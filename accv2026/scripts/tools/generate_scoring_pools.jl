#!/usr/bin/env julia
# =============================================================================
# generate_scoring_pools.jl — THE two-view scoring-pool driver: glue only.
#
#   julia --project=. -t auto scripts/tools/generate_scoring_pools.jl --config=pt_e_pools
#
# configs/<name>.toml states everything: the dataset reader and its raw roots
# ([source]), the problem and output tree ([experiment]), and every generation
# constant ([pool]). A raw pair (VisualGeometryToolkitEval.Datasets, pixels) becomes a
# pool pair through VisualGeometryToolkitEstimation's `PoolPair(hypotheses, problem, raw;
# variance)` on a PIXEL-frame problem carrying the pool's sampler; one scene is
# written by VisualGeometryToolkitEval's `write_scene_pool` (threads, per-pair seeds,
# skip-existing, the light file and its residuals). Per dataset:
#   phototourism — σ̂² over the SfM-track keypoints (`TrackVariance`), the
#                  reader's pixel-Sampson GT mask;
#   heb          — σ̂² over the GT inliers (`InlierVariance`), H solved in the
#                  calibrated chart through labelled K⁻¹ maps;
#   roma         — σ̂² over the GT inliers, at least a minimal sample of them.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using VisualGeometryToolkitEval: cli_option, start_output_flush!
using VisualGeometryToolkitEval.Datasets: PtRawTrees, PT_SCENES, load_pt_pairs, load_heb_pairs, RomaPair,
    load_roma_pairs
using VisualGeometryToolkitEval.Pools: write_scene_pool
using VisualGeometryToolkitEval.Experiments: load_run_config, data_root
using VisualGeometryToolkitEstimation: EssentialProblem, FundMatProblem, HomographyProblem, GaussianSampler,
    ProsacSampler, UniformSampler, draw_hypotheses, TrackVariance, InlierVariance, minimal_sample_size
using VisualGeometryToolkitCore: CameraModel, HomographyMap, UnlabeledFrame, GnomonicFrame
using VisualGeometryToolkitCore.Pools: PoolPair, pair_csponds, pair_snn, pair_K1, pair_K2
using StaticArrays: SMatrix
include(srcdir("validation_data.jl"))   # split_scenes

const _PROBLEMS = Dict(:E => EssentialProblem, :F => FundMatProblem, :H => HomographyProblem)

# The pool's minimal-sample sampler over the raw SNN (low = good).
function pool_sampler(pool, snn, mss)
    s = Symbol(pool["sampler"])
    s === :gaussian && return GaussianSampler(Float64.(snn); snn_sigma = Float64(pool["gaussian_sigma"]))
    s === :prosac && return ProsacSampler(sortperm(Float64.(snn)), mss; T_N = Int(pool["prosac_T_N"]))
    s === :uniform && return UniformSampler(length(snn))
    error("[pool] sampler = $s: expected gaussian | prosac | uniform")
end

# The PIXEL-frame generation problem of a raw pair (csponds Float64, the sampler on the problem).
function generation_problem(P, raw, pool)
    cs, sampler = pair_csponds(raw), pool_sampler(pool, pair_snn(raw), minimal_sample_size(P))
    P === EssentialProblem && return EssentialProblem(CameraModel(pair_K1(raw)), CameraModel(pair_K2(raw)), cs; sampler)
    P === FundMatProblem && return FundMatProblem(cs; sampler)
    # A HEB homography is solved in the calibrated chart: K⁻¹ measurement maps labelled into it.
    raw isa RomaPair && return HomographyProblem(cs; sampler)
    K⁻¹(K, side) = HomographyMap{UnlabeledFrame{2}, GnomonicFrame{side}}(SMatrix{3,3,Float64,9}(inv(K)))
    return HomographyProblem(cs; sampler, src_map = K⁻¹(pair_K1(raw), :src), dst_map = K⁻¹(pair_K2(raw), :dst),
                             model_frames = (GnomonicFrame{:src}, GnomonicFrame{:dst}))
