const std = @import("std");

// ============================================================================
// Shared log-frequency sweep driver (ac / noise / stb / disto / sp)
// ============================================================================

pub fn logSweepCount(f_start: f64, f_stop: f64, points_per_decade: u16) u32 {
    const decades = @log10(f_stop) - @log10(f_start);
    return @as(u32, @intFromFloat(@ceil(decades * @as(f64, @floatFromInt(points_per_decade))))) + 1;
}

pub fn logSweepFreq(f_start: f64, f_stop: f64, n_points: u32, k: u32) f64 {
    const log_start = @log10(f_start);
    const frac = if (n_points > 1) @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points - 1)) else 0;
    return std.math.pow(f64, 10.0, log_start + frac * (@log10(f_stop) - log_start));
}

pub const LogSweep = struct {
    f_start: f64,
    f_stop: f64,
    n: u32,
    k: u32 = 0,

    pub fn next(self: *LogSweep) ?f64 {
        if (self.k >= self.n) return null;
        const f = logSweepFreq(self.f_start, self.f_stop, self.n, self.k);
        self.k += 1;
        return f;
    }
};

pub fn logSweep(f_start: f64, f_stop: f64, points_per_decade: u16) LogSweep {
    return .{ .f_start = f_start, .f_stop = f_stop, .n = logSweepCount(f_start, f_stop, points_per_decade) };
}

// ponytail: single Complex type for all frequency-domain analyses
// replaces 3 separate definitions in ac.zig, pz.zig, sp.zig

pub const Complex = struct {
    re: f64,
    im: f64,

    pub const zero = Complex{ .re = 0, .im = 0 };

    pub inline fn mag(self: Complex) f64 {
        return @sqrt(self.re * self.re + self.im * self.im);
    }

    pub inline fn magSq(self: Complex) f64 {
        return self.re * self.re + self.im * self.im;
    }

    pub inline fn phase(self: Complex) f64 {
        return std.math.atan2(self.im, self.re);
    }

    pub inline fn phaseDeg(self: Complex) f64 {
        return self.phase() * (180.0 / std.math.pi);
    }

    pub inline fn magDb(self: Complex) f64 {
        const m = self.mag();
        return if (m < 1e-30) -300.0 else 20.0 * @log10(m);
    }

    pub inline fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub inline fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub inline fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub inline fn div(a: Complex, b: Complex) Complex {
        const d = b.re * b.re + b.im * b.im;
        return .{
            .re = (a.re * b.re + a.im * b.im) / d,
            .im = (a.im * b.re - a.re * b.im) / d,
        };
    }

    pub inline fn scale(self: Complex, s: f64) Complex {
        return .{ .re = self.re * s, .im = self.im * s };
    }

    pub inline fn neg(self: Complex) Complex {
        return .{ .re = -self.re, .im = -self.im };
    }
};
