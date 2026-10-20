//! Query-boundary validation and Session scheduling tests. Oracles: the
//! named refusal each invalid query must get (the frontend's own refusals
//! for `validate`), the dependency order a Session must keep, and the
//! columns a run publishes for `schemaOf`'s prediction.

const Deck = @import("core").Deck;
const builtin = @import("device").Library.builtin;
const requests = @import("core").query;
const std = @import("std");
const validate = @import("core").validate.validate;
const validateDeck = @import("core").validate.validateDeck;

test "query boundary rejects nonfinite values and nonterminating sweeps" {
    const t = std.testing;
    try t.expectError(error.InvalidQueryOptions, validate(.{ .ac = .{ .sweep = .{ .f_start = 0, .f_stop = 1 } } }, 4));
    try t.expectError(error.InvalidQueryOptions, validate(.{ .dc = .{ .start = 0, .stop = 1, .step = -1 } }, 4));
    try t.expectError(error.InvalidQueryOptions, validate(.{ .tran = .{ .t_stop = std.math.inf(f64) } }, 4));
    try validate(.{ .tran = .{ .t_stop = 1e-6 } }, 4);
    try validate(.{ .temp = .{ .t_start = -40, .t_stop = -10 } }, 4);
}

test "query boundary refuses a v(a,b) reference on .hbxf and .hbac (#201)" {
    const t = std.testing;
    const lptv: requests.HbLptv = .{ .f0 = 1e3, .out_node = 1, .out_neg = 2, .sweep = .{ .f_start = 10, .f_stop = 100 } };
    try t.expectError(error.InvalidQueryOptions, validate(.{ .hbxf = lptv }, 4));
    try t.expectError(error.InvalidQueryOptions, validate(.{ .hbac = lptv }, 4));
    // `.hbnoise` measures v(a,b), and a single-ended `.hbxf` still passes.
    try validate(.{ .hbnoise = lptv }, 4);
    var single = lptv;
    single.out_neg = 0;
    try validate(.{ .hbxf = single }, 4);
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

test "validate: every node and branch row a driver indexes with is in range" {
    const t = std.testing;
    const sweep: requests.FreqSweep = .{ .f_start = 1, .f_stop = 1e3 };
    const far = 4;
    const ports = [_]requests.Port{.{ .node = 1, .neg = far, .branch = 2 }};
    const zero_z0 = [_]requests.Port{.{ .node = 1, .neg = 0, .branch = 2, .z0 = 0 }};
    const out_of_range = [_]requests.Query{
        .{ .noise = .{ .out_node = 1, .sweep = sweep, .in_nodes = .{ 1, far } } },
        .{ .tf = .{ .output_node = 1, .input_nodes = .{ far, 0 } } },
        .{ .tf = .{ .output_node = 1, .output_neg = far } },
        .{ .tf = .{ .output_node = 1, .output_branch = far } },
        .{ .pz = .{ .in_pos = far } },
        .{ .pz = .{ .in_neg = far } },
        .{ .pz = .{ .out_pos = far } },
        .{ .stb = .{ .sweep = sweep, .probe_p = 1, .probe_n = 2, .probe_branch = far } },
        .{ .sens = .{ .output_node = 1, .output_neg = far } },
        .{ .dcmatch = .{ .output_node = 1, .output_neg = far } },
        .{ .acmatch = .{ .sweep = sweep, .output_node = 1, .output_neg = far } },
        .{ .dcsens = .{ .output_node = 1, .output_neg = far } },
        .{ .lstb = .{ .sweep = sweep, .probes = @splat(.{ .p = 1, .n = 2, .branch = 3 }), .local_gnd = far } },
        .{ .hblin = .{ .f0 = 1e3, .sweep = sweep, .ports = &ports } },
        .{ .hblin = .{ .f0 = 1e3, .sweep = sweep, .ports = &zero_z0 } },
    };
    for (out_of_range) |query| try t.expectError(error.InvalidQueryOptions, validate(query, far));
    try validate(.{ .tf = .{ .output_node = 1, .input_nodes = .{ 1, 0 }, .output_branch = 3 } }, far);
}

test "validate: refuses what the frontend refuses" {
    const t = std.testing;
    const refused = [_]requests.Query{
        .{ .op = .{ .tol = .{ .temp_c = -273.15 } } },
        .{ .temp = .{ .t_start = -300, .t_stop = 0, .t_step = 1 } },
        .{ .tran = .{ .t_stop = 1e-6, .xmu = 0.6 } },
        .{ .tran = .{ .t_stop = 1e-6, .xmu = -0.1 } },
        .{ .tran = .{ .t_stop = 1e-6, .t_start = -1e-9 } },
        .{ .tran = .{ .t_stop = 1e-6, .t_start = 1e-6 } },
    };
    for (refused) |query| try t.expectError(error.InvalidQueryOptions, validate(query, 4));
    try validate(.{ .tran = .{ .t_stop = 1e-6, .t_start = 5e-7, .xmu = 0, .tol = .{ .temp_c = -273 } } }, 4);
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
    try b.addDevice(models.vsource, "", &.{ .dc = 10 }, &.{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ vin, out });
    try b.addDevice(models.resistor, "", &.{ .r = 3000 }, &.{}, .{ out, GROUND });
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

    // Only the OP is ready; a short buffer fails and readyCount sizes it.
    var ready: [3]requests.QueryId = undefined;
    try t.expectEqual(@as(usize, 1), try s.readyCount(.all));
    try t.expectError(error.BufferTooSmall, s.readyQueries(.all, ready[0..0]));
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

test "a failed implicit OP's own error is the session failure, not DependencyFailed" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ vin, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    const deck = bareDeck(&.{vin}, &.{"v(vin)"});
    var s = Session.init(t.allocator, t.io, &prepared, &deck, .{});
    defer s.deinit();
    var ids: [1]requests.QueryId = undefined;
    _ = try s.append(&.{.{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 1e3 } } }}, &ids);
    const op_id: requests.QueryId = @fromBackingInt(0);
    try t.expect(!(try s.info(op_id)).requested);
    // The OP prerequisite ends as a worker records an allocation failure.
    s.rows.items(.status)[0] = .failed;
    s.rows.items(.failure)[0] = error.OutOfMemory;
    try t.expectEqual(Status.dependency_failed, (try s.info(ids[0])).status);
    try t.expectEqual(error.OutOfMemory, s.failure().?);
    // A batch past the u32 row space; only its length is read (#55).
    const huge = std.math.maxInt(usize) / 2 + 1;
    const one: requests.Query = .{ .op = .{} };
    const jobs: [*]const requests.Query = @ptrCast(&one);
    const many: [*]requests.QueryId = &ids;
    try t.expectError(error.TooManyQueries, s.append(jobs[0..huge], many[0..huge]));
}

