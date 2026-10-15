#!/usr/bin/env julia
# provenance: a worker of src/superansac.jl (scripts/superansac_e2e.jl); its
# inputs are the cell's raw-pixel slices, its settings the cell's config.
# paper-project: allow P1 a worker of src/superansac.jl (scripts/superansac_e2e.jl): it writes one part file into the SupeRANSAC cell's keyed directory, whose run records the cell writes
# paper-project: allow P2 the cell keys the directory (superansac-<run key>) and names each part; the worker writes only where --out says
# =============================================================================
# scripts/tools/superansac_worker.jl — SupeRANSAC on one raw-pixel input
# slice, in the SupeRANSAC environment (envs/superansac: PythonCall + a build of
# pysuperansac; NOT this project's environment). Ported from the earlier
# SupeRANSAC drivers superansac_common.jl / superansac_loss_width_worker.jl /
# superansac_zeta_worker.jl (which ran the published rows on 2026-10-04): the
# same settings, input form, metric and output schema.
#
#   julia --project=envs/superansac scripts/tools/superansac_worker.jl \
#         --mode=loss_width|zeta --settings=<effective cell config> --inputs=<slice> --out=<jld2>
#         [--loss-widths=w1,w2,...]          (loss_width: the tuning termination)
#         [--loss-width=w* --zetas=z1,...]   (zeta: loss width ζ·w*, the evaluation termination)
#   ... --mode=time --inputs=<slice1>,<slice2>,... --loss-width=w* --zetas=z1,... \
#         --warmup-pairs=<n> --cpu=<pinned cpu> --out=<jld2>
#         (one TIMED run of the timing cell, src/e2e_timing.jl: every slice at
#          every ζ, the evaluation termination, after an untimed warm-up of the
#          first n pairs of each slice; refused unless pinned to exactly <cpu>)
#
# SETTINGS — every one from the cell config's [superansac] (configs/pt_e_superansac.toml):
# the authors' essential-matrix tester preset ([superansac.preset]: PROSAC
# sampling over matches sorted by descending 1 − SNN with rank probabilities
# 1 − rank/n, MAGSAC scoring, NestedRANSAC local optimization, LSQ final
# optimization, local_opt_k, SPRT, the neighbourhood grid, the tester's literal
# image sizes) at a termination ([superansac.tuning_termination] or
# [superansac.evaluation_termination]: min/max trials and confidence — their
# adaptive criterion is inert in every binding-reachable configuration, so the
# max is the budget). The loss width is the one knob swept.
#
# HAZARD (still present upstream): estimateEssentialMatrix MUTATES the
# RANSACSettings it is given (px loss width → normalized units), so every call
# gets a FRESH settings object.
#
# METRIC: the pose error of every row of the e2e table — max(ΔR, Δt) [deg]
# over the best decomposition of E (VisualGeometryCore imc_pose_error), x₂ᵀE x₁
# = 0; `Inf` when no model. The wall clock brackets exactly the
# estimateEssentialMatrix call.
# =============================================================================
using JLD2, TOML, Printf, Dates
using Statistics: median
using StaticArrays: SMatrix, SVector
using VisualGeometryCore: EssentialMat
using VisualGeometryCore.Synthetic: imc_pose_error
using PythonCall
include(joinpath(@__DIR__, "..", "..", "src", "timing_probe.jl"))   # the timing repeat's machine records (pure Base)

function _option(name, default = nothing)
    for a in ARGS
        startswith(a, "--$name=") && return a[length(name)+4:end]
    end
    default === nothing && error("superansac_worker: --$name=... is required")
    return default
end
_floats(s) = parse.(Float64, split(s, ','; keepempty = false))

const MODE = _option("mode")
const SETTINGS = TOML.parsefile(_option("settings"))["superansac"]
const INPUT = _option("inputs")   # mode time: a comma-separated list of slices
const OUT = _option("out")
const PRESET = SETTINGS["preset"]

"(min trials, max trials, confidence) of a termination table."
_termination(t) = (Int(t["min_trials"]), Int(t["max_trials"]), Float64(t["confidence"]))

