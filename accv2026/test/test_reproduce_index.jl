# REPRODUCE.md is THE experiment index: every stage file is listed, every
# listed file exists (a retired or renamed driver cannot go stale in the docs).
using Test
@testset "REPRODUCE.md indexes the experiments" begin
    root = normpath(joinpath(@__DIR__, ".."))
    doc = read(joinpath(root, "REPRODUCE.md"), String)
    scripts = joinpath(root, "scripts")
    stage_files = [
        f for f in readdir(scripts) if endswith(f, ".jl") &&
            occursin("run_stages(", read(joinpath(scripts, f), String))
    ]
    @test !isempty(stage_files)
    missing = [f for f in stage_files if !occursin("scripts/" * f, doc)]
    @test isempty(missing)
    isempty(missing) || @info "stage files not indexed in REPRODUCE.md" missing
    stale = [m[1] for m in eachmatch(r"scripts/([A-Za-z0-9_/]+\.(?:jl|sh|sbatch|py))", doc) if !isfile(joinpath(scripts, m[1]))]
    @test isempty(stale)
    isempty(stale) || @info "REPRODUCE.md names files that do not exist" stale
end
