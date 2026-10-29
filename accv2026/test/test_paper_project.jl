# =============================================================================
# test_paper_project.jl — the stack's paper-project conventions
# (VisualGeometryToolkitEval `PaperProjects.paper_project_violations`): the layout,
# the data policy (D1–D4), the REPRODUCE.md asset index against what the two
# papers read, configs of record, provenance and the data catalog. Opt-outs
# with their reasons sit in the files they excuse (`# paper-project: allow
# <RULE> <reason>`); the deferred data-policy violations are listed here, each
# with its fix. An entry that stops matching fails as STALE, so the list only
# shrinks, and any NEW violation fails.
# =============================================================================
using Test
using VisualGeometryToolkitEval.PaperProjects: paper_project_violations
using VisualGeometryToolkitEval.Experiments: DataPolicyAllow

const PAPER_PROJECT_ALLOW = [
    # D2 — the timing tables are RESULTS written under the data root. Fix:
    # EXP_TIMING_DIR = joinpath(EXP_RESULTS_ROOT, "phototourism", "sift", "E",
    # "Timing", "timing-" * <run key of configs/timing_table.toml>) and move the tree.
    DataPolicyAllow("D2", "src/registry.jl", "EXP_TIMING_DIR = joinpath(EXP_DATA_ROOT, \"results\", \"lo_timing\")"),
    # D3 — oracle_floors.jld2: one unkeyed file at the top of the results tree,
    # rewritten by every cell's oracle stage. Fix: a keyed file per cell,
    # joinpath(<cell's keyed dir>, "oracle_floor.jld2"), read through one function.
    DataPolicyAllow("D3", "src/common.jl", "oracle_floor_done(oracle_floors_path(), tag; kw...)"),
    DataPolicyAllow("D3", "scripts/tools/compute_supp_oracle_floors.jl", "write_oracle_floor!(oracle_floors_path()"),
    DataPolicyAllow("D3", "scripts/tools/render_miscal_faceted.jl", "JLD2.load(oracle_floors_path(), \"floors\")"),
    DataPolicyAllow("D3", "src/paper_numbers.jl", "JLD2.load(oracle_floors_path(), \"floors\")"),
    # D3 — fig1's hand-bumped stamp. Fix: key the bundle directory by the run
    # key of its effective config (Miscalibration/miscal-sel-<run_key>).
    DataPolicyAllow("D3", "src/registry.jl", "EXP_SEL_MISCAL_TAG    = \"miscal-sel-allpairs-v5\""),
]

@testset "paper-project conventions" begin
    v = paper_project_violations(normpath(joinpath(@__DIR__, ".."));
                                 papers = ["paper/main.tex", "paper/supplement.tex"],
                                 allow = PAPER_PROJECT_ALLOW)
    foreach(x -> @info("paper-project violation", x), v)
    @test isempty(v)
end
