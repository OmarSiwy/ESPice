//! ltra_native — ngspice's LTRA lossy line (O card), the REAL §1.3–§1.6 method,
//! hand-written against the device contract (VerA has no spelling for unbounded
//! per-instance history, so this cannot be a .va model — see
//! models/lossy_tline.va's header for the ceiling this replaces).
//!
//! Ported from ngspice ltraload.c / ltramisc.c / ltratemp.c / ltraacct.c
//! (Roychowdhury & Pederson, DAC'91), deliberately bug-compatible where the
//! reference cuts corners (the h2 interval mismatch at i == auxindex, the
//! duplicated straight-line check in the maxSafeStep bisection): matching
//! ngspice's numbers IS the spec (docs/devices/ltra-lossy-line.md).
//!
//! Data (DOD): one instance = 6 unknowns (4 ports + 2 branch currents) and an
//! append-only accepted-step history — 5 parallel f64 arrays (t, v1, v2, i1,
//! i2), capacity-bounded with ngspice's straight-line compaction as the
//! overflow valve. Access: appended once per accepted step (commit channel),
//! scanned newest→oldest once per TIMEPOINT to rebuild the affine stamp
//! (c1h1/c1h2/c1h3, in1, in2); every Newton iteration then reads only those
//! five cached scalars. Instances are independent (ParEval-safe): unlike
//! ngspice there is no shared model coefficient list — each instance fuses
//! coefficient generation with its own convolution dot product, so no
//! coefficient arrays exist at all.
//!
//! Per-timepoint cost is O(history), like ngspice with its default
//! chopreltol=0; per-iteration cost is O(1). NOT lanes: the rebuild is
//! sequential in history and runs once per timepoint per instance.

const std = @import("std");
const contract = @import("contract");

const Self = @This();
const inf = std.math.inf(f64);

// exe and test roots link libc (build.zig); the RC kernels are erfc-shaped.
extern "c" fn erfc(x: f64) f64;

pub const U = enum(u8) { p1, n1, p2, n2, br1, br2 };
pub const num_ports: usize = 4;
const n_u = contract.nU(Self);

pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, .voltage, .voltage, .voltage, .current, .current,
};
pub const u_abstol = [n_u]f64{ 1e-6, 1e-6, 1e-6, 1e-6, 1e-12, 1e-12 };

pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

/// The engine's commit_state gate: history pushed by `updateState` cannot be
/// rolled back, so it must run once per ACCEPTED step, never per Newton
/// iteration (engine.zig hasAbsdelayState — this decl is the native spelling).
pub const unrevertible_state = true;

/// ngspice LTRAspecialCase, §1.1 (RG and rejects stay on models/lossy_tline.va
/// — the builder routes only these three here).
pub const Case = enum(u8) { lc, rlc, rc };

/// History capacity. tmax-gridded fixtures accept ~500–2000 points; the
/// straight-line compaction below is the overflow valve, so this is a memory
/// bound, not a correctness cliff.
/// ponytail: fixed cap in Instance because eval sees only Model/Instance;
/// upgrade to engine-owned growable storage if a >CAP-point line shows up.
const CAP = 8192;

pub const Model = struct {
    // `.model ltra` card (per-unit-length RLGC + length), ngspice ltra.c IOP.
    r: f64 = 0,
    l: f64 = 0,
    g: f64 = 0,
    c: f64 = 0,
    len: f64 = 0,
    /// card `compactrel`/`compactabs` (ngspice stLineReltol/stLineAbstol:
    /// CKTreltol/CKTabstol defaults) — maxSafeStep bisection + compaction.
    compactrel: f64 = 1e-3,
    compactabs: f64 = 1e-12,
    /// ngspice chopReltol, default 0 = never truncate the convolution.
    chopreltol: f64 = 0,
    steplimit: f64 = 1,
    truncdontcut: f64 = 0,
    /// card `rel`/`abs` (ngspice LTRAreltol/LTRAabstol, both default 1):
    /// the LTRAaccept wavefront-breakpoint derivative test.
    rel: f64 = 1,
    brkabs: f64 = 1e31, // ngspice `abs` default 1; 1e31-default keeps it off the param list, precompute sets it

    // Derived (precompute). Defaults sit outside collectParams' (-1e30,1e30)
    // window so none of them masquerades as a card parameter.
    case: Case = .rlc,
    td: f64 = 1e31,
    imped: f64 = 1e31,
    admit: f64 = 1e31,
    alpha: f64 = 1e31,
    beta: f64 = 1e31,
    atten: f64 = 1e31,
    cbyr: f64 = 1e31,
    rclsqr: f64 = 1e31,
    int_h1: f64 = 1e31,
    int_h2: f64 = 1e31,
    int_h3: f64 = 1e31,
    max_safe_step: f64 = 1e31,
    /// Pending wavefront breakpoints (ngspice CKTsetBreak from LTRAaccept),
    /// a small overwrite ring: stale entries are simply <= t at query time.
    brk: [8]f64 = @splat(-inf),
    brk_head: u8 = 0,
};

pub const mc_param = "len";

pub const Instance = struct {
    // Host-owned (engine set_sim_state / bound_step channels).
    abstime: f64 = 0,
    dt: f64 = 0,
    analysis_kind: AnalysisKind = .dc,
    bound_step: f64 = inf,

    // Per-timepoint cache (frozen across Newton iterations; the line is
    // linear, ngspice ltraload MODEINITPRED). 1e31 = "stale" and also keeps
    // these out of collectParams.
    cache_t: f64 = 1e31,
    c1h1: f64 = 1e31,
    c1h2: f64 = 1e31,
    c1h3: f64 = 1e31,
    in1: f64 = 1e31,
    in2: f64 = 1e31,

    // §2 initVolt/initCur snapshot (t = 0 operating point).
    v10: f64 = 1e31,
    i10: f64 = 1e31,
    v20: f64 = 1e31,
    i20: f64 = 1e31,

    // Accepted-step history, SoA.
    n_hist: u32 = 0,
    hist_t: [CAP]f64 = @splat(0),
    hist_v1: [CAP]f64 = @splat(0),
    hist_v2: [CAP]f64 = @splat(0),
    hist_i1: [CAP]f64 = @splat(0),
    hist_i2: [CAP]f64 = @splat(0),
};

