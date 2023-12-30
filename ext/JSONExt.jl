# compatiability with serializing parsed pstat options with JSON.jl

module JSONExt

using LinuxPerf: parse_groups
using JSON

JSON.lower(::typeof(parse_groups)) = "LinuxPerf.parse_groups"

end