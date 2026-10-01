//! Frequency sweep in bounded lane chunks. Every point solves against the
//! same right-hand sides (one for ac, stb and noise, one per port for sp),
//! and the lane axis is frequency (`FreqSolver.solveBatch`). One lane pass,
//! `FreqSolver.W` points, is live at once, so a sweep holds W·rhs.len values
//! instead of points·rhs.len.
const std = @import("std");
const root = @import("../types.zig");
const FreqSolver = @import("solver").freq_solve.FreqSolver;
const Dyn = @import("solver").freq_solve.Dyn;

// ponytail: fixed at 64; expose a work budget if a caller needs another
// latency/throughput tradeoff. One factorization is never split.
/// Frequencies per progress checkpoint; a multiple of every `FreqSolver.W`.
pub const quantum: usize = 64;
const lanes = FreqSolver.W;
comptime {
    std.debug.assert(quantum % lanes == 0);
}

/// Point k's stacked-real solutions `[re(0..n), im(0..n)]`, one per 2n block
/// of the stream's rhs, valid until the next `next` call.
pub const Point = struct { k: usize, x: []const f64 };

/// Iterator over the solutions of `omegas`, in order. Chunking cannot change a
/// bit of the result: lanes are independent, and the pivot tape carries across
/// `solveBatch` calls the same way it carries across its internal W-chunks.
/// Each chunk adds the circuit's frequency-dependent terms at `x_op`
/// (`Circuit.acDyn`). Borrows `fs`, `x_op`, `omegas` and `rhs` for its whole
/// life.
pub const Stream = struct {
    fs: *FreqSolver,
    x_op: []const f64,
    omegas: []const f64,
    rhs: []const f64,
    adjoint: bool,
    buf: []f64,
    /// A chunk's `acDyn` terms, re then im, each `ac_dyn_slots.len` rows of
    /// up to `lanes` points.
    dyn: []f64,
    /// Chunk in `buf` covers omegas[base..end]; `k` is the next point out.
    base: usize = 0,
    end: usize = 0,
    k: usize = 0,

    /// Allocates the chunk buffers for `ckt`, the circuit `fs` linearized;
    /// free them with `deinit`.
    pub fn init(allocator: std.mem.Allocator, fs: *FreqSolver, ckt: *const root.Circuit, x_op: []const f64, omegas: []const f64, rhs: []const f64, adjoint: bool) !Stream {
        const buf = try allocator.alloc(f64, @min(lanes, omegas.len) * rhs.len);
        errdefer allocator.free(buf);
        const dyn = try allocator.alloc(f64, 2 * ckt.ac_dyn_slots.len * @min(lanes, omegas.len));
        return .{ .fs = fs, .x_op = x_op, .omegas = omegas, .rhs = rhs, .adjoint = adjoint, .buf = buf, .dyn = dyn };
    }

    /// Frees the chunk buffers; points returned so far become invalid.
    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        allocator.free(self.dyn);
    }

    /// Returns the next point, or null past the last one. Solves a new chunk
    /// when the current one is spent, then checkpoints `ckt` (which may
    /// return error.QueryCancelled) every `quantum` points and at the end.
    pub fn next(self: *Stream, ckt: *root.Circuit) !?Point {
        const m = self.rhs.len;
        if (self.k == self.end) {
            if (self.end == self.omegas.len) return null;
            self.base = self.end;
            self.end += @min(lanes, self.omegas.len - self.base);
            const chunk = self.omegas[self.base..self.end];
            const terms = ckt.ac_dyn_slots.len * chunk.len;
            const re = self.dyn[0..terms];
            const im = self.dyn[self.dyn.len / 2 ..][0..terms];
            if (terms != 0) ckt.acDyn(self.x_op, chunk, re, im);
            const dyn: Dyn = .{ .slots = ckt.ac_dyn_slots, .re = re, .im = im };
            try self.fs.solveBatch(chunk, dyn, self.rhs, self.buf[0 .. chunk.len * m], self.adjoint);
            if (self.end % quantum == 0 or self.end == self.omegas.len)
                try ckt.checkpoint(.{ .phase = .frequency, .completed = self.end, .total = self.omegas.len });
        }
        defer self.k += 1;
        return .{ .k = self.k, .x = self.buf[(self.k - self.base) * m ..][0..m] };
    }
};
