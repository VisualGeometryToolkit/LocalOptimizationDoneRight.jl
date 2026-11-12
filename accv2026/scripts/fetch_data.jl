#!/usr/bin/env julia
# =============================================================================
# scripts/fetch_data.jl — fetch the paper's published input data (Zenodo, as
# the lazy Julia artifacts of accv2026/Artifacts.toml) and link it where the
# drivers read it. The new-machine setup step (REPRODUCE.md, "On a new
# machine"); a no-op where the data are already bound.
#
#   julia --project=. scripts/fetch_data.jl              # the required artifacts
#   julia --project=. scripts/fetch_data.jl --all        # every catalogued artifact (required or not)
#   julia --project=. scripts/fetch_data.jl --only=heb_raw,pt_e_superansac_stored
#   julia --project=. scripts/fetch_data.jl --list       # the catalog, nothing fetched
#
# Each artifact is downloaded once into the Julia depot (sha256 and tree hash
# verified) and linked file by file into its mount root: data artifacts into
# data/exp_raw (made an artifact view when no data root is bound), results
# artifacts into results_root() (data/exp_pro is created when no results root
# is bound). An existing binding wins — VGTK_DATA_ROOT / VGTK_RESULTS_ROOT or
# the author's data/exp_raw symlink — and is never written to by this script
# (VisualGeometryToolkitEval DataArtifacts `fetch_data!`, the one new-machine step
# every paper project's script is; data/README.md). A split entry fetches all
# its parts; a file shipped in chunks (a sub-part of a scene over the catalog's
# `max_part_bytes`) is reassembled in the view.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using VisualGeometryToolkitEval.DataArtifacts: fetch_data!, project_catalog
include(srcdir("common.jl"))   # binds the project root the catalog and both roots resolve against

fetch_data!(project_catalog())
