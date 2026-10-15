#!/usr/bin/env julia
# =============================================================================
# run_polish.jl — DRIVER: does a final polish move a locally optimized result?
# (configs/polish_pt_e.toml; launched by scripts/polish.jl.)
#
# Per test pair of the operating points' own cross-validation:
#   seed  = the IG-selected pool model at the deployed a* (`best_pool_model`)
#   E_LO  = each source arm's refit of the seed at its deployed width
#           (`refit_model` — the refit layer's native refit, model kept); its
#           error must equal the sidecar's ζ = 1 evaluation, pair for pair
#   polishers on E_LO ([polish] polishers):
#     l2_stutu  PoseLib least squares (GaussianShape = TrivialLoss) on the
#               Stu-tU partition I* at E_LO under the scorer at a* — the
#               pipeline's own inlier set (the RANSAC workspace's score sweep:
#               `_score_and_sweep!` → ws.mask); no threshold, no parameter
#     tls       (optional) the deployed TLS-IRLS arm's refiner (PoseLib
#               truncated LM) at that arm's own cross-validated loss width
#   a polish that bails (or returns a non-finite error) keeps E_LO.
# The displacement of a polish is max(rotation angle, translation-direction
# angle) between the E_LO pose (cheirality-resolved) and the polished pose.
#
#   julia -t auto --project=. scripts/tools/run_polish.jl --outdir=<dir> [--config=polish_pt_e] [--smoke]
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2, Statistics, Printf, Dates, TOML, LinearAlgebra
include(srcdir("cell_stages.jl"))
include(srcdir("e2e_cells.jl"))      # sidecar_scale_prior
using VisualGeometryEval.Pools: load_pool, load_pool_residuals, residuals_path, residual_matrix
using VisualGeometryEval.Evaluation: build_pair_ctx, refit_model, refit_seed, model_imc,
    essential_bearings, deployed_budget_settings
using LocalOptimizationDoneRight: truncated_refit_pose, PoseLibLm
using RobustVisualGeometry: EssentialProblem, RansacWorkspace
using RansacScoringDoneRight: StudentTUniformScoring
using VisualGeometryCore: EssentialMat, EuclideanMap, Vec3, cheiral_pose_fast, GaussianShape, best_pool_model,
    score_model!, consensus_mask, external_workspace
using PoseLib: refine_relpose
start_output_flush!()

const CFG_NAME = cli_option(ARGS, "config", "polish_pt_e")
const OUTDIR   = cli_option(ARGS, "outdir")
const SMOKE    = "--smoke" in ARGS        # one scene, its first 10 pairs (a code check, never a result)
const CFG      = load_run_config(projectdir("configs", CFG_NAME * ".toml"))
const PC       = CFG["polish"]
const POOL     = joinpath(data_root(), CFG["experiment"]["pool_dir"])
const SIDECAR  = miscal_sidecar_of(String(CFG["operating_points"]["miscal_config"]))
const SOURCES  = String.(PC["sources"])
const POLISHERS = Symbol.(PC["polishers"])
all(p -> p in (:tls, :l2_stutu), POLISHERS) || error("[polish] polishers: l2_stutu | tls")
const MAX_ITER = Int(PC["max_iter"])
const DEP      = Dict(deployed_budget_settings(ROSTER, SIDECAR))
const PRIOR    = sidecar_scale_prior(SIDECAR)
const A_STAR   = let a = unique(DEP[s].sel for s in SOURCES)
    length(a) == 1 || error("polish: the sources were deployed at different selection widths $a")
    only(a)
end
# The (optional) TLS polish width: the deployed TLS-IRLS arm's own
# cross-validated loss width (pool frame, absolute; what its refit consumes).
const TLS_WIDTH = :tls in POLISHERS ? Float64(DEP[String(PC["tls_arm"])].ref) : NaN
const TLS_LO    = PoseLibLm(MAX_ITER)
const CV        = sidecar_cross_validation(SIDECAR)

