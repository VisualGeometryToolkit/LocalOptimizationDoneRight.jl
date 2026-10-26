# =============================================================================
# test_lift_losses.jl — loss-parameterized half-quadratic lift (AbstractLossShape).
# Gates (the Geman–Reynolds duality, the z-block closed forms and the
# half-weight depth are VisualGeometryToolkitCore's shape math, and are tested there
# only — its test/loss_shape_math_tests.jl):
#   1. Lift regression — every lift arm stays within 1e-6 of its pre-refactor output on a
#      fixed synthetic problem (hex captured at 7af4ae4; the offline capture
#      diff at refactor time was bit-exact under the capture config — under
#      Pkg.test's --check-bounds=yes the trajectories drift at the ~1e-12
#      level, so the cross-config pin is tolerance-based).
#   2. Loss-arm smoke — each HQ{K} loss executes on E (and F) and
#      improves a perturbed seed at a suitable standardized depth.
#   3. Every registered LO strategy RUNS end to end (and a loss a mechanism
#      cannot run is refused at load).
#   4. BarronHQ α-dial anchor gates.
# =============================================================================
# (Moved from VisualGeometryToolkitEstimation's test/lift_losses_tests.jl with the strategies it tests.)
import VisualGeometryToolkitCore as VgtkCore
import VisualGeometryToolkitEstimation as VgtkEstimation
using Test, Random, LinearAlgebra, StaticArrays, StructArrays
using Rotations: RotY
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: Synthetic
using VisualGeometryToolkitCore.Synthetic: projective_distance
using VisualGeometryToolkitCore: estimate, retcode   # VGC accessors (public)
using RANSACScoringDoneRight: StudentTUniformScoring   # owned and exported by RANSACScoringDoneRight
using VisualGeometryToolkitEstimation: LOSS_TAGS, config_dict, local_optimization_from_toml   # public, not exported
using VisualGeometryToolkitEstimation
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: WelschHQEcm, WelschHQNewton
const LO = LocalOptimizationDoneRight
# The merged strategy registry: the core's tags and this package's.
const TAGS = merge(VgtkEstimation.LO_TAGS, LocalOptimizationDoneRight.LO_TAGS)
# NOT exported: under the old serial suite this was visible because an earlier
# `include` had imported it into the shared namespace. Items get their own
# module, so it must be named here.
using VisualGeometryToolkitEstimation: RansacWorkspace

# THIS TESTSET STAYS IN THE CALIBRATED DOMAIN, deliberately: its problems are
# stated on the identity camera (`IDCAM`, Cameras), whose "pixels" are
# calibrated units. Do not "fix" it
# into the pixel domain — the reason is measured, not stylistic:
#
# These arms pin the LO LOSS's behaviour, and its `scale_multiple` is only
# observable here. In the calibrated regime the 1.5 / 1.0 / 2.5 arms differ in
# the third hex digit of their pinned models — ~1e-3 relative, small but real.
# In the pixel regime the scale multiple is INERT: swept across 32x (0.25x to 8x the inlier
# residual scale) every output is BIT-IDENTICAL. Porting this testset to pixels
# therefore deletes the only sensitivity it exists to measure, silently.
#
# The coarse gate that an identity camera implies costs nothing here, and that
# was checked rather than assumed: these arms call `locally_optimize` DIRECTLY,
# with no `ransac` and no sampling, so `test_sample` is never invoked.
cal_problem(a, b) = essential_problem(IDCAM, a, b)


const RVGK = VisualGeometryToolkitEstimation
# From its OWNER: RVG no longer imports `signed_sampson_distance` — E's
# scoring moved to the tangent Sampson and was its last user there, so the
# quality gate refuses it as a stale explicit import. F still uses it.
using VisualGeometryToolkitCore: signed_sampson_distance
include("scenes.jl")   # the shared scenes, as modules
using .EpipolarScenes, .Cameras

