# =============================================================================
# test_keyed_cells.jl — every output of record is a keyed directory under the
# results root, never under the inputs: Table 1's timings (once written under
# the data root), Fig 1's selection-only sweep (once the hand-bumped stamp
# miscal-sel-allpairs-v5) and Fig 2's ladder (once a --stamp the driver
# derived by hand). Each directory is `<kind>-<run_key>` of its folded config
# (src/protocol_folds.jl), so a change of any keyed input moves it.
# =============================================================================
using Test
using DrWatson: projectdir

mktempdir() do tmp
    data, results = mkpath(joinpath(tmp, "data")), mkpath(joinpath(tmp, "results"))
    withenv("VGTK_DATA_ROOT" => data, "VGTK_RESULTS_ROOT" => results) do
        include(joinpath(@__DIR__, "..", "src", "config.jl"))
        include(joinpath(@__DIR__, "..", "src", "protocol_folds.jl"))
        under(p, root) = startswith(normpath(p), normpath(root) * "/")

        @testset "Table 1 timings: a keyed results directory, never under the data root" begin
            cfg = fold_timing_cell!(config_of_record("timing_table"))
            d = timing_cell_dir(cfg)
            @test under(d, results_root())
            @test !under(d, data_root())
            @test basename(d) == "timing-" * run_key(cfg)
            @test cfg["operating_points_run"] == operating_points_run("pt_e_miscal")   # a re-tune re-keys it
        end

        @testset "Fig 1: keyed by its config, its tuning spec and the ζ ladder" begin
            cfg = fold_sensitivity_cell!(config_of_record("pt_e_sel_miscal"))
            d = sensitivity_cell_dir(cfg)
            @test under(d, results_root())
            @test basename(d) == "sel-miscal-" * run_key(cfg)
            @test haskey(cfg, "tuning_spec_hash") && haskey(cfg, "miscal_protocol")
            other = config_of_record("pt_e_sel_miscal")
            other["sensitivity"]["selectors"] = ["msac"]
            @test sensitivity_cell_dir(fold_sensitivity_cell!(other)) != d
        end

        @testset "Fig 2: the ladder folds its basin cell's run" begin
            lc = ladder_cell("pt_e_basin")
            d = ladder_cell_dir(lc)
            @test under(d, results_root())
            @test basename(d) == "basin-ladder-" * run_key(lc)
            @test lc["operating_points_run"] == operating_points_run("pt_e_basin")
        end
    end
end

# No config switch rides in the environment: the drivers and tools read their
# configs of record and command lines. The bindings that remain are Eval's root
# ladder (VGTK_DATA_ROOT), the data catalog's documented override, the timing
# cell's child-process environment (its config's [timing.pinning] env), the
# Zenodo packer's guard against that override and SupeRANSAC's build env.
@testset "no environment-variable config switches" begin
    allowed = ("VGTK_DATA_ROOT", "ACCV2026_ARTIFACTS_TOML", "CMAKE_PREFIX_PATH", "CONDA_PREFIX", "merge(copy(ENV)")
    proj = normpath(joinpath(@__DIR__, ".."))
    hits = String[]
    for dir in ("src", "scripts"), (r, _, fs) in walkdir(joinpath(proj, dir)), f in fs
        endswith(f, ".jl") || continue
        for (i, l) in enumerate(eachline(joinpath(r, f)))
            code = first(split(l, '#'))
            occursin(r"\bENV\b", code) || continue
            any(a -> occursin(a, code), allowed) && continue
            push!(hits, "$(relpath(joinpath(r, f), proj)):$i  $(strip(l))")
        end
    end
    @test isempty(hits) || (@info "environment-variable config switches" hits; false)
end
