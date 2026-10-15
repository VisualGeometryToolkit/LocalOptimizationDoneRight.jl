#!/usr/bin/env julia
# =============================================================================
# figures_registry.jl — THE paper-figure registry + driver.
#
# One table (FIGURES) mapping a figure id to how it renders (bundle + PanelSpec)
# and where it deploys; one driver (render_figures) that
# renders any subset and copies the artifacts into the paper's figures/
# directory (the supplement's scoring-only miscalibration figure, via
# fig1_sel_miscal.jl).
#
#   julia --project=. scripts/tools/figures_registry.jl fig1 fig1_maa
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"

# Guarded include: render_bundle/PanelSpec for the :panel entries. (The budget
# figure is fig4_budget.jl + fig4_budget_grid.jl; the basin ladder figures are
# fig2_basin.jl's.)
@isdefined(render_bundle) || include(srcdir("plot_lo_sensitivity.jl"))

@isdefined(PAPER_FIGDIR) || include(srcdir("registry.jl"))
const PAPER_FIGS = PAPER_FIGDIR          # the paper's figures directory (registry.jl; PAPER_FIGS env overrides)

# Welsch-marginal (WMG) was cut from the paper long ago; both Fig 1 panels drop
# it on every re-render so it never creeps back from the bundle roster.
# (Substring filter on "wmg"/"marg"; MAGSAC/RANSAC are unaffected.)
_drop_wmg(l) = (s = lowercase(string(l)); !occursin("wmg", s) && !occursin("marg", s))

# Registry entries: render_bundle(src, PanelSpec(; spec...)) → <panel_name>.tex
# next to the bundle; deploy copies it to <figdir>/<dest>.
const FIGURES = Dict{Symbol,NamedTuple}(
    # Fig 1 (main paper): scoring-only miscalibration, all pairs, fixed tuned scale multiple.
    # Bundle job 2427 added MAGSAC++ and RANSAC; v3 (2026-09-08) adds SIMFIT++. Rendered
    # as TWO panels — median (:fig1) and mAA@10° (:fig1_maa) — off the same
    # bundle; both write the shared "selmiscallegend" legend-to-name.
    :fig1 => (
              src  = EXP_SEL_MISCAL_BUNDLE,              # registry.jl (fig1_sel_miscal.jl produce)
              spec = (width = raw"\linewidth", height = raw"0.72\linewidth",
                      ymax = 6, legend_name = "selmiscallegend", legend_cols = 4),
              panel_name = "panel_sel_miscal",
              label_filter = _drop_wmg,
              dest = "panel_sel_miscal.tex"),
    # Fig 1 companion: mAA@10° panel off the SAME sel-miscal bundle (stat=:maa
    # reads the mean-of-scene mAA off the median-tuned deployed rows).
    # legend routed to an UNUSED box name (only :fig1's median panel defines the
    # printed "selmiscallegend") — same roster, so this avoids a duplicate-label
    # clash when main.tex \input's both fragments under one shared legend.
    :fig1_maa => (
              src  = EXP_SEL_MISCAL_BUNDLE,              # registry.jl (fig1_sel_miscal.jl produce)
              spec = (width = raw"\linewidth", height = raw"0.72\linewidth",
                      legend_name = "selmiscallegend_maa_unused", legend_cols = 4,
                      # PANELS.mAA_mean y_spacing is 0.025 (fine, for near-tied budget mAA);
                      # over a forced [0,1] mAA axis that is ~40 crammed ticks, so
                      # pin a coarse major grid, a 0 floor and a 0.8 ceiling (no
                      # scoring rule exceeds it; 2026-09-08) for a clean panel.
                      ymin = 0, ymax = 0.8, ytick_spacing = 0.2),
              panel_name = "panel_sel_miscal_maa", stat = :maa,
              label_filter = _drop_wmg,
              dest = "panel_sel_miscal_maa.tex"),
)

"""
    render_figures(ids::Symbol...; deploy = true, figdir = PAPER_FIGS)

Render the registered figures `ids` and (with `deploy`) copy the artifacts
into `figdir`. Known ids: `keys(FIGURES)`.
"""
function render_figures(ids::Symbol...; deploy::Bool = true,
                        figdir::AbstractString = PAPER_FIGS)
    isempty(ids) &&
        error("render_figures: no ids (known: $(sort!(collect(keys(FIGURES)))))")
    deploy && mkpath(figdir)
    for id in ids
        haskey(FIGURES, id) ||
            error("render_figures: unknown id :$id (known: $(sort!(collect(keys(FIGURES)))))")
        e = FIGURES[id]
        render_bundle(e.src, PanelSpec(; e.spec...);
                      panel_name = e.panel_name,
                      label_filter = get(e, :label_filter, nothing),
                      stat = get(e, :stat, :median))
        deploy && cp(joinpath(dirname(e.src), e.panel_name * ".tex"),
                     joinpath(figdir, e.dest); force = true)
        println("rendered  :$id", deploy ? "  (deployed → $figdir)" : "")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    ids = Symbol.(filter(a -> !startswith(a, "--"), ARGS))
    render_figures(ids...; deploy = !("--no-deploy" in ARGS))
end
