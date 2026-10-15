#!/usr/bin/env julia
# provenance: inputs declared via require_input blocks in src/cell_stages.jl; see REPRODUCE.md.
# =============================================================================
# scripts/heb_h_pools.jl — HEB HOMOGRAPHY-track 4K-sample scoring-pool
# production. POOL PRODUCER class (scoring_pool_stages). Feeds the HEB rows
# of Fig. 2 (supp_H_miscal) and Fig. 3 (supp_H_budget) and the HEB statistics
# (heb_inlier_stats).
#
# CONFIG-DRIVEN: configs/heb_h_pools.toml is the single source of truth and the
# stages are built once in src/cell_stages.jl (`scoring_pool_stages`). Every
# generation constant (the 4000-sample target included) is the config's
# [pool] table.
#
# The pools store the GT motion in the extrinsic convention; the reader
# (VisualGeometryEval `load_pool`) refuses any other `gt_convention`, and the
# audit asserts it per scene.
#
# STAGES
#   pools (CPU) — the test side of the registered heb split (5 scenes).
#   audit (CPU) — every scene readable at the current pool format, stamped
#                 extrinsic.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2
using VisualGeometryEval.Pools: GT_CONVENTION
include(srcdir("cell_stages.jl"))

"The convention this cell depends on, read off the artifact itself."
function _assert_extrinsic(scene, path)
    conv = jldopen(path, "r") do j
        haskey(j, "gt_convention") ? j["gt_convention"] : nothing
    end
    conv == GT_CONVENTION ||
        error("AUDIT $(scene): gt_convention = $(repr(conv)), expected " *
              "$(repr(GT_CONVENTION))")
end

run_stages("heb_h_pools", scoring_pool_stages("heb_h_pools";
    what = "ETH HEB <scene>_homographies.h5 raw pairs",
    provenance = "ETH HEB release (REPRODUCE.md, Data prerequisites)",
    audit_extra = _assert_extrinsic))
