#!/usr/bin/env julia
# =============================================================================
# run_sequential_cv.jl — THE SEQUENTIAL CV driver (GPU): each selector's width
# once, then every refiner's width at its selector's fixed value, then the ζ
# evaluation at the tuned points. Design and the measurements behind it:
# notes/sequential_cv.md.
#
# EVERY parameter is the cell's folded config (`--config`, written by
# src/protocol_folds.jl `fold_sequential_cv!`): `[sequential_cv]` names the
# configs/tuning.toml `coarse_fine` entries, their `cross_validation` is the
# cell's cv_protocol section, the ζ ladder is miscal_protocol.toml. There is no
# grid, window or scene flag.
#
# SELECTORS. The roster's arms seed from one or more selector families — IG
# (outlier half-width) on every cell, MSAC (loss width) on the E/F rosters.
# Each family the roster uses is a cell of the scorer CV, all of them swept in
# the same sweep of the pool; an arm refines at ITS selector's a*.
#
# STAGES, each writing ONE artifact into --outdir and skipped when it exists
# (delete it to re-run); each later stage READS the earlier artifact rather
# than recomputing or receiving it in memory, so a stage can be rerun alone and
# its input is auditable on disk:
#
#   scorer   scorer_cv.jld2 — `coarse_fine_cv_batched` of each selector's width
#            on the SELECTION-ONLY error (`NoLocalOptimization`: the selected
#            model's pose error, no refit) over the validation pairs. One sweep
#            of the pool per round, every point of every selector in it.
#   refiner  refiner_cv.jld2 — reads a* per selector from scorer_cv.jld2
#            (refusing a boundary hit), then `coarse_fine_cv_batched` over the
#            arms: each arm a cell on its kind's entry, its selector fixed at
#            the one column a*, each round one sweep with every arm's requested
#            widths as refit specs.
#   evaluate operating_points.jld2 — reads both artifacts; the ζ ladder on the
#            test scenes at (a*_sel, w*_arm) through the production
#            `miscal_evaluation_refit`, and the operating-point keys the
#            deployed readers gate on (`arms`, `tuned_selection`,
#            `tuned_width`, `boundary_hits`): the sidecar of the cell's miscal
#            panels AND its budget cell.
#
# THE PLUG-IN SCALE (`[sequential_cv] plugin_scale`, optional): the tuning
# never reads a scale, but the anchoring ablation evaluates the scale-multiple
# arms at a FIXED external scale s0. `"oracle_gt_variance"` records s0 =
# reference_scale of the validation pairs' stored σ̂² — on PhotoTourism the
# ORACLE variance (SfM-track detections under the bundle-adjusted pose,
# VisualGeometryEval Datasets phototourism.jl) — in both artifacts. Absent, no s0 is written and a
# reader that needs one fails loudly.
#
# ROSTERS (`[sequential_cv] roster`): "composed" (default) — the composed
# score+LO roster, evaluated on the ζ ladder; "basin" — the Fig 2 loss-width
# roster (`basin_specs`), whose test side is the δ-perturbed basin ladder
# (run_basin_ladder.jl --solo-cv), so its last stage writes the operating
# points as a `mode = "basin"` sidecar with no ζ evaluation.
#
# ANCHORING (`--stage=anchoring`, never part of `all`): the anchoring
# ablation's WITHOUT side — the composed sidecar's scale-multiple arms
# re-evaluated on the same ζ ladder with their loss width delivered at the
# FIXED plug-in scale ζ·s0 (`miscal_evaluation_refit`'s `plugin_scale`)
# instead of the seed partition's ŝ. The scale interface is
# miscal_protocol.toml [anchoring_ablation] scale_interface, and the artifact
# (`mode = "evaluation"`, render_anchoring_paired.jl) is written to
# <outdir>/anchoring_ablation-<interface>/zeta_evaluation.jld2 — the path
# registry.jl EXP_ANCHOR_WITHOUT derives from the same two facts.
#
# The objective of every stage is the per-pair pose error `model_imc` scores
# (rotation only on H — the LO engine's geometry.jl), aggregated by the entry's
# criterion over the pooled validation pairs.
#
# PINNED WIDTHS: an arm whose width source is its selection's
# (LocalOptimizationDoneRight `SelectionWidth()` — the objective-matched
# variants a cell declares in `[sequential_cv] objective_matched`, e.g.
# ["IG  +BCD"] → "IG  +BCD@a*", arm_rosters.jl) has no refiner stage: its
# width IS its selector's a*, recorded as such in the sidecar (`tuned_width`
# = `tuned_selection`, `width_sources`), with the selection's boundary hits
# alone; the ζ evaluation refits it at ζ·a*.
#
# ZERO-CLAMP VARIANTS (research-only; `[sequential_cv] zero_clamp`, e.g.
# ["IG  +Lift"] → "IG  +Lift@zc", arm_rosters.jl / welsch_zero_clamp.jl): the
# Welsch-HQ arm on the 2026-10-04 z-block (hreg = 0 at the lift's clamp). A
# TUNED arm like any other — its own refiner cell at its selector's a*. To add
# it to an existing run: `--stage=refiner --arms="IG  +Lift@zc"`, then
# `--stage=evaluate` with the same `--arms`.
#
#   julia -t 64 --project=. scripts/tools/run_sequential_cv.jl \
#         --config=<outdir>/_config.toml --outdir=<keyed dir> [--stage=all|scorer|refiner|evaluate]
#   ... --stage=anchoring
#
# RE-RUNNING SOME ARMS (`--arms="IG  +Lift,MSAC +Lift"`, refiner / evaluate;
# a pinned arm, e.g. `--arms="IG  +BCD@a*"`, needs the evaluate stage alone):
# when a code change moves only some arms (2026-10-04: VisualGeometryCore's
# Welsch z-block clamp, the two Welsch-HQ arms), those arms are re-tuned at the
# EXISTING a* and re-evaluated IN PLACE; every other arm's entries, and the
# scorer artifact, are kept as they are. The artifacts must exist; each is
# copied to `<name>.pre_rerun` first, and the rewrite records `rerun_arms`.
# =============================================================================

