using Test
using LocalOptimizationDoneRight
using VisualGeometryCore: agent_doc_violations
@testset "agent docs" begin
    # CLAUDE.md, AGENTS.md and anything tracked under .claude/ ship with the
    # package; they carry its conventions and nothing private. The check and its
    # patterns are VisualGeometryCore's; release tooling adds its own patterns
    # through AGENT_DOC_PATTERNS (a file, one regular expression per line).
    violations = agent_doc_violations(pkgdir(LocalOptimizationDoneRight); extra = get(ENV, "AGENT_DOC_PATTERNS", nothing))
    isempty(violations) || @error "agent docs carry private content" violations
    @test isempty(violations)
end

@testset "agent docs: conventions pointer" begin
    # The stack conventions live once, in VisualGeometryCore's conventions/
    # folder. This CLAUDE.md points there and carries no copy of the shared
    # text: the copies drifted, a pointer cannot. No sibling checkout needed.
    claude = read(joinpath(pkgdir(LocalOptimizationDoneRight), "CLAUDE.md"), String)
    @test occursin(r"^#+ Stack Conventions$"m, claude)
    @test occursin("VisualGeometryCore/conventions/", claude)
    @test occursin("VisualGeometryCore.conventions_dir()", claude)
    for copied in ("<!-- shared:", "Frame in = frame out.", "The one exception is the benchmark pool",
                   "Iterative-estimator vocabulary", "Correspondences in, dicts for groups")
        @test !occursin(copied, claude)
    end
end
