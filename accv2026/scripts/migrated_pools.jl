#!/usr/bin/env julia
# provenance: the migrated tree's run records (write_run_records, src/cell_stages.jl pool_migration_stages); see REPRODUCE.md.
# =============================================================================
# scripts/migrated_pools.jl — a pool tree of record carried to the current pool
# format (VisualGeometryToolkitEval pool format 6): `--config=<name>` names
# configs/<name>.toml ([inputs.pool] the source tree, [experiment] pool_dir the
# NEW tree), run through `pool_migration_stages` (src/cell_stages.jl), which
# links the source's files into the new tree and migrates each light pool with
# VisualGeometryToolkitEval's `migrate_pools` (Pools.migrate_pool: verified bit
# for bit; the residuals and every pool_key unchanged). The source is never
# written.
#
#   julia --project=. scripts/migrated_pools.jl --config=pt_e_pools_v6
#
# reproduce: reads configs/pt_e_pools_v6.toml
# reproduce: reads configs/heb_h_pools_v6.toml
# reproduce: reads configs/eth_f_pools_v6.toml
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))
import VisualGeometryToolkitEval
include(joinpath(pkgdir(VisualGeometryToolkitEval), "scripts", "migrate_pools.jl"))   # Eval's migrate_pools (its CLI runs only as a program)
const CFG_NAME = cli_option(ARGS, "config", "")
isempty(CFG_NAME) && error("migrated_pools.jl: --config=<name> is required (configs/<name>.toml)")
run_stages(CFG_NAME, pool_migration_stages(CFG_NAME; migrate = migrate_pools, pool_format = _pool_format))
