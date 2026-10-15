# =============================================================================
# test_engine_integration.jl — the RSDR × LODR integration goldens of the
# composition evaluator (VisualGeometryEval.Evaluation): the paper's scorer
# (RansacScoringDoneRight's Student-t + uniform marginal, its grid kernels) and
# local optimizers (LocalOptimizationDoneRight's HQ lift, Stu-tU IRLS and BCD,
# the PoseLib truncated refiners) through the refit layer, the post-LO
# matrices, the sample-budget engine, live runs, the selection stream, the
# miscalibration evaluation refit and the roster's gate-enforced readers.
#
# Carried from LocalOptimizationDoneRight's test/test_engine.jl when the
# engine moved to VisualGeometryEval (K+, 2026-10-09). VisualGeometryEval's
# own suite tests the engine on core components alone (it may not load the
# scorer or optimizer packages); the cases here are the ones only the paper's
# components can exercise, on the K+ API: scorings are TEMPLATES, an absolute
# width reaches a native or an external refiner through `widths` /
# `solo_refit_imc!` / `refit_imc!(…; s2)` (`FixedS2`).
#
# Fixtures: VisualGeometryEval's synthetic E pool pair (a light `PoolPair` with
# its residual matrix) and a wide-FOV calibrated scene in a fake pool frame.
# Runs in a module of its own (no binding leaks into the paper config's Main).
# =============================================================================
module EngineIntegration

using Test, Random, LinearAlgebra, StaticArrays
using Rotations: RotationVec
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LocalOptimizationDoneRight as LODR, HQ, StuTuBCD, StudentTUniform, PoseLibLm,
    PoseLibLZ, PoseLibLmAdaptLossWidth
import PoseLib            # LocalOptimizationDoneRight's PoseLib extension: the truncated refiners' solver calls
using RansacScoringDoneRight: RansacScoringDoneRight, StudentTUniformScoring, loss_width_scoring
using VisualGeometryEval.Evaluation
using VisualGeometryEval.Evaluation: Evaluation, PairGeom, ScoreSelector, OracleSelector, lo_error!,
    lo_iteration_budget, deployed_ref
using VisualGeometryEval.Pools: PoolResiduals, ScoringPool, synthetic_e_pool_pair, sample_starts, GT_CONVENTION
using VisualGeometryEval.Tuning: tuning_spec, GridSpec, SpacedGrid, LinearCount, grid, save_tuning_artifact,
    tuning_table, ScaleMultipleWindow, PairUnit
using RobustVisualGeometry: EssentialProblem, FundMatProblem, NoLocalOptimization, RansacWorkspace, consensus_s2!
using VisualGeometryCore: EssentialMat, FundMat, Point2, Csponds, CameraModel, WelschShape, IGPrior, MsacScoring,
    ConsensusAnchored, ScaleMultiple, LossWidth, OutlierHalfwidth, scale_interface, width_axis_name, with_width,
    codimension, select_on_grid!, stage_selection, selection_staging, best_pool_model, scoring_workspace
using VisualGeometryCore.Pools: PoolPair, num_models, num_points

const P = EssentialProblem
const PRIOR = IGPrior(0.0, 0.0)                           # Jeffreys
"The Student-t + uniform marginal at outlier half-width `a` (Jeffreys)."
marginal(a) = StudentTUniformScoring(P, a; prior = PRIOR)
"THE refit scoring template of every context here."
const TEMPLATE = marginal(1.0)
const CPU = RansacScoringDoneRight.KernelAbstractions.CPU()

# A one-scene ScoringPool of `pairs` stamped with `total` minimal samples: what
# VisualGeometryEval's `sample_starts` certifies its boundaries against.
starts_pool(pairs, total) = ScoringPool(pairs, :E, "synthetic"; scene_names = fill("synthetic", length(pairs)),
    stamps = (gt_convention = GT_CONVENTION, pool_rng = "LehmerRNG", julia_version = string(VERSION),
              total_samples = total, total_solutions = sum(num_models, pairs), mean_solutions_per_sample = 1.0,
              provenance = Dict{String,Any}()))
# The pair restricted to the stored models `cols`.
subpair(pair, cols) = PoolPair{FundMat{Float64}}(; (f => getfield(pair, f) for f in fieldnames(typeof(pair)))...,
    models = pair.models[cols], sample_indices = pair.sample_indices[:, cols],
    errors_r = pair.errors_r[cols], errors_t = pair.errors_t[cols])

