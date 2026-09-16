//! Bounded frequency batches retain SIMD/GPU lanes between query yields.
const std = @import("std");
const root = @import("../types.zig");
const FreqSolver = @import("solvers").freq_solve.FreqSolver;

// ponytail: 64 frequencies per public advancement; expose a work budget if
// callers need another latency/throughput tradeoff. A factorization is atomic.
pub const quantum: usize = 64;

pub fn solve(
    ckt: *root.Circuit,
    fs: *FreqSolver,
    allocator: std.mem.Allocator,
    g: []const f64,
    c: []const f64,
    omegas: []const f64,
    rhs: []const f64,
    adjoint: bool,
) ![]f64 {
    const nn: usize = fs.nn;
    const output = try allocator.alloc(f64, try std.math.mul(usize, omegas.len, nn));
    errdefer allocator.free(output);
    const width = if (ckt.progress != null) quantum else @max(omegas.len, 1);
    var first: usize = 0;
    while (first < omegas.len) {
        const end = first + @min(width, omegas.len - first);
        const dst = output[first * nn .. end * nn];
        ckt.gpuFreqBatch(g, c, omegas[first..end], rhs, fs.n, adjoint, dst) orelse
            try fs.solveBatch(omegas[first..end], rhs, dst, adjoint);
        first = end;
        try ckt.checkpoint(.{ .phase = .frequency, .completed = end, .total = omegas.len });
    }
    return output;
}
