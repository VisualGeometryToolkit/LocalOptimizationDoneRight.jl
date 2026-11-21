#!/usr/bin/env julia
# provenance: inputs declared via require_input; see REPRODUCE.md.
# reproduce: reads configs/pt_e_e2e_table.toml   (the main paper's cell, Tab. 3)
# =============================================================================
# scripts/e2e_ransac.jl — an END-TO-END RANSAC cell (--config=<name>, a
# configs/*.toml with `[e2e] test = "operating_points"`; the main paper's is
# pt_e_e2e_table, Tab. 3): the deployed arms of its operating points run
# through the production RANSAC loop on EVERY test pair of those operating
# points' own cross-validation — no validation side, the scorer and refiners
# being already cross-validated (src/e2e_cells.jl) — set beside SupeRANSAC's
# results on the same pairs (`[e2e] superansac`, the SupeRANSAC cell:
# configs/pt_e_superansac.toml, scripts/superansac_e2e.jl). SupeRANSAC is not
# run here: the summary reads that cell's own results when it has run, its
# STORED results ([stored] dir, the published rows) otherwise, and says which.
#
# STAGES
#   live     (CPU, threads) — arms × ζ on the test pairs → EndToEnd/e2e/<key>/live.jld2
#   summary  (CPU) — arm × ζ, scene-averaged (median°, mAA@10°, mAA@5°,
#                    trials, wall ms), + SupeRANSAC → EndToEnd/e2e-summary/<key>/summary.tsv
#                    (keyed by the live runs and SupeRANSAC's result files)
#   table    (CPU) — with [render] panel: the ours-vs-SupeRANSAC table
#            (pt_e_e2e_table) reproduce: writes paper/figures/table_e2e.tex
#            Its time row is the TIMING cell's when [render] time names one
#            (scripts/e2e_timing.jl: pinned single-threaded repeats on drawn
#            pairs), this cell's multithreaded wall clocks otherwise.
#
#   julia -t auto --project=. scripts/e2e_ransac.jl --config=pt_e_e2e_table
#   --smoke[=<dir>]: the first test scene, its first 20 test pairs, ζ = 1 only,
#                  written under <dir> (default DrWatson datadir("sims", "e2e-<key>-smoke"),
#                  never the keyed results tree; its run records name the smoke subset
#                  in their config's [smoke] table)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, Statistics, Printf, Dates, TOML
using VisualGeometryToolkitEstimation: RansacConfig
include(srcdir("cell_stages.jl"))
include(srcdir("e2e_cells.jl"))
include(srcdir("superansac.jl"))
include(srcdir("e2e_timing.jl"))     # [render] time: the time row's cell

const CFG_NAME = cli_option(ARGS, "config")
const CFG_PATH = projectdir("configs", CFG_NAME * ".toml")
const CFG = fold_e2e_cell!(load_run_config(CFG_PATH))
const PRODUCT = e2e_product(CFG)
const KEY     = PRODUCT.key
# a smoke run is a code check into DrWatson's datadir("sims"), never the cell's product
const SMOKE   = "--smoke" in ARGS ? datadir("sims", "e2e-$(KEY)-smoke") : cli_option(ARGS, "smoke", "")
const OUTDIR  = isempty(SMOKE) ? product_dir(PRODUCT) : SMOKE
const POOL    = pool_input(CFG)
const SIDECAR = miscal_sidecar_of(String(CFG["operating_points"]["miscal_config"]))
const ARMS    = String.(CFG["e2e"]["arms"])
const ZETAS   = isempty(SMOKE) ? Float64.(CFG["e2e"]["zetas"]) : [1.0]
const SEED    = Int(CFG["e2e"]["seed"])
const STREAM  = String(CFG["e2e"]["stream"])
# The test side of the operating points' own cross-validation: its scenes and,
# per scene, the units its sampling keeps (every pair under ExhaustiveSampling).
const CV      = sidecar_cross_validation(SIDECAR)
const SCENES  = isempty(SMOKE) ? test_scenes(CV) : test_scenes(CV)[1:1]
_units(s, n) = only(values(sample_units(CV.test, Dict(s => collect(1:n)))))
units_of(s, n) = isempty(SMOKE) ? _units(s, n) : first(_units(s, n), 20)
const LIVE    = joinpath(OUTDIR, "live.jld2")
# the summary: its own product (src/superansac.jl e2e_summary_product), built when its stage runs
_summary_path() = isempty(SMOKE) ? product_output(e2e_summary_product(CFG)) : joinpath(SMOKE, "summary.tsv")
# Our loop's termination: `[e2e] ransac` {min_trials, max_trials, success_prob}
# (absent: the production defaults).
const RCFG = e2e_ransac_config(CFG)
# The SupeRANSAC side (`[e2e] superansac`, a SupeRANSAC cell's config name):
# its results on these test pairs, from that cell's run or its stored results.
const SR = let n = get(CFG["e2e"], "superansac", nothing)
    n === nothing ? nothing : superansac_cell(String(n))
