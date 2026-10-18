# =============================================================================
# src/paper_numbers.jl — the numbers the papers typeset, computed from the
# results of record (configs/paper_numbers.toml; scripts/paper_numbers.jl
# writes them as paper/figures/paper_numbers.tex, THE one generated macro file).
#
# Every source is re-derived from the CONFIG of the cell that produced it (its
# keyed directory, never a copied path), and every statistic is the one the
# figure or table drawing it uses: the ζ evaluation's `evaluation_curve`
# (eligible mAA, finite median), the ladder's eligible mAA on the refinable
# seeds, the budget cell's `budget_curves`, the polishing and end-to-end
# cells' summary.tsv, the selection-only sweep's summary.jld2.
# =============================================================================
import VisualGeometryToolkitEval as VgtkEval
if !@isdefined(ACCV2026_PAPER_NUMBERS_LOADED)

using JLD2, TOML, Printf, Statistics
using VisualGeometryToolkitEval.Render: evaluation_curve, budget_curves
import VisualGeometryToolkitEval
# The figures' statistics (qualified: the prelude binds neither name).
const _eligible_maa = VgtkEval.Stats.eligible_maa
const _finite_median = VgtkEval.Stats.finite_median
using VisualGeometryToolkitEval.Tuning: tuning_spec, tuning_table, validation_scenes, test_scenes, load_tuning_artifact
# Included after cell_stages.jl and e2e_cells.jl (the folds, the registry, the arm tables).
include(joinpath(@__DIR__, "e2e_timing.jl"))   # the timing cell (kind "e2e_timing")

const PAPER_NUMBERS_PATH = joinpath(@__DIR__, "..", "configs", "paper_numbers.toml")
const PAPER_NUMBERS_TEX = "paper_numbers.tex"

_cfg_path(name) = joinpath(@__DIR__, "..", "configs", String(name) * ".toml")

# ---- the HEB statistics cell (scripts/heb_inlier_stats.jl) ---------------------------
"""
    heb_counts_cell(cfg) -> (; key, outdir, counts, cv, source)

The keyed per-pair counts of a HEB statistics config (configs/heb_stats.toml):
keyed by what they are a function of — the pools and the TEST side of the
source cell's cross-validation (its scenes and sampling).
"""
function heb_counts_cell(cfg::AbstractDict)
    src_name = String(cfg["source"]["miscal_config"])
    src = fold_sequential_cv!(load_run_config(_cfg_path(src_name)))
    for k in ("dataset", "matcher", "problem", "pool_dir")
        src["experiment"][k] == cfg["experiment"][k] || error("heb_stats: [experiment] $k differs from $(src_name)'s")
    end
    cv = tuning_spec(src, sequential_cv_scorer_entry(src["sequential_cv"], :ig)).scheme.cross_validation
    keyed = Dict{String,Any}("experiment" => cfg["experiment"],
        "test_side" => Dict{String,Any}("scenes" => test_scenes(cv), "sampling" => tuning_table(cv)["test"]))
    key = run_key(keyed)
    outdir = joinpath(experiment_dir(cfg), "DatasetStats", "heb-stats-" * key)
    return (; key, keyed, outdir, counts = joinpath(outdir, "counts.jld2"), cv, source = src_name)
end

"""
THE HEB statistics, by name, of the per-pair counts `n` (correspondences) and
`k` (GT inliers): their medians, the median GT inlier ratio and the fraction of
pairs whose ratio is below `low`.
"""
const HEB_STATISTICS = Dict{String,Function}(
    "correspondences_median"    => (n, k, low) -> median(n),
    "inliers_median"            => (n, k, low) -> median(k),
    "inlier_ratio_median"       => (n, k, low) -> median(k ./ n),
    "low_inlier_ratio_fraction" => (n, k, low) -> mean(k ./ n .< low),
)

# ---- sources ----------------------------------------------------------------------------
abstract type NumberSource end

"A sequential-CV cell's ζ evaluation and its oracle tag."
struct MiscalSource <: NumberSource
    path::String
    d::Any
    oracle::String
end
struct BasinSource <: NumberSource
    path::String
    d::Dict{String,Any}
end
struct BudgetSource <: NumberSource
    dir::String
    curves::Any
end
struct AnchoringSource <: NumberSource
    with::String
    without::String
    dwith::Any
    dwithout::Any
    pairs::Vector{String}
