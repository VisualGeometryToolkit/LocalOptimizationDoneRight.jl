# test_config_vocabulary.jl — retired (inert) config keys stay retired: no cell
# TOML may carry a key nothing reads (scripts/config_vocabulary.jl).
using Test, TOML
include(joinpath(@__DIR__, "..", "src", "config_vocabulary.jl"))

@testset "retired config keys are absent from every config" begin
    cfgdir = joinpath(@__DIR__, "..", "configs")
    files = filter(f -> endswith(f, ".toml"), readdir(cfgdir))
    @test !isempty(files)
    for f in files
        cfg = TOML.parsefile(joinpath(cfgdir, f))
        for (section, key) in RETIRED_CONFIG_KEYS
            present = haskey(cfg, section) && cfg[section] isa AbstractDict && haskey(cfg[section], key)
            @test !present || error("$(f): retired key [$(section)] $(key) is back")
        end
    end
end
