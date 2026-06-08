using EmulatedBitIntegers
using EmulatedBitIntegers: IntegerType, nextpowerof2bytesize
using Test
using Pkg
using BitIntegers
using IterTools: fieldvalues
using JET: get_reports, report_package

integertype(s) = IntegerType(s, Main)
values(x) = x |> fieldvalues |> collect
@define_integers 24

# Top-level emulated types reused across the testsets below. `@emulate` is idempotent, so individual testsets re-declare what they need locally for readability.
@emulate(UInt1, Int1, UInt3, Int3, Int4, Int20)
@emulate(UInt1_64, UInt3_64, Int4_8, Int4_16, Int7_16, Int20_32)


# ============================================================================
# Static analysis
# ============================================================================

@testset "JET" begin
    @test EmulatedBitIntegers |> report_package |> get_reports |> isempty
end


# ============================================================================
# Macro & integer-type machinery
# ============================================================================

@testset "nextpowerof2bytesize" begin
    @test 15 |> nextpowerof2bytesize == 16
    @test 17 |> nextpowerof2bytesize == 32
end

@testset "IntegerType" begin
    @test integertype(:Int17) |> values == [true, 17, 32, false, Int32]
    @test integertype(:Int179) |> values == [true, 179, 256, false, BitIntegers.Int256]
    @test integertype(:UInt9) |> values == [false, 9, 16, false, UInt16]
    @test integertype(:UInt22_24) |> values == [false, 22, 24, false, UInt24]
end

@testset "macro-produced type hierarchy" begin
    @test UInt1 <: Unsigned
    @test UInt1_64 <: Unsigned
    @test Int20 <: Signed
    @test Int20_32 <: Signed
end

@testset "rejected macro inputs" begin
    # Zero-bit integers fail the `1 <= logical_bits < storage_bits` check in `IntegerType`.
    @test_throws ArgumentError @macroexpand @emulate Int0
    @test_throws ArgumentError @macroexpand @emulate UInt0
    # Non-`Symbol` arguments are rejected by the macro's `Ts::Symbol...` signature: `UInt-1` parses as a subtraction `Expr`, `42` is an `Int`.
    @test_throws MethodError @macroexpand @emulate UInt-1
    @test_throws MethodError @macroexpand @emulate 42
    # Malformed width suffix fails the name regex in `IntegerType`; `@eval` throws a `LoadError` when the macro-expansion has an `ArgumentError`.
    @test_throws LoadError @eval(@emulate(Int6_abd))
end

@testset "type_alias" begin
    @emulate Int7 Int7_8
    @test Int7 === Int7_8
    @emulate UInt25 UInt25_32
    @test UInt25(1) + UInt25_32(2) == 3
    @emulate Int63_64
    @test 1 |> Int63 == 1
end

@testset "constructor docstrings" begin
    @emulate UInt9 Int9
    # The macro attaches a per-type docstring to the type binding so `help?> UInt9` resolves. Missing attachment would return the fallback "No documentation found".
    @test occursin("Construct an emulated integer of type `UInt9`", string(@doc UInt9))
    @test occursin("InexactError", string(@doc UInt9))
end


# ============================================================================
# Trait queries
# ============================================================================

@testset "storagetypeof" begin
    @emulate UInt6 Int14 UInt25 Int35
    @test UInt6 |> storagetypeof === UInt8
    @test Int14 |> storagetypeof === Int16
    @test UInt25 |> storagetypeof === UInt32
    @test Int35 |> storagetypeof === Int64
    @test Int16 |> storagetypeof === Int16
    @test UInt64 |> storagetypeof === UInt64
    # Reject types whose storage cannot be unambiguously determined: abstract types, `Union`s, `UnionAll`s, and concrete struct types without a single-field storage chain.
    @test_throws ArgumentError storagetypeof(Integer)
    @test_throws ArgumentError storagetypeof(Union{Int,UInt})
    @test_throws ArgumentError storagetypeof(Vector)
    struct ParametricSingleField{T}; x::T; end
    @test_throws ArgumentError storagetypeof(ParametricSingleField)
    struct MultiField; a::Int; b::Int; end
    @test_throws ArgumentError storagetypeof(MultiField)
