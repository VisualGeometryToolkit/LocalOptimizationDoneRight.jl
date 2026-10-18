# =============================================================================
# Shared synthetic scenes of the strategy tests — plain modules, one definition
# each. They are VisualGeometryToolkitEstimation's test scenes (its test/scenes_testsetups.jl,
# where they are ReTestItems setups), copied as modules so the tests that moved
# here with the strategies draw the SAME scenes in the SAME RNG order (their
# numeric pins depend on it). A test file includes this file into its own
# module and `using`s the scene modules it needs.
#
# Every scene is built through the OWNERS' forward models — VisualGeometryToolkitCore's
# `project`/`unproject` on a camera, `EssentialMat(R, t)`, `FundMat(E, K₁, K₂)`,
# `RadialCamera(camera)`, the rigid charts' `retract` — so no test restates the
# geometry it then checks.
# =============================================================================

# -----------------------------------------------------------------------------
# Two-view epipolar scenes: calibrated (normalized-plane) pairs, the pixel
# cameras the E problems are stated in, and the stereo pixel pairs of F.
# -----------------------------------------------------------------------------
module EpipolarScenes
using Random: AbstractRNG
using LinearAlgebra: normalize
using StaticArrays: SA, SVector
using Rotations: RotZ
using VisualGeometryToolkitCore: CameraModel, EssentialMat, Pinhole, Point2, TLSShape, cost, csponds, project, px,
    signed_sampson_distance
using VisualGeometryToolkitEstimation: EssentialProblem

export box_point, calibrated_pairs, perturbed_essential, stereo_pixel_pairs, truncated_sampson_cost,
    FPX, CX, CY, ECAM, topx, essential_problem, ecs

# A point in the box `[-1, 1] × [-0.75, 0.75] × [3, 5]` in front of view 1.
box_point(rng::AbstractRNG) = SA[2.0 * (rand(rng) - 0.5), 1.5 * (rand(rng) - 0.5), 3.0 + 2.0 * rand(rng)]

"""
    calibrated_pairs(rng, R, t; n, σ, outlier_every = 0) -> (u₁, u₂)

Calibrated two-view pairs on the z = 1 plane: `n` draws of `box_point`, seen
by view 2 at `x₂ = R·x₁ + t` (draws behind view 2 are skipped), view 2
perturbed by `σ` per coordinate.
Every `outlier_every`-th draw's view-2 point is replaced by a uniform one in
`[-0.4, 0.4]²` (a gross outlier).
"""
function calibrated_pairs(rng::AbstractRNG, R, t; n, σ, outlier_every = 0)
    u₁ = Point2{Float64}[]; u₂ = Point2{Float64}[]
    for k in 1:n
        X = box_point(rng)
        Y = R * X + t
        Y[3] <= 0 && continue
        push!(u₁, Point2{Float64}(project(Pinhole(), X)))
        if outlier_every > 0 && k % outlier_every == 0
            push!(u₂, Point2{Float64}(0.8 * (rand(rng) - 0.5), 0.8 * (rand(rng) - 0.5)))
        else
            push!(u₂, Point2{Float64}(project(Pinhole(), Y) + σ * SA[randn(rng), randn(rng)]))
        end
    end
    return u₁, u₂
end

"""
    perturbed_essential(R, t, δ, Δt) -> EssentialMat

The seed a local optimization starts from: the pose `(R, t)` rolled by `δ` about
view 2's optical axis and its direction moved by `Δt`.
"""
perturbed_essential(R, t, δ, Δt) = EssentialMat(R * RotZ(δ), normalize(t + Δt))