"A FRESH RANSACSettings at `loss_width` [px] and `term`, every other field the preset's."
function sr_settings(pysa, loss_width::Real, term)
    c = pysa.RANSACSettings()
    c.inlier_threshold = Float64(loss_width)
    c.min_iterations, c.max_iterations, c.confidence = term       # their names count TRIALS
    c.local_opt_k = Int(PRESET["local_opt_k"])
    c.use_sprt = Bool(PRESET["use_sprt"])
    c.sampler = getproperty(pysa.SamplerType, Symbol(PRESET["sampler"]))
    c.scoring = getproperty(pysa.ScoringType, Symbol(PRESET["scoring"]))
    c.local_optimization = getproperty(pysa.LocalOptimizationType, Symbol(PRESET["local_optimization"]))
    c.final_optimization = getproperty(pysa.LocalOptimizationType, Symbol(PRESET["final_optimization"]))
    c.neighborhood_settings.neighborhood_grid_density = Int(PRESET["neighborhood_grid_density"])
    c.neighborhood_settings.neighborhood_size = Int(PRESET["neighborhood_size"])
    return c
end

"The slice's pairs in the tester's input form: matches by descending 1 − SNN, rank probabilities."
function sr_pairs(np, d)
    map(1:d["n_pairs"]) do i
        order = sortperm(1.0 .- d["snn"][i]; rev = true)
        Ms = d["matches"][i][order, :]
        m = size(Ms, 1)
        (matches = np.ascontiguousarray(np.asarray(Ms), dtype = np.float64),
         K1 = np.ascontiguousarray(np.asarray(d["K1"][i]), dtype = np.float64),
         K2 = np.ascontiguousarray(np.asarray(d["K2"][i]), dtype = np.float64),
         probabilities = pylist([1.0 - (k - 1) / m for k in 1:m]),
         R_gt = SMatrix{3,3,Float64,9}(d["R_gt"][i]),
         t_gt = SVector{3,Float64}(d["t_gt"][i]))
    end
end

"One estimateEssentialMatrix call: (; err, trials, inliers, wall)."
function sr_estimate(pysa, np, pair, settings)
    t0 = time_ns()
    out = pysa.estimateEssentialMatrix(pair.matches, pair.K1, pair.K2,
                                       pylist(Float64.(PRESET["image_sizes"])), pair.probabilities;
                                       config = settings)
    wall = (time_ns() - t0) / 1e9
    E_py, inl, its = out[0], out[1], out[3]
    trials = pyconvert(Int, its)
    pyis(E_py, pybuiltins.None) && return (; err = Inf, trials, inliers = 0, wall)
    E = pyconvert(Matrix{Float64}, np.asarray(E_py))
    err = Float64(imc_pose_error(EssentialMat{Float64}(Tuple(SMatrix{3,3,Float64,9}(E))), pair.R_gt, pair.t_gt))
    return (; err, trials, inliers = pyconvert(Int, pybuiltins.len(inl)), wall)
end

"`sr_estimate` over `pairs` (serial: perf-counter walls), a fresh settings object per call."
function sr_run(pysa, np, pairs, loss_width, term)
    rs = [sr_estimate(pysa, np, p, sr_settings(pysa, loss_width, term)) for p in pairs]
    return (; err = [r.err for r in rs], trials = [r.trials for r in rs],
            inliers = [r.inliers for r in rs], wall = [r.wall for r in rs])
end

"The pysuperansac build of record: its distribution version and where it was imported from."
sr_build(pysa) = "pysuperansac " * pyconvert(String, pyimport("importlib.metadata").version("pysuperansac")) *
                 " (" * pyconvert(String, pysa.__file__) * ")"

