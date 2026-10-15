#!/usr/bin/env julia
# provenance: inputs declared via require_input; see REPRODUCE.md.
# =============================================================================
# scripts/supp_ETH_F_budget.jl — the ETH3D-F (SP+LG) sample-budget cell
# (configs/accv2026_eth_f_budget.toml): the main-paper Fig 4 grid's third row.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))
run_stages("supp_ETH_F_budget", budget_cell_stages("ETH_F", "accv2026_eth_f_budget"))
