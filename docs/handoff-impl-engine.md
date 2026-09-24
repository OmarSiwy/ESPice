# Handoff: stream A (analysis engine cleanup)

Branch `worktree-agent-a289816b63c9a3259`, based on main 4614f9a. Plan:
`docs/plan/optimize.md` stream A. Every commit is gated on `zig build -Dgpu=false`,
`zig build test -Dgpu=false` (306/306 unit tests; the step exits 1 only because
of the 98 known fixture failures), the fixture FAIL deck list (same 98 decks as
the f-base baseline) and byte-identical raw/stdout/exit on all 616 decks against
a `-Dgpu=false` build of 4614f9a.

Gate scripts live in the session scratchpad under `engA/`. `gate.sh <tag> <rev>`
builds a `git archive` of the commit, runs the tests, and compares the corpus.
`corpus.sh` runs every deck. `one.sh` reruns one deck.

`stress/scaling_inverter_chain_4k.sp` fails as Timeout in some runs and as
ValueMismatch in others. The timeouts come from machine load (load average
100+), and the deck fails either way. The baseline corpus was rerun for it with
a 900 s timeout.

## Done

| # | Commit | Item | LOC (+/-) |
|---|--------|------|-----------|
| 1 | 9df71ed | Delete GpuHook.solve_newton, AssembleHook, GpuContext.ws/launch_err, the converger GPU block, EvalHook.gpu_eligible, Circuit.gpu_active | +6 / -85 |
| 2 | 22f4b0b | ParEval moves to analysis/par_eval.zig (pure move; eval.zig's private zeroSimd dropped for numerics.zeroSimd) | +421 / -424 |
| 3 | 6ee1aec | Circuit.clearPlanes + stamp(mode): one plane reset and one batch walk for serial, ParEval and the GPU host half; ParEval exposes only run(); GPU fallbacks use Circuit batch walkers | +118 / -165 |
| 5 | c4736bd | eval.baseName(D); Batch.type_name is the short name; gpu.modelOf gone (landed before the ABI bump on purpose) | +23 / -38 |
| 4 | 865a274 | ABI 11: drop Batch.thread_safe (+ dead lane-0 pass), Hooks.record_history/inject_history, DeviceVtable.gpu_kernel_name/gpu_ptx/gpu_amdgcn; version history moves next to abi_version | +20 / -44 |
| 6 | 40c0074 | validate/validatePrepared -> analysis/validate.zig; requests.Kind.transient() replaces the two transient-kind lists | +281 / -249 |
| 7 | 8aeeeb8 | ProtoStore stages one MultiArrayList | +35 / -53 |
| 8 | 0b7e39f | Unused Io, limitRange bool, collectNoise localX, addInto -> addSimd, stale file-name comments | +29 / -32 |
| 8b | 7da4c04 | limitRange keeps its f64 flag (bool cost +0.1% Ir on mos6) | +7 / -4 |
| 3b | 199e9bf | Stamp mode comptime on the serial path (recovers most of 6ee1aec's Ir) | small |

## Cost (callgrind Ir, -Dgpu=false)

| deck | 4614f9a | branch tip |
|------|---------|------------|
| tran/device_mos6_inverter | 118,220,932 | 118,253,735 (+0.03%) |
| stress/scaling_parallel_inverters_100 | 343,907,580 | 343,981,138 (+0.02%) |

Per-commit numbers are in the 7da4c04 and 199e9bf messages. The series makes
no speed claim.

## GPU-affecting commits (GPU builds are off; check these in the GPU pass)

- 9df71ed: the GPU reaches Newton only through `eval_planes` now.
- 6ee1aec: `evalOnGpu` clears through `Circuit.clearPlanes(.full)` and pins
  ground through `Circuit.groundStamp`. The limit, state and ctl hooks walk
  through `Circuit.limitBatches`/`updateBatches`/`clearLimitBatches`/
  `stateCtlBatches`/`seedBatches`. None of this was type-checked with a
  backend present, because the `comptime backend == null` early returns hide
  those bodies.
- c4736bd: `reportDemote` prints `Batch.type_name` instead of parsing the
  kernel symbol.
- 865a274: ABI 11, so runtime `.so` devices rebuild once.
- 0b7e39f: `addInto` is replaced by `par_eval.addSimd`.

## Deviations from the plan

- Item order: baseName (5) landed before the ABI bump (4). It changes what
  `Batch.type_name` holds, and the bump then re-keys cached `.so` files built
  with the old full name.
- ProtoStore keeps `staging_gpa`. The arena waste it avoids comes from every
  device type's store growing interleaved in netlist order, and a single
  MultiArrayList buffer per store does not change that.
- Worker(Product) stays generic, because tests/executor.zig instantiates it
  with u64, u32 and void.
- saved_models stays eager. `applyAttempt` is a void hook with no allocator,
  so a lazy allocation would need a stored allocator and would fail silently
  on OOM.
- build.zig still wires `device_eval` into analysis_mod. The analysis sources
  no longer import it, but tests/transient.zig reaches it through the shared
  import list. build.zig is outside this stream.
- frontend/builder.zig keeps its own `shortTypeName` (the frontend rewrite owns
  it); it can call `eval.baseName` once the reorg settles.

## Left / skipped
- Slot-tape compaction: needs sign-off (frozen GPU layout).
- RealFor -> DualFor(0): skipped unless the asm is identical; not attempted.
- Per-instance Model copies: load-bearing, not removed.
- validateOutputSchema stays in session.zig until the output reorg.
