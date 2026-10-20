//! The C ABI over `Problem`, built as libespice.a. include/espice.h is the
//! contract: every export's behaviour and every struct layout is documented
//! there, and the comptime block below fails the build if the enums drift.
const std = @import("std");
const api = @import("espice");

/// std reserves a 256 KB alternate signal stack per thread for stack-overflow
/// traces, as zero-filled TLS: every thread of every compilation unit pays it
/// (1.5 MB per thread across the device objects before this). Kept in Debug,
/// where the trace is worth it.
pub const std_options: std.Options = .{ .signal_stack_size = if (@import("builtin").mode == .debug) 1 << 18 else null };

/// VerA's device/host contract checks (`contract.validating`), on in Debug
/// only: off, a device build spends 0.4-1.8% fewer instructions.
pub const vera_validate_contract = @import("builtin").mode == .debug;
/// `core.gpa`: SmpAllocator, or the page allocator single-threaded (wasm).
const allocator = if (@import("builtin").single_threaded) std.heap.page_allocator else std.heap.smp_allocator;
/// Bumped on a change that breaks a caller built against an older header;
/// `espice_create` rejects a mismatch. Fields appended to
/// `espice_create_options` do not bump it: `struct_size` gates them.
const abi_version = 1;
/// ESPICE_NO_QUERY, "no dependency" in `QueryInfo`, and ESPICE_PLOT_TITLE,
/// "plot title" in `espice_copy_result_name`.
const no_query = std.math.maxInt(u32);
const header = @import("espice_h");
comptime {
    if (header.ESPICE_NO_QUERY != no_query or header.ESPICE_PLOT_TITLE != no_query) @compileError("include/espice.h sentinels drifted");
}

// Enums cross the boundary as tag values, so each is pinned to the header's
// ESPICE_<NAME> constants: a reordered or renamed tag fails the build.
comptime {
    pin(Code, .{});
    pin(api.Dialect, .{});
    pin(api.Request, .{});
    pin(api.Format, .{});
    pin(api.Status, .{ .failed = "QUERY_FAILED" });
    pin(api.requests.Kind, .{});
    pin(api.Problem.Reason, .{
        .ok = "REASON_OK",
        .no_convergence = "REASON_NO_CONVERGENCE",
        .timestep_too_small = "REASON_TIMESTEP_TOO_SMALL",
        .singular_matrix = "REASON_SINGULAR_MATRIX",
        .measure_not_found = "REASON_MEASURE_NOT_FOUND",
        .measure_unresolved = "REASON_MEASURE_UNRESOLVED",
        .aborted = "REASON_ABORTED",
        .model_bin_not_found = "REASON_MODEL_BIN_NOT_FOUND",
        .topology_changed = "REASON_TOPOLOGY_CHANGED",
        .invalid_parameter = "REASON_INVALID_PARAMETER",
        .device_refused = "REASON_DEVICE_REFUSED",
        .other = "REASON_OTHER",
    });
    pin(@FieldType(@typeInfo(@FieldType(api.QueryInfo, "progress")).optional.child, "phase"), .{ .dc = "DC_PHASE" });
}

/// Checks every tag of `E` against `ESPICE_<TAG>` in the header. `rename`
/// maps a tag to its header name where the upper-cased tag would clash.
fn pin(comptime E: type, comptime rename: anytype) void {
    @setEvalBranchQuota(20_000);
    const info = @typeInfo(E).@"enum";
    for (info.field_names, info.field_values) |field, value| {
        var upper: [field.len]u8 = undefined;
        const name = if (@hasField(@TypeOf(rename), field)) @field(rename, field) else std.ascii.upperString(&upper, field);
        if (@field(header, "ESPICE_" ++ name) != value) @compileError("include/espice.h ESPICE_" ++ name ++ " != " ++ @typeName(E) ++ "." ++ field);
    }
}

