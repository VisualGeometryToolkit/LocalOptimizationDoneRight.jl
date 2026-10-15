# =============================================================================
# src/cell_stages.jl — THE stage lists of the dataset-cell drivers.
#
# A dataset cell (scripts/supp_<TAG>_miscal.jl, scripts/supp_<TAG>_budget.jl)
# is ONE config of record (configs/<name>.toml, folded with the protocols of
# record into the run key) run through the same stages; the drivers differ
# only in that config and in the documentation of their pool. The stage lists
# are built here, once; each driver is its config name plus `run_stages`.
#
#   miscal_cell_stages(cfg_name; pool_what, pool_provenance)
#       cv (GPU)     — the sequential CV on the val scenes at ζ = 1,
#                      the ζ evaluation on the test scenes, interior-argmin audit,
#                      run records beside the operating-points sidecar;
#       oracle (CPU) — pool-best selection bound (floor + mAA ceiling);
#       render_main (CPU) — the cell's objective-faceted Fig 3 grid row into
#                      the paper's figures/.
#   scoring_pool_stages(cfg_name; what, provenance, audit_extra)
#       pools (CPU)  — the two-view scoring pools of every `source.splits` side,
#                      through THE one entry point generate_scoring_pools.jl;
#       audit (CPU)  — every expected scene present and READ at the current pool
#                      format (a real read, not `pool_is_native`).
#   budget_cell_stages(tag, cfg_name; protocol)
#       budget (CPU) — the streamed budget engine, every arm at its tuned
#                      operating point from the cell's deployed sidecar (a path of
#                      record, or a two-view miscal cell's key DERIVED via
#                      protocol_folds.miscal_sidecar_of, never copied), on
#                      the TEST side of that sidecar's cross-validation;
#       render (CPU) — the faceted budget panel (+ an optional time panel).
# =============================================================================
using DrWatson
using JLD2, TOML
using DelimitedFiles: readdlm
import VisualGeometryCore   # check_keys: the figure configs' key check
include(srcdir("config.jl"))
include(srcdir("common.jl"))
include(srcdir("registry.jl"))
include(srcdir("protocol_folds.jl"))

# The problem symbol of a cell config ("E" / "F"); its RANSAC problem type is
# the LO engine's `problem_type`.
_cell_problem(cfg) = Symbol(cfg["experiment"]["problem"])

# =============================================================================
# The tuning stages every miscalibration/basin experiment chains (fig2_basin,
# fig3_composed_miscal, supp_H_miscal and the dataset cells below): THE
# sequential CV (scripts/tools/run_sequential_cv.jl, notes/sequential_cv.md).
# THE tuning protocol of record (configs/tuning.toml, folded by
# protocol_folds.jl `fold_sequential_cv!`) is the one authority for every
# tuning parameter, and the miscalibration protocol of record
# (configs/miscal_protocol.toml) for the ζ evaluation ladder: every launch
# derives its arguments from them, never a literal.
# =============================================================================
const MISCAL_PROTOCOL = TOML.parsefile(projectdir("configs", "miscal_protocol.toml"))["protocol"]

"The ζ ladder of the miscalibration protocol of record, as driver arguments."
zeta_ladder_args(mp = MISCAL_PROTOCOL) =
    ["--n-zeta=$(mp["n_zeta"])", "--zeta-octaves=$(mp["zeta_octaves"])"]