# THE synthetic E pool pair of the engine items: 30 noisy correspondences, 12
# single-model minimal samples, σ̂² = 4e-6. Returns `(pair, residuals)`.
const EPAIR_GT_VARIANCE = 4.0e-6
epair(rng) = synthetic_e_pool_pair(rng; sibling_counts = fill(1, 12), noise = 0.002, δ_rot = 0.2,
                                   t_jitter = 0.1, gt_variance = EPAIR_GT_VARIANCE)

# A wide-FOV calibrated pair in a fake pool frame: 1600×1200 images, focal 800
# px, half diagonal s = 1000 px, so the pool-frame camera is Kc = diag(f/s, f/s,
# 1); 0.5 px noise, outliers uniform in the image.
function wide_scene(rng; n_in = 120, n_out = 40)
    W, H, f = 1600.0, 1200.0, 800.0
    s = hypot(W, H) / 2
    Kc = SMatrix{3,3,Float64,9}(Diagonal(SA[f / s, f / s, 1.0]))
    R = SMatrix{3,3,Float64,9}(RotationVec(0.1, 0.2, 0.05))
    t = normalize(SA[1.0, 0.2, 0.1])
    project(X) = Point2{Float64}(Kc[1, 1] * X[1] / X[3], Kc[2, 2] * X[2] / X[3])
    jitter() = Point2{Float64}(0.5 / s * randn(rng), 0.5 / s * randn(rng))
    x1 = Point2{Float64}[]; x2 = Point2{Float64}[]
    while length(x1) < n_in
        X = SA[8.0 * (rand(rng) - 0.5), 6.0 * (rand(rng) - 0.5), 3.0 + 4.0 * rand(rng)]
        Y = R * X + t
        (abs(X[1] / X[3]) < W / 2f && abs(X[2] / X[3]) < H / 2f && Y[3] > 0 &&
         abs(Y[1] / Y[3]) < W / 2f && abs(Y[2] / Y[3]) < H / 2f) || continue
        push!(x1, project(X) + jitter()); push!(x2, project(Y) + jitter())
    end
    inside() = Point2{Float64}((rand(rng) - 0.5) * W / s, (rand(rng) - 0.5) * H / s)
    for _ in 1:n_out
        push!(x1, inside()); push!(x2, inside())
    end
    cs = Csponds(x1, x2)
    geom = PairGeom(Kc, Kc, R, SVector{3,Float64}(t), cs)
    return (; R, t, Kc, cs, geom, loss_width = 2.0 / s, n_in)
end

# One refit row of a spec on a hand-built context (the row `apply_lo_refits`
# writes for pair 1).
function refit_row(ctx, spec)
    M = fill(NaN, 1, length(spec.grid))
    Evaluation._apply_refit_row!(M, ctx, spec.lo, spec, 1, OPERATING_SCALE_MULTIPLE, nothing)
    return M
end

@testset "RSDR × LODR integration (composition evaluator)" begin

@testset "refit_model: the HQ lift under the Student-t + uniform marginal" begin
    pair, _ = epair(MersenneTwister(7))
    ctx = build_pair_ctx(P, pair; scoring = TEMPLATE)
    seed = refit_seed(ctx, pair.models[3])
    lo = HQ{WelschShape}(max_iter = 25, scale_multiple = 1.0)
    a = 0.01
    sc = marginal(a)
    @test with_width(TEMPLATE, OutlierHalfwidth(a)) == sc          # the template at the refit's half-width
    E = refit_model(ctx.ep, seed, lo, sc)
    @test E !== nothing && E != seed
    @test refit_imc!(ctx, lo, seed, a)[1] == model_imc(E, ctx)          # the imc row of exactly this model
    s2 = consensus_s2!(RansacWorkspace(ctx.ep, sc), ctx.ep, sc, seed)
    @test s2 !== nothing && refit_model(ctx.ep, seed, lo, sc; s2) == E   # ŝ² as an absolute scale: same refit
    @test refit_model(ctx.ep, seed, lo, sc; s2 = 100 * s2) != E
    @test refit_model(ctx.ep, seed, ScoreGuarded(lo), sc) in (E, seed)
end

