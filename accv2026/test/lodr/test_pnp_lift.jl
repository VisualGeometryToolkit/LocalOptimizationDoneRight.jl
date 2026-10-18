# =============================================================================
# test_pnp_lift.jl — smoke + parity gate for the PnP (absolute-pose) loss
# lift: test_homography_lift.jl's battery (LiftChecks) on the absolute pose.
#
# Gates (the acceptance battery for the 6-dof joint-(θ,z) lift port):
#   1. Full production `ransac()` with StudentTUniformScoring converges on a
#      calibrated synthetic (150 noisy inliers in a frustum + 100 uniform
#      2D-3D outlier matches) for each LO arm — static Irls{WelschShape},
#      the HQ{K} loss lifts (Welsch, Geman–McClure), and the GNC arm —
#      with small rotation/translation error vs GT and high-tp/low-fp
#      inlier recovery.
#   2. Basin sanity via `locally_optimize` from PERTURBED seeds (pinned
#      rolls about the optical axis — radius-proportional pixel
#      displacement, the absolute-pose analogue of the H test's sl(3)
#      steps): every arm recovers from the near seed; from the far seed
#      the HQ lifts (and GNC) recover where the static Welsch IRLS strands.
#   3. Cheirality stress: a seed pose that puts a cluster of TRUE inliers
#      behind the camera — the lift's per-iteration cheirality guard
#      (problems/p3p.jl header) must decouple them and still converge.
# =============================================================================
# (Moved from VisualGeometryToolkitEstimation's test/pnp_lift_tests.jl with the strategies it tests.)
using Test, Random, LinearAlgebra, StaticArrays
using Rotations: RotMatrix, RotZ, RotXYZ
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: estimate, rotation, translation   # VGC accessors (public)
using RansacScoringDoneRight: StudentTUniformScoring   # owned and exported by RansacScoringDoneRight
using VisualGeometryToolkitEstimation
using LocalOptimizationDoneRight
include("scenes.jl")   # the shared scenes, as modules
using .PoseScenes, .Contamination, .LiftChecks
const RVGP = VisualGeometryToolkitEstimation

