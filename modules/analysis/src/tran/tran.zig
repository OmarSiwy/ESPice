//! Transient: Newton per timestep on A = G + alpha*C (one axpy over nnz).
//! The companion residual uses the exact q(x) plane; the companion Jacobian
//! is the analytic C plane — nothing is lagged, nothing is dense.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;

pub const Method = enum {
    backward_euler,
    trapezoidal,
    gear_2,
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
            .gear_2 => 3.0 / (2.0 * dt),
        };
    }

    /// ngspice CKTterr: per-state timestep bound, in seconds. For each
    /// charge state j (tolerance in CURRENT units, cktterr.c):
    ///   i_new_j     = α·(q0_j − q1_j) [− i_prev_j when the step ran trap]
    ///   volttol_j   = abstol + reltol·max(|i_new_j|, |i_prev_j|)
    ///   chargetol_j = reltol·max(|q0_j|, |q1_j|, chgtol) / dt
    ///   tol_j       = max(volttol_j, chargetol_j)
    ///   dd_j        = divided difference over order+2 charge points
    ///   del_j       = trtol·tol_j / max(abstol, coeff·|dd_j|)
    ///   order 2:      del_j = sqrt(del_j)
    /// coeff: 1/2 at order 1, 1/12 at order 2 (trap; gear_2 shares the
    /// order-2 path — ngspice's gear coefficient differs slightly, deferred).
    /// Returns min del over all states; the caller accepts the step iff
    /// del > 0.9·dt and uses del as the next dt (dctran.c:872-913).
    fn stepBound(
        order2: bool,
        q_cur: []const f64,
        q_prev: []const f64,
        q_prev2: []const f64,
        q_prev3: []const f64,
        i_prev: []const f64,
        alpha_used: f64,
        exec_trap: bool,
        dt: f64,
        dt1: f64,
        dt2: f64,
        reltol: f64,
        abstol: f64,
        chgtol: f64,
        trtol: f64,
    ) f64 {
        const V = @Vector(W, f64);
        const inv_dt: V = @splat(1.0 / dt);
        const inv_dt1: V = @splat(1.0 / dt1);
        const inv_sum01: V = @splat(1.0 / (dt + dt1));
        const av: V = @splat(alpha_used);
        const v_abstol: V = @splat(abstol);
        const v_reltol: V = @splat(reltol);
        const v_chgtol: V = @splat(chgtol);
        const v_trtol: V = @splat(trtol);
        const coeff: V = @splat(if (order2) 1.0 / 12.0 else 0.5);
        var vmin: V = @splat(std.math.inf(f64));
        var i: usize = 0;

        while (i + W <= q_cur.len) : (i += W) {
            const qc: V = q_cur[i..][0..W].*;
            const qp: V = q_prev[i..][0..W].*;
            const ip: V = i_prev[i..][0..W].*;
            const i_new = if (exec_trap) av * (qc - qp) - ip else av * (qc - qp);
            const volttol = v_abstol + v_reltol * @max(@abs(i_new), @abs(ip));
            const chargetol = v_reltol * @max(@max(@abs(qc), @abs(qp)), v_chgtol) * inv_dt;
            const tol = @max(volttol, chargetol);

            const qp2: V = q_prev2[i..][0..W].*;
            const f01 = (qc - qp) * inv_dt;
            const f12 = (qp - qp2) * inv_dt1;
            const f012 = (f01 - f12) * inv_sum01;
            var dd = f012;
            if (order2) {
                const qp3: V = q_prev3[i..][0..W].*;
                const f23 = (qp2 - qp3) * @as(V, @splat(1.0 / dt2));
                const f123 = (f12 - f23) * @as(V, @splat(1.0 / (dt1 + dt2)));
                dd = (f012 - f123) * @as(V, @splat(1.0 / (dt + dt1 + dt2)));
            }
            const del = v_trtol * tol / @max(v_abstol, coeff * @abs(dd));
            vmin = @min(vmin, del);
        }
        var min_del = @reduce(.Min, vmin);
        // Scalar tail
        while (i < q_cur.len) : (i += 1) {
            const i_new = if (exec_trap)
                alpha_used * (q_cur[i] - q_prev[i]) - i_prev[i]
            else
                alpha_used * (q_cur[i] - q_prev[i]);
            const volttol = abstol + reltol * @max(@abs(i_new), @abs(i_prev[i]));
            const chargetol = reltol * @max(@max(@abs(q_cur[i]), @abs(q_prev[i])), chgtol) / dt;
            const tol = @max(volttol, chargetol);
            const f01 = (q_cur[i] - q_prev[i]) / dt;
            const f12 = (q_prev[i] - q_prev2[i]) / dt1;
            const f012 = (f01 - f12) / (dt + dt1);
            var dd = f012;
            if (order2) {
                const f23 = (q_prev2[i] - q_prev3[i]) / dt2;
                const f123 = (f12 - f23) / (dt1 + dt2);
                dd = (f012 - f123) / (dt + dt1 + dt2);
            }
            const c: f64 = if (order2) 1.0 / 12.0 else 0.5;
            const del = trtol * tol / @max(abstol, c * @abs(dd));
            min_del = @min(min_del, del);
        }
        // sqrt is monotone — applying it to the reduced min is equivalent
        // to per-lane sqrt, and cheaper.
        return if (order2) @sqrt(min_del) else min_del;
    }
};

