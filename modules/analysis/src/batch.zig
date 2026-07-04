//! Comptime device → batch mechanism. Analysis-owned because it defines the
//! Jacobian convention every analysis consumes:
//!
//!   pattern:  dedup (row,col) set → sorted CSC, frozen at freeze()
//!   batches:  one per device TYPE (archetype), slot tapes precomputed
//!   AD:       device physics is written once, generic over a scalar S;
//!             eval runs it on a derivative-carrying scalar, so one pass
//!             yields residual + all partials. No finite differences.
//!
//! Ground is branch-free: x[0] is a real unknown pinned to 0 by the ground
//! equation (g[0,0] = 1, rhs[0] = x[0]); device stamps touching row or
//! column 0 land in a trash slot (index nnz) / trash rhs (index n).
//!
//! Construction policy (node interning, BBD permutation) lives with the app
//! in src/builder.zig; it accumulates ProtoStore(D)s behind the Proto fn-ptr
//! table and hands them to freeze().

const std = @import("std");
const root = @import("root.zig");

const GROUND = root.GROUND;
const Batch = root.Batch;
const Circuit = root.Circuit;
const Planes = root.Planes;

/// Arena-allocated ring buffer that stores (time, values...) tuples and
/// supports linear interpolation lookup at arbitrary query times.
/// Used by history-dependent devices (transmission lines, delay elements).
const HistoryBuffer = struct {
    /// Ring buffer of time points
    times: []f64,
    /// Ring buffer of value snapshots; values[sample_idx * n_signals + signal_idx]
    values: []f64,
    n_signals: u32,
    capacity: u32,
    head: u32,
    len: u32,

    pub fn init(allocator: std.mem.Allocator, n_signals: u32, capacity: u32) !HistoryBuffer {
        const cap = @max(capacity, 4);
        return .{
            .times = try allocator.alloc(f64, cap),
            .values = try allocator.alloc(f64, @as(usize, cap) * n_signals),
            .n_signals = n_signals,
            .capacity = cap,
            .head = 0,
            .len = 0,
        };
    }

    /// Record a new sample. vals.len must equal n_signals.
    pub fn record(self: *HistoryBuffer, t: f64, vals: []const f64) void {
        std.debug.assert(vals.len == self.n_signals);
        const slot = self.head;
        self.times[slot] = t;
        const base = @as(usize, slot) * self.n_signals;
        @memcpy(self.values[base..][0..self.n_signals], vals);
        self.head = (slot + 1) % self.capacity;
        if (self.len < self.capacity) self.len += 1;
    }

    /// Look up signal `sig` at time `t_query` using linear interpolation.
    /// Clamps to oldest/newest value if t_query is out of range.
    /// Binary search — times are monotonic along the ring.
    pub fn lookup(self: *const HistoryBuffer, t_query: f64, sig: u32) f64 {
        if (self.len == 0) return 0.0;
        const oldest = if (self.len < self.capacity) 0 else self.head;

        // First k in [0, len) with times[slot(k)] >= t_query.
        var lo: u32 = 0;
        var hi: u32 = self.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.times[(oldest + mid) % self.capacity] < t_query) lo = mid + 1 else hi = mid;
        }

        if (lo == 0) return self.valueAt(oldest, sig);
        if (lo == self.len) return self.valueAt((oldest + self.len - 1) % self.capacity, sig);

        const s0 = (oldest + lo - 1) % self.capacity;
        const s1 = (oldest + lo) % self.capacity;
        const t0 = self.times[s0];
        const t1 = self.times[s1];
        const alpha = (t_query - t0) / (t1 - t0);
        const v0 = self.valueAt(s0, sig);
        const v1 = self.valueAt(s1, sig);
        return v0 + alpha * (v1 - v0);
    }

    inline fn valueAt(self: *const HistoryBuffer, slot: u32, sig: u32) f64 {
        return self.values[@as(usize, slot) * self.n_signals + sig];
    }
};

/// Handed to a history device's histInject: interpolated signal lookup.
pub const HistLookup = struct {
    buf: *const HistoryBuffer,
    pub fn at(self: HistLookup, t: f64, signal: usize) f64 {
        return self.buf.lookup(t, @intCast(signal));
    }
};

