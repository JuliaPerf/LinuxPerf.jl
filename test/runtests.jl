using LinuxPerf
using Test

import LinuxPerf: make_bench, enable!, disable!, reset!, reasonable_defaults, counters
const bench = make_bench(reasonable_defaults);
@noinline function g(a)
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
g(zeros(10000))

counters(bench)