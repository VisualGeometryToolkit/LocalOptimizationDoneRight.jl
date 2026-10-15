#!/usr/bin/env python3
# Three-dataset facet grids of the main paper and their supplement median
# counterparts: Fig 3 (scale miscalibration, fig3_miscal_grid.jl) and Fig 4
# (sample budget, fig4_budget_grid.jl). The renderer-emitted faceted panels of
# N datasets (each 3 objective facets x 1 or 2 statistic rows) are stacked into
# ONE 3-by-N groupplot: columns = objectives, rows = datasets. Per-facet axis
# options, coordinates, colours, markers and the row's y label are copied
# verbatim from the panels; only the row label, the column titles (top row) and
# the x label are set here. Nothing is recomputed.
#   python3 make_facet_grid.py --rows=maa|med --out=<tex> --legend=<pgfplots legend name> \
#       --xopts=budget|shared --panels="PhotoTourism E=<pt.tex>;ETH3D F=<eth.tex>;HEB H=<heb.tex>"
#   --xopts=budget : every row has its own x range (sample budgets differ per
#                    dataset) — padded limits, at most four ticks, x label per row;
#   --xopts=shared : the rows share one x axis (the zeta sweep) — the group
#                    header's x options are copied verbatim, tick labels and the
#                    x label appear on the bottom row only.
#   --yaxes="lo:hi:step;lo:hi:step;..." (optional, one entry per row, empty entry
#                    keeps the panel's own axis): the figure's y range for the
#                    drawn statistic row — a figure-level choice owned by the
#                    figure's driver, so no experiment is re-keyed for it.
#   --xtick="t1,t2,..." / --xticklabels="L1|L2|..." (optional, --xopts=shared
#                    only): the figure's ticks and tick labels for the shared x
#                    axis (one label per tick, refused otherwise; --xtick absent
#                    keeps the panels' ticks) — e.g. 2^k every three octaves in
#                    place of 1/64..64 every two, which collide at the grid's
#                    column width. In shared mode only the BOTTOM row is labelled.
#   --oracle=0        drop the black oracle reference curves and their legend entry.
#   --ytick-spacing=S every row WITHOUT a --yaxes entry gets ticks every S on a range
#                    fitted to its plotted curves (min/max rounded outward to S),
#                    and no minor ticks.
import re, os, sys
ARGS=dict(a.lstrip('-').split('=',1) for a in sys.argv[1:] if '=' in a)
ROWS=ARGS.get('rows','maa'); OUT=ARGS['out']; LEGNAME=ARGS['legend']; XMODE=ARGS.get('xopts','budget')
PANELS=[p.split('=',1) for p in ARGS['panels'].split(';') if p]
YAXES=[y for y in ARGS.get('yaxes','').split(';')] if ARGS.get('yaxes') else []
XTICKLABELS=ARGS['xticklabels'].split('|') if ARGS.get('xticklabels') else None
XTICK=ARGS.get('xtick') or None
ORACLE=ARGS.get('oracle','1')!='0'
YTICK_SPACING=float(ARGS['ytick-spacing']) if ARGS.get('ytick-spacing') else None
if (XTICKLABELS is not None or XTICK is not None) and XMODE!='shared':
    sys.exit("--xtick/--xticklabels are defined for --xopts=shared only")
NFACETS=3

def yaxis_override(opts, spec):
    """replace ymin/ymax/ytick in a facet's options by the figure's lo:hi:step."""
    if not spec: return opts
    lo,hi,st=(float(v) for v in spec.split(':'))
    n=int(round((hi-lo)/st)); ticks=[lo+i*st for i in range(n+1)]
    fmt=lambda v: ('%g'%round(v,6))
    opts=re.sub(r'ymin=\{[^{}]*\}', 'ymin={%s}'%fmt(lo), opts)
    opts=re.sub(r'ymax=\{[^{}]*\}', 'ymax={%s}'%fmt(hi), opts)
    opts=re.sub(r'ytick=\{[^{}]*\}', 'ytick={%s}'%','.join(fmt(t) for t in ticks), opts)
    return opts

