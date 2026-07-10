//! Transient noise: backward-Euler transient with one Gaussian current
//! sample per noise source per step, sigma = sqrt(S * BW) with BW = 1/(2dt),
//! so the sampled sequence carries the source's white PSD. Flicker noise
//! (K / f^ef) is a sum of Ornstein-Uhlenbeck (Lorentzian) processes with
//! corners log-spaced over [f_min, 1/(2 dt_max)], each advanced exactly over
//! the step. The PSDs come from the devices (`Circuit.collectNoiseSources`).
//! METHOD=SDE draws nothing: the noiseless march carries the covariance of
//! the noise that sampled runs on the same steps would add (`Covariance`).
const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const converger = @import("solver").converger;
const dense_lu = @import("solver").dense_lu;
const numerics = @import("core").numerics;
const integrator = @import("integrator.zig");

const NoiseSource = root.NoiseSource;

pub const Options = @import("core").query.TranNoise;
const Waveform = @import("types.zig").Waveform;

/// Xorshift64 PRNG with a Box-Muller normal draw: deterministic per seed.
const Xorshift64 = struct {
    state: u64,

    /// The seed goes through SplitMix64 first, so small seeds (HSPICE's
    /// SEED=2, 3, ...) start well mixed; a zero state maps to 1, since
    /// xorshift is stuck at zero.
    pub fn init(seed: u64) Xorshift64 {
        var mix = std.Random.SplitMix64.init(seed);
        const state = mix.next();
        return .{ .state = if (state == 0) 1 else state };
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

/// METHOD=SDE: the covariance of the noise part of x through the same
/// backward-Euler steps the sampled run takes, exact for the linearized
/// circuit. With A = G + C/h and P = C/h at the step's end point, the white
/// draws w (covariance N, sigma^2 = S/(2h) per source) and the flicker
/// poles y (stationary variances V, decays D = e^(-h/tau), injected by J),
///   x_k = A^-1 (P x_{k-1} + J y_k + w_k)
///   K_k = A^-1 (P K P^T + P Kxy D J^T + J D Kxy^T P^T + J V J^T + N) A^-T
///   Kxy_k = A^-1 (P Kxy D + J V),
/// with K = E[x x^T] and Kxy = E[x y^T], both zero at t = 0.
// ponytail: dense n x n K and a dense LU per step, O(n^3) a step. A
// low-rank factor of K over a sparse LU is the upgrade for large circuits.
const Covariance = struct {
    /// Row-major n x n: K, then the products that become the next K.
    k: []f64,
    m: []f64,
    /// Dense G + C/h, factored in place.
    a: []f64,
    piv: []u32,
    /// Pole-major `poles x n`: row p is E[x y_p].
    kxy: []f64,
    /// Injection endpoints and white PSD of each source, `NoiseHook` layout.
    inj_nodes: []const u32,
    white: []const f64,
    n: usize,

    fn init(gpa: std.mem.Allocator, n: usize, poles: usize, inj_nodes: []const u32, white: []const f64) !Covariance {
        const buf = try gpa.alloc(f64, 3 * n * n + poles * n);
        @memset(buf, 0);
        return .{
            .k = buf[0 .. n * n],
            .m = buf[n * n ..][0 .. n * n],
            .a = buf[2 * n * n ..][0 .. n * n],
            .kxy = buf[3 * n * n ..],
            .piv = try gpa.alloc(u32, n),
            .inj_nodes = inj_nodes,
            .white = white,
            .n = n,
        };
    }

    fn deinit(c: *Covariance, gpa: std.mem.Allocator) void {
        gpa.free(c.k.ptr[0 .. 3 * c.n * c.n + c.kxy.len]);
        gpa.free(c.piv);
    }

    /// out[row] += alpha * C x for every row; C from the CSC plane.
    fn addCx(ckt: *const root.Circuit, alpha: f64, x: []const f64, out: []f64) void {
        for (0..ckt.n) |j| {
            if (x[j] == 0) continue;
            for (ckt.col_ptr[j]..ckt.col_ptr[j + 1]) |p| out[ckt.row_idx[p]] += alpha * ckt.c_vals[p] * x[j];
        }
    }

    /// Adds v (e_a - e_b)(e_a - e_b)^T to the dense matrix m; ground rows
    /// carry no noise.
    fn stampPair(m: []f64, n: usize, a: u32, b: u32, v: f64) void {
        if (a != root.GROUND) m[a * n + a] += v;
        if (b != root.GROUND) m[b * n + b] += v;
        if (a != root.GROUND and b != root.GROUND) {
            m[a * n + b] -= v;
            m[b * n + a] -= v;
        }
    }

    /// In-place transpose of the row-major n x n matrix m.
    fn transpose(m: []f64, n: usize) void {
        for (0..n) |i| for (i + 1..n) |j| std.mem.swap(f64, &m[i * n + j], &m[j * n + i]);
    }

    /// Advances K and Kxy over one accepted step of length h ending at x,
    /// whose planes `ckt` holds. `flicker` gives the poles, `scale` the PSD
    /// factor of the white sources.
    fn step(c: *Covariance, ckt: *const root.Circuit, h: f64, flicker: *const Flicker, scale: f64) !void {
        const n = c.n;
        const alpha = 1 / h;
        // m = P K P^T, K symmetric: a gets the columns of P K by rows,
        // turns into P K, and row i of m (= column i) is P (P K)[i,:]^T.
        @memset(c.a, 0);
        for (0..n) |i| addCx(ckt, alpha, c.k[i * n ..][0..n], c.a[i * n ..][0..n]);
        transpose(c.a, n);
        @memset(c.m, 0);
        for (0..n) |i| addCx(ckt, alpha, c.a[i * n ..][0..n], c.m[i * n ..][0..n]);
        for (c.white, 0..) |w, s| stampPair(c.m, n, c.inj_nodes[2 * s], c.inj_nodes[2 * s + 1], w * scale * 0.5 * alpha);
        for (flicker.source, flicker.rate, flicker.variance, 0..) |s, rate, v, p| {
            const node_p = c.inj_nodes[2 * s];
            const node_n = c.inj_nodes[2 * s + 1];
            // u = D P Kxy[p]: the cross term P Kxy D J^T is u j_p^T.
            const row = c.kxy[p * n ..][0..n];
            const u = c.a[0..n];
            @memset(u, 0);
            addCx(ckt, alpha * @exp(-rate * h), row, u);
            for (0..n) |i| {
                if (node_p != root.GROUND) {
                    c.m[i * n + node_p] += u[i];
                    c.m[node_p * n + i] += u[i];
                }
                if (node_n != root.GROUND) {
                    c.m[i * n + node_n] -= u[i];
                    c.m[node_n * n + i] -= u[i];
                }
            }
            stampPair(c.m, n, node_p, node_n, v);
            // Kxy[p] <- u + v j_p, solved below.
            numerics.copySimd(row, u);
            if (node_p != root.GROUND) row[node_p] += v;
            if (node_n != root.GROUND) row[node_n] -= v;
        }
        ckt.denseG(c.a);
        for (0..n) |j| for (ckt.col_ptr[j]..ckt.col_ptr[j + 1]) |p| {
            c.a[@as(usize, ckt.row_idx[p]) * n + j] += alpha * ckt.c_vals[p];
        };
        try dense_lu.factorize(n, c.a, c.piv);
        for (0..flicker.source.len) |p| dense_lu.solveFactored(n, c.a, c.piv, c.kxy[p * n ..][0..n], c.kxy[p * n ..][0..n]);
        // K = A^-1 (A^-1 m)^T, m symmetric: rows of m are its columns.
        for (0..n) |i| dense_lu.solveFactored(n, c.a, c.piv, c.m[i * n ..][0..n], c.m[i * n ..][0..n]);
        transpose(c.m, n);
        for (0..n) |i| dense_lu.solveFactored(n, c.a, c.piv, c.m[i * n ..][0..n], c.k[i * n ..][0..n]);
    }

    /// Variance of x[a] - x[b].
    fn variance(c: Covariance, a: u32, b: u32) f64 {
        const n = c.n;
        return c.k[a * n + a] + c.k[b * n + b] - c.k[a * n + b] - c.k[b * n + a];
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
/// on a Newton failure and otherwise grows 1.5x up to dt_max. With
/// `options.sde` nothing is drawn, and `onoise` (required then) gets the rms
/// noise of v(out_node, out_neg) at every recorded point.
pub fn simulate(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    noise_sources: []const NoiseSource,
    waveform: *Waveform,
    onoise: ?*std.ArrayList(f64),
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
    const white = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(white);
    for (noise_sources, white) |src, *w| w.* = src.white;
    var cov: ?Covariance = if (options.sde) try Covariance.init(allocator, n, flicker.source.len, inj_nodes, white) else null;
    defer if (cov) |*c| c.deinit(allocator);
    @memset(noise_currents, 0);

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
    if (cov != null) try onoise.?.append(allocator, 0);

    var t: f64 = 0;
    var dt: f64 = options.dt_init;
    var steps: u32 = 0;

    var attempts: u64 = 0;
    while (t < options.t_stop and steps < options.max_steps) {
        if (attempts != 0) try ckt.checkpoint(.{ .phase = .transient, .completed = attempts });
        attempts += 1;
        // HSPICE TIME=: land on the time exactly, then march on.
        const land = if (options.t_break) |tb| t < tb and t + dt >= tb else false;
        if (land) dt = options.t_break.? - t;
        if (cov == null) {
            // sqrt(BW), BW = 1/(2dt).
            const bandwidth_scale = @sqrt(1.0 / (2.0 * dt));
            for (noise_prefix, noise_currents) |pfx, *i_n| {
                const sigma = pfx * bandwidth_scale;
                i_n.* = sigma * rng.randn();
            }
            flicker.step(dt, &rng, noise_currents);
        }

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

        if (cov) |*c| {
            ckt.eval(x_try, t + dt);
            try c.step(ckt, dt, &flicker, options.scale);
            try onoise.?.append(allocator, @sqrt(@max(c.variance(options.out_node, options.out_neg), 0)));
        }

        simdCopy(x, x_try);
        t = if (land) options.t_break.? else t + dt;
        steps += 1;

        try waveform.record(t, x, probes);

        dt = @min(dt * 1.5, options.dt_max);
        if (t + dt > options.t_stop) dt = options.t_stop - t;
    }

    return t >= options.t_stop;
}

/// Contract entry: sample the devices' noise sources at x_op and integrate.
/// Point-major rows (time, probes..., and `onoise` for SDE); a run cut short
/// by dt_min says so in the plot name rather than failing, and a run of a
/// SAMPLES set names its index.
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
    // Recorded straight into the results arena; the Result borrows it
    // unless SDE appends its onoise column.
    var wf = try Waveform.init(a, @intCast(ctx.probes.len), @intFromFloat(@min(@max(1024.0, est_rows), @as(f64, 1 << 22))));
    errdefer wf.deinit();
    var onoise: std.ArrayList(f64) = .empty;
    defer onoise.deinit(scratch);
    const completed = try simulate(ctx.circuit, x, ctx.probes, srcs, &wf, &onoise, opts, scratch);

    const probe_names = try root.probeNames(ctx, "time");
    var names = probe_names;
    var data = wf.data();
    if (opts.sde) {
        const s = wf.stride();
        const width = s + 1;
        const rows = try a.alloc(f64, @as(usize, wf.len) * width);
        for (onoise.items, 0..) |v, r| {
            @memcpy(rows[r * width ..][0..s], data[r * s ..][0..s]);
            rows[r * width + s] = v;
        }
        data = rows;
        const all = try a.realloc(@constCast(probe_names), width);
        all[s] = "onoise";
        names = all;
    }
    const base = if (completed) "Transient Noise Analysis" else "Transient Noise Analysis (stopped early)";
    return .{
        .plotname = if (opts.sample == 0) base else try std.fmt.allocPrint(a, "{s} (sample={d})", .{ base, opts.sample }),
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
