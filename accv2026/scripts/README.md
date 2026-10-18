# ACCV 2026 experiments — "Score Sharp, Refine Soft, Polish Hard"

One executable file per experiment; each file **is** the experiment: it
declares its data inputs (`require_input` with provenance), runs idempotent
stages (skip-if-done; `--force` re-runs; `--stage=NAME` runs one), tunes only
through **THE single CV path** under a `[tuning.<name>]` spec
(`../configs/tuning.toml`; schema: the header of VisualGeometryToolkitEval `src/tuning/toml.jl`, defaults in its `configs/tuning.toml`;
the sequential CV `tools/run_sequential_cv.jl`, with boundary detection +
read-time refusal),
audits every tuning artifact for interior argmins before
consumption, and ends by rendering its figure/table into the paper repo's
`figures/`.

```
julia --project=. scripts/<exp>.jl --plan   # structural check
sbatch [shape overrides] scripts/slurm/run_experiment.sbatch <exp>.jl [args]
```

The experiment → artifact index, data provenance and the CV-path contract
live in `../REPRODUCE.md` (the one index; the suite checks it against the
stage files). Layout (DrWatson: `@quickactivate "ACCV2026"`, then
`include(srcdir("config.jl"))`):

- this directory: the drivers only (`fig*`, `supp_*`, the pool producers,
  the table drivers `timing_table.jl` and `e2e_ransac.jl`, the SupeRANSAC
  cell `superansac_e2e.jl`, `polish.jl`, `heb_inlier_stats.jl`);
- `../src/`: the shared prelude — `config.jl` (entry), `registry.jl` (every
  path), `validation_data.jl` (a spec's cross-validation → the scenes and
  units a driver reads; the drivers' accepted samplings by signature),
  `protocol_folds.jl` (the run-key fold recipe), `arm_rosters.jl` (THE arm
  table: every roster and the timing names derive from it), `figure_style.jl`
  (styling), `labels.jl`, `cell_stages.jl` (the shared stage builders: the
  sequential CV, the miscal and budget cells, the pool producers, the facet
  grids), `e2e_cells.jl` (the live end-to-end runs and Tab. 3),
  `superansac.jl` (the SupeRANSAC cell: detection of the outside dependency,
  its CV and evaluation, the stored results), …;
- `tools/`: the CLIs the drivers launch through `run_driver` (the tuning
  driver `run_sequential_cv.jl`, the polishing runner `run_polish.jl`
  (driven by `scripts/polish.jl`, configs/polish_pt_e.toml) — every budget cell
  runs inline through `budget_cell_stages`, configured by its
  `configs/*_budget.toml` — the renderers (one for every two-view budget
  cell, `render_budget.jl`), the pool driver, the design-table emitter,
  `make_facet_grid.py`, and `superansac_worker.jl`, which runs in the
  SupeRANSAC environment `../envs/superansac`, not this project's). The
  end-to-end cell has no workers of its own: its stages call the LO engine's
  live-RANSAC runs directly. Scoring pools come from
  `tools/generate_scoring_pools.jl` (see `../REPRODUCE.md`);
- `slurm/`: the launchers and the one sbatch template.
