//! coupled_ltra — N-line coupled lossy transmission lines (P card): faithful
//! port of ngspice's CPL device (Hough/SWEC), cplsetup.c coupled() +
//! cplload.c. The setup samples the modal decomposition of the symmetrized
//! C^{1/2}(sL+R)C^{1/2} product at eight 1/s points, polynomial-interpolates
//! every matrix entry (polint/match), forms truncated polynomial products
//! IWI = Si·W·Si⁻¹ and IWV = Si·W·Sv⁻¹, and Padé-fits each entry to three
//! poles. The load runs O(1) recursive exponential convolutions per entry.
//! Deliberately bug-compatible: the fits live in the reference's scaled
//! units (poles ~1e-3 "rad/s" fed to exp(x·h) with h in seconds — the
//! shipped code does exactly this), the diag() ordering pipeline, the R
//! entry clamp MAX(R,1e-4), integer-picosecond history. Matching the
//! goldens IS the spec: an exact modal Bessel/LTRA variant measured
//! 1.5e-2 rms away from them, an analytic modal Padé variant 2.5e-2.
//!
//! Nodes: ngspice binds pos/neg per conductor and IGNORES the card's
//! reference nodes — ports are ground-referenced. Unknowns (4N): 2N port
//! voltages + 2N conductor branch currents. History is conductor-space on
//! integer-ps times, pruned behind the largest mode delay.

const std = @import("std");
const contract = @import("contract");

const inf = std.math.inf(f64);

/// Line counts the builder may instantiate; ngspice's own MAX is 8.
/// ponytail: 2..4 covers every fixture and typical bus; widen when needed.
pub const supported_n = [_]usize{ 2, 3, 4 };

/// Accepted-history capacity (shared time axis). Delayed reads reach back
/// max τ (~15 points at fixture grids); updateState prunes the dead front.
const CAP = 2048;

const DEG = 7; // Left_deg: 8 samples, degree-7 fits

// ---------------------------------------------------------------------------
// Setup pipeline (cplsetup.c), verbatim math. Everything works on fixed
// MAXN-sized scratch; N <= 4 keeps it all on the stack.
// ---------------------------------------------------------------------------

const MAXN = 4;

fn eval2(a: f64, b: f64, c: f64, x: f64) f64 {
    return a * x * x + b * x + c;
}

fn divC(ar: f64, ai: f64, br: f64, bi: f64) [2]f64 {
    const t = br * br + bi * bi;
    return .{ (ar * br + ai * bi) / t, (ai * br - ar * bi) / t };
}

/// Numerical Recipes polint (degree n−1 through n points), 1-based arrays
/// spelled 0-based.
fn polint(xa: []const f64, ya: []const f64, n: usize, x: f64) f64 {
    var c: [DEG + 1]f64 = undefined;
    var d: [DEG + 1]f64 = undefined;
    var ns: usize = 0;
    var dif = @abs(x - xa[0]);
    for (0..n) |i| {
        const dift = @abs(x - xa[i]);
        if (dift < dif) {
            ns = i;
            dif = dift;
        }
        c[i] = ya[i];
        d[i] = ya[i];
    }
    var y = ya[ns];
    var ns_i: isize = @as(isize, @intCast(ns)) - 1;
    for (1..n) |m| {
        for (0..n - m) |i| {
            const ho = xa[i] - x;
            const hp = xa[i + m] - x;
            const w = c[i + 1] - d[i];
            const den = w / (ho - hp);
            d[i] = hp * den;
            c[i] = ho * den;
        }
        if (2 * @as(isize, @intCast(ns_i + 1)) < @as(isize, @intCast(n - m))) {
            y += c[@intCast(ns_i + 1)];
        } else {
            y += d[@intCast(ns_i)];
            ns_i -= 1;
        }
    }
    return y;
}

/// cplsetup match(): power-series coefficients through the sample set by
/// repeated polint-at-0 + deflation, in place over (x, y) copies.
fn matchFit(cof: *[DEG + 1]f64, xa: [DEG + 1]f64, ya: [DEG + 1]f64) void {
    var x = xa;
    var y = ya;
    for (0..DEG + 1) |j| {
        cof[j] = polint(x[0 .. DEG + 1 - j], y[0 .. DEG + 1 - j], DEG + 1 - j, 0.0);
        var xmin: f64 = 1.0e38;
        var k: usize = 0;
        for (0..DEG + 1 - j) |i| {
            if (@abs(x[i]) < xmin) {
                xmin = @abs(x[i]);
                k = i;
            }
            if (x[i] != 0) y[i] = (y[i] - cof[j]) / x[i];
        }
        var i = k + 1;
        while (i <= DEG - j) : (i += 1) {
            y[i - 1] = y[i];
            x[i - 1] = x[i];
        }
    }
}

fn root3(a1: f64, a2: f64, a3: f64, x: f64) f64 {
    const t1 = x * (x * (x + a1) + a2) + a3;
    const t2 = x * (2.0 * a1 + 3.0 * x) + a2;
    return x - t1 / t2;
}

/// cplsetup find_roots: returns true when the deflated pair is complex
/// (x2 ± j·x3). No overflow-scaling dance here, unlike txlsetup's.
fn findRoots(a1_in: f64, a2_in: f64, a3_in: f64, x1: *f64, x2: *f64, x3: *f64) bool {
    var a1 = a1_in;
    var a2 = a2_in;
    const q = (a1 * a1 - 3.0 * a2) / 9.0;
    const p = (2.0 * a1 * a1 * a1 - 9.0 * a1 * a2 + 27.0 * a3_in) / 54.0;
    var t = q * q * q - p * p;
    var x: f64 = undefined;
    if (t >= 0.0) {
        t = std.math.acos(p / (q * @sqrt(q)));
        x = -2.0 * @sqrt(q) * @cos(t / 3.0) - a1 / 3.0;
    } else if (p > 0.0) {
        t = std.math.pow(f64, @sqrt(-t) + p, 1.0 / 3.0);
        x = -(t + q / t) - a1 / 3.0;
    } else if (p == 0.0) {
        x = -a1 / 3.0;
    } else {
        t = std.math.pow(f64, @sqrt(-t) - p, 1.0 / 3.0);
        x = (t + q / t) - a1 / 3.0;
    }
    {
        const backup = x;
        var i: u32 = 0;
        t = root3(a1, a2, a3_in, x);
        while (@abs(t - x) > 5.0e-4) : (t = root3(a1, a2, a3_in, x)) {
            i += 1;
            if (i == 32) {
                x = backup;
                break;
            }
            x = t;
        }
    }
    x1.* = x;
    a1 = a1_in + x;
    a2 = -a3_in / x;
    t = a1 * a1 - 4.0 * a2;
    if (t < 0) {
        x3.* = 0.5 * @sqrt(-t);
        x2.* = -0.5 * a1;
        return true;
    }
    t = @sqrt(t);
    if (a1 >= 0.0) {
        x2.* = -0.5 * (a1 + t);
    } else {
        x2.* = -0.5 * (a1 - t);
    }
    x3.* = a2 / x2.*;
    return false;
}

