# =============================================================================
# src/arm_rosters.jl — THE paper's arm table and the rosters drawn from it
# (the ComposedSpec/SoloSpec/Roster types, the refit layer and the deployed_*
# sidecar readers live in the composition evaluator, VisualGeometryEval.Evaluation;
# the tuning is scripts/tools/run_sequential_cv.jl).
#
# ONE table, `ARM_TABLE`: every arm the paper runs, keyed by its registry key
# ("IG  +Lift"), with its strategy constructor, its width parameterization and every name
# another layer gives it — the timing run tag and column (time_lo_supp.jl). The
# relative-pose rosters (`composed_specs`, `solo_specs`, `basin_specs`), the
# timing roster (`TIMING_TAGS`) and the figure vocabulary (figure_style.jl)
# are all DERIVED from it, so no layer spells a constructor or a name of its own.
#
# Loaded by config.jl. `ROSTER` hands the rosters to the engine's readers
# (deployed_budget_settings / deployed_arm_settings / deployed_basin_settings /
# audit_operating_points), so they rebuild arms from this ONE table.
# =============================================================================

using RobustVisualGeometry: Irls
using LocalOptimizationDoneRight: HQ, Gnc, StuTuBCD, StudentTUniform, PoseLibLm, PoseLibLZ, PoseLibLmAdaptLossWidth
using VisualGeometryCore: WelschShape, GemanMcclureShape, SmoothTLSShape, TLSShape, MsacScoring, RansacScoring,
    codimension
using RansacScoringDoneRight: StudentTUniformScoring
using RansacLibLO: LebedaLOOptions, PRESET_REFERENCE   # the Lebeda ladder's options; RansacLib's defaults
using VisualGeometryEval.Evaluation: ComposedSpec, SoloSpec, Roster, WidthSource, TunedWidth, SelectionWidth,
    problem_type
using VisualGeometryCore: WidthAxis, ScaleMultiple, LossWidth, OutlierHalfwidth, TagRegistry
import PoseLib
using VisualGeometryCore: lo_label
# The classical RansacLib LO baseline (LebedaIterLO, LebedaLOPlus) over lib/RansacLibLO.
include(joinpath(@__DIR__, "lebeda_lo.jl"))
# The research-only zero-clamp Welsch shape (the "<key>@zc" variants below).
include(joinpath(@__DIR__, "welsch_zero_clamp.jl"))

# --- the selector families a config names --------------------------------------
"""
    SELECTOR_FAMILIES

The selector families a config or command line names (VisualGeometryCore's
`TagRegistry`, family suffix `Scoring`): the tag — `snake_case` of the
family's scoring type (`StudentTUniformScoring` → `"student_t_uniform"`,
`MlesacScoring` → `"mlesac"`, …) — to the family's SWEEP KEY, the symbol its
grid, its selection row, its arms' `sel` and its persisted records carry
(`:ig`, `:msac`, …). Retired tags name their successor.
"""
const SELECTOR_FAMILIES = TagRegistry(:selector, "Scoring",
    "student_t_uniform" => :ig, "msac" => :msac, "ransac" => :ransac, "magsac" => :magsac,
    "mlesac" => :gau, "welsch_cost" => :welsch, "geman" => :geman, "sim_fit_pp" => :simfitpp;
    retired = ("ig" => "student_t_uniform", "gau" => "mlesac", "welsch" => "welsch_cost",
               "simfitpp" => "sim_fit_pp"),
    paths = [r"(^|\.)selectors\[\d+\]$"])
"The sweep key of the selector family a config tag names (a retired tag is refused, naming its successor)."
selector_key(tag) = SELECTOR_FAMILIES[String(tag)]

# --- the protocol of record (configs/protocol.toml [arms]) ----------------------
# Every arm's LO budget is THE equal budget; every deviation is declared in
# protocol.toml beside its reason. No arm below spells an iteration count.

