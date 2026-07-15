//! HSPICE S-element data [SI Ch.2]: a Touchstone 1.0 file read into
//! admittance samples, and the rational model every analysis runs.
//!
//! Y = Z0⁻¹·(I − S)(I + S)⁻¹ at each data point, then vector fitting
//! (Gustavsen and Semlyen, IEEE Trans. Power Delivery 14(3), 1999) with
//! poles common to every entry and the fast column-wise pole identification
//! (Deschrijver et al., IEEE MWCL 18(6), 2008), then passivity by residue
//! perturbation: every violation of λ_min(Re Y(jω)) ≥ 0 on a dense grid
//! becomes a linear constraint, and the minimum-norm change of the fitted
//! response over the data points that meets them is applied, repeated until
//! the model is passive. `sections` turns the result into the second-order
//! sections models/sparam_1.va runs through `laplace_nd`. HSPICE's option for this is
//! RATIONAL_FUNC=1; its default is IFFT convolution. The W element's fitter
//! (wfit.zig) reuses `fit`, `enforcePassivity` and `sections`.
//!
//! Data (DOD): samples are SoA over (entry, frequency), entry-major, entry
//! e = i·P + j; the fit is one pole list and per-entry residues and direct
//! terms. Everything lives in the parse arena and dies after the build.
//! Least-squares matrices are column-major (`a[c * m + r]` for m rows):
//! Householder QR reads and updates whole columns, so every inner loop is
//! a contiguous dot or axpy (`core.numerics`, stdpp SIMD) instead of a
//! stride-n walk that touches a new cache line per element.

const std = @import("std");
const core = @import("core");
const eigen = core.eigen;
const numerics = core.numerics;
const Cx = std.math.Complex(f64);
const Allocator = std.mem.Allocator;

/// Admittance samples of a P-port.
pub const Network = struct {
    /// P, 1 to 64 from `parseTouchstone`; the entry count is P².
    ports: usize,
    /// Hz, strictly ascending.
    freq: []const f64,
    /// Y entry e at frequency k: `re[e * freq.len + k]`, `im[...]`.
    re: []const f64,
    /// Imaginary parts, laid out as `re`.
    im: []const f64,

    /// Entry `e` (= i·P + j) at frequency index `k`.
    pub fn at(self: Network, e: usize, k: usize) Cx {
        return .{ .re = self.re[e * self.freq.len + k], .im = self.im[e * self.freq.len + k] };
    }
};

/// InvalidTouchstone: a malformed or Touchstone 2.0 file, or a fit with no
/// usable data; SingularSParameters: I + S (or Z) is singular at a point.
pub const Error = error{ OutOfMemory, InvalidTouchstone, SingularSParameters };

/// Parses a Touchstone 1.0 file of `ports` ports (the `.sNp` extension's N)
/// into admittance samples. The option line `# <unit> <S|Y|Z> <MA|DB|RI> R
/// <z0>` defaults to `GHz S MA R 50`; Y and Z data are normalized to R, as
/// version 1.0 writes them. A two-port's entries come in the column order
/// N11 N21 N12 N22; the noise block after a 2-port's data (frequencies
/// starting over) is skipped. The tables, and the parse scratch, live in
/// `arena`.
pub fn parseTouchstone(arena: Allocator, bytes: []const u8, ports: usize) Error!Network {
    if (ports == 0 or ports > 64) return error.InvalidTouchstone;
    var unit: f64 = 1e9;
    var kind: u8 = 's';
    var format: enum { ma, db, ri } = .ma;
    var z0: f64 = 50;
    var nums: std.ArrayList(f64) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '!') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') return error.InvalidTouchstone; // Touchstone 2.0 keywords
        var it = std.mem.tokenizeAny(u8, line, " \t");
        if (line[0] == '#') {
            _ = it.next();
            while (it.next()) |t| {
                var buf: [8]u8 = undefined;
                if (t.len > buf.len) return error.InvalidTouchstone;
                const w = std.ascii.lowerString(&buf, t);
                if (std.mem.eql(u8, w, "hz")) unit = 1 else if (std.mem.eql(u8, w, "khz")) unit = 1e3 else if (std.mem.eql(u8, w, "mhz")) unit = 1e6 else if (std.mem.eql(u8, w, "ghz")) unit = 1e9 else if (std.mem.eql(u8, w, "s") or std.mem.eql(u8, w, "y") or std.mem.eql(u8, w, "z")) kind = w[0] else if (std.mem.eql(u8, w, "ma")) format = .ma else if (std.mem.eql(u8, w, "db")) format = .db else if (std.mem.eql(u8, w, "ri")) format = .ri else if (std.mem.eql(u8, w, "r")) {
                    z0 = std.fmt.parseFloat(f64, it.next() orelse return error.InvalidTouchstone) catch return error.InvalidTouchstone;
                } else return error.InvalidTouchstone;
            }
            continue;
        }
        while (it.next()) |t| try nums.append(arena, std.fmt.parseFloat(f64, t) catch return error.InvalidTouchstone);
    }
    if (!(z0 > 0)) return error.InvalidTouchstone;
    const pp = ports * ports;
    const stride = 1 + 2 * pp;
    var nf: usize = 0;
    while ((nf + 1) * stride <= nums.items.len) : (nf += 1) {
        const f = nums.items[nf * stride];
        if (nf > 0 and !(f > nums.items[(nf - 1) * stride])) break;
    }
    if (nf == 0) return error.InvalidTouchstone;
    const freq = try arena.alloc(f64, nf);
    const re = try arena.alloc(f64, pp * nf);
    const im = try arena.alloc(f64, pp * nf);
    const m = try arena.alloc(Cx, 2 * pp);
    for (0..nf) |k| {
        const row = nums.items[k * stride ..][0..stride];
        freq[k] = row[0] * unit;
        if (!std.math.isFinite(freq[k]) or freq[k] < 0) return error.InvalidTouchstone;
        for (0..pp) |q| {
            const a = row[1 + 2 * q];
            const b = row[2 + 2 * q];
            const v: Cx = switch (format) {
                .ri => .{ .re = a, .im = b },
                .ma, .db => blk: {
                    const mag = if (format == .db) std.math.pow(f64, 10, a / 20) else a;
                    const ang = b * std.math.pi / 180;
                    break :blk .{ .re = mag * @cos(ang), .im = mag * @sin(ang) };
                },
            };
            // Two-port files list N11 N21 N12 N22.
            const e = if (ports == 2) (q % 2) * 2 + q / 2 else q;
            m[e] = v;
        }
        const y = m[pp..];
        switch (kind) {
            's' => try sToY(ports, m[0..pp], y, z0),
            'y' => for (y, m[0..pp]) |*o, v| {
                o.* = v.mul(.{ .re = 1 / z0, .im = 0 });
            },
            else => {
                for (m[0..pp]) |*v| v.* = v.mul(.{ .re = z0, .im = 0 });
                if (!invert(ports, m[0..pp], y)) return error.SingularSParameters;
            },
        }
        for (0..pp) |e| {
            re[e * nf + k] = y[e].re;
            im[e * nf + k] = y[e].im;
        }
    }
    return .{ .ports = ports, .freq = freq, .re = re, .im = im };
}

