# compatiability with serializing parsed pstat options with JSON.jl

module JSONExt

using LinuxPerf: parse_groups
isdefined(Base, :get_extension) ? (import JSON) : (import ..JSON)

JSON.lower(::typeof(parse_groups)) = "LinuxPerf.parse_groups"

end