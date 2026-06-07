# The `@emulate` macro and the per-type method definitions it expands to. Each `@emulate T` user call evaluates the expressions assembled here in the caller's module, defining a primitive type plus the methods that need to dispatch on the concrete `T` (because of ambiguity with Base specializations, unrolled arity, or trait installation). Abstract-typed methods that serve every emulated type live in `methods.jl`.

macro emulate(Ts::Symbol...)
    # `Ts` is a `Vararg` and therefore hard to precompile when received by a method. We deliberately do the extraction of single elements here in the macro, as then the caller can constant-propagate the `Symbol`s and the calling method can be precompiled.
    block = Expr(:block)
    to_be_defined = Symbol[]
    for i in 1:length(Ts)
        emulate!(block, to_be_defined, Ts[i], __module__)
    end
    # The evaluation of the macro should not print anything.
    push!(block.args, nothing)
    return block |> esc
end

# Use an `AbstractVector` instead of an `NTuple` to avoid recompilation for each arity of `@emulate` (e.g. `@emulate Int2` vs. `@emulate Int2 Int3`).
function emulate!(block::Expr, to_be_defined::Vector{Symbol}, T::Symbol, m::Module)

    # Do not redefine the type if it already exists or is already prepared to be defined to keep things simple in the following and save some time for repeated calls.
    (isdefined(m, T) || T ∈ to_be_defined) && return

    t = IntegerType(T, m)

    # Do not define a type like UInt7_8. Instead define a type UInt7 if not already done and define the new name UInt7_8 for the already defined type UInt7.
    if t.redundant_storage_request
        T_canonical = t |> Symbol

        if !(isdefined(m, T_canonical) || T_canonical ∈ to_be_defined)
            push!(to_be_defined, T_canonical)
            emulate!(block.args, T_canonical, IntegerType(T_canonical, m))
        end
        push!(to_be_defined, T)
        # This needs to be in global (toplevel) scope for `const` being allowed.
        push!(block.args, Expr(:toplevel, :(const $T = $T_canonical)))
    else
        push!(to_be_defined, T)
        emulate!(block.args, T, t)
    end
end

# `@push! ex` expands to `push!(exprs, quote ex end)` in the caller scope: the call is escaped so it binds to the caller's local `exprs::Vector{Any}`, and the inner `:quote` (rather than a `QuoteNode`) preserves `$T` etc. so interpolations resolve at `emulate!` runtime, not at macro-expansion time.
macro push!(ex)
    return Expr(:escape, Expr(:call, :push!, :exprs, Expr(:quote, ex)))
end

function emulate!(exprs::Vector{Any}, T::Symbol, t::IntegerType)
    parent = t.signed ? EmulatedSigned : EmulatedUnsigned

    # For EnumX (and probably other packages) to work an EmulatedInteger needs to be a primitive type as `Base.bitcast` is used in v1.0.5. This is the reason why the storage_bits are not a type parameter of `EmulatedInteger`, as a [primitive type cannot use the type parameter for its size](https://discourse.julialang.org/t/primitive-parametric-types/27173). This is also the reason for UInt7 to be always 8 bits internally and using the underscore-suffix syntax like UInt7_16 to be 16 bits internally.
    @push! primitive type $T <: $parent $(t.storage_bits) end

    # Bake the docstring into a `Core.@doc` macrocall in the pushed expression.
    doc_T = """
        $T(x)

    Construct an object of type `$T`.

    Throws an `InexactError` for out-of-range values, like other Julia integer constructors.
    """
    inrange = t.signed ? :($(t |> minvalue) <= x <= $(t |> maxvalue)) : :(x <= $(t |> maxvalue))
    # `Core.throw_inexacterror` is the `@noinline` helper Base's integer constructors use; it keeps the cold error branch out of line so this hot constructor inlines down to a compare + reinterpret.
    @push! Core.@doc $doc_T $T(x::$(t.storage_type)) = $inrange ? reinterpret($T, x) : Core.throw_inexacterror(:trunc, $T, x)

    T_unsafe = Symbol(T, :Unsafe)
    @push! $T_unsafe(x::Integer) = reinterpret($T, convert($(t.storage_type), x))

    # Create the type with different signedness, but identical prefix and size, compared to the original type. This will only be done, if the other type is defined, too, and then the conversion methods for both directions are defined. In this sense we delay the definition of the conversion methods until the other type is defined.
    T_dual = t |> signdual |> Symbol
    T_signed, T_unsigned = t.signed ? (T, T_dual) : (T_dual, T)
    @push! if @isdefined($T_dual)
        # Convert types
        Base.unsigned(::Type{$T_signed}) = $T_unsigned
        Base.signed(::Type{$T_unsigned}) = $T_signed

        # Convert values. Signed and Unsigned must throw an InexactError if the value gets out of range by the conversion, so go through the regular constructor.
        Base.Unsigned(x::$T_signed) = x |> $T_unsigned
        Base.Signed(x::$T_unsigned) = x |> $T_signed
    end

    # Multi-arg `+`/`-` unrolls: the safe arity depends on `wastedbits` (`2^wastedbits - 1` operands fit without intermediate overflow), so the number of methods is per-type and therefore in the macro.
    for OP ∈ (:+, :-)
        for k = 3 : min(2^(t |> wastedbits) - 1, 8)
            # The following code builds the variable length form of
            # "@eval M Base.$OP(x1::$T, x2::$T, x3::$T) = $OP(x1[], x2[], x3[]) % $T"
            lhs = Expr(:call, :(Base.$OP), map(n -> :($(Symbol("x", n))::$T), 1:k)...)
            rhs = Expr(:call, OP, map(n -> :($(Symbol("x", n))[]), 1:k)...)
            @push! $lhs = $rhs % $T
        end
    end

    # Per-type traits feeding the abstract-typed methods in `methods.jl`. Each is a single-method constant-returning function so the call sites fold to a literal at inference time. The methods are added to functions owned by `EmulatedBitIntegers`, so the macro-expansion site (the caller's module) reaches them via the fully-qualified module path; function-name interpolation does not work in macros [discussion](https://discourse.julialang.org/t/adding-method-to-function-in-macro/128613/5). All other trait values (`wastedbits`, `maxvalue`, `minvalue`, `hexdigits`) are derived from these two in `methods.jl`.
    @push! $EmulatedBitIntegers.bits(::Type{<:$T}) = $(t.logical_bits)
    @push! $EmulatedBitIntegers.storagetypeof(::Type{$T}) = $(t.storage_type)
end
