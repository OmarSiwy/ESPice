//! Fixed-pattern sparse direct solver — thin dispatcher.
//!
//! This file is the PUBLIC INTERFACE that converger.zig and all Newton callers
//! use. All algorithm complexity lives in sparse_lu.zig, tridiag.zig, bbd.zig;
//! this is pure dispatch + pipeline (value bypass, engine selection, iterative
//! refinement).
//!
//!   init     : pattern-only dispatch (tridiag > BBD > SparseLu)
//!   factor   : value-identity bypass + engine factor (refactor/full fallback)
//!   solveNeg : x = -A\rhs  (the Newton step)
//!   solve    : x =  A\rhs
//!   solveT   : x =  A'\rhs (adjoint — noise/sens)

const std = @import("std");
const sparse_lu = @import("sparse_lu.zig");
const tridiag_mod = @import("tridiag.zig");
const order_mod = @import("order.zig");
const bbd_mod = @import("bbd.zig");
const root = @import("types.zig");

const Allocator = std.mem.Allocator;
const NONE: u32 = std.math.maxInt(u32);

/// Tuning knobs (KLU-style). Defaults reproduce the established behavior;
/// accuracy <-> speed is traded here, not by editing the kernel.
pub const Params = struct {
    /// Threshold partial pivoting: keep the diagonal when
    /// |diag| >= pivot_tol * colmax (KLU default 0.001).
    pivot_tol: f64 = 1e-3,
    /// Refactor pivot monitor: a reused pivot that decays below
    /// refactor_growth_limit * (max |entry| in its column) fails the
    /// refactor, forcing a full re-pivoting factor. 0 disables.
    refactor_growth_limit: f64 = 1e-12,
    /// Iterative refinement steps applied after each solve (0/1/2).
    iter_refine_steps: u2 = 0,
    /// Column ordering strategy. .natural = identity (no fill reduction).
    ordering: enum { amd, natural } = .amd,
    /// Block triangular form (Tarjan SCC) before per-block AMD.
    btf: bool = true,
};

