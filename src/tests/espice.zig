//! Problem facade contract: ownership, transactional appends, stepped vs
//! batch execution, output ordering and failure isolation.
const std = @import("std");
const api = @import("espice");
const t = std.testing;
const deck = "query fixture\nV1 in 0 dc 1 ac 1\nR1 in out 1k\nC1 out 0 1n\n.ac dec 80 1 100k\n.tran 1n 10n uic\n.end\n";

fn create(source: []const u8) !*api.Problem {
    return createLimited(source, 2);
}

fn createLimited(source: []const u8, max_parallel: u16) !*api.Problem {
    return api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "memory.cir" } }, .max_parallel = max_parallel });
}

fn find(p: *api.Problem, kind: api.requests.Kind) !api.QueryId {
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if ((try p.query_info(id)).kind == kind) return id;
    }
    return error.MissingQuery;
}

fn construct(allocator: std.mem.Allocator) !void {
    const p = try api.Problem.init(allocator, t.io, .{
        .source = .{ .bytes = .{ .data = deck, .origin = "construction.cir" } },
        .output = .{ .path = "unused.raw" },
    });
    defer p.deinit();
}

test "Problem: construction releases partial ownership at every allocation failure" {
    try construct(t.allocator);
    try t.checkAllAllocationFailures(fixed_growth, construct, .{});
}

/// `t.allocator` that never grows or shrinks a block in place. Whether a
/// large block grows in place depends on the address space around it, so
/// through `t.allocator` an arena's chunk count, and with it the allocation
/// count `checkAllAllocationFailures` replays, can change between runs.
const fixed_growth: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = struct {
        fn alloc(_: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
            return t.allocator.rawAlloc(n, a, ra);
        }
    }.alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = struct {
        fn free(_: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
            t.allocator.rawFree(m, a, ra);
        }
    }.free,
} };

test "Problem: .hdl builds with the embedder's toolchain paths (#13)" {
    const source = "hdl toolchain\n.hdl \"m.va\"\nN1 1 0 m\nR1 1 0 1k\n.op\n.end\n";
    // The share path is used as given, never swapped for the build tree: one
    // without the evaluator sources fails before anything compiles.
    try t.expectError(error.HdlShareNotFound, api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = source, .origin = "toolchain.cir" } },
        .hdl_toolchain = .{ .zig = "/nonexistent/zig", .share = "/nonexistent-espice-test-dir/share/espice" },
    }));
}

/// Parse, subcircuit expansion, the builder's freeze and permutation, the
/// `.step` variant runs, `analyses.queries`, `Session.append` and a run of
/// every query: each allocation on that path fails once.
fn constructAndRun(allocator: std.mem.Allocator) !void {
    const p = try api.Problem.init(allocator, t.io, .{
        .source = .{ .bytes = .{ .data =
        \\construct and run under allocation failure
        \\.param rv=1k
        \\.subckt cell a b r=1k
        \\R1 a m {r}
        \\C1 m b 1n
        \\.ends
        \\V1 in 0 dc 1 ac 1
        \\X1 in out cell r={2*rv}
        \\D1 out 0 dn
        \\.model dn d is=1e-14
        \\B1 o2 0 v={v(out)*2}
        \\R2 o2 0 1k
        \\.op
        \\.ac dec 2 1 1k
        \\.tran 1u 4u
        \\.step param rv 1k 2k 1k
        \\.end
        , .origin = "run.cir" } },
        .max_parallel = 1,
    });
    defer p.deinit();
    try p.run_all();
}

test "Problem: construction and a full run release everything at every allocation failure" {
    try constructAndRun(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, constructAndRun, .{});
}

test "Problem: compiled device callbacks preserve allocation errors" {
    const p = try create(deck);
    defer p.deinit();
    for (p.prepared.circuit.batches) |batch| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        try t.expectError(error.OutOfMemory, batch.hooks.instantiate(batch.ctx, failing.allocator()).unwrap());
    }
}

test "Problem: pure preview, automatic prerequisite, independent frontier and retained copies" {
    const p = try create(deck);
    defer p.deinit();
    const ac = try find(p, .ac);
    const tran = try find(p, .tran);
    const op = (try p.query_info(ac)).dependency.?;
    try t.expectEqual(@as(u32, 3), p.query_count());
    var ready: [3]api.QueryId = undefined;
    try t.expectEqual(@as(usize, 2), try p.ready_queries(.all, &ready));
    var first = std.Io.Writer.Allocating.init(t.allocator);
    defer first.deinit();
    var second = std.Io.Writer.Allocating.init(t.allocator);
    defer second.deinit();
    const preview: api.PrintOptions = .{ .preview = .{ .advance = ac } };
    try p.print(&first.writer, preview);
    try p.print(&second.writer, preview);
    try t.expectEqualSlices(u8, first.written(), second.written());
    try t.expect(std.mem.indexOf(u8, first.written(), "NEXT") != null);
    try t.expectEqual(api.Status.pending, (try p.query_info(op)).status);
    try t.expectEqual(api.Status.pending, (try p.query_info(tran)).status);
    const event = try p.advance(ac);
    try t.expectEqual(op, event.advanced);
    try t.expectEqual(ac, event.requested);
    try t.expectEqual(api.Status.pending, event.target_status);
    try t.expectEqual(api.Status.pending, (try p.query_info(tran)).status);
    try p.run_all();
    const result = try p.result(ac);
    const copied = try t.allocator.alloc(f64, (try p.result(ac)).data.len);
    defer t.allocator.free(copied);
    _ = try p.copy_result(ac, copied);
    try t.expectEqualSlices(f64, result.data, copied);
    const complete = try p.advance(ac);
    try t.expectEqual(api.Status.complete, complete.status);
    try t.expectEqualSlices(f64, result.data, copied);
}

