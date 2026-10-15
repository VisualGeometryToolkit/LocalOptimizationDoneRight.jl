# Sequential CV: two scalars, not a product

Status: **IMPLEMENTED 2026-10-04** — THE tuning of every two-view cell
(`scripts/tools/run_sequential_cv.jl`; the configs' `[sequential_cv]`; the
batched single CV path, VisualGeometryEval `Evaluation.expanding_search` / `bracket`), and
the product grid is retired from accv2026. The design below is as agreed; the
"Implementation plan" section records the order it was done in. Every number
below is measured; the file says where.

## The claim

Selection and refinement hyperparameters do not vary jointly. The scorer's
outlier half-width is a property of the SCORER. Each refiner's efficiency
constant is a property of THAT REFINER. So the protocol is two 1-D
cross-validations in sequence, not one 2-D grid re-tuned per arm.

```
a* = coarse_fine_cv(scorer_scheme,  a -> selection_errors(a))          # once
k* = coarse_fine_cv(refiner_scheme, k -> arm_errors(arm, a*, k))       # per arm
```

## Why the coupling is not needed

**The selection is already shared.** `stream_selections` sweeps the staged
hypothesis pool once per column and records ONE selected model index per
(pair, column); `apply_lo_refits` hands that same index to every arm. The
selection was never a per-arm computation — only the per-arm ARGMIN over
columns is, which is a different thing and is what makes the product look
necessary.

**The one real coupling is handled by the order.** A partition-anchored
refiner's width is `k · ŝ(selected partition)`, so the optimal k depends on
the selection. That makes the optimal k a function of a*, which the sequential
order satisfies by construction: k is tuned after a* is fixed. It does NOT make
the optimal a* a function of the arm, which is what a product grid assumes.

**Joint tuning lets the scorer absorb refiner-specific compensation.** Measured
on two interior production cells (the only two where the argmin is clear of the
grid ceiling):

| cell | arms | selection argmins | spread | width argmins |
|---|---|---|---|---|
| ScanNet-F | 8 | 94 104 107 112 125 128 136 139 | 45 of 200 cols | 10 49 88 90 91 91 91 94 |
| ETH3D-F | 8 | 91 96 106 112 112 113 113 120 | 29 of 200 cols | 17 46 83 90 92 93 93 120 |

A weaker refiner prefers a selection that hands it a cleaner seed; a robust one
prefers a wider selection that captures more inliers. That spread is
COMPENSATION, not a better scorer — and it confounds the comparison the figure
exists to make: with a per-arm selection, arms differ in TWO things at once, so
the row no longer isolates refinement.

(The HEB-H checkpoint shows all 14 arms agreeing to 2 columns, which looks like
support but is not: that argmin sits 3 columns / 0.03 decades below the grid
top, so the agreement is a shared ceiling.)

## This is already the project's stated policy

`VisualGeometryEval src/evaluation/cv_probe.jl`: "**THE single CV path for scalar
hyperparameters.** Every scalar hyperparameter in this project is
cross-validated by ONE discipline — a coarse probe with expand-on-boundary,
then a fine sweep over the coarse argmin's bracket, then a FREE argmin …
Windows are located by expansion — NEVER hand-pinned, NEVER hand-widened …
Per-experiment CV code must not implement its own sweep/argmin loop — call
`coarse_fine_cv` instead."

`[tuning.default]`'s product grid is the only tuning in the project that does.
`run_polish_sharp` and the scalar CVs use `coarse_fine_cv`.

## What it removes

`ProductGrid` and its reimplementation of sweep, argmin, grid extension, window
widening and boundary enforcement. Every failure of 2026-10-03/04 lived in that
reimplementation and none of them exist in `coarse_fine_cv`:

- the k window silently falling back to the evaluation engine's (0.8, 6.0) because the cell
  declared its entry inline — a `coarse_fine` coarse window is `fixed` and
  located by expansion, so there is nothing to inherit wrongly
- the reach trap: `zeta_octaves` 7 -> 0 left 0.67 decades of headroom, so
  `window_widening.max_rounds = 8` was worth ~2 usable rounds and the production
  run refused all 14 arms. A coarse probe GROWS instead of spending a reserve
- the scale having TWO sources (grid from `_val_sigma2`, s0 from the stream's
  own `gt_variance`)
- `select` quadratic in the grid size (2.3e11 row comparisons)

## Why the σ̂ question disappears

The coarse window is located by EXPANSION from a fixed start, never positioned
at `s0`. The measured σ̂ bias — stored σ̂ climbs 1.58x with a pair's GT inlier
count (3.01e-4 at 4-12 inliers to 4.76e-4 at 201+, HEB-H NYC_Library, 2200
pairs) — is 0.12 decades, against a coarse probe at quarter-decade spacing that
extends on an edge argmin. It stops mattering, and
`[scale_estimation] min_gt_inliers_for_scale` can go with it. Two hours of
estimator work (SIMFIT++ label-free and over-labels, chart-LM vs DLT, held-out
k-fold) were spent making an anchor accurate that does not need to be.

## Cost

Per dataset x problem, with ~14 arms:

| | evaluations |
|---|---|
| joint product today | 14 x 240 x 124 ~ 417,000 |
| sequential coarse+fine | ~32 (scorer) + 14 x ~32 ~ 480 |