@testset "LO contracts on the wide scene" begin
    sn = wide_scene(MersenneTwister(2026))
    F_seed = FundMat(perturbed_seed_E(MersenneTwister(5), sn.R, sn.t, 0.08), sn.Kc, sn.Kc)
    mkctx() = PairCtx((models = [F_seed],), EssentialProblem(CameraModel(sn.Kc), CameraModel(sn.Kc), sn.cs),
                      nothing, sn.geom, EssentialProblem, TEMPLATE, TEMPLATE, Dict{Symbol,Any}())

    @testset "PoseLibLmAdaptLossWidth guards" begin
        # E-track only: its workspace refuses another problem
        fctx = PairCtx((models = [F_seed],), FundMatProblem(sn.cs), nothing, sn.geom, FundMatProblem,
                       TEMPLATE, TEMPLATE, Dict{Symbol,Any}())
        @test_throws ErrorException refit_imc!(fctx, PoseLibLmAdaptLossWidth(), F_seed, 0.05; on_fail = NaN)
        @test scale_interface(PoseLibLmAdaptLossWidth()) isa ConsensusAnchored
        ctx = mkctx()
        e, _ = refit_imc!(ctx, PoseLibLmAdaptLossWidth(), refit_seed(ctx, F_seed), sn.loss_width; on_fail = NaN)
        @test isfinite(e)
    end

    @testset "an absolute loss width: every conduit delivers one width (bitwise)" begin
        for lo in (PoseLibLm(25), PoseLibLZ(25)), seed_rng in (1, 2), m in (0.5, 1.0, 3.0)
            width = m * sn.loss_width
            ctx = mkctx()
            seed = perturbed_seed_E(MersenneTwister(seed_rng), sn.R, sn.t, 0.08)
            e_native, _ = refit_imc!(ctx, lo, seed, width; on_fail = NaN)
            e_fixed, _ = refit_imc!(ctx, lo, seed, 0.123; on_fail = NaN, s2 = width^2)   # FixedS2(width²)
            @test isfinite(e_native) && e_native === e_fixed
        end
        for lo in (PoseLibLm(25), PoseLibLZ(25))
            width = 3 * sn.loss_width
            rows = map(((; natives = [width]), (; widths = [width]), (; natives = [0.123], fixed_s2s = [width^2]))) do d
                only(refit_row(mkctx(), LoRefitSpec("x", lo, OutlierHalfwidth(), [0.05], reshape(Int32[1], 1, 1); d...)))
            end
            @test isfinite(rows[1]) && rows[1] === rows[2] === rows[3]
        end
    end

    @testset "loss-width delivery ≡ solo delivery (bitwise)" begin
        width = 3 * sn.loss_width
        halfwidth = 0.05
        lo_unit() = HQ{WelschShape}(max_iter = 25, scale_multiple = 1.0)
        for lo_of in (lo_unit, () -> PoseLibLm(25))          # a native refiner, an external one
            spec = LoRefitSpec("bw", lo_of(), OutlierHalfwidth(), [halfwidth], reshape(Int32[1], 1, 1);
                               width_delivery(LossWidth(), lo_of(), width, 1)...)
            M = refit_row(mkctx(), spec)
            ctx2 = mkctx()
            solo = SoloSpec("bw", :refinement, LossWidth(), _ -> lo_of())
            e_solo, _ = solo_refit_imc!(ctx2, solo, refit_seed(ctx2, F_seed), width, halfwidth; on_fail = nothing)
            @test isfinite(M[1, 1]) && M[1, 1] === e_solo
        end
        # the native refiner: its unit-multiple strategy at the fixed scale w² under the solo template
        ctx3 = mkctx()
        @test first(refit_row(mkctx(), LoRefitSpec("bw", lo_unit(), OutlierHalfwidth(), [halfwidth],
                                                   reshape(Int32[1], 1, 1); widths = [width]))) ===
              first(refit_imc!(ctx3, lo_unit(), refit_seed(ctx3, F_seed), halfwidth; scoring = ctx3.solo_scoring,
                               s2 = width^2))
        @test width_delivery(LossWidth(), lo_unit(), 2.0, 2) == (; widths = [2.0, 2.0])
        @test width_delivery(LossWidth(), PoseLibLm(25), 2.0, 2) == (; widths = [2.0, 2.0])
        @test width_delivery(ScaleMultiple(), lo_unit(), 2.0, 2) == (;)
        @test_throws ArgumentError SoloSpec("x", :refinement, ScaleMultiple(), identity)
        @test_throws ArgumentError ComposedSpec("x", :ig, ScaleMultiple(), ScaleMultiple(), identity)
    end
end

