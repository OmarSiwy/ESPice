//! Session: the query graph and its cooperative scheduler. In: query
//! requests. Out: rows with their status, progress and results. Each row is
//! one query, an implicit OP prerequisite included; numerical state lives in
//! the row's Executor. Cites #13 (the C API's calling contract) and #154
//! (the `.sens` schema).
const std = @import("std");
const core = @import("core");
const requests = core.query;
const Deck = core.Deck;
const Circuit = @import("device").Circuit;
const ParamRef = @import("device").abi.ParamRef;
const execution = @import("executor.zig");
const progress = @import("progress.zig");
const types = @import("types.zig");
const Result = types.Result;
const validateDeck = @import("core").validate.validateDeck;

/// Why a query ended without a result: its run failed (`QueryError`,
/// `error.QueryCancelled` included), its executor could not be built
/// (`Executor.create`: `error.OutOfMemory`, `error.InvalidOperatingPoint`,
/// a bad variant or AC override) or started (a thread spawn), or its
/// prerequisite ended without one (`error.DependencyFailed`). Names are part
/// of the API: `c_api.zig` maps some to status codes.
pub const Failure = execution.QueryError || types.ErrorOf(execution.Executor.create) ||
    types.ErrorOf(execution.Executor.start) || error{DependencyFailed} || PointError;
/// Why a point of `Problem.append_points` was refused before it ran
/// (`Session.refuse`): a value that needs another topology or flips a
/// top-level `.if`, a geometry no model bin holds, a non-finite value, or
/// any other failure to build the point's circuit (`PointRefused`).
pub const PointError = error{ TopologyChanged, ModelBinNotFound, NonFiniteParameter, PointRefused };

/// A row index into the session, stable for its lifetime.
pub const QueryId = requests.QueryId;
const none = requests.invalid_query;

/// Lifecycle of one query row.
pub const Status = enum(u8) {
    pending,
    paused,
    complete,
    failed,
    dependency_failed,
    cancelled,

    /// True once the row will never run again.
    pub fn terminal(self: Status) bool {
        return switch (self) {
            .pending, .paused => false,
            else => true,
        };
    }
};
/// A query selection: everything, one query with its prerequisite, or one
/// connected component (a shared OP and its dependents).
pub const Scope = union(enum) { all, query: QueryId, component: u32 };
/// How many ready queries one scheduling round may run at once, and how far
/// each runs.
pub const Limits = struct { max_parallel: u16 = 1, quantum: Quantum = .checkpoint };
const Quantum = @import("worker.zig").Quantum;
/// Which advancement `print` previews.
pub const Preview = union(enum) { run_all, advance: QueryId, advance_ready: []const QueryId };
/// What `Session.print` shows; `limits` previews a concurrency cap.
pub const PrintOptions = struct {
    scope: Scope = .all,
    preview: Preview = .run_all,
    ascii: bool = false,
    limits: ?Limits = null,
};
/// Snapshot of one query row.
pub const QueryInfo = struct {
    id: QueryId,
    kind: requests.Kind,
    status: Status,
    dependency: ?QueryId,
    component: u32,
    requested: bool,
    progress: ?progress.Event,
    failure: ?Failure,
};
/// What one advancement did: `advanced` may be the prerequisite of
/// `requested`, and `target_status` is the requested query's status after it.
pub const Advance = struct {
    requested: QueryId,
    advanced: QueryId,
    status: Status,
    target_status: Status,
    /// The facade's first output failure (`espice.Problem.output_error`);
    /// analysis cannot name the output module's error set.
    delivery_error: ?anyerror = null,
    progress: ?progress.Event = null,
    failure: ?Failure = null,
};
const Row = struct {
    job: requests.Query,
    dependency: QueryId = none,
    component: u32,
    requested: bool,
    status: Status = .pending,
    progress: ?progress.Event = null,
    failure: ?Failure = null,
    executor: ?*execution.Executor = null,
    /// The circuit the query instantiates: 0 for `topology`, k for
    /// `templates[k - 1]`.
    template: u32 = 0,
    /// Rows that read this one's device state (its dependents) and have
    /// not yet stopped a first quantum, which is when their copy is done.
    readers: u32 = 0,
    /// The newest dependent and the next older one sharing `dependency`.
    child: QueryId = none,
    sibling: QueryId = none,
    /// A quantum is in flight; `settle` collects it.
    running: bool = false,
    /// `release` dropped its executor and result.
    released: bool = false,
    /// Its position in `outputs`, or `no_output` when not requested.
    output: u32 = no_output,
};

const no_output = std.math.maxInt(u32);