"""
    lebeda_budget_trials(budget, num_lsq_iterations) -> Int

The full classical LO's trials that spend exactly `budget` model updates when
every stage is active, `1 + trials·(2 + num_lsq_iterations) = budget`. A
budget the formula cannot meet exactly is refused.
"""
function lebeda_budget_trials(budget::Integer, num_lsq_iterations::Integer)
    trials, r = divrem(budget - 1, 2 + num_lsq_iterations)
    r == 0 && trials >= 1 || throw(ArgumentError(
        "LO budget $budget is not 1 + trials·(2 + $num_lsq_iterations) for an integer trials ≥ 1 " *
        "(configs/protocol.toml [arms] lo_iteration_budget vs [arms.lebeda] num_lsq_iterations)"))
    return trials
end

"""
    LEBEDA_OPTIONS

THE Lebeda ladder of the paper ([arms.lebeda]): the declared schedule, with the
full LO's trials derived from the budget. The two-view TLS-LO / TLS-LO+ arms
run these options.
"""
const LEBEDA_OPTIONS = let n = Int(protocol_value("arms.lebeda", "num_lsq_iterations"))
    LebedaLOOptions(; num_lo_trials = lebeda_budget_trials(LO_BUDGET, n),
                    sq_loss_width_multiplier = Float64(protocol_value("arms.lebeda", "sq_loss_width_multiplier")),
                    num_lsq_iterations = n,
                    min_sample_multiplicator = Int(protocol_value("arms.lebeda", "min_sample_multiplicator")),
                    non_min_sample_multiplier = Int(protocol_value("arms.lebeda", "non_min_sample_multiplier")))
end
"The Lebeda ladder's per-call seed ([arms.lebeda] rng_seed)."
const LEBEDA_RNG_SEED = Int(protocol_value("arms.lebeda", "rng_seed"))
const _GNC_ENTRY = Float64(protocol_value("arms.gnc", "entry"))
const _TLS_ADAPT_ROUNDS = let per = Int(protocol_value("arms.tls_adapt", "lm_iterations_per_round"))
    rounds, r = divrem(LO_BUDGET, per)
    r == 0 || throw(ArgumentError("[arms.tls_adapt] lm_iterations_per_round = $per does not divide the LO budget $LO_BUDGET"))
    rounds
end

"""
    welsch_half_weight_depth(scale_multiple) -> Float64

The half-weight depth `scale_multiple·√ln2` of a Welsch scale multiple: a
Welsch loss of width `scale_multiple·ŝ` weighs a residual `r` by
`e^{−r²/width²}`, which is ½ at `r = scale_multiple·√ln2·ŝ`. The GM static and
lifted arms read their scale multiple in that half-weight currency (VGC
`decision_width`), so mapping the shared scale-multiple grid through this
function lets the GM rows of the relative-pose rosters tune on the same grid
as the Welsch arms.
"""
welsch_half_weight_depth(scale_multiple) = scale_multiple * sqrt(log(2.0))

# One arm. `lo(scale_multiple)` builds the relative-pose strategy at the loss's
# OWN scale multiple (ignored by the self-scaling and fixed-external-scale arms,
# whose width is a native outlier half-width / loss width the refit layer
# delivers); `strategy_scale_multiple(width)` maps the tuned width value onto
# that scale multiple. `source` is where the refit width VALUE comes from (VisualGeometryEval
# `WidthSource`): tuned by the refiner stage, or — an objective-matched variant
# (`matched_key`, declared per cell) — its selector's a* itself.
struct ArmDef
    key::String                              # registry key, e.g. "IG  +Lift"
    sel::Symbol                              # selector seeding the refit (:ig | :msac)
    kind::WidthAxis                          # width parameterization (ScaleMultiple() | OutlierHalfwidth() | LossWidth())
    lo::Function                             # scale multiple -> strategy
    strategy_scale_multiple::Function        # tuned width value -> scale multiple
    timing::Union{Nothing, Tuple{String, Symbol}}   # (time_lo_supp run tag, method column)
    cite::String                             # the LO's citation (`\cite{…}`), "" = none
    source::WidthSource                      # TunedWidth() | SelectionWidth() (refit width = a*)
end
ArmDef(key, sel, kind, lo; strategy_scale_multiple = identity, timing = nothing, cite = "",
       source = TunedWidth()) =
    ArmDef(key, sel, kind, lo, strategy_scale_multiple, timing, cite, source)

