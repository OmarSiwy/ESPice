//! HSPICE bisection optimization (`.model m OPT METHOD=BISECTION|PASSFAIL`,
//! or LEVEL=2|3) [SA Ch.19 "Using Bisection"; CR .MODEL]: a binary search
//! of one parameter's range for the value where its RESULTS card turns from
//! fail to pass. Like `lm.Lm`, the caller owns evaluation: `points` hands
//! out the values to test and `feed` takes their goal errors back. The two
//! limits go out as one batch, then one midpoint per iteration.
const std = @import("std");
const assert = std.debug.assert;
const Options = @import("lm.zig").Options;

/// The `.model OPT` search: LEVEL=1 (Levenberg-Marquardt), LEVEL=2 or
/// METHOD=BISECTION, LEVEL=3 or METHOD=PASSFAIL.
pub const Method = enum(u8) { lm, bisection, passfail };

/// Why the search stopped; `running` until it has.
pub const Status = enum(u8) {
    running,
    /// RELIN (or ABSIN) and, for BISECTION, RELOUT (or ABSOUT) hold.
    converged,
    itropt,
    /// Both limits pass or both fail, so they do not bracket the target.
    bounds,
    /// A BISECTION test could not be simulated or measured.
    failed,
};

/// One search. `x` is the last passing value, the result. All storage
/// comes from the arena passed to `init`.
pub const Bisect = struct {
    /// `bisection` or `passfail`, never `lm`.
    method: Method,
    opts: Options,
    /// Goal error to absolute measure units (ABSOUT): max(|GOAL|, MINVAL) / WEIGHT.
    scale: f64,
    /// The window, narrowed to the last pass and the last fail.
    lo: f64,
    hi: f64,
    /// Half the initial window's width, the RELIN reference.
    range: f64,
    /// Every tested value is a multiple of `grid` (#95); 0 is continuous.
    grid: f64,
    /// Which limit passes, once both have been tested.
    pass_hi: bool = false,
    /// The last passing value; `lo` until a limit passes.
    x: f64,
    /// Goal error at `x`.
    r: f64 = std.math.nan(f64),
    /// The values `points` hands out, `pending` of them.
    pts: [2]f64,
    pending: u8 = 2,
    /// Midpoints tested, not counting the two limits.
    iterations: u32 = 0,
    /// Every value tested, the limits included.
    evaluations: u32 = 0,
    status: Status = .running,
    history: History = .{},
    arena: std.mem.Allocator,

    /// One row per midpoint test, SoA: the window it was taken from, the
    /// value tested and its goal error.
    pub const History = struct {
        lo: std.ArrayList(f64) = .empty,
        hi: std.ArrayList(f64) = .empty,
        x: std.ArrayList(f64) = .empty,
        r: std.ArrayList(f64) = .empty,
    };

    /// Searches [lo, hi], rounded inward onto `grid` when it is positive;
    /// the manual ignores the initial value. `scale` converts a goal error
    /// to measure units for ABSOUT. Asserts that the method is not `lm` and
    /// that a (grid) point lies inside lo <= hi.
    pub fn init(arena: std.mem.Allocator, method: Method, lo_in: f64, hi_in: f64, grid: f64, scale: f64, opts: Options) Bisect {
        const lo = if (grid > 0) @ceil(lo_in / grid) * grid else lo_in;
        const hi = if (grid > 0) @floor(hi_in / grid) * grid else hi_in;
        assert(method != .lm);
        assert(lo <= hi);
        return .{ .method = method, .opts = opts, .scale = scale, .lo = lo, .hi = hi, .range = halfWidth(lo, hi), .grid = grid, .x = lo, .pts = .{ lo, hi }, .arena = arena };
    }

    /// The values to test next. Empty once `status` is no longer `running`.
    pub fn points(s: *const Bisect) []const f64 {
        assert(s.pending <= s.pts.len);
        return if (s.status == .running) s.pts[0..s.pending] else &.{};
    }

    /// Takes the goal errors of `points()` in order; NaN marks a test whose
    /// measure found no value or whose simulation failed. Fails only when
    /// the arena cannot grow `history`. Asserts that the search is still
    /// running and that there is one error per point.
    pub fn feed(s: *Bisect, residuals: []const f64) !void {
        assert(s.status == .running);
        assert(residuals.len == s.pending);
        s.evaluations += s.pending;
        if (s.method == .bisection) for (residuals) |r| if (std.math.isNan(r)) return s.stop(.failed);
        if (s.pending == 2) {
            const lo_pass = s.passes(residuals[0]);
            s.pass_hi = s.passes(residuals[1]);
            if (lo_pass == s.pass_hi) return s.stop(.bounds);
            s.x = if (s.pass_hi) s.hi else s.lo;
            s.r = residuals[@intFromBool(s.pass_hi)];
        } else {
            const t = s.pts[0];
            const r = residuals[0];
            try s.history.lo.append(s.arena, s.lo);
            try s.history.hi.append(s.arena, s.hi);
            try s.history.x.append(s.arena, t);
            try s.history.r.append(s.arena, r);
            s.iterations += 1;
            // The passing side of the window moves to a pass, the other to a fail.
            if (s.passes(r) == s.pass_hi) s.hi = t else s.lo = t;
            if (s.passes(r)) {
                s.x = t;
                s.r = r;
            }
            if (s.converged(r)) return s.stop(.converged);
            if (s.opts.absin == 0 and s.iterations >= s.opts.itropt) return s.stop(.itropt);
        }
        assert(s.lo <= s.hi);
        assert(s.x == s.lo or s.x == s.hi);
        s.pts[0] = s.mid();
        s.pending = 1;
    }

    /// The window's midpoint; on a grid, the grid point at or below the
    /// middle grid index, so a one-step window's midpoint is `lo`.
    fn mid(s: *const Bisect) f64 {
        if (s.grid == 0) return s.lo + halfWidth(s.lo, s.hi);
        const a = @round(s.lo / s.grid);
        const b = @round(s.hi / s.grid);
        return (a + @floor((b - a) / 2)) * s.grid;
    }

    /// (hi - lo) / 2 without the overflow of hi - lo: [-1.5e308, 1.5e308]
    /// has a finite midpoint.
    fn halfWidth(lo: f64, hi: f64) f64 {
        return hi / 2 - lo / 2;
    }

    /// BISECTION passes when the measure exceeds its goal; PASSFAIL when
    /// the measure has a value at all [CR .MODEL METHOD].
    fn passes(s: *const Bisect, r: f64) bool {
        return if (s.method == .bisection) r > 0 else !std.math.isNan(r);
    }

    /// The window after a test is the step between successive test values
    /// [SA Ch.19 "Using RELOUT and RELIN"]: ABSIN bounds it absolutely and
    /// overrides the rest; otherwise RELIN bounds it relative to the initial
    /// window, and BISECTION also needs the latest error within RELOUT (or,
    /// when given, within ABSOUT in measure units).
    /// A window whose midpoint rounds onto one of its ends is as narrow as
    /// f64 makes it, so it meets every window tolerance; ABSIN, which also
    /// lifts ITROPT, would otherwise never stop below one ulp.
    fn converged(s: *const Bisect, r: f64) bool {
        // Half-widths throughout: hi - lo overflows near the f64 range.
        const half = halfWidth(s.lo, s.hi);
        assert(half >= 0);
        const middle = s.mid();
        const resolved = middle == s.lo or middle == s.hi;
        // A one-step grid window cannot narrow further.
        if (s.grid > 0 and resolved) return true;
        if (s.opts.absin > 0) return half <= s.opts.absin / 2 or resolved;
        if (half > s.opts.relin * s.range and !resolved) return false;
        if (s.method == .passfail) return true;
        return if (s.opts.absout > 0) @abs(r * s.scale) < s.opts.absout else @abs(r) < s.opts.relout;
    }

    fn stop(s: *Bisect, status: Status) void {
        assert(status != .running);
        s.status = status;
        s.pending = 0;
    }
};

