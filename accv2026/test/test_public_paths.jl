# The public-facing files name no machine: no absolute host paths, home
# directories or cluster hosts in the READMEs, the docs, REPRODUCE.md or the
# project's code, configs and launchers (scripts/slurm included). Paths come
# from data_root() / results_root() (data/README.md) or environment variables.
using Test

@testset "public files name no host paths" begin
    repo = normpath(joinpath(@__DIR__, "..", ".."))
    proj = joinpath(repo, "accv2026")
    files = String[joinpath(repo, "README.md"), joinpath(proj, "REPRODUCE.md"),
                   joinpath(proj, "data", "README.md")]
    for (root, exts) in ((joinpath(repo, "docs", "src"), (".md",)),
                         (joinpath(repo, "docs"), (".jl",)),
                         (joinpath(repo, "configs"), (".toml",)),
                         (joinpath(proj, "src"), (".jl",)),
                         (joinpath(proj, "scripts"), (".jl", ".sh", ".sbatch", ".py", ".md")),
                         (joinpath(proj, "configs"), (".toml",)))
        for (r, _, fs) in walkdir(root), f in fs
            any(e -> endswith(f, e), exts) && push!(files, joinpath(r, f))
        end
    end
    pat = r"/raid/|/home/[a-z]|/Users/[a-z]|~/src/|\$HOME/src|\$\(HOME\)/src|\bdgx\d*\b"i
    hits = [(relpath(f, repo), i, strip(l)) for f in files for (i, l) in enumerate(eachline(f)) if occursin(pat, l)]
    @test isempty(hits) || (@info "host-specific paths in public files" hits; false)
end
