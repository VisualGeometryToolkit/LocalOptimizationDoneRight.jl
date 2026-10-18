# =============================================================================
# accv2026/test/lodr — LocalOptimizationDoneRight's strategy tests that run on
# the paper's scorer (RansacScoringDoneRight's Student-t + uniform marginal):
# the Table 1 strategies (HQ lifts, GNC, Stu-tU IRLS and BCD) on
# VisualGeometryToolkitEstimation's problems, their lifts on H / PnP, the recorded BCD
# traces, and the old find_* recipes. Moved from the package's test/ (K+,
# 2026-10-09): the stack allow-list (VisualGeometryToolkitCore
# configs/stack_dependencies.toml) lets the library's test target name no
# scorer package, so the RSDR × LODR tests live here, pins unchanged.
#
# Every file runs in a module of its own (no binding leaks between files; a
# file `include`s scenes.jl, the shared synthetic scenes, into its module).
# Included by accv2026/test/runtests.jl; standalone:
#   julia --project=. test/lodr/runtests.jl
# =============================================================================
using Test

const _LODR_FILES = [
    "test_strategies.jl",
    "test_bcd_recorded.jl",
    "test_manifold_collapse.jl",
    "test_lift_losses.jl",
    "test_homography_lift.jl",
    "test_pnp_lift.jl",
    "test_problem_arms.jl",
    "test_old_defaults.jl",
]

function _run_lodr_file(file)
    m = Module(Symbol(splitext(file)[1]))
    Core.eval(m, :(include(path) = Base.include($m, path)))
    @testset "$file" begin
        Base.include(m, joinpath(@__DIR__, file))
    end
    return nothing
end

@testset "LocalOptimizationDoneRight × RansacScoringDoneRight" begin
    foreach(_run_lodr_file, _LODR_FILES)
end
