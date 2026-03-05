//! Query graph and coordinator. Numerical state remains in each Executor.
const std = @import("std");
const requests = @import("requests");
const Prepared = @import("problem_types").Prepared;
const execution = @import("executor.zig");
const progress = @import("progress.zig");
const Result = @import("types.zig").Result;

pub const QueryId = requests.QueryId;
const none = requests.invalid_query;
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
pub const Scope = union(enum) { all, query: QueryId, component: u32 };
pub const Limits = struct { max_parallel: u16 = 1 };
pub const Preview = union(enum) { run_all, advance: QueryId, advance_ready: []const QueryId };
pub const PrintOptions = struct {
    scope: Scope = .all,
    preview: Preview = .run_all,
    ascii: bool = false,
    limits: ?Limits = null,
};
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

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    prepared: *const Prepared,
    config: execution.Config,
    rows: std.MultiArrayList(Row) = .empty,
    outputs: std.ArrayList(QueryId) = .empty,
    request_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    cursor: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, prepared: *const Prepared, config: execution.Config) Session {
        return .{ .allocator = allocator, .io = io, .prepared = prepared, .config = config };
    }

    pub fn deinit(self: *Session) void {
        // Join dependents before releasing their immutable OP products.
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

    /// Validates and copies the whole extension before publishing IDs or rows.
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
            try validatePrepared(job, self.prepared);
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

    /// Copy-out in scheduler order. Returns required capacity without partial writes.
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
            self.prepared,
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

    /// Every selected query is on the initial ready frontier; validation is atomic.
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
                self.rows.items(.executor)[i].?.start() catch |err| {
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

    pub fn finished(self: *const Session) bool {
        for (self.outputs.items) |id| if (!self.effectiveStatus(@intFromEnum(id)).terminal()) return false;
        return true;
    }

    pub fn failure(self: *const Session) ?anyerror {
        for (self.outputs.items) |id| {
            const i = @intFromEnum(id);
            const status = self.effectiveStatus(i);
            if (status == .complete or !status.terminal()) continue;
            return self.rows.items(.failure)[i] orelse if (status == .cancelled) error.QueryCancelled else error.DependencyFailed;
        }
        return null;
    }

    pub fn result(self: *const Session, id: QueryId) !Result {
        const i = try self.index(id);
        if (self.effectiveStatus(i) != .complete) return error.ResultUnavailable;
        return self.rows.items(.executor)[i].?.result() orelse error.ResultUnavailable;
    }

    /// Pure preview: uses the same readiness order and validation as advancement.
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

fn prerequisite(job: requests.Query) ?requests.Op {
    if (job == .op or (job == .tran and job.tran.uic)) return null;
    return .{ .tol = switch (job) {
        inline else => |o| o.tol,
    }, .tran_op = switch (job) {
        .tran, .four, .tran_noise, .envelope, .pss, .qpss, .pnoise, .pac, .pxf => true,
        else => false,
    } };
}

fn connector(ascii: bool, last: bool) []const u8 {
    return if (ascii) (if (last) "`--" else "|--") else (if (last) "└──" else "├──");
}

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

fn finite(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .float => std.math.isFinite(value),
        .@"struct" => |s| blk: {
            inline for (s.fields) |field| {
                const v = @field(value, field.name);
                if (comptime std.mem.eql(u8, field.name, "dx_clamp")) {
                    if (std.math.isNan(v) or v <= 0) break :blk false;
                } else if (!finite(v)) break :blk false;
            }
            break :blk true;
        },
        .optional => if (value) |v| finite(v) else true,
        .pointer => |p| blk: {
            if (p.size == .slice) for (value) |v| if (!finite(v)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

fn sweep(start: f64, stop: f64, step: f64) !usize {
    const intervals = (stop - start) / step;
    if (step == 0 or intervals < 0) return error.InvalidQueryOptions;
    const count = @floor(intervals + 1e-6) + 1;
    if (!std.math.isFinite(count) or count >= @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return error.InvalidQueryOptions;
    // Repeated-addition sweeps must make representable progress at both ends.
    if (start != stop and (start + step == start or stop + step == stop)) return error.InvalidQueryOptions;
    return @intFromFloat(count);
}

fn positive(value: f64) !void {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidQueryOptions;
}

fn timeStep(value: f64) !void {
    try positive(value);
    // Trapezoidal companion stamps use 2/dt.
    try positive(2 / value);
}

fn frequency(value: f64) !void {
    try timeStep(1 / value);
    try positive(2 * std.math.pi * value);
}

// Bound derived slabs before entering algorithms with unchecked arithmetic.
// Sixty-four f64 planes leave room for each family's sums and byte counts;
// this is a representability ceiling, not an allocation or performance budget.
fn elements(factors: []const usize) !usize {
    var count: usize = 1;
    for (factors) |factor| count = std.math.mul(usize, count, factor) catch return error.InvalidQueryOptions;
    if (count > std.math.maxInt(usize) / (64 * @sizeOf(f64))) return error.InvalidQueryOptions;
    return count;
}

fn tolerance(t: @import("numerics").Tolerances) !void {
    inline for (.{ "reltol", "abstol", "vntol", "residual_tol", "chgtol", "trtol" }) |field|
        try positive(@field(t, field));
    if (t.gmin < 0 or t.gmin_start < 0 or t.itl1 == 0 or t.itl2 == 0 or t.itl4 == 0)
        return error.InvalidQueryOptions;
}

pub fn validate(query: requests.Query, n: u32) !void {
    @setEvalBranchQuota(10000);
    if (n == 0) return error.InvalidQueryOptions;
    switch (query) {
        inline else => |o| {
            if (!finite(o)) return error.InvalidQueryOptions;
            try tolerance(o.tol);
            inline for (.{ "out_node", "output_node", "source_node", "ac_source_node", "probe_p", "probe_n", "input_branch", "drive_branch" }) |field| {
                if (@hasField(@TypeOf(o), field)) {
                    const node = @field(o, field);
                    if (@typeInfo(@TypeOf(node)) == .optional) {
                        if (node) |v| if (v >= n) return error.InvalidQueryOptions;
                    } else if (node >= n) return error.InvalidQueryOptions;
                }
            }
            if (@hasField(@TypeOf(o), "f_start")) {
                if (o.f_start <= 0 or o.f_stop < o.f_start) return error.InvalidQueryOptions;
                try frequency(o.f_start);
                try frequency(o.f_stop);
                if (@hasField(@TypeOf(o), "points_per_decade")) {
                    const count = @ceil((@log10(o.f_stop) - @log10(o.f_start)) * @as(f64, @floatFromInt(o.points_per_decade))) + 1;
                    if (!std.math.isFinite(count) or count >= @as(f64, @floatFromInt(std.math.maxInt(u32))))
                        return error.InvalidQueryOptions;
                    _ = try elements(&.{ @intFromFloat(count), n, 2 });
                }
            }
            inline for (.{ "points_per_decade", "n_points", "n_samples", "n_time_samples", "pss_n_samples", "n_trials", "max_steps", "max_iter", "max_newton", "max_shooting_iter", "carrier_steps_per_period", "periods_per_outer_step", "min_periods_per_step", "max_periods_per_step", "max_outer_steps", "max_points", "m_max", "gmres_restart", "gmres_max_restarts", "max_newton_iter", "pss_periods", "pss_max_newton_iter", "pss_shoot_max_iter", "pss_newton_max_iter", "qr_max_iter" }) |field| {
                if (@hasField(@TypeOf(o), field)) if (@field(o, field) == 0) return error.InvalidQueryOptions;
            }
            inline for (.{ "f0", "f1", "f2", "f_lo", "f_fundamental", "period", "t_carrier", "dt_init", "dt_min", "t_stop" }) |field| {
                if (@hasField(@TypeOf(o), field) and @TypeOf(o) != requests.Temp)
                    if (@field(o, field) <= 0) return error.InvalidQueryOptions;
            }
            inline for (.{ "shooting_tol", "fd_epsilon", "newton_tol", "gmres_tol", "hb_tol", "pss_newton_tol", "pss_shoot_tol", "krylov_tol", "qr_tol", "fd_eps", "envelope_reltol" }) |field| {
                if (@hasField(@TypeOf(o), field)) try positive(@field(o, field));
            }
            inline for (.{ "f0", "f1", "f2", "f_lo", "f_fundamental" }) |field| {
                if (@hasField(@TypeOf(o), field)) try frequency(@field(o, field));
            }
            if (@hasField(@TypeOf(o), "gmres_restart")) {
                _ = try elements(&.{ @as(usize, o.gmres_restart) + 1, @as(usize, o.gmres_restart) + 1 });
                _ = try elements(&.{ @as(usize, o.gmres_restart) + 1, n });
            }
        },
    }
    switch (query) {
        .dc => |o| {
            const inner = try sweep(o.start, o.stop, o.step);
            const outer = if (o.hasOuter()) try sweep(o.start2, o.stop2, o.step2) else 1;
            if (o.source2_index != null and o.source2_is_temp) return error.InvalidQueryOptions;
            _ = try elements(&.{ inner, outer, @as(usize, n) + 1 });
        },
        .temp => |o| {
            // The current temperature driver and numPoints are ascending only.
            if (o.t_step <= 0) return error.InvalidQueryOptions;
            const count = try sweep(o.t_start, o.t_stop, o.t_step);
            _ = try elements(&.{ count, @as(usize, n) + 1 });
            try validate(.{ .dc = o.dc_options }, n);
        },
        .mc => |o| {
            if (o.variation < 0) return error.InvalidQueryOptions;
            try validate(.{ .dc = o.dc_options }, n);
            _ = try elements(&.{ o.n_trials, @as(usize, n) + 1 });
        },
        .tran => |o| {
            if (o.dt_min > o.dt_init or o.step_fn != null or o.step_ctx != null) return error.InvalidQueryOptions;
            if (o.dt_max) |max| if (max <= 0 or max < o.dt_min) return error.InvalidQueryOptions;
            try timeStep(o.dt_min);
            try timeStep(o.dt_init);
            try timeStep(o.dt_max orelse o.t_stop / 50);
            if (o.max_steps == std.math.maxInt(u32)) return error.InvalidQueryOptions;
        },
        .tran_noise => |o| {
            if (o.dt_max < o.dt_min or o.dt_min > o.dt_init or o.max_steps == std.math.maxInt(u32)) return error.InvalidQueryOptions;
            try timeStep(o.dt_min);
            try timeStep(o.dt_init);
            try timeStep(o.dt_max);
        },
        .pac, .pxf => |o| {
            if (!std.math.isPowerOfTwo(o.n_time_samples) or @as(u32, o.n_time_samples) < 2 * (2 * @as(u32, o.n_harmonics) + 1))
                return error.InvalidQueryOptions;
            try timeStep((1 / o.f_lo) / @as(f64, @floatFromInt(o.n_time_samples)));
            const bands = 2 * @as(usize, o.n_harmonics) + 1;
            _ = try elements(&.{ bands, n, bands, n });
            _ = try elements(&.{ o.n_time_samples, n, n });
            try frequency(o.f_stop + @as(f64, @floatFromInt(o.n_harmonics)) * o.f_lo);
        },
        .sp => |o| {
            for (o.ports) |port| {
                if (port.node >= n or port.branch >= n or port.z0 <= 0) return error.InvalidQueryOptions;
            }
            const ports = @max(o.ports.len, 1);
            _ = try elements(&.{ o.n_points, ports, ports, 2 });
        },
        .four => |o| {
            if (o.tran_opts) |tran| {
                try validate(.{ .tran = tran }, n);
            } else {
                try positive(5 / o.f_fundamental);
                try timeStep(1 / (200 * o.f_fundamental));
            }
        },
        .pss => |o| {
            if (o.n_samples == std.math.maxInt(u32)) return error.InvalidQueryOptions;
            try timeStep(o.period / @as(f64, @floatFromInt(o.n_samples)));
            _ = try elements(&.{ @as(usize, o.n_samples) + 1, @as(usize, n) + 1 });
        },
        .pnoise => |o| {
            try timeStep((1 / o.f_fundamental) / @as(f64, @floatFromInt(o.pss_n_samples)));
            _ = try elements(&.{ o.pss_n_samples, n, n });
            try frequency(o.f_stop + @as(f64, @floatFromInt(o.n_sidebands)) * o.f_fundamental);
        },
        .hb => |o| {
            if (o.n_harmonics == 0) return error.InvalidQueryOptions;
            const bands = 2 * @as(usize, o.n_harmonics) + 1;
            _ = try elements(&.{ bands, n, bands, n });
            _ = try elements(&.{ bands, bands });
            try frequency(o.f0 * @as(f64, @floatFromInt(o.n_harmonics)));
        },
        .qpss => |o| {
            const bands = try elements(&.{ 2 * @as(usize, o.k1) + 1, 2 * @as(usize, o.k2) + 1 });
            const width = try elements(&.{ bands, n, 2 });
            if (width > std.math.maxInt(u32)) return error.InvalidQueryOptions;
            _ = try elements(&.{ bands, bands });
            _ = try elements(&.{ bands, n, n });
            _ = try elements(&.{ width, @as(usize, o.gmres_restart) + 1 });
            try frequency(o.f1 * @as(f64, @floatFromInt(@max(o.k1, 1))) + o.f2 * @as(f64, @floatFromInt(@max(o.k2, 1))));
        },
        .disto => {
            _ = try elements(&.{ n, n, n });
            try frequency(query.disto.f_stop * 2);
        },
        .envelope => |o| {
            if (o.min_periods_per_step > o.max_periods_per_step or o.periods_per_outer_step < o.min_periods_per_step or
                o.periods_per_outer_step > o.max_periods_per_step or o.max_outer_steps > std.math.maxInt(u32) - 2)
                return error.InvalidQueryOptions;
            try timeStep(o.t_carrier / @as(f64, @floatFromInt(o.carrier_steps_per_period)));
            try positive(o.t_carrier * @as(f64, @floatFromInt(o.max_periods_per_step)));
            _ = try elements(&.{ @as(usize, o.max_outer_steps) + 2, 2 * @as(usize, n) + 1 });
        },
        .matex => |o| {
            try timeStep(o.gamma orelse o.t_stop / 1000);
            try timeStep(o.h_output_cap orelse o.t_stop / 200);
            _ = try elements(&.{ @as(usize, o.m_max) + 1, @as(usize, o.m_max) + 1 });
            _ = try elements(&.{ @as(usize, o.m_max) + 1, n });
            _ = try elements(&.{ o.max_points, @as(usize, n) + 1 });
        },
        .tf, .pz => {
            _ = try elements(&.{ n, n });
        },
        else => {},
    }
}

pub fn validatePrepared(query: requests.Query, prepared: *const Prepared) !void {
    try validate(query, prepared.circuit.n);
    if (query == .dc) {
        // DC's current contract selects V sources when present, otherwise I.
        // Frontend rejects mixed-current sweeps instead of aliasing ordinals.
        const count = if (prepared.bindings.v_names.len != 0) prepared.bindings.v_names.len else prepared.bindings.i_names.len;
        if (query.dc.source_index >= count) return error.DcSweepSourceNotFound;
        if (query.dc.source2_index) |index| if (index >= count) return error.DcSweepSourceNotFound;
    }
}

const output = @import("output_types");
const ir = @import("device_ir");

pub fn validateOutputSchema(allocator: std.mem.Allocator, prepared: *const Prepared, query: requests.Query, format: output.Format) !void {
    if (format == .touchstone or format == .citi) {
        if (query != .sp) return error.NotSParameterData;
        if (query.sp.ports.len == 0 and prepared.source_branch == 0) return error.NoPorts;
    }
    if (format != .sst2 and format != .fsdb) return;
    // SST2 has a fixed 64-variable header; FSDB has 16-bit label lengths.
    const nvars: usize = switch (query) {
        .op => prepared.probes.len,
        .tf => 3,
        .noise => |o| if (o.integrated) 1 else 2,
        .four, .disto => 4,
        .pz, .stb, .pnoise => 2,
        .pac => |o| 2 + 2 * @as(usize, o.n_harmonics),
        .pxf => |o| 1 + (1 + 2 * @as(usize, o.n_harmonics)) * prepared.circuit.n,
        .sp => |o| blk: {
            const n = @max(o.ports.len, 1);
            break :blk 1 + try std.math.mul(usize, n, n);
        },
        .sens, .dcmatch => blk: {
            var refs: std.ArrayList(ir.ParamRef) = .empty;
            defer refs.deinit(allocator);
            for (prepared.circuit.batches) |batch| try batch.hooks.collect_params(batch.ctx, allocator, &refs);
            break :blk refs.items.len + @intFromBool(query == .dcmatch);
        },
        else => prepared.probes.len + 1,
    };
    if (nvars == 0) return error.DataLengthMismatch;
    if (format == .sst2 and nvars > 64) return error.FormatLimitExceeded;
    if (format == .fsdb) {
        if (nvars > std.math.maxInt(u32) or prepared.title.len > std.math.maxInt(u16)) return error.FormatLimitExceeded;
        for (prepared.probe_labels) |label| if (label.len > std.math.maxInt(u16)) return error.FormatLimitExceeded;
    }
}
