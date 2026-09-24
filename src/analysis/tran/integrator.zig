//! Integration methods: dynamic-residual coefficients, the dynamic-current
//! recurrence and the CKTterr LTE bound. tran.zig drives these per step.
const std = @import("std");
const Method = @import("types.zig").Method;

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;

/// Integration coefficients — ngspice's `CKTag[]` (`NIcomCof`,
/// maths/ni/nicomcof.c). `ag0` is the q(x) coefficient, i.e. the companion
/// conductance multiplier `geq = ag[0]*cap` (niinteg.c:77) and the Jacobian
/// axpy weight; `ag2` is the q_prev2 coefficient, gear-2 only.
///
///   BE:   F_dyn = (1/dt)*(q - q1)
///   trap: F_dyn = (2/dt)*(q - q1) - i_prev
///   gear: F_dyn = ag0*q + ag1*q1 + ag2*q2  ==  ag0*(q - q1) - ag2*(q1 - q2)
///         since ag0 + ag1 + ag2 = 0 (the corrector is exact on constants).
///
/// GEAR ON A NON-UNIFORM GRID. ngspice solves a Vandermonde system over the
/// ACTUAL step history `CKTdeltaOld[]` (nicomcof.c:60-136) — its gear-2 is
/// a variable-step BDF2. espice hardcoded the uniform-step coefficients
/// 3/(2dt), -2/dt, 1/(2dt), which are only consistent while dt == dt_prev.
/// At order 2 that Vandermonde solve has the closed form below, r = dt/dt1:
///   ag0 = (1+2r)/((1+r)*dt)   ag1 = -(1+r)/dt   ag2 = r^2/((1+r)*dt)
/// r == 1 recovers the hardcoded triple exactly.
///
/// The old constants survived only because every shipping gear deck is
/// tmax-locked at tstep, so dt never varied. Correcting the gear LTE
/// coefficient (previous commit) made dt vary and the inconsistency bit
/// immediately: mos6 at 373 steps was 8.2e-2 rms against its own converged
/// reference, worse than the 316-step trapezoidal run.
pub const Coeffs = struct { ag0: f64, ag2: f64 };
pub fn coeffs(method: Method, dt: f64, dt_prev: f64) Coeffs {
    return switch (method) {
        .backward_euler => .{ .ag0 = 1.0 / dt, .ag2 = 0 },
        .trapezoidal => .{ .ag0 = 2.0 / dt, .ag2 = 0 },
        .gear_2 => blk: {
            const r = dt / dt_prev;
            break :blk .{
                .ag0 = (1.0 + 2.0 * r) / ((1.0 + r) * dt),
                .ag2 = r * r / ((1.0 + r) * dt),
            };
        },
    };
}

/// LTE divided-difference coefficient — ngspice `CKTterr`
/// (spicelib/analysis/cktterr.c:24-34, selected at :58-67 by
/// `CKTintegrateMethod`, indexed `[CKTorder-1]`):
///   gearCoeff = {.5, .2222222222, .1363636364, .096, .0729927, .0583090}
///   trapCoeff = {.5, .08333333333}
/// espice's order is fixed by the method (BE = 1, trap/gear_2 = 2), so the
/// coefficient is a function of the method alone. Order 1 is `.5` in both
/// tables, which is why BE reads the same either way — and why the order-2
/// GEAR entry (2/9) was the only one that could be, and was, wrong: it had
/// been sharing `trapCoeff[1]`, a 1.63x looser bound than GEAR asks for.
pub fn lteCoeff(method: Method) f64 {
    return switch (method) {
        .backward_euler => 0.5, // gearCoeff[0] == trapCoeff[0]
        .trapezoidal => 1.0 / 12.0, // trapCoeff[1]
        .gear_2 => 2.0 / 9.0, // gearCoeff[1]
    };
}

/// Dynamic-current recurrence, in place — ngspice `NIintegrate`
/// (maths/ni/niinteg.c) writing `CKTstate0[qcap+1]`:
///   BE   : i_j <- ag0*(q0_j - q1_j)
///   trap : i_j <- ag0*(q0_j - q1_j) - i_j
///   gear : i_j <- ag0*(q0_j - q1_j) - ag2*(q1_j - q2_j)
/// i.e. `CKTstate0[qcap+1]` under each method's `CKTag[]`. The gear arm was
/// missing its ag2 term, so `i_prev` — which is what CKTterr's `volttol`
/// reads — was the BE current on every gear deck.
/// One body for the summed row plane (companion residual, length n) and for
/// the per-device-state tape (LTE only, length n_qt). The BE and trap
/// expressions are untouched, so the row plane — which feeds the residual —
/// stays bit-identical on every non-gear deck.
pub fn advanceCurrent(method: Method, i_cur: []f64, q0: []const f64, q1: []const f64, q2: []const f64, c: Coeffs) void {
    // Comptime method, for the reason `stepBound` gives.
    switch (method) {
        inline else => |m| companionAt(m, false, i_cur, q0, q1, q2, i_cur, c),
    }
}