end
if SR !== nothing
    issubset(ZETAS, Float64.(SR["superansac"]["zetas"])) ||
        error("$CFG_NAME: the SupeRANSAC cell's ζ ladder lacks some of $(ZETAS)")
    superansac_cross_validation(SR) == CV ||
        error("$CFG_NAME: the SupeRANSAC cell reads another cross-validation than these operating points'")
end

function _live()
    r = e2e_live(SIDECAR, ARMS, SCENES, units_of; zetas = ZETAS, seed = SEED, stream = STREAM, pool_dir = POOL, config = RCFG)
    mkpath(OUTDIR)
    jldsave(LIVE; r..., arms = ARMS, zetas = ZETAS, scenes = SCENES, sidecar = SIDECAR,
            cross_validation = tuning_table(CV),
            seed_scheme = "StableRNG(stable_seed($(SEED), \"$(STREAM)\", scene, pool_index))",
            created = string(Dates.now()))
end

function _summary(out = _summary_path())
    d = JLD2.load(LIVE)
    pp = d["per_pair"]
    comments = ["$(CFG_NAME) — end-to-end RANSAC, arm × ζ, scene-averaged over the $(length(SCENES)) test scenes " *
                "(mean of per-scene stats; every test pair: $(sum(length.(values(d["units"])))))",
                "operating points: $(SIDECAR)"]
    rows = [e2e_summary_row(a, ζ, [pp["$(a)|$(s)|$(ζ)"] for s in SCENES]; wall = r -> r.wall_s) for a in ARMS for ζ in ZETAS]
    if SR !== nothing && isempty(SMOKE)   # a smoke run's pairs are not SupeRANSAC's
        src = superansac_results(SR, SCENES)
        @info "SupeRANSAC rows from $(src.source)"
        push!(comments, "SupeRANSAC: $(src.source)")
        sr = Dict(s => superansac_scene_results(src.files[s], s, d["units"][s], ZETAS) for s in SCENES)
        for (z, ζ) in enumerate(ZETAS)
            push!(rows, e2e_summary_row("SupeRANSAC", ζ, [sr[s][z] for s in SCENES]; wall = r -> r.wall))
        end
    end
    write_tsv(out, E2E_SUMMARY_HEADER, rows; comments)
    print(read(out, String))
end