/// Y = Z0⁻¹·(I − S)(I + S)⁻¹ with one real reference impedance.
fn sToY(p: usize, s: []const Cx, y: []Cx, z0: f64) Error!void {
    var buf_a: [64 * 64]Cx = undefined;
    var buf_b: [64 * 64]Cx = undefined;
    const a = buf_a[0 .. p * p];
    const b = buf_b[0 .. p * p];
    for (0..p) |i| for (0..p) |j| {
        const id: f64 = if (i == j) 1 else 0;
        a[i * p + j] = s[i * p + j].add(.{ .re = id, .im = 0 });
        b[i * p + j] = (Cx{ .re = id, .im = 0 }).sub(s[i * p + j]);
    };
    // (I − S) and (I + S)⁻¹ commute, so this is (I + S)⁻¹(I − S).
    if (!solve(p, a, b)) return error.SingularSParameters;
    for (y, b) |*o, v| o.* = v.mul(.{ .re = 1 / z0, .im = 0 });
}

/// Solves A·X = B in place (B becomes X), Gauss-Jordan with partial
/// pivoting; false when A is singular.
fn solve(p: usize, a: []Cx, b: []Cx) bool {
    for (0..p) |c| {
        var piv = c;
        for (c + 1..p) |r| if (a[r * p + c].magnitude() > a[piv * p + c].magnitude()) {
            piv = r;
        };
        if (a[piv * p + c].magnitude() == 0) return false;
        for (0..p) |j| {
            std.mem.swap(Cx, &a[piv * p + j], &a[c * p + j]);
            std.mem.swap(Cx, &b[piv * p + j], &b[c * p + j]);
        }
        const inv = (Cx{ .re = 1, .im = 0 }).div(a[c * p + c]);
        for (0..p) |j| {
            a[c * p + j] = a[c * p + j].mul(inv);
            b[c * p + j] = b[c * p + j].mul(inv);
        }
        for (0..p) |r| {
            if (r == c) continue;
            const f = a[r * p + c];
            for (0..p) |j| {
                a[r * p + j] = a[r * p + j].sub(f.mul(a[c * p + j]));
                b[r * p + j] = b[r * p + j].sub(f.mul(b[c * p + j]));
            }
        }
    }
    return true;
}

fn invert(p: usize, a: []Cx, out: []Cx) bool {
    for (0..p) |i| for (0..p) |j| {
        out[i * p + j] = .{ .re = if (i == j) 1 else 0, .im = 0 };
    };
    return solve(p, a, out);
}

// ---------------------------------------------------------------------------
// Rational fit
// ---------------------------------------------------------------------------

/// Y(s) ≈ d_e + Σ_k r_ek/(s − p_k) (+ the conjugate term for a complex
/// pole), common poles. A complex pole appears once, with Im p > 0.
pub const Fit = struct {
    /// rad/s, all with Re p < 0 (a pole is reflected into the left half
    /// plane when relocation lands it right of the axis).
    poles: []const Cx,
    /// `res[e * poles.len + k]`; real for a real pole.
    res: []Cx,
    /// Direct term per entry, `d[e]`.
    d: []f64,
    /// RMS error over the data relative to max |Y|.
    rel_err: f64 = 0,

    /// The fitted response of entry `e` at s = jω.
    pub fn eval(self: Fit, e: usize, omega: f64) Cx {
        const s: Cx = .{ .re = 0, .im = omega };
        var y: Cx = .{ .re = self.d[e], .im = 0 };
        const kk = self.poles.len;
        for (self.poles, self.res[e * kk ..][0..kk]) |p, r| {
            y = y.add(r.div(s.sub(p)));
            if (p.im != 0) y = y.add(r.conjugate().div(s.sub(p.conjugate())));
        }
        return y;
    }

    /// Real state count of the realization: one per real pole, two per pair.
    pub fn order(self: Fit) usize {
        return realOrder(self.poles);
    }
};

/// A fit as real sections Σ_k (b1·s + b0)/(a2·s² + a1·s + a0): each
/// complex pair, or two real poles, is one second-order section (one odd
/// real pole is first order). Poles are never multiplied into one
/// polynomial, whose coefficients would be ill-conditioned.
pub const Sections = struct {
    /// Section k's denominator `.{ a0, a1, a2 }`, shared by every entry.
    den: []const [3]f64,
    /// Entry e's numerator for section k, `.{ b0, b1 }` at `num[e * den.len + k]`.
    num: []const [2]f64,
};

/// `f`'s poles and residues as `Sections`; allocates both tables in `arena`.
pub fn sections(arena: Allocator, f: Fit) Error!Sections {
    const kk = f.poles.len;
    const ne = f.d.len;
    var reals: std.ArrayList(usize) = .empty;
    var pairs: std.ArrayList(usize) = .empty;
    for (f.poles, 0..) |p, k| try (if (p.im != 0) &pairs else &reals).append(arena, k);
    const ns = pairs.items.len + (reals.items.len + 1) / 2;
    const den = try arena.alloc([3]f64, ns);
    const num = try arena.alloc([2]f64, ne * ns);
    for (pairs.items, 0..) |k, sec| {
        const p = f.poles[k];
        den[sec] = .{ p.re * p.re + p.im * p.im, -2 * p.re, 1 };
        // r/(s − p) + r̄/(s − p̄) = (2 Re r·s − 2 Re(r·p̄)) / (s² − 2 Re p·s + |p|²).
        for (0..ne) |e| {
            const r = f.res[e * kk + k];
            num[e * ns + sec] = .{ -2 * (r.re * p.re + r.im * p.im), 2 * r.re };
        }
    }
    var sec = pairs.items.len;
    var at: usize = 0;
    while (at < reals.items.len) : ({
        at += 2;
        sec += 1;
    }) {
        const k1 = reals.items[at];
        const p1 = f.poles[k1].re;
        if (at + 1 == reals.items.len) {
            den[sec] = .{ -p1, 1, 0 };
            for (0..ne) |e| num[e * ns + sec] = .{ f.res[e * kk + k1].re, 0 };
            break;
        }
        const k2 = reals.items[at + 1];
        const p2 = f.poles[k2].re;
        den[sec] = .{ p1 * p2, -(p1 + p2), 1 };
        // r1/(s − p1) + r2/(s − p2) = ((r1 + r2)·s − (r1·p2 + r2·p1)) / ((s − p1)(s − p2)).
        for (0..ne) |e| {
            const r1 = f.res[e * kk + k1].re;
            const r2 = f.res[e * kk + k2].re;
            num[e * ns + sec] = .{ -(r1 * p2 + r2 * p1), r1 + r2 };
        }
    }
    return .{ .den = den, .num = num };
}