fn getC(q1: f64, q2: f64, q3: f64, p1: f64, p2: f64, a: f64, b: f64) [2]f64 {
    var d = (3.0 * (a * a - b * b) + 2.0 * p1 * a + p2) * (3.0 * (a * a - b * b) + 2.0 * p1 * a + p2);
    d += (6.0 * a * b + 2.0 * p1 * b) * (6.0 * a * b + 2.0 * p1 * b);
    var n = -(q1 * (a * a - b * b) + q2 * a + q3) * (6.0 * a * b + 2.0 * p1 * b);
    n += (2.0 * q1 * a * b + q2 * b) * (3.0 * (a * a - b * b) + 2.0 * p1 * a + p2);
    const ci = n / d;
    n = (3.0 * (a * a - b * b) + 2.0 * p1 * a + p2) * (q1 * (a * a - b * b) + q2 * a + q3);
    n += (6.0 * a * b + 2.0 * p1 * b) * (2.0 * q1 * a * b + q2 * b);
    return .{ n / d, ci };
}

/// One TMS entry: three exponential terms (or one real + complex pair).
pub const Tms = struct {
    aten: f64 = 0, // C_0; 0 = entry absent
    if_img: bool = false,
    c: [3]f64 = @splat(0),
    x: [3]f64 = @splat(0),
};

/// cplsetup Pade_apx on a matched power series (b[0] == 1 implied).
fn padeApx(a_b: f64, b: *const [DEG + 1]f64, tms: *Tms) bool {
    var at: [3][4]f64 = .{
        .{ 1.0 - a_b, b[1], b[2], -b[3] },
        .{ b[1], b[2], b[3], -b[4] },
        .{ b[2], b[3], b[4], -b[5] },
    };
    // Gaussian_Elimination(3) with epsi_mult
    for (0..3) |i| {
        var imax = i;
        var max = @abs(at[i][i]);
        for (i + 1..3) |j| {
            if (@abs(at[j][i]) > max) {
                imax = j;
                max = @abs(at[j][i]);
            }
        }
        if (max < 1e-28) return false;
        if (imax != i) std.mem.swap([4]f64, &at[i], &at[imax]);
        const f = 1.0 / at[i][i];
        at[i][i] = 1.0;
        for (i + 1..4) |j| at[i][j] *= f;
        for (0..3) |j| {
            if (i == j) continue;
            const f2 = at[j][i];
            at[j][i] = 0.0;
            for (i + 1..4) |k| at[j][k] -= f2 * at[i][k];
        }
    }
    const p3 = at[0][3];
    const p2 = at[1][3];
    const p1 = at[2][3];
    const q1 = p1 + b[1];
    const q2 = b[1] * p1 + p2 + b[2];
    const q3 = p3 * a_b;
    var x1: f64 = undefined;
    var x2: f64 = undefined;
    var x3: f64 = undefined;
    tms.if_img = findRoots(p1, p2, p3, &x1, &x2, &x3);
    tms.x = .{ x1, x2, x3 };
    tms.c[0] = eval2(q1 - p1, q2 - p2, q3 - p3, x1) / eval2(3.0, 2.0 * p1, p2, x1);
    if (tms.if_img) {
        const pair = getC(q1 - p1, q2 - p2, q3 - p3, p1, p2, x2, x3);
        tms.c[1] = pair[0];
        tms.c[2] = pair[1];
    } else {
        tms.c[1] = eval2(q1 - p1, q2 - p2, q3 - p3, x2) / eval2(3.0, 2.0 * p1, p2, x2);
        tms.c[2] = eval2(q1 - p1, q2 - p2, q3 - p3, x3) / eval2(3.0, 2.0 * p1, p2, x3);
    }
    return true;
}