"""
    sequential_cv_stage(name, cfg, cfg_path; inputs = ()) -> Stage

THE sequential CV of a folded cell config (`fold_sequential_cv!`; design:
notes/sequential_cv.md) through scripts/tools/run_sequential_cv.jl, into the
cell's keyed `sequential_cv_dir`: the scorer, the refiners at the scorer's a*,
and the ζ evaluation, each its own artifact. The effective config is written
to `<outdir>/_config.toml` and handed to the tool; the sidecar
(`operating_points.jld2`) then clears THE interior-argmin audit, and the run
records are written. `inputs` are `(path, what, provenance)`.
"""
function sequential_cv_stage(name::Symbol, cfg::AbstractDict, cfg_path::AbstractString; inputs = ())
    outdir = sequential_cv_dir(cfg)
    sidecar = joinpath(outdir, SEQUENTIAL_CV_SIDECAR)
    p = _cell_problem(cfg)
    return Stage(name,
        "sequential CV :$p (config $(basename(cfg_path)), key $(run_key(cfg))) -> $(sidecar)",
        () -> run_complete(outdir; sidecar = SEQUENTIAL_CV_SIDECAR),
        () -> begin
            for (path, what, provenance) in inputs
                require_input(path; what, provenance)
            end
            mkpath(outdir)
            config = joinpath(outdir, "_config.toml")
            open(io -> TOML.print(io, cfg; sorted = true), config, "w")
            run_driver("run_sequential_cv.jl", "--config=$(config)", "--outdir=$(outdir)")
            audit_operating_points(ROSTER, sidecar; problem = p)
            write_run_records(outdir, cfg; driver = "run_sequential_cv.jl",
                              config_source = cfg_path, key = run_key(cfg),
                              inputs = [joinpath(data_root(), cfg["experiment"]["pool_dir"])])
        end)
end

"""
    miscal_cell_stages(cfg_name; pool_what, pool_provenance) -> Vector{Stage}

The miscalibration cell of `configs/<cfg_name>.toml` — its sequential CV
(`[sequential_cv]`, [`sequential_cv_stage`](@ref)), oracle bound and grid row —
on the validation and test scenes of its cross-validation (the registered
split its `[protocol] cv_section` names). `pool_what` / `pool_provenance`
document the pool for `require_input`.
"""
function miscal_cell_stages(cfg_name::AbstractString;
                            pool_what::AbstractString, pool_provenance::AbstractString,
                            cv_stage::Symbol = :cv)
    cfg_path = projectdir("configs", cfg_name * ".toml")
    cfg = fold_sequential_cv!(load_run_config(cfg_path))   # protocols of record, folded into the key
    pool = joinpath(data_root(), cfg["experiment"]["pool_dir"])
    cv = tuning_spec(cfg, sequential_cv_scorer_entry(cfg["sequential_cv"], :ig)).scheme.cross_validation
    val_sc, test_sc = validation_scenes(cv), test_scenes(cv)
    test = join(test_sc, ",")
    sidecar = joinpath(sequential_cv_dir(cfg), SEQUENTIAL_CV_SIDECAR)
    r       = cfg["render"]
    tag     = cfg["experiment"]["oracle_tag"]
    p       = _cell_problem(cfg)
    floor_done() = oracle_floor_done(tag; pool_dir = pool, problem = p, scenes = test_sc)
    stages = Stage[sequential_cv_stage(cv_stage, cfg, cfg_path;
        inputs = ((joinpath(pool, "$(val_sc[1]).jld2"), pool_what, pool_provenance),))]
    push!(stages, Stage(:oracle,
            "$tag pool-best oracle bound (floor + mAA ceiling) -> oracle_floors.jld2[$tag]",
            floor_done,
            () -> run_driver("compute_supp_oracle_floors.jl",
                             "--tag=$(tag)", "--problem=$p",
                             "--pool-dir=$(pool)",
                             "--scenes=$(test)")))
    # The cell's row of the main-paper Fig 3 grid (configs/fig3_miscal_grid.toml):
    # the `[render.main]` table — `panel` and the one statistic of `rows` it draws —
    # drawn with the Table 1 roster gate (the renderer's MAIN_ARMS + EXTRA_ARMS
    # defaults). The grid draws its own legend.
    VisualGeometryCore.check_keys(r, ("deploy", "main"), "$cfg_path [render]")
    m = r["main"]
    VisualGeometryCore.check_keys(m, ("panel", "rows"), "$cfg_path [render.main]")
    length(m["rows"]) == 1 || error("$cfg_name [render.main] rows: the grid row draws one statistic, got $(m["rows"])")
    out, row = joinpath(PAPER_FIGDIR, m["panel"]), String(only(m["rows"]))   # deployed straight into the paper (registry.jl)
    push!(stages, Stage(:render_main, "$tag miscal panel, Table 1 roster, $(row) row (Fig 3 grid) -> $(out)",
            () -> fresher(out, sidecar),
            () -> begin
                audit_operating_points(ROSTER, sidecar; problem = Symbol(p))
                floor_done() ||
                    error("oracle floor $(tag): missing or computed on other pools/scenes — run --stage=oracle first")
                run_driver("render_miscal_faceted.jl";
                           env = Dict("SIDECAR" => sidecar, "OUT" => out,
                                      "DEPLOY" => r["deploy"] ? "1" : "", "ORACLE_TAG" => tag,
                                      "ROWS" => row))
            end))
    return stages
