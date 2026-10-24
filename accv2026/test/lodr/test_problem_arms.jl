# =============================================================================
# The strategies on VisualGeometryToolkitEstimation's problems — the arms of its problem
# batteries that run this package's strategies (the Student-t + uniform IRLS,
# StuTuBCD, the Welsch HQ lift), with their scenes, seeds and bounds unchanged.
# The batteries themselves (and their core-strategy arms) stay with the
# problems in VisualGeometryToolkitEstimation. (Moved from its test/fundmat_lm_tests.jl,
# pnp_lens_tests.jl, ransac_homography_tests.jl, ransac_fundmat_tests.jl,
# radial_homography_tests.jl, radial_camera_tests.jl and line_fitting_tests.jl.)
# =============================================================================
import VisualGeometryToolkitCore as VgtkCore
using Test, Random, LinearAlgebra, StaticArrays, StructArrays
using Statistics: median
using Rotations: RotMatrix, RotXYZ, RotY, RotZ, MRP
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: Csponds, csponds, converged, estimate, rotation, translation, center, division_coeff,
    homography, radial_rows, is_map_inlier, IGPrior, FundMatManifold7, retract, project, Point2, Point3, Line2D,
    RadialHomography, RadialCamera, radial_transfer, unit_normalize, calibration_matrix
using VisualGeometryToolkitCore.Synthetic: projective_distance
using RANSACScoringDoneRight: StudentTUniformScoring
using VisualGeometryToolkitEstimation
using VisualGeometryToolkitEstimation: RadialHomographyProblem, RadialCameraProblem, find_radial_homography, find_radial_camera,
    minimal_sample_size, model_type, residuals!, data_size
using LocalOptimizationDoneRight
const RVG = VisualGeometryToolkitEstimation
include("scenes.jl")   # the shared scenes, as modules
using .EpipolarScenes, .HomographyScenes, .PoseScenes, .Contamination, .DivisionBoards

# The paper's per-class Welsch HQ recipe (the find_* default before 2026-10).
welsch_hq(class) = HQ{WelschShape}(scale_multiple = tuning_constant(class, "welsch").scale_multiple)

@testset "F: the joint-(θ,z) Welsch lift (F-lift, 2026-07-09)" begin
    # the scene of VisualGeometryToolkitEstimation's Bartoli–Sturm refit battery
    rng = MersenneTwister(42)
    R = RotMatrix(MRP(0.1, -0.2, 0.15))
    t = normalize(SVector(0.3, -0.1, 1.0))
    F_gt = SMatrix{3, 3, Float64}(FundMat(EssentialMat(R, t), SMatrix{3, 3, Float64}(I)))   # F at K = I
    u1, u2 = calibrated_pairs(rng, R, t; n = 60, σ = 0.001)
    n = length(u1)
    sqrtw = ones(n)
    prob = RVG.FundMatProblem(u1 .=> u2)
    F_seed = RVG.FundMat(Tuple(F_gt + 0.05 * SMatrix{3, 3, Float64}(randn(rng, 3, 3))))
    cost(F) = VgtkCore.rows_cost(RVG.ChartLm(RVG._chart(prob, F), prob, sqrtw), zero(SVector{7, Float64}), n)
    # The Welsch HQ lift must run on FundMatProblem and improve the
    # truncated-partition cost from the perturbed seed.
    sc = StudentTUniformScoring(typeof(prob), 0.05; prior = IGPrior(0.0, 0.0))
    ws = RVG.RansacWorkspace(prob, sc)
    rlift = RVG.locally_optimize(
        prob, F_seed; local_optimization = HQ{WelschShape}(max_iter = 25, scale_multiple = 1.5),
        scoring = sc, workspace = ws
    )
    @test estimate(rlift) !== nothing
    @test cost(estimate(rlift)) < cost(F_seed)
end

