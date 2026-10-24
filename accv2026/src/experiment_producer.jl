# =============================================================================
# experiment_producer.jl — SHARED experiment producer (STREAMING).
#
# The one code path for every streamed selection+LO experiment — the
# validation-budget sweep, the miscalibration (ζ) sweep, and the well-depth
# (Δ) sweep — called by the `run_lo_sensitivity.jl` driver; the tuning
# (run_sequential_cv.jl) streams through the same evaluator `stream_selections`.  Experiments
# are `StreamedExperiment` strategy types (grid/selector/bundle/result policies as
# methods); selection methods are `SelectorSpec` strategies (IG, MSAC, one
# mixture-marginal selector per Δ).  Given a scene-ordered list of SCENE
# LOADERS (zero-arg closures returning that scene's `(pool, residuals)`; `scenes[1:nval]`
# are val, the rest test) it streams the pool one scene at a time so peak
# host+GPU memory is ONE scene, not the whole pool — which is what lets it run
# on the ENTIRE PT dataset (~21 × 2200 pairs ≈ 46k, ~1.6 TB on disk) instead
# of a per-scene cap:
#
#   PHASE 1 (val scalars): load each VAL scene, collect σ̂² (`gt_variance`), free.
#     → the native grids, realized from the run's `[tuning]` spec (VisualGeometryToolkitEval
#       `grid_spec`: the coverage window rule over the val σ̂² band + spacing).
#       The IG prior is Jeffreys ⇒ `IGPrior(0,0)`, data-independent, so no
#       full-pool scalar sweep is needed.
#   PHASE 2 (stage→grid→selection rows, per scene): VisualGeometryToolkitEval's
#     `stream_selections` — per scene, stage each batch on-device ONCE, evaluate
#     EVERY selector's grid on that staged copy (VisualGeometryToolkitCore
#     `select_on_grid!` — RANSACScoringDoneRight's grid kernels), then score each selector's
#     per-(pair, column) selection through `apply_lo_refits` (a
#     NoLocalOptimization row: the selected pool model's imc).  Free the scene.
#
# The per-pair errs/idxs and the post-LO `M` matrices are scalar (pair × column),
# ~MB; only the staged `sorted_sq_flat` + the raw scene pairs are large, and both
# are bounded to one batch / one scene by the streaming loop. Output is identical
# (bit-for-bit) to staging the whole pool at once — staging is pair-local.
#
# Then: bucket the per-scene matrices → `WindowedGridMethod` (free argmin over
# every grid column inside the σ_med(n)-anchored window), and run the production
# `bootstrap_trials` over the spec's budget sampling (offline, in
# plot_lo_sensitivity.jl). Every tuning parameter is the `windowed_bootstrap`
# spec the bundle records (save_tuning_artifact).
# =============================================================================

using CUDA, Statistics, JLD2
using VisualGeometryToolkitEstimation: NoLocalOptimization
using RANSACScoringDoneRight: loss_spec, loss_scale_bounds, StudentTUniformScoring, SimFitPP, loss_width_scoring
using VisualGeometryToolkitCore: AbstractLossShape, WidthAxis, LossWidth, OutlierHalfwidth, width_axis_name, width_axis,
    native_map, IGPrior, codimension, minimal_sample_size
using VisualGeometryToolkitEval.Stats: reference_scale
using VisualGeometryToolkitEval.Tuning: TuningSpec, WindowedBootstrap, CoverageWindow, GridSpec, grid,
    grid_spec, save_tuning_artifact, fit_prior, ALL_PRIOR_SPECS
using VisualGeometryToolkitEval.Evaluation: stream_selections, LoRefitSpec

# The paper config (rosters, vocabulary, registries) on top of the package.
include(joinpath(@__DIR__, "config.jl"))

# A "scene" may be supplied as a zero-arg loader (streaming, frees between scenes)
# or as an already-loaded `(pool, residuals)` (tiny in-memory smoke/test).
# Normalize to a loader.
_as_loader(loader::Function) = loader
_as_loader(scene::Tuple) = () -> scene

