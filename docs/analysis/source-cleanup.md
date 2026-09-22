# Source cleanup (2026-09-16)

The public analysis root exposes query sessions, execution configuration and
validation. Unused re-exports of Circuit, solvers' consumers, device contracts
and direct analysis entry points are removed. Internal callers import the
owning leaf or `types.zig`; external callers execute queries through Problem.
The frontend root exposes preparation and query binding. Parser, builder and
model callers use their existing modules directly. CLI dialect parsing is
available through Problem, so the executable no longer imports frontend.

Executor dispatch is one exhaustive `requests.Kind` switch. It retains the
compile-time checks on every analysis module's Options and run signature.
The unused AnalysisId, Analysis and Job aliases and Executor.advance wrapper
are removed; the coordinator continues to call start and wait separately.

`worker.zig` owns the existing cooperative controller. Executor still embeds
it in the same pinned allocation. The eight worker tests import this leaf,
without pulling in circuit construction or numerical dispatch. Cancellation,
progress, timing and thread-stack policy are unchanged.

Prepared.n_directives had no readers and is removed. Sensitivity solve returns
its allocated entries directly: its discarded operating-point value and
single-slice result wrapper are removed. The caller still releases the entries
through the scratch allocator after building the retained result.

This pass changes no numerical kernels, SIMD lane axes, device ABI or GPU
layout. It makes no throughput claim. The standalone LU measurement harness,
runtime exportDevice entry point and host capability declarations remain:
they have documented or generated-code callers.

Standards and task-scope reviews checked the cleanup against snapshots taken
immediately before the edits, preserving unrelated work in the shared tree.

## Verification

- Default build passed all 333 steps, including the executable, C library and
  device kernels.
- Focused preparation, parser, output and solver suites passed 222 tests.
  The isolated worker suite passed its eight behavior tests.
- CLI smoke checks accepted the `ng` dialect alias and rejected an invalid
  dialect. Formatting and diff whitespace checks passed.
- The initial full run passed 293 unit tests; its fixture runner reported
  426 passes and 189 failures out of 615 fixtures.
- The subsequent `zig build test` was blocked by a concurrent VerA dependency
  change: `UnsupportedParameterDefault` for `DDLTSLP` in
  `models/hisimhv_va.va:1140`. This pass does not modify that model or VerA.
  Fixture verification therefore uses a saved copy of the successful build.
- That executable also produced 426 passes and 189 failures. Failed fixture
  names and failure categories exactly match the initial run. The suite is
  still red, including unsupported sweeps, numerical mismatches and a MATEX
  abort; this cleanup does not resolve those failures.

These runs are observations of a shared, changing workspace, not an isolated
before/after performance or regression baseline.
