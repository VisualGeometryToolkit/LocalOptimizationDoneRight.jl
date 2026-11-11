#!/usr/bin/env julia
# =============================================================================
# render_budget.jl — THE renderer of every two-view budget cell
# (src/cell_stages.jl `budget_cell_stages`): the objective-faceted
# accuracy-vs-sample-budget panel (KIND=budget; 3 family panels x {median
# error, mAA@10}) and, for a cell whose config has a [render.time] table, its
# compute-efficiency companion (KIND=time; mAA vs cumulative LO time).
#
# THIN CALLER of the one budget path, VisualGeometryToolkitEval.Render `budget_curves` (the
# statistics over the cell's per-scene files, the ONE scene schema) →
# emit_budget_faceted_curves / emit_budget_time_panel. This script only reads
# the cell's wiring: its scene files, its roster gate, its [render] settings.
#
# DETERMINISTIC per-call times (2026-07-23): the time panel's x axis is the
# SINGLE-THREAD per-call measurement of time_lo_supp.jl ([render.time] timing,
# under EXP_TIMING_DIR) — the in-situ sweep counters are contention-noisy (up
# to ~40 percent for sub-ms arms) and stay in the scene files (`lo_timing`)
# for audit only.
#
#   --kind      budget | time                             [required]
#   --sbdir     the cell's keyed budget dir (<scene>.jld2) [required]
#   --out       the output .tex                          [required]
#   --config    the cell config ([render], [experiment])  [required]
#   --legend    the panel's legend name                  [required]
#   --rows      med,maa | maa | med (--kind=budget)         [med,maa]
#   --xticks    the budget-axis ticks ([render] xticks)  [required for --kind=budget]
#   --deploy=1  wrap in tikzpicture (--kind=budget)
#   --extra-arms  arms beyond MAIN_ARMS (the roster gate); --roster=all keeps every arm
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"   # the project this tool runs under (srcdir/projectdir)
using JLD2, TOML
include(srcdir("config.jl"))   # PAPER_STYLE, the arm vocabulary
include(srcdir("registry.jl"))   # EXP_TIMING_DIR

const KIND   = cli_option(ARGS, "kind")
KIND in ("budget", "time") || error("render_budget: KIND must be budget | time, got $(repr(KIND))")
const SBDIR  = cli_option(ARGS, "sbdir")
const OUT    = cli_option(ARGS, "out")
const CFG    = TOML.parsefile(cli_option(ARGS, "config"))
const LEGEND = cli_option(ARGS, "legend")
const RND    = CFG["render"]
const PROBLEM = Symbol(CFG["experiment"]["problem"])

# The cell's scenes: the test side of its operating points' cross-validation
# (fold_budget_cell! + budget_sidecar, exactly as the budget stage derives it).
const CELL = fold_budget_cell!(deepcopy(CFG))
const SCENES = test_scenes(sidecar_cross_validation(budget_sidecar(CELL)))
const FILES = [joinpath(SBDIR, "$s.jld2") for s in SCENES]
let absent = [f for f in FILES if !isfile(f)]
    isempty(absent) || error("render_budget: scene files absent — run the cell's budget stage: $absent")
end

# The roster gate: the arms of the scene files, kept to MAIN_ARMS + --extra-arms
# unless --roster=all; every scene must carry the same arms (one scene set).
const PRESENT = collect(String, JLD2.load(FILES[1], "arms"))
for f in FILES[2:end]
    Set(JLD2.load(f, "arms")) == Set(PRESENT) || error("render_budget: $f carries other arms than $(FILES[1])")
end
const ARMS = cli_option(ARGS, "roster", "main") == "all" ? PRESENT : main_arms(PRESENT; extra = cli_option(ARGS, "extra-arms", ""))

const C = budget_curves(FILES; arms = ARMS)
const LABEL = row_label(RND["row_label"], PROBLEM)

if KIND == "budget"
    emit_budget_faceted_curves(PAPER_STYLE, OUT; row_label = LABEL, budgets = C.budgets, med = C.med, maa = C.maa,
        xticks = parse.(Int, split(cli_option(ARGS, "xticks"), ",")), xlog = RND["xlog"],
        deploy = cli_option(ARGS, "deploy", "") == "1", legend_name = LEGEND,
        rows = Symbol.(strip.(split(cli_option(ARGS, "rows", "med,maa"), ","))),
        oracle_med = C.oracle_med, oracle_maa = C.oracle_maa, oracle_label = oracle_budget_label(PROBLEM),
        med_ylabel = ZETA_MED_YLABEL, xlabel = raw"sample budget")
else
    T = RND["time"]
    tr = JLD2.load(joinpath(EXP_TIMING_DIR, T["timing"]))["runs"]
    # arm -> deterministic per-call µs through the arm table's timing vocabulary
    percall = Dict(k => arm_lo_us_per_call(tr, k) for k in keys(TIMING_TAGS) if k in ARMS)
    emit_budget_time_panel(PAPER_STYLE, OUT; row_label = LABEL, budgets = C.budgets, maa = C.maa,
        percall_us = percall, legend_name = LEGEND,
        xmax = T["xmax"], xticks = T["xticks"], maamax = T["maamax"])
end
println("  scenes=", length(FILES), "  arms=", length(ARMS))
for a in sort(ARMS)
    o = C.outcomes[a]
    println("  ", rpad(a, 18), " mAA@B=", C.budgets[end], " ", round(C.maa[a][end]; digits = 3),
            "  med ", round(C.med[a][end]; digits = 2), "  (eligible/failed/skipped ",
            o.n_eligible, "/", o.n_failed, "/", o.n_skipped, ")")
end
@info "WROTE" OUT