# -----------------------------------------------------------------------------
# Fixed synthetic essential scene shared by the regression + smoke gates.
# -----------------------------------------------------------------------------
function _lift_regression_scene()
    R = RotY(0.3); t = normalize(SA[0.7, -0.2, 0.4])
    u₁, u₂ = calibrated_pairs(MersenneTwister(42), R, t; n = 120, σ = 0.002, outlier_every = 5)   # ~20% gross outliers
    return u₁, u₂, perturbed_essential(R, t, 0.15, SA[0.12, -0.1, 0.06])
end

_hex9(M) = join(
    [
        string(reinterpret(UInt64, x), base = 16)
            for x in Tuple(SMatrix{3, 3, Float64, 9}(M))
    ], ","
)

_unhex9(s) = SMatrix{3, 3, Float64, 9}(
    Tuple(
        reinterpret(
            Float64,
            [parse(UInt64, h; base = 16) for h in split(s, ",")]
        )
    )
)

# Pre-refactor outputs of every lift arm on the scene above (captured at
# 7af4ae4, BEFORE the loss-shape refactor; Julia 1.12.6, x86-64,
# default check-bounds). Regenerate by printing `_hex9(estimate(r))` per arm.
#
# WHAT MAY LEGITIMATELY MOVE THESE, AND WHAT MAY NOT. A bit-exact pin on a
# converged LO output is brittle by construction, and that brittleness is the
# point — it is what surfaced a 10% residual tail nobody had measured. But it
# means a broken pin arrives with a plausible story attached, so the rule is:
#
#   * A change of RESIDUAL DEFINITION may move them, and its magnitude must be
#     measured and recorded. These values were regenerated on 2026-09-23 when
#     E moved from the image-plane Sampson to the tangent Sampson whitened by
#     the back-projection Jacobians. Those two are FIRST-ORDER EQUIVALENT ONLY.
#     Measured on this scene through the real construction path (`ecs`), the
#     per-point |Δresidual| is median 2.0e-5, q95 0.0150, max 0.0356 AT THE
#     SEED, and median 3.0e-7, q95 0.0154, max 0.0475 AT THE CONVERGED `welsch`
#     MODEL. It is the tail, not the median, that a 25-iteration LO with 20%
#     gross outliers amplifies into model differences of 1.9e-5 to 8.7e-2
#     (per arm, min gm_sent 1.9e-5, max ecm 8.7e-2). All nine exceed the 1e-6
#     gate below, which is why all nine moved together and none was excused.
#
#     DIFF THE PIN AGAINST HEAD, NOT AGAINST THE WORKING TREE. That range was
#     first recorded as 0.23-0.71, taken by diffing the new values against the
#     ones sitting in the working tree — which were themselves a regeneration
#     made while the LM/scoring mismatch was still live. So it measured the
#     magnitude of THAT defect, not of the residual change it was captioning,
#     and overstated it by an order of magnitude. A stale working tree is the
#     likelier baseline to reach for and the wrong one; HEAD is the last state
#     the suite was green in, which is what "how far did this move it" means.
#
#     ALWAYS NAME THE EVALUATION POINT when recording these. The previous
#     revision of this note claimed median 0.00114, q95 0.0494, max 0.104 with
#     no model named, and none of the three reproduces at either point above.
#     They were measured while `_canonicalize_pairs` was still truncating
#     bearings to 2-vectors and dropping the M attribute columns — i.e. taken
#     through the very defect the note was describing as repaired. A number
#     measured mid-repair reads exactly like a number measured after it.
#
#   * A change of SCALE or UNIT may NOT move them — proven inert here, not
#     assumed: scaling the outlier half-width and the loss width together
#     left every arm bit-identical. If a scale change moves a pin, something
#     else moved with it.
#
# A moved pin is a QUESTION, never a thing to re-record. The pressure to
# regenerate is highest exactly when the change is large and an explanation is
# handy — and here the handy explanation ("trajectory change from the new
# gate") was PARTLY TRUE, which is what made it dangerous. What settled it was
# measuring a quantity whose value could be predicted independently rather than
# assessing whether the story was plausible.
# The four Welsch-family arms (welsch, welsch_k1, welsch_k25, ecm) were
# re-recorded 2026-09-30 for VGC 09277bd, which changed the Welsch z-block's
# hreg near and at w̄ = 1 (0 → its limit 2c²). Measured against the previous
# pins at HEAD 9c735a4: _dmodel 0.079 (welsch), 0.135 (welsch_k1), 0.0088
# (welsch_k25), 0.078 (ecm); every non-Welsch arm stayed within 1.7e-8 (gm),
# 5e-10 or less for the rest — the change is confined to the shape it touched.
const _LIFT_REGRESSION = Dict(
    "welsch" => "3fb378b1a883c0ed,3fe3775649c89ef7,3fd24b0aa4e2ce05,bfd8e89e24db06b7,3f9122763bfca8dc,3febc01d34d8a23e,bfd2d14409ce33a0,bfe7934143cd88c6,3fb8e5c9271ddbb2",
    "welsch_1x" => "3fb2f43548d12bf4,3fe6f6e6389dece4,3fcefa8c5ef85643,bfdf66a7439df004,3f25f1669ccbc100,3feaa9acd3b4488e,bfcee9d0fc8b9c9d,bfe4c77d7f1d5546,3fb3cce05b8d382b",
    "welsch_2_5x" => "3f99f67bcf53dbac,3feda808f019183a,3fb7d9872495bc18,bfe7655053934de4,bf9a22af5d863999,3fe5bcc592740cb1,bfac74eb7d224fc3,bfd741828c033adc,3f78e32dfdef0dc5",
    "newton" => "bfb5c255c18d1a99,3fdf35721c088133,3fdd53b05566e2b3,bfd9570d9bcb55ad,3f8e00e903b7c1a2,3fe82360350b920f,bfd5bdc936677482,bfea80befa2963c5,3fc105d66dac2808",
    # "ecm" pin re-baked 2026-07-14 for the D2 incumbent-comparability fix
    # (WelschHQEcm now selects the incumbent by re-scoring seed +
    # trajectory at the FINAL converged scale — see problems/essential.jl
    # WelschEcmScale header; the pre-fix moving-objective pin was
    # 3fb04e862ee4798e,…,3fb46de38e9b954a). All other arms unchanged.
    "ecm" => "3faf984748af3f6e,3fe8c510a2fc3cb9,3fc9edb9241164d5,bfe19802ccee4485,bf859278d88fd70b,3fe9ea18583d7fd5,bfc89c3e4feeaef5,bfe32218e4d2ccb9,3fad79b60856831c",
    "gm" => "3fb2d2fd2b09a402,3fe6fb094daa12c5,3fced13308d78ef0,bfdf6f7635cdb68a,bf2b97d8df7e2b28,3feaab2b5c5a030f,bfceb58a3890814e,bfe4c78e749313ac,3fb39bbf9618f4cd",
    "tls" => "3fb15b4cbfbe61af,3fe85cd662216447,3fcb74f39345a6c6,bfe11b9631924864,bf7cd25f78635a43,3fea1d41a397a061,bfca99da6386993f,bfe37b7f59b081e6,3fb053941a287411",
    "welsch_F" => "3f889ec72bbb5ea0,3fec400aa495ec26,3fba7dd93cb701a6,bfe6eda83c6472b1,bfb3132cbd82ff60,3fe5bb320bc22552,bfadf4904df45eda,bfd7fc9fa1f2bf31,3f7e551983e89be0",
)

