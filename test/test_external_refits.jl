# R22: contract test — the external-refit contract (`external_workspace`, `prepare_external!`, `external_refit!`) of this package's BackendRefit(AdaptiveLossWidthRefit())
# =============================================================================
# The external refiners (VisualGeometryToolkitCore's `ExternalRefit` family): PoseLib's
# truncated refiners as Core's `BackendRefit` of `LevenbergMarquardt(PoseLibSolver();
# optimization_strategy)` (their identity), and this package's consensus-anchored
# truncated refit `AdaptiveLossWidthRefit` (src/adaptive_refit.jl): its identity, the
# refine on a `RelativePoseRefitProblem`, its external refit, the within-width scale
# moment, and the configuration converter of its defaults. Their integration with the
# composition evaluator (VisualGeometryToolkitEval.Evaluation) and the paper's scorer
# is accv2026/test/test_engine_integration.jl.
# =============================================================================
using Test
using LinearAlgebra: I
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LocalOptimizationDoneRight as LODR, AdaptiveLossWidthRefit, RelativePoseRefitProblem,
    LODR_CONFIG_VERSIONS
import PoseLib
using PoseLib: LeZach
import VisualGeometryToolkitCore
using VisualGeometryToolkitCore: AbstractOptimizationStrategy, RefitFamily, ExternalRefit, FixedScale, ConsensusAnchored,
    LossWidth, FixedS2, scale_interface, optimization_path, lo_label, lo_marker, loss_family, external_workspace,
    external_refit!, prepare_external!, Correspondences, CameraModel, EssentialMat, EuclideanMap, RefineProblem, RefineKind,
    estimator_kind, solve, BackendRefit, OptimizationPath, found_model, LevenbergMarquardt, PoseLibSolver, LmStops, Irls, TLSShape, cheiral_pose_fast,
    migrate_config, current_config_version, StudentTUniformScoring, JeffreysPrior, FlatLabelPrior
using VisualGeometryToolkitEstimation: EssentialProblem, RelativePoseProblem
using StaticArrays: SMatrix
using Random: Xoshiro
# the seeded E scene of the stack's LO benches (`essential_bench_scene`, VisualGeometryToolkitCore's)
include(joinpath(pkgdir(VisualGeometryToolkitCore), "test", "lo_timing", "bench_record.jl"))


@testset "external refiners: identity" begin
    # PoseLib's truncated refiners are Core's BackendRefit; it reports its LM strategy's identity
    lm = BackendRefit(LevenbergMarquardt(PoseLibSolver(); optimization_strategy = Irls{TLSShape}()), LmStops(; max_iter = 25))
    lz = BackendRefit(LevenbergMarquardt(PoseLibSolver(); optimization_strategy = LeZach()), LmStops(; max_iter = 25))
    @test RefitFamily(lm) isa ExternalRefit && RefitFamily(lz) isa ExternalRefit
    @test optimization_path(lm) === OptimizationPath.irls && optimization_path(lz) === OptimizationPath.gnc
    @test lo_label(lm) == "TLS-IRLS" && lo_label(lz) == "TLS-LZ"
    @test loss_family(lm) === :tls && loss_family(lz) === :tls
    @test scale_interface(lm) isa FixedScale && scale_interface(lz) isa FixedScale
    # the adaptive arm: this package's refine algorithm, its BackendRefit an external refiner
    alg = AdaptiveLossWidthRefit()
    @test estimator_kind(alg) isa RefineKind && alg.lm === LevenbergMarquardt(PoseLibSolver(); optimization_strategy = Irls{TLSShape}())
    ad = BackendRefit(alg, LmStops(; max_iter = 25))
    @test ad isa AbstractOptimizationStrategy && RefitFamily(ad) isa ExternalRefit
    @test scale_interface(ad) isa ConsensusAnchored && optimization_path(ad) === OptimizationPath.irls && loss_family(ad) === :tls
    @test lo_label(ad) == raw"TLS-IRLS-$\hat s$" && lo_marker(ad) === Symbol("square*")
    @test (alg.rounds, alg.min_support, alg.cheirality_vote_points, alg.efficiency_constant) === (5, 8, 256, 2.5)
    @test_throws ArgumentError AdaptiveLossWidthRefit(; rounds = 0)
    @test_throws ArgumentError AdaptiveLossWidthRefit(; cheirality_vote_points = 0)
end

@testset "truncated-moment scale plug-in" begin
    tm = LODR._truncated_moment_s2
    r = [1.0, -1.0, 1.5, 0.5, 2.0, 1.0, 0.5, 1.0]
    @test tm(2.0, r, 8) ≈ 10.75 / 8                    # |r| ≤ loss width INCLUSIVE
    @test tm(1.0, vcat(r, fill(50.0, 3)), 4) ≈ (1.0 + 1.0 + 0.25 + 1.0 + 0.25 + 1.0) / 6
    @test tm(2.0, r[1:7], 8) === nothing               # thin consensus, the default min_support = 8
    @test tm(0.75, r, 8) === nothing
    @test tm(2.0, r[1:7], 7) ≈ (10.75 - 1.0) / 7
    @test tm(1.0, zeros(8), 8) === eps()               # VGC's Jeffreys scale estimator: floored at eps, never 0
end

