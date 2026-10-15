# =============================================================================
# src/e2e_timing.jl — the END-TO-END TIMING cell (configs/pt_e_e2e_timing.toml,
# scripts/e2e_timing.jl): THE time row of main-paper Tab. 3.
#
# The accuracy run (scripts/e2e_ransac.jl) runs every test pair multithreaded:
# its per-pair streams make every error independent of the thread schedule, but
# its wall clocks share the machine with the other threads. The timing repeat is
# separate: a sample of the test pairs drawn by VisualGeometryEval's unit
# sampling (`[timing] sample`, the vocabulary of the validation and test sides),
# each system timed in a fresh single-threaded process pinned to ONE CPU and its
# NUMA node (`[timing.pinning]`, numactl), the run repeated `[timing] repeats`
# times, ours and SupeRANSAC alternating on the same CPU and the same pairs.
# Every setting is the config's; this file and the driver hold none.
#
# THE STATISTIC (the accuracy summary's, `e2e_summary_line`): per pair the
# median over the repeats of its wall time, per scene the median over its pairs,
# then the mean over the scenes [ms]. The run-to-run spread is that statistic
# computed from each repeat alone (min, max, (max − min)/median).
#
# Ours runs the accuracy cell's deployment (`e2e_deployment`) with the same
# per-pair streams, so its timed errors must equal the accuracy run's on the
# same pairs, bit for bit: the summary checks it. SupeRANSAC runs at its cell's
# tuned loss width (its own run, or the stored one) with the evaluation
# termination, in its environment (src/superansac.jl).
#
# Included after cell_stages.jl and e2e_cells.jl.
# =============================================================================
using JLD2, TOML, Printf, Dates
using Statistics: median, mean
using DrWatson: projectdir, scriptsdir
using VisualGeometryEval.Tuning: read_tuning, UnitSampling, sample_units, test_scenes, tuning_table
using VisualGeometryEval.Evaluation: deployed_scalar_setting
include(joinpath(@__DIR__, "superansac.jl"))     # the SupeRANSAC cell (config, common, protocol folds)
include(joinpath(@__DIR__, "timing_probe.jl"))   # the machine records of a repeat

if !@isdefined(ACCV2026_E2E_TIMING_LOADED)

"""
    fold_e2e_timing_cell!(cfg) -> cfg

The fold of a timing cell into its run key: the run of the e2e cell it times
(`[timing] e2e_config`, its run key — a re-tune or a new ζ ladder re-keys the
timing) and of that cell's SupeRANSAC cell (its run key: SupeRANSAC is timed at
that cell's tuned loss width). `[timing]`:

- `e2e_config`: the accuracy cell (arms, ζ ladder, per-pair streams, termination);
- `sample`: the timed pairs, a COMPLETE unit-sampling table in VisualGeometryEval's
  vocabulary (`exhaustive` | `stratified` | `uniform`, read by `read_tuning`)
  over that cell's test units;
- `repeats` (≥ 4) timed repeats per system; `warmup_pairs` (≥ 1): the first pairs
  of each scene, run untimed at every ζ by each worker process before its repeat;
- `[timing.pinning]`: `launcher` ("numactl"), `cpu`, `numa_node`, `julia_threads`
  and `gc_threads` (1 each) and the workers' environment `env` (BLAS/OpenMP threads).
"""
function fold_e2e_timing_cell!(cfg)
    t = cfg["timing"]
    VisualGeometryCore.check_keys(t, ("e2e_config", "sample", "repeats", "warmup_pairs", "pinning"), "[timing]")
    p = t["pinning"]
    VisualGeometryCore.check_keys(p, ("launcher", "cpu", "numa_node", "julia_threads", "gc_threads", "env"), "[timing.pinning]")
    Int(t["repeats"]) >= 4 || error("[timing] repeats: at least 4 timed repeats, got $(t["repeats"])")
    Int(t["warmup_pairs"]) >= 1 || error("[timing] warmup_pairs: at least 1, got $(t["warmup_pairs"])")
    p["launcher"] == "numactl" || error("[timing.pinning] launcher: only \"numactl\" is supported, got $(repr(p["launcher"]))")
    Int(p["julia_threads"]) == 1 && Int(p["gc_threads"]) == 1 ||
        error("[timing.pinning]: a timing repeat is single-threaded (one Julia thread, one GC thread)")
    read_tuning(UnitSampling, t["sample"])   # a complete sampling table, or an error naming the key
    e2e = e2e_timed_cell(cfg)
    for k in ("dataset", "matcher", "problem", "pool_dir")
        e2e["experiment"][k] == cfg["experiment"][k] ||
            error("timing cell: [experiment] $k differs from the e2e cell's ($(t["e2e_config"]))")
    end
    haskey(e2e["e2e"], "superansac") || error("timing cell: the e2e cell $(t["e2e_config"]) names no [e2e] superansac")
    cfg["e2e_run"] = run_key(e2e)
    cfg["superansac_run"] = run_key(superansac_cell(String(e2e["e2e"]["superansac"])))
    return cfg
