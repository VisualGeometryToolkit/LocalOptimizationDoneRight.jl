# =============================================================================
# The paper's local-optimization strategies (moved from RobustVisualGeometry's
# scoring_glue.jl): the half-quadratic lifts HQ{K} and their research
# variants, GNC, the Student-t + uniform IRLS and its score-matched BCD, the
# Barron arms — their types, identity, width modes, the strategy registry
# (`LO_TAGS`) and the one keyword constructor.
#
# They implement VisualGeometryCore's local-optimization contract
# (`locally_optimize!`, `lo_width`, `with_width`, `deployed_scale_multiple`) on
# RobustVisualGeometry's problems and its public posterior-weight iteration.
# =============================================================================

"""
    StudentTUniform <: AbstractLocalOptimization

The paper's **Stu-tU-IRLS**: posterior-weighted IRLS under the Student-t +
uniform mixture (the same model family as the profile-marginal score).
Computes posterior inlier probabilities from the marginal score partition,
uses them as soft weights for a WLS refit, re-scores, and iterates over a
fixed Student-t + uniform likelihood. Self-scaling: it re-estimates its own
scale each iteration (contrast with the consensus-anchored `Irls{K}`/`HQ{K}`/
`Gnc{S}` strategies, whose loss width is frozen at `scale_multiple·ŝ` from the
consensus set).

It needs the scorer's uniform outlier model (`outlier_halfwidth`).

# Fields
- `max_iter::Int=5`: Max IRLS iterations per hypothesis
"""
struct StudentTUniform <: AbstractLocalOptimization
    max_iter::Int
end

# Construction-time admission: a shape the mechanism cannot run is refused
# HERE, rather than surfacing mid-RANSAC as a MethodError from a VGC internal
# the caller never wrote. The admissible set is read off VGC's own traits.
function _mechanism_admits_shape(strategy, ::Type{K}) where {K}
    applicable(K) || throw(
        ArgumentError(
            "$strategy: $K is not a zero-argument shape tag (a Barron " *
                "shape carries its α — use BarronHQ or BarronAdaptive)"
        )
    )
    return nothing
end
function _hq_admits_shape(::Type{K}) where {K}
    _mechanism_admits_shape("HQ{$K}", K)
    liftable(K()) || throw(
        ArgumentError(
            "HQ{$K}: $K has no half-quadratic lift (VGC `liftable($K()) === false`)"
        )
    )
    return nothing
end

"""
    StuTuBCD <: AbstractLocalOptimization

Exact same-objective refinement for [`StudentTUniformScoring`](@ref): block-coordinate
ascent **on the scoring objective S itself**. Alternates

  (model)      θ⁺ = argmin_θ Σ_{i∈I} rᵢ(θ)²        — hard-inlier least squares
  (partition)  I⁺ = argmax_I  S(θ⁺, I)             — the score's own sort-and-sweep

to convergence. Every step is non-decreasing in S: the model step lowers
`RSS_I` with all other score terms fixed (so S rises), and the partition step is
the score's exact argmax over partitions. Unlike [`StudentTUniform`](@ref)
(soft, score-*derived* responsibilities under a related t/uniform mixture — NOT
the Jeffreys-collapsed hard-partition objective) and the Welsch-HQ lift
(a *different* objective optimized jointly over auxiliary weights), this is the
strict `same-objective' baseline: exact score monotonicity, hard partition.
Expected to be very monotone but narrow-basined — correspondences excluded by
the current partition exert no force on the pose (`RSS_I` sees only I).

# Fields
- `max_iter::Int=25`: max block-coordinate sweeps per hypothesis
- `tol::Float64=0.0`: minimum score increase to keep iterating
"""
struct StuTuBCD <: AbstractLocalOptimization
    max_iter::Int
    tol::Float64
end

"""
    HQ{K<:AbstractLossShape} <: AbstractLocalOptimization

Half-quadratic *lifted* local optimization on loss `K` (Zach 2014): the **genuine joint-(θ,z) Gauss-Newton** on the lifted
residual `(zᵢ·rᵢ, κ(zᵢ²))` with the loss's closed-form Geman–Reynolds
regularizer (`lift_zblock`, VGC's loss family). Per-point weight `zᵢ` is a
free variable, initialized LARGE (all-inlier = smoothed cost) and **evolved
jointly with θ**, Schur-eliminating `Δz` — this broadens the basin, escaping a
poor seed where the static [`Irls`](@ref)/[`StudentTUniform`](@ref) is trapped,
*without* annealing or quadrature. ONE code path for every loss AND every
problem (`ManifoldLiftHQ` on VisualGeometryCore's chart-rows contract,
lift/lifts.jl); `K` contributes only its closed-form z-block
quantities and tracked cost. Implemented for every liftable problem (the
`MinimalSolveProblem` family: its lift provider supplies the chart).

The loss width is frozen at setup by the width mode (VisualGeometryCore's
`loss_at`): at the consensus set's Student-t scale `ŝ` the `scale_multiple` is
read in the loss's OWN currency (RobustVisualGeometry's `plain_scale_multiple`,
shared with `Irls{K}`), which
converts it to the plain multiple that goes in a deployment's `scale_multiple`
slot — the loss width is then `scale_multiple·ŝ` and `sq_loss_width` is
`scale_multiple²·ŝ²`, with the multiple and the noise variance stored apart and
never multiplied into a stored width:

- `K = WelschShape`: `loss_width = scale_multiple·ŝ` (1.5 was the pre-anchoring point)
- `K = SmoothTLSShape`: hard cutoff `loss_width = scale_multiple·ŝ` (historically
  2.0 = the statistically natural 2σ cutoff; no width follows the scorer's
  decision point). Default `max_iter = 40` (historical ψ̂ arm).
- `K ∈ {GemanMcclureShape, CauchyShape}`: the shared half-weight ablation currency
  `loss_width = decision_width(K(), scale_multiple·ŝ)` (historically 1.5·√ln2 —
  the deployed Welsch arm's evidence depth). NOTE the roster's GM arm keeps its
  CONSTRUCTOR-level convention `scale_multiple = κ·√ln2` (κ the shared Welsch
  grid value).

# Fields
- `max_iter::Int`: max joint-GN iterations (25; 40 for `SmoothTLSShape`)
- `μ::Float64=1e-9`: Gauss-Newton damping
- `init::Symbol=:flat`: z₀ policy — `:flat` (all-in, default) | `:posterior`
  (soft seed weights) | `:consensus` (hard r½ mask)
- `width::W`: the width mode (`scale_multiple = m` in the per-K currency above,
  `loss_width = w`, or neither: follow the scorer), as [`Irls`](@ref)
"""
struct HQ{K <: AbstractLossShape, W} <: AbstractLocalOptimization
    max_iter::Int
    μ::Float64
    init::Symbol
    width::W
