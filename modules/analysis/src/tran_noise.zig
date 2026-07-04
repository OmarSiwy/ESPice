//! Transient noise: transient Newton per timestep with sampled thermal
//! noise currents injected into the residual. Each step draws one Gaussian
//! sample per source with sigma = sqrt(4kT*G*BW), BW = 1/(2*dt), so the
//! discrete-time sequence carries the correct white PSD. Noise sources come
//! off the analytic Jacobian (root.Circuit.collectNoiseSources) — devices
//! carry builtin noise generators, this analysis never re-derives them.
const std = @import("std");
const root = @import("root.zig");
const newton = @import("newton.zig");

const k_boltzmann = 1.380649e-23; // J/K

pub const NoiseSource = root.NoiseSource;

pub const Options = struct {
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    dt_max: f64 = 1e-3,
    max_newton_iter: u16 = 50,
    newton_tol: f64 = 1e-9,
    max_steps: u32 = 1_000_000,
    temp_k: f64 = 27.0 + 273.15,
    seed: u64 = 0xDEAD_BEEF_CAFE_1234,
};

/// simulate() output. `rows` is the full allocation (caller frees); the
/// recorded samples are rows[0 .. npoints * (probes.len + 1)], point-major:
/// (time, v(probe0), v(probe1), ...) per row — already Result data layout.
pub const SimResult = struct {
    completed: bool,
    steps: u32,
    t_final: f64,
    npoints: u32,
    rows: []f64,
};

// ============================================================================
// Xorshift64 PRNG
// ============================================================================

const Xorshift64 = struct {
    state: u64,

    fn init(seed: u64) Xorshift64 {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    fn next(self: *Xorshift64) u64 {
        var s = self.state;
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        self.state = s;
        return s;
    }

    /// Uniform in [0, 1).
    fn uniform(self: *Xorshift64) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    /// Standard normal via Box-Muller transform.
    fn randn(self: *Xorshift64) f64 {
        const r1 = @max(self.uniform(), 1e-300); // avoid log(0)
        const r2 = self.uniform();
        return @sqrt(-2.0 * @log(r1)) * @cos(2.0 * std.math.pi * r2);
    }
};

// ============================================================================
// Flat waveform recorder (no ArrayList): point-major rows, doubling fallback
// ============================================================================

const Recorder = struct {
    rows: []f64,
    ncols: usize,
    n_rows: usize,

    fn record(self: *Recorder, gpa: std.mem.Allocator, t: f64, x: []const f64, probes: []const u32) !void {
        if ((self.n_rows + 1) * self.ncols > self.rows.len)
            // ponytail: doubling fallback for walks past the size heuristic
            self.rows = try gpa.realloc(self.rows, self.rows.len * 2);
        const row = self.rows[self.n_rows * self.ncols ..][0..self.ncols];
        row[0] = t;
        for (probes, row[1..]) |node, *out| out.* = x[node];
        self.n_rows += 1;
    }
};

// ============================================================================
// Transient noise simulation
// ============================================================================

/// Newton hook: backward-Euler companion from the q plane plus the sampled
/// noise currents on top of the device residual. Matrix = G + (1/dt)*C.
const NoiseHook = struct {
    alpha: f64,
    q_prev: []const f64,
    a_vals: []f64,
    has_charge: bool,
    noise_sources: []const NoiseSource,
    noise_currents: []const f64,

    pub fn assemble(self: NoiseHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.eval(x, t);
        if (self.has_charge) {
            for (0..ckt.n) |i|
                ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]);
        }
        for (self.noise_sources, self.noise_currents) |src, i_n| {
            if (src.node_p != root.GROUND) ckt.rhs[src.node_p] += i_n;
            if (src.node_n != root.GROUND) ckt.rhs[src.node_n] -= i_n;
        }
    }

    pub fn vals(self: NoiseHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
    }
};