end

"A timing cell's folded config, by name (configs/<name>.toml)."
e2e_timing_cell(name::AbstractString) =
    fold_e2e_timing_cell!(load_run_config(projectdir("configs", name * ".toml")))

"The folded e2e cell a timing cell times."
e2e_timed_cell(cfg) = fold_e2e_cell!(load_run_config(projectdir("configs", String(cfg["timing"]["e2e_config"]) * ".toml")))

"The SupeRANSAC cell of the timed e2e cell."
e2e_timed_superansac(cfg) = superansac_cell(String(e2e_timed_cell(cfg)["e2e"]["superansac"]))

"""
    e2e_timing_dir(cfg) -> String

The keyed directory of a folded timing cell:
`<results>/<dataset>/<matcher>/<problem>/EndToEnd/timing-<run_key>`.
"""
e2e_timing_dir(cfg) = joinpath(experiment_dir(cfg), "EndToEnd", "timing-" * run_key(cfg))

"The timing sample's file (scene ⇒ the drawn pool indices), its ours and SupeRANSAC inputs, and a repeat's output."
timing_sample_path(dir) = joinpath(dir, "sample.toml")
timing_pairs_path(dir, scene) = joinpath(dir, "inputs", "pairs_$(scene).jld2")
timing_sr_inputs_path(dir, scene) = joinpath(dir, "inputs", "inputs_$(scene)_timing.jld2")
timing_repeat_path(dir, system::AbstractString, r::Integer) = joinpath(dir, "$(system)_r$(r).jld2")
"The summary of the timing cell (THE time row of Tab. 3)."
timing_summary_path(dir) = joinpath(dir, "timing.tsv")

"The light-pool size of `scene` (its pairs counted without loading them)."
_timing_pool_size(pool_dir, scene) = jldopen(f -> length(f["scene_names"]), joinpath(pool_dir, scene * ".jld2"))

"""
    draw_timing_sample(cfg) -> Dict{String,Vector{Int}}

The timed pairs: `[timing] sample` (VisualGeometryEval unit sampling) applied to
the test units of the timed e2e cell's operating points — its test scenes, each
scene's units as the accuracy run keeps them — scene ⇒ pool indices, sorted.
"""
function draw_timing_sample(cfg)
    e2e = e2e_timed_cell(cfg)
    cv = sidecar_cross_validation(miscal_sidecar_of(String(e2e["operating_points"]["miscal_config"])))
    pool = joinpath(data_root(), e2e["experiment"]["pool_dir"])
    test = Dict(s => only(values(sample_units(cv.test, Dict(s => collect(1:_timing_pool_size(pool, s))))))
                for s in test_scenes(cv))
    drawn = sample_units(read_tuning(UnitSampling, cfg["timing"]["sample"]), test)
    return Dict{String,Vector{Int}}(String(s) => sort!(collect(Int, v)) for (s, v) in drawn)
end

"The drawn sample of a timing directory (scene ⇒ pool indices), in scene order."
function read_timing_sample(dir)
    d = TOML.parsefile(timing_sample_path(dir))
    scenes = sort!(collect(keys(d["pairs"])))
    return scenes, Dict{String,Vector{Int}}(s => collect(Int, d["pairs"][s]) for s in scenes)
end

