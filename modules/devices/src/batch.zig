//! Device batching: type definitions, sparsity pattern builder, history ring
//! buffer, and the comptime ProtoStore/DeviceBatch machinery.  Consolidates
//! what was previously split across analysis/root.zig, problem/pattern.zig,
//! problem/history.zig, and problem/batch.zig.

const std = @import("std");
const contract = @import("contract");
const gpu_abi = @import("gpu_abi");
/// pub: the GPU TUs (kernel_common.zig) reach the shared eval body through
/// dev_models.batch.eval_core — a direct file import there would put
/// eval_core.zig in two modules of one compilation (a compile error).
pub const eval_core = @import("eval_core.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const GROUND: u32 = 0;

// ---------------------------------------------------------------------------
// Re-exports from contract (single source of truth)
// ---------------------------------------------------------------------------

pub const StateCtlOp = contract.StateCtlOp;
pub const UpdateResult = contract.UpdateResult;

// ---------------------------------------------------------------------------
// Circuit-facing types
// ---------------------------------------------------------------------------

pub const ParamRef = struct {
    ptr: *f32,
    device_type: []const u8,
    param_name: []const u8,
    index: u32,
    is_instance: bool,
    primary: bool,
    pelgrom_ap: f64 = 0,
    area_wl: f64 = 0,
};

pub const NoiseSource = struct {
    node_p: u32,
    node_n: u32,
    kind: NoiseGenKind = .thermal,
    conductance: f64,
    current: f64 = 0,
    kf: f64 = 0,
    af: f64 = 1,
};

pub const NoiseGenKind = enum { thermal, shot, flicker };
pub const NoiseGen = struct { row: usize, col: usize, kind: NoiseGenKind };

/// Target value planes for one eval pass. Circuit.eval points this at its own
/// slices; parallel eval (par.zig) points lanes 1.. at private slabs and
/// reduces afterwards. computeBaseline points it at g_base/c_base directly.
pub const Planes = struct {
    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,
};

/// Per-type device batch vtable. One entry per device TYPE, dispatched once
/// per eval. Created by ProtoStore(D).finalize().
///
/// eval/eval_newton stamp instances [first..last) into `pl`; `lane` selects
/// the per-lane dedup cache (0 on the serial path).
pub const Batch = struct {
    // -- hot: the only fields the eval dispatch loop reads --
    ctx: *anyopaque,
    eval: *const fn (*anyopaque, *const Planes, lane: u32, first: u32, last: u32, []const f64, f64) void,
    eval_newton: *const fn (*anyopaque, *const Planes, lane: u32, first: u32, last: u32, []const f64, f64) void,
    count: u32,
    /// Terminals per instance; per-instance eval cost scales ~n_u².
    n_u: u32,
    has_charge: bool,
    has_const_jacobian: bool,
    /// False when eval uses shared per-batch scratch — such a batch must run
    /// whole on one lane.
    thread_safe: bool,

    // -- cold --
    type_name: []const u8,
    /// GPU kind (0 ⇒ not GPU-eligible); must match the megakernel's
    /// comptime dispatch.
    gpu_kind_id: u32 = 0,
    /// Everything dispatched outside the eval loop: one static table per
    /// device TYPE (comptime const in DeviceBatch(D)), zero per-batch bytes.
    hooks: *const Hooks,
};

/// Cold per-device-type vtable. Null entry ⇒ device type lacks the hook.
pub const Hooks = struct {
    /// Grow per-lane dedup caches to n_lanes. Null when the batch has none.
    set_lanes: ?*const fn (*anyopaque, std.mem.Allocator, u32) anyerror!void = null,
    /// Scatter footprint of instances [first..last): {slot_lo, slot_hi_excl,
    /// row_lo, row_hi_excl}, entries equal to the passed trash slot/row
    /// (ground writes) excluded. Lets parallel eval zero and reduce only the
    /// touched window of a lane's private planes.
    scatter_bounds: *const fn (*anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32,
    apply_limits: ?*const fn (*anyopaque, []f64, []const f64) bool = null,
    /// Reset private limiting state after a Newton solve finishes.
    clear_limits: ?*const fn (*anyopaque) void = null,
    /// SPICE MODEINITJCT: write junction seed voltages into a cold-started x.
    seed: ?*const fn (*anyopaque, []f64) void = null,
    /// Mark unknowns that are MNA branch currents (not node voltages) so the
    /// converger can apply abstol vs vntol per row (ngspice NIconvTest).
    mark_current_rows: ?*const fn (*anyopaque, []bool) void = null,
    update_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    /// FSM accepted-state bookkeeping (switch devices): query returns true if
    /// any working state differs from the last accepted one; commit/revert
    /// sync the two on step accept/reject. See devices contract.StateCtlOp.
    state_ctl: ?*const fn (*anyopaque, StateCtlOp) bool = null,
    set_temp: ?*const fn (*anyopaque, f32) void = null,
    record_history: ?*const fn (*anyopaque, []const f64, f64) void = null,
    inject_history: ?*const fn (*anyopaque, f64, []f64) void = null,
    min_delay: ?*const fn (*anyopaque) f64 = null,
    next_breakpoint: ?*const fn (*anyopaque, f64) ?f64 = null,
    collect_params: *const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(ParamRef)) anyerror!void,
    collect_noise: ?*const fn (*anyopaque, []const f64, std.mem.Allocator, *std.ArrayList(NoiseSource)) anyerror!void = null,
    recompute: ?*const fn (*anyopaque) void = null,
    apply_attempt: ?*const fn (*anyopaque, f64) void = null,
    restore_models: ?*const fn (*anyopaque) void = null,
    gpu_pack_size: ?*const fn (*anyopaque) usize = null,
    /// Serialize tapes+params into `dest` (blob-relative base at `base_off`),
    /// returning the filled BatchDesc.
    gpu_pack: ?*const fn (*anyopaque, dest: []u8, base_off: u32, n: u32) gpu_abi.BatchDesc = null,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

// ---------------------------------------------------------------------------
// Proto: type-erased accumulation store, one per device TYPE (archetype).
// Builder code holds []Proto; freeze() consumes them into Batches.
// ---------------------------------------------------------------------------

pub const Proto = struct {
    ctx: *anyopaque,
    type_name: []const u8,
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) anyerror!void,
    finalize: *const fn (*anyopaque, std.mem.Allocator, PatternView) anyerror!Batch,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

// ---------------------------------------------------------------------------
// PatternView: read-only CSC sparsity view (replaces *const Circuit in tapes)
// ---------------------------------------------------------------------------

pub const PatternView = struct {
    col_ptr: []const u32,
    row_idx: []const u32,
    n: u32,
    trash_slot: u32,

    pub fn findSlot(self: PatternView, row: u32, col: u32) ?u32 {
        var lo = self.col_ptr[col];
        var hi = self.col_ptr[col + 1];
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.row_idx[mid] < row) lo = mid + 1 else hi = mid;
        }
        if (lo < self.col_ptr[col + 1] and self.row_idx[lo] == row) return lo;
        return null;
    }
};

