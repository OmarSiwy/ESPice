//! Circuit pattern, plane-kernel, stamp and lifecycle tests.

const impl = @import("../Circuit.zig");
const combinePlanes = impl.combinePlanes;
const std = @import("std");

test "pattern CSC matches comparison sort across radix digits" {
    const PatternBuilder = @import("device").abi.PatternBuilder;
    const gpa = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0x5041545445524e);
    for ([_]u32{ 1, 31, 65537, 131073 }) |n| {
        for ([_]usize{ 0, 1, 63, 64, 65, 257 }) |count| {
            var pattern: PatternBuilder = .{};
            defer pattern.deinit(gpa);
            var unique = std.AutoHashMap(u64, void).init(gpa);
            defer unique.deinit();
            var previous: u64 = 0;
            for (0..count) |i| {
                const row = if (i % 7 == 0) n - 1 else random.random().intRangeLessThan(u32, 0, n);
                const occupied_columns = [_]u32{ n - 1, 0, n / 2 };
                const col = occupied_columns[i % occupied_columns.len];
                const key = if (i % 4 == 1) previous else (@as(u64, col) << 32) | row;
                try pattern.add(gpa, @truncate(key), @intCast(key >> 32));
                try unique.put(key, {});
                previous = key;
            }
            const expected = try gpa.alloc(u64, unique.count());
            defer gpa.free(expected);
            var keys = unique.keyIterator();
            for (expected) |*key| key.* = keys.next().?.*;
            std.mem.sortUnstable(u64, expected, {}, std.sort.asc(u64));

            var col_ptr: []u32 = undefined;
            var row_idx: []u32 = undefined;
            const nnz = try pattern.toCsc(gpa, gpa, n, &col_ptr, &row_idx);
            defer gpa.free(col_ptr);
            defer gpa.free(row_idx);
            try std.testing.expectEqual(@as(u32, @intCast(expected.len)), nnz);
            try std.testing.expectEqual(expected.len, row_idx.len);
            try std.testing.expectEqual(@as(usize, n) + 1, col_ptr.len);
            try std.testing.expectEqual(@as(u32, 0), col_ptr[0]);
            var p: usize = 0;
            for (0..n) |col| {
                while (p < expected.len and expected[p] >> 32 == col) : (p += 1) {
                    try std.testing.expectEqual(@as(u32, @truncate(expected[p])), row_idx[p]);
                }
                try std.testing.expectEqual(@as(u32, @intCast(p)), col_ptr[col + 1]);
            }
            try std.testing.expectEqual(expected.len, p);
        }
    }
}

test "combined circuit planes match W=1 with tails and aliased output" {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    var random = std.Random.DefaultPrng.init(0x4321);
    var g: [3 * W + 1]f64 = undefined;
    var c: [g.len]f64 = undefined;
    var actual: [g.len]f64 = undefined;
    var expected: [g.len]f64 = undefined;
    for (0..g.len + 1) |n| {
        for (&g, &c) |*gv, *cv| {
            gv.* = random.random().float(f64) - 0.5;
            cv.* = random.random().float(f64) - 0.5;
        }
        for ([_]f64{ 0, -1, 0.125, 1e12 }) |alpha| {
            combinePlanes(1, expected[0..n], g[0..n], c[0..n], alpha);
            combinePlanes(W, actual[0..n], g[0..n], c[0..n], alpha);
            try std.testing.expectEqualSlices(f64, expected[0..n], actual[0..n]);
            @memcpy(actual[0..n], g[0..n]);
            combinePlanes(W, actual[0..n], actual[0..n], c[0..n], alpha);
            try std.testing.expectEqualSlices(f64, expected[0..n], actual[0..n]);
        }
    }
}

const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const Prepared = @import("device").Circuit;
const models = @import("models");
const types = @import("../types.zig");
const ParEval = @import("../par_eval.zig").ParEval;
const t = std.testing;