@testset "lift losses: Welsch-lift trait path is bit-identical (regression)" begin
    u₁, u₂, E_seed = _lift_regression_scene()
    p = cal_problem(u₁, u₂)
    # The Welsch scale multiples below are NOT in the residual's unit and must
    # NOT be scaled with it. Measured: scaling them by the focal length collapses
    # `welsch`, `welsch_1x` and `welsch_2_5x` to BIT-IDENTICAL output — the
    # loss goes flat and the multiple stops mattering, which is the opposite of
    # what these three arms exist to test. `scale_multiple` multiplies an
    # estimated scale; the outlier half-width is the quantity that carries the
    # residual's unit.
    arms = [
        "welsch" => HQ{WelschShape}(max_iter = 25, scale_multiple = 1.5),   # historical default (bitwise fixture)
        "welsch_1x" => HQ{WelschShape}(max_iter = 25, scale_multiple = 1.0),
        "welsch_2_5x" => HQ{WelschShape}(max_iter = 25, scale_multiple = 2.5),
        "newton" => WelschHQNewton(scale_multiple = 1.5, max_iter = 25),
        "ecm" => WelschHQEcm(scale_multiple = 1.5, max_iter = 25),
        "gm" => LO.GmHqEps(scale_multiple = 1.0),
        "tls" => HQ{SmoothTLSShape}(scale_multiple = 2.0),              # historical LiftedSmoothTLSIrls defaults (40, scale_multiple = 2)
        # (the `scale_multiple = 0` crossover-sentinel arms gm_sent/tls_sent
        # retired with the sentinel: a non-positive multiple is refused)
    ]
    # DISCRIMINATION: the arms must still tell each other apart. Without this a
    # regime change can collapse several arms to bit-identical output and every
    # pin still succeeds — the failure mode that nearly shipped here, caught only
    # by eye when regenerating. Asserted mechanically so it cannot recur.
    _arm_models = Dict{String, SMatrix{3, 3, Float64, 9}}()
    for (name, lo) in arms
        # Explicit Float64 workspace: the hex pins were captured at Float64
        # storage; the default workspace is now Float32.
        r = locally_optimize(
            p, E_seed; scoring = StudentTUniformScoring(p, 0.05),
            local_optimization = lo,
            workspace = RansacWorkspace(p, StudentTUniformScoring(p, 0.05), Float64)
        )
        @test estimate(r) !== nothing
        @test projective_distance(estimate(r), _unhex9(_LIFT_REGRESSION[name])) < 1.0e-6
        _arm_models[name] = SMatrix{3, 3, Float64, 9}(estimate(r))
    end
    # Measured margin: the three Welsch widths separate by ~1e-3 relative in
    # this (calibrated) regime — small but real, and zero in the pixel regime,
    # which is why the testset lives here. 1e-9 is far below the real margin
    # and far above last-bit noise, so it catches a collapse without pinning
    # the magnitude.
    let names = collect(keys(_arm_models))
        for i in 1:length(names), j in (i + 1):length(names)
            @test projective_distance(_arm_models[names[i]], _arm_models[names[j]]) > 1.0e-9
        end
    end
    # F lift (7-dof orthonormal chart), same trait path. NOTE: no cross-config
    # pin — the F chart's 25-iteration trajectory amplifies last-bit config
    # differences (check-bounds) past any tolerance that would still detect
    # regressions, so the F lift is gated by the smoke testset below.
    pf = FundMatProblem(StructArray(u₁ .=> u₂))
    F_seed = FundMat(Tuple(SMatrix{3, 3, Float64, 9}(E_seed)))
    rf = locally_optimize(
        pf, F_seed; scoring = StudentTUniformScoring(pf, 0.05),
        local_optimization = HQ{WelschShape}(max_iter = 25, scale_multiple = 1.5)
    )
    @test estimate(rf) !== nothing
