# =============================================================================
# The cross-validated operating points — [[tuning_constants]] in
# configs/default.toml, read through `tuning_constant` — and their one-source
# provenance. (Moved from VisualGeometryToolkitEstimation's test/fitting_pipelines_tests.jl
# and test/config_toml_tests.jl with the tuning constants.)
# =============================================================================
using Test
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: WELSCH_HQ_SCALE_MULTIPLE_ABSOLUTE_POSE, WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL,
    WELSCH_HQ_SCALE_MULTIPLE_FUNDMAT, WELSCH_HQ_SCALE_MULTIPLE_HOMOGRAPHY, TuningConstant, TuningProvenance
const LO = LocalOptimizationDoneRight

@testset "tuning constants" begin
@testset "the registry IS the [[tuning_constants]] array" begin
    @test length(LO._TOML_DEFAULTS["tuning_constants"]) == length(LO._TUNING_CONSTANTS)
    @test WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL == tuning_constant(:essential, "welsch").scale_multiple == 1.597
    @test tuning_constant(:radial_homography, "welsch").scale_multiple == tuning_constant(:homography, "welsch").scale_multiple
    @test !tuning_constant(:radial_homography, "welsch").validated
    # Every entry declares the SHAPE it was validated for.
    @test all(v.shape == "welsch" for v in values(LO._TUNING_CONSTANTS))
    @test tuning_constant(:essential, "welsch") isa TuningConstant
    @test tuning_constant(:essential, "welsch").tuning isa TuningProvenance
    # the old spelling of the scale multiple is an unknown key, never read
    @test_throws ArgumentError LO._tuning_registry([
        Dict("problem" => "essential", "features" => "any", "dataset" => "any", "shape" => "welsch",
             "k" => 1.0, "tuning" => Dict("config" => "c.toml", "name" => "n", "hash" => "h", "arm" => "a")),
    ])
end

@testset "tuning constants are the single authority" begin
    # The exported constants must BE the registry entries — a literal
    # drifting into a find_* signature is exactly what this catches.
    @test WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL == tuning_constant(:essential, "welsch").scale_multiple
    @test WELSCH_HQ_SCALE_MULTIPLE_FUNDMAT == tuning_constant(:fundmat, "welsch").scale_multiple
    @test WELSCH_HQ_SCALE_MULTIPLE_HOMOGRAPHY == tuning_constant(:homography, "welsch").scale_multiple
    @test WELSCH_HQ_SCALE_MULTIPLE_ABSOLUTE_POSE == tuning_constant(:absolute_pose, "welsch").scale_multiple

    # Resolution walks (problem, features, dataset) → (problem, :any, :any).
    # The specific tier must resolve to ITS registry entry, and that entry
    # must differ from the :any fallback — otherwise the test cannot tell a
    # working resolution from one that always falls through. (It used to
    # compare the call with itself, which no resolution bug could fail.)
    specific = only(
        e for e in LO._TOML_DEFAULTS["tuning_constants"]
            if e["problem"] == "essential" && e["features"] == "splg" &&
            e["dataset"] == "scannet1500" && e["shape"] == "welsch"
    )
    splg_scale_multiple = tuning_constant(:essential, "welsch"; features = :splg, dataset = :scannet1500).scale_multiple
    @test splg_scale_multiple == specific["scale_multiple"]
    @test splg_scale_multiple != tuning_constant(:essential, "welsch").scale_multiple
    @test tuning_constant(:essential, "welsch"; features = :nope, dataset = :nope).scale_multiple ==
        tuning_constant(:essential, "welsch").scale_multiple
    @test_throws ErrorException tuning_constant(:not_a_model_class, "welsch")
end

@testset "tuning constants carry one-source provenance" begin
    LOD = LocalOptimizationDoneRight
    # A validated entry names the product tuning that produced it.
    pt = tuning_constant(:essential, "welsch"; features = :sift, dataset = :phototourism)
    @test pt.validated && pt.transfer === nothing
    # `name` follows the accv2026 rename of [tuning.miscal] to [tuning.default]
    # (configs/default.toml since RVG ef852ce); `hash` still names the spec
    # that produced the value.
    @test pt.tuning.name == "default" && pt.tuning.arm == "IG  +Lift"
    @test endswith(pt.tuning.config, ".toml") && occursin(r"^[0-9a-f]{16}$", pt.tuning.hash)
    # A transfer borrows its source's value AND provenance; it never restates scale_multiple.
    cls = tuning_constant(:essential, "welsch")
    @test !cls.validated && cls.transfer == (:essential, :sift, :phototourism)
    @test cls.scale_multiple == pt.scale_multiple && cls.tuning == pt.tuning
    rh = tuning_constant(:radial_homography, "welsch")          # a two-link chain
    @test rh.transfer == (:homography, :any, :any) && rh.scale_multiple == pt.scale_multiple && rh.tuning == pt.tuning
    @test all(!haskey(e, "scale_multiple") for e in LOD._TOML_DEFAULTS["tuning_constants"] if haskey(e, "transfer"))
    # The loader refuses what the schema forbids.
    val(; kw...) = merge(Dict{String,Any}("problem" => "essential", "features" => "any", "dataset" => "any",
        "shape" => "welsch", "scale_multiple" => 1.0, "tuning" => Dict("config" => "c.toml", "name" => "n",
        "hash" => "0123456789abcdef", "arm" => "A")), Dict{String,Any}(String(key) => v for (key, v) in kw))
    xfer(p, f, d; kw...) = merge(Dict{String,Any}("problem" => p, "features" => f, "dataset" => d,
        "shape" => "welsch", "transfer" => Dict("problem" => "essential", "features" => "any",
        "dataset" => "any")), Dict{String,Any}(String(key) => v for (key, v) in kw))
    @test length(LOD._tuning_registry([val(), xfer("fundmat", "any", "any")])) == 2
    @test_throws ArgumentError LOD._tuning_registry([xfer("fundmat", "any", "any")])           # dangling
    @test_throws ArgumentError LOD._tuning_registry([val(), xfer("fundmat", "any", "any"; scale_multiple = 1.0)])  # scale_multiple restated
    @test_throws ArgumentError LOD._tuning_registry([val(transfer = Dict("problem" => "x", "features" => "any", "dataset" => "any"))])
    @test_throws ArgumentError LOD._tuning_registry([val(cell = "x")])                      # unknown key
    @test_throws ArgumentError LOD._tuning_registry([val(), val()])                          # duplicate
    cyc = [xfer("fundmat", "any", "any"; transfer = Dict("problem" => "homography", "features" => "any", "dataset" => "any")),
           xfer("homography", "any", "any"; transfer = Dict("problem" => "fundmat", "features" => "any", "dataset" => "any"))]
    @test_throws ArgumentError LOD._tuning_registry(cyc)
    # pending re-validation: the producing hash stays, the pending one is stated beside it
    tval(; kw...) = val(tuning = merge(Dict{String,Any}("config" => "c.toml", "name" => "n",
        "hash" => "0123456789abcdef", "arm" => "A"), Dict{String,Any}(String(key) => v for (key, v) in kw)))
    reg = LOD._tuning_registry([tval(pending_hash = "fedcba9876543210")])
    p = only(values(reg)).tuning
    @test p.hash == "0123456789abcdef" && p.pending_hash == "fedcba9876543210"
    @test only(values(LOD._tuning_registry([val()]))).tuning.pending_hash === nothing
    @test_throws ArgumentError LOD._tuning_registry([tval(pending_hash = "0123456789abcdef")])   # nothing pending
    @test_throws ArgumentError LOD._tuning_registry([tval(revalidated = "x")])                  # unknown key
end
end
