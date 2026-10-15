#!/bin/bash
# =============================================================================
# launch_pool_regen.sh — submit the POOL PRODUCER cells as Slurm chains: one
# chain per cell (its stages in declaration order, each its own job, chained
# --dependency=afterok), the CELLS IN PARALLEL. Skip-if-done inside each cell
# makes re-launches idempotent, so an interrupted 2 TB generation resumes by
# re-running this.
#
#   launch_pool_regen.sh [--pools-cpus=96] [--other-cpus=40] <cell> ...
#   launch_pool_regen.sh heb_h_pools pt_e_pools
#
# NO GPU. Pool generation is CPU-threaded over a scene's pairs, so every stage
# is submitted --gres=gpu:0: a days-long pools job must never hold a GPU that
# the cv stages need. (run_experiment.sbatch defaults to --gres=gpu:1.)
#
# SHAPES LIVE HERE, NOT IN THE CELLS' TOMLs. `run_key` hashes the effective
# config, so a cpu count stated there would re-key the pools it generates — a
# resource knob must not change an artifact's identity. RAM follows cpus via
# run_experiment.sbatch's --mem-per-cpu=8000M (96 cpus ≈ 768 G, 64 ≈ 512 G).
#
# STAGES COME FROM `--plan`, NOT FROM A GREP OF THE DRIVER. A grep for
# `Stage(:name` (the retired launch_supp_fleet.sh) silently yields an EMPTY
# chain — zero jobs submitted, no error — for every config-driven driver, whose
# stages are built in src/cell_stages.jl and appear nowhere in the driver text.
# `--plan` is the stage list the driver actually built, so this works for thin
# and fat drivers alike.
# =============================================================================
set -euo pipefail

# Resolve the project from THIS script's location, never a hardcoded path.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(cd "$HERE/../.." && pwd)
cd "$PROJ"

L=${ACCV_LOG_DIR:-$PROJ/logs}   # the jobs' logs (ACCV_LOG_DIR overrides)
SB=scripts/slurm/run_experiment.sbatch
POOLS_CPUS=96          # a pools stage: threads over a scene's pairs
# An audit stage is NOT cheap. It counts each scene's pairs as
# `length(load_pool(path))` (VisualGeometryEval), which DESERIALIZES THE WHOLE
# light pool file. Its memory must therefore exceed the LARGEST scene file in
# the tree, with room for JLD2's transient buffers. Memory is set
# only through cpus here (run_experiment.sbatch pins --mem-per-cpu=8000M and
# Slurm forbids --mem alongside it), so 40 cpus = 320 G.
# Observed 2026-10-02: 8 cpus (64 G) audited HEB's ~10 G scenes fine and was
# OOM-killed on PT-E, whose scenes run 50-100 G (sagrada_familia 100.7 G).
OTHER_CPUS=40
mkdir -p "$L"

for a in "$@"; do
  case "$a" in
    --pools-cpus=*) POOLS_CPUS="${a#*=}" ;;
    --other-cpus=*) OTHER_CPUS="${a#*=}" ;;
  esac
done

for cell in "$@"; do
  [[ "$cell" == --* ]] && continue
  file="scripts/${cell}.jl"
  [ -f "$file" ] || { echo "no such cell: $file" >&2; exit 1; }

  # The stage list the driver BUILDS (see the header). --plan runs nothing.
  stages=$(julia --project=. --startup-file=no "$file" --plan \
           | awk '/^[[:space:]]+[a-z_]+[[:space:]]/ {print $1}')
  [ -n "$stages" ] || { echo "$cell: --plan declared no stages — refusing to submit" >&2; exit 1; }

  dep=""; chain=""
  for st in $stages; do
    if [ "$st" = "pools" ]; then cpus=$POOLS_CPUS; else cpus=$OTHER_CPUS; fi
    jid=$(sbatch --parsable --gres=gpu:0 --cpus-per-task="$cpus" \
          ${NICE:+--nice=$NICE} ${dep:+--dependency=afterok:$dep} \
          --job-name="${cell}_${st}" \
          --output="$L/exp_${cell}_${st}_%j.log" \
          --error="$L/exp_${cell}_${st}_%j.log" \
          "$SB" "${cell}.jl" "--stage=${st}")
    chain+="${st}=${jid}(${cpus}c) "
    dep="$jid"
  done
  echo "$cell: $chain"
done
