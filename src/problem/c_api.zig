//! C boundary for the owning Problem facade. Build as a separate module so the
//! facade never imports its own adapter. Public layouts are in include/espice.h.
const std = @import("std");
const api = @import("problem");
const allocator = std.heap.smp_allocator;
const abi_version = 1;
const no_query = std.math.maxInt(u32);

const Code = enum(u32) {
    ok = 0,
    invalid_argument = 1,
    buffer_too_small = 2,
    out_of_memory = 3,
    invalid_query = 4,
    result_unavailable = 5,
    failed = 6,
    abi_mismatch = 7,
};
const Bytes = extern struct { data: ?[*]const u8, len: usize };
const CreateOptions = extern struct {
    abi_version: u32,
    struct_size: u32,
    source_kind: u32,
    dialect: u32,
    backend: u32,
    explicit_gpu: u32,
    output_format: u32,
    max_parallel: u32,
    source: Bytes,
    origin: Bytes,
    output_path: Bytes,
};
const Scope = extern struct { kind: u32, id: u32 };
const Progress = extern struct { phase: u32, reserved: u32 = 0, completed: u64, total: u64 };
const QueryInfo = extern struct {
    id: u32,
    kind: u32,
    status: u32,
    dependency: u32,
    component: u32,
    requested: u32,
    has_progress: u32,
    failure_code: u32,
    progress: Progress,
};
const Advance = extern struct {
    requested: u32,
    advanced: u32,
    status: u32,
    target_status: u32,
    has_progress: u32,
    failure_code: u32,
    output_error: u32,
    reserved: u32 = 0,
    progress: Progress,
    output_error_name: [96]u8,
};
const ResultInfo = extern struct { variable_count: u32, is_complex: u32, point_count: u64, value_count: u64 };
const PrintOptions = extern struct {
    scope: Scope,
    preview: u32,
    query: u32,
    ascii: u32,
    max_parallel: u32,
    ready_ids: ?[*]const u32,
    ready_count: usize,
};

// The handle owns identity-bearing Io and Problem objects for one lifetime.
// Control records are cold AoS: every field is read together at the boundary.
const Handle = struct {
    threaded: std.Io.Threaded,
    problem: *api.Problem,
    last_error: ?anyerror = null,

    fn fail(self: *Handle, err: anyerror) u32 {
        self.last_error = err;
        return status(err);
    }
};

export fn espice_abi_version() u32 {
    return abi_version;
}

export fn espice_default_options(out: ?*CreateOptions) void {
    const options = out orelse return;
    options.* = std.mem.zeroes(CreateOptions);
    options.abi_version = abi_version;
    options.struct_size = @sizeOf(CreateOptions);
    options.max_parallel = 1;
}

export fn espice_create(options: ?*const CreateOptions, out: ?*?*Handle, diagnostic: ?[*]u8, diagnostic_capacity: usize) u32 {
    const destination = out orelse return status(error.InvalidArgument);
    destination.* = null;
    const buffer = mutableSlice(u8, diagnostic, diagnostic_capacity) catch return status(error.InvalidArgument);
    writeTruncated(buffer, "");
    destination.* = create(options orelse {
        writeTruncated(buffer, "InvalidArgument");
        return status(error.InvalidArgument);
    }) catch |err| {
        writeTruncated(buffer, @errorName(err));
        return status(err);
    };
    return 0;
}

