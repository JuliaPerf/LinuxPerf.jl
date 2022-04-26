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

The `@pstats' macro provides another (perhaps more concise) tool to measure
performance events, which can be used in the same way as `@timed` of the
standard library. The following example measures default events and reports its
summary:
```
julia> using LinuxPerf, Random

julia> mt = MersenneTwister(1234);

julia> @pstats rand(mt, 1_000_000);  # compile

julia> @pstats rand(mt, 1_000_000)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┌ cpu-cycles               2.88e+06   58.1%  #  1.2 cycles per ns
│ stalled-cycles-frontend  9.50e+03   58.1%  #  0.3% of cycles
└ stalled-cycles-backend   1.76e+06   58.1%  # 61.2% of cycles
┌ instructions             1.11e+07   41.9%  #  3.9 insns per cycle
│ branch-instructions      5.32e+05   41.9%  #  4.8% of insns
└ branch-misses            2.07e+03   41.9%  #  0.4% of branch insns
┌ task-clock               2.38e+06  100.0%  #  2.4 ms
│ context-switches         0.00e+00  100.0%
│ cpu-migrations           0.00e+00  100.0%
└ page-faults              1.95e+03  100.0%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

See the documentation of `@pstats` for more details and available options.

For more fine tuned performance profile examples, please check out the `test`
directory.
