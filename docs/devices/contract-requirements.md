# Device contract requirements — derived from every analysis's actual needs

What `modules/devices/src/contract.zig` must be: every member justified by a
named consumer at a performant call pattern; no extras. Ground truth =
grep of `modules/analysis/src/` (batch.zig hook table, converger.zig,
per-analysis files), `src/builder.zig`, `modules/devices/src/kernel*.zig`,
`modules/analysis/src/problem/dyn.zig`, plus all 23 `docs/analysis/*.md`
(future analyses marked **future**). Requirements doc — no code changes.

Consumption is mediated: analyses never touch `D` directly. They call
`Circuit` methods (`root.zig`), which fan out over the type-erased
`Hooks` vtable built per device type in `batch.zig` (`DeviceBatch(D).hooks`,
line 269–291). So "consumer" below names both the batch hook and the
analysis that drives it. The GPU megakernel (`kernel.zig` driver +
`kernel_common.zig` physics + `kernel_stub.zig` per-model TUs) is the
second direct consumer; `dyn.zig` (.so ABI) compiles `batch.zig` inside
the plugin, so it inherits the CPU surface wholesale (`layoutHash` pins
compatibility — a `NoiseSource` layout change auto-invalidates cached .so).

## 1. Requirements matrix: analysis → contract members

Call frequency legend: **build** = once at circuit build/freeze;
**run** = once per analysis invocation; **step** = per accepted
timestep/sample; **iter** = per Newton iteration (hot).

| Analysis (impl) | Members needed | Frequency | Why |
|---|---|---|---|
| `.op` (`dc/op.zig`) | `eval` (+`evalFromPrep`/`PrepCache`/`computePrep`), `limit`, `limit_flag_unknowns`, `seed`, `attempt`, `updateState`/`stateCtl`, `collapse`, `precompute`, `constant_g` | eval/limit: **iter**; seed: **run** (cold start); attempt: per homotopy λ; collapse/precompute: **build** | Newton with SPICE limiting (`converger.zig:247` `applyLimits`), MODEINITJCT seeding (`op.zig:26`), gmin/source stepping (`op.zig:132` `applyAttempt`), FSM commit (`op.zig:44`) |
| `.dc` sweep (`dc/dc.zig`) | op set + `mc_param` (via `collectParams`), `precompute`/`computePrep` (via `recompute`) | recompute: per sweep point | swept param written into Model/Instance f32, then `ckt.recompute()` re-derives prep (`dc.zig:51,63`) |
| `.tran` (`tran/tran.zig`, also envelope, tran front of pss) | `eval`+`q` (+`qFromPrep`), `constant_c`, `limit`, `updateState`/`stateCtl`, `gatherHistSignals`/`histInject`/`delays`/`n_hist_signals`, `nextBreakpoint` | eval/q: **iter**; state/history/breakpoint: **step** | companion residual F+αq; step reject on state flip (`tran.zig:450–550`); delay lines (`tran.zig:291,365,585`); source breakpoints (`tran.zig:393`); `minDelay` caps dt (`tran.zig:370`) |
| `.ac`/`.sp`/`.stb`/`.tf`/`.pz` (`ac/*.zig`, `dc/tf.zig`, `eigen/pz.zig`) | `eval`, `q` | **run** (one linearization at x_op; G,C planes off the AD pass) | these consume only `ckt.eval`/`denseG`/`denseC` — verified, no other ckt hooks called |
| `.noise` (`ac/noise.zig:94`) | `noise_gens` (via `collect_noise`) | **run** (once at x_op; covers whole f sweep) | adjoint sweep, psd = 4kT·g per source |
| `.pnoise` (`pss/pnoise.zig:190`) | `noise_gens` | **run** today (x_op-frozen); **future**: per PSS sample via `noisePsd` | cyclostationary upgrade needs PSD as pure fn of arbitrary x — `collect_noise` hook already takes arbitrary `x` |
| `.tran_noise` (`tran/tran_noise.zig:244`) | `noise_gens` | **run** today; **future**: per accepted step via `noisePsd` (optional fidelity upgrade) | bias-frozen white sources injected per step |
| `.pss` shooting / `.hb` (`pss/pss.zig`, `pss/hb.zig`) | tran set (shooting) / `eval`+`q` per time sample (HB) | **iter** / per sample | pss records/injects history over the period (`pss.zig:83,120,160`) |
| `.pac` (`pss/pac.zig`) | `eval`, `q` | per PSS sample (dense G(t_k), C(t_k)) | conversion matrix from sampled linearizations — no device additions |
| `.disto` (`post/disto.zig`) | `eval` | n+1 evals at perturbed x (**run**) | d²F = FD of analytic Jacobian — deliberately no second-derivative hook |
| `.four` (`post/four.zig`) | — | — | postprocessing only |
| MC / ensemble (`sweep/mc.zig`, `problem/par.zig`) | `mc_param`, `precompute`/`computePrep` (recompute), `PrepCache` dedup + `set_lanes` | per sample | `collectParams` primary marking (`batch.zig:706`); lane-major dedup caches |
| `.sens` FD (`sweep/sens.zig`) | `mc_param`/params via `collectParams`, recompute | per param, per FD solve | perturb-and-re-solve today |
| temp sweep (`sweep/temp_sweep.zig:83`) | `Instance.temp` **field convention** (not a decl; hook `set_temp` at `batch.zig:278`) | per temp point | device-internal temp physics re-derived by `recompute` |
| **future** `.pxf` (docs/analysis/pxf.md) | same as pac (adjoint = transpose solve) | — | **no device-contract additions** |
| **future** `.qpss` (docs/analysis/qpss.md) | `eval`+`q` on multi-tone time grids | — | **no device-contract additions** (basis generalization is solver-side) |
| **future** `.dcmatch` + adjoint sens (docs/analysis/dcmatch.md, docs/solvers/parameter-derivative-stamps.md) | ∂F/∂p stamps. First rung: **stamp-level FD over existing `eval` — zero contract change**. Analytic `evalp`: **future, do not add yet** | one batch pass per output | dcmatch's own doc: "FD-stamp fallback needs no contract change" |
| **future** noise upgrades (docs/devices/noise-contract.md) | `noisePsd` + `PsdTerm` — **the one addition required now** | noise: **run**; pnoise: per PSS sample; tran_noise: per step | shot/flicker/correlation are un-fakeable from the Jacobian (§3) |