/// The query graph over one prepared circuit and deck, both borrowed for the
/// session's lifetime. `QueryId` is the row index; every call that takes one
/// fails with `error.InvalidQuery` for an id at or past `count`.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    topology: *const Circuit,
    deck: *const Deck,
    config: execution.Config,
    rows: std.MultiArrayList(Row) = .empty,
    /// Requested queries in first-request order, for delivery.
    outputs: std.ArrayList(QueryId) = .empty,
    /// One arena per `append`, holding its copied query options.
    request_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    /// Round-robin start for `readyQueries`.
    cursor: u32 = 0,
    /// Every OP row by template and options, for `append` to share one.
    ops: OpIndex = .empty,
    /// Rows with no dependency that have not yet stopped a first quantum:
    /// the template's readers, as `Row.readers` counts a row's.
    root_readers: u32 = 0,
    /// A `Pool`'s view: ready rows in row order from `queue_head`, and the
    /// rows that turned ready since (a finished OP's dependents, a parked
    /// query), taken first.
    queue: std.ArrayList(u32) = .empty,
    queue_head: usize = 0,
    urgent: std.ArrayList(u32) = .empty,
    /// Every row before it is terminal, and every output before
    /// `done_outputs`: where `requeue` and `finished` start, so a session
    /// appended to and run over and over costs what each batch adds.
    done_rows: usize = 0,
    done_outputs: usize = 0,
    /// No other session reads `topology`'s device state after this one, so
    /// under `config.final_plan` its last root query evaluates the template's
    /// own batches instead of a copy (`Circuit.instantiateMove`). Set by
    /// `markLastTemplateReader`.
    last_template_reader: bool = false,
    /// Circuits with `topology`'s pattern that rows can instantiate instead
    /// (a model bin that moved under `Problem.set_params`), oldest first;
    /// each must outlive the session.
    templates: std.ArrayList(*const Circuit) = .empty,
    /// The circuit rows appended from now on instantiate: 0 for `topology`,
    /// k for `templates[k - 1]`.
    template: u32 = 0,
    /// A transient or AC query that writes its rows to `writer` as it records them
    /// instead of keeping them; its Result has empty `data`. Set by `streamTo`.
    stream: ?struct { id: QueryId, writer: *std.Io.Writer } = null,

    /// An empty session. Allocates nothing; `topology` and `deck` must
    /// outlive it.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, topology: *const Circuit, deck: *const Deck, config: execution.Config) Session {
        return .{ .allocator = allocator, .io = io, .topology = topology, .deck = deck, .config = config };
    }

    /// Marks this session as the last reader of `topology`'s device state
    /// (`last_template_reader`). Asserts that nothing has been appended, so
    /// every row sees the same answer (#13).
    pub fn markLastTemplateReader(self: *Session) void {
        std.debug.assert(self.rows.len == 0);
        self.last_template_reader = true;
    }

    /// Makes transient or AC query `id` write its rows to `writer` as it
    /// records them, its Result keeping empty `data`. False, and nothing
    /// set, once `id` has started: its rows already went elsewhere (#13).
    /// Asserts that no other query streams and that `id` is a tran or AC row.
    pub fn streamTo(self: *Session, id: QueryId, writer: *std.Io.Writer) !bool {
        const i = try self.index(id);
        std.debug.assert(self.stream == null);
        const job = self.rows.items(.job)[i];
        std.debug.assert(job == .tran or job == .ac);
        if (self.rows.items(.executor)[i] != null) return false;
        self.stream = .{ .id = id, .writer = writer };
        return true;
    }

    /// Cancels and joins every started query, then frees every row, result
    /// and copied option. Every `Result` the session handed out dies here.
    pub fn deinit(self: *Session) void {
        // Newest first: dependents join before the OP products they copied from.
        var i = self.rows.len;
        while (i != 0) {
            i -= 1;
            if (self.rows.items(.executor)[i]) |worker| worker.destroy();
        }
        self.rows.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        self.templates.deinit(self.allocator);
        self.ops.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.urgent.deinit(self.allocator);
        for (self.request_arenas.items) |*arena| arena.deinit();
        self.request_arenas.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds `jobs`, writing their ids to `ids`, and returns `jobs.len`. Each
    /// non-OP job shares an existing matching OP prerequisite or gets a new
    /// one. All-or-nothing: every job is validated and deep-copied before any
    /// row or id is published. Fails with `error.BufferTooSmall` when `ids`
    /// is shorter than `jobs`, a validation error for the first bad job, or
    /// `error.TooManyQueries` past u32 rows.
    pub fn append(self: *Session, jobs: []const requests.Query, ids: []QueryId) !usize {
        return self.appendAt(jobs, null, ids);
    }

    /// `append` with job k instantiating `templates[k]` (as `template`
    /// numbers them) instead of `template`, so one call can hold points on
    /// several templates. Asserts `templates` matches `jobs` in length.
    pub fn appendAt(self: *Session, jobs: []const requests.Query, templates: ?[]const u32, ids: []QueryId) !usize {
        if (templates) |t| std.debug.assert(t.len == jobs.len);
        if (ids.len < jobs.len) return error.BufferTooSmall;
        if (jobs.len == 0) return 0;
        const max_rows = std.math.add(usize, self.rows.len, std.math.mul(usize, jobs.len, 2) catch return error.TooManyQueries) catch return error.TooManyQueries;
        if (max_rows >= std.math.maxInt(u32)) return error.TooManyQueries;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const old_len = self.rows.len;
        // Everything that can fail first: copies, then room for every row,
        // OP index entry and output, so the rows below change infallibly.
        const owned = try a.alloc(requests.Query, jobs.len);
        for (jobs, owned) |job, *o| {
            try validateDeck(job, self.topology.n, self.deck);
            o.* = try copyValue(a, job);
        }
        try self.rows.ensureTotalCapacity(self.allocator, max_rows);
        try self.ops.ensureUnusedCapacity(self.allocator, @intCast(max_rows - old_len));
        try self.outputs.ensureUnusedCapacity(self.allocator, jobs.len);
        try self.request_arenas.ensureUnusedCapacity(self.allocator, 1);
        try self.urgent.ensureTotalCapacity(self.allocator, max_rows);
        var roots: u32 = 0;
        for (owned, ids[0..jobs.len], 0..) |job, *id, k| {
            const template = if (templates) |t| t[k] else self.template;
            std.debug.assert(template <= self.templates.items.len);
            var dependency = none;
            if (prerequisite(job)) |op| {
                dependency = self.ops.get(.{ .template = template, .op = op }) orelse blk: {
                    const dep: QueryId = @fromBackingInt(@intCast(self.rows.len));
                    self.rows.appendAssumeCapacity(.{
                        .job = .{ .op = op },
                        .component = @backingInt(dep),
                        .requested = false,
                        .template = template,
                    });
                    self.ops.putAssumeCapacity(.{ .template = template, .op = op }, dep);
                    roots += 1;
                    break :blk dep;
                };
            }
            // An explicit OP can expose an already shared prerequisite product.
            if (job == .op) {
                if (self.ops.get(.{ .template = template, .op = job.op })) |existing| {
                    const e = @backingInt(existing);
                    id.* = existing;
                    if (!self.rows.items(.requested)[e]) {
                        self.rows.items(.requested)[e] = true;
                        self.rows.items(.output)[e] = @intCast(self.outputs.items.len);
                        self.outputs.appendAssumeCapacity(existing);
                    }
                    continue;
                }
            }
            id.* = @fromBackingInt(@intCast(self.rows.len));
            var sibling = none;
            if (dependency == none) {
                roots += 1;
            } else {
                const d = @backingInt(dependency);
                self.rows.items(.readers)[d] += 1;
                sibling = self.rows.items(.child)[d];
                self.rows.items(.child)[d] = id.*;
            }
            self.rows.appendAssumeCapacity(.{
                .job = job,
                .dependency = dependency,
                .component = if (dependency == none) @backingInt(id.*) else self.rows.items(.component)[@backingInt(dependency)],
                .requested = true,
                .template = template,
                .sibling = sibling,
                .output = @intCast(self.outputs.items.len),
            });
            self.outputs.appendAssumeCapacity(id.*);
            if (job == .op) self.ops.putAssumeCapacity(.{ .template = template, .op = job.op }, id.*);
        }
        self.root_readers += roots;
        self.request_arenas.appendAssumeCapacity(arena);
        return jobs.len;
    }

    /// Ends pending query `id`, and its pending prerequisite, with `err`
    /// before anything runs: a point `Problem.append_points` could not set.
    /// The prerequisite must be the query's own (no other row reads it).
    pub fn refuse(self: *Session, id: QueryId, err: PointError) !void {
        const i = try self.index(id);
        const dep = self.rows.items(.dependency)[i];
        for ([_]QueryId{ id, dep }) |row| if (row != none) {
            const r = @backingInt(row);
            std.debug.assert(self.rows.items(.executor)[r] == null);
            self.rows.items(.status)[r] = .failed;
            self.rows.items(.failure)[r] = err;
        };
    }

    /// Makes `circuit` the template of every row appended from now on
    /// (`template`, which a caller may point back at an earlier one).
    /// Asserts that it has `topology`'s node count and pattern size; the
    /// caller keeps it alive for the session's lifetime.
    pub fn addTemplate(self: *Session, circuit: *const Circuit) !void {
        std.debug.assert(circuit.n == self.topology.n);
        std.debug.assert(circuit.nnz == self.topology.nnz);
        try self.templates.append(self.allocator, circuit);
        self.template = @intCast(self.templates.items.len);
    }

    /// Returns the row count, implicit prerequisites included.
    pub fn count(self: *const Session) u32 {
        return @intCast(self.rows.len);
    }

    fn index(self: *const Session, id: QueryId) !usize {
        const i = @backingInt(id);
        if (i >= self.rows.len) return error.InvalidQuery;
        return i;
    }

    fn effectiveStatus(self: *const Session, i: usize) Status {
        const status = self.rows.items(.status)[i];
        if (status.terminal()) return status;
        const dep = self.rows.items(.dependency)[i];
        if (dep != none) {
            const ds = self.rows.items(.status)[@backingInt(dep)];
            if (ds.terminal() and ds != .complete) return .dependency_failed;
        }
        return status;
    }

    /// Returns a snapshot of query `id`. A non-terminal query whose
    /// prerequisite ended without a result reads as `.dependency_failed`.
    pub fn info(self: *const Session, id: QueryId) !QueryInfo {
        const i = try self.index(id);
        const dep = self.rows.items(.dependency)[i];
        const status = self.effectiveStatus(i);
        return .{
            .id = id,
            .kind = std.meta.activeTag(self.rows.items(.job)[i]),
            .status = status,
            .dependency = if (dep == none) null else dep,
            .component = self.rows.items(.component)[i],
            .requested = self.rows.items(.requested)[i],
            .progress = self.rows.items(.progress)[i],
            .failure = if (status == .dependency_failed) error.DependencyFailed else self.rows.items(.failure)[i],
        };
    }

    fn validateScope(self: *const Session, scope: Scope) !void {
        switch (scope) {
            .all => {},
            .query => |id| _ = try self.index(id),
            .component => |component| {
                for (self.rows.items(.component)) |c| if (c == component) return;
                return error.InvalidComponent;
            },
        }
    }

    fn contains(self: *const Session, scope: Scope, i: usize) bool {
        return switch (scope) {
            .all => true,
            .component => |component| self.rows.items(.component)[i] == component,
            .query => |id| @backingInt(id) == i or self.rows.items(.dependency)[@backingInt(id)] == @as(QueryId, @fromBackingInt(@intCast(i))),
        };
    }

    fn ready(self: *const Session, i: usize) bool {
        if (self.effectiveStatus(i).terminal()) return false;
        const dep = self.rows.items(.dependency)[i];
        return dep == none or self.rows.items(.status)[@backingInt(dep)] == .complete;
    }

    /// How many queries in `scope` can advance now: the length
    /// `readyQueries` needs.
    pub fn readyCount(self: *const Session, scope: Scope) !usize {
        try self.validateScope(scope);
        var n: usize = 0;
        for (0..self.rows.len) |i| if (self.contains(scope, i) and self.ready(i)) {
            n += 1;
        };
        return n;
    }

    /// Copies the ready queries in `scope` into `ids` in scheduler order and
    /// returns how many there are. Fails with `error.BufferTooSmall`, writing
    /// nothing, when `ids` is shorter than `readyCount`, as every other
    /// copying call here does (#13).
    pub fn readyQueries(self: *const Session, scope: Scope, ids: []QueryId) !usize {
        const n = try self.readyCount(scope);
        if (ids.len < n) return error.BufferTooSmall;
        var out: usize = 0;
        for (0..self.rows.len) |offset| {
            const i = (offset + self.cursor) % self.rows.len;
            if (!self.contains(scope, i) or !self.ready(i)) continue;
            ids[out] = @fromBackingInt(@intCast(i));
            out += 1;
        }
        return n;
    }

    fn validateReady(self: *const Session, ids: []const QueryId, limits: Limits) !void {
        if (limits.max_parallel == 0) return error.InvalidConcurrency;
        for (ids, 0..) |id, pos| {
            const i = try self.index(id);
            if (!self.ready(i)) return error.QueryNotReady;
            for (ids[0..pos]) |earlier| if (earlier == id) return error.DuplicateQuery;
        }
    }

    fn makeExecutor(self: *Session, i: usize) !void {
        if (self.rows.items(.executor)[i] != null) return;
        const dep = self.rows.items(.dependency)[i];
        const initial = if (dep == none) null else self.rows.items(.executor)[@backingInt(dep)];
        const template = self.rows.items(.template)[i];
        // Query `i` may take its source's state only as its last reader,
        // once every other reader has stopped a quantum: their copies are done.
        const last = if (dep == none) self.last_template_reader and self.root_readers == 1 else self.rows.items(.readers)[@backingInt(dep)] == 1;
        self.rows.items(.executor)[i] = try execution.Executor.create(
            self.allocator,
            self.io,
            if (template == 0) self.topology else self.templates.items[template - 1],
            self.deck,
            self.rows.items(.job)[i],
            initial,
            self.config.final_plan and last,
            self.config,
        );
        if (self.stream) |s| if (@backingInt(s.id) == i) {
            self.rows.items(.executor)[i].?.stream = s.writer;
        };
        self.rows.items(.executor)[i].?.row = @intCast(i);
        if (self.config.timing_in_depth)
            self.rows.items(.executor)[i].?.controller.options.timing_query = @fromBackingInt(@intCast(i));
    }

    /// The grouping pass (lane-batched-simulation.md §2): makes ready `.op`,
    /// `.dc`, `.tran` or AC-family row `i` the leader of a lane batch with up to `lane_width -
    /// 1` other ready, never-started rows of its kind on its template, with
    /// a prerequisite exactly when it has one, whose options differ at most
    /// in `tol.variant` and `tol.temp_c`, taken from the queue ahead.
    /// Each lane is bitwise its query run alone, so grouping is free to
    /// follow scheduling order. A row whose executor cannot be built is
    /// left to run alone.
    /// ponytail: looks `lane_window` rows into `urgent` and the queue, not
    /// all of them; a sweep's rows are adjacent in row order.
    fn gather(self: *Session, i: usize) void {
        const lane_width = execution.lane_width;
        const config = self.config;
        if (config.gpu_lanes and self.rows.items(.job)[i] == .tran and self.rows.items(.executor)[i] == null) return self.gatherWide(i);
        if (!execution.lanesOn(config) or config.backend != .cpu or config.device_threads != 1 or config.timing_in_depth) return;
        const jobs = self.rows.items(.job);
        const laned = jobs[i] == .op or jobs[i] == .dc or jobs[i] == .tran or execution.freqLaneKind(jobs[i]);
        if (!laned or self.rows.items(.executor)[i] != null) return;
        var peers: [lane_width - 1]usize = undefined;
        var n: usize = 0;
        // A finished batch's dependents wait in `urgent`, newest last.
        const urgent = self.urgent.items;
        const from_urgent = @min(urgent.len, lane_window);
        const queued = self.queue.items[@min(self.queue_head, self.queue.items.len)..];
        for (0..from_urgent + @min(queued.len, lane_window)) |at| {
            if (n == peers.len) break;
            const j = if (at < from_urgent) urgent[urgent.len - 1 - at] else queued[at - from_urgent];
            if (j == i or !self.ready(j) or self.rows.items(.running)[j] or self.rows.items(.executor)[j] != null) continue;
            if (self.rows.items(.template)[j] != self.rows.items(.template)[i]) continue;
            if ((self.rows.items(.dependency)[j] == none) != (self.rows.items(.dependency)[i] == none)) continue;
            if (!sameLaneJob(jobs[i], jobs[j])) continue;
            peers[n] = j;
            n += 1;
        }
        if (n == 0) return;
        self.makeExecutor(i) catch return;
        const leader = self.rows.items(.executor)[i].?;
        const list = leader.work.allocator().alloc(*execution.Executor, n) catch return;
        var taken: usize = 0;
        for (peers[0..n]) |j| {
            self.makeExecutor(j) catch continue;
            list[taken] = self.rows.items(.executor)[j].?;
            taken += 1;
            self.rows.items(.running)[j] = true;
        }
        leader.peers = list[0..taken];
    }

    /// The GPU lane form of `gather`: up to `gpu_lane_cap - 1` ready,
    /// never-started `.tran` rows of row i's template and options, from all
    /// of `urgent` and the queue (a sweep's transients are ready together
    /// under breadth-first order). A row whose executor cannot be built is
    /// left to run alone.
    /// ponytail: an ineligible sweep (`tran.gpuLaneEligible`) still gathers
    /// and then runs its lanes one after another on one worker; check the
    /// template before gathering if that ever costs a `--jobs` run.
    fn gatherWide(self: *Session, i: usize) void {
        const jobs = self.rows.items(.job);
        var peers: std.ArrayList(usize) = .empty;
        defer peers.deinit(self.allocator);
        const cap = self.config.gpu_lane_cap - 1;
        const queued = self.queue.items[@min(self.queue_head, self.queue.items.len)..];
        for ([_][]const u32{ self.urgent.items, queued }) |list| for (list) |j32| {
            if (peers.items.len == cap) break;
            const j: usize = j32;
            if (j == i or !self.ready(j) or self.rows.items(.running)[j] or self.rows.items(.executor)[j] != null) continue;
            if (std.mem.indexOfScalar(usize, peers.items, j) != null) continue;
            if (self.rows.items(.template)[j] != self.rows.items(.template)[i]) continue;
            if ((self.rows.items(.dependency)[j] == none) != (self.rows.items(.dependency)[i] == none)) continue;
            if (!sameLaneJob(jobs[i], jobs[j])) continue;
            peers.append(self.allocator, j) catch break;
        };
        if (peers.items.len == 0) return;
        self.makeExecutor(i) catch return;
        const leader = self.rows.items(.executor)[i].?;
        const list = leader.work.allocator().alloc(*execution.Executor, peers.items.len) catch return;
        var taken: usize = 0;
        for (peers.items) |j| {
            self.makeExecutor(j) catch continue;
            list[taken] = self.rows.items(.executor)[j].?;
            taken += 1;
            self.rows.items(.running)[j] = true;
        }
        leader.peers = list[0..taken];
    }

    /// Settles the peers of batch leader `i`, which has stopped: each takes
    /// the outcome its lane left, or the leader's cancel.
    fn settlePeers(self: *Session, i: usize) void {
        const leader = self.rows.items(.executor)[i].?;
        const cancelled = self.rows.items(.status)[i] == .cancelled;
        for (leader.peers) |p| {
            const j = p.row;
            std.debug.assert(self.rows.items(.running)[j]);
            self.rows.items(.running)[j] = false;
            const first = self.rows.items(.status)[j] == .pending;
            if (p.published != null) {
                self.rows.items(.status)[j] = .complete;
            } else if (cancelled or p.peer_failure == null) {
                self.rows.items(.status)[j] = .cancelled;
            } else {
                self.rows.items(.status)[j] = .failed;
                self.rows.items(.failure)[j] = p.peer_failure;
            }
            if (first) self.readerDone(j);
            self.releaseIfRead(j);
        }
    }

    /// Starts query `i`'s next quantum, building its executor first, with
    /// `signal` posted when it stops. False, the row failed and settled,
    /// when it could not start.
    fn launch(self: *Session, i: usize, quantum: Quantum, signal: *std.Io.Semaphore) bool {
        const started = blk: {
            self.makeExecutor(i) catch |err| break :blk err;
            self.rows.items(.executor)[i].?.start(quantum, signal) catch |err| break :blk err;
            self.rows.items(.running)[i] = true;
            return true;
        };
        const first = self.rows.items(.status)[i] == .pending;
        self.rows.items(.status)[i] = .failed;
        self.rows.items(.failure)[i] = started;
        if (first) self.readerDone(i);
        return false;
    }

    /// Records the quantum of running query `i`, which has stopped. Under
    /// `Config.final_plan`, a completed query's circuit, or its source's, is
    /// released once no dependent still has to copy it.
    fn settle(self: *Session, i: usize) void {
        std.debug.assert(self.rows.items(.running)[i]);
        self.rows.items(.running)[i] = false;
        const first = self.rows.items(.status)[i] == .pending;
        // A started worker always has an outcome; `NotStarted` cannot happen.
        const outcome = self.rows.items(.executor)[i].?.wait() catch unreachable;
        switch (outcome) {
            .progress => |p| {
                self.rows.items(.status)[i] = .paused;
                self.rows.items(.progress)[i] = p;
            },
            .complete => self.rows.items(.status)[i] = .complete,
            .failed => |err| {
                self.rows.items(.status)[i] = .failed;
                self.rows.items(.failure)[i] = err;
            },
            .cancelled => self.rows.items(.status)[i] = .cancelled,
        }
        if (first) self.readerDone(i);
        self.releaseIfRead(i);
        self.settlePeers(i);
    }

    /// Query `i` no longer reads its source's state.
    fn readerDone(self: *Session, i: usize) void {
        const dep = self.rows.items(.dependency)[i];
        if (dep == none) {
            self.root_readers -= 1;
        } else {
            self.rows.items(.readers)[@backingInt(dep)] -= 1;
            self.releaseIfRead(@backingInt(dep));
        }
    }

    /// Under a final plan nothing reads a finished query's circuit once
    /// its dependents have copied it; its result lives elsewhere.
    fn releaseIfRead(self: *Session, i: usize) void {
        if (self.config.final_plan and self.rows.items(.status)[i] == .complete and self.rows.items(.readers)[i] == 0)
            self.rows.items(.executor)[i].?.circuit.release();
    }

    /// Advances each of `ids` by one quantum, at most `limits.max_parallel` at
    /// a time, starting the next as soon as one stops, and writes one event
    /// per id. Every id must be ready and unique;
    /// that is checked for all of them before any runs: fails with
    /// `error.InvalidConcurrency` for a zero `max_parallel`,
    /// `error.QueryNotReady`, `error.DuplicateQuery`, or
    /// `error.BufferTooSmall` when `events` is shorter than `ids`. A query
    /// whose executor cannot be built or started is marked failed, not
    /// returned as an error. Under `Config.final_plan`, a completed query's
    /// circuit is released once no dependent still has to snapshot it.
    pub fn advanceReady(self: *Session, ids: []const QueryId, limits: Limits, events: []Advance) !usize {
        try self.validateReady(ids, limits);
        if (events.len < ids.len) return error.BufferTooSmall;
        if (ids.len == 0) return 0;
        // Positions into `ids` of the running queries.
        const running = try self.allocator.alloc(usize, @min(ids.len, limits.max_parallel));
        defer self.allocator.free(running);
        var signal: std.Io.Semaphore = .{};
        var n_running: usize = 0;
        var next: usize = 0;
        while (true) {
            while (n_running < running.len and next < ids.len) : (next += 1) {
                if (self.launch(@backingInt(ids[next]), limits.quantum, &signal)) {
                    running[n_running] = next;
                    n_running += 1;
                } else try self.event(ids[next], &events[next]);
            }
            if (n_running == 0) break;
            signal.waitUncancelable(self.io);
            var k: usize = 0;
            while (k < n_running) {
                const at = running[k];
                const i = @backingInt(ids[at]);
                if (!self.rows.items(.executor)[i].?.stopped()) {
                    k += 1;
                    continue;
                }
                self.settle(i);
                try self.event(ids[at], &events[at]);
                n_running -= 1;
                running[k] = running[n_running];
            }
        }
        self.cursor = @intCast((@backingInt(ids[ids.len - 1]) + 1) % self.rows.len);
        return ids.len;
    }

    fn event(self: *const Session, id: QueryId, out: *Advance) !void {
        const q = try self.info(id);
        out.* = .{ .requested = id, .advanced = id, .status = q.status, .target_status = q.status, .progress = q.progress, .failure = q.failure };
    }

    /// Queues every query that is ready now for `Pool.fill`, in row order;
    /// queries that turn ready later join as they do.
    fn requeue(self: *Session) !void {
        self.queue.clearRetainingCapacity();
        self.urgent.clearRetainingCapacity();
        self.queue_head = 0;
        // A row is queued in `urgent` at most once at a time.
        try self.urgent.ensureTotalCapacity(self.allocator, self.rows.len);
        self.advanceDone();
        for (self.done_rows..self.rows.len) |i| if (self.ready(i) and !self.rows.items(.running)[i]) {
            try self.queue.append(self.allocator, @intCast(i));
        };
    }

    /// The next query `Pool.fill` starts: a parked query or a finished
    /// OP's dependent first, so each point's OP and analysis run back to
    /// back, then the queue in row order.
    fn nextReady(self: *Session) ?usize {
        // Breadth-first under GPU lanes: OPs drain before their transients,
        // so the transients become ready together and gather N wide.
        if (!self.config.gpu_lanes) while (self.urgent.pop()) |i| if (self.ready(i) and !self.rows.items(.running)[i]) return i;
        while (self.queue_head < self.queue.items.len) {
            const i = self.queue.items[self.queue_head];
            self.queue_head += 1;
            if (self.ready(i) and !self.rows.items(.running)[i]) return i;
        }
        if (self.config.gpu_lanes) while (self.urgent.pop()) |i| if (self.ready(i) and !self.rows.items(.running)[i]) return i;
        return null;
    }

    /// Queues for `nextReady` what settled query `i` (and its batch's
    /// peers) made ready: itself when parked, its dependents when complete.
    fn follow(self: *Session, i: usize) void {
        for (self.rows.items(.executor)[i].?.peers) |p| self.followOne(p.row);
        self.followOne(i);
    }

    fn followOne(self: *Session, i: usize) void {
        switch (self.rows.items(.status)[i]) {
            .paused => self.urgent.appendAssumeCapacity(@intCast(i)),
            .complete => {
                var c = self.rows.items(.child)[i];
                while (c != none) : (c = self.rows.items(.sibling)[@backingInt(c)]) {
                    const j = @backingInt(c);
                    if (self.ready(j) and !self.rows.items(.running)[j]) self.urgent.appendAssumeCapacity(j);
                }
            },
            else => {},
        }
    }

    /// Runs every query to its end through a pool of `limits.max_parallel`.
    /// Fails with `error.SchedulingFailure` when queries remain that can
    /// never become ready.
    pub fn runAll(self: *Session, limits: Limits) !void {
        var pool: Pool = try .init(self.allocator, self.io, limits);
        defer pool.deinit();
        try pool.add(self);
        while (true) {
            pool.fill(self);
            if (!pool.wait()) break;
        }
        if (!self.finished()) return error.SchedulingFailure;
    }

    /// Advances `target`, or its prerequisite first, by one quantum. A
    /// terminal target returns its status without running anything. Fails
    /// as `advanceReady` does.
    pub fn advance(self: *Session, target: QueryId) !Advance {
        const target_info = try self.info(target);
        if (target_info.status.terminal()) return .{
            .requested = target,
            .advanced = target,
            .status = target_info.status,
            .target_status = target_info.status,
            .progress = target_info.progress,
            .failure = target_info.failure,
        };
        var ids: [2]QueryId = undefined;
        const n = try self.readyQueries(.{ .query = target }, &ids);
        if (n == 0 or n > ids.len) return error.SchedulingFailure;
        var events: [1]Advance = undefined;
        _ = try self.advanceReady(ids[0..1], .{}, &events);
        events[0].requested = target;
        events[0].target_status = (try self.info(target)).status;
        return events[0];
    }

    /// True when every requested query is terminal.
    pub fn finished(self: *const Session) bool {
        for (self.outputs.items[self.done_outputs..]) |id| if (!self.effectiveStatus(@backingInt(id)).terminal()) return false;
        return true;
    }

    /// Moves `done_rows` and `done_outputs` past the rows and outputs that
    /// have ended; a terminal row stays terminal. O(rows ended since).
    fn advanceDone(self: *Session) void {
        while (self.done_rows < self.rows.len and self.effectiveStatus(self.done_rows).terminal()) self.done_rows += 1;
        const outputs = self.outputs.items;
        while (self.done_outputs < outputs.len and self.effectiveStatus(@backingInt(outputs[self.done_outputs])).terminal()) self.done_outputs += 1;
    }

    /// Whether `release` freed query `id`.
    pub fn released(self: *const Session, id: QueryId) bool {
        return self.rows.items(.released)[@backingInt(id)];
    }

    /// The position of requested query `id` in `outputs`; null when it was
    /// never requested.
    pub fn outputIndex(self: *const Session, id: QueryId) !?usize {
        const k = self.rows.items(.output)[try self.index(id)];
        return if (k == no_output) null else k;
    }

    /// Frees ended query `id`'s executor: its circuit, work and result.
    /// Its status stays; `result` then fails `error.ResultUnavailable`. Its
    /// prerequisite OP goes too once no unreleased query reads it, and
    /// leaves the OP index, so a later query gets a new one. A query
    /// already released is left alone. `error.QueryNotReady` while it, or
    /// a query reading its state, has not ended.
    pub fn release(self: *Session, id: QueryId) error{ InvalidQuery, QueryNotReady }!void {
        const i = try self.index(id);
        if (self.rows.items(.released)[i]) return;
        if (!self.effectiveStatus(i).terminal() or self.rows.items(.running)[i]) return error.QueryNotReady;
        var c = self.rows.items(.child)[i];
        while (c != none) : (c = self.rows.items(.sibling)[@backingInt(c)]) {
            if (!self.rows.items(.released)[@backingInt(c)]) return error.QueryNotReady;
        }
        if (self.rows.items(.executor)[i]) |worker| worker.destroy();
        self.rows.items(.executor)[i] = null;
        self.rows.items(.released)[i] = true;
        const job = self.rows.items(.job)[i];
        if (job == .op) {
            const key: OpKey = .{ .template = self.rows.items(.template)[i], .op = job.op };
            if (self.ops.get(key)) |at| if (@backingInt(at) == i) {
                _ = self.ops.remove(key);
            };
        }
        const dep = self.rows.items(.dependency)[i];
        if (dep != none and !self.rows.items(.requested)[@backingInt(dep)]) self.release(dep) catch |err| switch (err) {
            // Another of its readers has not been released yet.
            error.QueryNotReady => {},
            else => unreachable, // else: `dep` is a valid row
        };
    }

    /// Returns the error of the first requested query that ended without a
    /// result, or null. A query whose prerequisite failed reports the
    /// prerequisite's error, so an implicit OP's OutOfMemory is not renamed
    /// DependencyFailed.
    pub fn failure(self: *const Session) ?Failure {
        return self.failureFrom(0);
    }

    /// `failure` over `outputs[from..]`.
    pub fn failureFrom(self: *const Session, from: usize) ?Failure {
        for (self.outputs.items[from..]) |id| {
            const i = @backingInt(id);
            const status = self.effectiveStatus(i);
            if (status == .complete or !status.terminal()) continue;
            if (self.rows.items(.failure)[i]) |err| return err;
            if (status == .cancelled) return error.QueryCancelled;
            const dep = self.rows.items(.dependency)[i];
            if (dep != none) if (self.rows.items(.failure)[@backingInt(dep)]) |err| return err;
            return error.DependencyFailed;
        }
        return null;
    }

    /// Returns the request `id` was appended as. Its slices live until
    /// `deinit`.
    pub fn query(self: *const Session, id: QueryId) !requests.Query {
        return self.rows.items(.job)[try self.index(id)];
    }

    /// Returns a completed query's result, valid until `deinit`. Fails with
    /// `error.ResultUnavailable` before completion.
    pub fn result(self: *const Session, id: QueryId) !Result {
        const i = try self.index(id);
        if (self.effectiveStatus(i) != .complete) return error.ResultUnavailable;
        const worker = self.rows.items(.executor)[i] orelse return error.ResultUnavailable;
        return worker.result() orelse error.ResultUnavailable;
    }

    /// The solved operating point query `id` started from: its
    /// prerequisite's, or its own for an `.op`. Null when there is none or
    /// it has not completed. Valid until `deinit`.
    pub fn operatingPoint(self: *const Session, id: QueryId) !?[]const f64 {
        const i = try self.index(id);
        const dep = self.rows.items(.dependency)[i];
        const worker = self.rows.items(.executor)[if (dep == none) i else @backingInt(dep)] orelse return null;
        return worker.operatingPoint();
    }

    /// Writes the query tree for `options.scope`, marking what the chosen
    /// preview would run next. Runs nothing; uses the same readiness order and
    /// validation as advancement.
    pub fn print(self: *const Session, writer: *std.Io.Writer, options: PrintOptions) !void {
        try self.validateScope(options.scope);
        const limits = options.limits orelse Limits{};
        if (limits.max_parallel == 0) return error.InvalidConcurrency;
        const a = self.allocator;
        const next = try a.alloc(QueryId, self.rows.len);
        defer a.free(next);
        var n_next: usize = 0;
        switch (options.preview) {
            .run_all => n_next = @min(try self.readyQueries(options.scope, next), limits.max_parallel),
            .advance => |id| {
                const n = try self.readyQueries(.{ .query = id }, next);
                n_next = @min(n, 1);
            },
            .advance_ready => |ids| {
                try self.validateReady(ids, limits);
                @memcpy(next[0..ids.len], ids);
                n_next = ids.len;
            },
        }
        const seen = try a.alloc(bool, self.rows.len);
        defer a.free(seen);
        @memset(seen, false);
        const continuations = try a.alloc(bool, self.rows.len + 1);
        defer a.free(continuations);
        var components: usize = 0;
        for (self.rows.items(.component), 0..) |component, i|
            if (component == i and self.containsComponent(options.scope, component)) {
                components += 1;
            };
        try writer.print("Problem: {d} requested queries, {d} total queries, {d} components\n", .{ self.outputs.items.len, self.rows.len, components });
        // Each component's rows in row order, CSR by component (a
        // component is numbered by its first row), so the tree is one pass.
        const starts = try a.alloc(u32, self.rows.len + 1);
        defer a.free(starts);
        @memset(starts, 0);
        for (self.rows.items(.component)) |c| starts[c + 1] += 1;
        for (1..starts.len) |c| starts[c] += starts[c - 1];
        const members = try a.alloc(u32, self.rows.len);
        defer a.free(members);
        const fill = try a.dupe(u32, starts[0..self.rows.len]);
        defer a.free(fill);
        for (self.rows.items(.component), 0..) |c, j| {
            members[fill[c]] = @intCast(j);
            fill[c] += 1;
        }
        for (self.rows.items(.component), 0..) |component, i| {
            if (component != i or !self.containsComponent(options.scope, component)) continue;
            components -= 1;
            continuations[0] = components != 0;
            try writer.print("{s} Component {d}\n", .{ connector(options.ascii, components == 0), component });
            const rows = members[starts[component]..starts[component + 1]];
            var last_query: usize = i;
            for (rows) |j| {
                if (self.contains(options.scope, j) and self.rows.items(.requested)[j]) last_query = j;
            }
            for (rows) |j| {
                if (!self.contains(options.scope, j) or !self.rows.items(.requested)[j]) continue;
                try self.printQuery(writer, j, 1, j == last_query, continuations, next[0..n_next], seen, options.ascii);
            }
            // A scope naming an implicit prerequisite still shows that query.
            if (options.scope == .query) {
                const j = @backingInt(options.scope.query);
                if (!seen[j]) try self.printQuery(writer, j, 1, j == last_query, continuations, next[0..n_next], seen, options.ascii);
            }
        }
    }

    fn containsComponent(self: *const Session, scope: Scope, component: u32) bool {
        return switch (scope) {
            .all => true,
            .component => |c| component == c,
            .query => |q| component == self.rows.items(.component)[@backingInt(q)],
        };
    }

    fn printQuery(self: *const Session, writer: *std.Io.Writer, i: usize, depth: usize, last: bool, continuations: []bool, next: []const QueryId, seen: []bool, ascii: bool) !void {
        const q = try self.info(@fromBackingInt(@intCast(i)));
        for (continuations[0..depth]) |continues|
            try writer.writeAll(if (!continues) "    " else if (ascii) "|   " else "│   ");
        try writer.print("{s} {s}q{d} {s} [{s}", .{
            connector(ascii, last),
            if (seen[i]) (if (ascii) "-> " else "↪ ") else "",
            i,
            @tagName(q.kind),
            if (q.status == .pending and self.ready(i)) "ready" else @tagName(q.status),
        });
        if (seen[i]) try writer.writeAll("; shared");
        const selected = std.mem.indexOfScalar(QueryId, next, @fromBackingInt(@intCast(i))) != null;
        if (selected) try writer.writeAll("; NEXT") else if (self.ready(i)) try writer.writeAll("; deferred by selection");
        if (q.dependency) |dep| if (!self.ready(i) and !q.status.terminal())
            try writer.print("; waiting for q{d}", .{@backingInt(dep)});
        if (q.progress) |p| try writer.print("; {s} {d}/{d}", .{ @tagName(p.phase), p.completed, p.total });
        if (q.failure) |err| try writer.print("; {s}", .{@errorName(err)});
        try writer.writeAll("]\n");
        if (seen[i]) return;
        seen[i] = true;
        continuations[depth] = !last;
        if (q.dependency) |dep| try self.printQuery(writer, @backingInt(dep), depth + 1, true, continuations, next, seen, ascii);
    }
};

