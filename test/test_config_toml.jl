# =============================================================================
# The strategies' TOML — configs/default.toml is the ONE default authority of
# this package's strategies, and they load through VisualGeometryToolkitEstimation's one
# entry over the MERGED registry:
#
#     optimization_strategy_from_toml(d; class, tags = merge(VisualGeometryToolkitEstimation.OPTIMIZATION_STRATEGY_TAGS, LODR_STRATEGY_TAGS))
#
# What this pins: the shipped file is what the constructors default to and is
# complete over every strategy field; every tag round-trips through
# `config_dict`; "cross_validated" resolves the class's tuning constant for the
# strategy's own shape and nothing else; retired tags name their successor;
# the core's registry alone refuses this package's tags. (Moved from
# VisualGeometryToolkitEstimation's test/config_toml_tests.jl with the strategies.)
# =============================================================================
import VisualGeometryToolkitCore as VgtkCore
using Test
using TOML
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: AbstractOptimizationStrategy, GemanMcclureShape, SmoothTLSShape, WelschShape, TagRegistry
using VisualGeometryToolkitEstimation
using VisualGeometryToolkitEstimation: config_dict, optimization_strategy_from_toml
using VisualGeometryToolkitCore: Irls
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LODR_STRATEGY_TAGS, BarronAdaptive, StuTuRegemm, _config_default, _DEFAULTS_OF_RECORD
const RVG = VisualGeometryToolkitEstimation
const LO = LocalOptimizationDoneRight

const TAGS = merge(RVG.OPTIMIZATION_STRATEGY_TAGS, LO.LODR_STRATEGY_TAGS)
load(d; class = :homography) = optimization_strategy_from_toml(d; class, tags = TAGS)
# A width-carrying strategy's efficiency constant (its `EfficiencyConstant` width mode).
sm(lo) = VgtkCore.lo_width(lo).value

