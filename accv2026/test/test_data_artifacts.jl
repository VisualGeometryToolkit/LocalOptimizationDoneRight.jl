# test_data_artifacts.jl — this paper's own rules on its published input data
# (configs/data_artifacts.toml; VisualGeometryToolkitEval DataArtifacts): the catalog binds the
# committed Artifacts.toml, its licences and kinds, and the pool producers' scene
# resolver reads the registered splits. Catalog ⇔ bindings is the paper-project
# check's A1 (test_paper_project.jl).
using Test, TOML
include(joinpath(@__DIR__, "..", "src", "data_artifacts.jl"))

@testset "data artifacts: the catalog of this paper" begin
    # Checked against the COMMITTED bindings, whatever ACCV2026_ARTIFACTS_TOML says.
    cat = withenv(project_catalog, "ACCV2026_ARTIFACTS_TOML" => nothing)
    @test cat.artifacts_toml == normpath(joinpath(@__DIR__, "..", "Artifacts.toml"))
    # (catalog ⇔ bindings: the paper-project check's A1, test_paper_project.jl)
    @test all(r -> r["license"] in ("CC-BY-4.0", "CC-BY-NC-SA-4.0"), values(cat.records))
    # the kinds of THIS paper (no `tree`): every file list derives from a config of record,
    # or the entry is produced by its stage (never bound)
    @test all(a -> a["kind"] in ("pool_sources", "pools", "stored", "produced"), values(cat.artifacts))
    # dataset-centric names (the data are shared by two papers): no paper prefix
    @test !any(n -> startswith(n, "accv2026_"), keys(cat.artifacts))
end

@testset "split_scenes: a pool producer's sides" begin
    @test length(split_scenes("heb:validation")) == 5 && length(split_scenes("heb:test")) == 5
    @test isempty(intersect(split_scenes("phototourism:validation"), split_scenes("phototourism:test")))
    @test_throws ArgumentError split_scenes("heb")
    @test_throws ArgumentError split_scenes("heb:train")
end

# ---- THE DATA POLICY (REPRODUCE.md, "Data policy"), enforced ----------------------
# Inputs are immutable and resolved RELATIVE to data_root() (data/exp_raw: the
# author's primary copy, or the artifact view of the published artifacts);
# derived results are DrWatson-keyed run directories under results_root().

@testset "data policy: input paths are relative to data_root() and never inside the results tree" begin
    cfgdir = normpath(joinpath(@__DIR__, "..", "configs"))
    rel = String[]
    for f in filter(endswith(".toml"), readdir(cfgdir))
        c = TOML.parsefile(joinpath(cfgdir, f))
        ex = get(c, "experiment", nothing)
        ex isa AbstractDict && haskey(ex, "pool_dir") && push!(rel, ex["pool_dir"])
        src = get(c, "source", nothing)
        src isa AbstractDict && append!(rel, (v for (k, v) in src if endswith(k, "_dir") && v isa AbstractString))
    end
    @test !isempty(rel)
    @test all(!isabspath, rel)
    # Bound roots (the author's host, or a fetched machine): no input resolves into the results tree.
    bound = try (data_root(), results_root()) catch; nothing end
    if bound === nothing
        @test_skip "data/results roots not bound on this machine"
    else
        res = realpath(last(bound))
        inside(p) = (q = ispath(p) ? realpath(p) : normpath(p); q == res || startswith(q, res * "/"))
        @test !inside(first(bound))
        bad = [r for r in rel if inside(joinpath(first(bound), r))]
        @test isempty(bad) || (@info "inputs inside the results tree" bad; false)
    end
    # The artifacts mount into data_root(); the ONE declared exception is the stored
    # SupeRANSAC baseline (configs/pt_e_superansac.toml [stored] dir is relative to the
    # results root, where the author's copy sits) — to move with the data-policy audit.
    cat = project_catalog()
    @test Set(n for (n, a) in cat.artifacts if a["kind"] != "produced" && a["mount"] == "results") == Set(["pt_e_superansac_stored"])
end