@testset "PnP loss lift — smoke + parity" begin
    # --- calibrated synthetic -----------------------------------------------
    cam = CameraModel(; focal = 800.0, pp = (480.0, 360.0))
    R_gt = RotMatrix(RotXYZ(0.15, -0.25, 0.1))
    t_gt = Vec3{Float64}(0.3, -0.2, 0.6)

    # A 2D-3D pair: pixel in the image, depth along its GT viewing ray (PoseScenes).

    # inliers: projected + 0.5 px noise; outliers: uniform 2D-3D matches
    rng = MersenneTwister(7)
    n_in, n_out = 150, 100
    pairs, _ = contaminated_pairs(
        rng, (rng, _) -> Pair(frustum_point(rng, cam, R_gt, t_gt)...), n_in; σ = 0.5, n_out,
        outlier = (rng, _) -> first(frustum_point(rng, cam, R_gt, t_gt)) => SVector(40.0 + 880.0 * rand(rng), 40.0 + 640.0 * rand(rng))
    )
    prob = AbsolutePoseProblem(cam, pairs)
    sc = StudentTUniformScoring(prob, 50.0)
    # A pose within 0.5° and 0.05 scene units of the truth (t_gt ~0.7, depth 4-10).
    function accurate(p)
        @test rotation_error_deg(p, R_gt) < 0.5
        @test translation_error(p, t_gt) < 0.05
    end

    # --- 1. full production ransac() per LO arm ------------------------------
    arms = lift_arms(; welsch_scale_multiple = 1.597, gnc_scale_multiple = 1.0)
    check_lift_ransac(accurate, prob, sc, arms, n_in; seed = 373)

    # --- 2. basin sanity: perturbed seeds ------------------------------------
    # Roll about the camera optical axis + a pinned random translation offset.
    # A roll displaces pixels PROPORTIONAL TO RADIUS from the principal point
    # (center points barely move), so the seed keeps a consensus anchor at
    # angles where a whole-image rotation would slew every inlier outside the
    # scoring half-width — the absolute-pose analogue of the H basin test's
    # spatially-graded corner error.
    seed_roll(angdeg, toff, sd) = begin
        Random.seed!(sd)
        dR = RotMatrix(RotZ(deg2rad(angdeg)))
        EuclideanMap(
            RotMatrix(dR * R_gt),
            Vec3{Float64}((dR * t_gt + toff * normalize(randn(3)))...)
        )
    end
    refit(p0, lo, outlier_halfwidth) = RVGP.locally_optimize(
        prob, p0; local_optimization = lo,
        scoring = StudentTUniformScoring(prob, outlier_halfwidth)
    )

    @testset "near seed — every arm recovers" begin
        p0 = seed_roll(2.0, 0.02, 5)                     # ~28 px displacement at the corners
        @test rotation_error_deg(p0, R_gt) > 1.5                          # genuinely perturbed
        check_lift_recovers(accurate, lo -> refit(p0, lo, 50.0), arms)
    end

    @testset "far seed — HQ recovers where Irls is trapped" begin
        p0 = seed_roll(40.0, 0.15, 5)                    # only ~2 inliers within 150 px
        @test rotation_error_deg(p0, R_gt) > 30.0
        e_irls, e_hqw, e_hqgm, e_gnc = (rotation_error_deg(estimate(refit(p0, lo, 150.0)), R_gt) for (_, lo) in arms)
        @test e_irls > 5.0                               # static IRLS stranded far from GT
        @test e_hqw < 0.5                               # the lift crosses the basin
        @test e_hqgm < 0.5
        @test e_gnc < 1.5                               # graduation crosses it too (lands
        # near, not on, GT at this range)
    end

    # --- 3. cheirality stress: true inliers behind the camera at the seed ----
    # A cluster of near-depth inliers (0.35-0.5) plus the far field (4-10);
    # the seed translates the camera 0.6 forward along its optical axis, which
    # puts the whole near cluster at negative depth. The lift's per-iteration
    # cheirality guard must decouple those rows (zero θ contribution, frozen
    # z, saturated cost entry) and still converge to the GT pose — at which
    # every true inlier is back in front.
    @testset "cheirality stress — behind-camera inliers at the seed" begin
        rng2 = MersenneTwister(21)
        n_near, n_far = 12, 138
        field = (x = (140.0, 820.0), y = (120.0, 600.0))
        pairs2, _ = contaminated_pairs(
            rng2, (rng, i) -> Pair(frustum_point(rng, cam, R_gt, t_gt; field..., depth = i <= n_near ? (0.35, 0.5) : (4.0, 10.0))...),
            n_near + n_far; σ = 0.5, n_out = 100,
            outlier = (rng, _) -> first(frustum_point(rng, cam, R_gt, t_gt; field...)) => SVector(140.0 + 680.0 * rand(rng), 120.0 + 480.0 * rand(rng))
        )
        src2 = first.(pairs2)
        prob2 = AbsolutePoseProblem(cam, pairs2)
        sc2 = StudentTUniformScoring(prob2, 150.0)
        p0 = EuclideanMap(R_gt, Vec3{Float64}(t_gt[1], t_gt[2], t_gt[3] - 0.6))
        n_behind = count(i -> (R_gt * src2[i] + translation(p0))[3] <= 0.0, 1:(n_near + n_far))
        @test n_behind >= 10                             # the stress is real
        check_lift_recovers(lo -> RVGP.locally_optimize(prob2, p0; local_optimization = lo, scoring = sc2), arms[2:4]) do p
            accurate(p)
            # every true inlier is back in front of the recovered pose
            @test all(i -> (rotation(p) * src2[i] + translation(p))[3] > 0.0, 1:(n_near + n_far))
        end
    end
end
