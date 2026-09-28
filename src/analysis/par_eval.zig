//! ParEval: the device stamp threaded over persistent worker lanes. Lane 0
//! stamps the caller's planes; lanes 1.. stamp private slabs that are summed
//! into them in a fixed lane order. Zero allocation and no mutex per pass.
//!
//! Not bit-identical to the serial stamp: a plane cell becomes
//! `((S0 + S1) + S2) + ...` over consecutive segments of the serial order.
//! Lane cuts fall on instance boundaries, so one instance's cancelling
//! `+g/-g` pair never straddles lanes, but two instances sharing a node can.
//! Measured serial vs 2..16 lanes: at most 1 ulp (parallel_inverters,
//! resistor_grid_100x100; rc_ladder_10k bit-identical), deterministic at a
//! given lane count.
//!
//! ponytail: bit-identity would need a per-contribution staging tape and a
//! segmented reduction (about 8x the plane footprint at mos1 geometry). Build
//! it, copying the GPU's `Order`, only if a deck shows a thread-count-dependent
//! trajectory (a point-count change is the tell).

const std = @import("std");
const device_ir = @import("device").abi;

const Batch = device_ir.Batch;
const Planes = device_ir.Planes;

/// Instances [first, last) of batch `batch`.
const EvalTask = struct {
    batch: u32,
    first: u32,
    last: u32,
};

/// The plane and row index ranges one lane's tasks can write.
const Window = struct {
    slot_lo: u32,
    slot_hi: u32, // exclusive
    row_lo: u32,
    row_hi: u32, // exclusive
};

/// Which planes a stamp writes. `.charge` is the transient's post-accept
/// re-read: `q_vec` and the per-batch `q_tape` only. It uses the same tasks,
/// lane cuts and reduce order as `.full`, so its q plane is bit-for-bit what
/// `.full` leaves at the same lane count.
pub const Mode = enum(u8) { full, newton, charge };

/// Stamps instances [first, last) of one batch in `mode`. The one per-mode
/// dispatch shared by the serial path and every lane.
pub fn stampRange(b: Batch, pl: *const Planes, first: u32, last: u32, x: []const f64, t: f64, comptime mode: Mode) void {
    switch (mode) {
        .full => b.eval(b.ctx, pl, first, last, x, t),
        .newton => b.eval_newton(b.ctx, pl, first, last, x, t),
        .charge => if (b.hooks.eval_q) |f| f(b.ctx, pl, first, last, x, t),
    }
}

