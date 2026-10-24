# =============================================================================
# test_experiment_producer.jl — CPU smoke test of the streamed experiment
# producer (src/experiment_producer.jl): the miscalibration, sample-budget and
# well-depth sweeps run end to end on the composition evaluator's
# `stream_selections` over the KernelAbstractions CPU backend, each selector
# contributing its selection row, every grid realized from a
# `windowed_bootstrap` tuning spec, and the M-bundle written through the
# tuning-artifact writer (the spec, the grid specs, one row per label with its
# native axis); the offline renderer summarizes that bundle.
# (Production runs on CUDA over the full pools.)
# =============================================================================
using Test, Random, JLD2, DataFrames
using VisualGeometryToolkitEstimation: EssentialProblem
using RANSACScoringDoneRight: RANSACScoringDoneRight
using VisualGeometryToolkitCore: WelschShape
using VisualGeometryToolkitEval.Tuning: tuning_spec, load_tuning_artifact, grid
using VisualGeometryToolkitEval.Pools: synthetic_e_pool_pair, PoolResiduals

include(joinpath(@__DIR__, "..", "src", "experiment_producer.jl"))
include(joinpath(@__DIR__, "..", "src", "plot_lo_sensitivity.jl"))   # compute_summary

@testset "experiment producer (CPU streaming)" begin
    # n = 100 GT inliers: above the validation-scale floor
    # (configs/protocol.toml [scale_estimation] min_gt_inliers_for_scale = 80)
    made = [synthetic_e_pool_pair(MersenneTwister(s); n = 100) for s in 1:4]
    scene(r) = ((; pairs = first.(made[r])), PoolResiduals("synthetic", :tangent_sampson, last.(made[r])))
    scenes = [scene(1:2), () -> scene(3:4)]          # a loaded (pool, residuals) and a loader
    native = Dict("window" => Dict("type" => "coverage", "zeta_octaves" => 1.0),
                  "spacing" => Dict("type" => "log_count", "n" => 9))
    spec = tuning_spec(Dict("tuning" => Dict("smoke" => Dict(
        "type" => "windowed_bootstrap",
        "scale_multiple_window" => Dict("lo" => 1.0, "hi" => 3.3),
        "outlier_halfwidth" => native, "loss_width" => native,
        "scale_multiple" => Dict("spacing" => Dict("type" => "linear_count", "n" => 5)),
        "budget_sampling" => Dict("n_draws" => 20, "sizes" => [1, 2]),
        "cross_validation" => Dict("scene_split" => Dict("type" => "registered", "name" => "phototourism"))))), "smoke")
    kw = (; problem_type = EssentialProblem, spec,
          backend = RANSACScoringDoneRight.KernelAbstractions.CPU())
    path = tempname() * ".jld2"
    mc = miscalibration_sweep(scenes, 1, [0.5, 1.0, 2.0]; batch = 1,
                              save_bundle = path, kw...)
    @test mc.zetas == [0.5, 1.0, 2.0] && mc.n == 2
    b = load_tuning_artifact(path)
    @test b.spec == spec && b["mode"] == "miscal" && b["labels"] == ["IG  sel", "MSAC sel"]
    @test b["label_axis"] == Dict("IG  sel" => "outlier_halfwidth", "MSAC sel" => "loss_width")
    @test length(b.grids[:outlier_halfwidth]) == 9 && length(b.grids[:scale_multiple]) == 5
    @test b.grids[:scale_multiple] == grid(b.grid_specs[:scale_multiple])
    @test size.(b["M"]["IG  sel"]) == [(2, 9), (2, 9)]
    @test all(M -> all(isfinite, M), b["M"]["IG  sel"])
    # the offline renderer's summary (plot_lo_sensitivity.jl): the fixed-width
    # evaluation, one row per (selector, ζ), re-bootstrapped from the bundle alone
    mode, df = compute_summary(b)
    @test mode == "miscal" && nrow(df) == 2 * 3
    @test Set(df.method) == Set(["IG  sel", "MSAC sel"]) && all(isfinite, df.mean_med)
    rm(path; force = true)
    # a ζ ladder the coverage window does not reach is refused
    @test_throws ArgumentError miscalibration_sweep(scenes, 1, [0.25, 4.0]; batch = 1, kw...)

    # batching is pair-local: one batch per pair == the whole scene at once
    nn1 = lo_sensitivity_sweep(scenes, 1; batch = 1, kw...)
    nn2 = lo_sensitivity_sweep(scenes, 1; batch = 4, kw...)
    @test nn1.M == nn2.M && size(nn1.M["MSAC sel"]) == (4, 9)
    # the bundles are selection-only: no LO knob exists to request a refit
    @test_throws MethodError lo_sensitivity_sweep(scenes, 1; batch = 2, los = [:tmix], kw...)

    ds = delta_sweep(scenes, 1, WelschShape(), [0.5, 2.0]; NG = 33, batch = 2, kw...)
    @test Set(keys(ds.M)) == Set(["IG  sel", "MSAC sel", "Δ=0.5 sel", "Δ=2.0 sel"])
    @test size(ds.M["Δ=2.0 sel"]) == (4, 9)
end
