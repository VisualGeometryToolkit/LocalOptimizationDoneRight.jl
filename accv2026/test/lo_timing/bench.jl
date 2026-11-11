# =============================================================================
# accv2026/test/lo_timing/bench.jl — the LO timing benchmark of the paper's
# Table 1 arms that refine under its Student-t + uniform marginal
# (RANSACScoringDoneRight): LocalOptimizationDoneRight's strategies at the
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

using LocalOptimizationDoneRight, VisualGeometryToolkitEstimation, VisualGeometryToolkitCore, RANSACScoringDoneRight
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
include(joinpath(pkgdir(LocalOptimizationDoneRight), "test", "lo_timing", "call_set.jl"))   # read_fixture, pool_csponds, problem_of (the package bench's)
include(joinpath(pkgdir(VisualGeometryToolkitCore), "test", "lo_timing", "bench_record.jl"))   # calibration_spread, kernel_arm, write_bench_record: the record the gate reads (VisualGeometryToolkitCore's)

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

# Each arm as Core's record measures it: (its sorted µs per call over the reps, bytes per call).
function lo_arm(ctor)
    return function ()
        lo = ctor()
        run_set(lo); run_set(lo)                                   # compile + warm the task-local buffers
        bytes = @allocated run_set(lo)
        return sort!([time_set(lo) for _ in 1:REPS]), bytes / NCALLS
    end
end

write_bench_record(OUT, "accv2026/test/lo_timing/bench.jl", NCALLS, REPS, [name => lo_arm(ctor) for (name, ctor) in ARMS])
