//! `.meas` evaluation over a finished result, ported from ngspice 45
//! com_measure2.c: the same event counting, linear interpolation and
//! quadrature, printed in the same lines. A card whose event never happens
//! reports on the error writer, as ngspice does, and prints no value.
const std = @import("std");
const core = @import("core");
const Writer = std.Io.Writer;
const Clause = core.MeasureClause;
const Kind = core.query.Kind;
const nan = std.math.nan(f64);
const assert = std.debug.assert;

/// A sweep point's row in the variant table and its label (`rv=1k, ...`),
/// which names its `.meas` block.
pub const Point = struct { row: u32, label: []const u8 };

/// Writes every card in `measures` that targets `analysis`, evaluated over
/// `result`, under ngspice's heading. Writes nothing when none targets it.
/// A card that names a missing vector or whose event never happens writes
/// ngspice's error line to `err` and no value; at a sweep `point`, which
/// the heading names, it also writes `name = NaN`. A PARAM card reads NaN
/// for any card past the 256th.
pub fn print(out: *Writer, err: *Writer, measures: []const core.Measure, analysis: Kind, result: core.Result, point: ?Point) Writer.Error!void {
    // As ngspice's measure.c, PARAM cards read every other card's result,
    // so those are evaluated first; each card still prints in deck order.
    // ponytail: a fixed table; cards past the 256th read as NaN to a PARAM.
    var values: [256]f64 = @splat(nan);
    var discard_buf: [64]u8 = undefined;
    var discard: Writer.Discarding = .init(&discard_buf);
    var done: Done = undefined;
    for (measures, 0..) |m, i| {
        if (!targets(m, analysis, result) or m.func == .param or i >= values.len) continue;
        values[i] = evaluate(&discard.writer, m, cardWave(result, analysis, &values, i, &done)) catch nan;
    }
    var headed = false;
    for (measures, 0..) |m, i| {
        if (!targets(m, analysis, result)) continue;
        if (!headed) try writeHeading(out, analysis, point);
        headed = true;
        const value = evaluate(out, m, cardWave(result, analysis, &values, i, &done)) catch |e| switch (e) {
            error.WriteFailed => return error.WriteFailed,
            error.NoSuchVector => blk: {
                try err.print("\nError: measure  {s} : no such vector\n", .{m.name});
                break :blk nan;
            },
            error.OutOfInterval => blk: {
                try err.print("\nError: measure  {s} : out of interval\n", .{m.name});
                break :blk nan;
            },
        };
        if (point != null and std.math.isNan(value)) try out.print("{s:<20}=  NaN\n", .{m.name});
        if (m.func == .param and i < values.len) values[i] = value;
    }
}

/// `print` for a sweep point whose `analysis` failed: its heading and
/// `name = NaN` for every card of that analysis.
pub fn printFailed(out: *Writer, measures: []const core.Measure, analysis: Kind, point: Point) Writer.Error!void {
    var headed = false;
    for (measures) |m| {
        if (m.analysis != analysis) continue;
        if (!headed) try writeHeading(out, analysis, point);
        headed = true;
        try out.print("{s:<20}=  NaN\n", .{m.name});
    }
}

/// ngspice's block heading, naming the sweep point when there is one.
fn writeHeading(out: *Writer, analysis: Kind, point: ?Point) Writer.Error!void {
    try out.print("\n  Measurements for {s} Analysis", .{switch (analysis) {
        .tran => "Transient",
        .tran_noise => "Transient Noise",
        .ac => "AC",
        .sp => "SP",
        .fft => "FFT",
        .dcmatch => "DC Mismatch",
        .acmatch => "AC Mismatch",
        .lstb => "Loop Stability",
        .phasenoise => "Phase Noise",
        .pnoise => "Periodic Time-Dependent Noise",
        .op => "Operating Point",
        else => "DC", // else: any other analysis takes the DC heading; a kind with its own title adds an arm
    }});
    if (point) |p| try out.print(", point {d} ({s})", .{ p.row, p.label });
    try out.writeAll("\n\n");
}

/// Evaluates every card in `measures` that targets `analysis` over
/// `result` into `out` (parallel to `measures`), PARAM cards last in
/// deck order, as `print` does. A card that does not target the result, or
/// whose event never happens, reads NaN.
/// Asserts that `out.len == measures.len`.
pub fn evaluateAll(measures: []const core.Measure, analysis: Kind, result: core.Result, out: []f64) void {
    evaluateOutcomes(measures, analysis, result, out, null);
}

/// `evaluateAll`, also setting `missing[i]` (when given, parallel to
/// `measures`) for a card that names a vector `result` lacks, ngspice's
/// "no such vector", and clearing it for every other card.
pub fn evaluateOutcomes(measures: []const core.Measure, analysis: Kind, result: core.Result, out: []f64, missing: ?[]bool) void {
    assert(out.len == measures.len);
    @memset(out, nan);
    if (missing) |ms| @memset(ms, false);
    var discard_buf: [64]u8 = undefined;
    var discard: Writer.Discarding = .init(&discard_buf);
    var done: Done = undefined;
    for ([_]bool{ false, true }) |param| for (measures, out, 0..) |m, *v, i| {
        if (!targets(m, analysis, result) or (m.func == .param) != param) continue;
        v.* = evaluate(&discard.writer, m, cardWave(result, analysis, out, i, &done)) catch |e| blk: {
            if (e == error.NoSuchVector) if (missing) |ms| {
                ms[i] = true;
            };
            break :blk nan;
        };
    };
}

/// Clause `c`'s waveform over transient `result` at each time in `at`,
/// interpolated linearly and held flat past either end. A result with no
/// samples (none computed, or streamed to a file) reads NaN everywhere.
/// `NoSuchVector` when `c` names a vector the result lacks. Asserts that
/// `at.len == out.len`.
pub fn sample(c: Clause, result: core.Result, at: []const f64, out: []f64) error{NoSuchVector}!void {
    assert(at.len == out.len);
    const w: Wave = .{ .result = result, .analysis = .tran };
    const x = w.scale();
    const y = try w.waveform(c.vec, c.ops, c.vectype);
    const n = w.len();
    if (n == 0) return @memset(out, nan);
    for (at, out) |t, *v| {
        // The first sample at or after t.
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (x.get(mid) < t) lo = mid + 1 else hi = mid;
        }
        v.* = if (lo == 0) y.get(0) else if (lo == n) y.get(n - 1) else interpolate(x, y, lo - 1, lo, t);
    }
}

/// Sets `keep[k]` for every column of `names` (a transient's labels, the
/// scale first) that a `.tran` card of `measures` reads, and the scale;
/// with `streamed`, only for the cards a `Stream` cannot measure without
/// the recording. Evaluating over just those columns gives the same values,
/// to the bit, as over all of them: lookups are by name. Asserts
/// `keep.len == names.len`.
pub fn markColumns(measures: []const core.Measure, names: []const []const u8, keep: []bool, streamed: bool) void {
    assert(keep.len == names.len);
    @memset(keep, false);
    if (keep.len > 0) keep[0] = true;
    for (measures, 0..) |m, i| if (m.analysis == .tran and !(streamed and ruleOf(measures, i) == .scan)) for ([_]Clause{ m.first, m.second }) |c| {
        for ([_][]const u8{ c.vec, c.vec2 }) |name| if (name.len > 0) if (columnIndex(names, name)) |k| {
            keep[k] = true;
        };
        for ([_][]const core.MeasureOp{ c.ops, c.ops2 }) |ops| for (ops) |op| if (op == .vector) if (columnIndex(names, op.vector)) |k| {
            keep[k] = true;
        };
    };
}

