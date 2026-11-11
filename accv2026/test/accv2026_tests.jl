# =============================================================================
# The ACCV 2026 research project's tests as ReTestItems test items (the
# `_tests.jl` name is what ReTestItems discovers), run across worker processes
# by runtests.jl. One item per file of this directory, and one per testset the
# serial runtests.jl held inline; lodr/lodr_tests.jl holds the strategy tests.
#
# Every item runs in a module of its own on some worker, in no fixed order, so
# an item states everything it uses. `default_imports = false`: the project
# (ACCV2026) is not a package, so ReTestItems' implicit `using <project>` has
# nothing to load. The preamble every item opens with is the one the serial
# runner's Main held for all files:
#
#     using Test
#     import VisualGeometryToolkitEval as VgtkEval
#     using VisualGeometryToolkitEval
#     using LocalOptimizationDoneRight
#     import VisualGeometryToolkitCore
#
# Tags (runtests.jl runs each in its own run):
#   :data    needs a bound results root (VGTK_RESULTS_ROOT or data/exp_pro);
#            SKIPPED — a recorded skip, not an error — where none is bound
#   :timing  the LO timing gate, on ONE single-threaded worker after the pool
# =============================================================================

@testitem "paper config registers" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include(joinpath(@__DIR__, "..", "src", "config.jl"))
    # the data a cross-validation samples is declared by the data, not the spec
    @test TWO_VIEW_UNIT === VgtkEval.Tuning.PairUnit()
    @test length(ROSTER.composed(:E)) >= 7
    @test length(ROSTER.solo(:E; role = :refinement)) >= 6
    @test !isempty(PAPER_STYLE.rows)
    @test !isempty(PAPER_STYLE.arms)
end

# The Fig 1 selection roster: every loss-width family with a per-residual quality selects on the CPU (the exact
# selection kernels, VisualGeometryToolkitCore's; best_pool_model per pair), MAGSAC++ and the other RSDR families included.
@testitem "selection roster: the loss-width families select on the CPU" default_imports = false begin
    using Test
    using VisualGeometryToolkitEval
    using VisualGeometryToolkitEval.Pools: synthetic_e_pool_pair
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    using VisualGeometryToolkitCore: best_pool_model, has_residual_quality
    include(joinpath(@__DIR__, "..", "src", "config.jl"))
    specs = solo_specs(:E; role = :selection)
    @test [s.base for s in specs] == ["IG", "MSAC", "RANSAC", "MAGSAC", "GAU", "WEL", "GEM"]
    pair, R = synthetic_e_pool_pair()
    grid = [0.5e-3, 2.0e-3, 8.0e-3]
    for s in specs
        s.axis isa VisualGeometryToolkitCore.LossWidth || continue
        @test has_residual_quality(s.ctor(1.0e-3))
        @test all(w -> 0 < best_pool_model(s.ctor(w), pair, R) <= size(R, 2), grid)
    end
end

# The research-only zero-clamp Welsch-HQ (src/welsch_zero_clamp.jl): VGC
# 92597af's z-block at the clamp, Welsch everywhere else, and the opt-in
# "<key>@zc" arms wired through the rosters.
@testitem "zero-clamp Welsch-HQ variant" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include(joinpath(@__DIR__, "..", "src", "config.jl"))
    VGC = VisualGeometryToolkitCore
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
@testitem "the paper's Welsch-HQ is the zero-clamp arm" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include(joinpath(@__DIR__, "..", "src", "config.jl"))
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
# roster and rebuild the deployed arm settings. Tagged :data and SKIPPED where
# no results root is bound (VisualGeometryToolkitEval's results_root(): ENV
# VGTK_RESULTS_ROOT, else the project's data/exp_pro link); with one bound and
# the sidecar not yet regenerated, it warns.
@testitem "deployed operating-points sidecar gate" default_imports = false tags = [:data] skip = !(
        haskey(ENV, "VGTK_RESULTS_ROOT") ||
        (p = joinpath(dirname(Base.active_project()), "data", "exp_pro"); islink(p) || isdir(p))) begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include(joinpath(@__DIR__, "..", "src", "config.jl"))
    include(joinpath(@__DIR__, "..", "src", "registry.jl"))
    sc = EXP_MISCAL_SIDECAR
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
        @warn "deployed sidecar not found — read gate SKIPPED (not regenerated)" sc
    end
end

