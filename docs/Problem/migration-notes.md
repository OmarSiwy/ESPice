# Migration notes

## Problem file boundaries

Problem keeps six production files: `root.zig` owns orchestration; `c_api.zig`
adapts the C ABI; `types.zig` holds prepared data and its Circuit; `requests.zig`,
`numerics.zig`, and `device_ir.zig` remain independent shared leaf modules.
The former `circuit.zig` is folded into `types.zig` without changing layouts or
ownership. Tests live in `src/problem/tests/`, separated into Problem lifecycle,
analysis regressions, C ABI, and numerical helpers.

S-parameter delivery accepts the analysis producer's `v(S_m_n)` labels as well
as `S(m,n)` labels used by direct writer callers. One shared parser supplies
port identities to validation and CITI serialization; raw result names remain
unchanged. Problem validates requested output once before committing an append.

### Allocation-error regression at the device boundary

The allocation-failure tests expose an existing device ABI defect:
separately compiled device objects return Zig `anyerror` values, whose numeric
identities are local to each compilation. A forced allocation failure can arrive
at Problem as `PermissionDenied` instead of `OutOfMemory`. A direct call to the
built voltage-source vtable with a zero-capacity allocator reproduced device
error code 1 versus caller `OutOfMemory` code 2 using matching ReleaseFast/LLVM
settings. A dedicated test forces failure directly in each compiled device's
instantiation callback, so detection does not depend on the constructor arena's
current growth points. Successful construction does not expose the defect.

The regression remains enabled. Do not treat the current constructor error name
or C out-of-memory status as reliable for device allocation failures. A repair
needs stable device-boundary error codes and conversion at the owning side,
with a host ABI version change. Reinterpreting arbitrary errors in Problem would
hide the defect. Until then, callers must treat any construction error as a
failed creation; the compiled-device allocation test remains a failing conformance gate.

The implementation starts from `fc7b115`. Existing benchmark edits and document
deletions in the working tree are outside this migration.

## Prepared circuit and request contracts

The data-design answers for the first extraction are:

1. Construction transforms resolved device prototypes into frozen CSC/tapes,
   initial device templates, labels, and query requests. Analysis creates its
   mutable execution state from that representation.
2. There are many unknowns/nonzeros/instances per circuit and many requests per
   session. Collections keep their existing layouts; no per-instance objects
   are introduced.
3. Preserve the existing u32 circuit/tape indices, f64 planes and request field
   widths. New query IDs are distinct u32 indices, with maxInt(u32) reserved
   as invalid and checked allocation/count arithmetic.
4. Keep CSC and batch storage separate from labels/request metadata. The
   prepared aggregate is a cold collection of slices; numerical loops still
   stream their existing arrays. No new numerical kernel is introduced here.
5. Prepared data and retained source live for the session. Query instances own
   mutable device state, numerical planes and scratch. Templates outlive all
   instantiated queries. Construction scratch ends after preparation.
6. Independent queries share immutable topology but have separate mutable
   state. Existing frequency/device lanes and sequential integration semantics
   remain intact.

Source relocation is not evidence of a performance improvement. No performance
claim is made for this migration without the repository's benchmark evidence.

### Query scheduler storage

1. Resolved request descriptions and completed prerequisites become progress events,
   terminal results, and a read-only DAG projection.
2. A session contains up to `u32::MAX - 1` queries; each current analysis has zero
   or one shared OP prerequisite. Requested outputs form a separate ordered ID list.
3. Query/component identities are u32; status/kind/phase are byte enums; concurrency
   is u16. Array lengths are usize. Progress counters are u64 across nested attempts.
4. Graph columns use MultiArrayList (SoA); status/readiness scans avoid large request
   payloads. Worker handles and errors are cold columns. IDs survive appends.
5. Prepared data and completed products live for the session. Each accepted append
   owns an arena; a rejected candidate frees its arena without publishing anything.
   Each worker owns its numerical state and output arena until session destruction.