"""
    stereo_pixel_pairs(rng, cam₁, cam₂, R, t; n, point, σ₁ = 0, σ₂ = 0, n_out = 0, outlier)

Pixel pairs of two cameras, view 2 at `x₂ = R·x₁ + t`: `n` draws of `point(rng)`
(draws behind view 2 are skipped) projected through each camera, each view
perturbed by its own `σ` (no draw at σ = 0), then `n_out` pairs `outlier(rng)`.
"""
function stereo_pixel_pairs(
        rng::AbstractRNG, cam₁, cam₂, R, t;
        n, point, σ₁ = 0.0, σ₂ = 0.0, n_out = 0, outlier = nothing
    )
    u₁ = SVector{2, Float64}[]; u₂ = SVector{2, Float64}[]
    for _ in 1:n
        X = point(rng)
        Y = R * X + t
        Y[3] <= 0 && continue
        p₁ = SVector{2, Float64}(project(cam₁, X))
        σ₁ > 0 && (p₁ += σ₁ * SA[randn(rng), randn(rng)])
        p₂ = SVector{2, Float64}(project(cam₂, Y))
        σ₂ > 0 && (p₂ += σ₂ * SA[randn(rng), randn(rng)])
        push!(u₁, p₁); push!(u₂, p₂)
    end
    for _ in 1:n_out
        o₁, o₂ = outlier(rng)
        push!(u₁, o₁); push!(u₂, o₂)
    end
    return u₁, u₂
end

# The truncated least-squares cost (MSAC at the squared width `c2`) of F's
# Sampson distances over the pairs `u₁[i] => u₂[i]`.
truncated_sampson_cost(F, u₁, u₂; c2 = 1.0e-4) =
    cost(TLSShape(), [signed_sampson_distance(F, u₁[i], u₂[i]) for i in eachindex(u₁)], c2, length(u₁))

# The pixel camera the calibrated scenes are moved into. A realistic focal
# length keeps the PIXEL tolerances (`COINCIDENT_PX` in the sample gate, an
# outlier half-width) meaningful; an identity camera (f = 1) makes one "pixel"
# one calibrated unit, and sample admission collapses from 100% to 3.92%.
# (The identity camera is `IDCAM`, Cameras.)
const FPX = 800.0
const CX, CY = 320.0, 240.0
const ECAM = CameraModel(FPX * px, SA[CX * px, CY * px])

# A calibrated point imaged by ECAM.
topx(u) = Point2{Float64}(project(ECAM, SA[u[1], u[2], 1.0]))

essential_problem(camera, a, b) = EssentialProblem(camera, camera, csponds(a, b))
# Calibrated pairs as ECAM's pixels.
ecs(a, b) = essential_problem(ECAM, topx.(a), topx.(b))
end

# -----------------------------------------------------------------------------
# The plane-induced homography scene
# -----------------------------------------------------------------------------
module HomographyScenes
using Random: AbstractRNG
using LinearAlgebra: norm
using StaticArrays: SA, SMatrix, SVector
using VisualGeometryToolkitCore: HomographyMap, HomographyMat, PerspectiveMap

export H_TRUE, H_PX, gaussian_source, uniform_source, homography_warp, homography_pairs, max_transfer_error

# The ground-truth homography, unit Frobenius norm, h₃₃ > 0.
const H_TRUE = let H = SMatrix{3, 3, Float64, 9}(0.95, 0.12, 1.0e-4, -0.1, 0.93, 2.0e-4, 15.0, -8.0, 1.0)
    H = H / norm(H)
    HomographyMat{Float64}(Tuple(H[3, 3] < 0 ? -H : H))
end

# A pixel-scale homography (h₃₃ = 1), and the Gaussian point cloud about
# (300, 300) its scenes draw from.
const H_PX = HomographyMat{Float64}(Tuple(SA[1.2 -0.1 30.0; 0.05 1.1 -20.0; 1.0e-4 2.0e-4 1.0]))
gaussian_source(rng::AbstractRNG) = SVector{2, Float64}(randn(rng, 2) .* 200 .+ 300)

# The point map of a homography: x ↦ π(H·x̃).
homography_warp(H) = PerspectiveMap() ∘ HomographyMap(H)

# How far apart two homographies put the same points: the largest distance
# between their transfers of `points` (a region's corners, a few probes).
max_transfer_error(H₁, H₂, points) =
    maximum(norm(homography_warp(H₁)(p) - homography_warp(H₂)(p)) for p in points)

# A source point uniform in [100, 900] × [100, 700] (x drawn first, then y).
uniform_source(rng) = SA[100.0 + 800.0 * rand(rng), 100.0 + 600.0 * rand(rng)]