/// `espice_status` values; `status` maps Zig errors onto them.
const Code = enum(u32) {
    ok = 0,
    invalid_argument = 1,
    buffer_too_small = 2,
    out_of_memory = 3,
    invalid_query = 4,
    result_unavailable = 5,
    failed = 6,
    abi_mismatch = 7,
    invalid_handle = 8,
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
    /// Added after ABI 1 shipped: read only when `struct_size` covers them.
    zig_path: Bytes,
    share_path: Bytes,
    /// Added after the toolchain fields, read under the same rule.
    live_params: ?[*]const Bytes,
    live_param_count: usize,
    /// Added after `live_params`, read under the same rule.
    display: ?*const DisplayFn,
    display_user: ?*anyopaque,
};
const DisplayFn = fn (text: [*]const u8, len: usize, user: ?*anyopaque) callconv(.c) void;
const PointsOptions = extern struct {
    struct_size: u32,
    measures_only: u32,
    early_stop: u32,
    warm_start: u32,
    abort_after: f64,
    tangent_step: f64,
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

// The extern records above are AoS on purpose: each crosses the boundary
// whole, once per call. Each is pinned to its header struct, field by field.
comptime {
    pinLayout(Bytes, header.espice_bytes);
    pinLayout(CreateOptions, header.espice_create_options);
    pinLayout(PointsOptions, header.espice_points_options);
    pinLayout(Scope, header.espice_scope);
    pinLayout(Progress, header.espice_progress);
    pinLayout(QueryInfo, header.espice_query_info);
    pinLayout(Advance, header.espice_advance_event);
    pinLayout(ResultInfo, header.espice_result_info);
    pinLayout(PrintOptions, header.espice_print_options);
}

/// Fails the build unless `C` (the header's struct) has `Z`'s size and
/// every field of `Z` at the same offset, under the same name.
fn pinLayout(comptime Z: type, comptime C: type) void {
    if (@sizeOf(Z) != @sizeOf(C)) @compileError(@typeName(C) ++ " drifted in size from " ++ @typeName(Z));
    for (@typeInfo(Z).@"struct".field_names) |name|
        if (@offsetOf(Z, name) != @offsetOf(C, name)) @compileError(@typeName(C) ++ "." ++ name ++ " drifted from " ++ @typeName(Z));
}

/// `espice_problem`: a C handle is a `handles` token, never an address.
const Token = opaque {};

/// Every live problem, so a destroyed or foreign handle is an error code
/// rather than a use-after-free (#143). A token packs a slot index into its
/// low `index_bits` and the slot's generation above them. Slot 0 is never
/// handed out, so no token is NULL. Destroy bumps the slot's generation, so
/// every copy of the old token stops matching; a slot whose generation
/// would wrap is retired instead of reused. One lock guards the table, and
/// every critical section is O(1): it never allocates, calls out or waits
/// on anything but the lock.
const handles = struct {
    const index_bits = 12;
    /// Slots, slot 0 included; `capacity - 1` problems can be live at once.
    const capacity = 1 << index_bits;
    const Index = @Int(.unsigned, index_bits);
    const Generation = @Int(.unsigned, @bitSizeOf(usize) - index_bits);

    var mutex: std.Io.Mutex = .init;
    var live: [capacity]?*Handle = @splat(null);
    var generation: [capacity]Generation = @splat(0);
    /// Slots `remove` released, reused before `fresh` advances.
    var free: [capacity]Index = undefined;
    var free_len: u32 = 0;
    /// The lowest slot never handed out.
    var fresh: u32 = 1;

    /// The futex behind `mutex`; the single-threaded Io still supplies real
    /// futexes (see `create`).
    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    /// Registers `h` and returns its token. `error.TooManyProblems` when
    /// every slot is live or retired.
    fn insert(h: *Handle) error{TooManyProblems}!*Token {
        mutex.lockUncancelable(io());
        defer mutex.unlock(io());
        const index: Index = if (free_len > 0) reuse: {
            free_len -= 1;
            break :reuse free[free_len];
        } else if (fresh < capacity) next: {
            fresh += 1;
            break :next @intCast(fresh - 1);
        } else return error.TooManyProblems;
        std.debug.assert(index != 0 and live[index] == null);
        live[index] = h;
        return @ptrFromInt(@as(usize, generation[index]) << index_bits | index);
    }

    /// The handle `token` names. NULL is `error.InvalidArgument`; a
    /// destroyed token, or any value whose bits name no live slot at its
    /// current generation, is `error.InvalidHandle`.
    fn get(token: ?*Token) error{ InvalidArgument, InvalidHandle }!*Handle {
        const bits = @intFromPtr(token orelse return error.InvalidArgument);
        mutex.lockUncancelable(io());
        defer mutex.unlock(io());
        return live[try find(bits)].?;
    }

    /// Unregisters `token`'s handle and returns it; the token goes stale.
    fn remove(token: *Token) error{InvalidHandle}!*Handle {
        mutex.lockUncancelable(io());
        defer mutex.unlock(io());
        const index = try find(@intFromPtr(token));
        const h = live[index].?;
        live[index] = null;
        // Retired: its last token keeps failing `find` on the null slot.
        if (generation[index] == std.math.maxInt(Generation)) return h;
        generation[index] += 1;
        std.debug.assert(free_len < capacity);
        free[free_len] = index;
        free_len += 1;
        return h;
    }

    /// The live slot `bits` names. Caller holds `mutex`.
    fn find(bits: usize) error{InvalidHandle}!Index {
        const index: Index = @truncate(bits);
        if (live[index] == null or generation[index] != @as(Generation, @truncate(bits >> index_bits))) return error.InvalidHandle;
        return index;
    }
};

/// What a token names. `threaded` lives here, at a stable address, because
/// the Problem's Io points into it.
const Handle = struct {
    /// What `create` allocated the handle and its Problem from.
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    problem: *api.Problem,
    /// Read by `espice_error_message`; set by every failing call that got
    /// past the handle lookup, and by an advance event's output error.
    last_error: ?anyerror = null,
    /// `Options.display` when the caller set a display callback.
    /// Unbuffered, so concurrent queries never touch its state.
    display: std.Io.Writer,
    display_fn: ?*const DisplayFn,
    display_user: ?*anyopaque,

    fn fail(self: *Handle, err: anyerror) u32 {
        self.last_error = err;
        return status(err);
    }

    fn drainDisplay(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Handle = @alignCast(@fieldParentPtr("display", w));
        const f = self.display_fn.?;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            if (d.len != 0) f(d.ptr, d.len, self.display_user);
            n += d.len;
        }
        const last = data[data.len - 1];
        if (last.len != 0) for (0..splat) |_| f(last.ptr, last.len, self.display_user);
        return n + last.len * splat;
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

export fn espice_create(options: ?*const CreateOptions, out: ?*?*Token, diagnostic: ?[*]u8, diagnostic_capacity: usize) u32 {
    const destination = out orelse return status(error.InvalidArgument);
    destination.* = null;
    const buffer = mutableSlice(u8, diagnostic, diagnostic_capacity) catch return status(error.InvalidArgument);
    writeTruncated(buffer, "");
    destination.* = create(allocator, options orelse {
        writeTruncated(buffer, "InvalidArgument");
        return status(error.InvalidArgument);
    }) catch |err| {
        writeTruncated(buffer, @errorName(err));
        return status(err);
    };
    return 0;
}

/// `espice_create` over `gpa`, which the handle keeps for its own free.
/// Not exported: every C entry point passes `allocator` (SmpAllocator, the
/// page allocator on single-threaded wasm); only the in-file allocation
/// sweep passes another.
fn create(gpa: std.mem.Allocator, options: *const CreateOptions) !*Token {
    // A caller built before the toolchain fields passes a struct ending at
    // `output_path`; the fields past its size are never read.
    if (options.abi_version != abi_version or options.struct_size < @offsetOf(CreateOptions, "zig_path")) return error.AbiMismatch;
    const toolchain = options.struct_size >= @offsetOf(CreateOptions, "live_params");
    const live = options.struct_size >= @offsetOf(CreateOptions, "display");
    const display = options.struct_size >= @sizeOf(CreateOptions);
    const source = try constSlice(u8, options.source.data, options.source.len);
    const origin = try constSlice(u8, options.origin.data, options.origin.len);
    const path = try constSlice(u8, options.output_path.data, options.output_path.len);
    const zig_path = if (toolchain) try constSlice(u8, options.zig_path.data, options.zig_path.len) else "";
    const share_path = if (toolchain) try constSlice(u8, options.share_path.data, options.share_path.len) else "";
    const live_bytes = if (live) try constSlice(Bytes, options.live_params, options.live_param_count) else &.{};
    const live_params = try gpa.alloc([]const u8, live_bytes.len);
    defer gpa.free(live_params);
    for (live_bytes, live_params) |b, *name| name.* = try constSlice(u8, b.data, b.len);
    if (source.len == 0 or options.explicit_gpu > 1) return error.InvalidArgument;
    var config: api.Options = .{
        .source = switch (options.source_kind) {
            0 => .{ .file = source },
            1 => .{ .bytes = .{ .data = source, .origin = origin } },
            else => return error.InvalidArgument,
        },
        .dialect = std.enums.fromInt(api.Dialect, options.dialect) orelse return error.InvalidArgument,
        .backend = .{
            .backend = std.enums.fromInt(api.Request, options.backend) orelse return error.InvalidArgument,
            .gpu_explicit = options.explicit_gpu == 1,
        },
        .output = .{
            .format = std.enums.fromInt(api.Format, options.output_format) orelse return error.InvalidArgument,
            .path = if (path.len == 0) null else path,
        },
        .max_parallel = try concurrency(options.max_parallel),
        .hdl_toolchain = .{
            .zig = if (zig_path.len == 0) null else zig_path,
            .share = if (share_path.len == 0) null else share_path,
        },
        .live_params = live_params,
    };
    const handle = try gpa.create(Handle);
    errdefer gpa.destroy(handle);
    // Query workers use std.Thread directly. The single-threaded Io still
    // supplies real futexes, and unlike Threaded.init it installs no
    // process-wide signal handlers inside the host application.
    handle.gpa = gpa;
    handle.threaded = .init_single_threaded;
    errdefer handle.threaded.deinit();
    // Spawning a `.hdl` build allocates its argv and hands the child an
    // environment (the compiler finds its cache through HOME); the static
    // instance has neither.
    handle.threaded.allocator = gpa;
    const environ = try copyEnviron(gpa);
    errdefer environ.deinit(gpa);
    handle.threaded.environ = .{ .process_environ = .{ .block = environ } };
    handle.threaded.environ_initialized = false;
    handle.last_error = null;
    handle.display = .{ .vtable = &.{ .drain = Handle.drainDisplay }, .buffer = &.{} };
    handle.display_fn = if (display) options.display else null;
    handle.display_user = if (display) options.display_user else null;
    if (handle.display_fn != null) config.display = &handle.display;
    handle.problem = try api.Problem.init(gpa, handle.threaded.io(), config);
    errdefer handle.problem.deinit();
    return handles.insert(handle);
}

export fn espice_destroy(handle: ?*Token) u32 {
    // NULL is a no-op, as for free().
    const h = handles.remove(handle orelse return 0) catch |err| return status(err);
    h.problem.deinit();
    const environ = h.threaded.environ.process_environ.block;
    h.threaded.deinit();
    environ.deinit(h.gpa);
    h.gpa.destroy(h);
    return 0;
}

/// A copy of the process environment at create time: libc's `environ`
/// can move under a later `setenv`.
fn copyEnviron(gpa: std.mem.Allocator) !std.process.Environ.Block {
    const Environ = std.process.Environ;
    if (comptime Environ.Block != Environ.PosixBlock) return .global;
    const env = std.mem.span(std.c.environ);
    const block = try gpa.allocSentinel(?[*:0]const u8, env.len, null);
    var copied: usize = 0;
    errdefer {
        for (block[0..copied]) |entry| gpa.free(std.mem.span(entry.?));
        gpa.free(block);
    }
    for (env, block) |entry, *dst| {
        dst.* = (try gpa.dupeSentinel(u8, std.mem.span(entry.?), 0)).ptr;
        copied += 1;
    }
    return .{ .slice = block };
}

export fn espice_query_count(handle: ?*Token, out: ?*u32) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const destination = out orelse return h.fail(error.InvalidArgument);
    destination.* = h.problem.query_count();
    return 0;
}

export fn espice_get_query_info(handle: ?*Token, id: u32, out: ?*QueryInfo) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const destination = out orelse return h.fail(error.InvalidArgument);
    const q = h.problem.query_info(@fromBackingInt(@intCast(id))) catch |err| return h.fail(err);
    destination.* = .{
        .id = @backingInt(q.id),
        .kind = @backingInt(q.kind),
        .status = @backingInt(q.status),
        .dependency = if (q.dependency) |dep| @backingInt(dep) else no_query,
        .component = q.component,
        .requested = @intFromBool(q.requested),
        .has_progress = @intFromBool(q.progress != null),
        .failure_code = if (q.failure) |err| status(err) else 0,
        .progress = packProgress(q.progress),
    };
    return 0;
}

