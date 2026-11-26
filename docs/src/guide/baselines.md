# Baselines

```@meta
CurrentModule = LocalOptimizationDoneRight
```

The paper compares its local optimizers with two families of established
refiners, both run as `ExternalRefit` strategies (VisualGeometryToolkitCore's external
refit contract: `external_workspace`, `external_refit!`) through the same refit
layer (`VisualGeometryToolkitEval.Evaluation`) and under the same LO budget as every
other arm: PoseLib's truncated refiners (in
the package) and RansacLib's classical LO-MSAC (in the paper project
`accv2026/`, see below). They are evaluation-only: they refine a selected seed
at an absolute loss width, never inside the native RANSAC loop.

| arm | strategy | what runs |
|:---|:---|:---|
| TLS-IRLS | `BackendRefit(LevenbergMarquardt(PoseLibSolver(); optimization_strategy = Irls{TLSShape}()), LmStops(; max_iter))` | PoseLib Levenberg–Marquardt on the truncated Sampson loss (`TLSShape`) |
| TLS-LZ | `BackendRefit(LevenbergMarquardt(PoseLibSolver(); optimization_strategy = LeZach()), LmStops(; max_iter))` | PoseLib's Le–Zach relaxed IRLS on the same truncated loss |
| TLS-IRLS-ŝ | `BackendRefit(`[`AdaptiveLossWidthRefit`](@ref)`(), LmStops(; max_iter))` | TLS-IRLS with a partition-anchored width, re-estimated between rounds (E only) |
| TLS-LO | `LebedaIterLO(opts, rng_seed)` (accv2026) | RansacLib's iterative least-squares ladder alone |
| TLS-LO⁺ | `LebedaLOPlus(opts, rng_seed)` (accv2026) | RansacLib's full LO: least squares at the enlarged width, inner non-minimal resampling, per-sample ladder |

## PoseLib truncated refiners

