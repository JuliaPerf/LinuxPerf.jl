module LinuxPerf

using Printf
using PrettyTables
using Formatting

export @measure, @measured, @pstats
export make_bench, enable!, disable!, reset!, reasonable_defaults, counters

import Base: show, length

macro measure(expr, args...)
    esc(quote
        local bench
        _, bench = $LinuxPerf.@measured($expr, $(args...))
        $counters(bench)
    end)
end
macro measured(expr, events = reasonable_defaults)
    quote
        local bench = $make_bench($events);
        local v
        try
            $enable!(bench)
            v = $(esc(expr))
        finally
            $disable!(bench)
        end
        (v, bench)
    end
end

mutable struct perf_event_attr
    typ::UInt32
    size::UInt32
    config::UInt64
    sample_period_or_freq::UInt64
    sample_type::UInt64
    read_format::UInt64
    flags::UInt64
    wakeup_events_or_watermark::UInt32
    bp_type::UInt32
    bp_addr_or_config1::UInt64
    bp_len_or_config2::UInt64
    branch_sample_type::UInt64

    sample_regs_user::UInt64
    sample_stack_user::UInt32
    clockid::Int32
    sample_regs_intr::UInt64
    aux_watermark::UInt32
    __reserved_2::UInt32

end

perf_event_attr() = perf_event_attr(ntuple(x->0, fieldcount(perf_event_attr))...)

const PERF_TYPE_HARDWARE = 0
const PERF_TYPE_SOFTWARE = 1
const PERF_TYPE_TRACEPOINT = 2
const PERF_TYPE_HW_CACHE = 3
const PERF_TYPE_RAW = 4
const PERF_TYPE_BREAKPOINT = 5

const EVENT_TYPES =
    [
     (:hw, PERF_TYPE_HARDWARE, # PERF_TYPE_HARDWARE
      [(:cycles, 0), # PERF_COUNT_HW_CPU_CYCLES
       (:instructions, 1), # PERF_COUNT_HW_INSTRUCTIONS
       (:cache_access, 2), # PERF_COUNT_HW_CACHE_REFERENCES
       (:cache_misses, 3), # PERF_COUNT_HW_CACHE_MISSES
       (:branches, 4), # PERF_COUNT_HW_BRANCH_INSTRUCTIONS
       (:branch_mispredicts, 5), # PERF_COUNT_HW_BRANCH_MISSES
       (:bus_cycles, 6), # PERF_COUNT_HW_BUS_CYCLES
       (:stalled_cycles_frontend, 7), # PERF_COUNT_HW_STALLED_CYCLES_FRONTEND
       (:stalled_cycles_backend, 8), # PERF_COUNT_HW_STALLED_CYCLES_BACKEND
       (:scaled_cycles, 9) # PERF_COUNT_HW_REF_CPU_CYCLES
       ]),
     (:sw, PERF_TYPE_SOFTWARE,
      [(:cpu_clock, 0), # PERF_COUNT_SW_CPU_CLOCK
       (:task_clock, 1), # PEF_COUNT_SW_TASK_CLOCK
       (:page_faults, 2), # PERF_COUNT_SW_PAGE_FAULTS
       (:ctx_switches, 3), # PERF_COUNT_SW_CONTEXT_SWITCHES
       (:cpu_migrations, 4), # PERF_COUNT_SW_CPU_MIGRATIONS
       (:minor_page_faults, 5), # PERF_COUNT_SW_PAGE_FAULTS_MIN
       (:major_page_faults, 6), # PERF_COUNT_SW_PAGE_FAULTS_MAJ
       (:alignment_faults, 7), # PERF_COUNT_SW_ALIGNMENT_FAULTS
       (:emulation_faults, 8), # PERF_COUNT_SW_EMULATION_FAULTS
       (:dummy, 9), # PERF_COUNT_SW_DUMMY
       (:bpf_output, 10), # PERF_COUNT_SW_BPF_OUTPUT
       ])
     ]


