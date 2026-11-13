# LocalOptimizationDoneRight changelog

## 0.7.0 (unreleased): the wave-10 stack and the terminology taxonomy

On the wave-10 stack: VisualGeometryToolkitCore 0.10 and VisualGeometryToolkitEstimation 0.11 (package and test);
accv2026 also VisualGeometryToolkitEval 0.8 and RANSACScoringDoneRight 0.8.

### Breaking

- **Requires the wave-10 stack**: VisualGeometryToolkitCore 0.10 and VisualGeometryToolkitEstimation 0.11
  (`[compat]` of the package, test and accv2026); accv2026 VisualGeometryToolkitEval 0.8 and RANSACScoringDoneRight 0.8.
- **The terminology taxonomy (correspondence, observation)**: the PoseLib refiners' two-view frame carries
  `frame.cs` as a `Correspondences` of `Point2{Float64}` (VisualGeometryToolkitCore 0.10's name for the
  retired `Csponds`); "measurement" and "keypoint" are gone from this repository's own names and prose (the
  paper's LaTeX, the vendored RansacLib and VisualGeometryToolkitEval's field names it reads are not this repository's).
- **`LiftableProblem` is retired upstream (no alias)**: the HQ/GNC `locally_optimize!` methods are typed on
  VisualGeometryToolkitEstimation's `MinimalSolveProblem` (the same type the alias named).
