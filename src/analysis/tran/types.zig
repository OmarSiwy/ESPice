//! Transient data types, split from tran.zig so Circuit.zig can name them in
//! its hook signatures without importing the transient driver (which imports
//! the analysis types that re-export Circuit — this file keeps the file-level
//! import graph acyclic: types.zig -> Circuit.zig -> ../types.zig -> tran.zig).
const std = @import("std");
const converger = @import("solvers").converger;

pub const Method = @import("requests").Method;

pub const Options = @import("requests").Tran;

/// Waveform capacity heuristic: adaptive dt makes the point count unknown up
/// front. dt_init is the PRINT step (ngspice tstep), and accepted points run
/// a small factor above t_stop/tmax in practice — 2x covers the LTE-refined
/// tail on the fixture corpus, and grow() doubles past it when a deck is
/// edge-heavy. The old 16x prefactor put a 100k-node ladder's waveform at
/// 16 buffers of slack: preallocation was most of the 2.8 GB peak.
pub fn initialCapacity(options: Options) u32 {
    const est = 2.0 * options.t_stop / options.dt_init;
    return @intFromFloat(@min(@max(64.0, est), @as(f64, 1 << 22)));
}

/// SIMD copy — the shared pair lives on the solvers leaf (one copy per repo).
/// ponytail: the shared kernel owns the vector width; this leaf only records.
pub const simdCopy = @import("solvers").types.copySimd;

/// Recorded transient waveform. Flat preallocated storage, probe-major:
/// values[k * capacity + i] is probe k at point i — probeValues(k) is one
/// contiguous slice (what four.zig / meas.zig consume).
pub const Waveform = struct {
    times: []f64,
    values: []f64, // n_probes * capacity, probe-major
    len: u32,
    capacity: u32,
    n_probes: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n_probes: u32, capacity: u32) !Waveform {
        const cap: u32 = @max(capacity, 1);
        const times = try allocator.alloc(f64, cap);
        errdefer allocator.free(times);
        const values = try allocator.alloc(f64, @as(usize, n_probes) * cap);
        return .{
            .times = times,
            .values = values,
            .len = 0,
            .capacity = cap,
            .n_probes = n_probes,
            .allocator = allocator,
        };
    }

    pub fn record(self: *Waveform, t: f64, x: []const f64, probes: []const u32) !void {
        if (self.len == self.capacity) try self.grow();
        self.times[self.len] = t;
        const cap: usize = self.capacity;
        for (probes, 0..) |node, k| self.values[k * cap + self.len] = x[node];
        self.len += 1;
    }

    pub fn timeSlice(self: *const Waveform) []const f64 {
        return self.times[0..self.len];
    }

    pub fn probeValues(self: *const Waveform, k: u32) []const f64 {
        return self.values[@as(usize, k) * self.capacity ..][0..self.len];
    }

    /// Caller owns the point-major (time, probes...) result allocation.
    ///
    /// 32x32 point/probe tiles. The point-at-a-time version read one element
    /// of every probe slice per row, and consecutive probes are `capacity`
    /// f64 apart, so on rc_ladder_100k (100k probes, 320 MB waveform) every
    /// read was a fresh line and a fresh page. A tile keeps 8 KB of source
    /// and 8 KB of destination resident, so each 64-byte line is consumed
    /// whole on both sides. Values, row order, and partial tiles unchanged.
    /// ponytail: 32x32 measured 1.85 s vs 1.97 s on rc_ladder_100k, and both
    /// tile dimensions matter — 32 points x ALL probes is *slower* than no
    /// tiling at all (25 MB of destination in flight). Retune together.
    pub fn toRows(self: *const Waveform, allocator: std.mem.Allocator, ncols: usize) ![]f64 {
        const data = try allocator.alloc(f64, @as(usize, self.len) * ncols);
        const times = self.timeSlice();
        const tile = 32;
        var p0: usize = 0;
        while (p0 < self.len) : (p0 += tile) {
            const p1 = @min(p0 + tile, self.len);
            for (p0..p1) |p| data[p * ncols] = times[p];
            var k0: usize = 0;
            while (k0 < self.n_probes) : (k0 += tile) {
                const k1 = @min(k0 + tile, self.n_probes);
                for (k0..k1) |idx| {
                    const src = self.probeValues(@intCast(idx))[p0..p1];
                    for (src, p0..) |v, p| data[p * ncols + idx + 1] = v;
                }
            }
        }
        return data;
    }

    // ponytail: doubling fallback, capacity heuristic covers normal runs
    fn grow(self: *Waveform) !void {
        const old_cap: usize = self.capacity;
        const new_cap = old_cap * 2;
        const times_new = try self.allocator.alloc(f64, new_cap);
        errdefer self.allocator.free(times_new);
        const values_new = try self.allocator.alloc(f64, @as(usize, self.n_probes) * new_cap);
        simdCopy(times_new[0..self.len], self.times[0..self.len]);
        for (0..self.n_probes) |k| {
            simdCopy(
                values_new[k * new_cap ..][0..self.len],
                self.values[k * old_cap ..][0..self.len],
            );
        }
        self.allocator.free(self.times);
        self.allocator.free(self.values);
        self.times = times_new;
        self.values = values_new;
        self.capacity = @intCast(new_cap);
    }

    pub fn deinit(self: *Waveform) void {
        self.allocator.free(self.times);
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub const SimResult = struct {
    completed: bool,
    steps: u32,
    t_final: f64,
};
