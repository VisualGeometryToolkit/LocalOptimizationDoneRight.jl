# =============================================================================
# adaptive_refit.jl — the consensus-anchored truncated refit (TLS-IRLS-ŝ): a
# refine algorithm of this package, `AdaptiveLossWidthRefit`, on a two-view
# problem that holds the pixels and calibrations it refines on and the unit
# bearings its scale moment reads (`RelativePoseRefitProblem`), and its external
# refit as a RANSAC local optimization, VisualGeometryToolkitCore's
# `BackendRefit(AdaptiveLossWidthRefit(…), stops)`.
#
# PoseLib's truncated refiners themselves are Core's `BackendRefit` of
# `LevenbergMarquardt(PoseLibSolver(); optimization_strategy = Irls{TLSShape}() | LeZach())`;
# this file adds only the scale re-estimation between rounds, which is this
# package's. Every refine is composed through `solve`: Core's Levenberg–Marquardt
# with PoseLib's backend on the raw pixel correspondences with the two cameras,
# `RefineProblem(cs, pose, (; K1, K2))` (loading PoseLib makes its solver available).
# =============================================================================

"""
    RelativePoseRefitProblem(relpose::RelativePoseProblem, essential::EssentialProblem)

The data of a relative pose's adaptive-width refine (an [`AdaptiveLossWidthRefit`](@ref)), both in the problem: the
pixel correspondences and the two cameras' calibrations it refines on (VisualGeometryToolkitEstimation's
`RelativePoseProblem(K1, K2, cs)`, the pool frame's), and the same pair's essential problem, whose unit bearings the
scale moment between rounds is measured on (`mahalanobis_distances!`, the tangent Sampson distance). Built once per
pair, outside a timing bracket.
"""
struct RelativePoseRefitProblem{R <: RelativePoseProblem, E <: EssentialProblem}
    relpose::R
    essential::E
end

"""
    AdaptiveLossWidthRefit(lm = LevenbergMarquardt(PoseLibSolver(); optimization_strategy = Irls{TLSShape}());
                           rounds, efficiency_constant, min_support, cheirality_vote_points)

A truncated relative-pose refine whose loss width is re-estimated between rounds (TLS-IRLS-ŝ), a `RefineKind`
algorithm:

    solve(RefineProblem(f::RelativePoseRefitProblem, pose₀), alg; stops = LmStops(; max_iter), scale = FixedS2(ŝ²₀))
        -> FitResult

`rounds` refines of the pose by `lm` (Core's Levenberg–Marquardt with PoseLib's backend), each at the truncated
loss `TLSShape()` deployed at the current scale ŝ² and `efficiency_constant` (the loss width
`efficiency_constant·ŝ`), with `max_iter ÷ rounds` (at least 1) of the total budget `stops.max_iter`. The start
scale is the solve's `scale`; between rounds ŝ² is the within-width truncated second moment of the refined pose's
distances on `f`'s bearings (the partition `|rᵢ| ≤ loss width`, inclusive), `ScaleMAP(JeffreysPrior())` of
`(rss, ν)`; with fewer than `min_support` residuals within the width the width is frozen. The result's `u` is the
refined pose (an `EuclideanMap{3}`), its record the last round's, `stats.nsteps` every round's iterations,
`metadata = (; loss_width, rounds)` (the width the last round ran at, the rounds run).

`cheirality_vote_points` is the external refit's seed (the cheirality vote of an essential seed, strided to about
that many points; VisualGeometryToolkitCore's `BackendRefit` of this algorithm). Defaults:
configs/default.toml `[adaptive_loss_width_refit]`. The workspace reuse is `init` → `solve!` → `reinit!(c, pose₀;
scale)`, the moment's residual buffer the cache's.
"""
struct AdaptiveLossWidthRefit{L <: LevenbergMarquardt} <: AbstractEstimationAlgorithm
    lm::L
    rounds::Int
    efficiency_constant::Float64
    min_support::Int
    cheirality_vote_points::Int
end
function AdaptiveLossWidthRefit(lm::LevenbergMarquardt = LevenbergMarquardt(PoseLibSolver(); optimization_strategy = Irls{TLSShape}());
        rounds::Integer = _config_default("adaptive_loss_width_refit", "rounds"),
        efficiency_constant::Real = _ADAPT_OPERATING_EFFICIENCY_CONSTANT,
        min_support::Integer = _config_default("adaptive_loss_width_refit", "min_support"),
        cheirality_vote_points::Integer = _config_default("adaptive_loss_width_refit", "cheirality_vote_points"))
    rounds >= 1 || throw(ArgumentError("AdaptiveLossWidthRefit: rounds must be ≥ 1, got $rounds"))
    cheirality_vote_points >= 1 || throw(ArgumentError(
        "AdaptiveLossWidthRefit: cheirality_vote_points must be ≥ 1, got $cheirality_vote_points"))
    return AdaptiveLossWidthRefit(lm, Int(rounds), Float64(efficiency_constant), Int(min_support), Int(cheirality_vote_points))
