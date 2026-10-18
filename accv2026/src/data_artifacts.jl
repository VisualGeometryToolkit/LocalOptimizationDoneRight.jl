# =============================================================================
# src/data_artifacts.jl — the paper's published input data as Julia artifacts
# (lazy, sha256-pinned tarballs on Zenodo, bound in accv2026/Artifacts.toml).
#
# configs/data_artifacts.toml is the catalog (what each artifact holds, its
# mount, its Zenodo record, the config of record its file list derives from).
# Its format and everything that reads it — the derived file lists, the
# author-side packer, the fetch into the artifact view — are VisualGeometryToolkitEval's
# DataArtifacts, shared with the other paper projects of the stack; this file
# only binds the catalog.
#
# Resolution ladder (data/README.md): the drivers read data_root() /
# results_root() (VisualGeometryToolkitEval.Experiments): ENV CAU_DATA_ROOT /
# CAU_RESULTS_ROOT, else the project's data/exp_raw / data/exp_pro. A machine
# without either gets them from the artifacts: `fetch_artifacts!` makes
# data/exp_raw an ARTIFACT VIEW (per-file links into the installed artifact
# trees, marked by `.artifact_view`) and data/exp_pro a plain results
# directory. An existing binding always wins and is never written to.
# =============================================================================
if !@isdefined(ACCV2026_DATA_ARTIFACTS_LOADED)

using TOML
using VisualGeometryToolkitEval.DataArtifacts: DataCatalog, load_catalog, required_artifacts, artifact_files, artifact_parts,
    fetch_artifacts!, pack_artifacts, zenodo_url, catalog_violations, split_scenes
using VisualGeometryToolkitEval.Experiments: data_root, results_root

const DATA_ARTIFACTS_CATALOG = normpath(joinpath(@__DIR__, "..", "configs", "data_artifacts.toml"))

"The catalog (configs/data_artifacts.toml), bound to accv2026/Artifacts.toml or `ENV[\"ACCV2026_ARTIFACTS_TOML\"]`."
artifact_catalog() = load_catalog(DATA_ARTIFACTS_CATALOG)

const ACCV2026_DATA_ARTIFACTS_LOADED = true
end # include guard