"""
    homography_pairs(rng, H; n_in, n_out = 0, σ = 0, source, target = source) -> (src, dst)

`n_in` pairs `s => H(s)` with `s = source(rng)` (uniform in `[100, 900] ×
[100, 700]` by default), the target perturbed by `σ` per coordinate (no draw at
σ = 0); then `n_out` unrelated pairs `source(rng) => target(rng)`.
"""
function homography_pairs(rng::AbstractRNG, H; n_in, n_out = 0, σ = 0.0, source = uniform_source, target = source)
    warp = homography_warp(H)
    src = SVector{2, Float64}[]; dst = SVector{2, Float64}[]
    for _ in 1:n_in
        s = SVector{2, Float64}(source(rng))
        d = SVector{2, Float64}(warp(s))
        σ > 0 && (d += σ * SA[randn(rng), randn(rng)])
        push!(src, s); push!(dst, d)
    end
    for _ in 1:n_out
        push!(src, SVector{2, Float64}(source(rng))); push!(dst, SVector{2, Float64}(target(rng)))
    end
    return src, dst
end
end

# -----------------------------------------------------------------------------
# Rigid poses: random draws, perturbations in the decoupled chart, and the
# PnP scene's frustum points.
# -----------------------------------------------------------------------------
module PoseScenes
using Random: AbstractRNG
using LinearAlgebra: norm, normalize
using StaticArrays: SVector
using Rotations: AngleAxis, RotMatrix
using VisualGeometryToolkitCore: EuclideanMap, Point3, RigidExpManifold6, Vec3, retract, rotation, log_so3,
    translation, unproject

export rigid, rand_pose, retract_pose, perturb_pose, frustum_point, rotation_error_deg, translation_error,
    marker_pose, robot_world_hand_eye_scene

# A rigid map from a rotation and a translation, taken as given (no
# orthonormality check: a caller's drifted rotation stays drifted).
rigid(R, t) = EuclideanMap(RotMatrix{3, Float64}(R), Vec3{Float64}(t[1], t[2], t[3]); check = false)

# A random pose: a rotation by a uniform angle in [0, ang_max) about a
# uniformly random axis, and a Gaussian translation of scale `t_scale`.
rand_pose(rng::AbstractRNG; ang_max = π, t_scale = 1.0) =
    rigid(AngleAxis(ang_max * rand(rng), normalize(randn(rng, 3))...), t_scale .* randn(rng, 3))

# `p` moved by `v = (δω, δt)` in the decoupled chart (rotation on the left
# through the exponential, translation free), as a `rigid` map.
retract_pose(p, v) = (q = retract(RigidExpManifold6(p), SVector{6, Float64}(Tuple(v))); rigid(q.R, q.t))

# `p` perturbed in that chart: δω ~ N(0, σ_R²I₃), δt ~ N(0, σ_t²I₃).
function perturb_pose(rng::AbstractRNG, p; σ_R, σ_t)
    δω = σ_R .* randn(rng, 3); δt = σ_t .* randn(rng, 3)
    return retract_pose(p, vcat(δω, δt))
end