/// The fit's options: its accuracy target and pole budget.
pub const FitOptions = struct {
    /// Target RMS error relative to max |Y| (to |Y| itself with `relative`).
    tol: f64 = 1e-6,
    /// Largest real order tried (a pair counts two). 32 fills the 16
    /// second-order sections of models/sparam_1.va and wline_1.va.
    max_order: usize = 32,
    /// Pole-relocation passes per order.
    iterations: usize = 12,
    /// Weight each sample by 1/|Y| instead of each entry by 1/max |Y|, for
    /// a response that spans decades (a line's Yc).
    relative: bool = false,
};

/// The rational fit of `net` over its data frequencies, orders 4, 8, ...
/// until `opt.tol` or `opt.max_order`, whichever comes first; the best one
/// tried is returned. An order is tried only below the frequency count,
/// so a short file gets the fit its data can determine.
/// Fails with InvalidTouchstone when `net` has no frequency above 0.
/// Allocates every table of the result, and its scratch, in `arena`.
pub fn fit(arena: Allocator, net: Network, opt: FitOptions) Error!Fit {
    if (net.freq.len == 0) return error.InvalidTouchstone;
    const w_max = 2 * std.math.pi * net.freq[net.freq.len - 1];
    if (!(w_max > 0)) return error.InvalidTouchstone;
    const weight = try weights(arena, net, opt.relative);
    const s = try arena.alloc(f64, net.freq.len);
    for (s, net.freq) |*o, f| o.* = 2 * std.math.pi * f / w_max;
    // Order 0 first: a constant (a lossless line's Yc) needs no poles.
    var best = try residues(arena, net, &.{}, s, w_max, weight);
    var n: usize = 4;
    // Order K's σ block is rows K+1..2K of a 2·nf-row QR, so K < nf.
    while (best.rel_err > opt.tol and n <= opt.max_order and n < net.freq.len) : (n += 4) {
        const f = try fitOrder(arena, net, n / 2, opt.iterations, w_max, weight);
        if (f.rel_err < best.rel_err) best = f;
    }
    return best;
}

/// Per-sample LS weights, `[e * freq.len + k]`: 1/max_k |Y_e| per entry, or
/// 1/|Y_e(k)| with `relative` (0 for a zero sample or entry).
fn weights(arena: Allocator, net: Network, relative: bool) Error![]f64 {
    const nf = net.freq.len;
    const w = try arena.alloc(f64, net.ports * net.ports * nf);
    for (0..net.ports * net.ports) |e| {
        var m: f64 = 0;
        for (0..nf) |k| m = @max(m, net.at(e, k).magnitude());
        for (0..nf) |k| {
            const a = if (relative) net.at(e, k).magnitude() else m;
            w[e * nf + k] = if (a > 0) 1 / a else 0;
        }
    }
    return w;
}

/// Vector fitting with `pairs` starting complex pairs, in s scaled by
/// `w0` so the basis is O(1); `weight` as `weights` returns it.
fn fitOrder(arena: Allocator, net: Network, pairs: usize, iterations: usize, w0: f64, weight: []const f64) Error!Fit {
    const nf = net.freq.len;
    const ne = net.ports * net.ports;
    var poles = try arena.alloc(Cx, pairs);
    // Starting poles: complex pairs log-spaced over the band, lightly damped.
    var f_min = net.freq[nf - 1];
    for (net.freq) |f| if (f > 0) {
        f_min = @min(f_min, f);
    };
    const lo = @max(f_min * 2 * std.math.pi / w0, 1e-12);
    for (poles, 0..) |*p, i| {
        const t = if (pairs == 1) 1.0 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(pairs - 1));
        const b = lo * std.math.pow(f64, 1 / lo, t);
        p.* = .{ .re = -b / 100, .im = b };
    }
    const s = try arena.alloc(f64, nf);
    for (s, net.freq) |*o, f| o.* = 2 * std.math.pi * f / w0;
    var n_used: usize = 0;
    for (0..ne) |e| n_used += @intFromBool(!std.mem.allEqual(f64, weight[e * nf ..][0..nf], 0));
    if (n_used == 0) return error.InvalidTouchstone;

    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        const kk = realOrder(poles);
        // Per entry: QR of [Φ 1 | −HΦ], keep the σ block (rows past K+1).
        const rows = 2 * nf;
        const cols = 2 * kk + 1;
        const a = try arena.alloc(f64, rows * cols);
        const rhs = try arena.alloc(f64, rows);
        // The σ blocks stacked, n_used·K rows by K columns.
        const sr = n_used * kk;
        const stack = try arena.alloc(f64, sr * kk);
        const stack_b = try arena.alloc(f64, sr);
        var used: usize = 0;
        for (0..ne) |e| {
            const we = weight[e * nf ..][0..nf];
            if (std.mem.allEqual(f64, we, 0)) continue;
            for (0..nf) |k| {
                const h = net.at(e, k).mul(.{ .re = we[k], .im = 0 });
                var col: usize = 0;
                for (poles) |p| {
                    const basis = phi(p, s[k]);
                    for (basis[0..if (p.im != 0) 2 else 1]) |bv| {
                        a[col * rows + 2 * k] = bv.re * we[k];
                        a[col * rows + 2 * k + 1] = bv.im * we[k];
                        const hb = h.mul(bv).neg();
                        a[(kk + 1 + col) * rows + 2 * k] = hb.re;
                        a[(kk + 1 + col) * rows + 2 * k + 1] = hb.im;
                        col += 1;
                    }
                }
                a[kk * rows + 2 * k] = we[k];
                a[kk * rows + 2 * k + 1] = 0;
                rhs[2 * k] = h.re;
                rhs[2 * k + 1] = h.im;
            }
            householder(rows, cols, a, rhs);
            for (0..kk) |c| @memcpy(stack[c * sr + used * kk ..][0..kk], a[(kk + 1 + c) * rows + kk + 1 ..][0..kk]);
            @memcpy(stack_b[used * kk ..][0..kk], rhs[kk + 1 ..][0..kk]);
            used += 1;
        }
        const ct = try arena.alloc(f64, kk);
        leastSquares(sr, kk, stack, stack_b, ct);
        // New poles: the zeros of σ = eig(A − b·c̃ᵀ).
        const h = try arena.alloc(f64, kk * kk);
        @memset(h, 0);
        var at: usize = 0;
        for (poles) |p| {
            if (p.im != 0) {
                h[at * kk + at] = p.re;
                h[at * kk + at + 1] = p.im;
                h[(at + 1) * kk + at] = -p.im;
                h[(at + 1) * kk + at + 1] = p.re;
                for (0..kk) |c| h[at * kk + c] -= 2 * ct[c];
                at += 2;
            } else {
                h[at * kk + at] = p.re;
                for (0..kk) |c| h[at * kk + c] -= ct[c];
                at += 1;
            }
        }
        const ev = try arena.alloc(core.numerics.Complex, kk);
        const got = eigen.eigenvalues(kk, h, ev, 1e-14, 60 * @as(u32, @intCast(kk)));
        if (!got.converged or got.count != kk) break;
        poles = try arena.alloc(Cx, kk);
        var n: usize = 0;
        for (ev[0..got.count]) |z| {
            if (z.im < 0) continue; // the conjugate of a listed pole
            // Stable, and not so close to the axis that it rings forever.
            var p: Cx = .{ .re = -@abs(z.re), .im = z.im };
            if (p.re == 0) p.re = -1e-6 * @max(lo, @abs(p.im));
            poles[n] = p;
            n += 1;
        }
        poles = poles[0..n];
    }
    return residues(arena, net, poles, s, w0, weight);
}

