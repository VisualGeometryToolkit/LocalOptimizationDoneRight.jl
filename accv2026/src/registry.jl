# =============================================================================
# src/registry.jl — the path registry of the ACCV 2026 experiment files that
# predate the config-driven convention. Config-driven cells (the ETH3D-F and
# HEB-H cells, the budget, e2e and SupeRANSAC cells) take pool_dir and the
# keyed outdir from configs/<cell>.toml through run_key / data_root() and have
# no entry here.
#
# Roots come from VisualGeometryToolkitEval's results_root() / data_root() and the
# configs, never hardcoded twice.
# =============================================================================
if !@isdefined(ACCV2026_EXPERIMENTS_REGISTRY_LOADED)

include(joinpath(@__DIR__, "config.jl"))
include(joinpath(@__DIR__, "common.jl"))   # binds the project root results_root() resolves against
include(joinpath(@__DIR__, "protocol_folds.jl"))   # keyed run dirs (miscal_sidecar_of)

# --- roots -------------------------------------------------------------------
# The per-cell results tree: VisualGeometryToolkitEval's `results_root()` (VGTK_RESULTS_ROOT or the
# project's data/exp_pro link → <results>/accv2026, data/README.md). The inputs
# are under `data_root()` (VGTK_DATA_ROOT or data/exp_raw), read only.
const EXP_RESULTS_ROOT = results_root()

# The main-paper cell: PhotoTourism / SIFT / Essential.
const EXP_PT_CELL   = joinpath(EXP_RESULTS_ROOT, "phototourism", "sift", "E")
# THE PT-E pool: the one fig3's config of record names (configs/pt_e_miscal.toml
# [experiment] pool_dir) — part of that run's key, so never overridden here.
const EXP_POOL_PT_E = let p = load_run_config(projectdir("configs", "pt_e_miscal.toml"))["experiment"]["pool_dir"]
    isabspath(p) ? p : joinpath(data_root(), p)
end
# The paper repo's figures/ directory (deploy target of every render stage),
# one path, no override. DEFERRED: DrWatson's papersdir() is papers/, this
# tree's is paper/ — the move waits for the regeneration.
const PAPER_FIGDIR = projectdir("paper", "figures")

# Every tuning artifact named below is written by the tuning-artifact writer
# (VisualGeometryToolkitEval `save_tuning_artifact`) and read through `load_tuning_artifact`,
# which REFUSES an artifact of another format (tuning format v3, 2026-10-01:
# the codified cross-validation — registered scene split, unit samplings,
# stable name-keyed seeds): their stamps were bumped with the format so every
# one regenerates.

# --- fig1 (selection-only miscalibration) -------------------------------------
# The keyed directory of configs/pt_e_sel_miscal.toml folded with its tuning
# spec and the ζ ladder (src/protocol_folds.jl `sensitivity_cell_dir`).
const EXP_SEL_MISCAL_DIR    = sensitivity_cell_dir(fold_sensitivity_cell!(config_of_record("pt_e_sel_miscal")))
const EXP_SEL_MISCAL_BUNDLE = joinpath(EXP_SEL_MISCAL_DIR, "bundle.jld2")

# --- fig2 (basin: the loss-width tuning + δ-perturbed ladder test) ------------
# THE basin roster's operating points: the keyed sequential-CV cell of
# configs/pt_e_basin.toml (`miscal_sidecar_of` derives its sidecar). The
# ladder's keyed directory folds that cell's run key and the ladder protocol
# (configs/protocol.toml [basin_ladder]; src/protocol_folds.jl `ladder_cell`),
# so a re-tune can never be read against a ladder run at the previous widths.
const EXP_BASIN_SIDECAR = miscal_sidecar_of("pt_e_basin")
const EXP_BASIN_DIR     = dirname(EXP_BASIN_SIDECAR)
const EXP_LADDER_DIR    = ladder_cell_dir(ladder_cell("pt_e_basin"))
const EXP_LADDER_BUNDLE = joinpath(EXP_LADDER_DIR, "ladder.jld2")
# The ladder's success radius (configs/protocol.toml [basin_ladder]), for its renderer.
const EXP_LADDER_SUCC   = string(protocol_value("basin_ladder", "success_deg"))


