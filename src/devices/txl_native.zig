//! txl_native — ngspice's TXL lossy line (Y card), the Hough/SWEC method:
//! [3/3] Padé fits of the characteristic admittance Y(s) and propagation
//! H(s) at setup, then O(1)-per-step recursive convolution of the resulting
//! exponential kernels. Ported from txlsetup.c / txlload.c, deliberately
//! bug-compatible (integer-picosecond history times, the h3 complex-pair DC
//! seed using real division, the h2-fit "aten" folding order): the golden
//! decks were produced by this exact algorithm, so matching its numbers IS
//! the spec. The physics-exact alternative already exists (ltra_native's
//! Bessel convolution) and measurably disagrees with ngspice's TXL by ~1e-1
//! on the txl fixtures — approximation identity, not accuracy, is what the
//! benchmark tests.
//!
//! Data (DOD): one instance = 4 unknowns (2 ground-referenced ports — the Y
//! card's reference nodes are discarded, as inp2y.c does — + 2 branch
//! currents), 24 committed + 21 pending convolution scalars, and a pruned
//! accepted-step history of 5 parallel arrays. Access: history walked once
//! per TIMEPOINT around t − τ (delayed interpolation); Newton iterations
//! replay 3 cached scalars. Instances are independent (ParEval-safe).
//! ngspice's txline/txline2 commit/scratch pair maps onto committed fields +
//! pending fields: eval rebuilds pending, updateState adopts them on accept.

const std = @import("std");
const contract = @import("contract");

const Self = @This();
const inf = std.math.inf(f64);

pub const U = enum(u8) { p1, p2, br1, br2 };
pub const num_ports: usize = 2;
const n_u = contract.nU(Self);

pub const u_kinds = [n_u]contract.UnknownKind{ .voltage, .voltage, .current, .current };
pub const u_abstol = [n_u]f64{ 1e-6, 1e-6, 1e-12, 1e-12 };

pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };
pub const unrevertible_state = true;
pub const mc_param = "len";

/// History capacity. The delayed interpolation only ever looks τ back
/// (~25 points at fixture grids); the front-prune in updateState keeps the
/// live window tiny, so this bounds burst growth between prunes only.
const CAP = 2048;

// ---------------------------------------------------------------------------
// Padé fitting (txlsetup.c y_pade / exp_pade / get_h3 / update_h1C_c),
// shared with the coupled-line device: coupled_ltra fits one LineFit per
// mode. All times inside the fit are seconds; `taul` is exported in ps
// (SWEC's integer-time unit, kept for bug-compatible history bookkeeping).
// ---------------------------------------------------------------------------

pub const LineFit = struct {
    ok: bool = false, // false: Y-fit hit complex roots (ngspice exits; we fall back)
    lsl: bool = false, // lossless shortcut (R/L < 5e5, G < 1e-2)
    if_img: bool = false, // propagation fit produced a complex pole pair
    sqtCdL: f64 = 0,
    taul: f64 = 0, // ps
    h1C: f64 = 0,
    h2_aten: f64 = 0,
    h3_aten: f64 = 0,
    h1_c: [3]f64 = @splat(0),
    h1_x: [3]f64 = @splat(0),
    h2_c: [3]f64 = @splat(0),
    h2_x: [3]f64 = @splat(0),
    h3_c: [6]f64 = @splat(0),
    h3_x: [6]f64 = @splat(0),
};

fn eval2(a: f64, b: f64, c: f64, x: f64) f64 {
    return a * x * x + b * x + c;
}

/// (ar + j·ai) / (br + j·bi), txlsetup div_C spelling.
fn divC(ar: f64, ai: f64, br: f64, bi: f64) [2]f64 {
    const d = br * br + bi * bi;
    return .{ (ar * br + ai * bi) / d, (-ar * bi + ai * br) / d };
}

/// Maclaurin of F(z) = sqrt((1+az)/(1+bz)) — txlsetup mac(), verbatim.
fn mac(a: f64, b: f64) [5]f64 {
    const y1 = 0.5 * (a - b);
    const y2 = 0.5 * (3.0 * b * b - 2.0 * a * b - a * a) * y1 / (a - b);
    const y3 = ((3.0 * b * b + a * a) * y1 * y1 + 0.5 * (3.0 * b * b - 2.0 * a * b - a * a) * y2) / (a - b);
    const y4 = ((3.0 * b * b - 3.0 * a * a) * y1 * y1 * y1 + (9.0 * b * b + 3.0 * a * a) * y1 * y2 +
        0.5 * (3.0 * b * b - 2.0 * a * b - a * a) * y3) / (a - b);
    const y5 = (12.0 * a * a * y1 * y1 * y1 * y1 + y1 * y1 * y2 * (18.0 * b * b - 18.0 * a * a) +
        (9.0 * b * b + 3.0 * a * a) * (y2 * y2 + y1 * y3) + (3.0 * b * b + a * a) * y1 * y3 +
        0.5 * (3.0 * b * b - 2.0 * a * b - a * a) * y4) / (a - b);
    return .{ y1, y2 / 2.0, y3 / 6.0, y4 / 24.0, y5 / 120.0 };
}

/// In-place 3x4 Gauss with partial pivot (Gaussian_Elimination1/2; the two
/// differ only in the give-up epsilon). Returns false on pivot collapse.
fn gauss3(a: *[3][4]f64, epsilon: f64) bool {
    for (0..3) |i| {
        var imax = i;
        var max = @abs(a[i][i]);
        for (i + 1..3) |j| {
            if (@abs(a[j][i]) > max) {
                imax = j;
                max = @abs(a[j][i]);
            }
        }
        if (max < epsilon) return false;
        if (imax != i) std.mem.swap([4]f64, &a[i], &a[imax]);
        const f = 1.0 / a[i][i];
        a[i][i] = 1.0;
        for (i + 1..4) |j| a[i][j] *= f;
        for (0..3) |j| {
            if (i == j) continue;
            const f2 = a[j][i];
            a[j][i] = 0.0;
            for (i + 1..4) |k| a[j][k] -= f2 * a[i][k];
        }
    }
    return true;
}

