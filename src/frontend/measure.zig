//! `.meas` card text to a `core.Measure`, after ngspice com_measure2.c
//! (measure_parse_trigtarg, _find, _when and _stdParams). The caller
//! evaluates the numbers, so a value may be a parameter expression. HSPICE
//! forms ride along: an omitted analysis type, INTEGRAL/DERIVATIVE, PARAM=
//! and ERR/ERR1/ERR2/ERR3 [CR .MEASURE].
const std = @import("std");
const core = @import("core");
const Kind = core.query.Kind;
const Clause = core.MeasureClause;

/// `lhs`, or `lhs=rhs` with blanks around the `=` dropped.
const Word = struct { lhs: []const u8, rhs: ?[]const u8 = null };

const analyses = std.StaticStringMap(Kind).initComptime(.{ .{ "tran", .tran }, .{ "ac", .ac }, .{ "dc", .dc }, .{ "fft", .fft } });

const funcs = std.StaticStringMap(core.MeasureFunc).initComptime(.{
    .{ "trig", .trig_targ }, .{ "delay", .trig_targ }, .{ "targ", .trig_targ },
    .{ "find", .find },      .{ "when", .when },       .{ "avg", .avg },
    .{ "min", .min },        .{ "max", .max },         .{ "min_at", .min_at },
    .{ "max_at", .max_at },  .{ "rms", .rms },         .{ "pp", .pp },
    .{ "integ", .integ },    .{ "deriv", .deriv },      .{ "integral", .integ },
    .{ "derivative", .deriv }, .{ "param", .param },    .{ "err", .err },
    .{ "err1", .err1 },      .{ "err2", .err2 },       .{ "err3", .err3 },
    .{ "thd", .thd },        .{ "snr", .snr },         .{ "sndr", .sndr },
    .{ "enob", .enob },      .{ "sfdr", .sfdr },
});

/// Parses `text`, the card after `.meas`, lowercased. `ctx.measureValue(text)
/// !f64` evaluates a value and `ctx.measureExpr(text) ![]const
/// core.MeasureOp` compiles a PARAM= expression. A card without an analysis
/// type reads `default`, HSPICE's last analysis card. Strings in the result
/// are slices of `text` or allocated in `arena`. ParseError for anything
/// neither simulator accepts.
pub fn parse(arena: std.mem.Allocator, text: []const u8, ctx: anytype, default: ?Kind) !core.Measure {
    const typed = try words(arena, text);
    if (typed.len < 2) return error.ParseError;
    const given = analyses.get(typed[0].lhs);
    const analysis = given orelse default orelse return error.ParseError;
    // `w[0]` is the analysis type's slot either way.
    const w = if (given != null) typed else try std.mem.concat(arena, Word, &.{ &.{.{ .lhs = "" }}, typed });
    if (w.len < 3) return error.ParseError;
    const func = funcs.get(w[2].lhs) orelse return error.ParseError;
    // ngspice widens the default window of a DC sweep, which may run negative.
    var base: Clause = .{};
    if (analysis == .dc) {
        base.from = -1e99;
        base.to = 1e99;
    }
    // MAXFREQ defaults to the top of the spectrum [CR .MEASURE FFT].
    if (analysis == .fft) base.to = 1e99;
    var m: core.Measure = .{ .analysis = analysis, .name = w[1].lhs, .func = func, .first = base, .second = base };
    const rest = w[3..];
    switch (func) {
        .trig_targ => {
            const t = find(rest, "targ") orelse return error.ParseError;
            try trigTarg(arena, &m.first, analysis, rest[0..t], ctx);
            try trigTarg(arena, &m.second, analysis, rest[t + 1 ..], ctx);
            for ([_]Clause{ m.first, m.second }) |c| {
                if (c.rise == core.measure_unset and c.fall == core.measure_unset and
                    c.cross == core.measure_unset and c.at == core.measure_no_at) return error.ParseError;
            }
            if (m.first.from != 0 and m.second.from == 0) m.second.from = m.first.from else if (m.second.from != 0 and m.first.from == 0) m.first.from = m.second.from;
        },
        .param => {
            m.expr = try ctx.measureExpr(w[2].rhs orelse return error.ParseError);
            try stdParams(&m.first, analysis, rest, ctx);
        },
        .err, .err1, .err2, .err3 => {
            if (rest.len < 2) return error.ParseError;
            m.first.vec = try vector(arena, &m.first, analysis, rest[0].lhs);
            var ignored: Clause = .{};
            m.first.vec2 = try vector(arena, &ignored, analysis, rest[1].lhs);
            try stdParams(&m.first, analysis, rest[2..], ctx);
        },
        .find, .deriv => {
            const k = find(rest, "when") orelse rest.len;
            if (k == 0 or rest[0].rhs != null) return error.ParseError;
            m.first.vec = try vector(arena, &m.first, analysis, rest[0].lhs);
            if (k > 1) {
                if (!std.mem.eql(u8, rest[1].lhs, "at") or rest[1].rhs == null) return error.ParseError;
                m.first.at = try ctx.measureValue(rest[1].rhs.?);
                try stdParams(&m.first, analysis, rest[2..k], ctx);
            }
            if (m.first.at == core.measure_no_at) {
                if (k == rest.len) return error.ParseError;
                try when(arena, &m.second, analysis, rest[k + 1 ..], ctx);
            }
        },
        .when => try when(arena, &m.first, analysis, rest, ctx),
        // `.meas fft name THD|SNR|SNDR|ENOB|SFDR v(out) [NBHARM=] [MAXFREQ=]
        // [MINFREQ=] [BINSIZ=]`.
        .thd, .snr, .sndr, .enob, .sfdr => {
            if (analysis != .fft or rest.len == 0 or rest[0].rhs != null) return error.ParseError;
            m.first.vec = rest[0].lhs;
            try stdParams(&m.first, analysis, rest[1..], ctx);
        },
        else => try trigTarg(arena, &m.first, analysis, rest, ctx),
    }
    return m;
}

