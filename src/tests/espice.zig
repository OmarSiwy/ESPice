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
    try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, construct, .{});
}

test "Problem: .hdl display-task lines go to Options.display (#127)" {
    var sink: std.Io.Writer.Allocating = .init(t.allocator);
    defer sink.deinit();
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .file = "tests/fixtures/hdl/veriloga_strobe.sp" },
        .display = &sink.writer,
    });
    defer p.deinit();
    try p.run_all();
    try t.expectEqualStrings("n1 vdrop = 0.35\n", sink.written());
}

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
    try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, constructAndRun, .{});
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
    // Single-threaded, a worker runs its query to completion per advance.
    try t.expect(advances > 3 or @import("builtin").single_threaded);
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

test "Problem: stepping every query to the end publishes the file run_all writes (#179)" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const stepped_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/stepped.raw", .{tmp.sub_path});
    defer t.allocator.free(stepped_path);
    const batch_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/batch.raw", .{tmp.sub_path});
    defer t.allocator.free(batch_path);
    // The oracle: the same deck through run_all.
    {
        const p = try api.Problem.init(t.allocator, t.io, .{
            .source = .{ .bytes = .{ .data = deck, .origin = "order.cir" } },
            .output = .{ .path = batch_path },
        });
        defer p.deinit();
        try p.run_all();
    }
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = deck, .origin = "order.cir" } },
        .output = .{ .path = stepped_path },
    });
    defer p.deinit();
    var calls: usize = 0;
    while (!p.finished() and calls < 10_000) : (calls += 1) {
        for (0..p.query_count()) |i| _ = try p.advance(@fromBackingInt(@intCast(i)));
    }
    try t.expect(p.finished());
    try t.expectEqual(null, p.output_error());
    const stepped = try tmp.dir.readFileAlloc(t.io, "stepped.raw", t.allocator, .unlimited);
    defer t.allocator.free(stepped);
    const batch = try tmp.dir.readFileAlloc(t.io, "batch.raw", t.allocator, .unlimited);
    defer t.allocator.free(batch);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, stepped, "Title: query fixture\n"));
    try t.expectEqualSlices(u8, batch, stepped);
}

test "Problem: a title-only deck runs nothing and succeeds" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/title.raw", .{tmp.sub_path});
    defer t.allocator.free(path);
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = "--8<-- \"snippet.sp\"\n", .origin = "title.cir" } },
        .output = .{ .path = path },
    });
    defer p.deinit();
    try p.run_all();
    try t.expectEqual(@as(usize, 0), p.query_count());
    try t.expectEqual(null, p.output_error());
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
        // `.pnoise` names its input (a 0 A source, #57), which does not drive the solve.
        "device noise\nR1 out 0 1k\nI1 out 0 0\n.temp 27\n.noise v(out) dec 3 1k 10k\n.pnoise v(out) i1 dec 3 1k 10k 1k 0\n.end\n",
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

/// What a final-plan run of `jobs_deck` writes at `jobs`, as the CLI runs
/// it: the raw file and `.meas` text, which the caller frees, and the
/// main session's four points' `tf`.
const JobsRun = struct { raw: []u8, measures: []u8, tf: [4]f64 };

fn runJobs(tmp: *const std.testing.TmpDir, jobs: u16, warm_start: bool) !JobsRun {
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "jobs{d}{s}.raw", .{ jobs, if (warm_start) "w" else "" });
    const path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    defer t.allocator.free(path);
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = jobs_deck, .origin = "jobs.sp" } },
        .dialect = .hspice,
        .output = .{ .path = path },
        .backend = .{ .final_plan = true },
        .max_parallel = jobs,
        .point = .{ .warm_start = warm_start },
    });
    defer p.deinit();
    try p.run_all();
    var run: JobsRun = .{ .raw = &.{}, .measures = &.{}, .tf = undefined };
    var reasons: [4]api.Problem.Reason = undefined;
    try p.point_measures(try find(p, .tran), &.{"tf"}, &run.tf, &reasons);
    for (reasons) |r| try t.expectEqual(api.Problem.Reason.ok, r);
    var measures: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer measures.deinit();
    var errors: std.Io.Writer.Allocating = .init(t.allocator);
    defer errors.deinit();
    try p.print_measures(&measures.writer, &errors.writer);
    try t.expectEqual(@as(usize, 0), errors.written().len);
    run.raw = try tmp.dir.readFileAlloc(t.io, name, t.allocator, .unlimited);
    run.measures = try measures.toOwnedSlice();
    return run;
}

// Points 3 and 5 move M1 to the other bin, so they run as variant
// sessions in the same pool; the rest are rows of one template.
const jobs_deck =
    \\sweep jobs
    \\.param wn=1u rl=1k
    \\V1 d 0 2
    \\V2 g 0 pulse(0 2 1n 1n 1n 5n 20n)
    \\R1 d o 'rl'
    \\M1 o g 0 0 nm l=1u w='wn'
    \\C1 o 0 1p
    \\.model nm.1 nmos level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u vto=0.5 kp=2m
    \\.model nm.2 nmos level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u vto=0.7 kp=1m
    \\.data pts wn rl
    \\+ 1u 1k
    \\+ 1.05u 2k
    \\+ 2u 1k
    \\+ 1.1u 500
    \\+ 2.05u 3k
    \\+ 0.95u 1.5k
    \\.enddata
    \\.tran 0.1n 20n sweep data=pts
    \\.meas tran tf trig v(g) val=1 rise=1 targ v(o) val=1 fall=1
    \\.end
    \\
;

test "a .data sweep writes the same bytes at every --jobs, its bin-moving points included" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const serial = try runJobs(&tmp, 1, false);
    defer t.allocator.free(serial.raw);
    defer t.allocator.free(serial.measures);
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, serial.raw, "Plotname: Transient Analysis ("));
    try t.expectEqual(@as(usize, 6), std.mem.count(u8, serial.measures, "tf "));
    for ([_]u16{ 2, 3, 8 }) |jobs| {
        const again = try runJobs(&tmp, jobs, false);
        defer t.allocator.free(again.raw);
        defer t.allocator.free(again.measures);
        try t.expectEqualSlices(u8, serial.raw, again.raw);
        try t.expectEqualStrings(serial.measures, again.measures);
    }
}

