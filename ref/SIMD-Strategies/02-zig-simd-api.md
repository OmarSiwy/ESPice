# Part II — The Complete Zig SIMD API

Verified against Zig 0.16.0. Result columns are real program output.

## Builtins — construction and introspection

| Builtin | Does | Verified |
|---|---|---|
| `@Vector(len, T)` | The vector type. Both parameters comptime. | — |
| `@splat(x)` | Broadcast a scalar to every lane. Requires an inferrable result type. | `{9,9,9,9}` |
| `@typeInfo(V).vector` | Gives `.len` and `.child`. | `len = 4` |
| `@sizeOf(V)` / `@bitSizeOf(V)` | Bytes / bits. | `16` / `128` |

Arrays coerce to vectors and back implicitly — this is how you load and store:
`const v: V = buf[i..][0..16].*;` and `const a: [16]u8 = v;`

## Builtins — rearranging lanes

| Builtin | Does | Verified |
|---|---|---|
| `@shuffle(T, a, b, mask)` | Gather lanes from two vectors. Non-negative mask index picks from `a`; `~i` picks index *i* from `b`. | `{10,3,20,3}` |
| `@select(T, pred, a, b)` | Lane-wise ternary driven by a `bool` vector. | `{10,3,30,7}` |

> **The single most important constraint in this API**
>
> **`@shuffle`'s mask must be comptime-known** — verified by compile error:
> *"'@shuffle' mask must be comptime-known"*. Vectors also cannot be indexed at a
> runtime index: *"vector index not comptime known"*. Convert to an array first.
> Consequence: no portable `pshufb`/`tbl`. See Technique 1.

## Builtins — reductions

`@reduce(op, vec)` collapses a vector to a scalar. All seven ops verified:

| Op | On `{10,20,30,40}` / `{3,3,7,7}` | On a `bool` vector |
|---|---|---|
| `.Add` | `100` | — |
| `.Mul` | `441` | — |
| `.Min` / `.Max` | `10` / `40` | — |
| `.And` | `3` | **all lanes true** |
| `.Or` | `7` | **any lane true** |
| `.Xor` | `0` | parity |

## Builtins — changing representation

| Builtin | Does | Verified |
|---|---|---|
| `@bitCast` | **Bool vector → packed integer.** Lane 0 → low bit. The gateway to mask-land. | `{t,f,t,f}` → `0b0101` |
| `@intFromBool` | Bool vector → integer vector of 0/1, element-wise. | `{1,0,1,0}` |
| `@intCast` | Lane-wise width change, value-preserving (safety-checked). | `{3,3,7,7}` |
| `@truncate` | Lane-wise narrowing, drops high bits. | `u32 → u8` |
| `@intFromFloat` | Lane-wise, truncates toward zero. | `{1,-2,3,-4}` |
| `@floatFromInt` | Lane-wise. | `{-5,2,-9,4}` |

## Builtins — bit operations (all element-wise on vectors)

Easy to miss, and it unlocks a lot. Each returns a vector.

| Builtin | On `{10, 20, 30, 40}` as `u32` |
|---|---|
| `@popCount` | `{2, 2, 4, 2}` |
| `@ctz` | `{1, 2, 1, 3}` |
| `@clz` | `{28, 27, 27, 26}` |
| `@byteSwap` | lane-wise endian swap |
| `@bitReverse` | lane-wise bit reversal |

## Builtins — arithmetic

Operators `+ - * / % & | ^ ~ << >>` and comparisons `== != < > <= >=` all work
lane-wise; comparisons yield a `bool` vector. Wrapping and saturating variants
verified in Technique 4.

| Builtin | Notes |
|---|---|
| `@abs @min @max` | Lane-wise; `@min`/`@max` take two vectors. |
| `@mulAdd(T, a, b, c)` | Fused multiply-add, single rounding. |
| `@divFloor @divTrunc @divExact` | Lane-wise. On `{-5,2,-9,4} / 2`: floor `{-3,1,-5,2}`, trunc `{-2,1,-4,2}`. |
| `@mod @rem` | Differ on negatives: `{1,2,0,1}` vs `{-2,2,0,1}`. |
| `@sqrt @floor @ceil @round @trunc` | Lane-wise float. |
| `@sin @cos @exp @exp2 @log @log2 @log10` | Lane-wise; may lower to library calls — check codegen in a hot loop. |

## Builtins — overflow, shifts, misc

The `*WithOverflow` family returns a tuple `.{ result_vector, overflow_bits }`,
where the second element is a `@Vector(len, u1)`.