"The relative-pose strategy of arm `def` at tuned width value `width`."
arm_strategy(def::ArmDef, width) = def.lo(def.strategy_scale_multiple(width))
"""
    arm_lo_label(def::ArmDef) -> String

The arm's LO label: its strategy's `lo_label` trait (the faceted registry's
label), an objective-matched variant marked " (matched)" — the one label
difference from its base arm, whose strategy it shares.
"""
arm_lo_label(def::ArmDef) = lo_label(arm_strategy(def, 1.0)) * _source_label(def.source)
_source_label(::TunedWidth) = ""
_source_label(::SelectionWidth) = " (matched)"

"""
    composed_label(def::ArmDef) -> String

The arm's legend label: selection score + LO ([`arm_lo_label`](@ref)), followed
by its citation.
"""
composed_label(def::ArmDef) =
    SEL_SHORT[def.sel] * "+" * arm_lo_label(def) * (isempty(def.cite) ? "" : "~" * def.cite)

const _CITE_TLS_IRLS = raw"\cite{Lebeda2012,PoseLib}"
const _CITE_TLS_LZ   = raw"\cite{LeZach2021,PoseLib}"
const _ARM_DEFS = ArmDef[
    # Self-scaling Stu-tU arms: the width is the refit outlier half-width.
    ArmDef("IG  +LO",  :ig, OutlierHalfwidth(), _ -> StudentTUniform(; max_iter = LO_BUDGET);
           timing = ("Stu-t-IRLS", :ig)),
    ArmDef("IG  +BCD", :ig, OutlierHalfwidth(), _ -> StuTuBCD(max_iter = LO_BUDGET);   # same-objective control (Table 1)
           timing = ("Stu-tU-BCD", :ig)),
    # Welsch: static IRLS, HQ lift, GNC continuation — consensus-anchored scale
    # multiple (width = scale_multiple·ŝ of the consensus set; never slides with the plug-in).
    ArmDef("IG  +WIrls", :ig, ScaleMultiple(), scale_multiple -> Irls{WelschShape}(; max_iter = LO_BUDGET, scale_multiple);
           timing = ("Welsch-IRLS", :ig)),
    ArmDef("IG  +Lift",  :ig, ScaleMultiple(), scale_multiple -> HQ{WelschShape}(; max_iter = LO_BUDGET, scale_multiple);
           timing = ("Welsch-HQ", :ig)),
    # GNC: the scale multiple sets the terminal width; `entry` is the continuation
    # SCHEDULE's start ([arms.gnc] entry: the anneal completes within the budget).
    ArmDef("IG  +GNC-W", :ig, ScaleMultiple(), scale_multiple -> Gnc{Irls{WelschShape}}(; max_iter = LO_BUDGET, scale_multiple, entry = _GNC_ENTRY);
           timing = ("Welsch-GNC", :ig)),
    # Geman–McClure: same three mechanisms in the half-weight currency.
    ArmDef("IG  +GM-Irls", :ig, ScaleMultiple(), scale_multiple -> Irls{GemanMcclureShape}(; max_iter = LO_BUDGET, scale_multiple);
           strategy_scale_multiple = welsch_half_weight_depth, timing = ("GM-IRLS", :ig)),
    ArmDef("IG  +GM-HQ",   :ig, ScaleMultiple(), scale_multiple -> HQ{GemanMcclureShape}(; max_iter = LO_BUDGET, scale_multiple);
           strategy_scale_multiple = welsch_half_weight_depth, timing = ("GM-HQ", :ig)),
    ArmDef("IG  +GNC-GM",  :ig, ScaleMultiple(), scale_multiple -> Gnc{Irls{GemanMcclureShape}}(; max_iter = LO_BUDGET, scale_multiple);
           timing = ("GM-GNC", :ig)),
    # TLS: smooth-truncated HQ lift (the scale multiple is the truncation in ŝ units) and GNC.
    ArmDef("IG  +TLS-HQ",  :ig, ScaleMultiple(), scale_multiple -> HQ{SmoothTLSShape}(; max_iter = LO_BUDGET, scale_multiple);
           timing = ("TLS-HQ", :ig)),
    ArmDef("IG  +GNC-TLS", :ig, ScaleMultiple(), scale_multiple -> Gnc{Irls{TLSShape}}(; max_iter = LO_BUDGET, scale_multiple);
           timing = ("TLS-GNC", :ig)),
    # Fixed-EXTERNAL-scale TLS baselines: the width IS the absolute truncation
    # loss width (:loss_width, the loss-width grid). Their timing rides the
    # Stu-t-IRLS run's MSAC / Le-Zach columns.
    ArmDef("IG  +PoseLib", :ig, LossWidth(), _ -> PoseLibLm(LO_BUDGET); timing = ("Stu-t-IRLS", :msac),
           cite = _CITE_TLS_IRLS),
    ArmDef("IG  +LZ",      :ig, LossWidth(), _ -> PoseLibLZ(LO_BUDGET); timing = ("Stu-t-IRLS", :lezach),
           cite = _CITE_TLS_LZ),
    # Classical RansacLib LO (Lebeda LO family; ExternalRefit route, the width IS
    # the absolute pool-frame truncation loss width — TLS-IRLS's currency).
    # LEBEDA_OPTIONS = the protocol's ladder with the full LO's trials derived
    # from the budget; PRESET_REFERENCE = RansacLib's defaults (61 updates), the
    # supplement's reference row. No iterLO(ref) row: the ILSQ ladder ignores
    # num_lo_trials (the ONLY field the two differ in), so it would duplicate
    # "IG  +TLS-LO" bitwise.
    ArmDef("IG  +TLS-LO",       :ig, LossWidth(), _ -> LebedaIterLO(LEBEDA_OPTIONS, LEBEDA_RNG_SEED);
           cite = raw"\cite{Lebeda2012}"),
    ArmDef("IG  +TLS-LO+",      :ig, LossWidth(), _ -> LebedaLOPlus(LEBEDA_OPTIONS, LEBEDA_RNG_SEED); timing = ("TLS-LO+", :ig)),
    ArmDef("IG  +TLS-LO+(ref)", :ig, LossWidth(), _ -> LebedaLOPlus(PRESET_REFERENCE, LEBEDA_RNG_SEED)),
    # Composed adaptive-TLS: Stu-t selection + PoseLib truncated LM
    # whose loss width is CONSENSUS-ANCHORED per round (scale_multiple·ŝ of the
    # refined consensus; [arms.tls_adapt]: one LM iteration per round, so
    # rounds = the budget). The width parameter is the dimensionless scale multiple — the
    # treatment of the Welsch arms. An external refiner (LocalOptimizationDoneRight's
    # PoseLib extension); E-track only.
    ArmDef("IG  +TLSadapt", :ig, ScaleMultiple(),
           m -> PoseLibLmAdaptLossWidth(max_iter = LO_BUDGET, rounds = _TLS_ADAPT_ROUNDS, scale_multiple = m)),
    # MSAC-seeded arms: the selection loss width seeds, the tuned truncation
    # loss width refits (the truncated pair); MSAC+Lift is the score×refiner
    # factorial off-diagonal.
    ArmDef("MSAC +PoseLib", :msac, LossWidth(), _ -> PoseLibLm(LO_BUDGET); cite = _CITE_TLS_IRLS),
    ArmDef("MSAC +LZ",      :msac, LossWidth(), _ -> PoseLibLZ(LO_BUDGET); cite = _CITE_TLS_LZ),
    ArmDef("MSAC +Lift",    :msac, ScaleMultiple(), scale_multiple -> HQ{WelschShape}(; max_iter = LO_BUDGET, scale_multiple)),
]
# THE OBJECTIVE-MATCHED VARIANTS: every arm whose width axis IS its selection
# axis (the Stu-tU-selected self-scaled refits) has a variant `matched_key(key)`
# — the same strategy, its refit width PINNED to its selector's a*
# (`SelectionWidth()`: never tuned; ζ·a* under a corruption). A variant runs
# only where a cell DECLARES it, opt-in, in its own TOML (`objective_matched =
# ["IG  +BCD"]` in `[sequential_cv]` / `[budget]`; an e2e cell lists it in its
# arms), so a cell that does not declare one keeps its key. No timing row (one
# LO call costs what its base arm's does).

