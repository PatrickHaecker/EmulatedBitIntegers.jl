module EmulatedBitIntegers

# import Random
using Random: Random

export @emulate, bits, zext, storagetypeof

abstract type EmulatedUnsigned <: Unsigned end
abstract type EmulatedSigned <: Signed end
const EmulatedInteger = Union{EmulatedUnsigned, EmulatedSigned}
const UnifiedInteger = Union{EmulatedInteger, Base.BitInteger}

include("IntegerType.jl")
include("interface.jl")
include("methods.jl")
include("emulate.jl")

end