"""
    timing_inputs!(cfg, dir) -> nothing

The sample (`sample.toml`: the sampling table and every drawn pool index) and,
from one load of each scene's light pool, the drawn pairs for ours
(`inputs/pairs_<scene>.jld2`) and their raw-pixel slices for SupeRANSAC
(`inputs/inputs_<scene>_timing.jld2`, src/superansac.jl). Existing files are kept.
"""
function timing_inputs!(cfg, dir)
    mkpath(joinpath(dir, "inputs"))
    if !isfile(timing_sample_path(dir))
        drawn = draw_timing_sample(cfg)
        open(timing_sample_path(dir), "w") do io
            println(io, "# The timed pairs of this timing cell: [timing] sample over the test units of the e2e cell.")
            TOML.print(io, Dict("sampling" => tuning_table(read_tuning(UnitSampling, cfg["timing"]["sample"])),
                                "n_pairs" => sum(length, values(drawn)),
                                "pairs" => drawn); sorted = true)
        end
    end
    scenes, drawn = read_timing_sample(dir)
    pool_dir = joinpath(data_root(), cfg["experiment"]["pool_dir"])
    for s in scenes
        isfile(timing_pairs_path(dir, s)) && isfile(timing_sr_inputs_path(dir, s)) && continue
        pool = pt_pool(s, pool_dir)
        idx = drawn[s]
        isfile(timing_pairs_path(dir, s)) ||
            jldsave(timing_pairs_path(dir, s); scene = s, pair_indices = idx, pairs = pool.pairs[idx],
                    pool_key = pool.pool_key, pool_size = length(pool))
        superansac_pixel_inputs!(timing_sr_inputs_path(dir, s), s, pool, _ -> idx)
        pool = nothing; GC.gc()
    end
    return nothing
end

"""
    pinned_worker_cmd(cfg, script, args...; project) -> Cmd

The pinned launch of a timing worker: `numactl --physcpubind=<cpu>
--membind=<numa_node> julia -t <julia_threads> --gcthreads=<gc_threads>
--project=<project> <script> <args>` under the `[timing.pinning] env`.
"""
function pinned_worker_cmd(cfg, script::AbstractString, args...; project::AbstractString)
    p = cfg["timing"]["pinning"]
    jl = joinpath(Sys.BINDIR, "julia")
    cmd = Cmd(["numactl", "--physcpubind=$(p["cpu"])", "--membind=$(p["numa_node"])",
               jl, "--startup-file=no", "-t", string(p["julia_threads"]), "--gcthreads=$(p["gc_threads"])",
               "--project=$(project)", script, string.(args)...])
    return setenv(cmd, merge(copy(ENV), Dict(String(k) => String(v) for (k, v) in p["env"])))
end

"""
    run_timing_repeat(cfg, cfg_name, dir, system, r)

Timed repeat `r` of `system` ("ours" | "superansac") on the drawn pairs, in a
fresh pinned process → `<system>_r<r>.jld2`.
"""
function run_timing_repeat(cfg, cfg_name::AbstractString, dir, system::AbstractString, r::Integer)
    out = timing_repeat_path(dir, system, r)
    isfile(out) && return out
    tmp = out * ".part"
    if system == "ours"
        cmd = pinned_worker_cmd(cfg, scriptsdir("tools", "e2e_time_ours.jl"), "--config=$(cfg_name)",
                                "--dir=$(dir)", "--out=$(tmp)"; project = projectdir())
    elseif system == "superansac"
        sr = e2e_timed_superansac(cfg)
        scenes, _ = read_timing_sample(dir)
        w = deployed_scalar_setting(superansac_cv_path(superansac_results(sr, scenes).dir);
                                    context = "SupeRANSAC loss-width CV (timing)")
        settings = _write_effective_config(sr, dir)
        cmd = pinned_worker_cmd(cfg, scriptsdir("tools", "superansac_worker.jl"), "--mode=time",
                                "--settings=$(settings)",
                                "--inputs=" * join([timing_sr_inputs_path(dir, s) for s in scenes], ','),
                                "--loss-width=$(w)", "--zetas=" * join(Float64.(e2e_timed_cell(cfg)["e2e"]["zetas"]), ','),
                                "--warmup-pairs=$(cfg["timing"]["warmup_pairs"])",
                                "--cpu=$(cfg["timing"]["pinning"]["cpu"])", "--out=$(tmp)";
                                project = superansac_env(sr))
    else
        error("run_timing_repeat: system must be ours or superansac, got $(repr(system))")
    end
    println(">> timing repeat $(r) of $(system): ", cmd); flush(stdout)
    run(cmd)
    mv(tmp, out)
    return out
end

