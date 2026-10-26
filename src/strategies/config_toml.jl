# =============================================================================
# The strategies' TOML: their `[local_optimization.<tag>]` keyword defaults
# (configs/default.toml), and this package's exceptions to VisualGeometryToolkitEstimation's
# one reader (`lo_from_toml`) and writer (`config_dict`), stated as hook methods.
#
# A strategy is spelled as an inline table, `type` its tag:
#
#     local_optimization = { type = "hq", loss = "welsch", scale_multiple = "cross_validated" }
#
# and loaded through the core's one entry with the two registries merged:
#
#     local_optimization_from_toml(d; class, tags = merge(VisualGeometryToolkitEstimation.LO_TAGS, LO_TAGS))
#
# `loss` (HQ, Gnc) selects the robust loss from the core's LOSS_TAGS; `gnc`
# wraps an inner static strategy named by `inner` + `loss`. A width is
# `scale_multiple` (a number, or "cross_validated": the [[tuning_constants]]
# entry of the calling pipeline's model class for the strategy's shape) or
# `loss_width`; with neither it follows the scorer's decision point.
# =============================================================================

# ---- the exceptions this package states to the machinery --------------------
# Reading, writing and constructing a strategy are VisualGeometryToolkitEstimation's
# (`lo_from_toml`, `lo_config_dict`, `lo_construct`; Greek field names are spelled
# ASCII by Core's `toml_key`). What is this package's is stated as hook methods.

# TOML has no NaN. `Gnc.entry = NaN` means "r_max" (the Yang–Carlone seed
# breadth); the file spells the meaning and this maps it, both directions.
_entry_from_toml(v::AbstractString) = v == "r_max" ? NaN :
    throw(ArgumentError("gnc.entry must be a number or \"r_max\", got $(repr(v))"))
_entry_from_toml(v::Real) = Float64(v)
_entry_to_toml(x::Float64) = isnan(x) ? "r_max" : x

VgtkEstimation.lo_field_from_toml(::Type{<:Gnc}, ::Val{:entry}, v) = _entry_from_toml(v)
VgtkCore.toml_field(lo::Gnc, ::Val{:entry}) = _entry_to_toml(lo.entry)

const _LOSS_TAG_OF = Dict{Type, String}(shape => tag for (tag, shape) in LOSS_TAGS)
_loss_tag(::Type{K}) where {K <: AbstractLossShape} = _LOSS_TAG_OF[K]

# Gnc{S} wraps the inner static strategy `inner` (+ `loss`): concrete at
# `Gnc{Irls{loss}}`. (HQ{K}, a plain strategy: Estimation's default.)
function VgtkEstimation.lo_concrete(::Type{Gnc}, d::AbstractDict, sec::AbstractString; tags::TagRegistry)
    inner_tag = get(d, "inner", "irls")
    inner_tag in ("irls",) || throw(ArgumentError("[$sec] inner must be \"irls\", got $(repr(inner_tag))"))
    haskey(d, "loss") || throw(ArgumentError("[$sec] needs a `loss` (one of $(sort(collect(keys(LOSS_TAGS)))))"))
    return Gnc{Irls{LOSS_TAGS[d["loss"]]}}, ("type", "inner", "loss")
end

# `scale_multiple = "cross_validated"` resolves the registry entry for THIS
# strategy's shape. The lookup is shape-keyed, so a class with no entry for the
# shape being deployed raises there — a Welsch-tuned value is never handed to a
# GM arm. (A number is the caller's own and is taken as given, by Estimation's
# method.)
for T in values(LO_TAGS)
    # only a strategy with a width, or Welsch-HQ-ECM's plain scale multiple, has one to resolve
    (:width in fieldnames(T) || :scale_multiple in fieldnames(T)) || continue
    @eval VgtkEstimation.lo_resolve_scale_multiple(::Type{<:$T}, K::Type, v::AbstractString; class::Symbol) =
        v == "cross_validated" ?
        tuning_constant(class, _loss_tag(K)).scale_multiple :
        throw(ArgumentError("scale_multiple must be a number or \"cross_validated\", got $(repr(v))"))
end

# The writer: Estimation's `lo_config_dict`; only the wrapper's `inner`
# discriminator is this package's.
function VgtkEstimation.config_dict(lo::Gnc)
    d = VgtkEstimation.lo_config_dict(lo)
    d["inner"] = "irls"
    return d
end
