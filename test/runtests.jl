# =============================================================================
# LocalOptimizationDoneRight — the optimizer library's suite: the lift core and
# its schedules, the tuning constants and the strategies' TOML, the PoseLib
# refiners, plus the tooling gates. Plain `@testset`s: every file below runs in
# a module of its own (no binding leaks between files). The paper's tests (and
# its RansacLib LO baseline's) live in accv2026/test (a DrWatson project).
#
#   julia --project -e 'using Pkg; Pkg.test()'
#   Pkg.test(test_args = ["lift_core|schedules"])   # the files whose name matches
#   LO_TIMING_GATE=1 (same) — the opt-in timing gate (test_lo_timing_gate.jl)
#
# The evaluation engine is VisualGeometryToolkitEval's (VisualGeometryToolkitEval.Evaluation,
# tested there); its integration with these strategies and the paper's scorer
# is accv2026/test/test_engine_integration.jl. The strategy tests that run on
# the paper's scorer (RANSACScoringDoneRight, which the stack allow-list keeps
# out of this test target) live in accv2026/test/lodr/.
# =============================================================================
using Test
using LocalOptimizationDoneRight

const _FILES = [
    "test_lift_core.jl",
    "test_schedules.jl",
    "test_config_toml.jl",
    "test_tuning_constants.jl",
    "test_poselib_arms.jl",
    "test_gates.jl",
    "test_lo_timing_gate.jl",
    "agent_docs.jl",
]

# One file in a fresh module; `ARGS` (a test_args regex) selects files by name.
function _run_file(file)
    isempty(ARGS) || occursin(Regex(join(ARGS, "|")), file) || return nothing
    m = Module(Symbol(splitext(file)[1]))
    Core.eval(m, :(include(path) = Base.include($m, path)))
    @testset "$file" begin
        Base.include(m, joinpath(@__DIR__, file))
    end
    return nothing
end

@testset "LocalOptimizationDoneRight" begin
    foreach(_run_file, _FILES)
end
