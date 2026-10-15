# =============================================================================
# The ACCV 2026 research project's tests: the paper config registers, the
# production sidecar reads through the roster, every driver obeys the
# codification contract, the protocol invariants hold, and REPRODUCE.md indexes
# the experiments, the RansacLib LO baseline (src/lebeda_lo.jl over
# lib/RansacLibLO) refits as declared, and the composition evaluator
# (VisualGeometryEval.Evaluation) runs the paper's scorer and local optimizers
# as its RSDR × LODR integration goldens pin (test_engine_integration.jl). Run
# from the project: `julia --project=. test/runtests.jl` (a DrWatson project,
# not a package — no Pkg.test).
# =============================================================================
using Test
using VisualGeometryEval
using LocalOptimizationDoneRight
import VisualGeometryCore

@testset "ACCV2026" begin
    @testset "paper config registers" begin
        include(joinpath(@__DIR__, "..", "src", "config.jl"))
        # the data a cross-validation samples is declared by the data, not the spec
        @test TWO_VIEW_UNIT === VisualGeometryEval.Tuning.PairUnit()
        @test length(ROSTER.composed(:E)) >= 7
        @test length(ROSTER.solo(:E; role = :refinement)) >= 6
        @test !isempty(PAPER_STYLE.rows)
        @test !isempty(PAPER_STYLE.arms)
    end

    # The research-only zero-clamp Welsch-HQ (src/welsch_zero_clamp.jl): VGC
    # 92597af's z-block at the clamp, Welsch everywhere else, and the opt-in
    # "<key>@zc" arms wired through the rosters.
    @testset "zero-clamp Welsch-HQ variant" begin
        VGC = VisualGeometryCore
        zc, w = WelschZeroClampShape(), WelschShape()
        # 92597af's zblock(::WelschShape, …), verbatim, as the reference
        ref(w̄, c2) = (r = -c2 * log(w̄); w̄ >= one(w̄) ? (r, zero(r)) :
                                           (r, c2 * w̄ * VGC._welsch_hreg_ratio(w̄, Float64)))
        for c2 in (3.0e-6, 1.0, 2.5e3), w̄ in (1.0, prevfloat(1.0), 0.999, 0.9975, 0.99, 0.5, 1.0e-3, 1.0e-9)
            @test isequal(VGC.zblock(zc, w̄, c2), ref(w̄, c2))
            w̄ < 1 && @test isequal(VGC.zblock(zc, w̄, c2), VGC.zblock(w, w̄, c2))
            @test isequal(VGC.conjugate(zc, w̄, c2), VGC.conjugate(w, w̄, c2))
            @test isequal(VGC.ρ(zc, w̄, c2), VGC.ρ(w, w̄, c2)) && isequal(VGC.weight(zc, w̄, c2), VGC.weight(w, w̄, c2))
        end
        @test VGC.zblock(zc, 1.0, 2.0) == (-0.0, 0.0) && VGC.zblock(w, 1.0, 2.0)[2] == 4.0   # faithful: 2c²
        lo = arm_strategy(ARM_TABLE["IG  +Lift@zc"], 1.7)
        base = arm_strategy(ARM_TABLE["IG  +Lift"], 1.7)
        @test lo isa HQ{WelschZeroClampShape}
        @test all(f -> getfield(lo, f) == getfield(base, f), fieldnames(typeof(base)))
        @test ZERO_CLAMP_KEYS == ["IG  +Lift@zc", "MSAC +Lift@zc"]
        @test lo_label(lo) == "Welsch-HQ (zero clamp)"        # the strategy names its z-block
        # opt-in: only a declaring cell's roster carries it, right after its base
        keys_of(r) = [a.base for a in r]
        @test !("IG  +Lift@zc" in keys_of(composed_specs(:E)))
        k = keys_of(composed_specs(:E; zero_clamp = ["IG  +Lift"]))
        @test k[findfirst(==("IG  +Lift"), k) + 1] == "IG  +Lift@zc"
        @test is_tuned(only(a for a in composed_specs(:E; zero_clamp = ["IG  +Lift"]) if a.base == "IG  +Lift@zc"))
        @test_throws ErrorException composed_specs(:E; zero_clamp = ["IG  +BCD"])
        @test "IG  +Lift@zc" in keys_of(ROSTER.composed(:H)) && "IG  +Lift@zc" in keys_of(ROSTER.basin(:E))
    end

    # THE paper's Welsch-HQ (configs/protocol.toml [paper] welsch_hq, 2026-10-07):
    # the zero-clamp arm is drawn, labelled and timed as "Welsch-HQ"; the
    # faithful arm stays in the results and out of every paper figure and table.
    @testset "the paper's Welsch-HQ is the zero-clamp arm" begin
        root = normpath(joinpath(@__DIR__, ".."))
        @test PAPER_WELSCH_HQ == "IG  +Lift@zc" && UNSHOWN_WELSCH_HQ == "IG  +Lift"
        @test PAPER_WELSCH_HQ in MAIN_ARMS && !(UNSHOWN_WELSCH_HQ in MAIN_ARMS)
        @test main_arms(["IG  +WIrls", "IG  +Lift", "IG  +Lift@zc"]; extra = "") == ["IG  +WIrls", "IG  +Lift@zc"]
        rec = arm_record(PAPER_STYLE, PAPER_WELSCH_HQ)
        @test rec.label == "Welsch-HQ" && rec.color == "ColorIGLift"
        @test arm_record(PAPER_STYLE, UNSHOWN_WELSCH_HQ).color != rec.color
        @test arm_record(PAPER_STYLE, UNSHOWN_WELSCH_HQ).label != rec.label
        @test TIMING_TAGS[PAPER_WELSCH_HQ] == ("Welsch-HQ", :ig) && !haskey(TIMING_TAGS, UNSHOWN_WELSCH_HQ)
        # the cells that name their arms in their own configs name the paper's
        cfg(n) = TOML.parsefile(joinpath(root, "configs", n * ".toml"))
        @test cfg("pt_e_e2e_table")["e2e"]["arms"] == [PAPER_WELSCH_HQ]
        @test PAPER_WELSCH_HQ in cfg("polish_pt_e")["polish"]["sources"] &&
              !(UNSHOWN_WELSCH_HQ in cfg("polish_pt_e")["polish"]["sources"])
        # every cell that records Welsch-HQ records the paper's z-block
        for n in ("pt_e_miscal", "pt_e_basin", "accv2026_eth_f_miscal", "heb_h_miscal")
            @test "IG  +Lift" in get(cfg(n)["sequential_cv"], "zero_clamp", String[])
        end
        for n in ("pt_e_budget", "accv2026_eth_f_budget", "heb_h_budget")
            @test "IG  +Lift" in get(cfg(n)["budget"], "zero_clamp", String[])
        end
        # no paper figure draws both z-blocks: the unshown arm's colour appears in none
        unshown = arm_record(PAPER_STYLE, UNSHOWN_WELSCH_HQ).color
        figs = joinpath(root, "paper", "figures")
        uses(f, c) = occursin(Regex("color=\\{?" * c * "[,}\\]]"), read(joinpath(figs, f), String))
        panels = [f for f in readdir(figs) if endswith(f, ".tex") && f != "fig_colors.tex"]
        @test any(f -> uses(f, rec.color), panels)                  # the regex finds a drawn arm
        @test isempty([f for f in panels if uses(f, unshown)])
    end

    # THE deployed-sidecar read gate: the campaign's operating-points sidecar
    # (fig3_composed_miscal.jl stage cv) must load through the package + this
    # roster and rebuild the deployed arm settings. Skipped (loudly) where no
    # results root is bound or before the sidecar is regenerated.
    @testset "deployed operating-points sidecar gate" begin
        sc = try
            include(joinpath(@__DIR__, "..", "src", "registry.jl")); EXP_MISCAL_SIDECAR
        catch                                   # no results root bound (off the data host)
            ""
        end
        if isfile(sc)
            dep = Dict(deployed_arm_settings(ROSTER, sc))
            # exactly the cell's roster: its base arms + the variants it declares
            cell = load_run_config(joinpath(@__DIR__, "..", "configs", "pt_e_miscal.toml"))
            roster = composed_specs(:E; matched = declared_matched(cell["sequential_cv"]),
                                    zero_clamp = declared_zero_clamp(cell["sequential_cv"]))
            # A zero-clamp variant (research-only, declared 2026-10-06) joins a
            # migrated sidecar only when the regeneration runs it: until then it
            # is the one arm the sidecar may lack, and it is reported.
            pending = setdiff(Set(a.base for a in roster), keys(dep))
            isempty(pending) || @warn "sidecar predates declared zero-clamp arm(s) — run them" sc pending = sort!(collect(pending))
            @test issubset(pending, ZERO_CLAMP_KEYS)
            @test Set(keys(dep)) == setdiff(Set(a.base for a in roster), pending)
            @test haskey(dep, "IG  +LO") && haskey(dep, "MSAC +LZ")
            # a pinned (objective-matched) arm deploys at its selection's a*
            for a in roster
                is_tuned(a) || @test dep[a.base][2] == Dict(deployed_budget_settings(ROSTER, sc))[a.base].sel
            end
            bud = Dict(deployed_budget_settings(ROSTER, sc))
            @test all(v -> isfinite(v.sel) && isfinite(v.ref), values(bud))
        else
            @warn "deployed sidecar not found — read gate SKIPPED (off-host or not regenerated)" sc
        end
    end

    include("test_experiment_contracts.jl")
    include("test_oracle_floors.jl")
    include("test_config_vocabulary.jl")
    include("test_data_policy.jl")

    # LO-strategy contracts: separate process (the paper config defines Main
    # verbs that collide with earlier using-imports under the 1.12 rules).
    @testset "LO-strategy contracts (subprocess)" begin
        @test success(run(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "test_lo_contracts.jl"))`))
    end

    # The RansacLib LO arms and the vendored library's suite: separate process
    # for the same reason.
    @testset "RansacLib LO baseline (subprocess)" begin
        @test success(run(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "test_lebeda_lo.jl"))`))
    end

    # The RSDR × LODR integration goldens of the composition evaluator (a
    # module of its own).
    include("test_engine_integration.jl")
    # LocalOptimizationDoneRight's strategy tests on the paper's scorer.
    include(joinpath("lodr", "runtests.jl"))

    include("test_experiment_producer.jl")
    include("test_anchoring_ablation.jl")
    include("test_tuning_protocol.jl")
    include("protocol_invariants.jl")
    include("test_protocol_completeness.jl")
    include("test_reproduce_index.jl")
    include("test_data_artifacts.jl")
    include("test_prior_codified.jl")
    include("test_public_paths.jl")
    include("test_paper_project.jl")
    include("test_paper_numbers.jl")
    include("test_e2e_timing.jl")

    # A driver's selector roster names live scoring tags: a retired tag
    # ("ig", "gau", …) is refused only when the produce stage runs.
    @testset "fig1 selector roster names live tags" begin
        src = read(joinpath(@__DIR__, "..", "scripts", "fig1_sel_miscal.jl"), String)
        m = match(r"const SELECTORS = \"([^\"]+)\"", src)
        @test m !== nothing
        for t in split(m[1], ',')
            @test selector_key(t) isa Symbol
        end
    end

    # The LO timing regression gate on the Table 1 arms under the paper's
    # marginal (test/lo_timing/bench.jl). Opt-in; policy, modes and robustness
    # in VisualGeometryCore's test/lo_timing/gate.jl (the stack's one gate):
    #   LO_TIMING_GATE=1      julia --project=. test/runtests.jl
    #   LO_TIMING_GATE=record (same) — rewrites test/lo_timing/baselines.toml
    @testset "lo_timing_gate" begin
        gate = joinpath(pkgdir(VisualGeometryCore), "test", "lo_timing", "gate.jl")
        if isfile(gate)
            g = Module(:_LoTimingGate); Base.include(g, gate)    # in a module of its own
            Base.invokelatest(g.run_lo_timing_gate, joinpath(@__DIR__, "lo_timing"))
        elseif get(ENV, "LO_TIMING_GATE", "") in ("1", "record")
            @test_skip "the resolved VisualGeometryCore ships no test/lo_timing/gate.jl (older than the gate)"
        end
    end
end
