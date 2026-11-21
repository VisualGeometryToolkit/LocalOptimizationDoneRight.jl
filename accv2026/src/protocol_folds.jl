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
# overrides layered by VisualGeometryToolkitEval's `layer_tuning`; `run_key`
# resolves it to its complete table — the registered scene lists included — so
# every tuning parameter keys the run.
# =============================================================================
if !@isdefined(ACCV2026_PROTOCOL_FOLDS_LOADED)

using DrWatson: projectdir   # configs/ of the active (accv2026) project
using TOML
using VisualGeometryToolkitCore: EfficiencyConstant, OutlierHalfwidth, LossWidth, width_axis_name, check_keys
using VisualGeometryToolkitEval.Tuning: layer_tuning, layered_tuning_entry, tuning_spec, TUNING_TAGS, CoarseFine, tuning_hash
using VisualGeometryToolkitEval.Experiments:
    load_run_config, run_key,
    config_of_record,                   # configs/<name>.toml as a run config
    Product, product_dir, product_output,   # a cell's keyed product: <results>/<dataset>/<matcher>/<problem>/<experiment>/<kind>/<key>
    tier_path, input_path               # a path under an input's tier root; an input opened, checked to be there
include(joinpath(@__DIR__, "protocol.jl"))   # configs/protocol.toml: the arm protocol folded below

const _CVP_PATH    = projectdir("configs", "cv_protocol.toml")
const _MP_PATH     = projectdir("configs", "miscal_protocol.toml")
const _TUNING_PATH = projectdir("configs", "tuning.toml")

"The scale interface the consensus-anchoring ablation evaluates (configs/miscal_protocol.toml [anchoring_ablation])."
const EXP_ANCHOR_SCALE_INTERFACE = String(TOML.parsefile(_MP_PATH)["anchoring_ablation"]["scale_interface"])

"""
    anchoring_ablation_path(dir) -> String

The consensus-anchoring ablation's ζ evaluation inside the keyed sequential-CV
directory `dir`: `<dir>/anchoring_ablation-<EXP_ANCHOR_SCALE_INTERFACE>/zeta_evaluation.jld2`,
named by the scale interface it evaluates (a change of it is a new artifact). The
one path rule: the writer (run_sequential_cv.jl `--stage=anchoring`) and the
reader (registry.jl `EXP_ANCHOR_WITHOUT`) both call it.
"""
anchoring_ablation_path(dir::AbstractString) =
    joinpath(dir, "anchoring_ablation-" * EXP_ANCHOR_SCALE_INTERFACE, "zeta_evaluation.jld2")

"The tuning protocol of record (configs/tuning.toml), parsed."
const TUNING_PROTOCOL = TOML.parsefile(_TUNING_PATH)

"""
    protocol_tuning(name; over = Dict()) -> Dict

The `[tuning.<name>]` entry of the tuning protocol of record, with the
protocol's paper-level type defaults (`[types.<type>]`) layered beneath it —
under every entry whose scheme holds a TOML key of that name — and `over` (a
cell's overrides) layered above it: VisualGeometryToolkitEval's
`layered_tuning_entry`.
"""
protocol_tuning(name::AbstractString; over::AbstractDict = Dict{String,Any}()) =
    layered_tuning_entry(TUNING_PROTOCOL, name; under = get(TUNING_PROTOCOL, "types", Dict{String,Any}()), over)

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
    cell_product(cfg, experiment, kind; output) -> Product