fn create(options: *const CreateOptions) !*Handle {
    if (options.abi_version != abi_version or options.struct_size < @sizeOf(CreateOptions)) return error.AbiMismatch;
    const source = try constSlice(u8, options.source.data, options.source.len);
    const origin = try constSlice(u8, options.origin.data, options.origin.len);
    const path = try constSlice(u8, options.output_path.data, options.output_path.len);
    if (source.len == 0 or options.explicit_gpu > 1) return error.InvalidArgument;
    const config: api.Options = .{
        .source = switch (options.source_kind) {
            0 => .{ .file = source },
            1 => .{ .bytes = .{ .data = source, .origin = origin } },
            else => return error.InvalidArgument,
        },
        .dialect = switch (options.dialect) {
            0 => .ngspice,
            1 => .hspice,
            2 => .spectre,
            else => return error.InvalidArgument,
        },
        .backend = .{
            .backend = switch (options.backend) {
                0 => .cpu,
                1 => .auto,
                2 => .cuda,
                3 => .hip,
                else => return error.InvalidArgument,
            },
            .gpu_explicit = options.explicit_gpu == 1,
        },
        .output = .{
            .format = switch (options.output_format) {
                0 => .binary,
                1 => .ascii,
                2 => .csv,
                3 => .touchstone,
                4 => .psf,
                5 => .fsdb,
                6 => .sst2,
                7 => .citi,
                8 => .print,
                else => return error.InvalidArgument,
            },
            .path = if (path.len == 0) null else path,
        },
        .max_parallel = try concurrency(options.max_parallel),
    };
    const handle = try allocator.create(Handle);
    errdefer allocator.destroy(handle);
    // Query workers use std.Thread; this Io still supplies real futexes, while
    // avoiding Threaded.init's process-wide signal-handler installation.
    handle.threaded = .init_single_threaded;
    errdefer handle.threaded.deinit();
    handle.last_error = null;
    handle.problem = try api.Problem.init(allocator, handle.threaded.io(), config);
    return handle;
}

export fn espice_destroy(handle: ?*Handle) void {
    const h = handle orelse return;
    h.problem.deinit();
    h.threaded.deinit();
    allocator.destroy(h);
}

export fn espice_query_count(handle: ?*Handle, out: ?*u32) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const destination = out orelse return h.fail(error.InvalidArgument);
    destination.* = h.problem.query_count();
    return 0;
}

export fn espice_get_query_info(handle: ?*Handle, id: u32, out: ?*QueryInfo) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const destination = out orelse return h.fail(error.InvalidArgument);
    const q = h.problem.query_info(@enumFromInt(id)) catch |err| return h.fail(err);
    destination.* = .{
        .id = @intFromEnum(q.id),
        .kind = kindTag(q.kind),
        .status = stateTag(q.status),
        .dependency = if (q.dependency) |dep| @intFromEnum(dep) else no_query,
        .component = q.component,
        .requested = @intFromBool(q.requested),
        .has_progress = @intFromBool(q.progress != null),
        .failure_code = if (q.failure) |err| status(err) else 0,
        .progress = packProgress(q.progress),
    };
    return 0;
}

export fn espice_ready_queries(handle: ?*Handle, scope: Scope, ids: ?[*]u32, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = 0;
    const buffer = mutableSlice(u32, ids, capacity) catch |err| return h.fail(err);
    const selection = decodeScope(scope) catch |err| return h.fail(err);
    count.* = h.problem.ready_queries(selection, @ptrCast(buffer)) catch |err| return h.fail(err);
    return if (count.* > capacity) h.fail(error.BufferTooSmall) else 0;
}

export fn espice_advance(handle: ?*Handle, id: u32, out: ?*Advance) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const destination = out orelse return h.fail(error.InvalidArgument);
    const event = h.problem.advance(@enumFromInt(id)) catch |err| return h.fail(err);
    destination.* = packAdvance(h, event);
    return 0;
}

export fn espice_advance_ready(handle: ?*Handle, ids: ?[*]const u32, count: usize, max_parallel: u32, events: ?[*]Advance, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const needed = required orelse return h.fail(error.InvalidArgument);
    needed.* = count;
    const selected = constSlice(u32, ids, count) catch |err| return h.fail(err);
    const destination = mutableSlice(Advance, events, capacity) catch |err| return h.fail(err);
    const limit = concurrency(max_parallel) catch |err| return h.fail(err);
    if (capacity < count) return h.fail(error.BufferTooSmall);
    const scratch = allocator.alloc(api.Advance, count) catch |err| return h.fail(err);
    defer allocator.free(scratch);
    needed.* = h.problem.advance_ready(@ptrCast(selected), .{ .max_parallel = limit }, scratch) catch |err| return h.fail(err);
    for (scratch[0..needed.*], destination[0..needed.*]) |event, *dest| dest.* = packAdvance(h, event);
    return 0;
}