/// A refilling scheduler over the queries of one or more sessions: up to
/// `limit` quanta in flight, a stopped one replaced at once. Every worker
/// posts `signal` when its quantum stops, so the coordinator wakes on
/// whichever stops first. Run it as `add` each session, then `fill` and
/// `wait` until `wait` returns false. Results do not depend on the order
/// queries start in, so output is the same at every `limit`.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limit: u16,
    quantum: Quantum,
    signal: std.Io.Semaphore = .{},
    running: std.ArrayList(Running) = .empty,

    const Running = struct { session: *Session, row: u32 };

    /// An empty pool. `error.InvalidConcurrency` for a zero `max_parallel`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, limits: Limits) !Pool {
        if (limits.max_parallel == 0) return error.InvalidConcurrency;
        var pool: Pool = .{ .allocator = allocator, .io = io, .limit = limits.max_parallel, .quantum = limits.quantum };
        try pool.running.ensureTotalCapacity(allocator, limits.max_parallel);
        return pool;
    }

    /// Cancels and settles whatever still runs (an error ended the loop
    /// early), then frees the pool.
    pub fn deinit(pool: *Pool) void {
        for (pool.running.items) |r| r.session.rows.items(.executor)[r.row].?.cancel();
        for (pool.running.items) |r| r.session.settle(r.row);
        pool.running.deinit(pool.allocator);
    }

    /// Queues `session`'s ready queries. Call once per run, before `fill`.
    pub fn add(pool: *Pool, session: *Session) !void {
        _ = pool;
        try session.requeue();
    }

    /// Starts `session`'s next ready queries while the pool has room.
    pub fn fill(pool: *Pool, session: *Session) void {
        while (pool.running.items.len < pool.limit) {
            const i = session.nextReady() orelse return;
            session.gather(i);
            if (session.launch(i, pool.quantum, &pool.signal)) {
                pool.running.appendAssumeCapacity(.{ .session = session, .row = @intCast(i) });
            } else if (session.rows.items(.executor)[i]) |leader| {
                // The batch never started: its peers run on their own.
                for (leader.peers) |p| session.rows.items(.running)[p.row] = false;
                leader.peers = &.{};
            }
        }
    }

    /// Waits until a running quantum stops, then settles every stopped
    /// one and queues what it made ready. False, without waiting, when
    /// nothing runs.
    pub fn wait(pool: *Pool) bool {
        if (pool.running.items.len == 0) return false;
        pool.signal.waitUncancelable(pool.io);
        var k: usize = 0;
        while (k < pool.running.items.len) {
            const r = pool.running.items[k];
            if (!r.session.rows.items(.executor)[r.row].?.stopped()) {
                k += 1;
                continue;
            }
            r.session.settle(r.row);
            r.session.follow(r.row);
            _ = pool.running.swapRemove(k);
        }
        return true;
    }
};