## 2. Verdict per current member

| Member | Verdict | Consumer (file:line) |
|---|---|---|
| `U`, `num_ports`, `Model`, `Instance`, `eval` | **keep** (required) | everything: batch.zig eval loop, kernel_common.zig:143 `isDevice`, dyn.zig vtable, builder.zig |
| `q` | **keep** | batch.zig:463 (companion/C plane), kernel_common.zig:259, tran/ac/hb/pz |
| `limit` | **keep** | batch.zig:542 via converger.zig:247 (per-iter), kernel_common.zig:316, kernel_stub.zig:69. Cleanup: validated **twice** in `validate()` (contract.zig:547 and :589) — delete the duplicate |
| `limit_flag_unknowns` | **keep, underspecified** | batch.zig:551, kernel.zig:120; declared by bjt.zig:853, mos1.zig:684, mos2.zig:546. In the allowlist but **never shape-checked** in `validate()` — add `[k]D.U` check |
| `seed` | **keep** | batch.zig:504 via op.zig:26 (cold-start only) |
| `collapse` | **keep** | builder.zig:212 (build-time), dyn.zig:136 vtable |
| `initState`/`updateState`/`stateCtl`/`State` | **keep** | batch.zig:106,276,277,590; tran.zig:450–550 step reject/commit, converger.zig:252 flip detection |
| `histInject`/`gatherHistSignals`/`delays`/`n_hist_signals` | **keep** | batch.zig:655,665,674; tran.zig:291,365,370,585; pss.zig:83,120,160 |
| `attempt` | **keep, change**: the 3-arg `fn (Model, Instance, f64) Model` alternative (contract.zig:586) is **unusable** — batch.zig:616 calls `D.attempt(s, lambda)` (2-arg) unconditionally, no device declares 3-arg. Delete the alternative from `validate()` | batch.zig:616 via op.zig:132 homotopy |
| `u_kinds` | **keep** | batch.zig:275/518 (`markCurrentRows` — current-row tolerance marking, problem.zig:128; seeding mask) |
| `g_pattern_override` / `c_pattern_override` | **dead — delete or wire in.** Grep: zero consumers outside `modules/devices/` and FastVAF codegen. `addPattern` (batch.zig:35–44) stamps dense n_u×n_u regardless. ~60 devices + the VA generator emit them for nothing. Either make `addPattern`/GPU pack consume them (real sparsity win for big MOSFETs: bsim4 is 9×9 dense today) or drop the decls + allowlist entries. Do not keep a validated-but-unread decl | none |
| `noise_gens` | **keep** | batch.zig:284/746 `collectNoise`; ac/noise.zig:94, pnoise.zig:190, tran_noise.zig:244 |
| `mc_param` | **keep** | batch.zig:706 (`collectParams` primary), mc.zig:221 |
| `PrepCache`/`computePrep`/`evalFromPrep`/`qFromPrep` | **keep** | batch.zig:124–145,437,463,645 (hot loop + dedup), kernel_common.zig:236,261 |
| `precompute` | **keep** | batch.zig:118,635 (`reprep` — recompute after every param/temp/attempt change) |
| `constant_g`/`constant_c` | **keep** | batch.zig:49–50,218–219 (baseline + `evalNewton` stamp skip — per-iteration win) |
| `nextBreakpoint` | **keep** | batch.zig:683 via tran.zig:393 |
| `Value`/`Dual`/`fmath`/`limits`/`nU`/`uKinds`/`Entry`/`NoiseGen`/`UpdateResult`/`StateCtlOp`/`UnknownKind`/`evalValues`/`qValues` | **keep** (infrastructure) | devices, kernel_common.zig:12,199–201, dyn ABI, device unit tests |
| `HistoryReq` | **dead — delete.** Grep: sole occurrence is its own definition (contract.zig:264); the history path uses `delays()` + `HistoryBuffer.init(gpa, D.n_hist_signals, 8192)` instead | none |
| `espice_*` allowlist prefix | **keep** | dyn.zig plugin ABI exports |
| `Instance.temp` field | **keep as documented convention** (field, not decl) | batch.zig:278 `set_temp`, temp_sweep.zig:83 |

