//! The `Problem` facade: one netlist prepared once, a DAG of analysis queries
//! run over it, and their results delivered to one output. main.zig and
//! c_api.zig import only this module.
const std = @import("std");
const frontend = @import("frontend");
const analysis = @import("analysis");
const output = @import("output");
const core = @import("core");
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
    /// One session per `prepared.runs` entry (variants with their own
    /// topology), run after the main session by `run_all`.
    runs: []Run = &.{},
    /// The deck's file name (`Source` path or origin), which names the
    /// Touchstone files `.lin format=touchstone` writes beside it.
    origin: []const u8 = "",

    /// Holds the netlist an HSPICE optimization re-evaluates
    /// (`prepared.tuner`); null for a deck without one.
    parse_arena: ?*std.heap.ArenaAllocator = null,
    /// The finished optimization, once `optimize` has run.
    optimization: ?core.lm.Lm = null,

    /// A variant run's queries and its next result to publish.
    const Run = struct { session: analysis.session.Session, next_output: usize = 0 };

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
        self.origin = try a.dupe(u8, switch (options.source) {
            .file => |path| path,
            .bytes => |bytes| bytes.origin,
        });
        self.parse_arena = null;
        self.optimization = null;
        // An optimization keeps the parse arena: its tuner re-evaluates the netlist.
        const parse_arena = try allocator.create(std.heap.ArenaAllocator);
        parse_arena.* = .init(allocator);
        defer if (self.parse_arena == null) {
            parse_arena.deinit();
            allocator.destroy(parse_arena);
        };
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
        self.runs = try a.alloc(Run, self.prepared.runs.len);
        for (self.runs, self.prepared.runs, 0..) |*run, *prep, k| {
            errdefer for (self.runs[0..k]) |*done| done.session.deinit();
            run.* = .{ .session = analysis.session.Session.init(self.workerAllocator(), io, &prep.circuit, &prep.deck, execution) };
            errdefer run.session.deinit();
            for (prep.deck.queries) |query|
                try output.validateQuery(self.delivery.selection.format, try analysis.schemaOf(self.allocator, &prep.circuit, &prep.deck, query), prep.deck.title, prep.deck.probe_labels);
            _ = try run.session.append(prep.deck.queries, try scratch.alloc(QueryId, prep.deck.queries.len));
        }
        timingLap(io, &lap, "query graph and output setup");
        if (self.prepared.tuner != null) self.parse_arena = parse_arena;
        return self;
    }

    /// Cancels and joins any paused query workers, then frees everything.
    /// Invalidates every result slice handed out.
    pub fn deinit(self: *Problem) void {
        const a = self.allocator;
        for (self.runs) |*run| run.session.deinit();
        self.session.deinit();
        self.delivery.deinit();
        self.prepared.deinit();
        self.library.deinit();
        if (self.parse_arena) |arena| {
            arena.deinit();
            a.destroy(arena);
        }
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

    /// True once every requested query has ended, completed or not: the
    /// stop condition of a stepping loop over `ready_queries`.
    pub fn finished(self: *const Problem) bool {
        return self.session.finished();
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
        try self.optimize();
        var event = try self.session.advance(id);
        self.deliver();
        event.delivery_error = self.delivery_error;
        return event;
    }

    /// Advances every query in `ids` by one quantum, up to
    /// `limits.max_parallel` at a time, writing one event per query.
    /// `ids` must be ready and distinct; a bad frontier starts nothing.
    pub fn advance_ready(self: *Problem, ids: []const QueryId, limits: Limits, events: []Advance) !usize {
        try self.optimize();
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
        try self.optimize();
        const ids = try self.allocator.alloc(QueryId, self.query_count());
        defer self.allocator.free(ids);
        const events = try self.allocator.alloc(Advance, @min(ids.len, self.limits.max_parallel));
        defer self.allocator.free(events);
        while (!self.finished()) {
            const n = try self.ready_queries(.all, ids);
            if (n == 0) return error.SchedulingFailure;
            // The same bounded frontier `print` marks NEXT for a run_all preview.
            const selected = @min(n, events.len);
            // Whole-query quanta: nothing here reads intermediate progress,
            // except the in-depth timing, which reports per checkpoint.
            const quantum: Limits = .{ .max_parallel = self.limits.max_parallel, .quantum = if (self.timing_in_depth) .checkpoint else .completion };
            _ = try self.advance_ready(ids[0..selected], quantum, events);
        }
        self.deliver();
        for (self.runs) |*run| {
            try runSession(&run.session, self.limits.max_parallel);
            self.deliverFrom(&run.session, &run.next_output, run.session.deck.title);
        }
        if (self.session.failure()) |err| return err;
        for (self.runs) |*run| if (run.session.failure()) |err| return err;
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

    /// Writes the deck's `.meas` results for every completed tran, AC, DC
    /// and FFT result, in request order, as ngspice prints them; cards that
    /// cannot be measured are reported on `err`.
    pub fn print_measures(self: *const Problem, out: *std.Io.Writer, err: *std.Io.Writer) !void {
        const measures = self.prepared.deck.measures;
        if (self.optimization) |*lm| try printOptimization(out, lm, self.prepared.tuner.?, measures);
        if (measures.len == 0) return;
        try printSessionMeasures(&self.session, out, err, measures);
        for (self.runs) |*run| try printSessionMeasures(&run.session, out, err, measures);
        // Statistics over the Monte Carlo trials of each analysis kind.
        var trials: std.ArrayList(Result) = .empty;
        defer trials.deinit(self.allocator);
        inline for (.{ .tran, .ac, .dc }) |kind| {
            trials.clearRetainingCapacity();
            try monteTrials(self.allocator, &self.session, kind, &trials);
            for (self.runs) |*run| try monteTrials(self.allocator, &run.session, kind, &trials);
            if (trials.items.len != 0) try output.printMeasureStatistics(out, measures, kind, trials.items);
        }
    }

    /// The completed results of the variant runs with their own topology
    /// (an `.alter` that swaps elements, a point that collapses a node), in
    /// output order. The caller frees the slice with `gpa`; the results stay
    /// valid until `deinit`.
    pub fn run_results(self: *const Problem, gpa: std.mem.Allocator) ![]Result {
        var list: std.ArrayList(Result) = .empty;
        errdefer list.deinit(gpa);
        for (self.runs) |*run| for (run.session.outputs.items) |id| {
            if ((try run.session.info(id)).status == .complete) try list.append(gpa, try run.session.result(id));
        };
        return list.toOwnedSlice(gpa);
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

    /// Runs the deck's HSPICE optimization once, before any query advances
    /// (docs/analysis/optimize.md). Each batch of optimizer points is one
    /// session of the optimized card's queries, a variant row per point,
    /// run `max_parallel` at a time. The optimum's writes then fill the
    /// rows the optimized card and every later card run.
    fn optimize(self: *Problem) !void {
        const t = self.prepared.tuner orelse return;
        if (self.optimization != null) return;
        const a = self.arena.allocator();
        const deck = &self.prepared.deck;
        var template: std.ArrayList(Query) = .empty;
        for (deck.queries) |job| switch (job) {
            inline else => |o| if (o.tol.variant == 0) try template.append(a, job),
        };
        var lm = try core.lm.Lm.init(a, t.initial, t.spec.lo, t.spec.hi, t.spec.dels, @intCast(t.results.len), t.options);
        const residuals = try a.alloc(f64, @as(usize, @max(lm.n, 1)) * lm.m);
        while (lm.points().len != 0) {
            const points = lm.points();
            const out = residuals[0 .. points.len / lm.n * lm.m];
            try self.evaluatePoints(t, template.items, points, out);
            try lm.feed(out);
        }
        const best = try t.rows(a, &self.prepared.circuit, lm.x);
        const refs, const values = best.writes(0);
        deck.variants.starts = try a.dupe(u32, &.{ 0, @intCast(refs.len), @intCast(2 * refs.len) });
        deck.variants.refs = try std.mem.concat(a, u32, &.{ refs, refs });
        deck.variants.values = try std.mem.concat(a, f64, &.{ values, values });
        self.optimization = lm;
    }

    /// Residuals of each point of `points` (the optimized parameters'
    /// values, n per point) into `out`, m per point: the RESULTS cards'
    /// goal errors over the `template` queries run at that point, NaN where
    /// a query failed or a card found no value.
    fn evaluatePoints(self: *Problem, t: *frontend.Tuner, template: []const Query, points: []const f64, out: []f64) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const count = points.len / t.spec.live.len;
        var deck = self.prepared.deck;
        deck.variants = try t.rows(a, &self.prepared.circuit, points);
        const jobs = try a.alloc(Query, count * template.len);
        for (0..count) |p| for (template, jobs[p * template.len ..][0..template.len]) |job, *copy| {
            copy.* = job;
            switch (copy.*) {
                inline else => |*o| o.tol.variant = @intCast(p),
            }
        };
        var session = analysis.session.Session.init(self.workerAllocator(), self.io, &self.prepared.circuit, &deck, self.session.config);
        defer session.deinit();
        const ids = try a.alloc(QueryId, jobs.len);
        _ = try session.append(jobs, ids);
        try runSession(&session, self.limits.max_parallel);
        const values = try a.alloc(f64, deck.measures.len);
        const m = t.results.len;
        @memset(out, std.math.nan(f64));
        for (0..count) |p| for (ids[p * template.len ..][0..template.len]) |id| {
            const info = try session.info(id);
            if (info.status != .complete) continue;
            output.measureValues(deck.measures, info.kind, try session.result(id), values);
            for (t.results, out[p * m ..][0..m]) |card, *r| {
                const measure = deck.measures[card];
                if (measure.analysis == info.kind) r.* = measure.goalError(values[card]).?;
            }
        };
    }

    /// Publishes completed results in request order, stopping at the first
    /// unfinished query or the first output failure.
    fn deliver(self: *Problem) void {
        self.deliverFrom(&self.session, &self.next_output, self.prepared.deck.title);
    }

    fn deliverFrom(self: *Problem, session: *const analysis.session.Session, next_output: *usize, deck_title: []const u8) void {
        if (self.delivery_error != null) return;
        while (next_output.* < session.outputs.items.len) {
            const id = session.outputs.items[next_output.*];
            const status = (session.info(id) catch unreachable).status;
            if (!status.terminal()) return;
            if (status == .complete) {
                const res = session.result(id) catch unreachable;
                var lap = if (self.timing_in_depth) std.Io.Timestamp.now(self.io, .awake) else null;
                defer timingLap(self.io, &lap, "output delivery");
                self.delivery.publish(self.io, .{ .title = deck_title, .result = res }) catch |err| {
                    self.delivery_error = err;
                    return;
                };
                const job = session.query(id) catch unreachable;
                if (job == .sp) if (job.sp.lin) |lin| if (lin.touchstone)
                    self.writeTouchstone(lin.file, job.sp.ports, .{ .title = deck_title, .result = res }) catch |err| {
                        self.delivery_error = err;
                        return;
                    };
            }
            next_output.* += 1;
        }
    }

    /// Writes a `.lin format=touchstone` result as `<file>.s<N>p` beside the
    /// deck, `file` defaulting to the deck's name without its extension
    /// (HSPICE names it after the netlist). The writer's header states a
    /// 50 ohm reference, so another port z0 is
    /// `error.UnsupportedReferenceImpedance`.
    fn writeTouchstone(self: *Problem, file: []const u8, ports: []const requests.Port, plot: output.Plot) !void {
        for (ports) |p| if (p.z0 != 50) return error.UnsupportedReferenceImpedance;
        const stem = if (file.len > 0) file else std.fs.path.stem(self.origin);
        const name = try std.fmt.allocPrint(self.allocator, "{s}.s{d}p", .{ stem, @max(ports.len, 1) });
        defer self.allocator.free(name);
        const path = try std.fs.path.join(self.allocator, &.{ std.fs.path.dirname(self.origin) orelse ".", name });
        defer self.allocator.free(path);
        try output.write(self.io, path, .touchstone, plot);
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

/// Runs every query of a variant run's session to completion, whole
/// queries at a time.
fn runSession(session: *analysis.session.Session, max_parallel: u16) !void {
    const gpa = session.allocator;
    const ids = try gpa.alloc(QueryId, session.count());
    defer gpa.free(ids);
    const events = try gpa.alloc(Advance, @max(1, @min(ids.len, max_parallel)));
    defer gpa.free(events);
    while (!session.finished()) {
        const n = try session.readyQueries(.all, ids);
        if (n == 0) return error.SchedulingFailure;
        _ = try session.advanceReady(ids[0..@min(n, events.len)], .{ .max_parallel = max_parallel, .quantum = .completion }, events);
    }
}

/// Appends `session`'s completed Monte Carlo trial results of `kind`.
fn monteTrials(gpa: std.mem.Allocator, session: *const analysis.session.Session, kind: requests.Kind, trials: *std.ArrayList(Result)) !void {
    for (session.outputs.items) |id| {
        const info = try session.info(id);
        if (info.status != .complete or info.kind != kind) continue;
        const res = try session.result(id);
        if (std.mem.indexOf(u8, res.plotname, "(monte=") != null) try trials.append(gpa, res);
    }
}

/// `.meas` results over one session's completed tran, AC and DC results.
fn printSessionMeasures(session: *const analysis.session.Session, out: *std.Io.Writer, err: *std.Io.Writer, measures: []const @import("core").Measure) !void {
    for (session.outputs.items) |id| {
        const info = try session.info(id);
        if (info.status != .complete) continue;
        switch (info.kind) {
            .tran, .ac, .dc, .fft, .tran_noise => try output.printMeasures(out, err, measures, info.kind, try session.result(id)),
            else => {},
        }
    }
}

/// The optimizer's summary, after HSPICE's: one line per accepted
/// iteration, the stop reason, the final figures, the optimized parameters
/// and each RESULTS card's error at the optimum.
fn printOptimization(out: *std.Io.Writer, lm: *const core.lm.Lm, t: *const frontend.Tuner, measures: []const core.Measure) !void {
    const o = t.options;
    try out.print("\n  Optimization {s} (Levenberg-Marquardt, model {s})\n\n  iter  evals  residual sum of squares  marquardt param", .{ t.spec.name, t.spec.model });
    for (t.names) |name| try out.print("  {s:>14}", .{name});
    try out.writeAll("\n");
    const h = lm.history;
    for (h.rss.items, h.lambda.items, h.evaluations.items, 0..) |rss, lambda, evals, k| {
        try out.print("  {d:>4}  {d:>5}  {e:>23.6}  {e:>15.6}", .{ k, evals, rss, lambda });
        for (h.x.items[k * lm.n ..][0..lm.n]) |x| try out.print("  {e:>14.6}", .{x});
        try out.writeAll("\n");
    }
    try out.writeAll("\n");
    var pinned = false;
    for (0..lm.n) |j| pinned = pinned or lm.pinned(j) != 0;
    if (lm.status != .failed and pinned) {
        try out.writeAll("  optimization stopped at a limit: the goals are not reachable inside the parameter ranges\n");
    } else switch (lm.status) {
        .relin => try out.print("  optimization completed: RELIN = {e} on last iteration\n", .{o.relin}),
        .relout => try out.print("  optimization completed: RELOUT = {e} on last iteration\n", .{o.relout}),
        .grad => try out.print("  optimization completed: norm of the gradient < GRAD = {e}\n", .{o.grad}),
        .itropt => try out.print("  optimization incomplete: ITROPT = {d} iterations reached\n", .{o.itropt}),
        .max => try out.print("  optimization stopped: marquardt parameter above MAX = {e}\n", .{o.max}),
        .failed, .running => try out.writeAll("  optimization failed: a point could not be simulated or measured\n"),
    }
    for (t.names, 0..) |name, j| switch (lm.pinned(j)) {
        -1 => try out.print("  {s} is held at its lower limit {e:.6}\n", .{ name, lm.lo[j] }),
        1 => try out.print("  {s} is held at its upper limit {e:.6}\n", .{ name, lm.hi[j] }),
        else => {},
    };
    try out.print(
        \\  residual sum of squares       = {e:.6}
        \\  norm of the gradient          = {e:.6}
        \\  marquardt scaling parameter   = {e:.6}
        \\  no. of function evaluations   = {d}
        \\  no. of iterations             = {d}
        \\
        \\  optimized parameters {s} -- final values
        \\
    , .{ lm.rss, lm.gradientNorm(), lm.lambda, lm.evaluations, lm.iterations, t.spec.name });
    for (t.names, lm.x, t.initial, lm.lo, lm.hi) |name, x, x0, lo, hi|
        try out.print("  {s} = {e:.6} $ initial {e:.6}, range {e:.6} to {e:.6}\n", .{ name, x, x0, lo, hi });
    try out.writeAll("\n  goal errors at the optimum (weight * (result - goal) / max(|goal|, minval))\n");
    for (t.results, lm.r) |card, r| try out.print("  error({s}) = {e:.6}\n", .{ measures[card].name, r });
}

/// Prints the time since `start.*` under `label` and restarts the lap.
/// A null `start` means timing is off.
fn timingLap(io: std.Io, start: *?std.Io.Timestamp, label: []const u8) void {
    const before = start.* orelse return;
    const now = std.Io.Timestamp.now(io, .awake);
    const elapsed = before.durationTo(now).nanoseconds;
    std.debug.print("timing: {s}: {d:.6}ms\n", .{ label, @as(f64, @floatFromInt(elapsed)) / 1e6 });
    start.* = std.Io.Timestamp.now(io, .awake);
}