end

@testset "bits on struct" begin
    @emulate UInt3 Int5
    @test bits(UInt8) === 8
    @test bits(Int64) === 64
    @test bits(UInt3) === 3
    # Plain struct: bits is the recursive sum of `bits` over fields.
    struct TwoInts; a::Int8; b::Int16; end
    @test bits(TwoInts) === 24
    struct Mixed; a::UInt3; b::Int5; c::UInt8; end
    @test bits(Mixed) === 3 + 5 + 8
    # Nested struct.
    struct Outer; head::Int8; inner::TwoInts; end
    @test bits(Outer) === 8 + 24
    # Empty struct.
    struct Empty; end
    @test bits(Empty) === 0
    # Instance form delegates to type.
    @test bits(Int8(1)) === 8
    @test bits(TwoInts(Int8(0), Int16(0))) === 24
end

@testset "zext" begin
    @emulate UInt4 Int4
    @test -1 |> Int4 |> zext === 0b1111 |> Int8
    @test UInt4 |> typemax |> zext === 0b1111 |> UInt8
    @test reinterpret(UInt8, 0b1111) |> zext === 0b1111 |> UInt8
    @test -1 |> Int8 |> zext === -1 |> Int8
    @test zext(UInt16, -1 |> Int4) === 0b1111 |> UInt16
    @test zext(UInt16, 2 |> UInt4) === 0b10 |> UInt16
end


# ============================================================================
# Construction, conversion, parsing
# ============================================================================

@testset "typemin / typemax / oneunit" begin
    @test typemin(Int4) == -8
    @test typemax(Int4) == 7
    @test typemax(UInt3) == 7
    @test typemin(UInt3) == 0
    @test oneunit(UInt3) === UInt3(1)
end

@testset "Float to emulated / round / floor / ceil / trunc" begin
    @emulate UInt3 Int3
    # Direct constructor.
    @test UInt3(2.0) === UInt3(2)
    @test Int3(-2.0) === Int3(-2)
    @test_throws InexactError UInt3(2.5)
    @test_throws InexactError UInt3(8.0)   # out of range
    @test_throws InexactError Int3(-5.0)   # out of range
    # `convert` routes through the constructor.
    @test convert(UInt3, 2.0) === UInt3(2)
    # Rounding-into-type.
    @test round(UInt3, 2.5) === UInt3(2)   # ties to even
    @test round(UInt3, 2.4) === UInt3(2)
    @test floor(Int3, -1.5) === Int3(-2)
    @test ceil(Int3, 1.5) === Int3(2)
    @test trunc(UInt3, 2.9) === UInt3(2)
    @test_throws InexactError round(UInt3, 8.0)
end

@testset "parse / tryparse" begin
    @emulate UInt3 Int3
    @test parse(UInt3, "5") === UInt3(5)
    @test parse(Int3, "-2") === Int3(-2)
    @test parse(UInt3, "7", base=16) === UInt3(7)
    @test_throws OverflowError parse(UInt3, "9")
    @test_throws OverflowError parse(UInt3, "256")
    @test_throws OverflowError parse(Int3, "-9")
    @test_throws ArgumentError parse(UInt3, "abc")
    @test tryparse(UInt3, "5") === UInt3(5)
    @test tryparse(Int3, "-2") === Int3(-2)
    @test tryparse(UInt3, "9") === nothing
    @test tryparse(Int3, "-9") === nothing
    @test tryparse(UInt3, "abc") === nothing
end


# ============================================================================
# Arithmetic
# ============================================================================

