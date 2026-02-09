//! Self-check: divider compiles and one eval() produces the exact linear MNA.
//! Moved from modules/analysis/src/compiled.zig when the Builder split into
//! src/builder.zig (policy) + analysis batch (mechanism).

const std = @import("std");
const testing = std.testing;
const analysis = @import("analysis");
const builder = @import("builder");

const Builder = builder.Builder;
const GROUND = analysis.GROUND;
const td = @import("testdev.zig");

test "compile + eval: resistor divider planes" {
    var b = Builder.init(testing.allocator);
    const vin = b.addNode();
    const vout = b.addNode();
    try b.addDevice(td.V, .{ .dc = 10 }, .{}, .{ vin, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ vin, vout });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ vout, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    // n = ground + vin + vout + branch
    try testing.expectEqual(@as(u32, 4), ckt.n);

    const x = [_]f64{ 0, 0, 0, 0 };
    ckt.eval(&x, 0);

    const g = 1.0 / 1000.0;
    // KCL vin: g*(vin-vout) + ibr
    try testing.expectApproxEqAbs(g, ckt.g_vals[ckt.findSlot(1, 1).?], 1e-15);
    try testing.expectApproxEqAbs(-g, ckt.g_vals[ckt.findSlot(1, 2).?], 1e-15);
    try testing.expectApproxEqAbs(1.0, ckt.g_vals[ckt.findSlot(1, 3).?], 1e-15);
    // KCL vout: -g*vin + 2g*vout
    try testing.expectApproxEqAbs(2 * g, ckt.g_vals[ckt.findSlot(2, 2).?], 1e-15);
    // branch: vin - v = -10 residual at x=0
    try testing.expectApproxEqAbs(1.0, ckt.g_vals[ckt.findSlot(3, 1).?], 1e-15);
    try testing.expectApproxEqAbs(-10.0, ckt.rhs[3], 1e-15);
    // ground eq pinned
    try testing.expectApproxEqAbs(1.0, ckt.g_vals[ckt.diag_slots[0]], 1e-15);
}

test "recompute rejects internal node merges and splits, permits numeric updates" {
    const Diode = @import("devices").byName("diode");
    for ([_]f64{ 0, 10 }) |rs| for ([_]bool{ false, true }) |tied_ports| {
        var b = Builder.init(testing.allocator);
        const a = b.addNode();
        try b.addDevice(Diode, .{ .rs = rs }, .{}, .{ a, if (tied_ports) a else GROUND });
        var ckt = try b.compile();
        defer ckt.deinit();
        try ckt.recompute();
        var checked = false;
        for (try ckt.collectParams()) |ref| {
            if (!std.mem.eql(u8, ref.param_name, "rs")) continue;
            checked = true;
            ref.set(if (rs == 0) 10 else 0);
            try testing.expectError(error.TopologyChanged, ckt.recompute());
            ref.set(rs);
            try ckt.recompute();
            ref.set(2 * rs);
            try ckt.recompute();
        }
        try testing.expect(checked);
    };
}

test "recompute refreshes constant resistor baseline after numeric edit" {
    var b = Builder.init(testing.allocator);
    const n = b.addNode();
    try b.addDevice(td.Rc, .{ .r = 1000 }, .{}, .{ n, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    try ckt.computeBaseline();
    try testing.expect(ckt.has_baseline);
    const refs = try ckt.collectParams();
    try testing.expectEqual(@as(usize, 1), refs.len);
    refs[0].set(2000);
    try ckt.recompute();
    try testing.expect(!ckt.has_baseline);
    try ckt.computeBaseline();
    ckt.eval(&.{ 0, 1 }, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0005), ckt.g_vals[ckt.findSlot(n, n).?], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0005), ckt.rhs[n], 1e-15);
}

test "DC outer temperature topology error restores source and instance temperatures" {
    const Bjt = @import("devices").byName("bjt");
    var b = Builder.init(testing.allocator);
    const n = b.addNode();
    try b.addDevice(td.V, .{ .dc = 0.1 }, .{}, .{ n, GROUND });
    try b.addDevice(Bjt, .{ .rb = 100, .trb1 = -1 }, .{}, .{ GROUND, GROUND, GROUND, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    try ckt.recompute();
    const refs = try ckt.collectParams();
    const before = try testing.allocator.alloc(f64, refs.len);
    defer testing.allocator.free(before);
    for (refs, before) |ref, *v| v.* = ref.get();
    const ctx: analysis.RunCtx = .{
        .circuit = &ckt,
        .x_op = null,
        .probes = &.{n},
        .source_node = n,
        .source_branch = GROUND,
        .allocator = testing.allocator,
    };
    // RB(T) reaches zero at 28 C, changing the frozen base-node wiring.
    try testing.expectError(error.TopologyChanged, analysis.dc.run(&ctx, .{
        .start = 0.2,
        .stop = 0.2,
        .source2_is_temp = true,
        .start2 = 28,
        .stop2 = 28,
    }));
    try ckt.recompute();
    for (refs, before) |ref, v| {
        if (std.mem.eql(u8, ref.param_name, "dc") or std.mem.eql(u8, ref.param_name, "temperature"))
            try testing.expectEqual(v, ref.get());
    }
}
