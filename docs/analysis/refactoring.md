# Analysis module: ownership and engine notes

How `src/analysis/` is split, what each file owns, and the design decisions
that are not obvious from the code. The per-analysis pages in this directory
cover the numerics.

## Ownership

| File | Owns |
|---|---|
| `root.zig` | The public seam: `session`, `ExecutionConfig`, `validateBackend`, `schemaOf`. The numerical leaves stay private. Its `test` block imports the suites in `tests/` and, for semantic analysis only, the `pss/` leaves the test step does not otherwise reach. |
| `session.zig` | The query graph and its cooperative scheduler: one row per query plus its implicit OP prerequisite, query publication, output-schema validation. |
| `executor.zig` | One query's mutable numerical state and the worker thread that runs it; dispatch is one exhaustive `requests.Kind` switch with compile-time checks on every analysis module's `Options` and `run` signature. Prepared topology and the deck are borrowed; an accepted OP from a dependency is copied before use. |
| `worker.zig` | `Worker(Product)`: runs one analysis on its own thread and parks it at every progress checkpoint until the coordinator resumes or cancels it. Embedded in its pinned executor, so there is no separate allocation. Suppressed inner Newton checkpoints poll an atomic cancellation flag without the scheduler mutex; published boundaries stay locked. |
| `validate.zig` | Query validation at the analysis boundary: every numeric option a driver would otherwise trust, checked once before any allocation. `requests.Kind.transient()` is the single list of transient kinds. |
| `types.zig` | The shared context every leaf needs (`Circuit`, `RunCtx`, `Result`, hooks). Leaves import it, never `root.zig`. File DAG: `Circuit.zig` to `types.zig` to leaves and `executor.zig` to `root.zig`. |
| `Circuit.zig` | The mutable analysis-side circuit over the frozen `device.Circuit`: plane evaluation, `clearPlanes(mode)`, `groundStamp`, `combinePlanes`, parameter recompute, noise collection, the GPU hook. |
| `par_eval.zig` | `ParEval`: the device stamp threaded over persistent worker lanes (below). |
| `gpu.zig` | GPU device evaluation feeding the host solver (below). |
| `progress.zig` | Checkpoint phases and counters. |

Evaluation itself lives in `src/device/eval.zig`. Imported as `device_eval`
or by the runtime loader, it supplies the shared evaluator; compiled as a
per-model root, it exports either the host vtable or the GPU entry points.

## Plane evaluation

`Circuit.clearPlanes(mode)` is the one plane reset and one batch walk for
the serial path, `ParEval` and the GPU host half; the stamp mode is comptime
on the serial path. `Circuit.combinePlanes(W, out, g, c, alpha)` forms
$G + \alpha C$ in one pass (the transient Jacobian) and serves MATEX with the
operands swapped ($C + \gamma G$). W = 1 is its scalar oracle and tail; the
differential case is mirrored in the standalone
`ref/SIMD-Strategies/verify.zig`, covering vector boundaries and aliased
output.

**ParEval.** Lane 0 stamps the caller's planes; lanes 1 and up stamp private
slabs that are summed into them in a fixed lane order, with no allocation and
no mutex per pass. Lane cuts fall on instance boundaries, so one instance's
cancelling `+g/-g` pair never straddles lanes, but two instances sharing a
node can. The result is therefore not bit-identical to the serial stamp: a
plane cell becomes `((S0 + S1) + S2) + ...` over consecutive segments of the
serial order. Measured serial against 2 to 16 lanes: at most 1 ulp
(`parallel_inverters`, `resistor_grid_100x100`; `rc_ladder_10k`
bit-identical), and deterministic at a given lane count. It is off by
default: `ESPICE_THREADS` sets the device thread count (default 1).

**GPU.** Every eligible batch's models, instances and tapes are uploaded once
and stay resident. Per Newton iteration the bus carries `x` up and the value
planes down (`Circuit.gpu_hook.eval_planes`); the sparse LU, Newton update
and convergence test stay on the CPU. That round trip is the floor, so the
GPU pays off on device count, not circuit size. A GPU plane stamp bypasses
the host batches, so the transient LTE falls back to per-row charge (see
[transient-integration.md](transient-integration.md)). Devices with
iteration hooks are excluded from GPU residency
([iteration lifecycle](../devices/iteration-lifecycle.md)). The earlier
GPU Newton, JFNK, transient and batched-solve routes were deleted; the
GPU reaches Newton only through `eval_planes`.

## Decisions kept on purpose

These came out of the engine cleanup (branch history `9df71ed` to
`199e9bf`; measured cost of the whole series +0.03% Ir on
`tran/device_mos6_inverter` and +0.02% on
`stress/scaling_parallel_inverters_100`, no speed claim):

- `ProtoStore` stages one `MultiArrayList` per device type and keeps its own
  `staging_gpa` (`std.heap.smp_allocator`). The arena waste it avoids comes
  from every type's store growing interleaved in netlist order, and one
  buffer per store does not change that.
- `Worker(Product)` stays generic: the executor tests instantiate it with
  `u64`, `u32` and `void`.
- `saved_models` (the source-stepping snapshot in `device/eval.zig`) is
  allocated eagerly. `applyAttempt` is a void hook with no allocator, so a
  lazy allocation would need a stored allocator and would fail silently on
  OOM.
- `limitRange` keeps its `f64` flag: a `bool` cost +0.1% Ir on
  `device_mos6_inverter`.

## Retired paths

- The serial temperature sweep with external `TempCoeff` overrides. Query
  execution uses `temp_sweep.run`, one `solveLanes` lane per temperature
  with device-native temperature coefficients; overrides were never supplied
  by query preparation.
- The OP-f64 / transient-f32 derivative-width experiment and its environment
  switch. CPU derivative width follows `jac_f32_host`; GPU derivative width
  follows the model's `jac_f32` permission. Reintroducing a phase-dependent
  width needs fresh numerical and benchmark evidence, not a dormant branch.
- Device ABI 11 dropped `Batch.thread_safe`, `Hooks.record_history` /
  `inject_history` and the GPU kernel-name/PTX/AMDGCN vtable fields
  (history next to `abi_version` in `src/device/abi.zig`).
- `mc` statistics (`Stats`/`YieldSpec`), `.four`'s `analyzeBuffer`, the
  envelope `extractPeak`/`extractRMS` helpers and the `stb` margin
  extraction had no callers and were deleted.

## Native transmission lines

O, Y and P cards stay on the native Zig devices (`models/native/`), registered
through the same neutral CPU vtable boundary as generated models: O cards use
native LTRA convolution for RLC/RC, the ideal line for LC and the static
Verilog-A two-port for RG; Y cards use native TXL; P cards use native CPL for
two, three or four conductors. Unsupported parameter sets and dimensions
fail at construction; the approximate Verilog-A RLC/RC and coupled models are
not fallbacks. The natives commit their own histories through `commit_state`,
with step bounds and breakpoints through the existing hooks. They stay until a
Verilog-A replacement passes the same numerical oracles (see
[vera-gaps.md](../vera-gaps.md)). Native history capacities, interpolation
choices, fit limits and non-transient behavior still need their own
compatibility coverage, and runtime parameter sweeps need a failure path for
newly invalid fits.

## Tests

The analysis suites live in `src/analysis/tests/` (AC, circuit, executor,
Fourier, GPU policy, integration, periodic, pole-zero, session, sweep,
transient) and run with `zig build test-analysis`. Private test access is
compiled only when `builtin.is_test` is true. Worker tests use the production
stack setting because the combined test executable's thread-local storage
exceeds a 1 MiB override.