# cache events have special encoding, PERF_TYPE_HW_CACHE
const CACHE_TYPES =
    [(:L1_data, 0),
     (:L1_insn, 1),
     (:LLC,   2),
     (:TLB_data, 3),
     (:TLB_insn, 4),
     (:BPU, 5),
     (:NODE, 6)]
const CACHE_OPS =
    [(:read, 0),
     (:write, 1),
     (:prefetch, 2)]
const CACHE_EVENTS =
    [(:access, 0),
     (:miss, 1)]

const PERF_FORMAT_TOTAL_TIME_ENABLED = 1 << 0
const PERF_FORMAT_TOTAL_TIME_RUNNING = 1 << 1
const PERF_FORMAT_GROUP = 1 << 3

struct EventType
    category::UInt32
    event::UInt64
end

function all_events()
    evts = EventType[]
    for (cat_name, cat_id, events) in EVENT_TYPES
        for (type_name, type_id) in events
            push!(evts, EventType(cat_id, type_id))
        end
    end
    evts
end

function Base.show(io::IO, e::EventType)
    if e.category == PERF_TYPE_HW_CACHE
        print(io, "cache:")
        cache = e.event & 0xff
        idx = findfirst(k -> k[2] == cache, CACHE_TYPES)
        print(io, idx == 0 ? cache : CACHE_TYPES[idx][1], ":")
        cache_op = (e.event & 0xff00) >> 8
        idx = findfirst(k -> k[2] == cache_op, CACHE_OPS)
        print(io, idx == 0 ? cache : CACHE_OPS[idx][1], ":")
        cache_event = (e.event & 0xff0000) >> 16
        idx = findfirst(k -> k[2] == cache_event, CACHE_EVENTS)
        print(io, idx == 0 ? cache : CACHE_EVENTS[idx][1])
    else
        for (cat_name, cat_id, events) in EVENT_TYPES
            cat_id == e.category || continue
            print(io, cat_name, ":")
            for (type_name, type_id) in events
                type_id == e.event || continue
                print(io, type_name)
                return
            end
            print(io, e.event)
            return
        end
        print(io, "event(", e.category, ":", e.event, ")")
    end
end

const SYS_perf_event_open = 298

"""
    perf_event_open(attr::perf_event_attr, pid, cpu, fd, flags)
"""
function perf_event_open(attr::perf_event_attr, pid, cpu, leader_fd, flags)
    r_attr = Ref(attr)
    GC.@preserve r_attr begin
        # Have to do a manual conversion, since the ABI is a vararg call
        ptr = Base.unsafe_convert(Ptr{Cvoid}, Base.cconvert(Ptr{Cvoid}, r_attr))
        fd = ccall(:syscall, Cint, (Clong, Clong...), SYS_perf_event_open,
                   ptr, pid, cpu, leader_fd, flags)
    end
    return fd
end

function EventType(cat::Symbol, event::Symbol)
    cat !== :cache || error("cache events needs 3 arguments")
    for (cat_name, cat_id, events) in EVENT_TYPES
        cat_name === cat || continue
        for (type_name, type_id) in events
            type_name === event || continue
            return EventType(cat_id, type_id)
        end
        error("event $event not found in $cat")
    end
    error("category $cat not found")
end

function EventType(cat::Symbol, cache::Symbol, op::Symbol, evt::Symbol)
    cat === :cache || error("only cache events takes 3 arguments")
    idx = findfirst(x -> x[1] === cache, CACHE_TYPES)
    idx != 0 || error("cache not found $cache")
    cache_id = CACHE_TYPES[idx][2]
    idx = findfirst(x -> x[1] === op, CACHE_OPS)
    idx != 0 || error("op not found $op")
    op_id = CACHE_OPS[idx][2]
    idx = findfirst(x -> x[1] === evt, CACHE_EVENTS)
    idx != 0 || error("cache event not found $evt")
    evt_id = CACHE_EVENTS[idx][2]
    return EventType(PERF_TYPE_HW_CACHE,
                     cache_id | (op_id << 8) | (evt_id << 16))
end

