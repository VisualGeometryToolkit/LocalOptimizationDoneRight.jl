#!/usr/bin/env julia
# =============================================================================
# scripts/fig1_sel_miscal.jl — MAIN-PAPER FIG 1 (fig:sel-miscal,
# figures/panel_sel_miscal.tex + panel_sel_miscal_maa.tex): scoring-only
# miscalibration — every selector family (Stu-tU/IG, MSAC, GaU, Welsch,
# Geman–McClure, MAGSAC++, RANSAC) tuned on the perturbed val pool per ζ by
# the standing windowed machinery (WindowedGridMethod free argmin inside the
# standardized eq-28 window at the supplied scale — every tuning parameter the
# [tuning.lo_sensitivity_miscal] entry of configs/tuning.toml, never hand-pinned)
# and read out on the untouched test pool at the fixed tuned width.
# Selection-only (the producer has no LO refits; PROTOCOL.md §3/§4).
#
# RERUN RATIONALE (campaign reset): the previous bundle
# (miscal-sel-allpairs-magsac) predates the engine-level CV guards, so its
# tuning left no auditable boundary evidence — it is re-produced through the
# current guarded engine (same protocol shape as production launch block A).
#
# DATA INPUTS
#   pool : PT-E-SIFT-4K_pf3 (see REPRODUCE.md)
# STAGES
#   produce (GPU) → EXP_SEL_MISCAL_BUNDLE
#   render  (CPU) → figures/panel_sel_miscal{,_maa}.tex (via figures_registry
#                   :fig1/:fig1_maa, whose src is THIS bundle)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2
include(srcdir("cell_stages.jl"))   # config + common + registry; THE miscal protocol's ζ ladder

require_input(EXP_POOL_PT_E; what = "PT-E-SIFT-4K_pf3 scoring pool",
              provenance = "scripts/tools/generate_scoring_pools.jl --config=pt_e_pools (REPRODUCE.md)")

const PANEL  = joinpath(PAPER_FIGDIR, "panel_sel_miscal.tex")
# Fig 1 selector roster: the production block-A families + MAGSAC++/RANSAC
# (job-2427 extension) + SIMFIT++ (2026-09-08: MSAC at a loss width re-estimated
# per pair, its initial guess cross-validated on the loss-width axis); welsch_marg (WMG)
# stays out — cut from the paper.
const SELECTORS = "student_t_uniform,msac,mlesac,welsch_cost,geman,magsac,ransac,sim_fit_pp"

STAGES = Stage[]
push!(STAGES, Stage(:produce,
        "selection-only miscal sweep (all pairs, $(SELECTORS)) → $(EXP_SEL_MISCAL_BUNDLE)",
        () -> isfile(EXP_SEL_MISCAL_BUNDLE),
        () -> run_driver("run_lo_sensitivity.jl",
                         "--mode=miscal",
                         "--pool-dir=$(EXP_POOL_PT_E)",
                         "--selectors=$(SELECTORS)",
                         "--tuning=lo_sensitivity_miscal", zeta_ladder_args()...,
                         "--stamp=$(EXP_SEL_MISCAL_TAG)")))
push!(STAGES, Stage(:render,
        "median + mAA panels via figures_registry (:fig1, :fig1_maa) → $(PANEL)",
        () -> fresher(PANEL, EXP_SEL_MISCAL_BUNDLE),
        () -> begin
            require_input(EXP_SEL_MISCAL_BUNDLE; what = "sel-miscal bundle",
                          provenance = "stage produce of this experiment")
            run_driver("figures_registry.jl", "fig1", "fig1_maa";
                       env = Dict("PAPER_FIGS" => PAPER_FIGDIR))
        end))

run_stages("fig1_sel_miscal", STAGES)
