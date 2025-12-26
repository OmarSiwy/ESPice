//! Fixed-pattern sparse direct solver. The sparsity pattern comes frozen
//! from CompiledCircuit.compile(); there is no assembly here — analyses
//! hand in a vals slice living on that pattern.
//!
//!   init     : ordering (BTF+AMD) once, from the pattern
//!   factor   : numeric refactor on the frozen pattern (zero alloc);
//!              automatic fallback to full factor on pivot collapse
//!   solveNeg : x = -A\rhs  (the Newton step)
//!   solve    : x =  A\rhs
//!   solveT   : x =  A'\rhs (adjoint — noise/sens)
//!
//! The underlying LU (§1.5 / §2.7 base tier):
//!
//!   ordering   : stage-1 BTF + per-block AMD (`order.zig`) — once
//!                at init, from the merged pattern
//!   factor     : left-looking Gilbert-Peierls; threshold pivoting that
//!                prefers the diagonal (KLU-style, candidates within the
//!                factored column); builds the L/U pattern
//!   refactor   : numeric-only replay over the stored pattern + pivot
//!                sequence — the Newton hot path, zero allocation
//!   solve      : permuted forward/back substitution
//!
//! Iterative solvers intentionally absent in the time-domain Newton loop
//! (MNA conditioning, §2.7 invariant). Pivot growth is the caller's
//! monitor: `refactor` fails on a collapsed pivot and the caller re-runs
//! `factor` (automatic fall-back-to-full-factor).

const std = @import("std");
const order_mod = @import("order.zig");
const root = @import("root.zig");
const bbd_mod = @import("bbd.zig");

const Allocator = std.mem.Allocator;
const NONE: u32 = std.math.maxInt(u32);

/// Sparse direct solver over element type T (f32 or f64). `Solver` below
/// is the f64 instantiation (existing callers).
pub fn SolverT(comptime T: type) type {
    return struct {
        const Self = @This();

        n: u32,
        col_ptr: []const u32,
        row_idx: []const u32,
        lu: ?Lu(T),
        tri: ?TriDiag(T),
        bbd_eng: ?bbd_mod.Bbd(T) = null,
        gpa: std.mem.Allocator,
        factored: bool = false,
        bbd: ?root.BbdInfo = null,

        pub fn init(gpa: std.mem.Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?root.BbdInfo) !Self {
            // Dispatch precedence: tridiag > BBD > flat. The BBD engine
            // (bbd.zig) re-factors every block dense per Newton iteration —
            // blocks share STRUCTURE, not values (W/L vary per instance),
            // so there is no factor-once-per-block-type shortcut.
            // ZPICEY_NO_BBD=1 forces the flat path (A/B correctness switch).
            if (isTridiag(n, col_ptr, row_idx)) {
                return .{
                    .n = n,
                    .col_ptr = col_ptr,
                    .row_idx = row_idx,
                    .lu = null,
                    .tri = try TriDiag(T).init(gpa, n, col_ptr, row_idx),
                    .gpa = gpa,
                    .bbd = bbd,
                };
            }
            if (bbd) |info| no_bbd: {
                if (comptime @import("builtin").link_libc) {
                    if (std.c.getenv("ZPICEY_NO_BBD") != null) break :no_bbd;
                }
                const eng = bbd_mod.Bbd(T).init(gpa, n, col_ptr, row_idx, info, .{}) catch |err| switch (err) {
                    error.NotApplicable => break :no_bbd,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                // Flat Lu intentionally NOT allocated: on a factor-time
                // singularity the facade constructs it lazily and stays flat.
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
            return .{
                .n = n,
                .col_ptr = col_ptr,
                .row_idx = row_idx,
                .lu = try Lu(T).init(gpa, n, col_ptr, row_idx),
                .tri = null,
                .gpa = gpa,
                .bbd = bbd,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.lu) |*lu| lu.deinit(self.gpa);
            if (self.tri) |*tri| tri.deinit(self.gpa);
            if (self.bbd_eng) |*eng| eng.deinit();
            self.* = undefined;
        }

        pub fn factor(self: *Self, vals: []const T) !void {
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
                    // Singular block or border in the BBD path: fall back to
                    // the flat solver PERMANENTLY (mirrors the refactor →
                    // full-factor philosophy below). Lu is constructed lazily
                    // here — it was never allocated while BBD was active.
                    eng.deinit();
                    self.bbd_eng = null;
                    self.factored = false;
                }
            }
            if (self.lu == null)
                self.lu = try Lu(T).init(self.gpa, self.n, self.col_ptr, self.row_idx);
            var lu = &self.lu.?;
            if (self.factored) {
                lu.refactor(self.col_ptr, vals) catch {
                    // Full re-factor resets Lu.factored; mirror that here so a
                    // FAILED re-factor can't leave us replaying poisoned state
                    // on the next call (gmin retry paths catch the error).
                    self.factored = false;
                    try lu.factor(self.gpa, self.col_ptr, self.row_idx, vals, 1e-3);
                    self.factored = true;
                };
            } else {
                try lu.factor(self.gpa, self.col_ptr, self.row_idx, vals, 1e-3);
                self.factored = true;
            }
        }

        pub fn solveNeg(self: *Self, rhs: []const T, x: []T) void {
            if (self.tri) |*tri| {
                negateSimd(T, rhs[0..self.n], x[0..self.n]);
                tri.solve(x[0..self.n]);
                return;
            }
            negateSimd(T, rhs[0..self.n], x[0..self.n]);
            if (self.bbd_eng) |*eng| {
                eng.solveInPlace(x[0..self.n]);
                return;
            }
            self.lu.?.solve(x[0..self.n], x[0..self.n]);
        }

        pub fn solve(self: *Self, rhs: []const T, x: []T) void {
            if (self.tri) |*tri| {
                if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
                tri.solve(x[0..self.n]);
                return;
            }
            if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
            if (self.bbd_eng) |*eng| {
                eng.solveInPlace(x[0..self.n]);
                return;
            }
            self.lu.?.solve(x[0..self.n], x[0..self.n]);
        }

        pub fn solveT(self: *Self, rhs: []const T, x: []T) void {
            if (self.tri) |*tri| {
                if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
                tri.solveT(x[0..self.n]);
                return;
            }
            if (rhs.ptr != x.ptr) @memcpy(x[0..self.n], rhs[0..self.n]);
            if (self.bbd_eng) |*eng| {
                eng.solveTInPlace(x[0..self.n]);
                return;
            }
            self.lu.?.solveT(x[0..self.n], x[0..self.n]);
        }
    };
}