end

# -----------------------------------------------------------------------------
# Smoke: each loss's lift executes and improves a perturbed seed.
# -----------------------------------------------------------------------------
function _lift_smoke_scene()
    R = RotY(0.25); t = normalize(SA[0.6, -0.15, 0.35])
    u₁, u₂ = calibrated_pairs(MersenneTwister(11), R, t; n = 110, σ = 0.001, outlier_every = 12)   # ~8% gross outliers
    return u₁, u₂, perturbed_essential(R, t, 0.06, SA[0.05, -0.04, 0.03]), R, SVector{3, Float64}(t)
end

@testset "lift losses: HQ{K} smoke (E + F)" begin
    u₁, u₂, E_seed, R_gt, t_gt = _lift_smoke_scene()
    p = cal_problem(u₁, u₂)
    e_seed = Synthetic.imc_pose_error(E_seed, R_gt, t_gt)
    @test e_seed > 3.0                     # the seed is genuinely perturbed (~3.4°)
    # Per-loss standardized depths at which the lift must recover: the
    # redescending losses at the deployed Welsch scale multiple 1.5 (half-weight
    # depth 1.5·√ln2);
    # Cauchy — the ablation's non-redescending control, whose heavy tail drags
    # toward outliers at wide widths (that sensitivity is the finding the
    # ladder ablation quantifies) — at a tighter depth where it contracts.
    half_weight_depth = 1.5 * sqrt(log(2.0))
    # Per-K currencies (HQ docstring): Welsch a width multiple, GM/Cauchy a
    # half-weight depth, smooth-TLS a cutoff multiple (the half-weight depth maps
    # to the cutoff √2·half_weight_depth·ŝ).
    arms = [
        HQ{WelschShape}(max_iter = 25, scale_multiple = 1.5),
        HQ{GemanMcclureShape}(max_iter = 25, scale_multiple = half_weight_depth),
        HQ{SmoothTLSShape}(max_iter = 25, scale_multiple = sqrt(2.0) * half_weight_depth),
        HQ{CauchyShape}(max_iter = 25, scale_multiple = 0.6),
    ]
    for lo in arms
        r = locally_optimize(
            p, E_seed; scoring = StudentTUniformScoring(p, 0.05),
            local_optimization = lo
        )
        @test estimate(r) !== nothing
        @test retcode(r) in (:converged, :max_iterations)
        @test Synthetic.imc_pose_error(estimate(r), R_gt, t_gt) < 0.8 * e_seed  # the lift traveled toward GT
    end
    # F path: every loss arm executes and reduces the truncated Sampson cost.
    pf = FundMatProblem(StructArray(u₁ .=> u₂))
    F_seed = FundMat(Tuple(SMatrix{3, 3, Float64, 9}(E_seed)))
    sqcost(F) = truncated_sampson_cost(F, u₁, u₂)
    cost_seed = sqcost(F_seed)
    for lo in arms
        rf = locally_optimize(
            pf, F_seed; scoring = StudentTUniformScoring(pf, 0.05),
            local_optimization = lo
        )
        @test estimate(rf) !== nothing
        @test sqcost(estimate(rf)) < cost_seed
    end
