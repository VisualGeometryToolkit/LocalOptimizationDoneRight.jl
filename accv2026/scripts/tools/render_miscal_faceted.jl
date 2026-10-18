# Objective-faceted composed-miscalibration groupplot, in the CURRENT paper style
# (linear y 1..6 with ° labels, powers-of-4 ζ fraction ticks, framework markers).
# 3 panels {Welsch, TLS, GM}, shared y.
#
# THIN CALLER: the emission body is VisualGeometryToolkitEval.Render `emit_miscal_faceted`;
# this script keeps only the paper wiring — env parsing, default artifact
# paths, the oracle constants, the panel table, the main-paper EXCLUDE
# default and the legend name.
using DrWatson; @quickactivate "ACCV2026"   # the project this tool runs under (srcdir/projectdir)
include(srcdir("config.jl"))   # PAPER_STYLE, the arm vocabulary

SIDECAR = ENV["SIDECAR"]   # a operating-points sidecar (read through load_tuning_artifact by the emitter)
OUT = get(ENV, "OUT", "/tmp/faceted_miscal_body.tex")
# Oracle selection bound: NEVER a hard-coded default. The floor/ceiling are
# computed into oracle_floors.jld2 (compute_supp_oracle_floors.jl, THE
# writer, by each driver's stage oracle) and selected by ORACLE_TAG ("PT_E", "HEB_H",
# "PT_F", ...); the tag's trailing letter is the panel's model class.
# 2026-07-26 incident: the old env defaults (0.5/0.95) silently shipped in
# deployed panels while the computed PT_E values were 0.469/0.852 — a missing
# tag or entry is now a hard error, and there is no value-override path.
ORACLE_TAG = get(ENV, "ORACLE_TAG") do
    error("ORACLE_TAG not set — supply the oracle_floors.jld2 key (e.g. PT_E)")
end
let floors = JLD2.load(oracle_floors_path(), "floors")
    haskey(floors, ORACLE_TAG) ||
        error("oracle_floors.jld2 has no entry $(ORACLE_TAG) — run the oracle compute driver first")
    haskey(floors, "$(ORACLE_TAG)_maa") ||
        error("oracle_floors.jld2 has no entry $(ORACLE_TAG)_maa — run the oracle compute driver first")
    global ORACLE     = floors[ORACLE_TAG]
    global ORACLE_MAA = floors["$(ORACLE_TAG)_maa"]
end
ORACLE_CLASS = model_tex(Symbol(last(split(ORACLE_TAG, '_'))))   # legend model-class symbol (figure_style.jl MODEL_TEX)
# Row label of the standalone panel (dataset + model symbol, figure_style.jl):
# ORACLE_TAG is "<dataset>_<model>" (PT_E, HEB_H, ...); DATASET_NAME (figure_style.jl) names the dataset.
ROW_LABEL = row_label(DATASET_NAME[String(first(split(ORACLE_TAG, '_')))], Symbol(last(split(ORACLE_TAG, '_'))))
YMIN   = get(ENV, "YMIN", "0.4")
# Median-row ceiling / tick step (deg): the relative-pose default is 6/1; HEB-H's
# homography pose error needs tens of degrees (supp_H_miscal.jl sets 30/5).
YMAX   = parse(Float64, get(ENV, "YMAX", "6"))
YTICK_SPACING  = parse(Float64, get(ENV, "YTICK_SPACING", "1"))
DEPLOY = get(ENV, "DEPLOY", "") == "1"   # deploy: wrap in tikzpicture, legend drawn by main.tex
# ROWS=med,maa (default) | maa | med — which statistic rows to draw (main-paper
# panels draw mAA alone; the supplement keeps the median rows for comparison).
ROWS = Symbol.(strip.(split(get(ENV, "ROWS", "med,maa"), ",")))

# Roster: the main-paper render keeps MAIN_ARMS (figure_style.jl) plus this
# figure's same-objective control, Stu-tU-BCD (EXTRA_ARMS; default
# "IG  +BCD"); ROSTER=all keeps every Stu-tU-scored sidecar arm (supplement
# full-roster render).  EXCLUDE drops arm keys from THIS render only.
# (not `ROSTER`: that name is the prelude's const arm table, arm_rosters.jl)
ROSTER_SEL = get(ENV, "ROSTER", "main")
EXTRA  = String.(filter(!isempty, strip.(split(get(ENV, "EXTRA_ARMS", "IG  +BCD"), ","))))
EXCL   = env_arm_set("EXCLUDE")      # figure_style.jl: THE arm-list parser

# NB: "Stu-tU scoring; panels vary the refinement objective" belongs in the
# figure \caption (main.tex), not on the plot.
emit_miscal_faceted(PAPER_STYLE, SIDECAR, OUT; row_label = ROW_LABEL,
    oracle = ORACLE, oracle_maa = ORACLE_MAA, oracle_class = ORACLE_CLASS,
    ymin = YMIN, ymax = YMAX, ytick_spacing = YTICK_SPACING, deploy = DEPLOY, rows = ROWS,
    exclude = EXCL, legend_name = "miscallegend",
    panels = [(f, panel_title(f)) for f in FAMILY_ORDER],
    # Stu-tU (IG) scoring only — drop MSAC-scored arms; main roster unless ROSTER=all
    arm_filter = a -> startswith(a, "IG") && (ROSTER_SEL == "all" || a in MAIN_ARMS || a in EXTRA))
