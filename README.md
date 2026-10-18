# Robust Local Optimization Done Right — ACCV 2026

[![CI](https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://localoptimizationdoneright.github.io)

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

Code for the ACCV 2026 paper "Robust Local Optimization Done Right" (Score
Sharp, Refine Soft; [arXiv](https://arxiv.org/abs/2610.05743)), in two halves:
the registered package `LocalOptimizationDoneRight` — the paper's local
optimizers, ready to compose into any RANSAC of the stack — and the research
project `accv2026/` that produces every figure and table. Both, with the
package's tests and docs, are one Pkg workspace: they resolve together, in one
`Manifest.toml` at the repository root that is not committed.

## Install

`LocalOptimizationDoneRight` and the packages it builds on are registered in the
Julia General registry (Julia 1.12+):

```julia
using Pkg; Pkg.add("LocalOptimizationDoneRight")
```

To reproduce the paper, clone the repository and instantiate `accv2026/` (see
[Reproducing the paper](#reproducing-the-paper)).

## Use

The strategies implement VisualGeometryToolkitCore's local-optimization contract, so
they plug into VisualGeometryToolkitEstimation's `find_*` pipelines and `ransac` beside any
scorer. The core default is MSAC with a truncated-least-squares IRLS; the
paper's recipe swaps in RansacScoringDoneRight's Student-t + uniform scorer and
the Welsch half-quadratic lift at its cross-validated scale multiple:

```julia
using VisualGeometryToolkitEstimation, RansacScoringDoneRight, LocalOptimizationDoneRight
using VisualGeometryToolkitCore: WelschShape

result = find_essential(cam1, cam2, pixel_pairs;
    scoring = StudentTUniformScoring(EssentialProblem, outlier_halfwidth),
    local_optimization = HQ{WelschShape}(; scale_multiple = WELSCH_HQ_SCALE_MULTIPLE_ESSENTIAL))
```

From TOML, merge the strategy registries:
`local_optimization_from_toml(d; class, tags = merge(VisualGeometryToolkitEstimation.LO_TAGS, LocalOptimizationDoneRight.LO_TAGS))`.

## Layout

```
src/LocalOptimizationDoneRight.jl   module: imports, includes, the API
src/strategies/        the strategies (HQ, Gnc, StudentTUniform, StuTuBCD,
                       BarronAdaptive, the research variants), LO_TAGS, TOML IO
src/lift/              the joint-(θ,z) lift core and the continuation schedules
src/tuning_constants.jl  the cross-validated operating points (tuning_constant)
src/poselib_arms.jl    PoseLib's truncated refiners (PoseLibLm, PoseLibLZ,
                       PoseLibLmAdaptLossWidth); solver calls in ext/
ext/                   the PoseLib package extension
configs/default.toml   the strategies' defaults of record and tuning constants
test/                  the package's tests (strategies, lift core, gates, LO timing)
docs/                  the documentation site (Documenter)
accv2026/              the research project (DrWatson layout, devs this package):
  Project.toml         every dependency the drivers need (`@quickactivate "ACCV2026"`)
  src/                 the shared prelude (config.jl entry: registry, cells, splits,
                       folds) and the paper's arm rosters
  scripts/             the experiment drivers (one file per figure/table/cell)
  scripts/tools/       the CLIs the drivers launch (CV engines, renderers, builders)
  scripts/slurm/       an example Slurm wrapper and the pool launcher
  configs/             configs of record (each cell's TOML; protocols folded into run keys)
  lib/RansacLibLO/     the classical RansacLib LO baseline (vendored, unregistered)
  envs/                auxiliary environments (SupeRANSAC)
  data/                exp_raw / exp_pro symlinks (per machine)
  paper/               the manuscript; renders land in paper/figures/
  test/                the project's tests (`julia --project=. test/runtests.jl`)
  REPRODUCE.md         the experiment → artifact index and provenance
```

## Relationship to the stack

VisualGeometryToolkitCore owns the contracts (scoring, local optimization, external
refit, chart rows); VisualGeometryToolkitEstimation owns the problems, the one generic
RANSAC loop and the core baselines (`NoLocalOptimization`, `Irls{K}`). This
package depends on those two only (PoseLib is a weak dependency). The
evaluation engine the paper runs on — pair geometry, the one refit layer,
post-LO matrices, the sample-budget engine, live runs, `Roster` and its
gate-enforced readers, the selection stream — is `VisualGeometryToolkitEval.Evaluation`,
written against the contracts alone. The split rule:

| Belongs in the package | Belongs in `accv2026/` |
|---|---|
| the local optimizers a second paper reuses | paper drivers, figures, arm rosters |
| registered LO baselines (PoseLib) | the unregistered RansacLib baseline; anything that exists to make one comparison defensible |

## The RansacLib LO baseline

Torsten Sattler's [RansacLib](https://github.com/tsattler/RansacLib) LO-MSAC
(Lebeda–Matas–Chum, BMVC 2012), run unmodified, as a seeded local optimization
for E/F/H. It lives in the research project: `accv2026/lib/RansacLibLO` wraps
it in a small C++ shim and is not registered, and its two arms
(`LebedaIterLO`, `LebedaLOPlus`, in `accv2026/src/lebeda_lo.jl`) are external
refiners on VisualGeometryToolkitCore's contract (`external_workspace`,
`refine_external!`), refit by the evaluation engine like the PoseLib arms. `accv2026/Project.toml`
devs it by path.

RansacLib is vendored **byte-identical at commit `b952083`**, with `LICENSE` and
`NOTICE` retained (BSD-3-Clause), so the artifact builds offline. Building the
shim needs `git` and a C++17 `g++`; Eigen comes from `Eigen_jll` (set
`EIGEN_INCLUDE` to use another copy).

## Reproducing the paper

```bash
git clone https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl.git
cd LocalOptimizationDoneRight.jl/accv2026
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.build("RansacLibLO")'
julia --project=. scripts/fig3_composed_miscal.jl --plan
```

Bind the data and results roots first: the `accv2026/data/exp_raw` (immutable
inputs) and `accv2026/data/exp_pro` (add-only results) symlinks, or the
`CAU_DATA_ROOT` / `CAU_RESULTS_ROOT` environment variables — see
`accv2026/data/README.md`. `accv2026/REPRODUCE.md` maps every figure and table
to its config of record and driver and records the data provenance. The
cross-validation stages need a CUDA GPU.

Nothing large is committed. What the paper shows is tracked as the rendered
`.tex` figures and tables under `accv2026/paper/figures/`; the result
artifacts themselves are not yet published.

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

If you use the RansacLib arms, also cite RansacLib (Sattler et al., 2019) and
Lebeda, Matas and Chum (BMVC 2012).

## License

MIT (see `LICENSE`). The vendored RansacLib keeps its BSD-3-Clause licence.
