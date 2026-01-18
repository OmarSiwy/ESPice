//! engine.zig — the whole device engine in one file: the derivative scalar,
//! type-erased batching (SoA), a SINK-PARAMETERIZED eval so one physics body
//! serves both CPU and GPU, persistent-worker CPU threading, the runtime `.so`
//! device ABI, and runtime VA/Verilog compile+cache+load.
//!
//! Consolidates the former batch.zig + par.zig + dyn.zig + load.zig.
//!
//! CPU vs GPU: gompute's `map` is elementwise-scalar-only and its `RawKernel`
//! is device-only, so device assembly (sparse gather → eval residual+Jacobian →
//! scatter) cannot be a single "compile the CPU code for GPU" map. Instead the
//! physics is written ONCE in `evalRange`, generic over a `sink`:
//! ONE `Sink(D, device, skip_const)` serves both: `device=false` scatters `+=`
//! into the shared planes with per-lane dedup (par.zig runs the lanes);
//! `device=true` is a gompute `RawKernel` that atomic-scatters and compiles the
//! dedup out. gompute owns the GPU build/launch (was the hand-rolled
//! ptxas/nvlink megakernel).

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");
const gompute = @import("gompute"); // GPU: RawKernel build/launch (shared core)
// NVPTX/AMDGCN emit no libcalls, so `@exp`/`@log`/`@sin`/`@cos` and
// std.math's sinh/cosh/pow are hard codegen errors in device compilation.
// gompute.math is the drop-in that also forwards to libm on the host.
const dmath = gompute.math;
// engine.zig is the SHARED device core: the app compiles it at comptime for
// builtins, and the FastVAF `.so` compiles this SAME source at runtime for
// dynamics — identical format by construction. Deps: std + contract + gompute
// (both app and .so provide gompute); NO fastvaf (that would be circular — the
// fastvaf-dependent loader lives in loader.zig, app-only).

// ===========================================================================
// Derivative scalar (moved out of contract.zig — the engine is the only thing
// that instantiates device physics with a concrete S).
// ===========================================================================

