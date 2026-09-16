# Parallel query execution and previews

Parallelism belongs inside a serialized Problem call. Callers can select a
ready set; analysis owns the mutable state and starts independent workers.
`max_parallel` limits simultaneously advancing queries and defaults to one.

```zig
const required = try p.ready_queries(.all, ids);
// Supply enough IDs before using the returned set.
const count = try p.advance_ready(ids[0..required],
    .{ .max_parallel = 2 }, events);
```

`ready_queries(scope, ids)` returns the required capacity and makes no partial
copy when the buffer is too small. Scopes are `.all`, `.query = id` (the target
and its prerequisite), or `.component = component_id`. Query information
provides the component ID. The returned order is the scheduler's rotating
order, not completion order.

`advance_ready(ids, limits, events)` requires distinct IDs that are ready at
entry. It validates the complete selection and event-buffer capacity before
execution. It then processes the selection in batches of at most
`limits.max_parallel`, starting each batch before waiting for its checkpoints.
Each selected query advances once; newly ready dependents wait for a later call.
It returns one event per selected ID in the supplied order.

`advance(target)` automatically selects its ready prerequisite or itself.
`run_all()` repeatedly selects the bounded ready frontier. Applications do not
need thread claims, lock tokens, or an external scheduler. Serialize calls on
one Problem; do not inspect it concurrently with advancement or destruction.

## Connected and disconnected work

Consider AC and noise sharing a DC operating point, plus a `uic` transient:

```text
AC ───────┐
          ├── DCOP
noise ────┘

transient (uic)
```

Initially DCOP and the transient are ready. Once DCOP completes, AC and noise
can run together despite belonging to the same connected component. Different
components can also run together. A component groups dependencies; it is not
a lock or an assignment to a CPU/GPU device.

The two DC consumers clone accepted OP state. The transient owns different
state and starts from its resolved initial conditions. An interleaved parameter
sweep has its own parameters/history and cannot corrupt either consumer.
Implicit shared OP work runs once. Requesting that same OP explicitly exposes
the existing ID without rerunning it or delivering its result twice.

The graph currently has only OP dependency edges. Periodic preparation remains
inside its query; this example does not imply cross-query sharing of PSS data.

## CPU/GPU lanes and resource limits

Query concurrency coexists with frequency SIMD lanes, independent sweep lanes,
and parallel device evaluation. Frequency batches retain their lane shape;
transient timesteps, Newton iterations, and coupled harmonics stay sequential
within their algorithm. A GPU batch can be one indivisible advancement unit.

All queries in a Problem use its selected backend policy. Each executor owns
its GPU context when applicable. Eligible operations use existing GPU hooks
with CPU fallbacks; query concurrency does not imply that disconnected
components occupy separate GPUs or that the whole analysis runs on-device.

Paused queries retain numerical storage and a worker stack. Thus
`max_parallel=1` bounds active work, but does not bound the total memory of all
queries already started. The initial implementation favors preserved execution
state over explicit per-phase state machines. See
[migration notes](migration-notes.md) for the stack reservation and fallback.

Numerical results are keyed by query ID. File delivery follows requested order,
so a fast later query can finish before its result is written. Independent
completion order does not reorder plots or consume another query's random
stream. Bitwise equivalence across different CPU/GPU backends is not promised.

## `Problem.print()`

```zig
try p.print(writer, .{
    .scope = .all,
    .preview = .{ .advance = ac_id },
    .ascii = true,
});
```

The printer displays components and requested queries as a tree, with their
prerequisites beneath them. Repeated appearances use a shared-query reference
rather than duplicating work. Rows show query ID, technique, state, latest
phase/counters, failure where present, and `NEXT` for selected work. Waiting
queries name their unfinished prerequisite; ready queries outside the selection
are marked `deferred by selection`. The heading includes the component count.

For the three requests above, an ASCII `run_all` preview with two workers is:

```text
Problem: 3 requested queries, 4 total queries, 2 components
|-- Component 0
|   |-- q1 ac [pending; waiting for q0]
|   |   `-- q0 op [ready; NEXT]
|   `-- q2 noise [pending; waiting for q0]
|       `-- -> q0 op [ready; shared; NEXT]
`-- Component 3
    `-- q3 tran [ready; NEXT]
```

Preview modes describe one call:

| Preview | Meaning of `NEXT` |
|---|---|
| `.advance = id` | The single ready query that `advance(id)` would choose |
| `.advance_ready = ids` | Every selected query in that batch call, even if concurrency divides it into several batches |
| `.run_all` | The first ready frontier, bounded by the supplied concurrency limit |

`PrintOptions.limits` defaults to null, so `Problem.print()` uses the Problem's
configured concurrency. Its default `run_all` preview therefore marks the same
initial frontier that execution selects. An explicit limit previews an override.
The preview shows that initial decision, not future convergence or completion
order. Invalid ready selections fail preview using the execution checks.

Printing performs no numerical work, creates no executor, and leaves statuses,
results, and the scheduling cursor unchanged. The CLI exposes this as `--plan`
(print only) and `--print-dag` (print, then run).