pub const Solver = SolverT(f64);

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

fn Lu(comptime T: type) type {
    return struct {
        const Self = @This();

        n: u32,
        q: []u32, // column order: step k factors original column q[k]
        pinv: []u32, // original row -> pivot step (permuted position)
        // L strictly lower / U strictly upper, column-wise over pivot steps.
        // Row indices are PERMUTED positions; U rows per column are stored in
        // the topological order of the triangular solve so refactor replays.
        lp: []u32,
        up: []u32,
        udiag: []T,
        // pinv ∘ row_idx (len nnz(A)): refactor scatters through it directly.
        prow: []u32,
        li: std.ArrayList(u32) = .empty,
        lx: std.ArrayList(T) = .empty,
        ui: std.ArrayList(u32) = .empty,
        ux: std.ArrayList(T) = .empty,
        // workspace (all length n)
        w: []T,
        flag: []u32,
        topo: []u32,
        stack: []u32,
        pstack: []u32,
        y: []T,
        factored: bool = false,

        pub const FactorError = error{ OutOfMemory, SingularMatrix };

        /// Allocates workspace and computes the fill-reducing column order
        /// (BTF + AMD over the merged pattern).
        pub fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32) !Self {
            // ponytail: pre-size L/U arrays to nnz estimate — avoids ArrayList
            // growth memset during first factor. Typical fill ~2-4x nnz for SPICE.
            const nnz = col_ptr[n];
            const est_lu: usize = @max(nnz, 2 * @as(usize, n));
            var self = Self{
                .n = n,
                .q = try gpa.alloc(u32, n),
                .pinv = try gpa.alloc(u32, n),
                .lp = try gpa.alloc(u32, n + 1),
                .up = try gpa.alloc(u32, n + 1),
                .udiag = try gpa.alloc(T, n),
                .prow = try gpa.alloc(u32, nnz),
                .w = try gpa.alloc(T, n),
                .flag = try gpa.alloc(u32, n),
                .topo = try gpa.alloc(u32, n),
                .stack = try gpa.alloc(u32, n),
                .pstack = try gpa.alloc(u32, n),
                .y = try gpa.alloc(T, n),
            };
            try self.li.ensureTotalCapacity(gpa, est_lu);
            try self.lx.ensureTotalCapacity(gpa, est_lu);
            try self.ui.ensureTotalCapacity(gpa, est_lu);
            try self.ux.ensureTotalCapacity(gpa, est_lu);
            @memset(self.w, 0);
            @memset(self.flag, 0);
            const ws_buf = try gpa.alloc(u32, order_mod.wsSize(n, col_ptr[n]));
            defer gpa.free(ws_buf);
            var ws = order_mod.Ws.init(ws_buf);
            try order_mod.order(n, col_ptr, row_idx, self.q, &ws);
            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            inline for (.{ self.q, self.pinv, self.lp, self.up, self.prow, self.flag, self.topo, self.stack, self.pstack }) |s| gpa.free(s);
            inline for (.{ self.udiag, self.w, self.y }) |s| gpa.free(s);
            self.li.deinit(gpa);
            self.lx.deinit(gpa);
            self.ui.deinit(gpa);
            self.ux.deinit(gpa);
        }

        /// Full factorization: symbolic (reach, pattern) + numeric + pivoting.
        pub fn factor(
            self: *Self,
            gpa: Allocator,
            col_ptr: []const u32,
            row_idx: []const u32,
            vals: []const T,
            pivot_tol: T,
        ) FactorError!void {
            const n = self.n;
            self.factored = false;
            @memset(self.pinv, NONE);
            @memset(self.flag, 0);
            self.li.clearRetainingCapacity();
            self.lx.clearRetainingCapacity();
            self.ui.clearRetainingCapacity();
            self.ux.clearRetainingCapacity();

            for (0..n) |k| {
                const c = self.q[k];
                self.lp[k] = @intCast(self.li.items.len);
                self.up[k] = @intCast(self.ui.items.len);
                const mark: u32 = @intCast(k + 1);

                // ---- reach: DFS from A[:,c] through completed L columns ----
                var nt: u32 = 0; // topo fill (finish order)
                for (col_ptr[c]..col_ptr[c + 1]) |p| {
                    var r = row_idx[p];
                    if (self.flag[r] == mark) continue;
                    var sp: u32 = 0;
                    self.stack[sp] = r;
                    self.pstack[sp] = if (self.pinv[r] == NONE) NONE else self.lp[self.pinv[r]];
                    self.flag[r] = mark;
                    while (true) {
                        r = self.stack[sp];
                        const kc = self.pinv[r];
                        const end = if (kc == NONE) NONE else self.lp[kc + 1];
                        var descended = false;
                        while (self.pstack[sp] != NONE and self.pstack[sp] < end) {
                            const child = self.li.items[self.pstack[sp]];
                            self.pstack[sp] += 1;
                            if (self.flag[child] != mark) {
                                self.flag[child] = mark;
                                sp += 1;
                                self.stack[sp] = child;
                                self.pstack[sp] = if (self.pinv[child] == NONE) NONE else self.lp[self.pinv[child]];
                                descended = true;
                                break;
                            }
                        }
                        if (descended) continue;
                        self.topo[nt] = r; // finished
                        nt += 1;
                        if (sp == 0) break;
                        sp -= 1;
                    }
                }

                // ---- scatter A[:,c] (w is zero outside previous clears) ----
                for (col_ptr[c]..col_ptr[c + 1]) |p| self.w[row_idx[p]] = vals[p];

                // ---- sparse triangular solve, reverse finish order ----
                var idx: u32 = nt;
                while (idx > 0) {
                    idx -= 1;
                    const r = self.topo[idx];
                    const kc = self.pinv[r];
                    if (kc == NONE) continue; // pivot candidate, no children
                    const ukr = self.w[r];
                    self.ui.append(gpa, kc) catch return error.OutOfMemory;
                    self.ux.append(gpa, ukr) catch return error.OutOfMemory;
                    for (self.lp[kc]..self.lp[kc + 1]) |p| {
                        self.w[self.li.items[p]] -= self.lx.items[p] * ukr;
                    }
                }

                // ---- threshold pivoting, diagonal preferred ----
                var amax: T = 0;
                var piv: u32 = NONE;
                for (self.topo[0..nt]) |r| {
                    if (self.pinv[r] != NONE) continue;
                    const a = @abs(self.w[r]);
                    if (a > amax) {
                        amax = a;
                        piv = r;
                    }
                }
                if (piv == NONE or amax == 0 or !std.math.isFinite(amax))
                    return error.SingularMatrix;
                if (self.pinv[c] == NONE and @abs(self.w[c]) >= pivot_tol * amax) piv = c;
                const d = self.w[piv];
                self.udiag[k] = d;
                self.pinv[piv] = @intCast(k);

                // ---- store L[:,k] (scaled candidates), clear w ----
                for (self.topo[0..nt]) |r| {
                    if (self.pinv[r] == NONE) {
                        self.li.append(gpa, r) catch return error.OutOfMemory; // mapped below
                        self.lx.append(gpa, self.w[r] / d) catch return error.OutOfMemory;
                    }
                    self.w[r] = 0;
                }
            }
            self.lp[n] = @intCast(self.li.items.len);
            self.up[n] = @intCast(self.ui.items.len);
            // L row indices: original -> permuted (every row is pivoted now)
            for (self.li.items) |*r| r.* = self.pinv[r.*];
            // refactor scatter targets: compose pivots with A's pattern
            for (row_idx[0..self.prow.len], self.prow) |r, *pr| pr.* = self.pinv[r];
            self.factored = true;
        }

        /// Numeric refactorization: same pattern, same pivot sequence, new
        /// values. Fails when a reused pivot collapses (caller re-factors).
        pub fn refactor(
            self: *Self,
            col_ptr: []const u32,
            vals: []const T,
        ) error{SingularMatrix}!void {
            std.debug.assert(self.factored);
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;
            for (0..self.n) |k| {
                const c = self.q[k];
                // zero the stored pattern, then scatter A[:,c] in permuted rows
                for (ui[self.up[k]..self.up[k + 1]]) |i| self.w[i] = 0;
                for (li[self.lp[k]..self.lp[k + 1]]) |i| self.w[i] = 0;
                self.w[k] = 0;
                for (col_ptr[c]..col_ptr[c + 1]) |p| self.w[self.prow[p]] = vals[p];
                // replay the triangular solve in stored topological order
                for (self.up[k]..self.up[k + 1]) |p| {
                    const i = ui[p];
                    const uki = self.w[i];
                    ux[p] = uki;
                    for (self.lp[i]..self.lp[i + 1]) |pl| self.w[li[pl]] -= lx[pl] * uki;
                }
                const d = self.w[k];
                if (d == 0 or !std.math.isFinite(d)) return error.SingularMatrix;
                self.udiag[k] = d;
                for (self.lp[k]..self.lp[k + 1]) |p| lx[p] = self.w[li[p]] / d;
            }
        }

        /// x = A^-1 b. `b` and `x` may alias.
        pub fn solve(self: *Self, b: []const T, x: []T) void {
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;
            for (b, 0..) |bi, r| self.y[self.pinv[r]] = bi;
            for (0..self.n) |k| { // L y' = P b
                const yk = self.y[k];
                if (yk == 0) continue;
                for (self.lp[k]..self.lp[k + 1]) |p| self.y[li[p]] -= lx[p] * yk;
            }
            var k = self.n;
            while (k > 0) { // U z = y'
                k -= 1;
                const zk = self.y[k] / self.udiag[k];
                self.y[k] = zk;
                if (zk == 0) continue;
                for (self.up[k]..self.up[k + 1]) |p| self.y[ui[p]] -= ux[p] * zk;
            }
            for (self.q, 0..) |c, j| x[c] = self.y[j];
        }

        /// x = A^{-T} b (transpose solve). Used by the adjoint analyses
        /// (noise, tf, sens). A = P^{-1} L U Q^{-1}, so
        /// A^{-T} = P^{-1} L^{-T} U^{-T} Q^T:
        ///   1. z = Q^T b   (column perm)
        ///   2. U^{-T} z    (forward sub on U^T, lower triangular)
        ///   3. L^{-T} z    (back sub on L^T, unit upper triangular)
        ///   4. x = P^{-1} z (row unperm)
        pub fn solveT(self: *Self, b: []const T, x: []T) void {
            const li = self.li.items;
            const lx = self.lx.items;
            const ui = self.ui.items;
            const ux = self.ux.items;
            // 1. z = Q^T b: pivot-step k gets b[q[k]]
            for (self.q, 0..) |c, k| self.y[k] = b[c];
            // 2. U^{-T} z: U^T is lower triangular; gather-mode forward sub.
            //    U^T[k, ui[p]] = ux[p] (ui[p] < k), diagonal = udiag[k].
            for (0..self.n) |k| {
                for (self.up[k]..self.up[k + 1]) |p| self.y[k] -= ux[p] * self.y[ui[p]];
                self.y[k] /= self.udiag[k];
            }
            // 3. L^{-T} z: L^T is unit upper triangular; gather-mode back sub.
            //    L^T[k, li[p]] = lx[p] (li[p] > k), unit diagonal.
            var k = self.n;
            while (k > 0) {
                k -= 1;
                for (self.lp[k]..self.lp[k + 1]) |p| self.y[k] -= lx[p] * self.y[li[p]];
            }
            // 4. P^{-1} z: pinv[r] = step that pivoted row r → x[r] = z[pinv[r]]
            for (0..self.n) |r| x[r] = self.y[self.pinv[r]];
        }
    };
}

