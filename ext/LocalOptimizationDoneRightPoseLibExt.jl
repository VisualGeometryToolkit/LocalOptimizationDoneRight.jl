# =============================================================================
# LocalOptimizationDoneRightPoseLibExt — the PoseLib truncated refiners'
# solver calls: VisualGeometryToolkitCore's external-refit contract
# (`external_workspace`, `prepare_external!`, `refine_external!`) for
# `PoseLibLm`, `PoseLibLZ` and `PoseLibLmAdaptLossWidth` on two-view problems,
# their pixel-form inputs read from the refit's two-view frame (`frame.Kc1`,
# `frame.Kc2`, `frame.cs`).
#
# E `refine_relpose` (camera-aware, from the seed's cheirality-resolved pose),
# F `refine_fundamental`, H `refine_homography` (symmetric transfer error,
# per-side truncation), all in the pool frame. `TLSShape()` = TLS-LM,
# `LeZachTruncation()` = TLS-LZ. The E cheirality (fast cross-product vote,
# strided-subsampled) runs INSIDE the refine — it is part of the refit
# pipeline, matching a native refit, which decomposes internally.
# =============================================================================
module LocalOptimizationDoneRightPoseLibExt

using LocalOptimizationDoneRight: LocalOptimizationDoneRight, PoseLibLm, PoseLibLZ, PoseLibLmAdaptLossWidth
# The package's internals, qualified: its defaults of record and the adaptive arm's operating point.
const _config_default = LocalOptimizationDoneRight._config_default
const _ADAPT_OPERATING_SCALE_MULTIPLE = LocalOptimizationDoneRight._ADAPT_OPERATING_SCALE_MULTIPLE
import LocalOptimizationDoneRight: truncated_refit_pose
using PoseLib: refine_relpose, refine_fundamental, refine_homography, LeZachTruncation
using StaticArrays: SMatrix
using VisualGeometryToolkitCore: VisualGeometryToolkitCore, EssentialMat, FundMat, HomographyMat, Csponds, Point2, Vec3,
    EuclideanMap, TLSShape, LossWidth, OutlierHalfwidth, loss_width, sources, targets, cheiral_pose_fast,
    codimension, data_size, residuals!, with_width, loss_width_to_outlier_halfwidth, FixedS2, scale_s2
import VisualGeometryToolkitCore: external_workspace, prepare_external!, refine_external!
using VisualGeometryToolkitEstimation: EssentialProblem, FundMatProblem, HomographyProblem, RansacWorkspace, consensus_s2!

# The PoseLib loss each truncated arm refines on.
_poselib_loss(::PoseLibLm) = TLSShape()
_poselib_loss(::PoseLibLZ) = LeZachTruncation()

"""
    PoseLibWorkspace

The per-pair workspace of a PoseLib refiner: the frame's calibrations `Kc₁`,
`Kc₂` and its correspondences as a concretely typed `Point2{Float64}`
`Csponds` (the form PoseLib's `refine_*` consume).
"""
struct PoseLibWorkspace
    Kc1::SMatrix{3, 3, Float64, 9}
    Kc2::SMatrix{3, 3, Float64, 9}
    cs::Csponds{Point2{Float64}, Point2{Float64}, Vector{Point2{Float64}}, Vector{Point2{Float64}}, @NamedTuple{}}
end
PoseLibWorkspace(frame) =
    PoseLibWorkspace(SMatrix{3, 3, Float64, 9}(frame.Kc1), SMatrix{3, 3, Float64, 9}(frame.Kc2),
                     Csponds(Point2{Float64}.(sources(frame.cs)), Point2{Float64}.(targets(frame.cs))))

external_workspace(::Union{PoseLibLm, PoseLibLZ}, _problem, frame, _scoring) = PoseLibWorkspace(frame)

# THE cheirality of a seed essential (one copy): its pose by VGC's fast vote
# (`cheiral_pose_fast`, strided-subsampled to about `[local_optimization.poselib]
# cheirality_vote_points` points) on the E problem's unit bearings.
const _CHEIRALITY_VOTE_POINTS = Int(_config_default("local_optimization.poselib", "cheirality_vote_points"))
@inline _cheiral_stride(n::Int; cap::Int = _CHEIRALITY_VOTE_POINTS) = 1:max(1, n ÷ cap):n
function _cheiral_seed_pose(problem::EssentialProblem, seed_E)
    f₁, f₂ = sources(problem.cs), targets(problem.cs)
    idx = _cheiral_stride(length(f₁))
    R0, t0 = cheiral_pose_fast(seed_E, view(f₁, idx), view(f₂, idx))
    return EuclideanMap(R0, Vec3{Float64}(t0))
end

truncated_refit_pose(lo::Union{PoseLibLm, PoseLibLZ}, ws::PoseLibWorkspace, problem::EssentialProblem, seed_E,
                     loss_width::Float64) =
    refine_relpose(_cheiral_seed_pose(problem, seed_E), ws.Kc1, ws.Kc2, ws.cs;
                   loss_width, max_iter = lo.max_iter, loss = _poselib_loss(lo))

function refine_external!(ws::PoseLibWorkspace, lo::Union{PoseLibLm, PoseLibLZ}, problem::EssentialProblem,
                          seed_E, width::LossWidth, _scoring)
    pose = truncated_refit_pose(lo, ws, problem, seed_E, loss_width(width))
    pose === nothing && return nothing
    return EssentialMat(pose.R, pose.t)
