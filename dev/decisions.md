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

### S5: GPU evaluation and LU hooks

- **Axis**: backend at runtime: host walk or a live GPU context.
- **Evidence**: one implementation each (`analysis/gpu.zig`, `analysis/gpu_lu.zig`). The "host" case is the absence of a hook.
- **Owner**: analysis (`src/analysis/Circuit.zig:63` `GpuHook`, `:98` `LuHook`).
- **Rung**: 8 today (`*anyopaque` plus 11 function pointers). This **breaks §2.1**: rung 8 is forbidden on a hot path, and `eval_planes` runs once per Newton evaluation. With one adapter the seam is speculative.
- **Target (P3)**: concrete optional contexts (`?*gpu.Context`, `?*gpu_lu.GpuLu`) owned by the executor; the which-backend branch moves into the spine that calls `evalNewton`, so `Circuit` no longer knows about the GPU. Rung 1 with one branch per evaluation.
- **Cost (target)**:
  - residue: one predictable branch per evaluation
  - change radius for a second GPU backend: 0 (HIP and CUDA already share `gpu.zig` through gompute)
  - interface weight: −1 (`GpuHook` removed)
- **Drills passed**: D3 is open
- **Proof**: n/a at rung 1
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
- **Evidence**: three engines today (`src/solver/direct.zig:43-45`).
- **Owner**: solver (`src/solver/direct.zig` `Solver`).
- **Rung**: 4 in substance, written as three optionals with an "at most one live" comment. This is an implicit union: the type allows zero or several live engines.
- **Target (P3)**: `engine: union(enum) { sparse: SparseLu, tridiag: Tridiag, bbd: Bbd }` with exhaustive switches in `factor`, `refactor`, `solve`, `solveT`. Same code, and the compiler enforces "exactly one".
- **Cost**:
  - residue: one switch per factor and per solve, as today
  - change radius for one more engine: 4 compiler-listed arms
  - interface weight: unchanged for callers
- **Drills passed**: none drilled
- **Proof**: pending, P3 (probe the union switch against the current optional checks: expected IDENTICAL or NEGATIVE)
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
- **Owner**: device (`src/device/loader.zig`, `Library.load`).
- **Rung**: 9, ABI boundary. Separately built code: it cannot be a build-time parameter.
- **Cost**:
  - residue: one `dlopen` and symbol lookup per model per Problem (cold); evaluation then runs through S2
  - change radius for one more HDL: 0 bodies (VerA's frontend)
  - interface weight: `arp_abi_version`, `arp_layout_hash`, `arp_device`
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

## Drills

Taken from the open GitHub issues (2026-10-17). Radii are counted on the code
at `66ec7fe`; a drill marked "re-run" is run again when its fix lands.

| ID | Change | Source | Edits (file: function or row) | Radius | Weight Δ | Verdict | Fix |
|---|---|---|---|---|---|---|---|
| D1 | Set a `.param` on a live Problem and re-run its queries without a re-parse | #101 | `espice.zig`: new `Problem.set_param` (0), `Problem.init` keeps the parsed `Netlist` in the session arena instead of parse scratch (1); `c_api.zig`: new `espice_set_param` (0); `include/espice.h`: one decl (0); `frontend/netlist.zig`: `setLive` today writes a `*const Netlist` through `@constCast`, so a second writer appears (1); `frontend/prepare.zig`: `buildRun` reached from the facade (1, through the prepare↔variants cycle); `analysis/session.zig`: new `Session.rebind(circuit)` (0) | 3 | +1 (`set_param`) | fail | restructure (P3): `netlist.applyLive` drains a `live_requests` table that variants and the facade append; the prepare spine owns the per-point loop. Expected radius 1 (`Problem.init`). Re-run. |
| D2 | `.hdl` device with more than 64 unknowns compiles and evaluates | #117 | `device/eval.zig`: `Dual` (`:89` refuses > 64 lanes), `addPattern` (`:517-533`, u64 row masks), `limit` writes mask (`:545`), `maskOf` (`:572-585`), `markCurrentRows`, `collectAcDyn` (unrolled n_u², `:1749`), `permuteInPlace` (`:1020`) | 7 | 0 | fail | restructure: the mask type becomes a comptime function of `n_u` (`std.bit_set.StaticBitSet(n_u)` or a dense-fallback variant chosen at comptime), so S3 handles any width at radius 0 afterwards. Lands with #117, not in this pass. |
| D3 | GPU ensemble: many same-pattern runs batched in lockstep | #99 | new `analysis/sweep/ensemble.zig` (0); `analysis/gpu.zig`: context init and `eval_planes` gain a points axis (2); `analysis/gpu_lu.zig`: batched refactor (1); `device/eval.zig` kernel exports over points × instances (1, frozen ABI → `abi_version` bump); `sweep/lanes.zig solveLanes` (1) | 5 | +1 (ensemble query) | open (research item) | after S5's target lands the hook bodies are concrete and the points axis is a new transform per stage; the remaining radius is the ABI bump, which §2.9 allows with a version bump. Re-run after #99's research note. |