// ---------------------------------------------------------------------------
// PatternBuilder: dedup (row,col) set -> sorted CSC. Compile-time only.
// ---------------------------------------------------------------------------

pub const PatternBuilder = struct {
    // Duplicates allowed during accumulation; toCsc() sorts and dedups once.
    // Appending to a flat list is far cheaper than per-entry hash-set puts.
    keys: std.ArrayList(u64) = .empty,

    fn key(row: u32, col: u32) u64 {
        return (@as(u64, col) << 32) | row; // col-major sort order
    }

    pub fn add(self: *PatternBuilder, gpa: std.mem.Allocator, row: u32, col: u32) !void {
        try self.keys.append(gpa, key(row, col));
    }

    /// Reserve for a known number of upcoming add() calls.
    pub fn reserve(self: *PatternBuilder, gpa: std.mem.Allocator, extra: usize) !void {
        try self.keys.ensureUnusedCapacity(gpa, extra);
    }

    pub fn deinit(self: *PatternBuilder, gpa: std.mem.Allocator) void {
        self.keys.deinit(gpa);
    }

    /// LSD radix sort (16-bit digits): O(n) on the bounded (col,row) keys,
    /// several times faster than comparison sort at netlist scale.
    fn radixSort(gpa: std.mem.Allocator, sort_keys: []u64) !void {
        if (sort_keys.len < 64) {
            std.mem.sortUnstable(u64, sort_keys, {}, std.sort.asc(u64));
            return;
        }
        var max_key: u64 = 0;
        for (sort_keys) |k| max_key = @max(max_key, k);

        const tmp = try gpa.alloc(u64, sort_keys.len);
        defer gpa.free(tmp);
        const counts = try gpa.alloc(u32, 1 << 16);
        defer gpa.free(counts);

        var src: []u64 = sort_keys;
        var dst: []u64 = tmp;
        var shift: u6 = 0;
        while (true) {
            @memset(counts, 0);
            for (src) |k| counts[@as(u16, @truncate(k >> shift))] += 1;
            var sum: u32 = 0;
            for (counts) |*c| {
                const c0 = c.*;
                c.* = sum;
                sum += c0;
            }
            for (src) |k| {
                const d: u16 = @truncate(k >> shift);
                dst[counts[d]] = k;
                counts[d] += 1;
            }
            const t = src;
            src = dst;
            dst = t;
            if (shift >= 48 or (max_key >> shift) >> 16 == 0) break;
            shift += 16;
        }
        if (src.ptr != sort_keys.ptr) @memcpy(sort_keys, src);
    }

    pub fn toCsc(self: *PatternBuilder, gpa: std.mem.Allocator, n: u32, col_ptr_out: *[]u32, row_idx_out: *[]u32) !u32 {
        const all = self.keys.items;
        try radixSort(gpa, all);
        // In-place dedup of the sorted keys.
        var m: usize = 0;
        for (all) |k| {
            if (m == 0 or all[m - 1] != k) {
                all[m] = k;
                m += 1;
            }
        }
        const nnz: u32 = @intCast(m);

        const col_ptr = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, nnz);
        @memset(col_ptr, 0);
        for (all[0..m], 0..) |k, p| {
            row_idx[p] = @truncate(k);
            col_ptr[(k >> 32) + 1] += 1;
        }
        for (0..n) |j| col_ptr[j + 1] += col_ptr[j];
        col_ptr_out.* = col_ptr;
        row_idx_out.* = row_idx;
        return nnz;
    }
};

