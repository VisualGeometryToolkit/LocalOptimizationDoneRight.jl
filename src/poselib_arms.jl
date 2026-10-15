# =============================================================================
# poselib_arms.jl — PoseLib's truncated refiners as LO strategies (the solver
# calls live in the PoseLib extension, ext/LocalOptimizationDoneRightPoseLibExt.jl).
#
# External refiners (VisualGeometryCore's `ExternalRefit`): they refine at an
# absolute loss width through `refine_external!` on their per-pair
# `external_workspace` (the pool-frame calibrations and correspondences), never
# in the native RANSAC loop — truncating at a marginal's outlier half-width
# would degenerate TLS to least squares. Loading PoseLib makes the solver
# methods available.
# =============================================================================

"""
    PoseLibLm(max_iter) <: AbstractLocalOptimization

PoseLib Levenberg–Marquardt over the TRUNCATED Sampson loss (`TLSShape`) — the
LO-RANSAC standard truncated refiner (TLS-IRLS). An external refiner
(`ExternalRefit`): it refines at an absolute loss width (`refine_external!`),
not in the native RANSAC loop. `max_iter` is its LM budget.
"""
struct PoseLibLm <: AbstractLocalOptimization
    max_iter::Int
end

"""
    PoseLibLZ(max_iter) <: AbstractLocalOptimization

PoseLib's Le–Zach relaxed IRLS (TR-IRLS) on the same truncated loss as
[`PoseLibLm`](@ref) — the optimizer axis within the truncated class (TLS-LZ).
"""
struct PoseLibLZ <: AbstractLocalOptimization
    max_iter::Int
end

"""
    PoseLibLmAdaptLossWidth(; max_iter, rounds, scale_multiple)

Consensus-anchored truncated refit (TLS-IRLS-ŝ): PoseLib LM over the truncated
loss, its loss width re-formed between `rounds` LM rounds as
`scale_multiple·ŝ` of the current model's within-width residual scale (outer
pose-block / scale-moment alternation; PoseLib is a black box).

The INITIAL width is anchored on the seed's consensus scale — `ŝ²` of the
consensus set under the refit scoring at the outlier half-width of the
delivered loss width (`loss_width_to_outlier_halfwidth` at the refit
protocol's operating scale multiple, `[local_optimization.poselib_adapt]
operating_scale_multiple`), RobustVisualGeometry's `consensus_s2!` — never a
plug-in scale; a consensus too thin to carry a scale makes no refit.
`max_iter` is the total LM budget across rounds. Defaults:
configs/default.toml `[local_optimization.poselib_adapt]`. E-track only
(PoseLib `refine_relpose`).
"""
struct PoseLibLmAdaptLossWidth <: AbstractLocalOptimization
    max_iter::Int    # TOTAL LM budget across rounds (parity with PoseLibLm)
    rounds::Int      # scale re-estimation rounds
    scale_multiple::Float64   # the truncated loss's width as a multiple of the re-estimated scale ŝ
end
# The refit protocol's operating scale multiple: the default `scale_multiple`
# and the bootstrap's loss width → outlier half-width conversion.
const _ADAPT_OPERATING_SCALE_MULTIPLE = Float64(_config_default("local_optimization.poselib_adapt", "operating_scale_multiple"))
PoseLibLmAdaptLossWidth(; max_iter::Integer = _config_default("local_optimization.poselib_adapt", "max_iter"),
                        rounds::Integer = _config_default("local_optimization.poselib_adapt", "rounds"),
                        scale_multiple::Real = _ADAPT_OPERATING_SCALE_MULTIPLE) =
    PoseLibLmAdaptLossWidth(Int(max_iter), Int(rounds), Float64(scale_multiple))

const _PoseLibArm = Union{PoseLibLm, PoseLibLZ, PoseLibLmAdaptLossWidth}
VisualGeometryCore.RefitFamily(::_PoseLibArm) = ExternalRefit()

# Identity (VisualGeometryCore traits). PoseLib's truncated-loss LM is a binary
# weight recomputed every iteration — static reweighting, the IRLS column;
# Le–Zach's relaxed TLS multiplies its penalty per LM iteration until it
# collapses to hard truncation — explicit continuation, the GNC column. Both
# are FixedScale: the absolute loss width is supplied at refit time. The
# adaptive arm anchors its start width on the consensus scale.
VisualGeometryCore.optimization_path(::PoseLibLm) = :irls
VisualGeometryCore.optimization_path(::PoseLibLZ) = :gnc
VisualGeometryCore.optimization_path(::PoseLibLmAdaptLossWidth) = :irls
VisualGeometryCore.scale_interface(::Union{PoseLibLm, PoseLibLZ}) = FixedScale()
VisualGeometryCore.scale_interface(::PoseLibLmAdaptLossWidth) = ConsensusAnchored()
VisualGeometryCore.loss_family(::_PoseLibArm) = :tls
VisualGeometryCore.lo_label(::PoseLibLm) = raw"TLS-IRLS"
VisualGeometryCore.lo_label(::PoseLibLZ) = raw"TLS-LZ"
# The truncated LS refined with a RE-ESTIMATED scale (ŝ); the filled square
# marks a refiner that re-estimates its scale.
VisualGeometryCore.lo_label(::PoseLibLmAdaptLossWidth) = raw"TLS-IRLS-$\hat s$"
VisualGeometryCore.lo_marker(::PoseLibLmAdaptLossWidth) = Symbol("square*")

"""
    truncated_refit_pose(lo, ws, problem, seed_E, loss_width) -> Union{Nothing, refined pose}

The E-branch optimizer body of a PoseLib truncated refiner WITHOUT a guard or
scoring bracket: the seed's cheirality-resolved pose (fast strided vote on the
problem's bearings) refined by PoseLib `refine_relpose` at the absolute
pool-frame `loss_width`, on the refiner's `external_workspace`. For callers
that need the REFINED pose itself (a warm-started polish). Implemented by the
PoseLib extension.
"""
function truncated_refit_pose end
