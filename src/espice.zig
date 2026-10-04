//! The `Problem` facade: one netlist prepared once, a DAG of analysis queries
//! run over it, and their results delivered to one output. main.zig and
//! c_api.zig import only this module.
const std = @import("std");
const frontend = @import("frontend");
const analysis = @import("analysis");
const output = @import("output");
const core = @import("core");
/// Query request types (`core.query`): what `append_queries` takes.
pub const requests = core.query;
/// Dense DAG index, `0..query_count()`. Appends never renumber an ID.
pub const QueryId = requests.QueryId;
/// One analysis request; `append_queries` copies its slices.
pub const Query = requests.Query;
/// A netlist path, or in-memory text with the origin it is named by.
pub const Source = frontend.Source;
/// The netlist syntax family, which decides SPICE letter and LEVEL meaning.
pub const Dialect = frontend.Dialect;
/// Maps a CLI dialect name (`ngspice`, `hspice`, `spectre`); null if unknown.
pub const parseDialect = frontend.parseDialect;
/// Requested compute backend; `Problem.init` rejects one the build lacks; a
/// query run with an explicit cuda/hip fails when no GPU is usable.
pub const Request = analysis.ExecutionConfig.Backend;
/// A query's lifecycle state; `terminal()` says whether it can still run.
pub const Status = analysis.session.Status;
/// Which part of the DAG a call looks at: all, one query's chain, or one component.
pub const Scope = analysis.session.Scope;
/// Concurrency and quantum for one advancing call.
pub const Limits = analysis.session.Limits;
/// Which call's next frontier `print` marks.
pub const Preview = analysis.session.Preview;
/// `print` settings; a null `limits` takes the Problem's.
pub const PrintOptions = analysis.session.PrintOptions;
/// A query's kind, status, prerequisite, component and progress.
pub const QueryInfo = analysis.session.QueryInfo;
/// What one quantum did: which query ran, where it and its target stand.
pub const Advance = analysis.session.Advance;
/// A published plot. Its slices borrow Problem storage until `deinit`.
pub const Result = output.Result;
/// Output file format; some (touchstone, citi) hold only S-parameter queries.
pub const Format = output.Format;
/// Output format and path. A null path keeps results in memory only.
pub const Selection = output.Selection;
/// Maps a CLI format name (`binary`, `csv`, ...); null if unknown.
pub const parseFormat = output.parseFormat;

