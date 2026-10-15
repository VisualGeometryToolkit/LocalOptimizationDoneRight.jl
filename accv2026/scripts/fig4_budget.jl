#!/usr/bin/env julia
# provenance: inputs declared via require_input blocks in src/cell_stages.jl; see REPRODUCE.md.
# =============================================================================
# scripts/fig4_budget.jl — MAIN-PAPER FIG 4's PhotoTourism row
# (figures/panel_sample_budget_faceted.tex) and the time panel
# (figures/panel_sample_budget_faceted_time.tex):
# accuracy per hypothesis budget, objective-faceted {TLS | Welsch | GM}, every
# IG-seeded arm at its OWN tuned operating point from THE deployed PT-E sidecar
# (pt_e_miscal's sequential CV) — no self-tuning exists.
#
# A budget cell like every other: configs/pt_e_budget.toml through
# `budget_cell_stages` (src/cell_stages.jl) — the one budget engine, scene
# schema and renderer. Its stages: budget (CPU, the test side of the
# sidecar's cross-validation), render (mAA row), render_time.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))
run_stages("fig4_budget", budget_cell_stages("PT_E", "pt_e_budget"))
