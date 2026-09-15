//! Scaled residual certificate (LAPACK LAWN 41) for `direct.Solver` on
//! generated matrices of controlled condition: seeded families → the ratio
//! ||A x - b||_inf / (||A||_inf ||x||_inf n eps) for `solve` and `solveT`.
//! The oracle is backward stability, so it holds at any condition number;
//! κ only makes the inputs hard.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const direct = @import("direct.zig");
const num = @import("core").numerics;

/// LAPACK's bar (LAWN 41 §6.5) for a backward-stable LU solve: Thomas
/// and BBD meet it.
const ratio_max = 30;
/// The general LU's bar: LAWN's 30 over the pivot threshold. Threshold
/// pivoting (τ = 1e-3, KLU's and ngspice's) admits multipliers up to 1/τ,
/// and the replay keeps the first factor's pivots on new values, so the
/// growth LAWN's bar assumes away is up to 1/τ per step. Measured over
/// 2000 seeded systems: full factor 1.6e3, replay 6.0e3 (backward error
/// near 1e-10, far under reltol). A lost pivot or a wrong solve misses by
/// 1/eps.
const ratio_max_pivoting = ratio_max / (direct.Params{}).pivot_tol;
/// Dense scratch bound: the families stay at or below this order.
const n_max = 72;

/// A dense row-major n x n matrix and its CSC copy. The CSC holds every
/// nonzero plus the full diagonal, as the MNA pattern merge guarantees.
const System = struct {
    n: u32,
    dense: []f64,
    col_ptr: []u32,
    row_idx: []u32,
    vals: []f64,

    fn initZero(gpa: Allocator, n: u32) !System {
        assert(n >= 1);
        assert(n <= n_max);
        const dense = try gpa.alloc(f64, @as(usize, n) * n);
        @memset(dense, 0);
        return .{ .n = n, .dense = dense, .col_ptr = &.{}, .row_idx = &.{}, .vals = &.{} };
    }

    fn at(self: System, i: usize, j: usize) *f64 {
        return &self.dense[i * self.n + j];
    }

    /// Builds the CSC from `dense`; call once, after the values are final.
    fn freeze(self: *System, gpa: Allocator) !void {
        assert(self.col_ptr.len == 0);
        const n = self.n;
        var nnz: u32 = 0;
        for (0..n) |i| for (0..n) |j| {
            nnz += @intFromBool(i == j or self.at(i, j).* != 0);
        };
        self.col_ptr = try gpa.alloc(u32, n + 1);
        self.row_idx = try gpa.alloc(u32, nnz);
        self.vals = try gpa.alloc(f64, nnz);
        var p: u32 = 0;
        self.col_ptr[0] = 0;
        for (0..n) |j| {
            for (0..n) |i| {
                const v = self.at(i, j).*;
                if (i != j and v == 0) continue;
                self.row_idx[p] = @intCast(i);
                self.vals[p] = v;
                p += 1;
            }
            self.col_ptr[j + 1] = p;
        }
        assert(p == nnz);
    }

    fn deinit(self: System, gpa: Allocator) void {
        gpa.free(self.dense);
        gpa.free(self.col_ptr);
        gpa.free(self.row_idx);
        gpa.free(self.vals);
    }

    /// The certificate, computed from `dense` (not from any factor), with
    /// the true infinity norms. `transpose` checks A^T x = b.
    fn ratio(self: System, x: []const f64, b: []const f64, comptime transpose: bool) f64 {
        const n = self.n;
        var rmax: f64 = 0;
        var anorm: f64 = 0;
        for (0..n) |i| {
            var r = b[i];
            var row_sum: f64 = 0;
            for (0..n) |j| {
                const a = if (transpose) self.at(j, i).* else self.at(i, j).*;
                r -= a * x[j];
                row_sum += @abs(a);
            }
            rmax = @max(rmax, @abs(r));
            anorm = @max(anorm, row_sum);
        }
        var xmax: f64 = 0;
        for (x[0..n]) |v| xmax = @max(xmax, @abs(v));
        assert(anorm > 0);
        assert(xmax > 0);
        const nf: f64 = @floatFromInt(n);
        return rmax / (anorm * xmax * nf * std.math.floatEps(f64));
    }
};