fn root3(a1: f64, a2: f64, a3: f64, x: f64) f64 {
    const t1 = x * x * x + a1 * x * x + a2 * x + a3;
    const t2 = 3.0 * x * x + 2.0 * a1 * x + a2;
    return x - t1 / t2;
}

const Roots = struct { x1: f64, x2: f64, x3: f64, img: bool };

/// Cubic roots, txlsetup find_roots/exp_find_roots. `scale` is the reference's
/// overflow dance on the discriminant (1e-18/1e9 for Y, 1e-16/1e8 for exp);
/// `allow_img` selects the exp variant (complex pair instead of failure).
fn findRoots(a1_in: f64, a2_in: f64, a3_in: f64, comptime allow_img: bool, comptime scale: f64) ?Roots {
    var a1 = a1_in;
    var a2 = a2_in;
    const q = (a1 * a1 - 3.0 * a2) / 9.0;
    const p = (2.0 * a1 * a1 * a1 - 9.0 * a1 * a2 + 27.0 * a3_in) / 54.0;
    const disc = q * q * q - p * p;
    var x: f64 = undefined;
    if (disc >= 0.0) {
        const t = std.math.acos(p / (q * @sqrt(q)));
        x = -2.0 * @sqrt(q) * @cos(t / 3.0) - a1 / 3.0;
    } else if (p > 0.0) {
        const t = std.math.pow(f64, @sqrt(-disc) + p, 1.0 / 3.0);
        x = -(t + q / t) - a1 / 3.0;
    } else if (p == 0.0) {
        x = -a1 / 3.0;
    } else {
        const t = std.math.pow(f64, @sqrt(-disc) - p, 1.0 / 3.0);
        x = (t + q / t) - a1 / 3.0;
    }
    // Newton polish, 5e-4 ABSOLUTE stop with 32-iteration revert (verbatim).
    {
        const backup = x;
        var i: u32 = 0;
        var t = root3(a1, a2, a3_in, x);
        while (@abs(t - x) > 5.0e-4) : (t = root3(a1, a2, a3_in, x)) {
            i += 1;
            if (i == 32) {
                x = backup;
                break;
            }
            x = t;
        }
    }
    const x1 = x;
    // Deflate: s² + (a1+x)s + (−a3/x).
    a1 = a1_in + x;
    a2 = -a3_in / x;
    var t = a1 * a1 - 4.0 * a2;
    if (t < 0) {
        if (!allow_img) return null;
        return .{ .x1 = x1, .x2 = -0.5 * a1, .x3 = 0.5 * @sqrt(-t), .img = true };
    }
    t *= scale * scale;
    t = @sqrt(t) / scale;
    const x2 = if (a1 >= 0.0) -0.5 * (a1 + t) else -0.5 * (a1 - t);
    return .{ .x1 = x1, .x2 = x2, .x3 = a2 / x2, .img = false };
}

/// txlsetup get_c: residue of the [3/3] fit at the complex pole a + j·b.
fn getC(eq1: f64, eq2: f64, eq3: f64, ep1: f64, ep2: f64, a: f64, b: f64) [2]f64 {
    var d = (3.0 * (a * a - b * b) + 2.0 * ep1 * a + ep2) * (3.0 * (a * a - b * b) + 2.0 * ep1 * a + ep2);
    d += (6.0 * a * b + 2.0 * ep1 * b) * (6.0 * a * b + 2.0 * ep1 * b);
    var n = -(eq1 * (a * a - b * b) + eq2 * a + eq3) * (6.0 * a * b + 2.0 * ep1 * b);
    n += (2.0 * eq1 * a * b + eq2 * b) * (3.0 * (a * a - b * b) + 2.0 * ep1 * a + ep2);
    const ci = n / d;
    n = (3.0 * (a * a - b * b) + 2.0 * ep1 * a + ep2) * (eq1 * (a * a - b * b) + eq2 * a + eq3);
    n += (6.0 * a * b + 2.0 * ep1 * b) * (2.0 * eq1 * a * b + eq2 * b);
    return .{ n / d, ci };
}

