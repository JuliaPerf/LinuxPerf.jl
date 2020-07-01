using LinuxPerf
using Test

using LinuxPerf: make_bench, enable!, disable!, reset!, reasonable_defaults, counters, EventType, EventTypeExt, parse_groups

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

@testset "Parser" begin
    cycles = EventType(:hw, :cycles)
    insns = EventType(:hw, :instructions)

    @test parse_groups("") == []
    @test parse_groups("cpu-cycles") == [[EventTypeExt(cycles, false, 0)]]
    @test parse_groups("(cpu-cycles)") == parse_groups("cpu-cycles")
    @test parse_groups("cpu-cycles,instructions") == [[EventTypeExt(cycles, false, 0)], [EventTypeExt(insns, false, 0)]]
    @test parse_groups("(cpu-cycles,instructions)") == [[EventTypeExt(cycles, false, 0), EventTypeExt(insns, false, 0)]]
    @test parse_groups("  cpu-cycles,  instructions  ") == parse_groups("cpu-cycles,instructions")
    @test parse_groups("  (  cpu-cycles,  instructions  )  ") == parse_groups("(cpu-cycles,instructions)")

    # exclude flags
    u = LinuxPerf.exclude_flags(true, false, false)
    k = LinuxPerf.exclude_flags(false, true, false)
    h = LinuxPerf.exclude_flags(false, false, true)
    uk = LinuxPerf.exclude_flags(true, true, false)
    ukh = LinuxPerf.exclude_flags(true, true, true)

    # event-level modifiers
    @test parse_groups("cpu-cycles:u") == [[EventTypeExt(cycles, true, u)]]
    @test parse_groups("cpu-cycles:k") == [[EventTypeExt(cycles, true, k)]]
    @test parse_groups("cpu-cycles:h") == [[EventTypeExt(cycles, true, h)]]
    @test parse_groups("cpu-cycles:uk") == [[EventTypeExt(cycles, true, uk)]]
    @test parse_groups("cpu-cycles:ukh") == [[EventTypeExt(cycles, true, ukh)]]
    @test parse_groups("cpu-cycles:ku") == parse_groups("cpu-cycles:uk")
    @test parse_groups("cpu-cycles:uu") == parse_groups("cpu-cycles:u")
    @test parse_groups("cpu-cycles  :  u  ") == parse_groups("cpu-cycles:u")

    # group-level modifiers
    @test parse_groups("(cpu-cycles,instructions):u") == parse_groups("(cpu-cycles:u,instructions:u)")
    @test parse_groups("(cpu-cycles,instructions):k") == parse_groups("(cpu-cycles:k,instructions:k)")
    @test parse_groups("(cpu-cycles,instructions):h") == parse_groups("(cpu-cycles:h,instructions:h)")
    @test parse_groups("(cpu-cycles,instructions):uk") == parse_groups("(cpu-cycles:uk,instructions:uk)")
    @test parse_groups("(cpu-cycles,instructions):ukh") == parse_groups("(cpu-cycles:ukh,instructions:ukh)")
    @test parse_groups("(cpu-cycles,instructions):ku") == parse_groups("(cpu-cycles,instructions):uk")
    @test parse_groups("(cpu-cycles,instructions):uu") == parse_groups("(cpu-cycles,instructions):u")
    @test parse_groups("(cpu-cycles:k,instructions):u") == parse_groups("(cpu-cycles:k,instructions:u)")
    @test parse_groups("(cpu-cycles,instructions)  :  u  ") == parse_groups("(cpu-cycles,instructions):u")
end

end