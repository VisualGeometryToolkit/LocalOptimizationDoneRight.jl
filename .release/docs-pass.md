docs-pass: a2fe836
landing: LocalOptimizationDoneRight/localoptimizationdoneright.github.io c55bb03 (no change: a compat patch; nothing the site shows moved)

# 0.6.1 docs pass (julia-docs-pass) — on VisualGeometryToolkitEstimation 0.10

LocalOptimizationDoneRight 0.6.1 is a patch: `[compat]` VisualGeometryToolkitEstimation "0.10" in every member that declares it, and the
CHANGELOG section. No public name added, removed or re-signatured.
- API diff since the last release: none.
- stale mentions: nothing here names the SplineLens image-space refine Estimation 0.10.0 retired (its free route,
  `penalty`, the GCV and window metadata): checked by grep over src, docs, README and the paper projects.
- README / install lines: unchanged (no version is named); the README rows resolve the registry and pass once
  Estimation 0.10.0 is registered.

---

# LocalOptimizationDoneRight 0.6.0: docs pass

On the release tree: the bump 67d770e ("Bump version: LocalOptimizationDoneRight 0.5.1 → 0.6.0"), re-confirmed on fc68fdb (accv2026's RANSACScoringDoneRight compat 0.7, no docs-relevant change).

- Public API since v0.5.1:
  - Renames, each documented and in the manual, with every mention updated: `LO_TAGS` → `LODR_STRATEGY_TAGS`, `WELSCH_HQ_SCALE_MULTIPLE_*` → `WELSCH_HQ_EFFICIENCY_CONSTANT_*`, `scale_multiple` → `efficiency_constant`.
  - No public name was added. `truncated_refit_pose`'s signature line now states what it returns: a refined pose, never `nothing`.
  - The termination record (`lo_termination`, `success_rule`) is internal.
- Stale mentions: no retired name remains in README.md, docs/src, accv2026/README.md or REPRODUCE.md (`LO_TAGS`, `scale_multiple`, `AbstractLocalOptimization`, `local_optimization_from_toml`, `LeZachTruncation`, `Incumbent`, `ScaleMultiple`, `inlier_threshold`, `deployed_scale_multiple`, `plain_scale_multiple`, the hand-folded run-key fields).
- README and landing example (docs/src/index.md): the same block. It uses the current API (`local_optimization_strategy`, `efficiency_constant`, `inlier_mask`, Core's `StudentTUniformScoring`). The readme test runs it in a fresh environment from the install line at the fresh-clone gate, once RANSACScoringDoneRight 0.7.0 is registered.
- The landing site is the Documenter build of docs/ (the github.io repository, now at c55bb03). It is rebuilt and pushed with the publish.
- CHANGELOG.md holds the 0.6.0 heading and its Breaking list: the 0.9 stack, the PoseLib frame contract, accv2026's moved run keys, and the earlier entries.
