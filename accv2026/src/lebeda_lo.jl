# =============================================================================
# src/lebeda_lo.jl — classical RansacLib LO arms (Lebeda LO family), the
# paper's reference baseline. They live in the research project, not in
# LocalOptimizationDoneRight, because their C++ backend (lib/RansacLibLO, the
# vendored RansacLib shim) is an unregistered, locally built package; they plug
# into the composition evaluator through VisualGeometryToolkitCore's external-refit
# contract (`external_workspace`, `refine_external!`), like any third-party LO
# strategy.
#
# Thin PoseLibLm-style strategy types over RansacLibLO.jl (Sattler's RansacLib
# run verbatim; Lebeda/Matas/Chum LO-MSAC), external refiners (ExternalRefit):
#
#   LebedaIterLO(opts, rng_seed) — the iterative-least-squares ladder alone
#                          (`lebeda_iterlo`; Chum et al. 2003 / Lebeda's LO').
#   LebedaLOPlus(opts, rng_seed) — full LO (`lebeda_lo`: LSq at the enlarged loss width,
#                          inner non-minimal resampling, per-sample ILSQ).
#
# Options are RansacLibLO's public LORansacOptions subset (`LebedaLOOptions`),
# always supplied by the caller: the paper builds its budget-parity options from
# its protocol of record (accv2026 configs/protocol.toml: the Lebeda schedule
# and the LO iteration budget), and PRESET_REFERENCE is RansacLib's own
# defaults (61 updates; the supplement's reference rows).
#
# LOSS-WIDTH CURRENCY (checked against both wrappers' APIs, not assumed):
#   * The refit's loss width is the absolute truncation width (UNSQUARED,
#     pool-frame Sampson) — the same fixed-absolute currency PoseLibLm consumes
#     (scale_interface = FixedScale(); axis LossWidth()): the `LossWidth` the
#     refit hands `refine_external!`, exactly as the PoseLib arms read it.
#   * RansacLibLO's API takes the SQUARED loss width "in the frame of the
#     input points" (`lebeda_lo(pts, seed, sq_loss_width)`), so the wrapper
#     receives the square of the (frame-converted) loss width.
#   * E-track: RansacLibLO's :E solver projects onto the ESSENTIAL manifold
#     (equal singular values), which is only valid in the CALIBRATED (bearing
#     xy) frame — its own test scenes are normalized coordinates. We therefore
#     feed calibrated points x_cal = Kc⁻¹·x_can and convert the pool-frame
#     loss width with EXACTLY PoseLib's camera-aware convention (PoseLib
#     robust.cc: loss_scale · ½(1/f₁ + 1/f₂), focal = (fxᵢ+fyᵢ)/2) — so
#     TLS-LM/LZ and TLS-LO consume the SAME absolute pool-frame loss width.
#   * F-track: the pool frame is already the model frame (a pool-frame F fits
#     pool-frame points verbatim, exactly like refine_fundamental), so pts and
#     the loss width go through unconverted.
#   * H-track (the HEB-H cell): as on the F track — pool-frame points, the
#     pool-frame H seed, the loss width unconverted. The shim scores the codimension-2 Sampson
#     of the transfer constraint (the whitened transfer error of the pools' H
#     scoring); PoseLib's truncated H path (TLS-LM/LZ) truncates the symmetric
#     transfer error instead — the same absolute pool-frame loss width, a different
#     residual. The imc is read through the H decomposition metric (`model_imc`).
#
# ACCOUNTING: the refit is bracketed by the evaluator's `guarded_refit` — lo_ns
# spans the optimizer call exactly like every other external arm (the ladder's
# documented lo_ns/lo_calls semantics; calls = count(lo_ns > 0)). The
# wrapper's own (updates, ns) measurement is surfaced per call in the arm's
# workspace, `lebeda_last(ws)` (updates = measured linear solves — the
# budget-parity audit; ns = steady-clock inside the LO, marshalling excluded).
#
# DETERMINISM: the strategy carries its rng_seed (the caller's protocol
# declares it) — RansacLibLO's mt19937 is its only randomness source, so
# identical inputs give bitwise-identical outputs.
# =============================================================================