end

# -----------------------------------------------------------------------------
# The PIXEL regime. Every E arm above runs at f = 1 (calibrated units), so the
# deployed configuration — a real focal length, the outlier half-width in
# pixels — had no lift gate at all. Same scene, moved into the pixels of an
# f = 800 camera; the outlier half-width scales with the residual's unit, the
# Welsch `scale_multiple` does not (it multiplies an estimated scale).
# -----------------------------------------------------------------------------
@testset "lift losses: E HQ lift in the pixel regime" begin
    u₁, u₂, E_seed, R_gt, t_gt = _lift_smoke_scene()
    f = FPX
    p = ecs(u₁, u₂)                                    # the scene in ECAM's pixels
    e_seed = Synthetic.imc_pose_error(E_seed, R_gt, t_gt)
    lift(scale_multiple) = locally_optimize(
        p, E_seed; scoring = StudentTUniformScoring(p, 0.05 * f),
        local_optimization = HQ{WelschShape}(; max_iter = 25, scale_multiple)
    )
    # The same lift in calibrated units, for the unit-invariance gate below.
    pc = cal_problem(u₁, u₂)
    lift_cal(scale_multiple) = locally_optimize(
        pc, E_seed; scoring = StudentTUniformScoring(pc, 0.05),
        local_optimization = HQ{WelschShape}(; max_iter = 25, scale_multiple)
    )
    models = Dict{Float64, SMatrix{3, 3, Float64, 9}}()
    for scale_multiple in (1.0, 1.5, 2.5)
        r = lift(scale_multiple)
        @test estimate(r) !== nothing
        @test retcode(r) in (:converged, :max_iterations)
        @test projective_distance(estimate(r), E_seed) > 1.0e-6     # the lift moved the model
        # Moving into pixels changes nothing but the unit: the pose error
        # matches the calibrated lift's at every width (measured: 1.2e-6
        # relative at scale_multiple = 1, the conditioning of the pixel ↔ bearing map).
        @test isapprox(Synthetic.imc_pose_error(estimate(r), R_gt, t_gt), Synthetic.imc_pose_error(estimate(lift_cal(scale_multiple)), R_gt, t_gt); rtol = 1.0e-5)
        # Toward the truth at the deployed widths only. Measured: at a scale
        # multiple ≥ 2.5 the Welsch loss admits this scene's 8% outliers and ends
        # near 13°, identically in calibrated units — the width, not the unit.
        scale_multiple <= 1.5 && @test Synthetic.imc_pose_error(estimate(r), R_gt, t_gt) < 0.8 * e_seed
        models[scale_multiple] = SMatrix{3, 3, Float64, 9}(estimate(r))
    end
    # and its width is live: different scale multiple, different model
    @test projective_distance(models[1.0], models[2.5]) > 1.0e-12