// ---------------------------------------------------------------------------
// ngspice ltramisc.c: Bessel fits (Numerical Recipes) in exponentially SCALED
// form — e^{-x}·I0(x) etc. for x >= 0. Algebraically identical to ngspice's
// exp(ax)·poly later multiplied by exp(-beta t) (all call sites pair them),
// minus the overflow at beta·t > 709 the reference leaves open.
// ---------------------------------------------------------------------------

fn bessI0e(x: f64) f64 {
    if (x < 3.75) {
        var y = x / 3.75;
        y *= y;
        return @exp(-x) * (1.0 + y * (3.5156229 + y * (3.0899424 + y * (1.2067492 +
            y * (0.2659732 + y * (0.360768e-1 + y * 0.45813e-2))))));
    }
    const y = 3.75 / x;
    return (1.0 / @sqrt(x)) * (0.39894228 + y * (0.1328592e-1 +
        y * (0.225319e-2 + y * (-0.157565e-2 + y * (0.916281e-2 +
            y * (-0.2057706e-1 + y * (0.2635537e-1 + y * (-0.1647633e-1 +
                y * 0.392377e-2))))))));
}

fn bessI1e(x: f64) f64 {
    if (x < 3.75) {
        var y = x / 3.75;
        y *= y;
        return @exp(-x) * x * (0.5 + y * (0.87890594 + y * (0.51498869 + y * (0.15084934 +
            y * (0.2658733e-1 + y * (0.301532e-2 + y * 0.32411e-3))))));
    }
    const y = 3.75 / x;
    var ans = 0.2282967e-1 + y * (-0.2895312e-1 + y * (0.1787654e-1 - y * 0.420059e-2));
    ans = 0.39894228 + y * (-0.3988024e-1 + y * (-0.362018e-2 +
        y * (0.163801e-2 + y * (-0.1031555e-1 + y * ans))));
    return ans / @sqrt(x);
}

/// e^{-x}·I1(x)/x; finite at x = 0 (→ 1/2), which is why ngspice carries it
/// as its own fit.
fn bessI1xOverXe(x: f64) f64 {
    if (x < 3.75) {
        var y = x / 3.75;
        y *= y;
        return @exp(-x) * (0.5 + y * (0.87890594 + y * (0.51498869 + y * (0.15084934 +
            y * (0.2658733e-1 + y * (0.301532e-2 + y * 0.32411e-3))))));
    }
    const y = 3.75 / x;
    var ans = 0.2282967e-1 + y * (-0.2895312e-1 + y * (0.1787654e-1 - y * 0.420059e-2));
    ans = 0.39894228 + y * (-0.3988024e-1 + y * (-0.362018e-2 +
        y * (0.163801e-2 + y * (-0.1031555e-1 + y * ans))));
    return ans / (x * @sqrt(x));
}

// ---------------------------------------------------------------------------
// §1.4 kernels (ltramisc.c). G = 0 throughout (α = β), so every Bessel
// argument is <= β·t and the scaled products below never overflow.
// ---------------------------------------------------------------------------

/// h2(t) = α²T e^{-βt} I1(x)/x, x = α√(t²−T²); 0 for t < T.
fn rlcH2Func(time: f64, T: f64, alpha: f64, beta: f64) f64 {
    if (alpha == 0.0 or time < T) return 0.0;
    const barg = if (time != T) alpha * @sqrt(time * time - T * T) else 0.0;
    return alpha * alpha * T * @exp(barg - beta * time) * bessI1xOverXe(barg);
}

/// ∫∫h1' = t e^{-βt}[I0(βt) + I1(βt)] − t (G = 0 closed form).
fn rlcH1dashTwiceIntFunc(time: f64, beta: f64) f64 {
    if (beta == 0.0) return time;
    const arg = beta * time;
    if (arg == 0.0) return 0.0;
    return (bessI1e(arg) + bessI0e(arg)) * time - time;
}

// ponytail: rebuildWave computes the h3 integral with its shared exponential;
// extract a standalone helper only if another caller needs it.

// RC-case twice-integrated closed forms (erfc kernels).
fn rcH1dashTwiceIntFunc(time: f64, cbyr: f64) f64 {
    return @sqrt(4.0 * cbyr * time / std.math.pi);
}

fn rcH2TwiceIntFunc(time: f64, rclsqr: f64) f64 {
    if (time == 0.0) return 0.0;
    const temp = rclsqr / (4.0 * time);
    return (time + rclsqr * 0.5) * erfc(@sqrt(temp)) -
        @sqrt(time * rclsqr / std.math.pi) * @exp(-temp);
}

fn rcH3dashTwiceIntFunc(time: f64, cbyr: f64, rclsqr: f64) f64 {
    if (time == 0.0) return 0.0;
    const temp = rclsqr / (4.0 * time);
    return @sqrt(cbyr) * (2.0 * @sqrt(time / std.math.pi) * @exp(-temp) -
        @sqrt(rclsqr) * erfc(@sqrt(temp)));
}

// ---------------------------------------------------------------------------
// §1.5 PWL segment integrals + §1.6 interpolation + straight-line check
// (ltramisc.c, verbatim).
// ---------------------------------------------------------------------------

fn intlinfunc(lolimit: f64, hilimit: f64, lovalue: f64, hivalue: f64, t1: f64, t2: f64) f64 {
    const width = t2 - t1;
    if (width == 0.0) return 0.0;
    const m = (hivalue - lovalue) / width;
    return (hilimit - lolimit) * lovalue + 0.5 * m * ((hilimit - t1) * (hilimit - t1) -
        (lolimit - t1) * (lolimit - t1));
}

