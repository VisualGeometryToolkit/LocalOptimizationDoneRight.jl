# =============================================================================
# RansacLibLO tests: determinism, option plumbing, update accounting,
# E-manifold validity, refinement on a synthetic essential scene.
# =============================================================================

using Test, Random, LinearAlgebra
using RansacLibLO

skew(t) = [0.0 -t[3] t[2]; t[3] 0.0 -t[1]; -t[2] t[1] 0.0]

# Synthetic calibrated two-view scene (normalized image coords, z = 1).
# Wide field of view (~±45°): non-minimal 8-point fits on a handful of points
# are only well-posed with parallax/spread — mirroring the real-data regime
# the classical LO was designed for (a narrow-FOV synthetic makes 14-point
# DLT fits fit-the-sample-but-wrong-globally and every LO stage gate out).
function make_scene(rng; n_in = 120, frac_out = 0.3, noise = 0.002)
    φ = 0.2
    R = [cos(φ) 0 sin(φ); 0 1 0; -sin(φ) 0 cos(φ)]
    t = normalize([0.8, 0.1, 0.3])
    pts = Vector{NTuple{4,Float64}}()
    while length(pts) < n_in
        X = [4.0 * (rand(rng) - 0.5), 3.0 * (rand(rng) - 0.5), 1.5 + 3.0 * rand(rng)]
        Y = R * X + t
        (Y[3] <= 0.2 || X[3] <= 0.2) && continue
        x1 = X[1] / X[3]; y1 = X[2] / X[3]
        (abs(x1) > 1.5 || abs(y1) > 1.2) && continue
        push!(pts, (x1, y1,
                    Y[1] / Y[3] + noise * randn(rng), Y[2] / Y[3] + noise * randn(rng)))
    end
    n_out = round(Int, frac_out / (1 - frac_out) * n_in)
    for _ in 1:n_out
        push!(pts, (randn(rng), randn(rng), randn(rng), randn(rng)))
    end
    P = Matrix{Float64}(undef, 4, length(pts))
    for (i, p) in enumerate(pts); P[:, i] .= p; end
    E_gt = skew(t) * R
    return P, E_gt / norm(E_gt), R, t
end

# Direction error between essential matrices (sign/scale invariant).
e_err(E, G) = (Ên = E / norm(E); Ĝn = G / norm(G); min(norm(Ên - Ĝn), norm(Ên + Ĝn)))

# Perturbed seed: rotate the pose and jitter translation.
function perturb_seed(R, t, δ, rng)
    Rp = R * [cos(δ) -sin(δ) 0; sin(δ) cos(δ) 0; 0 0 1]
    tp = normalize(t + δ * randn(rng, 3))
    E = skew(tp) * Rp
    return E / norm(E)
end

const refit_sq_loss_width = 1e-4    # squared Sampson loss width (noise 0.002 ⇒ ~5σ)

# Squared first-order Sampson distances of all columns (test-side reference,
# same 4-term denominator as the shim's EvaluateModelOnPoint).
function sampson²(P::AbstractMatrix, E::AbstractMatrix)
    n = size(P, 2)
    out = Vector{Float64}(undef, n)
    for i in 1:n
        x1 = [P[1, i], P[2, i], 1.0]; x2 = [P[3, i], P[4, i], 1.0]
        Ex1 = E * x1; Etx2 = E' * x2
        C = dot(x2, Ex1)
        out[i] = C^2 / (Ex1[1]^2 + Ex1[2]^2 + Etx2[1]^2 + Etx2[2]^2 + eps())
    end
    return out
end

