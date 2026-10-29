# =============================================================================
# src/figure_style.jl — the paper's faceted-arm style rows and THE paper style.
# THIN by contract: ALL styling machinery is package-level — the arm GRAMMAR
# in VisualGeometryToolkitEval.Render figure_style.jl and the house conventions in
# Render axis_style.jl. This paper supplies DATA only, gathered into ONE value,
# `PAPER_STYLE` (a Render `PaperStyle`), which every renderer is handed: the
# palette and summary rows (palette.jl), the faceted arm records, and the
# ACCV axis blocks the camera-ready figures were frozen at (byte-compared, so
# they live here rather than in the package). Hand-styled axis options in
# paper scripts are a defect (test/test_experiment_contracts.jl).
#
# The styling GRAMMAR (color-hue = loss family, shade+marker = mechanism,
# dashed = fixed-external scale; FAMILY_ORDER / PATH_RANK) is Render's. This
# file supplies the CONCRETE rows: the paper-owned fig_colors.tex color name
# and ramp step per arm — keyed PER ARM because the truncated pair TLS-IRLS /
# TLS-LZ shares (tls, truncated) yet keeps distinct shades (ColorIGPoseLib /
# ColorIGLZ) — and one probe instance per styled arm, built by the deployed
# rosters' OWN ctors (arm_rosters.jl), so a legend cannot drift from the
# production strategy. Every other style axis (family, mechanism, marker,
# scale interface ⇒ dashed) is the strategy's trait.
#
# Loaded by config.jl after arm_rosters.jl and palette.jl.
# =============================================================================

# Paper-owned style axes: the fig_colors.tex color name, its hex (the
# paper's \providecolor value — previews and every other emitter read it from
# here, never a second copy) and the ramp step.
const _ARM_PAPER = Dict(
    # `shade` = the arm's step on its family's light→dark ramp in fig_colors.tex
    # (1 = lightest); it is THE within-facet legend/plot order, so a legend reads
    # lightest to darkest exactly as the curves do, in every figure.
    "IG  +WIrls"   => (color="ColorIGWIrls",   hex="A1D99B", shade=1),
    # THE paper's Welsch-HQ (arm_rosters.jl PAPER_WELSCH_HQ, configs/protocol.toml
    # [paper] welsch_hq: the zero-clamp "IG  +Lift@zc" or the faithful
    # "IG  +Lift") carries the published Welsch-HQ style; the other z-block, never
    # drawn in the paper (not in MAIN_ARMS), keeps the darkest Welsch step so a
    # supplement-style full-roster render can still tell them apart.
    PAPER_WELSCH_HQ   => (color="ColorIGLift",   hex="41AB5D", shade=2),
    UNSHOWN_WELSCH_HQ => (color="ColorIGLiftZC", hex="00441B", shade=4),
    "IG  +GNC-W"   => (color="ColorIGGNCW",    hex="006D2C", shade=3),
    "IG  +PoseLib" => (color="ColorIGPoseLib", hex="FDAE6B", shade=1),   # TLS-IRLS
    "IG  +LZ"      => (color="ColorIGLZ",      hex="FD8D3C", shade=2),
    "IG  +TLS-HQ"  => (color="ColorIGTLSHQ",   hex="E6550D", shade=4),
    "IG  +GNC-TLS" => (color="ColorIGGNCTLS",  hex="8C2D04", shade=6),   # darkest TLS
    # Stu-tU arms (blue family) close the uniform-mixture facet after the TLS ramp.
    "IG  +LO"      => (color="Colorstulo",     hex="4363D8", shade=8),
    "IG  +BCD"     => (color="ColorIGBCD",     hex="08519C", shade=9),   # Colorstulo's family, distinct shade
    # Its objective-matched variant (refit width = a*; arm_rosters.jl
    # `matched_key`, declared per cell): the same strategy, so the same marker and line —
    # the next, darker step of the ramp; label "… (matched)". Opt-in: never in
    # MAIN_ARMS, drawn only where a render names it (EXTRA_ARMS).
    "IG  +BCD@a*"  => (color="ColorIGBCDMatched", hex="08306B", shade=10),
    "IG  +GM-HQ"   => (color="ColorIGGMHQ",    hex="807DBA", shade=2),
    "IG  +GM-Irls" => (color="ColorIGGMIrls",  hex="9E9AC8", shade=1),   # lightest BuPu step of the GM family
    "IG  +GNC-GM"  => (color="ColorIGGNCGM",   hex="54278F", shade=3),
    # Classical LO rows: fixed-EXTERNAL absolute loss width (dashed, like TLS-IRLS/LZ);
    # orange/brown TLS-family shades clear of the four taken oranges.
    "IG  +TLS-LO"       => (color="ColorIGTLSLO",     hex="F16913", shade=3),
    "IG  +TLS-LO+"      => (color="ColorIGTLSLOP",    hex="A63603", shade=5),
    "IG  +TLS-LO+(ref)" => (color="ColorIGTLSLOPRef", hex="543005", shade=7),
)

