# readme_tests.jl — the README's example, the documentation's Getting started
# and the Overview's recipe run as written, in a clean environment that holds
# exactly what the README's install line adds. A reader's first contact with the
# package is that code; it once used cameras, correspondences and an outlier
# half-width it never defined (General registration review, 2026-11).
#
# The example composes this package with RANSACScoringDoneRight's scorer, which
# the stack allow-list (VisualGeometryToolkitCore configs/stack_dependencies.toml)
# keeps out of this test target. So the item builds a temporary environment —
# this package by path, every other package of the install line from the
# registries — and runs the blocks in a child Julia process there. The install
# lines are `pkg>` blocks (```julia-repl), so they are not run as code: the
# item checks instead that the `pkg> add` line names every non-standard-library
# package the examples load, and nothing else.

@testitem "readme" begin
    using Test
    root = pkgdir(LocalOptimizationDoneRight)
    julia_blocks(path) = [m[1] for m in eachmatch(r"^```julia\n(.*?)^```"ms, read(path, String))]
    readme = read(joinpath(root, "README.md"), String)
    example = julia_blocks(joinpath(root, "README.md"))
    # Getting started, then the Overview's recipe, which reuses its scene.
    docs = [julia_blocks(joinpath(root, "docs", "src", "index.md"));
            filter(b -> occursin("find_essential", b), julia_blocks(joinpath(root, "docs", "src", "overview.md")))]
    @test length(example) == 1
    @test length(docs) == 2
    @test docs[1] == example[1]                     # one example, shown twice

    # The install line adds exactly the packages the examples load.
    install = match(r"^pkg> add (.+)$"m, readme)
    @test install !== nothing
    packages = split(install[1])
    loaded = Set{String}()
    for code in [example; docs], m in eachmatch(r"^(?:using|import)\s+([^:\n]+)"m, code)
        for part in split(m[1], ',')
            push!(loaded, first(split(strip(part), r"[.\s]")))
        end
    end
    stdlib(name) = isdir(joinpath(Sys.STDLIB, name))
    @test Set(filter(!stdlib, loaded)) == Set(packages)

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
        # The 200 matches, and the few of the 100 mismatches that land within
        # the inlier band of their epipolar lines.
        @test 195 <= readme.n_inliers <= 215
        @test readme.rotation_error < 1.0           # degrees, at 1 px noise
        @test readme.translation_error < 3.0
    end
    @testset "documentation examples" begin
        @test docs.n_inliers == readme.n_inliers    # the same scene and seeds
        @test count(docs.result.inlier_mask) >= 195 # the Overview's recipe on it
    end
    """)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia --startup-file=no --project=$env $script`
    # A clean environment: none of the test run's load path or project.
    proc = withenv("JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing) do
        run(ignorestatus(cmd))
    end
    @test proc.exitcode == 0
end
