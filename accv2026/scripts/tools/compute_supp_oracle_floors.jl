#!/usr/bin/env julia
# =============================================================================
# compute_supp_oracle_floors.jl — oracle SELECTION bounds for the supplement
# model-class cells (PT-F, HEB-H), merged into oracle_floors.jld2.
#
# THE oracle-floor writer of every cell (PT_E via fig3_composed_miscal.jl too; PROTOCOL §8): median over TEST
# pairs of the pool-best model error (floor) + mean pool-best mAA@10°
# (ceiling); ζ-independent; bounds SELECTION only. The metric is the
# problem-family `model_imc` — the SAME conversion the tuning's ζ evaluation scores
# refits with (F: Kc pose upgrade; H: Malis–Vargas optimistic decomposition),
# so the bound and the curves share one metric by construction.
#
# Codified: invoked by supp_{F,H}_miscal.jl stage :oracle via run_driver.
#   --tag=PT_F --problem=F --pool-dir=DIR --scenes=a,b,c
# The tag MUST end in the model-class letter (_F/_H): render_miscal_faceted.jl
# derives the legend's model-class letter from it.
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
include(srcdir("config.jl"))
include(srcdir("common.jl"))   # write_oracle_floor! (THE floors writer)
start_output_flush!()          # per-scene progress reaches the Slurm log

const TAG      = cli_option(ARGS, "tag", "")
const PROBLEM  = Symbol(uppercase(cli_option(ARGS, "problem", "")))
const POOL_DIR = cli_option(ARGS, "pool-dir", "")
const SCENES   = String.(split(cli_option(ARGS, "scenes", ""), ','; keepempty = false))
isempty(TAG) && error("--tag required (oracle_floors.jld2 key, e.g. PT_F)")
PROBLEM in (:E, :F, :H) || error("--problem must be E | F | H")
(isempty(POOL_DIR) || isempty(SCENES)) && error("--pool-dir and --scenes required")
endswith(TAG, "_" * String(PROBLEM)) ||
    error("--tag must end in _$(PROBLEM) — the panel legend letter is derived from it")

const PTy = problem_type(PROBLEM)
@info "supp oracle floor" TAG PROBLEM pool_dir = POOL_DIR nscenes = length(SCENES)

# Per-pair pool-best model error (min over pool models). Every stored pool pair
# is processable, so under THE mAA rule a pair whose pool holds no finite model
# counts as a failure (Inf), never drops out.
# The pool-best error of one pair: every pool model scored against the GT.
# refit_seed: pool models are pool-frame F/H containers taken verbatim for the
# F/H families but need the metric upgrade to EssentialMat for E.
pool_best(p) = (ctx = build_pair_ctx(PTy, p);
                minimum(m -> (e = model_imc(refit_seed(ctx, m), ctx); isfinite(e) ? e : Inf), p.models; init = Inf))
# Pairs are independent: threaded across the job's threads (`:greedy` — a
# pair's cost scales with its pool size). Until 2026-10-04 this was one core
# for the whole test side (~24k PT-E pairs × thousands of models each).
vals = Float64[]
for sc in SCENES
    t0 = time()
    pairs = scene_loaders(POOL_DIR, [sc])[1]().pairs   # the light records: no residuals needed
    v = Vector{Float64}(undef, length(pairs))
    Threads.@threads :greedy for i in eachindex(pairs)
        v[i] = pool_best(pairs[i])
    end
    append!(vals, v)
    @info "scene done" scene = sc pairs = length(v) secs = round(Int, time() - t0)
    pairs = nothing; GC.gc()
end
any(isfinite, vals) || error("no finite pool-best errors — wrong --pool-dir or --scenes?")
floor_v  = round(median(vals), digits = 3)     # Inf (no model) sorts last: a failure, not a gap
ceil_maa = round(eligible_maa(vals), digits = 3)
@info "oracle" TAG floor = floor_v maa_ceiling = ceil_maa npairs = length(vals) pair_outcomes(vals)...

path = write_oracle_floor!(oracle_floors_path(), TAG, floor_v, ceil_maa;
                           source = oracle_floor_source(POOL_DIR, PROBLEM, SCENES),
                           npairs = length(vals), driver = "compute_supp_oracle_floors.jl")
@info "floor written" path TAG floor_v ceil_maa
