# LocalOptimizationDoneRight changelog

## 0.5.0 (2026-11-07)

The VisualGeometryToolkit 0.7 stack, from General: VisualGeometryToolkitCore 0.7
and VisualGeometryToolkitEstimation 0.7, PoseLib 0.1.8, and in accv2026 also
VisualGeometryToolkitEval 0.6, VisualGeometryToolkitIO 0.7 and
RANSACScoringDoneRight 0.5.

### Breaking

- `FixedWelschScale` is removed: the fixed-scale arms (HQ, BarronHQ, GmHqEps,
  GNC, the score-matched BCD) run under VisualGeometryToolkitCore's
  `FrozenNuisance()`, the weight policy that holds nothing (nothing in it was
  Welsch-specific). Migration: `LocalOptimizationDoneRight.FixedWelschScale()` →
  `VisualGeometryToolkitCore.FrozenNuisance()`.

### Changed

- The RANSAC protocol's distance vocabulary (VisualGeometryToolkitCore 0.7):
  the Barron-adaptive likelihood reads `sq_distances` (was `sq_residuals`), and
  `PoseLibLmAdaptLossWidth`'s per-round scale moment reads
  `mahalanobis_distances!` (was `residuals!`). The moment squares each entry, so
  the scale is unchanged.
- `PoseLibLmAdaptLossWidth` fills its workspace's residual buffer on every
  round, which it allocated anew before (the buffer was unused).
- The `scale_multiple = "cross_validated"` lookup names a loss shape's tag by
  `tag_of(LOSS_TAGS, K)`, the registry's writer side, in place of an inverted
  copy of the registry.

### accv2026

The paper project calls the stack for what it had copied (the 2026-11-06
duplication audit). No result of record moves.

- The oracle floors are VisualGeometryToolkitEval's `write_oracle_floor`,
  `oracle_floor_done(path, tag; source)` and `oracle_floor_source`; the
  sidecar's note reads the configured mAA threshold.
- SupeRANSAC's pixel inputs are `Pools.export_pixel_inputs` (which also
  refuses a pair without Lowe ratios).
- The e2e summary and the timing row are written with `write_tsv` and read with
  `read_tsv`, their cells by `fmt3` and their scene averages by `scene_mean`
  (a scene without a finite statistic is skipped; none has one today). The
  summary row is `e2e_summary_row` (was `e2e_summary_line`, a joined string),
  and `E2E_SUMMARY_HEADER` is the header vector. DelimitedFiles is no longer a
  dependency.
- The protocol's tuning entries are `layered_tuning_entry`; the `[types]`
  defaults are filtered by the scheme's TOML keys (`allowed_keys`), not its
  field names.
- The fold key checks are `check_keys` (an unknown key is an `ArgumentError`).
- The polish displacement is Core's `pose_error`; the polish ECDF coordinates
  are `pgf_coords`.
- The GM arms' half-weight depth is Core's `decision_threshold(WelschShape(), m)`.
- The selector families are keyed by RANSACScoringDoneRight's `SCORING_TAGS`
  (Core's merged with its own), which owns the tags, the types and the retired
  spellings; `SELECTOR_FAMILIES` keeps only each family's sweep key and display
  label, and `selector_scoring` builds the loss-width families by
  `loss_width_scoring(tag, dg)`.
- The Lebeda E-track width conversion is PoseLib's `calibrated_loss_width`.
- A pool's pair count is `Pools.pool_size(path)`, under the pool format check.
- The tests follow the renames: `mahalanobis_distances!`, `signed_distance`,
  `RansacWorkspace(T, problem, scoring)`, `LossWidthSpec` and
  `loss_width_specs`.
