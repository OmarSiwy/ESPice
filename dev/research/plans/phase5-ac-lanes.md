# Phase 5 plan: AC family over (point, ω) lanes (#209)

Base: main 06cff37f. Lands after phase 3 (#207: the `.tran` branch of
`Executor.executeBatch` and `sameLaneJob`) and is written against the tree
as it is now; where phase 3 touched the same lines, merge both arms. The GPU
half (steps 6-7 and the provider in "GPU hook") needs phase 4 (#208).

## 1. Design

### What the CPU can and cannot gain

- `FreqSolver.solveBatch` already fills the CPU's W lanes with ω of one
  point (`freq_solve.zig:356`). A (point, ω) lane on the CPU fills the same
  vector with the same work, so the CPU gains nothing (§11, the issue).
- A point's AC output depends on its own solver history:
  - the tape laid at the centre ω of its first chunk (`freq_solve.zig:392`);
  - every serial re-factor a failed lane makes (`:433`), which re-pivots
    the tape the next chunk replays.
- Mixing points inside one `LaneLu(W)` pass changes that history, so it is
  not bitwise its solo run. The §11 gate is byte-identical batched vs
  `--jobs=1`.
- Decision: on the CPU every lane keeps its own `FreqSolver` and its own
  chunk sequence. The batch only changes when a sweep is solved, never how.
  The (point, ω) axis exists only on the device, where each lane replays its
  own point's tape and the host keeps each point's chunk control. That is
  the same split as phase 3 (host control, backend middle) and phase 4
  (lane = thread, host decisions).

### Control inversion: precompute, then replay

- Every AC-family analysis drives its sweep as `while (try stream.next(ckt))`
  inside its own `run`, interleaved with per-point readout. Batching W or N
  points' solves together means inverting that loop, and Zig has no
  coroutines.
- Lazy answer: solve a lane's leading sweep up front into a buffer
  (`freq.solveAll`, which is the same `Stream` drained), then run the
  analysis with `Stream.pre` set so `next` reads the buffer instead of
  solving.
- Bitwise by construction: the precompute is the same `Stream` on the same
  `FreqSolver` inputs (same G/C from `linearizeAc` at the same x_op and sim
  state, same chunks, same `acDyn` terms). freq.zig:41 already states that
  chunking cannot change a bit.
- The CPU runs the precompute per lane. The GPU lane backend replaces only
  the precompute loop (`Executor.runFreqLanes`) with (point, ω) rounds.
  Everything after it stays host code, per lane.

### Which kinds ride the precompute

| Kind | Leading sweep | Lane treatment |
|---|---|---|
| `.ac` | one `Stream`, forward, `ac_drive` | precompute + replay |
| `.acxf` | one `Stream`, forward per source or one adjoint (`tf_only`) | precompute + replay |
| `.stb` | one `Stream`, forward, probe branch | precompute + replay |
| `.noise` | main `sweep` `Stream`, adjoint | precompute + replay; the `sample` re-sweep (noise.zig:251) stays live |
| `.sp` | several `Stream`s on one solver, `addDiagG` between | class E: per-lane `run` |
| `.lstb` | regula falsi probes, single-lane `solveBatch` | class B on paper; per-lane `run` (each lane its own bracket, which is today's code) |
| `.acmatch` | two `Stream`s on one solver, then FD | per-lane `run` |
| `.tf`, `.dcxf`, `.dcinc`, `.sens`, `.dcmatch`, `.dcsens` | real DC factor at the OP, FD | per-lane `run` (class A/E at W = 1) |

- Per-lane `run` for the class A/E rows is the §6 peel to W = 1. On the
  CPU it is the only bitwise option. On the GPU the cost is one host factor
  per lane, small next to the OP the lanes just shared.
- Not laned here: `.pz` (phase 6 decision), the periodic small-signal kinds
  (phase 6), `factorEach` (MHB/PAC, phase 6).

### Grouping and execution

- `executor.freqLaneKind(kind)` names the kinds above.
- `Session.gather` accepts them.
- `sameLaneJob` compares their options minus `tol.variant`/`tol.temp_c`,
  as for `.op`/`.dc`.
- `Executor.executeBatch` gains one branch, `runFreqLanes`:
  - set every live lane's sim state as `runQuery` does (`.ac` or
    `.noise`, else `.dc`);
  - precompute every live lane's leading sweep;
  - then run each lane's analysis on its own buffer and label it.
- A lane whose precompute fails (singular centre on the serial path,
  out of memory, a cancel) runs live, so it fails, streams partial rows or
  cancels exactly as alone.
- ponytail ceiling: the precompute holds points × ω × rhs values per lane.
  On the CPU, batching also puts W AC queries on one worker (lanes are off
  by default on the CPU, #211). The GPU provider is the reason this exists.

### GPU shape (served by phase 4)

- Lane = (point p, ω index k), lanes innermost: element (i, l) at
  `i * N + l`.
- Round r processes chunk r (W ω, the CPU's chunk width, so each point's
  decision timeline is the CPU oracle's) of every point. On the host, per
  point:
  - `chunkTape`: a scalar centre factor when the point has no current tape
    (needs that point's G/C on the host: download its planes when needed);
  - group the lanes by tape (`LaneSolver.sameTape`'s test across points);
  - launch the lane complex-replay kernel: `LaneLu` restated over `P(T)`,
    thread = lane, with the fill from `StackedPoints` (step 7);
  - download the solutions and the bad mask;
  - `chunkPeel` on the host for the bad lanes, in lane order per point.
- G/C per lane are the planes the OP lane batch leaves after an `.ac`-kind
  lane eval at x_op (phase 4's resident lane eval).
- Decks with `acDyn` devices (`ac_dyn_slots` non-empty) take the per-point
  path: `StackedPoints` carries no `Dyn`.

## 2. Edits, in dependency order

### Step 1. freq.zig: `Stream.pre`, `Plan`, `solveAll`

`src/analysis/ac/freq.zig`.

**1a. `Stream` field (after `adjoint: bool,`, :50):**

```zig
    /// Every point's solutions solved up front by `solveAll` on these same
    /// inputs, `omegas.len * rhs.len` values point-major; `next` then reads
    /// them instead of solving. Empty: solve as it goes.
    pre: []const f64 = &.{},
```

**1b. `Stream.next` (:78-96), replacing the body:**

```zig
    pub fn next(self: *Stream, ckt: *root.Circuit) !?Point {
        const m = self.rhs.len;
        if (self.k == self.end) {
            if (self.end == self.omegas.len) return null;
            self.base = self.end;
            self.end += @min(lanes, self.omegas.len - self.base);
            if (self.pre.len == 0) {
                const chunk = self.omegas[self.base..self.end];
                const terms = ckt.ac_dyn_slots.len * chunk.len;
                const re = self.dyn[0..terms];
                const im = self.dyn[self.dyn.len / 2 ..][0..terms];
                if (terms != 0) ckt.acDyn(self.x_op, chunk, re, im);
                const dyn: Dyn = .{ .slots = ckt.ac_dyn_slots, .re = re, .im = im };
                try self.fs.solveBatch(chunk, dyn, self.rhs, self.buf[0 .. chunk.len * m], self.adjoint);
            }
            if (self.end % quantum == 0 or self.end == self.omegas.len)
                try ckt.checkpoint(.{ .phase = .frequency, .completed = self.end, .total = self.omegas.len });
        }
        defer self.k += 1;
        const x = if (self.pre.len != 0) self.pre[self.k * m ..][0..m] else self.buf[(self.k - self.base) * m ..][0..m];
        return .{ .k = self.k, .x = x };
    }
```

**1c. After `freeAxis` (:23), add:**

```zig
/// One frequency analysis' leading sweep: what its `Stream` solves. Built
/// by the analysis' `plan`; `deinit` returns the axis block and `rhs` to
/// the scratch allocator that built them.
pub const Plan = struct {
    freqs: []f64,
    omegas: []f64,
    rhs: []f64,
    adjoint: bool,

    pub fn deinit(p: Plan, scratch: std.mem.Allocator) void {
        freeAxis(scratch, p.freqs);
        scratch.free(p.rhs);
    }
};

/// Solves every point of a `Stream` over these inputs into `out`
/// (`omegas.len * rhs.len` values, point-major), bitwise what that stream
/// returns point by point: the precompute behind `Stream.pre`. Checkpoints
/// as the stream does. Asserts that `out` has that length.
pub fn solveAll(allocator: std.mem.Allocator, fs: *FreqSolver, ckt: *root.Circuit, x_op: []const f64, omegas: []const f64, rhs: []const f64, adjoint: bool, out: []f64) !void {
    std.debug.assert(out.len == omegas.len * rhs.len);
    var s = try Stream.init(allocator, fs, ckt, x_op, omegas, rhs, adjoint);
    defer s.deinit(allocator);
    while (try s.next(ckt)) |pt| @memcpy(out[pt.k * rhs.len ..][0..rhs.len], pt.x);
}
```

### Step 2. `RunCtx.freq_pre`

`src/analysis/types.zig`, `RunCtx` (:53), after `measures` (:83):

```zig
    /// The leading frequency sweep's solutions, solved up front by a lane
    /// batch (`Executor.runFreqLanes`) as `freq.solveAll` lays them out;
    /// `.ac`, `.acxf`, `.stb` and `.noise` replay them (`freq.Stream.pre`).
    /// Empty: solve live.
    freq_pre: []const f64 = &.{},
```

### Step 3. A `plan` per precomputed kind, used by its own `run`

Each `run` builds its sweep inputs through `plan`, so the precompute cannot
drift from the live sweep.

**3a. `src/analysis/ac/ac.zig`.** Add after `Options` (:15):

```zig
/// The sweep `run` solves: `ctx.ac_drive` (or zero) at every ω of `opts`.
/// Asserts that `ctx.ac_drive` is 2n long or empty.
pub fn plan(ctx: *const root.RunCtx, opts: Options) !freq.Plan {
    const scratch = ctx.scratch_allocator;
    const nn = 2 * @as(usize, ctx.circuit.n);
    std.debug.assert(ctx.ac_drive.len == nn or ctx.ac_drive.len == 0);
    const rhs = try scratch.alloc(f64, nn);
    errdefer scratch.free(rhs);
    if (ctx.ac_drive.len == nn) @memcpy(rhs, ctx.ac_drive) else @memset(rhs, 0);
    const freqs, const omegas = try freq.axis(scratch, opts.sweep);
    return .{ .freqs = freqs, .omegas = omegas, .rhs = rhs, .adjoint = false };
}
```

Then replace `run`'s lines :34 (`std.debug.assert(...)`) and :39-44 (the
`rhs` and `axis` blocks) with:

```zig
    const p = try plan(ctx, opts);
    defer p.deinit(scratch);
    const rhs = p.rhs;
    const freqs = p.freqs;
    const omegas = p.omegas;
```

Keep `var fs = try FreqSolver.fromCircuit(...)` (:36) above it. After
`var stream = try freq.Stream.init(...)` (:55), add:

```zig
    stream.pre = ctx.freq_pre;
```

`nn` (:32) stays, because `run` still reads it for the row width.

**3b. `src/analysis/ac/xf.zig`.** Add after `Options` (:10):

```zig
/// The sweep `run` solves: one adjoint right-hand side (`tf_only`) or one
/// forward drive per source, at every ω of `opts`.
pub fn plan(ctx: *const root.RunCtx, opts: Options) !freq.Plan {
    const scratch = ctx.scratch_allocator;
    const n: usize = ctx.circuit.n;
    const out: dcxf.Output = .{ .node = opts.output_node, .neg = opts.output_neg, .branch = opts.output_branch };
    const n_rhs: usize = if (opts.tf_only) 1 else opts.sources.len;
    const rhs = try scratch.alloc(f64, @max(n_rhs, 1) * 2 * n);
    errdefer scratch.free(rhs);
    @memset(rhs, 0);
    if (opts.tf_only) out.seed(rhs) else for (opts.sources, 0..) |s, i| dcxf.excite(s, rhs[i * 2 * n ..]);
    const freqs, const omegas = try freq.axis(scratch, opts.sweep);
    return .{ .freqs = freqs, .omegas = omegas, .rhs = rhs, .adjoint = opts.tf_only };
}
```

In `run`:
- replace :29-37 (`n_points` through the `rhs` seeding) with:

  ```zig
      const n_points: usize = opts.sweep.count();
      const p = try plan(ctx, opts);
      defer p.deinit(scratch);
      const freqs = p.freqs;
      const omegas = p.omegas;
      const rhs = p.rhs;
  ```

- keep `out` (:24), which the readout uses;
- after the `Stream.init` (:44), add `stream.pre = ctx.freq_pre;`.

**3c. `src/analysis/ac/stb.zig`.** Add after `Options` (:10):

```zig
/// The sweep `run` solves: a unit injection on the probe's branch row.
/// Fails with error.InvalidProbe as `run` does, before allocating.
pub fn plan(ctx: *const root.RunCtx, opts: Options) !freq.Plan {
    const scratch = ctx.scratch_allocator;
    const n: usize = ctx.circuit.n;
    if (opts.probe_branch >= n or opts.probe_p >= n or opts.probe_n >= n)
        return error.InvalidProbe;
    if (opts.probe_n == root.GROUND) return error.InvalidProbe;
    const rhs = try scratch.alloc(f64, 2 * n);
    errdefer scratch.free(rhs);
    @memset(rhs, 0);
    rhs[opts.probe_branch] = 1.0;
    const freqs, const omegas = try freq.axis(scratch, opts.sweep);
    return .{ .freqs = freqs, .omegas = omegas, .rhs = rhs, .adjoint = false };
}
```

In `run`:
- replace the probe checks (:29-31) and the `rhs`/`axis` blocks (:36-43)
  with:

  ```zig
      const p = try plan(ctx, opts);
      defer p.deinit(scratch);
      const freqs = p.freqs;
      const omegas = p.omegas;
      const rhs = p.rhs;
  ```

- place that before `fs` (:33), so the probe refusal still precedes any
  eval;
- after `Stream.init` (:50), add `stream.pre = ctx.freq_pre;`.

**3d. `src/analysis/ac/noise.zig`.**
- `sweep` (:94): add a last parameter `pre: []const f64`.
- After `var stream = try freq.Stream.init(...)` (:126), add
  `stream.pre = pre;`.
- Call sites: :251 passes `&.{}` (the sampled re-sweep is never
  precomputed); :307 passes `ctx.freq_pre`.
- Add after `Options`:

```zig
/// The main sweep `run` solves (`sweep`'s adjoint stream): the output's
/// unit adjoint drive at every ω of `opts`. The sampled re-sweep is not
/// part of it.
pub fn plan(ctx: *const root.RunCtx, opts: Options) !freq.Plan {
    const scratch = ctx.scratch_allocator;
    const rhs = try scratch.alloc(f64, 2 * @as(usize, ctx.circuit.n));
    errdefer scratch.free(rhs);
    root.outputDrive(rhs, opts.out_node, opts.out_neg);
    const freqs, const omegas = try freq.axis(scratch, opts.sweep);
    return .{ .freqs = freqs, .omegas = omegas, .rhs = rhs, .adjoint = true };
}
```

- CHECK: `sweep`'s own ω come from `options.sweep.fill(freqs, omegas)`
  (:116), and `freq.axis` calls the same `fill`. Confirm that `fill` is
  pure in its inputs, so both give the same bits.
- CHECK: that `outputDrive` overwrites all 2n entries. If it only writes
  the two rows, add `@memset(rhs, 0)` before it, as `sweep`'s `e`
  allocation (:121-123) must then do too.

### Step 4. Executor: `freqLaneKind`, `simKind`, `runFreqLanes`

`src/analysis/executor.zig`.

**4a. After `lanesOn` (:100), add:**

```zig
/// The AC-family kinds a lane batch runs (`runFreqLanes`): small-signal
/// analyses at their own operating point, each lane bitwise its query run
/// alone (lane-batched-simulation.md §6, the AC family rows).
pub fn freqLaneKind(kind: requests.Kind) bool {
    return switch (kind) {
        .ac, .noise, .sp, .stb, .lstb, .acxf, .tf, .dcxf, .dcinc, .sens, .dcmatch, .dcsens, .acmatch => true,
        else => false,
    };
}

/// The analysis state a query's devices see while it runs (`runQuery`).
/// Small-signal linearizations run as analysis("ac") or ("noise"), LRM
/// Table 4-22, as ngspice's MODEINITSMSIG load sets ANALYSIS_AC for ac,
/// noise, pz and disto (osdiload.c:165).
fn simKind(job: requests.Query) SimKind {
    const transient = if (job == .op) job.op.tran_op else @as(requests.Kind, job).transient();
    return switch (job) {
        .ac, .sp, .stb, .pz, .disto, .lstb, .acxf => .ac,
        .noise => .noise,
        else => if (transient) .ic else .dc,
    };
}

const SimKind = @FieldType(@import("device").abi.SimState, "kind");
```

CHECK: the `device` module path to `SimState` (gpu.zig:16 uses
`@import("device").abi`).

**4b. `runQuery` (:444-457).** Replace the `transient` line and the
`setSimState` switch with:

```zig
        self.circuit.setSimState(.{ .kind = simKind(self.job) });
```

`transient` is still read below (:462), so keep it:

```zig
        const transient = if (self.job == .op) self.job.op.tran_op else @as(requests.Kind, self.job).transient();
```

Keep the LRM comment above `simKind`, not here.

**4c. `executeBatch` (:312).**
- Replace the assert (:314) with:

  ```zig
          std.debug.assert(g <= lane_width and (self.job == .op or self.job == .dc or freqLaneKind(self.job)));
  ```

  Phase 3 adds `.tran` to it.
- After the `sayNames` early return (:336-339), before
  `if (self.job == .dc)`, add:

  ```zig
          if (freqLaneKind(self.job)) {
              runFreqLanes(members[0..g], live[0..n_live], outcomes[0..g]);
              return outcomes[0];
          }
  ```

**4d. New functions, after `finishAlone` (:399):**

```zig
    /// `executeBatch`'s AC-family branch: every live lane's leading
    /// frequency sweep solved up front (`precompute`), then each lane's
    /// analysis replaying it (`RunCtx.freq_pre`) and labelled as alone. The
    /// two passes are the GPU lane backend's shape: it replaces the first
    /// with (point, ω) lane rounds (dev/research/plans/phase5-ac-lanes.md).
    /// A lane whose precompute fails runs live, so it fails or streams as
    /// it would alone.
    // ponytail: holds points·ω·rhs values per lane until its run ends;
    // chunk the precompute if a long sweep on a large n needs it.
    fn runFreqLanes(members: []const *Executor, live: []const usize, outcomes: []QueryError!types.Result) void {
        var ctxs: [lane_width]types.RunCtx = undefined;
        for (live, 0..) |k, l| {
            const e = members[k];
            e.circuit.setSimState(.{ .kind = simKind(e.job) });
            ctxs[l] = e.runCtx();
            ctxs[l].freq_pre = e.precompute(&ctxs[l]) catch &.{};
        }
        for (live, 0..) |k, l| {
            const e = members[k];
            outcomes[k] = if (run(&ctxs[l], e.job)) |r| e.label(r) else |err| err;
            e.refuseLatched() catch |err| {
                outcomes[k] = err;
            };
        }
    }

    /// The query's leading frequency sweep, solved as its own `run` would
    /// solve it (`freq.solveAll` over its `plan`), in the query's work
    /// arena; empty for a kind that solves live.
    fn precompute(self: *Executor, ctx: *const types.RunCtx) ![]const f64 {
        const freq = @import("ac/freq.zig");
        const scratch = ctx.scratch_allocator;
        const p: freq.Plan = switch (self.job) {
            .ac => |o| try @import("ac/ac.zig").plan(ctx, o),
            .acxf => |o| try @import("ac/xf.zig").plan(ctx, o),
            .stb => |o| try @import("ac/stb.zig").plan(ctx, o),
            .noise => |o| try @import("ac/noise.zig").plan(ctx, o),
            else => return &.{}, // else: every other kind solves live (class E)
        };
        defer p.deinit(scratch);
        var fs = try @import("solver").freq_solve.FreqSolver.fromCircuit(scratch, ctx.circuit, ctx.x_op);
        defer fs.deinit();
        const out = try self.work.allocator().alloc(f64, p.omegas.len * p.rhs.len);
        try freq.solveAll(scratch, &fs, ctx.circuit, ctx.x_op, p.omegas, p.rhs, p.adjoint, out);
        return out;
    }
```

- Notes:
  - `run` here is the file-level dispatcher (:682), not a method.
  - `QueryError` already includes `types.ErrorOf(run)`.
- CHECK: that `executor.zig` may import `solver` (build.zig's
  `restricted_imports` allow `solver` under `src/analysis/`, so it may).
- CHECK: a `.noise` deck whose sweep is a `dec` grid with `sample` also
  calls `sweep` for the sampled grid (noise.zig:251). That stays live and
  is unaffected.

### Step 5. Session: group the AC family

`src/analysis/session.zig`.

**5a. `gather` (:478).** Replace

```zig
        if ((jobs[i] != .op and jobs[i] != .dc) or self.rows.items(.executor)[i] != null) return;
```

with

```zig
        const laned = jobs[i] == .op or jobs[i] == .dc or execution.freqLaneKind(jobs[i]);
        if (!laned or self.rows.items(.executor)[i] != null) return;
```

Phase 3 adds `.tran` to `laned`. Update `gather`'s doc (:464): "`.op`,
`.dc` or AC-family row".

**5b. `sameLaneJob` (:1022).**

```zig
fn sameLaneJob(a: requests.Query, b: requests.Query) bool {
    return switch (a) {
        inline .op, .dc, .ac, .noise, .sp, .stb, .lstb, .acxf, .tf, .dcxf, .dcinc, .sens, .dcmatch, .dcsens, .acmatch => |o, tag| b == tag and sameDeep(stripTol(o), stripTol(@field(b, @tagName(tag)))),
        else => false,
    };
}
```

- CHECK: `sameDeep` must compile over every option type here. Watch
  `Noise.card_names` (`CardNames`), `Sp.lin`, `Acxf.sources` and
  `Lstb.Probe`. Its `else => a == b` arm is a compile error for a type
  without `==` (a struct inside an optional is fine; the struct arm
  recurses). If one fails, give that field a case or compare it by
  `std.meta.eql`.
- The kind list must equal `freqLaneKind`'s. A `comptime` loop over
  `std.meta.tags(requests.Kind)` asserting
  `freqLaneKind(k) == (sameLaneJob arm exists)` is not expressible cheaply,
  so keep the two lists adjacent in review.

### Step 6. GPU seam in `solveBatch`: chunk head and tail (code motion)

Needed by phase 4's AC provider. If phase 4 is not scheduled, skip it.
`src/solver/freq_solve.zig`.

**6a. Imports (:16).** Add:

```zig
const SparseLu = @import("sparse_lu.zig").SparseLu;
```

**6b. In `solveBatch` (:378-435).**
- Replace the block from `if (!sp.slv.factored) setOmegaSparse(...)` (:392)
  through `const lu = sp.slv.sparse() orelse {...};` (:400-403) with:

  ```zig
              const lu = (try self.chunkTape(sp, omegas, dyn, base, cnt, rhs, x_out, adjoint)) orelse continue;
  ```

- Replace the trailing peel loop (:433-434) with:

  ```zig
              try self.chunkPeel(omegas, dyn, base, cnt, bad, rhs, x_out, adjoint);
  ```

**6c. New methods after `solveBatch`:**

```zig
    /// `solveBatch`'s chunk head: the pivot tape lanes `[base, base + cnt)`
    /// replay, laid by a scalar factor at the chunk's centre ω when none is
    /// current. Null when the chunk took the serial path instead (a
    /// singular centre or a non-LU engine), its rows of `x_out` written. An
    /// allocation failure is the caller's, not a numerical one (#83). The
    /// GPU lane backend runs it per point per round.
    fn chunkTape(self: *Self, sp: *Sparse, omegas: []const f64, dyn: Dyn, base: usize, cnt: usize, rhs: []const f64, x_out: []f64, adjoint: bool) !?*SparseLu {
        const centre = base + cnt / 2;
        if (!sp.slv.factored) setOmegaSparse(self.n, sp, omegas[centre], dyn, centre) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => { // else: a numerical factor failure takes the serial path
                try self.solveBatchSerial(omegas, dyn, base, cnt, rhs, x_out, adjoint);
                return null;
            },
        };
        // LaneLu replays SparseLu only, not the tridiagonal engine.
        return sp.slv.sparse() orelse {
            try self.solveBatchSerial(omegas, dyn, base, cnt, rhs, x_out, adjoint);
            return null;
        };
    }

    /// `solveBatch`'s chunk tail: each lane `bad` marks solves on the serial
    /// path, in lane order, after every lane solve: a failed lane's full
    /// factor may repivot the tape the next chunk replays.
    fn chunkPeel(self: *Self, omegas: []const f64, dyn: Dyn, base: usize, cnt: usize, bad: u64, rhs: []const f64, x_out: []f64, adjoint: bool) !void {
        for (0..cnt) |l| if ((bad & (@as(u64, 1) << @intCast(l))) != 0)
            try self.solveBatchSerial(omegas, dyn, base + l, 1, rhs, x_out, adjoint);
    }
```

- `ow[cnt / 2]` was `omegas[base + min(cnt/2, cnt - 1)]`, which is
  `omegas[base + cnt/2]` for every cnt ≥ 1. The centre is unchanged.
- Phase 4 makes the two methods `pub`, with a `*Self`-only signature that
  switches on `strategy` inside, when its provider calls them.

### Step 7. `StackedPoints`: the host oracle of the (point, ω) fill

`src/solver/freq_solve.zig`, after `Stacked` (:847).

```zig
/// `Stacked` over lanes from several points on one stacked pattern: lane l
/// fills from `g[l]`/`c[l]`, one point's source-slot G and C snapshot, at
/// `omega[l]`. Same products, in the same order per entry, as `Stacked`,
/// so lane l is bitwise `Stacked(1)` of its own point. No `Dyn`: a deck
/// with `acDyn` terms solves per point. The host oracle of the GPU lane
/// backend's (point, ω) fill (phase 4); every point must share the pattern
/// `src_col_ptr`/`col_ptr`.
pub fn StackedPoints(comptime L: usize) type {
    return struct {
        const V = @Vector(L, f64);
        src_col_ptr: []const u32,
        col_ptr: []const u32,
        g: [L][]const f64,
        c: [L][]const f64,
        omega: V,

        /// Stacked column `col` per lane, as `Stacked.load`.
        pub inline fn load(s: @This(), col: usize, w: []V, prow: []const u32) void {
            const n = s.src_col_ptr.len - 1;
            const top = col < n;
            const j = if (top) col else col - n;
            const cs = s.src_col_ptr[j];
            const len: usize = s.src_col_ptr[j + 1] - cs;
            const rows = prow[s.col_ptr[col]..][0 .. 2 * len];
            for (0..len) |i| {
                var ga: [L]f64 = undefined;
                var ca: [L]f64 = undefined;
                for (0..L) |l| {
                    ga[l] = s.g[l][cs + i];
                    ca[l] = s.c[l][cs + i];
                }
                const gv: V = ga;
                const cv: V = ca;
                if (top) {
                    w[rows[i]] = gv;
                    w[rows[len + i]] = s.omega * cv;
                } else {
                    w[rows[i]] = -s.omega * cv;
                    w[rows[len + i]] = gv;
                }
            }
        }
    };
}
```

`Stacked` writes `(-ω) * c` as `neg * @splat(v)` with `neg = -s.omega`.
`-s.omega * cv` parses as `(-s.omega) * cv`, the same product.

## 3. W = 1 identity and codegen probes

- No scalar arithmetic becomes generic over W in this phase:
  - `Stream.next` gains a branch on `pre.len`, and the live path is the old
    body verbatim;
  - `chunkTape`/`chunkPeel` are code motion;
  - `StackedPoints` is new code that no scalar path calls.
- So, per the phase 3 rule, no `gen_`/`hand_` probe is added.
- The identity gates:
  1. The whole corpus at `ESPICE_LANES=0` is byte-identical to main (the
     plan/`run` refactor).
  2. `ESPICE_LANES=1` vs `0` is byte-identical on every swept AC deck
     (§4).
  3. A ReleaseFast wall time on `tests/benchmark` AC decks within noise of
     main. `Stream.next`'s new branch is per chunk, not per point.
- If review wants proof that the `next` refactor is free, the cheap probe
  is `gen_stream_next`/`hand_stream_next` over a stand-in `FreqSolver`.
  It is not worth its harness: `freq.zig` imports `root` (the analysis
  `Circuit`), which `tests/codegen.zig` cannot link without the device
  graph.

## 4. Tests

### 4a. Unit: the (point, ω) fill oracle (step 7)

`src/solver/freq_solve.zig`, after the existing tests:

```zig
test "StackedPoints: lane (point, ω) is bitwise Stacked(1) of its own point on the shared tape" {
    const gpa = testing.allocator;
    const n: u32 = 20; // above dense_threshold: the sparse strategy
    const a: Ring = .init(n, 1e-3);
    var b: Ring = .init(n, 3e-3);
    for (b.g[0..a.col_ptr[n]]) |*v| v.* *= 1.05;
    const nnz = a.col_ptr[n];
    var fa = try FreqSolver.fromPlanes(gpa, n, a.col_ptr[0 .. n + 1], a.row_idx[0..nnz], a.g[0..nnz], a.c[0..nnz]);
    defer fa.deinit();
    var fb = try FreqSolver.fromPlanes(gpa, n, b.col_ptr[0 .. n + 1], b.row_idx[0..nnz], b.g[0..nnz], b.c[0..nnz]);
    defer fb.deinit();
    // Lay point a's tape at 1e4 rad/s; point b replays it.
    try FreqSolver.test_access.setOmega(&fa, 1e4);
    const spa = &fa.strategy.sp;
    const spb = &fb.strategy.sp;
    const lu = spa.slv.sparse().?;
    const L = 4;
    var lanes = try lane_lu.LaneLu(L).init(gpa, lu);
    defer lanes.deinit(gpa);
    const omegas = [L]f64{ 1e2, 1e2, 1e6, 1e6 };
    const src: StackedPoints(L) = .{
        .src_col_ptr = spa.src_col_ptr,
        .col_ptr = spa.col_ptr,
        .g = .{ spa.g_vals, spb.g_vals, spa.g_vals, spb.g_vals },
        .c = .{ spa.c_vals, spb.c_vals, spa.c_vals, spb.c_vals },
        .omega = omegas,
    };
    const bad = lanes.refactor(src, spa.slv.params.refactor_growth_limit);
    const nn: usize = 2 * n;
    const bv = try gpa.alloc(@Vector(L, f64), 2 * nn);
    defer gpa.free(bv);
    for (bv[0..nn], 0..) |*v, i| v.* = @splat(@as(f64, @floatFromInt(i % 3)) - 1);
    lanes.solve(bv[0..nn], bv[nn..]);
    var one = try lane_lu.LaneLu(1).init(gpa, lu);
    defer one.deinit(gpa);
    const b1 = try gpa.alloc(@Vector(1, f64), 2 * nn);
    defer gpa.free(b1);
    for (0..L) |l| {
        const sp = if (l % 2 == 0) spa else spb;
        const want_bad = one.refactor(Stacked(1).of(sp, @as(@Vector(1, f64), @splat(omegas[l])), .{}, 0, 1), spa.slv.params.refactor_growth_limit);
        try testing.expectEqual(want_bad != 0, (bad >> @intCast(l)) & 1 != 0);
        if (want_bad != 0) continue;
        for (b1[0..nn], 0..) |*v, i| v.* = @splat(@as(f64, @floatFromInt(i % 3)) - 1);
        one.solve(b1[0..nn], b1[nn..]);
        for (bv[nn..], b1[nn..]) |got, want| {
            const g: [L]f64 = got;
            const w: [1]f64 = want;
            try testing.expectEqual(@as(u64, @bitCast(w[0])), @as(u64, @bitCast(g[l])));
        }
    }
}
```

- `Ring` (:927) takes n ≤ 24; n = 20 is past `dense_threshold`, so
  `fromPlanes` gives the sparse strategy.
- CHECK: `test_access.setOmega`'s receiver form. It is a method, so call
  `FreqSolver.test_access.setOmega(&fa, 1e4)`.
- CHECK: `fa.strategy.sp` (the test is in-file, so the private field is
  reachable).

### 4b. Session: AC-family lanes bitwise alone, mixed and replicated

`src/analysis/tests/session.zig`, after the NaN/peel test (:618):

```zig
test "lane batches: AC-family rows on variant rows equal their runs alone, bitwise, with failing and replicated lanes" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 2 }, &.{}, .{ vin, GROUND });
    var prev = vin;
    for (0..4) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, mid });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-9 }, &.{}, .{ mid, GROUND });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14, .cjo = 1e-12 }, &.{}, .{ mid, GROUND });
        prev = mid;
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    // Variant k writes the first resistor's `r`.
    var probe = try @import("../types.zig").Circuit.instantiate(&prepared, t.allocator);
    defer probe.deinit();
    const params = try probe.collectParams();
    const r_ref: u32 = for (params, 0..) |p, k| {
        if (p.type == builtin("resistor") and p.index == 0 and std.mem.eql(u8, p.param_name, "r")) break @intCast(k);
    } else return error.TestUnexpectedResult;
    // Rows 0, 2, 5 and 8 replicate one point; 4 cannot solve its OP.
    const values = [_]f64{ 1e3, 2e3, 1e3, 5e2, std.math.nan(f64), 1e3, 7e3, 3e2, 1e3, 1e4 };
    var labels: [values.len][]const u8 = undefined;
    var starts: [values.len + 1]u32 = undefined;
    var refs: [values.len]u32 = undefined;
    var temps: [values.len]?f64 = undefined;
    for (&labels, starts[0..values.len], &refs, &temps, 0..) |*l, *s0, *r, *tc, k| {
        l.* = "r";
        s0.* = @intCast(k);
        r.* = r_ref;
        tc.* = null;
    }
    starts[values.len] = values.len;
    const drive = try t.allocator.alloc(f64, 2 * @as(usize, prepared.n));
    defer t.allocator.free(drive);
    @memset(drive, 0);
    drive[prev] = 1e-3;
    var deck = bareDeck(&.{ vin, prev }, &.{ "v(in)", "v(out)" });
    deck.ac_drive = drive;
    deck.variants = .{ .labels = &labels, .temp_c = &temps, .starts = &starts, .refs = &refs, .values = &values };
    deck.cards = &.{.{ .type = builtin("vsource"), .index = 0, .name = "v1" }};
    const sweep: requests.FreqSweep = .{ .f_start = 1e3, .f_stop = 1e9 };
    var jobs: [2 * values.len]requests.Query = undefined;
    for (jobs[0..values.len], jobs[values.len..], 0..) |*ac, *nz, k| {
        ac.* = .{ .ac = .{ .sweep = sweep, .tol = .{ .variant = @intCast(k) } } };
        nz.* = .{ .noise = .{ .out_node = prev, .sweep = sweep, .tol = .{ .variant = @intCast(k) } } };
    }
    const Row = struct { status: Status, failure: ?@import("../session.zig").Failure, data: []f64 };
    var rows: [2][jobs.len]Row = undefined;
    var ac_batched: usize = 0;
    for ([_]bool{ false, true }, &rows) |lanes, *out| {
        var config: @import("../executor.zig").Config = .{};
        config.knobs.lanes = lanes;
        var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
        defer s.deinit();
        var ids: [jobs.len]requests.QueryId = undefined;
        _ = try s.append(&jobs, &ids);
        try s.runAll(.{ .max_parallel = 1, .quantum = .completion });
        for (s.rows.items(.executor), s.rows.items(.job)) |e, j| if (e) |x| {
            if (j == .ac or j == .noise) ac_batched += x.peers.len;
        };
        for (ids, out) |id, *r| {
            const q = try s.info(id);
            r.* = .{ .status = q.status, .failure = q.failure, .data = &.{} };
            if (q.status == .complete) r.data = try t.allocator.dupe(f64, (try s.result(id)).data);
        }
    }
    defer for (rows) |rs| for (rs) |r| t.allocator.free(r.data);
    try t.expect(ac_batched > 0);
    for (rows[0], rows[1]) |a, c| {
        try t.expectEqual(a.status, c.status);
        try t.expectEqual(a.failure, c.failure);
        try t.expectEqualSlices(u64, @ptrCast(a.data), @ptrCast(c.data));
    }
    // Replication: one point in four lanes, bitwise four times.
    for ([_]usize{ 0, values.len }) |off| for ([_]usize{ 2, 5, 8 }) |k| {
        try t.expectEqualSlices(u64, @ptrCast(rows[1][off].data), @ptrCast(rows[1][off + k].data));
    };
    // The NaN row fails, alone and batched.
    try t.expect(rows[1][4].status != .complete);
}
```

- CHECK: `requests.FreqSweep` is re-exported at core/query.zig:20.
- CHECK: the name `Failure` and `s.info`'s fields, as in the existing NaN
  test.

### 4c. Facade: a `.step` deck, every AC-family point under `--lanes`

`src/tests/espice.zig`, after the #212 test (:1729):

```zig
const ac_lane_deck =
    \\* AC-family lanes (#209): .ac, .noise and .tf of a diode-loaded RC
    \\* stepped over rl; points 0, 2, 4 and 6 repeat rl = 1k.
    \\.param rl=1k
    \\v1 in 0 dc 1 ac 1
    \\r1 in mid {rl}
    \\c1 mid 0 1n
    \\d1 mid out dmod
    \\r2 out 0 2k
    \\c2 out 0 0.5n
    \\.model dmod d is=1e-14 cjo=1p
    \\.step param rl list 1k 2k 1k 500 1k 3k 1k 700
    \\.ac dec 10 1k 1g
    \\.noise v(out) v1 dec 10 1k 1g
    \\.tf v(out) v1
    \\.end
    \\
;

/// Each requested query's data, in request order, per kind.
fn acLaneRun(lanes: bool) !std.ArrayList([]f64) {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = ac_lane_deck, .origin = "ac_lanes.sp" } }, .backend = .{ .lanes = lanes } });
    defer p.deinit();
    try p.run_all();
    var out: std.ArrayList([]f64) = .empty;
    errdefer {
        for (out.items) |d| t.allocator.free(d);
        out.deinit(t.allocator);
    }
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const info = try p.query_info(id);
        if (!info.requested) continue;
        try out.append(t.allocator, try t.allocator.dupe(f64, (try p.result(id)).data));
    }
    return out;
}

test "AC-family lanes (#209): every .step point's .ac, .noise and .tf equal under --lanes, and repeated points equal each other" {
    var alone = try acLaneRun(false);
    defer {
        for (alone.items) |d| t.allocator.free(d);
        alone.deinit(t.allocator);
    }
    var laned = try acLaneRun(true);
    defer {
        for (laned.items) |d| t.allocator.free(d);
        laned.deinit(t.allocator);
    }
    try t.expectEqual(@as(usize, 24), laned.items.len);
    for (alone.items, laned.items) |a, b| try t.expectEqualSlices(u64, @ptrCast(a), @ptrCast(b));
    // Request order is point-major or kind-major; find the rl = 1k rows of
    // the first kind by content instead of position.
    var same: usize = 0;
    for (laned.items[1..]) |d| same += @intFromBool(d.len == laned.items[0].len and std.mem.eql(u64, @ptrCast(d), @ptrCast(laned.items[0])));
    try t.expect(same >= 3);
}
```

CHECK:
- the `Problem.init` option names (`.backend = .{ .lanes = ... }`; see
  espice.zig:55);
- `.step param ... list` support with `.ac`/`.noise`/`.tf` in the ngspice
  dialect (variants/step_param_divider.sp uses it with `.op`);
- that the 24 requested queries are 8 points × 3 kinds.

### 4d. Corpus gate: lanes on vs off on every swept AC deck

Build Debug with `-Dgpu=false`, then:

```sh
E=zig-out/bin/espice
out=$(mktemp -d)
grep -lE '^\.(step|data|alter|temp)\b|sweep data' -r tests/fixtures \
  | xargs grep -lE '^\.(ac|noise|sp|stb|lstb|tf|acmatch|dcmatch|sens|xf|acxf)\b' \
  | while read -r d; do
      b=$(basename "$d" .sp); dir=$(dirname "$d")
      (cd "$dir" && ESPICE_LANES=0 "$OLDPWD/$E" --jobs=1 --format=binary -b -r "$out/$b.0" "$(basename "$d")" >/dev/null 2>&1)
      (cd "$dir" && ESPICE_LANES=1 "$OLDPWD/$E" --jobs=1 --format=binary -b -r "$out/$b.1" "$(basename "$d")" >/dev/null 2>&1)
      cmp -s "$out/$b.0" "$out/$b.1" && echo "SAME $d" || echo "DIFF $d"
    done
```

- Today that set is 7 decks: `hspice/{meas_match, lin_rc_noise,
  noise_ac_sweep, lin_pad, match_diode_is, match_diode}.sp` and
  `variants/data_sweep.sp`. Every line must read SAME.
- Also run `zig build test -- --jobs 8` with `ESPICE_LANES=1` exported.
  The correctness corpus must pass unchanged, and `tests/VERDICTS.tsv`
  must not move.

### 4e. GPU parity hook (lands with phase 4's provider)

- The provider replaces `runFreqLanes`'s first loop when the batch's
  backend is the GPU.
- Its gate is a test in `src/analysis/tests/gpu.zig`, skipped without a
  device (as that file's others are):
  - run 4b's deck (AC rows only, no NaN row) on the GPU lane backend and on
    the CPU lanes;
  - compare every complex point with `test_correctness.zig`'s `close` at
    rtol 1e-6, the non-transient tolerance (:397);
  - name: `"gpu lanes: (point, ω) AC equals the CPU lanes within the
    test-gpu tolerance"`.
- Plus `zig build test-gpu` under `ESPICE_LANES=1`, with VERDICTS.tsv
  unmoved.

## 5. Risks and open questions

1. **Precompute vs live ordering (bitwise, settled only by 4b/4c):**
   - The batched run calls `linearizeAc` twice per lane (precompute, then
     `run`'s own `fromCircuit`). Without `ac_params` the second is a
     `linearize` memo hit. With them, `recompute` runs twice;
     deterministic, but untested.
   - `.noise` calls `collectNoiseSources(x_op)` (noise.zig:286) after the
     precompute's eval instead of before `run`'s. If a device's noise hook
     reads plane or memo state, the bits move.
   - Fallback if they do: drop `.noise` from `precompute` (one line); its
     lanes then solve live.
2. **`sameDeep` over the new option types** (`CardNames`, `Sp.Lin`,
   `XfSource`, `Lstb.Probe`) may not compile, or may compare a pointer
   where content was meant. Only a build settles it.
3. **CPU parallelism and memory.**
   - Under `--lanes --jobs=N`, W AC queries share one worker, where alone
     they took W workers. That is a CPU loss, accepted because lanes are
     off by default on the CPU (#211).
   - The precompute holds ω × rhs × 2n per lane; `.sp` is excluded and
     `.acxf` multiplies by the source count.
   - If a deck shows it, chunk the precompute (ponytail comment in
     `runFreqLanes`).
4. **GPU only:**
   - points' pivot tapes may differ (threshold pivoting is
     value-dependent), so one round can need several tape groups:
     divergence or extra launches;
   - `acDyn` decks are excluded from the (point, ω) path;
   - a point's centre factor needs that point's G/C on the host.
   - The 4e test and a MATCHA AC deck settle the throughput.
5. **Scope left out on purpose:**
   - a per-lane masked regula falsi for `.lstb`: per-lane `run` is already
     that bracket;
   - laned FD for `.tf`/`.sens`/`.dcmatch`/`.acmatch`: per-lane `run`,
     one host factor each;
   - add either when a profile shows the GPU idle on them.

## 6. Effort

| Step | Work | Effort |
|---|---|---|
| 1 | `Stream.pre`, `Plan`, `solveAll` | 0.5 d |
| 2 | `RunCtx.freq_pre` | 0.1 d |
| 3 | `plan` in ac, xf, stb, noise; `run`s use it | 0.5 d |
| 4 | executor `freqLaneKind`, `simKind`, `runFreqLanes`, `precompute` | 0.5 d |
| 5 | session `gather`, `sameLaneJob` (plus `sameDeep` fixes) | 0.25-0.5 d |
| 4a-4d | tests, corpus diff, fixes | 1.5 d |
| 6-7 | chunk seam and `StackedPoints` + test (GPU prep) | 0.75 d |
| **CPU phase total** | | **about 4-4.5 days** |
| GPU provider (phase 4 extension) | (point, ω) rounds, the lane complex-replay kernel (phase 4's `lane_refactor`/`lane_solve` over the `StackedPoints` fill), tape grouping, per-point host peels, the 4e test | 1-1.5 weeks |