# -----------------------------------------------------------------------------
# Absolute pose through a distorting lens (pnp_lens): the Student-t M-step and
# the Welsch lift in the raw-pixel currency.
# -----------------------------------------------------------------------------
_lens_camera(lens) = CameraModel(; focal = 950.0, pp = (2120.0, 1416.0), lens)
const _CAMS_L = (
    "division2" => _lens_camera(Division(-0.3, -0.08)),
    # OpenCV's 8-coefficient radial-tangential lens (k1…k6, p1, p2)
    "brown_conrady" => _lens_camera(Lens(Perspective(), Additive(Radial((-0.25, 0.06, -0.01), (0.0, 0.0, 0.0)),
                                                                Tangential(0.001, -0.0005)))),
)
const _SCENES = Dict(
    "division2" => (RotMatrix(RotXYZ(0.35, -0.35, 0.2)), Vec3{Float64}(850.0, 250.0, 350.0), 1100.0),
    "brown_conrady" => (RotMatrix(RotXYZ(0.35, -0.55, 0.2)), Vec3{Float64}(280.0, -60.0, 420.0), 650.0),
)
function _board_scene(rng, cam, R, t; σ = 0.3, n_out = 40)
    board = [Point3{Float64}(X, Y, 0.0) for X in -160.0:20.0:160.0 for Y in -120.0:20.0:120.0]
    inliers = [Xw => SVector{2, Float64}(project(cam, R * SVector(Xw) + t)) for Xw in board]
    pairs, gt = contaminated_pairs(
        rng, filter(c -> all(isfinite, c.second), inliers); σ, n_out, shuffle = true,
        outlier = (rng, _) -> Point3{Float64}(320 * rand(rng) - 160, 240 * rand(rng) - 120, 0.0) => SVector(4240 * rand(rng), 2832 * rand(rng))
    )
    return first.(pairs), last.(pairs), gt
end
@testset "absolute pose through a distorting lens — $name" for (name, cam) in _CAMS_L
    R_gt, t_gt, rim = _SCENES[name]
    src, dst, gt = _board_scene(MersenneTwister(21), cam, R_gt, t_gt)
    c = SVector(2120.0, 1416.0)
    radius = [norm(SVector{2, Float64}(d) - c) for d in dst]
    arms = (
        "StudentTUniform" => StudentTUniform(),
        "HQ{Welsch}" => HQ{WelschShape}(scale_multiple = 1.597),
    )
    @testset "$lo_name" for (lo_name, lo) in arms
        est = find_absolute_pose(cam, src .=> dst; scoring = StudentTUniformScoring(AbsolutePoseProblem(cam, src .=> dst), 5.0),
                                 local_optimization = lo, rng = MersenneTwister(3))
        @test est !== nothing
        @test rotation_error_deg(estimate(est), R_gt) < 0.05
        @test translation_error(estimate(est), t_gt) < 1.0
        m = est.inlier_mask
        @test count(m .& gt) >= count(gt) - 2 && count(m .& .!gt) == 0
        @test count(m .& gt .& (radius .> rim)) >= count(gt .& (radius .> rim)) - 1    # the rim is kept
    end
end

# -----------------------------------------------------------------------------
# Homography (ransac_homography)
# -----------------------------------------------------------------------------
function make_homography_data(; n_inliers = 100, n_outliers = 30, noise = 0.5, seed = 42)
    source_pts, target_pts = homography_pairs(MersenneTwister(seed), H_TRUE; n_in = n_inliers, n_out = n_outliers, σ = noise)
    return source_pts, target_pts, H_TRUE, n_inliers
end