export fn espice_ready_queries(handle: ?*Token, scope: Scope, ids: ?[*]u32, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = 0;
    const buffer = mutableSlice(u32, ids, capacity) catch |err| return h.fail(err);
    const selection = decodeScope(scope) catch |err| return h.fail(err);
    count.* = h.problem.ready_count(selection) catch |err| return h.fail(err);
    if (count.* > capacity) return h.fail(error.BufferTooSmall);
    _ = h.problem.ready_queries(selection, @ptrCast(buffer)) catch |err| return h.fail(err);
    return 0;
}

export fn espice_advance(handle: ?*Token, id: u32, out: ?*Advance) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const destination = out orelse return h.fail(error.InvalidArgument);
    const event = h.problem.advance(@fromBackingInt(@intCast(id))) catch |err| return h.fail(err);
    destination.* = packAdvance(h, event);
    return 0;
}

export fn espice_advance_ready(handle: ?*Token, ids: ?[*]const u32, count: usize, max_parallel: u32, events: ?[*]Advance, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
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

export fn espice_run_all(handle: ?*Token) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    h.problem.run_all() catch |err| return h.fail(err);
    return 0;
}

export fn espice_append_directives(handle: ?*Token, directives: Bytes, ids: ?[*]u32, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = 0;
    const text = constSlice(u8, directives.data, directives.len) catch |err| return h.fail(err);
    const buffer = mutableSlice(u32, ids, capacity) catch |err| return h.fail(err);
    count.* = h.problem.append_directives(text, @ptrCast(buffer)) catch |err| return h.fail(err);
    return if (count.* > capacity) h.fail(error.BufferTooSmall) else 0;
}

