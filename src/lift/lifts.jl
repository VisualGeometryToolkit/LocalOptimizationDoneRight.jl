# =============================================================================
# The half-quadratic loss lifts and the GNC ports — ONE code path over
# VisualGeometryCore's chart-rows contract (a problem's provider supplies the
# rows, their Jacobian, the re-anchor and the model; RobustVisualGeometry
# implements it for its chart problems). Moved from RobustVisualGeometry's
# problems/manifold_providers.jl and estimators/ransac/interface.jl.
# =============================================================================

# =============================================================================
# The lift methods' shared protocol — incumbent, stop rule, result
# =============================================================================
#
# Every lift method (the HQ and GNC drivers below; the
# mixture and ReGeMM arms, strategies/essential.jl) runs on a provider `prov` and a mutable state holding
# the current chart `θ`, its cost `cur_cost` and the incumbent `best` (VGC
# `Incumbent`). They share ONE best-tracking update, ONE step-norm stop rule and
# ONE result hook: the incumbent's model.

abstract type AbstractLiftMethod <: AbstractBlockCoordinateMethod end

# The joint-(θ,z) lifts — the loss lift and the tabulated mixture lift
# (strategies/essential.jl) — share ONE model block (`update_model!` below).
abstract type JointLiftMethod <: AbstractLiftMethod end

# Offer the current iterate to the incumbent; returns whether it improved.
@inline function _track_incumbent!(state)
    state.best, improved = keep_best(state.best, state.θ, state.cur_cost)
    return improved
end

# The lift's convergence floor: the last tangent increment's norm.
const _LIFT_INCREMENT_TOL = 1.0e-10
@inline _increment_stalled(state) = state.Δθnorm < _LIFT_INCREMENT_TOL

# =============================================================================
# The stopping criteria of RVG's block-coordinate states (VGC
# `StoppingCriterion`; each method's `stopping_criterion` composes them). Pure:
# they read the counters `post_iteration!` keeps in the state.
# =============================================================================

"""
    StopWhenIncrementSmall()

`:converged` once the last tangent increment's norm is below the lift's floor
(`_increment_stalled`, `_LIFT_INCREMENT_TOL`).
"""
struct StopWhenIncrementSmall <: StoppingCriterion end
@inline stop_reason(::StopWhenIncrementSmall, state, method, prob, θ, θ_old, iter) =
    _increment_stalled(state) ? :converged : :continue

post_iteration!(state, ::AbstractLiftMethod, prob, θ, iter) = (_track_incumbent!(state); nothing)

# The residuals block of every lift method: the provider's residuals at the
# current chart, then the method's tracked objective on them — `_lift_objective`
# (the loss lifts' `lift_cost`, below; the mixture NLL,
# essential.jl).
function update_residuals!(state, method::AbstractLiftMethod, prob, θ)
    lift_refresh!(method.prov, state.θ)
    state.cur_cost = _lift_objective(state, method, lift_residuals(method.prov))
    return nothing
end

block_coordinate_result(state, method::AbstractLiftMethod, prob, θ, stop_reason, final_iter) =
    lo_estimate(lift_model(method.prov, state.best.θ), stop_reason; iterations = final_iter)


# =============================================================================
# ManifoldLiftHQ — THE joint-(θ,z) half-quadratic loss lift (all providers)
# =============================================================================

# `zblock` (VGC `LiftZBlock`) selects the joint system — the Gauss–Newton one by
# default, the Welsch convexified Newton for `WelschHQNewton` — at every
# codimension. The width rides on the deployed loss.
struct ManifoldLiftHQ{L <: DeployedLoss, Prov, Z <: LiftZBlock, S <: LiftState} <: JointLiftMethod
    prov::Prov
    n::Int
    loss::L      # shape + (scale_multiple, ŝ²) at the seed anchor; the width is `sq_loss_width(loss)`
    μ::Float64
    zblock::Z    # the joint system's z-block (`LiftZBlock`)
    ls::S        # the lift's own state (z and the reduced system)
end
ManifoldLiftHQ(prov, n::Int, loss::DeployedLoss, μ::Float64, zblock::LiftZBlock = JointGaussNewton()) =
    ManifoldLiftHQ(prov, n, loss, μ, zblock, provider_lift_state(prov))

