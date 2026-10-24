# REPRODUCE — ACCV 2026 "Score Sharp, Refine Soft, Polish Hard"

Every figure/table of the paper is produced by ONE executable experiment
file under `scripts/` (stage-idempotent; `--plan` prints the stage plan,
`--stage=NAME`/`--force` control execution). Each file runs directly with
`julia --project=. scripts/<exp>.jl`; on a Slurm cluster,
`scripts/slurm/run_experiment.sbatch` is a generic wrapper that only sets the
resource shape.

## Layout

DrWatson project: `src/` holds the shared prelude (`config.jl` is the entry;
every driver starts with `using DrWatson; @quickactivate "ACCV2026"` and
`include(srcdir("config.jl"))`), `scripts/` the drivers, `scripts/tools/` the
CLIs they launch through `run_driver`, `scripts/slurm/` the launchers,
`configs/` the configs of record, `envs/` auxiliary environments (`envs/superansac`,
SupeRANSAC's), `data/` the `exp_raw`/`exp_pro` symlinks, `paper/` the
manuscript.

## Data policy (enforced by test/test_data_artifacts.jl)

- **Inputs are immutable.** Everything a driver reads but no stage of this
  project produces — the raw PhotoTourism/HEB/ETH3D inputs, the scoring pools
  once generated (frozen: a changed pool is a NEW tree, never an overwrite),
  the stored SupeRANSAC baseline — lives under the INPUT root `data_root()`
  (DrWatson's `datadir("exp_raw")`, i.e. `data/exp_raw`, or `CAU_DATA_ROOT`).
  Configs name inputs by paths RELATIVE to it; code never spells an absolute
  data path and never resolves an artifact directly (`artifact"…"`): on the
  author's host `data/exp_raw` is a symlink to the primary copy, on any other
  machine it is the artifact view `scripts/fetch_data.jl` composes from the
  published, content-addressed artifacts. Only the pool producer cells write
  under it, and only NEW trees.
- **Results are derived and DrWatson-keyed.** Every stage writes keyed run
  directories (`run_key` of the effective config; `_config.toml`,
  `_provenance.toml`) under the RESULTS root `results_root()`
  (`datadir("exp_pro")`, i.e. `data/exp_pro`, or `CAU_RESULTS_ROOT`), add-only.
  No input path resolves into it. A published results snapshot, if any, is a
  separate, read-only artifact for re-rendering, never a location drivers write.
- **Declared exception, pending the move:** the stored SupeRANSAC baseline's
  `[stored] dir` is still relative to the results root (where the author's
  copy sits); the artifact `pt_e_superansac_stored` links it there.

## On a new machine (the published data)

The inputs every figure and table regenerates from are published on Zenodo as
lazy Julia artifacts (`Artifacts.toml`: sha256- and tree-hash-pinned tarballs;
`configs/data_artifacts.toml` is the catalog — what each holds, where it
mounts, which config of record its file list is derived from; `data/README.md`
the binding). Nothing below needs the author's data host or Slurm. The data are shared with
RANSAC Scoring Done Right (NeurIPS 2026), hence the dataset-centric names, in
three records split by licence:

| record | artifacts | licence |
|---|---|---|
| PhotoTourism, [10.5281/zenodo.23240462](https://doi.org/10.5281/zenodo.23240462) | `pt_raw_validation`, `pt_raw_test` | CC BY 4.0 (our packaging; the IMC 2020 / RANSAC-tutorial / YFCC100M sources keep their terms) |
| HEB + stored baselines, [10.5281/zenodo.23240467](https://doi.org/10.5281/zenodo.23240467) | `heb_raw`, `pt_e_superansac_stored` | CC BY 4.0 (our packaging; HEB keeps its terms) |
| ETH3D, [10.5281/zenodo.23240469](https://doi.org/10.5281/zenodo.23240469) | `eth3d_splg_csponds`, `eth3d_f_pools_1k` (20 files: `eth3d_f_pools_1k_meta`, one `eth3d_f_pools_1k_<scene>` per scene, `facade` as `eth3d_f_pools_1k_facade_part1..7`) | CC BY-NC-SA 4.0 (inherited from ETH3D, share-alike) |

Each record's description lists the upstream sources to cite alongside it.

| artifact | holds | mount | needed by |
|---|---|---|---|
| `pt_raw_validation`, `pt_raw_test` (required) | the RootSIFT matches + confidences and COLMAP models of the 10 + 11 PhotoTourism scenes | data | `scripts/pt_e_pools.jl` → every PT-E cell |
| `heb_raw` (required) | the HEB `<scene>_homographies.h5` of the 10 `heb` scenes | data | `scripts/heb_h_pools.jl` → the HEB cells, `scripts/heb_inlier_stats.jl` |
| `eth3d_splg_csponds` (required) | the ETH3D SuperPoint+LightGlue correspondences (the one input made outside this repository) | data | provenance of the ETH3D-F pools |
| `pt_e_superansac_stored` (required) | the stored SupeRANSAC results of Tab. 3 | results | `scripts/e2e_ransac.jl` when `scripts/superansac_e2e.jl` has not run |
| `eth3d_f_pools_1k` (required) | the ETH3D-F pools of record, frozen; bound as one artifact per scene plus `eth3d_f_pools_1k_meta` (the run records), a scene over 1.6 GB (`facade`) as sub-parts whose chunks the fetch reassembles; fetched together | data | the ETH3D cells (`scoring_pools.jl --config=eth_f_pools` then reports them done) |

The scoring POOLS of PhotoTourism and HEB are not published: they are a pure
function of the raw inputs (`write_scene_pool`: per-pair StableRNG streams,
independent of thread count and Julia version; the fresh-machine test of
2026-10-07 regenerated all 10 HEB pools `pool_key`-identical to the author's,
and the first PhotoTourism pairs likewise) and far beyond a Zenodo record
(PT-E-SIFT-4K_pf3 ≈ 1.6 TB, HEB-H-SIFT-4K_pf3 ≈ 110 GB). Plan the disk for them
(≈ 1.8 TB under `data/exp_raw`) and the CPU time of the two pool cells (the
PT-E generation took days on one multi-GPU node).

```
# Julia 1.12 (juliaup). The stack is registered in CauRegistry (and submitted to
# General); until it is in General, add both registries once (General first: Pkg
# adds it on its own only to an empty depot):
julia -e 'using Pkg; Pkg.Registry.add("General"); Pkg.Registry.add(url = "https://github.com/prittjam/CauRegistry.jl")'   # once per depot
git clone https://github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl.git && cd LocalOptimizationDoneRight.jl/accv2026
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. scripts/fetch_data.jl            # the required artifacts
# the pools (POOL PRODUCER cells; they write into data/exp_raw)
julia --project=. -t auto scripts/pt_e_pools.jl
julia --project=. -t auto scripts/heb_h_pools.jl
# (the ETH3D-F pools are fetched, frozen: NOT regenerated — the current F solver
#  does not reproduce them bit for bit; scoring_pools.jl --config=eth_f_pools reports them done)
# then every experiment of the index below, e.g.
julia --project=. scripts/fig3_composed_miscal.jl --plan
```

Each experiment file runs directly (`julia --project=. scripts/<exp>.jl`; the
Slurm wrapper only sets the resource shape); the cv and evaluation stages want
a CUDA GPU. SupeRANSAC is optional (`scripts/superansac_e2e.jl --check`).
Packaging (author side): `scripts/tools/make_zenodo_artifacts.jl` derives each
artifact's files from the catalog and builds it with Pkg.Artifacts
(`create_artifact` → `archive_artifact` → `bind_artifact!`, lazy, the Zenodo
URLs of the catalog's record ids); `scripts/fetch_data.jl` is the consumer side
(`ensure_artifact_installed`, then the per-file links of the view).

## Experiment → figure index

One executable file per experiment (`scripts/<exp>.jl`): it declares its
inputs (`require_input` with provenance), runs idempotent stages
(`--plan` lists them; `--stage=NAME` runs one; `--force` re-runs), tunes only
through THE single CV path, audits every sidecar before consuming it, and
renders its artifact into `accv2026/paper/figures/`. The suite checks that
every stage file is listed here and that every file listed exists.
`paper/figures/` holds exactly the paper's inputs and the grid rows the two
grids compose (`paper/figures/README.md`); nothing else is rendered.

```
julia --project=. scripts/<exp>.jl --plan
sbatch [shape] scripts/slurm/run_experiment.sbatch <exp>.jl [--stage=NAME]
```

### Asset index

Every file `paper/main.tex` and `paper/supplement.tex` read, with what makes
it. This is the table the suite checks (VisualGeometryToolkitEval `PaperProjects`,
`test/test_paper_project.jl`): an asset the papers read and this table does not
list, a row the papers no longer read, or a generator that does not write its
asset fails it. The narrative tables below say what each experiment is.

| label | asset | kind | generator | config | data | provenance |
|---|---|---|---|---|---|---|
| — (colour definitions) | `paper/figures/fig_colors.tex` | static | — | — | — | hand-maintained colour table (`paper/figures/README.md`); the renderers read it and never write it |
| — (every number macro: `\OursCal`, `\Basin*`, `\Bud*`, `\Anchor*`, `\Pol*`, `\EtoE*`, `\Sel*`, `\HEB*`, the dataset counts, …) | `paper/figures/paper_numbers.tex` | generated | `scripts/paper_numbers.jl` | `configs/paper_numbers.toml` | the results of record of every cell below (each re-derived from its config), the HEB counts of `scripts/heb_inlier_stats.jl` | stages `numbers`, `emit` (run LAST); `test/test_paper_numbers.jl` refuses a hand-typed data number in the prose |
| `tab:design` | `paper/figures/table_design.tex` | generated | `scripts/timing_table.jl` | `configs/timing_table.toml` | PT-E-SIFT-4K_pf3 (british_museum), the pt_e_miscal operating points | stages `time_pt` (single thread, quiet node) and `design_table` |
| `fig:basin-ladder` | `paper/figures/panel_basin_matched.tex` | generated | `scripts/fig2_basin.jl` | `configs/pt_e_basin.toml` | PT-E-SIFT-4K_pf3 test side | basin CV, ladder (`configs/protocol.toml` `[basin_ladder]`), render |
| `fig:miscal` | `paper/figures/panel_miscal_grid.tex` | generated | `scripts/fig3_miscal_grid.jl` | `configs/fig3_miscal_grid.toml` | the rows of `scripts/fig3_composed_miscal.jl`, `scripts/supp_ETH_F_miscal.jl`, `scripts/supp_H_miscal.jl` | stage `compose` |
| `fig:sample-budget` | `paper/figures/panel_sample_budget_grid.tex` | generated | `scripts/fig4_budget_grid.jl` | `configs/fig4_budget_grid.toml` | the rows of `scripts/fig4_budget.jl`, `scripts/supp_ETH_F_budget.jl`, `scripts/supp_H_budget.jl` | stage `compose` |
| `fig:polish` | `paper/figures/panel_polish_diff.tex` | generated | `scripts/polish.jl` | `configs/polish_pt_e.toml` | PT-E-SIFT-4K_pf3 test side, the pt_e_miscal operating points | stages `test`, `summary`, `render` |
| `tab:e2e` | `paper/figures/table_e2e.tex` | generated | `scripts/e2e_ransac.jl` | `configs/pt_e_e2e_table.toml` | PT-E-SIFT-4K_pf3 test pairs; SupeRANSAC's rows from `scripts/superansac_e2e.jl` (`configs/pt_e_superansac.toml`) or its stored results; the time row from `scripts/e2e_timing.jl` (`configs/pt_e_e2e_timing.toml`, `[render] time`) | stages `live`, `summary`, `table` |
| `fig:supp-sel-miscal` | `paper/figures/panel_sel_miscal.tex`, `paper/figures/panel_sel_miscal_maa.tex` | generated | `scripts/fig1_sel_miscal.jl` | `configs/tuning.toml` | PT-E-SIFT-4K_pf3, all pairs | stages `produce`, `render` |
| `fig:supp-anchoring` | `paper/figures/panel_anchoring_paired.tex` | generated | `scripts/fig_anchoring.jl` | `configs/pt_e_miscal.toml` | PT-E-SIFT-4K_pf3 test side | `configs/miscal_protocol.toml` `[anchoring_ablation]` |
| `fig:supp-budget-time` | `paper/figures/panel_sample_budget_faceted_time.tex` | generated | `scripts/fig4_budget.jl` | `configs/pt_e_budget.toml` | the pt_e_budget curves and the `scripts/timing_table.jl` per-call times | stage `render_time` |

### Main paper

| experiment file | paper artifact |
|---|---|
| `scripts/timing_table.jl` | Tab. 1 `table_design.tex` (stage `design_table`; the per-call LO timings of stage `time_pt`, which also feed the budget time panel) |
| `scripts/fig2_basin.jl` | Fig. 1 `panel_basin_matched.tex` (perturbed-seed basin ladder) |
| `scripts/fig3_composed_miscal.jl` | PhotoTourism row of Fig. 2 (`panel_lo_miscal.tex`) and THE deployed operating-points sidecar every downstream PT-E cell reads (one full-roster tuning) |
| `scripts/supp_ETH_F_miscal.jl` | ETH3D row of Fig. 2 (`panel_lo_miscal_eth_F_main.tex`; `configs/accv2026_eth_f_miscal.toml`) |
| `scripts/supp_H_miscal.jl` | HEB row of Fig. 2 (`panel_lo_miscal_heb_H_main.tex`; `configs/heb_h_miscal.toml`, the inverse-gamma prior) |
| `scripts/fig3_miscal_grid.jl` | Fig. 2 grid (`panel_miscal_grid.tex`, composed from the three rows; `configs/fig3_miscal_grid.toml`) |
| `scripts/fig4_budget.jl` | PhotoTourism row of Fig. 3 (`panel_sample_budget_faceted.tex`) and the time panel `panel_sample_budget_faceted_time.tex` (`configs/pt_e_budget.toml`) |
| `scripts/supp_ETH_F_budget.jl` | ETH3D row of Fig. 3 (`panel_sample_budget_eth_F.tex`; `configs/accv2026_eth_f_budget.toml`) |
| `scripts/supp_H_budget.jl` | HEB row of Fig. 3 (`panel_sample_budget_heb_H.tex`; `configs/heb_h_budget.toml`, at heb_h_miscal's inverse-gamma operating points) |
| `scripts/fig4_budget_grid.jl` | Fig. 3 grid (`panel_sample_budget_grid.tex`; `configs/fig4_budget_grid.toml`) |
| `scripts/e2e_ransac.jl` | Tab. 3 `table_e2e.tex` (`--config=pt_e_e2e_table`): our deployed pipeline end to end on every PhotoTourism test pair, beside SupeRANSAC's rows (the SupeRANSAC cell's results, or its stored ones) |
| `scripts/e2e_timing.jl` | the time row of Tab. 3 (`--config=pt_e_e2e_timing`; `\EtoE*Ms`): ours and SupeRANSAC timed on the same drawn test pairs, pinned single-threaded runs, repeated ("End-to-end timing" below). Needs SupeRANSAC installed (`scripts/superansac_e2e.jl --check`) and a quiet machine |
| `scripts/superansac_e2e.jl` | the SupeRANSAC rows of Tab. 3 (`configs/pt_e_superansac.toml`): its loss-width CV on our validation units and its evaluation on the same test pairs. SupeRANSAC is an OUTSIDE dependency (`envs/superansac`; `--check` says whether it is installed, the cv/eval stages print the installation steps when it is not); without it the table reads the stored results named by `[stored] dir` (`<results>/phototourism/sift/E/SupeRANSAC/stored-e2e-3ea0c00581858498/`, the published rows, with their PROVENANCE.toml) |
| `scripts/heb_inlier_stats.jl` | the per-pair counts (correspondences, GT inliers) behind the HEB dataset statistics of Sec. 4 (`\HEBCsMed`, `\HEBInlMed`, …; `configs/heb_stats.toml`), which `scripts/paper_numbers.jl` typesets |
| `scripts/paper_numbers.jl` | THE one generated macro file `paper_numbers.tex` (`configs/paper_numbers.toml`): every number `main.tex` and `supplement.tex` state, from the cells' results of record; run after every cell |
| `scripts/fig1_sel_miscal.jl` | scoring-only miscalibration (`panel_sel_miscal{,_maa}.tex`, supplement figure; the main paper quotes its numbers) |

### Supplement

| experiment file | paper artifact |
|---|---|
| `scripts/fig_anchoring.jl` | `panel_anchoring_paired.tex` |
| `scripts/polish.jl` | `panel_polish_diff.tex` (configs/polish_pt_e.toml; the main paper's `\Pol*` numbers are `scripts/paper_numbers.jl`'s, from its polish_test.jld2) |

### Data builders and maintenance tools

Two-view scoring pools are produced by POOL PRODUCER cells like every other
artifact: a config of record plus a stage-idempotent experiment file, launched
directly or through the Slurm wrapper. NOTHING is stated on a command line.

| experiment file | config of record | tree |
|---|---|---|
| `scripts/pt_e_pools.jl` | `configs/pt_e_pools.toml` | PT-E-SIFT-4K_pf3 (the pool every main-paper cell reads) |
| `scripts/heb_h_pools.jl` | `configs/heb_h_pools.toml` | HEB-H-SIFT-4K_pf3 (the budget protocol's test pools) |
| `scripts/scoring_pools.jl` | `--config=<name>`, any two-view pool config (`configs/*_pools.toml`) | the config's `pool_dir` |

```
scripts/slurm/launch_pool_regen.sh heb_h_pools pt_e_pools     # both cells, in parallel
sbatch [shape] scripts/slurm/run_experiment.sbatch pt_e_pools.jl [--stage=pools|audit]
```

`scripts/slurm/launch_pool_regen.sh` is the launcher of record: one Slurm chain
per cell (its stages `--dependency=afterok`), the cells in parallel, every
stage `--gres=gpu:0` (pool generation is CPU-threaded, and a days-long pools
job must not hold a GPU the cv stages need — `run_experiment.sbatch` defaults
to `gpu:1`). Resource shapes live in the launcher, NOT in the cells' TOMLs:
`run_key` hashes the effective config, so a cpu count stated there would
re-key the pools it generates. Skip-if-done makes re-launching the whole thing
the way to resume an interrupted generation.

It takes each cell's stage list from `--plan`, not from a grep of the driver
text: a grep for `Stage(:name` (the retired fleet launcher's method) yields an
EMPTY chain — zero jobs submitted, no error — for a config-driven driver whose
stages are built in `src/cell_stages.jl`.

Both delegate to `scripts/tools/generate_scoring_pools.jl`, THE two-view pool
driver (VisualGeometryToolkitEval's dataset readers → VisualGeometryToolkitCore's
`Pools.PoolPair` → VisualGeometryToolkitEval's `write_scene_pool`). It takes
`--config=<name>` and nothing else: every generation parameter comes from that
TOML (its `[pool]` table, the 4000-sample targets included).

**Minimal-sample starts of a pool tree** (`scripts/tools/derive_pool_samples.jl
--config=<pool config>`). A pool stores no per-model sample id; VisualGeometryToolkitEval
`Pools.sample_starts(pool)` recovers the boundaries from the record (a repeated
draw is its own sample) and certifies them against the pool's `total_samples`
stamp. ETH3D-F and HEB-H certify; PT-E-SIFT-4K_pf3 does not (276 of 46,200 pairs
hold an E solve whose duplicated root reads like a repeated draw), so this tool
replays the generator's seeded streams and writes the exact starts as derived
data under `<results>/phototourism/sift/E/PoolSamples/samples-<key>/` (give a
scene's file as `sample_starts(pool; derived = …)`). The paper's budget cells
count MODELS (`configs/sample_budget_protocol.toml`), so they read no sample
starts; a `:samples` budget and RANSACScoringDoneRight's scoring-only budget
experiment do.

**Regenerate every pool after the 2026-10-01 map rename.** The pool record's
pixel → pool-frame maps became `source_map`/`target_map` (the record is now
VisualGeometryToolkitCore's `Pools.PoolPair`, read and written by VisualGeometryToolkitEval's
pool IO), and pool files carried `pool_format = 2` (then
the evaluation engine's `ARTIFACT_FORMATS.pool`, now VisualGeometryToolkitEval's; 3 with the stable streams —
see "Result-changing changes of 2026-10-01" below — and now 4). Every pool written before is format 1 and is refused on
read — `ArgumentError: <file>: pool format v1 predates the source_map/target_map
rename — regenerate the pool` — and is NOT migratable.
Regenerate each tree through
its POOL PRODUCER cell into a NEW out-dir, then point the consuming configs at
it. The main-paper trees are `scripts/pt_e_pools.jl` (PT-E-SIFT-4K_pf3) and
`scripts/heb_h_pools.jl` (HEB-H-SIFT-4K_pf3); the ETH3D-F tree is
`scripts/scoring_pools.jl --config=eth_f_pools`.

A REGENERATED HEB TREE NEEDS NO `_extrinsic` STEP. The current generator stamps
`gt_convention = "extrinsic"` on every pool and `Loaders.migrate_heb_pool`
refuses a source that already declares one; the retired `*_extrinsic` trees
were a one-time repair (2026-09-22) of the April pools' inverse GT motion
(Rᵀ, −Rᵀt). The April pool-frame sidecars (an older suffix, read as
`<scene>.pool_frame.jld2` by the current reader) serve only that retired
repair.

`pool_is_native` IS NOT A CURRENCY CHECK, AND IS WRONG IN BOTH DIRECTIONS. It
reads `native_layout`, which is a MIGRATION stamp written by
`migrate_pool_file!` / `migrate_heb_pool`, not by the generator:

| key | fresh (generated) | retired (migrated 2026-09-22) |
|---|---|---|
| `pool_format` | `3` | ABSENT — refused on read as v1 |
| `native_layout` | ABSENT | present, naming the CURRENT versions |

So `native_layout` is not a currency marker: `pool_format` is, and the only
proof is a READ through the package reader (VisualGeometryToolkitEval `load_pool`),
which is what both cells' `audit` stage does.

**Regenerate every tuning artifact after the 2026-10-01 tuning-spec format.**
Every cross-validation is now a `[tuning.<name>]` spec read by
VisualGeometryToolkitEval's one `[tuning]` parser — the schema is documented
once, in the header of VisualGeometryToolkitEval `src/tuning/toml.jl`; this paper's protocol of
record is `configs/tuning.toml` (entries `miscal`, `budget`,
`lo_sensitivity`, `lo_sensitivity_natural`, `lo_sensitivity_miscal`,
`polish`), and a cell layers its overrides over the entry it uses
(`src/protocol_folds.jl`; `run_key` resolves the layered entry to its complete
table, so every tuning parameter — inherited defaults included — keys the
run). Every tuning artifact is written by `save_tuning_artifact` (format stamp
`tuning_format`, the spec, its hash, the GRID SPECS — realized grids are
rebuilt from them bit-exactly — and the code identity) and read by
`load_tuning_artifact`, which REFUSES an artifact of another format:
`ArgumentError: <file>: tuning format v1 predates the persisted [tuning] spec
and grid specs (v2) — regenerate it`. Nothing is migrated; the
artifacts to regenerate are listed once, below (current format: v4).

**Regenerate every tuning artifact after the 2026-10-01 codified
cross-validation (tuning format v3).** The data of every tuning is part of
its spec: `[tuning.<name>.cross_validation]` (VisualGeometryToolkitEval
`CrossValidation`) names a scene split REGISTERED in VisualGeometryToolkitEval
`configs/splits.toml` — the ONE file holding every scene list (this project
holds none; `test/protocol_invariants.jl` refuses a registered scene literal
in src/, scripts/, configs/ or test/) — and how each side's units are sampled
(`all`; `stratified` — a fraction of each scene, then at most `cap_per_scene`,
drawn by a seed keyed on the scene's NAME, sorted last; `simple_random` —
pooled). The paper's main split is stated once (`[types.cross_validation]` of
`configs/tuning.toml`, PhotoTourism); a cell names its own through its
`configs/cv_protocol.toml` section. The resolved scene lists are in the spec's
table, so in its hash, the run key and every artifact; the validation-budget
draws are the spec's `budget_sampling` (draw r of budget n from
`stable_seed(seed, "budget", n, r)`, its interval's resampling from
`stable_seed(seed, "resampling", n)`). The drivers accept the samplings they
implement by SIGNATURE (`src/validation_data.jl`: two-view = every pair or a
stratified sample — anything else is a `MethodError`), and every evaluation reads
the TEST side of the cross-validation its sidecar was tuned under. Removed:
the `--val`/`--test`/`--np`/`--scenes` driver flags and their scene defaults,
`[experiment] split`, the budget cells' `scenes`/`scenes_split`/`scenes_mode`,
the `:disk` complement test sides, and the polish CV's
first-200-pairs prefix (now `cap_per_scene = 200`). An artifact of format v2
is refused (`tuning format v2 predates the codified cross-validation …
regenerate it`); the registry stamps were bumped, so each stage
simply runs:

| artifact | producing stage |
|---|---|
| PT-E `scorer_cv.jld2` → `refiner_cv.jld2` → `operating_points.jld2` (the sequential CV, 2026-10-04) in the KEYED dir `phototourism/sift/E/Miscalibration/sequential-cv-<key>/` of `configs/pt_e_miscal.toml` (`src/registry.jl` derives `EXP_MISCAL_DIR` by `miscal_sidecar_of("pt_e_miscal")`, the one rule of every cell — no stamp) | `fig3_composed_miscal.jl --stage=cv` |
| basin `operating_points.jld2` (mode "basin") in `phototourism/sift/E/Basin/sequential-cv-<key>/` of `configs/pt_e_basin.toml` — its scorer READ from PT-E's (`scorer_of`) — then the ladder `basin-ladder-sequential-cv-<key>/ladder.jld2` (stamp derived from the basin cell's key; the sidecar's test side; perturbations from `stable_seed(EXP_LADDER_SEED, scene, pair, δ)`) | `fig2_basin.jl --stage=basin_cv`, `--stage=ladder_test` |
| HEB-H `operating_points.jld2` in `heb/sift/H/Miscalibration/sequential-cv-<key>/` of `configs/heb_h_miscal.toml` | `supp_H_miscal.jl` (all stages) |
| ETH3D-F `operating_points.jld2` in the keyed dir of `configs/accv2026_eth_f_miscal.toml` (its pools regenerated at the current pool format first) | `supp_ETH_F_miscal.jl --stage=cv` |
| the selection-only M-bundle `miscal-sel-allpairs-v5/bundle.jld2` | `fig1_sel_miscal.jl --stage=produce` |
| the polishing run `Polish/polish-<key>/polish_test.jld2` (nothing tuned; E_LO checked pair for pair against pt_e_miscal's sidecar) | `polish.jl` |
| the partition-anchoring ablation evaluation `anchoring_ablation-fixed/zeta_evaluation.jld2` inside fig3's keyed dir (NEW: the anchoring figure's WITHOUT side is now regenerated — see below) | `fig_anchoring.jl --stage=evaluation` (GPU), then `--stage=render` — AFTER `fig3_composed_miscal.jl --stage=cv` |
| everything consuming the above: the keyed `budget-<key>` cells, the oracle floors (the floors' `sources` check refuses a floor computed on other pools or test scenes), the timing runs, the keyed end-to-end cell `e2e-<key>` and the SupeRANSAC cell `superansac-<key>` (its inputs, `loss_width_cv.jld2`, `zeta_<scene>.jld2`) | `fig4_budget.jl`, `supp_*_budget.jl`, `supp_*_miscal.jl --stage=oracle`, `timing_table.jl`, `e2e_ransac.jl --config=pt_e_e2e_table`, `superansac_e2e.jl` (all stages) |

The ζ EVALUATION ladder stays `configs/miscal_protocol.toml`; the coverage
windows of the tuning entries that read it out carry the ladder's reach
(`zeta_octaves`) and the drivers refuse a mismatch (`check_zeta_reach`). No
frozen input remains: every file a driver consumes is produced by a stage.

## Data prerequisites (provenance)

- **PT-E-SIFT-4K_pf3 scoring pools** — `<data root>/accv2026/data/PT-E-SIFT-4K_pf3/<scene>.jld2`
  (~72–84 GB/scene, ~2 TB total; **stream one scene at a time, never slurp**).
  Built by `scripts/pt_e_pools.jl` from the public **IMC PhotoTourism**
  release plus the RANSAC Tutorial data. The five raw trees it reads — the two
  tutorial-split match dirs, the TestData match dir, and the two COLMAP recon
  dirs — plus the `[source.recon_special]` exceptions for `reichstag` and
  `florence_cathedral_side` (whose models sit outside the recon tree) are
  DECLARED in `configs/pt_e_pools.toml` and handed to the reader
  (VisualGeometryToolkitEval `PtRawTrees`)
  (RootSIFT matches, 4000 minimal-sample models/pair, pool-frame Sampson
  residual matrices, COLMAP pseudo-GT poses + oracle `gt_variance`).
  Scene split: the registered `phototourism` split of VisualGeometryToolkitEval
  `configs/splits.toml` (10 val / 11 test, as-run canonical), named by every
  tuning spec's `cross_validation`.
- **HEB-H-SIFT-4K_pf3 scoring pools** — `scripts/heb_h_pools.jl` from the
  ETH HEB release's `<scene>_homographies.h5` (its SIFT matches and per-match
  GT inlier flags), the registered `heb` split.
- **ETH3D SP+LG F pools** — the native tree
  `datasets/eth3d/derived/splg/scoring_data_F_pf3` under `data/exp_raw`
  (`scripts/scoring_pools.jl --config=eth_f_pools`, from the consolidated
  SP+LG correspondences); the ETH3D cells' configs name it in
  `experiment.pool_dir`.
- **Results roots** — per-cell tree `<results root>/…`
  (VisualGeometryToolkitEval `results_root()`: `CAU_RESULTS_ROOT` or the `data/exp_pro` link, see
  `data/README.md`), flat campaign root `<data root>/accv2026/…`
  (`ACCV_DATA` overrides; `src/registry.jl` is the one place that binds these).
- **Stored SupeRANSAC results** — `<results>/phototourism/sift/E/SupeRANSAC/stored-e2e-3ea0c00581858498/`
  (`configs/pt_e_superansac.toml` `[stored] dir`): the per-scene ζ sweeps,
  loss-width tuning artifact and tuning units behind the published Tab. 3,
  copied 2026-10-07 from the e2e cell of record `e2e-3ea0c00581858498`
  (2026-10-04; its config, provenance and summary copied beside), with
  `PROVENANCE.toml` and `SHA256SUMS`. The table reads them when the SupeRANSAC
  cell has not run.

## THE single-CV-path contract (binding)

All hyperparameter tuning flows through one code path under one spec — no
experiment may implement its own sweep/argmin or state a tuning parameter
outside a `[tuning.<name>]` entry (mandated 2026-07-18; the spec form
2026-10-01; schema: the header of VisualGeometryToolkitEval `src/tuning/toml.jl`):

Every stage is composed from TWO grid-search primitives (VisualGeometryToolkitEval
`Evaluation.expanding_search` and `bracket`), BATCHED: one objective call per
round holds every cell's new points, so cells sharing an expensive objective
(one sweep over a staged validation pool) share every sweep.

1. **Coarse** — `probe_curves_batched` (point-wise: `probe_curve`): the spec's
   coarse grid, expand-on-boundary by the spec's `extension` (points per side,
   rounds) at its `edge_margin`. Windows are located by expansion, never
   hand-pinned or hand-widened.
2. **Fine** — `fine_stages_batched` (`fine_stage`): the spec's fine spacing over
   the coarse argmin's bracketing neighbours, free argmin.
3. **Artifact** — the spec, its hash and every grid spec (coarse, fine) are
   persisted by `save_tuning_artifact` with the probe records.
4. **Readers refuse** — every consumer hard-errors on `boundary_hit = true`
   (`enforce_probe_interior`; the `deployed_*` readers on the sidecar's
   per-arm `boundary_hits`) and on another artifact format. The experiment
   files additionally run `audit_*` on every artifact BEFORE consumption.

THE tuning of every two-view cell is the SEQUENTIAL CV
(`scripts/tools/run_sequential_cv.jl`, `notes/sequential_cv.md`): each
selector's width on the selection-only error (`scorer_cv.jld2`), then every
refiner's width at its selector's a* read back from that artifact
(`refiner_cv.jld2`), then the ζ evaluation at the tuned points
(`operating_points.jld2`) — each a separate artifact a later stage reads. The
composed (selection, refinement) PRODUCT GRID it replaced
(`run_product_tuning.jl`) was retired on 2026-10-04. SupeRANSAC's one knob,
its loss width (`scripts/superansac_e2e.jl`, `src/superansac.jl`), is tuned
through the same batched coarse-fine path under its cell's
`[tuning.superansac_loss_width]`.

## End-to-end timing (Tab. 3's time row, since 2026-10-14)

Accuracy and time are two runs. The ACCURACY run (`scripts/e2e_ransac.jl
--config=pt_e_e2e_table`, stage `live`) runs every test pair multithreaded:
each pair draws from its own stream (`stable_seed(seed, stream, scene,
pool_index)`), so its errors do not depend on the thread count. The TIMING run
(`scripts/e2e_timing.jl --config=pt_e_e2e_timing`) is separate, every setting
in its config of record:

- the pairs: `[timing] sample`, VisualGeometryToolkitEval's unit sampling (the
  vocabulary of the cross-validations' sides) over the e2e cell's test units —
  stratified by scene, 2 % of each of the 11 test scenes (44 pairs, 484 in
  all), drawn pair ids in `timing-<key>/sample.toml`;
- the process: one fresh Julia process per repeat, `numactl --physcpubind=<cpu>
  --membind=<numa_node> julia -t 1 --gcthreads=1` with BLAS/OpenMP at one
  thread (`[timing.pinning]`); the worker refuses any other affinity;
- warm-up: `[timing] warmup_pairs` pairs of each scene at every ζ, untimed,
  in every worker process; a GC before each (scene, ζ) block, outside the
  brackets; the bracket is the `ransac` call (ours) or the
  `estimateEssentialMatrix` call (SupeRANSAC), as in the accuracy run;
- repeats: `[timing] repeats` runs per system, ours and SupeRANSAC
  alternating on the same CPU and the same pairs (SupeRANSAC at its cell's
  tuned loss width, in `envs/superansac`);
- the statistic (`timing.tsv`): per pair the median over the repeats, per scene
  the median over its pairs, the mean over the scenes [ms]; the run-to-run
  spread is the same statistic of each repeat alone (`rep_min_ms`,
  `rep_max_ms`, `rep_spread_pct`);
- the record: `timing_repeats.toml` (per repeat: host, CPU model, the pinned CPU,
  the load averages before and after, the pinned CPU's busy share taken by
  other processes and its SMT sibling's), `timing_code.toml` (every
  package checkout's commit), `_provenance.toml`.

The summary refuses a timing repeat whose errors differ from the accuracy run's
on the same pairs (same deployment, same streams: they must agree bit for
bit). `scripts/e2e_ransac.jl` stage `table` and `scripts/paper_numbers.jl`
(`[sources.e2e_timing]`, the `\EtoE*Ms` macros) read the time row from
`timing.tsv`; `test/test_e2e_timing.jl` checks the config and that no time
number comes from anywhere else.

## The partition-anchoring figure (regenerable since 2026-10-01)

`fig_anchoring.jl` (`panel_anchoring_paired.tex`) is a PAIRED ABLATION at ONE
set of operating points, fig3's full-roster tuning: the SOLID (WITH) side is
fig3's own ζ evaluation (the scale-multiple arms' loss width partition-anchored,
`scale_multiple·ŝ`); the DASHED (WITHOUT) side is stage `evaluation`, the SAME
tuned points re-read on the same ladder, test scenes and seeds with the loss
width delivered at a fixed external plug-in scale corrupted by ζ
(`with_width(lo, fixed_width(lo, (ζ·s0)²))`, s0 the reference scale of the
validation pairs' ORACLE σ̂² — `configs/pt_e_miscal.toml` `[sequential_cv]
plugin_scale`; `run_sequential_cv.jl --stage=anchoring`, the interface declared
in `configs/miscal_protocol.toml` `[anchoring_ablation]` and recorded in the
artifact). Regenerate after fig3's `cv`:

    julia --project=. scripts/fig3_composed_miscal.jl --stage=cv
    julia --project=. scripts/fig_anchoring.jl --stage=evaluation   # GPU: the test side only
    julia --project=. scripts/fig_anchoring.jl --stage=render

The WITHOUT side CHANGED MEANING. It used to be a frozen forensic input — the
June–July 2026 production tuning read out under the pre-2026-07-18 window
delivery (`miscal-2knob-newarms/two_knob_merged12.jld2`, sha256-pinned in the
retired `configs/frozen_inputs.toml`), i.e. a DIFFERENT, historical tuning
whose producing code no longer exists. It is now the paired ablation above:
nothing differs from the WITH side but the scale interface. The dashed TLS
curve is accordingly TLS-IRLS-ŝ at the fixed plug-in, not the old fixed
`c_ref` TLS-IRLS arm; caption and text must say so.

## Correspondences (the one step outside this repository)

The `derived/splg/csponds` tree under `data/exp_raw/datasets/eth3d/`
(SuperPoint+LightGlue) is produced by a separate feature-matching tool
(`densematch-tools`, `extract_splg_batch.py --manifest <pairs.tsv>`), not by
this project. It carries the `manifest.tsv` of the image
pairs it was extracted for and one file per scene; the pool generator reads
those. PhotoTourism and HEB ship their matches. Everything from the pools down
regenerates here.

## Oracle floors (provenance)

`<results root>/accv2026/oracle_floors.jld2` — the pool-best selection bound
drawn on every miscalibration panel — has ONE writer,
`scripts/tools/compute_supp_oracle_floors.jl`, invoked only by a driver's `oracle`
stage (`fig3_composed_miscal.jl` for PT_E, `supp_*_miscal.jl` for the other
cells). Besides `floors[<TAG>]` / `floors[<TAG>_maa]` it records
`sources[<TAG>]`: the pool tree, problem and test scenes the floor was
computed on. A driver's `oracle` stage is DONE only when that source is the
cell's current pool tree and test scenes (`oracle_floor_done`,
`src/common.jl`), and its render stage refuses a floor whose source does
not match, so a floor computed on retired pools cannot be taken as current.

## Running on your own machine

- Bind the data and results roots first (`data/README.md`: the `data/exp_raw`
  and `data/exp_pro` links, or `CAU_DATA_ROOT` / `CAU_RESULTS_ROOT`). You need
  the inputs and the pools: fetch the published inputs and regenerate the
  PhotoTourism and HEB pools from them ("On a new machine" above). Each
  experiment file runs directly (`julia --project=. scripts/<exp>.jl`); the
  sbatch wrapper only sets the resource shape. The cross-validation stages
  expect a CUDA GPU.
- Renders are pure CPU + the sidecars/bundles: with the produced artifacts
  synced, `--stage=render` regenerates every committed panel byte-for-byte.
- The manuscript (`paper/`) receives the panels in `figures/` (`PAPER_FIGS`
  overrides); recompile `main.tex` afterwards.

## Protocols of record (folded into every run key)

| protocol file | governs |
|---|---|
| `configs/tuning.toml` | THE tuning protocol: every `[tuning.<name>]` entry the drivers run (windows, spacings, expand-on-boundary rules, argmin, objective, budget sampling, cross-validation), stating only what differs from VisualGeometryToolkitEval's `configs/tuning.toml`; paper-level type defaults (`[types.scale_multiple_window]`, the paper's [1, 3.3]; `[types.cross_validation]`, the registered `phototourism` split) |
| `configs/cv_protocol.toml` | tuning at ζ=1; per-dataset cross-validations (partial `cross_validation` tables layered into the tuning entry: the registered scene split and the validation sampling; test sides never subsampled) |
| `configs/miscal_protocol.toml` | ζ evaluation ladder (n_zeta, zeta_octaves) |
| `configs/sample_budget_protocol.toml` | per-dataset stream depth / checkpoint schedule (explicit `checkpoints` overrides the batch/lo_every rule) |
| `configs/protocol.toml` | THE experiment protocol: `[arms]` (the equal LO update budget `lo_iteration_budget`, the Lebeda ladder `[arms.lebeda]` of the RansacLib TLS-LO arms, every per-arm deviation with its reason — folded into the key of every cell that builds arms, `fold_arm_protocol!`) and every experiment's result-changing value (the basin ladder, the scale-estimation floor; a timing fixture's scene and pairs are stated by its stage file), read by `src/protocol.jl` `protocol_value` and nowhere spelled in code; and `[paper] welsch_hq`, WHICH recorded Welsch-HQ z-block the paper shows as "Welsch-HQ" (the zero-clamp `IG  +Lift@zc`, as submitted; presentation only, in no run key — figure_style.jl, the timing row, the anchoring reference, and the e2e/polish cells' arm lists, which the suite checks) |

### The K+ tag renames (re-key, 2026-10-09)

The K+ stack renamed config tags (unit samplings `"all"` → `"exhaustive"`,
selector `"ig"` → `"student_t_uniform"`, the anchoring interface `"fixed"` →
`"fixed_scale"`), so every keyed cell moved to a new run directory although no
number did. The old → new map of every key, computed by VisualGeometryToolkitEval
`Experiments.rekey_map` from the previous runs' `_config.toml` and checked
against the K+ fold, is `<results>/_rekey/kplus-20261009.toml`. Every cell was
rerun on the K+ stack: every evaluation, tuning artifact, budget curve, ladder,
polish and end-to-end per-pair result is bit-identical to the previous run;
only wall-clock times differ.

### The 2026-10-07 slimming (rerun)

The project was cut to exactly what the paper and supplement use (the
ScanNet1500, 7-Scenes, Aachen, InLoc, RoMa, ETH3D-E and PhotoTourism-F cells,
the PnP code, the superseded end-to-end drivers, the unused tables and panels are in git
history). Two consequences for the keys: `configs/protocol.toml` lost
`[arms.tls_lo_pnp]` (the PnP ladder's LM cap), and `[arms]` is folded into
every arm-building cell's run key, so EVERY such cell re-keys and reruns —
regenerate from scratch. The HEB budget row of Fig. 3 now reads the
inverse-gamma operating points of `heb_h_miscal` (the Jeffreys comparison cell
is retired). The SupeRANSAC rows of Tab. 3 are their own cell
(`scripts/superansac_e2e.jl`), no longer the earlier SupeRANSAC drivers.

### Result-changing changes of 2026-10-01 (rerun)

- **The LO budget is one declared value** (`[arms] lo_iteration_budget = 25`)
  that every arm reads, with the deviations declared beside it (GNC's entry
  width, TLS-LO+'s trials derived from the budget, TLSadapt's one LM iteration
  per round). The values are those the arms
  ran with, so no result moves; the `[arms]` table is now folded into every
  arm-building cell's run key, so every such cell gets a new run directory.
- The basin ladder's perturbation and bootstrap streams are StableRNGs
  (`basin-ladder-v5`); the polish table's bootstrap likewise (render stage).
- The evaluation engine (same date; now VisualGeometryToolkitEval): every random stream feeding a
  persisted result is a StableRNG keyed by `stable_seed` (never `Base.hash`,
  never `MersenneTwister`/`Xoshiro`, whose streams Julia does not keep across
  versions): the pool subsample and per-pair pool draws (pool format 3 —
  regenerate every pool), the
  tuning unit samplings (tuning format 4 — every tuning artifact), the live
  e2e runs. `run_key` is the SHA-256 of the effective config's sorted TOML, so
  every keyed run directory moves. Together with the pool regeneration this
  reruns every cell; the fixed-arm results move only through these streams.

Render knobs live in each cell config's `[render]` section (consumed via the
stage env) — never shell literals or code heuristics.

## Config-driven cells (`configs/<name>.toml` = single source)

Every cell's effective config (its TOML plus the protocols of record folded
in by `src/protocol_folds.jl`, THE one fold recipe; which cv_protocol
section a cell tunes on is declared in its TOML as `[protocol] cv_section`,
which tuning entries as `[sequential_cv]`; each layered entry resolved to
its complete table) is hashed into its
run directory (`VisualGeometryToolkitEval.Experiments.run_key`; the `[render]`
section is excluded). Consumers re-derive a producer's key from the config
name (`miscal_sidecar_of`, `operating_points_run`) — keys are derived, never copied.

Pools are the native trees (PT-E-SIFT-4K_pf3, HEB-H-SIFT-4K_pf3,
`scoring_data_F_pf3` of eth3d/splg); a tree that no longer deserializes natively is converted ONCE,
never read through a compatibility layer. Pool
trees are immutable inputs: regeneration writes NEW dirs; a stale tree is
retired, not overwritten.
