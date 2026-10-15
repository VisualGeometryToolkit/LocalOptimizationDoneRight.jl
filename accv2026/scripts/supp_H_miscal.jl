#!/usr/bin/env julia
# provenance: inputs declared via require_input blocks below; see REPRODUCE.md.
# =============================================================================
# scripts/supp_H_miscal.jl — SUPPLEMENT model-class transfer, HEB-H cell:
# composed score+LO miscalibration (ζ sweep) with the HOMOGRAPHY on the ETH
# HEB scenes (HEB-H-SIFT-4K_pf3 pools; codimension-2 Sampson residuals) — the
# planar/projective end of the model-class transfer claim.
#
# ROSTER: composed_specs(:H) — the loss MECHANISM MATRIX (3 losses ×
# {static IRLS, HQ lift, GNC}), the self-scaling Stu-t rows (IG +LO, BCD) and
# the fixed-external-scale TLS baselines (PoseLib refine_homography, the
# RansacLib Lebeda pair); the relpose-only rows (TLSadapt, MSAC-seeded) have no
# H path. EVALUATION METRIC: ROTATION error Δr° of the Malis–Vargas homography
# decomposition against the COLMAP pose (optimistic over candidates; the
# pools' errors_r convention, src/loaders/heb.jl `_pose_errors_min`), and the
# LO side scores refined pool-frame H's through the identical conversion
# (the LO engine's `model_imc`) — one metric, selection and refit. Rotation
# ONLY, matching the scoring campaign's HEB eR protocol: the small-baseline
# pairs make the decomposition's translation direction ill-conditioned (the
# plane-assignment caveat), so a combined max(Δr, Δt°) metric saturates on
# noise no estimator can remove.
#
# STAGES
#   h_cv  (GPU) — the FULL composed :H roster through run_sequential_cv.jl on
#         the 10 HEB scenes (the registered `heb` split, every pair): the IG
#         scorer's a* on the 5 val scenes (scorer_cv.jld2), every refiner's
#         width at that a* (refiner_cv.jld2), the ζ evaluation on the 5 test
#         scenes (operating_points.jld2 — also the heb_h_budget cell's
#         operating points). Interior-argmin invariant enforced end to end:
#         each coarse probe expands on an edge argmin, and the deployed readers
#         refuse a surviving clip. Until 2026-10-04 this was the
#         [tuning.default] product grid (notes/sequential_cv.md says why not).
#   oracle (CPU) — pool-best selection bound (floor + mAA ceiling).
#   render_main (CPU) — the HEB row of the Fig 3 grid →
#         figures/panel_lo_miscal_heb_H_main.tex (mAA@10°, the Table 1 roster;
#         the H roster is loss-mechanism-only, so all three loss-family facets
#         populate).
#
# NO pools stage: the HEB-H-SIFT-4K_pf3 pools are scripts/heb_h_pools.jl's —
# declared as a require_input instead.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, TOML
include(srcdir("cell_stages.jl"))   # config + common + registry; the shared tuning stages

# CONFIG-DRIVEN, ONE PATH (2026-10-04): every value is configs/heb_h_miscal.toml's
# ([sequential_cv], [render], [render.main]), run by THE miscal cell builder
# (src/cell_stages.jl `miscal_cell_stages`) — the same stages and main-paper
# row every miscal cell gets. This file used to be a
# hand-rolled copy of that builder.
run_stages("supp_H_miscal", miscal_cell_stages("heb_h_miscal";
    pool_what = "HEB-H-SIFT-4K_pf3 scoring pool",
    pool_provenance = "scripts/heb_h_pools.jl (configs/heb_h_pools.toml, both sides of the heb split)",
    cv_stage = :h_cv))
