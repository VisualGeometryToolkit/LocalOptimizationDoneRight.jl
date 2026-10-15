# =============================================================================
# LO continuation schedules — the ONE place schedule/stall semantics live
# =============================================================================
#
# A graduated local optimizer runs its solver under a continuation multiplier
# (a GNC μ, or a loss-width multiplier) that a SCHEDULE advances
# toward its terminal value. Historically every engine re-implemented the
# advance/terminate bookkeeping, and the single worst bug class was the
# STALL-AT-WIDE-SURROGATE failure: a converged (stalled) inner step at a
# non-terminal schedule position must ADVANCE the schedule, never terminate
# the engine — otherwise easy seeds converge at a wide surrogate and the
# anneal never completes, so the pose is never optimized at the terminal
# objective (RobustVisualGeometry commit 373d0a6 fixed exactly this in
# GncIrls; ScheduledWelschIrls carried the pre-fix semantics until the
# schedule trait consolidated them here).
#
# The contract encodes those semantics ONCE. The consuming solver loop is:
#
#     small = norm(Δθ) < tol                  # inner-step stall?
#     small && isterminal(st; open) && break   # TERMINAL convergence only
#     advance!(st, small; open)               # scheduled or stall-early advance
#
# `open` is the optional engine-side observation that the schedule may still
# make progress (e.g. the GNC-TLS middle band is non-empty); schedules that
# do not consume it ignore it.
#
# Types and contracts only — the trait is pure bookkeeping (no solver code,
# no dependencies), matching this file's siblings in robust/.
# =============================================================================

"""
    LoSchedule

A continuation schedule for graduated local optimization: owns the current
continuation multiplier and the advance/terminate bookkeeping.

The contract (all four verbs; see the header for the consuming loop shape):

- `schedule_init(sched, mu0, max_iter) -> state`: mutable schedule state from
  the seed-derived start multiplier `mu0` and the TOTAL inner-iteration
  budget `max_iter` (schedules that split the budget into rungs derive the
  rung length here — defined once, never re-inlined by engines).
- `scale_mult(state) -> Float64`: the current continuation multiplier (the
  GNC μ, or the loss-width multiplier).
- `isterminal(state; open=true) -> Bool`: whether the schedule has reached
  its terminal objective. A stalled inner step may end the engine ONLY when
  this is true.
- `advance!(state, stalled::Bool; open=true)`: per-iteration bookkeeping.
  A stalled step at a non-terminal position advances the schedule (rung
  ladders: early rung advance; time-indexed anneals: jump to terminal) —
  the stall-advance semantics, defined here once.
"""
abstract type LoSchedule end

function schedule_init end
function scale_mult end
function advance! end
function isterminal end

# -----------------------------------------------------------------------------
# NoSchedule — static objective (no continuation)
# -----------------------------------------------------------------------------

"""
    NoSchedule()

The trivial schedule of a static-objective engine: multiplier 1, always
terminal (a stalled step ends the engine immediately).
"""
struct NoSchedule <: LoSchedule end

struct NoScheduleState end

schedule_init(::NoSchedule, mu0::Float64, max_iter::Int) = NoScheduleState()
scale_mult(::NoScheduleState) = 1.0
isterminal(::NoScheduleState; open::Bool = true) = true
advance!(::NoScheduleState, stalled::Bool; open::Bool = true) = nothing

# -----------------------------------------------------------------------------
# MuLadder — rung-based GNC μ-ladder (Yang–Carlone RA-L 2020 bookkeeping)
# -----------------------------------------------------------------------------

"""
    MuLadder(factor; direction = :down, cap = Inf)

The GNC rung ladder: μ starts at a seed-derived `mu0` and moves by `factor`
per rung toward its terminal value — `direction = :down` anneals μ → 1
(GM / annealed-width Welsch surrogates; terminal at μ = 1), `direction = :up`
anneals μ → `cap` (the TLS surrogate; terminal when the caller reports the
middle band empty via `open = false`, or at μ ≥ `cap`).

`schedule_init` splits the TOTAL budget into rungs exactly as the GncIrls
engines always did: `n_rungs` from the μ0 → terminal ladder at `factor`
(down: `⌈log(μ0)/log(factor)⌉ + 1` including the terminal μ = 1 phase; up:
`⌈log(cap/μ0)/log(factor)⌉`), `rung_len = max(1, ⌊max_iter/n_rungs⌋)`.

`advance!` moves to the next rung when the rung budget is spent OR the inner
step stalled (the stall-early advance — see the file header).

    MuLadder(factor; direction = :down, cap = Inf, converged_rung = false)

CONVERGED-RUNG mode (`converged_rung = true`): no per-rung budget split —
each rung runs until the inner step stalls and ONLY a stall advances the
schedule (the Yang–Carlone-faithful setting; `max_iter` becomes a SAFETY
ceiling enforced by the consuming loop, not a parity budget). Equivalent to
an infinite `rung_len`; the budget contract is mode-aware: parity mode
spends exactly the split, converged-rung mode is bounded only by the
ceiling.
"""
struct MuLadder <: LoSchedule
    factor::Float64
    direction::Symbol      # :down (μ → 1) | :up (μ → cap)
    cap::Float64
    converged_rung::Bool   # true ⇒ rung advances ONLY on stall (no budget split)
