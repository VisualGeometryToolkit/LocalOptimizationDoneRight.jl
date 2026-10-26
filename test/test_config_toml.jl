# =============================================================================
# The strategies' TOML — configs/default.toml is the ONE default authority of
# this package's strategies, and they load through VisualGeometryToolkitEstimation's one
# entry over the MERGED registry:
#
#     local_optimization_from_toml(d; class, tags = merge(VisualGeometryToolkitEstimation.LO_TAGS, LO_TAGS))
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
using VisualGeometryToolkitCore: AbstractLocalOptimization, GemanMcclureShape, SmoothTLSShape, WelschShape, TagRegistry
using VisualGeometryToolkitEstimation
using VisualGeometryToolkitEstimation: Irls, config_dict, local_optimization_from_toml
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LO_TAGS, BarronAdaptive, StuTuRegemm, _config_default, _TOML_DEFAULTS
const RVG = VisualGeometryToolkitEstimation
const LO = LocalOptimizationDoneRight

const TAGS = merge(RVG.LO_TAGS, LO.LO_TAGS)
load(d; class = :homography) = local_optimization_from_toml(d; class, tags = TAGS)
# A width-carrying strategy's scale multiple (its `ScaleMultiple` width mode).
sm(lo) = VgtkCore.lo_width(lo).value

