const std = @import("std");
const netlist = @import("builder");
const devices = @import("device_models");
const syntax = @import("syntax");
const types = syntax.types;
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

test "control source sensing ignores case while binding rejects missing and inexact names" {
    for ([_][]const u8{ "vcase", "missing", "" }) |control| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "VCase in 0 2\nRin in 0 1k\nF1 out 0 {s}\nRout out 0 1k\n", .{control});
        const ast = try syntax.Parser(syntax.spectre).parse(a, source);
        var builder = try Builder.init(a);
        defer builder.deinit();
        var nb = try netlist.NetBuilder.init(a, &builder, try syntax.elaborate(a, ast));
        try std.testing.expectError(if (control.len == 0) error.MissingControlSource else error.UnknownControlSource, nb.build());
        if (std.mem.eql(u8, control, "vcase"))
            try std.testing.expect(!builder.card_counts.contains("vsource"));
    }
}

test "transmission-line cards retain native numerical algorithms" {
    const cases = .{
        .{ "O1 a 0 b 0 line\n.model line LTRA r=0.5 l=250n c=100p len=2\n", "ltra_native" },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 c=100p len=2\n", "ltra_native" },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=12.45 l=8.972n c=0.468p length=16\n", "txl_native" },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=0.2 0 0.2 l=9.13n 3.3n 9.13n c=0.365p -0.09p 0.365p length=10\n", "cpl_native_2" },
        .{ "P1 a b c 0 d e f 0 line\n.model line CPL r=0.2 0 0 0.2 0 0.2 l=9n 3n 0 9n 3n 9n c=0.3p -0.03p 0 0.3p -0.03p 0.3p length=10\n", "cpl_native_3" },
        .{ "P1 a b c d 0 e f g h 0 line\n.model line CPL r=0.2 0 0 0 0.2 0 0 0.2 0 0.2 l=9n 3n 0 0 9n 3n 0 9n 3n 9n c=0.3p -0.03p 0 0 0.3p -0.03p 0 0.3p -0.03p 0.3p length=10\n", "cpl_native_4" },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const ast = try syntax.Parser(syntax.ngspice).parse(a, "* native line routing\n" ++ case[0] ++ ".end\n");
        var builder = try Builder.init(a);
        var compiled = false;
        defer if (!compiled) builder.deinit();
        var nb = try netlist.NetBuilder.init(a, &builder, try syntax.elaborate(a, ast));
        try nb.build();
        try std.testing.expectEqual(@as(usize, 1), builder.protos.items.len);
        try std.testing.expectEqualStrings(devices.vtable(case[1]).name, builder.protos.items[0].type_name);
        if (case[0][0] == 'Y' or case[0][0] == 'P') {
            try std.testing.expectEqual(@as(u32, 1), nb.n_br);
            try std.testing.expectEqual(builder.n - 1, nb.br_rows[0]);
        }
        var circuit = try builder.compile();
        compiled = true;
        defer circuit.deinit();
        try std.testing.expect(circuit.batches[0].hooks.commit_state != null);
        try std.testing.expect(circuit.batches[0].hooks.update_state == null);
        try std.testing.expect(circuit.batches[0].hooks.gpu_payload == null);
    }
}

test "unsupported transmission-line cards never select approximate fallbacks" {
    const cases = .{
        .{ "P1 a b c d e 0 f g h i j 0 line\n.model line CPL length=1\n", error.UnsupportedCoupledLineDimension },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=1 l=1n c=1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1e6 l=1n c=1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1 l=1u g=1u c=1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1e200 l=1e200 c=1e-100 length=1e150\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1 l=1e200 c=1e-200 length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=1 0 1 l=1u 2u 1u c=1p 0 1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=1 0 1 l=0 0 0 c=1p 0 1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=12.45 l=8.972n g=unresolved c=0.468p length=16\n", error.UnresolvedParameter },
        .{ "Y1 a 0 b 0 line len=unresolved\n.model line TXL r=12.45 l=8.972n c=0.468p length=16\n", error.UnresolvedParameter },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=0.5 l=250n c=100p length=unresolved\n", error.UnresolvedParameter },
        .{ "P1 a b 0 c d 0 line length=unresolved\n.model line CPL r=0.2 0 0.2 l=9n 0 9n c=0.3p 0 0.3p length=10\n", error.UnresolvedParameter },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 l=1n len=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 l=1u g=1e-320 c=1p len=1e-10\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 l=1e-320 c=1p len=1e-10\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1e200 g=1e200 len=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 g=1 len=1000\n", error.UnsupportedTransmissionLineParameters },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1e-200 g=1e-200 len=1e200\n", error.UnsupportedTransmissionLineParameters },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const ast = try syntax.Parser(syntax.ngspice).parse(a, "* invalid line routing\n" ++ case[0] ++ ".end\n");
        var builder = try Builder.init(a);
        defer builder.deinit();
        var nb = try netlist.NetBuilder.init(a, &builder, try syntax.elaborate(a, ast));
        try std.testing.expectError(case[1], nb.build());
        try std.testing.expectEqual(@as(usize, 0), builder.protos.items.len);
    }
}

test "RG line retains the checked instance length alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ast = try syntax.Parser(syntax.ngspice).parse(a, "* static RG length override\nO1 a 0 b 0 line length=2\n.model line LTRA r=1 g=1 len=1\n.end\n");
    var builder = try Builder.init(a);
    var compiled = false;
    defer if (!compiled) builder.deinit();
    var nb = try netlist.NetBuilder.init(a, &builder, try syntax.elaborate(a, ast));
    try nb.build();
    var circuit = try builder.compile();
    compiled = true;
    defer circuit.deinit();
    var params: std.ArrayList(devices.ir.ParamRef) = .empty;
    defer params.deinit(a);
    const batch = circuit.batches[0];
    try batch.hooks.collect_params(batch.ctx, a, &params).unwrap();
    for (params.items) |param| {
        if (std.mem.eql(u8, param.param_name, "len")) {
            try std.testing.expectEqual(@as(f64, 2), param.get());
            return;
        }
    }
    return error.MissingLineLength;
}
