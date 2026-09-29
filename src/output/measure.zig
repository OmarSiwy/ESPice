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

/// Writes every card in `measures` that targets `analysis`, evaluated over
/// `result`, under ngspice's heading. Writes nothing when none targets it.
pub fn print(out: *Writer, err: *Writer, measures: []const core.Measure, analysis: Kind, result: core.Result) Writer.Error!void {
    // As ngspice's measure.c, PARAM cards read every other card's result,
    // so those are evaluated first; each card still prints in deck order.
    // ponytail: a fixed table; cards past the 256th read as NaN to a PARAM.
    var values: [256]f64 = @splat(nan);
    var discard_buf: [64]u8 = undefined;
    var discard: Writer.Discarding = .init(&discard_buf);
    for (measures, 0..) |m, i| {
        if (!targets(m, analysis, result) or m.func == .param or i >= values.len) continue;
        values[i] = evaluate(&discard.writer, m, .{ .result = result, .analysis = analysis, .values = &values }) catch nan;
    }
    var heading = false;
    for (measures, 0..) |m, i| {
        if (!targets(m, analysis, result)) continue;
        if (!heading) {
            heading = true;
            try out.print("\n  Measurements for {s} Analysis\n\n", .{switch (analysis) {
                .tran => "Transient",
                .ac => "AC",
                .fft => "FFT",
                else => "DC",
            }});
        }
        const w: Wave = .{ .result = result, .analysis = analysis, .values = &values };
        const value = evaluate(out, m, w) catch |e| switch (e) {
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
        if (m.func == .param and i < values.len) values[i] = value;
    }
}

/// Evaluates every card in `measures` that targets `analysis` over
/// `result` into `values` (parallel to `measures`), PARAM cards last in
/// deck order, as `print` does. A card that does not target the result, or
/// whose event never happens, reads NaN.
pub fn evaluateAll(measures: []const core.Measure, analysis: Kind, result: core.Result, out: []f64) void {
    std.debug.assert(out.len == measures.len);
    @memset(out, nan);
    var discard_buf: [64]u8 = undefined;
    var discard: Writer.Discarding = .init(&discard_buf);
    for ([_]bool{ false, true }) |param| for (measures, out) |m, *v| {
        if (!targets(m, analysis, result) or (m.func == .param) != param) continue;
        v.* = evaluate(&discard.writer, m, .{ .result = result, .analysis = analysis, .values = out }) catch nan;
    };
}

/// Whether card `m` reads `result`. Each `.fft` card has its own plot, so an
/// FFT card reads the one holding its vector.
fn targets(m: core.Measure, analysis: Kind, result: core.Result) bool {
    if (m.analysis != analysis) return false;
    if (analysis != .fft or m.func == .param) return true;
    const w: Wave = .{ .result = result, .analysis = analysis };
    _ = w.column(m.first.vec, 0) catch return false;
    return true;
}

/// Mean, sigma, min and max of each card over Monte Carlo trials, as
/// `mean(name) = x` lines (sigma with Bessel's correction). `trials` holds
/// the results the cards are evaluated over; a card that fails in a trial
/// leaves that trial out.
pub fn printStatistics(out: *Writer, measures: []const core.Measure, analysis: Kind, trials: []const core.Result) Writer.Error!void {
    var discard_buf: [64]u8 = undefined;
    var discard: Writer.Discarding = .init(&discard_buf);
    var heading = false;
    for (measures, 0..) |m, i| {
        if (m.analysis != analysis or i >= 256) continue;
        var n: f64 = 0;
        var mean: f64 = 0;
        var m2: f64 = 0;
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (trials) |result| {
            var values: [256]f64 = @splat(nan);
            for (measures, 0..) |other, k| {
                if (other.analysis != analysis or k >= values.len) continue;
                if (other.func == .param and k > i) continue;
                values[k] = evaluate(&discard.writer, other, .{ .result = result, .analysis = analysis, .values = &values }) catch nan;
            }
            const x = values[i];
            if (!std.math.isFinite(x)) continue;
            n += 1;
            const delta = x - mean;
            mean += delta / n;
            m2 += delta * (x - mean);
            lo = @min(lo, x);
            hi = @max(hi, x);
        }
        if (n == 0) continue;
        if (!heading) {
            heading = true;
            try out.print("\n  Monte Carlo statistics over {d} trials\n\n", .{trials.len});
        }
        const sigma = if (n > 1) @sqrt(m2 / (n - 1)) else 0;
        try out.print("mean({s}) = {f}\nsigma({s}) = {f}\nmin({s}) = {f}\nmax({s}) = {f}\n", .{ m.name, sci(mean, 6), m.name, sci(sigma, 6), m.name, sci(lo, 6), m.name, sci(hi, 6) });
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
            try out.print("{s:<20}=  {f}\n", .{ m.name, sci(v, 6) });
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
    }
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
fn evaluateCont(out: *Writer, m: core.Measure, w: Wave) EvalError!f64 {
    var first: f64 = nan;
    var buf: [96]u8 = undefined;
    var k: i32 = 0;
    while (true) : (k += 1) {
        var one = m;
        one.cont = false;
        one.name = std.fmt.bufPrint(&buf, "{s}[{d}]", .{ m.name, k + 1 }) catch m.name;
        switch (m.func) {
            .trig_targ => {
                one.first = nth(m.first, k) orelse break;
                one.second = nth(m.second, k) orelse break;
            },
            .find, .deriv => one.second = nth(m.second, k) orelse break,
            .when => one.first = nth(m.first, k) orelse break,
            else => return evaluate(out, one, w),
        }
        const v = evaluate(out, one, w) catch |e| switch (e) {
            error.OutOfInterval => break,
            else => return e,
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
    var k0: usize = 0;
    for (1..n) |k| if (k0 == 0 or mag.get(k) > mag.get(k0)) {
        k0 = k;
    };
    if (k0 == 0) return nan;
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
        else => unreachable,
    };
}

/// Folds a PARAM card's postfix over the results in `values`; NaN when a
/// result it reads is missing or it reads a vector.
fn paramValue(ops: []const core.MeasureOp, values: []const f64) f64 {
    return fold(ops, struct {
        values: []const f64,
        fn leaf(s: @This(), op: core.MeasureOp) f64 {
            return switch (op) {
                .num => |x| x,
                .measure => |k| if (k < s.values.len) s.values[k] else nan,
                else => nan,
            };
        }
    }{ .values = values });
}

/// Folds measure postfix; `leaves.leaf(op)` values each `num`, `measure`
/// and `vector` op. NaN on a stack overflow or a malformed tail.
fn fold(ops: []const core.MeasureOp, leaves: anytype) f64 {
    var stack: [32]f64 = undefined;
    var n: usize = 0;
    for (ops) |op| switch (op) {
        .num, .measure, .vector => {
            if (n == stack.len) return nan;
            stack[n] = leaves.leaf(op);
            n += 1;
        },
        .neg => stack[n - 1] = -stack[n - 1],
        else => {
            n -= 1;
            const b = stack[n];
            const x = &stack[n - 1];
            x.* = switch (op) {
                .add => x.* + b,
                .sub => x.* - b,
                .mul => x.* * b,
                .div => x.* / b,
                .pow => std.math.pow(f64, x.*, b),
                else => unreachable,
            };
        },
    };
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
            else => re,
        };
    }
};

/// Sample `i` of the columns a `par()` waveform reads.
const Sample = struct {
    column: Column,
    i: usize,

    // ponytail: each vector op finds its column by name per sample,
    // O(vectors); resolve the indices once if par() waveforms get hot.
    fn leaf(s: Sample, op: core.MeasureOp) f64 {
        return switch (op) {
            .num => |x| x,
            .vector => |name| blk: {
                const k = columnIndex(s.column.names, name) orelse break :blk nan;
                var c = s.column;
                c.ops = &.{};
                c.offset = k * @as(usize, if (c.complex) 2 else 1);
                break :blk c.get(s.i);
            },
            .measure => nan,
            else => unreachable,
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

    fn len(w: Wave) usize {
        return w.result.npoints;
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
        for (ops) |op| if (op == .vector) {
            _ = try w.column(op.vector, vectype);
        };
        var c = w.col(0, vectype);
        c.ops = ops;
        c.names = w.result.varnames;
        return c;
    }

    /// Scale value of the event `c` names; NaN when it never happens
    /// (ngspice com_measure_when).
    fn when(w: Wave, c: Clause) !f64 {
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        const y2: ?Column = if (c.vec2.len > 0) try w.waveform(c.vec2, c.ops2, c.vectype) else null;
        const dc = w.analysis == .dc;
        var td = c.td;
        var rise: i32 = 0;
        var fall: i32 = 0;
        var cross: i32 = 0;
        var above = false;
        var pending = false;
        var last: f64 = nan;
        var first: u32 = 0;
        var prev: f64 = 0;
        var prev2: f64 = 0;
        var prev_x: f64 = 0;
        for (0..w.len()) |i| {
            const v = y.get(i);
            const xv = x.get(i);
            const v2 = if (y2) |c2| c2.get(i) else nan;
            // A DC sweep may start anywhere: ngspice keeps its origin in td.
            if (dc and i == 0) td = xv;
            if (w.analysis == .tran and xv < td) continue;
            if (w.analysis == .ac and xv < 0) continue;
            if (dc) {
                if (xv < c.from or xv > c.to) continue;
            } else {
                if (xv < c.from) continue;
                if (c.to != 0 and xv > c.to) break;
            }
            if (first > 1 and dc and td == xv) first = 1;
            const level = if (y2 != null) v2 else c.val;
            const prev_level = if (y2 != null) prev2 else c.val;
            if (first == 1) {
                cross = 0;
                above = !(v < level);
                if (!above and prev >= prev_level) {
                    fall = 1;
                    cross = 1;
                } else if (above and prev < prev_level) {
                    rise = 1;
                    cross = 1;
                }
            }
            if (first > 1) {
                if (!above and v >= level) {
                    above = true;
                    cross += 1;
                    rise += 1;
                    if (c.fall != core.measure_last) pending = true;
                } else if (above and v <= level) {
                    above = false;
                    cross += 1;
                    fall += 1;
                    if (c.rise != core.measure_last) pending = true;
                }
                const hit = prev_x + (prev_level - prev) * (xv - prev_x) / (v - prev - level + prev_level);
                if (cross == c.cross or rise == c.rise or fall == c.fall) return hit;
                if (pending) {
                    if (c.cross == core.measure_unset and c.rise == core.measure_unset and c.fall == core.measure_unset) return hit;
                    if (c.cross == core.measure_last or c.rise == core.measure_last or c.fall == core.measure_last) last = hit;
                    pending = false;
                }
            }
            first += 1;
            prev = v;
            if (y2 != null) prev2 = v2;
            prev_x = xv;
        }
        return last;
    }

    /// The vector interpolated at scale value `at`; NaN outside the sweep
    /// (ngspice measure_at).
    fn valueAt(w: Wave, c: Clause, at: f64) !f64 {
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        var px: f64 = 0;
        var pv: f64 = 0;
        for (0..w.len()) |i| {
            const v = y.get(i);
            const xv = x.get(i);
            if (i > 0 and ((px <= at and xv >= at) or (w.analysis == .dc and px >= at and xv <= at)))
                return pv + (at - px) * (v - pv) / (xv - px);
            px = xv;
            pv = v;
        }
        return nan;
    }

    /// Slope of the vector against the scale at `at`, off the sample pair
    /// around it; NaN outside the sweep.
    fn slopeAt(w: Wave, c: Clause, at: f64) !f64 {
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        for (1..w.len()) |i| {
            const x0 = x.get(i - 1);
            const x1 = x.get(i);
            if ((x0 <= at and x1 >= at) or (w.analysis == .dc and x0 >= at and x1 <= at))
                return (y.get(i) - y.get(i - 1)) / (x1 - x0);
        }
        return nan;
    }

    /// HSPICE's ERR family over the window [SA Ch.11 "Error Equations"]:
    /// with e = (M - C) / M, M = `c.vec` floored at `c.minval`, C =
    /// `c.vec2`, ERR and ERR1 return the RMS of e and ERR2 the mean of |e|.
    /// ERR3 takes e = +-log|M/C| / log(M), signed as M/C, reduced as ERR1.
    /// Points with |M| outside [ymin, ymax] are skipped; NaN when none is left.
    fn relError(w: Wave, c: Clause, func: core.MeasureFunc) !f64 {
        const x = w.scale();
        const mv = try w.waveform(c.vec, c.ops, c.vectype);
        const cv = try w.column(c.vec2, c.vectype);
        var sum: f64 = 0;
        var count: f64 = 0;
        for (0..w.len()) |i| {
            const xv = x.get(i);
            if (w.analysis == .dc) {
                if (xv < c.from or xv > c.to) continue;
            } else {
                if (xv < c.from) continue;
                if (c.to != 0 and xv > c.to) break;
            }
            const m = mv.get(i);
            const calc = cv.get(i);
            if (@abs(m) < c.ymin or @abs(m) > c.ymax) continue;
            const d = if (@abs(m) < c.minval) c.minval else m;
            // ponytail: the manual gives no reduction for ERR3; RMS, as ERR1.
            const e = if (func == .err3) std.math.sign(m / calc) * @log(@abs(m / calc)) / @log(d) else (m - calc) / d;
            sum += if (func == .err2) @abs(e) else e * e;
            count += 1;
        }
        if (count == 0) return nan;
        return if (func == .err2) sum / count else @sqrt(sum / count);
    }

    /// MIN/MAX (value, where) or AVG (trapezoidal mean, last scale read)
    /// over the window, without interpolating its ends (ngspice
    /// measure_minMaxAvg).
    fn extremum(w: Wave, c: Clause, op: enum { min, max, avg }) !Stat {
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        var first = false;
        var m: f64 = 0;
        var m_at: f64 = 0;
        var xv: f64 = 0;
        var pv: f64 = 0;
        var px: f64 = 0;
        var span: f64 = 0;
        for (0..w.len()) |i| {
            const v = y.get(i);
            xv = x.get(i);
            if (w.analysis == .dc) {
                if (xv < c.from or xv > c.to) continue;
            } else {
                if (xv < c.from) continue;
                if (c.to != 0 and xv > c.to) break;
            }
            if (!first) {
                first = true;
                m = if (op == .avg) 0 else v;
                m_at = xv;
                pv = v;
                px = xv;
                continue;
            }
            switch (op) {
                .min => if (v <= m) {
                    m = v;
                    m_at = xv;
                },
                .max => if (v >= m) {
                    m = v;
                    m_at = xv;
                },
                .avg => {
                    m += 0.5 * (v + pv) * (xv - px);
                    span += xv - px;
                    pv = v;
                    px = xv;
                },
            }
        }
        return if (op == .avg) .{ .value = m / (if (first) span else 1), .at = xv } else .{ .value = m, .at = m_at };
    }

    const Integral = struct { value: f64, from: f64, to: f64 };

    /// HSPICE EM_AVG over the window [CR .MEASURE (AVG, EM_AVG, ...)]:
    /// with I+ and I- the trapezoidal averages of the positive and negative
    /// parts (each segment split at its zero crossing), max(I+, I-) minus
    /// `c.val` (`.option em_recovery`) times min(I+, I-). The window ends
    /// are samples, as AVG's.
    fn emAvg(w: Wave, c: Clause) !Integral {
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        var pos: f64 = 0;
        var neg: f64 = 0;
        var from: f64 = nan;
        var to: f64 = nan;
        var pv: f64 = 0;
        for (0..w.len()) |i| {
            const v = y.get(i);
            const xv = x.get(i);
            if (xv < c.from) continue;
            if (c.to != 0 and xv > c.to) break;
            if (!std.math.isNan(from)) {
                pos += positiveArea(pv, v, xv - to);
                neg += positiveArea(-pv, -v, xv - to);
            } else from = xv;
            to = xv;
            pv = v;
        }
        const span = to - from;
        if (!(span > 0)) return .{ .value = nan, .from = from, .to = to };
        return .{ .value = (@max(pos, neg) - c.val * @min(pos, neg)) / span, .from = from, .to = to };
    }

    /// Integral, or RMS, of the vector over [from, to], ends interpolated,
    /// by composite Simpson 3/8, Simpson 1/3 and trapezoid panels as the
    /// sample spacing allows (ngspice measure_rms_integral).
    fn rmsInteg(w: Wave, c: Clause, rms: bool) !Integral {
        const x = w.scale();
        const y = try w.waveform(c.vec, c.ops, c.vectype);
        const n = w.len();
        var win: Window = .{ .x = x, .y = y, .from = c.from, .to = c.to, .rms = rms };
        while (win.lo < n and x.get(win.lo) < c.from) win.lo += 1;
        win.hi = win.lo;
        while (win.hi < n and !(c.to != 0 and x.get(win.hi) > c.to)) win.hi += 1;
        win.cut = win.hi < n;
        if (win.cut) win.hi += 1;
        const count = win.hi - win.lo;
        var sum: [3]f64 = .{ 0, 0, 0 };
        var k: usize = 0;
        while (k + 1 < count) {
            const p = [4][2]f64{ win.point(k), win.point(k + 1), win.point(k + 2), win.point(k + 3) };
            var width: [3]f64 = undefined;
            for (&width, 0..) |*d, j| d.* = if (k + j + 1 < count) p[j + 1][0] - p[j][0] else 0;
            if (almostEqualUlps(width[0], width[1]) and almostEqualUlps(width[0], width[2])) {
                sum[0] += 3 * width[0] * (p[0][1] + 3 * (p[1][1] + p[2][1]) + p[3][1]) / 8.0;
                k += 3;
            } else if (almostEqualUlps(width[0], width[1])) {
                sum[1] += width[0] * (p[0][1] + 4 * p[1][1] + p[2][1]) / 3.0;
                k += 2;
            } else {
                sum[2] += width[0] * (p[0][1] + p[1][1]) / 2;
                k += 1;
            }
        }
        const from = if (count > @intFromBool(win.cut)) win.point(0)[0] else nan;
        const to = if (win.cut) win.point(count - 1)[0] else x.get(n - 1);
        const total = sum[0] + sum[1] + sum[2];
        return .{ .value = if (rms) @sqrt(total / (to - from)) else total, .from = from, .to = to };
    }
};

/// Area under max(v, 0) over one linear segment from `v0` to `v1`, `dx` wide.
fn positiveArea(v0: f64, v1: f64, dx: f64) f64 {
    if (v0 >= 0 and v1 >= 0) return 0.5 * (v0 + v1) * dx;
    if (v0 <= 0 and v1 <= 0) return 0;
    const hi = @max(v0, v1);
    return 0.5 * hi * dx * hi / (hi - @min(v0, v1));
}

/// Samples lo..hi of an RMS/INTEG window. With `cut`, sample hi-1 is the
/// first past `to` and reads as the value at `to`; the first sample reads as
/// the value at a nonzero `from`. Points past the window are zero, as in
/// ngspice's zeroed buffers.
const Window = struct {
    x: Column,
    y: Column,
    lo: usize = 0,
    hi: usize = 0,
    cut: bool = false,
    from: f64,
    to: f64,
    rms: bool,

    /// Point `k` as (scale, value or value squared).
    fn point(win: Window, k: usize) [2]f64 {
        const i = win.lo + k;
        if (i >= win.hi) return .{ 0, 0 };
        var xv = win.x.get(i);
        var v = win.y.get(i);
        if (win.cut and i + 1 == win.hi) {
            if (i > 0 and !almostEqualUlps(xv, win.to)) {
                v = interpolate(win.x, win.y, i - 1, i, win.to);
                xv = win.to;
            }
        } else if (k == 0 and win.from != 0 and i > 0 and !almostEqualUlps(xv, win.from)) {
            v = interpolate(win.x, win.y, i - 1, i, win.from);
            xv = win.from;
        }
        return .{ xv, if (win.rms) v * v else v };
    }
};

/// ngspice measure_interpolate, 'y' mode: the line through samples i and j
/// at scale value `at`, in slope-intercept form for the same rounding.
fn interpolate(x: Column, y: Column, i: usize, j: usize, at: f64) f64 {
    const slope = (y.get(j) - y.get(i)) / (x.get(j) - x.get(i));
    const intercept = y.get(i) - slope * x.get(i);
    return slope * at + intercept;
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

/// C's `%.*e`: at least two exponent digits and an explicit sign.
fn sci(x: f64, comptime precision: u8) Sci {
    return .{ .x = x, .precision = precision };
}

const Sci = struct {
    x: f64,
    precision: u8,

    pub fn format(s: Sci, w: *Writer) Writer.Error!void {
        var buf: [64]u8 = undefined;
        const t =std.fmt.float.render(&buf, s.x, .{ .mode = .scientific, .precision = s.precision }) catch return w.writeAll("?");
        const e = std.mem.indexOfScalar(u8, t, 'e') orelse return w.writeAll(t);
        const exp = std.fmt.parseInt(i32, t[e + 1 ..], 10) catch return w.writeAll(t);
        try w.print("{s}e{c}{d:0>2}", .{ t[0..e], @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
    }
};

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
    try print(&out, &err, &cards, .tran, result);
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
        \\p                   =  4.000000e+00
        \\
    , out.buffered());
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "gone") != null);
}
