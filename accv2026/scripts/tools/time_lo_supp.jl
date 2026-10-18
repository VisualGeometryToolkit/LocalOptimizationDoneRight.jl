#!/usr/bin/env julia
# =============================================================================
# time_lo_supp.jl — isolated single-thread LO wall-clock timing for the
# SUPPLEMENT's per-call timing table. Times every arm the arm table marks as
# timed (arm_rosters.jl TIMING_TAGS), built by the table's own constructors at
# the deployed scale multiple: one evaluate_sample_budget run per run tag, whose :ig
# column carries that arm's per-call time; the truncated MSAC / Le-Zach refits
# (TLS-IRLS / TLS-LZ) ride the Stu-t-IRLS run as its :msac / :lezach columns.
#
# Single-threaded (`julia -t 1`): the per-pair `Threads.@threads` loop is serial,
# so every `time_ns()` bracket measures a clean, uncontended optimizer call.
#
# Usage:
#   julia -t 1 --project=<RVG> time_lo_supp.jl [--pool=DIR] [--scene=NAME]
#                                              [--npairs=N] [--outlier-halfwidth=W] [--loss-width=T]
#                                              [--scale-multiple=M] [--tag=LABEL]
# Defaults reproduce the PhotoTourism (main-paper) timing; supply --pool/--outlier-halfwidth/--loss-width
# to time on ScanNet at its own val-tuned operating point.
# Output: $OUT/lo_timing_<tag>_<scene>.jld2 + a printed per-method table.
#
# paper-project: allow P1 a worker of scripts/timing_table.jl; the timing directory is the deferred D2 entry (test/test_paper_project.jl), and the record moves with it
# paper-project: allow P2 the caller names the output directory (--outdir) and the file by tag and scene (configs/timing_table.toml); keyed with the D2 fix
# =============================================================================

using DrWatson; @quickactivate "ACCV2026"   # the project this tool runs under (srcdir/projectdir)
using VisualGeometryToolkitEstimation; const RVG = VisualGeometryToolkitEstimation
using VisualGeometryToolkitEval.Pools: load_pool, load_pool_residuals, residuals_path, residual_matrix
import PoseLib, JLD2
using Printf
import TOML
using VisualGeometryToolkitEstimation: EssentialProblem
include(srcdir("config.jl"))


if Threads.nthreads() != 1
    @warn "nthreads = $(Threads.nthreads()) > 1 — per-call times include thread " *
          "contention. Re-run with `julia -t 1` for ISOLATED per-call timing."
end

const POOL   = cli_option(ARGS, "pool")      # the caller's pool tree (timing_table.jl: EXP_POOL_PT_E)
const OUT    = cli_option(ARGS, "outdir")    # the caller's output dir (timing_table.jl: EXP_TIMING_DIR)
const TAG    = cli_option(ARGS, "tag", "pt")
mkpath(OUT)

# Operating point: --operating-points=PATH (or SB_OPERATING_POINTS) reads the deployed
# tuned optima through `deployed_budget_settings` — THE gate-enforced
# reader (interior-argmin invariant; a clipped sidecar hard-errors here), so
# each dataset is timed at ITS OWN tuned operating point from the ONE tuning
# path. Explicit --outlier-halfwidth/--loss-width/--scale-multiple win (smoke
# only); without a sidecar every one of them is REQUIRED — there is no fallback
# operating point. The retired `--cv=cv.jld2` shared-knob-CV consumer was
# REMOVED 2026-07-18 with that CV path.
const TKPATH = cli_option(ARGS, "operating-points", get(ENV, "SB_OPERATING_POINTS", ""))
const _DEP = isempty(TKPATH) ? nothing : Dict(deployed_budget_settings(ROSTER, TKPATH))
_operating_point(flag, deployed) = _DEP === nothing ? parse(Float64, cli_option(ARGS, flag)) :
                                                      parse(Float64, cli_option(ARGS, flag, string(deployed(_DEP))))
const OUTLIER_HALFWIDTH = _operating_point("outlier-halfwidth", d -> d["IG  +LO"].sel)
const LOSS_WIDTH        = _operating_point("loss-width",        d -> d["MSAC +PoseLib"].ref)
# the paper's Welsch-HQ (configs/protocol.toml [paper] welsch_hq) — the arm the "Welsch-HQ" run times
const SCALE_MULTIPLE    = _operating_point("scale-multiple",    d -> lo_width(d[PAPER_WELSCH_HQ].lo).value)

