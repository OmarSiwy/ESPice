//! Transient data types, split from tran.zig so Circuit.zig can name them in
//! its hook signatures without importing the transient driver (which imports
//! the analysis types that re-export Circuit — this file keeps the file-level
//! import graph acyclic: types.zig -> Circuit.zig -> ../types.zig -> tran.zig).
const std = @import("std");
const converger = @import("solvers").converger;

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;

pub const Method = enum {
    backward_euler,
    trapezoidal,
    gear_2,
};

pub const Options = struct {
    tol: converger.Tolerances = .{},
    t_stop: f64,
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    /// ngspice tmax: default is t_stop/50; an explicit value replaces it.
    dt_max: ?f64 = null,
    method: Method = .trapezoidal,
    max_steps: u32 = 1_000_000,
    /// Invoked after each accepted step (envelope/pnoise/pac build on this).
    step_fn: ?*const fn (ctx: ?*anyopaque, t: f64, x: []const f64) void = null,
    step_ctx: ?*anyopaque = null,
};

/// Waveform capacity heuristic: adaptive dt makes the point count unknown up
/// front, so start generously from t_stop/dt_init and clamp to 4M points.
pub fn initialCapacity(options: Options) u32 {
    const est = 16.0 * options.t_stop / options.dt_init;
    return @intFromFloat(@min(@max(1024.0, est), @as(f64, 1 << 22)));
}

/// SIMD copy — the shared pair lives on the solvers leaf (one copy per repo).
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

    /// Record one point from already-gathered probe values (GPU waveform
    /// drain — the device ships probe values, not the full x vector).
    pub fn recordValues(self: *Waveform, t: f64, vals: []const f64) !void {
        if (self.len == self.capacity) try self.grow();
        self.times[self.len] = t;
        const cap: usize = self.capacity;
        for (vals, 0..) |v, k| self.values[k * cap + self.len] = v;
        self.len += 1;
    }

    pub fn timeSlice(self: *const Waveform) []const f64 {
        return self.times[0..self.len];
    }

    pub fn probeValues(self: *const Waveform, k: u32) []const f64 {
        return self.values[@as(usize, k) * self.capacity ..][0..self.len];
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
