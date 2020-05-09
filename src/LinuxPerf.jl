module LinuxPerf

using Printf
using PrettyTables
using Formatting

export @measure, @measured
export make_bench, enable!, disable!, reset!, reasonable_defaults, counters

import Base: show, length, close

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
const PERF_TYPE_BREAKPOINT = 3

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
     (:sw, 1, # PERF_TYPE_SOFTWARE
      [(:page_faults, 2), # PERF_COUNT_SW_PAGE_FAULTS
       (:ctx_switches, 3), # PERF_COUNT_SW_CONTEXT_SWITCHES
       (:cpu_migrations, 4), # PERF_COUNT_SW_CPU_MIGRATIONS
       (:minor_page_faults, 5), # PERF_COUNT_SW_PAGE_FAULTS_MIN
       (:major_page_faults, 6), # PERF_COUNT_SW_PAGE_FAULTS_MAJ
       ])
     ]


# cache events have special encoding, PERF_TYPE_HW_CACHE
const CACHE_TYPES =
    [(:L1_data, 0),
     (:L1_insn, 1),
     (:LLC,   2),
     (:TLB_data, 3),
     (:TLB_insn, 4),
     (:BPU, 5)]
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

mutable struct EventGroup
    leader_fd::Cint
    fds::Vector{Cint}
    event_types::Vector{EventType}
    leader_io::IOStream

    function EventGroup(types::Vector{EventType};
                        warn_unsupported = true,
                        userspace_only = true,
                        pinned = false,
                        exclusive = false,
                        )
        my_types = EventType[]
        group = new(-1, Cint[], EventType[])

        for (i, evt_type) in enumerate(types)
            attr = perf_event_attr()
            attr.typ = evt_type.category
            attr.size = sizeof(perf_event_attr)
            attr.config = evt_type.event
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
            push!(group.event_types, evt_type)
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

function make_bench(x)
    groups = EventGroup[]
    for y in x
        if isa(y, EventType)
            push!(groups, EventGroup([y]))
        else
            push!(groups, EventGroup(y))
        end
    end
    PerfBench(groups)
end

make_bench() = make_bench(reasonable_defaults)

end