# Two products: the live runs, and their scene-averaged summary with SupeRANSAC's rows (from
# whichever of its sources holds every scene, named in the summary), keyed by the live runs and
# SupeRANSAC's result files. A smoke run is a check into datadir("sims").
STAGES = isempty(SMOKE) ? Stage[
    Stage(:live, "$(join(ARMS, " vs ")) × ζ $(ZETAS) on every test pair (config $(CFG_NAME), key $(KEY)) → $(LIVE)";
          items = () -> [PRODUCT], product = identity,
          run = p -> produce(_ -> (_live(); nothing), p; driver = "e2e_ransac.jl", config_source = CFG_PATH, inputs = [SIDECAR, POOL])),
    Stage(:summary, "arm × ζ scene-averaged summary" * (SR === nothing ? "" : " + SupeRANSAC") * " (config $(CFG_NAME))";
          items = () -> [e2e_summary_product(CFG)], product = identity,
          run = p -> produce(dir -> (_summary(joinpath(dir, "summary.tsv")); nothing), p; driver = "e2e_ransac.jl",
                             config_source = CFG_PATH, inputs = [LIVE])),
] : Stage[Stage(:live, "smoke run → $(SMOKE)"; check = () -> (_live(); _summary()))]
# THE main-paper table (`[render] panel`, deployed when `deploy`): ours vs
# SupeRANSAC × ζ, median error / mAA@10 / median wall time, the best system
# per column in bold (src/e2e_cells.jl `e2e_table_tex`). The FIRST arm is
# "ours"; any further arm (the research-only zero-clamp "IG  +Lift@zc") is a
# block of its own between ours and SupeRANSAC, in the bold comparison like
# every row.
if haskey(CFG, "render") && haskey(CFG["render"], "panel")
    SR === nothing && error("$CFG_NAME: [render] panel is the ours-vs-SupeRANSAC table; [e2e] superansac is required")
    const TABLE = Bool(get(CFG["render"], "deploy", false)) ? joinpath(PAPER_FIGDIR, CFG["render"]["panel"]) :
                                                              joinpath(OUTDIR, CFG["render"]["panel"])
    # The time row's source: the timing cell `[render] time` names (its timing.tsv), else this summary.
    const TIMING_CFG = let n = get(CFG["render"], "time", nothing)
        n === nothing ? nothing : (String(n), e2e_timing_cell(String(n)))
    end
    TIMING_CFG === nothing || upstream_products(TIMING_CFG[2])["e2e"].key == KEY ||
        error("$CFG_NAME: [render] time = $(TIMING_CFG[1]) times another e2e run than this one ($KEY)")
    function _table()
        # derived when the table is written: the timing cell's key folds the e2e product's produced output
        timing = TIMING_CFG === nothing ? nothing : e2e_timing_product(TIMING_CFG[2])
        summary = _summary_path()
        recs, trecs = read_tsv(summary), read_tsv(timing === nothing ? summary : product_output(timing))
        row(rs, arm, ζ, k) = parse(Float64, only(r for r in rs if r["arm"] == arm && parse(Float64, r["zeta"]) == ζ)[k])
        val(arm, ζ, k) = row(k == "med_wall_ms" ? trecs : recs, arm, ζ, k)
        # (arm, label lines): a label's k-th line heads the arm's k-th stat row,
        # so "(Ours)" sits under our arm's name.
        arms = [(first(ARMS), [raw"\stuU{}+" * label_tex(first(ARMS)), "(Ours)"]),
                [(a, [raw"\stuU{}+" * label_tex(a)]) for a in ARMS[2:end]]...,
                ("SupeRANSAC", [raw"SupeRANSAC~\cite{BarathSupeRANSAC2025}"])]
        src = timing === nothing ? "summary.tsv" : "summary.tsv, the time row from $(TIMING_CFG[1]) (key $(timing.key), timing.tsv)"
        write(TABLE, e2e_table_tex(val, arms, ZETAS; header =
            "% Auto-generated by scripts/e2e_ransac.jl stage table (config $(CFG_NAME), key $(KEY)) from $(src); do not hand-edit."))
        @info "e2e table written" TABLE
    end
    push!(STAGES, Stage(:table, "ours vs SupeRANSAC × ζ table → $(TABLE)"; check = _table))
end
run_stages("e2e_ransac[$(CFG_NAME)]", STAGES)