| Builtin | Verified |
|---|---|
| `@addWithOverflow` | `{10,20,30,40} + 0xFFFFFFF0` → bits `{0,1,1,1}` |
| `@subWithOverflow` `@mulWithOverflow` `@shlWithOverflow` | same shape |
| `a << @Vector(4,u5){1,2,3,4}` | per-lane variable shift → `{20,80,240,640}` |
| `@shlExact` / `@shrExact` | Lane-wise; UB if bits would be lost. |
| `@prefetch(p, .{...})` | `.{ .rw = .read, .locality = 3, .cache = .data }` |
| `@setFloatMode(.optimized)` | Scope-local fast-math; the only sanctioned way to let the compiler reassociate float reductions. |

> **Variable shifts are a trap**
>
> Per-lane variable shifts are legal and often scalarised. The "packed lookup
> table + variable shift" idea in Technique 1 ballooned to 50–140 instructions for
> this reason. Always check `-femit-asm`.

---

# `std.simd` — all 21 public functions

Every `amount`/`shift`/`hop` parameter is **comptime**.

## Target adaptation

| Function | Returns | Verified (x86-64-v3) |
|---|---|---|
| `suggestVectorLength(T)` | `?comptime_int` | `u8`→32, `u32`→8, `u64`→4. `null` means "use scalar" — your fallback hook. |
| `suggestVectorLengthForCpu(T, cpu)` | `?comptime_int` | same, for an explicit CPU |
| `VectorIndex(V)` | `type` | smallest uint indexing a lane: `@Vector(16,u8)` → `u4` |
| `VectorCount(V)` | `type` | smallest uint holding the lane *count* → `u5` |

## Building vectors

| Function | Verified output | Use for |
|---|---|---|
| `iota(u8, 8)` | `{0,1,2,3,4,5,6,7}` | lane indices as data |
| `repeat(8, .{1,2,3})` | `{1,2,3,1,2,3,1,2}` | tiling a pattern |
| `join(a, b)` | `{1,2}`+`{3,4}` → `{1,2,3,4}` | concatenation |
| `extract(v, start, len)` | `extract(iota8,2,4)` → `{2,3,4,5}` | sub-vector slice |
| `interlace(.{a, b})` | `{11,21,12,22,13,23,14,24}` | SoA → AoS, planar → RGB |
| `deinterlace(2, v)` | → `{11,12,13,14}`, `{21,22,23,24}` | AoS → SoA |

## Moving lanes — the neighbour-access tools

| Function | On `{10,20,30,40}` | Use for |
|---|---|---|
| `shiftElementsRight(v,1,99)` | `{99,10,20,30}` | "the previous lane's value" |
| `shiftElementsLeft(v,1,99)` | `{20,30,40,99}` | "the next lane's value" |
| `mergeShift(a,b,1)` | `{20,30,40,50}` | **the `alignr` equivalent** — real bytes from the previous block, not filler |
| `rotateElementsLeft(v,1)` | `{20,30,40,10}` | circular |
| `rotateElementsRight(v,1)` | `{40,10,20,30}` | circular |
| `reverseOrder(v)` | `{40,30,20,10}` | endian / order flips |

> **Naming trap**
>
> `shiftElementsRight` moves toward *higher indices*, so it surfaces the
> *previous* element. On a bitmask, `>>` surfaces the *next* byte. The two
> "rights" point in opposite directions. Always say "lane-wise shift" out loud
> when you mean the vector one.

## Searches and counts

| Function | Verified |
|---|---|
| `firstTrue(v)` / `lastTrue(v)` | `{f,t,t,f}` → `1` / `2`; `null` if none |
| `countTrues(v)` | `2` |
| `firstIndexOfValue(v,x)` / `lastIndexOfValue` | 30 in `{10,20,30,40}` → `2` |
| `countElementsWithValue(v,x)` | `{5,5,1,5}`, 5 → `3` |

Conveniences over `@reduce`/`@select`. In hot loops, going through `@bitCast` to
a mask and using `@ctz`/`@popCount` is usually better — the mask can then answer
several further questions rather than being recomputed.

## Prefix scan

| Call | Verified output |
|---|---|
| `prefixScan(.Add, 1, iota(u8,8))` | `{0,1,3,6,10,15,21,28}` — running sum |
| `prefixScan(.Xor, 1, @splat(1))` | `{1,0,1,0,1,0,1,0}` — running parity |
| `prefixScan(.Max, 1, {3,1,7,2})` | `{3,3,7,7}` — running maximum |
| `prefixScanWithFunc(hop, vec, ErrType, func, identity)` | arbitrary associative op. **`ErrType` is a *type*** — pass `void` when `func` does not return an error union. |

Implemented as a `log₂(len)` chain of lane-wise shifts. The `.Xor` case is the
lane-wise cousin of "am I inside a string?"; for 64-bit-mask prefix XOR, `clmul`
is dramatically faster.
