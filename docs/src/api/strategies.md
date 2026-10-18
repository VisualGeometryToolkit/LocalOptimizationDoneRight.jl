# Local optimization strategies

```@meta
CurrentModule = LocalOptimizationDoneRight
```

Every strategy implements VisualGeometryToolkitCore's local-optimization contract
(`lo_workspace`, `locally_optimize!`), so it composes with any scorer in
VisualGeometryToolkitEstimation's `ransac` and `find_*` pipelines. The core baselines,
`NoLocalOptimization` and `Irls{K}`, live in VisualGeometryToolkitEstimation. A
width-carrying strategy takes `scale_multiple = m` (a multiple of the consensus
set's scale), `loss_width = w` (an absolute width), or neither, in which case
its loss width follows the scorer's inlier threshold. See the
[Overview](../overview.md).

## Half-quadratic lifts and graduated non-convexity

```@docs
HQ
WelschHQNewton
WelschHQEcm
BarronHQ
Gnc
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

## PoseLib truncated refiners

External refiners (VisualGeometryToolkitCore's `ExternalRefit`): they refine a seed at
an absolute loss width through `refine_external!`, outside the RANSAC loop. The
solver calls load with PoseLib (a package extension). See
[Baselines](../guide/baselines.md).

```@docs
PoseLibLm
PoseLibLZ
PoseLibLmAdaptLossWidth
truncated_refit_pose
```

## Cross-validated operating points

```@docs
tuning_constant
TuningConstant
TuningProvenance
WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL
WELSCH_HQ_SCALE_MULTIPLE_FUNDMAT
WELSCH_HQ_SCALE_MULTIPLE_HOMOGRAPHY
WELSCH_HQ_SCALE_MULTIPLE_ABSOLUTE_POSE
```

## TOML registry

```@docs
LO_TAGS
```

## Index

```@index
```
