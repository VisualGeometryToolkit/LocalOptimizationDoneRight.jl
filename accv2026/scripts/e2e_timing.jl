#!/usr/bin/env julia
# provenance: inputs declared via require_input; see REPRODUCE.md.
# =============================================================================
# scripts/e2e_timing.jl — THE end-to-end TIMING cell (--config=<name>, a
# configs/*.toml with a [timing] table; the main paper's is pt_e_e2e_timing):
# the time row of Tab. 3. Ours and SupeRANSAC on the SAME pairs drawn from the
# e2e cell's test units ([timing] sample, VisualGeometryToolkitEval unit sampling),
# each repeat a fresh single-threaded process pinned to one CPU
# ([timing.pinning], numactl), [timing] repeats runs per system, the two
# systems alternating (src/e2e_timing.jl). The accuracy rows are not touched:
# they are the e2e cell's (scripts/e2e_ransac.jl), whose table stage reads this
# cell's timing.tsv for its time row ([render] time).
#
# STAGES
#   inputs   (CPU) — the drawn pairs (sample.toml), ours' pool records and
#                    SupeRANSAC's raw-pixel slices of them → timing-<key>/inputs/
#   repeats  (CPU, ONE pinned core) — repeats × {ours, SupeRANSAC} → <system>_r<r>.jld2
#   summary  (CPU) — the time row and its run-to-run spread → timing.tsv,
#                    the machine around every repeat → timing_repeats.toml
#
#   julia --project=. scripts/e2e_timing.jl --config=pt_e_e2e_timing
#   (the repeats stage needs SupeRANSAC: scripts/superansac_e2e.jl --check; run it
#    on a quiet machine — timing_repeats.toml records the load around every repeat)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, TOML, Dates
include(srcdir("cell_stages.jl"))
include(srcdir("e2e_cells.jl"))
include(srcdir("e2e_timing.jl"))

const CFG_NAME = cli_option(ARGS, "config")
const CFG_PATH = projectdir("configs", CFG_NAME * ".toml")
const CFG = e2e_timing_cell(CFG_NAME)
const KEY = run_key(CFG)
const OUTDIR = e2e_timing_dir(CFG)
const R = Int(CFG["timing"]["repeats"])
const E2E = e2e_timed_cell(CFG)
const LIVE = joinpath(e2e_cell_dir(E2E), "live.jld2")
const SR = e2e_timed_superansac(CFG)
const SUMMARY = timing_summary_path(OUTDIR)

_inputs_done() = isfile(timing_sample_path(OUTDIR)) &&
                 all(s -> isfile(timing_pairs_path(OUTDIR, s)) && isfile(timing_sr_inputs_path(OUTDIR, s)),
                     first(read_timing_sample(OUTDIR)))
"Repeat r runs ours first when r is odd, SupeRANSAC first when even (drift falls on both alike)."
_order(r) = isodd(r) ? ("ours", "superansac") : ("superansac", "ours")
_repeats_done() = all(isfile(timing_repeat_path(OUTDIR, sys, r)) for r in 1:R for sys in ("ours", "superansac"))

function _repeats()
    require_superansac(SR)
    for r in 1:R, sys in _order(r)
        run_timing_repeat(CFG, CFG_NAME, OUTDIR, sys, r)
    end
end

"The git commit (and whether its tree is dirty) of every checkout the repeats ran."
function _code_record()
    mods = (LocalOptimizationDoneRight, VisualGeometryToolkitCore, VisualGeometryToolkitEstimation, RansacScoringDoneRight, VisualGeometryToolkitEval)
    Dict{String,Any}(string(nameof(m)) => begin
                         d = pkgdir(m)
                         head = readchomp(`git -C $d rev-parse HEAD`)
                         dirty = !isempty(readchomp(`git -C $d status --porcelain --untracked-files=no`))
                         head * (dirty ? "-dirty" : "")
                     end for m in mods)
end

function _summary()
    require_input(LIVE; what = "the e2e cell's accuracy run", provenance = "scripts/e2e_ransac.jl --config=$(CFG["timing"]["e2e_config"]) stage live")
    path = timing_summary!(CFG, CFG_NAME, OUTDIR)
    open(joinpath(OUTDIR, "timing_code.toml"), "w") do io
        println(io, "# The code the timed repeats ran (each package's checkout; this project's commit is _provenance.toml's).")
        TOML.print(io, _code_record(); sorted = true)
    end
    write_run_records(OUTDIR, CFG; driver = "e2e_timing.jl", config_source = CFG_PATH, key = KEY,
                      inputs = [joinpath(data_root(), CFG["experiment"]["pool_dir"]), LIVE])
    print(read(path, String))
end

STAGES = Stage[
    Stage(:inputs, "the drawn pairs ([timing] sample) of the e2e cell $(CFG["timing"]["e2e_config"]) and their inputs " *
                   "(config $(CFG_NAME), key $(KEY)) → $(joinpath(OUTDIR, "inputs"))",
          _inputs_done, () -> timing_inputs!(CFG, OUTDIR)),
    Stage(:repeats, "$(R) pinned single-threaded repeats × {ours, SupeRANSAC} on CPU $(CFG["timing"]["pinning"]["cpu"]) → $(OUTDIR)",
          _repeats_done, _repeats),
    Stage(:summary, "the time row and its spread → $(SUMMARY)",
          () -> isfile(SUMMARY) && isfile(joinpath(OUTDIR, "_provenance.toml")) &&
                fresher(SUMMARY, (timing_repeat_path(OUTDIR, sys, r) for r in 1:R for sys in ("ours", "superansac"))...),
          _summary),
]
run_stages("e2e_timing[$(CFG_NAME)]", STAGES)