"""
One TIMED run (mode time): every slice of `--inputs` at every ζ (loss width
ζ·w*, the evaluation termination), in slice then ζ order, after an untimed
warm-up of the first `--warmup-pairs` pairs of each slice at every ζ; the
machine window around the repeat (src/timing_probe.jl).
"""
function main_time()
    cpu = parse(Int, _option("cpu"))
    check_timing_pinning(cpu)
    pysa, np = pyimport("pysuperansac"), pyimport("numpy")
    term = _termination(SETTINGS["evaluation_termination"])
    w_star = parse(Float64, _option("loss-width"))
    zetas = _floats(_option("zetas"))
    nw = parse(Int, _option("warmup-pairs"))
    files = String.(split(INPUT, ','; keepempty = false))
    slices = map(files) do f
        d = JLD2.load(f)
        haskey(d, "pool_key") || error("$f names no pool_key")
        (scene = String(d["scene"]), units = Int.(d["pair_indices"]), pairs = sr_pairs(np, d))
    end
    for sl in slices, ζ in zetas
        sr_run(pysa, np, sl.pairs[1:min(nw, end)], w_star * ζ, term)
    end
    started = string(Dates.now())
    res = Dict{String,Any}()
    a0 = timing_snapshot(cpu)
    for sl in slices, ζ in zetas
        GC.gc()
        r = sr_run(pysa, np, sl.pairs, w_star * ζ, term)
        res["$(sl.scene)|z" * @sprintf("%.6f", ζ)] = (scene = sl.scene, zeta = ζ, err = r.err, wall = r.wall, trials = r.trials)
    end
    window = timing_window(a0, timing_snapshot(cpu), cpu)
    mkpath(dirname(OUT))
    jldsave(OUT; res, zetas, scenes = [sl.scene for sl in slices], pairs = Dict(sl.scene => sl.units for sl in slices),
            inputs = files, loss_width_cv = w_star, build = sr_build(pysa), window, host = timing_host(), started,
            termination = "$(term[1])/$(term[2])/$(term[3])", created = string(Dates.now()))
    @info "SupeRANSAC timed repeat" OUT window["seconds"] window["loadavg_before"] window["loadavg_after"] window["cpu_other_busy"]
    return nothing
end

function main()
    MODE == "time" && return main_time()
    d = JLD2.load(INPUT)
    haskey(d, "pool_key") || error("$INPUT names no pool_key — rewrite it (stage inputs)")
    pysa, np = pyimport("pysuperansac"), pyimport("numpy")
    pairs = sr_pairs(np, d)
    scene = String(d["scene"])
    build = sr_build(pysa)
    mkpath(dirname(OUT))
    if MODE == "loss_width"
        term = _termination(SETTINGS["tuning_termination"])
        loss_widths = _floats(_option("loss-widths"))
        errors = [sr_run(pysa, np, pairs, w, term).err for w in loss_widths]
        for (w, e) in zip(loss_widths, errors)
            @info @sprintf("superansac %s loss width %.4g px  median=%.3f", scene, w, median(e))
        end
        jldsave(OUT; loss_widths, errors, inputs = [INPUT], build,
                termination = "$(term[1])/$(term[2])/$(term[3])", created = string(Dates.now()))
    elseif MODE == "zeta"
        term = _termination(SETTINGS["evaluation_termination"])
        w_star = parse(Float64, _option("loss-width"))
        zetas = _floats(_option("zetas"))
        res = Dict{String,Any}()
        for ζ in zetas
            r = sr_run(pysa, np, pairs, w_star * ζ, term)
            res["$(scene)|z" * @sprintf("%.6f", ζ)] = (scene = scene, zeta = ζ, err = r.err, wall = r.wall, trials = r.trials)
            @info @sprintf("superansac %s zeta=%.4g loss width=%.4g px  med=%7.3f  wall_med=%.0fms",
                           scene, ζ, w_star * ζ, median(filter(isfinite, r.err)), 1e3 * median(r.wall))
        end
        jldsave(OUT; res, zetas, scenes = [scene], units = [(scene, Int(i)) for i in d["pair_indices"]],
                inputs = [INPUT], loss_width_cv = w_star, build,
                provenance = "loss width = zeta * w* (the cell's tuned loss width, at zeta = 1; a test-time " *
                             "corruption, never re-tuned) on the test units of $(scene); termination " *
                             "$(term[1])/$(term[2])/$(term[3]) (min/max trials, confidence; the adaptive " *
                             "criterion is inert, so the max is the budget); a fresh settings object per call; " *
                             "serial perf-counter walls",
                created = string(Dates.now()))
    else
        error("superansac_worker: --mode must be loss_width, zeta or time, got $(repr(MODE))")
    end
    return nothing
end

main()
