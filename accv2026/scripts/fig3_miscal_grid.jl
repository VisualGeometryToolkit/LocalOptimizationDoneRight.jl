#!/usr/bin/env julia
# =============================================================================
# fig3_miscal_grid.jl — MAIN-PAPER FIG 3 (fig:miscal, figures/panel_miscal_grid.tex):
# the scale-miscalibration study on THREE datasets in one 3-by-3 grid — columns =
# objectives (uniform mixtures | Welsch | Geman–McClure), rows = PhotoTourism
# essential matrices, ETH3D fundamental matrices, HEB homographies.
#
# PROVENANCE. The three rows are the codified products of
#   fig3_composed_miscal.jl    stage render         → panel_lo_miscal.tex
#   supp_ETH_F_miscal.jl       stage render_main    → panel_lo_miscal_eth_F_main.tex
#   supp_H_miscal.jl           stage render_main    → panel_lo_miscal_heb_H_main.tex
# each at its own cross-validated operating points and drawn with the Table 1
# roster gate (figure_style.jl MAIN_ARMS + the per-render EXTRA_ARMS). The rows
# share the x axis (ζ over 1/128..128: ζ multiplies the residual unit), each
# with its pool-best oracle floor. This experiment only stacks
# the panels: scripts/tools/make_facet_grid.py copies axis options, coordinates,
# colours and markers verbatim.
#
# THE FIGURE CONFIG: configs/fig3_miscal_grid.toml [render] — the rows, the
# shared x axis, the legend and each row's y axes (2026-10-04: moved out of
# this file, every figure's axes live in a [render] section).
#
# STAGES
#   compose (CPU) → figures/panel_miscal_grid.tex (mAA@10°)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))   # facet_grid_stages: the one 3-by-3 grid builder
run_stages("fig3_miscal_grid", facet_grid_stages("fig3_miscal_grid"))
