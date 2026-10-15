# =============================================================================
# labels.jl — THE paper's SELECTION label vocabulary (single source; see
# PROTOCOL.md §9).
#
# One selector = one label (with its citation); a composed pipeline is
# `SEL_SHORT[sel] * "+" * <LO label>`, the LO named by its strategy's
# `lo_label` trait and cited from the arm table (arm_rosters.jl
# `composed_label`) — so LO labels have one owner, the strategy, and no table
# here. Every renderer consumes these tables, never a locally spelled string.
# The score is named for the MIXTURE, consistently with the family convention
# (GaU = Gaussian+Uniform): Stu-$t$U = the Student-t/uniform mixture marginal.
# =============================================================================

const SEL_LABEL = Dict(
    :ig     => raw"Stu-$t$U~\cite{PrittsScoring2026}",
    :msac   => raw"MSAC~\cite{Torr1998}",
    :oracle => "Oracle (GT-best)",
)

# Short selector forms used in COMPOSITION (the score's cite and the -marg
# qualifier stay on selection-only entries; composed arms read "Stu-$t$+X").
const SEL_SHORT = Dict(:ig => raw"Stu-$t$U", :msac => "MSAC", :oracle => "Oracle")

"""
    arm_label(sel::Symbol) -> String

The selection-only label of selector `sel` (with its citation). Composed
labels come from `composed_label` (arm_rosters.jl).
"""
arm_label(sel::Symbol) = SEL_LABEL[sel]
