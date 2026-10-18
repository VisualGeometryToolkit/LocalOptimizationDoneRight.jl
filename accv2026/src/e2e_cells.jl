# =============================================================================
# e2e_cells.jl — END-TO-END RANSAC cells (configs/pt_e_e2e_table.toml): the
# deployed arms of an operating-points sidecar run through the production
# RANSAC loop (the evaluator's `live_runs`: Gaussian-SNN sampler over the
# record's stored Lowe ratios `pair.snn` at the pool generator's σ, adaptive
# termination, the arm's LO in the loop) on PT-E pool pairs. THE one live-run
# path of this project (`e2e_live`, scripts/e2e_ransac.jl), and THE table of
# its results beside SupeRANSAC's (`e2e_table_tex`; SupeRANSAC is the
# SupeRANSAC cell's, src/superansac.jl).
#
# An arm is deployed at its sidecar's operating point by its width kind:
#   ScaleMultiple()    — the deployed strategy itself (consensus-anchored k*·ŝ;
#                        ζ never touches it), scoring at ζ·a*;
#   OutlierHalfwidth() — the self-scaled arm (Stu-tU IRLS, BCD) refitting under
#                        the marginal at ITS tuned refit half-width ζ·w*
#                        (the evaluator's `RefitHalfwidth`, bitwise the bare
#                        arm at w = a);
#   anything else      — refused: a fixed loss width has no in-loop port here.
# The scale prior is the operating points' own (their scorer artifact's).
# =============================================================================
using VisualGeometryToolkitEval.Evaluation: build_pair_ctx, live_runs, live_row, RefitHalfwidth,
    audit_operating_points, deployed_budget_settings
using VisualGeometryToolkitEval.Pools: load_pool
using VisualGeometryToolkitCore: ScaleMultiple, OutlierHalfwidth, width_axis_name, IGPrior
using VisualGeometryToolkitCore.Pools: PoolPair
using VisualGeometryToolkitEstimation: EssentialProblem, RansacConfig, GaussianSampler
using RansacScoringDoneRight: StudentTUniformScoring
using Printf: Printf
using DrWatson: projectdir   # configs/ of the active (accv2026) project
using Statistics: mean, median

"The PT-E pool generator's Gaussian-SNN sampler σ (configs/pt_e_pools.toml [pool]): the live loop draws as the pool was drawn."
const PT_E_SNN_SIGMA = Float64(load_run_config(projectdir("configs", "pt_e_pools.toml"))["pool"]["gaussian_sigma"])

"""
    pt_live_problem(pair::PoolPair) -> EssentialProblem

The live-RANSAC problem of a PT-E pool pair: VisualGeometryToolkitEstimation's pool-frame
`EssentialProblem(pair)` (its sample gate's 0.1 px duplicate tolerance is in
pool units), sampled by the Gaussian-SNN sampler over the record's raw Lowe
ratios `pair.snn` (low = good) at the pool generator's σ — the pool's own
sampler, so the live loop draws from the distribution the pool was drawn
from. A record without SNN keeps the problem's uniform sampler.
"""
pt_live_problem(pair::PoolPair) =
    pair.snn === nothing ? EssentialProblem(pair) :
    EssentialProblem(pair; sampler = GaussianSampler(Float64.(pair.snn); snn_sigma = PT_E_SNN_SIGMA))

"The light PT-E pool of `scene` (VisualGeometryToolkitEval `load_pool`; its records carry the SNN)."
function pt_pool(scene::AbstractString, pool_dir::AbstractString)
    require_input(joinpath(pool_dir, "$scene.jld2"); what = "PT-E-SIFT-4K_pf3 pool ($scene)",
                  provenance = "configs/pt_e_pools.toml (generate_scoring_pools.jl)")
    return load_pool(joinpath(pool_dir, "$scene.jld2"))
end

# `sidecar_scale_prior` (the operating points' own prior) lives in cell_stages.jl:
# the budget cells consume it too.

