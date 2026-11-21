#!/usr/bin/env julia
# provenance: inputs declared via require_input (src/superansac.jl); see REPRODUCE.md.
# =============================================================================
# scripts/superansac_e2e.jl — the SupeRANSAC cell of MAIN-PAPER TAB. 3
# (figures/table_e2e.tex; configs/pt_e_superansac.toml, src/superansac.jl):
# SupeRANSAC's loss width cross-validated on the validation units of our
# operating points' cross-validation, then run on every test pair of it under
# the table's ζ ladder. scripts/e2e_ransac.jl (--config=pt_e_e2e_table) sets
# these rows beside ours.
#
# SupeRANSAC is an OUTSIDE dependency: the cv and eval stages run it in worker
# processes in its own environment ([environment] project, envs/superansac) and
# stop, with the installation steps, when it is not importable there. The table
# does not need this cell to run: without its results it reads the stored ones
# ([stored] dir).
#
# STAGES
#   inputs (CPU)          — raw-pixel slices of the validation and test units
#                           → <dir>/inputs/
#   cv     (CPU, workers) — the loss-width CV ([tuning.superansac_loss_width])
#                           → <dir>/loss_width_cv.jld2
#   eval   (CPU, workers) — every test pair × ζ → <dir>/zeta_<scene>.jld2
#   <dir> = <results>/phototourism/sift/E/SupeRANSAC/superansac-<key>. The
#   workers are single-threaded processes, one per julia thread of this one
#   (`julia -t N`, the Slurm wrapper's allocation).
#
#   julia -t auto --project=. scripts/superansac_e2e.jl [--config=pt_e_superansac] [--plan] [--stage=NAME]
#   julia --project=. scripts/superansac_e2e.jl --check   (is SupeRANSAC available? no stage runs)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))
include(srcdir("superansac.jl"))

const CFG_NAME = cli_option(ARGS, "config", "pt_e_superansac")
const CFG_PATH = projectdir("configs", CFG_NAME * ".toml")
const CFG = superansac_cell(CFG_NAME)
const PRODUCT = superansac_product(CFG)
const KEY = PRODUCT.key
const OUTDIR = product_dir(PRODUCT)
const CV = superansac_cross_validation(CFG)

if "--check" in ARGS
    st = superansac_status(CFG)
    println(st.available ? "SupeRANSAC available: $(st.detail) ($(superansac_env(CFG)))" :
                           "SupeRANSAC NOT available in $(superansac_env(CFG)):\n$(st.detail)")
    exit(st.available ? 0 : 1)
end

_inputs_done() = all(isfile(superansac_inputs_path(OUTDIR, s, side))
                     for (side, ss) in (("validation", validation_scenes(CV)), ("test", test_scenes(CV))) for s in ss)
# The cell's product: its raw-pixel inputs, its loss-width CV and the ζ evaluation, each step
# resumed from what an interrupted run left in the product's directory; the last test scene's
# ζ-sweep file is written last.
function _cell(dir)
    _inputs_done() || superansac_inputs!(CFG, dir)
    isfile(superansac_cv_path(dir)) || superansac_loss_width_cv!(CFG, dir)
    superansac_evaluation!(CFG, dir)
    return nothing
end

STAGES = Stage[
    Stage(:eval, "SupeRANSAC raw-pixel inputs ($(length(validation_scenes(CV))) validation and $(length(test_scenes(CV))) test " *
                 "scenes), loss-width CV and every test pair × ζ $(CFG["superansac"]["zetas"]) (config $(CFG_NAME), key $(KEY)) → $(OUTDIR)";
          items = () -> [PRODUCT], product = identity,
          run = p -> produce(_cell, p; driver = "superansac_e2e.jl", config_source = CFG_PATH, inputs = [pool_input(CFG)])),
]
run_stages("superansac_e2e[$(CFG_NAME)]", STAGES)