end
"A summary.tsv (polishing, end to end): its rows as column => value dicts."
struct TableSource <: NumberSource
    path::String
    rows::Vector{Dict{String,String}}
end
"""
The end-to-end timing cell: its summary (timing.tsv, the time row) and the two
protocol facts the caption states, each read from its record: the drawn pairs per
scene (the cell's `sample.toml`) and the timed repeats (the folded config's
`[timing] repeats`).
"""
struct TimingSource <: NumberSource
    table::TableSource
    sample::String
    pairs_per_scene::Dict{String,Int}
    repeats::Int
end
"The polishing run (polish_test.jld2): per source, the LO output's and each polish's per-pair errors."
struct PolishSource <: NumberSource
    path::String
    d::Dict{String,Any}
end
struct SelectionSource <: NumberSource
    path::String
    df::Any
end
struct HebStatsSource <: NumberSource
    path::String
    n::Vector{Int}
    k::Vector{Int}
    low::Float64
end
struct SplitSource <: NumberSource
    config::String
    scenes::Dict{String,Vector{String}}
    pairs::Dict{String,Int}
end

function _read_tsv(path)
    lines = filter(l -> !isempty(strip(l)) && !startswith(l, "#"), readlines(path))
    hdr = split(lines[1], '\t')
    return [Dict(String(h) => String(v) for (h, v) in zip(hdr, split(l, '\t'))) for l in lines[2:end]]
end

# The pairs of one scene of a pool tree: a ScoringPool's `scene_names` holds one
# label per pair (VisualGeometryToolkitEval Pools, `length(scene_names) == length(pairs)`),
# read without the pairs themselves.
_pool_pair_count(pool_dir, scene) = jldopen(f -> length(f["scene_names"]), joinpath(pool_dir, scene * ".jld2"))

"""
    number_source_input(name, spec) -> String

The result of record `[sources.<name>]` reads — the file (or, for a budget
cell, the keyed directory) re-derived from the producing cell's config, never
copied. For a split, the cell's own keyed sequential-CV directory (its
cross-validation is part of that key). Cheap: nothing is loaded.
"""
function number_source_input(name, spec::AbstractDict)
    kind, cfg_name = spec["kind"], get(spec, "config", "")
    kind == "miscal" && return miscal_sidecar_of(cfg_name)
    kind == "split" && return dirname(miscal_sidecar_of(cfg_name))
    if kind == "basin"
        cfg_name == "pt_e_basin" || error("[sources.$name]: the basin ladder of record is pt_e_basin's")
        return EXP_LADDER_BUNDLE
    elseif kind == "anchoring"
        cfg_name == "pt_e_miscal" || error("[sources.$name]: the anchoring ablation of record is pt_e_miscal's")
        return EXP_ANCHOR_WITHOUT
    elseif kind == "budget"
        return budget_cell_dir(fold_budget_cell!(load_run_config(_cfg_path(cfg_name))))
    elseif kind == "polish"
        cfg = load_run_config(_cfg_path(cfg_name))
        cfg["operating_points_run"] = operating_points_run(String(cfg["operating_points"]["miscal_config"]))
        return joinpath(experiment_dir(cfg), "Polish", "polish-" * run_key(cfg), "polish_test.jld2")
    elseif kind == "e2e"
        return joinpath(e2e_cell_dir(fold_e2e_cell!(load_run_config(_cfg_path(cfg_name)))), "summary.tsv")
    elseif kind == "e2e_timing"
        return timing_summary_path(e2e_timing_dir(e2e_timing_cell(cfg_name)))
    elseif kind == "selection"
        return joinpath(dirname(EXP_SEL_MISCAL_BUNDLE), "summary.jld2")
    elseif kind == "heb_stats"
        return heb_counts_cell(load_run_config(_cfg_path(cfg_name))).counts
    end
    error("[sources.$name]: unknown kind $(repr(kind))")
end

