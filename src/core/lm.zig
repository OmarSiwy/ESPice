//! Bounded Levenberg-Marquardt least squares, the HSPICE optimizer
//! (`.model m OPT`, LEVEL=1) [SA Ch.27]. The caller owns evaluation: `Lm`
//! yields the parameter points it needs (`points`) and takes their residual
//! vectors back (`feed`), so a batch of finite-difference points can run in
//! parallel. The Jacobian is forward differences; bounds are handled by
//! clamping each step into the box and holding a parameter fixed while it
//! sits on a limit its gradient pushes it past.
const std = @import("std");

/// The optimizer knobs of an HSPICE `.model m OPT` card, with its defaults.
pub const Options = struct {
    /// Iteration limit.
    itropt: u32 = 20,
    /// Converged when every parameter moves by less than this, relative to
    /// max(|p|, parmin).
    relin: f64 = 1e-3,
    /// Converged when the residual sum of squares drops by less than this
    /// fraction in one iteration.
    relout: f64 = 1e-3,
    /// Initial Marquardt parameter: above 100 the step is steepest descent,
    /// below 1 Gauss-Newton.
    close: f64 = 1,
    /// Factor the Marquardt parameter is divided by after a successful step
    /// and multiplied by after a failed one.
    cut: f64 = 2,
    /// Finite-difference increment: difsiz * max(|p|, parmin).
    difsiz: f64 = 1e-3,
    parmin: f64 = 0.1,
    /// Converged when the norm of the residual-sum-of-squares gradient over
    /// the free parameters, each component scaled by max(|p|, parmin) so the
    /// test does not depend on the parameters' units, falls below this.
    grad: f64 = 1e-6,
    /// Stop when the Marquardt parameter exceeds this.
    max: f64 = 6e5,
};

/// Why the optimizer stopped; `running` until it has.
pub const Status = enum(u8) { running, relin, relout, grad, itropt, max, failed };