test "--warm-start: every point starts from one nominal OP, so bytes match at every --jobs" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cold = try runJobs(&tmp, 1, false);
    defer t.allocator.free(cold.raw);
    defer t.allocator.free(cold.measures);
    const warm = try runJobs(&tmp, 1, true);
    defer t.allocator.free(warm.raw);
    defer t.allocator.free(warm.measures);
    // The same operating points within Newton's tolerances.
    for (cold.tf, warm.tf) |c, w| try t.expectApproxEqRel(c, w, 1e-6);
    for ([_]u16{ 3, 8 }) |jobs| {
        const again = try runJobs(&tmp, jobs, true);
        defer t.allocator.free(again.raw);
        defer t.allocator.free(again.measures);
        try t.expectEqualSlices(u8, warm.raw, again.raw);
        try t.expectEqualStrings(warm.measures, again.measures);
    }
}

test "Problem.append_points: warm-started points measure what cold ones do" {
    const template =
        \\points
        \\.param rl=1k
        \\V1 d 0 2
        \\V2 g 0 pulse(0 2 1n 1n 1n 5n 20n)
        \\R1 d o 'rl'
        \\M1 o g 0 0 nm l=1u w=1u
        \\C1 o 0 1p
        \\.model nm nmos level=1 vto=0.5 kp=2m
        \\.tran 0.1n 20n
        \\.meas tran tf trig v(g) val=1 rise=1 targ v(o) val=1 fall=1
        \\.end
        \\
    ;
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = template, .origin = "points.sp" } }, .dialect = .hspice, .live_params = &.{"rl"}, .max_parallel = 3 });
    defer p.deinit();
    const values = [_]f64{ 800, 1.5e3, 2.5e3 };
    const cold = try p.append_points(&values, values.len, .{});
    const warm = try p.append_points(&values, values.len, .{ .warm_start = true });
    try p.run_all();
    var tf: [2][values.len]f64 = undefined;
    var reasons: [values.len]api.Problem.Reason = undefined;
    for ([_]api.QueryId{ cold, warm }, &tf) |first, *out| {
        try p.point_measures(first, &.{"tf"}, out, &reasons);
        for (reasons) |r| try t.expectEqual(api.Problem.Reason.ok, r);
    }
    for (tf[0], tf[1]) |c, w| try t.expectApproxEqRel(c, w, 1e-6);
    // The warm points' operating points have their own prerequisite.
    try t.expect((try p.query_info(warm)).dependency.? != (try p.query_info(cold)).dependency.?);
}

test "Problem: an optimization takes the same path one point at a time and batched" {
    const fit =
        \\* common-source stage: fit the width and load to two points of the transfer curve
        \\.model nch NMOS(level=1 VTO=0.7 KP=110u GAMMA=0.4 LAMBDA=0.04 PHI=0.65)
        \\.param w1=optrange(2u, 0.5u, 20u) rv=optrange(5k, 1k, 50k)
        \\vdd vdd 0 1.8
        \\vin in 0 0.8
        \\m1 out in 0 0 nch W=w1 L=1u
        \\r1 vdd out rv
        \\.model optmod opt itropt=40 relin=1e-6 relout=1e-10
        \\.dc vin 0 1.8 0.01 sweep optimize=opt2 results=v1,v2 model=optmod
        \\.meas dc v1 find v(out) at=0.9 goal=1.682597
        \\.meas dc v2 find v(out) at=1.2 goal=1.082725
        \\.end
        \\
    ;
    var runs: [2]*api.Problem = undefined;
    for (&runs, [_]u16{ 1, 3 }, 0..) |*p, jobs, i| {
        errdefer for (runs[0..i]) |q| q.deinit();
        p.* = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = fit, .origin = "fit.sp" } }, .dialect = .hspice, .max_parallel = jobs });
    }
    defer for (runs) |p| p.deinit();
    for (runs) |p| try p.run_all();
    const a = runs[0].optimization[0];
    const b = runs[1].optimization[0];
    try t.expect(a.iterations > 1);
    try t.expectEqual(a.evaluations, b.evaluations);
    try t.expectEqualSlices(f64, a.history.x.items, b.history.x.items);
    try t.expectEqualSlices(f64, a.history.rss.items, b.history.rss.items);
}

/// `set_params`, an append at the new value, and its run.
fn tuneAndRun(allocator: std.mem.Allocator) !void {
    const p = try api.Problem.init(allocator, t.io, .{
        .source = .{ .bytes = .{ .data = "tuned oom\n.param rv=1k\nV1 in 0 1\nR1 in out {rv}\nR2 out 0 1k\n.op\n.end\n", .origin = "tuned.cir" } },
        .live_params = &.{"rv"},
    });
    defer p.deinit();
    try p.run_all();
    try p.set_params(&.{"rv"}, &.{3e3});
    var id: [1]api.QueryId = undefined;
    _ = try p.append_directives(".op", &id);
    try p.run_all();
}

test "Problem.set_params: every allocation failure leaves nothing behind" {
    try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, tuneAndRun, .{});
}

