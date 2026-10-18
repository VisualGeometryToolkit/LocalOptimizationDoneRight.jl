# ACCV 2026 — "Score Sharp, Refine Soft, Polish Hard"

The paper project of LocalOptimizationDoneRight: every figure, table and
number of `paper/main.tex` and `paper/supplement.tex` comes from a driver under
`scripts/` run on a config of record under `configs/`, laid out by the stack's
paper-project conventions (VisualGeometryToolkitEval `PaperProjects`). A
[DrWatson](https://juliadynamics.github.io/DrWatson.jl/) project, not a
package; the parent package is tracked through `[sources]` (`path = ".."`).

```
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. scripts/<experiment>.jl --plan   # the stage plan of one experiment
julia --project=. scripts/<experiment>.jl          # run what is pending
julia --project=. test/runtests.jl                 # the conventions + the project's tests
```

| Path | Holds |
|---|---|
| `REPRODUCE.md` | the asset index (every file the papers read → generator, config, data) and how to rerun each experiment |
| `configs/` | the configs of record (TOML); `run_key` hashes each effective config, `[render]` excluded |
| `scripts/` | the drivers, one per experiment, stage-idempotent (`--plan`, `--stage=NAME`, `--force`); `scripts/tools/` the CLIs they launch, `scripts/slurm/` the launchers |
| `src/` | the shared prelude (`config.jl` is the entry) |
| `test/` | the suite; `test/test_paper_project.jl` runs `paper_project_violations` |
| `paper/` | the manuscript; generated assets under `paper/figures/` |
| `data/exp_raw`, `data/exp_pro` | per-machine links to the read-only input tree and to the results tree (`data/README.md`) |
| `envs/` | auxiliary environments (`envs/superansac`, SupeRANSAC's) |
| `lib/RansacLibLO` | the vendored RansacLib LO baseline |
