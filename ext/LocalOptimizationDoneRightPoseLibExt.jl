# =============================================================================
# LocalOptimizationDoneRightPoseLibExt — the PoseLib truncated refiners'
# solver calls: VisualGeometryToolkitCore's external-refit contract
# (`external_workspace`, `prepare_external!`, `external_refit!`) for
# `PoseLibLm`, `PoseLibLZ` and `PoseLibLmAdaptLossWidth` on two-view problems,
# their pixel-form inputs read from the refit's two-view frame (`frame.Kc1`,
# `frame.Kc2`, `frame.cs`), and the solve of `TruncatedRefit`.
#
# Every refine is VisualGeometryToolkitCore's Levenberg–Marquardt with PoseLib's
# backend, `LevenbergMarquardt(PoseLibSolver(); optimization_strategy)`, its budget
# `stops = LmStops(; max_iter)`: E on `RefineProblem(cs, pose, (; K1, K2))`
# (camera-aware, from the seed's cheirality-resolved pose), F on
# `RefineProblem(cs, FundMat(F))`, H on `RefineProblem(cs, HomographyMat(H))`
# (symmetric transfer error, per-side truncation), all in the pool frame. `TLSShape()` = TLS-LM,
# `LeZach()` = TLS-LZ. The E cheirality (fast cross-product vote,
# strided-subsampled) runs INSIDE the refine — it is part of the refit
# pipeline, matching a native refit, which decomposes internally.
# =============================================================================
module LocalOptimizationDoneRightPoseLibExt

using LocalOptimizationDoneRight: LocalOptimizationDoneRight, PoseLibLm, PoseLibLZ, PoseLibLmAdaptLossWidth, TruncatedRefit
# The package's internals, qualified: its defaults of record and the adaptive arm's operating point.
const _config_default = LocalOptimizationDoneRight._config_default
const _ADAPT_OPERATING_EFFICIENCY_CONSTANT = LocalOptimizationDoneRight._ADAPT_OPERATING_EFFICIENCY_CONSTANT
using PoseLib: LeZach
using StaticArrays: SMatrix
using VisualGeometryToolkitCore: VisualGeometryToolkitCore, EssentialMat, FundMat, HomographyMat, Vec3,
    EuclideanMap, TLSShape, LossWidth, OutlierHalfwidth, loss_width, sources, targets, cheiral_pose_fast,
    codimension, data_size, mahalanobis_distances!, with_width, loss_width_to_outlier_halfwidth, FixedS2, scale_s2,
    deploy, JeffreysPrior, SquaredScale, ScaleMAP, EstimationProblem, RefineProblem, LevenbergMarquardt,
    PoseLibSolver, LmStops, NullParameters, Irls, solve
import VisualGeometryToolkitCore: external_workspace, prepare_external!, external_refit!, __solve
using VisualGeometryToolkitEstimation: EssentialProblem, FundMatProblem, HomographyProblem, RansacWorkspace, consensus_s2!

# The PoseLib strategy each truncated arm refines with (PoseLib's backend takes
# Core's `Irls{K}` or PoseLib's own `LeZach()` marker as `optimization_strategy`,
# the width as the solve keyword `width`; robust-contract B5).
_poselib_strategy(::PoseLibLm) = Irls{TLSShape}()
_poselib_strategy(::PoseLibLZ) = LeZach()

"""
    PoseLibWorkspace

The per-pair workspace of a PoseLib refiner: the frame's calibrations `Kc₁`,
`Kc₂` and its correspondences, as the two-view frame of VisualGeometryToolkitCore's
external-refit contract hands them over (`Kc1`, `Kc2` 3×3; `cs` a `Correspondences` of
2-vectors, which PoseLib's refines consume) — held as they are, of whatever
type and layout the frame carries (attribute columns, element type), not re-packed.
"""
struct PoseLibWorkspace{C}
    Kc1::SMatrix{3, 3, Float64, 9}
    Kc2::SMatrix{3, 3, Float64, 9}
    cs::C
end
PoseLibWorkspace(Kc1, Kc2, cs) = PoseLibWorkspace{typeof(cs)}(Kc1, Kc2, cs)
PoseLibWorkspace(frame) = PoseLibWorkspace(frame.Kc1, frame.Kc2, frame.cs)

external_workspace(::Union{PoseLibLm, PoseLibLZ}, _problem, frame, _scoring) = PoseLibWorkspace(frame)

