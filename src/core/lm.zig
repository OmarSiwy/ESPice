//! Bounded Levenberg-Marquardt least squares, the HSPICE optimizer
//! (`.model m OPT`, LEVEL=1) [SA Ch.27]. The caller owns evaluation: `Lm`
//! yields the parameter points it needs (`points`) and takes their residual
//! vectors back (`feed`), so a batch of finite-difference points can run in
//! parallel. The Jacobian is forward differences; bounds are handled by
//! clamping each step into the box and holding a parameter fixed while it
//! sits on a limit its gradient pushes it past.
const std = @import("std");
const dot = @import("numerics.zig").dot;

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
    /// Floor of |p| in the DIFSIZ, RELIN and GRAD scalings, so a parameter
    /// near zero still gets a usable step.
    parmin: f64 = 0.1,
    /// Converged when the norm of the residual-sum-of-squares gradient over
    /// the free parameters, each component scaled by max(|p|, parmin) so the
    /// test does not depend on the parameters' units, falls below this.
    grad: f64 = 1e-6,
    /// Stop when the Marquardt parameter exceeds this.
    max: f64 = 6e5,
    /// Bisection only (`bisect.zig`): an absolute window width that ends
    /// the search, overriding RELIN, RELOUT and ITROPT; 0 is unset.
    absin: f64 = 0,
    /// Bisection only: an absolute measure tolerance replacing RELOUT; 0 is unset.
    absout: f64 = 0,
};

/// Why the optimizer stopped; `running` until it has. `relin`, `relout`,
/// `grad`, `itropt` and `max` name the `Options` field whose test ended it;
/// `failed` is a point that could not be evaluated (or a non-finite
/// Jacobian entry).
pub const Status = enum(u8) { running, relin, relout, grad, itropt, max, failed };