/// A run that writes a raw file, `.save` and `.stim` files into `dir`, then
/// prints its `.meas` results: each allocation on those paths fails once.
fn saveStimMeasure(allocator: std.mem.Allocator, dir: []const u8) !void {
    const out = try std.fmt.allocPrint(allocator, "{s}/a.raw", .{dir});
    defer allocator.free(out);
    const p = try api.Problem.init(allocator, t.io, .{
        .source = .{ .bytes = .{ .data = "write\nv1 a 0 pwl(0 0 1n 1)\nr1 a 0 1k\n.tran 0.5n 1n\n.save type=ic\n" ++
            ".stim tran pwl filename=rc v0=v(a) node1=b node2=0 npoints=3\n.meas tran vmax max v(a)\n.end\n", .origin = "write.sp" } },
        .dialect = .hspice,
        .output = .{ .path = out },
    });
    defer p.deinit();
    // An output failure is DeliveryFailed by contract; the sweep wants its cause.
    p.run_all() catch |err| return if (err == error.DeliveryFailed) p.output_error().? else err;
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    // The sink is a `Writer.Allocating`: WriteFailed is its OOM.
    p.print_measures(&sink.writer, &sink.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

test "Problem: .save, .stim and .meas output release everything at every allocation failure" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(dir);
    try t.checkAllAllocationFailures(@import("core").testing.fixed_growth, saveStimMeasure, .{dir});
    for ([_][]const u8{ "rc.pwl0_tr0", "write.ic0" }) |name| {
        const text = try tmp.dir.readFileAlloc(t.io, name, t.allocator, .unlimited);
        defer t.allocator.free(text);
        try t.expect(std.mem.startsWith(u8, text, "* write\n"));
    }
}

/// What one run of a deck under `point` gives: the `.meas` text (stdout,
/// then stderr), every point's `.tran` card values as bits, and the
/// accepted transient points, summed over its transients.
const MeasureRun = struct {
    text: []u8,
    bits: []u64,
    steps: usize,

    fn deinit(r: MeasureRun) void {
        t.allocator.free(r.text);
        t.allocator.free(r.bits);
    }
};

fn measureRun(source: api.Source, dialect: api.Dialect, point: api.requests.PointOptions) !MeasureRun {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = source, .dialect = dialect, .point = point });
    defer p.deinit();
    try p.run_all();
    var text: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer text.deinit();
    try p.print_measures(&text.writer, &text.writer);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(t.allocator);
    for (p.prepared.deck.measures) |m| if (m.analysis == .tran) try names.append(t.allocator, m.name);
    // Each of these decks runs one `.tran` per point.
    var first: ?api.QueryId = null;
    var points: usize = 0;
    var steps: usize = 0;
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const info = try p.query_info(id);
        if (!info.requested) continue;
        if (first == null) first = id;
        if (info.kind != .tran) continue;
        points += 1;
        const r = try p.result(id);
        steps += r.npoints;
        if (point.measures_only) try t.expect(r.varnames.len <= names.items.len * 2 + 1);
    }
    const values = try t.allocator.alloc(f64, points * names.items.len);
    errdefer t.allocator.free(values);
    const reasons = try t.allocator.alloc(api.Problem.Reason, points);
    defer t.allocator.free(reasons);
    try p.point_measures(first.?, names.items, values, reasons);
    return .{ .text = try text.toOwnedSlice(), .bits = @ptrCast(values), .steps = steps };
}

/// Every `.meas` card form the transient watch has a rule for, over a
/// 1 MHz sine into an RC; the last card resolves at 3 us of 6 us.
const every_card =
    \\every card
    \\v1 s 0 sin(0 1 1meg)
    \\r1 s o 1k
    \\c1 o 0 0.1n
    \\.tran 1n 6u
    \\.meas tran tw when v(s)=0.5 rise=2 td=0.5u
    \\.meas tran tv when v(s)=v(o) cross=3
    \\.meas tran d1 trig v(s) val=0.5 rise=1 targ v(o) val=0.2 rise=1
    \\.meas tran d2 trig at=1u targ v(o) val=0 fall=1
    \\.meas tran f1 find v(o) when v(s)=0.5 fall=2
    \\.meas tran f2 find v(o) at=2.5u
    \\.meas tran g1 deriv v(o) when v(s)=0 cross=3
    \\.meas tran g2 deriv v(s) at=1.2u
    \\.meas tran mx max v(o) from=1u to=2u
    \\.meas tran mn min v(o) from=1u to=2u
    \\.meas tran mxa max_at v(o) from=1u to=2u
    \\.meas tran mna min_at v(o) from=1u to=2u
    \\.meas tran p2 pp v(o) from=0.5u to=3u
    \\.meas tran av avg v(o) from=1u to=2u
    \\.meas tran rm rms v(s) from=0.3u to=1.3u
    \\.meas tran ig integ v(o) from=0 to=2.2u
    \\.meas tran pr param='d1*2+mx'
    \\.meas tran nv when v(s)=5 rise=1 to=3u
    \\.end
    \\
;

test "measures_only and early_stop: every .meas tran fixture measures as the stored run, to the bit" {
    const decks = [_]struct { api.Source, api.Dialect }{
        .{ .{ .file = "tests/fixtures/tran/bbd_ten_cells.sp" }, .ngspice },
        .{ .{ .file = "tests/fixtures/tran/zero_abstol_vntol.sp" }, .ngspice },
        .{ .{ .file = "tests/fixtures/tran/trap_maxord1_ngspice.sp" }, .ngspice },
        .{ .{ .file = "tests/fixtures/tran/zero_vntol_chgtol.sp" }, .ngspice },
        .{ .{ .file = "tests/fixtures/tran/gear_maxord6_ngspice.sp" }, .ngspice },
        .{ .{ .file = "tests/fixtures/optimize/rc_delay_fit.sp" }, .hspice },
        .{ .{ .file = "tests/fixtures/optimize/bisection_rc_max.sp" }, .hspice },
        .{ .{ .file = "tests/fixtures/hspice/meas_events.sp" }, .hspice },
        .{ .{ .file = "tests/fixtures/hspice/meas_forms.sp" }, .hspice },
        .{ .{ .file = "tests/fixtures/hspice/fft_meas.sp" }, .hspice },
        .{ .{ .file = "tests/fixtures/variants/monte_tran_meas.sp" }, .hspice },
        .{ .{ .file = "tests/fixtures/regression/ota_buffer_large_step.sp" }, .ngspice },
        .{ .{ .file = "tests/fixtures/regression/ota_buffer_large_step_0p88.sp" }, .ngspice },
        .{ .{ .bytes = .{ .data = every_card, .origin = "every.sp" } }, .ngspice },
    };
    const modes = [_]api.requests.PointOptions{
        .{ .measures_only = true },
        .{ .early_stop = true },
        .{ .measures_only = true, .early_stop = true },
    };
    for (decks) |d| {
        const want = try measureRun(d[0], d[1], .{});
        defer want.deinit();
        for (modes) |mode| {
            const got = try measureRun(d[0], d[1], mode);
            defer got.deinit();
            errdefer std.debug.print("deck {s}, {any}\n", .{ switch (d[0]) {
                .file => |f| f,
                .bytes => |b| b.origin,
            }, mode });
            try t.expectEqualStrings(want.text, got.text);
            try t.expectEqualSlices(u64, want.bits, got.bits);
            try t.expect(got.steps <= want.steps);
        }
    }
}

