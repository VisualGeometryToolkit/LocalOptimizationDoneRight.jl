"""
    RansacLibLO

Seeded classical LO-RANSAC local optimization for essential matrices, via
RansacLib — Sattler's template-based *SAC library, run UNMODIFIED. RansacLib
self-describes its `LocallyOptimizedMSAC` as "LO-MSAC as described in Lebeda,
Matas, Chum, Fixing the Locally Optimized RANSAC, BMVC 2012" (README.md) /
"Implements LO-RANSAC with MSAC (top-hat) scoring, based on the description
provided in [Lebeda, Matas, Chum, Fixing the Locally Optimized RANSAC, BMVC
2012]" (RansacLib/ransac.h).

The C++ shim (`deps/ransaclib_wrapper/julia_wrapper.cpp`) vendors RansacLib
byte-identical to upstream and supplies only what its template API requires
the user to supply — an essential-model solver (Hartley-normalized 8-point +
projection to the essential manifold; squared first-order Sampson residuals;
plain unweighted refits, exactly as RansacLib drives them) — plus a subclass
lifting the `protected` LO entry so it can be run from a caller-supplied
seed. Two entries:

- [`lebeda_lo`](@ref)     — full LO (Lebeda Alg. 2+3 as implemented by
  RansacLib): least-squares fit at the enlarged loss width, inner non-minimal
  resampling from the internally derived base consensus, per-sample iterative
  least squares with an arithmetically decreasing loss width.
- [`lebeda_iterlo`](@ref) — the iterative-least-squares ladder alone (Alg. 3;
  the Chum et al. 2003 "iterative" mechanism / Lebeda's LO'), composed from
  RansacLib's own protected primitives.

Both refine a caller-supplied seed model at a caller-supplied ABSOLUTE
squared loss width (`sq_loss_width`, squared Sampson in the frame of the input
points; RansacLib's `squared_inlier_threshold_`) — the classical absolute-width
currency. Best-tracking is on the MSAC (truncated quadratic) score at that
width; the seed is always a candidate, so the returned model
never scores worse than the seed.

Determinism: the only randomness is a `std::mt19937` seeded from `rng_seed`
per call — identical inputs give bitwise-identical outputs.

DISCLOSED delta vs Lebeda's original EG implementation: Lebeda's iterated
LSq used Sampson-gradient REWEIGHTED fits (`u2fw`); RansacLib's refits are
plain least squares and are used as-is (the arm is attributed to Sattler's
implementation, not our reconstruction of Lebeda through it).
"""
module RansacLibLO

using LinearAlgebra

export LebedaLOOptions, PRESET_REFERENCE, PRESET_TR_INFORMATIVE
export lebeda_lo, lebeda_iterlo, lsq_sq_loss_widths

const _SHIM = joinpath(@__DIR__, "..", "deps", "ransaclib_wrapper",
    "libransaclib_jl.$(Sys.iswindows() ? "dll" : Sys.isapple() ? "dylib" : "so")")