/// Forward-mode dual satisfying the device scalar interface S: one eval pass
/// yields residual + all analytic partials. Lane u carries ∂/∂x[u].
///
/// MIXED PRECISION. `F` is the width of the DERIVATIVE half only; the value
/// half is always f64 and every boundary of the contract's S protocol
/// (`con`/`scale`/`addC`/`val`/`ddxAt`) is f64, so a device never sees `F`.
/// `F = f32` is the inexact-Newton construction: Newton converges to the
/// accuracy of the RESIDUAL, and an approximate Jacobian costs iteration count
/// rather than the answer. It exists because sm_89 runs f32 at 69x its f64 rate
/// (docs/gpu-device-eval.md §1), which is the only route by which a compact
/// model beats this CPU. `jacFloat` decides per device — the permission is the
/// device's `jac_f32`, because only the physics knows whether its unknowns fit
/// in f32's ~7 digits.
pub fn Dual(comptime N: usize, comptime F: type) type {
    return struct {
        v: f64,
        d: V,

        const V = @Vector(N, F);
        const Self = @This();

        inline fn splat(c: f64) V {
            return @splat(@floatCast(c));
        }
        pub fn seed(value: f64, comptime u: usize) Self {
            var d: V = @splat(0);
            d[u] = 1;
            return .{ .v = value, .d = d };
        }
        pub fn con(c: f64) Self {
            return .{ .v = c, .d = splat(0) };
        }
        /// One of the three places the Jacobian widens back to f64 — the
        /// solver's `g_vals` is `[]f64` and feeds a sparse LU. The other two are
        /// `evalRange`'s scatter and its limiting correction.
        pub fn ddxAt(a: Self, col: usize) f64 {
            const lanes: [N]F = a.d;
            return lanes[col];
        }
        /// The whole derivative, widened. Callers that need f64 partials (the
        /// scatter, the limiting correction, the dedup cache, noise) go through
        /// this rather than reading `.d`, so `F` stays private to the arithmetic.
        pub inline fn grad(a: Self) @Vector(N, f64) {
            return if (F == f64) a.d else @floatCast(a.d);
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
            const e = dmath.exp(a.v);
            return .{ .v = e, .d = a.d * splat(e) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = dmath.log(a.v), .d = a.d * splat(1.0 / a.v) };
        }
        /// LRM 4.3.1 Table 4-14 names the C library forms, and `contract.zig`
        /// requires them of the S protocol as PRIMITIVES rather than `exp(x)-1`
        /// and `log(1+x)`, because those two compositions cancel: at x = 1e-17,
        /// `1+x` rounds to 1 and `log(1+x)` answers 0 where the true value is
        /// 1e-17. A VerA-generated device calls these directly (that is what
        /// `no field or member function named 'log1p'` was), so their absence
        /// here was a hole in this host's half of the contract, not a device bug.
        ///
        /// `gompute.math` has no `log1p`/`expm1` and this type also compiles for
        /// nvptx, so `std.math` is out. These are the standard Kahan corrections,
        /// which need only `exp`/`log` and are accurate to within an ulp or two
        /// across the range where the naive form loses everything.
        pub fn expm1(a: Self) Self {
            const u = dmath.exp(a.v);
            const v = if (u == 1.0) a.v // x so small that e^x rounded to 1
            else if (u - 1.0 == -1.0) -1.0 // x so negative that e^x rounded to 0
            else (u - 1.0) * a.v / dmath.log(u);
            // d/dx (e^x - 1) = e^x, and `u` is that derivative already.
            return .{ .v = v, .d = a.d * splat(u) };
        }
        pub fn log1p(a: Self) Self {
            const u = 1.0 + a.v;
            // `a.v / (u - 1.0)` is the correction for the rounding of 1 + x: it
            // is 1 when 1+x is exact and slightly off when it is not.
            const v = if (u == 1.0) a.v else dmath.log(u) * (a.v / (u - 1.0));
            return .{ .v = v, .d = a.d * splat(1.0 / u) };
        }
        pub fn sqrt(a: Self) Self {
            const s = @sqrt(a.v);
            return .{ .v = s, .d = a.d * splat(if (s > 0.0) 0.5 / s else 0.0) };
        }
        pub fn sin(a: Self) Self {
            return .{ .v = dmath.sin(a.v), .d = a.d * splat(dmath.cos(a.v)) };
        }
        pub fn cos(a: Self) Self {
            return .{ .v = dmath.cos(a.v), .d = a.d * splat(-dmath.sin(a.v)) };
        }
        pub fn tanh(a: Self) Self {
            const th = dmath.tanh(a.v);
            return .{ .v = th, .d = a.d * splat(1.0 - th * th) };
        }
        pub fn abs(a: Self) Self {
            return if (a.v < 0) a.neg() else a;
        }
        pub fn minC(a: Self, c: f64) Self {
            return if (a.v > c) con(c) else a;
        }
        pub fn maxC(a: Self, c: f64) Self {
            return if (a.v < c) con(c) else a;
        }
        pub fn pow(a: Self, c: f64) Self {
            const p = dmath.pow(a.v, c);
            const slope = c * p / a.v;
            return .{ .v = p, .d = a.d * splat(if (std.math.isFinite(slope)) slope else 0.0) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = std.math.atan(a.v), .d = a.d * splat(1.0 / (1.0 + a.v * a.v)) };
        }
        pub fn sinh(a: Self) Self {
            return .{ .v = dmath.sinh(a.v), .d = a.d * splat(dmath.cosh(a.v)) };
        }
        pub fn cosh(a: Self) Self {
            return .{ .v = dmath.cosh(a.v), .d = a.d * splat(dmath.sinh(a.v)) };
        }
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

// ===========================================================================
// Constants + contract re-exports
// ===========================================================================

/// Width of the derivative half of `Dual` for device D. `pub const jac_f32` is
/// VerA's `--jac-f32` permission (contract.zig, "THE WIDTHS INSIDE S ARE THE
/// HOST'S"); a device that does not declare it gets f64, which is what a host
/// must assume.
pub fn jacFloat(comptime D: type) type {
    return if (@hasDecl(D, "jac_f32") and D.jac_f32) f32 else f64;
}

pub const GROUND: u32 = 0;

pub const StateCtlOp = contract.StateCtlOp;
pub const UpdateResult = contract.UpdateResult;
pub const AnalysisKind = contract.AnalysisKind;
pub const SimState = contract.SimState;
pub const LimitResult = contract.LimitResult;
pub const Constant = contract.Constant;

// ===========================================================================
// Circuit-facing types
// ===========================================================================

pub const ParamRef = struct {
    /// Tagged because BOTH widths are live: VerA emits `f64` parameters, while
    /// hand-written devices (tests/testdev.zig, and any device written straight
    /// against the contract) still use `f32`. A single-width `*f32` here is what
    /// silently emptied `collectParams` for every generated device and took
    /// `.dc` sweep, Monte Carlo, sensitivity and dcmatch down with it — those
    /// four read the circuit's parameters through this and got nothing back.
    ///
    /// The accessors below are the whole interface; nothing outside should
    /// switch on the tag. Values move as `f64` because that is what the callers
    /// compute in — an `f32` field round-trips through `@floatCast`, which is
    /// exactly the precision the device declared.
    ptr: Ptr,
    device_type: []const u8,
    param_name: []const u8,
    index: u32,
    is_instance: bool,
    primary: bool,
    pelgrom_ap: f64 = 0,
    area_wl: f64 = 0,

    pub const Ptr = union(enum) {
        f32: *f32,
        f64: *f64,
    };

    pub fn get(self: ParamRef) f64 {
        return switch (self.ptr) {
            .f32 => |p| p.*,
            .f64 => |p| p.*,
        };
    }

    pub fn set(self: ParamRef, v: f64) void {
        switch (self.ptr) {
            .f32 => |p| p.* = @floatCast(v),
            .f64 => |p| p.* = v,
        }
    }
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
/// slices; parallel eval points lanes 1.. at private slabs and reduces after.
pub const Planes = struct {
    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,
};

/// Per-type device batch vtable. One entry per device TYPE, created by
/// ProtoStore(D).finalize(). eval/eval_newton stamp [first..last) into `pl`;
/// `lane` selects the per-lane dedup cache (0 on the serial path).
pub const Batch = struct {
    // -- hot --
    ctx: *anyopaque,
    eval: *const fn (*anyopaque, *const Planes, lane: u32, first: u32, last: u32, []const f64, f64) void,
    eval_newton: *const fn (*anyopaque, *const Planes, lane: u32, first: u32, last: u32, []const f64, f64) void,
    count: u32,
    n_u: u32,
    has_charge: bool,
    has_const_jacobian: bool,
    /// False when eval uses shared per-batch scratch — such a batch runs whole
    /// on one lane.
    thread_safe: bool,

    // -- cold --
    type_name: []const u8,
    hooks: *const Hooks,
};

/// Cold per-device-type vtable. Null entry ⇒ device type lacks the hook.
pub const Hooks = struct {
    set_lanes: ?*const fn (*anyopaque, std.mem.Allocator, u32) anyerror!void = null,
    scatter_bounds: *const fn (*anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32,
    apply_limits: ?*const fn (*anyopaque, []f64, []const f64) bool = null,
    clear_limits: ?*const fn (*anyopaque) void = null,
    seed: ?*const fn (*anyopaque, []f64) void = null,
    mark_current_rows: ?*const fn (*anyopaque, []bool) void = null,
    update_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    state_ctl: ?*const fn (*anyopaque, StateCtlOp) bool = null,
    set_temp: ?*const fn (*anyopaque, f32) void = null,
    /// Host-owned Instance fields (`$abstime`, timestep, `analysis()`,
    /// `initial_step`/`final_step`). A generated device READS these and never
    /// writes them, so nothing else in the engine can supply them — without
    /// this hook `$abstime` is pinned at its default 0 and every SPICE
    /// waveform degenerates to its t=0 value.
    ///
    /// Contract with the analyses: call it once per SOLVE ATTEMPT (before
    /// eval/updateState run for that attempt), never per Newton iteration —
    /// it walks every instance, so it is O(count) per timepoint by design.
    set_sim_state: ?*const fn (*anyopaque, SimState) void = null,
    record_history: ?*const fn (*anyopaque, []const f64, f64) void = null,
    inject_history: ?*const fn (*anyopaque, f64, []f64) void = null,
    min_delay: ?*const fn (*anyopaque) f64 = null,
    next_breakpoint: ?*const fn (*anyopaque, f64) ?f64 = null,
    collect_params: *const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(ParamRef)) anyerror!void,
    collect_noise: ?*const fn (*anyopaque, []const f64, std.mem.Allocator, *std.ArrayList(NoiseSource)) anyerror!void = null,
    recompute: ?*const fn (*anyopaque) void = null,
    /// This batch's device-resident working set, or null when the device type
    /// is not `gpuEligible` — the launcher reads a null here as "this batch
    /// stays on the CPU" and declines the whole circuit rather than splitting a
    /// solve across both, which would cost a plane round-trip per iteration to
    /// merge.
    gpu_payload: ?*const fn (*anyopaque) GpuPayload = null,
    apply_attempt: ?*const fn (*anyopaque, f64) void = null,
    restore_models: ?*const fn (*anyopaque) void = null,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const Proto = struct {
    ctx: *anyopaque,
    type_name: []const u8,
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) anyerror!void,
    finalize: *const fn (*anyopaque, std.mem.Allocator, PatternView) anyerror!Batch,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

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

pub const PatternBuilder = struct {
    keys: std.ArrayList(u64) = .empty,

    fn key(row: u32, col: u32) u64 {
        return (@as(u64, col) << 32) | row; // col-major sort order
    }

    pub fn add(self: *PatternBuilder, gpa: std.mem.Allocator, row: u32, col: u32) !void {
        try self.keys.append(gpa, key(row, col));
    }

    pub fn reserve(self: *PatternBuilder, gpa: std.mem.Allocator, extra: usize) !void {
        try self.keys.ensureUnusedCapacity(gpa, extra);
    }

    pub fn deinit(self: *PatternBuilder, gpa: std.mem.Allocator) void {
        self.keys.deinit(gpa);
    }

    /// LSD radix sort (16-bit digits): O(n) on the bounded (col,row) keys.
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
/// trash slot / trash row (ground writes) excluded.
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

pub const HistoryBuffer = struct {
    times: []f64,
    values: []f64, // values[sample_idx * n_signals + signal_idx]
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

    pub fn record(self: *HistoryBuffer, t: f64, vals: []const f64) void {
        std.debug.assert(vals.len == self.n_signals);
        const slot = self.head;
        self.times[slot] = t;
        const base = @as(usize, slot) * self.n_signals;
        @memcpy(self.values[base..][0..self.n_signals], vals);
        self.head = (slot + 1) % self.capacity;
        if (self.len < self.capacity) self.len += 1;
    }

    /// Look up signal `sig` at `t_query`. 3-point Lagrange through the two
    /// samples at/before and the one after; linear when only two bracket.
    pub fn lookup(self: *const HistoryBuffer, t_query: f64, sig: u32) f64 {
        if (self.len == 0) return 0.0;
        const oldest = if (self.len < self.capacity) 0 else self.head;

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

// ===========================================================================
// Sink-parameterized eval — the ONE physics body. `sink` (comptime-known)
// owns all memory access, so the same loop serves both instantiations of the
// ONE `Sink` type (CPU `+=`, GPU atomic-scatter). Always AD (Dual): residual +
// Jacobian in one pass.
// ===========================================================================

fn evalRange(comptime D: type, sink: anytype, first: u32, end: u32, t: f64, limiting: bool) void {
    @setEvalBranchQuota(1_000_000);
    const SinkT = @typeInfo(@TypeOf(sink)).pointer.child;
    @setFloatMode(if (SinkT.optimized_float) .optimized else .strict);
    const n_u = comptime contract.nU(D);
    const has_limit = comptime @hasDecl(D, "limit");
    const S = Dual(n_u, jacFloat(D));
    const use_lim = if (comptime has_limit) limiting else false;

    var id: u32 = first;
    while (id < end) : (id += 1) {
        // Gather the local eval point; corr = local(x) − lx (zero unless limiting).
        var lx: [n_u]f64 = undefined;
        var corr: @Vector(n_u, f64) = @splat(0);
        inline for (0..n_u) |u| {
            const gi = sink.gath(id, u);
            const xg = sink.x(gi);
            lx[u] = xg;
            if (use_lim) {
                const l = sink.lim(id, u);
                lx[u] = l;
                corr[u] = xg - l;
            }
        }

        if (comptime SinkT.dedup) {
            if (sink.tryCached(id, &lx, corr)) continue;
        }

        var xv: [n_u]S = undefined;
        inline for (0..n_u) |u| xv[u] = S.seed(lx[u], u);

        const out = if (comptime @hasDecl(D, "evalFromPrep"))
            D.evalFromPrep(S, xv, sink.prep(id), sink.model(id), sink.inst(id), t)
        else
            D.eval(S, xv, sink.model(id), sink.inst(id), t);

        inline for (0..n_u) |ru| {
            const row = sink.rhsRow(id, ru);
            var val = out[ru].v;
            if (comptime has_limit) {
                // Widened FIRST: this term lands on the residual, which stays
                // f64 whatever the Jacobian is carried in.
                if (use_lim) val += @reduce(.Add, out[ru].grad() * corr);
            }
            sink.scatterRes(row, val);
            if (comptime !SinkT.skip_g) {
                const g = out[ru].grad();
                inline for (0..n_u) |cu| sink.scatterJac(id, ru, cu, row, g[cu]);
            }
        }
        if (comptime SinkT.dedup) sink.store(id, &out);

        if (comptime @hasDecl(D, "q")) {
            if (sink.qActive()) {
                const qo = if (comptime @hasDecl(D, "qFromPrep"))
                    D.qFromPrep(S, xv, sink.prep(id), sink.model(id), sink.inst(id), t)
                else
                    D.q(S, xv, sink.model(id), sink.inst(id), t);
                inline for (0..n_u) |ru| {
                    const row = sink.rhsRow(id, ru);
                    var qv = qo[ru].v;
                    if (comptime has_limit) {
                        if (use_lim) qv += @reduce(.Add, qo[ru].grad() * corr);
                    }
                    sink.scatterQ(row, qv);
                    if (comptime !SinkT.skip_c) {
                        const gq = qo[ru].grad();
                        inline for (0..n_u) |cu| sink.scatterQJac(id, ru, cu, row, gq[cu]);
                    }
                }
                if (comptime SinkT.dedup) sink.storeQ(id, &qo);
            }
        }
    }
}

/// SPICE-style limiting pass: cur = local(x); old = lim (once engaged) else
/// local(x_old); lim = D.limit(cur, old). Returns 1.0 if any instance reported
/// `converged = false` — the DEVICE decides whether its clamp was significant
/// enough to force another Newton iteration (pnjlim says yes, a cosmetic
/// fetlim/limvds clamp says no). This replaces the old `limit_flag_unknowns`
/// table, which could only answer that positionally and so could not tell a
/// large clamp from a small one on the same unknown.
fn limitRange(comptime D: type, sink: anytype, first: u32, end: u32, lim_active: bool) f64 {
    const n_u = comptime contract.nU(D);
    var flag: f64 = 0;
    var id: u32 = first;
    while (id < end) : (id += 1) {
        var cur: [n_u]f64 = undefined;
        var old: [n_u]f64 = undefined;
        inline for (0..n_u) |u| {
            const gi = sink.gath(id, u);
            cur[u] = sink.x(gi);
            old[u] = if (lim_active) sink.lim(id, u) else sink.xOld(gi);
        }
        const lm = D.limit(sink.model(id), sink.inst(id), cur, old);
        if (!lm.converged) flag = 1;
        inline for (0..n_u) |u| sink.setLim(id, u, lm.x[u]);
    }
    return flag;
}

// ===========================================================================
// ProtoStore(D) + DeviceBatch(D): comptime device accumulation and the frozen
// SoA batch with the AD eval hot loop and cold Hooks vtable.
// ===========================================================================

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
            const const_g = @hasDecl(D, "constant") and D.constant.g;
            const const_c = @hasDecl(D, "constant") and D.constant.c;
            const has_attempt_decl = @hasDecl(D, "attempt");
            const self: *Self = @ptrCast(@alignCast(ctx));
            const count = self.models.items.len;
            const store = try gpa.create(DeviceBatch(D));

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
                for (store.history_bufs) |*b|
                    b.* = .{ .times = &.{}, .values = &.{}, .n_signals = 0, .capacity = 0, .head = 0, .len = 0 };
                for (0..count) |i|
                    store.history_bufs[i] = try HistoryBuffer.init(gpa, D.n_hist_signals, 8192);
            }

            if (comptime @hasDecl(D, "precompute")) {
                for (0..count) |i| D.precompute(&store.instances[i], &store.models[i]);
            }

            if (comptime has_prep_cache) {
                const all = try gpa.alloc(D.PrepCache, count);
                defer gpa.free(all);
                for (0..count) |i| all[i] = D.computePrep(&store.models[i], &store.instances[i]);

                store.prep_group = try gpa.alloc(u32, count);
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

// ponytail: the two predicates below are PROVABLY FALSE for every device the
// contract now admits — `histInject` and `PrepCache` were deleted from
// `contract.allowed_pub_decls`, so a device declaring either fails validation
// as a stray pub decl. Everything they gate (HistoryBuffer/HistLookup, the
// prep-cache dedup, the per-lane eval cache, `gpuEligible`'s first and third
// terms) is therefore comptime-dead and compiles to nothing.
//
// Kept rather than deleted on purpose: it is ~270 lines threaded through the
// hot eval loop and the ParEval lane machinery, the deletion has zero
// behavioural payoff, and the risk sits in the one file where a mistake is
// silent and fast. See VerA/TODO.md "Dead code in the consumer" — delete it
// with the history-subsystem landing that also touches Circuit/tran/pss, not
// piecemeal.
//
// FastVAF owns delay history now: `absdelay` lowers to a private ring in
// `Instance` advanced by `updateState`, not to a host callback.

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
    const S = Dual(n_u, jacFloat(D));
    const has_state = @hasDecl(D, "State");
    const has_hist = hasHistoryDecl(D);
    const has_prep_cache = @hasDecl(D, "PrepCache");
    const can_dedup = canDedup(D);
    const can_dedup_q = canDedupQ(D);

    const has_attempt = @hasDecl(D, "attempt");
    const has_limit = @hasDecl(D, "limit");
    // A device that reads none of the host-owned fields gets a null hook, so
    // the analyses' per-timepoint sweep skips it entirely.
    const has_sim_state = @hasField(D.Instance, "abstime") or
        @hasField(D.Instance, "dt") or
        @hasField(D.Instance, "analysis_kind") or
        @hasField(D.Instance, "is_initial_step") or
        @hasField(D.Instance, "is_final_step");

    return struct {
        count: usize,
        models: []D.Model,
        saved_models: if (has_attempt) []D.Model else void,
        attempt_saved: if (has_attempt) bool else void,
        lim_x: if (has_limit) []f64 else void,
        lim_active: if (has_limit) bool else void,
        instances: []D.Instance,
        states: if (has_state) []D.State else void,
        history_bufs: if (has_hist) []HistoryBuffer else void,
        gath: []u32,
        rhs_idx: []u32,
        slots: []u32,
        prep_cache: if (has_prep_cache) []D.PrepCache else void,
        prep_group: if (has_prep_cache) []u32 else void,

        dedup_worth: if (can_dedup) bool else void,
        n_lanes: if (can_dedup) u32 else void,
        eval_cache_hash: if (can_dedup) []u64 else void,
        eval_cache_rhs: if (can_dedup) [][n_u]f64 else void,
        eval_cache_jac: if (can_dedup) [][n_u][n_u]f64 else void,
        eval_cache_q_rhs: if (can_dedup_q) [][n_u]f64 else void,
        eval_cache_q_jac: if (can_dedup_q) [][n_u][n_u]f64 else void,

        const Self = @This();

        pub const hooks: Hooks = .{
            .set_lanes = if (can_dedup) setLanes else null,
            .scatter_bounds = scatterBounds,
            .apply_limits = if (has_limit) applyLimits else null,
            .clear_limits = if (has_limit) clearLimits else null,
            .seed = if (@hasDecl(D, "seed")) seedFn else null,
            .mark_current_rows = if (@hasDecl(D, "u_kinds")) markCurrentRows else null,
            .update_state = if (@hasDecl(D, "updateState")) updateState else null,
            .state_ctl = if (@hasDecl(D, "stateCtl")) stateCtl else null,
            .set_temp = if (@hasField(D.Instance, "temperature")) setTemp else null,
            .set_sim_state = if (has_sim_state) setSimState else null,
            .record_history = if (has_hist) recordHistory else null,
            .inject_history = if (has_hist) injectHistory else null,
            .min_delay = if (has_hist) minDelay else null,
            .next_breakpoint = if (@hasDecl(D, "nextBreakpoint")) nextBreakpointFn else null,
            .collect_params = collectParams,
            .collect_noise = if (@hasDecl(D, "noise_gens")) collectNoise else null,
            .recompute = if (@hasDecl(D, "precompute") or has_prep_cache) recomputePrecomputed else null,
            .gpu_payload = if (gpuEligible(D)) gpuPayload else null,
            .apply_attempt = if (has_attempt) applyAttempt else null,
            .restore_models = if (has_attempt) restoreAttempt else null,
            .deinit = destroy,
        };

        fn eval(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, false);
        }

        fn evalNewton(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
            evalInner(ctx, pl, lane, first, last, x, t, true);
        }

        fn scatterBounds(ctx: *anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return tapeBounds(self.slots[first * n_u * n_u .. last * n_u * n_u], self.rhs_idx[first * n_u .. last * n_u], trash_slot, trash_row);
        }

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

        pub fn hashVoltages(lx: *const [n_u]f64) u64 {
            var h: u64 = 0x517cc1b727220a95;
            inline for (0..n_u) |u| {
                h ^= @as(u64, @bitCast(lx[u]));
                h *%= 0x9e3779b97f4a7c15;
            }
            return h | 1;
        }

        pub inline fn corrDot(jrow: @Vector(n_u, f64), corr: @Vector(n_u, f64)) f64 {
            return if (comptime has_limit) @reduce(.Add, jrow * corr) else 0.0;
        }

        fn evalInner(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64, comptime skip_const: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const dedup_on = if (comptime can_dedup) self.dedup_worth and last - first >= 4 else false;
            const lane_off: usize = if (comptime can_dedup) @as(usize, lane) * self.prep_cache.len else 0;

            if (comptime can_dedup) {
                if (dedup_on) @memset(self.eval_cache_hash[lane_off..][0..self.prep_cache.len], 0);
            }

            const limiting = if (comptime has_limit) self.lim_active else false;

            var sink = Sink(D, false, skip_const).host(self, pl, x, undefined, dedup_on, lane_off);
            evalRange(D, &sink, first, last, t, limiting);
        }

        fn localX(self: *Self, x: []const f64, id: usize) [n_u]f64 {
            var out: [n_u]f64 = undefined;
            inline for (0..n_u) |u| out[u] = x[self.gath[id * n_u + u]];
            return out;
        }

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

        fn applyLimits(ctx: *anyopaque, x: []f64, x_old: []const f64) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // limitRange never scatters to the planes; an empty Planes keeps the
            // sink's plane .ptr reads valid (undefined would trap in Debug).
            const no_planes: Planes = .{ .g_vals = &.{}, .c_vals = &.{}, .rhs = &.{}, .q_vec = &.{} };
            var sink = Sink(D, false, false).host(self, &no_planes, x, x_old, false, 0);
            const any = limitRange(D, &sink, 0, @intCast(self.count), self.lim_active);
            self.lim_active = true;
            return any != 0;
        }

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

        /// §9.10 `$temperature` is KELVIN; the host speaks Celsius (the SPICE
        /// `.temp` card), hence the conversion. The field was probed as "temp"
        /// until now — a name no generated device has — so this hook was
        /// silently null and `.temp`/`temp_sweep` moved only the explicit
        /// TempCoeff parameters, never the device's own junction physics.
        fn setTemp(ctx: *anyopaque, temp_c: f32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| inst.temperature = @as(f64, temp_c) + 273.15;
            self.reprep();
        }

        /// Write the host-owned Instance block. Field-by-field `@hasField` so a
        /// device that reads only `$abstime` pays for exactly that store.
        /// No `reprep()`: FastVAF hoists nothing time-dependent into
        /// precompute/PrepCache (no generated device declares either), so
        /// there is no derived state to invalidate.
        fn setSimState(ctx: *anyopaque, st: SimState) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.instances) |*inst| {
                if (comptime @hasField(D.Instance, "abstime")) inst.abstime = st.t;
                if (comptime @hasField(D.Instance, "dt")) inst.dt = st.dt;
                // Devices declare their own AnalysisKind; ordinal-convert like
                // stateCtl does for StateCtlOp.
                if (comptime @hasField(D.Instance, "analysis_kind"))
                    inst.analysis_kind = @enumFromInt(@intFromEnum(st.kind));
                if (comptime @hasField(D.Instance, "is_initial_step")) inst.is_initial_step = st.initial_step;
                if (comptime @hasField(D.Instance, "is_final_step")) inst.is_final_step = st.final_step;
            }
        }

        fn applyAttempt(ctx: *anyopaque, lambda: f64) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
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

        /// Hand the launcher this batch's working set. Slices, not copies —
        /// the batch keeps owning them; the launcher only reads them to stage
        /// device memory (and re-reads `models`/`instances` on `repack`).
        fn gpuPayload(ctx: *anyopaque) GpuPayload {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{
                .kernel = comptime kernelName(D),
                .count = @intCast(self.count),
                .n_u = n_u,
                .models = std.mem.sliceAsBytes(self.models),
                .instances = std.mem.sliceAsBytes(self.instances),
                .gath = self.gath,
                .rhs_idx = self.rhs_idx,
                .slots = self.slots,
            };
        }

        fn recomputePrecomputed(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.reprep();
        }

        fn reprep(self: *Self) void {
            if (comptime @hasDecl(D, "precompute")) {
                for (self.instances, self.models) |*inst, *mdl| D.precompute(inst, mdl);
            }
            if (comptime has_prep_cache) {
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
                            .ptr = if (field.type == f32)
                                .{ .f32 = &@field(it, field.name) }
                            else
                                .{ .f64 = &@field(it, field.name) },
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

        fn paramField(comptime T: type, comptime field: std.builtin.Type.StructField) bool {
            if (field.type != f32 and field.type != f64) return false;
            const dflt = @field(T{}, field.name);
            return dflt > -1e30 and dflt < 1e30;
        }

        fn collectNoise(ctx: *anyopaque, x: []const f64, gpa: std.mem.Allocator, list: *std.ArrayList(NoiseSource)) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.count) |id| {
                var xd: [n_u]S = undefined;
                inline for (0..n_u) |u| xd[u] = S.seed(x[self.gath[id * n_u + u]], u);
                const out = D.eval(S, xd, &self.models[id], &self.instances[id], 0);
                inline for (D.noise_gens) |gen| {
                    switch (gen.kind) {
                        .thermal => {
                            const g = @abs(out[gen.row].ddxAt(gen.col));
                            if (g > 0) try list.append(gpa, .{
                                .node_p = self.gath[id * n_u + gen.row],
                                .node_n = self.gath[id * n_u + gen.col],
                                .conductance = g,
                            });
                        },
                        .shot, .flicker => {},
                    }
                }
            }
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

// ===========================================================================
// GPU path — the SAME evalRange body, driven by a gompute RawKernel with an
// atomic-scatter sink. One kernel per device type; builtins register at comptime
// (kernels.zig), a dynamic `.so` registers its one device from this same
// template. Buffers are flat SoA uploaded before launch (host mirrors of the
// batch tapes/planes). First cut targets simple devices (no prep-cache / state /
// history / limiting); richer devices stay CPU until their GPU state is added.
// ===========================================================================

/// Devices eligible for a GPU kernel in this first cut. PrepCache/State/history/
/// limiting each need extra device-side state not yet wired; those run CPU-only.
pub fn gpuEligible(comptime D: type) bool {
    return !@hasDecl(D, "PrepCache") and !@hasDecl(D, "State") and
        !hasHistoryDecl(D) and !@hasDecl(D, "limit");
}

/// The kernel symbol for device D — `arp_eval_<model>`.
///
/// Derived from the TYPE, and called by both sides: `kernels.zig` to export the
/// symbol into the GPU image, and `gpuPayload` below to name the symbol the
/// launcher looks up. One function so the two cannot drift into a green build
/// that fails with `error.KernelNotFound` on a machine with a GPU.
pub fn kernelName(comptime D: type) [:0]const u8 {
    const full = @typeName(D);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
    return "arp_eval_" ++ base;
}

/// One batch's device-resident working set, type-erased.
///
/// Everything here is written by the builder and then FROZEN for the life of
/// the solve, which is what lets the launcher upload it once and leave it on
/// the GPU: the tapes are pattern, and `models`/`instances` only change when a
/// sweep mutates a parameter (see the `repack` hook). Per Newton iteration the
/// launcher moves `x` in and the value planes out, and nothing else.
pub const GpuPayload = struct {
    /// `arp_eval_<model>`, from `kernelName`.
    kernel: []const u8,
    /// Instances in this batch — one GPU thread each.
    count: u32,
    /// Unknowns per instance. Fixes the tape strides below.
    n_u: u32,
    /// `[]D.Model` / `[]D.Instance` as bytes. POD by contract (§5 rule 3), so a
    /// byte copy is the whole upload.
    models: []const u8,
    instances: []const u8,
    /// count * n_u — global row each local unknown gathers x from.
    gath: []const u32,
    /// count * n_u — residual row each local unknown scatters to.
    rhs_idx: []const u32,
    /// count * n_u * n_u — CSC slot each Jacobian entry scatters to.
    slots: []const u32,
};

/// The ONE sink `evalRange`/`limitRange` consume. `device` picks the two axes
/// that differ between CPU and GPU and NOTHING else — the gather/index/eval body
/// is identical:
///   - memory access: host reads plain slices (GlobalPtr(T) == [*]T), device
///     casts the `.global` kernel params to generic addrspace (one cvta.global
///     on NVPTX) so the contract's generic-addrspace `eval` can read them.
///   - scatter: host `p[i] +=`; device `@atomicRmw(.Add)` (many threads stamp
///     one matrix slot; the atomic lowers to a global-space reduction).
///   - dedup: host-only prep-cache reuse; on device it compiles to always-miss
///     (atomics make racing threads correct), so the whole cache is gone.
/// The ABI-table fields are GlobalPtr both ways — one type, one body, two
/// backends. Host-only dedup/limit state hangs off `b: *DeviceBatch(D)` and is
/// `void` under `device`, so a device compilation never sees it.
pub fn Sink(comptime D: type, comptime device: bool, comptime skip_const: bool) type {
    const n_u = comptime uCount(D);
    const const_g = @hasDecl(D, "constant") and D.constant.g;
    const const_c = @hasDecl(D, "constant") and D.constant.c;
    const can_dedup = comptime canDedup(D);
    const can_dedup_q = comptime canDedupQ(D);
    const BatchT = DeviceBatch(D);
    return struct {
        xs: gompute.GlobalPtr(f64),
        gath_: gompute.GlobalPtr(u32),
        rhs_idx_: gompute.GlobalPtr(u32),
        slots_: gompute.GlobalPtr(u32),
        models_: gompute.GlobalPtr(D.Model),
        instances_: gompute.GlobalPtr(D.Instance),
        g_vals: gompute.GlobalPtr(f64),
        c_vals: gompute.GlobalPtr(f64),
        rhs: gompute.GlobalPtr(f64),
        q_vec: gompute.GlobalPtr(f64),

        // Host-only: the dedup caches / limit tables live on the batch. Device
        // dedup is compiled out, so none of this exists in a GPU compilation.
        b: if (device) void else *BatchT,
        xo: if (device) void else []const f64, // x_old (limit pass only)
        dedup_on: if (device) void else bool,
        lane_off: if (device) void else usize,
        cur_group: if (device) void else usize = if (device) {} else 0,
        cur_hash: if (device) void else u64 = if (device) {} else 0,

        pub const dedup = !device and can_dedup;
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
            return s.gath_[@as(usize, id) * n_u + u];
        }
        pub inline fn rhsRow(s: *const Sk, id: u32, ru: usize) u32 {
            return s.rhs_idx_[@as(usize, id) * n_u + ru];
        }
        pub inline fn lim(s: *const Sk, id: u32, u: usize) f64 {
            return s.b.lim_x[@as(usize, id) * n_u + u];
        }
        pub inline fn setLim(s: *const Sk, id: u32, u: usize, v: f64) void {
            s.b.lim_x[@as(usize, id) * n_u + u] = v;
        }
        // The contract's eval takes generic-addrspace pointers; on device the
        // `.global` param is cast here rather than copying the whole
        // Model/Instance per thread (a compact model's Model is hundreds of
        // params wide and would blow the register budget). On host the cast is
        // a no-op.
        pub inline fn model(s: *const Sk, id: u32) *const D.Model {
            return @addrSpaceCast(&s.models_[id]);
        }
        pub inline fn inst(s: *const Sk, id: u32) *const D.Instance {
            return @addrSpaceCast(&s.instances_[id]);
        }
        pub inline fn prep(s: *const Sk, id: u32) *const D.PrepCache {
            return &s.b.prep_cache[s.b.prep_group[id]];
        }
        inline fn slot(s: *const Sk, id: u32, ru: usize, cu: usize) u32 {
            return s.slots_[(@as(usize, id) * n_u + ru) * n_u + cu];
        }
        inline fn add(p: gompute.GlobalPtr(f64), i: u32, v: f64) void {
            if (comptime device) {
                _ = @atomicRmw(f64, &p[i], .Add, v, .monotonic);
            } else {
                p[i] += v;
            }
        }
        pub inline fn scatterRes(s: *const Sk, row: u32, val: f64) void {
            add(s.rhs, row, val);
        }
        pub inline fn scatterJac(s: *const Sk, id: u32, ru: usize, cu: usize, row: u32, val: f64) void {
            _ = row;
            add(s.g_vals, s.slot(id, ru, cu), val);
        }
        pub inline fn qActive(s: *const Sk) bool {
            _ = s;
            return true;
        }
        pub inline fn scatterQ(s: *const Sk, row: u32, qv: f64) void {
            add(s.q_vec, row, qv);
        }
        pub inline fn scatterQJac(s: *const Sk, id: u32, ru: usize, cu: usize, row: u32, val: f64) void {
            _ = row;
            add(s.c_vals, s.slot(id, ru, cu), val);
        }

        // dedup: host-only (guarded by `dedup` == false on device, so never
        // instantiated there). Reuses a prior eval when the gather point hashes
        // equal within the same prep group.
        pub inline fn tryCached(s: *Sk, id: u32, lx: *const [n_u]f64, corr: @Vector(n_u, f64)) bool {
            s.cur_group = s.lane_off + s.b.prep_group[id];
            s.cur_hash = if (s.dedup_on) BatchT.hashVoltages(lx) else 0;
            if (comptime skip_g or skip_c) return false;
            if (!s.dedup_on) return false;
            if (s.b.eval_cache_hash[s.cur_group] != s.cur_hash) return false;
            const cr = &s.b.eval_cache_rhs[s.cur_group];
            const cj = &s.b.eval_cache_jac[s.cur_group];
            inline for (0..n_u) |ru| {
                const cjv: @Vector(n_u, f64) = cj[ru];
                add(s.rhs, s.rhsRow(id, ru), cr[ru] + BatchT.corrDot(cjv, corr));
                inline for (0..n_u) |cu|
                    add(s.g_vals, s.slot(id, ru, cu), cj[ru][cu]);
            }
            if (comptime can_dedup_q) {
                const cqr = &s.b.eval_cache_q_rhs[s.cur_group];
                const cqj = &s.b.eval_cache_q_jac[s.cur_group];
                inline for (0..n_u) |ru| {
                    const cqjv: @Vector(n_u, f64) = cqj[ru];
                    add(s.q_vec, s.rhsRow(id, ru), cqr[ru] + BatchT.corrDot(cqjv, corr));
                    inline for (0..n_u) |cu|
                        add(s.c_vals, s.slot(id, ru, cu), cqj[ru][cu]);
                }
            }
            return true;
        }

        pub inline fn store(s: *Sk, id: u32, out: anytype) void {
            _ = id;
            if (comptime skip_g) return;
            if (!s.dedup_on) return;
            s.b.eval_cache_hash[s.cur_group] = s.cur_hash;
            inline for (0..n_u) |ru| {
                s.b.eval_cache_rhs[s.cur_group][ru] = out[ru].v;
                s.b.eval_cache_jac[s.cur_group][ru] = out[ru].grad();
            }
        }
        pub inline fn storeQ(s: *Sk, id: u32, qo: anytype) void {
            _ = id;
            if (comptime !(can_dedup_q and !skip_c)) return;
            if (!s.dedup_on) return;
            inline for (0..n_u) |ru| {
                s.b.eval_cache_q_rhs[s.cur_group][ru] = qo[ru].v;
                s.b.eval_cache_q_jac[s.cur_group][ru] = qo[ru].grad();
            }
        }

        // Host constructor: flatten the batch's slices to the GlobalPtr fields
        // (GlobalPtr(T) == [*]T here) so the shared body indexes them the same
        // way the device does. `has_limit` guards `xo`/lim state, unused off the
        // limit pass.
        pub fn host(b: *BatchT, pl: *const Planes, xs: []const f64, xo: []const f64, dedup_on: bool, lane_off: usize) Sk {
            return .{
                .xs = @constCast(xs.ptr), // read-only here; GlobalPtr carries no const
                .gath_ = b.gath.ptr,
                .rhs_idx_ = b.rhs_idx.ptr,
                .slots_ = b.slots.ptr,
                .models_ = b.models.ptr,
                .instances_ = b.instances.ptr,
                .g_vals = pl.g_vals.ptr,
                .c_vals = pl.c_vals.ptr,
                .rhs = pl.rhs.ptr,
                .q_vec = pl.q_vec.ptr,
                .b = b,
                .xo = xo,
                .dedup_on = dedup_on,
                .lane_off = lane_off,
            };
        }
    };
}

/// One-thread-per-instance GPU kernel for device D — the gompute RawKernel entry.
/// Body is the SHARED `evalRange`; only the sink differs from the CPU path.
/// `exportRaw`'d by kernels.zig (builtins) or the `.so` shim (dynamics), so it
/// is analyzed only in device compilation (globalIdX is device-only).
pub fn DeviceKernel(comptime D: type, comptime block_size: u32) type {
    return struct {
        pub fn run(
            count: u64,
            t: f64,
            xs: gompute.GlobalPtr(f64),
            gath: gompute.GlobalPtr(u32),
            rhs_idx: gompute.GlobalPtr(u32),
            slots: gompute.GlobalPtr(u32),
            models: gompute.GlobalPtr(D.Model),
            instances: gompute.GlobalPtr(D.Instance),
            g_vals: gompute.GlobalPtr(f64),
            c_vals: gompute.GlobalPtr(f64),
            rhs: gompute.GlobalPtr(f64),
            q_vec: gompute.GlobalPtr(f64),
        ) callconv(gompute.kernel_callconv) void {
            const tid = gompute.globalIdX(block_size);
            if (tid >= count) return;
            var sink = Sink(D, true, false){
                .xs = xs,
                .gath_ = gath,
                .rhs_idx_ = rhs_idx,
                .slots_ = slots,
                .models_ = models,
                .instances_ = instances,
                .g_vals = g_vals,
                .c_vals = c_vals,
                .rhs = rhs,
                .q_vec = q_vec,
                .b = {},
                .xo = {},
                .dedup_on = {},
                .lane_off = {},
            };
            const id: u32 = @intCast(tid);
            evalRange(D, &sink, id, id + 1, t, false);
        }
    };
}

// ===========================================================================
// ParEval — persistent-worker CPU threading. Lane 0 stamps into the caller's
// planes; lanes 1.. stamp private slabs, SIMD-reduced in fixed order (bit-
// identical run-to-run at a given n_lanes). Zero-alloc, no-mutex hot path.
// ===========================================================================

pub const EvalTask = struct {
    batch: u32,
    first: u32,
    last: u32,
};

const Window = struct {
    slot_lo: u32,
    slot_hi: u32, // exclusive
    row_lo: u32,
    row_hi: u32, // exclusive
};

pub const default_min_instances: u32 = 1024;

const Mode = enum(u8) { full, newton };

pub const ParEval = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    n_lanes: u32,

    g_slab: []f64,
    c_slab: []f64,
    rhs_slab: []f64,
    q_slab: []f64,

    tasks: []EvalTask,
    task_off: []u32,
    windows: []Window,

    nnz1: usize,
    n1: usize,
    has_charge: bool,

    threads: []std.Thread,
    started: bool,
    quit: std.atomic.Value(bool),
    epoch: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
    job_batches: []const Batch,
    job_own_planes: Planes,
    job_has_charge: bool,
    job_x: []const f64,
    job_t: f64,
    job_mode: Mode,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        batches: []const Batch,
        nnz: u32,
        n: u32,
        has_charge: bool,
        trash_slot: u32,
        n_lanes_req: u32,
    ) !ParEval {
        const n_lanes = @max(n_lanes_req, 1);
        const nnz1: usize = nnz + 1;
        const n1: usize = n + 1;
        const extra: usize = n_lanes - 1;

        var w_total: u64 = 0;
        for (batches) |b| w_total += @as(u64, b.count) * b.n_u * b.n_u;
        const target: u64 = (w_total + n_lanes - 1) / n_lanes;

        var lane_tasks = try gpa.alloc(std.ArrayList(EvalTask), n_lanes);
        defer {
            for (lane_tasks) |*lt| lt.deinit(gpa);
            gpa.free(lane_tasks);
        }
        for (lane_tasks) |*lt| lt.* = .empty;
        var loads = try gpa.alloc(u64, n_lanes);
        defer gpa.free(loads);
        @memset(loads, 0);

        for (batches, 0..) |b, bi| {
            if (b.thread_safe or b.count == 0) continue;
            try lane_tasks[0].append(gpa, .{ .batch = @intCast(bi), .first = 0, .last = b.count });
            loads[0] += @as(u64, b.count) * b.n_u * b.n_u;
        }
        var cur: u32 = 0;
        for (batches, 0..) |b, bi| {
            if (!b.thread_safe or b.count == 0) continue;
            const w: u64 = @as(u64, b.n_u) * b.n_u;
            var pos: u32 = 0;
            while (pos < b.count) {
                while (cur + 1 < n_lanes and loads[cur] >= target) cur += 1;
                const cap = if (loads[cur] >= target) b.count - pos else blk: {
                    const room = target - loads[cur];
                    break :blk @as(u32, @intCast(@min(@as(u64, b.count - pos), (room + w - 1) / w)));
                };
                const take = @max(cap, 1);
                try lane_tasks[cur].append(gpa, .{ .batch = @intCast(bi), .first = pos, .last = pos + take });
                loads[cur] += @as(u64, take) * w;
                pos += take;
            }
        }

        var tasks: std.ArrayList(EvalTask) = .empty;
        errdefer tasks.deinit(gpa);
        const task_off = try gpa.alloc(u32, n_lanes + 1);
        errdefer gpa.free(task_off);
        var off: u32 = 0;
        for (lane_tasks, 0..) |lt, l| {
            task_off[l] = off;
            try tasks.appendSlice(gpa, lt.items);
            off += @intCast(lt.items.len);
        }
        task_off[n_lanes] = off;

        const windows = try gpa.alloc(Window, extra);
        errdefer gpa.free(windows);
        for (windows, 1..) |*win, l| {
            win.* = .{ .slot_lo = @intCast(nnz1 - 1), .slot_hi = 0, .row_lo = @intCast(n1 - 1), .row_hi = 0 };
            for (tasks.items[task_off[l]..task_off[l + 1]]) |task| {
                const b = &batches[task.batch];
                const bounds = b.hooks.scatter_bounds(b.ctx, task.first, task.last, trash_slot, n);
                win.slot_lo = @min(win.slot_lo, bounds[0]);
                win.slot_hi = @max(win.slot_hi, bounds[1]);
                win.row_lo = @min(win.row_lo, bounds[2]);
                win.row_hi = @max(win.row_hi, bounds[3]);
            }
            if (win.slot_lo > win.slot_hi) win.slot_lo = win.slot_hi;
            if (win.row_lo > win.row_hi) win.row_lo = win.row_hi;
        }

        const g_slab = try gpa.alloc(f64, extra * nnz1);
        errdefer gpa.free(g_slab);
        const rhs_slab = try gpa.alloc(f64, extra * n1);
        errdefer gpa.free(rhs_slab);
        const c_slab = try gpa.alloc(f64, if (has_charge) extra * nnz1 else 0);
        errdefer gpa.free(c_slab);
        const q_slab = try gpa.alloc(f64, if (has_charge) extra * n1 else 0);
        errdefer gpa.free(q_slab);
        @memset(g_slab, 0);
        @memset(rhs_slab, 0);
        @memset(c_slab, 0);
        @memset(q_slab, 0);

        for (batches) |b| {
            if (b.hooks.set_lanes) |f| try f(b.ctx, gpa, n_lanes);
        }

        const threads = try gpa.alloc(std.Thread, extra);
        errdefer gpa.free(threads);

        return .{
            .io = io,
            .gpa = gpa,
            .n_lanes = n_lanes,
            .g_slab = g_slab,
            .c_slab = c_slab,
            .rhs_slab = rhs_slab,
            .q_slab = q_slab,
            .tasks = try tasks.toOwnedSlice(gpa),
            .task_off = task_off,
            .windows = windows,
            .nnz1 = nnz1,
            .n1 = n1,
            .has_charge = has_charge,
            .threads = threads,
            .started = false,
            .quit = .init(false),
            .epoch = .init(0),
            .done = .init(0),
            .job_batches = batches,
            .job_own_planes = undefined,
            .job_has_charge = has_charge,
            .job_x = &.{},
            .job_t = 0,
            .job_mode = .full,
        };
    }

    pub fn deinit(self: *ParEval) void {
        if (self.started) {
            self.quit.store(true, .release);
            _ = self.epoch.fetchAdd(1, .release);
            for (self.threads) |th| th.join();
        }
        const gpa = self.gpa;
        gpa.free(self.threads);
        gpa.free(self.g_slab);
        gpa.free(self.c_slab);
        gpa.free(self.rhs_slab);
        gpa.free(self.q_slab);
        gpa.free(self.tasks);
        gpa.free(self.task_off);
        gpa.free(self.windows);
        self.* = undefined;
    }

    pub fn eval(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, x: []const f64, t: f64) void {
        zeroSimd(own_planes.g_vals);
        if (has_charge) {
            zeroSimd(own_planes.c_vals);
            @memset(own_planes.q_vec, 0);
        }
        @memset(own_planes.rhs, 0);
        self.forkJoin(batches, own_planes, has_charge, x, t, .full);
    }

    pub fn evalNewton(
        self: *ParEval,
        batches: []const Batch,
        own_planes: Planes,
        has_charge: bool,
        has_baseline: bool,
        g_base: []const f64,
        c_base: []const f64,
        x: []const f64,
        t: f64,
    ) void {
        if (has_baseline) {
            @memcpy(own_planes.g_vals, g_base);
            if (has_charge) {
                @memcpy(own_planes.c_vals, c_base);
                @memset(own_planes.q_vec, 0);
            }
            @memset(own_planes.rhs, 0);
            self.forkJoin(batches, own_planes, has_charge, x, t, .newton);
        } else {
            zeroSimd(own_planes.g_vals);
            if (has_charge) {
                zeroSimd(own_planes.c_vals);
                @memset(own_planes.q_vec, 0);
            }
            @memset(own_planes.rhs, 0);
            self.forkJoin(batches, own_planes, has_charge, x, t, .full);
        }
    }

    fn forkJoin(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, x: []const f64, t: f64, mode: Mode) void {
        if (self.n_lanes == 1) {
            runLane(self, batches, own_planes, has_charge, 0, x, t, mode);
            return;
        }
        if (!self.started) self.startWorkers();
        self.job_batches = batches;
        self.job_own_planes = own_planes;
        self.job_has_charge = has_charge;
        self.job_x = x;
        self.job_t = t;
        self.job_mode = mode;
        self.done.store(0, .monotonic);
        _ = self.epoch.fetchAdd(1, .release);
        runLane(self, batches, own_planes, has_charge, 0, x, t, mode);
        var spins: u32 = 0;
        while (self.done.load(.acquire) < self.n_lanes - 1) {
            spins +%= 1;
            if (spins > 4096) std.Thread.yield() catch {};
        }
        self.reduce(own_planes, has_charge);
    }

    fn startWorkers(self: *ParEval) void {
        const epoch0 = self.epoch.load(.acquire);
        for (self.threads, 1..) |*th, lane| {
            th.* = std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, workerMain, .{ self, @as(u32, @intCast(lane)), epoch0 }) catch
                @panic("ParEval: worker spawn failed");
        }
        self.started = true;
    }

    fn workerMain(self: *ParEval, lane: u32, epoch0: u32) void {
        var last: u32 = epoch0;
        while (true) {
            var spins: u32 = 0;
            var e = self.epoch.load(.acquire);
            while (e == last) {
                spins +%= 1;
                if (spins > 4096) std.Thread.yield() catch {};
                e = self.epoch.load(.acquire);
            }
            last = e;
            if (self.quit.load(.acquire)) return;
            runLane(self, self.job_batches, self.job_own_planes, self.job_has_charge, lane, self.job_x, self.job_t, self.job_mode);
            _ = self.done.fetchAdd(1, .release);
        }
    }

    fn lanePlanes(self: *ParEval, own_planes: Planes, lane: u32) Planes {
        if (lane == 0) return own_planes;
        const e: usize = lane - 1;
        const g = self.g_slab[e * self.nnz1 ..][0..self.nnz1];
        const r = self.rhs_slab[e * self.n1 ..][0..self.n1];
        return .{
            .g_vals = g,
            .rhs = r,
            .c_vals = if (self.has_charge) self.c_slab[e * self.nnz1 ..][0..self.nnz1] else g,
            .q_vec = if (self.has_charge) self.q_slab[e * self.n1 ..][0..self.n1] else r,
        };
    }

    fn runLane(self: *ParEval, batches: []const Batch, own_planes: Planes, has_charge: bool, lane: u32, x: []const f64, t: f64, mode: Mode) void {
        const pl = self.lanePlanes(own_planes, lane);
        if (lane != 0) {
            const win = self.windows[lane - 1];
            zeroSimd(pl.g_vals[win.slot_lo..win.slot_hi]);
            zeroSimd(pl.rhs[win.row_lo..win.row_hi]);
            pl.g_vals[self.nnz1 - 1] = 0;
            pl.rhs[self.n1 - 1] = 0;
            if (has_charge) {
                zeroSimd(pl.c_vals[win.slot_lo..win.slot_hi]);
                zeroSimd(pl.q_vec[win.row_lo..win.row_hi]);
                pl.c_vals[self.nnz1 - 1] = 0;
                pl.q_vec[self.n1 - 1] = 0;
            }
        }
        for (self.tasks[self.task_off[lane]..self.task_off[lane + 1]]) |task| {
            const b = &batches[task.batch];
            switch (mode) {
                .full => b.eval(b.ctx, &pl, lane, task.first, task.last, x, t),
                .newton => b.eval_newton(b.ctx, &pl, lane, task.first, task.last, x, t),
            }
        }
    }

    fn reduce(self: *ParEval, own_planes: Planes, has_charge: bool) void {
        var l: u32 = 1;
        while (l < self.n_lanes) : (l += 1) {
            const e: usize = l - 1;
            const win = self.windows[e];
            addSimd(
                own_planes.g_vals[win.slot_lo..win.slot_hi],
                self.g_slab[e * self.nnz1 + win.slot_lo .. e * self.nnz1 + win.slot_hi],
            );
            addSimd(
                own_planes.rhs[win.row_lo..win.row_hi],
                self.rhs_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
            );
            if (has_charge) {
                addSimd(
                    own_planes.c_vals[win.slot_lo..win.slot_hi],
                    self.c_slab[e * self.nnz1 + win.slot_lo .. e * self.nnz1 + win.slot_hi],
                );
                addSimd(
                    own_planes.q_vec[win.row_lo..win.row_hi],
                    self.q_slab[e * self.n1 + win.row_lo .. e * self.n1 + win.row_hi],
                );
            }
        }
    }
};

const vec_width = std.simd.suggestVectorLength(f64) orelse 4;

fn zeroSimd(buf: []f64) void {
    const W = vec_width;
    const Vv = @Vector(W, f64);
    const zero: Vv = @splat(0.0);
    var i: usize = 0;
    while (i + W <= buf.len) : (i += W) buf[i..][0..W].* = zero;
    for (buf[i..]) |*v| v.* = 0;
}

fn addSimd(dst: []f64, src: []const f64) void {
    const W = vec_width;
    const Vv = @Vector(W, f64);
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) {
        const d: Vv = dst[i..][0..W].*;
        const s: Vv = src[i..][0..W].*;
        dst[i..][0..W].* = d + s;
    }
    while (i < dst.len) : (i += 1) dst[i] += src[i];
}

