# =============================================================================
# test_lo_contracts.jl — LO-strategy contract tests, on the repository's
# two-view fixture (two_view_scene.jl):
#   • production Gnc{Irls{K}}: ctor validation, the update budget, end-to-end
#     refinement through locally_optimize (all three variants) read on the
#     data fit,
#   • consensus-anchored width: corrupting the deployed native barely moves
#     the GNC arms (the leak-dead property, like the Welsch HQ lift),
#   • the Welsch HQ lift's basin against the Stu-tU IRLS.
# (The composition evaluator's contracts are VisualGeometryToolkitEval's suite's; its
# integration with these arms and scorers is test_engine_integration.jl.)
# =============================================================================

import VisualGeometryToolkitCore as VgtkCore
import VisualGeometryToolkitEstimation as VgtkEstimation
using Test, Random, LinearAlgebra, StaticArrays
using VisualGeometryToolkitEstimation
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: Synthetic, Csponds, consensus_set, residuals!, estimate, iterations, lo_width,
    minimal_sample_size, codimension
using VisualGeometryToolkitEstimation: consensus_s2!
using RansacScoringDoneRight: StudentTUniformScoring

# The evaluator + the paper config.
using VisualGeometryToolkitEval.Evaluation: perturbed_seed_E
include(joinpath(@__DIR__, "..", "src", "config.jl"))
include(joinpath(@__DIR__, "two_view_scene.jl"))

# One seeded scene shared by every test: the repository's two-view fixture on
# the narrow field of view, its 51 outliers inside both images.
const _LOC = two_view_scene(; fov = :narrow)
_loc_seed_E(δ; seed) = perturbed_seed_E(MersenneTwister(seed), _LOC.R, _LOC.t, δ)
const _LOC_A = 0.05                        # operating half-width of the scene
# The scene's calibrated plane points through the identity camera: the one
# E-problem construction (unit bearings by back-projection).
const _LOC_PROB = EssentialProblem(CameraModel(SMatrix{3, 3, Float64, 9}(I)), CameraModel(SMatrix{3, 3, Float64, 9}(I)),
                                   Csponds(_LOC.w1, _LOC.w2))

# Symbol → wrapped-strategy map for the three GNC arms (the historical
# per-variant construction sites). `scale_multiple` has no mechanism default
# (a problem-class operating point; without a width the strategy follows the
# scorer's) — the helper supplies the historical parity point 2.5 so the
# contract scenes stay put.
_gnc(v::Symbol; scale_multiple = 2.5, kw...) =
    v === :welsch ? Gnc{Irls{WelschShape}}(; scale_multiple, kw...) :
    v === :tls ? Gnc{Irls{TLSShape}}(; scale_multiple, kw...) :
    Gnc{Irls{GemanMcclureShape}}(; scale_multiple, kw...)

# What a local optimization optimizes is the fit to the data, so the contracts
# read the fit, not the pose: on this narrow field of view the translation
# direction is barely determined by the data (a model 10° from the truth in
# imc explains all 120 inliers at a cost within 3 % of the truth's), so an imc
# assertion would test the scene, not the arm. `_fit(E)` = (true inliers within
# 3σ of E, the truncated cost Σ min(r², (3σ)²) over all points); σ = 0.002.
const _NIN = 120
# The scoring a contract run refines under: the Jeffreys Student-t + uniform
# marginal at outlier half-width `h` (the paper's selection scorer).
_marginal(h) = StudentTUniformScoring(_LOC_PROB, h)
function _fit(E)
    r = Vector{Float64}(undef, length(_LOC.w1))
    residuals!(r, _LOC_PROB, E)
    θ = 3 * 0.002
    return (inliers = count(<(θ), view(r, 1:_NIN)), cost = sum(x -> min(x^2, θ^2), r))
end

