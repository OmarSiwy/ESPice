# GPU Device Evaluation — What the Hardware Actually Allows

## 1. The constraint nobody can optimize around

Everything below follows from one measurement. On the development machine
(RTX 4060 Laptop, sm_89, 24 SMs @ 1.89 GHz, against an i9-14900HX, 24C/32T):

| | GPU | CPU |
|---|---|---|
| **f64 FMA** | **152.7 GFLOP/s** | **1449 GFLOP/s** (32 threads) · 90 (1 thread) |
| f32 FMA | 10 477 GFLOP/s | — |
| f64 : f32 | **1 : 69** | 1 : 2 |
| f64 `rcp.rn` | 13.8 Gop/s | — |
| memcpy bandwidth | ~250 GB/s (VRAM) | 47 GB/s |
| host↔device | Gen4 x8, 12.6 GB/s, 4.31 µs round trip | — |

Consumer Ada carries **2 FP64 cores per SM**. Every value in a device model is
`f64`. So the GPU has **1/9.5 of this CPU's f64 throughput**, and measured f64
FMA lands at 84 % of the 181 GFLOP/s the part is theoretically capable of —
there is no tuning left on the table, the ceiling itself is low.

The consequence is worth stating plainly, because it is the opposite of the
usual intuition: **a straight f64 port of device evaluation cannot beat this
CPU on arithmetic.** What the GPU still has is ~5× the memory bandwidth and
tens of thousands of threads, and that is what the win below is actually made
of — device evaluation is a bandwidth-and-parallelism problem, not a FLOP
problem, right up until a compact model turns it into one.

Where the GPU is flop-bound it loses badly. The emitted `bsim4va` kernel
carries **142 990 f64 operations**, 739 f64 divides and 3 530 predicates in
7 104+ virtual 64-bit registers against a 255-register file — it spills to
local memory and runs at roughly 16 % occupancy. That is why those models are
excluded from GPU emission entirely (§4).

## 2. Where the GPU enters an analysis

Exactly one place: `Circuit.eval` and `Circuit.evalNewton` consult
`GpuHook.eval_planes` and, if set, hand the whole stamp to the device.

This is deliberate and it is the difference between transient working and not.
An earlier design put the GPU behind `solve_newton`, replacing the *solve*.
`tran.TranHook.assemble` calls `evalNewton` and then does its own companion-RHS
math on the planes:

```
rhs += alpha*(q - q_prev)          # backward Euler
vals() -> combineGC(alpha, a_vals) # A = G + alpha*C
```

A GPU path that replaces the solve skips all of that. One that replaces only
the *stamp* composes with it untouched — and equally with limiting, history
injection, and every other host-side layer. `TranHook` never declared
`gpu_eligible`, and `simulate_tran` was null, so before this change **`.tran`
never touched the GPU at all**.

Routing the stamp also picks up `hb`, `qpss`, `pnoise` and `tran_noise`, which
call `ckt.eval` in a loop and were CPU-only for the same reason.

### The baseline is deliberately given up

The device path ignores `has_baseline`. `g_base` holds the constant Jacobian
contribution of **every** batch, GPU-eligible ones included, and `GpuSink` has
no `skip_g` — so starting from the baseline and letting kernels stamp on top
would double-count. The GPU path zeroes and restamps instead. That costs the
constant-Jacobian optimization and is a real loss on linear-heavy circuits.

## 3. Per-iteration cost, and what was removed

The device eval is a strict chain — upload `x`, zero the planes, launch, download
the planes — and the chain used to be paid in full, synchronously, per Newton
iteration. On a 100×100 resistor grid (`nnz` ≈ 50 000):

| step | before | after |
|---|---|---|
| `x` upload, 80 KB | 13 µs (blocking, pageable) | ~2 µs memcpy + async |
| zero `g`/`rhs` (+`c`/`q`) | 6–15 µs (D2D from a resident zero block) | `cuMemsetD8Async` |
| launch | 1.3 µs | 1.3 µs |
| sync | `cuCtxSynchronize` (whole device) | `cuStreamSynchronize` |
| download `g`, 400 KB | 45 µs (blocking, pageable) | issued **before** host work |
| download `rhs`, 80 KB | 13 µs (blocking, pageable) | issued **before** host work |

