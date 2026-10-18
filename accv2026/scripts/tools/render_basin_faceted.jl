# P3 matched-loss mechanism matrix (basin), faceted by objective. Same style as
# the composed-miscal figure. 3 loss columns × 2 rows (success rate P(e≤succ°) /
# conditional mean final error) vs pose perturbation δ. Within each loss:
# static IRLS, HQ passive-z₀ (no continuation), HQ active-z₀, GNC.
#
# THIN CALLER: the emission body is VisualGeometryToolkitEval.Render `emit_basin_faceted`;
# this script keeps only the paper wiring — env parsing, default artifact
# paths, the panel table, the EXCLUDE default and the legend name. Arm names
# are the deployed-sidecar keys (two spaces after IG); CV'd scale multiple per method.
using DrWatson; @quickactivate "ACCV2026"   # the project this tool runs under (srcdir/projectdir)
include(srcdir("config.jl"))   # PAPER_STYLE, the arm vocabulary
@isdefined(PAPER_FIGDIR) || include(srcdir("registry.jl"))   # the campaign path registry

BUNDLE = get(ENV, "BUNDLE",
  EXP_LADDER_BUNDLE)
OUT    = get(ENV, "OUT", "/tmp/faceted_basin_body.tex")
SUCC   = parse(Float64, get(ENV, "SUCC", EXP_LADDER_SUCC))   # the ladder protocol's success radius (registry.jl)
DEPLOY = get(ENV, "DEPLOY", "") == "1"

# Roster: the main-paper render keeps MAIN_ARMS (figure_style.jl); the
# bundle's other arms (classical RansacLib duplicates, the excised Stu-tU-IRLS
# arm) are excluded HERE, never from the bundle.  ROSTER=all keeps every arm
# (supplement full-roster render); EXCLUDE drops further arm names from this
# render only.
EXCL = env_arm_set("EXCLUDE")      # figure_style.jl: THE arm-list parser
if get(ENV, "ROSTER", "main") != "all"
    ms = String.(JLD2.load(BUNDLE, "methods"))
    union!(EXCL, setdiff(ms, main_arms(ms), ["seed"]))
end
# ROWS: comma-separated row statistics in order — succ | maa | cond
# (emit_basin_faceted `rows`); default = the historical two-row figure.
ROWS = Symbol.(filter(!isempty, strip.(split(get(ENV, "ROWS", "succ,cond"), ","))))

emit_basin_faceted(PAPER_STYLE, BUNDLE, OUT; row_label = row_label("PhotoTourism", :E),
    succ = SUCC, deploy = DEPLOY, exclude = EXCL, legend_name = "basinlegend", rows = ROWS,
    panels = [(f, panel_title(f)) for f in FAMILY_ORDER])
