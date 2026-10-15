#!/usr/bin/env julia
# provenance: inputs declared via require_input blocks in src/cell_stages.jl; see REPRODUCE.md.
# =============================================================================
# scripts/pt_e_pools.jl — PhotoTourism ESSENTIAL-track 4K-sample scoring-pool
# production. POOL PRODUCER class (scoring_pool_stages). THE pool every
# main-paper cell reads: fig3's deployed tuning, fig2's basin ladder, fig4's
# budget, fig1's selection bundle, polish, the end-to-end table and the timing
# runs all key on it.
#
# CONFIG-DRIVEN: configs/pt_e_pools.toml is the single source of truth and the
# stages are built once in src/cell_stages.jl (`scoring_pool_stages`), so this
# file is its config name plus `run_stages`. The generation constants are the
# config's [pool] table; nothing states them here.
#
# STAGES
#   pools (CPU) — every scene of BOTH sides of the registered phototourism
#                 split, ONE scene at a time (72-84 GB each, ~2 TB total).
#   audit (CPU) — every scene readable at the current pool format.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))

run_stages("pt_e_pools", scoring_pool_stages("pt_e_pools";
    what = "PhotoTourism raw RootSIFT matches + COLMAP reconstructions",
    provenance = "public IMC PhotoTourism release + the RANSAC Tutorial data; " *
                 "the five raw trees and the two per-scene recon exceptions are " *
                 "declared in configs/pt_e_pools.toml [source]"))
