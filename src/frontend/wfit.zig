//! HSPICE W element [SI Ch.3]: N coupled lossy lines as the rational,
//! delay-extracted model models/wline.va runs (method of characteristics).
//!
//!     Z(f) = R0 + Rs·√f·(1 + j) + j2πf·L0      (the j term off with INCLUDERSIMAG=NO)
//!     Y(f) = G0 + Gd·f / √(1 + (f/fgd)²) + j2πf·C0   (fgd = 0: Gd·f)
//!
//! One constant real modal transform diagonalizes L0 and C0 (the lossless
//! modes). Per mode, with z and y the diagonal of the transformed Z and Y,
//! the characteristic admittance Yc = √(y/z) (scaled by the mode's lossless
//! Z0 to O(1)) and the propagation P = e^(−γd + sτ), γ = √(zy), with the
//! lossless delay τ taken out, are vector fitted (sparam.zig) on a log grid
//! over the mode's loss and delay frequencies, then written as second-order
//! sections. Exact for N = 1 and for any coupling whose R, G, Rs and Gd
//! share L0·C0's modes (a symmetric pair); otherwise the off-diagonal modal
//! loss is dropped.
//!
//! Data (DOD): every table is fixed size N ≤ 4 on the stack except the
//! sections, which live in the build arena and die after the build.

const std = @import("std");
const sparam = @import("sparam.zig");
const Cx = std.math.Complex(f64);
const Allocator = std.mem.Allocator;

/// Maximum conductor count, the largest models/wline_N.va.
pub const max_n = 4;
const Mat = [max_n][max_n]f64;

/// Per-unit-length matrices (full, symmetric) of an N-conductor line.
pub const Rlgc = struct {
    /// Conductor count, 1 to `max_n`; entries past it are ignored.
    n: usize,
    /// L0, H/m. Positive definite.
    l: Mat = @splat(@splat(0)),
    /// C0, F/m. Positive definite.
    c: Mat = @splat(@splat(0)),
    /// R0, Ω/m.
    r: Mat = @splat(@splat(0)),
    /// G0, S/m.
    g: Mat = @splat(@splat(0)),
    /// Skin-effect resistance, Ω/(m·√Hz).
    rs: Mat = @splat(@splat(0)),
    /// Dielectric loss, S/(m·Hz).
    gd: Mat = @splat(@splat(0)),
    /// Dielectric-loss cutoff in Hz; 0 keeps Gd·f linear.
    fgd: f64 = 0,
    /// INCLUDERSIMAG: the skin effect's reactive half.
    rs_imag: bool = true,
    /// Line length in meters.
    length: f64,

    /// Z(jω) and Y(jω) per unit length at `f` Hz (f ≥ 0: √f), over the
    /// whole `max_n` square.
    pub fn zy(self: Rlgc, f: f64) struct { z: [max_n][max_n]Cx, y: [max_n][max_n]Cx } {
        var out: @TypeOf(self.zy(0)) = undefined;
        const sf = @sqrt(f);
        const fd = if (self.fgd > 0) f / @sqrt(1 + (f / self.fgd) * (f / self.fgd)) else f;
        const w = 2 * std.math.pi * f;
        for (0..max_n) |i| for (0..max_n) |j| {
            const skin = self.rs[i][j] * sf;
            out.z[i][j] = .{ .re = self.r[i][j] + skin, .im = (if (self.rs_imag) skin else 0) + w * self.l[i][j] };
            out.y[i][j] = .{ .re = self.g[i][j] + self.gd[i][j] * fd, .im = w * self.c[i][j] };
        };
        return out;
    }
};

/// d + Σ_k (num_k[1]·s + num_k[0]) / (den_k[2]·s² + den_k[1]·s + den_k[0]).
pub const Rational = struct {
    /// Direct term.
    d: f64,
    /// Section k's `.{ num0, num1 }`, parallel to `den`.
    num: []const [2]f64,
    /// Section k's `.{ den0, den1, den2 }`; den2 = 0 for a first-order one.
    den: []const [3]f64,
    /// RMS over the fit grid of the error relative to each sample (of Yc,
    /// and of 1 − P for the propagation).
    rel_err: f64,
};

