# LocalOptimizationDoneRight 0.7.0: duplication checklist (wave 10)

Concept-level check of every function this wave added or changed, against the stack (Core, IO, Features, Estimation,
Eval, PoseLib, BB, RSDR, LODR, PS, CB), and Core's `check_duplication` over the repository with VGTK_STACK_PATHS
(RSDR, BB, CB, PS working trees) at gates 42850cfe, eec82d9 (up-v8), 5a26b9b (up-v11) and 32e7c7d (up-v12):

    == check_duplication(LocalOptimizationDoneRight 0.7.0): 0 finding(s)

Core's `check_splat` (up-v12), over the package and the paper project's RansacLibLO:

    == check_splat(LocalOptimizationDoneRight 0.7.0): 0 finding(s)
    == check_splat(RansacLibLO 0.2.0): 0 finding(s)

Core's ONE LM adapter: no direct NLLSsolver / `lmsolve_chart!` / `static_lm` / `nlls_options` call anywhere here.

- [x] `PoseLibWorkspace{C}` + `PoseLibWorkspace(Kc1, Kc2, cs)` (ext/LocalOptimizationDoneRightPoseLibExt.jl:47-53):
  a field-type change of the extension's own workspace; considered Core's external-refit contract (src/robust/lo_contract.jl,
  which defines no workspace type) and Estimation's RansacWorkspace (another quantity). No new concept.
- [x] the SupeRANSAC cell's tuning artifact (accv2026/src/superansac.jl:292, e2e_timing.jl:195): now Eval's
  `save_tuning_artifact` (Tuning) and `deployed_setting` (Evaluation), the owners; the never-existing
  `save_scalar_tuning_artifact` / `deployed_scalar_setting` calls are gone.
- [x] the criterion → StopRule map (src/lift/termination.jl `success_rule`, `_fired_rule`), duplicated with
  Estimation's `_stop_rule` (catch-up LODR#2): DELETED; the one map is Core's `stop_rule(criterion, method)` (core10
  4981053a), with a method beside each criterion this package defines (lifts.jl, essential.jl); Estimation's
  `StopWhenNoImprovement` rule is Estimation's own (no copy here); Core's loop hands over the fired member's rule.
