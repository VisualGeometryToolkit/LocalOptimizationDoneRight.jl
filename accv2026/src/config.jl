# =============================================================================
# src/config.jl — THE paper prelude.
#
# One include gives a driver the full campaign configuration on top of the
# stack:
#
#     include(joinpath(@__DIR__, "..", "src", "config.jl"))
#
# The stack: VisualGeometryEval (statistics, the codified CV, the stage
# runner and run records, rendering, pool IO, and the composition evaluator
# `Evaluation`), the paper's local optimizers (LocalOptimizationDoneRight) and
# scorers (RansacScoringDoneRight), and the estimator / geometry packages below
# them. Contents (thin per-paper CONFIG; every mechanism lives in a
# package):
#   protocol.jl       — configs/protocol.toml, the experiment protocol of record
#                       (the LO budget, the Lebeda schedule, every experiment's
#                       result-changing value), read by `protocol_value`
#   validation_data.jl — the data a cross-validation reads, from its spec (the
#                       scene lists are VisualGeometryEval configs/splits.toml's,
#                       named by every tuning spec; no list lives in this paper's code)
#   labels.jl         — THE paper label vocabulary (citations)
#   arm_rosters.jl    — the arm table and `ROSTER` (the deployed_* sidecar
#                       readers rebuild arms from it)
#   palette.jl        — paper colours and summary-panel rows
#   figure_style.jl   — the faceted-arm style rows and `PAPER_STYLE`, the one
#                       value every renderer is handed
#
# Idempotent: safe to include from several files of one driver process.
# =============================================================================

if !@isdefined(ACCV2026_CONFIG_LOADED)

using JLD2
using StaticArrays: SMatrix, SVector
using StructArrays: StructArray
using LinearAlgebra
using Base.Threads
using Statistics: median
using Random: MersenneTwister
using Rotations: RotMatrix

using VisualGeometryEval
using VisualGeometryEval.Stats, VisualGeometryEval.Tuning, VisualGeometryEval.Evaluation,
    VisualGeometryEval.Experiments, VisualGeometryEval.Render, VisualGeometryEval.Pools
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: StudentTUniform, HQ, Gnc, WelschHQNewton, WelschHQEcm, StuTuRegemm
using RobustVisualGeometry
using RobustVisualGeometry: EssentialProblem, FundMatProblem, locally_optimize, NoLocalOptimization, Irls
using VisualGeometryCore
using VisualGeometryCore: Point2, EssentialMat, FundMat, intrinsics, Vec3, skew,
    WelschShape, GemanMcclureShape, CauchyShape, SmoothTLSShape, TLSShape, HuberShape, GaussianShape,
    WidthAxis, ScaleMultiple, LossWidth, OutlierHalfwidth, IGPrior, codimension, best_pool_model,
    MsacScoring, RansacScoring, lo_width
using VisualGeometryCore.Pools
using VisualGeometryEval.Evaluation: lo_iteration_budget
using PoseLib: refine_relpose
using RansacScoringDoneRight: StudentTUniformScoring
import RansacScoringDoneRight

"The packages whose code determines a tuning artifact's result (VisualGeometryEval `save_tuning_artifact` / `code_identity` `code`)."
const TUNING_CODE = (RobustVisualGeometry, RansacScoringDoneRight, VisualGeometryCore, LocalOptimizationDoneRight,
                     VisualGeometryEval)

include(joinpath(@__DIR__, "protocol.jl"))         # configs/protocol.toml (protocol_value)
include(joinpath(@__DIR__, "validation_data.jl"))   # spec → scenes and units
include(joinpath(@__DIR__, "labels.jl"))
include(joinpath(@__DIR__, "arm_rosters.jl"))
include(joinpath(@__DIR__, "palette.jl"))
include(joinpath(@__DIR__, "figure_style.jl"))

const ACCV2026_CONFIG_LOADED = true

end # config guard
