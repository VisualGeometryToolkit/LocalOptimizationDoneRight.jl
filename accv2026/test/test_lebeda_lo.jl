# The classical RansacLib LO arms (src/lebeda_lo.jl): identity traits, presets,
# the external-refit contract they implement, the refit path on every track, and
# the vendored RansacLibLO library's own suite. Run in its own process by
# runtests.jl (it loads the paper config, like test_lo_contracts.jl).
import VisualGeometryToolkitEval as VgtkEval
using Test
using LocalOptimizationDoneRight: LocalOptimizationDoneRight
include(joinpath(@__DIR__, "..", "src", "config.jl"))
using VisualGeometryToolkitCore: VisualGeometryToolkitCore, ExternalRefit, LossWidth, FixedS2, OutlierHalfwidth,
    refine_external!
using RansacLibLO: LebedaLOOptions, PRESET_REFERENCE

# Budget-parity options as a caller builds them: RansacLib defaults with 4 trials
# (1 + 4·(2 + 4) = 25 updates for a fully active full-LO call).
const _FOUR_TRIALS = LebedaLOOptions(num_lo_trials = 4)
using VisualGeometryToolkitEval.Evaluation: PairCtx, problem_type, model_imc, refit_imc!, refit_seed, solo_refit_imc!,
    SoloSpec, LoRefitSpec
using VisualGeometryToolkitEstimation: EssentialProblem
using RansacScoringDoneRight: StudentTUniformScoring
using VisualGeometryToolkitCore: CameraModel

include(joinpath(@__DIR__, "test_lebeda_identity.jl"))

# In a module of its own: the library's suite defines helpers (`skew`) that the
# paper config imports from VisualGeometryToolkitCore.
@testset "vendored RansacLibLO suite" begin
    Core.eval(Main, :(module _RansacLibLOSuite
        include($(joinpath(dirname(@__DIR__), "lib", "RansacLibLO", "test", "runtests.jl")))
    end))
end

# The refit path itself — the arms' only non-trivial code, which the
# identity checks above never run. Wide-FOV synthetic pair (RansacLibLO's own
# test regime; a planar variant for H), in a fake
# pool frame with non-trivial focals so the E-track loss-width conversion is live.
using Random, LinearAlgebra, StaticArrays
using VisualGeometryToolkitCore: Point2, EssentialMat, FundMat, HomographyMat, Csponds
using RansacLibLO: lebeda_iterlo

include(joinpath(@__DIR__, "two_view_scene.jl"))
_lebeda_scene(; planar::Bool) = two_view_scene(; planar)