/// Persistent-worker threaded stamp. Owned by the executor for one query;
/// the batch table it was built for must not change shape while it lives.
pub const ParEval = struct {
    gpa: std.mem.Allocator,
    /// Parks idle workers on `epoch` (futex) between passes.
    io: std.Io,
    n_lanes: u32,

    /// Private planes of lanes 1.., `n_lanes - 1` back-to-back copies each.
    /// c/q are empty without charge.
    g_slab: []f64,
    c_slab: []f64,
    rhs_slab: []f64,
    q_slab: []f64,

    /// Every lane's tasks, lane-major; lane l owns `tasks[task_off[l]..task_off[l+1]]`.
    tasks: []EvalTask,
    task_off: []u32,
    /// Write window of lanes 1.., indexed `lane - 1`.
    windows: []Window,

    nnz1: usize,
    n1: usize,
    has_charge: bool,

    threads: []std.Thread,
    started: bool,
    quit: std.atomic.Value(bool),
    /// Bumped once per pass; workers spin on it, then park on it.
    epoch: std.atomic.Value(u32),
    /// Workers parked (or about to park) on `epoch`. `run` pays for the wake
    /// syscall only when this is nonzero.
    sleepers: std.atomic.Value(u32),
    /// Lanes, lane 0 included, finished stamping the current pass.
    stamped: std.atomic.Value(u32),
    /// Workers finished with the current pass, reduce included.
    done: std.atomic.Value(u32),
    /// The current pass's arguments, published before `epoch` is bumped.
    job_batches: []const Batch,
    job_own_planes: Planes,
    job_x: []const f64,
    job_t: f64,
    job_mode: Mode,

    /// Splits the batches into `n_lanes_req` (at least 1) lanes of roughly
    /// equal `count * n_u^2` work, cut at instance boundaries in ascending
    /// order. Threads start lazily on the first `run`.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        batches: []const Batch,
        nnz: u32,
        n: u32,
        has_charge: bool,
        trash_slot: u32,
        n_lanes_req: u32,
    ) !ParEval {
        const n_lanes = @max(n_lanes_req, 1);
        const nnz1: usize = nnz + 1;
        const n1: usize = n + 1;
        const extra: usize = n_lanes - 1;

        var w_total: u64 = 0;
        for (batches) |b| w_total += @as(u64, b.count) * b.n_u * b.n_u;
        const target: u64 = (w_total + n_lanes - 1) / n_lanes;

        var lane_tasks = try gpa.alloc(std.ArrayList(EvalTask), n_lanes);
        defer {
            for (lane_tasks) |*lt| lt.deinit(gpa);
            gpa.free(lane_tasks);
        }
        for (lane_tasks) |*lt| lt.* = .empty;
        var loads = try gpa.alloc(u64, n_lanes);
        defer gpa.free(loads);
        @memset(loads, 0);

        var cur: u32 = 0;
        for (batches, 0..) |b, bi| {
            if (b.count == 0) continue;
            const w: u64 = @as(u64, b.n_u) * b.n_u;
            var pos: u32 = 0;
            while (pos < b.count) {
                while (cur + 1 < n_lanes and loads[cur] >= target) cur += 1;
                const cap = if (loads[cur] >= target) b.count - pos else blk: {
                    const room = target - loads[cur];
                    break :blk @as(u32, @intCast(@min(@as(u64, b.count - pos), (room + w - 1) / w)));
                };
                const take = @max(cap, 1);
                try lane_tasks[cur].append(gpa, .{ .batch = @intCast(bi), .first = pos, .last = pos + take });
                loads[cur] += @as(u64, take) * w;
                pos += take;
            }
        }

        var tasks: std.ArrayList(EvalTask) = .empty;
        errdefer tasks.deinit(gpa);
        const task_off = try gpa.alloc(u32, n_lanes + 1);
        errdefer gpa.free(task_off);
        var off: u32 = 0;
        for (lane_tasks, 0..) |lt, l| {
            task_off[l] = off;
            try tasks.appendSlice(gpa, lt.items);
            off += @intCast(lt.items.len);
        }
        task_off[n_lanes] = off;

        const windows = try gpa.alloc(Window, extra);
        errdefer gpa.free(windows);
        for (windows, 1..) |*win, l| {
            win.* = .{ .slot_lo = @intCast(nnz1 - 1), .slot_hi = 0, .row_lo = @intCast(n1 - 1), .row_hi = 0 };
            for (tasks.items[task_off[l]..task_off[l + 1]]) |task| {
                const b = &batches[task.batch];
                const bounds = b.hooks.scatter_bounds(b.ctx, task.first, task.last, trash_slot, n);
                win.slot_lo = @min(win.slot_lo, bounds[0]);
                win.slot_hi = @max(win.slot_hi, bounds[1]);
                win.row_lo = @min(win.row_lo, bounds[2]);
                win.row_hi = @max(win.row_hi, bounds[3]);
            }
            if (win.slot_lo > win.slot_hi) win.slot_lo = win.slot_hi;
            if (win.row_lo > win.row_hi) win.row_lo = win.row_hi;
        }

        const g_slab = try gpa.alloc(f64, extra * nnz1);
        errdefer gpa.free(g_slab);
        const rhs_slab = try gpa.alloc(f64, extra * n1);
        errdefer gpa.free(rhs_slab);
        const c_slab = try gpa.alloc(f64, if (has_charge) extra * nnz1 else 0);
        errdefer gpa.free(c_slab);
        const q_slab = try gpa.alloc(f64, if (has_charge) extra * n1 else 0);
        errdefer gpa.free(q_slab);
        @memset(g_slab, 0);
        @memset(rhs_slab, 0);
        @memset(c_slab, 0);
        @memset(q_slab, 0);

        const threads = try gpa.alloc(std.Thread, extra);
        errdefer gpa.free(threads);

        return .{
            .gpa = gpa,
            .io = io,
            .n_lanes = n_lanes,
            .g_slab = g_slab,
            .c_slab = c_slab,
            .rhs_slab = rhs_slab,
            .q_slab = q_slab,
            .tasks = try tasks.toOwnedSlice(gpa),
            .task_off = task_off,
            .windows = windows,
            .nnz1 = nnz1,
            .n1 = n1,
            .has_charge = has_charge,
            .threads = threads,
            .started = false,
            .quit = .init(false),
            .epoch = .init(0),
            .sleepers = .init(0),
            .stamped = .init(0),
            .done = .init(0),
            .job_batches = batches,
            .job_own_planes = undefined,
            .job_x = &.{},
            .job_t = 0,
            .job_mode = .full,
        };
    }

    /// Stops and joins the workers, then frees every slab.
    pub fn deinit(self: *ParEval) void {
        if (self.started) {
            self.quit.store(true, .release);
            _ = self.epoch.fetchAdd(1, .seq_cst);
            self.io.futexWake(u32, &self.epoch.raw, std.math.maxInt(u32));
            for (self.threads) |th| th.join();
        }
        const gpa = self.gpa;
        gpa.free(self.threads);
        gpa.free(self.g_slab);
        gpa.free(self.c_slab);
        gpa.free(self.rhs_slab);
        gpa.free(self.q_slab);
        gpa.free(self.tasks);
        gpa.free(self.task_off);
        gpa.free(self.windows);
        self.* = undefined;
    }

    /// Stamps every batch into `own_planes` across the lanes and waits for all
    /// of them. The caller has already cleared (or baseline-seeded) the planes
    /// `mode` writes. Spawns the workers on first use; a failed spawn panics.
    /// `.charge` on a circuit without charge is a no-op: there is no q plane.
    pub fn run(self: *ParEval, batches: []const Batch, own_planes: Planes, x: []const f64, t: f64, mode: Mode) void {
        if (mode == .charge and !self.has_charge) return;
        if (self.n_lanes == 1) {
            runLane(self, batches, own_planes, 0, x, t, mode);
            return;
        }
        if (!self.started) self.startWorkers();
        self.job_batches = batches;
        self.job_own_planes = own_planes;
        self.job_x = x;
        self.job_t = t;
        self.job_mode = mode;
        self.stamped.store(0, .monotonic);
        self.done.store(0, .monotonic);
        // seq_cst pairs with the worker's `sleepers` increment and epoch
        // re-check: either it sees the new epoch or this sees it parking.
        _ = self.epoch.fetchAdd(1, .seq_cst);
        if (self.sleepers.load(.seq_cst) != 0)
            self.io.futexWake(u32, &self.epoch.raw, std.math.maxInt(u32));
        runLane(self, batches, own_planes, 0, x, t, mode);
        _ = self.stamped.fetchAdd(1, .acq_rel);
        waitCount(&self.stamped, self.n_lanes);
        self.reduceChunk(own_planes, mode, 0);
        waitCount(&self.done, self.n_lanes - 1);
    }

    fn startWorkers(self: *ParEval) void {
        const epoch0 = self.epoch.load(.acquire);
        for (self.threads, 1..) |*th, lane| {
            th.* = std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, workerMain, .{ self, @as(u32, @intCast(lane)), epoch0 }) catch
                @panic("ParEval: worker spawn failed");
        }
        self.started = true;
    }

    fn workerMain(self: *ParEval, lane: u32, epoch0: u32) void {
        var last: u32 = epoch0;
        while (true) {
            var spins: u32 = 0;
            var e = self.epoch.load(.acquire);
            while (e == last) {
                if (spins < park_spins) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                } else if (spins < park_spins + park_yields) {
                    std.Thread.yield() catch {};
                    spins += 1;
                } else {
                    // Spinning (or `yield`, which returns at once on an idle
                    // core) through the host solve kept every worker at
                    // 100% CPU. The futex rechecks `epoch == last` itself.
                    _ = self.sleepers.fetchAdd(1, .seq_cst);
                    if (self.epoch.load(.seq_cst) == last)
                        self.io.futexWaitUncancelable(u32, &self.epoch.raw, last);
                    _ = self.sleepers.fetchSub(1, .seq_cst);
                }
                e = self.epoch.load(.acquire);
            }
            last = e;
            if (self.quit.load(.acquire)) return;
            runLane(self, self.job_batches, self.job_own_planes, lane, self.job_x, self.job_t, self.job_mode);
            _ = self.stamped.fetchAdd(1, .acq_rel);
            waitCount(&self.stamped, self.n_lanes);
            self.reduceChunk(self.job_own_planes, self.job_mode, lane);
            _ = self.done.fetchAdd(1, .release);
        }
    }

    fn lanePlanes(self: *ParEval, own_planes: Planes, lane: u32) Planes {
        if (lane == 0) return own_planes;
        const e: usize = lane - 1;
        const g = self.g_slab[e * self.nnz1 ..][0..self.nnz1];
        const r = self.rhs_slab[e * self.n1 ..][0..self.n1];
        return .{
            .g_vals = g,
            .rhs = r,
            .c_vals = if (self.has_charge) self.c_slab[e * self.nnz1 ..][0..self.nnz1] else g,
            .q_vec = if (self.has_charge) self.q_slab[e * self.n1 ..][0..self.n1] else r,
        };
    }

    fn runLane(self: *ParEval, batches: []const Batch, own_planes: Planes, lane: u32, x: []const f64, t: f64, mode: Mode) void {
        const pl = self.lanePlanes(own_planes, lane);
        if (lane != 0) {
            // The window is already zero: `reduceChunk` clears what it
            // consumes. The trash cells lie outside it.
            pl.g_vals[self.nnz1 - 1] = 0;
            pl.rhs[self.n1 - 1] = 0;
            pl.c_vals[self.nnz1 - 1] = 0;
            pl.q_vec[self.n1 - 1] = 0;
        }
        for (self.tasks[self.task_off[lane]..self.task_off[lane + 1]]) |task|
            switch (mode) {
                inline else => |m| stampRange(batches[task.batch], &pl, task.first, task.last, x, t, m),
            };
    }

    /// Moves every lane's slab into lane `lane`'s share of `own_planes`:
    /// adds, lanes in ascending order, so each cell sums in the order a
    /// serial reduce would, and zeroes the slab cell for the next pass. The
    /// shares split the slots and rows into cache-line aligned ranges; every
    /// lane reduces one after all have stamped. Clearing here rather than
    /// per lane before its stamp spreads that traffic evenly: the per-lane
    /// clear cost each lane its whole window (chain_psp103_10k: 300k-660k
    /// slots of 1.4M), and the widest window set the pass time.
    fn reduceChunk(self: *ParEval, own_planes: Planes, mode: Mode, lane: u32) void {
        const slots = share(self.nnz1, lane, self.n_lanes);
        const rows = share(self.n1, lane, self.n_lanes);
        var l: u32 = 1;
        while (l < self.n_lanes) : (l += 1) {
            const e: usize = l - 1;
            const win = self.windows[e];
            const s0 = @max(slots[0], win.slot_lo);
            const s1 = @min(slots[1], win.slot_hi);
            const r0 = @max(rows[0], win.row_lo);
            const r1 = @min(rows[1], win.row_hi);
            const go = e * self.nnz1;
            const ro = e * self.n1;
            if (mode != .charge and s0 < s1) {
                moveSimd(own_planes.g_vals[s0..s1], self.g_slab[go + s0 .. go + s1]);
                if (self.has_charge) moveSimd(own_planes.c_vals[s0..s1], self.c_slab[go + s0 .. go + s1]);
            }
            if (r0 < r1) {
                if (mode != .charge) moveSimd(own_planes.rhs[r0..r1], self.rhs_slab[ro + r0 .. ro + r1]);
                if (self.has_charge) moveSimd(own_planes.q_vec[r0..r1], self.q_slab[ro + r0 .. ro + r1]);
            }
        }
    }
};