# The native axis of an arm's selection score: the Stu-tU marginal's outlier
# half-width, MSAC's loss width (VisualGeometryCore `width_axis` of the scoring).
_selection_axis(d::ArmDef) = d.sel === :ig ? OutlierHalfwidth() : LossWidth()
"The registry key of arm `key`'s objective-matched variant."
matched_key(key::AbstractString) = String(key) * "@a*"
"Can arm `def` refit at its selector's a* (its width axis is its selection axis)?"
matchable(def::ArmDef) = def.source isa TunedWidth && def.kind == _selection_axis(def)
_matched_def(def::ArmDef) =
    ArmDef(matched_key(def.key), def.sel, def.kind, def.lo;
           strategy_scale_multiple = def.strategy_scale_multiple, cite = def.cite, source = SelectionWidth())
append!(_ARM_DEFS, [_matched_def(d) for d in filter(matchable, _ARM_DEFS)])
"The registry keys of every objective-matched variant (opt-in rows of every render and table)."
const MATCHED_KEYS = [d.key for d in _ARM_DEFS if d.source isa SelectionWidth]
"""
    declared_matched(section) -> Vector{String}

The base arms whose objective-matched variant a cell declares: its config
section's `objective_matched` list (`[sequential_cv]`, `[budget]`); none when
absent.
"""
declared_matched(section::AbstractDict) = String.(get(section, "objective_matched", String[]))

