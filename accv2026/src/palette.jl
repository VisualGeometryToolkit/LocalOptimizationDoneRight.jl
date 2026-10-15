# =============================================================================
# src/palette.jl — the colours and STYLE rows of the paper's SELECTION scorers
# and of the composed arms the faceted arm registry does not carry (the
# MSAC-seeded arms, the E-only adaptive-TLS control). Every registry arm
# (figure_style.jl) is styled by the registry alone — its STYLE row, colour
# name and hex are derived there — so no arm has two styles. Loaded by
# config.jl AFTER labels.jl and arm_rosters.jl (the rows consume SEL_LABEL and
# the arm table's `composed_label`).
#
# Colours are emitted as `\providecolor{Color<key>}{HTML}{<hex>}` (the paper's
# own definitions, figures/fig_colors.tex, are loaded first and win). The
# selector hues that ARE the house palette (VisualGeometryEval
# `default_palette()`) are looked up there, never re-typed. Both tables feed
# `PAPER_STYLE` (figure_style.jl), the one value every renderer is handed.
# =============================================================================

using VisualGeometryCore: lo_label, lo_marker

const _HOUSE = Dict(default_palette())
"Colour name => hex of the selection scorers and the composed arms outside the faceted rows."
const PALETTE_COLORS = [paper_color_name(key) => hex for (key, hex) in (
    # Selection scorers ("<TAG> sel", the producer's selector rows): the house
    # hue of each score where it has one.
    "IG  sel"       => _HOUSE["IG-Robust"],   # the Stu-tU marginal score
    "MSAC sel"      => _HOUSE["MAGSAC"],      # house orange
    "RANSAC sel"    => _HOUSE["RANSAC"],
    "GAU sel"       => _HOUSE["GaU"],
    "MAGSAC sel"    => "9a6324",              # brown: apart from MSAC-sel orange
    "SIMFIT sel"    => "000075",              # navy, apart from the orange/brown RANSAC family
    "WEL sel"       => "911eb4",
    "GEM sel"       => "808000",
    "WMG sel"       => "f032e6",              # marginal Welsch (scale integrated)
    # Composed arms outside the faceted registry.
    "IG  +TLSadapt" => "1f77b4",              # composed adaptive-loss-width truncated LM (loss width = scale_multiple·ŝ per round)
    "MSAC +PoseLib" => "b5530b",
    "MSAC +LO"      => "b5530b",              # the archived bundles' name for MSAC +PoseLib
    "MSAC +LZ"      => "d62728",
)]

# Style rows: (method key in a summary, display label, pgf colour name, mark,
# dashed?). Legend order = row order; the faceted arms are appended by
# figure_style.jl. A composed label is score + LO — the score is never omitted.
const PALETTE_ROWS = [
    ("IG  sel",       arm_label(:ig),                            paper_color_name("IG  sel"),       "*",         false),
    ("MSAC sel",      arm_label(:msac),                          paper_color_name("MSAC sel"),      "square*",   false),
    ("RANSAC sel",    "RANSAC~\\cite{Fischler1981}",             paper_color_name("RANSAC sel"),    "x",         false),
    ("MAGSAC sel",    "MAGSAC++~\\cite{Barath2020}",             paper_color_name("MAGSAC sel"),    "star",      false),
    ("SIMFIT sel",    "SIMFIT++~\\cite{Edstedt2025}",            paper_color_name("SIMFIT sel"),    "pentagon*", false),
    ("GAU sel",       "GaU~\\cite{Shekhovtsov2025}",             paper_color_name("GAU sel"),       "triangle*", false),
    ("WEL sel",       "Welsch",                                  paper_color_name("WEL sel"),       "o",         false),
    ("GEM sel",       "Geman--McClure",                          paper_color_name("GEM sel"),       "triangle",  false),
    ("WMG sel",       "Welsch-marginal",                         paper_color_name("WMG sel"),       "square",    false),
    # Composed adaptive-TLS control: label and marker are the
    # strategy's own traits (PoseLibLmAdaptLossWidth: TLS-IRLS-ŝ, square* = re-estimates
    # its scale during refinement, the fig:supp-corrupt convention).
    ("IG  +TLSadapt", SEL_SHORT[:ig] * "+" * lo_label(PoseLibLmAdaptLossWidth()), paper_color_name("IG  +TLSadapt"),
                      String(lo_marker(PoseLibLmAdaptLossWidth())), true),
    ("MSAC +PoseLib", composed_label(ARM_TABLE["MSAC +PoseLib"]),     paper_color_name("MSAC +PoseLib"), "square",    true),
    ("MSAC +LO",      composed_label(ARM_TABLE["MSAC +PoseLib"]),     paper_color_name("MSAC +LO"),      "square",    true),
    ("MSAC +LZ",      composed_label(ARM_TABLE["MSAC +LZ"]),          paper_color_name("MSAC +LZ"),      "diamond",   true),
]
