# =============================================================================
# test_e2e_timing.jl — Tab. 3's time row (configs/pt_e_e2e_timing.toml,
# scripts/e2e_timing.jl, src/e2e_timing.jl): the timing cell's config is
# complete and folds, its drivers hold none of its settings, and every time
# number of the paper comes from its timing.tsv — the table's time row and the
# \EtoE*Ms macros — never from the accuracy run's multithreaded wall clocks
# or a hand-typed value.
# =============================================================================
import VisualGeometryToolkitEval as VgtkEval
using Test, TOML

const _T_ROOT = normpath(joinpath(@__DIR__, ".."))
_t_cfg(n) = TOML.parsefile(joinpath(_T_ROOT, "configs", n * ".toml"))

# "e2e timing: the config of record" loads the drivers, which bind the results
# root: test_e2e_timing_cell.jl (a :data item).

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