/// How far ahead of the queue head `gather` looks for a batch's peers.
const lane_window = 8 * execution.lane_width;

/// Whether two rows may share a lane batch: the same kind with equal
/// options but for the variant row and temperature, which only the circuit
/// each lane builds reads. Slices compare by content, floats by bits.
fn sameLaneJob(a: requests.Query, b: requests.Query) bool {
    return switch (a) {
        // The AC family's list is `execution.freqLaneKind`'s; keep the two adjacent in review.
        inline .op, .dc, .tran, .ac, .noise, .sp, .stb, .lstb, .acxf, .tf, .dcxf, .dcinc, .sens, .dcmatch, .dcsens, .acmatch => |o, tag| b == tag and sameDeep(stripTol(o), stripTol(@field(b, @tagName(tag)))),
        else => false,
    };
}

fn stripTol(o: anytype) @TypeOf(o) {
    var c = o;
    c.tol.variant = null;
    c.tol.temp_c = null;
    return c;
}

fn sameDeep(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.field_names) |name| if (!sameDeep(@field(a, name), @field(b, name))) return false;
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            return switch (a) {
                inline else => |payload, tag| sameDeep(payload, @field(b, @tagName(tag))),
            };
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return sameDeep(a.?, b.?);
        },
        .pointer => |p| {
            if (p.size != .slice) return a == b;
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!sameDeep(x, y)) return false;
            return true;
        },
        .float => return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)),
        .array => {
            for (a, b) |x, y| if (!sameDeep(x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}

const OpKey = struct { template: u32, op: requests.Op };
const OpIndex = std.HashMapUnmanaged(OpKey, QueryId, struct {
    pub fn hash(_: @This(), key: OpKey) u64 {
        var h: std.hash.Wyhash = .init(0);
        hashFields(&h, key);
        return h.final();
    }
    pub fn eql(_: @This(), a: OpKey, b: OpKey) bool {
        return std.meta.eql(a, b);
    }
}, std.hash_map.default_max_load_percentage);

/// Feeds `value` to `h` field by field, floats by their bits, which
/// `std.hash.autoHash` refuses. `-0.0` and `0.0` hash apart though `eql`
/// matches them, which only costs a second OP.
fn hashFields(h: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |s| inline for (s.field_names) |name| hashFields(h, @field(value, name)),
        .optional => if (value) |v| {
            h.update(&.{1});
            hashFields(h, v);
        } else h.update(&.{0}),
        .float => h.update(std.mem.asBytes(&value)),
        else => std.hash.autoHash(h, value),
    }
}

/// The OP a query needs first: its tolerances, transient-flavoured for
/// time-domain kinds, warm when a transient point asks. Null for `.op`
/// itself and a `uic` start.
fn prerequisite(job: requests.Query) ?requests.Op {
    if (job == .op or job.uic()) return null;
    return .{ .tol = switch (job) {
        inline else => |o| o.tol,
    }, .tran_op = @as(requests.Kind, job).transient(), .warm_start = job == .tran and job.tran.point.warm_start };
}

fn connector(ascii: bool, last: bool) []const u8 {
    return if (ascii) (if (last) "`--" else "|--") else (if (last) "└──" else "├──");
}

/// Deep-copies every slice reachable from `value` into `allocator`.
fn copyValue(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            var result = value;
            inline for (s.field_names) |name| @field(result, name) = try copyValue(allocator, @field(value, name));
            return result;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try copyValue(allocator, payload)),
        },
        .optional => return if (value) |payload| try copyValue(allocator, payload) else null,
        .pointer => |p| {
            if (p.size != .slice) return value;
            const result = try allocator.alloc(p.child, value.len);
            for (value, result) |src, *dst| dst.* = try copyValue(allocator, src);
            return result;
        },
        else => return value,
    }
}

