# =============================================================================
# Per-model-class tuning constants — the index over configs/default.toml's
# [[tuning_constants]], THE single home of the cross-validated
# `efficiency_constant` of the paper's arms (the accv2026 operating points), with
# codified provenance. Moved from VisualGeometryToolkitEstimation, whose find_* pipelines
# now default to the classical Irls{TLSShape} following the scorer.
#
# `efficiency_constant` is VGC's deployment multiple (robust/losses.jl `deploy`): the loss
# width a deployed loss runs at is `efficiency_constant·√s2`, with `s2` the noise
# variance the scale port supplies. VGC derives a default `efficiency_constant` from
# `efficiency_constant(K, codim)`; this registry is the other source VGC's
# docstring names — "a caller that cross-validates its own operating point".
# The mechanism structs (HQ{K} / Gnc{S} and every fixed-loss arm) therefore
# have NO default `efficiency_constant` (with none they follow the scorer): it is cross-validated per MODEL
# CLASS (the dominant axis: PT-E 1.597 vs HEB-H 0.773 at fixed features — 2×),
# with the feature/matcher type a second-order refinement (PT-E/SIFT 1.597 vs
# SN-E/SP+LG 1.795 — ~12%) and the dataset the axis partition anchoring is
# designed to absorb. `tuning_constant` resolves along exactly that hierarchy.
#
# SHAPE: a cross-validated `efficiency_constant` is an operating point for ONE loss
# shape. It is NOT a unit that converts between shapes — a Welsch-tuned 1.597
# used on Geman-McClure is a different operating point that nobody validated.
# So the shape is part of the LOOKUP KEY: a strategy asks for the value of the
# shape it actually deploys, and a class with no entry for that shape is an
# error naming what IS registered. Declaring a cross-shape transfer means
# adding an entry for it, with its own provenance — the registry already
# distinguishes validated from transferred, and this is a transfer.
#
# (Every `efficiency_constant` is the PLAIN multiple, `loss_width = efficiency_constant·ŝ`,
# whatever the shape: the half-weight currency the GM ablation arms were once
# stated in is retired, its values migrated once through `decision_width`.)
#
# PROVENANCE — one source of truth per value. A VALIDATED entry carries
# `tuning = { config, name, hash, arm }`: the cell config of record and the
# `[tuning.<name>]` product tuning whose arm `arm` deployed this value, with the
# spec's hash (VisualGeometryToolkitEval `tuning_hash`; the run's sidecar records
# the same hash, its grid specs and its run key). When the config of record
# changes (its spec now hashes otherwise) the entry keeps the hash of the spec
# that PRODUCED its value and states `pending_hash`, the hash it awaits
# re-validation under; value and hash then change together, and `pending_hash`
# goes. A TRANSFERRED entry carries
# `transfer = { problem, features, dataset }` and no `efficiency_constant`: its value
# and provenance are the referenced entry's (same shape), resolved at load. An
# audit re-derives each validated entry's spec hash from its config and checks
# the value against the cited run's sidecar.
# =============================================================================

"""
    TuningProvenance

Where a cross-validated `efficiency_constant` came from: arm `arm` of the product tuning
`[tuning.<name>]` of the cell config of record `config` (a path relative to the
directory holding the stack checkouts), whose spec hashes to `hash`
(VisualGeometryToolkitEval `tuning_hash`). `pending_hash` is `nothing`, or the
hash the config of record's spec has since moved to: the value is pending
re-validation under it (and `hash` still names the spec that produced it).
"""
struct TuningProvenance
    config::String
    name::String
    hash::String
    arm::String
    pending_hash::Union{Nothing,String}
end

"""
    TuningConstant

A cross-validated `efficiency_constant` with codified provenance — the loss width
as a multiple of the estimated scale; see `VisualGeometryToolkitCore.deploy`.

# Fields
- `efficiency_constant::Float64` — the loss width as a multiple of ŝ (partition-anchored).
- `shape::String` — the loss shape this value was validated for, in the tag
  vocabulary a strategy's `loss` key uses (`"welsch"`, `"geman_mcclure"`, …).
- `tuning::TuningProvenance` — the product tuning that produced the value
  (for a transfer: the one that produced the value it borrows).
- `transfer` — `nothing` for a value validated at its own key, else the
  registry key `(problem, features, dataset)` it was transferred from.
- `validated::Bool` — `transfer === nothing` (derived, not stated).
"""
struct TuningConstant
    efficiency_constant::Float64
    shape::String
    tuning::TuningProvenance
    transfer::Union{Nothing,NTuple{3,Symbol}}
    validated::Bool
end

const _TUNING_KEYS = ("problem", "features", "dataset", "shape", "efficiency_constant", "tuning", "transfer")
const _PROVENANCE_KEYS = ("config", "name", "hash", "arm")
const _PROVENANCE_OPTIONAL_KEYS = ("pending_hash",)
const _TRANSFER_KEYS = ("problem", "features", "dataset")