/// The residues and direct terms for fixed `poles` (scaled by `w0`), by
/// weighted least squares over the data, then scaled back to rad/s.
/// `rel_err` is the weighted RMS error.
fn residues(arena: Allocator, net: Network, poles_s: []const Cx, s: []const f64, w0: f64, weight: []const f64) Error!Fit {
    const nf = net.freq.len;
    const ne = net.ports * net.ports;
    const kk = realOrder(poles_s);
    const rows = 2 * nf;
    const cols = kk + 1;
    const basis = try arena.alloc(f64, rows * cols);
    fillBasis(poles_s, s, basis);
    const res = try arena.alloc(Cx, ne * poles_s.len);
    const d = try arena.alloc(f64, ne);
    const a = try arena.alloc(f64, rows * cols);
    const b = try arena.alloc(f64, rows);
    const x = try arena.alloc(f64, cols);
    // ponytail: one QR per entry. Without `relative` every entry's weight is
    // one constant, so a single QR of the basis would serve them all.
    for (0..ne) |e| {
        const we = weight[e * nf ..][0..nf];
        for (0..cols) |c| for (0..nf) |k| {
            a[c * rows + 2 * k] = basis[c * rows + 2 * k] * we[k];
            a[c * rows + 2 * k + 1] = basis[c * rows + 2 * k + 1] * we[k];
        };
        for (0..nf) |k| {
            b[2 * k] = net.at(e, k).re * we[k];
            b[2 * k + 1] = net.at(e, k).im * we[k];
        }
        leastSquares(rows, cols, a, b, x);
        unpack(poles_s, x[0..kk], res[e * poles_s.len ..][0..poles_s.len]);
        d[e] = x[kk];
    }
    const poles = try arena.alloc(Cx, poles_s.len);
    for (poles, poles_s) |*p, q| p.* = q.mul(.{ .re = w0, .im = 0 });
    for (res) |*r| r.* = r.mul(.{ .re = w0, .im = 0 });
    var out: Fit = .{ .poles = poles, .res = res, .d = d };
    var err2: f64 = 0;
    for (0..ne) |e| for (0..nf) |k| {
        const err = out.eval(e, 2 * std.math.pi * net.freq[k]).sub(net.at(e, k)).magnitude() * weight[e * nf + k];
        err2 += err * err;
    };
    out.rel_err = @sqrt(err2 / @as(f64, @floatFromInt(ne * nf)));
    return out;
}

/// Column-major real LS matrix [basis | 1] over the scaled frequencies,
/// 2·s.len rows (re, im per frequency).
fn fillBasis(poles: []const Cx, s: []const f64, a: []f64) void {
    const m = 2 * s.len;
    std.debug.assert(a.len == m * (realOrder(poles) + 1));
    for (s, 0..) |sk, k| {
        var col: usize = 0;
        for (poles) |p| {
            const bv = phi(p, sk);
            for (bv[0..if (p.im != 0) 2 else 1]) |v| {
                a[col * m + 2 * k] = v.re;
                a[col * m + 2 * k + 1] = v.im;
                col += 1;
            }
        }
        a[col * m + 2 * k] = 1;
        a[col * m + 2 * k + 1] = 0;
    }
}

/// Real basis coefficients to complex residues: a pair's (c1, c2) is
/// c1 + j·c2 at the pole with Im p > 0.
fn unpack(poles: []const Cx, x: []const f64, res: []Cx) void {
    var at: usize = 0;
    for (poles, res) |p, *r| {
        if (p.im != 0) {
            r.* = .{ .re = x[at], .im = x[at + 1] };
            at += 2;
        } else {
            r.* = .{ .re = x[at], .im = 0 };
            at += 1;
        }
    }
}

fn realOrder(poles: []const Cx) usize {
    var n: usize = 0;
    for (poles) |p| n += if (p.im != 0) 2 else 1;
    return n;
}

/// The real-coefficient basis of pole `p` at s = j·w: 1/(s − p) for a real
/// pole; 1/(s − p) + 1/(s − p*) and j/(s − p) − j/(s − p*) for a pair.
fn phi(p: Cx, w: f64) [2]Cx {
    const s: Cx = .{ .re = 0, .im = w };
    const one: Cx = .{ .re = 1, .im = 0 };
    const a = one.div(s.sub(p));
    if (p.im == 0) return .{ a, .{ .re = 0, .im = 0 } };
    const b = one.div(s.sub(p.conjugate()));
    const j: Cx = .{ .re = 0, .im = 1 };
    return .{ a.add(b), j.mul(a.sub(b)) };
}

/// In-place Householder QR of the column-major m×n `a`, applied to `b` as
/// well: afterwards `a`'s upper triangle is R, the rest is zero, and `b` is
/// Qᵀb. With m < n the columns past m are only reflected.
fn householder(m: usize, n: usize, a: []f64, b: []f64) void {
    std.debug.assert(a.len >= m * n and b.len >= m);
    for (0..@min(n, m)) |c| {
        // v = (v0, tail); H = I − 2vvᵀ/(vᵀv).
        const col = a[c * m + c .. (c + 1) * m];
        const tail = col[1..];
        const tail2 = numerics.dot(tail, tail);
        const norm = @sqrt(col[0] * col[0] + tail2);
        if (norm == 0) continue;
        const alpha = if (col[0] > 0) -norm else norm;
        const v0 = col[0] - alpha;
        const vtv = v0 * v0 + tail2;
        if (vtv == 0) continue;
        for (c + 1..n) |j| reflect(a[j * m + c .. (j + 1) * m], v0, tail, vtv);
        reflect(b[c..m], v0, tail, vtv);
        col[0] = alpha;
        @memset(tail, 0);
    }
}

