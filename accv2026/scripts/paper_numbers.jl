#!/usr/bin/env julia
# provenance: inputs declared via require_input (src/paper_numbers.jl); see REPRODUCE.md.
# =============================================================================
# scripts/paper_numbers.jl — every number macro of paper/main.tex and
# paper/supplement.tex, from the results of record (configs/paper_numbers.toml;
# the computations in src/paper_numbers.jl), into ONE generated macro file.
#
# STAGES
#   numbers (CPU) — every macro's value, with the result each was read from
#                   → <results>/PaperNumbers/numbers-<key>/numbers.toml
#                   (keyed by the config AND the keyed runs it reads, so a
#                   re-keyed cell re-keys the numbers)
#   emit    (CPU) — the values as VisualGeometryToolkitEval number macros (write_numbers),
#                   beside the record, deployed
#                   → paper/figures/paper_numbers.tex (reproduce: writes paper/figures/paper_numbers.tex)
#
# Run LAST, after every cell it reads (REPRODUCE.md).
#
#   julia --project=. scripts/paper_numbers.jl [--plan] [--stage=NAME] [--force]
# =============================================================================
import VisualGeometryToolkitCore as VgtkCore
using DrWatson; @quickactivate "ACCV2026"
using JLD2, TOML
using VisualGeometryToolkitEval.Experiments: read_provenance
using VisualGeometryToolkitEval.Reproduce: PaperNumbers, add_number!, write_numbers, deploy_assets
include(srcdir("cell_stages.jl"))
include(srcdir("e2e_cells.jl"))
include(srcdir("paper_numbers.jl"))

const CFG_PATH = PAPER_NUMBERS_PATH
const CFG = TOML.parsefile(CFG_PATH)
VgtkCore.check_keys(CFG, ("sources", "macro"), CFG_PATH)
# The effective config: the macros and sources of record, and the keyed runs
# they read (relative to the results root; a split reads its cell's keyed
# directory) — so the key moves whenever any source re-keys.
const INPUTS = Dict(String(n) => number_source_input(n, s) for (n, s) in CFG["sources"])
const EFFECTIVE = merge(Dict{String,Any}(CFG),
    Dict{String,Any}("inputs" => Dict(n => relpath(p, results_root()) for (n, p) in INPUTS)))
const KEY = run_key(EFFECTIVE)
const OUTDIR = joinpath(results_root(), "PaperNumbers", "numbers-" * KEY)
const RECORD = joinpath(OUTDIR, "numbers.toml")
const TEX = joinpath(PAPER_FIGDIR, PAPER_NUMBERS_TEX)

function _numbers()
    r = paper_numbers(CFG; floors = paper_number_floors(CFG))
    mkpath(OUTDIR)
    rec = Dict{String,Any}("key" => KEY, "macros" => [
        Dict{String,Any}("name" => x.name, "tex" => x.tex, "source" => x.source,
                         "input" => INPUTS[x.source],
                         "value" => x.value isa Tuple ? collect(Float64.(x.value)) : Float64(x.value))
        for x in r.rows])
    open(io -> TOML.print(io, rec; sorted = true), RECORD, "w")
    write_run_records(OUTDIR, EFFECTIVE; driver = "paper_numbers.jl", config_source = CFG_PATH, key = KEY,
                      inputs = sort(unique(collect(values(INPUTS)))))
    for x in r.rows
        println(rpad("\\" * x.name, 24), rpad(x.tex, 22), x.source)
    end
end

# The macros through VisualGeometryToolkitEval's one number-macro writer: one
# `add_number!` per macro (its typeset body as the record holds it), the
# provenance of the numbers run (its key and recorded gitcommit), written beside
# the record (`write_numbers`), then deployed into paper/figures. The driver
# always replaced the paper's copy (it is the one generated macro file, run
# last), so the deploy is signed off here; the value each macro was read from
# stays in numbers.toml.
function _emit()
    rec = TOML.parsefile(RECORD)
    rec["key"] == KEY || error("$(RECORD): key $(rec["key"]) is not this run's ($(KEY))")
    nums = PaperNumbers(; driver = "scripts/paper_numbers.jl", config = "configs/paper_numbers.toml", run_key = KEY,
                        commit = string(read_provenance(OUTDIR)["gitcommit"]))
    for m in rec["macros"]
        add_number!(nums, m["name"], m["tex"])
    end
    write_numbers(joinpath(OUTDIR, PAPER_NUMBERS_TEX), nums)
    deploy_assets(OUTDIR, PAPER_FIGDIR, [PAPER_NUMBERS_TEX]; replace_submitted = true)
    @info "WROTE" TEX
end

STAGES = Stage[
    Stage(:numbers, "every number macro from the results of record (key $(KEY)) -> $(RECORD)",
          () -> isfile(RECORD) && isfile(joinpath(OUTDIR, "_provenance.toml")), _numbers),
    Stage(:emit, "the macros (VisualGeometryToolkitEval's write_numbers) -> $(TEX)",
          () -> isfile(TEX) && fresher(TEX, RECORD), _emit),
]
run_stages("paper_numbers", STAGES)
