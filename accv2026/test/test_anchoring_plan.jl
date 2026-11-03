# =============================================================================
# test_anchoring_plan.jl — the consensus-anchoring ablation's driver
# (scripts/fig_anchoring.jl) lists its evaluation stage under `--plan`, keyed
# by the scale interface configs/miscal_protocol.toml declares. The driver
# binds the results root when it loads (src/registry.jl), so this runs only
# where one is bound: a :data item (accv2026_tests.jl). Split from
# test_anchoring_ablation.jl, whose other testsets need no data.
# =============================================================================
using Test, TOML

@testset "consensus-anchoring ablation: listed by --plan" begin
    root = normpath(joinpath(@__DIR__, ".."))
    iface = TOML.parsefile(joinpath(root, "configs", "miscal_protocol.toml"))["anchoring_ablation"]["scale_interface"]
    # scratch data and results roots: the plan resolves the keyed paths,
    # runs nothing, and so needs no data binding on this machine
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$root $(joinpath(root, "scripts", "fig_anchoring.jl")) --plan`
    out = read(addenv(cmd, "CAU_RESULTS_ROOT" => mktempdir(), "CAU_DATA_ROOT" => mktempdir()), String)
    @test occursin("evaluation", out) && occursin("render", out)
    @test occursin("anchoring_ablation-$(iface)", out)
end
