# GPU on layout netlists — what the hardware and the fixtures actually allow

Base `446268a`, branch `gpu-layout-eval`, RTX 4060 Laptop (sm_89, 24 SMs) against
an i9-14900HX. **Every number here was taken on a machine other agents were also
using** — load average 15–32 throughout, three concurrent `zig build-exe`
processes for most of the session. Absolute times are therefore 30–50 % above
the uncontended `docs/perf/baseline-446268a.md` figures. Ratios taken from
*interleaved* arms (§6) survive that; ratios taken from separate passes do not,
and are labelled where used.

The stated goal is *"faster than NGSpice (CPU and GPU, where GPU is used for
layout netlists because it can evaluate quick)."* The short version:

- The three `scaling/inverter_chain_*` decks skipped because the **fixtures were
  unphysical**, not because of any gate or engine fault. Two are fixed here; the
  third has a second, already-documented op-ladder cause (§1).
- The `zp-gpu` column of the benchmark has been reporting **CPU times** for
  every gate-declined fixture, including all five `layout/*` decks. One-line
  matcher bug, fixed here. Nothing in `layout/` has ever run on the GPU — the
  whole category is 340 devices and **zero transistors**.
- On the default build exactly **one** fixture in 280 both clears the work gate
  and runs: `scaling/parallel_inverters_2000`, where the GPU is **1.27× ngspice
  and 1.22× our own CPU** end to end and **1.98×** in setup-subtracted steady
  state (§4, §6).
- The per-step bottleneck is **f64 issue rate**, and the kernel is already at
  **94 %** of what this part can deliver at the grid the deck gives it. There is
  no tuning left in it. The offloadable fraction is **83 %**, Amdahl ceiling
  2.4× end to end (§5, §7).
- **The goal is met, on the biggest deck.** `inverter_chain_4k` (8 000 MOS) with
  `-Djac-f32=mos1`: GPU **6.4 s = 1.49× ngspice** where our CPU is 13.4 s =
  **0.71×**, gpu/cpu **2.09×** (§8.3). Two caveats, both fixable: the deck only
  converges under that flag, and 8 000 transistors is the *first* size at which
  the grid covers all 24 SMs. Deck size is the dominant variable — 4 000
  instances gives 1.3×, 8 000 gives 2.1×.
- `jac_f32` on the GPU is **1.21×, measured** (§8.2), against §9.5's earlier
  0.0 % for a spilling kernel.

---

## 1. Why `scaling/inverter_chain_{256,1k,4k}` skipped

Not a runner gate. Not a `--gpu declined`. Not an engine failure. **The decks
were unsimulatable, and ngspice says so first.**

Every one of the 255/999/3999 internal nodes carried **no capacitance at all**.
The level-1 model card declares no `TOX`, `CGSO`, `CGDO`, `CJ` — so there are no
parasitics — and only the last stage had a `Cload`. Each internal node is a
purely algebraic node inside a nonlinear feedback chain; when a stage sits in
cutoff both drain conductances collapse, the node floats, the LTE controller has
no charge to bound, and `dt` underflows.

```
$ ngspice -b .../inverter_chain_256/circuit.sp        # BEFORE
doAnalyses: TRAN:  Timestep too small; time = 4.97603e-11,
            timestep = 1.25e-22: trouble with nch-instance mn103
run simulation(s) aborted

$ espice -b --backend cpu .../inverter_chain_256/circuit.sp   # BEFORE
Engine error: TimestepTooSmall
{"skip":"TimestepTooSmall"}
```

`{"skip":"TimestepTooSmall"}` on stdout is what `runner.zig skipReason`
parses, which is why the row read `skip` in all five columns — espice CPU, espice
GPU, **and ngspice**. A fixture no simulator can run is a fixture defect.

### The fix

One `Cl<i> s<i> 0 10f` per stage — the same 10 fF load the sibling
`scaling/parallel_inverters_*` decks already put on every node — plus three
comment lines saying why, so it does not get stripped again.

| deck | before | after (espice) | ngspice |
|---|---|---|---|
| `inverter_chain_256` | skip everywhere | **runs**, 7 569 NR iters | 0.406 s |
| `inverter_chain_1k` | skip everywhere | **runs**, 7 243 NR iters | 1.838 s |
| `inverter_chain_4k` | skip everywhere | still skips on the default build — see below; runs under `-Djac-f32=mos1` (§8.3) | 16.60 s |

### `inverter_chain_4k` has a second, unrelated defect, and it is a known one

With the caps in place the netlist is sound (ngspice runs it in 16.6 s) but
espice still fails, **identically on CPU and GPU**:

```
tran-stats: accepted=22966 attempts=23978 nr_iters=93070 avg_dt=4.354e-11
tran-stats: DT UNDERFLOW (newton) at t=0 dt=9.537e-19 accepted=0 attempts=20 nr_iters=200
Engine error: TimestepTooSmall
```

Two `tran-stats` lines, and the first one is not the transient. `avg_dt × accepted
= 1.0e-6`, twenty times the deck's 50 ns stop — that is `op.zig:246`'s
**pseudo-transient operating point**, burning 93 070 Newton iterations because
the direct OP solve failed on a chain whose DC loop gain is the product of 4 000
inverter stages. The real `.tran` then starts from that answer and cannot take
its first step.

`ESPICE_SOLVER=jfnk` fixes it on the CPU — the OP converges directly, no
pseudo-transient, 7 100 NR iterations, deck completes. This is exactly the case
`converger.zig:581` already documents:

> JFNK only rescues `parallel_inverters_100` when it drives the **whole** op
> continuation ladder. […] Doing it properly means restarting the whole op ladder
> under JFNK, at the dc/op level rather than here.

So deck 3 is blocked on an open, deliberately-deferred op-ladder item, not on
anything in this task's scope, and not on the GPU. **Not fixed here**; the
mechanism and the `ESPICE_SOLVER=jfnk` workaround are recorded so the next
person does not re-diagnose it.

Two extra data points, both pointing the same way:

- With the `jfnk` pin the deck runs on the CPU and *still* fails on the GPU
  (95 035 NR iterations in the pseudo-transient, then the same underflow). The
  likely mechanism is §5's chunked reduce: level-1 segments are 64 contributions
  wide, so a row with more than 64 contributors — the `vdd` row has 8 000 — is
  re-associated relative to the serial CPU stamp.
- With **`-Djac-f32=mos1`** it converges directly on *both* backends, 7 126 NR
  iterations, no pseudo-transient at all (§8.3).

Two unrelated perturbations flip the same deck, and one of them flips it on only
one backend. That is a circuit sitting exactly on the knife edge of the op
continuation ladder, and it means neither perturbation is a fix — the
`converger.zig:581` item is. §8.3 uses the `jac_f32` build anyway, because a deck
that runs is worth more than a deck that does not, and labels it.

---

## 2. The benchmark has been reporting CPU times in its GPU column

`runner.zig gpuSkipReason` matched three literals:

```
"--gpu declined"   "--gpu unavailable"   "falling back to the CPU"
```

`src/engine.zig prepare` prints three refusals, and since the backend-policy
revision (`docs/gpu-device-eval.md` §"Backend policy") they read:

```
note: auto declined the GPU; too little device work to beat the PCIe round trip …
warning: GPU declined (CircuitNotEligible); … running on the CPU
warning: GPU unavailable (NoGpuArtifacts); running on the CPU
```

**None of the three matches any needle.** The matcher has been dead, and every
fixture the `min_work` gate declines has reported its CPU time under `zp-gpu`.
The test that should have caught it (`"GPU fallback diagnostics cannot become
GPU timings"`) fed the matcher a hard-coded copy of the *old* wording, so it
stayed green across the rewording. `engine.prepare`'s own comment says
"`--gpu` silently meaning 'ran on the CPU' is exactly how the benchmark came to
report CPU timings in its GPU column" — the engine side was fixed and the runner
side was not.

Fixed by matching the stable tokens (`GPU` plus a refusal verb) instead of four
verbatim phrases, and by replacing both tests' paraphrased fixtures with the
strings the engine actually prints. 10/10 runner tests pass.

**What this invalidates in the task brief's table:**

| deck | brief says | actually |
|---|---|---|
| `layout/fanout_tran` | gpu/ng 2.0× — "real gain" | 95 devices, **0 transistors**, declines; both columns are the same CPU path |
| `layout/mesh_op` | gpu/ng 2.3× — "small gain" | 192 devices, **0 transistors**, declines |
| `layout/{capacitive_divider,metal_island}_tran` | "flat" | 4 and 2 devices, declines |
| `layout/coupled_ac` | "flat" | 47 devices, declines |
| `scaling/parallel_inverters_{500,100}` | gpu/ng 1.0×, 1.2× | declines; noise between two CPU runs |

Measured in this session, interleaved with ngspice (all three arms 5 medians):

```
layout/fanout_tran     cpu 67.5ms  "gpu" 49.0ms  ng 143.7ms   DECLINED->cpu
layout/mesh_op         cpu  3.4ms  "gpu"  3.5ms  ng  12.9ms   DECLINED->cpu
parallel_inverters_500 cpu337.7ms  "gpu"327.5ms  ng 416.8ms   DECLINED->cpu
parallel_inverters_100 cpu 80.2ms  "gpu" 85.2ms  ng  75.6ms   DECLINED->cpu
```