import VisualGeometryToolkitCore as VgtkCore
using RansacLibLO: RansacLibLO, LebedaLOOptions, PRESET_REFERENCE, lebeda_lo, lebeda_iterlo
# The C++ shim is built locally (`Pkg.build("RansacLibLO")`, gitignored). Unbuilt,
# every Lebeda refit throws inside the evaluator's guarded refit and silently
# falls back to its seed (a no-op arm, tuned onto its window's boundary) — so
# refuse at load instead.
isfile(RansacLibLO._SHIM) ||
    error("RansacLibLO's shim $(RansacLibLO._SHIM) is not built — run `Pkg.build(\"RansacLibLO\")` in accv2026")
import VisualGeometryToolkitCore
using VisualGeometryToolkitCore: AbstractLocalOptimization, ExternalRefit, FixedScale, EssentialMat, FundMat,
    HomographyMat, PerspectiveMap, sources, targets, LossWidth, loss_width
import VisualGeometryToolkitCore: external_workspace, refine_external!
using StaticArrays: SMatrix
using VisualGeometryToolkitEstimation: EssentialProblem, FundMatProblem, HomographyProblem

"""
    LebedaIterLO(opts::LebedaLOOptions, rng_seed::Integer)

Classical iterative-least-squares LO as an ExternalRefit strategy.
It runs RansacLib's ILSQ ladder alone (`lebeda_iterlo`; Lebeda's LO′
mechanism) in the absolute loss-width currency (the truncation width the refit
hands it). See the file
header for the loss width's frame conversion. `rng_seed` seeds RansacLib's
mt19937 on every call (its inlier-cap subsampling). Both are required: the
options and the seed are protocol values of the caller.
"""
struct LebedaIterLO <: AbstractLocalOptimization
    opts::LebedaLOOptions
    rng_seed::Int
end

"""
    LebedaLOPlus(opts::LebedaLOOptions, rng_seed::Integer)

Full classical LO (RansacLib `LocalOptimization` run verbatim — `lebeda_lo`:
enlarged-loss-width LSq, inner non-minimal resampling, per-sample ILSQ) as an
ExternalRefit strategy. Same currency/accounting/seeding as [`LebedaIterLO`](@ref).
"""
struct LebedaLOPlus <: AbstractLocalOptimization
    opts::LebedaLOOptions
    rng_seed::Int
end

const _LebedaLO = Union{LebedaIterLO, LebedaLOPlus}

VgtkCore.RefitFamily(::_LebedaLO) = ExternalRefit()

# Identity/scale traits (VGC estimation.jl): fixed-ABSOLUTE scale semantics
# like PoseLibLm (the deployed loss width is an external truncation supplied
# at refit time, never a partition read); marker = pentagon* (free shape in the registry: o = static
# IRLS, triangle = HQ, diamond = GNC, square = truncated LM/LZ).
VgtkCore.optimization_path(::_LebedaLO) = :classical_lo   # classical LO-RANSAC inner refinement
VgtkCore.scale_interface(::_LebedaLO) = FixedScale()        # absolute loss width supplied at refit time
VgtkCore.lo_label(::LebedaIterLO) = raw"TLS-LO"
# Instance-aware: the RansacLib-default reference preset is a DISTINCT arm
# (61 updates vs the budget-parity options') and needs a distinct legend label. isbits
# options ⇒ === is field-wise.
VgtkCore.lo_label(lo::LebedaLOPlus) =
    lo.opts === PRESET_REFERENCE ? raw"TLS-LO$^+$ (ref)" : raw"TLS-LO$^+$"
VgtkCore.loss_family(::_LebedaLO) = :tls

_lebeda_call(lo::LebedaIterLO, pts, seed, sq_loss_width; model::Symbol) =
    lebeda_iterlo(pts, seed, sq_loss_width; model, options = lo.opts, rng_seed = lo.rng_seed)
_lebeda_call(lo::LebedaLOPlus, pts, seed, sq_loss_width; model::Symbol) =
    lebeda_lo(pts, seed, sq_loss_width; model, options = lo.opts, rng_seed = lo.rng_seed)