/// The whole coupled() pipeline for one card. Scratch state bundled so the
/// device stays reentrant (ngspice uses file statics).
const Setup = struct {
    n: usize,
    length: f64,
    r: [MAXN][MAXN]f64,
    g: [MAXN][MAXN]f64,
    l: [MAXN][MAXN]f64,
    c: [MAXN][MAXN]f64,

    zy: [MAXN][MAXN]f64 = undefined,
    sv: [MAXN][MAXN]f64 = undefined,
    d: [MAXN]f64 = undefined,
    y5: [MAXN][MAXN]f64 = undefined,
    y5_1: [MAXN][MAXN]f64 = undefined,
    sv_1: [MAXN][MAXN]f64 = undefined,
    si: [MAXN][MAXN]f64 = undefined,
    si_1: [MAXN][MAXN]f64 = undefined,
    scaling_f: f64 = 1,
    scaling_f2: f64 = 1,
    freq: [DEG + 1]f64 = undefined,
    sip: [MAXN][MAXN][DEG + 1]f64 = undefined,
    si_1p: [MAXN][MAXN][DEG + 1]f64 = undefined,
    sv_1p: [MAXN][MAXN][DEG + 1]f64 = undefined,
    sisv_1: [MAXN][MAXN][DEG + 1]f64 = undefined,
    w: [MAXN][DEG + 1]f64 = undefined,
    tau: [MAXN]f64 = undefined,

    /// diag() — Jacobi with the reference's largest-off-element ordering
    /// queue and its integer-truncated comparisons. The queue is a sorted
    /// array here (N ≤ 4: at most 3 entries).
    fn diagz(self: *Setup) void {
        const n = self.n;
        var fmax = @abs(self.zy[0][0]);
        var fmin = fmax;
        for (0..n) |i| {
            for (i..n) |j| {
                const v = @abs(self.zy[i][j]);
                if (v > fmax) fmax = v else if (v < fmin) fmin = v;
            }
        }
        const scale = 2.0 / (fmin + fmax);
        for (0..n) |i| {
            for (i..n) |j| self.zy[i][j] *= scale;
        }
        for (0..n) |i| {
            for (0..n) |j| self.sv[i][j] = if (i == j) 1.0 else 0.0;
        }
        // ordering(): per row i, its largest |offdiag| column.
        var rows: [MAXN]struct { row: usize, col: usize, value: f64 } = undefined;
        var nrows: usize = 0;
        for (0..n - 1) |i| {
            var m = i + 1;
            var mv = @abs(self.zy[i][m]);
            for (m + 1..n) |j| {
                if (@as(i64, @intFromFloat(@abs(self.zy[i][j]) * 1e7)) > @as(i64, @intFromFloat(1e7 * mv))) {
                    mv = @abs(self.zy[i][j]);
                    m = j;
                }
            }
            insertSorted(&rows, &nrows, i, m, mv);
        }
        while (nrows > 0 and rows[0].value > 1.0e-8) {
            const p = rows[0].row;
            const q = rows[0].col;
            self.rotate(p, q);
            // reordering(p, q)
            removeRow(&rows, &nrows, p);
            var m = p + 1;
            var mv = @abs(self.zy[p][m]);
            for (m + 1..n) |j| {
                if (@as(i64, @intFromFloat(@abs(self.zy[p][j]) * 1e7)) > @as(i64, @intFromFloat(1e7 * mv))) {
                    mv = @abs(self.zy[p][j]);
                    m = j;
                }
            }
            insertSorted(&rows, &nrows, p, m, mv);
            if (q + 1 != n) {
                removeRow(&rows, &nrows, q);
                m = q + 1;
                mv = @abs(self.zy[q][m]);
                for (m + 1..n) |j| {
                    if (@as(i64, @intFromFloat(@abs(self.zy[q][j]) * 1e7)) > @as(i64, @intFromFloat(1e7 * mv))) {
                        mv = @abs(self.zy[q][j]);
                        m = j;
                    }
                }
                insertSorted(&rows, &nrows, q, m, mv);
            }
        }
        for (0..n) |i| self.d[i] = self.zy[i][i] / scale;
    }

    fn insertSorted(rows: anytype, nrows: *usize, r: usize, c: usize, v: f64) void {
        // descending by value, stable insertion mirroring the linked sort()
        var i: usize = 0;
        while (i < nrows.* and rows[i].value >= v) i += 1;
        var j = nrows.*;
        while (j > i) : (j -= 1) rows[j] = rows[j - 1];
        rows[i] = .{ .row = r, .col = c, .value = v };
        nrows.* += 1;
    }

    fn removeRow(rows: anytype, nrows: *usize, r: usize) void {
        var i: usize = 0;
        while (rows[i].row != r) i += 1;
        while (i + 1 < nrows.*) : (i += 1) rows[i] = rows[i + 1];
        nrows.* -= 1;
    }

    /// rotate() — upper-triangle Jacobi rotation, verbatim.
    fn rotate(self: *Setup, p: usize, q: usize) void {
        const n = self.n;
        const ld = -self.zy[p][q];
        const mu = 0.5 * (self.zy[p][p] - self.zy[q][q]);
        const ve = @sqrt(ld * ld + mu * mu);
        const co = @sqrt((ve + @abs(mu)) / (2.0 * ve));
        const si_ = std.math.copysign(@as(f64, 1.0), mu) * ld / (2.0 * ve * co);
        var t_: [MAXN]f64 = undefined;
        for (p + 1..n) |j| t_[j] = self.zy[p][j];
        for (0..p) |j| t_[j] = self.zy[j][p];
        for (p + 1..n) |j| {
            if (j == q) continue;
            if (j > q) {
                self.zy[p][j] = t_[j] * co - self.zy[q][j] * si_;
            } else {
                self.zy[p][j] = t_[j] * co - self.zy[j][q] * si_;
            }
        }
        for (q + 1..n) |j| {
            if (j == p) continue;
            self.zy[q][j] = t_[j] * si_ + self.zy[q][j] * co;
        }
        for (0..p) |j| {
            if (j == q) continue;
            self.zy[j][p] = t_[j] * co - self.zy[j][q] * si_;
        }
        for (0..q) |j| {
            if (j == p) continue;
            self.zy[j][q] = t_[j] * si_ + self.zy[j][q] * co;
        }
        const t = self.zy[p][p];
        self.zy[p][p] = t * co * co + self.zy[q][q] * si_ * si_ - 2.0 * self.zy[p][q] * si_ * co;
        self.zy[q][q] = t * si_ * si_ + self.zy[q][q] * co * co + 2.0 * self.zy[p][q] * si_ * co;
        self.zy[p][q] = 0.0;
        var tc: [MAXN]f64 = undefined;
        var rc: [MAXN]f64 = undefined;
        for (0..n) |j| {
            tc[j] = self.sv[j][p];
            rc[j] = self.sv[j][q];
        }
        for (0..n) |j| {
            self.sv[j][p] = tc[j] * co - rc[j] * si_;
            self.sv[j][q] = tc[j] * si_ + rc[j] * co;
        }
    }

    fn loopZY(self: *Setup, y: f64) void {
        const n = self.n;
        for (0..n) |i| {
            for (0..n) |j| self.zy[i][j] = self.scaling_f * self.c[i][j] + self.g[i][j] * y;
        }
        self.diagz();
        var fmin = self.d[0];
        for (1..n) |i| fmin = @min(fmin, self.d[i]);
        fmin = @sqrt(fmin);
        const fmin1 = 1.0 / fmin;
        for (0..n) |i| self.d[i] = @sqrt(self.d[i]);
        for (0..n) |i| {
            for (0..n) |j| {
                self.y5[i][j] = self.d[i] * self.sv[j][i];
                self.y5_1[i][j] = self.sv[j][i] / self.d[i];
            }
        }
        var tmp: [MAXN][MAXN]f64 = undefined;
        for (0..n) |i| {
            for (0..n) |j| {
                var s: f64 = 0;
                for (0..n) |k| s += self.sv[i][k] * self.y5[k][j];
                tmp[i][j] = s;
            }
        }
        self.y5 = tmp;
        for (0..n) |i| {
            for (0..n) |j| {
                var s: f64 = 0;
                for (0..n) |k| s += self.sv[i][k] * self.y5_1[k][j];
                tmp[i][j] = s;
            }
        }
        self.y5_1 = tmp;
        for (0..n) |i| {
            for (0..n) |j| {
                var s: f64 = 0;
                for (0..n) |k| s += (self.scaling_f * self.l[i][k] + self.r[i][k] * y) * self.y5[k][j];
                self.zy[i][j] = s;
            }
        }
        for (0..n) |i| {
            for (0..n) |j| {
                var s: f64 = 0;
                for (0..n) |k| s += self.y5[i][k] * self.zy[k][j];
                tmp[i][j] = s;
            }
        }
        self.zy = tmp;
        self.diagz();
        for (0..n) |i| {
            for (0..n) |j| {
                var s: f64 = 0;
                for (0..n) |k| s += self.sv[k][i] * self.y5[k][j];
                self.sv_1[i][j] = s * fmin1;
            }
        }
        for (0..n) |i| {
            for (0..n) |j| {
                var s: f64 = 0;
                for (0..n) |k| s += self.y5_1[i][k] * self.sv[k][j];
                tmp[i][j] = s * fmin;
            }
        }
        self.sv = tmp;
    }

    fn evalSi(self: *Setup, y: f64) void {
        const n = self.n;
        for (0..n) |i| {
            for (0..n) |j| {
                var s: f64 = 0;
                for (0..n) |k| s += self.sv_1[i][k] * (y * self.r[k][j] + self.scaling_f * self.l[k][j]);
                self.si_1[i][j] = s;
            }
        }
        for (0..n) |i| {
            const rt = @sqrt(self.d[i]);
            for (0..n) |j| self.si_1[i][j] /= rt;
        }
        // invert via [A | I]
        var a: [MAXN][2 * MAXN]f64 = undefined;
        for (0..n) |i| {
            for (0..n) |j| a[i][j] = self.si_1[i][j];
            for (n..2 * n) |j| a[i][j] = 0.0;
            a[i][i + n] = 1.0;
        }
        _ = gauss2(&a, n);
        for (0..n) |i| {
            for (0..n) |j| self.si[i][j] = a[i][j + n];
        }
    }

    /// Gaussian_Elimination2(type = −1): pivot search over 2n columns as the
    /// reference does (its j loop runs to `dim` = 2n — rows beyond n do not
    /// exist, but j < 2n only ever matters when n... transcribed with the
    /// row-bound j < n, which is what the memory layout makes it do).
    fn gauss2(a: *[MAXN][2 * MAXN]f64, n: usize) bool {
        for (0..n) |i| {
            var imax = i;
            var max = @abs(a[i][i]);
            for (i + 1..n) |j| {
                if (@abs(a[j][i]) > max) {
                    imax = j;
                    max = @abs(a[j][i]);
                }
            }
            if (max < 1.0e-88) return false;
            if (imax != i) std.mem.swap([2 * MAXN]f64, &a[i], &a[imax]);
            const f = 1.0 / a[i][i];
            a[i][i] = 1.0;
            for (i + 1..2 * n + 1) |j| {
                if (j < 2 * MAXN) a[i][j] *= f;
            }
            for (0..n) |j| {
                if (i == j) continue;
                const f2 = a[j][i];
                a[j][i] = 0.0;
                for (i + 1..2 * n + 1) |k| {
                    if (k < 2 * MAXN) a[j][k] -= f2 * a[i][k];
                }
            }
        }
        return true;
    }

    fn approxMode(self: *Setup, x: *[DEG + 1]f64) f64 {
        const w0 = x[0];
        const w1 = x[1] / w0;
        const w2 = x[2] / w0;
        const w3 = x[3] / w0;
        const w4 = x[4] / w0;
        const w5 = x[5] / w0;
        const y1 = 0.5 * w1;
        const y2 = w2 - y1 * y1;
        const y3 = 3.0 * w3 - 3.0 * y1 * y2;
        const y4 = 12.0 * w4 - 3.0 * y2 * y2 - 4.0 * y1 * y3;
        const y5 = 60.0 * w5 - 5.0 * y1 * y4 - 10.0 * y2 * y3;
        const y6 = -10.0 * y3 * y3 - 15.0 * y2 * y4 - 6.0 * y1 * y5;
        const delay = @sqrt(w0) * self.length / self.scaling_f;
        const atten = @exp(-delay * y1);
        var a: [6]f64 = .{ 0, y2 / 2.0, y3 / 6.0, y4 / 24.0, y5 / 120.0, y6 / 720.0 };
        for (1..6) |i| a[i] *= -delay;
        var b: [DEG + 1]f64 = @splat(0);
        b[0] = 1.0;
        b[1] = a[1];
        for (2..6) |i| {
            var s: f64 = 0;
            for (1..i + 1) |j| s += @as(f64, @floatFromInt(j)) * a[j] * b[i - j];
            b[i] = s / @as(f64, @floatFromInt(i));
        }
        for (0..6) |i| b[i] *= atten;
        x.* = b;
        return delay;
    }

    fn multP(p1: []const f64, p2: []const f64, p3: *[DEG + 1]f64) void {
        for (0..DEG + 1) |i| p3[i] = 0.0;
        for (0..DEG + 1) |i| {
            var j = i;
            var k: usize = 0;
            while (k <= DEG) : ({
                j += 1;
                k += 1;
            }) {
                if (j > DEG) break;
                p3[j] += p1[i] * p2[k];
            }
        }
    }
};

