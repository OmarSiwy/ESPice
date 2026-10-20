//! C ABI contract through include/espice.h, linked against libespice.a.
const std = @import("std");
const c = @import("espice_h");

test "C creation validates versions, tags and pointer lengths" {
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    try std.testing.expectEqual(@as(u32, @sizeOf(c.espice_create_options)), options.struct_size);
    try std.testing.expectEqual(c.espice_abi_version(), options.abi_version);
    var handle: ?*c.espice_problem = null;
    var diagnostic: [128]u8 = undefined;
    options.abi_version += 1;
    try std.testing.expectEqual(@as(u32, c.ESPICE_ABI_MISMATCH), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    try std.testing.expect(handle == null);
    try std.testing.expectEqualStrings("AbiMismatch", std.mem.sliceTo(&diagnostic, 0));
    options.abi_version = c.ESPICE_ABI_VERSION;
    options.source = .{ .data = null, .len = 1 };
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    options.source = .{ .data = "ignored.cir", .len = "ignored.cir".len };
    options.backend = 99;
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    options.backend = 0;
    options.struct_size = @offsetOf(c.espice_create_options, "zig_path") - 1;
    try std.testing.expectEqual(@as(u32, c.ESPICE_ABI_MISMATCH), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    options.struct_size = @sizeOf(c.espice_create_options);
    options.max_parallel = 65536;
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_query_count(null, null));
    _ = c.espice_destroy(null);
}

test "C lifecycle copies metadata, advances prerequisites and appends transactionally" {
    const deck =
        "C ABI RC\nV1 in 0 dc 1 ac 1\nR1 in out 1000\nC1 out 0 1u\n.op\n.ac dec 2 1 1000\n.end\n";
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = 1;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.origin = .{ .data = "abi.cir", .len = "abi.cir".len };
    var handle: ?*c.espice_problem = null;
    var diagnostic: [128]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    defer _ = c.espice_destroy(handle);
    var count: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0), c.espice_query_count(handle, &count));
    var ac_id: u32 = c.ESPICE_NO_QUERY;
    var info: c.espice_query_info = undefined;
    for (0..count) |id| {
        try std.testing.expectEqual(@as(u32, 0), c.espice_get_query_info(handle, @intCast(id), &info));
        if (info.kind == 0) ac_id = @intCast(id);
    }
    try std.testing.expect(ac_id != c.ESPICE_NO_QUERY);
    try std.testing.expectEqual(@as(u32, 0), c.espice_get_query_info(handle, ac_id, &info));
    try std.testing.expect(info.dependency != c.ESPICE_NO_QUERY);
    const dependency = info.dependency;

    var needed: usize = 0;
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_print(handle, null, null, 0, &needed));
    const tree = try std.testing.allocator.alloc(u8, needed);
    defer std.testing.allocator.free(tree);
    try std.testing.expectEqual(@as(u32, 0), c.espice_print(handle, null, tree.ptr, tree.len, &needed));
    try std.testing.expectEqual(@as(u8, 0), tree[needed - 1]);
    const inherited = try std.testing.allocator.alloc(u8, needed);
    defer std.testing.allocator.free(inherited);
    const zeroed = std.mem.zeroes(c.espice_print_options);
    try std.testing.expectEqual(@as(u32, 0), c.espice_print(handle, &zeroed, inherited.ptr, inherited.len, &needed));
    try std.testing.expectEqualSlices(u8, tree, inherited);
    try std.testing.expectEqual(@as(u32, 0), c.espice_get_query_info(handle, ac_id, &info));
    try std.testing.expectEqual(@as(u32, 0), info.status); // Preview is pure.

    var event: c.espice_advance_event = undefined;
    try std.testing.expectEqual(@as(u32, 0), c.espice_advance(handle, ac_id, &event));
    try std.testing.expectEqual(ac_id, event.requested);
    try std.testing.expectEqual(dependency, event.advanced);
    try std.testing.expectEqual(@as(u32, 0), c.espice_run_all(handle));
    var result: c.espice_result_info = undefined;
    try std.testing.expectEqual(@as(u32, 0), c.espice_get_result_info(handle, ac_id, &result));
    try std.testing.expectEqual(@as(u32, 1), result.is_complex);
    try std.testing.expect(result.value_count != 0);
    try std.testing.expectEqual(result.point_count * result.variable_count * 2, result.value_count);
    var short = [_]f64{-999};
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_copy_result(handle, ac_id, &short, short.len, &needed));
    try std.testing.expectEqual(@as(f64, -999), short[0]);
    try std.testing.expectEqual(result.value_count, needed);
    const values = try std.testing.allocator.alloc(f64, needed);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(u32, 0), c.espice_copy_result(handle, ac_id, values.ptr, values.len, &needed));
    for (values) |value| try std.testing.expect(std.math.isFinite(value));
    var view: [*c]const f64 = null;
    var view_len: usize = 0;
    try std.testing.expectEqual(@as(u32, 0), c.espice_result_view(handle, ac_id, &view, &view_len));
    try std.testing.expectEqualSlices(f64, values, view[0..view_len]);
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_result_view(handle, c.ESPICE_NO_QUERY, &view, &view_len));
    try std.testing.expectEqual(@as(usize, 0), view_len);
    var output_column: ?usize = null;
    for (0..result.variable_count) |variable| {
        try std.testing.expectEqual(@as(u32, 0), c.espice_copy_result_name(handle, ac_id, @intCast(variable), &diagnostic, diagnostic.len, &needed));
        if (std.mem.eql(u8, std.mem.sliceTo(&diagnostic, 0), "v(out)")) output_column = variable;
    }
    const column = output_column orelse return error.MissingOutputVoltage;
    for (0..@intCast(result.point_count)) |point| {
        const row = values[point * result.variable_count * 2 ..][0 .. result.variable_count * 2];
        const omega_rc = 2 * std.math.pi * row[0] * 1e-3;
        try std.testing.expectApproxEqAbs(1 / (1 + omega_rc * omega_rc), row[2 * column], 1e-8);
        try std.testing.expectApproxEqAbs(-omega_rc / (1 + omega_rc * omega_rc), row[2 * column + 1], 1e-8);
    }
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_copy_result_name(handle, ac_id, c.ESPICE_PLOT_TITLE, null, 0, &needed));
    const title = try std.testing.allocator.alloc(u8, needed);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqual(@as(u32, 0), c.espice_copy_result_name(handle, ac_id, c.ESPICE_PLOT_TITLE, title.ptr, title.len, &needed));
    try std.testing.expectEqual(@as(u8, 0), title[needed - 1]);

    const text = ".ac dec 3 10 100\n";
    const directives: c.espice_bytes = .{ .data = text.ptr, .len = text.len };
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_append_directives(handle, directives, null, 0, &needed));
    var after_sizing: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0), c.espice_query_count(handle, &after_sizing));
    try std.testing.expectEqual(count, after_sizing);
    const ids = try std.testing.allocator.alloc(u32, needed);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(u32, 0), c.espice_append_directives(handle, directives, ids.ptr, ids.len, &needed));
    try std.testing.expectEqual(@as(u32, 0), c.espice_run_all(handle));
    try std.testing.expectEqual(@as(u32, 0), c.espice_get_result_info(handle, ids[0], &result));

    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_get_query_info(handle, c.ESPICE_NO_QUERY, &info));
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_error_message(handle, null, 0, &needed));
    try std.testing.expectEqual(@as(u32, 0), c.espice_error_message(handle, &diagnostic, diagnostic.len, &needed));
    try std.testing.expectEqualStrings("InvalidQuery", std.mem.sliceTo(&diagnostic, 0));
}

test "C short buffers and invalid frontiers do not modify IDs, events or query state" {
    const deck = "C frontier\nV1 in 0 dc 1 ac 1\nR1 in out 1k\nC1 out 0 1n\n.ac dec 2 1 10\n.tran 1n 5n uic\n.end\n";
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.origin = .{ .data = "frontier.cir", .len = "frontier.cir".len };
    var handle: ?*c.espice_problem = null;
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&options, &handle, null, 0));
    defer _ = c.espice_destroy(handle);
    var required: usize = 0;
    var ids = [_]u32{ c.ESPICE_NO_QUERY, c.ESPICE_NO_QUERY };
    const all: c.espice_scope = .{ .kind = c.ESPICE_ALL, .id = 0 };
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_ready_queries(handle, all, &ids, 1, &required));
    try std.testing.expectEqual(@as(usize, 2), required);
    try std.testing.expectEqualSlices(u32, &.{ c.ESPICE_NO_QUERY, c.ESPICE_NO_QUERY }, &ids);
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_ready_queries(handle, all, null, 2, &required));
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_ready_queries(handle, all, &ids, ids.len, &required));
    var events = @as([2]c.espice_advance_event, @splat(std.mem.zeroes(c.espice_advance_event)));
    events[0].reserved = 123;
    const before = events;
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_advance_ready(handle, &ids, ids.len, 2, &events, 1, &required));
    try std.testing.expectEqual(@as(usize, 2), required);
    try std.testing.expectEqualDeep(before, events);
    const duplicate = [_]u32{ ids[0], ids[0] };
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_advance_ready(handle, &duplicate, 2, 2, &events, 2, &required));
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_advance_ready(handle, &ids, 2, 0, &events, 2, &required));
    for (ids) |id| {
        var info: c.espice_query_info = undefined;
        try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_get_query_info(handle, id, &info));
        try std.testing.expectEqual(@as(u32, c.ESPICE_PENDING), info.status);
    }
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_advance_ready(handle, &ids, 2, 2, &events, 2, &required));
    for (ids, events) |id, event| {
        try std.testing.expectEqual(id, event.requested);
        try std.testing.expectEqual(id, event.advanced);
        try std.testing.expectEqual(@as(u32, 0), event.reserved);
    }
    // Destroy also exercises cancellation/join through the opaque handle.
}