/// w −= 2·v·(vᵀw)/(vᵀv) for v = (v0, tail), w.len = 1 + tail.len.
fn reflect(w: []f64, v0: f64, tail: []const f64, vtv: f64) void {
    const f = 2 * (v0 * w[0] + numerics.dot(tail, w[1..])) / vtv;
    w[0] -= f * v0;
    numerics.axpy(w[1..], -f, tail);
}

/// min ‖A·x − b‖ for column-major m×n `a` (m ≥ n; destroyed, as is `b`),
/// with column scaling for conditioning and a zero for a null column.
fn leastSquares(m: usize, n: usize, a: []f64, b: []f64, x: []f64) void {
    std.debug.assert(m >= n and x.len == n);
    // `x` holds each column's scale until its solution component replaces it.
    for (x, 0..) |*s, c| {
        const col = a[c * m ..][0..m];
        const norm2 = numerics.dot(col, col);
        s.* = if (norm2 > 0) 1 / @sqrt(norm2) else 0;
        numerics.scale(col, s.*, col);
    }
    householder(m, n, a, b);
    // Column-oriented back substitution: each solved component is removed
    // from the rows above it with one contiguous axpy down its column.
    var c = n;
    while (c > 0) {
        c -= 1;
        const col = a[c * m ..][0 .. c + 1];
        const y = if (@abs(col[c]) > 1e-14) b[c] / col[c] else 0;
        numerics.axpy(b[0..c], -y, col[0..c]);
        x[c] *= y;
    }
}

// ---------------------------------------------------------------------------
// Passivity
// ---------------------------------------------------------------------------

/// Makes `f` passive for a P-port: symmetric direct term positive
/// semidefinite and λ_min(Re Y(jω)) ≥ 0 on a dense grid, by the
/// minimum-norm residue and direct-term change (over the data points) that
/// lifts every violation to a small positive margin. Returns false when
/// 30 rounds leave a violation. `f` must be a fit of `net` (same ports);
/// its residues and direct terms change in place, its poles never. Scratch
/// lives in `arena`.
pub fn enforcePassivity(arena: Allocator, net: Network, f: *Fit) Error!bool {
    const p = net.ports;
    const ne = p * p;
    const kk = f.order();
    const npar = kk + 1;
    var ymax: f64 = 0;
    for (0..ne) |e| for (0..net.freq.len) |k| {
        ymax = @max(ymax, net.at(e, k).magnitude());
    };
    const margin = 1e-9 * ymax;
    // Objective metric: Φ's R factor over the data points (shared by entries).
    const rows = 2 * net.freq.len;
    const r_fac = try arena.alloc(f64, rows * npar);
    const s = try arena.alloc(f64, net.freq.len);
    for (s, net.freq) |*o, fr| o.* = 2 * std.math.pi * fr;
    fillBasis(f.poles, s, r_fac);
    // Work in column-normalized parameters Δ'_c = n_c·Δ_c: a residue's
    // basis column is ~1/|p| next to the direct term's 1, and R⁻¹ of the
    // unscaled basis loses the constraint to roundoff.
    const col_norm = try arena.alloc(f64, npar);
    for (col_norm, 0..) |*n, c| {
        const col = r_fac[c * rows ..][0..rows];
        const v = numerics.dot(col, col);
        n.* = if (v > 0) @sqrt(v) else 1;
        numerics.scale(col, 1 / n.*, col);
    }
    const junk = try arena.alloc(f64, rows);
    @memset(junk, 0);
    householder(rows, npar, r_fac, junk);
    // Check grid: log-spaced over and past the band, the data points and
    // each pole's resonance.
    var grid: std.ArrayList(f64) = .empty;
    const w_hi = 2 * std.math.pi * net.freq[net.freq.len - 1];
    const w_lo = @max(2 * std.math.pi * net.freq[0], w_hi * 1e-6);
    try grid.append(arena, 0);
    const npts = 40 * (kk + 5);
    for (0..npts) |i| try grid.append(arena, w_lo / 10 * std.math.pow(f64, 1000 * w_hi / w_lo, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(npts - 1))));
    for (s) |w| try grid.append(arena, w);
    for (f.poles) |pole| if (pole.im > 0) {
        for ([_]f64{ -1, -0.5, 0, 0.5, 1 }) |t| try grid.append(arena, @max(0, pole.im + t * @abs(pole.re)));
    };
    std.mem.sort(f64, grid.items, {}, std.sort.asc(f64));

    const g = try arena.alloc(Cx, ne);
    const q = try arena.alloc(Cx, p);
    // minEig's 2P×2P matrix and eigenvectors, reused at every grid point.
    const work = try arena.alloc(f64, 8 * p * p);
    var cons: std.ArrayList(f64) = .empty; // rows of B, ne * npar each
    var rhs: std.ArrayList(f64) = .empty;
    var round: usize = 0;
    while (round < 30) : (round += 1) {
        cons.clearRetainingCapacity();
        rhs.clearRetainingCapacity();
        // λ_min over the grid; one constraint per local minimum below zero.
        var prev: f64 = std.math.inf(f64);
        var falling = false;
        var cand_w: f64 = 0;
        var cand_l: f64 = 0;
        for (grid.items, 0..) |w, gi| {
            hermitianPart(f.*, p, w, g);
            const l = minEig(p, g, null, work);
            if (l < prev) {
                falling = true;
                cand_w = w;
                cand_l = l;
            } else if (falling) {
                falling = false;
                if (cand_l < 0) try addConstraint(arena, f.*, p, cand_w, cand_l, margin, g, q, work, &cons, &rhs);
            }
            if (gi == grid.items.len - 1 and falling and cand_l < 0) try addConstraint(arena, f.*, p, cand_w, cand_l, margin, g, q, work, &cons, &rhs);
            prev = l;
        }
        // Direct term: sym(D) ⪰ 0 bounds Re Y at infinite frequency.
        for (0..p) |i| for (0..p) |j| {
            g[i * p + j] = .{ .re = 0.5 * (f.d[i * p + j] + f.d[j * p + i]), .im = 0 };
        };
        const ld = minEig(p, g, q, work);
        if (ld < 0) try appendRow(arena, f.*, p, null, q, -ld + margin, &cons, &rhs);
        const nc = rhs.items.len;
        if (nc == 0) return true;
        // Minimum ‖R·Δ_e‖ subject to B·Δ = c: with z_e = R·Δ_e,
        // z = Mᵀ(MMᵀ)⁻¹c, M = B·blockdiag(R⁻¹).
        const mm = try arena.alloc(f64, nc * ne * npar);
        for (0..nc) |ci| for (0..ne) |e| {
            // Row (B_c,e)·R⁻¹: solve Rᵀ·y = B_c,eᵀ.
            const bce = cons.items[(ci * ne + e) * npar ..][0..npar];
            const y = mm[(ci * ne + e) * npar ..][0..npar];
            for (0..npar) |c| {
                // R's column c above the diagonal is contiguous.
                const rc = r_fac[c * rows ..][0 .. c + 1];
                const v = bce[c] / col_norm[c] - numerics.dot(rc[0..c], y[0..c]);
                y[c] = if (@abs(rc[c]) > 1e-300) v / rc[c] else 0;
            }
        };
        // MMᵀ, symmetric: the upper triangle, mirrored.
        const gram = try arena.alloc(f64, nc * nc);
        const row_len = ne * npar;
        for (0..nc) |a| for (a..nc) |b| {
            const v = numerics.dot(mm[a * row_len ..][0..row_len], mm[b * row_len ..][0..row_len]);
            gram[a * nc + b] = v;
            gram[b * nc + a] = v;
        };
        const lam = try arena.alloc(f64, nc);
        @memcpy(lam, rhs.items);
        // Symmetric, so its row-major layout is also the column-major one
        // leastSquares takes; it destroys `gram`, which nothing reads after.
        leastSquares(nc, nc, gram, try arena.dupe(f64, lam), lam);
        // Δ_e = R⁻¹·z_e, z = Mᵀλ.
        const z = try arena.alloc(f64, npar);
        const delta = try arena.alloc(f64, npar);
        for (0..ne) |e| {
            @memset(z, 0);
            for (0..nc) |ci| numerics.axpy(z, lam[ci], mm[(ci * ne + e) * npar ..][0..npar]);
            // Column-oriented back substitution, as in leastSquares; it
            // consumes `z`, which the next entry rebuilds.
            var c = npar;
            while (c > 0) {
                c -= 1;
                const rc = r_fac[c * rows ..][0 .. c + 1];
                delta[c] = if (@abs(rc[c]) > 1e-300) z[c] / rc[c] else 0;
                numerics.axpy(z[0..c], -delta[c], rc[0..c]);
            }
            for (delta, col_norm) |*v, n| v.* /= n;
            var at: usize = 0;
            for (f.poles, f.res[e * f.poles.len ..][0..f.poles.len]) |pole, *r| {
                if (pole.im != 0) {
                    r.* = r.add(.{ .re = delta[at], .im = delta[at + 1] });
                    at += 2;
                } else {
                    r.re += delta[at];
                    at += 1;
                }
            }
            f.d[e] += delta[kk];
        }
    }
    return false;
}

