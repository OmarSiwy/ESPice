const std = @import("std");
const netlist = @import("builder");
const devices = @import("device_models");
const types = @import("syntax").types;
const Builder = netlist.Builder;
const applySourceWaveform = netlist.test_access.applySourceWaveform;
const pwlSlot = netlist.test_access.pwlSlot;
const pwlCapacity = netlist.test_access.pwlCapacity;
const Wave = netlist.test_access.Wave;
const castField = netlist.test_access.castField;
const applyKvDyn = netlist.test_access.applyKvDyn;

// ---------------------------------------------------------------------------
// Source binding regression check
//
// The two things that break silently when the .va and the binder drift apart:
// the flattened PWL table (`applySourceWaveform` writes mangled field names
// that no compiler will catch a typo in — @hasField just skips) and the -1
// PULSE sentinels (an unspecified PULSE has to stay a step; if a default ever
// stops being -1 the .tran resolution turns into a 2 ns square wave).
// ---------------------------------------------------------------------------

test "V card: PWL table lands in the flattened Model slots" {
    const args = [_]types.Value{
        .{ .num = 0.0 },   .{ .num = 0.0 },
        .{ .num = 10e-3 }, .{ .num = 5.0 },
        .{ .num = 20e-3 }, .{ .num = 0.0 },
    };
    const positional = [_]types.Value{.{ .group = .{ .name = "PWL", .args = &args } }};
    const dev: types.Device = .{
        .name = "Vc",
        .nodes = &.{ "ctl", "0" },
        .positional = &positional,
        .kv = &.{},
    };

    var model: devices.vsource.Model = .{};
    applySourceWaveform(&model, dev);

    try std.testing.expectEqual(@as(i64, @intFromEnum(Wave.pwl)), @as(i64, model.waveform));
    try std.testing.expectEqual(@as(i64, 3), @as(i64, model.pwl_len));
    try std.testing.expectEqual(@as(f64, 0.0), @field(model, pwlSlot("pwl_times", 0)));
    try std.testing.expectEqual(@as(f64, 10e-3), @field(model, pwlSlot("pwl_times", 1)));
    try std.testing.expectEqual(@as(f64, 5.0), @field(model, pwlSlot("pwl_values", 1)));
    try std.testing.expectEqual(@as(f64, 20e-3), @field(model, pwlSlot("pwl_times", 2)));
    // Slot 3 is past the table and must stay at its default, or the model's
    // `pwl_len`-bounded loops would walk into stale data.
    try std.testing.expectEqual(@as(f64, 0.0), @field(model, pwlSlot("pwl_times", 3)));
    try std.testing.expect(pwlCapacity(devices.vsource.Model) >= 3);
}

test "V/I cards: unspecified PULSE edges stay at the -1 sentinel" {
    // PULSE(0 5) — no TR/TF/PW/PER. resolvePulseDefaults fills these from the
    // .tran card; until it runs they must still read as "unset".
    const args = [_]types.Value{ .{ .num = 0.0 }, .{ .num = 5.0 } };
    const positional = [_]types.Value{.{ .group = .{ .name = "PULSE", .args = &args } }};
    const dev: types.Device = .{
        .name = "V1",
        .nodes = &.{ "a", "0" },
        .positional = &positional,
        .kv = &.{},
    };

    inline for (.{ devices.vsource, devices.isource }) |D| {
        var model: D.Model = .{};
        applySourceWaveform(&model, dev);
        try std.testing.expectEqual(@as(f64, 5.0), model.pulse_v2);
        try std.testing.expect(model.pulse_tr < 0);
        try std.testing.expect(model.pulse_tf < 0);
        try std.testing.expect(model.pulse_pw < 0);
        try std.testing.expect(model.pulse_per < 0);
    }
}

fn nodeAllocationFixture(allocator: std.mem.Allocator) !void {
    var builder = try Builder.init(allocator);
    defer builder.deinit();
    for (0..24) |index| {
        var buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "node{d}", .{index});
        const before = builder.n;
        const node = builder.internNode(name) catch |err| {
            try std.testing.expectEqual(before, builder.n);
            try std.testing.expectEqual(@as(usize, before), builder.node_labels.items.len);
            try std.testing.expect(!builder.node_names.contains(name));
            return err;
        };
        try std.testing.expectEqual(before, node);
        try std.testing.expectEqual(node, try builder.internNode(name));
    }
}

test "node construction returns allocation errors without partial name publication" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, nodeAllocationFixture, .{});
}

fn integerParameterFixture(dest: [*]u8, name: []const u8, value: f64) bool {
    if (!std.mem.eql(u8, name, "mode")) return false;
    const converted = castField(i8, value) catch return false;
    const field: *i8 = @ptrCast(dest);
    field.* = converted;
    return true;
}

test "numeric field binding rejects invalid native and dynamic parameter values" {
    try std.testing.expectEqual(@as(i8, -128), try castField(i8, -128));
    try std.testing.expectEqual(@as(i8, 127), try castField(i8, 127));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i8, 128));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i8, 1.5));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u16, -1));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u16, 65536));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i64, 0x1p63));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u64, 0x1p64));
    try std.testing.expectEqual(std.math.minInt(i64), try castField(i64, -0x1p63));
    try std.testing.expectError(error.NonFiniteParameter, castField(i64, std.math.inf(f64)));
    try std.testing.expectError(error.NonFiniteParameter, castField(bool, std.math.nan(f64)));
    try std.testing.expectError(error.ParameterOutOfRange, castField(f32, 1e300));

    var field: i8 = 7;
    try applyKvDyn(integerParameterFixture, @ptrCast(&field), &.{.{ .key = "unknown", .value = .{ .num = 1e300 } }});
    try std.testing.expectEqual(@as(i8, 7), field);
    try std.testing.expectError(error.InvalidParameterValue, applyKvDyn(integerParameterFixture, @ptrCast(&field), &.{.{ .key = "mode", .value = .{ .num = 128 } }}));
    try std.testing.expectError(error.InvalidParameterValue, applyKvDyn(integerParameterFixture, @ptrCast(&field), &.{.{ .key = "mode", .value = .{ .name = "unresolved" } }}));
}