@testset "LO-strategy contracts" begin

    prob = _LOC_PROB

    # -------------------------------------------------------------------------
    # 1. Production Gnc{Irls{K}}: ctor validation (semantics preserved from the
    #    retired eval engine; variant legality is TYPE-level now — the wrapper
    #    admits any strategy, the engine's variant lookup refuses non-Irls).
    # -------------------------------------------------------------------------
    @testset "Gnc ctor validation" begin
        # no mechanism default on the ctor: without a width the strategy follows the scorer's
        @test lo_width(Gnc{Irls{WelschShape}}()) === nothing
        @test lo_width(_gnc(:welsch)).value == 2.5
        # graduation over the lift is refused at construction (the engine
        # graduates Irls{K} only)
        @test_throws ArgumentError Gnc{HQ{WelschShape}}(scale_multiple = 2.5)
        @test_throws ErrorException _gnc(:welsch, budget = :bar)
        # the GM/TLS μ is a convexity parameter, not a width — numeric entry refuses
        # (the entry policy's μ₀ values are VisualGeometryToolkitCore's `gnc_entry_mu0`,
        # tested there)
        @test_throws ErrorException _gnc(:gm, entry = 4.0)
        @test VgtkCore.scale_interface(_gnc(:welsch)) isa VgtkCore.ConsensusAnchored
        @test lo_width(_gnc(:tls)) isa ScaleMultiple   # a width read off the consensus scale
    end

    # -------------------------------------------------------------------------
    # 2. End-to-end through the production port: every variant respects the
    #    model-update budget (the protocol cap counts EVERY GNC stage — the estimate's
    #    `iterations`, read through the public LO extension point on the seed's
    #    own consensus set) and, from a near (δ = 0.02) or a far (δ = 0.2) seed,
    #    lowers the truncated cost and recovers ≥ 95 % of the inliers.
    #    Measured (seeds 14, 15): inliers 115–120 of 120 for every variant and
    #    both δ, from 0–5 (δ = 0.2) or 120 (δ = 0.02) at the seed. Seeds with
    #    no consensus at `a` (11–13, 16 at δ = 0.2) never reach
    #    the LO — the port returns them unchanged — so they test nothing here.
    #    (The old fixture's @test_broken — GNC-TLS from a 12.8° seed landing at
    #    27.8° imc — measured the scene: its outliers lay outside the image, and
    #    imc is not what an LO optimizes; see `_fit`.)
    # -------------------------------------------------------------------------
    @testset "Gnc end-to-end + budget: $v" for v in (:welsch, :tls, :gm)
        sc = StudentTUniformScoring(prob, _LOC_A)
        for δ in (0.02, 0.2), s in (14, 15)
            E0 = _loc_seed_E(δ; seed = s)
            lo = _gnc(v, max_iter = LO_BUDGET)
            ws = VgtkEstimation.RansacWorkspace(prob, sc, lo)
            # the seed's score on the workspace buffers, and its consensus set
            @test consensus_s2!(ws, prob, sc, E0) !== nothing
            cs = consensus_set(sc, ws.buf.scoring_ws, ws.buf.residuals; model_dof = minimal_sample_size(prob) + 1,
                               d_g = codimension(prob), epoch = ws.buf.epoch)
            est = VgtkCore.locally_optimize!(ws.lo_ws, lo, prob, E0, cs, ws.buf, sc)
            @test estimate(est) isa EssentialMat
            @test iterations(est) <= lo.max_iter
            r = locally_optimize(prob, E0; scoring = _marginal(_LOC_A), local_optimization = lo)
            f0, f = _fit(E0), _fit(r.estimate)
            @test f.cost < f0.cost
            @test f.inliers >= 0.95 * _NIN
        end
    end

    # The deployed GNC-W (scale_multiple = 1.5, the protocol's entry: the anneal completes within the
    # update budget) from far seeds. Measured: δ = 0.1 seeds 14/15 and
    # δ = 0.2 seed 15 recover 120/120 inliers (from 18, 85 and 5); δ = 0.2 seed
    # 14 lands in a wrong basin (67/120 from 0), still lowering the cost — a
    # 0.2-rad seed is not inside every basin, so it is asserted on the cost only.
    @testset "Gnc deployed config improves a far seed" begin
        lo = _gnc(:welsch, max_iter = LO_BUDGET, scale_multiple = 1.5, entry = _GNC_ENTRY)
        for (δ, s) in ((0.1, 14), (0.1, 15), (0.2, 14), (0.2, 15))
            E0 = _loc_seed_E(δ; seed = s)
            r = locally_optimize(prob, E0; scoring = _marginal(_LOC_A), local_optimization = lo)
            f0, f = _fit(E0), _fit(r.estimate)
            @test f.cost < f0.cost
            (δ, s) == (0.2, 14) || @test f.inliers >= 0.95 * _NIN
        end
    end

    # -------------------------------------------------------------------------
    # 3. Leak-dead: the width is consensus-anchored — corrupting the deployed
    #    half-width 128× must barely move the GNC arms from a NEAR seed (the
    #    consensus set stays inlier-dominated, so ŝ barely moves). Read on the fit:
    #    both runs explain ≥ 90 % of the inliers and their truncated costs agree
    #    within 15 %. Measured over seeds 11–16: inliers ≥ 109/120, the largest
    #    cost gap 12 % (GNC-TLS, seed 13; every other run ≤ 4 %).
    # -------------------------------------------------------------------------
    @testset "consensus-anchored width (native corruption)" begin
        for v in (:welsch, :tls, :gm), s in 11:16
            E0 = _loc_seed_E(0.02; seed = s)
            lo = _gnc(v, max_iter = LO_BUDGET)
            f1 = _fit(locally_optimize(prob, E0; scoring = _marginal(_LOC_A), local_optimization = lo).estimate)
            f128 = _fit(locally_optimize(prob, E0; scoring = _marginal(128 * _LOC_A), local_optimization = lo).estimate)
            @test min(f1.inliers, f128.inliers) >= 0.9 * _NIN
            @test abs(f128.cost - f1.cost) <= 0.15 * f1.cost
        end
    end

    # -------------------------------------------------------------------------
    # 4. The lift's basin (the evaluation of the retired _research/_lift_basin_smoke.jl):
    #    at δ = 0.15 (8.6°) the Welsch HQ lift recovers ≥ 95 % of the inliers on
    #    every seed with a consensus at `a`, where the Stu-tU
    #    IRLS does not. Measured, seeds 14 / 15: lift 116 / 116, IRLS 107 / 93
    #    (seeds 11–13, 16 hold no consensus at δ = 0.15; at δ ≥ 0.3 none does).
    # -------------------------------------------------------------------------
    @testset "Welsch HQ lift basin" begin
        for s in (14, 15)
            E0 = _loc_seed_E(0.15; seed = s)
            run(lo) = _fit(locally_optimize(prob, E0; scoring = _marginal(_LOC_A), local_optimization = lo).estimate)
            lift, irls = run(HQ{WelschShape}(max_iter = LO_BUDGET, scale_multiple = 1.0)), run(StudentTUniform(max_iter = LO_BUDGET))
            @test lift.inliers >= 0.95 * _NIN
            @test lift.inliers > irls.inliers
        end
    end
end
