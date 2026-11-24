# LocalOptimizationDoneRight changelog

## 0.7.3: on VisualGeometryToolkitCore 0.13; accv2026 on Eval 0.10's storage design and keyed products

A patch: the package's code is unchanged. The package, test and accv2026 (with accv2026/envs/superansac) move to
VisualGeometryToolkitCore 0.13, which removes the spherical spline and the dilogarithm (unused here) and installs artifacts
into the artifact store; accv2026 moves to VisualGeometryToolkitEval 0.10.1, whose paper-project check enforces the storage
design. No API change.

accv2026 (the paper project, not part of the registered package):
- Its drivers run again: every result of record is a keyed product (Eval's `Product`, `src/protocol_folds.jl`
  `cell_product`), `<results>/<dataset>/<matcher>/<problem>/<experiment>/<kind>/<key>`, keyed by the folded config, the
  products it reads and the code it runs, and produced through `produce`; renders, grids, oracle bounds and pool trees are
  check stages. This closes 0.7.1's known break (the drivers called Eval 0.8's retired `keyed_cell_dir`, `run_complete`,
  `fresher`, `keyed_data_dir`). Every result moves to a new key and layout; the runs of record are regenerated and their
  paper numbers, figures and tables checked against the published ones before they are promoted (the old runs kept).
- `scripts/fetch_data.jl` installs the published tiers into the artifact store (`VGTK_ARTIFACT_STORE`, or the site
  profile's `[storage] artifact_store`, selected by `VGTK_SITE`; never a cluster's Julia depot) and links them into the
  artifact view. data/README.md, REPRODUCE.md and CLAUDE.md name the store and the site profiles' roots.
- The pools of record move to pool format 6 (Eval 0.10 reads no other): the stages `pt_e_pools_v6`,
  `heb_h_pools_v6` and `eth_f_pools_v6` (`scripts/migrated_pools.jl`, configs `*_pools_v6.toml`) carry
  PT-E-SIFT-4K_pf3, HEB-H-SIFT-4K_pf3 and the published ETH3D scoring_data_F_pf3 into new trees (`*_pf6`) with
  Eval's `migrate_pools` (each light pool verified bit for bit; the residuals linked, every pool key unchanged; the
  format-4 trees never written). Every cell's `[inputs.pool]` and `pool_dir` name the format-6 tree and its digest.
- The pools that are never published are catalogued as `kind = "produced"` entries naming their producer stages:
  `pt_e_pools`, `heb_h_pools` and the three format-6 trees `pt_e_pools_v6`, `heb_h_pools_v6`, `eth3d_f_pools_v6`.
  The published eth3d_f_pools_1k stays format 4 (Zenodo 23240469); a fresh machine migrates it after the fetch.
- accv2026 depends on RANSACScoringDoneRight 0.8.3 (its Core 0.13 release) and on VisualGeometryToolkitIO 0.11.2
  (the migration's staged writer).
- `test/test_public_paths.jl` runs Eval's `data_policy_violations` over the package (its own regex copy is gone), and
  `test/test_data_artifacts.jl` drops its copies of the D1 and D4 scans and of the catalog check (A1), which the
  paper-project check owns. A failing item no longer skips the conventions check.

- The run of record (2026-11-21..24), on the release tree resolved from General (Core 0.13.0, Eval 0.10.1,
  Estimation 0.12.2, IO 0.11.2, PoseLib 0.3.3, RANSACScoringDoneRight 0.8.3; Julia 1.13.4): every cell regenerated
  and every paper asset rewritten. The owner's policy (2026-11-21): a rerun may differ within documented tolerances,
  every moved number is listed. `accv2026/RECORD_CHANGES.md` lists every moved number old → new, file by file;
  the summary:
  - Accuracy: PhotoTourism and ETH3D-F move at the 4th decimal (mAA ≤ 0.003); HEB-H by up to 0.017 mAA in the
    iterative-LO arms (IG +Lift, IG +GNC-W), accepted by the owner (2026-11-22). No ranking of the paper's method
    changes. Tab. 3 (ours): error 2.59 → 2.58 (ζ = 16), 6.20 → 6.18 (ζ = 128); the rest identical.
  - Timings (Tab. 1, Fig. 4's time axis, Tab. 3's time row), re-timed with the published protocol (a node held
    exclusively, CPU 38 pinned, its SMT sibling idle) on the same CPU model (Intel Xeon Platinum 8570). The moves come
    from the software environment, Julia 1.12.6 → 1.13.4 and the newer stack, not the machine.
    Tab. 1, ms per LO call: Welsch IRLS 0.43 → 0.33, HQ 1.13 → 1.03, GNC 0.83 → 0.79; Geman–McClure 0.38 → 0.29,
    0.73 → 0.70, 0.63 → 0.61; TLS 0.53 → 0.48, 0.73 → 0.68, 0.68 → 0.62, -LZ 0.93 → 0.87, -LO+ 0.31 → 0.27;
    Stu-tU-BCD 0.86 → 0.56. Tab. 3's time row [ms]: ours 291/50/34/23/15 → 308/51/35/23/15, SupeRANSAC
    86/111/168/265/381 → 86/111/166/261/374 (SupeRANSAC built from danini/superansac 27de486).
  - paper_numbers.tex (86 macros, 79 identical): EtoEOursDeflMs 291 → 308, EtoEOursMs 50 → 51, EtoEOursInflMed
    6.20 → 6.18, HEBCalSpread 0.01 → 0.012 (now typeset to three digits), SelSimfitMedCal 2.36 → 2.35,
    SelSimfitMedInfl 34 → 33, SelSimfitMAAInfl 0.134 → 0.142. The file is written by Eval's `write_numbers` (one
    provenance line per macro).
  - The selection-only sweep (supplement, fig:supp-sel-miscal): the profile-marginal and threshold arms identical to
    the published up to the last float digits; SIMFIT++ moves with its own scorer path (median error at ζ = 128
    34.1° → 33.1°, mAA 0.134 → 0.142); the paper's claims hold.
  - Paper text: HEB-H at calibration "within 0.012" (\HEBCalSpread, three digits) and TLS-LO+ "among the
    strongest" (its gap to the top grew from 0.0029 to 0.0075). The matched-LO-time claim (main.tex, supplement
    fig:supp-budget-time) now reads "From 1000 hypotheses on" (was "Beyond the smallest budget"): with the
    regenerated per-call times, Welsch-IRLS and GM-IRLS exceed Welsch-HQ at matched time at its 500-hypothesis
    checkpoint (0.5956, 0.5983 vs 0.5928); from 1000 on Welsch-HQ is the highest (owner decision 2026-11-24).