test "early_stop: every card resolves by 3 us of 6 us, so the run ends near halfway" {
    const source: api.Source = .{ .bytes = .{ .data = every_card, .origin = "every.sp" } };
    const full = try measureRun(source, .ngspice, .{});
    defer full.deinit();
    const cut = try measureRun(source, .ngspice, .{ .early_stop = true });
    defer cut.deinit();
    std.debug.print("every_card steps: full {d}, early stop {d}\n", .{ full.steps, cut.steps });
    try t.expect(cut.steps * 10 < full.steps * 6);
    // Only `nv`, whose event never happens, has no value.
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, full.text, "Error"));
    try t.expectEqualSlices(u64, full.bits, cut.bits);
}

/// An RC whose 50% delay is about 70 ps at 1k and 7 ns at 100k.
const abort_deck =
    \\abort bound
    \\.param rv=1k
    \\v1 in 0 pulse(0 1 0.1n 0.1n 0.1n 20n 40n)
    \\r1 in out {rv}
    \\c1 out 0 0.1p
    \\.tran 1p 10n
    \\.meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1
    \\.end
    \\
;

/// The RC deck of the C points tests (src/tests/c_api.zig), here as a
/// 16-row `.data` sweep for the CLI's `.meas` printout.
const points_body =
    \\points rc
    \\.param rv=1k cv=1p
    \\vdd vdd 0 1
    \\rl vdd 0 1k
    \\vin in 0 pwl(0 0 10p 1)
    \\r1 in out rv
    \\c1 out 0 cv
    \\
;
const points_meas =
    \\.meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1
    \\.meas tran e integ par('-v(in)*i(vin)') from=0 to=40n
    \\.end
    \\
;

test "points: abort_after fails only the points still unresolved past it, early_stop keeps the others' values" {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = abort_deck, .origin = "abort.sp" } }, .live_params = &.{"rv"} });
    defer p.deinit();
    const rows = [_]f64{ 1e3, 100e3, 2e3 };
    const plain = p.append_points(&rows, rows.len, .{}) catch |e| {
        std.debug.print("append: {s}\n", .{@errorName(e)});
        return e;
    };
    const bounded = try p.append_points(&rows, rows.len, .{ .measures_only = true, .early_stop = true, .abort_after = 1e-9 });
    p.run_all() catch |err| try t.expectEqual(error.MeasureBoundExceeded, err);
    errdefer std.debug.print("abort test: plain {d}, bounded {d}\n", .{ @backingInt(plain), @backingInt(bounded) });
    var want: [3]f64 = undefined;
    var want_why: [3]api.Problem.Reason = undefined;
    p.point_measures(plain, &.{"tpd"}, &want, &want_why) catch |e| {
        std.debug.print("plain: {s}\n", .{@errorName(e)});
        return e;
    };
    var got: [3]f64 = undefined;
    var why: [3]api.Problem.Reason = undefined;
    p.point_measures(bounded, &.{"tpd"}, &got, &why) catch |e| {
        std.debug.print("bounded: {s}\n", .{@errorName(e)});
        return e;
    };
    try t.expectEqualSlices(api.Problem.Reason, &.{ .ok, .ok, .ok }, &want_why);
    try t.expectEqualSlices(api.Problem.Reason, &.{ .ok, .aborted, .ok }, &why);
    try t.expect(std.math.isNan(got[1]));
    try t.expectEqual(@as(u64, @bitCast(want[0])), @as(u64, @bitCast(got[0])));
    try t.expectEqual(@as(u64, @bitCast(want[2])), @as(u64, @bitCast(got[2])));
    // The bounded points stopped near their delay, not at 10 ns.
    var lens: [2]usize = .{ 0, 0 };
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const info = try p.query_info(id);
        if (info.kind != .tran or info.status != .complete) continue;
        const r = try p.result(id);
        lens[@intFromBool(@backingInt(id) >= @backingInt(bounded))] += r.npoints;
        // TRIG/TARG streams: only the time column is recorded.
        if (@backingInt(id) >= @backingInt(bounded)) try t.expectEqual(@as(usize, 1), r.varnames.len);
    }
    std.debug.print("abort test steps: plain {d}, bounded {d}\n", .{ lens[0], lens[1] });
    try t.expect(lens[1] * 3 < lens[0]);
}

test "points: tangent slopes of .tran measures match central finite differences" {
    const source =
        \\tangents
        \\.param rv=1k cv=0.1p
        \\v1 in 0 pulse(0 1 0.1n 0.1n 0.1n 20n 40n)
        \\r1 in out {rv}
        \\c1 out 0 {cv}
        \\.tran 1p 2n 0 2p
        \\.meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1
        \\.meas tran vf find v(out) at=0.3n
        \\.meas tran ig integ v(out) from=0 to=1n
        \\.end
        \\
    ;
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "tangents.sp" } }, .live_params = &.{ "rv", "cv" } });
    defer p.deinit();
    const x = [2]f64{ 1e3, 0.1e-12 };
    const names = [_][]const u8{ "tpd", "vf", "ig" };
    // early_stop too: one row past resolution keeps the tangents' events.
    const tangent = try p.append_points(&x, 1, .{ .tangent_step = 1e-6, .early_stop = true, .measures_only = true });
    // Central differences, each parameter moved by 1e-3 of itself.
    const rel = 1e-3;
    var rows: [4][2]f64 = .{ x, x, x, x };
    for (0..2) |k| {
        rows[2 * k][k] *= 1 + rel;
        rows[2 * k + 1][k] *= 1 - rel;
    }
    const fd = try p.append_points(@ptrCast(&rows), 4, .{});
    try p.run_all();
    var slopes: [3 * 2]f64 = undefined;
    try p.point_tangents(tangent, 1, &names, &slopes);
    var values: [4 * 3]f64 = undefined;
    var why: [4]api.Problem.Reason = undefined;
    try p.point_measures(fd, &names, &values, &why);
    var worst: f64 = 0;
    defer std.debug.print("tangents vs central differences: worst relative gap {e}\n", .{worst});
    for (0..3) |c| for (0..2) |k| {
        const central = (values[(2 * k) * 3 + c] - values[(2 * k + 1) * 3 + c]) / (2 * rel * x[k]);
        const got = slopes[c * 2 + k];
        errdefer std.debug.print("card {s}, param {d}: tangent {e}, central {e}\n", .{ names[c], k, got, central });
        worst = @max(worst, @abs(got - central) / @abs(central));
        try t.expectApproxEqRel(central, got, 1e-3);
    };
    // The slopes don't change the point's own values.
    var own: [3]f64 = undefined;
    var own_why: [1]api.Problem.Reason = undefined;
    try p.point_measures(tangent, &names, &own, &own_why);
    try t.expectEqual(api.Problem.Reason.ok, own_why[0]);
}

