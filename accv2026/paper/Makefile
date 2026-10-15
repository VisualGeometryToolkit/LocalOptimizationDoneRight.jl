MAIN = main
SUPP = supplement
LATEXMK = latexmk
LATEXMKFLAGS = -pdf -interaction=nonstopmode -halt-on-error

.DEFAULT_GOAL := all

.PHONY: all main supplement force force-supplement watch clean distclean

# Always delegate to latexmk: it tracks all dependencies (figures, .bib,
# .sty) itself and is a no-op when everything is current.
# main.tex cross-references supplement.aux (xr-hyper), so the supplement builds first.
all: main

main: supplement
	$(LATEXMK) $(LATEXMKFLAGS) $(MAIN)

supplement:
	$(LATEXMK) $(LATEXMKFLAGS) $(SUPP)

# Full rebuild that also clears the aux files a killed run can corrupt.
# No -halt-on-error here: with a fresh aux, the first pass legitimately
# errors on \pgfplotslegendfromname (legends live in the aux) and must be
# allowed to continue so later passes can resolve them.
force: force-supplement
	rm -f $(MAIN).aux $(MAIN).toc $(MAIN).lot $(MAIN).lof $(MAIN).out $(MAIN).brf $(MAIN).fdb_latexmk $(MAIN).blg
	pdflatex -interaction=nonstopmode $(MAIN) >/dev/null || true
	$(LATEXMK) $(LATEXMKFLAGS) $(MAIN)

force-supplement:
	rm -f $(SUPP).aux $(SUPP).out $(SUPP).fdb_latexmk $(SUPP).fls $(SUPP).blg
	pdflatex -interaction=nonstopmode $(SUPP) >/dev/null || true
	$(LATEXMK) $(LATEXMKFLAGS) $(SUPP)

watch:
	$(LATEXMK) $(LATEXMKFLAGS) -pvc $(MAIN)

clean:
	$(LATEXMK) -c $(MAIN)
	$(LATEXMK) -c $(SUPP)
	rm -f $(MAIN).bbl $(MAIN).brf $(MAIN).run.xml $(MAIN).synctex.gz

distclean: clean
	$(LATEXMK) -C $(MAIN)
	$(LATEXMK) -C $(SUPP)