fn addConstraint(arena: Allocator, f: Fit, p: usize, w: f64, l: f64, margin: f64, g: []Cx, q: []Cx, work: []f64, cons: *std.ArrayList(f64), rhs: *std.ArrayList(f64)) Error!void {
    hermitianPart(f, p, w, g);
    _ = minEig(p, g, q, work);
    try appendRow(arena, f, p, w, q, -l + margin, cons, rhs);
}

/// One constraint row: Re(qᴴ·ΔY(jω)·q) = c over every entry's parameters
/// [basis coefficients..., d]; `w` null is the direct term alone.
fn appendRow(arena: Allocator, f: Fit, p: usize, w: ?f64, q: []const Cx, c: f64, cons: *std.ArrayList(f64), rhs: *std.ArrayList(f64)) Error!void {
    const npar = f.order() + 1;
    for (0..p) |i| for (0..p) |j| {
        const qq = q[i].conjugate().mul(q[j]);
        if (w) |om| {
            for (f.poles) |pole| {
                const bv = phi(pole, om);
                for (bv[0..if (pole.im != 0) 2 else 1]) |v| try cons.append(arena, qq.mul(v).re);
            }
        } else try cons.appendNTimes(arena, 0, npar - 1);
        try cons.append(arena, qq.re);
    };
    try rhs.append(arena, c);
}

/// (Y + Yᴴ)/2 of the fit at jω into `g` (row-major P×P).
fn hermitianPart(f: Fit, p: usize, w: f64, g: []Cx) void {
    for (0..p) |i| for (0..p) |j| {
        g[i * p + j] = f.eval(i * p + j, w);
    };
    for (0..p) |i| for (i..p) |j| {
        const a = g[i * p + j];
        const b = g[j * p + i].conjugate();
        const h = a.add(b).mul(.{ .re = 0.5, .im = 0 });
        g[i * p + j] = h;
        g[j * p + i] = h.conjugate();
    };
}

/// The smallest eigenvalue of the Hermitian P×P `g`, and its unit
/// eigenvector into `vec` when given: cyclic Jacobi on the real symmetric
/// 2P×2P embedding [[Re, −Im], [Im, Re]], whose spectrum doubles g's.
/// `work` holds 2·(2P)² scratch values.
fn minEig(p: usize, g: []const Cx, vec: ?[]Cx, work: []f64) f64 {
    const n = 2 * p;
    const a = work[0 .. n * n];
    const v = work[n * n ..][0 .. n * n];
    for (0..p) |i| for (0..p) |j| {
        const z = g[i * p + j];
        a[i * n + j] = z.re;
        a[(p + i) * n + (p + j)] = z.re;
        a[i * n + (p + j)] = -z.im;
        a[(p + i) * n + j] = z.im;
    };
    symEig(n, a, v);
    var best: usize = 0;
    for (1..n) |i| if (a[i * n + i] < a[best * n + best]) {
        best = i;
    };
    if (vec) |out| {
        var norm: f64 = 0;
        for (0..p) |i| {
            out[i] = .{ .re = v[i * n + best], .im = v[(p + i) * n + best] };
            norm += out[i].magnitude() * out[i].magnitude();
        }
        const inv = 1 / @sqrt(norm);
        for (out) |*o| o.* = o.mul(.{ .re = inv, .im = 0 });
    }
    return a[best * n + best];
}

