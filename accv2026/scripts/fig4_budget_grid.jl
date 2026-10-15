#!/usr/bin/env julia
# =============================================================================
# fig4_budget_grid.jl — MAIN-PAPER FIG 4 (fig:sample-budget,
# figures/panel_sample_budget_grid.tex): the accuracy-versus-sample-budget
# study on THREE datasets in one 3-by-3 grid — columns = objectives (Welsch |
# uniform mixtures | Geman–McClure), rows = PhotoTourism essential matrices,
# ETH3D fundamental matrices, HEB homographies.
#
# PROVENANCE. The three rows are the codified products of
#   fig4_budget.jl             stage render → panel_sample_budget_faceted.tex
#   supp_ETH_F_budget.jl       stage render → panel_sample_budget_eth_F.tex
#   supp_H_budget.jl           stage render → panel_sample_budget_heb_H.tex
# each at its own cross-validated operating points; roster = the Table 1 gate
# (figure_style.jl MAIN_ARMS + the per-render EXTRA_ARMS). This experiment only
# stacks them: scripts/tools/make_facet_grid.py copies axis options, coordinates,
# colours and markers verbatim from the panels.
#
# STAGES
#   compose (CPU) → figures/panel_sample_budget_grid.tex (mAA@10°)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))   # facet_grid_stages: the one 3-by-3 grid builder
run_stages("fig4_budget_grid", facet_grid_stages("fig4_budget_grid"))   # configs/fig4_budget_grid.toml [render]
