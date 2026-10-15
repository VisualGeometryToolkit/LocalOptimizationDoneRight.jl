#!/usr/bin/env julia
# =============================================================================
# plot_lo_sensitivity.jl — OFFLINE renderer for the LO-sensitivity (B),
# miscalibration (A), and well-depth (Δ) bundles.
#
# Reads a compute-once M-bundle (`bundle.jld2` written by experiment_producer.jl
# through `save_tuning_artifact`; read through `load_tuning_artifact`, which
# refuses another format — regenerate it), then
# re-runs the bootstrap trials PURELY ON THE SAVED M (CPU lookup — no GPU, no LO
# re-run), computes BCa CIs the same way the paper Sensitivity panels do
# (`mean` over the per-trial test medians, Shek-matched `bootstrap_ci`),
# and emits a PGFPlots group panel + standalone preview into the bundle's dir.
# Every tuning parameter (the budget sampling, the window, the objective) is
# the `windowed_bootstrap` spec the bundle records; only the
# x positions rendered (the n-grid (B) or ζ-grid (A)) are a free knob here.
#
#   julia --project=. src/plot_lo_sensitivity.jl <bundle.jld2> [--xgrid=2,4,8,...,1024]
#
# Curves are the bundle's labels (classic five: IG sel / IG +LO / IG +Lift /
# MSAC sel / MSAC +LO; delta bundles add one per Δ, summarized as a "Δ sweep"
# curve with the baselines as flat anchors).  x-axis: validation size n
# (mode="validation_budget"), scale corruption ζ (mode="miscal"), or well depth Δ
# (mode="delta" — canonical summary + console table; no PGF panel).
# =============================================================================

using JLD2, Random, Statistics, Printf, DataFrames
using PGFPlotsX
using VisualGeometryCore: to_native, native_map, LossWidth, OutlierHalfwidth
using VisualGeometryEval: cli_option
using VisualGeometryEval.Evaluation: WindowedGridMethod, FlatProtocol, compute_method_rows,
    window_columns
using VisualGeometryEval.Stats: bootstrap_ci, reference_scale, scene_ranges
using VisualGeometryEval.Tuning: load_tuning_artifact, resampling_rng, corrupt_native, _tune_objective
using VisualGeometryEval.Tuning: nearest_column
# The paper config (rosters, PAPER_STYLE) on top of the packages; guarded
# inside, so a driver that already loaded it does not redefine.
include(joinpath(@__DIR__, "config.jl"))

const LO_LABELS = ["IG  sel", "IG  +LO", "IG  +Lift", "MSAC sel", "MSAC +LO"]

# Labels carried by this bundle, in producer order.
_bundle_labels(d) = collect(String, d["labels"])

# eq-(28) native maps (VisualGeometryCore `native_map`, the ONE
# definition, shared with the producer): each label's native axis is the
# bundle's `label_axis` record (`:outlier_halfwidth` | `:loss_width`), at the
# codimension its grids were built at (`d_g`).
_axis(label, d) = Symbol(d["label_axis"][label])
_dg(d) = Int(d["d_g"])
_tonat(label, d) = _axis(label, d) === :loss_width ? native_map(LossWidth(); d_g = _dg(d)) :
    # WMG: the mixture is only a valid model for half-widths inside the
    # pool-frame residual domain — clamp the reachable columns to ≤ r_max = 1.
    occursin("WMG", label) ?
        ((m, scale) -> min(to_native(OutlierHalfwidth(), m, scale; d_g = _dg(d)), 1.0)) :
    native_map(OutlierHalfwidth(); d_g = _dg(d))

# The bundle's tuning scheme and its parts.
_scheme(d) = d.spec.scheme
_window(d) = _scheme(d).scale_multiple_window
_budget(d) = _scheme(d).budget_sampling

# FlatProtocol from per-scene pair counts (val scenes first, then test).
function _proto(np_per, nval)
    nscene = length(np_per)
    val_idx  = [(si, p) for si in 1:nval         for p in 1:np_per[si]]
    test_idx = [(si, p) for si in (nval+1):nscene for p in 1:np_per[si]]
    FlatProtocol(val_idx, test_idx)