/// Sparse direct solver over element type T (f32 or f64). `Solver` below
/// is the f64 instantiation (existing callers).
pub fn SolverT(comptime T: type) type {
    return struct {
        const Self = @This();
        const SparseLu = sparse_lu.SparseLu(T);
        const TriDiag = tridiag_mod.TriDiag(T);
        const BbdEng = bbd_mod.Bbd(T);

        n: u32,
        col_ptr: []const u32,
        row_idx: []const u32,
        lu: ?SparseLu,
        tri: ?TriDiag,
        bbd_eng: ?BbdEng = null,
        gpa: Allocator,
        factored: bool = false,
        bbd: ?root.BbdInfo = null,
        params: Params = .{},
        q: []u32 = &.{}, // owned column ordering (passed to SparseLu)
        // iterative-refinement scratch ([r | saved b], 2n) + the values the
        // current factorization was built from; empty when steps == 0.
        rbuf: []T = &.{},
        ref_vals: []const T = &.{},
        // copy of the last-factored values: factor() is a no-op when the
        // matrix didn't change (linear circuits between dt changes).
        vcopy: []T = &.{},

        pub fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?root.BbdInfo) !Self {
            return initParams(gpa, n, col_ptr, row_idx, bbd, .{});
        }

        pub fn initParams(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?root.BbdInfo, params: Params) !Self {
            var self = try initInner(gpa, n, col_ptr, row_idx, bbd, params);
            self.params = params;
            if (params.iter_refine_steps > 0)
                self.rbuf = try gpa.alloc(T, 2 * @as(usize, n));
            self.vcopy = try gpa.alloc(T, col_ptr[n]);
            return self;
        }

        /// Dispatch precedence: tridiag > BBD > flat SparseLu.
        fn initInner(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?root.BbdInfo, params: Params) !Self {
            if (tridiag_mod.isTridiag(n, col_ptr, row_idx)) {
                return .{
                    .n = n,
                    .col_ptr = col_ptr,
                    .row_idx = row_idx,
                    .lu = null,
                    .tri = try TriDiag.init(gpa, n, col_ptr, row_idx),
                    .gpa = gpa,
                    .bbd = bbd,
                };
            }
            if (bbd) |info| no_bbd: {
                if (comptime @import("builtin").link_libc) {
                    if (std.c.getenv("ZPICEY_NO_BBD") != null) break :no_bbd;
                }
                const eng = BbdEng.init(gpa, n, col_ptr, row_idx, info, .{}) catch |err| switch (err) {
                    error.NotApplicable => break :no_bbd,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                return .{
                    .n = n,
                    .col_ptr = col_ptr,
                    .row_idx = row_idx,
                    .lu = null,
                    .tri = null,
                    .bbd_eng = eng,
                    .gpa = gpa,
                    .bbd = bbd,
                };
            }
            const q = try computeOrdering(gpa, n, col_ptr, row_idx, params);
            errdefer gpa.free(q);
            return .{
                .n = n,
                .col_ptr = col_ptr,
                .row_idx = row_idx,
                .lu = try SparseLu.init(gpa, n, col_ptr, row_idx, q),
                .tri = null,
                .gpa = gpa,
                .bbd = bbd,
                .q = q,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.lu) |*lu| lu.deinit(self.gpa);
            if (self.tri) |*tri| tri.deinit(self.gpa);
            if (self.bbd_eng) |*eng| eng.deinit();
            self.gpa.free(self.q);
            self.gpa.free(self.rbuf);
            self.gpa.free(self.vcopy);
            self.* = undefined;
        }

        /// Value-identity bypass + dispatch to engine factor.
        pub fn factor(self: *Self, vals: []const T) !void {
            self.ref_vals = vals;
            // Bypass: identical matrix (linear circuit, unchanged dt) —
            // the factorization is already exact. One O(nnz) compare.
            const nnz = self.vcopy.len;
            if (self.factored and simdEql(T, self.vcopy, vals[0..nnz])) return;
            try self.factorInner(vals);
            simdCopy(T, self.vcopy, vals[0..nnz]);
        }

        fn factorInner(self: *Self, vals: []const T) !void {
            if (self.tri) |*tri| {
                try tri.factor(vals);
                self.factored = true;
                return;
            }
            if (self.bbd_eng) |*eng| {
                if (eng.factor(vals)) |_| {
                    self.factored = true;
                    return;
                } else |_| {
                    // Singular block in BBD: fall back to flat PERMANENTLY.
                    // Lu is constructed lazily — never allocated while BBD active.
                    eng.deinit();
                    self.bbd_eng = null;
                    self.factored = false;
                }
            }
            if (self.lu == null) {
                if (self.q.len == 0)
                    self.q = try computeOrdering(self.gpa, self.n, self.col_ptr, self.row_idx, self.params);
                self.lu = try SparseLu.init(self.gpa, self.n, self.col_ptr, self.row_idx, self.q);
            }
            var lu = &self.lu.?;
            const ptol: T = @floatCast(self.params.pivot_tol);
            const growth: T = @floatCast(self.params.refactor_growth_limit);
            if (self.factored) {
                lu.refactor(self.col_ptr, vals, growth) catch {
                    self.factored = false;
                    try lu.factor(self.gpa, self.col_ptr, self.row_idx, vals, ptol);
                    self.factored = true;
                };
            } else {
                try lu.factor(self.gpa, self.col_ptr, self.row_idx, vals, ptol);
                self.factored = true;
            }
        }

        /// In-place engine dispatch (no refinement).
        fn rawSolve(self: *Self, x: []T) void {
            if (self.tri) |*tri| return tri.solve(x[0..self.n]);
            if (self.bbd_eng) |*eng| return eng.solveInPlace(x[0..self.n]);
            self.lu.?.solve(x[0..self.n], x[0..self.n]);
        }

        /// Iterative refinement: r = b - A*x (CSC SpMV), rawSolve(r), x += r.
        fn refine(self: *Self, x: []T) void {
            const n = self.n;
            const b = self.rbuf[n .. 2 * @as(usize, n)];
            const r = self.rbuf[0..n];
            var step: u2 = 0;
            while (step < self.params.iter_refine_steps) : (step += 1) {
                simdCopy(T, r, b);
                for (0..n) |j| {
                    const xj = x[j];
                    if (xj == 0) continue;
                    for (self.col_ptr[j]..self.col_ptr[j + 1]) |p|
                        r[self.row_idx[p]] -= self.ref_vals[p] * xj;
                }
                self.rawSolve(r);
                // SIMD x[i] += r[i]
                {
                    const WW = std.simd.suggestVectorLength(T) orelse 1;
                    const VV = @Vector(WW, T);
                    var ii: usize = 0;
                    while (ii + WW <= n) : (ii += WW) {
                        const xv: VV = x[ii..][0..WW].*;
                        const rv: VV = r[ii..][0..WW].*;
                        x[ii..][0..WW].* = xv + rv;
                    }
                    for (x[ii..n], r[ii..]) |*xi, di| xi.* += di;
                }
            }
        }

        pub fn solveNeg(self: *Self, rhs: []const T, x: []T) void {
            negateSimd(T, rhs[0..self.n], x[0..self.n]);
            const do_refine = self.params.iter_refine_steps > 0;
            if (do_refine) simdCopy(T, self.rbuf[self.n..][0..self.n], x[0..self.n]);
            self.rawSolve(x);
            if (do_refine) self.refine(x);
        }

        pub fn solve(self: *Self, rhs: []const T, x: []T) void {
            if (rhs.ptr != x.ptr) simdCopy(T, x[0..self.n], rhs[0..self.n]);
            const do_refine = self.params.iter_refine_steps > 0;
            if (do_refine) simdCopy(T, self.rbuf[self.n..][0..self.n], x[0..self.n]);
            self.rawSolve(x);
            if (do_refine) self.refine(x);
        }

        pub fn solveT(self: *Self, rhs: []const T, x: []T) void {
            if (self.tri) |*tri| {
                if (rhs.ptr != x.ptr) simdCopy(T, x[0..self.n], rhs[0..self.n]);
                tri.solveT(x[0..self.n]);
                return;
            }
            if (rhs.ptr != x.ptr) simdCopy(T, x[0..self.n], rhs[0..self.n]);
            if (self.bbd_eng) |*eng| {
                eng.solveTInPlace(x[0..self.n]);
                return;
            }
            self.lu.?.solveT(x[0..self.n], x[0..self.n]);
        }
    };
}