@testset "modular arithmetic" begin
    @emulate UInt3 Int3 Int4

    # Unsigned wraparound mod 2^N (UInt3 range 0..7).
    @test typemax(UInt3) + UInt3(1) === UInt3(0)
    @test UInt3(0) - UInt3(1) === typemax(UInt3)
    @test typemax(UInt3) * UInt3(2) === UInt3(6)  # 14 mod 8
    @test UInt3(5) * UInt3(3) === UInt3(7)        # 15 mod 8
    @test -UInt3(1) === typemax(UInt3)            # 0 - 1 wraps
    @test -UInt3(0) === UInt3(0)                  # -0 stays 0

    # Signed two's-complement wraparound (Int3 range -4..3).
    @test typemax(Int3) + Int3(1) === typemin(Int3)
    @test typemin(Int3) - Int3(1) === typemax(Int3)
    @test Int3(2) * Int3(2) === typemin(Int3)     # 4 wraps to -4
    @test Int3(-3) * Int3(2) === Int3(2)          # -6 wraps to 2
    @test Int3(-4) * Int3(-1) === typemin(Int3)   # 4 wraps to -4

    # `-typemin` and `abs(typemin)` are the classic signed edge cases: the
    # positive counterpart of `typemin` is not representable, so both wrap
    # back to `typemin` itself.
    @test -typemin(Int3) === typemin(Int3)
    @test abs(typemin(Int3)) === typemin(Int3)
    @test abs(Int3(-3)) === Int3(3)

    # `div(typemin, -1)` overflows for the same reason (extended here to Int4
    # so the wrap value differs from the input and is unambiguous).
    @test div(typemin(Int4), Int4(-1)) === typemin(Int4)

    # Shifts. Left shift drops high bits via the modular `% T` cleaning;
    # right shift on signed values sign-extends (so `-1 >> 1 == -1`).
    @test UInt3(7) << 1 === UInt3(6)              # 0b111 << 1 = 0b1110 → 0b110
    @test UInt3(1) << 3 === UInt3(0)              # shifted entirely out
    @test UInt3(4) >> 1 === UInt3(2)
    @test Int3(1) << 2 === typemin(Int3)          # 0b001 << 2 = 0b100 = -4
    @test Int3(-1) >> 1 === Int3(-1)              # arithmetic shift preserves sign

    # Multi-argument `+` / `-` (the unrolled forms) must still wrap correctly.
    @test UInt3(2) + UInt3(2) + UInt3(2) + UInt3(2) === UInt3(0)  # 8 mod 8
    @test Int3(1) - Int3(2) - Int3(3) === Int3(-4)
end

@testset "modular arithmetic with non-default storage" begin
    # Same logical width, wider storage: behavior must not depend on the
    # storage type (i.e. the cleaning must use the *logical* mask, not the
    # storage mask).
    @emulate UInt3_64 Int3_16
    @test typemax(UInt3_64) + UInt3_64(1) === UInt3_64(0)
    @test (typemax(UInt3_64) + UInt3_64(1))[] === UInt64(0)  # storage actually cleared
    @test typemax(Int3_16) + Int3_16(1) === typemin(Int3_16)
    @test (Int3_16(2) * Int3_16(2))[] === Int16(-4)          # storage sign-extended
end

@testset "unsigned overflow cleans storage" begin
    @emulate UInt3
    x = UInt3(7) + UInt3(1)
    @test x[] === 0x00
    @test x === UInt3(0)
    @test hash(x) === hash(UInt3(0))
    @test Int(x) === 0
    @test sprint(show, x) == "0x0"
end

