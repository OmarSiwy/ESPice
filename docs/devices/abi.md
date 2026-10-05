# Device ABI

`src/device/abi.zig` defines everything that crosses the boundary between the
host and a separately compiled device object: the `DeviceVtable`, `Proto`,
`Batch`, `Hooks`, planes, the pattern builder, `ParamRef` and noise sources.
Every built-in model is its own object, and a runtime-loaded `.hdl` device is
a shared library built from the same `src/device/eval.zig` root, so both
sides compile the same ABI source.

## Versioning

`layoutHash()` hashes the size, alignment and field offsets of every
boundary type, the Zig version, backend and optimize mode, whether error
return tracing is on, and `abi_version` (23). Each device object exports it
as `arp_layout_hash`. The runtime loader (`src/device/loader.zig`) refuses a
shared library whose hash differs (`error.LayoutMismatch`), and the hash keys
the runtime build cache, so a bump rebuilds every cached device once.

`hashType` sees only layout, so a change that moves no field (a tape's
meaning, a function signature) must bump `abi_version`. The version history
is the comment above `abi_version`. The GPU planes, Model/Instance PODs and
scatter tapes did not change from version 10 to 18; they are frozen at the GPU
boundary (see AGENTS.md).

## Shared Models (19)

A batch's `models` holds one row per distinct Model and `model_of` (one u32
per instance, owned per batch) names each instance's row; every host hook and
GPU kernel reads `models[model_of[id]]`. `ProtoStore.finalize` merges rows
that are bit-equal field by field (each is rebuilt over zeroed bytes first,
so padding cannot hide a match). Only VerA devices without breakpoint caches
or `attempt` share (`DeviceBatch.shares_models`): their Model is const to
every device entry point, so only host parameter writes change it.
`collect_params` first gives every instance its own row (`unshareModels`,
on `smp_allocator`, since the caller may be a worker thread borrowing a
template on the Problem arena), so a `ParamRef` write reaches one instance,
as before; the GPU launcher regrows its model buffer on the next `repack`.
Peak RSS, 2026-10-02 (default build, CPU backend): scaling_rc_ladder_100k
275.0 -> 265.4 MB, sweep_opamp_wl_5000 128.6 -> 119.8 MB,
scaling_inverter_chain_4k 90.9 -> 86.2 MB. Device eval costs one more load
per instance: callgrind on the inverter chain (0.1n..2n) 4.637G -> 4.678G Ir
(+0.9%). CPU and CUDA outputs are byte-identical to ABI 18 on the opamp,
inverter chain, vacask_ring (psp103), bsim4, hfet and the .sens/.dcmatch/.mc
decks checked.

## Analysis state

VerA's contract ABI 5 passes `contract.SimState` (24 bytes, `extern`) by value
to every device entry point and GPU kernel: `$abstime`, the timestep,
`analysis()`, the initial/final-step flags, `analog initial` and the Newton
iteration. It is in `layoutHash`'s type list. The `Circuit` owns it:
`setSimState` publishes the analysis fields, `beginSolve` sets `iteration` to
1 and `advanceIteration` adds 1 after the device hooks run, and each batch
stores the current value through `Hooks.set_sim_state`. `eval` overrides
`t` with its own argument, which callers keep equal to the published time.

## Device types

A device type is a dense `core.DeviceType` (`enum(u16)`) id from the
Problem's `Library` (`src/device/Library.zig`): built-ins take
`[0, builtin_count)` in catalog order, and each loaded HDL module appends one.
`CardRef`, the DC sweep target, AC overrides and `ParamRef` all carry that id,
never a type-name string. Display names come from `Circuit.typeName`.

Deck labels and result column names are not interned. They are output
strings the writers print verbatim, and every `Result` already borrows or
copies them once; an id table would add a pool lookup to every writer with no
measured gain. `ParamRef.param_name` stays a string for the same reason.

## Errors across the boundary

Zig error values are numbered per compilation, so a device object's
`OutOfMemory` could reach the host as an unrelated error such as
`PermissionDenied`, even with matching compiler settings. Fallible callbacks
therefore return `DeviceResult(T)`, a union tagged by the byte enum
`DeviceStatus` (`ok = 0`, `out_of_memory = 1`, `too_many_instances = 2`). The
producer converts its closed local error set with `fromLocal`; the consumer
rebuilds its own Zig error with `unwrap`. The `recompute` hook returns a bool,
and `Circuit.recompute` raises `error.TopologyChanged` locally when it is
false.

`zig build test-device` runs `src/device/tests/device_errors.zig` against a
real evaluator compiled as a separate object
(`device_errors_object.zig`), injecting failures through construction,
pattern creation, finalization, instantiation, snapshots, parameter and noise
collection, plus the `TooManyInstances` count guard.

## Error tracing on host device objects

The vtable functions use `callconv(.auto)`. With error return tracing on,
Zig passes every such function a hidden `*StackTrace` argument. The per-model
host objects are stripped, and stripping turns error tracing off by default,
so a traced Debug test binary and an untraced device object disagreed on
argument registers: the self-hosted backend read the trace pointer from r9
and faulted at 0, and LLVM handed `proto_create` a shifted `Allocator`.