fn find(w: []const Word, key: []const u8) ?usize {
    for (w, 0..) |x, i| if (x.rhs == null and std.mem.eql(u8, x.lhs, key)) return i;
    return null;
}

/// An optional vector, then parameters.
fn trigTarg(arena: std.mem.Allocator, c: *Clause, analysis: Kind, w: []const Word, ctx: anytype) !void {
    if (w.len == 0) return error.ParseError;
    const has_vec = !std.mem.startsWith(u8, w[0].lhs, "at");
    if (has_vec) c.vec = try vector(arena, c, analysis, w[0].lhs);
    try stdParams(c, analysis, w[@intFromBool(has_vec)..], ctx);
}

/// `vec=level` or `vec=vec2`, then parameters.
fn when(arena: std.mem.Allocator, c: *Clause, analysis: Kind, w: []const Word, ctx: anytype) !void {
    if (w.len == 0) return error.ParseError;
    const rhs = w[0].rhs orelse return error.ParseError;
    c.vec = try vector(arena, c, analysis, w[0].lhs);
    c.val = 1e99;
    // A result variable is always `v(..)`/`i(..)`: a `(` names one.
    if (std.mem.indexOfScalar(u8, rhs, '(') != null) {
        var ignored: Clause = .{};
        c.vec2 = try vector(arena, &ignored, analysis, rhs);
    } else c.val = try ctx.measureValue(rhs);
    try stdParams(c, analysis, w[1..], ctx);
}

/// `vdb(out)` reads `v(out)` in dB for AC (ngspice correct_vec).
fn vector(arena: std.mem.Allocator, c: *Clause, analysis: Kind, name: []const u8) ![]const u8 {
    if ((analysis != .ac and analysis != .fft) or name.len < 2 or name[0] != 'v' or name[1] == '(') return name;
    const paren = std.mem.indexOfScalar(u8, name, '(') orelse return name;
    c.vectype = name[1];
    return std.mem.concat(arena, u8, &.{ "v", name[paren..] });
}

fn stdParams(c: *Clause, analysis: Kind, w: []const Word, ctx: anytype) !void {
    for (w) |x| {
        const rhs = x.rhs orelse {
            if (!std.mem.eql(u8, x.lhs, "last")) return error.ParseError;
            c.cross = core.measure_last;
            c.rise = core.measure_unset;
            c.fall = core.measure_unset;
            continue;
        };
        const v: f64 = if (std.mem.eql(u8, rhs, "last")) core.measure_last else try ctx.measureValue(rhs);
        // `print` only switches HSPICE's listing.
        const Key = enum { rise, fall, cross, val, td, from, to, at, minval, ignor, ymin, ymax, goal, weight, nbharm, minfreq, maxfreq, binsiz, print };
        const key = std.meta.stringToEnum(Key, x.lhs) orelse return error.ParseError;
        switch (key) {
            .rise, .fall, .cross => {
                const n = std.math.lossyCast(i32, @floor(v + 0.5));
                c.rise = if (key == .rise) n else core.measure_unset;
                c.fall = if (key == .fall) n else core.measure_unset;
                c.cross = if (key == .cross) n else core.measure_unset;
            },
            .val => c.val = v,
            .td => c.td = v,
            .from => c.from = v,
            .to => c.to = v,
            .at => c.at = v,
            .minval => c.minval = v,
            .ignor, .ymin => c.ymin = v,
            .ymax => c.ymax = v,
            .goal => c.goal = v,
            .weight => c.weight = v,
            .print => {},
            .minfreq => c.from = v,
            .maxfreq => c.to = v,
            .nbharm, .binsiz => {
                if (!(v >= 0) or v > std.math.maxInt(u32)) return error.ParseError;
                const n: u32 = @intFromFloat(@floor(v + 0.5));
                if (key == .nbharm) c.nbharm = n else c.binsiz = n;
            },
        }
    }
    if (analysis == .dc and c.to < c.from) std.mem.swap(f64, &c.from, &c.to);
}

