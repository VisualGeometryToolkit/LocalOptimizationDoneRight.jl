# =============================================================================
# src/welsch_zero_clamp.jl — RESEARCH-ONLY: the Welsch-HQ lift with the
# 2026-10-04 "zero clamp" z-block, kept so the regenerated results can show it
# beside the faithful arm. Never upstream.
#
# VisualGeometryToolkitCore's Welsch z-block takes Zach & Bourmaud's Taylor limit at
# the lift's upper clamp, hreg → 2γ''(1) = 2c² at w̄ = 1 (VGC dec9cd8, 96021ce).
# From VGC 92597af (0.29.1, 2026-10-04) until dec9cd8 it returned hreg = 0
# there instead — an implicit "exclude and reset" rule: a clamped inlier's
# Schur-eliminated θ-weight becomes μ/(r² + μ) ≈ 0 (RVG HQ's absolute
# μ = 1e-9), so it sits out the pose step and is thrown off the clamp. The ACCV
# camera-ready / arXiv v1 Welsch-HQ numbers (the "IG  +Lift" arm, rerun after
# 2026-10-04 — "MSAC +Lift" was not rerun, so its published numbers are the
# limit era's) were produced with it.
#
# `WelschZeroClampShape` is that rule as its own loss shape: every closed form
# is Welsch's (delegated to `WelschShape`), except `zblock` AT the clamp,
# which is 92597af's expression verbatim. Below the clamp it delegates to the
# stock Welsch z-block, whose arithmetic for w̄ < 1 is unchanged since 92597af
# (96021ce's two-sided series guard |ε| < cut equals ε < cut for ε > 0), so the
# variant reproduces the zero-clamp era bit for bit. The arm runs through the
# stock `HQ{K}` (`HQ{WelschZeroClampShape}`, the one `ManifoldLiftHQ` path), μ
# and all; only the shape differs. Not a Barron variant: no paper arm runs
# Barron, so VGC ac2a071 (Barron's zero clamp) has no counterpart here.
#
# Loaded by arm_rosters.jl; the arms are the opt-in "<key>@zc" variants there.
# =============================================================================

import VisualGeometryToolkitCore as VgtkCore
import VisualGeometryToolkitCore
using VisualGeometryToolkitCore: AbstractMEstimator, WelschShape
using LocalOptimizationDoneRight: HQ

"""
    WelschZeroClampShape <: AbstractMEstimator

Welsch with the zero-clamp HQ z-block of VisualGeometryToolkitCore 92597af
(`hreg = 0` at `w̄ ≥ 1`). Identical to `WelschShape` everywhere else.
Research-only (accv2026); see src/welsch_zero_clamp.jl.
"""
struct WelschZeroClampShape <: AbstractMEstimator end

# Every Welsch closed form but the z-block: delegated, so they cannot drift.
for f in (:liftable, :bounded, :lift_wmax, :cost_scale, :gnc_surrogate)
    @eval VgtkCore.$f(::WelschZeroClampShape) = VgtkCore.$f(WelschShape())
end
for f in (:ρ, :weight, :conjugate, :conjugate_curvature)
    @eval VgtkCore.$f(::WelschZeroClampShape, x, sq_loss_width) =
        VgtkCore.$f(WelschShape(), x, sq_loss_width)
end
VgtkCore.decision_width(::WelschZeroClampShape, decision_threshold::Real) =
    VgtkCore.decision_width(WelschShape(), decision_threshold)
VgtkCore.loss_family(::Type{WelschZeroClampShape}) = VgtkCore.loss_family(WelschShape)
VgtkCore.loss_label(::Type{WelschZeroClampShape}) = VgtkCore.loss_label(WelschShape)

# THE override. At the clamp: 92597af's `zblock(::WelschShape, …)`, verbatim —
#     rinv2 = -sq_loss_width * log(w̄)
#     w̄ >= one(w̄) && return rinv2, zero(rinv2)
# Below it: the stock Welsch z-block (same arithmetic as 92597af for w̄ < 1).
@inline function VgtkCore.zblock(::WelschZeroClampShape, w̄, sq_loss_width)
    rinv2 = -sq_loss_width * log(w̄)                                # r²(w̄) = −c²·ln w̄
    w̄ >= one(w̄) && return rinv2, zero(rinv2)
    return VgtkCore.zblock(WelschShape(), w̄, sq_loss_width)
end

# The strategy's label: its base's, marked (the arm's figure/legend label).
VgtkCore.lo_label(::HQ{WelschZeroClampShape}) = "Welsch-HQ (zero clamp)"

"""
    zero_clamp_strategy(lo::HQ{WelschShape}) -> HQ{WelschZeroClampShape}

The same Welsch-HQ strategy — every field (budget, μ, z₀ policy, width mode) —
on the zero-clamp shape.
"""
zero_clamp_strategy(lo::HQ{WelschShape}) = HQ{WelschZeroClampShape}(lo.max_iter, lo.μ, lo.init, lo.width)