// ponytail: O(n) Thomas solver for tridiagonal matrices (RC ladders, chains).
// Ceiling: no partial pivoting — fine for diagonally-dominant MNA + gmin.
fn isTridiag(n: u32, col_ptr: []const u32, row_idx: []const u32) bool {
    if (n < 3) return false;
    for (0..n) |j| {
        for (col_ptr[j]..col_ptr[j + 1]) |p| {
            const r = row_idx[p];
            const diff = if (r >= j) r - j else j - r;
            if (diff > 1) return false;
        }
    }
    return true;
}

fn triVal(comptime T: type, pos: u32, vals: []const T) T {
    return if (pos != NONE) vals[pos] else 0;
}

fn TriDiag(comptime T: type) type {
    return struct {
        const Self = @This();

        n: u32,
        // CSC positions: a_pos[i] = A[i, i-1] (sub), b_pos[i] = A[i, i], c_pos[i] = A[i, i+1] (super)
        a_pos: []u32,
        b_pos: []u32,
        c_pos: []u32,
        // Factored: bp = modified diagonal, mul = elimination multiplier, cv = super-diagonal values
        bp: []T,
        mul: []T,
        cv: []T,

        pub const FactorError = error{SingularMatrix};

        fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32) !Self {
            var self = Self{
                .n = n,
                .a_pos = try gpa.alloc(u32, n),
                .b_pos = try gpa.alloc(u32, n),
                .c_pos = try gpa.alloc(u32, n),
                .bp = try gpa.alloc(T, n),
                .mul = try gpa.alloc(T, n),
                .cv = try gpa.alloc(T, n),
            };
            @memset(self.a_pos, NONE);
            @memset(self.b_pos, NONE);
            @memset(self.c_pos, NONE);
            for (0..n) |j| {
                for (col_ptr[j]..col_ptr[j + 1]) |p| {
                    const r = row_idx[p];
                    if (r == j) {
                        self.b_pos[j] = @intCast(p);
                    } else if (r == j + 1) {
                        self.a_pos[j + 1] = @intCast(p);
                    } else if (j > 0 and r + 1 == j) {
                        self.c_pos[r] = @intCast(p);
                    }
                }
            }
            return self;
        }

        fn deinit(self: *Self, gpa: Allocator) void {
            inline for (.{ self.a_pos, self.b_pos, self.c_pos }) |s| gpa.free(s);
            inline for (.{ self.bp, self.mul, self.cv }) |s| gpa.free(s);
        }

        fn factor(self: *Self, vals: []const T) FactorError!void {
            const n = self.n;
            self.bp[0] = triVal(T, self.b_pos[0], vals);
            if (self.bp[0] == 0 or !std.math.isFinite(self.bp[0])) return error.SingularMatrix;
            self.mul[0] = 0;
            if (n > 1) self.cv[0] = triVal(T, self.c_pos[0], vals);
            for (1..n) |i| {
                const a = triVal(T, self.a_pos[i], vals);
                const b = triVal(T, self.b_pos[i], vals);
                const m = a / self.bp[i - 1];
                self.mul[i] = m;
                self.bp[i] = b - m * self.cv[i - 1];
                if (self.bp[i] == 0 or !std.math.isFinite(self.bp[i])) return error.SingularMatrix;
                if (i + 1 < n) self.cv[i] = triVal(T, self.c_pos[i], vals);
            }
        }

        fn solve(self: *Self, x: []T) void {
            const n = self.n;
            // Forward sweep: eliminate sub-diagonal
            for (1..n) |i| x[i] -= self.mul[i] * x[i - 1];
            // Back substitution
            x[n - 1] /= self.bp[n - 1];
            var i: usize = n - 1;
            while (i > 0) {
                i -= 1;
                x[i] = (x[i] - self.cv[i] * x[i + 1]) / self.bp[i];
            }
        }

        // A^T solve: A = LU, A^T = U^T L^T
        // U^T is lower bidiagonal (diag=bp, sub=cv), L^T is upper bidiagonal (diag=1, super=mul)
        fn solveT(self: *Self, x: []T) void {
            const n = self.n;
            // Forward sub: U^T y = b
            x[0] /= self.bp[0];
            for (1..n) |i| x[i] = (x[i] - self.cv[i - 1] * x[i - 1]) / self.bp[i];
            // Back sub: L^T x = y
            var i: usize = n - 1;
            while (i > 0) {
                i -= 1;
                x[i] -= self.mul[i + 1] * x[i + 1];
            }
        }
    };
}

