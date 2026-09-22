# Frontend boundaries and measurements

The frontend transforms source bytes into an unresolved AST, then builds a
passive `Prepared` circuit. Parsing preserves card order, subcircuit calls and
expressions. Construction resolves parameter scopes, expands instances,
selects model bins, binds compiled devices and builds circuit connectivity.
The same AST can be built repeatedly without scaling or rewriting its values.

| File | Responsibility |
|---|---|
| `tokenizer.zig` | Dialect line rules, tokens and numeric suffixes |
| `parser.zig` | Tokens to declarations and expression ASTs |
| `types.zig` | AST, expressions and construction scratch columns |
| `elaborate.zig` | Parameter resolution, subcircuit expansion and model bins |
| `builder.zig` | Device binding, node identities and circuit topology |
| `prepare.zig` | Source/model preparation, Prepared construction and query binding |
| `source.zig` | File reads, relative includes and library sections |
| `models.zig` | Comptime device catalog and fixed dispatch maps |
| `model_loader.zig` | Runtime HDL compilation, registration and library ABI |
| `syntax.zig` | Dependency-free syntax module exports for construction and benchmarks |
| `root.zig` | Public frontend exports and test registration |

`prepare.zig` combines the former input/prepared orchestration files. File I/O
remains separate from dialect tokenization, and runtime HDL loading remains
separate from comptime device selection. The syntax module boundary lets tests
and benchmarks parse decks without linking numerical device implementations.

All frontend tests live in `src/frontend/tests/`: syntax, builder, prepared
circuits, and models. `root.zig` registers each suite. Private helper access is
available only in test builds. `test-frontend`, `test-builder`, `test-devices`
and `test-prepared` preserve their existing build entry points.

## Layout and SIMD

AST declarations use source-order arrays; expansion consumes each declaration's
fields together. Subcircuit lookup stores checked `u16` indices. Expanded
instance IDs and builder device indices are checked `u32` values. Device
construction uses the existing letter-bucketed SoA columns. Parse scratch dies
when preparation completes; published metadata belongs to the session arena.
GPU device layouts and scatter tapes are unchanged.

The parser reuses node/argument/parameter buffers and copies completed card
slices into arena slabs. Literal expression parsing returns values directly;
only expression edges allocate nodes. Semantic expansion copies values when
substitution or geometry scaling requires it.

ASCII normalization and newline counting share one streaming vector pass.
The newline predicate becomes a bit mask followed by `@popCount`; this avoids
the incorrect line counts observed with vector boolean-to-integer reduction
in the Debug backend. Width 1 is the scalar oracle and tail. Differential
cases cover widths 1, 16, 32 and 64, every input length through 257 bytes, and
random non-ASCII bytes. The standalone SIMD reference mirrors the kernel;
the frontend test checks the production implementation. LLVM assembly contains
`vpcmpeqb`, `vpmovmskb` and `popcnt` in the production normalization function.

The per-word SIMD experiment was retired. It classified 16 bytes anew for each
short token, then used a width-1 tail. Cachegrind on a 20,005-device RC prefix
reported 86,436,501 instructions versus 81,433,895 with the retained scalar
word scan (6.1% more), with identical 533,666 L1 data misses. These figures
include one warmup and one measured parse/expansion. Both binaries used LLVM
ReleaseFast and x86_64_v3, with simulated caches I1/D1=32KiB, 8-way, 64-byte
lines and LL=8MiB, 16-way. Standard-library vector scans for physical newlines
and quoted spans remain. Reconsider token SIMD only with measured gains across
short-token and long-token decks; mask caching adds state that this result
does not justify.

## Controlled-source preparation — 2026-09-16

`op/controlled_source_scaling.sp` contains 2,048 independent
voltage-source/resistor/CCCS/load groups, with permuted control references and
an analytic voltage/current oracle. It stresses preparation; it does not
represent a long nonlinear transient simulation.

The former implementation scanned every F/H/W reference for every voltage
source, then scanned every voltage-source name again for each control binding.
Control names now form one sorted slice of borrowed strings, queried with
case-insensitive binary search. Deferred binding builds one exact-name map of
the actual native voltage-source rows. Its `u32` values preserve the first
duplicate name and exclude dynamically loaded cards skipped during native
source construction. Both indexes die with parse scratch; published source
columns and device/GPU layouts are unchanged. Missing and unknown controls
retain their existing errors, and case-insensitive sensing remains distinct
from exact-name binding.

