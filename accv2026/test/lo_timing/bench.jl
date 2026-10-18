# =============================================================================
# accv2026/test/lo_timing/bench.jl — the LO timing benchmark of the paper's
# Table 1 arms that refine under its Student-t + uniform marginal
# (RansacScoringDoneRight): LocalOptimizationDoneRight's strategies at the
# equal LO budget (25 model updates) — Welsch, GM and TLS under the HQ lift /
# GNC, the Student-t + uniform IRLS and BCD. Moved from the library's
# test/lo_timing (K+, 2026-10-09: its test target names no scorer package;
# the PoseLib arms and the lift kernels stay timed there). Run by the opt-in
# gate of accv2026/test/runtests.jl (LO_TIMING_GATE=1; VisualGeometryToolkitCore's
# test/lo_timing/gate.jl policy), in its own single-threaded process pinned to
# one core:
#
#   taskset -c <core> julia -t 1 --project=. test/lo_timing/bench.jl <out.toml> [reps]
#
# THE CALL SET `lo_calls_phototourism_e.bin`: 24 recorded local optimizations
# of the ACCV Table 1 timing protocol, 8 PhotoTourism british_museum pairs
# (346–1094 correspondences, the pool frame of VisualGeometryToolkitEval's PT-E-SIFT
# pool) × 3 RANSAC LO-checkpoint seeds each (the first, middle and last
# checkpoint of the Welsch-IRLS run of record), the camera matrices and the
# selection's outlier half-width. Little-endian binary, written once (the same
# file VisualGeometryToolkitEstimation's and LocalOptimizationDoneRight's gates time
# their arms on):
#
#   "LOFX0001" | npairs::Int64 | nseeds::Int64 | outlier_halfwidth::Float64 |
#   per pair: n::Int64, Kc1 (9, column-major), Kc2 (9), x1 (2n), x2 (2n),
#             nseeds seeds E (9 each, column-major)
#
# A "call" is one `locally_optimize` under the Jeffreys marginal at the
# recorded outlier half-width.
#
# OUTPUT: per arm, the min and every rep's µs per call, and the bytes
# allocated per call after warm-up; plus the host and a calibration loop's
# spread (the noise probe). `ncalls` is the call set's size.
# =============================================================================

using LocalOptimizationDoneRight, VisualGeometryToolkitEstimation, VisualGeometryToolkitCore, RansacScoringDoneRight
using LocalOptimizationDoneRight: HQ, Gnc, StudentTUniform, StuTuBCD
using VisualGeometryToolkitEstimation: RansacWorkspace, Irls
using VisualGeometryToolkitCore: IGPrior
using StaticArrays, LinearAlgebra, Random

const FIXTURE = joinpath(@__DIR__, "lo_calls_phototourism_e.bin")
const OUT = ARGS[1]
const REPS = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 7

Threads.nthreads() == 1 || error("bench.jl: run single-threaded (julia -t 1); got $(Threads.nthreads()) threads")

# =============================================================================
# The Table 1 arms on the recorded call set
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

# The Table 1 arms at the equal LO budget. The scale multiples are the Welsch
# grid's centre (GM in its half-weight currency, as accv2026's arm table maps
# it) — the width barely moves per-call time; the protocol's GNC entry is 16.
const BUDGET = 25
const GM_MULTIPLE = 1.5 * sqrt(log(2.0))
const ARMS = [
    "Welsch-HQ"   => () -> HQ{WelschShape}(; max_iter = BUDGET, scale_multiple = 1.6),
    "Welsch-GNC"  => () -> Gnc{Irls{WelschShape}}(; max_iter = BUDGET, scale_multiple = 1.5, entry = 16.0),
    "GM-HQ"       => () -> HQ{GemanMcclureShape}(; max_iter = BUDGET, scale_multiple = GM_MULTIPLE),
    "GM-GNC"      => () -> Gnc{Irls{GemanMcclureShape}}(; max_iter = BUDGET, scale_multiple = 1.5),
    "TLS-HQ"      => () -> HQ{SmoothTLSShape}(; max_iter = BUDGET, scale_multiple = 2.5),
    "TLS-GNC"     => () -> Gnc{Irls{TLSShape}}(; max_iter = BUDGET, scale_multiple = 2.5),
    "Stu-t-IRLS"  => () -> StudentTUniform(; max_iter = BUDGET),
    "Stu-tU-BCD"  => () -> StuTuBCD(; max_iter = BUDGET),
]

const PAIRS, HALFWIDTH = read_fixture(FIXTURE)
const PROBS = [problem_of(pr) for pr in PAIRS]
const SCORINGS = [StudentTUniformScoring(EssentialProblem, HALFWIDTH; prior = IGPrior(0.0, 0.0)) for _ in PROBS]
const WORKSPACES = [RansacWorkspace(PROBS[i], SCORINGS[i]) for i in eachindex(PROBS)]
const NCALLS = sum(length(pr.seeds) for pr in PAIRS)

lo_call(lo, i, seed) =
    locally_optimize(PROBS[i], seed; local_optimization = lo, scoring = SCORINGS[i], workspace = WORKSPACES[i])

function run_set(lo)
    for i in eachindex(PROBS), s in PAIRS[i].seeds
        lo_call(lo, i, s)
    end
    return nothing
end

function time_set(lo)
    t = UInt64(0)
    for i in eachindex(PROBS), s in PAIRS[i].seeds
        t0 = time_ns(); lo_call(lo, i, s); t += time_ns() - t0
    end
    return t / NCALLS / 1.0e3
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
println(io, "# written by accv2026/test/lo_timing/bench.jl")
println(io, "[host]")
println(io, "cpu = ", repr(Sys.cpu_info()[1].model))
println(io, "julia = ", repr(string(VERSION)))
println(io, "calibration_spread = ", calibration_spread(REPS))
println(io, "ncalls = ", NCALLS)
for (name, ctor) in ARMS
    lo = ctor()
    run_set(lo); run_set(lo)                                   # compile + warm the task-local buffers
    bytes = @allocated run_set(lo)
    us = sort!([time_set(lo) for _ in 1:REPS])
    println(io, "[arms.", repr(name), "]")
    println(io, "us_per_call = ", us[1])
    println(io, "reps_us_per_call = [", join(us, ", "), "]")
    println(io, "bytes_per_call = ", bytes / NCALLS)
end
write(OUT, take!(io))
