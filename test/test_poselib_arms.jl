# =============================================================================
# The PoseLib truncated refiners (src/poselib_arms.jl, their solver calls in
# ext/LocalOptimizationDoneRightPoseLibExt.jl): identity traits, the
# external-refit contract they implement, and the adaptive arm's
# within-width scale moment. Their integration with the composition evaluator
# (VisualGeometryEval.Evaluation) and the paper's scorer is
# accv2026/test/test_engine_integration.jl.
# =============================================================================
using Test
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LocalOptimizationDoneRight as LODR, PoseLibLm, PoseLibLZ, PoseLibLmAdaptLossWidth
import PoseLib
using VisualGeometryCore: AbstractLocalOptimization, RefitFamily, ExternalRefit, FixedScale, ConsensusAnchored,
    LossWidth, FixedS2, scale_interface, optimization_path, lo_label, external_workspace, refine_external!,
    prepare_external!

const _EXT = Base.get_extension(LODR, :LocalOptimizationDoneRightPoseLibExt)

@testset "PoseLib truncated refiners: identity" begin
    @test _EXT isa Module                                    # loading PoseLib loads the solver calls
    @test PoseLibLm(25) isa AbstractLocalOptimization && PoseLibLZ(25) isa AbstractLocalOptimization
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
    @test any(m -> m.sig <: Tuple{typeof(refine_external!), Any, Union{PoseLibLm, PoseLibLZ}, Any, Any, LossWidth, Any},
              methods(refine_external!))
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
