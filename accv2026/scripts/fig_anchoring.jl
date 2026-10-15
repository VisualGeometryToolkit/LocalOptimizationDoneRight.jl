#!/usr/bin/env julia
# =============================================================================
# scripts/fig_anchoring.jl — MAIN-PAPER partition-anchoring figure
# (figures/panel_anchoring_paired.tex): a PAIRED ABLATION of anchoring the
# local optimizer's scale to the seed partition, at ONE set of operating
# points. Pairs share a hue; DASHED = WITHOUT anchoring, SOLID = WITH.
#
# ONE tuning — fig3's sequential CV (stage cv) — read out twice
# on the same ζ ladder, test scenes and seeds:
#   WITH    : fig3's own ζ evaluation — the deployed arms, the scale-multiple
#             arms' loss width scale_multiple·ŝ partition-anchored (immune to ζ).
#   WITHOUT : stage evaluation below — the SAME tuned operating points, the
#             scale-multiple arms' loss width delivered at a FIXED external
#             plug-in scale corrupted by ζ (the scale interface of
#             configs/miscal_protocol.toml [anchoring_ablation]: "fixed_scale" =
#             `with_width(lo, fixed_width(lo, (ζ·s0)²))`, s0 the reference scale of
#             the validation pairs' ORACLE σ̂² — pt_e_miscal.toml
#             [sequential_cv] plugin_scale), so the loss width slides with ζ.
# The contrast isolates the scale interface: nothing else differs.
#
# DATA INPUTS
#   with    : EXP_ANCHOR_WITH (fig3_composed_miscal.jl stage cv; audited)
#   without : EXP_ANCHOR_WITHOUT (stage evaluation of this experiment)
#   pool    : PT-E-SIFT-4K_pf3 (fig3's; the evaluation re-streams its test scenes)
# STAGES
#   evaluation (GPU) → EXP_ANCHOR_WITHOUT (run_sequential_cv.jl --stage=anchoring)
#   render  (CPU) → figures/panel_anchoring_paired.tex
# =============================================================================
using DrWatson; @quickactivate "ACCV2026"
using JLD2
include(srcdir("cell_stages.jl"))   # config + common + registry; zeta_ladder_args

const PANEL = joinpath(PAPER_FIGDIR, "panel_anchoring_paired.tex")

_require_with() = (require_input(EXP_ANCHOR_WITH; what = "WITH-anchoring sidecar (fig3's tuning)",
                                 provenance = "fig3_composed_miscal.jl stage cv");
                   audit_operating_points(ROSTER, EXP_ANCHOR_WITH))   # operating points must satisfy the gate

STAGES = Stage[]
# The WITHOUT evaluation: fig3's tuned points under the ablation's scale
# interface, through the sequential-CV tool's anchoring stage (its operating
# points, ζ ladder and s0 are fig3's sidecar's, checked there).
push!(STAGES, Stage(:evaluation,
        "WITHOUT: fig3's operating points at scale interface \"$(EXP_ANCHOR_SCALE_INTERFACE)\" → $(EXP_ANCHOR_WITHOUT)",
        () -> fresher(EXP_ANCHOR_WITHOUT, EXP_ANCHOR_WITH),
        () -> begin
            _require_with()
            # The sequential CV's anchoring stage, on fig3's own keyed cell: its
            # effective config (written by the cv stage) and its directory, which
            # it writes EXP_ANCHOR_WITHOUT under — the scale interface and the ζ
            # ladder come from the same TOMLs registry.jl derives the path from.
            run_driver("run_sequential_cv.jl", "--config=$(joinpath(EXP_MISCAL_DIR, "_config.toml"))",
                       "--outdir=$(EXP_MISCAL_DIR)", "--stage=anchoring")
            isfile(EXP_ANCHOR_WITHOUT) ||
                error("fig_anchoring: the anchoring stage did not write $(EXP_ANCHOR_WITHOUT)")
        end))
push!(STAGES, Stage(:render,
        "paired with/without-anchoring ζ panel → $(PANEL)",
        () -> fresher(PANEL, EXP_ANCHOR_WITH, EXP_ANCHOR_WITHOUT),
        () -> begin
            _require_with()
            require_input(EXP_ANCHOR_WITHOUT; what = "WITHOUT-anchoring ζ evaluation",
                          provenance = "stage evaluation of this experiment")
            run_driver("render_anchoring_paired.jl";
                       env = Dict("EVALUATION_WITHOUT" => EXP_ANCHOR_WITHOUT,
                                  "EVALUATION_WITH" => EXP_ANCHOR_WITH,
                                  "OUT" => PANEL,
                                  "DEPLOY" => "1"))
        end))

run_stages("fig_anchoring", STAGES)