@testset "div / fld / cld / fldmod / divrem / ÷ / /" begin
    @emulate UInt3 Int3
    @test div(Int3(-3), Int3(2)) === Int3(-1)
    @test fld(Int3(-3), Int3(2)) === Int3(-2)
    @test cld(Int3(-3), Int3(2)) === Int3(-1)
    @test fld(Int3(3), Int3(-2)) === Int3(-2)
    @test cld(Int3(3), Int3(-2)) === Int3(-1)
    @test fldmod(Int3(-3), Int3(2)) === (Int3(-2), Int3(1))
    @test divrem(Int3(-3), Int3(2)) === (Int3(-1), Int3(-1))
    @test div(UInt3(5), UInt3(3)) === UInt3(1)
    @test fld(UInt3(5), UInt3(3)) === UInt3(1)
    @test cld(UInt3(5), UInt3(3)) === UInt3(2)
    @test fldmod(UInt3(5), UInt3(3)) === (UInt3(1), UInt3(2))
    @test divrem(UInt3(5), UInt3(3)) === (UInt3(1), UInt3(2))
    @test div(Int3(3), Int3(2), RoundNearest) === Int3(2)
    @test div(Int3(3), Int3(2), RoundFromZero) === Int3(2)
    # Every concrete `RoundingMode{:Mode}` Base's integer-`div` machinery resolves to must have a matching `Base.div(::T, ::T, ::RoundingMode{:Mode}) where T<:Emulated*` method installed by this package. Walking both method tables (instead of comparing against the source-side constant directly) keeps the check honest end-to-end; a new mode added to Julia and missed in `methods.jl` surfaces as a test failure rather than a silent dispatch into Base's promotion fallback.
    rounding_modes_of(meths) = let s = Set{Type}()
        for m in meths
            sig = m.sig isa UnionAll ? Base.unwrap_unionall(m.sig) : m.sig
            rm = sig.parameters[end]
            for t in (rm isa Union ? Base.uniontypes(rm) : (rm,))
                t === RoundingMode || push!(s, t)  # skip the abstract-`RoundingMode` fallback method
            end
        end
        s
    end
    base_modes = rounding_modes_of(methods(div, Tuple{Integer, Integer, RoundingMode}))
    ours_modes = rounding_modes_of(Iterators.filter(m -> m.module === EmulatedBitIntegers,
                                                    methods(div, Tuple{EmulatedBitIntegers.EmulatedInteger, EmulatedBitIntegers.EmulatedInteger, RoundingMode})))
    @test base_modes == ours_modes
    # `÷` is the operator form of `div`; `/` returns Float64.
    @test Int4(4) ÷ Int4(4) === Int4(1)
    @test_throws DivideError Int4(-2) ÷ Int4(0)
    @test Int4(4) / Int4(2) === 2.0
end

@testset "rem / mod between two emulated" begin
    @emulate UInt3 Int3
    @test rem(UInt3(5), UInt3(3)) === UInt3(2)
    @test mod(UInt3(5), UInt3(3)) === UInt3(2)
    @test rem(Int3(-3), Int3(2)) === Int3(-1)
    @test mod(Int3(-3), Int3(2)) === Int3(1)
    @test rem(Int3(3), Int3(-2)) === Int3(1)
    @test mod(Int3(3), Int3(-2)) === Int3(-1)
    @test UInt3(5) % UInt3(3) === UInt3(2)
end

@testset "modular cast between emulated types" begin
    @emulate UInt2 Int2 UInt3 Int3
    @test Int3(1) % Int2 === Int2(1)
    @test UInt3(2) % UInt2 === UInt2(2)
    @test UInt3(1) % Int2 === Int2(1)
    @test Int2(1) % Int3 === Int3(1)
end

@testset "checked arithmetic / gcd / lcm" begin
    @emulate UInt3 Int3
    @test Base.Checked.checked_abs(Int3(-2)) === Int3(2)
    @test_throws OverflowError Base.Checked.checked_abs(typemin(Int3))
    @test Base.Checked.checked_abs(UInt3(5)) === UInt3(5)
    @test Base.Checked.add_with_overflow(UInt3(2), UInt3(3)) === (UInt3(5), false)
    @test Base.Checked.add_with_overflow(UInt3(5), UInt3(5)) === (UInt3(2), true)
    @test Base.Checked.mul_with_overflow(UInt3(3), UInt3(3)) === (UInt3(1), true)
    @test Base.Checked.sub_with_overflow(UInt3(1), UInt3(3)) === (UInt3(6), true)
    @test gcd(UInt3(6), UInt3(4)) === UInt3(2)
    @test gcd(Int3(2), Int3(-3)) === Int3(1)
    @test lcm(UInt3(2), UInt3(3)) === UInt3(6)
end

