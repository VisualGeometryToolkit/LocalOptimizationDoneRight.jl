# =============================================================================
# Manifold-parametric lift core — the θ-block of the joint-(θ,z) half-quadratic
# loss lift and of the GNC surrogate step, for every chart and every residual
# codimension (moved from VisualGeometryCore's robust/lift_core.jl). The rows a
# step reads are a chart-rows provider's (VisualGeometryCore's contract:
# `lift_rows(prov)::RowsWorkspace{D, C}`, filled by `lift_refresh!` /
# `lift_jacobian!`); the lift's own state — the line process z and the
# reduced system — is this package's `LiftState{D}`.
#
# SCOPE: the core owns ONLY the model-agnostic mathematics of a lift step at a
# fixed manifold anchor. Per point i the residual is a codim-C block
# rᵢ ∈ ℝ^C (C whitened rows sharing ONE line-process weight zᵢ) with tangent
# Jacobian Jᵢ ∈ ℝ^{C×D}. The joint system's z-block kind (`LiftZBlock`) supplies
# per point the pivot dᵢ, the z-gradient gzᵢ, the θθ weight Aᵢ, the θ–z coupling
# κᵢ (bᵢ = κᵢ·Jᵢᵀrᵢ) and the θ-gradient weight γᵢ; the core accumulates the
# Schur-reduced θ-Hessian Aᵢ·JᵢᵀJᵢ − dᵢ·bᵢbᵢᵀ and gradient (γᵢ − dᵢgzᵢ)·bᵢ,
# solves the damped D×D system, and back-substitutes Δzᵢ = −dᵢ(gzᵢ + bᵢᵀΔθ).
# The codim-1 lift is the C = 1 instance of the same accumulation — there is no
# second family. The PROBLEM supplies everything manifold-specific: the row fill
# at the current model (whitened, in the scoring residual currency), the
# re-anchor and the model reconstruction.
#
# VALIDITY MASK: `valid` is either `nothing` (every point participates; the
# branch is compiled away) or a `Vector{Bool}` per-iteration participation mask
# (the PnP cheirality guard). An invalid point contributes NO rows to the θ
# system and is DECOUPLED from the z system for that iteration: its dᵢ/gzᵢ slots
# are zeroed so the back-substitution leaves its zᵢ untouched.
# =============================================================================

# =============================================================================
# LiftState — the lift's own buffers (the rows are the provider's)
# =============================================================================

"""
    LiftState{D}
    LiftState{D}(n)

The lift's own buffers on a `D`-dof chart for `n` points: the line process `z`
and its back-substitution terms (`dvec`, `gzv`), and the reduced normal
equations (`Hbuf`, `gbuf`). The stacked rows, their Jacobian, the per-point
norms and the participation mask are the chart-rows provider's
(VisualGeometryCore `RowsWorkspace{D, C}`). [`lift_state`](@ref) builds one per
(task, size).
"""
struct LiftState{D}
    z::Vector{Float64}
    dvec::Vector{Float64}; gzv::Vector{Float64}
    Hbuf::Matrix{Float64}; gbuf::Vector{Float64}   # D × D, D
end
LiftState{D}(n::Int) where {D} = LiftState{D}(
    Vector{Float64}(undef, n), Vector{Float64}(undef, n), Vector{Float64}(undef, n),
    Matrix{Float64}(undef, D, D), Vector{Float64}(undef, D)
)

"""
    lift_state(::Val{D}, n) -> LiftState{D}

The lift's state for `n` points under the one reuse policy
(VisualGeometryCore's `task_buffers`).
"""
lift_state(::Val{D}, n::Int) where {D} =
    task_buffers(LiftState{D}, () -> LiftState{D}(n), (:lodr_lift_state, n))

"""
    reused_state(S, vals::Tuple) -> S

The per-call state of a strategy (an iteration's incumbent, a schedule's rung
bookkeeping) under the one reuse policy: ONE mutable `S` per (task, type),
every field written from `vals` on each call, so the call's state is exactly
a fresh `S(vals...)` without the allocation. A strategy never runs nested in
itself on a task, so one state per type serves every call.
"""
function reused_state(::Type{S}, vals::Tuple) where {S}
    d = task_buffers(Dict{Symbol, S}, Dict{Symbol, S}, :lodr_reused_state)
    st = get(d, :state, nothing)
    st === nothing && return (d[:state] = S(vals...))
    return _assign_fields!(st, vals)