## 3. Additions required

### 3.1 `noisePsd` + `PsdTerm` — add now — **APPLIED 2026-07-12** (validation + allowlist in contract.zig; `HistoryReq`, 3-arg `attempt`, dup `limit` validation also removed; `limit_flag_unknowns` now shape-checked. Pattern-override deletion deferred until the FastVAF worktree merges — codegen emits them.)

Justified by three named consumers (`ac/noise.zig`, `pss/pnoise.zig`,
`tran/tran_noise.zig`) and the ponytail marker already in the code
(batch.zig:757: shot/flicker skipped pending this hook). Refinements vs
the draft in [noise-contract.md](noise-contract.md):

- **Drop `gen: u8`** from `PsdTerm`. The return is
  `[noise_gens.len]PsdTerm`; position *is* the generator index. A
  redundant index is a bug vector, not information.
- Everything else stands: frequency-parametrized (`white + flicker/f^ef`)
  so ONE device eval covers the whole f sweep (AC noise stays a **run**-
  frequency hook); pure function of arbitrary `x` so pnoise calls it per
  PSS sample and tran_noise per step **with no signature change** — the
  existing `collect_noise(ctx, x, gpa, list)` hook already takes arbitrary
  `x` (root.zig:669). Per-sample callers must reuse a caller-owned list
  (`clearRetainingCapacity`), analysis-side detail, no contract impact.
- Real `corr` only; add `corr_im` when a reference model (BSIM4 tnoiMod2 /
  PSP103 c_igid) actually lands and demands it.

```zig
// contract.zig additions
pub const PsdTerm = struct {
    /// Frequency-flat PSD [A²/Hz] at this x. thermal: 4kT·g; shot: 2q|I|.
    white: f64,
    /// 1/f numerator: S(f) = white + flicker / f^ef.
    flicker: f64 = 0,
    ef: f64 = 1,
    /// Correlated partner: index into noise_gens, real coeff c
    /// (S_xy = c·sqrt(S_xx·S_yy)). corr_im deferred until a model needs it.
    corr_with: ?u8 = null,
    corr: f64 = 0,
};

/// Optional. Requires noise_gens. Pure function of ANY state vector —
/// no allocation, no state writes, plain f64 (kernel-style straight-line
/// math via fmath; no S-generic needed — no derivatives of PSDs are taken).
/// Term k describes noise_gens[k]. Devices without it keep the current
/// thermal-off-the-Jacobian fallback in batch.zig collectNoise.
pub fn noisePsd(x: [n_u]f64, m: *const Model, i: *const Instance)
    [noise_gens.len]PsdTerm;
```

`validate()` addition: if `noisePsd` declared, require `noise_gens` and
check the exact signature (`expectFn` — it is not S-generic, so fully
checkable). Allowlist: `noisePsd`.

`root.NoiseSource` grows `white/flicker/ef/corr_with/corr` (replacing
lone `conductance`); dyn `.so` cache invalidation is automatic —
`NoiseSource` is in `layoutHash` (dyn.zig:71).