/// Full main_pade chain for one line's per-unit-length RLGC and length.
pub fn fitLine(r_in: f64, l_in: f64, g: f64, c: f64, len: f64) LineFit {
    var fit: LineFit = .{};
    const l_ = @max(l_in, 1e-12); // ReadTxL's LL floor
    if (r_in / l_ < 5.0e5 and g < 1.0e-2) {
        fit.ok = true;
        fit.lsl = true;
        fit.taul = @sqrt(c * l_) * len * 1.0e12;
        fit.sqtCdL = @sqrt(c / l_);
        fit.h3_aten = fit.sqtCdL;
        fit.h2_aten = 1.0;
        return fit;
    }

    const sqtCdL = @sqrt(c / l_);
    const rdl = r_in / l_;
    const gdc = g / c;

    // --- y_pade: Y(s)/sqtCdL ≈ 1 + Σ c_i/(s − x_i) ---
    {
        const b = mac(gdc, rdl);
        var a: [3][4]f64 = .{
            .{ 1.0 - @sqrt(gdc / rdl), b[0], b[1], -b[2] },
            .{ b[0], b[1], b[2], -b[3] },
            .{ b[1], b[2], b[3], -b[4] },
        };
        if (!gauss3(&a, 1.0e-16)) return fit;
        const p3 = a[0][3];
        const p2 = a[1][3];
        const p1 = a[2][3];
        const q1 = p1 + b[0];
        const q2 = b[0] * p1 + p2 + b[1];
        const q3 = p3 * @sqrt(gdc / rdl);
        const roots = findRoots(p1, p2, p3, false, 1.0e9) orelse return fit;
        fit.h1_x = .{ roots.x1, roots.x2, roots.x3 };
        for (0..3) |i| {
            fit.h1_c[i] = eval2(q1 - p1, q2 - p2, q3 - p3, fit.h1_x[i]) /
                eval2(3.0, 2.0 * p1, p2, fit.h1_x[i]);
        }
        fit.sqtCdL = sqtCdL;
    }

    // --- exp_pade: H(s)·e^{sτl} ≈ e^{−a0}·(1 + Σ ec_i/(s − ex_i)) ---
    const tau = @sqrt(l_ * c);
    var a0: f64 = undefined;
    {
        const y1 = 0.5 * (rdl + gdc);
        const y2 = rdl * gdc - y1 * y1;
        const y3 = -3.0 * y1 * y2;
        const y4 = -3.0 * y2 * y2 - 4.0 * y1 * y3;
        const y5 = -5.0 * y1 * y4 - 10.0 * y2 * y3;
        const y6 = -10.0 * y3 * y3 - 15.0 * y2 * y4 - 6.0 * y1 * y5;
        a0 = y1 * tau * len;
        const a1 = y2 * tau * tau / 2.0 * len;
        const a2 = y3 * tau * tau * tau / 6.0 * len;
        const a3 = y4 * tau * tau * tau * tau / 24.0 * len;
        const a4 = y5 * tau * tau * tau * tau * tau / 120.0 * len;
        const a5 = y6 * tau * tau * tau * tau * tau * tau / 720.0 * len;

        // pade(): cumulative-exponential series b[i] of exp(Σ −a_i z^i).
        var bb: [6]f64 = undefined;
        const aa: [6]f64 = .{ 0, -a1, -a2, -a3, -a4, -a5 };
        bb[0] = 1.0;
        bb[1] = aa[1];
        for (2..6) |i| {
            bb[i] = 0.0;
            for (1..i + 1) |j| bb[i] += @as(f64, @floatFromInt(j)) * aa[j] * bb[i - j];
            bb[i] /= @floatFromInt(i);
        }
        const h0 = @exp(a0 - len * @sqrt(r_in * g)); // fit's value at s = 0
        var am: [3][4]f64 = .{
            .{ 1.0 - h0, bb[1], bb[2], -bb[3] },
            .{ bb[1], bb[2], bb[3], -bb[4] },
            .{ bb[2], bb[3], bb[4], -bb[5] },
        };
        if (!gauss3(&am, 1.0e-28)) return fit;
        var ep3 = am[0][3];
        var ep2 = am[1][3];
        var ep1 = am[2][3];
        var eq1 = ep1 + bb[1];
        var eq2 = bb[1] * ep1 + ep2 + bb[2];
        var eq3 = ep3 * h0;
        ep3 /= tau * tau * tau;
        ep2 /= tau * tau;
        ep1 /= tau;
        eq3 /= tau * tau * tau;
        eq2 /= tau * tau;
        eq1 /= tau;
        const roots = findRoots(ep1, ep2, ep3, true, 1.0e8) orelse unreachable;
        fit.if_img = roots.img;
        fit.h2_x = .{ roots.x1, roots.x2, roots.x3 };
        fit.h2_c[0] = eval2(eq1 - ep1, eq2 - ep2, eq3 - ep3, roots.x1) /
            eval2(3.0, 2.0 * ep1, ep2, roots.x1);
        if (roots.img) {
            const cpair = getC(eq1 - ep1, eq2 - ep2, eq3 - ep3, ep1, ep2, roots.x2, roots.x3);
            fit.h2_c[1] = cpair[0];
            fit.h2_c[2] = cpair[1];
        } else {
            for (1..3) |i| {
                fit.h2_c[i] = eval2(eq1 - ep1, eq2 - ep2, eq3 - ep3, fit.h2_x[i]) /
                    eval2(3.0, 2.0 * ep1, ep2, fit.h2_x[i]);
            }
        }
        fit.taul = tau * len;
        fit.h2_aten = @exp(-a0);
    }

    // --- get_h3: h3 = Y·H product expansion over the six poles ---
    {
        fit.h3_aten = fit.h2_aten * fit.sqtCdL;
        const xx = [6]f64{ fit.h1_x[0], fit.h1_x[1], fit.h1_x[2], fit.h2_x[0], fit.h2_x[1], fit.h2_x[2] };
        const cc = [6]f64{ fit.h1_c[0], fit.h1_c[1], fit.h1_c[2], fit.h2_c[0], fit.h2_c[1], fit.h2_c[2] };
        fit.h3_x = xx;
        if (fit.if_img) {
            for (0..3) |i| {
                fit.h3_c[i] = cc[i] + cc[i] * (cc[3] / (xx[i] - xx[3]) +
                    2.0 * (cc[4] * xx[i] - xx[5] * cc[5] - xx[4] * cc[4]) /
                        (xx[i] * xx[i] - 2.0 * xx[4] * xx[i] + xx[4] * xx[4] + xx[5] * xx[5]));
            }
            fit.h3_c[3] = cc[3] + cc[3] * (cc[0] / (xx[3] - xx[0]) + cc[1] / (xx[3] - xx[1]) + cc[2] / (xx[3] - xx[2]));
            fit.h3_c[4] = cc[4];
            fit.h3_c[5] = cc[5];
            for (0..3) |i| {
                const ri = divC(cc[4], cc[5], xx[4] - xx[i], xx[5]);
                fit.h3_c[4] += ri[0] * cc[i];
                fit.h3_c[5] += ri[1] * cc[i];
            }
        } else {
            for (0..3) |i| {
                fit.h3_c[i] = cc[i] + cc[i] * (cc[3] / (xx[i] - xx[3]) + cc[4] / (xx[i] - xx[4]) + cc[5] / (xx[i] - xx[5]));
            }
            for (3..6) |i| {
                fit.h3_c[i] = cc[i] + cc[i] * (cc[0] / (xx[i] - xx[0]) + cc[1] / (xx[i] - xx[1]) + cc[2] / (xx[i] - xx[2]));
            }
        }
    }

    // --- update_h1C_c: fold the attenuations in, in the reference's order ---
    fit.taul *= 1.0e12;
    var d: f64 = 0;
    for (0..3) |i| {
        fit.h1_c[i] *= fit.sqtCdL;
        d += fit.h1_c[i];
    }
    fit.h1C = d;
    for (0..3) |i| fit.h2_c[i] *= fit.h2_aten;
    for (0..6) |i| fit.h3_c[i] *= fit.h3_aten;
    fit.ok = true;
    return fit;
}

