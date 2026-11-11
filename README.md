# LocalOptimizationDoneRight.jl

[![CI](https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://localoptimizationdoneright.github.io)
[![Coverage](https://codecov.io/gh/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/branch/main/graph/badge.svg)](https://app.codecov.io/gh/VisualGeometryToolkit/LocalOptimizationDoneRight.jl)

LocalOptimizationDoneRight provides the local optimizers of the ACCV 2026 paper
[Robust Local Optimization Done Right](https://arxiv.org/abs/2610.05743)
(James Pritts and Kevin Köser): half-quadratic lifts, graduated non-convexity,
Student-t + uniform reweighting and PoseLib's truncated refiners, for the
refinement step of a RANSAC. Each one implements VisualGeometryToolkitCore's
local-optimization contract, so it composes with any scorer in
VisualGeometryToolkitEstimation's `find_*` estimators.

## Installation

The package requires Julia 1.12 or later. The example below also loads the
packages it composes with:

```julia-repl
pkg> add LocalOptimizationDoneRight VisualGeometryToolkitEstimation VisualGeometryToolkitCore
```

## Example

The paper's recipe, Student-t + uniform selection and Welsch half-quadratic
refinement at its cross-validated efficiency constant, on a synthetic two-view scene:

```julia
using Random: MersenneTwister
using VisualGeometryToolkitCore: CameraModel, Point2, WelschShape, estimate, motion, px
using VisualGeometryToolkitCore: StudentTUniformScoring, JeffreysPrior, FlatLabelPrior
using VisualGeometryToolkitCore.Synthetic: pose_error, sample_twoview_scene
using VisualGeometryToolkitEstimation: EssentialProblem, find_essential
using LocalOptimizationDoneRight: HQ, WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL

# Two 500 × 500 px views of one pinhole camera (focal length 600 px, principal
# point at the image centre): 200 matches with 1 px noise, then 100 mismatches
# drawn anywhere in the image.
rng = MersenneTwister(1)
R, t, _, _, matches = sample_twoview_scene(rng, 200; f = 600.0, c = 250.0)
noisy(u) = u + Point2(randn(rng), randn(rng))
anywhere() = Point2(500 * rand(rng), 500 * rand(rng))
cs = [[u₁ => noisy(u₂) for (u₁, u₂) in matches]; [anywhere() => anywhere() for _ in 1:100]]
camera = CameraModel(600.0px, Point2(250.0px, 250.0px))

# Student-t + uniform selection, its outlier half-width 250 px (half the image),
# the scale integrated out against Jeffreys' prior and the labels flat, then
# Welsch half-quadratic refinement at its cross-validated multiple of the
# consensus set's scale.
result = find_essential(camera, camera, cs;
    scoring = StudentTUniformScoring(EssentialProblem, 250.0; scale_prior = JeffreysPrior(), label_prior = FlatLabelPrior()),
    local_optimization_strategy = HQ{WelschShape}(; efficiency_constant = WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL),
    rng = MersenneTwister(2))

n_inliers = count(result.inlier_mask)   # the 200 matches, and the few mismatches that land on their epipolar lines
# Rotation and translation-direction errors in degrees, against the closest of
# the four motions (R, t) the estimated essential matrix factors into.
rotation_error, translation_error =
    rad2deg.(minimum(pose_error(Rᵢ, tᵢ, R, t) for (Rᵢ, tᵢ) in motion(estimate(result))))
```

The [Overview](https://localoptimizationdoneright.github.io/overview/) introduces
every strategy, its width modes and how it composes with a scorer.

## Documentation

- [Home](https://localoptimizationdoneright.github.io): the paper's results, installation and this example.
- [Overview](https://localoptimizationdoneright.github.io/overview/): the strategies, their width modes, scorers and TOML configuration.
- [Reproducing the paper](https://localoptimizationdoneright.github.io/guide/reproducing/): every figure and table from its config and driver.
- [Baselines](https://localoptimizationdoneright.github.io/guide/baselines/): the classical LO arms (PoseLib, RansacLib).
- [API Reference](https://localoptimizationdoneright.github.io/api/strategies/).

The package builds on [VisualGeometryToolkitCore](https://visualgeometrytoolkit.github.io/VisualGeometryToolkitCore/stable/)
(the contracts and losses, the Student-t + uniform scorer among them) and [VisualGeometryToolkitEstimation](https://visualgeometrytoolkit.github.io/VisualGeometryToolkitEstimation/stable/)
(the problems and the RANSAC loop); the paper's scoring companion is [RANSACScoringDoneRight](https://ransacscoringdoneright.github.io). The
[Visual Geometry Toolkit portal](https://visualgeometrytoolkit.github.io) links them all.

## Citing

```bibtex
@inproceedings{Pritts2026LocalOptimization,
  title     = {Robust Local Optimization Done Right},
  author    = {Pritts, James and K{\"o}ser, Kevin},
  booktitle = {Asian Conference on Computer Vision (ACCV)},
  year      = {2026},
  eprint    = {2610.05743},
  archivePrefix = {arXiv}
}
```

If you use the paper project's RansacLib arms, also cite RansacLib and Lebeda,
Matas and Chum (BMVC 2012); see
[Baselines](https://localoptimizationdoneright.github.io/guide/baselines/).

## License

MIT (see `LICENSE`). The vendored RansacLib keeps its BSD-3-Clause licence.