const EXCLUDE_NONE       = UInt(0)
const EXCLUDE_USER       = UInt(1) << 0
const EXCLUDE_KERNEL     = UInt(1) << 1
const EXCLUDE_HYPERVISOR = UInt(1) << 2

function exclude_flags(u, k, h)
    exclude = EXCLUDE_NONE
    u || (exclude |= EXCLUDE_USER)
    k || (exclude |= EXCLUDE_KERNEL)
    h || (exclude |= EXCLUDE_HYPERVISOR)
    return exclude
end

struct EventTypeExt
    event::EventType
    modified::Bool
    exclude::UInt  # bit flags
end

mutable struct EventGroup
    leader_fd::Cint
    fds::Vector{Cint}
    event_types::Vector{EventType}
    leader_io::IOStream

    function EventGroup(types::Vector{<:Union{EventType,EventTypeExt}};
                        warn_unsupported = true,
                        userspace_only = true,
                        pinned = false,
                        exclusive = false,
                        )
        my_types = EventType[]
        group = new(-1, Cint[], EventType[])

        for (i, evt_type) in enumerate(types)
            attr = perf_event_attr()
            attr.size = sizeof(perf_event_attr)
            if evt_type isa EventTypeExt
                attr.typ = evt_type.event.category
                attr.config = evt_type.event.event
            else
                attr.typ = evt_type.category
                attr.config = evt_type.event
            end
            attr.sample_period_or_freq = 0
            attr.flags = 0
            # first attribute becomes group leader
            if group.leader_fd == -1
                attr.flags |= (1 << 0) # start disabled
            end
            if pinned
                attr.flags |= (1 << 2)
            end
            if exclusive
                attr.flags |= (1 << 3)
            end
            # (1 << 4) exclude_user
            if userspace_only
                attr.flags |= (1 << 5) # exclude kernel
            end
            # (1 << 6) exclude hypervisor
            # (1 << 7) exclude idle

            if evt_type isa EventTypeExt
                if evt_type.exclude & EXCLUDE_USER != 0
                    attr.flags |= (1 << 4)
                end
                if evt_type.exclude & EXCLUDE_KERNEL != 0
                    attr.flags |= (1 << 5)
                end
                if evt_type.exclude & EXCLUDE_HYPERVISOR != 0
                    attr.flags |= (1 << 6)
                end
            end

            attr.read_format =
                PERF_FORMAT_GROUP |
                PERF_FORMAT_TOTAL_TIME_ENABLED |
                PERF_FORMAT_TOTAL_TIME_RUNNING

            fd = perf_event_open(attr, 0, -1, group.leader_fd, 0)
            if fd < 0
                errno = Libc.errno()
                if errno in (Libc.EINVAL,Libc.ENOENT)
                    if warn_unsupported
                        @warn("$evt_type not supported, skipping")
                    end
                    continue
                else
                    if errno == Libc.EACCES && !userspace_only
                        @warn("try to adjust /proc/sys/kernel/perf_event_paranoid to a value <= 1 or use user-space only events")
                    end
                    error("perf_event_open error : $(Libc.strerror(errno))")
                end
            end
            if evt_type isa EventTypeExt
                push!(group.event_types, evt_type.event)
            else
                push!(group.event_types, evt_type)
            end
            push!(group.fds, fd)
            if group.leader_fd == -1
                group.leader_fd = fd
                group.leader_io = fdio(fd)
            end
        end
        reset!(group)
        group
    end
end

Base.length(g::EventGroup) = length(g.event_types)

function Base.show(io::IO, g::EventGroup)
    println(io, "EventGroup(")
    for e in g.event_types[1:end-1]
        println(io, "\t", e, ",")
    end
    print(io, "\t", g.event_types[end], ")")
end

const PERF_EVENT_IOC_ENABLE =  UInt64(0x2400)
const PERF_EVENT_IOC_DISABLE = UInt64(0x2401)
const PERF_EVENT_IOC_RESET =   UInt64(0x2403)

function ioctl(group::EventGroup, x)
    res = ccall(:ioctl, Cint, (Cint, Clong, Clong), group.leader_fd, x, 1)
    Base.systemerror(:ioctl, res < 0)
    return nothing