end

# σ̂²: the SfM-track keypoints (PhotoTourism), else the GT inliers.
pool_variance(dataset, P, raw, pool) =
    dataset == "phototourism" ? TrackVariance(raw.track_kpts_A, raw.track_kpts_B) :
    InlierVariance(; min_inliers = dataset == "heb" ? Int(pool["min_gt_inliers"]) : minimal_sample_size(P))

"`build(rng, raw)` of `write_scene_pool` for the config's dataset and problem."
pair_builder(dataset, P, pool) = (rng, raw) -> begin
    problem = generation_problem(P, raw, pool)
    hyps = draw_hypotheses(rng, problem; target = Int(pool["target"]), max_trials = Int(pool["max_trials"]))
    pair, R = PoolPair(hyps, problem, raw; variance = pool_variance(dataset, P, raw, pool))
    (; pair, residuals = R, samples = hyps.samples_accepted, solutions = hyps.n_solutions)
end

"The raw pairs of `scene` (pixels), read as the config's [source] and [pool] state."
function raw_pairs(cfg, scene)
    src, pool = cfg["source"], cfg["pool"]
    sub = (; min_csponds = Int(pool["min_csponds"]), max_pairs_per_scene = Int(pool["max_pairs_per_scene"]),
           subsample_overdraw = Int(pool["subsample_overdraw"]), subsample_seed = Int(pool["subsample_seed"]))
    root(k) = joinpath(data_root(), src[k])
    route = get(src, "route", cfg["experiment"]["dataset"])
    if route == "phototourism"
        trees = PtRawTrees(; (Symbol(chop(k; tail = 4)) => root(k) for k in keys(src) if endswith(k, "_dir"))...,
                           recon_special = Dict{String,String}(k => joinpath(data_root(), v)
                                                               for (k, v) in get(src, "recon_special", Dict())))
        return load_pt_pairs(scene, Dict(PT_SCENES)[scene]; trees, sub...)
    elseif route == "heb"
        return load_heb_pairs(joinpath(root("raw_dir"), "$(scene)_homographies.h5"); sub...)
    elseif route == "roma"
        return load_roma_pairs(joinpath(root("input_jld2_dir"), "$(scene).jld2"))
    end
    error("[source] route = $route: expected phototourism | heb | roma")
end

"Generate (or skip) every scene of the config's splits into `out_dir`."
function generate_scoring_pools(cfg; out_dir = joinpath(data_root(), cfg["experiment"]["pool_dir"]),
                                scenes = sort(unique(reduce(vcat, split_scenes.(cfg["source"]["splits"])))),
                                limit = nothing)
    ex, pool = cfg["experiment"], cfg["pool"]
    cfg["source"]["image_unit"] == "px" || error("source.image_unit must be px (got $(cfg["source"]["image_unit"]))")
    P = _PROBLEMS[Symbol(ex["problem"])]
    build = pair_builder(ex["dataset"], P, pool)
    for scene in scenes
        raws = [r for r in raw_pairs(cfg, scene) if length(pair_csponds(r)) >= minimal_sample_size(P)]
        limit === nothing || (raws = raws[1:min(limit, end)])   # smoke runs only
        write_scene_pool(joinpath(out_dir, "$scene.jld2"), raws, build; problem = Symbol(ex["problem"]),
                         residual_kind = P === EssentialProblem ? :tangent_sampson : :sampson,
                         seed = Int(pool["pool_seed"]),
                         provenance = Dict{String,Any}("driver" => "generate_scoring_pools.jl", "pool" => pool))
    end
    return out_dir
end

if abspath(PROGRAM_FILE) == @__FILE__
    start_output_flush!()
    name = cli_option(ARGS, "config", "")
    isempty(name) && error("generate_scoring_pools: --config=<name> is required (configs/<name>.toml)")
    out = generate_scoring_pools(load_run_config(projectdir("configs", "$name.toml")))
    println("GENERATE_SCORING_POOLS_DONE ", name, " -> ", out)
end
