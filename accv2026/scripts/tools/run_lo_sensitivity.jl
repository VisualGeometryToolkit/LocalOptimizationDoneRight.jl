#!/usr/bin/env julia
# =============================================================================
# run_lo_sensitivity.jl — driver for the streamed experiments: --mode=validation_budget
# (how many VALIDATION PAIRS the tuner needs — not the sample budget),
# --mode=miscal (scale-corruption ζ sweep), and
# --mode=delta (well-depth Δ sweep).
#
# Protocol: eval/protocol/PROTOCOL.md §3 (base bundles are SELECTION-ONLY),
# §4 (fixed tuned scale multiple miscal), §5 (validation_budget sweep).
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
# `[tuning.<name>]` spec read from --config
# (default: the protocol of record, configs/tuning.toml) — `lo_sensitivity`
# for --mode=validation_budget|delta, `lo_sensitivity_natural` for the unrestricted regime,
# `lo_sensitivity_miscal` for --mode=miscal. The ζ ladder is the
# miscalibration protocol of record (configs/miscal_protocol.toml).
#
# GPU job:
#   julia --project=. scripts/tools/run_lo_sensitivity.jl --pool-dir=<pool> --mode=validation_budget
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
# CLI
# =============================================================================
const ARGV     = ARGS
const POOL_DIR = cli_option(ARGV, "pool-dir")
const NBATCH   = parse(Int, cli_option(ARGV, "batch", "600"))            # pairs staged on-device per chunk (bounds GPU/host)
const MODE     = cli_option(ARGV, "mode", "validation_budget")                          # "validation_budget" (val-size sweep) | "miscal" (synthetic scale-corruption ζ) | "delta" (well-depth sweep)
const TUNING   = cli_option(ARGV, "tuning", MODE == "miscal" ? "lo_sensitivity_miscal" : "lo_sensitivity")
const CONFIG   = cli_option(ARGV, "config", "")
const SPEC     = tuning_spec(isempty(CONFIG) ? tuning_config(TUNING) : TOML.parsefile(CONFIG), TUNING)
const MP       = TOML.parsefile(projectdir("configs", "miscal_protocol.toml"))["protocol"]
const NZETA    = parse(Int, cli_option(ARGV, "n-zeta", string(MP["n_zeta"])))               # # of ζ points (miscal)
const ZETA_OCT = parse(Float64, cli_option(ARGV, "zeta-octaves", string(MP["zeta_octaves"])))   # ζ ∈ 2^[-ZETA_OCT, ZETA_OCT]
const ZETAS    = collect(2.0 .^ range(-ZETA_OCT, ZETA_OCT; length = NZETA))
const NMIS     = parse(Int, cli_option(ARGV, "n-miscal", "0"))           # val size for miscal sweep; 0 ⇒ full val pool
const DELTAS   = parse.(Float64, split(cli_option(ARGV, "deltas", "0.25,0.5,1,2,4,8"), ','))  # well depths (delta)
const LOSS_NAME = cli_option(ARGV, "loss", "welsch")                     # delta-mode inlier loss
# PROTOCOL INVARIANT (2026-07-09, PROTOCOL.md §3): base bundles are
# SELECTION-ONLY — refined arms exist solely through the sequential CV (run_sequential_cv.jl).
# Roster (validation_budget + miscal modes): the selector families (experiment_producer.jl SELECTOR_TAGS keys).
#   --selectors=student_t_uniform,msac,mlesac,welsch_cost,geman
const SELECTORS = Symbol[selector_key(s) for s in split(cli_option(ARGV, "selectors", "student_t_uniform,msac"), ','; keepempty=false)]
const PT       = EssentialProblem

# Canonical keyed output dir for the M-bundle (mirrors the production results
# tree: ROOT/<dataset>/<matcher>/<problem>/<Experiment>/<stamp>/). The offline
# renderer (plot_lo_sensitivity.jl) reads bundle.jld2 from here.
# <results root>/accv2026 of the retired RVG_RESULTS_ROOT convention, else this
# project's results_root() (data/README.md) — the same tree on the author's host.
const RESULTS_ROOT = haskey(ENV, "RVG_RESULTS_ROOT") ? joinpath(ENV["RVG_RESULTS_ROOT"], "accv2026") : results_root()
const DATASET  = cli_option(ARGV, "dataset", "phototourism")
const MATCHER  = cli_option(ARGV, "matcher", "sift")
const PROBLEM  = cli_option(ARGV, "problem", "E")
const EXPNAME  = MODE == "miscal" ? "Miscalibration" :
                 MODE == "delta"  ? "DeltaSweep" : "LOSensitivity"
# The run's effective arguments: everything that moves the bundle (--batch is
# the on-device chunk size and --save a switch, so neither keys it). --stamp
# defaults to their run key, so a rerun of the same arguments lands in the
# same directory.
const EFFECTIVE = Dict{String,Any}(
    "pool_dir" => POOL_DIR, "mode" => MODE, "tuning" => TUNING, "spec" => tuning_hash(SPEC),
    "zetas" => ZETAS, "n_miscal" => NMIS, "deltas" => DELTAS, "loss" => LOSS_NAME,
    "selectors" => String.(SELECTORS), "dataset" => DATASET, "matcher" => MATCHER, "problem" => PROBLEM)
const STAMP    = cli_option(ARGV, "stamp", lowercase(EXPNAME) * "-" * run_key(EFFECTIVE))
const SAVE     = parse(Bool, cli_option(ARGV, "save", "true"))   # write the M-bundle
const OUTDIR   = joinpath(RESULTS_ROOT, DATASET, MATCHER, PROBLEM, EXPNAME, STAMP)
const BUNDLE   = SAVE ? joinpath(OUTDIR, "bundle.jld2") : nothing

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
    BUNDLE === nothing || @info "bundle → $BUNDLE"
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
    BUNDLE === nothing || @info "bundle → $BUNDLE"
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
    BUNDLE === nothing || @info "bundle → $BUNDLE"
    out = lo_sensitivity_sweep(scenes, NVAL;
        problem_type = PT, spec = SPEC, batch = NBATCH, selectors = SELECTORS,
        save_bundle = BUNDLE, scene_ids = SCENE_IDS)
    M, s0, grids = out.M, out.s0, out.grids

    # Per-scale-multiple diagnostic: pool-median imc° on the standardized display
    # axis (the spec's scale_multiple grid; evaluation at s0), one column per
    # roster label. Grid choice follows the label's selector family
    # (outlier-half-width families: "IG "/"WMG"; everything else a loss width).
    # The n-sweep table (with BCa CIs) is printed by the auto-render below.
    cm(Mat) = [finite_median(@view Mat[:, t]) for t in 1:size(Mat, 2)]
    cmM = Dict(k => cm(v) for (k, v) in M)
    labels = sort(collect(keys(M)))
    _is_ig(l) = startswith(l, "IG ") || startswith(l, "WMG")
    println("\n=== pose imc° vs scale multiple (pool median; evaluation at s0) ===")
    @printf("%5s |%s\n", "mult", join((@sprintf(" %12s", l) for l in labels)))
    for m in grids[:scale_multiple]
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
if BUNDLE !== nothing && isfile(BUNDLE)
    @info "auto-render → panels next to $BUNDLE"
    include(srcdir("plot_lo_sensitivity.jl"))
    Base.invokelatest(render_bundle, BUNDLE, PanelSpec(; legend_name = "lolegend"))
end
