//! Self-check: divider compiles and one eval() produces the exact linear MNA.
//! Moved from modules/analysis/src/compiled.zig when the Builder split into
//! src/builder.zig (policy) + analysis batch/dyn (mechanism).

const std = @import("std");
const testing = std.testing;
const analysis = @import("analysis");
const builder = @import("builder");

const Builder = builder.Builder;
const DynDevice = analysis.dyn.DynDevice;
const DynKv = analysis.dyn.DynKv;
const GROUND = analysis.GROUND;
const td = analysis.testdev;

// In-process fake dyn device: a 100-ohm resistor behind the ABI.
// Model = { g: f64 }, default g = 0.01. Analytic Jacobian by hand.
const FakeDynR = struct {
    const Model = extern struct { g: f64 };

    fn initModel(buf: [*]u8) callconv(.c) void {
        const m: *Model = @ptrCast(@alignCast(buf));
        m.* = .{ .g = 0.01 };
    }
    fn initInstance(_: [*]u8) callconv(.c) void {}
    fn setModelParam(buf: [*]u8, name: [*]const u8, len: usize, value: f64) callconv(.c) bool {
        if (!std.mem.eql(u8, name[0..len], "g")) return false;
        const m: *Model = @ptrCast(@alignCast(buf));
        m.g = value;
        return true;
    }
    fn setInstanceParam(_: [*]u8, _: [*]const u8, _: usize, _: f64) callconv(.c) bool {
        return false;
    }
    fn evalAd(x: [*]const f64, model: [*]const u8, _: [*]const u8, _: f64, out_res: [*]f64, out_jac: [*]f64) callconv(.c) void {
        const m: *const Model = @ptrCast(@alignCast(model));
        const ir = m.g * (x[0] - x[1]);
        out_res[0] = ir;
        out_res[1] = -ir;
        out_jac[0 * 2 + 0] = m.g;
        out_jac[0 * 2 + 1] = -m.g;
        out_jac[1 * 2 + 0] = -m.g;
        out_jac[1 * 2 + 1] = m.g;
    }

    fn device() DynDevice {
        return .{
            .n_u = 2,
            .num_ports = 2,
            .model_size = @sizeOf(Model),
            .instance_size = 0,
            .init_model = initModel,
            .init_instance = initInstance,
            .set_model_param = setModelParam,
            .set_instance_param = setInstanceParam,
            .eval_ad = evalAd,
            .q_ad = null,
        };
    }
};

test "addDynDevice: dyn resistor divider matches static planes" {
    var b = Builder.init(testing.allocator);
    const vin = b.addNode();
    const vout = b.addNode();
    try b.addDevice(td.V, .{ .dc = 10 }, .{}, .{ vin, GROUND });
    // upper leg static 1k, lower leg DYN 1k (g set via named param)
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ vin, vout });
    const kv = [_]DynKv{.{ .key = "g", .value = 1e-3 }};
    try b.addDynDevice(
        FakeDynR.device(),
        "fake_dyn_r",
        &.{&.{ vout, GROUND }},
        &.{&kv},
        &.{&.{}},
    );
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = [_]f64{ 0, 0, 0, 0 };
    ckt.eval(&x, 0);

    const g = 1e-3;
    // dyn leg stamps only its non-ground diagonal (vout,vout); ground row/col trashed
    try testing.expectApproxEqAbs(2 * g, ckt.g_vals[ckt.findSlot(2, 2).?], 1e-15);
    try testing.expectApproxEqAbs(-g, ckt.g_vals[ckt.findSlot(1, 2).?], 1e-15);
    // residual at x=0 is zero on vout row
    try testing.expectApproxEqAbs(0.0, ckt.rhs[2], 1e-15);
}

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
