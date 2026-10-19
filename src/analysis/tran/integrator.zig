//! Integration kernels: the companion coefficients, the dynamic-current
//! recurrence, the companion step's Newton hook and the CKTterr LTE bound.
//! tran.zig drives them per step; envelope and pss reuse the hook, and
//! tran_noise the companion kernel.
//! Cites ngspice nicomcof.c, niinteg.c, cktterr.c and dctran.c;
//! dev/analysis/transient-integration.md.
const std = @import("std");
const Method = @import("types.zig").Method;
const num = @import("core").numerics;

const W = std.simd.suggestVectorLength(f64) orelse 8;

/// Integration coefficients, ngspice `CKTag[]` (nicomcof.c). `ag0` multiplies
/// q(x): it is the companion conductance factor (niinteg.c:77) and the
/// Jacobian axpy weight. `ag2` multiplies q_prev2 and is nonzero for gear-2
/// only. `ag1` weighs trap's previous current, ngspice's xmu/(1 - xmu): 1 for
/// the plain trapezoid. Each method's dynamic residual is
///   BE:      ag0*(q - q1)
///   trap:    ag0*(q - q1) - ag1*i_prev
///   gear-2:  ag0*(q - q1) - ag2*(q1 - q2)
///   gear-k:  ag0*(q - q1) - g, g = `gearHistory` of the step (k = 3..6)
pub const Coeffs = struct { ag0: f64, ag2: f64, ag1: f64 = 1 };

comptime {
    // Passed by value into every step's hook and LTE call.
    std.debug.assert(@sizeOf(Coeffs) == 24);
    std.debug.assert(@sizeOf(LteIn) == 56);
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Hook(null)) == 96);
        std.debug.assert(@sizeOf(Hook(.trapezoidal)) == 112);
    }
}

/// Coefficients for a step of `dt` seconds after one of `dt_prev`. Gear-2 is
/// the variable-step BDF2 ngspice solves as a Vandermonde system over the
/// real step history (nicomcof.c:60-136); with r = dt/dt_prev its closed form
/// is ag0 = (1+2r)/((1+r)dt), ag2 = r^2/((1+r)dt), and r = 1 gives the
/// uniform-step 3/(2dt), 1/(2dt). `xmu` is the trapezoid's weight
/// (`Options.xmu`); at 0.5 its coefficients are exactly 2/dt and 1.
pub fn coeffs(method: Method, dt: f64, dt_prev: f64, xmu: f64) Coeffs {
    return switch (method) {
        .backward_euler => .{ .ag0 = 1.0 / dt, .ag2 = 0 },
        .trapezoidal => .{ .ag0 = 1.0 / dt / (1.0 - xmu), .ag2 = 0, .ag1 = xmu / (1.0 - xmu) },
        .gear_2 => blk: {
            const r = dt / dt_prev;
            break :blk .{
                .ag0 = (1.0 + 2.0 * r) / ((1.0 + r) * dt),
                .ag2 = r * r / ((1.0 + r) * dt),
            };
        },
        else => unreachable, // gear_3..6 read the whole step history: `gearAg`
    };
}

/// The integration order of `method`: BE 1, trap 2, gear_k k.
pub fn order(method: Method) u8 {
    return switch (method) {
        .backward_euler => 1,
        .trapezoidal => 2,
        else => @backingInt(method) - @backingInt(Method.gear_2) + 2,
    };
}

/// Gear of order `k`, 2..6.
pub fn gear(k: u8) Method {
    std.debug.assert(k >= 2 and k <= 6);
    return @fromBackingInt(@intCast(@backingInt(Method.gear_2) + k - 2));
}

/// The most an accepted step at `method` may grow the next one, as a ratio.
/// Orders 1 and 2 keep ngspice's 2 (dctran.c). Variable-step BDF-k is
/// zero-stable under a constant step ratio only below 2.414, 1.618, 1.280,
/// 1.127 and 1.044 for k = 2..6 (Grigorieff, Numer. Math. 42, 1983; the
/// thresholds re-measured with a y' = 0 march), and a run of capped growth
/// is such a ratio, so each order keeps a margin under its threshold.
/// Shrinking is not limited: a single small ratio amplifies a parasitic
/// mode by a bounded factor, and promotion waits k + 1 steps at one order.
pub fn maxGrowth(method: Method) f64 {
    return switch (method) {
        .gear_3 => 1.5,
        .gear_4 => 1.2,
        .gear_5 => 1.1,
        .gear_6 => 1.03,
        else => 2,
    };
}