// ---------------------------------------------------------------------------
// Per-line convolution state + the recursive-convolution steps, shared with
// coupled_ltra (one LineState per mode there). All named after the reference.
// ---------------------------------------------------------------------------

pub const LineState = struct {
    // Committed (state at the last accepted point; ngspice's `txline`).
    cnv1_i: [3]f64 = @splat(0),
    cnv1_o: [3]f64 = @splat(0),
    cnv2_i: [3]f64 = @splat(0),
    cnv2_o: [3]f64 = @splat(0),
    cnv3_i: [6]f64 = @splat(0),
    cnv3_o: [6]f64 = @splat(0),
    vprev_i: f64 = 0, // accepted node voltages (in_node->V / out_node->V)
    vprev_o: f64 = 0,
    dv_i: f64 = 0, // accepted slopes, volts per PICOSECOND (SWEC units)
    dv_o: f64 = 0,
    dc1: f64 = 0,
    dc2: f64 = 0,

    // Pending (advanced to the attempted timepoint; ngspice's `txline2`).
    p2_i: [3]f64 = @splat(0),
    p2_o: [3]f64 = @splat(0),
    p3_i: [6]f64 = @splat(0),
    p3_o: [6]f64 = @splat(0),
    h1e: [3]f64 = @splat(0),
    in1: f64 = 0,
    in2: f64 = 0,
};

/// Delayed values at (t1 − τ, t2 − τ) interpolated over the integer-ps
/// history (get_pvs_vi_txl, ext folded away — see updateState's step bound).
pub const Delayed = struct { v1_i: f64, v1_o: f64, i1_i: f64, i1_o: f64, v2_i: f64, v2_o: f64, i2_i: f64, i2_o: f64 };

pub const Hist = struct {
    t: []const f64, // integer ps values, stored f64 (compares/interp only)
    v_i: []const f64,
    v_o: []const f64,
    i_i: []const f64,
    i_o: []const f64,
};

pub fn getPvs(h: Hist, dc1: f64, dc2: f64, taul: f64, t1: f64, t2: f64) Delayed {
    var d: Delayed = .{ .v1_i = dc1, .v1_o = dc2, .i1_i = 0, .i1_o = 0, .v2_i = dc1, .v2_o = dc2, .i2_i = 0, .i2_o = 0 };
    const ta = t1 - taul;
    var tb = t2 - taul;
    if (tb <= 0) return d;
    // ponytail: the reference's ext path (tb > t1, dt exceeding τ) is cut off
    // by updateState's 0.9τ bound_step; clamp keeps a stray oversized first
    // step finite instead of reading future history.
    if (tb > t1) tb = t1;

    var j: usize = 1; // walk index; history is short (τ window + slack)
    if (ta > 0) {
        while (j + 1 < h.t.len and h.t[j] < ta) j += 1;
        const f = (ta - h.t[j - 1]) / (h.t[j] - h.t[j - 1]);
        d.v1_i = h.v_i[j - 1] + f * (h.v_i[j] - h.v_i[j - 1]);
        d.v1_o = h.v_o[j - 1] + f * (h.v_o[j] - h.v_o[j - 1]);
        d.i1_i = h.i_i[j - 1] + f * (h.i_i[j] - h.i_i[j - 1]);
        d.i1_o = h.i_o[j - 1] + f * (h.i_o[j] - h.i_o[j - 1]);
    }
    while (j + 1 < h.t.len and h.t[j] < tb) j += 1;
    const f = (tb - h.t[j - 1]) / (h.t[j] - h.t[j - 1]);
    d.v2_i = h.v_i[j - 1] + f * (h.v_i[j] - h.v_i[j - 1]);
    d.v2_o = h.v_o[j - 1] + f * (h.v_o[j] - h.v_o[j - 1]);
    d.i2_i = h.i_i[j - 1] + f * (h.i_i[j] - h.i_i[j - 1]);
    d.i2_o = h.i_o[j - 1] + f * (h.i_o[j] - h.i_o[j - 1]);
    return d;
}

