#!/usr/bin/env julia
# provenance: inputs declared via require_input blocks below; see REPRODUCE.md.
# =============================================================================
# scripts/supp_ETH_F_miscal.jl — ETH3D-F cell (uncalibrated track on the outdoor dataset): composed score+LO miscalibration with the FUNDAMENTAL matrix.
#
# CONFIG-DRIVEN (2026-08-31): configs/accv2026_eth_f_miscal.toml is the single
# source of truth; the output directory is KEYED by the effective config
# (code is provenance-restorable, not keyed; a changed config is a NEW run, never an
# overwrite), and every run carries _config.toml + _provenance.toml sidecars
# (run_records.jl).
#
# STAGES
#   cv     (GPU) — the sequential CV (scorer, then each refiner) on the val
#          scenes at zeta=1, zeta evaluation on the test scenes, interior-argmin
#          invariant end to end;
#          writes the run-record sidecars beside the operating-points sidecar.
#   oracle (CPU) — pool-best selection bound (floor + mAA ceiling).
#   render_main (CPU) — the ETH3D row of the Fig 3 grid →
#          figures/panel_lo_miscal_eth_F_main.tex (mAA@10°, the Table 1 roster).
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("cell_stages.jl"))

run_stages("supp_ETH_F_miscal", miscal_cell_stages("accv2026_eth_f_miscal";
    pool_what = "eth3d splg F scoring pool (vgc07)",
    pool_provenance = "scripts/scoring_pools.jl (eth3d/splg; REPRODUCE.md)"))
