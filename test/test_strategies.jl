# =============================================================================
# The strategies on one essential-matrix scene, through the local-optimization
# contract (`locally_optimize!`) directly: the HQ and GNC dispatch of
# src/lift/lifts.jl, the posterior-weight IRLS arms and the score-matched BCD of
# src/strategies/irls.jl, and the essential-matrix research lifts of
# src/strategies/essential.jl.
#
# The scene is VisualGeometryToolkitCore's synthetic two-view scene in pixels
# (focal length 600 px, 500 × 500 px images): 150 matches with 0.5 px noise and
# 50 mismatches. The seed is the true pose perturbed by about 0.006 rad (its
# RMS Sampson error over the 150 matches is 2.2 px, the true model's 0.32 px),
# inside the basin the 2 px MSAC consensus set leads back from: from a seed of
# about 3 px most arms settle on a wrong model (12 px) instead.
#
# Selection is the core MSAC. The posterior-weight arms also need a uniform
# outlier model, which no core scorer has and RANSACScoringDoneRight's
# Student-t + uniform scorer (kept out of this test target by the stack
# allow-list) supplies: `UniformOutlierScoring` is MSAC with an outlier
# half-width, the least a scorer must declare for them. The same strategies on
# the paper's scorer are tested in accv2026/test/lodr.
# =============================================================================
using LinearAlgebra: normalize
using Random: MersenneTwister, randn
using StaticArrays: SA
import VisualGeometryToolkitCore as VgtkCore
using VisualGeometryToolkitCore: AbstractScoring, BarronShape, CameraModel, EssentialMat, GemanMcclureShape, LossWidth,
    MsacScoring, Point2, Rect, EfficiencyConstant, TLSShape, WelschShape, codimension, consensus_set, correspondences, decision_boundary, decision_width,
    deploy, estimate, exp_so3, locally_optimize!, loss_at, lo_width, mahalanobis_distances!, minimal_sample_size, px,
    retcode, scale_s2, score_model!, sq_loss_width, ReturnCode, stop_rule, IncrementSize, LadderConverged, NoImprovement,
    LeftBasin, IterationCap, NoRule
using VisualGeometryToolkitCore.Synthetic: projective_distance, sample_twoview_scene
using VisualGeometryToolkitEstimation: BoundedProblem, EssentialProblem, RansacWorkspace
using VisualGeometryToolkitCore: Irls
using LocalOptimizationDoneRight

# MSAC selection with a uniform outlier model of half-width `halfwidth`.
struct UniformOutlierScoring{S <: AbstractScoring} <: AbstractScoring
    inner::S
    halfwidth::Float64
end
VgtkCore.outlier_halfwidth(s::UniformOutlierScoring) = s.halfwidth
VgtkCore.scoring_workspace(s::UniformOutlierScoring, n::Int, d_g::Int) = VgtkCore.scoring_workspace(s.inner, n, d_g)
VgtkCore.score!(W, s::UniformOutlierScoring, q, r, n::Int; kw...) = VgtkCore.score!(W, s.inner, q, r, n; kw...)
VgtkCore.inlier_count(s::UniformOutlierScoring, W) = VgtkCore.inlier_count(s.inner, W)
VgtkCore.consensus_order(s::UniformOutlierScoring, W) = VgtkCore.consensus_order(s.inner, W)
VgtkCore.decision_boundary(s::UniformOutlierScoring, buf) = VgtkCore.decision_boundary(s.inner, buf)
VgtkCore.has_decision_boundary(::Type{UniformOutlierScoring{S}}) where {S} = VgtkCore.has_decision_boundary(S)
VgtkCore.score_bound(s::UniformOutlierScoring) = VgtkCore.score_bound(s.inner)

# The same scorer with a non-Jeffreys scale prior (its own `scale_prior`), for the test
# that a mixture lift keeps the scoring's prior.
struct PriorScoring{S <: AbstractScoring} <: AbstractScoring
    inner::S
    prior::VgtkCore.IGPrior
end
VgtkCore.scale_prior(s::PriorScoring) = s.prior
VgtkCore.outlier_halfwidth(s::PriorScoring) = VgtkCore.outlier_halfwidth(s.inner)
VgtkCore.scoring_workspace(s::PriorScoring, n::Int, d_g::Int) = VgtkCore.scoring_workspace(s.inner, n, d_g)
VgtkCore.score!(W, s::PriorScoring, q, r, n::Int; kw...) = VgtkCore.score!(W, s.inner, q, r, n; kw...)
VgtkCore.inlier_count(s::PriorScoring, W) = VgtkCore.inlier_count(s.inner, W)
VgtkCore.consensus_order(s::PriorScoring, W) = VgtkCore.consensus_order(s.inner, W)
VgtkCore.decision_boundary(s::PriorScoring, buf) = VgtkCore.decision_boundary(s.inner, buf)
VgtkCore.has_decision_boundary(::Type{PriorScoring{S}}) where {S} = VgtkCore.has_decision_boundary(S)
VgtkCore.score_bound(s::PriorScoring) = VgtkCore.score_bound(s.inner)

