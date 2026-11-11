# =============================================================================
# test_paper_project.jl — the stack's paper-project conventions
# (VisualGeometryToolkitEval `PaperProjects.paper_project_violations`): the layout,
# the data policy (D1–D4), the REPRODUCE.md asset index against what the two
# papers read, configs of record, provenance and the data catalog. NO deferred
# allowance: any violation fails. A justified opt-out sits, with its reason, in
# the file it excuses (`# paper-project: allow <RULE> <reason>`).
#
# Included by test/runtests.jl itself (not a ReTestItems item), so the suite's
# own entry point calls the check (rule L4).
# =============================================================================
using Test
using VisualGeometryToolkitEval.PaperProjects: paper_project_violations

@testset "paper-project conventions" begin
    v = paper_project_violations(normpath(joinpath(@__DIR__, ".."));
                                 papers = ["paper/main.tex", "paper/supplement.tex"])
    foreach(x -> @info("paper-project violation", x), v)
    @test isempty(v)
end