_registry_key(e) = (Symbol(e["problem"]), String(e["shape"]), Symbol(e["features"]), Symbol(e["dataset"]))

# Build the registry from configs/default.toml's [[tuning_constants]]: every
# entry states exactly one of `tuning` (with its `efficiency_constant`) or `transfer` (without),
# unknown keys are refused, and a transfer resolves — transitively, same shape
# — to a validated entry; a dangling or cyclic reference is refused.
function _tuning_registry(entries)
    raw = Dict{Tuple{Symbol, String, Symbol, Symbol}, Any}()
    for e in entries
        VgtkCore.check_keys(e, _TUNING_KEYS, "tuning_constants")
        key = _registry_key(e)
        haskey(raw, key) && throw(ArgumentError("[[tuning_constants]]: duplicate entry $key"))
        has_t, has_x = haskey(e, "tuning"), haskey(e, "transfer")
        has_t == has_x && throw(ArgumentError(
            "[[tuning_constants]] $key: state exactly one of `tuning` (a validated value) or `transfer`"))
        if has_t
            haskey(e, "efficiency_constant") || throw(ArgumentError("[[tuning_constants]] $key: a validated entry states its `efficiency_constant`"))
            VgtkCore.check_keys(e["tuning"], (_PROVENANCE_KEYS..., _PROVENANCE_OPTIONAL_KEYS...),
                                          "tuning_constants.tuning")
            get(e["tuning"], "pending_hash", nothing) == e["tuning"]["hash"] && throw(ArgumentError(
                "[[tuning_constants]] $key: `pending_hash` equals `hash` — nothing is pending"))
            all(key -> haskey(e["tuning"], key), _PROVENANCE_KEYS) ||
                throw(ArgumentError("[[tuning_constants]] $key: `tuning` needs $(_PROVENANCE_KEYS)"))
        else
            haskey(e, "efficiency_constant") && throw(ArgumentError(
                "[[tuning_constants]] $key: a transfer does not restate `efficiency_constant` — it is the source's"))
            VgtkCore.check_keys(e["transfer"], _TRANSFER_KEYS, "tuning_constants.transfer")
            all(key -> haskey(e["transfer"], key), _TRANSFER_KEYS) ||
                throw(ArgumentError("[[tuning_constants]] $key: `transfer` needs $(_TRANSFER_KEYS)"))
        end
        raw[key] = e
    end
    function resolve(key, seen)
        key in seen && throw(ArgumentError("[[tuning_constants]]: cyclic transfer through $key"))
        haskey(raw, key) || throw(ArgumentError("[[tuning_constants]]: transfer to $key, which has no entry"))
        e = raw[key]
        haskey(e, "tuning") && return (Float64(e["efficiency_constant"]), e["tuning"])
        x = e["transfer"]
        return resolve((Symbol(x["problem"]), key[2], Symbol(x["features"]), Symbol(x["dataset"])), push!(seen, key))
    end
    out = Dict{Tuple{Symbol, String, Symbol, Symbol}, TuningConstant}()
    for (key, e) in raw
        efficiency_constant, t = resolve(key, Set{Any}())
        pending = get(t, "pending_hash", nothing)
        prov = TuningProvenance(String(t["config"]), String(t["name"]), String(t["hash"]), String(t["arm"]),
                                pending === nothing ? nothing : String(pending))
        transfer = haskey(e, "transfer") ?
            (Symbol(e["transfer"]["problem"]), Symbol(e["transfer"]["features"]), Symbol(e["transfer"]["dataset"])) :
            nothing
        out[key] = TuningConstant(efficiency_constant, key[2], prov, transfer, transfer === nothing)
    end
    return out
end

# (problem, shape, features, dataset) → TuningConstant. `:any` is the wildcard
# tier for features/dataset; `shape` NEVER wildcards — a constant belongs to
# the shape it was tuned for, so an absent (class, shape) pair is an error
# rather than a fallback.
# Built from configs/default.toml's [[tuning_constants]] array at precompile —
# the file is the one home of these constants; this Dict is its index.
const _TUNING_CONSTANTS = _tuning_registry(_DEFAULTS_OF_RECORD["tuning_constants"])

