# =============================================================================
# VGC's `Recorded` decorator on every block-coordinate state this package
# runs: the posterior IRLS (Student-t and Barron-adaptive likelihoods),
# StuTuBCD, the HQ lift (incl. the ECM scale and the convex-Newton z-block),
# GNC, the tabulated mixture lift and ReGeMM. (The core's states — Irls{K}, the
# KeepModel EM, the division-camera IRLS — are VisualGeometryToolkitEstimation's test.)
# A recorded run must BE the bare run:
# the same result, and — truncated after every iteration k — the same state,
# so iterate for iterate. Each state is built as its `locally_optimize!` arm
# builds it (the internals of this package and VisualGeometryToolkitEstimation), on a
# fresh workspace per run.
# =============================================================================
# (Moved from VisualGeometryToolkitEstimation's test/bcd_recorded_tests.jl with the strategies it tests.)
using Test, Random, LinearAlgebra, StaticArrays
using Rotations: RotXYZ
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: CameraModel, Point2, Vec3, correspondences, estimate, retcode, iterations, Attributed,
    WelschShape, GemanMcclureShape, HuberShape, block_coordinate_descent!, Recorded, current_cost
using VisualGeometryToolkitCore: StudentTUniformScoring, JeffreysPrior, FlatLabelPrior   # the Student-t scorer is VisualGeometryToolkitCore's
using VisualGeometryToolkitEstimation
using LocalOptimizationDoneRight
const R = VisualGeometryToolkitEstimation
const V = VisualGeometryToolkitCore
const LO = LocalOptimizationDoneRight
using VisualGeometryToolkitCore: rows_provider, lift_init, lift_refresh!, lift_residuals, lift_size
using .EpipolarScenes: contaminated_pixel_pairs, PIXEL_PAIRS_K   # Estimation's shared two-view pixel scene

# The consensus set of `model`, as `_locally_optimize_seed!` hands it to the
# local optimizer (`_lo_on_partition!`), on a workspace composed for `lo`.
function seeded(p, sc, model, lo)
    ws = R._entry_workspace(nothing, p, sc, lo)
    R._prepare!(p)
    buf = ws.buf
    V.score_model!(buf, sc, p, R._seed_scored!(ws, p, sc, model))
    cs = V.consensus_set(sc, buf.scoring_ws, buf.residuals;
                         model_dof = R.minimal_sample_size(p) + 1, d_g = R.codimension(p), epoch = buf.epoch)
    return ws, cs
end

