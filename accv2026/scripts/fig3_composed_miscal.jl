#!/usr/bin/env julia
# =============================================================================
# scripts/fig3_composed_miscal.jl — the PhotoTourism row of MAIN-PAPER FIG 3
# (fig:miscal, figures/panel_lo_miscal.tex): composed score+LO miscalibration
# (ζ sweep), objective-faceted {Welsch | TLS | GM} at mAA@10°, every arm at its
# tuned operating point, scale-multiple arms PARTITION-ANCHORED
# (the loss scale rides the seed partition; it never slides with the
# ζ-corrupted plug-in).
#
# TUNING: ONE sequential CV of the full composed :E roster (configs/pt_e_miscal.toml
# [sequential_cv]; notes/sequential_cv.md): each selector's width, then every
# refiner's at it, then the ζ evaluation. The sidecar must satisfy the
# interior-argmin gate before anything consumes it.
#
# DOWNSTREAM: the sidecar is THE deployed sidecar of the campaign —
# fig4_budget.jl, polish.jl, fig_anchoring.jl (WITH side),
# timing_table.jl and the end-to-end cells (e2e_ransac.jl, superansac_e2e.jl)
# consume it through the gate-enforced readers.
#
# DATA INPUTS
#   pool : PT-E-SIFT-4K_pf3 (see REPRODUCE.md)
# STAGES
#   cv     (GPU) → EXP_MISCAL_SIDECAR (+ interior-argmin audit)
#   oracle (CPU) → oracle_floors.jld2[PT_E]
#   render (CPU) → figures/panel_lo_miscal.tex (the PhotoTourism row of the
#                  Fig 3 grid, mAA@10°)
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, TOML
include(srcdir("cell_stages.jl"))   # config + common + registry; the shared tuning stages

require_input(EXP_POOL_PT_E; what = "PT-E-SIFT-4K_pf3 scoring pool",
              provenance = "scripts/tools/generate_scoring_pools.jl --config=pt_e_pools (REPRODUCE.md)")

const PANEL = joinpath(PAPER_FIGDIR, "panel_lo_miscal.tex")

# The PT-E pool-best oracle bound (floor + mAA ceiling) of record for these pools and test scenes.
_oracle_done() = oracle_floor_done("PT_E"; pool_dir = EXP_POOL_PT_E, problem = :E, scenes = split(TEST, ","))

STAGES = Stage[]
# The PT-E composed tuning: the SEQUENTIAL CV (2026-10-04, notes/sequential_cv.md)
# of configs/pt_e_miscal.toml's [sequential_cv] — each selector's width, then
# every refiner's at it, then the ζ ladder — with THE interior-argmin audit.
# Its keyed directory IS registry.jl's EXP_MISCAL_DIR (`miscal_sidecar_of`
# derives both from the same config).
const PT_E_PATH   = projectdir("configs", "pt_e_miscal.toml")
const PT_E_TUNING = fold_sequential_cv!(load_run_config(PT_E_PATH))
sequential_cv_dir(PT_E_TUNING) == EXP_MISCAL_DIR ||
    error("fig3: pt_e_miscal's sequential-CV directory disagrees with registry.jl EXP_MISCAL_DIR")
# The test scenes of its cross-validation (the oracle bound's and the evaluation's).
const TEST = join(test_scenes(tuning_spec(PT_E_TUNING, sequential_cv_scorer_entry(
    PT_E_TUNING["sequential_cv"], :ig)).scheme.cross_validation), ",")
push!(STAGES, sequential_cv_stage(:cv, PT_E_TUNING, PT_E_PATH))
# THE PT-E pool-best oracle bound (floor + mAA ceiling) drawn on the panel,
# computed by the one floors writer on the panel's own pools and test scenes.
push!(STAGES, Stage(:oracle,
        "PT-E pool-best oracle bound (floor + mAA ceiling) → oracle_floors.jld2[PT_E]",
        () -> _oracle_done(),
        () -> run_driver("compute_supp_oracle_floors.jl",
                         "--tag=PT_E", "--problem=E",
                         "--pool-dir=$(EXP_POOL_PT_E)",
                         "--scenes=$(TEST)")))
# The full Table 1 roster, so Fig 3 carries the same arms as Figs 2 and 4, at
# mAA@10°, with the PT-E pool-best bound of stage oracle.
push!(STAGES, Stage(:render,
        "objective-faceted composed-miscal panel, maa row → $(PANEL)",
        () -> fresher(PANEL, EXP_MISCAL_SIDECAR),
        () -> begin
            require_input(EXP_MISCAL_SIDECAR; what = "PT-E full-roster operating-points sidecar",
                          provenance = "stage cv of this experiment")
            audit_operating_points(ROSTER, EXP_MISCAL_SIDECAR)
            _oracle_done() ||
                error("oracle floor PT_E: missing or computed on other pools/scenes — run --stage=oracle first")
            run_driver("render_miscal_faceted.jl";
                       env = Dict("SIDECAR" => EXP_MISCAL_SIDECAR, "OUT" => PANEL,
                                  "DEPLOY" => "1", "ROWS" => "maa", "ORACLE_TAG" => "PT_E"))
        end))

run_stages("fig3_composed_miscal", STAGES)
