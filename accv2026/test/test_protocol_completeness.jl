# =============================================================================
# test_protocol_completeness.jl — configs/protocol.toml and its readers agree:
# every value in the file is read by a `protocol_value(table, key)` call in
# src/ or scripts/ (a value nothing reads is a second authority that can only
# silently disagree), and every such call names a value the file holds (the
# reader throws on a missing one at run time; this finds it at test time).
# =============================================================================
using Test, TOML

@testset "configs/protocol.toml ⇔ protocol_value readers" begin
    root = normpath(joinpath(@__DIR__, ".."))
    proto = TOML.parsefile(joinpath(root, "configs", "protocol.toml"))
    declared = Set{Tuple{String,String}}()
    walk(d, path) = for (k, v) in d
        v isa AbstractDict ? walk(v, isempty(path) ? k : path * "." * k) : push!(declared, (path, k))
    end
    walk(proto, "")
    code = join((read(joinpath(r, f), String) for dir in ("src", "scripts")
                 for (r, _, fs) in walkdir(joinpath(root, dir)) for f in fs if endswith(f, ".jl")), '\n')
    read_keys = Set((m[1], m[2]) for m in eachmatch(r"protocol_value\(\s*\"([A-Za-z0-9_.]+)\"\s*,\s*\"([A-Za-z0-9_]+)\"", code))
    unread = setdiff(declared, read_keys)
    undeclared = setdiff(read_keys, declared)
    @test isempty(unread)
    @test isempty(undeclared)
    isempty(unread) || @info "protocol.toml values nothing reads" unread
    isempty(undeclared) || @info "protocol_value reads absent from protocol.toml" undeclared
end
