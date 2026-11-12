# =============================================================================
# config_defaults.jl — THE default mechanism of LocalOptimizationDoneRight:
# configs/default.toml, read through `_config_default`.
#
# Every keyword default and constant of the package that changes a
# refinement reads it here, so there is no second set of Julia literals to drift
# from it. The lookup is VisualGeometryToolkitCore's `toml_default`, which throws on a missing
# table or key by design. Parsed at precompile by Core's `parse_defaults`, the
# stack's one defaults reader, which records the file as an include dependency:
# an edit forces a recompile (a Revise session needs a restart to see one).
# =============================================================================

"The defaults of record (configs/default.toml)."
const DEFAULTS_PATH = normpath(joinpath(@__DIR__, "..", "configs", "default.toml"))
const _DEFAULTS_OF_RECORD = parse_defaults(DEFAULTS_PATH)

"""
    _config_default(table, key)

The default `key` of `[table]` (a dotted path, `"optimization_strategy.poselib_adapt"`)
in configs/default.toml. Throws a `KeyError` naming a missing table or key.
"""
_config_default(table::AbstractString, key::AbstractString) = toml_default(_DEFAULTS_OF_RECORD, table, key)