/// One propagation mode.
pub const Mode = struct {
    /// Lossless characteristic impedance, Ω in modal units: Yc = yc/z0.
    z0: f64,
    /// Lossless delay, s.
    tau: f64,
    /// Z0·Yc(s), dimensionless.
    yc: Rational,
    /// e^(−γ(s)·d + s·τ).
    h: Rational,
};

/// A fitted line: modal voltages vm = Tv⁻¹·v = Tiᵀ·v, phase currents
/// i = Ti·im, modal currents im = Tvᵀ·i.
pub const Line = struct {
    /// The conductor count it was fitted for.
    n: usize,
    /// Voltage modal transform; each column scaled to unit max |entry|.
    tv: Mat = @splat(@splat(0)),
    /// Current modal transform, Ti = Tv⁻ᵀ.
    ti: Mat = @splat(@splat(0)),
    /// The first `n` are set.
    modes: [max_n]Mode = undefined,
    /// Lowest and highest fitted frequency, Hz (the grid also holds 0).
    /// Below the lowest, a lossy mode levels off to finite DC values.
    band: [2]f64 = .{ 0, 0 },
};

/// NotPositiveDefinite: L0 or C0 is not (a lossless line needs both).
pub const Error = sparam.Error || error{NotPositiveDefinite};

/// Fits `p`'s modes with at most `sections` second-order sections per
/// function; allocates the section tables, and the fit scratch, in `arena`.
/// Fails when L0 or C0 is not positive definite. Asserts that `p.n` is 1
/// to `max_n`.
pub fn fitLine(arena: Allocator, p: Rlgc, sections: usize) Error!Line {
    const n = p.n;
    std.debug.assert(n >= 1 and n <= max_n);
    // C = FᵀF, F upper; F·L·Fᵀ = Q·Λ·Qᵀ. Then Tv = F⁻¹Q, Ti = FᵀQ and
    // Tv⁻¹·L·Ti = Λ, Ti⁻¹·C·Tv = I. Columns are then scaled to unit max.
    var f: Mat = @splat(@splat(0));
    for (0..n) |j| for (0..j + 1) |i| {
        var v = p.c[i][j];
        for (0..i) |k| v -= f[k][i] * f[k][j];
        if (i == j) {
            if (!(v > 0)) return error.NotPositiveDefinite;
            f[i][i] = @sqrt(v);
        } else f[i][j] = v / f[i][i];
    };
    var m: [max_n * max_n]f64 = undefined;
    for (0..n) |i| for (0..n) |j| {
        var v: f64 = 0;
        for (0..n) |a| for (0..n) |b| {
            v += f[i][a] * p.l[a][b] * f[j][b];
        };
        m[i * n + j] = v;
    };
    var q: [max_n * max_n]f64 = undefined;
    sparam.symEig(n, m[0 .. n * n], q[0 .. n * n]);
    var line: Line = .{ .n = n };
    const tv = &line.tv;
    for (0..n) |mi| {
        if (!(m[mi * n + mi] > 0)) return error.NotPositiveDefinite;
        // Tv column = F⁻¹·q (back substitution), Ti column = Fᵀ·q.
        var col: [max_n]f64 = undefined;
        var r = n;
        while (r > 0) {
            r -= 1;
            var v = q[r * n + mi];
            for (r + 1..n) |k| v -= f[r][k] * col[k];
            col[r] = v / f[r][r];
        }
        var big: f64 = 0;
        for (col[0..n]) |v| big = @max(big, @abs(v));
        for (0..n) |k| {
            tv[k][mi] = col[k] / big;
            var t: f64 = 0;
            for (0..k + 1) |a| t += f[a][k] * q[a * n + mi];
            line.ti[k][mi] = t * big;
        }
    }
    // Band: every mode's loss and delay corner, two decades past each side.
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = 0;
    var corners: [max_n][5]f64 = undefined;
    for (0..n) |mi| {
        const lm = modal(p.l, tv.*, line.ti, mi, .series);
        const cm = modal(p.c, tv.*, line.ti, mi, .shunt);
        const tau = p.length * @sqrt(lm * cm);
        corners[mi] = .{
            1 / tau,
            modal(p.r, tv.*, line.ti, mi, .series) / (2 * std.math.pi * lm),
            modal(p.g, tv.*, line.ti, mi, .shunt) / (2 * std.math.pi * cm),
            std.math.pow(f64, modal(p.rs, tv.*, line.ti, mi, .series) / (2 * std.math.pi * lm), 2),
            if (modal(p.gd, tv.*, line.ti, mi, .shunt) != 0) (if (p.fgd > 0) p.fgd else 1 / tau) else 0,
        };
        for (corners[mi]) |c| if (c > 0 and std.math.isFinite(c)) {
            lo = @min(lo, c);
            hi = @max(hi, c);
        };
    }
    lo /= 100;
    hi *= 100;
    line.band = .{ lo, hi };
    const per_decade = 30;
    const nf = 1 + @as(usize, @intFromFloat(@ceil(@log10(hi / lo) * per_decade)));
    const freq = try arena.alloc(f64, nf + 1);
    freq[0] = 0;
    for (freq[1..], 0..) |*o, k| o.* = lo * std.math.pow(f64, hi / lo, @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(nf - 1)));

    for (0..n) |mi| {
        const lm = modal(p.l, tv.*, line.ti, mi, .series);
        const cm = modal(p.c, tv.*, line.ti, mi, .shunt);
        const z0 = @sqrt(lm / cm);
        const tau = p.length * @sqrt(lm * cm);
        // A lossy mode with no R0 or no G0 has Yc ~ √s (or 1/√s) toward
        // DC, which no rational function follows. It gets the R0 or G0 that
        // puts that corner at `lo`, so Yc and P level off to finite DC
        // values whose ratio still gives the series resistance. ponytail:
        // this costs ~1e-5 of P in band (G·Z0·l/2 of extra loss); a corner
        // further down needs a wider band and more sections.
        const r0 = modal(p.r, tv.*, line.ti, mi, .series);
        const g0 = modal(p.g, tv.*, line.ti, mi, .shunt);
        const lossy = r0 != 0 or g0 != 0 or modal(p.rs, tv.*, line.ti, mi, .series) != 0 or modal(p.gd, tv.*, line.ti, mi, .shunt) != 0;
        const r_floor = if (lossy) @max(0, 2 * std.math.pi * lo * lm - r0) else 0;
        const g_floor = if (lossy) @max(0, 2 * std.math.pi * lo * cm - g0) else 0;
        const yc_re = try arena.alloc(f64, freq.len);
        const yc_im = try arena.alloc(f64, freq.len);
        const h_re = try arena.alloc(f64, freq.len);
        const h_im = try arena.alloc(f64, freq.len);
        for (freq, 0..) |fr, k| {
            const zy = p.zy(fr);
            const z = modalCx(zy.z, tv.*, line.ti, mi, .series).add(.{ .re = r_floor, .im = 0 });
            const y = modalCx(zy.y, tv.*, line.ti, mi, .shunt).add(.{ .re = g_floor, .im = 0 });
            const gamma = std.math.complex.sqrt(z.mul(y));
            // Yc = y/γ (= √(y/z) on γ's branch); 1/Z0 at a lossless DC.
            const yc = if (y.magnitude() == 0) Cx{ .re = 1 / z0, .im = 0 } else y.div(gamma);
            const h = std.math.complex.exp((Cx{ .re = -p.length, .im = 0 }).mul(gamma).add(.{ .re = 0, .im = 2 * std.math.pi * fr * tau }));
            yc_re[k] = yc.re * z0;
            yc_im[k] = yc.im * z0;
            // 1 − P: relative weighting then keeps the small low-frequency
            // loss, whose ratio to Yc is the line's DC resistance.
            h_re[k] = 1 - h.re;
            h_im[k] = -h.im;
        }
        const opt: sparam.FitOptions = .{ .max_order = 2 * sections, .relative = true };
        var yc_fit = try sparam.fit(arena, .{ .ports = 1, .freq = freq, .re = yc_re, .im = yc_im }, opt);
        _ = try sparam.enforcePassivity(arena, .{ .ports = 1, .freq = freq, .re = yc_re, .im = yc_im }, &yc_fit);
        // P = 1 − (the fit of 1 − P).
        var h_fit = try sparam.fit(arena, .{ .ports = 1, .freq = freq, .re = h_re, .im = h_im }, opt);
        for (h_fit.res) |*r| r.* = r.neg();
        h_fit.d[0] = 1 - h_fit.d[0];
        line.modes[mi] = .{ .z0 = z0, .tau = tau, .yc = try rational(arena, yc_fit), .h = try rational(arena, h_fit) };
    }
    return line;
}

