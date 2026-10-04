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
const ta = builder.test_access;
const z = @import("stdpp");

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

    try std.testing.expectEqual(@as(i64, @backingInt(Wave.pwl)), @as(i64, model.waveform));
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
            try std.testing.expect(b.card_counts.items.len <= @backingInt(device.Library.builtin("vsource")));
    }
}

test "transmission-line cards route to their convolution algorithms" {
    const cases = .{
        .{ "O1 a 0 b 0 line\n.model line LTRA r=0.5 l=250n c=100p len=2\n", "ltra" },
        .{ "O1 a 0 b 0 line\n.model line LTRA r=1 c=100p len=2\n", "ltra" },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=12.45 l=8.972n c=0.468p length=16\n", "txl" },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=0.2 0 0.2 l=9.13n 3.3n 9.13n c=0.365p -0.09p 0.365p length=10\n", "coupled_ltra" },
        .{ "P1 a b c 0 d e f 0 line\n.model line CPL r=0.2 0 0 0.2 0 0.2 l=9n 3n 0 9n 3n 9n c=0.3p -0.03p 0 0.3p -0.03p 0.3p length=10\n", "coupled_ltra3" },
        .{ "P1 a b c d 0 e f g h 0 line\n.model line CPL r=0.2 0 0 0 0.2 0 0 0.2 0 0.2 l=9n 3n 0 0 9n 3n 0 9n 3n 9n c=0.3p -0.03p 0 0 0.3p -0.03p 0 0.3p -0.03p 0.3p length=10\n", "coupled_ltra4" },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try netlist.parse(a, "* line routing\n" ++ case[0] ++ ".end\n", .ngspice);
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
        // The lines hold their history as §5.10 state, staged per converged solve.
        try std.testing.expect(circuit.batches[0].hooks.commit_state == null);
        try std.testing.expect(circuit.batches[0].hooks.update_state != null);
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

// A failed TXL or CPL fit passes the builder and the run refuses it; see
// "a failed line fit refuses every analysis" in src/tests/analyses.zig.
test "unsupported transmission-line cards never select approximate fallbacks" {
    const cases = .{
        .{ "P1 a b c d e 0 f g h i j 0 line\n.model line CPL length=1\n", error.UnsupportedCoupledLineDimension },
        .{ "P1 a b 0 c d 0 line\n.model line CPL r=1 l=1n c=1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1e6 l=1n c=1p length=1\n", error.UnsupportedTransmissionLineParameters },
        .{ "Y1 a 0 b 0 line\n.model line TXL r=1e200 l=1e200 c=1e-100 length=1e150\n", error.UnsupportedTransmissionLineParameters },
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

test "branch probes land on the branch row when the card's nets are new" {
    // Each card's first net (and B1's probed net c) is new to the builder
    // when the card is added, so the device's internal rows start past them.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* probes\nB1 x 0 V=2*V(c)\nE1 y 0 d 0 3\nV1 c 0 1\nV2 d 0 1\n.end\n", .ngspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    var circuit = try b.compile();
    compiled = true;
    defer circuit.deinit();
    const published = try nb.publish(a, &circuit, null);
    var found: u8 = 0;
    for (published.probe_labels, published.probes) |label, row| {
        if (label[0] != 'i') continue;
        // No branch column may alias a named node's row.
        for (1..circuit.n) |i| if (circuit.nodeName(@intCast(i)).len != 0)
            try std.testing.expect(row != i);
        found += 1;
    }
    try std.testing.expectEqual(@as(u8, 4), found);
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

fn cardWith(name: []const u8, kind: u8, positional: []const Value, kv: []const netlist.Kv) netlist.Netlist.View {
    return .{ .name = name, .kind = kind, .pins = &.{}, .positional = positional, .kv = kv, .model = null, .subckt_instance = 0 };
}

test "source cards: DC, AC, DISTOF and waveform keywords read as ngspice reads them" {
    const n = struct {
        fn num(v: f64) Value {
            return .{ .num = v };
        }
        fn name(v: []const u8) Value {
            return .{ .name = v };
        }
    };
    // DC: `dc=` wins, then `DC v`, `DC(v)`, then the first bare number
    // past the AC/DISTOF magnitude and phase.
    try std.testing.expectEqual(@as(?f64, 2), ta.sourceDc(cardWith("v1", 'v', &.{n.num(9)}, &.{.{ .key = "dc", .value = n.num(2) }})));
    try std.testing.expectEqual(@as(?f64, 7), ta.sourceDc(cardWith("v1", 'v', &.{ n.name("dc"), n.num(7) }, &.{})));
    try std.testing.expectEqual(@as(?f64, 4), ta.sourceDc(cardWith("v1", 'v', &.{.{ .group = .{ .name = "dc", .args = &.{n.num(4)} } }}, &.{})));
    try std.testing.expectEqual(@as(?f64, 3), ta.sourceDc(cardWith("v1", 'v', &.{ n.name("ac"), n.num(1), n.num(0), n.num(3) }, &.{})));
    try std.testing.expectEqual(@as(?f64, null), ta.sourceDc(cardWith("v1", 'v', &.{ n.name("distof1"), n.num(1), n.num(0) }, &.{})));
    try std.testing.expectEqual(@as(?f64, null), ta.sourceDc(cardWith("v1", 'v', &.{}, &.{})));

    // AC: bare is 1∠0, one number the magnitude, two magnitude and phase in
    // degrees; a waveform keyword after the magnitude is no phase.
    const bare = ta.sourceAc(cardWith("v1", 'v', &.{n.name("ac")}, &.{})).?;
    try std.testing.expectEqual(@as(f64, 1), bare.re);
    try std.testing.expectEqual(@as(f64, 0), bare.im);
    const quad = ta.sourceAc(cardWith("v1", 'v', &.{ n.name("ac"), n.num(2), n.num(90) }, &.{})).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), quad.re, 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 2), quad.im, 1e-15);
    const then_sin = ta.sourceAc(cardWith("v1", 'v', &.{ n.name("ac"), n.num(3), n.name("sin"), n.num(0), n.num(1) }, &.{})).?;
    try std.testing.expectEqual(@as(f64, 3), then_sin.re);
    try std.testing.expectEqual(@as(f64, 0), then_sin.im);
    const grouped = ta.sourceAc(cardWith("v1", 'v', &.{.{ .group = .{ .name = "ac", .args = &.{n.num(5)} } }}, &.{})).?;
    try std.testing.expectEqual(@as(f64, 5), grouped.re);
    try std.testing.expect(ta.sourceAc(cardWith("v1", 'v', &.{n.num(1)}, &.{})) == null);

    // DISTOF: absent is no drive, bare is 1∠0.
    try std.testing.expectEqual([2]f64{ 0, 0 }, ta.sourceDisto(cardWith("v1", 'v', &.{}, &.{}), "distof1"));
    try std.testing.expectEqual([2]f64{ 1, 0 }, ta.sourceDisto(cardWith("v1", 'v', &.{n.name("distof1")}, &.{}), "distof1"));
    try std.testing.expectEqual([2]f64{ 0.5, 30 }, ta.sourceDisto(cardWith("v1", 'v', &.{ n.name("distof2"), n.num(0.5), n.num(30) }, &.{}), "distof2"));
    try std.testing.expectEqual([2]f64{ 2, 0 }, ta.sourceDisto(cardWith("v1", 'v', &.{}, &.{.{ .key = "distof2", .value = n.num(2) }}), "distof2"));

    try std.testing.expectEqual(Wave.pulse, ta.waveKind("PULSE").?);
    try std.testing.expectEqual(Wave.sffm, ta.waveKind("Sffm").?);
    try std.testing.expect(ta.waveKind("dc") == null);
    try std.testing.expect(ta.waveKind("pulsewidth") == null); // longer than any keyword
}

test "source cards: portnum, z0 and an HSPICE P card" {
    const port = (try ta.sourcePort(cardWith("v1", 'v', &.{}, &.{.{ .key = "portnum", .value = .{ .num = 1 } }}))).?;
    try std.testing.expectEqual(@as(u16, 1), port.num);
    try std.testing.expectEqual(@as(f64, 50), port.z0);
    const positional = (try ta.sourcePort(cardWith("v1", 'v', &.{ .{ .name = "portnum" }, .{ .num = 2 }, .{ .name = "z0" }, .{ .num = 75 } }, &.{}))).?;
    try std.testing.expectEqual(@as(u16, 2), positional.num);
    try std.testing.expectEqual(@as(f64, 75), positional.z0);
    try std.testing.expect((try ta.sourcePort(cardWith("v1", 'v', &.{}, &.{}))) == null);
    for ([_][]const netlist.Kv{
        &.{.{ .key = "portnum", .value = .{ .num = 0 } }},
        &.{.{ .key = "portnum", .value = .{ .num = 1025 } }},
        &.{ .{ .key = "portnum", .value = .{ .num = 1 } }, .{ .key = "z0", .value = .{ .num = 0 } } },
        &.{ .{ .key = "portnum", .value = .{ .num = 1 } }, .{ .key = "hblin_h", .value = .{ .num = 0.5 } } },
        &.{ .{ .key = "portnum", .value = .{ .num = 1 } }, .{ .key = "hblin_s", .value = .{ .num = 2 } } },
    }) |kv| try std.testing.expectError(error.InvalidAnalysisArguments, ta.sourcePort(cardWith("v1", 'v', &.{}, kv)));

    try std.testing.expect(ta.isPortCard(cardWith("p1", 'v', &.{}, &.{})));
    try std.testing.expect(ta.isPortCard(cardWith("x1.P2", 'v', &.{}, &.{})));
    try std.testing.expect(!ta.isPortCard(cardWith("v1", 'v', &.{}, &.{})));
    try std.testing.expect(!ta.isPortCard(cardWith("x1.", 'v', &.{}, &.{})));
    try std.testing.expect(!ta.isPortCard(cardWith("p1", 'r', &.{}, &.{})));
}

test "POLE root products pair conjugates and refuse an unpaired root" {
    try std.testing.expectEqual(@as(f64, 1), try ta.rootProduct(&.{}));
    try std.testing.expectEqual(@as(f64, 1), try ta.rootProduct(&.{ 0, 0 })); // a root at 0 is skipped
    try std.testing.expectEqual(@as(f64, -6), try ta.rootProduct(&.{ 2, 0, -3, 0 }));
    // (−1 + 2j)(−1 − 2j) = 5, in either order.
    try std.testing.expectEqual(@as(f64, 5), try ta.rootProduct(&.{ -1, 2, -1, -2 }));
    try std.testing.expectEqual(@as(f64, 5), try ta.rootProduct(&.{ -1, -2, -1, 2 }));
    try std.testing.expectError(error.UnpairedPoleRoot, ta.rootProduct(&.{ -1, 2 }));
    try std.testing.expectError(error.UnpairedPoleRoot, ta.rootProduct(&.{ -1, 2, -1, -2.1 }));
}

test "CPL and RLGC matrices read their packed triangles" {
    const kv = [_]netlist.Kv{
        .{ .key = "r", .value = .{ .num = 0.2 } },  .{ .key = "", .value = .{ .num = 0 } }, .{ .key = "", .value = .{ .num = 0.3 } },
        .{ .key = "l", .value = .{ .num = 1e-9 } },
    };
    var out: [3]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try ta.cplVector(&kv, "r", &out));
    try std.testing.expectEqualSlices(f64, &.{ 0.2, 0, 0.3 }, &out);
    try std.testing.expectEqual(@as(usize, 1), try ta.cplVector(&kv, "l", &out));
    try std.testing.expectEqual(@as(usize, 0), try ta.cplVector(&kv, "c", &out));
    try std.testing.expectError(error.UnsupportedTransmissionLineParameters, ta.cplVector(&kv, "r", out[0..2]));
    try std.testing.expectError(error.NonFiniteParameter, ta.cplVector(&.{.{ .key = "g", .value = .{ .num = std.math.inf(f64) } }}, "g", &out));
    try std.testing.expectError(error.InvalidParameterValue, ta.cplVector(&.{.{ .key = "g", .value = .{ .name = "x" } }}, "g", &out));

    var m: ta.WMatrices = .{};
    try std.testing.expectEqual(@as(usize, 1), try ta.parseRlgcFile("* one line\n1\n2.5e-7 * L\n1e-10, 5\n", &m));
    try std.testing.expectEqual(@as(f64, 2.5e-7), m.tri[0][0]);
    try std.testing.expectEqual(@as(f64, 1e-10), m.tri[1][0]);
    try std.testing.expectEqual(@as(f64, 5), m.tri[2][0]);
    try std.testing.expectEqual(@as(usize, 2), try ta.parseRlgcFile("2 (1 2 3) [4 5 6]", &m));
    try std.testing.expectEqualSlices(f64, &.{ 4, 5, 6 }, m.tri[1][0..3]);
    for ([_][]const u8{
        "", // no N
        "5 1 2", // N past 4
        "1.5 1 2", // fractional N
        "1 1", // L alone: C is required
        "2 1 2 3 4", // not whole triangles
        "1 1 2 3 4 5 6 7", // seven matrices
    }) |bytes| try std.testing.expectError(error.InvalidParameterValue, ta.parseRlgcFile(bytes, &m));
}