// ---------------------------------------------------------------------------
// The device.
// ---------------------------------------------------------------------------

pub fn CoupledLtra(comptime N: usize) type {
    const NU = 4 * N;
    const TRI = N * (N + 1) / 2;
    return struct {
        pub const U = @Enum(u8, .exhaustive, names: {
            var names: [NU][]const u8 = undefined;
            for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("u{d}", .{i});
            const frozen = names;
            break :names &frozen;
        }, vals: {
            var vals: [NU]u8 = undefined;
            for (&vals, 0..) |*v, i| v.* = i;
            const frozen = vals;
            break :vals &frozen;
        });
        pub const num_ports: usize = 2 * N;
        const n_u = NU;

        inline fn p1(k: usize) usize {
            return k;
        }
        inline fn p2(k: usize) usize {
            return N + k;
        }
        inline fn br1(m: usize) usize {
            return 2 * N + m;
        }
        inline fn br2(m: usize) usize {
            return 3 * N + m;
        }

        pub const u_kinds = blk: {
            var k: [n_u]contract.UnknownKind = undefined;
            for (0..2 * N) |i| k[i] = .voltage;
            for (2 * N..n_u) |i| k[i] = .current;
            break :blk k;
        };
        pub const u_abstol = blk: {
            var a: [n_u]f64 = undefined;
            for (0..2 * N) |i| a[i] = 1e-6;
            for (2 * N..n_u) |i| a[i] = 1e-12;
            break :blk a;
        };

        pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };
        pub const unrevertible_state = true;
        pub const mc_param = "length";

        pub const Model = struct {
            rr: [TRI]f64 = @splat(0),
            ll: [TRI]f64 = @splat(0),
            cc: [TRI]f64 = @splat(0),
            gg: [TRI]f64 = @splat(0),
            length: f64 = 0,

            ok: bool = false,
            taul: [N]f64 = @splat(0), // ps
            max_taul: f64 = 0, // ps
            min_tau_s: f64 = inf,
            rdiag: [N]f64 = @splat(0), // clamped R[m][m]·length, DC rows
            h1t: [N][N]Tms = @splat(@splat(.{})),
            h2t: [N][N][N]Tms = @splat(@splat(@splat(.{}))),
            h3t: [N][N][N]Tms = @splat(@splat(@splat(.{}))),
            h1c: [N][N]f64 = @splat(@splat(0)),
        };

        /// Convolution accumulators for one TMS entry set (3 terms × both
        /// ends). Pending slots carry the h2/h3 advance to the attempted
        /// timepoint (ngspice's cplines2 scratch copy).
        const Cnv = struct {
            i: [3]f64 = @splat(0),
            o: [3]f64 = @splat(0),
        };

        pub const Instance = struct {
            abstime: f64 = 0,
            dt: f64 = 0,
            analysis_kind: AnalysisKind = .dc,
            bound_step: f64 = inf,

            cache_t: f64 = 1e31,
            cache_dt: f64 = 1e31,

            cnv1: [N][N]Cnv = @splat(@splat(.{})),
            cnv2: [N][N][N]Cnv = @splat(@splat(@splat(.{}))),
            cnv3: [N][N][N]Cnv = @splat(@splat(@splat(.{}))),
            p2c: [N][N][N]Cnv = @splat(@splat(@splat(.{}))), // pending h2
            p3c: [N][N][N]Cnv = @splat(@splat(@splat(.{}))), // pending h3
            h1e: [N][N][3]f64 = @splat(@splat(@splat(0))),
            in1: [N]f64 = @splat(0), // cached RHS (ff/gg)
            in2: [N]f64 = @splat(0),

            vprev_i: [N]f64 = @splat(0),
            vprev_o: [N]f64 = @splat(0),
            dv_i: [N]f64 = @splat(0), // volts per ps
            dv_o: [N]f64 = @splat(0),
            dc1: [N]f64 = @splat(0),
            dc2: [N]f64 = @splat(0),

            n_hist: u32 = 0,
            hist_t: [CAP]f64 = @splat(0), // integer ps
            hist_vi: [N][CAP]f64 = @splat(@splat(0)),
            hist_vo: [N][CAP]f64 = @splat(@splat(0)),
            hist_ii: [N][CAP]f64 = @splat(@splat(0)),
            hist_io: [N][CAP]f64 = @splat(@splat(0)),
        };

        pub fn precompute(_: *Instance, model: *Model) void {
            model.ok = false;
            var s: Setup = .{
                .n = N,
                .length = model.length,
                .r = @splat(@splat(0)),
                .g = @splat(@splat(0)),
                .l = @splat(@splat(0)),
                .c = @splat(@splat(0)),
            };
            var idx: usize = 0;
            for (0..N) |i| {
                for (i..N) |j| {
                    const rv = @max(model.rr[idx], 1.0e-4); // ReadCpL clamp
                    s.r[i][j] = rv;
                    s.r[j][i] = rv;
                    s.g[i][j] = model.gg[idx];
                    s.g[j][i] = model.gg[idx];
                    s.l[i][j] = model.ll[idx];
                    s.l[j][i] = model.ll[idx];
                    s.c[i][j] = model.cc[idx];
                    s.c[j][i] = model.cc[idx];
                    idx += 1;
                }
            }
            for (0..N) |m| model.rdiag[m] = s.r[m][m] * model.length;

            if (model.length <= 0) return;
            // coupled():
            s.scaling_f = 1;
            s.scaling_f2 = 1;
            s.loopZY(0.0);
            {
                var minv = s.d[0];
                for (1..N) |i| minv = @min(minv, s.d[i]);
                if (minv <= 0) return;
                s.scaling_f2 = 1.0 / minv;
                s.scaling_f = @sqrt(s.scaling_f2);
                const step = s.length * 8.0;
                s.freq[0] = 0.0;
                for (1..DEG + 1) |i| s.freq[i] = s.freq[i - 1] + step;
                for (0..N) |i| s.d[i] *= s.scaling_f2;
            }
            s.evalSi(0.0);
            storeAll(&s, 0);
            for (1..DEG + 1) |i| {
                s.loopZY(s.freq[i]);
                s.evalSi(s.freq[i]);
                storeAll(&s, i);
            }
            for (0..N) |i| {
                for (0..N) |j| {
                    matchFit(&s.sip[i][j], s.freq, s.sip[i][j]);
                    matchFit(&s.si_1p[i][j], s.freq, s.si_1p[i][j]);
                    matchFit(&s.sv_1p[i][j], s.freq, s.sv_1p[i][j]);
                }
            }
            for (0..N) |i| {
                matchFit(&s.w[i], s.freq, s.w[i]);
                s.tau[i] = s.approxMode(&s.w[i]);
            }
            // IWI = Sip·diag(W)·Si_1p, IWV = Sip·diag(W)·Sv_1p, per entry:
            // C_0 + normalized series → Padé.
            var t: [MAXN][MAXN][DEG + 1]f64 = undefined;
            inline for (.{ false, true }) |use_sv| {
                for (0..N) |i| {
                    for (0..N) |j| {
                        const b = if (use_sv) &s.sv_1p[i][j] else &s.si_1p[i][j];
                        Setup.multP(b, &s.w[i], &t[i][j]);
                    }
                }
                for (0..N) |i| {
                    for (0..N) |j| {
                        for (0..N) |k| {
                            var p: [DEG + 1]f64 = undefined;
                            Setup.multP(&s.sip[i][k], &t[k][j], &p);
                            const c0 = p[0];
                            const tms = if (use_sv) &model.h3t[i][j][k] else &model.h2t[i][j][k];
                            tms.aten = 0;
                            if (c0 == 0.0) continue;
                            p[0] = 1.0;
                            for (1..DEG + 1) |dgi| p[dgi] /= c0;
                            const a_b: f64 = if (i == j and k == i) blk: {
                                const grr = @sqrt(s.g[i][i] * s.r[i][i]);
                                break :blk if (use_sv)
                                    @sqrt(s.g[i][i] / s.r[i][i]) * @exp(-grr * s.length) / c0
                                else
                                    @exp(-grr * s.length) / c0;
                            } else 0.0;
                            if (!padeApx(a_b, &p, tms)) continue; // entry dropped, as the reference does
                            tms.aten = c0;
                        }
                    }
                }
            }
            // SIV = fitted Si·Sv⁻¹ entries → h1t.
            for (0..N) |i| {
                for (0..N) |j| {
                    matchFit(&s.sisv_1[i][j], s.freq, s.sisv_1[i][j]);
                    var p = s.sisv_1[i][j];
                    const c0 = p[0];
                    model.h1t[i][j].aten = 0;
                    if (c0 == 0.0) continue;
                    for (0..DEG + 1) |dgi| p[dgi] /= c0;
                    const a_b: f64 = if (i == j) @sqrt(s.g[i][i] / s.r[i][i]) / c0 else 0.0;
                    if (!padeApx(a_b, &p, &model.h1t[i][j])) continue;
                    model.h1t[i][j].aten = c0;
                }
            }

            // ReadCpL folding: taul in ps; c scaled by aten; h1C per entry.
            model.min_tau_s = inf;
            model.max_taul = 0;
            for (0..N) |i| {
                model.taul[i] = s.tau[i] * 1.0e12;
                model.min_tau_s = @min(model.min_tau_s, s.tau[i]);
                model.max_taul = @max(model.max_taul, model.taul[i]);
            }
            for (0..N) |i| {
                for (0..N) |j| {
                    const h1 = &model.h1t[i][j];
                    if (h1.aten != 0) {
                        for (0..3) |k| h1.c[k] *= h1.aten;
                        model.h1c[i][j] = if (h1.if_img) h1.c[0] + 2.0 * h1.c[1] else h1.c[0] + h1.c[1] + h1.c[2];
                    } else {
                        // cplload dereferences h1t unconditionally; a missing
                        // entry is a hard error there. Treat as zero row.
                        model.h1c[i][j] = 0;
                    }
                    for (0..N) |k| {
                        const t2 = &model.h2t[i][j][k];
                        if (t2.aten != 0) {
                            for (0..3) |ki| t2.c[ki] *= t2.aten;
                        }
                        const t3 = &model.h3t[i][j][k];
                        if (t3.aten != 0) {
                            for (0..3) |ki| t3.c[ki] *= t3.aten;
                        }
                    }
                }
            }
            model.ok = true;
        }

        fn storeAll(s: *Setup, ind: usize) void {
            for (0..N) |i| {
                for (0..N) |j| {
                    s.sip[i][j][ind] = s.si[i][j];
                    s.si_1p[i][j][ind] = s.si_1[i][j];
                    s.sv_1p[i][j][ind] = s.sv_1[i][j];
                    var acc: f64 = 0;
                    for (0..N) |k| acc += s.si[i][k] * s.sv_1[k][j];
                    s.sisv_1[i][j][ind] = acc;
                }
                s.w[i][ind] = s.d[i];
            }
        }

        // -- delayed interpolation (get_pvs_vi): per mode l, conductor k --
        const Delayed = struct {
            v1_i: [N][N]f64, // [mode][conductor]
            v1_o: [N][N]f64,
            i1_i: [N][N]f64,
            i1_o: [N][N]f64,
            v2_i: [N][N]f64,
            v2_o: [N][N]f64,
            i2_i: [N][N]f64,
            i2_o: [N][N]f64,
        };

        fn getPvs(inst: anytype, model: *const Model, t1: f64, t2: f64) Delayed {
            var d: Delayed = undefined;
            const n = inst.n_hist;
            for (0..N) |l| {
                const ta = t1 - model.taul[l];
                var tb = t2 - model.taul[l];
                if (tb > t1) tb = t1; // ext cut off by the 0.9τ step bound
                if (tb <= 0) {
                    for (0..N) |k| {
                        d.i1_i[l][k] = 0;
                        d.i2_i[l][k] = 0;
                        d.i1_o[l][k] = 0;
                        d.i2_o[l][k] = 0;
                        d.v1_i[l][k] = inst.dc1[k];
                        d.v2_i[l][k] = inst.dc1[k];
                        d.v1_o[l][k] = inst.dc2[k];
                        d.v2_o[l][k] = inst.dc2[k];
                    }
                    continue;
                }
                var j: usize = 1;
                if (ta <= 0) {
                    for (0..N) |k| {
                        d.i1_i[l][k] = 0;
                        d.i1_o[l][k] = 0;
                        d.v1_i[l][k] = inst.dc1[k];
                        d.v1_o[l][k] = inst.dc2[k];
                    }
                } else {
                    while (j + 1 < n and inst.hist_t[j] < ta) j += 1;
                    const f = (ta - inst.hist_t[j - 1]) / (inst.hist_t[j] - inst.hist_t[j - 1]);
                    for (0..N) |k| {
                        d.v1_i[l][k] = inst.hist_vi[k][j - 1] + f * (inst.hist_vi[k][j] - inst.hist_vi[k][j - 1]);
                        d.v1_o[l][k] = inst.hist_vo[k][j - 1] + f * (inst.hist_vo[k][j] - inst.hist_vo[k][j - 1]);
                        d.i1_i[l][k] = inst.hist_ii[k][j - 1] + f * (inst.hist_ii[k][j] - inst.hist_ii[k][j - 1]);
                        d.i1_o[l][k] = inst.hist_io[k][j - 1] + f * (inst.hist_io[k][j] - inst.hist_io[k][j - 1]);
                    }
                }
                while (j + 1 < n and inst.hist_t[j] < tb) j += 1;
                const f = (tb - inst.hist_t[j - 1]) / (inst.hist_t[j] - inst.hist_t[j - 1]);
                for (0..N) |k| {
                    d.v2_i[l][k] = inst.hist_vi[k][j - 1] + f * (inst.hist_vi[k][j] - inst.hist_vi[k][j - 1]);
                    d.v2_o[l][k] = inst.hist_vo[k][j - 1] + f * (inst.hist_vo[k][j] - inst.hist_vo[k][j - 1]);
                    d.i2_i[l][k] = inst.hist_ii[k][j - 1] + f * (inst.hist_ii[k][j] - inst.hist_ii[k][j - 1]);
                    d.i2_o[l][k] = inst.hist_io[k][j - 1] + f * (inst.hist_io[k][j] - inst.hist_io[k][j - 1]);
                }
            }
            return d;
        }

        /// right_consts: h1 exp caches + RHS, h2/h3 pending advances + RHS.
        fn rebuild(model: *const Model, inst: *Instance, h: f64, t2_ps: f64) void {
            const h1 = 0.5 * h;
            var ff: [N]f64 = @splat(0);
            var gg: [N]f64 = @splat(0);

            for (0..N) |j| {
                for (0..N) |k| {
                    const tms = &model.h1t[j][k];
                    if (tms.aten == 0) continue;
                    if (tms.if_img) {
                        const e = @exp(tms.x[0] * h);
                        inst.h1e[j][k][0] = e;
                        const er = @exp(tms.x[1] * h) * @cos(tms.x[2] * h);
                        const ei = @exp(tms.x[1] * h) * @sin(tms.x[2] * h);
                        inst.h1e[j][k][1] = er;
                        inst.h1e[j][k][2] = ei;
                        const ff1 = tms.c[0] * e * h1;
                        ff[j] -= inst.cnv1[j][k].i[0] * e;
                        gg[j] -= inst.cnv1[j][k].o[0] * e;
                        ff[j] -= ff1 * inst.vprev_i[k];
                        gg[j] -= ff1 * inst.vprev_o[k];
                        const a1 = tms.c[1] * er - tms.c[2] * ei;
                        const ai_ = inst.cnv1[j][k].i[1] * er - inst.cnv1[j][k].i[2] * ei;
                        ff[j] -= 2.0 * (a1 * h1 * inst.vprev_i[k] + ai_);
                        const ao_ = inst.cnv1[j][k].o[1] * er - inst.cnv1[j][k].o[2] * ei;
                        gg[j] -= 2.0 * (a1 * h1 * inst.vprev_o[k] + ao_);
                    } else {
                        var ff1: f64 = 0;
                        for (0..3) |i| {
                            const e = @exp(tms.x[i] * h);
                            inst.h1e[j][k][i] = e;
                            ff1 -= tms.c[i] * e;
                            ff[j] -= inst.cnv1[j][k].i[i] * e;
                            gg[j] -= inst.cnv1[j][k].o[i] * e;
                        }
                        ff[j] += ff1 * h1 * inst.vprev_i[k];
                        gg[j] += ff1 * h1 * inst.vprev_o[k];
                    }
                }
            }

            const t1 = inst.hist_t[inst.n_hist - 1];
            const del = getPvs(inst, model, t1, t2_ps);

            for (0..N) |j| {
                for (0..N) |k| {
                    for (0..N) |l| {
                        const tms = &model.h3t[j][k][l];
                        if (tms.aten == 0) continue;
                        const v1i = del.v1_i[l][k];
                        const v2i = del.v2_i[l][k];
                        const v1o = del.v1_o[l][k];
                        const v2o = del.v2_o[l][k];
                        const cm = &inst.cnv3[j][k][l];
                        const pd = &inst.p3c[j][k][l];
                        if (tms.if_img) {
                            const er = @exp(tms.x[1] * h) * @cos(tms.x[2] * h);
                            const ei = @exp(tms.x[1] * h) * @sin(tms.x[2] * h);
                            const a2 = h1 * tms.c[1];
                            const b2 = h1 * tms.c[2];
                            var ar = cm.i[1] * er - cm.i[2] * ei;
                            var ai_ = cm.i[1] * ei + cm.i[2] * er;
                            pd.i[1] = ar + a2 * (v1i * er + v2i) - b2 * (v1i * ei);
                            pd.i[2] = ai_ + a2 * (v1i * ei) + b2 * (v1i * er + v2i);
                            ar = cm.o[1] * er - cm.o[2] * ei;
                            ai_ = cm.o[1] * ei + cm.o[2] * er;
                            pd.o[1] = ar + a2 * (v1o * er + v2o) - b2 * (v1o * ei);
                            pd.o[2] = ai_ + a2 * (v1o * ei) + b2 * (v1o * er + v2o);
                            const e = @exp(tms.x[0] * h);
                            pd.i[0] = cm.i[0] * e + h1 * tms.c[0] * (v1i * e + v2i);
                            pd.o[0] = cm.o[0] * e + h1 * tms.c[0] * (v1o * e + v2o);
                            ff[j] += tms.aten * v2o + pd.o[0] + 2.0 * pd.o[1];
                            gg[j] += tms.aten * v2i + pd.i[0] + 2.0 * pd.i[1];
                        } else {
                            for (0..3) |i| {
                                const e = @exp(tms.x[i] * h);
                                pd.i[i] = cm.i[i] * e + h1 * tms.c[i] * (v1i * e + v2i);
                                pd.o[i] = cm.o[i] * e + h1 * tms.c[i] * (v1o * e + v2o);
                                ff[j] += pd.o[i];
                                gg[j] += pd.i[i];
                            }
                            ff[j] += tms.aten * v2o;
                            gg[j] += tms.aten * v2i;
                        }
                    }
                }
                for (0..N) |k| {
                    for (0..N) |l| {
                        const tms = &model.h2t[j][k][l];
                        if (tms.aten == 0) continue;
                        const i1i = del.i1_i[l][k];
                        const i2i = del.i2_i[l][k];
                        const i1o = del.i1_o[l][k];
                        const i2o = del.i2_o[l][k];
                        const cm = &inst.cnv2[j][k][l];
                        const pd = &inst.p2c[j][k][l];
                        if (tms.if_img) {
                            const er = @exp(tms.x[1] * h) * @cos(tms.x[2] * h);
                            const ei = @exp(tms.x[1] * h) * @sin(tms.x[2] * h);
                            const a2 = h1 * tms.c[1];
                            const b2 = h1 * tms.c[2];
                            var ar = cm.i[1] * er - cm.i[2] * ei;
                            var ai_ = cm.i[1] * ei + cm.i[2] * er;
                            pd.i[1] = ar + a2 * (i1i * er + i2i) - b2 * (i1i * ei);
                            pd.i[2] = ai_ + a2 * (i1i * ei) + b2 * (i1i * er + i2i);
                            ar = cm.o[1] * er - cm.o[2] * ei;
                            ai_ = cm.o[1] * ei + cm.o[2] * er;
                            pd.o[1] = ar + a2 * (i1o * er + i2o) - b2 * (i1o * ei);
                            pd.o[2] = ai_ + a2 * (i1o * ei) + b2 * (i1o * er + i2o);
                            const e = @exp(tms.x[0] * h);
                            pd.i[0] = cm.i[0] * e + h1 * tms.c[0] * (i1i * e + i2i);
                            pd.o[0] = cm.o[0] * e + h1 * tms.c[0] * (i1o * e + i2o);
                            ff[j] += tms.aten * i2o + pd.o[0] + 2.0 * pd.o[1];
                            gg[j] += tms.aten * i2i + pd.i[0] + 2.0 * pd.i[1];
                        } else {
                            for (0..3) |i| {
                                const e = @exp(tms.x[i] * h);
                                pd.i[i] = cm.i[i] * e + h1 * tms.c[i] * (i1i * e + i2i);
                                pd.o[i] = cm.o[i] * e + h1 * tms.c[i] * (i1o * e + i2o);
                                ff[j] += pd.o[i];
                                gg[j] += pd.i[i];
                            }
                            ff[j] += tms.aten * i2o;
                            gg[j] += tms.aten * i2i;
                        }
                    }
                }
            }
            inst.in1 = ff;
            inst.in2 = gg;
        }

        pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, t: f64) [n_u]S {
            var res = [_]S{S.con(0.0)} ** n_u;
            for (0..N) |k| {
                res[p1(k)] = x[br1(k)];
                res[p2(k)] = x[br2(k)];
            }

            if (inst.dt <= 0.0 or inst.analysis_kind != .tran or !model.ok or inst.n_hist == 0) {
                // cplload cond1: per conductor, i1 + i2 = 0 and
                // v1 − v2 = R[m][m]·len·i1 (diagonal R only, as the
                // reference's resindex walk stamps).
                for (0..N) |m| {
                    res[br1(m)] = x[br1(m)].add(x[br2(m)]);
                    res[br2(m)] = x[p1(m)].sub(x[p2(m)]).sub(x[br1(m)].scale(model.rdiag[m]));
                }
                return res;
            }

            const ii: *Instance = @constCast(inst);
            if (ii.cache_t != t or ii.cache_dt != inst.dt) {
                rebuild(model, ii, inst.dt, @trunc(t * 1e12));
                ii.cache_t = t;
                ii.cache_dt = inst.dt;
            }
            const h1 = 0.5 * inst.dt;
            for (0..N) |m| {
                var row1 = x[br1(m)].neg().addC(-ii.in1[m]);
                var row2 = x[br2(m)].neg().addC(-ii.in2[m]);
                for (0..N) |p| {
                    const yc = model.h1t[m][p].aten + h1 * model.h1c[m][p];
                    row1 = row1.add(x[p1(p)].scale(yc));
                    row2 = row2.add(x[p2(p)].scale(yc));
                }
                res[br1(m)] = row1;
                res[br2(m)] = row2;
            }
            return res;
        }

        pub const State = struct {};
        pub fn initState(_: *const Model, _: *Instance) State {
            return .{};
        }

        pub fn updateState(model: *Model, inst: *Instance, x: [n_u]f64, _: *State) contract.UpdateResult {
            if (inst.analysis_kind != .tran or !model.ok) return .ok;
            const t_ps: f64 = @trunc(inst.abstime * 1e12);

            if (inst.abstime == 0 or inst.n_hist == 0) {
                // cplload dc setup: steady h1/h3 states (complex pairs via
                // proper complex division), zero h2, one t=0 history point.
                inst.n_hist = 1;
                inst.hist_t[0] = 0;
                for (0..N) |k| {
                    const v1 = x[p1(k)];
                    const v2 = x[p2(k)];
                    inst.dc1[k] = v1;
                    inst.dc2[k] = v2;
                    inst.vprev_i[k] = v1;
                    inst.vprev_o[k] = v2;
                    inst.dv_i[k] = 0;
                    inst.dv_o[k] = 0;
                    inst.hist_vi[k][0] = v1;
                    inst.hist_vo[k][0] = v2;
                    inst.hist_ii[k][0] = 0;
                    inst.hist_io[k][0] = 0;
                }
                for (0..N) |i| {
                    for (0..N) |j| {
                        seedTms(&model.h1t[i][j], &inst.cnv1[i][j], inst.dc1[j], inst.dc2[j]);
                        for (0..N) |l| {
                            inst.cnv2[i][j][l] = .{};
                            seedTms(&model.h3t[i][j][l], &inst.cnv3[i][j][l], inst.dc1[j], inst.dc2[j]);
                        }
                    }
                }
                inst.cache_t = 1e31;
                inst.bound_step = 0.9 * model.min_tau_s;
                return .ok;
            }

            const tail = inst.hist_t[inst.n_hist - 1];
            if (t_ps <= tail) return .ok;

            if (inst.cache_t != inst.abstime or inst.cache_dt != inst.dt)
                rebuild(model, inst, inst.dt, t_ps);
            // Adopt the pending h2/h3 advances, then advance h1 over the
            // accepted segment (update_cnv / update_cnv_a).
            inst.cnv2 = inst.p2c;
            inst.cnv3 = inst.p3c;
            const delta = t_ps - tail;
            for (0..N) |k| {
                const v1 = x[p1(k)];
                const v2 = x[p2(k)];
                inst.dv_i[k] = (v1 - inst.vprev_i[k]) / delta;
                inst.dv_o[k] = (v2 - inst.vprev_o[k]) / delta;
                inst.vprev_i[k] = v1;
                inst.vprev_o[k] = v2;
            }
            for (0..N) |j| {
                for (0..N) |k| {
                    const tms = &model.h1t[j][k];
                    if (tms.aten == 0) continue;
                    const ai = inst.vprev_i[k];
                    const ao = inst.vprev_o[k];
                    var bi = inst.dv_i[k];
                    var bo = inst.dv_o[k];
                    const cv = &inst.cnv1[j][k];
                    if (tms.if_img) {
                        // update_cnv_a on the pair (note its h·0.5e-12 and
                        // bi−dv·h argument quirks, verbatim), then the real
                        // term's exact-segment formula.
                        const hh = delta * 0.5e-12;
                        const er = inst.h1e[j][k][1];
                        const ei = inst.h1e[j][k][2];
                        const a1r = tms.c[1] * er - tms.c[2] * ei;
                        const a1i = tms.c[1] * ei + tms.c[2] * er;
                        const bi_a = ai - bi * delta;
                        const bo_a = ao - bo * delta;
                        var ar = cv.i[1] * er - cv.i[2] * ei;
                        var aii = cv.i[1] * ei + cv.i[2] * er;
                        cv.i[1] = ar + hh * (a1r * bi_a + ai * tms.c[1]);
                        cv.i[2] = aii + hh * (a1i * bi_a + ai * tms.c[2]);
                        ar = cv.o[1] * er - cv.o[2] * ei;
                        aii = cv.o[1] * ei + cv.o[2] * er;
                        cv.o[1] = ar + hh * (a1r * bo_a + ao * tms.c[1]);
                        cv.o[2] = aii + hh * (a1i * bo_a + ao * tms.c[2]);
                        const e = inst.h1e[j][k][0];
                        const tt = tms.c[0] / tms.x[0];
                        const bit = bi * tt;
                        const bot = bo * tt;
                        cv.i[0] = (cv.i[0] - bit * delta) * e + (e - 1.0) * (ai * tt + 1.0e12 * bit / tms.x[0]);
                        cv.o[0] = (cv.o[0] - bot * delta) * e + (e - 1.0) * (ao * tt + 1.0e12 * bot / tms.x[0]);
                    } else {
                        // update_cnv quirk, verbatim: the slope accumulates
                        // the c/x product across terms (bi never resets).
                        for (0..3) |i| {
                            const e = inst.h1e[j][k][i];
                            const tt = tms.c[i] / tms.x[i];
                            bi *= tt;
                            bo *= tt;
                            cv.i[i] = (cv.i[i] - bi * delta) * e + (e - 1.0) * (ai * tt + 1.0e12 * bi / tms.x[i]);
                            cv.o[i] = (cv.o[i] - bo * delta) * e + (e - 1.0) * (ao * tt + 1.0e12 * bo / tms.x[i]);
                        }
                    }
                }
            }

            // Prune + append (shared axis).
            {
                const cutoff = t_ps - model.max_taul;
                var drop: u32 = 0;
                while (drop + 1 < inst.n_hist and inst.hist_t[drop + 1] < cutoff) drop += 1;
                if (drop > 64 or inst.n_hist == CAP) {
                    drop = @max(drop, @intFromBool(inst.n_hist == CAP));
                    const keep = inst.n_hist - drop;
                    std.mem.copyForwards(f64, inst.hist_t[0..keep], inst.hist_t[drop..inst.n_hist]);
                    for (0..N) |k| {
                        inline for (.{ "hist_vi", "hist_vo", "hist_ii", "hist_io" }) |f| {
                            const arr = &@field(inst, f)[k];
                            std.mem.copyForwards(f64, arr[0..keep], arr[drop..inst.n_hist]);
                        }
                    }
                    inst.n_hist = keep;
                }
            }
            const j = inst.n_hist;
            inst.hist_t[j] = t_ps;
            for (0..N) |k| {
                inst.hist_vi[k][j] = x[p1(k)];
                inst.hist_vo[k][j] = x[p2(k)];
                inst.hist_ii[k][j] = x[br1(k)];
                inst.hist_io[k][j] = x[br2(k)];
            }
            inst.n_hist = j + 1;
            inst.cache_t = 1e31;
            inst.bound_step = 0.9 * model.min_tau_s;
            return .ok;
        }

        fn seedTms(tms: *const Tms, cv: *Cnv, dc1: f64, dc2: f64) void {
            cv.* = .{};
            if (tms.aten == 0) return;
            if (tms.if_img) {
                cv.i[0] = -dc1 * tms.c[0] / tms.x[0];
                cv.o[0] = -dc2 * tms.c[0] / tms.x[0];
                const p = divC(tms.c[1], tms.c[2], tms.x[1], tms.x[2]);
                cv.i[1] = -dc1 * p[0];
                cv.i[2] = -dc1 * p[1];
                cv.o[1] = -dc2 * p[0];
                cv.o[2] = -dc2 * p[1];
            } else {
                for (0..3) |k| {
                    cv.i[k] = -dc1 * tms.c[k] / tms.x[k];
                    cv.o[k] = -dc2 * tms.c[k] / tms.x[k];
                }
            }
        }
    };
}