@testset "H: LO-RANSAC — StudentTUniform" begin
    source_pts, target_pts, H_true, n_inliers = make_homography_data(n_inliers = 100, n_outliers = 30, noise = 0.5, seed = 42)
    problem = HomographyProblem(csponds(source_pts, target_pts))
    result = ransac(
        problem, StudentTUniformScoring(problem, 50.0);
        local_optimization = StudentTUniform(),
        config = RansacConfig(max_trials = 3000, min_trials = 200),
        rng = MersenneTwister(128)
    )
    @test converged(result)
    test_pts = [SA[300.0, 400.0], SA[600.0, 300.0], SA[450.0, 550.0], SA[200.0, 200.0], SA[700.0, 500.0]]
    @test max_transfer_error(estimate(result), H_true, test_pts) < 2.0
    @test sum(result.inlier_mask) >= n_inliers * 0.7
end

# MAPPED homography: pixels in, `K⁻¹`-style measurement maps, a model-frame H
# out. The maps are anisotropic, differ per view and carry a ROLL, so a
# consumer that applies the model-frame H to raw pixels (the LM refit, the HQ
# lift) is caught rather than accidentally agreeing.
_roll(θ) = SMatrix{3, 3, Float64, 9}(RotZ(θ))
_K(fx, fy, cx, cy) = SMatrix{3, 3, Float64, 9}(calibration_matrix(CameraModel(; focal = (fx, fy), pp = (cx, cy))))
const C₁ = _roll(deg2rad(70)) * inv(_K(820.0, 790.0, 480.0, 400.0))
const C₂ = _roll(deg2rad(-110)) * inv(_K(760.0, 805.0, 510.0, 380.0))
_to_px(H) = inv(HomographyMap(C₂)) ∘ H ∘ HomographyMap(C₁)
_to_model(H) = HomographyMap(C₂) ∘ H ∘ inv(HomographyMap(C₁))
const mapped_test_pts = [SA[300.0, 400.0], SA[600.0, 300.0], SA[450.0, 550.0], SA[200.0, 200.0], SA[700.0, 500.0]]

@testset "mapped H — the strategies refit in a consistent frame" begin
    source_pts, target_pts, H_true, n_inliers = make_homography_data(n_inliers = 100, n_outliers = 30, noise = 0.5, seed = 42)
    cs = csponds(source_pts, target_pts)
    pm = HomographyProblem(cs; src_map = C₁, dst_map = C₂)
    pu = HomographyProblem(cs)
    for lo in (StudentTUniform(), welsch_hq(:homography))
        cfg = RansacConfig(max_trials = 3000, min_trials = 200)
        rm = ransac(pm, StudentTUniformScoring(pm, 50.0); local_optimization = lo, config = cfg, rng = MersenneTwister(129))
        ru = ransac(pu, StudentTUniformScoring(pu, 50.0); local_optimization = lo, config = cfg, rng = MersenneTwister(129))
        @test converged(rm)
        @test estimate(rm) isa model_type(pm)
        @test sum(rm.inlier_mask[1:n_inliers]) >= 0.9 * n_inliers
        @test sum(rm.inlier_mask[(n_inliers + 1):end]) <= 3
        @test max_transfer_error(_to_px(estimate(rm)), H_true, mapped_test_pts) < 1.0
        # The LO objective is the same pixel objective mapped or not, so the
        # two runs land on the same homography.
        @test max_transfer_error(_to_px(estimate(rm)), estimate(ru), mapped_test_pts) < 0.5
    end
    # `locally_optimize` from a perturbed model-frame seed.
    Hs = _to_model(HomographyMat{Float64}(Tuple(SMatrix{3, 3, Float64, 9}(H_true) .* (1 .+ 1.0e-3 .* SMatrix{3, 3, Float64, 9}(1, -2, 1, 2, -1, 1, -1, 1, 0)))))
    for lo in (StudentTUniform(), welsch_hq(:homography))
        r = RVG.locally_optimize(pm, Hs; scoring = StudentTUniformScoring(pm, 50.0), local_optimization = lo)
        @test max_transfer_error(_to_px(estimate(r)), H_true, mapped_test_pts) < 1.0
    end
end