@testset "flipsign" begin
    @emulate Int3
    @test flipsign(Int3(-2), Int3(-1)) === Int3(2)
    @test flipsign(Int3(-2), Int3(1)) === Int3(-2)
    @test flipsign(Int3(3), Int3(1)) === Int3(3)
    @test flipsign(Int3(3), Int3(-2)) === Int3(-3)
    @test flipsign(Int3(-4), Int3(1)) === Int3(-4)
    @test flipsign(Int3(-4), Int3(-2)) === Int3(-4)
end


# ============================================================================
# Promotion
# ============================================================================

@testset "promote" begin
    @emulate UInt14 Int2
    # Wider regular int wins.
    @test promote_type(Int64, Int4) == Int64
    @test promote_type(UInt64, Int4) == UInt64
    # Emulated wins over narrower regular int.
    @test UInt14(17) + Int2(1) === UInt14(18)
    @test UInt14(42) + Int16(-2) === Int16(40)
    @test UInt14(82) + UInt8(14) === UInt14(96)
end

@testset "promote with AbstractFloat" begin
    @emulate UInt3 Int3
    @test promote_type(UInt3, Float64) === Float64
    @test promote_type(Int3, Float32) === Float32
    @test promote_type(UInt3, Float16) === Float16
    @test UInt3(2) + 1.0 === 3.0
    @test Int3(-1) * 2.5f0 === -2.5f0
    @test promote(UInt3(2), 1.0) === (2.0, 1.0)
end


# ============================================================================
# Bitwise
# ============================================================================

@testset "bitwise ops" begin
    @emulate UInt3 Int3 UInt3_64
    # AND / OR / XOR — straightforward bit twiddling within the logical width.
    @test UInt3(0b110) & UInt3(0b011) === UInt3(0b010)
    @test UInt3(0b101) | UInt3(0b010) === UInt3(0b111)
    @test xor(UInt3(0b101), UInt3(0b011)) === UInt3(0b110)
    @test Int3(-1) & Int3(3) === Int3(3)          # -1 = 0b111 logically
    @test Int3(-1) | Int3(0) === Int3(-1)
    @test xor(Int3(-1), Int3(-1)) === Int3(0)
    # NOT — flips exactly the N logical bits, leaving storage clean.
    @test ~UInt3(0) === typemax(UInt3)
    @test ~UInt3(0b011) === UInt3(0b100)
    @test ~typemax(UInt3) === UInt3(0)
    @test ~Int3(0) === Int3(-1)                   # ~0b000 = 0b111 = -1
    @test ~Int3(-1) === Int3(0)
    @test ~typemin(Int3) === typemax(Int3)        # ~0b100 = 0b011 = 3
    # Storage stays clean — same invariant as arithmetic ops.
    @test (~UInt3(0))[] === UInt8(0b111)
    @test (~UInt3_64(0))[] === UInt64(0b111)
    @test (~Int3(0))[] === Int8(-1)               # sign-extended
end

@testset "logical right shift (>>>) and unsigned left shift" begin
    @emulate UInt3 Int3
    # Unsigned >>>: same as >>.
    @test UInt3(4) >>> 1 === UInt3(2)
    @test UInt3(4) >>> UInt(1) === UInt3(2)
    # Signed >>>: treats the bit pattern as unsigned, fills with zero.
    @test Int3(-1) >>> 1 === Int3(3)   # 0b111 → 0b011
    @test Int3(-2) >>> 1 === Int3(3)   # 0b110 → 0b011
    # Disambiguation: `prevpow` internally does `T << ::UInt`.
    @test UInt3(1) << UInt(2) === UInt3(4)
    @test Int3(1) << UInt(2) === Int3(-4)
    @test prevpow(2, UInt3(5)) === UInt3(4)
end

@testset "bitrotate" begin
    @emulate UInt3 Int3
    @test bitrotate(UInt3(0b100), 1) === UInt3(0b001)
    @test bitrotate(UInt3(0b001), 1) === UInt3(0b010)
    @test bitrotate(UInt3(0b111), 0) === UInt3(0b111)
    @test bitrotate(UInt3(0b101), 3) === UInt3(0b101)   # Full rotation = identity.
    @test bitrotate(UInt3(0b101), -1) === bitrotate(UInt3(0b101), 2)
    # Inverse: rotate by k then by -k gives identity.
    @test bitrotate(bitrotate(UInt3(5), 2), -2) === UInt3(5)
