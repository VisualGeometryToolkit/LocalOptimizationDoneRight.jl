#!/usr/bin/env julia
# provenance: inputs declared via require_input blocks (scoring_pool_stages); see REPRODUCE.md.
# =============================================================================
# scripts/scoring_pools.jl — THE two-view scoring-pool producer of every
# dataset whose pools come from a pool config: `--config=<name>` names
# configs/<name>.toml ([experiment] dataset/problem/pool_dir, [source] the raw
# trees, the splits and the generator route, [pool] the version, concurrency
# and every generation constant), run through `scoring_pool_stages` (src/cell_stages.jl). Nothing
# else is stated here: a new dataset or variant is a new config, not a driver.
#
#   sbatch ... scripts/slurm/run_experiment.sbatch scoring_pools.jl --config=eth_f_pools
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))
const CFG_NAME = cli_option(ARGS, "config", "")
isempty(CFG_NAME) && error("scoring_pools.jl: --config=<name> is required (configs/<name>.toml)")
const SRC = load_run_config(projectdir("configs", CFG_NAME * ".toml"))["source"]
run_stages(CFG_NAME, scoring_pool_stages(CFG_NAME; what = SRC["what"], provenance = SRC["provenance"]))
