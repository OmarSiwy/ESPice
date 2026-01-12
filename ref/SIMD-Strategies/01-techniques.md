# Part I — Techniques

## Technique 01 — Vectorised classification

Foundational primitive. `pshufb` (x86 SSSE3) and `tbl` (ARM NEON) take one
register as a **16-entry lookup table** and another as **16 indices**, returning
16 results in a single instruction. A 16-way parallel table lookup.

An index is 4 bits → arbitrary function of a *nibble*. For a whole byte, two
lookups and combine:

```
lo_class = lookup16(lo_table, byte & 0x0F)
hi_class = lookup16(hi_table, byte >> 4)
classes  = lo_class & hi_class      // one bit per category
```

Every byte now carries a bitset of categories it belongs to: whitespace,
structural, UTF-8 continuation, invalid lead, base64 digit. This is the mechanism
under both simdjson's structural scan and the Keiser–Lemire UTF-8 validator.

### The actual difficulty

Per class bit, membership is "low nibble in set L *and* high nibble in set H" —
a **rectangle** in the 16×16 grid of byte values. Arbitrary byte sets must be
decomposed into rectangles spread across several bits. That decomposition is the
puzzle. The instructions are the easy part.

### Zig cannot express this portably — measured, not assumed

`@shuffle` requires a comptime mask → no portable runtime lookup. Four candidate
formulations, identical comptime table, all verified against a scalar reference
on 20,000 random inputs:

| Formulation | Instrs (SSSE3) | Instrs (AVX2) | Throughput | Relative |
|---|---|---|---|---|
| LLVM intrinsic via `extern` | 3 | 3 | **46.8 GB/s** | **1.0×** |
| inline asm `pshufb` | 3 | 3 | 40.7 GB/s | 1.15× |
| `@select` chain (portable) | 25 | 18 | 6.2 GB/s | 7.6× |
| scalar loop over an array | 37 | 36 | — | — |
| packed table + variable shift | 140 | 50 | — | — |

Best of 5 runs, 26 MB per run, XOR-accumulated to defeat dead-code elimination.
LLVM does *not* recognise the `@select` chain and rewrite it as a shuffle —
checked on aarch64 too, where it emits 33 instructions and no `tbl`. The "packed
table in a u64, variable-shift per lane" idea looks clever and is the worst
option: LLVM scalarises it.

### The formulation to use

Declaring an LLVM intrinsic as `extern` fully lowers with no external symbol, and
beats inline asm because it survives cross-compilation:

```zig
const V16 = @Vector(16, u8);
extern fn @"llvm.x86.ssse3.pshuf.b.128"(V16, V16) V16;
extern fn @"llvm.aarch64.neon.tbl1"(V16, V16) V16;

/// out[i] = tbl[idx[i] & 15]. One instruction on x86 SSSE3 and on aarch64.
pub inline fn lookup16(tbl: V16, idx: V16) V16 {
    const lo = idx & @as(V16, @splat(0x0F));
    if (comptime builtin.cpu.arch.isX86() and
        std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3))
        return @"llvm.x86.ssse3.pshuf.b.128"(tbl, lo);
    if (comptime builtin.cpu.arch == .aarch64)
        return @"llvm.aarch64.neon.tbl1"(tbl, lo);
    return selectFallback(tbl, lo);   // @select chain, ~18-33 instrs
}
```

Emits `pand; pshufb` on x86 and `movi; and; tbl` on aarch64. Verified exact
against a scalar reference on 50,000 random table/index pairs on both paths.

> **Two sharp edges**
>
> Hardware instructions **zero** a lane whose index has the high bit set, rather
> than wrapping. Masking with `0x0F` makes all backends agree — but simdjson
> deliberately *exploits* the zeroing, so do not blindly copy code depending on it.
>
> `extern fn` against an LLVM intrinsic is not a stable, documented Zig feature.
> Pin your compiler and keep the `@select` version as a correctness oracle in tests.

---

## Technique 02 — The bitmask as intermediate representation

