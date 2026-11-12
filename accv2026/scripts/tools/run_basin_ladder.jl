#!/usr/bin/env julia
# =============================================================================
# run_basin_ladder.jl — Exhibit 1: the basin/travel ladder on REAL data.
#
# For each PhotoTourism pair, perturb the DATASET ground-truth pose by an
# angle δ (rotation about a seeded random axis + translation jitter of the
# same magnitude) and run each refiner from that seed on the pair's real
# correspondences.  δ is the controlled "selection quality" axis — the
# selector is abstracted away entirely; the residual/outlier structure is
# genuine.  Two-panel evaluation per (δ, method):
#   travel      — success rate  P(imc ≤ succ-deg°)   (basin radius, direct)
#   destination — mean imc conditional on success    (accuracy where reached)
# with pair-bootstrap BCa 95% bands.  Saves a JLD2 bundle of the raw
# (pair × δ × method) error tensor for offline re-analysis.
#
#   julia --project=. scripts/tools/run_basin_ladder.jl --config=configs/pt_e_basin.toml
#
# Every ladder parameter is configs/protocol.toml [basin_ladder]; the config
# names the basin cell whose operating points it deploys.
#
# The pairs are the TEST side of the sidecar's own cross-validation (its
# persisted spec: the scenes its operating points were NOT tuned on). Draw
# (scene s, pair i, δ) perturbs from `StableRNG(stable_seed(seed, s, i, δ))`
# and the bootstrap bands resample from `StableRNG(stable_seed(seed, "bootstrap"))` —
# keyed by name, so a scene's draws do not depend on the others.
#
# Conventions: pool-frame Sampson residuals via the record's EssentialProblem(pair);
# per-pair oracle scale ŝ² = gt_variance (this is the MECHANISM exhibit — the
# oracle choice is stated in the caption; the production 2×2 uses plug-in);
# outlier half-width = ŝ·√(π/2)·e^{m²/2} at the operating efficiency constant m
# (paper eq-28 map, at Eval's OPERATING_EFFICIENCY_CONSTANT).
#
# =============================================================================

using DrWatson; @quickactivate "ACCV2026"
using Random, Statistics, Printf, JLD2, Logging, LinearAlgebra
using StableRNGs: StableRNG
using VisualGeometryToolkitEstimation
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: Synthetic, to_native
using VisualGeometryToolkitEval.Tuning: corrupt_native

# The paper config on top of the LO engine (PairCtx geometry, RefitFamily refit
# layer, the PoseLib adaptive-loss-width custom engine).
include(srcdir("config.jl"))
include(srcdir("protocol_folds.jl"))   # ladder_cell, ladder_cell_dir, miscal_sidecar_of
start_output_flush!()


# =============================================================================
# The config of record (--config=<configs/name.toml>): the BASIN cell whose
# operating points the ladder deploys (Fig 2: configs/pt_e_basin.toml, roster
# "basin") — its sidecar, `miscal_sidecar_of(name)`, is the roster and the tuned
# widths, repackaged by deployed_basin_settings into SoloSpec views delivered
# through the same delivery dispatch as the tuning itself (`solo_refit_imc!`:
# the s2_override port for the loss-width arms — tuning and test bitwise-identical
# delivery; nat′ for the outlier half-width ones). Every ladder parameter is the
# protocol of record, configs/protocol.toml [basin_ladder]. The bundle's keyed
# directory is `ladder_cell_dir(ladder_cell(name))` (src/protocol_folds.jl),
# which folds that cell's run key: a re-tune re-keys the ladder.
#
# CROSS-VALIDATED DEPLOYMENT ONLY: every arm runs at its tuned operating point
# applied to the per-pair oracle scale. There is NO fixed-multiple mode: a
# common efficiency constant does not translate across losses.
# =============================================================================
const CFG_PATH = cli_option(ARGS, "config")
const CELL     = first(splitext(basename(CFG_PATH)))
const LADDER   = ladder_cell(CELL)
# the basin cell named on the command line, read by Eval's loader, must be the config of record the ladder keys
load_run_config(CFG_PATH)["experiment"] == LADDER["experiment"] ||
    error("run_basin_ladder: --config=$(CFG_PATH) is not configs/$(CELL).toml, the config of record of cell $(CELL)")