test "Problem: stepped and parallel execution match run_all for AC and transient" {
    const serial = try createLimited(deck, 1);
    defer serial.deinit();
    try serial.run_all();
    const stepped = try create(deck);
    defer stepped.deinit();
    var ids: [8]api.QueryId = undefined;
    var events: [8]api.Advance = undefined;
    var advances: usize = 0;
    while (!stepped.finished()) {
        const n = try stepped.ready_queries(.all, &ids);
        try t.expect(n != 0);
        _ = try stepped.advance_ready(ids[0..n], .{ .max_parallel = 2 }, &events);
        advances += 1;
        try t.expect(advances < 10000);
    }
    try stepped.run_all();
    try t.expect(advances > 3);
    inline for (.{ api.requests.Kind.ac, api.requests.Kind.tran }) |kind| {
        const a = try serial.result(try find(serial, kind));
        const b = try stepped.result(try find(stepped, kind));
        try t.expectEqualSlices(f64, a.data, b.data);
    }
}

test "Problem: append is transactional, retains IDs and owns request slices" {
    const p = try create("append\nV1 in 0 1\nR1 in out 1k\nR2 out 0 1k\n.op\n.end\n");
    defer p.deinit();
    try p.run_all();
    const op = try find(p, .op);
    const data = (try p.result(op)).data;
    const original = p.query_count();
    var duplicate: [1]api.QueryId = undefined;
    _ = try p.append_queries(&.{.{ .op = .{} }}, &duplicate);
    try t.expectEqual(op, duplicate[0]);
    try t.expectEqual(@as(usize, 1), p.session.outputs.items.len);
    try t.expectEqual(@as(u32, 1), p.delivery.published);
    var ids: [2]api.QueryId = undefined;
    try t.expectError(error.InvalidQueryOptions, p.append_queries(&.{
        .{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 10 } } },
        .{ .dc = .{ .start = 0, .stop = 1, .step = 0 } },
    }, &ids));
    try t.expectEqual(original, p.query_count());
    try t.expectEqual(data.ptr, (try p.result(op)).data.ptr);
    try t.expectEqual(@as(usize, 1), try p.append_directives(".ac dec 2 1 10", &.{}));
    try t.expectEqual(original, p.query_count());
    _ = try p.append_directives(".ac dec 2 1 10", &ids);
    try t.expectEqual(op, (try p.query_info(ids[0])).dependency.?);
    try p.run_all();
    try t.expectEqual(api.Status.complete, (try p.query_info(ids[0])).status);
    try t.expectError(error.UnsupportedDirectiveMutation, p.append_directives("R3 in 0 1k", &ids));
}

test "Problem: invalid frontier does not start work" {
    const p = try create(deck);
    defer p.deinit();
    var ids: [4]api.QueryId = undefined;
    const n = try p.ready_queries(.all, &ids);
    var events: [4]api.Advance = undefined;
    try t.expectError(error.DuplicateQuery, p.advance_ready(&.{ ids[0], ids[0] }, .{}, &events));
    try t.expectError(error.QueryNotReady, p.advance_ready(&.{try find(p, .ac)}, .{}, &events));
    try t.expectError(error.InvalidConcurrency, p.advance_ready(ids[0..n], .{ .max_parallel = 0 }, &events));
    try t.expectError(error.BufferTooSmall, p.advance_ready(ids[0..n], .{}, events[0 .. n - 1]));
    try t.expectError(error.InvalidQuery, p.advance_ready(&.{ ids[0], api.requests.invalid_query }, .{}, &events));
    for (0..p.query_count()) |i| try t.expectEqual(api.Status.pending, (try p.query_info(@fromBackingInt(@intCast(i)))).status);
}

test "Problem: short copy-out buffers and invalid scopes leave caller storage untouched" {
    const p = try create(deck);
    defer p.deinit();
    var ids = [_]api.QueryId{api.requests.invalid_query};
    try t.expectEqual(@as(usize, 2), try p.ready_count(.all));
    try t.expectError(error.BufferTooSmall, p.ready_queries(.all, &ids));
    try t.expectEqual(api.requests.invalid_query, ids[0]);
    try t.expectError(error.InvalidQuery, p.ready_queries(.{ .query = api.requests.invalid_query }, &ids));
    try t.expectError(error.InvalidComponent, p.ready_queries(.{ .component = p.query_count() }, &ids));
    const ac = try find(p, .ac);
    const dependency = (try p.query_info(ac)).dependency.?;
    try t.expectEqual(@as(usize, 1), try p.ready_queries(.{ .query = ac }, &ids));
    try t.expectEqual(dependency, ids[0]);
    var values = [_]f64{-123};
    try t.expectError(error.ResultUnavailable, p.copy_result(ac, &values));
    try t.expectEqual(@as(f64, -123), values[0]);
    try p.run_all();
    _ = try p.result(ac);
    try t.expectError(error.BufferTooSmall, p.copy_result(ac, &values));
    try t.expectEqual(@as(f64, -123), values[0]);
    try t.expectEqual(@as(usize, 0), try p.ready_queries(.all, &ids));
}

test "Problem: source and appended port slices are owned after the call returns" {
    var source = "owned input\nV1 in 0 dc 1 ac 1\nR1 in 0 50\n.end\n".*;
    var origin = "owned.cir".*;
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = &source, .origin = &origin } },
    });
    defer p.deinit();
    @memset(&source, 'x');
    @memset(&origin, 'x');
    try t.expectEqualStrings("owned input", p.title());
    try t.expectEqual(@as(u32, 1), p.query_count());
    const op = try find(p, .op); // A deck without directives gets one OP.
    var ports = [_]api.requests.Port{.{ .node = p.prepared.deck.source_node, .branch = p.prepared.deck.source_branch }};
    var ids: [1]api.QueryId = undefined;
    _ = try p.append_queries(&.{.{ .sp = .{ .sweep = .{ .f_start = 1, .f_stop = 10, .points = 2, .kind = .lin }, .ports = &ports } }}, &ids);
    ports[0].z0 = 150;
    try t.expectEqual(op, (try p.query_info(ids[0])).dependency.?);
    try p.run_all();
    const result = try p.result(ids[0]);
    try t.expectEqual(@as(usize, 2), result.npoints);
    // A 50-ohm load matches the original port. Borrowing the modified slice
    // would produce S11 = (50 - 150) / (50 + 150) = -0.5.
    for (0..result.npoints) |i| {
        try t.expectApproxEqAbs(@as(f64, 0), result.data[4 * i + 2], 1e-9);
        try t.expectApproxEqAbs(@as(f64, 0), result.data[4 * i + 3], 1e-9);
    }
}