/// Runs `s` to completion against `f`, a test oracle.
fn solve(s: *Bisect, f: anytype) !void {
    var buf: [2]f64 = undefined;
    // Terminates: every feed past the limits halves the window, and a
    // window f64 cannot halve further converges.
    while (s.points().len != 0) {
        const pts = s.points();
        for (pts, buf[0..pts.len]) |x, *r| r.* = f.eval(x);
        try s.feed(buf[0..pts.len]);
    }
}

test "bisection finds a monotone goal crossing from the passing side" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // v = 5 rx / (1k + rx) exceeds 2 V above rx = 2k/3, so hi passes.
    const F = struct {
        fn eval(_: @This(), x: f64) f64 {
            return (5 * x / (1e3 + x) - 2) / 2;
        }
    };
    var s = Bisect.init(arena.allocator(), .bisection, 100, 1e4, 0, 1, .{ .relin = 1e-6, .relout = 1e-4, .itropt = 100 });
    try solve(&s, F{});
    try std.testing.expectEqual(.converged, s.status);
    try std.testing.expect(s.x >= 2e3 / 3.0 and s.x - 2e3 / 3.0 <= 1e-6 * 9900);
    try std.testing.expect(s.r > 0);
}

test "pass/fail keeps the last value with a result; bad limits are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A measure that has a value only below 3.
    const F = struct {
        fn eval(_: @This(), x: f64) f64 {
            return if (x < 3) 1 else std.math.nan(f64);
        }
    };
    var s = Bisect.init(arena.allocator(), .passfail, 0, 10, 0, 1, .{});
    try solve(&s, F{});
    try std.testing.expectEqual(.converged, s.status);
    try std.testing.expect(s.x < 3 and 3 - s.x <= 1e-3 * 10);
    try std.testing.expect(!s.pass_hi);
    var both = Bisect.init(arena.allocator(), .passfail, 0, 2, 0, 1, .{});
    try solve(&both, F{});
    try std.testing.expectEqual(.bounds, both.status);
}

