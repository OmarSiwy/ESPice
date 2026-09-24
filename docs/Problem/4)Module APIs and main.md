# Module APIs and main

Four feature modules sit between two shared ones. The `espice` facade
coordinates them; `core` and `device` keep it out of consumer imports.

| Module | Input → output | Owned responsibility |
|---|---|---|
| `frontend` | Source → `Prepared = {circuit, deck}` | Includes, dialect parsing, SPICE letter/LEVEL policy, instance construction, directive/name resolution |
| `espice` | Creation options and API calls → query events/results | Session lifetime, the device `Library`, fixed backend/output choice; `c_api.zig` adapts it to C |
| `analysis` | Circuit, deck and resolved queries → progress/completed results | Graph scheduling, mutable circuit clones, algorithms, solver use and GPU execution |
| `output` | Result plus deck title and a fixed selection → encoded files | Validation, ordered publication, one atomic write, numbered paths |

`core` holds the shared data (ids, numerics, queries, `Deck`, `Result`).
`device` holds the device ABI, the evaluator in `src/device/eval.zig`, HDL
loading, the frozen `Circuit` and the `Library`. Model sources are in
`models/`. Solvers live in `src/solver/`; build.zig wires them into analysis
only, so frontend, espice, output and main cannot import them.

Inside a module, leaves import other leaves or shared types, never its
aggregation `root.zig`. Analysis does not import frontend; output does not
import analysis.

## Construction seam

These are the implemented frontend signatures, abbreviated only by omitting
module qualifiers on common types:

```text
prepare(io, arena, Source, Dialect) !PreparedInput
build(session_arena, parse_arena, Ast) !Prepared
resolveQueries(arena, *const Prepared, directive_text) ![]const Query
```

`prepare` owns source loading and model preparation. `PreparedInput` holds
expanded source, origin, and an unresolved AST in the supplied arena.
`build` performs no I/O: it resolves those tables into a passive circuit
and analysis requests. `resolveQueries` reuses retained name bindings without
rebuilding the circuit; it rejects topology, model, include, parameter, and
deck-setting cards.

`Problem.init(allocator, io, Options) !*Problem` pins the owning object. It
prepares source in scratch storage, retains source/origin and Prepared in its
session arena, initializes analysis/output sessions, validates requests and
output schemas, then publishes the pointer. Partial failure releases owned
resources. `Prepared.deinit()` closes its circuit resources; its metadata
arena remains the caller's responsibility.

## Execution seam

[Problem methods](../../src/espice.zig) expose:

```text
title() []const u8
device_count() u32
output_error() ?anyerror
query_count() u32
query_info(id) !QueryInfo
ready_queries(scope, ids) !usize
append_queries(queries, ids) !usize
append_directives(text, ids) !usize
advance(id) !Advance
advance_ready(ids, limits, events) !usize
run_all() !void
print(writer, options) !void
result(id) !Result
copy_result(id, values) !usize
deinit() void
```

Append and ready-list calls use caller buffers and return required capacity
without partial copying. Append sizing does not mutate the graph. Batch
advancement instead requires sufficient event capacity before starting work.
The C adapter translates these rules into status codes and explicit required
sizes; it does not implement another scheduler.

Analysis validates and copies each graph extension before publishing IDs.
Only when work starts does its executor instantiate a mutable numerical
Circuit, bind private parameter pointers, create working/result arenas, and
start its retained worker. A dependent executor clones the accepted OP's
complete state. Pure readiness and preview operations never create executors.

Caller allocators may be ordinary serialized allocators: the analysis session
coordinates allocator access used by its internal workers. This does not allow
concurrent external calls on one Problem. See
[parallel execution](<3)Parallel Query Execution.md>) for call serialization.

## Result and output seam

`core.Schema` describes names, real/complex layout, and optional point count
before data exists. `analysis.schemaOf` gives a query's column count before it
runs, and `output.validateQuery` refuses a format that cannot hold it. `Plot`
is `{title, result}`: the deck title over a `core.Result`. Every format is an
encoder onto a `std.Io.Writer`; `output.write` validates, encodes and replaces
the file atomically.