test "Problem: allocation failures during append preserve results and permit retry" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const p = try api.Problem.init(failing.allocator(), t.io, .{
        .source = .{ .bytes = .{ .data = "allocation failure\nV1 in 0 1\nR1 in 0 50\n.op\n.end\n", .origin = "oom.cir" } },
    });
    defer p.deinit();
    try p.run_all();
    const op = try find(p, .op);
    const retained = try p.result(op);
    const count = p.query_count();
    const ports = [_]api.requests.Port{.{ .node = p.prepared.deck.source_node, .branch = p.prepared.deck.source_branch }};
    var failures: usize = 0;
    while (failures < 100) : (failures += 1) {
        var ids = [_]api.QueryId{api.requests.invalid_query};
        failing.fail_index = failing.alloc_index + failures;
        failing.resize_fail_index = failing.resize_index;
        const appended = p.append_queries(&.{.{ .sp = .{ .sweep = .{ .f_start = 1, .f_stop = 10, .points = 2, .kind = .lin }, .ports = &ports } }}, &ids);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (appended) |n| {
            try t.expectEqual(@as(usize, 1), n);
            try t.expect(failures > 0);
            try p.run_all();
            try t.expectEqual(api.Status.complete, (try p.query_info(ids[0])).status);
            break;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqual(api.requests.invalid_query, ids[0]);
            try t.expectEqual(count, p.query_count());
            try t.expectEqual(retained.data.ptr, (try p.result(op)).data.ptr);
            try t.expectEqual(api.Status.complete, (try p.query_info(op)).status);
        }
    }
    try t.expect(failures < 100);
}

test "Problem: publication follows request order and repeated run_all does not duplicate plots" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/ordered.raw", .{tmp.sub_path});
    defer t.allocator.free(path);
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = deck, .origin = "order.cir" } },
        .output = .{ .path = path },
    });
    defer p.deinit();
    const tran = try find(p, .tran);
    var calls: usize = 0;
    while (!(try p.query_info(tran)).status.terminal() and calls < 1000) : (calls += 1)
        _ = try p.advance(tran);
    try t.expectEqual(api.Status.complete, (try p.query_info(tran)).status);
    try t.expectError(error.FileNotFound, tmp.dir.openFile(t.io, "ordered.raw", .{}));
    try p.run_all();
    const before = try tmp.dir.readFileAlloc(t.io, "ordered.raw", t.allocator, .unlimited);
    defer t.allocator.free(before);
    const ac_name = try std.fmt.allocPrint(t.allocator, "Plotname: {s}\n", .{(try p.result(try find(p, .ac))).plotname});
    defer t.allocator.free(ac_name);
    const tran_name = try std.fmt.allocPrint(t.allocator, "Plotname: {s}\n", .{(try p.result(tran)).plotname});
    defer t.allocator.free(tran_name);
    const ac_pos = std.mem.indexOf(u8, before, ac_name) orelse return error.MissingAcPlot;
    const tran_pos = std.mem.indexOf(u8, before, tran_name) orelse return error.MissingTranPlot;
    try t.expect(ac_pos < tran_pos);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, before, "Title: query fixture\n"));
    try p.run_all();
    const after = try tmp.dir.readFileAlloc(t.io, "ordered.raw", t.allocator, .unlimited);
    defer t.allocator.free(after);
    try t.expectEqualSlices(u8, before, after);
}

test "Problem: writer failure retains completed results and is reported separately" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/missing/out.raw", .{tmp.sub_path});
    defer t.allocator.free(path);
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = "output\nV1 x 0 1\nR1 x 0 1k\n.op\n.end\n", .origin = "output.cir" } },
        .output = .{ .path = path },
    });
    defer p.deinit();
    try t.expectError(error.DeliveryFailed, p.run_all());
    const op = try find(p, .op);
    try t.expectEqual(api.Status.complete, (try p.query_info(op)).status);
    try t.expect(p.delivery_error != null);
    try t.expect((try p.result(op)).data.len != 0);
    try t.expect((try p.advance(op)).delivery_error != null);
}

test "Problem: destroy safely cancels parked transient and construction validates output" {
    const p = try create(deck);
    const tran = try find(p, .tran);
    _ = try p.advance(tran);
    p.deinit();
    try t.expectError(error.NotSParameterData, api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = deck, .origin = "output.cir" } },
        .output = .{ .format = .touchstone },
    }));
}

test "Problem: output validation rejects an entire append before publishing IDs" {
    for ([_]api.Format{ .touchstone, .citi }) |format| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/ports", .{tmp.sub_path});
        defer t.allocator.free(path);
        const p = try api.Problem.init(t.allocator, t.io, .{
            .source = .{ .bytes = .{
                .data = "S parameters\nV1 in 0 dc 1 ac 1\nR1 in 0 50\n.sp dec 2 1 10\n.end\n",
                .origin = "ports.cir",
            } },
            .output = .{ .format = format, .path = path },
        });
        defer p.deinit();
        try p.run_all();
        const sp = try find(p, .sp);
        const retained = try p.result(sp);
        const count = p.query_count();
        const jobs = [_]api.Query{
            .{ .sp = .{ .sweep = .{ .f_start = 10, .f_stop = 100 } } },
            .{ .ac = .{ .sweep = .{ .f_start = 10, .f_stop = 100 } } },
        };
        // Sizing does not validate or commit; rejection leaves both IDs untouched.
        try t.expectEqual(jobs.len, try p.append_queries(&jobs, &.{}));
        var ids = @as([jobs.len]api.QueryId, @splat(sp));
        try t.expectError(error.NotSParameterData, p.append_queries(&jobs, &ids));
        try t.expectEqualSlices(api.QueryId, &.{ sp, sp }, &ids);
        try t.expectEqual(count, p.query_count());
        try t.expectEqual(retained.data.ptr, (try p.result(sp)).data.ptr);
        _ = try p.append_queries(jobs[0..1], ids[0..1]);
        try p.run_all();
        try t.expectEqual(api.Status.complete, (try p.query_info(ids[0])).status);
        const written = try tmp.dir.readFileAlloc(t.io, "ports.2", t.allocator, .unlimited);
        defer t.allocator.free(written);
        try t.expect(std.mem.indexOf(u8, written, if (format == .citi) "DATA S[1,1] RI" else "# Hz S RI R 50") != null);
    }
}