export fn espice_set_params(handle: ?*Token, names: ?[*]const Bytes, values: ?[*]const f64, count: usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const name_bytes = constSlice(Bytes, names, count) catch |err| return h.fail(err);
    const numbers = constSlice(f64, values, count) catch |err| return h.fail(err);
    const keys = allocator.alloc([]const u8, count) catch |err| return h.fail(err);
    defer allocator.free(keys);
    for (name_bytes, keys) |b, *key| key.* = constSlice(u8, b.data, b.len) catch |err| return h.fail(err);
    h.problem.set_params(keys, numbers) catch |err| return h.fail(err);
    return 0;
}

export fn espice_get_result_info(handle: ?*Token, id: u32, out: ?*ResultInfo) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const destination = out orelse return h.fail(error.InvalidArgument);
    const result = h.problem.result(@fromBackingInt(@intCast(id))) catch |err| return h.fail(err);
    destination.* = .{
        .variable_count = std.math.cast(u32, result.varnames.len) orelse return h.fail(error.Overflow),
        .is_complex = @intFromBool(result.is_complex),
        .point_count = result.npoints,
        .value_count = result.data.len,
    };
    return 0;
}

export fn espice_copy_result(handle: ?*Token, id: u32, values: ?[*]f64, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = 0;
    const buffer = mutableSlice(f64, values, capacity) catch |err| return h.fail(err);
    const qid: api.QueryId = @fromBackingInt(@intCast(id));
    count.* = (h.problem.result(qid) catch |err| return h.fail(err)).data.len;
    if (count.* > capacity) return h.fail(error.BufferTooSmall);
    _ = h.problem.copy_result(qid, buffer) catch |err| return h.fail(err);
    return 0;
}

export fn espice_result_view(handle: ?*Token, id: u32, data: ?*?[*]const f64, len: ?*usize) u32 {
    // The header promises *data NULL and *len 0 on any failure, a NULL or
    // stale handle included (#76).
    if (data) |view| view.* = null;
    if (len) |count| count.* = 0;
    const h = handles.get(handle) catch |err| return status(err);
    const view = data orelse return h.fail(error.InvalidArgument);
    const count = len orelse return h.fail(error.InvalidArgument);
    const values = (h.problem.result(@fromBackingInt(@intCast(id))) catch |err| return h.fail(err)).data;
    view.* = values.ptr;
    count.* = values.len;
    return 0;
}

export fn espice_copy_result_name(handle: ?*Token, id: u32, variable: u32, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const result = h.problem.result(@fromBackingInt(@intCast(id))) catch |err| return h.fail(err);
    const name = if (variable == no_query) result.plotname else if (variable < result.varnames.len) result.varnames[variable] else return h.fail(error.InvalidArgument);
    return copyString(h, name, buffer, capacity, required);
}

export fn espice_print(handle: ?*Token, options: ?*const PrintOptions, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    if (required == null or (buffer == null and capacity != 0)) return h.fail(error.InvalidArgument);
    var config: api.PrintOptions = .{};
    if (options) |o| {
        if (o.ascii > 1) return h.fail(error.InvalidArgument);
        config.scope = decodeScope(o.scope) catch |err| return h.fail(err);
        config.ascii = o.ascii == 1;
        if (o.max_parallel != 0) config.limits = .{ .max_parallel = concurrency(o.max_parallel) catch |err| return h.fail(err) };
        config.preview = switch (o.preview) {
            0 => .run_all,
            1 => .{ .advance = @fromBackingInt(@intCast(o.query)) },
            2 => .{ .advance_ready = @ptrCast(constSlice(u32, o.ready_ids, o.ready_count) catch |err| return h.fail(err)) },
            else => return h.fail(error.InvalidArgument),
        };
    }
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    // `Writer.Allocating` reports running out of memory as WriteFailed.
    h.problem.print(&writer.writer, config) catch |err| return h.fail(if (err == error.WriteFailed) error.OutOfMemory else err);
    return copyString(h, writer.written(), buffer, capacity, required);
}

export fn espice_error_message(handle: ?*Token, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    // Querying an error must not replace it with the sizing call's error.
    const saved = h.last_error;
    defer h.last_error = saved;
    return copyString(h, if (saved) |err| @errorName(err) else "", buffer, capacity, required);
}

export fn espice_query_error_message(handle: ?*Token, id: u32, buffer: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const q = h.problem.query_info(@fromBackingInt(@intCast(id))) catch |err| return h.fail(err);
    return copyString(h, if (q.failure) |err| @errorName(err) else "", buffer, capacity, required);
}

export fn espice_append_points(handle: ?*Token, values: ?[*]const f64, count: usize, options: ?*const PointsOptions, first_id: ?*u32) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const first = first_id orelse return h.fail(error.InvalidArgument);
    const len = std.math.mul(usize, count, h.problem.live.len) catch |err| return h.fail(err);
    const rows = constSlice(f64, values, len) catch |err| return h.fail(err);
    var config: api.requests.PointOptions = .{};
    if (options) |o| {
        // Fields appended later are read only when `struct_size` covers them.
        if (o.struct_size < @offsetOf(PointsOptions, "tangent_step")) return h.fail(error.AbiMismatch);
        if (o.measures_only > 1 or o.early_stop > 1 or o.warm_start > 1 or !(o.abort_after >= 0) or std.math.isInf(o.abort_after)) return h.fail(error.InvalidArgument);
        config = .{ .measures_only = o.measures_only == 1, .early_stop = o.early_stop == 1, .warm_start = o.warm_start == 1, .abort_after = o.abort_after };
        if (o.struct_size >= @sizeOf(PointsOptions)) {
            if (!(o.tangent_step >= 0) or std.math.isInf(o.tangent_step)) return h.fail(error.InvalidArgument);
            config.tangent_step = o.tangent_step;
        }
    }
    const id = h.problem.append_points(rows, count, config) catch |err| return h.fail(err);
    first.* = @backingInt(id);
    return 0;
}

