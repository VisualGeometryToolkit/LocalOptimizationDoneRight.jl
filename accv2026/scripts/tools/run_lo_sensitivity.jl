#!/usr/bin/env julia
# =============================================================================
# run_lo_sensitivity.jl — driver for the streamed experiments ([sensitivity] mode of its config): validation_budget
# (how many VALIDATION PAIRS the tuner needs — not the sample budget),
# miscal (scale-corruption ζ sweep), and
# delta (well-depth Δ sweep).
#
# Protocol: eval/protocol/PROTOCOL.md §3 (base bundles are SELECTION-ONLY),
# §4 (fixed tuned efficiency constant miscal), §5 (validation_budget sweep).
#
# File-specific: THIN CALLER of the shared producers (`lo_sensitivity_sweep` /
# `miscalibration_sweep` / `delta_sweep` in eval/experiment_producer.jl) — the
# SAME code path the production cell driver uses, so the smoke and production
# cannot drift.  This script only does CLI + scene load + printing; all the
# staging / selection sweep / WindowedGridMethod / bootstrap logic lives in
# the shared producer.
#
# Every tuning parameter (the native grids, the standardized display axis, the
# budget sampling) and THE data (the cross-validation: its
# registered validation/test scenes and per-scene pair samplings) is the
# `[tuning.<name>]` spec the config's [sensitivity] tuning names
# (the protocol of record, configs/tuning.toml) — `lo_sensitivity`
# for mode = validation_budget|delta, `lo_sensitivity_natural` for the unrestricted regime,
# `lo_sensitivity_miscal` for mode = miscal. The ζ ladder is the
# miscalibration protocol of record (configs/miscal_protocol.toml).
#
# GPU job:
#   julia --project=. scripts/tools/run_lo_sensitivity.jl --config=configs/pt_e_sel_miscal.toml [--batch=600]
# =============================================================================

using DrWatson; @quickactivate "ACCV2026"
using CUDA, Random, Statistics, Printf, JLD2, Logging
using VisualGeometryToolkitEstimation
using VisualGeometryToolkitEstimation: EssentialProblem
using TOML

# The paper config (the CLI and flusher come with VisualGeometryToolkitEval) and THE
# shared streamed-experiment producer (also used by the production cell driver).
include(srcdir("config.jl"))
include(srcdir("experiment_producer.jl"))
include(srcdir("protocol_folds.jl"))

# sbatch-safe output: VisualGeometryToolkitEval's periodic stdout/stderr flusher.
start_output_flush!()

# =============================================================================
# The config of record (--config=<configs/name.toml>, a `[sensitivity]` cell:
# Fig 1's configs/pt_e_sel_miscal.toml), folded with its tuning spec and the ζ
# ladder (src/protocol_folds.jl `fold_sensitivity_cell!`): everything that moves
# the bundle keys its directory, `sensitivity_cell_dir`. --batch (the on-device
# chunk size) is a resource knob and keys nothing.
# =============================================================================
const ARGV     = ARGS
const CFG_PATH = cli_option(ARGV, "config")
const CFG      = fold_sensitivity_cell!(load_run_config(CFG_PATH))
const KEY      = run_key(CFG)
const S        = CFG["sensitivity"]
const NBATCH   = parse(Int, cli_option(ARGV, "batch", "600"))            # pairs staged on-device per chunk (bounds GPU/host)
const POOL_DIR = joinpath(data_root(), CFG["experiment"]["pool_dir"])
const MODE     = String(S["mode"])                                       # "validation_budget" | "miscal" | "delta"
const TUNING   = String(S["tuning"])
const SPEC     = tuning_spec(tuning_config(TUNING), TUNING)
const ZETAS    = MODE == "miscal" ?
    collect(2.0 .^ range(-Float64(CFG["miscal_protocol"]["zeta_octaves"]), Float64(CFG["miscal_protocol"]["zeta_octaves"]);
                          length = Int(CFG["miscal_protocol"]["n_zeta"]))) : Float64[]
const NMIS     = Int(get(S, "n_miscal", 0))                             # val size for the miscal sweep; 0 ⇒ the full val pool
const DELTAS   = Float64.(get(S, "deltas", Float64[]))                   # well depths (delta mode)
const LOSS_NAME = String(get(S, "loss", "welsch"))                       # delta-mode inlier loss
# PROTOCOL INVARIANT (2026-07-09, PROTOCOL.md §3): base bundles are
# SELECTION-ONLY — refined arms exist solely through the sequential CV (run_sequential_cv.jl).
# Roster: the selector families (arm_rosters.jl SELECTOR_FAMILIES tags).
const SELECTORS = Symbol[selector_key(s) for s in S["selectors"]]
const PT       = EssentialProblem
const OUTDIR   = sensitivity_cell_dir(CFG)
const BUNDLE   = joinpath(OUTDIR, "bundle.jld2")