end
@generated function _assign_fields!(st::S, vals::Tuple) where {S}
    sets = (:(setfield!(st, $i, convert($(fieldtype(S, i)), vals[$i]))) for i in 1:fieldcount(S))
    return Expr(:block, sets..., :(return st))
end

# Point i's blocks of the stacked rows, in registers: `JᵢᵀJᵢ` (D×D), `Jᵢᵀrᵢ`
# and `‖rᵢ‖²` over its C rows (row C(i−1)+c of `J` and `r`). The accumulations
# below sum these per-point blocks into LOCAL static matrices and write the
# workspace's `Hbuf`/`gbuf` once at the end: element-wise `Hbuf[a, b] +=` per
# point kept the D² sums in memory (2026-10-07, D = 5: the Welsch HQ
# accumulation 37 → 25 ns per point, 14 for GM with the codimension-1 form).
@inline function _point_blocks(J::AbstractMatrix, r::AbstractVector, i::Int, ::Val{D}, ::Val{C}) where {D, C}
    k = C * (i - 1)
    Jr = @inbounds SVector{D, Float64}(ntuple(a -> J[k + 1, a], Val(D)))
    rr = @inbounds r[k + 1]
    JtJ = Jr * Jr'; Jtr = Jr * rr; r2 = rr * rr
    for c in 2:C
        Jc = @inbounds SVector{D, Float64}(ntuple(a -> J[k + c, a], Val(D)))
        rc = @inbounds r[k + c]
        JtJ += Jc * Jc'; Jtr += Jc * rc; r2 += rc * rc
    end
    return JtJ, Jtr, r2
end
# A codimension-1 point's one Jacobian row and residual.
@inline _point_row(J::AbstractMatrix, r::AbstractVector, i::Int, ::Val{D}) where {D} =
    (@inbounds(SVector{D, Float64}(ntuple(a -> J[i, a], Val(D)))), @inbounds(r[i]))
# `Jᵢᵀrᵢ` alone (the z back-substitution's coupling).
@inline function _point_jtr(J::AbstractMatrix, r::AbstractVector, i::Int, ::Val{D}, ::Val{C}) where {D, C}
    k = C * (i - 1)
    Jtr = @inbounds SVector{D, Float64}(ntuple(a -> J[k + 1, a], Val(D))) * @inbounds(r[k + 1])
    for c in 2:C
        Jtr += @inbounds SVector{D, Float64}(ntuple(a -> J[k + c, a], Val(D))) * @inbounds(r[k + c])
    end
    return Jtr
end

# The damped D×D solve every θ-block below ends in: Δθ = −(H + 1e-9·I)⁻¹g from
# the accumulated Hessian/gradient buffers, or `nothing` when the solve throws
# or yields a non-finite entry (the callers' `:solve_failed` exit).
@inline function _damped_solve(::Val{D}, Hbuf, gbuf) where {D}
    Δθ = try
        -((SMatrix{D, D, Float64}(Hbuf) + 1.0e-9 * I) \ SVector{D, Float64}(gbuf))
    catch
        return nothing
    end
    any(!isfinite, Δθ) && return nothing
    return Δθ
end

# =============================================================================
# The z-block kinds and the line-process window
# =============================================================================

"""
    LiftZBlock

The z-block of a joint-(θ,z) lift. [`JointGaussNewton`](@ref) (the default)
reads the loss's closed forms through [`lift_zblock`](@ref);
[`WelschConvexNewton`](@ref) is the convexified-Newton z-block of the Welsch lift.
"""
abstract type LiftZBlock end

"""
    JointGaussNewton()

The Gauss–Newton z-block: per point the joint system is
`[w̄·JᵢᵀJᵢ, zᵢ·Jᵢᵀrᵢ; ·, ‖rᵢ‖² + hreg + μ]` with `(rinv2, hreg) = lift_zblock(loss, w̄)`
and z-gradient `zᵢ(‖rᵢ‖² − rinv2)`. Any object answering `lift_zblock` and
[`lift_window`](@ref) is a loss for it — a `DeployedLoss` or a
[`TabulatedLift`](@ref).
"""
struct JointGaussNewton <: LiftZBlock end

