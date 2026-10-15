# Paired-ablation "partition anchoring" figure: WITH vs WITHOUT anchoring the
# local optimizer's scale to the seed partition, at the SAME tuned operating
# points (scripts/fig_anchoring.jl): WITH = fig3's production ζ evaluation (loss
# width scale_multiple·ŝ, ŝ from the seed partition); WITHOUT = the ablation
# evaluation of the same points with the loss width at a fixed external plug-in
# scale corrupted by ζ (the evaluation artifact records its scale interface).
# 1×2 groupplot in the CURRENT paper style (modeled on render_miscal_faceted.jl):
#   left  = scene-agnostic median pose error vs ζ (linear y, truncated at 6°),
#   right = mAA@10° vs ζ (continuous AUC kernel max(0, 1 - min(e,10)/10)).
#
# Visual grammar: pairs share a hue; DASHED = WITHOUT partition anchoring
# (matches the paper's dashed = fixed-external-scale convention), SOLID = WITH.
# Curves (7): TLS-IRLS-ŝ, Welsch-GNC and GM-GNC, each fixed-scale (dashed) and
# anchored (solid), plus the anchored Welsch-HQ reference (thin solid). The
# TLS-GNC pair is OMITTED to keep the panel at 7 curves — trivial to add
# ("IG  +GNC-TLS", both sides).
#
# ENV: EVALUATION_WITHOUT (the ablation evaluation), EVALUATION_WITH (fig3's sidecar),
# OUT, DEPLOY=1 (wrap in tikzpicture; main.tex draws the legend via
# \pgfplotslegendfromname{anchorlegend}).
using DrWatson; @quickactivate "ACCV2026"   # the project this tool runs under (srcdir/projectdir)
using JLD2, Statistics, Printf
include(srcdir("config.jl"))   # PAPER_STYLE, the frozen ζ axis blocks

# Both sides are supplied by scripts/fig_anchoring.jl (registry.jl paths).
const EVALUATION_WITHOUT = ENV["EVALUATION_WITHOUT"]
const EVALUATION_WITH    = ENV["EVALUATION_WITH"]
OUT    = ENV["OUT"]
DEPLOY = get(ENV, "DEPLOY", "") == "1"
YMIN   = get(ENV, "YMIN", "0.4")

# Both through the tuning-artifact reader (another format is refused). The
# pairing is CHECKED, never assumed: one ζ ladder, and every WITHOUT arm at
# exactly its WITH operating point.
dwith = load_tuning_artifact(EVALUATION_WITH)
dwithout = load_tuning_artifact(EVALUATION_WITHOUT)
String(dwithout["mode"]) == "evaluation" ||
    error("EVALUATION_WITHOUT=$EVALUATION_WITHOUT is not an evaluation-only artifact (mode $(dwithout["mode"]))")
zetas = Float64.(dwith["zetas"])
Float64.(dwithout["zetas"]) == zetas || error("the two evaluations' ζ ladders differ")
# Format 6: the operating point is a NATIVE VALUE, so the two evaluations are
# compared on the values themselves rather than on indices into a shared grid.
for b in dwithout["arms"], k in ("tuned_selection", "tuned_width")
    dwithout[k][b] == dwith[k][b] ||
        error("arm $b: the WITHOUT evaluation is not at the WITH operating point ($k)")
end
@info "WITHOUT evaluation" scale_interface = dwithout["scale_interface"] plugin_scale = dwithout["plugin_scale"]
ro_with, ro_without = dwith["evaluation"], dwithout["evaluation"]

# Curves through VisualGeometryEval's evaluation statistics (Render `evaluation_curve`):
# the finite median row and THE mAA rule row (`eligible_maa`).
curve(ro, arm)    = evaluation_curve(ro, arm, finite_median)
maacurve(ro, arm) = evaluation_curve(ro, arm, eligible_maa)

