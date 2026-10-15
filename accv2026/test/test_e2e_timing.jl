# =============================================================================
# test_e2e_timing.jl — Tab. 3's time row (configs/pt_e_e2e_timing.toml,
# scripts/e2e_timing.jl, src/e2e_timing.jl): the timing cell's config is
# complete and folds, its drivers hold none of its settings, and every time
# number of the paper comes from its timing.tsv — the table's time row and the
# \EtoE*Ms macros — never from the accuracy run's multithreaded wall clocks
# or a hand-typed value.
# =============================================================================
using Test, TOML

const _T_ROOT = normpath(joinpath(@__DIR__, ".."))
_t_cfg(n) = TOML.parsefile(joinpath(_T_ROOT, "configs", n * ".toml"))

@testset "e2e timing: the config of record" begin
    include(joinpath(_T_ROOT, "src", "config.jl"))
    include(joinpath(_T_ROOT, "src", "cell_stages.jl"))
    include(joinpath(_T_ROOT, "src", "e2e_cells.jl"))
    include(joinpath(_T_ROOT, "src", "e2e_timing.jl"))
    raw = _t_cfg("pt_e_e2e_timing")
    t = raw["timing"]
    # the sample is a COMPLETE table of VisualGeometryEval's unit-sampling vocabulary
    s = VisualGeometryEval.Tuning.read_tuning(VisualGeometryEval.Tuning.UnitSampling, t["sample"])
    @test s isa VisualGeometryEval.Tuning.StratifiedSampling
    @test t["repeats"] >= 4 && t["warmup_pairs"] >= 1
    @test t["pinning"]["julia_threads"] == 1 && t["pinning"]["gc_threads"] == 1
    @test all(k -> haskey(t["pinning"], k), ("launcher", "cpu", "numa_node", "env"))
    @test all(k -> t["pinning"]["env"][k] == "1", ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"))
    cfg = e2e_timing_cell("pt_e_e2e_timing")
    @test cfg["e2e_run"] == run_key(e2e_timed_cell(cfg))      # it times THE e2e cell of record
    @test haskey(cfg, "superansac_run")
    bad = deepcopy(raw); bad["timing"]["repeats"] = 3
    @test_throws ErrorException fold_e2e_timing_cell!(bad)
    bad = deepcopy(raw); bad["timing"]["pinning"]["julia_threads"] = 2
    @test_throws ErrorException fold_e2e_timing_cell!(bad)
    bad = deepcopy(raw); delete!(bad["timing"]["sample"], "seed")      # incomplete: no defaults inherited
    @test_throws ArgumentError fold_e2e_timing_cell!(bad)
end

@testset "e2e timing: the drivers hold no timing setting" begin
    files = [joinpath(_T_ROOT, "scripts", "e2e_timing.jl"), joinpath(_T_ROOT, "scripts", "tools", "e2e_time_ours.jl"),
             joinpath(_T_ROOT, "src", "e2e_timing.jl")]
    keys_ = ("repeats", "warmup_pairs", "warmup", "cpu", "numa_node", "julia_threads", "gc_threads",
             "seed", "fraction", "cap_per_scene", "nthreads", "threads")
    for f in files, l in eachline(f)
        startswith(lstrip(l), "#") && continue
        for k in keys_
            @test !occursin(Regex("\\b$(k)\\s*=\\s*\\d"), l) || (@info "a timing setting in code" f l; false)
        end
        @test !occursin(r"(physcpubind|membind)=\d", l)
        @test !occursin(r"\"-t\",\s*\"\d", l)
    end
end

@testset "e2e timing: every paper time number comes from timing.tsv" begin
    pn = _t_cfg("paper_numbers")
    kinds = Dict(n => s["kind"] for (n, s) in pn["sources"])
    timed = [m for m in pn["macro"] if get(m, "column", "") == "med_wall_ms"]
    @test !isempty(timed)
    @test all(m -> kinds[m["source"]] == "e2e_timing", timed)
    tsrc = only(s for (n, s) in pn["sources"] if s["kind"] == "e2e_timing")
    e2e = only(s for (n, s) in pn["sources"] if s["kind"] == "e2e")
    # the table's time row reads the same timing cell, of the same e2e cell
    @test _t_cfg(e2e["config"])["render"]["time"] == tsrc["config"]
    @test _t_cfg(tsrc["config"])["timing"]["e2e_config"] == e2e["config"]
    # the generated table names its time-row source
    tab = read(joinpath(_T_ROOT, "paper", "figures", "table_e2e.tex"), String)
    @test occursin("the time row from $(tsrc["config"])", tab)
end