/// Order-k (3..6) Gear coefficients, ngspice nicomcof.c: ag[i] weighs
/// q_{n-i} in q'(t_n) ~ sum ag[i]*q_{n-i}, solved per step from the real
/// step history `dts` = [dt, dt_prev, dt_prev2, ...] (seconds, k entries
/// read). With s_i = t_n - t_{n-i} the (k+1)-square system is
///   sum ag_i = 0,  sum ag_i (s_i/dt) = -1/dt,  sum ag_i (s_i/dt)^j = 0, j = 2..k,
/// factored as nicomcof.c does: Doolittle without pivoting, skipping the
/// first column (1, 0, ..., 0). Entries past k are 0.
pub fn gearAg(k: u8, dts: []const f64) [7]f64 {
    std.debug.assert(k >= 3 and k <= 6 and dts.len >= k);
    const n: usize = k + 1;
    var mat: [7][7]f64 = undefined;
    var ag: [7]f64 = @splat(0);
    ag[1] = -1 / dts[0];
    var arg: f64 = 0;
    for (0..n) |i| {
        if (i > 0) arg += dts[i - 1];
        var p: f64 = 1;
        for (0..n) |j| {
            mat[j][i] = p;
            p *= arg / dts[0];
        }
    }
    for (1..n) |i| for (i + 1..n) |j| {
        mat[j][i] /= mat[i][i];
        for (i + 1..n) |c| mat[j][c] -= mat[j][i] * mat[i][c];
    };
    for (1..n) |i| for (i + 1..n) |j| {
        ag[j] -= mat[j][i] * ag[i];
    };
    ag[k] /= mat[k][k];
    var i: usize = k;
    while (i > 0) {
        i -= 1;
        for (i + 1..n) |j| ag[i] -= mat[i][j] * ag[j];
        ag[i] /= mat[i][i];
    }
    return ag;
}

/// The constant part of an order-k Gear step's dynamic current over one
/// index space, g = sum over i = 2..k of ag[i]*(q[1] - q[i]), so that
/// i = ag[0]*(q[0] - q[1]) - g. `q` is the history [cur, prev, ...] of k + 1
/// slots (slot 0 is not read); `companionAt` takes `g` as its `q2`.
pub fn gearHistory(g: []f64, q: []const []f64, ag: [7]f64) void {
    @memset(g, 0);
    for (q[2..], ag[2..q.len]) |qi, a| {
        for (g, q[1], qi) |*o, b, c| o.* += a * (b - c);
    }
}

