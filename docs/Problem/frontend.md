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

## Repeating the measurements

```sh
zig build bench-frontend -- tests/fixtures/stress/scaling_rc_ladder_100k.sp 11
zig build bench-frontend -- tests/fixtures/stress/scaling_inverter_chain_4k.sp 11
zig build test-frontend -Doptimize=Debug
zig run ref/SIMD-Strategies/verify.zig -fllvm -OReleaseSafe -mcpu=native
```

The frontend benchmark times parsing plus semantic expansion, excluding file
loading, device binding and simulation. Each iteration owns a fresh arena;
results report median time, arena capacity and a device-count checksum.

A before/after run used `zig build ... bench` with the same standalone harness,
LLVM ReleaseFast, x86_64_v3 and 11 iterations on `scaling_rc_ladder_100k.sp`:
42.848ms before, 45.443ms after; both reserved 143,648,772 arena bytes and
produced checksum 2,400,012. The baseline was a snapshot of the working frontend
before this refactor, not clean HEAD. Other compilations were active, and
repeated runs varied substantially. These results do **not** establish a
frontend throughput improvement. The retained changes establish the AST/build
boundary and reduce repeated copying and scans; future performance claims need
an isolated before/after run.

Validation of this working tree: `zig build` passes; the frontend differential
suite passes in Debug and ReleaseFast, and the standalone SIMD verification
passes. A temporary structural comparison against the saved frontend snapshot
found identical device, model and directive values on all 612 fixture decks,
ignoring internal subcircuit IDs. The full numerical fixture gate reports
416 passes and 196 failures; the structural comparison does not prove that
all numerical failures predate the change. The combined unit run passes
321/323 tests: two Problem allocation-failure tests fail, including a compiled
device callback that reports `PermissionDenied` where `OutOfMemory` is expected.

An OP/transient/AC CLI smoke test with `--jobs=2` produced byte-identical CSV
plots with timing enabled and disabled. The timing test also checks that
cancelling a paused worker does not charge paused time to active execution.