Three changes, in order of value:

1. **Pinned host buffers.** `cuMemcpy*Async` on *pageable* memory is
   asynchronous in name only — the driver stages it through an internal pinned
   buffer and blocks. Only `cuMemHostAlloc` memory actually overlaps.
2. **Downloads issued before the host batches run.** The ineligible devices
   (`vsource` declares `State`, so a mixed circuit is the normal case) stamp the
   host planes while the D2H copies drain. ~58 µs leaves the critical path.
3. **A dedicated stream.** The NULL stream implicitly synchronizes with every
   other blocking stream, so copies and launches had to leave it together or
   they would serialize anyway.

## 4. Two gates

**Work gate** (`gpu_context.zig`, `ESPICE_GPU_MIN_WORK`, default 200 000).
`--gpu` bypasses this gate, including for tiny or all-linear circuits. It still
requires available hardware and eligible kernels. `--backend auto` retains the
gate; the last `--gpu` or `--backend` option wins.
Scatter work is `count · n_u²` summed over eligible batches — the number of
`atom.global.add.f64` a batch issues per iteration, which for the devices
`gpuEligible` admits today *is* the kernel. Measured: 6 atomics × 20 K
instances = 9.5 µs, × 200 K = 76 µs, against a ~100 µs round trip. Below the
gate the GPU cannot win, so `init` declines **before the first driver call** —
which is also what makes `cuInit` lazy. That matters: `cuInit` costs 113.7 ms
and retaining the primary context another 80.7 ms, and a small netlist used to
pay all 194 ms just for passing `--gpu`.

**Model size cap** (`build.zig`, `gpu_max_model_bytes`, 80 KB of source).
Above it a model gets no GPU kernel at all. The cost being avoided is not
subtle:

| model | source | PTX | cold `cuModuleLoadData` |
|---|---|---|---|
| mos9 | 20 KB | 731 KB | 11.4 ms |
| bjt | 20 KB | 895 KB | 12.6 ms |
| hicumL2_va | 90 KB | 9.7 MB | — |
| bsim4va | 440 KB | 8.7 MB | 37.9 ms *(warm cache)* |
| bsimsoi_va | 399 KB | 11.3 MB | **308 667 ms** |
| hisimhv_va | 614 KB | 38.4 MB | **> 900 000 ms, killed** |

The driver caches JIT output in `~/.nv/ComputeCache`, so that is paid once per
(model, arch, driver) — but it *is* paid, the cache evicts (109 MB here), and
it buys a kernel that loses anyway for the register-pressure reasons in §1.
Emitting them also put 68 MB of PTX in `.data`. Dropping them took the binary
from **549 MB to 307 MB**.

Source bytes is a proxy: emitted PTX size is what actually predicts JIT cost,
but it is only known after paying the build-time compile the cap exists to
skip. The size clusters cleanly — `hicumL2_va` at 90 KB is the smallest model
that explodes, `mos2` at 24 KB the largest that does not, and nothing lives in
between.

A batch whose model has no image **demotes to the CPU** rather than failing the
context, so one BSIM4 in a netlist does not pull its ten thousand resistors
back with it.

## 5. Measured results

Nonlinear DC sweep, 50 000 diodes + 50 000 resistors, 101 points:

| | time | vs GPU |
|---|---|---|
| CPU, 1 thread | 26.06 s | 11.3× |
| CPU, 8 threads *(best)* | 12.54 s | **5.4×** |
| CPU, 16 threads | 15.87 s | 6.9× |
| **GPU** | **2.31 s** | — |

Transient, 60 000 devices — an analysis that previously never reached the GPU:

| | time |
|---|---|
| CPU | 6.75 s |
| **GPU** | **2.15 s** (3.1×) |

Note the CPU column is `ESPICE_THREADS`-dependent and peaks at 8; 16 threads is
*slower* (15.87 s), because the per-eval handoff and window reduce stop paying
for themselves.