/// LTE divided-difference coefficient, ngspice `CKTterr` (cktterr.c:24-34)
/// indexed by order: gearCoeff = {.5, .2222222222, ...}, trapCoeff = {.5,
/// .08333333333}. The order is the method's (`order`).
pub fn lteCoeff(method: Method) f64 {
    // ngspice's decimals, not 2/9 and 1/12: the 4e-11 relative gap moves
    // every LTE-chosen step by 2e-11, which a 256-stage inverter chain
    // amplifies past tolerance.
    return switch (method) {
        .backward_euler => 0.5, // gearCoeff[0] == trapCoeff[0]
        .trapezoidal => 0.08333333333, // trapCoeff[1]
        .gear_2 => 0.2222222222, // gearCoeff[1]
        .gear_3 => 0.1363636364,
        .gear_4 => 0.096,
        .gear_5 => 0.07299270073,
        .gear_6 => 0.05830903790,
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
/// method's history term (ag1*i_prev for trap, ag2*(q1 - q2) for gear-2, and
/// for gear-3..6 `q2` itself, which then holds `gearHistory`'s g):
///   accumulate = false: out  = d - history   (NIintegrate)
///   accumulate = true:  out += d - history   (the Newton residual's dynamic part)
/// `i_prev` may alias `out`. q2 is read by gear only, i_prev by trap only.
/// With `accumulate` every element rounds (out + d) - history: the tail is
/// the w == 1 instantiation of the vector lane, so position in the slice
/// never changes the bits.
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
    var j: usize = 0;
    while (j + W <= out.len) : (j += W) companionLane(W, method, accumulate, j, out, q0, q1, q2, i_prev, c);
    while (j < out.len) : (j += 1) companionLane(1, method, accumulate, j, out, q0, q1, q2, i_prev, c);
}

inline fn companionLane(
    comptime w: usize,
    comptime method: Method,
    comptime accumulate: bool,
    j: usize,
    out: []f64,
    q0: []const f64,
    q1: []const f64,
    q2: []const f64,
    i_prev: []const f64,
    c: Coeffs,
) void {
    const V = @Vector(w, f64);
    const a: V = q0[j..][0..w].*;
    const b: V = q1[j..][0..w].*;
    const d = @as(V, @splat(c.ag0)) * (a - b);
    const base = if (accumulate) @as(V, out[j..][0..w].*) + d else d;
    out[j..][0..w].* = switch (method) {
        .trapezoidal => base - @as(V, @splat(c.ag1)) * @as(V, i_prev[j..][0..w].*),
        .gear_2 => base - @as(V, @splat(c.ag2)) * (b - @as(V, q2[j..][0..w].*)),
        .backward_euler => base,
        else => base - @as(V, q2[j..][0..w].*),
    };
}

/// The converger hook of one companion step: `evalNewton` at x, then the
/// method's dynamic current (`companionAt`) added to the residual rows; the
/// matrix is G + ag0·C, or G alone without charge. `fixed` pins a one-step
/// method at comptime (pss and envelope: the plain trapezoid, ag1 = 1 and
/// only `c.ag0` read), which also keeps q(x) of every assemble in `q_cur`
/// for `accept`; null reads `method` and all of `c` per step (tran). `ckt` is a `*Circuit`; tests/codegen.zig probes the hook
/// against hand-written copies on a stand-in.
pub fn Hook(comptime fixed: ?Method) type {
    if (fixed) |m| comptime std.debug.assert(order(m) == 1 or m == .trapezoidal); // `accept` drops q_prev2
    return struct {
        const Self = @This();

        /// The method this attempt integrates with (BE while order-dropped).
        method: if (fixed == null) Method else void,
        c: Coeffs,
        q_prev: []f64,
        i_prev: []f64, // read by trap only
        q_prev2: []const f64 = &.{}, // gear_2: q_prev2; gear_3..6: `gearHistory`
        /// q(x) of the last assemble.
        q_cur: if (fixed == null) void else []f64,
        a_vals: []f64,
        has_charge: bool,

        /// Stamps the planes at `x` and adds the companion's dynamic current
        /// to the residual rows.
        pub fn assemble(self: *const Self, ckt: anytype, x: []const f64, t: f64) void {
            ckt.evalNewton(x, t);
            if (!self.has_charge) return;
            const n: usize = ckt.n;
            if (fixed) |m| {
                num.copySimd(self.q_cur[0..n], ckt.q_vec[0..n]);
                companionAt(m, true, ckt.rhs[0..n], ckt.q_vec[0..n], self.q_prev[0..n], &.{}, self.i_prev[0..n], .{ .ag0 = self.c.ag0, .ag2 = 0 });
            } else switch (self.method) {
                inline else => |m| companionAt(m, true, ckt.rhs[0..n], ckt.q_vec[0..n], self.q_prev, self.q_prev2, self.i_prev, self.c),
            }
        }

        /// The Newton matrix values: G itself without charge, else G + ag0·C
        /// rebuilt into `a_vals`, overwriting the previous return.
        pub fn vals(self: *const Self, ckt: anytype) []f64 {
            if (!self.has_charge) return ckt.g_vals;
            ckt.combineGC(self.c.ag0, self.a_vals);
            return self.a_vals;
        }

        /// One diagonal of the combined matrix without materializing it
        /// (`Circuit.gcAt`); the residual gate calls this per unknown.
        pub fn diagAt(self: *const Self, ckt: anytype, slot: u32) f64 {
            return if (self.has_charge) ckt.gcAt(self.c.ag0, slot) else ckt.g_vals[slot];
        }

        /// The accepted step of a fixed method: i_prev = its dynamic current
        /// at `q_cur`, then q_prev = q_cur. Asserts a fixed method.
        pub fn accept(self: *const Self, n: usize) void {
            comptime std.debug.assert(fixed != null);
            companionAt(fixed.?, false, self.i_prev[0..n], self.q_cur[0..n], self.q_prev[0..n], &.{}, self.i_prev[0..n], .{ .ag0 = self.c.ag0, .ag2 = 0 });
            num.copySimd(self.q_prev[0..n], self.q_cur[0..n]);
        }
    };
}

/// Accepted-point charge re-read: `i_cur += alpha*(q_new - q_old)`.
pub fn rebaseCurrent(i_cur: []f64, q_new: []const f64, q_old: []const f64, alpha: f64) void {
    for (i_cur, q_new, q_old) |*c, a, b| c.* += alpha * (a - b);
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
/// del > 0.9*dt (dctran.c:872-913). NaN when any entry read (q slots the
/// order uses, i_prev) is NaN or inf, or a del_j is 0/0.
///
/// `method` sets the coefficient and order; at the BE-to-order-2 promotion
/// probe (dctran.c:901-913) it is the method being probed. `cur_method` and
/// `c` are what the step integrated with. `q` is the charge history
/// [cur, prev, prev2, prev3] over one index space (per state or per row).
/// Each state rounds as cktterr.c does, divisions included, so every `w`
/// gives the same bits; `w == 1` is the scalar oracle (tests/transient.zig).
/// Both methods are of order 1 or 2; above that, `stepBoundGear`.
pub fn stepBound(comptime w: usize, method: Method, cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    // Both methods comptime: a runtime switch stayed inside the vector loop.
    const min_del = switch (method) {
        inline .backward_euler, .trapezoidal, .gear_2 => |m| switch (cur_method) {
            inline .backward_euler, .trapezoidal, .gear_2 => |cm| minDel(w, m, cm, q, i_prev, c, lte),
            else => unreachable, // order > 2: stepBoundGear
        },
        else => unreachable,
    };
    // sqrt is monotone, so one sqrt of the min equals the min of the sqrts.
    return if (method == .backward_euler) min_del else @sqrt(min_del);
}

/// `stepBound` for a Gear order above 2, as `method` or as `cur_method`:
/// cktterr.c's divided-difference loop over order + 2 charge points, then
/// the order-th root (exp(log(del)/order), as cktterr.c takes it). Scalar.
/// `q` is the history [cur, prev, ...] with at least order(method) + 2
/// slots, `dts` the steps [dt, dt_prev, ...] with at least order(method) + 1
/// (`lte`'s dt fields are not read), and `g` the step's `gearHistory` when
/// `cur_method` is gear-3..6. NaN as `stepBound`.
pub fn stepBoundGear(method: Method, cur_method: Method, q: []const []const f64, i_prev: []const f64, g: []const f64, c: Coeffs, lte: LteIn, dts: []const f64) f64 {
    const p = order(method);
    std.debug.assert(q.len >= p + 2 and dts.len >= p + 1);
    const coeff = lteCoeff(method);
    var min_del = std.math.inf(f64);
    // NaN once a read entry is NaN or inf, as in `minDel`.
    var poison: f64 = 0;
    for (0..q[0].len) |j| {
        const qc = q[0][j];
        const qp = q[1][j];
        const ip = i_prev[j];
        const d = c.ag0 * (qc - qp);
        const i_new = switch (cur_method) {
            .backward_euler => d,
            .trapezoidal => d - c.ag1 * ip,
            .gear_2 => d - c.ag2 * (qp - q[2][j]),
            else => d - g[j],
        };
        const volttol = lte.abstol + lte.reltol * @max(@abs(i_new), @abs(ip));
        const chargetol = lte.reltol * @max(@max(@abs(qc), @abs(qp)), lte.chgtol) / dts[0];
        const tol = @max(volttol, chargetol);
        var diff: [8]f64 = undefined;
        for (diff[0 .. p + 2], q[0 .. p + 2]) |*df, h| df.* = h[j];
        var deltmp: [7]f64 = undefined;
        @memcpy(deltmp[0 .. p + 1], dts[0 .. p + 1]);
        var k: usize = p;
        while (true) {
            for (0..k + 1) |i| diff[i] = (diff[i] - diff[i + 1]) / deltmp[i];
            if (k == 0) break;
            k -= 1;
            for (0..k + 1) |i| deltmp[i] = deltmp[i + 1] + dts[i];
        }
        const del = lte.trtol * tol / @max(lte.abstol, coeff * @abs(diff[0]));
        for (q[0 .. p + 2]) |h| poison += h[j] - h[j];
        poison += (ip - ip) + (i_new - i_new) + if (del == del) 0 else del;
        min_del = @min(min_del, del);
    }
    if (std.math.isNan(poison)) return std.math.nan(f64);
    return switch (p) {
        1 => min_del,
        2 => @sqrt(min_del),
        else => @exp(@log(min_del) / @as(f64, @floatFromInt(p))),
    };
}

/// The min over the states of del_j, before the order-2 root; NaN when any
/// entry it reads is NaN or inf.
fn minDel(comptime w: usize, comptime method: Method, comptime cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    const V = @Vector(w, f64);
    const dt: V = @splat(lte.dt);
    const dt1: V = @splat(lte.dt1);
    const dt2: V = @splat(lte.dt2);
    // cktterr.c's deltmp sums: d0+d1, d1+d2, then (d1+d2)+d0.
    const sum01: V = @splat(lte.dt + lte.dt1);
    const sum12: V = @splat(lte.dt1 + lte.dt2);
    const sum012: V = @splat(lte.dt + (lte.dt1 + lte.dt2));
    const av: V = @splat(c.ag0);
    const a2: V = @splat(c.ag2);
    const a1: V = @splat(c.ag1);
    const abstol: V = @splat(lte.abstol);
    const reltol: V = @splat(lte.reltol);
    const chgtol: V = @splat(lte.chgtol);
    const trtol: V = @splat(lte.trtol);
    const coeff: V = @splat(lteCoeff(method));
    var vmin: V = @splat(std.math.inf(f64));
    // NaN once any read entry is NaN or inf (x - x) or a del is 0/0: a
    // float @min drops NaN, which would accept the step at a growing dt.
    var poison: V = @splat(0);
    var i: usize = 0;
    while (i + w <= q[0].len) : (i += w) {
        const qc: V = q[0][i..][0..w].*;
        const qp: V = q[1][i..][0..w].*;
        const qp2: V = q[2][i..][0..w].*;
        const ip: V = i_prev[i..][0..w].*;
        const i_new = switch (cur_method) {
            .trapezoidal => av * (qc - qp) - a1 * ip,
            .gear_2 => av * (qc - qp) - a2 * (qp - qp2),
            .backward_euler => av * (qc - qp),
            else => comptime unreachable,
        };
        const volttol = abstol + reltol * @max(@abs(i_new), @abs(ip));
        const chargetol = reltol * @max(@max(@abs(qc), @abs(qp)), chgtol) / dt;
        const tol = @max(volttol, chargetol);
        poison += (qc - qc) + (qp - qp) + (qp2 - qp2) + (ip - ip);
        const f12 = (qp - qp2) / dt1;
        var dd = ((qc - qp) / dt - f12) / sum01;
        if (method != .backward_euler) {
            const qp3: V = q[3][i..][0..w].*;
            poison += qp3 - qp3;
            const f123 = (f12 - (qp2 - qp3) / dt2) / sum12;
            dd = (dd - f123) / sum012;
        }
        const del = trtol * tol / @max(abstol, coeff * @abs(dd));
        poison += @select(f64, del == del, @as(V, @splat(0)), del);
        vmin = @min(vmin, del);
    }
    if (std.math.isNan(@reduce(.Add, poison))) return std.math.nan(f64);
    const min_del = @reduce(.Min, vmin);
    if (comptime w == 1) return min_del;
    const tail: [4][]const f64 = .{ q[0][i..], q[1][i..], q[2][i..], q[3][i..] };
    const tail_del = minDel(1, method, cur_method, tail, i_prev[i..], c, lte);
    return if (std.math.isNan(tail_del)) tail_del else @min(min_del, tail_del);
}