end
VgtkCore.estimator_kind(::AdaptiveLossWidthRefit) = RefineKind()

# The refit protocol's operating efficiency constant: the default `efficiency_constant` and the bootstrap's loss
# width → outlier half-width conversion.
const _ADAPT_OPERATING_EFFICIENCY_CONSTANT = Float64(_config_default("adaptive_loss_width_refit", "operating_efficiency_constant"))
# The external refit's LM budget of record (the evaluation's equal LO budget), the total across rounds.
const _ADAPT_STOPS = LmStops(; max_iter = Int(_config_default("adaptive_loss_width_refit.stops", "max_iter")))

# Identity (VisualGeometryToolkitCore traits, which its BackendRefit reports): the truncated LS refined with a
# RE-ESTIMATED scale ŝ, anchored on the seed's consensus scale; the filled square marks a refiner that re-estimates
# its scale.
VgtkCore.optimization_path(::AdaptiveLossWidthRefit) = OptimizationPath.irls
VgtkCore.scale_interface(::AdaptiveLossWidthRefit) = ConsensusAnchored()
VgtkCore.loss_family(::AdaptiveLossWidthRefit) = :tls
VgtkCore.lo_label(::AdaptiveLossWidthRefit) = raw"TLS-IRLS-$\hat s$"
VgtkCore.lo_marker(::AdaptiveLossWidthRefit) = Symbol("square*")

# -----------------------------------------------------------------------------
# The refine: its cache (the moment's buffer) and its rounds
# -----------------------------------------------------------------------------

mutable struct AdaptiveLossWidthCache{F <: RelativePoseRefitProblem, U, A <: AdaptiveLossWidthRefit}
    f::F
    u0::U
    alg::A
    stops::LmStops
    s2₀::Float64
    r::Vector{Float64}
end

function VgtkCore.__init(prob::RefineProblem{<:RelativePoseRefitProblem}, alg::AdaptiveLossWidthRefit;
        stops::LmStops = _ADAPT_STOPS, scale::FixedS2)
    prob.p isa NullParameters || throw(ArgumentError("AdaptiveLossWidthRefit takes no context: its data are the problem's"))
    return AdaptiveLossWidthCache(prob.f, prob.u0, alg, stops, scale_s2(scale), Vector{Float64}(undef, data_size(prob.f.essential)))
end
function VgtkCore.reinit!(c::AdaptiveLossWidthCache{F, U}, u0::U = c.u0; f::F = c.f, p = NullParameters(),
        alg = c.alg, stops::LmStops = c.stops, scale::FixedS2 = FixedS2(c.s2₀)) where {F, U}
    p isa NullParameters || throw(ArgumentError("AdaptiveLossWidthRefit takes no context: its data are the problem's"))
    data_size(f.essential) == length(c.r) || throw(DimensionMismatch(
        "reinit!: the cache's buffer holds $(length(c.r)) residuals; init a new cache for $(data_size(f.essential))"))
    c.f = f; c.u0 = u0; c.alg = alg; c.stops = stops; c.s2₀ = scale_s2(scale)
    return c
end
VgtkCore.solve!(c::AdaptiveLossWidthCache) = _adaptive_refit!(c.r, c.f, c.u0, c.alg, c.stops, c.s2₀)

# Within-width truncated second moment — the arm's definition of record (the width "re-anchored on the refined
# partition", accv2026 protocol.toml [arms.tls_adapt]): the partition is the truncated loss's own, |rᵢ| ≤ loss_width
# (inclusive), and its scale is VGC's estimator `ScaleMAP(JeffreysPrior())` of (rss, ν) = rss/ν, ν the partition's
# size (a scalar distance: one component per point). Fewer than `min_support` residuals within the truncation →
# nothing (a consensus too thin for a stable scale).
function _truncated_moment_s2(loss_width::Float64, r::AbstractVector, min_support::Int)
    rss = 0.0; ν = 0
    @inbounds for i in eachindex(r)
        abs(r[i]) <= loss_width && (rss += r[i]^2; ν += 1)
    end
    ν < min_support && return nothing
    return solve(EstimationProblem(SquaredScale, (; rss, dof = ν)), ScaleMAP(JeffreysPrior())).u
end

# The truncated loss a round refines at: VGC's deployment of `TLSShape()` at the scale ŝ² (floored at eps) and the
# algorithm's multiple — its width is `loss_width(deploy(…)) = efficiency_constant·ŝ`.
_adapt_loss_width(alg::AdaptiveLossWidthRefit, s2::Float64) =
    loss_width(deploy(TLSShape(), max(s2, eps()); efficiency_constant = alg.efficiency_constant))

