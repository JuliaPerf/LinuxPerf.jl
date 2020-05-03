# LinuxPerf.jl -- Julia wrapper for Linux's perf

the kernel multiplexes event counter that requires limited hardware resources so some counters are only active for a fraction of the running time (% on the right).

if you need to compare two quantities you must put them in the same event group so they are always scheduled at the same time (or not at all).

```julia
julia> import LinuxPerf: make_bench, enable!, disable!, reset!, reasonable_defaults, counters
julia> const bench = make_bench(reasonable_defaults);
julia> @noinline function g(a)
           enable!(bench)
           c = 0
           for x in a
               if x > 0
                   c += 1
               end
           end
           disable!(bench)
           c
       end
g (generic function with 1 method)
julia> g(zeros(10000))
0
julia> counters(bench)
hw:cycles : 
	               52794 (100.0 %)
hw:cache_access : 
	                 881 (100.0 %)
hw:cache_misses : 
	                 579 (100.0 %)
hw:branches : 
	               31367 (100.0 %)
hw:branch_mispredicts : 
	                 107 (100.0 %)      # =)
hw:instructions : 
	               96961 (100.0 %)
sw:ctx_switches : 
	                   0 (100.0 %)
sw:page_faults : 
	                   0 (100.0 %)
sw:minor_page_faults : 
	                   0 (100.0 %)
sw:major_page_faults : 
	                   0 (100.0 %)
sw:cpu_migrations : 
	                   0 (100.0 %)

julia> reset!(bench)
julia> g(randn(10000))
5023
julia> counters(bench)
hw:cycles : 
	              194454 (100.0 %)
hw:cache_access : 
	                 291 (100.0 %)
hw:cache_misses : 
	                 222 (100.0 %)
hw:branches : 
	               38050 (100.0 %)
hw:branch_mispredicts : 
	                5131 (100.0 %)      # =(
hw:instructions : 
	              129253 (100.0 %)
sw:ctx_switches : 
	                   0 (100.0 %)
sw:page_faults : 
	                   0 (100.0 %)
sw:minor_page_faults : 
	                   0 (100.0 %)
sw:major_page_faults : 
	                   0 (100.0 %)
sw:cpu_migrations : 
	                   0 (100.0 %)
```
