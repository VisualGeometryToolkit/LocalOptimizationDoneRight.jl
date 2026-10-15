# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

LocalOptimizationDoneRight: the ACCV 2026 paper artifact, in two halves: a
registered package — the paper's local optimizers on VisualGeometryCore's
local-optimization contract and RobustVisualGeometry's problems (`src/`: the
HQ/GNC lifts and their lift core and schedules in `src/lift/`, the strategies —
`HQ`, `Gnc`, `StudentTUniform`, `StuTuBCD`, `BarronAdaptive`, the research
variants — their TOML registry `LO_TAGS` in `src/strategies/`, the
cross-validated `tuning_constant`s, and the PoseLib truncated refiners, whose
solver calls are the PoseLib package extension in `ext/`) — and the research
project `accv2026/` that produces every figure and table. The evaluation engine
(pair geometry, the refit layer, post-LO matrices, the sample-budget engine,
live runs, the `Roster` type and its gate-enforced readers, the selection
stream) is `VisualGeometryEval.Evaluation`; the paper's arm rosters stay in
`accv2026/`.
The RansacLib LO baseline (unregistered) lives in the project: the shim at
`accv2026/lib/RansacLibLO` (dev'd via `[sources]`) and its arms in
`accv2026/src/lebeda_lo.jl`; the package must not depend on it. The package's
defaults of record are `configs/default.toml`, read only through
`_config_default`.

## Testing

Plain `@testset` (`test/runtests.jl`): `Pkg.test()` runs the whole suite; there
is no per-item filter. The paper project has its own suite
(`julia --project=accv2026 accv2026/test/runtests.jl`).

## Git Commit Conventions

- **NEVER** add "Co-Authored-By: Claude" or similar AI attribution to commit messages
- **NEVER** add "🤖 Generated with Claude Code" or similar footers
- Write clean, concise commit messages focused on the change itself

## Stack Conventions

The conventions every stack package follows — naming and the estimator verbs,
signatures, data arguments, coordinate frames and normalization ("frame in =
frame out"), pixel origins, bearings, Jacobians, units and the stack
contracts — live ONCE, in VisualGeometryCore's `conventions/` folder
(`conventions/README.md` indexes it). Read them before changing code here.
This file carries no copy of them, only how they land in this package. Where
the folder is:

- in a checkout of the stack's monorepo: `../VisualGeometryCore/conventions/`
  (the root CLAUDE.md imports it);
- in VisualGeometryCore's own repository: `conventions/`;
- from Julia, the installed copy: `VisualGeometryCore.conventions_dir()`, i.e.
  `joinpath(pkgdir(VisualGeometryCore), "conventions")`.

The agent-docs test checks that this file points there and holds no copy.

## Data (accv2026)

The data binding, provenance record and data policy are VisualGeometryEval's
`Experiments` (one implementation for every paper project). accv2026 binds
itself in `src/common.jl` (`set_project_root!(projectdir())`, asserted to be
the accv2026 project).

- Roots: `data_root()` = `CAU_DATA_ROOT` → `data/exp_raw` (DrWatson
  `datadir("exp_raw")`: a per-machine link, or the artifact view);
  `results_root()` = `CAU_RESULTS_ROOT` → `data/exp_pro`. Both are returned as
  the LINK paths, because every keyed path of this paper is spelled under them.
  Paths come from `projectdir`/`scriptsdir`/`datadir`, never from `@__DIR__`
  or a machine path. `paper/` is not yet DrWatson's `papers/` (deferred).
- Keys: a run directory is `<kind>-<run_key>` of the folded effective config
  (`run_key`: SHA-256 of the sorted TOML, `[render]` excluded). This is the
  one justified extension of DrWatson's `savename`, which drops nested values.
- Records: `write_run_records` writes `_config.toml` + `_provenance.toml`
  (DrWatson's tagged dict: `gitcommit`, `gitpatch`, inputs relative to their
  roots). `run_complete` skips a keyed run and warns on commit drift. Never use
  `produce_or_load` for an artifact of record: it swallows save errors.
- Policy, enforced by `test/test_data_policy.jl` (an explicit allowlist of the
  deferred violations, each naming its fix):
  - D1: no machine paths in code or launchers (Slurm: `$SLURM_SUBMIT_DIR`,
    `$ACCV_LOG_DIR`).
  - D2: nothing writes under `data_root()` except a declared producer
    (`producer = true`: the pool cells); the writers' runtime guard refuses
    the rest.
  - D3: output directories are keyed. No wall-clock stamps, hand-bumped `-vN`
    literals, `-smoke` siblings (smoke runs go to `datadir("sims")`) or
    unkeyed shared files.
- Never write into the results tree of a running regeneration: point a
  worktree's `data/exp_pro` (or `CAU_RESULTS_ROOT`) at a scratch directory
  before running its tests or drivers.

## Coordinate Frames and Normalization

The rule is the stack's (`conventions/frames.md`); how it lands here:

### The pool frame here

The drivers consume VisualGeometryEval pools in `NormalizedImageFrame`.
The vendored RansacLib baseline normalizes internally (third-party, exempt from
rule 3). Its E arm takes calibrated plane points: a declared pinhole-only
third-party exception to the bearings rule, converted once from the pool frame
by the stored `Kc`.
