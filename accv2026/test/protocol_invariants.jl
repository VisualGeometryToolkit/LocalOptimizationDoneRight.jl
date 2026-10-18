# =============================================================================
# test/protocol_invariants.jl — EXECUTABLE protocol invariants (the historical
# eval/protocol/check_invariants.jl, repointed at the LocalOptimizationDoneRight
# layout: VisualGeometryToolkitEval src/ = mechanisms (read via pkgdir), scripts/ =
# the campaign drivers).
#
# Any failure means a retired protocol or a vocabulary drift has re-entered
# the codebase — fix the code, never this file.
# =============================================================================
import VisualGeometryToolkitEval as VgtkEval
using Test, TOML
using VisualGeometryToolkitEstimation: VisualGeometryToolkitEstimation
using VisualGeometryToolkitEval: VisualGeometryToolkitEval

const ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "src", "config.jl"))   # the arm table + protocol of record (idempotent)
const SCRIPTS = joinpath(ROOT, "scripts")
const EVAL = pkgdir(VisualGeometryToolkitEval)
const SRC = joinpath(EVAL, "src")

# "src" = the eval package's sources (EVAL); "prelude" = this project's src/.
_read(p...) = p[1] == "prelude" ? read(joinpath(ROOT, "src", p[2:end]...), String) :
              read(joinpath(p[1] == "src" ? EVAL : ROOT, p...), String)
_all_eval_sources() = [
    joinpath(r, f)
        for base in (SRC, SCRIPTS) for (r, _, files) in walkdir(base) for f in files
        if endswith(f, ".jl") && !occursin("protocol_invariants", f)
]