fn twiceintlinfunc(lolimit: f64, hilimit: f64, otherlolimit: f64, lovalue: f64, hivalue: f64, t1: f64, t2: f64) f64 {
    const width = t2 - t1;
    if (width == 0.0) return 0.0;
    const m = (hivalue - lovalue) / width;
    const temp1 = hilimit - t1;
    const temp2 = lolimit - t1;
    const temp3 = otherlolimit - t1;
    var dummy = lovalue * ((hilimit - otherlolimit) * (hilimit - otherlolimit) -
        (lolimit - otherlolimit) * (lolimit - otherlolimit));
    dummy += m * ((temp1 * temp1 * temp1 - temp2 * temp2 * temp2) / 3.0 -
        temp3 * temp3 * (hilimit - lolimit));
    return dummy * 0.5;
}

/// Quadratic Lagrange coefficients at t over (t1,t2,t3) — LTRAquadInterp.
fn quadInterp(t: f64, t1: f64, t2: f64, t3: f64) [3]f64 {
    if (t == t1) return .{ 1, 0, 0 };
    if (t == t2) return .{ 0, 1, 0 };
    if (t == t3) return .{ 0, 0, 1 };
    if (t2 - t1 == 0 or t3 - t2 == 0 or t1 - t3 == 0) return .{ 0, 1, 0 };
    var f1 = (t - t2) * (t - t3);
    var f2 = (t - t1) * (t - t3);
    var f3 = (t - t1) * (t - t2);
    f1 /= (t1 - t2);
    f2 /= (t2 - t1);
    f2 /= (t2 - t3);
    f3 /= (t2 - t3);
    f1 /= (t1 - t3);
    f3 /= (t1 - t3);
    return .{ f1, f2, f3 };
}

/// Triangle-vs-quadrilateral area collinearity test — LTRAstraightLineCheck.
fn straightLineCheck(x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64, reltol: f64, abstol: f64) bool {
    const quad1 = (@abs(y2) + @abs(y1)) * 0.5 * @abs(x2 - x1);
    const quad2 = (@abs(y3) + @abs(y2)) * 0.5 * @abs(x3 - x2);
    const quad3 = (@abs(y3) + @abs(y1)) * 0.5 * @abs(x3 - x1);
    const tr = @abs(quad3 - quad1 - quad2);
    return (quad1 + quad2) * reltol + abstol > tr;
}

// ---------------------------------------------------------------------------
// Setup (ngspice LTRAsetup + LTRAtemp fused). Engine calls this at finalize
// and on recompute (parameter sweeps through the ParamRef channel).
// ---------------------------------------------------------------------------

pub fn precompute(_: *Instance, model: *Model) void {
    if (model.brkabs > 1e30) model.brkabs = 1.0; // ngspice LTRAabstol default
    const wave = model.l > 0 and model.c > 0 and model.g == 0;
    model.case = if (wave and model.r == 0) .lc else if (wave) .rlc else .rc;
    switch (model.case) {
        .lc, .rlc => {
            model.imped = @sqrt(model.l / model.c);
            model.admit = 1.0 / model.imped;
            model.td = @sqrt(model.l * model.c) * model.len;
            model.alpha = 0.5 * (model.r / model.l);
            model.beta = model.alpha;
            model.atten = @exp(-model.beta * model.td);
            if (model.alpha > 0.0) {
                model.int_h1 = -1.0;
                model.int_h2 = 1.0 - model.atten;
                model.int_h3 = -model.atten;
            } else {
                model.int_h1 = 0;
                model.int_h2 = 0;
                model.int_h3 = 0;
            }
            model.max_safe_step = inf;
            if (model.case == .rlc and model.truncdontcut == 0) {
                // LTRAtemp bisection for the largest step over which the h2/h3
                // kernels still look straight. Bug-compat: ngspice sums the
                // SAME h2 check twice (y2 never enters `done`), so this does
                // too.
                var xbig = model.td + 9.0 * model.td;
                const xsmall = model.td;
                var xmid = 0.5 * (xbig + xsmall);
                const y1small = rlcH2Func(xsmall, model.td, model.alpha, model.beta);
                var iters: u32 = 0;
                while (true) {
                    iters += 1;
                    const y1big = rlcH2Func(xbig, model.td, model.alpha, model.beta);
                    const y1mid = rlcH2Func(xmid, model.td, model.alpha, model.beta);
                    const done: u32 =
                        @as(u32, @intFromBool(straightLineCheck(xbig, y1big, xmid, y1mid, xsmall, y1small, model.compactrel, model.compactabs))) +
                        @intFromBool(straightLineCheck(xbig, y1big, xmid, y1mid, xsmall, y1small, model.compactrel, model.compactabs));
                    if (done == 2 or iters > 50) break;
                    xbig = xmid;
                    xmid = 0.5 * (xbig + xsmall);
                }
                model.max_safe_step = xbig - model.td;
            }
        },
        .rc => {
            model.cbyr = model.c / model.r;
            model.rclsqr = model.r * model.c * model.len * model.len;
            model.int_h1 = 0.0;
            model.int_h2 = 1.0;
            model.int_h3 = 0.0;
            model.td = 0;
            model.max_safe_step = inf;
        },
    }
}

/// Nearest pending wavefront breakpoint after t (engine next_breakpoint).
pub fn nextBreakpoint(model: *const Model, t: f64) ?f64 {
    var best = inf;
    for (model.brk) |b| {
        if (b > t and b < best) best = b;
    }
    return if (best == inf) null else best;
}

// No `delays()` on purpose: the tran's generic wavefront-echo machinery
// (every landed breakpoint re-emits at t+td) inserts landings ngspice never
// makes — measured on ltra1_1_line it knocked the step train off ngspice's
// phase right before an arrival. ngspice's ONLY wavefront mechanism is the
// LTRAaccept derivative-test breakpoint above (nextBreakpoint) plus the
// stepLimit/maxSafeStep bound carried by Instance.bound_step.