# THE ZERO-CLAMP VARIANTS (research-only, 2026-10-06): every Welsch-HQ arm
# (`HQ{WelschShape}`: "IG  +Lift", "MSAC +Lift") has a variant
# `zero_clamp_key(key)` — the same strategy on `WelschZeroClampShape`
# (welsch_zero_clamp.jl: the z-block's hreg = 0 at the lift's clamp, VGC
# 92597af, which produced the ACCV camera-ready / arXiv v1 "IG  +Lift" numbers;
# the 2026-10-04 rerun re-ran "IG  +Lift" alone, so the paper cells declare
# that one), beside the faithful arm (Zach & Bourmaud's limit, VGC dec9cd8). A TUNED arm:
# its own width CV, like its base. Opt-in, declared per cell in its own TOML
# (`zero_clamp = ["IG  +Lift"]` in `[sequential_cv]` / `[budget]`; an e2e cell
# lists "IG  +Lift@zc" in its arms), so a cell that does not declare one keeps
# its key. No timing row.
"The registry key of arm `key`'s zero-clamp variant."
zero_clamp_key(key::AbstractString) = String(key) * "@zc"
"Has arm `def` a zero-clamp variant (a tuned Welsch-HQ arm)?"
zero_clampable(def::ArmDef) = def.source isa TunedWidth && arm_strategy(def, 1.0) isa HQ{WelschShape}
_zero_clamp_def(def::ArmDef) =
    ArmDef(zero_clamp_key(def.key), def.sel, def.kind, m -> zero_clamp_strategy(def.lo(m));
           strategy_scale_multiple = def.strategy_scale_multiple, cite = def.cite)
append!(_ARM_DEFS, [_zero_clamp_def(d) for d in filter(zero_clampable, _ARM_DEFS)])
"The registry keys of every zero-clamp variant (opt-in rows of every render and table)."
const ZERO_CLAMP_KEYS = [d.key for d in _ARM_DEFS if arm_strategy(d, 1.0) isa HQ{WelschZeroClampShape}]
"""
    declared_zero_clamp(section) -> Vector{String}

The base arms whose zero-clamp variant a cell declares: its config section's
`zero_clamp` list (`[sequential_cv]`, `[budget]`); none when absent.
"""
declared_zero_clamp(section::AbstractDict) = String.(get(section, "zero_clamp", String[]))
"Every opt-in variant key (objective-matched and zero-clamp): rows a cell runs only where it declares them."
const VARIANT_KEYS = vcat(MATCHED_KEYS, ZERO_CLAMP_KEYS)
"""
    declared_variants(section) -> Vector{String}

The registry keys of every opt-in variant a cell's config section declares
(`objective_matched` and `zero_clamp`).
"""
declared_variants(section::AbstractDict) =
    vcat(matched_key.(declared_matched(section)), zero_clamp_key.(declared_zero_clamp(section)))