test "Problem: an .sp written as Touchstone records each port's reference impedance" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/ts.s2p", .{tmp.sub_path});
    defer t.allocator.free(path);
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{
            .data = "ports\nV1 p1 0 dc 0 ac 1 portnum 1 z0 50\nV2 p2 0 dc 0 ac 0 portnum 2 z0 75\nR1 p1 p2 60\n.sp lin 2 1meg 2meg\n.end\n",
            .origin = "ts.sp",
        } },
        .output = .{ .format = .touchstone, .path = path },
    });
    defer p.deinit();
    try p.run_all();
    const written = try tmp.dir.readFileAlloc(t.io, "ts.s2p", t.allocator, .unlimited);
    defer t.allocator.free(written);
    try t.expect(std.mem.indexOf(u8, written, "[Reference] 50 75\n") != null);
}

test {
    _ = @import("analyses.zig");
}

test "Problem: .lin format=touchstone writes <deck>.s2p beside the deck with the noise block" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const origin = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/amp.sp", .{tmp.sub_path});
    defer t.allocator.free(origin);
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{
            .data = "pad\nP1 a 0 port=1 z0=50\nR1 a b 50\nR2 b 0 50\nP2 b 0 port=2 z0=50\n.ac dec 1 1k 10k\n.lin noisecalc=1 format=touchstone\n.end\n",
            .origin = origin,
        } },
        .dialect = .hspice,
    });
    defer p.deinit();
    try p.run_all();
    const written = try tmp.dir.readFileAlloc(t.io, "amp.s2p", t.allocator, .unlimited);
    defer t.allocator.free(written);
    try t.expect(std.mem.indexOf(u8, written, "# Hz S RI R 50\n1e3 ") != null);
    try t.expect(std.mem.indexOf(u8, written, "! noise parameters\n1e3 ") != null);
}

test "Problem: parameter sweeps cannot mutate concurrently running transient state" {
    const input = "independent state\nV1 in 0 dc 1\nR1 in out 1k\nC1 out 0 1n\n.tran 1n 8n\n.end\n";
    const serial = try createLimited(input, 1);
    defer serial.deinit();
    const parallel = try create(input);
    defer parallel.deinit();
    const jobs = [_]api.Query{
        .{ .mc = .{ .n_trials = 4, .seed = 123 } },
        .{ .temp = .{ .t_start = 20, .t_stop = 30, .t_step = 5 } },
    };
    var serial_ids: [2]api.QueryId = undefined;
    var parallel_ids: [2]api.QueryId = undefined;
    _ = try serial.append_queries(&jobs, &serial_ids);
    _ = try parallel.append_queries(&jobs, &parallel_ids);
    try serial.run_all();
    try parallel.run_all();
    try t.expectEqualSlices(f64, (try serial.result(try find(serial, .tran))).data, (try parallel.result(try find(parallel, .tran))).data);
    for (serial_ids, parallel_ids) |a, b| try t.expectEqualSlices(f64, (try serial.result(a)).data, (try parallel.result(b)).data);
}

test "device noise needs no input source and retains its thermal PSD" {
    const p = try create(
        "device noise\nR1 out 0 1k\n.temp 27\n.noise v(out) dec 3 1k 10k\n.pnoise v(out) unused dec 3 1k 10k 1k 0\n.end\n",
    );
    defer p.deinit();
    try p.run_all();
    // 4kTR, the PSD in V^2/Hz. ngspice's curves are AMPLITUDE spectra, so the
    // column carries its square root; the totals stay V rms.
    const expected = 4 * 1.380649e-23 * 300.15 * 1000;
    var spectra: u8 = 0;
    var totals: u8 = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const kind = (try p.query_info(id)).kind;
        if (kind != .noise and kind != .pnoise) continue;
        const result = try p.result(id);
        if (kind == .noise and result.npoints == 1) {
            try t.expectEqual(@as(usize, 2), result.varnames.len);
            try t.expectEqualStrings("v(onoise_total)", result.varnames[0]);
            try t.expectEqualStrings("v(inoise_total)", result.varnames[1]);
            try t.expectApproxEqRel(@sqrt(expected * 9000), result.data[0], 1e-6);
            // No `.noise` input source was named, so nothing to refer back to.
            try t.expectEqual(@as(f64, 0), result.data[1]);
            totals += 1;
        } else if (kind == .noise) {
            try t.expectEqual(@as(usize, 3), result.varnames.len);
            try t.expectEqualStrings("onoise_spectrum", result.varnames[1]);
            try t.expectEqualStrings("inoise_spectrum", result.varnames[2]);
            for (0..result.npoints) |point|
                try t.expectApproxEqRel(@sqrt(expected), result.data[3 * point + 1], 1e-6);
            spectra += 1;
        } else {
            try t.expectEqual(@as(usize, 2), result.varnames.len);
            try t.expectEqualStrings("pnoise_density", result.varnames[1]);
            for (0..result.npoints) |point|
                try t.expectApproxEqRel(expected, result.data[2 * point + 1], 1e-6);
            spectra += 1;
        }
    }
    try t.expectEqual(@as(u8, 2), spectra);
    try t.expectEqual(@as(u8, 1), totals);
}