test "schemaOf names the plot and scale column a transient and an AC sweep publish" {
    const t = std.testing;
    const schemaOf = @import("../session.zig").schemaOf;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ vin, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    const deck = bareDeck(&.{vin}, &.{"v(vin)"});
    var s = Session.init(t.allocator, t.io, &prepared, &deck, .{});
    defer s.deinit();
    const jobs = [_]requests.Query{
        .{ .tran = .{ .t_stop = 1e-9 } },
        .{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 1e3 } } },
    };
    var ids: [jobs.len]requests.QueryId = undefined;
    _ = try s.append(&jobs, &ids);
    for (jobs, ids) |job, id| {
        var steps: u32 = 0;
        while (!(try s.info(id)).status.terminal()) : (steps += 1) {
            try t.expect(steps < 100_000);
            _ = try s.advance(id);
        }
        const res = try s.result(id);
        const schema = try schemaOf(t.allocator, &prepared, &deck, job);
        try t.expectEqualStrings(res.plotname, schema.plotname);
        try t.expectEqualStrings(res.varnames[0], schema.scale);
    }
    // A query that has run cannot start streaming (#13).
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try t.expect(!try s.streamTo(ids[0], &sink.writer));
    try t.expectEqual(null, s.stream);
    // A query that does not stream names no plot.
    try t.expectEqual(0, (try schemaOf(t.allocator, &prepared, &deck, .{ .op = .{} })).plotname.len);
}

