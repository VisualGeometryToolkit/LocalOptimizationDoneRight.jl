# =============================================================================
# test_homography_lift.jl — smoke + parity gate for the H loss lift.
#
# Gates (the acceptance battery for the sl(3) joint-(θ,z) lift port; the
# battery itself is LiftChecks', shared with test_pnp_lift.jl):
#   1. Full production `ransac()` with StudentTUniformScoring converges on a
#      plane-induced synthetic (150 noisy inliers + 100 uniform outliers)
#      for each LO arm — static Irls{WelschShape}, the HQ{K} loss lifts
#      (Welsch, Geman–McClure), and the GNC arm — with small corner
#      reprojection error vs GT and high-tp/low-fp inlier recovery.
#   2. Basin sanity via `locally_optimize` from PERTURBED seeds (modest
#      random sl(3) steps about the GT): the HQ lifts recover where the
#      static Welsch IRLS is trapped, and match it from near seeds.
# =============================================================================
# (Moved from VisualGeometryToolkitEstimation's test/homography_lift_tests.jl with the strategies it tests.)
using Test, Random, LinearAlgebra, StaticArrays
using VisualGeometryToolkitCore: estimate   # VGC accessor (public)
using VisualGeometryToolkitCore: HomographyManifold8, retract   # the sl(3) chart (public)
using RANSACScoringDoneRight: StudentTUniformScoring   # owned and exported by RANSACScoringDoneRight
using VisualGeometryToolkitEstimation
using LocalOptimizationDoneRight
include("scenes.jl")   # the shared scenes, as modules
using .HomographyScenes, .Contamination, .LiftChecks
const RVGL = VisualGeometryToolkitEstimation