end


# ============================================================================
# Bit counting
# ============================================================================

@testset "count_ones / count_zeros" begin
    @test UInt3(0b101) |> count_ones === 2
    @test UInt3(0b101) |> count_zeros === 1
    @test UInt3 |> typemax |> count_ones === 3
    @test UInt3(0) |> count_zeros === 3
    @test Int3(3) |> count_ones === 2          # 0b011
    @test Int3(-1) |> count_ones === 3         # all bits set
    @test Int3(-1) |> count_zeros === 0
    @test Int3(-4) |> count_ones === 1         # 0b100
    @test Int3(-4) |> count_zeros === 2
end

@testset "leading_ones / trailing_ones" begin
    @test UInt3(0b110) |> leading_ones === 2
    @test UInt3(0b011) |> leading_ones === 0
    @test UInt3 |> typemax |> leading_ones === 3
    @test UInt3(0b011) |> trailing_ones === 2
    @test UInt3(0b110) |> trailing_ones === 0
    @test Int3(-1) |> leading_ones === 3
    @test Int3(-2) |> leading_ones === 2       # 0b110
    @test Int3(3) |> leading_ones === 0
    @test Int3(-1) |> trailing_ones === 3
    @test Int3(-2) |> trailing_ones === 0
end

@testset "trailing_zeros" begin
    @emulate UInt2
    @test 0b10 |> UInt2 |> trailing_zeros === 1
    @test 0b01 |> UInt2 |> trailing_zeros === 0
end


# ============================================================================
# Introspection / display
# ============================================================================

@testset "bitstring" begin
    @emulate UInt3 Int3
    @test bitstring(UInt3(0)) == "000"
    @test bitstring(UInt3(5)) == "101"
    @test bitstring(UInt3(7)) == "111"
    @test bitstring(Int3(3)) == "011"
    @test bitstring(Int3(-1)) == "111"
    @test bitstring(Int3(-4)) == "100"
    # Storage type wider than next power-of-two byte size, exercising the slice past the storage padding.
    @emulate UInt5_16
    @test bitstring(UInt5_16(0)) == "00000"
    @test bitstring(UInt5_16(31)) == "11111"
    @test length(bitstring(UInt5_16(0))) === 5
end


# ============================================================================
# Misc
# ============================================================================

@testset "rand" begin
    using Random
    @emulate UInt3 Int3
    Random.seed!(42)
    @test rand(UInt3) isa UInt3
    @test rand(UInt3, 5) isa Vector{UInt3}
    # Distribution covers the full logical range (extremely high probability with 2000 draws).
    @test extrema(rand(UInt3) for _ in 1:2000) === (UInt3(0), UInt3(7))
    @test extrema(rand(Int3) for _ in 1:2000) === (Int3(-4), Int3(3))
end

@testset "range length" begin
    @emulate UInt3 UInt129
    @test length(UInt3(1):UInt3(3)) === 3       # Int, not UInt3.
    @test length(UInt3(0):UInt3(7)) === 8       # would wrap to 0 with element-typed result.
    @test length(UInt3(3):UInt3(2)) === 0       # empty range.
    # High endpoints (> typemax(Int)) with a small count: must not throw `InexactError` on endpoint conversion.
    @test length(typemax(UInt129)-UInt129(2) : typemax(UInt129)) === 3
end

@testset "large" begin
    @emulate Int129 UInt129
    @test Int129(1) + Int129(2) === Int129(3)
    @test UInt129(10) * UInt129(100) === UInt129(1000)
end


# ============================================================================
# Performance invariants
# ============================================================================

# Capture LLVM IR of `f(::types...)` and return the lines containing actual operations: drop preamble (`define`/`declare`), labels, braces, comments, blank lines, and the trailing `ret` (which is bookkeeping, not an operation — when the caller inlines `f`, only the operation lines remain).
function llvm_ops(f, types)
    io = IOBuffer()
    InteractiveUtils.code_llvm(io, f, types; debuginfo=:none, raw=false)
    filter(!contains(r"^\s*($|;|define|declare|\}|\{\s*$|.+:\s*$|ret\b)"), split(io |> take! |> String, "\n"))
