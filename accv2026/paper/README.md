# The ACCV 2026 paper — camera-ready sources

`main.tex` (the paper) and `supplement.tex` (its supplementary material), in
the ACCV / LNCS style (`llncs.cls`, `accv.sty`, `splncs04.bst`). Every figure,
table and number they read is generated into `figures/` by the drivers of
`../scripts/` (`../REPRODUCE.md` indexes each asset with its generator;
`figures/paper_numbers.tex` holds every number macro).

    make            # supplement.pdf, then main.pdf (main cross-references the supplement)
    make force      # full rebuild from clean aux files