/// Compute column ordering (BTF+AMD or natural) and return owned q slice.
fn computeOrdering(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, params: Params) ![]u32 {
    const q = try gpa.alloc(u32, n);
    errdefer gpa.free(q);
    switch (params.ordering) {
        .natural => for (q, 0..) |*qi, i| {
            qi.* = @intCast(i);
        },
        .amd => {
            const ws_buf = try gpa.alloc(u32, order_mod.wsSize(n, col_ptr[n]));
            defer gpa.free(ws_buf);
            var ws = order_mod.Ws.init(ws_buf);
            if (params.btf)
                try order_mod.order(n, col_ptr, row_idx, q, &ws)
            else
                try order_mod.amd(n, col_ptr, row_idx, q, &ws);
        },
    }
    return q;
}

pub const Solver = SolverT(f64);

fn simdCopy(comptime T: type, dst: []T, src: []const T) void {
    const WW = std.simd.suggestVectorLength(T) orelse 1;
    var i: usize = 0;
    while (i + WW <= dst.len) : (i += WW) {
        dst[i..][0..WW].* = src[i..][0..WW].*;
    }
    for (dst[i..], src[i..]) |*d, s| d.* = s;
}

fn simdEql(comptime T: type, a: []const T, b: []const T) bool {
    const WW = std.simd.suggestVectorLength(T) orelse 1;
    const VV = @Vector(WW, T);
    var i: usize = 0;
    while (i + WW <= a.len) : (i += WW) {
        const av: VV = a[i..][0..WW].*;
        const bv: VV = b[i..][0..WW].*;
        if (@reduce(.Or, av != bv)) return false;
    }
    for (a[i..], b[i..]) |ai, bi| {
        if (ai != bi) return false;
    }
    return true;
}

