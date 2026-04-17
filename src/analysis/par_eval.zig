//! ParEval: persistent-worker CPU threading of the device stamp. Analysis
//! scheduling, so it lives here and not in the device evaluator.

const std = @import("std");
const device_ir = @import("device").abi;
const zeroSimd = @import("numerics").zeroSimd;

const Batch = device_ir.Batch;
const Planes = device_ir.Planes;

// ===========================================================================
// ParEval — persistent-worker CPU threading. Lane 0 stamps into the caller's
// planes; lanes 1.. stamp private slabs, SIMD-reduced in fixed order (bit-
// identical run-to-run at a given n_lanes). Zero-alloc, no-mutex hot path.
//
// NOT bit-identical to the serial path, and that is a bounded reassociation,
// not the GPU's unbounded one. `reduce` walks lanes 1..n in a fixed order, so
// a cell's sum is `((S0 + S1) + S2) + ...` over CONSECUTIVE segments of the
// serial sequence — `init` cuts the lane ranges at INSTANCE boundaries and
// hands them out in ascending order, so no ONE INSTANCE's contributions ever
// straddle a lane. That keeps the cancelling `+g/-g` pair that makes a
// high-fan-in cell ill-conditioned (see `GpuContext.reduce`) inside one lane.
//
// It does NOT keep a NODE inside one lane. Two instances of the same batch that
// share a node can land either side of a cut, and then that node's row sum is
// split — measured on sweep/opamp_wl_5000 at 16 lanes, where the deviation set
// is exactly the four nodes of OTA #888 (`tail_888` is driven by M1/M2/M5_888,
// all nch, and the cut falls between them). Still 1 ulp, still deterministic at
// a given n_lanes; the guarantee is per-instance, not per-node.
//
// Measured serial vs
// n_lanes in {2,4,8,16}, same point count everywhere: parallel_inverters_500
// and _2000 max 1.1e-16..1.9e-16, resistor_grid_100x100 4.4e-16, rc_ladder_10k
// bit-identical. One ulp, against a benchmark tolerance of 1e-2.
//
// ponytail: bit-identity would need a per-contribution staging tape on the host
// and a segmented reduction over it — ~8x the plane footprint at mos1 geometry
// and the same memory traffic twice, to move 1 ulp. Build it only if a deck
// ever shows a threading-dependent trajectory (a point-count change is the
// tell); the GPU's `Order` is the design to copy.
// ===========================================================================

pub const EvalTask = struct {
    batch: u32,
    first: u32,
    last: u32,
};

const Window = struct {
    slot_lo: u32,
    slot_hi: u32, // exclusive
    row_lo: u32,
    row_hi: u32, // exclusive
};

/// `.charge` is the transient's post-accept re-read: `q_vec` and the per-batch
/// `q_tape` only, g/c/rhs left alone. Same tasks, same lane cuts and the same
/// `reduce` order as `.full`, so the q plane it leaves is bit-for-bit the one
/// `.full` would have left at this width — which is the property the serial
/// `Circuit.evalQ` promises against serial `eval`.
pub const Mode = enum(u8) { full, newton, charge };

/// Stamp instances [first, last) of one batch. The one per-mode dispatch the
/// serial path and every lane share.
pub fn stampRange(b: Batch, pl: *const Planes, first: u32, last: u32, x: []const f64, t: f64, comptime mode: Mode) void {
    switch (mode) {
        .full => b.eval(b.ctx, pl, first, last, x, t),
        .newton => b.eval_newton(b.ctx, pl, first, last, x, t),
        .charge => if (b.hooks.eval_q) |f| f(b.ctx, pl, first, last, x, t),
    }
}

