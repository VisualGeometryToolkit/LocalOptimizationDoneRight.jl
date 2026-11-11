# Overview

```@meta
CurrentModule = LocalOptimizationDoneRight
```

`LocalOptimizationDoneRight` holds the local optimizers (LO) of the ACCV 2026
paper *Robust Local Optimization Done Right*: the strategies the paper proposes,
the alternatives it studies, and the research variants behind its ablations.
They implement VisualGeometryToolkitCore's local-optimization contract, so each one
composes with any scorer in VisualGeometryToolkitEstimation's RANSAC. The repository has two
halves:

| | |
|:---|:---|
| **the package** (`src/`, `ext/`) | the strategies, the joint-(θ,z) lift core and its continuation schedules, the cross-validated operating points, the strategies' TOML registry, and PoseLib's truncated refiners (a package extension) |
| **the research project** (`accv2026/`) | the paper's arm rosters, configs, drivers, renderers, the RansacLib baseline and the manuscript; see [Reproducing the paper](guide/reproducing.md) |

The package depends on VisualGeometryToolkitCore (the contracts, the losses, the width
axes) and VisualGeometryToolkitEstimation (the problems, the RANSAC loop, the core
baselines `nothing` (no local optimization) and `Irls{K}`). PoseLib is a weak dependency.

## Scoring versus refinement

