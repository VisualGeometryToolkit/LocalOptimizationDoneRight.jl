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
#   julia --project=. scripts/tools/run_basin_ladder.jl --solo-cv=<sidecar> \
#       --pool-dir=<pool> --seed=<s> --nboot=<b> \
#       --deltas=<rad,...> --succ-deg=<deg> --stamp=<tag>
#
# fig2_basin.jl supplies every protocol argument from configs/protocol.toml
# [basin_ladder] (registry.jl); the driver has no default for any of them.
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
# outlier half-width = ŝ·√(π/2)·e^{m²/2} at the operating scale multiple m
# (paper eq-28 map, --operating-scale-multiple).
#
# paper-project: allow C1 a worker: scripts/fig2_basin.jl hands it every argument from its configs of record (configs/pt_e_basin.toml, configs/protocol.toml [basin_ladder]) through registry.jl
# paper-project: allow P1 a worker of scripts/fig2_basin.jl: the bundle (ladder.jld2) records its operating-points sidecar, seed and protocol, and lives in the basin cell's keyed directory, whose run records the cell writes
# paper-project: allow P2 fig2_basin.jl gives --stamp = basin-ladder-<the basin cell's keyed directory> (registry.jl EXP_LADDER_STAMP), so the bundle is keyed by that cell's run key; the wall-clock default is a deferred D3 entry
# =============================================================================

using DrWatson; @quickactivate "ACCV2026"
using Random, Statistics, Printf, JLD2, Logging, Dates, LinearAlgebra
using StableRNGs: StableRNG
using RobustVisualGeometry
using VisualGeometryCore
using VisualGeometryCore: Synthetic, to_native
using VisualGeometryEval.Tuning: corrupt_native

# The paper config on top of the LO engine (PairCtx geometry, RefitFamily refit
# layer, the PoseLib adaptive-loss-width custom engine).
include(srcdir("config.jl"))
start_output_flush!()


const ARGV     = ARGS
const POOL_DIR = cli_option(ARGV, "pool-dir")
const DELTAS   = parse.(Float64, split(cli_option(ARGV, "deltas"), ','))      # the ladder protocol's δ (rad; registry.jl EXP_LADDER_DELTAS)
const OPERATING_MULTIPLE = parse(Float64, cli_option(ARGV, "operating-scale-multiple",
                                              string(OPERATING_SCALE_MULTIPLE)))   # eq-28 operating scale multiple (outlier half-width ≈ 25ŝ)
const SUCCDEG  = parse(Float64, cli_option(ARGV, "succ-deg"))      # the ladder protocol's success radius (registry.jl EXP_LADDER_SUCC)
const SEED     = parse(Int, cli_option(ARGV, "seed"))              # the ladder protocol's (registry.jl EXP_LADDER_SEED)
# Mechanism experiment: corrupt the supplied scale by ζ (ŝ → ζ·ŝ) BEFORE the
# half-width map and every refiner's σ derivation; GT evaluation is untouched.
# Frozen-σ arms inherit the corruption for all iterations; σ̂ arms start from
# it but re-estimate.  ζ=1 is the standard ladder.
const ZETA    = parse(Float64, cli_option(ARGV, "zeta", "1.0"))
const ARMSF    = cli_option(ARGV, "arms", "")                       # comma list of roster names ("" = all)
const NBOOT    = parse(Int, cli_option(ARGV, "nboot"))             # bootstrap resamples (registry.jl EXP_LADDER_NBOOT)
const STAMP    = cli_option(ARGV, "stamp", Dates.format(Dates.now(), "yyyy-mm-ddTHHMMSS"))
# <results root>/accv2026 of the retired RVG_RESULTS_ROOT convention, else this
# project's results_root() (data/README.md) — the same tree on the author's host.
const RESULTS_ROOT = haskey(ENV, "RVG_RESULTS_ROOT") ? joinpath(ENV["RVG_RESULTS_ROOT"], "accv2026") : results_root()
const DATASET  = cli_option(ARGV, "dataset", "phototourism")
const MATCHER  = cli_option(ARGV, "matcher", "sift")
const OUTDIR   = joinpath(RESULTS_ROOT, DATASET, MATCHER, "E",
                          "BasinLadder", STAMP)

