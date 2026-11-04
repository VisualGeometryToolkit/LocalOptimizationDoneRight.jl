# =============================================================================
# The package's suite as ReTestItems test items (the `_test.jl` name is what
# ReTestItems discovers): one item per file, run across worker processes by
# runtests.jl. Each file states its own imports (`using Test` and
# `using LocalOptimizationDoneRight` are implicit as well). An item's name is
# its file's, so `Pkg.test(test_args = ["lift_core"])` selects as before.
# Tagged `:timing`: the opt-in LO timing gate, run alone on one worker.
# =============================================================================

@testitem "lift_core" begin
    include("test_lift_core.jl")
end

@testitem "schedules" begin
    include("test_schedules.jl")
end

@testitem "config_toml" begin
    include("test_config_toml.jl")
end

@testitem "tuning_constants" begin
    include("test_tuning_constants.jl")
end

@testitem "strategies" begin
    include("test_strategies.jl")
end

@testitem "poselib_arms" begin
    include("test_poselib_arms.jl")
end

@testitem "gates" begin
    include("test_gates.jl")
end

@testitem "lo_timing_gate" tags = [:timing] begin
    include("test_lo_timing_gate.jl")
end

@testitem "agent_docs" begin
    include("agent_docs.jl")
end
