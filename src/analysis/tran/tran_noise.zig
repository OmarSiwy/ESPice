//! Transient noise: backward-Euler transient with one Gaussian current
//! sample per noise source per step, sigma = sqrt(S * BW) with BW = 1/(2dt),
//! so the sampled sequence carries the source's white PSD. Flicker noise
//! (K / f^ef) is a sum of Ornstein-Uhlenbeck (Lorentzian) processes with
//! corners log-spaced over [f_min, 1/(2 dt_max)], each advanced exactly over
//! the step. The PSDs come from the devices (`Circuit.collectNoiseSources`).
const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const converger = @import("solver").converger;
const integrator = @import("integrator.zig");

const NoiseSource = root.NoiseSource;

pub const Options = @import("core").query.TranNoise;
const Waveform = @import("types.zig").Waveform;

/// Xorshift64 PRNG with a Box-Muller normal draw: deterministic per seed.
const Xorshift64 = struct {
    state: u64,

    /// Seed 0 maps to 1, since xorshift is stuck at zero.
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

    /// Uniform in [0, 1) from the top 53 bits.
    fn uniform(self: *Xorshift64) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    /// Standard normal via Box-Muller.
    pub fn randn(self: *Xorshift64) f64 {
        const r1 = @max(self.uniform(), 1e-300); // keeps log finite
        const r2 = self.uniform();
        return @sqrt(-2.0 * @log(r1)) * @cos(2.0 * std.math.pi * r2);
    }
};

/// Flicker generators, SoA over every pole of every source with flicker
/// noise. A pole is an Ornstein-Uhlenbeck process of corner f_k and
/// variance v_k, one-sided PSD 4 v_k tau_k / (1 + (2 pi f tau_k)^2) with
/// tau_k = 1 / (2 pi f_k). With `per_decade` corners log-spaced by ratio r,
/// v_k = K ln(r) sin(pi (2 - ef) / 2) f_k^(1 - ef) makes the sum K / f^ef
/// between the outer corners (the integral of the Lorentzian over log f),
/// so for ef = 1 the variance is K ln(f_max / f_min).
const Flicker = struct {
    /// Owning noise source per pole, 1/tau and stationary variance.
    source: []u32,
    rate: []f64,
    variance: []f64,
    /// Process value. Every attempt advances it; a rejected attempt's
    /// advance stands, which keeps each process stationary.
    y: []f64,
    started: bool = false,

    // ponytail: fixed density; the sum ripples about 0.1 dB around K/f^ef.
    const per_decade = 3.0;

    fn init(gpa: std.mem.Allocator, sources: []const NoiseSource, options: Options) !Flicker {
        const f_max = 0.5 / options.dt_max;
        const f_min = options.f_min orelse 1.0 / options.t_stop;
        const decades = if (f_max > f_min) std.math.log10(f_max / f_min) else 0;
        const k: usize = @intFromFloat(@ceil(per_decade * decades));
        var count: usize = 0;
        // ponytail: ef outside (0, 2) has no finite Lorentzian sum; such a
        // source keeps its white half only.
        for (sources) |s| count += if (s.flicker > 0 and s.ef > 0 and s.ef < 2) k else 0;
        var f: Flicker = .{
            .source = try gpa.alloc(u32, count),
            .rate = try gpa.alloc(f64, count),
            .variance = try gpa.alloc(f64, count),
            .y = try gpa.alloc(f64, count),
        };
        if (count == 0) return f;
        const ln_r = @log(f_max / f_min) / @as(f64, @floatFromInt(k));
        var p: usize = 0;
        for (sources, 0..) |s, i| {
            if (!(s.flicker > 0 and s.ef > 0 and s.ef < 2)) continue;
            const weight = s.flicker * options.scale * ln_r * @sin(std.math.pi * (2 - s.ef) / 2);
            for (0..k) |j| {
                const corner = f_min * @exp(ln_r * (@as(f64, @floatFromInt(j)) + 0.5));
                f.source[p] = @intCast(i);
                f.rate[p] = 2 * std.math.pi * corner;
                f.variance[p] = weight * std.math.pow(f64, corner, 1 - s.ef);
                p += 1;
            }
        }
        return f;
    }

    fn deinit(f: *Flicker, gpa: std.mem.Allocator) void {
        gpa.free(f.source);
        gpa.free(f.rate);
        gpa.free(f.variance);
        gpa.free(f.y);
    }

    /// Advances every pole by `dt` and adds each to its source's current.
    /// The first call draws the stationary state.
    fn step(f: *Flicker, dt: f64, rng: *Xorshift64, currents: []f64) void {
        for (f.source, f.rate, f.variance, f.y) |s, rate, v, *y| {
            const decay = @exp(-rate * dt);
            y.* = if (f.started) y.* * decay + @sqrt(v * (1 - decay * decay)) * rng.randn() else @sqrt(v) * rng.randn();
            currents[s] += y.*;
        }
        f.started = true;
    }
};