// ===========================================================================
// Runtime device ABI (dlopen'd .so). Crosses the boundary PER BATCH: the .so
// compiles this same ProtoStore(D)/DeviceBatch(D) and hands back the same
// type-erased Proto the builtin path uses. layoutHash() guards ABI drift.
// ===========================================================================

// Bumped 4 -> 5 for the `derive` slot below: `DeviceVtable` grew a field, and a
// `.so` built against version 4 returns a pointer to its own shorter struct, so
// reading the new field off it is UB. The check in `DynDevice.open` is what makes
// the bump load-bearing rather than decorative.
pub const abi_version: u32 = 5;

pub const DeviceVtable = struct {
    name: []const u8,
    n_u: u32,
    num_ports: u32,
    model_size: usize,
    instance_size: usize,
    init_model: *const fn ([*]u8) void,
    init_instance: *const fn ([*]u8) void,
    set_model_param: *const fn ([*]u8, []const u8, f64) bool,
    set_instance_param: *const fn ([*]u8, []const u8, f64) bool,
    /// LRM 6.3.4 / 3.4.5: a parameter whose value is an expression over OTHER
    /// parameters, plus every localparam. The Model is a flat struct, so a host
    /// write to a base parameter cannot reach what was declared over it — the
    /// device closes that gap here, and the contract requires the host to call it
    /// once after the last `set_model_param` and before anything READS the model.
    /// Null when the module has no such parameter, which is the common case.
    derive: ?*const fn (model: [*]u8) void,
    collapse: ?*const fn (model: [*]const u8, instance: [*]const u8, out: [*]i32) void,
    proto_create: *const fn (std.mem.Allocator) anyerror!Proto,
    proto_add: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) anyerror!void,

    // GPU eval kernel this device emitted from `engine.DeviceKernel` at
    // `.so`-build-time (empty ⇒ CPU-only). The `.so` compiles the SAME template
    // the builtins use, so the format matches; the app links it into its gompute
    // context by `gpu_kernel_name`. Populated by the compileGenerated shim
    // (dynamic devices); empty for the in-process vtable (builtins bake their
    // kernels via kernels.zig instead).
    gpu_kernel_name: []const u8 = "",
    gpu_ptx: []const u8 = "", // NVIDIA cubin/PTX image
    gpu_amdgcn: []const u8 = "", // AMD code object
};

