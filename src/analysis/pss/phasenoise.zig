//! Oscillator phase noise by the perturbation projection vector (PPV;
//! Demir, Mehrotra and Roychowdhury, IEEE TCAS-I 47(5), 2000), HSPICE's
//! `.phasenoise` METHOD=0, and by periodic noise about the oscillator orbit
//! (METHOD=1), stitched together by METHOD=2.
//!
//! A small current b(t) injected into an oscillator shifts its phase, not
//! its amplitude, in the long run: x(t) ~ x_s(t + a(t)) with
//! da/dt = v(t)^T b(t). v(t) is the PPV. White noise sources make a(t) a
//! random walk of diffusion constant
//!   c = (1/T) integral_0^T sum_s (v_p(t) - v_n(t))^2 S_s(t)/2 dt
//! (S_s the one-sided current PSD of source s between nodes p and n), and
//! the single-sideband phase noise at offset f_m is the Lorentzian
//!   L(f_m) = f0^2 c / (pi^2 f0^4 c^2 + f_m^2).
//! A flicker source m_s(t) n(t), n of PSD 1/f^ef and much slower than the
//! period, drives da/dt through the period average of v times m_s only, so
//! it adds <(v_p - v_n) m_s>^2 / (2 f_m^ef) to c at f_m. Like HSPICE's
//! default PHNOISE_LORENTZ=1, that c(f_m) goes through the same Lorentzian.
//!
//! The PPV comes from the autonomous HB solve. Its Jacobian J = dF/dX is
//! singular along the time-shift direction, and its left null vector y
//! measures how a synchronous perturbation B moves the frequency:
//! J dX + dF/d(ln w) d(ln w) = -B gives d(ln w) = -y.B / (y.dF/d(ln w)).
//! `hb.solveSpectrum` returns y already normalized to y.dF/d(ln w) = 1, and
//! matching d(ln w) = (1/T) integral v.b harmonic by harmonic gives
//! v = -(y_dc + 2 sum_h y_ch cos + y_sh sin), which `hb.orbit` samples.
const std = @import("std");
const root = @import("../types.zig");
const hb = @import("hb.zig");
const pnoise = @import("pnoise.zig");

pub const Options = @import("core").query.PhaseNoise;

/// PPV and orbit samples per period before rounding up to a power of two.
const min_samples: usize = 64;

/// Phase diffusion of an oscillator, c(f_m) = white + sum_s dc_s^2 /
/// (2 f_m^ef_s), in s.
pub const Diffusion = struct {
    white: f64,
    /// Per noise source: (1/T) integral (v_p - v_n) sqrt(flicker_s(t)) dt,
    /// and its flicker exponent.
    dc: []f64,
    ef: []f64,

    /// c at offset `f_m` (Hz), in s.
    pub fn at(d: Diffusion, f_m: f64) f64 {
        var c = d.white;
        for (d.dc, d.ef) |m, ef| if (m != 0) {
            c += m * m / (2 * std.math.pow(f64, f_m, ef));
        };
        return c;
    }

    /// Frees `dc` and `ef` with the allocator `diffusion` was given.
    pub fn deinit(d: Diffusion, gpa: std.mem.Allocator) void {
        gpa.free(d.dc);
        gpa.free(d.ef);
    }
};

/// The diffusion of the oscillator whose HB solution is `x_hat` at `f0`,
/// from the normalized left null vector `y` (`hb.solveSpectrum`'s `ppv`,
/// overwritten). Samples both on `n_samples` points. The caller frees the
/// result with `allocator`.
pub fn diffusion(ckt: *root.Circuit, x_hat: []const f64, y: []f64, f0: f64, n_samples: usize, allocator: std.mem.Allocator) !Diffusion {
    const n: usize = ckt.n;
    const nf = x_hat.len / n;
    // v's spectrum in the orbit's [dc, cos_h, sin_h] amplitude convention.
    for (0..n) |node| {
        const spec = y[node * nf ..][0..nf];
        spec[0] = -spec[0];
        for (spec[1..]) |*coeff| coeff.* *= -2;
    }
    const orb = try hb.orbit(x_hat, n, f0, n_samples, true, allocator);
    defer allocator.free(orb.wave);
    const ppv = try hb.orbit(y, n, f0, n_samples, true, allocator);
    defer allocator.free(ppv.wave);

    var d: Diffusion = .{ .white = 0, .dc = &.{}, .ef = &.{} };
    errdefer d.deinit(allocator);
    for (0..n_samples) |k| {
        const v = ppv.state(k, n);
        const srcs = try ckt.collectNoiseSources(orb.state(k, n), allocator);
        defer allocator.free(srcs);
        if (k == 0) {
            d.dc = try allocator.alloc(f64, srcs.len);
            @memset(d.dc, 0);
            d.ef = try allocator.alloc(f64, srcs.len);
            for (srcs, d.ef) |src, *ef| ef.* = src.ef;
        }
        if (srcs.len != d.dc.len) return error.NoiseTopologyChanged;
        for (srcs, d.dc) |src, *dc| {
            const vp = if (src.node_p != root.GROUND) v[src.node_p] else 0;
            const vn = if (src.node_n != root.GROUND) v[src.node_n] else 0;
            d.white += (vp - vn) * (vp - vn) * src.white / 2;
            dc.* += (vp - vn) * pnoise.signedSqrt(src.flicker);
        }
    }
    const inv: f64 = 1 / @as(f64, @floatFromInt(n_samples));
    d.white *= inv;
    for (d.dc) |*m| m.* *= inv;
    return d;
}