@testset "RansacLibLO" begin
    rng = MersenneTwister(7)
    four_trials = LebedaLOOptions(num_lo_trials = 4)   # 1 + 4·(2 + 4) = 25 updates when fully active
    P, E_gt, R, t = make_scene(rng)
    E0 = perturb_seed(R, t, 0.05, MersenneTwister(11))

    @testset "option plumbing (RansacLib defaults are the reference)" begin
        @test_throws ArgumentError LebedaLOOptions(num_lsq_iterations = 1)
        @test_throws ArgumentError LebedaLOOptions(sq_loss_width_multiplier = 0.5)
        @test_throws ArgumentError LebedaLOOptions(num_lo_trials = -1)
        # PRESET_REFERENCE == LORansacOptions() defaults (ransac.h)
        @test PRESET_REFERENCE.num_lo_trials == 10
        @test PRESET_REFERENCE.sq_loss_width_multiplier ≈ sqrt(2.0)
        @test PRESET_REFERENCE.num_lsq_iterations == 4
        @test PRESET_REFERENCE.min_sample_multiplicator == 7
        @test PRESET_REFERENCE.non_min_sample_multiplier == 3
        # the ladder's squared-width schedule (RunIterLSQ): θ², then √2·θ² down to θ² in 4 rungs
        θ² = 2.0
        w = lsq_sq_loss_widths(PRESET_REFERENCE, θ²)
        @test length(w) == 1 + PRESET_REFERENCE.num_lsq_iterations
        @test w[1] == θ² && w[2] == sqrt(2.0) * θ² && w[end] ≈ θ²
        @test all(diff(w[2:end]) .≈ -(sqrt(2.0) - 1) * θ² / 3)
        @test_throws ArgumentError lsq_sq_loss_widths(PRESET_REFERENCE, 0.0)
        # informational Lebeda-TR mapping (public options only)
        @test PRESET_TR_INFORMATIVE.sq_loss_width_multiplier == 4.0   # m_θ = 2 on θ
        @test PRESET_TR_INFORMATIVE.num_lo_trials == 10            # reps
        @test PRESET_TR_INFORMATIVE.num_lsq_iterations == 4       # iters
        @test PRESET_TR_INFORMATIVE.min_sample_multiplicator == 10 # cap 50 ≈ inlLimit 49
    end

    @testset "argument validation" begin
        @test_throws ArgumentError lebeda_lo(P[1:3, :], E0, refit_sq_loss_width)
        @test_throws ArgumentError lebeda_lo(P[:, 1:5], E0, refit_sq_loss_width)
        @test_throws ArgumentError lebeda_lo(P, E0[1:2, :], refit_sq_loss_width)
        @test_throws ArgumentError lebeda_lo(P, E0, -1.0)
        @test_throws ArgumentError lebeda_lo(P, E0, refit_sq_loss_width; base_mask = trues(3))
    end

    @testset "update accounting (measured solves vs cap arithmetic)" begin
        # From a GT seed every stage's consensus gate is populated, so the
        # counts hit the closed forms exactly:
        #   full LO: 1 + num_lo_trials·(2 + num_lsq_iterations); ILSQ: 1 + iters.
        Eg = Matrix(E_gt)
        @test lebeda_lo(P, Eg, refit_sq_loss_width; rng_seed = 1).updates == 1 + 10 * (2 + 4)   # 61
        @test lebeda_lo(P, Eg, refit_sq_loss_width; options = four_trials, rng_seed = 1).updates ==
              1 + 4 * (2 + 4)                                                  # 25
        @test lebeda_iterlo(P, Eg, refit_sq_loss_width; rng_seed = 1).updates == 1 + 4          # 5
        # the declared schedule is the ladder the C++ runs: one solve per width
        @test lebeda_iterlo(P, Eg, refit_sq_loss_width; rng_seed = 1).updates ==
              length(lsq_sq_loss_widths(PRESET_REFERENCE, refit_sq_loss_width))
        # From a perturbed seed stages may gate out (< min_sample_size inliers
        # at a rung) — the measured count never exceeds the closed form.
        @test lebeda_lo(P, E0, refit_sq_loss_width; rng_seed = 1).updates <= 61
        @test lebeda_lo(P, E0, refit_sq_loss_width; options = four_trials, rng_seed = 1).updates <= 25
        @test lebeda_iterlo(P, E0, refit_sq_loss_width; rng_seed = 1).updates <= 5
    end

    @testset "determinism (bitwise repeat)" begin
        for f in (lebeda_lo, lebeda_iterlo), seed in (0, 42)
            a = f(P, E0, refit_sq_loss_width; rng_seed = seed)
            b = f(P, E0, refit_sq_loss_width; rng_seed = seed)
            @test a.E == b.E                             # bitwise
            @test a.score == b.score
            @test a.updates == b.updates
        end
    end

    @testset "E-manifold validity of outputs" begin
        for r in (lebeda_lo(P, E0, refit_sq_loss_width; rng_seed = 3),
                  lebeda_iterlo(P, E0, refit_sq_loss_width; rng_seed = 3),
                  lebeda_lo(P, E0, refit_sq_loss_width; options = four_trials, rng_seed = 3),
                  lebeda_lo(P, E0, refit_sq_loss_width; options = PRESET_TR_INFORMATIVE, rng_seed = 3))
            if e_err(r.E, E0) > 1e-12          # refined models (seed is E-valid by construction)
                s = svdvals(r.E)
                @test s[3] < 1e-12                           # rank 2
                @test isapprox(s[1], s[2]; rtol = 1e-9)      # equalized singular values
                @test isapprox(norm(r.E), 1.0; rtol = 1e-9)  # unit Frobenius output
            end
        end
    end

    @testset "refinement improves a perturbed seed" begin
        for δ in (0.05, 0.15)
            E0δ = perturb_seed(R, t, δ, MersenneTwister(100 + round(Int, 1000δ)))
            seed_err = e_err(E0δ, E_gt)
            r_lo = lebeda_lo(P, E0δ, refit_sq_loss_width; rng_seed = 5)
            r_it = lebeda_iterlo(P, E0δ, refit_sq_loss_width; rng_seed = 5)
            @test e_err(r_lo.E, E_gt) < seed_err
            @test e_err(r_it.E, E_gt) < seed_err
            @test e_err(r_lo.E, E_gt) < 0.05             # near-GT recovery
        end
    end

    @testset "score semantics (MSAC at sq_loss_width, seed included)" begin
        r = lebeda_lo(P, E0, refit_sq_loss_width; rng_seed = 9)
        # score = Σ min(r², sq_loss_width) of the returned model, and never above the seed's
        seed_score = sum(min.(sampson²(P, E0), refit_sq_loss_width))
        @test r.score <= seed_score + 1e-12
        @test isapprox(r.score, sum(min.(sampson²(P, r.E), refit_sq_loss_width)); rtol = 1e-9)
    end

    @testset "fundamental model (:F)" begin
        # In normalized coords the GT essential matrix is also the GT F.
        E0δ = perturb_seed(R, t, 0.08, MersenneTwister(21))
        a = lebeda_lo(P, E0δ, refit_sq_loss_width; model = :F, rng_seed = 6)
        b = lebeda_lo(P, E0δ, refit_sq_loss_width; model = :F, rng_seed = 6)
        @test a.E == b.E && a.updates == b.updates       # determinism
        s = svdvals(a.E)
        @test s[3] < 1e-12                               # rank-2 manifold
        @test s[2] > 1e-6                                # genuinely rank 2, not 1
        @test isapprox(norm(a.E), 1.0; rtol = 1e-9)
        @test e_err(a.E, E_gt) < e_err(E0δ, E_gt)        # refinement
        r_it = lebeda_iterlo(P, E0δ, refit_sq_loss_width; model = :F, rng_seed = 6)
        @test e_err(r_it.E, E_gt) < e_err(E0δ, E_gt)
        @test lebeda_lo(P, Matrix(E_gt), refit_sq_loss_width; model = :F, rng_seed = 1).updates ==
              1 + 10 * (2 + 4)                           # same update arithmetic
    end

    @testset "homography model (:H)" begin
        # Plane-induced homography scene (normalized coords) + outliers.
        rngh = MersenneTwister(31)
        H_gt = [1.0 0.02 0.1; -0.03 0.95 -0.05; 0.05 -0.02 1.0]
        H_gt /= norm(H_gt)
        nh = 100
        Ph = Matrix{Float64}(undef, 4, nh + 40)
        for i in 1:nh
            x = [0.8 * (rand(rngh) - 0.5), 0.8 * (rand(rngh) - 0.5), 1.0]
            y = H_gt * x
            Ph[:, i] .= (x[1], x[2], y[1] / y[3] + 0.002 * randn(rngh),
                         y[2] / y[3] + 0.002 * randn(rngh))
        end
        for i in nh+1:nh+40
            Ph[:, i] .= 0.8 .* (rand(rngh, 4) .- 0.5)
        end
        # Seed within the loss width's consensus basin: at 0.05 perturbation the
        # seed catches no inliers at all (classical LO with an off-scale loss width
        # legitimately returns the seed / a spurious-cluster model).
        H0 = H_gt + 0.008 * randn(MersenneTwister(32), 3, 3)
        H0 /= norm(H0)
        homography_sq_loss_width = 1e-4
        a = lebeda_lo(Ph, H0, homography_sq_loss_width; model = :H, rng_seed = 7)
        b = lebeda_lo(Ph, H0, homography_sq_loss_width; model = :H, rng_seed = 7)
        @test a.E == b.E && a.updates == b.updates       # determinism
        s = svdvals(a.E)
        @test s[3] > 1e-8                                # nonsingular
        @test isapprox(norm(a.E), 1.0; rtol = 1e-9)
        @test e_err(a.E, H_gt) < e_err(H0, H_gt)         # refinement
        @test e_err(a.E, H_gt) < 0.01                    # near-GT recovery
        r_it = lebeda_iterlo(Ph, H0, homography_sq_loss_width; model = :H, rng_seed = 7)
        @test e_err(r_it.E, H_gt) < e_err(H0, H_gt)
        # H update arithmetic identical (fits are DLT with min_sample_size 4)
        @test lebeda_lo(Ph, Matrix(H_gt), homography_sq_loss_width; model = :H, rng_seed = 1).updates ==
              1 + 10 * (2 + 4)
        @test_throws ArgumentError lebeda_lo(Ph, H0, homography_sq_loss_width; model = :Q)
    end

    @testset "base_mask override" begin
        # GT-inlier mask (diagnostic hook) — runs and stays deterministic.
        m = sampson²(P, E_gt) .< refit_sq_loss_width
        @test count(m) >= 8
        a = lebeda_lo(P, E0, refit_sq_loss_width; rng_seed = 4, base_mask = m)
        b = lebeda_lo(P, E0, refit_sq_loss_width; rng_seed = 4, base_mask = m)
        @test a.E == b.E && a.updates == b.updates
        @test svdvals(a.E)[3] < 1e-12
        # A too-small mask degrades gracefully (init fit only, incumbent kept).
        tiny = falses(size(P, 2)); tiny[1:4] .= true
        r = lebeda_lo(P, E0, refit_sq_loss_width; rng_seed = 4, base_mask = collect(tiny))
        @test r.updates == 1 && all(isfinite, r.E)
    end
end
