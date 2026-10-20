# Phase 4 plan: the GPU lane backend (#208)

Implementation-ready plan for running transient sweep points as N
device-resident lanes on CUDA/HIP, with the CPU lane path of phase 3 as the
oracle. Written against main 06cff37f plus the phase 3 plan. Nothing was built,
run or measured for this plan. Spots that only a build or a GPU run can settle
are marked **CHECK**, and Gompute calls I could not confirm in its docs are
marked **API?**.

Inputs:
- `dev/research/lane-batched-simulation.md`: §3.2 (layout), §4 (GPU eval),
  §5, §5.1 (residency, launch cost), §5.2 (lane LU kernel), §7, §11 (phase 4
  gate);
- `dev/research/gpu-lane-e1.md`: E1 passed, 0.066-0.081 of host serial;
- issue #208 and the owner decisions in its comments.

## 0. Decisions this plan takes

1. **Scope v1 is the transient Newton plus the per-round step numerics on the
   device. Per-lane step control stays on the host, and so do OP lanes.**
   - MATCHA's cost is the `.tran`: 3477 ticks against 364 OP iterations (§1).
   - The OP runs scalar in parallel workers, or as phase 2 CPU lanes, and each
     lane's `.tran` starts from its own snapshot, as today.
   - GPU OP lanes are a follow-up. They need the masked ladder of phase 2 on
     the device.
2. **No staging, no clear-and-reduce for the lane eval.**
   - One thread runs one lane. It walks every instance of one batch in tape
     order and adds straight into the lane's own lane-major planes.
   - No two threads ever write one cell, and each cell sums its contributions
     in the host stamp's order (batch by batch, instance by instance). That
     makes the sum deterministic without atomics, and without the 20-27% of
     kernel time E1 measured for clear and reduce.
   - It also removes the 4.3 KB/instance of staging that capped an 8 GB card
     near 16k lanes.
   - Warps stay lane-innermost, as E1 requires: a warp is 32 lanes of the same
     instance at the same time.
   - The cost is wave quantization. Parallelism is N, not N x instances, so N
     must be at least ~2x the card's resident threads (§5 risk 1). The kernel
     is written so that a later thread-per-(instance-color, lane) mapping with
     hub staging (§5 risk 1) reuses the same `LaneSink`.
3. **The layout is lane-major (`i * N + l`) for everything Newton touches per
   tick:**
   - x, x_old, dx, planes, A, L/U values, the row charge ring, i_prev;
   - the instance, state and lim rows;
   - the per-(instance, lane) `model_of`.

   Lane-minor (`l * len + j`) holds only the LTE charge-tape ring, which is read
   once per round by one thread per lane.
4. **Model rows are deduplicated by bytes over all (instance, lane) pairs.**
   `model_of` becomes lane-major, so lanes with equal sizes broadcast one row
   across the warp ("packed rows", §3.2).
5. **Host control is single-sourced.** Phase 3's `Sim.begin`/`Sim.end` become
   generic over a numerics backend, `Ops` (step G1).
   - The CPU backend is today's statements moved verbatim. The corpus must stay
     byte-identical.
   - The GPU backend answers the same calls from numbers the device computed
     for the whole round (*probe*), and queues the device mutations (*apply*).
     So there is one copy of the step-control logic, and the CPU path stays its
     oracle.
6. **`auto` keeps the CPU on consumer cards.**
   - `Config.gpu_lanes` is decided once per Problem: true for an explicit
     `cuda`/`hip`; under `auto`, true only when `fp64Ratio() <= 4` (FP64-class
     parts report 2). `ESPICE_LANES=0` forces it off.
   - E1: the 4060 is only 1.4-2x the 24-core CPU, and it reports 64.
7. **Threads take FP64 as the bound.** The first throughput lever is bsimcmg's
   frame and spills (step G2): an experiment matrix with a decision rule, run
   before the lane kernels are tuned.

## 1. Architecture

```
Session (gpu_lanes)        breadth-first: OPs first, then ready .tran rows gathered N wide
  Executor.executeGpuBatch materialize N lane Circuits (instantiate+installVariant / fromSnapshot)
    tran.runGpuLanes       one Run + Sim per lane (host control), one GpuLanes (device state)
      per round:
        host  Sim.begin(GpuOps)       -> per-lane LaneScalars, SimState (upload)
        dev   predict, limit(trial,cur)
        dev   Newton ticks: graph A [clear, eval(batches), assemble, refactor, solve]
              host: peel LU-failed lanes on the host (rare)
              graph B [update+norm, limit, gate, state, finalize]  -> active count (4 B down)
        dev   probe: ctl query, eval(charge) at x, q-tape, LTE del/del2, probe gather
        host  download per-lane probe numbers; Sim.end(GpuOps) per lane = decide + queue ops
        dev   apply: ctl revert/commit, accept (prev<-cur<-x, i_prev, ring perms), rebase
        host  record/feed from downloaded probe rows; early stop; finished lanes leave
```

Per-round traffic (§5.1): about 8 f64 up and 8 f64 plus `n_probes` f64 down per
lane, plus the 4-byte active count per tick. At N = 8192 that is ~1 MB per
round against ~90 ms of compute per round on the 4060.

## 2. Code changes, in dependency order

### G0. Build policy: empty `gpu_host_only` (build.zig:651)

E1 §5 measured every model under CUDA's 262,136 B limit. The largest gfx1100
frame was 113 KB, so every model also compiles there.

```zig
/// GPU kernel stack frames past the 262,136 B limit (CUDA's and amdgcn's).
/// Empty since VerA v0.11.0's sparse layout: the largest is mvsg at 47 KB on
/// sm_89 and asmhemt at 113 KB on gfx1100 (dev/research/gpu-lane-e1.md §5).
const gpu_host_only = std.StaticStringMap(void).initComptime(.{});
```

Gate: `zig build test-gpu` on a CUDA box. The decks with psp103/104_nqs,
asmhemt, bsimsoi_va and mvsg must pass, and VERDICTS.tsv must not move.
**CHECK** the ptxas wall time: asmhemt and bsimsoi_va take 177-181 s and 11 GB
each, and they go onto the serial heavy lanes (`heavy_lanes = 2`). If CI memory
cannot hold them, keep those two listed and file the per-backend exclusion
Gompute lacks.

### G1. `Sim` over a numerics backend (CPU, bitwise gate) — critical path

Edit phase 3's `Sim` in `src/analysis/tran/tran.zig`. Every statement that
touches O(n) data or device state moves into a `HostOps` method with the same
body. `begin`/`end` call `ops.<method>(s, ...)` at the same point.
`HostOps` is zero-size and its methods are `inline`, so the scalar code is
unchanged.

The `Ops` surface (each line names the `Sim` statements it absorbs):

```zig
/// What `Sim.begin` and `Sim.end` ask of the numerics, so one copy of the
/// step control drives the host (`HostOps`, the oracle) and the device
/// (`gpu_lanes.Ops`). Each method runs exactly the statements it names, at
/// the point it is called. A backend may answer from numbers it computed
/// earlier for the whole round, as long as they equal what the statements
/// would compute now.
const HostOps = struct {
    /// begin: gear history, the hook, predict, predictFirstIterate,
    /// evalFollowsFirst, applyLimits, reject_at = null.
    inline fn attempt(_: HostOps, s: *Sim, a: *Attempt) void {
        const ckt = s.ckt;
        const q_hist = s.qHist();
        if (a.gear_hi) integrator.gearHistory(s.g_row, q_hist[0 .. s.order + 1], a.ag);
        a.hook = .{
            .method = a.method,
            .c = a.c,
            .q_prev = q_hist[1],
            .i_prev = s.i_prev,
            .q_prev2 = if (a.gear_hi) s.g_row else q_hist[2],
            .q_cur = {},
            .a_vals = s.a_vals,
            .has_charge = s.has_charge,
        };
        const xfact = s.dt / s.dt_old[0];
        predict(s.trial, s.cur, s.prev, xfact);
        ckt.predictFirstIterate(s.trial, s.cur, s.prev, s.dt / s.dt_old[1]);
        ckt.evalFollowsFirst(s.trial, a.t_dev);
        _ = ckt.applyLimits(s.trial, s.cur);
        ckt.reject_at = null;
    }
    inline fn revert(_: HostOps, s: *Sim) void {
        _ = s.ckt.stateCtl(.revert);
    }
    inline fn rejectAt(_: HostOps, s: *Sim) ?f64 {
        return s.ckt.reject_at;
    }
    /// The `evalFollows` hint, then (only when `ask`) the flip query.
    inline fn flipped(_: HostOps, s: *Sim, a: *const Attempt, ask: bool) bool {
        if (s.has_charge and !s.ckt.q_fresh) s.ckt.evalFollows(s.trial, a.t_dev, true);
        return ask and s.ckt.stateCtl(.query);
    }
    inline fn boundStep(_: HostOps, s: *Sim) ?f64 {
        return s.ckt.boundStep();
    }
    /// The charge re-read at the solution into ring slot 0, rows and tape.
    inline fn charges(_: HostOps, s: *Sim, a: *const Attempt) void {
        const ckt = s.ckt;
        const qt_hist = s.qtHist();
        if (!ckt.q_fresh) ckt.evalQ(s.trial, a.t_dev);
        num.copySimd(s.qHist()[0], ckt.q_vec[0..s.n]);
        if (s.n_qt > 0) lteSnap(ckt, qt_hist[0], s.lte_zero, s.lte_rows);
        if (a.gear_hi and s.n_qt > 0) integrator.gearHistory(s.qt_g, qt_hist[0 .. s.order + 1], a.ag);
    }
    /// `stepBound` (order <= 2) of `method` after a step at `a.method`.
    inline fn bound(_: HostOps, s: *Sim, a: *const Attempt, method: Method, lte: integrator.LteIn) f64 {
        const h = s.lteHist();
        return integrator.stepBound(W, method, a.method, .{ h[0], h[1], h[2], h[3] }, s.lteIp(), a.c, lte);
    }
    inline fn boundGear(_: HostOps, s: *Sim, a: *const Attempt, method: Method, lte: integrator.LteIn) f64 {
        return integrator.stepBoundGear(method, a.method, s.lteHist(), s.lteIp(), s.lteG(), a.c, lte, &a.dts);
    }
    /// advanceCurrent on both index spaces, then the ring rotation.
    inline fn advance(_: HostOps, s: *Sim, a: *const Attempt) void {
        const q_hist = s.qHist();
        const qt_hist = s.qtHist();
        integrator.advanceCurrent(a.method, s.i_prev, q_hist[0], q_hist[1], if (a.gear_hi) s.g_row else q_hist[2], a.c);
        if (s.n_qt > 0)
            integrator.advanceCurrent(a.method, s.qt_i_prev, qt_hist[0], qt_hist[1], if (a.gear_hi) s.qt_g else qt_hist[2], a.c);
        std.mem.rotate([]f64, q_hist, s.n_hist - 1);
        if (s.n_qt > 0) std.mem.rotate([]f64, qt_hist, s.n_hist - 1);
    }
    /// commitStates and the commit, at the rotated `cur`.
    inline fn commit(_: HostOps, s: *Sim) void {
        _ = s.ckt.commitStates(s.cur);
        _ = s.ckt.stateCtl(.commit);
    }
    /// The stateful-charge re-read at `cur` (`has_state_q`).
    inline fn rebase(_: HostOps, s: *Sim, a: *const Attempt) void {
        const ckt = s.ckt;
        const q_hist = s.qHist();
        const qt_hist = s.qtHist();
        if (!(s.has_charge and ckt.has_state_q)) return;
        ckt.evalQ(s.cur, s.t);
        integrator.rebaseCurrent(s.i_prev, ckt.q_vec[0..s.n], q_hist[1], a.c.ag0);
        num.copySimd(q_hist[1], ckt.q_vec[0..s.n]);
        if (s.n_qt > 0) {
            lteSnap(ckt, qt_hist[0], s.lte_zero, s.lte_rows);
            integrator.rebaseCurrent(s.qt_i_prev, qt_hist[0], qt_hist[1], a.c.ag0);
            std.mem.swap([]f64, &qt_hist[0], &qt_hist[1]);
        }
    }
    /// The accepted solution `record` and `feed` read (probe rows only).
    inline fn accepted(_: HostOps, s: *Sim) []const f64 {
        return s.cur;
    }
};
```