/// right_consts_txl: advance the h2/h3 convolutions by the attempted step h
/// (into the PENDING slots) and produce the branch-equation RHS pair
/// (in1, in2). Purely a function of committed state + history; Newton
/// iterations reuse the cached result. `t2_ps` is trunc(t·1e12) — ngspice
/// anchors the delayed reads on the truncated integer time, not on t1 + h.
pub fn rebuildLine(fit: *const LineFit, st: *LineState, h: f64, t2_ps: f64, hi: Hist) void {
    const h1 = 0.5 * h;
    var ff: f64 = 0;
    var gg: f64 = 0;

    if (!fit.lsl) {
        var ff1: f64 = 0;
        for (0..3) |i| {
            const e = @exp(fit.h1_x[i] * h);
            st.h1e[i] = e;
            ff1 -= fit.h1_c[i] * e;
            ff -= st.cnv1_i[i] * e;
            gg -= st.cnv1_o[i] * e;
        }
        ff += ff1 * h1 * st.vprev_i;
        gg += ff1 * h1 * st.vprev_o;
    }

    const t1 = hi.t[hi.t.len - 1];
    const del = getPvs(hi, st.dc1, st.dc2, fit.taul, t1, t2_ps);

    if (fit.lsl) {
        ff = fit.h3_aten * del.v2_o + fit.h2_aten * del.i2_o;
        gg = fit.h3_aten * del.v2_i + fit.h2_aten * del.i2_i;
    } else if (fit.if_img) {
        // h3: 4 real terms + one complex pair in slots 4,5.
        for (0..4) |i| {
            const e = @exp(fit.h3_x[i] * h);
            st.p3_i[i] = st.cnv3_i[i] * e + h1 * fit.h3_c[i] * (del.v1_i * e + del.v2_i);
            st.p3_o[i] = st.cnv3_o[i] * e + h1 * fit.h3_c[i] * (del.v1_o * e + del.v2_o);
        }
        const er = @exp(fit.h3_x[4] * h) * @cos(fit.h3_x[5] * h);
        const ei = @exp(fit.h3_x[4] * h) * @sin(fit.h3_x[5] * h);
        const a2 = h1 * fit.h3_c[4];
        const b2 = h1 * fit.h3_c[5];
        inline for (.{ "i", "o" }) |side| {
            const cnv = if (comptime std.mem.eql(u8, side, "i")) &st.cnv3_i else &st.cnv3_o;
            const p = if (comptime std.mem.eql(u8, side, "i")) &st.p3_i else &st.p3_o;
            const v1 = if (comptime std.mem.eql(u8, side, "i")) del.v1_i else del.v1_o;
            const v2 = if (comptime std.mem.eql(u8, side, "i")) del.v2_i else del.v2_o;
            const ar = cnv[4] * er - cnv[5] * ei;
            const ai = cnv[4] * ei + cnv[5] * er;
            const a1r = a2 * (v1 * er + v2) - b2 * (v1 * ei);
            const a1i = a2 * (v1 * ei) + b2 * (v1 * er + v2);
            p[4] = ar + a1r;
            p[5] = ai + a1i;
        }
        ff += fit.h3_aten * del.v2_o;
        gg += fit.h3_aten * del.v2_i;
        for (0..4) |i| {
            ff += st.p3_o[i];
            gg += st.p3_i[i];
        }
        ff += 2.0 * st.p3_o[4];
        gg += 2.0 * st.p3_i[4];

        // h2: 1 real term + one complex pair in slots 1,2.
        {
            const e = @exp(fit.h2_x[0] * h);
            st.p2_i[0] = st.cnv2_i[0] * e + h1 * fit.h2_c[0] * (del.i1_i * e + del.i2_i);
            st.p2_o[0] = st.cnv2_o[0] * e + h1 * fit.h2_c[0] * (del.i1_o * e + del.i2_o);
        }
        const er2 = @exp(fit.h2_x[1] * h) * @cos(fit.h2_x[2] * h);
        const ei2 = @exp(fit.h2_x[1] * h) * @sin(fit.h2_x[2] * h);
        const c2 = h1 * fit.h2_c[1];
        const d2 = h1 * fit.h2_c[2];
        inline for (.{ "i", "o" }) |side| {
            const cnv = if (comptime std.mem.eql(u8, side, "i")) &st.cnv2_i else &st.cnv2_o;
            const p = if (comptime std.mem.eql(u8, side, "i")) &st.p2_i else &st.p2_o;
            const di1 = if (comptime std.mem.eql(u8, side, "i")) del.i1_i else del.i1_o;
            const di2 = if (comptime std.mem.eql(u8, side, "i")) del.i2_i else del.i2_o;
            const ar = cnv[1] * er2 - cnv[2] * ei2;
            const ai = cnv[1] * ei2 + cnv[2] * er2;
            const a1r = c2 * (di1 * er2 + di2) - d2 * (di1 * ei2);
            const a1i = c2 * (di1 * ei2) + d2 * (di1 * er2 + di2);
            p[1] = ar + a1r;
            p[2] = ai + a1i;
        }
        ff += fit.h2_aten * del.i2_o + st.p2_o[0] + 2.0 * st.p2_o[1];
        gg += fit.h2_aten * del.i2_i + st.p2_i[0] + 2.0 * st.p2_i[1];
    } else {
        for (0..6) |i| {
            const e = @exp(fit.h3_x[i] * h);
            st.p3_i[i] = st.cnv3_i[i] * e + h1 * fit.h3_c[i] * (del.v1_i * e + del.v2_i);
            st.p3_o[i] = st.cnv3_o[i] * e + h1 * fit.h3_c[i] * (del.v1_o * e + del.v2_o);
        }
        ff += fit.h3_aten * del.v2_o;
        gg += fit.h3_aten * del.v2_i;
        for (0..6) |i| {
            ff += st.p3_o[i];
            gg += st.p3_i[i];
        }
        for (0..3) |i| {
            const e = @exp(fit.h2_x[i] * h);
            st.p2_i[i] = st.cnv2_i[i] * e + h1 * fit.h2_c[i] * (del.i1_i * e + del.i2_i);
            st.p2_o[i] = st.cnv2_o[i] * e + h1 * fit.h2_c[i] * (del.i1_o * e + del.i2_o);
        }
        ff += fit.h2_aten * del.i2_o;
        gg += fit.h2_aten * del.i2_i;
        for (0..3) |i| {
            ff += st.p2_o[i];
            gg += st.p2_i[i];
        }
    }

    st.in1 = ff;
    st.in2 = gg;
}