// ============================================================================
// Tests — Solver facade on the fixed pattern, plus LU correctness on dense
// references, refactor reuse, MNA structural zero diagonals, determinism
// (the solver-component tier, R3).
// ============================================================================

const testing = std.testing;

fn cscFromDense(gpa: std.mem.Allocator, n: usize, dense: []const f64, col_ptr: *[]u32, row_idx: *[]u32, vals: *[]f64) !void {
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

test "Solver: factor + solveNeg + refactor on fixed pattern" {
    const gpa = testing.allocator;
    // [2 1; 1 3] x = -[5;7] -> x = [-1.6, -1.8]
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

fn checkSolve(comptime n: usize, a: [n][n]f64, b: [n]f64, lu: *Lu(f64)) !void {
    var x: [n]f64 = undefined;
    lu.solve(&b, &x);
    const xref = denseSolve(n, a, b);
    for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
}

test "factor + solve on an MNA-like system with a structural zero diagonal" {
    // Voltage-source branch row: zero diagonal forces off-diagonal pivoting.
    const a = [3][3]f64{
        .{ 1e-3, 0, 1 },
        .{ 0, 2e-3, -1 },
        .{ 1, -1, 0 },
    };
    const b = [3]f64{ 0, 0, 5 };
    const csc = DenseCsc(3).from(a);
    const gpa = testing.allocator;
    var lu = try Lu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
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
    var lu = try Lu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try checkSolve(4, a, .{ 1, 2, 3, 4 }, &lu);

    // perturb values on the same pattern, refactor only
    a[1][1] = 9;
    a[2][3] = 1;
    csc = DenseCsc(4).from(a);
    try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()]);
    try checkSolve(4, a, .{ 4, 3, 2, 1 }, &lu);
}

