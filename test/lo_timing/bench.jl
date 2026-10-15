# =============================================================================
# lo_timing/bench.jl — the LO timing benchmark this package's timing gate runs
# (test/test_lo_timing_gate.jl). A standalone script, run in its own
# single-threaded process pinned to one core by the gate:
#
#   taskset -c <core> julia -t 1 --project=<test env> test/lo_timing/bench.jl <out.toml> [reps]
#
# TWO KINDS OF ARM, each timed as it was where it came from. (The Table 1
# arms that refine under the paper's Student-t + uniform marginal — the HQ
# lifts, GNC, the Stu-tU IRLS and BCD — are timed in accv2026/test/lo_timing:
# the library's test target names no scorer package.)
#
# THE PoseLib TABLE 1 ARMS (from this package's former PoseLib bench,
# lo_timing_poselib/): PoseLib's truncated LM (TLS-IRLS) and its Le–Zach
# variant (TLS-LZ) at the equal LO budget (25), on THE CALL SET
# `lo_calls_phototourism_e.bin`: 24 recorded local optimizations of the ACCV
# Table 1 timing protocol, 8 PhotoTourism british_museum pairs (346–1094
# correspondences, the pool frame of VisualGeometryEval's PT-E-SIFT pool) × 3
# RANSAC LO-checkpoint seeds each (the first, middle and last checkpoint of the
# Welsch-IRLS run of record), the camera matrices and the selection's outlier
# half-width. Little-endian binary, written once (the same file
# RobustVisualGeometry's gate times its core arms on):
#
#   "LOFX0001" | npairs::Int64 | nseeds::Int64 | outlier_halfwidth::Float64 |
#   per pair: n::Int64, Kc1 (9, column-major), Kc2 (9), x1 (2n), x2 (2n),
#             nseeds seeds E (9 each, column-major)
#
# The truncation loss width is the selection's outlier half-width as the
# absolute pool-frame loss width (the arms' `LossWidth` currency). They are
# external refiners, timed through VisualGeometryCore's external-refit contract
# directly: `external_workspace` once per pair (outside the timing), then one
# `refine_external!(ws, lo, problem, seed, LossWidth(w), scoring)` per call —
# the E seed's cheirality plus PoseLib's `refine_relpose`, the bracket Table 1
# reports (the refit layer's `lo_ns`); the pose → essential conversion is
# inside it now (negligible). The arms read no scoring (they are handed `nothing`).
# A "call" is one `refine_external!`. `import PoseLib` loads the solver calls
# (the package's PoseLib extension).
#
# THE LIFT KERNELS (from VisualGeometryCore's bench, with the lift core): the
# joint-(θ,z) HQ and the GNC normal-equation accumulations on the 5-dof
# essential chart (`_lift_hq_increment!`, `_lift_gnc_increment!` over
# VisualGeometryCore's chart rows), on a fixed seeded scene of 1000
# correspondences (f = 800 px, 30 % outliers; deterministic, no fixture). A
# "call" is one sweep over the scene.
#
# OUTPUT: per arm, the min and every rep's µs per call, and the bytes
# allocated per call after warm-up; plus the host and a calibration loop's
# spread (the noise probe). `ncalls` is the Table 1 call set's size.
# =============================================================================

using LocalOptimizationDoneRight, RobustVisualGeometry, VisualGeometryCore
import PoseLib                # the PoseLib extension: the truncated refiners' solver calls
using LocalOptimizationDoneRight: LiftState, _lift_hq_increment!, _lift_gnc_increment!, _seed_lift_z!,
    PoseLibLm, PoseLibLZ
using VisualGeometryCore: RowsWorkspace, sampson_rows!, sampson_jacobian_rows!, retract, retract_directions,
    zero_tangent, backproject_with_jacobian, EssentialManifold5, deploy, external_workspace, refine_external!,
    LossWidth
using StaticArrays, LinearAlgebra, Random

const FIXTURE = joinpath(@__DIR__, "lo_calls_phototourism_e.bin")
const OUT = ARGS[1]
const REPS = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 7

Threads.nthreads() == 1 || error("bench.jl: run single-threaded (julia -t 1); got $(Threads.nthreads()) threads")

