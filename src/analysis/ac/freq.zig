//! Frequency sweep in bounded lane chunks. Every point solves against one
//! shared rhs, and the lane axis is frequency (`FreqSolver.solveBatch`). At
//! most `quantum` solutions are live at once, so a sweep holds quantum·2n
//! values instead of points·2n.
const std = @import("std");
const root = @import("../types.zig");
const FreqSolver = @import("solver").freq_solve.FreqSolver;

// ponytail: fixed at 64; expose a work budget if a caller needs another
// latency/throughput tradeoff. One factorization is never split.
/// Frequencies per `solveBatch` call and per progress checkpoint.
pub const quantum: usize = 64;

/// Point k's stacked-real solution `[re(0..n), im(0..n)]`, valid until the
/// next `next` call.
pub const Point = struct { k: usize, x: []const f64 };

/// Iterator over the solutions of `omegas`, in order. Chunking cannot change a
/// bit of the result: lanes are independent, and the pivot tape carries across
/// `solveBatch` calls the same way it carries across its internal W-chunks.
/// Borrows `fs`, `omegas` and `rhs` for its whole life.
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

    /// Allocates the chunk buffer; free it with `deinit`.
    pub fn init(allocator: std.mem.Allocator, fs: *FreqSolver, omegas: []const f64, rhs: []const f64, adjoint: bool) !Stream {
        const buf = try allocator.alloc(f64, @min(quantum, omegas.len) * @as(usize, fs.nn));
        return .{ .fs = fs, .omegas = omegas, .rhs = rhs, .adjoint = adjoint, .buf = buf };
    }

    /// Frees the chunk buffer; points returned so far become invalid.
    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    /// Returns the next point, or null past the last one. Solves a new chunk
    /// when the current one is spent, then checkpoints `ckt` (which may
    /// return error.QueryCancelled).
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
