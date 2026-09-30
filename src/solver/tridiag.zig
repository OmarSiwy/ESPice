//! O(n) Thomas solver for tridiagonal patterns (RC ladders, chains).
//! No pivoting: a pivot threshold pivoting would not keep fails the factor
//! and `direct` demotes the system to the pivoting sparse LU (#45).
//! In: a tridiagonal CSC pattern and its values. Out: solutions of A x = b
//! and A^T x = b.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const NONE: u32 = std.math.maxInt(u32);

/// True when every entry has |row - col| <= 1 and n >= 3. O(nnz). Asserts
/// that `col_ptr` has n + 1 entries.
pub fn isTridiag(n: u32, col_ptr: []const u32, row_idx: []const u32) bool {
    assert(col_ptr.len == @as(usize, n) + 1);
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

inline fn triVal(pos: u32, vals: []const f64) f64 {
    return if (pos != NONE) vals[pos] else 0;
}

/// Thomas-algorithm solver. CSC slots are resolved once at `init`;
/// `factor`, `solve` and `solveT` allocate nothing.
pub const TriDiag = struct {
    const Self = @This();

    n: u32,
    /// CSC slots of A[i,i-1], A[i,i] and A[i,i+1]; NONE when absent.
    a_pos: []u32,
    b_pos: []u32,
    c_pos: []u32,
    /// Modified diagonal, elimination multiplier and super-diagonal value.
    bp: []f64,
    mul: []f64,
    cv: []f64,

    /// `SingularMatrix`: a modified pivot is zero, non-finite or too small
    /// against its column. Thomas does not pivot, so this covers
    /// nonsingular matrices too.
    pub const FactorError = error{SingularMatrix};

    /// Builds the slot maps. Borrows nothing. Free with `deinit`. Asserts
    /// that the pattern passes `isTridiag`, which needs n >= 3.
    pub fn init(gpa: Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32) !Self {
        assert(isTridiag(n, col_ptr, row_idx));

        const a_pos = try gpa.alloc(u32, n);
        errdefer gpa.free(a_pos);
        const b_pos = try gpa.alloc(u32, n);
        errdefer gpa.free(b_pos);
        const c_pos = try gpa.alloc(u32, n);
        errdefer gpa.free(c_pos);
        const bp = try gpa.alloc(f64, n);
        errdefer gpa.free(bp);
        const mul = try gpa.alloc(f64, n);
        errdefer gpa.free(mul);

        var self = Self{
            .n = n,
            .a_pos = a_pos,
            .b_pos = b_pos,
            .c_pos = c_pos,
            .bp = bp,
            .mul = mul,
            .cv = try gpa.alloc(f64, n),
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

    /// Frees the slot maps and factors.
    pub fn deinit(self: *Self, gpa: Allocator) void {
        inline for (.{ self.a_pos, self.b_pos, self.c_pos }) |s| gpa.free(s);
        inline for (.{ self.bp, self.mul, self.cv }) |s| gpa.free(s);
    }

    /// Thomas forward sweep, O(n). Fails when a modified pivot is zero or
    /// non-finite, or below `pivot_tol` times the entry under it: the test
    /// threshold partial pivoting would keep the diagonal by, so the sparse
    /// LU `direct` demotes to pivots where Thomas cannot (#45). The factors
    /// are then unusable. Asserts that `pivot_tol` is not negative.
    pub fn factor(self: *Self, vals: []const f64, pivot_tol: f64) FactorError!void {
        const n = self.n;
        assert(n >= 3);
        assert(pivot_tol >= 0);

        self.bp[0] = triVal(self.b_pos[0], vals);
        self.cv[0] = triVal(self.c_pos[0], vals);
        for (0..n) |i| {
            if (i > 0) {
                const m = triVal(self.a_pos[i], vals) / self.bp[i - 1];
                self.mul[i] = m;
                self.bp[i] = triVal(self.b_pos[i], vals) - m * self.cv[i - 1];
                if (i + 1 < n) self.cv[i] = triVal(self.c_pos[i], vals);
            }
            const d = @abs(self.bp[i]);
            const below = if (i + 1 < n) @abs(triVal(self.a_pos[i + 1], vals)) else 0;
            // Negated, so a NaN pivot fails too.
            if (!(d > 0 and d < std.math.inf(f64) and d >= pivot_tol * below)) return error.SingularMatrix;
        }
    }

    /// x = A^-1 x after a successful `factor`, O(n). Asserts that `x` has n
    /// entries.
    pub fn solve(self: *Self, x: []f64) void {
        const n = self.n;
        assert(x.len == n);
        for (1..n) |i| x[i] -= self.mul[i] * x[i - 1];
        x[n - 1] /= self.bp[n - 1];
        var i: usize = n - 1;
        while (i > 0) {
            i -= 1;
            x[i] = (x[i] - self.cv[i] * x[i + 1]) / self.bp[i];
        }
    }

    /// x = A^-T x after a successful `factor`: forward through U^T
    /// (diagonal bp, sub-diagonal cv), then back through unit L^T. Asserts
    /// that `x` has n entries.
    pub fn solveT(self: *Self, x: []f64) void {
        const n = self.n;
        assert(x.len == n);
        x[0] /= self.bp[0];
        for (1..n) |i| x[i] = (x[i] - self.cv[i - 1] * x[i - 1]) / self.bp[i];
        var i: usize = n - 1;
        while (i > 0) {
            i -= 1;
            x[i] -= self.mul[i + 1] * x[i + 1];
        }
    }
};

test "TriDiag: random diagonally dominant ladders solve both ways; NaN, Inf and absent entries" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7d1a);
    const r = prng.random();
    var col_ptr: [65]u32 = undefined;
    var row_idx: [3 * 64]u32 = undefined;
    var vals: [3 * 64]f64 = undefined;
    var dense: [64][64]f64 = undefined;
    for (3..65) |n| {
        // Band entries, each off-diagonal absent one time in five.
        for (0..n) |i| @memset(dense[i][0..n], 0);
        for (0..n) |i| {
            for ([_]usize{ i -| 1, i + 1 }) |j| {
                if (j == i or j >= n or r.uintLessThan(u8, 5) == 0) continue;
                dense[i][j] = 2 * r.float(f64) - 1;
            }
            dense[i][i] = 3 + r.float(f64);
        }
        var p: u32 = 0;
        col_ptr[0] = 0;
        for (0..n) |j| {
            for (j -| 1..@min(j + 2, n)) |i| {
                if (i != j and dense[i][j] == 0) continue;
                row_idx[p] = @intCast(i);
                vals[p] = dense[i][j];
                p += 1;
            }
            col_ptr[j + 1] = p;
        }
        const nn: u32 = @intCast(n);
        try testing.expect(isTridiag(nn, col_ptr[0 .. n + 1], row_idx[0..p]));
        var td = try TriDiag.init(gpa, nn, col_ptr[0 .. n + 1], row_idx[0..p]);
        defer td.deinit(gpa);
        try td.factor(vals[0..p], 1e-3);
        var x: [64]f64 = undefined;
        var b: [64]f64 = undefined;
        for (b[0..n]) |*v| v.* = 2 * r.float(f64) - 1;
        inline for (.{ false, true }) |transpose| {
            @memcpy(x[0..n], b[0..n]);
            if (transpose) td.solveT(x[0..n]) else td.solve(x[0..n]);
            for (0..n) |i| {
                var ri = b[i];
                for (0..n) |j| ri -= (if (transpose) dense[j][i] else dense[i][j]) * x[j];
                try testing.expect(@abs(ri) < 1e-13);
            }
        }
        // A non-finite entry anywhere in the band poisons a pivot.
        const bad = r.uintLessThan(u32, p);
        const keep = vals[bad];
        vals[bad] = if (r.boolean()) std.math.nan(f64) else std.math.inf(f64);
        try testing.expectError(error.SingularMatrix, td.factor(vals[0..p], 1e-3));
        vals[bad] = keep;
    }
}