@testset "LoRefitSpec: the paper refiners' native axes" begin
    idxs = ones(Int32, 1, 3)
    @test_throws MethodError consumed_native(PoseLibLm(25), ScaleMultiple(), 0.2; d_g = 1)
    @test consumed_axis(PoseLibLm(25)) === LossWidth() && consumed_axis(PoseLibLmAdaptLossWidth()) === LossWidth()
    @test consumed_axis(ScoreGuarded(StudentTUniform(max_iter = 2))) === OutlierHalfwidth()
    @test consumed_axis(HQ{WelschShape}(max_iter = 2, scale_multiple = 1.0)) === OutlierHalfwidth()
    @test consumed_native(PoseLibLm(25), LossWidth(), 0.2; d_g = 1) === 0.2
    @test LoRefitSpec("x", PoseLibLm(25), LossWidth(), [1.0, 2.0, 3.0], idxs).axis === LossWidth()
    # tuned ≡ deployed at ζ = 1: a scale-multiple arm's evaluation native is the
    # selection native on the refiner's own axis
    grids = Dict(:outlier_halfwidth => [0.5, 1.0, 2.0], :loss_width => [0.1, 0.2, 0.4], :scale_multiple => [1.5, 2.5])
    idxs_of = Dict(:ig => ones(Int32, 1, 3), :msac => ones(Int32, 1, 3))
    arms = [ComposedSpec("IG+Welsch", :ig, OutlierHalfwidth(), ScaleMultiple(), m -> HQ{WelschShape}(; scale_multiple = m)),
            ComposedSpec("MSAC+TLS-LM", :msac, LossWidth(), ScaleMultiple(), m -> PoseLibLm(25))]
    for arm in arms, c in 1:3
        sel = grids[width_axis_name(arm.selection)][c]
        ro = miscal_evaluation_refit(arm, idxs_of, (selection = sel, width = 2.5), [1.0], grids; d_g = 1)
        @test only(ro.natives) == consumed_native(arm.ctor(2.5), arm.selection, sel; d_g = 1)
        @test ro.axis === arm.selection
    end
end

@testset "apply_lo_refits: the task-space shape cannot move a cell" begin
    rng = MersenneTwister(20261003)
    pairs = [first(epair(rng)) for _ in 1:3]
    hw = [0.005, 0.01, 0.02, 0.04, 0.08]
    idxs = Int32[j % 4 for j in 1:3, _ in 1:5]                 # some 0 ⇒ no consensus
    specs = [LoRefitSpec("IG  +Lift|w=$i", HQ{WelschShape}(; max_iter = 5, scale_multiple = m),
                         OutlierHalfwidth(), hw, idxs) for (i, m) in enumerate((1.0, 2.0))]
    push!(specs, LoRefitSpec("IG  +LO", StudentTUniform(max_iter = 5), OutlierHalfwidth(), hw, idxs))
    push!(specs, LoRefitSpec("IG  +TLS-LM", PoseLibLm(5), OutlierHalfwidth(), hw, idxs))
    push!(specs, LoRefitSpec("IG  sel", NoLocalOptimization(), OutlierHalfwidth(), hw, idxs))
    threaded = apply_lo_refits(P, specs, pairs; scoring = TEMPLATE)
    for sp in specs
        @test isequal(threaded[sp.label], only(values(apply_lo_refits(P, [sp], pairs; scoring = TEMPLATE))))
        @test size(threaded[sp.label]) == (3, 5)
    end
    @test isempty(apply_lo_refits(P, LoRefitSpec[], pairs))
end