"""
    load_number_source(name, spec) -> NumberSource

The result of record `spec` names (configs/paper_numbers.toml `[sources.<name>]`),
read from [`number_source_input`](@ref).
"""
function load_number_source(name, spec::AbstractDict)
    kind, cfg_name = spec["kind"], get(spec, "config", "")
    path = number_source_input(name, spec)
    need(what, provenance) = require_input(path; what, provenance)
    if kind == "miscal"
        need("operating points of $(cfg_name)", "the cell's sequential CV")
        return MiscalSource(path, load_tuning_artifact(path), String(spec["oracle"]))
    elseif kind == "basin"
        need("basin ladder", "scripts/fig2_basin.jl ladder_test")
        return BasinSource(path, JLD2.load(path))
    elseif kind == "budget"
        cfg = fold_budget_cell!(load_run_config(_cfg_path(cfg_name)))
        files = [joinpath(path, "$s.jld2") for s in test_scenes(sidecar_cross_validation(budget_sidecar(cfg)))]
        foreach(f -> require_input(f; what = "budget curves", provenance = "the budget cell of $(cfg_name)"), files)
        return BudgetSource(path, budget_curves(files; arms = collect(String, JLD2.load(files[1], "arms"))))
    elseif kind == "anchoring"
        need("anchoring ablation", "scripts/fig_anchoring.jl evaluation")
        return AnchoringSource(EXP_ANCHOR_WITH, path, load_tuning_artifact(EXP_ANCHOR_WITH),
                               load_tuning_artifact(path), String.(spec["pairs"]))
    elseif kind == "polish"
        need("polishing run", "scripts/polish.jl test")
        return PolishSource(path, JLD2.load(path))
    elseif kind == "e2e"
        need("end-to-end summary", "scripts/e2e_ransac.jl summary")
        return TableSource(path, _read_tsv(path))
    elseif kind == "e2e_timing"
        need("end-to-end time row", "scripts/e2e_timing.jl summary")
        dir = dirname(path)
        require_input(timing_sample_path(dir); what = "timing sample", provenance = "scripts/e2e_timing.jl inputs")
        scenes, drawn = read_timing_sample(dir)
        return TimingSource(TableSource(path, _read_tsv(path)), timing_sample_path(dir),
                            Dict(s => length(drawn[s]) for s in scenes),
                            Int(e2e_timing_cell(cfg_name)["timing"]["repeats"]))
    elseif kind == "selection"
        need("selection-only summary", "scripts/fig1_sel_miscal.jl render")
        return SelectionSource(path, JLD2.load(path, "summary"))
    elseif kind == "heb_stats"
        need("HEB per-pair counts", "scripts/heb_inlier_stats.jl counts")
        d = JLD2.load(path)
        all(>(0), d["n_cs"]) || error("$(path): a pair without correspondences")
        return HebStatsSource(path, d["n_cs"], d["n_inl"], Float64(spec["low_inlier_ratio"]))
    elseif kind == "split"
        cfg = fold_sequential_cv!(load_run_config(_cfg_path(cfg_name)))
        cv = tuning_spec(cfg, sequential_cv_scorer_entry(cfg["sequential_cv"], :ig)).scheme.cross_validation
        pool_dir = joinpath(data_root(), cfg["experiment"]["pool_dir"])
        sc = Dict("validation" => validation_scenes(cv), "test" => test_scenes(cv))
        return SplitSource(String(cfg_name), sc, Dict(k => sum(s -> _pool_pair_count(pool_dir, s), v) for (k, v) in sc))
    end
    error("[sources.$name]: unknown kind $(repr(kind))")
end

# ---- arms -------------------------------------------------------------------------------
_arm_token(a) = a == "@welsch_hq" ? [PAPER_WELSCH_HQ] : a == "@main" ? copy(MAIN_ARMS) : [String(a)]
"The arms a macro names (its `arms`, tokens expanded, minus its `exclude`)."
macro_arms(m) = setdiff(unique(reduce(vcat, _arm_token.(get(m, "arms", String[])); init = String[])),
                        reduce(vcat, _arm_token.(get(m, "exclude", String[])); init = String[]))

_index(xs, x; what, rtol = 1e-6) = (i = findfirst(v -> isapprox(v, x; rtol), xs);
                       i === nothing ? error("$what $x is not on the grid $xs") : i)

function _reduce(op, vals::AbstractVector{<:Real}; what)
    isempty(vals) && error("$what: no values")
    all(isfinite, vals) || error("$what: a non-finite value in $vals")
    op == "value"  && (length(vals) == 1 || error("$what: op value takes one arm, got $(length(vals))"); return vals[1])
    op == "min"    && return minimum(vals)
    op == "max"    && return maximum(vals)
    op == "spread" && return maximum(vals) - minimum(vals)
    op == "range"  && return (minimum(vals), maximum(vals))
    error("$what: op $(repr(op)) does not apply")
end