// ---------------------------------------------------------------------------
// Internal derivative-carrying scalar. Devices never name this type —
// physics is written against an opaque comptime S (con/add/sub/mul/...).
// Analyses never see it at all, only the planes it fills.
// ---------------------------------------------------------------------------
fn AdScalar(comptime N: usize) type {
    return struct {
        v: f64,
        d: V,

        const V = @Vector(N, f64);
        const Self = @This();

        inline fn splat(c: f64) V {
            return @splat(c);
        }
        pub fn con(c: f64) Self {
            return .{ .v = c, .d = splat(0) };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v, .d = a.d + b.d };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v - b.v, .d = a.d - b.d };
        }
        pub fn neg(a: Self) Self {
            return .{ .v = -a.v, .d = -a.d };
        }
        pub fn mul(a: Self, b: Self) Self {
            return .{ .v = a.v * b.v, .d = a.d * splat(b.v) + b.d * splat(a.v) };
        }
        pub fn div(a: Self, b: Self) Self {
            const inv_b = 1.0 / b.v;
            const quot = a.v * inv_b;
            return .{ .v = quot, .d = (a.d - b.d * splat(quot)) * splat(inv_b) };
        }
        pub fn scale(a: Self, c: f64) Self {
            return .{ .v = a.v * c, .d = a.d * splat(c) };
        }
        pub fn addC(a: Self, c: f64) Self {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn exp(a: Self) Self {
            const e = @exp(a.v);
            return .{ .v = e, .d = a.d * splat(e) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = @log(a.v), .d = a.d * splat(1.0 / a.v) };
        }
        pub fn sqrt(a: Self) Self {
            const s = @sqrt(a.v);
            return .{ .v = s, .d = a.d * splat(0.5 / s) };
        }
        pub fn sin(a: Self) Self {
            return .{ .v = @sin(a.v), .d = a.d * splat(@cos(a.v)) };
        }
        pub fn cos(a: Self) Self {
            return .{ .v = @cos(a.v), .d = a.d * splat(-@sin(a.v)) };
        }
        pub fn tanh(a: Self) Self {
            const th = std.math.tanh(a.v);
            return .{ .v = th, .d = a.d * splat(1.0 - th * th) };
        }
        pub fn abs(a: Self) Self {
            return if (a.v < 0) a.neg() else a;
        }
        /// Clamp-style guards: derivative flat past the bound.
        pub fn minC(a: Self, c: f64) Self {
            return if (a.v > c) con(c) else a;
        }
        pub fn maxC(a: Self, c: f64) Self {
            return if (a.v < c) con(c) else a;
        }
        /// a^c for constant exponent (a > 0).
        pub fn pow(a: Self, c: f64) Self {
            const p = std.math.pow(f64, a.v, c);
            return .{ .v = p, .d = a.d * splat(c * p / a.v) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = std.math.atan(a.v), .d = a.d * splat(1.0 / (1.0 + a.v * a.v)) };
        }
        pub fn sinh(a: Self) Self {
            return .{ .v = std.math.sinh(a.v), .d = a.d * splat(std.math.cosh(a.v)) };
        }
        pub fn cosh(a: Self) Self {
            return .{ .v = std.math.cosh(a.v), .d = a.d * splat(std.math.sinh(a.v)) };
        }
        /// Piecewise max/min of two scalars: derivative follows the winner.
        pub fn max(a: Self, b: Self) Self {
            return if (a.v >= b.v) a else b;
        }
        pub fn min(a: Self, b: Self) Self {
            return if (a.v <= b.v) a else b;
        }
        pub fn val(a: Self) f64 {
            return a.v;
        }
    };
}

fn uCount(comptime D: type) usize {
    return @typeInfo(D.U).@"enum".fields.len;
}

// ---------------------------------------------------------------------------
// Pattern builder: dedup (row,col) set -> sorted CSC. Compile-time only.
// ---------------------------------------------------------------------------
pub const PatternBuilder = struct {
    set: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn key(row: u32, col: u32) u64 {
        return (@as(u64, col) << 32) | row; // col-major sort order
    }

    pub fn add(self: *PatternBuilder, gpa: std.mem.Allocator, row: u32, col: u32) !void {
        try self.set.put(gpa, key(row, col), {});
    }

    pub fn deinit(self: *PatternBuilder, gpa: std.mem.Allocator) void {
        self.set.deinit(gpa);
    }

    pub fn toCsc(self: *PatternBuilder, gpa: std.mem.Allocator, n: u32, col_ptr_out: *[]u32, row_idx_out: *[]u32) !u32 {
        const nnz: u32 = @intCast(self.set.count());
        const keys = try gpa.alloc(u64, nnz);
        defer gpa.free(keys);
        var it = self.set.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sortUnstable(u64, keys, {}, std.sort.asc(u64));

        const col_ptr = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, nnz);
        @memset(col_ptr, 0);
        for (keys, 0..) |k, p| {
            row_idx[p] = @truncate(k);
            col_ptr[(k >> 32) + 1] += 1;
        }
        for (0..n) |j| col_ptr[j + 1] += col_ptr[j];
        col_ptr_out.* = col_ptr;
        row_idx_out.* = row_idx;
        return nnz;
    }
};

// ---------------------------------------------------------------------------
// Proto: type-erased accumulation store, one per device TYPE (archetype).
// Builder code holds []Proto; freeze() consumes them into Batches.
// ---------------------------------------------------------------------------
pub const Proto = struct {
    ctx: *anyopaque,
    type_name: []const u8,
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) anyerror!void,
    finalize: *const fn (*anyopaque, std.mem.Allocator, *const Circuit) anyerror!Batch,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