"""
    LebedaLOOptions(; num_lo_trials=10, sq_loss_width_multiplier=√2,
                      num_lsq_iterations=4, min_sample_multiplicator=7,
                      non_min_sample_multiplier=3)

The subset of RansacLib's public `LORansacOptions` driving the LO procedure,
with RansacLib's OWN defaults (`ransac.h`, `LORansacOptions()`) — the
reference behavior. Field ↔ `LORansacOptions` member:

| field                       | RansacLib member              | default |
|-----------------------------|-------------------------------|---------|
| `num_lo_trials`             | `num_lo_steps_`               | 10      |
| `sq_loss_width_multiplier`      | `threshold_multiplier_` (on the squared loss width)| √2     |
| `num_lsq_iterations`        | `num_lsq_iterations_`         | 4       |
| `min_sample_multiplicator`  | `min_sample_multiplicator_`   | 7       |
| `non_min_sample_multiplier` | `non_min_sample_multiplier_`  | 3       |

Each of RansacLib's LO "steps" is a random non-minimal draw from the base
consensus (`ransac.h`, `RandomShuffleAndResize`), so the option is named a
count of TRIALS here; it maps onto `num_lo_steps_` only at the C boundary.
The `num_lsq_iterations` are deterministic reweighting cycles, hence iterations.

With the solver's `min_sample_size = 5` (essential), RansacLib derives:
LSq inlier cap = `min_sample_multiplicator·5` (35 at default); non-minimal
sample size = `max(8, min(non_min_sample_multiplier·5, |I_base|/2))` (15 at
default). `num_lsq_iterations ≥ 2` is required (RansacLib's loss-width
decrement divides by `iters − 1`).

Informational mapping to Lebeda's TR Table 1 EG constants (m_θ = 2 on θ,
reps = 10, iters = 4, inlLimit = 49, s_is = min(14, |I|/2)): see
[`PRESET_TR_INFORMATIVE`](@ref). Note RansacLib's `threshold_multiplier_`
multiplies the SQUARED loss width, so its default √2 corresponds to
m_θ = 2^(1/4) ≈ 1.19 on θ, vs Lebeda's published m_θ = 2 (⇒ 4.0 on θ²).

Model-update budget (linear solves per call, every stage active): full LO =
`1 + num_lo_trials·(2 + num_lsq_iterations)`; ILSQ-only =
`1 + num_lsq_iterations`. Stages whose consensus gate is thinner than the
minimal sample size skip their solve, so the count is a per-call measurement
(returned as `updates`), not a constant.
"""
struct LebedaLOOptions
    num_lo_trials::Int32              # LORansacOptions.num_lo_steps_
    sq_loss_width_multiplier::Float64     # LORansacOptions.threshold_multiplier_ (on the squared loss width)
    num_lsq_iterations::Int32         # LORansacOptions.num_lsq_iterations_ (≥ 2)
    min_sample_multiplicator::Int32   # LORansacOptions.min_sample_multiplicator_
    non_min_sample_multiplier::Int32  # LORansacOptions.non_min_sample_multiplier_
    function LebedaLOOptions(; num_lo_trials::Integer = 10,
                             sq_loss_width_multiplier::Real = sqrt(2.0),
                             num_lsq_iterations::Integer = 4,
                             min_sample_multiplicator::Integer = 7,
                             non_min_sample_multiplier::Integer = 3)
        num_lo_trials >= 0 || throw(ArgumentError("num_lo_trials must be ≥ 0"))
        sq_loss_width_multiplier >= 1 ||
            throw(ArgumentError("sq_loss_width_multiplier must be ≥ 1 (enlarged entry)"))
        num_lsq_iterations >= 2 ||
            throw(ArgumentError("num_lsq_iterations must be ≥ 2 (RansacLib divides by iters−1)"))
        min_sample_multiplicator >= 1 ||
            throw(ArgumentError("min_sample_multiplicator must be ≥ 1"))
        non_min_sample_multiplier >= 1 ||
            throw(ArgumentError("non_min_sample_multiplier must be ≥ 1"))
        new(num_lo_trials, sq_loss_width_multiplier, num_lsq_iterations,
            min_sample_multiplicator, non_min_sample_multiplier)
    end
end

"""
PRIMARY preset — RansacLib's own `LORansacOptions` defaults (the reference
behavior; 61 model updates for full LO when every stage is active).
"""
const PRESET_REFERENCE = LebedaLOOptions()