6. The coordinator validates a frontier before starting workers, then starts all
   workers in each bounded batch before waiting. Queries share only immutable
   prepared topology and completed prerequisite snapshots.

## Source ownership after the move

`src/devices/models/` moved to `models/`; frontend construction and model loading
now live under `src/frontend/`. The old engine became the owning Problem API in
`src/problem/`. Device evaluation and GPU policy are analysis internals under
`src/analysis/eval/` and `src/analysis/gpu.zig`; solver implementations are under
`src/analysis/solvers/`. Shared passive contracts prevent consumers importing
frontend or the owning Problem facade.

## Resumption and memory ceiling

The first resumable implementation preserves each started query's stack on its
worker thread. Its default stack request is 512 MiB, inherited from the previous
whole-simulation worker because large numerical phases need stack headroom.
This is a virtual-address reservation, not an assertion that every query
immediately commits 512 MiB of physical memory. Paused queries retain their
stack and numerical allocations; terminal workers join, while completed
results and dependency state remain session-owned.

The fallback is the default `max_parallel=1` and explicit query selection.
That limits active work, not total retained state. If retained stacks become
the capacity limit, replace them with explicit algorithm-phase state or a
measured smaller stack policy; do not silently restart queries at every call.
No performance improvement is claimed for this design.

An OP that encountered a GPU runtime fallback fails publication with
`GpuStateUnavailable`: host and resident histories may differ, so it cannot
become a dependency snapshot; select the CPU backend to rerun that work.

Envelope queries now fail with `EnvelopeDidNotConverge` when Newton fails at
the minimum outer step or the configured step count ends before the requested
time, replacing an infinite retry or publication of an incomplete result.

Only OP prerequisites are graph nodes today. PAC, PXF and periodic-noise
preparation remain inside their existing algorithms; shared periodic products
need a complete state/trajectory contract before graph reuse is introduced.
The implemented graph supports automatic prerequisites and append-only query
requests, not caller-defined dependency edges.

## Retired CLI streaming shortcut

The old CLI special-cased a single binary transient into `runTransient` plus
`rawfile.Stream`. That bypass no longer belongs to the owning Problem path.
Problem now retains complete results and uses one publication session for all
queries, preserving result access and append/resume semantics consistently.

This increases retained memory for long transient results. The fallback is
whole-result delivery through Problem; low-level `output.Stream` and transient
recorder support remain available to direct internal callers. Add partial
committed-result ranges and writer framing to the shared Problem contract
before restoring streaming through the public API. Do not claim bounded-memory
transient output for Problem or the CLI.

## Retired placeholder CLI flags

The old CLI parsed interactive/server/pipe modes without implementing those
services. It also accepted ignored or incomplete compatibility flags, including
`--autorun`, `--no-spiceinit`, `--define`, `--output` log selection,
`--completion`, `--soa-log`, and `--term`. The new CLI rejects unsupported flags
rather than implying those features run.

Batch execution remains the default, with `--plan`, `--print-dag`, and `--jobs`
for graph inspection and concurrency. Embedders use the Zig/C Problem API for
manual advancement and query append. Shell redirection handles log capture;
netlist parameters replace the unsupported CLI definition mechanism. A future
interactive frontend must use these same Problem operations.

## Output delivery and recovery

Output publishes only completed plots, in requested order. A later completed
query can wait behind earlier unfinished work. Binary raw uses append; other
formats use numbered destinations. Finishing current work leaves the session
open to appended requests.

A writer error is terminal for that destination because replaying a partial
append can duplicate or corrupt output. Numerical results remain accessible;
copy them out or invoke a direct writer at a new destination. No automatic
retry, output retargeting, or partial-result publication is claimed.

## Retired global memory accounting

The unused `mem_stats.zig` module and its build wiring were removed. Its global
current-label allocator assumed one simulation owner; it has no callers after
the engine migration and does not describe concurrent query lifetimes. Use
process memory measurements until per-Problem allocation accounting is added.
`ZP_MEM_STATS` no longer produces a report.
