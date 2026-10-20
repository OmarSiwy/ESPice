# Lane-batched simulation: research and design

**Status:** phase 1's lane core is implemented except the executor grouping
pass: `solver/lanes.zig` (`Lanes(W)`), `solver/lane_solver.zig`
(`LaneSolver(W)`: `LaneLu` with per-lane peel), `solver/lane_system.zig`
(the deinterleaved lane system), `converger.newtonLanes` and
`analysis/lane_circuit.zig` (`LaneCircuit(W)`). `newton` at W = 1 is
IDENTICAL in `zig build test-codegen`. Two departures from §3.1: masks
combine through `both`, `either` and `not` (at W = 1 a bitwise `&` of two
flags lowers to different code than the scalar `and`), and Newton's loop
exit and the delta gate's finite test keep their scalar form at W = 1 for
the same reason. Everything past phase 1 is design only.

**What it does.** A deck sweeps one subcircuit (`.step`, `.data`, `.mc`,
`.temp`, `.alter`) and expands into independent sweep-point queries. The
executor runs ready queries that share a pattern and an analysis as the W
lanes of one `Circuit(W)` batch, through one comptime-generic code path on
the CPU or the GPU. Results come back per query, exactly as an unbatched
run publishes them.

**Owner.** The executor owns grouping. The analyses are generic over W and
change only at their data-dependent decisions. Device evaluation is
unchanged.

**Lifetime.** One batch per group of ready queries. Lanes are packed from
the W per-query `Circuit`s when the batch starts and unpacked into them when
it ends.

**Workload.** MATCHA's FPGA tile sizing: 10 to 200 transistors (BSIM-CMG,
asap7), `.tran` over a few ns, `.meas` of delay and edge times, millions of
points, judged by points per second. The owner approved a CPU lane path (b)
and a GPU lane backend (c) behind one abstraction. This page measures what
each would buy and designs both as one instantiation parameter. Its
prototypes are in [`lane-batched-simulation/`](lane-batched-simulation/).

## Summary

1. **The workload is device-bound and its step grid is fixed** (§1). On a
   24-stage asap7 chain (48 BSIM-CMG, `.tran 1p 1.5n`), the transient time
   splits as follows:
   - device evaluation: 64%;
   - limiting, gates and state staging: 21%;
   - LU: 2%.

   Sixteen random sizing points took **identical** (t, dt) grids with no
   rejections, because `tstep` caps every step. The last `.meas` resolves at
   0.59-0.68 ns of 1.5 ns, so early stop alone saves about 57% of the steps.
2. **One generic engine, comptime W, two backends** (§3, §5).
   - `Circuit(W)` holds lane-major numerical state. The analyses take
     `comptime W` and use a seven-function mask primitive set. `W = 1`
     compiles to today's code, and a `tests/codegen.zig` probe proves it.
   - Per-lane work is written as kernel bodies generic over the value type,
     following the `lu_kernels.zig` and `DeviceKernel` precedents. The CPU
     runs a body at `@Vector(W, f64)`; the GPU runs it once per lane thread
     through Gompute.
   - The host control loop reads lane masks and launches bodies. It is the
     same for both backends.
3. **Lanes share iterations, never decisions** (§6, §7). Newton iteration
   counts are masked. Each transient lane keeps its own step control, run in
   rounds, so each lane is bitwise its own scalar run. A point's result then
   depends only on the deck and its own parameter values, which an optimizer
   needs.
   - Lockstep costs +5.3% Newton evaluations at W = 4 (measured).
   - Regrouping (refilling a finished lane) is the one piece that is not
     generic, and it lives in the executor.
4. **Device evaluation keeps the scalar family** (§4). Batching 4 points per
   BSIM-CMG `evalQ` call is at most 1.25x faster (prototype), about 1.05x
   end to end. It would also need a VerA contract change, because L and
   NFIN live in the `Model` row. Instead, the CPU deinterleaves each lane
   and runs today's scalar evaluation, so no device object is rebuilt. The
   GPU runs one thread per (instance, lane).
5. **The CPU path is the oracle and the GPU path is the throughput lever,
   and only with FP64 hardware** (§9). The CPU lane path is not a CPU
   speedup on BSIM-CMG. Early stop (57%), measurement-only mode and
   per-thread scalar points are. On this RTX 4060 Laptop (FP64 at 1/64) the
   GPU is estimated at 0.6-0.8x of the 24-core CPU. An FP64 datacenter part
   is one to two orders of magnitude more. This is unmeasured; E1 in §11
   measures it first.
6. **The entry point is the deck's own sweep, and the C API stays
   analysis-generic** (§2, §10). A swept deck is already a batch. MATCHA's
   `evaluate(values[N][P])` appends N sweep points as queries in one call
   and reads back measures plus a reason code per point.

## 1. The workload, measured

**Deck.** `gen_chain.py` builds 24 inverters (`pmos_rvt`/`nmos_rvt`,
`l=20n nfin={nfp|nfn}`). Each drives an RC wire (`{rw}`, `{cw}`). The deck
has a pulse input, `.tran 1p 1.5n` and `.meas` tpd, trise and tfall: 98
devices, n = 293 unknowns (BSIM-CMG's internal nodes), nnz(L+U) = 1385.

**Binary and machine.** The main checkout's ReleaseFast `espice` (sha256
`d00d3b4f…`, LEVEL 72 present), run with `--timing-in-depth`,
`ZP_TRAN_STATS=1` and `nice -n 10` on an i9-14900HX at load average 7-21
(other builds running). Read the ratios, not the milliseconds.

| Phase | Newton iterations | eval | update | factor | solve | rest | total |
|---|---:|---:|---:|---:|---:|---:|---:|
| `.op` | 364 | 59.5 ms | 1.5 ms | 3.2 ms | 0.6 ms | 0.4 ms | 65 ms |
| `.tran` (1531 steps, 1531 attempts) | 3477 | 565 ms (64%) | 188 ms (21%) | 14.3 ms (1.6%) | 4.9 ms | 114 ms (13%) | 888 ms |

- **Preparation.** The frontend and Problem creation take 5.8 ms, small
  next to the 0.98 s run.
- **"update"** is `finalizeStep` (`src/solver/converger.zig:225`): device
  limiting, the acceptance gates and `updateState` staging, all per instance
  and scalar.
- **"rest"** is step control, the accepted-point charge re-read, the LTE
  and recording.
- **One BSIM-CMG `evalQ`** costs 565 ms / 3477 / 48 = 3.4 µs.

**The step is `tstep`-bound.** Every `tstep` from 0.25p to 10p took zero
LTE and zero Newton rejections. Cost is linear in the step count, and
`tstep` alone sets the accuracy (reference: 0.25p):

| `tstep` | accepted | Newton | run total | tpd error | trise error |
|---|---:|---:|---:|---:|---:|
| 0.25p | 6031 | 12062 | 3.02 s | — | — |
| 0.5p | 3031 | 6118 | 1.61 s | +0.03% | +0.2% |
| 1p | 1531 | 3477 | 0.98 s | +0.13% | +1.5% |
| 2p | 781 | 1841 | 0.52 s | +0.56% | +5.6% |
| 5p | 331 | 893 | 0.30 s | +3.6% | +32% |
| 10p | 182 | — | 0.21 s | +15% | +143% |

This matters to MATCHA regardless of lanes. The LTE never binds, so
`tstep` (or `tmax`) is the accuracy knob, and halving it doubles the cost.

