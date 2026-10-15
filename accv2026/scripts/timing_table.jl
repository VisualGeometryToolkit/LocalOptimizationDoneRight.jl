#!/usr/bin/env julia
# =============================================================================
# scripts/timing_table.jl — the LO per-call timings of main-paper Table 1
# (figures/table_design.tex): isolated single-thread wall-clock per LO call
# for the paper's LO arms on PhotoTourism, each at ITS OWN deployed operating
# point read through the gate-enforced deployed_budget_settings (fig3's
# sidecar). The same timing sidecar feeds the budget cell's time panel
# (configs/pt_e_budget.toml [render.time]).
#
# RUN LAST, ON A QUIET NODE (submit --exclusive after every other job):
# time_ns() brackets must be uncontended for the µs/call table to be honest.
#
# DATA INPUTS
#   the PT-E pool + EXP_MISCAL_SIDECAR (fig3_composed_miscal.jl stage cv).
# STAGES
#   time_pt      (1 thread) → EXP_TIMING_DIR/lo_timing_pt_sift_*.jld2
#   design_table (CPU)      → figures/table_design.tex
#
# paper-project: allow P1 the timing file lives in EXP_TIMING_DIR, the shared unkeyed directory of the deferred D2 entry (test/test_paper_project.jl); its provenance record moves with that fix (a keyed Timing/timing-<run key> directory under the results tree)
# paper-project: allow P2 same deferral: the output directory becomes keyed by this config's run key with the D2 fix; the file name is keyed by [timing] tag and scene today
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2
include(srcdir("config.jl"))
include(srcdir("common.jl"))
include(srcdir("registry.jl"))

# The configuration of record: the fixture and the protocol section.
const CFG_PATH = projectdir("configs", "timing_table.toml")
const CFG = load_run_config(CFG_PATH)
const TIMING = CFG["timing"]
joinpath(data_root(), CFG["experiment"]["pool_dir"]) == EXP_POOL_PT_E ||
    error("configs/timing_table.toml pool_dir is not the PT-E pool of record ($(EXP_POOL_PT_E))")
const PT_OUT = joinpath(EXP_TIMING_DIR, "lo_timing_$(TIMING["tag"])_$(TIMING["scene"]).jld2")

STAGES = Stage[]
push!(STAGES, Stage(:time_pt,
        "PT per-call LO timing @ deployed optima (single-thread) → $(PT_OUT)",
        () -> fresher(PT_OUT, EXP_MISCAL_SIDECAR),
        () -> begin
            # The Table 1 roster of record (fig3_composed_miscal.jl stage cv);
            # the timing driver reads its IG +LO / MSAC +PoseLib / IG +Lift optima.
            require_input(EXP_MISCAL_SIDECAR; what = "deployed operating-points sidecar",
                          provenance = "fig3_composed_miscal.jl stage cv")
            audit_operating_points(ROSTER, EXP_MISCAL_SIDECAR)
            run_driver("time_lo_supp.jl",
                       "--tag=$(TIMING["tag"])", "--sb-protocol=$(TIMING["sb_protocol"])", "--pool=$(EXP_POOL_PT_E)",
                       "--outdir=$(EXP_TIMING_DIR)", "--scene=$(TIMING["scene"])", "--npairs=$(TIMING["npairs"])",
                       "--operating-points=$(EXP_MISCAL_SIDECAR)"; threads = 1)
        end))
# Main-paper Table 1 (2026-09-07): the optimizer taxonomy carries each arm's
# PhotoTourism per-call time in its cell, generated from the same sidecar.
const DESIGN_TABLE = joinpath(PAPER_FIGDIR, "table_design.tex")
push!(STAGES, Stage(:design_table,
        "Table 1: taxonomy grid with per-call µs (PhotoTourism) → $(DESIGN_TABLE)",
        () -> fresher(DESIGN_TABLE, PT_OUT),
        () -> begin
            require_input(PT_OUT; what = "PT timing sidecar", provenance = "stage time_pt of this experiment")
            run_driver("emit_design_table.jl", "--timing=$(PT_OUT)", "--out=$(DESIGN_TABLE)")
        end))

run_stages("timing_table", STAGES)
