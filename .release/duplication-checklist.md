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
- [x] `LO_TAGS`, `_LO_REGISTRY`, `_TOML_DEFAULTS`, names VisualGeometryToolkitEstimation owns (test_duplication `[name]`) → `STRATEGY_TAGS`, `_STRATEGY_ROWS`, `_DEFAULTS_OF_RECORD` (7a3013a)
- [x] accv2026's four keyed cell directories and two config loaders restated (test_duplication `[similar]`: `e2e_timing_dir`, `budget_cell_dir`, `e2e_cell_dir`, `superansac_cell_dir`; `e2e_timing_cell`, `superansac_cell`) → `keyed_cell_dir` and `config_of_record` in accv2026/src/protocol_folds.jl (bb20c31)
- [x] the two timing benches' call-set reader (`read_fixture`, `pool_csponds`, `problem_of`) and VisualGeometryToolkitCore's `calibration_spread`/record writer restated in both (audit 2; test_duplication `[similar]`) → one test/lo_timing/call_set.jl and Core's test/lo_timing/bench_record.jl (08a5135)

## Hoists into the stack

Common code no stack package offers yet (each is a copy of a stack package's TEST code, which nothing downstream can
call). Not kept by choice: each waits for its owner to publish it, and the switch here is noted.

- [ ] hoist the scene builders of accv2026/test/lodr/test_problem_arms.jl that restate VisualGeometryToolkitEstimation's tests (audit 2; test_duplication `[similar]`): `_board_scene` (pnp_lens_tests.jl:37), `_box` (ransac_fundmat_tests.jl:30), `_gt_model`/`_make_scene` (radial_homography_tests.jl:26/38), `_board` (radial_camera_tests.jl:29), `_contaminated_line` (line_fitting_tests.jl:97) → Estimation's `test_scenes()`, as new families or members: `PoseScenes.lens_board_scene(rng, camera, R, t; σ, n_out)`, `EpipolarScenes.box_point_far(rng)` (or `box_point` with the box as keywords), `RadialScenes.radial_homography(k_norm)` / `RadialScenes.radial_homography_pairs(rng, model; n_in, n_out, σ)`, `RadialScenes.radial_board(rng; f, k, n_out, σ)`, `Contamination.contaminated_line(rng, …)` (the owner reconciles the keyword differences first). Callers: test_problem_arms.jl. The switch: each local definition deleted, the family added to the item's `setup = [...]`.
- [ ] hoist `two_view` of accv2026/test/lodr/test_bcd_recorded.jl (audit 2; test_duplication `[similar]` against Estimation's test/bcd_recorded_tests.jl:21) → Estimation's `test_scenes().EpipolarScenes.contaminated_pixel_pairs(rng, n; planar)`; and `check_recorded` (audit 2, ibid. :101) → VisualGeometryToolkitCore's Test extension, `test_recorded(make)` (a `Recorded` run equals the bare run, iterate for iterate; `Recorded` is Core's). Caller: test_bcd_recorded.jl. The switch: two deletions and one import.
- [ ] hoist `subpair` and `scene` of accv2026/test/test_engine_integration.jl (audit 2; test_duplication `[similar]` against VisualGeometryToolkitEval's test/evaluation_engine_tests.jl:124/:597) and its `write_sidecar` (audit 2, ibid. :728) → a VisualGeometryToolkitEval Test extension (`test_fixtures()`: `subpair(pair, cols)`, `engine_scene(...)`, `write_sidecar(path, arms; mode, hits)`). Caller: test_engine_integration.jl. The switch: one import.
- [ ] hoist the bench scene of test/lo_timing/bench.jl `scene()` (test_duplication `[similar]` against VisualGeometryToolkitCore's test/lo_timing/bench.jl:38, the same seeded 1000-point E scene) → Core's test/lo_timing/bench_record.jl (`essential_bench_scene(rng; n)`), which both benches already include. The switch: the local definition deleted.
- [ ] hoist test/lo_timing/call_set.jl (the LOFX0001 call-set reader, also in VisualGeometryToolkitEstimation's test/lo_timing/bench.jl:44, the same fixture file) → Estimation's test/lo_timing/call_set.jl (`read_fixture`, `pool_csponds`, `problem_of`), included from `pkgdir(VisualGeometryToolkitEstimation)` as Core's bench record is. The switch: one include path.
- [ ] hoist accv2026 `artifact_catalog()` (src/data_artifacts.jl:30; audit 20, also RANSACScoringDoneRight's neurips2026) → VisualGeometryToolkitEval DataArtifacts `project_catalog(project_root = projectdir())`. The switch: one import.
- [ ] hoist `keyed_cell_dir(cfg, experiment, kind)` and `config_of_record(name)` (accv2026/src/protocol_folds.jl; every paper project spells a keyed run directory `<experiment_dir>/<Experiment>/<kind>-<run_key>` and loads `configs/<name>.toml`) → VisualGeometryToolkitEval Experiments, beside `experiment_dir` and `load_run_config`. The switch: delete the two definitions, import them.

## Not a duplicate

- `_config_default` (src/config_defaults.jl, audit 20 "defaults readers"): a one-line binding of this package's
  configs/default.toml to Core's `toml_default`; Eval's `_config_default` binds Eval's own file. No shared code.

## test_duplication

See the leg report (/home/jpr/logs/dgx-agent/cascade-09-LocalOptimizationDoneRight.md).