"""
    WelschConvexNewton()

The convexified-Newton z-block of the Welsch lift (Zach & Bourmaud, ECCV 2018,
Eq. 15). Per point, for Φᵢ = w‖rᵢ‖² + κ²(w), w = z², κ² the Welsch conjugate —
Φ carries no ½, so every derivative is twice the Gauss–Newton block's:

    ∂Φ/∂θ = 2w Jᵀr,  ∂Φ/∂z = 2z(‖r‖² − rinv2),
    θθ = 2w JᵀJ,  θz = 4z Jᵀr,  zz = 2(‖r‖² − rinv2) + 4w·κ²″(w),

with `rinv2` from [`lift_zblock`](@ref) and the z-block convexified to
`max(zz, 8‖r‖²) + μ` so the Schur-reduced θ-Hessian stays positive
semidefinite. The curvature `w·κ²″(w)` is Welsch's own (it is `c²`), so the
loss must be a deployed `WelschShape` (checked).
"""
struct WelschConvexNewton <: LiftZBlock end

# w̄ = z² clamp window of a closed-form loss's lift, and the flat z₀ level
# (the all-in convex-end start) inside it.
const _LIFT_WLO = 1.0e-9
const _LIFT_WHI = 1.0
const _LIFT_W0 = 0.95

"""
    lift_window(loss) -> (w̄lo, w̄hi)

The clamp window of the normalized line-process weight `w̄ = z²` the lift runs
in: `(1e-9, 1)` for a closed-form loss, the table's own grid for a
[`TabulatedLift`](@ref).
"""
@inline lift_window(::AnyLoss) = (_LIFT_WLO, _LIFT_WHI)

# Per-point coefficients of the joint system at one point with squared
# residual norm `rsq`: (dᵢ = 1/zz-pivot, gzᵢ, θθ weight Aᵢ, θ-gradient weight γᵢ).
@inline function _lift_coefficients(::JointGaussNewton, loss, zi, w, rsq, μ)
    rinv2, hreg = lift_zblock(loss, w)    # r²(w̄) + z-block Hessian, at the loss's own width
    di = 1.0 / (rsq + hreg + μ); gz = zi * (rsq - rinv2)
    return di, gz, w, zi
end
@inline function _lift_coefficients(::WelschConvexNewton, loss, zi, w, rsq, μ)
    rinv2, _ = lift_zblock(loss, w)                          # r²(w̄) = −c² ln w̄
    gz = 2.0 * zi * (rsq - rinv2)                            # ∂Φ/∂z: twice the GN z-gradient
    zz = 2.0 * (rsq - rinv2) + 4.0 * _convex_newton_curvature(loss, w)   # ∂²Φ/∂z²
    h_z = max(zz, 8.0 * rsq) + μ                             # convexify (p.s.d.) + damp
    return 1.0 / h_z, gz, 2.0 * w, 0.5 * zi
end
# The θ–z coupling κᵢ: bᵢ = κᵢ·Jᵢᵀrᵢ in the Schur reduction and the back-substitution.
@inline _lift_coupling(::JointGaussNewton, zi) = zi
@inline _lift_coupling(::WelschConvexNewton, zi) = 4.0 * zi

# w·κ²″(w) of the loss's conjugate — the shape's own `conjugate_curvature`,
# for the deployed Welsch loss only: the convexification is derived and
# verified for Welsch (whose curvature is the constant c², so w̄ is unused).
@inline _convex_newton_curvature(loss::AnyLoss, w) = _convex_newton_curvature(loss_shape(loss), w, sq_loss_width(loss))
@inline _convex_newton_curvature(shape::WelschShape, w, sq_loss_width) = conjugate_curvature(shape, w, sq_loss_width)
_convex_newton_curvature(shape::AbstractLossShape, w, sq_loss_width) = throw(ArgumentError(
    "WelschConvexNewton: the convexified-Newton z-block is derived for the Welsch " *
        "loss; got $(shape)"
))
_convex_newton_curvature(loss, w) = throw(ArgumentError(
    "WelschConvexNewton: the convexified-Newton z-block needs a deployed Welsch " *
        "loss; got a $(typeof(loss))"
))

# =============================================================================
# The θ-block, the z back-substitution and the GNC θ-block
# =============================================================================