# ---- the value of one macro, by source --------------------------------------------------
function number_value(s::MiscalSource, m, floors)
    ro = s.d["evaluation"]
    j = _index(Float64.(s.d["zetas"]), Float64(m["zeta"]); what = "ζ")
    arms = macro_arms(m)
    missing_arms = setdiff(arms, collect(keys(ro)))
    isempty(missing_arms) || error("$(m["name"]): arms $missing_arms not in $(s.path)")
    stat = m["op"] == "oracle_gap" ? _eligible_maa : m["stat"] == "maa" ? _eligible_maa : _finite_median
    vals = [evaluation_curve(ro, a, stat)[j] for a in arms]
    m["op"] == "oracle_gap" && return floors[s.oracle * "_maa"] - maximum(vals)
    return _reduce(m["op"], vals; what = m["name"])
end

function number_value(s::BasinSource, m, _floors)
    d = s.d
    mask = d["refinable"]
    m["op"] == "refinable" && return count(mask)
    # the ladder stores δ in radians rounded to 6 digits (registry.jl EXP_LADDER_DELTAS)
    j = _index(rad2deg.(Float64.(d["deltas"])), Float64(m["delta"]); what = "δ", rtol = 1e-4)
    methods = String.(d["methods"])
    vals = map(macro_arms(m)) do a
        mi = findfirst(==(a), methods)
        mi === nothing && error("$(m["name"]): arm $a not in $(s.path)")
        _eligible_maa(view(d["errs"], :, j, mi), mask; T = d["succ_deg"])
    end
    return _reduce(m["op"], vals; what = m["name"])
end

function number_value(s::BudgetSource, m, _floors)
    c = s.curves
    j = _index(Float64.(c.budgets), Float64(m["budget"]); what = "budget")
    vals = map(a -> (haskey(c.maa, a) || error("$(m["name"]): arm $a not in $(s.dir)"); c.maa[a][j]), macro_arms(m))
    return _reduce(m["op"], vals; what = m["name"])
end

function number_value(s::AnchoringSource, m, _floors)
    zw, zo = Float64.(s.dwith["zetas"]), Float64.(s.dwithout["zetas"])
    zw == zo || error("the anchoring evaluations' ζ ladders differ")
    j = _index(zw, Float64(m["zeta"]); what = "ζ")
    med(d, a) = evaluation_curve(d["evaluation"], a, _finite_median)[j]
    m["op"] == "max_abs_diff" && return maximum(abs(med(s.dwithout, a) - med(s.dwith, a)) for a in s.pairs)
    d = m["side"] == "with" ? s.dwith : m["side"] == "without" ? s.dwithout : error("$(m["name"]): side with | without")
    return _reduce(m["op"], [med(d, a) for a in s.pairs]; what = m["name"])
end

function number_value(s::TableSource, m, _floors)
    col = String(m["column"])
    zetas = haskey(m, "zetas") ? Float64.(m["zetas"]) : haskey(m, "zeta") ? [Float64(m["zeta"])] : nothing
    vals = Float64[]
    for a in macro_arms(m)
        rows = filter(r -> (haskey(r, "arm") ? r["arm"] : r["source"]) == a, s.rows)
        zetas === nothing || (rows = filter(r -> any(z -> isapprox(parse(Float64, r["zeta"]), z; rtol = 1e-6), zetas), rows))
        isempty(rows) && error("$(m["name"]): no row of $a in $(s.path)")
        zetas === nothing || length(rows) == length(zetas) || error("$(m["name"]): $a has $(length(rows)) rows for ζ $zetas")
        append!(vals, parse.(Float64, getindex.(rows, col)))
    end
    return _reduce(m["op"], vals; what = m["name"])
end

# The timing cell: the drawn pairs per scene (op pairs_per_scene: one count, the
# same in every scene — a stratified sample of equal-size scenes), the timed
# repeats (op repeats), or a column of its summary (any table op).
function number_value(s::TimingSource, m, floors)
    if m["op"] == "pairs_per_scene"
        n = unique(values(s.pairs_per_scene))
        length(n) == 1 || error("$(m["name"]): the scenes of $(s.sample) drew different pair counts $(s.pairs_per_scene)")
        return only(n)
    end
    m["op"] == "repeats" && return s.repeats
    return number_value(s.table, m, floors)
end