pub fn simulate(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    noise_sources: []const NoiseSource,
    options: Options,
    allocator: std.mem.Allocator,
) !SimResult {
    const n: usize = ckt.n;
    const has_charge = ckt.has_charge;

    var ws = try newton.Workspace.init(allocator, ckt);
    defer ws.deinit(allocator);
    const x_try = try allocator.alloc(f64, n);
    defer allocator.free(x_try);

    // One noise current sample per source per step.
    const noise_currents = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(noise_currents);

    // Backward-Euler charge state (no LTE control here: noise dominates the
    // local error, so the step only shrinks on Newton failure).
    var a_vals: []f64 = &.{};
    var q_prev: []f64 = &.{};
    defer if (has_charge) {
        allocator.free(a_vals);
        allocator.free(q_prev);
    };
    if (has_charge) {
        a_vals = try allocator.alloc(f64, ckt.nnz);
        q_prev = try allocator.alloc(f64, n);
        ckt.eval(x, 0);
        @memcpy(q_prev, ckt.q_vec[0..n]);
    }

    var rng = Xorshift64.init(options.seed);

    // ponytail: waveform capacity heuristic — expected rows ~ steps at dt_init
    // with growth headroom (16x), clamped to [1024, 1<<22]; doubling fallback
    // in Recorder.record covers dt collapse below dt_init.
    const est_rows = 16.0 * options.t_stop / options.dt_init;
    const cap_rows: usize = @intFromFloat(@min(@max(1024.0, est_rows), @as(f64, 1 << 22)));
    const ncols = probes.len + 1;
    var rec = Recorder{
        .rows = try allocator.alloc(f64, cap_rows * ncols),
        .ncols = ncols,
        .n_rows = 0,
    };
    errdefer allocator.free(rec.rows);

    try rec.record(allocator, 0, x, probes);

    var t: f64 = 0;
    var dt: f64 = options.dt_init;
    var steps: u32 = 0;

    while (t < options.t_stop and steps < options.max_steps) {
        // Bandwidth for this timestep: BW = 1 / (2 * dt)
        const bandwidth = 1.0 / (2.0 * dt);

        // Thermal noise sample: i_rms = sqrt(4 * k * T * G * BW)
        for (noise_sources, noise_currents) |src, *i_n| {
            const sigma = @sqrt(4.0 * k_boltzmann * options.temp_k * src.conductance * bandwidth);
            i_n.* = sigma * rng.randn();
        }

        const hook = NoiseHook{
            .alpha = 1.0 / dt,
            .q_prev = q_prev,
            .a_vals = a_vals,
            .has_charge = has_charge,
            .noise_sources = noise_sources,
            .noise_currents = noise_currents,
        };

        @memcpy(x_try, x);
        const nr = newton.solve(ckt, &ws.slv, x_try, ws.dx, ws.x_old, t + dt, .{
            .max_iter = options.max_newton_iter,
            .abstol = options.newton_tol,
            .gmin = 1e-12,
            .dx_clamp = std.math.inf(f64),
        }, hook) catch newton.Result{ .converged = false, .iterations = 0, .max_dx = 0 };

        if (!nr.converged) {
            dt *= 0.5;
            if (dt < options.dt_min) {
                return .{ .completed = false, .steps = steps, .t_final = t, .npoints = @intCast(rec.n_rows), .rows = rec.rows };
            }
            continue;
        }

        if (has_charge) {
            // exact q at the converged point (planes are one iterate stale)
            ckt.eval(x_try, t + dt);
            @memcpy(q_prev, ckt.q_vec[0..n]);
        }

        @memcpy(x, x_try);
        t += dt;
        steps += 1;

        try rec.record(allocator, t, x, probes);

        dt = @min(dt * 1.5, options.dt_max);
        if (t + dt > options.t_stop) dt = options.t_stop - t;
    }

    return .{
        .completed = t >= options.t_stop,
        .steps = steps,
        .t_final = t,
        .npoints = @intCast(rec.n_rows),
        .rows = rec.rows,
    };
}

/// Contract entry: sources off the analytic Jacobian (builtin device noise via
/// collectNoiseSources — never re-derived per resistor), BE transient with
/// per-step noise injection. Data layout: point-major (time, probes...).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const x = try a.dupe(f64, x_op);
    defer a.free(x);

    const srcs = try ctx.circuit.collectNoiseSources(x_op, a);
    defer a.free(srcs);

    const st = try simulate(ctx.circuit, x, ctx.probes, srcs, opts, a);

    const names = try root.probeNames(ctx, "time");
    return .{
        // Early stop surfaced in the plotname — run() stays pure.
        .plotname = if (st.completed) "Transient Noise Analysis" else "Transient Noise Analysis (stopped early)",
        .varnames = names,
        .is_complex = false,
        .npoints = st.npoints,
        .data = st.rows[0 .. @as(usize, st.npoints) * names.len],
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "tran_noise: xorshift64 produces deterministic sequence" {
    var rng1 = Xorshift64.init(42);
    var rng2 = Xorshift64.init(42);

    for (0..100) |_| {
        try testing.expectEqual(rng1.next(), rng2.next());
    }
}

test "tran_noise: randn distribution has zero mean and unit variance" {
    var rng = Xorshift64.init(0xCAFE_BABE);
    const n_samples: usize = 100_000;

    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    for (0..n_samples) |_| {
        const v = rng.randn();
        sum += v;
        sum_sq += v * v;
    }
    const mean = sum / @as(f64, @floatFromInt(n_samples));
    const variance = sum_sq / @as(f64, @floatFromInt(n_samples)) - mean * mean;

    try testing.expectApproxEqAbs(@as(f64, 0.0), mean, 0.02);
    try testing.expectApproxEqAbs(@as(f64, 1.0), variance, 0.02);
}
