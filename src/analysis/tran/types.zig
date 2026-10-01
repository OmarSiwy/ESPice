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

/// A borrowed series inside a row-major table: element i is
/// `base[i * stride]`. Readers walk a waveform column in place instead of
/// gathering it.
pub const Column = struct {
    base: []const f64,
    stride: usize,
    len: usize,

    /// A plain slice as a column of stride 1.
    pub fn of(s: []const f64) Column {
        return .{ .base = s, .stride = 1, .len = s.len };
    }

    pub fn at(c: Column, i: usize) f64 {
        return c.base[i * c.stride];
    }

    /// The column from element `i` on.
    pub fn from(c: Column, i: usize) Column {
        return .{ .base = c.base[i * c.stride ..], .stride = c.stride, .len = c.len - i };
    }

    /// The first index whose value is >= `v`; the column must be ascending.
    pub fn lowerBound(c: Column, v: f64) usize {
        var lo: usize = 0;
        var hi = c.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (c.at(mid) < v) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

/// Recorded transient waveform as point-major rows (time, probe 0, ...),
/// the exact layout a transient `Result` publishes, so the result borrows
/// the recording instead of transposing a copy of it. Untouched capacity is
/// virtual memory only: the estimate in `initialCapacity` costs no RSS.
pub const Waveform = struct {
    /// `capacity` rows of `stride()` f64s; the first `len` rows are valid.
    rows: []f64,
    len: u32,
    capacity: u32,
    n_probes: u32,
    allocator: std.mem.Allocator,
    /// When set, every row goes here as native-endian f64s and only the row
    /// being built is kept: `data` is empty and `column`/`time` are invalid.
    sink: ?*std.Io.Writer = null,

    /// Allocates room for `capacity` points (at least 1) of `n_probes` probes.
    pub fn init(allocator: std.mem.Allocator, n_probes: u32, capacity: u32) !Waveform {
        const cap: u32 = @max(capacity, 1);
        return .{
            .rows = try allocator.alloc(f64, @as(usize, n_probes + 1) * cap),
            .len = 0,
            .capacity = cap,
            .n_probes = n_probes,
            .allocator = allocator,
        };
    }

    /// A waveform that writes each row to `sink` instead of keeping it.
    pub fn initStream(allocator: std.mem.Allocator, n_probes: u32, sink: *std.Io.Writer) !Waveform {
        var wf = try init(allocator, n_probes, 1);
        wf.sink = sink;
        return wf;
    }

    /// Columns per row: time, then one per probe.
    pub fn stride(self: Waveform) usize {
        return @as(usize, self.n_probes) + 1;
    }

    /// Appends point `t` with `x[probes[k]]` as probe k. Growing invalidates
    /// earlier `data` slices.
    pub fn record(self: *Waveform, t: f64, x: []const f64, probes: []const u32) !void {
        const row = try self.next();
        row[0] = t;
        for (probes, row[1..]) |node, *v| v.* = x[node];
        try self.emit(row);
    }

    /// `record` of the point `(1 - f) * a + f * b` at time `t`, per probe.
    pub fn recordLerp(self: *Waveform, t: f64, a: []const f64, b: []const f64, f: f64, probes: []const u32) !void {
        const row = try self.next();
        row[0] = t;
        for (probes, row[1..]) |node, *v| v.* = a[node] + f * (b[node] - a[node]);
        try self.emit(row);
    }

    fn emit(self: Waveform, row: []const f64) !void {
        if (self.sink) |w| try w.writeAll(std.mem.sliceAsBytes(row));
    }

    /// The recorded rows, borrowed: valid until the next `record` or
    /// `deinit`. A transient `Result.data` is exactly this slice.
    pub fn data(self: Waveform) []f64 {
        if (self.sink != null) return &.{};
        return self.rows[0 .. @as(usize, self.len) * self.stride()];
    }

    /// Point `i`'s time.
    pub fn time(self: Waveform, i: usize) f64 {
        return self.rows[i * self.stride()];
    }

    /// Column `c` (0 = time, k + 1 = probe k), borrowed in place; valid
    /// until the next `record` or `deinit`.
    pub fn column(self: Waveform, c: usize) Column {
        return .{ .base = self.rows[c..], .stride = self.stride(), .len = self.len };
    }

    fn next(self: *Waveform) ![]f64 {
        const s = self.stride();
        defer self.len += 1;
        if (self.sink != null) return self.rows[0..s];
        if (self.len == self.capacity) try self.grow();
        return self.rows[@as(usize, self.len) * s ..][0..s];
    }

    // ponytail: doubling fallback; initialCapacity covers normal runs. On an
    // arena a growth that cannot resize in place leaves the old rows resident
    // until the arena dies; a reserve-and-commit buffer removes that.
    fn grow(self: *Waveform) !void {
        const new_cap = @as(usize, self.capacity) * 2;
        self.rows = try self.allocator.realloc(self.rows, self.stride() * new_cap);
        self.capacity = @intCast(new_cap);
    }

    pub fn deinit(self: *Waveform) void {
        self.allocator.free(self.rows);
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
