const std = @import("std");
const api = @import("problem");
const t = std.testing;
const deck = "query fixture\nV1 in 0 dc 1 ac 1\nR1 in out 1k\nC1 out 0 1n\n.ac dec 80 1 100k\n.tran 1n 10n uic\n.end\n";

fn create(source: []const u8) !*api.Problem {
    return api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "memory.cir" } }, .max_parallel = 2 });
}

fn find(p: *api.Problem, kind: api.requests.Kind) !api.QueryId {
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @enumFromInt(i);
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
    try t.checkAllAllocationFailures(t.allocator, construct, .{});
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
    const copied = try t.allocator.alloc(f64, try p.copy_result(ac, &.{}));
    defer t.allocator.free(copied);
    _ = try p.copy_result(ac, copied);
    try t.expectEqualSlices(f64, result.data, copied);
    const complete = try p.advance(ac);
    try t.expectEqual(api.Status.complete, complete.status);
    try t.expectEqualSlices(f64, result.data, copied);
}

test "Problem: stepped and parallel execution match run_all for AC and transient" {
    const serial = try create(deck);
    defer serial.deinit();
    serial.limits.max_parallel = 1;
    try serial.run_all();
    const stepped = try create(deck);
    defer stepped.deinit();
    var ids: [8]api.QueryId = undefined;
    var events: [8]api.Advance = undefined;
    var advances: usize = 0;
    while (!stepped.session.finished()) {
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
    for (0..p.query_count()) |i| try t.expectEqual(api.Status.pending, (try p.query_info(@enumFromInt(i))).status);
}

test "Problem: short copy-out buffers and invalid scopes leave caller storage untouched" {
    const p = try create(deck);
    defer p.deinit();
    var ids = [_]api.QueryId{api.requests.invalid_query};
    try t.expectEqual(@as(usize, 2), try p.ready_queries(.all, &ids));
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
    const result = try p.result(ac);
    try t.expectEqual(result.data.len, try p.copy_result(ac, &values));
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
    try t.expectEqualStrings("owned.cir", p.origin);
    try t.expect(std.mem.startsWith(u8, p.source, "owned input\n"));
    try t.expectEqual(@as(u32, 1), p.query_count());
    const op = try find(p, .op); // A deck without directives gets one OP.
    var ports = [_]api.requests.Port{.{ .node = p.prepared.source_node, .branch = p.prepared.source_branch }};
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
    const ports = [_]api.requests.Port{.{ .node = p.prepared.source_node, .branch = p.prepared.source_branch }};
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
        var ids = [_]api.QueryId{sp} ** jobs.len;
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

test {
    _ = @import("analyses.zig");
}

test "Problem: parameter sweeps cannot mutate concurrently running transient state" {
    const input = "independent state\nV1 in 0 dc 1\nR1 in out 1k\nC1 out 0 1n\n.tran 1n 8n\n.end\n";
    const serial = try create(input);
    defer serial.deinit();
    serial.limits.max_parallel = 1;
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
        const id: api.QueryId = @enumFromInt(i);
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