Use SIMD to *build* a `u64`, then do the algorithm in bit manipulation. The
bitcast is not the last step that extracts an answer; it is the first step, where
data changes into a representation with operations vector units do not have —
shifts that move data across the whole block, `@popCount`, `@ctz`, carry
propagation.

simdjson processes **64 bytes per iteration** precisely so every mask fills a
general-purpose register.

```zig
fn maskEq(block: *const [64]u8, needle: u8) u64 {
    const V = @Vector(64, u8);
    const v: V = block.*;
    return @bitCast(v == @as(V, @splat(needle)));
}
```

No CPU has a 64-byte byte vector without AVX-512; LLVM legalises the oversized
vector by splitting across registers and combining the movemask results. Works,
but it is compiler behaviour rather than a language guarantee — check
`-femit-asm` once per target.

> **Convention — fix this or lose an hour**
>
> **Bit *i* ↔ byte *i*; lane 0 is the least significant bit.** That is what Zig's
> `@bitCast` produces and what makes `@ctz` return a lane index. Printed in byte
> order, byte 0 is on the *left*, but binary notation puts the low bit on the
> *right* — so on the page, `>>` moves data leftwards.

### Neighbour access

| Direction | Asks about | Mnemonic |
|---|---|---|
| `m >> 1` | the byte *after* each position | look ahead |
| `m << 1` | the byte *before* each position | look back |

| Expression | Bit *i* is set when |
|---|---|
| `a & (b >> 1)` | byte *i* in `a`, byte *i+1* in `b` — a two-byte pattern |
| `a & (b >> 1) & (c >> 2)` | a three-byte pattern starting at *i* |
| `m & (m >> 1)` | this byte and the next both matched (overlapping pairs included) |
| `m & ~(m << 1)` | *i* starts a run of matches |
| `m & ~(m >> 1)` | *i* ends a run of matches |

```
byte        a  b  /  /  c  d  /  e  f  /  /  /  g  h
m           0  0  1  1  0  0  1  0  0  1  1  1  0  0
m >> 1      0  1  1  0  0  1  0  0  1  1  1  0  0  0
m & (m>>1)  0  0  1  0  0  0  0  0  0  1  1  0  0  0
```

One instruction for all 64 positions. The lone slash at 6 correctly yields
nothing; the run of three at 9–11 yields two overlapping pairs.

### Consuming the mask

| Expression | Meaning |
|---|---|
| `@ctz(m)` | index of first match (guard `m == 0`) |
| `63 - @clz(m)` | index of last match |
| `@popCount(m)` | how many matched — free counting |
| `m & (m -% 1)` | clear the lowest set bit |
| `m & (~m +% 1)` | isolate the lowest set bit (`m & -m`) |
| `m == 0` | the fast path — take it early and often |

```zig
// visit every match, once per match rather than once per byte
while (m != 0) {
    const idx = base + @ctz(m);
    // ...
    m &= m -% 1;
}
```

### Block boundaries

A mask cannot see past its block, so a pattern straddling the seam is invisible
to both sides. Carry forward exactly the state the next iteration needs.

| You need | Carry |
|---|---|
| the previous byte | `@truncate(m >> 63)` — one bit |
| the previous *k* bytes | the top *k* bits, or the previous vector itself |
| "am I inside a string" | one bit of parity — see T5 |
| a partial UTF-8 sequence | the previous vector, for lane-wise shifts — see T3 |

Cover the final seam by starting the scalar tail one byte *before* the last full
block ends, rather than at the block edge.

---

## Technique 03 — Cross-lane dependencies

When a byte's validity depends on the 1–3 bytes before it — UTF-8 being the
canonical case — materialise the neighbours as whole shifted vectors, then
classify pairs lane-wise.

`std.simd.mergeShift(prev, cur, n)` is the `alignr` equivalent: shifts in real
bytes from the previous iteration rather than a filler value. Verified with
4-lane vectors `prev={1,2,3,4}`, `cur={5,6,7,8}`:

