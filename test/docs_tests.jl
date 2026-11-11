# docs_tests.jl — the docstring gates the Documenter build cannot run. Its
# `checkdocs = :public` only sees docstrings that exist, so a public name with
# none (GmHqEps and the four schedule verbs had none until 2026-11-04), a
# docstring detached from its definition by a blank or comment line (Julia
# 1.12 makes it a bare string) and a signature line that drifted from the
# methods (a removed keyword) all get through it. The General registration review asks
# for every public name to be documented (#173032).
#
# The gates are VisualGeometryToolkitCore's one `test_docs` (its Test extension;
# this package's copy, docs_gates.jl, is deleted 2026-11-11). Its lists, kept
# apart, are empty: every public name is documented. A first exception
# (`exceptions = Dict(name => reason)`, a name undocumented ON PURPOSE) or a
# backlog name takes Core's test/docs_tests.jl form.

@testitem "docs: every public name has a docstring, attached, and its signatures match the methods" begin
    using Test, LocalOptimizationDoneRight
    using VisualGeometryToolkitCore: test_docs
    test_docs(LocalOptimizationDoneRight; dirs = ("src", "ext"))
end