end
HQ{K}(max_iter::Integer, μ::Real, init::Symbol, width::W) where {K, W} = HQ{K, W}(Int(max_iter), Float64(μ), init, width)
"""
    WelschHQNewton(; scale_multiple, max_iter=25, μ=1e-9)

Welsch half-quadratic lift refined with the **convexified Newton** joint-(θ,z) step
(Zach & Bourmaud, ECCV 2018, Eq. 15) instead of the Gauss-Newton step of
[`HQ{WelschShape}`](@ref HQ). Identical fixed-scale setup (`loss_width =
scale_multiple·ŝ` from the seed partition); the only difference is the
second-order z-block with the convexification
`h_z = max(2r² + 4·loss_width²·(1+ln z), 8r²)`. Intended as the A/B partner of the GN lift — it
should match on easy seeds and (per the paper) reach better minima on hard,
barrier-crossing seeds. `EssentialProblem` only.
"""
struct WelschHQNewton{W} <: AbstractLocalOptimization
    max_iter::Int
    μ::Float64
    width::W
end


"""
    WelschHQEcm <: AbstractLocalOptimization

Ablation sibling of [`HQ{WelschShape}`](@ref HQ): the **same closed-form Welsch
joint-(θ,z) lift**, but the loss width `scale_multiple·√ŝ²` is **re-estimated each iteration**
by the same Student-t + uniform ECM the mixture uses (`_mix_ecm`), instead of fixed
at the seed. Closed-form κ² ⇒ no LUT, so the only added cost is the O(n) ECM sweep.
Kept a separate LO strategy so fixed-vs-ECM scale can be ablated head-to-head.

# Fields
- `max_iter::Int=25`: max joint-GN iterations
- `scale_multiple::Float64`: the loss width as a multiple of ŝ (`scale_multiple·√ŝ²`, ŝ² re-estimated per iter)
- `μ::Float64=1e-9`: Gauss-Newton damping
"""
struct WelschHQEcm <: AbstractLocalOptimization
    max_iter::Int
    scale_multiple::Float64
    μ::Float64
end

"""
    BarronHQ(α; scale_multiple, max_iter=25, μ=1e-9)

The α-DIAL lift (smooth-and-lift 3-ii): the same genuine joint-(θ,z)
half-quadratic lift as [`HQ`](@ref) with the Barron family
loss at fixed shape α, standardized in the FIXED-CORE-WIDTH currency —
the facet-B Barron loss width is scale_multiple·ŝ/√2, which holds the near-zero
(Gaussian-core) curvature IDENTICAL across every α, so the dial isolates
tail steepness (retirement profile) only. Anchor identities (mandatory
gates, lift_losses_tests.jl): α → −∞ runs the SAME iteration as
`HQ{WelschShape}(; scale_multiple)`; α = −2 matches the GM lift and α = 0 the Cauchy
lift at their convention-mapped scales. Runs on the generic ManifoldLiftHQ
driver, so on every liftable problem.
"""
struct BarronHQ{W} <: AbstractLocalOptimization
    α::Float64
    max_iter::Int
    μ::Float64
    width::W
end


# =============================================================================
# GmHqEps — Geman–McClure lift (soft-tailed sibling), ε-parameterized
# =============================================================================
#
# Soft-tailed redescender with a closed-form lift — see `GemanMcclureShape` in
# VGC's loss family (w = loss_width: r²(w̄)=w²(w̄^{-1/2}−1), CONSTANT z-block
# Hessian h_reg=w²). Steeper core than ψ̂ (≈1−2s/w² near 0) AND a soft
# polynomial tail (~w⁴/s², never 0) — the "tight + inclusive" profile. Tested
# against Welsch (soft exp tail, 1.91) and ψ̂ (hard cut, 2.20) in the SHARED
# half-weight currency r_½/ŝ. loss_width = scale_multiple·ŝ (a `ScaleMultiple`
# width mode), an absolute `LossWidth`, or the scorer's decision point (no
# width). This strategy is the ε-parameterized arm; the half-weight-standardized
# ablation arm is `HQ{GemanMcclureShape}`. Runs on the generic ManifoldLiftHQ driver, so on
# every liftable problem (`_manifold_hq!`, lift/lifts.jl).