pub const Options = struct {
    tol: converger.Tolerances = .{},
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    dt_max: f64 = 1e-3,
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

    /// Record one point from already-gathered probe values (GPU waveform
    /// drain — the device ships probe values, not the full x vector).
    pub fn recordValues(self: *Waveform, t: f64, vals: []const f64) !void {
        if (self.len == self.capacity) try self.grow();
        self.times[self.len] = t;
        const cap: usize = self.capacity;
        for (vals, 0..) |v, k| self.values[k * cap + self.len] = v;
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
    q_prev2: ?[]const f64, // gear_2 only
    half_inv_dt: f64, // gear_2: 1/(2*dt)
    a_vals: []f64,
    q_snap: ?[]f64,
    has_charge: bool,
    has_history: bool,

    pub fn assemble(self: TranHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        if (self.q_snap) |snap| @memcpy(snap, ckt.q_vec[0..ckt.n]);
        if (self.has_charge) {
            const n: usize = ckt.n;
            const V = @Vector(W, f64);
            const av: V = @splat(self.alpha);
            var i: usize = 0;
            if (self.q_prev2) |qp2| {
                // Gear-2: rhs += alpha*(q - q_prev) - (1/(2*dt))*(q_prev - q_prev2)
                const hv: V = @splat(self.half_inv_dt);
                while (i + W <= n) : (i += W) {
                    const r: V = ckt.rhs[i..][0..W].*;
                    const qv: V = ckt.q_vec[i..][0..W].*;
                    const qp: V = self.q_prev[i..][0..W].*;
                    const qp2v: V = qp2[i..][0..W].*;
                    ckt.rhs[i..][0..W].* = r + av * (qv - qp) - hv * (qp - qp2v);
                }
                while (i < n) : (i += 1)
                    ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]) - self.half_inv_dt * (self.q_prev[i] - qp2[i]);
            } else if (self.i_prev) |ipv| {
                // Trapezoidal
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
                // Backward Euler (or Gear-2 first-step fallback)
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
    // Whole-transient GPU path (engine-owned megakernel driver): chunked
    // cooperative launches integrate the full [0, t_stop] on-device. Only
    // when nothing needs per-step host callbacks or host-side state; any
    // error falls through to the CPU integrator with the waveform rewound.
    if (ckt.gpu_hook) |gh| {
        if (gh.simulate_tran) |gt| {
            if (options.step_fn == null and !ckt.has_history) gpu: {
                const len0 = waveform.len;
                const r = gt(gh.ctx, x, probes, waveform, options) catch {
                    waveform.len = len0;
                    break :gpu;
                };
                return r;
            }
        }
    }
    const n: usize = ckt.n;
    const has_charge = ckt.has_charge;
    const has_history = ckt.has_history;
    const trap = options.method == .trapezoidal;
    const gear = options.method == .gear_2;

    const ws = try ckt.workspace();
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
    // SPICE2 heuristic: never exceed 2% of simulation interval
    effective_dt_max = @min(effective_dt_max, options.t_stop / 50.0);

    try waveform.record(0, x, probes);

    var cur: []f64 = x;
    var trial: []f64 = x_try;
    var t: f64 = 0;
    var dt: f64 = options.dt_init;
    var steps: u32 = 0;
    // Order control (ngspice-style): start at BE, promote to configured
    // method when LTE says it's safe. Drop back to BE at breakpoints to
    // suppress trap companion ringing after source-edge discontinuities.
    var use_be: bool = true;
    var bp_landing: bool = false;

    while (t < options.t_stop and steps < options.max_steps) {
        const use_gear = gear and !use_be and q_levels >= 1;
        const use_trap = trap and !use_be;
        const eff_method: Method = if (use_be or (gear and !use_gear)) .backward_euler else options.method;
        const alpha = integrator.alpha(eff_method, dt);
        const hook = TranHook{
            .alpha = alpha,
            .q_prev = q_hist[1],
            .i_prev = if (use_trap and has_charge) i_prev else null,
            .q_prev2 = if (use_gear and has_charge) q_hist[2] else null,
            .half_inv_dt = if (use_gear) 1.0 / (2.0 * dt) else 0,
            .a_vals = a_vals,
            .q_snap = if (has_charge) q_snap else null,
            .has_charge = has_charge,
            .has_history = has_history,
        };

        @memcpy(trial, cur);
        var nr_opts = options.tol.newtonOpts(options.tol.itl4);
        nr_opts.dx_clamp = std.math.inf(f64);
        const nr = converger.run(ckt, ws, trial, t + dt, nr_opts, hook) catch converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };

        if (!nr.converged) {
            dt *= 0.5;
            if (dt < options.dt_min) return .{ .completed = false, .steps = steps, .t_final = t };
            continue;
        }

        var dt_next = @min(dt * 1.5, effective_dt_max);

        if (has_charge) {
            @memcpy(q_hist[0], q_snap);

            const need: u2 = if (trap or gear) 2 else 1;
            if (q_levels >= need) {
                const order2 = eff_method != .backward_euler;
                const del = integrator.stepBound(
                    order2, q_hist[0], q_hist[1], q_hist[2], q_hist[3],
                    i_prev, alpha, use_trap, dt, dt_prev, dt_prev2,
                    options.tol.reltol, options.tol.abstol, options.tol.chgtol, options.tol.trtol,
                );
                if (del < 0.9 * dt) {
                    dt *= 0.5;
                    if (dt < options.dt_min) return .{ .completed = false, .steps = steps, .t_final = t };
                    continue;
                }
                dt_next = @min(@max(del, options.dt_min), effective_dt_max);
            }

            // Promote BE → configured method when LTE-based dt is stable.
            // ngspice promotes when trap dt_next > 1.05 * current dt.
            if (use_be and q_levels >= need) {
                const trial_order2 = options.method != .backward_euler;
                const trial_del = integrator.stepBound(
                    trial_order2, q_hist[0], q_hist[1], q_hist[2], q_hist[3],
                    i_prev, alpha, use_trap, dt, dt_prev, dt_prev2,
                    options.tol.reltol, options.tol.abstol, options.tol.chgtol, options.tol.trtol,
                );
                if (trial_del > 1.05 * dt) use_be = false;
            }

            // Dynamic current update — must match the method actually used.
            const V = @Vector(W, f64);
            const av: V = @splat(alpha);
            var j: usize = 0;
            if (use_trap) {
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

        // If we just landed on a breakpoint, drop to BE + shrink dt.
        if (bp_landing) {
            use_be = true;
            dt_next = @min(dt_next, dt * 0.1);
            bp_landing = false;
        }

        if (has_history) ckt.recordHistory(cur, t);

        try waveform.record(t, cur, probes);
        if (options.step_fn) |f| f(options.step_ctx, t, cur);

        // Breakpoint handling: clamp dt to reach the next breakpoint.
        // Flag that the step after landing needs BE to suppress trap ringing.
        if (ckt.nextBreakpoint(t)) |bp| {
            const dt_to_bp = bp - t;
            if (dt_to_bp > 1e-18 and dt_to_bp < dt_next) {
                dt_next = dt_to_bp;
                bp_landing = true;
            }
        }

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

// ponytail: estimateLTE/adaptTimestep tests removed — LTE control now
// uses integrator.stepBound which has its own acceptance path in simulate().
