//! History ring buffer for delay/transmission-line devices: (time, values)
//! samples with linear-interpolation lookup.

const std = @import("std");

/// Arena-allocated ring buffer that stores (time, values...) tuples and
/// supports linear interpolation lookup at arbitrary query times.
/// Used by history-dependent devices (transmission lines, delay elements).
pub const HistoryBuffer = struct {
    /// Ring buffer of time points
    times: []f64,
    /// Ring buffer of value snapshots; values[sample_idx * n_signals + signal_idx]
    values: []f64,
    n_signals: u32,
    capacity: u32,
    head: u32,
    len: u32,

    pub fn init(allocator: std.mem.Allocator, n_signals: u32, capacity: u32) !HistoryBuffer {
        const cap = @max(capacity, 4);
        return .{
            .times = try allocator.alloc(f64, cap),
            .values = try allocator.alloc(f64, @as(usize, cap) * n_signals),
            .n_signals = n_signals,
            .capacity = cap,
            .head = 0,
            .len = 0,
        };
    }

    /// Record a new sample. vals.len must equal n_signals.
    pub fn record(self: *HistoryBuffer, t: f64, vals: []const f64) void {
        std.debug.assert(vals.len == self.n_signals);
        const slot = self.head;
        self.times[slot] = t;
        const base = @as(usize, slot) * self.n_signals;
        @memcpy(self.values[base..][0..self.n_signals], vals);
        self.head = (slot + 1) % self.capacity;
        if (self.len < self.capacity) self.len += 1;
    }

    /// Look up signal `sig` at time `t_query` using linear interpolation.
    /// Clamps to oldest/newest value if t_query is out of range.
    /// Binary search — times are monotonic along the ring.
    pub fn lookup(self: *const HistoryBuffer, t_query: f64, sig: u32) f64 {
        if (self.len == 0) return 0.0;
        const oldest = if (self.len < self.capacity) 0 else self.head;

        // First k in [0, len) with times[slot(k)] >= t_query.
        var lo: u32 = 0;
        var hi: u32 = self.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.times[(oldest + mid) % self.capacity] < t_query) lo = mid + 1 else hi = mid;
        }

        if (lo == 0) return self.valueAt(oldest, sig);
        if (lo == self.len) return self.valueAt((oldest + self.len - 1) % self.capacity, sig);

        const s0 = (oldest + lo - 1) % self.capacity;
        const s1 = (oldest + lo) % self.capacity;
        const t0 = self.times[s0];
        const t1 = self.times[s1];
        const alpha = (t_query - t0) / (t1 - t0);
        const v0 = self.valueAt(s0, sig);
        const v1 = self.valueAt(s1, sig);
        return v0 + alpha * (v1 - v0);
    }

    inline fn valueAt(self: *const HistoryBuffer, slot: u32, sig: u32) f64 {
        return self.values[@as(usize, slot) * self.n_signals + sig];
    }
};

/// Handed to a history device's histInject: interpolated signal lookup.
pub const HistLookup = struct {
    buf: *const HistoryBuffer,
    pub fn at(self: HistLookup, t: f64, signal: usize) f64 {
        return self.buf.lookup(t, @intCast(signal));
    }
};