THE keyed product of a folded cell (VisualGeometryToolkitEval's `Product`): its directory is
`<results>/<dataset>/<matcher>/<problem>/<experiment>/<kind>/<key>` (`product_dir`), keyed by
the folded config, the products it reads ([`upstream_products`](@ref)) and the code it runs;
`output` is the file the cell writes last (its completion mark with the records). Every
`*_product` below is this rule applied to one kind of cell, at both ends of every derived key.
"""
function cell_product(cfg::AbstractDict, experiment::AbstractString, kind::AbstractString; output::AbstractString)
    e = cfg["experiment"]
    return Product(join((e["dataset"], e["matcher"], e["problem"], experiment), "/"), kind, cfg;
                   output, upstream = upstream_products(cfg))
end

"""
    miscal_sidecar_of(config_name) -> path

Re-derive the named cell's operating-points sidecar EXACTLY as its script
does (config_of_record + fold_sequential_cv! + sequential_cv_dir) — the
arms_from_cv discipline: keys derived, never copied. THE one rule for every
sidecar of record (fig3's PT-E: registry.jl EXP_MISCAL_SIDECAR =
`miscal_sidecar_of("pt_e_miscal")`; fig2's basin: `miscal_sidecar_of("pt_e_basin")`).
"""
miscal_sidecar_of(config_name::AbstractString) =
    product_output(sequential_cv_product(fold_sequential_cv!(config_of_record(config_name))))

# --- the sequential CV (notes/sequential_cv.md) ----------------------------------

"The width kinds a refiner can be tuned on, each its own `[sequential_cv] refiner` entry."
const SEQUENTIAL_CV_KINDS = map(a -> String(width_axis_name(a)), (EfficiencyConstant(), OutlierHalfwidth(), LossWidth()))
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
    check_keys(sq, ("roster", "scorer", "scorer_of", "refiner", "cache_validation", "decode_parallel", "plugin_scale",
                    "prior", "objective_matched", "zero_clamp"), "sequential_cv")
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
    # cell's run keys this one as an UPSTREAM run (`upstream_products`,
    # Eval's `run_key(; upstream)`), so a re-tuned scorer re-keys it.
    if haskey(sq, "scorer_of")
        name = String(sq["scorer_of"])
        src = fold_sequential_cv!(config_of_record(name))
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
    end
    return fold_arm_protocol!(cfg)
end

"""
    operating_points_run(config_name) -> String

The run of the operating points a CONSUMER folds into its key (budget, e2e and
polish cells): the key of the named sequential-CV cell's product WITHOUT its opt-in
variant declarations (`objective_matched`, `zero_clamp`). A declared variant
moves no other arm's operating point or evaluation — an objective-matched one
is evaluation-only (never tuned); a zero-clamp one is tuned on its own, at the
selector's a* the scorer stage fixed before any refiner (the sequential CV
splices either in) — so a consumer that does not run it keeps its key; one
that does declares it itself, which re-keys it.
"""
function operating_points_run(config_name::AbstractString)
    cfg = fold_sequential_cv!(config_of_record(config_name))
    delete!(cfg["sequential_cv"], "objective_matched")
    delete!(cfg["sequential_cv"], "zero_clamp")
    return sequential_cv_product(cfg).key
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
    check_keys(cfg["budget"], ("protocol", "selectors", "objective_matched", "zero_clamp"), "budget")
    name = String(cfg["budget"]["protocol"])
    sbp = TOML.parsefile(projectdir("configs", "sample_budget_protocol.toml"))
    haskey(sbp, name) || error("[budget] protocol = \"$name\": configs/sample_budget_protocol.toml has no such section")
    cfg["sample_budget_protocol"] = Dict(name => sbp[name])
    return fold_arm_protocol!(cfg)
end

"The completion mark of a budget cell: the scene files and arms it holds, written last."
const BUDGET_MANIFEST = "scenes.toml"

"""
    budget_product(cfg) -> Product

The keyed product of a folded budget cell:
`<results>/<dataset>/<matcher>/<problem>/SampleBudget/budget/<key>`, one `<scene>.jld2` per
test scene and [`BUDGET_MANIFEST`](@ref) written last.
"""
budget_product(cfg) = cell_product(cfg, "SampleBudget", "budget"; output = BUDGET_MANIFEST)
budget_cell_dir(cfg) = product_dir(budget_product(cfg))

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
    check_keys(e, ("arms", "test", "zetas", "seed", "stream", "ransac", "superansac"), "e2e")
    required = ("arms", "test", "zetas", "seed", "stream")
    all(k -> haskey(e, k), required) ||
        error("[e2e]: keys $(sort!(collect(keys(e)))) — required $(required)")
    e["arms"] isa AbstractVector && !isempty(e["arms"]) || error("[e2e] arms: a non-empty list of deployed arm names")
    return fold_arm_protocol!(cfg)
end

"""
    e2e_product(cfg) -> Product

The keyed product of a folded end-to-end cell:
`<results>/<dataset>/<matcher>/<problem>/EndToEnd/e2e/<key>`, its live runs (`live.jld2`) and
their scene-averaged summary (`summary.tsv`, written last).
"""
e2e_product(cfg) = cell_product(cfg, "EndToEnd", "e2e"; output = "summary.tsv")
e2e_cell_dir(cfg) = product_dir(e2e_product(cfg))

"""
    sequential_cv_scorer_path(cfg) -> String

Where a folded cell's scorer artifact lives: its own keyed directory, or — for
a `scorer_of` cell — the keyed directory of the cell it reads it from.
"""
function sequential_cv_scorer_path(cfg)
    sq = cfg["sequential_cv"]
    haskey(sq, "scorer_of") || return joinpath(sequential_cv_dir(cfg), SEQUENTIAL_CV_SCORER)
    return joinpath(dirname(miscal_sidecar_of(String(sq["scorer_of"]))), SEQUENTIAL_CV_SCORER)
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
    sequential_cv_product(cfg) -> Product

The keyed product of a folded sequential-CV cell: `<results>/<dataset>/<matcher>/<problem>/
<Miscalibration | Basin>/sequential-cv/<key>` — `Basin` for the `roster = "basin"` cells — whose
output is the operating-points sidecar. Every stage's artifact lives in its directory
(`sequential_cv_dir`), so a change to any entry, the cv section, the ζ ladder or the arm protocol
re-keys all three stages together.
"""
sequential_cv_product(cfg) =
    cell_product(cfg, get(cfg["sequential_cv"], "roster", "composed") == "basin" ? "Basin" : "Miscalibration",
                 "sequential-cv"; output = SEQUENTIAL_CV_SIDECAR)
sequential_cv_dir(cfg) = product_dir(sequential_cv_product(cfg))

"""
    upstream_products(cfg) -> Union{Nothing, Dict{String,Any}}

The products a folded cell READS, by name, as Eval's `Product(…; upstream)` keys
them — so a re-tune upstream re-keys every cell that reads it, and no key is
held as a config value:

- `scorer_of`: a `[sequential_cv] scorer_of` cell's scorer cell (its product: its key and,
  once produced, its output's hash);
- `operating_points`: the operating points a consumer evaluates (`[operating_points]
  miscal_config`: that cell's key without its opt-in variants, [`operating_points_run`](@ref);
  an explicit `sidecar`: its keyed directory's name);
- `e2e`, `superansac`: a timing cell's timed e2e cell and that cell's SupeRANSAC
  cell (their products; src/e2e_timing.jl).

`nothing` for a cell that reads none.
"""
function upstream_products(cfg)
    up = Dict{String,Any}()
    sq = get(cfg, "sequential_cv", Dict{String,Any}())
    haskey(sq, "scorer_of") &&
        (up["scorer_of"] = sequential_cv_product(fold_sequential_cv!(config_of_record(String(sq["scorer_of"])))))
    op = get(cfg, "operating_points", nothing)
    op === nothing || (up["operating_points"] = haskey(op, "sidecar") ? basename(dirname(String(op["sidecar"]))) :
                                                operating_points_run(String(op["miscal_config"])))
    if haskey(get(cfg, "timing", Dict{String,Any}()), "e2e_config")
        up["e2e"] = e2e_product(e2e_timed_cell(cfg))
        up["superansac"] = superansac_product(e2e_timed_superansac(cfg))
    end
    return isempty(up) ? nothing : up
end

"""
    fold_sensitivity_cell!(cfg) -> cfg

The fold of a selection-only sensitivity cell (`[sensitivity]`: Fig 1's
configs/pt_e_sel_miscal.toml; scripts/tools/run_lo_sensitivity.jl) into its run
key: the hash of the configs/tuning.toml entry it tunes on (`[sensitivity]
tuning`) and, for `mode = "miscal"`, the ζ ladder of configs/miscal_protocol.toml.
"""
function fold_sensitivity_cell!(cfg)
    s = cfg["sensitivity"]
    check_keys(s, ("mode", "tuning", "selectors", "n_miscal", "deltas", "loss"), "sensitivity")
    mode = String(s["mode"])
    mode in ("miscal", "delta", "validation_budget") ||
        error("[sensitivity] mode = $(repr(mode)): expected miscal, delta or validation_budget")
    cfg["tuning_spec_hash"] = tuning_hash(tuning_spec(tuning_config(String(s["tuning"])), String(s["tuning"])))
    mode == "miscal" && (cfg["miscal_protocol"] = TOML.parsefile(_MP_PATH)["protocol"])
    return cfg
end

"""
    sensitivity_product(cfg) -> Product

The keyed product of a folded sensitivity cell:
`<results>/<dataset>/<matcher>/<problem>/<Miscalibration | DeltaSweep | LOSensitivity>/sel-<mode>/<key>`,
its output `bundle.jld2`.
"""
function sensitivity_product(cfg)
    mode = String(cfg["sensitivity"]["mode"])
    experiment = mode == "miscal" ? "Miscalibration" : mode == "delta" ? "DeltaSweep" : "LOSensitivity"
    return cell_product(cfg, experiment, "sel-" * replace(mode, "_" => "-"); output = "bundle.jld2")
end
sensitivity_cell_dir(cfg) = product_dir(sensitivity_product(cfg))

"""
    ladder_cell(config_name) -> Dict

Fig 2's δ-perturbed ladder (scripts/tools/run_basin_ladder.jl) as a run
config: the basin cell `config_name`'s `[experiment]` (its pool), the RUN of
its operating points (that cell's run key — a re-tune re-keys the ladder) and
the ladder protocol of record, configs/protocol.toml `[basin_ladder]`. Its
keyed directory is [`ladder_cell_dir`](@ref).
"""
ladder_cell(config_name::AbstractString) = Dict{String,Any}(
    "experiment" => config_of_record(config_name)["experiment"],
    "inputs" => Dict{String,Any}("pool" => config_of_record(config_name)["inputs"]["pool"]),
    "operating_points" => Dict{String,Any}("miscal_config" => String(config_name)),
    "basin_ladder" => protocol_table("basin_ladder"))

"""
    ladder_product(cfg) -> Product

The keyed product of a ladder cell: `<results>/<dataset>/<matcher>/<problem>/BasinLadder/basin-ladder/<key>`,
its output `ladder.jld2`.
"""
ladder_product(cfg) = cell_product(cfg, "BasinLadder", "basin-ladder"; output = "ladder.jld2")
ladder_cell_dir(cfg) = product_dir(ladder_product(cfg))

# ---- the scoring pool a cell reads ----------------------------------------------------

# A cell's pool is its `[inputs.pool]`; its `[experiment] pool_dir` (the layout key Eval
# requires) must name the same tree.
function _pool_spec(cfg)
    t = get(get(cfg, "inputs", Dict{String,Any}()), "pool", nothing)
    t isa AbstractDict || error("config of record: [experiment] pool_dir = $(cfg["experiment"]["pool_dir"]) but no [inputs.pool]")
    t["path"] == cfg["experiment"]["pool_dir"] ||
        error("config of record: [inputs.pool] path = $(t["path"]) is not [experiment] pool_dir = $(cfg["experiment"]["pool_dir"])")
    return t
end

"""
    pool_input(cfg) -> String

The scoring pool cell `cfg` reads, opened through Eval's `input_path`: its
`[inputs.pool]` under that input's tier root, checked to be there. The one way a
driver reaches its pool.
"""
pool_input(cfg) = (_pool_spec(cfg); input_path(cfg, "pool"))

"""
    pool_path(cfg) -> String

Where cell `cfg`'s pool is (its `[inputs.pool]` under its tier root), unchecked: the
pool's identity in a record (an oracle floor's source), the same path
[`pool_input`](@ref) opens.
"""
pool_path(cfg) = (t = _pool_spec(cfg); tier_path(String(get(t, "tier", "")), t["path"]))

"""
    polish_product(cfg) -> Product

The keyed product of the folded polishing cell: `<results>/<dataset>/<matcher>/<problem>/Polish/polish/<key>`:
every polish on the test side (`polish_test.jld2`) and its before/after summary (`summary.tsv`, written last).
"""
polish_product(cfg) = cell_product(cfg, "Polish", "polish"; output = "summary.tsv")
polish_cell_dir(cfg) = product_dir(polish_product(cfg))

"""
    fold_timing_cell!(cfg) -> cfg

The fold of the timing cell (configs/timing_table.toml, scripts/timing_table.jl)
into its run key: the configs/sample_budget_protocol.toml section it runs under
(`[timing] sb_protocol`) and the RUN of the operating points it times
(`[operating_points] miscal_config`, that cell's run key — a re-tune re-keys
the timings).
"""
function fold_timing_cell!(cfg)
    name = String(cfg["timing"]["sb_protocol"])
    sbp = TOML.parsefile(projectdir("configs", "sample_budget_protocol.toml"))
    haskey(sbp, name) || error("[timing] sb_protocol = \"$name\": configs/sample_budget_protocol.toml has no such section")
    cfg["sample_budget_protocol"] = Dict(name => sbp[name])
    return cfg
end

"""
    timing_product(cfg) -> Product

The keyed product of the folded timing cell: `<results>/<dataset>/<matcher>/<problem>/Timing/timing/<key>`,
its output the timings file `lo_timing_<tag>_<scene>.jld2` of its `[timing]`.
"""
timing_product(cfg) = (t = cfg["timing"]; cell_product(cfg, "Timing", "timing"; output = "lo_timing_$(t["tag"])_$(t["scene"]).jld2"))
timing_cell_dir(cfg) = product_dir(timing_product(cfg))

const ACCV2026_PROTOCOL_FOLDS_LOADED = true
end # include guard