test "C entry points reject NULL handles and malformed options" {
    c.espice_default_options(null);
    var n: usize = 0;
    var u: u32 = 0;
    const all: c.espice_scope = .{ .kind = c.ESPICE_ALL, .id = 0 };
    const empty: c.espice_bytes = .{ .data = null, .len = 0 };
    const invalid: u32 = c.ESPICE_INVALID_ARGUMENT;
    const t = std.testing;
    try t.expectEqual(invalid, c.espice_query_count(null, &u));
    try t.expectEqual(invalid, c.espice_get_query_info(null, 0, null));
    try t.expectEqual(invalid, c.espice_ready_queries(null, all, null, 0, &n));
    try t.expectEqual(invalid, c.espice_advance(null, 0, null));
    try t.expectEqual(invalid, c.espice_advance_ready(null, null, 0, 1, null, 0, &n));
    try t.expectEqual(invalid, c.espice_run_all(null));
    try t.expectEqual(invalid, c.espice_append_directives(null, empty, null, 0, &n));
    try t.expectEqual(invalid, c.espice_get_result_info(null, 0, null));
    try t.expectEqual(invalid, c.espice_copy_result(null, 0, null, 0, &n));
    try t.expectEqual(invalid, c.espice_result_view(null, 0, null, null));
    // On any failure the view is NULL and 0, a NULL handle included (#76).
    const dummy: f64 = 0;
    var view: [*c]const f64 = &dummy;
    n = 7;
    try t.expectEqual(invalid, c.espice_result_view(null, 0, &view, &n));
    try t.expect(view == null);
    try t.expectEqual(@as(usize, 0), n);
    try t.expectEqual(invalid, c.espice_copy_result_name(null, 0, 0, null, 0, &n));
    try t.expectEqual(invalid, c.espice_print(null, null, null, 0, &n));
    try t.expectEqual(invalid, c.espice_error_message(null, null, 0, &n));
    try t.expectEqual(invalid, c.espice_query_error_message(null, 0, null, 0, &n));

    const deck = "C options\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n";
    var good: c.espice_create_options = undefined;
    c.espice_default_options(&good);
    good.source_kind = c.ESPICE_BYTES;
    good.source = .{ .data = deck.ptr, .len = deck.len };
    var handle: ?*c.espice_problem = null;
    var diagnostic: [4]u8 = undefined;
    try t.expectEqual(invalid, c.espice_create(&good, null, &diagnostic, diagnostic.len));
    try t.expectEqual(invalid, c.espice_create(null, &handle, &diagnostic, diagnostic.len));
    try t.expect(handle == null);
    // Truncated, still NUL-terminated.
    try t.expectEqualStrings("Inv", std.mem.sliceTo(&diagnostic, 0));
    try t.expectEqual(invalid, c.espice_create(&good, &handle, null, 1));
    try t.expect(handle == null);
    for (0..10) |case| {
        var bad = good;
        switch (case) {
            0 => bad.source_kind = 2,
            1 => bad.dialect = 3,
            2 => bad.output_format = 9,
            3 => bad.explicit_gpu = 2,
            4 => bad.max_parallel = 0,
            5 => bad.source.len = 0,
            6 => bad.origin = .{ .data = null, .len = 1 },
            7 => bad.output_path = .{ .data = null, .len = 1 },
            8 => bad.zig_path = .{ .data = null, .len = 1 },
            9 => bad.share_path = .{ .data = null, .len = 1 },
            else => unreachable,
        }
        try t.expectEqual(invalid, c.espice_create(&bad, &handle, null, 0));
        try t.expect(handle == null);
    }
    // A caller built before the toolchain fields: they are never read.
    var old = good;
    old.struct_size = @offsetOf(c.espice_create_options, "zig_path");
    old.zig_path = .{ .data = null, .len = 1 };
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&old, &handle, null, 0));
    _ = c.espice_destroy(handle);
    // A newer caller's larger struct is accepted; only our prefix is read.
    good.struct_size += 16;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&good, &handle, null, 0));
    _ = c.espice_destroy(handle);
}

test "C creation hands the toolchain paths to .hdl loading (#13)" {
    const deck = "C toolchain\n.hdl \"m.va\"\nN1 1 0 m\nR1 1 0 1k\n.op\n.end\n";
    const share = "/nonexistent-espice-test-dir/share/espice";
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.share_path = .{ .data = share.ptr, .len = share.len };
    var handle: ?*c.espice_problem = null;
    var diagnostic: [64]u8 = undefined;
    try std.testing.expectEqual(@as(u32, c.ESPICE_FAILED), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    try std.testing.expect(handle == null);
    try std.testing.expectEqualStrings("HdlShareNotFound", std.mem.sliceTo(&diagnostic, 0));
}

test "C creation routes .hdl display-task lines to the display callback (#127)" {
    const t = std.testing;
    const path = "tests/fixtures/hdl/veriloga_strobe.sp";
    const Sink = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        fn put(text: [*c]const u8, len: usize, user: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user.?));
            @memcpy(self.buf[self.len..][0..len], text[0..len]);
            self.len += len;
        }
    };
    var sink: Sink = .{};
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_FILE;
    options.source = .{ .data = path.ptr, .len = path.len };
    options.display = Sink.put;
    options.display_user = &sink;
    var handle: ?*c.espice_problem = null;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&options, &handle, null, 0));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_run_all(handle));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_destroy(handle));
    try t.expectEqualStrings("n1 vdrop = 0.35\n", sink.buf[0..sink.len]);

    // A caller built before the display fields: they are never read.
    const deck = "C old display\nV1 1 0 1\nR1 1 0 1k\n.op\n.end\n";
    var old = options;
    old.source_kind = c.ESPICE_BYTES;
    old.source = .{ .data = deck.ptr, .len = deck.len };
    old.struct_size = @offsetOf(c.espice_create_options, "display");
    old.display = @ptrFromInt(8);
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&old, &handle, null, 0));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_destroy(handle));
}