# -----------------------------------------------------------------------------
# Fundamental matrix (ransac_fundmat)
# -----------------------------------------------------------------------------
const _CAM₁ = CameraModel(; focal = 500.0, pp = (320.0, 240.0))
const _CAM₂ = CameraModel(; focal = 600.0, pp = (300.0, 250.0))
const _R = RotY(0.15)
const _T = SA[1.0, 0.2, 0.1]
_box(rng) = SA[4.0 * (rand(rng) - 0.5), 3.0 * (rand(rng) - 0.5), 5.0 + 3.0 * rand(rng)]
function make_fundmat_data(; n_inliers = 100, n_outliers = 30, noise = 0.5, seed = 42)
    source_pts, target_pts = stereo_pixel_pairs(
        MersenneTwister(seed), _CAM₁, _CAM₂, _R, _T;
        n = n_inliers, σ₁ = noise, σ₂ = noise, point = _box, n_out = n_outliers,
        outlier = rng -> (SA[100.0 + 440.0 * rand(rng), 50.0 + 380.0 * rand(rng)], SA[80.0 + 440.0 * rand(rng), 60.0 + 380.0 * rand(rng)])
    )
    return source_pts, target_pts, n_inliers
end

@testset "F: LO-RANSAC — StudentTUniform" begin
    source_pts, target_pts, n_inliers = make_fundmat_data(n_inliers = 100, n_outliers = 30, noise = 0.5, seed = 42)
    problem = FundMatProblem(csponds(source_pts, target_pts))
    result = ransac(
        problem,
        StudentTUniformScoring(minimal_sample_size(problem), 50.0);
        local_optimization = StudentTUniform(),
        config = RansacConfig(max_trials = 5000, min_trials = 500),
        rng = MersenneTwister(192)
    )
    @test converged(result)
    sv = svdvals(estimate(result))
    @test sv[3] / sv[1] < 0.01
    @test sum(result.inlier_mask) >= n_inliers * 0.6
end

# -----------------------------------------------------------------------------
# Radial homography (radial_homography): the old default (the class's Welsch
# HQ recipe, stated explicitly) and the Student-t + uniform IRLS.
# -----------------------------------------------------------------------------
const _RW, _RH = 1200.0, 900.0
_rdiag() = hypot(_RW, _RH)
function _gt_model(k_norm)
    H0 = SMatrix{3, 3, Float64}(4.0, -0.2, 5.0e-5, 0.3, 4.2, -4.0e-5, 260.0, 200.0, 1.0)
    return RadialHomography{Float64}(HomographyMat{Float64}(Tuple(H0)), k_norm / _rdiag()^2, SVector(_RW / 2, _RH / 2))
end
function _make_scene(rng, m_gt; n_in = 70, n_out = 30, σ = 0.0)
    function inlier(rng, _)
        while true
            s = SVector(200 * rand(rng), 150 * rand(rng))
            d = radial_transfer(m_gt, s)
            d === nothing && continue
            (0 < d[1] < _RW && 0 < d[2] < _RH) && return s => SVector(d[1], d[2])
        end
    end
    return contaminated_pairs(
        rng, inlier, n_in; σ, n_out, shuffle = true,
        outlier = (rng, _) -> SVector(200 * rand(rng), 150 * rand(rng)) => SVector(_RW * rand(rng), _RH * rand(rng))
    )
end