@testset "sample-budget engine" begin
    pair, R = synthetic_e_pool_pair()      # 25 minimal samples: two carry 2 siblings, 23 carry 1
    cfg = SampleBudgetConfig(; sample_cap = 20, batch_size = 5, lo_every = 10, budget_unit = :models,
                             lo_strategy = StudentTUniform(max_iter = 2))
    methods = [SampleBudgetMethodSpec(:jeffreys, marginal(0.01)), SampleBudgetMethodSpec(:wide, marginal(0.03))]
    msac = [MsacSpec(:msac, 0.1, PoseLibLm(lo_iteration_budget()))]
    @testset "per pair: shapes, sample boundaries, the MSAC column" begin
        res = evaluate_sample_budget(P, methods, [pair], [R]; pair_ids = ["synth-1"], msac_specs = msac, cfg)
        @test res.methods == [:jeffreys, :wide, :msac, :oracle]
        # one scale prior per evaluation: the per-pair context (and every refit) carries one template
        @test_throws ArgumentError evaluate_sample_budget(P,
            [methods[1], SampleBudgetMethodSpec(:ig_mle, StudentTUniformScoring(P, 0.01; prior = IGPrior(3.0, 0.001)))],
            [pair], [R]; cfg)
        @test size(res.err_batch) == (1, 4, 4) && size(res.err_lo) == (1, 4, 3)
        @test all(0 .<= res.best_idx_batch .<= num_models(pair))
        @test !any(isnan, res.err_batch)
        cfg_s = SampleBudgetConfig(; sample_cap = 20, batch_size = 20, lo_every = 20, budget_unit = :samples,
                                   lo_strategy = StudentTUniform(max_iter = 2))
        starts = sample_starts(starts_pool([pair], 25))
        res_s = evaluate_sample_budget(P, methods[1:1], [pair], [R];
                                       msac_specs = msac, cfg = cfg_s, sample_starts = starts)
        msac_best = best_pool_model(MsacScoring(1; threshold = 0.1), subpair(pair, 1:22), R[:, 1:22])
        @test res_s.best_idx_batch[1, 2, end] == msac_best      # 20 samples reach model 22
        @test_throws DimensionMismatch evaluate_sample_budget(P, methods, [pair], typeof(R)[]; cfg)
        # a :samples budget counts through VisualGeometryEval's sample starts, never on its own
        @test_throws ArgumentError evaluate_sample_budget(P, methods[1:1], [pair], [R]; cfg = cfg_s)
    end
    @testset "LO timing summary" begin
        res = evaluate_sample_budget(P, methods[1:1], [pair], [R]; pair_ids = ["synth-rt"], cfg)
        @test [t.method for t in summarize_lo_timing(res)] == [:jeffreys, :oracle]
    end
end

@testset "budget selectors refit at the arm's refinement native" begin
    # An outlier-half-width arm (IG +LO, IG +BCD) selects at a* and refits at its
    # TUNED half-width: the refit scoring is the template at nat′, not the
    # selector's selection scoring (until 2026-10-07 the budget engine refit them at a*).
    pair, _ = epair(MersenneTwister(7))
    ctx = build_pair_ctx(P, pair; scoring = TEMPLATE)
    a = 0.01; w = 0.04
    sc = marginal(a)
    n = num_points(pair)
    sel = ScoreSelector(:ig, sc, a, scoring_workspace(sc, n, 1), Vector{Float64}(undef, n))
    sel.best_idx = 3
    seed = refit_seed(ctx, pair.models[3])
    for lo in (StuTuBCD(max_iter = 25), StudentTUniform(max_iter = 25))
        cfg(nat_ref) = SampleBudgetConfig(; sample_cap = 12, batch_size = 12, lo_every = 12,
                                          budget_unit = :models, lo_strategy = lo, nat_ref)
        at_w = first(refit_imc!(ctx, lo, seed, w))
        at_a = first(refit_imc!(ctx, lo, seed, a))
        @test at_w != at_a                                    # the fixture separates the two widths
        @test first(lo_error!(ctx, sel, cfg(w))) === Float32(at_w)
        @test first(lo_error!(ctx, sel, cfg(nothing))) === Float32(at_a)   # no refinement native: a*
        oracle = OracleSelector(:oracle, a); oracle.best_idx = 3
        @test first(lo_error!(ctx, oracle, cfg(w))) === Float32(at_w)
        # the scoring is a TEMPLATE: rebuilt at nat′, whatever width it carries
        @test first(refit_imc!(ctx, lo, seed, w; scoring = sc)) === at_w
    end
end