RANSAC asks two different questions of a robust objective. **Scoring** ranks
minimal-sample hypotheses and must be sharp: a single wrong inlier set loses the
pair. **Refinement** moves the selected hypothesis toward the solution and needs a
soft objective: gradient from correspondences that the seed currently rejects.
The stack keeps the two roles behind separate contracts, so a scorer and a local
optimizer are chosen independently. With the `camera` and the pixel
correspondences `cs` of the [Getting started](index.md#Getting-started) scene:

```julia
using VisualGeometryToolkitEstimation, LocalOptimizationDoneRight
using VisualGeometryToolkitCore: WelschShape, StudentTUniformScoring, JeffreysPrior, FlatLabelPrior

# the core default: MSAC at the class's threshold + TLS-IRLS following it
result = find_essential(camera, camera, cs)

# the paper's recipe: Student-t + uniform selection (outlier half-width 250 px),
# Welsch-HQ refinement
result = find_essential(camera, camera, cs;
    scoring = StudentTUniformScoring(EssentialProblem, 250.0; scale_prior = JeffreysPrior(), label_prior = FlatLabelPrior()),
    local_optimization_strategy = HQ{WelschShape}(; efficiency_constant = WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL))
```

## Strategies

| strategy | path | what it does |
|:---|:---|:---|
| [`HQ`](@ref)`{K}` | `:hq` | joint-(θ,z) half-quadratic lift on loss `K`; the paper's method (Welsch-HQ) |
| [`WelschHQNewton`](@ref), [`WelschHQEcm`](@ref), [`BarronHQ`](@ref), `GmHqEps` | `:hq` | research variants of the lift |
| [`Gnc`](@ref)`{Irls{K}}` | `:gnc` | graduated non-convexity over a core IRLS |
| [`StudentTUniform`](@ref) | `:irls` | the Student-t + uniform mixture IRLS (EM), self-scaling |
| [`StuTuBCD`](@ref) | `:bcd` | block-coordinate ascent of the scorer's own objective (the score-matched optimizer) |
| [`StuTuHQTabulated`](@ref), [`StuTuRegemm`](@ref) | `:hq`, `:gnc` | mixture lifts |
| [`BarronAdaptive`](@ref) | `:irls` | Barron's adaptive loss under IRLS |
| [`PoseLibLm`](@ref), [`PoseLibLZ`](@ref), [`PoseLibLmAdaptLossWidth`](@ref) | `:irls`, `:gnc` | PoseLib's truncated refiners (external refiners) |

The lifts run on VisualGeometryToolkitCore's chart-rows contract, which
VisualGeometryToolkitEstimation implements per problem, so one code path serves every
liftable problem; see [Lift core and schedules](api/lift.md).

## Widths

A width-carrying strategy (`HQ`, `Gnc`, `WelschHQNewton`, `BarronHQ`, `GmHqEps`,
`BarronAdaptive`, and the core `Irls`) holds its width mode as a type parameter,
resolved once per call by VisualGeometryToolkitCore's `loss_at`:

- `efficiency_constant = m` (`EfficiencyConstant(m)`): the loss width is `m·ŝ`, with `ŝ`
  the scale of the consensus set the scorer selected (the paper's *partition
  anchoring*). `m` is always the plain multiple of the scale, whatever the
  loss shape;
- `loss_width = w` (`LossWidth(w)`): an absolute width, in the caller's units;
- neither: the width follows the scorer. The loss's decision point is placed at
  the scorer's `decision_boundary`; a scorer without one is refused at entry.

Give at most one of `efficiency_constant` and `loss_width`. The
cross-validated constants of [Operating points and TOML](#Operating-points-and-TOML)
are efficiency constants, tuned per model class.

`with_width(lo, w)` returns the same strategy at another width mode. The
self-scaling strategies (`StudentTUniform`, `StuTuBCD`, `WelschHQEcm`, the
mixture lifts) carry no width; they start from the consensus scale.

## External refiners

PoseLib's truncated refiners are `ExternalRefit` strategies: they refine a seed
at an absolute loss width through VisualGeometryToolkitCore's external-refit contract
(`external_workspace`, `prepare_external!`, `refine_external!`), outside the
RANSAC loop. The PoseLib package extension implements those methods. The paper
project's RansacLib arms implement the same contract; see
[Baselines](guide/baselines.md).

## Operating points and TOML

[`tuning_constant`](@ref)`(problem, shape; features, dataset)` returns the
cross-validated efficiency constant of a loss on a model class, with its provenance
(the accv2026 config that produced it); the `WELSCH_HQ_EFFICIENCY_CONSTANT_*`
constants are its Welsch-HQ entries.

[`LODR_STRATEGY_TAGS`](@ref) registers the strategies' TOML tags. Merge it with the core's
to read a strategy table of either package, such as a `find_*` pipeline's
`local_optimization_strategy = { type = "hq", loss = "welsch", … }`:

```julia
lo = optimization_strategy_from_toml(d; class = :essential,
    tags = merge(VisualGeometryToolkitEstimation.LO_TAGS, LocalOptimizationDoneRight.LODR_STRATEGY_TAGS))
```

In such a table, `efficiency_constant = "cross_validated"` resolves through
[`tuning_constant`](@ref).

## Evaluation

The paper's evaluation engine (pair geometry, the one refit layer, post-LO error
matrices, the sample-budget engine, live RANSAC runs, the `Roster` of arms and
its gate-enforced readers, the selection stream) is
`VisualGeometryToolkitEval.Evaluation`, written against the core contracts alone. It
evaluates any strategy here without per-type code: a native strategy through
`locally_optimize!`, an external one through `refine_external!`.

## Defaults of record

Every strategy default lives in `configs/default.toml`, read through one
function, `_config_default(table, key)`, which throws on a missing table or key;
there is no second set of Julia literals. The file is parsed at precompile time,
so an edit forces a recompile.

| table | holds |
|:---|:---|
| `[optimization_strategy.<tag>]` | each strategy's defaults (`max_iter`, damping, schedule), keyed by its `LODR_STRATEGY_TAGS` tag |
| `[optimization_strategy.poselib]` | `cheirality_vote_points`: points in the cheirality vote of an E decomposition |
| `[optimization_strategy.poselib_adapt]` | [`PoseLibLmAdaptLossWidth`](@ref)'s total budget, rounds, `min_support` and operating efficiency constant |
| `[[tuning_constants]]` | the cross-validated operating points with their provenance |

A paper with its own protocol states its values explicitly; the ACCV 2026
protocol of record is `accv2026/configs/protocol.toml`.

## Frames

Frame in, frame out: public functions return results in the frame their inputs
came in. The one declared exception is the benchmark pool, stored in
`NormalizedImageFrame`; every API where pool data enters or leaves names that
frame. Calibrated geometry is on unit bearings, except for the vendored
RansacLib essential-matrix arm, a declared third-party pinhole exception (see
[Baselines](guide/baselines.md)).
