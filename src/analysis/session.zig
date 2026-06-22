//! Session: the query graph and its cooperative scheduler. Each row is one
//! query plus its implicit OP prerequisite; numerical state lives in the
//! row's Executor.
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
const validateDeck = @import("validate.zig").validateDeck;

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
    failure: ?anyerror,
};
/// What one advancement did: `advanced` may be the prerequisite of
/// `requested`, and `target_status` is the requested query's status after it.
pub const Advance = struct {
    requested: QueryId,
    advanced: QueryId,
    status: Status,
    target_status: Status,
    delivery_error: ?anyerror = null,
    progress: ?progress.Event = null,
    failure: ?anyerror = null,
};
const Row = struct {
    job: requests.Query,
    dependency: QueryId = none,
    component: u32,
    requested: bool,
    status: Status = .pending,
    progress: ?progress.Event = null,
    failure: ?anyerror = null,
    executor: ?*execution.Executor = null,
};

/// The query graph over one prepared circuit and deck, both borrowed for the
/// session's lifetime. `QueryId` is the row index.
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, topology: *const Circuit, deck: *const Deck, config: execution.Config) Session {
        return .{ .allocator = allocator, .io = io, .topology = topology, .deck = deck, .config = config };
    }

    pub fn deinit(self: *Session) void {
        // Newest first: dependents join before the OP products they copied from.
        var i = self.rows.len;
        while (i != 0) {
            i -= 1;
            if (self.rows.items(.executor)[i]) |worker| worker.destroy();
        }
        self.rows.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
        for (self.request_arenas.items) |*arena| arena.deinit();
        self.request_arenas.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds `jobs`, writing their ids to `ids`, and returns `jobs.len`. Each
    /// non-OP job shares an existing matching OP prerequisite or gets a new
    /// one. All-or-nothing: every job is validated and deep-copied before any
    /// row or id is published.
    pub fn append(self: *Session, jobs: []const requests.Query, ids: []QueryId) !usize {
        if (ids.len < jobs.len) return error.BufferTooSmall;
        if (jobs.len == 0) return 0;
        const max_rows = std.math.add(usize, self.rows.len, try std.math.mul(usize, jobs.len, 2)) catch return error.TooManyQueries;
        if (max_rows >= std.math.maxInt(u32)) return error.TooManyQueries;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var candidate: std.MultiArrayList(Row) = .empty;
        errdefer candidate.deinit(self.allocator);
        try candidate.ensureTotalCapacity(self.allocator, max_rows);
        for (0..self.rows.len) |i| candidate.appendAssumeCapacity(self.rows.get(i));
        const new_ids = try a.alloc(QueryId, jobs.len);
        for (jobs, new_ids) |job, *id| {
            try validateDeck(job, self.topology.n, self.deck);
            const owned = try copyValue(a, job);
            var dependency = none;
            if (prerequisite(owned)) |op| {
                dependency = findOp(candidate, op) orelse blk: {
                    const dep: QueryId = @enumFromInt(candidate.len);
                    candidate.appendAssumeCapacity(.{
                        .job = .{ .op = op },
                        .component = @intFromEnum(dep),
                        .requested = false,
                    });
                    break :blk dep;
                };
            }
            // An explicit OP can expose an already shared prerequisite product.
            if (owned == .op) {
                if (findOp(candidate, owned.op)) |existing| {
                    candidate.items(.requested)[@intFromEnum(existing)] = true;
                    id.* = existing;
                    continue;
                }
            }
            id.* = @enumFromInt(candidate.len);
            candidate.appendAssumeCapacity(.{
                .job = owned,
                .dependency = dependency,
                .component = if (dependency == none) @intFromEnum(id.*) else candidate.items(.component)[@intFromEnum(dependency)],
                .requested = true,
            });
        }
        try self.outputs.ensureUnusedCapacity(self.allocator, jobs.len);
        try self.request_arenas.ensureUnusedCapacity(self.allocator, 1);
        self.rows.deinit(self.allocator);
        self.rows = candidate;
        for (new_ids) |id| {
            if (std.mem.indexOfScalar(QueryId, self.outputs.items, id) == null)
                self.outputs.appendAssumeCapacity(id);
        }
        self.request_arenas.appendAssumeCapacity(arena);
        @memcpy(ids[0..jobs.len], new_ids);
        return jobs.len;
    }

    pub fn count(self: *const Session) u32 {
        return @intCast(self.rows.len);
    }

    fn index(self: *const Session, id: QueryId) !usize {
        const i = @intFromEnum(id);
        if (i >= self.rows.len) return error.InvalidQuery;
        return i;
    }

    fn effectiveStatus(self: *const Session, i: usize) Status {
        const status = self.rows.items(.status)[i];
        if (status.terminal()) return status;
        const dep = self.rows.items(.dependency)[i];
        if (dep != none) {
            const ds = self.rows.items(.status)[@intFromEnum(dep)];
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
            .query => |id| @intFromEnum(id) == i or self.rows.items(.dependency)[@intFromEnum(id)] == @as(QueryId, @enumFromInt(i)),
        };
    }

    fn ready(self: *const Session, i: usize) bool {
        if (self.effectiveStatus(i).terminal()) return false;
        const dep = self.rows.items(.dependency)[i];
        return dep == none or self.rows.items(.status)[@intFromEnum(dep)] == .complete;
    }

    /// Copies the ready queries in `scope` into `ids` in scheduler order and
    /// returns how many there are. When `ids` is too short, writes nothing and
    /// returns the required length.
    pub fn readyQueries(self: *const Session, scope: Scope, ids: []QueryId) !usize {
        try self.validateScope(scope);
        var n: usize = 0;
        for (0..self.rows.len) |i| if (self.contains(scope, i) and self.ready(i)) {
            n += 1;
        };
        if (ids.len < n) return n;
        var out: usize = 0;
        for (0..self.rows.len) |offset| {
            const i = (offset + self.cursor) % self.rows.len;
            if (!self.contains(scope, i) or !self.ready(i)) continue;
            ids[out] = @enumFromInt(i);
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
        const started = if (self.config.timing_in_depth) std.Io.Timestamp.now(self.io, .awake) else null;
        const dep = self.rows.items(.dependency)[i];
        const initial = if (dep == none) null else self.rows.items(.executor)[@intFromEnum(dep)];
        self.rows.items(.executor)[i] = try execution.Executor.create(
            self.allocator,
            self.io,
            self.topology,
            self.deck,
            self.rows.items(.job)[i],
            initial,
            self.config,
        );
        if (started) |start| {
            self.rows.items(.executor)[i].?.controller.options.timing_query = @enumFromInt(i);
            const elapsed = start.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
            std.debug.print("timing: query {d} {s} setup: {d:.6}ms\n", .{
                i, @tagName(self.rows.items(.job)[i]), @as(f64, @floatFromInt(elapsed)) / 1e6,
            });
        }
    }

    /// Advances each of `ids` by one quantum, at most `limits.max_parallel` at
    /// a time, and writes one event per id. Every id must be ready and unique;
    /// that is checked for all of them before any runs.
    pub fn advanceReady(self: *Session, ids: []const QueryId, limits: Limits, events: []Advance) !usize {
        try self.validateReady(ids, limits);
        if (events.len < ids.len) return error.BufferTooSmall;
        var offset: usize = 0;
        while (offset < ids.len) {
            const end = @min(ids.len, offset + limits.max_parallel);
            for (ids[offset..end]) |id| {
                const i = @intFromEnum(id);
                self.makeExecutor(i) catch |err| {
                    self.rows.items(.status)[i] = .failed;
                    self.rows.items(.failure)[i] = err;
                    continue;
                };
                self.rows.items(.executor)[i].?.start(limits.quantum) catch |err| {
                    self.rows.items(.status)[i] = .failed;
                    self.rows.items(.failure)[i] = err;
                };
            }
            for (ids[offset..end], events[offset..end]) |id, *event| {
                const i = @intFromEnum(id);
                if (self.rows.items(.status)[i] != .failed) {
                    const outcome = try self.rows.items(.executor)[i].?.wait();
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
                }
                const q = try self.info(id);
                event.* = .{ .requested = id, .advanced = id, .status = q.status, .target_status = q.status, .progress = q.progress, .failure = q.failure };
                self.cursor = @intCast((i + 1) % self.rows.len);
            }
            offset = end;
        }
        return ids.len;
    }

    /// Advances `target`, or its prerequisite first, by one quantum. A
    /// terminal target returns its status without running anything.
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
        for (self.outputs.items) |id| if (!self.effectiveStatus(@intFromEnum(id)).terminal()) return false;
        return true;
    }

    /// Returns the error of the first requested query that ended without a
    /// result, or null.
    pub fn failure(self: *const Session) ?anyerror {
        for (self.outputs.items) |id| {
            const i = @intFromEnum(id);
            const status = self.effectiveStatus(i);
            if (status == .complete or !status.terminal()) continue;
            return self.rows.items(.failure)[i] orelse if (status == .cancelled) error.QueryCancelled else error.DependencyFailed;
        }
        return null;
    }

    /// Returns a completed query's result, valid until `deinit`.
    /// The request `id` was appended as.
    pub fn query(self: *const Session, id: QueryId) !requests.Query {
        return self.rows.items(.job)[try self.index(id)];
    }

    pub fn result(self: *const Session, id: QueryId) !Result {
        const i = try self.index(id);
        if (self.effectiveStatus(i) != .complete) return error.ResultUnavailable;
        return self.rows.items(.executor)[i].?.result() orelse error.ResultUnavailable;
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
        for (self.rows.items(.component), 0..) |component, i| {
            if (component != i or !self.containsComponent(options.scope, component)) continue;
            components -= 1;
            continuations[0] = components != 0;
            try writer.print("{s} Component {d}\n", .{ connector(options.ascii, components == 0), component });
            var last_query: usize = i;
            for (0..self.rows.len) |j| {
                if (self.rows.items(.component)[j] == component and self.contains(options.scope, j) and
                    self.rows.items(.requested)[j]) last_query = j;
            }
            for (0..self.rows.len) |j| {
                if (self.rows.items(.component)[j] != component or !self.contains(options.scope, j) or
                    !self.rows.items(.requested)[j]) continue;
                try self.printQuery(writer, j, 1, j == last_query, continuations, next[0..n_next], seen, options.ascii);
            }
            // A scope naming an implicit prerequisite still shows that query.
            if (options.scope == .query) {
                const j = @intFromEnum(options.scope.query);
                if (!seen[j]) try self.printQuery(writer, j, 1, j == last_query, continuations, next[0..n_next], seen, options.ascii);
            }
        }
    }

    fn containsComponent(self: *const Session, scope: Scope, component: u32) bool {
        return switch (scope) {
            .all => true,
            .component => |c| component == c,
            .query => |q| component == self.rows.items(.component)[@intFromEnum(q)],
        };
    }

    fn printQuery(self: *const Session, writer: *std.Io.Writer, i: usize, depth: usize, last: bool, continuations: []bool, next: []const QueryId, seen: []bool, ascii: bool) !void {
        const q = try self.info(@enumFromInt(i));
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
        const selected = std.mem.indexOfScalar(QueryId, next, @enumFromInt(i)) != null;
        if (selected) try writer.writeAll("; NEXT") else if (self.ready(i)) try writer.writeAll("; deferred by selection");
        if (q.dependency) |dep| if (!self.ready(i) and !q.status.terminal())
            try writer.print("; waiting for q{d}", .{@intFromEnum(dep)});
        if (q.progress) |p| try writer.print("; {s} {d}/{d}", .{ @tagName(p.phase), p.completed, p.total });
        if (q.failure) |err| try writer.print("; {s}", .{@errorName(err)});
        try writer.writeAll("]\n");
        if (seen[i]) return;
        seen[i] = true;
        continuations[depth] = !last;
        if (q.dependency) |dep| try self.printQuery(writer, @intFromEnum(dep), depth + 1, true, continuations, next, seen, ascii);
    }
};

