# =============================================================================
# The LO timing regression gate on the arms this package owns
# (test/lo_timing/bench.jl): PoseLib's truncated refiners TLS-IRLS and TLS-LZ
# on the recorded Table 1 call set, through the external-refit contract, and
# the lift kernels. (The Table 1 strategies that refine under the paper's
# Student-t + uniform marginal are gated in accv2026/test/lo_timing.) Opt-in;
# policy, modes and
# robustness in VisualGeometryToolkitCore's test/lo_timing/gate.jl (the stack's one
# gate), included from its package dir:
#
#   LO_TIMING_GATE=1      julia --project -e 'using Pkg; Pkg.test(test_args = ["lo_timing_gate"])'
#   LO_TIMING_GATE=record (same) — rewrites test/lo_timing/baselines.toml
# =============================================================================
using Test
import LocalOptimizationDoneRight, VisualGeometryToolkitCore
const _LO_TIMING_GATE = joinpath(pkgdir(VisualGeometryToolkitCore), "test", "lo_timing", "gate.jl")

@testset "lo_timing_gate" begin
    if isfile(_LO_TIMING_GATE)
        include(_LO_TIMING_GATE)
        Base.invokelatest(run_lo_timing_gate, joinpath(@__DIR__, "lo_timing"))
    elseif get(ENV, "LO_TIMING_GATE", "") in ("1", "record")
        @test_skip "the resolved VisualGeometryToolkitCore ships no test/lo_timing/gate.jl (older than the gate)"
    end
end
