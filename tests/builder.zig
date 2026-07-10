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
