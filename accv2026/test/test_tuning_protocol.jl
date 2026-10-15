# =============================================================================
# test_tuning_protocol.jl — THE tuning protocol of record (configs/tuning.toml)
# and its fold into a cell's effective config (src/protocol_folds.jl):
#
#   * every [tuning.<name>] entry parses through VisualGeometryEval's one parser, with
#     the paper-level type defaults ([types.<type>]) layered beneath it;
#   * every entry's data is a registered scene split (VisualGeometryEval
#     configs/splits.toml): the PhotoTourism split by the paper's
#     [types.cross_validation], another through a cell's cv_protocol section;
#     the resolved spec carries the registry's lists;
#   * a tuning cell's effective entries (the coarse_fine entries its
#     [sequential_cv] names) are the protocol entries with its cv_protocol
#     cross-validation section layered in (`layer_tuning`, fold_sequential_cv!)
#     — the per-dataset validation sampling its section's;
#   * ONE scorer per (dataset, model class): a `scorer_of` cell reads the named
#     cell's scorer, keyed by it, and a cell that does not match is refused;
#   * run_key covers EVERY tuning parameter, inherited defaults included: a
#     change to a parameter the cell never states re-keys the run, and the
#     recorded effective config (resolved) keys identically;
#   * the drivers accept exactly the samplings they implement, by signature:
#     two-view = every pair or a stratified sample per scene
#     (src/validation_data.jl).
# =============================================================================
using Test, TOML
using VisualGeometryEval.Tuning, VisualGeometryEval.Experiments

include(joinpath(@__DIR__, "..", "src", "config.jl"))

include(joinpath(@__DIR__, "..", "src", "protocol_folds.jl"))

const _CFGDIR = joinpath(@__DIR__, "..", "configs")
_cell(name) = fold_sequential_cv!(load_run_config(joinpath(_CFGDIR, name * ".toml")))
# A cell's cross-validation: its scorer entry's (every entry it names carries the same).
_cell_cv(cfg) = tuning_spec(cfg, sequential_cv_scorer_entry(cfg["sequential_cv"], :ig)).scheme.cross_validation