const N_IN = 150
rng = MersenneTwister(5)
R, t, _, E_true, matches = sample_twoview_scene(rng, N_IN)
noisy(u) = u + Point2(0.5 * randn(rng), 0.5 * randn(rng))
anywhere() = Point2(500 * rand(rng), 500 * rand(rng))
pairs_px = [[u₁ => noisy(u₂) for (u₁, u₂) in matches]; [anywhere() => anywhere() for _ in 1:50]]
camera = CameraModel(600.0px, SA[250.0px, 250.0px])
problem = EssentialProblem(camera, camera, correspondences(first.(pairs_px), last.(pairs_px)))
msac = MsacScoring(problem; threshold = 2.0)
stu = UniformOutlierScoring(msac, 250.0)
# A fixed perturbation (no RNG: the Random streams differ across Julia versions):
# the rotation by 0.006 rad, the translation direction by about 0.005 rad.
seed = EssentialMat(exp_so3(0.006 * normalize(SA[1.0, -1.0, 0.7])) * R, normalize(t + 0.005 * normalize(SA[1.0, -0.5, 0.8])))

# The RMS Sampson error (px) over the true matches.
function inlier_rms(E)
    d = zeros(length(pairs_px))
    mahalanobis_distances!(d, problem, E)
    return sqrt(sum(abs2, view(d, 1:N_IN)) / N_IN)
end

# The consensus set of `model` under `scoring` (and the workspace that scored it).
function scored_consensus(lo, problem, scoring, model)
    ws = RansacWorkspace(problem, scoring, lo)
    buf = ws.buf
    score_model!(buf, scoring, problem, model)
    cs = consensus_set(scoring, buf.scoring_ws, buf.residuals;
                       model_dof = minimal_sample_size(problem) + 1, d_g = codimension(problem), epoch = buf.epoch)
    return ws, cs
end

# One local optimization from `model`: score it, take its consensus set, refine.
function run_lo(lo, problem, scoring, model)
    ws, cs = scored_consensus(lo, problem, scoring, model)
    return locally_optimize!(ws.lo_ws, lo, problem, model, cs, ws.buf, scoring)
end

@testset "the scene" begin
    @test inlier_rms(E_true) < 0.4
    @test inlier_rms(seed) > 2.0
end

@testset "each strategy recovers the perturbed seed" begin
    arms = (
        HQ{WelschShape}(efficiency_constant = 1.5) => msac,
        HQ{GemanMcclureShape}(efficiency_constant = decision_width(GemanMcclureShape(), 1.5)) => msac,   # half-weight depth 1.5, migrated
        BarronHQ(-2.0; efficiency_constant = 1.5 / sqrt(2.0)) => msac,                                   # the retired m/√2 currency, migrated
        GmHqEps(efficiency_constant = 1.0) => msac,
        Gnc{Irls{TLSShape}}(efficiency_constant = 2.5) => msac,
        WelschHQEcm(efficiency_constant = 1.5) => msac,
        BarronAdaptive(efficiency_constant = 1.5) => msac,
        StuTuBCD() => msac,
        StudentTUniform() => stu,
        StuTuHQTabulated() => stu,
        HQ{WelschShape}(efficiency_constant = 1.5) => stu,
    )
    @testset "$(nameof(typeof(lo)))" for (lo, scoring) in arms
        result = run_lo(lo, problem, scoring, seed)
        @test retcode(result) in (ReturnCode.Success, ReturnCode.MaxIters, ReturnCode.Terminated)
        @test estimate(result) isa EssentialMat
        @test inlier_rms(estimate(result)) < 0.6      # from 2.2 px, the truth's 0.32 px
    end
end

# StuTuRegemm accepts a refit only when it lowers its lifted objective. The
# scene's draws differ across Julia versions, and on Julia 1.12's it stays at
# the seed where on 1.13's it recovers the pose: on both it does not worsen
# the fit to the matches.
@testset "StuTuRegemm improves or keeps the seed" begin
    result = run_lo(StuTuRegemm(), problem, stu, seed)
    @test estimate(result) isa EssentialMat
    @test inlier_rms(estimate(result)) <= inlier_rms(seed) * (1 + 1.0e-6)