# ── curve roster: (side, arm-key, label, styled arm, dashed, line width) ──────
# Colour and marker are the styled arm's record in PAPER_STYLE
# (figure_style.jl); the paired contrast is the dash (DASHED = WITHOUT anchoring).
# TLS-IRLS-ŝ has no registry row of its own: it is drawn in the TLS-IRLS style.
SPECS = [
  (:without, "IG  +TLSadapt", "TLS-IRLS (fixed scale)",    "IG  +PoseLib", true,  0.8),
  (:with,    "IG  +TLSadapt", raw"TLS-IRLS-$\hat s$",      "IG  +PoseLib", false, 0.8),
  (:without, "IG  +GNC-W",    "Welsch-GNC (fixed scale)",  "IG  +GNC-W",   true,  0.8),
  (:with,    "IG  +GNC-W",    "Welsch-GNC",                "IG  +GNC-W",   false, 0.8),
  (:without, "IG  +GNC-GM",   "GM-GNC (fixed scale)",      "IG  +GNC-GM",  true,  0.8),
  (:with,    "IG  +GNC-GM",   "GM-GNC",                    "IG  +GNC-GM",  false, 0.8),
  (:with,    PAPER_WELSCH_HQ, "Welsch-HQ (ref.)",          PAPER_WELSCH_HQ, false, 0.6),   # THE paper's Welsch-HQ (configs/protocol.toml [paper])
]
src_ro(side)   = side === :without ? ro_without : ro_with
src_name(side) = side === :without ? "EVALUATION_WITHOUT" : "EVALUATION_WITH"
# Every curve is required: a missing arm is a broken evaluation, not a gap.
for s in SPECS
    haskey(src_ro(s[1]), s[2]) || error("arm $(s[2]) missing from $(src_name(s[1]))")
end
_color(s)  = arm_record(PAPER_STYLE, s[4]).color
_marker(s) = arm_record(PAPER_STYLE, s[4]).marker

coords(ys) = pgf_coords(zetas, ys)

# ── panel axis opts — the SHARED ζ-corruption blocks (src/figure_style.jl;
# byte-identical to render_miscal_faceted.jl's) ───────────────────────────────
const AXX = zeta_axis_x()
MEDY = zeta_axis_med_y(YMIN)
const MAAY = zeta_axis_maa_y()
const MEDYLAB = ZETA_MED_YLABEL
const MAAYLAB = ZETA_MAA_YLABEL


io = IOBuffer()
DEPLOY && println(io, raw"\begin{tikzpicture}")
open_faceted_groupplot(io; cols = 2, rows = 1, edge_labels = false, hsep = "34pt",
    width = raw"0.40\linewidth", height = raw"0.28\linewidth",
    opts = [AXX])
for r in 1:2
    yopt = r == 1 ? MEDY : MAAY
    ylab = r == 1 ? MEDYLAB : MAAYLAB
    # columns=3: 7 entries at 4 columns overflow the ACCV text width — pairs
    # stay adjacent at 3 (fixed/anchored per row, HQ reference last).
    leg  = r == 1 ? faceted_legend_opts("anchorlegend"; columns = 3) : ""
    println(io, "\\nextgroupplot[$yopt, ylabel={$ylab}$leg]")
    for s in SPECS
        yc = r == 1 ? curve(src_ro(s[1]), s[2]) : maacurve(src_ro(s[1]), s[2])
        arm_addplot(io, _color(s), _marker(s), s[5], coords(yc); line_width = "$(s[6])pt")
    end
    if r == 1  # complete legend once (image-only)
        for s in SPECS
            arm_legendimage(io, _color(s), _marker(s), s[5], s[3];
                            line_width = "$(s[6])pt", mark_size = "1.6pt")
        end
    end
end
println(io, raw"\end{groupplot}")
if DEPLOY
    println(io, raw"\end{tikzpicture}")   # main.tex draws \pgfplotslegendfromname{anchorlegend}
else
    println(io, raw"\path (group c1r1.south west) -- (group c2r1.south east)")
    println(io, raw"  node[midway, below=9mm] {\pgfplotslegendfromname{anchorlegend}};")
end

open(OUT, "w") do f; write(f, String(take!(io))); end
println("WROTE ", OUT)

# ── stdout summary: per-curve median pose error at ζ=1 and ζ=128 ─────────────
j1   = argmin(abs.(log2.(zetas) .- 0.0))
j128 = argmin(abs.(log2.(zetas) .- 7.0))
@printf("%-34s %-14s %10s %10s\n", "curve", "source", "med@ζ=$(round(zetas[j1],digits=3))", "med@ζ=$(round(zetas[j128],digits=1))")
for s in SPECS
    yc = curve(src_ro(s[1]), s[2])
    @printf("%-34s %-14s %9.3f° %9.3f°\n", s[3], src_name(s[1]), yc[j1], yc[j128])
end