test "CPL setup matches the ngspice cplsetup pipeline (coupled_tlines card)" {
    // Goldens from the cplsetup.c math compiled standalone
    // (/tmp/cplfit_ref.c extraction, ngspice-44.2) on R=0.2 0 0.2,
    // L=9.13n 3.3n 9.13n, C=.365p -.09p .365p, G=0, length 10.
    const D = CoupledLtra(2);
    var model: D.Model = .{
        .rr = .{ 0.2, 0, 0.2 },
        .ll = .{ 9.13e-9, 3.3e-9, 9.13e-9 },
        .cc = .{ 0.365e-12, -0.09e-12, 0.365e-12 },
        .gg = .{ 0, 0, 0 },
        .length = 10,
    };
    var inst: D.Instance = .{};
    D.precompute(&inst, &model);
    try std.testing.expect(model.ok);
    const eq = struct {
        fn f(want: f64, got: f64) !void {
            try std.testing.expectApproxEqRel(want, got, 1e-6);
        }
    }.f;
    try eq(584.65801970040559, model.taul[0]);
    try eq(515.03883348733996, model.taul[1]);
    // SIV[0][0]: C0, poles; c scaled by aten in the model.
    try eq(0.0067689448252243435, model.h1t[0][0].aten);
    try std.testing.expect(!model.h1t[0][0].if_img);
    try eq(-0.0048889702141035277, model.h1t[0][0].x[0]);
    try eq(1.2358159135175167e-06 * 0.0067689448252243435, model.h1t[0][0].c[0]);
    try eq(-0.0020653404833063586, model.h1t[0][1].aten);
    // IWI[0][0][0]: img pair.
    try eq(0.49999999999993477, model.h2t[0][0][0].aten);
    try std.testing.expect(model.h2t[0][0][0].if_img);
    try eq(-0.00038843728876919795, model.h2t[0][0][0].x[0]);
    try eq(-0.017076138072357659, model.h2t[0][0][0].x[1]);
    try eq(0.012191062272522618, model.h2t[0][0][0].x[2]);
    try eq(0.00041042630919461645 * 0.49999999999993477, model.h2t[0][0][0].c[0]);
    // IWV[1][1][1].
    try eq(0.0044171426542627835, model.h3t[1][1][1].aten);
    try eq(0.015519183492600154, model.h3t[1][1][1].x[0]);
}
