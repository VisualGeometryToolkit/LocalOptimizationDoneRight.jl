# readme_tests.jl — the README's example, the documentation's Getting started
# and the Overview's recipe run as written, in a clean environment that holds
# exactly what the README's install line adds. A reader's first contact with the
# package is that code; it once used cameras, correspondences and an outlier
# half-width it never defined (General registration review, #174579).
#
# The example composes this package with VisualGeometryToolkitCore's Student-t +
# uniform scorer, and runs as a reader runs it: from what the install line adds.
# So the item builds a temporary environment —
# this package by path, every other package of the install line from General —
# and runs the blocks in a child Julia process there. The install line is a
# `pkg>` block (```julia-repl), so it is not run as code: the item checks
# instead that the `pkg> add` line names every non-standard-library package the
# examples load, and nothing else, and that the landing page shows the same line.
# A block that cannot run starts with `# Illustrative` and is left out; the
# pinned counts of the blocks that do run make a new one a deliberate change.

@testitem "readme" begin
    using Test
    root = pkgdir(LocalOptimizationDoneRight)
    julia_blocks(path) = [m[1] for m in eachmatch(r"^```julia\n(.*?)^```"ms, read(path, String))]
    illustrative(block) = startswith(block, "# Illustrative")
    readme = read(joinpath(root, "README.md"), String)
    index_path = joinpath(root, "docs", "src", "index.md")
    example = filter(!illustrative, julia_blocks(joinpath(root, "README.md")))
    # Getting started, then the Overview's recipe, which reuses its scene.
    docs = [filter(!illustrative, julia_blocks(index_path));
            filter(b -> occursin("find_essential", b), julia_blocks(joinpath(root, "docs", "src", "overview.md")))]
    @test length(example) == 1                      # pin the counts
    @test length(docs) == 2
    @test docs[1] == example[1]                     # one example, shown twice

    # The install line adds exactly the packages the examples load, and the
    # landing page shows the same line.
    install = [m[1] for m in eachmatch(r"^pkg> add (.+)$"m, readme)]
    @test length(install) == 1
    packages = split(only(install))
    loaded = Set{String}()
    for code in [example; docs], m in eachmatch(r"^(?:using|import)\s+([^:\n]+)"m, code)
        for part in split(m[1], ',')
            push!(loaded, first(split(strip(part), r"[.\s]")))
        end
    end
    stdlib(name) = isdir(joinpath(Sys.STDLIB, name))
    @test Set(filter(!stdlib, loaded)) == Set(packages)
    @test occursin("pkg> add $(only(install))", read(index_path, String))

    env = mktempdir()
    write(joinpath(env, "readme_example.jl"), only(example))
    write(joinpath(env, "docs_example.jl"), join(docs, "\n"))
    registered = filter(!=("LocalOptimizationDoneRight"), String.(packages))
    script = joinpath(env, "run.jl")
    write(script, """
    using Pkg
    Pkg.develop(path = $(repr(root)); io = devnull)
    Pkg.add($(repr(registered)); io = devnull)
    readme = Module(:ReadmeSandbox)
    Base.include(readme, $(repr(joinpath(env, "readme_example.jl"))))
    docs = Module(:DocsSandbox)
    Base.include(docs, $(repr(joinpath(env, "docs_example.jl"))))
    using Test
    @testset "README example" begin
        # The 200 matches, and the few of the 100 mismatches that land close
        # enough to their epipolar lines for the Student-t + uniform scorer to
        # take them as inliers.
        @test 195 <= readme.n_inliers <= 215
        @test readme.rotation_error < 1.0           # degrees, at 1 px noise
        @test readme.translation_error < 3.0
    end
    @testset "documentation examples" begin
        @test docs.n_inliers == readme.n_inliers    # the same scene and seeds
        @test count(docs.inlier_mask(docs.result)) >= 195 # the Overview's recipe on it
    end
    """)
    # Base.julia_cmd() carries the test run's flags (--depwarn=error, coverage).
    # The load path is the project and the standard library only: no default
    # environment (@v1.13) can supply a package the install line does not add.
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$env $script`
    proc = withenv("JULIA_LOAD_PATH" => "@:@stdlib", "JULIA_PROJECT" => nothing) do
        run(ignorestatus(cmd))
    end
    @test proc.exitcode == 0
end