The entire `layout/` category — the fixtures named after the workload this goal
is about — **contains no transistor and no deck above 192 devices.** The
layout-shaped GPU workload has never been benchmarked.

---

## 3. Which fixtures can reach the GPU at all

The gate is `count · n_u² · 16` summed over **nonlinear** batches, against
`default_min_work = 3_200_000`. `mos1` has `n_u = 8` (d, g, s, b, di, si + the
two `rd`/`rs` branch flows), so a MOS deck needs **≥ 3 125 transistors**.

Scanning all 280 fixtures for nonlinear devices (netlist-letter count × the
model's `n_u`; `n_u = 8` is measured for `mos1`, the others are estimated, which
does not matter because the largest non-MOS nonlinear deck in the corpus is
`devices/vbic_diffamp` with **13** transistors — three orders below the gate at
any plausible `n_u`):

- 155 decks have at least one.
- **4** clear the gate: `sweep/opamp_wl_5000` (25 000 M), `scaling/inverter_chain_4k`
  (8 000 M), `sweep/opamp_wl_1000` (5 000 M), `scaling/parallel_inverters_2000`
  (4 000 M).
- `inverter_chain_4k` fails on the default build (§1) and runs under
  `-Djac-f32=mos1`, which is where §8.3's result comes from. The two
  `opamp_wl_*` decks are `.ac dec 10 1
  1G` — the device is used for the operating point only, then
  `freq_solve_batch` is null by design and the whole 91-point sweep is LaneLu on
  the CPU (`gpu-device-eval.md` §10 splits that deck: ~0.55 s of GPU `.op` in a
  ~1.1 s run).

**On the default build `scaling/parallel_inverters_2000` is the only deck in the
corpus that runs a transient on the GPU**, and `inverter_chain_4k` joins it under
`-Djac-f32=mos1`. Everything the brief reads as "the GPU is level with the CPU"
is either that one deck or a CPU run mislabelled.

---

## 4. Setup versus steady state

The transient step grid is adaptive, so nominal stop time is not a usable
x-axis. Each deck was run at `.tran` stops of 2 ns / 10 ns / 50 ns, 5 medians
each, with the **accepted Newton iteration count read out of `ZP_TRAN_STATS`**,
and `wall = fixed + k · nr_iters` least-squares fitted. Load ~19.

| deck | arm | fixed | per NR iteration |
|---|---|---:|---:|
| `parallel_inverters_2000` (4 000 M, n=2005, nnz=10 011) | cpu | 88 ms | **899 µs** |
| | gpu | 341 ms | **453 µs** |
| `inverter_chain_1k` (2 000 M) | cpu | 156 ms | **429 µs** |
| | gpu | 335 ms | **340 µs** |

- **GPU fixed-setup premium: 253 ms** on `pi2000`, 179 ms on `chain_1k`.
- Cross-checked independently of espice, by JIT-ing the same PTX through
  `libcuda.so.1` directly (9 runs, medians): `cuInit` **67 ms**,
  `cuDevicePrimaryCtxRetain` **113 ms**, four `cuModuleLoadData` **2–4 ms warm**
  (52 ms once, cold `~/.nv/ComputeCache`), **total 183 ms** (range 157–258; the
  cold-cache first run was 398 ms). The doc's "~340 ms" is the cold figure; warm
  it is ~180–250 ms, and the fit's 253 ms premium sits in that band.
- **Setup is 27 % of the 954 ms `pi2000` GPU run** and 6.4 % of the 2.8 s
  `chain_1k` run.
- **In steady state the GPU is 1.98× the CPU on `pi2000`** (899 → 453 µs), against
  1.37× end to end in the same pass (the 50 ns points: cpu 1308 ms, gpu 954 ms).
  That 253 ms is what makes a one-second deck look like a tie.

Setup does **not** dominate every deck — `chain_1k` is a 6 % overhead — but at
one second of work it costs a quarter of the run, and no deck in the corpus is
big enough to make it negligible *and* clear the gate.

---

## 5. The per-step bottleneck: f64 issue rate, at 94 % of the ceiling

### 5.1 Splitting the GPU iteration

`ESPICE_GPU_EVAL_CHECK=1` (`gpu_context.evalCheck`) replays the entire device
half — upload `x`, memset the staging, launch `arp_eval` + `arp_lim`, both reduce
passes, download all four planes, sync — a second time at the same `x`, with no
host work under it. The wall-clock delta over `nr_iters` is the unoverlapped cost
of the GPU half. `pi2000`, 5 medians:

