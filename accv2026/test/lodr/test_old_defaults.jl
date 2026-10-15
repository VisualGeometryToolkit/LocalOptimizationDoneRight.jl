# =============================================================================
# The find_* pipelines under the paper's per-class recipes — the defaults of
# RobustVisualGeometry's find_* before 2026-10, now stated explicitly: the
# Welsch HQ lift at the class's cross-validated scale multiple,
#
#     local_optimization = HQ{WelschShape}(scale_multiple = tuning_constant(class, "welsch").scale_multiple)
#
# with their default scorer of that time, the Jeffreys Student-t + uniform
# marginal at the class's file outlier half-width (`old_scoring`; the core
# default is now MSAC at a threshold convention, RobustVisualGeometry b5194da).
#
# Same scenes, seeds and bounds as RobustVisualGeometry's fitting_pipelines
# item (moved from there with the recipes; that item now pins the core
# default, Irls{TLSShape}).
# =============================================================================
using Test
using LinearAlgebra
using StaticArrays
using StructArrays
using Random
using Rotations: RotMatrix, RotXYZ, RotY
using VisualGeometryCore
using VisualGeometryCore: converged, estimate, rotation, translation   # VGC accessors (public)
using RobustVisualGeometry: RansacWorkspace   # public, not exported
using RansacScoringDoneRight: StudentTUniformScoring, Predictive   # owned and exported by RansacScoringDoneRight
using RobustVisualGeometry
using LocalOptimizationDoneRight
include("scenes.jl")   # the shared scenes, as modules
using .EpipolarScenes, .HomographyScenes, .PoseScenes, .Contamination

# The paper's per-class recipe.
welsch_hq(class) = HQ{WelschShape}(scale_multiple = tuning_constant(class, "welsch").scale_multiple)
# The find_* default scorer before 2026-10: the marginal at the class's
# `[pipelines.<class>] outlier_halfwidth` of RobustVisualGeometry's
# configs/default.toml then (pixels; hand-eye a fraction of the problem's L).
const OLD_OUTLIER_HALFWIDTH = Dict(:homography => 20.0, :fundmat => 50.0, :essential => 20.0, :absolute_pose => 5.0, :hand_eye => 0.05)
old_scoring(problem, class) = StudentTUniformScoring(problem, OLD_OUTLIER_HALFWIDTH[class])
old_scoring(problem::HandEyeProblem, ::Symbol) = StudentTUniformScoring(problem, OLD_OUTLIER_HALFWIDTH[:hand_eye] * problem.char_length)

