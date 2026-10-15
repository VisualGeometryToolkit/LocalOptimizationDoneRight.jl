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
const KEY = run_key(CFG)
const OUTDIR = superansac_cell_dir(CFG)
const CV = superansac_cross_validation(CFG)

if "--check" in ARGS
    st = superansac_status(CFG)
    println(st.available ? "SupeRANSAC available: $(st.detail) ($(superansac_env(CFG)))" :
                           "SupeRANSAC NOT available in $(superansac_env(CFG)):\n$(st.detail)")
    exit(st.available ? 0 : 1)
end

_inputs_done() = all(isfile(superansac_inputs_path(OUTDIR, s, side))
                     for (side, ss) in (("validation", validation_scenes(CV)), ("test", test_scenes(CV))) for s in ss)
_eval_done() = all(isfile(superansac_zeta_path(OUTDIR, s)) for s in test_scenes(CV)) &&
               isfile(joinpath(OUTDIR, "_provenance.toml"))
function _eval()
    superansac_evaluation!(CFG, OUTDIR)
    write_run_records(OUTDIR, CFG; driver = "superansac_e2e.jl", config_source = CFG_PATH, key = KEY,
                      inputs = [joinpath(data_root(), CFG["experiment"]["pool_dir"])])
end

STAGES = Stage[
    Stage(:inputs, "SupeRANSAC raw-pixel inputs: $(length(validation_scenes(CV))) validation and " *
                   "$(length(test_scenes(CV))) test scenes (config $(CFG_NAME), key $(KEY)) → $(joinpath(OUTDIR, "inputs"))",
          _inputs_done, () -> superansac_inputs!(CFG, OUTDIR)),
    Stage(:cv, "SupeRANSAC loss-width CV on the validation units → $(superansac_cv_path(OUTDIR))",
          () -> isfile(superansac_cv_path(OUTDIR)), () -> superansac_loss_width_cv!(CFG, OUTDIR)),
    Stage(:eval, "SupeRANSAC on every test pair × ζ $(CFG["superansac"]["zetas"]) → $(OUTDIR)",
          _eval_done, _eval),
]
run_stages("superansac_e2e[$(CFG_NAME)]", STAGES)