```
gpu base   976.4 ms   (1356 NR iters)
gpu +chk  1380.0 ms
device half = (1380.0 - 976.4) / 1356 = 297.7 us per Newton iteration
```

So the 453 µs GPU iteration is **298 µs device + 155 µs host residue** (companion
RHS, `combineGC`, LU tape replay at n=2005/nnz=10 011/fill 1.2×, convergence
norms, waveform append).

The probe was silent throughout — the deterministic scatter holds; the
`todo.md` atomic-ordering defect is closed by the staging + segmented reduce and
did not reappear.

### 5.2 Where the 298 µs goes

Data movement, from the measured shapes (n = 2005, nnz = 10 011; `n_slot` =
4 000 mos1 × 8² + 2 000 caps × 2² = 264 000 staging cells, `n_row` = 36 000):

| item | bytes/iteration | at | cost |
|---|---:|---|---:|
| `x` H2D + g/rhs/c/q D2H | 208 KB | 12.6 GB/s PCIe | **17 µs** |
| staging memsets (g, c, rhs, q) | 4.8 MB | ~250 GB/s VRAM | **19 µs** |
| two-level reduce read+write | ~5 MB | ~250 GB/s | **20 µs** |
| **kernels (residual)** | | | **≈242 µs** |

(The reduce is cheap here because the average `g` cell takes 264 000 / 10 011 =
26 contributions, under the 64-wide level-1 chunk, so level 1 is close to a copy
for all but the `vdd` row.)

Transfers, memsets and the reduce together are **18 % of the device half**. They
are not the bottleneck; the kernel is.

### 5.3 The kernel is at the hardware ceiling

Counted off the emitted PTX (`arp_eval_mos1` / `arp_lim_mos1`, FP64-pipe
mnemonics only — `fma/mul/add/sub/div/rcp/sqrt/neg/abs/min/max/cvt`, excluding
`mov`/`ld`/`st`/`setp`/`selp`):

| kernel | FP64-pipe ops / instance | regs | spill | occupancy @ block 256 |
|---|---:|---:|---:|---:|
| `arp_eval_mos1` | **2 028** | **248** | 0 B | **16.7 %** |
| `arp_lim_mos1` | 841 | 114 | 8 B | 33.3 % |
| `arp_ctl_mos1` | 3 | 30 | 0 | 100 % |
| `arp_reduce_mos1` | 9 | 32 | 0 | 100 % |

(Register and occupancy figures are the driver's own, via `cuModuleLoadData` +
`cuFuncGetAttribute` + `cuOccupancyMaxActiveBlocksPerMultiprocessor` against
`libcuda.so.1` — no CUDA toolkit is installed on this machine.)

4 000 instances × (2 028 + 841) = **11.5 M FP64-pipe instructions per Newton
iteration**.

Two ceilings apply, and both are structural:

1. **Register-capped occupancy.** `arp_eval_mos1` needs 248 of 255 registers.
   At `block_size = 256` that is 63 488 of an SM's 65 536 registers, so **one
   block per SM, 256 of 1 536 thread slots, 16.7 % occupancy.** This is not a
   bsim4 problem — §1 of `gpu-device-eval.md` attributes 16 % occupancy to
   bsim4's 142 990 ops, but the *simplest MOSFET in the catalog* is on the same
   cliff, with zero spill. Measured across the eligible set: mos9 255 regs /
   168 B spill / 16.7 %, bjt 255 / 1 672 B / 16.7 %, diode 82 / 0 / 33.3 %,
   resistor 26 / 0 / 100 %, capacitor 34 / 0 / 100 %.

2. **The grid does not cover the device.** `Dim3.linear(count, 256)` gives
   `ceil(4000/256) = 16` blocks for the mos1 batch. The part has **24 SMs**, so
   **8 SMs get no work at all** and the achievable f64 rate is 16/24 of the
   device's.

Ceiling arithmetic: 16 SMs × 2 FP64 cores × 1.89 GHz = 60.5 G f64-op/s, × the
84 % efficiency `gpu-device-eval.md` §1 measures = **50.8 G/s achievable**.
Measured: 11.5 M ÷ 242 µs = **47.5 G/s = 94 % of it.**

There is essentially nothing left in this kernel on this part.

The grid effect is directly visible in the fit. Going from `chain_1k`'s 2 000
instances (8 blocks) to `pi2000`'s 4 000 (16 blocks) doubles the work:

| | per NR iteration | ratio |
|---|---|---|
| CPU | 429 → 899 µs | **2.10×** — pays in full |
| GPU | 340 → 453 µs | **1.33×** — idle SMs absorb it |

