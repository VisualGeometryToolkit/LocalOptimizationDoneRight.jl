# =============================================================================
# protocol_folds.jl — THE fold of the protocols of record into a cell's run
# key, consumed by the cell scripts AND by every downstream experiment that
# must RE-DERIVE a cell's key from its config name (the arms_from_cv
# discipline: keys are derived identically at both ends, never copied). Which
# cv_protocol section a cell folds is declared in ITS config
# (`[protocol] cv_section`), never in code.
#
# The tuning protocol (configs/tuning.toml) is folded the same way
# (`fold_sequential_cv!`): each tuning entry a cell's `[sequential_cv]` names
# is the protocol entry with its cross-validation section and the cell's own
# overrides layered by VisualGeometryEval's `layer_tuning`; `run_key`
# resolves it to its complete table — the registered scene lists included — so
# every tuning parameter keys the run.
# =============================================================================
if !@isdefined(ACCV2026_PROTOCOL_FOLDS_LOADED)

using DrWatson: projectdir   # configs/ of the active (accv2026) project
using TOML
using VisualGeometryCore: ScaleMultiple, OutlierHalfwidth, LossWidth, width_axis_name
using VisualGeometryEval.Tuning: layer_tuning, tuning_spec, TUNING_TAGS, CoarseFine
using VisualGeometryEval.Experiments:
    load_run_config, run_key, experiment_dir
include(joinpath(@__DIR__, "protocol.jl"))   # configs/protocol.toml: the arm protocol folded below

const _CVP_PATH    = projectdir("configs", "cv_protocol.toml")
const _MP_PATH     = projectdir("configs", "miscal_protocol.toml")
const _TUNING_PATH = projectdir("configs", "tuning.toml")

"The tuning protocol of record (configs/tuning.toml), parsed."
const TUNING_PROTOCOL = TOML.parsefile(_TUNING_PATH)

"""
    protocol_tuning(name; over = Dict()) -> Dict

The `[tuning.<name>]` entry of the tuning protocol of record, with the
protocol's paper-level type defaults (`[types.<type>]`) layered beneath it —
under every entry whose scheme holds a field of that name — and `over` (a
cell's overrides) layered above it, all by VisualGeometryEval's `layer_tuning`.
"""
function protocol_tuning(name::AbstractString; over::AbstractDict = Dict{String,Any}())
    entries = TUNING_PROTOCOL["tuning"]
    haskey(entries, name) ||
        throw(ArgumentError("configs/tuning.toml has no [tuning.$name] (has: $(sort(collect(keys(entries)))))"))
    entry = entries[name]
    T = TUNING_TAGS["scheme"][entry["type"]]
    types = Dict{String,Any}(k => v for (k, v) in get(TUNING_PROTOCOL, "types", Dict())
                             if Symbol(k) in fieldnames(T))
    return layer_tuning(layer_tuning(types, entry), over)
end

"""
    tuning_config(name; over = Dict()) -> Dict

A config holding only `[tuning.<name>]` = [`protocol_tuning`](@ref)`(name;
over)` — what a driver's `--config` reads.
"""
tuning_config(name::AbstractString; over::AbstractDict = Dict{String,Any}()) =
    Dict{String,Any}("tuning" => Dict{String,Any}(String(name) => protocol_tuning(name; over)))

"""
    protocol_cross_validation(name; over = Dict()) -> CrossValidation

The cross-validation of the effective `[tuning.<name>]` entry
([`tuning_config`](@ref)`(name; over)`): the scenes and units a stage of that
entry tunes on and reads out.
"""
protocol_cross_validation(name::AbstractString; over::AbstractDict = Dict{String,Any}()) =
    tuning_spec(tuning_config(name; over), name).scheme.cross_validation

"""
    cross_validation_section(section) -> Dict

The partial `cross_validation` table of a cv_protocol.toml section (the
registered scene split it names and its validation sampling), as the
`cross_validation` override of a tuning entry.
"""
function cross_validation_section(section::AbstractString)
    cvp = TOML.parsefile(_CVP_PATH)
    section != "protocol" && haskey(cvp, section) || error("cv_protocol.toml has no section [$section]")
    cvp["protocol"]["tune_zeta"] == 1.0 ||
        error("cv_protocol.toml: tuning is always at zeta = 1 (calibration); tune_zeta = $(cvp["protocol"]["tune_zeta"])")
    return Dict{String,Any}(cvp[section])
end

"`over` with the cross-validation of cv_protocol.toml section `section` layered beneath it."
cross_validation_over(section::AbstractString, over::AbstractDict = Dict{String,Any}()) =
    layer_tuning(Dict{String,Any}("cross_validation" => cross_validation_section(section)), over)