@testset "the strategies' TOML" begin

    @testset "the default names ONE thing" begin
        # Every strategy's keyword defaults ARE its table.
        @test StudentTUniform().max_iter == _config_default("optimization_strategy.student_t_uniform", "max_iter")
        @test HQ{WelschShape}(efficiency_constant = 1.0).max_iter == _config_default("optimization_strategy.hq", "max_iter")
        @test HQ{SmoothTLSShape}(efficiency_constant = 1.0).max_iter == _config_default("optimization_strategy.hq", "max_iter_smooth_tls")
        @test HQ{WelschShape}(efficiency_constant = 1.0).μ == _config_default("optimization_strategy.hq", "mu")
        @test Gnc{Irls{WelschShape}}(efficiency_constant = 1.0).factor == _config_default("optimization_strategy.gnc", "factor")
        @test isnan(Gnc{Irls{WelschShape}}(efficiency_constant = 1.0).entry)      # "r_max" in the file
        @test StuTuRegemm().lut_points == _config_default("optimization_strategy.stu_tu_regemm", "lut_points")
        @test BarronAdaptive(efficiency_constant = 1.5).α_min == _config_default("optimization_strategy.barron_adaptive", "alpha_min")
        @test LO.GmHqEps(efficiency_constant = 1.0).max_iter == _config_default("optimization_strategy.gm_hq_eps", "max_iter")
    end

    @testset "the file is complete over every strategy field" begin
        # `efficiency_constant` / `alpha` are REQUIRED per call, deliberately absent:
        # an efficiency constant is cross-validated per model class, never defaulted
        # in the file, for EVERY arm that takes one.
        required = Dict(
            "hq" => (:efficiency_constant,), "gnc" => (:efficiency_constant,),
            "barron_hq" => (:α, :efficiency_constant),
            "welsch_hq_newton" => (:efficiency_constant,), "welsch_hq_ecm" => (:efficiency_constant,),
            "barron_adaptive" => (:efficiency_constant,), "gm_hq_eps" => (:efficiency_constant,),
        )
        for (tag, T) in LODR_STRATEGY_TAGS
            tbl = _DEFAULTS_OF_RECORD["optimization_strategy"][tag]
            for f in fieldnames(T)
                f in get(required, tag, ()) && continue
                f in VgtkCore.toml_skip_fields(T) && continue   # the width is not a config key
                @test haskey(tbl, VgtkCore.toml_key(T, f))
            end
        end
        # ...and the converse, asserted rather than assumed.
        for (tag, fields) in required, f in fields
            @test !haskey(_DEFAULTS_OF_RECORD["optimization_strategy"][tag], VgtkCore.toml_key(LODR_STRATEGY_TAGS[tag], f))
        end
    end

    @testset "round trip: every tag, through the merged registry" begin
        # Both registries' tags, no overlap ("none", no strategy, is the core's alone).
        @test isempty(intersect(collect(keys(RVG.OPTIMIZATION_STRATEGY_TAGS)), collect(keys(LODR_STRATEGY_TAGS))))
        @test !haskey(LODR_STRATEGY_TAGS, "none") && RVG.OPTIMIZATION_STRATEGY_TAGS["none"] === nothing
        @test sort(collect(keys(TAGS))) == sort([collect(keys(RVG.OPTIMIZATION_STRATEGY_TAGS)); collect(keys(LODR_STRATEGY_TAGS))])
        for (tag, T) in LODR_STRATEGY_TAGS
            takes_efficiency_constant = :width in fieldnames(T) || hasfield(T, :efficiency_constant)
            # the minimal table for this tag: only the keys it actually takes
            tbl = Dict{String, Any}("type" => tag)
            VgtkCore.lo_parametric(T) && (tbl["loss"] = "welsch")
            takes_efficiency_constant && (tbl["efficiency_constant"] = 1.0)
            tag == "barron_hq" && (tbl["alpha"] = 0.5)
            lo = load(tbl)
            @test lo isa T
            d = config_dict(lo)
            @test d["type"] == tag
            for f in fieldnames(T)
                f in VgtkCore.toml_skip_fields(T) && continue   # the width: not a config key
                @test haskey(d, VgtkCore.toml_key(T, f))
            end
            @test load(d) == lo
            # the table survives the file round trip too
            @test load(TOML.parse(sprint(TOML.print, d))) == lo
        end
        # the writer covers a loss width, a GNC inner loss and a retuned knob
        for lo in (HQ{GemanMcclureShape}(loss_width = 2.5, max_iter = 7), Gnc{Irls{GemanMcclureShape}}(efficiency_constant = 1.5, factor = 1.7),
                   LO.WelschHQEcm(efficiency_constant = 1.5, max_iter = 9), LO.BarronHQ(-2.0; efficiency_constant = 1.5))
            @test load(config_dict(lo)) == lo
        end
        # the core's own strategies load through the merged registry unchanged
        @test load(Dict("type" => "irls", "loss" => "welsch", "efficiency_constant" => 1.5)) == Irls{WelschShape}(efficiency_constant = 1.5)
        @test load(Dict("type" => "none")) === nothing   # no local optimization
    end

    @testset "loaders: present keys override, absent keys inherit" begin
        e = load(Dict("type" => "gnc", "inner" => "irls", "loss" => "welsch", "efficiency_constant" => "cross_validated",
                      "factor" => 2.0, "budget" => "converged"); class = :essential)
        @test e isa Gnc{Irls{WelschShape}}
        @test sm(e) == tuning_constant(:essential, "welsch").efficiency_constant
        @test e.factor == 2.0 && e.budget === :converged
        @test isnan(e.entry)                                             # inherited "r_max"
        @test e.max_iter == _config_default("optimization_strategy.gnc", "max_iter")
    end

    @testset "a cross-validated efficiency constant is not substituted across shapes" begin
        lo_from(loss, efficiency_constant) = load(Dict("type" => "hq", "loss" => loss, "efficiency_constant" => efficiency_constant))
        @test sm(lo_from("welsch", "cross_validated")) == tuning_constant(:homography, "welsch").efficiency_constant
        # the paper's per-class recipe: the class's own operating point
        for class in (:homography, :fundmat, :essential, :absolute_pose, :radial_homography, :radial_camera)
            lo = load(Dict("type" => "hq", "loss" => "welsch", "efficiency_constant" => "cross_validated"); class)
            @test lo == HQ{WelschShape}(efficiency_constant = tuning_constant(class, "welsch").efficiency_constant)
        end
        # A shape with no entry for this class is REFUSED, not served the
        # Welsch number.
        @test_throws ErrorException lo_from("geman_mcclure", "cross_validated")
        @test_throws ErrorException lo_from("cauchy", "cross_validated")
        # ...including the fixed-loss arms, whose shape their type names.
        @test_throws ErrorException load(Dict("type" => "barron_adaptive", "efficiency_constant" => "cross_validated"))
        # The refusal is ACTIONABLE: it names the requested shape, what is
        # registered, the citing cell, and both ways out.
        msg = try
            lo_from("geman_mcclure", "cross_validated"); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("geman_mcclure", msg)          # the shape asked for
        @test occursin("welsch", msg)                 # the shape on file
        @test occursin("pt_e_miscal.toml", msg)       # the tuning of record that produced it
        @test occursin("literal `efficiency_constant`", msg)   # way out 1
        @test occursin("[[tuning_constants]]", msg)   # way out 2
        # A LITERAL efficiency constant claims no provenance, so any shape may take one.
        @test sm(lo_from("geman_mcclure", 1.25)) == 1.25
        @test sm(lo_from("cauchy", 0.9)) == 0.9
        @test_throws ArgumentError lo_from("welsch", "not_a_number")
        # The retired spellings fail loudly: an old `k` or `kernel` key is an
        # unknown key, never silently read.
        @test_throws ArgumentError load(Dict("type" => "hq", "kernel" => "welsch", "efficiency_constant" => 1.0))
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welsch", "k" => 1.0))
    end

    @testset "bad tables are refused, never silently defaulted" begin
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welch", "efficiency_constant" => 1.0))       # unknown loss
        @test_throws ArgumentError load(Dict("type" => "hqq", "loss" => "welsch", "efficiency_constant" => 1.0))     # unknown type
        # no width: the strategy follows the scorer's inlier threshold (not a refusal)
        @test VgtkCore.lo_width(load(Dict("type" => "hq", "loss" => "welsch"))) === nothing
        @test_throws ArgumentError load(Dict("type" => "welsch_hq_ecm"))                                        # its efficiency_constant is required
        @test_throws ArgumentError load(Dict("type" => "barron_hq", "efficiency_constant" => 1.0))                   # its alpha is required
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welsch", "efficiency_constant" => 1.0, "loss_width" => 2.0))   # both widths
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welsch", "efficiency_constant" => 1.0, "max_itr" => 3))       # typo'd knob
        @test_throws ArgumentError load(Dict("type" => "gnc", "inner" => "hq", "loss" => "welsch", "efficiency_constant" => 1.0))     # inner must be irls
    end

    @testset "retired tags name their successor" begin
        for (old, new) in ("stutu_bcd" => "stu_tu_bcd", "stutu_hq_tabulated" => "stu_tu_hq_tabulated",
                           "stutu_regemm" => "stu_tu_regemm")
            msg = try
                load(Dict("type" => old)); ""
            catch e
                sprint(showerror, e)
            end
            @test !isempty(msg)
            @test occursin(new, msg)
            @test haskey(TAGS, new) && !haskey(TAGS, old)
        end
        # the core's retired tag is carried by the merge too
        msg = try
            load(Dict("type" => "no_local_optimization")); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("\"none\"", msg)
    end

    @testset "the core's registry alone refuses this package's tags" begin
        for (tbl, class) in ((Dict("type" => "hq", "loss" => "welsch", "efficiency_constant" => 1.5), :homography),
                             (Dict("type" => "student_t_uniform"), :hand_eye),
                             (Dict("type" => "stu_tu_bcd"), :essential))
            @test_throws Exception optimization_strategy_from_toml(tbl; class)
            @test load(tbl; class) isa AbstractOptimizationStrategy
        end
        # and a cross-validated width on a core strategy is the core loader's refusal,
        # naming this package; with the merged registry it is still the core's
        # strategy, which has no tuning constants
        @test_throws ArgumentError optimization_strategy_from_toml(
            Dict("type" => "irls", "loss" => "welsch", "efficiency_constant" => "cross_validated"); class = :homography)
        @test TAGS isa TagRegistry
    end
