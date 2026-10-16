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
        canonical="https://localoptimizationdoneright.github.io/",
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

# The site is the localoptimizationdoneright organization page (https://localoptimizationdoneright.github.io):
# unversioned, at the root of that repository's `main` branch. CI deploys it
# (.github/workflows/docs.yml) with DOCUMENTER_KEY, the private half of a
# write-enabled deploy key of that repository. Documenter deploys only when the
# building repository's name occurs in the target URL; the site is another
# repository, so the deploy config names it as the target. LODR_DOCS_DEPLOY=1
# selects pretty URLs for a local build.
const SITE_REPO = "localoptimizationdoneright/localoptimizationdoneright.github.io"
deploydocs(;
    repo="github.com/$(SITE_REPO).git",
    branch="main",
    devbranch="main",
    versions=nothing,
    deploy_config=Documenter.GitHubActions(SITE_REPO, get(ENV, "GITHUB_EVENT_NAME", ""), get(ENV, "GITHUB_REF", "")),
)
