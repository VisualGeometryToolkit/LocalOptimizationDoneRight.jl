#!/usr/bin/env julia
# =============================================================================
# derive_pool_samples.jl — the exact minimal-sample starts of a scoring-pool
# tree, by replaying its generator's seeded draw streams.
#
#   julia --project=. -t auto scripts/tools/derive_pool_samples.jl --config=pt_e_pools
#
# A format-4 pool stores no per-model sample id; VisualGeometryEval
# `Pools.sample_starts(pool)` recovers the boundaries from the record and
# certifies them against the pool's `total_samples` stamp. Where that
# certificate fails (an E solve that returned a duplicated root: 276 of the
# 46,200 PT-E-SIFT-4K_pf3 pairs), only the draw stream decides, and this tool
# replays it: per pair the StableRNG stream `stable_seed(pool_seed, i)` of
# `write_scene_pool`, drawn by the Gaussian-SNN sampler of `[pool]` in the form
# that GENERATED the tree (RobustVisualGeometry 0.23: keys U^(1/w) over the
# normalized weights, the top `m` by `partialsortperm(…; rev = true)`; the
# current sampler draws log-space keys, which differ where U^(1/w) underflows).
# VisualGeometryEval `derive_sample_starts` matches the stream to the record
# and refuses anything it cannot certify.
#
# Output (DERIVED data, never beside the input pools): one
# `<scene>.samples.jld2` per scene under
#   <results>/<dataset>/<matcher>/<problem>/PoolSamples/samples-<run key of the pool config>/
# with the run records. Consumers give that directory's file as
# `sample_starts(pool; derived = …)`.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using VisualGeometryEval: cli_option, start_output_flush!
using VisualGeometryEval.Pools: load_pool, derive_sample_starts, save_sample_starts, sample_starts
using VisualGeometryEval.Experiments: load_run_config, data_root, run_key, experiment_dir, write_run_records
using VisualGeometryEval.Stats: stable_seed, POOL_RNG
using RobustVisualGeometry: EssentialProblem, FundMatProblem, HomographyProblem, minimal_sample_size

const _PROBLEMS = Dict(:E => EssentialProblem, :F => FundMatProblem, :H => HomographyProblem)

# The generating Gaussian-SNN draw (RobustVisualGeometry 0.23), as a stream.
function gaussian_stream(snn, m, σ, seed)
    w = [exp(-Float64(s)^2 / (2σ^2)) + 1e-6 for s in snn]
    invw = 1.0 ./ (w ./ sum(w))
    rng = POOL_RNG(seed)
    keys = similar(invw)
    return () -> begin
        @inbounds for i in eachindex(invw)
            keys[i] = rand(rng)^invw[i]
        end
        partialsortperm(keys, 1:m; rev = true)
    end
end

function derive_pool_samples(cfg; config_source)
    ex, pool = cfg["experiment"], cfg["pool"]
    pool["sampler"] == "gaussian" ||
        error("derive_pool_samples: replays the Gaussian-SNN sampler; [pool] sampler = $(pool["sampler"])")
    m = minimal_sample_size(_PROBLEMS[Symbol(ex["problem"])])
    σ, seed = Float64(pool["gaussian_sigma"]), Int(pool["pool_seed"])
    in_dir = joinpath(data_root(), ex["pool_dir"])
    key = run_key(cfg)
    out = joinpath(experiment_dir(cfg), "PoolSamples", "samples-" * key)
    mkpath(out)
    scenes = sort([f[1:end-5] for f in readdir(in_dir) if endswith(f, ".jld2") && !startswith(f, "_") &&
                   !endswith(f, ".residuals.jld2") && !endswith(f, "_snn.jld2")])
    for scene in scenes
        dst = joinpath(out, "$scene.samples.jld2")
        isfile(dst) && (@info "skip (exists)" scene; continue)
        p = load_pool(joinpath(in_dir, "$scene.jld2"))
        certified = try
            sample_starts(p); true
        catch e
            e isa ArgumentError || rethrow(); false
        end
        st = derive_sample_starts(p, i -> gaussian_stream(p.pairs[i].snn, m, σ, stable_seed(seed, i));
                                  max_trials = Int(pool["max_trials"]))
        save_sample_starts(dst, p, st;
            derivation = "replay: POOL_RNG(stable_seed($seed, i)), Gaussian-SNN σ = $σ, keys U^(1/w) (RVG 0.23)",
            provenance = Dict{String,Any}("driver" => "derive_pool_samples.jl", "pool_config_key" => key,
                                          "structural_certified" => certified))
        @info "derived" scene pairs = length(p.pairs) samples = sum(length, st) structural_certified = certified
        p = nothing; GC.gc()
    end
    write_run_records(out, cfg; driver = "scripts/tools/derive_pool_samples.jl", config_source, key,
                      inputs = [in_dir])
    return out
end

if abspath(PROGRAM_FILE) == @__FILE__
    start_output_flush!()
    name = cli_option(ARGS, "config", "")
    isempty(name) && error("derive_pool_samples: --config=<name> is required (configs/<name>.toml)")
    path = projectdir("configs", "$name.toml")
    out = derive_pool_samples(load_run_config(path); config_source = path)
    println("DERIVE_POOL_SAMPLES_DONE ", name, " -> ", out)
end
