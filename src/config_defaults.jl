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

"""
    LODR_CONFIG_VERSIONS

LocalOptimizationDoneRight's configuration converter (VisualGeometryToolkitCore's `ConfigVersions`):
`configs/default.toml` is version 2. Version 1 (0.7 and earlier, no `config_version` key) held the adaptive refit's
defaults under the deleted PoseLib arms' names; its one migration moves `[optimization_strategy.poselib_adapt]` to
`[adaptive_loss_width_refit]` (its `max_iter`, the total LM budget, to `[adaptive_loss_width_refit.stops]`) and
`[optimization_strategy.poselib] cheirality_vote_points` to `[adaptive_loss_width_refit]`. Read a stored file at the
current version with `VisualGeometryToolkitCore.migrate_config(stored, LODR_CONFIG_VERSIONS)`, `stored` the parsed file.
"""
const LODR_CONFIG_VERSIONS = ConfigVersions("LocalOptimizationDoneRight",
    ConfigMigration(; tables = ["optimization_strategy", "tuning_constants"],
        renames = ["optimization_strategy.poselib_adapt" => "adaptive_loss_width_refit",
                   "adaptive_loss_width_refit.max_iter" => "adaptive_loss_width_refit.stops.max_iter",
                   "optimization_strategy.poselib.cheirality_vote_points" => "adaptive_loss_width_refit.cheirality_vote_points"]);
    tables = ["optimization_strategy", "tuning_constants", "adaptive_loss_width_refit"])

const _DEFAULTS_OF_RECORD = parse_defaults(DEFAULTS_PATH; versions = LODR_CONFIG_VERSIONS)

"""
    _config_default(table, key)

The default `key` of `[table]` (a dotted path, `"adaptive_loss_width_refit.stops"`)
in configs/default.toml. Throws a `KeyError` naming a missing table or key.
"""
_config_default(table::AbstractString, key::AbstractString) = toml_default(_DEFAULTS_OF_RECORD, table, key)
