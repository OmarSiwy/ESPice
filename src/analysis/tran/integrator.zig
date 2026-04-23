//! Integration kernels: the companion coefficients, the dynamic-current
//! recurrence and the CKTterr LTE bound. tran.zig drives them per step;
//! envelope, tran_noise and pss reuse the companion kernel.
const std = @import("std");
const Method = @import("types.zig").Method;

// ponytail: platform SIMD width, not hardcoded.
const W = std.simd.suggestVectorLength(f64) orelse 8;

/// Integration coefficients, ngspice `CKTag[]` (nicomcof.c). `ag0` multiplies
/// q(x): it is the companion conductance factor (niinteg.c:77) and the
/// Jacobian axpy weight. `ag2` multiplies q_prev2 and is nonzero for gear-2
/// only. With ag0 + ag1 + ag2 = 0 each method's dynamic residual is
///   BE:   ag0*(q - q1)
///   trap: ag0*(q - q1) - i_prev
///   gear: ag0*(q - q1) - ag2*(q1 - q2)
pub const Coeffs = struct { ag0: f64, ag2: f64 };

/// Coefficients for a step of `dt` seconds after one of `dt_prev`. Gear-2 is
/// the variable-step BDF2 ngspice solves as a Vandermonde system over the
/// real step history (nicomcof.c:60-136); with r = dt/dt_prev its closed form
/// is ag0 = (1+2r)/((1+r)dt), ag2 = r^2/((1+r)dt), and r = 1 gives the
/// uniform-step 3/(2dt), 1/(2dt).
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

/// LTE divided-difference coefficient, ngspice `CKTterr` (cktterr.c:24-34)
/// indexed by order: gearCoeff = {.5, 2/9, ...}, trapCoeff = {.5, 1/12}. The
/// order here is fixed by the method (BE 1, trap and gear-2 2).
pub fn lteCoeff(method: Method) f64 {
    return switch (method) {
        .backward_euler => 0.5, // gearCoeff[0] == trapCoeff[0]
        .trapezoidal => 1.0 / 12.0, // trapCoeff[1]
        .gear_2 => 2.0 / 9.0, // gearCoeff[1]
    };
}

/// Advances the dynamic current in place, ngspice `NIintegrate` writing
/// `CKTstate0[qcap+1]`: i <- ag0*(q0 - q1) minus the method's history term.
/// Serves both the summed row plane (length n) and the per-state tape.
pub fn advanceCurrent(method: Method, i_cur: []f64, q0: []const f64, q1: []const f64, q2: []const f64, c: Coeffs) void {
    switch (method) {
        inline else => |m| companionAt(m, false, i_cur, q0, q1, q2, i_cur, c),
    }
}

/// The companion kernel over any index space, `d = ag0*(q0 - q1)` minus the
/// method's history term (i_prev for trap, ag2*(q1 - q2) for gear):
///   accumulate = false: out  = d - history   (NIintegrate)
///   accumulate = true:  out += d - history   (the Newton residual's dynamic part)
/// `i_prev` may alias `out`. q2 is read by gear only, i_prev by trap only.
/// With `accumulate`, the vector body rounds (out + d) - history and the
/// scalar tail out + (d - history); changing either order moves deck output.
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

/// Accepted-point charge re-read: `i_cur += alpha*(q_new - q_old)`.
/// Elementwise, so every `w` gives the same bits; `w == 1` is the scalar
/// oracle (tests/transient.zig).
pub fn rebaseCurrent(comptime w: usize, i_cur: []f64, q_new: []const f64, q_old: []const f64, alpha: f64) void {
    // Hand-vectorized: LLVM left the plain loop scalar because it cannot
    // prove the three history slices disjoint.
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

/// Step history and tolerances for one `stepBound`: `dt` is the step just
/// taken, `dt1`/`dt2` the two before it, all in seconds.
pub const LteIn = struct { dt: f64, dt1: f64, dt2: f64, reltol: f64, abstol: f64, chgtol: f64, trtol: f64 };

/// ngspice CKTterr: the next-step bound in seconds, min over every charge
/// state j of
///   i_new_j     = what `advanceCurrent` writes under `cur_method`
///   tol_j       = max(abstol + reltol*max(|i_new_j|, |i_prev_j|),
///                     reltol*max(|q0_j|, |q1_j|, chgtol)/dt)
///   del_j       = trtol*tol_j / max(abstol, lteCoeff(method)*|dd_j|)
/// with dd_j the divided difference over order+2 charge points, and the
/// square root taken at order 2. The caller accepts the step when
/// del > 0.9*dt (dctran.c:872-913).
///
/// `method` sets the coefficient and order; at the BE-to-order-2 promotion
/// probe (dctran.c:901-913) it is the method being probed. `cur_method` and
/// `c` are what the step integrated with. `q` is the charge history
/// [cur, prev, prev2, prev3] over one index space (per state or per row).
pub fn stepBound(method: Method, cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    // Both methods comptime: a runtime switch stayed inside the vector loop.
    return switch (method) {
        inline else => |m| switch (cur_method) {
            inline else => |cm| stepBoundAt(m, cm, q, i_prev, c, lte),
        },
    };
}

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
    // sqrt is monotone, so one sqrt of the min equals the min of the sqrts.
    return if (order2) @sqrt(min_del) else min_del;
}