/// Singular values spaced geometrically over [1/kappa, 1], in random order.
fn sigma(r: std.Random, out: []f64, kappa: f64) void {
    assert(kappa >= 1);
    for (out, 0..) |*s, i| {
        const t = if (out.len == 1) 0 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(out.len - 1));
        s.* = std.math.pow(f64, kappa, -t);
    }
    r.shuffle(f64, out);
}

/// One Givens rotation through angle θ on rows (left) or columns (right)
/// p and q of the dense matrix; orthogonal, so the 2-norm condition holds.
fn rotate(sys: System, p: usize, q: usize, theta: f64, comptime left: bool) void {
    assert(p != q);
    const c = @cos(theta);
    const s = @sin(theta);
    for (0..sys.n) |k| {
        const a = if (left) sys.at(p, k) else sys.at(k, p);
        const b = if (left) sys.at(q, k) else sys.at(k, q);
        const va = a.*;
        const vb = b.*;
        a.* = c * va - s * vb;
        b.* = s * va + c * vb;
    }
}

/// 10^u with u uniform in [-decades, decades].
fn logUniform(r: std.Random, decades: f64) f64 {
    return std.math.pow(f64, 10, decades * (2 * r.float(f64) - 1));
}

/// D1 A D2 with log-uniform diagonal scalings: κ grows up to 10^(4 decades).
fn scaleBadly(r: std.Random, sys: System, decades: f64) void {
    var d2: [n_max]f64 = undefined;
    for (d2[0..sys.n]) |*d| d.* = logUniform(r, decades);
    for (0..sys.n) |i| {
        const d1 = logUniform(r, decades);
        for (0..sys.n) |j| sys.at(i, j).* *= d1 * d2[j];
    }
}

/// Q1 Σ Q2 over the index ranges in `groups` (each group rotates only
/// inside itself, so a block structure survives), κ_2 = `kappa` per group
/// exactly. `rotations` Givens per side per group keep it sparse.
fn givensGroups(r: std.Random, sys: System, groups: []const [2]u32, kappa: f64, rotations: u32) void {
    var s: [n_max]f64 = undefined;
    for (groups) |g| {
        const lo, const len = g;
        sigma(r, s[0..len], kappa);
        for (0..len) |i| sys.at(lo + i, lo + i).* = s[i];
        if (len < 2) continue;
        for (0..2 * rotations) |k| {
            const p = lo + r.uintLessThan(u32, len);
            var q = lo + r.uintLessThan(u32, len - 1);
            if (q >= p) q += 1;
            const theta = 2 * std.math.pi * r.float(f64);
            if (k % 2 == 0) rotate(sys, p, q, theta, true) else rotate(sys, p, q, theta, false);
        }
    }
}

/// Swaps rows inside each group by a random permutation: zero and tiny
/// diagonals appear, so the factor must pivot. κ is unchanged.
fn permuteRows(r: std.Random, sys: System, groups: []const [2]u32) void {
    for (groups) |g| {
        const lo, const len = g;
        var i: u32 = len;
        while (i > 1) {
            i -= 1;
            const k = r.uintAtMost(u32, i);
            if (k == i) continue;
            for (0..sys.n) |j| std.mem.swap(f64, sys.at(lo + i, j), sys.at(lo + k, j));
        }
    }
}