# The pooled mAA of the LO output ("before") or of the figure's polish (the
# config's first polisher, "after"), as scripts/polish.jl's summary computes it.
function number_value(s::PolishSource, m, _floors)
    p = m["when"] == "before" ? "none" : m["when"] == "after" ? first(s.d["polishers"]) :
        error("$(m["name"]): when = before | after")
    vals = map(macro_arms(m)) do a
        k = "$(a)|$(p)"
        haskey(s.d["err"], k) || error("$(m["name"]): no $k in $(s.path)")
        _eligible_maa(s.d["err"][k])
    end
    return _reduce(m["op"], vals; what = m["name"])
end

function number_value(s::SelectionSource, m, _floors)
    df = s.df
    z = Float64(m["zeta"]); col = Symbol(m["column"])
    vals = map(macro_arms(m)) do a
        r = findall(i -> df.method[i] == a && isapprox(df.n[i], z; rtol = 1e-6), 1:size(df, 1))
        length(r) == 1 || error("$(m["name"]): $(length(r)) rows of $a at ζ = $z in $(s.path)")
        Float64(df[only(r), col])
    end
    return _reduce(m["op"], vals; what = m["name"])
end

number_value(s::HebStatsSource, m, _floors) = HEB_STATISTICS[m["statistic"]](s.n, s.k, s.low)

function number_value(s::SplitSource, m, _floors)
    side = String(m["side"])
    m["op"] == "scenes" && return length(s.scenes[side])
    m["op"] == "pairs" && return s.pairs[side]
    error("$(m["name"]): a split source takes op scenes | pairs")
end

# ---- typesetting ------------------------------------------------------------------------
_thousands(n::Integer) = (s = string(abs(n)); g = reverse(join(Iterators.partition(reverse(s), 3) .|> join, ","));
                          (n < 0 ? "-" : "") * replace(g, "," => "\\,"))
function _typeset1(v::Real, f::AbstractDict)
    get(f, "pct", false) && return string(round(Int, 100v), raw"\%")
    get(f, "int", false) && (isinteger(v) || error("format int: $v is not an integer"); return _thousands(Int(v)))
    haskey(f, "digits") && return Printf.format(Printf.Format("%.$(Int(f["digits"]))f"), v)
    error("format: digits | int | pct, got $f")
end
"The typeset macro body of a value (a range as `lo\\text{--}hi`)."
typeset_number(v::Real, f) = _typeset1(v, f)
typeset_number(v::Tuple, f) = _typeset1(v[1], f) * raw"\text{--}" * _typeset1(v[2], f)

"""
    paper_number_floors(cfg) -> Dict

The oracle selection bounds the `oracle_gap` macros read (oracle_floors.jld2,
THE floors file of the cells' oracle stages), each checked to be the one of
its cell's CURRENT pools and test scenes (`oracle_floor_done`).
"""
function paper_number_floors(cfg::AbstractDict)
    for (n, s) in cfg["sources"]
        s["kind"] == "miscal" || continue
        c = fold_sequential_cv!(load_run_config(_cfg_path(s["config"])))
        cv = tuning_spec(c, sequential_cv_scorer_entry(c["sequential_cv"], :ig)).scheme.cross_validation
        oracle_floor_done(String(s["oracle"]); pool_dir = joinpath(data_root(), c["experiment"]["pool_dir"]),
                          problem = Symbol(c["experiment"]["problem"]), scenes = test_scenes(cv)) ||
            error("[sources.$n]: oracle floor $(s["oracle"]) missing or computed on other pools/scenes — run its cell's oracle stage")
    end
    return JLD2.load(oracle_floors_path(), "floors")
end

"""
    paper_numbers(cfg; floors) -> (; rows, sources)

Every macro of `cfg` (configs/paper_numbers.toml): `rows` of `(name, value,
tex, source)` in config order, `sources` the loaded results by name.
"""
function paper_numbers(cfg::AbstractDict; floors::AbstractDict)
    srcs = Dict(String(n) => load_number_source(n, s) for (n, s) in cfg["sources"])
    names = [m["name"] for m in cfg["macro"]]
    allunique(names) || error("paper_numbers: duplicate macro names $(names[findall(n -> count(==(n), names) > 1, names)])")
    rows = map(cfg["macro"]) do m
        v = number_value(srcs[m["source"]], m, floors)
        (name = String(m["name"]), value = v, tex = typeset_number(v, m["format"]), source = String(m["source"]))
    end
    return (; rows, sources = srcs)
end

const ACCV2026_PAPER_NUMBERS_LOADED = true
end # include guard