fn findOp(rows: std.MultiArrayList(Row), op: requests.Op) ?QueryId {
    for (rows.items(.job), 0..) |job, i| if (job == .op and std.meta.eql(job.op, op)) return @enumFromInt(i);
    return null;
}

/// The OP a query needs first: its tolerances, transient-flavoured for
/// time-domain kinds. Null for `.op` itself and `.tran uic`.
fn prerequisite(job: requests.Query) ?requests.Op {
    if (job == .op or (job == .tran and job.tran.uic)) return null;
    return .{ .tol = switch (job) {
        inline else => |o| o.tol,
    }, .tran_op = @as(requests.Kind, job).transient() };
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
            inline for (s.fields) |field| @field(result, field.name) = try copyValue(allocator, @field(value, field.name));
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

/// Returns the shape `query` publishes over this circuit and deck, without
/// running it.
pub fn schemaOf(allocator: std.mem.Allocator, topology: *const Circuit, deck: *const Deck, query: requests.Query) !core.QuerySchema {
    const columns: usize = switch (query) {
        .op, .dcinc => deck.probes.len,
        // HSPICE `.op <time>` publishes the `.op` layout, with no time column.
        .tran => |o| deck.probes.len + @intFromBool(!o.snapshot),
        .tf => 3,
        .lstb => |o| if (o.margins) 5 else 8,
        .dcxf => |o| (if (o.tf_only) @as(usize, 1) else 3) * o.sources.len,
        .acxf => |o| 1 + (if (o.tf_only) @as(usize, 1) else 3) * o.sources.len,
        .noise => |o| if (o.integrated) 1 else 2,
        .four, .disto => 4,
        .pz, .stb, .pnoise, .hbnoise, .phasenoise, .fft => 2,
        .pac => |o| 2 + 2 * @as(usize, o.n_harmonics),
        .hbac => |o| 2 + 2 * @as(usize, o.n_sidebands),
        .pxf => |o| 1 + (1 + 2 * @as(usize, o.n_harmonics)) * topology.n,
        .hbxf => |o| 1 + (1 + 2 * @as(usize, o.n_sidebands)) * topology.n,
        .hblin => |o| 1 + o.ports.len * o.ports.len,
        .sp => |o| @import("ac/sp.zig").columns(@max(o.ports.len, 1), o.lin),
        .sens, .dcmatch, .dcsens, .acmatch => blk: {
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
    return .{
        .kind = query,
        .columns = columns,
        .portless = query == .sp and query.sp.ports.len == 0 and deck.source_branch == 0,
    };
}