/// Builds `source` (title line first) and returns `needs_tran_op`. The
/// Builder is never compiled.
fn buildDeck(source: []const u8, dialect: netlist.Dialect) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, source, dialect);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    defer b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    return b.needs_tran_op;
}

test "topology: V/L shorts must agree on KVL, current sources need a DC path" {
    try std.testing.expectError(error.VoltageSourceLoop, buildDeck("* loop\nV1 a 0 5\nV2 a 0 3\n.end\n", .ngspice));
    try std.testing.expect(!try buildDeck("* parallel\nV1 a 0 5\nV2 a 0 5\nR1 a 0 1k\n.end\n", .ngspice));
    // A chain of shorts listed against its order, closed by a fourth source:
    // v(c) = 3 agrees with it, 2 does not.
    try std.testing.expect(!try buildDeck("* chain\nV3 c b 1\nV2 b a 1\nV1 a 0 1\nV4 c 0 3\n.end\n", .ngspice));
    try std.testing.expectError(error.VoltageSourceLoop, buildDeck("* chain\nV3 c b 1\nV2 b a 1\nV1 a 0 1\nV4 c 0 2\n.end\n", .ngspice));
    // An inductor is a 0 V short.
    try std.testing.expectError(error.VoltageSourceLoop, buildDeck("* l loop\nV1 a 0 1\nL1 a 0 1u\n.end\n", .ngspice));
    try std.testing.expectError(error.CurrentSourceCutset, buildDeck("* cutset\nI1 0 out 1m\nC1 out 0 1u\n.end\n", .ngspice));
    // A node only capacitors reach needs the transient operating point.
    try std.testing.expect(try buildDeck("* cap node\nV1 a 0 1\nC1 a b 1p\nC2 b 0 1p\n.end\n", .ngspice));
}

