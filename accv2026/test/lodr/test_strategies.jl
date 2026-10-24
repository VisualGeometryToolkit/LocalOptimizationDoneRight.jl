# =============================================================================
# The strategies on VisualGeometryToolkitCore's contracts: the weight policies they
# iterate (verbs present, normalized or not), the refit family, the width
# setter, the loss a consensus-anchored strategy deploys, and the
# local-optimization contract checked by its owner's conformance helper.
# (Moved from VisualGeometryToolkitEstimation's test/estimation_interfaces_tests.jl and
# test/contract_conformance_tests.jl with the strategies; the core's
# strategies keep those tests there.)
# =============================================================================
import VisualGeometryToolkitCore as VgtkCore
using Test, Random, LinearAlgebra, StaticArrays
using Rotations: RotY
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: AbstractWeightPolicy, NormalizedWeightPolicy, RefitFamily, NativeRefit,
    update_nuisance!, update_weights!, lo_width, with_width, LossWidth, ScaleMultiple, FixedScale,
    consensus_set, score_model!, scale_s2, csponds, estimate, converged, codimension, minimal_sample_size,
    test_local_optimization_contract, MsacScoring, WelschShape, GemanMcclureShape, TLSShape
using RANSACScoringDoneRight: StudentTUniformScoring
using VisualGeometryToolkitEstimation
using VisualGeometryToolkitEstimation: RansacConfig, RansacWorkspace, PosteriorLikelihood
using LocalOptimizationDoneRight
const RVG = VisualGeometryToolkitEstimation
const LO = LocalOptimizationDoneRight
include("scenes.jl")   # the shared scenes, as modules
using .HomographyScenes, .EpipolarScenes

@testset "weight-policy verbs available per adapter" begin
    for T in (LO.BarronAdaptiveLikelihood, LO.FixedWelschScale, LO.WelschEcmScale,
              LO.LiftedMixtureLikelihood, LO.LiftedReGeMMLikelihood)
        @test hasmethod(update_nuisance!, Tuple{T})
        @test hasmethod(update_weights!, Tuple{T})
    end
end

@testset "NormalizedWeightPolicy membership (the ρ(∞)=∞ boundary)" begin
    # Proper normalized probability models (t/uniform mixture family): yes.
    for T in (PosteriorLikelihood, LO.LiftedMixtureLikelihood, LO.LiftedReGeMMLikelihood)
        @test T <: NormalizedWeightPolicy
    end
    # Loss-derived reweighting rules (bounded potentials / frozen scale): no.
    for T in (LO.BarronAdaptiveLikelihood, LO.FixedWelschScale, LO.WelschEcmScale)
        @test T <: AbstractWeightPolicy
        @test !(T <: NormalizedWeightPolicy)
    end
end

@testset "RefitFamily routing (VGC trait)" begin
    # VGC default: every strategy is NativeRefit unless it declares otherwise.
    @test RefitFamily(StudentTUniform()) isa NativeRefit
    @test RefitFamily(HQ{WelschShape}(scale_multiple = 1.597)) isa NativeRefit
    @test RefitFamily(StuTuBCD()) isa NativeRefit
end

