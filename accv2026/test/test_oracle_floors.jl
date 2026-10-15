# test_oracle_floors.jl — the oracle-floors file has ONE writer and ONE
# done-predicate (scripts/common.jl): a floor counts as DONE for a cell only
# when its recorded source (pool tree, problem, test scenes) is the cell's
# current one. Floors without a recorded source (legacy files) are never DONE.
using Test, JLD2
include(joinpath(@__DIR__, "..", "src", "common.jl"))

@testset "oracle floors: source-checked done predicate" begin
    mktempdir() do d
        p = joinpath(d, "oracle_floors.jld2")
        want = (pool_dir = "/pools/E", problem = :E, scenes = ["a", "b"])
        @test !oracle_floor_done(p, "X_E"; want...)
        write_oracle_floor!(p, "X_E", 1.5, 0.8;
                            source = oracle_floor_source("/pools/E", :E, ["b", "a"]),   # order-free
                            npairs = 10, driver = "t")
        @test oracle_floor_done(p, "X_E"; want...)
        @test !oracle_floor_done(p, "X_E"; pool_dir = "/pools/E_vgc07", problem = :E, scenes = ["a", "b"])
        @test !oracle_floor_done(p, "X_E"; pool_dir = "/pools/E", problem = :E, scenes = ["a"])
        @test !oracle_floor_done(p, "X_E"; pool_dir = "/pools/E", problem = :F, scenes = ["a", "b"])
        @test !oracle_floor_done(p, "Y_F"; pool_dir = "/pools/F", problem = :F, scenes = ["c"])
        # a second tag keeps the first, with its source
        write_oracle_floor!(p, "Y_F", 2.0, 0.5;
                            source = oracle_floor_source("/pools/F", :F, ["c"]), npairs = 3, driver = "t")
        f = JLD2.load(p)
        @test f["floors"]["X_E"] == 1.5 && f["floors"]["X_E_maa"] == 0.8 && f["floors"]["Y_F_maa"] == 0.5
        @test f["sources"]["X_E"]["npairs"] == 10 && f["sources"]["Y_F"]["scenes"] == ["c"]
        @test oracle_floor_done(p, "X_E"; want...)
        @test oracle_floor_done(p, "Y_F"; pool_dir = "/pools/F", problem = :F, scenes = ["c"])
        # a legacy file (floors only, no sources) is never DONE
        q = joinpath(d, "legacy.jld2")
        JLD2.jldsave(q; floors = Dict("Z_E" => 1.0, "Z_E_maa" => 0.9))
        @test !oracle_floor_done(q, "Z_E"; pool_dir = "/pools/E", problem = :E, scenes = ["a"])
    end
end