Full corpus against ngspice (264 fixtures, `rtol = 1e-3`): **80 PASS / 46 FAIL
on both the CPU and the GPU path, identical**. One fixture differs —
`sweep/opamp_wl_5000`, which the CPU path skips on timeout and the GPU path
completes in 29.5 s. The GPU introduces no accuracy regression.

The corpus itself shows only 0.68–1.48×, because every fixture in it runs in
20–50 ms — far below the work gate, so the GPU correctly declines and that
spread is process noise.

## 6. Reproducibility — read this before trusting a diff

**The GPU path is not bit-reproducible run to run.** `atom.global.add.f64`
commits in scheduling order, so the summation order of each matrix slot varies
between identical invocations. Measured on the 19 800-resistor grid: 750 of
10 000 values differ between runs, by at most **1 ULP** (2.19e-16 against an
f64 epsilon of 2.22e-16).

The magnitude is benign. The consequence is not always:

- For `.op`, `.dc` and `.ac`, results differ in the last bit and nothing else.
- For **`.tran`, the time grid itself moves.** Adaptive timestepping feeds the
  Newton iterate into the LTE controller, so a 1-ULP difference can change a
  step-accept decision. Observed on a 2-branch fixture: both runs produced 88
  points, identical through index 3, diverging at index 4
  (`1.98992165056e-10` vs `1.9899216075e-10`). **A pointwise diff of two
  transient runs is meaningless** unless you first confirm the grids match —
  compare on matched times, or interpolate.

This breaks a property the CPU side deliberately maintains: `ParEval` reduces
lanes in fixed order and is bit-identical run-to-run at a given `n_lanes`
(`devices/engine.zig`). Restoring it on the GPU means deterministic reduction
instead of atomics — segmented reduction over a sorted scatter list — which
costs a sort and a second pass.

## 7. Solver choice

`ESPICE_SOLVER` = `auto` | `direct` | `jfnk` | `jfnk-nolu`.

Matrix-free Newton-Krylov is the standard recommendation for GPU solvers, on
the theory that it trades a factorization for residual evaluations — which is
exactly the operation the device made cheap. **Measured, it is decisively wrong
here.** 4 000 R-D-C branches, `.tran 2n 100n`:

| strategy | time | vs direct |
|---|---|---|
| `direct` | **1.36 s** | — |
| `jfnk` | 64.33 s | 47× worse |
| `jfnk-nolu` | 49.17 s | 36× worse |

At 20 000 branches `jfnk` was killed at 650 s against `direct`'s 6.75 s.

Two reasons, both specific to this tree:

1. **`jfnk` here is not matrix-free.** `CpuEnv.precondBuild` calls `s.factor(v)`
   — a full sparse LU — and uses it as the preconditioner. A JFNK step costs a
   stamp *plus* the same factorization `direct` does *plus* up to 30 GMRES
   matvecs. It can only win by taking fewer Newton steps, and it does not.
2. **Matrix-free does not rescue it.** `jfnk-nolu` removes the factorization
   entirely (Jacobi diagonal only) and is still 36× worse. Circuit Jacobians
   are stiff and badly scaled; Jacobi-preconditioned GMRES stagnates, burning
   30 matvecs per step for little progress.

The general argument assumes the Krylov solve converges in few iterations.
Here each matvec is a residual eval, so 30 of them cost 30× more *device* work
than the single eval `direct` needs — making device eval faster makes JFNK's
cost structure worse relative to direct, not better.

### The default path pays for this on every solve

Worse than "JFNK is a bad option" — it is the option `converger.run` reaches
for **first**, on every solve, GPU or not:

```zig
if (jfnk(sys, ws, x, t, opts, hook)) |r| {
    if (r.converged) return r;
} else |_| {}
return newton(sys, ws, x, t, opts, hook);
```

A failed attempt is not free. It costs the *full* JFNK price — up to 30 GMRES
matvecs per Newton step, each a device eval, plus `CpuEnv.precondBuild` doing a
complete sparse `s.factor` — and then direct Newton runs anyway. Measured with
`ESPICE_SOLVER` flipping only that choice:

| fixture | `auto` | `direct` | |
|---|---|---|---|
| `ensemble/pvt_corners` (**9 devices**) | 13.97 s | 0.07 s | **199.6×** |
| `scaling/rc_ladder_1k` | 5.73 s | 0.29 s | 19.8× |
| `scaling/rc_ladder_10k` | timed out > 400 s | 2.57 s | — |
| `scaling/rc_chain_500` | 1.81 s | 0.16 s | 11.3× |
| `ensemble/opamp_mc` | 2.42 s | 0.32 s | 7.6× |
| `sweep/cmos_inv_sizing` | 0.38 s | 0.08 s | 4.8× |
| `mosfet/cmos_inverter` | 0.16 s | 5.01 s | **0.03×** |

A nine-device circuit paying 199× for a solver attempt that never succeeds is
the clearest statement of the problem. But the last row is why **"always
direct" is not the fix** — JFNK genuinely rescues some circuits, and there the
ordering is load-bearing. What is wrong is trying it *first, unconditionally*;
the existing comment justifies JFNK-first for "large sparse systems where LU
fill-in dominates" and then applies it to everything.

This also retired a wrong diagnosis. These same ladder fixtures first looked
like a **sparse-LU fill-in catastrophe** — >780× against ngspice and getting
worse with size. With JFNK skipped the superlinearity disappears entirely and
the residual gap is a flat ~5–7× across a 20× size range. The lesson is worth
keeping: measure the *strategy* before blaming the *kernel*.

## 8. What is not done, and what it would take

`solve_batch` (Monte Carlo, corners, temperature sweep) and `freq_solve_batch`
(AC, noise, SP, PAC, QPSS) are still null. Their call sites are written and
waiting (`mc.zig`, `temp_sweep.zig`, `dc.zig`, `ac.zig`, `noise.zig`, `sp.zig`,
`qpss.zig`).

Both are "N independent solves in one launch", and §7 rules out the cheap way
to do that: the solves must be **direct**. So both reduce to one missing
component — a batched direct sparse solver on the device: one symbolic
factorization on the host (the sparsity pattern is identical across lanes),
then batched numeric factorization and solve, one block per lane. That is a
substantial piece of work with real risk (partial pivoting, fill-in,
shared-memory blocking).

**Do not build it yet.** The workloads it targets are the worst in the corpus,
and that is an argument *against* starting here, not for it:

| fixture | espice | ngspice | |
|---|---|---|---|
| `ensemble/pvt_corners` | 13.862 s | 22.75 ms | 609× slower |
| `ensemble/opamp_mc` | 2.407 s | 11.74 ms | 205× slower |
| `sweep/opamp_wl_200` | 1.767 s | 28.31 ms | 62× slower |
| `sweep/opamp_wl_1000` | 9.052 s | 237.58 ms | 38× slower |

ngspice reaches those numbers on **one CPU core with no batching whatsoever**.
A 609× deficit against an unbatched single-threaded competitor is not evidence
that GPU parallelism is missing — it is evidence that the per-solve cost is
wrong. §7 already accounts for most of it: `pvt_corners` drops from 13.97 s to
0.07 s by changing nothing but the solver-strategy choice. Batching a 199×
overhead across lanes would multiply the wrong quantity.

Fix strategy selection first, re-measure, and only then ask whether batching
still has a case.

Also, before anyone fills `solve_batch`: **`runBatchGpu` in `dc.zig` is not
implementable as written.** It calls `repack` once per lane inside a loop and
then calls `solve_batch` once — but `repack` overwrites the single
device-resident parameter copy, so only the last lane's parameters survive.
Per-lane parameter storage has to enter the contract before that hook can be
filled, and for a large sweep that is `n_lanes × sizeof(models + instances)` of
device memory, which is its own budget question.

A tractable subset exists for `freq_solve_batch`: batched **dense** complex LU,
one block per frequency, for `n` below ~1000 with a CPU fallback above. It only
helps circuits that are already fast, but AC sweeps run thousands of points.