# (state, likelihood, method, problem, θ₀, max_iter) of one LO arm, fresh.
function arm(p, sc, model::M, lo) where {M}
    ws, cs = seeded(p, sc, model, lo)
    buf = ws.buf
    n = R.data_size(p)
    if lo isa Union{LO.StudentTUniform, LO.BarronAdaptive}
        a = lo isa LO.StudentTUniform ? R.required_outlier_halfwidth(sc) : something(V.outlier_halfwidth(sc), 1.0)
        state = R._seeded_irls_state!(ws.lo_ws, p, model, cs, buf, sc, a)
        lh = lo isa LO.StudentTUniform ? R.PosteriorLikelihood(state.rws, n) :
            LO.BarronAdaptiveLikelihood(state.rws, n, LO._barron_sq_width(lo, cs, sc, buf), lo.α_min, lo.truncation_multiple, lo.n_sub)
        R._seed_policy_weights!(state, lh, n)
        return state, lh, R.PosteriorIrlsMethod(ws.lo_ws.refine), p, model, lo.max_iter
    elseif lo isa LO.StuTuBCD
        score, _ = V.score_model!(buf, sc, p, model)
        state = LO.ScoreBcdState{M}(Attributed{M, @NamedTuple{cost::Float64}}(model, (; cost = -Float64(score))), -Float64(score), false)
        return state, FrozenNuisance(), LO.ScoreBcdMethod(sc, ws.lo_ws, buf, lo.tol), p, model, lo.max_iter
    end
    prov = rows_provider(p)
    θ₀ = lift_init(prov, model)
    if lo isa LO.HQ
        method = LO.ManifoldLiftHQ(prov, lift_size(prov), R.lo_loss(lo, cs, sc, buf), lo.μ, LO.JointGaussNewton())
        return LO._init_manifold_hq(method, θ₀, lo.init), FrozenNuisance(), method, p, model, lo.max_iter
    elseif lo isa LO.WelschHQNewton
        loss = V.loss_at(lo, WelschShape(), cs, sc, buf)
        method = LO.ManifoldLiftHQ(prov, lift_size(prov), loss, lo.μ, LO.WelschConvexNewton())
        return LO._init_manifold_hq(method, θ₀, :flat), FrozenNuisance(), method, p, model, lo.max_iter
    elseif lo isa LO.WelschHQEcm
        loss = V.loss_at(lo, WelschShape(), cs, sc, buf)
        method = LO.ManifoldLiftHQ(prov, lift_size(prov), loss, lo.μ)
        state = LO._init_manifold_hq(method, θ₀, :flat)
        return state, LO.WelschEcmScale(state, prov), method, p, model, lo.max_iter
    elseif lo isa LO.Gnc
        loss = R.lo_loss(lo, cs, sc, buf)
        lift_refresh!(prov, θ₀)
        res = lift_residuals(prov)
        r2max = maximum(i -> res[i]^2, 1:lift_size(prov))
        st = LO.schedule_init(LO.with_converged_rung(LO.gnc_schedule(loss, lo.factor), lo.budget === :converged),
                              V.gnc_entry_mu0(loss, r2max, lo.entry), lo.max_iter)
        cost0 = V.lift_cost(loss, res, lift_size(prov))
        state = LO.ManifoldLiftGncState(θ₀, cost0, Attributed(θ₀, (; cost = Float64(cost0))), Inf, st, 0, false)
        return state, FrozenNuisance(), LO.ManifoldLiftGnc(prov, lift_size(prov), loss), p, model, lo.max_iter
    end
    prov, pws = LO._mixture_lift_setup(ws.lo_ws, p, model, cs, buf, sc)
    θ₀ = lift_init(prov, model)
    if lo isa LO.StuTuHQTabulated
        method = LO.LiftedMixtureMethod(prov, lift_size(prov), lo.μ, lo.patience, LO.TabulatedLift(lo.lut_points; γ = lo.γ), pws)
        state = LO._init_lifted_mixture(method, θ₀)
        return state, LO.LiftedMixtureLikelihood(state, method), method, p, model, lo.max_iter
    else
        method = LO.LiftedReGeMMMethod(prov, lift_size(prov), lo.η, lo.adapt_scale, LO.TabulatedLift(lo.lut_points), pws,
                                       Vector{Float64}(undef, lift_size(prov)))
        state = LO._init_lifted_regemm(method, θ₀)
        return state, LO.LiftedReGeMMLikelihood(state, method), method, p, model, lo.max_iter
    end
end

# Recorded == bare, iterate for iterate: VisualGeometryToolkitCore's `test_recorded`.

problems = (
    (:H, R.HomographyProblem(contaminated_pixel_pairs(Xoshiro(101), 300; planar = true))),
    (:F, R.FundMatProblem(contaminated_pixel_pairs(Xoshiro(111), 300; planar = false))),
    (:E, R.EssentialProblem(CameraModel(PIXEL_PAIRS_K), CameraModel(PIXEL_PAIRS_K), contaminated_pixel_pairs(Xoshiro(121), 300; planar = false))),
)
arms(kind) = Any[
    LO.StudentTUniform(), LO.BarronAdaptive(efficiency_constant = 2.0),
    LO.StuTuBCD(), LO.HQ{WelschShape}(efficiency_constant = 1.5), LO.HQ{GemanMcclureShape}(efficiency_constant = VisualGeometryToolkitCore.decision_width(GemanMcclureShape(), 1.25)),
    LO.Gnc{R.Irls{WelschShape}}(efficiency_constant = 1.5),
    (kind === :E ? Any[LO.WelschHQNewton(efficiency_constant = 1.5), LO.WelschHQEcm(efficiency_constant = 1.5),
                       LO.StuTuHQTabulated(), LO.StuTuRegemm(max_iter = 12)] : Any[])...,
]
@testset "Recorded == bare: $kind $(nameof(typeof(lo)))" for (kind, p) in problems, lo in arms(kind)
    sc = StudentTUniformScoring(p, 50.0; scale_prior = JeffreysPrior(), label_prior = FlatLabelPrior())
    θ = estimate(R.ransac(p, sc; rng = Xoshiro(1), config = R.RansacConfig(max_trials = 200)))
    @test V.test_recorded(() -> arm(p, sc, θ, lo)) >= 1
end