"Every arm of the paper, by registry key."
const ARM_TABLE = Dict(def.key => def for def in _ARM_DEFS)
length(ARM_TABLE) == length(_ARM_DEFS) || error("arm_rosters: duplicate registry key")

# --- the relative-pose rosters: ordered key lists over ARM_TABLE -------------------
# Composed (the sequential CV: the selector's width, then each arm's at it).
# :H (HEB-H cell, supp_H_miscal.jl): the loss MECHANISM MATRIX — 3 losses
# {Welsch, GM, TLS} × {static IRLS where it exists, HQ lift, GNC} — plus the
# self-scaling Stu-t rows and the fixed-scale TLS baselines (PoseLib
# refine_homography, the budget-parity Lebeda pair: RansacLib's TwoViewLOSolver has the
# 4-pt DLT homography kind). The relpose-only rows (TLSadapt, MSAC-seeded)
# have no H path. E and F carry the same roster (the HQ lifts, GNC and BCD run
# on the 7-dof FundMatProblem chart); TLSadapt is E-only (PoseLibLmAdaptLossWidth
# hard-errors on F).
# Every roster below lists base arms; `_with_variants(keys, matched, zero_clamp)`
# places the declared variants of each base right after it (zero-clamp, then
# objective-matched; a declared base the roster lacks, or one without that
# variant, is refused).
function _with_variants(keys, matched, zero_clamp)
    for (decl, has, what) in (("objective_matched", matchable, matched), ("zero_clamp", zero_clampable, zero_clamp)),
        k in what
        k in keys && has(ARM_TABLE[k]) ||
            error("$decl: $(repr(k)) has no such variant in this roster " *
                  "(eligible: $(join(repr.(filter(b -> has(ARM_TABLE[b]), keys)), ", ")))")
    end
    return reduce(vcat, [vcat([k], k in zero_clamp ? [zero_clamp_key(k)] : String[],
                              k in matched ? [matched_key(k)] : String[]) for k in keys])
end
"Every matchable base of `keys`: the roster the deployed READERS rebuild from (any variant a sidecar may hold)."
_all_matchable(keys) = filter(k -> matchable(ARM_TABLE[k]), keys)
"Every zero-clampable base of `keys` (likewise, for the readers)."
_all_zero_clampable(keys) = filter(k -> zero_clampable(ARM_TABLE[k]), keys)
const _COMPOSED_EF = ["IG  +LO", "IG  +WIrls", "IG  +Lift", "IG  +PoseLib", "IG  +LZ",
                      "IG  +TLS-LO+", "MSAC +PoseLib", "MSAC +LZ"]
const _COMPOSED_CONTROLS = ["IG  +GNC-W", "IG  +GNC-TLS", "IG  +TLS-HQ", "IG  +GM-HQ",
                            "IG  +GM-Irls", "IG  +GNC-GM", "IG  +BCD", "MSAC +Lift"]
const COMPOSED_ROSTER = Dict((
    :H => ["IG  +LO", "IG  +BCD", "IG  +WIrls", "IG  +Lift", "IG  +GNC-W", "IG  +GM-Irls",
           "IG  +GM-HQ", "IG  +GNC-GM", "IG  +TLS-HQ", "IG  +GNC-TLS", "IG  +PoseLib",
           "IG  +LZ", "IG  +TLS-LO", "IG  +TLS-LO+"],
    :E => vcat(_COMPOSED_EF, "IG  +TLSadapt", _COMPOSED_CONTROLS),
    :F => vcat(_COMPOSED_EF, _COMPOSED_CONTROLS),
))
# Solo refinement / basin: the Fig 2 arms. The GNC family and TLS-HQ are E-only
# here (the F track keeps the subset with an F path).
const _FIG2_E_ONLY = ["IG  +GNC-W", "IG  +TLS-HQ", "IG  +GNC-TLS", "IG  +GNC-GM"]
const SOLO_ROSTER = ["IG  +LO", "IG  +WIrls", "IG  +Lift", "IG  +PoseLib", "IG  +LZ", "IG  +GM-HQ",
                     "IG  +TLS-LO", "IG  +TLS-LO+", "IG  +TLS-LO+(ref)"]