Note also that `runBatchGpu` in `dc.zig` is not implementable as written — it
calls `repack` once per lane inside a loop before a single `solve_batch` call,
and `repack` overwrites the one device-resident parameter copy, so only the
last lane's parameters survive. Per-lane parameter storage has to be part of
the contract before that hook can be filled.

## 9. Mixed precision — f32 Jacobian, f64 residual

The only route by which compact models beat the CPU. §1 gives the size of the
prize: f32 is **69×** the f64 rate on this part, and 10 477 GFLOP/s is 7× the
*entire* CPU's f64 peak.

Newton is self-correcting — the converged answer depends only on the accuracy
of the **residual**, while an approximate **Jacobian** costs iteration count,
not correctness. An f32 Jacobian with an f64 residual is the standard inexact
-Newton construction.

Prototyped on the diode (VerA branch `mixed-precision-jacobian`, ESPice
`-Djac-f32=`). What follows is measured.

### 9.1 The split is one type, and it is on this side

**VerA needs no dual-precision codegen, because the emitted device is already
precision-agnostic.** `eval` is generic over a comptime `S` and reaches it only
through the contract's primitive set — `con(f64)`, `scale(f64)`, `addC(f64)`,
`val() f64`, `ddxAt(usize) f64` — every one of which is f64 at the boundary.
Physics code may not open `S` up. So which floats `S` carries *inside* was
always the host's choice, and nothing in the 25 models had to change.

Pinned by a VerA test (`codegen: --jac-f32 adds a permission decl and changes
not one other byte`): the flag's whole output diff is

```zig
pub const jac_f32 = true;
```

and the rest of the file is byte-identical. If that ever stops holding, the
genericity has been broken somewhere and that test is where it surfaces.

The split itself is `engine.Dual(N, F)`:

```zig
v: f64,               // residual — never narrows
d: @Vector(N, F),     // Jacobian — F = f32 under jac_f32
inline fn splat(c: f64) V { return @splat(@floatCast(c)); }
```

`engine.jacFloat(D)` reads the device's `jac_f32` and picks `F`. The permission
is per **device**, not per host, because whether a model's unknowns fit in f32's
~7 digits is a fact about its physics and only the physics knows it.

### 9.2 What widens back, and where

`ckt.g_vals` is `[]f64` and feeds the sparse LU, so the partials widen at
exactly four points, all in `engine.zig`:

| site | why |
|---|---|
| `evalRange` scatter — `out[ru].grad()` | into `g_vals`/`c_vals` (host `+=`, GPU `atom.global.add.f64`) |
| `evalRange` limiting correction | `J·(x − x_lim)` lands on the **residual**, so it is widened before the dot product |
| `HostSink.store`/`storeQ` | the dedup cache is `[n_u][n_u]f64` |
| `collectNoise` | thermal conductance via `ddxAt` |

`.d` is never read directly any more; `grad()` and `ddxAt()` are the only ways
out, which is what keeps `F` private to the arithmetic.

### 9.3 Measured: the op counts move, exactly as n_u predicts

`grep -c '\.f64'` on the emitted kernel PTX. Note the count *includes* the
`cvt.rn.f32.f64` narrowings the split introduces — on sm_89 a 64-bit type
conversion has the same 2/SM/clock throughput as an f64 FMA, so it belongs in
the f64 budget rather than being netted out:

| model | n_u | f64 ops before | after | of which cvt | Δ | f32 ops after |
|---|---|---|---|---|---|---|
| diode | 2 | 80 | 66 | 14 | **−17 %** | 42 |
| mos9 | 6 | 9 587 | 3 267 | 526 | **−66 %** | 7 275 |
| bjt | 9 | 12 740 | 3 818 | 640 | **−70 %** | 10 157 |

Total instruction count barely moves (bjt 22 934 → 23 217, +1.2 %), so this is
a straight substitution and not extra work. The trend is the point: the value
chain is O(1) per operation and the derivative chain is O(n_u), so the fraction
that can go to f32 rises with the unknown count. **The diode is the worst case
in the catalog**, which is why its 17 % is not the number to plan from.

