# =============================================================================
# The PoseLib truncated refiners (src/poselib_arms.jl, their solver calls in
# ext/LocalOptimizationDoneRightPoseLibExt.jl): identity traits, the
# external-refit contract they implement, the E-branch pose refine as an
# algorithm (`TruncatedRefit`), and the adaptive arm's within-width scale moment. Their integration with the composition evaluator
# (VisualGeometryToolkitEval.Evaluation) and the paper's scorer is
# accv2026/test/test_engine_integration.jl.
# =============================================================================
using Test
using LinearAlgebra: I
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LocalOptimizationDoneRight as LODR, PoseLibLm, PoseLibLZ, PoseLibLmAdaptLossWidth,
    TruncatedRefit
import PoseLib
import VisualGeometryToolkitCore
using VisualGeometryToolkitCore: AbstractOptimizationStrategy, RefitFamily, ExternalRefit, FixedScale, ConsensusAnchored,
    LossWidth, FixedS2, scale_interface, optimization_path, lo_label, external_workspace, external_refit!,
    prepare_external!, Correspondences, Point2, withattrs, CameraModel, EssentialMat, EuclideanMap, RefineProblem,
    RefineKind, estimator_kind, solve
using VisualGeometryToolkitEstimation: EssentialProblem
using StaticArrays: SMatrix
using Random: Xoshiro
# the seeded E scene of the stack's LO benches (`essential_bench_scene`, VisualGeometryToolkitCore's)
include(joinpath(pkgdir(VisualGeometryToolkitCore), "test", "lo_timing", "bench_record.jl"))

const _EXT = Base.get_extension(LODR, :LocalOptimizationDoneRightPoseLibExt)

@testset "PoseLib truncated refiners: identity" begin
    @test _EXT isa Module                                    # loading PoseLib loads the solver calls
    @test PoseLibLm(25) isa AbstractOptimizationStrategy && PoseLibLZ(25) isa AbstractOptimizationStrategy
    for lo in (PoseLibLm(25), PoseLibLZ(25), PoseLibLmAdaptLossWidth())
        @test RefitFamily(lo) isa ExternalRefit
    end
    @test scale_interface(PoseLibLZ(25)) isa FixedScale && scale_interface(PoseLibLm(25)) isa FixedScale
    @test scale_interface(PoseLibLmAdaptLossWidth()) isa ConsensusAnchored
    @test optimization_path(PoseLibLm(25)) === :irls && optimization_path(PoseLibLZ(25)) === :gnc
    @test lo_label(PoseLibLm(25)) == "TLS-IRLS" && lo_label(PoseLibLZ(25)) == "TLS-LZ"
    # the library's own types
    @test parentmodule(PoseLibLm) === LODR && parentmodule(PoseLibLZ) === LODR
    # the external-refit contract, implemented by the extension at an absolute loss width
    @test any(m -> m.sig <: Tuple{typeof(external_refit!), Any, Union{PoseLibLm, PoseLibLZ}, Any, Any, LossWidth, Any},
              methods(external_refit!))
    @test any(m -> m.sig <: Tuple{typeof(prepare_external!), Any, PoseLibLmAdaptLossWidth, Any, Any, FixedS2, Any},
              methods(prepare_external!))
end

@testset "truncated-moment scale plug-in" begin
    tm = _EXT._truncated_moment_s2
    r = [1.0, -1.0, 1.5, 0.5, 2.0, 1.0, 0.5, 1.0]
    @test tm(2.0, r) ≈ 10.75 / 8                       # |r| ≤ loss width INCLUSIVE
    @test tm(1.0, vcat(r, fill(50.0, 3)); min_support = 4) ≈ (1.0 + 1.0 + 0.25 + 1.0 + 0.25 + 1.0) / 6
    @test tm(2.0, r[1:7]) === nothing                  # thin consensus, default min_support = 8
    @test tm(0.75, r) === nothing
    @test tm(2.0, r[1:7]; min_support = 7) ≈ (10.75 - 1.0) / 7
end

@testset "the adaptive arm's width is VGC's TLS deployment" begin
    lw = _EXT._adapt_loss_width
    for m in (2.5, 1.0, 3.7), s2 in (0.0, 1.0e-6, 0.37, 4.0)
        lo = PoseLibLmAdaptLossWidth(efficiency_constant = m)
        @test lw(lo, s2) === m * sqrt(max(s2, eps()))      # bit-identical to the width it replaced
    end
    # the moment is VGC's Jeffreys scale estimator: floored at eps, never 0
    @test _EXT._truncated_moment_s2(1.0, zeros(8)) === eps()
end

# LODR#7 (wave-10 catch-up review): the workspace holds the frame's correspondences as given — any layout the
# external-refit contract admits (attribute columns, another element type), not one concrete Correspondences type.
@testset "PoseLib workspace: the frame's correspondences as given" begin
    K = SMatrix{3, 3, Float64, 9}(1.0I)
    x = [Point2(0.1i, -0.2i) for i in 1:8]
    plain = Correspondences(x, x)
    for cs in (plain, withattrs(plain; weights = fill(1.0, 8)), Correspondences(Point2{Float32}.(x), Point2{Float32}.(x)))
        ws = external_workspace(PoseLibLm(25), nothing, (; Kc1 = K, Kc2 = K, cs), nothing)
        @test ws.cs === cs && ws.Kc1 === K
    end
end

# The E-branch body as an algorithm: `TruncatedRefit(lo)` on the problem, the seed and the two-view frame,
# at an absolute pool-frame loss width (the solve keyword `width`); the E external refit is the same body.
@testset "TruncatedRefit: the truncated refiner's pose refine" begin
    @test estimator_kind(TruncatedRefit(PoseLibLm(25))) isa RefineKind
    sc = essential_bench_scene(Xoshiro(20261125); n = 300)
    cs = Correspondences(sc.u₁, sc.u₂)
    problem = EssentialProblem(CameraModel(sc.K), CameraModel(sc.K), cs)
    frame = (; Kc1 = sc.K, Kc2 = sc.K, cs)
    seed = EssentialMat(sc.R, sc.t)
    for lo in (PoseLibLm(25), PoseLibLZ(25))
        r = solve(RefineProblem(problem, seed, frame), TruncatedRefit(lo); width = 3.0)
        @test r.u isa EuclideanMap && r.alg === TruncatedRefit(lo) && r.prob.f === problem
        @test maximum(abs, r.u.R - sc.R) < 1.0e-2                  # 0.5 px noise, 30 % outliers truncated
        ws = external_workspace(lo, problem, frame, nothing)
        @test external_refit!(ws, lo, problem, seed, LossWidth(3.0), nothing) === EssentialMat(r.u.R, r.u.t)
    end
end