That sublinearity *is* the headroom, and it runs out at 24 blocks = 6 144
transistors. Beyond that the GPU goes linear too and the ratio to the CPU stops
improving.

---

## 6. End-to-end, interleaved

Nine rounds, arms interleaved within each round so contention hits all of them
equally. Load 18–23.

| arm | median | min | max | vs ngspice | vs cpu 1T |
|---|---:|---:|---:|---:|---:|
| espice cpu (default, 1 thread) | 1694 ms | 1353 | 2703 | 1.04× | 1.00× |
| espice cpu `ESPICE_THREADS=2` | 1867 ms | 1421 | 2567 | 0.95× | 0.91× |
| espice cpu `=4` | 1981 ms | 1625 | 2153 | 0.89× | 0.86× |
| espice cpu `=8` | 1990 ms | 1700 | 2458 | 0.89× | 0.85× |
| espice cpu `=16` | 2892 ms | 2092 | 7165 | 0.61× | 0.59× |
| **espice gpu** | **1385 ms** | 1067 | 1630 | **1.27×** | **1.22×** |
| ngspice 44.2 | 1766 ms | 1406 | 2538 | 1.00× | 0.96× |

Two readings, and the contention caveat cuts differently for each:

- **The GPU beats both ngspice and our own CPU on this deck.** The uncontended
  `baseline-446268a` had cpu 900 ms / gpu 881 ms / ng 859 ms — level. The gap
  here is partly that the GPU path is *contention-insulated*: it moves 83 % of the
  work off a CPU that four agents are fighting over. Steady-state (§4) says 1.98×
  independent of the setup constant, but that pass was taken at load ~19 too.
  Honest bound: **the GPU is between 1.0× and 1.3× end to end on this deck,
  depending on how busy the machine is.**
- **`ESPICE_THREADS` is a regression at every T on this machine**, monotonically
  to −41 % at T=16. `gpu-device-eval.md` §5 reports a peak at 8 threads on an
  idle box; at load ~20 there are no spare cores and ParEval's per-eval handoff
  and window reduce are pure overhead. `remaining-2026-09-10.md` §12 is right
  that nobody had taken a wall-clock number — this is one, and it is negative.
  Re-take it on an idle machine before concluding anything about ParEval itself.

---

## 7. The offloadable fraction — Amdahl's ceiling

The hook supplies `eval_planes`, `solve_newton`, `apply_limits`,
`update_states`, `clear_limits`, `seed_junctions` and `state_ctl`.
`solve_batch`, `freq_solve_batch` and `simulate_tran` are null by design, so
every sweep and every frequency solve stays on the CPU.

The `ESPICE_THREADS` sweep cannot measure the offloadable fraction here (it is
negative — §6), so it is derived from the two independent measurements instead.
The host residue is the same work whichever backend runs the stamp:

```
GPU steady state       453 us / NR iteration      (3-point fit, §4)
GPU device half        298 us / NR iteration      (EVAL_CHECK ablation, §5.1)
host residue           155 us / NR iteration
CPU steady state       899 us / NR iteration      (3-point fit, §4)
CPU device half        899 - 155 = 744 us
```

**Offloadable fraction on `parallel_inverters_2000`: 744 / 899 = 83 %** of the
CPU's steady-state iteration.

Consistent with `remaining-2026-09-10.md`'s callgrind profile of `pi100`
(kernel+stamp 54.7 % + limiting 14.4 % + `updateStates` 3.9 % ≈ 73 % of Ir, on a
deck 20× smaller where the fixed LU share is larger).

Amdahl:

| | ceiling |
|---|---|
| steady state, eval made free | 899 / 155 = **5.8×** |
| end to end at 50 ns, eval free, setup still paid | (88 + 1356·0.899) / (341 + 1356·0.155) = **2.37×** |
| **achieved today** | **1.98× steady, 1.22–1.37× end to end** |

So the GPU has already collected roughly a third of the available ceiling, and
the remaining two thirds are worth at most 2.4× end to end even at infinite
device speed. That is the real limit on this deck, and it is not the kernel.

---

## 8. Mixed precision, judged on the GPU

`jac_f32` (`VerA/src/cli.zig:206` → `codegen.zig:1347` → `build.zig:18,107` →
`engine.jacFloat`) narrows the derivative half of `Dual(N, F)` to f32 and leaves
the residual at f64. What follows is the **GPU** case; a sibling agent is
measuring the CPU case, and `gpu-device-eval.md` §9.5 already measured mos9 and
diode on the GPU at **0.0 %**.

This is **not** an estimate from §9.3's trend line. `-Djac-f32=mos1` was built in
this worktree and the emitted `gompute_mos1.ptx` measured directly, the same way
as §5.3:

| `arp_eval_mos1` | f64 jac | **f32 jac** | Δ |
|---|---:|---:|---:|
| FP64-pipe ops | 2 028 | **1 074** | **−47 %** |
| …of which `cvt` f32↔f64 (runs at f64 rate) | 0 | 187 | |
| FP32-pipe ops | 0 | 952 | |
| physical registers | 248 | **183** | −26 % |
| local (spill) | 0 B | 0 B | |
| occupancy @ block 256 | 16.7 % | **16.7 %** | unchanged |
| 64-bit vregs | 3 911 | 2 853 | −27 % |

| `arp_lim_mos1` | f64 jac | f32 jac | Δ |
|---|---:|---:|---:|
| FP64-pipe ops | 841 | **841** | **0 %** |
| registers | 114 | 114 | 0 |

### 8.1 It does not fix occupancy — measured, not predicted

Two blocks per SM at `block_size = 256` needs **≤ 128 registers**. `jac_f32`
takes mos1 from 248 to **183**. That is a real 26 % cut and it lands in the dead
zone: **occupancy is still 16.7 %**, one block per SM, 256 of 1 536 thread
slots. The driver says the same at `block_size = 128` — 2 blocks/SM, still 256
threads, still 16.7 %. What halving the block *would* change is the grid, 32
blocks instead of 16, enough to put work on all 24 SMs (§5.3). That lever is
orthogonal to precision and untested.

### 8.2 What it buys — measured wall clock, interleaved

`arp_lim_mos1` **does not move at all** — the limit/state pass works on the
residual and clamp path, not the derivative vector, so none of its 841 f64 ops
narrow. So the eval kernel drops 47 % but the pair drops **33 %**, 2 869 → 1 915
FP64-pipe ops per instance. The arithmetic projection from §5.2–5.3 was
`242 → 162 µs` of kernel, `453 → 373 µs` per iteration, **1.13×** end to end.

Measured instead — `parallel_inverters_2000`, the two binaries interleaved round
by round, 7 rounds, load ~19:

| binary | `--gpu` | `--backend cpu` | NR iters |
|---|---:|---:|---:|
| f64 Jacobian | 1398.4 ms | 1927.4 ms | 1356 |
| **`-Djac-f32=mos1`** | **1158.4 ms** | **1500.7 ms** | 1354 |
| | **1.207×** | 1.284× | |

**1.21× on the GPU**, better than the 1.13× the op count alone predicted — the
248 → 183 register cut buys scheduling latitude the instruction count does not
see. Newton iteration count moves 1356 → **1354**: the inexact-Newton tax that
`gpu-device-eval.md` §9 warns about is *negative* here, i.e. nothing. Values
agree with the f64 build to **3.9e-10 relative** on the sample
`check_fixtures --reference` flags (−0.003149681814093183 vs
−0.003149681815312781), and the whole `scaling` category behaves identically
under both binaries.

(The CPU column is here because the same interleaved pass produced it, not as a
CPU study — a sibling agent owns that.)

Why this is nonzero where §9.5 measured **0.0 %**: that experiment used **mos9 at
40 000 instances**, where the kernel spills (168 B of local memory per thread) and
is bound by spill traffic rather than issue rate, and where the per-point cost is
dominated by the host LU on a 40 000-unknown matrix. `mos1` at 4 000 instances has
**zero spill** and is measured at 94 % of the f64 issue ceiling — the one regime
in which removing f64 operations converts directly into time. §9.5's conclusion
should be read as "mixed precision does not rescue a spilling kernel", not
"mixed precision does nothing".

And the 187 `cvt.rn.f32.f64` narrowings are §9.6's strict-float tax showing up on
the smallest MOSFET in the catalog: they are **17 % of the kernel's remaining f64
budget**, and they exist only because `@setFloatMode(.strict)` forbids folding
the multiplies against `S.con`'s all-zero derivative vectors. VerA reaching
`.optimized` is worth more here than more precision work.

### 8.3 The side effect: it unblocks `inverter_chain_4k`, and that is luck

With `-Djac-f32=mos1` the 4 000-stage chain's **operating point converges
directly** — no pseudo-transient, one `tran-stats` line, 7 126 NR iterations,
**identically on CPU and GPU** — where the f64 build burns 93 070 iterations in
the fallback and then dies (§1). `ESPICE_SOLVER=jfnk` produces the same rescue at
7 100 iterations. Two unrelated perturbations both flip the same deck, which is
the diagnosis: **the deck sits exactly on the knife edge of the op continuation
ladder**, and this is not a fix for it. The op-ladder item at
`converger.zig:581` is still the real one.

