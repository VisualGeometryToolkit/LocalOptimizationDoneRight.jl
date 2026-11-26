"""
    LocalOptimizationDoneRight

The local optimizers of the ACCV 2026 paper "Robust Local Optimization Done
Right", on VisualGeometryToolkitCore's local-optimization contract and
VisualGeometryToolkitEstimation's problems:

- the joint-(θ,z) half-quadratic loss lifts ([`HQ`](@ref) and its research
  variants [`WelschHQNewton`](@ref), [`WelschHQEcm`](@ref), [`BarronHQ`](@ref),
  [`GmHqEps`](@ref)) and graduated non-convexity ([`Gnc`](@ref)), one code
  path over VisualGeometryToolkitCore's chart-rows contract (the lift core and its
  continuation schedules live here);
- the Student-t + uniform IRLS ([`StudentTUniform`](@ref)), its score-matched
  block-coordinate ascent ([`StuTuBCD`](@ref)), the mixture lifts
  ([`StuTuHQTabulated`](@ref), [`StuTuRegemm`](@ref)) and the Barron-adaptive
  IRLS ([`BarronAdaptive`](@ref));
- the consensus-anchored truncated refit ([`AdaptiveLossWidthRefit`](@ref) on a
  [`RelativePoseRefitProblem`](@ref)), PoseLib's truncated LM with its loss width
  re-estimated between rounds, an external refiner as VisualGeometryToolkitCore's
  `BackendRefit` of it (PoseLib's truncated refiners themselves are Core's
  `BackendRefit(LevenbergMarquardt(PoseLibSolver(); optimization_strategy), stops)`);
- the cross-validated operating points ([`tuning_constant`](@ref)) and the
  strategies' TOML registry ([`LODR_STRATEGY_TAGS`](@ref)), merged with the core's to load:
  `optimization_strategy_from_toml(d; class, tags = merge(VisualGeometryToolkitEstimation.OPTIMIZATION_STRATEGY_TAGS, LODR_STRATEGY_TAGS))`.

Compose one with any scorer: `solve(EstimationProblem(EssentialProblem(cam1, cam2, cs)),
Ransac(; local_optimization_strategy = HQ{WelschShape}(efficiency_constant =
WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL)); rng)`.
"""
module LocalOptimizationDoneRight

import VisualGeometryToolkitCore as VgtkCore
import VisualGeometryToolkitEstimation as VgtkEstimation

using LinearAlgebra: I, dot, norm
using StaticArrays: SMatrix, SVector
using Statistics: Statistics

# --- Upstream stack: public names only ----------------------------------------
using VisualGeometryToolkitCore: VisualGeometryToolkitCore, AbstractOptimizationStrategy, AbstractLossShape, AbstractBlockCoordinateMethod,
    AbstractWeightPolicy, NormalizedWeightPolicy, AnyLoss, DeployedLoss, rescale,
    sq_loss_width, loss_shape, liftable, weight, conjugate_curvature,
    lift_weight, lift_cost, loss_family, loss_label,
    gnc_surrogate, gnc_weight, gnc_entry_mu0, gnc_mu_cap, band_signal, NoSurrogate, MuScaled,
    BandAnnealed, GaussianShape, WelschShape, GemanMcclureShape, SmoothTLSShape,
    BarronShape, ConsensusSet, consensus_score, is_predictive, ScoreBuffers, EfficiencyConstant, TagRegistry, tag_of,
    SelfScaling, ConsensusAnchored, scale_s2, inlier_count,
    outlier_halfwidth, score_model!, loss_at, width_scale_interface, lo_estimate, Attributed,
    keep_best, StoppingCriterion, PosteriorWeightState, reset_posterior!, StudentTMixture, posterior_weight,
    posterior_weight_derivative, mixture_ecm!, mixture_nll, s_hat_sq,
    sq_distances, robust_weight, FrozenNuisance, truncated_log_normaliser, data_size,
    refine!, JeffreysPrior, SquaredScale, ScaleMAP, EstimationProblem, solve, AbstractEstimationAlgorithm, RefineKind, weighted_sq, ReturnCode,
    IncrementSize, LadderConverged, LeftBasin, retcode_from_symbol, toml_default, parse_defaults, ConfigVersions, ConfigMigration, RowsWorkspace, task_buffers, rows_provider, lift_init, lift_refresh!, lift_jacobian!,
    lift_retract, lift_model, lift_valid, lift_rows, lift_residuals, lift_size,
    block_coordinate_descent!, path_suffix, optimization_path, EssentialMat,
    BackendRefit, LevenbergMarquardt, PoseLibSolver, LmStops, FitResult, SolveStats, NullParameters, RefineProblem,
    FixedS2, LossWidth, OutlierHalfwidth, TLSShape, EuclideanMap, Vec3, cheiral_pose_fast, deploy, loss_width,
    loss_width_to_outlier_halfwidth, codimension, mahalanobis_distances!, with_width, init, solve!, reinit!
