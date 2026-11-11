# =============================================================================
# The ACCV 2026 research project's tests — ReTestItems: the paper config
# registers, the production sidecar reads through the roster, every driver
# obeys the codification contract, the protocol invariants hold, REPRODUCE.md
# indexes the experiments, the RansacLib LO baseline (src/lebeda_lo.jl over
# lib/RansacLibLO) refits as declared, the composition evaluator
# (VisualGeometryToolkitEval.Evaluation) runs the paper's scorer and local
# optimizers as its RSDR × LODR integration goldens pin, and
# LocalOptimizationDoneRight's strategy tests run on the paper's scorer (lodr/).
#
# The items are accv2026_tests.jl and lodr/lodr_tests.jl (the shared scenes:
# lodr/scenes_testsetups.jl). Each item is evaluated in its own module on a
# pool of worker processes, so items share no bindings and run in no fixed
# order. Run from the project (a DrWatson project, not a package — no Pkg.test):
#
#   julia --project=. test/runtests.jl
#   julia --project=. test/runtests.jl "lodr|engine"   # the items whose name matches
#   RETESTITEMS_NWORKERS=0 → serial, in-process         # for debugging
#   LO_TIMING_GATE=1 (or =record) → the opt-in LO timing gate (lo_timing/)
#
# Runs, by tag:
#   (untagged)  the pool: RETESTITEMS_NWORKERS workers (default one per two
#               logical CPUs), 2 threads each
#   :data       on the pool too, SKIPPED (a recorded skip, not an error) where
#               no results root is bound (VGTK_RESULTS_ROOT or the project's
#               data/exp_pro link)
#   :timing     the LO timing gate, on ONE single-threaded worker after the
#               pool has exited: a timing gate shares no CPU with other items
# Every run: testitem_timeout = 3600 s. No item uses the GPU.
#
# The project's name (ACCV2026) has no package to load, so every item sets
# `default_imports = false`. Run as THIS file, ReTestItems takes the active
# project (--project=.) as the test environment instead of building one.
# =============================================================================
using ReTestItems

const NAME = isempty(ARGS) ? nothing : Regex(join(ARGS, "|"))
const NWORKERS = parse(Int, get(ENV, "RETESTITEMS_NWORKERS", string(max(1, Sys.CPU_THREADS ÷ 2))))
const ONE = NWORKERS == 0 ? 0 : 1          # the timing run: one worker (serial mode: in-process)

# One run. With a name pattern a run may match no item, which ReTestItems
# reports by throwing; that run is then skipped, and only a pattern that
# matches no item in any run is an error.
const RAN = Ref(false)
function run_items(select; kw...)
    try
        runtests(select, @__DIR__; name = NAME, testitem_timeout = 3600, kw...)
        RAN[] = true
    catch e
        (e isa ReTestItems.NoTestException && NAME !== nothing) || rethrow()
    end
end

# The stack's paper-project conventions (rule L4: the suite's entry point calls
# the check), in the main process before the items; a name pattern runs only
# the matching items.
NAME === nothing && include(joinpath(@__DIR__, "test_paper_project.jl"))

run_items(ti -> !(:timing in ti.tags); nworkers = NWORKERS, nworker_threads = 2)
run_items(ti -> :timing in ti.tags; nworkers = ONE, nworker_threads = 1)

RAN[] || error("no test item matches $(repr(NAME))")