test "Problem.append_points: measures equal the CLI's printed .meas of the same rows as a .data sweep" {
    var rows: [16][2]f64 = undefined;
    for (&rows, 0..) |*row, k| row.* = .{ 1e3 * @as(f64, @floatFromInt(k / 4 + 1)), 0.25e-12 * @as(f64, @floatFromInt(k % 4 + 1)) };
    // The last row's RC = 1 us never reaches 0.5 V: tpd is NaN there.
    rows[15] = .{ 1e6, 1e-12 };
    var swept: std.ArrayList(u8) = .empty;
    defer swept.deinit(t.allocator);
    try swept.appendSlice(t.allocator, points_body ++ ".data pts rv cv\n");
    for (rows) |p| try swept.print(t.allocator, "+ {e} {e}\n", .{ p[0], p[1] });
    try swept.appendSlice(t.allocator, ".enddata\n.tran 10p 40n sweep data=pts\n" ++ points_meas);
    const cli = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = swept.items, .origin = "data.sp" } }, .dialect = .hspice });
    defer cli.deinit();
    try cli.run_all();
    var printed: std.Io.Writer.Allocating = .init(t.allocator);
    defer printed.deinit();
    var errors: std.Io.Writer.Allocating = .init(t.allocator);
    defer errors.deinit();
    try cli.print_measures(&printed.writer, &errors.writer);

    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = points_body ++ ".tran 10p 40n\n" ++ points_meas, .origin = "points.sp" } },
        .dialect = .hspice,
        .live_params = &.{ "rv", "cv" },
    });
    defer p.deinit();
    const first = try p.append_points(@ptrCast(&rows), rows.len, .{});
    try p.run_all();
    var values: [16 * 2]f64 = undefined;
    var reasons: [16]api.Problem.Reason = undefined;
    try p.point_measures(first, &.{ "tpd", "e" }, &values, &reasons);
    try t.expectEqual(api.Problem.Reason.measure_unresolved, reasons[15]);

    // Each block: a heading naming the row, then one line per card.
    var lines = std.mem.splitScalar(u8, printed.written(), '\n');
    var k: usize = 0;
    var card: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Measurements for Transient Analysis") != null) {
            var want: [64]u8 = undefined;
            try t.expect(std.mem.indexOf(u8, line, try std.fmt.bufPrint(&want, "point {d} (", .{k})) != null);
            k += 1;
            card = 0;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[eq + 1 ..], ' ');
        const got = try std.fmt.parseFloat(f64, fields.next().?);
        const want = values[(k - 1) * 2 + card];
        try t.expectEqualStrings(if (card == 0) "tpd" else "e", std.mem.trim(u8, line[0..eq], " "));
        if (std.math.isNan(want)) try t.expect(std.math.isNan(got)) else try t.expectApproxEqRel(want, got, 1e-5);
        card += 1;
    }
    try t.expectEqual(@as(usize, 16), k);
}

test "Options.measures: run_all prints each point's .meas block as it ends, the bytes print_measures writes, at any max_parallel" {
    var swept: std.ArrayList(u8) = .empty;
    defer swept.deinit(t.allocator);
    try swept.appendSlice(t.allocator, points_body ++ ".data pts rv cv\n");
    for (0..12) |k| try swept.print(t.allocator, "+ {e} {e}\n", .{ 1e3 * @as(f64, @floatFromInt(k + 1)), 0.5e-12 });
    // The last row never reaches 0.5 V: an error line and a NaN.
    try swept.appendSlice(t.allocator, "+ 1e6 1e-12\n.enddata\n.tran 10p 40n sweep data=pts\n" ++ points_meas);
    const source: api.Source = .{ .bytes = .{ .data = swept.items, .origin = "data.sp" } };
    var want: std.Io.Writer.Allocating = .init(t.allocator);
    defer want.deinit();
    {
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = source, .dialect = .hspice });
        defer p.deinit();
        try p.run_all();
        try p.print_measures(&want.writer, &want.writer);
    }
    try t.expect(std.mem.count(u8, want.written(), "Measurements for Transient Analysis") == 13);
    for ([_]u16{ 1, 4 }) |jobs| {
        var got: std.Io.Writer.Allocating = .init(t.allocator);
        defer got.deinit();
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = source, .dialect = .hspice, .max_parallel = jobs, .point = .{ .measures_only = true }, .measures = .{ .out = &got.writer, .err = &got.writer } });
        defer p.deinit();
        try p.run_all();
        // Every block is out before run_all returns.
        try t.expectEqualStrings(want.written(), got.written());
        try p.print_measures(&got.writer, &got.writer);
        try t.expectEqualStrings(want.written(), got.written());
    }
}

test "Options.point.tangent_step with live parameters: the deck's own transient prints the tangents append_points gives" {
    const source =
        \\deck tangents
        \\.param rv=1k cv=0.1p
        \\v1 in 0 pulse(0 1 0.1n 0.1n 0.1n 20n 40n)
        \\r1 in out {rv}
        \\c1 out 0 {cv}
        \\.tran 1p 2n 0 2p
        \\.meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1
        \\.meas tran ig integ v(out) from=0 to=1n
        \\.end
        \\
    ;
    const live = [_][]const u8{ "rv", "cv" };
    const own = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "t.sp" } }, .live_params = &live, .point = .{ .tangent_step = 1e-6 } });
    defer own.deinit();
    try own.run_all();
    var printed: std.Io.Writer.Allocating = .init(t.allocator);
    defer printed.deinit();
    try own.print_tangents(&printed.writer);

    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "t.sp" } }, .live_params = &live });
    defer p.deinit();
    const first = try p.append_points(&.{ 1e3, 0.1e-12 }, 1, .{ .tangent_step = 1e-6 });
    try p.run_all();
    var slopes: [2 * 2]f64 = undefined;
    try p.point_tangents(first, 1, &.{ "tpd", "ig" }, &slopes);
    var want: std.Io.Writer.Allocating = .init(t.allocator);
    defer want.deinit();
    try want.writer.writeAll("\n  Tangents for Transient Analysis\n\n");
    for ([_][]const u8{ "tpd", "ig" }, 0..) |name, c| for (live, 0..) |param, k| {
        try t.expect(std.math.isFinite(slopes[c * 2 + k]));
        try want.writer.print("d({s})/d({s}) = {e:.6}\n", .{ name, param, slopes[c * 2 + k] });
    };
    try t.expectEqualStrings(want.written(), printed.written());
    // The deck's own run publishes its rows alone, the tangent rows apart.
    for (0..own.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        if ((try own.query_info(id)).kind != .tran) continue;
        const r = try own.result(id);
        try t.expectEqual(2 * r.npoints * r.varnames.len, r.tangents.len);
    }
}