/// DC seed at the start of a transient (txlload's TXLdcGiven block):
/// h1/h3 states at their steady values, h2 at zero. Bug-compat: the complex
/// h3 pair is seeded with the plain real −dc·c/x division, exactly as
/// txlload.c:187-192 does even when ifImg. cplload seeds its pairs with the
/// correct complex division — the coupled device uses seedLineCpl.
pub fn seedLine(fit: *const LineFit, st: *LineState, v1: f64, v2: f64) void {
    st.dc1 = v1;
    st.dc2 = v2;
    st.vprev_i = v1;
    st.vprev_o = v2;
    st.dv_i = 0;
    st.dv_o = 0;
    if (fit.lsl) return;
    for (0..3) |i| {
        st.cnv1_i[i] = -v1 * fit.h1_c[i] / fit.h1_x[i];
        st.cnv1_o[i] = -v2 * fit.h1_c[i] / fit.h1_x[i];
        st.cnv2_i[i] = 0;
        st.cnv2_o[i] = 0;
    }
    for (0..6) |i| {
        st.cnv3_i[i] = -v1 * fit.h3_c[i] / fit.h3_x[i];
        st.cnv3_o[i] = -v2 * fit.h3_c[i] / fit.h3_x[i];
    }
}

/// cplload's DC seed: identical except the complex h3 pair is seeded with
/// the proper complex division −dc·(c/z) (cplload.c:244-254 divC).
pub fn seedLineCpl(fit: *const LineFit, st: *LineState, v1: f64, v2: f64) void {
    seedLine(fit, st, v1, v2);
    if (fit.lsl or !fit.if_img) return;
    const p = divC(fit.h3_c[4], fit.h3_c[5], fit.h3_x[4], fit.h3_x[5]);
    st.cnv3_i[4] = -v1 * p[0];
    st.cnv3_i[5] = -v1 * p[1];
    st.cnv3_o[4] = -v2 * p[0];
    st.cnv3_o[5] = -v2 * p[1];
}

/// Accept commit (first loop of TXLload): adopt the pending h2/h3 states,
/// advance the h1 states over the just-accepted segment (update_cnv_txl's
/// exact linear-segment integral, ps-slope units verbatim), refresh V/dv.
/// `delta_ps` is the integer-ps step, `v1/v2` the accepted port voltages.
pub fn commitLine(fit: *const LineFit, st: *LineState, delta_ps: f64, v1: f64, v2: f64) void {
    if (fit.lsl) {
        st.dv_i = (v1 - st.vprev_i) / delta_ps;
        st.dv_o = (v2 - st.vprev_o) / delta_ps;
        st.vprev_i = v1;
        st.vprev_o = v2;
        return;
    }
    st.cnv2_i = st.p2_i;
    st.cnv2_o = st.p2_o;
    st.cnv3_i = st.p3_i;
    st.cnv3_o = st.p3_o;
    var bi = (v1 - st.vprev_i) / delta_ps;
    var bo = (v2 - st.vprev_o) / delta_ps;
    st.dv_i = bi;
    st.dv_o = bo;
    st.vprev_i = v1;
    st.vprev_o = v2;
    for (0..3) |i| {
        const e = st.h1e[i];
        const t = fit.h1_c[i] / fit.h1_x[i];
        // Verbatim reference quirk (update_cnv_txl): the slope accumulates
        // the c/x product ACROSS terms — bi is never reset, so terms 1 and 2
        // see bi·t0·t1(·t2). Products of c/x are ~1e-3², i.e. the reference
        // effectively drops the slope correction beyond term 0.
        bi *= t;
        bo *= t;
        st.cnv1_i[i] = (st.cnv1_i[i] - bi * delta_ps) * e + (e - 1.0) * (v1 * t + 1.0e12 * bi / fit.h1_x[i]);
        st.cnv1_o[i] = (st.cnv1_o[i] - bo * delta_ps) * e + (e - 1.0) * (v2 * t + 1.0e12 * bo / fit.h1_x[i]);
    }
}

// ---------------------------------------------------------------------------
// The Y-card device proper.
// ---------------------------------------------------------------------------

pub const Model = struct {
    r: f64 = 0,
    l: f64 = 0,
    g: f64 = 0,
    c: f64 = 0,
    len: f64 = 0,
    // Derived (precompute); 1e31 keeps scalars off collectParams, the fit
    // arrays are invisible to it by type.
    fit: LineFit = .{},
    rtot: f64 = 1e31, // R·len for the DC rows
};

pub const Instance = struct {
    abstime: f64 = 0,
    dt: f64 = 0,
    analysis_kind: AnalysisKind = .dc,
    bound_step: f64 = inf,

    cache_t: f64 = 1e31,
    cache_dt: f64 = 1e31, // breakpoint-pinned retries reuse t with new dt
    line: LineState = .{},

    n_hist: u32 = 0,
    hist_t: [CAP]f64 = @splat(0), // integer ps, stored f64
    hist_vi: [CAP]f64 = @splat(0),
    hist_vo: [CAP]f64 = @splat(0),
    hist_ii: [CAP]f64 = @splat(0),
    hist_io: [CAP]f64 = @splat(0),
};

pub fn precompute(_: *Instance, model: *Model) void {
    model.fit = fitLine(model.r, model.l, model.g, model.c, model.len);
    model.rtot = model.r * model.len;
}