/// Lane `lane`'s range of `[0, len)` when `lanes` split it, cut on 8-cell
/// (64-byte) boundaries so no two lanes write one cache line.
fn share(len: usize, lane: u32, lanes: u32) [2]usize {
    const lo = (len * lane / lanes) & ~@as(usize, 7);
    const hi = if (lane + 1 == lanes) len else (len * (lane + 1) / lanes) & ~@as(usize, 7);
    return .{ lo, hi };
}

/// Spins, then yields, until `counter` reaches `target`. `pause` frees
/// issue slots for the SMT sibling that may be running the lane this waits
/// on.
fn waitCount(counter: *std.atomic.Value(u32), target: u32) void {
    var spins: u32 = 0;
    while (counter.load(.acquire) < target) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        if (spins > 4096) std.Thread.yield() catch {};
    }
}

/// Pause-loop iterations a worker spins on `epoch` before it parks: long
/// enough to catch the next pass across a short solve, short enough that a
/// long LU solve does not burn the cores.
const park_spins: u32 = 4096;
const park_yields: u32 = 64;

const vec_width = std.simd.suggestVectorLength(f64) orelse 4;

/// Adds `src` into `dst` elementwise, then zeroes `src`. Equal lengths.
fn moveSimd(dst: []f64, src: []f64) void {
    const W = vec_width;
    const Vv = @Vector(W, f64);
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) {
        const d: Vv = dst[i..][0..W].*;
        const s: Vv = src[i..][0..W].*;
        dst[i..][0..W].* = d + s;
        src[i..][0..W].* = @splat(0);
    }
    while (i < dst.len) : (i += 1) {
        dst[i] += src[i];
        src[i] = 0;
    }
}
