# Gotchas & limits — consolidated

| # | Gotcha | Consequence |
|---|---|---|
| 1 | `@shuffle` mask must be comptime | No portable runtime table lookup. Use the `extern` LLVM intrinsic. |
| 2 | Vectors cannot be indexed at a runtime index | Coerce to an array first: `const a: [16]u8 = v;` |
| 3 | `shiftElementsRight` vs mask `>>` | Opposite directions. The most common bug in this material. |
| 4 | Per-lane variable shifts often scalarise | Check `-femit-asm` before relying on them. |
| 5 | `@Vector(64, u8)` exceeds hardware width | LLVM legalises by splitting — works, but verify per target. |
| 6 | `pshufb`/`tbl` zero on high-bit-set index | Mask with `0x0F` for portability; simdjson exploits the zeroing. |
| 7 | `prefixScanWithFunc`'s third arg is a type | Pass `void`, not `0`. |
| 8 | `std.time.Timer` removed in 0.16 | Use `std.os.linux.clock_gettime` for benchmarks. |
| 9 | `extern fn` on LLVM intrinsics is undocumented | Worked in 0.16.0; pin your compiler and keep a portable oracle. |
| 10 | `@splat` needs an inferrable result type | `@as(V, @splat(x))` when context is ambiguous. |

## Primary sources

| Source | Read it for |
|---|---|
| [Langdale & Lemire, "Parsing Gigabytes of JSON per Second"](https://arxiv.org/abs/1902.08318) | The simdjson paper. §3.1 is the densest concentration of technique in the field: two-stage architecture, structural scan, escaped-quote and inside-string derivations. |
| [Keiser & Lemire, "Validating UTF-8 In Less Than One Instruction Per Byte"](https://arxiv.org/abs/2010.03090) | Vectorised classification and cross-lane dependency handling, worked end to end. |
| Cameron et al., "Parallel Scanning with Bitstream Addition" (Parabix) | The *origin* of carry-propagation-as-parallel-scan, years before simdjson. General theory rather than one instance. |
| [Muła & Lemire, "Base64 encoding and decoding at almost the speed of a memory copy"](https://arxiv.org/abs/1910.05109) | Compaction, expansion, lookup-table construction for byte translation. |
| [`lib/std/simd.zig`](https://raw.githubusercontent.com/ziglang/zig/0.15.1/lib/std/simd.zig) | ~483 lines, unambiguous. Read the source, not summaries — including this one. |
| [branchfree.org](https://branchfree.org) · [0x80.pl](http://0x80.pl/) | Langdale's long-form posts on individual tricks; Muła's catalogue of SIMD algorithms with code. |

Local copy of the LLVM source is in `ref/LLVM` — intrinsic definitions live in
`llvm/include/llvm/IR/IntrinsicsX86.td` and `IntrinsicsAArch64.td`.