end

"""
    sidecar_scale_prior(sidecar) -> IGPrior

The marginal score's scale prior an operating-points sidecar was TUNED UNDER
(its scorer artifact's fitted inverse gamma; Jeffreys when it states none).
Every consumer that re-runs the scorer at those operating points — the budget
cells, the e2e cells, the polish — scores with it; a budget stream scored with
another prior than its operating points were tuned under is a mismatch (the
HEB-H inverse-gamma run's first budget, 2026-10-04, was hard-coded Jeffreys).
"""
function sidecar_scale_prior(sidecar::AbstractString)
    rec = load_tuning_artifact(sidecar)
    sc = load_tuning_artifact(String(rec["scorer_artifact"]))
    return haskey(sc, "prior_alpha0") ? IGPrior(Float64(sc["prior_alpha0"]), Float64(sc["prior_beta0"])) :
                                        IGPrior(0.0, 0.0)
end

"""
    budget_cell_stages(tag, cfg_name) -> Vector{Stage}

The sample-budget cell `tag` of `configs/<cfg_name>.toml` (two-view E/F and
the HEB homography), under the configs/sample_budget_protocol.toml section
its `[budget] protocol` names ([`fold_budget_cell!`](@ref), folded into the key). Every arm of the
deployed sidecar runs at its own tuned optimum; the sidecar is
`[operating_points] sidecar` (a path of record) or, for a two-view cell, the
keyed sidecar of `[operating_points] miscal_config` (DERIVED via
protocol_folds.miscal_sidecar_of, never copied). The scenes and pairs are the
TEST side of the sidecar's own cross-validation (its persisted spec) — the
evaluation reports exactly where its operating points were not tuned.

Each scene file carries every arm's per-pair curve, the oracle column (the
GT-best minimal model's running-best error at every batch checkpoint), the
count axes and the arm settings. An existing scene file keeps its curves
bit-identical: only the sidecar arms it lacks are computed and folded in.
`RVG_SMOKE=1` runs one scene, the first three arms (sorted) and 30 pairs,
into DrWatson's `datadir("sims", "budget-<key>-smoke")` — never beside the keyed
results — writing no run records.

`[render]` may set `rows` (default "med,maa"), `extra_arms` (default none)
and `[render.time]` (a panel of mAA against cumulative LO time); it is outside
the run key.
"""
function budget_cell_stages(tag::AbstractString, cfg_name::AbstractString)
    cfg_path = projectdir("configs", cfg_name * ".toml")
    cfg = fold_budget_cell!(load_run_config(cfg_path))   # protocols + the operating points' run, keyed
    sidecar = budget_sidecar(cfg)
    sbp = only(values(cfg["sample_budget_protocol"]))
    key = run_key(cfg)
    smoke = get(ENV, "RVG_SMOKE", "") == "1"
    ex = cfg["experiment"]
    pool = joinpath(data_root(), ex["pool_dir"])   # an absolute pool_dir stays itself
    p = _cell_problem(cfg)
    # The test side of the deployed sidecar's cross-validation, read lazily
    # (the sidecar is this cell's input, absent until its tuning stage ran).
    test_loaders() = let t = two_view_scene_loaders(sidecar_cross_validation(sidecar), pool).test
        smoke ? t[1:min(1, end)] : t
    end
    scenes() = isfile(sidecar) ? first.(test_loaders()) : String[]
    # a smoke run is a code check, never a result: DrWatson's datadir("sims")
    outdir = smoke ? datadir("sims", "budget-$(key)-smoke") : budget_cell_dir(cfg)
    rnd = cfg["render"]
    panel = joinpath(PAPER_FIGDIR, rnd["panel"])
    driver = "budget_cell_stages($(cfg_name))"
    # THE roster: the sidecar's arms seeded by a selector the cell declares
    # (`[budget] selectors`, tags of `SELECTOR_FAMILIES`). The engine seeds
    # through `SampleBudgetMethodSpec` with the Student-t + uniform marginal, so
    # `"student_t_uniform"` is the one selector it runs; a declared other
    # selector is REFUSED here rather than seeded by the marginal at a value on
    # another axis (the MSAC loss width), which is what this path did until
    # 2026-10-04 for any MSAC-seeded arm.
    selectors = selector_key.(String.(cfg["budget"]["selectors"]))
    issubset(selectors, (:ig,)) ||
        error("$cfg_name [budget] selectors = $(cfg["budget"]["selectors"]): the budget engine seeds through the " *
              "Student-t + uniform marginal only — name [\"student_t_uniform\"]")

    function run_budget()
        require_input(sidecar; what = "$tag deployed operating-points sidecar",
                      provenance = "the $(cfg["operating_points"]) tuning cell's cv stage (gate-audited)")
        audit_operating_points(ROSTER, sidecar; problem = p)      # MANDATORY before consumption
        dep = Dict(deployed_budget_settings(ROSTER, sidecar; problem = p))
        sel_of = Dict(a.base => a.sel for a in ROSTER.composed(p))
        # an opt-in variant (objective-matched, zero-clamp) runs only where THIS
        # cell declares it (`[budget] objective_matched` / `zero_clamp`),
        # whatever the sidecar holds
        runs_variants = Set(declared_variants(cfg["budget"]))
        bases = sort([b for b in keys(dep) if sel_of[b] in selectors &&
                                              (!(b in VARIANT_KEYS) || b in runs_variants)])
        skipped = sort(setdiff(collect(keys(dep)), bases))
        smoke && (bases = bases[1:min(3, end)])
        @info "budget @ tuned optima (:$p)" sidecar n_arms = length(bases) selectors skipped smoke
        cfgf(lo; nat_ref = nothing, nat_axis = OutlierHalfwidth()) =
            SampleBudgetConfig(; lo_strategy = lo, sample_cap = Int(sbp["sample_cap"]),
                               batch_size = Int(sbp["batch_size"]), lo_every = Int(sbp["lo_every"]),
                               budget_unit = Symbol(sbp["budget_unit"]), nat_ref, nat_axis)
        # The arm's kind (the roster's) is the axis its tuned native lives on.
        arm_cfg(s) = s.kind isa ScaleMultiple ? cfgf(s.lo) : cfgf(s.lo; nat_ref = s.ref, nat_axis = s.kind)
        mkpath(outdir)
        for (sc, load_test) in test_loaders()
            out_f = joinpath(outdir, "$sc.jld2")
            have = isfile(out_f) ? collect(String, JLD2.load(out_f, "arms")) : String[]
            missing_arms = setdiff(bases, have)
            isempty(missing_arms) && (@info "skip (complete)" sc; continue)
            isempty(have) || @info "append missing arms" sc arms = missing_arms
            t0 = time()
            # `scene_pool`, not `pool`: this closure captures the cell's pool
            # directory as `pool` (the run records' input), which a rebinding
            # here would overwrite with `nothing`.
            scene_pool, res = load_test()
            pairs, residuals = scene_pool.pairs, [residual_matrix(res, i) for i in eachindex(scene_pool.pairs)]
            scene_pool = res = nothing
            smoke && (pairs = pairs[1:min(30, length(pairs))]; residuals = residuals[1:length(pairs)])
            @info "scene loaded" sc n_pairs = length(pairs)
            old = isfile(out_f) ? JLD2.load(out_f) : Dict{String,Any}()
            err_lo = Dict{String,Matrix{Float32}}(get(old, "err_lo", Dict{String,Matrix{Float32}}()))
            timing = Dict{String,Any}(get(old, "lo_timing", Dict{String,Any}()))
            oracle_err_batch = get(old, "oracle_err_batch", nothing)
            # The selected seed's running-best error per batch (before any LO):
            # one stream per selection setting — every IG arm of a sequential-CV
            # sidecar shares the one a*, which is checked, not assumed.
            seed_err_batch = get(old, "seed_err_batch", nothing)
            seed_sel = get(old, "seed_selection", nothing)
            lo_counts = get(old, "lo_counts", Int[]); sample_counts = get(old, "sample_counts", Int[])
            for b in missing_arms
                s = dep[b]
                r = evaluate_sample_budget(problem_type(p),
                        [SampleBudgetMethodSpec(:ig, StudentTUniformScoring(problem_type(p), s.sel;
                                                                           prior = sidecar_scale_prior(sidecar)))],   # the operating points' own prior
                        pairs, residuals; cfg = arm_cfg(s))
                r.methods[1] === :ig || error("budget: method order changed — :ig is not column 1 ($(r.methods))")
                err_lo[b] = r.err_lo[:, 1, :]                    # the scoring column
                oracle_err_batch === nothing && (oracle_err_batch = r.err_batch[:, end, :])   # oracle = last selector
                if seed_err_batch === nothing
                    seed_err_batch = r.err_batch[:, 1, :]; seed_sel = s.sel
                else
                    s.sel == seed_sel || error("budget: arm $b selects at $(s.sel), the scene's seed stream at " *
                                               "$(seed_sel) — one selection setting per cell")
                end
                # in-situ LO counters (audit only: contention-noisy; figures use
                # time_lo_supp.jl's deterministic single-thread per-call times)
                timing[b] = (lo_ns = r.lo_ns_total[1], lo_calls = r.lo_calls_total[1],
                             lo_startup_ns = r.lo_startup_ns[1])
                # an existing file keeps its own count axes; only err_lo/arms grow
                isempty(lo_counts) && (lo_counts = r.lo_counts; sample_counts = r.sample_counts)
                @info "arm done" sc arm = b kind = s.kind sel = round(s.sel; sigdigits = 4) ref = round(s.ref; sigdigits = 4)
                flush(stderr)
            end
            tmp_f = out_f * ".appending"
            JLD2.jldsave(tmp_f; arms = sort(collect(keys(err_lo))), err_lo = err_lo,
                oracle_err_batch, seed_err_batch, seed_selection = seed_sel, lo_timing = timing,
                lo_counts, sample_counts, n_pairs = length(pairs),
                arm_settings = Dict(k => (sel = v.sel, ref = v.ref) for (k, v) in dep),
                operating_points_sidecar = sidecar, problem = String(p))
            mv(tmp_f, out_f; force = true)
            @info "scene done" sc secs = round(Int, time() - t0)
            pairs = nothing; GC.gc()
        end
        smoke || write_run_records(outdir, cfg; driver, config_source = cfg_path, key,
                                   inputs = [pool, sidecar])
    end

    done() = !smoke && isfile(sidecar) && all(isfile(joinpath(outdir, "$s.jld2")) for s in scenes()) &&
             isfile(joinpath(outdir, "_provenance.toml"))
    # THE budget renderer (scripts/tools/render_budget.jl, every two-view
    # budget cell's), launched with one interface: the scene directory, the
    # output panel, the cell config (its [render] there) and the panel kind.
    render_env(kind, out, legend; extra...) =
        Dict("KIND" => kind, "SBDIR" => outdir, "OUT" => out, "LEGEND" => legend, "CONFIG" => cfg_path,
             "EXTRA_ARMS" => get(rnd, "extra_arms", ""), (String(k) => v for (k, v) in extra)...)
    fresh(out) = () -> done() && fresher(out, joinpath(outdir, "$(scenes()[end]).jld2"))
    render_stage(name, out, legend, rows) = Stage(name,
            "faceted $tag budget panel ($rows) -> $(out)", fresh(out),
            () -> run_driver("render_budget.jl";
                             env = render_env("budget", out, legend;
                                              XTICKS = join(Int.(rnd["xticks"]), ","),
                                              DEPLOY = rnd["deploy"] ? "1" : "", ROWS = rows)))
    stages = Stage[]
    push!(stages, Stage(:budget,
            "$tag budget curves at deployed optima (config $(basename(cfg_path)), key $(key)) -> $(outdir)",
            done, run_budget))
    push!(stages, render_stage(:render, panel, rnd["legend"], get(rnd, "rows", "med,maa")))
    if haskey(rnd, "time")
        tpanel = replace(panel, ".tex" => "_time.tex")
        push!(stages, Stage(:render_time, "mAA vs cumulative LO time -> $(tpanel)", fresh(tpanel),
                () -> run_driver("render_budget.jl"; env = render_env("time", tpanel, rnd["time"]["legend"]))))
    end
    return stages
