//! Query-boundary validation and Session scheduling tests.

const Deck = @import("core").Deck;
const builtin = @import("device").Library.builtin;
const requests = @import("core").query;
const std = @import("std");
const validate = @import("../validate.zig").validate;
const validateDeck = @import("../validate.zig").validateDeck;

test "query boundary rejects nonfinite values and nonterminating sweeps" {
    const t = std.testing;
    try t.expectError(error.InvalidQueryOptions, validate(.{ .ac = .{ .sweep = .{ .f_start = 0, .f_stop = 1 } } }, 4));
    try t.expectError(error.InvalidQueryOptions, validate(.{ .dc = .{ .start = 0, .stop = 1, .step = -1 } }, 4));
    try t.expectError(error.InvalidQueryOptions, validate(.{ .tran = .{ .t_stop = std.math.inf(f64) } }, 4));
    try validate(.{ .tran = .{ .t_stop = 1e-6 } }, 4);
    try validate(.{ .temp = .{ .t_start = -40, .t_stop = -10 } }, 4);
}

test "query boundary checks derived frequencies, dimensions and nested controls" {
    const t = std.testing;
    const invalid = [_]requests.Query{
        .{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 1e308 } } },
        .{ .hb = .{ .f0 = 1e3, .n_harmonics = 0 } },
        .{ .qpss = .{ .f1 = 1e3, .f2 = 2e3, .k1 = 65535, .k2 = 65535 } },
        .{ .pss = .{ .period = 1e-308, .n_samples = 65536 } },
        .{ .tran = .{ .t_stop = 1, .dt_min = 1e-320 } },
        .{ .four = .{ .f_fundamental = 1e-308 } },
        .{ .matex = .{ .t_stop = 1, .m_max = std.math.maxInt(u32) } },
        .{ .matex = .{ .t_stop = 1, .gamma = -1 } },
        .{ .mc = .{ .dc_options = .{ .tol = .{ .abstol = -1 } } } },
        .{ .temp = .{ .dc_options = .{ .step = 0 } } },
        .{ .temp = .{ .t_start = 100, .t_stop = 0, .t_step = -1 } },
        .{ .dc = .{ .start = 1e20, .stop = 1e20 + 1e6, .step = 1 } },
        .{ .envelope = .{ .t_carrier = 1e-3, .t_stop = 1, .max_outer_steps = std.math.maxInt(u32) } },
    };
    for (invalid) |query| try t.expectError(error.InvalidQueryOptions, validate(query, 4));
    try validate(.{ .op = .{} }, 4);
    try validate(.{ .mc = .{} }, 4);
    try validate(.{ .hb = .{ .f0 = 1e3 } }, 4);
    try validate(.{ .qpss = .{ .f1 = 1e3, .f2 = 1414 } }, 4);
}

test "a dc sweep target resolves against the prepared card table, type included" {
    var deck: Deck = undefined;
    deck.cards = &.{
        .{ .type = builtin("vsource"), .index = 0, .name = "v1" },
        .{ .type = builtin("isource"), .index = 0, .name = "i1" },
        .{ .type = builtin("resistor"), .index = 1, .name = "r2" },
    };
    try validateDeck(.{ .dc = .{ .target = .{ .device = .{ .type = builtin("vsource") } } } }, 4, &deck);
    // Same ordinal, different device type: the two no longer alias.
    try validateDeck(.{ .dc = .{ .target = .{ .device = .{ .type = builtin("isource"), .index = 0 } } } }, 4, &deck);
    try validateDeck(.{ .dc = .{ .target = .{ .device = .{ .type = builtin("resistor"), .index = 1, .param_name = "r" } } } }, 4, &deck);
    try std.testing.expectError(error.DcSweepSourceNotFound, validateDeck(.{ .dc = .{ .target = .{ .device = .{ .index = 1 } } } }, 4, &deck));
    try std.testing.expectError(error.DcSweepSourceNotFound, validateDeck(.{ .dc = .{ .target = .{ .device = .{ .type = builtin("vsource") } }, .target2 = .{ .device = .{ .type = builtin("resistor"), .index = 0 } } } }, 4, &deck));
    // The temperature is not a card and is never looked up.
    try validateDeck(.{ .dc = .{ .target = .{ .device = .{ .type = builtin("vsource") } }, .target2 = .temp } }, 4, &deck);
}

test "fft sample count is bounded before the power-of-two test" {
    const t = std.testing;
    const base: requests.Fft = .{ .tran = .{ .t_stop = 1e-6 }, .out_pos = 1, .start = 0, .stop = 1e-6, .label = "v(1)" };
    // 0 used to reach `isPowerOfTwo`, which asserts a positive argument.
    for ([_]u32{ 0, 1, 2, 3, 6, 1000, (1 << 27) + 1, 1 << 28, std.math.maxInt(u32) }) |np| {
        var o = base;
        o.np = np;
        try t.expectError(error.InvalidQueryOptions, validate(.{ .fft = o }, 4));
    }
    for ([_]u32{ 4, 1024, 1 << 27 }) |np| {
        var o = base;
        o.np = np;
        try validate(.{ .fft = o }, 4);
    }
}

test "backend validation rejects zero thread counts" {
    const validateBackend = @import("../executor.zig").validateBackend;
    try validateBackend(.{});
    try std.testing.expectError(error.InvalidThreadCount, validateBackend(.{ .solver_threads = 0 }));
    try std.testing.expectError(error.InvalidThreadCount, validateBackend(.{ .device_threads = 0 }));
}