/// Layout guard over every type that crosses the boundary + the compiler
/// version. Both sides compile this same source; equal hashes ⇒ compatible.
pub fn layoutHash() u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var h: u64 = 0xcbf29ce484222325;
        for (builtin.zig_version_string) |c| h = mix(h, c);
        h = mix(h, @intFromEnum(builtin.zig_backend));
        h = mix(h, @intFromEnum(builtin.mode));
        for ([_]type{
            DeviceVtable, Proto,          Batch,
            Hooks,        Planes,         PatternView,
            PatternBuilder, ParamRef,     NoiseSource,
            std.mem.Allocator,
        }) |T| h = hashType(h, T);
        break :blk h;
    };
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

fn hashType(h0: u64, comptime T: type) u64 {
    var h = mix(mix(h0, @sizeOf(T)), @alignOf(T));
    switch (@typeInfo(T)) {
        .@"struct" => |si| inline for (si.fields) |f| {
            if (!f.is_comptime and @sizeOf(f.type) > 0) h = mix(h, @offsetOf(T, f.name));
        },
        else => {},
    }
    return h;
}

// ===========================================================================
// The host half of the contract (CONSUMING §4.2)
// ===========================================================================

/// This simulator's VPI application, and it deliberately has no `systf`.
///
/// §2.8.3 lets a `.va` call a `$name` no compiler defines, to be supplied
/// through §12.32 `vpi_register_analog_systf`. ESPice registers none, so the
/// right answer is to say so ONCE, in a type, and let `validateHost` turn a
/// model that needs one into a build error naming the function — instead of a
/// null `Instance.systf` reached at the first Newton step, or worse a value
/// invented out of thin air inside the residual.
///
/// A named empty struct rather than `DeviceBatch(D)`: `validateHost` only ever
/// looks for a `systf` decl, and routing the check through the batch type would
/// instantiate every model's SoA store at comptime just to ask that question.
///
/// ponytail: no VPI application until a model wants one. The day `checkHost`
/// errors, declare `pub fn systf(*const Model) ?*const contract.SystfHost` here
/// and fill EVERY partial (§12.22.1) — a slot left alone is a derivative
/// claimed and not computed.
pub const VpiHost = struct {};