/// Factors through `direct.Solver`, solves both ways for two right-hand
/// sides, then perturbs every nonzero by up to 25% and factors again, which
/// replays the first factor's pivots (the LU falls back to a full factor
/// when its growth check refuses). Thomas keeps no pivots, so its second
/// pass would only leave the dominant family it is stable on (a perturbed
/// SPD ladder at κ 1e4 measured 105; Thomas has no growth check) and is
/// skipped. Returns the worst ratio of all passes. `null` when the solver reports a matrix singular, which the
/// caller allows only past κ = 1/eps. Fails unless `engine` picked the
/// pattern and solved both passes on it, or, when `demoted` is given, on
/// the general LU it demoted to, which sets `demoted` and ends the passes.
fn certify(gpa: Allocator, r: std.Random, sys: System, info: ?num.BbdInfo, engine: std.meta.Tag(direct.Engine), demoted: ?*bool) !?f64 {
    var solver = try direct.Solver.init(gpa, sys.n, sys.col_ptr, sys.row_idx, info, .{});
    defer solver.deinit();
    var b: [n_max]f64 = undefined;
    var x: [n_max]f64 = undefined;
    var worst: f64 = 0;
    const passes: u32 = if (engine == .tri) 1 else 2;
    for (0..passes) |pass| {
        if (pass == 1) perturb(r, sys);
        solver.factor(sys.vals, .{}) catch |err| {
            if (err == error.SingularMatrix) return null;
            return err;
        };
        const live = std.meta.activeTag(solver.engine);
        // Thomas hands a pivot threshold pivoting would leave to the LU (#45).
        if (demoted != null and live == .lu) demoted.?.* = true else if (!(engine == .tri and live == .lu)) try testing.expectEqual(engine, live);
        for (0..2) |_| {
            for (b[0..sys.n]) |*v| v.* = 2 * r.float(f64) - 1;
            solver.solve(b[0..sys.n], x[0..sys.n]);
            worst = @max(worst, sys.ratio(&x, &b, false));
            solver.solveT(b[0..sys.n], x[0..sys.n]);
            worst = @max(worst, sys.ratio(&x, &b, true));
        }
        // A demoted system's fresh LU factor is certified here; its replay
        // belongs to the general-sparse family.
        if (live != engine) break;
    }
    assert(worst >= 0);
    return worst;
}

/// Scales every nonzero by 1 + u, u uniform in [-0.25, 0.25], in both the
/// CSC values and the dense copy: same pattern, new values, as between two
/// Newton iterations.
fn perturb(r: std.Random, sys: System) void {
    for (0..sys.n) |j| for (sys.col_ptr[j]..sys.col_ptr[j + 1]) |p| {
        const f = 1 + 0.5 * (r.float(f64) - 0.5);
        sys.vals[p] *= f;
        sys.at(sys.row_idx[p], j).* = sys.vals[p];
    };
}

const kappas = [_]f64{ 1, 1e4, 1e8, 1e12, 1e15 };

test "scaled residual: general sparse, controlled κ, pivoting, bad scaling" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1a3141);
    const r = prng.random();
    var worst: f64 = 0;
    for (kappas) |kappa| for (0..24) |t| {
        const n = r.intRangeAtMost(u32, 4, 64);
        var sys = try System.initZero(gpa, n);
        defer sys.deinit(gpa);
        const whole = [_][2]u32{.{ 0, n }};
        givensGroups(r, sys, &whole, kappa, n / 2);
        if (t % 2 == 1) permuteRows(r, sys, &whole);
        if (t % 3 == 2) scaleBadly(r, sys, 6);
        try sys.freeze(gpa);
        const got = try certify(gpa, r, sys, null, .lu, null) orelse {
            try testing.expect(kappa >= 1e15);
            continue;
        };
        worst = @max(worst, got);
    };
    try testing.expect(worst <= ratio_max_pivoting);
}