Virtual register pressure — §1's actual reason the compact models lose — moves
further:

| model | 64-bit vregs | 32-bit vregs | 32-bit-slot equivalent |
|---|---|---|---|
| mos9 f64 | 12 777 | 1 209 | 26 763 |
| mos9 **f32 jac** | 5 948 | 10 587 | **22 483** (−16 %) |
| bjt f64 | 15 602 | 1 107 | 32 311 |
| bjt **f32 jac** | 4 879 | 12 361 | **22 119** (−32 %) |

### 9.4 Measured: correct

201-point DC sweep of a diode through a 100 Ω series R, f64 Jacobian vs f32,
same binary otherwise:

```
max relative difference: 2.7e-13
```

Not bit-identical, and it should not be: Newton stops inside a tolerance ball
and a different Jacobian lands on a different point inside it. 2.7e-13 is
thirteen digits, against a `reltol` of 1e-3. Across the diode-carrying fixtures:

| fixture | analysis | max rel diff |
|---|---|---|
| `convergence/diode_bridge` | `.op` | 0 |
| `convergence/schmitt` | `.op` | 0 |
| `disto/diode_clipper` | `.op` | 2.8e-14 |
| `hb/diode_clipper` | `.hb` | 0 |
| `power/zener_reg` | `.dc` | 4.7e-13 |
| `power/rectifier` | `.tran` | 5.5e-6 |
| `devices/mos9` | `.dc` | 0 |

The transient outlier is §6's known effect, not a precision failure: a tiny
numeric difference feeds the LTE controller and moves the time grid.

### 9.5 Measured: no runtime change, and that is the real finding

50 000 diodes + 50 000 resistors, 101-point DC sweep, `--gpu`, 5 interleaved
runs each:

```
f64 jac   2.80  3.16  3.46  3.84  4.75
f32 jac   2.99  3.13  3.20  4.41  4.63
```

40 000 level-9 NMOS, DC sweep, warm (the first two runs of each binary are cold
`cuModuleLoadData` and were discarded):

| | 101 points | 11 points |
|---|---|---|
| f64 jac | 13.39 13.41 13.43 13.53 | 3.26 3.20 |
| **f32 jac** | 13.40 13.41 13.41 13.47 | 3.22 3.20 |

**−66 % of mos9's f64 ops bought 0.0 %.**

The two sweep lengths separate the fixed cost from the per-point cost: 1.95 s
to parse and build a 12 MB netlist, then **0.113 s per sweep point**. The same
netlist without `--gpu` takes 827–937 s over three runs, ~8.4 s per point — so
the GPU is
already **74× on the work being measured**, and device eval was ~99 % of the CPU
run. Mixed precision is not being hidden by the sparse LU; it is being applied
to a kernel that is not FP64-throughput bound.

Two readings survive, and no profiler is installed here to choose between them:

1. The kernel is already a small part of that 0.113 s, most of which is the host
   LU, the per-iteration transfers and the launch chain of §3.