# The pool-convention seed of each track: the metric E, the pool-frame F, and the
# pool-frame H of the plane z = 3 — all from the same perturbed pose.
function _lebeda_seed(s, track::Symbol)
    E0 = EssentialMat(s.Rp, s.tp)
    track === :E && return E0
    track === :F && return FundMat(E0, s.K1, s.K2)
    return HomographyMat(Tuple(s.K2 * (s.Rp + s.tp * SA[0.0, 0.0, 1.0]' / 3.0) * inv(s.K1)))
end
# The seed as a pool pair stores it: the pool-frame F on the E track.
_lebeda_pool_model(s, track::Symbol) = track === :E ? FundMat(_lebeda_seed(s, :E), s.K1, s.K2) : _lebeda_seed(s, track)

# The refit layer's per-pair context, laid out as `build_pair_ctx` builds it
# from a pool pair: the E track reads its bearings from the E problem (the
# pool-frame csponds back-projected by the pool cameras); F and H take the
# pool-frame csponds verbatim. Its one stored model is the track's seed; its
# refit template is the Jeffreys Student-t + uniform marginal (an external
# refiner reads none).
function _lebeda_ctx(s, track::Symbol)
    cs = s.geom.cs
    P = problem_type(track)
    ep = track === :E ? EssentialProblem(CameraModel(s.K1), CameraModel(s.K2), cs) : P(cs)
    template = StudentTUniformScoring(P, 1.0)
    return PairCtx((models = [_lebeda_pool_model(s, track)],), ep, nothing, s.geom, P, template, template,
                   Dict{Symbol, Any}())
end

# The arm's workspace in the context's cache (one per pair, template and arm).
_lebeda_ws(ctx) = only(v for v in values(ctx.lo_ws) if v isa LebedaWorkspace)

function _lebeda_refit_run(lo, track::Symbol)
    s = _lebeda_scene(; planar = track === :H)
    ctx = _lebeda_ctx(s, track)
    seed = _lebeda_seed(s, track)
    seed_err = model_imc(seed, ctx)
    err, ns = refit_imc!(ctx, ExternalRefit(), lo, seed, s.loss_width, ctx.scoring, NaN, false, nothing)
    return (; err, ns, seed_err, ctx, s)
end

# A DIRECT wrapper call, built by hand: the track's point frame (calibrated for
# E — the scene's own normalized points; the pool frame for F/H), the given squared
# loss width and
# model kind, read back through the same imc as the refit path.
function _lebeda_direct(track::Symbol, sq_loss_width; kind::Symbol = track)
    s = _lebeda_scene(; planar = track === :H)
    ctx = _lebeda_ctx(s, track)
    a, b = track === :E ? (s.w1, s.w2) : (s.x1c, s.x2c)
    P = Matrix{Float64}(undef, 4, length(a))
    for i in eachindex(a)
        P[1, i], P[2, i] = a[i]
        P[3, i], P[4, i] = b[i]
    end
    seed = Matrix{Float64}(SMatrix{3, 3, Float64, 9}(_lebeda_seed(s, track)))
    d = lebeda_iterlo(P, seed, sq_loss_width; model = kind, rng_seed = 0, options = _FOUR_TRIALS)
    M = SMatrix{3, 3, Float64, 9}(d.E)
    model = track === :E ? EssentialMat(Tuple(M)) : track === :F ? FundMat(Tuple(M)) : HomographyMat(Tuple(M))
    return model_imc(model, ctx)
end

@testset "RansacLib LO arms: refit path (E/F/H)" begin
    budget(lo) = lo isa LebedaIterLO ? 1 + lo.opts.num_lsq_iterations :
                 1 + lo.opts.num_lo_trials * (2 + lo.opts.num_lsq_iterations)
    for lo in (LebedaIterLO(_FOUR_TRIALS, 0), LebedaLOPlus(_FOUR_TRIALS, 0), LebedaLOPlus(PRESET_REFERENCE, 0)),
            track in (:E, :F, :H)
        r = _lebeda_refit_run(lo, track)
        @test isfinite(r.err) && r.err === _lebeda_refit_run(lo, track).err   # fixed rng_seed ⇒ bitwise repeat
        # travels from the seed (E/F). Not asserted for H: the engine's H
        # decomposition metric scores even this fixture's EXACT homography at
        # ~23°, so H correctness is pinned by the direct-call testset below.
        track === :H || @test r.err < r.seed_err
        ws = _lebeda_ws(r.ctx)
        last = lebeda_last(ws)
        @test 0 < last.updates <= budget(lo) && last.ns > 0 && r.ns > 0
        # each track's workspace holds the point matrix of its own frame (the
        # calibrated plane for E, the pool frame for F/H) and the loss width's
        # frame factor (E: PoseLib's camera-aware rule; F/H: none)
        a, b = track === :E ? (r.s.w1, r.s.w2) : (r.s.x1c, r.s.x2c)
        @test size(ws.pts) == (4, length(a))
        @test isapprox(ws.pts, stack(vcat(p, q) for (p, q) in zip(a, b)); atol = 1.0e-12)
        @test ws.width_scale === (track === :E ? _poselib_loss_width_scale(r.s.K1, r.s.K2) : 1.0)
    end
end

# Each track IS the direct wrapper call with its own frame, loss-width currency
# and model kind: E at the squared (loss_width · ½(1/f₁ + 1/f₂)) (PoseLib's
# camera-aware conversion, then the API's square), F and H at loss_width². The
# negative controls (the other currency, the wrong kind) differ on this fixture,
# so the equality is not vacuous.
@testset "RansacLib LO arms: each track is the direct wrapper call" begin
    for track in (:E, :F, :H)
        s = _lebeda_scene(; planar = track === :H)
        converted = (s.loss_width * _poselib_loss_width_scale(s.K1, s.K2))^2
        track_sq_loss_width, other = track === :E ? (converted, s.loss_width^2) : (s.loss_width^2, converted)
        path = _lebeda_refit_run(LebedaIterLO(_FOUR_TRIALS, 0), track).err
        # E: the calibrated points differ from the scene's only by the Kc round-trip ulps
        @test isapprox(path, _lebeda_direct(track, track_sq_loss_width); rtol = 1.0e-6)
        @test !isapprox(path, _lebeda_direct(track, other); rtol = 1.0e-3)
        @test !isapprox(path, _lebeda_direct(track, track_sq_loss_width; kind = track === :H ? :F : :H); rtol = 1.0e-3)
    end
end

# An absolute loss width reaches the arm bitwise through every conduit of the
# refit layer: its native nat′ (`refit_imc!`), a fixed scale `s2 = w²` whatever
# native rides along (`refit_imc!(…; s2)` → `FixedS2(w²)`, the loss width √s2 —
# √(w²) == w in IEEE arithmetic: a correctly rounded square root of a
# correctly rounded square), the solo delivery (`solo_refit_imc!` at
# `LossWidth()`) and a tuning column's absolute width (`LoRefitSpec` `widths`).
# The refit at another width differs, so the equalities are not vacuous.
@testset "RansacLib LO arms: an absolute width reaches the arm through every conduit" begin
    for track in (:E, :F, :H), lo in (LebedaIterLO(_FOUR_TRIALS, 0), LebedaLOPlus(_FOUR_TRIALS, 0))
        s = _lebeda_scene(; planar = track === :H)
        w = s.loss_width
        ctx = _lebeda_ctx(s, track)
        seed = refit_seed(ctx, only(ctx.pair.models))
        native = first(refit_imc!(ctx, ExternalRefit(), lo, seed, w, ctx.scoring, NaN, false, nothing))
        @test isfinite(native)
        @test first(refit_imc!(ctx, lo, seed, w; on_fail = NaN)) === native
        @test first(refit_imc!(ctx, lo, seed, 10 * w; on_fail = NaN, s2 = w^2)) === native
        @test first(refit_imc!(ctx, lo, seed, 10 * w; on_fail = NaN)) !== native
        solo = SoloSpec("TLS-LO", :refinement, LossWidth(), _ -> lo)
        @test first(solo_refit_imc!(ctx, solo, seed, w, 0.05)) === native
        spec = LoRefitSpec("TLS-LO", lo, OutlierHalfwidth(), [0.05], reshape(Int32[1], 1, 1); widths = [w])
        M = fill(NaN, 1, 1)
        VgtkEval.Evaluation._apply_refit_row!(M, ctx, lo, spec, 1, OPERATING_SCALE_MULTIPLE, NaN)
        @test M[1, 1] === native
        # the contract itself: FixedS2(w²) is the loss width √(w²) = w
        ws = _lebeda_ws(ctx)
        M_lw = refine_external!(ws, lo, ctx.ep, seed, LossWidth(w), ctx.scoring)
        @test refine_external!(ws, lo, ctx.ep, seed, FixedS2(w^2), ctx.scoring) == M_lw
    end
end
