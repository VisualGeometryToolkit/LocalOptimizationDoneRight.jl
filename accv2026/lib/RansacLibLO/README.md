# RansacLibLO.jl

Seeded classical LO-RANSAC **local optimization** (LO / LO⁺ family) for
essential, fundamental, and homography models, via
[RansacLib](https://github.com/tsattler/RansacLib) — Torsten Sattler's
template-based *SAC library — **run unmodified**.

## Attribution (primary sources)

RansacLib self-describes the implementation this package exposes:

> "LO-MSAC as described in *Lebeda, Matas, Chum, Fixing the Locally Optimized
> RANSAC, BMVC 2012*: RANSAC with local optimization (LO) and a truncated
> quadratic scoring function (as used by MSAC, described in *Torr, Zisserman,
> Robust computation and parametrization of multiple view relations, ICCV
> 1998*)." — `README.md` (RansacLib)

> "Implements LO-RANSAC with MSAC (top-hat) scoring, based on the description
> provided in [Lebeda, Matas, Chum, Fixing the Locally Optimized RANSAC, BMVC
> 2012]. Iteratively re-weighted least-squares optimization is optional." —
> `RansacLib/ransac.h` (comment above `LocallyOptimizedMSAC`)

Citing (per RansacLib's own README "Citing" section):

```bibtex
@misc{Sattler2019Github,
  title = {{RansacLib - A Template-based *SAC Implementation}},
  author = {Torsten Sattler and others},
  URL = {https://github.com/tsattler/RansacLib},
  year = {2019}
}
@inproceedings{Lebeda2012BMVC,
  title = {{Fixing the Locally Optimized RANSAC}},
  author = {Karel Lebeda and Jiri Matas and Ondrej Chum},
  booktitle = {British Machine Vision Conference (BMVC)},
  year = {2012}
}
```

## Verbatim-reference contract

- RansacLib is vendored **byte-identical** to upstream commit
  `b952083fcf1b2aea001bf178e010e540ff372889` (cloned by `deps/build.jl`; no
  patches, no edits).
- The only code here is (a) the Solver-concept plug-ins RansacLib's template
  API requires users to supply (E/F/H model fits + Sampson residuals), and
  (b) a subclass lifting the `protected` `LocalOptimization`/`LeastSquaresFit`
  entries so the LO runs from a caller-supplied seed (subclassing = usage).
- Configuration is exclusively through RansacLib's public `LORansacOptions`.
  The primary preset is **RansacLib's own defaults** (`PRESET_REFERENCE`);
  the informational Lebeda-TR mapping (`PRESET_TR_INFORMATIVE`) is a
  public-option preset. A caller with an update budget builds its own
  `LebedaLOOptions` (a fully active full-LO call costs
  `1 + num_lo_trials·(2 + num_lsq_iterations)` updates).
- `lsq_sq_loss_widths(options, θ²)` is the ladder's squared-width schedule
  (RansacLib's `RunIterLSQ`), for a caller running the ladder on a model
  RansacLib has no solver for.
- Disclosed delta vs Lebeda's original EG code: Lebeda's iterated LSq used
  Sampson-gradient *reweighted* fits (`u2fw`); RansacLib's refits are plain
  least squares and are used as-is.

## API

```julia
using RansacLibLO
# pts: 4×N (x1, y1, x2, y2 columns), any consistent frame; sq_loss_width (the
# squared loss width) in that frame's squared-Sampson currency. Returns (E, score, updates, ns).
r = lebeda_lo(pts, seed_model, sq_loss_width; model = :E, options = PRESET_REFERENCE,
              rng_seed = 0, base_mask = nothing)   # full LO (Alg. 2+3)
r = lebeda_iterlo(pts, seed_model, sq_loss_width; model = :E) # ILSQ ladder only (Alg. 3)
```

`model ∈ (:E, :F, :H)`; `updates` counts every linear solve (measured budget
parity), `ns` is steady-clock time inside the LO invocation (the eval stack's
`lo_ns`/`lo_calls` shape). Deterministic: a per-call `std::mt19937(rng_seed)`
is the only randomness source.

## Build

```julia
using Pkg; Pkg.build("RansacLibLO")   # clones RansacLib, builds the C++ shim
```

Requires `git` and `g++` (C++17). Eigen comes from `Eigen_jll` (set
`EIGEN_INCLUDE` to use another copy; see the Makefile). RansacLibLO is not
registered: the paper project `accv2026/` devs it by path
(`[sources]` in `accv2026/Project.toml`).

## License

RansacLib is BSD-3-Clause (c) 2019 Torsten Sattler. This wrapper follows the
same terms.