/// METHOD=1: the periodic noise density of `opts.osc_node` at
/// carrier * f0 + f_m, over the carrier's mean-square amplitude, for each
/// offset in `offsets`, into `out` (linear, per Hz). Phase and amplitude
/// noise together, as HSPICE describes it; the orbit's phase mode makes
/// the conversion matrix singular as f_m -> 0, so it is the far-out
/// method.
fn periodic(ckt: *root.Circuit, x_hat: []const f64, f0: f64, srcs: []const root.NoiseSource, offsets: []const f64, out: []f64, opts: Options, allocator: std.mem.Allocator) !void {
    const n: usize = ckt.n;
    const nf = 2 * @as(usize, opts.n_harmonics) + 1;
    const k: f64 = @floatFromInt(opts.carrier);
    const freqs = try allocator.alloc(f64, offsets.len);
    defer allocator.free(freqs);
    for (freqs, offsets) |*f, fm| f.* = fm + k * f0;
    const orb = try hb.orbit(x_hat, n, f0, pnoise.samplesFor(@max(min_samples, 2 * nf), nf), true, allocator);
    defer allocator.free(orb.wave);
    _ = try pnoise.orbitSweep(ckt, orb, srcs, freqs, out, .{
        .tol = opts.tol,
        .out_node = opts.osc_node,
        .sweep = .{ .kind = .poi, .points = @intCast(freqs.len), .list = freqs, .f_start = freqs[0], .f_stop = freqs[freqs.len - 1] },
        .f_fundamental = f0,
        .n_sidebands = opts.n_harmonics,
    }, allocator);
    const spec = x_hat[@as(usize, opts.osc_node) * nf ..][0..nf];
    const c = spec[2 * opts.carrier - 1];
    const s = spec[2 * opts.carrier];
    const power = (c * c + s * s) / 2;
    for (out) |*l| l.* /= power;
}

/// METHOD=2: `nlp` below the first offset where it and `pac` agree within
/// `match_db`, `pac` from there on; all `nlp` when they never agree. Both
/// in dBc/Hz, written into `nlp`.
pub fn stitch(nlp: []f64, pac: []const f64, match_db: f64) void {
    for (nlp, pac, 0..) |l, p, i| if (@abs(l - p) <= match_db) {
        @memcpy(nlp[i..], pac[i..]);
        return;
    };
}

/// Contract entry: phase noise of the oscillator `opts.osc_node` names, as
/// point-major rows (frequency offset, phnoise in dBc/Hz).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const scratch = ctx.scratch_allocator;
    const n: usize = ctx.circuit.n;
    const nf = 2 * @as(usize, opts.n_harmonics) + 1;
    const x_hat = try scratch.alloc(f64, 2 * n * nf);
    defer scratch.free(x_hat);
    const y = x_hat[n * nf ..];
    const st = try hb.solveOscillator(ctx.circuit, ctx.x_op, x_hat[0 .. n * nf], y, opts.hb(), scratch);
    if (!st.status.converged) return error.HbDidNotConverge;

    const n_points: usize = opts.sweep.count();
    const buf = try scratch.alloc(f64, 3 * n_points);
    defer scratch.free(buf);
    const freqs = buf[0..n_points];
    const nlp = buf[n_points..][0..n_points];
    const pac = buf[2 * n_points ..];
    opts.sweep.fill(freqs, pac);
    if (opts.method != .nlp) {
        const srcs = try ctx.circuit.collectNoiseSources(ctx.x_op, scratch);
        defer scratch.free(srcs);
        try periodic(ctx.circuit, x_hat[0 .. n * nf], st.f0, srcs, freqs, pac, opts, scratch);
        for (pac) |*l| l.* = 10 * std.math.log10(l.*);
    }
    if (opts.method != .pac) {
        const d = try diffusion(ctx.circuit, x_hat[0 .. n * nf], y, st.f0, pnoise.samplesFor(min_samples, nf), scratch);
        defer d.deinit(scratch);
        // HSPICE's carrierindex normalizes to harmonic k, whose phase is k
        // times the fundamental's.
        const f0 = @as(f64, @floatFromInt(opts.carrier)) * st.f0;
        const f0_sq = f0 * f0;
        for (freqs, nlp) |fm, *l| {
            const c = d.at(fm);
            l.* = 10 * std.math.log10(f0_sq * c / (std.math.pi * std.math.pi * f0_sq * f0_sq * c * c + fm * fm));
        }
    }
    const dbc = switch (opts.method) {
        .nlp => nlp,
        .pac => pac,
        .bpn => blk: {
            stitch(nlp, pac, 0.5);
            break :blk nlp;
        },
    };
    return pnoise.result(ctx.allocator, freqs, dbc, "phnoise", "Phase Noise Analysis");
}
