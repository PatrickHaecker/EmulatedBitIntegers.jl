module EmulatedBitIntegers

# import Random
using Random: Random
using PrecompileTools: @compile_workload

export @emulate, bits, zext, storagetypeof
VERSION >= v"1.11.0-DEV.469" && "public EmulatedInteger, EmulatedSigned, EmulatedUnsigned" |> Meta.parse |> eval

"""
    EmulatedUnsigned{S, L} <: Unsigned

Abstract supertype of every emulated unsigned integer with storage type `S` and logical bit width `L`.

Every concrete type produced by [`@emulate`](@ref) for an unsigned width is a primitive subtype of this.
Use it as a dispatch target when defining methods that should apply to all emulated unsigned widths
sharing a given storage and/or logical width — e.g. `Base.foo(x::EmulatedUnsigned) = ...`.
"""
abstract type EmulatedUnsigned{S, L} <: Unsigned end

"""
    EmulatedSigned{S, L} <: Signed

Abstract supertype of every emulated signed integer with storage type `S` and logical bit width `L`.

Every concrete type produced by [`@emulate`](@ref) for a signed width is a primitive subtype of this.
Use it as a dispatch target when defining methods that should apply to all emulated signed widths
sharing a given storage and/or logical width — e.g. `Base.foo(x::EmulatedSigned) = ...`.
"""
abstract type EmulatedSigned{S, L} <: Signed end

"""
    EmulatedInteger{S, L}

`Union` of [`EmulatedUnsigned{S, L}`](@ref) and [`EmulatedSigned{S, L}`](@ref). Public dispatch target
for methods that apply to any emulated integer regardless of signedness.
"""
const EmulatedInteger{S, L} = Union{EmulatedUnsigned{S, L}, EmulatedSigned{S, L}}

include("IntegerType.jl")
include("interface.jl")
include("methods.jl")
include("emulate.jl")

# `emulate` only builds an `Expr` (no `eval`), so calling it here exercises the macro pipeline without defining real types or polluting any module. Cover the four distinct branches: unsigned default-storage, signed default-storage, explicit non-default storage, and `redundant_storage_request` (suffix matches the default → produces a `const` alias).
@compile_workload begin
    precompile(Tuple{typeof(emulate!), Vector{Pair{Symbol, Expr}}, Symbol, Module})

    # Do a bit of precompilation. Although it's a mess, it seems to help somewhat.
    @eval module _PrecompileShifts
        using EmulatedBitIntegers
        # One emulated type per storage class so each Base shift MI gets pulled in.
        @emulate UInt7 Int7 UInt15 Int15 UInt31 Int31 UInt63 Int63
        for T in (UInt7, Int7, UInt15, Int15, UInt31, Int31, UInt63, Int63)
            T(0) << 1; T(0) >> 1; T(0) >>> 1
        end
    end

    # `zext` interface over Base's primitive bit integers. The two-arg form is valid only when the destination is at least as wide as the source.
    for T in (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
        zext(T(0))
        for X in (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
            bits(T) >= bits(X) && zext(T, X(0))
        end
    end
end

end