struct GmHqEps{W} <: AbstractLocalOptimization
    max_iter::Int
    μ::Float64
    width::W   # ScaleMultiple(m): loss_width = m·ŝ (half-weight radius r_½ = √(√2 − 1)·loss_width ≈ 0.6436·loss_width)
end

"""
    Gnc{S<:AbstractLocalOptimization} <: AbstractLocalOptimization

Graduated-non-convexity WRAPPER: canonical Yang–Carlone GNC (RA-L 2020) with
the Black–Rangarajan surrogate weights, graduating the objective of the wrapped
static strategy `S` — the paper's three GNC baselines for the continuation
family:

- `Gnc{Irls{WelschShape}}` — GNC-W (annealed-width Welsch)
- `Gnc{Irls{TLSShape}}`    — GNC-TLS (Black–Rangarajan band surrogate of the
  HARD truncation; `TLSShape` is the hard-TLS facet tag of VGC's loss family)
- `Gnc{Irls{GemanMcclureShape}}` — GNC-GM (μ-convexified GM)

The type parameter ADMITS any strategy (`Gnc{HQ{K}}` — graduation OVER the
lift, a composite `:gnc ∘ :hq` mechanism — and the `Resample{S}` wrapper are
NOT implemented here, the LO dispatch covers `Gnc{<:Irls}`
only). The GNC arms run through the same `locally_optimize!` contract as
every IRLS/lift strategy — one code path, one width resolution.

**Width** (VisualGeometryCore's `loss_at`): under `ScaleMultiple(m)` the
terminal (target) loss width is `c̄ = m·ŝ` with `ŝ` the consensus set's
Student-t scale (exactly the width the lifted loss arms freeze); under
`LossWidth(w)` it is `w`; with neither it follows the scorer's inlier
threshold. There is no plug-in scale bootstrap.

Variants and μ-schedules:

- `:gm` (GNC-GM) — surrogate ρ_μ(r) = μc̄²r²/(μc̄² + r²), weights
  `w = (μc̄²/(r² + μc̄²))² ≡ lift_weight(GM, r², μ·c̄²)`; μ₀ = 2·r²_max/c̄²
  (convex start from the SEED residual extreme), μ ← μ/factor per rung,
  clamp at μ = 1 (true GM) and spend the remaining budget there.
- `:welsch` (GNC-W) — annealed-WIDTH Welsch, c²_μ = μ·c̄², weights
  `w = exp(−r²/(μc̄²))`; μ₀ = r²_max/c̄² (every seed point starts ≥ e^{−1})
  or a numeric `entry = m` ⇒ μ₀ = max(m², 1) (entry-breadth dose axis), μ ← μ/factor,
  clamp at μ = 1 (target Welsch at c̄).
- `:tls` (GNC-TLS) — piecewise Black–Rangarajan band weights
  (`gnc_tls_weight`); μ₀ = c̄²/(2r²_max − c̄²) with the r²_max ≤ c̄²/2 guard
  (⇒ skip graduation, start effectively-hard), μ ← factor·μ, stop graduating
  once the middle band is empty or μ ≥ 1e6, then finish at the terminal
  surrogate.

Budget parity: TOTAL model updates across ALL rungs = `max_iter` (the shared
25-update LO cap; every GNC stage counts). Rung arithmetic is VGC `MuLadder`
(`budget = :converged` ⇒ converged-rung mode, `max_iter` a safety ceiling).
Rung advance is scheduled OR stall-early; termination is TERMINAL-only (the
373d0a6 semantics via the `LoSchedule` trait). Best-tracking is on the TARGET
loss (true TLS cost / true GM ρ / fixed-width Welsch cost at c̄) — graduation
shapes exploration only. Implemented for every liftable problem (the
`MinimalSolveProblem` family), like `HQ{K}`.
"""
struct Gnc{S <: AbstractLocalOptimization, W} <: AbstractLocalOptimization
    max_iter::Int        # TOTAL model-update budget across all rungs (parity: 25),
    # or the SAFETY CEILING under budget = :converged
    factor::Float64      # μ-schedule factor (canonical 1.4)
    entry::Float64       # entry-breadth policy: NaN = r_max (Yang–Carlone seed
    # extreme); numeric m = entry at m× target width, μ₀ = m²
    # (Welsch family only — smooth-and-lift dose axis 1)
    budget::Symbol       # :parity (rung budget split) | :converged (rung runs to
    # stall; Yang–Carlone-faithful)
    width::W             # target loss width c̄: ScaleMultiple(m) → m·ŝ | LossWidth | nothing (the scorer's)
end
Gnc{S}(max_iter::Integer, factor::Real, entry::Real, budget::Symbol, width::W) where {S, W} =
    Gnc{S, W}(Int(max_iter), Float64(factor), Float64(entry), budget, width)