PoseLib's truncated refiners are VisualGeometryToolkitCore's `BackendRefit` of its
Levenberg–Marquardt with PoseLib's backend, `LevenbergMarquardt(PoseLibSolver();
optimization_strategy)`, at `stops = LmStops(; max_iter)` (the paper runs them at the
evaluation's equal LO budget). They refine relative pose (an essential seed's
cheirality-resolved pose on the pool-frame pixels with the two cameras), fundamental
matrices and homographies at the absolute loss width the refit hands `external_refit!`
(a `LossWidth`); the solves are Core's and PoseLib's (`import PoseLib`).

The consensus-anchored arm, TLS-IRLS-ŝ, is this package's refine algorithm
[`AdaptiveLossWidthRefit`](@ref): PoseLib's truncated LM in `rounds`, its loss width
re-estimated between them from the refined pose's within-width residuals. It refines a
[`RelativePoseRefitProblem`](@ref), which holds both the pixels and calibrations it refines
on and the unit bearings its scale moment reads:

```julia
# Illustrative: `K1`, `K2` the cameras' calibrations, `cs` the pixel correspondences, `ep` the pair's
# EssentialProblem, `pose₀` a relative pose, `s2` a start scale
f = RelativePoseRefitProblem(RelativePoseProblem(K1, K2, cs), ep)
pose = solve(RefineProblem(f, pose₀), AdaptiveLossWidthRefit(); stops = LmStops(; max_iter = 25), scale = FixedS2(s2)).u
```

As an external refiner, `BackendRefit(AdaptiveLossWidthRefit(), LmStops(; max_iter = 25))`
bootstraps its start scale from the seed's consensus set (outside the timing bracket) and
seeds the pose by the essential seed's cheirality vote.

## RansacLib LO (RansacLibLO)

`accv2026/lib/RansacLibLO` wraps Torsten Sattler's
[RansacLib](https://github.com/tsattler/RansacLib) LO-MSAC (Lebeda, Matas and
Chum, BMVC 2012), **run unmodified** as a seeded local optimization for E, F and H.

- **Vendored byte-identical.** RansacLib is vendored at upstream commit
  `b952083` with its `LICENSE` and `NOTICE` (BSD-3-Clause), and declared in
  `VENDORED.toml` as upstream code outside the stack's naming rules. Vendoring
  removes the network dependency from the reproduction path.
- **The only code added** is what RansacLib's template API asks of a user — the
  E/F/H solver plug-ins and their Sampson residuals — and a subclass that exposes
  the protected `LocalOptimization` / `LeastSquaresFit` entries so the LO runs
  from a caller-supplied seed.
- **Configuration** is RansacLib's public `LORansacOptions` subset
  (`LebedaLOOptions`). `PRESET_REFERENCE` is RansacLib's own defaults; the paper
  builds budget-parity options from its protocol of record
  (`accv2026/configs/protocol.toml`, `[arms.lebeda]`). Both the options and the
  `rng_seed` are required: they are protocol values of the caller.
- **Deterministic.** RansacLib's per-call `mt19937(rng_seed)` is its only source
  of randomness, so identical inputs give identical outputs. The wrapper also
  reports the number of linear solves per call, the budget-parity audit.
- **Part of the paper project, not the package.** `RansacLibLO` builds a C++
  shim locally and is not registered, so the registered
  `LocalOptimizationDoneRight` does not depend on it. The paper project devs it
  by path (`[sources]` in `accv2026/Project.toml`), and the two arms
  (`accv2026/src/lebeda_lo.jl`) implement VisualGeometryToolkitCore's external refit
  contract (`external_workspace`, `external_refit!`), like any third-party
  strategy.

Building it compiles a small C++ shim and needs `git` and a C++17 `g++`; Eigen
comes from `Eigen_jll` (set `EIGEN_INCLUDE` to use another copy). From
`accv2026/`:

```julia
using Pkg; Pkg.instantiate(); Pkg.build("RansacLibLO")
```

### Loss width and frames

The refit's loss width is the absolute, unsquared truncation width in the pool
frame — the same currency the PoseLib arms consume. RansacLibLO takes the
*squared* width in the frame of its input points, so the wrapper converts once:

- **F and H** — the pool frame is the model frame: pool-frame points, seed and
  width go through unconverted. On H the shim scores the codimension-2 Sampson
  error of the transfer constraint, whereas PoseLib's truncated H path truncates
  the symmetric transfer error: the same width, a different residual.
- **E** — RansacLib's essential solver projects onto the essential manifold,
  which is valid only for calibrated coordinates. The wrapper feeds it calibrated
  points on the z = 1 plane, converted once from the pool frame by the stored
  pool-frame calibration `Kc`, and converts the width with exactly PoseLib's
  camera-aware rule, `½(1/f₁ + 1/f₂)`, so TLS-IRLS, TLS-LZ and TLS-LO⁺ consume the
  same pool-frame width.

This E arm is a **declared pinhole exception**. Calibrated geometry in the stack
is otherwise on unit bearings from the camera's back-projection, never the z = 1
plane; RansacLib is third-party code run unmodified, so its essential solver's
plane-point convention is accepted here, pinhole-only, and declared where it
lives.

### Citing

If you use the RansacLib arms, cite RansacLib and Lebeda et al.:

```bibtex
@misc{Sattler2019Github,
  title  = {{RansacLib - A Template-based *SAC Implementation}},
  author = {Torsten Sattler and others},
  URL    = {https://github.com/tsattler/RansacLib},
  year   = {2019}
}
@inproceedings{Lebeda2012BMVC,
  title     = {{Fixing the Locally Optimized RANSAC}},
  author    = {Karel Lebeda and Jiri Matas and Ondrej Chum},
  booktitle = {British Machine Vision Conference (BMVC)},
  year      = {2012}
}
```

One disclosed difference from Lebeda's original code: its iterated least squares
used Sampson-gradient reweighted fits, whereas RansacLib's refits are plain least
squares, used as-is.
