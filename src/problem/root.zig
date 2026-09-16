//! Owning public Problem API. Shared data is in the separate problem_types module.
const std = @import("std");
const frontend = @import("frontend");
const shared = @import("problem_types");
const analysis = @import("analysis");
const output = @import("output");
pub const requests = @import("requests");
pub const QueryId = requests.QueryId;
pub const Query = requests.Query;
pub const Source = frontend.Source;
pub const Dialect = frontend.Dialect;
pub const Request = analysis.ExecutionConfig.Backend;
pub const Status = analysis.session.Status;
pub const Scope = analysis.session.Scope;
pub const Limits = analysis.session.Limits;
pub const Preview = analysis.session.Preview;
pub const PrintOptions = analysis.session.PrintOptions;
pub const QueryInfo = analysis.session.QueryInfo;
pub const Advance = analysis.session.Advance;
pub const Result = output.Result;
pub const Format = output.Format;
pub const Options = struct {
    source: Source,
    dialect: Dialect = .ngspice,
    output: output.Selection = .{},
    backend: analysis.ExecutionConfig = .{},
    max_parallel: u16 = 1,
    timing_in_depth: bool = false,
};

/// Serialize external calls, including reads and destruction. Retained result
/// views stay valid until deinit; copy-out is available for foreign callers.
pub const Problem = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    allocation_mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    prepared: shared.Prepared,
    source: []const u8,
    origin: []const u8,
    session: analysis.session.Session,
    delivery: output.Session,
    limits: Limits,
    next_output: usize = 0,
    delivery_error: ?anyerror = null,
    timing_in_depth: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Problem {
        var lap = if (options.timing_in_depth) std.Io.Timestamp.now(io, .awake) else null;
        if (options.max_parallel == 0) return error.InvalidConcurrency;
        try analysis.validateBackend(options.backend);
        const self = try allocator.create(Problem);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io = io;
        self.timing_in_depth = options.timing_in_depth;
        self.allocation_mutex = .init;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();
        const scratch = parse_arena.allocator();
        const input = try frontend.prepare(io, scratch, options.source, options.dialect);
        timingLap(io, &lap, "frontend (source, parsing, HDL)");
        self.source = try a.dupe(u8, input.source);
        self.origin = try a.dupe(u8, input.origin);
        self.prepared = try frontend.build(a, scratch, input.ast);
        timingLap(io, &lap, "Problem creation (expansion, binding, topology)");
        errdefer self.prepared.deinit();
        self.delivery = try output.Session.init(allocator, options.output);
        errdefer self.delivery.deinit();
        self.limits = .{ .max_parallel = options.max_parallel };
        self.next_output = 0;
        self.delivery_error = null;
        var execution = options.backend;
        execution.timing_in_depth = options.timing_in_depth;
        self.session = analysis.session.Session.init(self.workerAllocator(), io, &self.prepared, execution);
        errdefer self.session.deinit();
        const jobs = if (self.prepared.queries.len == 0)
            &[_]Query{.{ .op = .{ .tol = self.prepared.deck_tol } }}
        else
            self.prepared.queries;
        const ids = try scratch.alloc(QueryId, jobs.len);
        _ = try self.append_queries(jobs, ids);
        timingLap(io, &lap, "query graph and output setup");
        return self;
    }

    pub fn deinit(self: *Problem) void {
        const a = self.allocator;
        self.session.deinit();
        self.delivery.deinit();
        self.prepared.deinit();
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn title(self: *const Problem) []const u8 {
        return self.prepared.title;
    }

    pub fn device_count(self: *const Problem) u32 {
        return self.prepared.n_devices;
    }

    pub fn output_error(self: *const Problem) ?anyerror {
        return self.delivery_error;
    }

    pub fn query_count(self: *const Problem) u32 {
        return self.session.count();
    }

    pub fn query_info(self: *const Problem, id: QueryId) !QueryInfo {
        return self.session.info(id);
    }

    pub fn ready_queries(self: *const Problem, scope: Scope, ids: []QueryId) !usize {
        return self.session.readyQueries(scope, ids);
    }

    pub fn append_queries(self: *Problem, queries: []const Query, ids: []QueryId) !usize {
        if (ids.len < queries.len) return queries.len;
        for (queries) |query|
            try analysis.validateOutputSchema(self.allocator, &self.prepared, query, self.delivery.selection.format);
        return self.session.append(queries, ids);
    }

    /// Analysis directives only, resolved against the immutable prepared bindings.
    pub fn append_directives(self: *Problem, text: []const u8, ids: []QueryId) !usize {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const jobs = try frontend.resolveQueries(scratch.allocator(), &self.prepared, text);
        return self.append_queries(jobs, ids);
    }

    pub fn advance(self: *Problem, id: QueryId) !Advance {
        var event = try self.session.advance(id);
        self.deliver();
        event.delivery_error = self.delivery_error;
        return event;
    }

    pub fn advance_ready(self: *Problem, ids: []const QueryId, limits: Limits, events: []Advance) !usize {
        const n = try self.session.advanceReady(ids, limits, events);
        self.deliver();
        for (events[0..n]) |*event| event.delivery_error = self.delivery_error;
        return n;
    }

    pub fn run_all(self: *Problem) !void {
        var lap = if (self.timing_in_depth) std.Io.Timestamp.now(self.io, .awake) else null;
        defer timingLap(self.io, &lap, "run total (analysis, scheduling, output)");
        const ids = try self.allocator.alloc(QueryId, self.query_count());
        defer self.allocator.free(ids);
        const events = try self.allocator.alloc(Advance, @min(ids.len, self.limits.max_parallel));
        defer self.allocator.free(events);
        while (!self.session.finished()) {
            const n = try self.ready_queries(.all, ids);
            if (n == 0) return error.SchedulingFailure;
            // Select the same bounded frontier that print(run_all) marks NEXT.
            const selected = @min(n, events.len);
            _ = try self.advance_ready(ids[0..selected], self.limits, events);
        }
        self.deliver();
        if (self.session.failure()) |err| return err;
        if (self.delivery_error != null) return error.DeliveryFailed;
        var output_lap = if (self.timing_in_depth) std.Io.Timestamp.now(self.io, .awake) else null;
        defer timingLap(self.io, &output_lap, "output finish");
        try self.delivery.finish();
    }

    pub fn print(self: *const Problem, writer: *std.Io.Writer, options: PrintOptions) !void {
        var resolved = options;
        if (resolved.limits == null) resolved.limits = self.limits;
        try self.session.print(writer, resolved);
    }

    pub fn result(self: *const Problem, id: QueryId) !Result {
        return self.session.result(id);
    }

    /// Required scalar count; no partial copy when the destination is too small.
    pub fn copy_result(self: *const Problem, id: QueryId, buffer: []f64) !usize {
        const data = (try self.result(id)).data;
        if (buffer.len >= data.len) @memcpy(buffer[0..data.len], data);
        return data.len;
    }

    fn deliver(self: *Problem) void {
        if (self.delivery_error != null) return;
        while (self.next_output < self.session.outputs.items.len) {
            const id = self.session.outputs.items[self.next_output];
            const status = (self.query_info(id) catch unreachable).status;
            if (!status.terminal()) return;
            if (status == .complete) {
                const res = self.result(id) catch unreachable;
                var lap = if (self.timing_in_depth) std.Io.Timestamp.now(self.io, .awake) else null;
                defer timingLap(self.io, &lap, "output delivery");
                self.delivery.publish(self.io, self.delivery.published, .{
                    .title = self.prepared.title,
                    .plotname = res.plotname,
                    .varnames = res.varnames,
                    .is_complex = res.is_complex,
                    .npoints = res.npoints,
                    .data = res.data,
                }) catch |err| {
                    self.delivery_error = err;
                    return;
                };
            }
            self.next_output += 1;
        }
    }

    // Serialize backing allocator calls across query-owned arenas. The caller
    // need not supply a concurrent allocator just to enable parallel queries.
    fn workerAllocator(self: *Problem) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Problem = @ptrCast(@alignCast(ctx));
        self.allocation_mutex.lockUncancelable(self.io);
        defer self.allocation_mutex.unlock(self.io);
        return self.allocator.rawAlloc(n, alignment, ret);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ret: usize) bool {
        const self: *Problem = @ptrCast(@alignCast(ctx));
        self.allocation_mutex.lockUncancelable(self.io);
        defer self.allocation_mutex.unlock(self.io);
        return self.allocator.rawResize(memory, alignment, n, ret);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ret: usize) ?[*]u8 {
        const self: *Problem = @ptrCast(@alignCast(ctx));
        self.allocation_mutex.lockUncancelable(self.io);
        defer self.allocation_mutex.unlock(self.io);
        return self.allocator.rawRemap(memory, alignment, n, ret);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Problem = @ptrCast(@alignCast(ctx));
        self.allocation_mutex.lockUncancelable(self.io);
        defer self.allocation_mutex.unlock(self.io);
        self.allocator.rawFree(memory, alignment, ret);
    }
};

fn timingLap(io: std.Io, start: *?std.Io.Timestamp, label: []const u8) void {
    const before = start.* orelse return;
    const now = std.Io.Timestamp.now(io, .awake);
    const elapsed = before.durationTo(now).nanoseconds;
    std.debug.print("timing: {s}: {d:.6}ms\n", .{ label, @as(f64, @floatFromInt(elapsed)) / 1e6 });
    start.* = std.Io.Timestamp.now(io, .awake);
}
