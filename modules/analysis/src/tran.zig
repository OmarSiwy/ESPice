//! Transient: Newton per timestep on A = G + alpha*C (one axpy over nnz).
//! The companion residual uses the exact q(x) plane; the companion Jacobian
//! is the analytic C plane — nothing is lagged, nothing is dense.
const std = @import("std");
const root = @import("root.zig");
const newton = @import("newton.zig");

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;

pub const Method = enum {
    backward_euler,
    trapezoidal,
};

// ---------------------------------------------------------------------------
// Integration methods: dynamic-residual coefficient, LTE estimate, timestep
// control. Internal to transient — only simulate() below drives these.
// ---------------------------------------------------------------------------
const integrator = struct {
    /// Dynamic-residual coefficient. The residual stamped per node is
    ///   BE:   F_dyn = (1/dt)*(q(x) - q_prev)
    ///   trap: F_dyn = (2/dt)*(q(x) - q_prev) - i_prev
    /// with i_prev the dynamic current of the previous accepted step.
    fn alpha(method: Method, dt: f64) f64 {
        return switch (method) {
            .backward_euler => 1.0 / dt,
            .trapezoidal => 2.0 / dt,
        };
    }

    /// Local truncation error estimate via divided differences of the charge
    /// history. Returns max relative LTE across charge variables.
    ///   BE:   |dt^2/2 * q''|,  q''  ~ 2*f[t0,t1,t2]
    ///   trap: |dt^3/12 * q'''|, q''' ~ 6*f[t0,t1,t2,t3]
    /// q_cur at t, q_prev at t-dt, q_prev2 at t-dt-dt1, q_prev3 at t-dt-dt1-dt2.
    /// q_prev3/dt2 are only read for trapezoidal.
    fn estimateLTE(
        method: Method,
        q_cur: []const f64,
        q_prev: []const f64,
        q_prev2: []const f64,
        q_prev3: []const f64,
        dt: f64,
        dt1: f64,
        dt2: f64,
    ) f64 {
        const V = @Vector(W, f64);
        const inv_dt: V = @splat(1.0 / dt);
        const inv_dt1: V = @splat(1.0 / dt1);
        const inv_sum01: V = @splat(1.0 / (dt + dt1));
        const floor: V = @splat(1e-15);
        var vmax: V = @splat(0.0);
        var i: usize = 0;

        if (method == .trapezoidal) {
            const inv_dt2: V = @splat(1.0 / dt2);
            const inv_sum12: V = @splat(1.0 / (dt1 + dt2));
            const inv_sum012: V = @splat(1.0 / (dt + dt1 + dt2));
            const coeff: V = @splat(0.5 * dt * dt * dt);
            while (i + W <= q_cur.len) : (i += W) {
                const qc: V = q_cur[i..][0..W].*;
                const qp: V = q_prev[i..][0..W].*;
                const qp2: V = q_prev2[i..][0..W].*;
                const qp3: V = q_prev3[i..][0..W].*;
                const f01 = (qc - qp) * inv_dt;
                const f12 = (qp - qp2) * inv_dt1;
                const f23 = (qp2 - qp3) * inv_dt2;
                const f012 = (f01 - f12) * inv_sum01;
                const f123 = (f12 - f23) * inv_sum12;
                const f0123 = (f012 - f123) * inv_sum012;
                const lte = coeff * @abs(f0123);
                const scale = @max(@abs(qc), floor);
                vmax = @max(vmax, lte / scale);
            }
        } else {
            const coeff: V = @splat(dt * dt);
            while (i + W <= q_cur.len) : (i += W) {
                const qc: V = q_cur[i..][0..W].*;
                const qp: V = q_prev[i..][0..W].*;
                const qp2: V = q_prev2[i..][0..W].*;
                const f01 = (qc - qp) * inv_dt;
                const f12 = (qp - qp2) * inv_dt1;
                const f012 = (f01 - f12) * inv_sum01;
                const lte = coeff * @abs(f012);
                const scale = @max(@abs(qc), floor);
                vmax = @max(vmax, lte / scale);
            }
        }
        var max_lte = @reduce(.Max, vmax);
        // Scalar tail
        while (i < q_cur.len) : (i += 1) {
            const f01 = (q_cur[i] - q_prev[i]) / dt;
            const f12 = (q_prev[i] - q_prev2[i]) / dt1;
            const f012 = (f01 - f12) / (dt + dt1);
            const lte = switch (method) {
                .backward_euler => dt * dt * @abs(f012),
                .trapezoidal => blk: {
                    const f23 = (q_prev2[i] - q_prev3[i]) / dt2;
                    const f123 = (f12 - f23) / (dt1 + dt2);
                    const f0123 = (f012 - f123) / (dt + dt1 + dt2);
                    break :blk 0.5 * dt * dt * dt * @abs(f0123);
                },
            };
            const scale = @max(@abs(q_cur[i]), 1e-15);
            max_lte = @max(max_lte, lte / scale);
        }
        return max_lte;
    }

    /// Compute new timestep from LTE estimate.
    /// Returns proposed dt, clamped to [dt_min, dt_max].
    fn adaptTimestep(
        method: Method,
        lte: f64,
        lte_tol: f64,
        dt: f64,
        dt_min: f64,
        dt_max: f64,
    ) f64 {
        if (lte < 1e-30) return @min(dt * 2.0, dt_max);

        const order: f64 = switch (method) {
            .backward_euler => 1.0,
            .trapezoidal => 2.0,
        };

        const ratio = lte_tol / lte;
        const factor = @min(2.0, 0.9 * std.math.pow(f64, ratio, 1.0 / (order + 1.0)));
        const new_dt = dt * factor;

        return @max(dt_min, @min(new_dt, dt_max));
    }
};