/// 1 V into `stages` sections of series R, each with a C and a diode to
/// ground: constant-Jacobian, charge and nonlinear batches in one pattern.
fn ladder(lib: *const Library, stages: usize) !Prepared {
    var b = try Builder.init(t.allocator, lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", .{ .dc = 1 }, .{}, .{ vin, types.GROUND });
    var prev = vin;
    for (0..stages) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", .{ .r = 1e3 }, .{}, .{ prev, mid });
        try b.addDevice(models.capacitor, "", .{ .c = 1e-9 }, .{}, .{ mid, types.GROUND });
        try b.addDevice(models.diode, "", .{ .is = 1e-14, .cjo = 1e-12 }, .{}, .{ mid, types.GROUND });
        prev = mid;
    }
    return b.compile();
}

/// A state with every row distinct and the diodes forward-biased.
fn ramp(gpa: std.mem.Allocator, n: u32) ![]f64 {
    const x = try gpa.alloc(f64, n);
    for (x, 0..) |*v, i| v.* = 0.05 * @as(f64, @floatFromInt(i));
    x[types.GROUND] = 0;
    return x;
}

/// Equal up to reassociation of a few stamps per cell.
fn expectClose(expected: []const f64, actual: []const f64) !void {
    try t.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try t.expectApproxEqAbs(e, a, 1e-12 * (1 + @abs(e)));
}

test "a Newton stamp seeded from the baseline equals a full stamp" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 3);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const nnz = ckt.nnz;
    const n = ckt.n;

    ckt.eval(x, 0);
    const g = try t.allocator.dupe(f64, ckt.g_vals[0..nnz]);
    defer t.allocator.free(g);
    const c = try t.allocator.dupe(f64, ckt.c_vals[0..nnz]);
    defer t.allocator.free(c);
    const rhs = try t.allocator.dupe(f64, ckt.rhs[0..n]);
    defer t.allocator.free(rhs);
    const q = try t.allocator.dupe(f64, ckt.q_vec[0..n]);
    defer t.allocator.free(q);

    try ckt.computeBaseline();
    try t.expect(ckt.has_baseline);
    try t.expect(!ckt.q_fresh);
    ckt.evalNewton(x, 0);
    try expectClose(g, ckt.g_vals[0..nnz]);
    try expectClose(c, ckt.c_vals[0..nnz]);
    try expectClose(rhs, ckt.rhs[0..n]);
    try expectClose(q, ckt.q_vec[0..n]);
    // A second baseline is a no-op that leaves the planes alone.
    try ckt.computeBaseline();
    try expectClose(g, ckt.g_vals[0..nnz]);
}

test "threaded stamps match the serial stamp and repeat bit for bit" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 6);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const nnz = ckt.nnz;
    const n = ckt.n;

    ckt.eval(x, 0);
    const g = try t.allocator.dupe(f64, ckt.g_vals[0..nnz]);
    defer t.allocator.free(g);
    const rhs = try t.allocator.dupe(f64, ckt.rhs[0..n]);
    defer t.allocator.free(rhs);
    const q = try t.allocator.dupe(f64, ckt.q_vec[0..n]);
    defer t.allocator.free(q);
    // Serial charge-only stamp: bit for bit what `eval` left.
    ckt.evalQ(x, 0);
    try t.expectEqualSlices(f64, q, ckt.q_vec[0..n]);
    ckt.evalNewton(x, 0);
    const g_newton = try t.allocator.dupe(f64, ckt.g_vals[0..nnz]);
    defer t.allocator.free(g_newton);

    // 0 asks for one lane; 24 is more lanes than the 19 instances.
    for ([_]u32{ 0, 1, 2, 3, 5, 8, 24 }) |lanes| {
        var par = try ParEval.init(t.allocator, t.io, ckt.batches, nnz, n, ckt.has_charge, ckt.trash_slot, lanes);
        defer par.deinit();
        ckt.par_eval = &par;
        defer ckt.par_eval = null;

        ckt.eval(x, 0);
        try expectClose(g, ckt.g_vals[0..nnz]);
        try expectClose(rhs, ckt.rhs[0..n]);
        try expectClose(q, ckt.q_vec[0..n]);
        const g1 = try t.allocator.dupe(f64, ckt.g_vals);
        defer t.allocator.free(g1);
        const q1 = try t.allocator.dupe(f64, ckt.q_vec[0..n]);
        defer t.allocator.free(q1);
        // Deterministic at a fixed lane count, and the lane slabs come back
        // clean: a second pass adds nothing stale.
        ckt.eval(x, 0);
        try t.expectEqualSlices(f64, g1, ckt.g_vals);
        ckt.evalQ(x, 0);
        try t.expectEqualSlices(f64, q1, ckt.q_vec[0..n]);
        ckt.evalNewton(x, 0);
        try expectClose(g_newton, ckt.g_vals[0..nnz]);
    }
}