end
function MuLadder(
        factor::Real; direction::Symbol = :down, cap::Real = Inf,
        converged_rung::Bool = false
    )
    direction in (:down, :up) ||
        throw(ArgumentError("MuLadder: direction must be :down or :up, got :$direction"))
    # a :down ladder ends at μ = 1 and never reads `cap`: refuse one rather than ignore it
    direction === :down && isfinite(cap) &&
        throw(ArgumentError("MuLadder: `cap` bounds an :up ladder; a :down ladder ends at μ = 1, got cap = $cap"))
    return MuLadder(Float64(factor), direction, Float64(cap), converged_rung)
end

"""
    with_converged_rung(s::MuLadder, converged_rung::Bool) -> MuLadder

The same ladder (factor, direction, cap) in the other rung mode: `true` advances
a rung only on a stall, `false` splits the budget across the rungs.
"""
with_converged_rung(s::MuLadder, converged_rung::Bool) =
    MuLadder(s.factor, s.direction, s.cap, converged_rung)

mutable struct MuLadderState
    μ::Float64
    factor::Float64       # fixed for a run (the state is reused across runs: `reused_state`)
    direction::Symbol
    cap::Float64
    rung_len::Int
    it_in_rung::Int
end

"Rung count of the μ0 → terminal ladder at `factor` (for the budget split)."
function n_rungs(sched::MuLadder, mu0::Float64)
    if sched.direction === :down
        mu0 <= 1.0 && return 1
        return ceil(Int, log(mu0) / log(sched.factor)) + 1   # + terminal μ=1 phase
    else
        mu0 >= sched.cap && return 1
        return ceil(Int, log(sched.cap / mu0) / log(sched.factor))
    end
end

function schedule_init(sched::MuLadder, mu0::Float64, max_iter::Int)
    # Converged-rung mode: no budget split — an effectively infinite rung
    # length makes `advance!` fire on stalls only.
    rung_len = sched.converged_rung ? typemax(Int) ÷ 2 :
        max(1, floor(Int, max_iter / n_rungs(sched, mu0)))
    return reused_state(MuLadderState, (mu0, sched.factor, sched.direction, sched.cap, rung_len, 0))
end

scale_mult(st::MuLadderState) = st.μ

isterminal(st::MuLadderState; open::Bool = true) =
    st.direction === :down ? st.μ <= 1.0 : (!open || st.μ >= st.cap)

function advance!(st::MuLadderState, stalled::Bool; open::Bool = true)
    st.it_in_rung += 1
    if st.it_in_rung >= st.rung_len || stalled
        st.it_in_rung = 0
        if st.direction === :down
            st.μ = max(st.μ / st.factor, 1.0)
        elseif open && st.μ < st.cap
            st.μ = min(st.μ * st.factor, st.cap)
        end
    end
    return nothing
end

"""
    gnc_schedule(loss, factor) -> MuLadder

The rung ladder for a loss's graduation (moved from RVG scoring_glue.jl
2026-07-18): a [`BandAnnealed`](@ref) shape anneals μ UP to the hard-surrogate
cap (VisualGeometryCore's `gnc_mu_cap()` — the same cap `gnc_mu0` guards to); the
μ-scaled families anneal μ DOWN to 1, the target loss. Only the
direction/cap mapping is per-family — rung arithmetic (n_rungs, rung_len) is
[`MuLadder`](@ref).

Dispatches on [`gnc_surrogate`](@ref) like the rest of the `gnc_*` family, so a
shape with no graduation path is a `MethodError` rather than a tag that falls
through to a default branch.
"""
gnc_schedule(loss::DeployedLoss, factor::Float64) =
    _gnc_schedule(gnc_surrogate(loss), factor)
_gnc_schedule(::BandAnnealed, factor::Float64) =
    MuLadder(factor; direction = :up, cap = gnc_mu_cap())
_gnc_schedule(::MuScaled, factor::Float64) = MuLadder(factor)   # anneal μ → 1

# -----------------------------------------------------------------------------
# GeometricAnneal — time-indexed geometric width anneal
# -----------------------------------------------------------------------------

"""
    GeometricAnneal(octaves)

The time-indexed continuation of the scheduled-Welsch family: at iteration
`t` of `T` the width multiplier is `2^{octaves·(1 − (t−1)/(T−1))}` — `2^oct`
at t = 1 decaying geometrically to exactly 1 at t = T (T ≤ 1 ⇒ 1).

Stall semantics (the D1 fix, defined here once): a stalled inner step at
t < T JUMPS the schedule to its terminal position (t → T) and the engine
continues at the terminal width until a terminal stall or the iteration
budget — a stall never ends the engine at a wide surrogate.
"""
struct GeometricAnneal <: LoSchedule
    octaves::Float64
end
GeometricAnneal(octaves::Real) = GeometricAnneal(Float64(octaves))

mutable struct GeometricAnnealState
    t::Int
    T::Int                # fixed for a run (the state is reused across runs: `reused_state`)
    octaves::Float64
end

schedule_init(sched::GeometricAnneal, mu0::Float64, max_iter::Int) =
    reused_state(GeometricAnnealState, (1, max_iter, sched.octaves))

scale_mult(st::GeometricAnnealState) =
    st.T <= 1 ? 1.0 : 2.0^(st.octaves * (1.0 - (st.t - 1) / (st.T - 1)))

isterminal(st::GeometricAnnealState; open::Bool = true) = st.t >= st.T

function advance!(st::GeometricAnnealState, stalled::Bool; open::Bool = true)
    if stalled
        st.t = st.T                    # stall at a non-terminal width: jump to terminal
    else
        st.t = min(st.t + 1, st.T)
    end
    return nothing
end