/// The `.tran` cards of a deck measured row by row as a transient accepts
/// rows (dev/research/lane-batched-simulation.md §7), each by the passes
/// `print` makes over a finished result, so with the same values, to the
/// bit. A card resolves once no later row can change its value, which
/// early stop and the abort bound read:
/// - WHEN, TRIG/TARG, FIND/DERIV with WHEN or AT: at the event, or past
///   every TO= (or AT=) without one; a LAST count only past TO=.
/// - AVG, MIN, MAX, PP, RMS, INTEG, EM_AVG, ERR*: past a nonzero TO=.
/// - PARAM: once every card it reads has resolved.
/// - `_CONT`, JITTER, the checks and DOUT, a bare FIND, and cards reading
///   a later card or a PARAM: never; they read the whole run.
/// Cards without TO= resolve at the run's end, recorded or not.
/// `measured` gives what each `.scan` card found, whose columns need no
/// recording (`markColumns` with `streamed`); every other card reads the
/// recording. A card reading an earlier card's value starts once that
/// resolves, replaying the recording so far, as do TARG with TD=TRIG and
/// FIND/DERIV with a WHEN of TD=, FROM= or a LAST count at their event.
/// O(open cards) per row; a replay is O(rows) once per card.
pub const Stream = struct {
    arena: std.heap.ArenaAllocator,
    measures: []const core.Measure,
    cards: []Card,
    /// Each resolved card's value, NaN until then: what a later card reads.
    values: []f64,
    /// `.tran` cards not resolved yet.
    open: usize,
    /// The columns the `.tran` cards read, the scale first, and the
    /// unknown of the solution behind each after the scale.
    names: []const []const u8,
    nodes: []u32,
    /// Those columns at the current row, which every scan reads, and the
    /// current row kept while a replay borrows `row`.
    row: []f64,
    saved: []f64,
    /// The column of `row` behind each recorded column, `none` for one no
    /// card reads.
    recorded: []u32,
    /// Rows fed so far.
    rows: usize = 0,

    const none = std.math.maxInt(u32);

    const Card = struct {
        rule: Rule,
        done: bool,
        started: bool = false,
        /// Its passes, in the order `evaluate` reads them; `n` are built.
        scans: [2]Scan = undefined,
        n: u8 = 0,
        /// Scan 1 starts at scan 0's event, from `clause`: TARG with
        /// TD=TRIG, or the value FIND/DERIV reads at its WHEN.
        stage: enum { none, targ, find } = .none,
        clause: Clause = .{},
        /// DERIV's slope rather than FIND's value at the event.
        slope: bool = false,
        /// A `.scan` FIND/DERIV WHEN: its FIND vector, and (scale, value)
        /// at the last rows, oldest first, which the value pass starts
        /// from (in a run whose times rise, it reads no row before them).
        ring_y: ?Column = null,
        ring: [3][2]f64 = undefined,
        ring_len: u8 = 0,

        fn resolved(c: Card) bool {
            if (!c.started or c.stage != .none) return false;
            for (c.scans[0..c.n]) |s| if (!s.over) return false;
            return true;
        }
    };

    /// `names` and `nodes` are a transient's columns (the scale first,
    /// then each probe's unknown); `recorded` names the ones it records.
    pub fn init(gpa: std.mem.Allocator, measures: []const core.Measure, names: []const []const u8, nodes: []const u32, recorded: []const []const u8) !Stream {
        assert(names.len == nodes.len + 1);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const keep = try a.alloc(bool, names.len);
        markColumns(measures, names, keep, false);
        const width = std.mem.count(bool, keep, &.{true});
        const own = try a.alloc([]const u8, width);
        const own_nodes = try a.alloc(u32, width - 1);
        var k: usize = 0;
        for (names, keep, 0..) |name, on, i| if (on) {
            own[k] = name;
            if (k > 0) own_nodes[k - 1] = nodes[i - 1];
            k += 1;
        };
        const map = try a.alloc(u32, recorded.len);
        for (recorded, map) |name, *m| m.* = for (own, 0..) |o, j| {
            if (std.mem.eql(u8, o, name)) break @intCast(j);
        } else none;
        var s: Stream = .{
            .arena = undefined,
            .measures = measures,
            .cards = try a.alloc(Card, measures.len),
            .values = try a.alloc(f64, measures.len),
            .open = 0,
            .names = own,
            .nodes = own_nodes,
            .row = try a.alloc(f64, width),
            .saved = try a.alloc(f64, width),
            .recorded = map,
        };
        @memset(s.values, nan);
        @memset(s.row, nan);
        for (measures, s.cards, 0..) |m, *c, i| {
            c.* = .{ .rule = ruleOf(measures, i), .done = m.analysis != .tran };
            s.open += @intFromBool(!c.done);
            // Read from the first row, so a run with none measures as an
            // empty recording does.
            if (!c.done and c.rule == .scan) s.start(m, c, &.{});
        }
        s.arena = arena;
        return s;
    }

    pub fn deinit(s: *Stream) void {
        s.arena.deinit();
        s.* = undefined;
    }

    /// Feeds the row at `t` of solution `x`. `data` is the recording, this
    /// row last, which a card starting late replays. Call once per row.
    pub fn feed(s: *Stream, t: f64, x: []const f64, data: []const f64) void {
        assert(data.len == (s.rows + 1) * s.recorded.len);
        defer s.rows += 1;
        if (s.open == 0) return;
        s.row[0] = t;
        for (s.nodes, s.row[1..]) |node, *v| v.* = x[node];
        // Non-PARAM cards read only earlier ones, PARAM cards any card.
        for ([_]bool{ false, true }) |param| for (s.measures, s.cards, 0..) |m, *c, i| {
            if (c.done or c.rule == .end or (c.rule == .param) != param) continue;
            if (c.started) {
                for (c.scans[0..c.n]) |*scan| scan.feed(s.row[0]);
                s.next(c, data);
            } else {
                if (!s.ready(i)) continue;
                s.start(m, c, data);
            }
            if (!c.resolved()) continue;
            c.done = true;
            s.values[i] = s.value(m, c);
            s.open -= 1;
        };
    }

    /// Each card's passes for `core.Result.measured`: what a `.scan` card
    /// found, nothing for the others.
    pub fn measured(s: *Stream, gpa: std.mem.Allocator) ![]core.Measured {
        const out = try gpa.alloc(core.Measured, s.cards.len);
        for (s.cards, out) |*c, *o| {
            o.* = .{};
            if (c.rule != .scan or !c.started) continue;
            o.* = .{ .scans = 2, .found = @splat(.{ .v = @splat(nan) }) };
            for (c.scans[0..c.n], o.found[0..c.n]) |*scan, *f| f.* = scan.found();
        }
        return out;
    }

    /// Whether every card it reads has resolved; a card of another analysis
    /// reads NaN whatever this run does.
    fn ready(s: Stream, i: usize) bool {
        const m = s.measures[i];
        for ([_]Clause{ m.first, m.second }) |c| for (c.refs) |ref| if (!s.resolvedOps(ref.expr)) return false;
        return s.resolvedOps(m.expr);
    }

    fn resolvedOps(s: Stream, ops: []const core.MeasureOp) bool {
        for (ops) |op| if (op == .measure and op.measure < s.cards.len and !s.cards[op.measure].done) return false;
        return true;
    }

    /// The current row as a one-row result, which the scans' columns read.
    fn wave(s: Stream) Wave {
        return .{ .result = .{ .plotname = "", .varnames = s.names, .is_complex = false, .npoints = 1, .data = s.row }, .analysis = .tran };
    }

    /// Builds card `c`'s passes, as `evaluate` makes them, and runs them
    /// over the rows so far: the recording `data` for a card starting late.
    fn start(s: *Stream, m: core.Measure, c: *Card, data: []const f64) void {
        c.started = true;
        if (c.rule == .param) return;
        // A ref without a value: `evaluate` fails it before any pass.
        const a = resolve(m.first, s.values) catch return;
        const b = resolve(m.second, s.values) catch return;
        const w = s.wave();
        const tran = Kind.tran;
        switch (m.func) {
            .when => c.scans[0] = .init(w, a, .{ .cross = .init(a, tran) }, .waveform),
            .trig_targ => {
                if (a.at == core.measure_no_at) c.scans[0] = .init(w, a, .{ .cross = .init(a, tran) }, .waveform);
                c.n = @intFromBool(a.at == core.measure_no_at);
                if (b.at == core.measure_no_at) {
                    var targ = b;
                    if (b.td_trig and a.at == core.measure_no_at) {
                        c.stage = .targ;
                        c.clause = b;
                    } else {
                        if (b.td_trig) targ.td = a.at;
                        c.scans[c.n] = .init(w, targ, .{ .cross = .init(targ, tran) }, .waveform);
                        c.n += 1;
                    }
                }
                return s.catchUp(c, data);
            },
            .find, .deriv => if (a.at != core.measure_no_at) {
                c.scans[0] = .init(w, a, .{ .at = .{ .at = a.at, .slope = m.func == .deriv } }, .none);
            } else {
                c.scans[0] = .init(w, b, .{ .cross = .init(b, tran) }, .waveform);
                c.stage = .find;
                c.clause = a;
                c.slope = m.func == .deriv;
                if (c.rule == .scan) c.ring_y = w.waveform(a.vec, a.ops, a.vectype) catch null;
            },
            .avg, .min, .max, .min_at, .max_at => c.scans[0] = .init(w, a, .{
                .extremum = .{
                    .c = a,
                    .dc = false,
                    .op = switch (m.func) {
                        .avg => .avg,
                        .min, .min_at => .min,
                        else => .max, // else: MAX and MAX_AT
                    },
                },
            }, .none),
            .pp => {
                c.scans = .{
                    .init(w, a, .{ .extremum = .{ .c = a, .dc = false, .op = .min } }, .none),
                    .init(w, a, .{ .extremum = .{ .c = a, .dc = false, .op = .max } }, .none),
                };
                c.n = 2;
                return s.catchUp(c, data);
            },
            .rms, .integ => c.scans[0] = .init(w, a, .{ .integ = .{ .c = a, .rms = m.func == .rms } }, .none),
            .em_avg => c.scans[0] = .init(w, a, .{ .em_avg = .{ .c = a } }, .none),
            .err, .err1, .err2, .err3 => c.scans[0] = .init(w, a, .{ .rel_error = .{ .c = a, .dc = false, .func = m.func } }, .column),
            else => unreachable, // else: `ruleOf` gives every other function `.end`
        }
        c.n = 1;
        s.catchUp(c, data);
    }

    /// Runs card `c`'s new passes over the rows so far: none before the
    /// first row, else the recording `data`, this row included.
    fn catchUp(s: *Stream, c: *Card, data: []const f64) void {
        if (data.len == 0) return;
        assert(c.rule == .replay);
        for (c.scans[0..c.n]) |*scan| s.replay(scan, data);
        s.next(c, data);
    }

    /// After card `c` has read the current row: keeps a `.scan` FIND's
    /// ring, and starts scan 1 at scan 0's event.
    fn next(s: *Stream, c: *Card, data: []const f64) void {
        if (c.stage == .none) return;
        if (c.ring_y) |y| {
            if (c.ring_len == c.ring.len) std.mem.copyForwards([2]f64, c.ring[0..2], c.ring[1..3]);
            c.ring_len = @min(c.ring_len + 1, c.ring.len);
            c.ring[c.ring_len - 1] = .{ s.row[0], y.get(0) };
        }
        if (!c.scans[0].over) return;
        const event = c.scans[0].found();
        const stage = c.stage;
        c.stage = .none;
        // No event: `evaluate` fails the card before scan 1.
        if (event.missing or std.math.isNan(event.v[0])) return;
        const w = s.wave();
        var cl = c.clause;
        c.n = 2;
        if (stage == .targ) {
            cl.td = event.v[0];
            c.scans[1] = .init(w, cl, .{ .cross = .init(cl, .tran) }, .waveform);
        } else c.scans[1] = .init(w, cl, .{ .at = .{ .at = event.v[0], .slope = c.slope } }, .none);
        if (c.rule == .replay) return s.replay(&c.scans[1], data);
        // `.scan`: from the ring. Rows before it hold the event only where
        // times repeat, which a transient's accepted rows never do.
        const scan = &c.scans[1];
        if (scan.missing) return;
        if (s.rows + 1 > c.ring_len and event.v[0] <= c.ring[0][0]) {
            scan.over = true; // ponytail: unreachable while recorded times rise
            return;
        }
        for (c.ring[0..c.ring_len]) |r| if (!scan.over) scan.feedValues(r[0], r[1], nan);
    }

    /// Runs `scan` over the recording `data`, every row so far.
    fn replay(s: *Stream, scan: *Scan, data: []const f64) void {
        const width = s.recorded.len;
        @memcpy(s.saved, s.row);
        defer @memcpy(s.row, s.saved);
        for (0..s.rows + 1) |i| {
            for (s.recorded, data[i * width ..][0..width]) |k, v| if (k != none) {
                s.row[k] = v;
            };
            scan.feed(s.row[0]);
        }
    }

    /// Resolved card `c`'s value, as `evaluate` reads it over its passes.
    fn value(s: Stream, m: core.Measure, c: *Card) f64 {
        var found: [2]core.Measured.Found = @splat(.{ .v = @splat(nan) });
        for (c.scans[0..c.n], found[0..c.n]) |*scan, *f| f.* = scan.found();
        var done: Done = .{ .found = &found };
        var discard_buf: [64]u8 = undefined;
        var discard: Writer.Discarding = .init(&discard_buf);
        const empty: core.Result = .{ .plotname = "", .varnames = &.{}, .is_complex = false, .npoints = 0, .data = &.{} };
        return evaluate(&discard.writer, m, .{ .result = empty, .analysis = .tran, .values = s.values, .done = &done }) catch nan;
    }
};

/// How `Stream` measures card `i` of `measures`: from the first row
/// without a recording (`scan`), over the recording (`replay`), once the
/// cards it reads resolve (`param`), or never (`end`).
const Rule = enum { end, param, scan, replay };

fn ruleOf(measures: []const core.Measure, i: usize) Rule {
    const m = measures[i];
    if (m.cont) return .end;
    // `print` reads a later card, or a PARAM, in its second pass and
    // `evaluateAll` reads NaN; a PARAM reading a later PARAM reads NaN.
    var refs = false;
    var at_ref = false;
    for ([_]Clause{ m.first, m.second }) |c| for (c.refs) |ref| {
        refs = true;
        at_ref = at_ref or ref.field == .at;
        for (ref.expr) |op| if (op == .measure) {
            if (op.measure >= i or (op.measure < measures.len and measures[op.measure].func == .param)) return .end;
        };
    };
    for (m.expr) |op| if (op == .measure and op.measure >= i and op.measure < measures.len and measures[op.measure].func == .param) return .end;
    const recorded = refs or switch (m.func) {
        // The targ count starts at the trigger.
        .trig_targ => m.second.td_trig and m.first.at == core.measure_no_at,
        // The value at the event reads rows before it, as far back as a
        // window start or the last event.
        .find, .deriv => m.first.at == core.measure_no_at and (m.second.td != 0 or m.second.from != 0 or lastEvent(m.second)),
        else => false, // else: every other function reads each row once
    };
    const by_rows: Rule = if (recorded) .replay else .scan;
    return switch (m.func) {
        .param => .param,
        .when, .trig_targ, .avg, .min, .max, .min_at, .max_at, .pp, .rms, .integ, .em_avg, .err, .err1, .err2, .err3 => by_rows,
        // A bare FIND reads a one-row plot.
        .find, .deriv => if (m.first.at != core.measure_no_at or at_ref or m.second.vec.len != 0) by_rows else .end,
        else => .end, // else: JITTER, the FFT figures, the checks and DOUT read the whole run
    };
}

/// Whether card `m` reads `result`. Each `.fft` card has its own plot, and
/// `.lstb` and `.ptdnoise` publish two kinds under one analysis, so those
/// cards read the plot holding their vector.
fn targets(m: core.Measure, analysis: Kind, result: core.Result) bool {
    if (m.analysis != analysis) return false;
    if ((analysis != .fft and analysis != .lstb and analysis != .pnoise) or m.func == .param) return true;
    const w: Wave = .{ .result = result, .analysis = analysis };
    _ = w.column(m.first.vec, 0) catch return false;
    return true;
}

/// Mean, sigma, min and max of each card over Monte Carlo trials, as
/// `mean(name) = x` lines (sigma with Bessel's correction). `trials` holds
/// the results the cards are evaluated over; a card that fails in a trial
/// leaves that trial out. Cards past the 256th are not reported.
/// O(cards * trials * samples).
pub fn printStatistics(out: *Writer, measures: []const core.Measure, analysis: Kind, trials: []const core.Result) Writer.Error!void {
    var discard_buf: [64]u8 = undefined;
    var discard: Writer.Discarding = .init(&discard_buf);
    // Welford accumulators, one per card; every field moves together.
    const Acc = struct { n: f64 = 0, mean: f64 = 0, m2: f64 = 0, lo: f64 = std.math.inf(f64), hi: f64 = -std.math.inf(f64) };
    var acc: [256]Acc = @splat(.{});
    const cards = measures[0..@min(measures.len, acc.len)];
    for (trials) |result| {
        // One pass in deck order: a card reads only the cards before it (a
        // later one is still NaN), so each card sees what it would alone.
        var values: [256]f64 = @splat(nan);
        var done: Done = undefined;
        for (cards, 0..) |m, k| {
            if (m.analysis != analysis) continue;
            values[k] = evaluate(&discard.writer, m, cardWave(result, analysis, &values, k, &done)) catch nan;
            const x = values[k];
            if (!std.math.isFinite(x)) continue;
            const a = &acc[k];
            a.n += 1;
            const delta = x - a.mean;
            a.mean += delta / a.n;
            a.m2 += delta * (x - a.mean);
            a.lo = @min(a.lo, x);
            a.hi = @max(a.hi, x);
        }
    }
    var heading = false;
    for (cards, acc[0..cards.len]) |m, a| {
        if (a.n == 0) continue;
        if (!heading) {
            heading = true;
            try out.print("\n  Monte Carlo statistics over {d} trials\n\n", .{trials.len});
        }
        const sigma = if (a.n > 1) @sqrt(a.m2 / (a.n - 1)) else 0;
        try out.print("mean({s}) = {f}\nsigma({s}) = {f}\nmin({s}) = {f}\nmax({s}) = {f}\n", .{ m.name, sci(a.mean, 6), m.name, sci(sigma, 6), m.name, sci(a.lo, 6), m.name, sci(a.hi, 6) });
    }
}

const EvalError = Writer.Error || error{ NoSuchVector, OutOfInterval };