@testset "tuning protocol of record" begin
    @testset "every entry parses" begin
        for name in keys(TUNING_PROTOCOL["tuning"])
            spec = tuning_spec(tuning_config(name), name)
            @test spec.name == name
            # lossless: the complete table reads back to the same spec
            @test tuning_spec(tuning_toml(spec), name) == spec
        end
        # the paper's window is stated once, as a type default, and reaches
        # every entry whose scheme holds one
        w = TUNING_PROTOCOL["types"]["scale_multiple_window"]
        for name in ("lo_sensitivity", "lo_sensitivity_natural", "lo_sensitivity_miscal")
            s = tuning_spec(tuning_config(name), name).scheme
            @test (s.scale_multiple_window.lo, s.scale_multiple_window.hi) == (w["lo"], w["hi"])
        end
        # the paper's data, stated once: every entry tunes on the registered
        # PhotoTourism split — the registry's lists, resolved into the spec
        pt = registered_split("phototourism")
        for name in keys(TUNING_PROTOCOL["tuning"])
            cv = protocol_cross_validation(name)
            @test cv.scene_split == pt
            @test tuning_table(tuning_spec(tuning_config(name), name))["cross_validation"]["scene_split"]["test_scenes"] ==
                  pt.test_scenes
        end
    end

    @testset "cell fold: protocol entries ⊕ cross-validation section" begin
        cvp = TOML.parsefile(joinpath(_CFGDIR, "cv_protocol.toml"))
        n = 0
        for f in readdir(_CFGDIR)
            occursin(r"^(accv2026_.*_miscal|pt_e_miscal|heb_h_miscal|pt_e_basin)\.toml$", f) || continue
            raw = TOML.parsefile(joinpath(_CFGDIR, f))
            @test !haskey(raw["experiment"], "split")            # the data is the spec's, stated once
            @test !haskey(raw, "product_tuning")                 # the product grid is retired
            cfg = _cell(first(splitext(f)))
            sec = cvp[raw["protocol"]["cv_section"]]
            cv = _cell_cv(cfg)
            # every entry the cell names: coarse_fine, on the one cross-validation
            for (name, _) in cfg["tuning"]
                spec = tuning_spec(cfg, name)
                @test spec.scheme isa CoarseFine
                @test spec.scheme.cross_validation == cv
            end
            @test cv.scene_split == registered_split(sec["scene_split"]["name"])
            @test cv.validation isa TUNING_TAGS["unit_sampling"][sec["validation"]["type"]]
            cv.validation isa StratifiedSampling && @test cv.validation.fraction == sec["validation"]["fraction"]
            @test cv.test == ExhaustiveSampling()                          # test sides are never subsampled
            @test cv isa TwoViewCrossValidation                  # run_sequential_cv accepts it
            n += 1
        end
        @test n == 4                                             # ETH3D-F, PT-E, HEB-H, the basin
        # every cv_protocol section names a registered split and a sampling tag
        for (k, sec) in cvp
            k == "protocol" && continue
            @test registered_split(sec["scene_split"]["name"]) isa RegisteredSceneSplit
            @test haskey(TUNING_TAGS["unit_sampling"], sec["validation"]["type"])
        end
    end

    @testset "the PT-E tuning of record (configs/pt_e_miscal.toml)" begin
        cfg = _cell("pt_e_miscal")
        cv = _cell_cv(cfg)
        @test cv.scene_split == registered_split("phototourism")
        @test cv.validation isa StratifiedSampling && cv.validation.fraction == 0.25
        @test cfg["sequential_cv"]["plugin_scale"] == "oracle_gt_variance"   # the anchoring ablation's s0
        @test tuning_spec(cfg, "scorer") == tuning_spec(tuning_config("scorer";
            over = cross_validation_over("phototourism")), "scorer")
    end

    @testset "one scorer per (dataset, model class)" begin
        pte, basin = _cell("pt_e_miscal"), _cell("pt_e_basin")
        @test basin["scorer_of_run"] == run_key(pte)
        bound = try results_root(); true catch; false end
        bound && @test sequential_cv_scorer_path(basin) == joinpath(sequential_cv_dir(pte), SEQUENTIAL_CV_SCORER)
        # a cell that is not the same (dataset, model class) is refused
        raw = load_run_config(joinpath(_CFGDIR, "pt_e_basin.toml"))
        raw["experiment"]["problem"] = "F"
        @test_throws ErrorException fold_sequential_cv!(raw)
    end

    @testset "run_key covers every tuning parameter" begin
        cfg = _cell("accv2026_eth_f_miscal")
        key = run_key(cfg)
        # the recorded effective config (resolved: every inherited default
        # stated) keys identically
        resolved = resolve_tuning!(deepcopy(cfg))
        @test haskey(resolved["tuning"]["scorer"]["cross_validation"], "test") &&
              !haskey(cfg["tuning"]["scorer"]["cross_validation"], "test")
        @test run_key(resolved) == key
        # a parameter the cell never states re-keys the run
        other = deepcopy(cfg)
        other["tuning"]["scorer"] = layer_tuning(other["tuning"]["scorer"],
            Dict{String,Any}("edge_margin" => 2))
        @test run_key(other) != key
        # re-deriving the cell's key reaches the same keyed sidecar (needs a
        # bound results root; off the data host it is not)
        bound = try results_root(); true catch; false end
        if bound
            sc = miscal_sidecar_of("accv2026_eth_f_miscal")
            @test basename(sc) == SEQUENTIAL_CV_SIDECAR && occursin(key, sc)
        else
            @info "results root not bound — keyed sidecar path not checked"
        end
    end

    @testset "drivers refuse an unsupported sampling by signature" begin
        heb = registered_split("heb")
        pooled = CrossValidation(heb, UniformSampling(0.5, 0, 1, "StableRNG"), ExhaustiveSampling())
        # two-view: per-scene loaders over the sides, sorted by scene
        sides = two_view_scene_loaders(CrossValidation(heb, StratifiedSampling(0.25, 0, 1, "StableRNG"), ExhaustiveSampling()), mktempdir())
        @test first.(sides.validation) == heb.validation_scenes && first.(sides.test) == heb.test_scenes
        @test_throws MethodError two_view_scene_loaders(pooled, mktempdir())
        # a pooled cap or fraction on the TEST side is refused the same way
        @test_throws MethodError two_view_scene_loaders(
            CrossValidation(heb, ExhaustiveSampling(), UniformSampling(1.0, 10, 1, "StableRNG")), mktempdir())
    end
end
