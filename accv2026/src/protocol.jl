# =============================================================================
# src/protocol.jl — THE reader of configs/protocol.toml, the experiment
# protocol of record (every result-changing value this paper's code used to
# carry as a literal or a global constant).
#
# ONE mechanism: `protocol_value(table, key)` — VisualGeometryCore's
# `toml_default` over the parsed file, which throws on a missing table or key
# (a value that is not in the file would be a second source of truth). Every
# reader in src/ and scripts/ goes through it; no reader keeps a fallback.
# =============================================================================
if !@isdefined(ACCV2026_PROTOCOL_LOADED)

using DrWatson: projectdir   # configs/ of the active (accv2026) project
using TOML: TOML
using VisualGeometryCore: toml_default

"The experiment protocol of record."
const PROTOCOL_PATH = projectdir("configs", "protocol.toml")
const PROTOCOL = TOML.parsefile(PROTOCOL_PATH)

"""
    protocol_value(table, key)

The value of `key` in the dotted `table` of configs/protocol.toml (`"arms"`,
`"arms.lebeda"`, `"basin_ladder"`). Throws on a missing table or key.
"""
protocol_value(table::AbstractString, key::AbstractString) = toml_default(PROTOCOL, table, key)

"""
    protocol_table(table)

The whole `table` of configs/protocol.toml, as a fresh Dict. For folding a
protocol table into a run key, where the KEY must cover
every value in it rather than the handful a reader happens to touch. Throws on
a missing table — the same contract as [`protocol_value`](@ref).
"""
function protocol_table(table::AbstractString)
    t = PROTOCOL
    for part in split(table, '.')
        t isa AbstractDict && haskey(t, part) ||
            error("protocol_table: configs/protocol.toml has no [$table]")
        t = t[part]
    end
    t isa AbstractDict || error("protocol_table: [$table] of configs/protocol.toml is not a table")
    return deepcopy(Dict{String,Any}(t))
end

"THE equal LO update budget of every arm of the paper (`[arms] lo_iteration_budget`)."
const LO_BUDGET = Int(protocol_value("arms", "lo_iteration_budget"))

const ACCV2026_PROTOCOL_LOADED = true
end # include guard
