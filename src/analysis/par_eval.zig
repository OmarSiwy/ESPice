//! ParEval: the device stamp threaded over persistent worker lanes, bit for
//! bit the serial stamp at any lane count (#137).
//!
//! A pass has two phases. Stamp: lanes claim chunks of instances and each
//! instance stores every stamp at its own position in a staging array
//! (`Hooks.stage`), so no two lanes write one cell. Reduce: lanes claim
//! blocks of plane cells and sum each cell's positions in tape order onto
//! its initial value (zero, or the constant baseline). Tape order is the
//! order the serial stamp adds them in, so every cell rounds as it does
//! serially, whatever the lane count or the chunk a lane happened to claim.
//!
//! Claiming is dynamic, so a slow lane (an E-core beside P-cores) takes fewer
//! chunks instead of holding up the pass. The previous design gave each lane
//! a whole-plane slab and a static instance range: sums regrouped with the
//! lane count (up to 24554 ulp), the slabs cost a plane copy per lane, and
//! the reduce walked every lane's slot window, which a shared rail stretches
//! to the whole plane (#138; dev/analysis/refactoring.md, "ParEval").

const std = @import("std");
const builtin = @import("builtin");
const device_ir = @import("device").abi;

const Batch = device_ir.Batch;
const Planes = device_ir.Planes;

/// Which planes a stamp writes; see `device_ir.StampMode`. `.charge` uses
/// the same staging and reduce as `.full`, so its q plane is bit-for-bit
/// what `.full` leaves.
pub const Mode = device_ir.StampMode;

/// Instances [first, last) of batch `batch`.
const EvalTask = struct {
    batch: u32,
    first: u32,
    last: u32,
};

/// Stamps instances [first, last) of one batch in `mode`. The serial path's
/// per-mode dispatch.
pub fn stampRange(b: Batch, pl: *const Planes, first: u32, last: u32, x: []const f64, t: f64, comptime mode: Mode) void {
    switch (mode) {
        .full => b.eval(b.ctx, pl, first, last, x, t),
        .newton => b.eval_newton(b.ctx, pl, first, last, x, t),
        .charge => if (b.hooks.eval_q) |f| f(b.ctx, pl, first, last, x, t),
    }
}

/// Cell -> its staging positions in tape order, for one index space (slots
/// or rows). Cell i's positions are `src[seg[i]..seg[i + 1]]`; ground
/// entries are in no cell.
const Gather = struct {
    seg: []u32,
    src: []u32,

    /// Counting sort of `tapes` (each batch's tape, its positions starting
    /// at `base[b]`) by destination cell, stable, so each run keeps tape
    /// order. `trash` (ground) entries are dropped.
    fn build(gpa: std.mem.Allocator, tapes: []const []const u32, n_cells: usize, trash: u32) !Gather {
        const seg = try gpa.alloc(u32, n_cells + 1);
        errdefer gpa.free(seg);
        @memset(seg, 0);
        for (tapes) |tape| for (tape) |dest| {
            if (dest != trash) seg[dest + 1] += 1;
        };
        for (1..seg.len) |i| seg[i] += seg[i - 1];
        const src = try gpa.alloc(u32, seg[n_cells]);
        errdefer gpa.free(src);
        const cursor = try gpa.dupe(u32, seg[0..n_cells]);
        defer gpa.free(cursor);
        var pos: u32 = 0;
        for (tapes) |tape| for (tape) |dest| {
            if (dest != trash) {
                src[cursor[dest]] = pos;
                cursor[dest] += 1;
            }
            pos += 1;
        };
        return .{ .seg = seg, .src = src };
    }

    fn deinit(self: Gather, gpa: std.mem.Allocator) void {
        gpa.free(self.seg);
        gpa.free(self.src);
    }
};