test "schemaOf predicts the columns envelope and noise publish (#83)" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ vin, out });
    try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ out, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    const deck = bareDeck(&.{ vin, out }, &.{ "v(vin)", "v(out)" });
    const sweep: requests.FreqSweep = .{ .f_start = 1, .f_stop = 1e3 };
    const queries = [_]requests.Query{
        .{ .envelope = .{ .t_carrier = 1e-6, .t_stop = 1e-5 } },
        .{ .noise = .{ .out_node = out, .sweep = sweep } },
        .{ .noise = .{ .out_node = out, .sweep = sweep, .integrated = true } },
        .{ .noise = .{ .out_node = out, .sweep = sweep, .contributions = true } },
        .{ .noise = .{ .out_node = out, .sweep = sweep, .contributions = true, .integrated = true } },
    };
    for (queries) |q| {
        var s = Session.init(t.allocator, t.io, &prepared, &deck, .{});
        defer s.deinit();
        var ids: [1]requests.QueryId = undefined;
        _ = try s.append(&.{q}, &ids);
        while (!(try s.info(ids[0])).status.terminal()) _ = try s.advance(ids[0]);
        const res = try s.result(ids[0]);
        const schema = try @import("../session.zig").schemaOf(t.allocator, &prepared, &deck, q);
        try t.expectEqual(res.varnames.len, schema.columns);
    }
}

/// Runs every query in `jobs` to completion over `prepared`, `device_threads`
/// stamp lanes. With a seed, each round's ready set runs at once in an order
/// shuffled by it; without one, one at a time in row order. Returns each
/// requested result's data, concatenated, owned by the caller.
fn runAll(prepared: *const @import("device").Circuit, deck: *const Deck, jobs: []const requests.Query, device_threads: u32, seed: ?u64) ![]f64 {
    const t = std.testing;
    var s = Session.init(t.allocator, t.io, prepared, deck, .{ .device_threads = device_threads });
    defer s.deinit();
    var ids: [8]requests.QueryId = undefined;
    _ = try s.append(jobs, ids[0..jobs.len]);
    var prng = std.Random.DefaultPrng.init(seed orelse 0);
    var ready: [16]requests.QueryId = undefined;
    var events: [16]@import("../session.zig").Advance = undefined;
    var rounds: usize = 0;
    while (!s.finished()) : (rounds += 1) {
        try t.expect(rounds < 16);
        const n = try s.readyQueries(.all, &ready);
        try t.expect(n > 0);
        if (seed != null) prng.random().shuffle(requests.QueryId, ready[0..n]);
        const limits: @import("../session.zig").Limits = .{ .max_parallel = if (seed == null) 1 else @intCast(n), .quantum = .completion };
        _ = try s.advanceReady(ready[0..n], limits, &events);
    }
    try t.expectEqual(null, s.failure());
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(t.allocator);
    for (ids[0..jobs.len]) |id| try out.appendSlice(t.allocator, (try s.result(id)).data);
    return out.toOwnedSlice(t.allocator);
}

