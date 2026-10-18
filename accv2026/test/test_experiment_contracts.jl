# =============================================================================
# test_experiment_contracts.jl — THE experiment-codification contract, enforced
# on every papers/*/experiments tree (maintainer mandate, 2026-07-19: "stop
# coding through the agent and codify the experiments"). Grep-based and it
# BITES: a violation fails CI, it does not advise.
#
# The checker is PACKAGE API (VisualGeometryToolkitEval.Experiments —
# `contract_violations(file)` returns one human-readable string per broken
# rule; the rule catalog F1–F4 /
# R1–R3 is documented there), so an external paper repo runs the SAME
# contract over its own papers/ tree. This file is the invocation.
#
# Scope: experiments/*.jl (top level; supp/, exploratory/, posebench/,
# validation/ subtrees are support or diagnostics). Non-experiment drivers are exempt (they are measurement records /
# legacy ACCV drivers with their own byte-frozen conventions).
# =============================================================================
using Test
using VisualGeometryToolkitEval: Experiments

const _EXP_DIR  = normpath(joinpath(@__DIR__, "..", "scripts"))
# drivers at the top level, the CLIs they launch in tools/, the exempt support pair in src/
const _EXP_DIRS = [_EXP_DIR, joinpath(_EXP_DIR, "tools"), normpath(joinpath(@__DIR__, "..", "src"))]

@testset "experiment codification contract" begin
    # The contract scope is the CODIFIED EXPERIMENT set (plus the exempt
    # support pair) — in this layout they share the top level with drivers,
    # config, and plotters, which were never in scope.
    _in_scope(f) = any(
        startswith(basename(f), p)
            for p in ("fig1", "fig2", "fig3", "fig4", "fig5", "fig_", "supp_", "polish", "timing_table")
    ) ||
        basename(f) in ("common.jl", "registry.jl")
    files = [
        p for d in _EXP_DIRS for p in readdir(d; join = true)
            if endswith(p, ".jl") && _in_scope(p)
    ]
    @test !isempty(files)
    for file in files
        name = relpath(file, normpath(joinpath(@__DIR__, "..")))
        @testset "$name" begin
            violations = Experiments.contract_violations(file)
            @test isempty(violations)
            isempty(violations) ||
                @info "contract violations" file violations
        end
    end
end

# The CLIs in scripts/tools/ run after the prelude (src/config.jl), whose arm
# table binds `const ROSTER`, `MAIN_ARMS`, …: a tool that assigns one of those
# names at top level dies at load ("invalid assignment to constant"), as
# render_miscal_faceted.jl's `ROSTER = get(ENV, "ROSTER", …)` did (2026-10-07).
@testset "tools never rebind a prelude constant" begin
    include(joinpath(@__DIR__, "..", "src", "config.jl"))
    _assigned(ex) = ex isa Expr && ex.head === :(=) && ex.args[1] isa Symbol ? [ex.args[1]] : Symbol[]
    tools = joinpath(_EXP_DIR, "tools")
    for f in filter(endswith(".jl"), readdir(tools; join = true))
        top = Meta.parseall(read(f, String); filename = f).args
        names = unique(reduce(vcat, (_assigned(ex) for ex in top); init = Symbol[]))
        bad = [s for s in names if isdefined(@__MODULE__, s) && isconst(@__MODULE__, s)]
        @test isempty(bad) || (@info "prelude constants rebound" file = basename(f) bad; false)
    end
end

# budget_cell_stages' run closure captures the cell's pool DIRECTORY as `pool`
# (the run records' input); the per-scene loop once rebound it to the loaded
# pool and then to `nothing`, so write_run_records got `inputs = [nothing, …]`
# after every scene had been computed (2026-10-07).
@testset "budget cell: the captured pool directory is bound once" begin
    src = Meta.parseall(read(normpath(joinpath(@__DIR__, "..", "src", "cell_stages.jl")), String)).args
    undoc(ex) = ex isa Expr && ex.head === :macrocall ? undoc(last(ex.args)) : ex   # a docstring wraps it
    fdef = only(f for f in undoc.(src) if f isa Expr && f.head === :function &&
                f.args[1].args[1] === :budget_cell_stages)
    count_assign(ex, s) = ex isa Expr ?
        ((ex.head === :(=) && (ex.args[1] === s || (ex.args[1] isa Expr && ex.args[1].head === :tuple && s in ex.args[1].args))) +
         sum((count_assign(a, s) for a in ex.args); init = 0)) : 0
    @test count_assign(fdef, :pool) == 1
end
