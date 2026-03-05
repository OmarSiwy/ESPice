//! Compiled as its own object: importing this into the test would hide the bug.
const std = @import("std");
const ir = @import("device_ir");
const eval = @import("device_eval");

const Device = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 1;
    pub const Model = struct { r: f64 = 1000 };
    pub const Instance = struct { temp: f64 = 300.15 };
    pub const noise_gens = [_]ir.NoiseGen{.{ .row = 0, .col = 1, .kind = .thermal }};
    pub fn noisePsd(_: [2]f64, _: *const Model, _: *const Instance) [1]ir.PsdTerm {
        return .{.{ .white = 1 }};
    }
    pub fn collapse(model: *const Model, _: *const Instance) [2]?u8 {
        return .{ null, if (model.r < 0) 0 else null };
    }
    pub fn eval(comptime S: type, x: [2]S, model: *const Model, _: *const Instance, _: f64) [2]S {
        const current = x[0].sub(x[1]).scale(1 / model.r);
        return .{ current, current.neg() };
    }
};

export fn testDeviceVtable() *const ir.DeviceVtable {
    return eval.deviceVtable(Device, "error_boundary");
}

fn tooManyInstances() ir.DeviceResult(ir.Batch) {
    if (@sizeOf(usize) <= 4) unreachable;
    var store: eval.ProtoStore(Device) = .{};
    // Only the count guard may inspect this oversized column; no element is
    // allocated or accessed, and finalize must fail before taking ownership.
    store.models.items.len = @as(usize, std.math.maxInt(u32)) + 1;
    return eval.ProtoStore(Device).finalize(&store, std.heap.page_allocator, undefined);
}

export fn testTooManyInstances() *const anyopaque {
    return @ptrCast(&tooManyInstances);
}
