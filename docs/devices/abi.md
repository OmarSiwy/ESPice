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
return tracing is on, and `abi_version` (14). Each device object exports it
as `arp_layout_hash`. The runtime loader (`src/device/loader.zig`) refuses a
shared library whose hash differs (`error.LayoutMismatch`), and the hash keys
the runtime build cache, so a bump rebuilds every cached device once.

`hashType` sees only layout, so a change that moves no field (a tape's
meaning, a function signature) must bump `abi_version`. The version history
is the comment above `abi_version`. The GPU planes, Model/Instance PODs and
scatter tapes did not change from version 10 to 14; they are frozen at the GPU
boundary (see AGENTS.md).

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