/// Everything `Problem.init` needs. Its slices are copied during init.
pub const Options = struct {
    source: Source,
    dialect: Dialect = .ngspice,
    /// Where results go. `.save` and `.stim` files land in its path's directory.
    output: Selection = .{},
    /// Device backend and thread counts. `final_plan` lets a lone leading
    /// transient or AC sweep stream to the output instead of being kept.
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
    /// The query whose rows stream to the output as it runs (`openStream`).
    streaming: ?QueryId = null,
    timing_in_depth: bool = false,
    /// Where an HSPICE `.save` writes the operating point; null without one.
    save_path: ?[]const u8 = null,
    /// Where `.save` and `.stim` files go: beside the output file, as HSPICE
    /// writes beside its listing.
    out_dir: []const u8 = ".",
    /// One session per `prepared.runs` entry (variants with their own
    /// topology), run after the main session by `run_all`.
    runs: []Run = &.{},
    /// The deck's file name (`Source` path or origin), which names the
    /// Touchstone files `.lin format=touchstone` writes beside it.
    origin: []const u8 = "",

    /// Holds the netlist an HSPICE optimization re-evaluates
    /// (`prepared.tuner`); null for a deck without one.
    parse_arena: ?*std.heap.ArenaAllocator = null,
    /// The finished optimizations, once `optimize` has run, one per
    /// `Tuner.bases` entry: Levenberg-Marquardt fits or bisections, as the
    /// `.model OPT` says.
    optimization: []core.lm.Lm = &.{},
    bisection: []core.bisect.Bisect = &.{},
    /// The MOSRA degradation table, once `age` has run.
    degradation: ?Result = null,

    /// A variant run's queries and its next result to publish.
    const Run = struct { session: analysis.session.Session, next_output: usize = 0 };

    /// Parses and prepares `options.source`, then queues the deck's analyses
    /// (a lone `.op` when the deck names none). Nothing runs yet.
    ///
    /// Fails on a netlist error, a backend the build lacks, zero
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
        self.optimization = &.{};
        self.bisection = &.{};
        self.degradation = null;
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
        self.save_path = null;
        self.out_dir = try a.dupe(u8, if (options.output.path) |out| std.fs.path.dirname(out) orelse "." else ".");
        if (self.prepared.deck.save_op) |save| {
            const name = save.file orelse try std.mem.concat(a, u8, &.{ std.fs.path.stem(self.origin), ".ic0" });
            self.save_path = try std.fs.path.resolve(a, &.{ self.out_dir, name });
        }
        self.delivery = try output.Session.init(allocator, options.output);
        errdefer self.delivery.deinit();
        self.limits = .{ .max_parallel = options.max_parallel };
        self.next_output = 0;
        self.delivery_error = null;
        self.streaming = null;
        var execution = options.backend;
        execution.timing_in_depth = options.timing_in_depth;
        self.session = analysis.session.Session.init(self.workerAllocator(), io, &self.prepared.circuit, &self.prepared.deck, execution);
        errdefer self.session.deinit();
        // An optimization's sessions run before this one; nothing after it
        // instantiates the template.
        self.session.last_template_reader = true;
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
            run.session.last_template_reader = true;
            errdefer run.session.deinit();
            try self.checkOutput(prep, prep.deck.queries);
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

    /// Device instances in the flattened circuit, subcircuits expanded.
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

    /// A snapshot of one query's state. `error.InvalidQuery` for an ID
    /// outside `0..query_count()`.
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
        try self.checkOutput(&self.prepared, queries);
        return self.session.append(queries, ids);
    }

    /// Refuses, before anything runs, the first of `queries` whose result
    /// the output format cannot hold over `prep`'s circuit and deck.
    fn checkOutput(self: *const Problem, prep: *const frontend.Prepared, queries: []const Query) !void {
        for (queries) |query| {
            const schema = try analysis.schemaOf(self.allocator, &prep.circuit, &prep.deck, query);
            try output.validateQuery(self.delivery.selection.format, schema, prep.deck.title, prep.deck.probe_labels);
        }
    }

    /// `append_queries` for SPICE analysis directives (`.ac dec 10 1 1meg`),
    /// resolved against the prepared circuit. A device card is
    /// `error.UnsupportedDirectiveMutation`; text with no analysis card is
    /// `error.InvalidAnalysisArguments`.
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
        try self.age();
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
        try self.age();
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
        try self.age();
        try self.openStream();
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
        if (self.save_path) |path| try self.saveOperatingPoint(path, self.prepared.deck.save_op.?);
        for (self.prepared.deck.stims) |stim| try self.writeStim(stim);
    }

    /// Writes an HSPICE `.stim` card's file from the main session's first
    /// transient: one PWL source per signal, or one `.data` table with a row
    /// per time. No transient only warns.
    fn writeStim(self: *Problem, stim: core.Stim) !void {
        const res = for (self.session.outputs.items) |id| {
            const info = try self.session.info(id);
            if (info.status == .complete and info.kind == .tran) {
                const r = try self.session.result(id);
                if (r.npoints != 0) break r;
            }
        } else {
            std.log.warn(".stim: no transient result to write", .{});
            return;
        };
        const gpa = self.allocator;
        var times: std.ArrayList(f64) = .empty;
        defer times.deinit(gpa);
        const width = res.varnames.len;
        if (stim.times.len != 0) {
            try times.appendSlice(gpa, stim.times);
        } else if (stim.npoints > 1) {
            const to = @min(stim.to, res.data[(res.npoints - 1) * width]);
            for (0..stim.npoints) |k| try times.append(gpa, stim.from + (to - stim.from) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(stim.npoints - 1)));
        } else for (0..res.npoints) |k| {
            const t = res.data[k * width];
            if (t >= stim.from and t <= stim.to) try times.append(gpa, t);
        }
        // Column-major: signal k's samples at values[k * n ..].
        const n = times.items.len;
        const values = try gpa.alloc(f64, n * stim.signals.len);
        defer gpa.free(values);
        for (stim.signals, 0..) |m, k| output.sampleMeasure(m.first, res, times.items, values[k * n ..][0..n]) catch {
            std.log.warn(".stim: no such vector for {s}", .{m.name});
            return;
        };
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        const w = &text.writer;
        try w.print("* {s}\n* written by .stim\n", .{self.prepared.deck.title});
        if (stim.data) {
            try w.print(".data {s}{s}", .{ stim.dataname, if (stim.indepout) " time" else "" });
            for (stim.signals) |m| try w.print(" {s}", .{m.name});
            for (times.items, 0..) |t, i| {
                try w.writeAll("\n+");
                if (stim.indepout) try w.print(" {e}", .{t});
                for (0..stim.signals.len) |k| try w.print(" {e}", .{values[k * n + i]});
            }
            try w.writeAll("\n.enddata\n");
        } else for (stim.signals, stim.nodes, 0..) |m, pair, k| {
            try w.print("{s} {s} {s} pwl(", .{ m.name, pair[0], pair[1] });
            for (times.items, 0..) |t, i| try w.print("\n+ {e} {e}", .{ t, values[k * n + i] });
            try w.writeAll(")\n");
        }
        const name = try std.fmt.allocPrint(gpa, "{s}.{s}{d}_tr0", .{ stim.file orelse std.fs.path.stem(self.origin), if (stim.data) "dat" else "pwl", stim.serial });
        defer gpa.free(name);
        const path = try std.fs.path.resolve(gpa, &.{ self.out_dir, name });
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = text.written() });
    }

    /// Under a final plan (the CLI), a transient or AC sweep that publishes
    /// first and that nothing reads afterwards (no `.meas` over it, no
    /// `.save` or `.stim`, no optimization) writes its rows straight to a binary raw
    /// output, or drops them without one, instead of keeping them all in
    /// memory. Its Result then has empty `data`. Plotname and columns are the
    /// ones `tran.run` and `ac.run` publish; `endStream` checks the row count.
    fn openStream(self: *Problem) !void {
        const deck = &self.prepared.deck;
        if (!self.session.config.final_plan or self.next_output != 0 or self.streaming != null) return;
        if (self.save_path != null or deck.stims.len != 0 or self.prepared.tuner != null or deck.probe_labels.len != deck.probes.len) return;
        if (self.session.outputs.items.len == 0) return;
        const id = self.session.outputs.items[0];
        if ((try self.session.info(id)).status != .pending) return;
        const job = try self.session.query(id);
        for (deck.measures) |m| if (m.analysis == job) return;
        const plotname, const scale = switch (job) {
            .tran => |o| if (o.snapshot) return else .{ "Transient Analysis", "time" },
            .ac => .{ "AC Analysis", "frequency" },
            else => return,
        };
        switch (job) {
            inline else => |o| if (o.tol.temp_c != null or o.tol.variant != null) return,
        }
        const names = try self.allocator.alloc([]const u8, deck.probe_labels.len + 1);
        defer self.allocator.free(names);
        names[0] = scale;
        @memcpy(names[1..], deck.probe_labels);
        const writer = try self.delivery.beginStream(self.io, .{ .title = deck.title, .result = .{
            .plotname = plotname,
            .varnames = names,
            .is_complex = job == .ac,
            .npoints = 0,
            .data = &.{},
        } }) orelse return;
        self.session.stream = .{ .id = id, .writer = writer };
        self.streaming = id;
    }

    /// Writes the node voltages of the main session's operating point as
    /// `.nodeset` or `.ic` cards: the first `.op` result, else row 0 of the
    /// first transient (its operating point) or DC sweep (its first point,
    /// as HSPICE saves only a sweep's first). `save.time` > 0 reads the first
    /// transient at that time, interpolated. Nothing to save only warns.
    fn saveOperatingPoint(self: *Problem, path: []const u8, save: core.SaveOp) !void {
        const found: ?struct { result: Result, row: usize, frac: f64 } = for (self.session.outputs.items) |id| {
            const info = try self.session.info(id);
            if (info.status != .complete) continue;
            const res = try self.session.result(id);
            if (res.is_complex or res.npoints == 0) continue;
            if (save.time > 0) {
                if (info.kind != .tran) continue;
                const width = res.varnames.len;
                var i: usize = 0;
                while (i + 1 < res.npoints and res.data[(i + 1) * width] < save.time) i += 1;
                if (i + 1 >= res.npoints) continue;
                const t0 = res.data[i * width];
                const t1 = res.data[(i + 1) * width];
                break .{ .result = res, .row = i, .frac = if (t1 > t0) (save.time - t0) / (t1 - t0) else 0 };
            }
            switch (info.kind) {
                .op, .tran, .dc => break .{ .result = res, .row = 0, .frac = 0 },
                else => {},
            }
        } else null;
        const op = found orelse {
            std.log.warn(".save: no {s} result to save", .{if (save.time > 0) "transient" else "operating point"});
            return;
        };
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        defer text.deinit();
        const w = &text.writer;
        try w.print("* {s}\n* operating point written by .save\n", .{self.prepared.deck.title});
        const width = op.result.varnames.len;
        for (op.result.varnames, 0..) |name, k| {
            if (!std.mem.startsWith(u8, name, "v(") or std.mem.indexOfScalar(u8, name, ',') != null) continue;
            if (save.top_only and std.mem.indexOfScalar(u8, name, '.') != null) continue;
            const v0 = op.result.data[op.row * width + k];
            const v = if (op.frac == 0) v0 else v0 + op.frac * (op.result.data[(op.row + 1) * width + k] - v0);
            try w.print("{s} {s}={e}\n", .{ if (save.ic) ".ic" else ".nodeset", name, v });
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = text.written() });
    }

    /// Writes the query DAG with the frontier `options.preview` would run
    /// next. Changes no state. A null `options.limits` uses the Problem's.
    pub fn print(self: *const Problem, writer: *std.Io.Writer, options: PrintOptions) !void {
        var resolved = options;
        if (resolved.limits == null) resolved.limits = self.limits;
        try self.session.print(writer, resolved);
    }

    /// Writes the deck's `.meas` results for every completed result a card
    /// can read (tran, AC, DC, FFT, mismatch, loop stability, phase and
    /// periodic noise), in request order, as ngspice prints them; cards that
    /// cannot be measured are reported on `err`.
    pub fn print_measures(self: *const Problem, out: *std.Io.Writer, err: *std.Io.Writer) !void {
        const measures = self.prepared.deck.measures;
        for (self.optimization, 0..) |*lm, k| try printOptimization(out, lm, self.prepared.tuner.?, k, measures);
        for (self.bisection, 0..) |*b, k| try printBisection(out, b, self.prepared.tuner.?, k, measures);
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
    /// shorter than that receives nothing; a longer one keeps its tail.
    /// `error.ResultUnavailable` until the query completes.
    pub fn copy_result(self: *const Problem, id: QueryId, buffer: []f64) !usize {
        const data = (try self.result(id)).data;
        if (buffer.len >= data.len) @memcpy(buffer[0..data.len], data);
        return data.len;
    }

    /// Runs the deck's HSPICE optimizations once, before any query advances
    /// (docs/analysis/optimize.md), one per `Tuner.bases` entry in turn.
    /// Each batch of optimizer points is one session of the optimized
    /// card's queries, a variant row per point, run `max_parallel` at a
    /// time. Each optimum's writes then fill the rows its optimized card
    /// and every later card run.
    fn optimize(self: *Problem) !void {
        const t = self.prepared.tuner orelse return;
        if (self.optimization.len != 0 or self.bisection.len != 0) return;
        const a = self.arena.allocator();
        const deck = &self.prepared.deck;
        const n = t.bases.len;
        if (t.method == .lm) self.optimization = try a.alloc(core.lm.Lm, n) else self.bisection = try a.alloc(core.bisect.Bisect, n);
        // Rows 0..n and n..2n take each base's optimum; 2n.. keep the plan's.
        const planned = deck.variants;
        var starts: std.ArrayList(u32) = .empty;
        var refs: std.ArrayList(u32) = .empty;
        var values: std.ArrayList(f64) = .empty;
        const best = try a.alloc(core.Variants, n);
        var template: std.ArrayList(Query) = .empty;
        for (best, 0..) |*row, base| {
            template.clearRetainingCapacity();
            for (deck.queries) |job| switch (job) {
                inline else => |o| if (o.tol.variant == @as(u32, @intCast(base))) try template.append(a, job),
            };
            const x: []const f64 = if (t.method == .lm) blk: {
                const lm = &self.optimization[base];
                lm.* = try core.lm.Lm.init(a, t.initial, t.spec.lo, t.spec.hi, t.spec.dels, @intCast(t.results.len), t.options);
                try self.search(t, template.items, base, lm);
                break :blk lm.x;
            } else blk: {
                const goal = deck.measures[t.results[0]];
                const c = if (goal.first.goal != null) goal.first else goal.second;
                const scale = @max(@abs(c.goal.?), c.minval) / c.weight;
                const b = &self.bisection[base];
                b.* = core.bisect.Bisect.init(a, t.method, t.spec.lo[0], t.spec.hi[0], scale, t.options);
                try self.search(t, template.items, base, b);
                break :blk (&b.x)[0..1];
            };
            row.* = try t.rows(a, &self.prepared.circuit, x, base);
        }
        try starts.append(a, 0);
        for (0..planned.starts.len - 1) |v| {
            const w_refs, const w_values = if (v < 2 * n) best[v % n].writes(0) else planned.writes(@intCast(v));
            try refs.appendSlice(a, w_refs);
            try values.appendSlice(a, w_values);
            try starts.append(a, @intCast(refs.items.len));
        }
        deck.variants.starts = starts.items;
        deck.variants.refs = refs.items;
        deck.variants.values = values.items;
    }

    /// HSPICE MOSRA, once before any query advances
    /// (docs/analysis/mosra.md): runs the stress transient with the bound
    /// MOSFETs' terminals as its only outputs, fills the aged rows'
    /// `delvto`/`mulu0` writes and publishes the degradation table.
    /// ponytail: the stress transient repeats the fresh one; fold them
    /// into one run when MOSRA decks get large.
    fn age(self: *Problem) !void {
        const m = self.prepared.deck.mosra orelse return;
        if (self.degradation != null) return;
        const a = self.arena.allocator();
        var deck = self.prepared.deck;
        const probes = try a.alloc(u32, 3 * m.terminals.len);
        for (m.terminals, 0..) |t, i| probes[3 * i ..][0..3].* = t;
        const labels = try a.alloc([]const u8, probes.len);
        @memset(labels, "");
        deck.probes = probes;
        deck.probe_labels = labels;
        var session = analysis.session.Session.init(self.workerAllocator(), self.io, &self.prepared.circuit, &deck, self.session.config);
        defer session.deinit();
        var id: [1]QueryId = undefined;
        _ = try session.append(&.{.{ .tran = m.tran }}, &id);
        try runSession(&session, self.limits.max_parallel);
        if (session.failure()) |err| return err;
        const aged = try analysis.mosra.age(a, m, try session.result(id[0]));
        if (m.aged_runs) self.prepared.deck.variants.values = aged.values;
        self.degradation = aged.table;
        try self.delivery.publish(self.io, .{ .title = deck.title, .result = aged.table });
    }

    /// Feeds `solver` (`core.lm.Lm` or `core.bisect.Bisect`) the residuals
    /// of the points it asks for until it stops.
    fn search(self: *Problem, t: *frontend.Tuner, template: []const Query, base: usize, solver: anytype) !void {
        const n = t.spec.live.len;
        const m = t.results.len;
        var residuals: std.ArrayList(f64) = .empty;
        defer residuals.deinit(self.allocator);
        while (solver.points().len != 0) {
            const points = solver.points();
            try residuals.resize(self.allocator, points.len / n * m);
            try self.evaluatePoints(t, template, base, points, residuals.items);
            try solver.feed(residuals.items);
        }
    }

    /// Residuals of each point of `points` (the optimized parameters'
    /// values, n per point, on top of `t.bases[base]`) into `out`, m per
    /// point: the RESULTS cards'
    /// goal errors over the `template` queries run at that point, NaN where
    /// a query failed or a card found no value.
    fn evaluatePoints(self: *Problem, t: *frontend.Tuner, template: []const Query, base: usize, points: []const f64, out: []f64) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const count = points.len / t.spec.live.len;
        var deck = self.prepared.deck;
        deck.variants = try t.rows(a, &self.prepared.circuit, points, base);
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
            if (session == &self.session and self.streaming == id) {
                self.streaming = null;
                if (status != .complete) self.delivery.abortStream() else {
                    const res = session.result(id) catch unreachable;
                    self.delivery.endStream(self.io, res.npoints, res.varnames.len) catch |err| {
                        self.delivery_error = err;
                        return;
                    };
                }
            } else if (status == .complete) {
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
    /// (HSPICE names it after the netlist), against the ports' own z0.
    fn writeTouchstone(self: *Problem, file: []const u8, ports: []const requests.Port, plot_in: output.Plot) !void {
        var plot = plot_in;
        // Mode impedances in sp.zig's `Basis` order: each port's first mode
        // (a balanced one's differential, 2·z0), then the common modes (z0/2).
        var z0: std.ArrayList(f64) = .empty;
        defer z0.deinit(self.allocator);
        for (ports) |p| try z0.append(self.allocator, if (p.balanced != null) 2 * p.z0 else p.z0);
        for (ports) |p| if (p.balanced != null) try z0.append(self.allocator, p.z0 / 2);
        plot.z0 = z0.items;
        const stem = if (file.len > 0) file else std.fs.path.stem(self.origin);
        const name = try std.fmt.allocPrint(self.allocator, "{s}.s{d}p", .{ stem, @max(z0.items.len, 1) });
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
            .tran, .ac, .dc, .fft, .tran_noise, .dcmatch, .acmatch, .lstb, .phasenoise, .pnoise => try output.printMeasures(out, err, measures, info.kind, try session.result(id)),
            else => {},
        }
    }
}