test "an ABSIN below one ulp of the window still ends the search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const F = struct {
        fn eval(_: @This(), x: f64) f64 {
            return x - 700;
        }
    };
    // 1e-300 is far below an ulp of 700, so only the f64 floor can stop it.
    var s = Bisect.init(arena.allocator(), .bisection, 0, 1e3, 0, 1, .{ .absin = 1e-300 });
    try solve(&s, F{});
    try std.testing.expectEqual(.converged, s.status);
    try std.testing.expect(s.iterations < 80);
    try std.testing.expect(s.x >= 700 and s.x - 700 <= 2 * std.math.floatEps(f64) * 700);
}

test "ABSIN ends the window absolutely, and ITROPT caps a RELIN search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const F = struct {
        fn eval(_: @This(), x: f64) f64 {
            return 3 - x;
        }
    };
    // lo passes here, so the search narrows from below.
    var abs = Bisect.init(arena.allocator(), .bisection, 0, 8, 0, 1, .{ .absin = 0.5, .itropt = 1 });
    try solve(&abs, F{});
    try std.testing.expectEqual(.converged, abs.status);
    try std.testing.expect(!abs.pass_hi);
    try std.testing.expectEqual(@as(u32, 4), abs.iterations);
    try std.testing.expect(abs.hi - abs.lo <= 0.5 and abs.x <= 3);
    var capped = Bisect.init(arena.allocator(), .bisection, 0, 8, 0, 1, .{ .relin = 1e-9, .itropt = 3 });
    try solve(&capped, F{});
    try std.testing.expectEqual(.itropt, capped.status);
    try std.testing.expectEqual(@as(u32, 3), capped.iterations);
    try std.testing.expectEqual(@as(u32, 5), capped.evaluations);
    try std.testing.expectEqual(@as(usize, 3), capped.history.x.items.len);
    try std.testing.expectEqualSlices(f64, &.{ 4, 2, 3 }, capped.history.x.items);
}