test "HSPICE .save writes the operating point beside the output and .load reads it back" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(dir);
    const out = try std.fmt.allocPrint(t.allocator, "{s}/a.raw", .{dir});
    defer t.allocator.free(out);
    const saver = try api.Problem.init(t.allocator, io, .{
        .source = .{ .bytes = .{ .data = "save\nv1 a 0 2\nr1 a b 1k\nr2 b 0 1k\nx1 b sub\n.subckt sub p\nr1 p m 1k\nr2 m 0 1k\n.ends\n.op\n.save type=ic level=top\n.end\n", .origin = "divider.sp" } },
        .dialect = .hspice,
        .output = .{ .path = out },
    });
    defer saver.deinit();
    try saver.run_all();
    const text = try tmp.dir.readFileAlloc(io, "divider.ic0", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".ic v(a)=2e0\n") != null);
    try t.expect(std.mem.indexOf(u8, text, ".ic v(b)=") != null);
    try t.expect(std.mem.indexOf(u8, text, "x1.") == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "load.sp", .data = "load\nv1 a 0 1\nr1 a b 1k\nc1 b 0 1n\n.load file=divider.ic0\n.tran 1n 10n\n.end\n" });
    const deck_path = try std.fmt.allocPrint(t.allocator, "{s}/load.sp", .{dir});
    defer t.allocator.free(deck_path);
    const loader = try api.Problem.init(t.allocator, io, .{ .source = .{ .file = deck_path }, .dialect = .hspice });
    defer loader.deinit();
    try t.expectEqual(@as(usize, 2), loader.prepared.deck.ic.len);
}

test "HSPICE .stim writes PWL sources and a .data table a later run reads" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(dir);
    const out = try std.fmt.allocPrint(t.allocator, "{s}/a.raw", .{dir});
    defer t.allocator.free(out);
    // v(a) ramps 0 to 1 V over 1 ns, then holds.
    const writer = try api.Problem.init(t.allocator, io, .{
        .source = .{ .bytes = .{ .data = "stim\nv1 a 0 pwl(0 0 1n 1)\nr1 a 0 1k\n.tran 0.1n 2n\n" ++
            ".stim tran pwl filename=rc v0=v(a) node1=b node2=0 npoints=5\n" ++
            ".stim tran data filename=rc tab vv=v(a) w=par('2*v(a)') indepvar=(0.5n 1.5n) indepout\n.end\n", .origin = "stim.sp" } },
        .dialect = .hspice,
        .output = .{ .path = out },
    });
    defer writer.deinit();
    try writer.run_all();
    const pwl = try tmp.dir.readFileAlloc(io, "rc.pwl0_tr0", t.allocator, .unlimited);
    defer t.allocator.free(pwl);
    try t.expectEqualStrings("* stim\n* written by .stim\nv0 b 0 pwl(\n+ 0e0 0e0\n+ 5e-10 5e-1\n+ 1e-9 1e0\n+ 1.5000000000000002e-9 1e0\n+ 2e-9 1e0)\n", pwl);
    const data = try tmp.dir.readFileAlloc(io, "rc.dat0_tr0", t.allocator, .unlimited);
    defer t.allocator.free(data);
    try t.expect(std.mem.startsWith(u8, data, "* stim\n* written by .stim\n.data tab time vv w\n+ ") and std.mem.endsWith(u8, data, "\n.enddata\n"));
    // Rows: time, v(a), 2 v(a) at 0.5 ns and 1.5 ns.
    const want = [_]f64{ 0.5e-9, 0.5, 1, 1.5e-9, 1, 2 };
    var got: std.ArrayList(f64) = .empty;
    defer got.deinit(t.allocator);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "+")) {
        var cells = std.mem.tokenizeScalar(u8, line[1..], ' ');
        while (cells.next()) |c| try got.append(t.allocator, try std.fmt.parseFloat(f64, c));
    };
    try t.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try t.expectApproxEqRel(w, g, 1e-9);

    try tmp.dir.writeFile(io, .{ .sub_path = "load.sp", .data = "load\n.include rc.pwl0_tr0\nr2 b 0 1k\n.tran 0.1n 2n\n.end\n" });
    const deck_path = try std.fmt.allocPrint(t.allocator, "{s}/load.sp", .{dir});
    defer t.allocator.free(deck_path);
    const reader = try api.Problem.init(t.allocator, io, .{ .source = .{ .file = deck_path }, .dialect = .hspice });
    defer reader.deinit();
    try reader.run_all();
}

test "HSPICE .op <time> counts its columns as .op does" {
    // 63 nets and one source current: 64 columns, SST2's limit. A time
    // column that the snapshot never publishes would make it 65.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(t.allocator);
    try text.appendSlice(t.allocator, "snapshot\nv1 n1 0 1\n");
    for (1..63) |i| try text.print(t.allocator, "r{d} n{d} n{d} 1k\n", .{ i, i, i + 1 });
    try text.appendSlice(t.allocator, "r63 n63 0 1k\n.op 1n\n.end\n");
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = text.items, .origin = "snapshot.sp" } },
        .dialect = .hspice,
        .output = .{ .format = .sst2 },
    });
    defer p.deinit();
    try p.run_all();
    try t.expectEqual(@as(usize, 64), (try p.result(@fromBackingInt(@intCast(0)))).varnames.len);
}

test "Problem: zero max_parallel fails before anything is parsed" {
    try t.expectError(error.InvalidConcurrency, createLimited(deck, 0));
    try t.expectError(error.InvalidConcurrency, createLimited("not a deck", 0));
}

test "Problem: invalid IDs, empty directives, inherited print limits and no variant runs" {
    const p = try create(deck);
    defer p.deinit();
    const bad = api.requests.invalid_query;
    try t.expectError(error.InvalidQuery, p.query_info(bad));
    try t.expectError(error.InvalidQuery, p.result(bad));
    try t.expectError(error.InvalidQuery, p.advance(bad));
    try t.expectError(error.InvalidQuery, p.copy_result(bad, &.{}));
    const count = p.query_count();
    try t.expectError(error.InvalidAnalysisArguments, p.append_directives("", &.{}));
    try t.expectEqual(count, p.query_count());
    try t.expectEqualStrings("query fixture", p.title());
    try t.expectEqual(@as(u32, 3), p.device_count());
    // A null `limits` previews with the Problem's max_parallel (2 here), not
    // the session default.
    var inherited = std.Io.Writer.Allocating.init(t.allocator);
    defer inherited.deinit();
    var explicit = std.Io.Writer.Allocating.init(t.allocator);
    defer explicit.deinit();
    try p.print(&inherited.writer, .{});
    try p.print(&explicit.writer, .{ .limits = .{ .max_parallel = 2 } });
    try t.expectEqualSlices(u8, explicit.written(), inherited.written());
    try p.run_all();
    try t.expect(p.output_error() == null);
    const runs = try p.run_results(t.allocator);
    defer t.allocator.free(runs);
    try t.expectEqual(@as(usize, 0), runs.len);
}