test "C calls on a live handle validate every pointer, scope and preview" {
    const t = std.testing;
    const deck = "C arguments\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n";
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    var handle: ?*c.espice_problem = null;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&options, &handle, null, 0));
    defer _ = c.espice_destroy(handle);
    const invalid: u32 = c.ESPICE_INVALID_ARGUMENT;
    var n: usize = 0;
    var message: [64]u8 = undefined;

    try t.expectEqual(invalid, c.espice_query_count(handle, null));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_error_message(handle, &message, message.len, &n));
    try t.expectEqualStrings("InvalidArgument", std.mem.sliceTo(&message, 0));
    var result: c.espice_result_info = undefined;
    try t.expectEqual(@as(u32, c.ESPICE_RESULT_UNAVAILABLE), c.espice_get_result_info(handle, 0, &result));

    var ids = [_]u32{c.ESPICE_NO_QUERY};
    try t.expectEqual(invalid, c.espice_ready_queries(handle, .{ .kind = 3, .id = 0 }, &ids, ids.len, &n));
    try t.expectEqual(invalid, c.espice_ready_queries(handle, .{ .kind = c.ESPICE_COMPONENT, .id = 99 }, &ids, ids.len, &n));
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_ready_queries(handle, .{ .kind = c.ESPICE_QUERY, .id = c.ESPICE_NO_QUERY }, &ids, ids.len, &n));
    try t.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_ready_queries(handle, .{ .kind = c.ESPICE_ALL, .id = 0 }, null, 0, &n));
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(c.ESPICE_NO_QUERY, ids[0]);

    var event: c.espice_advance_event = undefined;
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_advance(handle, c.ESPICE_NO_QUERY, &event));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_advance_ready(handle, null, 0, 1, null, 0, &n));
    try t.expectEqual(@as(usize, 0), n);
    try t.expectEqual(invalid, c.espice_advance_ready(handle, null, 1, 1, &event, 1, &n));
    const zero = [_]u32{0};
    try t.expectEqual(invalid, c.espice_advance_ready(handle, &zero, 1, 65536, &event, 1, &n));

    try t.expectEqual(invalid, c.espice_append_directives(handle, .{ .data = null, .len = 3 }, null, 0, &n));
    // No analysis card: malformed input, named in the message.
    try t.expectEqual(invalid, c.espice_append_directives(handle, .{ .data = null, .len = 0 }, null, 0, &n));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_error_message(handle, &message, message.len, &n));
    try t.expectEqualStrings("InvalidAnalysisArguments", std.mem.sliceTo(&message, 0));

    var print = std.mem.zeroes(c.espice_print_options);
    var text: [4096]u8 = undefined;
    print.ascii = 2;
    try t.expectEqual(invalid, c.espice_print(handle, &print, &text, text.len, &n));
    print.ascii = 1;
    print.preview = 3;
    try t.expectEqual(invalid, c.espice_print(handle, &print, &text, text.len, &n));
    print.preview = c.ESPICE_PREVIEW_READY;
    print.ready_count = 1;
    try t.expectEqual(invalid, c.espice_print(handle, &print, &text, text.len, &n));
    print.preview = c.ESPICE_PREVIEW_ADVANCE;
    print.query = c.ESPICE_NO_QUERY;
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_print(handle, &print, &text, text.len, &n));
    print.preview = c.ESPICE_PREVIEW_RUN_ALL;
    print.scope.kind = 3;
    try t.expectEqual(invalid, c.espice_print(handle, &print, &text, text.len, &n));
    try t.expectEqual(invalid, c.espice_print(handle, null, null, 1, &n));
    try t.expectEqual(invalid, c.espice_print(handle, null, &text, text.len, null));

    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_run_all(handle));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_get_result_info(handle, 0, &result));
    try t.expectEqual(invalid, c.espice_copy_result_name(handle, 0, result.variable_count, &message, message.len, &n));
    try t.expectEqual(invalid, c.espice_copy_result(handle, 0, null, 1, &n));
    var nul = [_]u8{'x'};
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_query_error_message(handle, 0, &nul, nul.len, &n));
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(u8, 0), nul[0]);
    const sentinel = [_]f64{0};
    var view: [*c]const f64 = &sentinel;
    try t.expectEqual(invalid, c.espice_result_view(handle, 0, &view, null));
    try t.expect(view == null);
}

test "C set_params runs later queries at new .param values without a re-parse (#101)" {
    const t = std.testing;
    const deck = "C live\n.param rv=1k\nV1 in 0 1\nR1 in out {rv}\nR2 out 0 1k\n.op\n.end\n";
    const live = [_]c.espice_bytes{.{ .data = "rv", .len = 2 }};
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.live_params = &live;
    options.live_param_count = 1;
    var handle: ?*c.espice_problem = null;
    var diagnostic: [64]u8 = undefined;
    try t.expectEqual(@as(u32, 0), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    defer _ = c.espice_destroy(handle);
    try t.expectEqual(@as(u32, 0), c.espice_run_all(handle));
    const op = ".op";
    for ([_]f64{ 3e3, 9e3 }) |rv| {
        try t.expectEqual(@as(u32, 0), c.espice_set_params(handle, &live, &rv, 1));
        var id: u32 = c.ESPICE_NO_QUERY;
        var needed: usize = 0;
        try t.expectEqual(@as(u32, 0), c.espice_append_directives(handle, .{ .data = op, .len = op.len }, &id, 1, &needed));
        try t.expectEqual(@as(u32, 0), c.espice_run_all(handle));
        var values: [8]f64 = undefined;
        try t.expectEqual(@as(u32, 0), c.espice_copy_result(handle, id, &values, values.len, &needed));
        var name: [16]u8 = undefined;
        const out = for (0..needed) |k| {
            var len: usize = 0;
            try t.expectEqual(@as(u32, 0), c.espice_copy_result_name(handle, id, @intCast(k), &name, name.len, &len));
            if (std.mem.eql(u8, std.mem.sliceTo(&name, 0), "v(out)")) break values[k];
        } else return error.MissingColumn;
        try t.expectApproxEqRel(1e3 / (1e3 + rv), out, 1e-12);
    }
    const bad = std.math.nan(f64);
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_set_params(handle, &live, &bad, 1));
    const unknown = [_]c.espice_bytes{.{ .data = "nope", .len = 4 }};
    const one: f64 = 1;
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_set_params(handle, &unknown, &one, 1));
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_set_params(handle, null, null, 1));
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_set_params(null, null, null, 0));
}

/// A problem over netlist text; fails the test unless create returns OK.
fn createDeck(deck: []const u8) !*c.espice_problem {
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    var handle: ?*c.espice_problem = null;
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&options, &handle, null, 0));
    return handle.?;
}

// Red before #143: the old espice_destroy freed the handle, and every later
// call read the freed memory (an OK from stale bytes, or a crash) and a
// second destroy freed it twice. Status 8 did not exist, so no outcome of
// the old code could equal INVALID_HANDLE.
test "C calls on a destroyed handle, and a second destroy, return INVALID_HANDLE (#143)" {
    const t = std.testing;
    const stale_code: u32 = c.ESPICE_INVALID_HANDLE;
    const deck = "C stale\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n";
    const handle = try createDeck(deck);
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_destroy(handle));
    var u: u32 = 0;
    var n: usize = 0;
    var info: c.espice_query_info = undefined;
    var event: c.espice_advance_event = undefined;
    var result: c.espice_result_info = undefined;
    var view: [*c]const f64 = null;
    const all: c.espice_scope = .{ .kind = c.ESPICE_ALL, .id = 0 };
    const empty: c.espice_bytes = .{ .data = null, .len = 0 };
    try t.expectEqual(stale_code, c.espice_query_count(handle, &u));
    try t.expectEqual(stale_code, c.espice_get_query_info(handle, 0, &info));
    try t.expectEqual(stale_code, c.espice_ready_queries(handle, all, null, 0, &n));
    try t.expectEqual(stale_code, c.espice_advance(handle, 0, &event));
    try t.expectEqual(stale_code, c.espice_advance_ready(handle, null, 0, 1, null, 0, &n));
    try t.expectEqual(stale_code, c.espice_run_all(handle));
    try t.expectEqual(stale_code, c.espice_append_directives(handle, empty, null, 0, &n));
    try t.expectEqual(stale_code, c.espice_set_params(handle, null, null, 0));
    try t.expectEqual(stale_code, c.espice_get_result_info(handle, 0, &result));
    try t.expectEqual(stale_code, c.espice_copy_result(handle, 0, null, 0, &n));
    const dummy: f64 = 0;
    view = &dummy;
    n = 7;
    try t.expectEqual(stale_code, c.espice_result_view(handle, 0, &view, &n));
    try t.expect(view == null);
    try t.expectEqual(@as(usize, 0), n);
    try t.expectEqual(stale_code, c.espice_copy_result_name(handle, 0, 0, null, 0, &n));
    try t.expectEqual(stale_code, c.espice_print(handle, null, null, 0, &n));
    try t.expectEqual(stale_code, c.espice_error_message(handle, null, 0, &n));
    try t.expectEqual(stale_code, c.espice_query_error_message(handle, 0, null, 0, &n));
    try t.expectEqual(stale_code, c.espice_destroy(handle));
    // The next problem may take the same slot; the old token stays stale.
    const next = try createDeck(deck);
    defer _ = c.espice_destroy(next);
    try t.expect(next != handle);
    try t.expectEqual(stale_code, c.espice_query_count(handle, &u));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_query_count(next, &u));
    // Slot 0 is never handed out, so this value names no problem.
    const foreign: *c.espice_problem = @ptrFromInt(0x1000);
    try t.expectEqual(stale_code, c.espice_query_count(foreign, &u));
    try t.expectEqual(stale_code, c.espice_destroy(foreign));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_destroy(null));
}