test "cards the builder refuses instead of misbinding" {
    // K naming an L card that does not exist.
    try std.testing.expectError(error.KinducUnknownInductor, buildDeck("* k\nL1 a 0 1u\nR1 a 0 1\nK1 L1 L2 0.5\n.end\n", .ngspice));
    // Nine probed nets overflow the B tape's eight control ports.
    try std.testing.expectError(error.UnsupportedBsourceExpression, buildDeck("* b\nB1 x 0 V=V(n1)+V(n2)+V(n3)+V(n4)+V(n5)+V(n6)+V(n7)+V(n8)+V(n9)\n.end\n", .ngspice));
    // URC K = 1 sizes every lump as 0/0.
    try std.testing.expectError(error.InvalidParameterValue, buildDeck("* urc\nU1 a b 0 um l=1 n=3\n.model um URC k=1\n.end\n", .ngspice));
    // A W or S port count far past the models must be refused, not
    // converted to an integer (illegal behaviour for N=1e30).
    try std.testing.expectError(error.UnsupportedCard, buildDeck("* w\nW1 a 0 b 0 rlgcmodel=wm n=1 l=0.1\n.model wm w modeltype=rlgc n=1e30 lo=250n co=100p\n.end\n", .hspice));
    try std.testing.expectError(error.UnsupportedCard, buildDeck("* s\nS1 a 0 mname=sm\n.model sm s tstonefile=x.s1p n=1e30\n.end\n", .hspice));
}