/// One optimization run. All storage comes from the arena passed to `init`.
pub const Lm = struct {
    /// Parameters, at least 1.
    n: u32,
    /// Residuals per point.
    m: u32,
    opts: Options,
    /// The box every point stays in, where it has room for the step.
    lo: []const f64,
    hi: []const f64,
    /// Per-parameter finite-difference step; 0 selects the DIFSIZ rule.
    dels: []const f64,
    /// The accepted iterate, the result.
    x: []f64,
    /// Residuals at `x`; `rss` is their sum of squares.
    r: []f64,
    rss: f64 = std.math.inf(f64),
    /// Column-major m x n: `jac[j * m + i]` is d r_i / d x_j.
    jac: []f64,
    /// Gradient of the residual sum of squares, 2 Jᵀr.
    g: []f64,
    /// Scratch for the n x n damped normal equations, row-major.
    a: []f64,
    /// The last step solved for, before clamping.
    delta: []f64,
    /// Parameters not held on a limit at the last Jacobian.
    free: []bool,
    /// Pending points, n values each; `pending` of them.
    pts: []f64,
    /// Finite-difference step of each Jacobian point.
    h: []f64,
    pending: u32 = 1,
    phase: Phase = .start,
    /// The Marquardt parameter.
    lambda: f64,
    /// Accepted steps.
    iterations: u32 = 0,
    /// Points evaluated, Jacobian points included.
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
    /// Slices are copied into `arena`. Asserts at least one parameter, equal
    /// slice lengths, lo <= hi, and CUT > 1 (anything less never grows the
    /// Marquardt parameter past MAX, so a rejected step would retry forever).
    pub fn init(arena: std.mem.Allocator, x0: []const f64, lo: []const f64, hi: []const f64, dels: []const f64, m: u32, opts: Options) !Lm {
        const n: u32 = @intCast(x0.len);
        std.debug.assert(n > 0 and lo.len == n and hi.len == n and dels.len == n);
        std.debug.assert(opts.cut > 1);
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
    /// a NaN marks a point that could not be evaluated. Fails only when the
    /// arena cannot grow `history`. Asserts one residual vector per point.
    pub fn feed(s: *Lm, residuals: []const f64) !void {
        const n = s.n;
        const m = s.m;
        std.debug.assert(residuals.len == @as(usize, s.pending) * m);
        s.evaluations += s.pending;
        switch (s.phase) {
            .start => {
                const rss = dot(residuals, residuals);
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
                    s.g[j] = 2 * dot(s.jac[j * m ..][0..m], s.r);
                    // A parameter on a limit its descent direction points past stays put.
                    s.free[j] = !((s.x[j] <= s.lo[j] and s.g[j] > 0) or (s.x[j] >= s.hi[j] and s.g[j] < 0));
                }
                if (s.gradientNorm() < s.opts.grad) return s.stop(.grad);
                s.trialPoint();
            },
            .trial => {
                const rss = dot(residuals, residuals);
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
    /// reach inside its range. Asserts j < n.
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
    /// limit so the point stays in the box. A box narrower than the step
    /// gets the wider side's whole room instead; only a box of zero width
    /// (lo == hi) steps outside it.
    fn jacobianPoints(s: *Lm) void {
        const n = s.n;
        for (0..n) |j| {
            var h = if (s.dels[j] != 0) @abs(s.dels[j]) else s.opts.difsiz * @max(@abs(s.x[j]), s.opts.parmin);
            if (s.x[j] + h > s.hi[j]) {
                const up = s.hi[j] - s.x[j];
                const down = s.x[j] - s.lo[j];
                if (down >= h) h = -h else if (up >= down and up > 0) h = up else if (down > 0) h = -down;
            }
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
                    dot(s.jac[j * m ..][0..m], s.jac[k * m ..][0..m]);
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

test "every point asked for stays inside a box narrower than the step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // DELS = 1 on a box of width 1: neither x + 1 nor x - 1 fits, so the
    // step must shrink to the room the box has.
    var lm = try Lm.init(arena.allocator(), &.{ 0.5, 0.9 }, &.{ 0, 0 }, &.{ 1, 1 }, &.{ 1, 1 }, 2, .{ .itropt = 50 });
    var buf: [4]f64 = undefined;
    while (lm.points().len != 0) {
        const pts = lm.points();
        for (0..pts.len / 2) |p| {
            const x = pts[p * 2 ..][0..2];
            for (x) |v| try std.testing.expect(v >= 0 and v <= 1);
            buf[p * 2] = x[0] - 0.7;
            buf[p * 2 + 1] = x[1] - 0.2;
        }
        try lm.feed(buf[0 .. pts.len / 2 * 2]);
    }
    try std.testing.expect(lm.status != .failed and lm.status != .max);
    try std.testing.expectApproxEqAbs(0.7, lm.x[0], 1e-3);
    try std.testing.expectApproxEqAbs(0.2, lm.x[1], 1e-3);
}

test "no residuals is already optimal; an unevaluable start fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var none = try Lm.init(arena.allocator(), &.{1}, &.{0}, &.{2}, &.{0}, 0, .{});
    try none.feed(&.{});
    try std.testing.expectEqual(.relout, none.status);
    try std.testing.expectEqual(@as(usize, 0), none.points().len);
    var bad = try Lm.init(arena.allocator(), &.{1}, &.{0}, &.{2}, &.{0}, 1, .{});
    try bad.feed(&.{std.math.nan(f64)});
    try std.testing.expectEqual(.failed, bad.status);
    try std.testing.expectEqual(@as(usize, 0), bad.history.rss.items.len);
}

test "a step that never improves raises the Marquardt parameter past MAX" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Only the start itself scores well, so every trial is rejected.
    const F = struct {
        fn eval(_: @This(), x: []const f64, r: []f64) void {
            r[0] = if (x[0] == 1) 0.5 else 1;
        }
    };
    var lm = try Lm.init(arena.allocator(), &.{1}, &.{0}, &.{10}, &.{0}, 1, .{ .max = 1e3 });
    try solve(&lm, F{});
    try std.testing.expectEqual(.max, lm.status);
    try std.testing.expectEqual(@as(f64, 1), lm.x[0]);
    try std.testing.expect(lm.lambda > 1e3);
}

test cholesky {
    // Certificate: A x = b recomputed from the untouched A, on SPD
    // matrices A = BᵀB + I of every size up to 6.
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (0..7) |n| {
        var b_mat: [36]f64 = undefined;
        var a: [36]f64 = undefined;
        var rhs: [6]f64 = undefined;
        for (b_mat[0 .. n * n]) |*v| v.* = rand.float(f64) - 0.5;
        for (0..n) |i| for (0..n) |j| {
            var v: f64 = @floatFromInt(@intFromBool(i == j));
            for (0..n) |k| v += b_mat[k * n + i] * b_mat[k * n + j];
            a[i * n + j] = v;
        };
        for (rhs[0..n]) |*v| v.* = rand.float(f64) - 0.5;
        var work = a;
        var x = rhs;
        try std.testing.expect(cholesky(work[0 .. n * n], x[0..n], n));
        for (0..n) |i| {
            var ax: f64 = 0;
            for (0..n) |j| ax += a[i * n + j] * x[j];
            try std.testing.expectApproxEqAbs(rhs[i], ax, 1e-12);
        }
    }
    // Indefinite: eigenvalues 3 and -1.
    var indefinite = [_]f64{ 1, 2, 2, 1 };
    var b = [_]f64{ 1, 1 };
    try std.testing.expect(!cholesky(&indefinite, &b, 2));
}