// Each step's expected code comes from the model, not from the
// implementation: a live token answers OK, a destroyed one INVALID_HANDLE;
// a query is pending after append, complete after run_all, and unknown
// after advance (one quantum may or may not finish it, or its prerequisite).
test "C random create/append/advance/result/destroy sequences match a model of valid states" {
    const t = std.testing;
    const ok: u32 = c.ESPICE_OK;
    const deck = "C model\nV1 in 0 dc 1 ac 1\nR1 in out 1k\nC1 out 0 1u\n.op\n.end\n";
    const ac = ".ac dec 1 1 10\n";
    const State = enum { pending, complete, unknown };
    const Live = struct { token: *c.espice_problem, ids: [8]u32 = undefined, states: [8]State = undefined, n: u8 = 0 };
    for ([_]u64{ 1, 2, 3 }) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var live: [3]Live = undefined;
        var live_len: usize = 0;
        var stale: [64]*c.espice_problem = undefined;
        var stale_len: usize = 0;
        defer for (live[0..live_len]) |p| {
            _ = c.espice_destroy(p.token);
        };
        for (0..120) |_| {
            const step = random.uintLessThan(u8, 6);
            if (live_len == 0 or (step == 0 and live_len < live.len)) {
                const token = try createDeck(deck);
                for (stale[0..stale_len]) |old| try t.expect(token != old);
                live[live_len] = .{ .token = token };
                // The deck's .op is query 0.
                live[live_len].ids[0] = 0;
                live[live_len].states[0] = .pending;
                live[live_len].n = 1;
                live_len += 1;
                continue;
            }
            const p = &live[random.uintLessThan(usize, live_len)];
            const k = random.uintLessThan(u8, p.n);
            var n: usize = 0;
            switch (step) {
                0, 1 => if (p.n < p.ids.len) {
                    var id: u32 = c.ESPICE_NO_QUERY;
                    try t.expectEqual(ok, c.espice_append_directives(p.token, .{ .data = ac, .len = ac.len }, &id, 1, &n));
                    try t.expectEqual(@as(usize, 1), n);
                    for (p.ids[0..p.n]) |earlier| try t.expect(id != earlier);
                    p.ids[p.n] = id;
                    p.states[p.n] = .pending;
                    p.n += 1;
                },
                2 => {
                    var event: c.espice_advance_event = undefined;
                    try t.expectEqual(ok, c.espice_advance(p.token, p.ids[k], &event));
                    try t.expectEqual(p.ids[k], event.requested);
                    for (p.states[0..p.n]) |*s| if (s.* == .pending) {
                        s.* = .unknown;
                    };
                },
                3 => {
                    try t.expectEqual(ok, c.espice_run_all(p.token));
                    @memset(p.states[0..p.n], .complete);
                },
                4 => {
                    var result: c.espice_result_info = undefined;
                    const code = c.espice_get_result_info(p.token, p.ids[k], &result);
                    switch (p.states[k]) {
                        .pending => try t.expectEqual(@as(u32, c.ESPICE_RESULT_UNAVAILABLE), code),
                        .complete => try t.expectEqual(ok, code),
                        .unknown => try t.expect(code == ok or code == @as(u32, c.ESPICE_RESULT_UNAVAILABLE)),
                    }
                },
                5 => {
                    try t.expectEqual(ok, c.espice_destroy(p.token));
                    if (stale_len < stale.len) {
                        stale[stale_len] = p.token;
                        stale_len += 1;
                    }
                    p.* = live[live_len - 1];
                    live_len -= 1;
                },
                else => unreachable, // else: uintLessThan(u8, 6)
            }
            // Every destroyed token stays stale, whatever reused its slot.
            if (stale_len > 0) {
                var u: u32 = 0;
                const old = stale[random.uintLessThan(usize, stale_len)];
                try t.expectEqual(@as(u32, c.ESPICE_INVALID_HANDLE), c.espice_query_count(old, &u));
                try t.expectEqual(@as(u32, c.ESPICE_INVALID_HANDLE), c.espice_destroy(old));
            }
        }
    }
}

/// v(out) of `deck`'s operating point, through one handle's whole life.
fn dividerOut(handle: *c.espice_problem) !f64 {
    if (c.espice_run_all(handle) != c.ESPICE_OK) return error.RunFailed;
    var values: [8]f64 = undefined;
    var n: usize = 0;
    if (c.espice_copy_result(handle, 0, &values, values.len, &n) != c.ESPICE_OK) return error.CopyFailed;
    var name: [16]u8 = undefined;
    for (0..n) |k| {
        var len: usize = 0;
        if (c.espice_copy_result_name(handle, 0, @intCast(k), &name, name.len, &len) != c.ESPICE_OK) return error.NameFailed;
        if (std.mem.eql(u8, std.mem.sliceTo(&name, 0), "v(out)")) return values[k];
    }
    return error.MissingColumn;
}

/// A divider of R1 = `r1` ohm over 1k, as a deck in `buf`.
fn dividerDeck(buf: []u8, r1: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "C threads\nV1 in 0 1\nR1 in out {d}\nR2 out 0 1k\n.op\n.end\n", .{r1});
}

// Independent handles from several threads at once (include/espice.h:
// "calls on them may run concurrently from any threads"), the handle table
// churning under them. Oracle: every call OK, every divider at its closed
// form, every destroyed token INVALID_HANDLE however its slot was reused.
test "C handles on different threads run concurrently and stay independent" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const Worker = struct {
        fn run(r1: u32, failures: *std.atomic.Value(u32)) void {
            body(r1) catch {
                _ = failures.fetchAdd(1, .monotonic);
            };
        }
        fn body(r1: u32) !void {
            var buf: [128]u8 = undefined;
            for (0..4) |_| {
                const handle = try createDeck(try dividerDeck(&buf, r1));
                const got = try dividerOut(handle);
                if (@abs(got - 1e3 / (1e3 + @as(f64, @floatFromInt(r1)))) > 1e-12) return error.WrongValue;
                if (c.espice_destroy(handle) != c.ESPICE_OK) return error.DestroyFailed;
                var u: u32 = 0;
                if (c.espice_query_count(handle, &u) != c.ESPICE_INVALID_HANDLE) return error.StaleHandleAnswered;
                if (c.espice_destroy(handle) != c.ESPICE_INVALID_HANDLE) return error.DoubleDestroyAccepted;
            }
        }
    };
    var failures: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ @as(u32, @intCast(1000 * (i + 1))), &failures });
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
}

// One handle, its calls serialized by join, made from three threads: the
// handle carries no thread affinity.
test "C a handle created on one thread runs on another and is destroyed on a third" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    const handle = try createDeck(try dividerDeck(&buf, 3000));
    var got: anyerror!f64 = error.NotRun;
    const Run = struct {
        fn run(h: *c.espice_problem, out: *anyerror!f64) void {
            out.* = dividerOut(h);
        }
        fn destroy(h: *c.espice_problem, out: *u32) void {
            out.* = c.espice_destroy(h);
        }
    };
    (try std.Thread.spawn(.{}, Run.run, .{ handle, &got })).join();
    try std.testing.expectApproxEqRel(@as(f64, 0.25), try got, 1e-12);
    var destroyed: u32 = 99;
    (try std.Thread.spawn(.{}, Run.destroy, .{ handle, &destroyed })).join();
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), destroyed);
    var u: u32 = 0;
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_HANDLE), c.espice_query_count(handle, &u));
}

test "C points: early stop and measures_only keep each point's values, abort_after fails only the slow one" {
    const t = std.testing;
    const deck = "C points\n.param rv=1k\nV1 in 0 pulse(0 1 0.1n 0.1n 0.1n 20n 40n)\nR1 in out {rv}\nC1 out 0 0.1p\n.tran 1p 10n\n" ++
        ".meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1\n.end\n";
    const live = [_]c.espice_bytes{.{ .data = "rv", .len = 2 }};
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.live_params = &live;
    options.live_param_count = 1;
    var handle: ?*c.espice_problem = null;
    try t.expectEqual(@as(u32, 0), c.espice_create(&options, &handle, null, 0));
    defer _ = c.espice_destroy(handle);
    const rows = [_]f64{ 1e3, 100e3, 2e3 };
    var plain: u32 = 0;
    try t.expectEqual(@as(u32, 0), c.espice_append_points(handle, &rows, rows.len, null, &plain));
    var bounded_options = pointsOptions();
    bounded_options.measures_only = 1;
    bounded_options.early_stop = 1;
    bounded_options.abort_after = 1e-9;
    var bounded: u32 = 0;
    try t.expectEqual(@as(u32, 0), c.espice_append_points(handle, &rows, rows.len, &bounded_options, &bounded));
    _ = c.espice_run_all(handle);
    const names = [_]c.espice_bytes{.{ .data = "tpd", .len = 3 }};
    var want: [3]f64 = undefined;
    var want_why: [3]u32 = undefined;
    try t.expectEqual(@as(u32, 0), c.espice_copy_point_measures(handle, plain, 3, &names, 1, &want, &want_why));
    var got: [3]f64 = undefined;
    var why: [3]u32 = undefined;
    try t.expectEqual(@as(u32, 0), c.espice_copy_point_measures(handle, bounded, 3, &names, 1, &got, &why));
    try t.expectEqualSlices(u32, &.{ c.ESPICE_REASON_OK, c.ESPICE_REASON_OK, c.ESPICE_REASON_OK }, &want_why);
    try t.expectEqualSlices(u32, &.{ c.ESPICE_REASON_OK, c.ESPICE_REASON_ABORTED, c.ESPICE_REASON_OK }, &why);
    try t.expect(std.math.isNan(got[1]));
    try t.expectEqual(@as(u64, @bitCast(want[0])), @as(u64, @bitCast(got[0])));
    try t.expectEqual(@as(u64, @bitCast(want[2])), @as(u64, @bitCast(got[2])));
}

