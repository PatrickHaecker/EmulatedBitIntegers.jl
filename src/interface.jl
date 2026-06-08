"""
    bits(T::Type) -> Int
    bits(x) -> Int

Logical bit width of `T` (or `typeof(x)`).

For the default primitive types, `bits(T) == 8 * sizeof(T)`. For struct types,
`bits(T)` is the recursive sum of `bits` over the fields.
Specific types may override this to report their logical width directly when
their storage includes padding.
"""
function bits(::Type{T}) where T
    isprimitivetype(T) && return 8 * sizeof(T)
    isstructtype(T) && return sum(i -> bits(fieldtype(T, i)), 1:fieldcount(T); init=0)
    8 * Base.packedsize(T)
end
bits(::Type{T}) where T<:Base.BitInteger = 8 * sizeof(T)
# As `Base.Bottom <: UnifiedInteger`, type inference thinks that `x |> typeof` below could be `Bottom`, although it can't as there is no value of type `Bottom`. However, as `Base.Bottom <: Base.BitInteger`, type inference will match the method in the line above which would lead to a call to `sizeof(Base.Bottom)` which would error. JET.jl points this out. Therefore, handle this case explicitly to tell type inference that this error is on purpose (although it won't actually happen).
bits(::Type{Base.Bottom}) = lazy"Cannot determine bits for Bottom" |> ArgumentError |> throw
bits(x) = x |> typeof |> bits

"""
    zext(x)

Zero-extend the high order bits of the value to the storage type.

For standard integers, this function acts as the identity function since their logical size
and storage size are the same.
"""
zext(x::Integer) = x

"""
    zext(T::Type{<:Integer}, x::Integer) -> T

Zero-extend the integer `x` to the wider integer type `T`.
"""
function zext(T::Type{<:Integer}, x::Integer)
    T |> bits >= x |> typeof |> bits || lazy"$T must not be a type with less bits than the type of x" |> ArgumentError |> throw
    reinterpret(T, convert(T |> unsigned, reinterpret(x |> zext |> typeof |> unsigned, x |> zext)))
end

# Zero-extension to the storage type. Unsigned storage is already clean. Signed storage is sign-extended, so mask off the wasted high bits; the mask `storagetypeof(T)(-1) >>> wastedbits(T)` folds to a literal.
zext(x::EmulatedUnsigned) = x[]
zext(x::T) where T<:EmulatedSigned = x[] & (storagetypeof(T)(-1) >>> wastedbits(T))

"""
    storagetypeof(T::Type) -> Type

Return the storage type.

For primitive types, this is `T` itself. For single-field struct types, it is the
storage type of the field (recursively). All other types (abstract, `Union`, `UnionAll`,
multi-field structs, structs with non-bits fields) throw an `ArgumentError`.
"""
@inline function storagetypeof(x::DataType)
    isprimitivetype(x) && return x
    isstructtype(x) && fieldcount(x) == 1 && return fieldtype(x, 1) |> storagetypeof
    lazy"$x does not have a storage type" |> ArgumentError |> throw
end
storagetypeof(::Type{<:EmulatedInteger{S}}) where S = S
# Fallback for `UnionAll`, `Union`, and other non-`DataType` `Type` values. Without this, `fieldtype` on those would silently produce a `TypeVar` or `Any` and the recursion would yield garbage.
storagetypeof(x::Type) = lazy"$x does not have a storage type" |> ArgumentError |> throw