export fn espice_run_all(handle: ?*Handle) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    h.problem.run_all() catch |err| return h.fail(err);
    return 0;
}

export fn espice_append_directives(handle: ?*Handle, directives: Bytes, ids: ?[*]u32, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = 0;
    const text = constSlice(u8, directives.data, directives.len) catch |err| return h.fail(err);
    const buffer = mutableSlice(u32, ids, capacity) catch |err| return h.fail(err);
    count.* = h.problem.append_directives(text, @ptrCast(buffer)) catch |err| return h.fail(err);
    return if (count.* > capacity) h.fail(error.BufferTooSmall) else 0;
}

export fn espice_get_result_info(handle: ?*Handle, id: u32, out: ?*ResultInfo) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const destination = out orelse return h.fail(error.InvalidArgument);
    const result = h.problem.result(@enumFromInt(id)) catch |err| return h.fail(err);
    destination.* = .{
        .variable_count = std.math.cast(u32, result.varnames.len) orelse return h.fail(error.Overflow),
        .is_complex = @intFromBool(result.is_complex),
        .point_count = result.npoints,
        .value_count = result.data.len,
    };
    return 0;
}

export fn espice_copy_result(handle: ?*Handle, id: u32, values: ?[*]f64, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = 0;
    const buffer = mutableSlice(f64, values, capacity) catch |err| return h.fail(err);
    count.* = h.problem.copy_result(@enumFromInt(id), buffer) catch |err| return h.fail(err);
    return if (count.* > capacity) h.fail(error.BufferTooSmall) else 0;
}

export fn espice_copy_result_name(handle: ?*Handle, id: u32, variable: u32, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const result = h.problem.result(@enumFromInt(id)) catch |err| return h.fail(err);
    const name = if (variable == no_query) result.plotname else if (variable < result.varnames.len) result.varnames[variable] else return h.fail(error.InvalidArgument);
    return copyString(h, name, buffer, capacity, required);
}

export fn espice_print(handle: ?*Handle, options: ?*const PrintOptions, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    if (required == null or (buffer == null and capacity != 0)) return h.fail(error.InvalidArgument);
    var config: api.PrintOptions = .{};
    if (options) |o| {
        if (o.ascii > 1) return h.fail(error.InvalidArgument);
        config.scope = decodeScope(o.scope) catch |err| return h.fail(err);
        config.ascii = o.ascii == 1;
        config.limits = .{ .max_parallel = concurrency(o.max_parallel) catch |err| return h.fail(err) };
        config.preview = switch (o.preview) {
            0 => .run_all,
            1 => .{ .advance = @enumFromInt(o.query) },
            2 => .{ .advance_ready = @ptrCast(constSlice(u32, o.ready_ids, o.ready_count) catch |err| return h.fail(err)) },
            else => return h.fail(error.InvalidArgument),
        };
    }
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    h.problem.print(&writer.writer, config) catch |err| return h.fail(err);
    return copyString(h, writer.written(), buffer, capacity, required);
}

export fn espice_error_message(handle: ?*Handle, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    // Querying an error must not replace it with the sizing call's error.
    const saved = h.last_error;
    defer h.last_error = saved;
    return copyString(h, if (saved) |err| @errorName(err) else "", buffer, capacity, required);
}

export fn espice_query_error_message(handle: ?*Handle, id: u32, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handle orelse return status(error.InvalidArgument);
    const q = h.problem.query_info(@enumFromInt(id)) catch |err| return h.fail(err);
    return copyString(h, if (q.failure) |err| @errorName(err) else "", buffer, capacity, required);
}