using DrWatson; @quickactivate "ACCV2026"
using CUDA, Statistics, Printf, JLD2, Logging, TOML
using RobustVisualGeometry

include(srcdir("config.jl"))
include(srcdir("experiment_producer.jl"))
include(srcdir("protocol_folds.jl"))
using VisualGeometryEval.Evaluation: coarse_fine_cv_batched, enforce_probe_interior
using VisualGeometryEval.Tuning: corrupt_native
using VisualGeometryEval.Tuning: fit_prior, JeffreysPriorSpec, IGRobustSpec   # the scale prior ([sequential_cv] prior)
using VisualGeometryEval.Evaluation: stream_selections, width_delivery, miscal_evaluation_refit,
    problem_type, is_tuned, operating_width
using VisualGeometryCore: width_axis_name, width_axis
start_output_flush!()

const CFG    = TOML.parsefile(cli_option(ARGS, "config"))
const OUTDIR = cli_option(ARGS, "outdir")
const STAGE  = cli_option(ARGS, "stage", "all")
STAGE in ("all", "scorer", "refiner", "evaluate", "anchoring") ||
    error("--stage must be all | scorer | refiner | evaluate | anchoring")
const NBATCH = parse(Int, cli_option(ARGS, "batch", "600"))     # pairs staged per GPU chunk (compute only)
"The arms re-run in place (`--arms`, comma-separated deployed names); empty = all."
const RERUN = String.(strip.(filter!(!isempty, split(cli_option(ARGS, "arms", ""), ","))))
isempty(RERUN) || STAGE in ("refiner", "evaluate", "all") ||
    error("--arms re-runs the refiner / evaluate stages only")

const SQ      = CFG["sequential_cv"]
const PROBLEM = Symbol(CFG["experiment"]["problem"])
const PT      = problem_type(PROBLEM)
const DG      = codimension(PT)
const POOL    = joinpath(data_root(), CFG["experiment"]["pool_dir"])
const MP      = CFG["miscal_protocol"]["protocol"]
const ZETAS   = collect(2.0 .^ range(-Float64(MP["zeta_octaves"]), Float64(MP["zeta_octaves"]);
                                     length = Int(MP["n_zeta"])))
const ROSTER_KIND = get(SQ, "roster", "composed")
ROSTER_KIND in ("composed", "basin") || error("[sequential_cv] roster: expected \"composed\" or \"basin\", got $(repr(ROSTER_KIND))")
"The base arms whose objective-matched variant this cell declares (`[sequential_cv] objective_matched`)."
const MATCHED = declared_matched(SQ)
"The base arms whose zero-clamp variant this cell declares (`[sequential_cv] zero_clamp`)."
const ZERO_CLAMP = declared_zero_clamp(SQ)
const ARMS    = ROSTER_KIND == "basin" ? basin_specs(PROBLEM; matched = MATCHED, zero_clamp = ZERO_CLAMP) :
                                         composed_specs(PROBLEM; matched = MATCHED, zero_clamp = ZERO_CLAMP)
"The arms the refiner stage tunes (every arm but the pinned, selection-width ones)."
const TUNED   = filter(is_tuned, ARMS)
"An arm's width parameterization by its persisted name (`\"scale_multiple\"` | …)."
kind_name(arm) = String(width_axis_name(arm.kind))
"The selector families the roster seeds from, in a fixed order."
const SELS    = sort!(unique(arm.sel for arm in ARMS))
const SCORER  = Dict(s => tuning_spec(CFG, sequential_cv_scorer_entry(SQ, s)) for s in SELS)
const REFINER = Dict(k => tuning_spec(CFG, String(n)) for (k, n) in SQ["refiner"])
for a in ARMS
    haskey(REFINER, kind_name(a)) || error("arm $(a.base): no [sequential_cv] refiner entry for kind :$(kind_name(a))")
end
for b in RERUN
    any(a.base == b for a in ARMS) || error("--arms: $(repr(b)) is not an arm of this roster ($(join(repr.(a.base for a in ARMS), ", ")))")
end
"Back up an artifact about to be rewritten in place by `--arms`."
function backup_for_rerun(path)
    isfile(path) || error("--arms re-runs IN PLACE: no artifact at $path — run the full stage")
    cp(path, path * ".pre_rerun"; force = true)
end
const PLUGIN = get(SQ, "plugin_scale", "")
PLUGIN in ("", "oracle_gt_variance") ||
    error("[sequential_cv] plugin_scale: expected \"oracle_gt_variance\" or absent, got $(repr(PLUGIN))")
