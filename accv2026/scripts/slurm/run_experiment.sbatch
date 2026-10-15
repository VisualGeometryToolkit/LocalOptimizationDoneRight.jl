#!/bin/bash
# =============================================================================
# scripts/slurm/run_experiment.sbatch — an example Slurm wrapper for the
# ACCV 2026 experiment files (each also runs directly:
# `julia --project=. scripts/<exp>.jl`). Submit from accv2026/; logs go to
# accv2026/logs/. Adjust the partition and shape to your cluster. RAM is
# PROPORTIONAL to cpus (`--mem-per-cpu`), so a submit sets ONLY
# --cpus-per-task and memory scales with it, e.g.
#
#   mkdir -p logs
#   sbatch --job-name=fig3 --gres=gpu:1 --cpus-per-task=48 \
#          --output=logs/exp_fig3_%j.log \
#          scripts/slurm/run_experiment.sbatch \
#          fig3_composed_miscal.jl [--stage=NAME] [--force]
#
# --mem-per-cpu=8000M is set a little under the RAM/cpu ratio of the node the
# paper ran on, so a full-node job still fits. Do NOT also supply --mem (Slurm
# forbids --mem + --mem-per-cpu together). CPU-heavy stages just raise
# --cpus-per-task.
# =============================================================================
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=48
#SBATCH --mem-per-cpu=8000M
#SBATCH --time=7-00:00:00
#SBATCH --job-name=accv_exp
#SBATCH --output=logs/exp_%j.log
#SBATCH --error=logs/exp_%j.log
set -euo pipefail
cd "${SLURM_SUBMIT_DIR:-.}"   # accv2026/ (sbatch runs a spooled copy of this file)

EXP="$1"; shift || true
# drivers live in scripts/, the CLIs they launch in scripts/tools/
EXPF="scripts/$EXP"; [ -f "$EXPF" ] || EXPF="scripts/tools/$EXP"
[ -f "$EXPF" ] || { echo "no such experiment or tool: $EXP" >&2; exit 2; }
echo "[$(date +%T)] experiment $EXP  args: $*"
exec julia -t "${SLURM_CPUS_PER_TASK:-48}" --project=. \
    "$EXPF" "$@"