/// Prints card `m` and returns its result, the value a PARAM card reads.
fn evaluate(out: *Writer, m: core.Measure, w: Wave) EvalError!f64 {
    if (m.cont) return evaluateCont(out, m, w);
    const a = try resolve(m.first, w.values);
    var b = try resolve(m.second, w.values);
    switch (m.func) {
        .trig_targ => {
            const trig = try defined(if (a.at == core.measure_no_at) try w.when(a) else a.at);
            if (b.td_trig) b.td = trig;
            const targ = try defined(if (b.at == core.measure_no_at) try w.when(b) else b.at);
            try out.print("{s:<20}=  {f} targ=  {f} trig=  {f}\n", .{ m.name, sci(targ - trig, 6), sci(targ, 6), sci(trig, 6) });
            return targ - trig;
        },
        .find, .deriv => {
            // A bare FIND: the value of a one-row plot.
            if (a.at == core.measure_no_at and b.vec.len == 0) {
                if (w.len() != 1) return error.OutOfInterval;
                const v = try defined((try w.waveform(a.vec, a.ops, a.vectype)).get(0));
                try out.print("{s:<20}=  {f}\n", .{ m.name, sci(v, 6) });
                return v;
            }
            const at = if (a.at == core.measure_no_at) try defined(try w.when(b)) else a.at;
            const v = try defined(if (m.func == .find) try w.valueAt(a, at) else try w.slopeAt(a, at));
            try out.print("{s:<20}=  {f}\n", .{ m.name, sci(v, 6) });
            return v;
        },
        .when => {
            const v = try defined(try w.when(a));
            try out.print("{s:<20}=   {f}\n", .{ m.name, sci(v, 5) });
            return v;
        },
        .rms, .integ => {
            const r = try w.rmsInteg(a, m.func == .rms);
            try out.print("{s:<20}=   {f} from=  {f} to=  {f}\n", .{ m.name, sci(try defined(r.value), 5), sci(r.from, 5), sci(r.to, 5) });
            return r.value;
        },
        .jitter => {
            const j = try w.jitter(a);
            try out.print("{s:<20}=  {f} pp=  {f} period=  {f} edges=  {d}\n", .{ m.name, sci(j.rms, 6), sci(j.pp, 6), sci(j.period, 6), j.edges });
            return j.rms;
        },
        .em_avg => {
            const r = try w.emAvg(a);
            try out.print("{s:<20}=  {f} from=  {f} to=  {f}\n", .{ m.name, sci(try defined(r.value), 6), sci(r.from, 6), sci(r.to, 6) });
            return r.value;
        },
        .avg => {
            const r = try w.extremum(a, .avg);
            try out.print("{s:<20}=  {f} from=  {f} to=  {f}\n", .{ m.name, sci(try defined(r.value), 6), sci(if (a.at == core.measure_no_at) a.from else a.at, 6), sci(r.at, 6) });
            return r.value;
        },
        .min, .max => {
            const r = try w.extremum(a, if (m.func == .min) .min else .max);
            try out.print("{s:<20}=  {f} at=  {f}\n", .{ m.name, sci(try defined(r.value), 6), sci(r.at, 6) });
            return r.value;
        },
        .min_at, .max_at => {
            const r = try w.extremum(a, if (m.func == .min_at) .min else .max);
            try out.print("{s:<20}=  {f} with=  {f}\n", .{ m.name, sci(try defined(r.at), 6), sci(r.value, 6) });
            return r.at;
        },
        .pp => {
            const lo = try defined((try w.extremum(a, .min)).value);
            const hi = try defined((try w.extremum(a, .max)).value);
            try out.print("{s:<20}=  {f} from=  {f} to=  {f}\n", .{ m.name, sci(hi - lo, 6), sci(a.from, 6), sci(a.to, 6) });
            return hi - lo;
        },
        .param => {
            const v = try defined(paramValue(m.expr, w.values));
            try out.print("{s:<20}=  {f}\n", .{ m.name, sci(v, 5) });
            return v;
        },
        .err, .err1, .err2, .err3 => {
            const v = try defined(try w.relError(a, m.func));
            try out.print("{s:<20}=  {f}\n", .{ m.name, sci(v, 6) });
            return v;
        },
        .thd, .snr, .sndr, .enob, .sfdr => {
            const v = try defined(fftFigure(try w.column(a.vec, 'm'), w.scale(), w.len(), a, m.func));
            try out.print("{s:<20}=  {f}\n", .{ m.name, sci(v, 6) });
            return v;
        },
        .check_slew, .check_forbid, .check_require, .check_level, .dout => {
            const n = try w.violations(out, m.name, a, b, m.func, m.check);
            try out.print("{s:<20}=  {d}\n", .{ m.name, n });
            return @floatFromInt(n);
        },
    }
}

/// Logic transitions of a waveform between thresholds `lo` and `hi`.
const Edges = struct {
    x: Column,
    y: Column,
    n: usize,
    lo: f64,
    hi: f64,
    i: usize = 1,
    state: enum { low, high, rising, falling, unknown } = .unknown,
    start: f64 = 0,

    const Edge = struct {
        rise: bool,
        start: f64,
        end: f64,

        fn at(e: Edge) f64 {
            return 0.5 * (e.start + e.end);
        }

        fn is(e: Edge, want: core.Check.Edge) bool {
            return want == .both or e.rise == (want == .rise);
        }
    };

    fn next(e: *Edges) ?Edge {
        if (e.i == 1 and e.n > 0) {
            const y0 = e.y.get(0);
            e.state = if (y0 <= e.lo) .low else if (y0 >= e.hi) .high else .unknown;
        }
        while (e.i < e.n) {
            const x0 = e.x.get(e.i - 1);
            const x1 = e.x.get(e.i);
            const y0 = e.y.get(e.i - 1);
            const y1 = e.y.get(e.i);
            e.i += 1;
            if (e.state == .low and y1 > e.lo) {
                e.state = .rising;
                e.start = crossing(x0, y0, x1, y1, e.lo);
            } else if (e.state == .high and y1 < e.hi) {
                e.state = .falling;
                e.start = crossing(x0, y0, x1, y1, e.hi);
            }
            switch (e.state) {
                .rising => if (y1 >= e.hi) {
                    e.state = .high;
                    return .{ .rise = true, .start = e.start, .end = crossing(x0, y0, x1, y1, e.hi) };
                } else if (y1 <= e.lo) {
                    e.state = .low;
                },
                .falling => if (y1 <= e.lo) {
                    e.state = .low;
                    return .{ .rise = false, .start = e.start, .end = crossing(x0, y0, x1, y1, e.lo) };
                } else if (y1 >= e.hi) {
                    e.state = .high;
                },
                .unknown => e.state = if (y1 <= e.lo) .low else if (y1 >= e.hi) .high else .unknown,
                .low, .high => {},
            }
        }
        return null;
    }
};

/// Where the segment (x0, y0)-(x1, y1) meets `level`.
fn crossing(x0: f64, y0: f64, x1: f64, y1: f64, level: f64) f64 {
    return if (y1 == y0) x1 else x0 + (level - y0) * (x1 - x0) / (y1 - y0);
}

/// `c` with its refs to earlier results applied; OutOfInterval when one
/// has no value.
fn resolve(c: Clause, values: []const f64) !Clause {
    var r = c;
    for (c.refs) |ref| {
        const v = try defined(paramValue(ref.expr, values));
        switch (ref.field) {
            .val => r.val = v,
            .td => r.td = v,
            .from => r.from = v,
            .to => r.to = v,
            .at => r.at = v,
        }
    }
    return r;
}

/// A `_CONT` card: the event it names and every later one, printed as
/// `name[k]`. Returns the first; OutOfInterval when there is none.
fn evaluateCont(out: *Writer, card: core.Measure, w: Wave) EvalError!f64 {
    assert(card.cont);
    var m = card;
    m.first = try resolve(card.first, w.values);
    m.second = try resolve(card.second, w.values);
    var first: f64 = nan;
    var buf: [96]u8 = undefined;
    var k: i32 = 0;
    // Ends when the events run out: `nth` is null past an AT clause, and
    // event k + 1 needs k + 1 crossings, so once k passes the sample count
    // `when` finds none and `evaluate` fails OutOfInterval.
    while (true) : (k += 1) {
        assert(@as(usize, @intCast(k)) <= w.len() + 1);
        var one = m;
        one.cont = false;
        one.name = std.fmt.bufPrint(&buf, "{s}[{d}]", .{ m.name, k + 1 }) catch m.name;
        switch (m.func) {
            .trig_targ => {
                one.first = nth(m.first, k) orelse break;
                one.second = nth(m.second, k) orelse break;
            },
            // FIND or DERIV at a fixed AT= has the one event (#68).
            .find, .deriv => if (m.first.at != core.measure_no_at) {
                one.first = nth(m.first, k) orelse break;
            } else {
                one.second = nth(m.second, k) orelse break;
            },
            .when => one.first = nth(m.first, k) orelse break,
            else => return evaluate(out, one, w), // else: a function without event vectors runs once
        }
        const v = evaluate(out, one, w) catch |e| switch (e) {
            error.OutOfInterval => break,
            else => return e, // else: every other failure is the caller's
        };
        if (k == 0) first = v;
        if (lastEvent(m.first) or lastEvent(m.second)) break;
    }
    return defined(first);
}

fn lastEvent(c: Clause) bool {
    return c.rise == core.measure_last or c.fall == core.measure_last or c.cross == core.measure_last;
}

/// `c` counting `k` events past the one it names (CROSS=1 when it names
/// none); null for an `AT=` clause past its one value.
fn nth(c: Clause, k: i32) ?Clause {
    assert(k >= 0);
    if (c.at != core.measure_no_at) return if (k == 0) c else null;
    var r = c;
    if (c.rise > 0) r.rise = c.rise + k else if (c.fall > 0) r.fall = c.fall + k else if (c.cross > 0) r.cross = c.cross + k else if (!lastEvent(c)) r.cross = 1 + k;
    return r;
}

/// An FFT figure of merit over the magnitude spectrum `mag` on `freq`
/// [SA Ch.15, CR .MEASURE FFT]. The fundamental is the largest non-DC bin;
/// its harmonics are its bin multiples up to NBHARM (every one when 0) and
/// MAXFREQ; BINSIZ bins either side of it count as signal. THD is the ratio
/// sqrt(Σ harmonic²)/fundamental; SNR leaves the harmonics out of the noise,
/// SNDR keeps them, both in dB over every other non-DC bin; ENOB is
/// (SNDR − 1.76)/6.02; SFDR is the fundamental over the largest other bin
/// in [MINFREQ, MAXFREQ], in dB. NaN for a spectrum with no non-DC bin.
fn fftFigure(mag: Column, freq: Column, n: usize, c: Clause, func: core.MeasureFunc) f64 {
    if (n < 2) return nan;
    var k0: usize = 0;
    for (1..n) |k| if (k0 == 0 or mag.get(k) > mag.get(k0)) {
        k0 = k;
    };
    if (k0 == 0) return nan;
    assert(k0 < n);
    const fund = mag.get(k0);
    var harmonics: f64 = 0;
    var noise: f64 = 0;
    var spur: f64 = 0;
    for (1..n) |k| {
        const d = if (k > k0) k - k0 else k0 - k;
        if (d <= c.binsiz) continue;
        const v = mag.get(k);
        const f = freq.get(k);
        const h = k / k0;
        const harmonic = k % k0 == 0 and (c.nbharm == 0 or h <= c.nbharm) and f <= c.to;
        if (harmonic) harmonics += v * v else noise += v * v;
        if (f >= c.from and f <= c.to) spur = @max(spur, v);
    }
    const sndr = 10 * std.math.log10(fund * fund / (harmonics + noise));
    return switch (func) {
        .thd => @sqrt(harmonics) / fund,
        .snr => 10 * std.math.log10(fund * fund / noise),
        .sndr => sndr,
        .enob => (sndr - 1.76) / 6.02,
        .sfdr => 20 * std.math.log10(fund / spur),
        else => unreachable, // else: `fftFigure` is called with the five FFT functions only
    };
}

/// Folds a PARAM card's postfix over the results in `values`; NaN when a
/// result it reads is missing or it reads a vector.
fn paramValue(ops: []const core.MeasureOp, values: []const f64) f64 {
    return fold(ops, struct {
        values: []const f64,
        fn leaf(s: @This(), op: core.MeasureOp, _: usize) f64 {
            return switch (op) {
                .num => |x| x,
                .measure => |k| if (k < s.values.len) s.values[k] else nan,
                .vector, .neg, .add, .sub, .mul, .div, .pow => nan,
            };
        }
    }{ .values = values });
}

/// Folds measure postfix; `leaves.leaf(op, v)` values each `num`, `measure`
/// and `vector` op, `v` counting the vector ops before it. NaN on a stack
/// overflow or underflow, or a malformed tail.
fn fold(ops: []const core.MeasureOp, leaves: anytype) f64 {
    var stack: [32]f64 = undefined;
    var n: usize = 0;
    var vectors: usize = 0;
    for (ops) |op| switch (op) {
        .num, .measure, .vector => {
            if (n == stack.len) return nan;
            stack[n] = leaves.leaf(op, vectors);
            vectors += @intFromBool(op == .vector);
            n += 1;
        },
        .neg => {
            if (n == 0) return nan;
            stack[n - 1] = -stack[n - 1];
        },
        .add, .sub, .mul, .div, .pow => {
            if (n < 2) return nan;
            n -= 1;
            const b = stack[n];
            const x = &stack[n - 1];
            x.* = switch (op) {
                .add => x.* + b,
                .sub => x.* - b,
                .mul => x.* * b,
                .div => x.* / b,
                .pow => std.math.pow(f64, x.*, b),
                .num, .measure, .vector, .neg => unreachable,
            };
        },
    };
    assert(n <= stack.len);
    assert(vectors <= ops.len);
    return if (n == 1) stack[0] else nan;
}

fn defined(x: f64) error{OutOfInterval}!f64 {
    return if (std.math.isNan(x)) error.OutOfInterval else x;
}

