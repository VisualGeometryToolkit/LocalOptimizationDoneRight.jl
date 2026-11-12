# P3 matched-loss mechanism matrix (basin), faceted by objective. Same style as
# the composed-miscal figure. 3 loss columns × 2 rows (success rate P(e≤succ°) /
# conditional mean final error) vs pose perturbation δ. Within each loss:
# static IRLS, HQ passive-z₀ (no continuation), HQ active-z₀, GNC.
#
# THIN CALLER: the emission body is VisualGeometryToolkitEval.Render `emit_basin_faceted`;
# this script keeps only the paper wiring — argument parsing, default artifact
# paths, the panel table, the --exclude default and the legend name. Arm names
# are the deployed-sidecar keys (two spaces after IG); CV'd efficiency constant per method.
using DrWatson; @quickactivate "ACCV2026"   # the project this tool runs under (srcdir/projectdir)
include(srcdir("config.jl"))   # PAPER_STYLE, the arm vocabulary
@isdefined(PAPER_FIGDIR) || include(srcdir("registry.jl"))   # the campaign path registry

BUNDLE = cli_option(ARGS, "bundle",
  EXP_LADDER_BUNDLE)
OUT    = cli_option(ARGS, "out")   # required: the caller names where its panel goes
SUCC   = parse(Float64, cli_option(ARGS, "succ", EXP_LADDER_SUCC))   # the ladder protocol's success radius (registry.jl)
DEPLOY = cli_option(ARGS, "deploy", "") == "1"

# Roster: the main-paper render keeps MAIN_ARMS (figure_style.jl); the
# bundle's other arms (classical RansacLib duplicates, the excised Stu-tU-IRLS
# arm) are excluded HERE, never from the bundle.  --roster=all keeps every arm
# (supplement full-roster render); --exclude drops further arm names from this
# render only.
EXCL = Set(arm_name_list(cli_option(ARGS, "exclude", "")))      # figure_style.jl: THE arm-list parser
if cli_option(ARGS, "roster", "main") != "all"
    ms = String.(JLD2.load(BUNDLE, "methods"))
    union!(EXCL, setdiff(ms, main_arms(ms; extra = cli_option(ARGS, "extra-arms", "")), ["seed"]))
end
# ROWS: comma-separated row statistics in order — succ | maa | cond
# (emit_basin_faceted `rows`); default = the historical two-row figure.
ROWS = Symbol.(filter(!isempty, strip.(split(cli_option(ARGS, "rows", "succ,cond"), ","))))

emit_basin_faceted(PAPER_STYLE, BUNDLE, OUT; row_label = row_label("PhotoTourism", :E),
    succ = SUCC, deploy = DEPLOY, exclude = EXCL, legend_name = "basinlegend", rows = ROWS,
    panels = [(f, panel_title(f)) for f in FAMILY_ORDER])