"""
    e2e_ransac_config(cfg) -> RansacConfig

Our loop's termination of a folded e2e cell: `[e2e] ransac` {min_trials,
max_trials, success_prob}, absent: the production defaults.
"""
function e2e_ransac_config(cfg)
    r = get(cfg["e2e"], "ransac", nothing)
    return r === nothing ? RansacConfig() :
        RansacConfig(success_prob = Float64(r["success_prob"]), max_trials = Int(r["max_trials"]), min_trials = Int(r["min_trials"]))
end

"""
    e2e_deployment(sidecar, arms) -> (; dep, prior, scoring_at, lo_at)

The deployed arms of the operating-points `sidecar` as the live loop runs them:
`scoring_at(a, ζ)` the selection scorer and `lo_at(a, ζ)` the LO of arm `a` at
ζ (see the header: a ScaleMultiple arm is its deployed strategy, an
OutlierHalfwidth arm refits at ζ·w*). Gated: interior argmins only, and every
arm deployable end to end. THE one deployment of the accuracy run
([`e2e_live`](@ref)) and the timing repeat (src/e2e_timing.jl).
"""
function e2e_deployment(sidecar::AbstractString, arms)
    audit_operating_points(ROSTER, sidecar)   # gate: interior argmins only
    dep = Dict(deployed_budget_settings(ROSTER, sidecar))
    prior = sidecar_scale_prior(sidecar)
    for a in arms
        haskey(dep, a) || error("e2e: arm \"$a\" not in $sidecar")
        dep[a].kind isa Union{ScaleMultiple, OutlierHalfwidth} ||
            error("e2e: arm \"$a\" is $(dep[a].kind) — a fixed loss width has no in-loop port; not deployable end to end here")
    end
    template = StudentTUniformScoring(EssentialProblem, 1.0; prior)   # the refit marginal at the operating points' prior
    lo_at(a, ζ) = dep[a].kind isa ScaleMultiple ? dep[a].lo :
                  RefitHalfwidth(dep[a].lo, ζ * dep[a].ref, template)
    scoring_at(a, ζ) = StudentTUniformScoring(EssentialProblem, ζ * dep[a].sel; prior)
    return (; dep, prior, scoring_at, lo_at)
end

"""
    e2e_live(sidecar, arms, scenes, units_of; zetas, seed, stream, pool_dir) -> NamedTuple

Every `arm` of the operating-points `sidecar`, end to end on the pairs
`units_of(scene, n_pairs)` of every `scene`, at every ζ. Rows carry
`(arm, scene, zeta, live_row(...)...)`; `per_pair["arm|scene|ζ"]` the raw runs. Pair `i` of
`scene` draws from `stable_seed(seed, stream, scene, i)` (`[e2e] seed`, `stream`).
"""
function e2e_live(sidecar::AbstractString, arms, scenes, units_of; zetas, seed::Integer, stream::AbstractString,
                  pool_dir::AbstractString,
                  config::RansacConfig = RansacConfig())
    (; dep, prior, scoring_at, lo_at) = e2e_deployment(sidecar, arms)
    cfg = config
    rows = NamedTuple[]; per_pair = Dict{String,Any}(); units = Dict{String,Vector{Int}}()
    first_run = true
    for scene in scenes   # one scene's light pool at a time, every arm and ζ while hot
        pool = pt_pool(scene, pool_dir)
        idx = units[scene] = units_of(scene, length(pool))
        ctxs = [build_pair_ctx(EssentialProblem, pool.pairs[i]) for i in idx]
        pool = nothing; GC.gc()
        for a in arms, ζ in zetas
            runs = live_runs(scoring_at(a, ζ), lo_at(a, ζ), ctxs;
                             problem_of = pt_live_problem, config = cfg,
                             seed_of = j -> stable_seed(seed, stream, scene, idx[j]),
                             warmup = first_run)
            first_run = false
            push!(rows, (; arm = a, scene, zeta = ζ, live_row(runs)...))
            per_pair["$(a)|$(scene)|$(ζ)"] = runs
            @info "e2e" arm = a scene zeta = ζ med = round(rows[end].med, digits = 3) maa = round(rows[end].maa, digits = 3) pairs = length(idx)
        end
        ctxs = nothing; GC.gc()
    end
    ops = Dict(a => (; selection = dep[a].sel, refit = dep[a].ref, kind = String(width_axis_name(dep[a].kind)), lo = string(typeof(dep[a].lo)))
               for a in arms)
    return (; rows, per_pair, units, ops, prior = (prior.alpha0, prior.beta0),
            ransac_config = (success_prob = cfg.success_prob, max_trials = cfg.max_trials, min_trials = cfg.min_trials))
