# Overview

```@meta
CurrentModule = LocalOptimizationDoneRight
```

`LocalOptimizationDoneRight` holds the local optimizers (LO) of the ACCV 2026
paper *Robust Local Optimization Done Right*: the strategies the paper proposes,
the alternatives it studies, and the research variants behind its ablations.
They implement VisualGeometryCore's local-optimization contract, so each one
composes with any scorer in RobustVisualGeometry's RANSAC. The repository has two
halves:

| | |
|:---|:---|
| **the package** (`src/`, `ext/`) | the strategies, the joint-(θ,z) lift core and its continuation schedules, the cross-validated operating points, the strategies' TOML registry, and PoseLib's truncated refiners (a package extension) |
| **the research project** (`accv2026/`) | the paper's arm rosters, configs, drivers, renderers, the RansacLib baseline and the manuscript; see [Reproducing the paper](guide/reproducing.md) |

The package depends on VisualGeometryCore (the contracts, the losses, the width
axes) and RobustVisualGeometry (the problems, the RANSAC loop, the core
baselines `NoLocalOptimization` and `Irls{K}`). PoseLib is a weak dependency.

## Scoring versus refinement

RANSAC asks two different questions of a robust objective. **Scoring** ranks
minimal-sample hypotheses and must be sharp: a single wrong inlier set loses the
pair. **Refinement** moves the selected hypothesis toward the solution and needs a
soft objective: gradient from correspondences that the seed currently rejects.
The stack keeps the two roles behind separate contracts, so a scorer and a local
optimizer are chosen independently:

```julia
using RobustVisualGeometry, RansacScoringDoneRight, LocalOptimizationDoneRight
using VisualGeometryCore: WelschShape

# the core default: MSAC at the class's threshold + TLS-IRLS following it
result = find_essential(cam1, cam2, pixel_pairs)

# the paper's recipe: Student-t + uniform selection, Welsch-HQ refinement
result = find_essential(cam1, cam2, pixel_pairs;
    scoring = StudentTUniformScoring(EssentialProblem, outlier_halfwidth),
    local_optimization = HQ{WelschShape}(; scale_multiple = WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL))
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

The lifts run on VisualGeometryCore's chart-rows contract, which
RobustVisualGeometry implements per problem, so one code path serves every
liftable problem; see [Lift core and schedules](api/lift.md).

## Widths

A width-carrying strategy (`HQ`, `Gnc`, `WelschHQNewton`, `BarronHQ`, `GmHqEps`,
`BarronAdaptive`, and the core `Irls`) holds its width mode as a type parameter,
resolved once per call by VisualGeometryCore's `loss_at`:

- `scale_multiple = m` (`ScaleMultiple(m)`): the loss width is `m·ŝ`, with `ŝ`
  the scale of the consensus set the scorer selected (the paper's *partition
  anchoring*);
- `loss_width = w` (`LossWidth(w)`): an absolute width, in the caller's units;
- neither: the width follows the scorer. The loss's decision point is placed at
  the scorer's `inlier_threshold`; a scorer without one is refused at entry.

`with_width(lo, w)` returns the same strategy at another width mode. The
self-scaling strategies (`StudentTUniform`, `StuTuBCD`, `WelschHQEcm`, the
mixture lifts) carry no width; they start from the consensus scale.

## External refiners

PoseLib's truncated refiners are `ExternalRefit` strategies: they refine a seed
at an absolute loss width through VisualGeometryCore's external-refit contract
(`external_workspace`, `prepare_external!`, `refine_external!`), outside the
RANSAC loop. The PoseLib package extension implements those methods. The paper
project's RansacLib arms implement the same contract; see
[Baselines](guide/baselines.md).

## Operating points and TOML

[`tuning_constant`](@ref)`(problem, shape; features, dataset)` returns the
cross-validated scale multiple of a loss on a model class, with its provenance
(the accv2026 config that produced it); the `WELSCH_HQ_SCALE_MULTIPLE_*`
constants are its Welsch-HQ entries.

[`LO_TAGS`](@ref) registers the strategies' TOML tags. Merge it with the core's
to load a `[local_optimization]` table of either package:

```julia
lo = local_optimization_from_toml(d; class = :essential,
    tags = merge(RobustVisualGeometry.LO_TAGS, LocalOptimizationDoneRight.LO_TAGS))
```

In such a table, `scale_multiple = "cross_validated"` resolves through
[`tuning_constant`](@ref).

## Evaluation

The paper's evaluation engine (pair geometry, the one refit layer, post-LO error
matrices, the sample-budget engine, live RANSAC runs, the `Roster` of arms and
its gate-enforced readers, the selection stream) is
`VisualGeometryEval.Evaluation`, written against the core contracts alone. It
evaluates any strategy here without per-type code: a native strategy through
`locally_optimize!`, an external one through `refine_external!`.

## Defaults of record

Every strategy default lives in `configs/default.toml`, read through one
function, `_config_default(table, key)`, which throws on a missing table or key;
there is no second set of Julia literals. The file is parsed at precompile time,
so an edit forces a recompile.

| table | holds |
|:---|:---|
| `[local_optimization.<tag>]` | each strategy's defaults (`max_iter`, damping, schedule), keyed by its `LO_TAGS` tag |
| `[local_optimization.poselib]` | `cheirality_vote_points`: points in the cheirality vote of an E decomposition |
| `[local_optimization.poselib_adapt]` | [`PoseLibLmAdaptLossWidth`](@ref)'s total budget, rounds, `min_support` and operating scale multiple |
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
