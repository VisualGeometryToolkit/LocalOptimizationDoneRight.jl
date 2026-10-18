#!/usr/bin/env julia
# provenance: a worker of src/e2e_timing.jl (scripts/e2e_timing.jl): its inputs are the
# timing cell's drawn pairs, its settings the timing cell's and the e2e cell's configs.
# paper-project: allow P1 a worker of src/e2e_timing.jl (scripts/e2e_timing.jl): it writes one repeat file into the timing cell's keyed directory, whose run records the cell writes
# paper-project: allow P2 the cell keys the directory (timing-<run key>) and names each repeat; the worker writes only where --out says
# =============================================================================
# scripts/tools/e2e_time_ours.jl — ONE timed repeat of our end-to-end pipeline
# on the timing cell's drawn pairs, in a process the cell pins to one CPU
# (src/e2e_timing.jl `pinned_worker_cmd`; refused here unless pinned and
# single-threaded). The deployment, the per-pair streams and the termination
# are the e2e cell's (`e2e_deployment`, `stable_seed(seed, stream, scene, i)`,
# `e2e_ransac_config`); the wall clock brackets exactly the `ransac` call
# (VisualGeometryToolkitEval `live_runs`, serial on one thread).
#
# Warm-up: the first `[timing] warmup_pairs` pairs of every scene, every arm and
# ζ, untimed, before the repeat (JIT and caches). Then every (scene, arm, ζ) in
# order, a GC before each block, outside the brackets.
#
#   numactl --physcpubind=<cpu> --membind=<node> julia -t 1 --project=. \
#       scripts/tools/e2e_time_ours.jl --config=<timing config> --dir=<timing dir> --out=<jld2>
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, Dates
include(srcdir("cell_stages.jl"))
include(srcdir("e2e_cells.jl"))
include(srcdir("e2e_timing.jl"))

const TCFG = fold_e2e_timing_cell!(load_run_config(projectdir("configs", cli_option(ARGS, "config") * ".toml")))
const DIR = cli_option(ARGS, "dir")
const OUT = cli_option(ARGS, "out")
const CPU = Int(TCFG["timing"]["pinning"]["cpu"])
check_timing_pinning(CPU)

function main()
    e2e = e2e_timed_cell(TCFG)
    arms, zetas = String.(e2e["e2e"]["arms"]), Float64.(e2e["e2e"]["zetas"])
    seed, stream = Int(e2e["e2e"]["seed"]), String(e2e["e2e"]["stream"])
    rcfg = e2e_ransac_config(e2e)
    sidecar = miscal_sidecar_of(String(e2e["operating_points"]["miscal_config"]))
    (; scoring_at, lo_at) = e2e_deployment(sidecar, arms)
    scenes, drawn = read_timing_sample(DIR)
    ctxs = Dict(s => begin
                    d = JLD2.load(timing_pairs_path(DIR, s))
                    d["pair_indices"] == drawn[s] || error("$(timing_pairs_path(DIR, s)) holds other pairs than the sample")
                    [build_pair_ctx(EssentialProblem, p) for p in d["pairs"]]
                end for s in scenes)
    run_block(s, a, ζ, js; warmup) = live_runs(scoring_at(a, ζ), lo_at(a, ζ), ctxs[s][js];
                                               problem_of = pt_live_problem, config = rcfg,
                                               seed_of = j -> stable_seed(seed, stream, s, drawn[s][js[j]]), warmup)
    nw = Int(TCFG["timing"]["warmup_pairs"])
    for s in scenes, a in arms, ζ in zetas
        run_block(s, a, ζ, 1:min(nw, length(drawn[s])); warmup = true)
    end
    started = string(Dates.now())
    res = Dict{String,Any}()
    a0 = timing_snapshot(CPU)
    for s in scenes, a in arms, ζ in zetas
        GC.gc()
        res["$(a)|$(s)|$(ζ)"] = run_block(s, a, ζ, eachindex(drawn[s]); warmup = false)
    end
    window = timing_window(a0, timing_snapshot(CPU), CPU)
    jldsave(OUT; res, scenes, pairs = drawn, arms, zetas, window, host = timing_host(), started,
            seed_scheme = "StableRNG(stable_seed($(seed), \"$(stream)\", scene, pool_index))",
            created = string(Dates.now()))
    @info "ours timed repeat" OUT window["seconds"] window["loadavg_before"] window["loadavg_after"] window["cpu_other_busy"]
end

main()
