# =============================================================================
# test_e2e_timing_cell.jl — Tab. 3's timing cell of record
# (configs/pt_e_e2e_timing.toml) is complete and folds, and times THE e2e cell
# of record. It loads the e2e drivers (src/cell_stages.jl → src/registry.jl),
# which bind the results root, so it runs only where one is bound: a :data item
# (accv2026_tests.jl). Split from test_e2e_timing.jl, whose other testsets need
# no data.
# =============================================================================
import VisualGeometryToolkitEval as VgtkEval
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
    # the sample is a COMPLETE table of VisualGeometryToolkitEval's unit-sampling vocabulary
    s = VgtkEval.Tuning.read_tuning(VgtkEval.Tuning.UnitSampling, t["sample"])
    @test s isa VgtkEval.Tuning.StratifiedSampling
    @test t["repeats"] >= 4 && t["warmup_pairs"] >= 1
    @test t["pinning"]["julia_threads"] == 1 && t["pinning"]["gc_threads"] == 1
    @test all(k -> haskey(t["pinning"], k), ("launcher", "cpu", "numa_node", "env"))
    @test all(k -> t["pinning"]["env"][k] == "1", ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"))
    cfg = e2e_timing_cell("pt_e_e2e_timing")
    # it times THE e2e cell of record: that run and its SupeRANSAC run key it as upstream runs
    e2e, sr = e2e_timed_cell(cfg), e2e_timed_superansac(cfg)
    @test upstream_runs(cfg) == Dict("e2e" => run_key(e2e; upstream = upstream_runs(e2e)),
                                     "superansac" => run_key(sr; upstream = upstream_runs(sr)))
    bad = deepcopy(raw); bad["timing"]["repeats"] = 3
    @test_throws ErrorException fold_e2e_timing_cell!(bad)
    bad = deepcopy(raw); bad["timing"]["pinning"]["julia_threads"] = 2
    @test_throws ErrorException fold_e2e_timing_cell!(bad)
    bad = deepcopy(raw); delete!(bad["timing"]["sample"], "seed")      # incomplete: no defaults inherited
    @test_throws ArgumentError fold_e2e_timing_cell!(bad)
end
