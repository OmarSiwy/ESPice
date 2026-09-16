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

/// Tuning knobs (KLU-style). Defaults reproduce the established behavior;
/// accuracy <-> speed is traded here, not by editing the kernel.
pub const Params = struct {
    execution: root.Execution = .{},
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
            errdefer self.deinit();
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
                };
            }
            if (bbd) |info| no_bbd: {
                if (comptime @import("builtin").link_libc) {
                    if (std.c.getenv("ESPICE_NO_BBD") != null) break :no_bbd;
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
            @memcpy(self.vcopy, vals[0..nnz]);
        }

        fn factorInner(self: *Self, vals: []const T) !void {
            if (self.tri) |*tri| {
                if (tri.factor(vals)) |_| {
                    self.factored = true;
                    return;
                } else |_| {
                    // Thomas has no pivoting, and an MNA branch row's
                    // structural ZERO diagonal lands here the moment nothing
                    // pads it (the always-on diagonal gmin used to). Demote to
                    // the pivoting LU permanently — the BBD fallback below.
                    // ponytail: costs tridiag speed on vsource-bearing
                    // ladders; a 2x2-block-pivot Thomas recovers it if the
                    // bench says so.
                    tri.deinit(self.gpa);
                    self.tri = null;
                    self.factored = false;
                }
            }
            if (self.bbd_eng) |*eng| {
                if (eng.factorWithExecution(vals, self.params.execution)) |_| {
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
                @memcpy(r, b);
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
            if (do_refine) @memcpy(self.rbuf[self.n..][0..self.n], x[0..self.n]);
            self.rawSolve(x);
            if (do_refine) self.refine(x);
        }

        pub fn solve(self: *Self, rhs: []const T, x: []T) void {
            if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
            const do_refine = self.params.iter_refine_steps > 0;
            if (do_refine) @memcpy(self.rbuf[self.n..][0..self.n], x[0..self.n]);
            self.rawSolve(x);
            if (do_refine) self.refine(x);
        }

        pub fn solveT(self: *Self, rhs: []const T, x: []T) void {
            // ponytail: every transpose engine consumes the same in-place RHS.
            if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
            if (self.tri) |*tri| {
                tri.solveT(x[0..self.n]);
                return;
            }
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
