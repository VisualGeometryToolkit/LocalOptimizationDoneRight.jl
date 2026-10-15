# =============================================================================
# manifold_collapse_tests.jl — gates for the ONE-code-path chart-lift collapse.
#
# 1. One-code-path enforcement: the `locally_optimize!` entries for HQ{K} and
#    Gnc{<:Irls} have exactly ONE implementation each (the generic
#    ManifoldLiftHQ/ManifoldLiftGnc dispatch on RobustVisualGeometry's
#    `LiftableProblem`, src/lift/lifts.jl). Reintroducing a per-problem port fails here.
# 2. F gains GNC for free: `Gnc{Irls{WelschShape}}` on FundMatProblem works
#    through the F provider (it error-stubbed before the collapse) and improves
#    a perturbed seed on a seeded synthetic scene.
# =============================================================================
# (Moved from RobustVisualGeometry's test/manifold_collapse_tests.jl with the strategies it tests.)
using Test, Random, LinearAlgebra, StaticArrays, StructArrays
using Rotations: RotY
using VisualGeometryCore
using VisualGeometryCore: estimate, retcode   # VGC accessors (public)
using RansacScoringDoneRight: StudentTUniformScoring   # the paper's marginal (the old core default)
using RobustVisualGeometry
using LocalOptimizationDoneRight
const RVGC = RobustVisualGeometry
const LODR = LocalOptimizationDoneRight
# From its OWNER: RVG no longer imports `signed_sampson_distance` — E's
# scoring moved to the tangent Sampson and was its last user there, so the
# quality gate refuses it as a stale explicit import. F still uses it.
using VisualGeometryCore: signed_sampson_distance
include("scenes.jl")   # the shared scenes, as modules
using .EpipolarScenes

@testset "one code path — HQ/Gnc locally_optimize! method census" begin
    # A method is the generic implementation iff its problem parameter is
    # constrained (the refusal takes `problem::Any`). The contract verb's
    # signature: locally_optimize!(L, lo, problem, θ, cs, buf, scoring).
    problem_param(m) = Base.unwrap_unionall(m.sig).parameters[4]
    _base(t) = t isa UnionAll ? _base(t.body) :
        t isa DataType ? t.name.wrapper : nothing
    lo_base(m) = _base(Base.unwrap_unionall(m.sig).parameters[3])
    ms = collect(methods(VisualGeometryCore.locally_optimize!))

    hq_ms = [m for m in ms if lo_base(m) === LODR.HQ]
    hq_impl = [m for m in hq_ms if problem_param(m) !== Any]
    # The BoundedProblem see-through forwarder (029665e) is a thin unwrap,
    # not a per-problem port — census the core implementations without it.
    hq_core = [m for m in hq_impl if !(problem_param(m) <: RVGC.BoundedProblem)]
    @test length(hq_core) == 1                       # ONE generic HQ implementation
    @test problem_param(hq_core[1]) == RVGC.LiftableProblem

    gnc_ms = [m for m in ms if lo_base(m) === LODR.Gnc]
    gnc_impl = [m for m in gnc_ms if problem_param(m) !== Any]
    @test length(gnc_impl) == 1                      # ONE generic Gnc{<:Irls} implementation
    @test problem_param(gnc_impl[1]) == RVGC.LiftableProblem

    # Any other problem reaches the ONE refusal (VisualGeometryCore's LO
    # contract), typed on the strategy root only — not a per-strategy stub.
    for lo in (LODR.HQ{VisualGeometryCore.WelschShape}, LODR.Gnc{RVGC.Irls{VisualGeometryCore.WelschShape}})
        m = which(VisualGeometryCore.locally_optimize!, Tuple{Any, lo, RVGC.LineFittingProblem{Float64}, Any,
                                                 VisualGeometryCore.ConsensusSet, VisualGeometryCore.ScoreBuffers, Any})
        @test problem_param(m) === Any
        @test Base.unwrap_unionall(m.sig).parameters[3] === VisualGeometryCore.AbstractLocalOptimization
    end
end

@testset "F gains GNC through the provider (new capability)" begin
    # Seeded synthetic epipolar scene (same construction family as the E/F
    # lift smoke): rotation + translation, ~8% gross outliers, mild noise.
    R = RotY(0.22); t = normalize(SA[0.55, -0.1, 0.3])
    u₁, u₂ = calibrated_pairs(MersenneTwister(7), R, t; n = 120, σ = 0.001, outlier_every = 12)
    # perturbed seed, read as F (the calibrated points are F's pixels at K = I)
    F_seed = FundMat(perturbed_essential(R, t, 0.06, SA[0.05, -0.04, 0.03]), SMatrix{3, 3, Float64}(I))

    pf = FundMatProblem(StructArray(u₁ .=> u₂))
    sqcost(F) = truncated_sampson_cost(F, u₁, u₂)
    c_seed = sqcost(F_seed)
    rf = RVGC.locally_optimize(
        pf, F_seed; scoring = StudentTUniformScoring(pf, 0.05),
        local_optimization = LODR.Gnc{RVGC.Irls{RVGC.WelschShape}}(scale_multiple = 1.0)
    )
    @test estimate(rf) !== nothing
    @test retcode(rf) in (:converged, :max_iterations)
    @test all(isfinite, Tuple(SMatrix{3, 3, Float64}(estimate(rf))))
    @test sqcost(estimate(rf)) < c_seed                  # GNC improved the perturbed seed
end
