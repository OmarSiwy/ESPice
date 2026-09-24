//! Frequency sweep in bounded lane chunks: one shared rhs, lane axis =
//! frequency. At most `quantum` solutions are live at once, so a sweep holds
//! quantum·2n values instead of points·2n.
const std = @import("std");
const root = @import("../types.zig");
const FreqSolver = @import("solvers").freq_solve.FreqSolver;

// ponytail: 64 frequencies per chunk and per checkpoint; expose a work budget
// if callers need another latency/throughput tradeoff. A factorization is atomic.
pub const quantum: usize = 64;

/// Point k's stacked-real solution `[re(0..n), im(0..n)]`, valid until the
/// next `next` call.
pub const Point = struct { k: usize, x: []const f64 };

/// Walks `omegas` in order. Chunking cannot move a bit: lanes are independent
/// and the pivot tape carries across `solveBatch` calls the same way it
/// carries across its internal W-chunks.
pub const Stream = struct {
    fs: *FreqSolver,
    omegas: []const f64,
    rhs: []const f64,
    adjoint: bool,
    buf: []f64,
    /// Chunk in `buf` covers omegas[base..end]; `k` is the next point out.
    base: usize = 0,
    end: usize = 0,
    k: usize = 0,

    pub fn init(allocator: std.mem.Allocator, fs: *FreqSolver, omegas: []const f64, rhs: []const f64, adjoint: bool) !Stream {
        const buf = try allocator.alloc(f64, @min(quantum, omegas.len) * @as(usize, fs.nn));
        return .{ .fs = fs, .omegas = omegas, .rhs = rhs, .adjoint = adjoint, .buf = buf };
    }

    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    pub fn next(self: *Stream, ckt: *root.Circuit) !?Point {
        const nn: usize = self.fs.nn;
        if (self.k == self.end) {
            if (self.end == self.omegas.len) return null;
            self.base = self.end;
            self.end += @min(quantum, self.omegas.len - self.base);
            try self.fs.solveBatch(self.omegas[self.base..self.end], self.rhs, self.buf[0 .. (self.end - self.base) * nn], self.adjoint);
            try ckt.checkpoint(.{ .phase = .frequency, .completed = self.end, .total = self.omegas.len });
        }
        defer self.k += 1;
        return .{ .k = self.k, .x = self.buf[(self.k - self.base) * nn ..][0..nn] };
    }
};