/// Persistent-worker threaded stamp. Owned by the executor for one query;
/// the batch table it was built for must not change shape while it lives.
pub const ParEval = struct {
    gpa: std.mem.Allocator,
    /// Parks idle workers on `epoch` (futex) between passes.
    io: std.Io,
    n_lanes: u32,

    /// Staged stamps, one position per tape entry: every batch's slot
    /// entries back to back (g, c), and its row entries (rhs, q). Each
    /// position holds -0.0 between passes, the additive identity, so one a
    /// pass leaves unstamped adds nothing, not even a sign. c/q are empty
    /// without charge.
    g_stage: []f64,
    c_stage: []f64,
    rhs_stage: []f64,
    q_stage: []f64,
    /// Batch b's first slot and row position.
    slot_base: []u32,
    row_base: []u32,
    slots: Gather,
    rows: Gather,

    /// Stamp chunks, claimed in order through `next_task`.
    tasks: []EvalTask,
    /// Reduce blocks over the cells `[0, nnz + n)`, slots then rows: block j
    /// is `[cuts[j], cuts[j + 1])`, claimed through `next_block`.
    cuts: []u32,

    nnz: u32,
    n: u32,
    has_charge: bool,

    threads: []std.Thread,
    started: bool,
    /// Each counter a lane writes while others read sits alone on its line,
    /// apart from the read-only `job_*` arguments and from each other, so a
    /// claim or barrier increment invalidates only that counter's line (#172).
    wake: Wake,
    next_task: Counter,
    next_block: Counter,
    /// Lanes, lane 0 included, finished stamping the current pass.
    stamped: Counter,
    /// Workers finished with the current pass, reduce included.
    done: Counter,
    /// The current pass's arguments, published before `epoch` is bumped.
    job_batches: []const Batch,
    job_planes: Planes,
    job_base: Base,
    job_x: []const f64,
    job_t: f64,
    job_mode: Mode,

    /// A u32 counter padded to a whole cache line: the struct's size rounds
    /// up to its alignment, so no other field shares the line.
    const Counter = struct {
        v: std.atomic.Value(u32) align(std.atomic.cache_line),
    };

    /// The pass doorbell, on its own line. `epoch` is bumped once per pass;
    /// workers spin on it, then park on it. `sleepers` counts workers parked
    /// (or about to park) on `epoch`: `run` pays for the wake syscall only
    /// when it is nonzero. `quit` is read right after `epoch` changes. All
    /// three are written about once per pass, so they share one line.
    const Wake = struct {
        epoch: std.atomic.Value(u32) align(std.atomic.cache_line),
        sleepers: std.atomic.Value(u32),
        quit: std.atomic.Value(bool),
    };

    comptime {
        std.debug.assert(@sizeOf(Counter) == std.atomic.cache_line);
        std.debug.assert(@sizeOf(Wake) == std.atomic.cache_line);
    }

    /// Initial g and c of every cell: the constant baseline, or empty for
    /// zero.
    pub const Base = struct {
        g: []const f64 = &.{},
        c: []const f64 = &.{},
    };

    /// Builds the staging for `batches` and splits the instances into
    /// chunks of roughly equal `count * instanceWeight` work, about eight
    /// per lane, so a fast lane can take a slow lane's share. Threads start
    /// lazily on the first `run`. `batches` must outlive it; free it with
    /// `deinit`. Asserts that `trash_slot == nnz`. Fails with
    /// `error.OutOfMemory` on allocation or when the tapes hold more than
    /// 2^32 positions. A single-threaded build runs one lane.
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
        std.debug.assert(trash_slot == nnz);
        // Single-threaded (wasm): one lane whatever `n_lanes_req` asks.
        const n_lanes: u32 = if (builtin.single_threaded) 1 else @max(n_lanes_req, 1);

        const slot_base = try gpa.alloc(u32, batches.len);
        errdefer gpa.free(slot_base);
        const row_base = try gpa.alloc(u32, batches.len);
        errdefer gpa.free(row_base);
        const slot_tapes = try gpa.alloc([]const u32, batches.len);
        defer gpa.free(slot_tapes);
        const row_tapes = try gpa.alloc([]const u32, batches.len);
        defer gpa.free(row_tapes);
        var n_slot: u64 = 0;
        var n_row: u64 = 0;
        for (batches, slot_base, row_base, slot_tapes, row_tapes) |b, *sb, *rb, *st, *rt| {
            const tapes = b.hooks.scatter_tapes(b.ctx);
            std.debug.assert(tapes.rows.len == @as(usize, b.count) * b.n_u);
            st.* = tapes.slots;
            rt.* = tapes.rows;
            sb.* = std.math.cast(u32, n_slot) orelse return error.OutOfMemory;
            rb.* = std.math.cast(u32, n_row) orelse return error.OutOfMemory;
            n_slot += tapes.slots.len;
            n_row += tapes.rows.len;
        }
        // Positions are u32, like the tapes; past that the staging alone
        // would need 32 GB per plane.
        if (n_slot > std.math.maxInt(u32) or n_row > std.math.maxInt(u32)) return error.OutOfMemory;

        const slots = try Gather.build(gpa, slot_tapes, nnz, trash_slot);
        errdefer slots.deinit(gpa);
        const rows = try Gather.build(gpa, row_tapes, n, n);
        errdefer rows.deinit(gpa);

        const g_stage = try gpa.alloc(f64, n_slot);
        errdefer gpa.free(g_stage);
        const rhs_stage = try gpa.alloc(f64, n_row);
        errdefer gpa.free(rhs_stage);
        const c_stage = try gpa.alloc(f64, if (has_charge) n_slot else 0);
        errdefer gpa.free(c_stage);
        const q_stage = try gpa.alloc(f64, if (has_charge) n_row else 0);
        errdefer gpa.free(q_stage);
        for ([_][]f64{ g_stage, rhs_stage, c_stage, q_stage }) |st| @memset(st, -0.0);

        const tasks = try chunkTasks(gpa, batches, n_lanes);
        errdefer gpa.free(tasks);
        const cuts = try cutBlocks(gpa, slots.seg, rows.seg, n_lanes);
        errdefer gpa.free(cuts);

        const threads = try gpa.alloc(std.Thread, n_lanes - 1);
        errdefer gpa.free(threads);

        return .{
            .gpa = gpa,
            .io = io,
            .n_lanes = n_lanes,
            .g_stage = g_stage,
            .c_stage = c_stage,
            .rhs_stage = rhs_stage,
            .q_stage = q_stage,
            .slot_base = slot_base,
            .row_base = row_base,
            .slots = slots,
            .rows = rows,
            .tasks = tasks,
            .cuts = cuts,
            .nnz = nnz,
            .n = n,
            .has_charge = has_charge,
            .threads = threads,
            .started = false,
            .wake = .{ .epoch = .init(0), .sleepers = .init(0), .quit = .init(false) },
            .next_task = .{ .v = .init(0) },
            .next_block = .{ .v = .init(0) },
            .stamped = .{ .v = .init(0) },
            .done = .{ .v = .init(0) },
            .job_batches = batches,
            .job_planes = undefined,
            .job_base = .{},
            .job_x = &.{},
            .job_t = 0,
            .job_mode = .full,
        };
    }

    /// Stops and joins the workers, then frees every table.
    pub fn deinit(self: *ParEval) void {
        if (self.started) {
            self.wake.quit.store(true, .release);
            _ = self.wake.epoch.fetchAdd(1, .seq_cst);
            self.io.futexWake(u32, &self.wake.epoch.raw, std.math.maxInt(u32));
            for (self.threads) |th| th.join();
        }
        const gpa = self.gpa;
        gpa.free(self.threads);
        gpa.free(self.g_stage);
        gpa.free(self.c_stage);
        gpa.free(self.rhs_stage);
        gpa.free(self.q_stage);
        gpa.free(self.slot_base);
        gpa.free(self.row_base);
        self.slots.deinit(gpa);
        self.rows.deinit(gpa);
        gpa.free(self.tasks);
        gpa.free(self.cuts);
        self.* = undefined;
    }

    /// Sets every cell of the planes `mode` writes to its value in `base`
    /// (`.newton` only; zero otherwise) plus every batch's stamps at `x`, and
    /// waits for all lanes. `planes` need no clearing first. Spawns the
    /// workers on first use; a failed spawn panics. `.charge` on a circuit
    /// without charge is a no-op: there is no q plane. Asserts that
    /// `batches` has as many batches as `init` saw and that `base` is empty
    /// outside `.newton`.
    pub fn run(self: *ParEval, batches: []const Batch, planes: Planes, base: Base, x: []const f64, t: f64, mode: Mode) void {
        if (mode == .charge and !self.has_charge) return;
        std.debug.assert(batches.len == self.slot_base.len);
        std.debug.assert(mode == .newton or (base.g.len == 0 and base.c.len == 0));
        self.job_batches = batches;
        self.job_planes = planes;
        self.job_base = base;
        self.job_x = x;
        self.job_t = t;
        self.job_mode = mode;
        self.next_task.v.store(0, .monotonic);
        self.next_block.v.store(0, .monotonic);
        self.stamped.v.store(0, .monotonic);
        self.done.v.store(0, .monotonic);
        // Comptime-false single-threaded, so `startWorkers` never compiles there.
        if (!builtin.single_threaded and self.n_lanes > 1) {
            if (!self.started) self.startWorkers();
            // seq_cst pairs with the worker's `sleepers` increment and epoch
            // re-check: either it sees the new epoch or this sees it parking.
            _ = self.wake.epoch.fetchAdd(1, .seq_cst);
            if (self.wake.sleepers.load(.seq_cst) != 0)
                self.io.futexWake(u32, &self.wake.epoch.raw, std.math.maxInt(u32));
        }
        self.pass();
        waitCount(&self.done.v, self.n_lanes - 1);
        // The trash cells take no stamps here; give them their initial value.
        switch (mode) {
            .charge => planes.q_vec[self.n] = 0,
            inline else => |m| {
                planes.g_vals[self.nnz] = if (m == .newton and base.g.len > 0) base.g[self.nnz] else 0;
                planes.rhs[self.n] = 0;
                if (self.has_charge) {
                    planes.c_vals[self.nnz] = if (m == .newton and base.c.len > 0) base.c[self.nnz] else 0;
                    planes.q_vec[self.n] = 0;
                }
            },
        }
    }

    fn startWorkers(self: *ParEval) void {
        const epoch0 = self.wake.epoch.load(.acquire);
        for (self.threads) |*th| {
            th.* = std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, workerMain, .{ self, epoch0 }) catch
                @panic("ParEval: worker spawn failed");
        }
        self.started = true;
    }

    fn workerMain(self: *ParEval, epoch0: u32) void {
        var last: u32 = epoch0;
        while (true) {
            var spins: u32 = 0;
            var e = self.wake.epoch.load(.acquire);
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
                    _ = self.wake.sleepers.fetchAdd(1, .seq_cst);
                    if (self.wake.epoch.load(.seq_cst) == last)
                        self.io.futexWaitUncancelable(u32, &self.wake.epoch.raw, last);
                    _ = self.wake.sleepers.fetchSub(1, .seq_cst);
                }
                e = self.wake.epoch.load(.acquire);
            }
            last = e;
            if (self.wake.quit.load(.acquire)) return;
            self.pass();
            _ = self.done.v.fetchAdd(1, .release);
        }
    }

    /// One lane's share of a pass: claim stamp chunks until none are left,
    /// wait for every lane to finish stamping, then claim reduce blocks.
    fn pass(self: *ParEval) void {
        const mode = self.job_mode;
        while (true) {
            const i = self.next_task.v.fetchAdd(1, .monotonic);
            if (i >= self.tasks.len) break;
            const task = self.tasks[i];
            const b = self.job_batches[task.batch];
            const sb = self.slot_base[task.batch];
            const rb = self.row_base[task.batch];
            const pl: Planes = .{
                .g_vals = self.g_stage[sb..],
                .c_vals = if (self.has_charge) self.c_stage[sb..] else &.{},
                .rhs = self.rhs_stage[rb..],
                .q_vec = if (self.has_charge) self.q_stage[rb..] else &.{},
            };
            b.hooks.stage(b.ctx, &pl, task.first, task.last, self.job_x, self.job_t, mode);
        }
        _ = self.stamped.v.fetchAdd(1, .acq_rel);
        waitCount(&self.stamped.v, self.n_lanes);
        const n_blocks = self.cuts.len - 1;
        while (true) {
            const j = self.next_block.v.fetchAdd(1, .monotonic);
            if (j >= n_blocks) break;
            const lo = self.cuts[j];
            const hi = self.cuts[j + 1];
            switch (mode) {
                inline else => |m| self.reduceBlock(lo, hi, m),
            }
        }
    }

    /// Reduces cells `[lo, hi)` of the combined slot-then-row index.
    fn reduceBlock(self: *ParEval, lo: u32, hi: u32, comptime mode: Mode) void {
        const pl = self.job_planes;
        if (lo < self.nnz and mode != .charge) {
            const end = @min(hi, self.nnz);
            const bg: []const f64 = if (mode == .newton) self.job_base.g else &.{};
            sumCells(self.slots, lo, end, pl.g_vals, self.g_stage, bg);
            if (self.has_charge) {
                const bc: []const f64 = if (mode == .newton) self.job_base.c else &.{};
                sumCells(self.slots, lo, end, pl.c_vals, self.c_stage, bc);
            }
        }
        if (hi > self.nnz) {
            const r0 = @max(lo, self.nnz) - self.nnz;
            const r1 = hi - self.nnz;
            if (mode != .charge) sumCells(self.rows, r0, r1, pl.rhs, self.rhs_stage, &.{});
            if (self.has_charge) sumCells(self.rows, r0, r1, pl.q_vec, self.q_stage, &.{});
        }
    }
};

