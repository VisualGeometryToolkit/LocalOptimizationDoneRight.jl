#!/usr/bin/env julia
# provenance: inputs declared via require_input below; see REPRODUCE.md.
# =============================================================================
# scripts/heb_inlier_stats.jl — the per-pair counts behind the HEB dataset
# statistics the main paper quotes (\HEBCsMed, \HEBInlMed, \HEBInlRatio,
# \HEBFracLow), computed from the HEB pools the paper's HEB cells read
# (configs/heb_stats.toml).
#
# Per pair of the TEST side of the source cell's cross-validation: the number
# of correspondences of the pool record and the number of them the benchmark
# labels inliers (the record's `gt_inliers` mask, HEB's own flags). The
# statistics over these counts are macros of scripts/paper_numbers.jl
# (configs/paper_numbers.toml [sources.heb_stats]; src/paper_numbers.jl
# HEB_STATISTICS), the one generated macro file.
#
# STAGES
#   counts  (CPU) — per-pair (correspondences, GT inliers) of every test pair
#                   → <results>/heb/sift/H/DatasetStats/heb-stats-<key>/counts.jld2
#
#   julia --project=. scripts/heb_inlier_stats.jl [--plan] [--stage=NAME] [--force]
# =============================================================================
import VisualGeometryToolkitCore as VgtkCore
using DrWatson; @quickactivate "ACCV2026"
using JLD2, TOML, Printf, Dates
include(srcdir("cell_stages.jl"))
include(srcdir("e2e_cells.jl"))
include(srcdir("paper_numbers.jl"))   # heb_counts_cell

const CFG_NAME = "heb_stats"
const CFG_PATH = projectdir("configs", CFG_NAME * ".toml")
const CFG = load_run_config(CFG_PATH)
VgtkCore.check_keys(CFG, ("experiment", "source"), CFG_PATH)
# The source cell's cross-validation and the counts' key (src/paper_numbers.jl
# heb_counts_cell: keyed by the pools and the test side, its scenes and sampling).
const CELL = heb_counts_cell(CFG)
const SRC_NAME = CELL.source
const CV = CELL.cv
const COUNTS_CFG = CELL.keyed
const KEY = CELL.key
const POOL = joinpath(data_root(), CFG["experiment"]["pool_dir"])
const OUTDIR = CELL.outdir
const COUNTS = CELL.counts

function _counts()
    scenes = test_scenes(CV)
    for s in scenes
        require_input(joinpath(POOL, "$s.jld2"); what = "HEB-H pool ($s)",
                      provenance = "scripts/heb_h_pools.jl (configs/heb_h_pools.toml)")
    end
    n_cs, n_inl, scene_of, pool_index = Int[], Int[], String[], Int[]
    for s in scenes
        pool = load_pool(joinpath(POOL, "$s.jld2"))
        idx = only(values(sample_units(CV.test, Dict(s => collect(eachindex(pool.pairs))))))
        for i in idx
            p = pool.pairs[i]
            length(p.gt_inliers) == length(p.csponds) ||
                error("$s pair $i: gt_inliers mask of length $(length(p.gt_inliers)) for $(length(p.csponds)) correspondences")
            push!(n_cs, length(p.csponds)); push!(n_inl, count(p.gt_inliers))
            push!(scene_of, s); push!(pool_index, i)
        end
        @info "scene counted" s pairs = length(idx)
        pool = nothing; GC.gc()
    end
    mkpath(OUTDIR)
    jldsave(COUNTS; n_cs, n_inl, scene = scene_of, pool_index, scenes,
            pool_dir = POOL, created = string(Dates.now()))
    write_run_records(OUTDIR, COUNTS_CFG; driver = "heb_inlier_stats.jl", config_source = CFG_PATH, key = KEY,
                      inputs = [POOL])
end

STAGES = Stage[
    Stage(:counts, "per-pair correspondences and GT inliers of $(SRC_NAME)'s test pairs (config $(CFG_NAME), key $(KEY)) -> $(COUNTS)",
          () -> isfile(COUNTS) && isfile(joinpath(OUTDIR, "_provenance.toml")), _counts),
]
run_stages("heb_inlier_stats", STAGES)