@testset "the strategies' TOML" begin

    @testset "the default names ONE thing" begin
        # Every strategy's keyword defaults ARE its table.
        @test StudentTUniform().max_iter == _config_default("local_optimization.student_t_uniform", "max_iter")
        @test HQ{WelschShape}(scale_multiple = 1.0).max_iter == _config_default("local_optimization.hq", "max_iter")
        @test HQ{SmoothTLSShape}(scale_multiple = 1.0).max_iter == _config_default("local_optimization.hq", "max_iter_smooth_tls")
        @test HQ{WelschShape}(scale_multiple = 1.0).μ == _config_default("local_optimization.hq", "mu")
        @test Gnc{Irls{WelschShape}}(scale_multiple = 1.0).factor == _config_default("local_optimization.gnc", "factor")
        @test isnan(Gnc{Irls{WelschShape}}(scale_multiple = 1.0).entry)      # "r_max" in the file
        @test StuTuRegemm().lut_points == _config_default("local_optimization.stu_tu_regemm", "lut_points")
        @test BarronAdaptive(scale_multiple = 1.5).α_min == _config_default("local_optimization.barron_adaptive", "alpha_min")
        @test LO.GmHqEps(scale_multiple = 1.0).max_iter == _config_default("local_optimization.gm_hq_eps", "max_iter")
    end

    @testset "the file is complete over every strategy field" begin
        # `scale_multiple` / `alpha` are REQUIRED per call, deliberately absent:
        # a scale multiple is cross-validated per model class, never defaulted
        # in the file, for EVERY arm that takes one.
        required = Dict(
            "hq" => (:scale_multiple,), "gnc" => (:scale_multiple,),
            "barron_hq" => (:α, :scale_multiple),
            "welsch_hq_newton" => (:scale_multiple,), "welsch_hq_ecm" => (:scale_multiple,),
            "barron_adaptive" => (:scale_multiple,), "gm_hq_eps" => (:scale_multiple,),
        )
        for (tag, T) in LO_TAGS
            tbl = _TOML_DEFAULTS["local_optimization"][tag]
            for f in fieldnames(T)
                f in get(required, tag, ()) && continue
                f in VgtkCore.toml_skip_fields(T) && continue   # the width is not a config key
                @test haskey(tbl, VgtkCore.toml_key(T, f))
            end
        end
        # ...and the converse, asserted rather than assumed.
        for (tag, fields) in required, f in fields
            @test !haskey(_TOML_DEFAULTS["local_optimization"][tag], VgtkCore.toml_key(LO_TAGS[tag], f))
        end
    end

    @testset "round trip: every tag, through the merged registry" begin
        # Both registries' tags, no overlap.
        @test isempty(intersect(collect(keys(RVG.LO_TAGS)), collect(keys(LO_TAGS))))
        @test sort(collect(keys(TAGS))) == sort([collect(keys(RVG.LO_TAGS)); collect(keys(LO_TAGS))])
        for (tag, T) in LO_TAGS
            takes_scale_multiple = :width in fieldnames(T) || hasfield(T, :scale_multiple)
            # the minimal table for this tag: only the keys it actually takes
            tbl = Dict{String, Any}("type" => tag)
            RVG.lo_parametric(T) && (tbl["loss"] = "welsch")
            takes_scale_multiple && (tbl["scale_multiple"] = 1.0)
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
        for lo in (HQ{GemanMcclureShape}(loss_width = 2.5, max_iter = 7), Gnc{Irls{GemanMcclureShape}}(scale_multiple = 1.5, factor = 1.7),
                   LO.WelschHQEcm(scale_multiple = 1.5, max_iter = 9), LO.BarronHQ(-2.0; scale_multiple = 1.5))
            @test load(config_dict(lo)) == lo
        end
        # the core's own strategies load through the merged registry unchanged
        @test load(Dict("type" => "irls", "loss" => "welsch", "scale_multiple" => 1.5)) == Irls{WelschShape}(scale_multiple = 1.5)
        @test load(Dict("type" => "no_local_optimization")) == NoLocalOptimization()
    end

    @testset "loaders: present keys override, absent keys inherit" begin
        e = load(Dict("type" => "gnc", "inner" => "irls", "loss" => "welsch", "scale_multiple" => "cross_validated",
                      "factor" => 2.0, "budget" => "converged"); class = :essential)
        @test e isa Gnc{Irls{WelschShape}}
        @test sm(e) == tuning_constant(:essential, "welsch").scale_multiple
        @test e.factor == 2.0 && e.budget === :converged
        @test isnan(e.entry)                                             # inherited "r_max"
        @test e.max_iter == _config_default("local_optimization.gnc", "max_iter")
    end

    @testset "a cross-validated scale multiple is not substituted across shapes" begin
        lo_from(loss, scale_multiple) = load(Dict("type" => "hq", "loss" => loss, "scale_multiple" => scale_multiple))
        @test sm(lo_from("welsch", "cross_validated")) == tuning_constant(:homography, "welsch").scale_multiple
        # the paper's per-class recipe: the class's own operating point
        for class in (:homography, :fundmat, :essential, :absolute_pose, :radial_homography, :radial_camera)
            lo = load(Dict("type" => "hq", "loss" => "welsch", "scale_multiple" => "cross_validated"); class)
            @test lo == HQ{WelschShape}(scale_multiple = tuning_constant(class, "welsch").scale_multiple)
        end
        # A shape with no entry for this class is REFUSED, not served the
        # Welsch number.
        @test_throws ErrorException lo_from("geman_mcclure", "cross_validated")
        @test_throws ErrorException lo_from("cauchy", "cross_validated")
        # ...including the fixed-loss arms, whose shape their type names.
        @test_throws ErrorException load(Dict("type" => "barron_adaptive", "scale_multiple" => "cross_validated"))
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
        @test occursin("literal `scale_multiple`", msg)   # way out 1
        @test occursin("[[tuning_constants]]", msg)   # way out 2
        # A LITERAL scale multiple claims no provenance, so any shape may take one.
        @test sm(lo_from("geman_mcclure", 1.25)) == 1.25
        @test sm(lo_from("cauchy", 0.9)) == 0.9
        @test_throws ArgumentError lo_from("welsch", "not_a_number")
        # The retired spellings fail loudly: an old `k` or `kernel` key is an
        # unknown key, never silently read.
        @test_throws ArgumentError load(Dict("type" => "hq", "kernel" => "welsch", "scale_multiple" => 1.0))
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welsch", "k" => 1.0))
    end

    @testset "bad tables are refused, never silently defaulted" begin
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welch", "scale_multiple" => 1.0))       # unknown loss
        @test_throws ArgumentError load(Dict("type" => "hqq", "loss" => "welsch", "scale_multiple" => 1.0))     # unknown type
        # no width: the strategy follows the scorer's inlier threshold (not a refusal)
        @test VgtkCore.lo_width(load(Dict("type" => "hq", "loss" => "welsch"))) === nothing
        @test_throws ArgumentError load(Dict("type" => "welsch_hq_ecm"))                                        # its scale_multiple is required
        @test_throws ArgumentError load(Dict("type" => "barron_hq", "scale_multiple" => 1.0))                   # its alpha is required
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welsch", "scale_multiple" => 1.0, "loss_width" => 2.0))   # both widths
        @test_throws ArgumentError load(Dict("type" => "hq", "loss" => "welsch", "scale_multiple" => 1.0, "max_itr" => 3))       # typo'd knob
        @test_throws ArgumentError load(Dict("type" => "gnc", "inner" => "hq", "loss" => "welsch", "scale_multiple" => 1.0))     # inner must be irls
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
            load(Dict("type" => "none")); ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("no_local_optimization", msg)
    end

    @testset "the core's registry alone refuses this package's tags" begin
        for (tbl, class) in ((Dict("type" => "hq", "loss" => "welsch", "scale_multiple" => 1.5), :homography),
                             (Dict("type" => "student_t_uniform"), :hand_eye),
                             (Dict("type" => "stu_tu_bcd"), :essential))
            @test_throws Exception local_optimization_from_toml(tbl; class)
            @test load(tbl; class) isa AbstractLocalOptimization
        end
        # and a cross-validated width on a core strategy is the core loader's refusal,
        # naming this package; with the merged registry it is still the core's
        # strategy, which has no tuning constants
        @test_throws ArgumentError local_optimization_from_toml(
            Dict("type" => "irls", "loss" => "welsch", "scale_multiple" => "cross_validated"); class = :homography)
        @test TAGS isa TagRegistry
    end
end