def group_xopts(s):
    """x-axis options of the panel's group header (xmode/log basis/xmin/xmax/xtick/xticklabels)."""
    hdr=re.search(r'\\begin\{groupplot\}\[(.*?)\]\s*\\nextgroupplot', s, re.S).group(1)
    g={}
    for key in ('xmode','log basis x','xmin','xmax','xtick','xticklabels'):
        m=re.search(r'(?<![a-z])'+re.escape(key)+r'\s*=\s*(\{[^{}]*\}|[^,\]\s]+)', hdr)
        if m: g[key]=m.group(1).strip('{}')
    mx=re.search(r'xlabel=\{([^{}]*)\}', hdr)
    if XMODE=='shared':      # verbatim: the rows share this axis
        if XTICK is not None: g['xtick']=XTICK
        if XTICKLABELS is not None:
            nt=len([t for t in g.get('xtick','').split(',') if t])
            if nt!=len(XTICKLABELS):
                sys.exit("--xticklabels: %d labels for %d ticks (%s)"%(len(XTICKLABELS),nt,g.get('xtick','')))
            g['xticklabels']=','.join(XTICKLABELS)
        keep=["%s={%s}"%(k,g[k]) for k in ('xmode','log basis x','xmin','xmax','xtick','xticklabels') if k in g]
        return ", ".join(keep), (mx.group(1) if mx else "")
    # Facets sit 6pt apart: pad the x limits past the outer ticks and keep at
    # most four labelled ticks so neighbouring facets' edge labels never touch.
    log='xmode' in g and 'log' in g['xmode']
    lo,hi=float(g['xmin']),float(g['xmax'])
    lo,hi=(lo/1.3,hi*1.3) if log else (max(0.0,lo-0.03*(hi-lo)),hi+0.03*(hi-lo))
    ticks=[t for t in g.get('xtick','').split(',') if t]
    while len(ticks)>4: ticks=ticks[::2] if len(ticks)%2 else ticks[:-1][::2]+[ticks[-1]]
    keep=[]
    if log: keep+=["xmode=log", "log basis x=%s"%g.get('log basis x','2')]
    fmt=lambda v: ('%g'%v)
    keep+=["xmin=%s"%fmt(lo), "xmax=%s"%fmt(hi), "xtick={%s}"%",".join(ticks), "xticklabels={%s}"%",".join(ticks)]
    return ", ".join(keep), (mx.group(1) if mx else "sample budget")

def strip_opts(opts):
    """per-facet options minus title/ylabel/legend/yticklabels (re-set here)."""
    opts=re.sub(r',?\s*legend to name=[^,\]]+(,\s*legend [^\]]*?)?(?=,\s*[a-z]|$)', '', opts)
    opts=re.sub(r',?\s*legend (columns|cell align|style)=(\{(?:[^{}]|\{[^{}]*\})*\}|[^,\]]+)', '', opts)
    opts=re.sub(r',?\s*title=\{(?:[^{}]|\{[^{}]*\})*\}', '', opts)
    opts=re.sub(r',?\s*ylabel=\{(?:[^{}]|\{[^{}]*\})*\}', '', opts)
    opts=re.sub(r',?\s*yticklabels=\{\}', '', opts)
    return opts.strip(', ')

def parse(path):
    s=open(path).read()
    legend=re.findall(r'\\addlegendimage\{((?:[^{}]|\{[^{}]*\})*)\}\s*\\addlegendentry\{([^}]*)\}', s)
    blocks=re.split(r'\\nextgroupplot', s)[1:]
    nrows=len(blocks)//NFACETS
    row=0 if nrows==1 else (0 if ROWS=='med' else 1)     # legacy 2-row panels: median over mAA
    xopts,xlabel=group_xopts(s)
    facets=[]; stat=None
    for b in blocks[row*NFACETS:(row+1)*NFACETS]:
        opts=re.match(r'\[((?:[^\[\]]|\[[^\[\]]*\])*)\]', b).group(1)
        if stat is None:     # the row's statistic label is the panel's own y label
            m=re.search(r'ylabel=\{((?:[^{}]|\{[^{}]*\})*)\}', opts); stat=(m.group(1).split('\\\\')[-1] if m else '')   # a row-labelled panel stacks 'dataset\\stat'
        plots=re.findall(r'\\addplot\[((?:black|color=)[^\]]*)\]\s*coordinates\s*\{([^}]*)\}', b)
        facets.append((strip_opts(opts), plots))
    titles=[]
    for b in blocks[:NFACETS]:
        m=re.search(r'title=\{((?:[^{}]|\{[^{}]*\})*)\}', b); titles.append(m.group(1) if m else '')
    return legend, facets, titles, xopts, xlabel, stat

# Legend order = the emitters' walk: facets TLS | Welsch | GM (FAMILY_ORDER),
# arms by the paper's colour-ramp step within a facet (arm_order / `shade`):
# lightest to darkest, the Stu-tU arms closing the uniform-mixture facet.
FAM=['oracle','TLS-IRLS','TLS-LZ','TLS-LO','TLS-HQ','TLS-LO$^+$','TLS-GNC',r'Stu-$t$U-IRLS',r'Stu-$t$U-BCD',
     'Welsch-IRLS','Welsch-HQ','Welsch-GNC','GM-IRLS','GM-HQ','GM-GNC']