/// The one companion kernel, `d = ag0·(q0 − q1)` plus the method's history
/// term, over any index space:
///   accumulate = false: out  = d [− i_prev | − ag2·(q1 − q2)]  (NIintegrate)
///   accumulate = true:  out += the same, the Newton residual's dynamic part
/// `i_prev` may alias `out` (the in-place recurrence). With `accumulate` the
/// vector body sums (out + d) − history while the scalar tail sums
/// out + (d − history): the two orders the hand copies had, kept so every
/// deck stays bit-identical. q2 is read by gear only, i_prev by trap only.
pub fn companionAt(
    comptime method: Method,
    comptime accumulate: bool,
    out: []f64,
    q0: []const f64,
    q1: []const f64,
    q2: []const f64,
    i_prev: []const f64,
    c: Coeffs,
) void {
    const V = @Vector(W, f64);
    const av: V = @splat(c.ag0);
    const a2: V = @splat(c.ag2);
    var j: usize = 0;
    while (j + W <= out.len) : (j += W) {
        const a: V = q0[j..][0..W].*;
        const b: V = q1[j..][0..W].*;
        const d = av * (a - b);
        const base = if (accumulate) @as(V, out[j..][0..W].*) + d else d;
        out[j..][0..W].* = switch (method) {
            .trapezoidal => base - @as(V, i_prev[j..][0..W].*),
            .gear_2 => base - a2 * (b - @as(V, q2[j..][0..W].*)),
            .backward_euler => base,
        };
    }
    while (j < out.len) : (j += 1) {
        const d = c.ag0 * (q0[j] - q1[j]);
        const v = switch (method) {
            .trapezoidal => d - i_prev[j],
            .gear_2 => d - c.ag2 * (q1[j] - q2[j]),
            .backward_euler => d,
        };
        out[j] = if (accumulate) out[j] + v else v;
    }
}

/// Accepted-point charge re-read: `i_cur += alpha·(q_new − q_old)`, per
/// element. Elementwise, so every `w` is bit-identical; `w == 1` is the
/// scalar oracle (tests/transient.zig). LLVM left the plain loop scalar —
/// it cannot prove the three history slices disjoint.
pub fn rebaseCurrent(comptime w: usize, i_cur: []f64, q_new: []const f64, q_old: []const f64, alpha: f64) void {
    const V = @Vector(w, f64);
    const av: V = @splat(alpha);
    var j: usize = 0;
    while (j + w <= i_cur.len) : (j += w) {
        const qn: V = q_new[j..][0..w].*;
        const qo: V = q_old[j..][0..w].*;
        i_cur[j..][0..w].* = @as(V, i_cur[j..][0..w].*) + av * (qn - qo);
    }
    if (comptime w > 1) rebaseCurrent(1, i_cur[j..], q_new[j..], q_old[j..], alpha);
}

/// ngspice CKTterr: per-state timestep bound, in seconds. For each
/// charge state j (tolerance in CURRENT units, cktterr.c):
///   i_new_j     = what `advanceCurrent` will write for `cur_method`
///   volttol_j   = abstol + reltol·max(|i_new_j|, |i_prev_j|)
///   chargetol_j = reltol·max(|q0_j|, |q1_j|, chgtol) / dt
///   tol_j       = max(volttol_j, chargetol_j)
///   dd_j        = divided difference over order+2 charge points
///   del_j       = trtol·tol_j / max(abstol, coeff·|dd_j|)
///   order 2:      del_j = sqrt(del_j)
/// coeff = `lteCoeff(method)`; order = 2 for everything but BE.
/// Returns min del over all states; the caller accepts the step iff
/// del > 0.9·dt and uses del as the next dt (dctran.c:872-913).
/// `method` sets the coefficient and the order — at the BE->order-2
/// promotion probe (dctran.c:901-913) that is the method being PROBED.
/// `cur_method`/`c` are the ones the step actually integrated with, which
/// is what `CKTstate0[qcap+1]` holds when CKTterr reads it.
/// `q` is the charge history [cur, prev, prev2, prev3] and `i_prev` the
/// dynamic current, over one index space (per device state or per row).
pub fn stepBound(method: Method, cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    // Both methods comptime: LLVM kept the `cur_method` switch and the
    // `order2` test inside the vector loop (6 of ~60 instructions per
    // 4 states). Same arithmetic per arm, so the result is bit-identical.
    return switch (method) {
        inline else => |m| switch (cur_method) {
            inline else => |cm| stepBoundAt(m, cm, q, i_prev, c, lte),
        },
    };
}