end

# =============================================================================
# Header-led TSVs (summary.tsv of the e2e cells): columns are always read BY
# HEADER NAME through `tsv_records`, never by position.
# =============================================================================
"""
    tsv_records(path) -> Vector{Dict{String,String}}

The rows of a header-led tab-separated file, each keyed by the header names.
Text from `#` to the end of a line is a comment (`readdlm`'s `comments`), so
the provenance preamble is skipped; a value must never contain `#`.
"""
function tsv_records(path::AbstractString)
    data, header = readdlm(path, '\t', String; header = true, comments = true, comment_char = '#')
    names = vec(String.(header))
    return [Dict(zip(names, String.(row))) for row in eachrow(data)]
end

# =============================================================================
# The main-paper 3-by-3 grids (fig3_miscal_grid, fig4_budget_grid): one row per
# dataset, stacked from the panels the producing experiments deploy, by
# scripts/tools/make_facet_grid.py (axis options, coordinates, colours and
# markers copied verbatim), drawn at mAA@10°.
# =============================================================================
"""
    facet_grid_stages(cfg_name) -> Vector{Stage}

The grid of the FIGURE config `configs/<cfg_name>.toml`, all of it under
`[render]`: `name` (→ `panel_<name>.tex`), `xopts`, `legend`, optionally
`xtick` / `xticklabels` (the shared x axis's ticks and their labels, one label
per tick), `oracle` (false drops the black oracle reference curves),
`ytick_spacing` (rows without a y range of their own: ticks every
`ytick_spacing` on a range fitted to the drawn curves, no minor ticks), and
one `[[render.rows]]` per dataset — `label` + `problem` (the row label),
`panel` (the deployed panel's base name), `producer` + `stage` (who deploys
it), and optionally `maa` = `[lo, hi, step]`, that row's y axis (absent keeps
the panel's own). Unknown keys are refused: a figure config is not a run
config, so nothing else would catch a typo.
"""
function facet_grid_stages(cfg_name::AbstractString)
    path = projectdir("configs", cfg_name * ".toml")
    r = TOML.parsefile(path)["render"]
    VisualGeometryCore.check_keys(r, ("name", "xopts", "legend", "xtick", "xticklabels", "oracle", "ytick_spacing", "rows"), "$path [render]")
    rows = r["rows"]
    for row in rows
        VisualGeometryCore.check_keys(row, ("label", "problem", "panel", "producer", "stage", "maa"), "$path [[render.rows]]")
    end
    name = String(r["name"]); xopts = String(r["xopts"]); legend = String(r["legend"])
    composer = scriptsdir("tools", "make_facet_grid.py")
    panel(row) = joinpath(PAPER_FIGDIR, row["panel"] * ".tex")
    axis(row) = haskey(row, "maa") ? join(string.(row["maa"]), ':') : ""
    out = joinpath(PAPER_FIGDIR, "panel_$(name).tex")
    function compose()
        for row in rows
            require_input(panel(row); what = "$(row["panel"]) panel",
                          provenance = "$(row["producer"]) stage $(row["stage"])")
        end
        spec = join(["$(row_label(row["label"], Symbol(row["problem"])))=$(panel(row))" for row in rows], ";")
        yaxes = [axis(row) for row in rows]
        yopt = all(isempty, yaxes) ? String[] : ["--yaxes=$(join(yaxes, ';'))"]
        xopt = vcat(haskey(r, "xtick") ? ["--xtick=$(join(string.(Float64.(r["xtick"])), ','))"] : String[],
                    haskey(r, "xticklabels") ? ["--xticklabels=$(join(r["xticklabels"], '|'))"] : String[],
                    get(r, "oracle", true) ? String[] : ["--oracle=0"],
                    haskey(r, "ytick_spacing") ? ["--ytick-spacing=$(r["ytick_spacing"])"] : String[])
        run(`python3 $(composer) --rows=maa --out=$(out) --legend=$(legend) --xopts=$(xopts) $(yopt) $(xopt) --panels=$(spec)`)
        isfile(out) || error("$(name): composer wrote no $(out)")
    end
    return [Stage(:compose, "3-by-3 $(name) grid, maa → $(out)",
                  () -> isfile(out) && fresher(out, path, [panel(row) for row in rows]...),
                  compose)]