# =============================================================================
# THE validation scale — configs/protocol.toml [scale_estimation], which carries
# the measurements behind the floor.
#
# The estimator is the pools' stored `gt_variance`, unchanged. What is applied
# here is a FLOOR on the GT inlier count: below it, the stored value is biased
# low because an 8-DOF fit to few points sits close to the very points whose
# residuals measure it. Measured on HEB-H the stored σ̂ climbs 3.01e-4 (4-12
# inliers) to 4.76e-4 (201+) and plateaus past ~80; a noise scale cannot depend
# on a pair's inlier count, so that slope is the bias.
#
# PER-PAIR ORDER IS LOAD-BEARING. The vectors are one entry per pair in pool
# order INCLUDING non-finite entries, because the caller indexes them against
# the validation matrices' rows (`s2flat[i]` vs row i of Mval). Only the grid
# and the quantile band take the finite subset. Filtering here would misalign
# scale with row, which nothing downstream would notice.
# =============================================================================
"""
    val_sigma2_by_scene(loaders, nval) -> Vector{Vector{Float64}}

Each validation scene's per-pair σ̂², in pool order, `NaN` where the pair has no
stored variance or has fewer than `[scale_estimation] min_gt_inliers_for_scale`
GT inliers.
"""
function val_sigma2_by_scene(loaders, nval)
    floor_in = Int(protocol_value("scale_estimation", "min_gt_inliers_for_scale"))
    out = Vector{Vector{Float64}}(undef, nval)
    for si in 1:nval
        pp = first(loaders[si]()).pairs
        out[si] = Float64[count(p.gt_inliers) >= floor_in ? Float64(p.gt_variance) : NaN for p in pp]
        kept = count(isfinite, out[si])
        @info "validation scale" scene = si pairs = length(out[si]) above_floor = kept #=
            =# min_gt_inliers = floor_in #=
            =# s_hat_median = kept == 0 ? NaN : round(sqrt(median(filter(isfinite, out[si]))), sigdigits=4)
        pp = nothing
        GC.gc()
    end
    return out
end

# The finite subset, for the coverage grid and the σ̂² quantile band (order does
# not matter there).
_val_sigma2(loaders, nval) = filter(isfinite, reduce(vcat, val_sigma2_by_scene(loaders, nval)))


# =============================================================================
# Selector strategies.  A `SelectorSpec` is one selection method: its label,
# native axis and grid, and its sweep (a GPU kernel over the staged batch or a
# per-pair host loop — the evaluator's `stream_selections` runs either).  The experiment types decide WHICH
# selectors run (IG + MSAC for the LO experiments; one per well depth Δ for the
# Δ-sweep); `stream_selections` (the evaluator) streams them all, and
# each selector contributes one selection row "<label>" (the selected pool
# model's imc, a NoLocalOptimization refit).  Labels are carried whole (not
# composed) so existing bundles/renderers see byte-identical keys.
# =============================================================================
struct SelectorSpec{S}
    key::Symbol                 # the stream's grid key (unique per selector)
    label::String               # the selection row's label ("<TAG> sel")
    axis::WidthAxis             # native axis of `native`: OutlierHalfwidth() | LossWidth()
    native::Vector{Float64}
    scoring::S                  # the scoring its grid evaluates (`select_on_grid!`)
end

_labels(selectors) = String[sel.label for sel in selectors]
_sweeps(selectors) = [sel.key => (sel.native, sel.scoring) for sel in selectors]
_selection_rows(selectors) = (idxs_of, _) ->
    [LoRefitSpec(sel.label, NoLocalOptimization(), sel.axis, sel.native, idxs_of[sel.key])
     for sel in selectors]

# =============================================================================
# Generic selector roster.
# A selector FAMILY is a display tag and a RANSACScoringDoneRight scoring; its
# native axis is the scoring's `width_axis` (VisualGeometryToolkitCore), and the
# evaluator's `stream_selections` evaluates its grid (`select_on_grid!`: RSDR's
# grid kernels, or SIMFIT++'s host loop). `build_selectors(selectors, …)` gives each family its "<TAG> sel"
# selection entry. The bundles are SELECTION-ONLY: refined arms exist only via
# the sequential CV (run_sequential_cv.jl).
# =============================================================================

"Display tag of each selector family, by its sweep key (byte-identical to the bundles' labels)."
const SELECTOR_TAGS = Dict(:ig => "IG ", :msac => "MSAC", :ransac => "RANSAC", :magsac => "MAGSAC",
                           :gau => "GAU", :welsch => "WEL", :geman => "GEM", :simfitpp => "SIMFIT")

# The RANSACScoringDoneRight loss-width family tag of a sweep key.
const _LOSS_WIDTH_FAMILY = Dict(:msac => :msac, :ransac => :ransac, :magsac => :magsac,
                                :gau => :mlesac, :welsch => :welsch_cost, :geman => :geman)