@testset "Homography loss lift — smoke + parity" begin
    # --- plane-induced synthetic --------------------------------------------
    # Every source first (inliers, then the outliers' sources), then each
    # inlier's 0.5 px target noise, then each outlier's uniform target — the
    # draw order the bitwise pins below were captured on.
    rng = MersenneTwister(42)
    n_in, n_out = 150, 100
    src = [uniform_source(rng) for _ in 1:(n_in + n_out)]
    pairs, _ = contaminated_pairs(
        rng, src[1:n_in] .=> homography_warp(H_TRUE).(src[1:n_in]);
        σ = 0.5, n_out, outlier = (rng, k) -> src[n_in + k] => uniform_source(rng)
    )
    prob = HomographyProblem(pairs)
    sc = StudentTUniformScoring(prob, 50.0)

    # Homography error metric: max reprojection error of the GT-inlier
    # region's corners under Ĥ vs the GT homography.
    corners = (
        SVector(100.0, 100.0), SVector(900.0, 100.0),
        SVector(900.0, 700.0), SVector(100.0, 700.0),
    )
    cerr(H) = max_transfer_error(H, H_TRUE, corners)

    # --- 1. full production ransac() per LO arm ------------------------------
    arms = lift_arms(; welsch_scale_multiple = 1.5, gnc_scale_multiple = 2.5)
    check_lift_ransac(prob, sc, arms, n_in; seed = 325) do Ĥ
        @test cerr(Ĥ) < 1.5                              # ≈3σ of the 0.5 px noise at the corners
    end

    # --- 2. basin sanity: HQ from a perturbed seed ---------------------------
    # Perturb the GT homography by a modest random sl(3) chart step. The chart
    # coefficient scale is TINY in pixel currency for this H (unit-Frobenius
    # H has h₃₃ ≈ 0.06, so |δ| ~ 1e-3 already displaces the corners by
    # hundreds of px). Pinned seeds; magnitudes chosen so the near seed is
    # inside every arm's basin and the far seeds strand the static IRLS.
    # The anchor is a LOCAL, captured by the closure, deliberately: written as
    # the global constant `H_TRUE` inside `seed_H`, the compiler constant-folds
    # the chart construction and one entry of the seed moves 2 ulp (measured
    # 2026-09-30), which the lift carries to 26-92 ulp in the bitwise pins below.
    H_u = SMatrix{3, 3, Float64, 9}(H_TRUE)
    seed_H(δn, sd) = begin
        Random.seed!(sd)
        δ = δn * normalize(randn(8))
        retract(HomographyManifold8(SMatrix{3, 3, Float64, 9}(H_u)), SVector{8, Float64}(δ))
    end
    # Explicit Float64 workspace: the bit-pins below were captured at Float64
    # storage; the default workspace is Float32 (storage precision perturbs
    # the seed scale ~1e-7 which the lift's GN iterations amplify ~1e-4).
    refit(H₀, lo) = RVGL.locally_optimize(
        prob, H₀; local_optimization = lo, scoring = sc,
        workspace = RVGL.RansacWorkspace(prob, sc, Float64)
    )
    arm = Dict(arms)

    @testset "near seed — every arm recovers" begin
        H₀ = seed_H(1.0e-4, 3)                             # seed corner error ≈ 16 px
        @test cerr(H₀) > 5.0                             # genuinely perturbed
        check_lift_recovers(lo -> refit(H₀, lo), arms[1:3]) do Ĥ
            @test cerr(Ĥ) < 2.0                          # all match: recovery from the near seed
        end
    end

    # --- 3. bitwise regression: the codim-2 core refactor is a NO-OP ---------
    # Hard-coded UInt64 bit patterns of the refined H entries, captured on the
    # pre-refactor commit (8ba8d72-era H lift, before the θ/z block moved to
    # estimators/ransac/lift_core.jl) on this exact synthetic + pinned seed.
    # The H lift path must stay within PIN_ULPS of the pinned values through
    # the shared core: a different minimum moves the model ~1e-3 (~1e13 ulp),
    # FP re-association a few tens of ulp. Bit-identity is not the criterion,
    # because it is build-dependent: Pkg.test runs with --check-bounds=yes,
    # which turns the @inbounds/@simd loops' reassociated FP back into
    # sequential FP, and the same source then lands up to ~101 ulp from a
    # bounds-elided build's values (measured 2026-10-01 on all three arms).
    @testset "ulp-bounded core-refactor regression" begin
        H₀ = seed_H(1.0e-3, 3)
        bits(lo) = reinterpret.(UInt64, collect(Tuple(estimate(refit(H₀, lo)))))
        PIN_ULPS = 256
        # entrywise ulp distance; a sign flip is never within the bound
        near(got, pinned) = all(zip(got, pinned)) do (g, p)
            (g >> 63) == (p >> 63) && abs(reinterpret(Int64, g) - reinterpret(Int64, p)) <= PIN_ULPS
        end
        # Re-pinned 2026-07-28 against RSDR 0.7.0 (UInt32 radix sort keys —
        # tie-order shift moved the trajectory 1-2 ulp from the 8ba8d72-era
        # values; verified identical on clean pre-Float32 RVG source, so the
        # storage-precision work is bitwise clean at Float64).
        # Re-pinned 2026-09-05 against VGC 0.19.0 / RSDR 0.7.18: every entry
        # moved 1-2 ulp on clean master (identical with and without the
        # release/0.15 SO(3) port), i.e. an upstream FP-order change, not a
        # lift-core change. Upstream reordering is accepted; this fixture
        # guards the H lift path only.
        # Re-pinned 2026-09-16 against VGC 0.26.3: every entry moved 1-2 ulp on
        # clean master with no lift-core change. The pin had stood since 0.22.0,
        # four minor versions of upstream reordering; the H lift path does not
        # touch VGC's rational-radial root solve. Same rule.
        # Re-pinned 2026-09-09 against VGC 0.22.0 / RSDR 0.7.23 / PoseLib
        # 0.3.21: entries moved a few ulp on clean master with no change to
        # the lift core (VGC's rational-radial projection root is a seeded
        # Newton since 0.21.2 and its focal stack a Schur solve since 0.21.2;
        # 0.22 renamed the lens Jacobians to transform_deriv). Same rule.
        # Re-pinned 2026-09-17 against VisualGeometryToolkitCore 0.28.1 / RSDR 0.8.0:
        # VGC's loss family retired the per-shape `lift_cost` loops for a generic
        # loop over the new `lift_rho`; the re-associated cost accumulation moves
        # the HQ arms tens of ulp and the GNC arm 1-2 ulp on clean master, with no
        # lift-core change here (RVG 0.22.0's own commit was signature-only, and
        # RVG supplies MuLadder's converged_rung explicitly, so VGC 0.28's flipped
        # default does not reach this path). Upstream reordering is accepted; this
        # fixture guards the H lift path only. Same rule.
        # Re-pinned 2026-09-20 for the held-loss refactor (RVG): the HQ arms
        # now carry a `DeployedLoss` and the currency map (now the
        # `_scale_multiple_currency(mechanism, shape)` trait in scoring_glue.jl)
        # returns the dimensionless multiple m, so the squared width is `m²·ŝ²`
        # instead of `(m·ŝ)²`. ONLY the GM entry moved — the GM currency is the
        # one that re-associates (`m/√(√2−1)` squared against ŝ², vs
        # `(m·ŝ)/√(√2−1)` squared); Welsch's multiple is forwarded unchanged and the GNC arm already
        # deployed as a pair, and both arrays below are byte-identical. Measured:
        # the input squared width moves ≤ 2 ulp (max rel 2.9e-16) and the output
        # model 2-24 ulp (max rel 3.5e-15, normalized gap 4.4e-16) — pure FP
        # re-association through 25 lift iterations, NOT a different minimum
        # (which would move the model ~1e-3). Same rule.
        # Re-pinned 2026-09-21 (RVG cleanup): the homography dehomogenization
        # Jacobian `_dpi` now IS VGC's `transform_deriv(::PerspectiveMap, h)` —
        # `iz = 1/h₃; −h₁·iz²` — instead of RVG's re-derived `−h₁/h₃²`; the
        # different expression tree rounds differently. Measured same-process
        # against the old pins (which the old `_dpi` reproduced exactly): every
        # arm moved, max 81 ulp (Welsch), max rel entry move 9.4e-15, normalized
        # model gap ≤ 4.9e-15 — FP re-association through the lift iterations,
        # not a different minimum. Same rule.
        # Re-pinned 2026-09-22 (RVG cleanup): the H LM and lift rows are VGC's
        # whitened transfer rows (`transfer_whitening!` / `transfer_rows!` /
        # `transfer_jacobian_rows!`, VGC 7443b90) along the chart directions of
        # `retract_jacobian(HomographyManifold8(H₀), a)`, replacing RVG's own
        # whitening and loops. Measured same-process against the old pins (which
        # the pre-switch source reproduced exactly): Welsch ≤ 231 ulp (max rel
        # entry move 3.1e-14, normalized model gap 7.7e-15), GM ≤ 46 ulp
        # (6.4e-15, 5.7e-16), GNC ≤ 36 ulp (5.5e-15, 3.3e-15) — FP
        # re-association (fma placement per inlining site) through the lift
        # iterations, not a different minimum. Same rule.
        # Re-pinned 2026-09-30 (VGC 09277bd + d544bb8): the Welsch z-block's
        # hreg now tends to its limit 2c² at w̄ = 1 instead of returning 0 there
        # (and no longer cancels just below it), so every confident inlier keeps
        # its Schur pivot. Welsch moved to a DIFFERENT MINIMUM, as that change
        # predicts: max rel entry move 7.3e-2, normalized model gap 4.6e-2. GM
        # (≤ 46 ulp, 6.4e-15, 5.7e-16) and GNC{Irls{Welsch}} (≤ 38 ulp, 6.4e-15,
        # 3.9e-15) do not use that z-block and moved only by FP re-association —
        # not a different minimum. Measured against the previous pins; untouched
        # RVG HEAD 9c735a4 gives the same new values, so RVG did not move them.
        # Same rule.
        # Re-pinned 2026-09-30 (the stack-wide duplication removal): VGC's one
        # perspective division is CoordinateTransformations' `PerspectiveMap()`
        # (multiply by 1/w, was divide) and the H path runs one LM/lift/whitening
        # route (one codim-generic lift core, bitwise equal to the old codim-2
        # one on this lift). Measured against the previous pins: Welsch ≤ 43 ulp
        # (max rel entry move 4.8e-15, normalized model gap 2.8e-15), GM ≤ 55 ulp
        # (6.2e-15, 3.6e-15), GNC ≤ 30 ulp (4.3e-15, 8.0e-16) — FP
        # re-association through the lift iterations, not a different minimum.
        # Same rule.
        @test near(bits(arm["HQ{Welsch}"]), UInt64[
            0x3face8fcd49a9be7, 0x3f7d0eaa8f6ff981, 0x3ed8a2633fdfa143,
            0xbf77dccbe0df69f0, 0x3fac5f1f5badf439, 0x3ee990336ff44785,
            0x3feb8a65aff9aaf3, 0xbfdff686f05949a4, 0x3fae6752b9639046,
        ])
        @test near(bits(arm["HQ{GM}"]), UInt64[
            0x3fad00bf2f9a232a, 0x3f7d165bf155204e, 0x3ed88e2472b6de4c,
            0xbf77e51a283b128d, 0x3fac77954d43e5c2, 0x3ee9affc6a39ff0a,
            0x3febb9efec7bcd3d, 0xbfdf4f4e174ba93a, 0x3fae8456acc76c80,
        ])
        @test near(bits(arm["Gnc{Irls{Welsch}}"]), UInt64[
            0x3fad36fb9b473012, 0x3f7d476575499a09, 0x3ed8b5f25f5fa8da,
            0xbf77be638ff57663, 0x3facb65e46c95955, 0x3eea480372677140,
            0x3feb1c2d6915e83a, 0xbfe0b1e8e6b2d741, 0x3faeb312faaad50c,
        ])
    end

    @testset "far seed — HQ recovers where Irls is trapped" begin
        for δn in (1.0e-3, 3.0e-3)                           # seed corner error ≈ 190 / 1000 px
            H₀ = seed_H(δn, 3)
            e_irls = cerr(estimate(refit(H₀, arm["Irls{Welsch}"])))
            e_hqw = cerr(estimate(refit(H₀, arm["HQ{Welsch}"])))
            e_hqgm = cerr(estimate(refit(H₀, arm["HQ{GM}"])))
            @test e_irls > 20.0                          # static IRLS stranded far from GT
            @test e_hqw < 10.0                          # the lift crosses the basin
            @test e_hqgm < 10.0
        end
    end
end