export fn espice_copy_point_measures(handle: ?*Token, first_id: u32, count: usize, names: ?[*]const Bytes, measure_count: usize, out: ?[*]f64, reasons: ?[*]u32) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const name_bytes = constSlice(Bytes, names, measure_count) catch |err| return h.fail(err);
    const len = std.math.mul(usize, count, measure_count) catch |err| return h.fail(err);
    const values = mutableSlice(f64, out, len) catch |err| return h.fail(err);
    const codes = mutableSlice(u32, reasons, count) catch |err| return h.fail(err);
    const keys = allocator.alloc([]const u8, measure_count) catch |err| return h.fail(err);
    defer allocator.free(keys);
    for (name_bytes, keys) |b, *key| key.* = constSlice(u8, b.data, b.len) catch |err| return h.fail(err);
    // `Reason` is u32-backed, so the caller's array holds the codes as is.
    h.problem.point_measures(@fromBackingInt(@intCast(first_id)), keys, values, @ptrCast(codes)) catch |err| return h.fail(err);
    return 0;
}

export fn espice_copy_point_tangents(handle: ?*Token, first_id: u32, count: usize, names: ?[*]const Bytes, measure_count: usize, out: ?[*]f64) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const name_bytes = constSlice(Bytes, names, measure_count) catch |err| return h.fail(err);
    const len = std.math.mul(usize, count, measure_count) catch |err| return h.fail(err);
    const total = std.math.mul(usize, len, h.problem.live.len) catch |err| return h.fail(err);
    const values = mutableSlice(f64, out, total) catch |err| return h.fail(err);
    const keys = allocator.alloc([]const u8, measure_count) catch |err| return h.fail(err);
    defer allocator.free(keys);
    for (name_bytes, keys) |b, *key| key.* = constSlice(u8, b.data, b.len) catch |err| return h.fail(err);
    h.problem.point_tangents(@fromBackingInt(@intCast(first_id)), count, keys, values) catch |err| return h.fail(err);
    return 0;
}

export fn espice_release_points(handle: ?*Token, first_id: u32, count: usize) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    h.problem.release_points(@fromBackingInt(@intCast(first_id)), count) catch |err| return h.fail(err);
    return 0;
}

export fn espice_lane_width(handle: ?*Token, out: ?*u32) u32 {
    const h = handles.get(handle) catch |err| return status(err);
    const destination = out orelse return h.fail(error.InvalidArgument);
    // ponytail: points run one query at a time; lane batching (TODO.md
    // phase 1) makes this the executor's group width.
    destination.* = 1;
    return 0;
}

/// A C (pointer, length) pair as a slice. NULL is allowed only at length 0.
fn constSlice(comptime T: type, ptr: ?[*]const T, len: usize) ![]const T {
    if (len == 0) return &.{};
    return (ptr orelse return error.InvalidArgument)[0..len];
}

fn mutableSlice(comptime T: type, ptr: ?[*]T, len: usize) ![]T {
    if (len == 0) return &.{};
    return (ptr orelse return error.InvalidArgument)[0..len];
}

/// A C `max_parallel` as the facade's u16, rejecting 0 and overflow.
fn concurrency(n: u32) !u16 {
    if (n == 0 or n > std.math.maxInt(u16)) return error.InvalidConcurrency;
    return @intCast(n);
}

fn decodeScope(scope: Scope) !api.Scope {
    return switch (scope.kind) {
        0 => .all,
        1 => .{ .query = @fromBackingInt(@intCast(scope.id)) },
        2 => .{ .component = scope.id },
        else => error.InvalidArgument,
    };
}

/// Copies `text` NUL-terminated into the caller's buffer. Sets `required`
/// first; a short buffer receives nothing and fails with BUFFER_TOO_SMALL.
fn copyString(h: *Handle, text: []const u8, ptr: ?[*]u8, capacity: usize, required: ?*usize) u32 {
    const count = required orelse return h.fail(error.InvalidArgument);
    count.* = std.math.add(usize, text.len, 1) catch |err| return h.fail(err);
    const buffer = mutableSlice(u8, ptr, capacity) catch |err| return h.fail(err);
    if (capacity < count.*) return h.fail(error.BufferTooSmall);
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;
    return 0;
}

/// Copies as much of `text` as fits, always NUL-terminated. No-op on an empty buffer.
fn writeTruncated(buffer: []u8, text: []const u8) void {
    if (buffer.len == 0) return;
    const n = @min(buffer.len - 1, text.len);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
}

fn packProgress(p: anytype) Progress {
    const event = p orelse return .{ .phase = 0, .completed = 0, .total = 0 };
    return .{
        .phase = @backingInt(event.phase),
        .completed = event.completed,
        .total = event.total,
    };
}

