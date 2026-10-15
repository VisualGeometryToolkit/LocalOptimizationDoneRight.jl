# test_data_policy.jl — the data policy (CLAUDE.md "Data"; VisualGeometryEval
# Experiments `data_policy_violations`, rules D1–D3) over src/ and scripts/.
# The allowlist is EXPLICIT and holds only the violations whose fix moves a
# path, deferred until after the 2026-10 regeneration; each names its fix. An
# entry that stops matching fails as STALE, so the list only shrinks — and any
# NEW violation fails here.
using Test
using DrWatson: projectdir
using VisualGeometryEval.Experiments: data_policy_violations, DataPolicyAllow

const DATA_POLICY_ALLOW = [
    # D2 — the timing tables are RESULTS written under the data root. Fix:
    # EXP_TIMING_DIR = joinpath(EXP_RESULTS_ROOT, "phototourism", "sift", "E",
    # "Timing", "timing-" * <run key of the timing config>) and move the tree.
    DataPolicyAllow("D2", "src/registry.jl", "EXP_TIMING_DIR = joinpath(EXP_DATA_ROOT, \"results\", \"lo_timing\")"),
    # D3 — oracle_floors.jld2: one unkeyed file at the top of the results tree,
    # rewritten by every cell's oracle stage. Fix: a keyed file per cell,
    # joinpath(<cell's keyed dir>, "oracle_floor.jld2") (or a floors file keyed
    # by the run key of its pools + test scenes), read through one function.
    DataPolicyAllow("D3", "src/common.jl", "oracle_floor_done(oracle_floors_path(), tag; kw...)"),
    DataPolicyAllow("D3", "scripts/tools/compute_supp_oracle_floors.jl", "write_oracle_floor!(oracle_floors_path()"),
    DataPolicyAllow("D3", "scripts/tools/render_miscal_faceted.jl", "JLD2.load(oracle_floors_path(), \"floors\")"),
    DataPolicyAllow("D3", "src/paper_numbers.jl", "JLD2.load(oracle_floors_path(), \"floors\")"),
    # D3 — fig1's hand-bumped stamp. Fix: key the bundle directory by the run
    # key of its effective config (Miscalibration/miscal-sel-<run_key>).
    DataPolicyAllow("D3", "src/registry.jl", "EXP_SEL_MISCAL_TAG    = \"miscal-sel-allpairs-v5\""),
    # D3 — wall-clock default stamps of the LO-sensitivity and basin-ladder
    # tools. Fix: the stamp defaults to the run key of the effective arguments
    # (the basin ladder's registry stamp is already derived; only the CLI
    # default remains).
    DataPolicyAllow("D3", "scripts/tools/run_lo_sensitivity.jl", "Dates.format(Dates.now(), \"yyyy-mm-ddTHHMMSS\")"),
    DataPolicyAllow("D3", "scripts/tools/run_basin_ladder.jl", "Dates.format(Dates.now(), \"yyyy-mm-ddTHHMMSS\")"),
]

@testset "data policy (D1–D3)" begin
    v = data_policy_violations(projectdir(); allow = DATA_POLICY_ALLOW)
    foreach(x -> @info("data policy violation", x.rule, x.file, x.line, x.text), v)
    @test isempty(v)
end