end

# -----------------------------------------------------------------------------
# Every registered strategy RUNS. Constructing a strategy proves nothing about
# the code behind it: `BarronAdaptive` was built by two testsets and run by
# none, so a half-applied field rename (of the inverse squared loss width) made every
# one of its local optimizations a FieldError while the suite stayed green
# (2026-09-21 audit). So: every LO_TAGS entry, and every loss each
# loss-parametric mechanism admits, is built through the TOML loader and run
# end to end on E. The two eval-only PoseLib arms have no native-loop path by
# design and must say so; a loss a mechanism cannot run is refused at LOAD.
# -----------------------------------------------------------------------------
@testset "every registered LO strategy runs end to end (E)" begin
    u₁, u₂, E_seed = _lift_smoke_scene()
    p = cal_problem(u₁, u₂)
    build(d) = local_optimization_from_toml(d; class = :essential, tags = TAGS)
    runlo(lo) = locally_optimize(p, E_seed; scoring = StudentTUniformScoring(p, 0.05), local_optimization = lo)
    # a registry entry's owner answers whether it takes a loss
    parametric(T) = RVGK.lo_parametric(T)
    for (tag, T) in TAGS
        takes_scale_multiple = :width in fieldnames(T) || hasfield(T, :scale_multiple)   # WelschHQEcm: a plain multiple
        takes_loss = parametric(T)
        takes_loss && continue                         # the loss families: below
        d = Dict{String, Any}("type" => tag)
        takes_scale_multiple && (d["scale_multiple"] = 1.5)
        tag == "barron_hq" && (d["alpha"] = -2.0)
        # the terminal placement names its strategy in a nested `inner` table
        tag == "terminal_lo" && (d["inner"] = Dict{String, Any}("type" => "hq", "loss" => "welsch", "scale_multiple" => 1.5))
        r = runlo(build(d))
        @test estimate(r) !== nothing
        @test retcode(r) in (:converged, :max_iterations)
    end
    # Loss families: what each admits runs; what it refuses fails at load.
    admitted = Dict(
        "irls" => ("gaussian", "welsch", "geman_mcclure", "cauchy", "smooth_tls", "tls", "huber"),
        "hq" => ("welsch", "geman_mcclure", "cauchy", "smooth_tls"),
        "gnc" => ("welsch", "geman_mcclure", "tls"),
    )
    for (tag, losses) in admitted, loss in keys(LOSS_TAGS)
        d = Dict{String, Any}("type" => tag, "loss" => loss)
        # least squares (Irls on the gaussian loss) has no scale multiple
        (tag == "irls" && loss == "gaussian") || (d["scale_multiple"] = 1.5)
        if loss in losses
            r = runlo(build(d))
            @test estimate(r) !== nothing
            @test retcode(r) in (:converged, :max_iterations)
        else
            @test_throws Exception build(d)            # Gnc's refusal is an ErrorException
            tag == "gnc" || @test_throws ArgumentError build(d)
        end
    end
    # Irls{GaussianShape} is least squares: no `scale_multiple` to require, and one given
    # is refused (in the constructor and in a TOML table), never ignored.
    @test Irls{GaussianShape}() isa Irls{GaussianShape}
    @test_throws ArgumentError Irls{GaussianShape}(scale_multiple = 1.5)
    @test VgtkCore.lo_width(Irls{WelschShape}()) === nothing   # no width: follows the scorer
    @test_throws ArgumentError build(Dict{String, Any}("type" => "irls", "loss" => "gaussian", "scale_multiple" => 1.5))
    l2 = Irls{GaussianShape}(max_iter = 7)
    @test !haskey(config_dict(l2), "scale_multiple")
    @test local_optimization_from_toml(config_dict(l2); class = :homography, tags = TAGS) == l2
    @test VgtkCore.lo_width(l2) === nothing
    @test VgtkCore.scale_interface(l2) == VgtkCore.NoScale()
    @test VgtkCore.with_width(l2, nothing) == l2
    # The seeded z₀ policies had no runner anywhere; they now read the deployed
    # loss's own normalized weight (VGC `lift_weight`/`lift_wmax`) — run them.
    for K in (WelschShape, GemanMcclureShape, SmoothTLSShape), init in (:posterior, :consensus)
        r = runlo(HQ{K}(scale_multiple = 1.5, init = init))
        @test estimate(r) !== nothing
        @test retcode(r) in (:converged, :max_iterations)
    end