pub const Options = struct {
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    dt_max: f64 = 1e-3,
    max_newton_iter: u16 = 50,
    newton_tol: f64 = 1e-9,
    /// Relative LTE bound per accepted step (charge-storage circuits only).
    lte_tol: f64 = 1e-3,
    /// Diagonal regularization, matching dc.zig's gmin floor.
    gmin: f64 = 1e-12,
    method: Method = .trapezoidal,
    max_steps: u32 = 1_000_000,
    /// Invoked after each accepted step (envelope/pnoise/pac build on this).
    step_fn: ?*const fn (ctx: ?*anyopaque, t: f64, x: []const f64) void = null,
    step_ctx: ?*anyopaque = null,
};

/// Waveform capacity heuristic: adaptive dt makes the point count unknown up
/// front, so start generously from t_stop/dt_init and clamp to 4M points.
pub fn initialCapacity(options: Options) u32 {
    const est = 16.0 * options.t_stop / options.dt_init;
    return @intFromFloat(@min(@max(1024.0, est), @as(f64, 1 << 22)));
}

/// Recorded transient waveform. Flat preallocated storage, probe-major:
/// values[k * capacity + i] is probe k at point i — probeValues(k) is one
/// contiguous slice (what four.zig / meas.zig consume).
pub const Waveform = struct {
    times: []f64,
    values: []f64, // n_probes * capacity, probe-major
    len: u32,
    capacity: u32,
    n_probes: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n_probes: u32, capacity: u32) !Waveform {
        const cap: u32 = @max(capacity, 1);
        const times = try allocator.alloc(f64, cap);
        errdefer allocator.free(times);
        const values = try allocator.alloc(f64, @as(usize, n_probes) * cap);
        return .{
            .times = times,
            .values = values,
            .len = 0,
            .capacity = cap,
            .n_probes = n_probes,
            .allocator = allocator,
        };
    }

    pub fn record(self: *Waveform, t: f64, x: []const f64, probes: []const u32) !void {
        if (self.len == self.capacity) try self.grow();
        self.times[self.len] = t;
        const cap: usize = self.capacity;
        for (probes, 0..) |node, k| self.values[k * cap + self.len] = x[node];
        self.len += 1;
    }

    pub fn timeSlice(self: *const Waveform) []const f64 {
        return self.times[0..self.len];
    }

    pub fn probeValues(self: *const Waveform, k: u32) []const f64 {
        return self.values[@as(usize, k) * self.capacity ..][0..self.len];
    }

    // ponytail: doubling fallback, capacity heuristic covers normal runs
    fn grow(self: *Waveform) !void {
        const old_cap: usize = self.capacity;
        const new_cap = old_cap * 2;
        const times_new = try self.allocator.alloc(f64, new_cap);
        errdefer self.allocator.free(times_new);
        const values_new = try self.allocator.alloc(f64, @as(usize, self.n_probes) * new_cap);
        @memcpy(times_new[0..self.len], self.times[0..self.len]);
        for (0..self.n_probes) |k| {
            @memcpy(
                values_new[k * new_cap ..][0..self.len],
                self.values[k * old_cap ..][0..self.len],
            );
        }
        self.allocator.free(self.times);
        self.allocator.free(self.values);
        self.times = times_new;
        self.values = values_new;
        self.capacity = @intCast(new_cap);
    }

    pub fn deinit(self: *Waveform) void {
        self.allocator.free(self.times);
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub const SimResult = struct {
    completed: bool,
    steps: u32,
    t_final: f64,
};

/// Newton hook: companion RHS from the q plane, matrix = G + alpha*C.
const TranHook = struct {
    alpha: f64,
    q_prev: []const f64,
    i_prev: ?[]const f64, // trap only
    a_vals: []f64,
    q_snap: ?[]f64, // captures q(x) from last converged Newton iter for LTE
    has_charge: bool,
    has_history: bool,

    pub fn assemble(self: TranHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        // q_vec now holds q(x) for this iteration — cache pointer for LTE.
        if (self.q_snap) |snap| @memcpy(snap, ckt.q_vec[0..ckt.n]);
        if (self.has_charge) {
            const n: usize = ckt.n;
            const V = @Vector(W, f64);
            const av: V = @splat(self.alpha);
            var i: usize = 0;
            if (self.i_prev) |ipv| {
                while (i + W <= n) : (i += W) {
                    const r: V = ckt.rhs[i..][0..W].*;
                    const qv: V = ckt.q_vec[i..][0..W].*;
                    const qp: V = self.q_prev[i..][0..W].*;
                    const ip: V = ipv[i..][0..W].*;
                    ckt.rhs[i..][0..W].* = r + av * (qv - qp) - ip;
                }
                while (i < n) : (i += 1)
                    ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]) - ipv[i];
            } else {
                while (i + W <= n) : (i += W) {
                    const r: V = ckt.rhs[i..][0..W].*;
                    const qv: V = ckt.q_vec[i..][0..W].*;
                    const qp: V = self.q_prev[i..][0..W].*;
                    ckt.rhs[i..][0..W].* = r + av * (qv - qp);
                }
                while (i < n) : (i += 1)
                    ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]);
            }
        }
        if (self.has_history) ckt.injectHistory(t);
    }

    pub fn vals(self: TranHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
    }
};