"The native axis (`WidthAxis`) a selector family's width lives on (its scoring's `width_axis`)."
selector_native_axis(s::Symbol) = width_axis(selector_scoring(s, PT, IGPrior(0.0, 0.0)))

# ONE cross-validation for every stage — the fold layers the same cv section
# into each entry, and this refuses a config edited by hand to disagree.
const CV = SCORER[first(SELS)].scheme.cross_validation
all(s.scheme.cross_validation == CV for s in vcat(collect(values(SCORER)), collect(values(REFINER)))) ||
    error("[sequential_cv]: the scorer and refiner entries tune on different cross-validations")
const SIDES = two_view_scene_loaders(CV, POOL)
const VAL_IDS  = first.(SIDES.validation)
const TEST_IDS = first.(SIDES.test)

# The scorer artifact: this cell's own, or — `[sequential_cv] scorer_of` — the
# one the named cell of the same (dataset, model class) tuned (the fold checked
# the two share pools, problem, cross-validation and scorer entries).
const SCORER_F  = sequential_cv_scorer_path(CFG)
const SCORER_SHARED = haskey(SQ, "scorer_of")
const REFINER_F = joinpath(OUTDIR, SEQUENTIAL_CV_REFINER)
const SIDECAR_F = joinpath(OUTDIR, SEQUENTIAL_CV_SIDECAR)
mkpath(OUTDIR)

# --- the scale prior of the marginal score -----------------------------------
# `[sequential_cv] prior` absent: Jeffreys, data-free (IGPrior(0, 0)). Present:
# the INFORMATIVE empirical prior IG(α₀, β₀), β₀ = α₀·median(σ̂²) over the
# finite ground-truth variances of the VALIDATION pairs (VisualGeometryEval `IGRobustSpec`;
# the test side is never read), so the scale of a thin partition cannot
# collapse — HEB-H, median 10 GT inliers per pair (2026-10-04):
#   { family = "inverse_gamma", fitting = "robust", alpha0 = α₀ }       a fixed α₀
#   { family = "inverse_gamma", fitting = "robust",
#     alpha0 = "cross_validated", tuning = "<entry>" }                  α₀ searched
# A cross-validated α₀ is a SCORER parameter: the scorer stage searches it
# (coarse→fine over the named configs/tuning.toml entry), each α₀ scored by the
# IG selector's validation objective at ITS OWN re-tuned a*. ONE prior for
# selection and every refit (the pair contexts carry it into the LO's own
# scoring). The scorer stage records it in its artifact; every later stage
# (and a `scorer_of` cell) reads it back from there.
const PRIOR_SPEC = get(SQ, "prior", nothing)
const ALPHA0_CV = PRIOR_SPEC !== nothing && PRIOR_SPEC["alpha0"] == "cross_validated"
if PRIOR_SPEC !== nothing
    want = ALPHA0_CV ? ("family", "fitting", "alpha0", "tuning") : ("family", "fitting", "alpha0")
    issetequal(keys(PRIOR_SPEC), want) && PRIOR_SPEC["family"] == "inverse_gamma" &&
        PRIOR_SPEC["fitting"] == "robust" && (ALPHA0_CV || Float64(PRIOR_SPEC["alpha0"]) > 0) ||
        error("[sequential_cv] prior: expected { family = \"inverse_gamma\", fitting = \"robust\", " *
              "alpha0 = α₀ > 0 | \"cross_validated\" (+ tuning = \"<entry>\") }, got $(PRIOR_SPEC)")
end
const ALPHA0_SPEC = ALPHA0_CV ? tuning_spec(CFG, String(PRIOR_SPEC["tuning"])) : nothing
const PRIOR = Ref{Any}(nothing)
const PRIOR_FIT = Ref{NamedTuple}((;))      # the scorer stage's prior record
# The validation ground-truth variances (finite, > 0), read once.
const VAL_S2 = Ref{Union{Nothing,Vector{Float64}}}(nothing)
function val_gt_s2()
    VAL_S2[] === nothing || return VAL_S2[]
    s2 = Float64[]
    for ld in validation_loaders(), p in first(ld()).pairs
        v = Float64(p.gt_variance)
        isfinite(v) && v > 0 && push!(s2, v)
    end
    isempty(s2) && error("[sequential_cv] prior: no finite ground-truth variance among the validation pairs")
    return VAL_S2[] = s2
end
"Install IG(α₀, α₀·median σ̂²_val) as THE prior and record it."
function set_prior!(α0::Real)
    s2 = val_gt_s2()
    PRIOR[] = fit_prior(IGRobustSpec(Float64(α0)), s2)
    PRIOR_FIT[] = (; prior_family = "inverse_gamma_robust", prior_alpha0 = Float64(α0),
                   prior_beta0 = PRIOR[].beta0, prior_n = length(s2), prior_median_s2 = median(s2),
                   prior_alpha0_source = ALPHA0_CV ? "cross_validated" : "fixed")
    return PRIOR[]