/// Freeze: build the union sparsity pattern (full diagonal + every
/// non-ground device entry), allocate planes, precompute every slot
/// tape. The protos are consumed (finalized into batches, shells freed).
/// Takes ownership of node_names and node_labels.
pub fn freeze(
    gpa: std.mem.Allocator,
    n: u32,
    node_names: std.StringHashMapUnmanaged(u32),
    node_labels: [][]const u8,
    protos: []const Proto,
    bbd: ?root.BbdInfo,
) !Circuit {
    var pb: PatternBuilder = .{};
    defer pb.deinit(gpa);
    for (0..n) |i| try pb.add(gpa, @intCast(i), @intCast(i));
    for (protos) |p| try p.pattern(p.ctx, gpa, &pb);

    var ckt: Circuit = undefined;
    ckt.gpa = gpa;
    ckt.n = n;
    ckt.node_names = node_names;
    ckt.node_labels = node_labels;
    ckt.has_charge = false;
    ckt.has_history = false;
    ckt.has_baseline = false;
    ckt.g_base = &.{};
    ckt.c_base = &.{};
    ckt.bbd = bbd;
    ckt.par_eval = null;

    ckt.nnz = try pb.toCsc(gpa, n, &ckt.col_ptr, &ckt.row_idx);
    ckt.trash_slot = ckt.nnz;
    ckt.g_vals = try gpa.alloc(f64, ckt.nnz + 1);
    ckt.c_vals = try gpa.alloc(f64, ckt.nnz + 1);
    ckt.rhs = try gpa.alloc(f64, @as(usize, n) + 1);
    ckt.q_vec = try gpa.alloc(f64, @as(usize, n) + 1);
    // eval() only re-zeroes c_vals/q_vec when has_charge; chargeless
    // circuits must still expose an exact C = 0 plane (pz/stb/ac read it).
    @memset(ckt.c_vals, 0);
    @memset(ckt.q_vec, 0);

    ckt.diag_slots = try gpa.alloc(u32, n);
    for (0..n) |i| ckt.diag_slots[i] = ckt.findSlot(@intCast(i), @intCast(i)).?;

    const batches = try gpa.alloc(Batch, protos.len);
    for (protos, 0..) |p, bi| {
        batches[bi] = try p.finalize(p.ctx, gpa, &ckt);
        if (batches[bi].has_charge) ckt.has_charge = true;
        if (batches[bi].inject_history != null) ckt.has_history = true;
    }
    ckt.batches = batches;

    // Protos consumed: instance data moved into batches, shells freed.
    for (protos) |p| p.destroy(p.ctx, gpa);
    return ckt;
}