// ---------------------------------------------------------------------------
// Per-timepoint rebuild: LTRArlcCoeffsSetup / LTRArcCoeffsSetup fused with
// ltraload's convolution sums. Coefficients are consumed the instant they are
// produced — no coefficient arrays. Runs once per (instance, timepoint);
// Newton iterations replay the cached affine stamp.
// ---------------------------------------------------------------------------

pub const Hist = struct {
    t: []const f64,
    v1: []const f64,
    v2: []const f64,
    i1: []const f64,
    i2: []const f64,
};

pub fn hist(inst: anytype) Hist {
    const n = inst.n_hist;
    return .{
        .t = inst.hist_t[0..n],
        .v1 = inst.hist_v1[0..n],
        .v2 = inst.hist_v2[0..n],
        .i1 = inst.hist_i1[0..n],
        .i2 = inst.hist_i2[0..n],
    };
}

/// Delayed port values at t − td, quadratically interpolated over the accepted
/// history (§1.6, default QUADINTERP: linear only at the first interval; an
/// out-of-range quad value is kept, as ngspice does for pure quadinterp).
pub const Delayed = struct { v1: f64, v2: f64, i1: f64, i2: f64 };

pub fn interpDelayed(h: Hist, aux: usize, tq: f64) Delayed {
    const timeindex = h.t.len - 1;
    var i = aux;
    if (i == timeindex) i -= 1; // dt > td: extrapolate off the last interval
    if (i == 0) {
        // linear over (t[0], t[1])
        const t1 = h.t[0];
        const t2 = h.t[1];
        const f = (tq - t1) / (t2 - t1);
        return .{
            .v1 = h.v1[0] + f * (h.v1[1] - h.v1[0]),
            .v2 = h.v2[0] + f * (h.v2[1] - h.v2[0]),
            .i1 = h.i1[0] + f * (h.i1[1] - h.i1[0]),
            .i2 = h.i2[0] + f * (h.i2[1] - h.i2[0]),
        };
    }
    const q = quadInterp(tq, h.t[i - 1], h.t[i], h.t[i + 1]);
    return .{
        .v1 = q[0] * h.v1[i - 1] + q[1] * h.v1[i] + q[2] * h.v1[i + 1],
        .v2 = q[0] * h.v2[i - 1] + q[1] * h.v2[i] + q[2] * h.v2[i + 1],
        .i1 = q[0] * h.i1[i - 1] + q[1] * h.i1[i] + q[2] * h.i1[i + 1],
        .i2 = q[0] * h.i2[i - 1] + q[1] * h.i2[i] + q[2] * h.i2[i + 1],
    };
}

