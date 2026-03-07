const std = @import("std");
const c = @cImport({
    @cInclude("espice.h");
});

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
    try std.testing.expectEqual(@as(u32, c.ESPICE_BUFFER_TOO_SMALL), c.espice_copy_result_name(handle, ac_id, c.ESPICE_NO_QUERY, null, 0, &needed));
    const title = try std.testing.allocator.alloc(u8, needed);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqual(@as(u32, 0), c.espice_copy_result_name(handle, ac_id, c.ESPICE_NO_QUERY, title.ptr, title.len, &needed));
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
    var events = [_]c.espice_advance_event{std.mem.zeroes(c.espice_advance_event)} ** 2;
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