@testset "the adaptive refit's width is VGC's TLS deployment" begin
    lw = LODR._adapt_loss_width
    for m in (2.5, 1.0, 3.7), s2 in (0.0, 1.0e-6, 0.37, 4.0)
        @test lw(AdaptiveLossWidthRefit(; efficiency_constant = m), s2) === m * sqrt(max(s2, eps()))
    end
end

# The refine on its problem, and the external refit of its BackendRefit: one body (the cache's solve!), from the seed's
# cheirality-resolved pose (Core's `cheiral_pose_fast` vote, the caller's step).
@testset "AdaptiveLossWidthRefit: the refine and its external refit" begin
    sc = essential_bench_scene(Xoshiro(20261125); n = 300)
    cs = Correspondences(sc.u₁, sc.u₂)
    K = SMatrix{3, 3, Float64, 9}(sc.K)
    problem = EssentialProblem(CameraModel(sc.K), CameraModel(sc.K), cs)
    frame = (; Kc1 = K, Kc2 = K, cs)
    seed = EssentialMat(sc.R, sc.t)
    alg = AdaptiveLossWidthRefit()
    f = RelativePoseRefitProblem(RelativePoseProblem(K, K, cs), problem)
    pose = cheiral_pose_fast(seed, problem.cs; vote_points = alg.cheirality_vote_points)
    stops = LmStops(; max_iter = 25)
    r = solve(RefineProblem(f, pose), alg; stops, scale = FixedS2(1.0))
    @test r.u isa EuclideanMap && r.alg === alg && r.prob.f === f && r.metadata.rounds >= 1
    @test maximum(abs, r.u.R - sc.R) < 1.0e-2                  # 0.5 px noise, 30 % outliers truncated
    lo = BackendRefit(alg, stops)
    scoring = StudentTUniformScoring(problem, 3.0; scale_prior = JeffreysPrior(), label_prior = FlatLabelPrior())
    ws = external_workspace(lo, problem, frame, scoring)
    @test prepare_external!(ws, lo, problem, seed, FixedS2(1.0), scoring)
    # the external refit's record (Core's contract: a FitResult), its model the refine's essential, its record the refine's
    re = external_refit!(ws, lo, problem, seed, LossWidth(3.0), scoring)
    @test re.u === EssentialMat(r.u.R, r.u.t) && found_model(re)
    @test (re.retcode, re.stop_rule, re.stats.nsteps, re.metadata) === (r.retcode, r.stop_rule, r.stats.nsteps, r.metadata)
    @test prepare_external!(ws, lo, problem, seed, LossWidth(3.0), scoring) && ws.s2₀ > 0   # the consensus bootstrap
    @test_throws ArgumentError solve(RefineProblem(f, pose, (; K1 = K)), alg; stops, scale = FixedS2(1.0))   # no context
    @test_throws ArgumentError external_workspace(lo, nothing, frame, scoring)                             # E only
end

# Decision 11: the version-1 tables of the deleted PoseLib arms, and version 2's Bool `adapt_scale`, are converter
# steps, never a refusal.
@testset "configuration converter" begin
    @test current_config_version(LODR_CONFIG_VERSIONS) == 3
    # as TOML parses a version-1 file: tables of Any
    t(ps...) = Dict{String, Any}(ps...)
    v1 = t("optimization_strategy" => t("poselib" => t("cheirality_vote_points" => 128),
                                        "poselib_adapt" => t("max_iter" => 30, "rounds" => 3, "min_support" => 6,
                                                             "operating_efficiency_constant" => 2.0),
                                        "hq" => t("max_iter" => 25)))
    m = migrate_config(v1, LODR_CONFIG_VERSIONS)
    @test m["adaptive_loss_width_refit"] == Dict("rounds" => 3, "min_support" => 6, "operating_efficiency_constant" => 2.0,
                                                 "cheirality_vote_points" => 128, "stops" => Dict("max_iter" => 30))
    @test m["optimization_strategy"] == Dict("hq" => Dict("max_iter" => 25)) && m["config_version"] == 3
    @test_throws r"adaptive_loss_width_refit" migrate_config(t("config_version" => 3,
        "optimization_strategy" => t("poselib_adapt" => t("rounds" => 3))), LODR_CONFIG_VERSIONS)
    # version 2 → 3 (L10): StuTuRegemm's Bool `adapt_scale` becomes its `scale_interface` tag (Core's `values` step)
    for (b, tag) in ((true, "self_scaling"), (false, "consensus_anchored"))
        v2 = t("config_version" => 2, "optimization_strategy" => t("stu_tu_regemm" => t("max_iter" => 100, "adapt_scale" => b)))
        m = migrate_config(v2, LODR_CONFIG_VERSIONS)
        @test m["optimization_strategy"]["stu_tu_regemm"] == Dict("max_iter" => 100, "scale_interface" => tag) &&
            m["config_version"] == 3
    end
    @test_throws r"adapt_scale.*Bool" migrate_config(t("config_version" => 2,
        "optimization_strategy" => t("stu_tu_regemm" => t("adapt_scale" => "yes"))), LODR_CONFIG_VERSIONS)
    # the old form in a current file is refused, naming its version
    @test_throws r"adapt_scale.*version 2" migrate_config(t("config_version" => 3,
        "optimization_strategy" => t("stu_tu_regemm" => t("adapt_scale" => true))), LODR_CONFIG_VERSIONS)
end
