# =============================================================================
# test_paper_numbers.jl — no hand-typed data number in the papers.
#
# Every number paper/main.tex and paper/supplement.tex state is a macro of THE
# one generated macro file, paper/figures/paper_numbers.tex
# (scripts/paper_numbers.jl, configs/paper_numbers.toml), or one of the
# protocol constants below (each with the setting it states). The prose is
# scanned with comments, display equations and reference/citation arguments
# removed; a number of two or more digits, or any decimal, that no protocol
# pattern accounts for fails, as does a \newcommand with a numeric body in a
# paper, a protocol pattern that no longer matches (stale), and a generated
# file whose macros are not exactly the config's.
# =============================================================================
using Test, TOML

const _PAPER_DIR = joinpath(@__DIR__, "..", "paper")
const _PAPERS = ["main.tex", "supplement.tex"]

# (pattern, what it states) — protocol and presentation constants, never results.
const PROTOCOL_LITERALS = [
    (r"mAA@\$10\^\\circ\$", "the metric, mAA@10° (its definition, Eq. maa)"),
    (r"\$10\^4\$ hypotheses", "the order of a pool's hypothesis count (4,000 minimal samples per pair, configs/*_pools.toml)"),
    (r"25-model-update|25-update|25 model updates", "the equal LO budget (configs/protocol.toml [arms] lo_iteration_budget)"),
    (r"\$128\\times\$|\\zeta=128|\\zeta=1/16|\\zeta\\in\[1/128,128\]", "the ζ ladder (configs/miscal_protocol.toml)"),
    (r"\$16\^\\circ\$", "a basin-ladder δ (configs/protocol.toml [basin_ladder])"),
    (r"100 models|100 hypotheses|4,000 models|after 4000", "the budget checkpoints (configs/sample_budget_protocol.toml)"),
    (r"\$4\\,096\$ per image pair", "the pools' correspondence cap (configs/pt_e_pools.toml)"),
    (r"\$10\\,000\$ trials", "SupeRANSAC's trial cap (configs/pt_e_superansac.toml)"),
    (r"\\kscore\\in\[1,3\.3\]", "the shared scoring window (configs/tuning.toml [types.scale_multiple_window])"),
    (r"\$0\.25\$--\$8\$\\,px", "SIMFIT++'s admissible window (its reference implementation)"),
    (r"\(40 pairs, about 4,000 correspondences\)", "the timing fixture (configs/timing_table.toml npairs; the 4,096 cap)"),
    (r"No~101081480", "a grant number"),
]

# The prose of a paper: comments, display equations, and the arguments of
# references, citations, inputs, labels and colours removed; lengths dropped.
function _paper_prose(src::AbstractString)
    t = replace(src, r"(?<!\\)%[^\n]*" => "")
    i = findfirst(raw"\begin{document}", t)
    t = i === nothing ? t : t[first(i):end]
    for env in ("equation", "align", "equation\\*", "align\\*")
        t = replace(t, Regex("\\\\begin\\{$env\\}.*?\\\\end\\{$env\\}", "s") => " ")
    end
    t = replace(t, r"\\(label|ref|cref|Cref|eqref|cite|input|includegraphics|url|bibliography|bibliographystyle|suppsec|supptab|suppfig|pgfplotslegendfromname|providecolor|definecolor|begin|end)(\[[^\]]*\])?\{[^}]*\}" => " ")
    t = replace(t, r"[0-9.]+\s*(pt|em|ex|cm|mm|\\linewidth|\\textwidth|\\baselineskip)" => " ")
    t = replace(t, r"\\\\\[[^\]]*\]" => " ")
    return t
end

