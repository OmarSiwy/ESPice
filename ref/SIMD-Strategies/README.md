# Advanced SIMD & The Complete Zig SIMD API

Techniques behind simdjson and simdutf, plus every Zig SIMD builtin and every
`std.simd` function.

Source material verified against **Zig 0.16.0**. This project pins
**0.17.0-dev.1884+841dd0eb8** — see `verify.zig` for a smoke test of the
highest-risk claims against the pinned compiler.

## Contents

| File | Covers |
|---|---|
| [01-techniques.md](01-techniques.md) | Techniques 1–8: classification, bitmask IR, cross-lane, saturating, prefix scans, compaction, architecture, verification |
| [02-zig-simd-api.md](02-zig-simd-api.md) | Every builtin + all 21 `std.simd` functions |
| [03-gotchas.md](03-gotchas.md) | Consolidated gotchas, limits, primary sources |
| [verify.zig](verify.zig) | Runnable check of the load-bearing claims |

## The diagnostic

Everyday SIMD works when two things hold: **lanes are independent**, and
**output has the same shape as input**. Every advanced technique exists to break
one of those. Identify which wall you hit; the rest follows.

| Symptom | Wall | Go to |
|---|---|---|
| Predicate is a messy set of byte values | neither — you need a primitive | T1 |
| A byte's meaning depends on its neighbours | lane independence | T2, T3, T4 |
| It depends on *everything* before it | lane independence, badly | T5 |
| Output length depends on the data | output shape | T6 |
| Works, but branch predictor thrashing | control flow | T7 |