fn rational(arena: Allocator, f: sparam.Fit) Error!Rational {
    const s = try sparam.sections(arena, f);
    return .{ .d = f.d[0], .num = s.num, .den = s.den, .rel_err = f.rel_err };
}

/// Diagonal entry `mi` of Tv⁻¹·X·Ti (series) or Ti⁻¹·X·Tv (shunt), with
/// Tv⁻¹ = Tiᵀ and Ti⁻¹ = Tvᵀ.
fn modal(x: Mat, tv: Mat, ti: Mat, mi: usize, comptime kind: enum { series, shunt }) f64 {
    const t = if (kind == .series) ti else tv;
    var v: f64 = 0;
    for (0..max_n) |a| for (0..max_n) |b| {
        v += t[a][mi] * x[a][b] * t[b][mi];
    };
    return v;
}

fn modalCx(x: [max_n][max_n]Cx, tv: Mat, ti: Mat, mi: usize, comptime kind: enum { series, shunt }) Cx {
    const t = if (kind == .series) ti else tv;
    var v: Cx = .{ .re = 0, .im = 0 };
    for (0..max_n) |a| for (0..max_n) |b| {
        v = v.add(x[a][b].mul(.{ .re = t[a][mi] * t[b][mi], .im = 0 }));
    };
    return v;
}