/// A result column, real or read out of complex samples as `vectype` says
/// (ngspice get_value), or a `par()` waveform over other columns.
const Column = struct {
    data: []const f64,
    stride: usize,
    offset: usize,
    complex: bool,
    vectype: u8,
    /// `par()` postfix and the result labels its vectors name.
    ops: []const core.MeasureOp = &.{},
    names: []const []const u8 = &.{},
    /// Column index of each of the first `par_count` vector ops in `ops`,
    /// resolved once by `Wave.waveform` instead of by name per sample.
    // ponytail: 8 slots; vectors past the 8th fall back to a name lookup
    // per sample. Widen if par() expressions grow.
    par_cols: [8]u32 = undefined,
    par_count: u8 = 0,

    fn get(c: Column, i: usize) f64 {
        if (c.ops.len != 0) return fold(c.ops, Sample{ .column = c, .i = i });
        const re = c.data[i * c.stride + c.offset];
        if (!c.complex) return re;
        const im = c.data[i * c.stride + c.offset + 1];
        return switch (c.vectype) {
            'm' => std.math.hypot(re, im),
            'i' => im,
            // ngspice radtodeg() converts only under `set units=degrees`.
            'p' => std.math.atan2(im, re),
            'd' => 20 * std.math.log10(std.math.hypot(re, im)),
            'g' => std.math.radiansToDegrees(std.math.atan2(im, re)),
            else => re, // else: 'r' and an untyped column read the real part
        };
    }
};

/// Sample `i` of the columns a `par()` waveform reads.
const Sample = struct {
    column: Column,
    i: usize,

    fn leaf(s: Sample, op: core.MeasureOp, v: usize) f64 {
        return switch (op) {
            .num => |x| x,
            .vector => |name| blk: {
                const p = s.column;
                const k = if (v < p.par_count) p.par_cols[v] else (columnIndex(p.names, name) orelse break :blk nan);
                const c: Column = .{ .data = p.data, .stride = p.stride, .offset = k * @as(usize, if (p.complex) 2 else 1), .complex = p.complex, .vectype = p.vectype };
                break :blk c.get(s.i);
            },
            .measure => nan,
            .neg, .add, .sub, .mul, .div, .pow => unreachable,
        };
    }
};

/// The column labelled `name`; a bare node name reads `v(name)`, as
/// ngspice's vector lookup does.
fn columnIndex(names: []const []const u8, name: []const u8) ?usize {
    var buf: [256]u8 = undefined;
    const alt = std.fmt.bufPrint(&buf, "v({s})", .{name}) catch name;
    for (names, 0..) |v, i| {
        if (std.ascii.eqlIgnoreCase(v, name) or std.ascii.eqlIgnoreCase(v, alt)) return i;
    }
    return null;
}

const Stat = struct { value: f64, at: f64 };

/// The result a card reads; column 0 is the scale (time, frequency, sweep).
const Wave = struct {
    result: core.Result,
    analysis: Kind,
    /// Results of the cards evaluated so far, by card index.
    values: []const f64 = &.{},
    /// What the card found while its run went, read in place of `result`.
    done: ?*Done = null,

    /// Sample count; 0 for a result whose rows streamed to a file.
    fn len(w: Wave) usize {
        return if (w.result.data.len == 0) 0 else w.result.npoints;
    }

    fn scale(w: Wave) Column {
        return w.col(0, 0);
    }

    fn col(w: Wave, i: usize, vectype: u8) Column {
        const width: usize = if (w.result.is_complex) 2 else 1;
        return .{ .data = w.result.data, .stride = w.result.varnames.len * width, .offset = i * width, .complex = w.result.is_complex, .vectype = vectype };
    }

    /// `name` as the result labels it (`columnIndex`).
    fn column(w: Wave, name: []const u8, vectype: u8) error{NoSuchVector}!Column {
        return w.col(columnIndex(w.result.varnames, name) orelse return error.NoSuchVector, vectype);
    }

    /// The vector `name`, or the `par()` waveform `ops` when given.
    fn waveform(w: Wave, name: []const u8, ops: []const core.MeasureOp, vectype: u8) error{NoSuchVector}!Column {
        if (ops.len == 0) return w.column(name, vectype);
        var c = w.col(0, vectype);
        c.ops = ops;
        c.names = w.result.varnames;
        for (ops) |op| if (op == .vector) {
            const k = columnIndex(w.result.varnames, op.vector) orelse return error.NoSuchVector;
            if (c.par_count < c.par_cols.len) {
                c.par_cols[c.par_count] = @intCast(k);
                c.par_count += 1;
            }
        };
        assert(c.par_count <= c.par_cols.len);
        return c;
    }

    /// Scale value of the event `c` names; NaN when it never happens
    /// (ngspice com_measure_when).
    fn when(w: Wave, c: Clause) !f64 {
        if (w.done) |d| return (try d.take())[0];
        var t: [1]f64 = .{nan};
        _ = try w.crossings(c, &t);
        return t[0];
    }

    /// The events `c` names into `times`, in one scan: `times[k]` is what
    /// `when` returns for `c` with its count raised by k. Returns how many
    /// were found, at most `times.len`. A clause with no count or a LAST
    /// count names one event.
    fn crossings(w: Wave, c: Clause, times: []f64) !usize {
        assert(times.len > 0);
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        const y2: ?Column = if (c.vec2.len > 0) try w.waveform(c.vec2, c.ops2, c.vectype) else null;
        var s: Cross = .init(c, w.analysis);
        for (0..w.len()) |i| {
            if (s.feed(times, x.get(i), y.get(i), if (y2) |c2| c2.get(i) else nan)) break;
        }
        return s.finish(times);
    }

    /// Violations of check `k` on `c`'s waveform (`ref`'s is the reference
    /// edge), one line each on `out`, after HSPICE's `.check`, `.dout` and
    /// `.biaschk` [CR .CHECK, .DOUT, .BIASCHK].
    // ponytail: SETUP/HOLD/EDGE rescan the node per reference edge,
    // O(edges x samples); merge the two edge streams if decks get long.
    fn violations(w: Wave, out: *Writer, name: []const u8, c: Clause, ref: Clause, func: core.MeasureFunc, k: core.Check) EvalError!u32 {
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        const node: Edges = .{ .x = x, .y = y, .n = w.len(), .lo = k.lo, .hi = k.hi };
        var n: u32 = 0;
        switch (func) {
            .check_slew => {
                var it = node;
                while (it.next()) |e| if (e.is(k.edge)) {
                    const d = e.end - e.start;
                    if (d >= k.min and d <= k.max) continue;
                    n += 1;
                    try out.print("  {s} violation: {s} at {f} took {f}\n", .{ name, if (e.rise) "rise" else "fall", sci(e.at(), 6), sci(d, 6) });
                };
            },
            .check_forbid, .check_require => {
                var refs: Edges = .{ .x = x, .y = try w.waveform(ref.vec, ref.ops, ref.vectype), .n = w.len(), .lo = k.lo, .hi = k.hi };
                while (refs.next()) |r| if (r.is(k.ref_edge)) {
                    var hits: u32 = 0;
                    var it = node;
                    while (it.next()) |e| if (e.is(k.edge) and e.at() >= r.at() + k.min and e.at() <= r.at() + k.max) {
                        hits += 1;
                        if (func == .check_forbid) try out.print("  {s} violation: {s} at {f}, reference edge at {f}\n", .{ name, if (e.rise) "rise" else "fall", sci(e.at(), 6), sci(r.at(), 6) });
                    };
                    if (func == .check_forbid) n += hits else if (hits == 0) {
                        n += 1;
                        try out.print("  {s} violation: no edge after reference edge at {f}\n", .{ name, sci(r.at(), 6) });
                    }
                };
            },
            .check_level => {
                var entered: ?f64 = null;
                for (0..w.len()) |i| {
                    const v = y.get(i);
                    const live = x.get(i) >= c.from and (c.to == 0 or x.get(i) <= c.to);
                    const outside = live and (v < k.min or v > k.max);
                    if (outside and entered == null) {
                        entered = if (i == 0) x.get(0) else crossing(x.get(i - 1), y.get(i - 1), x.get(i), v, if (v > k.max) k.max else k.min);
                    } else if (!outside and entered != null) {
                        const left = crossing(x.get(i - 1), y.get(i - 1), x.get(i), v, if (y.get(i - 1) > k.max) k.max else k.min);
                        if (left - entered.? > k.dur or k.dur == 0) {
                            n += 1;
                            try out.print("  {s} violation: from {f} to {f}\n", .{ name, sci(entered.?, 6), sci(left, 6) });
                        }
                        entered = null;
                    }
                }
                if (entered) |t| if (x.get(w.len() - 1) - t > k.dur or k.dur == 0) {
                    n += 1;
                    try out.print("  {s} violation: from {f} to the end\n", .{ name, sci(t, 6) });
                };
            },
            .dout => for (k.expect) |e| {
                const v = try w.valueAt(c, e[0]);
                const one = if (k.lo == k.hi) v > k.hi else v >= k.hi;
                const zero = if (k.lo == k.hi) !one else v <= k.lo;
                if (if (e[1] == 1) one else zero) continue;
                n += 1;
                try out.print("  {s} violation: expected {d} at {f}, got {f}\n", .{ name, @as(u8, @intFromFloat(e[1])), sci(e[0], 6), sci(v, 6) });
            },
            else => unreachable, // else: `violations` is called with the check functions only
        }
        return n;
    }

    /// The vector interpolated at scale value `at`; NaN outside the sweep
    /// (ngspice measure_at).
    fn valueAt(w: Wave, c: Clause, at: f64) !f64 {
        return w.segment(c, .{ .at = at, .dc = w.analysis == .dc });
    }

    /// Slope of the vector against the scale at `at`, off the sample pair
    /// around it; NaN outside the sweep.
    fn slopeAt(w: Wave, c: Clause, at: f64) !f64 {
        return w.segment(c, .{ .at = at, .dc = w.analysis == .dc, .slope = true });
    }

    fn segment(w: Wave, c: Clause, pass: At) !f64 {
        if (w.done) |d| return (try d.take())[0];
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        var s = pass;
        for (0..w.len()) |i| if (s.feed(x.get(i), y.get(i))) break;
        return s.value;
    }

    /// HSPICE's ERR family over the window [SA Ch.11 "Error Equations"]:
    /// with e = (M - C) / M, M = `c.vec` floored at `c.minval`, C =
    /// `c.vec2`, ERR and ERR1 return the RMS of e and ERR2 the mean of |e|.
    /// ERR3 takes e = +-log|M/C| / log(M), signed as M/C, reduced as ERR1.
    /// Points with |M| outside [ymin, ymax] are skipped; NaN when none is left.
    fn relError(w: Wave, c: Clause, func: core.MeasureFunc) !f64 {
        if (w.done) |d| return (try d.take())[0];
        const x = w.scale();
        const mv = try w.waveform(c.vec, c.ops, c.vectype);
        const cv = try w.column(c.vec2, c.vectype);
        var s: RelError = .{ .c = c, .dc = w.analysis == .dc, .func = func };
        for (0..w.len()) |i| if (s.feed(x.get(i), mv.get(i), cv.get(i))) break;
        return s.value();
    }

    /// MIN/MAX (value, where) or AVG (trapezoidal mean, last scale read)
    /// over the window, without interpolating its ends (ngspice
    /// measure_minMaxAvg).
    fn extremum(w: Wave, c: Clause, op: Extremum.Op) !Stat {
        if (w.done) |d| {
            const v = try d.take();
            return .{ .value = v[0], .at = v[1] };
        }
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        var s: Extremum = .{ .c = c, .dc = w.analysis == .dc, .op = op };
        for (0..w.len()) |i| if (s.feed(x.get(i), y.get(i))) break;
        return s.stat();
    }

    const Integral = struct { value: f64, from: f64, to: f64 };

    const Jitter = struct { rms: f64, pp: f64, period: f64, edges: u32 };

    /// Time interval error of the repeating event `c` names (rising edges
    /// unless it counts falls or crossings) after `c.td`: each event time
    /// minus the least-squares line through event time against index, the
    /// ideal clock the edges recover. OutOfInterval below three events.
    /// Reads the first 4096 events.
    fn jitter(w: Wave, c: Clause) !Jitter {
        var times: [4096]f64 = undefined;
        var e = c;
        if (c.fall > 0) e.fall = 1 else if (c.cross > 0) e.cross = 1 else e.rise = 1;
        const n = try w.crossings(e, &times);
        assert(n <= times.len);
        if (n < 3) return error.OutOfInterval;
        const count: f64 = @floatFromInt(n);
        var sx: f64 = 0;
        var st: f64 = 0;
        for (times[0..n], 0..) |t, i| {
            sx += @floatFromInt(i);
            st += t;
        }
        const mx = sx / count;
        const mt = st / count;
        var sxx: f64 = 0;
        var sxt: f64 = 0;
        for (times[0..n], 0..) |t, i| {
            const dx = @as(f64, @floatFromInt(i)) - mx;
            sxx += dx * dx;
            sxt += dx * (t - mt);
        }
        const period = sxt / sxx;
        var sum2: f64 = 0;
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (times[0..n], 0..) |t, i| {
            const tie = t - (mt + period * (@as(f64, @floatFromInt(i)) - mx));
            sum2 += tie * tie;
            lo = @min(lo, tie);
            hi = @max(hi, tie);
        }
        return .{ .rms = @sqrt(sum2 / count), .pp = hi - lo, .period = period, .edges = @intCast(n) };
    }

    /// HSPICE EM_AVG over the window [CR .MEASURE (AVG, EM_AVG, ...)]:
    /// with I+ and I- the trapezoidal averages of the positive and negative
    /// parts (each segment split at its zero crossing), max(I+, I-) minus
    /// `c.val` (`.option em_recovery`) times min(I+, I-). The window ends
    /// are samples, as AVG's.
    fn emAvg(w: Wave, c: Clause) !Integral {
        if (w.done) |d| {
            const v = try d.take();
            return .{ .value = v[0], .from = v[1], .to = v[2] };
        }
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        var s: EmAvg = .{ .c = c };
        for (0..w.len()) |i| if (s.feed(x.get(i), y.get(i))) break;
        return s.result();
    }

    /// Integral, or RMS, of the vector over [from, to], ends interpolated,
    /// by composite Simpson 3/8, Simpson 1/3 and trapezoid panels as the
    /// sample spacing allows (ngspice measure_rms_integral).
    fn rmsInteg(w: Wave, c: Clause, rms: bool) !Integral {
        if (w.done) |d| {
            const v = try d.take();
            return .{ .value = v[0], .from = v[1], .to = v[2] };
        }
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        var s: Integ = .{ .c = c, .rms = rms };
        for (0..w.len()) |i| if (s.feed(x.get(i), y.get(i))) break;
        return s.result();
    }
};

