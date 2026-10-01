//! The device LU, stage 1 of docs/solvers/gpu-lu.md: the host assembles A,
//! keeps every pivot decision and uploads the values; the device replays
//! the refactor and runs both triangular solves (`solver.lu_kernels`), and
//! dx comes back. Bitwise the host's `refactor` plus `solveNeg`, so a device
//! pivot failure peels to the host's full factor as if the host had run
//! the refactor itself.

const std = @import("std");
const gompute = @import("gompute");
const solver = @import("solver");
const numerics = @import("core").numerics;

const K = solver.lu_kernels;
const direct = solver.direct;
const fast_lu = solver.fast_lu;

const artifacts = @import("gompute_kernels");
const backend: ?gompute.Backend = if (artifacts.has_cuda) .cuda else if (artifacts.has_hip) .hip else null;
const Raw = if (backend) |be| gompute.RawByName(be) else void;
const Buffer = if (backend != null) Raw.Buffer else void;
const Stream = if (backend != null) Raw.Stream else void;
const Event = if (backend != null) Raw.Event else void;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn envOn(name: [*:0]const u8) bool {
    return std.c.getenv(name) != null;
}

/// Per-query device LU context: kernels, a stream, the per-iteration
/// buffers, and the tables of the current pivot epoch.
pub const GpuLu = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    n: u32,
    nnz: u32,
    k_ref: Raw,
    k_ls: Raw,
    k_us: Raw,
    /// The f32 kernels of `fast_mode`.
    k32: [3]Raw,
    stream: Stream,
    pin_a: []f64,
    pin_rhs: []f64,
    pin_dx: []f64,
    pin_fail: []u8,
    d_a: Buffer,
    d_rhs: Buffer,
    d_y: Buffer,
    d_dx: Buffer,

    /// `SparseLu.pattern_epoch` the tables below were built from; 0 = none.
    epoch: u32 = 0,
    /// This epoch's tables were too big (or failed to upload).
    declined: bool = true,
    tab: K.Tab = undefined,
    d_idx: Buffer = undefined,
    d_val: Buffer = undefined,
    d_sync: Buffer = undefined,
    /// Host copy of the tables, kept for `ESPICE_GPU_LU_BENCH`'s host runs.
    idx: []u32 = &.{},
    flops: u64 = 0,
    /// Done-stamp value of the next launch; grows by one per call.
    stamp: u32 = 0,
    /// `direct.Solver.gen` whose factors the device holds, if any.
    dev_gen: ?u32 = null,
    /// A driver call failed: the rest of the query solves on the host.
    poisoned: bool = false,
    check: bool,
    bench: ?*Bench = null,
    /// `fast_mode`: the f64 side of the refined solve, and whether the
    /// device's f32 factors (in `d_val`) match `ref.fa`.
    ref: ?fast_lu.Refiner = null,
    valid32: bool = false,
    bneg: []f64 = &.{},
    st: struct { calls: u64 = 0, refactors: u64 = 0, peels: u64 = 0, epochs: u64 = 0, mismatches: u64 = 0 } = .{},

    /// Loads the three kernels and allocates the per-iteration buffers for an
    /// n-unknown, nnz-entry pattern. Fails when this build has no kernels or
    /// the driver refuses. Caller owns the result; free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, n: u32, nnz: u32) !*Self {
        if (comptime backend == null) return error.NoGpuArtifacts;
        const be = backend.?;
        var k_ref = try gompute.rawKernelByName(be, "arp_lu_refactor", 0);
        errdefer k_ref.deinit();
        var k_ls = try gompute.rawKernelByName(be, "arp_lu_lsolve", 0);
        errdefer k_ls.deinit();
        var k_us = try gompute.rawKernelByName(be, "arp_lu_usolve", 0);
        errdefer k_us.deinit();
        var k32: [3]Raw = undefined;
        var n32: usize = 0;
        errdefer for (k32[0..n32]) |*k| k.deinit();
        for ([_][]const u8{ "arp_lu_refactor_f32", "arp_lu_lsolve_f32", "arp_lu_usolve_f32" }, &k32) |name, *k| {
            k.* = try gompute.rawKernelByName(be, name, 0);
            n32 += 1;
        }
        const pin_a = try pinnedF64(&k_ref, nnz);
        errdefer k_ref.freePinned(std.mem.sliceAsBytes(pin_a));
        const pin_rhs = try pinnedF64(&k_ref, n);
        errdefer k_ref.freePinned(std.mem.sliceAsBytes(pin_rhs));
        const pin_dx = try pinnedF64(&k_ref, n);
        errdefer k_ref.freePinned(std.mem.sliceAsBytes(pin_dx));
        const pin_fail = try k_ref.allocPinned(4);
        errdefer k_ref.freePinned(pin_fail);
        var d_a = try k_ref.alloc(@max(nnz, 1) * 8);
        errdefer d_a.free();
        var d_rhs = try k_ref.alloc(@max(n, 1) * 8);
        errdefer d_rhs.free();
        var d_y = try k_ref.alloc(@max(n, 1) * 8);
        errdefer d_y.free();
        var d_dx = try k_ref.alloc(@max(n, 1) * 8);
        errdefer d_dx.free();
        var stream = try k_ref.createStream();
        errdefer stream.deinit();
        const self = try gpa.create(Self);
        self.* = .{
            .gpa = gpa,
            .n = n,
            .nnz = nnz,
            .k_ref = k_ref,
            .k_ls = k_ls,
            .k_us = k_us,
            .k32 = k32,
            .stream = stream,
            .pin_a = pin_a,
            .pin_rhs = pin_rhs,
            .pin_dx = pin_dx,
            .pin_fail = pin_fail,
            .d_a = d_a,
            .d_rhs = d_rhs,
            .d_y = d_y,
            .d_dx = d_dx,
            .check = envOn("ESPICE_GPU_LU_CHECK"),
        };
        if (envOn("ESPICE_GPU_LU_BENCH")) self.bench = Bench.init(gpa, &self.k_ref) catch null;
        return self;
    }

    /// True when the device's FP64 runs at least 1/4 of its FP32 rate (a
    /// data-center card), the bar for `auto` to keep the device LU. A
    /// driver that cannot say (HIP today) counts as slow.
    pub fn fp64Fast(self: *Self) bool {
        const ratio = self.k_ref.context.fp64Ratio() catch return false;
        return ratio <= 4;
    }

    fn pinnedF64(k: *Raw, n: usize) ![]f64 {
        const bytes = try k.allocPinned(@max(n, 1) * @sizeOf(f64));
        return @as([*]f64, @ptrCast(@alignCast(bytes.ptr)))[0..n];
    }

    /// Prints the `ESPICE_GPU_STATS`/check/bench summary, then frees every
    /// device and pinned buffer and `self`.
    pub fn deinit(self: *Self) void {
        if (comptime backend == null) return;
        if (envOn("ESPICE_GPU_STATS") or self.check or self.bench != null) std.debug.print(
            "gpu-lu: calls={d} refactors={d} peels={d} epochs={d} F={d} check_mismatches={d}{s}\n",
            .{ self.st.calls, self.st.refactors, self.st.peels, self.st.epochs, self.flops, self.st.mismatches, if (self.check) "" else " (unchecked)" },
        );
        if (self.bench) |b| b.deinit(self);
        self.dropTables();
        const k = &self.k_ref;
        for ([_][]f64{ self.pin_a, self.pin_rhs, self.pin_dx }) |p| k.freePinned(@as([*]u8, @ptrCast(p.ptr))[0 .. @max(p.len, 1) * 8]);
        k.freePinned(self.pin_fail);
        for ([_]*Buffer{ &self.d_a, &self.d_rhs, &self.d_y, &self.d_dx }) |b| b.free();
        self.stream.deinit();
        if (self.ref) |*r| {
            if (envOn("ESPICE_LU_FAST_STATS")) {
                const st = r.stats;
                std.debug.print("gpu-lu-fast: refactors={d} refactor_fails={d} solves={d} iterations={d} gmres={d} fallbacks={d}\n", .{ st.refactors, st.refactor_fails, st.solves, st.iterations, st.gmres, st.fallbacks });
            }
            r.deinit(self.gpa);
        }
        self.gpa.free(self.bneg);
        for (&self.k32) |*kk| kk.deinit();
        self.k_us.deinit();
        self.k_ls.deinit();
        self.k_ref.deinit();
        self.gpa.destroy(self);
    }

    fn dropTables(self: *Self) void {
        if (self.epoch != 0 and !self.declined) {
            self.d_idx.free();
            self.d_val.free();
            self.d_sync.free();
        }
        self.gpa.free(self.idx);
        self.idx = &.{};
    }

    /// `Circuit.deviceSolve`'s body: dx = -A^-1 rhs on the device, with
    /// `need` false when the caller knows the matrix is unchanged. Null
    /// when the device did not try (no general LU yet, a declined epoch,
    /// factors it does not hold); false when it tried and the host's exact
    /// factor and solve must run: a device pivot failure (which clears
    /// `slv.factored`, so the host goes straight to the full factor its own
    /// refactor would have fallen back to) or a failed fast solve.
    pub fn solve(ctx: *anyopaque, slv: *direct.Solver, vals: []const f64, rhs: []const f64, dx: []f64, need: bool) ?bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.poisoned) return null;
        return self.trySolve(slv, vals, rhs, dx, need) catch |e| {
            std.debug.print("warning: device LU off for this query ({s})\n", .{@errorName(e)});
            self.poisoned = true;
            self.dev_gen = null;
            return null;
        };
    }

    fn trySolve(self: *Self, slv: *direct.Solver, vals: []const f64, rhs: []const f64, dx: []f64, need: bool) !?bool {
        if (comptime backend == null) return null;
        const lu = if (slv.lu) |*l| l else return null;
        if (slv.tri != null or slv.bbd_eng != null or !slv.factored or !lu.factored) return null;
        // Tape-sized factors refactor in microseconds on the host.
        if (lu.tv.items.len != 0) return null;
        if (self.epoch != lu.pattern_epoch) try self.load(slv);
        if (self.declined) return null;
        if (slv.params.fast_mode) return try self.fastSolve(slv, vals, rhs, dx, need);
        const refactor = need and !slv.unchanged(vals);
        if (!refactor and self.dev_gen != slv.gen) return null;
        if (refactor) for (lu.void_slots.items) |p| {
            if (vals[p] != 0) return null;
        };

        const n = self.n;
        self.st.calls += 1;
        self.stamp +%= 1;
        const t0 = if (self.bench != null) nowNs() else 0;
        if (refactor) {
            @memcpy(self.pin_a, vals[0..self.nnz]);
            try self.d_a.uploadAtAsync(self.pin_a.ptr, 0, self.nnz * 8, &self.stream);
        }
        @memcpy(self.pin_rhs, rhs[0..n]);
        try self.d_rhs.uploadAtAsync(self.pin_rhs.ptr, 0, n * 8, &self.stream);
        try self.d_sync.fillAsync(0, K.sync_header * 4, &self.stream);
        if (self.bench) |b| try b.ev[0].record(&self.stream);
        var tab = self.tab;
        var stamp = self.stamp;
        if (refactor) try self.k_ref.launchOn(&self.stream, .{ .x = n }, .{ .x = K.refactor_block }, 0, &.{
            gompute.interface.arg(&tab), self.d_idx.argPtr(), self.d_val.argPtr(), self.d_a.argPtr(), self.d_sync.argPtr(), gompute.interface.arg(&stamp),
        });
        if (self.bench) |b| try b.ev[1].record(&self.stream);
        try self.k_ls.launchOn(&self.stream, .{ .x = 1 }, .{ .x = K.solve_block }, 0, &.{
            gompute.interface.arg(&tab), self.d_idx.argPtr(), self.d_val.argPtr(), self.d_rhs.argPtr(), self.d_y.argPtr(), self.d_sync.argPtr(),
        });
        if (self.bench) |b| try b.ev[2].record(&self.stream);
        try self.k_us.launchOn(&self.stream, .{ .x = 1 }, .{ .x = K.solve_block }, 0, &.{
            gompute.interface.arg(&tab), self.d_idx.argPtr(), self.d_val.argPtr(), self.d_y.argPtr(), self.d_dx.argPtr(), self.d_sync.argPtr(),
        });
        if (self.bench) |b| try b.ev[3].record(&self.stream);
        try self.d_dx.downloadAtAsync(self.pin_dx.ptr, 0, n * 8, &self.stream);
        try self.d_sync.downloadAtAsync(self.pin_fail.ptr, 4, 4, &self.stream);
        try self.stream.synchronize();
        const t1 = if (self.bench != null) nowNs() else 0;

        if (std.mem.bytesToValue(u32, self.pin_fail[0..4]) != 0) {
            // The lowest failing step: every step below it matched the host,
            // so the host refactor fails there too. Skip it.
            self.st.peels += 1;
            self.dev_gen = null;
            slv.factored = false;
            return false;
        }
        if (refactor) {
            self.st.refactors += 1;
            @memcpy(slv.vcopy, vals[0..self.nnz]);
            slv.gen +%= 1;
            slv.host_stale = true;
            self.dev_gen = slv.gen;
        }
        @memcpy(dx[0..n], self.pin_dx);
        if (self.check and refactor) try self.checkAgainstHost(slv, rhs, dx);
        if (self.bench) |b| if (refactor) try b.sample(self, slv, vals, rhs, t1 - t0);
        return true;
    }

    /// `fast_mode` on the device: the f32 kernels refactor R A C on the
    /// same tables (into `d_val`, which the f64 path will refill) and give
    /// the corrections of a refined solve. False when the host's exact
    /// pair must run.
    fn fastSolve(self: *Self, slv: *direct.Solver, vals: []const f64, rhs: []const f64, dx: []f64, need: bool) !bool {
        const n = self.n;
        const lu = &slv.lu.?;
        if (self.ref == null) {
            self.ref = try fast_lu.Refiner.init(self.gpa, n, slv.col_ptr, slv.row_idx);
            self.bneg = try self.gpa.alloc(f64, n);
        }
        const ref = &self.ref.?;
        self.dev_gen = null; // d_val stops holding f64 factors
        if (!self.valid32 or (need and !std.mem.eql(u8, std.mem.sliceAsBytes(ref.fa), std.mem.sliceAsBytes(vals[0..self.nnz])))) {
            self.valid32 = false;
            ref.stats.refactors += 1;
            for (lu.void_slots.items) |p| {
                if (vals[p] != 0) return fast32Failed(ref);
            }
            const a32 = @as([*]f32, @ptrCast(self.pin_a.ptr))[0..self.nnz];
            if (!ref.load(vals, a32)) return fast32Failed(ref);
            try self.d_a.uploadAtAsync(a32.ptr, 0, self.nnz * 4, &self.stream);
            try self.d_sync.fillAsync(0, K.sync_header * 4, &self.stream);
            self.stamp +%= 1;
            var tab = self.tab;
            tab.growth = fast_lu.growth_f32;
            var stamp = self.stamp;
            try self.k32[0].launchOn(&self.stream, .{ .x = n }, .{ .x = K.refactor_block }, 0, &.{
                gompute.interface.arg(&tab), self.d_idx.argPtr(), self.d_val.argPtr(), self.d_a.argPtr(), self.d_sync.argPtr(), gompute.interface.arg(&stamp),
            });
            try self.d_sync.downloadAtAsync(self.pin_fail.ptr, 4, 4, &self.stream);
            try self.stream.synchronize();
            if (std.mem.bytesToValue(u32, self.pin_fail[0..4]) != 0) return fast32Failed(ref);
            self.valid32 = true;
        }
        numerics.scale(self.bneg, -1, rhs[0..n]);
        return ref.solve(self.gpa, self, self.bneg, dx);
    }

    fn fast32Failed(ref: *fast_lu.Refiner) bool {
        ref.stats.refactor_fails += 1;
        return false;
    }

    /// One correction of `fastSolve`'s refinement: dx32 = -(R A C)^-1 r32
    /// through the device's f32 factors. A driver fault poisons the
    /// context and returns NaN, which fails the refinement.
    pub fn apply(self: *Self, r32: []const f32, dx32: []f32) void {
        self.apply32(r32, dx32) catch {
            self.poisoned = true;
            @memset(dx32, std.math.nan(f32));
        };
    }

    fn apply32(self: *Self, r32: []const f32, dx32: []f32) !void {
        const n = self.n;
        const pr = @as([*]f32, @ptrCast(self.pin_rhs.ptr))[0..n];
        const pd = @as([*]f32, @ptrCast(self.pin_dx.ptr))[0..n];
        @memcpy(pr, r32);
        try self.d_rhs.uploadAtAsync(pr.ptr, 0, n * 4, &self.stream);
        var tab = self.tab;
        try self.k32[1].launchOn(&self.stream, .{ .x = 1 }, .{ .x = K.solve_block }, 0, &.{
            gompute.interface.arg(&tab), self.d_idx.argPtr(), self.d_val.argPtr(), self.d_rhs.argPtr(), self.d_y.argPtr(), self.d_sync.argPtr(),
        });
        try self.k32[2].launchOn(&self.stream, .{ .x = 1 }, .{ .x = K.solve_block }, 0, &.{
            gompute.interface.arg(&tab), self.d_idx.argPtr(), self.d_val.argPtr(), self.d_y.argPtr(), self.d_dx.argPtr(), self.d_sync.argPtr(),
        });
        try self.d_dx.downloadAtAsync(pd.ptr, 0, n * 4, &self.stream);
        try self.stream.synchronize();
        @memcpy(dx32, pd);
    }

    /// Builds and uploads the tables of `slv`'s current pivot epoch, or
    /// declines it (`declined`) past `max_flops`.
    fn load(self: *Self, slv: *direct.Solver) !void {
        const lu = &slv.lu.?;
        self.dropTables();
        self.epoch = lu.pattern_epoch;
        self.declined = true;
        self.dev_gen = null;
        self.valid32 = false;
        var flops: u64 = 0;
        for (lu.ui.items) |i| flops += lu.lp[i + 1] - lu.lp[i];
        self.flops = flops;
        if (flops > max_flops) return;
        // E2 calibration knobs: ESPICE_GPU_LU_TAIL=m fixes the solves' tail
        // at m steps, ESPICE_GPU_LU_NOGATHER keeps every column in stored
        // order.
        var opt: K.Options = .{ .gather = !envOn("ESPICE_GPU_LU_NOGATHER") };
        if (std.c.getenv("ESPICE_GPU_LU_TAIL")) |v| opt.tail = lu.n - @min(lu.n, std.fmt.parseInt(u32, std.mem.span(v), 10) catch 0);
        var tb = try K.build(self.gpa, lu, slv.col_ptr, slv.params.refactor_growth_limit, opt);
        defer tb.deinit(self.gpa);
        self.tab = tb.tab;
        self.d_idx = try self.k_ref.alloc(@as(usize, tb.tab.n_idx) * 4);
        errdefer self.d_idx.free();
        try self.d_idx.upload(tb.idx.ptr, @as(usize, tb.tab.n_idx) * 4);
        self.d_val = try self.k_ref.alloc(@as(usize, tb.tab.n_val) * 8);
        errdefer self.d_val.free();
        self.d_sync = try self.k_ref.alloc(@as(usize, tb.tab.syncLen()) * 4);
        errdefer self.d_sync.free();
        try self.d_sync.fillAsync(0, @as(usize, tb.tab.syncLen()) * 4, &self.stream);
        self.stamp = 0;
        if (self.bench != null) self.idx = try self.gpa.dupe(u32, tb.idx);
        self.declined = false;
        self.st.epochs += 1;
    }

    /// The epoch's tables cost 4 bytes per flop on both sides of the bus.
    /// ponytail: a fixed 1.6 GB of `dmap`; price it against free device
    /// memory if a deck between that and the card's size shows up.
    const max_flops = 400_000_000;

    /// `ESPICE_GPU_LU_CHECK`: refactors and solves on the host from the same
    /// values and compares the factors and dx bitwise, printing the first
    /// mismatch. Leaves the host factors current.
    fn checkAgainstHost(self: *Self, slv: *direct.Solver, rhs: []const f64, dx: []const f64) !void {
        const lu = &slv.lu.?;
        const t = self.tab;
        const val = try self.gpa.alloc(f64, t.n_val);
        defer self.gpa.free(val);
        try self.d_val.download(val.ptr, @as(usize, t.n_val) * 8);
        const ref = try self.gpa.alloc(f64, self.n);
        defer self.gpa.free(ref);
        // solveNeg syncs the host factors from vcopy first.
        slv.solveNeg(rhs, ref);
        var bad: ?[]const u8 = null;
        var where: usize = 0;
        var off: u32 = 0;
        for (0..self.n) |k| {
            const nuk = lu.up[k + 1] - lu.up[k];
            const nlk = lu.lp[k + 1] - lu.lp[k];
            const col = val[off..][0 .. nuk + 1 + nlk];
            off += nuk + 1 + nlk;
            if (!std.mem.eql(u8, std.mem.sliceAsBytes(col[0..nuk]), std.mem.sliceAsBytes(lu.ux.items[lu.up[k]..lu.up[k + 1]])) or
                @as(u64, @bitCast(col[nuk])) != @as(u64, @bitCast(lu.udiag[k])) or
                !std.mem.eql(u8, std.mem.sliceAsBytes(col[nuk + 1 ..]), std.mem.sliceAsBytes(lu.lx.items[lu.lp[k]..lu.lp[k + 1]])))
            {
                bad = "factor column";
                where = k;
                break;
            }
        }
        if (bad == null) for (dx, ref, 0..) |a, b, i| {
            if (@as(u64, @bitCast(a)) != @as(u64, @bitCast(b))) {
                bad = "dx";
                where = i;
                break;
            }
        };
        if (bad) |what| {
            self.st.mismatches += 1;
            if (self.st.mismatches <= 3) std.debug.print("gpu-lu check: {s} {d} differs from the host (refactor {d})\n", .{ what, where, self.st.refactors });
        }
    }
};

