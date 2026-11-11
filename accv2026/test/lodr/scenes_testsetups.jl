# =============================================================================
# Shared synthetic scenes of the strategy tests — ReTestItems `@testsetup`
# modules. The scenes are VisualGeometryToolkitEstimation's `synthetic_scenes()` (its
# Test extension), the ONE definition every stack package's tests draw from;
# each setup below is one family, re-exported, so an item names the families
# it needs in `setup = [...]` (lodr/lodr_tests.jl) and its file `using`s them.
# The draws are the ones this file's former copy made, in the same RNG order
# (the numeric pins depend on it). LiftChecks, below, is this package's own.
# =============================================================================

@testsetup module EpipolarScenes
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().EpipolarScenes
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:EpipolarScenes])...))
end

@testsetup module HomographyScenes
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().HomographyScenes
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:HomographyScenes])...))
end

@testsetup module PoseScenes
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().PoseScenes
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:PoseScenes])...))
end

@testsetup module DivisionBoards
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().DivisionBoards
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:DivisionBoards])...))
end

@testsetup module P3PScenes
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().P3PScenes
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:P3PScenes])...))
end

@testsetup module Cameras
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().Cameras
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:Cameras])...))
end

@testsetup module Contamination
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().Contamination
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:Contamination])...))
end

@testsetup module RadialScenes
using Test: Test                                       # loads the extension
using VisualGeometryToolkitEstimation: synthetic_scenes
const _Family = synthetic_scenes().RadialScenes
using ._Family
eval(Expr(:export, setdiff(names(_Family), [:RadialScenes])...))
end

# -----------------------------------------------------------------------------
# The loss-lift batteries' shared checks (the homography and PnP lift tests):
# the same LO arms through production `ransac()`, and from a perturbed seed
# through `locally_optimize`.
# -----------------------------------------------------------------------------
@testsetup module LiftChecks
using Test: @test, @testset
using Random: Random, MersenneTwister
using VisualGeometryToolkitCore: GemanMcclureShape, WelschShape, converged, estimate, decision_width, inlier_mask
using VisualGeometryToolkitEstimation: Irls, RansacConfig, ransac
using LocalOptimizationDoneRight: Gnc, HQ

export lift_arms, check_lift_ransac, check_lift_recovers

"""
    lift_arms(; welsch_efficiency_constant, gnc_efficiency_constant) -> (name => strategy, …)

The battery's LO arms: the static Welsch IRLS (efficiency constant 1.5), the HQ
lifts — Welsch at `welsch_efficiency_constant`, Geman–McClure at the half-weight
depth of Welsch's 1.5 — and the GNC arm at `gnc_efficiency_constant`.
"""
lift_arms(; welsch_efficiency_constant, gnc_efficiency_constant) = (
    "Irls{Welsch}" => Irls{WelschShape}(efficiency_constant = 1.5),
    "HQ{Welsch}" => HQ{WelschShape}(efficiency_constant = welsch_efficiency_constant),
    "HQ{GM}" => HQ{GemanMcclureShape}(efficiency_constant = decision_width(GemanMcclureShape(), 1.5 * sqrt(log(2.0)))),   # half-weight depth, migrated
    "Gnc{Irls{Welsch}}" => Gnc{Irls{WelschShape}}(efficiency_constant = gnc_efficiency_constant),
)

"""
    check_lift_ransac(accurate, problem, scoring, arms, n_in; seed)

Production `ransac()` per arm, the first `n_in` correspondences the true
inliers: it converges, `accurate(estimate)` holds (its own `@test`s), and it
keeps ≥ 90 % of the inliers with ≤ 5 false positives.
"""
function check_lift_ransac(accurate, problem, scoring, arms, n_in; seed)
    @testset "ransac() — $name" for (name, lo) in arms
        Random.seed!(11)
        res = ransac(
            problem, scoring; local_optimization_strategy = lo,
            config = RansacConfig(max_trials = 2000, min_trials = 200),
            rng = MersenneTwister(seed)
        )
        @test converged(res)
        accurate(estimate(res))
        @test sum(inlier_mask(res)[1:n_in]) >= 0.9 * n_in            # inlier recovery
        @test sum(inlier_mask(res)[(n_in + 1):end]) <= 5             # false-positive control
    end
    return nothing
end

"""
    check_lift_recovers(accurate, refine, arms)

Every arm, run from the same seed by `refine(strategy)`, lands where
`accurate(estimate)` holds.
"""
function check_lift_recovers(accurate, refine, arms)
    for (_, lo) in arms
        accurate(estimate(refine(lo)))
    end
    return nothing
end
end
