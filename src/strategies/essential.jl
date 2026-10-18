# =============================================================================
# The essential-matrix research local optimizations — the Welsch convexified
# Newton and ECM lifts, and the Student-t + uniform mixture lift and its ReGeMM
# baseline (moved from VisualGeometryToolkitEstimation's problems/essential.jl). They run
# on E's chart-rows provider.
# =============================================================================

# =============================================================================
# Scale policies of the joint-(θ,z) loss lift (ManifoldLiftHQ)
# =============================================================================
#
# HQ{K}, BarronHQ, GmHqEps and Gnc{Irls{K}} on E run on the generic provider
# (lift/lifts.jl) like every chart problem. The two Welsch
# research arms below differ from HQ{WelschShape} only in the z-block
# (WelschHQNewton) or in the SCALE MODEL — the likelihood type
# `update_nuisance!` dispatches on (WelschHQEcm).

# Fixed scale (all closed-form loss arms): trivial likelihood, the loss stays
# at the seed deployment.
struct FixedWelschScale <: AbstractWeightPolicy end
update_nuisance!(::FixedWelschScale) = nothing
update_weights!(::FixedWelschScale) = nothing

# Welsch-CONSISTENT ECM (WelschHQEcm): the Welsch loss is not Gaussian and
# not Student-t (Gaussian core, redescending tails), so the scale is re-estimated
# from the loss's OWN weight ω(r) = e^{−r²/loss_width²} (VGC `lift_weight`) — NOT a
# Gaussian variance or the t latent precision: ŝ² = Σωᵢrᵢ²/Σωᵢ, the
# redescending-weighted second moment, as RSDR's `fit_scale` under the Jeffreys
# prior (rss = Σωr², dof = Σω); the loss width is then scale_multiple·√ŝ² at the
# same `scale_multiple`.
#
# INCUMBENT COMPARABILITY (D2 fix, 2026-07-14): under ECM the per-iteration
# tracked cost `lift_cost(state.loss, r, n)` is evaluated at a MOVING scale
# — Welsch lift_cost is monotone-increasing in the loss width at fixed residuals, so the
# `post_iteration!` comparison mixed values from different objectives (iterations
# after a scale shrink got an automatic discount, after a growth a penalty,
# independent of pose quality; the "best" was not the argmin of any single
# objective). Fix: the likelihood RECORDS every visited chart (`traj`, pushed by
# update_nuisance! before it moves the width) and `locally_optimize!` re-scores seed +
# trajectory at the FINAL converged loss width, returning the argmin of that one
# fixed objective (`_ecm_final_scale_incumbent`). The moving-objective
# `post_iteration!` incumbent is DISCARDED for the ECM arm; the fixed-scale arms
# (FixedWelschScale) are untouched (their tracked objective never moves). Cost:
# ≤ max_iter extra residual evaluations at selection time.
struct WelschEcmScale{St, Prov, M} <: AbstractWeightPolicy
    state::St; prov::Prov
    traj::Vector{M}          # visited iterates (the D2 candidate store)
end
WelschEcmScale(state, prov) = WelschEcmScale(state, prov, typeof(state.θ)[])
function update_nuisance!(lh::WelschEcmScale)
    s = lh.state; res = lift_residuals(lh.prov); n = lift_size(lh.prov)
    push!(lh.traj, s.θ)                              # record the iterate BEFORE the scale moves
    sωr2 = 0.0; sω = 0.0
    @inbounds for i in 1:n
        ri = res[i]; ω = lift_weight(s.loss, ri * ri)    # the loss's own IRLS weight
        sωr2 += weighted_sq(ω, ri * ri); sω += ω         # RSDR's `weighted_rss` term: 0·Inf guarded
    end
    # A new noise VARIANCE at the same scale multiple: `rescale` replaces the
    # one slot. No weight at all (every point beyond the loss) holds the scale.
    sω > 0 && (s.loss = rescale(s.loss, fit_scale(JeffreysPrior(), sωr2, sω)))
    return nothing
end
update_weights!(::WelschEcmScale) = nothing          # closed-form Welsch: no table
current_s2(lh::WelschEcmScale) = scale_s2(lh.state.loss)   # the ECM scale (VGC `Recorded`)