end
"THE selection prior: Jeffreys, the scorer artifact's (fitted or tuned) IG, or — scorer stage — the stated α₀ fitted now."
function scale_prior()
    PRIOR[] === nothing || return PRIOR[]
    PRIOR_SPEC === nothing && return PRIOR[] = fit_prior(JeffreysPriorSpec(), Float64[])
    if isfile(SCORER_F)
        sc = load_tuning_artifact(SCORER_F)
        haskey(sc, "prior_alpha0") || error("$SCORER_F was tuned under the Jeffreys prior, this cell states $(PRIOR_SPEC) — delete it and re-run the scorer stage")
        String(sc["prior_alpha0_source"]) == (ALPHA0_CV ? "cross_validated" : "fixed") &&
            (ALPHA0_CV || Float64(sc["prior_alpha0"]) == Float64(PRIOR_SPEC["alpha0"])) ||
            error("$SCORER_F was tuned under another scale prior than this cell's $(PRIOR_SPEC) — delete it and re-run the scorer stage")
        ALPHA0_CV && enforce_probe_interior(Bool(sc["prior_alpha0_boundary_hit"]); context = "prior α₀ $SCORER_F")
        return PRIOR[] = IGPrior(Float64(sc["prior_alpha0"]), Float64(sc["prior_beta0"]))
    end
    ALPHA0_CV && error("scale_prior: the cross-validated α₀ is the scorer stage's — run --stage=scorer first")
    return set_prior!(Float64(PRIOR_SPEC["alpha0"]))
end

# --- the validation pool, decoded once ---------------------------------------
# Every round of every stage is one sweep of the validation pairs, and a pool
# reads slowly (hours for the residuals of a 100 GB PhotoTourism scene).
# `cache_validation` reads the scenes on first use, `decode_parallel` at a time,
# and keeps each side loader's `(pool, residuals)` of the sampled pairs.
const VAL_CACHE = Ref{Union{Nothing,Vector{Any}}}(nothing)
function validation_loaders()
    get(SQ, "cache_validation", false) || return last.(SIDES.validation)
    if VAL_CACHE[] === nothing
        t0 = time()
        lds = last.(SIDES.validation)
        width = Int(get(SQ, "decode_parallel", length(lds)))
        @info "decoding the validation pools (cached)" scenes = VAL_IDS decode_parallel = width
        cache = Vector{Any}(undef, length(lds))
        for chunk in Iterators.partition(eachindex(lds), width)
            tasks = [i => Threads.@spawn lds[i]() for i in chunk]
            for (i, t) in tasks
                cache[i] = fetch(t); GC.gc()
            end
            @info "decoded" scenes = VAL_IDS[chunk] minutes = round((time() - t0) / 60, digits = 1)
        end
        VAL_CACHE[] = cache
        @info "validation pools decoded" pairs = [length(c[1].pairs) for c in cache] minutes = round((time() - t0) / 60, digits = 1)
    end
    return [let pp = pp; () -> pp end for pp in VAL_CACHE[]]
end

# One sweep of `loaders`: each selector `s` in `grids` swept at its widths
# `grids[s]`, refitting `refits_of(idxs_of)` (`idxs_of[s]` = that sweep's
# selections). Returns the specs' matrices (rows in pool order over the scenes
# concatenated), the per-pair stored σ̂² and the pairs per scene.
function selection_sweep(refits_of, loaders, grids::AbstractDict{Symbol})
    prior = scale_prior()
    sweeps = [s => (g, selector_scoring(s, PT, prior)) for (s, g) in sort!(collect(grids); by = first)]
    # The refits' scorings: the marginal at THE prior (rebuilt at each refit's
    # own outlier half-width), and the Jeffreys marginal for an absolute-width
    # (loss-width) column — the solo delivery's scoring, whatever the prior.
    M, s2, np = stream_selections((idxs_of, si) -> refits_of(idxs_of), Float64, PT, loaders,
                                    sweeps, StudentTUniformScoring(PT, 1.0; prior), CUDABackend(), NBATCH;
                                    solo_scoring = StudentTUniformScoring(PT, 1.0))
    return Dict(l => reduce(vcat, ms) for (l, ms) in M), reduce(vcat, s2), np
end