end

enable!(g::EventGroup) = ioctl(g, PERF_EVENT_IOC_ENABLE)
disable!(g::EventGroup) = ioctl(g, PERF_EVENT_IOC_DISABLE)
reset!(g::EventGroup) = ioctl(g, PERF_EVENT_IOC_RESET)

function Base.close(g::EventGroup)
    for fd in g.fds
        fd == g.leader_fd && continue # close leader_fd last
        ccall(:close, Cint, (Cint,), fd)
    end
    ccall(:close, Cint, (Cint,), g.leader_fd)
end

mutable struct PerfBench
    groups::Vector{EventGroup}
end

struct Counter
    event::EventType
    value::UInt64
    enabled::UInt64
    running::UInt64
end

struct Counters
    counters::Vector{Counter}
end

function Base.show(io::IO, c::Counters)
    events = map(x -> x.event, c.counters)
    stats  = mapreduce(vcat, c.counters) do c
        c.enabled == 0 ? ["never enabled" "0 %"] :
            c.running == 0 ? ["did not run" "0 %"] :
                [format(Int64(c.value), commas=true) @sprintf("%.1f %%", 100*(c.running/c.enabled))]
    end
    return pretty_table(io, stats, ["Events", "Active Time"], row_names=events, alignment=:l, crop=:none, body_hlines=collect(axes(stats, 1)))
end

enable!(b::PerfBench) = foreach(enable!, b.groups)
disable!(b::PerfBench) = foreach(disable!, b.groups)
reset!(b::PerfBench) = foreach(reset!, b.groups)

Base.close(b::PerfBench) = foreach(close, b.groups)

function counters(b::PerfBench)
    c = Counter[]
    for g in b.groups
        values = Vector{UInt64}(undef, length(g)+1+2)
        read!(g.leader_io, values)
        #?Ref@assert(length(g) == values[1])
        enabled, running = values[2], values[3]
        for i = 1:length(g)
            push!(c, Counter(g.event_types[i], values[3+i],
                             enabled, running))
        end
    end
    Counters(c)
end

const reasonable_defaults =
    [EventType(:hw, :cycles),
     [EventType(:hw, :cache_access),
      EventType(:hw, :cache_misses)],
     [EventType(:hw, :branches),
      EventType(:hw, :branch_mispredicts),
      EventType(:hw, :instructions)],
     [EventType(:sw, :ctx_switches),
      EventType(:sw, :page_faults),
      EventType(:sw, :minor_page_faults),
      EventType(:sw, :major_page_faults),
      EventType(:sw, :cpu_migrations)],
#=     [EventType(:cache, :L1_data, :read, :access),
      EventType(:cache, :L1_data, :read, :miss)],
     [EventType(:cache, :L1_data, :write, :access),
      EventType(:cache, :L1_data, :write, :miss)]=#]

function make_bench(x; kwargs...)
    groups = EventGroup[]
    for y in x
        if isa(y, EventType)
            push!(groups, EventGroup([y]; kwargs...))
        else
            push!(groups, EventGroup(y; kwargs...))
        end
    end
    PerfBench(groups)
end

make_bench() = make_bench(reasonable_defaults)