# =============================================================================
# The recorded call set
# =============================================================================
function read_fixture(path)
    open(path) do io
        String(read(io, 8)) == "LOFX0001" || error("$path: not a LOFX0001 fixture")
        npairs = read(io, Int64); nseeds = read(io, Int64); halfwidth = read(io, Float64)
        rd(k) = [read(io, Float64) for _ in 1:k]
        pairs = map(1:npairs) do _
            n = Int(read(io, Int64))
            Kc1 = SMatrix{3, 3, Float64, 9}(rd(9)); Kc2 = SMatrix{3, 3, Float64, 9}(rd(9))
            x1 = reshape(rd(2n), 2, n); x2 = reshape(rd(2n), 2, n)
            seeds = [EssentialMat(Tuple(rd(9))) for _ in 1:nseeds]
            (; n, Kc1, Kc2, x1, x2, seeds)
        end
        eof(io) || error("$path: trailing bytes")
        return pairs, halfwidth
    end
end

# The pair's pool-frame correspondences, and its E problem (their bearings
# through the pool-frame cameras).
function pool_csponds(pr)
    P2 = Point2{Float64}
    return Csponds([P2(pr.x1[1, i], pr.x1[2, i]) for i in 1:pr.n], [P2(pr.x2[1, i], pr.x2[2, i]) for i in 1:pr.n])
end
problem_of(pr) = EssentialProblem(CameraModel(pr.Kc1), CameraModel(pr.Kc2), pool_csponds(pr))

# =============================================================================
# The PoseLib arms on the recorded call set, through the external-refit contract
# =============================================================================
const BUDGET = 25
const PAIRS, HALFWIDTH = read_fixture(FIXTURE)
const PROBS = [problem_of(pr) for pr in PAIRS]
const NCALLS = sum(length(pr.seeds) for pr in PAIRS)

const EXTERNAL_ARMS = [
    "TLS-IRLS" => () -> PoseLibLm(BUDGET),
    "TLS-LZ"   => () -> PoseLibLZ(BUDGET),
]
# The refit's two-view frame (VisualGeometryEval hands over its pair geometry): the
# pool-frame calibrations and correspondences.
const FRAMES = [(; Kc1 = pr.Kc1, Kc2 = pr.Kc2, cs = pool_csponds(pr)) for pr in PAIRS]
# The truncation loss width, absolute in the pool frame: the selection's
# outlier half-width of the call set.
const LOSS_WIDTH = LossWidth(HALFWIDTH)

external_workspaces(lo) = [external_workspace(lo, PROBS[i], FRAMES[i], nothing) for i in eachindex(PROBS)]
ext_call(ws, lo, i, seed) = refine_external!(ws[i], lo, PROBS[i], seed, LOSS_WIDTH, nothing)

function run_external_set(ws, lo)
    for i in eachindex(PROBS), s in PAIRS[i].seeds
        ext_call(ws, lo, i, s)
    end
    return nothing
end

function time_external_set(ws, lo)
    t = UInt64(0)
    for i in eachindex(PROBS), s in PAIRS[i].seeds
        t0 = time_ns(); ext_call(ws, lo, i, s); t += time_ns() - t0
    end
    return t / NCALLS / 1.0e3
end

# =============================================================================
# The lift kernels on the seeded scene
# =============================================================================
const SWEEPS = 200            # sweeps per rep (one "call" = one sweep)
const N = 1000
const RNG = Xoshiro(20261007)
const K = SMatrix{3, 3, Float64, 9}(800, 0, 0, 0, 800, 0, 640, 480, 1)
const R = SMatrix{3, 3, Float64, 9}(exp([0 -0.1 0.05; 0.1 0 -0.02; -0.05 0.02 0]))
const T = normalize(SVector(1.0, 0.1, 0.05))
function scene()
    u1 = Point2{Float64}[]; u2 = Point2{Float64}[]
    while length(u1) < N
        X = SVector(4 * rand(RNG) - 2, 3 * rand(RNG) - 1.5, 4 + 4 * rand(RNG))
        Y = R * X + T
        p1 = K * X; p2 = K * Y
        if rand(RNG) < 0.3
            push!(u1, Point2(1280 * rand(RNG), 960 * rand(RNG))); push!(u2, Point2(1280 * rand(RNG), 960 * rand(RNG)))
        else
            push!(u1, Point2(p1[1] / p1[3], p1[2] / p1[3]) + Point2(0.5 * randn(RNG), 0.5 * randn(RNG)))
            push!(u2, Point2(p2[1] / p2[3], p2[2] / p2[3]) + Point2(0.5 * randn(RNG), 0.5 * randn(RNG)))
        end
    end
    return u1, u2