# --- stage 1: the scorers -----------------------------------------------------
function run_scorer()
    if SCORER_SHARED
        isfile(SCORER_F) || error("scorer_of = $(SQ["scorer_of"]): no scorer artifact at $SCORER_F — " *
                                  "run that cell's tuning first")
        @info "scorer: READ from $(SQ["scorer_of"]) (one scorer per dataset × model class)" SCORER_F
        return
    end
    isfile(SCORER_F) && (@info "scorer: artifact exists — skipping (delete to re-tune)" SCORER_F; return)
    t0 = time()
    α0rec = (;)
    if ALPHA0_CV
        :ig in SELS || error("[sequential_cv] prior: a cross-validated α₀ is scored by the IG selector, absent from this roster")
        # Each α₀: the a* search under IG(α₀, α₀·median σ̂²), scored by the IG
        # selector's validation objective at its own a* (a one-value error
        # vector, which the entry's median criterion returns unchanged).
        function alpha_curves(xs_of)
            Dict(:alpha0 => [begin
                    set_prior!(α); recs, _, _ = scorer_search()
                    @info "prior α₀ evaluated" alpha0 = α a_star = recs[:ig][:x_star_fine] objective = minimum(recs[:ig][:fine_curve])
                    [minimum(recs[:ig][:fine_curve])]
                end for α in xs_of[:alpha0]])
        end
        ra = coarse_fine_cv_batched(alpha_curves, Dict(:alpha0 => grid_spec(ALPHA0_SPEC.scheme.coarse)),
                                    ALPHA0_SPEC.scheme; label = _ -> "prior α₀", param_name = :alpha0,
                                    context_tag = "scorer/prior_alpha0")[:alpha0]
        ra[:boundary_hit] && @warn "prior α₀: coarse argmin STILL ON THE WINDOW EDGE after the extension budget — every later stage will refuse it" ra[:x_star]
        α0rec = (; prior_alpha0_boundary_hit = ra[:boundary_hit], prior_alpha0_coarse = ra[:x_star],
                 prior_alpha0_n_extensions = ra[:n_extensions], prior_alpha0_coarse_curve = ra[:curve_ys],
                 prior_alpha0_fine_curve = ra[:fine_curve],
                 prior_alpha0_grids = Dict("coarse" => tuning_table(ra[:coarse_spec]), "fine" => tuning_table(ra[:fine_spec])))
        set_prior!(ra[:x_star_fine])
        @info "prior α₀ tuned" alpha0 = ra[:x_star_fine] beta0 = PRIOR[].beta0 objective = minimum(ra[:fine_curve])
    else
        scale_prior()
    end
    recs, np, s2 = scorer_search()
    for (s, r) in recs
        r[:boundary_hit] && @warn "scorer: coarse argmin STILL ON THE WINDOW EDGE after the extension budget — the refiner stage will refuse it" selector = s r[:x_star]
        @info "scorer tuned" selector = s a_star = r[:x_star_fine] objective = minimum(r[:fine_curve]) n_extensions = r[:n_extensions]
    end
    s0 = PLUGIN == "oracle_gt_variance" ? (; s0 = reference_scale(s2[]), s0_source = PLUGIN) : (;)
    grids = Dict{Symbol,GridSpec}()
    for (s, r) in recs
        grids[Symbol("coarse|", s)] = r[:coarse_spec]; grids[Symbol("fine|", s)] = r[:fine_spec]
    end
    save_tuning_artifact(SCORER_F, SCORER[first(SELS)]; unit = TWO_VIEW_UNIT, code = TUNING_CODE, grids,
        problem = String(PROBLEM), d_g = DG, scene_ids = VAL_IDS, np_per_val = np[],
        selectors = String.(SELS), axes = Dict(String(s) => String(width_axis_name(selector_native_axis(s))) for s in SELS),
        scorer_specs = Dict(String(s) => tuning_table(SCORER[s]) for s in SELS),
        a_star = Dict(String(s) => r[:x_star_fine] for (s, r) in recs),
        a_star_coarse = Dict(String(s) => r[:x_star] for (s, r) in recs),
        boundary_hit = Dict(String(s) => r[:boundary_hit] for (s, r) in recs),
        n_extensions = Dict(String(s) => r[:n_extensions] for (s, r) in recs),
        coarse_curve = Dict(String(s) => r[:curve_ys] for (s, r) in recs),
        fine_curve = Dict(String(s) => r[:fine_curve] for (s, r) in recs),
        objective = Dict(String(s) => minimum(r[:fine_curve]) for (s, r) in recs), s0..., PRIOR_FIT[]..., α0rec...)
    @info "scorer stage done" hours = round((time() - t0) / 3600, digits = 2) s0...
end

"The a* search of every selector under THE current prior → (recs, np, s2)."
function scorer_search()
    np = Ref{Vector{Int}}(); s2 = Ref{Vector{Float64}}()
    # One sweep at every requested width of every selector: the selected model's
    # own error, no refit.
    function curves(xs_of)
        M, s2[], np[] = selection_sweep(validation_loaders(), xs_of) do idxs_of
            [LoRefitSpec("selection|$s", NoLocalOptimization(), selector_native_axis(s), xs, idxs_of[s])
             for (s, xs) in xs_of]
        end
        return Dict(s => [M["selection|$s"][:, t] for t in eachindex(xs)] for (s, xs) in xs_of)
    end
    # One batched CV per distinct scorer ENTRY (the batched probe runs one
    # scheme); selectors sharing an entry share every sweep.
    recs = Dict{Symbol,Dict{Symbol,Any}}()
    for name in unique(sequential_cv_scorer_entry(SQ, s) for s in SELS)
        sels = [s for s in SELS if sequential_cv_scorer_entry(SQ, s) == name]
        spec = SCORER[first(sels)]
        merge!(recs, coarse_fine_cv_batched(curves, Dict(s => grid_spec(spec.scheme.coarse) for s in sels),
                                            spec.scheme; label = s -> "scorer $s", param_name = :width,
                                            context_tag = "scorer/$name"))
    end
    return recs, np, s2
end

"a* per selector from the scorer artifact, through the read-side interior gate."
function read_a_star()
    isfile(SCORER_F) || error("no scorer artifact at $SCORER_F — run --stage=scorer first")
    sc = load_tuning_artifact(SCORER_F)
    sc["a_star"] isa AbstractDict || error("$SCORER_F predates per-selector scorers (one scalar a*) — " *
                                           "delete it and re-run the scorer stage")
    collect(String, sc["scene_ids"]) == VAL_IDS || error("$SCORER_F: tuned on other validation scenes")
    a = Dict{Symbol,Float64}()
    for s in SELS
        haskey(sc["a_star"], String(s)) || error("$SCORER_F: no a* for selector :$s")
        sc["scorer_specs"][String(s)] == tuning_table(SCORER[s]) ||
            error("$SCORER_F: selector :$s was tuned under another scorer spec than this cell's")
        enforce_probe_interior(Bool(sc["boundary_hit"][String(s)]); context = "scorer :$s $SCORER_F")
        a[s] = Float64(sc["a_star"][String(s)])
    end
    return a, sc
