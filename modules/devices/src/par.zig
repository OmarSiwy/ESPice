//! Parallel device evaluation: lanes over private plane slabs, SIMD-reduced
//! in fixed order. Persistent workers, epoch spin-join, zero-alloc hot path.

const std = @import("std");
const batch_mod = @import("batch.zig");
const Batch = batch_mod.Batch;
const Planes = batch_mod.Planes;

// Lane model: lane 0 stamps directly into the caller's own planes (so the
// baseline memcpy / ground stamp story is unchanged); lanes 1..n_lanes stamp
// into private slabs which are then SIMD-reduced into the own planes in
// ascending lane order. Fixed partition + fixed lane→slab binding + fixed
// reduce order ⇒ bit-identical results run-to-run at a given n_lanes.
// (vs the serial path results differ by reassociation only.)
//
// Work is partitioned ONCE at init: all instances of all batches flattened
// into a weighted space (weight = n_u² per instance), cut into contiguous
// per-lane ranges. A batch with thread_safe=false is pinned whole to lane 0.
// Each extra lane also gets a precomputed scatter WINDOW (union of its
// tasks' scatter_bounds): zeroing and reduction touch only that window, so
// their cost tracks the lane's working set, not the whole matrix.
//
// Concurrency: persistent worker threads with an epoch spin-join handoff —
// zero allocations and no mutex on the eval hot path. Newton loops call
// eval thousands of times per solve; std.Io.Group's per-task closure
// allocation + mutex dispatch measurably lost to the serial path here.
// Idle workers spin briefly then Thread.yield, so parked cost is bounded.

/// One contiguous instance range of one batch, assigned to one lane.
pub const EvalTask = struct {
    batch: u32,
    first: u32,
    last: u32,
};

/// Per-extra-lane scatter window (union over the lane's tasks).
const Window = struct {
    slot_lo: u32,
    slot_hi: u32, // exclusive
    row_lo: u32,
    row_hi: u32, // exclusive
};

/// Serial fallback threshold: below this many total instances the fork/join
/// handoff overhead beats the parallel win, so policy should not build one.
pub const default_min_instances: u32 = 1024;

const Mode = enum(u8) { full, newton };