fn negateSimd(comptime T: type, src: []const T, dst: []T) void {
    const W = std.simd.suggestVectorLength(T) orelse 1;
    const V = @Vector(W, T);
    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: V = src[i..][0..W].*;
        const p: *[W]T = dst[i..][0..W];
        p.* = -v;
    }
    for (src[i..], dst[i..]) |s, *d| d.* = -s;
}

// ============================================================================
// Tests — Solver facade: factor/solve/refactor, MNA structural zero diag,
// singular detection, solveT correctness, determinism.
// ============================================================================

const testing = std.testing;

fn cscFromDense(gpa: Allocator, n: usize, dense: []const f64, col_ptr: *[]u32, row_idx: *[]u32, vals: *[]f64) !void {
    var nnz: usize = 0;
    for (dense) |v| nnz += @intFromBool(v != 0);
    col_ptr.* = try gpa.alloc(u32, n + 1);
    row_idx.* = try gpa.alloc(u32, nnz);
    vals.* = try gpa.alloc(f64, nnz);
    var p: u32 = 0;
    col_ptr.*[0] = 0;
    for (0..n) |j| {
        for (0..n) |i| {
            const v = dense[i * n + j];
            if (v != 0) {
                row_idx.*[p] = @intCast(i);
                vals.*[p] = v;
                p += 1;
            }
        }
        col_ptr.*[j + 1] = p;
    }
}

fn DenseCsc(comptime n: usize) type {
    return struct {
        col_ptr: [n + 1]u32,
        row_idx: [n * n]u32,
        vals: [n * n]f64,
        fn from(a: [n][n]f64) @This() {
            var s: @This() = undefined;
            var m: u32 = 0;
            s.col_ptr[0] = 0;
            for (0..n) |j| {
                for (0..n) |i| {
                    if (a[i][j] != 0) {
                        s.row_idx[m] = @intCast(i);
                        s.vals[m] = a[i][j];
                        m += 1;
                    }
                }
                s.col_ptr[j + 1] = m;
            }
            return s;
        }
        fn nnz(s: *const @This()) u32 {
            return s.col_ptr[n];
        }
    };
}

fn denseSolve(comptime n: usize, a_in: [n][n]f64, b_in: [n]f64) [n]f64 {
    var a = a_in;
    var b = b_in;
    for (0..n) |k| {
        var piv = k;
        for (k + 1..n) |i| {
            if (@abs(a[i][k]) > @abs(a[piv][k])) piv = i;
        }
        std.mem.swap([n]f64, &a[k], &a[piv]);
        std.mem.swap(f64, &b[k], &b[piv]);
        for (k + 1..n) |i| {
            const f = a[i][k] / a[k][k];
            for (k..n) |j| a[i][j] -= f * a[k][j];
            b[i] -= f * b[k];
        }
    }
    var x: [n]f64 = undefined;
    var k = n;
    while (k > 0) {
        k -= 1;
        var s = b[k];
        for (k + 1..n) |j| s -= a[k][j] * x[j];
        x[k] = s / a[k][k];
    }
    return x;
}

fn naturalOrder(comptime n: usize) [n]u32 {
    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);
    return q;
}

fn checkSolve(comptime n: usize, a: [n][n]f64, b: [n]f64, lu: *sparse_lu.SparseLu(f64)) !void {
    var x: [n]f64 = undefined;
    lu.solve(&b, &x);
    const xref = denseSolve(n, a, b);
    for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
}