/// The step history and tolerances one `stepBound` reads: dt is the step
/// just taken, dt1/dt2 the two before it.
pub const LteIn = struct { dt: f64, dt1: f64, dt2: f64, reltol: f64, abstol: f64, chgtol: f64, trtol: f64 };

fn stepBoundAt(comptime method: Method, comptime cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    const q_cur = q[0];
    const q_prev = q[1];
    const q_prev2 = q[2];
    const q_prev3 = q[3];
    const dt = lte.dt;
    const dt1 = lte.dt1;
    const dt2 = lte.dt2;
    const reltol = lte.reltol;
    const abstol = lte.abstol;
    const chgtol = lte.chgtol;
    const trtol = lte.trtol;
    const order2 = method != .backward_euler;
    const lc = lteCoeff(method);
    const V = @Vector(W, f64);
    const inv_dt: V = @splat(1.0 / dt);
    const inv_dt1: V = @splat(1.0 / dt1);
    const inv_sum01: V = @splat(1.0 / (dt + dt1));
    const av: V = @splat(c.ag0);
    const a2: V = @splat(c.ag2);
    const v_abstol: V = @splat(abstol);
    const v_reltol: V = @splat(reltol);
    const v_chgtol: V = @splat(chgtol);
    const v_trtol: V = @splat(trtol);
    const coeff: V = @splat(lc);
    var vmin: V = @splat(std.math.inf(f64));
    var i: usize = 0;

    while (i + W <= q_cur.len) : (i += W) {
        const qc: V = q_cur[i..][0..W].*;
        const qp: V = q_prev[i..][0..W].*;
        const ip: V = i_prev[i..][0..W].*;
        const qp2: V = q_prev2[i..][0..W].*;
        const i_new = switch (cur_method) {
            .trapezoidal => av * (qc - qp) - ip,
            .gear_2 => av * (qc - qp) - a2 * (qp - qp2),
            .backward_euler => av * (qc - qp),
        };
        const volttol = v_abstol + v_reltol * @max(@abs(i_new), @abs(ip));
        const chargetol = v_reltol * @max(@max(@abs(qc), @abs(qp)), v_chgtol) * inv_dt;
        const tol = @max(volttol, chargetol);

        const f01 = (qc - qp) * inv_dt;
        const f12 = (qp - qp2) * inv_dt1;
        const f012 = (f01 - f12) * inv_sum01;
        var dd = f012;
        if (order2) {
            const qp3: V = q_prev3[i..][0..W].*;
            const f23 = (qp2 - qp3) * @as(V, @splat(1.0 / dt2));
            const f123 = (f12 - f23) * @as(V, @splat(1.0 / (dt1 + dt2)));
            dd = (f012 - f123) * @as(V, @splat(1.0 / (dt + dt1 + dt2)));
        }
        const del = v_trtol * tol / @max(v_abstol, coeff * @abs(dd));
        vmin = @min(vmin, del);
    }
    var min_del = @reduce(.Min, vmin);
    // Scalar tail
    while (i < q_cur.len) : (i += 1) {
        const d = c.ag0 * (q_cur[i] - q_prev[i]);
        const i_new = switch (cur_method) {
            .trapezoidal => d - i_prev[i],
            .gear_2 => d - c.ag2 * (q_prev[i] - q_prev2[i]),
            .backward_euler => d,
        };
        const volttol = abstol + reltol * @max(@abs(i_new), @abs(i_prev[i]));
        const chargetol = reltol * @max(@max(@abs(q_cur[i]), @abs(q_prev[i])), chgtol) / dt;
        const tol = @max(volttol, chargetol);
        const f01 = (q_cur[i] - q_prev[i]) / dt;
        const f12 = (q_prev[i] - q_prev2[i]) / dt1;
        const f012 = (f01 - f12) / (dt + dt1);
        var dd = f012;
        if (order2) {
            const f23 = (q_prev2[i] - q_prev3[i]) / dt2;
            const f123 = (f12 - f23) / (dt1 + dt2);
            dd = (f012 - f123) / (dt + dt1 + dt2);
        }
        const del = trtol * tol / @max(abstol, lc * @abs(dd));
        min_del = @min(min_del, del);
    }
    // sqrt is monotone — applying it to the reduced min is equivalent
    // to per-lane sqrt, and cheaper.
    return if (order2) @sqrt(min_del) else min_del;
}
