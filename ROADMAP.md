# Roadmap

Speculative design directions for `EmulatedBitIntegers.jl`. These are not
commitments — they are sketched here so the trade-offs are not lost.

## Lazy bit cleaning

The current implementation cleans the unused storage bits after every
operation (0 for positive numbers, 1 for negative numbers). An alternative
strategy would be to only clean the bits at the *beginning* of an operation
when it makes a difference: cleaning would still be required before
multiplication or `show`, but not before addition or subtraction of unsigned
integers.

## Two-type "dirty" variant

A probably even better strategy would be to expose two types per logical
width, e.g. `UInt3` and `UInt3Dirty`:

- After an unsigned-unsigned `+`, no `rem` would be computed and the return
  type would be `UInt3Dirty`.
- Unsigned `+` on `UInt3Dirty` operands would compose without ever cleaning,
  so chains of additions would not pay the masking cost at all.
- `rem` would only be computed when a canonical value is actually required
  (e.g. for multiplication or printing).

This should be fully type stable.
