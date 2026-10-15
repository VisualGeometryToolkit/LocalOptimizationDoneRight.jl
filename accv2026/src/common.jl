# =============================================================================
# src/common.jl — THIN SHIM over the stage/run-record framework.
#
# The stage runner (Stage, run_stages with --plan/--force/--stage), driver
# shell-out (run_driver), input declarations (require_input) and the
# done-predicate helper (fresher) are VisualGeometryEval.Experiments; the
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

using VisualGeometryEval.Experiments: set_driver_context!, set_project_root!
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
# (VisualGeometryEval.Experiments; data/README.md): this project binds itself
# as the project they resolve against — data/exp_raw and data/exp_pro, read as
# the link paths (every keyed path of this paper is spelled under them).
set_project_root!(EXP_PROJECT_ROOT)

# A machine with no data binding gets the published data as artifacts
# (configs/data_artifacts.toml; scripts/fetch_data.jl makes data/exp_raw the
# artifact view). Said once here, before a driver's data_root() errors.
if !haskey(ENV, "CAU_DATA_ROOT") && !ispath(joinpath(EXP_PROJECT_ROOT, "data", "exp_raw"))
    @warn "no data root bound (CAU_DATA_ROOT unset, no data/exp_raw): fetch the published data with " *
          "`julia --project=. scripts/fetch_data.jl` (REPRODUCE.md, \"On a new machine\")" maxlog = 1
end

# ---- oracle floors: ONE writer, ONE done-predicate ---------------------------
# oracle_floors.jld2 holds "floors" (tag => pool-best floor, tag*"_maa" =>
# pool-best mAA ceiling) and "sources" (tag => the pool tree, problem and test
# scenes the floor was computed on, plus npairs/driver/computed). A floor is
# DONE for a cell only when its recorded source is the cell's CURRENT pool
# tree and test scenes: by key presence alone, floors computed on the retired
# vgc07 pool trees reported DONE (2026-09-08) and had to be deleted by hand.
# The read-modify-write is serialized by a pid lock because the transfer
# chains' oracle stages run concurrently on one node.
using JLD2, Dates
using FileWatching.Pidfile: mkpidlock

const ORACLE_FLOORS_NOTE = "median over test pairs of pool-best model error (<TAG> = floor; " *
    "<TAG>_maa = mean pool-best mAA@10° ceiling); metric = problem-family model_imc; " *
    "selection-only bound (LO may cross); sources[<TAG>] = the pools/scenes of record"

oracle_floor_source(pool_dir, problem, scenes) = Dict{String,Any}(
    "pool_dir" => String(pool_dir), "problem" => String(problem),
    "scenes"   => sort(String.(collect(scenes))))

function write_oracle_floor!(path, tag, floor_v, maa; source, npairs, driver)
    mkpath(dirname(path))
    mkpidlock(path * ".lock"; wait = true, stale_age = 600) do
        f       = isfile(path) ? JLD2.load(path) : Dict{String,Any}()
        floors  = get(f, "floors",  Dict{String,Float64}())
        sources = get(f, "sources", Dict{String,Any}())
        floors[tag]          = floor_v
        floors["$(tag)_maa"] = maa
        sources[tag] = merge(source, Dict{String,Any}("npairs" => npairs, "driver" => String(driver),
                                                     "computed" => string(Dates.now())))
        JLD2.jldsave(path; floors, sources, note = ORACLE_FLOORS_NOTE)
    end
    return path
end

function oracle_floor_done(path::AbstractString, tag; pool_dir, problem, scenes)
    isfile(path) || return false
    f = JLD2.load(path)
    floors = f["floors"]
    (haskey(floors, tag) && haskey(floors, "$(tag)_maa")) || return false
    src = get(get(f, "sources", Dict{String,Any}()), tag, nothing)
    src === nothing && return false
    want = oracle_floor_source(pool_dir, problem, scenes)
    return all(get(src, k, nothing) == v for (k, v) in want)
end
oracle_floor_done(tag; kw...) = oracle_floor_done(oracle_floors_path(), tag; kw...)


const ACCV2026_EXPERIMENTS_COMMON_LOADED = true
end # include guard