end

# =============================================================================
# BarronHQ α-dial — MANDATORY pre-launch anchor gates (smooth-and-lift
# 3-ii): the dial engine must reproduce the existing arms at its parameter
# limits (α → −∞ ≡ Welsch-HQ; α = −2 ≡ GM-HQ; α = 0 ≡ Cauchy-HQ) under the
# fixed-core-width standardization: Barron loss width = scale_multiple·ŝ/√2.
# =============================================================================
@testset "BarronHQ α-dial anchor gates" begin
    u₁, u₂, E_seed = _lift_regression_scene()
    p = cal_problem(u₁, u₂)
    RVGB = LocalOptimizationDoneRight
    run(lo) = estimate(locally_optimize(
        p, E_seed; scoring = StudentTUniformScoring(p, 0.05),
        local_optimization = lo
    ))
    scale_multiple = 1.5
    # α → −∞ ≡ HQ{WelschShape} at the same scale multiple. The limit is NOT
    # uniform in s: the tail correction is a factor e^{x²/(4|α|)} at
    # x = s/loss_width² — canonical-unit gross
    # outliers sit at x ≈ 6·10⁴ (x² ≈ 4·10⁹), so |α| ≳ 10¹² is needed before
    # the losses agree to trajectory tolerance (measured: d = 8e-5 at −1e10,
    # 4.3e-7 at −1e12, plateau ≈ 3e-7 = the 25-iteration ulp-chaos floor).
    Ew = run(RVGB.HQ{WelschShape}(; max_iter = 25, scale_multiple))
    Eb = run(RVGB.BarronHQ(-1.0e12; max_iter = 25, scale_multiple))
    @test projective_distance(Eb, Ew) < 1.0e-6
    # α = −2 ≡ the GM lift at GM loss width = 2·(Barron loss width) = √2·scale_multiple·ŝ
    # (HQ{GM} half-weight currency: GM loss width = m·ŝ/√(√2−1) ⇒ m = √2·scale_multiple·√(√2−1))
    Egm = run(RVGB.HQ{GemanMcclureShape}(max_iter = 25, scale_multiple = sqrt(2) * scale_multiple * sqrt(sqrt(2) - 1)))
    Eb2 = run(RVGB.BarronHQ(-2.0; max_iter = 25, scale_multiple))
    @test projective_distance(Eb2, Egm) < 1.0e-6
    # α = 0 ≡ the Cauchy lift at Cauchy loss width = √2·(Barron loss width) =
    # scale_multiple·ŝ (the Cauchy decision width is the identity)
    Eca = run(RVGB.HQ{CauchyShape}(; max_iter = 25, scale_multiple))
    Eb3 = run(RVGB.BarronHQ(0.0; max_iter = 25, scale_multiple))
    @test projective_distance(Eb3, Eca) < 1.0e-6
    # interior dial points run and return finite refined models
    for α in (-8.0, -4.0, -1.0, -0.5, 0.5, 1.0)
        E = run(RVGB.BarronHQ(α; max_iter = 25, scale_multiple))
        @test E !== nothing && all(isfinite, Tuple(SMatrix{3, 3, Float64}(E)))
    end
end
