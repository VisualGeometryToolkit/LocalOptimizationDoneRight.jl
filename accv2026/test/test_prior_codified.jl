# =============================================================================
# test_prior_codified.jl — THE SCALE PRIOR IS CODIFIED, NEVER STATED IN CODE.
#
# A cell's prior is its config's (`[sequential_cv] prior`, absent = Jeffreys),
# fitted by the scorer stage and recorded in the scorer artifact; every
# consumer that re-runs the scorer at a sidecar's operating points reads it
# back through `sidecar_scale_prior(sidecar)`. A literal prior in code silently
# overrides the config: the HEB-H inverse-gamma run's first budget (2026-10-04)
# was scored with a hard-coded Jeffreys at operating points tuned under the
# inverse gamma. This test fails on any prior constructed outside the files
# allowed to, each with its reason.
# =============================================================================
using Test

const _PRIOR_LITERAL = r"IGPrior\(|JeffreysPrior\(|ALL_PRIOR_SPECS|JeffreysPriorSpec\(|IGRobustSpec\("
# file (relative to accv2026/) => why it may construct a prior
const _PRIOR_ALLOWED = Dict(
    "scripts/tools/run_sequential_cv.jl" => "THE producer: fits the prior its [sequential_cv] prior states",
    "src/cell_stages.jl"                 => "sidecar_scale_prior: reads the scorer artifact (Jeffreys when it states none)",
    "scripts/tools/time_lo_supp.jl"      => "TODO codify: per-call LO timing (the prior does not change the timed work)",
    "src/experiment_producer.jl"         => "TODO codify: Fig 1's scoring-only producer (Jeffreys by design; move to its config)",
)

@testset "scale prior codified (no literal priors in code)" begin
    root = normpath(joinpath(@__DIR__, ".."))
    offenders = String[]
    for dir in ("src", "scripts"), (d, _, fs) in walkdir(joinpath(root, dir)), f in fs
        endswith(f, ".jl") || continue
        path = joinpath(d, f); rel = relpath(path, root)
        haskey(_PRIOR_ALLOWED, rel) && continue
        for (i, line) in enumerate(eachline(path))
            code = first(split(line, '#'; limit = 2))          # comments may name a prior
            occursin(_PRIOR_LITERAL, code) && push!(offenders, "$rel:$i: $(strip(line))")
        end
    end
    isempty(offenders) || @info "literal scale priors outside the allowlist" offenders
    @test isempty(offenders)
end