/// Area under max(v, 0) over one linear segment from `v0` to `v1`, `dx` wide.
fn positiveArea(v0: f64, v1: f64, dx: f64) f64 {
    if (v0 >= 0 and v1 >= 0) return 0.5 * (v0 + v1) * dx;
    if (v0 <= 0 and v1 <= 0) return 0;
    const hi = @max(v0, v1);
    return 0.5 * hi * dx * hi / (hi - @min(v0, v1));
}

/// ngspice measure_interpolate, 'y' mode: the line through samples i and j
/// at scale value `at`, in slope-intercept form for the same rounding.
fn interpolate(x: Column, y: Column, i: usize, j: usize, at: f64) f64 {
    assert(i < j);
    return line(x.get(i), y.get(i), x.get(j), y.get(j), at);
}

/// The line through (x0, y0) and (x1, y1) at `at`, as `interpolate`.
fn line(x0: f64, y0: f64, x1: f64, y1: f64, at: f64) f64 {
    const slope = (y1 - y0) / (x1 - x0);
    const intercept = y0 - slope * x0;
    return slope * at + intercept;
}

// The passes below read a waveform one sample at a time, in order, and
// `feed` returns true where the whole-waveform loop would stop. `Wave` runs
// them over a recording and `Stream` over a run as it goes, so both give
// the same values, to the bit.

/// `Wave.crossings`' event count (ngspice com_measure_when).
const Cross = struct {
    c: Clause,
    analysis: Kind,
    td: f64,
    /// The counts the next event needs.
    want: Clause,
    rise: i32 = 0,
    fall: i32 = 0,
    cross: i32 = 0,
    above: bool = false,
    pending: bool = false,
    last: f64 = nan,
    first: u32 = 0,
    prev: f64 = 0,
    prev2: f64 = 0,
    prev_x: f64 = 0,
    rows: usize = 0,
    /// Events found, and whether the scan stopped on one (LAST is not added then).
    n: usize = 0,
    ended: bool = false,

    fn init(c: Clause, analysis: Kind) Cross {
        return .{ .c = c, .analysis = analysis, .td = c.td, .want = c };
    }

    /// Reads sample (`xv`, `v`), `v2` being the level vector's (NaN
    /// without one), and adds the events it ends to `times`.
    fn feed(s: *Cross, times: []f64, xv: f64, v: f64, v2: f64) bool {
        const c = s.c;
        const dc = s.analysis == .dc;
        const has_y2 = c.vec2.len > 0;
        const i = s.rows;
        s.rows += 1;
        // A DC sweep may start anywhere: ngspice keeps its origin in td.
        if (dc and i == 0) s.td = xv;
        if ((s.analysis == .tran or s.analysis == .tran_noise) and xv < s.td) return false;
        if ((s.analysis == .ac or s.analysis == .sp) and xv < 0) return false;
        if (dc) {
            if (xv < c.from or xv > c.to) return false;
        } else {
            if (xv < c.from) return false;
            if (c.to != 0 and xv > c.to) return true;
        }
        if (s.first > 1 and dc and s.td == xv) s.first = 1;
        const level = if (has_y2) v2 else c.val;
        const prev_level = if (has_y2) s.prev2 else c.val;
        if (s.first == 1) {
            s.cross = 0;
            s.above = !(v < level);
            if (!s.above and s.prev >= prev_level) {
                s.fall = 1;
                s.cross = 1;
            } else if (s.above and s.prev < prev_level) {
                s.rise = 1;
                s.cross = 1;
            }
        }
        if (s.first > 1) {
            if (!s.above and v >= level) {
                s.above = true;
                s.cross += 1;
                s.rise += 1;
                if (c.fall != core.measure_last) s.pending = true;
            } else if (s.above and v <= level) {
                s.above = false;
                s.cross += 1;
                s.fall += 1;
                if (c.rise != core.measure_last) s.pending = true;
            }
            const hit = s.prev_x + (prev_level - s.prev) * (xv - s.prev_x) / (v - s.prev - level + prev_level);
            // Counters move by at most one per sample, so the event the
            // raised count names comes on a later sample.
            if (s.cross == s.want.cross or s.rise == s.want.rise or s.fall == s.want.fall) {
                times[s.n] = hit;
                s.n += 1;
                if (s.n == times.len) {
                    s.ended = true;
                    return true;
                }
                if (s.cross == s.want.cross) s.want.cross += 1;
                if (s.rise == s.want.rise) s.want.rise += 1;
                if (s.fall == s.want.fall) s.want.fall += 1;
            }
            if (s.pending) {
                if (c.cross == core.measure_unset and c.rise == core.measure_unset and c.fall == core.measure_unset) {
                    times[s.n] = hit;
                    s.n += 1;
                    s.ended = true;
                    return true;
                }
                if (c.cross == core.measure_last or c.rise == core.measure_last or c.fall == core.measure_last) s.last = hit;
                s.pending = false;
            }
        }
        s.first += 1;
        s.prev = v;
        if (has_y2) s.prev2 = v2;
        s.prev_x = xv;
        return false;
    }

    /// How many events `times` holds, a LAST count's appended; once the
    /// scan has stopped or read every sample.
    fn finish(s: Cross, times: []f64) usize {
        if (s.ended or std.math.isNan(s.last)) return s.n;
        times[s.n] = s.last;
        return s.n + 1;
    }
};

/// `Wave.valueAt` and `slopeAt`: the first segment holding `at`.
const At = struct {
    at: f64,
    dc: bool = false,
    slope: bool = false,
    rows: usize = 0,
    px: f64 = 0,
    pv: f64 = 0,
    value: f64 = nan,

    fn feed(s: *At, xv: f64, v: f64) bool {
        if (s.rows > 0 and ((s.px <= s.at and xv >= s.at) or (s.dc and s.px >= s.at and xv <= s.at))) {
            s.value = if (s.slope) (v - s.pv) / (xv - s.px) else s.pv + (s.at - s.px) * (v - s.pv) / (xv - s.px);
            return true;
        }
        s.rows += 1;
        s.px = xv;
        s.pv = v;
        return false;
    }
};

/// `Wave.extremum`.
const Extremum = struct {
    c: Clause,
    dc: bool,
    op: Op,
    first: bool = false,
    m: f64 = 0,
    m_at: f64 = 0,
    xv: f64 = 0,
    pv: f64 = 0,
    px: f64 = 0,
    span: f64 = 0,

    const Op = enum { min, max, avg };

    fn feed(s: *Extremum, xv: f64, v: f64) bool {
        s.xv = xv;
        if (s.dc) {
            if (xv < s.c.from or xv > s.c.to) return false;
        } else {
            if (xv < s.c.from) return false;
            if (s.c.to != 0 and xv > s.c.to) return true;
        }
        if (!s.first) {
            s.first = true;
            s.m = if (s.op == .avg) 0 else v;
            s.m_at = xv;
            s.pv = v;
            s.px = xv;
            return false;
        }
        switch (s.op) {
            .min => if (v <= s.m) {
                s.m = v;
                s.m_at = xv;
            },
            .max => if (v >= s.m) {
                s.m = v;
                s.m_at = xv;
            },
            .avg => {
                s.m += 0.5 * (v + s.pv) * (xv - s.px);
                s.span += xv - s.px;
                s.pv = v;
                s.px = xv;
            },
        }
        return false;
    }

    fn stat(s: Extremum) Stat {
        return if (s.op == .avg) .{ .value = s.m / (if (s.first) s.span else 1), .at = s.xv } else .{ .value = s.m, .at = s.m_at };
    }
};

/// `Wave.emAvg`.
const EmAvg = struct {
    c: Clause,
    pos: f64 = 0,
    neg: f64 = 0,
    from: f64 = nan,
    to: f64 = nan,
    pv: f64 = 0,

    fn feed(s: *EmAvg, xv: f64, v: f64) bool {
        if (xv < s.c.from) return false;
        if (s.c.to != 0 and xv > s.c.to) return true;
        if (!std.math.isNan(s.from)) {
            s.pos += positiveArea(s.pv, v, xv - s.to);
            s.neg += positiveArea(-s.pv, -v, xv - s.to);
        } else s.from = xv;
        s.to = xv;
        s.pv = v;
        return false;
    }

    fn result(s: EmAvg) Wave.Integral {
        const span = s.to - s.from;
        if (!(span > 0)) return .{ .value = nan, .from = s.from, .to = s.to };
        return .{ .value = (@max(s.pos, s.neg) - s.c.val * @min(s.pos, s.neg)) / span, .from = s.from, .to = s.to };
    }
};

/// `Wave.relError`.
const RelError = struct {
    c: Clause,
    dc: bool,
    func: core.MeasureFunc,
    sum: f64 = 0,
    count: f64 = 0,

    fn feed(s: *RelError, xv: f64, m: f64, calc: f64) bool {
        const c = s.c;
        if (s.dc) {
            if (xv < c.from or xv > c.to) return false;
        } else {
            if (xv < c.from) return false;
            if (c.to != 0 and xv > c.to) return true;
        }
        if (@abs(m) < c.ymin or @abs(m) > c.ymax) return false;
        const d = if (@abs(m) < c.minval) c.minval else m;
        // ponytail: the manual gives no reduction for ERR3; RMS, as ERR1.
        const e = if (s.func == .err3) std.math.sign(m / calc) * @log(@abs(m / calc)) / @log(d) else (m - calc) / d;
        s.sum += if (s.func == .err2) @abs(e) else e * e;
        s.count += 1;
        return false;
    }

    fn value(s: RelError) f64 {
        if (s.count == 0) return nan;
        return if (s.func == .err2) s.sum / s.count else @sqrt(s.sum / s.count);
    }
};

/// `Wave.rmsInteg`: the window's points, from the first sample at or past
/// `from` (read as the value at a nonzero `from`) to the first past a
/// nonzero `to` (read as the value at `to`), each panel taking the next
/// four points' spacing; points past the window read zero, as in
/// ngspice's zeroed buffers.
const Integ = struct {
    c: Clause,
    rms: bool,
    inside: bool = false,
    /// Samples read, and the last one raw: an interpolated end's left side.
    rows: usize = 0,
    px: f64 = 0,
    py: f64 = 0,
    /// Window points not in a panel yet, oldest first, as (scale, value or
    /// value squared).
    p: [4][2]f64 = undefined,
    np: usize = 0,
    count: usize = 0,
    first_x: f64 = nan,
    cut: bool = false,
    cut_x: f64 = nan,
    sum: [3]f64 = .{ 0, 0, 0 },

    fn feed(s: *Integ, xv: f64, v: f64) bool {
        defer {
            s.rows += 1;
            s.px = xv;
            s.py = v;
        }
        const c = s.c;
        if (!s.inside) {
            if (xv < c.from) return false;
            s.inside = true;
        }
        s.cut = c.to != 0 and xv > c.to;
        var pt: [2]f64 = .{ xv, v };
        if (s.cut) {
            if (s.rows > 0 and !almostEqualUlps(xv, c.to)) pt = .{ c.to, line(s.px, s.py, xv, v, c.to) };
        } else if (s.count == 0 and c.from != 0 and s.rows > 0 and !almostEqualUlps(xv, c.from)) {
            pt = .{ c.from, line(s.px, s.py, xv, v, c.from) };
        }
        if (s.rms) pt[1] = pt[1] * pt[1];
        if (s.count == 0) s.first_x = pt[0];
        if (s.cut) s.cut_x = pt[0];
        s.count += 1;
        s.p[s.np] = pt;
        s.np += 1;
        if (s.np == s.p.len) s.panel(s.np);
        return s.cut;
    }

    /// Folds the oldest points into one panel; `avail` of `p` are points,
    /// the rest read zero, and a spacing past them zero.
    fn panel(s: *Integ, avail: usize) void {
        assert(avail >= 2 and avail <= s.p.len);
        var p = s.p;
        for (p[avail..]) |*q| q.* = .{ 0, 0 };
        var width: [3]f64 = undefined;
        for (&width, 0..) |*d, j| d.* = if (j + 1 < avail) p[j + 1][0] - p[j][0] else 0;
        const used: usize = if (almostEqualUlps(width[0], width[1]) and almostEqualUlps(width[0], width[2])) blk: {
            s.sum[0] += 3 * width[0] * (p[0][1] + 3 * (p[1][1] + p[2][1]) + p[3][1]) / 8.0;
            break :blk 3;
        } else if (almostEqualUlps(width[0], width[1])) blk: {
            s.sum[1] += width[0] * (p[0][1] + 4 * p[1][1] + p[2][1]) / 3.0;
            break :blk 2;
        } else blk: {
            s.sum[2] += width[0] * (p[0][1] + p[1][1]) / 2;
            break :blk 1;
        };
        s.np = avail -| used;
        std.mem.copyForwards([2]f64, s.p[0..s.np], s.p[avail - s.np .. avail]);
    }

    fn result(s: *Integ) Wave.Integral {
        if (s.rows == 0) return .{ .value = nan, .from = nan, .to = nan };
        while (s.np > 1) s.panel(s.np);
        const from = if (s.count > @intFromBool(s.cut)) s.first_x else nan;
        const to = if (s.cut) s.cut_x else s.px;
        const total = s.sum[0] + s.sum[1] + s.sum[2];
        return .{ .value = if (s.rms) @sqrt(total / (to - from)) else total, .from = from, .to = to };
    }
};