@testset "budget engine at the full budget ≡ the miscal evaluation at ζ = 1" begin
    # Every arm kind of a composed roster: the budget engine's LO at the last
    # checkpoint (every pool model inspected) reproduces, bitwise, the miscal
    # evaluation's ζ = 1 column (`miscal_evaluation_refit` → `apply_lo_refits`).
    rng = MersenneTwister(20261007)
    prs = [epair(rng) for _ in 1:4]
    pairs = first.(prs); Rs = last.(prs)
    halfwidths = [0.005, 0.01, 0.02, 0.04]; a = halfwidths[2]
    grids = Dict(:outlier_halfwidth => halfwidths, :scale_multiple => [1.0, 2.0, 3.0],
                 :loss_width => [0.001, 0.002, 0.004])
    idxs = Matrix{Int32}(undef, length(pairs), length(halfwidths))
    select_on_grid!(idxs, P, TEMPLATE, halfwidths, stage_selection(selection_staging(TEMPLATE), pairs, Rs; backend = CPU))
    idxs_of = Dict(:ig => idxs)
    bcd = _ -> StuTuBCD(max_iter = 25)
    arms = [ComposedSpec("IG  +LO", :ig, OutlierHalfwidth(), OutlierHalfwidth(), _ -> StudentTUniform(max_iter = 25)) => 0.03,
            ComposedSpec("IG  +BCD", :ig, OutlierHalfwidth(), OutlierHalfwidth(), bcd) => 0.04,
            ComposedSpec("IG  +BCD@a*", :ig, OutlierHalfwidth(), OutlierHalfwidth(), bcd; source = SelectionWidth()) => nothing,
            ComposedSpec("IG  +Lift", :ig, OutlierHalfwidth(), ScaleMultiple(),
                         m -> HQ{WelschShape}(max_iter = 25, scale_multiple = m)) => 2.0,
            ComposedSpec("IG  +PoseLib", :ig, OutlierHalfwidth(), LossWidth(), _ -> PoseLibLm(25)) => 0.002]
    budget = Dict{String,Vector{Float32}}()
    for (arm, tuned_width) in arms
        width = operating_width(arm, a, tuned_width)
        spec = miscal_evaluation_refit(arm, idxs_of, (selection = a, width = tuned_width), [1.0], grids; d_g = 1)
        miscal = only(values(apply_lo_refits(P, [spec], pairs; scoring = TEMPLATE)))
        ref = deployed_ref(arm.kind, a, width)
        nat = arm.kind isa ScaleMultiple ? (;) : (; nat_ref = ref, nat_axis = arm.kind)
        cfg = SampleBudgetConfig(; sample_cap = 12, batch_size = 4, lo_every = 4, budget_unit = :models,
                                 lo_strategy = arm.ctor(width), nat...)
        r = evaluate_sample_budget(P, [SampleBudgetMethodSpec(:ig, marginal(a))], pairs, Rs; cfg)
        @test r.best_idx_batch[:, 1, end] == idxs_of[:ig][:, 2]     # one seed: the full pool's a* selection
        budget[arm.base] = r.err_lo[:, 1, end]
        @test all(isfinite, miscal) && budget[arm.base] == Float32.(miscal[:, 1])
    end
    @test budget["IG  +BCD"] != budget["IG  +BCD@a*"]                # their refit widths differ
end

@testset "live runs: the refit half-width in the loop" begin
    ctxs = [build_pair_ctx(P, first(epair(MersenneTwister(100 + i)))) for i in 1:12]
    @test all(c -> c.pair.snn === nothing, ctxs)             # the fixture carries no SNN: uniform sampler
    a = 0.02
    sc = marginal(a)
    run(lo) = live_runs(sc, lo, ctxs; problem_of = pair -> EssentialProblem(pair), seed_of = j -> 7 + j,
                        warmup = false)
    for lo in (StuTuBCD(max_iter = 25), StudentTUniform(max_iter = 25))
        bare = run(lo)
        at_a = run(RefitHalfwidth(lo, a, TEMPLATE))
        @test bare.err == at_a.err && bare.trials == at_a.trials
        @test run(RefitHalfwidth(lo, 3a, TEMPLATE)).err != bare.err
    end
    row = live_row(run(StudentTUniform(max_iter = 25)))
    @test 0 <= row.maa <= 1 && row.n_eligible == 12
end

@testset "stream_selections: the marginal and MSAC on RSDR's grid kernels" begin
    rng = MersenneTwister(20261001)
    prs = [epair(rng) for _ in 1:3]
    pairs = first.(prs); Rs = last.(prs)
    scene(r) = ((pairs = pairs[r],), PoolResiduals("k", :tangent_sampson, Rs[r]))
    loaders = [() -> scene(1:2), () -> scene(3:3)]
    halfwidths = grid(1.0e-3, 1.0, LinearCount(7))
    loss_widths = grid(1.0e-3, 1.0, LinearCount(5))
    ig = TEMPLATE
    msac = loss_width_scoring(:msac, codimension(P))
    refits_of = (idxs_of, _) -> [
        LoRefitSpec("IG  sel", NoLocalOptimization(), OutlierHalfwidth(), halfwidths, idxs_of[:ig]),
        LoRefitSpec("MSAC sel", NoLocalOptimization(), LossWidth(), loss_widths, idxs_of[:msac]),
    ]
    M, s2, np = stream_selections(refits_of, Float64, P, loaders,
                                  [:ig => (halfwidths, ig), :msac => (loss_widths, msac)], TEMPLATE, CPU, 1)
    @test np == [2, 1] && s2 == [[EPAIR_GT_VARIANCE, EPAIR_GT_VARIANCE], [EPAIR_GT_VARIANCE]]
    @test Set(keys(M)) == Set(["IG  sel", "MSAC sel"])
    for (si, r) in enumerate((1:2, 3:3))
        # one batch = the whole scene
        sel(sc, ws) = (idxs = Matrix{Int32}(undef, length(r), length(ws));
                       select_on_grid!(idxs, P, sc, ws, stage_selection(selection_staging(sc), pairs[r], Rs[r]; backend = CPU)))
        idxs_of = Dict(:ig => sel(ig, halfwidths), :msac => sel(msac, loss_widths))
        want = apply_lo_refits(P, refits_of(idxs_of, si), pairs[r]; scoring = TEMPLATE)
        @test M["IG  sel"][si] == want["IG  sel"] && M["MSAC sel"][si] == want["MSAC sel"]   # batching is pair-local
        @test all(isfinite, M["IG  sel"][si])
    end
