# Handoff: stream E, architecture reorg

Plan: docs/plan/optimize.md stream E. Base b1054dc. Branch
`worktree-agent-aa9264bf273c280fc`.

Gate for every commit: `zig build -Dgpu=false`, `zig build test -Dgpu=false`,
fixture failing set equal to the 90-deck list (526/616 pass), and all 616 decks
byte-identical (raw file, stdout, exit code) against a `-Dgpu=false` build of
b1054dc. Scripts: session scratchpad `e/gate.sh <tag>` and `e/runall.sh`.

## Status

| Step | What | State |
|---|---|---|
| 0 | test wiring, Debug crash | done |
| 1 | pure deletions | done |
| 2 | src/solver/ | done |
| 3 | src/device/ moves | done |
| 4 | Library, one binder, recomputeType by id | done |
| 5 | src/core/ | done |
| 6 | src/espice.zig, c_api, delete problem/ | done |
| 7 | DeviceType identity through CardRef/SweepTarget/AcOverride/ParamRef | done (see below) |
| 8 | schemaOf, output encoders, Plot | todo |
| 9 | AGENTS.md, docs paths | todo |

## Step 0 findings

The ReleaseFast "crash" was never a crash. `zig build` prints `failed command:`
next to any test run that wrote to stderr; the run was 24/24 green and the
stderr was two expected `std.log.warn` lines from the LEVEL 55/1040 test
(summary line `run test w`, w = warnings). That test now lowers
`std.testing.log_level` around the two calls.

The Debug crash was real and reproducible, with one cause: the device vtable
is `callconv(.auto)` and crosses separately compiled objects. A compilation
with error tracing passes each such function a hidden `*StackTrace`. The
per-model host objects are stripped (`GPU.make`), and stripping turns error
tracing off by default, so in Debug the traced test binary and the untraced
device objects disagreed on argument registers. Self-hosted backend: the
callee read the trace pointer from r9 and faulted at 0. LLVM backend:
`proto_create` got a shifted `Allocator` and jumped to a stack address.
Fix: pin `error_tracing = (optimize == .Debug)` on the host device objects.
Check: `zig build test-frontend -Dgpu=false -Doptimize=Debug` (was 14 pass /
10 crash, now 47/47).

## Step 4 findings

- Runtime loading of any `models/*.va` fails on b1054dc too: VerA's library
  emit declares `const h = @import("../h.zig")` and a local `var h` in every
  model with hoisted temporaries (`GeneratedDeviceDoesNotCompile`). The hdl/
  fixtures load because their small models hoist nothing. So the binder pin
  test registers the built-in resistor's own vtable as a runtime type; only
  the dlopen step is not exercised. Needs a VerA fix, then the pin can load
  models/resistor.va for real.
- The built-in R card path never publishes `.options tnom` to the resistor
  (`tnom` stays 27 under `.options tnom=50`); runtime-loaded devices never get
  it either. Left alone: output-changing, and impl-verA owns the construction
  sequence around derive.
- Deferred: analysis tests still import the frontend `builder` module
  (integration.zig builds circuits with Builder). Moving them onto a device
  level assembly API would drop the last analysis->frontend test edge.

## Step 7 scope

Device-type identity is a `core.DeviceType` everywhere: CardRef, Dc.SweepTarget,
AcOverride and ParamRef (`device_type` string dropped, abi 13); display names
come from the batch (`analysis.Circuit.typeName`). device_abi imports core, so
the runtime .so build gets a `core` module (build_options.core_path).
Not done: interning Deck labels / Result varnames through InternPool. They are
output strings the writers print verbatim, and every Result already borrows or
copies them once; an id table would add a pool lookup to every writer for no
measured win. ParamRef.param_name stays a string for the same reason.