/// Sidebands an HB small-signal analysis reads: 2M + 1 about one tone,
/// every signed line of a multi-tone spectrum.
fn hbSidebands(allocator: std.mem.Allocator, o: requests.HbLptv) !usize {
    if (o.extra_tones.len == 0) return 2 * @as(usize, o.n_sidebands) + 1;
    return 2 * try @import("pss/mhb.zig").lineCount(allocator, o.hb()) - 1;
}

/// Returns the shape `query` publishes over this circuit and deck, without
/// running it.
pub fn schemaOf(allocator: std.mem.Allocator, topology: *const Circuit, deck: *const Deck, query: requests.Query) !core.QuerySchema {
    const columns: usize = switch (query) {
        .op, .dcinc => deck.probes.len,
        // HSPICE `.op <time>` publishes the `.op` layout, with no time column.
        .tran => |o| deck.probes.len + @intFromBool(!o.snapshot),
        .tran_noise => |o| deck.probes.len + 1 + @intFromBool(o.sde),
        .tf => 3,
        .lstb => |o| if (o.margins) 5 else 8,
        .dcxf => |o| (if (o.tf_only) @as(usize, 1) else 3) * o.sources.len,
        .acxf => |o| 1 + (if (o.tf_only) @as(usize, 1) else 3) * o.sources.len,
        .noise => |o| try @import("ac/noise.zig").columnCount(allocator, topology.batches, topology.batch_types, o),
        // Time, then peak and rms per probe.
        .envelope => 1 + 2 * deck.probes.len,
        .four => 4,
        .disto => |o| if (o.plot == .summary) 4 else deck.probes.len + 1,
        .pz, .stb, .pnoise, .hbnoise, .phasenoise, .fft => 2,
        .pac => |o| 2 + 2 * @as(usize, o.n_harmonics),
        .hbac => |o| 1 + try hbSidebands(allocator, o),
        .pxf => |o| 1 + (1 + 2 * @as(usize, o.n_harmonics)) * topology.n,
        .hbxf => |o| 1 + try hbSidebands(allocator, o) * topology.n,
        .hblin => |o| 1 + o.ports.len * o.ports.len + @intFromBool(o.noise and o.ports.len >= 2),
        .sp => |o| @import("ac/sp.zig").columns(@import("ac/sp.zig").modeCount(o.ports), o.lin),
        // The parameters `.sens` lists, which isSensParam narrows (#154).
        .sens => blk: {
            var refs: std.ArrayList(ParamRef) = .empty;
            defer refs.deinit(allocator);
            var n: usize = 0;
            for (topology.batches) |b| {
                refs.clearRetainingCapacity();
                try b.hooks.collect_params(b.ctx, allocator, &refs).unwrap();
                for (refs.items) |r| n += @intFromBool(@import("sweep/sens.zig").isSensParam(b.type_name, r.param_name));
            }
            break :blk n;
        },
        .dcmatch, .dcsens, .acmatch => blk: {
            const groups = switch (query) {
                inline .dcmatch, .dcsens, .acmatch => |o| o.variations.starts.len -| 1,
                else => 0,
            };
            const extra: usize = switch (query) {
                .dcmatch => 1,
                .acmatch => 5,
                else => 0,
            };
            if (groups != 0) break :blk groups + extra;
            var refs: std.ArrayList(ParamRef) = .empty;
            defer refs.deinit(allocator);
            try types.Circuit.collectTyped(topology.batches, topology.batch_types, allocator, &refs);
            break :blk refs.items.len + extra;
        },
        else => deck.probes.len + 1,
    };
    const tran = @import("tran/tran.zig");
    const ac = @import("ac/ac.zig");
    const streamable = switch (query) {
        .tran => |o| !o.snapshot,
        .ac => true,
        else => false, // else: only a transient or AC sweep streams its rows
    };
    return .{
        .kind = query,
        .columns = columns,
        .portless = query == .sp and query.sp.ports.len == 0 and deck.source_branch == 0,
        .plotname = if (!streamable) "" else if (query == .tran) tran.plotname else ac.plotname,
        .scale = if (!streamable) "" else if (query == .tran) tran.scale else ac.scale,
    };
}