/// Counts the bytes live through it, for tests that bound what a Problem keeps.
const Counting = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(isize) = .init(0),

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(n, alignment, ret) orelse return null;
        _ = self.live.fetchAdd(@intCast(n), .monotonic);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ret: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, n, ret)) return false;
        _ = self.live.fetchAdd(@as(isize, @intCast(n)) - @as(isize, @intCast(memory.len)), .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, n, ret) orelse return null;
        _ = self.live.fetchAdd(@as(isize, @intCast(n)) - @as(isize, @intCast(memory.len)), .monotonic);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret);
        _ = self.live.fetchSub(@intCast(memory.len), .monotonic);
    }
};

test "release_points: a Problem run batch after batch keeps a few KB per released point" {
    var counting: Counting = .{ .child = t.allocator };
    const source = abort_deck;
    const p = try api.Problem.init(counting.allocator(), t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "batches.sp" } }, .live_params = &.{"rv"}, .max_parallel = 4 });
    defer p.deinit();
    var rows: [50]f64 = undefined;
    for (&rows, 0..) |*r, k| r.* = 1e3 * (1 + 0.01 * @as(f64, @floatFromInt(k)));
    var live: [30]isize = undefined;
    var values: [rows.len]f64 = undefined;
    var why: [rows.len]api.Problem.Reason = undefined;
    for (&live) |*l| {
        const first = try p.append_points(&rows, rows.len, .{ .measures_only = true, .early_stop = true });
        try p.run_all();
        try p.point_measures(first, &.{"tpd"}, &values, &why);
        try p.release_points(first, rows.len);
        l.* = counting.live.load(.monotonic);
    }
    const per_point = @divTrunc(live[live.len - 1] - live[9], 20 * rows.len);
    std.debug.print("release_points: {d} B live after batch 10, {d} B after 30, {d} B per point\n", .{ live[9], live[live.len - 1], per_point });
    // Its two query rows, the copied query and its variant row, with the
    // slack of the tables' doubling; an unreleased point keeps its circuit
    // and waveform, tens of KB.
    try t.expect(per_point < 4096);
    try t.expectError(error.ResultUnavailable, p.point_measures(@fromBackingInt(@backingInt(p.session.outputs.items[p.session.outputs.items.len - 1])), &.{"tpd"}, values[0..1], why[0..1]));
}

const lane_deck = "tests/fixtures/variants/data_lane_stimulus.sp";

/// `source`, the lane fixture, without its .data table: one .tran at `sel`
/// and `pol`.
fn laneSolo(source: []const u8, sel: f64, pol: f64) ![]u8 {
    const start = std.mem.indexOf(u8, source, "\n.data ").? + 1;
    const end = std.mem.indexOf(u8, source, ".enddata\n").? + ".enddata\n".len;
    const spliced = try std.mem.concat(t.allocator, u8, &.{ source[0..start], source[end..] });
    defer t.allocator.free(spliced);
    const single = try std.mem.replaceOwned(u8, t.allocator, spliced, " sweep data=lanes", "");
    defer t.allocator.free(single);
    var line: [64]u8 = undefined;
    return std.mem.replaceOwned(u8, t.allocator, single, ".param vdd=1 sel=0 pol=1", try std.fmt.bufPrint(&line, ".param vdd=1 sel={d} pol={d}", .{ sel, pol }));
}

/// Every .tran point's samples, in request order, and the printed .meas
/// lines without their headings.
const LaneRun = struct {
    data: std.ArrayList(f64) = .empty,
    measures: std.ArrayList(u8) = .empty,
    /// Each point's time column.
    grids: std.ArrayList([]f64) = .empty,

    fn deinit(r: *LaneRun) void {
        for (r.grids.items) |g| t.allocator.free(g);
        r.grids.deinit(t.allocator);
        r.data.deinit(t.allocator);
        r.measures.deinit(t.allocator);
    }

    fn add(r: *LaneRun, source: []const u8) !void {
        return r.addWith(source, false);
    }

    fn addWith(r: *LaneRun, source: []const u8, lanes: bool) !void {
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "lane.sp" } }, .dialect = .hspice, .backend = .{ .lanes = lanes } });
        defer p.deinit();
        try p.run_all();
        for (0..p.query_count()) |i| {
            const id: api.QueryId = @fromBackingInt(@intCast(i));
            const info = try p.query_info(id);
            if (!info.requested or info.kind != .tran) continue;
            const result = try p.result(id);
            try r.data.appendSlice(t.allocator, result.data);
            const grid = try t.allocator.alloc(f64, result.npoints);
            errdefer t.allocator.free(grid);
            for (grid, 0..) |*time, k| time.* = result.data[k * result.varnames.len];
            try r.grids.append(t.allocator, grid);
        }
        var printed: std.Io.Writer.Allocating = .init(t.allocator);
        defer printed.deinit();
        try p.print_measures(&printed.writer, &printed.writer);
        var lines = std.mem.splitScalar(u8, printed.written(), '\n');
        while (lines.next()) |line| if (std.mem.indexOfScalar(u8, line, '=') != null and std.mem.indexOf(u8, line, "Measurements for") == null) {
            try r.measures.appendSlice(t.allocator, line);
            try r.measures.append(t.allocator, '\n');
        };
    }
};