end
const U1, U2 = scene()
const CAM = CameraModel(K)
const FM1 = [backproject_with_jacobian(CAM, u) for u in U1]
const FM2 = [backproject_with_jacobian(CAM, u) for u in U2]
const F1 = first.(FM1); const F2 = first.(FM2); const M1 = last.(FM1); const M2 = last.(FM2)
const CHE = EssentialManifold5(EssentialMat(R, T))
const RWS = RowsWorkspace{5, 1}(N)        # the chart rows (VisualGeometryCore)
const LS = LiftState{5}(N)                # the lift's own state
const WELSCH = deploy(WelschShape(), 1.0; scale_multiple = 1.5)
const GM = deploy(GemanMcclureShape(), 1.0; scale_multiple = 1.25)

const aE = zero_tangent(CHE)
const EE = retract(CHE, aE); const dE = retract_directions(CHE, aE)
sampson_rows!(RWS.r, EE, F1, F2, RWS.onev; M₁ = M1, M₂ = M2)
sampson_jacobian_rows!(RWS.J, EE, dE, F1, F2, RWS.onev; M₁ = M1, M₂ = M2)
_seed_lift_z!(LS, WELSCH, RWS.r, N, :flat)

const KERNELS = [
    "lift-HQ"  => () -> _lift_hq_increment!(RWS, LS, WELSCH, 1.0e-9, N, nothing),
    "lift-GNC" => () -> _lift_gnc_increment!(RWS, LS, GM, 4.0, N, nothing),
]

function time_kernel(f)
    t0 = time_ns()
    for _ in 1:SWEEPS
        f()
    end
    return (time_ns() - t0) / SWEEPS / 1.0e3
end

# The noise probe: a fixed arithmetic loop timed REPS times; its relative spread
# (second-fastest over fastest − 1) is the machine's jitter on this core.
function calibration_spread(reps)
    f() = (s = 0.0; x = 1.0; for k in 1:2_000_000; x = muladd(x, 1.0000001, 1.0e-9); s += x; end; s)
    f(); ts = Float64[]
    for _ in 1:reps
        t0 = time_ns(); v = f(); push!(ts, time_ns() - t0); v > 0 || error()
    end
    sort!(ts)
    return ts[2] / ts[1] - 1
end

io = IOBuffer()
println(io, "# written by test/lo_timing/bench.jl")
println(io, "[host]")
println(io, "cpu = ", repr(Sys.cpu_info()[1].model))
println(io, "julia = ", repr(string(VERSION)))
println(io, "calibration_spread = ", calibration_spread(REPS))
println(io, "ncalls = ", NCALLS)
for (name, ctor) in EXTERNAL_ARMS
    lo = ctor()
    ws = external_workspaces(lo)                               # once per pair, outside the timing
    run_external_set(ws, lo); run_external_set(ws, lo)         # compile + warm
    bytes = @allocated run_external_set(ws, lo)
    us = sort!([time_external_set(ws, lo) for _ in 1:REPS])
    println(io, "[arms.", repr(name), "]")
    println(io, "us_per_call = ", us[1])
    println(io, "reps_us_per_call = [", join(us, ", "), "]")
    println(io, "bytes_per_call = ", bytes / NCALLS)
end
for (name, f) in KERNELS
    f(); f()
    bytes = @allocated f()
    us = sort!([time_kernel(f) for _ in 1:REPS])
    println(io, "[arms.", repr(name), "]")
    println(io, "us_per_call = ", us[1])
    println(io, "reps_us_per_call = [", join(us, ", "), "]")
    println(io, "bytes_per_call = ", Float64(bytes))
end
write(OUT, take!(io))