test "--jobs determinism: results are byte-identical across lane counts and scheduler orders" {
    // TESTING-METHODOLOGY 2.1 item 6: `--jobs=1` against N, plus a seeded
    // permutation of each round's ready set. The oracle is the serial run.
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 1 }, &.{}, .{ vin, GROUND });
    var prev = vin;
    for (0..8) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, mid });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-9 }, &.{}, .{ mid, GROUND });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14, .cjo = 1e-12 }, &.{}, .{ mid, GROUND });
        prev = mid;
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    const drive = try t.allocator.alloc(f64, 2 * @as(usize, prepared.n));
    defer t.allocator.free(drive);
    @memset(drive, 0);
    drive[prev] = 1e-3; // 1 mA AC into the last stage.
    var deck = bareDeck(&.{ vin, prev }, &.{ "v(in)", "v(out)" });
    deck.ac_drive = drive;
    // Two OP prerequisites (two tolerance sets), so two components race.
    const jobs = [_]requests.Query{
        .{ .op = .{} },
        .{ .ac = .{ .sweep = .{ .f_start = 1e3, .f_stop = 1e9 } } },
        .{ .tran = .{ .t_stop = 2e-6 } },
        .{ .tran = .{ .t_stop = 1e-6, .tol = .{ .reltol = 1e-4 } } },
        .{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 1e6 }, .tol = .{ .reltol = 1e-4 } } },
    };
    const serial = try runAll(&prepared, &deck, &jobs, 1, null);
    defer t.allocator.free(serial);
    try t.expect(serial.len > jobs.len);
    for ([_]u32{ 1, 4 }) |lanes| for ([_]u64{ 1, 2, 3 }) |seed| {
        const got = try runAll(&prepared, &deck, &jobs, lanes, seed);
        defer t.allocator.free(got);
        try t.expectEqualSlices(u64, @ptrCast(serial), @ptrCast(got));
    };
}

test "variant rows re-derive only the batches they write, bitwise as a full recompute (#214)" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 2 }, &.{}, .{ vin, GROUND });
    var prev = vin;
    for (0..3) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, mid });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-9 }, &.{}, .{ mid, GROUND });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14, .cjo = 1e-12 }, &.{}, .{ mid, GROUND });
        prev = mid;
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    var probe = try @import("../types.zig").Circuit.instantiate(&prepared, t.allocator);
    defer probe.deinit();
    const params = try probe.collectParams();
    const Find = struct {
        fn ref(ps: anytype, ty: @import("core").DeviceType, index: u32, name: []const u8) !u32 {
            for (ps, 0..) |p, k| {
                if (p.type == ty and p.index == index and std.mem.eql(u8, p.param_name, name)) return @intCast(k);
            }
            return error.TestUnexpectedResult;
        }
    };
    const r1 = try Find.ref(params, builtin("resistor"), 1, "r");
    const is2 = try Find.ref(params, builtin("diode"), 2, "is");
    const c0 = try Find.ref(params, builtin("capacitor"), 0, "c");
    // One batch, two batches, every batch under a temperature, and none.
    const labels = [_][]const u8{ "a", "b", "c", "d" };
    const temps = [_]?f64{ null, null, 85, null };
    const starts = [_]u32{ 0, 1, 4, 5, 5 };
    const refs = [_]u32{ r1, is2, c0, r1, r1 };
    const values = [_]f64{ 3e3, 1e-13, 2e-9, 500, 4e3 };
    var deck = bareDeck(&.{ vin, prev }, &.{ "v(in)", "v(out)" });
    deck.variants = .{ .labels = &labels, .temp_c = &temps, .starts = &starts, .refs = &refs, .values = &values };
    var jobs: [labels.len]requests.Query = undefined;
    for (&jobs, 0..) |*j, k| j.* = .{ .tran = .{ .t_stop = 2e-6, .tol = .{ .variant = @intCast(k) } } };
    // Without `param_starts` every query collects and re-derives every batch.
    const full = try runAll(&prepared, &deck, &jobs, 1, null);
    defer t.allocator.free(full);
    try prepared.countParams();
    try t.expectEqual(prepared.batches.len + 1, prepared.param_starts.len);
    try t.expectEqual(@as(u32, @intCast(params.len)), prepared.param_starts[prepared.batches.len]);
    const narrow = try runAll(&prepared, &deck, &jobs, 1, null);
    defer t.allocator.free(narrow);
    try t.expectEqualSlices(u64, @ptrCast(full), @ptrCast(narrow));
}