The ReleaseFast end-to-end benchmark measured a median of nine runs after
one warm-up. Times include process startup, preparation, the operating-point
solve, and output; reference conversion is outside the timed interval.

| ESPice before | ESPice after | End-to-end reduction | Reference comparison |
|---:|---:|---:|---|
| 36.761 ms | 22.541 ms | 38.68% | Both runs agree with ngspice and VACASK |

This reduction applies to this fixture and the combined preparation changes.
The after executable also includes the sparse-pattern radix optimization;
these measurements do not isolate name-lookup throughput or establish a
device-evaluation speedup or a 99% evaluation / 1% preparation split.

Exact commands, run against the respective before and after working tree states:

```sh
zig build bench -- --filter op/controlled_source_scaling.sp --iters 9 --timeout 30 \
  --ngspice /nix/store/zks09ghph193x3imsww3s8vnpr09nav8-ngspice-45/bin/ngspice \
  --vacask /nix/store/cjp1w6v1g1s0ih1g13ip8pnkhyygjnl9-vacask-unstable-2026/bin/vacask \
  --out /tmp/espice-src-cleanup/bench-before.md
zig build bench -- --filter op/controlled_source_scaling.sp --iters 9 --timeout 30 \
  --ngspice /nix/store/zks09ghph193x3imsww3s8vnpr09nav8-ngspice-45/bin/ngspice \
  --vacask /nix/store/cjp1w6v1g1s0ih1g13ip8pnkhyygjnl9-vacask-unstable-2026/bin/vacask \
  --out /tmp/espice-src-cleanup/bench-after.md
```

The local reports identify the before executable as
`.zig-cache/o/e4abfd366363552628590b32af8c7a32/espice` and the after executable
as `.zig-cache/o/d079a8673824e0684f6bd976281d2e5f/espice`.

## Historical AST/build refactor measurements

The measurements and checks below describe the earlier AST/build refactor,
not the controlled-source preparation changes above. That refactor used the
following frontend-specific benchmark commands:

```sh
zig build bench-frontend -- tests/fixtures/stress/scaling_rc_ladder_100k.sp 11
zig build bench-frontend -- tests/fixtures/stress/scaling_inverter_chain_4k.sp 11
zig build test-frontend -Doptimize=Debug
zig run ref/SIMD-Strategies/verify.zig -fllvm -OReleaseSafe -mcpu=native
```

The frontend benchmark timed parsing plus semantic expansion, excluding file
loading, device binding and simulation. Each iteration owned a fresh arena;
results reported median time, arena capacity and a device-count checksum.

A before/after run used `zig build ... bench` with the same standalone harness,
LLVM ReleaseFast, x86_64_v3 and 11 iterations on `scaling_rc_ladder_100k.sp`:
42.848ms before, 45.443ms after; both reserved 143,648,772 arena bytes and
produced checksum 2,400,012. The baseline was a snapshot of the working frontend
before that refactor, not clean HEAD. Other compilations were active, and
repeated runs varied substantially. These results do **not** establish a
frontend throughput improvement. The retained changes establish the AST/build
boundary and reduce repeated copying and scans; future performance claims need
an isolated before/after run.

Validation recorded for that earlier working tree: `zig build` passed; the
frontend differential suite passed in Debug and ReleaseFast, and the standalone
SIMD verification passed. A temporary structural comparison against the saved frontend snapshot
found identical device, model and directive values on all 612 fixture decks,
ignoring internal subcircuit IDs. The full numerical fixture gate reported
416 passes and 196 failures; the structural comparison does not prove that
all numerical failures predate the change. The combined unit run passed
321/323 tests: two Problem allocation-failure tests failed, including a compiled
device callback that reports `PermissionDenied` where `OutOfMemory` is expected.

An OP/transient/AC CLI smoke test with `--jobs=2` produced byte-identical CSV
plots with timing enabled and disabled. The timing test also checks that
cancelling a paused worker does not charge paused time to active execution.
