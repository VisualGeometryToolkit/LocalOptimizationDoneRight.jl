# =============================================================================
# Tooling gates (package-cleanup Phase 6): keep the package's hygiene where the
# 2026-09-08 audit left it. The tools are test-target deps ([extras] +
# [targets] test) so `Pkg.test` — the fresh-clone release gate — actually runs
# them (it never sees the shared environment); they are not [deps].
# Strict deprecations: `Pkg.test(; julia_args = ["--depwarn=error"])` succeeds
# (2026-09-08; re-verified 2026-09-21) and is the release-gate invocation.
# =============================================================================
using Test
using LocalOptimizationDoneRight
using Aqua, ExplicitImports, JET
using VisualGeometryCore: VisualGeometryCore
import PoseLib                # loads the PoseLib extension, checked by the stack contracts below
const _M = LocalOptimizationDoneRight

@testset "gates" begin
    @testset "Aqua" begin
        Aqua.test_stale_deps(_M)
        Aqua.test_piracies(_M)
        Aqua.test_undefined_exports(_M)
        Aqua.test_unbound_args(_M)
        Aqua.test_project_extras(_M)
        Aqua.test_deps_compat(_M)
        # Loading pulls CUDA/GPUCompiler; the 60 s default times out on a cold depot.
        Aqua.test_persistent_tasks(_M; tmax = 300)
    end
    @testset "ExplicitImports" begin
        @test check_no_implicit_imports(_M) === nothing
        @test check_no_stale_explicit_imports(_M) === nothing
        @test check_all_explicit_imports_are_public(_M) === nothing
    end
    # The stack's naming vocabulary (VisualGeometryCore.check_naming) over the
    # whole repository: package, vendored-wrapper library and paper project.
    @testset "naming" begin
        VisualGeometryCore.test_naming(_M)
    end
    @testset "JET ratchet" begin
        JET_BASELINE = 0          # 2026-09-08; only ever decreases
        r = JET.report_package(_M; target_modules = (_M,))
        n = length(JET.get_reports(r))
        n > JET_BASELINE && show(stdout, MIME("text/plain"), r)
        @test n <= JET_BASELINE
    end
end

# ONE owner of minimal-sample boundaries: VisualGeometryEval `Pools.sample_starts`
# (certified against the pool's `total_samples` stamp). A "new sample where the
# `sample_indices` column changes" rule merges repeated draws — the budget
# engine's own counter did, until 2026-10-08 — so no code here compares adjacent
# sample columns: the package source, the paper project's code and its drivers.
@testset "sample boundaries come from VisualGeometryEval only" begin
    adjacent = r"(sample_indices|sidx)[^\n]*\b[jk]\s*[-+]\s*1\b"
    root = pkgdir(LocalOptimizationDoneRight)
    offenders = String[]
    dirs = filter(isdir, [joinpath(root, d) for d in ("src", "accv2026/src", "accv2026/scripts")])
    for dir in dirs, (d, _, fs) in walkdir(dir), f in fs
        endswith(f, ".jl") || continue
        for (i, line) in enumerate(eachline(joinpath(d, f)))
            occursin(adjacent, first(split(line, '#'; limit = 2))) && push!(offenders, "$(relpath(joinpath(d, f), root)):$i")
        end
    end
    @test isempty(offenders) || (@info "ad hoc sample boundaries" offenders; false)
end

# The stack contracts (VisualGeometryCore quality/stack_contracts.jl), enforced:
# Project.toml names only the allow-listed stack packages, no `_`-prefixed
# name of another stack package is reached from src/ or ext/, and every method
# added to another stack package's function lands on its CONTRACT_GENERICS —
# for the package and for its PoseLib extension.
@testset "stack contracts" begin
    root = pkgdir(_M)
    @test isempty(VisualGeometryCore.stack_dependency_violations(joinpath(root, "Project.toml"), "LocalOptimizationDoneRight"))
    @test isempty(vcat(VisualGeometryCore.private_name_violations(joinpath(root, "src"), "LocalOptimizationDoneRight"),
                       VisualGeometryCore.private_name_violations(joinpath(root, "ext"), "LocalOptimizationDoneRight")))
    @test isempty(VisualGeometryCore.contract_generic_violations(_M))
    ext = Base.get_extension(_M, :LocalOptimizationDoneRightPoseLibExt)
    @test ext !== nothing && isempty(VisualGeometryCore.contract_generic_violations(ext))
end