test "linearize reuses the planes only for the same x_op until a writer runs" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    const y = try t.allocator.dupe(f64, x);
    defer t.allocator.free(y);
    const slot = ckt.diag_slots[1];

    ckt.linearize(x);
    try t.expect(ckt.lin.valid);
    const stamped = ckt.g_vals[slot];
    ckt.g_vals[slot] = 12345;
    ckt.linearize(x);
    try t.expectEqual(@as(f64, 12345), ckt.g_vals[slot]);
    // Same values, different slice: a different x_op, so it re-stamps.
    ckt.linearize(y);
    try t.expectEqual(stamped, ckt.g_vals[slot]);

    ckt.linearize(y);
    ckt.eval(y, 0);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.evalQ(y, 0);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.evalNewton(y, 0);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.setCircuitTemp(50);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    try ckt.recompute();
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    try ckt.recomputeType(ckt.batch_types[0]);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.applyAttempt(0.5);
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.restoreModels();
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.beginSolve();
    try t.expect(!ckt.lin.valid);
    ckt.linearize(y);
    ckt.advanceIteration(y);
    try t.expect(!ckt.lin.valid);
    const saved = try ckt.saveState(t.allocator);
    defer saved.deinit(t.allocator);
    ckt.linearize(y);
    ckt.restoreState(saved);
    try t.expect(!ckt.lin.valid);
}

test "combineGC, gcAt, denseG and findSlot agree on every pattern entry" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, ckt.n);
    defer t.allocator.free(x);
    ckt.eval(x, 0);
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;

    const out = try t.allocator.alloc(f64, nnz + 1);
    defer t.allocator.free(out);
    out[nnz] = -7;
    ckt.combineGC(1e3, out);
    try t.expectEqual(@as(f64, -7), out[nnz]);
    const dense = try t.allocator.alloc(f64, n * n);
    defer t.allocator.free(dense);
    ckt.denseG(dense);
    const in_pattern = try t.allocator.alloc(bool, n * n);
    defer t.allocator.free(in_pattern);
    @memset(in_pattern, false);
    for (0..n) |col| for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |p| {
        const row = ckt.row_idx[p];
        try t.expectEqual(ckt.gcAt(1e3, @intCast(p)), out[p]);
        try t.expectEqual(@as(?u32, @intCast(p)), ckt.findSlot(row, @intCast(col)));
        try t.expectEqual(ckt.g_vals[p], dense[row * n + col]);
        in_pattern[row * n + col] = true;
    };
    for (0..n) |row| for (0..n) |col| {
        const hit = ckt.findSlot(@intCast(row), @intCast(col)) != null;
        try t.expectEqual(in_pattern[row * n + col], hit);
        if (!hit) try t.expectEqual(@as(f64, 0), dense[row * n + col]);
    };
}

