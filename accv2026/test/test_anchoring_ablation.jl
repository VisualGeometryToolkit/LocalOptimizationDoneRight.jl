# =============================================================================
# test_anchoring_ablation.jl — the consensus-anchoring figure is a PAIRED
# ablation of ONE tuning (scripts/fig_anchoring.jl):
#   • the WITHOUT evaluation of the figure's deployed arms really runs at the
#     fixed external plug-in scale (a ζ change moves the loss width) and is
#     otherwise the WITH evaluation (same seeds, natives and LO);
#   • WITH is the production evaluation, untouched;
#   • the ablation's scale interface is declared in configs/miscal_protocol.toml
#     and names the evaluation's directory; `--plan` lists the evaluation stage.
# On VisualGeometryEval's synthetic E pool pair (real pools are not on the test host).
# =============================================================================
using Test, Random, TOML
using RobustVisualGeometry: EssentialProblem
using VisualGeometryEval.Evaluation: miscal_evaluation_refit, apply_lo_refits, build_pair_ctx,
    refit_imc!, refit_seed
using VisualGeometryCore: ScaleMultiple, FixedScale, SCALE_INTERFACE_TAGS
using RansacScoringDoneRight: StudentTUniformScoring
using VisualGeometryEval.Pools: synthetic_e_pool_pair
include(joinpath(@__DIR__, "..", "src", "config.jl"))   # the paper's arm roster (ROSTER)

@testset "consensus-anchoring ablation evaluation" begin
    root = normpath(joinpath(@__DIR__, ".."))
    # The figure's paired arms (scripts/tools/render_anchoring_paired.jl).
    drawn = ("IG  +TLSadapt", "IG  +GNC-W", "IG  +GNC-GM", PAPER_WELSCH_HQ)
    arms = [a for a in ROSTER.composed(:E) if a.base in drawn]   # the paper's roster
    @test length(arms) == length(drawn)
    @test all(a -> a.kind isa ScaleMultiple, arms)

    pair, _ = synthetic_e_pool_pair(MersenneTwister(7); sibling_counts = fill(1, 12), noise = 0.002,
                                 δ_rot = 0.2, t_jitter = 0.1, gt_variance = 4.0e-6)
    grids = Dict(:outlier_halfwidth => [0.005, 0.01, 0.02], :scale_multiple => [1.5, 2.5, 3.0])
    idxs_of = Dict(:ig => fill(Int32(3), 1, 3))
    # format 6: the tuned point is NATIVE values, read off the grids here
    tuned = (selection = grids[:outlier_halfwidth][2], width = grids[:scale_multiple][2])
    zetas = [0.25, 1.0, 4.0]
    s0 = sqrt(pair.gt_variance)                    # the plug-in (validation reference) scale
    template = StudentTUniformScoring(EssentialProblem, 1.0)   # the refit scoring template (Jeffreys)
    ctx = build_pair_ctx(EssentialProblem, pair; scoring = template)
    seed = refit_seed(ctx, pair.models[3])

    for arm in arms
        @testset "$(arm.base)" begin
            with = miscal_evaluation_refit(arm, idxs_of, tuned, zetas, grids; d_g = 1)
            without = miscal_evaluation_refit(arm, idxs_of, tuned, zetas, grids; d_g = 1, plugin_scale = s0)
            # same operating point; only the scale interface differs
            @test with.fixed_s2s === nothing
            @test without.fixed_s2s == [(ζ * s0)^2 for ζ in zetas]
            @test without.natives == with.natives && without.seedcols == with.seedcols
            M_with = only(values(apply_lo_refits(EssentialProblem, [with], [pair]; scoring = template)))
            M_without = only(values(apply_lo_refits(EssentialProblem, [without], [pair]; scoring = template)))
            @test all(isfinite, M_with) && all(isfinite, M_without)
            for j in eachindex(zetas)
                # WITH is the production refit (the arm's own anchored interface) …
                @test M_with[1, j] === first(refit_imc!(ctx, with.lo, seed, with.natives[j]))
                # … WITHOUT the same refit at the fixed external scale (ζ·s0)²
                @test M_without[1, j] === first(refit_imc!(ctx, with.lo, seed, with.natives[j];
                                                           s2 = without.fixed_s2s[j]))
            end
            # a ζ change moves the loss width: at one native, the scales of the
            # ladder's ends refit differently
            nat = with.natives[2]
            @test first(refit_imc!(ctx, with.lo, seed, nat; s2 = without.fixed_s2s[1])) !=
                  first(refit_imc!(ctx, with.lo, seed, nat; s2 = without.fixed_s2s[3]))
        end
    end

    @testset "declared in the evaluation config; listed by --plan" begin
        iface = TOML.parsefile(joinpath(root, "configs", "miscal_protocol.toml"))["anchoring_ablation"]["scale_interface"]
        @test iface == "fixed_scale" && SCALE_INTERFACE_TAGS[iface] === FixedScale
        driver = read(joinpath(root, "scripts", "tools", "run_sequential_cv.jl"), String)
        # the interface the driver delivers (it refuses any other)
        @test occursin("VisualGeometryCore.SCALE_INTERFACE_TAGS[iface] === VisualGeometryCore.FixedScale", driver)
        # scratch data and results roots: the plan resolves the keyed paths,
        # runs nothing, and so needs no data binding on this machine
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$root $(joinpath(root, "scripts", "fig_anchoring.jl")) --plan`
        out = read(addenv(cmd, "CAU_RESULTS_ROOT" => mktempdir(), "CAU_DATA_ROOT" => mktempdir()), String)
        @test occursin("evaluation", out) && occursin("render", out)
        @test occursin("anchoring_ablation-$(iface)", out)
    end
end
