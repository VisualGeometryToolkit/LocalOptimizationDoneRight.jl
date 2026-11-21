# The package beside the paper project obeys the same data policy
# (VisualGeometryToolkitEval's `data_policy_violations`: rule D1, no machine path —
# a machine's paths live only in Eval's site profiles, selected by VGTK_SITE —
# and D2–D5 on its code). The paper project's own files are checked by
# paper_project_violations (test_paper_project.jl); this item runs the same check
# over the package: its sources and extensions as code, its tests, configs and
# docs, and its README.
using Test
using VisualGeometryToolkitEval.Experiments: data_policy_violations

@testset "the package's public files name no machine path" begin
    repo = normpath(joinpath(@__DIR__, "..", ".."))
    v = data_policy_violations(repo; dirs = ["src", "ext"])
    foreach(x -> @info("data policy", x), v)
    @test isempty(v)
end
