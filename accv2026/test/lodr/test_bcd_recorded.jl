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
using VisualGeometryToolkitCore: CameraModel, Point2, Vec3, csponds, estimate, retcode, iterations, Incumbent,
    WelschShape, GemanMcclureShape, HuberShape, block_coordinate_descent!, Recorded, current_cost
using RANSACScoringDoneRight: StudentTUniformScoring
using VisualGeometryToolkitEstimation
using LocalOptimizationDoneRight
const R = VisualGeometryToolkitEstimation
const V = VisualGeometryToolkitCore
const LO = LocalOptimizationDoneRight
using VisualGeometryToolkitCore: rows_provider, lift_init, lift_refresh!, lift_residuals, lift_size

K = SA[800.0 0 320; 0 820.0 240; 0 0 1]
function two_view(rng, n; planar)
    Rm = SMatrix{3, 3, Float64, 9}(RotXYZ(0.05, -0.1, 0.03)); t = SA[1.0, 0.1, 0.05]
    u1 = Point2{Float64}[]; u2 = Point2{Float64}[]
    for _ in 1:n
        X = SA[2 * (rand(rng) - 0.5), 1.5 * (rand(rng) - 0.5), planar ? 4.0 : 3.0 + 2 * rand(rng)]
        p1 = K * X; p2 = K * (Rm * X + t)
        push!(u1, Point2{Float64}(p1[1] / p1[3], p1[2] / p1[3]))
        push!(u2, rand(rng) < 0.4 ? Point2{Float64}(640 * rand(rng), 480 * rand(rng)) :
                  Point2{Float64}(p2[1] / p2[3] + 0.5 * randn(rng), p2[2] / p2[3] + 0.5 * randn(rng)))
    end
    return csponds(u1, u2)
end

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
        state = LO.ScoreBcdState{M}(Incumbent{M}(model, -Float64(score)), -Float64(score), false)
        return state, LO.FixedWelschScale(), LO.ScoreBcdMethod(sc, ws.lo_ws, buf, lo.tol), p, model, lo.max_iter
    end
    prov = rows_provider(p)
    θ₀ = lift_init(prov, model)
    if lo isa LO.HQ
        method = LO.ManifoldLiftHQ(prov, lift_size(prov), R.lo_loss(lo, cs, sc, buf), lo.μ, LO.JointGaussNewton())
        return LO._init_manifold_hq(method, θ₀, lo.init), LO.FixedWelschScale(), method, p, model, lo.max_iter
    elseif lo isa LO.WelschHQNewton
        loss = V.loss_at(lo, WelschShape(), cs, sc, buf)
        method = LO.ManifoldLiftHQ(prov, lift_size(prov), loss, lo.μ, LO.WelschConvexNewton())
        return LO._init_manifold_hq(method, θ₀, :flat), LO.FixedWelschScale(), method, p, model, lo.max_iter
    elseif lo isa LO.WelschHQEcm
        loss = V.deploy(WelschShape(), max(V.scale_s2(cs), eps()); scale_multiple = lo.scale_multiple)
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
        state = LO.ManifoldLiftGncState(θ₀, cost0, Incumbent(θ₀, cost0), Inf, st, 0, false)
        return state, LO.FixedWelschScale(), LO.ManifoldLiftGnc(prov, lift_size(prov), loss), p, model, lo.max_iter
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

# Everything a state holds that a run moves (numbers, arrays, incumbents, the
# GNC ladder), not the shared workspaces it points into.
snap(x::Union{Number, Symbol, Nothing}) = x
snap(x::AbstractArray{<:Number}) = collect(x)
snap(x::StaticArray) = Tuple(x)
snap(x::Incumbent) = (snap(x.θ), x.cost)
snap(x) = isbits(x) ? x : nameof(typeof(x)) in (:PosteriorWeightState, :_PositionalDivisionState, :MuLadderState) ?
    Tuple(snap(getfield(x, i)) for i in 1:fieldcount(typeof(x))) : :skipped
snap_state(st) = Tuple(snap(getfield(st, i)) for i in 1:fieldcount(typeof(st)))
fp(res) = (snap(estimate(res)), retcode(res), iterations(res))

function check_recorded(mk)
    # the full run, bare and recorded
    st, lh, m, p, θ₀, max_iter = mk()
    bare = block_coordinate_descent!(st, lh, m, p, θ₀; max_iter)
    bare_state = snap_state(st)
    st2, lh2, m2, p2, θ₀2, _ = mk()
    rec = Recorded(st2)
    @test isequal(fp(block_coordinate_descent!(rec, lh2, m2, p2, θ₀2; max_iter)), fp(bare))
    @test isequal(snap_state(st2), bare_state)
    @test rec.reason[] === retcode(bare)
    k_run = iterations(bare)
    k_rec = length(rec.iterates)
    @test k_rec == (retcode(bare) === :solve_failed ? k_run - 1 : k_run)
    @test length(rec.cost) == length(rec.s2) == k_rec
    # iterate for iterate: the bare run truncated after k is the recorded run's k-th entry
    for k in 1:k_rec
        stk, lhk, mk_, pk, θk, _ = mk()
        resk = block_coordinate_descent!(stk, lhk, mk_, pk, θk; max_iter = k)
        @test isequal(current_cost(stk), rec.cost[k])
        @test iterations(resk) == k
        k == k_rec && @test isequal(snap_state(stk), bare_state)
    end
    return k_rec
end

problems = (
    (:H, R.HomographyProblem(two_view(Xoshiro(101), 300; planar = true))),
    (:F, R.FundMatProblem(two_view(Xoshiro(111), 300; planar = false))),
    (:E, R.EssentialProblem(CameraModel(K), CameraModel(K), two_view(Xoshiro(121), 300; planar = false))),
)
arms(kind) = Any[
    LO.StudentTUniform(), LO.BarronAdaptive(scale_multiple = 2.0),
    LO.StuTuBCD(), LO.HQ{WelschShape}(scale_multiple = 1.5), LO.HQ{GemanMcclureShape}(scale_multiple = 1.25),
    LO.Gnc{R.Irls{WelschShape}}(scale_multiple = 1.5),
    (kind === :E ? Any[LO.WelschHQNewton(scale_multiple = 1.5), LO.WelschHQEcm(scale_multiple = 1.5),
                       LO.StuTuHQTabulated(), LO.StuTuRegemm(max_iter = 12)] : Any[])...,
]
@testset "Recorded == bare: $kind $(nameof(typeof(lo)))" for (kind, p) in problems, lo in arms(kind)
    sc = StudentTUniformScoring(p, 50.0)
    θ = estimate(R.ransac(p, sc; rng = Xoshiro(1), config = R.RansacConfig(max_trials = 200)))
    @test check_recorded(() -> arm(p, sc, θ, lo)) >= 1
end
