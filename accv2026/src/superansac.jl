# =============================================================================
# src/superansac.jl — the SupeRANSAC cell (configs/pt_e_superansac.toml,
# scripts/superansac_e2e.jl): SupeRANSAC (Barath et al., 2025) cross-validated
# and evaluated on the pairs our end-to-end table (scripts/e2e_ransac.jl,
# configs/pt_e_e2e_table.toml) reports on, so its rows stand beside ours.
#
# SUPERANSAC IS AN OUTSIDE DEPENDENCY. Its Python binding (`pysuperansac`,
# built from https://github.com/danini/superansac) lives in the auxiliary
# environment the config names (`[environment] project`, envs/superansac:
# PythonCall + CondaPkg), never in this project's. Every call runs in a
# worker process there (scripts/tools/superansac_worker.jl);
# [`superansac_status`](@ref) detects it and [`require_superansac`](@ref)
# stops with the installation steps when it is absent. Without it the e2e
# table is built from the STORED results the config names (`[stored] dir`):
# [`superansac_results`](@ref) reads the cell's own keyed results when they
# are complete, the stored ones otherwise, and says which.
#
# THE DATA. The cell's pairs are the operating points' cross-validation
# (`[operating_points] miscal_config`): the loss width is tuned on its
# VALIDATION units (both pipelines cross-validated on the same pairs), the ζ
# ladder evaluated on its TEST units (every pair the e2e table reports). The
# inputs are raw-PIXEL slices of the light pool records
# ([`superansac_pixel_inputs!`](@ref)): SupeRANSAC normalizes internally and
# runs on its own frame (a third-party estimator; the pool frame never reaches
# it).
#
# THE SETTINGS are the config's, every one: the authors' essential-matrix
# tester preset (`[superansac.preset]`), the termination of the tuning and of
# the evaluation (`[superansac.tuning_termination]`,
# `[superansac.evaluation_termination]`), the ζ ladder (`[superansac] zetas`:
# loss width = ζ·w*, a test-time corruption, never re-tuned) and the loss-width
# CV (`[tuning.superansac_loss_width]`, the single CV path, its window stated in
# full). pysuperansac exposes no RNG seed: run-to-run objective noise is the
# library's own.
# =============================================================================
using JLD2, TOML, Printf, Dates
using DrWatson: projectdir   # configs/ of the active (accv2026) project
using Statistics: median, mean
using VisualGeometryEval.Pools: load_pool
using VisualGeometryEval.Tuning: layer_tuning, tuning_spec, tuning_table, grid_spec, sample_units,
    validation_scenes, test_scenes
using VisualGeometryEval.Evaluation: coarse_fine_cv_batched, enforce_probe_interior,
    save_scalar_tuning_artifact, deployed_scalar_setting
using VisualGeometryCore.Pools: pixel_csponds
using VisualGeometryCore: sources, targets
include(joinpath(@__DIR__, "config.jl"))           # the paper prelude (guarded)
include(joinpath(@__DIR__, "common.jl"))           # run_driver's context: scripts/tools, this project
include(joinpath(@__DIR__, "protocol_folds.jl"))   # operating_points_run, fold_sequential_cv!

# (the `using`s above stay outside the guard: a macro such as `@sprintf` must
# be bound before the guarded block is parsed)
if !@isdefined(ACCV2026_SUPERANSAC_LOADED)

"The tuning entry of a SupeRANSAC cell."
const SUPERANSAC_TUNING = "superansac_loss_width"

"""
    fold_superansac_cell!(cfg) -> cfg

THE fold of a SupeRANSAC cell into its run key: the run of the operating
points whose cross-validation it reads (`[operating_points] miscal_config`,
that cell's key without its opt-in variants — the units do not depend on them)
and that cross-validation, layered beneath `[tuning.superansac_loss_width]`
(resolved: its scene lists and samplings key the run). Unknown sections are
refused.
"""
function fold_superansac_cell!(cfg)
    known = ("experiment", "operating_points", "superansac", "tuning", "environment", "stored")
    VisualGeometryCore.check_keys(cfg, known, "SupeRANSAC cell")
    VisualGeometryCore.check_keys(cfg["superansac"],
        ("zetas", "preset", "tuning_termination", "evaluation_termination"), "SupeRANSAC cell [superansac]")
    VisualGeometryCore.check_keys(cfg["tuning"], (SUPERANSAC_TUNING,), "SupeRANSAC cell [tuning]")
    name = String(cfg["operating_points"]["miscal_config"])
    op = fold_sequential_cv!(load_run_config(projectdir("configs", name * ".toml")))
    for k in ("dataset", "matcher", "problem", "pool_dir")
        op["experiment"][k] == cfg["experiment"][k] ||
            error("SupeRANSAC cell: [experiment] $k differs from the operating points' ($name)")
    end
    cv = tuning_spec(op, sequential_cv_scorer_entry(op["sequential_cv"], :ig)).scheme.cross_validation
    cfg["operating_points_run"] = operating_points_run(name)
    cfg["tuning"][SUPERANSAC_TUNING] = layer_tuning(
        Dict{String,Any}("cross_validation" => tuning_table(cv)), cfg["tuning"][SUPERANSAC_TUNING])
    return cfg
