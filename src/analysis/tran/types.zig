//! Transient data types shared by tran.zig, integrator.zig, matex.zig and
//! the post-processors, kept apart from the driver so they import no solver.
const std = @import("std");

pub const Method = @import("core").query.Method;

pub const Options = @import("core").query.Tran;

/// Initial waveform capacity in points: twice the printed window over the
/// print step, clamped to [64, 2^22]. Adaptive dt makes the real count
/// unknown; 2x covers the LTE-refined tail on the fixture corpus and
/// `Waveform.record` doubles past it. Points before t_start are never stored.
pub fn initialCapacity(options: Options) u32 {
    const est = 2.0 * (options.t_stop - options.t_start) / options.dt_init;
    return @intFromFloat(@min(@max(64.0, est), @as(f64, 1 << 22)));
}

const simdCopy = @import("core").numerics.copySimd;

/// Recorded transient waveform, probe-major so each probe's samples are one
/// contiguous slice (`probeValues`). Owns both buffers through `allocator`.
pub const Waveform = struct {
    /// Sample times, `capacity` long; the first `len` are valid.
    times: []f64,
    /// `n_probes * capacity`; probe k's point i is at `k * capacity + i`.
    values: []f64,
    len: u32,
    capacity: u32,
    n_probes: u32,
    allocator: std.mem.Allocator,

    /// Allocates room for `capacity` points (at least 1) of `n_probes` probes.
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

    /// Appends point `t` with `x[probes[k]]` as probe k. A full buffer
    /// doubles, which invalidates earlier `timeSlice`/`probeValues` slices.
    pub fn record(self: *Waveform, t: f64, x: []const f64, probes: []const u32) !void {
        if (self.len == self.capacity) try self.grow();
        self.times[self.len] = t;
        const cap: usize = self.capacity;
        for (probes, 0..) |node, k| self.values[k * cap + self.len] = x[node];
        self.len += 1;
    }

    /// `record` of the point `(1 - f) * a + f * b` at time `t`, per probe;
    /// grows and invalidates like `record`.
    pub fn recordLerp(self: *Waveform, t: f64, a: []const f64, b: []const f64, f: f64, probes: []const u32) !void {
        if (self.len == self.capacity) try self.grow();
        self.times[self.len] = t;
        const cap: usize = self.capacity;
        for (probes, 0..) |node, k| self.values[k * cap + self.len] = a[node] + f * (b[node] - a[node]);
        self.len += 1;
    }

    /// The recorded times, valid until the next `record`.
    pub fn timeSlice(self: *const Waveform) []const f64 {
        return self.times[0..self.len];
    }

    /// Probe k's recorded samples, valid until the next `record`.
    pub fn probeValues(self: *const Waveform, k: u32) []const f64 {
        return self.values[@as(usize, k) * self.capacity ..][0..self.len];
    }

    /// Transposes to point-major rows (time, probes...) of stride `ncols`.
    /// The caller owns the returned slice.
    pub fn toRows(self: *const Waveform, allocator: std.mem.Allocator, ncols: usize) ![]f64 {
        const data = try allocator.alloc(f64, @as(usize, self.len) * ncols);
        const times = self.timeSlice();
        // 32x32 point/probe tiles keep 8 KB of source and 8 KB of destination
        // resident, so each cache line is consumed whole on both sides.
        // ponytail: 32x32 measured 1.85 s vs 1.97 s untiled on rc_ladder_100k,
        // and 32 points x all probes was slower than no tiling. Retune both
        // dimensions together.
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

    // ponytail: doubling fallback; initialCapacity covers normal runs.
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

/// Outcome of one transient integration.
pub const SimResult = struct {
    /// True when t reached t_stop; false when dt fell below dt_min or
    /// max_steps ran out.
    completed: bool,
    /// Accepted steps.
    steps: u32,
    /// Time of the last accepted point, in seconds.
    t_final: f64,
};