"""
    tuning_constant(problem::Symbol, shape::AbstractString;
                    features::Symbol = :any, dataset::Symbol = :any) -> TuningConstant

The cross-validated efficiency constant of a model class and loss shape.

Resolve the cross-validated `efficiency_constant` for `problem`
(`:essential | :fundmat | :homography | :radial_homography | :radial_camera |
:absolute_pose`) and loss `shape` (the tag vocabulary a strategy's `loss`
key uses) along the provenance hierarchy `(features, dataset)` →
`(features, :any)` → `(:any, :any)`.

`shape` does NOT wildcard. An efficiency constant is an operating point for one shape, not a
unit that converts between them, so a class with no entry for the requested
shape raises rather than serving a constant validated for a different one.
Check `.validated` to see whether the returned value was cross-validated at
its own key or transferred (`.transfer` names the source key), and `.tuning`
for the product tuning that produced it.

```jldoctest
julia> using LocalOptimizationDoneRight

julia> c = tuning_constant(:essential, "welsch");

julia> c.efficiency_constant, c.validated   # the class tier holds a transferred value
(1.597, false)

julia> c.efficiency_constant == WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL
true
```
"""
function tuning_constant(
        problem::Symbol, shape::AbstractString;
        features::Symbol = :any, dataset::Symbol = :any
    )
    sh = String(shape)
    for key in (
            (problem, sh, features, dataset),
            (problem, sh, features, :any),
            (problem, sh, :any, :any),
        )
        haskey(_TUNING_CONSTANTS, key) && return _TUNING_CONSTANTS[key]
    end
    # Actionable refusal: name what IS registered for this class, with the
    # tuning that produced it, and the two ways forward. Never substitute.
    here = sort!(
        [
            (kk[2], vv) for (kk, vv) in _TUNING_CONSTANTS
                if kk[1] === problem && kk[3] === :any && kk[4] === :any
        ];
        by = first
    )
    isempty(here) && error(
        "tuning_constant: no entry for problem :$problem — known classes: " *
            "$(sort!(unique(String.(first.(collect(keys(_TUNING_CONSTANTS)))))))"
    )
    have = join(["$(repr(sh2)) (efficiency_constant = $(vv.efficiency_constant), tuned by [tuning.$(vv.tuning.name)] of $(vv.tuning.config), arm $(repr(vv.tuning.arm)))" for (sh2, vv) in here], "\n        ")
    return error(
        "tuning_constant: model class :$problem has no cross-validated `efficiency_constant` for the " *
            "$(repr(sh)) shape.\n    Registered for :$problem:\n        $have\n" *
            "    A cross-validated `efficiency_constant` is an operating point for ONE shape, not a unit " *
            "that converts, so it is not substituted across shapes. Either state a " *
            "literal `efficiency_constant` for this strategy, or add a [[tuning_constants]] entry to " *
            "configs/default.toml with problem = $(repr(String(problem))), " *
            "shape = $(repr(sh)) and its own provenance."
    )
end

# Class-level Welsch efficiency-constant shorthands for callers that build a strategy
# by hand (`HQ{WelschShape}(efficiency_constant = WELSCH_HQ_EFFICIENCY_CONSTANT_HOMOGRAPHY)`).
# Each is `tuning_constant(class, "welsch").efficiency_constant`: the registry above
# is the single authority, and a TOML strategy resolves it itself through
# `efficiency_constant = "cross_validated"`, not through these. Never write a number here.

"""
    WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL

The Welsch-HQ `efficiency_constant` of the essential class.

For `VisualGeometryToolkitEstimation.find_essential`, it is the
deployed optimum of the PT-E-SIFT-4K product tuning (the essential class tier
transfers it from the `(:sift, :phototourism)` entry, the one that tuned it).
Equal to `tuning_constant(:essential, "welsch").efficiency_constant`.
"""
const WELSCH_HQ_EFFICIENCY_CONSTANT_ESSENTIAL = tuning_constant(:essential, "welsch").efficiency_constant

"""
    WELSCH_HQ_EFFICIENCY_CONSTANT_FUNDMAT

The Welsch-HQ `efficiency_constant` of the fundmat class (`VisualGeometryToolkitEstimation.find_fundmat`). TRANSFERRED
from the essential entry — `tuning_constant(:fundmat, "welsch").validated` is `false`
until the PT-F cross-validation lands.
"""
const WELSCH_HQ_EFFICIENCY_CONSTANT_FUNDMAT = tuning_constant(:fundmat, "welsch").efficiency_constant

"""
    WELSCH_HQ_EFFICIENCY_CONSTANT_HOMOGRAPHY

The Welsch-HQ `efficiency_constant` of the homography class (`VisualGeometryToolkitEstimation.find_homography`).
TRANSFERRED from the essential entry — `tuning_constant(:homography, "welsch").validated`
is `false` until the HEB-H re-CV succeeds at its gate.
"""
const WELSCH_HQ_EFFICIENCY_CONSTANT_HOMOGRAPHY = tuning_constant(:homography, "welsch").efficiency_constant

"""
    WELSCH_HQ_EFFICIENCY_CONSTANT_ABSOLUTE_POSE

The Welsch-HQ `efficiency_constant` of the absolute_pose class (`VisualGeometryToolkitEstimation.find_absolute_pose`).
TRANSFERRED from the essential entry — no PnP entry has been cross-validated
yet, so `tuning_constant(:absolute_pose, "welsch").validated` is `false`.
"""
const WELSCH_HQ_EFFICIENCY_CONSTANT_ABSOLUTE_POSE = tuning_constant(:absolute_pose, "welsch").efficiency_constant
