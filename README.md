# Robust Local Optimization Done Right — ACCV 2026

[![CI](https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://localoptimizationdoneright.github.io)
[![Coverage](https://codecov.io/gh/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/branch/main/graph/badge.svg)](https://app.codecov.io/gh/VisualGeometryToolkit/LocalOptimizationDoneRight.jl)

## Abstract

**[Robust Local Optimization Done Right](https://arxiv.org/abs/2610.05743)** — James Pritts and Kevin Köser. *ACCV 2026*. [Project page](https://localoptimizationdoneright.github.io).

RANSAC scoring and local optimization (LO) impose different robustness
requirements, motivating the separation of hypothesis selection from
refinement. We systematically isolate the effects of robust-loss shape,
incorrectly specified inlier scales, and optimization strategy on essential
matrix, fundamental matrix, and homography estimation. A profile-marginal score
marginalizes the nuisance inlier scale and selects an inlier partition, from
which we estimate the scale that sets the LO loss width; this makes LO robust
to an inlier scale specified too large, whereas one specified too small
degrades selection itself. Refinement needs gradient from correspondences the
seed currently rejects: optimizers that reweight from current residuals stay
pinned to their seed, whereas methods with broad basins recover strongly
perturbed seeds yet degrade accurate score-selected hypotheses, so basin size
alone is insufficient to assess RANSAC LO. Joint half-quadratic optimization
balances the two and is the most consistent strategy across model classes. An
optimizer matched to the profile-marginal score, which never decreases it, does
not reach the best accuracy, challenging the prescription that scoring and
refinement objectives should match. Composed from these findings, our RANSAC
reduces the median essential-matrix pose error of a state-of-the-art RANSAC on
PhotoTourism from 2.23 degrees to 1.58 degrees with a correctly specified
inlier scale and from 38 degrees to 6.2 degrees when it is grossly misspecified
(128x too large).

## Overview

`LocalOptimizationDoneRight` holds the paper's local optimizers, ready to
compose into any RANSAC of the VisualGeometryToolkit stack. The research
project `accv2026/` in this repository produces every figure and table; the
[documentation](https://localoptimizationdoneright.github.io) covers the
strategies, the [reproduction](https://localoptimizationdoneright.github.io/guide/reproducing/)
and the [classical baselines](https://localoptimizationdoneright.github.io/guide/baselines/).

## Install

The package requires Julia 1.12 or later. The example below also uses the
stack packages it composes with (VisualGeometryToolkitCore,
VisualGeometryToolkitEstimation and RANSACScoringDoneRight) and StaticArrays:

```julia-repl
pkg> add LocalOptimizationDoneRight VisualGeometryToolkitEstimation VisualGeometryToolkitCore RANSACScoringDoneRight StaticArrays
```

Until the General registration of `LocalOptimizationDoneRight` merges, add
[CauRegistry](https://github.com/prittjam/CauRegistry.jl) first:

```julia-repl
pkg> registry add https://github.com/prittjam/CauRegistry.jl
```

## Use

The strategies implement VisualGeometryToolkitCore's local-optimization contract, so
they plug into VisualGeometryToolkitEstimation's `find_*` pipelines and `ransac` beside any
scorer. The core default is MSAC with a truncated-least-squares IRLS; the
paper's recipe swaps in RANSACScoringDoneRight's Student-t + uniform scorer and
the Welsch half-quadratic lift at its cross-validated scale multiple. On a
synthetic two-view scene:

```julia
using Random: MersenneTwister
using StaticArrays: SA
using VisualGeometryToolkitCore: CameraModel, Point2, WelschShape, estimate, motion, px
using VisualGeometryToolkitCore.Synthetic: pose_error, sample_twoview_scene
using VisualGeometryToolkitEstimation: EssentialProblem, find_essential
using RANSACScoringDoneRight: StudentTUniformScoring
using LocalOptimizationDoneRight: HQ, WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL

# Two 500 × 500 px views of one pinhole camera (focal length 600 px, principal
# point at the image centre): 200 matches with 1 px noise, then 100 mismatches
# drawn anywhere in the image.
rng = MersenneTwister(1)
R, t, _, _, matches = sample_twoview_scene(rng, 200; f = 600.0, c = 250.0)
noisy(u) = u + Point2(randn(rng), randn(rng))
anywhere() = Point2(500 * rand(rng), 500 * rand(rng))
cs = [[u₁ => noisy(u₂) for (u₁, u₂) in matches]; [anywhere() => anywhere() for _ in 1:100]]
camera = CameraModel(600.0px, SA[250.0px, 250.0px])

# Student-t + uniform selection, its outlier half-width 250 px (half the image),
# then Welsch half-quadratic refinement at its cross-validated multiple of the
# consensus set's scale.
result = find_essential(camera, camera, cs;
    scoring = StudentTUniformScoring(EssentialProblem, 250.0),
    local_optimization = HQ{WelschShape}(; scale_multiple = WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL),
    rng = MersenneTwister(2))

n_inliers = count(result.inlier_mask)   # the 200 matches, and the few mismatches that land on their epipolar lines
# Rotation and translation-direction errors in degrees, against the closest of
# the four motions (R, t) the estimated essential matrix factors into.
rotation_error, translation_error =
    rad2deg.(minimum(pose_error(Rᵢ, tᵢ, R, t) for (Rᵢ, tᵢ) in motion(estimate(result))))
```

From TOML, merge the strategy registries:
`local_optimization_from_toml(d; class, tags = merge(VisualGeometryToolkitEstimation.LO_TAGS, LocalOptimizationDoneRight.LO_TAGS))`.
The [Overview](https://localoptimizationdoneright.github.io/overview/) introduces
every strategy, its width modes and how it composes with a scorer.

## Citation

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