/// Cyclic Jacobi on the real symmetric row-major n×n `a`: afterwards `a`'s
/// diagonal holds the eigenvalues and column i of `v` the unit eigenvector
/// of `a[i * n + i]`. Unordered. At most 100 sweeps, O(n³) each.
/// Asserts that `a` and `v` are n×n.
pub fn symEig(n: usize, a: []f64, v: []f64) void {
    std.debug.assert(a.len == n * n and v.len == n * n);
    @memset(v, 0);
    for (0..n) |i| v[i * n + i] = 1;
    for (0..100) |_| {
        var off: f64 = 0;
        for (0..n) |i| for (0..n) |j| {
            if (i != j) off += a[i * n + j] * a[i * n + j];
        };
        var diag: f64 = 0;
        for (0..n) |i| diag += a[i * n + i] * a[i * n + i];
        if (off <= 1e-30 * @max(diag, 1e-300)) break;
        for (0..n) |pp| for (pp + 1..n) |qq| {
            const apq = a[pp * n + qq];
            if (apq == 0) continue;
            const theta = (a[qq * n + qq] - a[pp * n + pp]) / (2 * apq);
            const t = std.math.sign(theta + 0.5 * @as(f64, if (theta == 0) 1 else 0)) / (@abs(theta) + @sqrt(theta * theta + 1));
            const c = 1 / @sqrt(t * t + 1);
            const sn = t * c;
            for (0..n) |k| {
                const akp = a[k * n + pp];
                const akq = a[k * n + qq];
                a[k * n + pp] = c * akp - sn * akq;
                a[k * n + qq] = sn * akp + c * akq;
            }
            for (0..n) |k| {
                const apk = a[pp * n + k];
                const aqk = a[qq * n + k];
                a[pp * n + k] = c * apk - sn * aqk;
                a[qq * n + k] = sn * apk + c * aqk;
            }
            for (0..n) |k| {
                const vkp = v[k * n + pp];
                const vkq = v[k * n + qq];
                v[k * n + pp] = c * vkp - sn * vkq;
                v[k * n + qq] = sn * vkp + c * vkq;
            }
        };
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "touchstone: a matched attenuator converts to its admittance" {
    // 6.02 dB matched pad: S11 = S22 = 0, S21 = S12 = 0.5, 50 Ω.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const net = try parseTouchstone(arena, "! pad\n# MHz S RI R 50\n1 0 0 0.5 0 0.5 0 0 0\n2 0 0 0.5 0 0.5 0 0 0\n", 2);
    try testing.expectEqual(@as(usize, 2), net.freq.len);
    try testing.expectEqual(@as(f64, 2e6), net.freq[1]);
    // Y = (1/50)·(I − S)(I + S)⁻¹ = (1/50)·[[5/3, −4/3], [−4/3, 5/3]].
    try testing.expectApproxEqRel(@as(f64, 1.0 / 30.0), net.at(0, 0).re, 1e-12);
    try testing.expectApproxEqRel(@as(f64, -1.0 / 37.5), net.at(1, 0).re, 1e-12);
}

test "vector fit reproduces a rational two-port and stays passive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Series R-L between the ports, series R-C to ground at each:
    // Y = Ys·[[1,−1],[−1,1]] + Yp·I.
    const r = 10.0;
    const l = 5e-9;
    const c = 2e-12;
    const nf = 200;
    const freq = try arena.alloc(f64, nf);
    const re = try arena.alloc(f64, 4 * nf);
    const im = try arena.alloc(f64, 4 * nf);
    for (0..nf) |k| {
        freq[k] = 1e6 * std.math.pow(f64, 1e4, @as(f64, @floatFromInt(k)) / (nf - 1));
        const w = 2 * std.math.pi * freq[k];
        const ys = (Cx{ .re = 1, .im = 0 }).div(.{ .re = r, .im = w * l });
        for (0..4) |e| {
            const sgn: f64 = if (e == 0 or e == 3) 1 else -1;
            const yp = (Cx{ .re = 1, .im = 0 }).div(.{ .re = 25, .im = -1 / (w * c) });
            const y = ys.mul(.{ .re = sgn, .im = 0 }).add(if (sgn > 0) yp else .{ .re = 0, .im = 0 });
            re[e * nf + k] = y.re;
            im[e * nf + k] = y.im;
        }
    }
    const net: Network = .{ .ports = 2, .freq = freq, .re = re, .im = im };
    var f = try fit(arena, net, .{});
    try testing.expect(f.rel_err < 1e-6);
    try testing.expect(try enforcePassivity(arena, net, &f));
    for (0..nf) |k| try testing.expect(f.eval(1, 2 * std.math.pi * freq[k]).sub(net.at(1, k)).magnitude() < 1e-4 * net.at(1, k).magnitude() + 1e-9);
}

test "touchstone: Y, Z and dB data convert, and the noise block is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Normalized y = 1 and z = 1 are both 1/50 S; |S| = 0.5 (−6.02 dB) at 0°
    // is (1 − 0.5)/(1 + 0.5)/50 = 1/150 S.
    for ([_][]const u8{ "# Hz Y RI R 50\n1 1 0\n", "# Hz Z RI R 50\n1 1 0\n", "# Hz S DB R 50\n1 -6.020599913279624 0\n" }, [_]f64{ 1.0 / 50.0, 1.0 / 50.0, 1.0 / 150.0 }) |file, want| {
        const net = try parseTouchstone(arena, file, 1);
        try testing.expectEqual(@as(f64, 1), net.freq[0]);
        try testing.expectApproxEqRel(want, net.at(0, 0).re, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0), net.at(0, 0).im, 1e-15);
    }
    // Two noise rows (5 numbers each) after the data: their first frequency
    // does not ascend, so the data ends at two points.
    const net = try parseTouchstone(arena, "# Hz S RI R 50\n1 0 0 0.5 0 0.5 0 0 0\n2 0 0 0.5 0 0.5 0 0 0\n1 2.0 0.5 0 0.1\n2 2.0 0.5 0 0.1\n", 2);
    try testing.expectEqual(@as(usize, 2), net.freq.len);
}

test "touchstone: malformed files are refused, never misread" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidTouchstone, parseTouchstone(arena, "1 0 0\n", 0));
    try testing.expectError(error.InvalidTouchstone, parseTouchstone(arena, "1 0 0\n", 65));
    for ([_][]const u8{
        "", // no data
        "! only a comment\n",
        "[Version] 2.0\n1 0 0\n", // Touchstone 2.0
        "# Hz Q RI\n1 0 0\n", // unknown option
        "# frequency\n1 0 0\n", // option token too long to be one
        "# Hz S RI R 0\n1 0 0\n", // z0 must be positive
        "# Hz S RI R\n1 0 0\n", // R without a value
        "# Hz S RI R 50\n-1 0 0\n", // negative frequency
        "# Hz S RI R 50\n1 x 0\n", // not a number
        "# Hz S RI R 50\n1 0\n", // a short row
    }) |file| try testing.expectError(error.InvalidTouchstone, parseTouchstone(arena, file, 1));
    // S = −1 makes I + S singular.
    try testing.expectError(error.SingularSParameters, parseTouchstone(arena, "# Hz S RI R 50\n1 -1 0\n", 1));
}

