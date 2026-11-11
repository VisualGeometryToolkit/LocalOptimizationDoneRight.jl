#!/bin/bash
# reproduce.sh — VisualGeometryToolkitEval's runner (Reproduce, src/reproduce/runner.jl) on this paper's stage graph of
# record, accv2026/configs/reproduce.toml; the per-machine launchers beside it (reproduce_results_<site>.sh) name the
# site. The runner needs the stdlibs only, so it starts from a bare julia before the environment is instantiated: on a
# fresh checkout the package sources are fetched here (no precompilation: JULIA_PKG_PRECOMPILE_AUTO=0), and the setup
# stage instantiates and precompiles inside the scheduler.
#   bash accv2026/scripts/reproduce/reproduce.sh --site=<dgx01 | desktop | path/to/site.toml> [--dry-run] [--only=a,b] [--no-deps] [status]
set -euo pipefail
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
exec "${JULIA:-julia}" --startup-file=no --project=accv2026 -e '
    import Pkg
    src = Base.find_package("VisualGeometryToolkitEval")
    if src === nothing
        withenv(Pkg.instantiate, "JULIA_PKG_PRECOMPILE_AUTO" => "0")
        src = Base.find_package("VisualGeometryToolkitEval")
    end
    include(joinpath(dirname(src), "cli.jl"))
    include(joinpath(dirname(src), "reproduce", "runner.jl"))
    exit(reproduce_main(ARGS))' -- --graph=accv2026/configs/reproduce.toml "$@"