# One probe per styled arm, built by the arm table's own constructor
# (arm_rosters.jl) at the unit knob. The identity traits are type/variant-level,
# so the knob is immaterial.
const _ARM_PROBES = let unrostered = setdiff(keys(_ARM_PAPER), keys(ARM_TABLE))
    isempty(unrostered) || error("figure_style: styled arms the arm table lacks: $(sort!(collect(unrostered)))")
    [key => arm_strategy(ARM_TABLE[key], 1.0) for key in keys(_ARM_PAPER)]
end

# ---------------------------------------------------------------------------
# THE ACCV AXIS BLOCKS — the ζ-corruption panels (composed miscalibration,
# partition anchoring) and the grid of the budget/basin/time panels, frozen at
# the camera-ready figures (byte-compared).
# ---------------------------------------------------------------------------
"x-axis options of the ζ (scale-corruption) panels: log₂, 1/64…64 ticks."
zeta_axis_x() =
    raw"xmode={log}, log basis x={2}, xlabel={scale corruption $\zeta$}, " *
    raw"xmajorgrids, ymajorgrids, grid style={gray!20}, label style={font=\footnotesize}, " *
    raw"tick label style={font=\scriptsize}, xmin={0.0078125}, xmax={128.0}, " *
    raw"xtick={0.015625,0.0625,0.25,1.0,4.0,16.0,64.0}, " *
    raw"xticklabels={$1/64$,$1/16$,$1/4$,$1$,$4$,$16$,$64$}"

"y-axis options of the ζ panels' MEDIAN row (linear, °-labelled, ymax 6°)."
# `ymax`/`ytick_spacing` size the median row for error scales other than the relative-pose
# default (e.g. HEB-H's Malis–Vargas homography pose error, tens of degrees).
zeta_axis_med_y(ymin; ymax::Real = 6, ytick_spacing::Real = 1) =
    "ymin={$ymin}, ymax={$(ymax)}, ytick={$(join([string(isinteger(t) ? Int(t) : t) for t in ytick_spacing:ytick_spacing:ymax], ","))}, minor y tick num={1}, yminorgrids, " *
    raw"scaled y ticks={false}, yticklabel style={/pgf/number format/.cd, fixed, precision=0}, " *
    raw"yticklabel={$\pgfmathprintnumber{\tick}^\circ$}"

"y-axis options of the ζ panels' mAA row (0.2..1 linear)."
zeta_axis_maa_y() =
    raw"ymin={0.2}, ymax={1}, ytick={0.2,0.4,0.6,0.8,1}, minor y tick num={1}, yminorgrids"

"Median-row ylabel of the ζ panels."
const ZETA_MED_YLABEL = raw"med.\ $\max(\Delta \mathbf{R},\Delta \mathbf{t})$"
"mAA-row ylabel of the ζ panels."
const ZETA_MAA_YLABEL = raw"mAA@$10^\circ$"
"The grid of the budget, basin and time panels."
const GRID_OPTS = raw"xmajorgrids, ymajorgrids, grid style={gray!20}"

"Axis options of the polishing figure's ECDF of the per-pair error change (scripts/polish.jl), frozen at the camera-ready figure; `w` is the half-range in degrees."
polish_diff_axis(w) =
    "scale only axis, width=0.62\\linewidth, height=0.28\\linewidth, xmin=$(-w), xmax=$(w), ymin=0, ymax=1, " * GRID_OPTS * ", " *
    raw"label style={font=\footnotesize}, tick label style={font=\scriptsize}, " *
    raw"xlabel={change in pose error by the polish [$^\circ$]}, ylabel={fraction of pairs}, " *
    raw"legend pos=south east, legend style={draw=none, font=\tiny, fill=none, inner sep=1pt, row sep=-2pt}, " *
    raw"legend image code/.code={\draw[#1] (0cm,0cm) -- (0.35cm,0cm);}"