pub fn rebuildWave(model: anytype, inst: anytype, t: f64) void {
    const h = hist(inst);
    const timeindex = h.t.len - 1;
    const T = model.td;
    // timeindex >= 1: with only the t=0 seed there is no interval to
    // interpolate over (reachable only under nosteplimit, where dt may
    // exceed td) — fall back to the initial values like t <= T.
    const tdover = t > T and timeindex >= 1;

    // aux = largest i with t − t_i > T (ngspice's auxindex; its `exact` branch
    // lands on the same index because the predicate here is strict).
    var aux: usize = 0;
    if (tdover) {
        var i: usize = timeindex;
        while (true) {
            if (t - h.t[i] > T) {
                aux = i;
                break;
            }
            if (i == 0) break; // t − t_0 = t > T guarantees the break above; belt only
            i -= 1;
        }
    }

    var in1: f64 = 0;
    var in2: f64 = 0;
    var c1h1: f64 = 0;

    if (model.case == .rlc) {
        const alpha = model.alpha;
        const beta = model.beta;

        // -- first coefficients of h2/h3 over [T, t − t_aux] (aux != 0 only) --
        var h2first: f64 = 0;
        var h3first: f64 = 0;
        var h2lov1: f64 = 0;
        var h2hiv1: f64 = 0;
        var h2dum1: f64 = 0;
        var h3lov1: f64 = 0;
        var h3hiv1: f64 = 0;
        var h3dum1: f64 = 0;
        var h2relval: f64 = 0;
        var h3relval: f64 = 0;
        const alphasqT = alpha * alpha * T;
        const expbetaT = @exp(-beta * T);
        if (aux != 0) {
            const lo = T;
            const hi = t - h.t[aux];
            const delta = hi - lo;
            h2lov1 = rlcH2Func(T, T, alpha, beta);
            const barg = if (hi > T) alpha * @sqrt(hi * hi - T * T) else 0.0;
            const expterm_s = @exp(barg - beta * hi); // e^{-βhi} folded with the scaled Bessels
            h2hiv1 = if (alpha == 0.0 or hi < T) 0.0 else alphasqT * expterm_s * bessI1xOverXe(barg);
            h2dum1 = twiceintlinfunc(lo, hi, lo, h2lov1, h2hiv1, lo, hi) / delta;
            h2first = h2dum1;
            h2relval = @abs(model.chopreltol * h2dum1);

            h3lov1 = 0.0;
            h3hiv1 = if (hi <= T or beta == 0.0) 0.0 else expterm_s * bessI0e(barg) - expbetaT;
            h3dum1 = intlinfunc(lo, hi, h3lov1, h3hiv1, lo, hi) / delta;
            h3first = h3dum1;
            h3relval = @abs(h3dum1 * model.chopreltol);
        }

        // -- h1 first coefficient over [0, t − t_n] --
        var lolim1: f64 = 0;
        var hilim1: f64 = t - h.t[timeindex];
        var delta1: f64 = hilim1;
        var h1lov1: f64 = 0;
        var h1hiv1: f64 = rlcH1dashTwiceIntFunc(hilim1, beta);
        var h1dum1: f64 = h1hiv1 / delta1;
        c1h1 = h1dum1;
        const h1relval = @abs(h1dum1 * model.chopreltol);

        // -- fused walk, newest → oldest: coefficient + dot product in one --
        var cv1: f64 = 0; // Σ c1_i (v1_i − v10)
        var cv2: f64 = 0;
        var ci2: f64 = 0; // Σ c2_i (i2_i − i20)
        var ci1: f64 = 0;
        var cw2: f64 = 0; // Σ c3_i (v2_i − v20)
        var cw1: f64 = 0;
        var doh1 = true;
        var doh2 = true;
        var doh3 = true;
        var lolim2: f64 = 0;
        var hilim2: f64 = 0;
        var i: usize = timeindex;
        while (i > 0) : (i -= 1) {
            if (doh1 or doh2 or doh3) {
                lolim2 = lolim1;
                hilim2 = hilim1;
                lolim1 = hilim2;
                hilim1 = t - h.t[i - 1];
                delta1 = h.t[i] - h.t[i - 1];
            } else break; // all kernels chopped: remaining coefficients are 0

            if (doh1) {
                const h1dum2 = h1dum1;
                h1lov1 = h1hiv1;
                h1hiv1 = rlcH1dashTwiceIntFunc(hilim1, beta);
                h1dum1 = (h1hiv1 - h1lov1) / delta1;
                const coeff = h1dum1 - h1dum2;
                cv1 += coeff * (h.v1[i] - inst.v10);
                cv2 += coeff * (h.v2[i] - inst.v20);
                if (@abs(coeff) <= h1relval) doh1 = false;
            }

            if (i <= aux) {
                var barg: f64 = 0;
                var expterm_s: f64 = 0;
                if (doh2 or doh3) {
                    barg = if (hilim1 > T) alpha * @sqrt(hilim1 * hilim1 - T * T) else 0.0;
                    expterm_s = @exp(barg - beta * hilim1);
                }
                if (doh2) {
                    const h2lov2 = h2lov1;
                    const h2hiv2 = h2hiv1;
                    const h2dum2 = h2dum1;
                    h2lov1 = h2hiv2;
                    h2hiv1 = if (alpha == 0.0 or hilim1 < T) 0.0 else alphasqT * expterm_s * bessI1xOverXe(barg);
                    h2dum1 = twiceintlinfunc(lolim1, hilim1, lolim1, h2lov1, h2hiv1, lolim1, hilim1) / delta1;
                    // Bug-compat: at i == aux the (lolim2,hilim2) interval and
                    // the (h2lov2,h2hiv2) values belong to different spans —
                    // ngspice's disabled `if (i == auxindex)` correction.
                    const coeff = h2dum1 - h2dum2 + intlinfunc(lolim2, hilim2, h2lov2, h2hiv2, lolim2, hilim2);
                    ci2 += coeff * (h.i2[i] - inst.i20);
                    ci1 += coeff * (h.i1[i] - inst.i10);
                    if (@abs(coeff) <= h2relval) doh2 = false;
                }
                if (doh3) {
                    const h3dum2 = h3dum1;
                    h3lov1 = h3hiv1;
                    h3hiv1 = if (hilim1 <= T or beta == 0.0) 0.0 else expterm_s * bessI0e(barg) - expbetaT;
                    h3dum1 = intlinfunc(lolim1, hilim1, h3lov1, h3hiv1, lolim1, hilim1) / delta1;
                    const coeff = h3dum1 - h3dum2;
                    cw2 += coeff * (h.v2[i] - inst.v20);
                    cw1 += coeff * (h.v1[i] - inst.v10);
                    if (@abs(coeff) <= h3relval) doh3 = false;
                }
            }
        }

        // -- assemble inputs (ltraload RLC MODEINITPRED, verbatim order) --
        const del: Delayed = if (tdover)
            interpDelayed(h, aux, t - T)
        else
            .{ .v1 = inst.v10, .v2 = inst.v20, .i1 = inst.i10, .i2 = inst.i20 };

        // h1' * v: matrix carries c1h1·v_now; RHS the rest.
        var d1 = cv1 + inst.v10 * model.int_h1 - inst.v10 * c1h1;
        var d2 = cv2 + inst.v20 * model.int_h1 - inst.v20 * c1h1;
        in1 -= d1 * model.admit;
        in2 -= d2 * model.admit;

        // h2 * i.
        d1 = 0;
        d2 = 0;
        if (tdover) {
            d1 = (del.i2 - inst.i20) * h2first + ci2;
            d2 = (del.i1 - inst.i10) * h2first + ci1;
        }
        d1 += inst.i20 * model.int_h2;
        d2 += inst.i10 * model.int_h2;
        in1 += d1;
        in2 += d2;

        // h3' * v.
        d1 = 0;
        d2 = 0;
        if (tdover) {
            d1 = (del.v2 - inst.v20) * h3first + cw2;
            d2 = (del.v1 - inst.v10) * h3first + cw1;
        }
        d1 += inst.v20 * model.int_h3;
        d2 += inst.v10 * model.int_h3;
        in1 += model.admit * d1;
        in2 += model.admit * d2;

        // Lossless part.
        if (tdover) {
            in1 += model.atten * (del.v2 * model.admit + del.i2);
            in2 += model.atten * (del.v1 * model.admit + del.i1);
        } else {
            in1 += model.atten * (inst.v20 * model.admit + inst.i20);
            in2 += model.atten * (inst.v10 * model.admit + inst.i10);
        }
    } else {
        // LC: pure delay, attenuation 1.
        const del: Delayed = if (tdover)
            interpDelayed(h, aux, t - T)
        else
            .{ .v1 = inst.v10, .v2 = inst.v20, .i1 = inst.i10, .i2 = inst.i20 };
        in1 = model.atten * (del.v2 * model.admit + del.i2);
        in2 = model.atten * (del.v1 * model.admit + del.i1);
    }

    inst.c1h1 = c1h1;
    inst.c1h2 = 0;
    inst.c1h3 = 0;
    inst.in1 = in1;
    inst.in2 = in2;
    inst.cache_t = t;
}