test "per-lane stimulus (#212): each .data point equals its row run alone, to the bit, on one time grid" {
    const source = try std.Io.Dir.cwd().readFileAlloc(t.io, lane_deck, t.allocator, .unlimited);
    defer t.allocator.free(source);
    var swept: LaneRun = .{};
    defer swept.deinit();
    try swept.add(source);
    var alone: LaneRun = .{};
    defer alone.deinit();
    for ([_][2]f64{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 } }) |row| {
        const solo = try laneSolo(source, row[0], row[1]);
        defer t.allocator.free(solo);
        try alone.add(solo);
    }
    try t.expectEqual(@as(usize, 4), swept.grids.items.len);
    try t.expectEqual(@as(usize, 12), std.mem.count(u8, swept.measures.items, "\n"));
    try t.expectEqualStrings(alone.measures.items, swept.measures.items);
    try t.expectEqualSlices(u64, @ptrCast(alone.data.items), @ptrCast(swept.data.items));
    // Every point lands the same edge breakpoints, levels aside, and none
    // rejects a step differently: one accepted grid.
    for (swept.grids.items[1..]) |grid| try t.expectEqualSlices(u64, @ptrCast(swept.grids.items[0]), @ptrCast(grid));
}

const ac_lane_deck =
    \\* AC-family lanes (#209): .ac, .noise and .tf of a diode-loaded RC
    \\* stepped over rl; points 0, 2, 4 and 6 repeat rl = 1k.
    \\.param rl=1k
    \\v1 in 0 dc 1 ac 1
    \\r1 in mid {rl}
    \\c1 mid 0 1n
    \\d1 mid out dmod
    \\r2 out 0 2k
    \\c2 out 0 0.5n
    \\.model dmod d is=1e-14 cjo=1p
    \\.step param rl list 1k 2k 1k 500 1k 3k 1k 700
    \\.ac dec 10 1k 1g
    \\.noise v(out) v1 dec 10 1k 1g
    \\.tf v(out) v1
    \\.end
    \\
;

/// Each requested query's data, in request order, per kind.
fn acLaneRun(lanes: bool) !std.ArrayList([]f64) {
    const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = ac_lane_deck, .origin = "ac_lanes.sp" } }, .backend = .{ .lanes = lanes } });
    defer p.deinit();
    try p.run_all();
    var out: std.ArrayList([]f64) = .empty;
    errdefer {
        for (out.items) |d| t.allocator.free(d);
        out.deinit(t.allocator);
    }
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const info = try p.query_info(id);
        if (!info.requested) continue;
        try out.append(t.allocator, try t.allocator.dupe(f64, (try p.result(id)).data));
    }
    return out;
}

test "AC-family lanes (#209): every .step point's .ac, .noise and .tf equal under --lanes, and repeated points equal each other" {
    var alone = try acLaneRun(false);
    defer {
        for (alone.items) |d| t.allocator.free(d);
        alone.deinit(t.allocator);
    }
    var laned = try acLaneRun(true);
    defer {
        for (laned.items) |d| t.allocator.free(d);
        laned.deinit(t.allocator);
    }
    // 8 points of .ac, .tf and .noise, which publishes two plots (the
    // spectra and the integrated totals).
    try t.expectEqual(@as(usize, 32), laned.items.len);
    for (alone.items, laned.items) |a, b| try t.expectEqualSlices(u64, @ptrCast(a), @ptrCast(b));
    // Request order is point-major or kind-major; find the rl = 1k rows of
    // the first kind by content instead of position.
    var same: usize = 0;
    for (laned.items[1..]) |d| same += @intFromBool(d.len == laned.items[0].len and std.mem.eql(u64, @ptrCast(d), @ptrCast(laned.items[0])));
    try t.expect(same >= 3);
}

test "per-lane stimulus (#212) under lanes: each .data point equals its row run alone, to the bit" {
    const source = try std.Io.Dir.cwd().readFileAlloc(t.io, lane_deck, t.allocator, .unlimited);
    defer t.allocator.free(source);
    var swept: LaneRun = .{};
    defer swept.deinit();
    try swept.addWith(source, true);
    var alone: LaneRun = .{};
    defer alone.deinit();
    for ([_][2]f64{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 } }) |row| {
        const solo = try laneSolo(source, row[0], row[1]);
        defer t.allocator.free(solo);
        try alone.add(solo);
    }
    try t.expectEqualStrings(alone.measures.items, swept.measures.items);
    try t.expectEqualSlices(u64, @ptrCast(alone.data.items), @ptrCast(swept.data.items));
    for (swept.grids.items, alone.grids.items) |a, b| try t.expectEqualSlices(u64, @ptrCast(b), @ptrCast(a));
}