### 3.2 `evalp` (∂F/∂p dual lane) — future, do not add yet

Honest no-speculation call: dcmatch/adjoint-sens are **not implemented**,
and [dcmatch.md](../analysis/dcmatch.md) + [parameter-derivative-stamps.md](../solvers/parameter-derivative-stamps.md)
both state the stamp-level FD fallback (perturb p, re-eval ONE device via
existing `eval`, difference the local residual — O(1) evals/device, no
extra Newton solves) **needs no contract change** and is the correct first
rung. Add `evalp` only when a landed dcmatch/adjoint-sens implementation
measures FD-stamp accuracy or cost as insufficient. Reserved signature
(from the stamps doc, so the name is not re-designed later):

```zig
// FUTURE — not in the allowlist yet:
pub fn evalp(comptime S: type, x: [n_u]S, p: S,
             m: *const Model, i: *const Instance, t: f64) [n_u]S;
// p = the mc_param field routed through S; AdScalar(n_u+1) seeding.
```

No other future analysis (pxf, qpss, pac upgrades) demands any contract
member beyond `eval`/`q` at arbitrary (x, t) — already the core contract.

## 4. Proposed contract surface (target)

Diff vs current: **added** `noisePsd`/`PsdTerm`; **removed**
`g_pattern_override`, `c_pattern_override` (dead), the 3-arg `attempt`
form (unusable); **changed** `limit_flag_unknowns` (now validated),
duplicate `limit` check deleted. Everything else unchanged.

```zig
// ---- required --------------------------------------------------------
pub const U: type;                  // dense enum(u8) 0..n-1; nU = |U|
pub const num_ports: usize;         // 1..|U|; builder node binding, dyn ABI
pub const Model: type;              // defaulted value-type struct (SoA, GPU-copyable)
pub const Instance: type;           // same
pub fn eval(comptime S: type, x: [n]S, m: *const Model, i: *const Instance, t: f64) [n]S;
// hot: per Newton iteration, comptime-dispatched per batch, AD scalar S,
// no allocation; must instantiate on nvptx64/amdgcn (fmath, no libcalls)

// ---- optional: physics -------------------------------------------------
pub fn q(comptime S: type, x, m, i, t) [n]S;          // charges; tran/ac/hb/pz
pub const PrepCache: type;                             // bias-independent prep
pub fn computePrep(m: *const Model, i: *const Instance) PrepCache;
pub fn evalFromPrep(comptime S: type, x, p: *const PrepCache, m, i, t) [n]S;
pub fn qFromPrep(...) [n]S;                            // required iff q + PrepCache
pub fn precompute(i: *Instance, m: *const Model) void; // instance param prep; reprep()
pub const constant_g: bool;                            // baseline stamp, Newton skip
pub const constant_c: bool;

// ---- optional: Newton robustness ---------------------------------------
pub fn limit(m: *const Model, i: *const Instance, x_new: [n]f64, x_old: [n]f64) [n]f64;
pub const limit_flag_unknowns: [k]U;   // which limited unknowns force re-iteration
                                       // (NOW validated: array of U)
pub fn seed(m: *const Model, i: *const Instance) [n]?f64;  // MODEINITJCT, cold start
pub fn attempt(m: Model, lambda: f64) Model;   // homotopy scaling — 2-arg ONLY
                                               // (3-arg variant removed: unusable)

// ---- optional: topology (build-time) ------------------------------------
pub fn collapse(m: *const Model, i: *const Instance) [n]?u8;  // zero-R node merge
pub const u_kinds: [n]UnknownKind;     // current-row tolerances (abstol_i)

// ---- optional: state machine (CPU-only: sequential accept/reject) -------
pub const State: type;
pub fn initState(m: *const Model, i: *Instance) State;
pub fn updateState(m: *const Model, i: *Instance, x: [n]f64, s: *State) UpdateResult;
pub fn stateCtl(m: *const Model, i: *Instance, s: *State, op: StateCtlOp) bool;

// ---- optional: history / delay lines (CPU-only: ring buffers) ------------
pub const n_hist_signals: u32;
pub fn gatherHistSignals(x: [n]f64) [n_hist_signals]f64;
pub fn histInject(m: *const Model, lookup: anytype, t: f64) [n]f64;
pub fn delays(m: *const Model) [k]f64;

// ---- optional: transient scheduling --------------------------------------
pub fn nextBreakpoint(m: *const Model, t: f64) ?f64;   // per step, cheap scan

// ---- optional: noise (in-device convention) -------------------------------
pub const noise_gens: [k]NoiseGen(Self);               // branch + kind metadata
pub fn noisePsd(x: [n]f64, m: *const Model, i: *const Instance)
    [noise_gens.len]PsdTerm;                           // ADDED — see §3.1
// straight-line f64 math; kernel-compatible by construction, consumed on
// CPU first (noise passes are run/sample-frequency, not iter-frequency)

// ---- optional: statistical -------------------------------------------------
pub const mc_param: []const u8;        // principal f32 param (MC, future evalp)

// ---- field conventions (not decls) -----------------------------------------
// Instance.temp: f32  → set_temp hook + recompute (temp sweep)
// espice_* pub decls  → dyn plugin ABI, allowlisted by prefix
```