**Sixteen points, one grid.** `lockstep.py` drew 16 points (nfn and nfp in
{2, 3, 4}; rw and cw scaled 0.5-2x) whose tpd spans 123-212 ps.
- All 16 took the same 1531 (t, dt) pairs bit for bit, with no rejections.
- Newton took 2 or 3 iterations per step (mean 2.25).
- The last measure (`tfall`'s target crossing) resolved between 0.590 and
  0.684 ns. So 55-61% of every run comes after the answer is known (§7).

## 2. Entry point: sweep points in the query DAG

**Today** (`src/frontend/analyses.zig:54-310`, `variants.zig:72-155`):
- Every sweep point of `.step`, `.data`, card `SWEEP`, `.alter` and an
  HSPICE `.temp` list becomes its own query. `copyVariants` sets
  `tol.variant` per row (analyses.zig:304).
- Each non-OP query gets its own implicit OP prerequisite. `findOp` matches
  on the template and the whole `Op`, `tol.variant` included
  (session.zig:619-631).
- A point whose bins or topology move becomes a separate `Prepared` run
  with its own session (variants.zig:484, `prepare.zig:201-220`). So every
  row in one session's variant table shares one pattern by construction.
- Three cases loop inside one query instead: `.dc DATA=`/`MONTE=`, `.mc N`
  and a `.temp a b c` range card. They call `sweep/lanes.zig solveLanes`, a
  serial loop over points (`mc.zig:111-128`, `temp_sweep.zig`).
- The executor runs ready queries in chunks of `max_parallel` (`--jobs`).
  Each query gets a worker thread and its own `Circuit` copy. That copy is
  either `instantiate` plus `installVariant` (parameter writes, temperature,
  one `recompute`) or `fromSnapshot` of its OP prerequisite
  (session.zig:406-455, executor.zig:112-176).

**Grouping pass.** In `Session.advanceReady`, before chunking, ready queries
are partitioned into **lane groups** by key:

| Key part | Why |
|---|---|
| session and `Row.template` | one pattern, one set of batches; the row's writes are the only difference (`sameTopology`, variants.zig:1191) |
| query kind and every option except `tol.variant` and `tol.temp_c` | same analysis, same tolerances, same output schema |
| prerequisite kind (an implicit OP, a deck `.op`, none) | dependents of one OP group form the next group |
| backend eligibility | GPU groups need every batch resident (§5) |

Stimulus is not part of the key. Each lane keeps its own breakpoints (§7),
so a lane whose source moves an edge is still exact. Stimulus affects only
how coherent the lanes are, so it is a sort key: ready queries are sorted by
their source-parameter writes before cutting groups of W. A group shorter
than W runs narrower. A lone query runs at W = 1, which is today's executor
path, byte for byte.

**OP and dependents.** The OPs of one group run as one lane batch. Their
dependents (the `.tran` of each point) become ready together and form the
next group. Lane l of that group starts from lane l's OP snapshot, as
`fromSnapshot` does today. A dependency stays per query, and a batch is just
how ready nodes execute.

**Packing.** A batch builds its W per-query `Circuit`s exactly as today:
`instantiate` + `installVariant`, or `fromSnapshot`. `Circuit(W)` then packs
their numerical state lane-major (§3). When the batch ends, every lane's
final state is unpacked into its own `Circuit` and `Result`. Dependents,
`.meas`, plot labels (`executor.zig:346`) and output order
(`session.outputs`) see exactly what an unbatched run produces. Because a
lane is bitwise its scalar run, a batched deck's output is byte-identical
to the same deck at `--jobs=1`. That makes every swept corpus deck a test.

**Internal loops.** `solveLanes` (`.mc`, `.temp`, `.dc DATA`) runs its
points W at a time through the same `Circuit(W)`. Its `apply(k)`/`restore`
protocol stays, and only the inner `converger.run` becomes the W-wide
Newton.

## 3. The lane core

### 3.1 Primitives

The whole lane surface every analysis sees is one comptime namespace.
`W == 1` maps every function to the scalar operation it replaces:

```zig
pub fn Lanes(comptime W: comptime_int) type {
    comptime assert(W >= 1 and W <= 64); // LaneLu's mask width
    return struct {
        /// One value per lane. f64 itself at W = 1.
        pub const V = if (W == 1) f64 else @Vector(W, f64);
        /// One flag per lane, as bits; bit l is lane l.
        pub const Mask = if (W == 1) bool else @Int(.unsigned, W);
        pub const none: Mask = …; pub const every: Mask = …;
        pub inline fn splat(x: f64) V
        pub inline fn any(m: Mask) bool        // W = 1: m
        pub inline fn all(m: Mask) bool        // W = 1: m
        pub inline fn select(m: Mask, a: V, b: V) V    // per-lane pick; W = 1: if (m) a else b
        pub inline fn cmp(comptime op: CompareOperator, a: V, b: V) Mask
        pub inline fn lane(v: V, l: u6) f64    // read one lane (control, peel)
        pub inline fn each(m: Mask) LaneIter   // set lanes in ascending order
    };
}
```

That is seven functions, two types and two constants. There are no
reductions across lanes (`min`, `sum`): under the exact policy no decision
couples lanes. The one place that needs a cross-lane value, the sort key of
§2, lives in the executor. The precedents are `LaneLu(W)` (a V per entry, a
u64 failure mask; its W = 1 instantiation is the scalar oracle,
`src/solver/lane_lu.zig`), the `anytype` lanewise callbacks of stdpp
pipelines, and Gompute's generic bodies. **`DualFor` is not a precedent for
the lane axis.** Its lanes are derivative lanes inside one value
(`device/eval.zig:95`), and §4 shows why the two axes should not be fused on
the CPU.

The zero-cost claim is checked the way `tests/codegen.zig` checks
`Dual.mul`. Each primitive at W = 1, and one generic Newton gate (the delta
test over `x`, `x_old`, `dx` with `select`), gets a `gen_`/`hand_` pair. A
whole-function probe exports `converger.newton` at W = 1 against today's
`newton`, and `tools/asm_probe.py` must report IDENTICAL or EQUIVALENT.

### 3.2 `Circuit(W)` and its layout

`Circuit(1)` is today's `Circuit`. `Circuit(W)` for W > 1 holds W of them
(the lanes' device state stays in each lane's own batches) plus the
lane-major numerical state:

| State | Per lane | Today |
|---|---|---|
| x ring `cur`/`prev`/`trial`, Newton `x_old`, `dx` | 5n | `tran.zig:124`, `converger.Workspace` |
| `rhs`, `q_vec`, `i_prev`, charge ring `q_hist[4]` | 7n | `Circuit`, `tran.zig:137` |
| LTE tape ring `qt_hist[4]`, `qt_i_prev` | 5 n_qt (n_qt = 1368 here) | `tran.zig:199` |
| planes `g_vals`, `c_vals`, `a_vals` | 3 nnz(A) | `Circuit`, `ws.ensureAVals` |
| LU values `lx`, `ux`, `udiag` | nnz(L+U) + n | `LaneLu` already |
| per-lane scalars: gmin, λ, t, dt, ag0, order, iteration, status | O(1) as `V` or `Mask` | locals of `op.zig`, `simulate` |
| control: breakpoint state, echo table (256 f64), counters | about 2.2 KB | locals of `simulate` |
| device `Instance`, `State`, `Model` rows, lim plane | 48 x 384 B + rows x 22,640 B (bsimcmg) | each lane's own `Circuit` |

Shared across lanes: the pattern, the scatter tapes, `model_of`, the
ordering, the pivot tape (`SparseLu` base), the probe list and the options.

**Layout: element (i, l) at `i * L + l`, lanes innermost.** Every kernel
walks one shared tape over i (a stamp slot, an L/U entry, a gather index)
and touches every lane of entry i. Lanes innermost make that one vector load
on the CPU (L = W: `[]Lanes(W).V`, the same V as `LaneLu(W)`) and one
coalesced transaction per warp on the GPU (L = N lanes). SoA by lane
(`[l][i]`) would need a gather per lane per entry. Tape indices do not
change.

On the GPU, the instance and Model rows are packed lane-major as well
(`row * N + l`). Rows are deduplicated over the whole lane tuple, so
`model_of` stays one tape. Two instances share a row only if their Models
are byte-equal in every lane: `nfin={nfn}` and `nfin={nfp}` are equal at the
nominal point and differ in a lane.

### 3.3 Memory

Per lane on this deck: about 145 KB of vectors, planes, LU values and
instance rows (the LTE ring is 55 KB of it), plus 22.6 KB per distinct
bsimcmg Model row (`@sizeOf(Model)`, Setup included). That gives two rows
here (about 190 KB per lane) and about 10 for a sized MATCHA tile (about
370 KB).

| Backend | Lanes | State |
|---|---:|---:|
| CPU, W = 4 | 4 | 0.6-1.5 MB per batch: one P-core's 2 MB L2 |
| CPU, W = 8 | 8 | 1.2-3 MB |
| GPU, N = 8192 | 8192 | 1.6-3 GB, plus the probe ring (§7) |

N is chosen from free device memory. Measurement-only mode (§7) records no
waveform, so it adds nothing per step.

### 3.4 Compile time and code size

Device objects do not change: 87 objects, one evaluator per model, and no
new `Sink` or family instantiation (§4). The lane-generic host code is
`Circuit`, `converger`, `direct`, the integrator and `tran`, `dc/op`,
`dc/dc`, `sweep/*` and `ac/freq` with `freq_solve`: about 10-12k of the
32k lines in `src/analysis` + `src/solver`.

Each extra W instantiates that subset once more inside the exe's single
LLVM module, which costs 12-16 min at ReleaseFast today (AGENTS.md). So
**ship two widths**: W = 1 and one CPU width. That width comes from
`std.simd.suggestVectorLength(f64)`, which is 4 on AVX2 and 8 on AVX-512;
VerA measured W = 8 spilling on AVX2. The estimate is +2-3 min at
ReleaseFast for the one extra width and nothing for the GPU, whose kernels
compile in their own Gompute roots. It is unmeasured: phase 1 measures it
and gates on +20%. Supporting W ∈ {1, 4, 8} would cost about twice that.

## 4. Device evaluation

**Prototype result.** `bench.zig` runs VerA's `batch_family` harness (a
W-point family with the lead protocol) over the generated `bsimcmg.zig`
(VerA 0.10.3) with asap7 `nmos_rvt`, l = 20 nm, nfin = 3. It shares one
Model row across lanes, which is the coherent upper bound. Pack and unpack of
30 unknowns and 1860 outputs are included. Timings are the best of 7, in TSC
ticks per instance, pinned to one core, at load average 21:

| set | W = 2 | W = 4 |
|---|---:|---:|
| scalar `evalQ` | 7350 | 7448 |
| coherent (W copies of one bias) | 6379 (1.15x) | 5952 (1.25x) |
| lanes (one inverter point, output shifted ±30 mV per lane) | 6390 (1.15x) | 5933 (1.26x) |
| mixed (W unrelated points) | 6420 (1.14x) | 6049 (1.23x) |

**Divergence.** Points that left the leader's path were 0, 6 and 99 out of
256 at W = 4. Parameter lanes are coherent: the same transistor at the same
time with another size takes the same branches. For comparison, VerA's study
(`docs/measurements/batched-lead-2026-10-02.md`, removed in VerA 4a870ae8)
measured these cycle speedups at W = 4 with one instance shared by the lanes:
diode 1.26x, mos1 1.34x, bsim4va 1.61x, psp103 1.87x. With an instance per
point, mos1 fell to 1.02-1.16x. BSIM-CMG's 30 unknowns already fill the
vector registers with derivative lanes, so a point axis adds pressure rather
than finding idle lanes.

**Cost end to end.** Evaluation is 64% of the run. A 1.25x speedup there,
reduced by re-runs and Model gathers and then by the +5.3% Newton tail of
§6, lands near 1.0-1.1x. The batch family also needs three VerA changes:
- a per-lane status latch, because bsimcmg is `mutable_eval` and
  `batchOk` refuses it (`VerA lib/device/codegen/file.zig:198`);
- a lane-major `Model` view, because the batch key is one Model row while
  `l`, `nfin` and their setup cache live in the Model;
- the lead protocol for its 763 core comparisons.