# Deleting RVG's Symbol map also deleted the check it carried: it used to REFUSE
# a `Gnc{S}` the engine cannot graduate, naming the three that work. Without it
# the refusal surfaces mid-run as `MethodError: no method matching
# gnc_mu0(::NoSurrogate, …)` — a VGC-internal function in the user's face, from
# a call the user never wrote. State it at CONSTRUCTION instead, and read the
# admissible set off VGC's `gnc_surrogate` trait rather than re-listing it here
# (a re-listed map is what went stale in the first place).
_gnc_admits(::Type{<:Irls{K}}) where {K} = _gnc_admits_shape(K)
_gnc_admits(::Type{S}) where {S} = throw(
    ArgumentError(
        "Gnc{$S}: the GNC engine graduates `Irls{K}` only. (`Gnc{HQ{K}}` — " *
            "graduation OVER the lift, a composite :gnc ∘ :hq mechanism — is admitted " *
            "by the type but not implemented.)"
    )
)
function _gnc_admits_shape(::Type{K}) where {K}
    # BarronShape carries its α, so it is not a zero-arg tag and cannot be a
    # graduating shape; the one tag check runs before constructing one.
    _mechanism_admits_shape("Gnc{Irls{$K}}", K)
    gnc_surrogate(K()) isa NoSurrogate && throw(
        ArgumentError(
            "Gnc{Irls{$K}}: $K has no Black–Rangarajan surrogate to graduate " *
                "(VGC `gnc_surrogate($K()) === NoSurrogate()`). The engine graduates " *
                "WelschShape (GNC-W), TLSShape (GNC-TLS) and GemanMcclureShape (GNC-GM)."
        )
    )
    return nothing
end

# -----------------------------------------------------------------------------
# Identity of the loss-parametric strategies — read off the loss tag
# (RobustVisualGeometry's `strategy_loss`, which `Irls{K}` shares).
# -----------------------------------------------------------------------------
RobustVisualGeometry.strategy_loss(::Type{<:HQ{K}}) where {K} = K
RobustVisualGeometry.strategy_loss(::Type{<:Gnc{S}}) where {S} = strategy_loss(S)

VisualGeometryCore.lo_label(lo::Union{HQ, Gnc}) =
    loss_label(strategy_loss(lo)) * "-" * path_suffix(optimization_path(lo))
VisualGeometryCore.loss_family(lo::Union{HQ, Gnc}) = loss_family(strategy_loss(lo))

# The scale-multiple currency (RobustVisualGeometry's `plain_scale_multiple`,
# the one table): `HQ{K}` reads its `scale_multiple` in its loss's currency,
# as `Irls{K}` does; GNC is the ONE mechanism exception — Yang–Carlone's
# schedules are stated in the TARGET loss width c̄ = scale_multiple·ŝ for every
# surrogate, so a GNC `scale_multiple` is a width multiple whatever the shape
# (the GNC-GM arm is CV'd in that currency; a half-weight read would move it by
# 1/√(√2−1) ≈ 1.55).
VisualGeometryCore.deployed_scale_multiple(::HQ, shape, m::Float64, _s2, _scoring) = plain_scale_multiple(shape, m)
VisualGeometryCore.deployed_scale_multiple(::Gnc, _shape, m::Float64, _s2, _scoring) = m
# The fixed-core Barron dial: the facet-B width is scale_multiple·ŝ/√2.
VisualGeometryCore.deployed_scale_multiple(::BarronHQ, _shape, m::Float64, _s2, _scoring) = m / sqrt(2.0)

# The shape `fixed_width` hands the currency hook.
RobustVisualGeometry.deployed_shape(lo::Union{HQ, Gnc}) = strategy_loss(lo)()
RobustVisualGeometry.deployed_shape(lo::BarronHQ) = BarronShape(lo.α)

"""
    StuTuHQTabulated <: AbstractLocalOptimization

Half-quadratic lifted LO using the **exact** Student-t + uniform mixture loss
`ρ(r)=−log(π_in t_ν(r;ŝ²)+π_out(2a)^{−d})`. Same genuine joint-(θ,z) weight-lift
as [`HQ{WelschShape}`](@ref HQ), but the regularizer `κ²` — whose closed form is
transcendental for the mixture — is **tabulated per ECM iteration**: the monotone
weight `ω=u·w_resp` is inverted on a grid (`r²(w)=−κ²′(w)`) and cumulatively
integrated (`κ²(w)`). Scale `ŝ²` and mixing `π_in` are ECM/EM-updated each
iteration. `EssentialProblem` only.

The **lifting-regularizer strength** `γ` scales the down-weighting penalty `κ²` (a
GNC-style continuation knob): `γ>1` makes the lift more reluctant to switch points
off (softer z-block Hessian, `hreg ∝ 1/γ`), keeping it in a smoother, wider-basin
regime for better escape from a poor seed. Selection is always on the true `γ=1`
objective (best-tracking), so `γ` shapes only the exploration — hence a constant,
validated `γ` (rather than a schedule). `κ²` is built on a fine grid so `γ` is the
sole, explicit regularizer knob. On PT val the LO is **insensitive** to `γ` over
`[1,5]` (median 4.92–5.04°, within the basin-flip noise); `γ=2.5` is the robust
plateau choice (near the per-scene minima, non-edge).

# Fields
- `max_iter::Int=25`: max joint-GN iterations
- `γ::Float64=2.5`: lifting-regularizer strength (PT-val plateau; LO is γ-insensitive over [1,5])
- `μ::Float64=1e-9`: Gauss-Newton damping
- `lut_points::Int=32`: `κ²` grid resolution. The table is read by **cubic Hermite**
  interpolation using the exact node slopes `κ²′=−r²` (the stationarity condition),
  so 32 nodes match a ~1000-node *linear* table in accuracy at ~⅛ the per-iteration
  rebuild cost. `γ` remains the sole regularizer knob — grid coarseness is no longer
  an accuracy lever (the inflation trap of a coarse *linear* table is avoided).
"""
struct StuTuHQTabulated <: AbstractLocalOptimization
    max_iter::Int
    γ::Float64
    μ::Float64
    lut_points::Int
    patience::Int