It does, however, give the corpus its **second** GPU-eligible transient — 8 000
transistors, 32 blocks, the first deck in the tree whose grid covers all 24 SMs.
`-Djac-f32=mos1` binary, 5 interleaved rounds, load ~14:

| arm | median | min | max | vs ngspice |
|---|---:|---:|---:|---:|
| espice cpu | 13 412 ms | 12 104 | 14 440 | **0.71×** |
| **espice gpu** | **6 417 ms** | 5 974 | 7 319 | **1.49×** |
| ngspice 44.2 | 9 558 ms | 9 334 | 12 291 | 1.00× |

**gpu/cpu = 2.09×.** This is the goal met, on the biggest layout-shaped deck in
the tree: our CPU path *loses* to ngspice by 1.4× and the GPU path *beats* it by
1.5×. It also confirms §5.3's grid prediction to the number — GPU/CPU was
1.22–1.37× at 4 000 instances (16 blocks, 16 of 24 SMs) and is **2.09× at 8 000
instances** (32 blocks, all 24 SMs), because doubling the deck doubles the CPU's
work and only partly the GPU's.

### 8.4 It still does not close the arithmetic gap on this part

| | f64 element-ops/s |
|---|---:|
| this GPU, all 24 SMs | 76.2 G |
| this GPU, 16/24 SMs (the `pi2000` grid) | 50.8 G |
| **this CPU, 32 threads** (`gpu-device-eval.md` §1: 1449 GFLOP/s) | **724 G** |

The GPU is **9.5× behind on f64 arithmetic** device-wide, 14× behind at
`pi2000`'s grid. `jac_f32` moves the GPU's *effective* rate to
`1/(0.35/76.2 + 0.65/5239) = 212 G/s`; the same split on the CPU, where f32 is
only ~2× f64, gives `1/(0.35/724 + 0.65/1448) = 1073 G/s`. **The CPU stays 5.1×
ahead on arithmetic.** No fixture size changes that — it is a ratio, not an
offset.

The GPU wins today anyway, and the reason matters: **device eval on the CPU is
not arithmetic-bound.** It is a scattered read-modify-write per Jacobian entry
per instance (`remaining-2026-09-10.md` settled: the data-movement floor is
25–30 %, needing ≳18 flops per f64 word, and MOS1 has 3.0). The GPU turns that
scatter into a coalesced staging write plus a segmented reduce and has ~5× the
memory bandwidth. The measured CPU device half is 744 µs for 11.5 M f64 ops =
**15.5 G f64-op/s**, 2 % of the CPU's arithmetic peak. That is the gap the GPU is
actually collecting — not FLOPs.

---

## 9. Verdict

**Is "faster than ngspice on layout netlists, using the GPU" reachable on this
hardware?** **It is already met on the largest transistor deck in the tree** —
`inverter_chain_4k`, 8 000 MOS, GPU **1.49× ngspice** where our own CPU path is
**0.71×** (§8.3). It is not met on the R/C parasitic networks the phrase usually
means, and it was invisible until this session because the corpus had no fixture
that could show it and the benchmark was labelling CPU runs as GPU runs.

The evidence, in order of how much it matters:

1. **The result is real but it takes two non-default things to see it.** The deck
   only exists because §1 fixed the fixture, and it only converges under
   `-Djac-f32=mos1` (§8.3) — a knife-edge accident, not a fix. On the default
   build the only GPU-eligible transient in 280 fixtures is
   `parallel_inverters_2000`, where the GPU is 1.22–1.37×. **Make the win
   reproducible on the default build**: land the op-ladder item, and add a
   generated ≥ 25 000-transistor transient. The fixture must have transistors —
   `gpu-device-eval.md` §10 already measured the all-linear case
   (`rc_ladder_100k`, 200 K devices: GPU 3.03 s vs CPU 2.55 s, a loss; a ~10-op
   stamp cannot pay for the bus).
2. **Deck size is the dominant variable, and the mechanism is the grid.** 4 000
   instances is 16 blocks on 24 SMs and gives 1.22–1.37×; 8 000 is 32 blocks and
   gives **2.09×**. Below 6 144 transistors a third of the part is idle by
   construction. This is why "the fixtures are too small" is not a
   rationalisation — it is the measured slope.
3. **The kernel is done.** 94 % of the achievable f64 issue rate at this grid,
   248/255 registers with no spill, transfers + reduce + memset only 18 % of the
   device half, atomics already gone. Micro-optimising it is wasted effort.
   `jac_f32` is the one exception and it is measured at 1.21× (§8.2).