end

# WindowedGridMethod of one label of the bundle.
_windowed_method(label, d) =
    WindowedGridMethod(label, d["M"][label], d["s2_by_scene"], d.grids[_axis(label, d)],
                       _window(d), _tonat(label, d), _scheme(d).criterion)

# =============================================================================
# The fixed-width miscalibration evaluation — protocol: PROTOCOL.md §4 (tune once
# at the true val scale, corrupt the deployed plug-in by ζ, evaluation at the
# column nearest ζ·native*). CIs: BCa over test pairs of the pool median at
# the deployed column.
# =============================================================================
function _fixed_width_rows(label, d, zetas, seed0)
    M = reduce(vcat, d["M"][label])
    np_per = d["np_per"]; nval = d["nval"]
    nv = sum(np_per[1:nval])
    val  = view(M, 1:nv, :)
    test = view(M, nv+1:size(M, 1), :)
    grid = d.grids[_axis(label, d)]
    σ  = reference_scale(reduce(vcat, d["s2_by_scene"][1:nval]))
    # Calibration tune: windowed free argmin of the spec's objective over the
    # full validation pool.
    win = window_columns(_window(d), grid, _tonat(label, d), σ)
    cstar = win[argmin([Float64(_tune_objective(_scheme(d).criterion, view(val, :, c)))
                        for c in win])]
    # Deployment evaluation: the column nearest each ζ-scaled tuned native.
    cols = [view(test, :, nearest_column(grid, corrupt_native(grid[cstar], ζ))) for ζ in zetas]
    # Mean-of-scene MEDIAN (Shekhovtsov "Mean median"): the test rows are laid
    # out scene-by-scene (scenes nval+1..nscene), so per-scene medians → mean
    # over scenes + scene-clustered BCa (NOT the pooled-over-pairs median).
    tsizes = np_per[(nval + 1):end]
    return scene_mean_median_rows!(NamedTuple[], label, zetas, cols,
                                   scene_ranges(tsizes); seed = seed0)
end

# =============================================================================
# Operating-points sidecar merge (the sequential CV, run_sequential_cv.jl). The
# sidecar carries fully-precomputed deployed-point evaluations of the composed
# arms at their tuned operating points. Rows produced here REPLACE those arms'
# base-bundle rows.
# =============================================================================
function _operating_points_rows(tk, mode, xs, seed0)
    rows = NamedTuple[]
    if mode == "miscal"
        zetas = Float64.(tk["zetas"])
        keep = [j for j in eachindex(zetas) if any(x -> isapprox(x, zetas[j]; rtol = 1e-9), xs)]
        # Mean-of-scene MEDIAN over the test scenes (sidecar `np_per_test` gives
        # the per-scene pair counts of the evaluation matrix) — matches the base
        # bundle's `_fixed_width_rows` scene-clustered statistic.
        sr = scene_ranges(Int.(tk["np_per_test"]))
        for base in tk["arms"]
            scene_mean_median_rows!(rows, base, zetas[keep],
                                    [view(tk["evaluation"][base], :, j) for j in keep],
                                    sr; seed = seed0)
        end
    else  # validation_budget: point = mean over per-draw test medians, CI = BCa over trials
           # (resampled from the sidecar's own budget sampling, `resampling_rng`).
           # Rows are padded to the 19-column canonical schema so they can sit
           # in one DataFrame with `compute_method_rows` output (the
           # 1-knob arms); the mAA/idx diagnostics are NaN for sidecar arms.
        budget = tk.spec.scheme.budget_sampling
        budgets = budget.sizes
        for base in tk["arms"], (j, n) in enumerate(budgets)
            n in xs || continue
            tm = filter(isfinite, Float64.(view(tk["trial_med"][base], :, j)))
            pt = isempty(tm) ? NaN : mean(tm)
            lo, hi = length(tm) >= 3 ?
                bootstrap_ci(mean, resampling_rng(budget, n), tm) : (pt, pt)
            sd = length(tm) >= 2 ? std(tm) : NaN
            push!(rows, (method = String(base), tuning_criterion = "median", n = Float64(n),
                         mean_med = pt, lo95_mean_med = lo, hi95_mean_med = hi,
                         std_med = sd, lo95_std_med = NaN, hi95_std_med = NaN,
                         mean_mAA = NaN, lo95_mean_mAA = NaN, hi95_mean_mAA = NaN,
                         std_mAA = NaN, lo95_std_mAA = NaN, hi95_std_mAA = NaN,
                         idx_mean = NaN, idx_std = NaN, edge_frac = NaN, T = 0))
        end
    end
    return rows