| Call | Result | Meaning |
|---|---|---|
| `mergeShift(prev, cur, 3)` | `{4,5,6,7}` | byte *i−1*, lane-aligned with `cur` |
| `mergeShift(prev, cur, 2)` | `{3,4,5,6}` | byte *i−2* |

```zig
var prev: V = @splat(0);
while (...) {
    const cur: V = load(...);
    const back1 = simd.mergeShift(prev, cur, lanes - 1);
    const back2 = simd.mergeShift(prev, cur, lanes - 2);
    err |= classify(cur, back1, back2);   // no branch, ever
    prev = cur;
}
if (@reduce(.Or, err) != 0) return error.Invalid;
```

The Keiser–Lemire UTF-8 validator needs only three nibble lookups — high nibble
of `back1`, low nibble of `back1`, high nibble of `cur` — ANDed together. A
nonzero byte anywhere is an error. Every malformed-sequence rule (overlongs,
surrogates, > U+10FFFF, continuation mismatches) lives in those three 16-byte
tables.

> **Error accumulation**
>
> Never branch per block to check for errors. `or` them into an accumulator and
> test once at the end. Keeps the hot loop free of data-dependent branches, worth
> more than the instructions it saves — the predictor sees constant behaviour
> regardless of input.

---

## Technique 04 — Saturating arithmetic as a threshold test

Zig has saturating operators natively on vectors — no intrinsic needed. `a -| b`
is zero everywhere `a <= b` and positive elsewhere: a comparison that leaves
useful magnitude behind instead of an all-ones mask. Verified on
`@Vector(4,u8)`:

| Op | `{10,200,30,250}` op `{20,100,5,50}` |
|---|---|
| `+%` wrapping | `{30, 44, 35, 44}` |
| `-%` wrapping | `{246, 100, 25, 200}` |
| `*%` wrapping | `{200, 32, 150, 212}` |
| `+\|` saturating | `{30, 255, 35, 255}` |
| `-\|` saturating | `{0, 100, 25, 200}` |
| `*\|` saturating | `{200, 255, 150, 255}` |

Applied to UTF-8 lead-byte detection — `lead -| 0xDF` on `{0x41, 0xC3, 0xE2,
0xF0}` gives `{0, 0, 3, 17}`: nonzero exactly where the byte is a 3-or-4-byte
lead. One instruction, no compare, no vector of thresholds.

---

## Technique 05 — Prefix problems: the carry chain as a scan

Hardest category. "Am I inside a string?" depends on the parity of every quote
before you — a sequential scan over the whole prefix, precisely what SIMD is
supposed to be bad at.

### Prefix XOR via carry-less multiply

`clmul(x, ~0)` computes, for every bit position, the XOR of all bits at or below
it. Sixty-four parity computations in one instruction. Verified against a scalar
reference on 100,000 random inputs:

```zig
extern fn @"llvm.x86.pclmulqdq"(@Vector(2,u64), @Vector(2,u64), i8) @Vector(2,u64);

fn prefixXor(x: u64) u64 {
    const v: @Vector(2,u64) = .{ x, 0 };
    const ones: @Vector(2,u64) = .{ ~@as(u64,0), 0 };
    return @"llvm.x86.pclmulqdq"(v, ones, 0)[0];
}
```

```
quotes      0 0 0 0 0 1 0 0 0 0 1 0 0 0
prefixXor   0 0 0 0 0 1 1 1 1 1 1 0 0 0
```

The second row is exactly "inside a string". Needs the `pclmul` feature — build
with `-mcpu=x86_64_v3+pclmul` or dispatch at runtime.

### Carry propagation via plain integer addition

First you must know which quotes are *escaped*, which needs the parity of each
backslash run. Adding a seed bit into a run of ones makes the carry ripple the
full length of the run and land one position past its end. The adder's carry
chain, used as a parallel prefix engine — ships on every CPU ever made.

```
run         0 1 1 1 0 0 0 0
seed        0 1 0 0 0 0 0 0
run + seed  0 0 0 0 1 0 0 0
```

