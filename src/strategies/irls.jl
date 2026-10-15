# =============================================================================
# The posterior-weight IRLS arms — the Student-t + uniform IRLS and the
# Barron-adaptive IRLS — on RobustVisualGeometry's posterior-weight iteration
# (`posterior_irls!`), and the score-matched block-coordinate ascent StuTuBCD.
# =============================================================================

"""
    locally_optimize!(L, lo::StudentTUniform, problem, model, cs, buf, scoring) -> FitResult

The paper's Stu-tU-IRLS: the posterior-weight iteration under the Student-t +
uniform posterior (RobustVisualGeometry's `PosteriorLikelihood`),
self-scaling, seeded from the consensus set `cs`. It needs the scorer's
uniform outlier model (`outlier_halfwidth`).
"""
function locally_optimize!(
        L::LoBuffers, lo::StudentTUniform, problem, model,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    return posterior_irls!(PosteriorLikelihood, L, problem, model, cs, buf, scoring,
                           required_outlier_halfwidth(scoring); max_iter = lo.max_iter)
end

"""
    locally_optimize!(L, lo::BarronAdaptive, problem, model, cs, buf, scoring) -> FitResult

Barron weights at the frozen loss width its mode resolves to, the shape α
re-fit each iteration ([`BarronAdaptiveLikelihood`](@ref)), on the
posterior-weight iteration. The frozen weights replace the posterior seed's
before the first solve, so any finite outlier model serves when the scorer has
none.
"""
function locally_optimize!(
        L::LoBuffers, lo::BarronAdaptive, problem, model,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    )
    # A genuine (scale_multiple, ŝ²) pair kept apart until the one
    # multiplication that needs them both; what lands in the likelihood is a
    # squared WIDTH. Only the SHAPE α moves in this arm.
    width2 = _barron_sq_width(lo, cs, scoring, buf)
    return posterior_irls!(L, problem, model, cs, buf, scoring, something(outlier_halfwidth(scoring), 1.0);
                           max_iter = lo.max_iter) do rws, n
        BarronAdaptiveLikelihood(rws, n, width2, lo.α_min, lo.truncation_multiple, lo.n_sub)
    end
end

# =============================================================================
# StuTuBCD — Block-coordinate ascent on the score itself
# =============================================================================
"""
    locally_optimize!(L, lo::StuTuBCD, problem, model, cs, buf, scoring) -> FitResult

Exact same-objective local optimization: block-coordinate ascent on the score
S. Alternates a hard-inlier least-squares **model step** (weights = the current
consensus mask, so the M-step minimizes `RSS_I` and thereby raises S with all
other score terms fixed) with a **partition step** that re-runs the scorer
(`score_model!`) at the refit pose (the exact `argmax_I S`). Both steps are
non-decreasing in S; the loop stops as soon as a score fails to improve the
incumbent by more than `lo.tol`. The buffers are left reflecting the last score
— Phase 3 re-scores the returned model from a clean score.
"""
function locally_optimize!(
        L::LoBuffers, lo::StuTuBCD, problem, model::M,
        cs::ConsensusSet, buf::ScoreBuffers, scoring
    ) where {M}
    # The incumbent score: the evaluation `cs` came from (VGC
    # `consensus_score`; K+ O7) — the buffers hold its mask and residuals for
    # the first model block. In the RANSAC loop that is Phase 1's score, whose
    # minimal-sample points score as exact fits. Re-scored only when `cs`
    # carries none or the scorer is predictive (its Phase-1 score is of the
    # model WITH a covariance, not of `model`); the re-score bumps the epoch,
    # retiring `cs` (unused past this point — the mask is read).
    score = _bcd_seed_score(buf, scoring, problem, model, cs)
    method = ScoreBcdMethod(scoring, L, buf, lo.tol)
    state = reused_state(ScoreBcdState{M}, (Incumbent{M}(model, -Float64(score)), -Float64(score), false))
    return block_coordinate_descent!(state, FixedWelschScale(), method, problem, model; max_iter = lo.max_iter)
end

function _bcd_seed_score(buf, scoring, problem, model, cs::ConsensusSet)
    s = consensus_score(cs)
    (isnan(s) || is_predictive(scoring)) || return s
    score, _ = score_model!(buf, scoring, problem, model)
    return score
end

# StuTuBCD on VGC's loop. The model block is the hard-inlier least squares on
# the current consensus set (weights = the last score's 0/1 mask, in the n-sized
# posterior scratch); the residuals block is the scorer itself at the refit,
# which also moves the set. The incumbent carries the NEGATED score, so ascent
# on S is descent on its cost. A failed refit (underdetermined set, singular
# normal equations) is the loop's `:solve_failed` exit and keeps the incumbent.
struct ScoreBcdMethod{S, L <: LoBuffers, B <: ScoreBuffers} <: AbstractBlockCoordinateMethod
    scoring::S
    lo_ws::L
    buf::B
    tol::Float64     # the minimum score gain an iteration must make
end

mutable struct ScoreBcdState{M}
    best::Incumbent{M}   # cost = −S
    cur_cost::Float64    # −S at the last refit
    improved::Bool       # the last iteration raised S by more than `tol`
end

function update_model!(::ScoreBcdState, method::ScoreBcdMethod, problem, θ)
    buf = method.buf; w = method.lo_ws.posterior_w
    @inbounds for i in 1:data_size(problem)
        w[i] = buf.mask[i] ? 1.0 : 0.0
    end
    return refine!(method.lo_ws.refine, problem, θ, w)
end

function update_residuals!(state::ScoreBcdState, method::ScoreBcdMethod, problem, θ)
    score, _ = score_model!(method.buf, method.scoring, problem, θ)
    state.cur_cost = -Float64(score)
    return nothing
end

# The incumbent moves only on a gain of more than `tol`, and that gain is the
# stop verdict: an iteration that does not make it ends the run.
function post_iteration!(state::ScoreBcdState{M}, method::ScoreBcdMethod, prob, θ, iter) where {M}
    state.improved = state.cur_cost < state.best.cost - method.tol
    state.improved && (state.best = Incumbent{M}(θ, state.cur_cost))
    return nothing
end

stopping_criterion(::ScoreBcdMethod) = StopWhenNoImprovement(1, 1)
current_cost(state::ScoreBcdState) = state.cur_cost

block_coordinate_result(state::ScoreBcdState, ::ScoreBcdMethod, prob, θ, stop_reason, final_iter) =
    lo_estimate(state.best.θ, stop_reason; iterations = final_iter)