end
function refine_external!(ws::PoseLibWorkspace, lo::Union{PoseLibLm, PoseLibLZ}, ::FundMatProblem,
                          seed_F, width::LossWidth, _scoring)
    F = refine_fundamental(SMatrix{3, 3, Float64, 9}(seed_F), ws.cs;
                           loss_width = loss_width(width), max_iter = lo.max_iter, loss = _poselib_loss(lo))
    F === nothing && return nothing
    return FundMat(Tuple(SMatrix{3, 3, Float64, 9}(F)))
end
function refine_external!(ws::PoseLibWorkspace, lo::Union{PoseLibLm, PoseLibLZ}, ::HomographyProblem,
                          seed_H, width::LossWidth, _scoring)
    H = refine_homography(SMatrix{3, 3, Float64, 9}(seed_H), ws.cs;
                          loss_width = loss_width(width), max_iter = lo.max_iter, loss = _poselib_loss(lo))
    H === nothing && return nothing
    return HomographyMat{Float64}(Tuple(SMatrix{3, 3, Float64, 9}(H)))
end

# =============================================================================
# PoseLibLmAdaptLossWidth — the consensus-anchored truncated refit
# =============================================================================

"""
    AdaptWorkspace

The per-pair workspace of [`PoseLibLmAdaptLossWidth`](@ref): the PoseLib
inputs, a RANSAC workspace for the consensus-scale bootstrap (the refit
scoring's), the bootstrap's ŝ² of the current refit, and a residual buffer for
the per-round scale moment.
"""
mutable struct AdaptWorkspace{W}
    pl::PoseLibWorkspace
    rws::W
    s2₀::Float64
    r::Vector{Float64}
end

function external_workspace(::PoseLibLmAdaptLossWidth, problem::EssentialProblem, frame, scoring)
    sc = with_width(scoring, OutlierHalfwidth(1.0))
    return AdaptWorkspace(PoseLibWorkspace(frame), RansacWorkspace(problem, sc), NaN,
                          Vector{Float64}(undef, data_size(problem)))
end
external_workspace(::PoseLibLmAdaptLossWidth, problem, _frame, _scoring) =
    error("PoseLibLmAdaptLossWidth: E-track only (got $(typeof(problem)))")

# Bootstrap ŝ² — OUTSIDE the timing bracket: the seed's consensus scale under
# the refit scoring at the outlier half-width of the delivered loss width,
# never the raw width itself. A consensus too thin to carry a scale makes no
# refit (no call is made or counted).
function prepare_external!(ws::AdaptWorkspace, ::PoseLibLmAdaptLossWidth, problem::EssentialProblem,
                           seed_E, width::LossWidth, scoring)
    a = loss_width_to_outlier_halfwidth(loss_width(width);
                                        operating_scale_multiple = _ADAPT_OPERATING_SCALE_MULTIPLE,
                                        d_g = codimension(problem))
    s2₀ = consensus_s2!(ws.rws, problem, with_width(scoring, OutlierHalfwidth(a)), seed_E)
    s2₀ === nothing && return false
    ws.s2₀ = s2₀
    return true
end

# A fixed plug-in scale (a role-isolated control): the bootstrap ŝ² IS that
# scale, no consensus read.
function prepare_external!(ws::AdaptWorkspace, ::PoseLibLmAdaptLossWidth, ::EssentialProblem, _seed_E,
                           f::FixedS2, _scoring)
    ws.s2₀ = scale_s2(f)
    return true
end

# Within-width truncated second moment: ŝ² = mean of rᵢ² over |rᵢ| ≤ loss_width;
# fewer than `min_support` residuals within the truncation → nothing (a
# consensus too thin for a stable scale).
const _ADAPT_MIN_SUPPORT = Int(_config_default("local_optimization.poselib_adapt", "min_support"))
function _truncated_moment_s2(loss_width::Float64, r::AbstractVector; min_support::Int = _ADAPT_MIN_SUPPORT)
    s2 = 0.0; ν = 0
    @inbounds for i in eachindex(r)
        abs(r[i]) <= loss_width && (s2 += r[i]^2; ν += 1)
    end
    ν < min_support && return nothing
    return s2 / ν
end

# The per-round alternation moment of a refined pose: the within-width
# second moment of its pool-frame residuals (VisualGeometryToolkitEstimation's
# `residuals!` on the E problem — the tangent Sampson on unit bearings).
_adapt_s2(ws::AdaptWorkspace, problem, R, t, loss_width::Float64) =
    _truncated_moment_s2(loss_width, residuals!(Vector{Float64}(undef, data_size(problem)), problem, EssentialMat(R, t)))

function refine_external!(ws::AdaptWorkspace, lo::PoseLibLmAdaptLossWidth, problem::EssentialProblem,
                          seed_E, ::LossWidth, _scoring)
    pl = ws.pl
    w = lo.scale_multiple * sqrt(max(ws.s2₀, eps()))
    inner = max(1, lo.max_iter ÷ lo.rounds)
    pose = _cheiral_seed_pose(problem, seed_E)
    local ref = nothing
    for round in 1:lo.rounds
        ref = refine_relpose(pose, pl.Kc1, pl.Kc2, pl.cs; loss_width = w, max_iter = inner, loss = TLSShape())
        ref === nothing && return nothing
        pose = EuclideanMap(ref.R, Vec3{Float64}(ref.t))
        round == lo.rounds && break
        s2t = _adapt_s2(ws, problem, ref.R, ref.t, w)
        s2t === nothing && break                 # consensus too thin — freeze the width
        w = lo.scale_multiple * sqrt(max(s2t, eps()))
    end
    return EssentialMat(ref.R, ref.t)
end

end # module LocalOptimizationDoneRightPoseLibExt