"""
    selector_scoring(fam, problem_type, prior)

The scoring of selector family `fam` (a sweep key): the Student-t-uniform
marginal at `prior` (`:ig`), SIMFIT++ (`:simfitpp`), or the loss-width
family's scoring at the problem's codimension.
"""
function selector_scoring(fam::Symbol, problem_type, prior)
    haskey(SELECTOR_TAGS, fam) ||
        error("unknown selector family :$fam (known: $(sort!(collect(keys(SELECTOR_TAGS)))))")
    fam === :ig && return StudentTUniformScoring(problem_type, 1.0; prior)   # the grid supplies the half-widths
    fam === :simfitpp && return SimFitPP()
    return loss_width_scoring(_LOSS_WIDTH_FAMILY[fam], codimension(problem_type))
end

"""
    build_selectors(selectors, prior, grids, problem_type)

One selection-only `SelectorSpec` per family in `selectors`, on the grid of its
scoring's native axis.
"""
function build_selectors(selectors::AbstractVector{Symbol}, prior, grids::AbstractDict{Symbol}, problem_type)
    specs = SelectorSpec[]
    for fam in selectors
        scoring = selector_scoring(fam, problem_type, prior)
        axis = width_axis(scoring)
        push!(specs, SelectorSpec(fam, "$(SELECTOR_TAGS[fam]) sel", axis, grids[width_axis_name(axis)], scoring))
    end
    return specs
end

# Save the compute-once "M-bundle" through THE tuning-artifact writer:
# everything needed to re-run `bootstrap_trials` OFFLINE (no GPU, no LO) with
# full BCa CIs — the run's `windowed_bootstrap` spec (budget sampling, window,
# criterion), the grid specs, the per-scene post-LO matrices and the
# per-scene σ̂². The expensive GPU sweep + LO is done once; CIs become free.
function _save_lo_bundle(path::AbstractString, mode::AbstractString, spec::TuningSpec;
                         grid_specs, Mse, s2_by_scene, np_per, nval, s0, scene_ids,
                         problem_type, extra::Dict, labels, label_axis = Dict{String,String}())
    save_tuning_artifact(path, spec; grids = grid_specs, unit = TWO_VIEW_UNIT, code = TUNING_CODE,
        mode          = String(mode),
        labels        = collect(String, labels),
        label_axis    = label_axis,               # label => "outlier_halfwidth"|"loss_width"
        M             = Mse,                       # Dict{String,Vector{Matrix{Float64}}} (per scene)
        s2_by_scene   = s2_by_scene,
        np_per        = np_per,
        nval          = Int(nval),
        s0            = s0,
        scene_ids     = collect(String, scene_ids),
        problem       = string(problem_type),
        d_g           = codimension(problem_type),   # the codimension the native grids are built at
        # `extra` carries mode-specific entries (zetas / n_use / deltas).
        (Symbol(k) => v for (k, v) in extra)...)
    return path
end

# =============================================================================
# Experiment strategy types.  The validation-budget and miscalibration (ζ)
# experiments share ONE streamed produce path — val scalars → native grids →
# stage/sweep/LO → s0 → bundle — and differ only in three policies: how the
# native grids are built, what mode metadata the bundle carries, and what the
# producer returns.  Each policy is a method on the experiment type (dispatch,
# not branching): adding an experiment = one struct + three small methods, not
# another copy of the pipeline.  The public `lo_sensitivity_sweep` /
# `miscalibration_sweep` entry points are preserved as thin wrappers.
# =============================================================================
abstract type StreamedExperiment end

"Sample-budget (validation-size) sensitivity: test error vs val size (the spec's budget sizes)."
struct ValidationBudgetExperiment <: StreamedExperiment
    selectors::Vector{Symbol}   # selector roster (families of SELECTOR_TAGS)
end

"Controlled miscalibration (accv §eq-29): test error vs scale corruption `ζ ∈ zetas`."
struct MiscalibrationExperiment <: StreamedExperiment
    zetas::Vector{Float64}
    n::Union{Nothing,Int}       # val size; `nothing` = the full val pool
    selectors::Vector{Symbol}   # selector roster (families of SELECTOR_TAGS)
end
MiscalibrationExperiment(zetas, n) = MiscalibrationExperiment(zetas, n, [:ig, :msac])