/// One optimization run. All storage comes from the arena passed to `init`.
pub const Lm = struct {
    n: u32,
    m: u32,
    opts: Options,
    lo: []const f64,
    hi: []const f64,
    /// Per-parameter finite-difference step; 0 selects the DIFSIZ rule.
    dels: []const f64,
    x: []f64,
    r: []f64,
    rss: f64 = std.math.inf(f64),
    /// Column-major m x n: `jac[j * m + i]` is d r_i / d x_j.
    jac: []f64,
    /// Gradient of the residual sum of squares, 2 Jᵀr.
    g: []f64,
    a: []f64,
    delta: []f64,
    free: []bool,
    /// Pending points, n values each; `pending` of them.
    pts: []f64,
    /// Finite-difference step of each Jacobian point.
    h: []f64,
    pending: u32 = 1,
    phase: Phase = .start,
    lambda: f64,
    iterations: u32 = 0,
    evaluations: u32 = 0,
    status: Status = .running,
    history: History = .{},
    arena: std.mem.Allocator,

    const Phase = enum(u8) { start, jacobian, trial };

    /// Accepted iterates, SoA: row 0 is the starting point.
    pub const History = struct {
        rss: std.ArrayList(f64) = .empty,
        lambda: std.ArrayList(f64) = .empty,
        evaluations: std.ArrayList(u32) = .empty,
        /// n values per row.
        x: std.ArrayList(f64) = .empty,
    };

    /// Starts at `x0` (clamped into [lo, hi]) with `m` residuals per point.
    /// Slices are copied into `arena`.
    pub fn init(arena: std.mem.Allocator, x0: []const f64, lo: []const f64, hi: []const f64, dels: []const f64, m: u32, opts: Options) !Lm {
        const n: u32 = @intCast(x0.len);
        std.debug.assert(lo.len == n and hi.len == n and dels.len == n);
        var s: Lm = .{
            .n = n,
            .m = m,
            .opts = opts,
            .lo = try arena.dupe(f64, lo),
            .hi = try arena.dupe(f64, hi),
            .dels = try arena.dupe(f64, dels),
            .x = try arena.alloc(f64, n),
            .r = try arena.alloc(f64, m),
            .jac = try arena.alloc(f64, @as(usize, m) * n),
            .g = try arena.alloc(f64, n),
            .a = try arena.alloc(f64, @as(usize, n) * n),
            .delta = try arena.alloc(f64, n),
            .free = try arena.alloc(bool, n),
            .pts = try arena.alloc(f64, @as(usize, n) * @max(n, 1)),
            .h = try arena.alloc(f64, n),
            .lambda = opts.close,
            .arena = arena,
        };
        for (s.x, x0, lo, hi) |*x, v, l, u| x.* = std.math.clamp(v, l, u);
        @memcpy(s.pts[0..n], s.x);
        @memset(s.g, 0);
        @memset(s.free, true);
        return s;
    }

    /// The points to evaluate next, `n` values each, row-major. Empty once
    /// `status` is no longer `running`.
    pub fn points(s: *const Lm) []const f64 {
        if (s.status != .running) return &.{};
        return s.pts[0 .. @as(usize, s.pending) * s.n];
    }

    /// Takes the residuals of `points()`, `m` per point in the same order;
    /// a NaN marks a point that could not be evaluated.
    pub fn feed(s: *Lm, residuals: []const f64) !void {
        const n = s.n;
        const m = s.m;
        std.debug.assert(residuals.len == @as(usize, s.pending) * m);
        s.evaluations += s.pending;
        switch (s.phase) {
            .start => {
                const rss = sumSquares(residuals);
                if (!std.math.isFinite(rss)) return s.stop(.failed);
                @memcpy(s.r, residuals);
                s.rss = rss;
                try s.record();
                if (rss == 0) return s.stop(.relout);
                s.jacobianPoints();
            },
            .jacobian => {
                for (0..n) |j| for (0..m) |i| {
                    const d = (residuals[j * m + i] - s.r[i]) / s.h[j];
                    if (!std.math.isFinite(d)) return s.stop(.failed);
                    s.jac[j * m + i] = d;
                };
                for (0..n) |j| {
                    s.g[j] = 2 * dotCol(s.jac[j * m ..][0..m], s.r);
                    // A parameter on a limit its descent direction points past stays put.
                    s.free[j] = !((s.x[j] <= s.lo[j] and s.g[j] > 0) or (s.x[j] >= s.hi[j] and s.g[j] < 0));
                }
                if (s.gradientNorm() < s.opts.grad) return s.stop(.grad);
                s.trialPoint();
            },
            .trial => {
                const rss = sumSquares(residuals);
                if (!(rss < s.rss)) {
                    s.lambda *= s.opts.cut;
                    if (s.lambda > s.opts.max) return s.stop(.max);
                    return s.trialPoint();
                }
                var rel_in: f64 = 0;
                for (s.x, s.pts[0..n]) |x, t| rel_in = @max(rel_in, @abs(t - x) / @max(@abs(x), s.opts.parmin));
                const rel_out = (s.rss - rss) / s.rss;
                @memcpy(s.x, s.pts[0..n]);
                @memcpy(s.r, residuals);
                s.rss = rss;
                s.lambda /= s.opts.cut;
                s.iterations += 1;
                try s.record();
                if (rel_in < s.opts.relin) return s.stop(.relin);
                if (rss == 0 or rel_out < s.opts.relout) return s.stop(.relout);
                if (s.iterations >= s.opts.itropt) return s.stop(.itropt);
                s.jacobianPoints();
            },
        }
    }

    /// The limit parameter `j` ended on while the last gradient still
    /// pulled it past (-1 lower, +1 upper), else 0: its goals are out of
    /// reach inside its range.
    pub fn pinned(s: *const Lm, j: usize) i2 {
        if (s.x[j] <= s.lo[j] and s.g[j] > 0) return -1;
        if (s.x[j] >= s.hi[j] and s.g[j] < 0) return 1;
        return 0;
    }

    /// Norm of the scaled residual-sum-of-squares gradient over the free
    /// parameters at the last Jacobian (`Options.grad`).
    pub fn gradientNorm(s: *const Lm) f64 {
        var norm: f64 = 0;
        for (s.g, s.x, s.free) |g, x, free| if (free) {
            const v = g * @max(@abs(x), s.opts.parmin);
            norm += v * v;
        };
        return @sqrt(norm);
    }

    fn stop(s: *Lm, status: Status) void {
        s.status = status;
        s.pending = 0;
    }

    fn record(s: *Lm) !void {
        try s.history.rss.append(s.arena, s.rss);
        try s.history.lambda.append(s.arena, s.lambda);
        try s.history.evaluations.append(s.arena, s.evaluations);
        try s.history.x.appendSlice(s.arena, s.x);
    }

    /// One point per parameter, stepped forward, or backward from an upper
    /// limit so the point stays in the box.
    fn jacobianPoints(s: *Lm) void {
        const n = s.n;
        for (0..n) |j| {
            var h = if (s.dels[j] != 0) @abs(s.dels[j]) else s.opts.difsiz * @max(@abs(s.x[j]), s.opts.parmin);
            if (s.x[j] + h > s.hi[j]) h = -h;
            s.h[j] = h;
            const p = s.pts[j * n ..][0..n];
            @memcpy(p, s.x);
            p[j] += h;
        }
        s.pending = n;
        s.phase = .jacobian;
    }

    /// Solves (JᵀJ + λ D) δ = -g/2 over the free parameters, D the diagonal
    /// of JᵀJ (Marquardt scaling), and queues x + δ clamped into the box.
    fn trialPoint(s: *Lm) void {
        const n = s.n;
        const m = s.m;
        while (true) {
            for (0..n) |j| for (0..n) |k| {
                s.a[j * n + k] = if (!s.free[j] or !s.free[k])
                    @floatFromInt(@intFromBool(j == k))
                else
                    dotCol(s.jac[j * m ..][0..m], s.jac[k * m ..][0..m]);
            };
            for (0..n) |j| {
                const d = s.a[j * n + j];
                s.a[j * n + j] = d + s.lambda * (if (d > 0) d else 1);
                s.delta[j] = if (s.free[j]) -0.5 * s.g[j] else 0;
            }
            if (cholesky(s.a, s.delta, n)) break;
            s.lambda *= s.opts.cut;
            if (s.lambda > s.opts.max) return s.stop(.max);
        }
        const t = s.pts[0..n];
        var moved = false;
        for (t, s.x, s.delta, s.lo, s.hi) |*p, x, d, l, u| {
            p.* = std.math.clamp(x + d, l, u);
            moved = moved or p.* != x;
        }
        if (!moved) return s.stop(.relin);
        s.pending = 1;
        s.phase = .trial;
    }
};