end

# --- stage 2: the refiners, at the fixed a* -----------------------------------
function run_refiner()
    isfile(REFINER_F) && isempty(RERUN) && (@info "refiner: artifact exists — skipping (delete to re-tune)" REFINER_F; return)
    isempty(RERUN) || any(arm.base in RERUN for arm in TUNED) ||
        (@info "refiner: --arms names only pinned (selection-width) arms — nothing to tune" RERUN; return)
    a, _ = read_a_star()
    old = nothing
    if !isempty(RERUN)
        old = load_tuning_artifact(REFINER_F)
        all(Float64(old["a_star"][String(s)]) == a[s] for s in SELS) ||
            error("$REFINER_F was tuned at a* = $(old["a_star"]), the scorer artifact says $a — re-run the whole stage")
        backup_for_rerun(REFINER_F)
    end
    t0 = time()
    by_base = Dict(arm.base => arm for arm in TUNED)
    # One sweep: each selector at its single column a*, every requested
    # (arm, width) a one-column refit spec at that width's own port.
    function curves(xs_of)
        sels = unique(by_base[b].sel for b in keys(xs_of))
        M, _, _ = selection_sweep(validation_loaders(), Dict(s => [a[s]] for s in sels)) do idxs_of
            specs = LoRefitSpec[]
            for (b, xs) in xs_of, (i, x) in enumerate(xs)
                arm = by_base[b]
                lo = arm.ctor(x)
                push!(specs, LoRefitSpec("$b|$i", lo, arm.selection, [a[arm.sel]], idxs_of[arm.sel];
                                         width_delivery(arm.kind, lo, x, 1)...))
            end
            specs
        end
        return Dict(b => [M["$b|$i"][:, 1] for i in eachindex(xs)] for (b, xs) in xs_of)
    end
    # The batched probe runs under ONE scheme, so the arms batch by the ENTRY
    # their kind names: kinds sharing an entry (the two native kinds) share
    # every sweep; each entry is one sweep per round over all of its arms.
    recs = Dict{String,Dict{Symbol,Any}}()
    for name in unique(String.(values(SQ["refiner"])))
        spec = tuning_spec(CFG, name)
        arms = [arm.base for arm in TUNED if SQ["refiner"][kind_name(arm)] == name &&
                                            (isempty(RERUN) || arm.base in RERUN)]
        isempty(arms) && continue
        coarse = Dict(b => grid_spec(spec.scheme.coarse) for b in arms)
        merge!(recs, coarse_fine_cv_batched(curves, coarse, spec.scheme; param_name = :width,
                                            context_tag = "refiner/$name"))
    end
    for b in sort!(collect(keys(recs)))
        r = recs[b]
        r[:boundary_hit] && @warn "refiner: coarse argmin STILL ON THE WINDOW EDGE after the extension budget — the deployed readers will refuse this arm" arm = b r[:x_star]
        @info "refiner tuned" arm = b width = round(r[:x_star_fine], sigdigits = 4) val_median = round(minimum(r[:fine_curve]), digits = 3) n_ext = r[:n_extensions]
    end
    grids = Dict{Symbol,GridSpec}()
    for (b, r) in recs
        grids[Symbol("coarse|", b)] = r[:coarse_spec]; grids[Symbol("fine|", b)] = r[:fine_spec]
    end
    per_arm = Dict{Symbol,Dict{String,Any}}(
        :w_star => Dict{String,Any}(b => r[:x_star_fine] for (b, r) in recs),
        :w_star_coarse => Dict{String,Any}(b => r[:x_star] for (b, r) in recs),
        :boundary_hit => Dict{String,Any}(b => r[:boundary_hit] for (b, r) in recs),
        :n_extensions => Dict{String,Any}(b => r[:n_extensions] for (b, r) in recs),
        :coarse_curve => Dict{String,Any}(b => r[:curve_ys] for (b, r) in recs),
        :fine_curve => Dict{String,Any}(b => r[:fine_curve] for (b, r) in recs),
        :objective => Dict{String,Any}(b => minimum(r[:fine_curve]) for (b, r) in recs))
    if old !== nothing          # --arms: every other arm keeps its tuned entries
        for b in collect(String, old["arms"]) if !(b in RERUN)
            for (k, d) in per_arm
                d[b] = old[String(k)][b]
            end
            for kind in ("coarse|", "fine|")
                grids[Symbol(kind, b)] = old.grid_specs[Symbol(kind, b)]
            end
        end end
        Set(keys(per_arm[:w_star])) == Set(arm.base for arm in TUNED) ||
            error("--arms: $REFINER_F does not cover this roster's arms")
    end
    save_tuning_artifact(REFINER_F, SCORER[first(SELS)]; unit = TWO_VIEW_UNIT, code = TUNING_CODE, grids,
        problem = String(PROBLEM), d_g = DG, scene_ids = VAL_IDS,
        a_star = Dict(String(s) => v for (s, v) in a),
        refiner_specs = Dict(k => tuning_table(s) for (k, s) in REFINER),
        arms = [arm.base for arm in TUNED],
        selectors = Dict(arm.base => String(arm.sel) for arm in TUNED),
        (k => d for (k, d) in per_arm)..., rerun_arms = RERUN)
    @info "refiner stage done" hours = round((time() - t0) / 3600, digits = 2)
