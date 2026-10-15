# =============================================================================
# The strategies' TOML: their `[local_optimization.<tag>]` keyword defaults
# (configs/default.toml), the loader method of RobustVisualGeometry's
# `lo_from_toml` for this package's tags, and the writer (`config_dict`).
#
# A strategy is spelled as an inline table, `type` its tag:
#
#     local_optimization = { type = "hq", loss = "welsch", scale_multiple = "cross_validated" }
#
# and loaded through the core's one entry with the two registries merged:
#
#     local_optimization_from_toml(d; class, tags = merge(RobustVisualGeometry.LO_TAGS, LO_TAGS))
#
# `loss` (HQ, Gnc) selects the robust loss from the core's LOSS_TAGS; `gnc`
# wraps an inner static strategy named by `inner` + `loss`. A width is
# `scale_multiple` (a number, or "cross_validated": the [[tuning_constants]]
# entry of the calling pipeline's model class for the strategy's shape) or
# `loss_width`; with neither it follows the scorer's decision point.
# =============================================================================

# ---- field ⇄ TOML key spelling ----------------------------------------------
# The strategy structs use Greek field names (μ, η, γ, ν, α, α_min); TOML keys
# stay ASCII so a config is typeable everywhere. ONE table, both directions.
const _KEY_ASCII = Dict{Symbol, String}(
    :μ => "mu", :η => "eta", :γ => "gamma", :ν => "nu", :α => "alpha",
    :α_min => "alpha_min",
)
const _KEY_FIELD = Dict{String, Symbol}(key => field for (field, key) in _KEY_ASCII)
_toml_key(f::Symbol) = get(_KEY_ASCII, f, String(f))
_field_of(key::AbstractString) = get(_KEY_FIELD, key, Symbol(key))

# TOML has no NaN. `Gnc.entry = NaN` means "r_max" (the Yang–Carlone seed
# breadth); the file spells the meaning and this maps it, both directions.
_entry_from_toml(v::AbstractString) = v == "r_max" ? NaN :
    throw(ArgumentError("gnc.entry must be a number or \"r_max\", got $(repr(v))"))
_entry_from_toml(v::Real) = Float64(v)
_entry_to_toml(x::Float64) = isnan(x) ? "r_max" : x

# The one per-field conversion hook of the reader.
_from_toml(::Type{T}, ::Val{F}, v) where {T, F} = convert_field(fieldtype(T, F), v)
_from_toml(::Type{<:Gnc}, ::Val{:entry}, v) = _entry_from_toml(v)
VisualGeometryCore.toml_field(lo::Gnc, ::Val{:entry}) = _entry_to_toml(lo.entry)

for T in values(LO_TAGS)
    @eval begin
        # The width field is written and read as its two keys
        # (`scale_multiple` | `loss_width`), never as `width`.
        VisualGeometryCore.toml_skip_fields(::Type{<:$T}) = (:width,)
        VisualGeometryCore.toml_key(::Type{<:$T}, f::Symbol) = _toml_key(f)
    end
end

_lo_tag(lo::AbstractLocalOptimization) = _lo_tag(typeof(lo))
const _LOSS_TAG_OF = Dict{Type, String}(shape => tag for (tag, shape) in LOSS_TAGS)
_loss_tag(::Type{K}) where {K <: AbstractLossShape} = _LOSS_TAG_OF[K]

function _loss_of(d::AbstractDict, section)
    haskey(d, "loss") || throw(ArgumentError("[$section] needs a `loss` (one of $(sort(collect(keys(LOSS_TAGS)))))"))
    return LOSS_TAGS[d["loss"]]
end

_width_keys(::Type{C}) where {C} = _lo_takes_width(C) ? ("scale_multiple", "loss_width") : ()

# The shape a strategy's `scale_multiple` was cross-validated for: the loss of a
# parametric family, the named shape of a fixed-loss arm.
_scale_multiple_shape(::Type{C}) where {C <: Union{HQ, Gnc}} = strategy_loss(C)
_scale_multiple_shape(::Type{C}) where {C} = _fixed_loss_shape(C)
# A strategy with no width has no shape a scale multiple was tuned for.
_fixed_loss_shape(::Type{C}) where {C} =
    throw(ArgumentError("$(nameof(C)) takes no `scale_multiple` (it has no width)"))

