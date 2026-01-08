//! Numeric-equivalence gate for the shared-core hoist (FastVAF item 2.2).
//! Evaluates the SAME model compiled by the old and the new codegen over a
//! deterministic sweep of solver unknowns and compares the residuals BITWISE.
const std = @import("std");
const contract = @import("contract");
const A = @import("old");
const B = @import("new");

/// Plain-f64 instantiation of the device scalar interface (codegen's `R`).
const R = struct {
    v: f64,
    const T = @This();
    pub fn con(c: f64) T {
        return .{ .v = c };
    }
    pub fn val(a: T) f64 {
        return a.v;
    }
    pub fn ddxAt(_: T, _: usize) f64 {
        return 0.0;
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
    pub fn mul(a: T, b: T) T {
        return .{ .v = a.v * b.v };
    }
    pub fn div(a: T, b: T) T {
        return .{ .v = a.v / b.v };
    }
    pub fn scale(a: T, c: f64) T {
        return .{ .v = a.v * c };
    }
    pub fn addC(a: T, c: f64) T {
        return .{ .v = a.v + c };
    }
    pub fn exp(a: T) T {
        return .{ .v = @exp(a.v) };
    }
    pub fn log(a: T) T {
        return .{ .v = @log(a.v) };
    }
    pub fn sqrt(a: T) T {
        return .{ .v = @sqrt(a.v) };
    }
    pub fn sin(a: T) T {
        return .{ .v = @sin(a.v) };
    }
    pub fn cos(a: T) T {
        return .{ .v = @cos(a.v) };
    }
    pub fn tanh(a: T) T {
        return .{ .v = std.math.tanh(a.v) };
    }
    pub fn sinh(a: T) T {
        return .{ .v = std.math.sinh(a.v) };
    }
    pub fn cosh(a: T) T {
        return .{ .v = std.math.cosh(a.v) };
    }
    pub fn atan(a: T) T {
        return .{ .v = std.math.atan(a.v) };
    }
    pub fn abs(a: T) T {
        return .{ .v = @abs(a.v) };
    }
    pub fn minC(a: T, c: f64) T {
        return .{ .v = @min(a.v, c) };
    }
    pub fn maxC(a: T, c: f64) T {
        return .{ .v = @max(a.v, c) };
    }
    pub fn min(a: T, b: T) T {
        return .{ .v = @min(a.v, b.v) };
    }
    pub fn max(a: T, b: T) T {
        return .{ .v = @max(a.v, b.v) };
    }
    pub fn pow(a: T, c: f64) T {
        return .{ .v = std.math.pow(f64, a.v, c) };
    }
};

const na = contract.nU(A);
const nb = contract.nU(B);

pub fn main() void {
    comptime std.debug.assert(na == nb);

    var prng: std.Random.DefaultPrng = .init(0x5eed_1234);
    const rnd = prng.random();

    const ma: A.Model = .{};
    const mb: B.Model = .{};
    var ia: A.Instance = .{};
    var ib: B.Instance = .{};
    ia.dt = 1e-9;
    ib.dt = 1e-9;

    var mismatch: usize = 0;
    var checked: usize = 0;
    var worst: f64 = 0;

    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        var xa: [na]R = undefined;
        var xb: [nb]R = undefined;
        for (0..na) |i| {
            // Volts in a range a real solver actually visits.
            const v = (rnd.float(f64) - 0.5) * 4.0;
            xa[i] = .{ .v = v };
            xb[i] = .{ .v = v };
        }
        const ra = A.eval(R, xa, &ma, &ia, 0.0);
        const rb = B.eval(R, xb, &mb, &ib, 0.0);
        for (0..na) |i| {
            checked += 1;
            if (@as(u64, @bitCast(ra[i].v)) == @as(u64, @bitCast(rb[i].v))) continue;
            if (std.math.isNan(ra[i].v) and std.math.isNan(rb[i].v)) continue;
            mismatch += 1;
            if (mismatch < 4) std.debug.print("  eval trial {d} u={d} old={e} new={e}\n", .{ trial, i, ra[i].v, rb[i].v });
            const d = @abs(ra[i].v - rb[i].v) / @max(1e-300, @abs(ra[i].v));
            if (d > worst) worst = d;
        }
        if (@hasDecl(A, "q")) {
            const qa = A.q(R, xa, &ma, &ia, 0.0);
            const qb = B.q(R, xb, &mb, &ib, 0.0);
            for (0..na) |i| {
                checked += 1;
                if (@as(u64, @bitCast(qa[i].v)) == @as(u64, @bitCast(qb[i].v))) continue;
                if (std.math.isNan(qa[i].v) and std.math.isNan(qb[i].v)) continue;
                mismatch += 1;
                if (mismatch < 8) std.debug.print("  q trial {d} u={d} old={e} new={e}\n", .{ trial, i, qa[i].v, qb[i].v });
                const d = @abs(qa[i].v - qb[i].v) / @max(1e-300, @abs(qa[i].v));
                if (d > worst) worst = d;
            }
        }
    }
    std.debug.print("checked {d} residual entries, {d} mismatched, worst rel {e}\n", .{ checked, mismatch, worst });
    if (mismatch != 0) std.process.exit(1);
}
