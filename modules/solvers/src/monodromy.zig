//! Matrix-free monodromy products for PSS shooting.
//!
//! Computes Φ·v (forward) and Φ^T·v (adjoint) via sensitivity recurrence
//! over saved per-step LU factorizations — never forms the dense monodromy
//! matrix. Cost: O(S · nnz(LU)) per product.
//!
//! The shooting Jacobian products (Φ-I)·v and (Φ-I)^T·v are thin wrappers
//! that subtract the identity contribution.
//!
//! See docs/solvers/monodromy-krylov.md §1 for the mathematical derivation.

const std = @import("std");
const direct = @import("direct.zig");

const Allocator = std.mem.Allocator;

pub fn Monodromy(comptime T: type) type {
    return struct {
        const Self = @This();
        const W = std.simd.suggestVectorLength(T) orelse 1;
        const Vec = @Vector(W, T);

        /// SIMD zero-fill a contiguous T buffer.
        inline fn simdZero(buf: []T) void {
            const zero: Vec = @splat(0);
            var i: usize = 0;
            while (i + W <= buf.len) : (i += W) {
                buf[i..][0..W].* = zero;
            }
            for (buf[i..]) |*v| v.* = 0;
        }

        /// SIMD copy contiguous T buffers.
        inline fn simdCopy(dst: []T, src: []const T) void {
            var i: usize = 0;
            while (i + W <= dst.len) : (i += W) {
                dst[i..][0..W].* = src[i..][0..W].*;
            }
            for (dst[i..], src[i..]) |*d, s| d.* = s;
        }

        /// One saved integration step: the LU factorization of A_{s+1} = G + αC,
        /// plus C_s values for the coupling term.
        pub const StepRecord = struct {
            /// Factored A_{s+1} (borrowed from the integrator — must outlive Monodromy)
            lu: *direct.SolverT(T),
            /// C_s values on the circuit CSC pattern (borrowed)
            c_vals: []const T,
            /// Integration coefficient β (BE: 1/h, trap: 1/h)
            beta: T,
        };

        n: u32,
        col_ptr: []const u32,
        row_idx: []const u32,
        steps: []const StepRecord,
        /// Workspace: intermediate vector (length n)
        w_scratch: []T,
        /// Workspace: SpMV result (length n)
        rhs_scratch: []T,

        /// Initialize with saved step records from one period integration.
        pub fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, steps: []const StepRecord) !Self {
            std.debug.assert(steps.len > 0);
            std.debug.assert(col_ptr.len == @as(usize, n) + 1);
            const w_scratch = try gpa.alloc(T, n);
            errdefer gpa.free(w_scratch);
            const rhs_scratch = try gpa.alloc(T, n);
            return .{
                .n = n,
                .col_ptr = col_ptr,
                .row_idx = row_idx,
                .steps = steps,
                .w_scratch = w_scratch,
                .rhs_scratch = rhs_scratch,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.w_scratch);
            gpa.free(self.rhs_scratch);
            self.* = undefined;
        }

        /// CSC SpMV: out = C * x, where C has the same sparsity pattern
        /// (col_ptr, row_idx) but values from c_vals.
        fn spmv(self: *const Self, c_vals: []const T, x: []const T, out: []T) void {
            const n = self.n;
            simdZero(out[0..n]);
            // ponytail: scalar CSC SpMV — SIMD on the scatter is tricky
            // (indirect stores). Upgrade to segmented-scan if profiling shows need.
            for (0..n) |j| {
                const xj = x[j];
                if (xj == 0) continue;
                for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| {
                    out[self.row_idx[p]] += c_vals[p] * xj;
                }
            }
        }

        /// CSC transpose SpMV: out = C^T * x.
        /// C^T[j, row_idx[p]] = c_vals[p] for p in col_ptr[j]..col_ptr[j+1].
        fn spmvT(self: *const Self, c_vals: []const T, x: []const T, out: []T) void {
            const n = self.n;
            simdZero(out[0..n]);
            for (0..n) |j| {
                var acc: T = 0;
                for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| {
                    acc += c_vals[p] * x[self.row_idx[p]];
                }
                out[j] = acc;
            }
        }

        /// Compute w = Φ·v via forward sensitivity recurrence.
        /// For s = 0..S-1: A_{s+1} · w_{s+1} = β_s · C_s · w_s
        /// Start: w_0 = v. Result: Φ·v = w_S.
        pub fn product(self: *Self, v: []const T, w: []T) void {
            const n = self.n;
            std.debug.assert(v.len >= n);
            std.debug.assert(w.len >= n);

            // w_0 = v
            simdCopy(w[0..n], v[0..n]);

            for (self.steps) |step| {
                // rhs = β · C_s · w
                self.spmv(step.c_vals, w[0..n], self.rhs_scratch[0..n]);
                const beta = step.beta;
                for (self.rhs_scratch[0..n]) |*r| r.* *= beta;

                // w_{s+1} = A_{s+1}^{-1} · rhs
                step.lu.solve(self.rhs_scratch[0..n], w[0..n]);
            }
        }

        /// Compute z = Φ^T·v via adjoint (backward) recurrence.
        /// For s = S-1..0: z_s = C_s^T · β · A_{s+1}^{-T} · z_{s+1}
        /// Start: z_S = v. Result: Φ^T·v = z_0.
        pub fn adjointProduct(self: *Self, v: []const T, z: []T) void {
            const n = self.n;
            std.debug.assert(v.len >= n);
            std.debug.assert(z.len >= n);

            // z_S = v
            simdCopy(z[0..n], v[0..n]);

            var s = self.steps.len;
            while (s > 0) {
                s -= 1;
                const step = self.steps[s];

                // tmp = A_{s+1}^{-T} · z
                step.lu.solveT(z[0..n], self.w_scratch[0..n]);

                // scale by β
                const beta = step.beta;
                for (self.w_scratch[0..n]) |*val| val.* *= beta;

                // z_s = C_s^T · (β · A_{s+1}^{-T} · z_{s+1})
                self.spmvT(step.c_vals, self.w_scratch[0..n], z[0..n]);
            }
        }

        /// Compute w = (Φ - I)·v (the shooting Jacobian-vector product).
        pub fn shootingProduct(self: *Self, v: []const T, w: []T) void {
            const n = self.n;
            self.product(v, w);
            for (0..n) |i| w[i] -= v[i];
        }

        /// Compute z = (Φ - I)^T·v (adjoint shooting product).
        pub fn adjointShootingProduct(self: *Self, v: []const T, z: []T) void {
            const n = self.n;
            self.adjointProduct(v, z);
            for (0..n) |i| z[i] -= v[i];
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Build a dense n×n CSC from row-major data. Only stores nonzeros.
fn DenseCsc(comptime n: usize) type {
    return struct {
        col_ptr: [n + 1]u32,
        row_idx: [n * n]u32,
        vals: [n * n]f64,
        nnz_count: u32,

        fn from(a: [n * n]f64) @This() {
            var s: @This() = undefined;
            var m: u32 = 0;
            s.col_ptr[0] = 0;
            for (0..n) |j| {
                for (0..n) |i| {
                    const v = a[i * n + j];
                    if (v != 0) {
                        s.row_idx[m] = @intCast(i);
                        s.vals[m] = v;
                        m += 1;
                    }
                }
                s.col_ptr[j + 1] = m;
            }
            s.nnz_count = m;
            return s;
        }

        fn nnz(s: *const @This()) u32 {
            return s.nnz_count;
        }
    };
}

/// Dense matrix multiply: C = A * B (all n×n, row-major).
fn denseMatMul(comptime n: usize, a: [n * n]f64, b: [n * n]f64) [n * n]f64 {
    var c = [_]f64{0} ** (n * n);
    for (0..n) |i| {
        for (0..n) |k| {
            const aik = a[i * n + k];
            if (aik == 0) continue;
            for (0..n) |j| {
                c[i * n + j] += aik * b[k * n + j];
            }
        }
    }
    return c;
}

/// Dense matrix-vector product: y = A * x (row-major A).
fn denseMatVec(comptime n: usize, a: [n * n]f64, x: [n]f64) [n]f64 {
    var y = [_]f64{0} ** n;
    for (0..n) |i| {
        for (0..n) |j| {
            y[i] += a[i * n + j] * x[j];
        }
    }
    return y;
}

/// Dense matrix transpose (row-major).
fn denseTranspose(comptime n: usize, a: [n * n]f64) [n * n]f64 {
    var t: [n * n]f64 = undefined;
    for (0..n) |i| {
        for (0..n) |j| {
            t[j * n + i] = a[i * n + j];
        }
    }
    return t;
}

/// Invert a dense n×n matrix via Gauss-Jordan (row-major). Test helper only.
fn denseInvert(comptime n: usize, a_in: [n * n]f64) [n * n]f64 {
    var a = a_in;
    // Augment with identity
    var inv = [_]f64{0} ** (n * n);
    for (0..n) |i| inv[i * n + i] = 1;

    for (0..n) |k| {
        // Partial pivot
        var piv = k;
        for (k + 1..n) |i| {
            if (@abs(a[i * n + k]) > @abs(a[piv * n + k])) piv = i;
        }
        if (piv != k) {
            for (0..n) |j| {
                std.mem.swap(f64, &a[k * n + j], &a[piv * n + j]);
                std.mem.swap(f64, &inv[k * n + j], &inv[piv * n + j]);
            }
        }
        const d = a[k * n + k];
        for (0..n) |j| {
            a[k * n + j] /= d;
            inv[k * n + j] /= d;
        }
        for (0..n) |i| {
            if (i == k) continue;
            const f = a[i * n + k];
            for (0..n) |j| {
                a[i * n + j] -= f * a[k * n + j];
                inv[i * n + j] -= f * inv[k * n + j];
            }
        }
    }
    return inv;
}

/// Build a test scenario: S steps of a constant-coefficient 2×2 system.
/// A = G + α·C (identity here for simplicity), C is the capacitance matrix.
/// Returns the dense Φ = (A^{-1} · β · C)^S and wired StepRecords.
const TestFixture = struct {
    const N = 2;
    const S = 3;

    a_csc: DenseCsc(N),
    c_csc: DenseCsc(N),
    solvers: [S]direct.SolverT(f64),
    records: [S]Monodromy(f64).StepRecord,

    /// Dense Φ for the constant-coefficient case: Φ = (A^{-1} β C)^S
    dense_phi: [N * N]f64,

    fn setup(self: *TestFixture, gpa: Allocator) !void {
        // A = [2, 0.5; 0.5, 3], C = [1, 0.1; 0.1, 0.8], β = 10
        const a_dense = [N * N]f64{ 2, 0.5, 0.5, 3 };
        const c_dense = [N * N]f64{ 1, 0.1, 0.1, 0.8 };
        const beta: f64 = 10.0;

        self.a_csc = DenseCsc(N).from(a_dense);
        self.c_csc = DenseCsc(N).from(c_dense);

        for (&self.solvers) |*slv| {
            slv.* = try direct.SolverT(f64).init(
                gpa,
                N,
                &self.a_csc.col_ptr,
                self.a_csc.row_idx[0..self.a_csc.nnz()],
                null,
            );
            try slv.factor(self.a_csc.vals[0..self.a_csc.nnz()]);
        }

        for (&self.records, &self.solvers) |*rec, *slv| {
            rec.* = .{
                .lu = slv,
                .c_vals = self.c_csc.vals[0..self.c_csc.nnz()],
                .beta = beta,
            };
        }

        // Compute dense Φ = (A^{-1} β C)^S
        const a_inv = denseInvert(N, a_dense);
        // β · C
        var bc: [N * N]f64 = undefined;
        for (0..N * N) |i| bc[i] = beta * c_dense[i];
        // M = A^{-1} β C
        const m = denseMatMul(N, a_inv, bc);
        // Φ = M^S
        var phi = m;
        for (1..S) |_| phi = denseMatMul(N, m, phi);
        self.dense_phi = phi;
    }

    fn teardown(self: *TestFixture) void {
        for (&self.solvers) |*slv| slv.deinit();
    }
};

test "forward product matches dense Phi*v (3-step constant system)" {
    const gpa = testing.allocator;
    var fix: TestFixture = undefined;
    try fix.setup(gpa);
    defer fix.teardown();

    var mono = try Monodromy(f64).init(
        gpa,
        TestFixture.N,
        &fix.a_csc.col_ptr,
        fix.a_csc.row_idx[0..fix.a_csc.nnz()],
        &fix.records,
    );
    defer mono.deinit(gpa);

    const v = [2]f64{ 1.0, 0.5 };
    var w: [2]f64 = undefined;
    mono.product(&v, &w);

    const w_ref = denseMatVec(2, fix.dense_phi, v);
    for (w, w_ref) |wi, ri| {
        try testing.expectApproxEqRel(ri, wi, 1e-10);
    }
}

test "adjoint product matches dense Phi^T*v" {
    const gpa = testing.allocator;
    var fix: TestFixture = undefined;
    try fix.setup(gpa);
    defer fix.teardown();

    var mono = try Monodromy(f64).init(
        gpa,
        TestFixture.N,
        &fix.a_csc.col_ptr,
        fix.a_csc.row_idx[0..fix.a_csc.nnz()],
        &fix.records,
    );
    defer mono.deinit(gpa);

    const v = [2]f64{ 0.7, -0.3 };
    var z: [2]f64 = undefined;
    mono.adjointProduct(&v, &z);

    const phi_t = denseTranspose(2, fix.dense_phi);
    const z_ref = denseMatVec(2, phi_t, v);
    for (z, z_ref) |zi, ri| {
        try testing.expectApproxEqRel(ri, zi, 1e-10);
    }
}

test "shootingProduct: (Phi-I)*v correct" {
    const gpa = testing.allocator;
    var fix: TestFixture = undefined;
    try fix.setup(gpa);
    defer fix.teardown();

    var mono = try Monodromy(f64).init(
        gpa,
        TestFixture.N,
        &fix.a_csc.col_ptr,
        fix.a_csc.row_idx[0..fix.a_csc.nnz()],
        &fix.records,
    );
    defer mono.deinit(gpa);

    const v = [2]f64{ 1.0, -1.0 };
    var w: [2]f64 = undefined;
    mono.shootingProduct(&v, &w);

    // Reference: Φv - v
    const phiv = denseMatVec(2, fix.dense_phi, v);
    for (w, phiv, v) |wi, pi, vi| {
        try testing.expectApproxEqRel(pi - vi, wi, 1e-10);
    }
}

test "adjointShootingProduct: (Phi-I)^T*v correct" {
    const gpa = testing.allocator;
    var fix: TestFixture = undefined;
    try fix.setup(gpa);
    defer fix.teardown();

    var mono = try Monodromy(f64).init(
        gpa,
        TestFixture.N,
        &fix.a_csc.col_ptr,
        fix.a_csc.row_idx[0..fix.a_csc.nnz()],
        &fix.records,
    );
    defer mono.deinit(gpa);

    const v = [2]f64{ 2.0, 0.5 };
    var z: [2]f64 = undefined;
    mono.adjointShootingProduct(&v, &z);

    // Reference: Φ^T v - v
    const phi_t = denseTranspose(2, fix.dense_phi);
    const ptv = denseMatVec(2, phi_t, v);
    for (z, ptv, v) |zi, pi, vi| {
        try testing.expectApproxEqRel(pi - vi, zi, 1e-10);
    }
}

test "forward/adjoint duality: <Phi*u, v> == <u, Phi^T*v>" {
    // The inner-product identity must hold for arbitrary u, v.
    const gpa = testing.allocator;
    var fix: TestFixture = undefined;
    try fix.setup(gpa);
    defer fix.teardown();

    var mono = try Monodromy(f64).init(
        gpa,
        TestFixture.N,
        &fix.a_csc.col_ptr,
        fix.a_csc.row_idx[0..fix.a_csc.nnz()],
        &fix.records,
    );
    defer mono.deinit(gpa);

    const u = [2]f64{ 1.3, -0.7 };
    const v = [2]f64{ 0.4, 2.1 };

    var phi_u: [2]f64 = undefined;
    mono.product(&u, &phi_u);

    var phi_t_v: [2]f64 = undefined;
    mono.adjointProduct(&v, &phi_t_v);

    // <Φu, v>
    var dot1: f64 = 0;
    for (phi_u, v) |a, b| dot1 += a * b;

    // <u, Φ^T v>
    var dot2: f64 = 0;
    for (u, phi_t_v) |a, b| dot2 += a * b;

    try testing.expectApproxEqRel(dot1, dot2, 1e-10);
}

test "single-step identity: A=I, C=I, beta=1 => Phi=I" {
    // When A = C = I and β = 1, one step gives A^{-1} β C = I, so Φ = I.
    const gpa = testing.allocator;
    const N = 2;

    // Identity CSC: col_ptr = [0,1,2], row_idx = [0,1], vals = [1,1]
    const col_ptr = [3]u32{ 0, 1, 2 };
    const row_idx = [2]u32{ 0, 1 };
    var a_vals = [2]f64{ 1.0, 1.0 };
    const c_vals = [2]f64{ 1.0, 1.0 };

    var slv = try direct.SolverT(f64).init(gpa, N, &col_ptr, &row_idx, null);
    defer slv.deinit();
    try slv.factor(&a_vals);

    var records = [1]Monodromy(f64).StepRecord{.{
        .lu = &slv,
        .c_vals = &c_vals,
        .beta = 1.0,
    }};

    var mono = try Monodromy(f64).init(gpa, N, &col_ptr, &row_idx, &records);
    defer mono.deinit(gpa);

    const v = [2]f64{ 3.0, -7.0 };
    var w: [2]f64 = undefined;
    mono.product(&v, &w);

    for (w, v) |wi, vi| {
        try testing.expectApproxEqAbs(vi, wi, 1e-14);
    }

    // shootingProduct should give zero
    mono.shootingProduct(&v, &w);
    for (w) |wi| {
        try testing.expectApproxEqAbs(@as(f64, 0), wi, 1e-14);
    }
}
