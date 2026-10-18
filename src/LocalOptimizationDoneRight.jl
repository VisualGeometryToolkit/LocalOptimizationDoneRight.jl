"""
    LocalOptimizationDoneRight

The local optimizers of the ACCV 2026 paper "Score Sharp, Refine Soft, Polish
Hard", on VisualGeometryToolkitCore's local-optimization contract and
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
- PoseLib's truncated refiners ([`PoseLibLm`](@ref), [`PoseLibLZ`](@ref),
  [`PoseLibLmAdaptLossWidth`](@ref)) as external refiners (their solver calls
  load with PoseLib, a package extension);
- the cross-validated operating points ([`tuning_constant`](@ref)) and the
  strategies' TOML registry ([`LO_TAGS`](@ref)), merged with the core's to load:
  `local_optimization_from_toml(d; class, tags = merge(VisualGeometryToolkitEstimation.LO_TAGS, LO_TAGS))`.

Compose one with any scorer: `find_essential(cam1, cam2, pairs; local_optimization
= HQ{WelschShape}(scale_multiple = WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL))`.
"""
module LocalOptimizationDoneRight

import VisualGeometryToolkitCore as VgtkCore
import VisualGeometryToolkitEstimation as VgtkEstimation

using LinearAlgebra: I, dot, norm
using StaticArrays: SMatrix, SVector
using Statistics: Statistics
using TOML: TOML

# --- Upstream stack: public names only ----------------------------------------
using VisualGeometryToolkitCore: VisualGeometryToolkitCore, AbstractLocalOptimization, AbstractLossShape, AbstractBlockCoordinateMethod,
    AbstractWeightPolicy, NormalizedWeightPolicy, AnyLoss, DeployedLoss, deploy, rescale,
    sq_loss_width, loss_shape, liftable, weight, conjugate_curvature,
    lift_weight, lift_cost, loss_family, loss_label,
    gnc_surrogate, gnc_weight, gnc_entry_mu0, gnc_mu_cap, band_signal, NoSurrogate, MuScaled,
    BandAnnealed, GaussianShape, WelschShape, GemanMcclureShape, SmoothTLSShape,
    BarronShape, ConsensusSet, consensus_score, is_predictive, ScoreBuffers, ScaleMultiple, LossWidth, TagRegistry,
    SelfScaling, ConsensusAnchored, FixedScale, ExternalRefit, scale_s2, inlier_count, inlier_threshold,
    outlier_halfwidth, score_model!, loss_at, width_scale_interface, lo_estimate, Incumbent,
    keep_best, StoppingCriterion, PosteriorWeightState, reset_posterior!, StudentTMixture, posterior_weight,
    posterior_weight_derivative, mixture_ecm!, mixture_nll, s_hat_sq, student_t_dof,
    sq_residuals, robust_weight, truncated_log_normaliser, data_size, codimension,
    refine!, fit_scale, JeffreysPrior, weighted_sq, iterations, retcode, toml_default, RowsWorkspace, task_buffers, rows_provider, lift_init, lift_refresh!, lift_jacobian!,
    lift_retract, lift_model, lift_valid, lift_rows, lift_residuals, lift_size,
    block_coordinate_descent!, path_suffix, optimization_path, EssentialMat,
    present_kwargs, check_keys, allowed_keys, convert_field, toml_table, toml_key, toml_skip_fields
# The contract verbs this package adds methods to.
import VisualGeometryToolkitCore: locally_optimize!, update_model!, update_residuals!, post_iteration!,
    update_nuisance!, update_weights!, stopping_criterion, stop_reason, current_cost,
    current_s2, block_coordinate_result,
    lift_wmax, lift_conjugate, lift_zblock   # the tabulated lift answers the loss's lift facet
using VisualGeometryToolkitEstimation: VisualGeometryToolkitEstimation, Irls, LoBuffers, LiftableProblem,
    BoundedProblem, EssentialProblem, PosteriorLikelihood, StopWhenNoImprovement,
    posterior_irls!, consensus_posterior, required_outlier_halfwidth, lo_loss, strategy_loss,
    plain_scale_multiple, lo_width_value, LOSS_TAGS

include("config_defaults.jl")          # configs/default.toml → `_TOML_DEFAULTS`, `_config_default`
include("lift/schedules.jl")           # LoSchedule, MuLadder, GeometricAnneal, gnc_schedule
include("lift/lift_core.jl")           # the lift θ/z-blocks, LiftState, TabulatedLift
include("strategies/types.jl")         # the strategies, their identity and registry (LO_TAGS)
include("lift/lifts.jl")               # ManifoldLiftHQ / ManifoldLiftGnc and the HQ/GNC locally_optimize!
include("strategies/irls.jl")          # StudentTUniform, BarronAdaptive, StuTuBCD
include("strategies/essential.jl")     # the essential-matrix research lifts
include("tuning_constants.jl")         # [[tuning_constants]] → tuning_constant
include("strategies/config_toml.jl")   # the strategies' TOML loader and writer
include("poselib_arms.jl")             # PoseLib's truncated refiners (solver calls: the PoseLib extension)

"""
    CONTRACT_GENERICS

The generic functions of LocalOptimizationDoneRight another module may add
methods to (VisualGeometryToolkitCore's `contract_generic_violations`): the PoseLib
truncated refiners' pose body, implemented by the PoseLib extension.
"""
const CONTRACT_GENERICS = (truncated_refit_pose,)

export HQ, Gnc, StudentTUniform, StuTuBCD, BarronAdaptive, BarronHQ, GmHqEps,
    WelschHQNewton, WelschHQEcm, StuTuHQTabulated, StuTuRegemm
export PoseLibLm, PoseLibLZ, PoseLibLmAdaptLossWidth, truncated_refit_pose
export tuning_constant, WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL, WELSCH_HQ_SCALE_MULTIPLE_FUNDMAT,
    WELSCH_HQ_SCALE_MULTIPLE_HOMOGRAPHY, WELSCH_HQ_SCALE_MULTIPLE_ABSOLUTE_POSE

# Public, not exported: the registry, the provenance records, the lift
# machinery a research arm builds on, and the continuation schedules.
public LO_TAGS, CONTRACT_GENERICS, TuningConstant, TuningProvenance, BarronAdaptiveLikelihood,
    LiftState, lift_state, LiftZBlock, JointGaussNewton, WelschConvexNewton, TabulatedLift,
    tabulate!, cubic_hermite, lift_window, lift_raw_window,
    LoSchedule, NoSchedule, MuLadder, GeometricAnneal, gnc_schedule, schedule_init, scale_mult,
    advance!, isterminal, with_converged_rung, DEFAULTS_PATH

end # module LocalOptimizationDoneRight