const chain_deck =
    \\* Lane lockstep (#207): 16 sizing points of an 8-stage inverter chain
    \\* with RC wires (lane-batched-simulation.md §1 on level-1 MOS), plus a
    \\* moved input edge, an extreme wire and a failing row.
    \\.param wn=1u wp=2u rw=200 cw=5f td=20p
    \\vdd vdd 0 1
    \\vin in 0 pulse(0 1 'td' 10p 10p 100p 300p)
    \\.subckt stage a z vdd
    \\mn y a 0 0 nm l=0.1u w='wn'
    \\mp y a vdd vdd pm l=0.1u w='wp'
    \\rw y z 'rw'
    \\cw z 0 'cw'
    \\.ends
    \\x1 in n1 vdd stage
    \\x2 n1 n2 vdd stage
    \\x3 n2 n3 vdd stage
    \\x4 n3 n4 vdd stage
    \\x5 n4 n5 vdd stage
    \\x6 n5 n6 vdd stage
    \\x7 n6 n7 vdd stage
    \\x8 n7 n8 vdd stage
    \\.model nm nmos level=1 vto=0.3 kp=200u
    \\.model pm pmos level=1 vto=-0.3 kp=100u
    \\.data pts wn wp rw cw td
    \\ROWS
    \\.enddata
    \\.tran 1p 400p sweep data=pts
    \\.meas tran tpd trig v(in) val=0.5 rise=1 targ v(n8) val=0.5 cross=1
    \\.meas tran trise trig v(n8) val=0.2 rise=1 targ v(n8) val=0.8 rise=1
    \\.meas tran tfall trig v(n8) val=0.8 fall=1 targ v(n8) val=0.2 fall=1
    \\.end
    \\
;

/// (wn, wp, rw, cw, td): 16 sizing points drawn as lockstep.py draws them
/// (nfin 2-4 as width 0.5-1.5 um, rw and cw 0.5-2x), then a moved edge,
/// an extreme wire, and rw = 0, which fails (CHECK: if the frontend
/// clamps r = 0 instead of failing, the test still holds; it then only
/// checks that some row differs, see the last assert).
const chain_rows = [_][5]f64{
    .{ 1.0e-6, 2.0e-6, 200, 5e-15, 20e-12 },   .{ 0.5e-6, 1.0e-6, 137, 3.1e-15, 20e-12 },
    .{ 1.5e-6, 3.0e-6, 352, 9.2e-15, 20e-12 }, .{ 1.0e-6, 1.0e-6, 101, 2.6e-15, 20e-12 },
    .{ 0.5e-6, 3.0e-6, 288, 7.7e-15, 20e-12 }, .{ 1.5e-6, 1.0e-6, 214, 4.0e-15, 20e-12 },
    .{ 1.0e-6, 3.0e-6, 390, 6.6e-15, 20e-12 }, .{ 0.5e-6, 2.0e-6, 166, 9.9e-15, 20e-12 },
    .{ 1.5e-6, 2.0e-6, 121, 2.9e-15, 20e-12 }, .{ 1.0e-6, 2.0e-6, 305, 8.4e-15, 20e-12 },
    .{ 0.5e-6, 1.0e-6, 255, 5.5e-15, 20e-12 }, .{ 1.5e-6, 3.0e-6, 178, 3.7e-15, 20e-12 },
    .{ 1.0e-6, 1.0e-6, 333, 7.1e-15, 20e-12 }, .{ 0.5e-6, 3.0e-6, 110, 6.0e-15, 20e-12 },
    .{ 1.5e-6, 1.0e-6, 270, 4.8e-15, 20e-12 }, .{ 1.0e-6, 3.0e-6, 199, 8.8e-15, 20e-12 },
    .{ 1.0e-6, 2.0e-6, 200, 5e-15, 37e-12 },   .{ 1.0e-6, 2.0e-6, 1e9, 5e-15, 20e-12 },
    .{ 1.0e-6, 2.0e-6, 0, 5e-15, 20e-12 },
};

/// `chain_deck` with `order`'s rows in its .data table.
fn chainSwept(order: []const usize) ![]u8 {
    var rows: std.Io.Writer.Allocating = .init(t.allocator);
    defer rows.deinit();
    for (order) |k| {
        const r = chain_rows[k];
        try rows.writer.print("+ {e} {e} {e} {e} {e}\n", .{ r[0], r[1], r[2], r[3], r[4] });
    }
    return std.mem.replaceOwned(u8, t.allocator, chain_deck, "ROWS\n", rows.written());
}

/// `chain_deck` without its .data table, at row `k` alone.
fn chainSolo(k: usize) ![]u8 {
    const r = chain_rows[k];
    var line: [128]u8 = undefined;
    const p = try std.fmt.bufPrint(&line, ".param wn={e} wp={e} rw={e} cw={e} td={e}", .{ r[0], r[1], r[2], r[3], r[4] });
    const start = std.mem.indexOf(u8, chain_deck, ".data ").?;
    const end = std.mem.indexOf(u8, chain_deck, ".enddata\n").? + ".enddata\n".len;
    const cut = try std.mem.concat(t.allocator, u8, &.{ chain_deck[0..start], chain_deck[end..] });
    defer t.allocator.free(cut);
    const plain = try std.mem.replaceOwned(u8, t.allocator, cut, " sweep data=pts", "");
    defer t.allocator.free(plain);
    return std.mem.replaceOwned(u8, t.allocator, plain, ".param wn=1u wp=2u rw=200 cw=5f td=20p", p);
}

/// Each requested .tran point's samples (empty for a failed point) and
/// error name, in request order.
const Points = struct {
    data: std.ArrayList([]f64) = .empty,
    errs: std.ArrayList(?anyerror) = .empty,

    fn deinit(ps: *Points) void {
        for (ps.data.items) |d| t.allocator.free(d);
        ps.data.deinit(t.allocator);
        ps.errs.deinit(t.allocator);
    }

    fn collect(ps: *Points, source: []const u8, lanes: bool) !void {
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "chain.sp" } }, .dialect = .hspice, .backend = .{ .lanes = lanes } });
        defer p.deinit();
        // CHECK: whether `run_all` fails when one point fails; if it does,
        // catch and continue, the per-query results below still tell.
        p.run_all() catch {};
        for (0..p.query_count()) |i| {
            const id: api.QueryId = @fromBackingInt(@intCast(i));
            const info = try p.query_info(id);
            if (!info.requested or info.kind != .tran) continue;
            if (p.result(id)) |res| {
                try ps.data.append(t.allocator, try t.allocator.dupe(f64, res.data));
                try ps.errs.append(t.allocator, null);
            } else |e| {
                try ps.data.append(t.allocator, &.{});
                try ps.errs.append(t.allocator, e);
            }
        }
    }
};

test "lane lockstep (#207): 16 sizing points, a moved edge, an extreme and a failing row, in three orders, each bitwise its run alone" {
    var alone: Points = .{};
    defer alone.deinit();
    for (0..chain_rows.len) |k| {
        const solo = try chainSolo(k);
        defer t.allocator.free(solo);
        try alone.collect(solo, false);
    }
    try t.expectEqual(chain_rows.len, alone.data.items.len);
    var identity: [chain_rows.len]usize = undefined;
    for (&identity, 0..) |*o, k| o.* = k;
    var reversed = identity;
    std.mem.reverse(usize, &reversed);
    var shuffled = identity;
    var prng = std.Random.DefaultPrng.init(207);
    prng.random().shuffle(usize, &shuffled);
    for ([_][]const usize{ &identity, &reversed, &shuffled }) |order| {
        const src = try chainSwept(order);
        defer t.allocator.free(src);
        var got: Points = .{};
        defer got.deinit();
        try got.collect(src, true);
        try t.expectEqual(order.len, got.data.items.len);
        for (order, got.data.items, got.errs.items) |k, d, e| {
            try t.expectEqual(alone.errs.items[k], e);
            try t.expectEqualSlices(u64, @ptrCast(alone.data.items[k]), @ptrCast(d));
        }
    }
    // Some row must fail (rw = 0) or the failing-lane case tested nothing.
    try t.expect(std.mem.indexOfNone(?anyerror, alone.errs.items, &.{null}) != null);
}