const BASIN_ROSTER = ["IG  +LO", "IG  +WIrls", "IG  +Lift", "IG  +PoseLib", "IG  +LZ", "IG  +GM-HQ",
                      "IG  +GM-Irls", "IG  +BCD", "IG  +TLS-LO", "IG  +TLS-LO+", "IG  +TLS-LO+(ref)"]
_fig2_roster(base, problem) = problem === :E ? vcat(base, _FIG2_E_ONLY) : base

"""
    composed_specs(problem::Symbol = :E; matched = String[], zero_clamp = String[]) -> Vector{ComposedSpec}

The composed (score + LO, sequential-CV tuned) roster of `problem` (:E, :F,
:H): each arm at its width parameterization (`:scale_multiple`
consensus-anchored, `:outlier_halfwidth` refit outlier half-width, `:loss_width`
refit truncation loss width), plus the objective-matched variant of each base
in `matched` and the zero-clamp variant of each base in `zero_clamp` (the
cell's declarations, [`declared_matched`](@ref), [`declared_zero_clamp`](@ref)).
"""
composed_specs(problem::Symbol = :E; matched = String[], zero_clamp = String[]) =
    [ComposedSpec(d.key, d.sel, _selection_axis(d), d.kind, width -> arm_strategy(d, width); source = d.source)
     for d in (ARM_TABLE[k] for k in _with_variants(COMPOSED_ROSTER[problem], matched, zero_clamp))]


# The unit-multiple arm of the solo/basin rosters: consensus-FORM arms register
# their UNIT scale multiple and the refit runs it at the absolute loss width
# (:loss_width); natively-absolute arms keep their kind.
_unit_strategy(d::ArmDef) = _ -> arm_strategy(d, 1.0)

"""
    solo_specs(problem::Symbol = :E; role::Symbol = :refinement) -> Vector{SoloSpec}

The registered solo-CV roster for `role`.

role=:refinement — the Fig 2 roster: the deterministic loss arms, the
truncated externals, the classical RansacLib rows and the self-scaled Stu-t
arm. Consensus-anchored arms are registered at their UNIT scale multiple; the
refit runs them at the absolute loss width (see `solo_refit_imc!`).
The default main-figure classical roster is the budget-parity Lebeda pair (LEBEDA_OPTIONS); the
PRESET_REFERENCE full-LO row is the supplement's reference operating point.

role=:selection — the Fig 1 scorers with a CPU pool-scoring path (each
`ctor(width)` is the scoring at that width, selected with VisualGeometryCore's
`best_pool_model`): IG (:outlier_halfwidth; the Jeffreys marginal), MSAC and
RANSAC (:loss_width). ROSTER GAP (documented, best-effort): :magsac and the
other vocab families with sweep-only engines (gau/geman/welsch(_marg)) score
through KernelAbstractions GPU kernels (RSDR `grid_evaluate` — MAGSAC needs
the σ-marginalized histogram weights); they stay out of the solo roster until
a CPU scorer exists.
"""
function solo_specs(problem::Symbol = :E; role::Symbol = :refinement)
    if role === :refinement
        return [SoloSpec(d.key, :refinement, d.kind isa ScaleMultiple ? LossWidth() : d.kind,
                         _unit_strategy(d))
                for d in (ARM_TABLE[k] for k in _fig2_roster(SOLO_ROSTER, problem))]
    elseif role === :selection
        P = problem_type(problem); dg = codimension(P)
        return SoloSpec[
            SoloSpec("IG",     :selection, OutlierHalfwidth(), w -> StudentTUniformScoring(P, Float64(w))),
            SoloSpec("MSAC",   :selection, LossWidth(),        w -> MsacScoring(dg; threshold = Float64(w))),
            SoloSpec("RANSAC", :selection, LossWidth(),        w -> RansacScoring(dg; threshold = Float64(w))),
        ]
    end
    error("solo_specs: unknown role :$role (expected :selection | :refinement)")
end