# LO-strategy contracts: separate process (the paper config defines verbs that
# collide with the preamble's using-imports under the 1.12 rules), so the item
# counts the subprocess's success, as the serial runner did.
@testitem "LO-strategy contracts (subprocess)" default_imports = false begin
    using Test
    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "test_lo_contracts.jl"))`))
end

# The RansacLib LO arms and the vendored library's suite: separate process for
# the same reason.
@testitem "RansacLib LO baseline (subprocess)" default_imports = false begin
    using Test
    @test success(run(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "test_lebeda_lo.jl"))`))
end

# A driver's selector roster names live scoring tags: a retired tag
# ("ig", "gau", …) is refused only when the produce stage runs.
@testitem "fig1 selector roster names live tags" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include(joinpath(@__DIR__, "..", "src", "config.jl"))
    src = read(joinpath(@__DIR__, "..", "scripts", "fig1_sel_miscal.jl"), String)
    m = match(r"const SELECTORS = \"([^\"]+)\"", src)
    @test m !== nothing
    for t in split(m[1], ',')
        @test selector_key(t) isa Symbol
    end
end

# The LO timing regression gate on the Table 1 arms under the paper's
# marginal (lo_timing/bench.jl). Opt-in; policy, modes and robustness in
# VisualGeometryToolkitCore's test/lo_timing/gate.jl (the stack's one gate):
#   LO_TIMING_GATE=1      julia --project=. test/runtests.jl
#   LO_TIMING_GATE=record (same) — rewrites test/lo_timing/baselines.toml
# Tagged :timing: runtests.jl runs it alone, on one single-threaded worker.
@testitem "lo_timing_gate" default_imports = false tags = [:timing] begin
    using Test
    import VisualGeometryToolkitCore
    gate = joinpath(pkgdir(VisualGeometryToolkitCore), "test", "lo_timing", "gate.jl")
    if isfile(gate)
        g = Module(:_LoTimingGate); Base.include(g, gate)    # in a module of its own
        Base.invokelatest(g.run_lo_timing_gate, joinpath(@__DIR__, "lo_timing"))
    elseif get(ENV, "LO_TIMING_GATE", "") in ("1", "record")
        @test_skip "the resolved VisualGeometryToolkitCore ships no test/lo_timing/gate.jl (older than the gate)"
    end
end

# One item per file below: each file's testsets, unchanged.

@testitem "experiment contracts" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_experiment_contracts.jl")
end

@testitem "config vocabulary" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_config_vocabulary.jl")
end

@testitem "engine integration" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_engine_integration.jl")
end

@testitem "experiment producer" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_experiment_producer.jl")
end

@testitem "anchoring ablation" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_anchoring_ablation.jl")
end

@testitem "tuning protocol" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_tuning_protocol.jl")
end

@testitem "protocol invariants" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("protocol_invariants.jl")
end

@testitem "keyed cells" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_keyed_cells.jl")
end

@testitem "protocol completeness" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_protocol_completeness.jl")
end

@testitem "REPRODUCE index" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_reproduce_index.jl")
end

@testitem "data artifacts" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_data_artifacts.jl")
end

@testitem "prior codified" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_prior_codified.jl")
end

@testitem "public paths" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_public_paths.jl")
end

@testitem "paper numbers" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_paper_numbers.jl")
end

@testitem "e2e timing" default_imports = false begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_e2e_timing.jl")
end

# The two testsets split out of test_anchoring_ablation.jl and
# test_e2e_timing.jl because their drivers bind the results root when they
# load: :data items, skipped like the sidecar gate where none is bound.
@testitem "anchoring ablation: listed by --plan" default_imports = false tags = [:data] skip = !(
        haskey(ENV, "VGTK_RESULTS_ROOT") ||
        (p = joinpath(dirname(Base.active_project()), "data", "exp_pro"); islink(p) || isdir(p))) begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_anchoring_plan.jl")
end

@testitem "e2e timing: the config of record" default_imports = false tags = [:data] skip = !(
        haskey(ENV, "VGTK_RESULTS_ROOT") ||
        (p = joinpath(dirname(Base.active_project()), "data", "exp_pro"); islink(p) || isdir(p))) begin
    using Test
    import VisualGeometryToolkitEval as VgtkEval
    using VisualGeometryToolkitEval
    using LocalOptimizationDoneRight
    import VisualGeometryToolkitCore
    include("test_e2e_timing_cell.jl")
end