Performance notes (unchanged invariants the surface must preserve):

- Comptime dispatch: every hook is resolved per device type at comptime;
  the only runtime indirection is one vtable call per batch.
- No allocation in any per-iteration or per-step hook; `collect_noise`
  allocates but is run/sample-frequency (per-sample callers reuse the list).
- SoA batch compatibility: `Model`/`Instance` stay defaulted value-type
  structs (`validateDefaultedStruct`) — this is what makes `gpuPack`'s
  byte-copy and dyn's `setParam` field walk sound. Any addition taking
  `*Model`/`*Instance` const keeps batch arrays shareable.
- GPU megakernel compatibility: every hook that could ever run at iter
  frequency (`eval`, `q`, `*FromPrep`, `limit`) already compiles for
  nvptx64/amdgcn. `State`/history hooks are explicitly CPU-only
  (`gpu_ok = !has_state and !has_hist`, batch.zig:770) because step
  accept/reject and ring buffers are host-side sequential control flow.
  `noisePsd` is kernel-style (fixed-size in/out, straight-line) but ships
  CPU-only; a GPU collection pass is a later, measured addition.

## 5. GPU section

Consumed by the megakernel today (kernel.zig / kernel_common.zig /
kernel_stub.zig, read in-tree):

| Member | Where |
|---|---|
| `U` (nU), `Model`, `Instance` | kernel_common.zig:143 `isDevice`, blob SoA pointers (off_models/off_instances) |
| `eval` / `evalFromPrep` + `PrepCache` (packed prep_cache/prep_group) | kernel_common.zig:236–241 |
| `q` / `qFromPrep` | kernel_common.zig:259–263 (TranEnv companion) |
| `limit` | kernel_common.zig:316 `limitBatch`; exported per-model as `arp_lb_<name>` (kernel_stub.zig:69) |
| `limit_flag_unknowns` | kernel.zig:120 (re-iteration gating, mirrors batch.zig:551) |

CPU-only (never cross the blob): `seed`, `collapse`, `precompute`,
`computePrep` (host runs them before pack), `attempt` (host mutates
models, re-packs), `State`/`initState`/`updateState`/`stateCtl`,
history hooks (`gpu_ok` excludes those batches entirely), `nextBreakpoint`,
`u_kinds`, `mc_param`, `noise_gens`/`collectNoise`.

Impact of the additions:

- **`noisePsd`: no kernel ABI change.** It is not called from
  `arp_solve`/`arp_tran`; noise collection stays a host pass. If a GPU
  collection kernel is ever measured to matter (pnoise per-sample over
  huge circuits), it is a NEW exported symbol per model
  (`arp_np_<name>`, same stub pattern as `arp_lb_`) writing a fixed-size
  `[count × noise_gens.len]PsdTerm` slab — additive, nothing existing moves.
- **`evalp` (future): no ABI change when it lands** — same stub-TU export
  pattern; the extra AdScalar lane is a register-pressure question per
  model (ptxas OOM history: measure per TU), not a layout question.
- **Deleting `g/c_pattern_override`: no GPU impact** — the kernel never
  read them.

## Sources

All in-tree, read at HEAD: `modules/devices/src/contract.zig`,
`kernel.zig`, `kernel_common.zig`, `kernel_stub.zig`;
`modules/analysis/src/problem/{batch,dyn,problem}.zig`, `root.zig`,
`helper/converger.zig`, `dc/{op,dc,tf}.zig`, `ac/{noise,sp,stb}.zig`,
`pss/{pss,hb,pac,pnoise}.zig`, `tran/{tran,tran_noise,envelope}.zig`,
`sweep/{mc,sens,temp_sweep}.zig`, `post/disto.zig`, `eigen/pz.zig`;
`src/builder.zig`; `docs/analysis/*.md` (23),
`docs/devices/noise-contract.md`,
`docs/solvers/parameter-derivative-stamps.md`.