/// Assert this host can supply everything `D` calls. A no-op for a device that
/// names no `$systf`, so every device site carries it unconditionally.
///
/// `contract.validate(D)` cannot ask this: it runs where the DEVICE is defined,
/// and a `.va` compiled to a `.so` does not know which simulator loads it. The
/// requirement only exists where the two meet — here.
pub fn checkHost(comptime D: type) void {
    contract.validateHost(VpiHost, D);
}

/// Export a contract-shaped device under the runtime ABI. The generated shim
/// is one line: `comptime { engine.exportDevice(@import("device"), "name"); }`.
pub fn exportDevice(comptime D: type, comptime device_name: []const u8) void {
    // The dynamic half. Builtins are checked over the catalog in root.zig;
    // this covers the `.so`, which root.zig never sees.
    comptime checkHost(D);
    const impl = Impl(D, device_name);
    @export(&impl.abiVersion, .{ .name = "arp_abi_version" });
    @export(&impl.layoutHashC, .{ .name = "arp_layout_hash" });
    @export(&impl.getVtable, .{ .name = "arp_device" });
}

/// In-process vtable (tests, embedding without dlopen).
pub fn deviceVtable(comptime D: type, comptime device_name: []const u8) *const DeviceVtable {
    return &Impl(D, device_name).vtable;
}