"""
INFORMATIONAL preset — the closest public-option mapping of Lebeda's TR
Table 1 EG constants onto RansacLib, given the solver's honest
`min_sample_size = 5`:

- `sq_loss_width_multiplier = 4.0` — Lebeda m_θ = 2 on θ ⇒ m_θ² on θ² (exact);
- `num_lo_trials = 10` — reps (exact);
- `num_lsq_iterations = 4` — iters (exact);
- `min_sample_multiplicator = 10` — LSq cap 50 vs Lebeda's inlLimit 49
  (49 = 7·7 is not reachable as an integer multiple of 5);
- `non_min_sample_multiplier = 3` — non-min sample min(15, |I|/2) vs
  Lebeda's s_is = min(14, |I|/2).

NOT the primary preset: the reference behavior is [`PRESET_REFERENCE`](@ref)
(RansacLib as shipped); this mapping exists to report Lebeda's published
constants against RansacLib's option names.
"""
const PRESET_TR_INFORMATIVE = LebedaLOOptions(sq_loss_width_multiplier = 4.0,
                                              min_sample_multiplicator = 10)

"""
    lsq_sq_loss_widths(options::LebedaLOOptions, sq_loss_width) -> Vector{Float64}

The squared loss widths of the iterative-least-squares ladder, in the order its
least-squares fits run: EXACTLY the schedule of RansacLib's ladder
(`ransac.h` `LocalOptimization`, the shim's `RunIterLSQ`) — one fit at
`sq_loss_width` (θ²), then `options.num_lsq_iterations` fits while the
SQUARED width decreases arithmetically from
`options.sq_loss_width_multiplier·θ²` to θ² (step
`(multiplier − 1)·θ²/(num_lsq_iterations − 1)`). The multiplier scales θ², not
θ: RansacLib's default √2 is 2^(1/4) on θ.

The C++ computes the two-view ladder itself; this is the same schedule for a
caller that runs the ladder on a model RansacLib has no solver for (an
absolute pose), so both ladders read one declaration. Its length is the
ladder's model-update count, `lebeda_iterlo`'s `updates` when every rung is
populated.
"""
function lsq_sq_loss_widths(options::LebedaLOOptions, sq_loss_width::Real)
    sq_loss_width > 0 || throw(ArgumentError("sq_loss_width must be > 0"))
    θ² = Float64(sq_loss_width)
    m, n = options.sq_loss_width_multiplier, Int(options.num_lsq_iterations)
    Δ = (m - 1.0) * θ² / (n - 1)
    widths = [θ²]
    thresh = m * θ²
    for _ in 1:n                       # RansacLib's `thresh -= thresh_mult_update` recurrence
        push!(widths, thresh)
        thresh -= Δ
    end
    return widths
end

const _MODEL_KIND = Dict{Symbol,Int32}(:E => 0, :F => 1, :H => 2)

function _run(variant::Int32, pts::AbstractMatrix{<:Real}, seed_E::AbstractMatrix{<:Real},
              sq_loss_width::Real, options::LebedaLOOptions, rng_seed::Integer,
              base_mask::Union{Nothing,AbstractVector{Bool}}, model::Symbol)
    haskey(_MODEL_KIND, model) ||
        throw(ArgumentError("model must be :E, :F or :H, got :$model"))
    size(pts, 1) == 4 || throw(ArgumentError("pts must be 4×N (x1, y1, x2, y2 columns)"))
    size(seed_E) == (3, 3) || throw(ArgumentError("seed_E must be 3×3"))
    n = size(pts, 2)
    n >= 8 || throw(ArgumentError("need ≥ 8 correspondences, got $n"))
    sq_loss_width > 0 || throw(ArgumentError("sq_loss_width must be > 0"))
    base_mask === nothing || length(base_mask) == n ||
        throw(ArgumentError("base_mask must have length $n"))

    P = Matrix{Float64}(pts)
    E0 = Matrix{Float64}(seed_E)
    Eout = Matrix{Float64}(undef, 3, 3)
    score = Ref{Float64}(NaN)
    updates = Ref{Int64}(0)
    lo_ns = Ref{Int64}(0)
    mask8 = base_mask === nothing ? UInt8[] : UInt8.(base_mask)

    rc = ccall((:ransaclib_lebeda_lo, _SHIM), Cint,
        (Ptr{Float64}, Int32, Ptr{Float64}, Float64, Int32, Float64, Int32,
         Int32, Int32, UInt32, Ptr{UInt8}, Int32, Int32, Ptr{Float64},
         Ref{Float64}, Ref{Int64}, Ref{Int64}),
        P, Int32(n), E0, Float64(sq_loss_width),
        options.num_lo_trials, options.sq_loss_width_multiplier,
        options.num_lsq_iterations, options.min_sample_multiplicator,
        options.non_min_sample_multiplier, UInt32(rng_seed),
        base_mask === nothing ? Ptr{UInt8}(C_NULL) : pointer(mask8),
        _MODEL_KIND[model], variant, Eout, score, updates, lo_ns)
    rc == 0 || error("ransaclib_lebeda_lo failed with code $rc")
    # `ns` is the wall-clock time INSIDE the RansacLib LO invocation
    # (steady_clock in the shim, marshalling excluded) — the lo_ns half of the
    # eval stack's lo_ns/lo_calls accounting; `updates` its refit count.
    return (E = Eout, score = score[], updates = updates[], ns = lo_ns[])