/// Scatter window over precomputed tapes: min/max slot and rhs row touched,
/// trash slot / trash row (ground writes) excluded. Shared by the comptime
/// and dyn batches — pure index math on the same tape layout.
pub fn tapeBounds(slots: []const u32, rhs_idx: []const u32, trash_slot: u32, trash_row: u32) [4]u32 {
    var slot_lo: u32 = std.math.maxInt(u32);
    var slot_hi: u32 = 0;
    var row_lo: u32 = std.math.maxInt(u32);
    var row_hi: u32 = 0;
    for (slots) |s| {
        if (s == trash_slot) continue;
        slot_lo = @min(slot_lo, s);
        slot_hi = @max(slot_hi, s + 1);
    }
    for (rhs_idx) |r| {
        if (r == trash_row) continue;
        row_lo = @min(row_lo, r);
        row_hi = @max(row_hi, r + 1);
    }
    if (slot_lo > slot_hi) slot_lo = slot_hi;
    if (row_lo > row_hi) row_lo = row_hi;
    return .{ slot_lo, slot_hi, row_lo, row_hi };
}

/// Precompute the gather/scatter tapes for one batch from its flat node
/// list ([id * n_u + u] layout). Ground rows/cols land in the trash slot.
pub fn buildTapes(nodes: []const u32, n_u: usize, pv: PatternView, gath: []u32, rhs_idx: []u32, slots: []u32) void {
    const count = nodes.len / n_u;
    for (0..count) |id| {
        const nd = nodes[id * n_u ..][0..n_u];
        for (nd, 0..) |node, u| {
            gath[id * n_u + u] = node;
            rhs_idx[id * n_u + u] = if (node == GROUND) pv.n else node;
        }
        for (nd, 0..) |r, ru| for (nd, 0..) |c, cu| {
            slots[(id * n_u + ru) * n_u + cu] =
                if (r == GROUND or c == GROUND) pv.trash_slot else pv.findSlot(r, c).?;
        };
    }
}

// ---------------------------------------------------------------------------
// HistoryBuffer: ring buffer for delay/transmission-line devices
// ---------------------------------------------------------------------------

