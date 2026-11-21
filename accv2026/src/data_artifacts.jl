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
# The roots, the artifact store and the artifact view: data/README.md.
# =============================================================================
if !@isdefined(ACCV2026_DATA_ARTIFACTS_LOADED)

using VisualGeometryToolkitEval.DataArtifacts: project_catalog, pack_artifacts, zenodo_url, split_scenes
using VisualGeometryToolkitEval.Experiments: data_root, results_root

# The catalog is VisualGeometryToolkitEval's `project_catalog()`: configs/data_artifacts.toml of the
# bound project, bound to its Artifacts.toml or `ENV["ACCV2026_ARTIFACTS_TOML"]`.

const ACCV2026_DATA_ARTIFACTS_LOADED = true
end # include guard