end

# The clipped axes of a probe record, in the deployed readers' vocabulary: the
# side of the argmin that sits within the edge margin.
function probe_hits(axis::AbstractString, hit::Bool, curve, margin::Integer)
    hit || return String[]
    j = argmin(curve)
    return [string(axis, j <= 1 + margin ? "_lo" : "_hi")]
end

# --- stage 3: the ζ evaluation, at (a*, w*) -----------------------------------
function run_evaluate()
    isfile(SIDECAR_F) && isempty(RERUN) && (@info "evaluate: sidecar exists — skipping (delete to re-run)" SIDECAR_F; return)
    isfile(REFINER_F) || error("no refiner artifact at $REFINER_F — run --stage=refiner first")
    a, sc = read_a_star()
    rf = load_tuning_artifact(REFINER_F)
    all(Float64(rf["a_star"][String(s)]) == a[s] for s in SELS) ||
        error("$REFINER_F was tuned at a* = $(rf["a_star"]), the scorer artifact says $a")
    Set(collect(String, rf["arms"])) == Set(arm.base for arm in TUNED) || error("$REFINER_F: its arms differ from the roster's tuned arms")
    t0 = time()
    # A pinned arm's width is its selector's a* (`operating_width`); its only
    # clipped axis can be the selection's.
    tuned = Dict(arm.base => (selection = a[arm.sel],
                              width = operating_width(arm, a[arm.sel], is_tuned(arm) ? Float64(rf["w_star"][arm.base]) : nothing))
                 for arm in ARMS)
    hits = Dict(arm.base => vcat(
        probe_hits("selection", Bool(sc["boundary_hit"][String(arm.sel)]), sc["coarse_curve"][String(arm.sel)],
                   SCORER[arm.sel].scheme.edge_margin),
        is_tuned(arm) ? probe_hits(kind_name(arm), Bool(rf["boundary_hit"][arm.base]), rf["coarse_curve"][arm.base],
                                   REFINER[kind_name(arm)].scheme.edge_margin) : String[]) for arm in ARMS)
    grids = merge(Dict(Symbol("scorer|", k) => v for (k, v) in sc.grid_specs), rf.grid_specs)
    record = (; problem = String(PROBLEM), d_g = DG, scene_ids = vcat(VAL_IDS, TEST_IDS), nval = length(VAL_IDS),
              arms = [arm.base for arm in ARMS],
              tuned_selection = Dict(b => t.selection for (b, t) in tuned),
              tuned_width = Dict(b => t.width for (b, t) in tuned),
              tuned_objective = Dict(arm.base => Float64(rf["objective"][arm.base]) for arm in TUNED),
              width_sources = Dict(arm.base => is_tuned(arm) ? "tuned" : "selection" for arm in ARMS),
              boundary_hits = hits, scorer_artifact = SCORER_F, refiner_artifact = REFINER_F)
    s0 = haskey(sc, "s0") ? (; s0 = Float64(sc["s0"]), s0_source = String(sc["s0_source"])) : (;)
    if ROSTER_KIND == "basin"
        # The basin test is the δ-perturbed ladder (run_basin_ladder.jl
        # --solo-cv), not the ζ ladder: the operating points ARE the result.
        save_tuning_artifact(SIDECAR_F, SCORER[first(SELS)]; unit = TWO_VIEW_UNIT, code = TUNING_CODE, grids,
                             mode = "basin", tuning = "sequential_cv", record..., s0...)
        @info "basin operating points written" SIDECAR_F
        return
    end
    # The evaluation's own selection grids: exactly {ζ_j · a*_s} per selector.
    egrid = Dict(s => sort!(unique!([corrupt_native(a[s], ζ) for ζ in ZETAS])) for s in SELS)
    egrids = Dict(width_axis_name(selector_native_axis(s)) => egrid[s] for s in SELS)
    run_arms = isempty(RERUN) ? ARMS : [arm for arm in ARMS if arm.base in RERUN]
    prev = nothing
    if !isempty(RERUN)
        ROSTER_KIND == "composed" || error("--arms: the basin sidecar has no evaluation to splice")
        prev = load_tuning_artifact(SIDECAR_F)
        Float64.(prev["zetas"]) == ZETAS || error("--arms: $SIDECAR_F was evaluated on another ζ ladder")
        backup_for_rerun(SIDECAR_F)
    end
    M, _, npt = selection_sweep(last.(SIDES.test), egrid) do idxs_of
        [miscal_evaluation_refit(arm, idxs_of, tuned[arm.base], ZETAS, egrids; d_g = DG) for arm in run_arms]
    end
    evaluation = Dict{String,Any}(arm.base => M["$(arm.base)|evaluation"] for arm in run_arms)
    if prev !== nothing         # --arms: every other arm keeps its evaluation
        collect(prev["np_per_test"]) == collect(npt) || error("--arms: the test pairs differ from $SIDECAR_F's")
        for arm in ARMS
            arm.base in RERUN || (evaluation[arm.base] = prev["evaluation"][arm.base])
        end
    end
    save_tuning_artifact(SIDECAR_F, SCORER[first(SELS)]; unit = TWO_VIEW_UNIT, code = TUNING_CODE, grids,
        mode = "miscal", tuning = "sequential_cv", record...,
        zetas = ZETAS, evaluation = evaluation, np_per_test = npt, rerun_arms = RERUN, s0...)
    @info "evaluation written" SIDECAR_F hours = round((time() - t0) / 3600, digits = 2)
    # The calibrated (ζ = 1) summary: median pose error and mAA@10 per arm.
    j1 = argmin(abs.(log2.(ZETAS)))
    println("\nsequential CV @ ζ = 1   a* = $(Dict(s => round(v, sigdigits = 4) for (s, v) in a))   test pairs = $(sum(npt))")
    @printf("  %-20s %-18s %10s %10s %8s\n", "arm", "kind", "w*", "med°", "mAA@10")
    for arm in ARMS
        e = evaluation[arm.base][:, j1]
        @printf("  %-20s %-18s %10.4g %10.3f %8.4f\n", arm.base, kind_name(arm), tuned[arm.base].width,
                finite_median(e), eligible_maa(e))
    end