/// One pass of a `Stream` card, reading its columns off the stream's row.
const Scan = struct {
    y: Column = undefined,
    y2: ?Column = null,
    /// It names a vector the run lacks, which `evaluate` fails it for.
    missing: bool = false,
    /// No later row changes what it found.
    over: bool = false,
    time: [1]f64 = .{nan},
    pass: Pass,

    const Pass = union(enum) { cross: Cross, at: At, extremum: Extremum, integ: Integ, em_avg: EmAvg, rel_error: RelError };

    /// `pass` over clause `c`'s vector on `w`, with its level vector
    /// (`waveform`), its comparison vector (`column`, ERR*) or neither.
    fn init(w: Wave, c: Clause, pass: Pass, second: enum { none, waveform, column }) Scan {
        const missing: Scan = .{ .missing = true, .over = true, .pass = pass };
        var s: Scan = .{ .y = w.waveform(c.vec, c.ops, c.vectype) catch return missing, .pass = pass };
        switch (second) {
            .none => {},
            .waveform => if (c.vec2.len > 0) {
                s.y2 = w.waveform(c.vec2, c.ops2, c.vectype) catch return missing;
            },
            .column => s.y2 = w.column(c.vec2, c.vectype) catch return missing,
        }
        return s;
    }

    /// Reads the row its columns point at, scale `x`.
    fn feed(s: *Scan, x: f64) void {
        if (s.over) return;
        s.feedValues(x, s.y.get(0), if (s.y2) |c| c.get(0) else nan);
    }

    fn feedValues(s: *Scan, x: f64, y: f64, y2: f64) void {
        assert(!s.over);
        s.over = switch (s.pass) {
            .cross => |*c| c.feed(&s.time, x, y, y2),
            // A transient's times rise: past AT=, no later segment holds it.
            .at => |*a| a.feed(x, y) or x > a.at,
            .extremum => |*e| e.feed(x, y),
            .integ => |*g| g.feed(x, y),
            .em_avg => |*e| e.feed(x, y),
            .rel_error => |*r| r.feed(x, y, y2),
        };
    }

    /// What it found over the rows read, as the `Wave` function its pass
    /// stands for returns it. Call only once it reads no more rows.
    fn found(s: *Scan) core.Measured.Found {
        if (s.missing) return .{ .missing = true, .v = @splat(nan) };
        return .{ .v = switch (s.pass) {
            .cross => |c| blk: {
                _ = c.finish(&s.time);
                break :blk .{ s.time[0], 0, 0 };
            },
            .at => |a| .{ a.value, 0, 0 },
            .extremum => |e| blk: {
                const r = e.stat();
                break :blk .{ r.value, r.at, 0 };
            },
            .integ => |*g| blk: {
                const r = g.result();
                break :blk .{ r.value, r.from, r.to };
            },
            .em_avg => |e| blk: {
                const r = e.result();
                break :blk .{ r.value, r.from, r.to };
            },
            .rel_error => |r| .{ r.value(), 0, 0 },
        } };
    }
};

/// A card's passes as its run found them (`core.Measured`), handed to
/// `evaluate` in the order it reads them.
const Done = struct {
    found: []const core.Measured.Found,
    next: usize = 0,

    fn take(d: *Done) error{NoSuchVector}![3]f64 {
        assert(d.next < d.found.len);
        const f = d.found[d.next];
        d.next += 1;
        return if (f.missing) error.NoSuchVector else f.v;
    }
};

/// The wave card `i` reads over `result`: its columns, or what its run
/// found (`core.Result.measured`) through `done`.
fn cardWave(result: core.Result, analysis: Kind, values: []const f64, i: usize, done: *Done) Wave {
    var w: Wave = .{ .result = result, .analysis = analysis, .values = values };
    if (i < result.measured.len and result.measured[i].scans > 0) {
        const m = &result.measured[i];
        done.* = .{ .found = m.found[0..m.scans] };
        w.done = done;
    }
    return w;
}

/// ngspice AlmostEqualUlps(a, b, 100) (maths/misc/equality.c).
fn almostEqualUlps(a: f64, b: f64) bool {
    if (a == b) return true;
    const ordered = struct {
        fn f(d: f64) i64 {
            const i: i64 = @bitCast(d);
            return if (i < 0) std.math.minInt(i64) -% i else i;
        }
    }.f;
    return @abs(ordered(a) -% ordered(b)) <= 100;
}

/// C's `%.*e`, digit for digit: the exact binary value rounded half-to-even
/// (glibc's default), at least two exponent digits and an explicit sign.
fn sci(x: f64, comptime precision: u8) Sci {
    return .{ .x = x, .precision = precision };
}

const Sci = struct {
    x: f64,
    precision: u8,

    pub fn format(s: Sci, w: *Writer) Writer.Error!void {
        if (!std.math.isFinite(s.x)) {
            var buf: [64]u8 = undefined;
            return w.writeAll(std.fmt.float.render(&buf, s.x, .{ .mode = .scientific }) catch "?");
        }
        // The exact decimal of an f64 has at most 767 significant digits.
        var mem: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&mem);
        const exact, const k = exactDecimal(fba.allocator(), @abs(s.x)) catch return w.writeAll("?");
        const q = @as(usize, s.precision) + 1;
        var d: [32]u8 = @splat('0');
        const n = @min(exact.len, q);
        @memcpy(d[0..n], exact[0..n]);
        var e10: i32 = @as(i32, @intCast(exact.len)) - 1 + k;
        if (exact.len > q) {
            const r = exact[q];
            const odd = (d[q - 1] - '0') & 1 == 1;
            const rest = std.mem.trimEnd(u8, exact[q + 1 ..], "0").len != 0;
            if (r > '5' or (r == '5' and (rest or odd))) {
                var i = q;
                while (i > 0) : (i -= 1) {
                    if (d[i - 1] != '9') {
                        d[i - 1] += 1;
                        break;
                    }
                    d[i - 1] = '0';
                } else {
                    d[0] = '1'; // 9.99..9 carried into 10.00..0
                    e10 += 1;
                }
            }
        }
        if (s.x == 0) e10 = 0;
        if (std.math.signbit(s.x)) try w.writeByte('-');
        try w.writeByte(d[0]);
        if (q > 1) try w.print(".{s}", .{d[1..q]});
        try w.print("e{c}{d:0>2}", .{ @as(u8, if (e10 < 0) '-' else '+'), @abs(e10) });
    }
};

/// The exact decimal digits of finite `x >= 0` and their exponent: `x = digits × 10^k`.
/// An f64 is m·2^e exactly, and 2^-e = 5^e / 10^e, so the digits are an integer.
fn exactDecimal(a: std.mem.Allocator, x: f64) !struct { []const u8, i32 } {
    const Big = std.math.big.int.Managed;
    const bits: u64 = @bitCast(x);
    const biased: i32 = @intCast(bits >> 52 & 0x7ff);
    const frac = bits & (1 << 52) - 1;
    const m = if (biased == 0) frac else frac | 1 << 52;
    const e = @as(i32, @max(biased, 1)) - 1075;
    var d = try Big.initSet(a, m);
    if (e >= 0) {
        try d.shiftLeft(&d, @intCast(e));
    } else {
        var five = try Big.initSet(a, 5);
        try five.pow(&five, @intCast(-e));
        try d.mul(&d, &five);
    }
    return .{ try d.toString(a, 10, .lower), @min(e, 0) };
}

test "sci matches C %e digit for digit" {
    const libc = struct {
        extern "c" fn snprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) c_int;
    };
    const cases = [_]f64{
        0,                      -0.0,                       1,        -1,
        1.0000005,              2.5e-7,                     0.125,    9.9999995,
        9.9999996,              std.math.floatTrueMin(f64), 5e-324,   2.2250738585072014e-308,
        std.math.floatMax(f64), 1e300,                      123456.5, 0.1,
        999999.5,               1e-5,                       -3.25e10, 7.0000005e-12,
    };
    var prng: std.Random.DefaultPrng = .init(0x5c1);
    const rand = prng.random();
    var buf: [64]u8 = undefined;
    var want: [64]u8 = undefined;
    for (0..20000 + cases.len) |i| {
        const x: f64 = if (i < cases.len) cases[i] else blk: {
            const v: f64 = @bitCast(rand.int(u64));
            break :blk if (std.math.isFinite(v)) v else 1.5;
        };
        inline for (.{ 5, 6 }) |p| {
            var w: Writer = .fixed(&buf);
            try w.print("{f}", .{sci(x, p)});
            const len: usize = @intCast(libc.snprintf(&want, want.len, "%.*e", @as(c_int, p), x));
            try std.testing.expectEqualStrings(want[0..len], w.buffered());
        }
    }
}

test "measurements match ngspice on a sampled ramp" {
    // v(a) = t on t = 0..4, sampled every 1; v(b) falls 4..0.
    const data = [_]f64{ 0, 0, 4, 1, 1, 3, 2, 2, 2, 3, 3, 1, 4, 4, 0 };
    const result: core.Result = .{ .plotname = "t", .varnames = &.{ "time", "v(a)", "v(b)" }, .is_complex = false, .npoints = 5, .data = &data };
    const cards = [_]core.Measure{
        .{ .analysis = .tran, .name = "d", .func = .trig_targ, .first = .{ .vec = "v(a)", .val = 0.5, .rise = 1 }, .second = .{ .vec = "b", .val = 1.5, .fall = 1 } },
        .{ .analysis = .tran, .name = "f", .func = .find, .first = .{ .vec = "v(b)", .at = 2.5 } },
        .{ .analysis = .tran, .name = "i", .func = .integ, .first = .{ .vec = "v(a)" } },
        .{ .analysis = .tran, .name = "mx", .func = .max, .first = .{ .vec = "v(a)", .to = 3 } },
        .{ .analysis = .tran, .name = "gone", .func = .when, .first = .{ .vec = "v(a)", .val = 9 } },
        .{ .analysis = .ac, .name = "skipped", .func = .max, .first = .{ .vec = "v(a)" } },
        // HSPICE forms: DERIVATIVE, ERR2 (t = 0 falls under YMIN), PARAM.
        .{ .analysis = .tran, .name = "s", .func = .deriv, .first = .{ .vec = "v(b)", .at = 2.5 } },
        .{ .analysis = .tran, .name = "e", .func = .err2, .first = .{ .vec = "v(a)", .vec2 = "v(b)" } },
        .{ .analysis = .tran, .name = "p", .func = .param, .first = .{}, .expr = &.{ .{ .measure = 0 }, .{ .num = 2 }, .mul } },
    };
    var out_buf: [1024]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);
    try print(&out, &err, &cards, .tran, result, null);
    // Rise 1 of v(a) happens in the first interval, where ngspice only
    // initialises its counters: it is measured on the next one, by
    // extrapolating that segment (exact here, as v(a) is a line).
    try std.testing.expectEqualStrings(
        \\
        \\  Measurements for Transient Analysis
        \\
        \\d                   =  2.000000e+00 targ=  2.500000e+00 trig=  5.000000e-01
        \\f                   =  1.500000e+00
        \\i                   =   8.00000e+00 from=  0.00000e+00 to=  4.00000e+00
        \\mx                  =  3.000000e+00 at=  3.000000e+00
        \\s                   =  -1.000000e+00
        \\e                   =  9.166667e-01
        \\p                   =  4.00000e+00
        \\
    , out.buffered());
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "gone") != null);
}

/// v(a) = t and v(b) = 4 - t on t = 0..4, sampled every 1.
const ramp: core.Result = .{ .plotname = "t", .varnames = &.{ "time", "v(a)", "v(b)" }, .is_complex = false, .npoints = 5, .data = &.{ 0, 0, 4, 1, 1, 3, 2, 2, 2, 3, 3, 1, 4, 4, 0 } };

test "a _CONT FIND or DERIV at a fixed AT= has one event and prints one line" {
    const cards = [_]core.Measure{
        .{ .analysis = .tran, .name = "x", .func = .find, .cont = true, .first = .{ .vec = "v(a)", .at = 1.5 } },
        .{ .analysis = .tran, .name = "d", .func = .deriv, .cont = true, .first = .{ .vec = "v(b)", .at = 1.5 } },
    };
    var values: [cards.len]f64 = undefined;
    evaluateAll(&cards, .tran, ramp, &values);
    try std.testing.expectEqualSlices(f64, &.{ 1.5, -1 }, &values);
    var buf: [256]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try print(&out, &out, &cards, .tran, ramp, null);
    try std.testing.expectEqualStrings(
        \\
        \\  Measurements for Transient Analysis
        \\
        \\x[1]                =  1.500000e+00
        \\d[1]                =  -1.000000e+00
        \\
    , out.buffered());
}