- Fixes found by the run of record: fig2's ladder product is keyed when its stage runs (it folds the basin CV's
  output, written in the same process); the stage graph runs fig2_basin after fig3_composed_miscal, whose scorer it
  reads; e2e_timing records the code through Eval's code trees (a package installed from General is no git checkout).

- accv2026 stays on VisualGeometryToolkitEval 0.10.x in this release: its run of record ran there, and Eval 0.11.0
  (breaking for it: a `Product` record holding a top-level `[render]` is an error) reached General the day before.
  The release leg ran with the owner's scoped exemption `FLOOR_LATEST_EXEMPT="accv2026:VisualGeometryToolkitEval"`
  (cau-release; the registered package's own dependencies are all at the registry latest). 0.7.4 ports accv2026 to
  Eval 0.11 and re-runs the cells, on a schedule.

## 0.7.2: on VisualGeometryToolkitCore 0.12

A patch: compat only. The package, test and accv2026 move to VisualGeometryToolkitCore 0.12, whose radiometric types (vignetting
fields, the environment light) moved to VisualRadiometryToolkitCore; this package uses none of them. No API change.

## 0.7.1: on VisualGeometryToolkitCore 0.11

A patch: compat only. The package, test and accv2026 move to the registry latest of the stack: VisualGeometryToolkitCore
0.11, VisualGeometryToolkitEstimation 0.12 and (the extension) PoseLib 0.3.1; accv2026 also VisualGeometryToolkitEval 0.9.2
and RANSACScoringDoneRight 0.8.1. No API change.

Known break, accv2026 only: Core 0.11 forces the paper project onto VisualGeometryToolkitEval 0.9.2, and main's accv2026
still calls Eval 0.8's retired `keyed_cell_dir` (and `run_complete`, `fresher`, the 4-argument `Stage` in its scripts). Its
test item "keyed cells" errors in three testsets (Table 1 timings, Fig 1, Fig 2: `keyed_cell_dir is retired`); the
package, its test and docs members are unaffected. The paper needs its held Eval 0.9 port, which this release does not
take.

Why a patch: Core 0.11.0's breaking change is its host LM's verdict (a tolerance stop on a finite step is `Success`, with no
stationarity test), and nothing here reads it. The local optimizers' termination records come from their own lift loops
(Core's `refine!` with this package's stop criteria: `StopWhenIncrementSmall`, `StopWhenLadderConverged`,
`StopWhenLeftBasin`, through `lo_termination`), never from `lmsolve_chart!` / `LmProblem`; the PoseLib refiners'
records are PoseLib's. So this release changes no estimate, inlier set or termination record of this package's (Estimation
0.12 changed no code path either: its RANSAC's model and inliers are unchanged).

## 0.7.0 (2026-11-13): the wave-10 stack and the terminology taxonomy

On the wave-10 stack: VisualGeometryToolkitCore 0.10 and VisualGeometryToolkitEstimation 0.11 (package and test);
accv2026 also VisualGeometryToolkitEval 0.8 and RANSACScoringDoneRight 0.8.

### Breaking

- **Requires the wave-10 stack**: VisualGeometryToolkitCore 0.10 and VisualGeometryToolkitEstimation 0.11 (0.11.1: its
  shared two-camera F scene and LO bench arm, which accv2026's tests use in place of their own copies),
  and (the extension) PoseLib 0.3, whose refiners return the seed with `InitialFailure` below the minimal sample
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
- **The termination record's rule is Core's** (catch-up review LODR#2): `block_coordinate_descent!` hands the result the
  `stop_rule(criterion, method)` of the criterion that fired (VisualGeometryToolkitCore 0.10); this package states the
  rule of each criterion it defines (`StopWhenIncrementSmall` → IncrementSize, `StopWhenLadderConverged` → LadderConverged,
  `StopWhenLeftBasin` → LeftBasin); Estimation's no-improvement stop states its own (NoImprovement). Its own
  criterion → rule map (`success_rule`) and the post-hoc guess of a composite's fired member (`_fired_rule`, which re-ran
  each member at the final state) are deleted.
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