fn hist(inst: anytype) Hist {
    const n = inst.n_hist;
    return .{
        .t = inst.hist_t[0..n],
        .v_i = inst.hist_vi[0..n],
        .v_o = inst.hist_vo[0..n],
        .i_i = inst.hist_ii[0..n],
        .i_o = inst.hist_io[0..n],
    };
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, t: f64) [n_u]S {
    var res: [n_u]S = undefined;
    const ib1 = x[@intFromEnum(U.br1)];
    const ib2 = x[@intFromEnum(U.br2)];
    res[@intFromEnum(U.p1)] = ib1;
    res[@intFromEnum(U.p2)] = ib2;
    const v1 = x[@intFromEnum(U.p1)];
    const v2 = x[@intFromEnum(U.p2)];

    if (inst.dt <= 0.0 or inst.analysis_kind != .tran or !model.fit.ok or inst.n_hist == 0) {
        // MODEDC rows: i1 + i2 = 0; v1 − v2 = R·len·i1.
        res[@intFromEnum(U.br1)] = ib1.add(ib2);
        res[@intFromEnum(U.br2)] = v1.sub(v2).sub(ib1.scale(model.rtot));
        return res;
    }

    const ii: *Instance = @constCast(inst);
    if (ii.cache_t != t or ii.cache_dt != inst.dt) {
        rebuildLine(&model.fit, &ii.line, inst.dt, @trunc(t * 1e12), hist(ii));
        ii.cache_t = t;
        ii.cache_dt = inst.dt;
    }

    const h1 = 0.5 * inst.dt;
    const yc = model.fit.sqtCdL + h1 * model.fit.h1C;
    res[@intFromEnum(U.br1)] = v1.scale(yc).sub(ib1).addC(-ii.line.in1);
    res[@intFromEnum(U.br2)] = v2.scale(yc).sub(ib2).addC(-ii.line.in2);
    return res;
}

pub const State = struct {};

pub fn initState(_: *const Model, _: *Instance) State {
    return .{};
}

pub fn updateState(model: *Model, inst: *Instance, x: [n_u]f64, _: *State) contract.UpdateResult {
    if (inst.analysis_kind != .tran or !model.fit.ok) return .ok;
    const v1 = x[@intFromEnum(U.p1)];
    const v2 = x[@intFromEnum(U.p2)];
    const t_ps: f64 = @trunc(inst.abstime * 1e12);

    if (inst.abstime == 0 or inst.n_hist == 0) {
        // Fresh transient: DC seed (dc setup block of TXLload).
        inst.n_hist = 1;
        inst.hist_t[0] = 0;
        inst.hist_vi[0] = v1;
        inst.hist_vo[0] = v2;
        inst.hist_ii[0] = x[@intFromEnum(U.br1)];
        inst.hist_io[0] = x[@intFromEnum(U.br2)];
        seedLine(&model.fit, &inst.line, v1, v2);
        inst.cache_t = 1e31;
        inst.bound_step = 0.9 * model.fit.taul * 1e-12;
        return .ok;
    }

    const tail = inst.hist_t[inst.n_hist - 1];
    if (t_ps <= tail) return .ok; // sub-ps step: reference merges it (no-op)

    if (inst.cache_t != inst.abstime or inst.cache_dt != inst.dt)
        rebuildLine(&model.fit, &inst.line, inst.dt, t_ps, hist(inst));
    commitLine(&model.fit, &inst.line, t_ps - tail, v1, v2);

    // Prune the dead front (all delayed reads anchor at tail − τ; keep one
    // bracket point before it) once it is worth a memmove.
    {
        const cutoff = t_ps - model.fit.taul;
        var drop: u32 = 0;
        while (drop + 1 < inst.n_hist and inst.hist_t[drop + 1] < cutoff) drop += 1;
        if (drop > 64 or inst.n_hist == CAP) {
            drop = @max(drop, @intFromBool(inst.n_hist == CAP)); // full + live window: drop oldest anyway
            inline for (.{ "hist_t", "hist_vi", "hist_vo", "hist_ii", "hist_io" }) |f| {
                const arr = &@field(inst, f);
                std.mem.copyForwards(f64, arr[0 .. inst.n_hist - drop], arr[drop..inst.n_hist]);
            }
            inst.n_hist -= drop;
        }
    }
    const j = inst.n_hist;
    inst.hist_t[j] = t_ps;
    inst.hist_vi[j] = v1;
    inst.hist_vo[j] = v2;
    inst.hist_ii[j] = x[@intFromEnum(U.br1)];
    inst.hist_io[j] = x[@intFromEnum(U.br2)];
    inst.n_hist = j + 1;
    inst.cache_t = 1e31;
    inst.bound_step = 0.9 * model.fit.taul * 1e-12;
    return .ok;
}

// ---------------------------------------------------------------------------
// Focused checks.
// ---------------------------------------------------------------------------

test "fitLine: Y(s) Padé matches the exact characteristic admittance" {
    // txl1 fixture card: R=12.45 L=8.972n G=0 C=0.468p length=16.
    const fit = fitLine(12.45, 8.972e-9, 0, 0.468e-12, 16);
    try std.testing.expect(fit.ok);
    try std.testing.expect(!fit.lsl);
    // Poles must be real negative (Y fit exits on complex in the reference).
    for (fit.h1_x) |xp| try std.testing.expect(xp < 0);
    // Fit vs exact at real frequencies s = σ (rad/s): Y(s) =
    // sqrt((C s)/(L s + R)) = sqtCdL·sqrt(s/(s+R/L)). The fit is a 1/s
    // Maclaurin Padé — accurate from ~R/L upward (below that it drifts to
    // ~10%, which is the designed-in TXL-vs-exact gap, not a porting bug).
    const rdl = 12.45 / 8.972e-9;
    var s: f64 = 1e9;
    while (s <= 1e12) : (s *= 10) {
        var y_fit = fit.sqtCdL;
        for (0..3) |i| y_fit += fit.h1_c[i] / (s - fit.h1_x[i]);
        const y_exact = fit.sqtCdL * @sqrt(s / (s + rdl));
        try std.testing.expectApproxEqRel(y_exact, y_fit, 0.03);
    }
    // s = 0 is pinned by the fit's first constraint row: Y(0) = 0 for G = 0.
    var y0 = fit.sqtCdL;
    for (0..3) |i| y0 += fit.h1_c[i] / (0 - fit.h1_x[i]);
    try std.testing.expectApproxEqAbs(@as(f64, 0), y0 / fit.sqtCdL, 1e-3);
    // Propagation DC value: H(0) = 1 for G = 0. h2_c are post-scaled by
    // h2_aten, so the fit at s=0 is h2_aten + Σ c/(−x) (2·Re for the pair).
    var h0: f64 = fit.h2_aten;
    if (fit.if_img) {
        h0 += fit.h2_c[0] / (0 - fit.h2_x[0]);
        const pair = divC(fit.h2_c[1], fit.h2_c[2], -fit.h2_x[1], -fit.h2_x[2]);
        h0 += 2.0 * pair[0];
    } else {
        for (0..3) |i| h0 += fit.h2_c[i] / (0 - fit.h2_x[i]);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), h0, 0.02);
    // Delay in ps.
    try std.testing.expectApproxEqRel(@sqrt(8.972e-9 * 0.468e-12) * 16 * 1e12, fit.taul, 1e-12);
}