test "C points: copy_point_tangents gives d(measure)/d(live parameter), and NaN without tangent_step" {
    const t = std.testing;
    const deck = "C tangents\n.param rv=1k\nV1 in 0 pulse(0 1 0.1n 0.1n 0.1n 20n 40n)\nR1 in out {rv}\nC1 out 0 0.1p\n.tran 1p 2n\n" ++
        ".meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1\n.end\n";
    const live = [_]c.espice_bytes{.{ .data = "rv", .len = 2 }};
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.live_params = &live;
    options.live_param_count = 1;
    var handle: ?*c.espice_problem = null;
    try t.expectEqual(@as(u32, 0), c.espice_create(&options, &handle, null, 0));
    defer _ = c.espice_destroy(handle);
    const rows = [_]f64{ 1e3, 2e3 };
    var points = pointsOptions();
    points.tangent_step = 1e-6;
    var first: u32 = 0;
    try t.expectEqual(@as(u32, 0), c.espice_append_points(handle, &rows, rows.len, &points, &first));
    var plain: u32 = 0;
    try t.expectEqual(@as(u32, 0), c.espice_append_points(handle, &rows, 1, null, &plain));
    try t.expectEqual(@as(u32, 0), c.espice_run_all(handle));
    const names = [_]c.espice_bytes{.{ .data = "tpd", .len = 3 }};
    var slopes: [2]f64 = undefined;
    try t.expectEqual(@as(u32, 0), c.espice_copy_point_tangents(handle, first, 2, &names, 1, &slopes));
    // tpd is near RC ln 2 (the 0.1 ns ramp shortens it): about 0.1p ln 2 per ohm.
    for (slopes) |s| try t.expectApproxEqRel(0.1e-12 * @log(2.0), s, 0.15);
    var none: [1]f64 = undefined;
    try t.expectEqual(@as(u32, 0), c.espice_copy_point_tangents(handle, plain, 1, &names, 1, &none));
    try t.expect(std.math.isNan(none[0]));
    // An options struct from before tangent_step still reads.
    points.struct_size = @offsetOf(c.espice_points_options, "tangent_step");
    try t.expectEqual(@as(u32, 0), c.espice_append_points(handle, &rows, 1, &points, &plain));
}

// Points API (include/espice.h, design doc dev/research/lane-batched-simulation.md
// §10 and the §11 phase 0 gate).

/// An RC step response: v(in) ramps to 1 V in 10 ps through r1 = rv into
/// c1 = cv; vdd holds 1 V across rl. tpd is RC ln 2 shifted by the ramp,
/// e the energy vin delivers (about cv · 1 V²), leak vdd's current (-1 mA).
/// Bare parameter names, which both dialects read.
const rc_deck =
    \\points rc
    \\.param rv=1k cv=1p
    \\vdd vdd 0 1
    \\rl vdd 0 1k
    \\vin in 0 pwl(0 0 10p 1)
    \\r1 in out rv
    \\c1 out 0 cv
    \\.tran 10p 40n
    \\.meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1
    \\.meas tran e integ par('-v(in)*i(vin)') from=0 to=40n
    \\.meas op leak find i(vdd)
    \\.end
    \\
;
const rc_live = [_]c.espice_bytes{ .{ .data = "rv", .len = 2 }, .{ .data = "cv", .len = 2 } };
const rc_names = [_]c.espice_bytes{ .{ .data = "tpd", .len = 3 }, .{ .data = "E", .len = 1 }, .{ .data = "leak", .len = 4 } };

/// The 16 (rv, cv) points of the gate: a 4 x 4 grid.
fn rcGrid() [16][2]f64 {
    var rows: [16][2]f64 = undefined;
    for (&rows, 0..) |*row, k| row.* = .{ 1e3 * @as(f64, @floatFromInt(k / 4 + 1)), 0.25e-12 * @as(f64, @floatFromInt(k % 4 + 1)) };
    return rows;
}

/// A problem over `deck` with `live` declared live.
fn createLive(deck: []const u8, live: []const c.espice_bytes) !*c.espice_problem {
    return createDialect(deck, live, c.ESPICE_NGSPICE);
}

fn createDialect(deck: []const u8, live: []const c.espice_bytes, dialect: u32) !*c.espice_problem {
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.dialect = dialect;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.live_params = live.ptr;
    options.live_param_count = live.len;
    options.max_parallel = 4;
    var handle: ?*c.espice_problem = null;
    var diagnostic: [64]u8 = @splat(0);
    std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&options, &handle, &diagnostic, diagnostic.len)) catch |err| {
        std.debug.print("create: {s}\n", .{std.mem.sliceTo(&diagnostic, 0)});
        return err;
    };
    return handle.?;
}

/// Appends `rows` as points, runs them, and copies `names` of each into
/// `out` and its reason into `reasons`.
fn runPoints(h: *c.espice_problem, rows: []const f64, count: usize, names: []const c.espice_bytes, out: []f64, reasons: []u32) !void {
    var first: u32 = c.ESPICE_NO_QUERY;
    errdefer printError(h);
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_append_points(h, rows.ptr, count, null, &first));
    _ = c.espice_run_all(h);
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_copy_point_measures(h, first, count, names.ptr, names.len, out.ptr, reasons.ptr));
}

fn printError(h: *c.espice_problem) void {
    var buf: [64]u8 = @splat(0);
    var needed: usize = 0;
    _ = c.espice_error_message(h, &buf, buf.len, &needed);
    std.debug.print("espice_error_message: {s}\n", .{std.mem.sliceTo(&buf, 0)});
}

fn expectSameBits(want: []const f64, got: []const f64) !void {
    try std.testing.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
}

test "C points: 16 points measure tpd, energy and leakage analytically, and match the .data sweep bit for bit" {
    const t = std.testing;
    const grid = rcGrid();
    const rows: []const f64 = @ptrCast(&grid);
    // HSPICE, the dialect of the .data deck below.
    const h = try createDialect(rc_deck, &rc_live, c.ESPICE_HSPICE);
    defer _ = c.espice_destroy(h);
    var lane: u32 = 0;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_lane_width(h, &lane));
    try t.expectEqual(@as(u32, 1), lane);
    var got: [16 * 3]f64 = undefined;
    var reasons: [16]u32 = undefined;
    try runPoints(h, rows, 16, &rc_names, &got, &reasons);
    for (grid, 0..) |p, k| {
        try t.expectEqual(@as(u32, c.ESPICE_REASON_OK), reasons[k]);
        // After a ramp of T, v(out) = 1 - (RC/T)(e^(T/RC) - 1) e^(-t/RC).
        const rc = p[0] * p[1];
        const ramp: f64 = 10e-12;
        const tpd = rc * @log(2 * rc / ramp * (@exp(ramp / rc) - 1)) - ramp / 2;
        try t.expectApproxEqRel(tpd, got[k * 3], 1e-3);
        // The source charges c1 through the ramp, then steps the rest.
        const a = 1 / ramp;
        const v_end = a * (ramp - rc * (1 - @exp(-ramp / rc)));
        const energy = p[1] * (a * a * (ramp * ramp / 2 - rc * rc + rc * (ramp + rc) * @exp(-ramp / rc)) + 1 - v_end);
        try t.expectApproxEqRel(energy, got[k * 3 + 1], 1e-3);
        try t.expectApproxEqRel(-1e-3, got[k * 3 + 2], 1e-9);
    }

    // The same deck sweeping the same rows through .data.
    var swept: std.ArrayList(u8) = .empty;
    defer swept.deinit(t.allocator);
    try swept.appendSlice(t.allocator, rc_deck[0..std.mem.indexOf(u8, rc_deck, ".tran").?]);
    try swept.appendSlice(t.allocator, ".data pts rv cv\n");
    for (grid) |p| try swept.print(t.allocator, "+ {e} {e}\n", .{ p[0], p[1] });
    try swept.appendSlice(t.allocator, ".enddata\n.tran 10p 40n sweep data=pts\n");
    try swept.appendSlice(t.allocator, rc_deck[std.mem.indexOf(u8, rc_deck, ".meas").?..]);
    const handle = try createDialect(swept.items, &.{}, c.ESPICE_HSPICE);
    defer _ = c.espice_destroy(handle);
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_run_all(handle));
    const first = try firstRequested(handle);
    var data: [16 * 3]f64 = undefined;
    var data_reasons: [16]u32 = undefined;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_copy_point_measures(handle, first, 16, &rc_names, 3, &data, &data_reasons));
    try t.expectEqualSlices(u32, &reasons, &data_reasons);
    try expectSameBits(&got, &data);
}