"""
    provider_lift_state(prov) -> LiftState{D}

The lift state for a provider's chart dimension and point count (one per
(task, size), the one reuse policy).
"""
provider_lift_state(prov) = _lift_state_for(lift_rows(prov), lift_size(prov))
_lift_state_for(::RowsWorkspace{D}, n::Int) where {D} = lift_state(Val(D), n)

# `loss` is THE loss this iterate runs at. It starts as the method's and a
# fixed-scale arm never moves it (`FixedWelschScale`); a self-scaling policy
# (`WelschEcmScale`, strategies/essential.jl) replaces it between iterations.
mutable struct ManifoldLiftHQState{M, L <: DeployedLoss}
    θ::M
    cur_cost::Float64
    best::Incumbent{M}
    Δθnorm::Float64
    loss::L
end

# z₀ (VGC `_seed_lift_z!`, in the provider's residual currency, read off THE
# DEPLOYED LOSS), then the seed cost — the incumbent's start.
function _init_manifold_hq(method::ManifoldLiftHQ, θ₀, init::Symbol)
    prov = method.prov
    lift_refresh!(prov, θ₀)
    _seed_lift_z!(method.ls, method.loss, lift_residuals(prov), lift_size(prov), init)
    cur = lift_cost(method.loss, lift_residuals(prov), method.n)
    return reused_state(ManifoldLiftHQState{typeof(θ₀), typeof(method.loss)}, (θ₀, cur, Incumbent(θ₀, cur), Inf, method.loss))
end

# THE joint-(θ,z) model block of every half-quadratic lift — this driver and
# the tabulated Student-t mixture lift (strategies/essential.jl): one joint
# Gauss-Newton move on θ with Δz Schur-eliminated, then the z back-substitution.
# `_lift_loss` names what the z-block reads (the deployed loss THIS iterate
# runs at, or the mixture's κ² table), `_lift_zblock` the joint system. Reads the
# residuals at the current iterate (filled by the prior refresh); returns the
# new model, or `nothing` on a singular/non-finite solve (:solve_failed).
function update_model!(state, method::JointLiftMethod, prob, θ)
    prov = method.prov; n = method.n
    loss = _lift_loss(state, method); zblock = _lift_zblock(method)
    lift_jacobian!(prov, state.θ)
    Δθ = _lift_hq_increment!(lift_rows(prov), method.ls, loss, method.μ, n, lift_valid(prov); zblock)
    Δθ === nothing && return nothing
    θn = lift_retract(prov, state.θ, Δθ)      # the chart re-anchored at the step
    _update_lift_z!(lift_rows(prov), method.ls, Δθ, loss, n, lift_valid(prov); zblock)
    state.θ = θn; state.Δθnorm = norm(Δθ)
    return lift_model(prov, θn)
end
_lift_loss(state::ManifoldLiftHQState, ::ManifoldLiftHQ) = state.loss
_lift_zblock(method::ManifoldLiftHQ) = method.zblock

stopping_criterion(::ManifoldLiftHQ) = StopWhenIncrementSmall()
current_cost(state::ManifoldLiftHQState) = state.cur_cost