Plus one pool sweep instead of two: the scale sweep
(`val_sigma2_by_scene`) disappears, and HEB deserialises 10-15 GB per scene.
6698 spent over three hours in pool I/O before its first argmin because the
validation scenes are read twice.

## Not settled

1. **The scorer's own criterion.** Sequential tunes a* on the SELECTION error.
   Is the half-width that best selects a model also the best seed for the
   composed pipeline? That is the assumption, and it is testable on an interior
   cell: compare `coarse_fine_cv` on the selection objective against the joint
   argmin per arm. The ScanNet/ETH3D spread above says the two differ by 29-45
   columns, so the answer is "not exactly" — the question is whether the
   difference matters once the comparison is unconfounded.
2. **Does the fine stage want a library optimiser?** No. Brent/golden-section
   evaluate serially, and each evaluation is a full sweep over the validation
   pool; the grid stages evaluate many columns in ONE batched sweep (the
   selection sweep is a single kernel over pairs x models x columns). A coarse->
   fine grid is the right algorithm for a batched noisy objective, not merely
   the simpler one.
3. **`solo_specs` is a roster, not a strategy.** `role = :selection` and
   `role = :refinement` already name the two halves and are already used (Fig 1,
   Fig 2). They say WHAT to evaluate; `coarse_fine_cv` says HOW to search. The
   sequential protocol needs both, and neither needs `ProductGrid`.

## Implementation plan (HEB-H first), 2026-10-04

Agreed: sequential, coarse->fine, and **full validation** (no 25 % sampling —
affordable now that the cost is ~480 evaluations, and it retires the sigma-hat
variance problem rather than trading bias for variance).

### What already exists and needs no new code

- **Stage 2 is the existing stream with a DEGENERATE selection axis.** Run
  `stream_product_tuning` with `grids[:outlier_halfwidth] = [a*]` (one column)
  and `grids[:scale_multiple]` = the coarse (then fine) k grid.
  `apply_lo_refits` already batches all 14 arms x all k columns in ONE sweep, so
  the 14 refiner CVs share a pool sweep for free. No per-arm pool reads.
- **Stage 3 is unchanged**: the evaluation phase already reads tau* as a native
  value (artifact format 6) and builds its own {zeta_j . tau*} grid.
- **The rosters exist**: `solo_specs(:H; role = :selection)` is the scorer
  (`StudentTUniformScoring(P, a)`), `role = :refinement` the loss arms at unit multiple
  run at the absolute loss width (`LoRefitSpec` `widths`).

### The ONE gap: a grid-wise probe

`probe_curve(evalfn, coarse, scheme)` evaluates POINT-WISE
(`for (i, x) in enumerate(xs); y = _probe_objective(scheme, evalfn, x)`). For
HEB that is the wrong shape: `evalfn(a)` means "sweep the staged pool at
half-width a", and the pool is 10-15 GB per scene, so point-wise re-stages to
the GPU once per point (38 times for a 17-point coarse + 21-point fine). The
sweep already takes a GRID as its column axis, so one sweep should yield the
whole curve.

Needed, beside `probe_curve` and with IDENTICAL semantics (edge margin, `npts`,
`max_rounds` per side, the `:coarse_spec` / `:x_star` / `:boundary_hit` /
`:n_extensions` record):

```julia
probe_curve_batched(curvefn, coarse::SpacedGrid, scheme::CoarseFine; kwargs...)
#   curvefn(xs::AbstractVector) -> Vector{<:AbstractVector}   # errors per x
```

Each extension round calls `curvefn` once on the APPENDED points only (the
extension's points are the new columns; already-computed ones stay valid, as
`extension_offset` guarantees). `fine_stage` gets the same treatment.

### Order of work

1. The evaluation engine (now VisualGeometryEval): `probe_curve_batched` + `fine_stage` batched form, beside the
   existing ones. Small, and the discipline is already specified.
2. The evaluation engine's release (it is also carrying 04e1b02's budget-oracle `eligible` fix,
   which the 7-Scenes budget panel is waiting on, plus the window-rule collapse).
3. accv2026: a driver that runs stage 1 -> stage 2 -> stage 3, and two
   `coarse_fine` tuning entries in place of `[tuning.default]`'s `product_grid`.
4. `cv_protocol.toml [heb] validation = { type = "all" }`.
5. Delete: `ProductGrid` and its extension/widening machinery,
   `[scale_estimation]`, `val_sigma2_by_scene`/`_val_sigma2` and the second pool
   sweep they cause.

### The HEB-H specifics to settle in the configs

- scorer coarse window: `fixed` over [1e-4, 1.0] pool-frame units (4 decades,
  0.01 %-100 % of the half-diagonal) at quarter-decade spacing = 17 points. The
  measured native optimum is ~0.028-0.031, comfortably interior.
- scorer criterion: `finite_median` of the ROTATION error (HEB's H
  decomposition has an ill-conditioned translation direction — the house
  protocol scores rotation only).
- refiner coarse window in k: `fixed` over [0.1, 10] at quarter-decade = 9
  points, extending.
- fine: `log_count` over the coarse bracket, ~21 points.
- a FREE diagnostic: while sweeping `a` coarsely, also record each arm's error
  at each coarse `a`. One extra refit set, and it directly tests the
  assumption in "Not settled" #1 — whether the selection-only optimum is the
  right `a` for the composed pipeline, or whether the 29-45 column compensation
  seen on ScanNet-F/ETH3D-F matters once the comparison is unconfounded.