fn sumSquares(v: []const f64) f64 {
    var sum: f64 = 0;
    for (v) |x| sum += x * x;
    return sum;
}

fn dotCol(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += x * y;
    return sum;
}

/// Solves the symmetric positive definite `a` (n x n, row-major, destroyed)
/// against `b` in place. False when `a` is not positive definite.
fn cholesky(a: []f64, b: []f64, n: usize) bool {
    for (0..n) |j| {
        var d = a[j * n + j];
        for (0..j) |k| d -= a[j * n + k] * a[j * n + k];
        if (!(d > 0)) return false;
        d = @sqrt(d);
        a[j * n + j] = d;
        for (j + 1..n) |i| {
            var v = a[i * n + j];
            for (0..j) |k| v -= a[i * n + k] * a[j * n + k];
            a[i * n + j] = v / d;
        }
    }
    for (0..n) |i| {
        var v = b[i];
        for (0..i) |k| v -= a[i * n + k] * b[k];
        b[i] = v / a[i * n + i];
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var v = b[i];
        for (i + 1..n) |k| v -= a[k * n + i] * b[k];
        b[i] = v / a[i * n + i];
    }
    return true;
}

/// Runs `lm` to completion against `f`, a test oracle.
fn solve(lm: *Lm, f: anytype) !void {
    var buf: [64]f64 = undefined;
    while (lm.points().len != 0) {
        const pts = lm.points();
        const count = pts.len / lm.n;
        for (0..count) |p| f.eval(pts[p * lm.n ..][0..lm.n], buf[p * lm.m ..][0..lm.m]);
        try lm.feed(buf[0 .. count * lm.m]);
    }
}

test "a divider sized to its target converges to the exact resistance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // v = 5 rx / (1k + rx), goal 2 V: rx = 666.67 ohm.
    const F = struct {
        fn eval(_: @This(), x: []const f64, r: []f64) void {
            r[0] = (5 * x[0] / (1e3 + x[0]) - 2) / 2;
        }
    };
    var lm = try Lm.init(arena.allocator(), &.{1e3}, &.{100}, &.{1e4}, &.{0}, 1, .{});
    try solve(&lm, F{});
    try std.testing.expect(lm.status != .failed and lm.status != .max);
    try std.testing.expectApproxEqRel(2e3 / 3.0, lm.x[0], 1e-4);
}

test "Rosenbrock's valley: two parameters reach the known optimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const F = struct {
        fn eval(_: @This(), x: []const f64, r: []f64) void {
            r[0] = 10 * (x[1] - x[0] * x[0]);
            r[1] = 1 - x[0];
        }
    };
    var lm = try Lm.init(arena.allocator(), &.{ -1.2, 1 }, &.{ -5, -5 }, &.{ 5, 5 }, &.{ 0, 0 }, 2, .{ .itropt = 200, .relin = 1e-9, .relout = 1e-12, .grad = 1e-12, .difsiz = 1e-7 });
    try solve(&lm, F{});
    try std.testing.expectApproxEqAbs(1, lm.x[0], 1e-4);
    try std.testing.expectApproxEqAbs(1, lm.x[1], 1e-4);
}

test "an unreachable goal stops on the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // v = 5 rx / (1k + rx) cannot reach 4.9 V with rx <= 10k.
    const F = struct {
        fn eval(_: @This(), x: []const f64, r: []f64) void {
            r[0] = (5 * x[0] / (1e3 + x[0]) - 4.9) / 4.9;
        }
    };
    var lm = try Lm.init(arena.allocator(), &.{1e3}, &.{100}, &.{1e4}, &.{0}, 1, .{});
    try solve(&lm, F{});
    try std.testing.expectEqual(1e4, lm.x[0]);
    try std.testing.expectEqual(1, lm.pinned(0));
    try std.testing.expect(lm.status != .running);
}