# -------------------------------------------------------------------------
# with_width — the SET accessor paired with `lo_width`/`scale_interface`:
# one strategy per CONSTRUCTOR SHAPE (parametric, plain-keyword,
# positional-then-keyword, validating), the width mode moved and everything
# else not.
# -------------------------------------------------------------------------
@testset "with_width sets the width mode and preserves every other field" begin
    strategies = Any[
        HQ{GemanMcclureShape}(scale_multiple = 1.25, max_iter = 7, init = :posterior),   # parametric
        WelschHQNewton(scale_multiple = 1.5, μ = 2.0e-9),                               # plain keyword
        BarronHQ(-2.0; scale_multiple = 1.5, max_iter = 9),                             # positional α
        Gnc{Irls{WelschShape}}(scale_multiple = 2.5, factor = 1.7, budget = :converged),
        BarronAdaptive(scale_multiple = 1.5, n_sub = 64),
        GmHqEps(scale_multiple = 0.75, max_iter = 33),
    ]
    for lo in strategies
        @test lo_width(lo) isa ScaleMultiple
        @test VgtkCore.scale_interface(lo) == VgtkCore.ConsensusAnchored()
        out = with_width(lo, LossWidth(0.25))
        @test typeof(out).name === typeof(lo).name
        @test lo_width(out) == LossWidth(0.25)
        @test VgtkCore.scale_interface(out) == FixedScale()
        for f in fieldnames(typeof(lo))
            f === :width && continue
            @test isequal(getfield(out, f), getfield(lo, f))
        end
        # and back: the multiple restored is the strategy constructed with it
        @test with_width(out, lo_width(lo)) == lo
    end
    # A strategy whose scale interface is INTRINSIC to the type carries no
    # width mode, implements no setter — which is correct, not a gap: there
    # is no field to set.
    @test lo_width(WelschHQEcm(scale_multiple = 1.5)) === missing
    @test_throws MethodError with_width(WelschHQEcm(scale_multiple = 1.5), LossWidth(1.0))
end

@testset "a consensus-anchored lift deploys the fresh set's scale" begin
    problem = HomographyProblem(csponds(homography_pairs(MersenneTwister(7), H_TRUE; n_in = 40, n_out = 10, σ = 0.3)...))
    scoring = StudentTUniformScoring(problem, 20.0)
    ws = RansacWorkspace(problem, scoring, StudentTUniform())
    buf = ws.buf
    model = first(solve(problem, [1, 2, 3, 4]))
    score_model!(buf, scoring, problem, model)
    cs = consensus_set(scoring, buf.scoring_ws, buf.residuals;
                       model_dof = minimal_sample_size(problem) + 1, d_g = codimension(problem), epoch = buf.epoch)
    # through the owner, VGC's `loss_at` (here via the core's `lo_loss`)
    @test scale_s2(RVG.lo_loss(HQ{WelschShape}(scale_multiple = 1.0), cs, scoring, buf)) == max(scale_s2(cs), eps())
end

# The local-optimization contract on the strategies this package hosts
# (VisualGeometryToolkitCore's helper; `allocations = false` for now, as for the
# core's strategies).
fitted(p, halfwidth; seed = 1) =
    estimate(ransac(p, StudentTUniformScoring(p, halfwidth); config = RansacConfig(max_trials = 300), rng = MersenneTwister(seed)))

@testset "local-optimization contract: the hosted strategies (H scene)" begin
    p = HomographyProblem(csponds(homography_pairs(MersenneTwister(7), H_TRUE; n_in = 80, n_out = 20, σ = 0.5)...))
    θ = fitted(p, 50.0)
    msac = MsacScoring(p; threshold = 3.0)
    stu = StudentTUniformScoring(p, 50.0)
    for (lo, sc) in (
            (HQ{WelschShape}(scale_multiple = 1.5), msac),
            (Gnc{Irls{TLSShape}}(scale_multiple = 2.5), msac),
            (StudentTUniform(), stu),                              # needs the scorer's outlier model
            (HQ{WelschShape}(scale_multiple = 1.5), stu),
            (StuTuBCD(), stu),
        )
        test_local_optimization_contract(lo, p, θ, sc; allocations = false)
    end
end

@testset "local-optimization contract: the hosted strategies (E scene)" begin
    u₁, u₂ = calibrated_pairs(MersenneTwister(11), RotY(0.25), normalize(SA[0.6, -0.15, 0.35]);
                              n = 110, σ = 0.001, outlier_every = 12)
    p = ecs(u₁, u₂)                                              # E in ECAM's pixels
    θ = fitted(p, 40.0)
    msac = MsacScoring(p; threshold = 2.0)
    stu = StudentTUniformScoring(p, 40.0)
    for (lo, sc) in (
            (HQ{WelschShape}(scale_multiple = 1.5), msac),
            (Gnc{Irls{TLSShape}}(scale_multiple = 2.5), msac),
            (StudentTUniform(), stu),
        )
        test_local_optimization_contract(lo, p, θ, sc; allocations = false)
    end
end