test "Problem: copy_result fills an exact or longer buffer and keeps its tail" {
    const p = try create("copy\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n");
    defer p.deinit();
    try p.run_all();
    const op = try find(p, .op);
    const data = (try p.result(op)).data;
    const buffer = try t.allocator.alloc(f64, data.len + 1);
    defer t.allocator.free(buffer);
    buffer[data.len] = -7;
    try t.expectEqual(data.len, try p.copy_result(op, buffer));
    try t.expectEqualSlices(f64, data, buffer[0..data.len]);
    try t.expectEqual(@as(f64, -7), buffer[data.len]);
    try t.expectEqual(data.len, try p.copy_result(op, buffer[0..data.len]));
    try t.expectEqualSlices(f64, data, buffer[0..data.len]);
}

test "Problem: a final plan streams a lone transient but keeps one that .stim reads" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/a.raw", .{tmp.sub_path});
    defer t.allocator.free(out);
    {
        const p = try api.Problem.init(t.allocator, io, .{
            .source = .{ .bytes = .{ .data = "stream\nv1 a 0 pwl(0 0 1n 1)\nr1 a 0 1k\n.tran 0.1n 2n\n.end\n", .origin = "stream.cir" } },
            .output = .{ .path = out },
            .backend = .{ .final_plan = true },
        });
        defer p.deinit();
        try p.run_all();
        // The rows went to the raw file; the Result keeps only their count.
        const r = try p.result(try find(p, .tran));
        try t.expect(r.npoints > 1);
        try t.expectEqual(@as(usize, 0), r.data.len);
        const raw = try tmp.dir.readFileAlloc(io, "a.raw", t.allocator, .unlimited);
        defer t.allocator.free(raw);
        try t.expect(std.mem.indexOf(u8, raw, "Plotname: Transient Analysis\n") != null);
    }
    // `.stim` samples the transient after run_all, so streaming would leave
    // it no rows to read.
    const p = try api.Problem.init(t.allocator, io, .{
        .source = .{ .bytes = .{ .data = "stim\nv1 a 0 pwl(0 0 1n 1)\nr1 a 0 1k\n.tran 0.1n 2n\n" ++
            ".stim tran pwl filename=rc v0=v(a) node1=b node2=0 npoints=5\n.end\n", .origin = "stim.sp" } },
        .dialect = .hspice,
        .output = .{ .path = out },
        .backend = .{ .final_plan = true },
    });
    defer p.deinit();
    try p.run_all();
    try t.expect((try p.result(try find(p, .tran))).data.len != 0);
    const pwl = try tmp.dir.readFileAlloc(io, "rc.pwl0_tr0", t.allocator, .unlimited);
    defer t.allocator.free(pwl);
    try t.expectEqualStrings("* stim\n* written by .stim\nv0 b 0 pwl(\n+ 0e0 0e0\n+ 5e-10 5e-1\n+ 1e-9 1e0\n+ 1.5000000000000002e-9 1e0\n+ 2e-9 1e0)\n", pwl);
}

/// The operating-point value of column `name` in `source`'s only query.
fn opValue(source: []const u8, name: []const u8) !f64 {
    const p = try create(source);
    defer p.deinit();
    try p.run_all();
    const r = try p.result(@fromBackingInt(@intCast(0)));
    for (r.varnames, 0..) |v, i| if (std.mem.eql(u8, v, name)) return r.data[i];
    return error.MissingColumn;
}

test "ngspice .option seed draws the distributions once, reproducibly per seed" {
    const body = "seed\ni1 0 a 1m\nr1 a 0 {{agauss(1k,100,1)}}\n{s}.op\n.end\n";
    var buf: [128]u8 = undefined;
    const nominal = try opValue(try std.fmt.bufPrint(&buf, body, .{""}), "v(a)");
    try t.expectEqual(@as(f64, 1), nominal);
    var drawn: [3]f64 = undefined;
    for (&drawn, [_][]const u8{ ".options seed=1\n", ".options seed=2\n", ".options seed=1\n" }) |*v, s|
        v.* = try opValue(try std.fmt.bufPrint(&buf, body, .{s}), "v(a)");
    try t.expect(drawn[0] != nominal and drawn[1] != drawn[0]);
    try t.expectEqual(drawn[0], drawn[2]);
    // A 1-sigma draw of 100 ohm: within 6 sigma of 1 V.
    try t.expect(@abs(drawn[0] - 1) < 0.6 and @abs(drawn[1] - 1) < 0.6);
}

test "an R reading v() is ngspice's B source: pow() takes |x|, tc divides, m multiplies" {
    // v(a,b) = 0.5: pow(0.5-1.7, 3) is |-1.2|^3 = 1.728 in ngspice's B
    // parser, so R = 1k*(1+0.01*1.728) = 1017.28; tc at 60 C: 1+33e-3+33^2*2e-6
    // = 1.035178; m=2 halves it.
    const deck_text = "rv\nv1 a 0 0.5\nr1 a 0 r={1k*(1+0.01*pow(abs(v(a,0))-1.7,3))} tc1=1e-3 tc2=2e-6 m=2\n.temp 60\n.op\n.end\n";
    const i = try opValue(deck_text, "i(v1)");
    try t.expectApproxEqRel(@as(f64, -0.5 * 2 / (1017.28 * 1.035178)), i, 1e-12);
}