/// A swept deck's points start at its first requested query.
fn firstRequested(h: *c.espice_problem) !u32 {
    var count: u32 = 0;
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_query_count(h, &count));
    return for (0..count) |id| {
        var info: c.espice_query_info = undefined;
        try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_get_query_info(h, @intCast(id), &info));
        if (info.requested == 1) break @as(u32, @intCast(id));
    } else error.NoRequestedQuery;
}
test "C points: the per-lane stimulus rows (#212) equal their .data sweep bit for bit" {
    const t = std.testing;
    const source = try std.Io.Dir.cwd().readFileAlloc(t.io, "tests/fixtures/variants/data_lane_stimulus.sp", t.allocator, .unlimited);
    defer t.allocator.free(source);
    const names = [_]c.espice_bytes{ .{ .data = "tpd", .len = 3 }, .{ .data = "tpd2", .len = 4 }, .{ .data = "slew", .len = 4 } };
    var data: [4 * 3]f64 = undefined;
    var data_reasons: [4]u32 = undefined;
    {
        const h = try createDialect(source, &.{}, c.ESPICE_HSPICE);
        defer _ = c.espice_destroy(h);
        try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_run_all(h));
        try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_copy_point_measures(h, try firstRequested(h), 4, &names, 3, &data, &data_reasons));
    }
    // The deck without its .data table, sel and pol live.
    const start = std.mem.indexOf(u8, source, "\n.data ").? + 1;
    const end = std.mem.indexOf(u8, source, ".enddata\n").? + ".enddata\n".len;
    const spliced = try std.mem.concat(t.allocator, u8, &.{ source[0..start], source[end..] });
    defer t.allocator.free(spliced);
    const template = try std.mem.replaceOwned(u8, t.allocator, spliced, " sweep data=lanes", "");
    defer t.allocator.free(template);
    const h = try createDialect(template, &.{ .{ .data = "sel", .len = 3 }, .{ .data = "pol", .len = 3 } }, c.ESPICE_HSPICE);
    defer _ = c.espice_destroy(h);
    const rows = [_]f64{ 0, 1, 0, 0, 1, 1, 1, 0 };
    var got: [4 * 3]f64 = undefined;
    var reasons: [4]u32 = undefined;
    try runPoints(h, &rows, 4, &names, &got, &reasons);
    for (reasons) |r| try t.expectEqual(@as(u32, c.ESPICE_REASON_OK), r);
    try t.expectEqualSlices(u32, &reasons, &data_reasons);
    try expectSameBits(&data, &got);
}

test "C points: rows do not depend on order, batching or the other points" {
    const grid = rcGrid();
    var want: [16 * 3]f64 = undefined;
    var reasons: [16]u32 = undefined;
    {
        const h = try createLive(rc_deck, &rc_live);
        defer _ = c.espice_destroy(h);
        try runPoints(h, @ptrCast(&grid), 16, &rc_names, &want, &reasons);
    }
    // Shuffled: a fixed permutation.
    var order: [16]usize = undefined;
    for (&order, 0..) |*o, k| o.* = (k * 7 + 3) % 16;
    var shuffled: [16][2]f64 = undefined;
    for (order, 0..) |o, k| shuffled[k] = grid[o];
    var got: [16 * 3]f64 = undefined;
    {
        const h = try createLive(rc_deck, &rc_live);
        defer _ = c.espice_destroy(h);
        try runPoints(h, @ptrCast(&shuffled), 16, &rc_names, &got, &reasons);
    }
    for (order, 0..) |o, k| try expectSameBits(want[o * 3 ..][0..3], got[k * 3 ..][0..3]);
    // Appended in calls of 5, 1 and 10 to one problem, running between.
    {
        const h = try createLive(rc_deck, &rc_live);
        defer _ = c.espice_destroy(h);
        var at: usize = 0;
        for ([_]usize{ 5, 1, 10 }) |n| {
            try runPoints(h, @ptrCast(grid[at..][0..n]), n, &rc_names, got[at * 3 ..][0 .. n * 3], reasons[at..][0..n]);
            at += n;
        }
        try expectSameBits(&want, &got);
    }
    // Each point alone on its own problem.
    for (grid, 0..) |p, k| {
        const h = try createLive(rc_deck, &rc_live);
        defer _ = c.espice_destroy(h);
        try runPoints(h, &p, 1, &rc_names, got[k * 3 ..][0..3], reasons[k..][0..1]);
        try expectSameBits(want[k * 3 ..][0..3], got[k * 3 ..][0..3]);
    }
}

/// A deck whose `bad` point fails with `reason` (a measure-level reason
/// when `card` names the one measure it leaves NaN; null for a failed
/// point, all NaN), while `good` runs.
const ReasonCase = struct {
    deck: []const u8,
    live: []const []const u8,
    names: []const []const u8,
    good: []const f64,
    bad: []const f64,
    reason: u32,
    card: ?usize = null,
};

const reason_cases = [_]ReasonCase{
    // A non-finite value.
    .{ .deck = rc_deck, .live = &.{ "rv", "cv" }, .names = &.{ "tpd", "e", "leak" }, .good = &.{ 1e3, 1e-12 }, .bad = &.{ std.math.nan(f64), 1e-12 }, .reason = c.ESPICE_REASON_INVALID_PARAMETER },
    .{ .deck = rc_deck, .live = &.{ "rv", "cv" }, .names = &.{ "tpd", "e", "leak" }, .good = &.{ 1e3, 1e-12 }, .bad = &.{ 1e3, std.math.inf(f64) }, .reason = c.ESPICE_REASON_INVALID_PARAMETER },
    // RC = 1 us: v(out) never reaches 0.5 V in 40 ns; e and leak still resolve.
    .{ .deck = rc_deck, .live = &.{ "rv", "cv" }, .names = &.{ "tpd", "e", "leak" }, .good = &.{ 1e3, 1e-12 }, .bad = &.{ 1e6, 1e-12 }, .reason = c.ESPICE_REASON_MEASURE_UNRESOLVED, .card = 0 },
    // A top-level .if flips with sel.
    .{
        .deck = "if flip\n.param sel=0 rv=1k\nv1 in 0 1\nr1 in out {rv}\n.if (sel == 0)\nr2 out 0 1k\n.else\nr2 out 0 3k\nr3 out 0 3k\n.endif\n.op\n.meas op vo find v(out)\n.end\n",
        .live = &.{ "sel", "rv" },
        .names = &.{"vo"},
        .good = &.{ 0, 2e3 },
        .bad = &.{ 1, 2e3 },
        .reason = c.ESPICE_REASON_TOPOLOGY_CHANGED,
    },
    // No bin holds W = 5u.
    .{
        .deck = "bins\n.param wn=1u\nv1 d 0 1\nv2 g 0 2\nm1 d g 0 0 nm l=1u w={wn}\n" ++
            ".model nm.1 nmos level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u vto=0.5\n" ++
            ".model nm.2 nmos level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u vto=1.7\n.op\n.meas op id find i(v1)\n.end\n",
        .live = &.{"wn"},
        .names = &.{"id"},
        .good = &.{2e-6},
        .bad = &.{5e-6},
        .reason = c.ESPICE_REASON_MODEL_BIN_NOT_FOUND,
    },
    // v/rb = 1 + v^2 has a root only for rb <= 0.5.
    .{
        .deck = "no root\n.param rb=0.1\nb1 0 n i=1+v(n)*v(n)\nr1 n 0 {rb}\n.op\n.meas op vn find v(n)\n.end\n",
        .live = &.{"rb"},
        .names = &.{"vn"},
        .good = &.{0.1},
        .bad = &.{1e3},
        .reason = c.ESPICE_REASON_NO_CONVERGENCE,
    },
    // The same once time passes 1 ns at k = 1e9: the transient loses its root.
    .{
        .deck = "lost root\n.param k=0\nb1 0 n i=time*k+v(n)*v(n)\nr1 n 0 1k\n.tran 10p 2n\n.meas tran vn find v(n) at=0.5n\n.end\n",
        .live = &.{"k"},
        .names = &.{"vn"},
        .good = &.{0},
        .bad = &.{1e9},
        .reason = c.ESPICE_REASON_TIMESTEP_TOO_SMALL,
    },
    // v(b) = g v(a) and v(a) = v(b) leave both undetermined at g = 1; the
    // AC matrix is singular (the operating point still solves).
    .{
        .deck = "singular\n.param g=0.5\nv1 in 0 1 ac 1\nr1 in 0 1k\ne1 b 0 a 0 {g}\ne2 a 0 b 0 1\nr2 a in 1k\nr3 b 0 1k\n.ac lin 3 500 2k\n.meas ac vb find vm(b) at=1k\n.end\n",
        .live = &.{"g"},
        .names = &.{"vb"},
        .good = &.{0.5},
        .bad = &.{1},
        .reason = c.ESPICE_REASON_SINGULAR_MATRIX,
    },
    // The txl Padé fit fails and the model $fatal's.
    .{
        .deck = "refused fit\n.param lv=1u cl=1p\nv1 a 0 dc 1\nr1 b 0 50\ny1 a 0 b 0 line\n.model line txl r=1 l={lv} g=0 c={cl} length=1\n.op\n.meas op vb find v(b)\n.end\n",
        .live = &.{ "lv", "cl" },
        .names = &.{"vb"},
        .good = &.{ 1e-6, 1e-12 },
        .bad = &.{ 1e200, 1e-200 },
        .reason = c.ESPICE_REASON_DEVICE_REFUSED,
    },
    // A lossless txl (r = 0) has no fit: UnsupportedTransmissionLineParameters.
    .{
        .deck = "lossless\n.param rv=1\nv1 a 0 dc 1\nr1 b 0 50\ny1 a 0 b 0 line\n.model line txl r={rv} l=1n g=0 c=1p length=1\n.op\n.meas op vb find v(b)\n.end\n",
        .live = &.{"rv"},
        .names = &.{"vb"},
        .good = &.{1},
        .bad = &.{0},
        .reason = c.ESPICE_REASON_OTHER,
    },
};

