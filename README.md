[![Test workflow status](https://github.com/PatrickHaecker/EmulatedBitIntegers.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/PatrickHaecker/EmulatedBitIntegers.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/PatrickHaecker/EmulatedBitIntegers.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/PatrickHaecker/EmulatedBitIntegers.jl)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)


# EmulatedBitIntegers

*Providing integers behaving as arbitrary bit-size integers.*

## Overview

`EmulatedBitIntegers.jl` provides integers with N bits where N is not a multiple of 8 (i.e. 1 byte). For sizes that are multiples of 8, use the existing primitive types or `BitIntegers.jl`. This package should only be relevant until [primitive types can be of any bitsize](https://github.com/JuliaLang/julia/issues/45486) as already supported by LLVM. Then, you can hopefully simply switch to `BitIntegers.jl` with native support. In order to facilitate this future transition, `EmulatedBitIntegers.jl` tries to provide types as closely as possible to the primitive types of any bitsize by being themselves primitive types and not using type parameters.

Until then, `EmulatedBitIntegers.jl`, well, emulates the integers by storing them in a (larger) primitive type, but behaving as if the intended type were implemented in hardware. For most operations, this needs some additional CPU instructions for masking or bit shifting operations. However, modern CPUs are quite efficient in doing these additional "lightweight" operations, up to the point that no additional cycles are needed. But in general expect that there are cases where some slowdown happens compared to integers with a size supported by the used hardware.

## Usage

`EmulatedBitIntegers.jl` is installed via the General registry:

```julia
pkg> add EmulatedBitIntegers
```

To create the type, do, e.g.:

```jldoctest usage
julia> using EmulatedBitIntegers

julia> @emulate UInt3
```

This UInt3 can be used like a regular integer, so you can create values by:

```jldoctest usage
julia> UInt3(7)
0x7
```

The type has the correct range:

```jldoctest usage
julia> UInt3 .|> (typemin, typemax)
(0x0, 0x7)
```

Values will overflow as a hardware UInt3 would, too:

```jldoctest usage
julia> UInt3(7) + UInt3(1)
0x0
```

Nevertheless, they use a larger primitive type internally. The `@emulate UInt3` defined `UInt3` to use an `UInt8` data storage. In general, the default for the storage type is the next corresponding (successor) power-of-two primitive type equal or larger to `UInt8`:

```jldoctest usage
julia> @emulate Int20

julia> Int20 |> storagetypeof
Int32
```

You can use another storage type by providing the primitive type explicitly:

```jldoctest usage
julia> @emulate Int7_16

julia> Int7_16 |> storagetypeof
Int16
```

If you need this type frequently, you can define an alias name for the type:

```jldoctest usage
julia> const Int7 = Int7_16
Int7_16
```

The storage type does not need to be a power-of-two byte size when using
`BitIntegers.jl`:

```jldoctest usage
julia> using BitIntegers

julia> @define_integers 24;
```

Then `Int24` can be used as the storage type:

```jldoctest usage
julia> @emulate Int20_24

julia> Int20_24 |> storagetypeof
Int24
```

This might be useful in situations where the overflow should not be checked too often. The current implementation checks after each operation, that the unused bits in the storage type are clean (i.e. 0 for positive numbers and 1 for negative numbers):

```julia
(a, b, c, d) = (22, 17, 1, 2) .|> Int7
@code_typed +(a, b, c, d)
```

In this example the overflow is guaranteed to be only checked once at the end of the operation (`shl_int` followed by `ashr_int`), as the primitive type is guaranteed to be large enough to hold the temporary results. However, this guarantee is limited in scope, as the overflow would always be checked at the end of each call, so

```julia
plus(a, b, c, d) = ((a + b) + c) + d
@code_typed plus(a, b, c, d)
```

will check for overflow three times in theory. Yet, `LLVM` can save the day in this case and checks for the overflow only once

```julia
@code_llvm debuginfo=:none plus(a, b, c, d)
```

If you define a type with a manual storage type which is identical to the regular storage type, the type with the regular storage type is created with a type alias to the type with the manual storage. For example

```jldoctest usage
julia> @emulate Int7_8
```

is a shortcut for

```julia
@emulate Int7
const Int7_8 = Int7
```

The signedness of data and storage types are always identical.

If you want to `@emulate` multiple types, you can simply provide multiple arguments to the macro with regular macro syntax:

```jldoctest usage
julia> @emulate Int3 UInt3 UInt4 UInt5
```

If you `@emulate` an already defined type, nothing will be done (not even any output).

Zero-bit types are rejected: `@emulate Int0` and `@emulate UInt0` throw an
`ArgumentError`, since a 0-bit integer carries no information.

## Querying and converting types

The package exposes a few helpers usable on both emulated and standard integers.

`bits(T)` (or `bits(x)`) returns the logical bit width of a type. For `BitInteger` types it matches `8 * sizeof(T)`; for emulated types it is the *logical* width, not the storage width:

```jldoctest usage
julia> bits(UInt3)
3

julia> bits(UInt8)
8
```

`storagetypeof(T)` returns the primitive type used internally to store values of `T`. For non-emulated primitive types it returns `T` itself:

```jldoctest usage
julia> storagetypeof(UInt3)
UInt8

julia> storagetypeof(UInt8)
UInt8
```

This is useful whenever code has to step outside the value-level API and work with the raw bits: allocating buffers (`Vector{storagetypeof(T)}`), `reinterpret`-ing to/from byte arrays, serialization, FFI calls into C code expecting a fixed primitive size, or packing several emulated integers into a larger word (as `PackedStructs.jl` does). Because the result is a regular Julia primitive type, it can be passed to any of these APIs unchanged.

`zext(T, x)` zero-extends `x` into the wider integer type `T`, treating the bits of `x` as unsigned regardless of `x`'s own signedness:

```jldoctest usage
julia> zext(UInt16, Int8(-1))
0x00ff
```

The single-argument form `zext(x)` zero-extends an emulated integer to its storage type, clearing the unused high bits. For non-emulated integers it is the identity.

## Related Work

- [Simen Gaure added a pull request to `BitIntegers.jl`](https://github.com/rfourquet/BitIntegers.jl/pull/54) which implements support for arbitrary bit integers via `llvmcall`.

- Work is ongoing to support arbitrary bit integers directly in Julia, see e.g. [Julia #45486](https://github.com/JuliaLang/julia/issues/45486) and [Julia #61359](https://github.com/JuliaLang/julia/pull/61359)

## License

Licensed under the [MIT License](LICENSE).