# =============================================================================
# Stream scenes (scene-ordered: val first, then test) — the spec's
# cross-validation (src/validation_data.jl `two_view_scene_loaders`: each
# side's pairs as its sampling keeps them; a pooled sampling is refused by its
# signature). Supply LOADERS, not loaded pairs — the producer streams one scene
# at a time so peak memory is one scene.
# =============================================================================
const SIDES = two_view_scene_loaders(SPEC.scheme.cross_validation, POOL_DIR)
const SCENE_IDS = vcat(first.(SIDES.validation), first.(SIDES.test))
const NVAL = length(SIDES.validation)
scenes = vcat(last.(SIDES.validation), last.(SIDES.test))   # zero-arg loaders
@info "pool (streamed)" nscenes=length(scenes) nval=NVAL ntest=length(SIDES.test) tuning=TUNING spec_hash=tuning_hash(SPEC)

# =============================================================================
# Run — the validation_budget val-size sweep, the miscalibration f sweep, or the Δ-depth sweep.
# =============================================================================
if MODE == "miscal"
    # Synthetic miscalibration: scale the VAL supplied scale ŝ by ζ (×ζ² on σ̂²),
    # evaluate on unscaled test, sweep f. Isolates the eq-29 bias response.
    @info "bundle → $BUNDLE"
    mc = miscalibration_sweep(scenes, NVAL, ZETAS;
        n = NMIS == 0 ? nothing : NMIS, selectors = SELECTORS,
        problem_type = PT, spec = SPEC, batch = NBATCH,
        save_bundle = BUNDLE, scene_ids = SCENE_IDS)
    # The per-ζ table (with BCa CIs) is printed by the auto-render below.
    @info "miscalibration sweep complete" n=mc.n nzeta=length(mc.zetas)
    flush(stdout)
elseif MODE == "delta"
    # Well-depth sweep: one Track-B mixture-marginal selector per Δ on the
    # shared outlier-half-width axis, IG/MSAC as anchors. Selection error vs contrast — the
    # paper's Δ dose-response curve.
    loss = LOSS_NAME == "welsch"    ? WelschShape() :        # the VGC loss shapes (config.jl)
           LOSS_NAME == "geman"     ? GemanMcclureShape() :
           LOSS_NAME == "smoothtls" ? SmoothTLSShape() :
           error("unknown --loss=$LOSS_NAME")
    @info "bundle → $BUNDLE"
    ds = delta_sweep(scenes, NVAL, loss, DELTAS;
        problem_type = PT, spec = SPEC, batch = NBATCH,
        save_bundle = BUNDLE, scene_ids = SCENE_IDS)
    # Δ dose-response evaluation: pool-median imc° at each label's best-a column.
    println("\n=== pose imc° vs well depth Δ (pool median at the per-label best outlier half-width) ===")
    for l in sort(collect(keys(ds.M)))
        col = map(t -> finite_median(@view ds.M[l][:, t]), 1:size(ds.M[l], 2))
        @printf("%-14s  best med = %6.3f°\n", l, minimum(col))
    end
    flush(stdout)
else
    @info "bundle → $BUNDLE"
    out = lo_sensitivity_sweep(scenes, NVAL;
        problem_type = PT, spec = SPEC, batch = NBATCH, selectors = SELECTORS,
        save_bundle = BUNDLE, scene_ids = SCENE_IDS)
    M, s0, grids = out.M, out.s0, out.grids

    # Per-efficiency-constant diagnostic: pool-median imc° on the standardized display
    # axis (the spec's efficiency_constant grid; evaluation at s0), one column per
    # roster label. Grid choice follows the label's selector family
    # (outlier-half-width families: "IG "/"WMG"; everything else a loss width).
    # The n-sweep table (with BCa CIs) is printed by the auto-render below.
    cm(Mat) = [finite_median(@view Mat[:, t]) for t in 1:size(Mat, 2)]
    cmM = Dict(k => cm(v) for (k, v) in M)
    labels = sort(collect(keys(M)))
    _is_ig(l) = startswith(l, "IG ") || startswith(l, "WMG")
    println("\n=== pose imc° vs efficiency constant (pool median; evaluation at s0) ===")
    @printf("%5s |%s\n", "mult", join((@sprintf(" %12s", l) for l in labels)))
    for m in grids[:efficiency_constant]
        ci = nearest_column(grids[:outlier_halfwidth], out.to_native_outlier_halfwidth(m, s0))
        cm_ = nearest_column(grids[:loss_width], out.to_native_loss_width(m, s0))
        @printf("%5.2f |%s\n", m,
            join((@sprintf(" %12.3f", cmM[l][_is_ig(l) ? ci : cm_]) for l in labels)))
    end
    flush(stdout)
end

# Auto-render: serialize + plot in one invocation (the run_pipeline.jl pattern).
# The renderer is pure-CPU (re-bootstraps the saved M via the package's
# `compute_method_rows` → BCa CIs) and writes `summary.jld2` + PGFPlots panels
# next to the bundle. Pure post-processing — safe to run at the tail of the job.
write_run_records(OUTDIR, CFG; driver = "run_lo_sensitivity.jl", config_source = CFG_PATH, key = KEY,
                  inputs = [POOL_DIR])
@info "auto-render → panels next to $BUNDLE"
include(srcdir("plot_lo_sensitivity.jl"))
Base.invokelatest(render_bundle, BUNDLE, PanelSpec(; legend_name = "lolegend"))