end
# `patience`: consecutive non-improving ECM iters before the stagnation stop fires
# (the speed lever). `patience=typemax(Int)` ⇒ no early-stop (run to `max_iter`),
# which with a high `lut_points` recovers the accurate-math regime.

"""
    StuTuRegemm <: AbstractLocalOptimization

Half-quadratic LO for the same Student-t + uniform mixture loss as
[`StuTuHQTabulated`](@ref), but solved by **relaxed generalized
majorization-minimization** (ReGeMM; Zach & Le, ECCV 2020, §6.1) instead of the
joint weight-lift. Faithful to the paper's robust-estimation scheme: weights are
initialized **all-inlier** (`u≡1`) and inferred inexactly by *graduated
non-convexity*. Each round (i) ECM-updates `ŝ²,π_in` and rebuilds the `κ²` table,
(ii) sets `uᵢ = ω(rᵢ/σ)` — the touching weight at an inflated scale `σ≥1`, with `σ`
the largest value (by bisection) still meeting the diminishing-gap criterion
`J(θ,uⁿᵉʷ) ≤ η·J(θ) + (1−η)·J(θ,uᵒˡᵈ)`, `J(θ)=minₚ J(θ,u)`, then (iii) minimizes the
bound over the pose for the graduated weights (the weighted-Sampson refit,
Alg. 1's line-3 argmin), accepted only if it descends. `σ` anneals to 1
as the gap tightens, so this is weight-space GNC from the *smooth* init.

The monotone, convergent counterpart of the [`StuTuHQTabulated`](@ref) joint step.
Zach & Le report it favorable vs the joint HQ lift on bundle adjustment (truncated
quadratic); on 2-view essential the joint lift reaches a better optimum with a
lighter tail. `EssentialProblem` only.

# Fields
- `max_iter::Int=100`: number of ReGeMM rounds (one σ-graduation + one pose refit each)
- `η::Float64=0.5`: diminishing-gap fraction (Zach & Le use η=1/2; `η→1` ⇒ touching/standard MM = IRLS)
- `lut_points::Int=128`: `κ²` lookup-table resolution
"""
struct StuTuRegemm <: AbstractLocalOptimization
    max_iter::Int
    η::Float64
    lut_points::Int
    adapt_scale::Bool     # ECM (ŝ²,π) re-estimation per round; false ⇒ frozen at
    # the seed partition (the strict fixed-scale consistent
    # refiner — the travel-mechanism ablation's other arm)
end


# =============================================================================
# Barron-adaptive robust IRLS (Barron CVPR'19; Chebrolu et al. RA-L'21)
# =============================================================================

"""
    BarronAdaptive(; scale_multiple | loss_width, max_iter=25, α_min=-10.0,
                   truncation_multiple=10.0, n_sub=256)

Solver-matched ADAPTIVE-SHAPE robust IRLS: the identical
`PosteriorIrlsMethod`/`block_coordinate_descent!` machinery as [`StudentTUniform`](@ref) /
[`Irls{WelschShape}`](@ref Irls), with Barron's generalized loss ρ(r; α, loss_width)
(CVPR 2019) whose SHAPE α is re-estimated each iteration from the current
residuals by minimizing the truncated-partition negative log-likelihood of
Chebrolu et al. (RA-L 2021, Eq. 11-15): 1-D grid search over
α ∈ [α_min, 2], with `Z̃(α) = ∫_{-T}^{T} e^{-ρ(x, α, 1)} dx`, `T =
truncation_multiple` (the normaliser's domain, in units of the loss width). The
loss width is `scale_multiple·ŝ`, frozen at the seed partition's Student-t
scale — Chebrolu et al. fix the width for exactly the scale/shape confounding
our partition anchor resolves. `n_sub` caps the residual subsample used by the
α grid search (strided; the full set is used when n ≤ n_sub).

This is the "adaptive-static" cell of the loss taxonomy: the loss adapts
its shape within the solve (no lift, no graduation) — the strongest
representative of "why not adapt instead of lift?".
"""
struct BarronAdaptive{W} <: AbstractLocalOptimization
    max_iter::Int
    α_min::Float64
    truncation_multiple::Float64
    n_sub::Int
    width::W
end

# The squared loss width the Barron α-fit runs at, from the width mode:
# `ScaleMultiple(m)` → m²·ŝ², `LossWidth((m₀, s2))` → m₀²·s2 (the scale floored
# at eps), no width → the scorer's decision point, squared.
_barron_sq_width(lo::BarronAdaptive, cs, scoring, buf) = _barron_sq_width(lo.width, cs, scoring, buf)
_barron_sq_width(w::ScaleMultiple{Float64}, cs, _scoring, _buf) = w.value^2 * max(scale_s2(cs), eps())
_barron_sq_width(w::LossWidth{NTuple{2, Float64}}, _cs, _scoring, _buf) = w.value[1]^2 * max(w.value[2], eps())
_barron_sq_width(::Nothing, _cs, scoring, buf) = inlier_threshold(scoring, buf)^2


# The shape of one point of the α-fit grid: VGC's `BarronShape(α)` for α < 2,
# and at the grid's L2 endpoint α = 2 (which BarronShape excludes — not
# liftable) the Gaussian, its pointwise limit. The ONE statement of that
# endpoint for the loss, the weight and the normaliser below.
@inline _barron_grid_shape(α::Float64) = α == 2.0 ? GaussianShape() : BarronShape(α)