end

@testset "miscal evaluation: the fixed external scale port" begin
    pair, _ = epair(MersenneTwister(7))
    arm = ComposedSpec("IG  +Lift", :ig, OutlierHalfwidth(), ScaleMultiple(),
                       m -> HQ{WelschShape}(; max_iter = 25, scale_multiple = m))
    grids = Dict(:outlier_halfwidth => [0.005, 0.01, 0.02], :scale_multiple => [1.0, 2.0, 3.0],
                 :loss_width => [0.001, 0.002, 0.004])
    idxs_of = Dict(:ig => fill(Int32(3), 1, 3))
    tuned = (selection = grids[:outlier_halfwidth][2], width = grids[:scale_multiple][2])
    zetas = [0.25, 1.0, 4.0]
    s0 = 2.0e-3
    with = miscal_evaluation_refit(arm, idxs_of, tuned, zetas, grids; d_g = 1)
    without = miscal_evaluation_refit(arm, idxs_of, tuned, zetas, grids; d_g = 1, plugin_scale = s0)
    @test with.fixed_s2s === nothing && without.fixed_s2s == [(ζ * s0)^2 for ζ in zetas]
    @test without.natives == with.natives && without.seedcols == with.seedcols
    M_with = only(values(apply_lo_refits(P, [with], [pair]; scoring = TEMPLATE)))
    M_without = only(values(apply_lo_refits(P, [without], [pair]; scoring = TEMPLATE)))
    ctx = build_pair_ctx(P, pair; scoring = TEMPLATE)
    seed = refit_seed(ctx, pair.models[3])
    for j in eachindex(zetas)
        @test M_without[1, j] === first(refit_imc!(ctx, with.lo, seed, with.natives[j]; s2 = (zetas[j] * s0)^2))
        @test M_with[1, j] === first(refit_imc!(ctx, with.lo, seed, with.natives[j]))
    end
    lw = ComposedSpec("IG  +PoseLib", :ig, OutlierHalfwidth(), LossWidth(), _ -> PoseLibLm(25))
    @test miscal_evaluation_refit(lw, idxs_of, tuned, zetas, grids; d_g = 1).fixed_s2s === nothing
    @test_throws ArgumentError miscal_evaluation_refit(lw, idxs_of, tuned, zetas, grids; d_g = 1, plugin_scale = s0)
end