fn Impl(comptime D: type, comptime device_name: []const u8) type {
    return struct {
        const Store = ProtoStore(D);
        const n_u = @typeInfo(D.U).@"enum".fields.len;

        fn abiVersion() callconv(.c) u32 {
            return abi_version;
        }
        fn layoutHashC() callconv(.c) u64 {
            return layoutHash();
        }
        fn getVtable() callconv(.c) *const DeviceVtable {
            return &vtable;
        }

        const vtable: DeviceVtable = .{
            .name = device_name,
            .n_u = n_u,
            .num_ports = D.num_ports,
            .model_size = @sizeOf(D.Model),
            .instance_size = @sizeOf(D.Instance),
            .init_model = initBlob(D.Model),
            .init_instance = initBlob(D.Instance),
            .set_model_param = setParam(D.Model),
            .set_instance_param = setParam(D.Instance),
            .derive = if (@hasDecl(D, "derive")) deriveFn else null,
            .collapse = if (@hasDecl(D, "collapse")) collapseFn else null,
            .proto_create = protoCreate,
            .proto_add = protoAdd,
        };

        fn initBlob(comptime T: type) *const fn ([*]u8) void {
            return struct {
                fn f(dest: [*]u8) void {
                    const p: *T = @ptrCast(@alignCast(dest));
                    p.* = .{};
                }
            }.f;
        }

        fn setParam(comptime T: type) *const fn ([*]u8, []const u8, f64) bool {
            return struct {
                fn f(dest: [*]u8, param: []const u8, value: f64) bool {
                    @setEvalBranchQuota(10_000);
                    const p: *T = @ptrCast(@alignCast(dest));
                    inline for (@typeInfo(T).@"struct".fields) |field| {
                        switch (@typeInfo(field.type)) {
                            .float => if (std.ascii.eqlIgnoreCase(param, field.name)) {
                                @field(p, field.name) = @floatCast(value);
                                return true;
                            },
                            .int => if (std.ascii.eqlIgnoreCase(param, field.name)) {
                                @field(p, field.name) = @intFromFloat(value);
                                return true;
                            },
                            .bool => if (std.ascii.eqlIgnoreCase(param, field.name)) {
                                @field(p, field.name) = value != 0;
                                return true;
                            },
                            else => {},
                        }
                    }
                    return false;
                }
            }.f;
        }

        fn deriveFn(model: [*]u8) void {
            const m: *D.Model = @ptrCast(@alignCast(model));
            D.derive(m);
        }

        fn collapseFn(model: [*]const u8, instance: [*]const u8, out: [*]i32) void {
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            const col = D.collapse(m, i);
            inline for (D.num_ports..n_u) |u|
                out[u] = if (col[u]) |p| @intCast(p) else -1;
        }

        fn protoCreate(gpa: std.mem.Allocator) anyerror!Proto {
            const store = try gpa.create(Store);
            store.* = .{};
            return .{
                .ctx = store,
                .type_name = device_name,
                .pattern = Store.addPattern,
                .finalize = Store.finalize,
                .destroy = Store.destroy,
                .apply_perm = Store.applyPerm,
            };
        }

        fn protoAdd(ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) anyerror!void {
            const store: *Store = @ptrCast(@alignCast(ctx));
            const m: *const D.Model = @ptrCast(@alignCast(model));
            const i: *const D.Instance = @ptrCast(@alignCast(instance));
            try store.models.append(gpa, m.*);
            try store.instances.append(gpa, i.*);
            try store.nodes.append(gpa, nodes[0..n_u].*);
        }
    };
}