@testset "fitting pipelines (the per-class Welsch HQ recipes)" begin

    @testset "find_homography" begin
        H = SMatrix{3, 3, Float64, 9}(H_PX)
        src, dst = homography_pairs(                  # inliers: exact transfer + 0.3 px; outliers: unrelated pairs
            MersenneTwister(11), H_PX; n_in = 120, n_out = 60, σ = 0.3,
            source = gaussian_source, target = rng -> randn(rng, 2) .* 400 .+ 300
        )

        hsc = old_scoring(HomographyProblem(StructArray(src .=> dst)), :homography)
        r = find_homography(StructArray(src .=> dst); scoring = hsc, local_optimization = welsch_hq(:homography), rng = MersenneTwister(134))
        @test r !== nothing
        @test converged(r)
        # Every inlier sits in the first 120 slots; demand most of them back
        # and almost no outlier admitted.
        @test count(r.inlier_mask[1:120]) > 100
        @test count(r.inlier_mask[121:end]) < 20
        Ĥ = estimate(r) / estimate(r)[3, 3]
        @test norm(Ĥ - H / H[3, 3]) / norm(H / H[3, 3]) < 1.0e-2

        # A pre-allocated workspace must give the same answer as an internal one:
        # the same draws (same seed as `r`), the same model and consensus — and
        # again when the workspace is reused.
        ws = RansacWorkspace(HomographyProblem{Float64}, length(src), hsc)   # the scorer's workspace
        for _ in 1:2
            r2 = find_homography(StructArray(src .=> dst); scoring = hsc, workspace = ws, local_optimization = welsch_hq(:homography), rng = MersenneTwister(134))
            @test r2 !== nothing && converged(r2)
            @test estimate(r2) == estimate(r)
            @test r2.inlier_mask == r.inlier_mask
            @test r2.quality == r.quality
        end

        # Below the minimal sample the wrapper returns nothing, it does not throw.
        @test find_homography(StructArray(src[1:3] .=> dst[1:3]); scoring = hsc, local_optimization = welsch_hq(:homography), rng = MersenneTwister(136)) === nothing
    end

    @testset "find_fundmat" begin
        cam = CameraModel(; focal = 800.0, pp = (480.0, 360.0))
        u₁, u₂ = stereo_pixel_pairs(                  # inliers: 0.4 px in view 2; outliers: uniform pairs
            MersenneTwister(13), cam, cam, RotMatrix(RotXYZ(0.05, 0.12, -0.03)), SVector{3, Float64}(0.9, 0.05, 0.1);
            n = 140, σ₂ = 0.4, n_out = 60,
            point = rng -> SA[2.0 * (rand(rng) - 0.5), 1.5 * (rand(rng) - 0.5), 4.0 + 3.0 * rand(rng)],
            outlier = rng -> (SA[960 * rand(rng), 720 * rand(rng)], SA[960 * rand(rng), 720 * rand(rng)])
        )
        n_in = length(u₁) - 60

        fsc = old_scoring(FundMatProblem(StructArray(u₁ .=> u₂)), :fundmat)
        r = find_fundmat(StructArray(u₁ .=> u₂); scoring = fsc, local_optimization = welsch_hq(:fundmat), rng = MersenneTwister(137))
        @test r !== nothing
        @test converged(r)
        @test count(r.inlier_mask[1:n_in]) > 0.75 * n_in
        # A fundamental matrix is rank 2.
        F = SMatrix{3, 3, Float64}(estimate(r))
        @test abs(det(F)) / norm(F)^3 < 1.0e-6
        # Recovered inliers satisfy their own epipolar constraint tightly.
        for i in 1:n_in
            r.inlier_mask[i] || continue
            @test sampson_distance(estimate(r), u₁[i], u₂[i]) < 5.0
        end

        ws = RansacWorkspace(FundMatProblem{Float64}, length(u₁), fsc)   # the scorer's workspace
        @test find_fundmat(StructArray(u₁ .=> u₂); scoring = fsc, workspace = ws, local_optimization = welsch_hq(:fundmat), rng = MersenneTwister(138)) !== nothing
    end

    @testset "find_essential" begin
        rng = MersenneTwister(17)                     # calibrated points + 0.002 noise, then 50 outliers
        u₁, u₂ = calibrated_pairs(rng, RotY(0.2), normalize(SA[0.8, 0.1, 0.3]); n = 120, σ = 0.002)
        n_in = length(u₁)
        for _ in 1:50
            push!(u₁, Point2{Float64}(randn(rng), randn(rng)))
            push!(u₂, Point2{Float64}(randn(rng), randn(rng)))
        end

        # Calibrated points moved into the PIXEL domain of ECAM: `find_essential`
        # takes pixels and the cameras that produced them, and its threshold is
        # in pixels too.
        pxcs = csponds(topx.(u₁), topx.(u₂))
        esc = old_scoring(EssentialProblem(ECAM, ECAM, pxcs), :essential)
        r = find_essential(ECAM, ECAM, pxcs; scoring = esc, local_optimization = welsch_hq(:essential), rng = MersenneTwister(139))
        @test r !== nothing
        @test converged(r)
        @test count(r.inlier_mask[1:n_in]) > 0.75 * n_in
        # An essential matrix has two equal singular values and one zero.
        s = svd(SMatrix{3, 3, Float64}(estimate(r))).S
        @test abs(s[1] - s[2]) / s[1] < 1.0e-6
        @test s[3] / s[1] < 1.0e-6

        @test find_essential(
            ECAM, ECAM, csponds(topx.(u₁[1:4]), topx.(u₂[1:4])); scoring = esc, local_optimization = welsch_hq(:essential), rng = MersenneTwister(140)
        ) === nothing
        # The floor refusal: a threshold carried over in the OLD calibrated
        # units is rejected, not silently honoured 800x too tight.
        @test_throws ArgumentError find_essential(ECAM, ECAM, pxcs; threshold = 0.02)
    end

    @testset "find_absolute_pose" begin
        cam = CameraModel(; focal = 800.0, pp = (480.0, 360.0))
        R_gt = RotMatrix(RotXYZ(0.15, -0.25, 0.1))
        t_gt = Vec3{Float64}(0.3, -0.2, 0.6)
        pairs, _ = contaminated_pairs(                   # inliers: frustum points + 0.5 px; outliers: uniform 2D-3D matches
            MersenneTwister(19), (rng, _) -> Pair(frustum_point(rng, cam, R_gt, t_gt)...), 120; σ = 0.5, n_out = 60,
            outlier = (rng, _) -> first(frustum_point(rng, cam, R_gt, t_gt)) => SVector(40.0 + 880.0 * rand(rng), 40.0 + 640.0 * rand(rng))
        )
        src, dst = first.(pairs), last.(pairs)

        psc = old_scoring(AbsolutePoseProblem(cam, StructArray(src .=> dst)), :absolute_pose)
        r = find_absolute_pose(cam, StructArray(src .=> dst); scoring = psc, local_optimization = welsch_hq(:absolute_pose), rng = MersenneTwister(141))
        @test r !== nothing
        @test converged(r)
        @test count(r.inlier_mask[1:120]) > 100
        @test rotation_error_deg(estimate(r), R_gt) < 1.0
        @test translation_error(estimate(r), t_gt) < 0.05

        ws = RansacWorkspace(AbsolutePoseProblem, length(src), psc)   # the scorer's workspace
        @test find_absolute_pose(cam, StructArray(src .=> dst); scoring = psc, workspace = ws, local_optimization = welsch_hq(:absolute_pose), rng = MersenneTwister(142)) !== nothing
        # fewer than the P3P minimal sample: no hypothesis; a minimal sample is
        # searched, and holds no consensus beyond itself
        @test find_absolute_pose(cam, StructArray(src[1:2] .=> dst[1:2]); scoring = psc, local_optimization = welsch_hq(:absolute_pose), rng = MersenneTwister(143)) === nothing
        @test !converged(find_absolute_pose(cam, StructArray(src[1:3] .=> dst[1:3]); scoring = psc, local_optimization = welsch_hq(:absolute_pose), rng = MersenneTwister(143)))

        # PREDICTIVE scoring, THROUGH the local optimization. The pose family's
        # LO returns an UNLABELED `EuclideanMap` while the workspace model type
        # is the labeled `Extrinsics3`; scoring the refined pose used to wrap it
        # unlabeled, `score!(…, ::Uncertain{M})` missed, and the run died on a
        # `constraint_with_jacobians(::AbsolutePoseProblem, …)` MethodError as soon
        # as a candidate reached LO (H/F/E never showed it — their LO returns
        # the model type). `_covariance_scored` labels first now, so this runs.
        rp = find_absolute_pose(
            cam, StructArray(src .=> dst);
            scoring = StudentTUniformScoring{Predictive}(3, 3.0; codimension = 2), local_optimization = welsch_hq(:absolute_pose), rng = MersenneTwister(144)   # model_dof = the P3P minimal sample, m = 3
        )
        @test rp !== nothing && converged(rp)
        @test rp.lo_retcode !== :not_run                                   # the LO really fired
        @test estimate(rp) isa Extrinsics3                                 # labeled, as the workspace stores it
        @test rotation_error_deg(estimate(rp), R_gt) < 1.0
        @test translation_error(estimate(rp), t_gt) < 0.05
    end

end

@testset "find_hand_eye (the Student-t + uniform IRLS, its default before 2026-10)" begin
    rng = MersenneTwister(29)
    sc = robot_world_hand_eye_scene(rng; N = 30, Y = (ang_max = π, t_scale = 2.0), X = (ang_max = π, t_scale = 0.1),
                                    A = (ang_max = π / 3, t_scale = 0.5))
    X, Y, A = only(sc.X), sc.Y, sc.A
    B = [perturb_pose(rng, marker_pose(Y, A[i], X); σ_R = 0.001, σ_t = 0.001) for i in eachindex(A)]
    r = find_hand_eye(A .=> B; scoring = old_scoring(HandEyeProblem(A .=> B), :hand_eye),
                      local_optimization = StudentTUniform(), rng = MersenneTwister(31))
    @test converged(r)
    @test r.lo_retcode !== :not_run
end