end

# A `call` instruction targeting an LLVM intrinsic (`@llvm.ctpop`, `@llvm.abs`, …) is a single native instruction, not a runtime dispatch. Only flag calls into Julia runtime functions (`@j_*`, `@julia_*`, `@ijl_*`, `@jl_*`).
runtime_calls(ops) = count(l -> occursin("call ", l) && !occursin("@llvm.", l), ops)

@testset "performance invariants" begin
    using InteractiveUtils
    @emulate UInt3 Int3 UInt20

    # `>>>` with a runtime shift amount lowers to ~13 IR lines (mask, branch, mod), but the typical hot-path use is a constant shift; wrap it in a helper so the constant folds into the body.
    shr1(x::UInt3) = x >>> 1

    # `(label, f, types, exact_ops)`. Counts are exact (calibrated on Julia 1.10.11 and 1.13.0-rc1; both produce identical IR for these methods). Any drift — up or down — is a regression worth investigating, so use `==` rather than `<=`.
    cases = [
        ("UInt3 +",             Base.:+,         Tuple{UInt3, UInt3},       2),
        ("UInt3 *",             Base.:*,         Tuple{UInt3, UInt3},       2),
        ("UInt3 &",             Base.:&,         Tuple{UInt3, UInt3},       1),
        ("UInt3 |",             Base.:|,         Tuple{UInt3, UInt3},       1),
        ("UInt3 xor",           Base.xor,        Tuple{UInt3, UInt3},       1),
        ("UInt3 ~",             Base.:~,         Tuple{UInt3},              2),
        ("UInt3 >>> 1 (const)", shr1,            Tuple{UInt3},              2),
        ("UInt3 count_ones",    Base.count_ones, Tuple{UInt3},              2),
        ("UInt3 abs (id)",      Base.abs,        Tuple{UInt3},              0),
        ("UInt8 % UInt3",       Base.rem,        Tuple{UInt8, Type{UInt3}}, 1),
        ("Int3 +",              Base.:+,         Tuple{Int3, Int3},         3),
        ("Int3 abs",            Base.abs,        Tuple{Int3},               3),
        ("Int8 % Int3",         Base.rem,        Tuple{Int8, Type{Int3}},   2),
        ("UInt20 +",            Base.:+,         Tuple{UInt20, UInt20},     2),
    ]

    for (label, f, types, exact_ops) in cases
        ops = llvm_ops(f, types)
        # No dispatch into runtime helpers — every operation must lower to native instructions or LLVM intrinsics. Also rules out allocations, which would surface as `@jl_gc_*` calls.
        @test runtime_calls(ops) == 0
        # Exact op count — any drift (up or down) signals a codegen change worth a look.
        @test length(ops) == exact_ops
    end
end


# ============================================================================
# Integration
# ============================================================================

# Test that packages using `EmulatedBitIntegers` can precompile successfully.
@testset "precompile" begin
    @test (Pkg.precompile("PrecompileTest"; strict=true, io=devnull); true)
end

@testset "README doctests" begin
    using Documenter
    using Logging: ConsoleLogger, with_logger, Error
    DocMeta.setdocmeta!(EmulatedBitIntegers, :DocTestSetup, :(using EmulatedBitIntegers); recursive=true)
    # `Documenter.doctest` expects a source directory, so stage the README into a tmpdir as `index.md`.
    mktempdir() do dir
        cp(joinpath(pkgdir(EmulatedBitIntegers), "README.md"), joinpath(dir, "index.md"))
        # Drop Documenter's pipeline `@info` chatter and the `edit_link` `@warn` (it shells out to `git remote` in the staged tmpdir which isn't a repo). Doctest failures surface through the active testset, not the logger.
        with_logger(ConsoleLogger(stderr, Error)) do
            Documenter.doctest(dir, [EmulatedBitIntegers])
        end
    end
end

include("Aqua.jl")