test "fitLine matches ngspice txlsetup constants (txl1 card)" {
    // Golden values from the ngspice txlsetup.c math compiled standalone
    // (/tmp/txlfit_ref.c extraction, ngspice-44.2 source) on
    // R=12.45 L=8.972n G=0 C=0.468p length=16.
    const fit = fitLine(12.45, 8.972e-9, 0, 0.468e-12, 16);
    try std.testing.expect(fit.ok and !fit.if_img);
    const eq = struct {
        fn f(want: f64, got: f64) !void {
            try std.testing.expectApproxEqRel(want, got, 1e-9);
        }
    }.f;
    try eq(0.0072223460632370425, fit.sqtCdL);
    try eq(1036.7822220698038, fit.taul);
    try eq(-5011045.9477987774, fit.h1C);
    try eq(0.48707085781090981, fit.h2_aten);
    try eq(0.0035177942924281137, fit.h3_aten);
    const h1c = [3]f64{ -3116913.0127078136, -1670348.6492662919, -223784.28582467159 };
    const h1x = [3]f64{ -1294695512.5454922, -693825234.06154299, -92954955.577564731 };
    const h2c = [3]f64{ 32032447.910523027, 70922821.889925435, 18593305.726098258 };
    const h2x = [3]f64{ -1082067468.6537325, -471891785.1181848, -55830477.679709695 };
    const h3c = [6]f64{ -733147.30911070784, -368923.02543214324, -46050.715676443077, -93152.380915472677, -248343.77399395837, -73251.367249283721 };
    for (0..3) |i| {
        try eq(h1c[i], fit.h1_c[i]);
        try eq(h1x[i], fit.h1_x[i]);
        try eq(h2c[i], fit.h2_c[i]);
        try eq(h2x[i], fit.h2_x[i]);
    }
    for (0..6) |i| try eq(h3c[i], fit.h3_c[i]);
}

test "matched TXL line: delayed replica and DC settle" {
    // Z0 = sqrt(L/C) ≈ 138.5 Ω, τ ≈ 1.037 ns, R·len = 199.2 Ω (lossy!).
    var model: Model = .{ .r = 12.45, .l = 8.972e-9, .g = 0, .c = 0.468e-12, .len = 16 };
    var inst: Instance = .{};
    precompute(&inst, &model);
    try std.testing.expect(model.fit.ok);

    const vs = 1.0;
    const rs = 138.5;
    const rl = 138.5;

    inst.analysis_kind = .tran;
    var st: State = .{};
    inst.abstime = 0;
    inst.dt = 0;
    var xacc = [_]f64{0} ** n_u;
    _ = updateState(&model, &inst, xacc, &st);

    const TS = struct {
        v: f64,
        const T = @This();
        pub fn con(c: f64) T {
            return .{ .v = c };
        }
        pub fn add(a: T, b: T) T {
            return .{ .v = a.v + b.v };
        }
        pub fn sub(a: T, b: T) T {
            return .{ .v = a.v - b.v };
        }
        pub fn neg(a: T) T {
            return .{ .v = -a.v };
        }
        pub fn scale(a: T, c: f64) T {
            return .{ .v = a.v * c };
        }
        pub fn addC(a: T, c: f64) T {
            return .{ .v = a.v + c };
        }
    };

    const dt = 0.05e-9;
    var t: f64 = dt;
    var v2_before_tau: f64 = 1;
    var v2_final: f64 = 0;
    while (t <= 40e-9 + 1e-15) : (t += dt) {
        inst.dt = dt;
        inst.abstime = t;
        var x = [_]TS{.{ .v = 0 }} ** n_u;
        const r0 = eval(TS, x, &model, &inst, t);
        const in1 = -r0[@intFromEnum(U.br1)].v;
        const in2 = -r0[@intFromEnum(U.br2)].v;
        const yc = model.fit.sqtCdL + 0.5 * dt * model.fit.h1C;
        // Terminations: v1 = vs − rs·i1, v2 = −rl·i2 (i into the line).
        const ib1 = (yc * vs - in1) / (1.0 + yc * rs);
        const ib2 = -in2 / (1.0 + yc * rl);
        const v1 = vs - rs * ib1;
        const v2 = -rl * ib2;
        x[0] = .{ .v = v1 };
        x[2] = .{ .v = ib1 };
        x[1] = .{ .v = v2 };
        x[3] = .{ .v = ib2 };
        const rchk = eval(TS, x, &model, &inst, t);
        try std.testing.expectApproxEqAbs(@as(f64, 0), rchk[@intFromEnum(U.br1)].v, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f64, 0), rchk[@intFromEnum(U.br2)].v, 1e-9);

        xacc = .{ v1, v2, ib1, ib2 };
        _ = updateState(&model, &inst, xacc, &st);
        if (t < 0.9e-9) v2_before_tau = @min(v2_before_tau, @abs(v2));
        v2_final = v2;
    }
    // Nothing arrives before τ.
    try std.testing.expect(v2_before_tau < 1e-6);
    // DC divider through the series resistance: rl/(rs + R·len + rl).
    const dc = vs * rl / (rs + 12.45 * 16 + rl);
    try std.testing.expectApproxEqAbs(dc, v2_final, 0.02 * vs);
}