"""
Well-depth (Δ) sweep: selection error vs loss contrast, with the Δ→∞ limit
anchored at the closed-form Student-t (the IG baseline selector).  One
mixture-marginal selector per `Δ ∈ deltas` (Track-B quadrature,
RANSACScoringDoneRight `grid_evaluate` of a `loss_spec`), sweeping the SAME outlier-half-width grid as the IG
selector (shared uniform outlier model ⇒ shared eq-(28) map).
`include_baselines=true` also runs the production IG/MSAC selectors on the
same streamed pool, giving the anchor curves for free.
"""
struct DeltaSweepExperiment{L<:AbstractLossShape} <: StreamedExperiment
    loss::L
    deltas::Vector{Float64}
    include_baselines::Bool
    NG::Union{Nothing,Int}     # trapezoid nodes for the scale quadrature (nothing = RSDR `loss_spec`'s own)
end
DeltaSweepExperiment(loss::AbstractLossShape, deltas::AbstractVector{<:Real};
                     include_baselines::Bool=true, NG::Union{Nothing,Integer}=nothing) =
    DeltaSweepExperiment(loss, collect(Float64, deltas), include_baselines,
                         NG === nothing ? nothing : Int(NG))

_mode_tag(::ValidationBudgetExperiment)   = "validation_budget"
_mode_tag(::MiscalibrationExperiment) = "miscal"
_mode_tag(::DeltaSweepExperiment)     = "delta"

# --- native grids ----------------------------------------------------------------
# The spec decides every grid: the coverage window rules of its
# `outlier_halfwidth` / `loss_width` axes over the val σ̂² band (band-restricted
# q and margin for the validation-budget / Δ sweeps; the natural regime's full-range q and
# wide margin; the miscal sweep's ζ-reaching window — a clamp would flatten the
# tail and hide the effect: MSAC's reachable native window scales as hi/lo of
# the scale-multiple window, IG's as exp((hi²−lo²)/2)) and its standardized
# `scale_multiple` display axis. A ζ sweep whose ladder the coverage does not
# reach is refused.
function _grid_specs(spec::TuningSpec, val_sigma2s, d_g::Int)
    sch = spec.scheme
    sch isa WindowedBootstrap ||
        throw(ArgumentError("[tuning.$(spec.name)] is a $(nameof(typeof(sch))), not a windowed_bootstrap"))
    w = sch.scale_multiple_window
    return Dict{Symbol,GridSpec}(
        :outlier_halfwidth => grid_spec(sch.outlier_halfwidth; scale_multiple_window = w,
                                        native = native_map(OutlierHalfwidth(); d_g), s2 = val_sigma2s),
        :loss_width => grid_spec(sch.loss_width; scale_multiple_window = w,
                                 native = native_map(LossWidth(); d_g), s2 = val_sigma2s),
        :scale_multiple => grid_spec(sch.scale_multiple; scale_multiple_window = w))
end

_check_reach(e::StreamedExperiment, spec) = nothing
function _check_reach(e::MiscalibrationExperiment, spec)
    need = maximum(abs.(log2.(e.zetas)))
    for f in (:outlier_halfwidth, :loss_width)
        win = getfield(spec.scheme, f).window
        win isa CoverageWindow && win.zeta_octaves >= need || throw(ArgumentError(
            "[tuning.$(spec.name).$f]: its coverage window does not reach the ζ ladder (2^±$need)"))
    end
    return nothing
end

# --- selector policy ----------------------------------------------------------
# Roster-driven: `e.selectors` through `build_selectors`.
_selectors(e::Union{ValidationBudgetExperiment, MiscalibrationExperiment},
           prior, grids, problem_type, val_sigma2s) =
    build_selectors(e.selectors, prior, grids, problem_type)

# delta: one Track-B mixture-marginal selector per well depth Δ (selection
# only), optionally alongside the production IG/MSAC selectors.  Float64 on
# device — the Stage-6 gate showed Float32 flips near-ties exactly at low Δ,
# where score gaps shrink below single precision.  The log-scale quadrature
# bounds come from the val σ̂² band (`loss_scale_bounds` semantics), fixed
# across Δ and scenes so every curve shares one grid.
function _selectors(e::DeltaSweepExperiment, prior, grids, problem_type, val_sigma2s)
    sels = e.include_baselines ?
        build_selectors([:ig, :msac], prior, grids, problem_type) :
        SelectorSpec[]
    t_lo, t_hi = loss_scale_bounds(val_sigma2s, length(val_sigma2s))
    for (di, Δ) in enumerate(e.deltas)
        spec = e.NG === nothing ? loss_spec(e.loss, IGPrior(); Δ, t_lo, t_hi) :
                                  loss_spec(e.loss, IGPrior(); Δ, t_lo, t_hi, NG = e.NG)
        push!(sels, SelectorSpec(Symbol(:delta_, di), "Δ=$(round(Δ; sigdigits=3)) sel",
                                 OutlierHalfwidth(), grids[:outlier_halfwidth], spec))
    end
    return sels