test "AT= naming an earlier result reads that result, _CONT too" {
    const t50: []const core.MeasureOp = &.{.{ .measure = 0 }};
    const at_t50: []const core.MeasureRef = &.{.{ .field = .at, .expr = t50 }};
    const cards = [_]core.Measure{
        .{ .analysis = .tran, .name = "t", .func = .when, .first = .{ .vec = "v(a)", .val = 2.5 } },
        .{ .analysis = .tran, .name = "v", .func = .find, .first = .{ .vec = "v(b)", .refs = at_t50 } },
        .{ .analysis = .tran, .name = "c", .func = .find, .cont = true, .first = .{ .vec = "v(b)", .refs = at_t50 } },
    };
    var values: [cards.len]f64 = undefined;
    evaluateAll(&cards, .tran, ramp, &values);
    try std.testing.expectEqualSlices(f64, &.{ 2.5, 1.5, 1.5 }, &values);
}

test "every function over a result with no samples reads NaN or zero, never panics" {
    const funcs = comptime std.enums.values(core.MeasureFunc);
    var cards: [funcs.len]core.Measure = undefined;
    for (funcs, &cards) |f, *c| c.* = .{ .analysis = .tran, .name = "m", .func = f, .first = .{ .vec = "v(a)", .vec2 = "v(b)" }, .second = .{ .vec = "v(b)" } };
    var empty = ramp;
    empty.npoints = 0;
    empty.data = &.{};
    // A streamed result keeps its point count but no samples.
    var streamed = ramp;
    streamed.data = &.{};
    var buf: [64]u8 = undefined;
    var sink: Writer.Discarding = .init(&buf);
    for ([_]core.Result{ empty, streamed }) |result| {
        var values: [funcs.len]f64 = undefined;
        evaluateAll(&cards, .tran, result, &values);
        for (cards, values) |c, v| switch (c.func) {
            // ngspice measure_minMaxAvg reports 0 over an empty window, and
            // a check over no samples counts no violation.
            .avg, .min, .max, .min_at, .max_at, .pp, .check_slew, .check_forbid, .check_require, .check_level, .dout => try std.testing.expectEqual(0, v),
            else => try std.testing.expect(std.math.isNan(v)), // else: every other function has no value over no samples
        };
        try print(&sink.writer, &sink.writer, &cards, .tran, result, null);
        var out: [3]f64 = undefined;
        try sample(.{ .vec = "v(a)" }, result, &.{ -1, 0, 9 }, &out);
        for (out) |v| try std.testing.expect(std.math.isNan(v));
    }
}

test sample {
    var out: [5]f64 = undefined;
    try sample(.{ .vec = "v(a)" }, ramp, &.{ -1, 0, 2.5, 3, 9 }, &out);
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 2.5, 3, 4 }, &out);
    try std.testing.expectError(error.NoSuchVector, sample(.{ .vec = "v(z)" }, ramp, &.{0}, out[0..1]));
}

test printStatistics {
    var doubled = ramp;
    doubled.data = &.{ 0, 0, 0, 1, 2, 0, 2, 4, 0, 3, 6, 0, 4, 8, 0 };
    const cards = [_]core.Measure{
        .{ .analysis = .tran, .name = "mx", .func = .max, .first = .{ .vec = "a" } },
        .{ .analysis = .tran, .name = "p", .func = .param, .first = .{}, .expr = &.{ .{ .measure = 0 }, .{ .num = 2 }, .mul } },
        // A PARAM reads only the cards before it: `late` is NaN here.
        .{ .analysis = .tran, .name = "q", .func = .param, .first = .{}, .expr = &.{.{ .measure = 3 }} },
        .{ .analysis = .tran, .name = "late", .func = .max, .first = .{ .vec = "v(a)" } },
        .{ .analysis = .ac, .name = "other", .func = .max, .first = .{ .vec = "v(a)" } },
    };
    var buf: [1024]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try printStatistics(&out, &cards, .tran, &.{ ramp, doubled });
    try std.testing.expectEqualStrings(
        \\
        \\  Monte Carlo statistics over 2 trials
        \\
        \\mean(mx) = 6.000000e+00
        \\sigma(mx) = 2.828427e+00
        \\min(mx) = 4.000000e+00
        \\max(mx) = 8.000000e+00
        \\mean(p) = 1.200000e+01
        \\sigma(p) = 5.656854e+00
        \\min(p) = 8.000000e+00
        \\max(p) = 1.600000e+01
        \\mean(late) = 6.000000e+00
        \\sigma(late) = 2.828427e+00
        \\min(late) = 4.000000e+00
        \\max(late) = 8.000000e+00
        \\
    , out.buffered());
}

test "FFT figures of merit over a synthetic spectrum" {
    // DC 5 (ignored), fundamental 1 at bin 2, harmonics 0.1 at bins 4 and
    // 6, noise 0.01 in every odd bin.
    const spectrum: core.Result = .{ .plotname = "fft", .varnames = &.{ "frequency", "v(o)" }, .is_complex = false, .npoints = 8, .data = &.{ 0, 5, 1, 0.01, 2, 1, 3, 0.01, 4, 0.1, 5, 0.01, 6, 0.1, 7, 0.01 } };
    const clause: Clause = .{ .vec = "v(o)", .to = 100 };
    const cards = [_]core.Measure{
        .{ .analysis = .fft, .name = "thd", .func = .thd, .first = clause },
        .{ .analysis = .fft, .name = "snr", .func = .snr, .first = clause },
        .{ .analysis = .fft, .name = "sfdr", .func = .sfdr, .first = clause },
    };
    var values: [cards.len]f64 = undefined;
    evaluateAll(&cards, .fft, spectrum, &values);
    try std.testing.expectApproxEqRel(@sqrt(0.02), values[0], 1e-12);
    try std.testing.expectApproxEqRel(10 * std.math.log10(2500.0), values[1], 1e-12);
    try std.testing.expectApproxEqRel(20, values[2], 1e-12);
}

test "par() waveforms resolve their vectors, past the cached eight too" {
    const v: core.MeasureOp = .{ .vector = "v(a)" };
    const nine = [_]core.MeasureOp{ v, v, .add, v, .add, v, .add, v, .add, v, .add, v, .add, v, .add, v, .add };
    const cards = [_]core.Measure{
        .{ .analysis = .tran, .name = "sum", .func = .max, .first = .{ .ops = &.{ .{ .vector = "a" }, .{ .vector = "v(b)" }, .add } } },
        .{ .analysis = .tran, .name = "nine", .func = .max, .first = .{ .ops = &nine } },
        .{ .analysis = .tran, .name = "missing", .func = .max, .first = .{ .ops = &.{.{ .vector = "v(z)" }} } },
    };
    var values: [cards.len]f64 = undefined;
    evaluateAll(&cards, .tran, ramp, &values);
    try std.testing.expectEqual(4, values[0]);
    try std.testing.expectEqual(36, values[1]);
    try std.testing.expect(std.math.isNan(values[2]));
}

test "malformed PARAM postfix reads NaN" {
    try std.testing.expect(std.math.isNan(paramValue(&.{.add}, &.{})));
    try std.testing.expect(std.math.isNan(paramValue(&.{.neg}, &.{})));
    try std.testing.expect(std.math.isNan(paramValue(&.{ .{ .num = 1 }, .{ .num = 2 } }, &.{})));
    try std.testing.expect(std.math.isNan(paramValue(&.{.{ .measure = 7 }}, &.{1})));
    const deep: [33]core.MeasureOp = @splat(.{ .num = 1 });
    try std.testing.expect(std.math.isNan(paramValue(&deep, &.{})));
    try std.testing.expectEqual(-6, paramValue(&.{ .{ .num = 2 }, .{ .measure = 0 }, .pow, .neg, .{ .num = 2 }, .sub }, &.{2}));
}

test "crossings, windows, NaN samples and a single point match ngspice 45" {
    // Each expected listing is what ngspice 45 prints for the same cards over
    // the same samples, loaded from an ASCII raw file; a failed card prints
    // nothing to `out`.
    const tri: core.Result = .{ .plotname = "t", .varnames = &.{ "time", "v(a)" }, .is_complex = false, .npoints = 9, .data = &.{ 0, 0, 1, 2, 2, 0, 3, 2, 4, 0, 5, 2, 6, 0, 7, 2, 8, 0 } };
    const with_nan: core.Result = .{ .plotname = "t", .varnames = &.{ "time", "v(a)" }, .is_complex = false, .npoints = 5, .data = &.{ 0, 0, 1, 1, 2, nan, 3, 3, 4, 2 } };
    const one: core.Result = .{ .plotname = "t", .varnames = &.{ "time", "v(a)" }, .is_complex = false, .npoints = 1, .data = &.{ 0, 5 } };
    const last = core.measure_last;
    const a: Clause = .{ .vec = "v(a)" };
    const tri_cards = [_]core.Measure{
        // RISE=1 falls in the first interval, which only primes the counters:
        // ngspice reports the next crossing, the fall at 1.5.
        .{ .analysis = .tran, .name = "r1", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .rise = 1 } },
        .{ .analysis = .tran, .name = "r2", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .rise = 2 } },
        .{ .analysis = .tran, .name = "f1", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .fall = 1 } },
        .{ .analysis = .tran, .name = "c1", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .cross = 1 } },
        .{ .analysis = .tran, .name = "c3", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .cross = 3 } },
        .{ .analysis = .tran, .name = "fl", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .fall = last } },
        .{ .analysis = .tran, .name = "rl", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .rise = last } },
        .{ .analysis = .tran, .name = "cl", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .cross = last } },
        .{ .analysis = .tran, .name = "w0", .func = .when, .first = .{ .vec = "v(a)", .val = 1 } },
        .{ .analysis = .tran, .name = "tt", .func = .trig_targ, .first = .{ .vec = "v(a)", .val = 1, .rise = 2 }, .second = .{ .vec = "v(a)", .val = 1, .fall = 2 } },
        .{ .analysis = .tran, .name = "x", .func = .find, .first = .{ .vec = "v(a)", .at = 2.25 } },
        .{ .analysis = .tran, .name = "mx", .func = .max, .first = .{ .vec = "v(a)", .from = 0.5, .to = 3.5 } },
        .{ .analysis = .tran, .name = "av", .func = .avg, .first = .{ .vec = "v(a)", .to = 4 } },
        .{ .analysis = .tran, .name = "ig", .func = .integ, .first = .{ .vec = "v(a)", .from = 0.5, .to = 3.5 } },
        .{ .analysis = .tran, .name = "rm", .func = .rms, .first = a },
        .{ .analysis = .tran, .name = "pp", .func = .pp, .first = a },
        .{ .analysis = .tran, .name = "mn", .func = .min, .first = .{ .vec = "v(a)", .from = 1, .to = 3 } },
        .{ .analysis = .tran, .name = "wd", .func = .when, .first = .{ .vec = "v(a)", .val = 1, .td = 2.6 } },
    };
    const sparse_cards = [_]core.Measure{
        .{ .analysis = .tran, .name = "mx", .func = .max, .first = a },
        .{ .analysis = .tran, .name = "mn", .func = .min, .first = a },
        .{ .analysis = .tran, .name = "w", .func = .when, .first = .{ .vec = "v(a)", .val = 1.5 } },
        .{ .analysis = .tran, .name = "w2", .func = .when, .first = .{ .vec = "v(a)", .val = 2.5, .fall = 1 } },
        .{ .analysis = .tran, .name = "x", .func = .find, .first = .{ .vec = "v(a)", .at = 0.5 } },
        .{ .analysis = .tran, .name = "x0", .func = .find, .first = .{ .vec = "v(a)", .at = 0 } },
        .{ .analysis = .tran, .name = "av", .func = .avg, .first = a },
        .{ .analysis = .tran, .name = "ig", .func = .integ, .first = a },
        .{ .analysis = .tran, .name = "rm", .func = .rms, .first = a },
        .{ .analysis = .tran, .name = "pp", .func = .pp, .first = a },
    };
    const cases = [_]struct { core.Result, []const core.Measure, []const u8 }{
        .{
            tri, &tri_cards,
            \\r1                  =   1.50000e+00
            \\r2                  =   2.50000e+00
            \\f1                  =   1.50000e+00
            \\c3                  =   2.50000e+00
            \\fl                  =   7.50000e+00
            \\rl                  =   6.50000e+00
            \\cl                  =   7.50000e+00
            \\w0                  =   1.50000e+00
            \\tt                  =  1.000000e+00 targ=  3.500000e+00 trig=  2.500000e+00
            \\x                   =  5.000000e-01
            \\mx                  =  2.000000e+00 at=  3.000000e+00
            \\av                  =  1.000000e+00 from=  0.000000e+00 to=  5.000000e+00
            \\ig                  =   2.50000e+00 from=  5.00000e-01 to=  3.50000e+00
            \\rm                  =   1.47196e+00 from=  0.00000e+00 to=  8.00000e+00
            \\pp                  =  2.000000e+00 from=  0.000000e+00 to=  0.000000e+00
            \\mn                  =  0.000000e+00 at=  2.000000e+00
            \\wd                  =   4.50000e+00
            \\
        },
        .{
            with_nan, &sparse_cards,
            \\mx                  =  3.000000e+00 at=  3.000000e+00
            \\mn                  =  0.000000e+00 at=  0.000000e+00
            \\w2                  =   3.50000e+00
            \\x                   =  5.000000e-01
            \\x0                  =  0.000000e+00
            \\pp                  =  3.000000e+00 from=  0.000000e+00 to=  0.000000e+00
            \\
        },
        .{
            one, &sparse_cards,
            \\mx                  =  5.000000e+00 at=  0.000000e+00
            \\mn                  =  5.000000e+00 at=  0.000000e+00
            \\ig                  =   0.00000e+00 from=  0.00000e+00 to=  0.00000e+00
            \\pp                  =  0.000000e+00 from=  0.000000e+00 to=  0.000000e+00
            \\
        },
    };
    for (cases) |case| {
        var buf: [2048]u8 = undefined;
        var out: Writer = .fixed(&buf);
        var sink: Writer.Discarding = .init(&.{});
        try print(&out, &sink.writer, case[1], .tran, case[0], null);
        const heading = "\n  Measurements for Transient Analysis\n\n";
        try std.testing.expectEqualStrings(heading, out.buffered()[0..heading.len]);
        try std.testing.expectEqualStrings(case[2], out.buffered()[heading.len..]);
    }
}