Then edit `Sim`:
- `begin(s)` becomes `begin(s, ops: anytype)`. In place of the gear block, the
  hook literal, the predictor lines and `ckt.reject_at = null`, it calls
  `ops.attempt(s, &a);`. Everything else stays: checkpoint, `setSimState`, VPI
  point, `methodAt`, `gearAg`, coefficients, `nr_opts`.
- `end(s, a, nr)` becomes `end(s, a, nr, ops: anytype)`. Substitute in order:
  - `_ = ckt.stateCtl(.revert);` becomes `ops.revert(s);` (all six sites: Newton, reject_at,
    flip, LTE, and both VPI branches);
  - `if (ckt.reject_at) |tr|` becomes `if (ops.rejectAt(s)) |tr|`;
  - the evalFollows line and `dt > s.state_eps and ckt.stateCtl(.query)` become
    `if (ops.flipped(s, a, dt > s.state_eps))`. The hint runs first and the
    query only when `dt > state_eps`, exactly today's order and short-circuit;
  - `ckt.boundStep()` becomes `ops.boundStep(s)` (three sites);
  - the `if (has_charge) { evalQ ... gearHistory }` block becomes
    `if (has_charge) ops.charges(s, a);`;
  - the `lq` local goes, and `stepBound(W, m, eff_method, lq, ...)` becomes
    `ops.bound(s, a, m, lte)`;
  - `stepBoundGear(m, eff_method, ...)` becomes `ops.boundGear(s, a, m, lte)`;
  - the two `advanceCurrent` calls and both rotates become `ops.advance(s, a);`;
  - `commitStates` and `.commit` become `ops.commit(s);`;
  - the `has_state_q` block becomes `ops.rebase(s, a);`;
  - `s.waveform.record(t_new, s.cur, ...)` and `sm.feed(t_new, s.cur, ...)`
    pass `ops.accepted(s)`.
- `drive` passes `HostOps{}`, and so does phase 3's `runLanes`.

`lq` was a snapshot of the ring heads taken before rotation. `ops.bound` now
reads the ring at call time, and every call to it still happens before
`ops.advance` rotates, so the values read are the same.

**Gate G1:** corpus byte-identical against phase 3's binary
(`tools/lane_diff.py` with lanes off, old against new); `test-analysis`; and the
chain timing within noise. **Codegen:** `HostOps` methods are `inline` on a
zero-size value, so no probe is added (phase 3 §3 argument).

### G2. bsimcmg frame and spill reduction (first throughput lever)

The owner named this first. It is independent of G3-G8, so it can run in
parallel on a GPU box. It is a measured experiment with a decision rule, not a
code edit decided in advance.

| # | Knob | Where | Expected |
|---|---|---|---|
| a | `maxrregcount` 128 / 168 (16 / 12 warps per SM) | gompute `emitKernels` ptxas flags. **API?** If it has no per-root flag, add `.ptxas_flags: []const []const u8` to `KernelRoot` (one field, passed through) | occupancy 17% to 25-33%, more spills; E1's spill traffic is DRAM-bound, so it is a gamble |
| b | narrow basis on the device | `LaneEvalKernel` takes `narrow_count` and runs `evalRange(D, true, ...)` on `[0, narrow_count)` and the wide basis on the rest, as **two kernels** (`arp_leval_n_<m>`, `arp_leval_<m>`) so each gets its own register allocation | fewer derivative lanes, so fewer live values. Only for maximally collapsed instances (`ProtoStore.finalize` sorts them first); asap7 bsimcmg has no RD/RS. **CHECK** `narrow_count` on the chain deck |
| c | `__launch_bounds__(64, 2)` equivalent | **API?** gompute export attribute | register cap per block width |
| d | VerA: fewer live derivative lanes per expression | VerA issue (codegen) | the real fix for 20.8 KB; out of ESPice's tree |

Procedure: E1's harness (`gpu-lane-e1/run.sh`, lane mixed, N = 4096) plus
`ptxas -v` per variant.

Decision rule: keep a variant when kernel µs per instance-eval drops ≥ 5% at
N = 4096 **and** the CPU-lane parity test (G9) stays within tolerance. Record
the results in `dev/research/gpu-lane-e1.md` §7.

### G3. Lane device kernels per model: `src/device/eval.zig`

Add after `CtlKernel` (line ~2895), before `VpiHost`:

```zig
/// Memory access for `evalRange` over lane `l` of `n` lanes, lane-major:
/// unknown gi at `xs[gi * n + l]`, plane cell c at `plane[c * n + l]`,
/// instance id's row at `instances[id * n + l]` and its Model at
/// `models[model_of[id * n + l]]`; the gather, scatter and slot tapes are
/// the batch's own, shared by every lane. One thread walks every instance
/// of its lane, so it alone writes its lane's cells: adds land in tape
/// order with no staging and no atomics (dev/research/plans/phase4).
fn LaneSink(comptime D: type) type {
    const n_u: usize = comptime contract.nU(D);
    return struct {
        n: u32,
        l: u32,
        xs: gompute.GlobalPtr(f64),
        gath_: gompute.GlobalPtr(u32),
        rhs_idx_: gompute.GlobalPtr(u32),
        slots_: gompute.GlobalPtr(u32),
        models_: gompute.GlobalPtr(D.Model),
        model_of_: gompute.GlobalPtr(u32),
        instances_: gompute.GlobalPtr(D.Instance),
        g_vals: gompute.GlobalPtr(f64),
        c_vals: gompute.GlobalPtr(f64),
        rhs: gompute.GlobalPtr(f64),
        q_vec: gompute.GlobalPtr(f64),
        /// Lane-major lim plane: instance id's limited unknown `at(u)` at
        /// `(id * k + at(u)) * n + l`.
        lim_: gompute.GlobalPtr(f64),

        pub const skip_g = false;
        pub const skip_c = false;
        pub const on_device = true;
        const Sk = @This();

        inline fn at(s: *const Sk, i: usize) usize {
            return i * s.n + s.l;
        }
        pub inline fn x(s: *const Sk, gi: u32) f64 {
            return s.xs[s.at(gi)];
        }
        pub inline fn gath(s: *const Sk, id: u32, u: usize) u32 {
            return s.gath_[@as(usize, id) * n_u + u];
        }
        pub inline fn rhsRow(s: *const Sk, id: u32, ru: usize) u32 {
            return s.rhs_idx_[@as(usize, id) * n_u + ru];
        }
        pub inline fn lim(s: *const Sk, id: u32, comptime u: usize) f64 {
            return s.lim_[s.at(@as(usize, id) * LimMap(D).k + comptime LimMap(D).at(u))];
        }
        pub inline fn model(s: *const Sk, id: u32) *const D.Model {
            return @addrSpaceCast(&s.models_[s.model_of_[s.at(id)]]);
        }
        pub inline fn inst(s: *const Sk, id: u32) if (@hasDecl(D, "mutable_eval") and D.mutable_eval) *D.Instance else *const D.Instance {
            return @addrSpaceCast(&s.instances_[s.at(id)]);
        }
        inline fn slot(s: *const Sk, id: u32, comptime ru: usize, comptime cu: usize) u32 {
            return s.slots_[@as(usize, id) * SlotMap(D).k + comptime SlotMap(D).at(ru, cu)];
        }
        pub inline fn scatterRes(s: *const Sk, row: u32, val: f64) void {
            s.rhs[s.at(row)] += val;
        }
        pub inline fn scatterJac(s: *const Sk, id: u32, comptime ru: usize, comptime cu: usize, val: f64) void {
            s.g_vals[s.at(s.slot(id, ru, cu))] += val;
        }
        pub inline fn scatterQ(s: *const Sk, row: u32, qv: f64) void {
            s.q_vec[s.at(row)] += qv;
        }
        pub inline fn scatterQJac(s: *const Sk, id: u32, comptime ru: usize, comptime cu: usize, val: f64) void {
            s.c_vals[s.at(s.slot(id, ru, cu))] += val;
        }
    };
}

/// GPU lane eval for D: thread l is lane l of `n_lanes`, evaluating every
/// instance of the batch at its own x under its own `sims[l]`, skipped
/// when `active[l] == 0` (a frozen or finished lane). `limiting[0]` is the
/// batch's lim-active word. Planes must be zeroed first; each plane cell
/// then sums its contributions in the host stamp's order.
fn LaneEvalKernel(comptime D: type, comptime block_size: u32) type {
    return struct {
        pub fn run(
            n_lanes: u64,
            count: u64,
            sims: gompute.GlobalPtr(SimState),
            active: gompute.GlobalPtr(u8),
            limiting: gompute.GlobalPtr(u32),
            xs: gompute.GlobalPtr(f64),
            gath: gompute.GlobalPtr(u32),
            rhs_idx: gompute.GlobalPtr(u32),
            slots: gompute.GlobalPtr(u32),
            models: gompute.GlobalPtr(D.Model),
            model_of: gompute.GlobalPtr(u32),
            instances: gompute.GlobalPtr(D.Instance),
            g_vals: gompute.GlobalPtr(f64),
            c_vals: gompute.GlobalPtr(f64),
            rhs: gompute.GlobalPtr(f64),
            q_vec: gompute.GlobalPtr(f64),
            lim: gompute.GlobalPtr(f64),
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= n_lanes) return;
            const l: u32 = @intCast(tid);
            if (active[l] == 0) return;
            var sink: LaneSink(D) = .{
                .n = @intCast(n_lanes),
                .l = l,
                .xs = xs,
                .gath_ = gath,
                .rhs_idx_ = rhs_idx,
                .slots_ = slots,
                .models_ = models,
                .model_of_ = model_of,
                .instances_ = instances,
                .g_vals = g_vals,
                .c_vals = c_vals,
                .rhs = rhs,
                .q_vec = q_vec,
                .lim_ = lim,
            };
            evalRange(D, false, gpuJacFloat(D), false, &sink, 0, @intCast(count), sims[l], limiting[0] != 0);
        }
    };
}

/// GPU lane limit/state kernel: `StateKernel` per (instance, lane), lanes
/// innermost (thread t is lane t % n_lanes of instance t / n_lanes), for
/// the lanes with `mask[l] != 0`. ORs bit 0 (not converged) and bit 1 (a
/// reject request, which the lane path treats as a fault) into `flags[l]`.
fn LaneStateKernel(comptime D: type, comptime block_size: u32) type {
    const n_u: usize = comptime contract.nU(D);
    const has_limit = @hasDecl(D, "limit");
    const has_state = @hasDecl(D, "State");
    const StateT = if (has_state) D.State else u8;
    return struct {
        pub fn run(
            n_lanes: u64,
            count: u64,
            mask: gompute.GlobalPtr(u8),
            xs: gompute.GlobalPtr(f64),
            x_old: gompute.GlobalPtr(f64),
            gath: gompute.GlobalPtr(u32),
            models: gompute.GlobalPtr(D.Model),
            model_of: gompute.GlobalPtr(u32),
            instances: gompute.GlobalPtr(D.Instance),
            lim: gompute.GlobalPtr(f64),
            states: gompute.GlobalPtr(StateT),
            lim_active: gompute.GlobalPtr(u32),
            halves: u64,
            flags: gompute.GlobalPtr(u32),
            sims: gompute.GlobalPtr(SimState),
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= n_lanes * count) return;
            const n: usize = @intCast(n_lanes);
            const l: usize = @intCast(tid % n_lanes);
            const id: usize = @intCast(tid / n_lanes);
            if (mask[l] == 0) return;
            const sim = sims[l];
            const model: *const D.Model = @addrSpaceCast(&models[model_of[id * n + l]]);
            var flag: u32 = 0;
            var cur: [n_u]f64 = undefined;
            inline for (0..n_u) |u| cur[u] = xs[@as(usize, gath[id * n_u + u]) * n + l];
            if (comptime has_limit) if (halves & ir.lim_pass_limit != 0) {
                const writes = comptime limitWritesOf(D);
                const k = comptime LimMap(D).k;
                const inst_c: *const D.Instance = @addrSpaceCast(&instances[id * n + l]);
                var old: [n_u]f64 = undefined;
                inline for (0..n_u) |u| {
                    const xo = x_old[@as(usize, gath[id * n_u + u]) * n + l];
                    old[u] = if (comptime has(writes, u))
                        (if (lim_active[0] != 0) lim[(id * k + comptime LimMap(D).at(u)) * n + l] else xo)
                    else
                        xo;
                }
                var lm = D.limit(Real, model, inst_c, cur, old, sim);
                snapLimited(n_u, comptime limitReadsOf(D), writes, &lm.x, cur);
                if (!lm.converged) flag |= 1;
                inline for (0..n_u) |u| if (comptime has(writes, u)) {
                    lim[(id * k + comptime LimMap(D).at(u)) * n + l] = lm.x[u];
                };
            };
            if (comptime has_state) if (halves & ir.lim_pass_state != 0) {
                const inst_m: *D.Instance = @addrSpaceCast(&instances[id * n + l]);
                const st: *StateT = @addrSpaceCast(&states[id * n + l]);
                switch (D.updateState(Real, model, inst_m, cur, st, sim)) {
                    .ok => {},
                    .request_reject_at => flag |= 2,
                }
            };
            if (flag != 0) _ = @atomicRmw(u32, &flags[l], .Or, flag, .monotonic);
        }
    };
}

/// GPU lane accepted-step kernel: `CtlKernel` per (instance, lane), lanes
/// innermost, running `D.stateCtl` with lane l's own op (`ops[l]`, a
/// `StateCtlOp` + 1; 0 skips the lane). ORs a query hit into `flags[l]`.
fn LaneCtlKernel(comptime D: type, comptime block_size: u32) type {
    const StateT = if (@hasDecl(D, "State")) D.State else u8;
    return struct {
        pub fn run(
            n_lanes: u64,
            count: u64,
            ops: gompute.GlobalPtr(u8),
            models: gompute.GlobalPtr(D.Model),
            model_of: gompute.GlobalPtr(u32),
            instances: gompute.GlobalPtr(D.Instance),
            states: gompute.GlobalPtr(StateT),
            flags: gompute.GlobalPtr(u32),
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= n_lanes * count) return;
            const n: usize = @intCast(n_lanes);
            const l: usize = @intCast(tid % n_lanes);
            const id: usize = @intCast(tid / n_lanes);
            const op = ops[l];
            if (op == 0) return;
            const model: *const D.Model = @addrSpaceCast(&models[model_of[id * n + l]]);
            const inst: *D.Instance = @addrSpaceCast(&instances[id * n + l]);
            const st: *StateT = @addrSpaceCast(&states[id * n + l]);
            const sop: StateCtlOp = @fromBackingInt(@intCast(op - 1));
            if (D.stateCtl(model, inst, st, sop))
                _ = @atomicRmw(u32, &flags[l], .Or, 1, .monotonic);
        }
    };
}

/// GPU lane charge-tape kernel: `QTapeKernel` per (instance, lane), lanes
/// innermost, at lane l's x, writing its LTE sites into ring slot
/// `slot0[l]` of lane l's lane-minor tape ring: site j of instance id at
/// `((l * n_hist + slot0[l]) * n_qt) + off + id * sites + j`.
fn LaneQTapeKernel(comptime D: type, comptime block_size: u32) type {
    const n_u: usize = comptime contract.nU(D);
    const sites = comptime lteSites(D);
    return struct {
        pub fn run(
            n_lanes: u64,
            count: u64,
            mask: gompute.GlobalPtr(u8),
            sims: gompute.GlobalPtr(SimState),
            xs: gompute.GlobalPtr(f64),
            gath: gompute.GlobalPtr(u32),
            models: gompute.GlobalPtr(D.Model),
            model_of: gompute.GlobalPtr(u32),
            instances: gompute.GlobalPtr(D.Instance),
            tape: gompute.GlobalPtr(f64),
            slot0: gompute.GlobalPtr(u8),
            n_hist: u64,
            n_qt: u64,
            off: u64,
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= n_lanes * count) return;
            const n: usize = @intCast(n_lanes);
            const l: usize = @intCast(tid % n_lanes);
            const id: usize = @intCast(tid / n_lanes);
            if (mask[l] == 0) return;
            const S = RealFor(@hasDecl(D, "collapse"));
            var lx: [n_u]f64 = undefined;
            inline for (0..n_u) |u| lx[u] = xs[@as(usize, gath[id * n_u + u]) * n + l];
            const inst: *const D.Instance = @addrSpaceCast(&instances[id * n + l]);
            const qs = D.q(S, &lx, @addrSpaceCast(&models[model_of[id * n + l]]), inst, sims[l]);
            const mf = mfactorOf(D, inst);
            const base = (l * @as(usize, @intCast(n_hist)) + slot0[l]) * @as(usize, @intCast(n_qt)) + @as(usize, @intCast(off)) + id * sites.len;
            inline for (sites, 0..) |k, j| tape[base + j] = qs[k].v * mf;
        }
    };
}
```