pub fn rebuildRc(model: anytype, inst: anytype, t: f64) void {
    const h = hist(inst);
    const timeindex = h.t.len - 1;

    // First coefficients over [0, t − t_n] (LTRArcCoeffsSetup).
    var delta1 = t - h.t[timeindex];
    var hilim1 = delta1;
    var h1hiv1 = rcH1dashTwiceIntFunc(hilim1, model.cbyr);
    var h1dum1 = h1hiv1 / delta1;
    const c1h1 = h1dum1;
    const h1relval = @abs(h1dum1 * model.chopreltol);
    var h2hiv1 = rcH2TwiceIntFunc(hilim1, model.rclsqr);
    var h2dum1 = h2hiv1 / delta1;
    const c1h2 = h2dum1;
    const h2relval = @abs(h2dum1 * model.chopreltol);
    var h3hiv1 = rcH3dashTwiceIntFunc(hilim1, model.cbyr, model.rclsqr);
    var h3dum1 = h3hiv1 / delta1;
    const c1h3 = h3dum1;
    const h3relval = @abs(h3dum1 * model.chopreltol);

    var cv1: f64 = 0;
    var cv2: f64 = 0;
    var ci2: f64 = 0;
    var ci1: f64 = 0;
    var cw2: f64 = 0;
    var cw1: f64 = 0;
    var doh1 = true;
    var doh2 = true;
    var doh3 = true;
    var i: usize = timeindex;
    while (i > 0) : (i -= 1) {
        delta1 = h.t[i] - h.t[i - 1];
        hilim1 = t - h.t[i - 1];
        if (!(doh1 or doh2 or doh3)) break;

        if (doh1) {
            const h1dum2 = h1dum1;
            const h1lov1 = h1hiv1;
            h1hiv1 = rcH1dashTwiceIntFunc(hilim1, model.cbyr);
            h1dum1 = (h1hiv1 - h1lov1) / delta1;
            const coeff = h1dum1 - h1dum2;
            cv1 += coeff * (h.v1[i] - inst.v10);
            cv2 += coeff * (h.v2[i] - inst.v20);
            if (@abs(coeff) < h1relval) doh1 = false;
        }
        if (doh2) {
            const h2dum2 = h2dum1;
            const h2lov1 = h2hiv1;
            h2hiv1 = rcH2TwiceIntFunc(hilim1, model.rclsqr);
            h2dum1 = (h2hiv1 - h2lov1) / delta1;
            const coeff = h2dum1 - h2dum2;
            ci2 += coeff * (h.i2[i] - inst.i20);
            ci1 += coeff * (h.i1[i] - inst.i10);
            if (@abs(coeff) < h2relval) doh2 = false;
        }
        if (doh3) {
            const h3dum2 = h3dum1;
            const h3lov1 = h3hiv1;
            h3hiv1 = rcH3dashTwiceIntFunc(hilim1, model.cbyr, model.rclsqr);
            h3dum1 = (h3hiv1 - h3lov1) / delta1;
            const coeff = h3dum1 - h3dum2;
            cw2 += coeff * (h.v2[i] - inst.v20);
            cw1 += coeff * (h.v1[i] - inst.v10);
            if (@abs(coeff) < h3relval) doh3 = false;
        }
    }

    // ltraload RC MODEINITPRED.
    var in1: f64 = 0;
    var in2: f64 = 0;
    var d1 = cv1 + inst.v10 * model.int_h1 - inst.v10 * c1h1;
    var d2 = cv2 + inst.v20 * model.int_h1 - inst.v20 * c1h1;
    in1 -= d1;
    in2 -= d2;
    d1 = ci2 + inst.i20 * model.int_h2 - inst.i20 * c1h2;
    d2 = ci1 + inst.i10 * model.int_h2 - inst.i10 * c1h2;
    in1 += d1;
    in2 += d2;
    d1 = cw2 + inst.v20 * model.int_h3 - inst.v20 * c1h3;
    d2 = cw1 + inst.v10 * model.int_h3 - inst.v10 * c1h3;
    in1 += d1;
    in2 += d2;

    inst.c1h1 = c1h1;
    inst.c1h2 = c1h2;
    inst.c1h3 = c1h3;
    inst.in1 = in1;
    inst.in2 = in2;
    inst.cache_t = t;
}

// ---------------------------------------------------------------------------
// Residual (§1.3 branch rows + KCL port rows). Affine in x: AD hands the
// solver the exact Jacobian, including the per-timepoint first coefficients.
// ---------------------------------------------------------------------------

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, t: f64) [n_u]S {
    var res: [n_u]S = undefined;
    const ib1 = x[@intFromEnum(U.br1)];
    const ib2 = x[@intFromEnum(U.br2)];
    res[@intFromEnum(U.p1)] = ib1;
    res[@intFromEnum(U.n1)] = ib1.neg();
    res[@intFromEnum(U.p2)] = ib2;
    res[@intFromEnum(U.n2)] = ib2.neg();
    const v1 = x[@intFromEnum(U.p1)].sub(x[@intFromEnum(U.n1)]);
    const v2 = x[@intFromEnum(U.p2)].sub(x[@intFromEnum(U.n2)]);

    if (inst.dt <= 0.0 or inst.analysis_kind != .tran) {
        // ngspice MODEDC: i1 + i2 = 0; v1 − v2 = R·len·i1. (The reference row
        // reads pos1 − pos2 without the negs; the fixtures ground both negs,
        // and the full port difference is the correct generalization.)
        res[@intFromEnum(U.br1)] = ib1.add(ib2);
        res[@intFromEnum(U.br2)] = v1.sub(v2).sub(ib1.scale(model.r * model.len));
        return res;
    }

    // The per-timepoint stamp is frozen across Newton iterations (the line is
    // linear); rejected attempts land on a different t and rebuild. The cast
    // is sound: instances live in the batch's mutable heap slice, and ParEval
    // partitions ids disjointly across threads.
    const ii: *Instance = @constCast(inst);
    if (ii.cache_t != t) switch (model.case) {
        .lc, .rlc => rebuildWave(model, ii, t),
        .rc => rebuildRc(model, ii, t),
    };

    switch (model.case) {
        .lc, .rlc => {
            const yc = model.admit * (1.0 + ii.c1h1);
            res[@intFromEnum(U.br1)] = v1.scale(yc).sub(ib1).addC(-ii.in1);
            res[@intFromEnum(U.br2)] = v2.scale(yc).sub(ib2).addC(-ii.in2);
        },
        .rc => {
            res[@intFromEnum(U.br1)] = v1.scale(ii.c1h1).sub(ib1)
                .sub(ib2.scale(ii.c1h2)).sub(v2.scale(ii.c1h3)).addC(-ii.in1);
            res[@intFromEnum(U.br2)] = v2.scale(ii.c1h1).sub(ib2)
                .sub(ib1.scale(ii.c1h2)).sub(v1.scale(ii.c1h3)).addC(-ii.in2);
        },
    }
    return res;
}