# The contract verbs this package adds methods to.
import VisualGeometryToolkitCore: locally_optimize!, update_model!, update_residuals!, post_iteration!,
    update_nuisance!, update_weights!, stopping_criterion, stop_reason, current_cost,
    current_s2, block_coordinate_result,
    lift_wmax, lift_conjugate, lift_zblock   # the tabulated lift answers the loss's lift facet
# The core optimization strategies and the strategy registry machinery (VisualGeometryToolkitCore
# robust/strategies.jl): the types, the shared loss table and the keyword constructor.
using VisualGeometryToolkitCore: Irls, LOSS_TAGS, lo_loss, strategy_loss, lo_width_value, lo_construct
using VisualGeometryToolkitEstimation: VisualGeometryToolkitEstimation, LoBuffers, MinimalSolveProblem,
    BoundedProblem, EssentialProblem, PosteriorLikelihood, StopWhenNoImprovement,
    posterior_irls!, consensus_posterior, required_outlier_halfwidth, RelativePoseProblem, ConsensusScale

include("config_defaults.jl")          # configs/default.toml → `_DEFAULTS_OF_RECORD`, `_config_default`
include("lift/schedules.jl")           # LoSchedule, MuLadder, GeometricAnneal, gnc_schedule
include("lift/lift_core.jl")           # the lift θ/z-blocks, LiftState, TabulatedLift
include("strategies/types.jl")         # the strategies, their identity and registry (LODR_STRATEGY_TAGS)
include("lift/lifts.jl")               # ManifoldLiftHQ / ManifoldLiftGnc and the HQ/GNC locally_optimize!
include("lift/termination.jl")         # the §14 record: lo_termination (the rule is Core's stop_rule of the criterion that fired)
include("strategies/irls.jl")          # StudentTUniform, BarronAdaptive, StuTuBCD
include("strategies/essential.jl")     # the essential-matrix research lifts
include("tuning_constants.jl")         # [[tuning_constants]] → tuning_constant
include("strategies/config_toml.jl")   # the strategies' TOML loader and writer
include("adaptive_refit.jl")           # AdaptiveLossWidthRefit on a RelativePoseRefitProblem, and its BackendRefit external refit

"""
    CONTRACT_GENERICS

The generic functions of LocalOptimizationDoneRight another module may add
methods to (VisualGeometryToolkitCore's `contract_generic_violations`): none. The
package adds methods to VisualGeometryToolkitCore's contract generics only (the
external-refit contract, and `__init`/`solve!`/`reinit!` for its own
[`AdaptiveLossWidthRefit`](@ref)).
"""
const CONTRACT_GENERICS = ()

export HQ, Gnc, StudentTUniform, StuTuBCD, BarronAdaptive, BarronHQ, GmHqEps,
    WelschHQNewton, WelschHQEcm, StuTuHQTabulated, StuTuRegemm
export FlatStart, PosteriorStart, ConsensusStart, ParityBudget, ConvergedBudget   # HQ's z₀ start, Gnc's rung budget
export AdaptiveLossWidthRefit, RelativePoseRefitProblem   # the consensus-anchored truncated refit (TLS-IRLS-ŝ) and its data
public LODR_CONFIG_VERSIONS
export tuning_constant, WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL, WELSCH_HQ_EFFICIENCY_CONSTANT_FUNDMAT,
    WELSCH_HQ_EFFICIENCY_CONSTANT_HOMOGRAPHY, WELSCH_HQ_EFFICIENCY_CONSTANT_ABSOLUTE_POSE

# Public, not exported: the registry, the provenance records, the lift
# machinery a research arm builds on, and the continuation schedules.
public LODR_STRATEGY_TAGS, LIFT_START_TAGS, GNC_BUDGET_TAGS, AbstractLiftStart, AbstractGncBudget, CONTRACT_GENERICS, TuningConstant, TuningProvenance, BarronAdaptiveLikelihood,
    LiftState, lift_state, LiftZBlock, JointGaussNewton, WelschConvexNewton, TabulatedLift,
    tabulate!, cubic_hermite, lift_window, lift_raw_window,
    LoSchedule, NoSchedule, MuLadder, GeometricAnneal, gnc_schedule, schedule_init, scale_mult,
    advance!, isterminal, with_converged_rung, DEFAULTS_PATH

end # module LocalOptimizationDoneRight
