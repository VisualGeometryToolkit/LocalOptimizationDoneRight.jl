# Reproducing the paper

The research project `accv2026/` produces every figure and table of the paper. It
is a DrWatson project that devs the package by path (`[sources]` in
`accv2026/Project.toml`) and pins its environment in a tracked `Manifest.toml`.
`accv2026/REPRODUCE.md` is the authoritative experiment → artifact index and
records the data provenance; this page summarizes it.

## Layout

| path | contents |
|:---|:---|
| `accv2026/src/` | the shared prelude: `config.jl` (entry), `registry.jl` (every path), `arm_rosters.jl` (THE arm table and the paper's `Roster`), `protocol_folds.jl` (the run-key fold recipe), `cell_stages.jl` (the shared stage builders), `figure_style.jl`, … |
| `accv2026/scripts/` | one executable driver per experiment: `fig*`, `supp_*`, the pool producers, the table drivers (`timing_table.jl`, `e2e_ransac.jl`), the SupeRANSAC cell `superansac_e2e.jl`, `polish.jl`, `heb_inlier_stats.jl` |
| `accv2026/scripts/tools/` | the CLIs the drivers launch: `run_sequential_cv.jl` (the tuning), `run_polish.jl`, the renderers, the pool builders, `make_facet_grid.py` |
| `accv2026/scripts/slurm/` | an example Slurm wrapper (`run_experiment.sbatch`) and the pool launcher |
| `accv2026/configs/` | the configs of record: one TOML per cell, and the protocols folded into every run key |
| `accv2026/data/` | two per-machine symlinks: `exp_raw` (immutable inputs) and `exp_pro` (add-only results), or `CAU_DATA_ROOT` / `CAU_RESULTS_ROOT` |
| `accv2026/lib/RansacLibLO/` | the classical RansacLib LO baseline (vendored C++ shim, `Pkg.build("RansacLibLO")`) |
| `accv2026/paper/` | the manuscript; renders land in `paper/figures/` |

## Drivers and stages

Every driver is stage-idempotent: a stage whose output exists is skipped,
`--force` re-runs, `--stage=NAME` runs one stage, and `--plan` prints the stage
plan without running anything. From `accv2026/`:

```bash
julia --project=. scripts/fig3_composed_miscal.jl --plan
```

```bash
julia --project=. scripts/fig3_composed_miscal.jl --stage=cv
```

Each driver declares its data inputs (`require_input`, with provenance), tunes
only through the single cross-validation path, audits every tuning artifact before
consuming it (`audit_operating_points`, VisualGeometryToolkitEval's `Evaluation`), and ends by rendering its panel
into `paper/figures/`. On a Slurm cluster, `scripts/slurm/run_experiment.sbatch`
wraps the same command and only sets the resource shape.

## Config-driven cells and keyed output directories

A cell is a config of record (`configs/<cell>.toml`) plus the driver that runs it.
Its *effective* config — the TOML with the protocols of record folded in by
`src/protocol_folds.jl` — is hashed into its run key
(VisualGeometryToolkitEval `Experiments.run_key`, the SHA-256 of the sorted TOML; the
`[render]` section is excluded). Results are written to keyed directories such as
`phototourism/sift/E/Miscalibration/sequential-cv-<key>/` under the add-only
results root, never rewritten. Consumers re-derive a producer's key from its
config name, so keys are derived, never copied.

| protocol of record | governs |
|:---|:---|
| `configs/tuning.toml` | every `[tuning.<name>]` entry: windows, spacings, expand-on-boundary rules, objective, budget sampling, cross-validation |
| `configs/cv_protocol.toml` | tuning at ζ = 1 and the per-dataset cross-validation splits |
| `configs/miscal_protocol.toml` | the ζ evaluation ladder |
| `configs/sample_budget_protocol.toml` | per-dataset stream depth and checkpoint schedule |
| `configs/protocol.toml` | the experiment protocol: the equal LO budget, the Lebeda ladder, every per-arm deviation, and the result-changing values of each experiment |

## The sequential cross-validation

Every two-view cell is tuned by the sequential CV,
`scripts/tools/run_sequential_cv.jl`: two one-dimensional cross-validations in
sequence rather than one product grid.

1. **Scorer** — the selector's width `a*` on the selection-only error →
   `scorer_cv.jld2`.
2. **Refiners** — each arm's width at that `a*`, read back from the scorer
   artifact → `refiner_cv.jld2`. A `SelectionWidth` arm (its refit width is the
   selection width `a*`) has nothing to tune here.
3. **Evaluation** — the ζ miscalibration ladder on the test scenes at the tuned
   points → `operating_points.jld2`, the sidecar every downstream cell reads.

Each stage expands its window when the argmin lands on its boundary; a surviving
clip is recorded per arm and the readers refuse it.

## Figure → config → driver

The paper's figures stack per-dataset panels into one grid. The *figure configs*
`configs/fig3_miscal_grid.toml` and `configs/fig4_budget_grid.toml` name each
row's panel and the driver stage that produces it; they compose and run no
experiment.

| paper | rows (dataset · model) | producing driver (stage) | cell config |
|:---|:---|:---|:---|
| Fig. 1, perturbed-seed basins | PhotoTourism · E | `fig2_basin.jl` (`basin_cv`, `ladder_test`, `render`) | `pt_e_basin.toml` |
| Fig. 2, scale miscalibration — `fig3_miscal_grid.jl` (`compose`) | PhotoTourism · E | `fig3_composed_miscal.jl` (`cv`, `oracle`, `render`) | `pt_e_miscal.toml` |
| | ETH3D · F | `supp_ETH_F_miscal.jl` (`render_main`) | `accv2026_eth_f_miscal.toml` |
| | HEB · H | `supp_H_miscal.jl` (`render_main`) | `heb_h_miscal.toml` |
| Fig. 3, hypothesis budget — `fig4_budget_grid.jl` (`compose`) | PhotoTourism · E | `fig4_budget.jl` (`render`) | `pt_e_budget.toml` |
| | ETH3D · F | `supp_ETH_F_budget.jl` (`render`) | `accv2026_eth_f_budget.toml` |
| | HEB · H | `supp_H_budget.jl` (`render`) | `heb_h_budget.toml` |
| Fig. 4, least-squares polish | PhotoTourism · E | `polish.jl` (`test`, `summary`, `render`) | `polish_pt_e.toml` |
| Table 3, end-to-end RANSAC | PhotoTourism · E | `e2e_ransac.jl` (`live`, `summary`, `table`); SupeRANSAC's rows `superansac_e2e.jl` (`inputs`, `cv`, `eval`) | `pt_e_e2e_table.toml`, `pt_e_superansac.toml` |

`fig3_composed_miscal.jl --stage=cv` writes THE deployed operating-points sidecar
of PhotoTourism E that the downstream PhotoTourism cells read, so it runs first.
The supplement's figures and tables (the scoring-only miscalibration, the
partition-anchoring ablation, the polish) and Table 1's timing are indexed in
`accv2026/REPRODUCE.md`.

SupeRANSAC is an outside dependency: `superansac_e2e.jl` runs it in its own
environment (`accv2026/envs/superansac`, PythonCall/CondaPkg with a source build
of pysuperansac), detects whether it is installed and says how to install it.
Without it, Table 3 is built from the stored SupeRANSAC results the cell's
config names.

## Data

Nothing large is committed. Two-view scoring pools are built by pool-producer
cells (`scripts/pt_e_pools.jl`, `scripts/heb_h_pools.jl`,
`scripts/scoring_pools.jl --config=<name>`) from the public datasets — IMC
PhotoTourism, ETH3D, HEB — via `scripts/tools/generate_scoring_pools.jl`. The
PhotoTourism E pool alone is about 2 TB. The data roots resolve through
`CAU_DATA_ROOT` / `CAU_RESULTS_ROOT` or the `data/exp_raw` / `data/exp_pro`
symlinks (`accv2026/data/README.md`). With the produced artifacts synced, every
`--stage=render` regenerates its committed panel on the CPU.

Rebuild the manuscript after rendering:

```bash
cd accv2026/paper && make
```

## Tests

The package's tests run from the repository root; the research project has its own
suite, which checks among other things that `REPRODUCE.md` lists every driver:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

```bash
cd accv2026 && julia --project=. test/runtests.jl
```