test "scaled residual: tridiagonal Thomas on SPD ladders of exact κ" {
    // tridiag(-1, d, -1) has eigenvalues d - 2cos(kπ/(n+1)), so
    // λmin = 4c/(κ-1) with c = cos(π/(n+1)) gives κ_2 exactly. D1 T D2
    // keeps the unpivoted LU as stable as T's. Every third system is
    // instead uniform in [-1, 1], with no dominance for Thomas to lean on.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7417d1a6);
    const r = prng.random();
    var worst: f64 = 0;
    for (kappas[1..]) |kappa| for (0..12) |t| {
        const n = r.intRangeAtMost(u32, 3, 64);
        var sys = try System.initZero(gpa, n);
        defer sys.deinit(gpa);
        const c = @cos(std.math.pi / @as(f64, @floatFromInt(n + 1)));
        const d = 2 * c + 4 * c / (kappa - 1);
        const random = t % 3 == 2;
        for (0..n) |i| {
            sys.at(i, i).* = if (random) 2 * r.float(f64) - 1 else d;
            if (i + 1 < n) {
                sys.at(i, i + 1).* = if (random) 2 * r.float(f64) - 1 else -1;
                sys.at(i + 1, i).* = if (random) 2 * r.float(f64) - 1 else -1;
            }
        }
        if (t % 2 == 1) scaleBadly(r, sys, 6);
        try sys.freeze(gpa);
        const got = try certify(gpa, r, sys, null, .tri, null) orelse {
            try testing.expect(kappa >= 1e15);
            continue;
        };
        worst = @max(worst, got);
    };
    try testing.expect(worst <= ratio_max);
}

test "scaled residual: bordered block diagonal, block κ controlled" {
    // Eight blocks (the production `min_blocks`) of exact κ each, a
    // well-conditioned border and E/F couplings; the global κ is near the
    // blocks' but not exact. Rows permute inside blocks only, which keeps
    // the BBD pattern. Unrefined, the Schur reduction's ratio reached 16 at
    // block κ 1e8, 2.5e4 at 1e12 and 2.9e5 at 1e15 (flat LU <= 0.18); the
    // solver's refinement and growth demotion bring it under the bar (#136).
    // Up to block κ 1e8 BBD must stay the engine, except on a badly scaled
    // system: `Bbd.growth` compares entries, so scaling alone can raise it.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xbbd5eed);
    const r = prng.random();
    var worst: f64 = 0;
    var worst_lu: f64 = 0;
    for (kappas) |kappa| for (0..16) |t| {
        const nb = 8;
        const s = r.intRangeAtMost(u32, 2, 6);
        const ncpl = r.intRangeAtMost(u32, 1, 4);
        const n = 1 + nb * s + ncpl;
        var sys = try System.initZero(gpa, n);
        defer sys.deinit(gpa);
        var groups: [nb][2]u32 = undefined;
        var blocks: [nb]num.BbdBlock = undefined;
        for (&groups, &blocks, 0..) |*g, *blk, i| {
            const lo = 1 + @as(u32, @intCast(i)) * s;
            g.* = .{ lo, s };
            blk.* = .{ .start = lo, .size = s };
        }
        givensGroups(r, sys, &groups, kappa, s);
        if (t % 2 == 1) permuteRows(r, sys, &groups);
        const cs = 1 + nb * s;
        sys.at(0, 0).* = 1;
        for (0..ncpl) |i| sys.at(cs + i, cs + i).* = 2 + r.float(f64);
        for (groups) |g| for (0..g[1]) |k| {
            const cp = cs + r.uintLessThan(u32, ncpl);
            sys.at(g[0] + k, cp).* = 0.25 * (r.float(f64) - 0.5);
            sys.at(cp, g[0] + k).* = 0.25 * (r.float(f64) - 0.5);
        };
        if (t % 4 == 3) scaleBadly(r, sys, 6);
        try sys.freeze(gpa);
        const info: num.BbdInfo = .{ .blocks = &blocks, .coupling_start = cs, .coupling_size = ncpl };
        var demoted = false;
        const may_demote = kappa > 1e8 or t % 4 == 3;
        const got = try certify(gpa, r, sys, info, .bbd, if (may_demote) &demoted else null) orelse {
            try testing.expect(kappa >= 1e15);
            continue;
        };
        // A demoted system is the threshold-pivoting LU's, held to its bar.
        if (demoted) worst_lu = @max(worst_lu, got) else worst = @max(worst, got);
    };
    try testing.expect(worst <= ratio_max);
    try testing.expect(worst_lu <= ratio_max_pivoting);
}