/// Blank- or comma-separated words; `{..}`, `'..'` and `(..)` stay whole,
/// and blanks around `=` join its sides.
fn words(arena: std.mem.Allocator, text: []const u8) ![]Word {
    var out: std.ArrayList(Word) = .empty;
    var i: usize = 0;
    var pending_eq = false;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == ',') {
            i += 1;
            continue;
        }
        const start = i;
        var depth: u32 = 0;
        var quote = false;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            if (b == '\'' or b == '"') quote = !quote;
            if (quote) continue;
            if (b == '{' or b == '(') depth += 1;
            if ((b == '}' or b == ')') and depth > 0) depth -= 1;
            if (depth == 0 and (b == ' ' or b == '\t' or b == ',')) break;
        }
        const tok = text[start..i];
        const eq = std.mem.indexOfScalar(u8, tok, '=');
        if (pending_eq or (tok[0] == '=' and out.items.len > 0)) {
            // `a =b`, `a = b` or `a= b`: this token completes the last word.
            const last = &out.items[out.items.len - 1];
            const value = if (tok[0] == '=') tok[1..] else tok;
            pending_eq = value.len == 0;
            last.rhs = value;
            continue;
        }
        if (eq) |e| {
            pending_eq = e + 1 == tok.len;
            try out.append(arena, .{ .lhs = tok[0..e], .rhs = tok[e + 1 ..] });
        } else try out.append(arena, .{ .lhs = tok });
    }
    if (pending_eq) return error.ParseError;
    return out.items;
}

test "meas cards parse like ngspice's word lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Ctx = struct {
        fn measureValue(_: @This(), t: []const u8) !f64 {
            return std.fmt.parseFloat(f64, t) catch error.ParseError;
        }
        fn measureExpr(_: @This(), _: []const u8) ![]const core.MeasureOp {
            return &.{.{ .measure = 0 }};
        }
    };
    const t = try parse(a, "tran tpd trig v(in) val = 0.9 rise=1 targ v(out) val= 0.9 fall =last td=1e-9", Ctx{}, null);
    try std.testing.expectEqual(.trig_targ, t.func);
    try std.testing.expectEqualStrings("v(out)", t.second.vec);
    try std.testing.expectEqual(0.9, t.first.val);
    try std.testing.expectEqual(1, t.first.rise);
    try std.testing.expectEqual(core.measure_last, t.second.fall);
    try std.testing.expectEqual(1e-9, t.second.td);
    const f = try parse(a, "ac g find vdb(out) when vp(out)=-45 cross=1", Ctx{}, null);
    try std.testing.expectEqualStrings("v(out)", f.first.vec);
    try std.testing.expectEqual('d', f.first.vectype);
    try std.testing.expectEqual('p', f.second.vectype);
    try std.testing.expectEqual(-45, f.second.val);
    const d = try parse(a, "dc x max v(1) from=2 to=-1", Ctx{}, null);
    try std.testing.expectEqual(-1, d.first.from);
    const w = try parse(a, "tran x when v(a)=v(b)", Ctx{}, null);
    try std.testing.expectEqualStrings("v(b)", w.first.vec2);
    try std.testing.expectError(error.ParseError, parse(a, "tran x trig v(a) val=1 targ v(b) val=1", Ctx{}, null));
    try std.testing.expectError(error.ParseError, parse(a, "tran x bogus v(a)", Ctx{}, null));
    // HSPICE: the analysis type defaults to the last analysis card.
    const e = try parse(a, "e err1 v(a) v(b) minval=1e-3 ymax=5", Ctx{}, .ac);
    try std.testing.expectEqual(.ac, e.analysis);
    try std.testing.expectEqual(.err1, e.func);
    try std.testing.expectEqualStrings("v(b)", e.first.vec2);
    try std.testing.expectEqual(1e-3, e.first.minval);
    try std.testing.expectError(error.ParseError, parse(a, "e err1 v(a) v(b)", Ctx{}, null));
    const p = try parse(a, "tran r param='tpd*2' goal=2 weight=3", Ctx{}, null);
    try std.testing.expectEqual(.param, p.func);
    try std.testing.expectEqual(3.0, p.goalError(4).?);
    const g = try parse(a, "dc v find v(out) at=5 goal=0 minval=0.5", Ctx{}, null);
    try std.testing.expectEqual(0.4, g.goalError(0.2).?);
    const s = try parse(a, "tran s derivative v(out) at=1e-9", Ctx{}, null);
    try std.testing.expectEqual(.deriv, s.func);
    try std.testing.expectEqual(1e-9, s.first.at);
}