fn bytes(names: []const []const u8, out: []c.espice_bytes) []const c.espice_bytes {
    for (names, out[0..names.len]) |n, *b| b.* = .{ .data = n.ptr, .len = n.len };
    return out[0..names.len];
}

test "C points: each reason from a deck built for it; NaN where it fails, the other points untouched" {
    const t = std.testing;
    for (reason_cases, 0..) |case, n| {
        errdefer std.debug.print("reason case {d}: {s}\n", .{ n, case.deck });
        var live_buf: [4]c.espice_bytes = undefined;
        var name_buf: [4]c.espice_bytes = undefined;
        const live = bytes(case.live, &live_buf);
        const names = bytes(case.names, &name_buf);
        const p = live.len;
        const m = names.len;
        // good, bad, good on one problem; good alone on another.
        var rows: [12]f64 = undefined;
        @memcpy(rows[0..p], case.good);
        @memcpy(rows[p..][0..p], case.bad);
        @memcpy(rows[2 * p ..][0..p], case.good);
        var got: [12]f64 = undefined;
        var reasons: [3]u32 = undefined;
        const h = try createLive(case.deck, live);
        defer _ = c.espice_destroy(h);
        try runPoints(h, &rows, 3, names, got[0 .. 3 * m], &reasons);
        try t.expectEqual(@as(u32, c.ESPICE_REASON_OK), reasons[0]);
        try t.expectEqual(case.reason, reasons[1]);
        try t.expectEqual(@as(u32, c.ESPICE_REASON_OK), reasons[2]);
        for (got[m..][0..m], 0..) |v, k| {
            const nan = case.card == null or case.card == k;
            try t.expectEqual(nan, std.math.isNan(v));
        }
        var alone: [4]f64 = undefined;
        var alone_reason: [1]u32 = undefined;
        const g = try createLive(case.deck, live);
        defer _ = c.espice_destroy(g);
        try runPoints(g, case.good, 1, names, alone[0..m], &alone_reason);
        try expectSameBits(alone[0..m], got[0..m]);
        try expectSameBits(alone[0..m], got[2 * m ..][0..m]);
        for (alone[0..m]) |v| try t.expect(std.math.isFinite(v));
    }
}

test "C points: a measure over a missing vector or analysis is MEASURE_NOT_FOUND at every point" {
    const t = std.testing;
    const deck = "no ac\n.param rv=1k\nv1 in 0 dc 1 ac 1\nr1 in out {rv}\nr2 out 0 1k\n.op\n.meas op vo find v(out)\n" ++
        ".meas ac g find vm(out) at=1k\n.meas op none find v(nowhere)\n.end\n";
    const h = try createLive(deck, rc_live[0..1]);
    defer _ = c.espice_destroy(h);
    for ([_][]const u8{ "g", "none" }) |missing| {
        const names = [_]c.espice_bytes{ .{ .data = "vo", .len = 2 }, .{ .data = missing.ptr, .len = missing.len } };
        var out: [4]f64 = undefined;
        var reasons: [2]u32 = undefined;
        try runPoints(h, &.{ 1e3, 3e3 }, 2, &names, &out, &reasons);
        try t.expectEqualSlices(u32, &.{ c.ESPICE_REASON_MEASURE_NOT_FOUND, c.ESPICE_REASON_MEASURE_NOT_FOUND }, &reasons);
        try t.expectApproxEqRel(0.5, out[0], 1e-12);
        try t.expectApproxEqRel(0.25, out[2], 1e-12);
        try t.expect(std.math.isNan(out[1]) and std.math.isNan(out[3]));
    }
}

test "C points: a failed point's queries report their error" {
    const t = std.testing;
    const h = try createLive(rc_deck, &rc_live);
    defer _ = c.espice_destroy(h);
    const rows = [_]f64{ std.math.nan(f64), 1e-12 };
    var first: u32 = 0;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_append_points(h, &rows, 1, null, &first));
    var info: c.espice_query_info = undefined;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_get_query_info(h, first, &info));
    try t.expectEqual(@as(u32, c.ESPICE_QUERY_FAILED), info.status);
    var name: [64]u8 = undefined;
    var needed: usize = 0;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_query_error_message(h, first, &name, name.len, &needed));
    try t.expectEqualStrings("NonFiniteParameter", std.mem.sliceTo(&name, 0));
}

test "C points: argument errors change nothing" {
    const t = std.testing;
    const invalid: u32 = c.ESPICE_INVALID_ARGUMENT;
    const h = try createLive(rc_deck, &rc_live);
    defer _ = c.espice_destroy(h);
    var before: u32 = 0;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_query_count(h, &before));
    const row = [_]f64{ 1e3, 1e-12 };
    var first: u32 = 77;
    try t.expectEqual(invalid, c.espice_append_points(h, &row, 0, null, &first));
    try t.expectEqual(invalid, c.espice_append_points(h, null, 1, null, &first));
    try t.expectEqual(invalid, c.espice_append_points(h, &row, 1, null, null));
    var o = pointsOptions();
    for (0..7) |case| {
        var bad = o;
        switch (case) {
            0 => bad.measures_only = 2,
            1 => bad.early_stop = 2,
            2 => bad.warm_start = 2,
            3 => bad.abort_after = -1,
            4 => bad.abort_measure = .{ .data = "nope", .len = 4 },
            5 => bad.abort_after = std.math.inf(f64),
            6 => bad.tangent_step = -1,
            else => unreachable,
        }
        try t.expectEqual(invalid, c.espice_append_points(h, &row, 1, &bad, &first));
    }
    var short = o;
    short.struct_size = @offsetOf(c.espice_points_options, "abort_after");
    try t.expectEqual(@as(u32, c.ESPICE_ABI_MISMATCH), c.espice_append_points(h, &row, 1, &short, &first));
    try t.expectEqual(@as(u32, 77), first);
    var after: u32 = 0;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_query_count(h, &after));
    try t.expectEqual(before, after);
    // Valid options, every flag set, are accepted.
    o.measures_only = 1;
    o.early_stop = 1;
    o.warm_start = 1;
    o.abort_after = 1;
    o.abort_measure = .{ .data = "TPD", .len = 3 };
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_append_points(h, &row, 1, &o, &first));

    // Unfinished queries, an unknown measure, a bad first_id.
    var out: [3]f64 = @splat(-1);
    var reasons: [1]u32 = .{99};
    try t.expectEqual(@as(u32, c.ESPICE_RESULT_UNAVAILABLE), c.espice_copy_point_measures(h, first, 1, &rc_names, 3, &out, &reasons));
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_run_all(h));
    const unknown = [_]c.espice_bytes{.{ .data = "nope", .len = 4 }};
    try t.expectEqual(invalid, c.espice_copy_point_measures(h, first, 1, &unknown, 1, &out, &reasons));
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_copy_point_measures(h, first, 2, &rc_names, 3, &out, &reasons));
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_copy_point_measures(h, c.ESPICE_NO_QUERY, 1, &rc_names, 3, &out, &reasons));
    try t.expectEqual(@as(u32, c.ESPICE_INVALID_QUERY), c.espice_copy_point_measures(h, after + 1000, 1, &rc_names, 3, &out, &reasons));
    try t.expectEqual(invalid, c.espice_copy_point_measures(h, first, 1, null, 3, &out, &reasons));
    try t.expectEqual(invalid, c.espice_copy_point_measures(h, first, 1, &rc_names, 3, null, &reasons));
    try t.expectEqual(invalid, c.espice_copy_point_measures(h, first, 1, &rc_names, 3, &out, null));
    try t.expectEqualSlices(f64, &.{ -1, -1, -1 }, &out);
    try t.expectEqual(@as(u32, 99), reasons[0]);
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_copy_point_measures(h, first, 1, &rc_names, 3, &out, &reasons));
    try t.expectEqual(@as(u32, c.ESPICE_REASON_OK), reasons[0]);
    try t.expectEqual(invalid, c.espice_lane_width(h, null));

    // No live parameters; a template that sweeps already.
    const plain = try createLive(rc_deck, &.{});
    defer _ = c.espice_destroy(plain);
    try t.expectEqual(invalid, c.espice_append_points(plain, null, 1, null, &first));
    try expectDiagnostic(plain, "NoLiveParameters");
    const stepped = try createLive("stepped\n.param rv=1k cv=1p\nv1 in 0 1\nr1 in out {rv}\nc1 out 0 {cv}\n.step param cv list 1p 2p\n.op\n.end\n", rc_live[0..1]);
    defer _ = c.espice_destroy(stepped);
    try t.expectEqual(invalid, c.espice_append_points(stepped, &row, 1, null, &first));
    try expectDiagnostic(stepped, "SweptTemplate");
}