const BAILS = Threads.Atomic{Int}(0)       # polishes that threw (E_LO kept)
_angle(R1, R2) = rad2deg(acos(clamp((tr(R1' * R2) - 1) / 2, -1.0, 1.0)))
_tangle(t1, t2) = rad2deg(acos(clamp(dot(t1, t2) / (norm(t1) * norm(t2)), -1.0, 1.0)))

# One pair: every source's E_LO, then every polisher on it → (err_LO, [(err, disp) per polisher]).
function pair_rows(pair, R)
    ctx = build_pair_ctx(EssentialProblem, pair; scoring = StudentTUniformScoring(EssentialProblem, 1.0; prior = PRIOR))
    sc_sel = StudentTUniformScoring(EssentialProblem, A_STAR; prior = PRIOR)
    tls_ws = external_workspace(TLS_LO, ctx.ep, ctx.geom, ctx.scoring)   # PoseLib's pool-frame inputs (the two-view frame: Kc1, Kc2, cs)
    # the pool stores pool-frame F hypotheses; the refit seed is the evaluation's
    # decode of the selected one (`refit_seed`: EssentialMat(F, Kc1, Kc2))
    seed = refit_seed(ctx, pair.models[best_pool_model(sc_sel, pair, R)])
    g = ctx.geom; f₁, f₂ = essential_bearings(ctx)
    map(SOURCES) do a
        d = DEP[a]
        E = try refit_model(ctx.ep, seed, d.lo, StudentTUniformScoring(EssentialProblem, d.ref; prior = PRIOR)) catch; nothing end
        E === nothing && return (NaN, [(NaN, NaN) for _ in POLISHERS])
        err_LO = Float64(model_imc(E, ctx))
        Rs, ts = cheiral_pose_fast(E, f₁, f₂)                       # static: what EuclideanMap takes
        R0 = Matrix(Rs); t0 = Vector(ts)                            # dense copies for the angle checks
        ws = RansacWorkspace(ctx.ep, sc_sel)
        score_model!(ws.buf, sc_sel, ctx.ep, E)        # the consensus mask of E under the selection
        stutu = copy(consensus_mask(ws.buf))
        pol = map(POLISHERS) do p
            ref = try
                p === :tls ? truncated_refit_pose(TLS_LO, tls_ws, ctx.ep, E, TLS_WIDTH) :
                    (count(stutu) >= 8 ? refine_relpose(EuclideanMap(Rs, Vec3{Float64}(ts)), g.Kc1, g.Kc2, g.cs[stutu];
                                                        max_iter = MAX_ITER, loss = GaussianShape()) : nothing)
            catch e
                BAILS[] += 1
                BAILS[] <= 3 && @warn "polish bailed (E_LO kept)" polisher = p exception = sprint(showerror, e)[1:min(end, 300)]
                nothing
            end
            ref === nothing && return (err_LO, 0.0)
            err = Float64(model_imc(EssentialMat(ref.R, ref.t), ctx))
            isfinite(err) || return (err_LO, 0.0)
            (err, max(_angle(R0, Matrix(ref.R)), _tangle(t0, Vector(ref.t))))
        end
        (err_LO, pol)
    end
end

mkpath(OUTDIR)
scenes = SMOKE ? test_scenes(CV)[1:1] : test_scenes(CV)
rows = Dict{String,Vector}()
for s in scenes
    path = joinpath(POOL, "$(s).jld2")
    pool = load_pool(path)
    ii = only(values(sample_units(CV.test, Dict(s => collect(1:length(pool))))))
    SMOKE && (ii = first(ii, 10))
    res = load_pool_residuals(residuals_path(path), pool; pairs = ii)
    v = Vector{Any}(undef, length(ii))
    Threads.@threads :greedy for j in eachindex(ii)
        v[j] = pair_rows(pool.pairs[ii[j]], residual_matrix(res, ii[j]))
    end
    rows[s] = v
    pool = res = nothing; GC.gc()
    @info "polish" scene = s pairs = length(ii)
end

# Assemble per (source, condition), and the consistency gate: E_LO is the model
# the sidecar reports at ζ = 1 (its rows: the test scenes in order, every pair).
sd = load_tuning_artifact(SIDECAR); j1 = argmin(abs.(log2.(sd["zetas"])))
err = Dict{String,Vector{Float64}}(); disp = Dict{String,Vector{Float64}}(); maxdiff = Dict{String,Float64}()
for (i, a) in enumerate(SOURCES)
    lo = reduce(vcat, [[r[i][1] for r in rows[s]] for s in scenes])
    ref = Float64.(sd["evaluation"][a][:, j1])[1:length(lo)]
    maxdiff[a] = maximum(abs.(replace(lo .- ref, NaN => 0.0)))
    err["$(a)|none"] = lo
    for (k, p) in enumerate(POLISHERS)
        err["$(a)|$(p)"] = reduce(vcat, [[r[i][2][k][1] for r in rows[s]] for s in scenes])
        disp["$(a)|$(p)"] = reduce(vcat, [[r[i][2][k][2] for r in rows[s]] for s in scenes])
    end
    @info "E_LO vs the sidecar's ζ = 1 evaluation" source = a max_abs_diff = maxdiff[a]
end
let total = sum(length(rows[s]) for s in scenes) * length(SOURCES) * length(POLISHERS)
    @info "polish bails" bails = BAILS[] of = total
    BAILS[] < 0.5 * total || error("polish: $(BAILS[]) of $total polishes threw — a broken polish, not a result (see the warnings)")
end
maximum(values(maxdiff)) < 1e-6 ||
    @warn "polish: E_LO errors differ from the sidecar's ζ = 1 evaluation — the polish input is NOT the reported model" maxdiff
jldsave(joinpath(OUTDIR, "polish_test.jld2"); err, disp, maxdiff_vs_sidecar = maxdiff,
        scenes, np = [length(rows[s]) for s in scenes], sources = SOURCES, polishers = String.(POLISHERS),
        a_star = A_STAR, tls_width = TLS_WIDTH, sidecar = SIDECAR, created = string(Dates.now()))
@info "polish done" OUTDIR
