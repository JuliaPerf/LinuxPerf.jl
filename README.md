# LinuxPerf.jl -- Julia wrapper for Linux's perf

[![Build Status](https://github.com/JuliaPerf/LinuxPerf.jl/workflows/CI/badge.svg)](https://github.com/JuliaPerf/LinuxPerf.jl/actions)
[![Coverage](https://codecov.io/gh/JuliaPerf/LinuxPerf.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaPerf/LinuxPerf.jl)

the kernel multiplexes event counter that requires limited hardware resources so some counters are only active for a fraction of the running time (% on the right).

if you need to compare two quantities you must put them in the same event group so they are always scheduled at the same time (or not at all).

```julia
julia> using LinuxPerf

julia> @noinline function g(a)
           c = 0
           for x in a
               if x > 0
                   c += 1
               end
           end
           c
       end
g (generic function with 1 method)

julia> g(zeros(10000))
0

julia> data = zeros(10000); @measure g(data)
┌───────────────────────┬────────────┬─────────────┐
│                       │ Events     │ Active Time │
├───────────────────────┼────────────┼─────────────┤
│             hw:cycles │ 25,583,165 │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│       hw:cache_access │ 1,640,429  │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│       hw:cache_misses │ 328,561    │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│           hw:branches │ 6,164,138  │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│ hw:branch_mispredicts │ 223,272    │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│       hw:instructions │ 28,115,285 │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│       sw:ctx_switches │ 0          │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│        sw:page_faults │ 41         │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│  sw:minor_page_faults │ 41         │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│  sw:major_page_faults │ 0          │ 100.0 %     │
├───────────────────────┼────────────┼─────────────┤
│     sw:cpu_migrations │ 0          │ 100.0 %     │
└───────────────────────┴────────────┴─────────────┘
```

For more fine tuned performance profile examples, please check out the `test`
directory.
