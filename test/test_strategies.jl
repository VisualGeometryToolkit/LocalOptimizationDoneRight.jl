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
using VisualGeometryToolkitCore: AbstractScoring, CameraModel, EssentialMat, GemanMcclureShape, MsacScoring,
    Point2, Rect, TLSShape, WelschShape, codimension, consensus_set, csponds, estimate, exp_so3, locally_optimize!,
    mahalanobis_distances!, minimal_sample_size, px, retcode, score_model!
using VisualGeometryToolkitCore.Synthetic: projective_distance, sample_twoview_scene
using VisualGeometryToolkitEstimation: BoundedProblem, EssentialProblem, Irls, RansacWorkspace
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
VgtkCore.inlier_threshold(s::UniformOutlierScoring, buf) = VgtkCore.inlier_threshold(s.inner, buf)
VgtkCore.has_inlier_threshold(::Type{UniformOutlierScoring{S}}) where {S} = VgtkCore.has_inlier_threshold(S)
VgtkCore.score_bound(s::UniformOutlierScoring) = VgtkCore.score_bound(s.inner)

const N_IN = 150
rng = MersenneTwister(5)
R, t, _, E_true, matches = sample_twoview_scene(rng, N_IN)
noisy(u) = u + Point2(0.5 * randn(rng), 0.5 * randn(rng))
anywhere() = Point2(500 * rand(rng), 500 * rand(rng))
pairs_px = [[u₁ => noisy(u₂) for (u₁, u₂) in matches]; [anywhere() => anywhere() for _ in 1:50]]
camera = CameraModel(600.0px, SA[250.0px, 250.0px])
problem = EssentialProblem(camera, camera, csponds(first.(pairs_px), last.(pairs_px)))
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

# One local optimization from `model`: score it, take its consensus set, refine.
function run_lo(lo, problem, scoring, model)
    ws = RansacWorkspace(problem, scoring, lo)
    buf = ws.buf
    score_model!(buf, scoring, problem, model)
    cs = consensus_set(scoring, buf.scoring_ws, buf.residuals;
                       model_dof = minimal_sample_size(problem) + 1, d_g = codimension(problem), epoch = buf.epoch)
    return locally_optimize!(ws.lo_ws, lo, problem, model, cs, buf, scoring)
end

@testset "the scene" begin
    @test inlier_rms(E_true) < 0.4
    @test inlier_rms(seed) > 2.0
end

@testset "each strategy recovers the perturbed seed" begin
    arms = (
        HQ{WelschShape}(scale_multiple = 1.5) => msac,
        HQ{GemanMcclureShape}(scale_multiple = 1.5) => msac,
        BarronHQ(-2.0; scale_multiple = 1.5) => msac,
        GmHqEps(scale_multiple = 1.0) => msac,
        Gnc{Irls{TLSShape}}(scale_multiple = 2.5) => msac,
        WelschHQEcm(scale_multiple = 1.5) => msac,
        BarronAdaptive(scale_multiple = 1.5) => msac,
        StuTuBCD() => msac,
        StudentTUniform() => stu,
        StuTuHQTabulated() => stu,
        HQ{WelschShape}(scale_multiple = 1.5) => stu,
    )
    @testset "$(nameof(typeof(lo)))" for (lo, scoring) in arms
        result = run_lo(lo, problem, scoring, seed)
        @test retcode(result) in (:converged, :max_iterations, :no_improvement, :left_basin)
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

@testset "HQ dispatch" begin
    hq = HQ{WelschShape}(scale_multiple = 1.5)
    welsch = run_lo(hq, problem, msac, seed)
    # BarronHQ standardizes on the Gaussian core, so α → −∞ is HQ{WelschShape}
    # at the same scale multiple.
    @test projective_distance(estimate(run_lo(BarronHQ(-1.0e12; scale_multiple = 1.5), problem, msac, seed)),
                              estimate(welsch)) < 1.0e-9
    # A BoundedProblem is a validation decorator: the lift refines its inner problem.
    bounded = BoundedProblem(problem, Rect(0.0, 0.0, 500.0, 500.0))
    @test estimate(run_lo(hq, bounded, msac, seed)) == estimate(welsch)
    gnc = Gnc{Irls{TLSShape}}(scale_multiple = 2.5)
    @test estimate(run_lo(gnc, bounded, msac, seed)) == estimate(run_lo(gnc, problem, msac, seed))
    # The crossover sentinel (a non-positive multiple) is retired.
    @test_throws ArgumentError run_lo(GmHqEps(scale_multiple = -1.0), problem, msac, seed)
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
    refined = estimate(run_lo(HQ{WelschShape}(scale_multiple = 1.5), problem, msac, seed))
    kept = estimate(run_lo(WelschHQNewton(scale_multiple = 1.5), problem, msac, refined))
    @test projective_distance(kept, refined) < 1.0e-6
    @test inlier_rms(kept) < 0.4
end