# The α-fit's loss and weight are VGC's at unit squared width (x² = r²/c²):
# `ρ(shape, x², 1)` (facet B, whose 2c² prefactor makes the Barron CVPR'19
# Eq. 16 unit loss `½ρ`) and `weight(shape, x², 1)` (w(0) = 1) — the HARDENED
# expm1/log1p forms, called at their site rather than renamed here.

# log Z̃(α) lookup on the canonical α grid — built lazily once per truncation_multiple T.
# Z̃(α) = ∫_{-T}^{T} e^{−½ρ(x², α)} dx is VisualGeometryCore's truncated
# normaliser `truncated_log_normaliser(shape, c² = 1, Δ = ½, T)` (adaptive quadrature over
# [0, T], doubled for the symmetric domain). Unit scale, so one table serves
# every c: log(c·Z̃) = log c + logZ̃_unit.
const _BARRON_ALPHA_GRID = collect(-10.0:0.1:2.0)
const _BARRON_LOGZ_CACHE = Dict{Float64, Vector{Float64}}()
function _barron_logZ_table(truncation_multiple::Float64)
    return get!(_BARRON_LOGZ_CACHE, truncation_multiple) do
        [truncated_log_normaliser(_barron_grid_shape(α), 1.0, 0.5, truncation_multiple) for α in _BARRON_ALPHA_GRID]
    end
end

"""
    BarronAdaptiveLikelihood <: AbstractWeightPolicy

Likelihood adapter for [`BarronAdaptive`](@ref). `update_nuisance!` is the
α-step (Chebrolu Alg. 1 step 1): grid-argmin over α of
`log Z̃(α) + mean ρ(rᵢ/c; α)` on the (strided) residual subsample.
`update_weights!` sets the Barron IRLS weights at the current (α, c).
Only the SHAPE α moves here; the WIDTH is frozen at construction from the
arm's `(scale_multiple, ŝ²)` pair (`sq_loss_width`) and is stored as its reciprocal because
the unit-scale α math divides by it.
"""
mutable struct BarronAdaptiveLikelihood <: AbstractWeightPolicy
    rws::PosteriorWeightState
    n::Int
    inv_sq_loss_width::Float64    # 1/(scale_multiple²·ŝ²) — a squared WIDTH, not a variance
    α::Float64
    α_lo_idx::Int                 # lower bound index into _BARRON_ALPHA_GRID
    logZ::Vector{Float64}
    stride::Int
end
function BarronAdaptiveLikelihood(
        rws::PosteriorWeightState, n::Int, width2::Float64,
        α_min::Float64, truncation_multiple::Float64, n_sub::Int
    )
    # n_sub ≥ n ⇒ stride 1: the FULL-SET α-fit (letter-faithful Chebrolu);
    # the default n_sub=256 strided subsample is the deployed fast path.
    lo_idx = findfirst(>=(α_min), _BARRON_ALPHA_GRID)
    return BarronAdaptiveLikelihood(
        rws, n, 1.0 / width2, 2.0, lo_idx === nothing ? 1 : lo_idx,
        _barron_logZ_table(truncation_multiple), max(1, n ÷ n_sub)
    )
end

function update_nuisance!(lh::BarronAdaptiveLikelihood)
    rws = lh.rws
    best = Inf; bestα = lh.α
    @inbounds for ai in lh.α_lo_idx:length(_BARRON_ALPHA_GRID)
        α = _BARRON_ALPHA_GRID[ai]
        sh = _barron_grid_shape(α)
        s = 0.0; m = 0
        for i in 1:lh.stride:lh.n
            s += VisualGeometryCore.ρ(sh, sq_residuals(rws)[i] * lh.inv_sq_loss_width, 1.0)
            m += 1
        end
        L = lh.logZ[ai] + 0.5 * s / m                 # unit loss = ½ρ (facet B)
        L < best && (best = L; bestα = α)
    end
    lh.α = bestα
    return nothing
end

function update_weights!(lh::BarronAdaptiveLikelihood)
    rws = lh.rws
    sh = _barron_grid_shape(lh.α)
    @inbounds for i in 1:lh.n
        robust_weight(rws)[i] = weight(sh, sq_residuals(rws)[i] * lh.inv_sq_loss_width, 1.0)
    end
    return nothing
end

# The strategies that carry a WIDTH MODE (VisualGeometryCore's `lo_width`),
# their derived scale-interface label, and the one setter: the width mode is a
# type parameter, so `with_width` rebuilds the strategy at a new mode — every
# other field carried across through the type's own constructor.
const _WidthCarrying = Union{HQ, Gnc, WelschHQNewton, BarronHQ, GmHqEps, BarronAdaptive}
VisualGeometryCore.lo_width(lo::_WidthCarrying) = lo.width
VisualGeometryCore.scale_interface(lo::_WidthCarrying) = width_scale_interface(lo.width)
VisualGeometryCore.with_width(lo::HQ{K}, w) where {K} = HQ{K}(lo.max_iter, lo.μ, lo.init, lo_width_value(w))
VisualGeometryCore.with_width(lo::Gnc{S}, w) where {S} = Gnc{S}(lo.max_iter, lo.factor, lo.entry, lo.budget, lo_width_value(w))
VisualGeometryCore.with_width(lo::WelschHQNewton, w) = WelschHQNewton(lo.max_iter, lo.μ, lo_width_value(w))
VisualGeometryCore.with_width(lo::BarronHQ, w) = BarronHQ(lo.α, lo.max_iter, lo.μ, lo_width_value(w))
VisualGeometryCore.with_width(lo::GmHqEps, w) = GmHqEps(lo.max_iter, lo.μ, lo_width_value(w))
VisualGeometryCore.with_width(lo::BarronAdaptive, w) =
    BarronAdaptive(lo.max_iter, lo.α_min, lo.truncation_multiple, lo.n_sub, lo_width_value(w))