end

# The Student-t keyword rule (owner ruling 2026-11-11): the Student-t + uniform scorer takes its outlier half-width
# (`outlier_halfwidth`) and never a `threshold`; the threshold scorers take `threshold` and never `outlier_halfwidth`.
# The posterior-weight strategies of this package read the half-width off the scorer (`required_outlier_halfwidth`),
# so their own tables carry neither key.
@testset "the Student-t path: outlier_halfwidth, never threshold" begin
    P = RVG.EssentialProblem
    # a Student-t scoring table with `threshold` is refused, by name
    msg = try
        RVG.scoring_from_toml(Dict("type" => "student_t_uniform", "thres" * "hold" => 3.0); problem = P); ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("threshold", msg)
    # and the constructor takes no MSAC width keyword
    @test_throws MethodError VgtkCore.StudentTUniformScoring(P, 250.0; Symbol("thres" * "hold") => 3.0,
        scale_prior = VgtkCore.JeffreysPrior(), label_prior = VgtkCore.FlatLabelPrior())
    # a threshold scorer takes no `outlier_halfwidth`
    @test_throws MethodError VgtkCore.MsacScoring(P; outlier_halfwidth = 3.0)
    # the table's `outlier_halfwidth` reaches the scorer exactly, and is what the posterior-weight strategies read
    sc = RVG.scoring_from_toml(Dict("type" => "student_t_uniform", "outlier_halfwidth" => 250.0); problem = P)
    @test sc isa VgtkCore.StudentTUniformScoring
    @test VgtkCore.outlier_halfwidth(sc) === 250.0
    @test RVG.required_outlier_halfwidth(sc) === 250.0
    # the strategies' own tables carry no width of the scorer's: neither key is accepted
    for type in ("student_t_uniform", "stu_tu_bcd"), key in ("thres" * "hold", "outlier_halfwidth")
        @test_throws ArgumentError load(Dict("type" => type, key => 3.0); class = :essential)
    end
end

# One defaults reader (robust-config-one-schema): the package parses its defaults of
# record through VisualGeometryToolkitCore's `parse_defaults` (which records the file as a
# precompilation dependency), never a TOML.parsefile of its own.
@testset "the defaults of record are read by Core's parse_defaults" begin
    src = joinpath(pkgdir(LocalOptimizationDoneRight), "src")
    hits = [relpath(joinpath(r, f), src) for (r, _, fs) in walkdir(src) for f in fs
            if endswith(f, ".jl") && occursin("TOML.parsefile", read(joinpath(r, f), String))]
    @test isempty(hits)
    @test LO._DEFAULTS_OF_RECORD == VgtkCore.parse_defaults(joinpath(pkgdir(LocalOptimizationDoneRight), "configs", "default.toml"))
end
