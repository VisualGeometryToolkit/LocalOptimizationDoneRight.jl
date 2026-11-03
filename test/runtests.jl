# =============================================================================
# LocalOptimizationDoneRight — the optimizer library's suite: the lift core and
# its schedules, the tuning constants and the strategies' TOML, the PoseLib
# refiners, plus the tooling gates. ReTestItems: every file is one test item
# (items_test.jl), evaluated in a module of its own on a pool of worker
# processes — items share no bindings and run in no fixed order. The paper's
# tests (and its RansacLib LO baseline's) live in accv2026/test (a DrWatson
# project, ReTestItems too).
#
#   julia --project -e 'using Pkg; Pkg.test()'
#   Pkg.test(test_args = ["lift_core|schedules"])   # the items whose name matches
#   RETESTITEMS_NWORKERS=0 → serial, in-process      # for debugging
#   LO_TIMING_GATE=1 (same) — the opt-in timing gate (test_lo_timing_gate.jl)
#
# Runs, by tag: the untagged items on the pool (RETESTITEMS_NWORKERS workers,
# default one per two logical CPUs, 2 threads each); `:timing` — the LO timing
# gate — on ONE single-threaded worker after the pool has exited, so a timing
# gate shares no CPU with other items. testitem_timeout = 3600 s.
#
# The evaluation engine is VisualGeometryToolkitEval's (VisualGeometryToolkitEval.Evaluation,
# tested there); its integration with these strategies and the paper's scorer
# is accv2026/test/test_engine_integration.jl. The strategy tests that run on
# the paper's scorer (RANSACScoringDoneRight, which the stack allow-list keeps
# out of this test target) live in accv2026/test/lodr/.
# =============================================================================
using ReTestItems
using LocalOptimizationDoneRight

const NAME = isempty(ARGS) ? nothing : Regex(join(ARGS, "|"))
const NWORKERS = parse(Int, get(ENV, "RETESTITEMS_NWORKERS", string(max(1, Sys.CPU_THREADS ÷ 2))))
const ONE = NWORKERS == 0 ? 0 : 1          # the timing run: one worker (serial mode: in-process)

# One run. With a name pattern a run may match no item, which ReTestItems
# reports by throwing; that run is then skipped, and only a pattern that
# matches no item in any run is an error. Items are found from the package
# module, not a path: from test/ ReTestItems would take the unnamed workspace
# member test/Project.toml for the project.
const RAN = Ref(false)
function run_items(select; kw...)
    try
        runtests(select, LocalOptimizationDoneRight; name = NAME, testitem_timeout = 3600, kw...)
        RAN[] = true
    catch e
        (e isa ReTestItems.NoTestException && NAME !== nothing) || rethrow()
    end
end

run_items(ti -> !(:timing in ti.tags); nworkers = NWORKERS, nworker_threads = 2)
run_items(ti -> :timing in ti.tags; nworkers = ONE, nworker_threads = 1)

RAN[] || error("no test item matches $(repr(NAME))")