# A literal `scale_multiple` is the caller's own number and claims nothing
# about provenance, so it carries no shape and is taken as given.
_resolve_scale_multiple(v::Real, ::Symbol, ::Type{<:AbstractLossShape}) = Float64(v)
# `scale_multiple = "cross_validated"` resolves the registry entry for THIS
# strategy's shape. The lookup is shape-keyed, so a class with no entry for the
# shape being deployed raises there — a Welsch-tuned value is never handed to a
# GM arm.
_resolve_scale_multiple(v::AbstractString, class::Symbol, K::Type{<:AbstractLossShape}) =
    v == "cross_validated" ?
    tuning_constant(class, _loss_tag(K)).scale_multiple :
    throw(ArgumentError("scale_multiple must be a number or \"cross_validated\", got $(repr(v))"))

# The reader's typed per-key overrides: only the keys PRESENT in the table
# become keywords (absent ones fall through to the shipped file), ASCII
# spellings mapped back to the Greek field names.
function _table_kwargs(::Type{T}, d::AbstractDict) where {T}
    spec = [
        toml_key(T, f) => (v -> _from_toml(T, Val(f), v))
            for f in fieldnames(T) if !(f in toml_skip_fields(T))
    ]
    return present_kwargs(d, spec...; field_of = _field_of)
end

for T in values(LO_TAGS)
    @eval RobustVisualGeometry.lo_from_toml(::Type{<:$T}, d::AbstractDict; class::Symbol, section::AbstractString) =
        _lodr_lo_from_toml($T, d; class, section)
end

# The concrete strategy type and the keys the table may carry beyond its fields:
# Gnc{S} wraps the inner static strategy `inner` (+ `loss`), HQ{K} is concrete
# at its `loss`, a plain strategy is itself.
function _lodr_concrete(::Type{Gnc}, d, sec)
    inner_tag = get(d, "inner", "irls")
    inner_tag in ("irls",) || throw(ArgumentError("[$sec] inner must be \"irls\", got $(repr(inner_tag))"))
    return Gnc{Irls{_loss_of(d, sec)}}, ("type", "inner", "loss")
end
_lodr_concrete(::Type{HQ}, d, sec) = (HQ{_loss_of(d, sec)}, ("type", "loss"))
_lodr_concrete(::Type{T}, d, sec) where {T} = (T, ("type",))

function _lodr_lo_from_toml(T, d::AbstractDict; class::Symbol, section::AbstractString)
    tag = d["type"]
    sec = "$section.$tag"
    C, extra = _lodr_concrete(T, d, sec)
    check_keys(d, allowed_keys(C, extra..., _width_keys(C)...), sec)
    # The ONE presence check: a key the shipped file has no default for is
    # required — BarronHQ's `alpha`. (No width: follow the scorer.)
    for f in fieldnames(C)
        f in toml_skip_fields(C) && continue
        haskey(d, toml_key(C, f)) || _lo_has_default(C, f) ||
            throw(ArgumentError("[$sec] needs `$(toml_key(C, f))`"))
    end
    kw = _table_kwargs(C, d)
    haskey(d, "scale_multiple") && haskey(d, "loss_width") &&
        throw(ArgumentError("[$sec] give `scale_multiple` or `loss_width`, not both"))
    haskey(d, "loss_width") && return _lo_construct(C; kw..., loss_width = Float64(d["loss_width"]))
    haskey(d, "scale_multiple") || return _lo_construct(C; kw...)
    scale_multiple = _resolve_scale_multiple(d["scale_multiple"], class, _scale_multiple_shape(C))
    return _lo_construct(C; kw..., scale_multiple)
end

# The writer: VGC's `toml_table` walk (the width skipped, Greek spelled ASCII,
# `Gnc.entry` spelled by its hook); only the discriminators are this package's.
for T in values(LO_TAGS)
    @eval function RobustVisualGeometry.config_dict(lo::$T)
        d = toml_table(lo)
        d["type"] = _lo_tag(lo)
        lo isa Gnc && (d["inner"] = "irls")
        lo isa Union{HQ, Gnc} && (d["loss"] = _loss_tag(strategy_loss(lo)))
        _lo_takes_width(typeof(lo)) && _width_to_toml!(d, lo.width)
        return d
    end
end

# The width mode, written as its key: `scale_multiple`, or `loss_width` (an
# absolute width, `√s2` of `LossWidth(w) = (1, w²)`); no width writes nothing.
_width_to_toml!(d, ::Nothing) = d
_width_to_toml!(d, w::ScaleMultiple{Float64}) = (d["scale_multiple"] = w.value; d)
function _width_to_toml!(d, w::LossWidth{NTuple{2, Float64}})
    m, s2 = w.value
    d["loss_width"] = m * sqrt(s2)
    return d
end