test "lane batches: OP and .dc rows at several temperatures group into batches and each equals its run alone, bitwise" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 3 }, &.{}, .{ vin, GROUND });
    var prev = vin;
    for (0..4) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, mid });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ mid, GROUND });
        prev = mid;
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    var deck = bareDeck(&.{ vin, prev }, &.{ "v(in)", "v(out)" });
    deck.cards = &.{.{ .type = builtin("vsource"), .index = 0, .name = "v1" }};
    // More rows than one batch holds, and a lone tolerance set that groups
    // with nobody.
    const temps = [_]f64{ -40, 0, 27, 85, 150, 27, 400, 1000, 60, -10 };
    // Each temperature's OP, then a `.dc` of the source from that point.
    var jobs: [2 * temps.len + 1]requests.Query = undefined;
    const target: requests.Dc.SweepTarget = .{ .device = .{ .type = builtin("vsource") } };
    for (jobs[0..temps.len], jobs[temps.len..][0..temps.len], temps) |*j, *d, temp| {
        j.* = .{ .op = .{ .tol = .{ .temp_c = temp } } };
        d.* = .{ .dc = .{ .target = target, .start = 0, .stop = 3, .step = 0.25, .tol = .{ .temp_c = temp } } };
    }
    jobs[2 * temps.len] = .{ .op = .{ .tol = .{ .reltol = 1e-4 } } };
    var out: [2][]f64 = undefined;
    var batched: usize = 0;
    var dc_batched: usize = 0;
    for ([_]bool{ false, true }, &out) |lanes, *o| {
        var config: @import("../executor.zig").Config = .{};
        config.knobs.lanes = lanes;
        var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
        defer s.deinit();
        var ids: [jobs.len]requests.QueryId = undefined;
        _ = try s.append(&jobs, &ids);
        try s.runAll(.{ .max_parallel = 2, .quantum = .completion });
        try t.expectEqual(null, s.failure());
        for (s.rows.items(.executor), s.rows.items(.job)) |e, j| {
            batched += e.?.peers.len;
            dc_batched += if (j == .dc) e.?.peers.len else 0;
        }
        var list: std.ArrayList(f64) = .empty;
        errdefer list.deinit(t.allocator);
        for (ids) |id| try list.appendSlice(t.allocator, (try s.result(id)).data);
        o.* = try list.toOwnedSlice(t.allocator);
    }
    defer for (out) |o| t.allocator.free(o);
    try t.expect(batched > 0 and dc_batched > 0);
    try t.expectEqualSlices(u64, @ptrCast(out[0]), @ptrCast(out[1]));
}