# (The fixed-constant LO_ROSTER table that used to live here was DEAD CODE: the
#  roster comes from the sidecars below since 2026-07-18, and its
#  scale-multiple-less constructors stopped loading when the scale multiple
#  became mandatory (RVG 0.15). Removed
#  2026-09-07.)
# =============================================================================
# Ladder CONFIGURATION — CROSS-VALIDATED DEPLOYMENT ONLY.
# Every arm runs at its tuned operating point (tuned on the val set with
# NO perturbation, from the operating-points sidecar) applied to the per-pair
# oracle scale. There is NO fixed-multiple mode: a common scale multiple does
# not translate across losses — a Welsch loss, a TLS truncation, and a
# Geman--McClure width at the same multiple are different operating points, so
# a shared multiple secretly un-matches the methods.
# =============================================================================
const TKPATH   = cli_option(ARGV, "operating-points", "")
# --solo-cv=<basin operating_points.jld2>: the loss-width configuration (THE
# Fig 2 config) — roster and tuned widths from the basin cell's sequential-CV
# sidecar (configs/pt_e_basin.toml, mode "basin"), repackaged by deployed_basin_settings into SoloSpec
# views delivered through the same delivery dispatch as the tuning itself
# (`solo_refit_imc!`: the s2_override port for the loss-width arms — tuning
# and test bitwise-identical delivery; nat′ for the outlier half-width ones). --operating-points remains the composed deployed mode for
# other uses. Exactly one of the two must be given.
const SOLOPATH = cli_option(ARGV, "solo-cv", "")
(isempty(TKPATH) == isempty(SOLOPATH)) &&
    error("run_basin_ladder: exactly ONE of --operating-points=<sidecar> (composed deployed " *
          "config) or --solo-cv=<basin operating_points.jld2> is required; " *
          "the fixed-multiple 'standardized' comparison was removed.")
# THE data: the test side of the sidecar's cross-validation.
const TEST_SIDE = Dict(two_view_scene_loaders(sidecar_cross_validation(isempty(SOLOPATH) ? TKPATH : SOLOPATH), POOL_DIR).test)
const SCENES = sort(collect(keys(TEST_SIDE)))

# Roster = the evaluator's `deployed_arm_settings` over THE arm table
# (ROSTER, arm_rosters.jl) at each arm's val tuned operating point; no label
# heuristics here. Optional --arms filter.
_deployed_roster(tkpath::AbstractString) = deployed_arm_settings(ROSTER, tkpath)
# Solo roster: base => (spec, width) — a basin (mode "basin") sidecar ONLY,
# repackaged by deployed_basin_settings (which refuses a
# non-basin sidecar, another format and any boundary-clipped arm).
_solo_roster(path::AbstractString) = collect(deployed_basin_settings(ROSTER, path))
const LADDER_ROSTER = let r = isempty(SOLOPATH) ? _deployed_roster(TKPATH) : _solo_roster(SOLOPATH)
    isempty(ARMSF) ? r : [pr for pr in r if first(pr) in split(ARMSF, ",")]
end
const METHODS = vcat(["seed"], first.(LADDER_ROSTER))
# The refinability probe's refiner: the paper's +LO arm itself (the arm table's
# "IG  +LO", at the protocol's LO budget).
const _PROBE_LO = arm_strategy(ARM_TABLE["IG  +LO"], 1.0)
_arm_lo(entry) = entry isa Tuple ? entry[1] : entry
_arm_native(entry, halfwidth::Float64) = entry isa Tuple ? entry[2] :
    consumed_native(entry, OutlierHalfwidth(), halfwidth;
                    operating_scale_multiple = OPERATING_MULTIPLE, d_g = codimension(EssentialProblem))
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
const _LADDER_TEMPLATE = StudentTUniformScoring(EssentialProblem, 1.0)

# Refinability mask: a pair enters the panels only if refining FROM THE GT POSE
# ITSELF (δ=0, +LO) stays within the success radius — otherwise the pair's data
# genuinely disagrees with the COLMAP pseudo-GT (bad GT / extreme contamination)
# and every method is penalized by the metric, not the optimization.  Standard
# basin-experiment practice; the mask fraction is reported.

# Pose perturbation: `perturbed_pose` / `perturbed_seed_E` live in the eval
# evaluator (VisualGeometryEval.Evaluation, engine/geometry.jl) so every consumer
# perturbs IDENTICALLY — same seeded axis draw,
# same translation jitter, same [t]ₓR seed model.

function run_ladder()
    # STREAMING: one scene in memory at a time (a full PT scene is ~150 GB;
    # loading the roster at once OOMs the node).  The error tensor is scalar.
    load_scene(s) = first(TEST_SIDE[s]()).pairs   # the one pool reader (VisualGeometryEval.Pools), the test side's pairs
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
            # half-width to a loss width at the operating scale multiple for the
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
                 scenes=collect(String.(SCENES)), operating_scale_multiple=OPERATING_MULTIPLE,
                 succ_deg=SUCCDEG, seed=SEED, zeta=ZETA,
                 config=isempty(SOLOPATH) ? "deployed" : "solo-cv",
                 product_tuning_sidecar=TKPATH, solo_sidecar=SOLOPATH,
                 scale_convention=isempty(SOLOPATH) ?
                     "deployed CV optima (global natives; partition-read widths)" :
                     "basin-tuned optima (ABSOLUTE natives; s2_override-delivered loss widths)")
    @info "bundle → $bundle"
    keep = findall(refinable)
    @info @sprintf("refinability mask: %d/%d pairs kept (%.0f%%)",
                   length(keep), P, 100 * length(keep) / max(P, 1))
    errs = errs[keep, :, :]

    # ---- B2 evaluation: success rate + conditional error, pair-bootstrap BCa bands
    # (VisualGeometryEval `bootstrap_ci`, the interval of every other CI in the paper). A
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
