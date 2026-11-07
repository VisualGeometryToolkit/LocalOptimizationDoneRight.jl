# =============================================================================
# src/common.jl — THIN SHIM over the stage/run-record framework.
#
# The stage runner (Stage, run_stages with --plan/--force/--stage), driver
# shell-out (run_driver), input declarations (require_input) and the
# done-predicate helper (fresher) are VisualGeometryToolkitEval.Experiments; the
# interior-argmin audit is the LO engine's `audit_operating_points(ROSTER,
# path)`. This file keeps only THIS paper's wiring: the repo root, the
# driver-directory helper, and the run_driver context (scripts resolve against
# scripts/tools/, drivers run under this project).
#
# CV DISCIPLINE (unchanged): no experiment file implements a sweep/argmin —
# all tuning is THE single CV path; every sidecar is audited for interior
# argmins BEFORE consumption.
# =============================================================================
if !@isdefined(ACCV2026_EXPERIMENTS_COMMON_LOADED)

using VisualGeometryToolkitEval.Experiments: set_driver_context!, set_project_root!
using DrWatson: projectdir, scriptsdir
using TOML

# Project root (accv2026/), DrWatson's: the ACTIVE project, so every path
# below survives a file move (an `@__DIR__` path is relative to this file and
# broke silently whenever a directory was renamed). That is right only when
# accv2026 IS the active project — asserted, so a driver started under another
# project fails here instead of resolving into the wrong tree. Layout
# (2026-09-09): src/ = the shared prelude (config.jl entry), scripts/ = the
# experiment drivers, scripts/tools/ = the CLIs the drivers launch through
# run_driver, scripts/slurm/ = launchers, envs/ = auxiliary environments.
isfile(projectdir("src", "registry.jl")) && occursin(r"(?m)^name = \"ACCV2026\"", read(projectdir("Project.toml"), String)) ||
    error("DrWatson's projectdir() is $(projectdir()), not the accv2026 project: run drivers with " *
          "`--project=<accv2026>` (the active project is $(Base.active_project())).")
const EXP_PROJECT_ROOT = projectdir()
const EXP_SCRIPTS_DIR  = scriptsdir()
const EXP_TOOLS_DIR    = scriptsdir("tools")
exp_driver(parts...) = joinpath(EXP_TOOLS_DIR, parts...)

# run_driver resolves relative scripts against scripts/tools/ and launches them
# under THIS project (accv2026: pinned Manifest, the package dev'd by path).
set_driver_context!(
    exp_driver(); project = EXP_PROJECT_ROOT)

# The data/results binding and the provenance record (data_root,
# results_root, run_key, write_run_records, …) are package API
# (VisualGeometryToolkitEval.Experiments; data/README.md): this project binds itself
# as the project they resolve against — data/exp_raw and data/exp_pro, read as
# the link paths (every keyed path of this paper is spelled under them).
set_project_root!(EXP_PROJECT_ROOT)

# A machine with no data binding gets the published data as artifacts
# (configs/data_artifacts.toml; scripts/fetch_data.jl makes data/exp_raw the
# artifact view). Said once here, before a driver's data_root() errors.
if !haskey(ENV, "VGTK_DATA_ROOT") && !ispath(joinpath(EXP_PROJECT_ROOT, "data", "exp_raw"))
    @warn "no data root bound (VGTK_DATA_ROOT unset, no data/exp_raw): fetch the published data with " *
          "`julia --project=. scripts/fetch_data.jl` (REPRODUCE.md, \"On a new machine\")" maxlog = 1
end

# ---- oracle floors -----------------------------------------------------------
# The sidecar oracle_floors.jld2 has ONE writer and ONE done-predicate,
# VisualGeometryToolkitEval.Experiments' `write_oracle_floor` and
# `oracle_floor_done(path, tag; source = oracle_floor_source(pool, problem,
# scenes))`: a floor is DONE for a cell only when its recorded source is the
# cell's CURRENT pool tree and test scenes.
using JLD2, Dates
using VisualGeometryToolkitEval.Experiments: oracle_floors_path, oracle_floor_source, write_oracle_floor,
    oracle_floor_done


const ACCV2026_EXPERIMENTS_COMMON_LOADED = true
end # include guard

