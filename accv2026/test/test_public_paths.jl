# The package beside the paper project obeys Eval's data policy
# (`data_policy_violations`, its src/ and ext/ as code); the paper project itself
# is test_paper_project.jl's.
using Test
using VisualGeometryToolkitEval.Experiments: data_policy_violations

@testset "the package's public files name no machine path" begin
    repo = normpath(joinpath(@__DIR__, "..", ".."))
    v = data_policy_violations(repo; dirs = ["src", "ext"])
    foreach(x -> @info("data policy", x), v)
    @test isempty(v)
end