- **accv2026's configs of record rename their keys**: the pool configs' `min_csponds` is `min_correspondences`
  (VisualGeometryToolkitEval's keyword), eth_f_pools' `[inputs.eth3d_csponds]` is `[inputs.eth3d_correspondences]`,
  and the ETH3D SuperPoint+LightGlue artifact is bound as `eth3d_splg_correspondences` (catalog and Artifacts.toml),
  its Zenodo file name of record kept as `published_name = "eth3d_splg_csponds"` (no re-deposit). The pool configs'
  run keys move with their keys.
- **accv2026's pool-sample derivation draws with StableRNGs' `StableRNG`** (VisualGeometryToolkitEval retired its alias
  `POOL_RNG`, the same type): the same streams; the recorded derivation string names `StableRNG`.
- accv2026 no longer lists VisualGeometryToolkitIO: nothing in the project imports it (it arrives through
  VisualGeometryToolkitEval).
- **The PoseLib refiners' workspace holds the frame's correspondences as given** (`PoseLibWorkspace{C}`): any
  `Correspondences` the external-refit contract admits (attribute columns, another element type), no longer only
  `Correspondences{Point2{Float64}, …, @NamedTuple{}}`, which refused (`convert` MethodError) any other.
- **accv2026's pool trees must be at VisualGeometryToolkitEval 0.8's pool format 6** (the correspondences' pair key):
  `load_pool` refuses formats ≤ 5. The stored `_pf3` trees and the Zenodo `eth3d_f_pools_1k` parts (format 4) are migrated
  into NEW trees with Eval's `scripts/migrate_pools.jl DIR --apply` (the data step after the release); the `[inputs.pool]`
  `sha256` pins follow the migrated trees.
- **accv2026's data-root override of the ETH3D SuperPoint+LightGlue tier is renamed with the tier**:
  `VGTK_DATA_ROOT_ETH3D_SPLG_CORRESPONDENCES` (was `..._ETH3D_SPLG_CSPONDS`), and a site's `[sites.<site>.tiers]` key
  `eth3d_splg_correspondences`. A launcher binding the old name is no longer read.
- **The renamed `[pool]` key re-keys every run keyed on a pool config** (`run_key` of pt_e_pools, heb_h_pools, eth_f_pools):
  the derived sample starts (`PoolSamples/samples-<key>`) are derived again at the new key.

### Fixed

- **The 0.6.0 entry's "bit-identical" did not hold for `BarronAdaptive()` without a width** (catch-up review LODR#1):
  since 0.6.0 its frozen α-fit width resolves through Core's `loss_at` like every other arm's, so with no width the
  Barron scale is the one whose decision flips at the scorer's decision point t, `decision_width(BarronShape(0), t)` =
  t/√2 (squared t²/2), where 0.5.1 used t² — the threshold read AS the Barron scale, which decides at √2·t. The 0.6.0
  value is the derivation's and stays (now tested against the decision point); `BarronAdaptive(loss_width = t)`
  reproduces 0.5.1. The paper's arms state an `efficiency_constant` and never took this path.
- CI: the Downgrade workflow is deleted (the stack's policy: every release raises its floors to the gated resolve,
  `floor_compat --raise`; Resolver.jl does not run on Julia 1.13).

## 0.6.2 (unreleased)

A patch: requires Julia 1.13 (`julia = "1.13"` in the `[compat]` of the package and of every
workspace member: test, docs, accv2026 (with its envs/superansac and lib/RansacLibLO, and that one's test)). CI runs Julia 1.13 only. No API change.

- CI: the Downgrade workflow (the suite at the compat floors) runs on demand only: Resolver.jl, which it uses,
  does not run on Julia 1.13 yet.

## 0.6.1 (2026-11-13)

A patch: no API change, the same results. On VisualGeometryToolkitEstimation 0.10 (`[compat]`
VisualGeometryToolkitEstimation "0.10" in the package, test and accv2026 environments). Estimation 0.10.0 retired the image-space refine of
a free SplineLens camera's controls (`refine_camera_and_poses` on a SplineLens camera now takes `fixed = (:controls,)`
only); LocalOptimizationDoneRight never called that route, so nothing here changes.

## 0.6.0 (2026-11-12): the VisualGeometryToolkit 0.9 stack

On the VisualGeometryToolkit 0.9 stack: VisualGeometryToolkitCore 0.9,
VisualGeometryToolkitEstimation 0.9 and PoseLib 0.2; accv2026 also
VisualGeometryToolkitIO 0.9, VisualGeometryToolkitEval 0.7 and RANSACScoringDoneRight
on that stack.

### Breaking

- **Requires the 0.9 stack**: VisualGeometryToolkitCore 0.9, VisualGeometryToolkitEstimation
  0.9 and (the extension) PoseLib 0.2.
- **The PoseLib refiners take the two-view frame as VisualGeometryToolkitCore's
  external-refit contract states it**: `frame.Kc1`, `frame.Kc2` 3×3 and `frame.cs` a
  `Csponds` of `Point2{Float64}` (VisualGeometryToolkitEval's `PairGeom`), held as given;
  the extension no longer re-packs another correspondence type.
- **accv2026's run keys move**: every run a cell reads (a `scorer_of` cell's scorer,
  the operating points of the budget, e2e, polish, ladder, timing and SupeRANSAC cells,
  a timing cell's e2e and SupeRANSAC runs) keys it through VisualGeometryToolkitEval's
  `run_key(cfg; upstream)` (`upstream_runs`), no longer as config values
  (`scorer_of_run`, `operating_points_run`, `e2e_run`, `superansac_run`). The stored
  runs of record are promoted to the new keys (`promote_run`); no result changes.

- **The local optimizers state their termination record** (VisualGeometryToolkitCore's
  `ReturnCode` and `StopRule`, the robust-estimation contract §14). Each refit's
  `FitResult` says why it stopped: `retcode(r)` is a `ReturnCode.T`, and `stop_rule(r)`
  is the rule that fired. The rules are `IncrementSize` (the HQ lifts' increment
  floor), `LadderConverged` (the GNC ladder's terminal rung), `NoImprovement` (the
  patience rule) and `IterationCap`. Leaving the seed's basin is
  `(Terminated, LeftBasin)`: a success, with the incumbent returned. The legacy
  Symbol is `retcode_symbol(r)`.
- **`LO_TAGS` is renamed `LODR_STRATEGY_TAGS`** (VisualGeometryToolkitEstimation owned the
  name `LO_TAGS`, its core registry, now `OPTIMIZATION_STRATEGY_TAGS`, and
  VisualGeometryToolkitCore `STRATEGY_TAGS`, the registry of its core strategies). The
  registry is unchanged. Migration:
  `merge(VisualGeometryToolkitEstimation.LO_TAGS, LocalOptimizationDoneRight.LO_TAGS)` →
  `merge(VisualGeometryToolkitEstimation.OPTIMIZATION_STRATEGY_TAGS, LocalOptimizationDoneRight.LODR_STRATEGY_TAGS)`.
- **The mixture lifts keep the scoring's scale prior.** `StuTuHQTabulated` and
  `StuTuRegemm` reset the posterior state with `scale_prior(scoring)`; they used to
  reset it to Jeffreys whatever the scoring's prior. A Jeffreys scoring (every E cell
  of the paper) is unchanged.
- **`scale_multiple` is `efficiency_constant`** (VisualGeometryToolkitCore's
  `ScaleMultiple` is `EfficiencyConstant`): every strategy keyword and field, the TOML
  key, `[[tuning_constants]] efficiency_constant`, the `WELSCH_HQ_EFFICIENCY_CONSTANT_*`
  constants (were `WELSCH_HQ_SCALE_MULTIPLE_*`), `PoseLibLmAdaptLossWidth`'s
  `efficiency_constant` and the defaults key `operating_efficiency_constant`.
- **The per-shape currencies are retired**: an efficiency constant is ALWAYS the
  plain multiple, `loss_width = efficiency_constant·ŝ`, for every strategy.
  `HQ{GemanMcclureShape}` no longer reads a half-weight depth and `BarronHQ` no
  longer divides by √2. Migration: a GM value `m` stated as a half-weight depth
  becomes `decision_width(GemanMcclureShape(), m)` (= m/√(√2−1)); a BarronHQ value
  `m` becomes `m / sqrt(2.0)`. Both are the conversions the retired hooks
  computed, so every result is bit-identical. `Gnc` and `GmHqEps` were already
  plain (unchanged). accv2026's GM arms compose `decision_width` into their map
  from the shared Welsch grid (the grid spec is unchanged).
- **One optimization-strategy family** (VisualGeometryToolkitCore's
  `AbstractOptimizationStrategy`, was `AbstractLocalOptimization`): find_*,
  `ransac` and `locally_optimize` take `local_optimization_strategy` (was
  `local_optimization`); the TOML reader is
  `optimization_strategy_from_toml` (was `local_optimization_from_toml`);
  `NoLocalOptimization()` is `nothing` (TOML `type = "none"`); the strategies'
  defaults tables are `[optimization_strategy.<tag>]` (were
  `[local_optimization.<tag>]`).
- **A result's inlier set is `inlier_mask(result)`** (VisualGeometryToolkitCore, public): the
  `inlier_mask` field of a RANSAC result is replaced by per-point `weights` and their kind
  (`weight_kind`); `inlier_mask(r)` cuts them (binary `w > 0`, posterior the MAP rule). The README,
  docs and tests read it so.

### Changed

- The strategies' best iterate is VisualGeometryToolkitCore 0.9's
  `Attributed(θ, (; cost))` (Core's `Incumbent` is retired): a `ScoreBcdState`,
  `ManifoldLiftHQState`, `ManifoldLiftGncState`, `LiftedMixtureState` or
  `LiftedReGeMMState` built by hand takes one (`best.value` its model).

- The docstring gates are VisualGeometryToolkitCore's `test_docs` (the copied
  `test/docs_gates.jl` is deleted); the gates item runs Core's `test_duplication`.
- accv2026: the strategy tests' scenes are VisualGeometryToolkitEstimation's
  `test_scenes()` (its Test extension; the copied families are deleted, the draws
  unchanged); the paper's number macros are written by VisualGeometryToolkitEval's
  `PaperNumbers`/`write_numbers` and deployed by `deploy_assets`; SIMFIT++ is
  imported from VisualGeometryToolkitEstimation and the scoring registry is
  RANSACScoringDoneRight's `ALL_SCORING_TAGS` (both moved upstream).
- The scorer's decision point is VisualGeometryToolkitCore's `decision_boundary`
  (`inlier_threshold`, `has_inlier_threshold` and `decision_threshold` are retired
  there): a scorer wrapper forwards `decision_boundary`/`has_decision_boundary`,
  and accv2026's GM arms read the Welsch half-weight depth as
  `decision_boundary(WelschShape(), m)`. A find_* takes its threshold through its
  scorer (`scoring = MsacScoring(EssentialProblem; threshold = …)`), never as a
  bare keyword.

## 0.5.1 (2026-11-09)

On the VisualGeometryToolkit 0.8 stack, from General: VisualGeometryToolkitCore 0.8 and
VisualGeometryToolkitEstimation 0.8, PoseLib 0.1.9 (its compat floor, the first on Core
0.8); accv2026 also IO 0.8, Eval 0.6.1 and RANSACScoringDoneRight 0.6. Nothing else
changes.

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