```
B          = backslash mask
starts     = B & ~(B << 1)        // first backslash of each run
odd_starts = starts & ODD_BITS    // runs beginning at odd positions
carries    = B +% odd_starts      // ripples through the run
ends       = carries ^ B          // isolate run ends
```

Predates simdjson by nearly a decade — from Cameron et al.'s Parabix work on XML
parsing ("Parallel Scanning with Bitstream Addition"). Read that for the general
theory rather than the single instance.

*Lane-wise alternative:* `std.simd.prefixScan(.Xor, 1, v)` does prefix parity
across lanes portably. Right tool when state is per-lane; much slower than
`clmul` when it is per-bit.

---

## Technique 06 — Compaction: variable-length output

Removing whitespace, base64 decoding, UTF-8 → UTF-16 — the lanes you keep are
scattered and the output must be contiguous.

| Approach | How | Needs |
|---|---|---|
| shuffle-table left-packing | mask → index into precomputed table of shuffle vectors → one `pshufb` | any runtime shuffle |
| `pext` | bit-level extract within a `u64` (SWAR packing) | BMI2 |
| `vpcompressb` | one instruction, whole job | AVX-512-VBMI2 |

An 8-lane mask needs a 256-entry table; 16 lanes would need 65,536, so split into
halves and offset the second by `@popCount` of the first. Always write a full
vector and advance the output pointer by `@popCount(mask)` — the writes overlap,
which is fine.

simdutf's UTF-8 → UTF-16 kernel is this at full strength: compute the 12-bit
pattern of which bytes are leads, look up a shuffle that scatters variable-length
characters into fixed-width slots, then recombine payload bits with shifts and
multiply-add.

**Multiplication as a bit-shifter:** `maddubs`/`madd` multiply lanes by powers of
two and horizontally add pairs — a shift-and-combine across lane boundaries. Used
to reassemble 6-bit base64 groups and UTF-8 payload bits. No portable Zig
spelling; reach for the LLVM intrinsic.

---

## Technique 07 — Architecture-level techniques

| Technique | Why it matters |
|---|---|
| **Two-stage design** | Stage 1 is one branchless pass producing an array of *indices*. Stage 2 does branchy tree-building over that much smaller array. Separating "where are things" from "what are things" makes the branchy part affordable. |
| **Padded buffers** | Over-read and over-write into padding so the vector loop handles the whole input and the scalar tail disappears. Costs a defined allocation contract; buys a simpler loop. |
| **Runtime dispatch** | One kernel per ISA behind a shared abstraction, selected by CPU feature detection at startup. In Zig, `comptime` switches on `builtin.cpu.features` give build-time selection; true runtime dispatch needs function pointers and separately-compiled kernels. |
| **Branchlessness as the goal** | The point is not instruction count — it is that the predictor sees near-constant behaviour regardless of input. Why error accumulation beats early exit even when early exit does less work. |

---

## Technique 08 — Verification discipline

What separates people who do this from people who read about it. These
expressions are easy to get subtly and silently wrong, and "it looked right" is
not a check.

| Step | Concretely |
|---|---|
| 1. Scalar reference first | It is the oracle, the fallback, and the tail. Write it before the vector version. |
| 2. Differential-test on random data | Tens of thousands of cases. Include lengths that are not multiples of the block, and matches deliberately placed at block boundaries. |
| 3. Read the assembly | `zig build-obj -O ReleaseFast -femit-asm=out.s x.zig`. Confirm the instruction you expected appears and nothing spilled. |
| 4. Measure throughput | Not instruction count. They correlate, but not reliably — see the 3-vs-18 instruction gap producing a 7.6× throughput gap in T1. |
| 5. Keep the portable version | As a test oracle, even after you ship the intrinsic one. |

> **Getting a compiler**
>
> `pip install ziglang` ships official Zig binaries via PyPI — useful when
> ziglang.org is unreachable, since GitHub releases carry only bootstrap sources.
> Cross-check ARM with `-target aarch64-linux`. `std.time.Timer` was removed in
> 0.16; use `std.os.linux.clock_gettime`.
>
> (This project uses the flake at the repo root instead.)
