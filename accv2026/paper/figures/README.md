# paper/figures — generated artifacts only

Every file here is written by a driver's render stage (`scripts/*.jl`, which
deploy into `PAPER_FIGDIR`; see `../../REPRODUCE.md` for the experiment →
artifact index), except `fig_colors.tex`, the hand-maintained colour table the
figures name. Nothing else here is edited by hand, and no tool lives here.
Two classes, and nothing else:

1. **Inputs of the paper** — `\input{figures/<name>}` in `main.tex` or
   `supplement.tex`. These are the deliverables.
2. **Grid rows** — the per-dataset panels the two main-paper grids compose
   (`fig3_miscal_grid.jl`, `fig4_budget_grid.jl` stack them; the rows are
   named in `configs/fig3_miscal_grid.toml` and `configs/fig4_budget_grid.toml`):
   `panel_lo_miscal{,_eth_F_main,_heb_H_main}.tex` and
   `panel_sample_budget_{faceted,eth_F,heb_H}.tex`.

`paper_numbers.tex` (`scripts/paper_numbers.jl`, `configs/paper_numbers.toml`)
is THE one generated macro file: every number `main.tex` and `supplement.tex`
state (`test/test_paper_numbers.jl` refuses a hand-typed one).