# Convexified-Newton lift (Zach & Bourmaud 2018): same fixed-scale setup as the GN
# HQ{WelschShape}, but the joint system's z-block is the convexified Newton one
# (VGC `WelschConvexNewton`). A/B partner for the GN lift in the LO ablation.
function locally_optimize!(
        ::LoBuffers, lo::WelschHQNewton, problem::EssentialProblem, model::EssentialMat,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    loss = loss_at(lo, WelschShape(), cs, scoring, buf)
    return _manifold_hq!(problem, model, loss, lo.μ, :flat, lo.max_iter; zblock = WelschConvexNewton())
end

# D2 selector: re-score seed + every visited iterate under ONE fixed objective
# — the lift cost at the FINAL converged loss — and return its argmin.
# Reuses the provider's residual buffer; ≤ (max_iter + 1) residual evaluations.
function _ecm_final_scale_incumbent(prov, θ₀, traj::Vector, final_loss::DeployedLoss)
    cost(θ) = (lift_refresh!(prov, θ); lift_cost(final_loss, lift_residuals(prov), lift_size(prov)))
    inc = Incumbent(θ₀, Float64(cost(θ₀)))
    for θ in traj
        inc, _ = keep_best(inc, θ, cost(θ))
    end
    return inc.θ
end

function locally_optimize!(
        ::LoBuffers, lo::WelschHQEcm, problem::EssentialProblem, model::EssentialMat,
        cs::ConsensusSet, ::ScoreBuffers, _scoring
    )
    # Self-scaling: the consensus scale is the ECM's initial ŝ² (floored at eps).
    loss = deploy(WelschShape(), max(scale_s2(cs), eps()); scale_multiple = lo.scale_multiple)
    prov = rows_provider(problem)
    method = ManifoldLiftHQ(prov, lift_size(prov), loss, lo.μ)
    θ₀ = lift_init(prov, model)                  # the seed (included in the candidate set)
    state = _init_manifold_hq(method, θ₀, :flat)
    lh = WelschEcmScale(state, prov)
    res = block_coordinate_descent!(state, lh, method, problem, model; max_iter = lo.max_iter)
    # D2: the ECM run's incumbent is selected at the FINAL converged scale —
    # one fixed objective for every candidate (see WelschEcmScale header).
    best = _ecm_final_scale_incumbent(prov, θ₀, lh.traj, state.loss)
    return lo_estimate(lift_model(prov, best), retcode(res); iterations = iterations(res))
end

# =============================================================================
# The Student-t + uniform mixture — ECM, table and objective (shared by the
# joint lift StuTuHQTabulated and the ReGeMM baseline StuTuRegemm)
# =============================================================================
#
# The mixture is VisualGeometryToolkitCore's: `PosteriorWeightState` holds (ν, ŝ²,
# π) and the E-step buffers, `StudentTMixture` its scalar formulas. The ECM on
# (ŝ², π) at fixed ν is the toolkit's three M-step blocks in order — E-step
# (`update_weights!`), ŝ² (`update_scale!`, the latent-precision-weighted ECM
# scale under the Jeffreys prior), π (`update_inlier_prior!`). EM, so each update
# is monotone in the mixture NLL. The half-quadratic conjugate κ² of the mixture
# weight has no closed form; it is VGC's `TabulatedLift`, re-tabulated from the
# mixture's weight and slope after every ECM update.

# The state (`PosteriorWeightState(n; ν, s_hat_sq, log_two_outlier_halfwidth, codimension,
# inlier_prior)` — Jeffreys, π clamped by the toolkit's one clamp), the ECM cycle
# (`mixture_ecm!`), the NLL (`mixture_nll(pws, r, n)`) and the κ² table
# (`tabulate!(tab, StudentTMixture(pws))`) are all VisualGeometryToolkitCore's; nothing of the
# mixture's math is restated here.

# The setup both mixture arms' dispatch shares: E's lift provider and a fresh ECM
# state at the consensus set's (ν, ŝ², π), from the one posterior seeding
# (VisualGeometryToolkitEstimation's `consensus_posterior`).
function _mixture_lift_setup(L::LoBuffers, problem::EssentialProblem, model, cs::ConsensusSet, buf::ScoreBuffers, scoring)
    n = data_size(problem)
    a = required_outlier_halfwidth(scoring)
    rws = consensus_posterior(L, problem, cs, buf, scoring, a)
    prov = rows_provider(problem)
    # The ECM state at the seed's (ν, ŝ², π), on the workspace's posterior
    # state itself (the seed is read first; VGC's `reset_posterior!`, the
    # in-place `PosteriorWeightState(n; …)`: buffers written before read).
    pws = reset_posterior!(
        rws; ν = student_t_dof(rws), s_hat_sq = s_hat_sq(rws),
        log_two_outlier_halfwidth = log(2 * a),
        codimension = codimension(problem), inlier_prior = inlier_count(cs) / n
    )
    return prov, pws
end

# The seed both mixture arms' init shares: residuals at θ₀ and their mixture NLL
# (the returned seed level), then the first ECM from those residuals and the κ²
# table at its parameters — the table the first `update_model!` reads (the only
# consequence of `block_coordinate_descent!`'s solve-before-scale ordering,
# absorbed here).
function _seed_mixture!(prov, pws::PosteriorWeightState, tab::TabulatedLift, θ₀, n::Int)
    lift_refresh!(prov, θ₀)
    seed_nll = mixture_nll(pws, lift_residuals(prov), n)
    mixture_ecm!(pws, lift_residuals(prov), n)
    tabulate!(tab, StudentTMixture(pws))
    return seed_nll
end

# =============================================================================
# StuTuHQTabulated — half-quadratic lifted LO for the t+uniform mixture loss
# =============================================================================
#
# Refines E by minimizing the Student-t + uniform mixture negative log-likelihood
#   L(θ, ŝ², π) = −Σᵢ log[ π·t_ν(rᵢ; ŝ²) + (1−π)·(2a)^{−d} ]
# over the relative pose θ (rᵢ = signed Sampson residual). This is block-
# coordinate descent on the ONE objective L:
#
#   • (ŝ², π) block — ECM (RSDR, above).
#   • θ block — the genuine joint-(θ,z) half-quadratic LIFT: each residual gets a
#     free lifting weight zᵢ (z̄² = w̄ ∈ (0,1], LARGE-init = all-inlier) evolved
#     *jointly* with θ by an **undamped** Gauss-Newton step, Schur-eliminating Δz
#     — VGC's codim-1 lift core with the tabulated conjugate as its loss, on
#     E's lift provider. The Schur coupling broadens the basin of attraction so
#     the step crosses from a poor RANSAC seed into the global basin — the part
#     that escapes where the basic IRLS is trapped.
#
# Globalization is on the TRUE objective L (not the per-slice half-quadratic
# surrogate, which moves as ECM re-estimates ŝ²/π): we **best-track** the lowest-L
# iterate and **cap at the seed L** — if a joint-GN step pushes L above its value
# at the seed pose, the iteration has left the basin, so we stop and return the
# incumbent. Empirically the cap fires on ≈0 of trajectories; the undamped step is
# essential (any LM damping monotonically degrades the result — it shrinks the
# very basin-crossing step toward local descent).
#
# `γ` is the lifting-regularizer strength (the table's) — a GNC-style continuation
# hyperparameter that scales the down-weighting penalty κ². γ>1 makes the lift more
# reluctant to switch points off (softer z-block Hessian, hreg ∝ 1/γ), keeping it in
# a smoother, wider-basin regime → better escape from a poor seed. Best-tracking is
# always on the TRUE (γ=1) objective, so γ shapes only the exploration, never the
# returned model — which is why a constant (validated) γ beats an anneal-to-1
# schedule.
#
# As an `AbstractBlockCoordinateMethod`: the joint step is `update_model!`; the ECM
# (ŝ²,π) is the likelihood's `update_nuisance!`; the κ² re-tabulation is
# `update_weights!` (the regularizer the next solve consumes); best-tracking is
# `post_iteration!`; the non-monotone, patience-tolerant stop is its
# `stopping_criterion`.
# The z's are solver-internal state, co-optimized inside `update_model!`.
struct LiftedMixtureMethod{Prov, S <: LiftState} <: JointLiftMethod
    prov::Prov
    n::Int
    μ::Float64; patience::Int
    table::TabulatedLift            # the κ² table (γ inside)
    pws::PosteriorWeightState       # the ECM state: ν (fixed), ŝ², π and E-step buffers
    ls::S                           # the lift's own state (z and the reduced system)
end
LiftedMixtureMethod(prov, n::Int, μ::Float64, patience::Int, table::TabulatedLift, pws::PosteriorWeightState) =
    LiftedMixtureMethod(prov, n, μ, patience, table, pws, provider_lift_state(prov))

# `cur_cost` is the TRUE mixture NLL at `θ`; `seed_nll` the leave-basin cap.
mutable struct LiftedMixtureState{M}
    θ::M
    seed_nll::Float64; cur_cost::Float64
    best::Incumbent{M}
    no_improve::Int; built::Bool; Δθnorm::Float64
end

struct LiftedMixtureLikelihood{St, Me} <: NormalizedWeightPolicy
    state::St; method::Me
end

# The table at the current ECM parameters, warm-started off the previous one
# once one exists.
function _mixture_tabulate!(state::LiftedMixtureState, method::LiftedMixtureMethod)
    tabulate!(method.table, StudentTMixture(method.pws); warm = state.built)
    state.built = true
    return nothing
end

# The seed state (`_init_lifted_mixture`): the flat z₀ (VGC's), then the shared mixture seed — the
# seed-NLL cap level and the FIRST ECM + table from the seed residuals.
function _init_lifted_mixture(method::LiftedMixtureMethod, θ₀)
    prov = method.prov; n = method.n
    _seed_lift_z!(method.ls, method.table, lift_residuals(prov), n, :flat)
    seed_nll = _seed_mixture!(prov, method.pws, method.table, θ₀, n)
    return reused_state(LiftedMixtureState{typeof(θ₀)}, (θ₀, seed_nll, seed_nll, Incumbent(θ₀, seed_nll), 0, true, Inf))
end

# The model block is THE joint-(θ,z) lift update (`update_model!` on
# `JointLiftMethod`, lift/lifts.jl): one undamped joint
# Gauss-Newton move, Δz Schur-eliminated, with the κ² table as the loss (its
# z-block and its w̄ window) under the plain Gauss-Newton z-block.
_lift_loss(_state, method::LiftedMixtureMethod) = method.table
_lift_zblock(::LiftedMixtureMethod) = JointGaussNewton()

# Likelihood (scale/weight model): ECM scale (`update_nuisance!`, shared with
# ReGeMM below), then the κ² regularizer table.
update_weights!(lh::LiftedMixtureLikelihood) = _mixture_tabulate!(lh.state, lh.method)

# Best-track the incumbent on ANY drop in the true objective; count flat iters.
function post_iteration!(state::LiftedMixtureState, method::LiftedMixtureMethod, prob, θ, iter)
    state.no_improve = _track_incumbent!(state) ? 0 : state.no_improve + 1
    return nothing
end

# Non-monotone, patience-tolerant termination (the lift's stopping criterion):
# leave-basin cap, then stop once the objective stops improving for `patience`
# iters (patience=1 ⇒ the monotone rule), then the step-norm floor.
"""
    StopWhenLeftBasin()

`:left_basin` once the true objective at the current iterate exceeds the seed's
(`state.cur_cost > state.seed_nll`): the step left the seed basin.
"""
struct StopWhenLeftBasin <: StoppingCriterion end
@inline stop_reason(::StopWhenLeftBasin, state, method, prob, θ, θ_old, iter) =
    state.cur_cost > state.seed_nll ? :left_basin : :continue
@inline VgtkEstimation.iterations_without_improvement(state::LiftedMixtureState) = state.no_improve
stopping_criterion(method::LiftedMixtureMethod) =
    StopWhenLeftBasin() | StopWhenNoImprovement(method.patience, 2) | StopWhenIncrementSmall()
current_cost(state::LiftedMixtureState) = state.cur_cost

# RANSAC LO dispatch — EssentialProblem specialization (VisualGeometryToolkitCore's
# contract refuses other problem types). Builds the seed partition's posterior
# state for the data-driven scale ŝ² and ν, then runs `block_coordinate_descent!`.
function locally_optimize!(
        L::LoBuffers, lo::StuTuHQTabulated, problem::EssentialProblem,
        model::EssentialMat, cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    prov, pws = _mixture_lift_setup(L, problem, model, cs, buf, scoring)
    n = lift_size(prov)
    method = LiftedMixtureMethod(prov, n, lo.μ, lo.patience, tabulated_lift(lo.lut_points; γ = lo.γ), pws)
    state = _init_lifted_mixture(method, lift_init(prov, model))
    lh = LiftedMixtureLikelihood(state, method)
    return block_coordinate_descent!(state, lh, method, problem, model; max_iter = lo.max_iter)
end

# =============================================================================
# StuTuRegemm — ReGeMM (Zach & Le, ECCV 2020, §6.1) for the mixture loss
# =============================================================================
#
# The monotone, convergent counterpart of the joint lift, following the
# robust-estimation scheme of Zach & Le §6.1. Same mixture objective `L` and `κ²`
# table, but instead of one coupled (θ,z) Newton step it ALTERNATES, inferring the
# latent weights only inexactly via graduated non-convexity from the smooth init:
#   • initialize the weights all-inlier (u≡1, the smooth/convex end);
#   • each round set u_i = ω(r_i/σ) — the touching weight at an INFLATED scale σ≥1
#     (σ large ⇒ smooth/high weights, σ=1 ⇒ exact touching), with σ chosen by
#     bisection as the largest value still meeting the diminishing-gap criterion
#     J(θ,uⁿᵉʷ) ≤ η·J(θ) + (1−η)·J(θ,uᵒˡᵈ),  with J(θ)=minₚ J(θ,u)=lifted@touching;
#   • then minimize the lifted bound over the pose for the graduated weights —
#     the weighted-Sampson refit `refine!` (Alg. 1, line 3's argmin).
# σ anneals toward 1 as the gap tightens, so this is weight-space GNC run from the
# *smooth* init — the inflated-scale weights keep the early θ-updates from fitting
# outliers, which is why no residual/touching init is needed. `EssentialProblem`
# only. (Zach & Le report this favorable vs the joint HQ lift on bundle adjustment
# with a truncated-quadratic loss; on 2-view essential the joint lift is better.)

# One point's lifted upper-bound term ½(w·r² + κ²(w)) — the summand of every
# ReGeMM cost below.
@inline _mix_lifted_term(tab::TabulatedLift, w, r2) = 0.5 * (w * r2 + lift_conjugate(tab, w))

# The touching weight at the inflated scale σ (σ² = 1: exact touching), clamped
# to the table's raw-weight window.
@inline _touching_weight(m::StudentTMixture, r2, σ2, wlo, whi) =
    clamp(posterior_weight(m, r2 / σ2), wlo, whi)

# Lifted upper-bound cost ½Σ(wᵢrᵢ² + κ²(wᵢ)) — the ReGeMM `J(θ,w)`.
function _mix_lifted_cost(r, w, tab::TabulatedLift, n::Int)
    c = 0.0
    @inbounds for i in 1:n
        c += _mix_lifted_term(tab, w[i], r[i]^2)
    end
    return c
end

# The same cost at the touching weights of scale σ² — `J(θ) = min_w J(θ, w)`
# at σ² = 1, the graduated bound above it.
function _mix_touching_cost(r, m::StudentTMixture, tab::TabulatedLift, n::Int, σ2, wlo, whi)
    c = 0.0
    @inbounds for i in 1:n
        c += _mix_lifted_term(tab, _touching_weight(m, r[i]^2, σ2, wlo, whi), r[i]^2)
    end
    return c
end

# ReGeMM as an `AbstractBlockCoordinateMethod` — the monotone, alternating
# baseline: `update_model!` is one σ-graduation (bisection to the diminishing-gap σ)
# + the pose refit for the graduated weights; the ECM (ŝ²,π) is the likelihood's
# `update_nuisance!`, the κ² re-tabulation its `update_weights!`. Weights `w`
# persist across rounds (u⁽⁰⁾=1 smooth init). Runs the full round budget
# (no stopping criterion of its own: VGC's default `StopNever`), best-tracking
# the true mixture NLL.
struct LiftedReGeMMMethod{Prov} <: AbstractLiftMethod
    prov::Prov
    n::Int
    η::Float64
    adapt_scale::Bool
    table::TabulatedLift
    pws::PosteriorWeightState       # the ECM state: ν (fixed), ŝ², π and E-step buffers
    w::Vector{Float64}              # the graduated weights (length n)
end

# `cur_cost` is the TRUE mixture NLL at `θ`, the best-tracked objective.
mutable struct LiftedReGeMMState{M}
    θ::M
    cur_cost::Float64
    best::Incumbent{M}
end

struct LiftedReGeMMLikelihood{St, Me} <: NormalizedWeightPolicy
    state::St; method::Me
end

# Both mixture arms: the TRUE mixture NLL is the tracked objective (the
# residuals block, `update_residuals!` on `AbstractLiftMethod`), and the ECM on
# (ŝ², π) from the current residuals is the nuisance block — unless the ReGeMM
# arm freezes the scale (the fixed-scale consistent refiner).
const _MixtureLiftMethod = Union{LiftedMixtureMethod, LiftedReGeMMMethod}
_lift_objective(_state, method::_MixtureLiftMethod, r) = mixture_nll(method.pws, r, method.n)
_adapts_scale(::LiftedMixtureMethod) = true
_adapts_scale(method::LiftedReGeMMMethod) = method.adapt_scale
function update_nuisance!(lh::Union{LiftedMixtureLikelihood, LiftedReGeMMLikelihood})
    m = lh.method
    _adapts_scale(m) && mixture_ecm!(m.pws, lift_residuals(m.prov), m.n)
    return nothing
end
update_weights!(lh::LiftedReGeMMLikelihood) = (tabulate!(lh.method.table, StudentTMixture(lh.method.pws)); nothing)
current_s2(lh::Union{LiftedMixtureLikelihood, LiftedReGeMMLikelihood}) = s_hat_sq(lh.method.pws)   # the ECM ŝ² (VGC `Recorded`)

function _init_lifted_regemm(method::LiftedReGeMMMethod, θ₀)
    prov = method.prov; n = method.n; pws = method.pws; tab = method.table
    # u⁽⁰⁾ = 1 (smooth/all-inlier): the top of the seed-parameter table.
    tabulate!(tab, StudentTMixture(pws))
    whi = last(lift_raw_window(tab))
    @inbounds for i in 1:n
        method.w[i] = whi
    end
    # The shared mixture seed (faithful to the standalone round-1 ordering).
    seed_nll = _seed_mixture!(prov, pws, tab, θ₀, n)
    return reused_state(LiftedReGeMMState{typeof(θ₀)}, (θ₀, seed_nll, Incumbent(θ₀, seed_nll)))
end

function update_model!(state::LiftedReGeMMState, method::LiftedReGeMMMethod, prob, θ)
    prov = method.prov; n = method.n; η = method.η; tab = method.table
    r = lift_residuals(prov); w = method.w
    m = StudentTMixture(method.pws)
    wlo, whi = lift_raw_window(tab)
    @inbounds for i in 1:n
        w[i] = clamp(w[i], wlo, whi)
    end
    # Gap targets: J(θ) = lifted@touching (σ=1), J(θ,wᵒˡᵈ) = current upper bound.
    Lo = _mix_touching_cost(r, m, tab, n, 1.0, wlo, whi)
    Uprev = _mix_lifted_cost(r, w, tab, n)
    target = η * Lo + (1 - η) * Uprev
    σlo, σhi = 1.0, 1.0e8                              # bisect the largest σ meeting the gap
    for _ in 1:40
        σm = sqrt(σlo * σhi)
        (_mix_touching_cost(r, m, tab, n, σm * σm, wlo, whi) <= target) ? (σlo = σm) : (σhi = σm)
    end
    σ2 = σlo * σlo
    @inbounds for i in 1:n
        w[i] = _touching_weight(m, r[i]^2, σ2, wlo, whi)
    end
    # Pose update: the weighted-Sampson refit minimizes the new bound J̄(·, u⁽ᵗ⁾)
    # over the pose — Alg. 1's line-3 argmin (Prop. 1's telescoping needs
    # J̄(θₜ,uₜ) ≤ J̄(θₜ₋₁,uₜ)). DESCENT acceptance is still checked, and a refit
    # that does not descend (or fails) leaves the pose; the weights still advance
    # the graduation. `r` is scratch after this point — the driver's
    # update_residuals! recomputes it from the accepted state.
    Jw_before = _mix_lifted_cost(r, w, tab, n)
    E = refine!(nothing, prob, lift_model(prov, state.θ), w)   # the chart-LM refit's own workspace policy
    if E !== nothing
        θn = lift_init(prov, E)
        lift_refresh!(prov, θn)
        _mix_lifted_cost(r, w, tab, n) <= Jw_before + 1.0e-12 * abs(Jw_before) && (state.θ = θn)
    end
    return lift_model(prov, state.θ)
end

current_cost(state::LiftedReGeMMState) = state.cur_cost

# RANSAC LO dispatch — ReGeMM baseline.
function locally_optimize!(
        L::LoBuffers, lo::StuTuRegemm, problem::EssentialProblem,
        model::EssentialMat, cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    prov, pws = _mixture_lift_setup(L, problem, model, cs, buf, scoring)
    n = lift_size(prov)
    method = LiftedReGeMMMethod(
        prov, n, lo.η, lo.adapt_scale, tabulated_lift(lo.lut_points), pws,
        task_buffers(Vector{Float64}, () -> Vector{Float64}(undef, n), (:lodr_regemm_scratch, n))
    )
    state = _init_lifted_regemm(method, lift_init(prov, model))
    lh = LiftedReGeMMLikelihood(state, method)
    return block_coordinate_descent!(state, lh, method, problem, model; max_iter = lo.max_iter)
end