- [x] `_entry_from_toml` (src/strategies/config_toml.jl:28) vs CaliBlobs' `_optimization_strategy_from_toml`: resolved by
  CaliBlobs (w10-cb 30b49af now reads through Estimation's reader); no DUPLICATION.toml entry needed.
- [x] Removed: accv2026's direct VisualGeometryToolkitIO dependency (unused; Eval carries it).

---

# LocalOptimizationDoneRight: duplicate removals of the 0.9 leg

Owner decision 12 (2026-11-11) and the owner's ruling "all duplicates must be gone; all common code must be hoisted
without exception". The items are the "LocalOptimizationDoneRight" section of cascade-duplicate-removals.md, the
"Every paper project" item for accv2026, everything the duplication audit (2026-11-10) attributes to LODR, and every
hit of Core's `test_duplication` (monorepo dde0b5ca) on this repository. Each item is ticked with the commit that
closes it.

## Removals

- [x] its copied test scenes → the shared scenes: accv2026/test/lodr/scenes_testsetups.jl's seven families (EpipolarScenes, HomographyScenes, PoseScenes, DivisionBoards, P3PScenes, Cameras, Contamination; audit 2) → VisualGeometryToolkitEstimation's `test_scenes()` Test extension (7f79ca7)
- [x] its TeX writer → Eval's number-macro writer: accv2026/scripts/paper_numbers.jl `_fmt`/`_emit` (audit 11) → VisualGeometryToolkitEval's `PaperNumbers`/`add_number!`/`write_numbers` + `deploy_assets` (e8839ed)
- [x] test/docs_gates.jl (audit 1) → VisualGeometryToolkitCore's `test_docs` (16ffdfa, 4f4e965)
- [x] the gates run VisualGeometryToolkitCore's `test_duplication` (4f4e965)
- [x] the registry Estimation names (see CHANGELOG), `_LO_REGISTRY`, `_TOML_DEFAULTS`, names VisualGeometryToolkitEstimation owns (test_duplication `[name]`) → `STRATEGY_TAGS`, `_STRATEGY_ROWS`, `_DEFAULTS_OF_RECORD` (7a3013a)
- [x] `STRATEGY_TAGS` (VisualGeometryToolkitCore's name since A2, the registry of its core strategies) → this package's `LODR_STRATEGY_TAGS`
- [x] accv2026's four keyed cell directories and two config loaders restated (test_duplication `[similar]`: `e2e_timing_dir`, `budget_cell_dir`, `e2e_cell_dir`, `superansac_cell_dir`; `e2e_timing_cell`, `superansac_cell`) → `keyed_cell_dir` and `config_of_record` in accv2026/src/protocol_folds.jl (bb20c31)
- [x] the two timing benches' call-set reader (`read_fixture`, `pool_csponds`, `problem_of`) and VisualGeometryToolkitCore's `calibration_spread`/record writer restated in both (audit 2; test_duplication `[similar]`) → one test/lo_timing/call_set.jl and Core's test/lo_timing/bench_record.jl (08a5135)

- [x] the twin audit's V1 (cpu-gpu-twin-audit.md): accv2026/src/arm_rosters.jl kept MAGSAC++ and the other loss-width families out of the `:selection` roster "until a CPU scorer exists"; they select on the CPU (VisualGeometryToolkitCore's exact selection kernels, monorepo 6accc512; `best_pool_model` per pair), so the exclusion is dropped and MAGSAC, GAU, WEL and GEM join the roster (this commit; the scale marginals stay sweep-only, not per-residual scorers)

## Hoists into the stack

Common code no stack package offers yet (each is a copy of a stack package's TEST code, which nothing downstream can
call). Not kept by choice: each waits for its owner to publish it, and the switch here is noted.

- [x] hoist the scene builders of accv2026/test/lodr/test_problem_arms.jl that restate VisualGeometryToolkitEstimation's tests (audit 2; test_duplication `[similar]`): `_board_scene` (pnp_lens_tests.jl:37), `_box` (ransac_fundmat_tests.jl:30), `_gt_model`/`_make_scene` (radial_homography_tests.jl:26/38), `_board` (radial_camera_tests.jl:29), `_contaminated_line` (line_fitting_tests.jl:97) → Estimation's `test_scenes()`, as new families or members: `PoseScenes.lens_board_scene(rng, camera, R, t; σ, n_out)`, `EpipolarScenes.box_point_far(rng)` (or `box_point` with the box as keywords), `RadialScenes.radial_homography(k_norm)` / `RadialScenes.radial_homography_pairs(rng, model; n_in, n_out, σ)`, `RadialScenes.radial_board(rng; f, k, n_out, σ)`, `Contamination.contaminated_line(rng, …)` (the owner reconciles the keyword differences first). Callers: test_problem_arms.jl. The switch: each local definition deleted, the family added to the item's `setup = [...]`. — CLOSED: VisualGeometryToolkitEstimation `synthetic_scenes()` (the Test extension; renamed from `test_scenes()` upstream): `PoseScenes.lens_board_scene`, `DivisionBoards.radial_board` (+ `RADIAL_BOARD_FRAME`/`RADIAL_BOARD_CENTER`), the new family `RadialScenes` (`radial_homography`, `radial_homography_pairs`), `Contamination.contaminated_line`, `EpipolarScenes.box_point` with the box as keywords (monorepo a53d004d); the local definitions deleted here (4b92805)
- [x] hoist `two_view` of accv2026/test/lodr/test_bcd_recorded.jl (audit 2; test_duplication `[similar]` against Estimation's test/bcd_recorded_tests.jl:21) → Estimation's `test_scenes().EpipolarScenes.contaminated_pixel_pairs(rng, n; planar)`; and `check_recorded` (audit 2, ibid. :101) → VisualGeometryToolkitCore's Test extension, `test_recorded(make)` (a `Recorded` run equals the bare run, iterate for iterate; `Recorded` is Core's). Caller: test_bcd_recorded.jl. The switch: two deletions and one import. — CLOSED: `EpipolarScenes.contaminated_pixel_pairs(rng, n; planar)` + `PIXEL_PAIRS_K` (monorepo 30f73a04) and VisualGeometryToolkitCore `test_recorded(make)` (the Test extension, with its snapshot helpers; monorepo 0a262039); deleted here (4b92805)
- [x] hoist `subpair` and `scene` of accv2026/test/test_engine_integration.jl (audit 2; test_duplication `[similar]` against VisualGeometryToolkitEval's test/evaluation_engine_tests.jl:124/:597) and its `write_sidecar` (audit 2, ibid. :728) → a VisualGeometryToolkitEval Test extension (`test_fixtures()`: `subpair(pair, cols)`, `engine_scene(...)`, `write_sidecar(path, arms; mode, hits)`). Caller: test_engine_integration.jl. The switch: one import. — CLOSED: VisualGeometryToolkitEval `engine_fixtures()` (a new Test extension: `epair`, `EPAIR_GT_VARIANCE`, `starts_pool`, `subpair`, `engine_scene`, `roster_tuning`, `write_roster_sidecar`; monorepo ecc25e3c); deleted here (4b92805)
- [x] hoist the bench scene of test/lo_timing/bench.jl `scene()` (test_duplication `[similar]` against VisualGeometryToolkitCore's test/lo_timing/bench.jl:38, the same seeded 1000-point E scene) → Core's test/lo_timing/bench_record.jl (`essential_bench_scene(rng; n)`), which both benches already include. The switch: the local definition deleted. — CLOSED: VisualGeometryToolkitCore test/lo_timing/bench_record.jl `essential_bench_scene(rng; n)` (monorepo 8b5d05f8); deleted here (4b92805)
- [x] hoist test/lo_timing/call_set.jl (the LOFX0001 call-set reader, also in VisualGeometryToolkitEstimation's test/lo_timing/bench.jl:44, the same fixture file) → Estimation's test/lo_timing/call_set.jl (`read_fixture`, `pool_csponds`, `problem_of`), included from `pkgdir(VisualGeometryToolkitEstimation)` as Core's bench record is. The switch: one include path. — CLOSED: VisualGeometryToolkitEstimation test/lo_timing/call_set.jl (`CALL_SET_FIXTURE`, `read_fixture`, `pool_csponds`, `problem_of`; monorepo cc49c43b); this package's call_set.jl and both copies of the fixture file (test/ and accv2026/test/) deleted, both benches include Estimation's (4b92805)
- [x] hoist accv2026 `artifact_catalog()` (src/data_artifacts.jl:30; audit 20, also RANSACScoringDoneRight's neurips2026) → VisualGeometryToolkitEval DataArtifacts `project_catalog(project_root = projectdir())`. The switch: one import. — CLOSED: VisualGeometryToolkitEval `DataArtifacts.project_catalog(root = project_root())` (monorepo 4b9b95d4); deleted here (4b92805)
- [x] hoist `keyed_cell_dir(cfg, experiment, kind)` and `config_of_record(name)` (accv2026/src/protocol_folds.jl; every paper project spells a keyed run directory `<experiment_dir>/<Experiment>/<kind>-<run_key>` and loads `configs/<name>.toml`) → VisualGeometryToolkitEval Experiments, beside `experiment_dir` and `load_run_config`. The switch: delete the two definitions, import them. — CLOSED: VisualGeometryToolkitEval `Experiments.keyed_cell_dir`, `config_of_record(name; root = project_root())` (monorepo 7841c46e); deleted here, imported in accv2026/src/protocol_folds.jl (4b92805)

## Robust schema

The owner's policy: every robust estimate goes through ONE schema — the stack's strategy types and Core's width
resolution (`loss_at` / `lo_loss` / `deploy` / `decision_width`), no private width or scale rules. The items are the
"LODR" section of robust-schema-audit.md (2026-11-11). Decisions taken in the owner's absence are recorded here.

- [x] src/strategies/types.jl `_barron_sq_width`: a private width resolver whose no-width branch took the scorer's threshold itself (skipping `decision_width`) → `sq_loss_width(loss_at(lo, BarronShape(0.0), cs, scoring, buf))`. Decision: the frozen width is resolved at ONE reference shape, Barron's α = 0 (Cauchy): its facet-B decision width t/√2 is the Cauchy loss deciding at the scorer's threshold t, the intent of the old rule in Core's currency. `EfficiencyConstant`/`LossWidth`: bit-identical; follow-the-scorer: a behaviour change (c² = t²/2, was t²; fail-first test, no paper arm runs this mode — every BarronAdaptive arm carries an `efficiency_constant`) (this commit)
- [x] src/strategies/essential.jl `WelschHQEcm`: the hand-written `deploy(WelschShape(), max(scale_s2(cs), eps()); efficiency_constant)` → `loss_at(lo, WelschShape(), cs, scoring, buf)`, with `lo_width(::WelschHQEcm) = EfficiencyConstant(lo.efficiency_constant)`. Bit-identical. Decision: the arm keeps its ONE mode and gets no `LossWidth` or follow-the-scorer mode (no `width` field, no `with_width`): it is self-scaling, re-estimating ŝ² at a fixed multiple, so an absolute width (a multiple of 1 from `loss_width`) or the scorer's would become 1·ŝ_ECM at the first scale step. Its scale interface stays `SelfScaling` (this commit)
- [x] ext/LocalOptimizationDoneRightPoseLibExt.jl `PoseLibLmAdaptLossWidth`: the width built in place (`efficiency_constant * sqrt(s2)`, twice) → `loss_width(deploy(TLSShape(), max(s2, eps()); efficiency_constant))` (`_adapt_loss_width`), bit-identical. Decision: the within-width truncated moment IS the arm's definition (accv2026 configs/protocol.toml `[arms.tls_adapt]`: the width "re-anchored on the refined partition"; the docstring's "within-width residual scale"; `min_support` in configs/default.toml), so the partition |r| ≤ width and its support floor stay; its scale is Core's estimator `fit_scale(JeffreysPrior(), rss, ν)` = rss/ν. Width bit-identical; the moment alone now floors at eps where it returned 0.0 for an all-zero partition (the width already floored it) (this commit)
No stack change is needed: VisualGeometryToolkitEstimation src/config_toml.jl `lo_from_toml` cites "LocalOptimizationDoneRight's Welsch-HQ-ECM" as its example of a plain `efficiency_constant` FIELD; it stays accurate (the field stays).

### The robust-estimation contract (A3 efficiency_constant, currency retirement; the optimization-strategy family)

- [x] the per-shape currency hooks: `deployed_scale`-style methods for HQ (GM's half-weight depth through Estimation's retired currency map), Gnc (identity), BarronHQ (m/√2) and GmHqEps (identity + the m ≤ 0 refusal, now `EfficiencyConstant`'s own), and the deployed-shape methods for HQ/Gnc/BarronHQ, are deleted with Core's generic: one width rule, `loss_at` deploying c·ŝ for every shape
- [x] the stored values migrated once at full precision, bit-identical: GM `m` → `decision_width(GemanMcclureShape(), m)` (test/test_strategies.jl, accv2026 test_lift_losses / scenes_testsetups / test_bcd_recorded / lo_timing bench), BarronHQ `m` → `m / sqrt(2.0)` (test/test_strategies.jl, test_lift_losses); the GM roster arms' grid map is `_gm_at_welsch_depth(m) = decision_width(GM, decision_boundary(Welsch, m))` (arm_rosters.jl), the grid spec unchanged. Before/after capture: identical width², estimate, retcode and iterations on 14 sites
- [x] the no-local-optimization type → `nothing` (accv2026 experiment_producer, run_sequential_cv, test_engine_integration; TOML `"none"`)

- [x] Q3 weights (B4): the 21 `result.inlier_mask` field reads (README, docs index, test/readme_tests, accv2026 test_old_defaults / test_problem_arms / scenes_testsetups) → Core's `inlier_mask(result)`
- [x] B6: the raw tuned-width readers (accv2026 run_sequential_cv anchoring stage, render_anchoring_paired) read through Eval's `tuned_width(art, arm)`; the `--arms` resumes refuse a file older than tuning format 7. The GM arms keep `format6_constant`'s default (identity): their stored widths are Welsch-grid values and their maps carry the conversion

### The Student-t keyword (owner ruling 2026-11-11: "there is no threshold for the Student-t, only the outlier half-width")

Every scorer takes its own keyword: `StudentTUniformScoring` its `outlier_halfwidth` (and its priors), never `threshold`; the
threshold scorers (RANSAC, MSAC, the loss-width families) `threshold`, never `outlier_halfwidth`. Audit of the package, accv2026,
its configs, scripts and paper (studentt-keyword-overload.md): every Student-t construction already takes a half-width
(`StudentTUniformScoring(P, a)`, `a`/`halfwidth`/`outlier_halfwidth`/`sel` the variable), every config axis is
`outlier_halfwidth` or `loss_width`, and no number crosses between the two meanings. The overloads left were prose.

- [x] accv2026/notes/sequential_cv.md:143-144 "tau*" named the tuned native width of every selector, the Student-t's half-width included → "each tuned width w* (the Student-t's outlier half-width a*, a threshold scorer's threshold)" (this commit)
- [x] test/readme_tests.jl:64 "the inlier band of their epipolar lines" for the README's Student-t + uniform scorer → "close enough to their epipolar lines for the Student-t + uniform scorer to take them as inliers" (this commit)
- [x] test/test_config_toml.jl "the Student-t path: outlier_halfwidth, never threshold": a Student-t scoring table or constructor with `threshold` is refused, MSAC refuses `outlier_halfwidth`, the table's `outlier_halfwidth` reaches the scorer exactly (`===`) and is what the posterior-weight strategies read (`required_outlier_halfwidth`), and the strategies' own tables take neither key (this commit)
- [x] the Student-t hoist downstream: README.md:52, docs/src/index.md:141 and docs/src/overview.md:43 build VisualGeometryToolkitCore's `StudentTUniformScoring(EssentialProblem, 250.0; scale_prior = JeffreysPrior(), label_prior = FlatLabelPrior())` (the install line drops RANSACScoringDoneRight; the README test runs the blocks: 205 inliers, 0.40° / 1.26°); accv2026's 57 constructions (src, scripts, tests) take `scale_prior` (was `prior`) and `label_prior = FlatLabelPrior()`, Jeffreys where none was given: the old defaults, so the scores are the same. The two in src/ and scripts/ that stated no prior (arm_rosters.jl's IG selector, run_basin_ladder.jl's template) read both priors from the stack's configuration (`scoring_from_toml`), as test_prior_codified requires (no literal prior in code) (this commit)
- [x] accv2026/test/lodr/test_old_defaults.jl:133 `find_essential(ECAM, ECAM, pxcs; threshold = 0.02)` (the sub-detector threshold refused) → `find_essential(ECAM, ECAM, pxcs; scoring = MsacScoring(EssentialProblem; threshold = 0.02))`; the refusal is still the 0.06 px floor's (checked: the message names the refinement bound), no longer the bare keyword's (robust-contract port, [sources] at vgtk-robust-core)
- [x] R12 (Core check_naming): test/test_config_toml.jl:207/213/223 spell the refused key apart (`"thres" * "hold"`, `Symbol("thres" * "hold") => 3.0`), :212's comment reads "takes no MSAC width keyword" (the switch list's "threshold-scorer width" is still within six tokens of the scorer's name, so R12 flags it); accv2026/test/lodr/test_strategies.jl:112/130 build the Student-t scorer before the MSAC one. check_naming over the repository: clean

### decision_boundary (Core 648cd520 retires the three older names of the scorer's decision point; Core's check_naming lists them)

- [x] test/test_strategies.jl:44/45 the `UniformOutlierScoring` wrapper forwards `decision_boundary`/`has_decision_boundary`
- [x] docs/src/overview.md:75, accv2026/src/arm_rosters.jl:29/182/186/188 (`decision_boundary(WelschShape(), m)`), accv2026/src/welsch_zero_clamp.jl:51/52 (argument `boundary`)
- [x] accv2026/scripts/tools/superansac_worker.jl:72 pysuperansac's own settings field is set by name, `setproperty!(c, Symbol(…), …)` with the field's name as a string (a foreign name, Core's FOREIGN_FORMAT_TOKENS); superansac.jl:300 (a string) and RansacLibLO's C++ member are foreign names: unchanged

### The 0.9 concept-level duplication audit (2026-11-12; ~/logs/dgx-agent/dup-audit-lodr.md)

- [x] the PoseLib extension's F/H re-wrap of PoseLib's FundMat/HomographyMat (SMatrix → Tuple → same type) and its dead `nothing` test → PoseLib's FitResult estimate (b2ab473)
- [x] the PoseLib workspace's re-pack of the two-view frame's correspondences → the frame as Core's external-refit contract hands it (1b4a226)
- [x] the mixture lifts' five restated posterior-state values → Core's `reset_posterior!` keeping every omitted keyword; only the inlier prior re-seeded, bit-identical (568bfdd)
- [x] accv2026's private `_cfg_path` and six `load_run_config(projectdir("configs", …))` loaders → Eval's `config_of_record` (0e65395)
- [x] accv2026 `pool_path`'s tier-root join → Eval's `tier_path`; the paper-numbers run directory → Eval's `keyed_cell_dir(…; base)` (0e65395)
- [x] the anchoring ablation's scale interface read twice and its artifact path restated at writer and reader → one constant and `anchoring_ablation_path` (protocol_folds.jl) (0e65395, aa0e75f)
- [x] the zero-clamp shape's restated Welsch r²(w̄) → Core's `zblock(::WelschShape)` (c361ca1)
- [x] the pool producer's tree (3×) and scene set (2×), and two private :E/:F/:H problem tables → `pool_tree`/`pool_scenes` (validation_data.jl) and Eval's `problem_type` (1ecf4dc)
- [x] hand-folded upstream run keys (`scorer_of_run`, `operating_points_run`, `e2e_run`, `superansac_run`) → Eval's `run_key(cfg; upstream)` through `upstream_runs` (1ecf4dc, 7a4cc92; the keys move, the stored runs are promoted)
- [x] accv2026 scripts/fetch_data.jl's copy of the catalog listing and fetch report → Eval's `fetch_data!(project_catalog())` (6ddf191)

## Not a duplicate

- `_config_default` (src/config_defaults.jl, audit 20 "defaults readers"): a one-line binding of this package's
  configs/default.toml to Core's `toml_default`; Eval's `_config_default` binds Eval's own file. No shared code.

## test_duplication

See the leg report (/home/jpr/logs/dgx-agent/cascade-09-LocalOptimizationDoneRight.md).

## 0.6.1 (on VisualGeometryToolkitEstimation 0.10)

Nothing to delete: the release widens one compat entry; the stack duplication audit lists no item for LocalOptimizationDoneRight at
this release (its open items: none). `check_duplication` runs in the suite.

## 0.6.2 (Julia 1.13)

A compat-only patch: no source, test or paper code is added, so nothing new can duplicate the stack.

- [x] 0.6.2: no new duplicate (the diff since the registered release adds no code; `check_duplication(LocalOptimizationDoneRight)` re-runs in the fresh-clone gate of this commit)
