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
# is bound). An existing binding wins — CAU_DATA_ROOT / CAU_RESULTS_ROOT or
# the author's data/exp_raw symlink — and is never written to by this script
# (VisualGeometryToolkitEval DataArtifacts `fetch_artifacts!`; data/README.md). A
# split entry fetches all its parts; a file shipped in chunks (a sub-part of a
# scene over the catalog's `max_part_bytes`) is reassembled in the view.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using VisualGeometryToolkitEval: cli_option
include(srcdir("common.jl"))
include(srcdir("data_artifacts.jl"))

const CAT = artifact_catalog()

if "--list" in ARGS
    meta = isfile(CAT.artifacts_toml) ? TOML.parsefile(CAT.artifacts_toml) : Dict{String,Any}()
    for (n, a) in sort(collect(CAT.artifacts); by = first)
        println(rpad(n, 32), get(a, "required", false) ? " required " : " optional ", rpad(a["mount"], 8), " ", a["what"])
        for p in artifact_parts(CAT, n)     # [n], or a split entry's parts (and sub-parts)
            println(" "^32, "  ", haskey(meta, p) ? meta[p]["download"][1]["url"] : "$p (not bound)")
        end
    end
    exit(0)
end

only = filter(!isempty, split(cli_option(ARGS, "only", ""), ','))
names = !isempty(only) ? String.(only) :
        "--all" in ARGS ? sort(collect(keys(CAT.artifacts))) : required_artifacts(CAT)

for r in fetch_artifacts!(CAT, names)
    msg = r.dst === nothing ?
        "not linked: the data root is bound ($(data_root()))" :
        "$(r.linked) new link(s) under $(r.dst)"
    println(rpad(r.name, 32), " ", msg)
end
for (what, root) in (("data_root()   ", data_root), ("results_root()", results_root))
    println(what, " = ", try root() catch err; sprint(showerror, err) end)
end
println("FETCH_DATA_DONE")