build.zig therefore pins `error_tracing = (optimize == .Debug)` on every host
device object, including the native transmission-line object. `layoutHash`
includes the tracing flag, so a runtime-loaded library built with the other
setting is refused rather than miscalled. Check: `zig build test-frontend -Doptimize=Debug`.

## Derivative lanes

The host's `Dual` is VerA's scalar family: a value of `Of(mask)` carries the
lanes of the unknowns in `mask`, and only `derivReads` unknowns get a lane
(the others stamp their `jac_const` partial). `hostLayout` in
`src/device/eval.zig` picks the width per basis: on the wide basis every value
carries exactly its mask's lanes, rounded up to a power of two; on the narrow
(collapsed) basis every value carries all of at most 4 lanes. The GPU kernel
stays dense and unpadded.

This retired the per-model `pad_lanes` table (pad the dense width to a
multiple of 4 for six models). Measured with callgrind on 100-instance DC
sweeps, per-instance Ir, dense exact / sparse power-of-two: hisimhv_va
23.7M/6.8M, hisim2_va 37.1M/13.7M, bsimsoi_va 7.36M/3.95M, vbic13_4t
7.74M/3.83M, bsim4va 4.14M/2.32M, gummel_poon 3.46M/1.96M, mos1 with RD/RS
1.33M/1.14M, bsim2 1.35M/0.99M, jfet 0.48M/0.37M. No wide model lost. On the
narrow basis the sparse layout lost up to 2.8% (bsim1, mos2/3/9), so it stays
dense there. Unpadded widths that are not powers of two (12, 26) cost up to
2x: LLVM splits them into shuffles and spills. Every layout gives
byte-identical corpus output.

## Pattern-only slot tape (20)

The slot tape holds one CSC slot per entry the device's combined
`jac_pattern | q_pattern` sets, row-major, the same `SlotMap(D).k` per
instance, instead of the full `n_u * n_u` square with structural zeros
pointing at the trash slot. Stamps take (ru, cu) at comptime and
`SlotMap.at` turns them into a tape position; an entry outside the pattern
is a compile error. A structural zero never had a stamp, so the host planes
and the GPU staging order (contributions in tape order, trash ones dropped)
are unchanged. mos1 (n_u = 8) keeps 32 of 64 entries: peak RSS of
sweep_opamp_wl_5000 (25,000 mos1) 122.8 -> 119.7 MB, outputs byte-identical
on the CPU and under CUDA.

## Written-only lim plane (21)

The lim plane holds one value per instance and unknown `limit` writes
(`LimMap(D)`, from `contract.limitWrites`), not the full `n_u` stride: no
reader ever looked at the others. A MOS model writes 2 of its 8.

Retired 2026-10-02: deriving the residual row from `gath` (ground to the
trash row by a compare and select per stamped row) instead of storing
`rhs_idx`. It saved 4 bytes per unknown per instance (ladder 264.8 -> 263.4
MB, opamp 115.6 -> 115.2 MB, medians of 7) but cost 4.695G -> 4.845G Ir
(+3.2%) on the inverter chain to 2 ns, so `rhs_idx` stays.

## Status channel (22)

VerA latches the first `$fatal`/`$error` an instance's evaluation reaches
in `Instance.vera_status__` (with up to four arguments) and stamps zero
rows from then on. `Hooks.status` finds a batch's first latched instance
and writes `contract.formatStatus` into a host buffer (`StatusHit` is in
the layout hash). `Executor.execute` checks every batch after a query,
failed or not, logs `<card>: <file>:<line>: fatal|error: <message>` as a
warning and returns `error.DeviceRefused`. A device whose only eval write
is that latch (hisim2_va, hisimhv_va and lossy_tline today) stays
GPU-eligible (`statusOnlyMutable`): the device stores the latch exactly as
the host does, and `GpuContext.syncStatus` downloads the resident instances before
the context goes away.

## VerA device ABI 6 (host side)

VerA's ABI 6 moves the solve-invariant cache `su` and the temperature
(`Model.temperature__`, kelvin, host-written) from `Instance` to `Model`.
The host runs `setup(V, *Model)` once per Model row and `setupInstance`
for every instance after it (`DeviceBatch.setupRows`); `set_temp` writes
every row's `temperature__`. A row is still a bit-identical Model
(`model_of`), so instances at different temperatures, on different cards
or with a different `$port_connected` mask get different rows, and
instances on one card share the cache: Instance bytes mos1 744 -> 368,
bsim4va 3,520 -> 200, psp103 3,872 -> 104. The builder clears
`Model.port_connected__` bit p for each port the card omits, before
`derive` (a 4-terminal card on HiSIM_HV's 6-port module).
The per-instance `temperature` parameter is gone, so `.sens` and
`.dcmatch` lose their `<device>.temperature` columns; a DC temperature
sweep restores `Circuit.temp_c` instead of each instance's value.

