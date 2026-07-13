//! Matrix-free restarted GMRES(m) with optional right preconditioning, for
//! the PSS monodromy and QPSS Krylov solves. All workspace is allocated by
//! `init`; `solve` allocates nothing. Background:
//! docs/solvers/monodromy-krylov.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const num = @import("core").numerics;

/// GMRES(m) workspace for n-dimensional systems.
pub const Gmres = struct {
    const Self = @This();
    /// What `solve` reached; `x` holds its best iterate either way.
    pub const SolveResult = struct {
        /// Arnoldi steps across all restarts.
        iterations: u32,
        /// ||b - A x|| / ||b||: the Givens estimate when a cycle converged,
        /// the true residual otherwise.
        residual: f64,
        converged: bool,
    };

    n: u32,
    /// Restart depth.
    m: u32,

    /// Arnoldi basis: v_k is v_basis[k*n..][0..n], m + 1 vectors.
    v_basis: []f64,
    /// Upper Hessenberg, (m + 1) x m row-major.
    h: []f64,
    /// Givens rotations.
    cs: []f64,
    sn: []f64,
    /// Rotated right-hand side, m + 1 entries.
    g: []f64,
    /// Triangular-solve result, m entries.
    y: []f64,
    // Scratch, n entries each.
    w: []f64,
    r: []f64,

    /// Allocates (m + 1)(n + m) + 2n + 4m + 1 f64s. Asserts that n and m
    /// are positive. Caller frees with `deinit` and the same allocator.
    pub fn init(gpa: Allocator, n: u32, m: u32) !Self {
        std.debug.assert(n > 0);
        std.debug.assert(m > 0);
        const nu: usize = n;
        const mu: usize = m;

        const v_basis = try gpa.alloc(f64, (mu + 1) * nu);
        errdefer gpa.free(v_basis);
        const h = try gpa.alloc(f64, (mu + 1) * mu);
        errdefer gpa.free(h);
        const cs = try gpa.alloc(f64, mu);
        errdefer gpa.free(cs);
        const sn = try gpa.alloc(f64, mu);
        errdefer gpa.free(sn);
        const g_ws = try gpa.alloc(f64, mu + 1);
        errdefer gpa.free(g_ws);
        const y_ws = try gpa.alloc(f64, mu);
        errdefer gpa.free(y_ws);
        const w_ws = try gpa.alloc(f64, nu);
        errdefer gpa.free(w_ws);
        const r_ws = try gpa.alloc(f64, nu);

        return .{
            .n = n,
            .m = m,
            .v_basis = v_basis,
            .h = h,
            .cs = cs,
            .sn = sn,
            .g = g_ws,
            .y = y_ws,
            .w = w_ws,
            .r = r_ws,
        };
    }

    /// Frees the workspace; `gpa` must be the allocator `init` got.
    pub fn deinit(self: *Self, gpa: Allocator) void {
        inline for (.{ self.v_basis, self.h, self.cs, self.sn, self.g, self.y, self.w, self.r }) |s| gpa.free(s);
        self.* = undefined;
    }

    /// Solves A x = b. `op` points at the caller's operator:
    /// `op.matvec(v, w)` writes w = A v, and `op.precond(r)`, when its
    /// type declares one, applies M^-1 in place for a right
    /// preconditioned solve. `x` holds the initial guess and receives
    /// the solution. Stops at ||r|| <= tol * ||b|| or after
    /// `max_restarts + 1` cycles. A zero `b` returns x = 0 at once; a
    /// non-finite one never converges. On a singular A convergence is
    /// judged by the true residual, never by a Givens estimate that cannot
    /// see what it left. Asserts that `b` and `x` hold at least n entries.
    pub fn solve(
        self: *Self,
        op: anytype,
        b: []const f64,
        x: []f64,
        tol: f64,
        max_restarts: u32,
    ) SolveResult {
        const n: usize = self.n;
        const m: usize = self.m;
        const has_precond = comptime @hasDecl(std.meta.Child(@TypeOf(op)), "precond");
        std.debug.assert(b.len >= n);
        std.debug.assert(x.len >= n);

        const b_norm = vecNorm(b[0..n]);
        if (b_norm == 0) {
            @memset(x[0..n], 0);
            return .{ .iterations = 0, .residual = 0, .converged = true };
        }
        const abs_tol = tol * b_norm;

        var total_iters: u32 = 0;

        for (0..max_restarts + 1) |_| {
            op.matvec(x[0..n], self.r[0..n]);
            self.residual(b[0..n]);

            const beta = vecNorm(self.r[0..n]);
            if (beta <= abs_tol) {
                return .{ .iterations = total_iters, .residual = beta / b_norm, .converged = true };
            }

            const v0 = self.getV(0);
            num.scale(v0, 1.0 / beta, self.r[0..n]);

            @memset(self.g[0 .. m + 1], 0);
            self.g[0] = beta;

            var j: u32 = 0;
            while (j < m) : (j += 1) {
                const ju: usize = j;
                total_iters += 1;

                const vj = self.getV(j);

                // z = A M^-1 v_j, into r.
                if (has_precond) {
                    @memcpy(self.w[0..n], vj);
                    op.precond(self.w[0..n]);
                    op.matvec(self.w[0..n], self.r[0..n]);
                } else {
                    op.matvec(vj, self.r[0..n]);
                }

                // Modified Gram-Schmidt.
                for (0..ju + 1) |i| {
                    const vi = self.getV(@intCast(i));
                    const hij = num.dot(self.r[0..n], vi);
                    self.h[i * m + ju] = hij;
                    num.axpy(self.r[0..n], -hij, vi);
                }

                const h_jp1_j = vecNorm(self.r[0..n]);
                self.h[(ju + 1) * m + ju] = h_jp1_j;

                if (h_jp1_j != 0) {
                    const vjp1 = self.getV(j + 1);
                    num.scale(vjp1, 1.0 / h_jp1_j, self.r[0..n]);
                }

                self.applyPreviousGivens(j);
                const hjj = self.h[ju * m + ju];
                const hjp1j = self.h[(ju + 1) * m + ju];
                const rot = givensRotation(hjj, hjp1j);
                self.cs[ju] = rot.c;
                self.sn[ju] = rot.s;

                self.h[ju * m + ju] = rot.c * hjj + rot.s * hjp1j;
                self.h[(ju + 1) * m + ju] = 0;

                const g_j = self.g[ju];
                const g_jp1 = self.g[ju + 1];
                self.g[ju] = rot.c * g_j + rot.s * g_jp1;
                self.g[ju + 1] = -rot.s * g_j + rot.c * g_jp1;

                // Breakdown or convergence.
                if (h_jp1_j == 0 or @abs(self.g[ju + 1]) <= abs_tol) {
                    j += 1;
                    break;
                }
            }

            const k = j; // Arnoldi steps completed, at least 1
            const singular = self.solveUpperTriangular(k);
            self.updateSolution(x[0..n], k, op);

            // A rank-deficient R leaves g[k] blind to the part of the
            // residual it could not reduce, so the next cycle's head (or
            // the tail) measures the true one instead.
            const res_norm = @abs(self.g[k]);
            if (!singular and res_norm <= abs_tol) {
                return .{ .iterations = total_iters, .residual = res_norm / b_norm, .converged = true };
            }
        }

        op.matvec(x[0..n], self.r[0..n]);
        self.residual(b[0..n]);
        const final_res = vecNorm(self.r[0..n]);
        return .{ .iterations = total_iters, .residual = final_res / b_norm, .converged = final_res <= abs_tol };
    }

    /// r = b - r.
    fn residual(self: *Self, b: []const f64) void {
        num.sub(self.r[0..b.len], b, self.r[0..b.len]);
    }

    inline fn getV(self: *Self, i: u32) []f64 {
        const off: usize = @as(usize, i) * @as(usize, self.n);
        return self.v_basis[off..][0..self.n];
    }

    /// Applies rotations 0..j-1 to column j of H.
    fn applyPreviousGivens(self: *Self, j: u32) void {
        const m: usize = self.m;
        const ju: usize = j;
        for (0..ju) |i| {
            const c = self.cs[i];
            const s = self.sn[i];
            const h_ij = self.h[i * m + ju];
            const h_ip1j = self.h[(i + 1) * m + ju];
            self.h[i * m + ju] = c * h_ij + s * h_ip1j;
            self.h[(i + 1) * m + ju] = -s * h_ij + c * h_ip1j;
        }
    }

    /// y = H^-1 g over the leading k x k triangle. A diagonal at or below
    /// eps times the largest (a singular operator; rounding rarely leaves
    /// an exact zero) sets that component to zero. Returns whether one did.
    fn solveUpperTriangular(self: *Self, k: u32) bool {
        const m: usize = self.m;
        const ku: usize = k;
        var d_max: f64 = 0;
        for (0..ku) |i| d_max = @max(d_max, @abs(self.h[i * m + i]));
        const floor = std.math.floatEps(f64) * d_max;
        var singular = false;
        @memcpy(self.y[0..ku], self.g[0..ku]);
        var i: usize = ku;
        while (i > 0) {
            i -= 1;
            for (i + 1..ku) |jj| {
                self.y[i] -= self.h[i * m + jj] * self.y[jj];
            }
            const diag = self.h[i * m + i];
            if (@abs(diag) <= floor) {
                self.y[i] = 0;
                singular = true;
            } else {
                self.y[i] /= diag;
            }
        }
        return singular;
    }

    /// x += M^-1 V_k y.
    fn updateSolution(
        self: *Self,
        x: []f64,
        k: u32,
        op: anytype,
    ) void {
        const n: usize = self.n;
        if (comptime @hasDecl(std.meta.Child(@TypeOf(op)), "precond")) {
            @memset(self.w[0..n], 0);
            for (0..k) |j| {
                const vj = self.getV(@intCast(j));
                num.axpy(self.w[0..n], self.y[j], vj);
            }
            op.precond(self.w[0..n]);
            num.axpy(x, 1, self.w[0..n]);
        } else {
            for (0..k) |j| {
                const vj = self.getV(@intCast(j));
                num.axpy(x, self.y[j], vj);
            }
        }
    }

    fn vecNorm(v: []const f64) f64 {
        return @sqrt(num.dot(v, v));
    }
};

/// c, s with [c s; -s c] [a; b] = [r; 0].
fn givensRotation(a: anytype, b: @TypeOf(a)) struct { c: @TypeOf(a), s: @TypeOf(a) } {
    if (b == 0) return .{ .c = 1, .s = 0 };
    if (a == 0) return .{ .c = 0, .s = std.math.sign(b) };
    const r = @sqrt(a * a + b * b);
    return .{ .c = a / r, .s = b / r };
}
