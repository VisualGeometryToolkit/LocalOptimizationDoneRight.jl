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
# CONFIG OF RECORD
#   configs/pt_e_sel_miscal.toml (the pool PT-E-SIFT-4K_pf3, the selectors, the tuning entry)
# STAGES
#   produce (GPU) → EXP_SEL_MISCAL_BUNDLE
#   render  (CPU) → figures/panel_sel_miscal{,_maa}.tex (via figures_registry
#                   :fig1/:fig1_maa, whose src is THIS bundle)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2
include(srcdir("cell_stages.jl"))   # config + common + registry; THE miscal protocol's ζ ladder

const CFG_PATH = projectdir("configs", "pt_e_sel_miscal.toml")
const CFG = fold_sensitivity_cell!(load_run_config(CFG_PATH))
sensitivity_cell_dir(CFG) == EXP_SEL_MISCAL_DIR || error("fig1: the keyed directory disagrees with registry.jl EXP_SEL_MISCAL_DIR")
pool_input(CFG)   # the PT-E pool of record ([inputs.pool]), there before the run starts

const PANEL  = joinpath(PAPER_FIGDIR, "panel_sel_miscal.tex")

STAGES = Stage[]
push!(STAGES, Stage(:produce,
        "selection-only miscal sweep (all pairs, $(join(CFG["sensitivity"]["selectors"], ","))) → $(EXP_SEL_MISCAL_BUNDLE)",
        () -> run_complete(EXP_SEL_MISCAL_DIR; sidecar = basename(EXP_SEL_MISCAL_BUNDLE)),
        () -> run_driver("run_lo_sensitivity.jl", "--config=$(CFG_PATH)")))
push!(STAGES, Stage(:render,
        "median + mAA panels via figures_registry (:fig1, :fig1_maa) → $(PANEL)",
        () -> fresher(PANEL, EXP_SEL_MISCAL_BUNDLE),
        () -> begin
            require_input(EXP_SEL_MISCAL_BUNDLE; what = "sel-miscal bundle",
                          provenance = "stage produce of this experiment")
            run_driver("figures_registry.jl", "fig1", "fig1_maa")
        end))

run_stages("fig1_sel_miscal", STAGES)