# Event names are taken from the perf command.
const NAME_TO_EVENT = Dict(
    # hardware events
    "branch-instructions" => EventType(:hw, :branches),
    "branch-misses" => EventType(:hw, :branch_mispredicts),
    "cache-misses" => EventType(:hw, :cache_misses),
    "cache-references" => EventType(:hw, :cache_access),
    "cpu-cycles" => EventType(:hw, :cycles),
    "instructions" => EventType(:hw, :instructions),
    "stalled-cycles-backend" => EventType(:hw, :stalled_cycles_backend),
    "stalled-cycles-frontend" => EventType(:hw, :stalled_cycles_frontend),

    # software events
    "alignment-faults" => EventType(:sw, :alignment_faults),
    "bpf-output" => EventType(:sw, :bpf_output),
    "context-switches" => EventType(:sw, :ctx_switches),
    "cpu-clock" => EventType(:sw, :cpu_clock),
    "cpu-migrations" => EventType(:sw, :cpu_migrations),
    "dummy" => EventType(:sw, :dummy),
    "emulation-faults" => EventType(:sw, :emulation_faults),
    "major-faults" => EventType(:sw, :major_page_faults),
    "minor-faults" => EventType(:sw, :minor_page_faults),
    "page-faults" => EventType(:sw, :page_faults),
    "task-clock" => EventType(:sw, :task_clock),

    # hardware cache events
    "L1-dcache-load-misses" => EventType(:cache, :L1_data, :read, :miss),
    "L1-dcache-loads" => EventType(:cache, :L1_data, :read, :access),
    "L1-icache-load-misses" => EventType(:cache, :L1_insn, :read, :miss),
    "L1-icache-loads" => EventType(:cache, :L1_insn, :read, :access),
    "dTLB-load-misses" => EventType(:cache, :TLB_data, :read, :miss),
    "dTLB-loads" => EventType(:cache, :TLB_data, :read, :access),
    "iTLB-load-misses" => EventType(:cache, :TLB_insn, :read, :miss),
    "iTLB-loads" => EventType(:cache, :TLB_insn, :read, :access),
)
const EVENT_TO_NAME = Dict(event => name for (name, event) in NAME_TO_EVENT)

function is_supported(event::EventType)
    attr = perf_event_attr()
    attr.typ = event.category
    attr.size = sizeof(perf_event_attr)
    attr.config = event.event
    fd = perf_event_open(attr, 0, -1, -1, 0)
    if fd ≥ 0
        ret = ccall(:close, Cint, (Cint,), fd)
        if ret != 0
            @warn "failed to close file descriptor for some reason"
        end
        return true
    end
    return false
end

is_supported(name::AbstractString) = haskey(NAME_TO_EVENT, name) && is_supported(NAME_TO_EVENT[name])

function list()
    for t in [PERF_TYPE_HARDWARE, PERF_TYPE_SOFTWARE, PERF_TYPE_HW_CACHE]
        events = collect(filter(x -> x[2].category == t, NAME_TO_EVENT))
        sort!(events, by = x -> x[1])  # sort events by name
        if t == PERF_TYPE_HARDWARE
            println("hardware:")
        elseif t == PERF_TYPE_SOFTWARE
            println("software:")
        elseif t == PERF_TYPE_HW_CACHE
            println("cache:")
        else
            @assert false
        end
        for (name, event) in events
            @printf "  %-25s%s" name (is_supported(event) ? "supported" : "not supported")
            println()
        end
        t != PERF_TYPE_HW_CACHE && println()
    end
end