/// Instances `b` added of catalog device `name`.
fn instances(b: *const Builder, comptime name: []const u8) u32 {
    const i = @backingInt(device.Library.builtin(name));
    return if (i < b.card_counts.items.len) b.card_counts.items[i] else 0;
}

test "URC expands into its lump ladder" {
    const cases = .{
        // N given: 2N resistors and 2N - 1 capacitors.
        .{ "U1 a b 0 um l=2 n=4\n.model um URC k=2 rperl=100 cperl=1p\n", 4, false },
        // No N: few enough lumps at this FMAX that the URCsetup floor of 3 holds.
        .{ "U1 a b 0 um\n.model um URC\n", 3, false },
        // ISPERL given, even as 0, swaps the capacitors for diodes.
        .{ "U1 a b 0 um l=1 n=3\n.model um URC isperl=0\n", 3, true },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try netlist.parse(a, "* urc\n" ++ case[0] ++ ".end\n", .ngspice);
        const lib = try device.Library.init(a);
        var b = try Builder.init(a, &lib);
        defer b.deinit();
        var nb = try builder.NetBuilder.init(a, &b, nl);
        try nb.build();
        const lumps: u32 = case[1];
        try std.testing.expectEqual(2 * lumps, instances(&b, "resistor"));
        try std.testing.expectEqual(if (case[2]) 0 else 2 * lumps - 1, instances(&b, "capacitor"));
        try std.testing.expectEqual(if (case[2]) 2 * lumps - 1 else 0, instances(&b, "diode"));
        // Ground, a, b and the 2N - 1 ladder nodes.
        try std.testing.expectEqual(2 * lumps + 2, b.n);
    }
}