"""
    basin_specs(problem::Symbol = :E; matched = String[], zero_clamp = String[]) -> Vector{ComposedSpec}

THE basin (loss-width) roster — the Fig 2 arms tuned by the COMPOSED
calibrated protocol (the sequential CV, real Stu-tU-selected seeds, ζ = 1)
on the LOSS WIDTH axis: the grid value is the arm's entire scale knowledge
(rationale: tuning uses the deployed composed protocol, but the basin TEST
provides no scale — a consensus anchor would smuggle one in).

Same unit-multiple operating points as the solo refinement roster (ONE
delivery table, `solo_refit_imc!`'s): consensus-FORM arms (:loss_width)
register their unit-multiple ctor and the val refits run it at the absolute
width (LoRefitSpec `widths` — bitwise the solo loss-width call, asserted in
tests); the fixed-external-scale arms (TLS-IRLS/LZ + the RansacLib classical
rows) are :loss_width too, their external refit at the same width, and
:outlier_halfwidth stays native (the self-scaled Stu-t arm and BCD).

Consumed by the sequential CV of configs/pt_e_basin.toml (roster = "basin":
sidecar mode "basin", its own keyed dir) and, test-side, by the basin ladder's --solo-cv path via
`deployed_basin_settings`. The deployed/miscal/budget rosters stay
scale-multiple/consensus-anchored — their readers REFUSE basin sidecars.
"""
basin_specs(problem::Symbol = :E; matched = String[], zero_clamp = String[]) =
    [ComposedSpec(d.key, d.sel, _selection_axis(d), d.kind isa ScaleMultiple ? LossWidth() : d.kind, _unit_strategy(d);
                  source = d.source)
     for d in (ARM_TABLE[k] for k in _with_variants(_fig2_roster(BASIN_ROSTER, problem), matched, zero_clamp))]

"""
THE paper's roster: the engine's deployed_* readers and audit rebuild arms from
this table — every base arm and every variant of it (objective-matched,
zero-clamp), so a reader rebuilds whatever a cell declared; what RUNS is the
cell's own declaration (the drivers call `composed_specs`/`basin_specs` with it).
"""
const ROSTER = Roster(p -> (k = COMPOSED_ROSTER[p];
                            composed_specs(p; matched = _all_matchable(k), zero_clamp = _all_zero_clampable(k))),
                      solo_specs,
                      p -> (k = _fig2_roster(BASIN_ROSTER, p);
                            basin_specs(p; matched = _all_matchable(k), zero_clamp = _all_zero_clampable(k))))

# --- THE paper's Welsch-HQ ----------------------------------------------------
# Two Welsch-HQ z-blocks are recorded wherever a cell declares the zero-clamp
# variant: the faithful "IG  +Lift" and "IG  +Lift@zc". Which ONE the paper
# shows as "Welsch-HQ" is declared once, configs/protocol.toml [paper]
# welsch_hq (presentation only, not in any run key); figure_style.jl draws and
# labels it, and the other is never drawn.
"The arm the paper reports as Welsch-HQ (configs/protocol.toml `[paper] welsch_hq`)."
const PAPER_WELSCH_HQ = String(protocol_value("paper", "welsch_hq"))
"The recorded Welsch-HQ arm the paper does NOT show (the other z-block)."
const UNSHOWN_WELSCH_HQ = let both = ("IG  +Lift", zero_clamp_key("IG  +Lift"))
    PAPER_WELSCH_HQ in both ||
        error("configs/protocol.toml [paper] welsch_hq = \"$(PAPER_WELSCH_HQ)\": must be one of $(both)")
    only(k for k in both if k != PAPER_WELSCH_HQ)
end

# --- the derived name tables --------------------------------------------------
# The "Welsch-HQ" timing run belongs to the paper's Welsch-HQ (its strategy,
# its tuned scale multiple: time_lo_supp.jl); the other z-block is not timed.
"Registry key => (time_lo_supp run tag, method column) of every timed arm."
const TIMING_TAGS = let t = Dict(d.key => d.timing for d in _ARM_DEFS if d.timing !== nothing)
    haskey(t, "IG  +Lift") || error("arm table: the Welsch-HQ arm lost its timing row")
    t[PAPER_WELSCH_HQ] = pop!(t, "IG  +Lift")
    t
end