Kernel names, next to `qTapeKernelName` (line ~2540):

```zig
/// Lane kernel symbols, named from `kernelName` by the host
/// (`gpu_lanes.laneName`), not carried in the frozen `GpuPayload`.
fn laneKernelName(comptime D: type, comptime what: []const u8) [:0]const u8 {
    return "arp_l" ++ what ++ "_" ++ comptime baseName(D);
}
```

Exports, in the build-root `comptime` block (line ~3055), inside
`if (gpuEligible(D)) { ... }`:

```zig
                    if (lane_kernels) {
                        gompute.exportRaw(laneKernelName(D, "eval"), &LaneEvalKernel(D, block_size).run);
                        if (hasStateKernel(D)) gompute.exportRaw(laneKernelName(D, "lim"), &LaneStateKernel(D, block_size).run);
                        if (hasCtlKernel(D)) gompute.exportRaw(laneKernelName(D, "ctl"), &LaneCtlKernel(D, block_size).run);
                        if (@hasDecl(D, "q")) gompute.exportRaw(laneKernelName(D, "qtp"), &LaneQTapeKernel(D, block_size).run);
                    }
```

`lane_kernels` is a build option, so CI can trade ptxas time. The lane eval
doubles each model's device code; bsimcmg goes from 85 to ~170 s of ptxas.

```zig
/// `-Dgpu-lanes`: also export the lane kernels (phase 4). Read through the
/// kernel roots' `abi` import. CHECK: thread it as `ir.gpu_lane_kernels`,
/// set in the device-side abi module's options, beside `gpu_block_size`.
const lane_kernels = ir.gpu_lane_kernels;
```

`src/device/abi.zig`: bump `abi_version` to 31 with this history line:

```zig
// 31: lane kernels `arp_l{eval,lim,ctl,qtp}_<model>` beside each image's
//     `arp_eval_<model>` (phase 4), the host deriving their names; a host of
//     30 loads no lane kernel and a lane host refuses an image without them.
pub const abi_version: u32 = 31;
```

Every `DeviceKernel`, `StateKernel`, `CtlKernel` and `QTapeKernel` is
unchanged: the single-circuit GPU path keeps them and its staging.

### G4. Model-independent lane kernels: `src/solver/lane_kernels.zig` (new, std only)

The bodies are per lane and generic over the pointer type `P` (`[*]T` on the
host, `gompute.GlobalPtr` on the device), as `lu_kernels.zig` is. Host tests
run them as loops over lanes against their CPU oracles, bitwise (§4).