# =============================================================================
# THE strategy registry — one row of facts per strategy, one keyword constructor
# =============================================================================
#
# Every strategy of this package is ONE row here: its TOML tag (the
# `configs/default.toml` `[local_optimization.<tag>]` table its keyword
# defaults read, and the `type` a config spells it by — the tag rule:
# `snake_case` of the type's name), its optimization path, whether it is a
# loss-parametric family (`Irls{K}`/`HQ{K}`/`Gnc{Irls{K}}`, which take a `loss`
# key), and — for the named one-off strategies — the identity VGC's `lo_label` /
# `loss_family` / `scale_interface` report. `nothing` in a column means the
# fact is DERIVED, not stated: the parametric families read their label and
# loss family off the loss tag (above), a fixed-loss arm its loss family off its
# `shape` column, and a width-carrying strategy its scale interface off its
# width mode (`_WidthCarrying`).
#
# Paths (the design-table column; marker shape = path, VGC `path_marker`):
# PoseLib's truncated-loss LM is a binary weight recomputed every iteration —
# static reweighting, the IRLS column; Le–Zach's relaxed TLS multiplies its
# penalty by 1.5 per LM iteration until it collapses to hard truncation —
# explicit continuation, the GNC column; ReGeMM's σ-graduated rounds are GNC
# too. The Student-t/uniform mixture arms report loss family :tls — they share
# the paper's "uniform mixtures" column.
#
#   type                 tag                      path   scale          family   label                     shape              parametric
const _LO_REGISTRY = (
    (StudentTUniform,     "student_t_uniform",     :irls, SelfScaling(), :tls,    raw"Stu-$t$U-IRLS",       nothing,           false),
    (HQ,                  "hq",                    :hq,   nothing,       nothing, nothing,                  nothing,           true),
    (Gnc,                 "gnc",                   :gnc,  nothing,       nothing, nothing,                  nothing,           true),
    (StuTuBCD,            "stu_tu_bcd",            :bcd,  SelfScaling(), :tls,    raw"Stu-$t$U-BCD",        nothing,           false),
    (WelschHQNewton,      "welsch_hq_newton",      :hq,   nothing,       nothing, raw"Welsch-HQ (Newton)",  WelschShape,       false),
    (WelschHQEcm,         "welsch_hq_ecm",         :hq,   SelfScaling(), nothing, raw"Welsch-HQ (ECM)",     WelschShape,       false),
    (BarronHQ,            "barron_hq",             :hq,   nothing,       nothing, raw"Barron-HQ",           BarronShape,       false),
    (StuTuHQTabulated,    "stu_tu_hq_tabulated",   :hq,   SelfScaling(), :tls,    raw"Stu-$t$U-HQ",         nothing,           false),
    (StuTuRegemm,         "stu_tu_regemm",         :gnc,  nothing,       :tls,    raw"Stu-$t$U-ReGeMM",     nothing,           false),
    (BarronAdaptive,      "barron_adaptive",       :irls, nothing,       nothing, raw"Barron-IRLS",         BarronShape,       false),
    (GmHqEps,             "gm_hq_eps",             :hq,   nothing,       nothing, raw"GM-HQ ($\epsilon$)",  GemanMcclureShape, false),
)
# ReGeMM's scale policy is a FIELD's value, not a type's: frozen (ŝ², π) is the
# strict fixed-scale consistent refiner, anchored at the consensus set.
VisualGeometryCore.scale_interface(lo::StuTuRegemm) = lo.adapt_scale ? SelfScaling() : ConsensusAnchored()

for (T, tag, path, iface, family, label, shape, _) in _LO_REGISTRY
    @eval begin
        _lo_tag(::Type{<:$T}) = $tag
        VisualGeometryCore.optimization_path(::$T) = $(QuoteNode(path))
    end
    iface === nothing || @eval VisualGeometryCore.scale_interface(::$T) = $iface
    family === nothing || @eval VisualGeometryCore.loss_family(::$T) = $(QuoteNode(family))
    label === nothing || @eval VisualGeometryCore.lo_label(::$T) = $label
    # The shape a FIXED-LOSS arm deploys (no `loss` key: its type names
    # the shape) — read by its loss family and by the TOML loader's
    # `scale_multiple = "cross_validated"` resolution (config_toml.jl). A tagged strategy
    # without one fails loudly there, never resolving somebody else's constant.
    shape === nothing || @eval begin
        _fixed_loss_shape(::Type{<:$T}) = $shape
        VisualGeometryCore.loss_family(::$T) = loss_family($shape)
    end
end

# A strategy takes a width (`scale_multiple` / `loss_width` keys) iff it has a
# `width` field, and a `loss` key iff it is a loss-parametric family.
_lo_takes_width(::Type{T}) where {T} = :width in fieldnames(T)
const _LO_PARAMETRIC = Dict{Any, Bool}(T => par for (T, _, _, _, _, _, _, par) in _LO_REGISTRY)

"""
    LO_TAGS

This package's local-optimization strategy registry (VisualGeometryCore's
`TagRegistry`): TOML tag → strategy type or loss-parametric family, the tag
`snake_case` of the type's name. Retired tags name their successor. Merge it
with the core's to load either: `merge(RobustVisualGeometry.LO_TAGS, LO_TAGS)`.
"""
const LO_TAGS = TagRegistry(
    :local_optimization, "",
    (tag => T for (T, tag) in _LO_REGISTRY)...;
    retired = ("stutu_bcd" => "stu_tu_bcd",
               "stutu_hq_tabulated" => "stu_tu_hq_tabulated", "stutu_regemm" => "stu_tu_regemm"),
    paths = [r"(^|\.)local_optimization\.type$"]
)