fn expectDiagnostic(h: *c.espice_problem, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    var needed: usize = 0;
    try std.testing.expectEqual(@as(u32, c.ESPICE_OK), c.espice_error_message(h, &buf, buf.len, &needed));
    try std.testing.expectEqualStrings(want, std.mem.sliceTo(&buf, 0));
}

/// Resident set size of this process, bytes (Linux /proc/self/statm).
fn residentBytes() !usize {
    var buf: [128]u8 = undefined;
    const text = try std.Io.Dir.cwd().readFile(std.testing.io, "/proc/self/statm", &buf);
    var fields = std.mem.tokenizeScalar(u8, text, ' ');
    _ = fields.next();
    return try std.fmt.parseInt(usize, fields.next().?, 10) * std.heap.pageSize();
}

test "C points: 100 batches of 100 on one handle, released as they are read, keep run_all time and RSS flat" {
    const t = std.testing;
    const deck = "C batches\n.param rv=1k\nV1 in 0 pulse(0 1 0.1n 0.1n 0.1n 20n 40n)\nR1 in out {rv}\nC1 out 0 0.1p\n.tran 1p 2n\n" ++
        ".meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1\n.end\n";
    const live = [_]c.espice_bytes{.{ .data = "rv", .len = 2 }};
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.live_params = &live;
    options.live_param_count = 1;
    options.max_parallel = 4;
    var handle: ?*c.espice_problem = null;
    try t.expectEqual(@as(u32, 0), c.espice_create(&options, &handle, null, 0));
    defer _ = c.espice_destroy(handle);
    var points = pointsOptions();
    points.measures_only = 1;
    points.early_stop = 1;
    const names = [_]c.espice_bytes{.{ .data = "tpd", .len = 3 }};
    const batches = 100;
    const n = 100;
    var ns: [batches]u64 = undefined;
    var rss: [batches]usize = undefined;
    var rows: [n]f64 = undefined;
    var first_ids: [batches]u32 = undefined;
    for (0..batches) |b| {
        // The same work every batch: only the handle's history grows.
        for (&rows, 0..) |*r, k| r.* = 1e3 * (1 + 0.01 * @as(f64, @floatFromInt(k)));
        try t.expectEqual(@as(u32, 0), c.espice_append_points(handle, &rows, n, &points, &first_ids[b]));
        const start = std.Io.Timestamp.now(t.io, .awake);
        try t.expectEqual(@as(u32, 0), c.espice_run_all(handle));
        ns[b] = @intCast(start.durationTo(std.Io.Timestamp.now(t.io, .awake)).nanoseconds);
        var values: [n]f64 = undefined;
        var why: [n]u32 = undefined;
        try t.expectEqual(@as(u32, 0), c.espice_copy_point_measures(handle, first_ids[b], n, &names, 1, &values, &why));
        for (values, why) |v, w| {
            try t.expect(std.math.isFinite(v));
            try t.expectEqual(@as(u32, c.ESPICE_REASON_OK), w);
        }
        try t.expectEqual(@as(u32, 0), c.espice_release_points(handle, first_ids[b], n));
        rss[b] = try residentBytes();
    }
    // A released point keeps its id, its measures are gone; releasing again is a no-op.
    var value: [1]f64 = undefined;
    var why: [1]u32 = undefined;
    try t.expectEqual(@as(u32, c.ESPICE_RESULT_UNAVAILABLE), c.espice_copy_point_measures(handle, first_ids[0], 1, &names, 1, &value, &why));
    var len: usize = 0;
    try t.expectEqual(@as(u32, c.ESPICE_RESULT_UNAVAILABLE), c.espice_copy_result(handle, first_ids[0], null, 0, &len));
    try t.expectEqual(@as(u32, 0), c.espice_release_points(handle, first_ids[0], 1));
    var early: u64 = 0;
    var late: u64 = 0;
    for (ns[10..20]) |x| early += x;
    for (ns[90..100]) |x| late += x;
    const grown = rss[batches - 1] -| rss[19];
    std.debug.print("batches: run_all {d} ms (11-20) vs {d} ms (91-100) per 10; RSS {d} MB at 20, {d} MB at 100, {d} B per point after\n", .{ early / 1_000_000, late / 1_000_000, rss[19] >> 20, rss[batches - 1] >> 20, grown / (80 * n) });
    try t.expect(late < 2 * early);
    // A released point keeps its query rows and variant row (the Zig
    // test of `release_points` counts them), plus allocator slack.
    try t.expect(grown < 80 * n * 8 * 1024);
}

/// Options with every flag off, no abort bound and no tangents.
fn pointsOptions() c.espice_points_options {
    var o = std.mem.zeroes(c.espice_points_options);
    o.struct_size = @sizeOf(c.espice_points_options);
    o.abort_after = std.math.nan(f64);
    return o;
}

test "C points: MATCHA's 40-byte options (no tangent_step) are read, abort_measure bounds only its card" {
    const t = std.testing;
    // `quick` resolves at 0.15 ns at every rv; tpd takes ~7 ns at 100k.
    const deck = "C abort measure\n.param rv=1k\nV1 in 0 pulse(0 1 0.1n 0.1n 0.1n 20n 40n)\nR1 in out {rv}\nC1 out 0 0.1p\n.tran 1p 10n\n" ++
        ".meas tran quick when v(in)=0.5 rise=1\n.meas tran tpd trig v(in) val=0.5 rise=1 targ v(out) val=0.5 rise=1\n.end\n";
    const live = [_]c.espice_bytes{.{ .data = "rv", .len = 2 }};
    var options: c.espice_create_options = undefined;
    c.espice_default_options(&options);
    options.source_kind = c.ESPICE_BYTES;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    options.live_params = &live;
    options.live_param_count = 1;
    var handle: ?*c.espice_problem = null;
    try t.expectEqual(@as(u32, 0), c.espice_create(&options, &handle, null, 0));
    defer _ = c.espice_destroy(handle);
    try t.expectEqual(@as(usize, 40), @offsetOf(c.espice_points_options, "tangent_step"));
    const rows = [_]f64{ 1e3, 100e3 };
    var firsts: [2]u32 = undefined;
    for ([_][]const u8{ "quick", "tpd" }, &firsts) |name, *first| {
        // MATCHA's struct: 40 bytes, tangent_step beyond it holding garbage.
        var o = pointsOptions();
        o.struct_size = 40;
        o.tangent_step = -7;
        o.measures_only = 1;
        o.early_stop = 1;
        o.abort_after = 1e-9;
        o.abort_measure = .{ .data = name.ptr, .len = name.len };
        try t.expectEqual(@as(u32, 0), c.espice_append_points(handle, &rows, rows.len, &o, first));
    }
    _ = c.espice_run_all(handle);
    const names = [_]c.espice_bytes{ .{ .data = "quick", .len = 5 }, .{ .data = "tpd", .len = 3 } };
    var values: [4]f64 = undefined;
    var why: [2]u32 = undefined;
    // Bounding `quick` aborts neither point; bounding tpd aborts the slow one.
    try t.expectEqual(@as(u32, 0), c.espice_copy_point_measures(handle, firsts[0], 2, &names, 2, &values, &why));
    try t.expectEqualSlices(u32, &.{ c.ESPICE_REASON_OK, c.ESPICE_REASON_OK }, &why);
    try t.expect(std.math.isFinite(values[3]) and values[3] > 1e-9);
    try t.expectEqual(@as(u32, 0), c.espice_copy_point_measures(handle, firsts[1], 2, &names, 2, &values, &why));
    try t.expectEqualSlices(u32, &.{ c.ESPICE_REASON_OK, c.ESPICE_REASON_ABORTED }, &why);
    var short = pointsOptions();
    short.struct_size = 39;
    var first: u32 = 0;
    try t.expectEqual(@as(u32, c.ESPICE_ABI_MISMATCH), c.espice_append_points(handle, &rows, 1, &short, &first));
}