test "Monte Carlo: a B source reads the trial's draw of a sampled .param, as a resistor does (#133)" {
    // Analytic oracle from the deck itself: within a trial v(out) = g and
    // v(c) = 1/(1+g), so v(out) = 1/v(c) - 1.
    const body = "monte B\n.param g=agauss(1, 0.1, 1)\nv1 a 0 1\nbout out 0 v=g*v(a)\nrload out 0 1k\nr1 a c '1k*g'\nr2 c 0 1k\n{s}.end\n";
    var buf: [256]u8 = undefined;
    const p = try create(try std.fmt.bufPrint(&buf, body, .{".op sweep monte=3\n"}));
    defer p.deinit();
    try p.run_all();
    var all: std.ArrayList(api.Result) = .empty;
    defer all.deinit(t.allocator);
    for (0..p.query_count()) |i| try all.append(t.allocator, try p.result(@fromBackingInt(@intCast(i))));
    const runs = try p.run_results(t.allocator);
    defer t.allocator.free(runs);
    try all.appendSlice(t.allocator, runs);
    var drawn: usize = 0;
    for (all.items) |r| {
        const g = try column(r, "v(out)");
        try t.expectApproxEqRel(1 / try column(r, "v(c)") - 1, g, 1e-9);
        if (@abs(g - 1) > 1e-6) drawn += 1;
    }
    try t.expectEqual(@as(usize, 4), all.items.len);
    try t.expectEqual(@as(usize, 3), drawn);
    // `.option seed` draws once, the same way.
    const seeded = try create(try std.fmt.bufPrint(&buf, body, .{".options seed=3\n.op\n"}));
    defer seeded.deinit();
    try seeded.run_all();
    const r = try seeded.result(@fromBackingInt(0));
    try t.expect(@abs(try column(r, "v(out)") - 1) > 1e-6);
    try t.expectApproxEqRel(1 / try column(r, "v(c)") - 1, try column(r, "v(out)"), 1e-9);
}

/// Column `name` of `r`'s first point.
fn column(r: api.Result, name: []const u8) !f64 {
    for (r.varnames, 0..) |v, i| if (std.mem.eql(u8, v, name)) return r.data[i];
    return error.MissingColumn;
}

/// Creates `body` at `values[0]` with `name` live, then for each later
/// value sets it and runs one more `.op`, checking it against a fresh
/// Problem parsed at that value (the re-parse oracle). Returns how many
/// templates the calls built.
fn expectTunedAsParsed(comptime body: []const u8, name: []const u8, values: []const f64) !usize {
    const first = try std.fmt.allocPrint(t.allocator, body, .{values[0]});
    defer t.allocator.free(first);
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = first, .origin = "tuned.cir" } }, .live_params = &.{name} });
    defer p.deinit();
    try p.run_all();
    for (values[1..]) |v| {
        try p.set_params(&.{name}, &.{v});
        var id: [1]api.QueryId = undefined;
        _ = try p.append_directives(".op", &id);
        try p.run_all();
        const text = try std.fmt.allocPrint(t.allocator, body, .{v});
        defer t.allocator.free(text);
        const q = try create(text);
        defer q.deinit();
        try q.run_all();
        const want = (try q.result(@fromBackingInt(0))).data;
        const got = (try p.result(id[0])).data;
        try t.expectEqual(want.len, got.len);
        for (want, got) |a, b| try t.expectApproxEqRel(a, b, 1e-12);
    }
    return p.session.templates.items.len;
}

test "Problem.set_params: later queries run at the new values, earlier ones keep theirs (#101)" {
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = "tuned\n.param rv=1k\nV1 in 0 1\nR1 in out {rv}\nR2 out 0 1k\n.op\n.end\n", .origin = "tuned.cir" } },
        .live_params = &.{"RV"},
    });
    defer p.deinit();
    try p.run_all();
    const nominal: api.QueryId = @fromBackingInt(0);
    for ([_]f64{ 3e3, 1e3, 9e3 }) |rv| {
        try p.set_params(&.{"rv"}, &.{rv});
        var id: [1]api.QueryId = undefined;
        _ = try p.append_directives(".op", &id);
        try p.run_all();
        try t.expectApproxEqRel(1e3 / (1e3 + rv), try column(try p.result(id[0]), "v(out)"), 1e-12);
        try t.expect(std.mem.indexOf(u8, (try p.result(id[0])).plotname, "(rv=") != null);
    }
    try t.expectApproxEqRel(0.5, try column(try p.result(nominal), "v(out)"), 1e-12);
    // A failed call changes nothing: the next query still runs at 9k.
    try t.expectError(error.UnknownParameter, p.set_params(&.{"nope"}, &.{1}));
    try t.expectError(error.InvalidArgument, p.set_params(&.{"rv"}, &.{std.math.inf(f64)}));
    try t.expectError(error.InvalidArgument, p.set_params(&.{"rv"}, &.{}));
    var id: [1]api.QueryId = undefined;
    _ = try p.append_directives(".op", &id);
    try p.run_all();
    try t.expectApproxEqRel(0.1, try column(try p.result(id[0]), "v(out)"), 1e-12);
    // The fast path writes the resistor; no circuit was rebuilt.
    try t.expectEqual(@as(usize, 0), p.session.templates.items.len);
}

test "Problem.set_params: no live names, an unknown one, or one an analysis card reads" {
    const p = try create("plain\n.param rv=1k\nV1 in 0 1\nR1 in 0 {rv}\n.op\n.end\n");
    defer p.deinit();
    try t.expectError(error.UnknownParameter, p.set_params(&.{"rv"}, &.{2e3}));
    const source: api.Source = .{ .bytes = .{ .data = "plain\n.param rv=1k\nV1 in 0 1\nR1 in 0 {rv}\n.tran 1n {rv*1n}\n.end\n", .origin = "plain.cir" } };
    try t.expectError(error.UnknownParameter, api.Problem.init(t.allocator, t.io, .{ .source = source, .live_params = &.{"nope"} }));
    try t.expectError(error.UnsupportedCard, api.Problem.init(t.allocator, t.io, .{ .source = source, .live_params = &.{"rv"} }));
}

