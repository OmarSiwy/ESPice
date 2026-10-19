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
    /// The Zig compiler and `share/espice` directory a `.hdl` model builds
    /// with; null fields read `$ZIG` and the executable's path (#13).
    hdl_toolchain: HdlToolchain = .{},
    /// Global `.param` names `set_params` may change later. Each stays live
    /// through the build, as a `.step` name does, so a name an analysis
    /// card, `.meas`, `.ic` or `.options` reads is `error.UnsupportedCard`,
    /// and one no `.param` defines is `error.UnknownParameter`.
    live_params: []const []const u8 = &.{},
    /// Where `.hdl` display-task lines (`$strobe`, `$display`, ...) go; null
    /// prints them on stdout. Each accepted point's lines arrive in one
    /// `writeAll` from the thread running its query; with `max_parallel`
    /// above 1 that is several threads at once, so the writer must
    /// serialize them. It must outlive the Problem.
    display: ?*std.Io.Writer = null,
    /// VPI applications (LRM 12.33) to load before the deck's `.hdl` models,
    /// as given; the deck may add more with `.options vpi=`. They need `vpi`.
    vpi_apps: []const []const u8 = &.{},
    /// The VPI host that loads them, which the espice executable supplies;
    /// null in an embedding, where any application is `VpiUnavailable`.
    /// It must outlive the Problem.
    vpi: ?*const Vpi = null,
};

/// The VPI host interface (`Options.vpi`) and its errors.
pub const Vpi = frontend.Library.Vpi;
pub const VpiError = frontend.Library.VpiError;
pub const VpiAnalogPoint = frontend.Library.AnalogPoint;
pub const VpiVerdict = frontend.Library.Verdict;

/// Why publication stopped (`Problem.output_error`): an encoder or file
/// error from the output session (`publish`, `endStream`, `finish`) or the Touchstone
/// file writer (`output.write`), `error.OutOfMemory` included. The session
/// lookups' `error.InvalidQuery` and `error.ResultUnavailable` mean the
/// query bookkeeping broke (a bug), reported instead of a panic.
pub const DeliveryError = errorOf(output.Session.publish) || errorOf(output.Session.endStream) || errorOf(output.Session.finish) || errorOf(output.write) ||
    errorOf(analysis.session.Session.info) || errorOf(analysis.session.Session.result) || errorOf(analysis.session.Session.query);

fn errorOf(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.error_set;
}