const testing = std.testing;

/// The fitted line's exact response check: Yc and P at f against the fit.
fn evalRational(r: Rational, f: f64) Cx {
    const s: Cx = .{ .re = 0, .im = 2 * std.math.pi * f };
    var y: Cx = .{ .re = r.d, .im = 0 };
    for (r.num, r.den) |nm, dn| {
        const num: Cx = .{ .re = nm[0], .im = s.im * nm[1] };
        const den = (Cx{ .re = dn[0], .im = s.im * dn[1] }).add(s.mul(s).mul(.{ .re = dn[2], .im = 0 }));
        y = y.add(num.div(den));
    }
    return y;
}

test "a lossless line fits exactly with no poles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p: Rlgc = .{ .n = 1, .length = 0.1 };
    p.l[0][0] = 250e-9;
    p.c[0][0] = 100e-12;
    const line = try fitLine(arena_state.allocator(), p, 12);
    try testing.expectApproxEqRel(@as(f64, 50), line.modes[0].z0, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 0.5e-9), line.modes[0].tau, 1e-12);
    try testing.expectEqual(@as(usize, 0), line.modes[0].yc.num.len);
    try testing.expectApproxEqAbs(@as(f64, 1), line.modes[0].h.d, 1e-12);
}

test "a lossy line with skin effect fits Yc and P over the band" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p: Rlgc = .{ .n = 1, .length = 0.2, .fgd = 0 };
    p.l[0][0] = 300e-9;
    p.c[0][0] = 120e-12;
    p.r[0][0] = 5;
    p.rs[0][0] = 1e-3;
    const line = try fitLine(arena_state.allocator(), p, 12);
    const md = line.modes[0];
    try testing.expect(md.yc.rel_err < 1e-3 and md.h.rel_err < 1e-3);
    // Spot check at 1 GHz against the exact functions.
    const zy = p.zy(1e9);
    const gamma = std.math.complex.sqrt(zy.z[0][0].mul(zy.y[0][0]));
    const yc = zy.y[0][0].div(gamma).mul(.{ .re = md.z0, .im = 0 });
    try testing.expect(evalRational(md.yc, 1e9).sub(yc).magnitude() < 1e-3);
}