pub fn ProtoStore(comptime D: type) type {
    const n_u = comptime uCount(D);
    return struct {
        models: std.ArrayList(D.Model) = .empty,
        instances: std.ArrayList(D.Instance) = .empty,
        nodes: std.ArrayList([n_u]u32) = .empty,

        const Self = @This();

        pub fn addPattern(ctx: *anyopaque, gpa: std.mem.Allocator, pb: *PatternBuilder) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.nodes.items) |nd| {
                for (0..n_u) |ru| for (0..n_u) |cu| {
                    if (nd[ru] != GROUND and nd[cu] != GROUND)
                        try pb.add(gpa, nd[ru], nd[cu]);
                };
            }
        }

        pub fn finalize(ctx: *anyopaque, gpa: std.mem.Allocator, ckt: *const Circuit) anyerror!Batch {
            const has_prep_cache = @hasDecl(D, "PrepCache");
            const has_q = @hasDecl(D, "q");
            const const_g = @hasDecl(D, "constant_g") and D.constant_g;
            const const_c = @hasDecl(D, "constant_c") and D.constant_c;
            const has_attempt_decl = @hasDecl(D, "attempt");
            const self: *Self = @ptrCast(@alignCast(ctx));
            const count = self.models.items.len;
            const store = try gpa.create(DeviceBatch(D));
            errdefer gpa.destroy(store);

            store.count = count;
            store.models = try self.models.toOwnedSlice(gpa);
            if (comptime has_attempt_decl) {
                store.saved_models = try gpa.alloc(D.Model, count);
            }
            store.instances = try self.instances.toOwnedSlice(gpa);

            store.gath = try gpa.alloc(u32, count * n_u);
            store.rhs_idx = try gpa.alloc(u32, count * n_u);
            store.slots = try gpa.alloc(u32, count * n_u * n_u);
            for (self.nodes.items, 0..) |nd, id| {
                for (0..n_u) |u| {
                    store.gath[id * n_u + u] = nd[u];
                    store.rhs_idx[id * n_u + u] = if (nd[u] == GROUND) ckt.n else nd[u];
                }
                for (0..n_u) |ru| for (0..n_u) |cu| {
                    store.slots[(id * n_u + ru) * n_u + cu] =
                        if (nd[ru] == GROUND or nd[cu] == GROUND)
                            ckt.trash_slot
                        else
                            ckt.findSlot(nd[ru], nd[cu]).?;
                };
            }
            self.nodes.deinit(gpa);
            self.nodes = .empty;

            if (comptime @hasDecl(D, "State")) {
                store.states = try gpa.alloc(D.State, count);
                for (0..count) |i| store.states[i] = D.initState(&store.models[i], &store.instances[i]);
            }
            if (comptime hasHistoryDecl(D)) {
                store.history_bufs = try gpa.alloc(HistoryBuffer, count);
                for (0..count) |i|
                    store.history_bufs[i] = try HistoryBuffer.init(gpa, D.n_hist_signals, 8192);
            }

            if (comptime @hasDecl(D, "precompute")) {
                for (0..count) |i| D.precompute(&store.instances[i], &store.models[i]);
            }

            if (comptime has_prep_cache) {
                // Compute all, then dedup by byte-equal PrepCache values.
                const all = try gpa.alloc(D.PrepCache, count);
                defer gpa.free(all);
                for (0..count) |i| all[i] = D.computePrep(&store.models[i], &store.instances[i]);

                store.prep_group = try gpa.alloc(u32, count);
                var n_unique: u32 = 0;
                for (0..count) |i| {
                    const bi = std.mem.asBytes(&all[i]);
                    var found: u32 = n_unique;
                    for (0..n_unique) |j| {
                        if (std.mem.eql(u8, std.mem.asBytes(&all[j]), bi)) {
                            found = @intCast(j);
                            break;
                        }
                    }
                    if (found == n_unique) {
                        all[n_unique] = all[i];
                        n_unique += 1;
                    }
                    store.prep_group[i] = found;
                }
                store.prep_cache = try gpa.alloc(D.PrepCache, n_unique);
                @memcpy(store.prep_cache, all[0..n_unique]);
            }

            if (comptime canDedup(D)) {
                const ng = store.prep_cache.len;
                store.n_lanes = 1;
                store.eval_cache_hash = try gpa.alloc(u64, ng);
                @memset(store.eval_cache_hash, 0);
                store.eval_cache_rhs = try gpa.alloc([n_u]f64, ng);
                store.eval_cache_jac = try gpa.alloc([n_u][n_u]f64, ng);
                if (comptime canDedupQ(D)) {
                    store.eval_cache_q_rhs = try gpa.alloc([n_u]f64, ng);
                    store.eval_cache_q_jac = try gpa.alloc([n_u][n_u]f64, ng);
                }
            }

            return .{
                .ctx = store,
                .type_name = @typeName(D),
                .count = @intCast(count),
                .n_u = n_u,
                .has_charge = @hasDecl(D, "q"),
                .has_const_jacobian = const_g and (!has_q or const_c),
                .thread_safe = true,
                .eval = DeviceBatch(D).eval,
                .eval_newton = DeviceBatch(D).evalNewton,
                .set_lanes = if (comptime canDedup(D)) DeviceBatch(D).setLanes else null,
                .scatter_bounds = DeviceBatch(D).scatterBounds,
                .apply_limits = if (@hasDecl(D, "limit")) DeviceBatch(D).applyLimits else null,
                .update_state = if (@hasDecl(D, "updateState")) DeviceBatch(D).updateState else null,
                .set_temp = if (@hasField(D.Instance, "temp")) DeviceBatch(D).setTemp else null,
                .record_history = if (hasHistoryDecl(D)) DeviceBatch(D).recordHistory else null,
                .inject_history = if (hasHistoryDecl(D)) DeviceBatch(D).injectHistory else null,
                .min_delay = if (hasHistoryDecl(D)) DeviceBatch(D).minDelay else null,
                .collect_params = DeviceBatch(D).collectParams,
                .collect_noise = if (@hasDecl(D, "noise_gens")) DeviceBatch(D).collectNoise else null,
                .recompute = if (@hasDecl(D, "precompute") or has_prep_cache) DeviceBatch(D).recomputePrecomputed else null,
                .apply_attempt = if (@hasDecl(D, "attempt")) DeviceBatch(D).applyAttempt else null,
                .restore_models = if (@hasDecl(D, "attempt")) DeviceBatch(D).restoreAttempt else null,
                .deinit = DeviceBatch(D).destroy,
            };
        }

        pub fn applyPerm(ctx: *anyopaque, perm: []const u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.nodes.items) |*nd| {
                inline for (0..n_u) |u| {
                    if (nd[u] < perm.len) nd[u] = perm[nd[u]];
                }
            }
        }

        pub fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.models.deinit(gpa);
            self.instances.deinit(gpa);
            self.nodes.deinit(gpa);
            gpa.destroy(self);
        }
    };
}

fn hasHistoryDecl(comptime D: type) bool {
    return @hasDecl(D, "histInject");
}

fn canDedup(comptime D: type) bool {
    return @hasDecl(D, "PrepCache") and !@hasDecl(D, "State") and !hasHistoryDecl(D);
}