/// `ESPICE_GPU_LU_BENCH` (E2): after each device refactor, times the same
/// refactor and solve on the host (`SparseLu`, one thread) and with the
/// kernel bodies on 1 and `ESPICE_GPU_LU_THREADS` (default 8) host threads,
/// against the device kernels by event timing. Prints medians at teardown,
/// or after N samples for `ESPICE_GPU_LU_BENCH=N` (then stops sampling).
const Bench = struct {
    ev: [4]Event,
    threads: u32,
    limit: usize = 0,
    /// Microseconds per sample: device refactor kernel, device solve
    /// kernels, device call wall (upload to download), host SparseLu
    /// refactor, host solve, kernel bodies on 1 thread, on `threads`.
    s: [8]std.ArrayList(f64) = @splat(.empty),
    val: []f64 = &.{},
    y: []f64 = &.{},
    dx: []f64 = &.{},
    sync: []u32 = &.{},
    stamp: u32 = 0,
    /// `GpuLu.st.epochs` the buffers above are sized for.
    epoch: u64 = 0,

    fn init(gpa: std.mem.Allocator, k: *Raw) !*Bench {
        if (!k.hasEvents()) return error.Unsupported;
        const b = try gpa.create(Bench);
        b.* = .{ .ev = undefined, .threads = 8 };
        if (std.c.getenv("ESPICE_GPU_LU_THREADS")) |v| b.threads = std.fmt.parseInt(u32, std.mem.span(v), 10) catch 8;
        if (std.c.getenv("ESPICE_GPU_LU_BENCH")) |v| b.limit = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
        for (&b.ev) |*e| e.* = try k.createEvent(true);
        return b;
    }

    fn sample(b: *Bench, lu_ctx: *GpuLu, slv: *direct.Solver, vals: []const f64, rhs: []const f64, wall_ns: u64) !void {
        const gpa = lu_ctx.gpa;
        const t = lu_ctx.tab;
        if (b.limit != 0 and b.s[0].items.len >= b.limit) return;
        defer if (b.limit != 0 and b.s[0].items.len == b.limit) b.report(lu_ctx);
        if (b.epoch != lu_ctx.st.epochs) {
            for ([_][]f64{ b.val, b.y, b.dx }) |p| gpa.free(p);
            gpa.free(b.sync);
            b.val = try gpa.alloc(f64, t.n_val);
            b.y = try gpa.alloc(f64, t.n);
            b.dx = try gpa.alloc(f64, t.n);
            b.sync = try gpa.alloc(u32, t.syncLen());
            @memset(b.sync, 0);
            b.epoch = lu_ctx.st.epochs;
        }
        try b.s[0].append(gpa, try Event.elapsedUs(&b.ev[0], &b.ev[1]));
        try b.s[1].append(gpa, try Event.elapsedUs(&b.ev[1], &b.ev[3]));
        try b.s[7].append(gpa, try Event.elapsedUs(&b.ev[1], &b.ev[2]));
        try b.s[2].append(gpa, @as(f64, @floatFromInt(wall_ns)) * 1e-3);
        const lu = &slv.lu.?;
        var t0 = nowNs();
        try lu.refactor(slv.col_ptr, vals, slv.params.refactor_growth_limit);
        var t1 = nowNs();
        try b.s[3].append(gpa, @as(f64, @floatFromInt(t1 - t0)) * 1e-3);
        const neg = b.dx; // scratch until the kernel runs below
        numerics.scale(neg, -1, rhs[0..t.n]);
        t0 = nowNs();
        lu.solve(neg, neg);
        t1 = nowNs();
        try b.s[4].append(gpa, @as(f64, @floatFromInt(t1 - t0)) * 1e-3);
        slv.host_stale = false; // the refactor above brought lu to vcopy
        const bufs: K.HostBufs = .{ .idx = lu_ctx.idx, .val = b.val, .a = vals, .rhs = rhs, .y = b.y, .dx = b.dx, .sync = b.sync };
        for ([_]u32{ 1, b.threads }, 5..) |th, slot| {
            b.stamp += 1;
            t0 = nowNs();
            _ = try K.runHost(t, bufs, b.stamp, th);
            t1 = nowNs();
            try b.s[slot].append(gpa, @as(f64, @floatFromInt(t1 - t0)) * 1e-3);
        }
    }

    fn report(b: *Bench, lu_ctx: *GpuLu) void {
        const names = [_][]const u8{ "dev_refactor", "dev_solves", "dev_call_wall", "host_refactor", "host_solve", "kern_1thr", "kern_nthr", "dev_lsolve" };
        const t = lu_ctx.tab;
        const x = lu_ctx.idx;
        var wide: u32 = 0;
        for (0..t.n) |k| wide += @intFromBool(x[t.wlev + k] != x[t.wlev + k + 1]);
        // Head span: per level, the longest row list.
        var chains: [2]u64 = .{ 0, 0 };
        for ([_][3]u32{ .{ t.l_levels, t.l_lev, t.l_rows }, .{ t.u_levels, t.u_lev, t.u_rows } }, [_]u32{ t.l_ptr, t.u_ptr }, 0..) |lv, ptr, side| {
            for (0..lv[0]) |v| {
                var mx: u32 = 0;
                for (x[lv[1] + v]..x[lv[1] + v + 1]) |j| {
                    const r = x[lv[2] + j];
                    mx = @max(mx, x[ptr + r + 1] - x[ptr + r]);
                }
                chains[side] += mx;
            }
        }
        std.debug.print("gpu-lu-bench: n={d} F={d} l_levels={d} u_levels={d} head_chain={d}+{d} tail={d} gather_cols={d} samples={d} threads={d} checked={d} mismatches={d} (median us)", .{ lu_ctx.n, lu_ctx.flops, t.l_levels, t.u_levels, chains[0], chains[1], t.n - t.t0, wide, b.s[0].items.len, b.threads, if (lu_ctx.check) lu_ctx.st.refactors else 0, lu_ctx.st.mismatches });
        for (&b.s, names) |*s, name| {
            std.mem.sort(f64, s.items, {}, std.sort.asc(f64));
            const m = if (s.items.len == 0) 0 else s.items[s.items.len / 2];
            std.debug.print(" {s}={d:.1}", .{ name, m });
        }
        std.debug.print("\n", .{});
    }

    fn deinit(b: *Bench, lu_ctx: *GpuLu) void {
        const gpa = lu_ctx.gpa;
        if (b.limit == 0 or b.s[0].items.len < b.limit) b.report(lu_ctx);
        for (&b.s) |*s| s.deinit(gpa);
        for ([_][]f64{ b.val, b.y, b.dx }) |p| gpa.free(p);
        gpa.free(b.sync);
        for (&b.ev) |*e| e.deinit();
        gpa.destroy(b);
    }
};
