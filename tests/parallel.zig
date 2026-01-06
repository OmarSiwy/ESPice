//! Parallel device eval (analysis.par) vs serial: plane equivalence,
//! determinism, baseline path, dedup path.
//!
//! Contract (par.zig doc): MT at fixed n_lanes is bit-identical run-to-run;
//! MT vs serial differs only by reassociation across lanes. Worst-case
//! reassociation error on a slot with k contributions is ~k·eps, so the
//! bound is relative (1e-11 ≫ any real k·eps here), not a fixed ulp count.
const std = @import("std");
const testing = std.testing;

const analysis = @import("analysis");
const builder = @import("builder");

const Builder = builder.Builder;
const td = @import("testdev.zig");
const GROUND = analysis.GROUND;

const N_LANES = 4;

/// |a-b| in units-in-last-place of the larger magnitude.
fn ulpDiff(a: f64, b: f64) u64 {
    if (a == b) return 0;
    const ia: i64 = @bitCast(a);
    const ib: i64 = @bitCast(b);
    if ((ia < 0) != (ib < 0)) return std.math.maxInt(u64);
    return @abs(ia - ib);
}

/// exact == true: bitwise equality (determinism checks).
/// exact == false: |w-g| <= 1e-11 * max(|w|,|g|) + 1e-30 (reassociation).
fn expectPlanesClose(want: []const f64, got: []const f64, exact: bool) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got, 0..) |w, g, i| {
        const ok = if (exact)
            @as(u64, @bitCast(w)) == @as(u64, @bitCast(g))
        else
            @abs(w - g) <= 1e-11 * @max(@abs(w), @abs(g)) + 1e-30;
        if (!ok) {
            std.debug.print("plane[{d}]: serial {e} vs mt {e} ({d} ulps)\n", .{ i, w, g, ulpDiff(w, g) });
            return error.TestExpectedApproxEq;
        }
    }
}

/// Deterministic pseudo-random voltage vector in [-0.8, 0.8] (diode-safe).
fn fillX(x: []f64) void {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    for (x) |*v| v.* = rnd.float(f64) * 1.6 - 0.8;
    x[0] = 0; // ground invariant
}

/// Diode/resistor ladder: cell i = R(n_i -> n_{i+1}) + D(n_i -> gnd).
/// Adjacent cells share nodes ⇒ scatter conflicts across lane boundaries.
fn buildLadder(gpa: std.mem.Allocator, cells: u32) !analysis.Circuit {
    var b = Builder.init(gpa);
    errdefer b.deinit();
    var prev = b.addNode();
    try b.addDevice(td.V, .{ .dc = 1.0 }, .{}, .{ prev, GROUND });
    for (0..cells) |_| {
        const next = b.addNode();
        try b.addDevice(td.R, .{ .r = 100 }, .{}, .{ prev, next });
        try b.addDevice(td.D, .{ .is = 1e-14 }, .{}, .{ next, GROUND });
        prev = next;
    }
    return b.compile();
}

const Snapshot = struct {
    g: []f64,
    c: []f64,
    rhs: []f64,
    q: []f64,

    // Trash slot (index nnz) and trash row (index n) collect ground writes
    // and are don't-care by contract — excluded (their value legitimately
    // differs between serial and lane-split accumulation).
    fn take(gpa: std.mem.Allocator, ckt: *const analysis.Circuit) !Snapshot {
        return .{
            .g = try gpa.dupe(f64, ckt.g_vals[0..ckt.nnz]),
            .c = try gpa.dupe(f64, ckt.c_vals[0..@min(ckt.c_vals.len, ckt.nnz)]),
            .rhs = try gpa.dupe(f64, ckt.rhs[0..ckt.n]),
            .q = try gpa.dupe(f64, ckt.q_vec[0..@min(ckt.q_vec.len, ckt.n)]),
        };
    }

    fn expectClose(self: Snapshot, ckt: *const analysis.Circuit, exact: bool) !void {
        try expectPlanesClose(self.g, ckt.g_vals[0..ckt.nnz], exact);
        try expectPlanesClose(self.c, ckt.c_vals[0..@min(ckt.c_vals.len, ckt.nnz)], exact);
        try expectPlanesClose(self.rhs, ckt.rhs[0..ckt.n], exact);
        try expectPlanesClose(self.q, ckt.q_vec[0..@min(ckt.q_vec.len, ckt.n)], exact);
    }
};

