# Decisions: seam records and change drills

The record format follows `codebase-clean-code/DECISIONS.md`. A seam at rung 5
or above gets its probe verdict when the P1 probe step lands (AGENTS.md §1.2
R8); until then its Proof field reads "pending, P1". A seam whose current rung
breaks §2.1 names its target rung and the plan block that moves it.

## Seam records

### S1: analysis kind dispatch

- **Axis**: kind: one leaf per `requests.Kind` (op, dc, ac, tran, noise, pss, hb, pac, pz, mc, sens, …, ~40 kinds).
- **Evidence**: ~40 cases today, each with fixtures.
- **Owner**: analysis (`src/analysis/executor.zig` `module`, `run`).
- **Rung**: 5, `switch (kind) { inline else => |k| module(k).run(ctx, job) }`. Rung 4 (a plain switch with one call per arm) is the same code written out ~40 times; rung 5 keeps one line and the compiler still lists a missing arm.
- **Cost**:
  - residue: one switch per query (cold: runs once per query, not per element)
  - change radius for one more case: 1 body (`module`'s compiler-listed arm) plus the new leaf
  - interface weight: `fn run(ctx: *const RunCtx, job: Query) !Result` per leaf
- **Drills passed**: none drilled
- **Proof**: n/a: cold (once per query), so §2.1's hot-path probe rule does not bind
- **Revisit when**: a kind is loaded at runtime.

### S2: device type evaluation

- **Axis**: kind: one `Batch` per `DeviceType`, built-in (64 models) or loaded at runtime from `.hdl`.
- **Evidence**: 64 built-in models today plus runtime `.so` devices.
- **Owner**: device (`src/device/abi.zig` `Batch`, `Hooks`; `src/device/eval.zig` `deviceVtable`).
- **Rung**: 7, function-pointer table per batch. Rung 5 fails because runtime-loaded devices are not known at build time; rung 3 (a table per kind) is what the batch already is: one indirect call per batch per eval, a tight loop over the batch's instances inside.
- **Cost**:
  - residue: one indirect call per device type per Newton evaluation (O(device types), §2.1 rung 7)
  - change radius for one more case: 0 bodies (a `.va` in `models/`)
  - interface weight: `Batch`, `Hooks`, `Proto`
- **Drills passed**: none drilled
- **Proof**: n/a (rung 7); residue location stated above
- **Revisit when**: an eval spends measurable time in the indirect call itself (more device types than instances per type).

### S3: device derivative scalar

- **Axis**: policy: `Dual(N, F)` derivative lanes (N = unknowns a value depends on) over F = f64 or f32 (`--jac-f32`, GPU only by default).
- **Evidence**: two scalar widths and every N from 0 to 64 in the model set today.
- **Owner**: device (`src/device/eval.zig:46` `Dual`, `DualFor`, `RealFor`).
- **Rung**: 5, comptime parameter. Rung 4 fails because the lane set is fixed per value per model at build time; a runtime switch per arithmetic op would be residue in the hottest loop (45–50% self time, `dev/analysis/evaluation-profile.md:86`).
- **Cost**:
  - residue: none expected
  - change radius for one more case: 0 bodies (a new instantiation)
  - interface weight: the `Of(mask)` / `to(mask)` contract VerA emits against
- **Drills passed**: D2 fails (more than 64 unknowns, below)
- **Proof**: `Dual(2, f64).mul` against the value and 2-lane gradient written out: see `tests/codegen.zig` `gen_dual_mul=hand_dual_mul`, Zig 0.17.0 `-O ReleaseFast -mcpu=x86_64_v3`. The first probe read RESIDUE on instruction order alone (the same 11 instructions, 2 vector, scheduled differently); with the hand version written in the family's operand order the verdict is the one `zig build test-codegen` prints. Pending P6: a whole `DeviceBatch(diode).eval` against a hand-written diode stamp. Bit-identity with the scalar path is tested (`src/device/tests/eval.zig:105`).
- **Revisit when**: a device has more than 64 unknowns (#117).

### S4: device target

- **Axis**: backend: host CPU, CUDA (NVPTX), HIP (AMDGCN).
- **Evidence**: three build targets today from one `eval.zig`.
- **Owner**: device (`src/device/eval.zig` `Sink(D, device, skip_const)`, root `comptime` exports).
- **Rung**: 5, comptime parameter. The target is fixed per object file, so a runtime branch would be residue on every stamp.
- **Cost**:
  - residue: none expected
  - change radius for one more case: the `Sink` arms for the new device (compiler-listed) and its export block
  - interface weight: `Sink`
- **Drills passed**: none drilled
- **Proof**: pending, P1 (host `Sink` vs a hand-written host stamp loop)
- **Revisit when**: a backend needs a different kernel shape, not just a different sink.

### S5: GPU evaluation and LU contexts

- **Axis**: backend at runtime: host walk or a live GPU context.
- **Evidence**: one implementation each (`analysis/gpu.zig` `GpuContext`, `analysis/gpu_lu.zig` `GpuLu`). The "host" case is the absence of a context.
- **Owner**: analysis (`src/analysis/Circuit.zig` fields `gpu: ?*GpuContext`, `lu: ?*GpuLu`; the executor creates, attaches and frees both).
- **Rung**: 1, concrete optional contexts. Each evaluation entry (`eval`, `evalQ`, `evalNewton`, `applyLimits`, `updateStates`, `stateCtl`, `seedJunctions`, `clearLimits`, `snapshotQTape`, `qTapeLen`, `evalFollows`, `restoreState`) branches once on `gpuContext()`, which is comptime null in a build without kernel images (`gpu.available`), so there the branch folds away; `deviceSolve` branches on `lu`. Was rung 8 (`GpuHook`, `*anyopaque` plus 11 function pointers, and `LuHook`), which broke §2.1 on the Newton path. The branch stays inside the `Circuit` methods rather than in their callers: 65 call sites across the analyses reach these 12 methods, and hoisting would copy the branch into each. gpu.zig does not import the circuit (`GpuContext.init` reads a `gpu.Host` view; the shared host walks are in walk.zig, the knobs in knobs.zig), so the file graph has no cycle. The `GpuContext` entry points are `noinline`: inlined into the Newton and transient loops, the GPU branch's body cost the host path registers.
- **Cost**:
  - residue: one predictable branch per evaluation entry in a GPU build, none in a host-only build. Callgrind Ir, ReleaseFast `-Dcpu=x86_64_v3 -Dhip-arch=none -Dcuda-arch=none`, `--backend cpu`, before (f05c47f) → after, raw files byte-identical: `tran/device_mos6_inverter` 113,988,293 → 113,956,155 (−0.03%); `stress/scaling_parallel_inverters_100` 358,515,839 → 358,535,625 (+0.006%). An earlier draft without the fold and with the entry points inlined measured +94k Ir on the second deck.
  - change radius for a second GPU backend: 0 (HIP and CUDA already share `gpu.zig` through gompute)
  - interface weight: −2 (`GpuHook`, `LuHook` removed)
- **Drills passed**: D3 is open
- **Proof**: n/a at rung 1; the Ir pair above
- **Revisit when**: a second, structurally different accelerator path exists.

### S6: frequency lane width

- **Axis**: policy: `LaneLu(W)`, W = 1 (the scalar oracle) and W = 4 shipped; W = 8 retired on Ir data.
- **Evidence**: two widths today (`src/solver/tests.zig:1997`, `:2003`).
- **Owner**: solver (`src/solver/lane_lu.zig:16`, `freq_solve.zig`).
- **Rung**: 5, comptime parameter. Rung 4 fails: the width is fixed per build; a runtime width would lose the `@Vector(W)` codegen.
- **Cost**:
  - residue: none expected
  - change radius for one more case: 0 bodies
  - interface weight: `W`
- **Drills passed**: D3 (ensemble lanes reuse the same replay)
- **Proof**: pending, P1 (`LaneLu(1)` against `SparseLu.refactor`+`solve` on the same values: also the bitwise test at `tests.zig:2003`)
- **Revisit when**: AVX-512 targets ship as a separate build (`x86_64_v4`).

### S7: linear engine

- **Axis**: kind: sparse LU, tridiagonal, bordered block diagonal (BBD).
- **Evidence**: three engines today (`src/solver/direct.zig` `Engine`).
- **Owner**: solver (`src/solver/direct.zig` `Solver`).
- **Rung**: 4, `engine: Engine`, a `union(enum) { lu, tri, bbd }` with exhaustive switches in `deinit`, `factorInner`, `solveInPlace` and `solveT`. Exactly one engine is live by type; a singular structured engine is swapped for the LU by `demote`, which builds the LU before freeing the old engine. Callers that need the LU itself (LaneLu, the device LU, the timing line) go through `Solver.sparse()`, null for the structured engines. Rung 3 fails: the engine is per circuit, not per element, so there is no table to bucket.
- **Cost**:
  - residue: one switch per factor and per solve, as before (measured below)
  - change radius for one more engine: 4 compiler-listed arms plus `sparse()`
  - interface weight: unchanged for callers (`sparse()` replaces reading `lu` directly)
- **Drills passed**: none drilled
- **Proof**: NEGATIVE: `tests/codegen.zig` `gen_engine_solve=hand_engine_solve` (the union switch against the three optionals it replaced, in their old check order), Zig 0.17.0 `-O ReleaseFast -mcpu=x86_64_v3`: 114 vs 115 instructions, 1 vs 2 calls, 12 branches each. Callgrind Ir, ReleaseFast `-Dcpu=x86_64_v3`, before → after, raw files byte-identical: `tran/device_mos6_inverter` 114,190,666 → 114,151,878; `stress/scaling_parallel_inverters_100` 358,735,713 → 358,594,795; `stress/scaling_inverter_chain_256` 3,044,906,004 → 3,043,618,826 (−0.03 to −0.04%).
- **Revisit when**: engines differ per matrix block rather than per circuit.

### S8: netlist dialect

- **Axis**: dialect: ngspice, HSPICE, Spectre (`frontend/lines.zig:8`).
- **Evidence**: three dialects today with fixtures (`tests/fixtures/hspice/`, `syntax/`).
- **Owner**: frontend (`lines.zig` `Syntax(d)`, `netlist.zig` keyword maps).
- **Rung**: 3 with a comptime `Syntax(d)` for the line splitter (5). A per-character runtime dialect switch would be residue in the parser's hot loop (`bench-frontend`).
- **Cost**:
  - residue: none in the splitter; one table load per keyword lookup
  - change radius for one more dialect: the `Dialect` tag, its `Syntax` arm, its keyword rows
  - interface weight: `Dialect`
- **Drills passed**: none drilled
- **Proof**: pending, P1 for `Syntax(d)` (hot: `bench-frontend`)
- **Revisit when**: a dialect changes the meaning of shared syntax rather than adding to it.

### S9: output format

- **Axis**: kind: binary raw, ascii raw, csv, touchstone, psf, fsdb, sst2, citi, print (`output/types.zig:8`).
- **Evidence**: nine formats today with golden tests.
- **Owner**: output (`src/output/write.zig`).
- **Rung**: 4, exhaustive switch over `Format`, once per plot. Cold.
- **Cost**:
  - residue: one switch per written plot
  - change radius for one more format: the compiler-listed arms in `write.zig`, `validateQuery`
  - interface weight: `Format`
- **Drills passed**: none drilled
- **Proof**: n/a (rung 4, cold)
- **Revisit when**: a format is supplied by a plugin.

### S10: runtime HDL devices

- **Axis**: plugin: `.hdl` Verilog-A/Verilog compiled at run time into a `.so`.
- **Evidence**: runtime-loaded devices in `tests/fixtures/hdl/` today.
- **Owner**: device. `src/device/loader.zig` compiles and opens (`prepareAll`), returning one `Prepared` value or error per file, and reads only the names already loaded; `Library.load` (`loadWith` for explicit paths) registers the values in file order. The loader does not import `Library.zig`, so the two no longer import each other (P3, 2026-10-17); registration stays with the table's owner.
- **Rung**: 9, ABI boundary. Separately built code: it cannot be a build-time parameter.
- **Cost**:
  - residue: one `dlopen` and symbol lookup per model per Problem (cold); evaluation then runs through S2
  - change radius for one more HDL: 0 bodies (VerA's frontend)
  - interface weight: `arp_abi_version`, `arp_layout_hash`, `arp_device`; host side, `loader.Error` (named, forwarding VerA's and std's sets by name) and `Library.LoadError`
- **Drills passed**: D2 (the failure is in S3, not here)
- **Proof**: n/a (rung 9); `layout_hash` refuses a mismatched `.so`
- **Revisit when**: untrusted models must be sandboxed.

### S11: stdpp pipelines in `core.numerics`

- **Axis**: policy: one lanewise callback per helper (`axpy`, `scale`, `sub`, `dot`, `sum`, `normInf`) over stdpp's comptime pipeline.
- **Evidence**: six helpers today, each with a `.byRef()` differential test.
- **Owner**: core (`src/core/numerics.zig`).
- **Rung**: 5, comptime-fused iterator pipeline. The vectorizer is off in Zig 0.17 (§2.11), so a plain loop (rung 1) is scalar.
- **Cost**:
  - residue: **measured, not zero.** `normInf` (2026-10-17, `-mcpu=x86_64_v3`): `gen` 67 instructions, 1 call: an out-of-line `foldVector` call per invocation for lengths ≥ 64, scalar inline below. A hand 4-wide, 4-accumulator loop: 108 instructions, 0 calls. The residue is one call and a 32-byte stack spill per `normInf`, never per element. The vector body sits in the helper.
  - change radius for one more helper: 0 bodies
  - interface weight: the lanewise callback contract
- **Drills passed**: none drilled
- **Proof**: RESIDUE, per call. Not gated, because the helper's symbol name (`foldVector__func_N`) changes between builds. **P6:** probe the helper body by a stable name (an `export` wrapper in `tests/codegen.zig` around `foldAssoc` itself), or inline it, then gate. Hot-path standing: `normInf` runs once per Newton iteration (`converger.zig:217`), O(n), against an O(fill) factor.
- **Revisit when**: stdpp exposes the fold body by a stable name, or a profile shows the call.

### S12: VPI `$systf` application

- **Axis**: plugin: the LRM §12.32 application behind each `$name` VerA leaves to a host (`contract.Systf`, W0852).
- **Evidence**: VerA's contract requires a host binding for every device with `systf_calls`, and the owner wants VAMS modules and testbenches that call one to run (#197). Today there are no applications: `VpiHost(D).systf` returns null, and `NetBuilder.addDynDevices` refuses such an instance by name (`UnregisteredSystf`) from `DeviceVtable.systf_calls` (device ABI 29).
- **Owner**: device. `VpiHost(D).systf` names the application, `ProtoStore.append` binds it into every staged `Instance.systf` and asserts it. The frontend owns the refusal.
- **Rung**: 8, a function pointer in the Instance. VerA's contract fixes the shape (`SystfHost.call`), because a function pointer cannot be generic over the AD family. No device evaluates through it yet.
- **Cost**:
  - residue: none today. Once loading lands, one indirect call per `$systf` site per eval, on such devices only; `gpuRefusal` (`.systf`) keeps them on the host
  - change radius for VPI loading: `VpiHost(D).systf`, a C-ABI forward in eval.zig (a Zig-ABI `SystfHost` cannot cross the `.so`), the loader, and the refusal (narrowed to unregistered names)
  - interface weight: `DeviceVtable.systf_calls`
- **Drills passed**: none drilled
- **Proof**: n/a (cold, rung fixed by VerA's contract)
- **Revisit when**: VPI loading lands (#197, VerA changes V1-V5 listed in dev/reviews/2026-10-18-systf-host.md), or VerA marks task calls (V1), when a task-position call becomes a no-op with a warning.

## Drills

Taken from the open GitHub issues (2026-10-17). Radii are counted on the code
at `66ec7fe`; a drill marked "re-run" is run again when its fix lands.

| ID | Change | Source | Edits (file: function or row) | Radius | Weight Δ | Verdict | Fix |
|---|---|---|---|---|---|---|---|
| D1 | Set a `.param` on a live Problem and re-run its queries without a re-parse | #101 | re-run after P3 (`p3-frontend`). `espice.zig`: new `Problem.set_param` (0), `Problem.init` keeps the parsed `Netlist` in the session arena instead of parse scratch (1); `c_api.zig`: new `espice_set_param` (0); `include/espice.h`: one decl (0); `frontend/root.zig`: re-export `buildRun` (0 bodies, one alias); `frontend/netlist.zig`: `parse` keeps the names a caller may set live, the way `.step` targets go through `liveParam` (1): a `.param` nothing sweeps folds at parse today; the write itself is `Netlist.setLive` on a `*Netlist`, the owner's method (0); `frontend/prepare.zig`: `buildRun` rebuilds from the set values, no cycle in the way (0); `analysis/session.zig`: new `Session.rebind(circuit)` (0). First run (`66ec7fe`): radius 3, through the `@constCast` writer and the prepare↔variants cycle | 2 | +1 (`set_param`) | pass | P3 removed the second writer and the cycle. The remaining radius is the facade keeping the netlist and the parse keeping a settable name live; the first run's list missed the second. |
| D2 | `.hdl` device with more than 64 unknowns compiles and evaluates | #117 | `device/eval.zig`: `Dual` (`:89` refuses > 64 lanes), `addPattern` (`:517-533`, u64 row masks), `limit` writes mask (`:545`), `maskOf` (`:572-585`), `markCurrentRows`, `collectAcDyn` (unrolled n_u², `:1749`), `permuteInPlace` (`:1020`) | 7 | 0 | fail | restructure: the mask type becomes a comptime function of `n_u` (`std.bit_set.StaticBitSet(n_u)` or a dense-fallback variant chosen at comptime), so S3 handles any width at radius 0 afterwards. Lands with #117, not in this pass. |
| D3 | GPU ensemble: many same-pattern runs batched in lockstep | #99 | new `analysis/sweep/ensemble.zig` (0); `analysis/gpu.zig`: context init and `eval_planes` gain a points axis (2); `analysis/gpu_lu.zig`: batched refactor (1); `device/eval.zig` kernel exports over points × instances (1, frozen ABI → `abi_version` bump); `sweep/lanes.zig solveLanes` (1) | 5 | +1 (ensemble query) | open (research item) | after S5's target lands the hook bodies are concrete and the points axis is a new transform per stage; the remaining radius is the ABI bump, which §2.9 allows with a version bump. Re-run after #99's research note. |