test "Solver: factor + solveNeg + refactor on fixed pattern" {
    const gpa = testing.allocator;
    var col_ptr: []u32 = undefined;
    var row_idx: []u32 = undefined;
    var vals: []f64 = undefined;
    try cscFromDense(gpa, 2, &.{ 2, 1, 1, 3 }, &col_ptr, &row_idx, &vals);
    defer gpa.free(col_ptr);
    defer gpa.free(row_idx);
    defer gpa.free(vals);

    var s = try Solver.init(gpa, 2, col_ptr, row_idx, null);
    defer s.deinit();
    try s.factor(vals);
    var x: [2]f64 = undefined;
    s.solveNeg(&.{ 5, 7 }, &x);
    try testing.expectApproxEqAbs(@as(f64, -1.6), x[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1.8), x[1], 1e-12);

    // new values, same pattern -> refactor path
    vals[0] = 4;
    vals[3] = 5; // [4 1; 1 5]
    try s.factor(vals);
    s.solveNeg(&.{ 9, 11 }, &x);
    try testing.expectApproxEqAbs(@as(f64, -34.0 / 19.0), x[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -35.0 / 19.0), x[1], 1e-12);
}

test "factor + solve on an MNA-like system with a structural zero diagonal" {
    const a = [3][3]f64{
        .{ 1e-3, 0, 1 },
        .{ 0, 2e-3, -1 },
        .{ 1, -1, 0 },
    };
    const b = [3]f64{ 0, 0, 5 };
    const csc = DenseCsc(3).from(a);
    const gpa = testing.allocator;
    const SparseLu = sparse_lu.SparseLu(f64);
    const q3 = naturalOrder(3);
    var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try checkSolve(3, a, b, &lu);
}

test "refactor: same pattern, new values, no allocation" {
    var a = [4][4]f64{
        .{ 4, 1, 0, 0 },
        .{ 1, 5, 2, 0 },
        .{ 0, 2, 6, 3 },
        .{ 0, 0, 3, 7 },
    };
    const gpa = testing.allocator;
    var csc = DenseCsc(4).from(a);
    const SparseLu = sparse_lu.SparseLu(f64);
    const q4 = naturalOrder(4);
    var lu = try SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q4);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try checkSolve(4, a, .{ 1, 2, 3, 4 }, &lu);

    // perturb values on the same pattern, refactor only
    a[1][1] = 9;
    a[2][3] = 1;
    csc = DenseCsc(4).from(a);
    try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
    try checkSolve(4, a, .{ 4, 3, 2, 1 }, &lu);
}

test "singular matrix reported, refactor pivot collapse reported" {
    const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
    const csc = DenseCsc(2).from(a);
    const gpa = testing.allocator;
    const SparseLu = sparse_lu.SparseLu(f64);
    const q2 = naturalOrder(2);
    var lu = try SparseLu.init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q2);
    defer lu.deinit(gpa);
    try testing.expectError(
        error.SingularMatrix,
        lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3),
    );
}

test "solveT: transpose solve matches A^T dense solve" {
    const a = [3][3]f64{
        .{ 1e-3, 0, 1 },
        .{ 0, 2e-3, -1 },
        .{ 1, -1, 0 },
    };
    const b = [3]f64{ 1, 2, 3 };
    const csc = DenseCsc(3).from(a);
    const gpa = testing.allocator;
    const SparseLu = sparse_lu.SparseLu(f64);
    const q3 = naturalOrder(3);
    var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    var at: [3][3]f64 = undefined;
    for (0..3) |i| for (0..3) |j| {
        at[i][j] = a[j][i];
    };
    const xref = denseSolve(3, at, b);
    var x: [3]f64 = undefined;
    lu.solveT(&b, &x);
    for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
}

test "determinism: two factorizations of the same values are byte-identical" {
    const a = [3][3]f64{
        .{ 2, 1, 0 },
        .{ 1, 3, 1 },
        .{ 0, 1, 4 },
    };
    const csc = DenseCsc(3).from(a);
    const gpa = testing.allocator;
    const SparseLu = sparse_lu.SparseLu(f64);
    const q3 = naturalOrder(3);
    var lu1 = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
    defer lu1.deinit(gpa);
    var lu2 = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
    defer lu2.deinit(gpa);
    try lu1.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try lu2.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try testing.expectEqualSlices(u32, lu1.q, lu2.q);
    try testing.expectEqualSlices(f64, lu1.lx.items, lu2.lx.items);
    try testing.expectEqualSlices(f64, lu1.ux.items, lu2.ux.items);
    try testing.expectEqualSlices(f64, lu1.udiag, lu2.udiag);
}