end

# --- the anchoring ablation: the fixed plug-in scale ---------------------------
function run_anchoring()
    ROSTER_KIND == "composed" || error("--stage=anchoring: the ablation evaluates a COMPOSED sidecar")
    iface = String(TOML.parsefile(projectdir("configs", "miscal_protocol.toml"))["anchoring_ablation"]["scale_interface"])
    VisualGeometryCore.SCALE_INTERFACE_TAGS[iface] === VisualGeometryCore.FixedScale ||
        error("miscal_protocol.toml [anchoring_ablation] scale_interface = $(repr(iface)): " *
              "the sequential CV implements the \"fixed_scale\" interface only")
    out = joinpath(OUTDIR, "anchoring_ablation-" * iface, "zeta_evaluation.jld2")
    isfile(out) && (@info "anchoring: artifact exists — skipping (delete to re-run)" out; return)
    isfile(SIDECAR_F) || error("no sidecar at $SIDECAR_F — run the evaluate stage first")
    tk = load_tuning_artifact(SIDECAR_F)
    haskey(tk, "s0") || error("$SIDECAR_F carries no plug-in scale s0 — set [sequential_cv] plugin_scale and re-tune")
    plugin_scale = Float64(tk["s0"])
    Float64.(tk["zetas"]) == ZETAS || error("$SIDECAR_F: its ζ ladder differs from the protocol's")
    # Only the scale-multiple arms have a partition anchor to remove.
    ro = [arm for arm in ARMS if arm.kind isa ScaleMultiple]
    tuned = Dict(arm.base => (selection = Float64(tk["tuned_selection"][arm.base]),
                              width = Float64(tk["tuned_width"][arm.base])) for arm in ro)
    sels = sort!(unique(arm.sel for arm in ro))
    a = Dict(s => only(unique(tuned[arm.base].selection for arm in ro if arm.sel === s)) for s in sels)
    egrid = Dict(s => sort!(unique!([corrupt_native(a[s], ζ) for ζ in ZETAS])) for s in sels)
    egrids = Dict(width_axis_name(selector_native_axis(s)) => egrid[s] for s in sels)
    t0 = time()
    @info "anchoring ablation: fixed plug-in scale" plugin_scale s0_source = tk["s0_source"] arms = [arm.base for arm in ro]
    M, _, npt = selection_sweep(last.(SIDES.test), egrid) do idxs_of
        [miscal_evaluation_refit(arm, idxs_of, tuned[arm.base], ZETAS, egrids; d_g = DG, plugin_scale)
         for arm in ro]
    end
    save_tuning_artifact(out, SCORER[first(SELS)]; unit = TWO_VIEW_UNIT, code = TUNING_CODE,
        grids = Dict{Symbol,GridSpec}(), mode = "evaluation", problem = String(PROBLEM), d_g = DG,
        scene_ids = vcat(VAL_IDS, TEST_IDS), nval = length(VAL_IDS),
        arms = [arm.base for arm in ro],
        tuned_selection = Dict(b => t.selection for (b, t) in tuned),
        tuned_width = Dict(b => t.width for (b, t) in tuned),
        evaluation_of = SIDECAR_F, scale_interface = iface, plugin_scale, s0 = plugin_scale,
        zetas = ZETAS, evaluation = Dict(arm.base => M["$(arm.base)|evaluation"] for arm in ro),
        np_per_test = npt)
    @info "anchoring evaluation written" out hours = round((time() - t0) / 3600, digits = 2)
end

STAGE == "anchoring" && (run_anchoring(); exit(0))
STAGE in ("all", "scorer")   && run_scorer()
STAGE in ("all", "refiner")  && run_refiner()
# The evaluation reads the TEST side only: release the cached validation pairs
# first (hundreds of GB on PhotoTourism) so the test stream has the memory.
VAL_CACHE[] = nothing; GC.gc()
STAGE in ("all", "evaluate") && run_evaluate()
