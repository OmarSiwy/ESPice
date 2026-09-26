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
return tracing is on, and `abi_version` (13). Each device object exports it
as `arp_layout_hash`. The runtime loader (`src/device/loader.zig`) refuses a
shared library whose hash differs (`error.LayoutMismatch`), and the hash keys
the runtime build cache, so a bump rebuilds every cached device once.

`hashType` sees only layout, so a change that moves no field (a tape's
meaning, a function signature) must bump `abi_version`. The version history
is the comment above `abi_version`. The GPU planes, Model/Instance PODs and
scatter tapes did not change from version 10 to 13; they are frozen at the GPU
boundary (see AGENTS.md).

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