# A pose's errors against the truth: the rotation angle (degrees) and the
# translation distance.
rotation_error_deg(p, R) = rad2deg(norm(log_so3(rotation(p)' * R)))
translation_error(p, t) = norm(translation(p) - t)

# The robot-world constraint A·X = Y·B solved for the observation: the marker
# pose B the camera sees in the frame whose rig pose is A. (Hand-eye is Y = X.)
marker_pose(Y, A, X) = inv(Y) ∘ A ∘ X

"""
    robot_world_hand_eye_scene(rng; N, M = 1, Y = (;), X = (;), A = (;)) -> (; Y, X, A)

The unknowns and rig poses of a robot-world scene `A_i·X_m = Y·B_i^m`: `Y`,
then the `M` markers `X`, then the `N` rig poses `A`, each a
`rand_pose(rng; kw...)` with that argument's keywords. Frame i's view of marker
m is `marker_pose(Y, A[i], X[m])`; noise, dropouts and outliers are the item's.
"""
function robot_world_hand_eye_scene(rng::AbstractRNG; N, M = 1, Y = (;), X = (;), A = (;))
    Yp = rand_pose(rng; Y...)
    Xp = [rand_pose(rng; X...) for _ in 1:M]
    Ap = [rand_pose(rng; A...) for _ in 1:N]
    return (; Y = Yp, X = Xp, A = Ap)
end

"""
    frustum_point(rng, camera, R, t; x, y, depth) -> (X, u)

A world point `X` imaged at pixel `u` by the camera at pose `x_cam = R·X + t`:
`u` uniform in `x × y`, the depth along its viewing ray uniform in `depth`.
"""
function frustum_point(rng::AbstractRNG, camera, R, t; x = (40.0, 920.0), y = (40.0, 680.0), depth = (4.0, 10.0))
    u = SVector(x[1] + (x[2] - x[1]) * rand(rng), y[1] + (y[2] - y[1]) * rand(rng))
    d = depth[1] + (depth[2] - depth[1]) * rand(rng)
    Xc = SVector{3, Float64}(unproject(camera, u, d))
    return Point3{Float64}(R' * (Xc - t)), u
end
end

# -----------------------------------------------------------------------------
# Boards under a division lens (the radial-camera and focal-stack scenes)
# -----------------------------------------------------------------------------
module DivisionBoards
using Random: AbstractRNG
using LinearAlgebra: norm
using StaticArrays: SVector
using Rotations: RotMatrix
using VisualGeometryToolkitCore: Camera, CameraModel, Division, EuclideanMap, project

export F0, K0, BOARD_ANGLES, BOARD_TS, BOARD_GRID, board_camera, board_pixels, noisy_board_views

# The focal length (px) and the division coefficient on the CENTRED PIXEL radius
# (ρᵤ = ρ_d / (1 + k·ρ_d²)); the lens stores it on the normalized radius, k·f².
const F0, K0 = 1226.3, -6.4e-7
# The boards' orientations (RotXYZ angles).
const BOARD_ANGLES = [(0.4, -0.3, 0.2), (-0.5, 0.2, -0.1), (0.2, 0.5, 0.3), (-0.3, -0.4, 0.1), (0.6, 0.1, -0.2), (0.1, -0.6, 0.4)]
# Their translations: boards at very different depths (350 to 3000), so the
# algebraic rows of the far ones dominate an unwhitened focal stack.
const BOARD_TS = [
    SVector(30.0, -20.0, 400.0), SVector(-40.0, 10.0, 2500.0), SVector(20.0, 30.0, 350.0),
    SVector(-10.0, -30.0, 3000.0), SVector(50.0, 20.0, 600.0), SVector(0.0, 40.0, 2200.0),
]
# A 5 × 5 board grid in its own z = 0 plane.
const BOARD_GRID = -80.0:40.0:80.0

"""
    board_camera(R, t; f = F0, ks = (K0,), center = (0, 0)) -> Camera

The camera viewing a board's `z = 0` plane at `x_cam = R·X + t`: focal `f`,
principal point `center`, and a division lens whose pixel-radius coefficients
are `ks` (`k_p` on `ρ^{2p}`).
"""
board_camera(R, t; f = F0, ks = (K0,), center = (0.0, 0.0)) = Camera(
    CameraModel(; focal = f, pp = (Float64(center[1]), Float64(center[2])),
        lens = Division((k * f^(2p) for (p, k) in enumerate(ks))...)),
    EuclideanMap(RotMatrix{3, Float64}(R), SVector{3, Float64}(t))
)

# The board's plane points and their pixels, noise free (X outer, Y inner).
board_pixels(camera; grid = BOARD_GRID) = Pair{SVector{2, Float64}, SVector{2, Float64}}[
    SVector(X, Y) => SVector{2, Float64}(project(camera, SVector(X, Y, 0.0))) for X in grid for Y in grid
]

"""
    noisy_board_views(rng, cameras; σ, ε = 0, ν0 = Inf, ρ = 0) -> (boards, inlier)

Each camera's `board_pixels`, every pixel perturbed by `σ·ξ` — ξ standard
Gaussian, or a multivariate Student-t of `ν0` dof — then, with probability `ε`,
a 30 px Gaussian gross outlier, and with probability `ρ` a RAY-ALIGNED mismatch
(moved ±U[5, 100] px along its own radial line: what a radial camera's 1-D
line test cannot reject). `inlier` is the true mask, in board order.
"""
function noisy_board_views(rng::AbstractRNG, cameras; σ, ε = 0.0, ν0 = Inf, ρ = 0.0)
    inlier = Bool[]
    boards = map(cameras) do cam
        pts = Pair{SVector{2, Float64}, SVector{2, Float64}}[]
        for (X, d0) in board_pixels(cam)
            ξ = randn(rng, SVector{2, Float64})
            isfinite(ν0) && (ξ *= sqrt(ν0 / sum(abs2, randn(rng, Int(ν0)))))
            d = d0 + σ * ξ
            out = rand(rng) < ε
            out && (d += 30.0 * randn(rng, SVector{2, Float64}))
            if ρ > 0 && rand(rng) < ρ
                out = true
                d += (rand(rng, Bool) ? 1 : -1) * (5 + 95 * rand(rng)) * d0 / max(norm(d0), 1.0e-9)
            end
            push!(pts, X => d); push!(inlier, !out)
        end
        pts
    end
    return boards, inlier
end
end

# -----------------------------------------------------------------------------
# The calibrated P3P scene: points in front of a fixed pose, observed by a
# camera (the identity camera `IDCAM` makes them calibrated coordinates), with
# per-row √weights.
# -----------------------------------------------------------------------------
module P3PScenes
using Random: AbstractRNG
using StaticArrays: SA
using Rotations: RotMatrix, MRP
using VisualGeometryToolkitCore: Point2, Point3, Vec3, project
using VisualGeometryToolkitEstimation: AbsolutePoseProblem

export p3p_scene

"""
    p3p_scene(rng, camera, n; σ) -> (R₀, t₀, problem, sqrtw)

`n` points seen from the pose `(R₀, t₀)` by `camera`, perturbed by `σ` (in its
pixels); `sqrtw` in the family's per-ROW convention (length 2n, a point's
weight on both its rows).
"""
function p3p_scene(rng::AbstractRNG, camera, n; σ)
    R₀ = RotMatrix(MRP(0.1, -0.05, 0.2))
    t₀ = Vec3{Float64}(0.3, -0.2, 0.5)
    Xs = [Point3{Float64}(randn(rng), randn(rng), 3 + rand(rng)) for _ in 1:n]
    obs = [Point2{Float64}(project(camera, R₀ * X + t₀) + σ * SA[randn(rng), randn(rng)]) for X in Xs]
    sqrtw = Vector{Float64}(undef, 2n)
    for i in 1:n
        w = sqrt(rand(rng))
        sqrtw[2i - 1] = w; sqrtw[2i] = w
    end
    return R₀, t₀, AbsolutePoseProblem(camera, [Xs[i] => obs[i] for i in 1:n]), sqrtw
end
end

# -----------------------------------------------------------------------------
# Cameras more than one item states its problems on.
# -----------------------------------------------------------------------------
module Cameras
using StaticArrays: SA
using VisualGeometryToolkitCore: CameraModel, Pinhole, Point2, backproject, project, px

export IDCAM, calibrated_point

# The identity camera: its "pixels" ARE calibrated units (f = 1, principal
# point at the origin).
const IDCAM = CameraModel(1.0px, SA[0.0px, 0.0px])

# A camera's pixel as a calibrated point: its bearing on the z = 1 plane.
calibrated_point(camera, u) = Point2{Float64}(project(Pinhole(), backproject(camera, u)))
end

# -----------------------------------------------------------------------------
# Contaminated correspondence sets: inliers with target noise, then outliers,
# optionally shuffled.
# -----------------------------------------------------------------------------
module Contamination
using Random: AbstractRNG, randperm
using StaticArrays: SA

export contaminated_pairs

_inlier(rng, inliers::AbstractVector, i) = inliers[i]
_inlier(rng, inlier, i) = inlier(rng, i)

"""
    contaminated_pairs(rng, inliers[, n_in]; σ = 0, n_out = 0, outlier, shuffle = false) -> (pairs, is_inlier)

`n_in` inlier pairs `a => b + σ·(randn, randn)` — `inliers` is a vector of
clean pairs, or a function `(rng, i) -> a => b` drawn in turn with each one's
noise right after it — then `n_out` pairs `outlier(rng, k)`, then, with
`shuffle`, one `randperm` of both. The noise is drawn at every σ, 0 included,
so a scene's draws do not depend on σ.
"""
function contaminated_pairs(
        rng::AbstractRNG, inliers, n_in = length(inliers);
        σ = 0.0, n_out = 0, outlier = nothing, shuffle = false
    )
    pairs = map(1:n_in) do i
        a, b = _inlier(rng, inliers, i)
        a => b + σ * SA[randn(rng), randn(rng)]
    end
    outs = [outlier(rng, k) for k in 1:n_out]
    all_pairs = n_out == 0 ? pairs : [pairs; outs]
    is_inlier = [trues(n_in); falses(n_out)]
    shuffle || return all_pairs, is_inlier
    perm = randperm(rng, length(all_pairs))
    return all_pairs[perm], is_inlier[perm]
end
end

# -----------------------------------------------------------------------------
# The loss-lift batteries' shared checks (the homography and PnP lift tests):
# the same LO arms through production `ransac()`, and from a perturbed seed
# through `locally_optimize`.
# -----------------------------------------------------------------------------
module LiftChecks
using Test: @test, @testset
using Random: Random, MersenneTwister
using VisualGeometryToolkitCore: GemanMcclureShape, WelschShape, converged, estimate
using VisualGeometryToolkitEstimation: Irls, RansacConfig, ransac
using LocalOptimizationDoneRight: Gnc, HQ

export lift_arms, check_lift_ransac, check_lift_recovers

"""
    lift_arms(; welsch_scale_multiple, gnc_scale_multiple) -> (name => strategy, …)

The battery's LO arms: the static Welsch IRLS (scale multiple 1.5), the HQ
lifts — Welsch at `welsch_scale_multiple`, Geman–McClure at the half-weight
depth of Welsch's 1.5 — and the GNC arm at `gnc_scale_multiple`.
"""
lift_arms(; welsch_scale_multiple, gnc_scale_multiple) = (
    "Irls{Welsch}" => Irls{WelschShape}(scale_multiple = 1.5),
    "HQ{Welsch}" => HQ{WelschShape}(scale_multiple = welsch_scale_multiple),
    "HQ{GM}" => HQ{GemanMcclureShape}(scale_multiple = 1.5 * sqrt(log(2.0))),
    "Gnc{Irls{Welsch}}" => Gnc{Irls{WelschShape}}(scale_multiple = gnc_scale_multiple),
)

"""
    check_lift_ransac(accurate, problem, scoring, arms, n_in; seed)

Production `ransac()` per arm, the first `n_in` correspondences the true
inliers: it converges, `accurate(estimate)` holds (its own `@test`s), and it
keeps ≥ 90 % of the inliers with ≤ 5 false positives.
"""
function check_lift_ransac(accurate, problem, scoring, arms, n_in; seed)
    @testset "ransac() — $name" for (name, lo) in arms
        Random.seed!(11)
        res = ransac(
            problem, scoring; local_optimization = lo,
            config = RansacConfig(max_trials = 2000, min_trials = 200),
            rng = MersenneTwister(seed)
        )
        @test converged(res)
        accurate(estimate(res))
        @test sum(res.inlier_mask[1:n_in]) >= 0.9 * n_in            # inlier recovery
        @test sum(res.inlier_mask[(n_in + 1):end]) <= 5             # false-positive control
    end
    return nothing
end

"""
    check_lift_recovers(accurate, refine, arms)

Every arm, run from the same seed by `refine(strategy)`, lands where
`accurate(estimate)` holds.
"""
function check_lift_recovers(accurate, refine, arms)
    for (_, lo) in arms
        accurate(estimate(refine(lo)))
    end
    return nothing
end
end