/// An output failure carried by the event also becomes the handle's last error.
fn packAdvance(h: *Handle, event: api.Advance) Advance {
    var out: Advance = .{
        .requested = @backingInt(event.requested),
        .advanced = @backingInt(event.advanced),
        .status = @backingInt(event.status),
        .target_status = @backingInt(event.target_status),
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

/// Collapses a Zig error into an `espice_status`; the name survives in
/// `last_error` for `espice_error_message`.
fn status(err: anyerror) u32 {
    const code: Code = switch (err) {
        error.InvalidArgument, error.InvalidConcurrency, error.InvalidComponent, error.QueryNotReady, error.DuplicateQuery => .invalid_argument,
        // Malformed caller input (analysis cards, query options, directive edits), not a numerical failure.
        error.InvalidAnalysisArguments, error.InvalidQueryOptions, error.UnsupportedDirectiveMutation => .invalid_argument,
        // A live parameter name the deck does not define or declare.
        error.UnknownParameter => .invalid_argument,
        // Points API: no live parameters, a deck that sweeps already, a
        // measure name no card has.
        error.NoLiveParameters, error.SweptTemplate, error.UnknownMeasure => .invalid_argument,
        // Points API: tangents on a transient that cannot integrate them.
        error.TangentsUnavailable => .invalid_argument,
        error.BufferTooSmall => .buffer_too_small,
        error.OutOfMemory => .out_of_memory,
        error.InvalidQuery => .invalid_query,
        error.ResultUnavailable => .result_unavailable,
        error.AbiMismatch => .abi_mismatch,
        error.InvalidHandle => .invalid_handle,
        // A full handle table is a capacity, reported like any allocation.
        error.TooManyProblems => .out_of_memory,
        // `err` is anyerror (Handle.last_error keeps any name), so no
        // exhaustive switch exists: every error not named above is a
        // numerical, I/O or output failure.
        else => .failed, // else: FAILED in include/espice.h
    };
    return @backingInt(code);
}

// Expected: every induced failure surfaces as OUT_OF_MEMORY from the call
// that hit it, and destroy then frees everything (the C contract for a
// failed call, include/espice.h); the testing allocator checks the frees.
test "create, append and run_all report OUT_OF_MEMORY at every allocation failure and leak nothing" {
    try std.testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, createAppendRun, .{});
}

fn createAppendRun(gpa: std.mem.Allocator) !void {
    const deck = "C sweep\nV1 in 0 dc 1 ac 1\nR1 in out 1k\nC1 out 0 1u\n.op\n.end\n";
    var options: CreateOptions = undefined;
    espice_default_options(&options);
    options.source_kind = 1;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    const token = try create(gpa, &options);
    defer std.debug.assert(espice_destroy(token) == 0);
    const ac = ".ac dec 1 1 10\n";
    var ids: [1]u32 = undefined;
    var n: usize = 0;
    try expectOk(espice_append_directives(token, .{ .data = ac, .len = ac.len }, &ids, ids.len, &n));
    try expectOk(espice_run_all(token));
}

/// OUT_OF_MEMORY as `error.OutOfMemory`, which the sweep expects at an
/// induced failure; any other failing code fails the test.
fn expectOk(code: u32) !void {
    if (code == @backingInt(Code.out_of_memory)) return error.OutOfMemory;
    if (code != 0) return error.UnexpectedStatus;
}

test "status: every documented error maps to its include/espice.h code" {
    const cases = [_]struct { anyerror, Code }{
        .{ error.InvalidArgument, .invalid_argument },     .{ error.InvalidConcurrency, .invalid_argument },
        .{ error.InvalidComponent, .invalid_argument },    .{ error.QueryNotReady, .invalid_argument },
        .{ error.DuplicateQuery, .invalid_argument },      .{ error.InvalidAnalysisArguments, .invalid_argument },
        .{ error.InvalidQueryOptions, .invalid_argument }, .{ error.UnsupportedDirectiveMutation, .invalid_argument },
        .{ error.UnknownParameter, .invalid_argument },    .{ error.BufferTooSmall, .buffer_too_small },
        .{ error.OutOfMemory, .out_of_memory },            .{ error.TooManyProblems, .out_of_memory },
        .{ error.InvalidQuery, .invalid_query },           .{ error.ResultUnavailable, .result_unavailable },
        .{ error.AbiMismatch, .abi_mismatch },             .{ error.InvalidHandle, .invalid_handle },
        // The header's FAILED: numerical, I/O and output failures, and
        // set_params' bin and topology refusals.
        .{ error.SingularMatrix, .failed },                .{ error.FileNotFound, .failed },
        .{ error.ModelBinNotFound, .failed },              .{ error.UnsupportedCard, .failed },
        .{ error.Overflow, .failed },
    };
    for (cases) |case| try std.testing.expectEqual(@backingInt(case[1]), status(case[0]));
}

test "writeTruncated: as much as fits, NUL-terminated; nothing past the buffer" {
    for ([_]struct { usize, []const u8 }{ .{ 0, "" }, .{ 1, "" }, .{ 3, "ab" }, .{ 4, "abc" }, .{ 7, "abc" } }) |case| {
        var buffer: [8]u8 = @splat('x');
        writeTruncated(buffer[0..case[0]], "abc");
        if (case[0] != 0) try std.testing.expectEqualStrings(case[1], std.mem.sliceTo(&buffer, 0));
        try std.testing.expect(std.mem.allEqual(u8, buffer[@min(case[0], case[1].len + 1)..], 'x'));
    }
}

// The table is process-global: this test leaves every slot it took free
// again, except the one it retires on purpose.
test "handles: a full table refuses create without leaking, and a retired slot never matches again" {
    const t = std.testing;
    var dummy: Handle = undefined;
    var tokens: [handles.capacity]*Token = undefined;
    var n: usize = 0;
    defer for (tokens[0..n]) |token| {
        _ = handles.remove(token) catch unreachable;
    };
    while (handles.insert(&dummy)) |token| : (n += 1) tokens[n] = token else |err| try t.expectEqual(error.TooManyProblems, err);
    try t.expectEqual(@as(usize, handles.capacity - 1), n);
    // A full table: create builds the Problem, then frees it (the testing
    // allocator checks) and reports OUT_OF_MEMORY through its diagnostic.
    const deck = "full\nV1 a 0 1\nR1 a 0 1k\n.op\n.end\n";
    var options: CreateOptions = undefined;
    espice_default_options(&options);
    options.source_kind = 1;
    options.source = .{ .data = deck.ptr, .len = deck.len };
    try t.expectError(error.TooManyProblems, create(t.allocator, &options));
    var out: ?*Token = @ptrFromInt(8);
    var diagnostic: [32]u8 = undefined;
    try t.expectEqual(@backingInt(Code.out_of_memory), espice_create(&options, &out, &diagnostic, diagnostic.len));
    try t.expect(out == null);
    try t.expectEqualStrings("TooManyProblems", std.mem.sliceTo(&diagnostic, 0));
    // Every token still names its own slot, and a slot-0 value names none.
    for (tokens[0..n]) |token| try t.expectEqual(&dummy, try handles.get(token));
    try t.expectError(error.InvalidHandle, handles.get(@ptrFromInt(@as(usize, 1) << handles.index_bits)));
    // Free one slot; its old token is stale, the slot's next token differs.
    const old = tokens[n - 1];
    n -= 1;
    _ = try handles.remove(old);
    try t.expectError(error.InvalidHandle, handles.get(old));
    try t.expectError(error.InvalidHandle, handles.remove(old));
    const next = try handles.insert(&dummy);
    try t.expect(next != old);
    try t.expectEqual(@as(handles.Index, @truncate(@intFromPtr(old))), @as(handles.Index, @truncate(@intFromPtr(next))));
    // A slot at the last generation is retired on remove, not reused.
    const index: handles.Index = @truncate(@intFromPtr(next));
    handles.generation[index] = std.math.maxInt(handles.Generation);
    const last: *Token = @ptrFromInt(@as(usize, handles.generation[index]) << handles.index_bits | index);
    const free_len = handles.free_len;
    try t.expectEqual(&dummy, try handles.remove(last));
    try t.expectEqual(free_len, handles.free_len);
    try t.expectError(error.InvalidHandle, handles.get(last));
    try t.expectError(error.InvalidHandle, handles.get(next));
}

// Stateful fuzz (TESTING-METHODOLOGY 2.1 item 10): random espice_* calls on
// up to three live problems, stale and forged handles mixed in. The model
// predicts every status code from include/espice.h alone: what was
// appended, which directive text maps to which id, what run_all completed,
// what was destroyed. `advance` leaves the queries it may have touched
// `.unknown` until a query_info observes them. Problems come from
// `create(testing.allocator)`, so a leak on any path fails the test.
test "C ABI stateful fuzz: random call sequences match a model of valid states and leak nothing" {
    const t = std.testing;
    const ok: u32 = 0;
    const code = struct {
        fn of(c: Code) u32 {
            return @backingInt(c);
        }
    }.of;
    const deck = "C fuzz\n.param rv=1k\nV1 in 0 dc 1 ac 1\nR1 in out {rv}\nC1 out 0 1u\n.op\n.end\n";
    const directives = [_][]const u8{ ".ac dec 1 1 10", ".tran 1u 3u", ".dc v1 0 1 0.5", ".op" };
    const State = enum { pending, complete, unknown };
    const Live = struct {
        token: *Token,
        /// Query ids `0..n`, with the model's state of each.
        states: [32]State = undefined,
        n: u32 = 0,
        /// The id `.op` got since the last set_params: only an OP is
        /// shared by an identical append; every other card is a new query.
        op: ?u32 = null,
        last_error: []const u8 = "",
    };
    const live_name = [_]Bytes{.{ .data = "rv", .len = 2 }};
    for ([_]u64{ 1, 2, 3, 4 }) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var live: [3]Live = undefined;
        var live_len: usize = 0;
        var stale: [64]*Token = undefined;
        var stale_len: usize = 0;
        defer for (live[0..live_len]) |p| {
            _ = espice_destroy(p.token);
        };
        for (0..200) |_| {
            const step = random.uintLessThan(u8, 12);
            if (live_len == 0 or (step == 0 and live_len < live.len)) {
                var options: CreateOptions = undefined;
                espice_default_options(&options);
                options.source_kind = 1;
                options.source = .{ .data = deck.ptr, .len = deck.len };
                options.live_params = &live_name;
                options.live_param_count = 1;
                live[live_len] = .{ .token = try create(t.allocator, &options) };
                live[live_len].states[0] = .pending; // the deck's .op
                live[live_len].n = 1;
                live[live_len].op = 0;
                live_len += 1;
                continue;
            }
            const p = &live[random.uintLessThan(usize, live_len)];
            const k = random.uintLessThan(u32, p.n);
            var n: usize = 0;
            var u: u32 = 0;
            switch (step) {
                0, 1 => if (p.n + 2 <= p.states.len) {
                    const which = random.uintLessThan(usize, directives.len);
                    const text = directives[which];
                    var id: u32 = no_query;
                    // A sizing call first: nothing is appended.
                    try t.expectEqual(code(.buffer_too_small), espice_append_directives(p.token, .{ .data = text.ptr, .len = text.len }, null, 0, &n));
                    try t.expectEqual(@as(usize, 1), n);
                    try t.expectEqual(ok, espice_query_count(p.token, &u));
                    try t.expectEqual(p.n, u);
                    p.last_error = "BufferTooSmall";
                    try t.expectEqual(ok, espice_append_directives(p.token, .{ .data = text.ptr, .len = text.len }, (&id)[0..1], 1, &n));
                    if (text[1] == 'o' and p.op != null) try t.expectEqual(p.op.?, id) else {
                        // A new card, perhaps with its .op prerequisite; an
                        // .op text may instead be such an existing prerequisite.
                        try t.expectEqual(ok, espice_query_count(p.token, &u));
                        try t.expect(id < u and (id >= p.n or text[1] == 'o'));
                        for (p.states[p.n..u]) |*s| s.* = .pending;
                        p.n = u;
                        if (text[1] == 'o') p.op = id;
                    }
                },
                2 => {
                    // Malformed input: a device card, or no analysis card.
                    const text = if (random.boolean()) "R9 in 0 1k" else "* nothing";
                    var id: u32 = no_query;
                    try t.expectEqual(code(.invalid_argument), espice_append_directives(p.token, .{ .data = text.ptr, .len = text.len }, (&id)[0..1], 1, &n));
                    try t.expectEqual(no_query, id);
                    try t.expectEqual(ok, espice_query_count(p.token, &u));
                    try t.expectEqual(p.n, u);
                    p.last_error = if (text[0] == 'R') "UnsupportedDirectiveMutation" else "InvalidAnalysisArguments";
                },
                3 => {
                    var event: Advance = undefined;
                    const bad = random.uintLessThan(u8, 4) == 0;
                    const id = if (bad) p.n + random.uintAtMost(u32, 3) else k;
                    if (bad) {
                        try t.expectEqual(code(.invalid_query), espice_advance(p.token, id, &event));
                        p.last_error = "InvalidQuery";
                    } else {
                        try t.expectEqual(ok, espice_advance(p.token, id, &event));
                        try t.expectEqual(id, event.requested);
                        for (p.states[0..p.n]) |*s| if (s.* == .pending) {
                            s.* = .unknown;
                        };
                    }
                },
                4 => {
                    var ids: [32]u32 = undefined;
                    try t.expectEqual(ok, espice_ready_queries(p.token, .{ .kind = 0, .id = 0 }, &ids, ids.len, &n));
                    var events: [32]Advance = undefined;
                    var required: usize = 0;
                    if (n > 0 and random.boolean()) {
                        // A duplicate frontier starts nothing.
                        const twice = [_]u32{ ids[0], ids[0] };
                        try t.expectEqual(code(.invalid_argument), espice_advance_ready(p.token, &twice, 2, 2, &events, events.len, &required));
                        p.last_error = "DuplicateQuery";
                    } else {
                        try t.expectEqual(ok, espice_advance_ready(p.token, &ids, n, random.uintAtMost(u32, 3) + 1, &events, events.len, &required));
                        try t.expectEqual(n, required);
                        for (ids[0..n], events[0..n]) |id, e| try t.expectEqual(id, e.requested);
                        for (p.states[0..p.n]) |*s| if (s.* == .pending) {
                            s.* = .unknown;
                        };
                    }
                },
                5 => {
                    try t.expectEqual(ok, espice_run_all(p.token));
                    @memset(p.states[0..p.n], .complete);
                },
                6 => {
                    var info: QueryInfo = undefined;
                    try t.expectEqual(ok, espice_get_query_info(p.token, k, &info));
                    try t.expectEqual(k, info.id);
                    try t.expectEqual(@as(u32, 0), info.failure_code);
                    const complete = header.ESPICE_COMPLETE;
                    switch (p.states[k]) {
                        .pending => try t.expectEqual(@as(u32, header.ESPICE_PENDING), info.status),
                        .complete => try t.expectEqual(@as(u32, complete), info.status),
                        .unknown => {
                            try t.expect(info.status <= complete); // pending, paused or complete
                            if (info.status == complete) p.states[k] = .complete;
                        },
                    }
                },
                7 => {
                    var result: ResultInfo = undefined;
                    const got = espice_get_result_info(p.token, k, &result);
                    var view: ?[*]const f64 = null;
                    var len: usize = 7;
                    const viewed = espice_result_view(p.token, k, &view, &len);
                    try t.expectEqual(got, viewed);
                    if (got == ok) {
                        try t.expect(p.states[k] != .pending);
                        p.states[k] = .complete;
                        try t.expectEqual(result.value_count, len);
                        // Any capacity: short is BUFFER_TOO_SMALL and untouched.
                        var values: [512]f64 = @splat(-1);
                        const capacity = random.uintAtMost(usize, @min(values.len, len + 1));
                        try t.expectEqual(if (capacity < len) code(.buffer_too_small) else ok, espice_copy_result(p.token, k, &values, capacity, &n));
                        try t.expectEqual(len, n);
                        if (capacity < len) {
                            try t.expect(std.mem.allEqual(f64, &values, -1));
                            p.last_error = "BufferTooSmall";
                        } else try t.expectEqualSlices(f64, view.?[0..len], values[0..len]);
                    } else {
                        try t.expectEqual(code(.result_unavailable), got);
                        try t.expect(p.states[k] != .complete);
                        try t.expect(view == null and len == 0);
                        p.last_error = "ResultUnavailable";
                    }
                },
                8 => {
                    // One fault per call: the header leaves the order of an
                    // unknown name and a NaN in one call unspecified.
                    const unknown = random.uintLessThan(u8, 4) == 0;
                    const value: f64 = if (!unknown and random.uintLessThan(u8, 3) == 0)
                        std.math.nan(f64)
                    else
                        500 + @as(f64, @floatFromInt(random.uintLessThan(u32, 5000)));
                    const names = [_]Bytes{.{ .data = "zz", .len = 2 }};
                    const values = [_]f64{value};
                    const got = espice_set_params(p.token, if (unknown) &names else &live_name, &values, 1);
                    if (unknown or std.math.isNan(value)) {
                        try t.expectEqual(code(.invalid_argument), got);
                        p.last_error = if (unknown) "UnknownParameter" else "InvalidArgument";
                    } else {
                        try t.expectEqual(ok, got);
                        // `.op` now names a new OP, at the new value.
                        p.op = null;
                    }
                },
                9 => {
                    // The diagnostic names the last failure, and reading it
                    // (a sizing failure included) does not replace it.
                    var message: [64]u8 = undefined;
                    try t.expectEqual(code(.buffer_too_small), espice_error_message(p.token, null, 0, &n));
                    try t.expectEqual(p.last_error.len + 1, n);
                    try t.expectEqual(ok, espice_error_message(p.token, &message, message.len, &n));
                    try t.expectEqualStrings(p.last_error, std.mem.sliceTo(&message, 0));
                },
                10 => {
                    // A forged token: never a live one's bits, by construction.
                    const bits = random.int(usize) | 1;
                    const forged: *Token = @ptrFromInt(bits);
                    if (for (live[0..live_len]) |q| {
                        if (q.token == forged) break true;
                    } else false) continue;
                    try t.expectEqual(code(.invalid_handle), espice_query_count(forged, &u));
                    try t.expectEqual(code(.invalid_handle), espice_destroy(forged));
                    try t.expectEqual(code(.invalid_argument), espice_run_all(null));
                },
                11 => {
                    try t.expectEqual(ok, espice_destroy(p.token));
                    if (stale_len < stale.len) {
                        stale[stale_len] = p.token;
                        stale_len += 1;
                    }
                    p.* = live[live_len - 1];
                    live_len -= 1;
                },
                else => unreachable, // else: uintLessThan(u8, 12)
            }
            if (stale_len > 0) {
                const old = stale[random.uintLessThan(usize, stale_len)];
                try t.expectEqual(code(.invalid_handle), espice_query_count(old, &u));
                try t.expectEqual(code(.invalid_handle), espice_destroy(old));
            }
        }
    }
}