end

# Re-bootstrap each label through the CANONICAL summarizer (`compute_method_rows`
# → `_summarize_trials`, the SAME BCa path the paper Sensitivity panels use) and
# return the canonical `summary` DataFrame. The x-axis column is `n` (= val size
# for validation_budget; = scale-corruption ζ for miscal — one row per (method, x)). This unifies
# A/B onto the identical statistic + schema.
# `operating_points` (path | auto-detected `operating_points.jld2` sibling | nothing)
# merges the tuned composed arms over their base-bundle rows.
function compute_summary(d; xgrid=nothing, operating_points=nothing)
    mode = d["mode"]; np_per = d["np_per"]; nval = d["nval"]
    proto = _proto(np_per, nval)
    budget = _budget(d)
    seed0 = budget.seed
    tk = operating_points === nothing ? nothing : load_tuning_artifact(String(operating_points))
    tk === nothing || tk["mode"] == mode ||
        error("operating-points sidecar mode $(tk["mode"]) ≠ bundle mode $mode")
    skip = tk === nothing ? String[] : collect(String, tk["arms"])
    present = [l for l in _bundle_labels(d) if haskey(d["M"], l) && l ∉ skip]
    # HARD GUARD (PROTOCOL.md §3 + invariants table): refined arms in figures
    # come from the operating-points sidecar, NEVER from bundle LO refits (retired
    # shared-knob CV).
    #  - sidecar present  ⇒ bundle LO arms silently excluded (selection only);
    #  - sidecar absent   ⇒ bundle LO arms are a hard ERROR: there is no
    #    protocol-compliant way to render refined arms without the sidecar.
    if tk === nothing
        bad = [l for l in present if occursin("+", l)]
        isempty(bad) || error("PROTOCOL VIOLATION: bundle carries shared-knob-CV LO arms " *
                              "$(bad) and no operating-points sidecar was given. Refined arms " *
                              "must come from the sequential CV (supply operating_points=<sidecar>).")
    else
        filter!(l -> !occursin("+", l), present)
    end
    rows = NamedTuple[]
    if mode == "validation_budget"
        xs = Int.(xgrid === nothing ? budget.sizes : xgrid)
        for label in present
            km = _windowed_method(label, d)
            s, _ = compute_method_rows(km, budget; protocol=proto, sizes=xs)
            append!(rows, s)                                  # rows already carry n + BCa stats
        end
        tk === nothing || append!(rows, _operating_points_rows(tk, mode, xs, seed0))
    elseif mode == "delta"
        # One bootstrapped point per Δ label at the full val pool (the Δ curve,
        # method="Δ sweep"), plus each Δ-independent baseline replicated across
        # the Δ axis as a flat anchor line.  `xgrid` is ignored — the Δ points
        # are baked into the bundle's labels.
        Δs = Float64.(d["deltas"])
        n_use = sum(np_per[1:nval])
        dlab(Δ) = "Δ=$(round(Δ; sigdigits=3)) sel"            # must match experiment_producer's label format
        for Δ in Δs
            haskey(d["M"], dlab(Δ)) || continue
            km = _windowed_method(dlab(Δ), d)
            s, _ = compute_method_rows(km, budget; protocol=proto, sizes=[n_use])
            push!(rows, merge(s[1], (; n=Δ, method="Δ sweep")))
        end
        for label in (l for l in present if !startswith(l, "Δ="))
            km = _windowed_method(label, d)
            s, _ = compute_method_rows(km, budget; protocol=proto, sizes=[n_use])
            append!(rows, [merge(s[1], (; n=Δ)) for Δ in Δs])  # flat anchor
        end
    else  # miscal — THE fixed-width protocol (see _fixed_width_rows)
        xs = Float64.(xgrid === nothing ? d["zetas"] : xgrid)
        for label in present
            append!(rows, _fixed_width_rows(label, d, xs, seed0))
        end
        tk === nothing || append!(rows, _operating_points_rows(tk, mode, xs, seed0))
    end
    return mode, DataFrame(rows)
