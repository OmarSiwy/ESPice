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
    options.struct_size = @sizeOf(c.espice_create_options) - 1;
    try std.testing.expectEqual(@as(u32, c.ESPICE_ABI_MISMATCH), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    options.struct_size = @sizeOf(c.espice_create_options);
    options.max_parallel = 65536;
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_create(&options, &handle, &diagnostic, diagnostic.len));
    try std.testing.expectEqual(@as(u32, c.ESPICE_INVALID_ARGUMENT), c.espice_query_count(null, null));
    c.espice_destroy(null);
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
    defer c.espice_destroy(handle);
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
    defer c.espice_destroy(handle);
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
    for (0..8) |case| {
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
            else => unreachable,
        }
        try t.expectEqual(invalid, c.espice_create(&bad, &handle, null, 0));
        try t.expect(handle == null);
    }
    // A newer caller's larger struct is accepted; only our prefix is read.
    good.struct_size += 16;
    try t.expectEqual(@as(u32, c.ESPICE_OK), c.espice_create(&good, &handle, null, 0));
    c.espice_destroy(handle);
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
    defer c.espice_destroy(handle);
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
