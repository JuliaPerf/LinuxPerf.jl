using LinuxPerf
using Test

using LinuxPerf: make_bench, enable!, disable!, reset!, reasonable_defaults, counters, EventGroup, EventType, EventTypeExt, parse_groups, enable_all!, disable_all!

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

        results = counters(bench)
        close(bench)

        true  # Succeeded without any exceptions...
    end

    @test begin
        bench = make_bench(reasonable_defaults);
        @noinline function g(a)
            enable_all!()
            c = 0
            for x in a
                if x > 0
                    c += 1
                end
            end
            disable_all!()
            c
        end
        g(zeros(10000))

        results = counters(bench)
        close(bench)

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


@testset "@pstats" begin
    n = 10^3
    a = randn(n)
    b = randn(n)
    c = randn(n)
    dest = zero(a)

    function foo!(dest, a, b, c)
        @. dest = a + b * c
        sum(dest)
    end

    # Simple smoke tests
    @test_nowarn LinuxPerf.list()
    @pstats foo!(dest, a, b, c)

    @pstats "cpu-cycles,(instructions,branch-instructions,branch-misses),(task-clock,context-switches,cpu-migrations,page-faults),(L1-dcache-load-misses,L1-dcache-loads,L1-icache-load-misses),(dTLB-load-misses,dTLB-loads)" foo!(dest, a, b, c)
end

@testset "_addcommas" begin
    @test LinuxPerf._addcommas(Int64(1)) == "1"
    @test LinuxPerf._addcommas(Int64(12)) == "12"
    @test LinuxPerf._addcommas(Int64(123)) == "123"
    @test LinuxPerf._addcommas(Int64(1234)) == "1,234"
    @test LinuxPerf._addcommas(Int64(12345)) == "12,345"
    @test LinuxPerf._addcommas(typemin(Int64)) == "-9,223,372,036,854,775,808"
end

@testset "empty EventGroup" begin
    # Creating an empty EventGroup should be a no-op (and not error)
    g = EventGroup(EventType[])
    @test length(g.fds) == 0
    @test g.leader_fd == -1
    close(g) # also a no-op
end

end