"""
    _lift_hq_increment!(rws::RowsWorkspace{D, C}, ls::LiftState{D}, loss, μ, n, valid;
                        zblock = JointGaussNewton()) -> SVector{D,Float64} | nothing

θ-block of one joint-(θ,z) half-quadratic step: accumulate the Schur-reduced
θ-Hessian/gradient from the CURRENT rows `rws.r` and tangent Jacobian `rws.J`
at the anchor, under the z-block kind `zblock` (see [`LiftZBlock`](@ref)), and
solve the damped D×D system. `w̄ = z²` is clamped to [`lift_window`](@ref)`(loss)`.
Fills `ls.dvec`/`ls.gzv` for the follow-up [`_update_lift_z!`](@ref)
(zeroed for `valid`-masked points). Returns Δθ, or `nothing` when the solve
fails or produces non-finite entries — the caller's `update_model!` converts
that to the `block_coordinate_descent!` `:solve_failed` exit.

THE LOSS CARRIES ITS WIDTH: a caller whose scale MOVES supplies a FRESH deployment
per iteration (`rescale(loss, s2)`), never a stored loss beside a changing
scalar. `loss` is anything answering `lift_zblock` and `lift_window` — a
`DeployedLoss` or a [`TabulatedLift`](@ref), at every codimension.
"""
@inline function _lift_hq_increment!(
        rws::RowsWorkspace{D, C}, ls::LiftState{D}, loss, μ::Float64, n::Int,
        valid::Union{Nothing, Vector{Bool}}; zblock::LiftZBlock = JointGaussNewton()
    ) where {D, C}
    r = rws.r; J = rws.J; z = ls.z; dvec = ls.dvec; gzv = ls.gzv
    wlo, whi = lift_window(loss)                           # w̄ = z² ∈ (wlo, whi]  (w̄ = w/w_max)
    H = zero(SMatrix{D, D, Float64}); g = zero(SVector{D, Float64})
    @inbounds for i in 1:n
        if valid !== nothing && !valid[i]
            dvec[i] = 0.0; gzv[i] = 0.0                    # decouple: Δzᵢ = 0 in back-substitution
            continue
        end
        zi = z[i]; w = clamp(zi * zi, wlo, whi)
        κ = _lift_coupling(zblock, zi)
        if C == 1
            # One row: Jᵢᵀrᵢ = rᵢ·Jᵢ, so bᵢbᵢᵀ = (κrᵢ)²·JᵢJᵢᵀ and the point's whole
            # θ-block is ONE scaled outer product (the same algebra, a third
            # of the arithmetic).
            Ji, ri = _point_row(J, r, i, Val(D))
            rsq = ri * ri
            di, gz, A, γ = _lift_coefficients(zblock, loss, zi, w, rsq, μ)
            κr = κ * ri
            g += ((γ - di * gz) * κr) * Ji
            H += ((A - di * κr * κr) * Ji) * Ji'
        else
            JtJ, Jtr, rsq = _point_blocks(J, r, i, Val(D), Val(C))
            di, gz, A, γ = _lift_coefficients(zblock, loss, zi, w, rsq, μ)
            b = κ * Jtr                                   # θ–z coupling bᵢ = κᵢ·Jᵢᵀrᵢ
            g += (γ - di * gz) * b
            H += A * JtJ - di * (b * b')
        end
        dvec[i] = di; gzv[i] = gz
    end
    Hbuf = ls.Hbuf; gbuf = ls.gbuf
    Hbuf .= H; gbuf .= g
    return _damped_solve(Val(D), Hbuf, gbuf)
end

"""
    _update_lift_z!(rws::RowsWorkspace{D, C}, ls::LiftState{D}, Δθ, loss, n, valid;
                    zblock = JointGaussNewton()) -> nothing

Back-substitute the line-process step after the θ solve:
`Δzᵢ = −dᵢ(gzᵢ + bᵢᵀΔθ)` with `bᵢ = κᵢ·Jᵢᵀrᵢ` recomputed from the SAME anchor
rows the θ solve used, clamped to `[√w̄lo, √w̄hi]` of the loss's
[`lift_window`](@ref). Points masked out by `valid` are skipped (their
`dvec`/`gzv` slots are zero anyway); their z survives to the next iteration.
"""
@inline function _update_lift_z!(
        rws::RowsWorkspace{D, C}, ls::LiftState{D}, Δθ::SVector{D, Float64}, loss, n::Int,
        valid::Union{Nothing, Vector{Bool}}; zblock::LiftZBlock = JointGaussNewton()
    ) where {D, C}
    r = rws.r; J = rws.J; z = ls.z; dvec = ls.dvec; gzv = ls.gzv
    wlo, whi = lift_window(loss)
    @inbounds for i in 1:n
        valid !== nothing && !valid[i] && continue
        zi = z[i]
        bΔ = _lift_coupling(zblock, zi) * dot(_point_jtr(J, r, i, Val(D), Val(C)), Δθ)
        Δz = -dvec[i] * (gzv[i] + bΔ)
        z[i] = clamp(zi + Δz, sqrt(wlo), sqrt(whi))
    end
    return nothing
end

"""
    _lift_gnc_increment!(rws::RowsWorkspace{D, C}, ls::LiftState{D}, loss, μ, n, valid)
        -> (SVector{D,Float64}, band::Int) | nothing

θ-block of one GNC surrogate-weighted Gauss–Newton step (no z block): per-point
weights are the Yang–Carlone surrogate at the current rung,
`w = gnc_weight(loss, ‖rᵢ‖², μ)`, one weight scaling all C rows of the point.
Returns the damped tangent step Δθ with the TLS middle-band count (points with
0 < w < 1 — the `:tls` rung-advance signal; 0 for the other families), or
`nothing` on solve failure. `valid`-masked points are excluded entirely.
"""
@inline function _lift_gnc_increment!(
        rws::RowsWorkspace{D, C}, ls::LiftState{D}, loss::DeployedLoss, μ::Float64, n::Int,
        valid::Union{Nothing, Vector{Bool}}
    ) where {D, C}
    r = rws.r; J = rws.J
    H = zero(SMatrix{D, D, Float64}); g = zero(SVector{D, Float64})
    band = 0
    surr = gnc_surrogate(loss)          # loop-invariant: a zero-field singleton
    @inbounds for i in 1:n
        valid !== nothing && !valid[i] && continue
        # The rung-advance signal is the SURROGATE FAMILY's, not this loop's:
        # `band_signal` is 0 for every family but the band-annealed one, so the
        # accumulation is unconditional here and folds away where it is 0.
        if C == 1
            Ji, ri = _point_row(J, r, i, Val(D))
            w = gnc_weight(loss, ri * ri, μ)
            band += band_signal(surr, w)
            wJ = w * Ji
            g += ri * wJ
            H += wJ * Ji'
        else
            JtJ, Jtr, rsq = _point_blocks(J, r, i, Val(D), Val(C))
            w = gnc_weight(loss, rsq, μ)
            band += band_signal(surr, w)
            g += w * Jtr
            H += w * JtJ
        end
    end
    Hbuf = ls.Hbuf; gbuf = ls.gbuf
    Hbuf .= H; gbuf .= g
    Δθ = _damped_solve(Val(D), Hbuf, gbuf)
    Δθ === nothing && return nothing
    return Δθ, band
end

"""
    _seed_lift_z!(ls::LiftState, loss, res, n, policy::Symbol) -> nothing

The z₀ policy of a lift run (w̄ = z² inside the loss's [`lift_window`](@ref),
capped at the flat level 0.95): `:flat` — every point at the all-in convex-end
start; `:posterior` — the loss's own normalized IRLS weight
`lift_weight(loss, rᵢ²) / lift_wmax(loss)` at the seed residual `res[i]` (the
provider's residual currency); `:consensus` — flat for a point whose weight is
≥ ½, the window floor otherwise.
"""
function _seed_lift_z!(ls::LiftState, loss, res, n::Int, policy::Symbol)
    z = ls.z
    if policy === :flat                                 # reads neither the loss nor `res`
        @inbounds for i in 1:n
            z[i] = sqrt(_LIFT_W0)
        end
    elseif policy === :posterior || policy === :consensus
        _seed_weighted_z!(z, loss, res, n, policy === :consensus)
    else
        throw(ArgumentError("lift: unknown z₀ policy :$policy (expected :flat|:posterior|:consensus)"))
    end
    return nothing
end

# The weight-seeded z₀ policies read the loss's own IRLS weight: a closed-form
# (deployed) loss's. `hard`: :consensus (inlier iff that weight ≥ ½), else :posterior.
function _seed_weighted_z!(z, loss::AnyLoss, res, n::Int, hard::Bool)
    wlo = first(lift_window(loss)); whi = _LIFT_W0
    wmax = lift_wmax(loss)
    @inbounds for i in 1:n
        w̄ = lift_weight(loss, res[i] * res[i]) / wmax
        z[i] = sqrt(hard ? (w̄ >= 0.5 ? whi : wlo) : clamp(w̄, wlo, whi))
    end
    return z
end
_seed_weighted_z!(z, loss, res, n::Int, hard::Bool) = throw(ArgumentError(
    "lift: the weight-seeded z₀ policies need a closed-form loss; got a $(typeof(loss))"
))

# =============================================================================
# TabulatedLift — the half-quadratic conjugate of a weight with no closed form
# =============================================================================
#
# A loss whose IRLS weight ω(x) (x = r²) is known but whose Geman–Reynolds
# conjugate κ²(w) is not — the Student-t + uniform mixture is the case in the
# stack — is lifted through a TABLE: ω is inverted by Newton on a log-spaced
# weight grid to r²(w), which integrates (trapezoid) to κ²(w) = ∫_w^{w_max} r².
# The stationarity condition κ²′(w) = −r²(w) gives EXACT node slopes, so a cubic
# Hermite on the node values reproduces κ² to high order from a coarse grid
# (M ≈ 32 matches a ~1000-node linear table), and one evaluation yields both
# quantities the z-block needs. Moved here from RobustVisualGeometry's
# essential-matrix mixture lift, where it was written against the mixture.

"""
    TabulatedLift(M; γ = 1)

Buffers for an `M`-node tabulated half-quadratic conjugate, filled by
[`tabulate!`](@ref). A loss for the lift's Gauss–Newton z-block (any codimension): it
answers [`lift_zblock`](@ref), [`lift_window`](@ref), [`lift_wmax`](@ref) and
[`lift_conjugate`](@ref). `γ` scales the conjugate (the lifting regularizer's
strength: `γ > 1` makes the lift more reluctant to switch points off).
"""
mutable struct TabulatedLift
    wg::Vector{Float64}      # ascending weight grid
    xg::Vector{Float64}      # r²(w) at the nodes
    kg::Vector{Float64}      # κ²(w) at the nodes
    w_max::Float64           # ω(0), the inlier-limit weight
    γ::Float64
end
TabulatedLift(M::Integer; γ::Real = 1.0) = TabulatedLift(
    Vector{Float64}(undef, M), Vector{Float64}(undef, M), Vector{Float64}(undef, M),
    NaN, Float64(γ)
)

"""
    tabulated_lift(M; γ = 1.0) -> TabulatedLift

`TabulatedLift(M; γ)` under the one reuse policy: one table per (task, `M`),
reset to the fresh table's state (`w_max = NaN`, `γ`; its nodes are filled by
the first [`tabulate!`](@ref) of each run before anything reads them).
"""
function tabulated_lift(M::Integer; γ::Real = 1.0)
    tab = task_buffers(TabulatedLift, () -> TabulatedLift(M; γ), (:lodr_tabulated_lift, Int(M)))
    tab.w_max = NaN
    tab.γ = Float64(γ)
    return tab
end

"""
    tabulate!(tab::TabulatedLift, ω; warm = false) -> w_max

Fill `tab` for the weight function `ω(x) -> (ω, dω/dx)` (a `Float64` pair) of the
squared residual `x`, which must decrease strictly from `w_max = ω(0)`. The grid spans
`w_max·[1e-9, 1 − 1e-9]` log-spaced; each node's `r²(w)` is a Newton root of
`ω(x) = w` started from the adjacent node's root, or — with `warm = true`, for
a table re-built after a small change of `ω` — from the SAME node's previous
root.
"""
function tabulate!(tab::TabulatedLift, ω; warm::Bool = false)
    wg = tab.wg; xg = tab.xg; kg = tab.kg; M = length(wg)
    w_max = first(ω(0.0)::NTuple{2, Float64})
    wg .= exp.(range(log(w_max * 1.0e-9), log(w_max * (1 - 1.0e-9)); length = M))
    xc = 0.0
    @inbounds for k in M:-1:1                  # invert ω(x) = wg[k]
        w = wg[k]
        x = (warm && isfinite(xg[k]) && xg[k] > 0.0) ? xg[k] : xc
        for _ in 1:40
            ωx, dω = ω(x)::NTuple{2, Float64}; xn = max(x - (ωx - w) / dω, 0.0)
            abs(xn - x) <= 1.0e-13 * (1 + x) && (x = xn; break); x = xn
        end
        xg[k] = x; xc = x
    end
    kg[M] = 0.0
    @inbounds for k in (M - 1):-1:1
        kg[k] = kg[k + 1] + 0.5 * (xg[k] + xg[k + 1]) * (wg[k + 1] - wg[k])
    end
    return tab.w_max = w_max
end

"""
    cubic_hermite(f0, d0, f1, d1, u, h)

The cubic Hermite interpolant on one interval of width `h` at the fraction
`u ∈ [0, 1]`, from the node values `f0`, `f1` and node slopes `d0`, `d1`
(slopes per unit of the abscissa, so they enter scaled by `h`). Generic over
the number type, so it runs on device inside a kernel.
"""
@inline function cubic_hermite(f0, d0, f1, d1, u, h)
    u2 = u * u; u3 = u2 * u
    return (2u3 - 3u2 + 1) * f0 + (u3 - 2u2 + u) * h * d0 +
        (-2u3 + 3u2) * f1 + (u3 - u2) * h * d1
end

# Cubic-Hermite lookup of (r²(w), κ²(w)) at raw weight `w`: node values `kg`,
# exact node slopes −xg; r²(w) = −κ²′(w) from the same cubic.
@inline function _tabulated_conjugate(tab::TabulatedLift, w::Float64)
    wg = tab.wg; xg = tab.xg; kg = tab.kg; M = length(wg)
    j = clamp(searchsortedfirst(wg, w), 2, M)
    w0 = wg[j - 1]; w1 = wg[j]; h = w1 - w0
    t = (w - w0) / h; t2 = t * t
    k0 = kg[j - 1];  k1 = kg[j]
    d0 = -xg[j - 1]; d1 = -xg[j]                          # κ²′ = −r² (exact)
    kap2 = cubic_hermite(k0, d0, k1, d1, t, h)            # κ²(w)
    g00 = 6t2 - 6t; g10 = 3t2 - 4t + 1; g01 = -6t2 + 6t; g11 = 3t2 - 2t
    dκ = (g00 * k0 + g01 * k1) / h + g10 * d0 + g11 * d1  # κ²′(w)
    return -dκ, kap2
end

@inline lift_wmax(tab::TabulatedLift) = tab.w_max
@inline lift_window(tab::TabulatedLift) = (tab.wg[1] / tab.w_max, tab.wg[end] / tab.w_max)
"""
    lift_raw_window(tab::TabulatedLift) -> (wlo, whi)

The table's weight grid ends on the RAW (unnormalized) weight scale — the clamp
window of a caller that works in raw weights; [`lift_window`](@ref) is the same
window normalized by [`lift_wmax`](@ref).
"""
@inline lift_raw_window(tab::TabulatedLift) = (tab.wg[1], tab.wg[end])
"The tabulated conjugate `γ·κ²(w)` at raw weight `w`."
@inline lift_conjugate(tab::TabulatedLift, w) = tab.γ * last(_tabulated_conjugate(tab, Float64(w)))
@inline function lift_zblock(tab::TabulatedLift, w̄)
    w_max = tab.w_max
    rinv2, kap2raw = _tabulated_conjugate(tab, w_max * w̄)
    rinv2 = max(rinv2, 0.0); kap2 = max(tab.γ * kap2raw, 1.0e-30)
    return rinv2, w̄ * rinv2 * rinv2 * w_max / kap2        # (r²(w̄), w̄·r²²/κ̄²(w̄))
end

"""
    tabulate!(tab::TabulatedLift, m::StudentTMixture; warm = false) -> w_max

Tabulate the half-quadratic conjugate `κ²` of the Student-t + uniform mixture's
IRLS weight — which has no closed form — from the weight and its slope,
VisualGeometryCore's `posterior_weight` and `posterior_weight_derivative`.
"""
tabulate!(tab::TabulatedLift, m::StudentTMixture; warm::Bool = false) =
    tabulate!(tab, x -> (posterior_weight(m, x), posterior_weight_derivative(m, x)); warm)