scene  = cli_option(ARGS, "scene")                  # the timing fixture: required, stated by the caller (timing_table.jl)
npairs = parse(Int, cli_option(ARGS, "npairs"))

const POOL_FILE = joinpath(POOL, "$scene.jld2")
pool = load_pool(POOL_FILE)                    # THE pool reader (VisualGeometryToolkitEval.Pools)
const IDX = collect(1:min(npairs, length(pool)))
sub  = pool.pairs[IDX]
sub_R = let res = load_pool_residuals(residuals_path(POOL_FILE), pool; pairs = IDX)
    [residual_matrix(res, i) for i in IDX]
end
println("timing on $(length(sub)) pairs of $scene  (tag=$TAG, nthreads=$(Threads.nthreads()))"); flush(stdout)

const METHODS = [SampleBudgetMethodSpec(:ig, StudentTUniformScoring(EssentialProblem, OUTLIER_HALFWIDTH))]   # Jeffreys
# The LO checkpoint schedule of the timed dataset: its section of the
# sample-budget protocol of record (--sb-protocol, required; timing_table.jl).
const SBP = TOML.parsefile(projectdir("configs", "sample_budget_protocol.toml"))[cli_option(ARGS, "sb-protocol")]
cfgf(lo) = SampleBudgetConfig(; lo_strategy = lo, sample_cap = Int(SBP["sample_cap"]),
                              batch_size = Int(SBP["batch_size"]), lo_every = Int(SBP["lo_every"]),
                              budget_unit = Symbol(SBP["budget_unit"]))
# A rider column's MSAC spec (evaluate_sample_budget's `msac_specs`): MSAC at
# the deployed LOSS_WIDTH, refit by PoseLib's truncated refiner (TLS-LM, TLS-LZ)
# at the evaluation's equal LO budget.
const RIDER_SPECS = Dict(:msac   => MsacSpec(:msac, LOSS_WIDTH, PoseLibLm(lo_iteration_budget())),
                         :lezach => MsacSpec(:lezach, LOSS_WIDTH, PoseLibLZ(lo_iteration_budget())))

# One run per run tag: the arm whose :ig column the tag names supplies the
# strategy (at SCALE_MULTIPLE on the shared grid; it barely affects per-call timing),
# the arms riding the tag supply its MSAC specs.
const RUN_TAGS = unique(tag for (tag, col) in values(TIMING_TAGS) if col === :ig)
runs = map(sort(RUN_TAGS)) do tag
    owner = only(k for (k, (t, c)) in TIMING_TAGS if t == tag && c === :ig)
    cols = Set(c for (t, c) in values(TIMING_TAGS) if t == tag && c !== :ig)
    riders = MsacSpec[RIDER_SPECS[c] for c in (:msac, :lezach) if c in cols]
    (tag, evaluate_sample_budget(EssentialProblem, METHODS, sub, sub_R;
                                 msac_specs = riders,
                                 cfg = cfgf(arm_strategy(ARM_TABLE[owner], SCALE_MULTIPLE))))
end

println("\n=== Isolated LO timing  (tag=$TAG, scene=$scene, $(length(sub)) pairs, nthreads=$(Threads.nthreads())) ===")
@printf("  %-14s %-9s %12s %9s %12s\n", "run", "method", "µs/call", "calls", "startup ms")
for (tag, r) in runs, row in summarize_lo_timing(r)
    row.method === :oracle && continue
    @printf("  %-14s %-9s %12.1f %9d %12.1f\n", tag, row.method, row.mean_us, row.calls, row.startup_ms)
end

JLD2.jldsave(joinpath(OUT, "lo_timing_$(TAG)_$(scene).jld2");
    tag = TAG, scene = scene, n_pairs = length(sub), nthreads = Threads.nthreads(),
    outlier_halfwidth = OUTLIER_HALFWIDTH, loss_width = LOSS_WIDTH, scale_multiple = SCALE_MULTIPLE,
    runs = [(tag = tag, methods = r.methods, lo_ns_total = r.lo_ns_total,
             lo_calls_total = r.lo_calls_total, lo_startup_ns = r.lo_startup_ns) for (tag, r) in runs])
println("\nsaved -> ", joinpath(OUT, "lo_timing_$(TAG)_$(scene).jld2")); flush(stdout)
