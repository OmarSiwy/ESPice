//! The `Problem` facade: one netlist prepared once, a DAG of analysis queries
//! run over it, and their results delivered to one output. main.zig and
//! c_api.zig import only this module.
const std = @import("std");
const frontend = @import("frontend");
const analysis = @import("analysis");
const output = @import("output");
pub const requests = @import("core").query;
pub const QueryId = requests.QueryId;
pub const Query = requests.Query;
pub const Source = frontend.Source;
pub const Dialect = frontend.Dialect;
pub const parseDialect = frontend.parseDialect;
/// Requested compute backend; `Problem.init` rejects one the hardware lacks.
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
pub const Selection = output.Selection;
pub const parseFormat = output.parseFormat;

/// Everything `Problem.init` needs. Its slices are copied during init.
pub const Options = struct {
    source: Source,
    dialect: Dialect = .ngspice,
    output: Selection = .{},
    backend: analysis.ExecutionConfig = .{},
    /// Queries `run_all` advances concurrently. Zero is `error.InvalidConcurrency`.
    max_parallel: u16 = 1,
    /// Print per-phase wall times to stderr.
    timing_in_depth: bool = false,
};

/// A prepared circuit, its query DAG and the output its results go to.
///
/// Not thread-safe: the caller serializes every call, reads and `deinit`
/// included. Parallelism lives inside `advance_ready` and `run_all`. Result
/// slices stay valid until `deinit`; `copy_result` copies for callers that
/// cannot hold them.
pub const Problem = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Serializes `allocator` for query workers; see `workerAllocator`.
    allocation_mutex: std.Io.Mutex = .init,
    /// Owns the prepared circuit and deck for the Problem's lifetime.
    arena: std.heap.ArenaAllocator,
    /// Every device type this problem can instantiate; outlives `prepared`.
    library: frontend.Library,
    prepared: frontend.Prepared,
    session: analysis.session.Session,
    delivery: output.Session,
    limits: Limits,
    /// Index into `session.outputs` of the next result to publish. Results
    /// publish in request order, so a finished query waits for earlier ones.
    next_output: usize = 0,
    /// First output failure. Once set, nothing else is published.
    delivery_error: ?anyerror = null,
    timing_in_depth: bool = false,

    /// Parses and prepares `options.source`, then queues the deck's analyses
    /// (a lone `.op` when the deck names none). Nothing runs yet.
    ///
    /// Fails on a netlist error, a backend the hardware lacks, zero
    /// `max_parallel`, or a query the output format cannot hold. The caller
    /// frees the result with `deinit`.
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
        self.library = try frontend.Library.init(allocator);
        errdefer self.library.deinit();
        const ast = try frontend.prepare(io, &self.library, scratch, options.source, options.dialect);
        timingLap(io, &lap, "frontend (source, parsing, HDL)");
        self.prepared = try frontend.build(&self.library, a, scratch, ast);
        timingLap(io, &lap, "Problem creation (expansion, binding, topology)");
        errdefer self.prepared.deinit();
        self.delivery = try output.Session.init(allocator, options.output);
        errdefer self.delivery.deinit();
        self.limits = .{ .max_parallel = options.max_parallel };
        self.next_output = 0;
        self.delivery_error = null;
        var execution = options.backend;
        execution.timing_in_depth = options.timing_in_depth;
        self.session = analysis.session.Session.init(self.workerAllocator(), io, &self.prepared.circuit, &self.prepared.deck, execution);
        errdefer self.session.deinit();
        const jobs = if (self.prepared.deck.queries.len == 0)
            &[_]Query{.{ .op = .{ .tol = self.prepared.deck.deck_tol } }}
        else
            self.prepared.deck.queries;
        const ids = try scratch.alloc(QueryId, jobs.len);
        _ = try self.append_queries(jobs, ids);
        timingLap(io, &lap, "query graph and output setup");
        return self;
    }

    /// Cancels and joins any paused query workers, then frees everything.
    /// Invalidates every result slice handed out.
    pub fn deinit(self: *Problem) void {
        const a = self.allocator;
        self.session.deinit();
        self.delivery.deinit();
        self.prepared.deinit();
        self.library.deinit();
        self.arena.deinit();
        a.destroy(self);
    }

    /// The deck's title line.
    pub fn title(self: *const Problem) []const u8 {
        return self.prepared.deck.title;
    }

    pub fn device_count(self: *const Problem) u32 {
        return self.prepared.deck.n_devices;
    }

    /// The output failure that stopped publication, if any.
    pub fn output_error(self: *const Problem) ?anyerror {
        return self.delivery_error;
    }

    /// Queries in the DAG, prerequisites included. IDs run `0..query_count()`.
    pub fn query_count(self: *const Problem) u32 {
        return self.session.count();
    }

    pub fn query_info(self: *const Problem, id: QueryId) !QueryInfo {
        return self.session.info(id);
    }

    /// Writes the queries in `scope` that can advance now into `ids` and
    /// returns how many there are. If that exceeds `ids.len`, `ids` is untouched.
    pub fn ready_queries(self: *const Problem, scope: Scope, ids: []QueryId) !usize {
        return self.session.readyQueries(scope, ids);
    }

    /// Adds `queries` and their prerequisites to the DAG, writing each one's
    /// ID into `ids`. Returns `queries.len`.
    ///
    /// When `ids` is too short this is a sizing call: nothing is validated or
    /// added. Otherwise the append is all-or-nothing: a query the output
    /// format cannot hold, or any other failure, leaves the DAG and `ids`
    /// unchanged. An existing identical query returns its old ID.
    pub fn append_queries(self: *Problem, queries: []const Query, ids: []QueryId) !usize {
        if (ids.len < queries.len) return queries.len;
        const deck = &self.prepared.deck;
        for (queries) |query|
            try output.validateQuery(self.delivery.selection.format, try analysis.schemaOf(self.allocator, &self.prepared.circuit, deck, query), deck.title, deck.probe_labels);
        return self.session.append(queries, ids);
    }

    /// `append_queries` for SPICE analysis directives (`.ac dec 10 1 1meg`),
    /// resolved against the prepared circuit. A device card is
    /// `error.UnsupportedDirectiveMutation`.
    pub fn append_directives(self: *Problem, text: []const u8, ids: []QueryId) !usize {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const jobs = try frontend.resolveQueries(scratch.allocator(), &self.prepared, text);
        return self.append_queries(jobs, ids);
    }

    /// Runs one quantum of `id`, or of its first unfinished prerequisite, then
    /// publishes whatever completed. A numerical failure is reported in the
    /// event, not as an error.
    pub fn advance(self: *Problem, id: QueryId) !Advance {
        var event = try self.session.advance(id);
        self.deliver();
        event.delivery_error = self.delivery_error;
        return event;
    }

    /// Advances every query in `ids` by one quantum, up to
    /// `limits.max_parallel` at a time, writing one event per query.
    /// `ids` must be ready and distinct; a bad frontier starts nothing.
    pub fn advance_ready(self: *Problem, ids: []const QueryId, limits: Limits, events: []Advance) !usize {
        const n = try self.session.advanceReady(ids, limits, events);
        self.deliver();
        for (events[0..n]) |*event| event.delivery_error = self.delivery_error;
        return n;
    }

    /// Runs every query to completion, publishes the results and finishes
    /// the output. Returns the first query failure, else
    /// `error.DeliveryFailed` if output failed. Calling it again is a no-op
    /// for finished queries and publishes nothing twice.
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
            // The same bounded frontier `print` marks NEXT for a run_all preview.
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

    /// Writes the query DAG with the frontier `options.preview` would run
    /// next. Changes no state. A null `options.limits` uses the Problem's.
    pub fn print(self: *const Problem, writer: *std.Io.Writer, options: PrintOptions) !void {
        var resolved = options;
        if (resolved.limits == null) resolved.limits = self.limits;
        try self.session.print(writer, resolved);
    }

    /// A completed query's result, valid until `deinit`.
    /// `error.ResultUnavailable` until the query completes.
    pub fn result(self: *const Problem, id: QueryId) !Result {
        return self.session.result(id);
    }

    /// Copies a result's data into `buffer` and returns its length. A buffer
    /// shorter than that receives nothing.
    pub fn copy_result(self: *const Problem, id: QueryId, buffer: []f64) !usize {
        const data = (try self.result(id)).data;
        if (buffer.len >= data.len) @memcpy(buffer[0..data.len], data);
        return data.len;
    }

    /// Publishes completed results in request order, stopping at the first
    /// unfinished query or the first output failure.
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
                self.delivery.publish(self.io, .{ .title = self.prepared.deck.title, .result = res }) catch |err| {
                    self.delivery_error = err;
                    return;
                };
            }
            self.next_output += 1;
        }
    }

    /// `allocator` behind a mutex, so parallel query arenas can share it
    /// without the caller having to supply a thread-safe allocator.
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

/// Prints the time since `start.*` under `label` and restarts the lap.
/// A null `start` means timing is off.
fn timingLap(io: std.Io, start: *?std.Io.Timestamp, label: []const u8) void {
    const before = start.* orelse return;
    const now = std.Io.Timestamp.now(io, .awake);
    const elapsed = before.durationTo(now).nanoseconds;
    std.debug.print("timing: {s}: {d:.6}ms\n", .{ label, @as(f64, @floatFromInt(elapsed)) / 1e6 });
    start.* = std.Io.Timestamp.now(io, .awake);
}