/// Newton hook: backward-Euler companion from the q plane plus the sampled
/// noise currents on top of the device residual. Matrix G + C/dt.
const NoiseHook = struct {
    alpha: f64,
    q_prev: []const f64,
    a_vals: []f64,
    has_charge: bool,
    /// Injection endpoints (p0, n0, p1, n1, ...) in source order: the only
    /// 8 bytes of each 48-byte `NoiseSource` this loop reads.
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

    /// One diagonal of the combined matrix without materializing it
    /// (`Circuit.gcAt`); the residual gate calls this per unknown.
    pub fn diagAt(self: NoiseHook, ckt: *root.Circuit, slot: u32) f64 {
        return if (self.has_charge) ckt.gcAt(self.alpha, slot) else ckt.g_vals[slot];
    }
};

/// Integrates from `x`, recording every accepted point into `waveform`.
/// Returns false when dt fell below dt_min before t_stop. There is no LTE
/// control: the noise dominates the local error, so dt only shrinks (by half)
/// on a Newton failure and otherwise grows 1.5x up to dt_max.
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

    const noise_currents = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(noise_currents);

    // Split the source table for the run: sampling streams sqrt(white), the
    // dt-independent factor of sigma, and injection streams the endpoints.
    // Valid because collectNoiseSources ran once on x_op.
    const noise_prefix = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(noise_prefix);
    const inj_nodes = try allocator.alloc(u32, 2 * noise_sources.len);
    defer allocator.free(inj_nodes);
    for (noise_sources, 0..) |src, s| {
        noise_prefix[s] = @sqrt(src.white * options.scale);
        inj_nodes[2 * s] = src.node_p;
        inj_nodes[2 * s + 1] = src.node_n;
    }
    var flicker = try Flicker.init(allocator, noise_sources, options);
    defer flicker.deinit(allocator);

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
        // sqrt(BW), BW = 1/(2dt).
        const bandwidth_scale = @sqrt(1.0 / (2.0 * dt));
        for (noise_prefix, noise_currents) |pfx, *i_n| {
            const sigma = pfx * bandwidth_scale;
            i_n.* = sigma * rng.randn();
        }
        flicker.step(dt, &rng, noise_currents);

        const hook = NoiseHook{
            .alpha = 1.0 / dt,
            .q_prev = q_prev,
            .a_vals = a_vals,
            .has_charge = has_charge,
            .inj_nodes = inj_nodes,
            .noise_currents = noise_currents,
        };

        // As in tran.simulate, devices must see the point this attempt
        // targets (§9.10 `$abstime`); a rejected step retries from here.
        ckt.setSimState(.{ .t = t + dt, .dt = dt, .kind = .tran, .initial_step = steps == 0 });
        simdCopy(x_try, x);
        const tn_nr_opts = converger.optionsFromTolerances(options.tol, options.tol.itl4);
        const nr = converger.run(ckt, ws, x_try, t + dt, tn_nr_opts, hook) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
        };

        if (!nr.converged) {
            _ = ckt.stateCtl(.revert);
            dt *= 0.5;
            if (dt < options.dt_min) return false;
            continue;
        }
        _ = ckt.stateCtl(.commit);

        if (has_charge) {
            // The planes are one iterate behind the converged point. Charges
            // only: the next assemble restamps the other planes.
            ckt.evalQ(x_try, t + dt);
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

/// Contract entry: sample the devices' noise sources at x_op and integrate.
/// Point-major rows (time, probes...); a run cut short by dt_min says so in
/// the plot name rather than failing.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;
    const scratch = ctx.scratch_allocator;
    const x = try scratch.alloc(f64, x_op.len);
    defer scratch.free(x);
    simdCopy(x, x_op);

    const srcs = try ctx.circuit.collectNoiseSources(x_op, scratch);
    defer scratch.free(srcs);

    // ponytail: capacity heuristic. Without Newton failures dt only grows
    // from dt_init, so t_stop/dt_init + 1 rows is the most a run records; 2x
    // is headroom and the waveform doubles past it.
    const est_rows = 2.0 * opts.t_stop / opts.dt_init;
    var wf = try Waveform.init(scratch, @intCast(ctx.probes.len), @intFromFloat(@min(@max(1024.0, est_rows), @as(f64, 1 << 22))));
    defer wf.deinit();
    const completed = try simulate(ctx.circuit, x, ctx.probes, srcs, &wf, opts, scratch);

    const data = try wf.toRows(a, ctx.probes.len + 1);
    errdefer a.free(data);
    const names = try root.probeNames(ctx, "time");
    return .{
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
