//! Oscillator phase noise by the perturbation projection vector (PPV;
//! Demir, Mehrotra and Roychowdhury, IEEE TCAS-I 47(5), 2000), HSPICE's
//! `.phasenoise` METHOD=0.
//!
//! A small current b(t) injected into an oscillator shifts its phase, not
//! its amplitude, in the long run: x(t) ~ x_s(t + a(t)) with
//! da/dt = v(t)^T b(t). v(t) is the PPV. White noise sources make a(t) a
//! random walk of diffusion constant
//!   c = (1/T) integral_0^T sum_s (v_p(t) - v_n(t))^2 S_s(t)/2 dt
//! (S_s the one-sided current PSD of source s between nodes p and n), and
//! the single-sideband phase noise at offset f_m is the Lorentzian
//!   L(f_m) = f0^2 c / (pi^2 f0^4 c^2 + f_m^2).
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

/// Diffusion constant c, in s, of the oscillator whose HB solution is
/// `x_hat` at `f0`, from the normalized left null vector `y`
/// (`hb.solveSpectrum`'s `ppv`, overwritten). Samples both on `n_samples`
/// points. White source densities only; see `run`.
pub fn diffusion(ckt: *root.Circuit, x_hat: []const f64, y: []f64, f0: f64, n_samples: usize, allocator: std.mem.Allocator) !f64 {
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

    var sum: f64 = 0;
    for (0..n_samples) |k| {
        const v = ppv.state(k, n);
        const srcs = try ckt.collectNoiseSources(orb.state(k, n), allocator);
        defer allocator.free(srcs);
        for (srcs) |src| {
            const vp = if (src.node_p != root.GROUND) v[src.node_p] else 0;
            const vn = if (src.node_n != root.GROUND) v[src.node_n] else 0;
            sum += (vp - vn) * (vp - vn) * src.white / 2;
        }
    }
    return sum / @as(f64, @floatFromInt(n_samples));
}

/// Contract entry: phase noise of the oscillator `opts.osc_node` names, as
/// point-major rows (frequency offset, phnoise in dBc/Hz).
// ponytail: white sources only. A flicker source needs Demir's colored-noise
// extension, whose spectrum is no longer a single Lorentzian; its 1/f part
// is dropped here.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const scratch = ctx.scratch_allocator;
    const n: usize = ctx.circuit.n;
    const nf = 2 * @as(usize, opts.n_harmonics) + 1;
    const x_hat = try scratch.alloc(f64, 2 * n * nf);
    defer scratch.free(x_hat);
    const y = x_hat[n * nf ..];
    const st = try hb.solveOscillator(ctx.circuit, ctx.x_op, x_hat[0 .. n * nf], y, opts.hb(), scratch);
    if (!st.status.converged) return error.HbDidNotConverge;
    const c = try diffusion(ctx.circuit, x_hat[0 .. n * nf], y, st.f0, pnoise.samplesFor(min_samples, nf), scratch);

    const n_points: usize = opts.sweep.count();
    const freqs = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(freqs);
    const dbc = freqs[n_points..];
    var sw = opts.sweep.iter();
    var i: usize = 0;
    const f0_sq = st.f0 * st.f0;
    while (sw.next()) |fm| : (i += 1) {
        freqs[i] = fm;
        dbc[i] = 10 * std.math.log10(f0_sq * c / (std.math.pi * std.math.pi * f0_sq * f0_sq * c * c + fm * fm));
    }
    return pnoise.result(ctx.allocator, freqs[0..n_points], dbc, "phnoise", "Phase Noise Analysis");
}