end

"""
    scoring_pool_stages(cfg_name; what, provenance, audit_extra = nothing) -> Vector{Stage}

The POOL PRODUCER cell of `configs/<cfg_name>.toml`: two-view scoring pools for
every side listed in `source.splits`, into `experiment.pool_dir`.

`what` / `provenance` document the raw source for `require_input`.
`audit_extra(scene, path)`, if given, adds a per-scene check after the read
(HEB's `gt_convention`).

Nothing here states a generation constant: the cell's TOML names the dataset,
problem, splits and the `[pool]` generation constants, and a split side's
scenes are `split_scenes` (validation_data.jl) — the same resolver the pool
driver uses, so this file holds no second copy of either.
"""
function scoring_pool_stages(cfg_name::AbstractString;
                             what::AbstractString, provenance::AbstractString,
                             audit_extra = nothing)
    cfg_path = projectdir("configs", cfg_name * ".toml")
    cfg = load_run_config(cfg_path)
    key = run_key(cfg)
    exp, src = cfg["experiment"], cfg["source"]
    # The source descriptor is ASSERTED, not decorative.
    src["image_unit"] == "px" ||
        error("$(cfg_name): source.image_unit must be px (got $(src["image_unit"]))")
    # Fail EARLY on a problem letter the pool driver has no problem for, rather
    # than at the generation subprocess after a scheduler wait.
    Symbol(exp["problem"]) in (:E, :F, :H) ||
        error("$(cfg_name): experiment.problem must be E, F or H (got $(exp["problem"]))")
    outdir = joinpath(data_root(), exp["pool_dir"])
    # The scene set is exactly what the config's sides resolve to, through the
    # protocol's registry — this paper states no scene list (protocol_invariants).
    scenes = sort(unique(reduce(vcat, split_scenes.(src["splits"]))))
    # EVERY raw root the config declares — every `[source] *_dir` key plus the
    # per-scene `recon_special` exceptions — resolved against data_root() and
    # declared as an input, so the tree's `_provenance.toml` names the raw data
    # it was built from.
    inputs = String[joinpath(data_root(), src[k])
                    for k in sort(collect(keys(src))) if endswith(k, "_dir")]
    if haskey(src, "recon_special")
        append!(inputs, (joinpath(data_root(), v) for v in values(src["recon_special"])))
    end

    _done() = all(isfile(joinpath(outdir, "$(s).jld2")) for s in scenes) &&
              run_complete(outdir; sidecar = "$(scenes[end]).jld2")

    function _audit()
        tot = 0
        for s in scenes
            f = joinpath(outdir, "$(s).jld2")
            isfile(f) || error("AUDIT $(s): missing $(f)")
            # The package reader. A stale pool format THROWS here — that is
            # the check.
            n = length(load_pool(f))
            n > 0 || error("AUDIT $(s): pool carries no pairs")
            audit_extra === nothing || audit_extra(s, f)
            tot += n
        end
        @info "AUDIT OK" cell = cfg_name scenes = length(scenes) pairs = tot out_dir = outdir
    end

    stages = Stage[]
    push!(stages, Stage(:pools,
            "$(exp["dataset"]) $(exp["problem"]) scoring pools, $(length(scenes)) scenes " *
            "(config $(basename(cfg_path)), key $(key)) -> $(outdir)",
            _done,
            () -> begin
                for p in inputs
                    require_input(p; what, provenance)
                end
                run_driver("generate_scoring_pools.jl", "--config=$(cfg_name)")
                write_run_records(outdir, cfg; driver = "generate_scoring_pools.jl",
                                  config_source = cfg_path, key, inputs,
                                  producer = true)   # a NEW pool tree under the data root
            end))
    push!(stages, Stage(:audit,
            "pool contract: all $(length(scenes)) scenes readable at the current pool format -> log",
            () -> false,
            _audit))
    return stages
end