/// The optimizer's summary, after HSPICE's: one line per accepted
/// iteration, the stop reason, the final figures, the optimized parameters
/// and each RESULTS card's error at the optimum.
fn printOptimization(out: *std.Io.Writer, lm: *const core.lm.Lm, t: *const frontend.Tuner, base: usize, measures: []const core.Measure) !void {
    const o = t.options;
    try out.print("\n  Optimization {s} (Levenberg-Marquardt, model {s}){s}{s}\n\n  iter  evals  residual sum of squares  marquardt param", .{ t.spec.name, t.spec.model, if (t.bases[base].label.len != 0) " at " else "", t.bases[base].label });
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

/// The bisection summary: one line per midpoint test with the window it
/// halved, the stop reason, and the last passing value [SA Ch.19].
fn printBisection(out: *std.Io.Writer, b: *const core.bisect.Bisect, t: *const frontend.Tuner, base: usize, measures: []const core.Measure) !void {
    const o = t.options;
    try out.print("\n  Optimization {s} ({s}, model {s}){s}{s}\n\n  iter             xlo             xhi               x      goal error\n", .{ t.spec.name, @tagName(b.method), t.spec.model, if (t.bases[base].label.len != 0) " at " else "", t.bases[base].label });
    const h = b.history;
    for (h.lo.items, h.hi.items, h.x.items, h.r.items, 1..) |lo, hi, x, r, k|
        try out.print("  {d:>4}  {e:>14.6}  {e:>14.6}  {e:>14.6}  {e:>14.6}\n", .{ k, lo, hi, x, r });
    try out.writeAll("\n");
    switch (b.status) {
        .converged => if (o.absin > 0)
            try out.print("  optimization completed: ABSIN = {e} satisfied\n", .{o.absin})
        else if (b.method == .passfail)
            try out.print("  optimization completed: RELIN = {e} satisfied\n", .{o.relin})
        else
            try out.print("  optimization completed: RELIN = {e} and {s} = {e} satisfied\n", .{ o.relin, if (o.absout > 0) "ABSOUT" else "RELOUT", if (o.absout > 0) o.absout else o.relout }),
        .itropt => try out.print("  optimization incomplete: ITROPT = {d} iterations reached\n", .{o.itropt}),
        .bounds => try out.print("  optimization failed: both limits of {s} {s}, so they do not bracket the goal\n", .{ t.names[0], if (b.pass_hi) "pass" else "fail" }),
        .failed, .running => try out.writeAll("  optimization failed: a point could not be simulated or measured\n"),
    }
    try out.print(
        \\  no. of function evaluations   = {d}
        \\  no. of iterations             = {d}
        \\
        \\  optimized parameters {s} -- final values
        \\  {s} = {e:.6} $ last passing value, range {e:.6} to {e:.6}
        \\  error({s}) = {e:.6}
        \\
    , .{ b.evaluations, b.iterations, t.spec.name, t.names[0], b.x, t.spec.lo[0], t.spec.hi[0], measures[t.results[0]].name, b.r });
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