fn canDedupQ(comptime D: type) bool {
    return canDedup(D) and @hasDecl(D, "q");
}

fn DeviceBatch(comptime D: type) type {
    const n_u = comptime uCount(D);
    const S = AdScalar(n_u);
    const has_q = @hasDecl(D, "q");
    const has_state = @hasDecl(D, "State");
    const has_hist = hasHistoryDecl(D);
    const has_prep_cache = @hasDecl(D, "PrepCache");
    const const_g = @hasDecl(D, "constant_g") and D.constant_g;
    const const_c = @hasDecl(D, "constant_c") and D.constant_c;
    const can_dedup = canDedup(D);
    const can_dedup_q = canDedupQ(D);

    const has_attempt = @hasDecl(D, "attempt");

    return struct {
        count: usize,
        models: []D.Model,
        saved_models: if (has_attempt) []D.Model else void,
        instances: []D.Instance,
        states: if (has_state) []D.State else void,
        history_bufs: if (has_hist) []HistoryBuffer else void,
        /// [id*n_u + u] -> x index (ground stays 0; x[0] == 0 invariant)
        gath: []u32,
        /// [id*n_u + u] -> rhs/q_vec row (ground -> n, the trash row)
        rhs_idx: []u32,
        /// [(id*n_u + ru)*n_u + cu] -> plane slot (ground -> trash slot)
        slots: []u32,
        prep_cache: if (has_prep_cache) []D.PrepCache else void,
        // ponytail: dedup index — prep_cache is compact (unique entries only),
        // prep_group maps device id → prep_cache slot. Identity map when no dups found.
        prep_group: if (has_prep_cache) []u32 else void,

        // Lane-major dedup caches, [lane*ng + group]; ng = prep_cache.len.
        // Sized for n_lanes lanes; grown by setLanes (par.zig init).
        n_lanes: if (can_dedup) u32 else void,
        eval_cache_hash: if (can_dedup) []u64 else void,
        eval_cache_rhs: if (can_dedup) [][n_u]f64 else void,
        eval_cache_jac: if (can_dedup) [][n_u][n_u]f64 else void,
        eval_cache_q_rhs: if (can_dedup_q) [][n_u]f64 else void,
        eval_cache_q_jac: if (can_dedup_q) [][n_u][n_u]f64 else void,

        const Self = @This();

        /// Full eval: stamps G, C, rhs, q_vec. Used for baseline and non-constant devices.
        fn eval(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, false);
        }

        /// Newton eval: skips G/C stamps for constant-Jacobian devices (already in baseline).
        fn evalNewton(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, true);
        }

        /// Scatter window of [first..last): min/max slot and rhs row touched,
        /// with the trash slot / trash row (ground writes) excluded.
        fn scatterBounds(ctx: *anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var slot_lo: u32 = std.math.maxInt(u32);
            var slot_hi: u32 = 0;
            var row_lo: u32 = std.math.maxInt(u32);
            var row_hi: u32 = 0;
            for (self.slots[first * n_u * n_u .. last * n_u * n_u]) |s| {
                if (s == trash_slot) continue;
                slot_lo = @min(slot_lo, s);
                slot_hi = @max(slot_hi, s + 1);
            }
            for (self.rhs_idx[first * n_u .. last * n_u]) |r| {
                if (r == trash_row) continue;
                row_lo = @min(row_lo, r);
                row_hi = @max(row_hi, r + 1);
            }
            if (slot_lo > slot_hi) slot_lo = slot_hi;
            if (row_lo > row_hi) row_lo = row_hi;
            return .{ slot_lo, slot_hi, row_lo, row_hi };
        }

        /// Grow the per-lane dedup caches (lane-major, [lane*ng + group]).
        fn setLanes(ctx: *anyopaque, gpa: std.mem.Allocator, n_lanes: u32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime !can_dedup) return;
            if (n_lanes <= self.n_lanes) return;
            const ng = self.prep_cache.len;
            self.eval_cache_hash = try gpa.realloc(self.eval_cache_hash, ng * n_lanes);
            self.eval_cache_rhs = try gpa.realloc(self.eval_cache_rhs, ng * n_lanes);
            self.eval_cache_jac = try gpa.realloc(self.eval_cache_jac, ng * n_lanes);
            if (comptime can_dedup_q) {
                self.eval_cache_q_rhs = try gpa.realloc(self.eval_cache_q_rhs, ng * n_lanes);
                self.eval_cache_q_jac = try gpa.realloc(self.eval_cache_q_jac, ng * n_lanes);
            }
            @memset(self.eval_cache_hash, 0);
            self.n_lanes = n_lanes;
        }

        fn hashVoltages(x: []const f64, gath: []const u32, id: usize) u64 {
            var h: u64 = 0x517cc1b727220a95;
            inline for (0..n_u) |u| {
                const v: f32 = @floatCast(x[gath[id * n_u + u]]);
                h ^= @as(u64, @as(u32, @bitCast(v)));
                h *%= 0x9e3779b97f4a7c15;
            }
            return h | 1; // ensure non-zero so 0 = empty
        }

        fn evalInner(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64, comptime skip_const: bool) void {
            @setFloatMode(.optimized);
            @setEvalBranchQuota(10_000);
            const self: *Self = @ptrCast(@alignCast(ctx));

            const skip_g = comptime (skip_const and const_g);
            const skip_c = comptime (skip_const and const_c);

            // Dedup engages on ranges of >= 4 instances (matches the old
            // whole-batch count >= 4 gate on the serial full-range path).
            const dedup_on = last - first >= 4;
            // Lane's cache segment: [lane*ng + group].
            const lane_off: usize = if (comptime can_dedup) @as(usize, lane) * self.prep_cache.len else 0;

            // Reset this lane's cache at start of each full-eval pass.
            if (comptime can_dedup) {
                if (dedup_on) @memset(self.eval_cache_hash[lane_off..][0..self.prep_cache.len], 0);
            }

            for (first..last) |id| {
                // Eval dedup: check if this prep group already has a cached result
                // for the same terminal voltages.
                if (comptime can_dedup and !skip_g and !skip_c) {
                    if (dedup_on) {
                        const group = lane_off + self.prep_group[id];
                        const h = hashVoltages(x, self.gath, id);
                        if (self.eval_cache_hash[group] == h) {
                            // Cache hit — scatter from cached result.
                            const cr = &self.eval_cache_rhs[group];
                            const cj = &self.eval_cache_jac[group];
                            inline for (0..n_u) |ru| {
                                pl.rhs[self.rhs_idx[id * n_u + ru]] += cr[ru];
                                inline for (0..n_u) |cu|
                                    pl.g_vals[self.slots[(id * n_u + ru) * n_u + cu]] += cj[ru][cu];
                            }
                            if (comptime can_dedup_q) {
                                const cqr = &self.eval_cache_q_rhs[group];
                                const cqj = &self.eval_cache_q_jac[group];
                                inline for (0..n_u) |ru| {
                                    pl.q_vec[self.rhs_idx[id * n_u + ru]] += cqr[ru];
                                    inline for (0..n_u) |cu|
                                        pl.c_vals[self.slots[(id * n_u + ru) * n_u + cu]] += cqj[ru][cu];
                                }
                            }
                            continue;
                        }
                    }
                }

                var xd: [n_u]S = undefined;
                inline for (0..n_u) |u| {
                    var d: @Vector(n_u, f64) = @splat(0);
                    d[u] = 1;
                    xd[u] = .{ .v = x[self.gath[id * n_u + u]], .d = d };
                }

                const pc_ptr = if (comptime has_prep_cache) &self.prep_cache[self.prep_group[id]] else undefined;

                if (comptime !skip_g) {
                    const out = if (comptime @hasDecl(D, "evalFromPrep"))
                        D.evalFromPrep(S, xd, pc_ptr, &self.models[id], &self.instances[id], t)
                    else
                        D.eval(S, xd, &self.models[id], &self.instances[id], t);
                    inline for (0..n_u) |ru| {
                        pl.rhs[self.rhs_idx[id * n_u + ru]] += out[ru].v;
                        inline for (0..n_u) |cu|
                            pl.g_vals[self.slots[(id * n_u + ru) * n_u + cu]] += out[ru].d[cu];
                    }
                    // Cache the result for this prep group.
                    if (comptime can_dedup) {
                        if (dedup_on) {
                            const group = lane_off + self.prep_group[id];
                            self.eval_cache_hash[group] = hashVoltages(x, self.gath, id);
                            inline for (0..n_u) |ru| {
                                self.eval_cache_rhs[group][ru] = out[ru].v;
                                inline for (0..n_u) |cu|
                                    self.eval_cache_jac[group][ru][cu] = out[ru].d[cu];
                            }
                        }
                    }
                } else {
                    // G Jacobian in baseline — only stamp rhs values.
                    const out = if (comptime @hasDecl(D, "evalFromPrep"))
                        D.evalFromPrep(S, xd, pc_ptr, &self.models[id], &self.instances[id], t)
                    else
                        D.eval(S, xd, &self.models[id], &self.instances[id], t);
                    inline for (0..n_u) |ru|
                        pl.rhs[self.rhs_idx[id * n_u + ru]] += out[ru].v;
                }

                if (comptime has_q) {
                    if (comptime !skip_c) {
                        const qo = if (comptime @hasDecl(D, "qFromPrep"))
                            D.qFromPrep(S, xd, pc_ptr, &self.models[id], &self.instances[id], t)
                        else
                            D.q(S, xd, &self.models[id], &self.instances[id], t);
                        inline for (0..n_u) |ru| {
                            pl.q_vec[self.rhs_idx[id * n_u + ru]] += qo[ru].v;
                            inline for (0..n_u) |cu|
                                pl.c_vals[self.slots[(id * n_u + ru) * n_u + cu]] += qo[ru].d[cu];
                        }
                        // Cache charge results.
                        if (comptime can_dedup) {
                            if (dedup_on) {
                                const group = lane_off + self.prep_group[id];
                                inline for (0..n_u) |ru| {
                                    self.eval_cache_q_rhs[group][ru] = qo[ru].v;
                                    inline for (0..n_u) |cu|
                                        self.eval_cache_q_jac[group][ru][cu] = qo[ru].d[cu];
                                }
                            }
                        }
                    } else {
                        // C Jacobian in baseline — only stamp q_vec values.
                        const qo = if (comptime @hasDecl(D, "qFromPrep"))
                            D.qFromPrep(S, xd, pc_ptr, &self.models[id], &self.instances[id], t)
                        else
                            D.q(S, xd, &self.models[id], &self.instances[id], t);
                        inline for (0..n_u) |ru|
                            pl.q_vec[self.rhs_idx[id * n_u + ru]] += qo[ru].v;
                    }
                }
            }
        }

        fn localX(self: *Self, x: []const f64, id: usize) [n_u]f64 {
            var out: [n_u]f64 = undefined;
            inline for (0..n_u) |u| out[u] = x[self.gath[id * n_u + u]];
            return out;
        }

        fn applyLimits(ctx: *anyopaque, x: []f64, x_old: []const f64) void {
            if (comptime !@hasDecl(D, "limit")) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                const cur = self.localX(x, id);
                const old = self.localX(x_old, id);
                const limited = D.limit(&self.models[id], &self.instances[id], cur, old);
                inline for (0..n_u) |u| {
                    const node = self.gath[id * n_u + u];
                    if (node != GROUND) x[node] = limited[u];
                }
            }
        }

        fn updateState(ctx: *anyopaque, x: []const f64) ?f64 {
            if (comptime !@hasDecl(D, "updateState")) return null;
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_reject: ?f64 = null;
            for (0..self.count) |id| {
                const lx = self.localX(x, id);
                switch (D.updateState(&self.models[id], &self.instances[id], lx, &self.states[id])) {
                    .ok => {},
                    .request_reject_at => |tr| {
                        min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
                    },
                }
            }
            return min_reject;
        }

        fn setTemp(ctx: *anyopaque, temp_c: f32) void {
            if (comptime !@hasField(D.Instance, "temp")) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| {
                // ponytail: infer K vs degC from default — >200 means Kelvin
                const default_temp = @field(D.Instance{}, "temp");
                inst.temp = if (default_temp > 200) temp_c + 273.15 else temp_c;
            }
            if (comptime @hasDecl(D, "precompute")) {
                for (self.instances, self.models) |*ins, *mdl| D.precompute(ins, mdl);
            }
            if (comptime has_prep_cache) {
                self.rebuildPrepCache();
            }
        }

        fn applyAttempt(ctx: *anyopaque, lambda: f64) void {
            if (comptime !has_attempt) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            @memcpy(self.saved_models, self.models);
            for (self.models) |*m| m.* = D.attempt(m.*, lambda);
            if (comptime @hasDecl(D, "precompute"))
                for (self.instances, self.models) |*inst, *mdl| D.precompute(inst, mdl);
            if (comptime has_prep_cache) self.rebuildPrepCache();
        }

        fn restoreAttempt(ctx: *anyopaque) void {
            if (comptime !has_attempt) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            @memcpy(self.models, self.saved_models);
            if (comptime @hasDecl(D, "precompute"))
                for (self.instances, self.models) |*inst, *mdl| D.precompute(inst, mdl);
            if (comptime has_prep_cache) self.rebuildPrepCache();
        }

        fn recomputePrecomputed(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(D, "precompute")) {
                for (self.instances, self.models) |*inst, *mdl| D.precompute(inst, mdl);
            }
            if (comptime has_prep_cache) {
                self.rebuildPrepCache();
            }
        }

        fn rebuildPrepCache(self: *Self) void {
            if (comptime !has_prep_cache) return;
            for (self.prep_cache, 0..) |*pc, g| {
                // Find the first device in this group and recompute from it.
                for (self.prep_group, 0..) |pg, i| {
                    if (pg == g) {
                        pc.* = D.computePrep(&self.models[i], &self.instances[i]);
                        break;
                    }
                }
            }
        }

        fn recordHistory(ctx: *anyopaque, x: []const f64, t: f64) void {
            if (comptime !has_hist) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                const signals = D.gatherHistSignals(self.localX(x, id));
                self.history_bufs[id].record(t, &signals);
            }
        }

        fn injectHistory(ctx: *anyopaque, t: f64, rhs: []f64) void {
            if (comptime !has_hist) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                // Concrete HistLookup value so devices can take `lookup: anytype`
                // (they cannot name this module's types).
                const adds = D.histInject(&self.models[id], HistLookup{ .buf = &self.history_bufs[id] }, t);
                inline for (0..n_u) |u| rhs[self.rhs_idx[id * n_u + u]] += adds[u];
            }
        }

        fn minDelay(ctx: *anyopaque) f64 {
            if (comptime !has_hist) return std.math.inf(f64);
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_td = std.math.inf(f64);
            for (self.models) |*m| {
                for (D.delays(m)) |d| min_td = @min(min_td, d);
            }
            return min_td;
        }

        fn collectParams(ctx: *anyopaque, gpa: std.mem.Allocator, list: *std.ArrayList(root.ParamRef)) anyerror!void {
            @setEvalBranchQuota(100_000);
            const self: *Self = @ptrCast(@alignCast(ctx));
            const type_name = comptime blk: {
                const full = @typeName(D);
                const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse break :blk full;
                break :blk full[dot + 1 ..];
            };
            comptime var inst_field_idx: usize = 0;
            inline for (@typeInfo(D.Instance).@"struct".fields) |field| {
                if (comptime paramField(D.Instance, field)) {
                    const primary = comptime if (@hasDecl(D, "mc_param"))
                        std.mem.eql(u8, field.name, D.mc_param)
                    else
                        inst_field_idx == 0;
                    for (self.instances, 0..) |*inst, idx| {
                        try list.append(gpa, .{
                            .ptr = &@field(inst, field.name),
                            .device_type = type_name,
                            .param_name = field.name,
                            .index = @intCast(idx),
                            .is_instance = true,
                            .primary = primary,
                        });
                    }
                    inst_field_idx += 1;
                }
            }
            inline for (@typeInfo(D.Model).@"struct".fields) |field| {
                if (comptime paramField(D.Model, field)) {
                    const primary = comptime @hasDecl(D, "mc_param") and std.mem.eql(u8, field.name, D.mc_param);
                    for (self.models, 0..) |*mdl, idx| {
                        try list.append(gpa, .{
                            .ptr = &@field(mdl, field.name),
                            .device_type = type_name,
                            .param_name = field.name,
                            .index = @intCast(idx),
                            .is_instance = false,
                            .primary = primary,
                        });
                    }
                }
            }
        }

        /// f32 scalar with a non-sentinel default = a real, perturbable parameter.
        fn paramField(comptime T: type, comptime field: std.builtin.Type.StructField) bool {
            if (field.type != f32) return false;
            const dflt = @field(T{}, field.name);
            return dflt > -1e30 and dflt < 1e30;
        }

        /// Noise conductance straight off the analytic Jacobian at x_op.
        /// Devices declare their generators as comptime `noise_gens` metadata
        /// (builtin noise) — this reads the conductance for each generator
        /// from the AD pass, so noise analyses never re-derive it.
        fn collectNoise(ctx: *anyopaque, x: []const f64, gpa: std.mem.Allocator, list: *std.ArrayList(root.NoiseSource)) anyerror!void {
            if (comptime !@hasDecl(D, "noise_gens")) return;
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                var xd: [n_u]S = undefined;
                inline for (0..n_u) |u| {
                    var d: @Vector(n_u, f64) = @splat(0);
                    d[u] = 1;
                    xd[u] = .{ .v = x[self.gath[id * n_u + u]], .d = d };
                }
                const out = D.eval(S, xd, &self.models[id], &self.instances[id], 0);
                inline for (D.noise_gens) |gen| {
                    switch (gen.kind) {
                        .thermal => {
                            const g = @abs(out[gen.row].d[gen.col]);
                            if (g > 0) try list.append(gpa, .{
                                .node_p = self.gath[id * n_u + gen.row],
                                .node_n = self.gath[id * n_u + gen.col],
                                .conductance = g,
                            });
                        },
                        // ponytail: shot/flicker need branch current + KF/AF;
                        // add a device noisePsd hook when greenlit.
                        .shot, .flicker => {},
                    }
                }
            }
        }

        fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            gpa.free(self.models);
            if (comptime has_attempt) gpa.free(self.saved_models);
            gpa.free(self.instances);
            if (comptime has_prep_cache) {
                gpa.free(self.prep_cache);
                gpa.free(self.prep_group);
            }
            if (comptime has_state) gpa.free(self.states);
            if (comptime has_hist) {
                for (self.history_bufs) |buf| {
                    gpa.free(buf.times);
                    gpa.free(buf.values);
                }
                gpa.free(self.history_bufs);
            }
            if (comptime can_dedup) {
                gpa.free(self.eval_cache_hash);
                gpa.free(self.eval_cache_rhs);
                gpa.free(self.eval_cache_jac);
                if (comptime can_dedup_q) {
                    gpa.free(self.eval_cache_q_rhs);
                    gpa.free(self.eval_cache_q_jac);
                }
            }
            gpa.free(self.gath);
            gpa.free(self.rhs_idx);
            gpa.free(self.slots);
            gpa.destroy(self);
        }
    };
}