pub const LoadedDevice = struct {
    lib: std.DynLib,
    vt: *const DeviceVtable,

    pub fn open(path: []const u8) !LoadedDevice {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        const u32_fn = *const fn () callconv(.c) u32;
        const u64_fn = *const fn () callconv(.c) u64;
        const ver = lib.lookup(u32_fn, "arp_abi_version") orelse return error.NotArpDevice;
        if (ver() != abi_version) return error.WrongAbiVersion;
        const lh = lib.lookup(u64_fn, "arp_layout_hash") orelse return error.NotArpDevice;
        if (lh() != layoutHash()) return error.LayoutMismatch;

        const get_vt = lib.lookup(*const fn () callconv(.c) *const DeviceVtable, "arp_device") orelse
            return error.NotArpDevice;
        return .{ .lib = lib, .vt = get_vt() };
    }

    pub fn close(self: *LoadedDevice) void {
        self.lib.close();
        self.* = undefined;
    }
};

test "Dual: an f32 Jacobian leaves the residual bit-identical" {
    // The one invariant the whole mixed-precision construction rests on
    // (docs/gpu-device-eval.md §9): `F` is the width of the DERIVATIVE, and the
    // residual is f64 on both instantiations. Not a tolerance — every operation
    // on `.v` is the same f64 arithmetic, so the values must be EQUAL. If this
    // ever needs a tolerance, the split has leaked into the residual.
    const core = struct {
        // The diode's own core, which is what the prototype ships:
        // is·(exp(v/vt) − 1) + gmin·v.
        fn f(comptime S: type, bias: f64) S {
            const x = [2]S{ S.seed(bias, 0), S.seed(0, 1) };
            const v = x[0].sub(x[1]);
            return S.con(1e-14).mul(v.div(S.con(0.025851999786450736)).exp().addC(-1.0))
                .add(v.scale(1e-12));
        }
    }.f;
    for (0..17) |i| {
        const bias = @as(f64, @floatFromInt(i)) * 0.05;
        const a = core(Dual(2, f64), bias);
        const b = core(Dual(2, f32), bias);
        try std.testing.expectEqual(a.val(), b.val());
        // …and the Jacobian degrades to f32 precision, and only to that.
        for (0..2) |c| try std.testing.expectApproxEqRel(a.ddxAt(c), b.ddxAt(c), 1e-6);
    }
}