rows=[]; seen={}
for label,path in PANELS:
    legend,facets,titles,xopts,xlabel,stat=parse(path)
    # One legend entry for the oracle: every row's reference is the same construct
    # (best minimal model at each budget / pool-best minimal model; the caption
    # defines it), so the per-panel 'oracle (...)' labels collapse to 'oracle'.
    for o,l in legend: seen.setdefault('oracle' if l.startswith('oracle') else l, o)
    rows.append((label,facets,titles,xopts,xlabel,stat))
def famkey(l): return next((i for i,f in enumerate(FAM) if l==f or (l.startswith(f) and f!='TLS-LO')), len(FAM))
order=[l for l in sorted(seen, key=famkey) if ORACLE or l!='oracle']

ax=(r"scale only axis, width=0.265\linewidth, height=0.185\linewidth, "
    r"xmajorgrids, ymajorgrids, grid style={gray!20}, label style={font=\footnotesize}, "
    r"tick label style={font=\scriptsize}, ylabel style={align=center, font=\footnotesize}, "
    r"title style={font=\footnotesize, align=center}")
shared=(XMODE=='shared')
gstyle="group size=3 by %d, horizontal sep=6pt, vertical sep=%s"%(len(rows), "12pt, xticklabels at=edge bottom, xlabels at=edge bottom" if shared else "24pt")
o=["% Derived by figures/make_facet_grid.py (--rows="+ROWS+", --xopts="+XMODE+") from the renderer-emitted faceted panels; do not hand-edit.",
   r"\begin{tikzpicture}",
   r"\begin{groupplot}[group style={%s}, "%gstyle+ax+"]"]
import math
def fitted_yspec(facets, spacing):
    """lo:hi:spacing over a row's drawn curves (all facets), rounded outward to spacing."""
    ys=[float(y) for _,plots in facets for opt,cc in plots
        for y in re.findall(r'\(\s*[-0-9.eE]+\s*,\s*([-0-9.eE]+)\s*\)', cc)]
    if not ys: return ''
    lo=math.floor(min(ys)/spacing+1e-9)*spacing; hi=math.ceil(max(ys)/spacing-1e-9)*spacing
    if hi<=lo: hi=lo+spacing
    return '%g:%g:%g'%(round(lo,6),round(hi,6),spacing)
for ri,(label,facets,titles,xopts,xlabel,stat) in enumerate(rows):
    if not ORACLE:   # the black reference curves out, before any range is fitted
        facets=[(opts,[(o_,cc) for o_,cc in plots if not o_.startswith('black')]) for opts,plots in facets]
    yspec=YAXES[ri] if ri<len(YAXES) else ''
    if not yspec and YTICK_SPACING: yspec=fitted_yspec(facets, YTICK_SPACING)
    for c,(opts,plots) in enumerate(facets):
        cell=xopts+", "+yaxis_override(opts, yspec)
        if YTICK_SPACING:   # the spacing is the only grid: no minor ticks between
            cell=re.sub(r'minor y tick num=\{[^{}]*\}', 'minor y tick num={0}', cell)
            cell=re.sub(r',?\s*yminorgrids', '', cell)
        # the facets' own xticklabels override the group's `xticklabels at=edge
        # bottom`: in shared mode blank them above the bottom row explicitly
        if shared and ri<len(rows)-1: cell+=", xticklabels={}"
        cell+=(", ylabel={%s\\\\%s}"%(label,stat)) if c==0 else ", yticklabels={}"
        if ri==0: cell+=", title={%s}"%titles[c]
        # the x label once, under the bottom row's middle facet (every row shares
        # its meaning; a budget grid keeps its per-row tick labels)
        if c==1 and ri==len(rows)-1: cell+=", xlabel={%s}"%xlabel
        first=(ri==0 and c==0)
        if first:
            cell+=r", legend to name=%s, legend columns=5, legend cell align=left, legend style={draw=none, font=\footnotesize, /tikz/every even column/.append style={column sep=6pt}}"%LEGNAME
        o.append(r"\nextgroupplot[%s]"%cell)
        for opt,cc in plots:
            o.append(r"\addplot[%s] coordinates {%s};"%(opt if 'forget plot' in opt else opt+', forget plot', cc.strip()))
        if first:
            for l in order:
                o.append(r"\addlegendimage{%s}\addlegendentry{%s}"%(seen[l],l))
o+=[r"\end{groupplot}", r"\end{tikzpicture}"]
open(OUT,'w').write("\n".join(o)+"\n")
print("wrote",OUT,"| rows:",[r[0] for r in rows],"| legend:",order)