# THE ONE HQ{K} LO dispatch (every liftable problem, every closed-form loss):
# the loss from `lo_loss` (scoring_glue.jl: the shape at its width mode's
# width, VGC `loss_at`), the manifold from the provider.
function locally_optimize!(
        ::LoBuffers, lo::HQ, problem::LiftableProblem, model,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    loss = lo_loss(lo, cs, scoring, buf)
    return _manifold_hq!(problem, model, loss, lo.μ, lo.init, lo.max_iter)
end

# THE one run of the joint-(θ,z) half-quadratic lift: every HQ-family arm
# (HQ{K}, BarronHQ, GmHqEps) deploys its loss and hands it here, so they
# share the provider, the z₀ policy, the stop rule and the incumbent.
function _manifold_hq!(
        problem, model, loss::DeployedLoss, μ::Float64, init::Symbol, max_iter::Int;
        zblock::LiftZBlock = JointGaussNewton()
    )
    prov = rows_provider(problem)
    method = ManifoldLiftHQ(prov, lift_size(prov), loss, μ, zblock)
    state = _init_manifold_hq(method, lift_init(prov, model), init)
    return block_coordinate_descent!(state, FixedWelschScale(), method, problem, model; max_iter)
end

# The α-dial lift (BarronHQ): fixed-CORE-WIDTH standardization — the facet-B
# Barron loss width scale_multiple·ŝ/√2 holds the Gaussian-core curvature fixed
# across α (α → −∞ is then EXACTLY HQ{WelschShape} at the same scale_multiple:
# the Welsch-equivalent loss width is √2·(scale_multiple·ŝ/√2) = scale_multiple·ŝ),
# so the dial moves tail steepness only. The √2 is part of the CURRENCY
# (`deployed_scale_multiple(::BarronHQ, …)`), so it belongs in the scale
# multiple, not in the scale. Flat z₀, as the arm always started.
function locally_optimize!(
        ::LoBuffers, lo::BarronHQ, problem::LiftableProblem, model,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    loss = loss_at(lo, BarronShape(lo.α), cs, scoring, buf)
    return _manifold_hq!(problem, model, loss, lo.μ, :flat, lo.max_iter)
end

# The loss-width-parameterized Geman–McClure lift (GmHqEps): loss width
# scale_multiple·ŝ (a width multiple — identity currency), an absolute width,
# or the scorer's decision point (its GM half-weight radius at the scorer's
# threshold). Flat z₀, as the arm always started.
function locally_optimize!(
        ::LoBuffers, lo::GmHqEps, problem::LiftableProblem, model,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    loss = loss_at(lo, GemanMcclureShape(), cs, scoring, buf)
    return _manifold_hq!(problem, model, loss, lo.μ, :flat, lo.max_iter)
end
VisualGeometryCore.deployed_scale_multiple(::GmHqEps, _shape, m::Float64, _s2, _scoring) =
    m > 0 ? m : throw(ArgumentError(
    "GmHqEps: scale_multiple = $m — the crossover sentinel is retired; give no width to follow the scorer"))

# `BoundedProblem` is a VALIDATION decorator, not a different estimation
# problem: its extent is consumed by RANSAC's post-IRLS consensus hook
# (`_check_extent` — cheirality and quad-convexity over the board rectangle),
# never by the manifold lift, which only refines θ. The wrapper is not a
# `LiftableProblem` (it wraps one), so it forwards to the inner problem to
# reach its lift provider; the extent guard still fires upstream on the
# wrapper. Every provider-backed arm forwards — the HQ family and GNC alike.
locally_optimize!(
    L::LoBuffers, lo::Union{HQ, BarronHQ, GmHqEps, Gnc{<:Irls}}, problem::BoundedProblem{<:LiftableProblem},
    model, cs::ConsensusSet, buf::ScoreBuffers, scoring
) =
    locally_optimize!(L, lo, getfield(problem, :inner), model, cs, buf, scoring)

# =============================================================================
# ManifoldLiftGnc — THE canonical Yang–Carlone GNC port (all providers)
# =============================================================================
#
# Plain surrogate-weighted Gauss–Newton — no z block — driven by the SAME
# `block_coordinate_descent!` loop. Per-iteration weights are the GNC surrogate at the
# current rung (`gnc_weight` on x = rᵢ² in the provider's residual currency;
# codim 2: one weight per correspondence scaling both rows), the μ-ladder is
# VGC `MuLadder`, the target loss width is frozen at c̄² = scale_multiple²·ŝ² from the seed
# partition, best-tracking is on the TARGET loss at c̄ (`lift_cost`).
# Cheirality-masked points (PnP) are excluded from the θ accumulation and the
# μ₀ seed extreme; their target-cost entry saturates at the sentinel norm.

struct ManifoldLiftGnc{Prov, L <: DeployedLoss, S <: LiftState} <: AbstractLiftMethod
    prov::Prov
    n::Int
    loss::L      # c̄² = scale_multiple²·ŝ² is `sq_loss_width(loss)`, frozen at the consensus anchor
    ls::S        # the lift's own state (the reduced system)
end
ManifoldLiftGnc(prov, n::Int, loss::DeployedLoss) = ManifoldLiftGnc(prov, n, loss, provider_lift_state(prov))

mutable struct ManifoldLiftGncState{M}
    θ::M
    cur_cost::Float64
    best::Incumbent{M}
    Δθnorm::Float64
    st::MuLadderState     # VGC μ-ladder state (rung bookkeeping)
    band::Int             # TLS middle-band count (0 < w < 1) of the last iteration
    converged::Bool       # the last iteration stalled on the terminal rung (set by post_iteration!)
end

function update_model!(state::ManifoldLiftGncState, method::ManifoldLiftGnc, prob, θ)
    prov = method.prov; n = method.n
    μ = scale_mult(state.st)
    lift_jacobian!(prov, state.θ)
    out = _lift_gnc_increment!(lift_rows(prov), method.ls, method.loss, μ, n, lift_valid(prov))
    out === nothing && return nothing
    Δθ, band = out
    state.band = band
    θn = lift_retract(prov, state.θ, Δθ)
    state.θ = θn; state.Δθnorm = norm(Δθ)
    return lift_model(prov, θn)
end

# The tracked objective of the loss lifts (the residuals block,
# `update_residuals!` on `AbstractLiftMethod`): VGC's `lift_cost` at the loss
# the iterate runs at, over the provider's residual currency. For GNC that is
# the TARGET loss at c̄ — never the surrogate — for every iteration and the seed
# (a shape with no graduation never gets here: `gnc_schedule` and `gnc_weight`
# refuse it).
_lift_loss(_state, method::ManifoldLiftGnc) = method.loss
_lift_objective(state, method::Union{ManifoldLiftHQ, ManifoldLiftGnc}, r) =
    lift_cost(_lift_loss(state, method), r, method.n)

# Best-tracking, then the terminal-only termination test + scheduled/stall-early
# rung advance (the VGC LoSchedule contract — one-to-one with the retired
# per-problem ports). The terminal test reads the rung this iteration ran on, BEFORE
# `advance!` moves it; the stopping criterion (`StopWhenLadderConverged`, read
# right after, with nothing in between) only reads the stored verdict.
function post_iteration!(state::ManifoldLiftGncState, method::ManifoldLiftGnc, prob, θ, iter)
    _track_incumbent!(state)
    small = _increment_stalled(state)
    open = state.band > 0
    state.converged = small && isterminal(state.st; open)
    state.converged || advance!(state.st, small; open)
    return nothing
end

"""
    StopWhenLadderConverged()

`:converged` once an iteration stalled on the terminal rung of the GNC μ-ladder
(the verdict `post_iteration!` stores in `state.converged`).
"""
struct StopWhenLadderConverged <: StoppingCriterion end
@inline stop_reason(::StopWhenLadderConverged, state, method, prob, θ, θ_old, iter) =
    state.converged ? :converged : :continue
stopping_criterion(::ManifoldLiftGnc) = StopWhenLadderConverged()
current_cost(state::ManifoldLiftGncState) = state.cur_cost

# THE ONE Gnc{<:Irls} LO dispatch. Seed residuals → r²_max (over the valid
# points — PnP's behind-camera sentinel would otherwise blow the entry rung
# to a vacuous breadth) → μ₀ (Yang–Carlone seed extreme / entry policy) →
# schedule state; the seed model enters best-tracking at the target loss.
function locally_optimize!(
        ::LoBuffers, lo::Gnc{<:Irls}, problem::LiftableProblem, model,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    # c̄² = scale_multiple²·ŝ², deployed as a (scale_multiple, ŝ²) pair.
    loss = lo_loss(lo, cs, scoring, buf)   # GNC: the target width multiple; ŝ² floored at eps() (VGC `loss_at`)
    prov = rows_provider(problem)
    n = lift_size(prov)
    method = ManifoldLiftGnc(prov, n, loss)
    θ₀ = lift_init(prov, model)
    lift_refresh!(prov, θ₀)
    res = lift_residuals(prov); valid = lift_valid(prov)
    r2max = 0.0
    @inbounds for i in 1:n
        valid !== nothing && !valid[i] && continue
        r2max = max(r2max, res[i]^2)
    end
    μ0 = gnc_entry_mu0(loss, r2max, lo.entry)
    sched = with_converged_rung(gnc_schedule(loss, lo.factor), lo.budget === :converged)
    st = schedule_init(sched, μ0, lo.max_iter)
    cost0 = lift_cost(loss, res, n)
    state = reused_state(ManifoldLiftGncState{typeof(θ₀)}, (θ₀, cost0, Incumbent(θ₀, cost0), Inf, st, 0, false))
    return block_coordinate_descent!(state, FixedWelschScale(), method, problem, model; max_iter = lo.max_iter)
end
