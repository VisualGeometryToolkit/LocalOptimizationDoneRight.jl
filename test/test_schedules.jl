# =============================================================================
# The LO continuation schedules (src/lift/schedules.jl): the LoSchedule
# contract, the μ-ladder's converged-rung mode and its accessor, and the ladder
# each GNC graduation family takes. Moved from VisualGeometryToolkitCore's
# lo_schedules item (its shape-math testsets stay there) with the schedules.
# =============================================================================
using Test
using VisualGeometryToolkitCore
using VisualGeometryToolkitCore: deploy, WelschShape, GemanMcclureShape, TLSShape
using LocalOptimizationDoneRight
using LocalOptimizationDoneRight: LoSchedule, NoSchedule, MuLadder, GeometricAnneal, gnc_schedule, schedule_init,
    scale_mult, advance!, isterminal, with_converged_rung, n_rungs

@testset "LO schedules" begin
@testset "LoSchedule contracts" begin
    @testset "NoSchedule" begin
        st = schedule_init(NoSchedule(), 1.0, 25)
        @test scale_mult(st) == 1.0
        @test isterminal(st)
        advance!(st, true)            # no-op, never throws
        @test isterminal(st; open = false)
    end

    @testset "MuLadder :down (GM/Welsch) — stall-early advance, terminal at μ=1" begin
        sched = MuLadder(1.4)
        μ0 = 37.0; max_iter = 25
        st = schedule_init(sched, μ0, max_iter)
        # rung split exactly as GncIrls: nr = ceil(log μ0/log f)+1, rung_len = ⌊25/nr⌋
        nr = ceil(Int, log(μ0) / log(1.4)) + 1
        @test n_rungs(sched, μ0) == nr
        @test st.rung_len == max(1, floor(Int, max_iter / nr))
        @test scale_mult(st) == μ0
        @test !isterminal(st)
        # a stalled step at a non-terminal rung ADVANCES the schedule (never ends it)
        advance!(st, true)
        @test scale_mult(st) == μ0 / 1.4
        # schedule completion: advancing with stall=true every step reaches terminal
        k = 0
        while !isterminal(st) && k < 1000
            advance!(st, true); k += 1
        end
        @test isterminal(st) && scale_mult(st) == 1.0
        @test k <= nr + 1
        # μ0 ≤ 1 ⇒ single terminal rung
        @test n_rungs(sched, 0.5) == 1
        @test isterminal(schedule_init(sched, 0.5, 25))
        # a :down ladder ends at μ = 1 and never reads `cap`: a finite one is refused
        @test_throws ArgumentError MuLadder(1.4; cap = 5.0)
        @test MuLadder(1.4; cap = Inf).cap == Inf
    end

    @testset "MuLadder :up (TLS) — band-open gating, terminal at cap or closed band" begin
        cap = 1.0e6
        sched = MuLadder(1.4; direction = :up, cap = cap)
        μ0 = 0.02
        st = schedule_init(sched, μ0, 25)
        @test !isterminal(st; open = true)
        @test isterminal(st; open = false)       # empty middle band ⇒ terminal surrogate
        # closed band freezes μ (no graduation past an empty band)
        advance!(st, true; open = false)
        @test scale_mult(st) == μ0
        # open band graduates up to the cap; scale_mult is monotone toward terminal
        prev = scale_mult(st); k = 0
        while !isterminal(st; open = true) && k < 200
            advance!(st, true; open = true)
            @test scale_mult(st) >= prev
            prev = scale_mult(st); k += 1
        end
        @test scale_mult(st) == cap
        # μ0 ≥ cap ⇒ single rung
        @test n_rungs(sched, cap) == 1
    end

    @testset "GeometricAnneal — stall JUMPS to terminal (the D1 semantics)" begin
        st = schedule_init(GeometricAnneal(2.0), 1.0, 25)
        @test scale_mult(st) == 2.0^2.0          # 2^oct at t=1
        @test !isterminal(st)
        advance!(st, false)
        @test scale_mult(st) == 2.0^(2.0 * (1.0 - 1 / 24))
        # stall at t < T: the schedule jumps to terminal, multiplier = exactly 1
        advance!(st, true)
        @test isterminal(st)
        @test scale_mult(st) == 1.0
        # advancing past terminal stays terminal
        advance!(st, false)
        @test isterminal(st) && scale_mult(st) == 1.0
        # T ≤ 1 degenerates to the static schedule
        st1 = schedule_init(GeometricAnneal(2.0), 1.0, 1)
        @test scale_mult(st1) == 1.0 && isterminal(st1)
    end
end

@testset "MuLadder converged-rung mode (Yang–Carlone-faithful)" begin
    sched = MuLadder(1.4; converged_rung = true)
    st = schedule_init(sched, 37.0, 25)
    # rung-budget advances NEVER fire: many non-stalled steps leave μ untouched
    for _ in 1:10_000
        advance!(st, false)
    end
    @test scale_mult(st) == 37.0
    # ONLY stalls advance; every stall moves exactly one rung
    advance!(st, true)
    @test scale_mult(st) == 37.0 / 1.4
    k = 1
    while !isterminal(st) && k < 1000
        advance!(st, true); k += 1
    end
    @test isterminal(st) && scale_mult(st) == 1.0
    @test k == n_rungs(MuLadder(1.4), 37.0) - 1   # one stall per rung to terminal
    # parity mode unchanged (default flag false)
    stp = schedule_init(MuLadder(1.4), 37.0, 25)
    @test stp.rung_len == max(1, floor(Int, 25 / n_rungs(MuLadder(1.4), 37.0)))
end

@testset "MuLadder: with_converged_rung" begin
    s = MuLadder(1.4; direction = :up, cap = 1.0e4)
    @test with_converged_rung(s, true) == MuLadder(1.4; direction = :up, cap = 1.0e4, converged_rung = true)
    @test with_converged_rung(with_converged_rung(s, true), false) == s
end

# The ladder direction is the whole reason BandAnnealed is its own GNC family
# (VisualGeometryToolkitCore's GNC surrogate facet; the ladders are this package's).
@testset "gnc_schedule: the ladder of each graduation family" begin
    cbar2 = 2.3
    kW = deploy(WelschShape(), cbar2; scale_multiple = 1.0)
    kG = deploy(GemanMcclureShape(), cbar2; scale_multiple = 1.0)
    kT = deploy(TLSShape(), cbar2; scale_multiple = 1.0)
    @test gnc_schedule(kT, 1.4).direction === :up
    @test gnc_schedule(kW, 1.4).direction === :down
    @test gnc_schedule(kG, 1.4).direction === :down
    @test gnc_schedule(kW, 1.4) isa LoSchedule
end
end
