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
        const times = try allocator.alloc(f64, cap);
        errdefer allocator.free(times);
        return .{
            .times = times,
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

    /// Look up signal `sig` at time `t_query`. Quadratic (3-point Lagrange)
    /// interpolation through the two samples at/before the query and the one
    /// after — same scheme as ngspice traload.c's default (f1/f2/f3 through
    /// t(i-2), t(i-1), t(i)); falls back to linear when only two points
    /// bracket the query. Clamps to oldest/newest value out of range.
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

        const s1 = (oldest + lo - 1) % self.capacity;
        const s2 = (oldest + lo) % self.capacity;
        const t1 = self.times[s1];
        const t2 = self.times[s2];
        const v1 = self.valueAt(s1, sig);
        const v2 = self.valueAt(s2, sig);

        if (lo >= 2) {
            const s0 = (oldest + lo - 2) % self.capacity;
            const t0 = self.times[s0];
            const d01 = t0 - t1;
            const d02 = t0 - t2;
            const d12 = t1 - t2;
            // Degenerate spacing → linear.
            if (d01 != 0.0 and d02 != 0.0 and d12 != 0.0) {
                const f0 = (t_query - t1) * (t_query - t2) / (d01 * d02);
                const f1 = (t_query - t0) * (t_query - t2) / (-d01 * d12);
                const f2 = (t_query - t0) * (t_query - t1) / (d02 * d12);
                return f0 * self.valueAt(s0, sig) + f1 * v1 + f2 * v2;
            }
        }

        const alpha = (t_query - t1) / (t2 - t1);
        return v1 + alpha * (v2 - v1);
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
