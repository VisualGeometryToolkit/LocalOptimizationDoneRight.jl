# =============================================================================
# The lift core (src/lift/lift_core.jl): the z-block kinds against a dense
# joint solve, the lift's own state (LiftState) over VisualGeometryToolkitCore's chart
# rows (RowsWorkspace), cubic Hermite interpolation and TabulatedLift. Moved
# from VisualGeometryToolkitCore's lift_zblock_kinds item with the lift core.
# =============================================================================
import VisualGeometryToolkitCore as VgtkCore
using Test, Random, LinearAlgebra, StaticArrays
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: RowsWorkspace, sq_loss_width, lift_wmax, lift_conjugate, lift_zblock
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LiftState, lift_state, JointGaussNewton, WelschConvexNewton, TabulatedLift,
    tabulate!, lift_window, lift_raw_window, cubic_hermite, _lift_hq_increment!, _update_lift_z!,
    _convex_newton_curvature

@testset "lift core: z-block kinds, LiftState, TabulatedLift" begin

# A dense reference: the FULL joint (θ, z) system of one iteration, solved
# without the Schur reduction, for codim-C rows (C rows per point). Per
# point i the kind supplies the θθ weight aᵢ, the coupling weight bᵢ (θz
# block bᵢ·Jᵢᵀrᵢ), the z pivot hᵢ and the gradients (gθᵢ·Jᵢᵀrᵢ, gzᵢ); the
# θθ block carries the solver's 1e-9 damping.
function _dense(J, r, coef, D, C)
    n = length(r) ÷ C
    H = zeros(D + n, D + n); g = zeros(D + n)
    for i in 1:n
        a, b, h, gθ, gz = coef(i)
        rows = (C * (i - 1) + 1):(C * i)
        Ji = J[rows, :]; Jr = Ji' * r[rows]
        H[1:D, 1:D] .+= a .* (Ji' * Ji)
        H[1:D, D + i] .= b .* Jr; H[D + i, 1:D] .= b .* Jr
        H[D + i, D + i] = h
        g[1:D] .+= gθ .* Jr; g[D + i] = gz
    end
    for k in 1:D
        H[k, k] += 1.0e-9
    end
    return -(H \ g)
end
# The codim-C rows (J, r) — VisualGeometryToolkitCore's RowsWorkspace — and the lift's
# own state holding z.
function _ws(J, r, z, D, C)
    rws = RowsWorkspace{D, C}(length(z))
    copyto!(rws.J, J); copyto!(rws.r, r)
    ls = LiftState{D}(length(z))
    copyto!(ls.z, z)
    return rws, ls
end
rsq(r, i, C) = sum(abs2, r[(C * (i - 1) + 1):(C * i)])

rng = MersenneTwister(3)
D = 5; n = 12
μ = 1.0e-3
loss = deploy(WelschShape(), 0.04; scale_multiple = 1.5)
c2 = sq_loss_width(loss)
z0 = sqrt.(0.2 .+ 0.7 .* rand(rng, n))                # inside the window: no clamp

for C in (1, 2)
    J = randn(rng, C * n, D); r = 0.3 .* randn(rng, C * n)
    @testset "codim $C — Gauss–Newton z-block: Schur step == dense joint solve" begin
        rws, ls = _ws(J, r, z0, D, C)
        Δθ = _lift_hq_increment!(rws, ls, loss, μ, n, nothing)
        ref = _dense(J, r, i -> begin
            w = z0[i]^2; s = rsq(r, i, C)
            rinv2, hreg = lift_zblock(loss, w)
            (w, z0[i], s + hreg + μ, w, z0[i] * (s - rinv2))
        end, D, C)
        @test Δθ ≈ ref[1:D] rtol = 1e-8
        _update_lift_z!(rws, ls, Δθ, loss, n, nothing)
        @test ls.z ≈ clamp.(z0 .+ ref[(D + 1):end], sqrt(1e-9), 1.0) rtol = 1e-8
        # the default kind IS the Gauss–Newton one
        Δθ2 = _lift_hq_increment!(_ws(J, r, z0, D, C)..., loss, μ, n, nothing; zblock = JointGaussNewton())
        @test Δθ2 == Δθ
    end

    @testset "codim $C — Welsch convexified Newton: Schur step == dense joint solve" begin
        rws, ls = _ws(J, r, z0, D, C)
        Δθ = _lift_hq_increment!(rws, ls, loss, μ, n, nothing; zblock = WelschConvexNewton())
        ref = _dense(J, r, i -> begin
            zi = z0[i]; w = zi^2; s = rsq(r, i, C)
            zz = 2s + 4c2 * (1 + log(zi))
            (2w, 4zi, max(zz, 8s) + μ, 2w, 2zi * (s + 2c2 * log(zi)))
        end, D, C)
        @test Δθ ≈ ref[1:D] rtol = 1e-8
        _update_lift_z!(rws, ls, Δθ, loss, n, nothing; zblock = WelschConvexNewton())
        @test ls.z ≈ clamp.(z0 .+ ref[(D + 1):end], sqrt(1e-9), 1.0) rtol = 1e-8
        # its second-order terms are Welsch's: another shape is refused
        @test_throws ArgumentError _lift_hq_increment!(
            _ws(J, r, z0, D, C)..., deploy(GemanMcclureShape(), 0.04; scale_multiple = 1.0), μ, n, nothing;
            zblock = WelschConvexNewton())
    end
end

@testset "LiftState: the lift's own buffers, one per (task, size)" begin
    ls = LiftState{D}(n)
    @test length(ls.z) == length(ls.dvec) == length(ls.gzv) == n
    @test size(ls.Hbuf) == (D, D) && length(ls.gbuf) == D
    @test lift_state(Val(D), n) === lift_state(Val(D), n)
    @test lift_state(Val(D), n) !== lift_state(Val(D), n + 1)
    @test lift_state(Val(D), n) !== lift_state(Val(D + 1), n)
    @test lift_state(Val(D), n) isa LiftState{D}
    @test fetch(Threads.@spawn lift_state(Val(D), n)) !== lift_state(Val(D), n)   # task-local
end

@testset "cubic_hermite interpolates values and slopes" begin
    f(x) = x^3 - 2x^2 + 0.5x; df(x) = 3x^2 - 4x + 0.5     # a cubic is reproduced exactly
    x0, h = 0.3, 0.7
    for u in (0.0, 0.25, 0.5, 1.0)
        @test cubic_hermite(f(x0), df(x0), f(x0 + h), df(x0 + h), u, h) ≈ f(x0 + u * h) rtol = 1e-13
    end
end

@testset "TabulatedLift reproduces a closed-form conjugate" begin
    # Welsch: ω(x) = exp(−x/c²), w_max = 1, κ²(w) = c²(w ln w − w + 1).
    # The node values are trapezoid sums, so the table is second order in
    # the (log-)grid spacing: measured at M = 256, ≤ 0.5% on κ², ≤ 0.3% on
    # r²(w̄) and ≤ 0.06% on hreg over w̄ ∈ [1e-4, 0.8].
    tab = TabulatedLift(256)
    @test tabulate!(tab, x -> (e = exp(-x / c2); (e, -e / c2))) == 1.0
    @test lift_wmax(tab) == 1.0
    lo, hi = lift_window(tab)
    @test lo ≈ 1e-9 rtol = 1e-12
    @test hi ≈ 1 - 1e-9 rtol = 1e-12
    @test lift_window(loss) == (1.0e-9, 1.0)
    @test all(lift_raw_window(tab) .≈ lift_wmax(tab) .* lift_window(tab))
    for w̄ in (1e-4, 1e-2, 0.2, 0.5, 0.8)
        @test lift_conjugate(tab, w̄) ≈ lift_conjugate(loss, w̄) rtol = 1e-2
        rt, ht = lift_zblock(tab, w̄); rk, hk = lift_zblock(loss, w̄)
        @test rt ≈ rk rtol = 5e-3
        @test ht ≈ hk rtol = 5e-3
    end
    # γ scales the conjugate; a warm rebuild after a small change lands on the cold one
    tabγ = TabulatedLift(256; γ = 2.0)
    tabulate!(tabγ, x -> (e = exp(-x / c2); (e, -e / c2)))
    @test lift_conjugate(tabγ, 0.3) ≈ 2 * lift_conjugate(tab, 0.3) rtol = 1e-12
    c2b = 1.05 * c2
    cold = TabulatedLift(256); tabulate!(cold, x -> (e = exp(-x / c2b); (e, -e / c2b)))
    tabulate!(tab, x -> (e = exp(-x / c2b); (e, -e / c2b)); warm = true)
    @test tab.xg ≈ cold.xg rtol = 1e-10
    # a TabulatedLift is a loss for the Gauss–Newton z-block, at every codimension
    for C in (1, 2)
        J = randn(rng, C * n, D); r = 0.3 .* randn(rng, C * n)
        Δθt = _lift_hq_increment!(_ws(J, r, z0, D, C)..., cold, μ, n, nothing)
        Δθk = _lift_hq_increment!(_ws(J, r, z0, D, C)..., deploy(WelschShape(), 0.04 * 1.05; scale_multiple = 1.5), μ, n, nothing)
        @test Δθt ≈ Δθk rtol = 2e-2
    end
end

# The convexified Newton z-block reads Welsch's conjugate curvature (the
# constant c²) and refuses every other shape (moved from VisualGeometryToolkitCore's
# conjugate_curvature item; the curvature itself is VGC's shape math).
@testset "the convexified Newton z-block's curvature" begin
    loss = deploy(WelschShape(), 0.04; scale_multiple = 1.5)
    @test _convex_newton_curvature(loss, 0.3) == VgtkCore.sq_loss_width(loss)
    @test_throws ArgumentError _convex_newton_curvature(deploy(CauchyShape(), 0.04; scale_multiple = 1.5), 0.3)
end
end