end

"A SupeRANSAC cell's folded config, by name (configs/<name>.toml)."
superansac_cell(name::AbstractString) =
    fold_superansac_cell!(load_run_config(projectdir("configs", name * ".toml")))

"The loss-width tuning spec of a folded cell (its cross-validation: the operating points')."
superansac_spec(cfg) = tuning_spec(cfg, SUPERANSAC_TUNING)
"The cross-validation a folded cell tunes and evaluates on."
superansac_cross_validation(cfg) = superansac_spec(cfg).scheme.cross_validation

"""
    superansac_cell_dir(cfg) -> String

The keyed directory of a folded SupeRANSAC cell:
`<results>/<dataset>/<matcher>/<problem>/SupeRANSAC/superansac-<run_key>`.
"""
superansac_cell_dir(cfg) = joinpath(experiment_dir(cfg), "SupeRANSAC", "superansac-" * run_key(cfg))

"The directory of the STORED results the config names (`[stored] dir`, under the results root)."
superansac_stored_dir(cfg) = joinpath(results_root(), String(cfg["stored"]["dir"]))

"The raw-pixel input slice of `scene`'s `side` units."
superansac_inputs_path(dir, scene, side) = joinpath(dir, "inputs", "inputs_$(scene)_$(side).jld2")
"The ζ-sweep results of `scene`."
superansac_zeta_path(dir, scene) = joinpath(dir, "zeta_$(scene).jld2")
"The loss-width tuning artifact."
superansac_cv_path(dir) = joinpath(dir, "loss_width_cv.jld2")
"The key of one (scene, ζ) result in a ζ-sweep file's `res`."
superansac_key(scene::AbstractString, ζ::Real) = "$(scene)|z" * @sprintf("%.6f", ζ)

# --- the outside dependency ------------------------------------------------------

"The auxiliary environment SupeRANSAC runs in (`[environment] project`, relative to the project root)."
superansac_env(cfg) = projectdir(String(cfg["environment"]["project"]))