end

"""
    lebeda_lo(pts, seed_model, sq_loss_width;
              model = :E, options = PRESET_REFERENCE, rng_seed = 0,
              base_mask = nothing)
        -> (E = 3×3 Matrix, score, updates, ns)

Full LO (RansacLib `LocalOptimization`, run verbatim) from `seed_model` on
the 4×N correspondence matrix `pts` (columns `(x1, y1, x2, y2)`, z = 1
implied, any consistent frame) at the terminal squared loss width
`sq_loss_width` (squared Sampson). `model` selects the fitted manifold: `:E`
(8-point DLT + essential projection, 5-pt minimal arithmetic), `:F`
(8-point DLT + rank-2 projection, 7-pt), or `:H` (4-point DLT, codim-2
transfer Sampson residual). Returns the best model by MSAC score at
`sq_loss_width` (`score = Σ min(r², sq_loss_width)`, seed included), the exact number of linear solves
performed (`updates`), and the wall-clock nanoseconds spent inside the LO
invocation (`ns` — steady_clock in the shim, marshalling excluded).

The base inlier set for the non-minimal sampling stage is NOT an input: per
the published algorithm it is derived internally by gating against the
current model at the enlarged loss width, and non-minimal samples are drawn
from it. `base_mask` (a length-N `Bool` vector) OVERRIDES that self-derived
set — a diagnostic/pipeline hook only; leave it `nothing` for the published
behavior.
"""
lebeda_lo(pts, seed_E, sq_loss_width;
          model::Symbol = :E,
          options::LebedaLOOptions = PRESET_REFERENCE, rng_seed::Integer = 0,
          base_mask::Union{Nothing,AbstractVector{Bool}} = nothing) =
    _run(Int32(0), pts, seed_E, sq_loss_width, options, rng_seed, base_mask, model)

"""
    lebeda_iterlo(pts, seed_model, sq_loss_width;
                  model = :E, options = PRESET_REFERENCE, rng_seed = 0)
        -> (E = 3×3 Matrix, score, updates, ns)

Iterative-least-squares-only local optimization (the ladder block of
RansacLib's `LocalOptimization`, composed from its own protected primitives —
the Chum et al. 2003 "iterative" mechanism / Lebeda's LO'): one
least-squares fit on the consensus at the loss width, then `options.num_lsq_iterations` fits
while the squared loss width decreases arithmetically from
`sq_loss_width_multiplier·sq_loss_width` to `sq_loss_width`. `num_lo_trials` and the non-minimal sampling
options are ignored, and so is any `base_mask` (the ladder re-derives its
consensus per rung by design); `rng_seed` still drives the inlier-cap
subsampling inside RansacLib's `LeastSquaresFit`.
"""
lebeda_iterlo(pts, seed_E, sq_loss_width;
              model::Symbol = :E,
              options::LebedaLOOptions = PRESET_REFERENCE, rng_seed::Integer = 0) =
    _run(Int32(1), pts, seed_E, sq_loss_width, options, rng_seed, nothing, model)

end # module