"""
    fold_arm_protocol!(cfg) -> cfg

Fold the arm protocol of record (configs/protocol.toml `[arms]`: the LO
iteration budget, the Lebeda ladder, every per-arm deviation) into `cfg` as
`arm_protocol`, so it keys the run: THE fold of every config whose run builds
arms from the arm table (the miscalibration and budget cells), applied at
both ends of every derived key.
"""
fold_arm_protocol!(cfg) = (cfg["arm_protocol"] = deepcopy(PROTOCOL["arms"]); cfg)

"""
    miscal_sidecar_of(config_name) -> path

Re-derive the named cell's operating-points sidecar EXACTLY as its script
does (load_run_config + fold_sequential_cv! + sequential_cv_dir) — the
arms_from_cv discipline: keys derived, never copied. THE one rule for every
sidecar of record (fig3's PT-E: registry.jl EXP_MISCAL_SIDECAR =
`miscal_sidecar_of("pt_e_miscal")`; fig2's basin: `miscal_sidecar_of("pt_e_basin")`).
"""
miscal_sidecar_of(config_name::AbstractString) =
    joinpath(sequential_cv_dir(fold_sequential_cv!(load_run_config(
        projectdir("configs", config_name * ".toml")))), SEQUENTIAL_CV_SIDECAR)

# --- the sequential CV (notes/sequential_cv.md) ----------------------------------

"The width kinds a refiner can be tuned on, each its own `[sequential_cv] refiner` entry."
const SEQUENTIAL_CV_KINDS = map(a -> String(width_axis_name(a)), (ScaleMultiple(), OutlierHalfwidth(), LossWidth()))
"The sequential CV's three artifacts, in stage order; the last is the cell's sidecar."
const SEQUENTIAL_CV_SCORER  = "scorer_cv.jld2"
const SEQUENTIAL_CV_REFINER = "refiner_cv.jld2"
const SEQUENTIAL_CV_SIDECAR = "operating_points.jld2"

"""
    fold_sequential_cv!(cfg) -> cfg

THE fold of the protocols of record into a tuning cell's run key: every
tuning entry the cell's `[sequential_cv]` names (the `scorer` — one entry, or one per
selector family — and each `refiner` kind) is
resolved from configs/tuning.toml with the cell's `[protocol] cv_section`
layered in as its cross-validation, so every stage tunes on the same pairs and
the evaluation reads the same test side; then miscal_protocol.toml (the ζ
ladder) and the arm protocol. All of it keys the run — the cell's own opt-in
variant declarations (`objective_matched`, `zero_clamp`; arm_rosters.jl)
included.
"""
function fold_sequential_cv!(cfg)
    haskey(cfg, "protocol") && haskey(cfg["protocol"], "cv_section") ||
        error("fold_sequential_cv!: the config declares no [protocol] cv_section")
    sq = cfg["sequential_cv"]
    known = ("roster", "scorer", "scorer_of", "refiner", "cache_validation", "decode_parallel", "plugin_scale", "prior",
             "objective_matched", "zero_clamp")
    bad = setdiff(keys(sq), known)
    isempty(bad) || error("[sequential_cv]: unknown key(s) $(sort!(collect(bad))) (known: $(known))")
    ref = sq["refiner"]
    issetequal(keys(ref), SEQUENTIAL_CV_KINDS) ||
        error("[sequential_cv] refiner: name an entry for exactly the kinds $(SEQUENTIAL_CV_KINDS), got $(sort!(collect(keys(ref))))")
    sc = sq["scorer"]
    scorers = sc isa AbstractString ? [String(sc)] : String.(collect(values(sc)))
    sec = String(cfg["protocol"]["cv_section"])
    cell = get(cfg, "tuning", Dict{String,Any}())
    cfg["tuning"] = Dict{String,Any}(
        n => protocol_tuning(n; over = cross_validation_over(sec, get(cell, n, Dict{String,Any}())))
        for n in unique(vcat(scorers, String.(collect(values(ref))),
                             # a cross-validated prior α₀ searches its own entry
                             haskey(get(sq, "prior", Dict()), "tuning") ? [String(sq["prior"]["tuning"])] : String[])))
    for n in keys(cfg["tuning"])
        TUNING_TAGS["scheme"][TUNING_PROTOCOL["tuning"][n]["type"]] == CoarseFine ||
            error("[sequential_cv]: [tuning.$n] is not a coarse_fine entry — the sequential CV is the single CV path")
    end
    cfg["miscal_protocol"] = Dict("protocol" => TOML.parsefile(_MP_PATH)["protocol"])
    # ONE scorer per (dataset, model class): `scorer_of` names the cell whose
    # scorer stage this cell READS instead of re-tuning it — the same pools,
    # problem, cross-validation and scorer entries, refused otherwise. That
    # cell's keyed directory keys this one, so a re-tuned scorer re-keys it.
    if haskey(sq, "scorer_of")
        name = String(sq["scorer_of"])
        src = fold_sequential_cv!(load_run_config(projectdir("configs", name * ".toml")))
        haskey(src["sequential_cv"], "scorer_of") &&
            error("[sequential_cv] scorer_of = \"$name\": that cell reads its scorer from another — name the one that tunes it")
        for k in ("dataset", "matcher", "problem", "pool_dir")
            src["experiment"][k] == cfg["experiment"][k] ||
                error("[sequential_cv] scorer_of = \"$name\": its [experiment] $k differs")
        end
        src["protocol"]["cv_section"] == cfg["protocol"]["cv_section"] ||
            error("[sequential_cv] scorer_of = \"$name\": its cv_section differs")
        # the scale prior is fitted by the scorer stage and drives every sweep
        get(src["sequential_cv"], "prior", nothing) == get(sq, "prior", nothing) ||
            error("[sequential_cv] scorer_of = \"$name\": its scale prior differs")
        for n in scorers
            haskey(src["tuning"], n) && src["tuning"][n] == cfg["tuning"][n] ||
                error("[sequential_cv] scorer_of = \"$name\": its [tuning.$n] differs or is absent")
        end
        cfg["scorer_of_run"] = run_key(src)
    end
    return fold_arm_protocol!(cfg)
