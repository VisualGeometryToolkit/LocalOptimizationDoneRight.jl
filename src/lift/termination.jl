# =============================================================================
# termination.jl — the termination record of this package's local optimizers
# (VisualGeometryToolkitCore's §14 record: a ReturnCode and the StopRule that fired).
#
# A block-coordinate loop reports the Symbol its stopping criterion returned; the
# record states which RULE that was. A success Symbol (`:converged`) names no rule,
# so each of this package's criteria states its own (`success_rule`). A composite
# criterion (StopWhenAny) is resolved the way Core chose its reason: the first
# member, in order, that fires at the final state. The two exits that are not a
# Symbol of the iterative-fit vocabulary are stated directly: `:left_basin` (the
# arm stopped on its own safeguard and returns the INCUMBENT, so `Terminated`,
# a success; the owner's rulings of 2026-11-11), and Core's loop exits
# (`:max_iterations`, `:solve_failed`) map through `retcode_from_symbol`.
# =============================================================================

"""
    success_rule(criterion) -> StopRule

The [`StopRule`](@ref VisualGeometryToolkitCore.StopRule) a stopping criterion
fires when it reports success (`:converged`): the HQ lifts' increment floor, the
GNC ladder's terminal rung, the no-improvement patience. A criterion that never
reports success (Core's `StopNever`, the iteration cap) has `NoRule`.
"""
success_rule(::StoppingCriterion) = NoRule
success_rule(::StopWhenIncrementSmall) = IncrementSize
success_rule(::StopWhenLadderConverged) = LadderConverged
success_rule(::StopWhenNoImprovement) = NoImprovement

# The member of a composite criterion that fired: the first, in Core's order, whose
# reason at the final state is the reported one.
_fired_rule(c::StoppingCriterion, reason, state, method, prob, θ, iter) = success_rule(c)
function _fired_rule(c::StopWhenAny, reason, state, method, prob, θ, iter)
    for m in c.criteria
        stop_reason(m, state, method, prob, θ, θ, iter) === reason && return _fired_rule(m, reason, state, method, prob, θ, iter)
    end
    return NoRule
end

"""
    lo_termination(reason, criterion, state, method, prob, θ, iter) -> (ReturnCode.T, StopRule)

The termination record of a run of `block_coordinate_descent!` that ended with
`reason` under `criterion` (the method's `stopping_criterion`).
"""
function lo_termination(reason::Symbol, criterion, state, method, prob, θ, iter)
    reason === :left_basin && return (ReturnCode.Terminated, LeftBasin)
    return retcode_from_symbol(reason, _fired_rule(criterion, reason, state, method, prob, θ, iter))
end