// ---------------------------------------------------------------------------
// Accepted-step bookkeeping (ngspice LTRAaccept + LTRAtrunc's stepLimit /
// maxSafeStep). Runs on the engine's commit_state channel — once per ACCEPTED
// point — because a history push cannot be reverted.
// ---------------------------------------------------------------------------

/// Append one accepted sample to a line's history: first sample doubles as
/// the initVolt/initCur snapshot, a same-time recommit overwrites, a full
/// buffer compacts. Shared by the O-card device below and the coupled modal
/// lines (coupled_ltra.zig).
pub fn pushHistory(model: anytype, inst: anytype, t: f64, v1: f64, v2: f64, i1_: f64, i2_: f64) void {
    if (t == 0) inst.n_hist = 0;
    if (inst.n_hist == 0) {
        inst.v10 = v1;
        inst.v20 = v2;
        inst.i10 = i1_;
        inst.i20 = i2_;
    }
    if (inst.n_hist > 0 and t <= inst.hist_t[inst.n_hist - 1]) {
        const j = inst.n_hist - 1;
        inst.hist_v1[j] = v1;
        inst.hist_v2[j] = v2;
        inst.hist_i1[j] = i1_;
        inst.hist_i2[j] = i2_;
    } else {
        if (inst.n_hist == inst.hist_t.len) compact(model, inst);
        const j = inst.n_hist;
        inst.hist_t[j] = t;
        inst.hist_v1[j] = v1;
        inst.hist_v2[j] = v2;
        inst.hist_i1[j] = i1_;
        inst.hist_i2[j] = i2_;
        inst.n_hist += 1;
    }
    inst.cache_t = 1e31; // history changed: next eval rebuilds
}

pub const State = struct {};

pub fn initState(_: *const Model, _: *Instance) State {
    return .{};
}

pub fn updateState(model: *Model, inst: *Instance, x: [n_u]f64, _: *State) contract.UpdateResult {
    if (inst.analysis_kind != .tran) return .ok;
    const t = inst.abstime;
    // pushHistory resets on a t=0 commit: the transient seeds histories with
    // one commit at (t=0, dt=0, kind=tran) before stepping, so a fresh t=0
    // commit is a fresh transient.

    const v1 = x[@intFromEnum(U.p1)] - x[@intFromEnum(U.n1)];
    const v2 = x[@intFromEnum(U.p2)] - x[@intFromEnum(U.n2)];
    const ib1 = x[@intFromEnum(U.br1)];
    const ib2 = x[@intFromEnum(U.br2)];
    pushHistory(model, inst, t, v1, v2, ib1, ib2);

    // ngspice LTRAaccept: when the total launched wave (v + Z0·i, attenuated)
    // changes derivative at this end, the image arrives one delay later —
    // set a breakpoint at PREVIOUS accepted point + td so the integrator
    // lands on the wavefront. CHECK() is the steady-state noise guard
    // (CKTreltol/CKTabstol are the circuit tolerances; defaults hardcoded —
    // ponytail: plumb host tolerances if a deck ever overrides them).
    if (model.case != .rc and inst.n_hist >= 2) {
        const n = inst.n_hist;
        const wavesum = struct {
            fn at(in: *const Instance, m: *const Model, j: u32, port: u1) f64 {
                return if (port == 0)
                    (in.hist_v1[j] + in.hist_i1[j] * m.imped) * m.atten
                else
                    (in.hist_v2[j] + in.hist_i2[j] * m.imped) * m.atten;
            }
        }.at;
        const check = struct {
            fn f(a: f64, b: f64, c: f64) bool {
                const reltol = 1e-3;
                const abstol = 1e-12;
                return @max(@max(a, b), c) - @min(@min(a, b), c) >=
                    @abs(50.0 * (reltol / 3.0 * (a + b + c) + abstol));
            }
        }.f;
        const dtn = inst.hist_t[n - 1] - inst.hist_t[n - 2];
        const dtn1 = if (n >= 3) inst.hist_t[n - 2] - inst.hist_t[n - 3] else 1.0;
        var trip = false;
        inline for (.{ 0, 1 }) |port| {
            const w1 = wavesum(inst, model, n - 1, port);
            const w2 = wavesum(inst, model, n - 2, port);
            const w3 = if (n >= 3) wavesum(inst, model, n - 3, port) else w2;
            const d1 = (w1 - w2) / dtn;
            const d2 = if (n >= 3) (w2 - w3) / dtn1 else 0.0;
            if (@abs(d1 - d2) >= model.rel * @max(@abs(d1), @abs(d2)) + model.brkabs and check(w1, w2, w3))
                trip = true;
        }
        if (trip) {
            model.brk[model.brk_head] = inst.hist_t[n - 2] + model.td;
            model.brk_head = (model.brk_head + 1) % @as(u8, model.brk.len);
        }
    }

    // §1.7: stepLimit dt <= td, and the RLC kernel-resolution cap
    // (LTRAtrunc applies both per accepted step).
    var bs = inf;
    if (model.case != .rc) {
        if (model.steplimit != 0) bs = model.td;
        if (model.case == .rlc and model.truncdontcut == 0)
            bs = @min(bs, model.max_safe_step);
    }
    inst.bound_step = bs;
    return .ok;
}