test "lane batches: a NaN value, failing, peeling and re-pivoting lanes leave the others bitwise and fail as they do alone" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    const mid = try b.addNode();
    const low = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 3 }, &.{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ vin, mid });
    try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ mid, low });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ low, GROUND });
    try b.addDevice(models.diode, "", &.{ .is = 1e-12 }, &.{}, .{ low, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    // Variant k writes the first resistor's `r`.
    var probe = try @import("../types.zig").Circuit.instantiate(&prepared, t.allocator);
    defer probe.deinit();
    const params = try probe.collectParams();
    const r_ref: u32 = for (params, 0..) |p, k| {
        if (p.type == builtin("resistor") and p.index == 0 and std.mem.eql(u8, p.param_name, "r")) break @intCast(k);
    } else return error.TestUnexpectedResult;
    const values = [_]f64{ 1e3, 2e3, std.math.nan(f64), 1e-30, 5e3, -1e3, 0, 1e12, 7e3, 10, 1e-9 };
    var labels: [values.len][]const u8 = undefined;
    var starts: [values.len + 1]u32 = undefined;
    var refs: [values.len]u32 = undefined;
    var temps: [values.len]?f64 = undefined;
    for (&labels, starts[0..values.len], &refs, &temps, 0..) |*l, *s0, *r, *tc, k| {
        l.* = "r";
        s0.* = @intCast(k);
        r.* = r_ref;
        tc.* = null;
    }
    starts[values.len] = values.len;
    var deck = bareDeck(&.{ vin, mid, low }, &.{ "v(in)", "v(mid)", "v(low)" });
    deck.variants = .{ .labels = &labels, .temp_c = &temps, .starts = &starts, .refs = &refs, .values = &values };
    deck.cards = &.{.{ .type = builtin("vsource"), .index = 0, .name = "v1" }};
    const target: requests.Dc.SweepTarget = .{ .device = .{ .type = builtin("vsource") } };
    var jobs: [2 * values.len]requests.Query = undefined;
    for (jobs[0..values.len], jobs[values.len..], 0..) |*o, *d, k| {
        o.* = .{ .op = .{ .tol = .{ .variant = @intCast(k) } } };
        d.* = .{ .dc = .{ .target = target, .start = -1, .stop = 3, .step = 0.5, .tol = .{ .variant = @intCast(k) } } };
    }
    const Row = struct { status: Status, failure: ?@import("../session.zig").Failure, data: []f64 };
    var rows: [2][jobs.len]Row = undefined;
    var batched: usize = 0;
    for ([_]bool{ false, true }, &rows) |lanes, *out| {
        var config: @import("../executor.zig").Config = .{};
        config.knobs.lanes = lanes;
        var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
        defer s.deinit();
        var ids: [jobs.len]requests.QueryId = undefined;
        _ = try s.append(&jobs, &ids);
        try s.runAll(.{ .max_parallel = 1, .quantum = .completion });
        for (s.rows.items(.executor)) |e| if (e) |x| {
            batched += x.peers.len;
        };
        for (ids, out) |id, *r| {
            const q = try s.info(id);
            r.* = .{ .status = q.status, .failure = q.failure, .data = &.{} };
            if (q.status == .complete) r.data = try t.allocator.dupe(f64, (try s.result(id)).data);
        }
    }
    defer for (rows) |rs| for (rs) |r| t.allocator.free(r.data);
    try t.expect(batched > 0);
    var completed: usize = 0;
    for (rows[0], rows[1]) |a, c| {
        try t.expectEqual(a.status, c.status);
        try t.expectEqual(a.failure, c.failure);
        try t.expectEqualSlices(u64, @ptrCast(a.data), @ptrCast(c.data));
        completed += @intFromBool(a.status == .complete);
    }
    // Some lanes must fail for the test to mean anything, and most finish.
    try t.expect(completed > jobs.len / 2 and completed < jobs.len);
}

test "split lanes (#213): .mc trials, .dc DATA= variants and a .temp range run as lane rows, batched or not, at any --jobs, and assemble bitwise the lanes run alone" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    const mid = try b.addNode();
    const low = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 3 }, &.{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ vin, mid });
    try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ mid, low });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ low, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    // Variant k writes the first resistor's `r`; NaN and the negative one
    // leave lanes unconverged, which the assembled sweep drops.
    var probe = try @import("../types.zig").Circuit.instantiate(&prepared, t.allocator);
    defer probe.deinit();
    const params = try probe.collectParams();
    const r_ref: u32 = for (params, 0..) |p, k| {
        if (p.type == builtin("resistor") and p.index == 0 and std.mem.eql(u8, p.param_name, "r")) break @intCast(k);
    } else return error.TestUnexpectedResult;
    const values = [_]f64{ 1e3, 2e3, std.math.nan(f64), 3e3, 5e3, -1e3, 7e3, 1e4, 2e4, 10, 1e5 };
    var labels: [values.len][]const u8 = undefined;
    var starts: [values.len + 1]u32 = undefined;
    var refs: [values.len]u32 = undefined;
    var temps: [values.len]?f64 = undefined;
    var axis: [values.len]f64 = undefined;
    for (&labels, starts[0..values.len], &refs, &temps, &axis, 0..) |*l, *s0, *r, *tc, *a, k| {
        l.* = "r";
        s0.* = @intCast(k);
        r.* = r_ref;
        tc.* = null;
        a.* = @floatFromInt(10 * k);
    }
    starts[values.len] = values.len;
    var deck = bareDeck(&.{ vin, mid, low }, &.{ "v(in)", "v(mid)", "v(low)" });
    deck.variants = .{ .labels = &labels, .temp_c = &temps, .axis = &axis, .starts = &starts, .refs = &refs, .values = &values };
    const jobs = [_]requests.Query{
        .{ .mc = .{ .n_trials = 11, .variation = 0.2, .seed = 5 } },
        .{ .mc = .{ .variants = .{ .first = 0, .count = values.len }, .axis = "r", .dc_plot = true } },
        .{ .temp = .{ .t_start = -40, .t_stop = 160, .t_step = 20 } },
    };
    const Run = struct { lanes: bool, jobs: u16 };
    const runs = [_]Run{ .{ .lanes = false, .jobs = 1 }, .{ .lanes = true, .jobs = 1 }, .{ .lanes = true, .jobs = 3 } };
    var out: [runs.len][jobs.len][]f64 = undefined;
    var batched: usize = 0;
    for (runs, &out) |r, *o| {
        var config: @import("../executor.zig").Config = .{};
        config.knobs.lanes = r.lanes;
        var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
        defer s.deinit();
        var ids: [jobs.len]requests.QueryId = undefined;
        _ = try s.append(&jobs, &ids);
        // One shared OP, 33 lane rows, the three split queries.
        try t.expectEqual(@as(u32, 1 + 33 + 3), s.count());
        try s.runAll(.{ .max_parallel = r.jobs, .quantum = .completion });
        try t.expectEqual(null, s.failure());
        for (s.rows.items(.executor)) |e| batched += e.?.peers.len;
        for (ids, o) |id, *d| d.* = try t.allocator.dupe(f64, (try s.result(id)).data);
    }
    defer for (out) |o| for (o) |d| t.allocator.free(d);
    try t.expect(batched > 0);
    for (out[1..]) |o| for (out[0], o) |want, got| try t.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
    // Two variant lanes drop out; the trials and temperatures all converge.
    try t.expectEqual(@as(usize, 11 * 4), out[0][0].len);
    try t.expectEqual(@as(usize, 9 * 4), out[0][1].len);
    try t.expectEqual(@as(usize, 11 * 4), out[0][2].len);

    // The same lanes appended one query each, never split or batched.
    var config: @import("../executor.zig").Config = .{};
    config.knobs.lanes = false;
    var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
    defer s.deinit();
    var alone: [33]requests.Query = undefined;
    for (0..11) |k| {
        const l: u32 = @intCast(k);
        alone[k] = jobs[0];
        alone[k].mc.lane = l;
        alone[11 + k] = jobs[1];
        alone[11 + k].mc.lane = l;
        alone[22 + k] = jobs[2];
        alone[22 + k].temp.lane = l;
    }
    var ids: [alone.len]requests.QueryId = undefined;
    _ = try s.append(&alone, &ids);
    try t.expectEqual(@as(u32, 1 + 33), s.count());
    try s.runAll(.{ .quantum = .completion });
    for (out[0], 0..) |want, q| {
        var at: usize = 0;
        for (ids[11 * q ..][0..11]) |id| {
            const part = (try s.result(id)).data;
            // A plain `.mc` numbers its converged trials.
            if (q == 0 and part.len != 0) try t.expectEqual(@as(f64, @floatFromInt(at / 4)), want[at]);
            const skip: usize = if (q == 0) 1 else 0;
            try t.expectEqualSlices(u64, @ptrCast(part[skip..]), @ptrCast(want[at + skip ..][0 .. part.len - skip]));
            at += part.len;
        }
        try t.expectEqual(want.len, at);
    }
}