```zig
//! Per-lane bodies of the GPU lane backend (dev/research/plans/phase4),
//! generic over the pointer type so the host runs them as the oracle tests'
//! loops and the device as one thread per lane (`lane_device.zig`):
//! `LaneLu`'s refactor and solve restated over lane-major values, the
//! Newton update, gates and finalize of `converger.newtonLanes`, the
//! transient's companion residual, assembly, predictor, LTE bound and
//! accepted-step update. Lane l of n holds element i at `i * n + l`
//! (lane-major); the LTE tape ring is lane-minor. Each body matches its
//! oracle's operation order, so a host run is bitwise the oracle.
//! std only: the kernel root compiles this file for NVPTX and AMDGCN.

const std = @import("std");

/// Offsets (u32 words) of a frozen `SparseLu` tape inside one index buffer
/// `x`, plus its scalars. Passed by value. Built by `buildTab` from the
/// lead lane's factored `SparseLu`; every lane replays it.
pub const LaneTab = extern struct {
    n: u32,
    nnz: u32,
    nnz_l: u32,
    nnz_u: u32,
    growth: f64,
    /// 1 / `direct.pivot_tol`: `LaneSolver.wideMultipliers`' bound.
    wide: f64,
    col_ptr: u32, // n + 1: A's CSC columns
    prow: u32, // nnz: A entry -> pivot position
    q: u32, // n: pivot step -> column
    pinv: u32, // n: row -> pivot step
    lp: u32, // n + 1
    li: u32, // nnz_l
    up: u32, // n + 1
    ui: u32, // nnz_u
    flags: u32, // n: bit 0 void column, bit 1 scaled pivot
};

pub const void_bit: u32 = 1;
pub const scaled_bit: u32 = 2;

pub fn Bodies(comptime P: fn (type) type) type {
    return struct {
        /// `LaneLu.refactor` for lane l, plus `LaneSolver.wideMultipliers`:
        /// true when lane l must peel (dead or non-finite pivot, growth,
        /// a non-finite L/U entry, a wide multiplier, or a void column).
        /// `a` is A lane-major in pattern order (nnz rows); `w` is n rows of
        /// zeros on entry and on exit.
        pub fn refactor(t: LaneTab, x: P(u32), a: P(f64), lx: P(f64), ux: P(f64), udiag: P(f64), w: P(f64), n_lanes: u32, l: u32) bool {
            const N: usize = n_lanes;
            const L: usize = l;
            var bad = false;
            var nonfinite: u64 = 0;
            const inf = std.math.inf(f64);
            for (0..t.n) |k| {
                const c = x[t.q + k];
                for (x[t.col_ptr + c]..x[t.col_ptr + c + 1]) |p| w[@as(usize, x[t.prow + p]) * N + L] = a[p * N + L];
                for (x[t.up + k]..x[t.up + k + 1]) |p| {
                    const i: usize = x[t.ui + p];
                    const uki = w[i * N + L];
                    w[i * N + L] = 0;
                    ux[p * N + L] = uki;
                    nonfinite |= @as(u64, @bitCast(uki - uki));
                    for (x[t.lp + i]..x[t.lp + i + 1]) |pl| w[@as(usize, x[t.li + pl]) * N + L] -= lx[pl * N + L] * uki;
                }
                if (x[t.flags + k] & void_bit != 0) {
                    for (0..t.n) |i| w[i * N + L] = 0;
                    return true;
                }
                var d = w[k * N + L];
                w[k * N + L] = 0;
                const dead = d == 0 or !(@abs(d) < inf);
                bad = bad or dead;
                if (dead) d = 1;
                udiag[k * N + L] = d;
                if (t.growth > 0 and x[t.flags + k] & scaled_bit == 0) {
                    var cbits: i64 = @bitCast(@abs(d));
                    for (x[t.lp + k]..x[t.lp + k + 1]) |p| {
                        const r: usize = x[t.li + p];
                        const v = w[r * N + L];
                        w[r * N + L] = 0;
                        cbits = @max(cbits, @as(i64, @bitCast(@abs(v))));
                        lx[p * N + L] = v / d;
                    }
                    const cmax: f64 = @bitCast(cbits);
                    bad = bad or !(@abs(d) >= t.growth * cmax);
                } else {
                    for (x[t.lp + k]..x[t.lp + k + 1]) |p| {
                        const r: usize = x[t.li + p];
                        const lv = w[r * N + L] / d;
                        nonfinite |= @as(u64, @bitCast(lv - lv));
                        lx[p * N + L] = lv;
                        w[r * N + L] = 0;
                    }
                }
            }
            if (nonfinite != 0) return true;
            // `wideMultipliers`: an unscaled column's L entry past 1 / pivot_tol.
            var worst: u64 = 0;
            for (0..t.n) |k| {
                if (x[t.flags + k] & scaled_bit != 0) continue;
                for (x[t.lp + k]..x[t.lp + k + 1]) |p| worst = @max(worst, @as(u64, @bitCast(@abs(lx[p * N + L]))));
            }
            return bad or !(@as(f64, @bitCast(worst)) <= t.wide);
        }

        /// `LaneLu.solve` of -rhs for lane l: dx = -A_l^-1 rhs_l, bitwise
        /// `LaneSolver.factorSolveNeg`'s vector lane. `y` is n rows of
        /// scratch.
        pub fn solveNeg(t: LaneTab, x: P(u32), lx: P(f64), ux: P(f64), udiag: P(f64), rhs: P(f64), y: P(f64), dx: P(f64), n_lanes: u32, l: u32) void {
            const N: usize = n_lanes;
            const L: usize = l;
            for (0..t.n) |r| y[@as(usize, x[t.pinv + r]) * N + L] = -rhs[r * N + L];
            for (0..t.n) |k| {
                const yk = y[k * N + L];
                if (yk != 0) for (x[t.lp + k]..x[t.lp + k + 1]) |p| {
                    y[@as(usize, x[t.li + p]) * N + L] -= lx[p * N + L] * yk;
                };
            }
            var k: usize = t.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k * N + L] / udiag[k * N + L];
                y[k * N + L] = zk;
                if (zk != 0) for (x[t.up + k]..x[t.up + k + 1]) |p| {
                    y[@as(usize, x[t.ui + p]) * N + L] -= ux[p * N + L] * zk;
                };
            }
            for (0..t.n) |j| dx[@as(usize, x[t.q + j]) * N + L] = y[j * N + L];
        }

        /// `converger.updateAndNorm` at W = 1 for lane l: x_old = x,
        /// x += dx, the delta score. Same operations in the same order.
        pub fn updateNorm(n: u32, x: P(f64), dx: P(f64), x_old: P(f64), current_row: P(u8), reltol: f64, abstol: f64, vntol: f64, n_lanes: u32, l: u32) f64 {
            const N: usize = n_lanes;
            const L: usize = l;
            const inf = std.math.inf(f64);
            var worst: i64 = 0;
            for (0..n) |i| {
                const xo = x[i * N + L];
                const d = dx[i * N + L];
                const xn = xo + d;
                x_old[i * N + L] = xo;
                x[i * N + L] = xn;
                const tol = reltol * @max(@abs(xn), @abs(xo)) + (if (current_row[i] != 0) abstol else vntol);
                const finite = @abs(xn) < inf and @abs(d) < inf;
                const q = @abs(d) / tol;
                const score = if (!finite) inf else if (q == q) q else 0;
                worst = @max(worst, @as(i64, @bitCast(score)));
            }
            return @bitCast(worst);
        }

        /// `plausible` for lane l: every |x_i| finite and <= limit.
        pub fn plausible(n: u32, x: P(f64), limit: f64, n_lanes: u32, l: u32) bool {
            for (0..n) |i| if (!(@abs(x[i * @as(usize, n_lanes) + l]) <= limit)) return false;
            return true;
        }

        /// `plausibleLimit` for lane l: the runaway bound read off the
        /// solve's first assembly (x, residual f, matrix values).
        pub fn plausibleLimit(n: u32, x: P(f64), f: P(f64), vals: P(f64), diag: P(u32), n_lanes: u32, l: u32) f64 {
            const N: usize = n_lanes;
            var g: f64 = 1;
            for (0..n) |i| g = @max(g, @abs(vals[@as(usize, diag[i]) * N + l]));
            var xm: u64 = 0;
            var fm: u64 = 0;
            for (0..n) |i| {
                xm = @max(xm, @as(u64, @bitCast(@abs(x[i * N + l]))));
                fm = @max(fm, @as(u64, @bitCast(@abs(f[i * N + l]))));
            }
            const scale = @min(@max(@as(f64, @bitCast(xm)), @as(f64, @bitCast(fm)) * g), 1e18);
            return if (!(1e3 * scale > x_plausible)) x_plausible else 1e3 * scale;
        }

        /// The transient companion residual and matrix of lane l at row/slot
        /// granularity: `integrator.companionAt(m, true, ...)` per row and
        /// `combineGC(ag0)` per slot. `method`: 0 BE, 1 trap, 2 gear-2.
        /// q1/q2 are the ring's logical slots 1 and 2 (`ring` physical
        /// slots via `perm`).
        pub fn companionRow(i: usize, method: u8, ag0: f64, ag1: f64, ag2: f64, rhs: P(f64), q: P(f64), ring: P(f64), perm: P(u8), n_hist: u32, n: u32, i_prev: P(f64), n_lanes: u32, l: u32) void {
            const N: usize = n_lanes;
            const L: usize = l;
            const s1: usize = perm[L * n_hist + 1];
            const s2: usize = perm[L * n_hist + 2];
            const a = q[i * N + L];
            const b = ring[(s1 * n + i) * N + L];
            const d = ag0 * (a - b);
            const base = rhs[i * N + L] + d;
            rhs[i * N + L] = switch (method) {
                1 => base - ag1 * i_prev[i * N + L],
                2 => base - ag2 * (b - ring[(s2 * n + i) * N + L]),
                else => base,
            };
        }

        /// A = G + ag0 C at slot p for lane l (`combinePlanes`'s order:
        /// g + alpha * c).
        pub fn combineSlot(p: usize, ag0: f64, g: P(f64), c: P(f64), a: P(f64), n_lanes: u32, l: u32) void {
            const i = p * @as(usize, n_lanes) + l;
            a[i] = g[i] + ag0 * c[i];
        }
    };
}

/// `converger.x_plausible`, the runaway floor. Kept equal by a host test.
pub const x_plausible = 1e9;
```

**CHECK** `combinePlanes` (Circuit.zig:1318) for the exact expression and
order, and copy it into `combineSlot`. If it is `g + alpha * c`, the body above
is exact.

`companionRow` copies `companionLane` at w = 1, with
`base = (out + d) - history`, as integrator.zig:205-210 rounds it.

Add the per-lane LTE and accepted-step bodies to the same file. The LTE
restates `integrator.minDel` at w = 1. Each state rounds independently and the
min is order-free, so a host run is bitwise `integrator.stepBound`, checked by a
test.

```zig
/// The LTE inputs of one step, per lane (uploaded with `LaneScalars`).
pub const LteIn = extern struct { dt: f64, dt1: f64, dt2: f64, reltol: f64, abstol: f64, chgtol: f64, trtol: f64, ag0: f64, ag1: f64, ag2: f64 };

/// `integrator.stepBound(w, method, cur_method, ...)` for one lane over its
/// contiguous history: `q[k]` is logical slot k (length `len`), methods as
/// in `companionRow`. NaN as `stepBound`. Order 1 or 2 only.
pub fn stepBound(method: u8, cur_method: u8, q0: []const f64, q1: []const f64, q2: []const f64, q3: []const f64, ip: []const f64, c: LteIn) f64 {
    const coeff: f64 = switch (method) {
        0 => 0.5,
        1 => 0.08333333333,
        else => 0.2222222222,
    };
    const sum01 = c.dt + c.dt1;
    const sum12 = c.dt1 + c.dt2;
    const sum012 = c.dt + (c.dt1 + c.dt2);
    var vmin = std.math.inf(f64);
    var poison: f64 = 0;
    for (q0, q1, q2, q3, ip) |qc, qp, qp2, qp3, i_p| {
        const i_new = switch (cur_method) {
            1 => c.ag0 * (qc - qp) - c.ag1 * i_p,
            2 => c.ag0 * (qc - qp) - c.ag2 * (qp - qp2),
            else => c.ag0 * (qc - qp),
        };
        const volttol = c.abstol + c.reltol * @max(@abs(i_new), @abs(i_p));
        const chargetol = c.reltol * @max(@max(@abs(qc), @abs(qp)), c.chgtol) / c.dt;
        const tol = @max(volttol, chargetol);
        poison += (qc - qc) + (qp - qp) + (qp2 - qp2) + (i_p - i_p);
        const f12 = (qp - qp2) / c.dt1;
        var dd = ((qc - qp) / c.dt - f12) / sum01;
        if (method != 0) {
            poison += qp3 - qp3;
            const f123 = (f12 - (qp2 - qp3) / c.dt2) / sum12;
            dd = (dd - f123) / sum012;
        }
        const del = c.trtol * tol / @max(c.abstol, coeff * @abs(dd));
        poison += if (del == del) 0 else del;
        vmin = @min(vmin, del);
    }
    if (std.math.isNan(poison)) return std.math.nan(f64);
    return if (method == 0) vmin else @sqrt(vmin);
}
```

**CHECK** two order-sensitive details:
- `poison` accumulates in element order. In `minDel` at w = W it is a vector
  sum reduced at the end. Both are NaN exactly when some term is NaN, and the
  test compares only the NaN-ness.
- The final `@min` is order-free.

So bitwise equality holds for every finite `del`. The host test (§4.1) asserts
it on random rings.

### G5. Device root: `src/solver/lane_device.zig` (new) and build.zig