/// `plane[i] = base[i] + stage[p0] + stage[p1] + ...` over cell i's
/// positions in tape order, left to right, for cells `[lo, hi)`; an empty
/// `base` is zero. Resets each position read to -0.0 for the next pass.
fn sumCells(gather: Gather, lo: u32, hi: u32, plane: []f64, stage: []f64, base: []const f64) void {
    for (lo..hi) |i| {
        var v: f64 = if (base.len > 0) base[i] else 0;
        for (gather.src[gather.seg[i]..gather.seg[i + 1]]) |p| {
            v += stage[p];
            stage[p] = -0.0;
        }
        plane[i] = v;
    }
}

/// Chunks of about `total / (8 * n_lanes)` instance weight, cut at instance
/// boundaries in ascending order. Caller frees.
fn chunkTasks(gpa: std.mem.Allocator, batches: []const Batch, n_lanes: u32) ![]EvalTask {
    var w_total: u64 = 0;
    for (batches) |b| w_total += @as(u64, b.count) * instanceWeight(b);
    const target = @max(w_total / (@as(u64, chunks_per_lane) * n_lanes), 1);
    var tasks: std.ArrayList(EvalTask) = .empty;
    errdefer tasks.deinit(gpa);
    for (batches, 0..) |b, bi| {
        const w = instanceWeight(b);
        const per: u32 = @intCast(@min(@max(target / w, 1), b.count));
        var pos: u32 = 0;
        while (pos < b.count) : (pos += per)
            try tasks.append(gpa, .{ .batch = @intCast(bi), .first = pos, .last = @min(pos + per, b.count) });
    }
    return tasks.toOwnedSlice(gpa);
}

