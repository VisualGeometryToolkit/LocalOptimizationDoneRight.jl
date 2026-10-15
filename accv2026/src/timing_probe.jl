# =============================================================================
# src/timing_probe.jl — what a pinned timing worker records about the machine
# around its timed repeat (scripts/tools/e2e_time_ours.jl and the SupeRANSAC
# worker's `--mode=time`, scripts/tools/superansac_worker.jl; src/e2e_timing.jl
# reads the records). Pure Base, Linux /proc and /sys only, so it loads in this
# project and in the SupeRANSAC environment alike.
#
#   timing_host()            host, CPU model, kernel, Julia
#   timing_affinity()        the CPUs this process may run on (Cpus_allowed_list)
#   timing_snapshot(cpu)     load averages, the pinned CPU's and its SMT
#                            siblings' /proc/stat ticks, this process's CPU ticks
#   timing_window(a, b, cpu) the busy share of the pinned CPU taken by OTHER
#                            processes, and of each sibling, between two snapshots
# =============================================================================
if !@isdefined(ACCV2026_TIMING_PROBE_LOADED)

"The load averages (1, 5, 15 min) of /proc/loadavg."
timing_loadavg() = parse.(Float64, split(read("/proc/loadavg", String))[1:3])

"The CPUs this process may run on (its Cpus_allowed_list, e.g. \"100\")."
function timing_affinity()
    for l in eachline("/proc/self/status")
        startswith(l, "Cpus_allowed_list:") && return strip(split(l, ':')[2])
    end
    error("timing_affinity: no Cpus_allowed_list in /proc/self/status")
end

"The SMT siblings of `cpu` (itself excluded)."
function timing_siblings(cpu::Integer)
    s = strip(read("/sys/devices/system/cpu/cpu$(cpu)/topology/thread_siblings_list", String))
    out = Int[]
    for part in split(s, ',')
        r = parse.(Int, split(part, '-'))
        append!(out, length(r) == 1 ? r : r[1]:r[2])
    end
    return filter(!=(cpu), out)
end

# (busy, total) ticks of one CPU's /proc/stat line: busy = total − idle − iowait.
function _cpu_ticks(cpu::Integer)
    for l in eachline("/proc/stat")
        f = split(l)
        f[1] == "cpu$(cpu)" || continue
        v = parse.(Int, f[2:end])
        return (busy = sum(v) - v[4] - v[5], total = sum(v))
    end
    error("timing_snapshot: no cpu$(cpu) in /proc/stat")
end

# This process's CPU ticks (utime + stime, /proc/self/stat fields 14 and 15).
function _self_ticks()
    s = read("/proc/self/stat", String)
    f = split(s[findlast(')', s)+2:end])   # fields from 3 on
    return parse(Int, f[12]) + parse(Int, f[13])
end

"A snapshot around a timed repeat: wall time, load averages, the CPU's and its siblings' ticks, this process's ticks."
timing_snapshot(cpu::Integer) =
    (; time_ns = time_ns(), loadavg = timing_loadavg(), cpu = _cpu_ticks(cpu),
       siblings = [_cpu_ticks(c) for c in timing_siblings(cpu)], self = _self_ticks())

"""
    timing_window(a, b, cpu) -> Dict

What happened on the machine between snapshots `a` and `b`: the load averages
at both ends, the share of the pinned CPU's busy time taken by OTHER processes
(its busy ticks minus this process's, over its total ticks) and the busy share
of each SMT sibling.
"""
function timing_window(a, b, cpu::Integer)
    dt(x, y) = max(y.total - x.total, 1)
    other = ((b.cpu.busy - a.cpu.busy) - (b.self - a.self)) / dt(a.cpu, b.cpu)
    return Dict{String,Any}("cpu" => Int(cpu), "seconds" => (b.time_ns - a.time_ns) / 1e9,
                            "loadavg_before" => a.loadavg, "loadavg_after" => b.loadavg,
                            "cpu_other_busy" => max(other, 0.0),
                            "sibling_cpus" => timing_siblings(cpu),
                            "sibling_busy" => [(y.busy - x.busy) / dt(x, y) for (x, y) in zip(a.siblings, b.siblings)])
end

"The host record of a timing repeat."
function timing_host()
    model = ""
    for l in eachline("/proc/cpuinfo")
        startswith(l, "model name") && (model = strip(split(l, ':'; limit = 2)[2]); break)
    end
    return Dict{String,Any}("hostname" => gethostname(), "cpu_model" => model,
                            "kernel" => strip(read("/proc/sys/kernel/osrelease", String)),
                            "julia" => string(VERSION), "affinity" => timing_affinity(),
                            "julia_threads" => Threads.nthreads())
end

"Refuse a timing repeat that is not pinned to exactly `cpu` and single-threaded."
function check_timing_pinning(cpu::Integer)
    timing_affinity() == string(cpu) ||
        error("timing repeat: pinned to CPUs $(timing_affinity()), expected exactly $(cpu) (launch through the cell's numactl recipe)")
    Threads.nthreads() == 1 || error("timing repeat: $(Threads.nthreads()) Julia threads, expected 1")
    return nothing
end

const ACCV2026_TIMING_PROBE_LOADED = true
end # include guard
