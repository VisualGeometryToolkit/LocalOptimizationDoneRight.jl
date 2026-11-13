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
# selection's outlier half-width. Little-endian binary, written once:
# VisualGeometryToolkitEstimation's test/lo_timing/ holds it and its one reader,
# call_set.jl (VisualGeometryToolkitEstimation's and LocalOptimizationDoneRight's
# gates time their arms on the same file):
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
using VisualGeometryToolkitEstimation: RansacWorkspace
using VisualGeometryToolkitCore: Irls
using VisualGeometryToolkitCore: StudentTUniformScoring, JeffreysPrior, FlatLabelPrior   # the Student-t scorer (Core's) and its priors
using VisualGeometryToolkitCore: IGPrior
using StaticArrays, LinearAlgebra, Random

const OUT = ARGS[1]
const REPS = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 7

Threads.nthreads() == 1 || error("bench.jl: run single-threaded (julia -t 1); got $(Threads.nthreads()) threads")

# =============================================================================
# The Table 1 arms on the recorded call set
# =============================================================================
include(joinpath(pkgdir(VisualGeometryToolkitEstimation), "test", "lo_timing", "call_set.jl"))   # CALL_SET_FIXTURE, read_fixture, pool_correspondences, problem_of: the call set's one reader (VisualGeometryToolkitEstimation's)
include(joinpath(pkgdir(VisualGeometryToolkitCore), "test", "lo_timing", "bench_record.jl"))   # calibration_spread, kernel_arm, write_bench_record: the record the gate reads (VisualGeometryToolkitCore's)

# The Table 1 arms at the equal LO budget. The efficiency constants are the Welsch
# grid's centre (GM at the Welsch half-weight depth's GM width, as accv2026's arm
# table maps it) — the width barely moves per-call time; the protocol's GNC entry is 16.
const BUDGET = 25
const GM_MULTIPLE = VisualGeometryToolkitCore.decision_width(GemanMcclureShape(), 1.5 * sqrt(log(2.0)))
const ARMS = [
    "Welsch-HQ"   => () -> HQ{WelschShape}(; max_iter = BUDGET, efficiency_constant = 1.6),
    "Welsch-GNC"  => () -> Gnc{Irls{WelschShape}}(; max_iter = BUDGET, efficiency_constant = 1.5, entry = 16.0),
    "GM-HQ"       => () -> HQ{GemanMcclureShape}(; max_iter = BUDGET, efficiency_constant = GM_MULTIPLE),
    "GM-GNC"      => () -> Gnc{Irls{GemanMcclureShape}}(; max_iter = BUDGET, efficiency_constant = 1.5),
    "TLS-HQ"      => () -> HQ{SmoothTLSShape}(; max_iter = BUDGET, efficiency_constant = 2.5),
    "TLS-GNC"     => () -> Gnc{Irls{TLSShape}}(; max_iter = BUDGET, efficiency_constant = 2.5),
    "Stu-t-IRLS"  => () -> StudentTUniform(; max_iter = BUDGET),
    "Stu-tU-BCD"  => () -> StuTuBCD(; max_iter = BUDGET),
]

const PAIRS, HALFWIDTH = read_fixture(CALL_SET_FIXTURE)
const PROBS = [problem_of(pr) for pr in PAIRS]
const SCORINGS = [StudentTUniformScoring(EssentialProblem, HALFWIDTH; scale_prior = IGPrior(0.0, 0.0), label_prior = FlatLabelPrior()) for _ in PROBS]
const WORKSPACES = [RansacWorkspace(PROBS[i], SCORINGS[i]) for i in eachindex(PROBS)]
const NCALLS = call_set_size(PAIRS)

# Each arm as Core's record measures it: VisualGeometryToolkitEstimation's `lo_call_set_arm` (call_set.jl, THE binding of every LO
# timing bench), `locally_optimize` of pair i's problem from each recorded seed with this bench's Student-t scorings and workspaces:
# its sorted µs per call over the reps, bytes per call.
write_bench_record(OUT, "accv2026/test/lo_timing/bench.jl", NCALLS, REPS,
                   [name => lo_call_set_arm(ctor, PROBS, SCORINGS, WORKSPACES, PAIRS, REPS) for (name, ctor) in ARMS])
