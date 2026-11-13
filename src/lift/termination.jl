# =============================================================================
# termination.jl — the termination record of this package's local optimizers
# (VisualGeometryToolkitCore's §14 record: a ReturnCode and the StopRule that fired).
#
# The rule is Core's: `block_coordinate_descent!` hands `block_coordinate_result` the
# `stop_rule(criterion, method)` of the criterion that FIRED (a composite's member, in
# Core's order). Each criterion this package defines states its rule beside its
# definition (lifts.jl, essential.jl), and its methods state the rule of Estimation's
# `StopWhenNoImprovement` when they run it (irls.jl, essential.jl). Here only the
# ReturnCode: `:left_basin` (the arm stopped on its own safeguard and returns the
# INCUMBENT, so `Terminated`, a success; the owner's rulings of 2026-11-11), every
# other Symbol of the iterative-fit vocabulary through Core's `retcode_from_symbol`.
# =============================================================================

"""
    lo_termination(reason::Symbol, rule) -> (ReturnCode.T, StopRule)

The termination record of a run of `block_coordinate_descent!` that ended with
`reason`, under the `rule` Core resolved for the criterion that fired.
"""
lo_termination(reason::Symbol, rule) =
    reason === :left_basin ? (ReturnCode.Terminated, rule) : retcode_from_symbol(reason, rule)