/// Builds and freezes `body` (no title, no `.end`) and returns its
/// published `.sp` ports, or publish's error.
fn publishPorts(a: std.mem.Allocator, comptime body: []const u8) ![]const @import("core").query.Port {
    const nl = try netlist.parse(a, "* ports\n" ++ body ++ ".end\n", .ngspice);
    const lib = try a.create(device.Library);
    lib.* = try device.Library.init(a);
    var b = try Builder.init(a, lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    var circuit = try b.compile();
    compiled = true;
    defer circuit.deinit();
    return (try nb.publish(a, &circuit, null)).bindings.ports;
}

test "publish orders .sp ports by portnum and refuses a gapped or doubled set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.MissingPortNumber, publishPorts(a, "V1 a 0 0 AC 1 portnum 2\nR1 a 0 50\n"));
    try std.testing.expectError(error.DuplicatePortNumber, publishPorts(a, "V1 a 0 0 AC 1 portnum 1\nV2 b 0 0 AC 1 portnum 1\nR1 a b 50\n"));
    const ports = try publishPorts(a, "V2 b 0 0 AC 1 portnum 2 z0 75\nV1 a 0 0 AC 1 portnum 1\nR1 a b 50\n");
    try std.testing.expectEqual(@as(usize, 2), ports.len);
    try std.testing.expectEqual(@as(f64, 50), ports[0].z0);
    try std.testing.expectEqual(@as(f64, 75), ports[1].z0);
}

