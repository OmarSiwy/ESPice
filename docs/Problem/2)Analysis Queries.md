# Analysis queries

A query is a resolved `requests.Query` plus execution state, identified by a
stable `QueryId`. The description contains numerical options and circuit
indices. Mutable numerical state belongs to an analysis executor.

The public entry points are:

```zig
const event = try p.advance(query_id);
try p.run_all();
const info = try p.query_info(query_id);
const result = try p.result(query_id);
```

`advance(target)` advances a ready unfinished prerequisite, or the target
itself, until the next supported checkpoint or terminal outcome. Its event
names both `requested` and `advanced`, and reports `status`, `target_status`,
latest progress, numerical failure, and output failure separately. It does not
advance an unrelated query. Advancing a terminal query does not run it again.

`run_all()` repeatedly advances ready work through the same path. It resumes
paused work, lets independent branches finish after a numerical failure, and
returns failure when requested work failed. Successful results remain available.
Neither operation promises a wall-clock deadline: a factorization, batch solve,
or unsupported internal phase can be indivisible.

## Prerequisites

The implemented graph adds shared **operating-point** prerequisites. Each
query has zero or one dependency. An explicit OP and a transient with `uic`
have none. Other queries use an OP with matching tolerances and either DCOP or
TRANOP flavor. Compatible OP requests share one node; implicit nodes remain
visible through query inspection.

The scheduler passes the accepted OP's full circuit/device state and solution
into a private clone for each consumer. Probe samples alone are insufficient.
DCOP and TRANOP are distinct because waveform sources and device initialization
can differ. A failed prerequisite gives its consumers `dependency_failed`.

PSS, PAC, PXF and periodic noise still prepare their periodic state inside their
own query. The graph does not expose a shared periodic-orbit node. Fourier
analysis likewise obtains its transient window internally; it does not depend
on an arbitrary separate `.tran` query. Explicit caller-supplied dependency
edges and arbitrary DAG edits are not part of this API.

## Checkpoints and results

The executor retains the analysis stack on a worker thread across calls. Local
iterators, random-stream position, continuation state, integrator history and
cleanup scopes therefore survive suspension. Non-OP queries suppress nested
Newton progress in favor of the surrounding analysis boundary.

| Technique | Implemented checkpoint boundary |
|---|---|
| OP | Nonlinear progress checkpoints |
| DC sweep | Between solved sweep points |
| AC and small-signal noise | Frequency batches; noise also checkpoints its postprocessing |
| SP, PAC, PXF, periodic noise, distortion | Frequency-point boundaries, with preparation phases where implemented |
| Transient, transient noise, envelope, matrix exponential | Between timestep/outer-step attempts |
| PSS and periodic-noise shooting | Between outer corrections; nested integration may also report progress |
| HB and QPSS | Between coupled nonlinear iterations |
| Monte Carlo and other lane sweeps | CPU lane boundaries; a GPU batch can complete as one unit |
| Temperature, sensitivity, mismatch | Between points or parameter contributions |
| Transfer, eigenvalue and finite postprocessing | Whole computation or checkpoints reached by their underlying work |

The shared AC batch path uses up to 64 frequencies per checkpoint, preserving
SIMD/GPU batches. A progress event contains a phase and counters;
`total == 0` means unknown. Nested phases can restart counters. Progress is not
a convergence percentage or proof that a sample was accepted.

Only **complete queries** publish `Result` data through this API. Accepted
samples remain private while a query is paused; there is no partial-result
copy or output chunk API. A rejected transient attempt can therefore report
progress without a result. Unconverged iterates never become valid OP products.
The existing low-level transient recorder remains separate from Problem delivery.

## State and errors

The stored states are `pending`, `paused`, `complete`, `failed`,
`dependency_failed`, and `cancelled`. Readiness is derived from state and
dependency completion; it is not another stored state. Query inspection exposes
the kind, dependency, component, requested/implicit role, latest progress and
persistent numerical error.

Invalid IDs, malformed ready sets and buffer-size errors fail the API call.
Execution failures are recorded on the affected query. An output error is
reported separately and leaves a complete numerical result readable. There is
no public retry/reset operation for terminal failures; construct another query
or Problem as appropriate.

Each started query owns a mutable circuit clone and separate working/result
allocations. Another sweep or transient cannot overwrite its parameters or
history while it is paused. The current worker requests a 512 MiB stack;
paused workers retain that virtual-address reservation until completion or
destruction. This is a deliberate first implementation, documented in
[migration notes](migration-notes.md).

## Appending and reading

`append_queries(queries, ids)` accepts typed Zig requests.
`append_directives(text, ids)` accepts SPICE analysis cards resolved against
existing bindings. Append between execution calls. Validation and copied
request storage are committed together; an invalid extension leaves existing
work intact. Output choice and deck settings remain fixed.

The ID buffer contains IDs for requested queries, including both plots produced
by a swept `.noise` directive. `query_count()` includes implicit prerequisites.
Sizing an ID buffer does not append work. Completed dependency products stay
available to later compatible queries.

`result(id)` returns a borrowed complete result valid until `deinit()`.
`copy_result(id, buffer)` returns its required scalar count and copies only
when the buffer is large enough. The C ABI also exposes result dimensions and
column-name copying. Neither append nor subsequent advancement invalidates a
completed result.

Implementation: [session](../../src/analysis/session.zig),
[executor](../../src/analysis/executor.zig),
[checkpoint controller](../../src/analysis/query_runtime.zig), and
[request validation](../../src/analysis/request_validation.zig).