# THE cheirality of a seed essential (one copy): its pose by VGC's fast vote
# (`cheiral_pose_fast`, strided-subsampled to about `[optimization_strategy.poselib]
# cheirality_vote_points` points) on the E problem's unit bearings.
const _CHEIRALITY_VOTE_POINTS = Int(_config_default("optimization_strategy.poselib", "cheirality_vote_points"))
@inline _cheiral_stride(n::Int; cap::Int = _CHEIRALITY_VOTE_POINTS) = 1:max(1, n ÷ cap):n
function _cheiral_seed_pose(problem::EssentialProblem, seed_E)
    f₁, f₂ = sources(problem.cs), targets(problem.cs)
    idx = _cheiral_stride(length(f₁))
    R0, t0 = cheiral_pose_fast(seed_E, view(f₁, idx), view(f₂, idx))
    return EuclideanMap(R0, Vec3{Float64}(t0))
end

# THE PoseLib refine of a guess (one copy): Core's LM with PoseLib's backend on the
# frame's correspondences `cs` and context `p` (the cameras of a pose refine, else
# none), at the absolute pool-frame loss width `w`, `max_iter` its budget.
_poselib_refine(cs, guess, p, strategy, w::Float64, max_iter::Int) =
    solve(RefineProblem(cs, guess, p), LevenbergMarquardt(PoseLibSolver(); optimization_strategy = strategy);
          stops = LmStops(; max_iter), width = w)

# THE E-branch body (one copy): the seed's cheirality-resolved pose refined
# camera-aware on the frame's calibrations and correspondences.
_truncated_refit(lo::Union{PoseLibLm, PoseLibLZ}, Kc1, Kc2, cs, problem::EssentialProblem, seed_E, w::Float64) =
    _poselib_refine(cs, _cheiral_seed_pose(problem, seed_E), (; K1 = Kc1, K2 = Kc2), _poselib_strategy(lo),
                    w, lo.max_iter)

__solve(prob::RefineProblem{<:EssentialProblem}, alg::TruncatedRefit; width::Real) =
    _truncated_refit(alg.lo, prob.p.Kc1, prob.p.Kc2, prob.p.cs, prob.f, prob.u0, Float64(width))

function external_refit!(ws::PoseLibWorkspace, lo::Union{PoseLibLm, PoseLibLZ}, problem::EssentialProblem,
                         seed_E, width::LossWidth, _scoring)
    pose = _truncated_refit(lo, ws.Kc1, ws.Kc2, ws.cs, problem, seed_E, loss_width(width)).u
    return EssentialMat(pose.R, pose.t)
end
function external_refit!(ws::PoseLibWorkspace, lo::Union{PoseLibLm, PoseLibLZ}, ::FundMatProblem,
                         seed_F, width::LossWidth, _scoring)
    return _poselib_refine(ws.cs, FundMat(SMatrix{3, 3, Float64, 9}(seed_F)), NullParameters(), _poselib_strategy(lo),
                           loss_width(width), lo.max_iter).u
end
function external_refit!(ws::PoseLibWorkspace, lo::Union{PoseLibLm, PoseLibLZ}, ::HomographyProblem,
                         seed_H, width::LossWidth, _scoring)
    return _poselib_refine(ws.cs, HomographyMat(SMatrix{3, 3, Float64, 9}(seed_H)), NullParameters(), _poselib_strategy(lo),
                           loss_width(width), lo.max_iter).u
end

# =============================================================================
# PoseLibLmAdaptLossWidth — the consensus-anchored truncated refit
# =============================================================================

"""
    AdaptWorkspace

The per-pair workspace of [`PoseLibLmAdaptLossWidth`](@ref): the PoseLib
inputs, a RANSAC workspace for the consensus-scale bootstrap (the refit
scoring's), the bootstrap's ŝ² of the current refit, and a residual buffer for
the per-round scale moment.
"""
mutable struct AdaptWorkspace{P <: PoseLibWorkspace, W}
    pl::P
    rws::W
    s2₀::Float64
    r::Vector{Float64}
end

function external_workspace(::PoseLibLmAdaptLossWidth, problem::EssentialProblem, frame, scoring)
    sc = with_width(scoring, OutlierHalfwidth(1.0))
    return AdaptWorkspace(PoseLibWorkspace(frame), RansacWorkspace(problem, sc), NaN,
                          Vector{Float64}(undef, data_size(problem)))
