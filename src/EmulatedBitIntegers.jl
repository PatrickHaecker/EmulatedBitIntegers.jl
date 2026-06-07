module EmulatedBitIntegers

# import Random
using Random: Random
using PrecompileTools: @compile_workload

export @emulate, bits, zext, storagetypeof

abstract type EmulatedUnsigned{S} <: Unsigned end
abstract type EmulatedSigned{S} <: Signed end
const EmulatedInteger{S} = Union{EmulatedUnsigned{S}, EmulatedSigned{S}}
const UnifiedInteger = Union{EmulatedInteger, Base.BitInteger}

include("IntegerType.jl")
include("interface.jl")
include("methods.jl")
include("emulate.jl")

# `emulate` only builds an `Expr` (no `eval`), so calling it here exercises the macro pipeline without defining real types or polluting any module. Cover the four distinct branches: unsigned default-storage, signed default-storage, explicit non-default storage, and `redundant_storage_request` (suffix matches the default → produces a `const` alias).
@compile_workload begin
    precompile(Tuple{typeof(emulate!), Vector{Pair{Symbol, Expr}}, Symbol, Module})

    # `zext` interface over Base's primitive bit integers. The two-arg form is valid only when the destination is at least as wide as the source.
    for T in (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
        zext(T(0))
        for X in (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
            bits(T) >= bits(X) && zext(T, X(0))
        end
    end
end

end