test "a BISECTION test that cannot be measured fails the search; equal limits do not bracket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const F = struct {
        fn eval(_: @This(), x: f64) f64 {
            return if (x > 5) std.math.nan(f64) else x - 1;
        }
    };
    var s = Bisect.init(arena.allocator(), .bisection, 0, 10, 0, 1, .{});
    try solve(&s, F{});
    try std.testing.expectEqual(.failed, s.status);
    try std.testing.expectEqual(@as(usize, 0), s.points().len);
    var point = Bisect.init(arena.allocator(), .bisection, 2, 2, 0, 1, .{});
    try solve(&point, F{});
    try std.testing.expectEqual(.bounds, point.status);
}

test "the midpoint of a window near the f64 range stays inside the window" {
    // hi - lo overflows here; the halves do not (#30).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Bisect.init(arena.allocator(), .bisection, -1.5e308, 1.5e308, 0, 1, .{});
    try s.feed(&.{ -1, 1 });
    const mid = s.points()[0];
    try std.testing.expect(std.math.isFinite(mid) and mid > -1.5e308 and mid < 1.5e308);
    try std.testing.expect(std.math.isFinite(s.range));
}

test "a gridded bisection tests only grid values and stops on a one-step window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Passes above 666.67; on a 100 grid inside [150, 9999] the last passing
    // value is 700 (#95).
    const F = struct {
        fn eval(_: @This(), x: f64) f64 {
            return x - 2e3 / 3.0;
        }
    };
    var s = Bisect.init(arena.allocator(), .bisection, 150, 9999, 100, 1, .{ .relin = 1e-9, .relout = 1e-12, .itropt = 100 });
    try std.testing.expectEqual(@as(f64, 200), s.points()[0]);
    try std.testing.expectEqual(@as(f64, 9900), s.points()[1]);
    while (s.points().len != 0) {
        const pts = s.points();
        var r: [2]f64 = undefined;
        for (pts, 0..) |x, k| {
            try std.testing.expectEqual(@round(x / 100), x / 100);
            r[k] = F.eval(.{}, x);
        }
        try s.feed(r[0..pts.len]);
    }
    try std.testing.expectEqual(.converged, s.status);
    try std.testing.expectEqual(@as(f64, 700), s.x);
    try std.testing.expectEqual(@as(f64, 100), s.hi - s.lo);
}

test "ABSOUT holds the latest error in measure units, RELOUT the goal error itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const F = struct {
        fn eval(_: @This(), x: f64) f64 {
            return (x - 1.05) / 10;
        }
    };
    // `scale` 10 turns the goal error back into measure units, so ABSOUT
    // 0.01 needs a test within 1e-2 of 1.05, while RELOUT 0.01 accepts 1.
    var abs = Bisect.init(arena.allocator(), .bisection, 0, 4, 0, 10, .{ .relin = 1, .absout = 0.01, .itropt = 100 });
    try solve(&abs, F{});
    try std.testing.expectEqual(.converged, abs.status);
    try std.testing.expectEqual(@as(u32, 8), abs.iterations);
    try std.testing.expect(@abs(abs.history.r.items[7] * 10) < 0.01);
    var rel = Bisect.init(arena.allocator(), .bisection, 0, 4, 0, 10, .{ .relin = 1, .relout = 0.01, .itropt = 100 });
    try solve(&rel, F{});
    try std.testing.expectEqual(.converged, rel.status);
    try std.testing.expectEqual(@as(u32, 2), rel.iterations);
}
