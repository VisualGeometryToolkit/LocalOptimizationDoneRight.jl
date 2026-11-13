docs-pass: baa4fd6
landing: LocalOptimizationDoneRight/localoptimizationdoneright.github.io (no hand edit: the site is the Docs workflow's build of docs/src; it shows 0.7.0 once main's Docs job deploys it)

# 0.7.0 docs pass at the release (julia-docs-pass), resolved from General alone

The release tree is the wave branch's (153bc9f) with no temporary [sources] (only the members' own paths: accv2026 → .. and
lib/RansacLibLO) plus two commits: 32d4b86, accv2026's reproduce.sh regenerated with the registered Eval 0.8.0's generator
(it includes Core's canonical.jl for the run keys; RSDR's release gate caught the same staleness in its paper project), and
0a7086f, the CHANGELOG dated. Resolved from General (refreshed from GitHub) alone (job 15097): Core 0.10.0, IO 0.10.0,
Estimation 0.11.0, Eval 0.8.0, PoseLib 0.3.0, RANSACScoringDoneRight 0.8.0 (registered). floor_compat --raise: 0 entries
raised; --latest: 0.
[x] API diff, docstrings, README/landing/guides: unchanged since the wave pass below (no docs change in these commits).
[x] README test: the readme item resolves the install line from the registry in the release gate (the wave pass's open
    "known pre-registration failure" line below is closed by it).
[x] Docs build: docs/make.jl (strict, linkcheck) in the release gate.
[x] Re-recorded at baa4fd6 (owner ruling: no duplication entries): accv2026's tests use VisualGeometryToolkitEstimation 0.11.1's
    one copies (EpipolarScenes.fundmat_scene; lo_call_set_arm), make_fundmat_data / lo_call / lo_arm deleted (5e0ceb0); compat
    Estimation "0.11.1" (package, test, accv2026) from the registry resolve (job 15216), CHANGELOG names it. No docs change:
    docs/src, README and REPRODUCE.md name neither helper (grep).

---

docs-pass: e995245
landing: LocalOptimizationDoneRight/localoptimizationdoneright.github.io (no hand edit: the site is the Docs workflow's build of docs/src; it shows 0.7.0 once main's Docs job deploys it)

# 0.7.0 docs pass (julia-docs-pass) — the wave-10 stack, Julia 1.13

LocalOptimizationDoneRight 0.7.0 (breaking) on VisualGeometryToolkitCore 0.10, VisualGeometryToolkitEstimation 0.11
(accv2026: VisualGeometryToolkitEval 0.8, RANSACScoringDoneRight 0.8).
- [x] API diff since 0.6.2: no public name added, removed or re-signatured. The retired upstream names this package used
  (now `MinimalSolveProblem` in src/lift/lifts.jl and `Correspondences` in the PoseLib extension; the old names: CHANGELOG 0.7.0)
  are internal uses; the extension's `PoseLibWorkspace` (internal) is `PoseLibWorkspace{C}` and its docstring says so.
- [x] Docstrings: the `docs` item (every public name documented, attached, signatures matching) green at gate 42850cfe.
  One link fixed: `BarronAdaptive`'s docstring (src/strategies/types.jl:59) @extref'd
  `RANSACScoringDoneRight.StudentTUniformScoring`; the scorer is VisualGeometryToolkitCore's, linked there now.
- [x] README / landing / guides: no retired name (concept grep over docs/, README.md, accv2026/REPRODUCE.md for cspond,
  measurement, keypoint, the retired aliases); REPRODUCE.md updated for pool format 6 and the renamed ETH3D-SPLG binding.
  No version is named in the install lines.
- [x] Docs build (strict, linkcheck): green at gates 42850cfe (up-v6), eec82d9 (up-v8, PoseLib 0.3), 5a26b9b (up-v11, the outer stop rule) and 32e7c7d (up-v12, Core's one LM adapter; Julia 1.13.3).
- [ ] README test (fresh environment from the registry): a KNOWN PRE-REGISTRATION failure (coordinator, 2026-11-13): it
  cannot resolve Core 0.10 / Estimation 0.11 until the wave registers; it must pass in the final no-tmp gate.

---

docs-pass: 804bcef
landing: LocalOptimizationDoneRight/localoptimizationdoneright.github.io a2805ed (no hand edit: the site is the Docs workflow's build of docs/src, which says Julia 1.13 from this commit on; it shows 1.13 once main's Docs job deploys it)

# 0.6.2 docs pass (julia-docs-pass) — Julia 1.13

LocalOptimizationDoneRight 0.6.2 is a patch whose only change is the Julia requirement: `julia = "1.13"` in the `[compat]` of every
Project.toml in the repository, the CI workflows on Julia 1.13 only, and the CHANGELOG section.
- API diff since the last release: none (no source file under src/ or ext/ changed).
- Docstrings: unchanged; the suite's docs item runs in the fresh-clone gate.
- README / landing / guides: every statement of the required Julia version says 1.13 now: README.md, docs/src/index.md and accv2026/REPRODUCE.md.
  Mentions of Julia 1.12 left in test comments record why a bound or a workaround was set (LLVM 18 vs 20 rounding,
  Julia 1.12's docstring rules, which 1.13 keeps); they are history, not instructions.
- Re-recorded after the Downgrade workflow became on-demand only (CI and CHANGELOG only; no docs change).
- Docs build: run by the fresh-clone gate on Julia 1.13.3 against the registered stack (General from GitHub).

---

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
