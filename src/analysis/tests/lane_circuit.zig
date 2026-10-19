//! `LaneCircuit(W)` on real devices: pack then unpack restores every
//! lane's planes bitwise, the deinterleaved eval equals each lane's own
//! scalar eval, and `newtonLanes` over the lane system equals the scalar
//! `newton` on each lane's twin, bitwise (diodes behind different
//! resistors: junction limiting, INITFIX and per-lane iteration counts).
const std = @import("std");
const t = std.testing;
const analysis = @import("../types.zig");
const LaneCircuit = @import("../lane_circuit.zig").LaneCircuit;
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const converger = @import("solver").converger;
const models = @import("models");
const GROUND = analysis.GROUND;
const gpa = t.allocator;

/// 5 V through `r` into two diodes in series, with a capacitor across the
/// lower one so the c and q planes carry something.
fn chain(lib: *const Library, r: f64) !@import("device").Circuit {
    var b = try Builder.init(gpa, lib);
    const n_in = try b.addNode();
    const n_mid = try b.addNode();
    const n_low = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 5 }, &.{}, .{ n_in, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = r }, &.{}, .{ n_in, n_mid });
    try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ n_mid, n_low });
    try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ n_low, GROUND });
    try b.addDevice(models.capacitor, "", &.{ .c = 1e-9 }, &.{}, .{ n_low, GROUND });
    return b.compile();
}

test "LaneCircuit(W): pack/unpack round trip, deinterleaved eval and newtonLanes are bitwise each lane's scalar run" {
    const W = std.simd.suggestVectorLength(f64) orelse 4;
    const LC = LaneCircuit(W);
    var lib = try Library.init(gpa);
    defer lib.deinit();
    // Lane l and its twin W + l share a Prepared (the same resistor).
    var prepared: [W]@import("device").Circuit = undefined;
    var built: usize = 0;
    defer for (prepared[0..built]) |*p| p.deinit();
    for (&prepared, 0..) |*p, l| {
        p.* = try chain(&lib, 100 * std.math.pow(f64, 10, @floatFromInt(l)));
        built += 1;
    }
    var ckts: [2 * W]analysis.Circuit = undefined;
    var made: usize = 0;
    defer for (ckts[0..made]) |*c| c.deinit();
    for (&ckts, 0..) |*c, k| {
        c.* = try analysis.Circuit.instantiate(&prepared[k % W], gpa);
        made += 1;
        try c.computeBaseline();
        c.setSimState(.{ .t = 0, .dt = 1, .kind = .dc });
    }
    var lane_ptrs: [W]*analysis.Circuit = undefined;
    for (&lane_ptrs, ckts[0..W]) |*p, *c| p.* = c;
    const n = ckts[0].n;

    var lc = try LC.init(gpa, lane_ptrs);
    defer lc.deinit(gpa);

    // Round trip: eval each lane at its own x, pack, scribble, unpack.
    const xs = try gpa.alloc(f64, n);
    defer gpa.free(xs);
    const x = try gpa.alloc(LC.V, n);
    defer gpa.free(x);
    for (x, 0..) |*v, i| {
        var a: [W]f64 = undefined;
        for (&a, 0..) |*e, l| e.* = if (i == 0) 0 else 0.3 + 0.1 * @as(f64, @floatFromInt(i + l));
        v.* = a;
    }
    const planes = .{ "g_vals", "c_vals", "rhs", "q_vec" };
    for (ckts[0..W], 0..) |*c, l| {
        LC.System.getLane(xs, x, l);
        c.eval(xs, 0);
    }
    lc.pack();
    const saved = try gpa.alloc(f64, W * (2 * ckts[0].g_vals.len + 2 * ckts[0].rhs.len));
    defer gpa.free(saved);
    var off: usize = 0;
    for (ckts[0..W]) |*c| inline for (planes) |p| {
        @memcpy(saved[off..][0..@field(c, p).len], @field(c, p));
        off += @field(c, p).len;
        @memset(@field(c, p), std.math.nan(f64));
    };
    lc.unpack();
    off = 0;
    for (ckts[0..W]) |*c| inline for (planes) |p| {
        try t.expectEqualSlices(u64, @ptrCast(saved[off..][0..@field(c, p).len]), @ptrCast(@field(c, p)));
        off += @field(c, p).len;
    };

    // Deinterleaved eval against each twin's own eval, all four planes.
    lc.eval(x, @splat(0));
    lc.unpack();
    for (0..W) |l| {
        const twin = &ckts[W + l];
        LC.System.getLane(xs, x, l);
        twin.eval(xs, 0);
        inline for (planes) |p| try t.expectEqualSlices(u64, @ptrCast(@field(twin, p)), @ptrCast(@field(&ckts[l], p)));
    }

    // Newton from the junction seed with INITFIX, against each twin.
    for (ckts[0..W], 0..) |*c, l| {
        @memset(xs, 0);
        c.seedJunctions(xs);
        LC.System.putLane(x, xs, l);
    }
    var lws = try lc.workspace(gpa);
    defer lws.deinit(gpa);
    const opts: converger.Options = .{ .gmin = 1e-12, .max_iter = 100, .init_fix = true };
    const res = try converger.newtonLanes(W, &lc.sys, &lws, x, @splat(0), opts, LC.System.LaneHook{});
    lc.sys.clearLimits();
    try t.expectEqual(@as(LC.System.Mask, 0), res.singular);
    var iters: [W]u16 = undefined;
    for (0..W) |l| {
        const twin = &ckts[W + l];
        @memset(xs, 0);
        twin.seedJunctions(xs);
        const want = try converger.run(twin, try twin.workspace(), xs, 0, opts, analysis.EvalHook{});
        try t.expect(want.converged);
        try t.expect(res.converged & (@as(LC.System.Mask, 1) << @intCast(l)) != 0);
        try t.expectEqual(want.iterations, res.iterations[l]);
        iters[l] = want.iterations;
        for (xs, x) |a, v| try t.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(@import("solver").lanes.Lanes(W).lane(v, l))));
        try t.expectEqualSlices(u64, @ptrCast(twin.g_vals), @ptrCast(ckts[l].g_vals));
        try t.expectEqualSlices(u64, @ptrCast(twin.rhs), @ptrCast(ckts[l].rhs));
    }
    // The lanes really are different points: not every lane took the same
    // number of iterations.
    try t.expect(std.mem.indexOfNone(u16, &iters, &.{iters[0]}) != null);
}