test "singular matrix reported, refactor pivot collapse reported" {
    const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
    const csc = DenseCsc(2).from(a);
    const gpa = testing.allocator;
    var lu = try Lu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
    defer lu.deinit(gpa);
    try testing.expectError(
        error.SingularMatrix,
        lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3),
    );
}

test "solveT: transpose solve matches A^T \\ b" {
    // Non-symmetric MNA-like system: asymmetric off-diagonals force a
    // meaningful test of the transpose vs the forward solve.
    const a = [3][3]f64{
        .{ 1e-3, 0, 1 },
        .{ 0, 2e-3, -1 },
        .{ 1, -1, 0 },
    };
    const b = [3]f64{ 1, 2, 3 };
    const csc = DenseCsc(3).from(a);
    const gpa = testing.allocator;
    var lu = try Lu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
    defer lu.deinit(gpa);
    try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    // reference: A^T dense solve
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
    var lu1 = try Lu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
    defer lu1.deinit(gpa);
    var lu2 = try Lu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
    defer lu2.deinit(gpa);
    try lu1.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try lu2.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
    try testing.expectEqualSlices(u32, lu1.q, lu2.q);
    try testing.expectEqualSlices(f64, lu1.lx.items, lu2.lx.items);
    try testing.expectEqualSlices(f64, lu1.ux.items, lu2.ux.items);
    try testing.expectEqualSlices(f64, lu1.udiag, lu2.udiag);
}