pub const ParEval = struct {
    io: std.Io, // retained for future use (worker threads are std.Thread)
    gpa: std.mem.Allocator,
    n_lanes: u32,

    // Value-plane slabs for lanes 1..n_lanes, each (nnz+1) / (n+1) long.
    g_slab: []f64,
    c_slab: []f64,
    rhs_slab: []f64,
    q_slab: []f64,

    // Static partition, grouped by lane: tasks[task_off[l]..task_off[l+1]].
    tasks: []EvalTask,
    task_off: []u32,
    // windows[l-1] = scatter window of lane l (extra lanes only).
    windows: []Window,

    nnz1: usize, // nnz + 1
    n1: usize, // n + 1
    has_charge: bool,

    // -- persistent workers (lazy-started: ParEval moves by value after init,
    //    workers capture `self`, so they may only start once the address is
    //    final — first evalParallel call) --
    threads: []std.Thread,
    started: bool,
    quit: std.atomic.Value(bool),
    epoch: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
    // Job for the current epoch (set before the epoch bump).
    job_batches: []const Batch,
    job_own_planes: Planes,
    job_has_charge: bool,
    job_x: []const f64,
    job_t: f64,
    job_mode: Mode,

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

        // -- weighted static partition --------------------------------------
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

        // Pass 1: pinned batches (thread_safe == false) go whole to lane 0.
        for (batches, 0..) |b, bi| {
            if (b.thread_safe or b.count == 0) continue;
            try lane_tasks[0].append(gpa, .{ .batch = @intCast(bi), .first = 0, .last = b.count });
            loads[0] += @as(u64, b.count) * b.n_u * b.n_u;
        }
        // Pass 2: thread-safe batches cut greedily across lanes in order.
        var cur: u32 = 0;
        for (batches, 0..) |b, bi| {
            if (!b.thread_safe or b.count == 0) continue;
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

        // -- per-lane scatter windows (extra lanes only) ---------------------
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

        // -- slabs -----------------------------------------------------------
        const g_slab = try gpa.alloc(f64, extra * nnz1);
        errdefer gpa.free(g_slab);
        const rhs_slab = try gpa.alloc(f64, extra * n1);
        errdefer gpa.free(rhs_slab);
        const c_slab = try gpa.alloc(f64, if (has_charge) extra * nnz1 else 0);
        errdefer gpa.free(c_slab);
        const q_slab = try gpa.alloc(f64, if (has_charge) extra * n1 else 0);
        errdefer gpa.free(q_slab);
        // Zero once: eval only re-zeroes the touched window, so the never-
        // touched remainder must start (and stay) zero.
        @memset(g_slab, 0);
        @memset(rhs_slab, 0);
        @memset(c_slab, 0);
        @memset(q_slab, 0);

        // -- per-lane dedup caches -------------------------------------------
        for (batches) |b| {
            if (b.hooks.set_lanes) |f| try f(b.ctx, gpa, n_lanes);
        }

        // Hoisted above the return literal: toOwnedSlice below must be the
        // last fallible op (its errdefer at `tasks` covers its own failure);
        // a threads-alloc failure after it would orphan the owned slice.
        const threads = try gpa.alloc(std.Thread, extra);
        errdefer gpa.free(threads);

        return .{
            .io = io,
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
            .job_has_charge = has_charge,
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

    /// Parallel eval. Zeros planes, runs device dispatch + lane reduction.
    /// Ground stamp is NOT applied here — caller handles it.
    pub fn eval(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, x: []const f64, t: f64) void {
        zeroSimd(own_planes.g_vals);
        if (has_charge) {
            zeroSimd(own_planes.c_vals);
            @memset(own_planes.q_vec, 0);
        }
        @memset(own_planes.rhs, 0);
        self.forkJoin(batches, own_planes, has_charge, x, t, .full);
    }

    /// Parallel evalNewton. Same baseline handling as the serial path, minus
    /// the ground stamp (caller handles it).
    pub fn evalNewton(
        self: *ParEval,
        batches: []const Batch,
        own_planes: Planes,
        has_charge: bool,
        has_baseline: bool,
        g_base: []const f64,
        c_base: []const f64,
        x: []const f64,
        t: f64,
    ) void {
        if (has_baseline) {
            @memcpy(own_planes.g_vals, g_base);
            if (has_charge) {
                @memcpy(own_planes.c_vals, c_base);
                @memset(own_planes.q_vec, 0);
            }
            @memset(own_planes.rhs, 0);
            self.forkJoin(batches, own_planes, has_charge, x, t, .newton);
        } else {
            zeroSimd(own_planes.g_vals);
            if (has_charge) {
                zeroSimd(own_planes.c_vals);
                @memset(own_planes.q_vec, 0);
            }
            @memset(own_planes.rhs, 0);
            self.forkJoin(batches, own_planes, has_charge, x, t, .full);
        }
    }

    fn forkJoin(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, x: []const f64, t: f64, mode: Mode) void {
        if (self.n_lanes == 1) {
            runLane(self, batches, own_planes, has_charge, 0, x, t, mode);
            return;
        }
        if (!self.started) self.startWorkers();
        // Publish the job, then bump the epoch (release) to wake workers.
        self.job_batches = batches;
        self.job_own_planes = own_planes;
        self.job_has_charge = has_charge;
        self.job_x = x;
        self.job_t = t;
        self.job_mode = mode;
        self.done.store(0, .monotonic);
        _ = self.epoch.fetchAdd(1, .release);
        runLane(self, batches, own_planes, has_charge, 0, x, t, mode);
        // Join: spin briefly, then yield — worker lanes are compute-bound and
        // finish in the same order of time as lane 0.
        var spins: u32 = 0;
        while (self.done.load(.acquire) < self.n_lanes - 1) {
            spins +%= 1;
            if (spins > 4096) std.Thread.yield() catch {};
        }
        self.reduce(own_planes, has_charge);
    }

    fn startWorkers(self: *ParEval) void {
        // Capture the baseline epoch HERE, before the caller's bump: a worker
        // reading epoch after the bump would treat the first job as already
        // seen and wait forever (4-thread spin livelock).
        const epoch0 = self.epoch.load(.acquire);
        for (self.threads, 1..) |*th, lane| {
            // Fat stacks: runtime-VA evals (PSP103+) carry multi-MB frames.
            th.* = std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, workerMain, .{ self, @as(u32, @intCast(lane)), epoch0 }) catch
                @panic("ParEval: worker spawn failed");
        }
        self.started = true;
    }

    fn workerMain(self: *ParEval, lane: u32, epoch0: u32) void {
        var last: u32 = epoch0;
        while (true) {
            // Wait for a new epoch: spin, then yield.
            var spins: u32 = 0;
            var e = self.epoch.load(.acquire);
            while (e == last) {
                spins +%= 1;
                if (spins > 4096) std.Thread.yield() catch {};
                e = self.epoch.load(.acquire);
            }
            last = e;
            if (self.quit.load(.acquire)) return;
            runLane(self, self.job_batches, self.job_own_planes, self.job_has_charge, lane, self.job_x, self.job_t, self.job_mode);
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
            // No-charge circuits: alias g/rhs — never written (no q stamps).
            .c_vals = if (self.has_charge) self.c_slab[e * self.nnz1 ..][0..self.nnz1] else g,
            .q_vec = if (self.has_charge) self.q_slab[e * self.n1 ..][0..self.n1] else r,
        };
    }

    fn runLane(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, lane: u32, x: []const f64, t: f64, mode: Mode) void {
        const pl = self.lanePlanes(own_planes, lane);
        if (lane != 0) {
            // Zero only this lane's scatter window (+ trash entries, which
            // collect ground writes and are never reduced).
            const win = self.windows[lane - 1];
            zeroSimd(pl.g_vals[win.slot_lo..win.slot_hi]);
            zeroSimd(pl.rhs[win.row_lo..win.row_hi]);
            pl.g_vals[self.nnz1 - 1] = 0;
            pl.rhs[self.n1 - 1] = 0;
            if (has_charge) {
                zeroSimd(pl.c_vals[win.slot_lo..win.slot_hi]);
                zeroSimd(pl.q_vec[win.row_lo..win.row_hi]);
                pl.c_vals[self.nnz1 - 1] = 0;
                pl.q_vec[self.n1 - 1] = 0;
            }
        }
        for (self.tasks[self.task_off[lane]..self.task_off[lane + 1]]) |task| {
            const b = &batches[task.batch];
            switch (mode) {
                .full => b.eval(b.ctx, &pl, lane, task.first, task.last, x, t),
                .newton => b.eval_newton(b.ctx, &pl, lane, task.first, task.last, x, t),
            }
        }
    }

    /// Fixed-order SIMD reduction of extra-lane windows into own planes.
    fn reduce(self: *ParEval, own_planes: Planes, has_charge: bool) void {
        var l: u32 = 1;
        while (l < self.n_lanes) : (l += 1) {
            const e: usize = l - 1;
            const win = self.windows[e];
            addSimd(
                own_planes.g_vals[win.slot_lo..win.slot_hi],
                self.g_slab[e * self.nnz1 + win.slot_lo .. e * self.nnz1 + win.slot_hi],
            );
            addSimd(
                own_planes.rhs[win.row_lo..win.row_hi],
                self.rhs_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
            );
            if (has_charge) {
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

fn zeroSimd(buf: []f64) void {
    const W = vec_width;
    const V = @Vector(W, f64);
    const zero: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= buf.len) : (i += W) buf[i..][0..W].* = zero;
    for (buf[i..]) |*v| v.* = 0;
}

fn addSimd(dst: []f64, src: []const f64) void {
    const W = vec_width;
    const V = @Vector(W, f64);
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) {
        const d: V = dst[i..][0..W].*;
        const s: V = src[i..][0..W].*;
        dst[i..][0..W].* = d + s;
    }
    while (i < dst.len) : (i += 1) dst[i] += src[i];
}