"""
    superansac_status(cfg) -> (; available::Bool, detail::String)

Is SupeRANSAC importable in the cell's environment? Probes it in a fresh
process (`using PythonCall; pyimport(<python_module>)`) with CondaPkg OFFLINE,
so a probe never installs anything: an uninstantiated environment, an
unresolved conda environment or a missing build all report unavailable.
`detail` is the module's version (available) or the last lines of the probe's
error output.
"""
function superansac_status(cfg)
    env = superansac_env(cfg)
    mod = String(cfg["environment"]["python_module"])
    isfile(joinpath(env, "Project.toml")) || return (available = false, detail = "no environment at $env")
    code = "using PythonCall; m = pyimport(\"$mod\"); " *
           "print(pyconvert(String, pyimport(\"importlib.metadata\").version(\"$mod\")))"
    cmd = setenv(`$(joinpath(Sys.BINDIR, "julia")) --startup-file=no --project=$env -e $code`,
                 merge(copy(ENV), Dict("JULIA_CONDAPKG_OFFLINE" => "yes")))
    out, err = IOBuffer(), IOBuffer()
    ok = success(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
    return ok ? (available = true, detail = String(take!(out))) :
                (available = false, detail = join(last(split(strip(String(take!(err))), '\n'), 12), '\n'))
end

"""
    require_superansac(cfg)

Stop, with the installation steps, unless SupeRANSAC is importable in the
cell's environment ([`superansac_status`](@ref)).
"""
function require_superansac(cfg)
    st = superansac_status(cfg)
    st.available && return (@info "SupeRANSAC available" version = st.detail; nothing)
    env = superansac_env(cfg)
    e = cfg["environment"]
    error("""
        SupeRANSAC is not available: `$(e["python_module"])` cannot be imported in $env.
        It is an OUTSIDE dependency this project does not install. To install it:
          1. julia --project=$env -e 'using Pkg; Pkg.instantiate(); using CondaPkg; CondaPkg.resolve()'
             (PythonCall + CondaPkg; the conda environment of $(joinpath(env, "CondaPkg.toml"))
             — Python, Eigen, Boost, OpenCV and the build tools — resolves into $(joinpath(env, ".CondaPkg")))
          2. git clone $(e["source_repository"]) <checkout>
          3. julia --project=$env -e 'using CondaPkg; CondaPkg.withenv() do
                 ENV["CMAKE_PREFIX_PATH"] = ENV["CONDA_PREFIX"]
                 run(`python -m ensurepip`)   # CondaPkg's pixi backend installs no pip
                 run(`python -m pip install --no-build-isolation -v <checkout>`)
             end'
        Without it, scripts/e2e_ransac.jl builds the table from the stored SupeRANSAC results
        ($(superansac_stored_dir(cfg))).
        Probe output: $(st.detail)""")
end

"Run the SupeRANSAC worker (scripts/tools/superansac_worker.jl) in the cell's environment, single-threaded."
superansac_worker(cfg, args...) =
    run_driver("superansac_worker.jl", args...; project = superansac_env(cfg), threads = 1)

# --- the inputs -------------------------------------------------------------------

# N×4 `[x₁ y₁ x₂ y₂]` rows of a pair's pixel csponds — the external estimator's input layout.
_match_matrix(cs) = [reduce(hcat, collect.(sources(cs)))' reduce(hcat, collect.(targets(cs)))']

"""
    superansac_pixel_inputs!(path, scene, pool_dir, units_fn) -> path

SupeRANSAC's raw-PIXEL input slice of `scene`: the pool pairs
`units_fn(n_pairs)` (strictly increasing pool indices) of the light pool —
`matches` (per pair an N×4 `[x₁ y₁ x₂ y₂]` matrix of pixel csponds, through
the record's own maps, VisualGeometryCore `pixel_csponds`), the stored `snn`,
the pixel `K1`/`K2` and the GT `R_gt`/`t_gt`, the indices (`pair_indices`),
the pool's size (`pool_size`) and its `pool_key`. An existing file is kept.
"""
function superansac_pixel_inputs!(path::AbstractString, scene::AbstractString, pool_dir::AbstractString, units_fn)
    isfile(path) && return path
    f = joinpath(pool_dir, "$scene.jld2")
    require_input(f; what = "scoring pool ($scene)", provenance = "the pool tree [experiment] pool_dir names")
    return superansac_pixel_inputs!(path, scene, load_pool(f), units_fn)
end

# The same slice from an already loaded light pool (the timing cell loads each pool once).
function superansac_pixel_inputs!(path::AbstractString, scene::AbstractString, pool, units_fn)
    isfile(path) && return path
    idx = collect(Int, units_fn(length(pool)))
    isempty(idx) && throw(ArgumentError("superansac_pixel_inputs!: no pair indices for $scene"))
    issorted(idx; lt = <=) || throw(ArgumentError("superansac_pixel_inputs!: pair indices of $scene must be strictly increasing"))
    ps = pool.pairs[idx]
    mkpath(dirname(path))
    JLD2.jldsave(path; scene = String(scene), n_pairs = length(ps), pair_indices = idx, pool_size = length(pool),
                 pool_key = pool.pool_key,
                 matches = [Matrix{Float64}(_match_matrix(pixel_csponds(p))) for p in ps],
                 snn = [Float64.(p.snn) for p in ps],
                 K1 = [Matrix{Float64}(p.K1) for p in ps], K2 = [Matrix{Float64}(p.K2) for p in ps],
                 R_gt = [Matrix{Float64}(p.R_gt) for p in ps], t_gt = [Vector{Float64}(p.t_gt) for p in ps],
                 provenance = "load_pool($(scene)) pool_key $(pool.pool_key); pixel_csponds + snn + K/R/t " *
                              "as stored; pool pairs $(idx); julia $(VERSION)",
                 created = string(Dates.now()))
    @info "pixel inputs written" path n_pairs = length(idx)
    return path
end

"The units of `scene` a side's sampling keeps, for a pool of `n` pairs."
_side_units(sampling, scene, n) = only(values(sample_units(sampling, Dict(String(scene) => collect(1:n)))))

"""
    superansac_inputs!(cfg, dir) -> Vector{String}

Every input slice the cell reads, under `dir`: the validation units of every
validation scene and the test units of every test scene of its
cross-validation. Existing slices are kept.
"""
function superansac_inputs!(cfg, dir)
    cv = superansac_cross_validation(cfg)
    pool = joinpath(data_root(), cfg["experiment"]["pool_dir"])
    out = String[]
    for (side, scenes, sampling) in (("validation", validation_scenes(cv), cv.validation),
                                     ("test", test_scenes(cv), cv.test)), s in scenes
        push!(out, superansac_pixel_inputs!(superansac_inputs_path(dir, s, side), s, pool,
                                            n -> _side_units(sampling, s, n)))
        GC.gc()
    end
    return out
end

"The input slices of `side`, refused unless each holds exactly the side's units of its scene."
function _checked_inputs(cfg, dir, side::AbstractString)
    cv = superansac_cross_validation(cfg)
    scenes, sampling = side == "validation" ? (validation_scenes(cv), cv.validation) : (test_scenes(cv), cv.test)
    files = [superansac_inputs_path(dir, s, side) for s in scenes]
    for (s, f) in zip(scenes, files)
        require_input(f; what = "SupeRANSAC raw-pixel inputs ($s, $side)", provenance = "stage inputs of this cell")
        d = JLD2.load(f)
        (d["scene"], d["pair_indices"]) == (s, _side_units(sampling, s, d["pool_size"])) ||
            error("$f does not hold the $side units of $s — delete it and re-run the inputs stage")
    end
    return scenes, files
end

"Write the cell's effective config beside its results: the workers read their settings from it."
function _write_effective_config(cfg, dir)
    mkpath(dir)
    path = joinpath(dir, "_superansac.toml")
    open(io -> TOML.print(io, cfg; sorted = true), path, "w")
    return path
end

"Run `jobs` (`(i, job)` → a worker call) on every thread of this process, one worker each."
_on_workers(f, jobs) = asyncmap(f, jobs; ntasks = Threads.nthreads())

# --- the loss-width CV ------------------------------------------------------------

"""
    superansac_loss_width_cv!(cfg, dir) -> path

THE loss-width CV of the cell (`[tuning.superansac_loss_width]`, the single
CV path: VisualGeometryEval `coarse_fine_cv_batched`): every loss width the
search requests is evaluated by worker processes, one per (validation scene,
loss width), at the tuning termination; the objective is the spec's criterion
over the pooled validation units' per-pair pose errors (a failure is `Inf`).
Writes the tuning artifact (`x_star_fine` = THE tuned loss width w*, px).
"""
function superansac_loss_width_cv!(cfg, dir)
    require_superansac(cfg)
    out = superansac_cv_path(dir)
    spec = superansac_spec(cfg)
    scheme = spec.scheme
    scenes, inputs = _checked_inputs(cfg, dir, "validation")
    settings = _write_effective_config(cfg, dir)
    builds = Set{String}()
    function errors_at(ws::Vector{Float64})
        mktempdir() do tmp
            part(k, i) = joinpath(tmp, "errors_$(k)_$(i).jld2")
            _on_workers([(k, i) for k in eachindex(inputs) for i in eachindex(ws)]) do (k, i)
                superansac_worker(cfg, "--mode=loss_width", "--settings=$(settings)", "--inputs=$(inputs[k])",
                                  "--loss-widths=$(ws[i])", "--out=$(part(k, i))")
            end
            parts = [JLD2.load(part(k, i)) for k in eachindex(inputs), i in eachindex(ws)]
            all(i -> all(d -> d["loss_widths"] == [ws[i]], parts[:, i]), eachindex(ws)) ||
                error("a SupeRANSAC worker answered another loss width than requested")
            union!(builds, String(d["build"]) for d in parts)
            # pooled in input order: exactly a single worker over every input
            return [reduce(vcat, [only(parts[k, i]["errors"]) for k in eachindex(inputs)]) for i in eachindex(ws)]
        end
    end
    recs = coarse_fine_cv_batched(xs_of -> Dict(k => errors_at(Float64.(xs)) for (k, xs) in xs_of),
                                  Dict(:superansac => grid_spec(scheme.coarse)), scheme;
                                  method_name = _ -> :superansac_E, label = _ -> "superansac-loss-width",
                                  param_name = :loss_width, context_tag = "superansac-E")
    rec = recs[:superansac]
    enforce_probe_interior(rec; context = "SupeRANSAC loss-width CV")
    build = only(builds)
    # the single-scalar artifact (VisualGeometryEval): grids, CV record and x_star_fine, read back
    # only through deployed_scalar_setting
    save_scalar_tuning_artifact(out, spec, rec; unit = TWO_VIEW_UNIT, code = (VisualGeometryCore,),
        tuning_inputs = inputs, scenes,
        pair_indices = [JLD2.load(f, "pair_indices") for f in inputs], build,
        objective = "the spec's criterion over the pooled validation units' per-pair max(dR, dt) [deg] " *
                    "(VisualGeometryCore imc_pose_error); a failure is Inf",
        protocol = "the [superansac.preset] tester preset at [superansac.tuning_termination]; ONLY " *
                   "inlier_threshold swept; a fresh RANSACSettings per call; no RNG seed exposed by pysuperansac",
        created = string(Dates.now()))
    @info "SupeRANSAC loss-width CV done" x_star_coarse = rec[:x_star] x_star_fine = rec[:x_star_fine] out
    return out
end

# --- the ζ evaluation -------------------------------------------------------------

"""
    superansac_evaluation!(cfg, dir)

SupeRANSAC on every test unit of the cell's cross-validation at every ζ of
`[superansac] zetas` (loss width ζ·w*, w* the tuning artifact's), at the
evaluation termination: one worker per (scene, ζ), merged per scene into
`zeta_<scene>.jld2` — `res[superansac_key(scene, ζ)] = (scene, zeta, err,
wall, trials)` with the scene's `units`, `zetas`, `loss_width_cv` and `build`.
"""
function superansac_evaluation!(cfg, dir)
    require_superansac(cfg)
    w = deployed_scalar_setting(superansac_cv_path(dir); context = "SupeRANSAC loss-width CV")
    zetas = Float64.(cfg["superansac"]["zetas"])
    scenes, inputs = _checked_inputs(cfg, dir, "test")
    settings = _write_effective_config(cfg, dir)
    part(s, ζ) = superansac_zeta_path(dir, s) * ".z" * @sprintf("%.6f", ζ) * ".jld2"
    jobs = [(s, f, ζ) for (s, f) in zip(scenes, inputs) if !isfile(superansac_zeta_path(dir, s)) for ζ in zetas]
    _on_workers(jobs) do (s, f, ζ)
        isfile(part(s, ζ)) || superansac_worker(cfg, "--mode=zeta", "--settings=$(settings)", "--inputs=$(f)",
                                                "--loss-width=$(w)", "--zetas=$(ζ)", "--out=$(part(s, ζ))")
    end
    for s in scenes
        isfile(superansac_zeta_path(dir, s)) && continue
        ps = [JLD2.load(part(s, ζ)) for ζ in zetas]
        res = merge([p["res"] for p in ps]...)
        all(haskey(res, superansac_key(s, ζ)) for ζ in zetas) || error("SupeRANSAC parts of $s miss a ζ")
        p1 = first(ps)
        jldsave(superansac_zeta_path(dir, s); res, zetas, scenes = p1["scenes"], units = p1["units"],
                inputs = p1["inputs"], loss_width_cv = w, build = p1["build"], provenance = p1["provenance"])
    end
end

# --- the results the e2e table reads -------------------------------------------------

"""
    superansac_results(cfg, scenes) -> (; source, dir, files)

Where the e2e table reads SupeRANSAC from: the cell's own keyed results when
every scene's ζ file is there, else the STORED results of `[stored] dir`
(published with the paper; their provenance is that directory's
PROVENANCE.toml), else an error. `files[scene]` is the scene's ζ-sweep file.
"""
function superansac_results(cfg, scenes)
    own = superansac_cell_dir(cfg)
    for (source, dir) in (("this cell's run ($own)", own),
                          ("the stored results ($(superansac_stored_dir(cfg)))", superansac_stored_dir(cfg)))
        files = Dict(String(s) => superansac_zeta_path(dir, s) for s in scenes)
        all(isfile, values(files)) && return (; source, dir, files)
    end
    error("SupeRANSAC results: neither $own (scripts/superansac_e2e.jl) nor the stored " *
          "$(superansac_stored_dir(cfg)) holds every scene of $(scenes)")
end

"""
    superansac_scene_results(file, scene, units, zetas) -> Vector

The `(err, wall, trials)` records of `scene` at every ζ of `zetas` from a
ζ-sweep file, refused unless it holds exactly `units` (the pool indices the
e2e cell ran ours on) and every ζ.
"""
function superansac_scene_results(file, scene, units, zetas)
    d = JLD2.load(file)
    got = [Int(i) for (s, i) in d["units"] if s == scene]
    got == collect(Int, units) ||
        error("$file holds other units of $scene than the e2e cell's ($(length(got)) vs $(length(units)))")
    return [d["res"][superansac_key(scene, ζ)] for ζ in zetas]
end

const ACCV2026_SUPERANSAC_LOADED = true
end # include guard