# The problem family's track, by dispatch on the problem's type: the model
# kind RansacLibLO fits, the model container its refit matrix is read back into,
# the 4×N point matrix it fits (built once per pair, in the arm's workspace) and
# the loss width's conversion into that frame (see the header for each track's
# currency).
_lebeda_kind(::EssentialProblem) = :E
_lebeda_kind(::FundMatProblem) = :F
_lebeda_kind(::HomographyProblem) = :H

_lebeda_model(::EssentialProblem, M) = EssentialMat(Tuple(M))
_lebeda_model(::FundMatProblem, M) = FundMat(Tuple(M))
_lebeda_model(::HomographyProblem, M) = HomographyMat(Tuple(M))

"""
    LebedaWorkspace

The per-pair workspace of a Lebeda arm: the 4×N point matrix of its track, the
loss width's frame factor (E: PoseLib's camera-aware rule; F/H: 1), and the
wrapper's own `(updates, ns)` of the last call ([`lebeda_last`](@ref)).
"""
mutable struct LebedaWorkspace
    pts::Matrix{Float64}
    width_scale::Float64
    last::Union{Nothing, NamedTuple{(:updates, :ns), Tuple{Int, Int}}}
end
"The `(updates, ns)` the RansacLib wrapper measured in the last refit on `ws` (`nothing` before one)."
lebeda_last(ws::LebedaWorkspace) = ws.last

# E: the calibrated z = 1 plane RansacLibLO's essential-manifold solver requires,
# the perspective division of the E problem's own unit bearings (Kc⁻¹·x_can up
# to scale), and the loss width by PoseLib's camera-aware rule. F/H: the pool
# frame verbatim (pool-frame models score pool-frame points), the loss width
# unconverted.
function external_workspace(::_LebedaLO, problem::EssentialProblem, frame, _scoring)
    f₁, f₂ = sources(problem.cs), targets(problem.cs)
    return LebedaWorkspace(_point_matrix(map(PerspectiveMap(), f₁), map(PerspectiveMap(), f₂)),
                           _poselib_loss_width_scale(frame.Kc1, frame.Kc2), nothing)
end
external_workspace(::_LebedaLO, ::Union{FundMatProblem, HomographyProblem}, frame, _scoring) =
    LebedaWorkspace(_point_matrix(sources(frame.cs), targets(frame.cs)), 1.0, nothing)

# The 4×N layout RansacLibLO takes: column i = (x₁ᵢ; x₂ᵢ).
_point_matrix(x₁, x₂) = Matrix{Float64}(stack(vcat(a, b) for (a, b) in zip(x₁, x₂)))

"""
    _poselib_loss_width_scale(Kc1, Kc2) -> Float64

The factor that converts a pool-frame loss width to a calibrated one.
It is EXACTLY PoseLib's camera-aware convention (`robust.cc`: `loss_scale · 0.5·(1/f₁ + 1/f₂)`, focal fᵢ = (fxᵢ+fyᵢ)/2 of the
pool-frame intrinsics) — so the Lebeda arms and TLS-LM/LZ consume the same
absolute pool-frame loss width on the E track.
"""
_poselib_loss_width_scale(Kc1, Kc2) =
    0.5 * (
    1.0 / ((Kc1[1, 1] + Kc1[2, 2]) / 2) +
        1.0 / ((Kc2[1, 1] + Kc2[2, 2]) / 2)
)

# The refit: ONE wrapper call on the track's frame at the squared converted
# loss width, the (updates, ns) side channel recorded in the workspace.
function refine_external!(ws::LebedaWorkspace, lo::_LebedaLO, problem, seed, width::LossWidth, _scoring)
    refit_sq_loss_width = (loss_width(width) * ws.width_scale)^2
    M0 = Matrix{Float64}(SMatrix{3, 3, Float64, 9}(seed))
    r = _lebeda_call(lo, ws.pts, M0, refit_sq_loss_width; model = _lebeda_kind(problem))
    ws.last = (updates = r.updates, ns = r.ns)
    r.E === nothing && return nothing
    return _lebeda_model(problem, SMatrix{3, 3, Float64, 9}(r.E))
end