end

"The columns of an e2e cell's summary.tsv."
const E2E_SUMMARY_HEADER = join(["arm", "zeta", "median_deg", "maa10", "maa5", "med_trials", "med_wall_ms"], '\t')

"""
    e2e_summary_line(name, ζ, per; wall) -> String

One summary.tsv row: system `name` at `ζ`, the MEAN over the scenes of
`per` (one record per scene, with `err` [deg], `trials` and the wall times
`wall(r)` [s]) of each scene's finite median error, mAA@10° (VisualGeometryToolkitEval
`eligible_maa`, the threshold of record), mAA@5°, median trials and median
wall time [ms]. Ours and SupeRANSAC's rows are both this line.
"""
function e2e_summary_line(name, ζ, per; wall)
    m(f) = mean(f(r) for r in per)
    f3(x) = Printf.@sprintf("%.3f", x)
    return join([name, string(ζ), f3(m(r -> finite_median(r.err))),
                 f3(m(r -> eligible_maa(r.err; T = maa_threshold()))), f3(m(r -> eligible_maa(r.err; T = 5.0))),
                 string(round(Int, m(r -> median(r.trials)))), f3(m(r -> 1e3 * finite_median(wall(r))))], '\t')
end

"""
    e2e_table_tex(stat, arms, zetas; header) -> String

THE end-to-end table (main-paper Tab. 3): every system of `arms` — `(name,
label lines)`, ours first, SupeRANSAC last; a label's k-th line heads the
system's k-th statistic row, so "(Ours)" sits under our arm's name — × ζ, the
median error, mAA@10° and median wall time per column, the best system per
column in bold. `stat(name, ζ, column)` reads a summary.tsv value; `header`
is the provenance comment line.
"""
function e2e_table_tex(stat, arms, zetas; header::AbstractString)
    ztex(ζ) = ζ < 1 ? "\$1/$(round(Int, 1/ζ))\$" : "\$$(round(Int, ζ))\$"
    stats = [("median_deg", raw"error [$^\circ$]", "%.2f", <), ("maa10", raw"mAA@$10^\circ$", "%.3f", >),
             ("med_wall_ms", "time [ms]", "%.0f", <)]
    out = [header, "\\begin{tabular}{@{}ll" * "r"^length(zetas) * "@{}}", " \\toprule",
           " & \$\\zeta\$ & " * join(ztex.(zetas), " & ") * " \\\\", " \\midrule"]
    for (i, (arm, labels)) in enumerate(arms)
        i > 1 && push!(out, " \\midrule")
        for (j, (key, slabel, fmt, better)) in enumerate(stats)
            cells = String[]
            for ζ in zetas
                v = stat(arm, ζ, key)
                txt = Printf.format(Printf.Format(fmt), v)
                all(o -> better(v, stat(o, ζ, key)), [a for (a, _) in arms if a != arm]) &&
                    (txt = "\\textbf{" * txt * "}")
                push!(cells, txt)
            end
            push!(out, " " * get(labels, j, "") * " & " * slabel * " & " * join(cells, " & ") * " \\\\")
        end
    end
    push!(out, " \\bottomrule", "\\end{tabular}")
    return join(out, "\n") * "\n"
end