# ---------------------------------------------------------------------------
# THE PAPER STYLE — palette + summary rows (palette.jl), then the faceted arms
# in facet order: the SAME label, colour, marker and dash as the faceted
# figures, the label carrying the score (selection + LO).
# ---------------------------------------------------------------------------
# The label is the arm table's (`arm_lo_label`): the trait label (the
# zero-clamp variant's strategy labels itself "Welsch-HQ (zero clamp)"), plus
# the objective-matched variant's " (matched)" — its probe is its base arm's strategy.
# The paper's Welsch-HQ is labelled plainly "Welsch-HQ" whichever z-block it is;
# the unshown one names its z-block.
paper_lo_label(key::AbstractString) =
    key == PAPER_WELSCH_HQ ? arm_lo_label(ARM_TABLE["IG  +Lift"]) :
    key == "IG  +Lift"     ? arm_lo_label(ARM_TABLE["IG  +Lift"]) * " (faithful z-block)" :
                             arm_lo_label(ARM_TABLE[key])
"The legend label of arm `key` in the paper (`composed_label`, through [`paper_lo_label`](@ref))."
paper_composed_label(key::AbstractString) = (d = ARM_TABLE[key];
    SEL_SHORT[d.sel] * "+" * paper_lo_label(key) * (isempty(d.cite) ? "" : "~" * d.cite))
const _ARM_RECORDS = Dict{String,NamedTuple}(k => merge(r, (label = paper_lo_label(k),))
                          for (k, r) in arm_style_records(_ARM_PROBES, _ARM_PAPER))
_facet_order(key) = (family_rank(_ARM_RECORDS[key].family),
                     (r = _ARM_RECORDS[key]; r.shade === nothing ? PATH_RANK[r.path] : Int(r.shade)),
                     _ARM_RECORDS[key].label)

"THE paper style: the one `PaperStyle` every renderer of this paper is handed."
const PAPER_STYLE = let keys_ = sort(collect(keys(_ARM_PAPER)); by = _facet_order)
    PaperStyle(; colors = PALETTE_COLORS,
               rows = vcat(PALETTE_ROWS,
                           [(k, paper_composed_label(k), _ARM_RECORDS[k].color, _ARM_RECORDS[k].marker,
                             _ARM_RECORDS[k].dashed) for k in keys_]),
               arms = _ARM_RECORDS,
               grid = GRID_OPTS, zeta_x = zeta_axis_x(), zeta_med_y = zeta_axis_med_y,
               zeta_maa_y = zeta_axis_maa_y(), med_ylabel = ZETA_MED_YLABEL, maa_ylabel = ZETA_MAA_YLABEL)
end

# ---------------------------------------------------------------------------
# THE ARM VOCABULARY — the names the timing sidecars write map to registry
# keys through the arm table (arm_rosters.jl TIMING_TAGS); this section adds the
# arm's typeset label. Every renderer and table reads these, so no figure or
# table spells an arm on its own.
# ---------------------------------------------------------------------------
# Oracle/run tag prefix ("<dataset>_<model>": PT_E, HEB_H, ETH_F) -> the
# dataset name of a row label.
const DATASET_NAME = Dict("PT" => "PhotoTourism", "HEB" => "HEB", "ETH" => "ETH3D")

"""
    arm_lo_us_per_call(runs, key) -> Float64

Arm `key`'s isolated per-call LO wall time [µs] from a timing sidecar's `runs`
(time_lo_supp.jl): VisualGeometryToolkitEval's `lo_us_per_call` of the run and method column the
arm's `TIMING_TAGS` entry names (`NaN` when that column made no LO call).
"""
function arm_lo_us_per_call(runs, key::AbstractString)
    tag, col = TIMING_TAGS[key]
    r = only(filter(x -> x.tag == tag, runs))
    i = findfirst(==(col), r.methods)
    i === nothing && error("arm_lo_us_per_call: timing run $tag has no $col column")
    return lo_us_per_call(r, i)
end

"The registry label typeset through the prose macros (\\stuU, \\tlsirls)."
label_tex(key::AbstractString) = replace(arm_record(PAPER_STYLE, key).label, "Stu-\$t\$U" => raw"\stuU{}", "TLS-IRLS" => raw"\tlsirls{}")