/// Overflow valve: drop the interior point whose (t, v/i) triples are most
/// collinear (ngspice's trytocompact criterion — all four signals must pass).
/// Falls back to the oldest interior point: for decaying kernels the oldest
/// coefficients are the smallest, so the damage is bounded.
/// ponytail: O(CAP) scan + memmove once per overflowing accept; fixtures top
/// out well under CAP, so this is insurance, not a hot path.
pub fn compact(model: anytype, inst: anytype) void {
    const n = inst.n_hist;
    var drop: u32 = 1;
    var j: u32 = 1;
    while (j + 1 < n) : (j += 1) {
        const t0 = inst.hist_t[j - 1];
        const t1 = inst.hist_t[j];
        const t2 = inst.hist_t[j + 1];
        if (straightLineCheck(t0, inst.hist_v1[j - 1], t1, inst.hist_v1[j], t2, inst.hist_v1[j + 1], model.compactrel, model.compactabs) and
            straightLineCheck(t0, inst.hist_v2[j - 1], t1, inst.hist_v2[j], t2, inst.hist_v2[j + 1], model.compactrel, model.compactabs) and
            straightLineCheck(t0, inst.hist_i1[j - 1], t1, inst.hist_i1[j], t2, inst.hist_i1[j + 1], model.compactrel, model.compactabs) and
            straightLineCheck(t0, inst.hist_i2[j - 1], t1, inst.hist_i2[j], t2, inst.hist_i2[j + 1], model.compactrel, model.compactabs))
        {
            drop = j;
            break;
        }
    }
    inline for (.{ "hist_t", "hist_v1", "hist_v2", "hist_i1", "hist_i2" }) |f| {
        const arr = &@field(inst, f);
        const cap = arr.len;
        std.mem.copyForwards(f64, arr[drop .. cap - 1], arr[drop + 1 .. cap]);
    }
    inst.n_hist -= 1;
}

// ---------------------------------------------------------------------------
// Focused check: a matched RLC line launches a delayed, attenuated replica.
// Drives the device directly (precompute/updateState/eval) with algebraic
// Rs/RL terminations — no engine, so the module stays a leaf.
// ---------------------------------------------------------------------------

const TestScalar = struct {
    v: f64,
    const T = @This();
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

test "matched RLC line: delayed attenuated replica, exact DC settle" {
    // Z0 = 50, td = 10 ns, R·len = 1 Ω (β·td = 0.01): matched 50 Ω source and
    // load, unit step at t = 0+.
    var model: Model = .{ .r = 0.5, .l = 250e-9, .c = 100e-12, .len = 2 };
    var inst: Instance = .{};
    precompute(&inst, &model);
    try std.testing.expectEqual(Case.rlc, model.case);
    try std.testing.expectApproxEqRel(@as(f64, 50.0), model.imped, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 10e-9), model.td, 1e-12);

    const vs = 1.0;
    const rs = 50.0;
    const rl = 50.0;

    // DC operating point (v = 0 source): everything 0.
    inst.analysis_kind = .tran;
    var st: State = .{};
    inst.abstime = 0;
    inst.dt = 0;
    var xacc = [_]f64{0} ** n_u;
    _ = updateState(&model, &inst, xacc, &st); // seeds history at t=0

    // Step to 35 ns on a fixed grid. Per point: given (in1, in2) solve the
    // 2×2 affine system of line + terminations:
    //   v1 = vs − rs·i1, v2 = −rl·i2,
    //   yc·v1 − i1 = in1,  yc·v2 − i2 = in2   (yc = Y0(1+c1h1))
    const dt = 0.05e-9;
    var t: f64 = dt;
    var v2_at_half_td: f64 = 0;
    var v2_at_15n: f64 = 0;
    var v2_final: f64 = 0;
    while (t <= 35e-9 + 1e-15) : (t += dt) {
        inst.dt = dt;
        inst.abstime = t;
        var x = [_]TestScalar{.{ .v = 0 }} ** n_u;
        const r0 = eval(TestScalar, x, &model, &inst, t);
        // res_br1 = yc·v1 − i1 − in1 with x=0 gives −in1.
        const in1 = -r0[@intFromEnum(U.br1)].v;
        const in2 = -r0[@intFromEnum(U.br2)].v;
        const yc = model.admit * (1.0 + inst.c1h1);
        const ib1 = (yc * vs - in1) / (1.0 + yc * rs);
        const ib2 = -in2 / (1.0 + yc * rl);
        const v1 = vs - rs * ib1;
        const v2 = -rl * ib2;
        // Sanity: the solved point satisfies the residual.
        x[0] = .{ .v = v1 };
        x[4] = .{ .v = ib1 };
        x[2] = .{ .v = v2 };
        x[5] = .{ .v = ib2 };
        const rchk = eval(TestScalar, x, &model, &inst, t);
        try std.testing.expectApproxEqAbs(@as(f64, 0), rchk[@intFromEnum(U.br1)].v, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f64, 0), rchk[@intFromEnum(U.br2)].v, 1e-9);

        xacc = .{ v1, 0, v2, 0, ib1, ib2 };
        _ = updateState(&model, &inst, xacc, &st);
        if (@abs(t - 5e-9) < dt * 0.5) v2_at_half_td = v2;
        if (@abs(t - 15e-9) < dt * 0.5) v2_at_15n = v2;
        v2_final = v2;
    }

    // Before td: nothing has arrived.
    try std.testing.expectApproxEqAbs(@as(f64, 0), v2_at_half_td, 1e-6);
    // Just after td: the wavefront is the incident half-step attenuated by
    // e^{−βT} (dispersion then relaxes it toward DC).
    const front = 0.5 * vs * model.atten;
    try std.testing.expectApproxEqAbs(front, v2_at_15n, 0.02 * vs);
    // Long after: the exact DC divider through the line's series resistance.
    const dc = vs * rl / (rs + model.r * model.len + rl);
    try std.testing.expectApproxEqAbs(dc, v2_final, 2e-3 * vs);
}
