#!/usr/bin/env julia
# provenance: inputs declared via require_input blocks below; see REPRODUCE.md.
# =============================================================================
# scripts/supp_H_budget.jl — HEB-H accuracy vs sample budget, the HEB row of
# the main-paper Fig 4 grid (fig4_budget_grid.jl), at the inverse-gamma
# operating points of heb_h_miscal: the streamed budget engine (the LO engine's evaluate_sample_budget, Stack A) on the
# 5 HEB test scenes, EVERY arm of the merged 13-arm sidecar at its OWN
# tuned (selection, refinement) operating point — deployed_budget_settings(problem = :H),
# no self-CV (PROTOCOL.md §6 shape, as fig4_budget on PT-E).
#
# CONFIG-DRIVEN: configs/heb_h_budget.toml; keyed output dir; run records.
# The stage list is the dataset cells' one (src/cell_stages.jl,
# budget_cell_stages): budget (CPU, julia -t N) per-scene curves -> <scene>.jld2;
# render (CPU) the faceted mAA panel (the Fig 4 grid's HEB row).
#
# SMOKE: RVG_SMOKE=1 → 1 scene, 30 pairs, 3 arms, into data/sims/budget-<key>-smoke (DrWatson datadir("sims")).
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))

run_stages("supp_H_budget", budget_cell_stages("H", "heb_h_budget"))