test "dyn vtable: blob init, param set by name, proto add" {
    const R = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct { r: f32 = 1000 };
        pub const Instance = struct { temp: f32 = 300.15 };
        pub fn eval(comptime Sc: type, x: [2]Sc, m: *const Model, _: *const Instance, _: f64) [2]Sc {
            const i = x[0].sub(x[1]).scale(1.0 / @as(f64, m.r));
            return .{ i, i.neg() };
        }
    };
    const testing = std.testing;
    const vt = deviceVtable(R, "tres");
    try testing.expectEqual(@as(u32, 2), vt.n_u);
    try testing.expectEqual(@sizeOf(R.Model), vt.model_size);

    var mblob: [@sizeOf(R.Model)]u8 align(16) = undefined;
    vt.init_model(&mblob);
    try testing.expect(vt.set_model_param(&mblob, "r", 42));
    try testing.expect(!vt.set_model_param(&mblob, "bogus", 1));
    const m: *R.Model = @ptrCast(@alignCast(&mblob));
    try testing.expectEqual(@as(f32, 42), m.r);

    var iblob: [@sizeOf(R.Instance)]u8 align(16) = undefined;
    vt.init_instance(&iblob);

    const proto = try vt.proto_create(testing.allocator);
    const nodes = [2]u32{ 1, 2 };
    try vt.proto_add(proto.ctx, testing.allocator, &mblob, &iblob, &nodes);
    const store: *ProtoStore(R) = @ptrCast(@alignCast(proto.ctx));
    try testing.expectEqual(@as(usize, 1), store.models.items.len);
    try testing.expectEqual(@as(f32, 42), store.models.items[0].r);
    proto.destroy(proto.ctx, testing.allocator);
}