"""
    timing_summary!(cfg, cfg_name, dir) -> String

THE time row: per system and ζ, the statistic of the header over the repeats
(`med_wall_ms`), the same statistic of each repeat alone (`rep_min_ms`,
`rep_max_ms`, `rep_spread_pct`), the pairs and repeats; the machine windows of
every repeat under `timing_repeats.toml`. Refused unless ours' timed errors equal
the accuracy run's on the same pairs.
"""
function timing_summary!(cfg, cfg_name::AbstractString, dir)
    e2e = e2e_timed_cell(cfg)
    arms, zetas = String.(e2e["e2e"]["arms"]), Float64.(e2e["e2e"]["zetas"])
    R = Int(cfg["timing"]["repeats"])
    scenes, drawn = read_timing_sample(dir)
    runs = Dict(sys => [JLD2.load(timing_repeat_path(dir, sys, r)) for r in 1:R] for sys in ("ours", "superansac"))
    # ours' errors are the accuracy run's, bit for bit (same deployment, same per-pair streams)
    live = JLD2.load(joinpath(e2e_cell_dir(e2e), "live.jld2"))
    for a in arms, s in scenes, ζ in zetas
        pos = [findfirst(==(i), live["units"][s]) for i in drawn[s]]
        acc = live["per_pair"]["$(a)|$(s)|$(ζ)"].err[pos]
        for (r, p) in enumerate(runs["ours"])
            isequal(p["res"]["$(a)|$(s)|$(ζ)"].err, acc) ||
                error("timing repeat $r of ours: the errors of $a on $s at ζ = $ζ differ from the accuracy run's")
        end
    end
    systems = [[(a, "ours", "$(a)|") for a in arms]; ("SupeRANSAC", "superansac", "")]
    stat(walls_by_scene) = mean(median(w) for w in walls_by_scene)   # mean over scenes of the per-scene median
    lines = ["# $(cfg_name) — the end-to-end time row (Tab. 3): $(sum(length, values(drawn))) drawn pairs of " *
             "$(length(scenes)) test scenes, $(R) pinned single-threaded repeats per system (CPU $(cfg["timing"]["pinning"]["cpu"]))",
             "# med_wall_ms: mean over scenes of the per-scene median over pairs of each pair's median over the repeats",
             join(["arm", "zeta", "med_wall_ms", "rep_min_ms", "rep_max_ms", "rep_spread_pct", "n_pairs", "repeats"], '\t')]
    f3(x) = @sprintf("%.3f", x)
    for (name, sys, prefix) in systems, ζ in zetas
        key(s) = sys == "ours" ? "$(prefix)$(s)|$(ζ)" : superansac_key(s, ζ)
        rec(r, s) = runs[sys][r]["res"][key(s)]
        walls(r, s) = Float64.(sys == "ours" ? rec(r, s).wall_s : rec(r, s).wall)   # live_runs' and the worker's names
        all(r -> all(s -> length(walls(r, s)) == length(drawn[s]), scenes), 1:R) ||
            error("timing: a repeat of $name at ζ = $ζ holds another number of pairs than the sample")
        pooled = stat([[median(walls(r, s)[j] for r in 1:R) for j in eachindex(drawn[s])] for s in scenes])
        per_rep = [stat([walls(r, s) for s in scenes]) for r in 1:R]
        push!(lines, join([name, string(ζ), f3(1e3 * pooled), f3(1e3 * minimum(per_rep)), f3(1e3 * maximum(per_rep)),
                           f3(100 * (maximum(per_rep) - minimum(per_rep)) / median(per_rep)),
                           string(sum(length, values(drawn))), string(R)], '\t'))
    end
    open(joinpath(dir, "timing_repeats.toml"), "w") do io
        println(io, "# The machine around every timed repeat (src/timing_probe.jl): host, load averages and CPU shares.")
        rec = Dict("$(sys)_r$(r)" => Dict("host" => p["host"], "window" => p["window"],
                                          "started" => p["started"], "build" => get(p, "build", ""))
                   for (sys, ps) in runs for (r, p) in enumerate(ps))
        TOML.print(io, rec; sorted = true)
    end
    write(timing_summary_path(dir), join(lines, '\n') * "\n")
    return timing_summary_path(dir)
end

const ACCV2026_E2E_TIMING_LOADED = true
end # include guard
