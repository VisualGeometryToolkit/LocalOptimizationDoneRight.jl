# =============================================================================
# accv2026/test/lodr — LocalOptimizationDoneRight's strategy tests that run on
# the paper's scorer (RANSACScoringDoneRight's Student-t + uniform marginal):
# the Table 1 strategies (HQ lifts, GNC, Stu-tU IRLS and BCD) on
# VisualGeometryToolkitEstimation's problems, their lifts on H / PnP, the recorded BCD
# traces, and the old find_* recipes. Moved from the package's test/ (K+,
# 2026-10-09): the stack allow-list (VisualGeometryToolkitCore
# configs/stack_dependencies.toml) lets the library's test target name no
# scorer package, so the RSDR × LODR tests live here, pins unchanged.
#
# One ReTestItems test item per file (each in a module of its own, on a worker
# process of ../runtests.jl's pool); the shared synthetic scenes are the
# `@testsetup` modules of scenes_testsetups.jl, named per item in `setup`.
# `default_imports = false`: the project (ACCV2026) is not a package, so
# ReTestItems' implicit `using <project>` has nothing to load.
# =============================================================================

@testitem "lodr: strategies" default_imports = false setup = [HomographyScenes, EpipolarScenes] begin
    using Test
    include("test_strategies.jl")
end

@testitem "lodr: BCD recorded" default_imports = false begin
    using Test
    include("test_bcd_recorded.jl")
end

@testitem "lodr: manifold collapse" default_imports = false setup = [EpipolarScenes] begin
    using Test
    include("test_manifold_collapse.jl")
end

@testitem "lodr: lift losses" default_imports = false setup = [EpipolarScenes, Cameras] begin
    using Test
    include("test_lift_losses.jl")
end

@testitem "lodr: homography lift" default_imports = false setup = [HomographyScenes, Contamination, LiftChecks] begin
    using Test
    include("test_homography_lift.jl")
end

@testitem "lodr: PnP lift" default_imports = false setup = [PoseScenes, Contamination, LiftChecks] begin
    using Test
    include("test_pnp_lift.jl")
end

@testitem "lodr: problem arms" default_imports = false setup = [EpipolarScenes, HomographyScenes, PoseScenes, Contamination, DivisionBoards] begin
    using Test
    include("test_problem_arms.jl")
end

@testitem "lodr: old defaults" default_imports = false setup = [EpipolarScenes, HomographyScenes, PoseScenes, Contamination] begin
    using Test
    include("test_old_defaults.jl")
end