/// Fine-grained primitive: integrate into caller-owned x and waveform.
/// four/pss/envelope/tran_noise all drive this.
pub fn simulate(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    waveform: *Waveform,
    options: Options,
    allocator: std.mem.Allocator,
) !SimResult {
    const n: usize = ckt.n;
    const has_charge = ckt.has_charge;
    const has_history = ckt.has_history;
    const trap = options.method == .trapezoidal;

    var ws = try newton.Workspace.init(allocator, ckt);
    defer ws.deinit(allocator);
    const x_try = try allocator.alloc(f64, n);
    defer allocator.free(x_try);

    // Charge state: dynamic current i_prev and a charge-history ring
    // [cur, prev, prev2, prev3] for the companion residual + trap LTE.
    var a_vals: []f64 = &.{};
    var i_prev: []f64 = &.{};
    var q_snap: []f64 = &.{};
    var q_hist: [4][]f64 = .{ &.{}, &.{}, &.{}, &.{} };
    defer if (has_charge) {
        allocator.free(a_vals);
        allocator.free(i_prev);
        allocator.free(q_snap);
        for (q_hist) |q| allocator.free(q);
    };
    try ckt.computeBaseline();

    if (has_charge) {
        a_vals = try allocator.alloc(f64, ckt.nnz);
        i_prev = try allocator.alloc(f64, n);
        q_snap = try allocator.alloc(f64, n);
        @memset(i_prev, 0);
        for (&q_hist) |*q| q.* = try allocator.alloc(f64, n);
        ckt.eval(x, 0);
        @memcpy(q_hist[1], ckt.q_vec[0..n]); // q_prev at t=0
    }
    var q_levels: u2 = 0; // valid history levels beyond q_prev
    var dt_prev: f64 = 0;
    var dt_prev2: f64 = 0;

    if (has_history) ckt.recordHistory(x, 0);

    // Clamp dt_max to minimum delay for history-aware timestep control
    var effective_dt_max = options.dt_max;
    if (ckt.minDelay()) |td_min| effective_dt_max = @min(effective_dt_max, td_min);

    try waveform.record(0, x, probes);

    var cur: []f64 = x;
    var trial: []f64 = x_try;
    var t: f64 = 0;
    var dt: f64 = options.dt_init;
    var steps: u32 = 0;

    while (t < options.t_stop and steps < options.max_steps) {
        const alpha = integrator.alpha(options.method, dt);
        const hook = TranHook{
            .alpha = alpha,
            .q_prev = q_hist[1],
            .i_prev = if (trap and has_charge) i_prev else null,
            .a_vals = a_vals,
            .q_snap = if (has_charge) q_snap else null,
            .has_charge = has_charge,
            .has_history = has_history,
        };

        @memcpy(trial, cur);
        const nr = newton.solve(ckt, &ws.slv, trial, ws.dx, ws.x_old, t + dt, .{
            .max_iter = options.max_newton_iter,
            .abstol = options.newton_tol,
            .gmin = options.gmin,
            .dx_clamp = std.math.inf(f64),
        }, hook) catch newton.Result{ .converged = false, .iterations = 0, .max_dx = 0 };

        if (!nr.converged) {
            dt *= 0.5;
            if (dt < options.dt_min) return .{ .completed = false, .steps = steps, .t_final = t };
            continue;
        }

        var dt_next = @min(dt * 1.5, effective_dt_max);

        if (has_charge) {
            // q_snap was captured from the last Newton iteration's evalNewton.
            // No re-eval needed — q(x_converged) is already there.
            @memcpy(q_hist[0], q_snap);

            const need: u2 = if (trap) 2 else 1;
            if (q_levels >= need) {
                const lte = integrator.estimateLTE(options.method, q_hist[0], q_hist[1], q_hist[2], q_hist[3], dt, dt_prev, dt_prev2);
                if (lte > options.lte_tol) {
                    dt *= 0.5;
                    if (dt < options.dt_min) return .{ .completed = false, .steps = steps, .t_final = t };
                    continue;
                }
                dt_next = integrator.adaptTimestep(options.method, lte, options.lte_tol, dt, options.dt_min, effective_dt_max);
            }

            // Accept: dynamic current (SIMD), then rotate charge history ring.
            const V = @Vector(W, f64);
            const av: V = @splat(alpha);
            var j: usize = 0;
            if (trap) {
                while (j + W <= n) : (j += W) {
                    const q0: V = q_hist[0][j..][0..W].*;
                    const q1: V = q_hist[1][j..][0..W].*;
                    const ip: V = i_prev[j..][0..W].*;
                    i_prev[j..][0..W].* = av * (q0 - q1) - ip;
                }
                while (j < n) : (j += 1) i_prev[j] = alpha * (q_hist[0][j] - q_hist[1][j]) - i_prev[j];
            } else {
                while (j + W <= n) : (j += W) {
                    const q0: V = q_hist[0][j..][0..W].*;
                    const q1: V = q_hist[1][j..][0..W].*;
                    i_prev[j..][0..W].* = av * (q0 - q1);
                }
                while (j < n) : (j += 1) i_prev[j] = alpha * (q_hist[0][j] - q_hist[1][j]);
            }
            const tail = q_hist[3];
            q_hist[3] = q_hist[2];
            q_hist[2] = q_hist[1];
            q_hist[1] = q_hist[0];
            q_hist[0] = tail;
            dt_prev2 = dt_prev;
            dt_prev = dt;
            if (q_levels < 2) q_levels += 1;
        }

        // ponytail: pointer swap instead of memcpy on accept
        const tmp = cur;
        cur = trial;
        trial = tmp;
        t += dt;
        steps += 1;

        if (has_history) ckt.recordHistory(cur, t);

        try waveform.record(t, cur, probes);
        if (options.step_fn) |f| f(options.step_ctx, t, cur);

        dt = dt_next;
        if (t + dt > options.t_stop) dt = options.t_stop - t;
    }

    // Ensure caller's buffer has the final result
    if (cur.ptr != x.ptr) @memcpy(x, cur);
    return .{ .completed = t >= options.t_stop, .steps = steps, .t_final = t };
}