# Generated for the record of their families but typeset nowhere today (the
# paper states their neighbours); a macro that becomes unused must be listed here.
const PAPER_NUMBERS_UNUSED = ["TLSCal", "LOPlusInfl", "BasinHq", "BasinClassicalLO", "BasinWelschStatic",
    "BasinWIrlsEight", "BasinGncOne", "BasinTruncOne", "BasinSeedOne", "PolLiftBefore", "PolBCDBefore",
    "EtoEOursMs", "EtoESRMs", "EtoESRRangeLo", "EtoEOursDeflMs", "EtoESRDeflMs", "EtoEOursInflMed", "HEBInlRatio", "HEBFracLow"]

# A number token outside a macro name: two or more digits, or a decimal.
_data_numbers(t) = [m.match for m in eachmatch(r"(?<![A-Za-z_\\^])(\d+(?:\\,\d{3})*(?:\.\d+)?|\.\d+)", t)
                    if !occursin(r"^\d$", m.match)]

@testset "paper numbers: no hand-typed data number" begin
    used = falses(length(PROTOCOL_LITERALS))
    for f in _PAPERS
        src = read(joinpath(_PAPER_DIR, f), String)
        @test occursin(raw"\input{figures/paper_numbers}", src)
        # no number macro defined by hand
        hand = [m.match for m in eachmatch(r"\\newcommand\{\\\w+\}\{\s*[-\d.]+(?:\\,\d+)*(?:\\%|\\text\{--\}[-\d.]+)?\s*\}", src)]
        @test isempty(hand) || (@info "hand-defined number macros in $f" hand; false)
        prose = _paper_prose(src)
        for (i, (pat, _)) in enumerate(PROTOCOL_LITERALS)
            occursin(pat, prose) && (used[i] = true)
            prose = replace(prose, pat => " ")
        end
        left = _data_numbers(prose)
        @test isempty(left) || (@info "hand-typed numbers in $f (make them paper_numbers macros)" left; false)
    end
    stale = [PROTOCOL_LITERALS[i][1] for i in eachindex(used) if !used[i]]
    @test isempty(stale) || (@info "STALE protocol patterns (match no paper)" stale; false)

    # the generated file holds exactly the config's macros, and says who wrote it
    cfg = TOML.parsefile(joinpath(@__DIR__, "..", "configs", "paper_numbers.toml"))
    gen = read(joinpath(_PAPER_DIR, "figures", "paper_numbers.tex"), String)
    @test startswith(gen, "% Generated by scripts/paper_numbers.jl")
    defined = [m[1] for m in eachmatch(r"\\newcommand\{\\(\w+)\}", gen)]
    @test sort(defined) == sort([m["name"] for m in cfg["macro"]])
    # every macro the generated file defines is typeset somewhere, or declared unused
    papers = join((read(joinpath(_PAPER_DIR, f), String) for f in _PAPERS), "\n")
    unused = [d for d in defined if !occursin(Regex("\\\\" * d * "(?![A-Za-z])"), papers)]
    @test issubset(unused, PAPER_NUMBERS_UNUSED) || (@info "generated but unused macros" setdiff(unused, PAPER_NUMBERS_UNUSED); false)
end

# Tab. 3's caption states the timing protocol (pairs per scene, repeats): generated
# from the timing cell's records (its sample.toml, its [timing] repeats), never typed.
const PAPER_NUMBERS_TIMING_PROTOCOL = ["EtoETimePairs" => "pairs_per_scene", "EtoETimeRepeats" => "repeats"]

@testset "paper numbers: Tab. 3's timing protocol from the timing cell" begin
    cfg = TOML.parsefile(joinpath(@__DIR__, "..", "configs", "paper_numbers.toml"))
    main = read(joinpath(_PAPER_DIR, "main.tex"), String)
    for (name, op) in PAPER_NUMBERS_TIMING_PROTOCOL
        m = only(x for x in cfg["macro"] if x["name"] == name)
        @test cfg["sources"][m["source"]]["kind"] == "e2e_timing"
        @test m["op"] == op
        @test occursin(Regex("\\\\" * name * "(?![A-Za-z])"), main)
    end
end
