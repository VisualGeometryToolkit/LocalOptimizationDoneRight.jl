#!/usr/bin/env julia
# provenance: inputs declared via require_input; see REPRODUCE.md.
# =============================================================================
# scripts/polish.jl — does a final polish move a locally optimized result?
# (configs/polish_pt_e.toml; the tool is scripts/tools/run_polish.jl.)
#
# STAGES
#   test     (CPU) — every polish of every source's LO output on the test side
#                    → polish_test.jld2 (nothing is tuned: L2 on the scorer's
#                    inliers has no parameter; an optional TLS polish runs at
#                    the deployed TLS-IRLS arm's own CV'd width)
#                    (E_LO checked pair for pair against the sidecar's ζ = 1 errors)
#   summary  (CPU) — per (source, polisher): mAA@10 / median before and after,
#                    improved / degraded rates, displacement quantiles → summary.tsv
#   render   (CPU) — the ECDF of the per-pair error CHANGE e_polished − e_LO
#                    (negative = the polish helped), one curve per source
#                    → paper/figures ([render] panel_diff)
#                    reproduce: writes paper/figures/panel_polish_diff.tex
#
#   julia --project=. scripts/polish.jl [--config=polish_pt_e]
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, Statistics, Printf, TOML
include(srcdir("cell_stages.jl"))

const CFG_NAME = cli_option(ARGS, "config", "polish_pt_e")
const CFG_PATH = projectdir("configs", CFG_NAME * ".toml")
const CFG = load_run_config(CFG_PATH)
# keyed by the config AND the run of the operating points it polishes
CFG["operating_points_run"] = operating_points_run(String(CFG["operating_points"]["miscal_config"]))
const KEY = run_key(CFG)
const OUTDIR = joinpath(experiment_dir(CFG), "Polish", "polish-" * KEY)
const TESTF, SUMF = joinpath(OUTDIR, "polish_test.jld2"), joinpath(OUTDIR, "summary.tsv")
const R = CFG["render"]
const PANEL_DIFF = joinpath(PAPER_FIGDIR, R["panel_diff"])

_tool() = run_driver("run_polish.jl", "--config=$(CFG_NAME)", "--outdir=$(OUTDIR)")

function _summary()
    d = JLD2.load(TESTF); err, disp = d["err"], d["disp"]
    lines = ["# $(CFG_NAME) — polish of a locally optimized result, PT-E test side ($(sum(d["np"])) pairs, $(length(d["scenes"])) scenes)",
             join(["source", "polisher", "maa10_before", "maa10_after", "med_before", "med_after",
                   "improved", "degraded", "disp_median_deg", "disp_p90_deg", "moved_gt_0.1deg"], '\t')]
    for a in d["sources"], p in d["polishers"]
        b, e, m = err["$(a)|none"], err["$(a)|$(p)"], disp["$(a)|$(p)"]
        ok = isfinite.(b) .& isfinite.(e)
        push!(lines, join([a, p,
            @sprintf("%.4f", eligible_maa(b)), @sprintf("%.4f", eligible_maa(e)),
            @sprintf("%.3f", finite_median(b)), @sprintf("%.3f", finite_median(e)),
            @sprintf("%.3f", mean(e[ok] .< b[ok] .- 1e-6)), @sprintf("%.3f", mean(e[ok] .> b[ok] .+ 1e-6)),
            @sprintf("%.4f", median(filter(isfinite, m))), @sprintf("%.4f", quantile(filter(isfinite, m), 0.9)),
            @sprintf("%.3f", mean(filter(isfinite, m) .> 0.1))], '\t'))
    end
    write(SUMF, join(lines, '\n') * "\n"); print(read(SUMF, String))
end

_render() = run_driver("render_polish_diff.jl";
    env = Dict("POLISH_TEST" => TESTF, "OUT" => PANEL_DIFF, "CONFIG" => CFG_NAME, "DIFF_XMAX" => string(R["diff_xmax"])))

STAGES = Stage[
    Stage(:test, "every polish of every source's LO output on the test side (config $(CFG_NAME), key $(KEY)) -> $(TESTF)",
          () -> isfile(TESTF) && isfile(joinpath(OUTDIR, "_provenance.toml")),
          () -> (_tool(); write_run_records(OUTDIR, CFG; driver = "run_polish.jl", config_source = CFG_PATH,
                                                  key = KEY, inputs = [miscal_sidecar_of(String(CFG["operating_points"]["miscal_config"]))]))),
    Stage(:summary, "before/after accuracy and displacement -> $(SUMF)", () -> isfile(SUMF) && fresher(SUMF, TESTF), _summary),
    Stage(:render, "ECDF of the per-pair error change -> $(PANEL_DIFF)",
          () -> isfile(PANEL_DIFF) && fresher(PANEL_DIFF, TESTF), _render),
]
run_stages("polish[$(CFG_NAME)]", STAGES)