test "backend validation refuses an explicit GPU this build has no kernels for" {
    const validateBackend = @import("../executor.zig").validateBackend;
    const requestSupported = @import("../gpu.zig").requestSupported;
    try validateBackend(.{ .backend = .auto });
    inline for (.{ .cuda, .hip }) |be| {
        if (requestSupported(be))
            try validateBackend(.{ .backend = be })
        else
            try std.testing.expectError(error.GpuBackendUnavailable, validateBackend(.{ .backend = be }));
    }
}

const Session = @import("../session.zig").Session;
const Status = @import("../session.zig").Status;
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const models = @import("models");
const GROUND = @import("../types.zig").GROUND;

/// A deck with nothing in it but `probes`, for driving a Session by hand.
fn bareDeck(probes: []const u32, labels: []const []const u8) Deck {
    return .{
        .probes = probes,
        .probe_labels = labels,
        .source_node = 0,
        .source_branch = 0,
        .output_node = 0,
        .ac_drive = &.{},
        .title = "",
        .n_devices = 0,
        .ic = &.{},
        .deck_tol = .{},
        .deck_temp = null,
        .deck_method = null,
        .queries = &.{},
        .bindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} },
        .cards = &.{},
        .ac_overrides = &.{},
    };
}

test "session shares one OP prerequisite and gates its dependents on it" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(models.vsource, "", .{ .dc = 10 }, .{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", .{ .r = 1000 }, .{}, .{ vin, out });
    try b.addDevice(models.resistor, "", .{ .r = 3000 }, .{}, .{ out, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    const deck = bareDeck(&.{out}, &.{"v(out)"});
    var s = Session.init(t.allocator, t.io, &prepared, &deck, .{});
    defer s.deinit();

    const ac1: requests.Query = .{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 1e3 } } };
    const ac2: requests.Query = .{ .ac = .{ .sweep = .{ .f_start = 10, .f_stop = 1e4 } } };
    var ids: [3]requests.QueryId = undefined;
    try t.expectError(error.BufferTooSmall, s.append(&.{ ac1, ac2, .{ .op = .{} } }, ids[0..2]));
    // All-or-nothing: one bad job publishes no row.
    const bad: requests.Query = .{ .ac = .{ .sweep = .{ .f_start = 0, .f_stop = 1 } } };
    try t.expectError(error.InvalidQueryOptions, s.append(&.{ ac1, bad }, &ids));
    try t.expectEqual(@as(u32, 0), s.count());
    try t.expectEqual(@as(usize, 0), try s.append(&.{}, &ids));

    try t.expectEqual(@as(usize, 3), try s.append(&.{ ac1, ac2, .{ .op = .{} } }, &ids));
    // Row 0 is the implicit OP; the explicit `.op` resolves to it.
    try t.expectEqual(@as(u32, 3), s.count());
    const op_id: requests.QueryId = @fromBackingInt(0);
    try t.expectEqual(op_id, ids[2]);
    for (ids[0..2]) |id| {
        const q = try s.info(id);
        try t.expectEqual(op_id, q.dependency.?);
        try t.expectEqual(@as(u32, 0), q.component);
        try t.expectEqual(Status.pending, q.status);
    }
    try t.expect((try s.info(op_id)).requested);
    try t.expectError(error.InvalidQuery, s.info(@fromBackingInt(3)));
    try t.expectError(error.InvalidComponent, s.readyQueries(.{ .component = 7 }, &ids));

    // Only the OP is ready; a short buffer gets the count and no writes.
    var ready: [3]requests.QueryId = undefined;
    try t.expectEqual(@as(usize, 1), try s.readyQueries(.all, ready[0..0]));
    try t.expectEqual(@as(usize, 1), try s.readyQueries(.all, &ready));
    try t.expectEqual(op_id, ready[0]);
    var events: [2]@import("../session.zig").Advance = undefined;
    try t.expectError(error.QueryNotReady, s.advanceReady(ids[0..1], .{}, &events));
    try t.expectError(error.DuplicateQuery, s.advanceReady(&.{ op_id, op_id }, .{}, &events));
    try t.expectError(error.InvalidConcurrency, s.advanceReady(&.{op_id}, .{ .max_parallel = 0 }, &events));
    try t.expectError(error.ResultUnavailable, s.result(ids[0]));

    var text: std.Io.Writer.Allocating = .init(t.allocator);
    defer text.deinit();
    try s.print(&text.writer, .{ .ascii = true });
    try t.expect(std.mem.indexOf(u8, text.written(), "3 total queries, 1 components") != null);
    try t.expect(std.mem.indexOf(u8, text.written(), "q0 op [ready; NEXT") != null);
    try t.expect(std.mem.indexOf(u8, text.written(), "waiting for q0") != null);

    // Advancing a dependent runs its prerequisite first.
    while (!(try s.info(op_id)).status.terminal()) {
        const step = try s.advance(ids[0]);
        try t.expectEqual(op_id, step.advanced);
        try t.expectEqual(ids[0], step.requested);
    }
    try t.expectEqual(Status.complete, (try s.info(op_id)).status);
    const res = try s.result(op_id);
    try t.expectEqual(@as(usize, 1), res.data.len);
    // The divider's analytic value: 10 V * 3k / (1k + 3k).
    try t.expectApproxEqRel(@as(f64, 7.5), res.data[0], 1e-9);
    try t.expectEqual(@as(usize, 2), try s.readyQueries(.all, &ready));
    try t.expect(!s.finished());
    try t.expectEqual(null, s.failure());
}