```zig
//! GPU kernel root for the lane backend's model-independent kernels
//! (dev/research/plans/phase4): one thread per lane (or per (entry, lane),
//! lanes innermost) over lane-major buffers. Bodies: `lane_kernels.zig`.

const gompute = @import("gompute");
const lk = @import("lane_kernels.zig");
const P = gompute.GlobalPtr;
const B = lk.Bodies(P);
const block = 64;

/// Per-lane step inputs (`gpu_lanes.LaneScalars`), and the per-lane Newton
/// state the gate kernels read and write.
pub const LaneScalars = extern struct {
    t_dev: f64,
    dt: f64,
    xfact: f64,
    ag0: f64,
    ag1: f64,
    ag2: f64,
    method: u32, // 0 BE, 1 trap, 2 gear-2
    flags: u32, // bit 0: in this round
};

fn lane() u32 {
    return @intCast(gompute.globalIdX(block));
}

/// Also counts the failing lanes into `fails[0]` (zeroed by the graph),
/// which the host reads to decide whether to peel this tick.
fn refactor(n_lanes: u64, t: lk.LaneTab, x: P(u32), active: P(u8), a: P(f64), lx: P(f64), ux: P(f64), udiag: P(f64), w: P(f64), fail: P(u8), fails: P(u32)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0) return;
    const bad = B.refactor(t, x, a, lx, ux, udiag, w, @intCast(n_lanes), l);
    fail[l] = @intFromBool(bad);
    if (bad) _ = @atomicRmw(u32, &fails[0], .Add, 1, .monotonic);
}

fn solveNeg(n_lanes: u64, t: lk.LaneTab, x: P(u32), active: P(u8), fail: P(u8), lx: P(f64), ux: P(f64), udiag: P(f64), rhs: P(f64), y: P(f64), dx: P(f64)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0 or fail[l] != 0) return;
    B.solveNeg(t, x, lx, ux, udiag, rhs, y, dx, @intCast(n_lanes), l);
}

/// Companion rows then the combined matrix, per (row or slot, lane),
/// lanes innermost: thread t < n * N does row t / N, the rest slot
/// (t - n N) / N. Skips inactive lanes.
fn assemble(n_lanes: u64, n: u64, nnz: u64, sc: P(LaneScalars), active: P(u8), rhs: P(f64), q: P(f64), ring: P(f64), perm: P(u8), n_hist: u64, i_prev: P(f64), g: P(f64), c: P(f64), a: P(f64)) callconv(gompute.kernel_callconv) void {
    const tid = gompute.globalIdX(block);
    if (tid >= (n + nnz) * n_lanes) return;
    const l: u32 = @intCast(tid % n_lanes);
    if (active[l] == 0) return;
    const s = sc[l];
    const e: usize = @intCast(tid / n_lanes);
    if (e < n) {
        B.companionRow(e, @intCast(s.method), s.ag0, s.ag1, s.ag2, rhs, q, ring, perm, @intCast(n_hist), @intCast(n), i_prev, @intCast(n_lanes), l);
    } else B.combineSlot(e - @as(usize, @intCast(n)), s.ag0, g, c, a, @intCast(n_lanes), l);
}

/// Newton per-lane gate state, one record per lane.
pub const Gate = extern struct {
    limit: f64, // plausibleLimit, set at iteration 0
    scaled: f64,
    iterations: u32,
    /// bit 0 active, 1 init_fix, 2 converged, 3 singular, 4 ok (pre-state)
    bits: u32,
};

/// The delta gate and first-iterate/plausible tests for every active lane:
/// x_old = x, x += dx, scaled; clears the lane's flag word for the limit
/// and state passes that follow. `iter` is the device iteration word.
fn update(n_lanes: u64, n: u64, opts: NewtonOpts, iter: P(u32), active: P(u8), gate: P(Gate), x: P(f64), dx: P(f64), x_old: P(f64), cur_row: P(u8), rhs: P(f64), a: P(f64), diag: P(u32), flags: P(u32)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0) return;
    if (iter[0] == 0) gate[l].limit = B.plausibleLimit(@intCast(n), x, rhs, a, diag, @intCast(n_lanes), l);
    gate[l].scaled = B.updateNorm(@intCast(n), x, dx, x_old, cur_row, opts.reltol, opts.abstol, opts.vntol, @intCast(n_lanes), l);
    flags[l] = 0;
}

/// `finalizeStep`'s gates after the limit pass, in its order: limited,
/// first iterate, delta, plausible (the residual gate is off at
/// `residual_tol = inf`, the transient's setting; asserted on the host).
/// Sets `stage[l]` for the lanes the state pass must stage.
fn gates(n_lanes: u64, n: u64, iter: P(u32), active: P(u8), gate: P(Gate), x: P(f64), flags: P(u32), stage: P(u8)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes) return;
    stage[l] = 0;
    if (active[l] == 0) return;
    var g = gate[l];
    var ok = flags[l] & 1 == 0 and iter[0] != 0 and !(g.scaled >= 1.0);
    if (ok) ok = B.plausible(@intCast(n), x, g.limit, @intCast(n_lanes), l);
    g.bits = (g.bits & ~@as(u32, 16)) | (if (ok) @as(u32, 16) else 0);
    gate[l] = g;
    // INITFIX lanes do not stage (`stage = not(init_fix)`).
    stage[l] = @intFromBool(ok and g.bits & 2 == 0);
    if (stage[l] != 0) flags[l] = 0; // the state pass ORs its flip in fresh
}

/// The loop exit per lane, after the state pass: a lane that passed and
/// did not flip leaves INITFIX or converges (x = x_old, as `newton`
/// publishes x_k); a converged or singular lane leaves `active`. Counts
/// the lanes still active into `count[0]` (zeroed by the host), and
/// advances every active lane's `$simparam("iteration")`.
fn finalize(n_lanes: u64, n: u64, iter: P(u32), active: P(u8), stage: P(u8), gate: P(Gate), flags: P(u32), fail: P(u8), x: P(f64), x_old: P(f64), sims: P(SimState), count: P(u32)) callconv(gompute.kernel_callconv) void {
    const l = lane();
    if (l >= n_lanes or active[l] == 0) return;
    var g = gate[l];
    if (fail[l] != 0) {
        g.bits |= 8;
        active[l] = 0;
        gate[l] = g;
        return;
    }
    const passed = g.bits & 16 != 0 and (stage[l] == 0 or flags[l] & 1 == 0);
    if (passed and g.bits & 2 != 0) {
        g.bits &= ~@as(u32, 2); // INITFIX -> INITFLOAT
    } else if (passed) {
        const N: usize = @intCast(n_lanes);
        for (0..@as(usize, @intCast(n))) |i| x[i * N + l] = x_old[i * N + l];
        g.bits |= 4;
        g.iterations = iter[0] + 1;
        active[l] = 0;
        gate[l] = g;
        return;
    }
    gate[l] = g;
    sims[l].iteration +|= 1;
    _ = @atomicRmw(u32, &count[0], .Add, 1, .monotonic);
}

/// Bumps the device iteration word once per tick (a 1-thread launch, so the
/// captured graph needs no host scalar).
fn tick(iter: P(u32)) callconv(gompute.kernel_callconv) void {
    if (gompute.globalIdX(block) == 0) iter[0] += 1;
}

pub const NewtonOpts = extern struct { reltol: f64, abstol: f64, vntol: f64 };
const SimState = @import("lane_kernels.zig").SimState;

/// trial = cur + xfact (cur - prev), per (row, lane), for the lanes in the
/// round (`sc[l].flags & 1`); x_old = cur for the predictor's limit pass.
fn predict(n_lanes: u64, n: u64, sc: P(LaneScalars), cur: P(f64), prev: P(f64), x: P(f64), x_old: P(f64)) callconv(gompute.kernel_callconv) void {
    const tid = gompute.globalIdX(block);
    if (tid >= n * n_lanes) return;
    const l: usize = @intCast(tid % n_lanes);
    if (sc[l].flags & 1 == 0) return;
    const i: usize = @intCast(tid);
    const c = cur[i];
    x[i] = c + sc[l].xfact * (c - prev[i]);
    x_old[i] = c;
}

comptime {
    if (gompute.is_device) {
        gompute.exportRaw("arp_lane_refactor", &refactor);
        gompute.exportRaw("arp_lane_solve", &solveNeg);
        gompute.exportRaw("arp_lane_assemble", &assemble);
        gompute.exportRaw("arp_lane_update", &update);
        gompute.exportRaw("arp_lane_gates", &gates);
        gompute.exportRaw("arp_lane_finalize", &finalize);
        gompute.exportRaw("arp_lane_tick", &tick);
        gompute.exportRaw("arp_lane_predict", &predict);
        gompute.exportRaw("arp_lane_lte", &lte);
        gompute.exportRaw("arp_lane_accept", &accept);
        gompute.exportRaw("arp_lane_gather", &gather);
    }
}
```

The state pass ORs its flip into `flags[l]` bit 0 (`LaneStateKernel` sets 1 on
non-converged *limit* and 2 on a reject request). `gates` clears `flags[l]`
before the state pass, so after it bit 0 or 1 means flipped. **CHECK** the
state half: its `.request_reject_at` goes to bit 2 here and is treated as a
fault (§2 G7 eligibility excludes devices that request it). Its "flip" is
`updateStates() != null` in the host's terms, which is the host
`walk.updateBatches`' reject time. A device that flips through a path latch
reports it through `stateCtl(.query)`, not through `updateState`'s result.
Compare `walk.updateBatches` with `GpuContext.updateStates` and copy their
flip rule into `finalize`.

`SimState` must be visible to this std-only file. Add a copy that is checked
against the real one:

```zig
// lane_kernels.zig
/// VerA's `contract.SimState` (24 bytes, extern), restated so this file
/// stays std only; `gpu_lanes.zig` asserts the two layouts equal.
pub const SimState = extern struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: u8 = 0, // CHECK: contract's AnalysisKind is an enum; match its backing int and size
    initial_step: bool = false,
    final_step: bool = false,
    analog_initial: bool = true,
    iteration: u32 = 1,
};
```

**CHECK:** `AnalysisKind`'s backing type. If it is not `u8`, size this field to
match so that `@offsetOf(SimState, "iteration") == 20` holds. Assert it in
gpu_lanes.zig: `comptime assert(@sizeOf(lk.SimState) == @sizeOf(abi.SimState))`.

The remaining device bodies, written the same way. These are full
specifications. Each is a loop over the documented indices, and each restates
the named host statement:

- `lte(n_lanes, sc, mask, ring_qt (lane-minor), perm_qt, ip_qt (lane-minor),
  n_hist, n_qt, lte_in: P(LteIn), out: P([2]f64))`: thread = lane, skipping
  lanes not in the round. Calls `lk.stepBound(method, method, q0..q3, ip,
  lte_in[l])` with `q_k = ring_qt[(l*n_hist + perm[l*n_hist+k])*n_qt ..][0..n_qt]`
  (contiguous per lane, so the slice form works on the device after an
  `@addrSpaceCast`). For a lane at order 1 it also calls `stepBound(promote,
  method, ...)`, where `promote` is `methodAt(top, 2)` coded per lane in
  `LaneScalars.flags` bits 4-5. Writes `out[l] = .{ del, del2 }`.
  - The row-ring fallback (n_qt == 0 with charge) is **not** supported. G7's
    eligibility requires the tape.
- `accept(n_lanes, n, sc, mask_accept, x, cur, prev, q, ring, perm_q, ip_rows,
  ring_qt, perm_qt, ip_qt, n_hist, n_qt)`, per (row-or-tape-entry, lane),
  lanes innermost, for accepted lanes:
  - `prev <- cur`, `cur <- x` (rows);
  - the row ring's logical slot 0 is the q plane (the charge re-read wrote it):
    copy `q` into physical slot `perm_q[l*n_hist+0]`;
  - `advanceCurrent` rows: `ip = ag0*(q0 - q1) - hist` (the `companionAt(m,
    false, ...)` expression);
  - the same for the tape (lane-minor) with `ip_qt`.

  The host has already rotated `perm_q`/`perm_qt` for the next step (G6). This
  kernel reads the pre-rotation slots, passed as `slot0`/`slot1`/`slot2` per
  lane in `LaneScalars`, which keeps it stateless.
- `gather(n_lanes, mask, x, probes: P(u32), n_probes, out)`: `out[l*np + k] =
  x[probes[k]*N + l]` for the lanes in `mask`.

### G6. Host device context: `src/analysis/gpu_lanes.zig` (new)

Same comptime backend selection as gpu.zig (`artifacts`, `Raw`, `Buffer`,
`Stream`). Fields:

```zig
pub const GpuLanes = struct {
    gpa: std.mem.Allocator,
    n_lanes: u32,
    n: u32,
    nnz: u32,
    n_hist: u32,
    n_qt: u32,
    n_probes: u32,
    batches: []LaneBatch,
    k: Kernels, // the arp_lane_* raw kernels
    stream: Stream,
    // lane-major
    d_x: Buffer, d_x_old: Buffer, d_dx: Buffer, d_cur: Buffer, d_prev: Buffer,
    d_g: Buffer, d_c: Buffer, d_rhs: Buffer, d_q: Buffer, d_a: Buffer,
    d_lx: Buffer, d_ux: Buffer, d_udiag: Buffer, d_w: Buffer, d_y: Buffer,
    d_ring: Buffer, d_ip: Buffer,
    // lane-minor
    d_ring_qt: Buffer, d_ip_qt: Buffer,
    // per lane
    d_sc: Buffer, d_sims: Buffer, d_active: Buffer, d_stage: Buffer, d_gate: Buffer,
    d_flags: Buffer, d_fail: Buffer, d_ops: Buffer, d_perm_q: Buffer, d_perm_qt: Buffer,
    d_lte_in: Buffer, d_lte_out: Buffer, d_probe_out: Buffer,
    // tables
    d_tab_idx: Buffer, tab: lk.LaneTab, tab_epoch: u32,
    d_cur_row: Buffer, d_diag: Buffer, d_probes: Buffer,
    // device words: iteration, active count, lim_active per batch
    d_words: Buffer,
    // pinned host mirrors of every per-lane buffer that moves each round
    pin: Pinned,
    graph_a: ?Raw.GraphExec, graph_b: ?Raw.GraphExec, // API?: GraphExec type path
    lead: ?*direct.Solver, // the tape's owner lane's solver
};

/// One device batch over every lane: the batch's shared tapes, its
/// deduplicated Model rows and lane-major Instance/State/lim rows, and
/// its lane kernels.
const LaneBatch = struct {
    eval: Raw,
    lim: ?Raw,
    ctl: ?Raw,
    qtp: ?Raw,
    count: u32,
    n_u: u32,
    k_lim: u32,
    tape_off: u32,
    d_models: Buffer,
    d_model_of: Buffer, // count * N u32, lane-major
    d_instances: Buffer, // count * N rows of inst_size
    d_states: Buffer,
    d_lim: Buffer, // count * k_lim * N
    d_gath: Buffer,
    d_rhs_idx: Buffer,
    d_slots: Buffer,
    lim_word: u32, // index into d_words
};
```

**`init(gpa, ckts: []const *Circuit, probes, n_probes, opts) !*GpuLanes`.** The
packing code:

```zig
    /// Lane-major rows of batch b over every lane: Model rows deduplicated
    /// by bytes (the "packed rows" of §3.2), model_of, instances, states and
    /// the lim plane. `ps[l]` is lane l's `GpuPayload` for b.
    fn pack(gpa: std.mem.Allocator, ps: []const abi.GpuPayload) !Packed {
        const p0 = ps[0];
        const n_lanes = ps.len;
        const count: usize = p0.count;
        var rows_n: u32 = 0;
        for (p0.model_of) |r| rows_n = @max(rows_n, r + 1);
        const ms = p0.models.len / rows_n; // @sizeOf(D.Model)
        const is = if (count == 0) 0 else p0.instances.len / count;
        const ss = if (count == 0) 0 else p0.states.len / count;
        const kl = if (count == 0) 0 else p0.lim_x.len / count;
        var index: std.StringHashMapUnmanaged(u32) = .empty;
        defer index.deinit(gpa);
        var models: std.ArrayList(u8) = .empty;
        errdefer models.deinit(gpa);
        const model_of = try gpa.alloc(u32, count * n_lanes);
        errdefer gpa.free(model_of);
        const inst = try gpa.alloc(u8, count * n_lanes * is);
        errdefer gpa.free(inst);
        const states = try gpa.alloc(u8, count * n_lanes * ss);
        errdefer gpa.free(states);
        const lim = try gpa.alloc(f64, count * kl * n_lanes);
        errdefer gpa.free(lim);
        for (ps, 0..) |p, l| {
            std.debug.assert(p.count == p0.count and std.mem.eql(u32, p.gath, p0.gath) and std.mem.eql(u32, p.slots, p0.slots));
            for (0..count) |id| {
                const row = p.models[@as(usize, p.model_of[id]) * ms ..][0..ms];
                const gop = try index.getOrPut(gpa, row);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(models.items.len / ms);
                    try models.appendSlice(gpa, row);
                }
                model_of[id * n_lanes + l] = gop.value_ptr.*;
                @memcpy(inst[(id * n_lanes + l) * is ..][0..is], p.instances[id * is ..][0..is]);
                if (ss != 0) @memcpy(states[(id * n_lanes + l) * ss ..][0..ss], p.states[id * ss ..][0..ss]);
                for (0..kl) |a| lim[(id * kl + a) * n_lanes + l] = p.lim_x[id * kl + a];
            }
        }
        return .{ .models = try models.toOwnedSlice(gpa), .model_of = model_of, .instances = inst, .states = states, .lim = lim };
    }
```

The hash map keys borrow each lane's payload bytes, which outlive `pack`.
**CHECK** that `GpuPayload.models` keeps its address while `index` lives. It
does: the batches are frozen.

**Upload** per lane, via pinned staging:
- x_op into `d_cur` and `d_prev`, lane-major;
- each lane's `i_prev`, row ring and tape ring as the CPU `Sim.init` leaves
  them. Run each lane's `Sim.init` on the host, which does the OP-point charge
  seeding, then copy `s.qHist()`, `s.i_prev`, `s.qtHist()` and `s.qt_i_prev`
  in. This keeps `init` single-sourced.
- `perm_q`/`perm_qt` = identity.

**The LU tape.** `buildTab(gpa, lu: *const SparseLu, col_ptr) !struct { idx: []u32, tab: LaneTab }`
concatenates `col_ptr`, `prow`, `q`, `pinv`, `lp`, `li`, `up`, `ui` and the
flags (from `void_col`/`scaled_pivot`) into one u32 buffer. The lead is the
first lane whose solver holds a factored `SparseLu` after the OP (the
`LaneSolver.rejoin` rule). Lanes whose `tapeKey` differs from the lead's start
peeled (below).

**The Newton tick** (`newton(round_mask) !LaneResults`):

```
host:  words[iter] = 0; upload d_active (round), d_gate.bits = active | init_fix(0)
       per lane: sims[l].iteration = 1 (beginSolve)
loop iter < max_iter:
  graph A (captured once):
    fillAsync(d_g, d_c, d_rhs, d_q, 0)
    for batch: arp_leval_<m>(N, count, sims, active, lim_word, d_x, tapes, rows, planes, lim)
    arp_lane_assemble
    arp_lane_refactor ; arp_lane_solve
    fillAsync(fails word, 0) before the refactor; downloadAsync(fails word)
  sync
  if fail count > 0: peel (below)
  graph B (captured once):
    arp_lane_update
    for batch with lim: arp_llim_<m>(halves = limit, mask = active, x = d_x, x_old = d_x_old)
    arp_lane_gates
    for batch with state: arp_llim_<m>(halves = state, mask = d_stage, x = d_x_old)
    count word = 0 (fillAsync 4 B) ; arp_lane_finalize ; arp_lane_tick
    downloadAsync(count word)
  sync
  if count == 0: break
download d_gate (N records) -> per-lane converger.Result / singular
```

- **Peel.** Download `d_fail` (N bytes) and the failing lanes' A and rhs
  columns. For each failing lane l:
  - deinterleave A and rhs;
  - run `ckts[l].ws.slv.factor(a_l)` then `solveNeg`, its scalar path;
  - on `SingularMatrix`, mark `fail[l] = 2` (singular, which `finalize` maps to
    bit 3); otherwise upload `dx_l` lane-major and clear `fail[l]`.

  A lane whose new tape (`tapeKey`) differs from the lead's stays peeled every
  tick (`peel[l]` host mask). When more than N/8 lanes are peeled, re-lead:
  rebuild the tab from the most common tape among the peeled lanes and move
  them back. **CHECK** with a measured peel rate on the chain. §1 found 16/16
  sharing one grid, so the tape is expected to stay shared.
- **`lim_word` per batch.** Set to 1 by the round's predictor limit pass and to
  0 after Newton (`clearLimits`), via `fillAsync` on the word.
- **`x_old` for the limit pass.** `LaneStateKernel` reads `x_old` as
  `finalizeStep` passes it to `applyLimits(x, x_old)`. **CHECK** that `update`
  leaves x_old = the pre-update x, which the limit pass compares against, as on
  the host.

**Round operations** (`GpuLanes.Ops`, the G1 backend for lane l):

```zig
/// The G1 backend of lane l of a `GpuLanes` round: the device did the
/// numerics for every lane at once (`probe`); this answers `Sim.end`'s
/// calls from those numbers and queues lane l's mutations for `apply`.
pub const Ops = struct {
    g: *GpuLanes,
    l: u32,

    pub fn attempt(o: Ops, s: anytype, a: anytype) void {
        // Gear-3..6 and predictFirstIterate devices are ineligible (G7).
        o.g.pin.sc[o.l] = .{ .t_dev = a.t_dev, .dt = s.dt, .xfact = s.dt / s.dt_old[0], .ag0 = a.c.ag0, .ag1 = a.c.ag1, .ag2 = a.c.ag2, .method = methodCode(a.method), .flags = 1 };
        o.g.pin.sims[o.l] = @bitCast(s.ckt.sim); // CHECK: same layout (asserted)
        o.g.pin.lte_in[o.l] = .{ .dt = s.dt, .dt1 = s.dt_old[0], .dt2 = s.dt_old[1], .reltol = s.options.tol.reltol, .abstol = s.options.tol.abstol, .chgtol = s.options.tol.chgtol, .trtol = s.options.tol.trtol, .ag0 = a.c.ag0, .ag1 = a.c.ag1, .ag2 = a.c.ag2 };
    }
    pub fn revert(o: Ops, _: anytype) void {
        o.g.pin.ops[o.l] = 1 + @as(u8, @backingInt(StateCtlOp.revert));
    }
    pub fn rejectAt(_: Ops, _: anytype) ?f64 {
        return null; // reject-requesting devices are ineligible
    }
    pub fn flipped(o: Ops, _: anytype, _: anytype, ask: bool) bool {
        return ask and o.g.pin.query[o.l] & 1 != 0;
    }
    pub fn boundStep(_: Ops, _: anytype) ?f64 {
        return null; // bound_step devices are ineligible
    }
    pub fn charges(_: Ops, _: anytype, _: anytype) void {} // probe did it for the round
    pub fn bound(o: Ops, s: anytype, a: anytype, method: Method, _: anytype) f64 {
        const out = o.g.pin.lte_out[o.l];
        _ = s;
        // `end` asks for the step's own method, or the order-2 promotion
        // probe (the only other order <= 2 call).
        return if (method == a.method) out[0] else out[1];
    }
    pub fn boundGear(_: Ops, _: anytype, _: anytype, _: Method, _: anytype) f64 {
        unreachable; // gear-3..6 ineligible
    }
    pub fn advance(o: Ops, s: anytype, _: anytype) void {
        // The device advances i_prev at `apply`; here only the rings' heads
        // move, as `std.mem.rotate` moves the host slices.
        o.g.queueAccept(o.l, s.n_hist);
    }
    pub fn commit(o: Ops, _: anytype) void {
        o.g.pin.ops[o.l] = 1 + @as(u8, @backingInt(StateCtlOp.commit));
    }
    pub fn rebase(o: Ops, s: anytype, _: anytype) void {
        if (s.has_charge and s.ckt.has_state_q) o.g.pin.rebase[o.l] = 1;
    }
    pub fn accepted(o: Ops, _: anytype) []const f64 {
        return o.g.probeRow(o.l); // n-long host scratch, probe rows filled
    }
};
```

