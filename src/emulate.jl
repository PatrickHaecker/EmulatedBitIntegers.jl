# The `@emulate` macro and the per-type method definitions it expands to. Each `@emulate T` user call evaluates the expressions assembled here in the caller's module, defining a primitive type plus the methods that need to dispatch on the concrete `T` (because of ambiguity with Base specializations, unrolled arity, or trait installation). Abstract-typed methods that serve every emulated type live in `methods.jl`.

macro emulate(Ts::Symbol...)
    # `Ts` is a `Vararg` and therefore hard to precompile when received by a method. We deliberately do the extraction of single elements here in the macro, as then the caller can constant-propagate the `Symbol`s and the calling method can be precompiled.
    defs = Pair{Symbol, Expr}[]
    for i in 1:length(Ts)
        emulate!(defs, Ts[i], __module__)
    end
    # Flatten the per-name sub-blocks into the result block in queue order.
    block = Expr(:block)
    for (_, sub) in defs
        append!(block.args, sub.args)
    end
    # The evaluation of the macro should not print anything.
    push!(block.args, nothing)
    # Do not use a pipe as it would not be precompiled due to being a macro.
    return esc(block)
end

# Each entry pairs the type name being queued with the `:block` expression that defines it. A single `Vector{Pair}` (instead of separate name and expression containers) keeps the queued-name lookup local, lets the inner builder return its block as a value, and gives one precompilable method instance across all `@emulate` arities.
function emulate!(defs::Vector{Pair{Symbol, Expr}}, T::Symbol, m::Module)

    # Do not redefine the type if it already exists or is already queued; this keeps things simple in the following and saves some time for repeated calls.
    (isdefined(m, T) || any(p -> p.first === T, defs)) && return

    t = IntegerType(T, m)

    # Do not define a type like UInt7_8. Instead define a type UInt7 if not already done and define the new name UInt7_8 for the already defined type UInt7.
    if t.redundant_storage_request
        T_canonical = t |> Symbol
        emulate!(defs, T_canonical, m)
        # `const` needs toplevel scope; wrap it in a `:block` so the outer flatten step appends a single `:toplevel` expression.
        push!(defs, T => Expr(:block, Expr(:toplevel, :(const $T = $T_canonical))))
    else
        push!(defs, T => emulate(T, t))
    end
end

# `@push! ex` expands to `push!(exprs, quote ex end)` in the caller scope: the call is escaped so it binds to the caller's local `exprs::Vector{Any}`, and the inner `:quote` (rather than a `QuoteNode`) preserves `$T` etc. so interpolations resolve at `emulate` runtime, not at macro-expansion time.
macro push!(ex)
    return Expr(:escape, Expr(:call, :push!, :exprs, Expr(:quote, ex)))
end

# Build and return the `:block` of definitions for a single type.
function emulate(T::Symbol, t::IntegerType)
    exprs = Expr[]
    parent = t.signed ? EmulatedSigned : EmulatedUnsigned

    # `EmulatedInteger` needs to be a primitive type to work with EnumX as `Base.bitcast` is used in v1.0.7. Although the bug is fixed in the `master` branch, other packages might contain similar bugs. Additionally, this makes the emulated integers as similar as possible to Base's primitive integers. However, [primitive types cannot use the type parameter for its size](https://discourse.julialang.org/t/primitive-parametric-types/27173). Whenever possible without loss of functionality or performance, we want to avoid defining more methods than necessary. Instead, different method instances of the same method are used to implement type-specific behavior. This is both a bit nicer on resource usage and can avoid quite some invalidations. In order to do this, we use parametric parent types (`EmulatedSigned{S}` and `EmulatedUnsigned{S}`) to dispatch on the storage type `S` for methods that need to know it (e.g. `bits`), and the concrete primitive type `T` for methods that need to dispatch on the logical type (e.g. `+`). This way, the methods that only need to know the storage type are shared between all emulated integers with the same storage type, and only the methods that need to dispatch on the logical type are per-type.

    #This is also the reason for UInt7 to be always 8 bits internally and using the underscore-suffix syntax like UInt7_16 to be 16 bits internally.
    @push! primitive type $T <: $parent{$(t.storage_type)} $(t.storage_bits) end

    # Per-type docstring attached to the type binding so `?$T` resolves. The constructor itself is the generic `(::Type{T})(x::Real) where T<:EmulatedInteger`; `Core.@doc` on the bare symbol documents the binding rather than a method, which is what `@doc $T` looks up.
    doc_T = """
        $T(x::Real)

    Construct an emulated integer of type `$T` from `x`.

    Throws an `InexactError` for out-of-range values, matching the contract of Julia's primitive integer constructors.
    """
    @push! Core.@doc $doc_T $T

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

    return Expr(:block, exprs...)
end