/// Contract entry: integrate from the operating point and format the
/// waveform point-major: (time, probes...) per row.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const x = try a.dupe(f64, x_op);
    defer a.free(x);

    var wf = try Waveform.init(a, @intCast(ctx.probes.len), initialCapacity(opts));
    defer wf.deinit();
    // Early stop keeps the partial waveform, matching the old engine.
    _ = try simulate(ctx.circuit, x, ctx.probes, &wf, opts, a);

    const names = try root.probeNames(ctx, "time");
    const ncols = names.len;
    const npoints: usize = wf.len;
    const data = try a.alloc(f64, npoints * ncols);
    const times = wf.timeSlice();
    for (0..npoints) |p| {
        const row = data[p * ncols ..][0..ncols];
        row[0] = times[p];
        for (0..ctx.probes.len) |idx| row[idx + 1] = wf.probeValues(@intCast(idx))[p];
    }

    return .{
        .plotname = "Transient Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;
test "waveform: doubling fallback keeps probe-major data intact" {
    const allocator = testing.allocator;
    var waveform = try Waveform.init(allocator, 2, 2);
    defer waveform.deinit();

    const probes = [_]u32{ 0, 1 };
    for (0..10) |i| {
        const fi: f64 = @floatFromInt(i);
        const x = [_]f64{ fi, 100.0 + fi };
        try waveform.record(fi * 1e-9, &x, &probes);
    }

    try testing.expectEqual(@as(u32, 10), waveform.len);
    try testing.expect(waveform.capacity >= 10);
    for (0..10) |i| {
        const fi: f64 = @floatFromInt(i);
        try testing.expectApproxEqAbs(fi * 1e-9, waveform.timeSlice()[i], 1e-24);
        try testing.expectApproxEqAbs(fi, waveform.probeValues(0)[i], 1e-15);
        try testing.expectApproxEqAbs(100.0 + fi, waveform.probeValues(1)[i], 1e-15);
    }
}

test "alpha: BE 1/dt, trap 2/dt" {
    try std.testing.expectApproxEqRel(@as(f64, 1e9), integrator.alpha(.backward_euler, 1e-9), 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 2e9), integrator.alpha(.trapezoidal, 1e-9), 1e-12);
}

