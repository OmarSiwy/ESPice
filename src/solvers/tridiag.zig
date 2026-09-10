//! O(n) Thomas tridiagonal solver for RC ladder / chain topologies.
//!
//! ponytail: no partial pivoting — safe for diagonally-dominant MNA + gmin;
//! upgrade to banded LU with pivoting if non-DD tridiag patterns appear.
//!
//! Data layout (SoA): three u32 CSC-slot arrays (a_pos/b_pos/c_pos) for
//! pattern lookup, three T arrays (bp/mul/cv) for factored numerics.
//! All allocated once at init; factor/solve are zero-alloc.

const std = @import("std");
const Allocator = std.mem.Allocator;

const NONE: u32 = std.math.maxInt(u32);

/// O(nnz) check: true iff pattern is tridiagonal (|row-col| <= 1) and n >= 3.
pub fn isTridiag(n: u32, col_ptr: []const u32, row_idx: []const u32) bool {
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

/// Fetch value from CSC vals at position `pos`, or 0 if pos == NONE.
inline fn triVal(comptime T: type, pos: u32, vals: []const T) T {
    return if (pos != NONE) vals[pos] else 0;
}

/// Thomas-algorithm tridiagonal solver. Monomorphized per element type.
///
/// CSC slot indices are resolved once at init. factor() runs the Thomas
/// forward sweep; solve()/solveT() are in-place forward/back substitutions.
pub fn TriDiag(comptime T: type) type {
    return struct {
        const Self = @This();

        n: u32,
        // CSC slot positions (SoA): sub-diagonal, diagonal, super-diagonal.
        // a_pos[i] = slot for A[i, i-1], b_pos[i] = slot for A[i, i],
        // c_pos[i] = slot for A[i, i+1]. NONE if structurally absent.
        a_pos: []u32,
        b_pos: []u32,
        c_pos: []u32,
        // Factored values (SoA, hot path):
        // bp[i] = modified diagonal, mul[i] = elimination multiplier,
        // cv[i] = super-diagonal value (cached from vals).
        bp: []T,
        mul: []T,
        cv: []T,

        pub const FactorError = error{SingularMatrix};

        /// Build slot maps from CSC pattern. Caller must have verified
        /// isTridiag() == true. All memory allocated upfront from `gpa`.
        pub fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32) !Self {
            std.debug.assert(n >= 3);

            const a_pos = try gpa.alloc(u32, n);
            errdefer gpa.free(a_pos);
            const b_pos = try gpa.alloc(u32, n);
            errdefer gpa.free(b_pos);
            const c_pos = try gpa.alloc(u32, n);
            errdefer gpa.free(c_pos);
            const bp = try gpa.alloc(T, n);
            errdefer gpa.free(bp);
            const mul = try gpa.alloc(T, n);
            errdefer gpa.free(mul);

            var self = Self{
                .n = n,
                .a_pos = a_pos,
                .b_pos = b_pos,
                .c_pos = c_pos,
                .bp = bp,
                .mul = mul,
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
                        // A[j+1, j] is the sub-diagonal entry: a_pos[j+1]
                        self.a_pos[j + 1] = @intCast(p);
                    } else if (j > 0 and r + 1 == j) {
                        // A[r, j] where r = j-1 is the super-diagonal: c_pos[r]
                        self.c_pos[r] = @intCast(p);
                    }
                }
            }

            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            inline for (.{ self.a_pos, self.b_pos, self.c_pos }) |s| gpa.free(s);
            inline for (.{ self.bp, self.mul, self.cv }) |s| gpa.free(s);
        }

        /// Thomas forward sweep: compute modified diagonals (bp),
        /// elimination multipliers (mul), and cache super-diagonal values (cv).
        /// Returns SingularMatrix if any modified pivot is zero or non-finite.
        pub fn factor(self: *Self, vals: []const T) FactorError!void {
            const n = self.n;

            self.bp[0] = triVal(T, self.b_pos[0], vals);
            if (self.bp[0] == 0 or !std.math.isFinite(self.bp[0])) return error.SingularMatrix;
            self.cv[0] = triVal(T, self.c_pos[0], vals);

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

        /// Solve Ax = x in-place. Requires prior factor().
        /// Forward sweep eliminates sub-diagonal, back sub divides by bp.
        pub fn solve(self: *Self, x: []T) void {
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

        /// Solve A^T x = x in-place. A = LU, so A^T = U^T L^T.
        /// U^T is lower bidiagonal (diag=bp, sub=cv[i-1] at row i).
        /// L^T is upper bidiagonal (diag=1, super=mul[i+1] at row i).
        pub fn solveT(self: *Self, x: []T) void {
            const n = self.n;
            // Forward sub: U^T y = b (lower bidiagonal)
            x[0] /= self.bp[0];
            for (1..n) |i| x[i] = (x[i] - self.cv[i - 1] * x[i - 1]) / self.bp[i];
            // Back sub: L^T x = y (upper bidiagonal)
            var i: usize = n - 1;
            while (i > 0) {
                i -= 1;
                x[i] -= self.mul[i + 1] * x[i + 1];
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Build CSC from dense row-major matrix (test helper, comptime).
fn CscResult(comptime n: usize, comptime nnz: usize) type {
    return struct {
        col_ptr: [n + 1]u32,
        row_idx: [nnz]u32,
        vals: [nnz]f64,
    };
}

fn countNnz(comptime n: usize, comptime dense: *const [n * n]f64) usize {
    var count: usize = 0;
    for (dense) |v| count += @intFromBool(v != 0);
    return count;
}

fn cscFromDense(comptime n: usize, comptime dense: *const [n * n]f64) CscResult(n, countNnz(n, dense)) {
    const nnz = comptime countNnz(n, dense);
    var col_ptr: [n + 1]u32 = undefined;
    var row_idx: [nnz]u32 = undefined;
    var vals: [nnz]f64 = undefined;

    var p: u32 = 0;
    col_ptr[0] = 0;
    for (0..n) |j| {
        for (0..n) |i| {
            const v = dense[i * n + j];
            if (v != 0) {
                row_idx[p] = @intCast(i);
                vals[p] = v;
                p += 1;
            }
        }
        col_ptr[j + 1] = p;
    }

    return .{ .col_ptr = col_ptr, .row_idx = row_idx, .vals = vals };
}

/// Dense solve Ax = b for reference (Gaussian elimination with partial pivoting).
fn denseSolve(comptime n: usize, mat: [n * n]f64, rhs: [n]f64) [n]f64 {
    var a = mat;
    var b = rhs;
    // Forward elimination with partial pivoting
    for (0..n) |k| {
        // Find pivot
        var max_val: f64 = @abs(a[k * n + k]);
        var max_row: usize = k;
        for (k + 1..n) |i| {
            const v = @abs(a[i * n + k]);
            if (v > max_val) {
                max_val = v;
                max_row = i;
            }
        }
        // Swap rows
        if (max_row != k) {
            for (0..n) |j| std.mem.swap(f64, &a[k * n + j], &a[max_row * n + j]);
            std.mem.swap(f64, &b[k], &b[max_row]);
        }
        // Eliminate
        for (k + 1..n) |i| {
            const m = a[i * n + k] / a[k * n + k];
            for (k + 1..n) |j| a[i * n + j] -= m * a[k * n + j];
            b[i] -= m * b[k];
        }
    }
    // Back substitution
    var x: [n]f64 = undefined;
    var ki: usize = n;
    while (ki > 0) {
        ki -= 1;
        var s = b[ki];
        for (ki + 1..n) |j| s -= a[ki * n + j] * x[j];
        x[ki] = s / a[ki * n + ki];
    }
    return x;
}

/// Transpose a dense row-major matrix.
fn denseTranspose(comptime n: usize, mat: [n * n]f64) [n * n]f64 {
    var t: [n * n]f64 = undefined;
    for (0..n) |i| for (0..n) |j| {
        t[i * n + j] = mat[j * n + i];
    };
    return t;
}

test "TriDiag: 4x4 factor + solve vs dense reference" {
    const gpa = testing.allocator;
    // 4x4 tridiagonal:
    // [4  1  0  0]
    // [1  5  2  0]
    // [0  1  6  3]
    // [0  0  2  7]
    const dense = [16]f64{
        4, 1, 0, 0,
        1, 5, 2, 0,
        0, 1, 6, 3,
        0, 0, 2, 7,
    };
    const csc = cscFromDense(4, &dense);

    var td = try TriDiag(f64).init(gpa, 4, &csc.col_ptr, &csc.row_idx);
    defer td.deinit(gpa);

    try td.factor(&csc.vals);

    const rhs = [4]f64{ 7, 13, 20, 23 };
    var x = rhs;
    td.solve(&x);

    const ref = denseSolve(4, dense, rhs);
    for (0..4) |i| {
        try testing.expectApproxEqAbs(ref[i], x[i], 1e-12);
    }
}

test "TriDiag: solveT matches dense A^T solve" {
    const gpa = testing.allocator;
    const dense = [16]f64{
        4, 1, 0, 0,
        1, 5, 2, 0,
        0, 1, 6, 3,
        0, 0, 2, 7,
    };
    const csc = cscFromDense(4, &dense);

    var td = try TriDiag(f64).init(gpa, 4, &csc.col_ptr, &csc.row_idx);
    defer td.deinit(gpa);

    try td.factor(&csc.vals);

    const rhs = [4]f64{ 3, 9, 15, 21 };
    var x = rhs;
    td.solveT(&x);

    const at = denseTranspose(4, dense);
    const ref = denseSolve(4, at, rhs);
    for (0..4) |i| {
        try testing.expectApproxEqAbs(ref[i], x[i], 1e-12);
    }
}

test "TriDiag: singular detection (zero pivot)" {
    const gpa = testing.allocator;
    // Singular: second row becomes zero after elimination.
    // [1  1  0]
    // [1  1  0]   <- row 2 = row 1 => zero pivot
    // [0  0  1]
    const dense = [9]f64{
        1, 1, 0,
        1, 1, 0,
        0, 0, 1,
    };
    const csc = cscFromDense(3, &dense);

    var td = try TriDiag(f64).init(gpa, 3, &csc.col_ptr, &csc.row_idx);
    defer td.deinit(gpa);

    try testing.expectError(error.SingularMatrix, td.factor(&csc.vals));
}

test "isTridiag: tridiag detected" {
    // 4x4 tridiag
    const dense = [16]f64{
        4, 1, 0, 0,
        1, 5, 2, 0,
        0, 1, 6, 3,
        0, 0, 2, 7,
    };
    const csc = cscFromDense(4, &dense);
    try testing.expect(isTridiag(4, &csc.col_ptr, &csc.row_idx));
}

test "isTridiag: non-tridiag rejected" {
    // 4x4 with an off-tridiag entry at A[0,2]
    const dense = [16]f64{
        4, 1, 1, 0,
        1, 5, 2, 0,
        0, 1, 6, 3,
        0, 0, 2, 7,
    };
    const csc = cscFromDense(4, &dense);
    try testing.expect(!isTridiag(4, &csc.col_ptr, &csc.row_idx));
}

test "isTridiag: n < 3 rejected" {
    const col_ptr = [3]u32{ 0, 1, 2 };
    const row_idx = [2]u32{ 0, 1 };
    try testing.expect(!isTridiag(2, &col_ptr, &row_idx));
}

test "TriDiag: f32 factor + solve" {
    const gpa = testing.allocator;
    // 3x3 tridiag with f32
    const dense = [9]f64{
        3, 1, 0,
        1, 4, 2,
        0, 1, 5,
    };
    const csc = cscFromDense(3, &dense);

    var td = try TriDiag(f32).init(gpa, 3, &csc.col_ptr, &csc.row_idx);
    defer td.deinit(gpa);

    // Convert vals to f32
    var vals32: [csc.vals.len]f32 = undefined;
    for (csc.vals, 0..) |v, i| vals32[i] = @floatCast(v);

    try td.factor(&vals32);

    var x = [3]f32{ 5, 11, 12 };
    td.solve(&x);

    // Dense reference in f64, then compare with f32 tolerance
    const rhs64 = [3]f64{ 5, 11, 12 };
    const ref = denseSolve(3, dense, rhs64);
    for (0..3) |i| {
        try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[i])), x[i], 1e-5);
    }
}