/// Cut points over the combined slot-then-row cells (`[0, nnz + n)`): blocks
/// of about `total / (8 * n_lanes)` work, a cell weighing 1 plus its
/// positions, cut on 16-cell (128-byte) boundaries so no two blocks write
/// one cache line, with a cut at `nnz`. Caller frees.
fn cutBlocks(gpa: std.mem.Allocator, slot_seg: []const u32, row_seg: []const u32, n_lanes: u32) ![]u32 {
    const nnz: u32 = @intCast(slot_seg.len - 1);
    const n: u32 = @intCast(row_seg.len - 1);
    const total: u64 = @as(u64, nnz) + n + slot_seg[nnz] + row_seg[n];
    const target = @max(total / (@as(u64, chunks_per_lane) * n_lanes), 1);
    var cuts: std.ArrayList(u32) = .empty;
    errdefer cuts.deinit(gpa);
    try cuts.append(gpa, 0);
    for ([_][]const u32{ slot_seg, row_seg }, [_]u32{ 0, nnz }) |seg, off| {
        const len: u32 = @intCast(seg.len - 1);
        var lo: u32 = 0;
        while (lo < len) {
            var hi = lo;
            var w: u64 = 0;
            while (hi < len and w < target) {
                const step = @min(len - hi, block_align);
                w += step + seg[hi + step] - seg[hi];
                hi += step;
            }
            try cuts.append(gpa, off + hi);
            lo = hi;
        }
    }
    std.debug.assert(cuts.last() == nnz + n);
    return cuts.toOwnedSlice(gpa);
}

