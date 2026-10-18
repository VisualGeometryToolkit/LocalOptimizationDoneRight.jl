# =============================================================================
# two_view_scene — THE synthetic two-view fixture of the paper project's tests,
# shared by test_lebeda_lo.jl (the RansacLib LO refit path) and
# test_lo_contracts.jl.
#
# 120 inliers (noise 0.002 on the calibrated z = 1 plane) and 51 outliers (30 %).
# The outliers are drawn uniformly INSIDE both cameras' fields of view: a
# mismatch is a pair of image points, and one outside the image is not
# physically meaningful (every scorer rejects it trivially, so it tests nothing).
# Two fields of view, the same rig:
#   :wide   — 3-D cloud [±2]×[±1.5]×[1.5, 4.5] kept to |x| ≤ 1.5, |y| ≤ 1.2 in
#             both views: RansacLibLO's regime (on a narrow FOV its non-minimal
#             14-point DLT fits are ill-posed and every classical-LO stage gates
#             out, which would make travel and currency checks vacuous).
#   :narrow — 3-D cloud [±1]×[±0.75]×[3, 5] (|x| ≤ 1/3, |y| ≤ 1/4): the
#             LO-strategy contract scene.
# `planar = true` puts every inlier on the plane z = 3 (the H track).
#
# The pool frame is a fake camera Kc with non-trivial focals, so the
# E-track loss-width conversion is live. Returns the calibrated points (w1, w2), the
# pool-frame points (x1c, x2c), the evaluator's `PairGeom`, the cameras, the ground
# truth (R, t), a seed pose (Rp, tp) perturbed by the evaluator's basin perturbation
# at δ = 0.02 rad (1.1°: on the wide scene its consensus at the loss width is 72 of the 120
# inliers — at δ = 0.1 it is 2, and every classical-LO stage gates out), and
# the pool-frame loss width ≈ 0.01 calibrated.
# =============================================================================
using Random: MersenneTwister, randn
using LinearAlgebra: normalize
using StaticArrays: SMatrix, SVector, SA
using Rotations: RotY
using VisualGeometryToolkitCore: Point2, Csponds
using VisualGeometryToolkitEval.Evaluation: PairGeom, perturbed_pose

const _TWO_VIEW_FOV = (
    wide = (cloud = (2.0, 1.5, 1.5, 3.0), image = (1.5, 1.2), seed = 3),
    narrow = (cloud = (1.0, 0.75, 3.0, 2.0), image = (1 / 3, 0.25), seed = 7),
)

function two_view_scene(; fov::Symbol = :wide, planar::Bool = false, n_in::Int = 120, n_out::Int = 51)
    spec = _TWO_VIEW_FOV[fov]
    hx, hy, z0, dz = spec.cloud
    bx, by = spec.image
    rng = MersenneTwister(spec.seed)
    R = SMatrix{3, 3, Float64, 9}(RotY(0.2))
    t = normalize(SA[0.8, 0.1, 0.3])
    in_view(p) = abs(p[1]) <= bx && abs(p[2]) <= by
    w1 = Point2{Float64}[]; w2 = Point2{Float64}[]
    while length(w1) < n_in
        X = SA[2hx * (rand(rng) - 0.5), 2hy * (rand(rng) - 0.5), planar ? 3.0 : z0 + dz * rand(rng)]
        Y = R * X + t
        (Y[3] <= 0.2 || X[3] <= 0.2) && continue
        x1 = Point2{Float64}(X[1] / X[3], X[2] / X[3])
        x2 = Point2{Float64}(Y[1] / Y[3] + 0.002randn(rng), Y[2] / Y[3] + 0.002randn(rng))
        (in_view(x1) && in_view(x2)) || continue
        push!(w1, x1); push!(w2, x2)
    end
    in_box() = Point2{Float64}(bx * (2rand(rng) - 1), by * (2rand(rng) - 1))
    for _ in 1:n_out
        push!(w1, in_box()); push!(w2, in_box())
    end
    f1, f2 = 0.7, 0.9
    K1 = SMatrix{3, 3, Float64, 9}(f1, 0, 0, 0, f1, 0, 0.51, 0.39, 1)
    K2 = SMatrix{3, 3, Float64, 9}(f2, 0, 0, 0, f2, 0, 0.48, 0.42, 1)
    x1c = [Point2{Float64}((K1 * SVector(u[1], u[2], 1.0))[1:2]...) for u in w1]
    x2c = [Point2{Float64}((K2 * SVector(u[1], u[2], 1.0))[1:2]...) for u in w2]
    geom = PairGeom(K1, K2, R, SVector{3, Float64}(t), Csponds(x1c, x2c))
    Rp, tp = perturbed_pose(MersenneTwister(11), R, t, 0.02)
    return (; geom, R, t, w1, w2, x1c, x2c, f1, f2, K1, K2, Rp, tp, loss_width = 0.01 * (f1 + f2) / 2)
end