**Decision: lanes evaluate devices with the scalar family.**
- **CPU.** `Circuit(W).eval` deinterleaves lane l's x, calls lane l's own
  scalar `Circuit.eval` (today's code), and interleaves its planes. That is
  O(n + nnz) copies per lane per iterate, against 48 x 3.4 µs of
  evaluation. It works for every device, mutable state included, and
  rebuilds no device object. At W = 1 there is no copy, because the
  lane-major planes are the circuit's own slices.
- **GPU.** One thread per (instance, lane), with the scalar family through
  a lane-strided `Sink`. SIMT masks divergence per thread. Threads are
  ordered lane-innermost, so a warp is 32 lanes of one instance: coherent
  control flow and coalesced loads (§5).

**When to revisit the batch family:** a MATCHA profile dominated by cheap
devices (R, C, diodes: up to 1.75x in VerA's study) or by the LU. That is a
VerA phase, not part of this design.

## 5. One body for CPU and GPU (Gompute)

Gompute's spec layer (`map`, `zip`, `mapIndexed`, `reduce`, `gather`,
`scatter`) runs a generic body at SIMD width on `.cpu` and one thread per
element on CUDA and HIP (`~/Documents/Projects/Zig/Gompute/skill/gompute/SKILL.md`).
Two of its rules decide how ESPice uses it:

- **`Params` cannot carry pointers or slices.** That is a compile error
  naming the field. Every lane kernel here walks a shared tape (`gath`,
  `slots`, `up`, `dmap`), so none of them fits a spec.
- **`Kernel(spec, .cpu)` has no `alloc` or `launch`.** Residency is a GPU
  concept, and the CPU path calls the body directly.

So lane kernels follow the two precedents ESPice already ships:
- `device/eval.zig`'s `evalRange` runs on the host through a host `Sink` and
  on the GPU inside `DeviceKernel` (`eval.zig:2675`, one thread per
  instance, `gompute.GlobalPtr` arguments).
- `solver/lu_kernels.zig` `Kernels(Sy, cap, lanes)` takes a sync provider
  and a pointer type `P(T)`, and runs on host threads (`runHost`) and as
  device blocks.

The lane bodies are generic over the value type and a pointer type:

```zig
/// One Newton update and delta gate for lanes [l0, l0 + width(V)):
/// V = Lanes(W).V on the CPU (one call per batch), V = f64 on the GPU
/// (one call per lane thread, l0 = thread id).
pub fn updateLanes(comptime V: type, comptime P: fn (type) type, n: u32, L: u32, l0: u32,
    x: P(f64), dx: P(f64), x_old: P(f64), active: Lanes.Mask, tol: Tol) Lanes.Mask
```

At W = 1 that is today's loop. On the CPU it is `@Vector(W, f64)` loads at
`i * W`. On the device, `P = gompute.GlobalPtr` and `L = N`. A raw entry
point exports it per body with `g.exportRaw`, launched with `g.RawKernel`;
host builds compile the export away.

| Body | One call covers | Notes |
|---|---|---|
| device eval | instance x lane | `evalRange` with a lane-strided `Sink`: x at `gath * L + l`, stamps at `slot * L + l`. Today's `DeviceKernel` is the L = 1 case; the GPU form bumps `abi_version` because the plane layout is frozen (`gpu-evaluation.md`) |
| staging reduce, assembly `A = G + ag0_l C`, gmin | entry x lane | ag0, gmin, λ come from a per-lane buffer, not params, so a captured graph never changes |
| `lane_refactor`, `lane_solve` | lane | the scalar replay of `SparseLu.refactorTape` per lane, with failure bit l. Lane l is bitwise the host replay (§5.2) |
| Newton update, delta gate, residual gate, plausibility | lane | writes `active` and `converged` bits |
| limiting | instance x lane | `limitRange` per lane; its flag ORs into lane l's `limited` bit |
| LTE bound | lane | `integrator.stepBound` over lane l's tape ring; one f64 per lane |
| charge re-read, state staging, commit/revert | instance x lane | the resident state kernels of `gpu-evaluation.md`, lane-strided |
| `.meas` streaming update | lane | per-card O(1) state (§7); `resolved` bits |

**What stays off the kernel path:**
- **Full factor with threshold pivoting**, ordering, BTF and pattern
  freeze. These need DFS, allocation and a value-dependent pivot search,
  so they stay host, scalar, once per pattern or per peel.
- **Per-lane control decisions.** Accept or reject, dt, order, breakpoint
  landing, rung choice. They are O(1) per lane and branchy, and they run on
  the host from downloaded per-lane numbers (§7). A GPU thread could run
  them, but on the host they are the same code for both backends.
- **Value-sized allocation** (`floatingHolds`, the noise grid, pz roots)
  and I/O.
- **Device types without a GPU image** (`gpu_host_only`, runtime `.hdl`)
  or with host hooks (VPI, `systf`). A group containing one runs on the CPU
  backend. That is an executor decision (§2).
- **Dense partial-pivot LUs** (HB dense, PAC dense, the shooting dense
  monodromy, pz). They stay scalar per lane (§6).

### 5.1 Residency and launch cost

Lane state is allocated once per batch with `kernel.alloc` / `RawKernel.alloc`
and stays on the device across iterates and steps.

**Per Newton tick:**
- the per-lane scalar buffer goes up (pinned, async);
- one captured graph runs eval, reduce, assembly, refactor, solve, update
  and gates;
- N bytes of masks come down, then one sync.

**Launch cost.** OVERHEAD.md (RTX 4060 Laptop) measures:
- `launch` + sync: 4.8 µs;
- each extra launch: about 1.5 µs CPU-side;
- a 10-launch graph replay + sync: 13 µs, against 19.9 µs as separate
  launches.

At 3477 ticks per batch that is about 50 ms of overhead, against about
160 ms of evaluation per tick at N = 8192 (§9). Graph capture applies, with
one constraint: params are copied at capture, so every per-tick scalar lives
in a device buffer (the `params` struct rule of `gpu-lu.md` §4.3).

**Per round:** N x 6 f64 come down (LTE bound and step-end flags) and N x 5
f64 go up (t, dt, ag0, xfact, method). The batch uploads parameter rows once
and downloads probe rings or measures once.

**Startup:** `cuInit` and the primary context cost 220-255 ms once per
process. A warm-up thread at startup hides it (OVERHEAD.md "Startup").

### 5.2 The lane LU kernel (extends `gpu-sparse-lu.md` §4)

§4's `refactor_level` puts one block on a column and parallelizes inside
it. That is the shape for one large matrix, and it ships as `gpu-lu.md`
stage 1. For N small matrices on one tape, the parallelism is the lanes:

```
lane_refactor(tab, val[nnz_lu * N], fail[N]):     # thread = lane l, stride N
  for k in 0..n:                                  # pivot order, shared
    scatter column k of A_l through amap          # val[slot * N + l]
    for p in up[k]..up[k+1]:                      # stored topological order
      u = val[uslot(p) * N + l]
      for t in dmap run of p: val[dst(t) * N + l] -= val[src(t) * N + l] * u
    pivot / growth check -> fail[l] = 1; L column /= d
lane_solve: the same, per thread, over the L and U rows
```

- **Access.** Indices are lane-uniform (one load broadcast across a warp)
  and values are coalesced. There are no levels, barriers or tickets.
- **Cost on this deck:** about 11 KB of values per lane, so 90 MB read and
  written per refactor at N = 8192 (under 1 ms at 256 GB/s), and roughly
  10^8 FP64 flops, under 1 ms even at 1/64 rate. That is under 1% of the
  eval.
- **On the CPU** the same body at V = `@Vector(W, f64)` is `LaneLu(W)`'s
  loop. `LaneLu` already exists and is tested bitwise against the scalar
  replay. The kernel form is `LaneLu` restated over `P(T)`, and `LaneLu`'s
  test is its oracle.

## 6. Decision points and the policy for each

Each analysis is the same code, generic over W. It changes only where a
branch or loop exit reads a value. Each such point falls into one of five
classes:

| Class | Primitive | Policy |
|---|---|---|
| **A. lanewise formula choice** (no control flow) | `select` | none; exact |
| **B. per-lane loop exit** (convergence) | `active` mask, `any(active)` loop, `select` on update | **mask**; finished lanes freeze, their slots compute and are discarded |
| **C. per-lane continuation parameter** (gmin, λ, dt, step) | a `V` parameter plus a mask | **mask**; every lane moves its own parameter |
| **D. structure from the pattern only** (dense vs Krylov route, HB route) | none, lane-uniform | shared by construction |
| **E. structure from values** (a re-pivot, held rows, `TopologyChanged`, value-sized output) | `each(mask)` → W = 1 | **peel** that lane to the scalar instantiation |

**Regrouping** is the executor's: refilling a lane whose point finished
early (§7). It is the only policy that is not generic. **No decision uses a
shared min across lanes:** a shared dt would make a point's result depend on
its partners. Phipps et al. (2017) prove the same for coupled ensemble norms
(§12).

The decision inventory, from a walk of every analysis (file:line in this
tree):

| Analysis | Decision points | Classes | Change |
|---|---|---|---|
| Newton (`converger.zig:183-244`) | loop `iter < max_iter`; gates in order: limited :349, iteration 1 :350, delta :351, plausible :352, residual :355, `load_ok` :358, device :360, `updateStates` flip :371; INITFIX pass :237 | B | `converged`/`active` masks; per-lane `init_fix` bit; `iterations` as a per-lane counter |
| direct solve (`direct.zig:232-377`) | value bypass :232; Thomas/BBD fallbacks :275-286; replay vs full factor :292-298, `replayHolds` :322 | D (engine), E (re-pivot) | lanes take the `LaneLu` engine; a failure bit peels lane l to its own `SparseLu` full factor and a W = 1 sub-batch; the bypass is dropped at W > 1 |
| JFNK / GMRES (`converger.zig:474-527`, `gmres.zig`) | breakdown and convergence exits | B | per-lane Krylov with masks; phase 6, only when a lane deck needs it |
| `.op` ladder (`op.zig:94-338`) | rungs in order: plain :138, gmin :166-212 (factor adapt, back-off), source :247-261 (×1.5 / ×0.5, `delta < 1e-4`), JFNK :279, OPtran :322 | B + C | lanes that converge at a rung freeze; the rest enter the next rung together, each with its own gmin or λ (`V`); OPtran runs the failing lanes as a W' transient batch |
| floating nodes, gmin stamps (`op.zig:115, 384-463`) | union-find over values; stamp set from `g_vals` | E | per lane; lanes whose holds differ peel |
| `.dc` sweep (`dc.zig:166-228`) | warm start or cold ladder :193-209; per-point outcome :215 | B, C | lanes are **variant rows**, each sweeping the same values in lockstep; the sweep axis stays sequential, so the predictor and warm start are per lane |
| `solveLanes` (`.mc`, `.temp`, `.dc DATA`) (`lanes.zig:40-58`) | warm from the previous lane :45 | B | W points per batch; "previous lane" becomes the previous batch's lane l |
| tf, xf, sens, dcmatch, acmatch FD (`tf.zig:80`, `xf.zig:91`, `sens.zig:115-164`, `dcmatch.zig:175`, `acmatch.zig:114`) | floors, Smith division, `ZeroDelta`, `TopologyChanged` | A, E | `select`; FD perturbations are more lanes (one per parameter, which is today's loop) |
| AC family (`freq_solve.zig:356-434`, `ac/freq.zig:78`) | centre factor, non-LU engine, tape length, bad lanes | D, E | the lane axis widens from ω to (point, ω): `Stacked` reads lane l's own G, C planes and ω_l; one pivot tape |
| noise (`noise.zig:31-53, 230`) | formula thresholds; sampled grid length | A; E | `select`; the grid is built per point on the host, so lanes share it only when it is equal (the usual case: it depends on the card) |
| lstb margins (`lstb.zig:261-292`) | regula falsi to 100 solves | B | per-lane bracket, masked |
| `.tran` (`tran.zig:361-667`) | loop end; Newton reject :428; `reject_at` :451; state flip :462; LTE :500-518; VPI :525; promotion :547; breakpoints :591-622; clamps :657 | per-lane control | §7: rounds, per-lane state machine, no shared step |
| shooting `.pss` (`pss.zig:131-492`) | per-step Newton; shooting loop exit :368; FD columns; oscillator damping, settle, start | B, C | fixed-step trapezoid periods run as lanes, one lane Newton per step (`pss.integrateLanes`); FD columns, monodromy LU, GMRES and damping per lane, scalar (phase 6) |
| HB / MHB (`hb.zig:237-253`, `mhb.zig:565-575`) | convergence; backtracking `step` halving and regrowth | B, C | phase 6b, GPU only (plans/phase6-periodic-lanes.md §1.1); not grouped on the CPU |
| PAC / pnoise (`pac.zig:54-211`, `pnoise.zig:131`) | route by size; GMRES convergence; noise topology | D, B, E | phase 6b, GPU only (plans/phase6-periodic-lanes.md §1.1); not grouped on the CPU |
| pz (`pz.zig:133-165`, `qz.zig`) | QR/QZ deflation, splits, iteration counts; root count | E | **not laned**: every step of QZ is a data-dependent structural choice and the output length varies. pz runs per lane at W = 1 after a lane OP; it is O(n^3) dense work on n ≤ a few hundred |
| post (`four`, `fft`, `disto`, `mosra`) | sample windows, thresholds, bisection | A, E | per-result post-processing on the host after unpacking; nothing to lane |

## 7. Transient: rounds, early stop, measures

**Rounds.**
1. Every live lane makes one attempt at its own (t_l, dt_l).
2. The batch ticks Newton until every active lane has ended its attempt
   (class B).
3. Each lane runs today's step-end logic on its own columns: state-flip
   query, `reject_at`, LTE over its tape ring, promotion, breakpoint
   landing, and dt and order for the next attempt.
4. A lane that rejects retries its own interval. A lane that accepts
   advances.

Lanes desynchronize only when they disagree, which is still exact. Each
lane's breakpoints come from its own source rows, so a lane with a moved
edge lands on its own edges.

**Cost.** The 16 measured points took identical grids, so rounds behave as
lockstep. Re-running their per-step Newton counts in lockstep groups gives
**1.032x** (W = 2), **1.053x** (W = 4), **1.069x** (W = 8) and **1.085x**
(W = 16) the evaluations of independent runs.

**SimState per lane.** Devices read `t`, `dt`, `kind`, `iteration` and
`initial_step` through `SimState`, which is global on `Circuit` today
(`Circuit.zig:1098`). Each lane's own `Circuit` carries its own, which the
CPU deinterleave path gets for free. On the GPU, `SimState` becomes a
per-lane buffer read by the eval body. bsimcmg's core ignores it, so only
sources and history devices read lane time.

**Early stop.** A lane ends when every card it was asked for has resolved.
Resolution is a per-card event of the streaming evaluator below:
- WHEN, TRIG/TARG and FIND AT resolve at the event;
- windows resolve at `to`;
- LAST, a window with `to = 0`, JITTER without `to`, `_CONT` and PARAM
  over unresolved cards resolve only at `t_stop`.

The lane's `done` bit clears, it leaves the round set, and the query
completes with a truncated waveform. That is legal because the caller asked
for measures only.

**Abort bound** (optional, per point). A lane whose card is unresolved at
`t > bound` stops with `ESPICE_REASON_ABORTED` and NaN values.

**Savings.** On the chain the last card resolves at 0.59-0.68 ns, so a lane
stops at about 43% of its steps. Within a W-group, early lanes idle until
the slowest ends. The spread above costs 5-8% idle at W = 4 (from the 16
targets). Refill (regrouping) closes it: when a lane ends, the executor
loads the next ready point into that slot at the next round boundary, from
its own OP lane. It is host-only: pack one lane, reset its control. It is
worth building only when the idle fraction is measured above about 10%,
which is likely at the GPU's N, where stragglers hold thousands of lanes.

**Measurement-only mode.**
- `Waveform` is replaced by per-card streaming state (counters, `above`,
  `pending`, the previous (x, y, y2), the wanted count, the accumulator,
  and a 4-sample ring for INTEG/RMS Simpson panels).
- These come from perf's one-pass `Wave.crossings`
  (`ESPice-perf src/output/measure.zig:612-699`), which already finds N
  events in one forward pass with O(1) state and linear interpolation.
- Each accepted step feeds its point to every card. No per-point waveform
  memory is allocated.
- Cards that need the whole waveform (LAST, JITTER, FFT-based THD/SNR/SFDR,
  `.check`) keep a recording of only the vectors they read. In
  measurement-only mode they are refused unless the caller allows that.
- On the GPU this is a per-lane `.meas` body that runs after each accepted
  round, reading the probe slots of x, so only `resolved` bits come down.
- A dependency inside a card (`TD=TRIG`, clause refs to earlier measures)
  runs that card after the card it reads resolves. The streaming update then
  needs the target's crossing state as well as its threshold. It is still
  O(1).

## 8. The other approved features

| Feature | Design | Cost in the lane abstraction | Effort |
|---|---|---|---|
| **Warm start across nearby points** | #97's design: only `x` crosses (`Deck.op_guess`, `executor.zig:313-317`). A warm start skips the junction seed and INITFIX, and on failure falls back to the full ladder (`op.zig:54, 132`). "Nearby" is structural, not a distance. For lanes, lane l's guess comes from a fixed reference: the template's nominal OP, or a caller-chosen anchor point. It must not come from "the previous point", which would make a point's result depend on its order and break §10's determinism rule | none: x is per lane already; the guess is one more `select` source | 2-3 days |
| **Corners (tt/ff/ss)** | an `.alter` that swaps `.lib` sections with the same cards and topology is already a parameter-write row (`variants.zig:344-358`), so a corner is a sweep point; a corner that moves a bin is a separate run and never shares a group | none: Model rows are per lane | 0 beyond phase 2 |
| **Temperature per lane** | `installVariant` already calls `setCircuitTemp` + `recompute` per query (`executor.zig:156-175`), which re-runs `setup` and `setupInstance` (`eval.zig:1981`, 2079); the row's `temp_c` is a lane property | none: per-lane rows | 0 |
| **Per-lane stimulus** (polarity, input selection, same edge times) | source parameters as live `.param`s (`pulse(0 {va} …)`); a source with v1 = v2 keeps its edge breakpoints, so selection and polarity keep grids aligned. Sort key of §2 | none; lanes with different edges stay exact and only lose coherence | 0-2 days (a test deck) |
| **Failure reason codes** | an enum per point (§10). The executor already keeps each query's failure error (`session.rows.failure`); the C layer maps names to codes. Measure misses today print an error line and give NaN (`measure.zig` `NoSuchVector`/`OutOfInterval`); they become `MEASURE_NOT_FOUND` / `MEASURE_UNRESOLVED` | none | 2 days |
| **Energy per transition** | `.meas tran e integ par('-v(vdd)*i(vdd)') from=.. to=..`: every V source has an `i(name)` column (`builder.zig:699-719`) and INTEG exists (`measure.zig:190`). Streaming INTEG needs the 4-sample ring above; a `.meas` per supply | none | 1 day plus a fixture against ngspice |
| **Leakage from `.op`** | the leakage is the OP's `i(vdd)`; add `.meas op name find i(vdd)` (the measure analysis map has no `op` kind today, `frontend/measure.zig:19-24`). The `.tran`'s implicit OP (`tran_op=true`, sources at t = 0) is the input-low state at no extra solve; another input state is a second sweep point or an HSPICE `.op <time>` snapshot (already supported) | none: the OP lanes run first anyway | 2-3 days |

## 9. What the GPU would buy (estimate)

- **Kernel rate.** The backend cost model sets device kernels at 0.12 of
  the host's serial evaluation time on this RTX 4060 Laptop
  (`gpu-evaluation.md`, "Choosing the backend"). For bsimcmg that is about
  0.4 µs per instance-eval, against 3.4 µs on one host core.
- **Per batch.** One tick at N = 8192 evaluates 393k instances in about
  160 ms. A full run is 3477 ticks: about 9.5 min for 8192 points, or about
  70 ms per point. Early stop cuts that by about 57%.
- **Against the CPU.** The 24-core CPU running scalar points does 0.98 s /
  24 ≈ 41 ms per point, if it scales linearly over 8 P-cores and 16 E-cores
  (unmeasured; phase 0 measures it). So the GPU adds about +60-80% to the
  CPU on this machine.
- **FP64 hardware.** The kernels are FP64-bound (exp, log, div), and
  Gompute's f32 math also computes in f64 on the GPU (SKILL.md). An A100 or
  H100 has 30-150x the 4060's FP64 rate.
- **Build cost.** bsimcmg's dense kernel has an 83 KB stack frame and costs
  ptxas 250 s and 9.8 GB of RAM. The sparse layout is 18.5 KB, 77 s and
  2.3 GB (`gpu-evaluation.md`, Inventory). The sparse layout must become
  bsimcmg's default first.

## 10. C API

A swept deck needs nothing new: `espice_run_all` (or `advance_ready`) runs
its sweep points, and the executor batches them. MATCHA's
`evaluate(template, values[N][P])` needs three things that do not exist:
appending N points in one call, reading `.meas` values as numbers, and a
reason code per point. The surface stays analysis-generic: it appends points
to whatever analyses the deck holds.

```c
/* Why a point produced no (or partial) values. */
typedef enum {
    ESPICE_REASON_OK = 0,
    ESPICE_REASON_NO_CONVERGENCE = 1,      /* OpDidNotConverge, HbDidNotConverge, ... */
    ESPICE_REASON_TIMESTEP_TOO_SMALL = 2,  /* TimestepTooSmall */
    ESPICE_REASON_SINGULAR_MATRIX = 3,     /* SingularMatrix, FloatingNode */
    ESPICE_REASON_MEASURE_NOT_FOUND = 4,   /* a .meas names a missing vector */
    ESPICE_REASON_MEASURE_UNRESOLVED = 5,  /* its event never happened (value NaN) */
    ESPICE_REASON_ABORTED = 6,             /* abort bound passed before resolution */
    ESPICE_REASON_MODEL_BIN_NOT_FOUND = 7, /* ModelBinNotFound */
    ESPICE_REASON_TOPOLOGY_CHANGED = 8,    /* TopologyChanged, a moved .if branch */
    ESPICE_REASON_INVALID_PARAMETER = 9,   /* non-finite value, NonFiniteParameter */
    ESPICE_REASON_DEVICE_REFUSED = 10,     /* DeviceRefused */
    ESPICE_REASON_OTHER = 255              /* espice_query_error_message names it */
} espice_reason;

typedef struct {
    uint32_t struct_size;
    uint32_t measures_only;   /* 1: record no waveforms (section 7) */
    uint32_t early_stop;      /* 1: end a point once its measures resolve */
    uint32_t warm_start;      /* 0 cold, 1 from the nominal OP */
    double abort_after;       /* t past which an unresolved measure aborts; 0 = off */
} espice_points_options;

/* Appends count sweep points: values is [count][live_param_count] row-major,
 * in the order of espice_create_options.live_params. Each point runs every
 * analysis card of the deck, as a .step point would; first_id receives the id
 * of point 0's first query (points are consecutive). All-or-nothing. A point
 * the template cannot hold (bin, topology, .if) is appended and fails with
 * its reason when run. */
espice_status espice_append_points(espice_problem *, const double *values,
    size_t count, const espice_points_options *options, uint32_t *first_id);
/* Measures of points [first, first + count): out is [count][measure_count]
 * row-major in the order of names; reasons is [count]. NaN where a measure
 * has no value. Requires every point's queries to be terminal. */
espice_status espice_copy_point_measures(espice_problem *, uint32_t first_id,
    size_t count, const espice_bytes *names, size_t measure_count,
    double *out, uint32_t *reasons);
/* The lane width the executor groups points into on this problem's backend:
 * W on the CPU, N on a GPU; 1 when batching is off. Advisory. */
espice_status espice_lane_width(espice_problem *, uint32_t *out);
```

- **Mapping.** `register_template` maps to `espice_create`, with
  `live_params` set to the P names and `backend` and `max_parallel` set.
  `evaluate` maps to `espice_append_points` + `espice_run_all` +
  `espice_copy_point_measures`. MATCHA's thread pool becomes `max_parallel`
  workers inside one handle, with batching inside each worker. Or MATCHA
  keeps one handle per pool thread; both are legal under the existing
  serialization rule.
- **Reuse.** A point is one `Tuning.set` variant row, so refusals come from
  `set_params` unchanged. Ids, `espice_get_query_info`,
  `espice_copy_result` (waveforms when `measures_only = 0`) and
  `espice_query_error_message` (the full error name behind `OTHER`) work on
  points as on any query.
- **Determinism.** Point i's measures and reason depend only on the deck
  and `values[i]`. They do not depend on count, order, lane width,
  `max_parallel` or the other points: bitwise on one backend; CPU and GPU
  agree to tolerance. This follows from the exact per-lane policy (§6) and
  from warm starts from a fixed reference (§8).
- **Indexing.** Parameters are addressed by position in `live_params`.
  SPEF/DSPF "set R/C by array index" maps onto the same `values` row if the
  parasitic loader registers its elements as live parameters in a fixed
  order. The point layout then needs no change.
- **Not included:** a separate batch handle (a swept deck is the batch), a
  width override (width affects only speed), progress callbacks, and a Rust
  crate (not approved).

## 11. Phases, effort, tests

The order runs from oracle to throughput. OP/DC goes first because every
analysis starts from an OP. It exercises Newton masks, the ladder and peels
without time control, and its corpus decks are a cheap bitwise oracle.
**Transient comes before AC.** MATCHA is a transient workload. AC already
fills the CPU's W with frequency lanes (`freq_solve.solveBatch`), so
(point, ω) lanes buy nothing on the CPU and matter only on the GPU. The GPU
follows the transient because E1 decides whether the GPU is worth its
phase. Estimates are for one engineer at today's build times.

| Phase | Work | Effort | Gate |
|---|---|---|---|
| 0. Points API, scalar | `espice_append_points` over existing per-point queries; `espice_copy_point_measures` via `measure.evaluateAll`; reason enum; abort bound; early stop and measurement-only for the scalar `simulate` (streaming cards) | 1.5-2 weeks | measures match `espice` CLI `.meas` on the 16 points; shuffled points give byte-identical rows; early stop leaves values unchanged |
| 1. Lane core | `Lanes(W)` primitives with W = 1 codegen probes; `Circuit(W)` pack and unpack from W `Circuit`s; deinterleaved scalar eval; `LaneLu` engine at W with peel; `converger.newton` generic; the executor grouping pass at W = 1, then W | 3 weeks | `newton` at W = 1 is IDENTICAL in `tools/asm_probe.py`; ReleaseFast compile time ≤ +20% |
| 2. OP/DC lanes | the `.op` ladder masked (per-lane gmin and λ, OPtran as a lane transient later); `.dc` with lanes as variant rows; `solveLanes` W-wide; warm start from the nominal OP | 2-3 weeks | every corpus OP/DC deck byte-identical batched vs `--jobs=1`, replicated and mixed |
| 3. Transient lanes | rounds and per-lane control; per-lane SimState; streaming measures and early stop in lanes; probes only for requested cards | 3 weeks | every corpus `.tran` deck byte-identical batched; the 16-point lockstep test (§1) bitwise against scalar runs |
| 4. GPU backend | **E1 first** (2-3 days): bsimcmg's sparse kernel over 48 x N instances on the 4060; stop if above 0.2 of host serial. Then the lane bodies over `P(T)`, raw exports, the lane-strided eval `Sink` (ABI bump), `lane_refactor`/`lane_solve`, mask and LTE downloads, graph per tick, packed rows | 4-6 weeks | lanes equal phase 3 to the `test-gpu` tolerance (6e-9 of rtol 1e-3); throughput against phase 0 on all cores |
| 5. AC family | `Stacked` over (point, ω); noise, sp, tf, sens, dcmatch, acmatch through the same OP lanes | 1-2 weeks | corpus AC decks byte-identical batched |
| 6. Periodic | shooting periods as lanes (`pss.Shoot`, `integrateLanes`); HB/MHB/PAC/pnoise in a GPU-only phase 6b | ~3.5 days (6b: 2-3 weeks after phase 4) | swept `.pss` tests bitwise (no swept `.pss` deck in the corpus); periodic corpus byte-identical lanes off |
| deferred | refill (regrouping) when idle > 10%; VerA batch family for cheap-device decks | 1 week; VerA 2-3 weeks | measured idle; a MATCHA profile |

**Tests,** each a differential against a named oracle:
1. **W = 1 is today.** Codegen probes for every primitive and for
   `newton`, plus the whole corpus at W = 1 through the new code with
   byte-identical output.
2. **Replication.** W copies of one point are byte-identical to each other
   and to the scalar run, at W = 2, 4 and 8 and at the GPU's N, on every
   corpus deck of the analyses phased in so far. That makes the whole
   fixture corpus a lane test without new expected files.
3. **Batched equals unbatched.** Every swept corpus deck under the grouping
   pass vs `--jobs=1` with batching off: byte-identical output and `.meas`.
4. **Mixed lanes.** The 16 points of `lockstep.py` in one batch and in
   every permutation. Add a lane forced to fail Newton (cw = 0), a NaN
   parameter, a lane that needs its own pivot tape, and a lane with a moved
   source edge. Each lane must equal its scalar run bitwise, and the others
   must be unaffected.
5. **GPU parity.** The `test-gpu` decks as replicated lane batches under
   the existing tolerance; `VERDICTS.tsv` must not move.
6. **API.** The phase 0 checks, every reason code from a deck built to
   trigger it, and shuffled `values` giving byte-identical output.

## Risks

1. **CPU throughput for BSIM-CMG comes from early stop and all-core scalar
   points, not from lanes.** The measured upper bound for batched
   evaluation is 1.25x, about 1.05x end to end, so the CPU lane path is the
   oracle and the GPU's host side. If MATCHA expected (b) to be a CPU
   multiplier, phase 0 is where the CPU win is.
2. **The GPU pays only with FP64 throughput.** It adds about +70% on this
   RTX 4060 Laptop (estimate). bsimcmg's kernel build is heavy, and Model
   rows take 22.6 KB per lane per size. E1 measures the rate before any
   other phase 4 work.
3. **Generic-W cost and exactness assumptions.**
   - The extra width in the exe's single LLVM module is estimated at
     +2-3 min of ReleaseFast. It is gated in phase 1.
   - Bitwise parity rests on assumptions measured on one deck: lanes
     sharing a pivot tape (grouped at start, peeled after), parameter lanes
     coherent (6/256 off the leader's path), and grids staying in step
     (16/16).
   - An LTE-bound or oscillating deck desynchronizes lanes. Results stay
     exact, but idle tails and warp divergence grow. Tests 3-4 and a real
     MATCHA deck settle it.

## 12. Prior art

Surveyed 2026-10-19:
- **verified**: read in the source's own full text or official docs;
- **abstract**: read in the publisher, arXiv or OSTI abstract only;
- **unverified**: seen only in a search snippet, because the page returned
  403 (ACM, IEEE, ResearchGate, cadence.com).

**Device evaluation on GPU and SIMD (one circuit).**

| Work | Batched | Result (baseline) | Status |
|---|---|---|---|
| Gulati, Croix, Khatri, Shastry, "Fast Circuit Simulation on Graphics Processing Units", ASP-DAC 2009 ([slides](https://www.aspdac.com/aspdac2009/archive/pdf/4C-6s.pdf)) | BSIM3 eval over instances, single precision, branches masked | eval 30-40x; **whole run 2.36x** vs OmegaSIM (Amdahl) | verified |
| Kapre, DeHon, "Performance comparison of single-precision SPICE Model-Evaluation on FPGA, GPU, Cell, and multi-core processors", FPL 2009, DOI 10.1109/FPL.2009.5272548 ([pdf](https://ic.ese.upenn.edu/pdf/spice_fpl2009.pdf)) | VA-compiled eval, autotuned vector length | GPU 3-131x, bsim3 30x vs Xeon 5160 | verified |
| Lannutti et al., CUSPICE ([ngspice page](https://ngspice.sourceforge.io/cuspice.html)) | BSIM4 eval and load per thread, KLU on the CPU | ">3x" transient | verified (page) |
| Ballenegger, "Vectorizing Device Model Evaluation in Ngspice", ngspice-devel 2020 ([thread](https://sourceforge.net/p/ngspice/mailman/ngspice-devel/thread/012B9A8F-7340-4C7B-A2E7-E231C4271EEB@fastwebnet.it/)) | CPU AVX2, 4 BSIM3 instances per vector | 1.85x on one core | verified |
| ChipFlow VAJAX ([repo](https://github.com/ChipFlow/vajax)) | `vmap` over device instances | 2.9x vs VACASK on c6288; 6.6x slower on a 4-node RC | verified (README) |

**Whole simulations batched.**

| Work | Scheme | Result | Divergence | Status |
|---|---|---|---|---|
| Xyce Users' Guide 7.8, SAND2023-13274, `.EMBEDDEDSAMPLING` ([pdf](https://xyce.sandia.gov/files/xyce/Xyce_Users_Guide_7.8.pdf)) | one block system over samples, `.DC`/`.TRAN` only, no `.MEASURE` | no speedup published; "less mature" | one shared step and Newton loop (inferred) | verified |
| Phipps, D'Elia, Edwards, Hoemmen, Hu, Rajamanickam, "Embedded ensemble propagation…", SIAM J. Sci. Comput. 39(2), 2017, DOI 10.1137/15M1044679 | `Ensemble<T,s>` through assembly and solve, lanes interleaved | CPU win mostly a 33% bandwidth cut from the shared graph; s = 32 recommended | coupled norms make results "no longer algorithmically equivalent to uncoupled solves"; group similar samples | verified |
| Han, Zhao, Feng, "TinySPICE", DAC 2013, DOI 10.1145/2463209.2488843 | whole small-circuit runs per GPU thread block | up to 138x for SRAM yield vs CPU | not stated | abstract |
| Han, Feng, "TinySPICE Plus", ICCAD 2016, DOI 10.1145/2966986.2967081 | shared-memory sparse LU per circuit | "orders of magnitude" | clusters similar circuits per SM | unverified |
| Utkarsh et al., "Automated translation and accelerated solving of differential equations on multiple GPU platforms", CMAME 419 (2024) 116591, arXiv:2304.06835 | `EnsembleGPUArray` (shared dt, array kernels) vs `EnsembleGPUKernel` (thread per trajectory, own dt) | Array 48-378x slower than Kernel; GPU beats CPU above 100-1000 trajectories | gap is mostly launch and memory traffic; lockstep not isolated | verified |
| Balos et al., "SUNDIALS time integrators for exascale applications with many independent systems of ODEs", IJHPCA 2025, arXiv:2405.01713 | cells in lockstep, batched block solves | MAGMA batched direct 1.5-10x over cuSPARSE batched | dt "constrained by the stiffest cell in the batch" | verified |

**Batched sparse LU on one pattern.**

| Work | Semantics | Failure handling | Status |
|---|---|---|---|
| cuSOLVER cuSolverRF batch ([docs](https://docs.nvidia.com/cuda/cusolver/index.html)) | same P, Q and L/U pattern per matrix | `cusolverRfBatchZeroPivot` per matrix; deprecated for cuDSS | verified |
| cuDSS uniform batch ([docs](https://docs.nvidia.com/cuda/cudss/)) | `CUDSS_CONFIG_UBATCH_SIZE`, values matrix-major | `UBATCH_INDEX` refactors one chosen matrix | verified |
| Boukaram, Hong, Liu, Shi, Li, "Batched sparse direct solver design and evaluation in SuperLU_DIST", IJHPCA 2024, DOI 10.1177/10943420241268200 | batched LU, fixed pivot order, level by level over the elimination tree | pivoting off for their applications | verified |
| Aggarwal et al. (Ginkgo), "Batched Sparse Iterative Solvers…", ScalA21, LLNL-PROC-826165 | batched Krylov, one pattern copy | per-system stopping; SIMD-until-last "obviously inefficient" | verified |
| Davis, Palamadai Natarajan, "Algorithm 907: KLU", ACM TOMS 37(3), 2010 | `klu_refactor`: same pattern, same pivot order | check `klu_rgrowth`/`klu_rcond` | verified (user guide) |
| Peng, Tan, "GLU3.0", arXiv:1908.00204; Chen, Wang, Yang, "NICSLU", IEEE TCAD 32(2), 2013 | one matrix, pivots fixed on the CPU, refactor reuses them | see `gpu-sparse-lu.md` | verified |

**Commercial (vendor claims).**
- Cadence Spectre X GPU: "up to 6X" on Hopper for one post-layout run
  (Cadence/MediaTek press release, 2025-01-22).
- Synopsys PrimeSim SPICE GPU: about 3x on a transient with GPUs vs without
  (Synopsys blog, 2026-06-10).
- Empyrean ALPS-GT: 5-13x with the GPU doing matrix solves (EDN,
  2020-05-26).

None claims sweep points as lanes of one simulation.

**Nothing found:** CPU SIMD across independent circuit instances for SPICE
(the closest is Ballenegger, across devices of one circuit), a Sandia
"batched KLU", and the "Poore et al." paper the brief named.

**Lessons taken:**
- Batch whole simulations, not just evaluation (Gulati's Amdahl wall).
- Decide convergence and step per lane, never through an ensemble norm
  (Phipps).
- Freeze converged lanes (Ginkgo; here it is also needed for correctness).
- Share one pivot order with a per-lane check and a peel (KLU, cuSolverRF,
  cuDSS).
- Interleave lanes innermost (Phipps).
- Below a few hundred points the GPU loses (DiffEqGPU, VAJAX).
- The niche is open: Xyce's embedded sampling, the only shipped
  block-sample transient, has no `.MEASURE`.

---

**Sources.** ESPice at 76627329 and the `ESPice-perf` working tree:
- solver: `src/solver/{lane_lu,lu_kernels,freq_solve,converger,direct}.zig`;
- analysis: `src/analysis/{Circuit,session,executor}.zig`,
  `tran/tran.zig`, `dc/op.zig`, `dc/dc.zig`, `sweep/*.zig`, and the
  per-analysis files cited in §6;
- device and frontend: `src/device/eval.zig`, `src/frontend/variants.zig`,
  `analyses.zig`;
- output and API: `src/output/measure.zig` (perf: `Wave.crossings`),
  `include/espice.h`, `src/c_api.zig`, `tests/codegen.zig`;
- docs: `dev/devices/gpu-evaluation.md`,
  `dev/solvers/{gpu-sparse-lu,gpu-lu,solver-perf-2026-09}.md`,
  `dev/analysis/{ensemble-sweeps,variants,optimize}.md`.

Outside ESPice:
- Gompute: `skill/gompute/{SKILL,REFERENCE,OVERHEAD}.md`.
- VerA v0.10.4: `tools/contract.zig`, `docs/host/batching.md`,
  `lib/device/codegen/file.zig`; the generated `bsimcmg.zig` (VerA 0.10.3);
  `docs/measurements/batched-lead-2026-10-02.md`, read from git history
  (`4a870ae8^`).
- The old AGENTS.md §2.10 lane-axis rule (`05852567^`).
- Issue #97's merged commits (51692b21, 8a5be218, c68d2ee0).
- asap7 `7nm_TT_160803.pm` from lambdapdk v0.2.12.

**Verification.**
- Measured here with the prototypes: §1's tables, §4's table, §7's lockstep
  factors and early-stop times, and §3.3's `@sizeOf`.
- Estimates, not measurements: §9's GPU throughput (from the documented
  cost model) and §3.4's compile time.
- Read from the code: §2's DAG facts and §6's decision inventory.
- The design in §§2-11 is ours; no source prescribes it.

**Prototypes** (`lane-batched-simulation/`):
- `gen_chain.py`: the deck.
- `lockstep.py`: 16 scalar runs, their grids and per-step Newton counts.
- `bench.zig`, `batch_family.zig` and `build.sh`: bsimcmg scalar vs batched
  `evalQ` (ReleaseFast, `-mcpu=native`; each width takes 95-139 s and 2.5 GB
  to build).
