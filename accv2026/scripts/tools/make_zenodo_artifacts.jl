#!/usr/bin/env julia
# =============================================================================
# make_zenodo_artifacts.jl — package the paper's input data into Julia
# artifacts for Zenodo (the BlobBoards bmvc2026 make_zenodo_artifacts.jl
# convention), AUTHOR-SIDE: it reads the author's data_root()/results_root().
#
#   julia --project=. scripts/tools/make_zenodo_artifacts.jl --stage=<dir> \
#         [--only=name,name] [--record=<group>=<zenodo id>,...] [--local-toml=<path>]
#
# For each artifact of configs/data_artifacts.toml (or --only): its file list
# is DERIVED from the config of record (VisualGeometryToolkitEval DataArtifacts
# `artifact_files`); `pack_artifacts` builds it with Pkg.Artifacts — `create_artifact` (the files
# copied into a tree, in a scratch artifacts directory under <stage>, never the
# depot), `archive_artifact` (<stage>/tarballs/<name>.tar.gz) and
# `bind_artifact!` (accv2026/Artifacts.toml, `lazy = true`, the tree's
# git-tree-sha1 and the tarball's sha256). Artifacts are packed concurrently
# (start julia with threads), bound one after the other.
#
# URLs: https://zenodo.org/records/<id>/files/<name>.tar.gz?download=1, the id
# that --record gives the artifact's record group, else the catalog's
# [records.<group>] id, else the group's PLACEHOLDER, which
# scripts/fetch_data.jl refuses to download. Run once without ids to stage and
# bind, then again with the ids once the records exist: a staged tarball is
# reused (no repacking) when its `.files` sidecar — the staged file list with
# sizes and mtimes — matches the current one.
#
# --local-toml=<path> also writes a COPY of the bindings with file:// URLs to
# the staged tarballs: the fresh-machine test's ACCV2026_ARTIFACTS_TOML. It is
# never committed.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using VisualGeometryToolkitEval: cli_option
include(srcdir("common.jl"))           # binds the project root data_root()/results_root() resolve against
include(srcdir("data_artifacts.jl"))

haskey(ENV, "ACCV2026_ARTIFACTS_TOML") && error(
    "make_zenodo_artifacts binds the committed accv2026/Artifacts.toml: unset ACCV2026_ARTIFACTS_TOML")
const STAGE_DIR = cli_option(ARGS, "stage", "")
isempty(STAGE_DIR) && error("make_zenodo_artifacts: --stage=<dir> is required (a scratch directory with room for the tarballs)")
const CATALOG = artifact_catalog()
const ONLY = filter(!isempty, split(cli_option(ARGS, "only", ""), ','))
const NAMES = isempty(ONLY) ? sort(collect(keys(CATALOG.artifacts))) : String.(ONLY)
const RECORD_IDS = Dict(String(first(kv)) => String(last(kv))
                        for kv in (split(p, '=') for p in filter(!isempty, split(cli_option(ARGS, "record", ""), ','))))

built = pack_artifacts(CATALOG, NAMES; stage = STAGE_DIR, record_ids = RECORD_IDS,
                       local_toml = cli_option(ARGS, "local-toml", ""))
for b in built
    println(rpad(b.name, 34), lpad(round(b.raw / 1e9; digits = 2), 9), " GB raw ", lpad(round(b.bytes / 1e9; digits = 2), 9),
            " GB tar.gz  ", bytes2hex(b.hash.bytes), "  ", b.sha, "  ", zenodo_url(CATALOG, b.name; record_ids = RECORD_IDS))
end
println("MAKE_ZENODO_ARTIFACTS_DONE ", CATALOG.artifacts_toml)