test "a symmetric coupled pair splits into even and odd modes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var p: Rlgc = .{ .n = 2, .length = 10 };
    p.l = .{ .{ 9.13e-9, 3.3e-9, 0, 0 }, .{ 3.3e-9, 9.13e-9, 0, 0 }, @splat(0), @splat(0) };
    p.c = .{ .{ 0.365e-12, -0.09e-12, 0, 0 }, .{ -0.09e-12, 0.365e-12, 0, 0 }, @splat(0), @splat(0) };
    p.r[0][0] = 0.2;
    p.r[1][1] = 0.2;
    const line = try fitLine(arena_state.allocator(), p, 12);
    // Each Tv column is ±[1, ±1].
    for (0..2) |mi| try testing.expectApproxEqAbs(@abs(line.tv[0][mi]), @abs(line.tv[1][mi]), 1e-9);
    const taus = [2]f64{ line.modes[0].tau, line.modes[1].tau };
    const even = 10 * @sqrt((9.13e-9 + 3.3e-9) * (0.365e-12 - 0.09e-12));
    const odd = 10 * @sqrt((9.13e-9 - 3.3e-9) * (0.365e-12 + 0.09e-12));
    try testing.expect(@abs(@max(taus[0], taus[1]) - @max(even, odd)) < 1e-15);
    try testing.expect(@abs(@min(taus[0], taus[1]) - @min(even, odd)) < 1e-15);
}

test "fitLine refuses an L0 or C0 that is not positive definite" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p: Rlgc = .{ .n = 1, .length = 1 };
    p.l[0][0] = 250e-9;
    try testing.expectError(error.NotPositiveDefinite, fitLine(arena, p, 4)); // C0 = 0
    p.c[0][0] = 100e-12;
    p.l[0][0] = 0;
    try testing.expectError(error.NotPositiveDefinite, fitLine(arena, p, 4));
    // Indefinite coupled C0: |c12| > c11.
    var q: Rlgc = .{ .n = 2, .length = 1 };
    q.l = .{ .{ 9e-9, 3e-9, 0, 0 }, .{ 3e-9, 9e-9, 0, 0 }, @splat(0), @splat(0) };
    q.c = .{ .{ 0.3e-12, 0.5e-12, 0, 0 }, .{ 0.5e-12, 0.3e-12, 0, 0 }, @splat(0), @splat(0) };
    try testing.expectError(error.NotPositiveDefinite, fitLine(arena, q, 4));
}

test "Rlgc.zy: DC is R0 and G0, Gd rolls off at fgd, INCLUDERSIMAG drops the skin reactance" {
    var p: Rlgc = .{ .n = 1, .length = 1, .fgd = 1e9, .rs_imag = false };
    p.r[0][0] = 2;
    p.l[0][0] = 1e-6;
    p.c[0][0] = 1e-12;
    p.g[0][0] = 1e-3;
    p.rs[0][0] = 1e-3;
    p.gd[0][0] = 1e-9;
    const dc = p.zy(0);
    try testing.expectEqual(Cx{ .re = 2, .im = 0 }, dc.z[0][0]);
    try testing.expectEqual(Cx{ .re = 1e-3, .im = 0 }, dc.y[0][0]);
    const at = p.zy(1e9);
    const w = 2 * std.math.pi * 1e9;
    try testing.expectApproxEqRel(@as(f64, 2 + 1e-3 * @sqrt(1e9)), at.z[0][0].re, 1e-12);
    try testing.expectApproxEqRel(w * 1e-6, at.z[0][0].im, 1e-12);
    try testing.expectApproxEqRel(1e-3 + 1e-9 * 1e9 / @sqrt(2.0), at.y[0][0].re, 1e-12);
    p.rs_imag = true;
    try testing.expectApproxEqRel(w * 1e-6 + 1e-3 * @sqrt(1e9), p.zy(1e9).z[0][0].im, 1e-12);
}
