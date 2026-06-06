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
        if (m.analysis != analysis or m.func == .param or i >= values.len) continue;
        values[i] = evaluate(&discard.writer, m, .{ .result = result, .analysis = analysis, .values = &values }) catch nan;
    }
    var heading = false;
    for (measures, 0..) |m, i| {
        if (m.analysis != analysis) continue;
        if (!heading) {
            heading = true;
            try out.print("\n  Measurements for {s} Analysis\n\n", .{switch (analysis) {
                .tran => "Transient",
                .ac => "AC",
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

/// Prints card `m` and returns its result, the value a PARAM card reads.
fn evaluate(out: *Writer, m: core.Measure, w: Wave) !f64 {
    const a = m.first;
    switch (m.func) {
        .trig_targ => {
            const trig = try defined(if (a.at == core.measure_no_at) try w.when(a) else a.at);
            const targ = try defined(if (m.second.at == core.measure_no_at) try w.when(m.second) else m.second.at);
            try out.print("{s:<20}=  {f} targ=  {f} trig=  {f}\n", .{ m.name, sci(targ - trig, 6), sci(targ, 6), sci(trig, 6) });
            return targ - trig;
        },
        .find, .deriv => {
            const at = if (a.at == core.measure_no_at) try defined(try w.when(m.second)) else a.at;
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
    }
}

/// Folds a PARAM card's postfix over the results in `values`; NaN when a
/// result it reads is missing.
fn paramValue(ops: []const core.MeasureOp, values: []const f64) f64 {
    var stack: [32]f64 = undefined;
    var n: usize = 0;
    for (ops) |op| switch (op) {
        .num, .measure => {
            if (n == stack.len) return nan;
            stack[n] = if (op == .num) op.num else if (op.measure < values.len) values[op.measure] else nan;
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
/// (ngspice get_value).
const Column = struct {
    data: []const f64,
    stride: usize,
    offset: usize,
    complex: bool,
    vectype: u8,

    fn get(c: Column, i: usize) f64 {
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

    /// `name` as the result labels it; a bare node name reads `v(name)`,
    /// as ngspice's vector lookup does.
    fn column(w: Wave, name: []const u8, vectype: u8) error{NoSuchVector}!Column {
        var buf: [256]u8 = undefined;
        const alt = std.fmt.bufPrint(&buf, "v({s})", .{name}) catch name;
        for (w.result.varnames, 0..) |v, i| {
            if (std.ascii.eqlIgnoreCase(v, name) or std.ascii.eqlIgnoreCase(v, alt)) return w.col(i, vectype);
        }
        return error.NoSuchVector;
    }

    /// Scale value of the event `c` names; NaN when it never happens
    /// (ngspice com_measure_when).
    fn when(w: Wave, c: Clause) !f64 {
        const x = w.scale();
        const y = try w.column(c.vec, c.vectype);
        const y2: ?Column = if (c.vec2.len > 0) try w.column(c.vec2, c.vectype) else null;
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
        const y = try w.column(c.vec, c.vectype);
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
        const y = try w.column(c.vec, c.vectype);
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
        const mv = try w.column(c.vec, c.vectype);
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
        const y = try w.column(c.vec, c.vectype);
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

    /// Integral, or RMS, of the vector over [from, to], ends interpolated,
    /// by composite Simpson 3/8, Simpson 1/3 and trapezoid panels as the
    /// sample spacing allows (ngspice measure_rms_integral).
    fn rmsInteg(w: Wave, c: Clause, rms: bool) !Integral {
        const x = w.scale();
        const y = try w.column(c.vec, c.vectype);
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