end

# --- bundle-metadata and result policies -------------------------------------
_n_use(e::MiscalibrationExperiment, np_per, nval) =
    something(e.n, sum(np_per[1:nval]))

_bundle_extra(e::ValidationBudgetExperiment, np_per, nval) = Dict{String,Any}()
_bundle_extra(e::MiscalibrationExperiment, np_per, nval) =
    Dict("zetas" => e.zetas, "n_use" => _n_use(e, np_per, nval))
# The bundle records the loss shape by its VGC type name (`WelschShape`, …).
_bundle_extra(e::DeltaSweepExperiment, np_per, nval) =
    Dict("deltas" => e.deltas, "loss" => string(nameof(typeof(e.loss))),
         "NG" => something(e.NG, "loss_spec default"))

# validation_budget: flat (val+test, scene-ordered) per-pair matrices for the per-scale-multiple
# diagnostic evaluation.  The n-sweep + BCa CIs live ONLY in the offline renderer
# (which re-bootstraps the saved bundle via the package's
# `compute_method_rows`), so the producer just makes M.  Keys follow the
# roster's labels.
_produce_result(e::ValidationBudgetExperiment, Mse, s0, grids, np_per, nval; dg) =
    (; M = Dict{String,Matrix{Float64}}(l => reduce(vcat, Mse[l]) for l in keys(Mse)),
       s0, grids, to_native_outlier_halfwidth = native_map(OutlierHalfwidth(); d_g = dg),
       to_native_loss_width = native_map(LossWidth(); d_g = dg))

# miscal: the per-ζ sweep + BCa CIs live in the offline renderer (which
# re-applies ζ² to the val σ̂² and re-bootstraps), so the producer returns the
# sweep description only.
_produce_result(e::MiscalibrationExperiment, Mse, s0, grids, np_per, nval; dg) =
    (; zetas = e.zetas, s0, n = _n_use(e, np_per, nval))

# delta: flat per-pair matrices per label (Δ curves + optional IG/MSAC
# anchors), plus the shared outlier-half-width axis — everything the Δ-vs-error figure needs.
_produce_result(e::DeltaSweepExperiment, Mse, s0, grids, np_per, nval; dg) =
    (; M = Dict{String,Matrix{Float64}}(l => reduce(vcat, Mse[l]) for l in keys(Mse)),
       Δs = e.deltas, outlier_halfwidth_grid = grids[:outlier_halfwidth], s0,
       to_native = native_map(OutlierHalfwidth(); d_g = dg))

"""
    run_experiment(exp::StreamedExperiment, scenes, nval; problem_type, spec,
                   prior_spec, batch, backend, save_bundle, scene_ids) -> NamedTuple

The one streamed produce path for every LO experiment.  `scenes` is a
scene-ordered vector whose `[1:nval]` entries are val and the rest test; each
entry is either a zero-arg loader closure (STREAMING — the production path,
frees each scene before the next) or already-loaded pairs (tiny in-memory
smoke/test).  PHASE 1 collects the val σ̂² scalars and realizes the native
grids from `spec` (a `windowed_bootstrap` TuningSpec); PHASE 2 streams
stage→sweep→LO per scene. When `save_bundle` is set, persists the compute-once
M-bundle (through `save_tuning_artifact`, with the spec and grid specs) from
which the offline renderer (`plot_lo_sensitivity.jl`) re-bootstraps with full
BCa CIs — the expensive GPU sweep + LO runs once. `batch` (pairs staged per
chunk) and `backend` are compute knobs, not tuning parameters.
"""
function run_experiment(exp::StreamedExperiment, scenes::AbstractVector, nval::Integer;
                        problem_type, spec::TuningSpec,
                        prior_spec=ALL_PRIOR_SPECS[1],
                        batch::Integer=600, backend=CUDABackend(),
                        save_bundle::Union{Nothing,AbstractString}=nothing,
                        scene_ids::AbstractVector=String[])
    loaders = _as_loader.(scenes)
    dg = codimension(problem_type)
    _check_reach(exp, spec)

    # PHASE 1 — val σ̂² scalars → prior, the spec's native grids.
    val_sigma2s = _val_sigma2(loaders, nval)
    prior = fit_prior(prior_spec, val_sigma2s)     # Jeffreys ⇒ IGPrior(0,0); data-independent
    grid_specs = _grid_specs(spec, val_sigma2s, dg)
    grids = Dict{Symbol,Vector{Float64}}(k => grid(g) for (k, g) in grid_specs)

    # PHASE 2 — streamed stage→sweep→selection rows over the experiment's selectors.
    selectors = _selectors(exp, prior, grids, problem_type, val_sigma2s)
    Mse, s2_by_scene, np_per = stream_selections(_selection_rows(selectors), Float64,
        problem_type, loaders, _sweeps(selectors), StudentTUniformScoring(problem_type, 1.0; prior), backend, Int(batch))
    s0 = reference_scale(reduce(vcat, s2_by_scene))   # over every finite σ̂² in the pool

    # Persist the compute-once bundle for offline re-bootstrap + rendering.
    save_bundle === nothing || _save_lo_bundle(save_bundle, _mode_tag(exp), spec;
        grid_specs, Mse, s2_by_scene, np_per, nval, s0, scene_ids, problem_type,
        extra=_bundle_extra(exp, np_per, Int(nval)),
        labels=_labels(selectors),
        label_axis=Dict{String,String}(sel.label => String(width_axis_name(sel.axis)) for sel in selectors))

    return _produce_result(exp, Mse, s0, grids, np_per, Int(nval); dg)
