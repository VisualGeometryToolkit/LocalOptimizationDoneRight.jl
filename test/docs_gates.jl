# docs_gates.jl — three docstring checks a package's suite runs (the stack's docs skill).
#
#   undocumented_public(M)       public names of M (and its submodules) with no docstring
#   signature_mismatches(M)      docstring signature lines that no method of the name accepts
#   detached_docstrings(srcdir)  a top-level docstring followed by a blank or comment line
#
# Each returns a vector of findings (strings); docs_tests.jl compares them to its
# allow-lists. Not a `*_tests.jl` file, so ReTestItems does not discover it; the
# item includes it. Hoisting it into src/quality (beside check_naming) would let
# every stack package call it instead of copying it.

using Base.Docs: Binding, aliasof

submodules(M::Module) = unique!(Module[M; [getfield(M, n) for n in names(M; all = true)
    if isdefined(M, n) && getfield(M, n) isa Module && parentmodule(getfield(M, n)) === M && getfield(M, n) !== M]])

"""Every binding documented in the modules `mods`, wherever its docstring was written."""
documented(mods) = Set(b for S in mods for b in keys(Docs.meta(S)))

function has_docstring(docs::Set, M::Module, n::Symbol)
    b = Binding(M, n)
    return b in docs || aliasof(getfield(M, n), b) in docs
end

function undocumented_public(M::Module)
    mods = submodules(M)
    docs = documented(mods)
    out = String[]
    for S in mods, n in names(S; all = true)
        (Base.ispublic(S, n) && isdefined(S, n) && n !== nameof(S)) || continue
        owner = try Base.binding_module(S, n) catch; S end
        owner === S || continue          # a re-export: reported where it is defined, or its package's
        has_docstring(docs, S, n) || push!(out, S === M ? string(n) : string(nameof(S), ".", n))
    end
    return sort!(out)
end

# The signature lines of a docstring: the leading indented block (Julia's
# convention), each line `name(args...; kws...) [-> T]` or `name::T`.
function signature_lines(text::AbstractString)
    lines = String[]
    for l in split(text, '\n')
        if startswith(l, "    ")
            push!(lines, strip(l))
        elseif !isempty(strip(l))
            break        # prose ends the signature block; a blank line between signature groups does not
        end
    end
    return lines
end

callof(ex) = ex isa Expr && ex.head === :(->) ? callof(ex.args[1]) :
             ex isa Expr && ex.head === :(::) && length(ex.args) == 2 ? callof(ex.args[1]) :
             ex isa Expr && ex.head === :where ? callof(ex.args[1]) : ex

basename_of(f) = f isa Symbol ? f : f isa Expr && f.head === :. ? basename_of(f.args[end]) :
                 f isa QuoteNode ? f.value : f isa Expr && f.head === :curly ? basename_of(f.args[1]) : nothing

"""(name, required, total, keywords) of a docstring call line, or nothing when it is not one.
A line with an elided argument list (`s₁, …, s₅`, `s₁..s₇`) or two alternatives
(`f(a) / f(b)`) is prose, not a signature, and is skipped."""
function parse_signature(line)
    (occursin('…', line) || occursin("..", replace(line, "..." => "")) || occursin(" / ", line)) && return nothing
    ex = try Meta.parse(line; raise = true) catch; return nothing end
    c = callof(ex)
    (c isa Expr && c.head === :call) || return nothing
    name = basename_of(c.args[1])
    name === nothing && return nothing
    req = 0; tot = 0; kws = Symbol[]; vararg = false
    for a in c.args[2:end]
        if a isa Expr && a.head === :parameters
            for k in a.args
                k isa Expr && k.head === :... && continue
                s = k isa Symbol ? k : k isa Expr && k.head === :kw ? callof(k.args[1]) : k isa Expr && k.head === :(::) ? k.args[1] : nothing
                s isa Symbol && push!(kws, s)
            end
        elseif a isa Expr && a.head === :vect               # [optional]
            tot += length(a.args)
        elseif a isa Expr && a.head === :kw                  # optional = default
            tot += 1
        elseif a isa Expr && a.head === :...
            vararg = true
        else
            req += 1; tot += 1
        end
    end
    return (; name, req, tot = vararg ? typemax(Int) : tot, kws)
end

function accepts(m::Method, sig)
    n = m.nargs - 1
    va = m.isva
    lo = va ? n - 1 : n
    (va ? sig.tot >= lo : (sig.req <= n <= sig.tot)) || return false
    isempty(sig.kws) && return true
    mk = Base.kwarg_decl(m)
    return any(endswith("..."), string.(mk)) || all(in(mk), sig.kws)
end

function signature_mismatches(M::Module)
    mods = submodules(M)
    docs = documented(mods)
    out = String[]
    for S in mods, (b, multi) in Docs.meta(S)
        isdefined(b.mod, b.var) || continue
        obj = getfield(b.mod, b.var)
        obj isa Function || continue
        ms = collect(methods(obj))
        isempty(ms) && continue
        for d in values(multi.docs)
            text = join(string.(d.text))
            for l in signature_lines(text)
                sig = parse_signature(l)
                sig === nothing && continue
                startswith(string(sig.name), r"[@.]") && continue   # a macro; `Base.+(…)` parses as a broadcast
                if sig.name !== b.var
                    # A docstring that also shows a SIBLING's signature is fine when the sibling
                    # has its own docstring; otherwise the sibling is documented only here — or
                    # this docstring sits on the wrong definition.
                    if isdefined(S, sig.name) && !has_docstring(docs, S, sig.name)
                        push!(out, "$(b.var): its docstring shows $(sig.name), which has none of its own: $l")
                    end
                elseif !any(m -> accepts(m, sig), ms)
                    push!(out, "$(b.var): no method accepts: $l")
                end
            end
        end
    end
    return sort!(unique!(out))
end

# A docstring the parser did not attach — a comment line or a helper between it
# and its definition (Julia 1.12) — is a bare string statement at module level:
# it documents NOTHING. Parsed, not pattern-matched, so `raw"""`, `@doc` blocks,
# one-line and indented docstrings are all read as the running Julia reads them.
_is_bare_string(ex) = ex isa String || (ex isa Expr && ex.head === :string) ||
    (ex isa Expr && ex.head === :macrocall && ex.args[1] in (Symbol("@raw_str"), Symbol("@doc_str")))

function _bare_strings!(out, ex, where)
    line = 0
    for a in (ex isa Expr ? ex.args : ())
        if a isa LineNumberNode
            line = a.line
        elseif _is_bare_string(a)
            push!(out, "$where:$line")
        elseif a isa Expr && a.head === :module
            _bare_strings!(out, a.args[3], where)
        elseif a isa Expr && a.head === :macrocall && a.args[end] isa Expr && a.args[end].head === :module
            # a documented module (`"""doc""" module X … end` parses as an @doc call around it): scan its body too
            _bare_strings!(out, a.args[end].args[3], where)
        elseif a isa Expr && a.head in (:block, :toplevel)
            _bare_strings!(out, a, where)
        end
    end
    return out
end

function detached_docstrings(srcdir::AbstractString)
    out = String[]
    for (root, _, files) in walkdir(srcdir), f in files
        endswith(f, ".jl") || continue
        path = joinpath(root, f)
        _bare_strings!(out, Meta.parseall(read(path, String); filename = path), relpath(path, srcdir))
    end
    return out
end
