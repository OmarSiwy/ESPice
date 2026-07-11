//! Forward-mode AD scalar: value + derivative vector. Device physics is
//! written once against an opaque comptime S; one eval pass yields residual
//! and all partials. No finite differences.

const std = @import("std");

// ---------------------------------------------------------------------------
// Internal derivative-carrying scalar. Devices never name this type —
// physics is written against an opaque comptime S (con/add/sub/mul/...).
// Analyses never see it at all, only the planes it fills.
// ---------------------------------------------------------------------------
pub fn AdScalar(comptime N: usize) type {
    return struct {
        v: f64,
        d: V,

        const V = @Vector(N, f64);
        const Self = @This();

        inline fn splat(c: f64) V {
            return @splat(c);
        }
        pub fn con(c: f64) Self {
            return .{ .v = c, .d = splat(0) };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v, .d = a.d + b.d };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v - b.v, .d = a.d - b.d };
        }
        pub fn neg(a: Self) Self {
            return .{ .v = -a.v, .d = -a.d };
        }
        pub fn mul(a: Self, b: Self) Self {
            return .{ .v = a.v * b.v, .d = a.d * splat(b.v) + b.d * splat(a.v) };
        }
        pub fn div(a: Self, b: Self) Self {
            const inv_b = 1.0 / b.v;
            const quot = a.v * inv_b;
            return .{ .v = quot, .d = (a.d - b.d * splat(quot)) * splat(inv_b) };
        }
        pub fn scale(a: Self, c: f64) Self {
            return .{ .v = a.v * c, .d = a.d * splat(c) };
        }
        pub fn addC(a: Self, c: f64) Self {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn exp(a: Self) Self {
            const e = @exp(a.v);
            return .{ .v = e, .d = a.d * splat(e) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = @log(a.v), .d = a.d * splat(1.0 / a.v) };
        }
        pub fn sqrt(a: Self) Self {
            const s = @sqrt(a.v);
            return .{ .v = s, .d = a.d * splat(0.5 / s) };
        }
        pub fn sin(a: Self) Self {
            return .{ .v = @sin(a.v), .d = a.d * splat(@cos(a.v)) };
        }
        pub fn cos(a: Self) Self {
            return .{ .v = @cos(a.v), .d = a.d * splat(-@sin(a.v)) };
        }
        pub fn tanh(a: Self) Self {
            const th = std.math.tanh(a.v);
            return .{ .v = th, .d = a.d * splat(1.0 - th * th) };
        }
        pub fn abs(a: Self) Self {
            return if (a.v < 0) a.neg() else a;
        }
        /// Clamp-style guards: derivative flat past the bound.
        pub fn minC(a: Self, c: f64) Self {
            return if (a.v > c) con(c) else a;
        }
        pub fn maxC(a: Self, c: f64) Self {
            return if (a.v < c) con(c) else a;
        }
        /// a^c for constant exponent (a > 0).
        pub fn pow(a: Self, c: f64) Self {
            const p = std.math.pow(f64, a.v, c);
            return .{ .v = p, .d = a.d * splat(c * p / a.v) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = std.math.atan(a.v), .d = a.d * splat(1.0 / (1.0 + a.v * a.v)) };
        }
        pub fn sinh(a: Self) Self {
            return .{ .v = std.math.sinh(a.v), .d = a.d * splat(std.math.cosh(a.v)) };
        }
        pub fn cosh(a: Self) Self {
            return .{ .v = std.math.cosh(a.v), .d = a.d * splat(std.math.sinh(a.v)) };
        }
        /// Piecewise max/min of two scalars: derivative follows the winner.
        pub fn max(a: Self, b: Self) Self {
            return if (a.v >= b.v) a else b;
        }
        pub fn min(a: Self, b: Self) Self {
            return if (a.v <= b.v) a else b;
        }
        pub fn val(a: Self) f64 {
            return a.v;
        }
    };
}
