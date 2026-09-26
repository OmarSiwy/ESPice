# Migration notes

Deliberate limitations of the Problem design, the paths it retired, and what
replaces each one. Module boundaries are in
[Module APIs and main](<4)Module APIs and main.md>); the device boundary is in
[devices/abi.md](../devices/abi.md).

## Source layout

`src/espice.zig` owns orchestration and `src/c_api.zig` adapts it to C. The
prepared data is two values: the frozen `Circuit` (`src/device/Circuit.zig`)
and the deck (`src/core/deck.zig`). Queries (`src/core/query.zig`) and
numerics (`src/core/numerics.zig`) are shared through `core`. Model sources
are in `models/`, HDL loading in `src/device/loader.zig`, device evaluation in
`src/device/eval.zig`, GPU policy in `src/analysis/gpu.zig`, and solvers in
`src/solver/`. Facade tests live in `src/tests/` (lifecycle, analysis
regressions, C ABI).

S-parameter delivery accepts both the analysis producer's `v(S_m_n)` labels
and the `S(m,n)` labels direct writer callers use. One parser
(`output.types.sParameter`) gives port identities to validation and to CITI
serialization; raw result names are unchanged. Problem validates the
requested output once, before it commits an append.

## Prepared circuit and request contracts

1. Construction turns resolved device prototypes into frozen CSC and tapes,
   device templates, labels and query requests. Analysis creates its mutable
   execution state from that.
2. A circuit has many unknowns, nonzeros and instances; a session has many
   requests. No per-instance objects exist.
3. Circuit and tape indices are `u32`, numerical planes `f64`. Query ids are
   distinct `u32` values with `maxInt(u32)` reserved as invalid; allocation
   and count arithmetic is checked.
4. CSC and batch storage are separate from labels and request metadata.
   Numerical loops stream their own arrays.
5. Prepared data and retained source live for the session. Each query owns
   its mutable device state, numerical planes and scratch. Templates outlive
   every instantiated query. Construction scratch dies after preparation.
6. Independent queries share immutable topology and keep separate mutable
   state.

## Query scheduler storage

1. Resolved requests and completed prerequisites become progress events,
   terminal results and a read-only DAG projection.
2. A session holds up to `maxInt(u32) - 1` queries. Each analysis has zero or
   one shared OP prerequisite. Requested outputs are a separate ordered id
   list.
3. Query and component ids are `u32`; status, kind and phase are byte enums;
   concurrency is `u16`. Progress counters are `u64` across nested attempts.
4. Graph columns are a `MultiArrayList`, so status and readiness scans skip
   the request payloads. Worker handles and errors are cold columns. Ids
   survive appends.
5. Prepared data and completed products live for the session. Each accepted
   append owns an arena; a rejected candidate frees its arena and publishes
   nothing. Each worker owns its numerical state and output arena until the
   session ends.
6. The coordinator validates a frontier before starting workers, then starts
   every worker of a bounded batch before waiting. Queries share only the
   immutable topology and completed prerequisite snapshots.

## Resumption and the memory ceiling

A started query keeps its stack on its worker thread
(`src/analysis/worker.zig`), which requests 512 MiB, the size the old
whole-simulation worker used for stack headroom. This is a virtual-address
reservation, not 512 MiB of committed memory. Paused queries keep their stack
and numerical allocations; terminal workers join, and completed results and
dependency state stay session-owned.

`max_parallel = 1` (the default) and explicit query selection bound active
work, not the total retained state. If retained stacks become the capacity
limit, replace them with explicit per-phase state or a measured smaller stack.
Do not silently restart queries on every call. No performance claim is made
for this design.

An OP whose GPU run fell back to the host fails publication with
`error.GpuStateUnavailable` (`syncHostState` in `src/analysis/gpu.zig`): host
and resident state may differ, so it cannot become a dependency snapshot.
Rerun that work on the CPU backend.

Envelope queries fail with `error.EnvelopeDidNotConverge` when Newton fails at
the minimum outer step or the step budget ends before the requested time.

Only OP prerequisites are graph nodes. PAC, PXF and periodic noise prepare
their periodic state inside their own query; sharing it needs a complete
state and trajectory contract first. The graph supports automatic
prerequisites and append-only requests, not caller-defined dependency edges.

## No streaming output

The old CLI special-cased a single binary transient into a streaming raw
writer. That bypass is gone, and so is the streaming writer: Problem retains
complete results and publishes every query through one output session, which
keeps result access and append/resume semantics the same for every query.

Long transient results therefore stay in memory until the query completes.
Restoring streaming needs partial committed-result ranges and writer framing
in the Problem contract first. Do not claim bounded-memory transient output
for Problem or the CLI.

## CLI flags

The CLI rejects any option it does not implement ("unsupported option")
instead of accepting it silently. The old interactive, server and pipe modes
and the compatibility flags `--autorun`, `--no-spiceinit`, `--define`,
`--output`, `--completion`, `--soa-log` and `--term` are gone. Batch
execution is the only mode, with `--plan`, `--print-dag` and `--jobs` for
graph inspection and concurrency. Embedders use the Zig or C Problem API for
manual advancement and appends. Shell redirection replaces log capture, and
netlist parameters replace `--define`. An interactive frontend must use the
same Problem operations.

## Output delivery and recovery

Output publishes only completed plots, in request order, so a completed query
can wait behind earlier unfinished work. Binary raw appends to one file;
other formats write numbered destinations. Finishing current work leaves the
session open to appended requests.

A writer error is terminal for its destination, because replaying a partial
append could duplicate or corrupt output. Numerical results stay readable;
copy them out or call a writer directly at a new destination. There is no
automatic retry, retargeting or partial-result publication.

## Memory accounting

There is no allocation accounting inside ESPice. The old global `mem_stats`
allocator assumed one simulation owner and could not describe concurrent query
lifetimes, so it was removed along with `ZP_MEM_STATS`. Use process-level
memory measurements until per-Problem accounting exists.
