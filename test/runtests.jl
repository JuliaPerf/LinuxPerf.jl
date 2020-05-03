using LinuxPerf
using Test

import LinuxPerf: make_bench, enable!, disable!, reset!, reasonable_defaults, counters

@testset "LinuxPerf" begin

@testset "simple benchmark" begin
    @test begin
        bench = make_bench(reasonable_defaults);
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

        true  # Succeeded without any exceptions...
    end
end


@testset "@measure" begin
    c1 = @measure 2 + 2
    v, b1 = @measured 2 + 2

    @test v === 4
    @test typeof(c1) == typeof(counters(b1))
end

end