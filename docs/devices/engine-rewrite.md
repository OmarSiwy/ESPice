# Device engine rewrite — batch/par/dyn/load → one gompute file

Status: **design** (files not yet deleted). The four files below are documented
here (what + why + the interface consumers depend on), then replaced by a single
`engine.zig` built on gompute. Deletion happens *as* the replacement lands, never
before — they are the simulator's only device engine.

---

## What each file does today, and why it exists

### `batch.zig` (1241 lines) — the type-erased device engine
**What:** turns a comptime contract device `D` into a runtime, type-erased
`Batch` of many same-type instances laid out SoA, and evaluates them into the
MNA matrix.
**Why it exists:** the solver holds a heterogeneous list of device batches
(resistors, diodes, …) behind one vtable; it can't be generic over every `D`.
**Public surface consumers bind to** (analysis/Circuit.zig, analysis/root.zig):
- `Batch` — one device-type's runtime vtable (eval, evalNewton fn-ptrs; count, n_u).
- `Hooks` — cold-path dispatch table (set_lanes, apply_limits, seed, update_state,
  state_ctl, set_temp, record/inject_history, collect_params, collect_noise, …).
- `Proto` — accumulation store while building one device type.
- `Planes` — the output slabs (`g_vals`, `c_vals`, `rhs`, `q_vec`).
- `PatternBuilder` / `PatternView` — CSC sparsity accumulation + lookup.
- `ParamRef`, `NoiseSource`, `NoiseGen`, `NoiseGenKind`, `StateCtlOp`, `UpdateResult`.
- `ProtoStore(D)`, `DeviceBatch(D)` — the comptime D → type-erased factory.
- `HistoryBuffer`, `HistLookup` — delay-line (tline) history.
Internally it also had the derivative scalar path (via the now-deleted
`eval_core`) and the GPU-pack hooks (via the deleted `gpu_abi`) — both dangling
now.

### `par.zig` (434 lines) — CPU multi-threaded eval
**What:** persistent worker threads; partitions instances across lanes, each lane
stamps into a private slab then SIMD-reduces into the caller's planes.
**Why:** device eval is the Newton hot loop; one thread underuses the CPU.
**Public surface:** `ParEval` (`init`, `deinit`, `eval`, `evalNewton`),
`default_min_instances`, `EvalTask`.

### `dyn.zig` (304 lines) — runtime device ABI (dlopen)
**What:** C ABI a compiled `.so` device exports/consumes so a runtime-loaded VA
model plugs in like a builtin. `layoutHash` guards ABI/layout drift.
**Why:** netlist `.va`/`.v` cards compile to a `.so` and load at runtime (see
load.zig); dyn is the handshake + vtable bridge.
**Public surface:** `DeviceVtable`, `abi_version`, `layoutHash`, `exportDevice(D,name)`,
`deviceVtable(D,name)`, `LoadedDevice` (`open`, `close`).

### `load.zig` (176 lines) — runtime compile + cache + registry
**What:** for a netlist HDL card, compile the model to a `.so` (via FastVAF), cache
by content-hash, dlopen, register by name. Parallel compile of many cards.
**Why:** the app never rebuilds; a foreign model is compiled once and cached.
**Public surface:** `ensureLoaded`, `ensureAllLoaded`, `get(name)`, `isEmpty`.
Keep as-is in spirit (it is already thin) — folds into the new file, unchanged
logic, minus the dangling `gpu_pack` nulling in dyn.

---

## Why gompute changes the shape (the real API)

gompute (read from source, not README):
- `map(name, Value, Parameters, func, opts) -> Spec`, where
  `func(x: Value, p: Parameters) Value` is **1-D elementwise**.
- `Kernel(Spec, .cpu|.cuda|.hip)`: `.cpu` = plain loop over `[]Value`; cuda/hip
  upload → launch → download. `AutoKernel(Spec)` probes GPU, falls back to CPU.
- `RawKernel(name, backend)` (arbitrary gather/scatter) is **cuda/hip only** — no
  CPU backend. So the "same code CPU+GPU" guarantee lives in the `map` path, not raw.

**Consequence:** device eval must be expressed as a **per-instance map**, not a
hand-written scatter kernel. Decomposition:

```
host gather ─► [InstanceIn] ──gompute map(evalInstance(D))──► [InstanceOut] ─► host scatter
     (sparse index tape)         (pure physics, CPU or GPU)        (into G/C/rhs)
```

- `Value = InstanceIn`  = the gathered eval point for one instance: `[n_u]f64`
  node values + a model index + packed instance state.
- `Parameters` = shared per-launch: `t`, analysis flags, and slices of the model
  and instance arrays (device pointers on GPU).
- `func = evalInstance(D)` = the contract `D.eval` run with the derivative scalar,
  emitting `residual[n_u]` + `jac[n_u*n_u]` (+ optional `q`) into `InstanceOut`.
- Gather (build `InstanceIn` from `x` via the index tape) and scatter (add
  `InstanceOut` into the sparse planes) stay on the **host** — cheap, sparse,
  branchy; exactly what does NOT belong in a map kernel.

This deletes: the dual CPU/GPU sink (`eval_core`), the hand-rolled
ptxas/nvlink megakernel + problem-blob ABI (`gpu_abi`, `kernel*`) — gompute owns
compile+launch. `par.zig` (CPU threads) is subsumed by gompute's `.cpu` backend
loop (and its own threading if any); if we still want host threads for the
gather/scatter halves, that is a small pool, not a 434-line subsystem.

The derivative scalar (`Value`/`Dual`, removed from contract.zig) lives **here**,
next to `evalInstance`, since the engine is the only thing that instantiates the
device physics with a concrete `S`.

---

## Target: `engine.zig` (one file)

Replaces batch + par + dyn + load. Public surface it must keep (consumer-driven):
`Batch`, `Hooks`, `Proto`, `Planes`, `PatternBuilder`, `PatternView`, `ParamRef`,
`NoiseSource`/`NoiseGen`/`NoiseGenKind`, `StateCtlOp`, `UpdateResult`,
`HistoryBuffer`/`HistLookup`, `ProtoStore(D)`/`DeviceBatch(D)`, plus the runtime
loader (`ensureLoaded`/`ensureAllLoaded`/`get`/`isEmpty`) and dyn ABI
(`DeviceVtable`/`LoadedDevice`/`exportDevice`). Same names → consumers
(analysis/Circuit.zig, builder.zig, engine.zig, main.zig) keep compiling.

### Open decision (needs a call before writing)
How much of batch.zig's machinery is **kept** vs **dropped** in the rewrite?
Candidates that add real value but also real code: prep-cache eval dedup,
constant-Jacobian skip flags, SPICE limiting pass, noise generators, delay-line
history, node collapse. The clean-slate ideal is "eval + gather/scatter + the
loader"; the working-simulator reality is that analysis calls the limiting,
noise, history, and state-machine hooks today. Recommend: **port the hot path
first** (gather → gompute eval → scatter → Newton), stub the cold hooks, and
re-add each cold feature behind a green build — rather than one 1500-line
big-bang.
```