/// Where runtime `.hdl` compilation finds its toolchain (`Options.hdl_toolchain`).
pub const HdlToolchain = frontend.Library.Toolchain;

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
    delivery_error: ?DeliveryError = null,
    /// The query whose rows stream to the output as it runs (`openStream`).
    streaming: ?QueryId = null,
    /// The variant row `set_params` last made, which queries appended
    /// since then run at; null before any call.
    variant: ?u32 = null,
    /// `Options.live_params` as live slots (`Tuning.index`), resolved once
    /// so a point of `append_points` costs no name lookups.
    live: []const u32 = &.{},
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
    parse_arena: ?std.heap.ArenaAllocator = null,
    /// The finished optimizations, once `optimize` has run, one per
    /// `Tuner.bases` entry: Levenberg-Marquardt fits or bisections, as the
    /// `.model OPT` says.
    optimization: []core.lm.Lm = &.{},
    bisection: []core.bisect.Bisect = &.{},
    /// The MOSRA degradation table, once `age` has run.
    degradation: ?Result = null,
    /// Whether a query of this Problem brought the GPU driver up, which every
    /// session's queries read through `ExecutionConfig.gpu_driver`.
    gpu_driver: analysis.GpuDriver = .{},

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
        self.optimization = &.{};
        self.bisection = &.{};
        self.degradation = null;
        // An optimization keeps the parse arena: its tuner re-evaluates the netlist.
        // `self` is heap-allocated, so the arena keeps its address.
        self.parse_arena = .init(allocator);
        var keep_parse = false;
        defer if (!keep_parse) {
            self.parse_arena.?.deinit();
            self.parse_arena = null;
        };
        const scratch = self.parse_arena.?.allocator();
        self.library = try frontend.Library.init(allocator);
        errdefer self.library.deinit();
        self.library.toolchain = try toolchainFromEnv(a, options.hdl_toolchain);
        self.library.vpi = options.vpi;
        const ast = try frontend.prepare(io, scratch, options.source, options.dialect, options.live_params);
        try frontend.loadModels(io, &self.library, scratch, ast, self.origin, options.vpi_apps);
        timingLap(io, &lap, "frontend (source, parsing, HDL)");
        self.prepared = try frontend.build(&self.library, a, scratch, ast);
        timingLap(io, &lap, "Problem creation (expansion, binding, topology)");
        errdefer self.prepared.deinit();
        self.live = &.{};
        if (self.prepared.tuning) |t| {
            const live = try a.alloc(u32, options.live_params.len);
            for (options.live_params, live) |name, *k| k.* = try t.index(name);
            self.live = live;
        }
        self.save_path = null;
        self.out_dir = try a.dupe(u8, if (options.output.path) |out| std.fs.path.dirname(out) orelse "." else ".");
        if (self.prepared.deck.save_op) |save| {
            // `FILE=x.ic` names the `.ic#` family (one file per `.alter` run in
            // HSPICE); ESPice writes `#` = 0, which `.load FILE=x.ic` reads.
            const name = if (save.file) |f|
                try std.mem.concat(a, u8, &.{ f, if (std.ascii.eqlIgnoreCase(std.fs.path.extension(f), ".ic")) "0" else "" })
            else
                try std.mem.concat(a, u8, &.{ std.fs.path.stem(self.origin), ".ic0" });
            self.save_path = try std.fs.path.resolve(a, &.{ self.out_dir, name });
        }
        self.delivery = try output.Session.init(allocator, options.output);
        errdefer self.delivery.deinit();
        self.limits = .{ .max_parallel = options.max_parallel };
        self.next_output = 0;
        self.delivery_error = null;
        self.streaming = null;
        self.variant = null;
        var execution = options.backend;
        execution.timing_in_depth = options.timing_in_depth;
        execution.knobs = knobsFromEnv();
        self.gpu_driver = .{};
        execution.gpu_driver = &self.gpu_driver;
        if (analysis.gpu_available and execution.backend != .cpu) raiseJitCache();
        execution.display = options.display;
        self.session = analysis.session.Session.init(self.workerAllocator(), io, &self.prepared.circuit, &self.prepared.deck, execution);
        errdefer self.session.deinit();
        // An optimization's sessions run before this one; nothing after it
        // instantiates the template.
        // `set_params` diffs later points against the template, so it is
        // never handed to a query to keep.
        if (self.prepared.tuning == null) self.session.markLastTemplateReader();
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
            run.session.markLastTemplateReader();
            errdefer run.session.deinit();
            try self.checkOutput(prep, prep.deck.queries);
            _ = try run.session.append(prep.deck.queries, try scratch.alloc(QueryId, prep.deck.queries.len));
        }
        timingLap(io, &lap, "query graph and output setup");
        keep_parse = self.prepared.tuner != null or self.prepared.tuning != null;
        return self;
    }

    /// Cancels and joins any paused query workers, then frees everything.
    /// Invalidates every result slice handed out. A Problem destroyed
    /// before its last query ended drops the plots published into binary
    /// or ASCII raw or `.print`, and the file keeps its old bytes.
    pub fn deinit(self: *Problem) void {
        const a = self.allocator;
        for (self.runs) |*run| run.session.deinit();
        self.session.deinit();
        self.delivery.deinit();
        self.prepared.deinit();
        self.library.deinit();
        if (self.parse_arena) |*arena| arena.deinit();
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
    pub fn output_error(self: *const Problem) ?DeliveryError {
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

    /// How many queries in `scope` can advance now: the length
    /// `ready_queries` needs.
    pub fn ready_count(self: *const Problem, scope: Scope) !usize {
        return self.session.readyCount(scope);
    }

    /// Writes the queries in `scope` that can advance now into `ids` and
    /// returns how many there are. Fails with `error.BufferTooSmall`, `ids`
    /// untouched, when `ids` is shorter than `ready_count`.
    pub fn ready_queries(self: *const Problem, scope: Scope, ids: []QueryId) !usize {
        return self.session.readyQueries(scope, ids);
    }

    /// Adds `queries` and their prerequisites to the DAG, writing each one's
    /// ID into `ids`. Returns `queries.len`.
    ///
    /// When `ids` is too short this is a sizing call: nothing is validated or
    /// added. Otherwise the append is all-or-nothing: a query the output
    /// format cannot hold, or any other failure, leaves the DAG and `ids`
    /// unchanged. An existing identical query returns its old ID. After
    /// `set_params`, a query that names no variant of its own runs at the
    /// values the last call set.
    pub fn append_queries(self: *Problem, queries: []const Query, ids: []QueryId) !usize {
        if (ids.len < queries.len) return queries.len;
        const jobs: []const Query = if (self.variant) |v| blk: {
            const copy = try self.allocator.dupe(Query, queries);
            for (copy) |*q| switch (q.*) {
                inline else => |*o| if (o.tol.variant == null) {
                    o.tol.variant = v;
                },
            };
            break :blk copy;
        } else queries;
        defer if (self.variant != null) self.allocator.free(jobs);
        try self.checkOutput(&self.prepared, jobs);
        return self.session.append(jobs, ids);
    }

    /// Sets each global `.param` in `names` to the matching value for
    /// every query appended afterwards; the others keep their last values.
    /// Queries appended earlier, finished or not, keep the values they were
    /// appended with, so a sizing loop appends its analyses again after
    /// each call (their plots are named `<plot> (<name>=<value>, ...)`).
    ///
    /// Nothing is re-parsed: the point is re-evaluated from the prepared
    /// netlist like a `.step` point, a binned MOSFET whose L or W moves
    /// takes its new bin, and the circuit is rebuilt only when parameter
    /// writes cannot express the point (dev/analysis/variants.md §5).
    ///
    /// The first call also runs the deck's pending `.model OPT` optimization
    /// and MOSRA stress run, so it can take as long as they do and fail with
    /// their errors.
    ///
    /// All-or-nothing. Fails with `error.UnknownParameter` for a name not
    /// in `Options.live_params` (nor a `.step` name), `error.InvalidArgument`
    /// when the lengths differ or a value is not finite,
    /// `error.ModelBinNotFound` when no bin holds a new geometry, and
    /// `error.UnsupportedCard` when the values would flip a top-level `.if`
    /// or change the topology. Each call keeps one row until `deinit`, and
    /// each distinct bin selection it reaches keeps one circuit.
    pub fn set_params(self: *Problem, names: []const []const u8, values: []const f64) !void {
        const tuning = self.prepared.tuning orelse return error.UnknownParameter;
        if (names.len != values.len) return error.InvalidArgument;
        // The optimizer and MOSRA rewrite the variant table once; let them
        // run before rows are appended to it.
        try self.optimize();
        try self.age();
        try self.session.templates.ensureUnusedCapacity(self.session.allocator, 1);
        const change = try tuning.set(&self.prepared.circuit, self.prepared.deck.variants, names, values);
        if (change.built) |c| self.session.addTemplate(c) catch unreachable;
        std.debug.assert(change.template <= self.session.templates.items.len);
        self.session.template = change.template;
        self.prepared.deck.variants = change.variants;
        self.variant = change.variants.count() - 1;
    }

    /// Appends `count` points, each the deck's analyses run at one row of
    /// `values` (`count` rows of `Options.live_params` values, row-major),
    /// as a `.step` point would run them, and returns point 0's first
    /// query id. Points are consecutive in request order (implicit
    /// operating points sit between their ids). Each point is one
    /// `set_params` row; a point it refuses is still appended, its queries
    /// failed with `TopologyChanged` (a topology change or a flipped
    /// top-level `.if`), `ModelBinNotFound` or `NonFiniteParameter`. The
    /// first call also runs the deck's `.model OPT` and MOSRA runs.
    ///
    /// All-or-nothing. `error.NoLiveParameters` without
    /// `Options.live_params`, `error.SweptTemplate` for a deck whose
    /// analyses already sweep (`.step`, `.data`, `.alter`, Monte Carlo),
    /// `error.InvalidArgument` for zero points. Asserts that `values` holds
    /// `count` rows.
    pub fn append_points(self: *Problem, values: []const f64, count: usize, options: requests.PointOptions) !QueryId {
        const tuning = self.prepared.tuning orelse return error.NoLiveParameters;
        const p = self.live.len;
        std.debug.assert(values.len == count * p);
        if (count == 0) return error.InvalidArgument;
        const deck = &self.prepared.deck;
        for (deck.queries) |job| switch (job) {
            inline else => |o| if (o.tol.variant != null) return error.SweptTemplate,
        };
        try self.optimize();
        try self.age();
        const template_jobs = if (deck.queries.len == 0) &[_]Query{.{ .op = .{ .tol = deck.deck_tol } }} else deck.queries;
        try self.checkOutput(&self.prepared, template_jobs);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const j = template_jobs.len;
        const jobs = try a.alloc(Query, count * j);
        const templates = try a.alloc(u32, count * j);
        const refused = try a.alloc(?analysis.session.PointError, count);
        // A built template becomes the session's current one; `set_params`
        // rows appended later keep theirs.
        const current = self.session.template;
        defer self.session.template = current;
        for (0..count) |i| {
            try self.session.templates.ensureUnusedCapacity(self.session.allocator, 1);
            refused[i] = null;
            const template = if (tuning.setAt(&self.prepared.circuit, deck.variants, self.live, values[i * p ..][0..p])) |change| blk: {
                if (change.built) |c| self.session.addTemplate(c) catch unreachable;
                deck.variants = change.variants;
                break :blk change.template;
            } else |err| blk: {
                refused[i] = switch (err) {
                    error.UnsupportedCard => error.TopologyChanged,
                    error.ModelBinNotFound => error.ModelBinNotFound,
                    error.InvalidArgument => error.NonFiniteParameter,
                    else => |e| return e,
                };
                deck.variants = try tuning.refusedRow(deck.variants);
                break :blk 0;
            };
            const row = deck.variants.count() - 1;
            for (template_jobs, jobs[i * j ..][0..j], templates[i * j ..][0..j]) |job, *copy, *t| {
                copy.* = job;
                switch (copy.*) {
                    inline else => |*o| o.tol.variant = row,
                }
                if (copy.* == .tran) copy.tran.point = options;
                t.* = template;
            }
        }
        const ids = try a.alloc(QueryId, jobs.len);
        _ = try self.session.appendAt(jobs, templates, ids);
        for (refused, 0..) |r, i| if (r) |err| for (ids[i * j ..][0..j]) |id| self.session.refuse(id, err) catch unreachable;
        return ids[0];
    }

    /// Why a point produced no value, or not all of them: the C API's
    /// ESPICE_REASON_* codes.
    pub const Reason = enum(u32) {
        ok = 0,
        no_convergence = 1,
        timestep_too_small = 2,
        singular_matrix = 3,
        measure_not_found = 4,
        measure_unresolved = 5,
        aborted = 6,
        model_bin_not_found = 7,
        topology_changed = 8,
        invalid_parameter = 9,
        device_refused = 10,
        other = 255,

        /// The reason a query that failed with `err` gives.
        pub fn of(err: anyerror) Reason {
            return switch (err) {
                error.OpDidNotConverge, error.HbDidNotConverge, error.QpssDidNotConverge, error.PzDidNotConverge, error.MatexDidNotConverge, error.EnvelopeDidNotConverge, error.PacDidNotConverge => .no_convergence,
                error.TimestepTooSmall => .timestep_too_small,
                error.SingularMatrix, error.FloatingNode => .singular_matrix,
                error.MeasureBoundExceeded => .aborted,
                error.ModelBinNotFound => .model_bin_not_found,
                error.TopologyChanged, error.NoiseTopologyChanged => .topology_changed,
                error.NonFiniteParameter => .invalid_parameter,
                error.DeviceRefused => .device_refused,
                // `err` is anyerror: the full name stays with the query
                // (`QueryInfo.failure`).
                else => .other,
            };
        }
    };

    /// Writes the `.meas` cards `names` (case-insensitive) of `reasons.len`
    /// points into `out` (`reasons.len` rows of `names.len`, row-major),
    /// and each point's reason. A point is a run of consecutive requested
    /// queries on one variant row, starting at `first`: each point of
    /// `append_points` or of a swept deck, or the whole of an unswept deck.
    /// A card reads the point's first analysis of its kind, and an `op`
    /// card the point's own operating point when it has no `.op`. A point
    /// that failed reads NaN everywhere with its failure's reason; else NaN
    /// where a card found no value, the reason naming the first such card
    /// (`measure_not_found` for a missing vector or analysis,
    /// `measure_unresolved` for an event that never happened).
    ///
    /// `error.UnknownMeasure` for a name no card has, `error.InvalidQuery`
    /// for a `first` that is not a requested query or fewer points after
    /// it, `error.ResultUnavailable` while one of them is unfinished;
    /// nothing is written then. Asserts `out.len == reasons.len * names.len`.
    pub fn point_measures(self: *const Problem, first: QueryId, names: []const []const u8, out: []f64, reasons: []Reason) !void {
        std.debug.assert(out.len == reasons.len * names.len);
        const session = &self.session;
        const measures = self.prepared.deck.measures;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const cards = try a.alloc(u32, names.len);
        for (names, cards) |name, *card| card.* = for (measures, 0..) |m, k| {
            if (std.ascii.eqlIgnoreCase(m.name, name)) break @intCast(k);
        } else return error.UnknownMeasure;
        const outputs = session.outputs.items;
        const start = std.mem.indexOfScalar(QueryId, outputs, first) orelse return error.InvalidQuery;
        // Point k's queries are outputs[ends[k]..ends[k + 1]].
        const ends = try a.alloc(usize, reasons.len + 1);
        ends[0] = start;
        for (ends[1..], ends[0..reasons.len]) |*end, begin| {
            if (begin == outputs.len) return error.InvalidQuery;
            const row = variantOf(try session.query(outputs[begin]));
            var e = begin;
            while (e < outputs.len and variantOf(try session.query(outputs[e])) == row) : (e += 1) {
                if (!(try session.info(outputs[e])).status.terminal()) return error.ResultUnavailable;
            }
            end.* = e;
        }
        const nan = std.math.nan(f64);
        const values = try a.alloc(f64, measures.len);
        const missing = try a.alloc(bool, measures.len);
        for (reasons, 0..) |*reason, k| {
            const row = out[k * names.len ..][0..names.len];
            @memset(row, nan);
            const ids = outputs[ends[k]..ends[k + 1]];
            reason.* = for (ids) |id| {
                if (try queryFailure(session, id)) |err| break .of(err);
            } else .ok;
            if (reason.* != .ok) continue;
            var evaluated: ?QueryId = null;
            for (cards, row) |card, *dst| {
                const kind = measures[card].analysis;
                var source: ?QueryId = null;
                for (ids) |id| if ((try session.info(id)).kind == kind) {
                    source = id;
                    break;
                };
                if (source == null and kind == .op) for (ids) |id| if ((try session.info(id)).dependency) |dep| {
                    source = dep;
                    break;
                };
                var why: Reason = .measure_not_found;
                if (source) |q| {
                    // Cards of one analysis share its evaluation.
                    if (evaluated != q) output.measureOutcomes(measures, kind, try session.result(q), values, missing);
                    evaluated = q;
                    dst.* = values[card];
                    if (!missing[card]) why = .measure_unresolved;
                }
                if (std.math.isNan(dst.*) and reason.* == .ok) reason.* = why;
            }
        }
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
    /// publishes whatever completed; in binary or ASCII raw or `.print` the
    /// plots reach the file in one replacement when the last query ends,
    /// as with `run_all` (#179). A terminal `id` returns its status without
    /// running anything. A numerical failure is reported in the
    /// event, not as an error, and an output failure in its
    /// `delivery_error`. `error.InvalidQuery` for an ID outside
    /// `0..query_count()`. The first of `advance`, `advance_ready`,
    /// `run_all` and `set_params` also runs the deck's `.model OPT`
    /// optimization and MOSRA stress run.
    pub fn advance(self: *Problem, id: QueryId) !Advance {
        try self.optimize();
        try self.age();
        var event = try self.session.advance(id);
        self.deliver();
        self.finishWhenDone();
        event.delivery_error = self.delivery_error;
        return event;
    }

    /// Advances every query in `ids` by one quantum, up to
    /// `limits.max_parallel` at a time, writing one event per query in `ids`
    /// order, and returns `ids.len`. `ids` must be ready and distinct
    /// (`error.QueryNotReady`, `error.DuplicateQuery`), `limits.max_parallel`
    /// nonzero (`error.InvalidConcurrency`) and `events` at least as long
    /// as `ids` (`error.BufferTooSmall`); a bad frontier starts nothing.
    /// Publishes as `advance` does.
    pub fn advance_ready(self: *Problem, ids: []const QueryId, limits: Limits, events: []Advance) !usize {
        const n = try self.stepReady(ids, limits, events);
        self.finishWhenDone();
        for (events[0..n]) |*event| event.delivery_error = self.delivery_error;
        return n;
    }

    /// `advance_ready` without finishing the output, which `run_all` does
    /// itself once the `.step` runs have published too.
    fn stepReady(self: *Problem, ids: []const QueryId, limits: Limits, events: []Advance) !usize {
        try self.optimize();
        try self.age();
        const n = try self.session.advanceReady(ids, limits, events);
        self.deliver();
        return n;
    }

    /// Finishes the output once every query has ended and published, so
    /// a caller that steps to the end gets the file `run_all` writes.
    /// `run_all` alone runs the `.step` variant runs, and publishes their
    /// plots in a later `finish`.
    fn finishWhenDone(self: *Problem) void {
        if (self.delivery_error != null or !self.finished()) return;
        if (self.next_output != self.session.outputs.items.len) return;
        self.delivery.finish(self.io) catch |err| {
            self.delivery_error = err;
        };
    }

    /// Runs every query to completion, publishes the results and finishes
    /// the output, then writes the `.save` and `.stim` files. Returns the
    /// first query failure, else `error.DeliveryFailed` if output failed,
    /// once every query has ended; no `.save` or `.stim` file is written
    /// then. Calling it again is a no-op for finished queries and publishes
    /// nothing twice.
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
            _ = try self.stepReady(ids[0..selected], quantum, events);
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
        self.delivery.finish(self.io) catch |err| {
            self.delivery_error = err;
            return error.DeliveryFailed;
        };
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
    /// memory. Its Result then has empty `data`. Plotname and scale column
    /// come from `analysis.schemaOf`; `endStream` checks the row count.
    fn openStream(self: *Problem) !void {
        const deck = &self.prepared.deck;
        if (!self.session.config.final_plan or self.next_output != 0 or self.streaming != null) return;
        if (self.save_path != null or deck.stims.len != 0 or self.prepared.tuner != null or deck.probe_labels.len != deck.probes.len) return;
        if (self.session.outputs.items.len == 0) return;
        const id = self.session.outputs.items[0];
        if ((try self.session.info(id)).status != .pending) return;
        const job = try self.session.query(id);
        for (deck.measures) |m| if (m.analysis == job) return;
        const schema = try analysis.schemaOf(self.allocator, &self.prepared.circuit, deck, job);
        if (schema.plotname.len == 0) return;
        switch (job) {
            inline else => |o| if (o.tol.temp_c != null or o.tol.variant != null) return,
        }
        const names = try self.allocator.alloc([]const u8, deck.probe_labels.len + 1);
        defer self.allocator.free(names);
        names[0] = schema.scale;
        @memcpy(names[1..], deck.probe_labels);
        const writer = try self.delivery.beginStream(self.io, .{ .title = deck.title, .result = .{
            .plotname = schema.plotname,
            .varnames = names,
            .is_complex = job == .ac,
            .npoints = 0,
            .data = &.{},
        } }) orelse return;
        if (!try self.session.streamTo(id, writer)) return self.delivery.abortStream();
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

    /// Writes each `.model OPT` optimization's summary, then the deck's
    /// `.meas` results for every completed result a card can read (tran,
    /// transient noise, AC, DC, FFT, S-parameter, mismatch, loop stability,
    /// phase and periodic noise), in request order, as ngspice prints them,
    /// then the Monte Carlo statistics of each tran, AC and DC card. Cards
    /// that cannot be measured are reported on `err`.
    pub fn print_measures(self: *const Problem, out: *std.Io.Writer, err: *std.Io.Writer) !void {
        const measures = self.prepared.deck.measures;
        for (self.optimization, 0..) |*lm, k| try printOptimization(out, lm, &self.prepared.tuner.?, k, measures);
        for (self.bisection, 0..) |*b, k| try printBisection(out, b, &self.prepared.tuner.?, k, measures);
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

    /// Copies a result's data into `buffer` and returns its length
    /// (`result(id).data.len`); a longer buffer keeps its tail. Fails with
    /// `error.BufferTooSmall`, `buffer` untouched, when it is shorter, and
    /// with `error.ResultUnavailable` until the query completes.
    pub fn copy_result(self: *const Problem, id: QueryId, buffer: []f64) !usize {
        const data = (try self.result(id)).data;
        if (buffer.len < data.len) return error.BufferTooSmall;
        @memcpy(buffer[0..data.len], data);
        return data.len;
    }

    /// Runs the deck's HSPICE optimizations once, before any query advances
    /// (dev/analysis/optimize.md), one per `Tuner.bases` entry in turn.
    /// Each batch of optimizer points is one session of the optimized
    /// card's queries, a variant row per point, run `max_parallel` at a
    /// time. Each optimum's writes then fill the rows its optimized card
    /// and every later card run.
    fn optimize(self: *Problem) !void {
        const t = if (self.prepared.tuner) |*tuner| tuner else return;
        if (self.optimization.len != 0 or self.bisection.len != 0) return;
        const a = self.arena.allocator();
        const deck = &self.prepared.deck;
        const n = t.bases.len;
        if (t.method == .lm) self.optimization = try a.alloc(core.lm.Lm, n) else self.bisection = try a.alloc(core.bisect.Bisect, n);
        const best = try a.alloc(core.Variants, n);
        var template: std.ArrayList(Query) = .empty;
        for (best, 0..) |*row, base| {
            template.clearRetainingCapacity();
            for (deck.queries) |job| switch (job) {
                inline else => |o| if (o.tol.variant == @as(u32, @intCast(base))) try template.append(a, job),
            };
            const x: []const f64 = if (t.method == .lm) blk: {
                // DC and transient goals take their Jacobian from the trial
                // point's own run (`Dc.tangents`, `Tran.tangents`), so every
                // round is batched.
                const direct = !self.session.config.knobs.no_tangents and for (template.items) |job| {
                    if (!self.tangentable(job)) break false;
                } else true;
                const lm = &self.optimization[base];
                lm.* = try core.lm.Lm.init(a, t.initial, t.spec.lo, t.spec.hi, t.spec.dels, t.spec.grid, @intCast(t.results.len), t.options, direct or self.limits.max_parallel > 1);
                try self.search(t, template.items, base, lm, direct);
                break :blk lm.x;
            } else blk: {
                const goal = deck.measures[t.results[0]];
                const c = if (goal.first.goal != null) goal.first else goal.second;
                const scale = @max(@abs(c.goal.?), c.minval) / c.weight;
                const b = &self.bisection[base];
                b.* = core.bisect.Bisect.init(a, t.method, t.spec.lo[0], t.spec.hi[0], t.spec.grid[0], scale, t.options);
                try self.search(t, template.items, base, b, false);
                break :blk (&b.x)[0..1];
            };
            row.* = try t.rows(a, &self.prepared.circuit, x, base);
        }
        deck.variants = try frontend.Tuner.optimized(a, deck.variants, best);
    }

    /// Whether `job` can give the optimizer its Jacobian as tangents of its
    /// own run. A transient cannot from an operating point it does not
    /// solve on its own (`uic`, `.ic` holds, a capacitor-only node's
    /// OPtran), under VPI callbacks, or off the CPU: its rows swap host
    /// device state (`Tran.tangents`).
    fn tangentable(self: *const Problem, job: Query) bool {
        const c = &self.prepared.circuit;
        return switch (job) {
            .dc => true,
            .tran => |o| !o.uic and !o.snapshot and !o.sources_at_zero and self.prepared.deck.ic.len == 0 and
                !c.needs_tran_op and c.vpi == null and self.session.config.backend == .cpu,
            else => false,
        };
    }

    /// HSPICE MOSRA, once before any query advances
    /// (dev/analysis/mosra.md): runs the stress transient with the bound
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
    /// A Levenberg-Marquardt point's operating point starts from the one of
    /// the iterate its step left (dev/analysis/optimize.md, "Warm starts"),
    /// so the path does not depend on batching; the start's round and every
    /// bisection point start cold. `direct` as `evaluatePoints` says.
    fn search(self: *Problem, t: *frontend.Tuner, template: []const Query, base: usize, solver: anytype, direct: bool) !void {
        const n = t.spec.live.len;
        const m = t.results.len;
        const lm = @TypeOf(solver) == *core.lm.Lm;
        const gpa = self.allocator;
        var residuals: std.ArrayList(f64) = .empty;
        defer residuals.deinit(gpa);
        // The operating points of the accepted iterate, of row 0 of the
        // last round, and the one this round starts from.
        var origin: std.ArrayList(f64) = .empty;
        defer origin.deinit(gpa);
        var first: std.ArrayList(f64) = .empty;
        defer first.deinit(gpa);
        var guess: std.ArrayList(f64) = .empty;
        defer guess.deinit(gpa);
        while (solver.points().len != 0) {
            const points = solver.points();
            if (lm) if (solver.stepping()) {
                guess.clearRetainingCapacity();
                try guess.appendSlice(gpa, origin.items);
            };
            try residuals.resize(gpa, points.len / n * m);
            try self.evaluatePoints(t, template, base, points, if (lm) direct and solver.batched() else false, guess.items, residuals.items, &first);
            const accepted = if (lm) solver.history.rss.items.len else 0;
            try solver.feed(residuals.items);
            if (lm) if (solver.history.rss.items.len > accepted) std.mem.swap(std.ArrayList(f64), &origin, &first);
        }
    }

    /// Residuals of each point of `points` (the optimized parameters'
    /// values, n per point, on top of `t.bases[base]`) into `out`, m per
    /// point: the RESULTS cards'
    /// goal errors over the `template` queries run at that point, NaN where
    /// a query failed or a card found no value. Every operating point
    /// starts from `guess` (cold when empty); `first` takes the one row 0's
    /// first query solved, empty when it has none. With `direct` (a
    /// batched round of `tangentable` queries) only row 0 runs, and the
    /// other points' results are its runs' first-order predictions of them
    /// (`Dc.tangents`, `Tran.tangents`, dev/analysis/optimize.md "Direct
    /// sensitivities").
    fn evaluatePoints(self: *Problem, t: *frontend.Tuner, template: []const Query, base: usize, points: []const f64, direct: bool, guess: []const f64, out: []f64, first: *std.ArrayList(f64)) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const count = points.len / t.spec.live.len;
        std.debug.assert(!direct or count == t.spec.live.len + 1);
        var deck = self.prepared.deck;
        deck.variants = try t.rows(a, &self.prepared.circuit, points, base);
        deck.op_guess = guess;
        const runs = if (direct) 1 else count;
        const tangents = try a.alloc(u32, if (direct) count - 1 else 0);
        for (tangents, 1..) |*row, p| row.* = @intCast(p);
        const jobs = try a.alloc(Query, runs * template.len);
        for (0..runs) |p| for (template, jobs[p * template.len ..][0..template.len]) |job, *copy| {
            copy.* = job;
            switch (copy.*) {
                inline else => |*o| o.tol.variant = @intCast(p),
            }
            if (direct) switch (copy.*) {
                .dc => |*o| o.tangents = tangents,
                .tran => |*o| o.tangents = tangents,
                else => unreachable, // else: `tangentable` admits these two
            };
        };
        var session = analysis.session.Session.init(self.workerAllocator(), self.io, &self.prepared.circuit, &deck, self.session.config);
        defer session.deinit();
        const ids = try a.alloc(QueryId, jobs.len);
        _ = try session.append(jobs, ids);
        try runSession(&session, self.limits.max_parallel);
        first.clearRetainingCapacity();
        if (try session.operatingPoint(ids[0])) |x| try first.appendSlice(self.allocator, x);
        const values = try a.alloc(f64, deck.measures.len);
        const m = t.results.len;
        @memset(out, std.math.nan(f64));
        for (0..count) |p| for (ids[(if (direct) 0 else p) * template.len ..][0..template.len]) |id| {
            const info = try session.info(id);
            if (info.status != .complete) continue;
            var res = try session.result(id);
            if (direct) {
                // Block p of the sweep: its own points, or row p's prediction.
                res.npoints /= count;
                res.data = res.data[p * res.npoints * res.varnames.len ..][0 .. res.npoints * res.varnames.len];
            }
            output.measureValues(deck.measures, info.kind, res, values);
            for (t.results, out[p * m ..][0..m]) |card, *r| {
                const measure = deck.measures[card];
                // Never null: Tuner.init refuses a RESULTS card without GOAL=
                // (`goalError(0) != null`), and only the goal decides null.
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
        while (next_output.* < session.outputs.items.len) : (next_output.* += 1) {
            const delivered = self.deliverOne(session, session.outputs.items[next_output.*], deck_title) catch |err| {
                self.delivery_error = err;
                return;
            };
            if (!delivered) return;
        }
    }

    /// Publishes (or ends the stream of) `id` once it is terminal; false
    /// while it still runs. `session.outputs` holds only appended ids, and a
    /// row reads `.complete` only after its executor published, so the
    /// session lookups fail only if Session breaks that bookkeeping; the
    /// error then stops delivery like any output failure instead of
    /// aborting a C host.
    fn deliverOne(self: *Problem, session: *const analysis.session.Session, id: QueryId, deck_title: []const u8) DeliveryError!bool {
        const status = (try session.info(id)).status;
        if (!status.terminal()) return false;
        if (session == &self.session and self.streaming == id) {
            self.streaming = null;
            if (status != .complete) {
                self.delivery.abortStream();
                return true;
            }
            const res = try session.result(id);
            try self.delivery.endStream(self.io, res.npoints, res.varnames.len);
        } else if (status == .complete) {
            const res = try session.result(id);
            var lap = if (self.timing_in_depth) std.Io.Timestamp.now(self.io, .awake) else null;
            defer timingLap(self.io, &lap, "output delivery");
            const job = try session.query(id);
            // An `.sp` carries its ports' z0, which a Touchstone output records (#60).
            var z0: std.ArrayList(f64) = .empty;
            defer z0.deinit(self.allocator);
            if (job == .sp) try modeZ0(self.allocator, job.sp.ports, &z0);
            const plot: output.Plot = .{ .title = deck_title, .result = res, .z0 = z0.items };
            try self.delivery.publish(self.io, plot);
            if (job == .sp) if (job.sp.lin) |lin| if (lin.touchstone)
                try self.writeTouchstone(lin.file, plot);
        }
        return true;
    }

    /// Writes a `.lin format=touchstone` result as `<file>.s<N>p` beside the
    /// deck, `file` defaulting to the deck's name without its extension
    /// (HSPICE names it after the netlist), against the ports' own z0.
    fn writeTouchstone(self: *Problem, file: []const u8, plot: output.Plot) !void {
        const stem = if (file.len > 0) file else std.fs.path.stem(self.origin);
        const name = try std.fmt.allocPrint(self.allocator, "{s}.s{d}p", .{ stem, @max(plot.z0.len, 1) });
        defer self.allocator.free(name);
        const path = try std.fs.path.join(self.allocator, &.{ std.fs.path.dirname(self.origin) orelse ".", name });
        defer self.allocator.free(path);
        try output.write(self.io, path, .touchstone, plot);
    }

    /// Appends the reference impedance of each of `ports`' modes to `z0`, in
    /// sp.zig's `Basis` order: each port's first mode (a balanced one's
    /// differential, 2·z0), then the common modes (z0/2).
    fn modeZ0(gpa: std.mem.Allocator, ports: []const requests.Port, z0: *std.ArrayList(f64)) !void {
        for (ports) |p| try z0.append(gpa, if (p.balanced != null) 2 * p.z0 else p.z0);
        for (ports) |p| if (p.balanced != null) try z0.append(gpa, p.z0 / 2);
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

/// The variant row `job` runs at, or null for the nominal circuit.
fn variantOf(job: Query) ?u32 {
    return switch (job) {
        inline else => |o| o.tol.variant,
    };
}

/// The error query `id` ended with, its prerequisite's for a query that
/// never ran because of it; null when it completed. Asserts it is terminal.
fn queryFailure(session: *const analysis.session.Session, id: QueryId) !?anyerror {
    const info = try session.info(id);
    std.debug.assert(info.status.terminal());
    if (info.status == .complete) return null;
    if (info.failure) |err| if (err == error.DependencyFailed) if (info.dependency) |dep| {
        if ((try session.info(dep)).failure) |cause| return cause;
    };
    return info.failure orelse error.QueryCancelled;
}

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

/// `.meas` results over one session's completed results of every kind a
/// card can read.
fn printSessionMeasures(session: *const analysis.session.Session, out: *std.Io.Writer, err: *std.Io.Writer, measures: []const @import("core").Measure) !void {
    for (session.outputs.items) |id| {
        const info = try session.info(id);
        if (info.status != .complete) continue;
        switch (info.kind) {
            .op, .tran, .ac, .dc, .fft, .tran_noise, .dcmatch, .acmatch, .lstb, .phasenoise, .pnoise, .sp => try output.printMeasures(out, err, measures, info.kind, try session.result(id)),
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
    for (t.names, lm.x, t.initial, lm.lo, lm.hi, lm.grid) |name, x, x0, lo, hi, g| {
        try out.print("  {s} = {e:.6} $ initial {e:.6}, range {e:.6} to {e:.6}", .{ name, x, x0, lo, hi });
        if (g > 0) try out.print(", grid {e:.6}", .{g});
        try out.writeAll("\n");
    }
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
        \\
    , .{ b.evaluations, b.iterations, t.spec.name, t.names[0], b.x, t.spec.lo[0], t.spec.hi[0] });
    if (b.grid > 0) try out.print("  grid {e:.6}\n", .{b.grid});
    try out.print("  error({s}) = {e:.6}\n", .{ measures[t.results[0]].name, b.r });
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

/// `given` with each null path the environment sets filled in, copied into
/// `a`: `zig` from `$ZIG`, and `cache_dir` from `$ESPICE_CACHE/hdl`, else
/// `$XDG_CACHE_HOME/espice/hdl`, else `$HOME/.cache/espice/hdl`, else
/// `$TMPDIR/espice-cache/hdl` (default `/tmp`). An empty variable counts as
/// unset for the cache, as `$ZIG` never is.
fn toolchainFromEnv(a: std.mem.Allocator, given: HdlToolchain) !HdlToolchain {
    const env = struct {
        fn get(name: [*:0]const u8) ?[]const u8 {
            const v = std.mem.span(std.c.getenv(name) orelse return null);
            return if (v.len == 0) null else v;
        }
    }.get;
    const cache_dir = if (given.cache_dir) |d| try a.dupe(u8, d) else if (env("ESPICE_CACHE")) |d|
        try std.fs.path.join(a, &.{ d, "hdl" })
    else if (env("XDG_CACHE_HOME")) |d|
        try std.fs.path.join(a, &.{ d, "espice", "hdl" })
    else if (env("HOME")) |d|
        try std.fs.path.join(a, &.{ d, ".cache", "espice", "hdl" })
    else
        try std.fs.path.join(a, &.{ env("TMPDIR") orelse "/tmp", "espice-cache", "hdl" });
    const zig = given.zig orelse if (std.c.getenv("ZIG")) |z| std.mem.span(z) else null;
    return .{
        .zig = if (zig) |z| try a.dupe(u8, z) else null,
        .share = if (given.share) |d| try a.dupe(u8, d) else null,
        .cache_dir = cache_dir,
    };
}

/// Keeps the driver's JIT cache (`~/.nv/ComputeCache`) from evicting the
/// compact-model kernels, whose cold compiles take 15 s (bsim4va) to 1001 s
/// (hisimhv_va). The default cap is 256 MiB on older drivers and this
/// machine's cache already held 321 MB before they were added. 4 GiB is the
/// driver's maximum. A user's own setting wins. It must run before the
/// driver initializes, which the first GPU query of the process does, so
/// `Problem.init` calls it whenever the backend may use the GPU.
fn raiseJitCache() void {
    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    }.setenv;
    _ = setenv("CUDA_CACHE_MAXSIZE", "4294967296", 0);
}

/// The developer switches (`analysis.Knobs`), read from the environment once
/// per Problem. Nothing below the facade reads the environment, so every
/// knob is parsed here; the field docs name each variable.
fn knobsFromEnv() analysis.Knobs {
    const env = struct {
        fn get(name: [:0]const u8) ?[]const u8 {
            return std.mem.span(std.c.getenv(name) orelse return null);
        }
        fn on(name: [:0]const u8) bool {
            return std.c.getenv(name) != null;
        }
    };
    var k: analysis.Knobs = .{};
    if (env.get("ESPICE_SOLVER")) |s| k.newton.pin = @TypeOf(k.newton.pin).names.get(s) orelse .auto;
    k.newton.opdbg = env.on("ZP_OPDBG");
    k.newton.newton_debug = env.on("ZP_NEWTON_DEBUG");
    k.lu.no_bbd = env.on("ESPICE_NO_BBD");
    if (env.get("ESPICE_LU_PAR")) |v| k.lu.par = v.len > 0 and v[0] == '1';
    k.lu.par_stats = env.on("ESPICE_LU_PAR_STATS");
    k.hb_trace = env.on("ESPICE_HB_TRACE");
    k.no_qtape = env.on("ZP_NO_QTAPE");
    k.tran_stats = env.on("ZP_TRAN_STATS");
    k.no_tangents = env.on("ZP_NO_TANGENTS");
    if (env.get("ESPICE_GPU_LU")) |v| k.gpu_lu = std.mem.eql(u8, v, "1");
    k.gpu_lu_check = env.on("ESPICE_GPU_LU_CHECK");
    k.gpu_lu_nogather = env.on("ESPICE_GPU_LU_NOGATHER");
    if (env.get("ESPICE_GPU_LU_TAIL")) |v| k.gpu_lu_tail = std.fmt.parseInt(u32, v, 10) catch 0;
    if (analysis.Knobs.instrument) {
        k.lu.stats = env.on("ZP_LU_STATS");
        if (env.get("ESPICE_GPU_LU_BENCH")) |v| k.gpu_lu_bench = std.fmt.parseInt(usize, v, 10) catch 0;
        if (env.get("ESPICE_GPU_LU_THREADS")) |v| k.gpu_lu_threads = std.fmt.parseInt(u32, v, 10) catch 8;
    }
    if (env.get("ESPICE_GPU_STATS")) |v| k.gpu_stats = if (std.mem.eql(u8, v, "phases")) .phases else .on;
    k.gpu_block = analysis.Knobs.parseBlock(env.get("ESPICE_GPU_BLOCK"));
    k.gpu_eval_check = env.on("ESPICE_GPU_EVAL_CHECK");
    k.gpu_nofuse = env.on("ESPICE_GPU_NOFUSE");
    k.xdg_cache_home = env.get("XDG_CACHE_HOME");
    k.home = env.get("HOME");
    return k;
}