/// Arena-allocated ring buffer that stores (time, values...) tuples and
/// supports linear interpolation lookup at arbitrary query times.
/// Used by history-dependent devices (transmission lines, delay elements).
pub const HistoryBuffer = struct {
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
        const times = try allocator.alloc(f64, cap);
        errdefer allocator.free(times);
        return .{
            .times = times,
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

    /// Look up signal `sig` at time `t_query`. Quadratic (3-point Lagrange)
    /// interpolation through the two samples at/before the query and the one
    /// after — same scheme as ngspice traload.c's default (f1/f2/f3 through
    /// t(i-2), t(i-1), t(i)); falls back to linear when only two points
    /// bracket the query. Clamps to oldest/newest value out of range.
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

        const s1 = (oldest + lo - 1) % self.capacity;
        const s2 = (oldest + lo) % self.capacity;
        const t1 = self.times[s1];
        const t2 = self.times[s2];
        const v1 = self.valueAt(s1, sig);
        const v2 = self.valueAt(s2, sig);

        if (lo >= 2) {
            const s0 = (oldest + lo - 2) % self.capacity;
            const t0 = self.times[s0];
            const d01 = t0 - t1;
            const d02 = t0 - t2;
            const d12 = t1 - t2;
            // Degenerate spacing → linear.
            if (d01 != 0.0 and d02 != 0.0 and d12 != 0.0) {
                const f0 = (t_query - t1) * (t_query - t2) / (d01 * d02);
                const f1 = (t_query - t0) * (t_query - t2) / (-d01 * d12);
                const f2 = (t_query - t0) * (t_query - t1) / (d02 * d12);
                return f0 * self.valueAt(s0, sig) + f1 * v1 + f2 * v2;
            }
        }

        const alpha = (t_query - t1) / (t2 - t1);
        return v1 + alpha * (v2 - v1);
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
// ProtoStore(D) and DeviceBatch(D): comptime device accumulation + frozen
// SoA batch with AD eval hot loop and cold Hooks vtable.
// ---------------------------------------------------------------------------

fn uCount(comptime D: type) usize {
    return @typeInfo(D.U).@"enum".fields.len;
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
            try pb.reserve(gpa, self.nodes.items.len * n_u * n_u);
            for (self.nodes.items) |nd| {
                for (0..n_u) |ru| for (0..n_u) |cu| {
                    if (nd[ru] != GROUND and nd[cu] != GROUND)
                        try pb.add(gpa, nd[ru], nd[cu]);
                };
            }
        }

        pub fn finalize(ctx: *anyopaque, gpa: std.mem.Allocator, pv: PatternView) anyerror!Batch {
            const has_prep_cache = @hasDecl(D, "PrepCache");
            const has_q = @hasDecl(D, "q");
            const const_g = @hasDecl(D, "constant_g") and D.constant_g;
            const const_c = @hasDecl(D, "constant_c") and D.constant_c;
            const has_attempt_decl = @hasDecl(D, "attempt");
            const self: *Self = @ptrCast(@alignCast(ctx));
            const count = self.models.items.len;
            const store = try gpa.create(DeviceBatch(D));

            // Empty-init every field destroy() frees, then let destroy() be
            // the single error cleanup: free(&.{}) is a no-op, so a failure
            // anywhere below releases exactly what was allocated so far.
            store.count = count;
            store.models = &.{};
            store.instances = &.{};
            store.gath = &.{};
            store.rhs_idx = &.{};
            store.slots = &.{};
            if (comptime has_attempt_decl) store.saved_models = &.{};
            if (comptime @hasDecl(D, "limit")) store.lim_x = &.{};
            if (comptime @hasDecl(D, "State")) store.states = &.{};
            if (comptime hasHistoryDecl(D)) store.history_bufs = &.{};
            if (comptime has_prep_cache) {
                store.prep_cache = &.{};
                store.prep_group = &.{};
            }
            if (comptime canDedup(D)) {
                store.eval_cache_hash = &.{};
                store.eval_cache_rhs = &.{};
                store.eval_cache_jac = &.{};
                if (comptime canDedupQ(D)) {
                    store.eval_cache_q_rhs = &.{};
                    store.eval_cache_q_jac = &.{};
                }
            }
            errdefer DeviceBatch(D).hooks.deinit(store, gpa);

            store.models = try self.models.toOwnedSlice(gpa);
            if (comptime has_attempt_decl) {
                store.saved_models = try gpa.alloc(D.Model, count);
                store.attempt_saved = false;
            }
            if (comptime @hasDecl(D, "limit")) {
                store.lim_x = try gpa.alloc(f64, count * n_u);
                store.lim_active = false;
            }
            store.instances = try self.instances.toOwnedSlice(gpa);

            store.gath = try gpa.alloc(u32, count * n_u);
            store.rhs_idx = try gpa.alloc(u32, count * n_u);
            store.slots = try gpa.alloc(u32, count * n_u * n_u);
            // [n_u]u32 arrays are contiguous — view them flat for the shared tape builder.
            const flat_nodes = @as([*]const u32, @ptrCast(self.nodes.items.ptr))[0 .. count * n_u];
            buildTapes(flat_nodes, n_u, pv, store.gath, store.rhs_idx, store.slots);
            self.nodes.deinit(gpa);
            self.nodes = .empty;

            if (comptime @hasDecl(D, "State")) {
                store.states = try gpa.alloc(D.State, count);
                for (0..count) |i| store.states[i] = D.initState(&store.models[i], &store.instances[i]);
            }
            if (comptime hasHistoryDecl(D)) {
                store.history_bufs = try gpa.alloc(HistoryBuffer, count);
                // Empty-init so a mid-loop init failure leaves destroy() a
                // fully defined (freeable) array, not undefined tails.
                for (store.history_bufs) |*b|
                    b.* = .{ .times = &.{}, .values = &.{}, .n_signals = 0, .capacity = 0, .head = 0, .len = 0 };
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
                // Byte-keyed hash dedup: O(count), keys point into the
                // compacted prefix of `all` (slots never overwritten once
                // inserted, n_unique only grows).
                var seen: std.StringHashMapUnmanaged(u32) = .empty;
                defer seen.deinit(gpa);
                try seen.ensureTotalCapacity(gpa, @intCast(count));
                var n_unique: u32 = 0;
                for (0..count) |i| {
                    all[n_unique] = all[i];
                    const gop = seen.getOrPutAssumeCapacity(std.mem.asBytes(&all[n_unique]));
                    if (!gop.found_existing) {
                        gop.value_ptr.* = n_unique;
                        n_unique += 1;
                    }
                    store.prep_group[i] = gop.value_ptr.*;
                }
                store.prep_cache = try gpa.alloc(D.PrepCache, n_unique);
                @memcpy(store.prep_cache, all[0..n_unique]);
            }

            if (comptime canDedup(D)) {
                const ng = store.prep_cache.len;
                // No sharing found ⇒ cache can never hit; don't pay
                // per-eval memset + per-instance hash for nothing.
                store.dedup_worth = ng * 2 <= count;
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
                .eval = DeviceBatch(D).eval,
                .eval_newton = DeviceBatch(D).evalNewton,
                .count = @intCast(count),
                .n_u = n_u,
                .has_charge = @hasDecl(D, "q"),
                .has_const_jacobian = const_g and (!has_q or const_c),
                .thread_safe = true,
                .type_name = @typeName(D),
                .gpu_kind_id = gpu_abi.kindId(D),
                .hooks = &DeviceBatch(D).hooks,
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

pub fn DeviceBatch(comptime D: type) type {
    const n_u = comptime uCount(D);
    const S = contract.Dual(n_u);
    const has_q = @hasDecl(D, "q");
    const has_state = @hasDecl(D, "State");
    const has_hist = hasHistoryDecl(D);
    const has_prep_cache = @hasDecl(D, "PrepCache");
    const const_g = @hasDecl(D, "constant_g") and D.constant_g;
    const const_c = @hasDecl(D, "constant_c") and D.constant_c;
    const can_dedup = canDedup(D);
    const can_dedup_q = canDedupQ(D);

    const has_attempt = @hasDecl(D, "attempt");
    const has_limit = @hasDecl(D, "limit");

    return struct {
        count: usize,
        models: []D.Model,
        saved_models: if (has_attempt) []D.Model else void,
        /// True while saved_models holds the pre-continuation models.
        attempt_saved: if (has_attempt) bool else void,
        /// SPICE-style private limiting state: the per-instance local x the
        /// device EVALUATES at (pnjlim/fetlim/limvds applied), decoupled
        /// from the solver's node vector. ngspice keeps vd/vgs/... in
        /// CKTstate0 for exactly this; node-writeback limiting cannot work
        /// once zero-R primes are collapsed onto shared/driven nodes.
        lim_x: if (has_limit) []f64 else void,
        lim_active: if (has_limit) bool else void,
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
        /// finalize found real prep sharing (ng*2 <= count); false ⇒ cache
        /// can't hit, dedup machinery skipped entirely at eval time.
        dedup_worth: if (can_dedup) bool else void,
        n_lanes: if (can_dedup) u32 else void,
        eval_cache_hash: if (can_dedup) []u64 else void,
        eval_cache_rhs: if (can_dedup) [][n_u]f64 else void,
        eval_cache_jac: if (can_dedup) [][n_u][n_u]f64 else void,
        eval_cache_q_rhs: if (can_dedup_q) [][n_u]f64 else void,
        eval_cache_q_jac: if (can_dedup_q) [][n_u][n_u]f64 else void,

        const Self = @This();

        /// Cold vtable — one static instance per device type, shared by every
        /// batch of that type. finalize() hands out &hooks.
        pub const hooks: Hooks = .{
            .set_lanes = if (can_dedup) setLanes else null,
            .scatter_bounds = scatterBounds,
            .apply_limits = if (has_limit) applyLimits else null,
            .clear_limits = if (has_limit) clearLimits else null,
            .seed = if (@hasDecl(D, "seed")) seedFn else null,
            .mark_current_rows = if (@hasDecl(D, "u_kinds")) markCurrentRows else null,
            .update_state = if (@hasDecl(D, "updateState")) updateState else null,
            .state_ctl = if (@hasDecl(D, "stateCtl")) stateCtl else null,
            .set_temp = if (@hasField(D.Instance, "temp")) setTemp else null,
            .record_history = if (has_hist) recordHistory else null,
            .inject_history = if (has_hist) injectHistory else null,
            .min_delay = if (has_hist) minDelay else null,
            .next_breakpoint = if (@hasDecl(D, "nextBreakpoint")) nextBreakpointFn else null,
            .collect_params = collectParams,
            .collect_noise = if (@hasDecl(D, "noise_gens")) collectNoise else null,
            .recompute = if (@hasDecl(D, "precompute") or has_prep_cache) recomputePrecomputed else null,
            .apply_attempt = if (has_attempt) applyAttempt else null,
            .restore_models = if (has_attempt) restoreAttempt else null,
            .gpu_pack_size = if (gpu_ok) gpuPackSize else null,
            .gpu_pack = if (gpu_ok) gpuPack else null,
            .deinit = destroy,
        };

        /// Full eval: stamps G, C, rhs, q_vec. Used for baseline and non-constant devices.
        fn eval(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, false);
        }

        /// Newton eval: skips G/C stamps for constant-Jacobian devices (already in baseline).
        fn evalNewton(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, true);
        }

        fn scatterBounds(ctx: *anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return tapeBounds(self.slots[first * n_u * n_u .. last * n_u * n_u], self.rhs_idx[first * n_u .. last * n_u], trash_slot, trash_row);
        }

        /// Grow the per-lane dedup caches (lane-major, [lane*ng + group]).
        fn setLanes(ctx: *anyopaque, gpa: std.mem.Allocator, n_lanes: u32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
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

        fn hashVoltages(lx: *const [n_u]f64) u64 {
            // Full f64 bits: JFNK's ε-perturbed voltages (~1e-8 apart) alias
            // under an f32 hash, turning distinct evals into stale cache hits
            // and poisoning the finite-difference J·v.
            var h: u64 = 0x517cc1b727220a95;
            inline for (0..n_u) |u| {
                h ^= @as(u64, @bitCast(lx[u]));
                h *%= 0x9e3779b97f4a7c15;
            }
            return h | 1; // ensure non-zero so 0 = empty
        }

        /// Companion-correction term J·(x_node − lx) for one residual row.
        /// Comptime-zero for devices without limiting — their scatter is a
        /// plain add, no vector multiply.
        inline fn corrDot(jrow: @Vector(n_u, f64), corr: @Vector(n_u, f64)) f64 {
            return if (comptime has_limit) @reduce(.Add, jrow * corr) else 0.0;
        }

        /// Host sink for eval_core: slot-tape scatter into the full G/C
        /// planes (plain +=) and the per-lane prep-cache dedup. skip_const
        /// freezes constant-Jacobian stamps out of Newton re-evals.
        fn HostSink(comptime skip_const: bool) type {
            return struct {
                b: *Self,
                pl: *const Planes,
                xs: []const f64,
                xo: []const f64, // x_old (limit pass only)
                /// Dedup engaged for this pass (dedup_worth && range >= 4).
                dedup_on: bool,
                /// Lane's cache segment base: [lane*ng + group].
                lane_off: usize,
                // group/hash of the current instance — computed by tryCached,
                // reused by the miss-path store/storeQ.
                cur_group: usize = 0,
                cur_hash: u64 = 0,

                pub const dedup = can_dedup;
                pub const skip_g = skip_const and const_g;
                pub const skip_c = skip_const and const_c;
                pub const optimized_float = true;

                const Sk = @This();

                pub inline fn x(s: *const Sk, gi: u32) f64 {
                    return s.xs[gi];
                }
                pub inline fn xOld(s: *const Sk, gi: u32) f64 {
                    return s.xo[gi];
                }
                pub inline fn gath(s: *const Sk, id: u32, u: usize) u32 {
                    return s.b.gath[@as(usize, id) * n_u + u];
                }
                pub inline fn rhsRow(s: *const Sk, id: u32, ru: usize) u32 {
                    return s.b.rhs_idx[@as(usize, id) * n_u + ru];
                }
                pub inline fn lim(s: *const Sk, id: u32, u: usize) f64 {
                    return s.b.lim_x[@as(usize, id) * n_u + u];
                }
                pub inline fn setLim(s: *const Sk, id: u32, u: usize, v: f64) void {
                    s.b.lim_x[@as(usize, id) * n_u + u] = v;
                }
                pub inline fn model(s: *const Sk, id: u32) *const D.Model {
                    return &s.b.models[id];
                }
                pub inline fn inst(s: *const Sk, id: u32) *const D.Instance {
                    return &s.b.instances[id];
                }
                pub inline fn prep(s: *const Sk, id: u32) *const D.PrepCache {
                    return &s.b.prep_cache[s.b.prep_group[id]];
                }
                inline fn slot(s: *const Sk, id: u32, ru: usize, cu: usize) u32 {
                    return s.b.slots[(@as(usize, id) * n_u + ru) * n_u + cu];
                }
                pub inline fn scatterRes(s: *const Sk, row: u32, val: f64) void {
                    s.pl.rhs[row] += val;
                }
                pub inline fn scatterJac(s: *const Sk, id: u32, ru: usize, cu: usize, row: u32, val: f64) void {
                    _ = row;
                    s.pl.g_vals[s.slot(id, ru, cu)] += val;
                }
                pub inline fn qActive(s: *const Sk) bool {
                    _ = s;
                    return true;
                }
                pub inline fn scatterQ(s: *const Sk, row: u32, qv: f64) void {
                    s.pl.q_vec[row] += qv;
                }
                pub inline fn scatterQJac(s: *const Sk, id: u32, ru: usize, cu: usize, row: u32, val: f64) void {
                    _ = row;
                    s.pl.c_vals[s.slot(id, ru, cu)] += val;
                }

                /// Eval dedup: check if this prep group already has a cached
                /// result for the same terminal voltages (the ACTUAL eval
                /// input — limited state included, so instances with equal
                /// node voltages but different limiting histories never
                /// alias). group/h computed once, reused by store/storeQ.
                /// Hit ⇒ scatter cached result (+ per-instance companion
                /// correction) and return true.
                pub inline fn tryCached(s: *Sk, id: u32, lx: *const [n_u]f64, corr: @Vector(n_u, f64)) bool {
                    s.cur_group = s.lane_off + s.b.prep_group[id];
                    s.cur_hash = if (s.dedup_on) hashVoltages(lx) else 0;
                    if (comptime skip_g or skip_c) return false;
                    if (!s.dedup_on) return false;
                    if (s.b.eval_cache_hash[s.cur_group] != s.cur_hash) return false;
                    const cr = &s.b.eval_cache_rhs[s.cur_group];
                    const cj = &s.b.eval_cache_jac[s.cur_group];
                    inline for (0..n_u) |ru| {
                        const cjv: @Vector(n_u, f64) = cj[ru];
                        s.pl.rhs[s.rhsRow(id, ru)] += cr[ru] + corrDot(cjv, corr);
                        inline for (0..n_u) |cu|
                            s.pl.g_vals[s.slot(id, ru, cu)] += cj[ru][cu];
                    }
                    if (comptime can_dedup_q) {
                        const cqr = &s.b.eval_cache_q_rhs[s.cur_group];
                        const cqj = &s.b.eval_cache_q_jac[s.cur_group];
                        inline for (0..n_u) |ru| {
                            const cqjv: @Vector(n_u, f64) = cqj[ru];
                            s.pl.q_vec[s.rhsRow(id, ru)] += cqr[ru] + corrDot(cqjv, corr);
                            inline for (0..n_u) |cu|
                                s.pl.c_vals[s.slot(id, ru, cu)] += cqj[ru][cu];
                        }
                    }
                    return true;
                }

                /// Cache the miss-path result (raw, at lx — the companion
                /// correction is per-instance, applied at scatter time).
                pub inline fn store(s: *Sk, id: u32, out: anytype) void {
                    _ = id;
                    if (comptime skip_g) return;
                    if (!s.dedup_on) return;
                    s.b.eval_cache_hash[s.cur_group] = s.cur_hash;
                    inline for (0..n_u) |ru| {
                        s.b.eval_cache_rhs[s.cur_group][ru] = out[ru].v;
                        inline for (0..n_u) |cu|
                            s.b.eval_cache_jac[s.cur_group][ru][cu] = out[ru].d[cu];
                    }
                }
                pub inline fn storeQ(s: *Sk, id: u32, qo: anytype) void {
                    _ = id;
                    if (comptime !(can_dedup_q and !skip_c)) return;
                    if (!s.dedup_on) return;
                    inline for (0..n_u) |ru| {
                        s.b.eval_cache_q_rhs[s.cur_group][ru] = qo[ru].v;
                        inline for (0..n_u) |cu|
                            s.b.eval_cache_q_jac[s.cur_group][ru][cu] = qo[ru].d[cu];
                    }
                }
            };
        }

        fn evalInner(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64, comptime skip_const: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Dedup engages on ranges of >= 4 instances, and only when
            // finalize found real prep sharing (dedup_worth).
            const dedup_on = if (comptime can_dedup) self.dedup_worth and last - first >= 4 else false;
            const lane_off: usize = if (comptime can_dedup) @as(usize, lane) * self.prep_cache.len else 0;

            // Reset this lane's cache at start of each full-eval pass.
            if (comptime can_dedup) {
                if (dedup_on) @memset(self.eval_cache_hash[lane_off..][0..self.prep_cache.len], 0);
            }

            // Loop-invariant limiting snapshot: one field read, not one per
            // instance. Comptime-false for devices without a limit decl.
            const limiting = if (comptime has_limit) self.lim_active else false;

            var sink: HostSink(skip_const) = .{
                .b = self,
                .pl = pl,
                .xs = x,
                .xo = undefined,
                .dedup_on = dedup_on,
                .lane_off = lane_off,
            };
            eval_core.evalRange(D, true, &sink, first, last, 1, t, limiting);
        }

        fn localX(self: *Self, x: []const f64, id: usize) [n_u]f64 {
            var out: [n_u]f64 = undefined;
            inline for (0..n_u) |u| out[u] = x[self.gath[id * n_u + u]];
            return out;
        }

        /// SPICE MODEINITJCT: seed each device's PRIVATE limited eval point
        /// (lim_x) so iteration 1 linearizes every junction at vcrit/vto.
        /// Seeds must NOT be written into the shared node vector — one
        /// device's collector seed lands on another's emitter net and the
        /// colliding junctions come up at 0 V, leaving a near-singular
        /// first Jacobian (ngspice seeds CKTstate0 vbe/vbc, never CKTrhsOld).
        /// Per-unknown ?f64 — null unknowns eval at the gathered node value.
        fn seedFn(ctx: *anyopaque, x: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime has_limit) {
                for (0..self.count) |id| {
                    const sv = D.seed(&self.models[id], &self.instances[id]);
                    const xn = self.localX(x, id);
                    inline for (0..n_u) |u|
                        self.lim_x[id * n_u + u] = sv[u] orelse xn[u];
                }
                self.lim_active = true;
            }
        }

        /// Mark unknowns whose kind is not .voltage (MNA branch currents).
        fn markCurrentRows(ctx: *anyopaque, mask: []bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                inline for (0..n_u) |u| {
                    if (comptime D.u_kinds[u] != .voltage) {
                        const node = self.gath[id * n_u + u];
                        if (node != GROUND) mask[node] = true;
                    }
                }
            }
        }

        /// SPICE-style limiting: compute each instance's limited local x and
        /// store it as PRIVATE state (lim_x) consumed by the next eval. The
        /// solver's node vector is never written — writing driven/shared
        /// nodes fights sources and other devices on the same net. The
        /// "previous" voltages passed to D.limit are the ones the device
        /// actually evaluated at last iteration (ngspice keeps vd/vgs/…
        /// in CKTstate0 for exactly this).
        fn applyLimits(ctx: *anyopaque, x: []f64, x_old: []const f64) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var sink: HostSink(false) = .{
                .b = self,
                .pl = undefined,
                .xs = x,
                .xo = x_old,
                .dedup_on = false,
                .lane_off = 0,
            };
            const any = eval_core.limitRange(D, &sink, 0, @intCast(self.count), 1, self.lim_active);
            self.lim_active = true;
            return any != 0;
        }

        /// End-of-solve: evals go back to reading the node vector.
        fn clearLimits(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lim_active = false;
        }

        fn updateState(ctx: *anyopaque, x: []const f64) ?f64 {
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

        fn stateCtl(ctx: *anyopaque, op: StateCtlOp) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var dirty = false;
            for (0..self.count) |id| {
                if (D.stateCtl(&self.models[id], &self.instances[id], &self.states[id], @enumFromInt(@intFromEnum(op)))) dirty = true;
            }
            return dirty;
        }

        fn setTemp(ctx: *anyopaque, temp_c: f32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| {
                // ponytail: infer K vs degC from default — >200 means Kelvin
                const default_temp = @field(D.Instance{}, "temp");
                inst.temp = if (default_temp > 200) temp_c + 273.15 else temp_c;
            }
            self.reprep();
        }

        fn applyAttempt(ctx: *anyopaque, lambda: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Save the TRUE models exactly once per continuation; every
            // lambda derives from them. Re-saving on each call compounds
            // the scaling (dc·λ₁·λ₂·…) — after λ=0 every later step AND
            // the restore ran with sources at zero, and Newton then
            // "converged" to the all-zero solution of that wrong circuit.
            if (!self.attempt_saved) {
                @memcpy(self.saved_models, self.models);
                self.attempt_saved = true;
            }
            for (self.models, self.saved_models) |*m, s| m.* = D.attempt(s, lambda);
            self.reprep();
        }

        fn restoreAttempt(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (!self.attempt_saved) return;
            self.attempt_saved = false;
            @memcpy(self.models, self.saved_models);
            self.reprep();
        }

        fn recomputePrecomputed(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.reprep();
        }

        /// Re-derive everything downstream of a model/instance change.
        fn reprep(self: *Self) void {
            if (comptime @hasDecl(D, "precompute")) {
                for (self.instances, self.models) |*inst, *mdl| D.precompute(inst, mdl);
            }
            if (comptime has_prep_cache) {
                // Groups are numbered in first-occurrence order (finalize's
                // dedup assigns new ids as it walks the devices), so one
                // O(count) pass meets each group's representative first.
                var next: u32 = 0;
                for (self.prep_group, 0..) |g, i| {
                    if (g == next) {
                        self.prep_cache[next] = D.computePrep(&self.models[i], &self.instances[i]);
                        next += 1;
                    }
                }
            }
        }

        fn recordHistory(ctx: *anyopaque, x: []const f64, t: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                const signals = D.gatherHistSignals(self.localX(x, id));
                self.history_bufs[id].record(t, &signals);
            }
        }

        fn injectHistory(ctx: *anyopaque, t: f64, rhs: []f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                // Concrete HistLookup value so devices can take `lookup: anytype`
                // (they cannot name this module's types).
                const adds = D.histInject(&self.models[id], HistLookup{ .buf = &self.history_bufs[id] }, t);
                inline for (0..n_u) |u| rhs[self.rhs_idx[id * n_u + u]] += adds[u];
            }
        }

        fn minDelay(ctx: *anyopaque) f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var min_td = std.math.inf(f64);
            for (self.models) |*m| {
                for (D.delays(m)) |d| min_td = @min(min_td, d);
            }
            return min_td;
        }

        fn nextBreakpointFn(ctx: *anyopaque, t: f64) ?f64 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var best: f64 = std.math.inf(f64);
            for (self.models) |*m| {
                if (D.nextBreakpoint(m, t)) |bp| best = @min(best, bp);
            }
            return if (best == std.math.inf(f64)) null else best;
        }

        fn collectParams(ctx: *anyopaque, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) anyerror!void {
            @setEvalBranchQuota(100_000);
            const self: *Self = @ptrCast(@alignCast(ctx));
            try appendParams(D.Instance, self.instances, true, gpa, list);
            try appendParams(D.Model, self.models, false, gpa, list);
        }

        /// Shared Instance/Model walk. Primary = mc_param match when the
        /// device declares one, else the first instance param field.
        fn appendParams(comptime T: type, items: anytype, comptime is_instance: bool, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) anyerror!void {
            const type_name = comptime blk: {
                const full = @typeName(D);
                const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse break :blk full;
                break :blk full[dot + 1 ..];
            };
            comptime var field_idx: usize = 0;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime paramField(T, field)) {
                    const primary = comptime if (@hasDecl(D, "mc_param"))
                        std.mem.eql(u8, field.name, D.mc_param)
                    else
                        is_instance and field_idx == 0;
                    for (items, 0..) |*it, idx| {
                        try list.append(gpa, .{
                            .ptr = &@field(it, field.name),
                            .device_type = type_name,
                            .param_name = field.name,
                            .index = @intCast(idx),
                            .is_instance = is_instance,
                            .primary = primary,
                        });
                    }
                    field_idx += 1;
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
        fn collectNoise(ctx: *anyopaque, x: []const f64, gpa: std.mem.Allocator, list: *std.ArrayList(NoiseSource)) anyerror!void {
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

        // -- GPU packing: serialize this batch's SoA tapes + params into the
        // problem blob. Layout assumption: D.Model/D.Instance byte layouts
        // match between x86_64 and nvptx64 (both LP64, natural alignment) —
        // the same assumption GpuEvalKernel's models/instances params make.
        // Kernel compiles every device type; only state/history (CPU-side
        // integration) disqualifies a batch.
        const gpu_ok = !has_state and !has_hist;

        fn gpuPackSize(ctx: *anyopaque) usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const c = self.count;
            const a8 = gpu_abi.alignUp;
            var sz: usize = a8(c * n_u * 4, 8) * 2; // gath + rhs_idx
            sz += a8(c * @sizeOf(D.Model), 8) + a8(c * @sizeOf(D.Instance), 8);
            if (comptime has_prep_cache)
                sz += a8(self.prep_cache.len * @sizeOf(D.PrepCache), 8) + a8(c * 4, 8);
            return sz;
        }

        fn gpuPack(ctx: *anyopaque, dest: []u8, base_off: u32, n: u32) gpu_abi.BatchDesc {
            _ = n;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const c = self.count;
            var desc: gpu_abi.BatchDesc = .{
                .kind_id = gpu_abi.kindId(D),
                .count = @intCast(c),
                .n_u = n_u,
                .has_q = @intFromBool(has_q),
                .off_gath = 0,
                .off_rhs_idx = 0,
                .off_models = 0,
                .off_instances = 0,
                .off_prep_cache = 0,
                .off_prep_group = 0,
            };
            var off: usize = 0;
            desc.off_gath = put(dest, &off, base_off, std.mem.sliceAsBytes(self.gath));
            desc.off_rhs_idx = put(dest, &off, base_off, std.mem.sliceAsBytes(self.rhs_idx));
            desc.off_models = put(dest, &off, base_off, std.mem.sliceAsBytes(self.models));
            desc.off_instances = put(dest, &off, base_off, std.mem.sliceAsBytes(self.instances));
            if (comptime has_prep_cache) {
                desc.off_prep_cache = put(dest, &off, base_off, std.mem.sliceAsBytes(self.prep_cache));
                desc.off_prep_group = put(dest, &off, base_off, std.mem.sliceAsBytes(self.prep_group));
            }
            return desc;
        }

        fn put(dest: []u8, off: *usize, base_off: u32, bytes: []const u8) u32 {
            const at = off.*;
            @memcpy(dest[at..][0..bytes.len], bytes);
            off.* = gpu_abi.alignUp(at + bytes.len, 8);
            return base_off + @as(u32, @intCast(at));
        }

        fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            gpa.free(self.models);
            if (comptime has_attempt) gpa.free(self.saved_models);
            if (comptime has_limit) gpa.free(self.lim_x);
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