pub const ParEval = struct {
    gpa: std.mem.Allocator,
    n_lanes: u32,

    g_slab: []f64,
    c_slab: []f64,
    rhs_slab: []f64,
    q_slab: []f64,

    tasks: []EvalTask,
    task_off: []u32,
    windows: []Window,

    nnz1: usize,
    n1: usize,
    has_charge: bool,

    threads: []std.Thread,
    started: bool,
    quit: std.atomic.Value(bool),
    epoch: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
    job_batches: []const Batch,
    job_own_planes: Planes,
    job_x: []const f64,
    job_t: f64,
    job_mode: Mode,

    pub fn init(
        gpa: std.mem.Allocator,
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
            .done = .init(0),
            .job_batches = batches,
            .job_own_planes = undefined,
            .job_x = &.{},
            .job_t = 0,
            .job_mode = .full,
        };
    }

    pub fn deinit(self: *ParEval) void {
        if (self.started) {
            self.quit.store(true, .release);
            _ = self.epoch.fetchAdd(1, .release);
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

    /// Stamp every batch into `own_planes` across the lanes. The caller has
    /// already cleared (or baseline-seeded) the planes `mode` writes.
    pub fn run(self: *ParEval, batches: []const Batch, own_planes: Planes, x: []const f64, t: f64, mode: Mode) void {
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
        self.done.store(0, .monotonic);
        _ = self.epoch.fetchAdd(1, .release);
        runLane(self, batches, own_planes, 0, x, t, mode);
        var spins: u32 = 0;
        while (self.done.load(.acquire) < self.n_lanes - 1) {
            // Same `pause` the loader's SpinLock uses. A busy waiter should not
            // hold issue slots its SMT sibling needs to FINISH the job we are
            // waiting on. Acquire/release and the 4096-spin yield are unchanged.
            std.atomic.spinLoopHint();
            spins +%= 1;
            if (spins > 4096) std.Thread.yield() catch {};
        }
        self.reduce(own_planes, mode);
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
                std.atomic.spinLoopHint();
                spins +%= 1;
                if (spins > 4096) std.Thread.yield() catch {};
                e = self.epoch.load(.acquire);
            }
            last = e;
            if (self.quit.load(.acquire)) return;
            runLane(self, self.job_batches, self.job_own_planes, lane, self.job_x, self.job_t, self.job_mode);
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
            const win = self.windows[lane - 1];
            // `.charge` writes q and nothing else, so it clears q and nothing
            // else: the other three slabs keep whatever the last `.full` or
            // `.newton` left, and `reduce` does not read them back.
            if (mode != .charge) {
                zeroSimd(pl.g_vals[win.slot_lo..win.slot_hi]);
                zeroSimd(pl.rhs[win.row_lo..win.row_hi]);
                pl.g_vals[self.nnz1 - 1] = 0;
                pl.rhs[self.n1 - 1] = 0;
            }
            if (self.has_charge) {
                if (mode != .charge) {
                    zeroSimd(pl.c_vals[win.slot_lo..win.slot_hi]);
                    pl.c_vals[self.nnz1 - 1] = 0;
                }
                zeroSimd(pl.q_vec[win.row_lo..win.row_hi]);
                pl.q_vec[self.n1 - 1] = 0;
            }
        }
        for (self.tasks[self.task_off[lane]..self.task_off[lane + 1]]) |task|
            switch (mode) {
                inline else => |m| stampRange(batches[task.batch], &pl, task.first, task.last, x, t, m),
            };
    }

    fn reduce(self: *ParEval, own_planes: Planes, mode: Mode) void {
        var l: u32 = 1;
        while (l < self.n_lanes) : (l += 1) {
            const e: usize = l - 1;
            const win = self.windows[e];
            if (mode == .charge) {
                addSimd(
                    own_planes.q_vec[win.row_lo..win.row_hi],
                    self.q_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
                );
                continue;
            }
            addSimd(
                own_planes.g_vals[win.slot_lo..win.slot_hi],
                self.g_slab[e * self.nnz1 + win.slot_lo .. e * self.nnz1 + win.slot_hi],
            );
            addSimd(
                own_planes.rhs[win.row_lo..win.row_hi],
                self.rhs_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
            );
            if (self.has_charge) {
                addSimd(
                    own_planes.c_vals[win.slot_lo..win.slot_hi],
                    self.c_slab[e * self.nnz1 + win.slot_lo .. e * self.nnz1 + win.slot_hi],
                );
                addSimd(
                    own_planes.q_vec[win.row_lo..win.row_hi],
                    self.q_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
                );
            }
        }
    }
};

const vec_width = std.simd.suggestVectorLength(f64) orelse 4;

/// `dst += src`, elementwise.
pub fn addSimd(dst: []f64, src: []const f64) void {
    const W = vec_width;
    const Vv = @Vector(W, f64);
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) {
        const d: Vv = dst[i..][0..W].*;
        const s: Vv = src[i..][0..W].*;
        dst[i..][0..W].* = d + s;
    }
    while (i < dst.len) : (i += 1) dst[i] += src[i];
}