end

@testset "the posterior-weight arms refuse a scorer without an outlier model" begin
    for lo in (StudentTUniform(), StuTuHQTabulated(), StuTuRegemm())
        @test_throws ArgumentError run_lo(lo, problem, msac, seed)
    end
end

# The mixture lifts (StuTuHQTabulated, StuTuRegemm) reset the workspace's posterior
# state: its scale prior is the scoring's (`scale_prior(scoring)`, the prior
# consensus_posterior seeds), never Jeffreys by default.
@testset "a mixture lift keeps the scoring's scale prior" begin
    ig = VgtkCore.IGPrior(3.0, 2.0)
    @test ig != VgtkCore.JeffreysPrior()
    sc = PriorScoring(stu, ig)
    ws, cs = scored_consensus(StuTuHQTabulated(), problem, sc, seed)
    _, pws = LocalOptimizationDoneRight._mixture_lift_setup(ws.lo_ws, problem, seed, cs, ws.buf, sc)
    @test pws.prior == ig
    ws, cs = scored_consensus(StuTuHQTabulated(), problem, stu, seed)
    _, pws = LocalOptimizationDoneRight._mixture_lift_setup(ws.lo_ws, problem, seed, cs, ws.buf, stu)
    @test pws.prior == VgtkCore.JeffreysPrior()          # a scorer without a prior: Jeffreys, as before
end

# The §14 record: Core's loop hands `block_coordinate_result` the `stop_rule(criterion, method)` of the criterion that
# FIRED (a composite's member, in Core's order); each criterion of this package states its rule (Estimation's
# no-improvement stop its own). Leaving the basin is Terminated (a success: the incumbent).
@testset "termination record" begin
    LO = LocalOptimizationDoneRight
    @test stop_rule(LO.StopWhenIncrementSmall(), nothing) === IncrementSize
    @test stop_rule(LO.StopWhenLadderConverged(), nothing) === LadderConverged
    @test stop_rule(LO.StopWhenLeftBasin(), nothing) === LeftBasin
    @test LO.lo_termination(:left_basin, LeftBasin) === (ReturnCode.Terminated, LeftBasin)
    @test LO.lo_termination(:max_iterations, IterationCap) === (ReturnCode.MaxIters, IterationCap)
    @test LO.lo_termination(:converged, LadderConverged) === (ReturnCode.Success, LadderConverged)
    @test_throws ArgumentError LO.lo_termination(:no_such_reason, NoRule)
    # LODR#2 (wave-10 catch-up): the rule is the one Core hands over, never re-derived from the final state. Fail-first: 0.6
    # re-ran each composite member's `stop_reason` at the final state (θ as θ_old) to guess the member that fired, so a
    # member whose verdict had changed since (impure, or reading state the last iteration moved) was named instead.
    # Here the state says "improved" — re-evaluating the no-improvement stop answers :continue, the old guess NoRule —
    # while the loop reports that stop fired.
    ws, cs = scored_consensus(StuTuBCD(), problem, msac, seed)
    m = LO.ScoreBcdMethod(msac, ws.lo_ws, ws.buf, 0.0)
    @test stop_rule(LO.StopWhenNoImprovement(1, 1), m) === NoImprovement
    st = LO.ScoreBcdState(VgtkCore.Attributed(seed, (; cost = -1.0)), -1.0, true)
    for (reason, rule, rc) in ((:converged, NoImprovement, ReturnCode.Success), (:max_iterations, IterationCap, ReturnCode.MaxIters))
        r = VgtkCore.block_coordinate_result(st, m, problem, seed, reason, 4, rule)
        @test (retcode(r), stop_rule(r)) === (rc, rule)
    end
    # the arms on the scene
    r = run_lo(HQ{WelschShape}(efficiency_constant = 1.5), problem, msac, seed)
    @test stop_rule(r) in (IncrementSize, IterationCap)
    r = run_lo(Gnc{Irls{TLSShape}}(efficiency_constant = 2.5), problem, msac, seed)
    @test stop_rule(r) in (LadderConverged, IterationCap)
    r = run_lo(StuTuBCD(), problem, msac, seed)
    @test stop_rule(r) in (NoImprovement, IterationCap)
    r = run_lo(StuTuHQTabulated(), problem, stu, seed)
    @test (retcode(r), stop_rule(r)) in ((ReturnCode.Success, NoImprovement), (ReturnCode.Success, IncrementSize),
                                          (ReturnCode.Terminated, LeftBasin), (ReturnCode.MaxIters, IterationCap))