`output.Session.init(allocator, selection)` copies its destination.
`publish(io, ordinal, plot)` validates and writes one whole committed plot.
Ordinals are consecutive delivery numbers, separate from query IDs. An already
acknowledged ordinal is a no-op; a gap is an error. Binary raw appends plots;
other encodings receive numbered paths after the first plot.

`finish()` checks delivery state. Every current publication has already flushed
and closed its writer, so finish neither closes the Problem nor prevents later
append-and-run calls. `deinit()` releases the owned destination. Low-level
writers, including `output.Stream`, remain available independently.

A writer failure marks the output session failed to avoid replaying a possibly
partial append. Problem retains the original delivery error and numerical
results, stops further file delivery, and reports that failure separately from
query convergence. There is no automatic output retry or destination change.
The caller can retrieve retained results and use a direct writer for recovery.

Problem destruction first cancels/joins analysis workers, then releases output,
prepared circuit resources, and session storage. A destructor does not report
successful delivery or replace explicit execution/output error handling.

## Main and the C adapter

[main.zig](../../src/main.zig) owns arguments, input-file iteration, diagnostic
presentation, summaries, and exit status. Its execution flow is:

```text
parse CLI options
for each input:
    Problem.init(allocator, io, options)
    optionally Problem.print(...)
    unless --plan: Problem.run_all()
    present results or errors
    Problem.deinit()
```

Main reads summary metadata and diagnostics through `title()`, `device_count()`,
`output_error()`, and `query_info()`. It does not reach into prepared circuit or
analysis-session fields. Default `print()` uses the Problem's configured limits.

`--jobs=N` sets query concurrency. `--backend=cpu|auto|cuda|hip`, `--gpu`,
`--format`, `--rawfile`, and `--tokenizer` become creation options.
`ESPICE_THREADS` and `ESPICE_SOLVER_THREADS` supply device/solver concurrency
policy; main translates them without importing solver types.

`--plan` still loads and validates the source/models, but performs no numerical
query work or output writing. `--print-dag` prints the initial frontier and then
runs. A named CUDA/HIP request without matching compiled artifacts fails at
creation; other GPU machine errors surface when its executor initializes.

The C library owns an opaque handle around the same Problem plus its I/O
context. [espice.h](../../include/espice.h) defines its version, tags, buffer
rules and operations. It copies results and diagnostics into caller buffers
rather than exposing Zig structures, solver workspaces, or borrowed pointers.
Its I/O setup preserves the host process's signal handlers; query workers still
use native threads. HDL preparation uses caller I/O concurrency when available
and synchronous execution otherwise.

Regression coverage lives in [Problem tests](../../src/tests/espice.zig),
[numerical compatibility tests](../../src/tests/analyses.zig),
[C ABI tests](../../src/tests/c_api.zig),
[numerical helper tests](../../src/core/tests.zig),
[frontend preparation tests](../../src/frontend/tests/prepared.zig), and
[output session tests](../../src/output/session.zig). These check state/ownership
contracts; analysis fixtures remain the evidence for numerical capability.

`zig build test-problem` runs all four Problem test files, including the C tests
compiled against `include/espice.h` and linked to the public library. `zig build
test` includes this gate alongside the numerical fixtures. The tests exercise
buffer ownership, transactional append failures, scheduling, output order,
failure isolation, and analytical circuit results.

## Optional timing

```sh
zig-out/bin/espice --timing-in-depth circuit.sp
```

Timing goes to stderr. Preparation reports source/parsing/HDL time, circuit
construction, and query/output setup separately. Each query reports setup,
wall time between numerical checkpoints, and active total. Transient rows
include attempt and accepted counts, reached simulation time, the attempted
`dt`, and `next_dt`; `next_dt=0` marks completion. The final attempt is included.
Output delivery and the complete run have separate timers.

Worker totals exclude cooperative scheduler pauses and timing-print overhead.
They are wall times, not CPU times; simultaneous query totals can overlap.
The first checkpoint interval includes numerical initialization, and the final
interval includes result construction. Timing output itself adds overhead, so
use this flag to locate expensive work and disable it for throughput benchmarks.
`--plan --timing-in-depth` reports preparation only. With the flag absent,
no timing clocks or timing output are used.