test "estimateLTE: trap exact for cubic charge" {
    // q(t) = t^3, uniform dt: q''' = 6, LTE = dt^3/12 * 6 = dt^3/2.
    const dt = 0.1;
    const t = 1.0;
    const q0 = [1]f64{(t) * (t) * (t)};
    const q1 = [1]f64{(t - dt) * (t - dt) * (t - dt)};
    const q2 = [1]f64{(t - 2 * dt) * (t - 2 * dt) * (t - 2 * dt)};
    const q3 = [1]f64{(t - 3 * dt) * (t - 3 * dt) * (t - 3 * dt)};
    const lte = integrator.estimateLTE(.trapezoidal, &q0, &q1, &q2, &q3, dt, dt, dt);
    try std.testing.expectApproxEqRel(0.5 * dt * dt * dt / q0[0], lte, 1e-9);
}

test "estimateLTE: trap zero for quadratic charge" {
    const dt = 0.1;
    const t = 1.0;
    const q0 = [1]f64{t * t};
    const q1 = [1]f64{(t - dt) * (t - dt)};
    const q2 = [1]f64{(t - 2 * dt) * (t - 2 * dt)};
    const q3 = [1]f64{(t - 3 * dt) * (t - 3 * dt)};
    const lte = integrator.estimateLTE(.trapezoidal, &q0, &q1, &q2, &q3, dt, dt, dt);
    try std.testing.expect(lte < 1e-12);
}

test "adaptTimestep: grows when LTE is small" {
    const new_dt = integrator.adaptTimestep(.trapezoidal, 1e-15, 1e-6, 1e-9, 1e-15, 1e-3);
    try std.testing.expect(new_dt > 1e-9);
}

test "adaptTimestep: shrinks when LTE is large" {
    const new_dt = integrator.adaptTimestep(.trapezoidal, 1e-3, 1e-6, 1e-9, 1e-15, 1e-3);
    try std.testing.expect(new_dt < 1e-9);
}