end

@testset "HQ dispatch" begin
    hq = HQ{WelschShape}(efficiency_constant = 1.5)
    welsch = run_lo(hq, problem, msac, seed)
    # BarronHQ standardizes on the Gaussian core, so α → −∞ is HQ{WelschShape}
    # at √2 times its efficiency constant.
    @test projective_distance(estimate(run_lo(BarronHQ(-1.0e12; efficiency_constant = 1.5 / sqrt(2.0)), problem, msac, seed)),
                              estimate(welsch)) < 1.0e-9
    # A BoundedProblem is a validation decorator: the lift refines its inner problem.
    bounded = BoundedProblem(problem, Rect(0.0, 0.0, 500.0, 500.0))
    @test estimate(run_lo(hq, bounded, msac, seed)) == estimate(welsch)
    gnc = Gnc{Irls{TLSShape}}(efficiency_constant = 2.5)
    @test estimate(run_lo(gnc, bounded, msac, seed)) == estimate(run_lo(gnc, problem, msac, seed))
    # The crossover sentinel (a non-positive multiple) is retired.
    @test_throws ArgumentError run_lo(GmHqEps(efficiency_constant = -1.0), problem, msac, seed)
end

@testset "StuTuBCD never lowers the score" begin
    ws = RansacWorkspace(problem, msac, StuTuBCD())
    before, _ = score_model!(ws.buf, msac, problem, seed)
    after, _ = score_model!(ws.buf, msac, problem, estimate(run_lo(StuTuBCD(), problem, msac, seed)))
    @test after >= before
end

# WelschHQNewton is the A/B partner of HQ{WelschShape}, meant to agree with it on
# an easy seed: started at HQ's refined model, it keeps it. (It is not in the
# recovery list above: from the perturbed seed on this pixel scene it returns
# the seed.)
@testset "WelschHQNewton keeps HQ{WelschShape}'s refined model" begin
    refined = estimate(run_lo(HQ{WelschShape}(efficiency_constant = 1.5), problem, msac, seed))
    kept = estimate(run_lo(WelschHQNewton(efficiency_constant = 1.5), problem, msac, refined))
    @test projective_distance(kept, refined) < 1.0e-6
    @test inlier_rms(kept) < 0.4
end

# Every robust width resolves through ONE schema, VisualGeometryToolkitCore's
# `loss_at`: no strategy keeps a private width rule.
@testset "widths resolve through VGC's loss_at" begin
    ws, cs = scored_consensus(StuTuBCD(), problem, msac, seed)
    buf = ws.buf
    s2 = max(scale_s2(cs), eps())
    # BarronAdaptive's frozen α-fit width: loss_at at the reference shape
    # BarronShape(0) — bit-identical to m²·ŝ² and m₀²·s2 under a width ...
    w2(lo) = LocalOptimizationDoneRight._barron_sq_width(lo, cs, msac, buf)
    @test w2(BarronAdaptive(efficiency_constant = 1.5)) === 1.5^2 * s2
    @test w2(BarronAdaptive(loss_width = 2.0)) === 2.0^2
    # ... and, following the scorer, the reference shape's DECISION width at the
    # threshold (Cauchy deciding at t: c² = t²/2), not the threshold itself
    @test w2(BarronAdaptive()) == decision_width(BarronShape(0.0), 2.0)^2
    @test w2(BarronAdaptive()) ≈ 2.0^2 / 2
    # The derivation (LODR#1, wave-10 catch-up review): with no width the α-fit's Barron scale is the one
    # whose decision flips at the scorer's decision point, like every other arm's no-width width
    # (Core's `loss_at`). 0.5.1's t² read the threshold AS the Barron scale: that scale decides at √2·t.
    @test decision_boundary(BarronShape(0.0), sqrt(w2(BarronAdaptive()))) ≈ decision_boundary(msac, buf)
    @test !(decision_boundary(BarronShape(0.0), 2.0) ≈ decision_boundary(msac, buf))
    # Welsch-HQ-ECM: its one width mode is its efficiency constant, deployed by loss_at
    ecm = WelschHQEcm(efficiency_constant = 1.5)
    @test lo_width(ecm) == EfficiencyConstant(1.5)
    @test loss_at(ecm, WelschShape(), cs, msac, buf) === deploy(WelschShape(), s2; efficiency_constant = 1.5)
    @test_throws MethodError VgtkCore.with_width(ecm, LossWidth(1.0))   # a self-scaling arm: no other mode
end
