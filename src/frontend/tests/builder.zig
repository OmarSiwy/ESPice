const std = @import("std");
const builder = @import("builder");
const devices = @import("builder").spice;
const device = @import("device");
const netlist = @import("netlist");
const Value = netlist.Value;
const Builder = builder.Builder;
const applySourceWaveform = builder.test_access.applySourceWaveform;
const pwlSlot = builder.test_access.pwlSlot;
const pwlCapacity = builder.test_access.pwlCapacity;
const Wave = builder.test_access.Wave;
const castField = builder.test_access.castField;
const bindKv = builder.test_access.bindKv;

fn card(name: []const u8, positional: []const Value) netlist.Netlist.View {
    return .{ .name = name, .kind = 'v', .pins = &.{}, .positional = positional, .kv = &.{}, .model = null, .subckt_instance = 0 };
}

// Source binding: the two things that break silently when the .va and the
// binder drift apart. The flattened PWL table (a typo in a mangled field name
// is skipped by @hasField, not caught) and the -1 PULSE sentinels (if a
// default stops being -1, an unspecified PULSE becomes a 2 ns square wave).

test "V card: PWL table lands in the flattened Model slots" {
    const args = [_]Value{
        .{ .num = 0.0 },   .{ .num = 0.0 },
        .{ .num = 10e-3 }, .{ .num = 5.0 },
        .{ .num = 20e-3 }, .{ .num = 0.0 },
    };
    const positional = [_]Value{.{ .group = .{ .name = "PWL", .args = &args } }};
    const dev = card("Vc", &positional);

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
    // PULSE(0 5): no TR/TF/PW/PER. resolvePulseDefaults fills these from the
    // .tran card; until it runs they must still read as "unset".
    const args = [_]Value{ .{ .num = 0.0 }, .{ .num = 5.0 } };
    const positional = [_]Value{.{ .group = .{ .name = "PULSE", .args = &args } }};
    const dev = card("V1", &positional);

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

const ModeBlob = struct { mode: i8 = 7 };

fn bindMode(dest: [*]u8, params: []const device.abi.Param) device.abi.BindStatus {
    return device.abi.bind.apply(@as(*ModeBlob, @ptrCast(@alignCast(dest))), params);
}

test "numeric field binding rejects invalid native and dynamic parameter values" {
    try std.testing.expectEqual(@as(i8, -128), try castField(i8, -128));
    try std.testing.expectEqual(@as(i8, 127), try castField(i8, 127));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i8, 128));
    try std.testing.expectEqual(@as(i8, 2), try castField(i8, 1.5));
    try std.testing.expectEqual(@as(i8, -1), try castField(i8, -1.5));
    try std.testing.expectEqual(@as(u16, 104), try castField(u16, 103.60));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i8, 127.5));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u16, -1));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u16, 65536));
    try std.testing.expectError(error.ParameterOutOfRange, castField(i64, 0x1p63));
    try std.testing.expectError(error.ParameterOutOfRange, castField(u64, 0x1p64));
    try std.testing.expectEqual(std.math.minInt(i64), try castField(i64, -0x1p63));
    try std.testing.expectError(error.NonFiniteParameter, castField(i64, std.math.inf(f64)));
    try std.testing.expectError(error.NonFiniteParameter, castField(bool, std.math.nan(f64)));
    try std.testing.expectError(error.ParameterOutOfRange, castField(f32, 1e300));

    var blob: ModeBlob = .{};
    try bindKv(bindMode, @ptrCast(&blob), &.{.{ .key = "unknown", .value = .{ .num = 1e300 } }});
    try std.testing.expectEqual(@as(i8, 7), blob.mode);
    try std.testing.expectError(error.ParameterOutOfRange, bindKv(bindMode, @ptrCast(&blob), &.{.{ .key = "mode", .value = .{ .num = 128 } }}));
    try std.testing.expectError(error.UnresolvedParameter, bindKv(bindMode, @ptrCast(&blob), &.{.{ .key = "mode", .value = .{ .name = "unresolved" } }}));
}