# --- fig3 (composed miscalibration: ONE full-roster sequential CV) -------------
# THE deployed sidecar of the campaign: the full composed :E roster tuned in
# one run (the historical frozen 14-arm base + anchored re-tune + GM-Irls and
# TLS-LO+ merges it replaces cannot be read under the tuning-artifact format:
# one keyed run of the full roster replaces the historical merge).
# fig4_budget, polish, fig_anchoring (both sides: its operating points),
# timing_table and the end-to-end cells (e2e_ransac.jl, superansac_e2e.jl)
# consume it through the gate-enforced readers.
# Its directory is KEYED like every dataset cell's: the effective config of
# record configs/pt_e_miscal.toml folded with the protocols of record
# (`miscal_sidecar_of`, THE one rule) — a change of any tuning or
# cross-validation parameter, or of the pool, is a new run directory.
const EXP_MISCAL_SIDECAR = miscal_sidecar_of("pt_e_miscal")
const EXP_MISCAL_DIR     = dirname(EXP_MISCAL_SIDECAR)

# --- SUPPLEMENT model-class transfer cells (2026-07-25) ----------------------
# HEB-H has NO constants here (2026-10-03). It is config-driven like every
# other miscal cell: configs/heb_h_miscal.toml names its pool
# (HEB-H-SIFT-4K_pf3) and its cross-validation, and its run directory is
# `sequential_cv_dir(cfg)` — derived, never spelled.
#
# What was here and why it had to go:
#   EXP_POOL_HEB_H           pointed at a retired pool tree that is REFUSED on read.
#   EXP_H_MISCAL_DIR         a LITERAL directory (`miscal-product-tuning-hebh-v2`)
#   EXP_H_MISCAL_BCD_DIR     that hashed nothing, so a protocol change reused
#                            the same path with new numbers.
# The BCD control is no longer a sibling run with its own directory: StuTuBCD
# is on the composed :H roster and tunes in the one run.
# --- fig4 (sample budget at the deployed tuned optima) -----------------
# configs/pt_e_budget.toml, a budget cell like every other: its keyed directory
# is `budget_cell_dir` of the folded config (src/protocol_folds.jl), derived
# where the stage runs — no path is restated here. (It used to be a
# hand-bumped literal, `sample_budget_fair_v7`, which a re-tune would have
# silently reused.)

# --- fig_anchoring (with/without partition anchoring, paired) -----------------
# ONE tuning, two evaluations of its operating points: WITH = fig3's own ζ evaluation
# (partition-anchored); WITHOUT = the ablation evaluation under the scale
# interface of configs/miscal_protocol.toml [anchoring_ablation], inside fig3's
# keyed run directory (a new fig3 key is a new ablation) and named by that
# interface (a change of it is a new artifact).
const EXP_ANCHOR_SCALE_INTERFACE = String(TOML.parsefile(projectdir("configs",
    "miscal_protocol.toml"))["anchoring_ablation"]["scale_interface"])
const EXP_ANCHOR_WITH        = EXP_MISCAL_SIDECAR
const EXP_ANCHOR_WITHOUT_DIR = joinpath(EXP_MISCAL_DIR, "anchoring_ablation-" * EXP_ANCHOR_SCALE_INTERFACE)
const EXP_ANCHOR_WITHOUT     = joinpath(EXP_ANCHOR_WITHOUT_DIR, "zeta_evaluation.jld2")

# --- timing --------------------------------------------------------------------
# Table 1's per-call LO timings: a RESULT, in the keyed directory of
# configs/timing_table.toml folded with the operating points it times
# (`timing_cell_dir`, src/protocol_folds.jl) — never under the data root.
const EXP_TIMING_DIR = timing_cell_dir(fold_timing_cell!(config_of_record("timing_table")))

const ACCV2026_EXPERIMENTS_REGISTRY_LOADED = true
end # include guard