@testset "radial homography" begin
    # the battery's RNG stream: its problem-level scene draws first
    rng = MersenneTwister(1234)
    m_gt = _gt_model(-0.25)
    _make_scene(rng, m_gt; n_in = 20, n_out = 0)
    @testset "find_radial_homography: exact data + outliers ($loname)" for (loname, lo) in (
            ("HQ-Welsch (the old default)", welsch_hq(:radial_homography)),
            ("StudentTUniform", StudentTUniform()),
        )
        pairs, gt_mask = _make_scene(rng, m_gt; n_in = 70, n_out = 30)
        res = find_radial_homography(
            pairs; center = (_RW / 2, _RH / 2),
            scoring = StudentTUniformScoring(RadialHomographyProblem(pairs; center = (_RW / 2, _RH / 2)), 2.0),
            max_trials = 4000, min_trials = 200,
            rng = MersenneTwister(99), local_optimization = lo
        )
        @test res !== nothing
        @test converged(res)
        m = estimate(res)
        @test m isa RadialHomography{Float64}
        @test center(m) ≈ SVector(_RW / 2, _RH / 2)
        @test abs(division_coeff(m) - division_coeff(m_gt)) / abs(division_coeff(m_gt)) < 1.0e-3
        @test projective_distance(homography(m), homography(m_gt)) < 1.0e-4
        w = res.weights
        @test count(i -> gt_mask[i] && is_map_inlier(w[i]), eachindex(w)) >= 65
        @test count(i -> !gt_mask[i] && is_map_inlier(w[i]), eachindex(w)) <= 2
    end
    @testset "noise: recovers sign and magnitude of k (the old default)" begin
        pairs, _ = _make_scene(rng, m_gt; n_in = 120, n_out = 20, σ = 0.4)
        res = find_radial_homography(
            pairs; center = (_RW / 2, _RH / 2),
            scoring = StudentTUniformScoring(RadialHomographyProblem(pairs; center = (_RW / 2, _RH / 2)), 2.5),
            max_trials = 4000, rng = MersenneTwister(7), local_optimization = welsch_hq(:radial_homography)
        )
        @test res !== nothing
        @test converged(res)
        @test sign(division_coeff(estimate(res))) == sign(division_coeff(m_gt))
        @test abs(division_coeff(estimate(res)) - division_coeff(m_gt)) / abs(division_coeff(m_gt)) < 0.3
    end
    @testset "minimal = :homography — the (H, k) optimizer is the Student-t + uniform IRLS" begin
        pairs, gt = _make_scene(MersenneTwister(77), m_gt; n_in = 80, n_out = 25, σ = 0.3)
        est = find_radial_homography(
            pairs; center = (_RW / 2, _RH / 2), minimal = :homography,
            scoring = StudentTUniformScoring(RadialHomographyProblem(pairs; center = (_RW / 2, _RH / 2), minimal = :homography), 3.0),
            local_optimization = StudentTUniform(), rng = MersenneTwister(5)
        )
        @test est !== nothing
        m = est.inlier_mask
        @test count(m .& gt) >= count(gt) - 3 && count(m .& .!gt) == 0
        @test abs(division_coeff(estimate(est)) - division_coeff(m_gt)) < 0.1 * abs(division_coeff(m_gt))
        @test sign(division_coeff(estimate(est))) == sign(division_coeff(m_gt))
    end
end

# -----------------------------------------------------------------------------
# Radial camera (radial_camera): the Student-t + uniform IRLS, and the
# partition-anchored Welsch-HQ lift on the 5-dof complement chart at the
# transferred operating point (the class's old default).
# -----------------------------------------------------------------------------
const _CW, _CH = 4000.0, 3000.0
const _CC = SVector(_CW / 2, _CH / 2)
function _board(rng; f = 900.0, k = -2.0e-7, n_out = 20, σ = 0.0)
    cam = board_camera(RotXYZ(0.35, -0.25, 0.15), SVector(40.0, -30.0, 600.0); f, ks = (k,), center = _CC)
    pairs, gt = contaminated_pairs(
        rng, board_pixels(cam; grid = -100.0:25.0:100.0); σ, n_out, shuffle = true,
        outlier = (rng, _) -> SVector(200 * rand(rng) - 100, 200 * rand(rng) - 100) => SVector(_CW * rand(rng), _CH * rand(rng))
    )
    return RadialCamera(cam), pairs, gt
end
_pd(a::RadialCamera, b::RadialCamera) = projective_distance(radial_rows(a), radial_rows(b))