fn constSlice(comptime T: type, ptr: ?[*]const T, len: usize) ![]const T {
    if (len == 0) return &.{};
    return (ptr orelse return error.InvalidArgument)[0..len];
}

fn mutableSlice(comptime T: type, ptr: ?[*]T, len: usize) ![]T {
    if (len == 0) return &.{};
    return (ptr orelse return error.InvalidArgument)[0..len];
}

fn concurrency(n: u32) !u16 {
    if (n == 0 or n > std.math.maxInt(u16)) return error.InvalidConcurrency;
    return @intCast(n);
}

fn decodeScope(scope: Scope) !api.Scope {
    return switch (scope.kind) {
        0 => .all,
        1 => .{ .query = @enumFromInt(scope.id) },
        2 => .{ .component = scope.id },
        else => error.InvalidArgument,
    };
}

fn copyString(h: *Handle, text: []const u8, ptr: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = std.math.add(usize, text.len, 1) catch |err| return h.fail(err);
    const buffer = mutableSlice(u8, ptr, capacity) catch |err| return h.fail(err);
    if (capacity < count.*) return h.fail(error.BufferTooSmall);
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    return 0;
}

fn writeTruncated(buffer: []u8, text: []const u8) void {
    if (buffer.len == 0) return;
    const n = @min(buffer.len - 1, text.len);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
}

fn packProgress(p: anytype) Progress {
    const event = p orelse return .{ .phase = 0, .completed = 0, .total = 0 };
    return .{
        .phase = switch (event.phase) {
            .prepare => 0,
            .nonlinear => 1,
            .dc => 2,
            .frequency => 3,
            .transient => 4,
            .periodic => 5,
            .harmonic => 6,
            .sweep => 7,
            .postprocess => 8,
        },
        .completed = event.completed,
        .total = event.total,
    };
}

fn packAdvance(h: *Handle, event: api.Advance) Advance {
    var out: Advance = .{
        .requested = @intFromEnum(event.requested),
        .advanced = @intFromEnum(event.advanced),
        .status = stateTag(event.status),
        .target_status = stateTag(event.target_status),
        .has_progress = @intFromBool(event.progress != null),
        .failure_code = if (event.failure) |err| status(err) else 0,
        .output_error = if (event.delivery_error) |err| status(err) else 0,
        .progress = packProgress(event.progress),
        .output_error_name = @splat(0),
    };
    if (event.delivery_error) |err| {
        h.last_error = err;
        writeTruncated(&out.output_error_name, @errorName(err));
    }
    return out;
}

fn stateTag(state: api.Status) u32 {
    return switch (state) {
        .pending => 0,
        .paused => 1,
        .complete => 2,
        .failed => 3,
        .dependency_failed => 4,
        .cancelled => 5,
    };
}

fn kindTag(kind: api.requests.Kind) u32 {
    return switch (kind) {
        .ac => 0,
        .dc => 1,
        .dcmatch => 2,
        .disto => 3,
        .envelope => 4,
        .four => 5,
        .hb => 6,
        .matex => 7,
        .mc => 8,
        .noise => 9,
        .op => 10,
        .pac => 11,
        .pnoise => 12,
        .pss => 13,
        .pxf => 14,
        .pz => 15,
        .qpss => 16,
        .sens => 17,
        .sp => 18,
        .stb => 19,
        .temp => 20,
        .tf => 21,
        .tran => 22,
        .tran_noise => 23,
    };
}

fn status(err: anyerror) u32 {
    const code: Code = switch (err) {
        error.InvalidArgument, error.InvalidConcurrency, error.InvalidComponent, error.QueryNotReady, error.DuplicateQuery => .invalid_argument,
        error.BufferTooSmall => .buffer_too_small,
        error.OutOfMemory => .out_of_memory,
        error.InvalidQuery => .invalid_query,
        error.ResultUnavailable => .result_unavailable,
        error.AbiMismatch => .abi_mismatch,
        else => .failed,
    };
    return @intFromEnum(code);
}