4. **Amdahl caps `pi2000` at 2.4×** end to end even with free device eval, of
   which 1.22–1.37× is already collected. The other 17 % is the 155 µs/iteration
   host residue — LU pivot-tape replay (n=2005, nnz=10 011, fill 1.2×, only 2
   full factors in the whole transient), companion-RHS vector math, convergence
   norms. Moving that to the device means a batched sparse LU, which
   `gpu-device-eval.md` §8 argues against on independent grounds — and a
   transient has one solve per iteration, so there is nothing to batch. The
   ceiling rises with deck size, which is item 1 again.
5. **On f64 arithmetic this part is 9.5× behind this CPU and mixed precision
   closes it to 5.1×, not to 1×.** The GPU's win comes from bandwidth and
   scatter, not FLOPs — the CPU's device half runs at 15.5 G f64-op/s, 2 % of its
   own arithmetic peak, because it is a scattered read-modify-write. That win
   survives only while the kernel stays below the register cliff, and every
   compact model in the catalog is already on it.

What would actually move the number, in order of expected value per unit of work:

| lever | expected | cost | status |
|---|---|---|---|
| **A ≥ 25 000-transistor transient fixture** | makes the win reproducible and puts the grid over all 24 SMs | one generated netlist | not done — the highest-value item here |
| **op ladder under JFNK** | `inverter_chain_4k` on the default build, without the `jac_f32` accident | real work at `dc/op` level | open, `converger.zig:581` |
| `jac_f32` on mos1 | **1.21× measured** on `pi2000` `--gpu` (§8.2), and it unblocks `chain_4k` | one build flag, already implemented end to end | measured here; not enabled by default |
| `block_size` 256 → 128 | up to 1.5× on decks under 6 144 instances (24 SMs instead of 16), 1.0× above | one comptime constant, affects every kernel | untested |
| An FP64 part | 9.5× on device eval | new hardware | — |

And the one thing that should **not** be done, restated with this session's
evidence: raising `gpu_max_model_bytes`. bsim4 is over the cap so there is no
PTX here to measure, but the two largest models that *are* emitted already sit
on the ceiling — bjt 255 registers with 1 672 B of spill, mos9 255 with 168 B,
both at 16.7 % occupancy — and **mos1**, a twentieth of bsim4's source size and
the simplest MOSFET in the catalog, is at 248 of 255 with nothing left to give.
A model an order of magnitude larger does not get a worse constant, it gets a
different regime. The cap is not protecting build time, it is protecting run
time.

---

## 10. Method

- Engine `446268a`, `zig build -Doptimize=ReleaseFast`, this worktree only. The
  mixed-precision arm is the same tree built `-Djac-f32=mos1 -p /tmp/jacf32-out`,
  so the two binaries differ in exactly one VerA codegen flag.
- ngspice `44.2` at `/nix/store/bywwgg84ccx0544z9qrfm4zc4ls30ghd-ngspice-44.2`
  (the PATH build — `remaining-2026-09-10.md` hazard 4 notes it is 8.5 % slower
  than a from-source build, which flatters our ratios; the from-source build is
  gone with the `/tmp` wipe).
- Wall clock is whole-process (`-b`, raw file written): medians of 5, except §6
  (9 interleaved rounds), §8.2 (7 interleaved rounds) and §8.3 (5 interleaved
  rounds). Newton iteration counts are `ZP_TRAN_STATS`.
- Accuracy: `check_fixtures.py --category scaling` is **13/14** on the default
  build (was 11/14) and **14/14** under `-Djac-f32=mos1`. With `--reference`
  (pointwise ngspice agreement, `atol=1e-6 rtol=1e-3`) the three chain decks
  deviate 0.18 % on one undershoot sample of `v(s1)` — the *same* deviation on
  both binaries to 9 significant digits, and the same class the sibling
  `parallel_inverters_*` decks already show at 0.29 %. Not introduced by the
  fixture change and not by mixed precision.
- **No profiler exists on this machine** — `perf`, `nsys`, `ncu`, `ptxas` and
  `cuobjdump` are all absent. Register counts, spill and occupancy come from the
  driver itself through `libcuda.so.1` (`cuModuleLoadData` +
  `cuFuncGetAttribute` + `cuOccupancyMaxActiveBlocksPerMultiprocessor`); PTX op
  counts are static mnemonic counts over the `.visible .entry` bodies in
  `.zig-cache/o/*/gompute_<model>.ptx`; the device/host split is the
  `ESPICE_GPU_EVAL_CHECK` replay ablation.
- **Contention**: load average 15–32 for the whole session, three other
  `zig build-exe` processes for most of it. Absolute times run 30–50 % high
  against `baseline-446268a`. Interleaved arms (§6) and the setup/steady split
  (§4, both arms in one pass) are the trustworthy comparisons; cross-session
  absolute numbers are not.