/// An instance's eval cost estimate: its stamp count `n_u^2`, times 16 for
/// a nonlinear model. With `n_u^2` alone, chain_psp103_10k's lane 0 got all
/// 64,244 capacitors and 241 ms of an eval pass that took the PSP103 lanes
/// 5-7 s: a PSP103 instance costs about 1,000 capacitors, not 36. Only the
/// chunk sizes depend on it, never the results.
fn instanceWeight(b: Batch) u64 {
    // At least 1: the chunking divides by it, and an instance with no
    // unknowns still costs a call.
    const stamps = @max(@as(u64, b.n_u) * b.n_u, 1);
    return if (b.has_const_jacobian) stamps else 16 * stamps;
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

/// Stamp chunks and reduce blocks per lane: enough that a lane on a core
/// half as fast takes about half as many, few enough that claiming costs
/// nothing next to an instance's eval.
const chunks_per_lane = 8;
/// Cells per reduce-block cut: 128 bytes of f64, `std.atomic.cache_line` on
/// x86_64 (adjacent-line prefetch pairs 64-byte lines).
const block_align = 16;

/// Pause-loop iterations a worker spins on `epoch` before it parks: long
/// enough to catch the next pass across a short solve, short enough that a
/// long LU solve does not burn the cores.
const park_spins: u32 = 4096;
const park_yields: u32 = 64;

test "Gather lists each cell's positions in tape order, ground dropped" {
    const gpa = std.testing.allocator;
    // Two batches over 3 cells, trash = 3.
    const tapes = [_][]const u32{ &.{ 2, 0, 3, 2 }, &.{ 0, 2, 1 } };
    const g = try Gather.build(gpa, &tapes, 3, 3);
    defer g.deinit(gpa);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 6 }, g.seg);
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, 6, 0, 3, 5 }, g.src);
}

