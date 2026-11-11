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
# correspondences, the pool frame of VisualGeometryToolkitEval's PT-E-SIFT pool) × 3
# RANSAC LO-checkpoint seeds each (the first, middle and last checkpoint of the
# Welsch-IRLS run of record), the camera matrices and the selection's outlier
# half-width. Little-endian binary, written once: VisualGeometryToolkitEstimation's
# test/lo_timing/ holds it and its one reader, call_set.jl (its gate times its
# core arms on the same file):
#
#   "LOFX0001" | npairs::Int64 | nseeds::Int64 | outlier_halfwidth::Float64 |
#   per pair: n::Int64, Kc1 (9, column-major), Kc2 (9), x1 (2n), x2 (2n),
#             nseeds seeds E (9 each, column-major)
#
# The truncation loss width is the selection's outlier half-width as the
# absolute pool-frame loss width (the arms' `LossWidth` currency). They are
# external refiners, timed through VisualGeometryToolkitCore's external-refit contract
# directly: `external_workspace` once per pair (outside the timing), then one
# `refine_external!(ws, lo, problem, seed, LossWidth(w), scoring)` per call —
# the E seed's cheirality plus PoseLib's `refine_relpose`, the bracket Table 1
# reports (the refit layer's `lo_ns`); the pose → essential conversion is
# inside it now (negligible). The arms read no scoring (they are handed `nothing`).
# A "call" is one `refine_external!`. `import PoseLib` loads the solver calls
# (the package's PoseLib extension).
#
# THE LIFT KERNELS (from VisualGeometryToolkitCore's bench, with the lift core): the
# joint-(θ,z) HQ and the GNC normal-equation accumulations on the 5-dof
# essential chart (`_lift_hq_increment!`, `_lift_gnc_increment!` over
# VisualGeometryToolkitCore's chart rows), on a fixed seeded scene of 1000
# correspondences (f = 800 px, 30 % outliers; deterministic, no fixture). A
# "call" is one sweep over the scene.
#
# OUTPUT: per arm, the min and every rep's µs per call, and the bytes
# allocated per call after warm-up; plus the host and a calibration loop's
# spread (the noise probe). `ncalls` is the Table 1 call set's size.
# =============================================================================

using LocalOptimizationDoneRight, VisualGeometryToolkitEstimation, VisualGeometryToolkitCore
import PoseLib                # the PoseLib extension: the truncated refiners' solver calls
using LocalOptimizationDoneRight: LiftState, _lift_hq_increment!, _lift_gnc_increment!, _seed_lift_z!,
    PoseLibLm, PoseLibLZ
using VisualGeometryToolkitCore: RowsWorkspace, sampson_residuals!, sampson_jacobian_rows!, Csponds, withattrs,
    retract, retract_directions,
    zero_tangent, backproject_with_jacobian, EssentialManifold5, deploy, external_workspace, refine_external!,
    LossWidth
using StaticArrays, LinearAlgebra, Random

const OUT = ARGS[1]
const REPS = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 7

Threads.nthreads() == 1 || error("bench.jl: run single-threaded (julia -t 1); got $(Threads.nthreads()) threads")

include(joinpath(pkgdir(VisualGeometryToolkitEstimation), "test", "lo_timing", "call_set.jl"))   # CALL_SET_FIXTURE, read_fixture, pool_csponds, problem_of: the call set's one reader (VisualGeometryToolkitEstimation's)
include(joinpath(pkgdir(VisualGeometryToolkitCore), "test", "lo_timing", "bench_record.jl"))   # calibration_spread, kernel_arm, write_bench_record: the record the gate reads (VisualGeometryToolkitCore's)

# =============================================================================
# The PoseLib arms on the recorded call set, through the external-refit contract
# =============================================================================
const BUDGET = 25
const PAIRS, HALFWIDTH = read_fixture(CALL_SET_FIXTURE)
const PROBS = [problem_of(pr) for pr in PAIRS]
const NCALLS = call_set_size(PAIRS)

const EXTERNAL_ARMS = [
    "TLS-IRLS" => () -> PoseLibLm(BUDGET),
    "TLS-LZ"   => () -> PoseLibLZ(BUDGET),
]
# The refit's two-view frame (VisualGeometryToolkitEval hands over its pair geometry): the
# pool-frame calibrations and correspondences.
const FRAMES = [(; Kc1 = pr.Kc1, Kc2 = pr.Kc2, cs = pool_csponds(pr)) for pr in PAIRS]
# The truncation loss width, absolute in the pool frame: the selection's
# outlier half-width of the call set.
const LOSS_WIDTH = LossWidth(HALFWIDTH)

external_workspaces(lo) = [external_workspace(lo, PROBS[i], FRAMES[i], nothing) for i in eachindex(PROBS)]
ext_call(ws, lo, i, seed) = refine_external!(ws[i], lo, PROBS[i], seed, LOSS_WIDTH, nothing)

# =============================================================================
# The lift kernels on the seeded scene
# =============================================================================
const SWEEPS = 200            # sweeps per rep (one "call" = one sweep)
const N = 1000
const SCENE = essential_bench_scene(Xoshiro(20261007); n = N)   # the seeded E scene (VisualGeometryToolkitCore's bench_record.jl)
const U1, U2, K, R, T = SCENE.u₁, SCENE.u₂, SCENE.K, SCENE.R, SCENE.t
const CAM = CameraModel(K)
const FM1 = [backproject_with_jacobian(CAM, u) for u in U1]
const FM2 = [backproject_with_jacobian(CAM, u) for u in U2]
const F1 = first.(FM1); const F2 = first.(FM2); const M1 = last.(FM1); const M2 = last.(FM2)
const CHE = EssentialManifold5(EssentialMat(R, T))
const RWS = RowsWorkspace{5, 1}(N)        # the chart rows (VisualGeometryToolkitCore)
const LS = LiftState{5}(N)                # the lift's own state
const WELSCH = deploy(WelschShape(), 1.0; efficiency_constant = 1.5)
const GM = deploy(GemanMcclureShape(), 1.0; efficiency_constant = 1.25)

const aE = zero_tangent(CHE)
const EE = retract(CHE, aE); const dE = retract_directions(CHE, aE)
# The bearing pairs as a measurement set, their back-projection Jacobians as
# attribute columns (unit weights: no `sqrt_weights` column).
const XS = withattrs(Csponds(F1, F2); M₁ = M1, M₂ = M2)
sampson_residuals!(RWS.r, EE, XS)
sampson_jacobian_rows!(RWS.J, EE, dE, XS)
_seed_lift_z!(LS, WELSCH, RWS.r, N, :flat)

const KERNELS = [
    "lift-HQ"  => () -> _lift_hq_increment!(RWS, LS, WELSCH, 1.0e-9, N, nothing),
    "lift-GNC" => () -> _lift_gnc_increment!(RWS, LS, GM, 4.0, N, nothing),
]

# Each arm as Core's record measures it (call_set.jl's `call_set_arm`): its sorted µs per call over the reps, bytes
# per call; the workspaces are built once per pair, outside the timing.
external_arm(ctor) = call_set_arm(() -> (lo = ctor(); ws = external_workspaces(lo); (i, seed) -> ext_call(ws, lo, i, seed)), PAIRS, REPS)

write_bench_record(OUT, "test/lo_timing/bench.jl", NCALLS, REPS,
                   [[name => external_arm(ctor) for (name, ctor) in EXTERNAL_ARMS];
                    [name => kernel_arm(f, SWEEPS, REPS) for (name, f) in KERNELS]])