test "Problem.set_params: a binned MOSFET takes the bin its new W selects (#101, #63)" {
    // nm.1 and nm.2 differ in VTO; W=2u moves M1 to nm.2 and back.
    const global =
        \\bins
        \\.param wn={d}
        \\V1 d 0 1
        \\V2 g 0 2
        \\M1 d g 0 0 nm l=1u w={{wn}}
        \\.model nm.1 nmos level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u vto=0.5
        \\.model nm.2 nmos level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u vto=1.7
        \\.op
        \\.end
        \\
    ;
    // A loop that keeps crossing the bin edge reuses the template of each
    // side: one circuit beside the nominal one, however many crossings (#129).
    try t.expectEqual(@as(usize, 1), try expectTunedAsParsed(global, "wn", &.{ 1e-6, 2e-6, 1.05e-6, 2.05e-6, 1e-6, 2e-6, 1.05e-6 }));
    // The same with sky130's layout: bins inside the subcircuit, a model
    // value read under each instance's parameters, and `.option scale`.
    const local =
        \\local bins
        \\.option scale=1u
        \\.param wn={d}
        \\.subckt nfet d g s b l=1 w=1
        \\.model nmod.1 nmos level=1 lmin=0.9e-6 lmax=1.1e-6 wmin=0.9e-6 wmax=1.1e-6 vto={{0.5+0*w}}
        \\.model nmod.2 nmos level=1 lmin=0.9e-6 lmax=1.1e-6 wmin=1.9e-6 wmax=2.1e-6 vto={{1.7+0*w}}
        \\m1 d g s b nmod l={{l}} w={{w}}
        \\.ends
        \\X1 d g 0 0 nfet w={{wn}} l=1
        \\V1 d 0 1
        \\V2 g 0 2
        \\.op
        \\.end
        \\
    ;
    try t.expectEqual(@as(usize, 1), try expectTunedAsParsed(local, "wn", &.{ 1, 2, 1.05, 2.05, 1 }));
    // The bins really differ: the drain current moves with them.
    var buf: [512]u8 = undefined;
    const narrow = try opValue(try std.fmt.bufPrint(&buf, global, .{1e-6}), "i(v1)");
    const wide = try opValue(try std.fmt.bufPrint(&buf, global, .{2e-6}), "i(v1)");
    try t.expect(@abs(wide) < @abs(narrow));
}

test ".step over W on a binned model runs a point whose bin moves on its own circuit (#63)" {
    const stepped =
        \\stepped bins
        \\.param wn=1u
        \\V1 d 0 1
        \\V2 g 0 2
        \\M1 d g 0 0 nm l=1u w={wn}
        \\.model nm.1 nmos level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u vto=0.5
        \\.model nm.2 nmos level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u vto=1.7
        \\.step param wn list 1.05u 2u
        \\.op
        \\.end
        \\
    ;
    const p = try create(stepped);
    defer p.deinit();
    try p.run_all();
    const runs = try p.run_results(t.allocator);
    defer t.allocator.free(runs);
    try t.expectEqual(@as(usize, 1), runs.len);
    var buf: [512]u8 = undefined;
    const body = "fresh\nV1 d 0 1\nV2 g 0 2\nM1 d g 0 0 nm l=1u w={s}\n.model nm.1 nmos level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u vto=0.5\n" ++
        ".model nm.2 nmos level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u vto=1.7\n.op\n.end\n";
    try t.expectApproxEqRel(try opValue(try std.fmt.bufPrint(&buf, body, .{"1.05u"}), "i(v1)"), try column(try p.result(try find(p, .op)), "i(v1)"), 1e-12);
    try t.expectApproxEqRel(try opValue(try std.fmt.bufPrint(&buf, body, .{"2u"}), "i(v1)"), try column(runs[0], "i(v1)"), 1e-12);
}

/// Every completed result of `path` at the given thread counts, its data
/// concatenated as bits. Caller frees it.
fn runThreaded(path: []const u8, device_threads: u32, solver_threads: u8) ![]const u64 {
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .file = path },
        .backend = .{ .device_threads = device_threads, .solver_threads = solver_threads },
    });
    defer p.deinit();
    // device_threads > 1 always builds a ParEval; with an instance per
    // lane at least, every lane can claim a chunk.
    try t.expect(p.device_count() >= device_threads);
    try p.run_all();
    var bits: std.ArrayList(u64) = .empty;
    errdefer bits.deinit(t.allocator);
    for (0..p.query_count()) |i| {
        const r = try p.result(@fromBackingInt(@intCast(i)));
        try t.expect(r.npoints > 0);
        try bits.appendSlice(t.allocator, @ptrCast(r.data));
    }
    try t.expect(bits.items.len > 0);
    return bits.toOwnedSlice(t.allocator);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "same deck, same bytes: run twice, any solver_threads, any device_threads" {
    // MOS transients and an AC sweep, 18 to 512 devices. ESPICE_LU_PAR=1
    // forces the multicore refactor past its cost model; ESPICE_LU_PAR_STATS
    // shows it admitted on the three stress decks. ParEval sums every stamp
    // in the serial order, so device_threads N is the serial run byte for
    // byte; before #137 it regrouped the sums (up to 24554 ulp on
    // parallel_inverters_100) and vacask_ring's transient took 20717 /
    // 20585 / 20318 points at 1 / 2 / 4 threads.
    const decks = [_][]const u8{
        "tests/fixtures/stress/scaling_parallel_inverters_100.sp",
        "tests/fixtures/stress/scaling_inverter_chain_256.sp",
        "tests/fixtures/stress/sweep_opamp_wl_200.sp",
        "tests/fixtures/stress/vacask_ring.sp",
    };
    try t.expectEqual(@as(c_int, 0), setenv("ESPICE_LU_PAR", "1", 1));
    defer _ = unsetenv("ESPICE_LU_PAR");
    for (decks) |deck_path| {
        const serial = try runThreaded(deck_path, 1, 1);
        defer t.allocator.free(serial);
        for ([_]u8{ 1, 2, 4 }) |solver_threads| {
            const again = try runThreaded(deck_path, 1, solver_threads);
            defer t.allocator.free(again);
            try t.expectEqualSlices(u64, serial, again);
        }
        for ([_]u32{ 2, 3, 4, 4 }) |device_threads| {
            const lanes = try runThreaded(deck_path, device_threads, 1);
            defer t.allocator.free(lanes);
            try t.expectEqualSlices(u64, serial, lanes);
        }
    }
}