function parse_pstats_options(opts)
    # default events
    events = :(parse_groups("
        (cpu-cycles, stalled-cycles-frontend, stalled-cycles-backend),
        (instructions, branch-instructions, branch-misses),
        (task-clock, context-switches, cpu-migrations, page-faults)
    "))
    # default spaces
    user = kernel = hypervisor = true
    for (i, opt) in enumerate(opts)
        if i == 1 && !(opt isa Expr && opt.head == :(=))
            events = :(parse_groups($(esc(opt))))
        elseif opt isa Expr && opt.head == :(=)
            key, val = opt.args
            if key == :user
                user = esc(val)
            elseif key == :kernel
                kernel = esc(val)
            elseif key == :hypervisor
                hypervisor = esc(val)
            else
                error("unknown key: $(key)")
            end
        else
            error("unknown option: $(opt)")
        end
    end
    return (events = events, spaces = :($(user), $(kernel), $(hypervisor)), )
end

# syntax: groups = (group ',')* group
function parse_groups(str)
    groups = Vector{EventTypeExt}[]
    i = firstindex(str)
    next = iterate(str, i)
    while next !== nothing
        i = skipws(str, i)
        group, i = parse_group(str, i)
        push!(groups, group)
        i = skipws(str, i)
        next = iterate(str, i)
        if next === nothing
            continue
        end
        c, i = next
        if c == ','
            # ok
        else
            error("unknown character: $(repr(c))")
        end
    end
    return groups
end

# syntax: group = event | '(' (event ',')* event ')' modifiers?
function parse_group(str, i)
    group = EventTypeExt[]
    next = iterate(str, i)
    if next === nothing
        error("no events")
    elseif next[1] == '('
        # group
        i = next[2]
        while true
            i = skipws(str, i)
            event, i = parse_event(str, i)
            push!(group, event)
            i = skipws(str, i)
            next = iterate(str, i)
            if next === nothing
                error("unpaired '('")
            end
            c, i = next
            if c == ','
                # ok
            elseif c == ')'
                break
            else
                error("unknown character: $(repr(c))")
            end
        end
        i = skipws(str, i)

        # parse group-level modifiers (if any)
        next = iterate(str, i)
        if next !== nothing && next[1] == ':'
            (u, k, h), i = parse_modifiers(str, i)
            group = map(group) do event
                event.modified && return event
                exclude = exclude_flags(u, k, h)
                return EventTypeExt(event.event, true, exclude)
            end
        end
    else
        # singleton group
        i = skipws(str, i)
        event, i = parse_event(str, i)
        push!(group, event)
    end
    return group, i
end

# syntax: event = [A-Za-z0-9-]+ modifiers?
function parse_event(str, i)
    # parse event name
    isevchar(c) = 'A' ≤ c ≤ 'Z' || 'a' ≤ c ≤ 'z' || '0' ≤ c ≤ '9' || c == '-'
    start = i
    next = iterate(str, start)
    while next !== nothing && isevchar(next[1])
        i = next[2]
        next = iterate(str, i)
    end
    stop = prevind(str, i)
    if start > stop
        error("empty event name")
    end
    name = str[start:stop]
    if !haskey(NAME_TO_EVENT, name)
        error("unknown event name: $(name)")
    end
    event = NAME_TO_EVENT[name]

    # parse event-level modifiers (if any)
    modified = false
    exclude = EXCLUDE_NONE
    i = skipws(str, i)
    next = iterate(str, i)
    if next !== nothing && next[1] == ':'
        (u, k, h), i = parse_modifiers(str, i)
        modified = true
        exclude = exclude_flags(u, k, h)
    end

    return EventTypeExt(event, modified, exclude), i
end

# syntax: modifiers = ':' [ukh]*
function parse_modifiers(str, i)
    next = iterate(str, i)
    @assert next[1] == ':'
    ismodchar(c) = 'A' ≤ c ≤ 'Z' || 'a' ≤ c ≤ 'z'
    # u: user, k: kernel, h: hypervisor
    u = k = h = false  # exclude all
    i = skipws(str, next[2])
    next = iterate(str, i)
    while next !== nothing && ismodchar(next[1])
        c, i = next
        if c == 'u'
            u = true
        elseif c == 'k'
            k = true
        elseif c == 'h'
            h = true
        else
            error("unsupported modifier: $(repr(c))")
        end
        next = iterate(str, i)
    end
    return (u, k, h), i
end

# skip whitespace if any
function skipws(str, i)
    @label head
    next = iterate(str, i)
    if next !== nothing && isspace(next[1])
        i = next[2]
        @goto head
    end
    return i
end

struct Stats
    groups::Vector{Vector{Counter}}
end

function Stats(b::PerfBench)
    groups = Vector{Counter}[]
    for g in b.groups
        values = Vector{UInt64}(undef, length(g)+1+2)
        read!(g.leader_io, values)
        #?Ref@assert(length(g) == values[1])
        enabled, running = values[2], values[3]
        push!(groups, [Counter(g.event_types[i], values[3+i], enabled, running) for i in 1:length(g)])
    end
    return Stats(groups)
end

function Base.haskey(stats::Stats, name::AbstractString)
    event = NAME_TO_EVENT[name]
    return any(counter.event == event for group in stats.groups for counter in group)
end

function Base.getindex(stats::Stats, name::AbstractString)
    event = NAME_TO_EVENT[name]
    for group in stats.groups, counter in group
        if counter.event == event
            return counter
        end
    end
    throw(KeyError(name))
end

function Base.show(io::IO, stats::Stats)
    w = 2 + 23 + 18
    println(io, '━'^w)
    for group in stats.groups
        for i in 1:length(group)
            # grouping character
            if length(group) == 1
                c = '╶'
            elseif i == 1
                c = '┌'
            elseif i == length(group)
                c = '└'
            else
                c = '│'
            end
            counter = group[i]
            event = counter.event
            name = EVENT_TO_NAME[event]
            @printf io "%-2s%-23s" c name
            if !isenabled(counter)
                @printf(io, "%18s", "not enabled")
            elseif !isrun(counter)
                @printf(io, "%10s%7.1f%%", "NA", 0.0)
            else
                @printf(io, "%10.2e%7.1f%%", scaledcount(counter), fillrate(counter) * 100)
            end
            if isrun(counter)
                # show a comment
                if name == "cpu-cycles"
                    @printf(io, "  # %4.1f cycles per ns", counter.value / counter.running)
                elseif name == "instructions" && haskey(stats, "cpu-cycles")
                    @printf(io, "  # %4.1f insns per cycle", scaledcount(counter) / scaledcount(stats["cpu-cycles"]))
                elseif name == "cpu-clock" || name == "task-clock"
                    clk = float(scaledcount(counter))
                    if clk ≥ 1e9
                        clk /= 1e9
                        unit = "s"
                    elseif clk ≥ 1e6
                        clk /= 1e6
                        unit = "ms"
                    elseif clk ≥ 1e3
                        clk /= 1e3
                        unit = "μs"
                    else
                        unit = "ns"
                    end
                    @printf(io, "  # %4.1f %s", clk, unit)
                else
                    for (num, den, label) in [
                            ("stalled-cycles-frontend", "cpu-cycles", "cycles"),
                            ("stalled-cycles-backend", "cpu-cycles", "cycles"),
                            ("branch-instructions", "instructions", "instructions"),
                            ("branch-misses", "branch-instructions", "branch instructions"),
                            ("cache-misses", "cache-references", "cache references"),
                            ("L1-dcache-load-misses", "L1-dcache-loads", "dcache loads"),
                            ("L1-icache-load-misses", "L1-icache-loads", "icache loads"),
                            ("dTLB-load-misses", "dTLB-loads", "dTLB loads"),
                            ("iTLB-load-misses", "iTLB-loads", "iTLB loads"),
                        ]
                        if name == num && haskey(stats, den)
                            @printf(io, "  # %4.1f%% of %s", scaledcount(counter) / scaledcount(stats[den]) * 100, label)
                            break
                        end
                    end
                end
            end
            println(io)
        end
    end
    print(io, '━'^w)
end

isenabled(counter::Counter) = counter.enabled > 0
isrun(counter::Counter) = counter.running > 0
fillrate(counter::Counter) = counter.running / counter.enabled
scaledcount(counter::Counter) = counter.value * (counter.enabled / counter.running)

function checkstats(stats::Stats)
    for group in stats.groups, counter in group
        if !isrun(counter)
            @warn "Some events are not measured"
            return
        end
    end
end

function set_default_spaces(groups, (u, k, h))
    map(groups) do group
        map(group) do event
            if event.modified
                return event
            end
            exclude = EXCLUDE_NONE
            u || (exclude |= EXCLUDE_USER)
            k || (exclude |= EXCLUDE_KERNEL)
            h || (exclude |= EXCLUDE_HYPERVISOR)
            return EventTypeExt(event.event, event.modified, exclude)
        end
    end
end

# for debug
function dump_groups(groups)
    buf = IOBuffer()
    println(buf, "Event groups")
    for (i, group) in enumerate(groups)
        println(buf, "group #$(i)")
        for (j, event) in enumerate(group)
            if j < length(group)
                print(buf, "  ├─ ")
            else
                print(buf, "  └─ ")
            end
            print(buf, event.event)
            event.modified && print(buf, " → modified")
            exclude = event.exclude
            exclude != 0 && print(buf, ", exclude ")
            exclude & EXCLUDE_USER       != 0 && print(buf, 'u')
            exclude & EXCLUDE_KERNEL     != 0 && print(buf, 'k')
            exclude & EXCLUDE_HYPERVISOR != 0 && print(buf, 'h')
            println(buf)
        end
    end
    String(take!(buf))
end

"""
    @pstats [options] expr

Run `expr` and gather its performance statistics.

This macro basically measures the number of occurrences of events such as CPU
cycles, branch prediction misses, page faults, and so on. The list of
supported events can be shown by calling the `LinuxPerf.list` function.

Due to the resource limitation of performance measuring units (PMUs)
installed in a CPU core, all events may not be measured simultaneously,
resulting in multiplexing several groups of events in a single measurement.
If the running time is extremely short, some event groups may not be measured
at all.

The result is shown in a table. Each row consists of four columns: an event
group indicator, an event name, a scaled count and a running rate. A comment
may follow these columns after a hash (#) character.
1. The event group indicated by a bracket is a set of events that are
   measured simultaneously so that their count statistics can be meaningfully
   compared.
2. The event name is a conventional name of the measured event.
3. The scaled count is the number of occurrences of the event, scaled by the
   reciprocal of the running rate.
4. The running rate is the ratio of the time of running and enabled.

The macro can take some options. If a string object is passed, it is a
comma-separated list of event names to measure. A group of events is
surrounded by a pair of parentheses. Modifiers can be added to confine
measured events to specific space. Currently, three space modifiers are
supported: user (`u`), kernel (`k`), and hypervisor (`h`) space. The
modifiers follow an event name separated by a colon. For example,
`cpu-cycles:u` ignores all CPU cycles except in user space. It is also
possible to pass `user`, `kernel`, and `hypervisor` parameters (`true` by
default) to the macro, which affect events without modifiers. For example,
`kernel=false` excludes events happend in kernel space.

# Examples

```
julia> xs = randn(1_000_000);

julia> sort(xs[1:9]);  # compile

julia> @pstats sort(xs)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┌ cpu-cycles               2.68e+08   51.0%  #  3.9 cycles per ns
│ stalled-cycles-frontend  9.75e+06   51.0%  #  3.6% of cycles
└ stalled-cycles-backend   2.00e+07   51.0%  #  7.5% of cycles
┌ instructions             1.87e+08   49.0%  #  0.7 insns per cycle
│ branch-instructions      3.82e+07   49.0%  # 20.4% of instructions
└ branch-misses            8.51e+06   49.0%  # 22.3% of branch instructions
┌ task-clock               6.90e+07  100.0%
│ context-switches         6.00e+00  100.0%
│ cpu-migrations           0.00e+00  100.0%
└ page-faults              1.95e+03  100.0%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

julia> @pstats "(cpu-cycles,instructions,branch-instructions,branch-misses),page-faults" sort(xs)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┌ cpu-cycles               2.68e+08  100.0%  #  3.9 cycles per ns
│ instructions             1.89e+08  100.0%  #  0.7 insns per cycle
│ branch-instructions      3.80e+07  100.0%  # 20.1% of instructions
└ branch-misses            8.23e+06  100.0%  # 21.7% of branch instructions
╶ page-faults              1.95e+03  100.0%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
"""
macro pstats(args...)
    if isempty(args)
        error("@pstats requires at least one argument")
    end
    opts, expr = parse_pstats_options(args[1:end-1]), args[end]
    quote
        (function ()
            groups = set_default_spaces($(opts.events), $(opts.spaces))
            @debug dump_groups(groups)
            bench = make_bench(groups, userspace_only = false)
            enable!(bench)
            val = $(esc(expr))
            disable!(bench)
            # trick the compiler not to eliminate the code
            stats = rand() < 0 ? val : Stats(bench)
            close(bench)
            checkstats(stats)
            return stats::Stats
        end)()
    end
end

end