fn serialVsParallel(ckt: *analysis.Circuit, arena: std.mem.Allocator, comptime newton: bool) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const x = try arena.alloc(f64, ckt.n + 1);
    fillX(x);

    // Serial reference.
    ckt.par_eval = null;
    if (newton) ckt.evalNewton(x, 0.0) else ckt.eval(x, 0.0);
    const want = try Snapshot.take(arena, ckt);

    // Parallel, twice: close to serial, bit-identical to itself.
    var par = try analysis.devices.par.ParEval.init(testing.allocator, io, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, ckt.trash_slot, N_LANES);
    defer par.deinit();
    ckt.par_eval = &par;
    defer ckt.par_eval = null;

    if (newton) ckt.evalNewton(x, 0.0) else ckt.eval(x, 0.0);
    try want.expectClose(ckt, false);
    const first = try Snapshot.take(arena, ckt);

    if (newton) ckt.evalNewton(x, 0.0) else ckt.eval(x, 0.0);
    try first.expectClose(ckt, true); // determinism: exact
}

test "par: diode ladder MT == serial (rel 1e-11), MT deterministic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ckt = try buildLadder(testing.allocator, 3000);
    defer ckt.deinit();

    try serialVsParallel(&ckt, arena, false);
}

test "par: baseline (const-Jacobian) evalNewton path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Rc declares constant_g ⇒ computeBaseline engages the baseline path.
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    var prev = b.addNode();
    try b.addDevice(td.V, .{ .dc = 1.0 }, .{}, .{ prev, GROUND });
    for (0..2000) |_| {
        const next = b.addNode();
        try b.addDevice(td.Rc, .{ .r = 250 }, .{}, .{ prev, next });
        try b.addDevice(td.D, .{ .is = 1e-14 }, .{}, .{ next, GROUND });
        prev = next;
    }
    var ckt = try b.compile();
    defer ckt.deinit();
    try ckt.computeBaseline();
    try testing.expect(ckt.has_baseline);

    try serialVsParallel(&ckt, arena, true);
}

test "par: dedup cache (PrepCache device, one prep group) MT == serial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 5000 byte-identical Dp diodes fanned out from one rail: single prep
    // group, per-lane caches must not corrupt each other.
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const rail = b.addNode();
    try b.addDevice(td.V, .{ .dc = 0.6 }, .{}, .{ rail, GROUND });
    for (0..5000) |_| {
        const leaf = b.addNode();
        try b.addDevice(td.R, .{ .r = 50 }, .{}, .{ rail, leaf });
        try b.addDevice(td.Dp, .{ .is = 1e-14 }, .{}, .{ leaf, GROUND });
    }
    var ckt = try b.compile();
    defer ckt.deinit();

    try serialVsParallel(&ckt, arena, false);
}

test "par: lane count 1 falls through cleanly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ckt = try buildLadder(testing.allocator, 64);
    defer ckt.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const x = try arena.alloc(f64, ckt.n + 1);
    fillX(x);
    ckt.eval(x, 0.0);
    const want = try Snapshot.take(arena, &ckt);

    var par = try analysis.devices.par.ParEval.init(testing.allocator, threaded.io(), ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, ckt.trash_slot, 1);
    defer par.deinit();
    ckt.par_eval = &par;
    defer ckt.par_eval = null;
    ckt.eval(x, 0.0);
    try want.expectClose(&ckt, true); // single lane: exactly the serial order
}