end

"""
    lo_sensitivity_sweep(scenes, nval; spec, selectors = [:ig, :msac], kwargs...) -> NamedTuple

Sample-budget (validation-size) LO sensitivity sweep — thin wrapper over
`run_experiment(ValidationBudgetExperiment(selectors), …)`; the validation sizes
are the spec's budget sizes (rendered offline). Returns
`(; M, s0, grids, to_native_outlier_halfwidth, to_native_loss_width)` where
`M[label]` is the per-(pair,column) selection imc matrix (val+test,
scene-ordered), one per selector (`"IG  sel"`, `"MSAC sel"`, …).
"""
lo_sensitivity_sweep(scenes::AbstractVector, nval::Integer;
                     selectors::AbstractVector{Symbol}=[:ig, :msac], kwargs...) =
    run_experiment(ValidationBudgetExperiment(collect(Symbol, selectors)), scenes, nval; kwargs...)

"""
    miscalibration_sweep(scenes, nval, zetas; n=nothing, spec, kwargs...) -> NamedTuple

Controlled miscalibration experiment (accv §eq-29) — thin wrapper over
`run_experiment(MiscalibrationExperiment(zetas, n), …)`.  Holds TEST fixed and
scales the VALIDATION supplied scale ŝ by each corruption factor `ζ ∈ zetas`
(multiplying val σ̂² by ζ²) before tuning, then evaluates on the unscaled test
pool, at fixed val size `n` (default: the full val pool). The spec's coverage
windows must reach the ladder. Returns `(; zetas, s0, n)`.
"""
miscalibration_sweep(scenes::AbstractVector, nval::Integer,
                     zetas::AbstractVector{<:Real};
                     n::Union{Nothing,Integer}=nothing,
                     selectors::AbstractVector{Symbol}=[:ig, :msac], kwargs...) =
    run_experiment(MiscalibrationExperiment(collect(Float64, zetas),
                                            n === nothing ? nothing : Int(n),
                                            collect(Symbol, selectors)),
                   scenes, nval; kwargs...)

"""
    delta_sweep(scenes, nval, loss, Δs; include_baselines=true, NG=nothing, spec,
                kwargs...) -> NamedTuple

Well-depth (Δ) sweep on the streamed pool — thin wrapper over
`run_experiment(DeltaSweepExperiment(loss, Δs; …), …)`.  One Track-B
mixture-marginal selector per Δ on the shared outlier-half-width axis, with the
production IG/MSAC selectors as anchor curves when `include_baselines=true`.
Returns `(; M, Δs, outlier_halfwidth_grid, s0, to_native)`.
"""
delta_sweep(scenes::AbstractVector, nval::Integer, loss::AbstractLossShape,
            Δs::AbstractVector{<:Real};
            include_baselines::Bool=true, NG::Union{Nothing,Integer}=nothing, kwargs...) =
    run_experiment(DeltaSweepExperiment(loss, Δs; include_baselines, NG),
                   scenes, nval; kwargs...)
