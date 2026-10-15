#!/usr/bin/env julia
# =============================================================================
# scripts/fig2_basin.jl — MAIN-PAPER FIG 2 (fig:basin-ladder,
# figures/panel_basin_matched.tex): the basin/travel matrix on real data,
# 13-arm E roster (Welsch/TLS/GM × {IRLS, HQ lift, GNC} + TruncLS-LM/LZ +
# the classical RansacLib rows TLS-LO / TLS-LO+ / TLS-LO+(ref) + the
# self-scaled Stu-t arm), each arm at its OWN tuned operating point on the
# LOSS WIDTH axis (the basin roster; the basin test provides no scale, so
# the tuned value is the arm's entire scale knowledge).
#
# TUNING: the sequential CV of configs/pt_e_basin.toml (roster = "basin";
# scripts/tools/run_sequential_cv.jl): the IG scorer's a*, then each basin
# arm's loss width at it, coarse→fine with expand-on-boundary, boundary hits
# recorded and REFUSED at read time (deployed_basin_settings). NO fixed scale
# multiple anywhere: a common multiple does not translate across losses.
#
# DATA INPUTS
#   pool  : <ACCV_DATA>/data/PT-E-SIFT-4K_pf3/<scene>.jld2 (public IMC-PT via
#           scripts/tools/generate_scoring_pools.jl — see REPRODUCE.md)
# STAGES
#   basin_cv    (GPU, longest tuning of the campaign)  → EXP_BASIN_SIDECAR
#   ladder_test (CPU ~200 threads, streams scenes) → EXP_LADDER_BUNDLE
#   render      (CPU)                              → figures/panel_basin_matched.tex
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2
include(srcdir("cell_stages.jl"))   # config + common + registry; the shared tuning stages

require_input(EXP_POOL_PT_E; what = "PT-E-SIFT-4K_pf3 scoring pool",
              provenance = "scripts/tools/generate_scoring_pools.jl --config=pt_e_pools (public IMC-PT; REPRODUCE.md)")

const PANEL = joinpath(PAPER_FIGDIR, "panel_basin_matched.tex")

STAGES = Stage[]
# THE basin tuning: configs/pt_e_basin.toml's sequential CV (roster = "basin";
# the full Table 1 set, GM-Irls and BCD included). THE interior-argmin audit
# (audit_basin) follows it: a clip that survives the coarse probe's extension
# budget refuses there (never hand-pinned, never silently consumed).
const PT_E_BASIN_PATH = projectdir("configs", "pt_e_basin.toml")
const PT_E_BASIN = fold_sequential_cv!(load_run_config(PT_E_BASIN_PATH))
sequential_cv_dir(PT_E_BASIN) == EXP_BASIN_DIR ||
    error("fig2: pt_e_basin's sequential-CV directory disagrees with registry.jl EXP_BASIN_DIR")
push!(STAGES, sequential_cv_stage(:basin_cv, PT_E_BASIN, PT_E_BASIN_PATH))
push!(STAGES, Stage(:ladder_test,
        "δ-perturbed ladder on the 11 test scenes at the CV'd widths → $(EXP_LADDER_BUNDLE)",
        () -> isfile(EXP_LADDER_BUNDLE),
        () -> begin
            require_input(EXP_BASIN_SIDECAR; what = "basin operating points (the Table 1 arms)",
                          provenance = "stage basin_cv of this experiment")
            audit_operating_points(ROSTER, EXP_BASIN_SIDECAR)
            run_driver("run_basin_ladder.jl",
                       "--solo-cv=$(EXP_BASIN_SIDECAR)",
                       "--pool-dir=$(EXP_POOL_PT_E)",
                       "--deltas=$(EXP_LADDER_DELTAS)",
                       "--seed=$(EXP_LADDER_SEED)", "--nboot=$(EXP_LADDER_NBOOT)",
                       "--succ-deg=$(EXP_LADDER_SUCC)",
                       "--stamp=$(EXP_LADDER_STAMP)",
                       "--dataset=phototourism", "--matcher=sift")
        end))
push!(STAGES, Stage(:render,
        "faceted basin matrix → $(PANEL)",
        () -> fresher(PANEL, EXP_LADDER_BUNDLE),
        () -> run_driver("render_basin_faceted.jl";
                         env = Dict("BUNDLE" => EXP_LADDER_BUNDLE,
                                    "OUT" => PANEL,
                                    "SUCC" => EXP_LADDER_SUCC,
                                    "DEPLOY" => "1",
                                    # ONE row, mAA@10°. The success and conditional-
                                    # error rows were dropped 2026-09-07: mAA =
                                    # P(e≤T)·(1 − E[e|e≤T]/T) already rewards reach
                                    # and precision; P(e≤10°) alone is inflated for
                                    # δ ≤ 8° (the seed sits inside T), and E[e|success]
                                    # is a selection effect masked where basins collapse.
                                    # Arm roster: the renderer keeps MAIN_ARMS
                                    # (figure_style.jl) — one classical row,
                                    # TLS-LO+ at the budget; the continuation-only
                                    # iterLO row and the 61-update REFERENCE
                                    # preset render in the supplement (all arms
                                    # stay in the bundle; ROSTER=all). Plus the
                                    # same-objective control Stu-tU-BCD, as in the
                                    # miscalibration and budget figures.
                                    "EXTRA_ARMS" => "IG  +BCD",
                                    "ROWS" => "maa"))))

run_stages("fig2_basin", STAGES)