@testset "Roster: the gate-enforced readers on the paper's arms" begin
    composed = p -> [
        ComposedSpec("IG  +LO",   :ig, OutlierHalfwidth(), OutlierHalfwidth(), _ -> StudentTUniform(max_iter = 25)),
        ComposedSpec("IG  +Lift", :ig, OutlierHalfwidth(), ScaleMultiple(),
                     m -> HQ{WelschShape}(max_iter = 25, scale_multiple = m)),
        ComposedSpec("MSAC +LZ",  :msac, LossWidth(), LossWidth(), _ -> PoseLibLZ(25)),
        ComposedSpec("IG  +BCD@a*", :ig, OutlierHalfwidth(), OutlierHalfwidth(), _ -> StuTuBCD(max_iter = 25);
                     source = SelectionWidth()),
    ]
    basin = p -> [
        ComposedSpec("IG  +Lift",    :ig, OutlierHalfwidth(), LossWidth(), _ -> HQ{WelschShape}(max_iter = 25, scale_multiple = 1.0)),
        ComposedSpec("IG  +PoseLib", :ig, OutlierHalfwidth(), LossWidth(), _ -> PoseLibLm(25)),
    ]
    roster = Roster(composed, (p; role = :refinement) -> SoloSpec[], basin)
    spec = tuning_spec(Dict{String,Any}("tuning" => Dict{String,Any}("t" => Dict{String,Any}(
        "type" => "windowed_bootstrap", "scale_multiple_window" => Dict("lo" => 1.0, "hi" => 3.3),
        "cross_validation" => Dict{String,Any}("scene_split" => Dict{String,Any}(
            "type" => "registered", "name" => "phototourism"))))), "t")
    gs = Dict{Symbol,GridSpec}(:outlier_halfwidth => SpacedGrid(0.01, 0.1, LinearCount(5)),
                               :loss_width => SpacedGrid(0.001, 0.01, LinearCount(5)),
                               :scale_multiple => SpacedGrid(1.0, 3.3, LinearCount(5)))
    g = Dict(k => grid(v) for (k, v) in gs)
    window = ScaleMultipleWindow(1.0, 3.3)
    function write_sidecar(path, arms; mode, hits = Dict(a.base => String[] for a in arms))
        save_tuning_artifact(path, spec; grids = gs, unit = PairUnit(), code = (LODR,), mode, problem = "E",
            d_g = 1, s0 = 0.001, arms = [a.base for a in arms],
            tuned_selection = Dict(a.base => g[width_axis_name(a.selection)][3] for a in arms),
            tuned_width = Dict(a.base => g[width_axis_name(a.kind)][3] for a in arms),
            tuned_objective = Dict(a.base => 0.0 for a in arms), boundary_hits = hits,
            windows = Dict(a.base => tuning_table(window) for a in arms))
    end
    mktempdir() do dir
        cpath = joinpath(dir, "composed.jld2"); write_sidecar(cpath, composed(:E); mode = "miscal")
        bud = Dict(deployed_budget_settings(roster, cpath))
        @test bud["IG  +Lift"].ref == bud["IG  +Lift"].sel                 # scale multiple: refit at the selection native
        @test bud["MSAC +LZ"].ref == g[:loss_width][3]                      # a native width at its tuned value
        @test bud["IG  +Lift"].kind === ScaleMultiple() && bud["MSAC +LZ"].kind === LossWidth()   # the roster's kind
        @test bud["IG  +Lift"].lo == HQ{WelschShape}(max_iter = 25, scale_multiple = g[:scale_multiple][3])
        @test bud["IG  +BCD@a*"].ref == bud["IG  +BCD@a*"].sel == g[:outlier_halfwidth][3]   # pinned at a*
        @test Dict(deployed_arm_settings(roster, cpath))["MSAC +LZ"][2] == g[:loss_width][3]
        @test audit_operating_points(roster, cpath)
        @test_throws ErrorException deployed_basin_settings(roster, cpath)

        bpath = joinpath(dir, "basin.jld2"); write_sidecar(bpath, basin(:E); mode = "basin")
        dep = Dict(deployed_basin_settings(roster, bpath))
        @test dep["IG  +PoseLib"].spec.axis === LossWidth() && dep["IG  +PoseLib"].width == g[:loss_width][3]
        @test audit_operating_points(roster, bpath)
        @test_throws ErrorException deployed_budget_settings(roster, bpath)

        epath = joinpath(dir, "clipped.jld2")
        write_sidecar(epath, composed(:E); mode = "miscal",
                      hits = Dict(a.base => (a.base == "MSAC +LZ" ? ["loss_width_hi"] : String[]) for a in composed(:E)))
        err = try deployed_budget_settings(roster, epath) catch e; e end
        @test occursin("MSAC +LZ", err.msg) && occursin("expand the window on the flagged side", err.msg)
        @test_throws ErrorException audit_operating_points(roster, epath)

        # a selection-width arm whose record carries another width is refused
        mpath = joinpath(dir, "mispinned.jld2")
        save_tuning_artifact(mpath, spec; grids = gs, unit = PairUnit(), code = (LODR,), mode = "miscal",
            problem = "E", d_g = 1, arms = ["IG  +BCD@a*"],
            tuned_selection = Dict("IG  +BCD@a*" => g[:outlier_halfwidth][3]),
            tuned_width = Dict("IG  +BCD@a*" => g[:outlier_halfwidth][4]),
            tuned_objective = Dict("IG  +BCD@a*" => 0.0), boundary_hits = Dict("IG  +BCD@a*" => String[]))
        @test_throws ArgumentError deployed_budget_settings(roster, mpath)

        # a scale-multiple arm on the basin roster is refused
        bad = Roster(composed, roster.solo, p -> composed(p))
        @test_throws ErrorException deployed_basin_settings(bad, bpath)
    end
end

end # @testset

end # module EngineIntegration