2. The kernel is bound by spill traffic rather than arithmetic. Its
   `__local_depot` is 5 120 B *per thread* (bjt's is 16 384 B) — this halves to
   2 560 B under mixed precision, which is real and still far above the register
   file, so the regime does not change.

For the diode, §4 already gave the answer directly: for what `gpuEligible`
admits today "the number of `atom.global.add.f64` a batch issues per iteration
… *is* the kernel". Six f64 atomics per thread against fourteen f64 ops
removed — there was never anything there to win.

So the prize in §1 is real, the machinery to collect it now exists and is proven
correct, and it is **gated behind the model size cap** (`gpu_max_model_bytes`,
§4). The models this helps most — bsim4's 142 990 f64 ops, 7 104 virtual f64
registers, 16 % occupancy — are precisely the ones excluded from GPU emission
today. −70 % of those ops with −32 % of the register pressure is the argument
for moving that cap; nothing measurable happens until it moves.

### 9.6 The strict-float interaction

VerA emits `@setFloatMode(.strict)` deliberately (`W0650`: *"unit is not
provably finite, so it compiles in strict float mode"*), which is why dead
arithmetic survives into the PTX — the emitted resistor kernel contains a
literal multiply-by-zero followed by `1.0 - that`, because `.rn` semantics
forbid folding it.

Mixed precision does not fix this and is **taxed by it**. Every `S.con(k)`
carries a derivative vector of literal zeros, and strict mode forbids folding
the multiplies against them. Under f64 those are dead vector multiplies; under
mixed precision they become cheap f32 multiplies that each still need their
operand narrowed, and the narrowing runs at f64 rate. That is where mos9's 526
and the diode's 14 conversions come from — the diode's are 21 % of its entire
remaining f64 budget. Reaching `.optimized` is a job for VerA's finiteness
prover, and it is worth more *after* this change than before it.

## 10. Addendum (2026-09): the limit class goes resident

Everything above described a first cut whose `gpuEligible` excluded any
device with `limit` or `State` — the whole diode/FET/BJT class, i.e. the
models that carry the eval work. That exclusion is gone. Three per-instance
kernels per admitted device now share one resident blob set:

| kernel | GPU half of | launched |
|---|---|---|
| `arp_eval_<m>` | `Circuit.eval`/`evalNewton` | per Newton iteration |
| `arp_lim_<m>` | `applyLimits` + `updateStates`, fused | per Newton iteration |
| `arp_ctl_<m>` | `stateCtl` (path-latch commit/revert/query) | per accepted step |

Two admission rules carry the correctness:

- **`core_reads_simstate`** (VerA-emitted decl): a core that reads a
  host-published sim-state Instance field (`analysis()`, `$abstime`, the
  ddt-family `inst.dt`) evals stale device-resident, because the host
  republishes those on the host blob only. jfet2 is the one such device in
  the catalog; it stays CPU.
- **`stateCtl` must run on the device.** The path-integration protocol
  (ddt-capform upstream: `updateState` stages `wb__/wq__`, commit folds
  them into the `pb__/pq__` latches eval reads) mutates the resident
  Instance blob. Running the commit on the host's stale copy is not a
  slow path, it is a wrong one: on a 400-MOS chain deck with CGSO/CJ set,
  the missing device commit killed the transient outright
  (`TimestepTooSmall` — the device latches never moved and LTE exploded).
  With `arp_ctl` the same deck matches the CPU path to 4.7e-12 max rel.
  A fixture without capacitance parameters cannot see this failure — the
  staged values are all zero — which is why `parallel_inverters_2000`
  passed while the protocol was broken.

The work gate now counts only nonlinear (limit/State) batches, at a ×16
eval-cost weight over the `count·n_u²` atomic proxy. Linear batches ride
along once nonlinear work engages the context, but cannot engage it: on
`rc_ladder_100k` (200 K linear devices, the largest all-linear fixture)
the resident path measured 3.03 s against 2.55 s CPU — offloading a
~10-f64-op stamp trades a vectorized host loop for the same atomics plus
the bus, and bigger only makes the planes' D2H larger.

Measured (5-run medians, ReleaseFast, RTX 4060 Laptop / i9-14900HX):

| fixture | cpu (32T default) | cpu (best, 8T) | gpu | ngspice |
|---|---|---|---|---|
| `scaling/parallel_inverters_2000` | 3.33 s | 2.24 s | **1.51–1.66 s** | 0.86 s |
| `sweep/opamp_wl_5000` | 1.14 s | — | **0.88 s** | 4.0 s |
| `scaling/rc_ladder_100k` | 2.64 s | — | 2.62 s *(declines)* | 5.0 s |
| `devices/hisim2` | 74 ms | — | 71 ms *(declines)* | 23 ms |

Where the remaining `parallel_inverters_2000` gap to ngspice lives, from
coarse differential timing (no profiler on this machine): the GPU loop
runs ~670 µs per Newton iteration against the CPU path's ~1.7 ms —
kernels, transfers and the two stream syncs account for only ~100–150 µs
of that, so the loop is host-residue-bound (companion RHS math,
convergence norms, waveform append), not device-bound. One-time GPU
init/upload adds ~0.3 s (cuInit 114 ms + context + module loads). LU is
exonerated: `ZP_LU_STATS` shows 2 full factors for the whole transient
(n=2005, fill 1.2×); everything else replays the pivot tape. The
`opamp_wl_5000` split: the 25 K-device `.op` is ~0.65 s CPU / ~0.55 s
GPU of the ~1.1 s total; the 91-point `.ac` remainder is LaneLu on the
CPU by design (`freq_solve_batch` stays null — §8's batched-LU verdict
stands, and at n=15 007 the dense-complex subset does not apply).

### Retired levers, with the measurements that retired them

- **`--outline-chunk` for GPU kernel roots** (a second per-model vera
  invocation feeding only the kernel roots): a no-op at the current 80 KB
  model cap. Cold build 277.9 s → 278.9 s; at chunk=300 only bsim3 and
  mos2 split at all (2 chunks each) — the monolithic cores the flag
  targets are exactly the whale models the cap already excludes, and
  mos9-class cores are shape-inhibited (multi-return) besides. The wiring
  is one build.zig block (see gpu-layout history); revive it the day the
  cap moves for §9's mixed-precision prize. Watch the kernel symbol if
  you do: it derives from the generated file's basename, so the second
  generation must emit `<name>.zig` into its own directory, not
  `<name>.gpu.zig` (`arp_eval_gpu` collides across every root).
- **PTX/HSACO runtime-load instead of embedding**: moot for the same
  reason. With the cap in place the kernel compiles hide entirely inside
  the host LLVM compile (cold build 278 s ≈ the espice exe compile; the
  PTX steps run parallel to it) — the "minutes off cold builds" claim
  predates the cap, when the whales were emitted.

### Backend policy (revised 2026-09): `--gpu` is an override, not a hint

`auto` is now the ONLY heuristic mode. Every other GPU request is EXPLICIT —
`--gpu`, `--backend cuda`, `--backend hip` — and an explicit request either runs
on the device or says why not. `gpu_context.Decline` splits the refusals into
the three kinds a caller can act on:

| kind | example | explicit request | `auto` |
|---|---|---|---|
| **policy** | `NotEnoughGpuWork` (the `min_work` gate) | never reached — the gate is off | declines, prints a note |
| **capability** | no device type has a kernel; every eligible model was excluded by `gpu_max_model_bytes` | falls back, prints WHICH batch demoted and why | same |
| **machine** | absent device, dead driver, out of memory, no artifacts in this binary | **hard error** naming what was detected | warns, falls back |

The bug this fixed: `--backend cuda` set `gpu_force = false`, and the engine
matched `NotEnoughGpuWork` *before* it checked strictness — so a named `cuda`
request on a small circuit printed "note: --gpu declined" and ran the whole
simulation on the CPU. A performance heuristic was overruling a direct
instruction. `gpu_force` and `gpu_strict` are now one `gpu_explicit`, because
they were always the same predicate and keeping two let them disagree.

Capability demotions are no longer silent either: a batch that loses its kernel
image names its model and instance count under an explicit request, or under
`ESPICE_GPU_STATS` for `auto`. `ESPICE_GPU_STATS` also prints the residency
decision (eligible batches, measured work, gate, resident vs host split,
whether the charge planes are device-side). `ESPICE_GPU_MIN_WORK` still tunes
the gate for `auto`.

`ESPICE_GPU_EVAL_CHECK=1` replays the device half at the same x and reports the
worst plane entry that moved — the probe for the atomic-scatter
non-reproducibility in `todo.md`'s open regression.

Override validation: a three-device resistor divider and a single-diode circuit
both ran with `--gpu` and `ESPICE_GPU_MIN_WORK=18446744073709551615`.
Their values matched the CPU exactly. CUDA tracing recorded two kernel launches
for the divider, versus zero with auto or CPU selection. Both option orders
were checked. Full build and all 376 tests pass. Reproduction:
`/tmp/espice-gpu-override-356hp9xj/validate.py`.