test "snapshots copy or move device state and refuse a foreign topology" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    var other = try ladder(&lib, 3);
    defer other.deinit();
    var source = try types.Circuit.instantiate(&prepared, t.allocator);
    defer source.deinit();
    source.setSimState(.{ .kind = .dc });
    const x = try ramp(t.allocator, source.n);
    defer t.allocator.free(x);
    source.eval(x, 0);
    const g = try t.allocator.dupe(f64, source.g_vals);
    defer t.allocator.free(g);

    try t.expectError(error.IncompatibleDependency, types.Circuit.fromSnapshot(&other, &source, t.allocator));
    try t.expectError(error.IncompatibleDependency, types.Circuit.fromSnapshotMove(&other, &source, t.allocator));
    var copy = try types.Circuit.fromSnapshot(&prepared, &source, t.allocator);
    defer copy.deinit();
    copy.eval(x, 0);
    try t.expectEqualSlices(f64, g, copy.g_vals);

    var moved = try types.Circuit.fromSnapshotMove(&prepared, &source, t.allocator);
    defer moved.deinit();
    // The source keeps nothing, and its own deinit frees nothing twice.
    try t.expectEqual(@as(usize, 0), source.batches.len);
    try t.expectEqual(@as(usize, 0), source.g_vals.len);
    source.release();
    moved.eval(x, 0);
    try t.expectEqualSlices(f64, g, moved.g_vals);
    try moved.refuseDigital("test");
}

test "a baseline that failed to allocate can be retried" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 1);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    // Allocation 0 is g_base, 1 c_base, 2 the zero state. Failing 1 used to
    // keep g_base, so the retry skipped the allocation and stamped into an
    // empty c_base.
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        ckt.gpa = failing.allocator();
        try t.expectError(error.OutOfMemory, ckt.computeBaseline());
        ckt.gpa = t.allocator;
        try t.expect(!ckt.has_baseline);
        try t.expectEqual(ckt.g_base.len, ckt.c_base.len);
    }
    try ckt.computeBaseline();
    try t.expect(ckt.has_baseline);
    try t.expectEqual(@as(usize, ckt.nnz) + 1, ckt.c_base.len);
}

fn setUpEverything(gpa: std.mem.Allocator, prepared: *const Prepared) !void {
    var ckt = try types.Circuit.instantiate(prepared, gpa);
    defer ckt.deinit();
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    _ = try ckt.workspace();
    _ = try ckt.collectParams();
    const saved = try ckt.saveState(gpa);
    saved.deinit(gpa);
    var par = try ParEval.init(gpa, t.io, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, ckt.trash_slot, 3);
    par.deinit();
}

test "every allocation in circuit setup can fail without a leak" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 2);
    defer prepared.deinit();
    try t.checkAllAllocationFailures(t.allocator, setUpEverything, .{&prepared});
}

test "probeNames borrows labels and names unlabeled rows" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var prepared = try ladder(&lib, 1);
    defer prepared.deinit();
    var ckt = try types.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var no_x: [0]f64 = .{};
    const labels = [_][]const u8{ "v(a)", "i(v1)" };
    var ctx: types.RunCtx = .{
        .circuit = &ckt,
        .x_op = &no_x,
        .probes = &.{ 1, 2 },
        .probe_labels = &labels,
        .source_node = 0,
        .source_branch = 0,
        .allocator = arena.allocator(),
        .scratch_allocator = t.allocator,
    };
    const same = try types.probeNames(&ctx, null);
    try t.expect(same.ptr == @as([]const []const u8, &labels).ptr);
    const with = try types.probeNames(&ctx, "time");
    try t.expectEqual(@as(usize, 3), with.len);
    try t.expectEqualStrings("time", with[0]);
    try t.expectEqualStrings("v(a)", with[1]);
    try t.expectEqualStrings("i(v1)", with[2]);
    // A label count that does not match the probes counts as unlabeled.
    ctx.probe_labels = labels[0..1];
    const bare = try types.probeNames(&ctx, null);
    try t.expectEqualStrings("v(1)", bare[0]);
    try t.expectEqualStrings("v(2)", bare[1]);
    // A row past the circuit has no name rather than overflowing.
    try t.expectEqualStrings("", ckt.nodeName(std.math.maxInt(u32)));
}
