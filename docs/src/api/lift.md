# Lift core and schedules

```@meta
CurrentModule = LocalOptimizationDoneRight
```

The joint-(θ,z) machinery behind [`HQ`](@ref), [`Gnc`](@ref) and the research
lifts. It runs on VisualGeometryCore's chart-rows contract (`rows_provider`,
`lift_init`, `lift_refresh!`, `lift_jacobian!`, `lift_retract`, …), which
RobustVisualGeometry implements for its problems, so one code path serves every
liftable problem.

## Lift state and z-blocks

```@docs
LiftState
lift_state
LiftZBlock
JointGaussNewton
WelschConvexNewton
lift_window
TabulatedLift
tabulate!
cubic_hermite
lift_raw_window
```

## Continuation schedules

```@docs
LoSchedule
NoSchedule
MuLadder
with_converged_rung
gnc_schedule
GeometricAnneal
```