# -----------------------------------------------------------------------------
# The ONE keyword constructor of every strategy, driven by `fieldnames` and the
# tag: a field's keyword is the field's name; its default is the strategy's
# `[local_optimization.<tag>]` key in `configs/default.toml` (ASCII-spelled,
# `_toml_key`); a field with NO key in the file is REQUIRED (Barron's `α`).
# The width field is set by `scale_multiple = m` (`ScaleMultiple(m)`) or
# `loss_width = w` (`LossWidth(w)`) — both is an `ArgumentError` — and by
# neither follows the scorer (`nothing`). Values convert to the field's type;
# an unknown keyword is an `ArgumentError`.
#
# The per-strategy exceptions are hooks, each stated once:
#   `_lo_admits(T)`            construction-time admission, BEFORE any field
#   `_lo_key(T, Val(f))`       a field read from another key (HQ smooth-TLS)
#   `_lo_field(T, Val(f), v)`  a supplied value's conversion / refusal
#   `_lo_absent(T, Val(f))`    a field's value when the caller omits it
#   `_lo_validate(lo)`         cross-field checks on the built value
# -----------------------------------------------------------------------------
function _lo_construct(::Type{T}; kw...) where {T <: AbstractLocalOptimization}
    _lo_admits(T)
    kw = _lo_width_keywords(T, kw)
    for f in keys(kw)
        f in fieldnames(T) || throw(
            ArgumentError(
                "$T has no keyword `$f` (its keywords: $(join(_lo_keywords(T), ", ")))"
            )
        )
    end
    vals = ntuple(fieldcount(T)) do i
        f = fieldname(T, i)
        haskey(kw, f) ? _lo_field(T, Val(f), kw[f]) : _lo_absent(T, Val(f))
    end
    return _lo_validate(T(vals...))
end

# The keywords a caller spells: the fields, the width field as its two keys.
_lo_keywords(::Type{T}) where {T} =
    _lo_takes_width(T) ? [filter(!=(:width), collect(fieldnames(T))); :scale_multiple; :loss_width] :
    collect(fieldnames(T))

# `scale_multiple = m` / `loss_width = w` → the `width` field.
function _lo_width_keywords(::Type{T}, kw) where {T}
    _lo_takes_width(T) || return kw
    hm, hw = haskey(kw, :scale_multiple), haskey(kw, :loss_width)
    hm && hw && throw(ArgumentError("$T: give `scale_multiple` or `loss_width`, not both"))
    hm || hw || return kw
    rest = Dict{Symbol, Any}(k => v for (k, v) in kw if k ∉ (:scale_multiple, :loss_width))
    rest[:width] = hm ? _lo_scale_multiple(T, kw[:scale_multiple]) : LossWidth(Float64(kw[:loss_width]))
    return rest
end
_lo_scale_multiple(::Type, m) = ScaleMultiple(Float64(m))

_lo_admits(::Type) = nothing
_lo_admits(::Type{HQ{K}}) where {K} = _hq_admits_shape(K)
_lo_admits(::Type{Gnc{S}}) where {S} = _gnc_admits(S)

_lo_key(::Type, ::Val{F}) where {F} = _toml_key(F)
_lo_key(::Type{<:HQ{SmoothTLSShape}}, ::Val{:max_iter}) = "max_iter_smooth_tls"   # the longer ψ̂ schedule

_lo_field(::Type{T}, ::Val{F}, v) where {T, F} = convert(fieldtype(T, F), v)
_lo_field(::Type, ::Val{:width}, w) = lo_width_value(w)

function _lo_absent(::Type{T}, ::Val{F}) where {T, F}
    _lo_has_default(T, F) || throw(UndefKeywordError(F))
    return _from_toml(T, Val(F), _lo_table(T)[_lo_key(T, Val(F))])
end
# No width given: follow the scorer.
_lo_absent(::Type, ::Val{:width}) = nothing
# The strategy's `[local_optimization.<tag>]` table (empty for a strategy with
# no fields), and whether it defaults a field.
_lo_table(::Type{T}) where {T} = get(_TOML_DEFAULTS["local_optimization"], _lo_tag(T), Dict{String, Any}())
_lo_has_default(::Type{T}, f::Symbol) where {T} = haskey(_lo_table(T), _lo_key(T, Val(f)))

_lo_validate(lo) = lo
function _lo_validate(lo::Gnc{S}) where {S}
    lo.budget in (:parity, :converged) || error("Gnc: budget must be :parity or :converged, got :$(lo.budget)")
    isnan(lo.entry) || S === Irls{WelschShape} ||
        error("Gnc: numeric entry is defined for the annealed-width (Irls{WelschShape}) family only")
    return lo
end

for (T, _, _, _, _, _, _, parametric) in _LO_REGISTRY
    if T === BarronHQ
        # The Barron shape α is the arm's identity, so it is positional.
        @eval BarronHQ(α::Real; kw...) = _lo_construct(BarronHQ; α, kw...)
    elseif parametric
        @eval (::Type{$T{P}})(; kw...) where {P} = _lo_construct($T{P}; kw...)
    else
        @eval (::Type{$T})(; kw...) = _lo_construct($T; kw...)
    end
end
