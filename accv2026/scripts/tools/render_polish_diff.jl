#!/usr/bin/env julia
# =============================================================================
# render_polish_diff.jl — RENDERER of the polishing figure: the ECDF of the
# per-pair error change e_polished − e_LO (negative = the polish helped), one
# curve per source on ONE axis (launched by scripts/polish.jl, stage render).
# The axis block is the frozen ACCV one (src/figure_style.jl `polish_diff_axis`).
#
# ENV: POLISH_TEST (polish_test.jld2), OUT (the .tex fragment), CONFIG (the
# polish config's name, for the header), DIFF_XMAX (the half-range in degrees).
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, Printf
include(srcdir("config.jl"))   # PAPER_STYLE, label_tex, the frozen axis blocks

const TESTF = ENV["POLISH_TEST"]
const OUT   = ENV["OUT"]
const CONFIG_NAME = ENV["CONFIG"]
const W     = parse(Float64, ENV["DIFF_XMAX"])

# ECDF points of `x` (finite values; non-finite count as never reached) on
# [xmin, xmax]; the mass below xmin is the curve's starting height.
function _ecdf(x, xmax; xmin = 0.0)
    n = length(x); v = sort(filter(isfinite, x)); below = count(<(xmin), v); v = v[xmin .<= v .<= xmax]
    pts = [(xmin, below / n)]
    for (i, xi) in enumerate(v); push!(pts, (xi, (below + i) / n)); end
    push!(pts, (xmax, (below + length(v)) / n))
    stride = max(1, length(pts) ÷ 400)                      # ≤ ~400 vertices per curve
    return pts[vcat(1:stride:length(pts)-1, length(pts))]
end
_coords(pts) = join(("(" * @sprintf("%.4g", x) * "," * @sprintf("%.4f", y) * ")" for (x, y) in pts), " ")

d = JLD2.load(TESTF); S = d["sources"]
# The per-pair change e_polished − e_LO (the polisher is the config's first);
# pairs where either error is undefined are dropped. Negative = improved.
p = first(d["polishers"])
srcstyle = POLISH_SOURCE_STYLES   # src/figure_style.jl, one per source in [polish] sources order
length(srcstyle) >= length(S) || error("POLISH_SOURCE_STYLES: $(length(srcstyle)) styles for $(length(S)) sources")
io = IOBuffer()
println(io, "% Derived by scripts/polish.jl (config $(CONFIG_NAME)); do not hand-edit.")
println(io, raw"\begin{tikzpicture}\begin{axis}[" * polish_diff_axis(W) * "]")
println(io, raw"\draw[gray, line width=0.6pt] (axis cs:0,0) -- (axis cs:0,1);")
for (i, a) in enumerate(S)
    b, e = d["err"]["$(a)|none"], d["err"]["$(a)|$(p)"]; ok = isfinite.(b) .& isfinite.(e)
    println(io, "\\addplot[$(srcstyle[i]), mark=none] coordinates {$(_coords(_ecdf(e[ok] .- b[ok], W; xmin = -W)))};")
    println(io, "\\addlegendentry{\\stuU{}+" * label_tex(a) * "}")
end
println(io, raw"\end{axis}\end{tikzpicture}")
write(OUT, String(take!(io))); @info "WROTE" out = OUT