end

"""
    operating_points_run(config_name) -> String

The run of the operating points a CONSUMER folds into its key (budget, e2e and
polish cells): the named sequential-CV cell's run key WITHOUT its opt-in
variant declarations (`objective_matched`, `zero_clamp`). A declared variant
moves no other arm's operating point or evaluation — an objective-matched one
is evaluation-only (never tuned); a zero-clamp one is tuned on its own, at the
selector's a* the scorer stage fixed before any refiner (the sequential CV
splices either in) — so a consumer that does not run it keeps its key; one
that does declares it itself, which re-keys it.
"""
function operating_points_run(config_name::AbstractString)
    cfg = fold_sequential_cv!(load_run_config(projectdir("configs", config_name * ".toml")))
    delete!(cfg["sequential_cv"], "objective_matched")
    delete!(cfg["sequential_cv"], "zero_clamp")
    return run_key(cfg)
end

"""
    fold_budget_cell!(cfg) -> cfg

THE fold of a sample-budget cell's protocols of record into its run key: the
configs/sample_budget_protocol.toml section the cell names in `[budget]
protocol` (its stream depth and checkpoint schedule), the arm protocol, and
the RUN of the operating points it evaluates — `[operating_points]
miscal_config` (that cell's run key, derived, never copied) or an explicit
`sidecar` path (its keyed directory's name). Folding the operating points in
is what makes a re-tune re-key the budget cell: without it the key is this
config's alone, and an existing scene file — which keeps every arm it already
holds — would silently carry curves computed at the PREVIOUS operating points.
"""
function fold_budget_cell!(cfg)
    haskey(cfg, "budget") && haskey(cfg["budget"], "protocol") && haskey(cfg["budget"], "selectors") ||
        error("fold_budget_cell!: the config declares no [budget] protocol (a " *
              "configs/sample_budget_protocol.toml section) and selectors")
    known = ("protocol", "selectors", "objective_matched", "zero_clamp")
    bad = setdiff(keys(cfg["budget"]), known)
    isempty(bad) || error("[budget]: unknown key(s) $(sort!(collect(bad))) (known: $(known))")
    name = String(cfg["budget"]["protocol"])
    sbp = TOML.parsefile(projectdir("configs", "sample_budget_protocol.toml"))
    haskey(sbp, name) || error("[budget] protocol = \"$name\": configs/sample_budget_protocol.toml has no such section")
    cfg["sample_budget_protocol"] = Dict(name => sbp[name])
    op = cfg["operating_points"]
    cfg["operating_points_run"] = haskey(op, "sidecar") ? basename(dirname(String(op["sidecar"]))) :
        operating_points_run(String(op["miscal_config"]))
    return fold_arm_protocol!(cfg)
end

"""
    budget_cell_dir(cfg) -> String

The keyed directory of a folded budget cell:
`<results>/<dataset>/<matcher>/<problem>/SampleBudget/budget-<run_key>`.
"""
budget_cell_dir(cfg) = joinpath(experiment_dir(cfg), "SampleBudget",
                                "budget-" * run_key(cfg))