test "control source sensing ignores case while binding rejects missing and inexact names" {
    for ([_][]const u8{ "vcase", "missing", "" }) |control| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "VCase in 0 2\nRin in 0 1k\nF1 out 0 {s}\nRout out 0 1k\n", .{control});
        const nl = try netlist.parse(a, source, .spectre);
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try std.testing.expectError(if (control.len == 0) error.MissingControlSource else error.UnknownControlSource, nb.build());
        if (std.mem.eql(u8, control, "vcase"))
            try std.testing.expect(b.card_counts.items.len <= @intFromEnum(device.Library.builtin("vsource")));
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
        const nl = try netlist.parse(a, "* native line routing\n" ++ case[0] ++ ".end\n", .ngspice);
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        var compiled = false;
        defer if (!compiled) b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try nb.build();
        try std.testing.expectEqual(@as(usize, 1), b.protos.items.len);
        try std.testing.expectEqualStrings(device.vtable(case[1]).name, b.protos.items[0].type_name);
        if (case[0][0] == 'Y' or case[0][0] == 'P') {
            try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(nb.br.len)));
            try std.testing.expectEqual(b.n - 1, nb.br.items(.row)[0]);
        }
        var circuit = try b.compile();
        compiled = true;
        defer circuit.deinit();
        try std.testing.expect(circuit.batches[0].hooks.commit_state != null);
        try std.testing.expect(circuit.batches[0].hooks.update_state == null);
        try std.testing.expect(circuit.batches[0].hooks.gpu_payload == null);
    }
}

test "held variables and switch latches stage per converged solve" {
    // `stateCtl(.revert)` restores vbic13_4t's @(initial_step) held values
    // and the switch's hysteresis latch alike, so both stage per solve.
    const cases = .{
        "Q1 c b 0 qm\n.model qm NPN LEVEL=4\n",
        "S1 a 0 c 0 sw\n.model sw SW vt=0.5\n",
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try netlist.parse(a, "* held state routing\n" ++ case ++ ".end\n", .ngspice);
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        var compiled = false;
        defer if (!compiled) b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try nb.build();
        var circuit = try b.compile();
        compiled = true;
        defer circuit.deinit();
        const hooks = circuit.batches[0].hooks;
        try std.testing.expect(hooks.update_state != null and hooks.state_ctl != null);
    }
}

test "source breakpoints match an uncached walk, forward and backward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* breakpoint cache\n" ++
        "V1 a 0 PULSE(0 1 1n 1n 1n 5n 20n)\nV2 b 0 PWL(0 0 3n 1 7n 0)\nR1 a b 1k\n.end\n", .ngspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    var circuit = try b.compile();
    compiled = true;
    defer circuit.deinit();
    const src = for (circuit.batches) |bt| {
        if (bt.hooks.next_breakpoint != null) break bt;
    } else return error.TestUnexpectedResult;
    // Timer-only sources run no per-step state pass.
    try std.testing.expect(src.hooks.update_state == null and src.hooks.bound_step == null);
    const next = src.hooks.next_breakpoint.?;
    const ts = [_]f64{ 0, 0.5e-9, 1e-9, 1.5e-9, 2e-9, 3e-9, 2.5e-9, 6.9e-9, 7e-9, 30e-9, 1e-9, 100e-9, 0 };
    for (ts) |t| {
        const cached = next(src.ctx, t);
        _ = src.hooks.recompute.?(src.ctx); // empties the cache
        try std.testing.expectEqual(next(src.ctx, t), cached);
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
        const nl = try netlist.parse(a, "* invalid line routing\n" ++ case[0] ++ ".end\n", .ngspice);
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try std.testing.expectError(case[1], nb.build());
        try std.testing.expectEqual(@as(usize, 0), b.protos.items.len);
    }
}

test "RG line retains the checked instance length alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* static RG length override\nO1 a 0 b 0 line length=2\n.model line LTRA r=1 g=1 len=1\n.end\n", .ngspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    var circuit = try b.compile();
    compiled = true;
    defer circuit.deinit();
    var params: std.ArrayList(device.abi.ParamRef) = .empty;
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

test "V card: PWL td= and r= suffixes bind, and r=0 means repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* pwl suffixes\nV1 a 0 pwl(0 0 1n 1 2n 0) td=0.5n r=0\n.end\n", .ngspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    var circuit = try b.compile();
    compiled = true;
    defer circuit.deinit();
    var params: std.ArrayList(device.abi.ParamRef) = .empty;
    defer params.deinit(a);
    const batch = circuit.batches[0];
    try batch.hooks.collect_params(batch.ctx, a, &params).unwrap();
    var seen: u8 = 0;
    for (params.items) |param| {
        if (std.mem.eql(u8, param.param_name, "pwl_td")) {
            try std.testing.expectEqual(@as(f64, 0.5e-9), param.get());
            seen += 1;
        } else if (std.mem.eql(u8, param.param_name, "pwl_repeat")) {
            try std.testing.expectEqual(@as(f64, 0), param.get());
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(u8, 2), seen);
}

test "compile frees the BBD permutation it does not return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a,
        \\* two subcircuit instances
        \\.subckt rc p q
        \\r1 p m 1k
        \\r2 m q 1k
        \\.ends
        \\x1 in mid rc
        \\x2 mid 0 rc
        \\.end
    , .ngspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(std.testing.allocator, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    try nb.tagSubcircuitNodes();
    var circuit = try b.compile();
    compiled = true;
    circuit.deinit();
}