end

# Per-label (x, mean_med, lo95, hi95) curves from the canonical summary DataFrame.
# Labels come from the DataFrame itself (classic five first, extras after), so
# delta bundles with "Δ sweep" curves work unchanged.
function _curves_from_summary(df)
    order = vcat([l for l in LO_LABELS if l in df.method],
                 [l for l in unique(df.method) if l ∉ LO_LABELS])
    curves = Dict{String,NamedTuple}()
    for label in order
        sub = sort(df[df.method .== label, :], :n)
        curves[label] = (x=Float64.(sub.n), y=Float64.(sub.mean_med),
                         lo=Float64.(sub.lo95_mean_med), hi=Float64.(sub.hi95_mean_med))
    end
    return curves, order
end

# Labels present in `curves`, classic-five order first (for the console table).
_present(curves) = vcat([l for l in LO_LABELS if haskey(curves, l)],
                        sort([l for l in keys(curves) if l ∉ LO_LABELS]))

# -----------------------------------------------------------------------------
# PGFPlots emission — fillbetween CI bands (mirrors the committed Sensitivity .tex).
# -----------------------------------------------------------------------------
# REUSES the package's `build_axis` (Render) — the SAME fillbetween emitter that makes the
# committed Sensitivity panels — so there is ONE renderer. The LO method styles +
# colours are PAPER_STYLE's rows and colours (palette.jl, figure_style.jl). Here we only supply the ζ/n x-label and wrap the axis in a standalone.