test copyValue {
    // The copy shares no slice with the request, so a caller may free or
    // reuse its option buffers once `append` returns.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tones = [_]f64{ 2e3, 3e3 };
    var harms = [_]u16{ 2, 3 };
    const job: requests.Query = .{ .hb = .{ .f0 = 1e3, .extra_tones = &tones, .extra_harmonics = &harms } };
    const copy = try copyValue(arena.allocator(), job);
    tones[0] = 0;
    harms[1] = 0;
    try std.testing.expectEqual(@as(f64, 1e3), copy.hb.f0);
    try std.testing.expectEqualSlices(f64, &.{ 2e3, 3e3 }, copy.hb.extra_tones);
    try std.testing.expectEqualSlices(u16, &.{ 2, 3 }, copy.hb.extra_harmonics);
    // An empty slice copies to an empty slice.
    const plain = try copyValue(arena.allocator(), requests.Query{ .hb = .{ .f0 = 1e3 } });
    try std.testing.expectEqual(@as(usize, 0), plain.hb.extra_tones.len);
}

test prerequisite {
    try std.testing.expectEqual(null, prerequisite(.{ .op = .{} }));
    try std.testing.expectEqual(null, prerequisite(.{ .tran = .{ .t_stop = 1e-6, .uic = true } }));
    // A transient-family query gets a MODETRANOP point with its own tolerances.
    const tran = prerequisite(.{ .tran = .{ .t_stop = 1e-6, .tol = .{ .reltol = 1e-4 } } }).?;
    try std.testing.expect(tran.tran_op);
    try std.testing.expectEqual(@as(f64, 1e-4), tran.tol.reltol);
    try std.testing.expect(!tran.warm_start);
    try std.testing.expect(prerequisite(.{ .tran = .{ .t_stop = 1e-6, .point = .{ .warm_start = true } } }).?.warm_start);
    const ac = prerequisite(.{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 1e3 } } }).?;
    try std.testing.expect(!ac.tran_op);
    try std.testing.expect(!ac.warm_start);
}

test "Status.terminal" {
    for ([_]Status{ .pending, .paused }) |s| try std.testing.expect(!s.terminal());
    for ([_]Status{ .complete, .failed, .dependency_failed, .cancelled }) |s| try std.testing.expect(s.terminal());
}