@testset "radial camera" begin
    @testset "RANSAC + the Student-t + uniform IRLS recovers the camera under distortion" begin
        P_gt, pairs, gt = _board(MersenneTwister(7))
        est = find_radial_camera(pairs; center = _CC, scoring = StudentTUniformScoring(RadialCameraProblem(pairs; center = _CC), 5.0), local_optimization = StudentTUniform(), rng = MersenneTwister(1))
        @test est !== nothing
        @test _pd(estimate(est), P_gt) < sqrt(2 * 1.0e-6)
        m = est.inlier_mask
        @test count(m .& gt) >= count(gt) - 2 && count(m .& .!gt) == 0
        P_gt2, pairs2, gt2 = _board(MersenneTwister(3); σ = 0.3)
        est2 = find_radial_camera(pairs2; center = _CC, scoring = StudentTUniformScoring(RadialCameraProblem(pairs2; center = _CC), 5.0), local_optimization = StudentTUniform(), rng = MersenneTwister(2))
        @test est2 !== nothing
        r2 = zeros(length(pairs2)); residuals!(r2, RadialCameraProblem(pairs2; center = _CC), estimate(est2))
        @test median(abs.(r2[gt2])) < 0.5
    end
    @testset "the Welsch-HQ chart lift (the old default)" begin
        P_gt, pairs, gt = _board(MersenneTwister(11); σ = 0.2)
        p = RadialCameraProblem(pairs; center = _CC)
        lo = welsch_hq(:radial_camera)
        est = find_radial_camera(pairs; center = _CC, scoring = StudentTUniformScoring(RadialCameraProblem(pairs; center = _CC), 5.0), local_optimization = lo, rng = MersenneTwister(4))
        @test est !== nothing
        @test est.lo_retcode != :not_run
        rr = zeros(length(pairs)); residuals!(rr, p, estimate(est))
        @test median(abs.(rr[gt])) < 0.4
        @test count(est.inlier_mask .& .!gt) == 0
    end
end

# -----------------------------------------------------------------------------
# Lines (line_fitting): the Student-t + uniform IRLS through its soft weights,
# and StuTuBCD on a problem with no weighted refit.
# -----------------------------------------------------------------------------
@testset "lines" begin
    function _contaminated_line(rng)
        pts = [Point2{Float64}(Float64(i), 0.01 * randn(rng)) for i in 0:56]
        append!(pts, [Point2{Float64}(Float64(x), 0.5) for x in (10, 30, 50)])
        return LineFittingProblem(pts), Line2D{Float64}(SVector(0.0, 1.0, -0.025))
    end
    @testset "StudentTUniform recovers the line through its soft weights" begin
        prob, θ₀ = _contaminated_line(MersenneTwister(57))
        r = locally_optimize(prob, θ₀; local_optimization = StudentTUniform(), scoring = StudentTUniformScoring(prob, 1.0))
        line = estimate(r)
        @test abs(distance(line, Point2(0.0, 0.0))) < 0.006
        @test abs(distance(line, Point2(56.0, 0.0))) < 0.006
        @test count(r.inlier_mask[1:57]) >= 55 && !any(r.inlier_mask[58:60])
    end
    @testset "StuTuBCD survives a failed refit" begin
        # The inhomogeneous line has no weighted refit (`refine!` is `nothing`):
        # StuTuBCD must keep its incumbent, not hand `nothing` to the scorer.
        rng = MersenneTwister(59)
        pts = [SVector(Float64(i), 1.0 + 0.5i + 0.01 * randn(rng)) for i in 1:40]
        prob = InhomLineFittingProblem(pts)
        r = ransac(prob, StudentTUniformScoring(prob, 1.0); local_optimization = StuTuBCD(), rng = MersenneTwister(60))
        @test converged(r)
        @test r.lo_retcode === :solve_failed
    end
end
