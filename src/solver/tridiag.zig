//! O(n) Thomas solver for tridiagonal patterns (RC ladders, chains).
//! No pivoting: a zero or non-finite pivot fails the factor and `direct`
//! demotes the system to the pivoting sparse LU.

const std = @import("std");
const Allocator = std.mem.Allocator;

const NONE: u32 = std.math.maxInt(u32);

/// True when every entry has |row - col| <= 1 and n >= 3. O(nnz).
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

inline fn triVal(comptime T: type, pos: u32, vals: []const T) T {
    return if (pos != NONE) vals[pos] else 0;
}

/// Thomas-algorithm solver. CSC slots are resolved once at `init`;
/// `factor`, `solve` and `solveT` allocate nothing.
pub fn TriDiag(comptime T: type) type {
    return struct {
        const Self = @This();

        n: u32,
        /// CSC slots of A[i,i-1], A[i,i] and A[i,i+1]; NONE when absent.
        a_pos: []u32,
        b_pos: []u32,
        c_pos: []u32,
        /// Modified diagonal, elimination multiplier and super-diagonal value.
        bp: []T,
        mul: []T,
        cv: []T,

        pub const FactorError = error{SingularMatrix};

        /// Builds the slot maps. The pattern must pass `isTridiag`.
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
                        self.a_pos[j + 1] = @intCast(p);
                    } else if (j > 0 and r + 1 == j) {
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

        /// Thomas forward sweep. Fails when a modified pivot is zero or
        /// non-finite.
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

        /// x = A^-1 x after a successful `factor`.
        pub fn solve(self: *Self, x: []T) void {
            const n = self.n;
            for (1..n) |i| x[i] -= self.mul[i] * x[i - 1];
            x[n - 1] /= self.bp[n - 1];
            var i: usize = n - 1;
            while (i > 0) {
                i -= 1;
                x[i] = (x[i] - self.cv[i] * x[i + 1]) / self.bp[i];
            }
        }

        /// x = A^-T x after a successful `factor`: forward through U^T
        /// (diagonal bp, sub-diagonal cv), then back through unit L^T.
        pub fn solveT(self: *Self, x: []T) void {
            const n = self.n;
            x[0] /= self.bp[0];
            for (1..n) |i| x[i] = (x[i] - self.cv[i - 1] * x[i - 1]) / self.bp[i];
            var i: usize = n - 1;
            while (i > 0) {
                i -= 1;
                x[i] -= self.mul[i + 1] * x[i + 1];
            }
        }
    };
}
