using Documenter
using DocumenterLandingPage   # LandingPage(): the VitePress-style home page (index.md frontmatter)
using DocumenterCodeBlocks    # CodeBlocks(): line numbers, docstring links and tooltips in code blocks
using LocalOptimizationDoneRight

makedocs(;
    modules=[LocalOptimizationDoneRight],
    repo=Remotes.GitHub("VisualGeometryToolkit", "LocalOptimizationDoneRight.jl"),
    authors="James Pritts <jbpritts@gmail.com>, Kevin Köser",
    sitename="Robust Local Optimization Done Right",
    format=Documenter.HTML(;
        assets=["assets/landing_tagline.css", "assets/landing_tagline.js"],
        prettyurls=get(ENV, "CI", "false") == "true" || get(ENV, "LODR_DOCS_DEPLOY", "0") == "1",
        canonical="https://visualgeometrytoolkit.github.io/LocalOptimizationDoneRight.jl/",
        edit_link="main",
    ),
    plugins=[LandingPage(), CodeBlocks()],
    warnonly=[:missing_docs, :cross_references, :docs_block],
    pages=[
        "Home" => "index.md",
        "Overview" => "overview.md",
        "Guides" => [
            "Reproducing the paper" => "guide/reproducing.md",
            "Baselines" => "guide/baselines.md",
        ],
        "API Reference" => [
            "Strategies" => "api/strategies.md",
            "Lift core and schedules" => "api/lift.md",
            "Internals" => "api/internals.md",
        ],
    ],
)

# The site is this repository's project page
# (https://visualgeometrytoolkit.github.io/LocalOptimizationDoneRight.jl/):
# unversioned, at the root of the `gh-pages` branch. CI deploys it
# (.github/workflows/docs.yml) with the DOCUMENTER_KEY deploy key of this
# repository; LODR_DOCS_DEPLOY=1
# selects pretty URLs for a local build.
deploydocs(;
    repo="github.com/VisualGeometryToolkit/LocalOptimizationDoneRight.jl.git",
    branch="gh-pages",
    devbranch="main",
    versions=nothing,
)
