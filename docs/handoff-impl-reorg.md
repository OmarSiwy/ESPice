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
| 4 | Library, one binder, recomputeType by id | todo |
| 5 | src/core/ | todo |
| 6 | src/espice.zig, c_api, delete problem/ | todo |
| 7 | InternPool through Deck/Result/CardRef/ParamRef | todo |
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