test "leastSquares meets the normal equations at every column-length tail" {
    // Certificate: the LS solution x makes the residual orthogonal to every
    // column, Aᵀ(Ax − b) = 0. Lengths sweep past 3×8 lanes plus one so every
    // dot/axpy tail inside the QR runs.
    var prng = std.Random.DefaultPrng.init(0x5ea1);
    const rnd = prng.random();
    const max_m = 4 + 3 * 8 + 2;
    var a0: [max_m * 4]f64 = undefined;
    var a: [max_m * 4]f64 = undefined;
    var b0: [max_m]f64 = undefined;
    var b: [max_m]f64 = undefined;
    var x: [4]f64 = undefined;
    for (1..5) |n| for (n..max_m) |m| {
        for (a0[0 .. m * n]) |*v| v.* = rnd.float(f64) * 2 - 1;
        for (b0[0..m]) |*v| v.* = rnd.float(f64) * 2 - 1;
        @memcpy(a[0 .. m * n], a0[0 .. m * n]);
        @memcpy(b[0..m], b0[0..m]);
        leastSquares(m, n, a[0 .. m * n], b[0..m], x[0..n]);
        var na: f64 = 0;
        for (a0[0 .. m * n]) |v| na += v * v;
        var nx: f64 = 0;
        for (x[0..n]) |v| nx += v * v;
        var nb: f64 = 0;
        for (b0[0..m]) |v| nb += v * v;
        const bound = 1e-9 * @sqrt(na) * (@sqrt(na) * @sqrt(nx) + @sqrt(nb));
        for (0..n) |c| {
            var g: f64 = 0;
            for (0..m) |r| {
                var ax: f64 = 0;
                for (0..n) |j| ax += a0[j * m + r] * x[j];
                g += a0[c * m + r] * (ax - b0[r]);
            }
            try testing.expect(@abs(g) <= bound);
        }
    };
}

test "leastSquares zeroes a null column" {
    // Column 0 all ones, column 1 all zeros: x = (mean b, 0).
    var a = [_]f64{ 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
    var b = [_]f64{ 1, 2, 3, 4, 5 };
    var x: [2]f64 = undefined;
    leastSquares(5, 2, &a, &b, &x);
    try testing.expectApproxEqRel(@as(f64, 3), x[0], 1e-12);
    try testing.expectEqual(@as(f64, 0), x[1]);
}

test symEig {
    // Certificate: A·v_i = λ_i·v_i for every returned pair, unit v_i.
    const a0 = [9]f64{ 4, 1, 0.5, 1, 3, 0.2, 0.5, 0.2, 1 };
    var a = a0;
    var v: [9]f64 = undefined;
    symEig(3, &a, &v);
    for (0..3) |i| {
        var norm: f64 = 0;
        for (0..3) |r| {
            var av: f64 = 0;
            for (0..3) |c| av += a0[r * 3 + c] * v[c * 3 + i];
            try testing.expectApproxEqAbs(a[i * 3 + i] * v[r * 3 + i], av, 1e-12);
            norm += v[r * 3 + i] * v[r * 3 + i];
        }
        try testing.expectApproxEqAbs(@as(f64, 1), norm, 1e-12);
    }
    var one = [1]f64{-2};
    var vone: [1]f64 = undefined;
    symEig(1, &one, &vone);
    try testing.expectEqual(@as(f64, -2), one[0]);
    try testing.expectEqual(@as(f64, 1), vone[0]);
}

test sections {
    // Three real poles (one pair of sections and one first-order) and a
    // complex pair: the sections sum to the pole-residue form at any ω.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var res = [_]Cx{ .{ .re = 1, .im = 0 }, .{ .re = 2, .im = 0 }, .{ .re = -0.5, .im = 0.25 }, .{ .re = 3, .im = 0 } };
    var d = [_]f64{0.1};
    const f: Fit = .{
        .poles = &.{ .{ .re = -1, .im = 0 }, .{ .re = -2, .im = 0 }, .{ .re = -1, .im = 2 }, .{ .re = -3, .im = 0 } },
        .res = &res,
        .d = &d,
    };
    try testing.expectEqual(@as(usize, 5), f.order());
    const sec = try sections(arena, f);
    try testing.expectEqual(@as(usize, 3), sec.den.len);
    for ([_]f64{ 0, 0.3, 1, 7 }) |w| {
        const s: Cx = .{ .re = 0, .im = w };
        var y: Cx = .{ .re = f.d[0], .im = 0 };
        for (sec.num, sec.den) |nm, dn| {
            const num: Cx = .{ .re = nm[0], .im = w * nm[1] };
            const den = (Cx{ .re = dn[0], .im = w * dn[1] }).add(s.mul(s).mul(.{ .re = dn[2], .im = 0 }));
            y = y.add(num.div(den));
        }
        try testing.expect(y.sub(f.eval(0, w)).magnitude() <= 1e-12 * f.eval(0, w).magnitude());
    }
}

test fit {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidTouchstone, fit(arena, .{ .ports = 1, .freq = &.{}, .re = &.{}, .im = &.{} }, .{}));
    try testing.expectError(error.InvalidTouchstone, fit(arena, .{ .ports = 1, .freq = &.{0}, .re = &.{1}, .im = &.{0} }, .{}));
    // Four points of a one-pole response: no order-4 fit fits in four
    // points, so the constant fit comes back instead of a σ block read
    // past the data.
    var freq: [4]f64 = undefined;
    var re: [4]f64 = undefined;
    var im: [4]f64 = undefined;
    for (&freq, &re, &im, 0..) |*f, *r, *i, k| {
        f.* = @floatFromInt(k + 1);
        const y = (Cx{ .re = 1, .im = 0 }).div(.{ .re = 1, .im = f.* });
        r.* = y.re;
        i.* = y.im;
    }
    const short = try fit(arena, .{ .ports = 1, .freq = &freq, .re = &re, .im = &im }, .{});
    try testing.expectEqual(@as(usize, 0), short.poles.len);
    try testing.expect(short.rel_err > 0);
}

test "weights: per entry, or per sample with `relative`, zero for a zero sample" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const net: Network = .{ .ports = 1, .freq = &.{ 1, 2 }, .re = &.{ 0, 2 }, .im = &.{ 0, 0 } };
    try testing.expectEqualSlices(f64, &.{ 0.5, 0.5 }, try weights(arena, net, false));
    try testing.expectEqualSlices(f64, &.{ 0, 0.5 }, try weights(arena, net, true));
}

test "enforcePassivity lifts a negative direct term to the margin" {
    // Y(jω) = d = −1 everywhere: one grid minimum and the direct term
    // both violate; the minimum-norm change sets d to the 1e-9 margin.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const net: Network = .{ .ports = 1, .freq = &.{ 1e6, 2e6 }, .re = &.{ 1, 1 }, .im = &.{ 0, 0 } };
    var d = [_]f64{-1};
    var f: Fit = .{ .poles = &.{}, .res = try arena.alloc(Cx, 0), .d = &d };
    try testing.expect(try enforcePassivity(arena, net, &f));
    try testing.expect(d[0] >= 0 and d[0] < 1e-6);
}