const KEY      = run_key(LADDER)
const BL       = LADDER["basin_ladder"]
const POOL_DIR = joinpath(data_root(), LADDER["experiment"]["pool_dir"])
const DELTAS   = round.(deg2rad.(Float64.(BL["deltas_deg"])); digits = 6)   # the δ ladder, in radians
const OPERATING_MULTIPLE = Float64(OPERATING_EFFICIENCY_CONSTANT)          # eq-28 operating efficiency constant (outlier half-width ≈ 25ŝ)
const SUCCDEG  = Float64(BL["success_deg"])                                # the success radius (degrees)
const SEED     = Int(BL["seed"])                                           # the perturbation and bootstrap seed
const NBOOT    = Int(BL["n_bootstrap"])                                    # bootstrap resamples
# ζ = 1: the standard ladder (the supplied scale uncorrupted; GT evaluation untouched).
const ZETA     = 1.0
const SOLOPATH = miscal_sidecar_of(CELL)
const OUTDIR   = ladder_cell_dir(LADDER)
# THE data: the test side of the sidecar's cross-validation.
const TEST_SIDE = Dict(two_view_scene_loaders(sidecar_cross_validation(SOLOPATH), POOL_DIR).test)
const SCENES = sort(collect(keys(TEST_SIDE)))

# The solo roster: base => (spec, width) — a basin (mode "basin") sidecar ONLY,
# repackaged by deployed_basin_settings (which refuses a non-basin sidecar,
# another format and any boundary-clipped arm).
const LADDER_ROSTER = collect(deployed_basin_settings(ROSTER, SOLOPATH))
const METHODS = vcat(["seed"], first.(LADDER_ROSTER))
# The refinability probe's refiner: the paper's +LO arm itself (the arm table's
# "IG  +LO", at the protocol's LO budget).
const _PROBE_LO = arm_strategy(ARM_TABLE["IG  +LO"], 1.0)
_arm_lo(entry) = entry isa Tuple ? entry[1] : entry
_arm_native(entry, halfwidth::Float64) = entry isa Tuple ? entry[2] :
    consumed_native(entry, OutlierHalfwidth(), halfwidth;
                    operating_efficiency_constant = OPERATING_MULTIPLE, d_g = codimension(EssentialProblem))
# ONE refit call per roster entry — solo entries route through the shared
# delivery dispatch (solo_refit_imc!); composed entries keep the deployed
# path below verbatim.
_ladder_refit(entry::NamedTuple{(:spec, :width)}, ctx, seed_E, halfwidth::Float64) =
    solo_refit_imc!(ctx, entry.spec, seed_E, entry.width, halfwidth; on_fail = NaN)
_ladder_refit(entry, ctx, seed_E, halfwidth::Float64) =
    refit_imc!(ctx, _arm_lo(entry), seed_E, _arm_native(entry, halfwidth);
               scoring = ctx.solo_scoring, on_fail = NaN)
# The ladder's refit scoring: the Jeffreys marginal (rebuilt at each refit's own
# outlier half-width), for the deployed and the solo refits alike.
const _LADDER_TEMPLATE = VisualGeometryToolkitEstimation.scoring_from_toml(   # the priors: the stack configuration's
    Dict{String, Any}("type" => "student_t_uniform", "outlier_halfwidth" => 1.0); problem = EssentialProblem)

# Refinability mask: a pair enters the panels only if refining FROM THE GT POSE
# ITSELF (δ=0, +LO) stays within the success radius — otherwise the pair's data
# genuinely disagrees with the COLMAP pseudo-GT (bad GT / extreme contamination)
# and every method is penalized by the metric, not the optimization.  Standard
# basin-experiment practice; the mask fraction is reported.