function _adaptive_refit!(r::Vector{Float64}, f::RelativePoseRefitProblem, pose, alg::AdaptiveLossWidthRefit,
                          stops::LmStops, s2₀::Float64)
    rp = f.relpose
    w = _adapt_loss_width(alg, s2₀)
    inner = LmStops(; max_iter = max(1, stops.max_iter ÷ alg.rounds))
    res = solve(RefineProblem(rp.cs, pose, (; K1 = rp.K1, K2 = rp.K2)), alg.lm; stops = inner, width = w)
    nsteps = res.stats.nsteps
    rounds = 1
    while rounds < alg.rounds
        s2t = _truncated_moment_s2(w, mahalanobis_distances!(r, f.essential, EssentialMat(res.u.R, res.u.t)), alg.min_support)
        s2t === nothing && break                 # consensus too thin — freeze the width
        w = _adapt_loss_width(alg, s2t)
        pose = EuclideanMap(res.u.R, Vec3{Float64}(res.u.t))
        res = solve(RefineProblem(rp.cs, pose, (; K1 = rp.K1, K2 = rp.K2)), alg.lm; stops = inner, width = w)
        nsteps += res.stats.nsteps
        rounds += 1
    end
    return FitResult(res.u, res.retcode, res.stop_rule, SolveStats(; nsteps), res.rms, res.n, (; loss_width = w, rounds);
                     original = res.original)
end

# -----------------------------------------------------------------------------
# The external refit: VisualGeometryToolkitCore's BackendRefit of this algorithm, on a two-view E problem
# -----------------------------------------------------------------------------

"""
    AdaptiveRefitWorkspace

The per-pair workspace of `BackendRefit(AdaptiveLossWidthRefit(…), stops)` on an essential problem: the refine's
cache (on the pair's `RelativePoseRefitProblem`, built from the refit's two-view frame), and the consensus-scale
bootstrap's cache (Estimation's `ConsensusScale` under the refit scoring) with the bootstrap's ŝ²₀.
"""
mutable struct AdaptiveRefitWorkspace{C, S}
    refine::C
    scale::S
    s2₀::Float64
end

const _AdaptiveRefit = BackendRefit{<:AdaptiveLossWidthRefit}

function VgtkCore.external_workspace(lo::_AdaptiveRefit, problem::EssentialProblem, frame, scoring)
    f = RelativePoseRefitProblem(RelativePoseProblem(SMatrix{3, 3, Float64, 9}(frame.Kc1), SMatrix{3, 3, Float64, 9}(frame.Kc2),
                                                     frame.cs), problem)
    pose₀ = EuclideanMap(SMatrix{3, 3, Float64, 9}(I), Vec3{Float64}(0.0, 0.0, 1.0))
    refine = init(RefineProblem(f, pose₀), lo.alg; stops = lo.stops, scale = FixedS2(1.0))
    sc = with_width(scoring, OutlierHalfwidth(1.0))
    scale = init(EstimationProblem(SquaredScale, problem, (; model = EssentialMat(SMatrix{3, 3, Float64, 9}(I)))), ConsensusScale(sc))
    return AdaptiveRefitWorkspace(refine, scale, NaN)
end
VgtkCore.external_workspace(::_AdaptiveRefit, problem, _frame, _scoring) =
    throw(ArgumentError("AdaptiveLossWidthRefit's external refit is the essential problem's (got a $(typeof(problem)))"))

# Bootstrap ŝ² — OUTSIDE the timing bracket: the seed's consensus scale under the refit scoring at the outlier
# half-width of the delivered loss width, never the raw width itself. A consensus too thin to carry a scale makes no
# refit (no call is made or counted).
function VgtkCore.prepare_external!(ws::AdaptiveRefitWorkspace, lo::_AdaptiveRefit, problem::EssentialProblem,
                                    seed_E, width::LossWidth, scoring)
    a = loss_width_to_outlier_halfwidth(loss_width(width);
                                        operating_efficiency_constant = _ADAPT_OPERATING_EFFICIENCY_CONSTANT,
                                        d_g = codimension(problem))
    r = solve!(reinit!(ws.scale; p = (; model = seed_E), alg = ConsensusScale(with_width(scoring, OutlierHalfwidth(a)))))
    r.u === nothing && return false
    ws.s2₀ = r.u
    return true
end
# A fixed plug-in scale (a role-isolated control): the bootstrap ŝ² IS that scale, no consensus read.
function VgtkCore.prepare_external!(ws::AdaptiveRefitWorkspace, ::_AdaptiveRefit, ::EssentialProblem, _seed_E,
                                    f::FixedS2, _scoring)
    ws.s2₀ = scale_s2(f)
    return true
end

# The bracketed refit: the seed's cheirality-resolved pose (the caller's step), refined from the bootstrap scale.
# The refine's record (Core's external-refit contract: a FitResult), its model the refined pose's essential.
function VgtkCore.external_refit!(ws::AdaptiveRefitWorkspace, lo::_AdaptiveRefit, problem::EssentialProblem,
                                  seed_E, ::LossWidth, _scoring)
    pose = cheiral_pose_fast(seed_E, problem.cs; vote_points = lo.alg.cheirality_vote_points)
    r = solve!(reinit!(ws.refine, pose; scale = FixedS2(ws.s2₀)))
    return FitResult(EssentialMat(r.u.R, r.u.t), r.retcode, r.stop_rule, r.stats, r.rms, r.n, r.metadata; original = r.original)
end