test "one crossings scan finds what when finds for each raised count" {
    // A two-tone wave on uneven steps, crossing 0.2 and the second vector.
    var data: [3 * 400]f64 = undefined;
    var t: f64 = 0;
    for (0..400) |i| {
        data[3 * i ..][0..3].* = .{ t, @sin(t) + 0.5 * @sin(3.1 * t), 0.3 * @cos(0.7 * t) };
        t += 0.05 + 0.04 * @abs(@sin(11 * t));
    }
    const r: core.Result = .{ .plotname = "t", .varnames = &.{ "time", "v(a)", "v(b)" }, .is_complex = false, .npoints = 400, .data = &data };
    const w: Wave = .{ .result = r, .analysis = .tran };
    for ([_]Clause{
        .{ .vec = "v(a)", .val = 0.2, .rise = 1 },
        .{ .vec = "v(a)", .val = 0.2, .fall = 2 },
        .{ .vec = "v(a)", .val = 0.2, .cross = 1, .td = 3 },
        .{ .vec = "v(a)", .vec2 = "v(b)", .rise = 1, .from = 1, .to = 25 },
    }) |c| {
        var times: [64]f64 = undefined;
        const n = try w.crossings(c, &times);
        try std.testing.expect(n >= 3 and n < times.len);
        for (0..n + 1) |k| {
            var e = c;
            const raise: i32 = @intCast(k);
            if (c.rise > 0) e.rise += raise else if (c.fall > 0) e.fall += raise else e.cross += raise;
            const want = try w.when(e);
            if (k == n) try std.testing.expect(std.math.isNan(want)) else try std.testing.expectEqual(want, times[k]);
        }
    }
}

test "jitter: an ideal clock has none, an alternating one its residual" {
    // Low from 0, then rising through 0.5 at each edge time (a 0.1-wide ramp
    // centred on it) and falling back 1 later. An edge in the first interval
    // would be ngspice's primed count, read off the next segment.
    const cases = [_]struct { [4]f64, f64, f64, f64 }{
        .{ .{ 0.55, 2.55, 4.55, 6.55 }, 2, 0, 0 },
        // Least squares: period 10.1/5, residuals -0.02, 0.06, -0.06, 0.02.
        .{ .{ 0.55, 2.65, 4.55, 6.65 }, 2.02, @sqrt(0.002), 0.12 },
    };
    for (cases) |case| {
        var data: [2 + 2 * 4 * 4]f64 = @splat(0);
        for (case[0], 0..) |e, k| data[2 + 8 * k ..][0..8].* = .{ e - 0.05, 0, e + 0.05, 1, e + 0.95, 1, e + 1.05, 0 };
        const r: core.Result = .{ .plotname = "t", .varnames = &.{ "time", "v(c)" }, .is_complex = false, .npoints = 17, .data = &data };
        const j = try (Wave{ .result = r, .analysis = .tran }).jitter(.{ .vec = "v(c)", .val = 0.5 });
        try std.testing.expectEqual(4, j.edges);
        try std.testing.expectApproxEqAbs(case[1], j.period, 1e-12);
        try std.testing.expectApproxEqAbs(case[2], j.rms, 1e-12);
        try std.testing.expectApproxEqAbs(case[3], j.pp, 1e-12);
    }
}

test "sci prints C's %e: signed exponent of two digits or more" {
    for ([_]f64{ 0, -1.5e-300, 1e100, 12345.678, std.math.inf(f64), nan }, [_][]const u8{ "0.000000e+00", "-1.500000e-300", "1.000000e+100", "1.234568e+04", "inf", "nan" }) |x, want| {
        var buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(want, try std.fmt.bufPrint(&buf, "{f}", .{sci(x, 6)}));
    }
}

/// Feeds `cards` a recording a row at a time through a `Stream`, keeping
/// only the columns `markColumns` keeps for it, and checks that the values
/// and the printout equal those over the whole recording; with `early`,
/// stopping once every card has resolved. Returns the rows fed.
fn expectStreamed(cards: []const core.Measure, early: bool) !usize {
    const gpa = std.testing.allocator;
    // A two-tone wave and a slow cosine on uneven steps, as a transient
    // would record them.
    const rows = 400;
    var data: [3 * rows]f64 = undefined;
    var t: f64 = 0;
    for (0..rows) |i| {
        data[3 * i ..][0..3].* = .{ t, @sin(t) + 0.5 * @sin(3.1 * t), 0.3 * @cos(0.7 * t) };
        t += 0.05 + 0.04 * @abs(@sin(11 * t));
    }
    const names: []const []const u8 = &.{ "time", "v(a)", "v(b)" };
    const full: core.Result = .{ .plotname = "t", .varnames = names, .is_complex = false, .npoints = rows, .data = &data };
    const want = try gpa.alloc(f64, cards.len);
    defer gpa.free(want);
    evaluateAll(cards, .tran, full, want);
    var want_text: Writer.Allocating = .init(gpa);
    defer want_text.deinit();
    try print(&want_text.writer, &want_text.writer, cards, .tran, full, null);
    var keep: [3]bool = undefined;
    markColumns(cards, names, &keep, true);
    var recorded: std.ArrayList([]const u8) = .empty;
    defer recorded.deinit(gpa);
    for (names, keep) |n, on| if (on) try recorded.append(gpa, n);
    var s: Stream = try .init(gpa, cards, names, &.{ 0, 1 }, recorded.items);
    defer s.deinit();
    var rec: std.ArrayList(f64) = .empty;
    defer rec.deinit(gpa);
    var n: usize = 0;
    while (n < rows and !(early and s.open == 0)) : (n += 1) {
        const row = data[3 * n ..][0..3];
        for (keep, row) |on, v| if (on) try rec.append(gpa, v);
        s.feed(row[0], row[1..], rec.items);
    }
    const measured = try s.measured(gpa);
    defer gpa.free(measured);
    const streamed: core.Result = .{ .plotname = "t", .varnames = recorded.items, .is_complex = false, .npoints = n, .data = rec.items, .measured = measured };
    const got = try gpa.alloc(f64, cards.len);
    defer gpa.free(got);
    evaluateAll(cards, .tran, streamed, got);
    var got_text: Writer.Allocating = .init(gpa);
    defer got_text.deinit();
    try print(&got_text.writer, &got_text.writer, cards, .tran, streamed, null);
    errdefer std.debug.print("early {}: {d} rows, columns {any}\n{s}\n", .{ early, n, keep, got_text.written() });
    try std.testing.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
    try std.testing.expectEqualStrings(want_text.written(), got_text.written());
    return n;
}

test "Stream measures each card as the whole recording does, to the bit, early stop too" {
    const last = core.measure_last;
    const sum: []const core.MeasureOp = &.{ .{ .vector = "v(a)" }, .{ .vector = "v(b)" }, .add };
    const streamed = [_]core.Measure{
        .{ .analysis = .tran, .name = "w", .func = .when, .first = .{ .vec = "v(a)", .val = 0.2, .rise = 2 } },
        .{ .analysis = .tran, .name = "wv", .func = .when, .first = .{ .vec = "v(a)", .vec2 = "v(b)", .cross = 3, .td = 1 } },
        .{ .analysis = .tran, .name = "wl", .func = .when, .first = .{ .vec = "v(a)", .val = 0.2, .fall = last, .to = 15 } },
        .{ .analysis = .tran, .name = "wn", .func = .when, .first = .{ .vec = "v(a)", .val = 9, .to = 20 } },
        .{ .analysis = .tran, .name = "w0", .func = .when, .first = .{ .vec = "v(a)", .val = 0.5 } },
        .{ .analysis = .tran, .name = "tt", .func = .trig_targ, .first = .{ .vec = "v(a)", .val = 0.2, .rise = 1 }, .second = .{ .vec = "v(b)", .val = 0, .fall = 1 } },
        .{ .analysis = .tran, .name = "ta", .func = .trig_targ, .first = .{ .at = 2 }, .second = .{ .vec = "v(a)", .val = 0, .cross = 2, .td_trig = true } },
        .{ .analysis = .tran, .name = "fw", .func = .find, .first = .{ .vec = "v(b)" }, .second = .{ .vec = "v(a)", .val = -0.3, .fall = 2 } },
        .{ .analysis = .tran, .name = "dw", .func = .deriv, .first = .{ .ops = sum }, .second = .{ .vec = "v(a)", .val = 0.1, .cross = 4 } },
        .{ .analysis = .tran, .name = "fp", .func = .find, .first = .{ .vec = "v(b)" }, .second = .{ .vec = "v(a)", .val = 0.05, .rise = 1 } },
        .{ .analysis = .tran, .name = "fa", .func = .find, .first = .{ .vec = "v(b)", .at = 4.321 } },
        .{ .analysis = .tran, .name = "da", .func = .deriv, .first = .{ .vec = "v(a)", .at = 7.5 } },
        .{ .analysis = .tran, .name = "mx", .func = .max, .first = .{ .vec = "v(a)", .from = 1, .to = 6 } },
        .{ .analysis = .tran, .name = "mn", .func = .min_at, .first = .{ .vec = "v(a)", .from = 1, .to = 6 } },
        .{ .analysis = .tran, .name = "av", .func = .avg, .first = .{ .ops = sum, .from = 2, .to = 9 } },
        .{ .analysis = .tran, .name = "pp", .func = .pp, .first = .{ .vec = "v(b)", .to = 12 } },
        .{ .analysis = .tran, .name = "ig", .func = .integ, .first = .{ .vec = "v(a)", .from = 0.7, .to = 8.3 } },
        .{ .analysis = .tran, .name = "rm", .func = .rms, .first = .{ .vec = "v(a)", .to = 21 } },
        .{ .analysis = .tran, .name = "em", .func = .em_avg, .first = .{ .vec = "v(a)", .to = 10 } },
        .{ .analysis = .tran, .name = "e1", .func = .err1, .first = .{ .vec = "v(a)", .vec2 = "v(b)", .to = 9 } },
        .{ .analysis = .tran, .name = "nv", .func = .max, .first = .{ .vec = "v(z)" } },
        .{ .analysis = .tran, .name = "pr", .func = .param, .first = .{}, .expr = &.{ .{ .measure = 0 }, .{ .measure = 12 }, .add } },
    };
    // Every card resolves by t = 21 of 30, keeping no column but time.
    const cut = try expectStreamed(&streamed, true);
    try std.testing.expect(cut < 300);
    _ = try expectStreamed(&streamed, false);
    const t0: []const core.MeasureOp = &.{.{ .measure = 0 }};
    const recorded = streamed ++ [_]core.Measure{
        .{ .analysis = .tran, .name = "td", .func = .trig_targ, .first = .{ .vec = "v(b)", .val = 0, .fall = 1 }, .second = .{ .vec = "v(a)", .val = 0, .rise = 1, .td_trig = true } },
        .{ .analysis = .tran, .name = "fd", .func = .find, .first = .{ .vec = "v(b)" }, .second = .{ .vec = "v(a)", .val = 0.1, .cross = 1, .td = 3 } },
        .{ .analysis = .tran, .name = "fr", .func = .find, .first = .{ .vec = "v(b)", .refs = &.{.{ .field = .at, .expr = t0 }} } },
        .{ .analysis = .tran, .name = "wr", .func = .when, .first = .{ .vec = "v(a)", .val = 0, .refs = &.{.{ .field = .td, .expr = t0 }} } },
        // Never resolve: a LAST count, a window and JITTER without TO=.
        .{ .analysis = .tran, .name = "fl", .func = .find, .first = .{ .vec = "v(b)" }, .second = .{ .vec = "v(a)", .val = 0.1, .rise = last } },
        .{ .analysis = .tran, .name = "rn", .func = .rms, .first = .{ .vec = "v(a)" } },
        .{ .analysis = .tran, .name = "ji", .func = .jitter, .first = .{ .vec = "v(a)", .val = 0 } },
    };
    for ([_]bool{ false, true }) |early| _ = try expectStreamed(&recorded, early);
    // The replayed cards resolve too.
    try std.testing.expect(try expectStreamed(recorded[0 .. recorded.len - 3], true) < 300);
}