# Pose perturbation: `perturbed_pose` lives in VisualGeometryToolkitCore.Synthetic
# and `perturbed_seed_E` in the eval evaluator (VisualGeometryToolkitEval.Evaluation,
# engine/geometry.jl) so every consumer perturbs IDENTICALLY — same seeded axis draw,
# same translation jitter, same [t]ₓR seed model.

function run_ladder()
    # STREAMING: one scene in memory at a time (a full PT scene is ~150 GB;
    # loading the roster at once OOMs the node).  The error tensor is scalar.
    load_scene(s) = first(TEST_SIDE[s]()).pairs   # the one pool reader (VisualGeometryToolkitEval.Pools), the test side's pairs
    counts = Int[]
    for sc in SCENES
        pp = load_scene(sc); push!(counts, length(pp)); pp = nothing; GC.gc()
    end
    offs = cumsum(vcat(0, counts))
    P = offs[end]; D = length(DELTAS)
    @info "basin ladder (streamed)" nscenes=length(SCENES) P D methods=METHODS succ_deg=SUCCDEG

    errs = fill(NaN, P, D, length(METHODS))     # (pair, δ, method) imc°
    # Per-refit optimizer wall-clock [ns] (refit_imc!'s guarded_refit bracket;
    # 0 = no refit call — seed column, thin-partition bails). Enables the
    # compute-parity (matched-milliseconds) rendering convention: calls =
    # count(lo_ns .> 0) per arm, total/mean ns per cell come free.
    lons = zeros(Int64, P, D, length(METHODS))
    refinable = falses(P)
    for (si, sc) in enumerate(SCENES)
    @info "scene $sc ($(si)/$(length(SCENES)))"
    pairs = load_scene(sc)
    Threads.@threads :static for pl in 1:length(pairs)
        p = offs[si] + pl
        pair = pairs[pl]
        # Pairs without a finite oracle σ̂² (too few GT-verified inliers —
        # e.g. ~2% of ScanNet1500) have no oracle scale for the standardized
        # width and no refinability probe: leave them non-refinable (the mask
        # drops them; every arm sees the identical pair set).
        isfinite(pair.gt_variance) || continue
        ctx  = build_pair_ctx(EssentialProblem, pair; scoring = _LADDER_TEMPLATE)   # ONE pool-frame geometry per pair
        R_gt, t_gt = ctx.geom.R_gt, ctx.geom.t_gt
        # Deployment corruption of the ORACLE supplied scale (the outlier
        # half-width is formed from it below) — the calibration-derived
        # quantity; the partition-anchored arms' own ŝ² is never corrupted.
        ŝ = corrupt_native(sqrt(max(Float64(pair.gt_variance), eps())), ZETA)
        outlier_halfwidth = to_native(OutlierHalfwidth(), OPERATING_MULTIPLE, ŝ; d_g = codimension(EssentialProblem))   # eq-28 native outlier half-width
        # δ=0 refinability probe: +LO from the GT pose itself must stay in-radius.
        refinable[p] = begin
            E0 = EssentialMat(R_gt, normalize(t_gt))
            first(refit_imc!(ctx, _PROBE_LO, E0, outlier_halfwidth;
                             scoring = ctx.solo_scoring, on_fail = NaN)) <= SUCCDEG
        end
        for (d, δ) in enumerate(DELTAS)
            rng = StableRNG(stable_seed(SEED, sc, pl, δ))
            seed_E = perturbed_seed_E(rng, R_gt, t_gt, δ)   # shared protocol helper
            errs[p, d, 1] = try
                Synthetic.imc_pose_error(seed_E, R_gt, t_gt)
            catch; NaN; end
            # ONE refit call per arm (_ladder_refit) — the RefitFamily trait
            # routes IRLS-family, PoseLib truncated, and the custom engine
            # identically; solo entries route through solo_refit_imc! (the s2
            # port there is the SANCTIONED s2_override delivery of the solo
            # protocol, not a scoring-partition leak). The ladder convention
            # is on_fail = NaN (a failed refit did NOT travel; the old
            # seed-imc fallback of the truncated path wrongly counted failures
            # as success). Deployed mode: consumed_native converts the outlier
            # half-width to a loss width at the operating efficiency constant for the
            # truncated arms, and every loss-scale consumer (incl. the
            # production Gnc port) reads the seed partition inside its own
            # refit — the retired eval engines' oracle-ŝ² side channel is gone.
            for (m, (name, entry)) in enumerate(LADDER_ROSTER)
                e_m, ns_m = _ladder_refit(entry, ctx, seed_E, outlier_halfwidth)
                errs[p, d, 1 + m] = e_m
                lons[p, d, 1 + m] = ns_m
            end
        end
    end
    pairs = nothing; GC.gc()
    end   # scene loop

    mkpath(OUTDIR)
    bundle = joinpath(OUTDIR, "ladder.jld2")
    JLD2.jldsave(bundle; errs, lo_ns=lons, refinable, deltas=collect(DELTAS), methods=METHODS,
                 scenes=collect(String.(SCENES)), operating_efficiency_constant=OPERATING_MULTIPLE,
                 succ_deg=SUCCDEG, seed=SEED, zeta=ZETA,
                 config="solo-cv", solo_sidecar=SOLOPATH,
                 scale_convention="basin-tuned optima (ABSOLUTE natives; s2_override-delivered loss widths)")
    write_run_records(OUTDIR, LADDER; driver = "run_basin_ladder.jl", config_source = CFG_PATH, key = KEY,
                      inputs = [SOLOPATH, POOL_DIR])
    @info "bundle → $bundle"
    keep = findall(refinable)
    @info @sprintf("refinability mask: %d/%d pairs kept (%.0f%%)",
                   length(keep), P, 100 * length(keep) / max(P, 1))
    errs = errs[keep, :, :]

    # ---- B2 evaluation: success rate + conditional error, pair-bootstrap BCa bands
    # (VisualGeometryToolkitEval `bootstrap_ci`, the interval of every other CI in the paper). A
    # refinable pair whose refit failed (non-finite) did not travel: it counts
    # as a non-success, never drops out of the rate.
    rng = StableRNG(stable_seed(SEED, "bootstrap"))
    band(f, v) = isempty(v) ? (NaN, NaN, NaN) : (f(v), bootstrap_ci(f, rng, v; n_resamples = NBOOT)...)
    println("\n=== travel: success rate P(imc ≤ $(SUCCDEG)°) ===")
    print(rpad("δ", 7)); foreach(m -> print(rpad(m, 22)), METHODS); println()
    for (d, δ) in enumerate(DELTAS)
        print(rpad(δ, 7))
        for m in 1:length(METHODS)
            succ = Float64[isfinite(x) && x <= SUCCDEG for x in errs[:, d, m]]
            s, lo95, hi95 = band(mean, succ)
            print(rpad(@sprintf("%.2f [%.2f,%.2f]", s, lo95, hi95), 22))
        end
        println()
    end
    println("\n=== destination: mean imc° | success ===")
    print(rpad("δ", 7)); foreach(m -> print(rpad(m, 22)), METHODS); println()
    for (d, δ) in enumerate(DELTAS)
        print(rpad(δ, 7))
        for m in 1:length(METHODS)
            v = filter(x -> isfinite(x) && x <= SUCCDEG, errs[:, d, m])
            s, lo95, hi95 = band(mean, v)
            print(rpad(@sprintf("%.2f [%.2f,%.2f]", s, lo95, hi95), 22))
        end
        println()
    end
    return bundle
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_ladder()
end
