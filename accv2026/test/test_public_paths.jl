# The package's public files name no machine (VisualGeometryToolkitEval's data
# policy, rule D1: machine paths live only in its site profiles, selected by
# VGTK_SITE). The paper project's own code, launchers, tests, configs and docs
# are checked by paper_project_violations (test_paper_project.jl); this item
# runs the same check, Eval's `data_policy_violations`, over the package beside
# it: its docs, configs, sources, extensions, tests and CI workflows.
using Test
using VisualGeometryToolkitEval.Experiments: data_policy_violations

@testset "the package's public files name no machine path" begin
    repo = normpath(joinpath(@__DIR__, "..", ".."))
    v = data_policy_violations(repo; dirs = String[], machine_dirs = ["docs", "configs", "src", "ext", "test", ".github"])
    foreach(x -> @info("machine path", x), v)
    @test isempty(v)
end