test "publish maps .sp port rows through the BBD permutation" {
    // Two subcircuit instances make a permutation; the port's node and
    // branch must land where the V card's own rows do.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a,
        \\* port behind a bbd permutation
        \\.subckt rc p q
        \\r1 p m 1k
        \\r2 m q 1k
        \\.ends
        \\Vp in 0 0 AC 1 portnum 1 z0 50
        \\x1 in mid rc
        \\x2 mid 0 rc
        \\.end
    , .ngspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    try nb.tagSubcircuitNodes();
    var perm: ?[]const u32 = null;
    var circuit = try b.compilePerm(&perm);
    compiled = true;
    defer circuit.deinit();
    try std.testing.expect(perm != null);
    const bindings = (try nb.publish(a, &circuit, perm)).bindings;
    try std.testing.expectEqual(@as(usize, 1), bindings.ports.len);
    try std.testing.expectEqual(bindings.v_pos[0], bindings.ports[0].node);
    try std.testing.expectEqual(bindings.v_branches[0], bindings.ports[0].branch);
}

test "AC sources land in one stacked excitation" {
    // I1 0 a AC 2 pushes 2 A into a; V1's AC drives its branch row.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* ac\nV1 b 0 0 AC 1 90\nI1 0 a AC 2\nR1 a 0 1\nR2 b 0 1\n.end\n", .ngspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    var compiled = false;
    defer if (!compiled) b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    var circuit = try b.compile();
    compiled = true;
    defer circuit.deinit();
    const out = try nb.publish(a, &circuit, null);
    const n = circuit.n;
    try std.testing.expectEqual(2 * @as(usize, n), out.ac_drive.len);
    const row_a = for (out.probe_labels, out.probes) |label, row| {
        if (std.mem.eql(u8, label, "v(a)")) break row;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 2), out.ac_drive[row_a]);
    const br = out.bindings.v_branches[0];
    try std.testing.expectApproxEqAbs(@as(f64, 0), out.ac_drive[br], 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 1), out.ac_drive[n + br], 1e-15);
    var total: f64 = 0;
    for (out.ac_drive) |v| total += @abs(v);
    try std.testing.expectApproxEqRel(@as(f64, 3), total, 1e-12);
}

test "HSPICE W card fits a lossy line onto wline_1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a, "* w\nW1 a 0 b 0 rlgcmodel=wm n=1 l=0.2\n.model wm w modeltype=rlgc n=1 lo=300n co=120p ro=5\n.end\n", .hspice);
    const lib = try device.Library.init(a);
    var b = try Builder.init(a, &lib);
    defer b.deinit();
    var nb = try builder.NetBuilder.init(a, &b, nl);
    try nb.build();
    try std.testing.expectEqual(@as(usize, 1), b.protos.items.len);
    try std.testing.expectEqualStrings(device.vtable("wline_1").name, b.protos.items[0].type_name);
}

test "stdpp max over port numbers matches its pull-path oracle" {
    // portList's pipeline at every length to past 3×32 u16 lanes, and four
    // misalignments; values include 0 (not a port) and the u16 maximum.
    var prng = std.Random.DefaultPrng.init(0x9047);
    const rnd = prng.random();
    var buf: [3 * 32 + 8]u16 = undefined;
    for (&buf) |*v| v.* = switch (rnd.uintLessThan(u8, 8)) {
        0 => 0,
        1 => std.math.maxInt(u16),
        else => rnd.int(u16),
    };
    for (0..4) |off| for (0..buf.len - off) |len| {
        const xs = buf[off..][0..len];
        var fast = z.fromSlice(u16, xs);
        var src = z.fromSlice(u16, xs);
        var slow = src.byRef();
        try std.testing.expectEqual(slow.max(), fast.max());
    };
}
