# Local optimization strategies

```@meta
CurrentModule = LocalOptimizationDoneRight
```

Every strategy implements VisualGeometryToolkitCore's local-optimization contract
(`lo_workspace`, `locally_optimize!`), so it composes with any scorer in
VisualGeometryToolkitEstimation's finds (`Ransac`) and local optimizations
(`LocalOptimization`). The core baselines,
`nothing` (no local optimization) and `Irls{K}`, live in VisualGeometryToolkitEstimation. A
width-carrying strategy takes `efficiency_constant = m` (a multiple of the consensus
set's scale), `loss_width = w` (an absolute width), or neither, in which case
its loss width follows the scorer's `decision_boundary`. See the
[Overview](../overview.md).

## Half-quadratic lifts and graduated non-convexity

```@docs
HQ
WelschHQNewton
WelschHQEcm
BarronHQ
GmHqEps
Gnc
```

An `HQ`'s z₀ start and a `Gnc`'s rung budget are types, stored by their tags:

```@docs
AbstractLiftStart
FlatStart
PosteriorStart
ConsensusStart
LIFT_START_TAGS
AbstractGncBudget
ParityBudget
ConvergedBudget
GNC_BUDGET_TAGS
```

## Student-t + uniform and Barron-adaptive strategies

```@docs
StudentTUniform
StuTuBCD
StuTuHQTabulated
StuTuRegemm
BarronAdaptive
BarronAdaptiveLikelihood
```

## The consensus-anchored truncated refit

An external refiner (VisualGeometryToolkitCore's `ExternalRefit`) as Core's
`BackendRefit` of this package's refine algorithm. PoseLib's truncated refiners
themselves are Core's `BackendRefit` of its PoseLib-backed Levenberg–Marquardt. See
[Baselines](../guide/baselines.md).

```@docs
AdaptiveLossWidthRefit
RelativePoseRefitProblem
LODR_CONFIG_VERSIONS
```

## Cross-validated operating points

```@docs
tuning_constant
TuningConstant
TuningProvenance
WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL
WELSCH_HQ_EFFICIENCY_CONSTANT_FUNDMAT
WELSCH_HQ_EFFICIENCY_CONSTANT_HOMOGRAPHY
WELSCH_HQ_EFFICIENCY_CONSTANT_ABSOLUTE_POSE
```

## TOML registry

```@docs
LODR_STRATEGY_TAGS
```

## Index

```@index
```