@testset "protocol invariants" begin
    # 1. The retired shared-knob CV is DELETED — its symbols may not reappear
    #    in CODE (word-boundary match on non-comment lines; comments recording
    #    the removal are allowed). Its bundle LO refit builder is kept out by
    #    the quality naming test: VisualGeometryToolkitCore.check_naming rejects its name.
    _code_lines(txt) = [l for l in split(txt, '\n') if !startswith(lstrip(l), "#")]
    for sym in ("run_sb_fair_cv", "load_sb_fair_cv", "fullbudget_err")
        re = Regex("\\b\\Q$(sym)\\E\\b")
        hits = [
            p for p in _all_eval_sources()
                if any(occursin(re, l) for l in _code_lines(read(p, String)))
        ]
        @test isempty(hits)
    end

    # 2. Every budget cell runs through the ONE budget path, which audits its
    #    operating points before consuming them and refuses a selector its
    #    engine cannot seed (the MSAC loss width read as an IG half-width).
    sb = _read("prelude", "cell_stages.jl")
    @test occursin("audit_operating_points(ROSTER, sidecar; problem = p)      # MANDATORY before consumption", sb)
    @test occursin("issubset(selectors, (:ig,))", sb)
    @test !isfile(joinpath(@__DIR__, "..", "scripts", "tools", "run_sb_fair.jl"))   # the special-case driver is gone

    # 3. The legacy LO roster cannot be launched from the sensitivity driver:
    #    the bundles are selection-only, so neither the driver nor the producer
    #    has an LO knob at all (the retired --with-lo / --los and the escape
    #    hatch stay dead).
    lo = _read("scripts", "tools", "run_lo_sensitivity.jl") * _read("prelude", "experiment_producer.jl")
    for knob in ("with-lo", "with_lo", "\"los\"", "los =", "allow-retired-cv")
        @test !occursin(knob, lo)
    end

    # 4. One label vocabulary: labels.jl parses, and the faceted renderers take
    #    their arm labels from PAPER_STYLE's arm records, which figure_style.jl
    #    builds from PROBE INSTANCES of the deployed strategies (trait-derived:
    #    a label cannot drift from the production type). The retired legacy
    #    renderer asserted the vocabulary by hand; the registry makes that
    #    structural.
    labels = _read("prelude", "labels.jl")
    Meta.parseall(labels)
    @test occursin("Stu-\\\$t\\\$U", labels) || occursin(raw"Stu-$t$U", labels)
    fs = _read("prelude", "figure_style.jl")
    @test occursin("arm_style_records(_ARM_PROBES", fs)
    @test occursin("TIMING_TAGS", _read("prelude", "arm_rosters.jl"))   # derived from the one arm table

    # 5. Scene lists have ONE source, VisualGeometryToolkitEval's registered
    #    splits (configs/splits.toml), reached only through a spec's
    #    cross_validation: no file of this project states a registered scene.
    @test !isfile(joinpath(ROOT, "src", "scene_splits.jl"))
    registered = Set(s for sp in values(VgtkEval.Tuning.SPLIT_REGISTRY["splits"])
                     for side in ("validation_scenes", "test_scenes") for s in sp[side])
    # The one named scene that is not a split: Table 1's timing FIXTURE (one
    # test scene's first pairs, configs/timing_table.toml [timing] scene).
    fixture = Set(["configs/timing_table.toml: british_museum"])
    literal = String[]
    for dir in ("src", "scripts", "configs", "test"), (r, _, fs) in walkdir(joinpath(ROOT, dir)), f in fs
        any(endswith(f, e) for e in (".jl", ".toml", ".py", ".sh")) || continue
        txt = read(joinpath(r, f), String)
        for s in registered
            hit = "$(relpath(joinpath(r, f), ROOT)): $s"
            occursin("\"" * s * "\"", txt) && !(hit in fixture) && push!(literal, hit)
        end
    end
    @test isempty(literal)
    isempty(literal) || @info "registered scene literals outside configs/splits.toml" literal

    # 6. The house display conventions live in build_axis (degree ticks etc.).
    pv = _read("src", "render", "plot_core.jl")
    @test occursin("y_unit_degree", pv)
    @test occursin("ytick_spacing", pv)

    # 7. Protocol-table constants: the supplement's tab:supp-protocols claims
    #    must equal the code constants. Both sides are PARSED (never hardcoded
    #    here) so a drift in either the paper or the code fails this suite.
    #    The paper lives in-tree (accv2026/paper); PAPER_SUPP overrides.
    #    Skipped (loudly) when absent.
    supp_path = get(
        ENV, "PAPER_SUPP",
        normpath(joinpath(@__DIR__, "..", "paper", "supplement.tex"))
    )
    if !isfile(supp_path)
        @warn "supplement.tex not found — protocol-table constants unchecked" supp_path
    else
        supp = read(supp_path, String)
        @testset "protocol table constants" begin
            # (a) Scale-multiple search window: the paper's prose "$k\in[1,3.3]$" (its symbol) ⇔ the
            #     tuning protocol of record's window (configs/tuning.toml
            #     [types.scale_multiple_window], THE one place it is spelled).
            mw = match(r"k\\in\[([\d.]+),([\d.]+)\]", supp)
            # The ACCV-restructured supplement dropped the protocols-table
            # prose; the constant checks only apply while the paper CLAIMS the
            # constant (pre-existing drift, predates the eval-package move).
            if mw === nothing
                @warn "supplement carries no scale-multiple window prose — window check skipped"
            else
                w = TOML.parsefile(joinpath(ROOT, "configs", "tuning.toml"))["types"]["scale_multiple_window"]
                @test parse(Float64, mw[1]) == Float64(w["lo"])
                @test parse(Float64, mw[2]) == Float64(w["hi"])
            end

            # (b) Shared LO iteration cap: prose "25-iteration LO cap" ⇔ THE
            #     budget of record (configs/protocol.toml [arms]
            #     lo_iteration_budget). Every arm reading it is asserted in
            #     "arm budgets" below, outside the prose gate.
            mi = match(r"(\d+)-iteration LO cap", supp)
            if mi === nothing
                @warn "supplement carries no LO-cap prose — cap prose check skipped"
            else
                @test parse(Int, mi[1]) == LO_BUDGET
            end

            # (The Huber-elbow check is gone: RVG made every loss's `scale_multiple` a
            # required keyword, so there is no code default for the prose to match.)
        end
    end
end
# Every arm of the paper spends THE budget of record (configs/protocol.toml
# [arms] lo_iteration_budget), save the deviations declared there: the Lebeda
# ladder alone (1 + num_lsq_iterations updates) and RansacLib's reference
# preset (61). The full classical LO's trials are derived so it spends exactly
# the budget.
@testset "arm budgets (configs/protocol.toml)" begin
    B = LO_BUDGET
    updates(lo::LebedaIterLO) = 1 + lo.opts.num_lsq_iterations
    updates(lo::LebedaLOPlus) = 1 + lo.opts.num_lo_trials * (2 + lo.opts.num_lsq_iterations)
    updates(lo) = lo.max_iter
    deviation = Dict("IG  +TLS-LO" => 1 + LEBEDA_OPTIONS.num_lsq_iterations,
                     "IG  +TLS-LO+(ref)" => 1 + 10 * (2 + 4))   # RansacLib's defaults
    for (key, def) in ARM_TABLE
        @test updates(arm_strategy(def, 1.0)) == get(deviation, key, B)
    end
    @test updates(arm_strategy(ARM_TABLE["IG  +TLS-LO+"], 1.0)) == B
    @test_throws ArgumentError lebeda_budget_trials(24, 4)
    @test lebeda_budget_trials(25, 4) == 4
end
println("PROTOCOL INVARIANTS: all enforced")