end
external_workspace(::PoseLibLmAdaptLossWidth, problem, _frame, _scoring) =
    error("PoseLibLmAdaptLossWidth: E-track only (got $(typeof(problem)))")

# Bootstrap ŝ² — OUTSIDE the timing bracket: the seed's consensus scale under
# the refit scoring at the outlier half-width of the delivered loss width,
# never the raw width itself. A consensus too thin to carry a scale makes no
# refit (no call is made or counted).
function prepare_external!(ws::AdaptWorkspace, ::PoseLibLmAdaptLossWidth, problem::EssentialProblem,
                           seed_E, width::LossWidth, scoring)
    a = loss_width_to_outlier_halfwidth(loss_width(width);
                                        operating_efficiency_constant = _ADAPT_OPERATING_EFFICIENCY_CONSTANT,
                                        d_g = codimension(problem))
    s2₀ = consensus_s2!(ws.rws, problem, with_width(scoring, OutlierHalfwidth(a)), seed_E)
    s2₀ === nothing && return false
    ws.s2₀ = s2₀
    return true
end

# A fixed plug-in scale (a role-isolated control): the bootstrap ŝ² IS that
# scale, no consensus read.
function prepare_external!(ws::AdaptWorkspace, ::PoseLibLmAdaptLossWidth, ::EssentialProblem, _seed_E,
                           f::FixedS2, _scoring)
    ws.s2₀ = scale_s2(f)
    return true
end

# Within-width truncated second moment — the arm's definition of record (the
# width "re-anchored on the refined partition", accv2026 protocol.toml
# [arms.tls_adapt]): the partition is the truncated loss's own, |rᵢ| ≤ loss_width
# (inclusive), and its scale is VGC's estimator `ScaleMAP(JeffreysPrior())` of (rss, ν)
# = rss/ν, ν the partition's size (a scalar distance: one component per point).
# Fewer than `min_support` residuals within the truncation → nothing (a
# consensus too thin for a stable scale).
const _ADAPT_MIN_SUPPORT = Int(_config_default("optimization_strategy.poselib_adapt", "min_support"))
function _truncated_moment_s2(loss_width::Float64, r::AbstractVector; min_support::Int = _ADAPT_MIN_SUPPORT)
    rss = 0.0; ν = 0
    @inbounds for i in eachindex(r)
        abs(r[i]) <= loss_width && (rss += r[i]^2; ν += 1)
    end
    ν < min_support && return nothing
    return solve(EstimationProblem(SquaredScale, (; rss, dof = ν)), ScaleMAP(JeffreysPrior())).u
end

# The truncated loss the arm refines at: VGC's deployment of `TLSShape()` at
# the scale ŝ² (floored at eps) and the arm's multiple — its width is
# `loss_width(deploy(…)) = efficiency_constant·ŝ`.
_adapt_loss_width(lo::PoseLibLmAdaptLossWidth, s2::Float64) =
    loss_width(deploy(TLSShape(), max(s2, eps()); efficiency_constant = lo.efficiency_constant))

# The per-round alternation moment of a refined pose: the within-width
# second moment of its pool-frame distances (`mahalanobis_distances!` on the E
# problem — the tangent Sampson distance on unit bearings), into the
# workspace's buffer.
_adapt_s2(ws::AdaptWorkspace, problem, R, t, loss_width::Float64) =
    _truncated_moment_s2(loss_width, mahalanobis_distances!(ws.r, problem, EssentialMat(R, t)))

function external_refit!(ws::AdaptWorkspace, lo::PoseLibLmAdaptLossWidth, problem::EssentialProblem,
                         seed_E, ::LossWidth, _scoring)
    pl = ws.pl
    w = _adapt_loss_width(lo, ws.s2₀)
    inner = max(1, lo.max_iter ÷ lo.rounds)
    pose = _cheiral_seed_pose(problem, seed_E)
    local ref = nothing
    for round in 1:lo.rounds
        ref = _poselib_refine(pl.cs, pose, (; K1 = pl.Kc1, K2 = pl.Kc2), Irls{TLSShape}(), w, inner).u
        pose = EuclideanMap(ref.R, Vec3{Float64}(ref.t))
        round == lo.rounds && break
        s2t = _adapt_s2(ws, problem, ref.R, ref.t, w)
        s2t === nothing && break                 # consensus too thin — freeze the width
        w = _adapt_loss_width(lo, s2t)
    end
    return EssentialMat(ref.R, ref.t)
end

end # module LocalOptimizationDoneRightPoseLibExt
