//! Transient noise: transient Newton per timestep with sampled noise currents
//! injected into the residual. Each step draws one Gaussian sample per source
//! with sigma = sqrt(S*BW), BW = 1/(2*dt), so the discrete-time sequence
//! carries the correct white PSD. Source PSDs come from the DEVICE
//! (root.Circuit.collectNoiseSources -> the model's own `noisePsd`) — this
//! analysis never re-derives them.
const std = @import("std");
const root = @import("../types.zig");
// ponytail: the shared copy owns SIMD setup; seeded noise sampling stays scalar.
const simdCopy = root.copySimd;
const converger = @import("solvers").converger;
const integrator = @import("integrator.zig");

pub const NoiseSource = root.NoiseSource;

pub const Options = @import("requests").TranNoise;
const Waveform = @import("types.zig").Waveform;

// ============================================================================
// Xorshift64 PRNG
// ============================================================================

const Xorshift64 = struct {
    state: u64,

    pub fn init(seed: u64) Xorshift64 {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    pub fn next(self: *Xorshift64) u64 {
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
    pub fn randn(self: *Xorshift64) f64 {
        const r1 = @max(self.uniform(), 1e-300); // avoid log(0)
        const r2 = self.uniform();
        return @sqrt(-2.0 * @log(r1)) * @cos(2.0 * std.math.pi * r2);
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
    /// Injection endpoints only, interleaved (p0, n0, p1, n1, ...) in source
    /// order — the shared `NoiseSource` is 48 bytes and this loop wants 8 of
    /// them. Same order, same per-source add-then-subtract.
    inj_nodes: []const u32,
    noise_currents: []const f64,

    pub fn assemble(self: NoiseHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.eval(x, t);
        if (self.has_charge) {
            const n: usize = ckt.n;
            integrator.companionAt(.backward_euler, true, ckt.rhs[0..n], ckt.q_vec[0..n], self.q_prev[0..n], &.{}, &.{}, .{ .ag0 = self.alpha, .ag2 = 0 });
        }
        for (self.noise_currents, 0..) |i_n, s| {
            const node_p = self.inj_nodes[2 * s];
            const node_n = self.inj_nodes[2 * s + 1];
            if (node_p != root.GROUND) ckt.rhs[node_p] += i_n;
            if (node_n != root.GROUND) ckt.rhs[node_n] -= i_n;
        }
    }

    pub fn vals(self: NoiseHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
    }
    /// One diagonal, without materializing the whole combined plane —
    /// see `Circuit.gcAt`. The residual gate calls this per unknown.
    pub fn diagAt(self: NoiseHook, ckt: *root.Circuit, slot: u32) f64 {
        return if (self.has_charge) ckt.gcAt(self.alpha, slot) else ckt.g_vals[slot];
    }
};

/// Integrate from x, recording accepted points into `waveform`. Returns
/// whether it reached t_stop (false: dt fell below dt_min).
pub fn simulate(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    noise_sources: []const NoiseSource,
    waveform: *Waveform,
    options: Options,
    allocator: std.mem.Allocator,
) !bool {
    const n: usize = ckt.n;
    const has_charge = ckt.has_charge;

    const ws = try ckt.workspace();
    const x_try = try allocator.alloc(f64, n);
    defer allocator.free(x_try);

    // One noise current sample per source per step.
    const noise_currents = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(noise_currents);

    // Simulation-lifetime split of the shared NoiseSource table: sampling
    // streams only the white PSD, injection only the endpoints. The prefix is
    // the invariant head of sigma = sqrt(S*BW). Requires the source data to be
    // immutable over the run, which it is — collectNoiseSources runs once on
    // x_op.
    //
    // ponytail: the WHITE half only. A `flicker` term is 1/f^ef, and a
    // per-step iid draw cannot produce that shape — sampling it as if it were
    // white would put the whole 1/f power at every frequency, which is worse
    // than omitting it. Upgrade path is a shaping filter (the standard sum of
    // first-order poles) driving the same draw; until then a 1/f generator
    // contributes its white half here and its full PSD in `.noise`/`.pnoise`.
    const noise_prefix = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(noise_prefix);
    const inj_nodes = try allocator.alloc(u32, 2 * noise_sources.len);
    defer allocator.free(inj_nodes);
    for (noise_sources, 0..) |src, s| {
        noise_prefix[s] = @sqrt(src.white);
        inj_nodes[2 * s] = src.node_p;
        inj_nodes[2 * s + 1] = src.node_n;
    }

    // Backward-Euler charge state (no LTE control here: noise dominates the
    // local error, so the step only shrinks on Newton failure).
    var a_vals: []f64 = &.{};
    var q_prev: []f64 = &.{};
    defer if (has_charge) allocator.free(q_prev);
    if (has_charge) {
        a_vals = try ws.ensureAVals(ckt.nnz);
        q_prev = try allocator.alloc(f64, n);
        ckt.eval(x, 0);
        simdCopy(q_prev, ckt.q_vec[0..n]);
    }

    var rng = Xorshift64.init(options.seed);

    try waveform.record(0, x, probes);

    var t: f64 = 0;
    var dt: f64 = options.dt_init;
    var steps: u32 = 0;

    var attempts: u64 = 0;
    while (t < options.t_stop and steps < options.max_steps) {
        if (attempts != 0) try ckt.checkpoint(.{ .phase = .transient, .completed = attempts });
        attempts += 1;
        // Bandwidth for this timestep: BW = 1 / (2 * dt)
        const bandwidth_scale = @sqrt(1.0 / (2.0 * dt));

        // Scale device-generated white noise to this timestep's bandwidth.
        for (noise_prefix, noise_currents) |pfx, *i_n| {
            const sigma = pfx * bandwidth_scale;
            i_n.* = sigma * rng.randn();
        }

        const hook = NoiseHook{
            .alpha = 1.0 / dt,
            .q_prev = q_prev,
            .a_vals = a_vals,
            .has_charge = has_charge,
            .inj_nodes = inj_nodes,
            .noise_currents = noise_currents,
        };

        // Same contract as tran.simulate: the devices' §9.10 `$abstime`/dt must
        // describe the point this attempt targets, and a rejected step
        // `continue`s back here with the halved dt.
        ckt.setSimState(.{ .t = t + dt, .dt = dt, .kind = .tran, .initial_step = steps == 0 });
        simdCopy(x_try, x);
        var tn_nr_opts = converger.optionsFromTolerances(options.tol, options.tol.itl4);
        tn_nr_opts.dx_clamp = std.math.inf(f64);
        const nr = converger.run(ckt, ws, x_try, t + dt, tn_nr_opts, hook) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
        };

        if (!nr.converged) {
            dt *= 0.5;
            if (dt < options.dt_min) return false;
            continue;
        }

        if (has_charge) {
            // exact q at the converged point (planes are one iterate stale)
            ckt.eval(x_try, t + dt);
            simdCopy(q_prev, ckt.q_vec[0..n]);
        }

        simdCopy(x, x_try);
        t += dt;
        steps += 1;

        try waveform.record(t, x, probes);

        dt = @min(dt * 1.5, options.dt_max);
        if (t + dt > options.t_stop) dt = options.t_stop - t;
    }

    return t >= options.t_stop;
}

/// Contract entry: device-generated sources from collectNoiseSources, BE transient with
/// per-step noise injection. Data layout: point-major (time, probes...).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;
    // `defer`-freed == scratch; `a` is a results arena.
    const scratch = ctx.scratch_allocator;
    const x = try scratch.alloc(f64, x_op.len);
    defer scratch.free(x);
    simdCopy(x, x_op);

    const srcs = try ctx.circuit.collectNoiseSources(x_op, scratch);
    defer scratch.free(srcs);

    // ponytail: waveform capacity heuristic. dt starts at dt_init and only
    // grows (x1.5 up to dt_max) on an accepted step, so a run with no Newton
    // failures records at most t_stop/dt_init + 1 rows. 2x keeps headroom for
    // the dt_min tail; only repeated Newton failure drives dt below dt_init,
    // and the waveform doubles for that.
    const est_rows = 2.0 * opts.t_stop / opts.dt_init;
    var wf = try Waveform.init(scratch, @intCast(ctx.probes.len), @intFromFloat(@min(@max(1024.0, est_rows), @as(f64, 1 << 22))));
    defer wf.deinit();
    const completed = try simulate(ctx.circuit, x, ctx.probes, srcs, &wf, opts, scratch);

    const data = try wf.toRows(a, ctx.probes.len + 1);
    errdefer a.free(data);
    const names = try root.probeNames(ctx, "time");
    return .{
        // Early stop surfaced in the plotname — run() stays pure.
        .plotname = if (completed) "Transient Noise Analysis" else "Transient Noise Analysis (stopped early)",
        .varnames = names,
        .is_complex = false,
        .npoints = wf.len,
        .data = data,
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .Xorshift64 = Xorshift64,
    .simdCopy = simdCopy,
} else {};
