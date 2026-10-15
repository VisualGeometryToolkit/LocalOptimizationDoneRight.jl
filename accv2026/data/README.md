# data/ — the per-machine data binding (BlobBoards/bmvc2026 convention)

Two entries, created per machine, never tracked (gitignored) — on the
author's host two SYMLINKS:

    exp_raw -> the IMMUTABLE input root (e.g. /path/to/data).
               Campaign pools live under exp_raw/accv2026/data/…,
               dataset-derived pools under exp_raw/datasets/…/derived/….
               NOTHING writes here except an explicit producer/promote.
    exp_pro -> the ADD-ONLY results root (e.g.
               /path/to/results/accv2026). Keyed run directories
               (sequential-cv-<key>/ with _config.toml/_provenance.toml)
               are created here and never rewritten.

Resolution ladder (VisualGeometryEval.Experiments, experiments/data.jl;
bound to this project by src/common.jl's set_project_root!(projectdir())):
  data_root():    ENV["CAU_DATA_ROOT"]    -> data/exp_raw -> error
  results_root(): ENV["CAU_RESULTS_ROOT"] -> data/exp_pro -> error
Both are returned as the link paths (every keyed path is spelled under them).
Writers refuse a path under data_root() unless declared a producer (the pool
cells); smoke runs go to data/sims (DrWatson datadir("sims"), gitignored).
The data policy (CLAUDE.md "Data") is checked by test/test_data_policy.jl.

Configs state pool_dir RELATIVE to data_root(), so a run key and its
sidecars are machine-portable (staging tree ≡ any mirror of the root).
The manuscript is in-tree (paper/); renders deploy to paper/figures
(PAPER_FIGDIR in src/registry.jl, overridable with PAPER_FIGS).

## A machine without the data: the published artifacts

The inputs are published on Zenodo as lazy Julia artifacts
(`../Artifacts.toml`, sha256- and tree-hash-pinned; the catalog of what each
holds and where it mounts is `../configs/data_artifacts.toml`). On a machine
with neither binding:

    julia --project=. scripts/fetch_data.jl          # the required inputs
    julia --project=. scripts/fetch_data.jl --all    # every catalogued artifact
    julia --project=. scripts/fetch_data.jl --list   # the catalog, nothing fetched

downloads them once into the Julia depot and makes

    exp_raw/  a DIRECTORY, the artifact view (marked `.artifact_view`): per-file
              symlinks into the installed artifact trees, at the paths the
              configs name. The pool producer cells write their NEW trees into
              it as real files, beside the linked inputs.
    exp_pro/  a plain results directory, with the stored SupeRANSAC results of
              Tab. 3 linked in at configs/pt_e_superansac.toml [stored] dir.

An existing binding always wins and is never written to: CAU_DATA_ROOT /
CAU_RESULTS_ROOT, or an author's exp_raw/exp_pro symlink. To rebuild a view,
delete data/exp_raw and fetch again (the depot copy is reused).
`ACCV2026_ARTIFACTS_TOML=<file>` points the fetch at another copy of the
bindings (the same hashes, other URLs — e.g. local file:// tarballs in a test).
The author side is `scripts/tools/make_zenodo_artifacts.jl` (REPRODUCE.md).