- `queueAccept(l, n_hist)` records `slot0..2` (the pre-rotation physical slots)
  into `pin.sc[l]`, rotates lane l's host permutation `perm_q[l*n_hist ..]` by
  `n_hist - 1` (same as `std.mem.rotate`), does the same for `perm_qt`, and
  sets `pin.accept[l] = 1`.
- `rebase` with `has_state_q` also swaps `perm_qt` slots 0 and 1, as
  `std.mem.swap` does. It is executed in `apply` as: eval with charge at cur,
  then the rebase kernel (`rebaseCurrent` rows and tape), then the q-tape
  kernel into slot 0. **CHECK** that the swap order matches the host:
  `lteSnap` into slot 0, rebase, then the swap.

**`probe(round)`** (one stream, one sync at the end):
1. Every batch's ctl kernel with `ops = query` for round lanes, then download
   `flags` into `pin.query`.
2. `fillAsync` the planes, every batch's lane eval at `d_x` with the round
   lanes' sims (t_dev), then every batch's qtp into slot `perm_qt[l*n_hist]`,
   and the q plane copied into the row ring slot 0 (the copy is in
   `arp_lane_accept`'s first phase, keyed by mask).
   - The extra eval is the host's `evalQ(trial)` when `!q_fresh`. The host GPU
     path pays it today too. **Fuse later** (G10).
3. `arp_lane_lte`, then download `lte_out`.
4. `arp_lane_gather` of `d_x`'s probe rows, then download `probe_out`.

**`apply(round)`:**
1. Upload `pin.ops`, `pin.sc` and the permutations.
2. Every batch's ctl kernel with per-lane ops: revert for rejected lanes,
   commit for accepted lanes.
3. `arp_lane_accept` for accepted lanes.
4. The rebase sequence for `pin.rebase` lanes.
5. Clear `pin.ops`, `accept` and `rebase`.

### G7. Transient driver and eligibility: `src/analysis/tran/tran.zig`

```zig
/// Whether `runGpuLanes` can serve a batch of this circuit and these
/// options: every batch resident with lane kernels (no host batch, no
/// host-stepped batch), and none of the features whose step-end numbers
/// the device does not compute.
pub fn gpuLaneEligible(ckt: *const root.Circuit, opts: Options) bool {
    if (!gpu_lanes.available) return false;
    if (opts.uic or opts.snapshot or opts.sources_at_zero or opts.tangents.len != 0) return false;
    if (integrator.order(opts.method) > 2) return false;
    if (ckt.vpi != null or ckt.display != null or ckt.load_check != null) return false;
    if (ckt.minDelay() != null) return false;
    if (ckt.has_charge and (ckt.knobs.no_qtape or ckt.qTapeLen() == 0)) return false;
    for (ckt.batches) |b| {
        if (b.hooks.gpu_payload == null) return false;
        if (!gpu_lanes.hasLaneImage(b)) return false;
        if (b.hooks.bound_step != null or b.hooks.commit_state != null or b.hooks.predict_first_iterate != null) return false;
        if (std.mem.eql(u8, b.type_name, "kinduc")) return false;
        if (gpu_lanes.hostStepped(b)) return false;
    }
    return true;
}
```

**CHECK** each hook name against `device_ir.Hooks`, and whether timer-only
vsource/isource are "host-stepped". E1 ran vsource on the device in a
transient, so they should pass. If their `update_state`/`state_ctl` hooks
exist, `GpuContext.loadBatch` marks them `stepped`. Mirror that rule in
`hostStepped`. If vsource turns out stepped, extend v1 with per-round host
stepping of those batches plus an upload of their changed rows, which is
`pushStepped` lane-strided.

`runGpuLanes(ctxs, opts, out)` follows `runLanes` (phase 3 §2.3). Each round:
1. Every live lane calls `sim.begin(gpu.ops(l))`. A null is `finish` + `take`.
2. `g.predictRound(round)`: upload, `arp_lane_predict`, the predictor limit pass
   with `x_old = cur`, and `lim_active` set.
3. `g.newton(round)`, giving per-lane `converger.Result`s, then
   `lim_active = 0`.
4. `g.probe(round)`.
5. Per lane in `round`: `sim.end(&atts[l], nr_l, gpu.ops(l))`. Its verdict is
   handled as in `runLanes`.
6. `g.apply(round)`.

On `GpuLanes.init` failure (memory, driver), every lane runs `run`. That is
correct and slow, and it prints one warning naming the error.

### G8. Policy, scheduling, executor

`executor.Config` (executor.zig:43) gains:

```zig
    /// Batch ready transients as GPU lanes (dev/research/plans/phase4):
    /// decided once per Problem by `gpu_lanes.policy`, true for an explicit
    /// `cuda`/`hip` and, under `auto`, on an FP64-class device only.
    gpu_lanes: bool = false,
    /// Lanes per GPU batch at most (`ESPICE_GPU_LANES`).
    gpu_lane_cap: u32 = 16384,
```

`gpu_lanes.zig`:

```zig
/// Whether this Problem batches transients as GPU lanes: an explicit
/// `cuda`/`hip` does unless `ESPICE_LANES=0`; `auto` only on a device whose
/// FP64 rate is at least a quarter of FP32 (datacenter parts report 2; the
/// RTX 4060 Laptop 64, where E1 measured the GPU at 1.4-2x the 24-core CPU,
/// so `auto` keeps the CPU there).
pub fn policy(config: executor.Config) bool {
    if (config.knobs.lanes == false) return false; // explicit ESPICE_LANES=0
    return switch (config.backend) {
        .cpu => false,
        .cuda, .hip => available,
        .auto => available and fp64RatioAtMost(4),
    };
}
```

`fp64RatioAtMost` opens `gompute.runtime.dynamic.Compute.init(null)`, reads
`fp64Ratio()` and deinits. On HIP it returns `error.Unsupported`, which counts
as false: no AMD box to measure on, so `auto` declines (**API?** confirmed in
compute.zig:88-92). It costs the driver init once per Problem.
- Call site: `espice.zig` `Problem.init` (line ~266), where `execution` is
  built: `execution.gpu_lanes = analysis.gpu_lanes.policy(execution);`.
- `knobs.lanes` is `?bool` (the `orelse` in `lanesOn`), so the comparison above
  is `config.knobs.lanes != null and !config.knobs.lanes.?`. **CHECK** the
  type.

`session.zig`:
- `nextReady` (line ~663), breadth-first under GPU lanes. OPs drain before
  their transients, so the transients become ready together and gather N wide:

```zig
    fn nextReady(self: *Session) ?usize {
        if (!self.config.gpu_lanes) while (self.urgent.pop()) |i| if (self.ready(i) and !self.rows.items(.running)[i]) return i;
        while (self.queue_head < self.queue.items.len) {
            const i = self.queue.items[self.queue_head];
            self.queue_head += 1;
            if (self.ready(i) and !self.rows.items(.running)[i]) return i;
        }
        if (self.config.gpu_lanes) while (self.urgent.pop()) |i| if (self.ready(i) and !self.rows.items(.running)[i]) return i;
        return null;
    }
```

- `gather` (line ~474) gets a GPU branch first:

```zig
        if (config.gpu_lanes and jobs[i] == .tran and self.rows.items(.executor)[i] == null) return self.gatherWide(i);
```

```zig
    /// The GPU lane form of `gather`: up to `gpu_lane_cap - 1` ready,
    /// never-started `.tran` rows of row i's template and options, from all
    /// of `urgent` and the queue (a sweep's transients are ready together
    /// under breadth-first order). A row whose executor cannot be built is
    /// left to run alone.
    fn gatherWide(self: *Session, i: usize) void {
        const jobs = self.rows.items(.job);
        var peers: std.ArrayList(usize) = .empty;
        defer peers.deinit(self.allocator);
        const cap = self.config.gpu_lane_cap - 1;
        const queued = self.queue.items[@min(self.queue_head, self.queue.items.len)..];
        for ([_][]const u32{ self.urgent.items, queued }) |list| for (list) |j32| {
            if (peers.items.len == cap) break;
            const j: usize = j32;
            if (j == i or !self.ready(j) or self.rows.items(.running)[j] or self.rows.items(.executor)[j] != null) continue;
            if (self.rows.items(.template)[j] != self.rows.items(.template)[i]) continue;
            if ((self.rows.items(.dependency)[j] == none) != (self.rows.items(.dependency)[i] == none)) continue;
            if (!sameLaneJob(jobs[i], jobs[j])) continue;
            peers.append(self.allocator, j) catch break;
        };
        if (peers.items.len == 0) return;
        self.makeExecutor(i) catch return;
        const leader = self.rows.items(.executor)[i].?;
        const list = leader.work.allocator().alloc(*execution.Executor, peers.items.len) catch return;
        var taken: usize = 0;
        for (peers.items) |j| {
            self.makeExecutor(j) catch continue;
            list[taken] = self.rows.items(.executor)[j].?;
            taken += 1;
            self.rows.items(.running)[j] = true;
        }
        leader.peers = list[0..taken];
    }
```

**CHECK** the element type of `urgent`/`queue` (`u32`, per `urgent:
std.ArrayList(u32)` at line 147). A row may appear in both lists, but the
`running` flag set during the scan prevents taking it twice.

`executor.zig`:
- `executeBatch` dispatches `if (self.config.gpu_lanes and self.job == .tran)
  return self.executeGpuBatch();` before the `lane_width` assert.
- `executeGpuBatch` is `executeBatch`'s `.tran` branch with arena slices in
  place of the `[lane_width]` arrays:

```zig
    /// `executeBatch` for a GPU lane batch: `peers` may be thousands wide,
    /// so the per-member arrays come from the work arena.
    fn executeGpuBatch(self: *Executor) QueryError!types.Result {
        const a = self.work.allocator();
        const g = 1 + self.peers.len;
        const members = try a.alloc(*Executor, g);
        members[0] = self;
        @memcpy(members[1..], self.peers);
        const outcomes = try a.alloc(QueryError!types.Result, g);
        @memset(outcomes, error.QueryCancelled);
        defer for (members[1..], outcomes[1..]) |p, o| {
            if (o) |r| p.published = r else |err| p.peer_failure = err;
        };
        const live = try a.alloc(usize, g);
        var n_live: usize = 0;
        // ponytail: serial materialize; thousands of lanes take seconds here.
        // Parallelize over a thread pool if it shows above 5% of the batch.
        for (members, 0..) |e, k| {
            e.materialize() catch |err| {
                outcomes[k] = err;
                continue;
            };
            e.circuit.progress = self.controller.callback();
            live[n_live] = k;
            n_live += 1;
        }
        const ctxs = try a.alloc(types.RunCtx, n_live);
        for (live[0..n_live], ctxs) |k, *c| {
            members[k].circuit.setSimState(.{ .kind = .ic });
            c.* = members[k].runCtx();
        }
        const ran = try a.alloc(tran.LaneOutcome, n_live);
        if (n_live != 0) tran.runGpuLanes(ctxs, self.job.tran, ran, self.config);
        for (live[0..n_live], ran) |k, o| {
            outcomes[k] = if (o) |r| members[k].label(r) else |err| err;
            members[k].refuseLatched() catch |err| {
                outcomes[k] = err;
            };
        }
        return outcomes[0];
    }
```

Gather already filters for eligibility: `gatherWide` is only reached for
`.tran`. `runGpuLanes` re-checks `gpuLaneEligible` on lane 0's circuit and falls
back to per-lane `run`. To avoid serializing an ineligible sweep onto one
worker, also check the template up front: `gatherWide` returns at once unless
`tran.gpuLaneEligibleTemplate(self.prepared, jobs[i].tran)` holds. That applies
`gpuLaneEligible`'s batch rules to the prepared topology's batch types.
**CHECK** whether the template exposes `batches` with hooks before
`instantiate`. If not, cache the decision per template after the first
materialize: one scalar run, then wide.

### G9. Tests and gates

Host tests run in `test-solver`/`test-analysis` without a GPU. Bodies use
`P = [*]T`.

**`src/solver/lane_kernels.zig`:**

```zig
test "lane_kernels refactor and solveNeg over N lanes are bitwise LaneSolver(W)'s vector lanes, and fail exactly where it peels" {
    // As `expectLanesMatch` (lane_solver.zig): 64 random systems, W = 4.
    // Each trial: factor lane 0's values on a SparseLu (the lead tape),
    // build the LaneTab (`buildTab`, defined in gpu_lanes.zig's host part:
    // move it here so the test owns it), lay out W lanes' values
    // lane-major, run `Bodies(HostP).refactor` and `.solveNeg` per lane, and
    // compare against `LaneSolver(W).factorSolveNeg` on the same values:
    // every lane LaneSolver solved on the vector path (`joined` and not in
    // its peel set) is bitwise dx; every lane it peeled or found singular
    // has `refactor` == true.
}

test "lane_kernels updateNorm and plausibleLimit at one lane are bitwise converger's W = 1 forms" {
    // Random x, dx (with NaN, inf, -0.0 entries), current_row: compare
    // `updateNorm` per lane against `converger.updateAndNorm(1, ...)` on the
    // deinterleaved lane, and `x_plausible` against converger's constant
    // (CHECK: export `x_plausible` from converger.zig as pub, or compare
    // through `plausibleLimit` on a crafted case).
}
```

`HostP` is `fn (comptime T: type) type { return [*]T; }`, as
`lu_kernels.HostSy.P`.

**`src/analysis/tests/transient.zig`:**

```zig
test "lane_kernels.stepBound is bitwise integrator.stepBound on random rings, NaN where it is NaN" {
    // For methods (BE, trap, gear2) x cur_methods, 200 random rings of
    // length 1..300 with occasional NaN/inf and tiny dt ratios: compare
    // `solver.lane_kernels.stepBound` against `integrator.stepBound(W, ...)`
    // (`test_access.integrator`): bits equal, or both NaN.
}

test "lane_kernels.companionRow equals integrator.companionAt(m, true, ...) per row" {
    // One lane (N = 1), identity perm: rhs after companionRow == rhs after
    // companionAt on the same q, q1, q2, i_prev, bitwise, per method.
}
```

**G1's CPU gate:** corpus byte-identical (phase 3 §4.4 a, b, c).

**GPU parity:** `zig build test-gpu-lanes`, a new build step on a CUDA box.

```zig
// build.zig, beside run_gpu_corpus (line 268)
const run_gpu_lanes = corpus(b, correctness, exe, vpi_fixture, &.{ "--backend", "cuda", "--jobs", "1", "--lanes-parity" });
b.step("test-gpu-lanes", "Every eligible .tran deck as replicated GPU lanes against the CPU lane oracle").dependOn(&run_gpu_lanes.step);
```

`--lanes-parity` in `tests/test_correctness.zig` takes every eligible `.tran`
deck (the runner does not know eligibility; let espice report
`gpu-lanes: N lanes` on stderr under `ESPICE_GPU_STATS`, and skip decks that
don't print it). For each deck:
- (a) rewrite it with `.param lane_rep=0` plus `.step param lane_rep list 1
  .. 64` (as `lane_diff.py replicate`);
- (b) run it with `--backend cuda` and `--backend cpu` + `ESPICE_LANES=1`;
- (c) compare every replica's columns with the corpus closeness the runner
  already uses (`close(actual, expected, rtol = 1e-3, atol = 1e-3 * peak +
  1e-15)`, test_correctness.zig:397). Also assert the 64 GPU replicas are
  bitwise equal to each other (determinism).

Report the worst ratio as test-gpu does ("6e-9 of rtol 1e-3"). The gate is the
same budget. `VERDICTS.tsv` must not move under `test-gpu`.

Mixed lanes on the GPU: `src/tests/espice.zig` adds a GPU-guarded test.

```zig
test "lane lockstep on the GPU: each .data point within test-gpu tolerance of its CPU lane, GPU lanes bitwise deterministic" {
    if (!@import("analysis").gpu_lanes.available) return error.SkipZigTest;
    // chain_deck x chain_rows (phase 3 §4.3), Problem backend .cuda:
    // run twice (determinism: bitwise), and against the CPU-lane run:
    // every point's samples within rtol 1e-3 of its CPU value (same grid
    // length; a grid that differs fails with the point index), the
    // failing row failing on both.
}
```

**Throughput gate (§11):** points per second on `gen_chain.py`'s 24-stage
chain, N = 4096 and 8192, against phase 0 on all CPU cores (24 independent
`espice` jobs, early stop on for both). Report:
- kernel time per tick split: eval, assemble, LU, gates and limit, state;
- per-round probe and apply time;
- peel rate;
- idle fraction from early stop.

Record it in `dev/research/gpu-lane-e1.md` §7 (or a new `gpu-lane-e2.md`).

### G10. Follow-ups gated on G9's measurements (not on the critical path)

- **Fused charge re-read.** The probe's extra eval per round is +1/2.25 of the
  ticks' evals (~44%). Fuse `acceptQ` into the state half
  (`LaneStateKernel` running `D.acceptQ` where the model has it, as the host's
  `acceptStates` does). Then the device's `q_fresh` lanes skip the eval.
- **Thread per (instance-color, lane) with hub staging** if wave quantization
  shows (N below ~2x resident threads). Color the instances so that no two in
  a color share a non-hub plane cell, with level order (instance i before j on
  a shared cell means color(i) < color(j)), which keeps the host's per-cell
  order. Hub cells (degree > 8: supply rows) go to a small staging run plus a
  reduce over just those cells.
- GPU OP lanes (the masked ladder), and refill.

## 3. W = 1 identity and codegen probes

- G1 is the only edit to scalar code. `HostOps` methods are `inline` on a
  zero-size value. The gate is behavioural (corpus byte-identical), as in
  phase 3 §3. No `gen_`/`hand_` pair is added: tests/codegen.zig cannot host
  `Sim`.
- The lane kernel bodies are *restatements* with oracles, not generalizations
  of scalar code, so they need no codegen probe. Their oracles are bitwise
  host tests (§G9) against `LaneSolver`, `converger.updateAndNorm(1)`,
  `integrator.stepBound` and `integrator.companionAt`.
- The single-circuit GPU path (`DeviceKernel` and the others) is untouched.
  `test-gpu` must not move.

## 4. Risks, open questions, what only a build or GPU run settles

1. **Wave quantization at modest N (decision 2).**
   - A thread per lane means N threads per eval launch. On the 4060 (6144
     resident at 17% occupancy) N = 8192 is 1.33 waves (~20% tail loss);
     N = 16384 is 2.7 waves (~10%).
   - On an A100 (~27k resident at 17%), N = 8192 fills 30% of the card.
   - The plan therefore defaults the cap to 16384 and lets memory set N. The
     lane path has no staging, so an 8 GB card holds ~40k lanes of the chain
     (≈190 KB per lane, §3.3).
   - If MATCHA's batches are small, G10's colored mapping is the fix.
   - Only a GPU run settles it: kernel time per instance-eval in the lane
     kernel against E1's 0.19-0.21 µs.
2. **Per-thread serial walk vs E1's thread per instance.**
   - E1 measured the per-instance kernel. The lane kernel's thread holds one
     instance's frame at a time, so its frame and spills are the same (20.8 KB),
     but each thread now runs 48 serial evals of bsimcmg plus the R/C/V batches'
     launches.
   - Expected throughput is equal at saturation. Only a run confirms it.
3. **Uncoalesced Model rows.**
   - Distinct sizes make each lane read its own 22.6 KB row: E1's +10%.
   - Lanes of equal size share one row via dedup.
   - A field-major (SoA) Model would coalesce, but needs VerA to emit field
     accessors. That is out of scope.
4. **Device and host step control must match.** G1 makes `end` single-sourced,
   but the GPU's numbers (`del`, the flip query, Newton outcomes) differ from the
   CPU's in the last bits. A step can then accept on one backend and reject on
   the other, and the grids desynchronize. Results stay within tolerance (both
   are valid runs), but the GPU parity test must compare by interpolation when
   grids differ, not row by row. The runner's `sample` path handles axis
   resampling (test_correctness.zig:751). **CHECK** that the replicated-lane
   comparison uses it.
5. **`.request_reject_at`, host-stepped batches, gear-3..6, delays, tangents
   and uic are ineligible in v1.** A deck that uses one runs CPU-side, and its
   batch never forms (template check).
6. **Graph capture of the tick.**
   - Every scalar the tick reads lives in a device word (iteration, lim_active,
     the count).
   - The sims, scalars and masks are buffers.
   - Params are copied at capture, so the graphs are captured once per batch
     and replayed. **API?:** `Raw.GraphExec` and `stream.beginCapture(.thread_local)`
     on `RawByName` handles. SKILL.md shows them on `Kernel(spec)`;
     REFERENCE.md lists `Graph`/`GraphExec` on raw kernels.
   - Fallback: plain launches, ~1.5 µs each, about 20 per tick, so ~30 µs
     against ≥ 10 ms of eval.
7. **`fp64Ratio` on HIP** returns `Unsupported`, so `auto` declines on AMD.
   MI250/MI300 are FP64-class. Revisit with an AMD box.
8. **Compile time.**
   - Lane kernels double each model's device code (ptxas ~2x per model; 12 GB
     peaks for asmhemt/bsimsoi_va when G0 empties `gpu_host_only`).
   - `-Dgpu-lanes=false` keeps CI's kernel build as it is today.
   - Host side: one more `Sim` instantiation (`GpuLanes.Ops`), small.
9. **AMD `globalIdX(block)`**: HIP bakes the block width into `globalIdX`.
   Every lane kernel uses `block = 64`, both exported and launched with it.
   Never use `evalBlock`'s knob for lane kernels.

## 5. Effort

| Step | Work | Effort |
|---|---|---|
| G0 | `gpu_host_only` emptied, test-gpu on CUDA | 0.5 d (+ CI time) |
| G1 | `Sim` over `Ops`, `HostOps`, corpus gate | 2 d |
| G2 | frame/spill experiment matrix and decision | 3-4 d (GPU box; parallel to G3-G6) |
| G3 | `LaneSink`, four lane kernels, exports, abi 31, `-Dgpu-lanes` | 2.5 d |
| G4 | `lane_kernels.zig` bodies + host oracle tests | 4 d |
| G5 | `lane_device.zig` root, build root | 1 d |
| G6 | `gpu_lanes.zig`: pack, buffers, tab, Newton graphs, peel, probe, apply, `Ops` | 7-9 d |
| G7 | `runGpuLanes`, eligibility | 1.5 d |
| G8 | policy, breadth-first, `gatherWide`, `executeGpuBatch` | 2 d |
| G9 | GPU parity runner mode, GPU lockstep test, throughput run | 4 d |
| | **Total** | **≈ 28-31 d (5.5-6 weeks)**, inside §11's 4-6 weeks; G2 overlaps |

Critical path: G1 → G3/G4 (parallel) → G5 → G6 → G7 → G8 → G9. G6 is the long
pole. Its first milestone is "Newton only": N lanes of one fixed step, compared
against `newtonLanes` on the CPU, before probe and apply are written.
