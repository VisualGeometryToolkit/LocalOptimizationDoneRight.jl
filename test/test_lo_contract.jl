# R22: contract test — the local-optimization contract (`locally_optimize!`) and the block-coordinate stop contract (`stop_reason`, `block_coordinate_result`) of this package's strategies
# =============================================================================
# The §14 termination record of this package's local optimizers, on
# VisualGeometryToolkitCore's `BlockCoordinateDescent` stop contract: each
# criterion's `stop_reason` IS its record, `(ReturnCode.T, StopRule)` when it
# fires and Core's `CONTINUE` while the run goes on, and a method's
# `block_coordinate_result` receives the record of the criterion that fired
# (a composite's member, in Core's order). Leaving the basin is Terminated (a
# success: the incumbent is returned). A BoundedProblem is a validation
# decorator of the contract: the lift refines its inner problem. The arms on a
# scene, through the front end, are test_strategies.jl's.
# =============================================================================
using Random: MersenneTwister
using StaticArrays: SA
import VisualGeometryToolkitCore as VgtkCore
using VisualGeometryToolkitCore: CameraModel, EssentialMat, MsacScoring, ReturnCode, CONTINUE, IncrementSize,
    LadderConverged, LeftBasin, NoImprovement, IterationCap, correspondences, px, stop_reason, block_coordinate_result,
    Rect, TLSShape, WelschShape, Irls, codimension, consensus_set, locally_optimize!, minimal_sample_size, score_model!
using VisualGeometryToolkitCore.Synthetic: sample_twoview_scene
using VisualGeometryToolkitEstimation: BoundedProblem, EssentialProblem, RansacWorkspace
using LocalOptimizationDoneRight
const LO = LocalOptimizationDoneRight

@testset "the criteria's records" begin
    # stop_reason(criterion, state, method, prob, θ, θ_old, iter): the criteria read the state only
    sr(c, state) = stop_reason(c, state, nothing, nothing, nothing, nothing, 1)
    @test sr(LO.StopWhenIncrementSmall(), (; Δθnorm = 0.0)) === (ReturnCode.Success, IncrementSize)
    @test sr(LO.StopWhenIncrementSmall(), (; Δθnorm = 1.0)) === CONTINUE
    @test sr(LO.StopWhenLadderConverged(), (; converged = true)) === (ReturnCode.Success, LadderConverged)
    @test sr(LO.StopWhenLadderConverged(), (; converged = false)) === CONTINUE
    @test sr(LO.StopWhenLeftBasin(), (; cur_cost = 2.0, seed_nll = 1.0)) === (ReturnCode.Terminated, LeftBasin)
    @test sr(LO.StopWhenLeftBasin(), (; cur_cost = 1.0, seed_nll = 1.0)) === CONTINUE
    # a composite: the first member, in order, whose record is not CONTINUE
    both = LO.StopWhenLeftBasin() | LO.StopWhenIncrementSmall()
    @test sr(both, (; cur_cost = 2.0, seed_nll = 1.0, Δθnorm = 0.0)) === (ReturnCode.Terminated, LeftBasin)
    @test sr(both, (; cur_cost = 1.0, seed_nll = 1.0, Δθnorm = 0.0)) === (ReturnCode.Success, IncrementSize)
end

# A method's result carries the record it is handed. LODR#2 (wave-10 catch-up): never re-derived from the final state —
# here the state says "improved" (re-evaluating the no-improvement stop would continue) while the loop reports that the
# stop fired.
@testset "block_coordinate_result: the record handed over" begin
    _, _, _, E, matches = sample_twoview_scene(MersenneTwister(5), 30)
    camera = CameraModel(600.0px, SA[250.0px, 250.0px])
    problem = EssentialProblem(camera, camera, correspondences(first.(matches), last.(matches)))
    msac = MsacScoring(problem; threshold = 2.0)
    ws = RansacWorkspace(problem, msac, StuTuBCD())
    m = LO.ScoreBcdMethod(msac, ws.lo_ws, ws.buf, 0.0)
    st = LO.ScoreBcdState(VgtkCore.Attributed(E, (; cost = -1.0)), -1.0, true)
    for (code, rule) in ((ReturnCode.Success, NoImprovement), (ReturnCode.MaxIters, IterationCap))
        r = block_coordinate_result(st, m, problem, E, code, 4, rule)
        @test (r.retcode, r.stop_rule) === (code, rule) && r.u === E && r.stats.nsteps == 4
    end
end

# A BoundedProblem is a validation decorator: the lift refines its inner problem, through the contract hook on the
# seed's consensus set (the front end validates an E model over no region).
@testset "locally_optimize!: a BoundedProblem refines its inner problem" begin
    _, _, _, E, matches = sample_twoview_scene(MersenneTwister(5), 60)
    camera = CameraModel(600.0px, SA[250.0px, 250.0px])
    problem = EssentialProblem(camera, camera, correspondences(first.(matches), last.(matches)))
    bounded = BoundedProblem(problem, Rect(0.0, 0.0, 500.0, 500.0))
    msac = MsacScoring(problem; threshold = 2.0)
    function lo_run(lo, P)
        ws = RansacWorkspace(P, msac, lo)
        score_model!(ws.buf, msac, P, E)
        cs = consensus_set(msac, ws.buf.scoring_ws, ws.buf.residuals; model_dof = minimal_sample_size(P) + 1,
                           d_g = codimension(P), epoch = ws.buf.epoch)
        return locally_optimize!(ws.lo_ws, lo, P, E, cs, ws.buf, msac)
    end
    for lo in (HQ{WelschShape}(efficiency_constant = 1.5), Gnc{Irls{TLSShape}}(efficiency_constant = 2.5))
        a, b = lo_run(lo, bounded), lo_run(lo, problem)
        @test a.u == b.u && (a.retcode, a.stop_rule) === (b.retcode, b.stop_rule)
    end
end