test "cutBlocks tiles every cell, 16-aligned, with a cut at nnz" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xb10c);
    const rnd = prng.random();
    for ([_]u32{ 0, 1, 15, 16, 17, 200 }) |nnz| for ([_]u32{ 0, 3, 40 }) |n| for ([_]u32{ 1, 3, 24 }) |lanes| {
        const slot_seg = try gpa.alloc(u32, nnz + 1);
        defer gpa.free(slot_seg);
        const row_seg = try gpa.alloc(u32, n + 1);
        defer gpa.free(row_seg);
        for ([_][]u32{ slot_seg, row_seg }) |seg| {
            seg[0] = 0;
            for (1..seg.len) |i| seg[i] = seg[i - 1] + rnd.uintLessThan(u32, 50);
        }
        const cuts = try cutBlocks(gpa, slot_seg, row_seg, lanes);
        defer gpa.free(cuts);
        try std.testing.expectEqual(@as(u32, 0), cuts[0]);
        try std.testing.expectEqual(nnz + n, cuts[cuts.len - 1]);
        try std.testing.expect(std.mem.indexOfScalar(u32, cuts, nnz) != null);
        for (cuts[0 .. cuts.len - 1], cuts[1..]) |a, b| {
            try std.testing.expect(a < b);
            if (b != nnz and b != nnz + n) try std.testing.expectEqual(@as(u32, 0), (if (b < nnz) b else b - nnz) % block_align);
        }
    };
}

test "chunkTasks covers every instance once, in order" {
    const gpa = std.testing.allocator;
    var bs: [3]Batch = undefined;
    for (&bs, [_]u32{ 1000, 0, 7 }, [_]u32{ 2, 3, 12 }) |*b, count, n_u| {
        b.count = count;
        b.n_u = n_u;
        b.has_const_jacobian = n_u == 2;
    }
    for ([_]u32{ 1, 2, 8, 24 }) |lanes| {
        const tasks = try chunkTasks(gpa, &bs, lanes);
        defer gpa.free(tasks);
        var next = [_]u32{ 0, 0, 0 };
        for (tasks) |task| {
            try std.testing.expectEqual(next[task.batch], task.first);
            try std.testing.expect(task.last > task.first);
            next[task.batch] = task.last;
        }
        try std.testing.expectEqualSlices(u32, &.{ 1000, 0, 7 }, &next);
    }
}

test instanceWeight {
    // A zero-unknown batch still weighs 1, so the chunking never divides by 0.
    var b: Batch = undefined;
    b.n_u = 0;
    b.has_const_jacobian = true;
    try std.testing.expectEqual(@as(u64, 1), instanceWeight(b));
    b.n_u = 3;
    try std.testing.expectEqual(@as(u64, 9), instanceWeight(b));
    b.has_const_jacobian = false;
    try std.testing.expectEqual(@as(u64, 144), instanceWeight(b));
}