# Emit the imc panel (PANELS.eR_mean) from the canonical summary on disk via
# the package's load_results + build_axis: a group fragment (\begin{axis}…, paper-
# includable) + a self-contained standalone preview. Returns the group path.
# Display options come from `spec::PanelSpec` (spec.xlabel must be resolved by
# the caller — render_bundle substitutes the mode default); `panel_name` is an
# output-naming knob, not a display option, so it stays a kwarg.
function _write_lo_panels(out_dir, mode, summary_path, spec::PanelSpec;
                          panel_name::AbstractString = "panel_lo_$(mode)",
                          label_filter = nothing, stat::Symbol = :median)
    data = load_results(summary_path)
    # Optional roster restriction (e.g. the main-paper composed-miscal panel
    # renders from a base bundle that also carries scoring-only selector arms
    # belonging to fig:sel-miscal): keep only labels the predicate accepts.
    label_filter === nothing ||
        (data = Dict(l => v for (l, v) in data if label_filter(l)))
    # stat=:maa renders the mean-of-scene mAA@10° panel (PANELS.mAA_mean, read off the
    # SAME median-tuned deployed rows) — the symmetric companion to the median
    # panel. :median is the default eR_mean panel.
    base_panel = stat === :maa ? PANELS.mAA_mean : PANELS.eR_mean
    panel = (spec.ylog && stat !== :maa) ? (; base_panel..., log_y = true) : base_panel
    # The pair-level statistic is ALWAYS the median imc. The validation-budget sweep wraps it
    # in an expectation over VALIDATION DRAWS (tuning randomness) — the
    # subscript keeps it from reading as a pair-mean; the ζ sweeps evaluate the
    # full test pool per point, so the plotted value IS the pool median.
    ylab = stat === :maa ? raw"mAA@$10^\circ$" :
        mode == "validation_budget" ?
        raw"$\mathbb{E}_{\mathcal{V}}[\mathrm{med.}\,\max(\Delta \mathbf{R},\Delta \mathbf{t})]$" :
        raw"med.\ $\max(\Delta \mathbf{R},\Delta \mathbf{t})$"
    # House tick convention (matches the committed Fig-4/5 panels): log-basis-2
    # axis with fraction labels on the ζ sweep (1/64 … 64) and plain integers
    # on the n sweep — never raw decimals from pgf's default log labels.
    xs_data = sort(unique(Float64[r.n for sub in values(data) for r in eachrow(sub)]))
    if mode == "miscal"
        tickvals = [2.0^p for p in -6:2:6 if any(x -> isapprox(x, 2.0^p; rtol=1e-9), xs_data)]
        ticklabs = [p < 0 ? "\$1/$(2^(-p))\$" : "\$$(2^p)\$" for p in -6:2:6
                    if any(x -> isapprox(x, 2.0^p; rtol=1e-9), xs_data)]
    else
        tickvals = [n for n in (2, 8, 32, 128, 512, 2048) if Float64(n) in xs_data]
        ticklabs = ["\$$(Int(n))\$" for n in tickvals]
    end
    ax = build_axis(PAPER_STYLE, panel, data, "median",
                    PanelSpec(spec; legend = true,       # legend is always collected here
                              xtick = tickvals, xticklabels = ticklabs,
                              # mAA is a dimensionless fraction ∈[0,1] — suppress the
                              # degree-unit tick suffix used on the pose-error panels.
                              y_unit_degree = stat !== :maa,
                              tight_x = true);           # span the data exactly (n: 2…2048)
                    ylabel = ylab)                       # imc; R,t bold
    ax === nothing && error("no LO curves to plot in $summary_path")
    if spec.oracle_floor !== nothing && stat !== :maa
        # Oracle SELECTION floor: median over test pairs of the pool's best
        # model — a bound on scoring, not on the pipeline (refits may cross
        # it by leaving the discrete hypothesis pool).
        push!(ax, @pgf PGFPlotsX.Plot({color = "gray", dashed, thick, "forget plot" = nothing},
            PGFPlotsX.Coordinates([(xs_data[1], Float64(spec.oracle_floor)),
                                   (xs_data[end], Float64(spec.oracle_floor))])))
    end
    if stat === :maa
        ax["ymax"] = spec.ymax === nothing ? 1.0 : spec.ymax   # mAA ∈ [0,1]; a spec ymax trims the empty top (Fig 1b: 0.8)
        spec.ymin === nothing || (ax["ymin"] = spec.ymin)   # honor an explicit mAA floor (e.g. 0)
    else
        spec.ymin === nothing || (ax["ymin"] = spec.ymin)
        spec.ymax === nothing || (ax["ymax"] = spec.ymax)
    end
    group_path = joinpath(out_dir, "$(panel_name).tex")
    pgfsave(group_path, ax; include_preamble = false)   # fragment (host loads fillbetween)
    # Optional legend-suffix strip (e.g. " (no LO)" on scoring-only panels,
    # where the qualifier is uniform and therefore uninformative).
    spec.legend_strip === nothing ||
        write(group_path, replace(read(group_path, String), spec.legend_strip * "}" => "}"))
    # Roster-generic: the colour defs of EVERY colour of PAPER_STYLE (the one
    # emitter), so the standalone preview is self-contained for any roster.
    write_article_preview(out_dir, panel_name, paper_color_defs(PAPER_STYLE); legend_ref = spec.legend_name)
    return group_path
end

# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------
function render_bundle(bundle_path::AbstractString, spec::PanelSpec;
                       xgrid=nothing, operating_points=:auto, panel_name=nothing,
                       label_filter=nothing, stat::Symbol=:median)
    d = load_tuning_artifact(bundle_path)
    tkpath = operating_points === :auto ?
        (isfile(joinpath(dirname(bundle_path), "operating_points.jld2")) ?
         joinpath(dirname(bundle_path), "operating_points.jld2") : nothing) : operating_points
    mode, summary_df = compute_summary(d; xgrid, operating_points = tkpath)
    curves, label_order = _curves_from_summary(summary_df)
    out_dir = dirname(bundle_path)

    # Canonical `summary` schema (plot_val-compatible) + meta for a future
    # single dispatch-by-meta renderer. x_var says what `n` actually holds.
    expname = mode == "validation_budget" ? "LOSensitivity" : mode == "delta" ? "DeltaSweep" : "Miscalibration"
    x_var   = mode == "validation_budget" ? "n" : mode == "delta" ? "delta" : "zeta"
    x_label = spec.xlabel !== nothing ? String(spec.xlabel) :
              mode == "validation_budget"    ? "validation size \$n\$" :
              mode == "delta" ? "well depth \$\\Delta\$" : "scale corruption \$\\zeta\$"
    meta = Dict(
        "experiment" => expname,
        "x_var"   => x_var,
        "x_label" => x_label,
        "x_scale" => "log2", "metric" => "imc",
        "dataset" => "phototourism", "matcher" => "sift", "problem" => "E",
        "methods" => label_order,
        "n_draws" => _budget(d).n_draws, "tuning_hash" => d.hash)
    summary_path = joinpath(out_dir, "summary.jld2")
    JLD2.jldsave(summary_path; summary=summary_df, meta=meta)

    # ONE renderer: panels via the package's build_axis off the canonical summary.
    # The Δ curve has no row in PAPER_STYLE (it is a custom
    # paper figure) — for delta bundles the canonical summary + console table
    # are the deliverables and the PGF panel is skipped.
    group_path = mode == "delta" ? nothing :
        _write_lo_panels(out_dir, mode, summary_path,
                         PanelSpec(spec; xlabel = x_label);
                         panel_name = something(panel_name, "panel_lo_$(mode)"),
                         label_filter = label_filter, stat = stat)
    preview_path = joinpath(out_dir, "preview.tex")

    # Console table for quick eyeballing (point ± CI) — any number of curves.
    @printf("\n=== %s  (point=mean over trials, 95%% BCa) ===\n",
            mode == "validation_budget" ? "B: pose imc° vs n" :
            mode == "delta" ? "Δ-sweep: pose imc° vs Δ" : "A: pose imc° vs ζ")
    labs = _present(curves)
    xs = curves[labs[1]].x
    print(@sprintf("%9s", mode == "validation_budget" ? "n" : mode == "delta" ? "Δ" : "ζ")); foreach(l -> print(@sprintf(" | %-21s", l)), labs); println()
    for (i, x) in enumerate(xs)
        print(@sprintf("%9.4g", x))
        for l in labs
            c = curves[l]; print(@sprintf(" | %6.3f [%6.3f,%6.3f]", c.y[i], c.lo[i], c.hi[i]))
        end
        println()
    end

    # preview.tex + .pdf are written/compiled by write_article_preview inside
    # _write_lo_panels (article-class, texlive-core — no standalone.cls needed).
    @info "rendered" out_dir group=(group_path === nothing ? "(delta: no panel)" : basename(group_path)) preview="preview.pdf"
    return out_dir
end

if abspath(PROGRAM_FILE) == @__FILE__
    isempty(ARGS) && error("usage: plot_lo_sensitivity.jl <bundle.jld2> [--xgrid=a,b,c]")
    bundle = ARGS[1]
    xg = cli_option(ARGS, "xgrid", nothing)
    spec = PanelSpec(; height = raw"0.618\linewidth", width = raw"\linewidth",
        xlabel = cli_option(ARGS, "xlabel", nothing), legend_name = something(cli_option(ARGS, "legend-name", nothing), "lolegend"),
        ylog = cli_option(ARGS, "ylog", nothing) == "true",
        legend_cols = (lc = cli_option(ARGS, "legend-cols", nothing); lc === nothing ? nothing : parse(Int, lc)),
        legend_strip = cli_option(ARGS, "strip-legend", nothing),
        ymax = (ym = cli_option(ARGS, "ymax", nothing); ym === nothing ? nothing : parse(Float64, ym)))
    render_bundle(bundle, spec;
        xgrid = xg === nothing ? nothing : parse.(Float64, split(xg, ',')),
        panel_name = cli_option(ARGS, "panel-name", nothing))
end