# ---------------------------------------------------------------------------
# MODEL-CLASS SYMBOLS as typeset in EVERY figure (grid row labels, oracle
# legend entries, panel titles): matrices bold. One vocabulary, so no figure
# spells them differently (2026-09-08).
# ---------------------------------------------------------------------------
const MODEL_TEX = Dict(:E => raw"\mathbf{E}", :F => raw"\mathbf{F}", :H => raw"\mathbf{H}")
model_tex(m::Symbol) = MODEL_TEX[m]
"Grid row label: dataset name + model symbol, e.g. `PhotoTourism \$\\mathbf{E}\$`."
row_label(dataset::AbstractString, m::Symbol) = dataset * " \$" * MODEL_TEX[m] * "\$"
"Legend entry of the budget oracle (best minimal model at each budget)."
oracle_budget_label(m::Symbol) = "oracle (best minimal \$" * MODEL_TEX[m] * "\$)"

# ---------------------------------------------------------------------------
# MAIN-PAPER ROSTER — the one list of optimizers the main-paper figures show.
# Every main-figure renderer runs its data product's arm names through
# `main_arms` so Figs. 2-5 (basin, miscalibration, sample budget, transfer)
# carry the same rows and their legends agree.  Arms outside the roster stay
# in the bundles/sidecars and in the supplement's full-roster renders; a
# figure-specific control (the Stu-tU-BCD row of the miscalibration figure)
# is added per render via EXTRA_ARMS, never by editing this list.
#   {Welsch, TLS, GM} x {IRLS, HQ, GNC}  +  TLS-IRLS (PoseLib), TLS-LZ, TLS-LO+
# Welsch-HQ is THE paper's (PAPER_WELSCH_HQ); the other z-block is never drawn.
const MAIN_ARMS = [
    "IG  +WIrls", PAPER_WELSCH_HQ, "IG  +GNC-W",
    "IG  +PoseLib", "IG  +LZ", "IG  +TLS-LO+", "IG  +TLS-HQ", "IG  +GNC-TLS",
    "IG  +GM-Irls", "IG  +GM-HQ", "IG  +GNC-GM",
]
for a in MAIN_ARMS
    haskey(_ARM_PAPER, a) || error("MAIN_ARMS: $a has no _ARM_PAPER style entry")
end

"""
    arm_name_list(s) -> Vector{String}
    env_arm_set(var) -> Set{String}

THE comma-separated arm-name list a render reads from its environment:
`EXTRA_ARMS` (added to the main roster, [`main_arms`](@ref)) and `EXCLUDE`
(dropped from THIS render, the emitters' `exclude` keyword). Surrounding space
and blank entries are ignored, so `"a, b"` and a trailing comma both parse.

One parser: this was written four times before 2026-10-03 — once in each of
`render_miscal_faceted.jl`, `render_basin_faceted.jl` and a since-removed
PnP renderer, plus `main_arms` — each copy its own spelling of the
same two lines, and one of them without the `String.` that makes the result a
`Set{String}` rather than a set of `SubString`s.
"""
arm_name_list(s::AbstractString) = String.(filter(!isempty, strip.(split(s, ","))))
env_arm_set(var::AbstractString) = Set(arm_name_list(get(ENV, var, "")))

"""
    main_arms(present; extra = ENV["EXTRA_ARMS"]) -> Vector{String}

Roster gate for a main-paper render: the arm names of `present` (bundle
methods, sidecar arms, summary keys) that are in `MAIN_ARMS` or in `extra`
(comma-separated; default none).  Order of `present` is kept.  A main-roster
arm missing from the data product is reported with @warn — the figure is
then inconsistent with its siblings and the experiment needs that arm — but
never silently dropped from the roster.
"""
function main_arms(present; extra = get(ENV, "EXTRA_ARMS", ""))
    present = String.(collect(present))
    keep = vcat(MAIN_ARMS, arm_name_list(extra))
    absent = setdiff(MAIN_ARMS, present)
    isempty(absent) || @warn "main-roster arms absent from this data product" absent
    return [a for a in present if a in keep]
end

"""
    POLISH_SOURCE_STYLES

The pgfplots style of each source curve of the polishing figure
(`scripts/polish.jl`, `paper/figures/panel_polish_diff.tex`), in the order of
the polish config's `[polish] sources` (the paper's Welsch-HQ, then
Stu-tU-BCD), a third for a further source.
"""
const POLISH_SOURCE_STYLES = ["ColorIGLift, line width=1.0pt", "ColorIGBCD, line width=1.0pt, dashed", "black, dotted"]