"The operating-points sidecar a folded budget cell evaluates: its explicit path, or its miscal cell's."
budget_sidecar(cfg) = haskey(cfg["operating_points"], "sidecar") ? String(cfg["operating_points"]["sidecar"]) :
                      miscal_sidecar_of(String(cfg["operating_points"]["miscal_config"]))

"""
    fold_e2e_cell!(cfg) -> cfg

The fold of an end-to-end RANSAC cell (configs/pt_e_e2e_table.toml;
src/e2e_cells.jl): the run of the operating points it deploys
(`[operating_points] miscal_config`, that cell's run key — a re-tune re-keys
the cell) and its `[e2e]` table:

- `arms`: the deployed arms run end to end (sidecar names, e.g. "IG  +Lift");
- `test = "operating_points"`: the operating points' OWN cross-validation test
  side, every unit it keeps (no validation side: scorer and refiners are
  already cross-validated); the ζ ladder and the per-pair streams are the cell's `zetas` /
  `seed` and `stream` (pair i of a scene draws from `stable_seed(seed, stream, scene, i)`);
- `ransac` (optional): our loop's termination {min_trials, max_trials,
  success_prob} — absent: the production defaults;
- `superansac` (optional): the SupeRANSAC cell (configs/<name>.toml,
  scripts/superansac_e2e.jl) whose results the summary sets beside ours.
"""
function fold_e2e_cell!(cfg)
    e = cfg["e2e"]
    test = get(e, "test", "")
    test == "operating_points" ||
        error("[e2e] test: expected \"operating_points\", got $(repr(test))")
    known = ("arms", "test", "zetas", "seed", "stream", "ransac", "superansac")
    required = ("arms", "test", "zetas", "seed", "stream")
    all(k -> haskey(e, k), required) && all(k -> k in known, keys(e)) ||
        error("[e2e]: keys $(sort!(collect(keys(e)))) — required $(required), allowed $(known)")
    e["arms"] isa AbstractVector && !isempty(e["arms"]) || error("[e2e] arms: a non-empty list of deployed arm names")
    cfg["operating_points_run"] = operating_points_run(String(cfg["operating_points"]["miscal_config"]))
    return fold_arm_protocol!(cfg)
end

"""
    e2e_cell_dir(cfg) -> String

The keyed directory of a folded end-to-end cell:
`<results>/<dataset>/<matcher>/<problem>/EndToEnd/e2e-<run_key>`.
"""
e2e_cell_dir(cfg) = joinpath(experiment_dir(cfg), "EndToEnd", "e2e-" * run_key(cfg))

"""
    sequential_cv_scorer_path(cfg) -> String

Where a folded cell's scorer artifact lives: its own keyed directory, or — for
a `scorer_of` cell — the keyed directory of the cell it reads it from.
"""
function sequential_cv_scorer_path(cfg)
    sq = cfg["sequential_cv"]
    haskey(sq, "scorer_of") || return joinpath(sequential_cv_dir(cfg), SEQUENTIAL_CV_SCORER)
    src = dirname(miscal_sidecar_of(String(sq["scorer_of"])))
    basename(src) == "sequential-cv-" * cfg["scorer_of_run"] ||
        error("scorer_of = $(sq["scorer_of"]): its keyed directory $(basename(src)) is not the run this " *
              "config was folded against ($(cfg["scorer_of_run"])) — re-fold")
    return joinpath(src, SEQUENTIAL_CV_SCORER)
end

"""
    sequential_cv_scorer_entry(sq, selector::Symbol) -> String

The configs/tuning.toml entry selector family `selector` is tuned on:
`[sequential_cv] scorer` names ONE entry for every selector the roster uses,
or a table `{ ig = "...", msac = "..." }` naming each.
"""
function sequential_cv_scorer_entry(sq::AbstractDict, selector::Symbol)
    sc = sq["scorer"]
    sc isa AbstractString && return String(sc)
    haskey(sc, String(selector)) ||
        error("[sequential_cv] scorer: no entry for selector :$selector (has: $(sort!(collect(keys(sc)))))")
    return String(sc[String(selector)])
end

"""
    sequential_cv_dir(cfg) -> String

The keyed directory of a folded sequential-CV cell: `<results>/<dataset>/<matcher>/<problem>/
<Miscalibration | Basin>/sequential-cv-<run_key>` — `Basin` for the
`roster = "basin"` cells. Every stage's artifact lives here, so a change to
any entry, the cv section, the ζ ladder or the arm protocol re-keys all three
stages together.
"""
sequential_cv_dir(cfg) =
    joinpath(experiment_dir(cfg),
             get(cfg["sequential_cv"], "roster", "composed") == "basin" ? "Basin" : "Miscalibration",
             "sequential-cv-" * run_key(cfg))

const ACCV2026_PROTOCOL_FOLDS_LOADED = true
end # include guard
