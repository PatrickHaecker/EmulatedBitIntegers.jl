struct IntegerType
    signed::Bool
    logical_bits::Int
    storage_bits::Int
    # A storage request is redundant for a definition like UInt7_8. This will be created as UInt7 to be consistent.
    redundant_storage_request::Bool
    # We store the storage type to avoid evaluating more than once.
    storage_type::DataType

    function IntegerType(signed, logical_bits, storage_bits, redundant_storage_request, m::Module)
        1 <= logical_bits < storage_bits || lazy"Logical bits must be a positive value less than storage bits." |> ArgumentError |> throw
        storage_bits |> isbytesize || lazy"Storage bits must be a multiple of 8." |> ArgumentError |> throw
        # Resolve the storage type's binding in module `m`. We want to have something like `CallerModule.UInt24`. However, this can also return something like `BitIntegers.UInt256`, as this type and some others always get defined when loading `BitIntegers.jl`. This is a [problem of `BitIntegers.jl`](https://github.com/rfourquet/BitIntegers.jl/issues/53) and not of `EmulatedBitIntegers.jl`.
        storage_type = getfield(m, Symbol(signed ? "Int" : "UInt", storage_bits))

        new(signed, logical_bits, storage_bits, redundant_storage_request, storage_type)
    end
end

function IntegerType(s::Symbol, mod::Module)
    m = match(r"(U)?Int(\d+)(?:_(\d+))?$", s |> string)
    isnothing(m) && lazy"Invalid EmulatedInteger: $s" |> ArgumentError |> throw

    signed = isnothing(m[1])
    logical_bits = parse(Int, m[2]::SubString{String}) # help type inference by type assertion
    maybe_storage_bits = m[3] # this needs to be a separate variable to help type inference

    if isnothing(maybe_storage_bits)
        storage_bits = logical_bits |> nextpowerof2bytesize
        redundant_storage_request = false
    else
        storage_bits = parse(Int, maybe_storage_bits)
        redundant_storage_request = storage_bits == logical_bits |> nextpowerof2bytesize
    end

    return IntegerType(signed, logical_bits, storage_bits, redundant_storage_request, mod)
end

Base.Symbol(x::IntegerType) = Symbol(x.signed ? "Int" : "UInt", x.logical_bits, nextpowerof2bytesize(x.logical_bits) == x.storage_bits ? "" : "_$(x.storage_bits)")

issigned(x::IntegerType) = x.signed
issigned(::Type{<:EmulatedSigned}) = true
issigned(::Type{<:EmulatedUnsigned}) = false

bits(x::IntegerType) = x.logical_bits

wastedbits(x::IntegerType) = x.storage_bits - x.logical_bits

signdual(x::IntegerType) = IntegerType(!x.signed, x.logical_bits, x.storage_bits, x.redundant_storage_request, x.storage_type |> parentmodule)

# Return the logical typemin/typemax, but in the type of the storage typemin/typemax. Therefore, this is not a method of typemax/typemin. The reason is that the new type does not exist yet. This reduces redundancy and is not exported.
minvalue(x::IntegerType) = x.signed ? x.storage_type(-1) << (x.logical_bits-1) : x.storage_type(0)
maxvalue(x::IntegerType) = x.signed ? x.storage_type(-1) >>> (wastedbits(x) + 1) : ~x.storage_type(0) >> wastedbits(x)

storagetypemin(x::IntegerType) = convert(x.storage_type, x.storage_type |> typemin)
storagetypemax(x::IntegerType) = convert(x.storage_type, x.storage_type |> typemax)

"""
    ispowerof2bytesize(x::Integer)

Checks for 8 * 2ⁿ for n ∈ ℕ, i.e. 8, 16, 32, ...

A number is a power of two and has a size a multiple of 8 iff the three least significant bits are zero and the number of set bits is 1.
"""
ispowerof2bytesize(x::Integer) = ispowerof2(x) && isbytesize(x)
ispowerof2(x::Integer) = x |> Base.ctpop_int == 1
isbytesize(x::Integer) = x & 0b111 == 0

"""
    hexdigits(x::IntegerType)

Compute the number of hexadecimal digits this unsigned integer type needs for printing.
"""
# This is an optimized version of div(t.bits, 4, RoundUp)
hexdigits(x::IntegerType) = (((unsigned(x.logical_bits) + 3) >> 2) % Int)::Int

"""
    nextbytesize(x::Integer)

Return the next bytesize in bits, which is up to 8 bits larger than x.

```jldoctest
julia> using EmulatedBitIntegers

julia> EmulatedBitIntegers.nextbytesize(7)
8

julia> EmulatedBitIntegers.nextbytesize(8)
16
```
"""
nextbytesize(x::Integer) = (((unsigned(x) + 8) & ~0b111) % Int)::Int

# Defining for Base.BitIntegerType would be better, but this is not public.
"""
    nextpowerof2bytesize(x::Int)

Return the first y > x such that y is a power of 2 and dividable by 8.
"""
nextpowerof2bytesize(x::Int) = 1 << (8sizeof(x) - leading_zeros(unsigned(x) | 0b111))