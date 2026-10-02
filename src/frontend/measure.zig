//! `.meas` card text to a `core.Measure`, after ngspice com_measure2.c
//! (measure_parse_trigtarg, _find, _when and _stdParams). The caller
//! evaluates the numbers, so a value may be a parameter expression. HSPICE
//! forms ride along: an omitted analysis type, INTEGRAL/DERIVATIVE, PARAM=
//! and ERR/ERR1/ERR2/ERR3, the `_CONT` analyses, EM_AVG, `par('expr')`
//! waveforms, values naming earlier results, TARG's `TD=TRIG` and
//! inherited TD, and the DCMATCH, ACMATCH, LSTB, PHASENOISE and PTDNOISE
//! analyses, which read those plots' columns by name [CR .MEASURE].
const std = @import("std");
const core = @import("core");
const Kind = core.query.Kind;
const Clause = core.MeasureClause;

/// `lhs`, or `lhs=rhs` with blanks around the `=` dropped.
const Word = struct { lhs: []const u8, rhs: ?[]const u8 = null };

const analyses = std.StaticStringMap(Kind).initComptime(.{
    .{ "tran", .tran },         .{ "ac", .ac },                 .{ "dc", .dc },
    .{ "fft", .fft },           .{ "trannoise", .tran_noise },  .{ "dcmatch", .dcmatch },
    .{ "acmatch", .acmatch },   .{ "lstb", .lstb },             .{ "phasenoise", .phasenoise },
    .{ "ptdnoise", .pnoise },
});
/// `.lstb`'s margins-plot columns, each a measure of its own:
/// `.meas lstb pm phase_margin` [CR .MEASURE LSTB].
const lstb_margins = std.StaticStringMap(void).initComptime(.{ .{"gain_margin"}, .{"phase_crossover_freq"}, .{"phase_margin"}, .{"unity_gain_freq"}, .{"loop_gain_minifreq"} });
/// HSPICE's `lstb(db)` spellings of the loop gain; `p` is in degrees.
const lstb_types = std.StaticStringMap(u8).initComptime(.{ .{ "db", 'd' }, .{ "m", 'm' }, .{ "mag", 'm' }, .{ "p", 'g' }, .{ "r", 'r' }, .{ "i", 'i' } });
/// HSPICE continuous measures [CR .MEASURE (Continuous Results)].
const cont_analyses = std.StaticStringMap(Kind).initComptime(.{ .{ "tran_cont", .tran }, .{ "ac_cont", .ac }, .{ "dc_cont", .dc } });

const funcs = std.StaticStringMap(core.MeasureFunc).initComptime(.{
    .{ "trig", .trig_targ }, .{ "delay", .trig_targ }, .{ "targ", .trig_targ },
    .{ "find", .find },      .{ "when", .when },       .{ "avg", .avg },
    .{ "min", .min },        .{ "max", .max },         .{ "min_at", .min_at },
    .{ "max_at", .max_at },  .{ "rms", .rms },         .{ "pp", .pp },
    .{ "integ", .integ },    .{ "deriv", .deriv },      .{ "integral", .integ },
    .{ "derivative", .deriv }, .{ "param", .param },    .{ "err", .err },
    .{ "err1", .err1 },      .{ "err2", .err2 },       .{ "err3", .err3 },
    .{ "thd", .thd },        .{ "snr", .snr },         .{ "sndr", .sndr },
    .{ "enob", .enob },      .{ "sfdr", .sfdr },       .{ "em_avg", .em_avg },
    .{ "jitter", .jitter },
});

/// Parses `text`, the card after `.meas`, lowercased. `ctx.measureValue(text)
/// !f64` evaluates a value, `ctx.measureExpr(text) ![]const core.MeasureOp`
/// compiles a PARAM= or `par()` expression and `ctx.measureOption(name) ?f64`
/// reads an `.option`. A card without an analysis type reads `default`,
/// HSPICE's last analysis card; `hspice` selects HSPICE's TARG TD
/// inheritance. Strings in the result are slices of `text` or allocated in
/// `arena`. ParseError for anything neither simulator accepts.
pub fn parse(arena: std.mem.Allocator, text: []const u8, ctx: anytype, default: ?Kind, hspice: bool) !core.Measure {
    const typed = try words(arena, text);
    if (typed.len < 2) return error.ParseError;
    const cont = cont_analyses.get(typed[0].lhs);
    const given = analyses.get(typed[0].lhs) orelse cont;
    const analysis = given orelse default orelse return error.ParseError;
    // `w[0]` is the analysis type's slot either way.
    const w = if (given != null) typed else try std.mem.concat(arena, Word, &.{ &.{.{ .lhs = "" }}, typed });
    if (w.len < 3) return error.ParseError;
    if (analysis == .lstb and w.len == 3 and lstb_margins.has(w[2].lhs))
        return .{ .analysis = analysis, .name = w[1].lhs, .func = .find, .first = .{ .vec = w[2].lhs } };
    const func = funcs.get(w[2].lhs) orelse return error.ParseError;
    // ngspice widens the default window of a DC sweep, which may run negative.
    var base: Clause = .{};
    if (analysis == .dc) {
        base.from = -1e99;
        base.to = 1e99;
    }
    // MAXFREQ defaults to the top of the spectrum [CR .MEASURE FFT].
    if (analysis == .fft) base.to = 1e99;
    var m: core.Measure = .{ .analysis = analysis, .name = w[1].lhs, .func = func, .first = base, .second = base, .cont = cont != null };
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
            // HSPICE: a TARG without TD inherits TRIG's [CR .MEASURE (Rise,
            // Fall, Delay, and Power Measurements)]. ngspice keeps it at 0.
            // ponytail: an explicit TD=0 on TARG reads as omitted.
            if (hspice and m.second.td == 0 and !m.second.td_trig and !hasRef(m.second, .td)) {
                m.second.td = m.first.td;
                var refs: std.ArrayList(core.MeasureRef) = .empty;
                try refs.appendSlice(arena, m.second.refs);
                for (m.first.refs) |r| if (r.field == .td) try refs.append(arena, r);
                m.second.refs = refs.items;
            }
            if (m.first.from != 0 and m.second.from == 0) m.second.from = m.first.from else if (m.second.from != 0 and m.first.from == 0) m.first.from = m.second.from;
        },
        .param => {
            m.expr = try ctx.measureExpr(w[2].rhs orelse return error.ParseError);
            try stdParams(arena, &m.first, analysis, rest, ctx);
        },
        .err, .err1, .err2, .err3 => {
            if (rest.len < 2) return error.ParseError;
            m.first.vec = try vector(arena, &m.first, analysis, rest[0].lhs, ctx);
            var ignored: Clause = .{};
            m.first.vec2 = try vector(arena, &ignored, analysis, rest[1].lhs, ctx);
            try stdParams(arena, &m.first, analysis, rest[2..], ctx);
        },
        .find, .deriv => {
            const k = find(rest, "when") orelse rest.len;
            if (k == 0 or rest[0].rhs != null) return error.ParseError;
            m.first.vec = try vector(arena, &m.first, analysis, rest[0].lhs, ctx);
            if (k > 1) {
                if (!std.mem.eql(u8, rest[1].lhs, "at") or rest[1].rhs == null) return error.ParseError;
                try stdParams(arena, &m.first, analysis, rest[1..k], ctx);
            }
            if (m.first.at == core.measure_no_at) {
                // A bare FIND reads a one-row plot (`.dcmatch`, `.lstb` margins).
                if (k == rest.len) {
                    if (func != .find or (analysis != .dcmatch and analysis != .lstb)) return error.ParseError;
                } else try when(arena, &m.second, analysis, rest[k + 1 ..], ctx);
            }
        },
        .when => try when(arena, &m.first, analysis, rest, ctx),
        // `.jitter trannoise|tran TRIG v(clk) VAL= [TD=] [RISE|FALL|CROSS=]`
        // [CR .JITTER], read as `.meas <kind> <name> jitter TRIG ...`.
        .jitter => {
            if (analysis != .tran and analysis != .tran_noise) return error.ParseError;
            if (rest.len == 0 or !std.mem.eql(u8, rest[0].lhs, "trig")) return error.ParseError;
            try trigTarg(arena, &m.first, analysis, rest[1..], ctx);
        },
        // `.meas fft name THD|SNR|SNDR|ENOB|SFDR v(out) [NBHARM=] [MAXFREQ=]
        // [MINFREQ=] [BINSIZ=]`.
        .thd, .snr, .sndr, .enob, .sfdr => {
            if (analysis != .fft or rest.len == 0 or rest[0].rhs != null) return error.ParseError;
            m.first.vec = rest[0].lhs;
            try stdParams(arena, &m.first, analysis, rest[1..], ctx);
        },
        else => try trigTarg(arena, &m.first, analysis, rest, ctx),
    }
    if (func == .em_avg) {
        if (analysis != .tran) return error.ParseError;
        m.first.val = ctx.measureOption("em_recovery") orelse 1;
    }
    return m;
}

fn hasRef(c: Clause, field: core.MeasureRef.Field) bool {
    for (c.refs) |r| if (r.field == field) return true;
    return false;
}

fn find(w: []const Word, key: []const u8) ?usize {
    for (w, 0..) |x, i| if (x.rhs == null and std.mem.eql(u8, x.lhs, key)) return i;
    return null;
}

/// An optional vector, then parameters.
fn trigTarg(arena: std.mem.Allocator, c: *Clause, analysis: Kind, w: []const Word, ctx: anytype) !void {
    if (w.len == 0) return error.ParseError;
    const has_vec = !std.mem.startsWith(u8, w[0].lhs, "at");
    if (has_vec) c.vec = try vector(arena, c, analysis, w[0].lhs, ctx);
    try stdParams(arena, c, analysis, w[@intFromBool(has_vec)..], ctx);
}

/// `vec=level` or `vec=vec2`, then parameters.
fn when(arena: std.mem.Allocator, c: *Clause, analysis: Kind, w: []const Word, ctx: anytype) !void {
    if (w.len == 0) return error.ParseError;
    const rhs = w[0].rhs orelse return error.ParseError;
    c.vec = try vector(arena, c, analysis, w[0].lhs, ctx);
    c.val = 1e99;
    // A result variable is always `v(..)`/`i(..)`/`par(..)`: a `(` names one.
    if (std.mem.indexOfScalar(u8, rhs, '(') != null) {
        var other: Clause = .{};
        c.vec2 = try vector(arena, &other, analysis, rhs, ctx);
        c.ops2 = other.ops;
    } else try setValue(arena, c, .val, rhs, ctx);
    try stdParams(arena, c, analysis, w[1..], ctx);
}

/// `vdb(out)` reads `v(out)` in dB for AC (ngspice correct_vec), `lstb(db)`
/// `loop_gain` in dB; `par('expr')` compiles into `c.ops`.
fn vector(arena: std.mem.Allocator, c: *Clause, analysis: Kind, name: []const u8, ctx: anytype) ![]const u8 {
    if (std.mem.startsWith(u8, name, "par(") and name[name.len - 1] == ')') {
        c.ops = try ctx.measureExpr(name[4 .. name.len - 1]);
        return name;
    }
    if (analysis == .lstb and std.mem.startsWith(u8, name, "lstb(") and name[name.len - 1] == ')') {
        c.vectype = lstb_types.get(name[5 .. name.len - 1]) orelse return error.ParseError;
        return "loop_gain";
    }
    if ((analysis != .ac and analysis != .fft) or name.len < 2 or name[0] != 'v' or name[1] == '(') return name;
    const paren = std.mem.indexOfScalar(u8, name, '(') orelse return name;
    c.vectype = name[1];
    return std.mem.concat(arena, u8, &.{ "v", name[paren..] });
}

/// Sets `field` of `c` from `text`: a number or parameter expression, or,
/// in HSPICE, an expression over earlier `.meas` results kept as a ref.
fn setValue(arena: std.mem.Allocator, c: *Clause, field: core.MeasureRef.Field, text: []const u8, ctx: anytype) !void {
    const v = ctx.measureValue(text) catch |err| {
        if (err == error.OutOfMemory) return err;
        var refs: std.ArrayList(core.MeasureRef) = .empty;
        try refs.appendSlice(arena, c.refs);
        try refs.append(arena, .{ .field = field, .expr = try ctx.measureExpr(text) });
        c.refs = refs.items;
        return;
    };
    switch (field) {
        .val => c.val = v,
        .td => c.td = v,
        .from => c.from = v,
        .to => c.to = v,
        .at => c.at = v,
    }
}

fn stdParams(arena: std.mem.Allocator, c: *Clause, analysis: Kind, w: []const Word, ctx: anytype) !void {
    for (w) |x| {
        const rhs = x.rhs orelse {
            // REVERSE lets the target precede the trigger, which a
            // negative result already reports.
            if (std.mem.eql(u8, x.lhs, "reverse")) continue;
            if (!std.mem.eql(u8, x.lhs, "last")) return error.ParseError;
            c.cross = core.measure_last;
            c.rise = core.measure_unset;
            c.fall = core.measure_unset;
            continue;
        };
        // `print` only switches HSPICE's listing.
        const Key = enum { rise, fall, cross, val, td, from, to, at, minval, ignor, ymin, ymax, goal, weight, nbharm, minfreq, maxfreq, binsiz, print };
        const key = std.meta.stringToEnum(Key, x.lhs) orelse return error.ParseError;
        switch (key) {
            .val, .td, .from, .to, .at => {
                if (key == .td and std.mem.eql(u8, rhs, "trig")) {
                    c.td_trig = true;
                } else try setValue(arena, c, std.meta.stringToEnum(core.MeasureRef.Field, x.lhs).?, rhs, ctx);
                continue;
            },
            else => {},
        }
        const bound: core.GoalBound = if (key != .goal) .equal else switch (rhs[0]) {
            '<' => .below,
            '>' => .above,
            else => .equal,
        };
        const text = if (bound == .equal) rhs else std.mem.trim(u8, rhs[1..], " \t");
        const v: f64 = if (std.mem.eql(u8, text, "last")) core.measure_last else try ctx.measureValue(text);
        switch (key) {
            .rise, .fall, .cross => {
                const n = std.math.lossyCast(i32, @floor(v + 0.5));
                c.rise = if (key == .rise) n else core.measure_unset;
                c.fall = if (key == .fall) n else core.measure_unset;
                c.cross = if (key == .cross) n else core.measure_unset;
            },
            .val, .td, .from, .to, .at => unreachable,
            .minval => c.minval = v,
            .ignor, .ymin => c.ymin = v,
            .ymax => c.ymax = v,
            .goal => {
                c.goal = v;
                c.goal_bound = bound;
            },
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
            // `goal > v`: the rhs runs from the operator to the value.
            const op = last.rhs orelse "";
            last.rhs = if (op.len != 0 and (op[0] == '<' or op[0] == '>')) text[@intFromPtr(op.ptr) - @intFromPtr(text.ptr) .. i] else value;
            continue;
        }
        if ((tok[0] == '<' or tok[0] == '>') and out.items.len > 0 and out.items[out.items.len - 1].rhs == null and
            std.mem.eql(u8, out.items[out.items.len - 1].lhs, "goal"))
        {
            // HSPICE `GOAL < v` / `GOAL > v` [SA Ch.27]: the operator stays in the rhs.
            out.items[out.items.len - 1].rhs = tok;
            pending_eq = tok.len == 1;
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

/// Logic thresholds of `.check` cards: low at or below `lo`, high at or
/// above `hi`.
pub const Levels = struct { lo: f64, hi: f64 };

/// Appends the measures an HSPICE `.check`, `.dout` or `.biaschk` card
/// expands to, one per node, to `out` [CR .CHECK, .DOUT, .BIASCHK]. `card`
/// is the card name without its dot and `text` the rest, lowercased.
/// `.check global_level` only sets `global`, which later cards default to.
/// `serial` numbers the card in its measures' names (`setup2_v1`).
/// ParseError for a form ESPice does not read: a node wildcard, an element
/// or region `.biaschk`, a `.biaschk` outside the transient.
pub fn parseCheck(arena: std.mem.Allocator, card: []const u8, text: []const u8, ctx: anytype, global: *?Levels, serial: u32, out: *std.ArrayList(core.Measure)) !void {
    const w = try words(arena, text);
    if (w.len == 0) return error.ParseError;
    var m: core.Measure = .{ .analysis = .tran, .name = "", .func = .check_slew, .first = .{}, .second = .{} };
    var nodes = w;
    if (std.mem.eql(u8, card, "biaschk")) {
        // `'expr' [limit=] [max=] [min=] [simulation=tr] [tstart=] [tstop=] ...`
        if (w[0].lhs[0] != '\'' and w[0].lhs[0] != '"') return error.ParseError;
        m.func = .check_level;
        m.first.ops = try ctx.measureExpr(w[0].lhs);
        m.first.vec = w[0].lhs;
        for (w[1..]) |x| {
            const rhs = x.rhs orelse continue; // `autostop`
            if (std.mem.eql(u8, x.lhs, "simulation")) {
                if (!std.mem.eql(u8, rhs, "tr")) return error.ParseError;
            } else if (std.mem.eql(u8, x.lhs, "limit") or std.mem.eql(u8, x.lhs, "max")) {
                m.check.max = try ctx.measureValue(rhs);
            } else if (std.mem.eql(u8, x.lhs, "min")) {
                m.check.min = try ctx.measureValue(rhs);
            } else if (std.mem.eql(u8, x.lhs, "tstart")) {
                m.first.from = try ctx.measureValue(rhs);
            } else if (std.mem.eql(u8, x.lhs, "tstop")) {
                m.first.to = try ctx.measureValue(rhs);
            } else if (!std.mem.eql(u8, x.lhs, "noise") and !std.mem.eql(u8, x.lhs, "interval")) return error.ParseError;
        }
        m.name = try std.fmt.allocPrint(arena, "biaschk{d}", .{serial});
        return out.append(arena, m);
    }
    if (std.mem.eql(u8, card, "dout")) {
        // `nd [nd ...] [VTH | VLO VHI] (time state [state ...] ...)`; the
        // group may touch the last word (`vth(0n 1 ...)`).
        var last = w[w.len - 1].lhs;
        const open = std.mem.indexOfScalar(u8, last, '(') orelse return error.ParseError;
        const head = last[0..open];
        last = last[open..];
        var names: std.ArrayList([]const u8) = .empty;
        var levels: std.ArrayList(f64) = .empty;
        for (w[0 .. w.len - 1]) |x| try names.append(arena, x.lhs);
        if (head.len > 0) try names.append(arena, head);
        // The first word is a node; values after it are thresholds.
        while (names.items.len > 1) {
            const v = ctx.measureValue(names.items[names.items.len - 1]) catch break;
            try levels.insert(arena, 0, v);
            _ = names.pop();
        }
        // ponytail: no threshold given reads the .vec VTH default, 1.65 V.
        const lo, const hi = switch (levels.items.len) {
            0 => .{ 1.65, 1.65 },
            1 => .{ levels.items[0], levels.items[0] },
            2 => .{ levels.items[0], levels.items[1] },
            else => return error.ParseError,
        };
        const row = try words(arena, last[1 .. last.len - 1]);
        const width = names.items.len + 1;
        if (row.len == 0 or row.len % width != 0) return error.ParseError;
        for (names.items, 0..) |node, k| {
            var expect: std.ArrayList([2]f64) = .empty;
            var r: usize = 0;
            while (r < row.len) : (r += width) {
                const state = row[r + 1 + k].lhs;
                if (std.mem.eql(u8, state, "0") or std.mem.eql(u8, state, "1"))
                    try expect.append(arena, .{ try ctx.measureValue(row[r].lhs), if (state[0] == '1') 1 else 0 });
            }
            var d = m;
            d.func = .dout;
            d.check = .{ .lo = lo, .hi = hi, .expect = expect.items };
            try appendNode(arena, d, "dout", serial, node, out);
        }
        return;
    }
    if (!std.mem.eql(u8, card, "check") or w.len < 2) return error.ParseError;
    const Kind_ = enum { global_level, rise, fall, slew, setup, hold, edge, irdrop };
    const kind = std.meta.stringToEnum(Kind_, w[0].lhs) orelse return error.ParseError;
    const spec = try groupWords(arena, w[1].lhs);
    nodes = w[2..];
    var levels = global.*;
    if (nodes.len > 0 and nodes[nodes.len - 1].lhs[0] == '(') {
        levels = try parseLevels(arena, nodes[nodes.len - 1].lhs, ctx);
        nodes = nodes[0 .. nodes.len - 1];
    }
    if (kind == .global_level) {
        global.* = try parseLevels(arena, w[1].lhs, ctx);
        return;
    }
    if (nodes.len == 0) return error.ParseError;
    switch (kind) {
        .global_level => unreachable,
        // `(min max)`
        .rise, .fall, .slew => {
            if (spec.len != 2) return error.ParseError;
            m.check.min = try ctx.measureValue(spec[0].lhs);
            m.check.max = try ctx.measureValue(spec[1].lhs);
            m.check.edge = switch (kind) {
                .rise => .rise,
                .fall => .fall,
                else => .both,
            };
        },
        // `(ref RISE|FALL duration RISE|FALL)`, `(ref RISE|FALL min max RISE|FALL)`
        .setup, .hold, .edge => {
            if (spec.len != @as(usize, if (kind == .edge) 5 else 4)) return error.ParseError;
            m.second.vec = try nodeVector(arena, spec[0].lhs);
            m.check.ref_edge = try edgeOf(spec[1].lhs);
            m.check.edge = try edgeOf(spec[spec.len - 1].lhs);
            const a = try ctx.measureValue(spec[2].lhs);
            m.func = if (kind == .edge) .check_require else .check_forbid;
            m.check.min, m.check.max = switch (kind) {
                .setup => .{ -a, 0 },
                .hold => .{ 0, a },
                else => .{ a, try ctx.measureValue(spec[3].lhs) },
            };
        },
        // `(volt duration)`: below a negative level, above a positive one.
        .irdrop => {
            if (spec.len != 2) return error.ParseError;
            const v = try ctx.measureValue(spec[0].lhs);
            m.func = .check_level;
            m.check.dur = try ctx.measureValue(spec[1].lhs);
            if (v < 0) m.check.min = v else m.check.max = v;
        },
    }
    if (m.func != .check_level) {
        const l = levels orelse return error.ParseError;
        m.check.lo = l.lo;
        m.check.hi = l.hi;
    }
    for (nodes) |x| try appendNode(arena, m, @tagName(kind), serial, x.lhs, out);
}

/// `m` reading node `node`, named `<kind><serial>_<node>`.
fn appendNode(arena: std.mem.Allocator, m: core.Measure, kind: []const u8, serial: u32, node: []const u8, out: *std.ArrayList(core.Measure)) !void {
    var one = m;
    one.first.vec = try nodeVector(arena, node);
    one.name = try std.fmt.allocPrint(arena, "{s}{d}_{s}", .{ kind, serial, node });
    try out.append(arena, one);
}

/// A bare node name as its result label, `v(node)`; a `v(..)` or `i(..)`
/// stays as written.
fn nodeVector(arena: std.mem.Allocator, node: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, node, '*') != null) return error.ParseError;
    if (std.mem.indexOfScalar(u8, node, '(') != null) return node;
    return std.fmt.allocPrint(arena, "v({s})", .{node});
}

fn edgeOf(word: []const u8) !core.Check.Edge {
    if (std.mem.eql(u8, word, "rise")) return .rise;
    if (std.mem.eql(u8, word, "fall")) return .fall;
    return error.ParseError;
}

/// The words inside a `( ... )` group.
fn groupWords(arena: std.mem.Allocator, group: []const u8) ![]Word {
    if (group.len < 2 or group[0] != '(' or group[group.len - 1] != ')') return error.ParseError;
    return words(arena, group[1 .. group.len - 1]);
}

/// `(hi lo hi_th lo_th)`; a threshold ending in `%` is that share of the
/// swing above `lo`.
fn parseLevels(arena: std.mem.Allocator, group: []const u8, ctx: anytype) !Levels {
    const g = try groupWords(arena, group);
    if (g.len != 4) return error.ParseError;
    const hi = try ctx.measureValue(g[0].lhs);
    const lo = try ctx.measureValue(g[1].lhs);
    var th: [2]f64 = undefined;
    for (g[2..], &th) |x, *t| {
        const s = x.lhs;
        t.* = if (s[s.len - 1] == '%') lo + (hi - lo) * try ctx.measureValue(s[0 .. s.len - 1]) / 100 else try ctx.measureValue(s);
    }
    return .{ .lo = th[1], .hi = th[0] };
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
        fn measureOption(_: @This(), _: []const u8) ?f64 {
            return 0.5;
        }
    };
    const t = try parse(a, "tran tpd trig v(in) val = 0.9 rise=1 targ v(out) val= 0.9 fall =last td=1e-9", Ctx{}, null, false);
    try std.testing.expectEqual(.trig_targ, t.func);
    try std.testing.expectEqualStrings("v(out)", t.second.vec);
    try std.testing.expectEqual(0.9, t.first.val);
    try std.testing.expectEqual(1, t.first.rise);
    try std.testing.expectEqual(core.measure_last, t.second.fall);
    try std.testing.expectEqual(1e-9, t.second.td);
    const f = try parse(a, "ac g find vdb(out) when vp(out)=-45 cross=1", Ctx{}, null, false);
    try std.testing.expectEqualStrings("v(out)", f.first.vec);
    try std.testing.expectEqual('d', f.first.vectype);
    try std.testing.expectEqual('p', f.second.vectype);
    try std.testing.expectEqual(-45, f.second.val);
    const d = try parse(a, "dc x max v(1) from=2 to=-1", Ctx{}, null, false);
    try std.testing.expectEqual(-1, d.first.from);
    const w = try parse(a, "tran x when v(a)=v(b)", Ctx{}, null, false);
    try std.testing.expectEqualStrings("v(b)", w.first.vec2);
    try std.testing.expectError(error.ParseError, parse(a, "tran x trig v(a) val=1 targ v(b) val=1", Ctx{}, null, false));
    try std.testing.expectError(error.ParseError, parse(a, "tran x bogus v(a)", Ctx{}, null, false));
    // HSPICE: the analysis type defaults to the last analysis card.
    const e = try parse(a, "e err1 v(a) v(b) minval=1e-3 ymax=5", Ctx{}, .ac, true);
    try std.testing.expectEqual(.ac, e.analysis);
    try std.testing.expectEqual(.err1, e.func);
    try std.testing.expectEqualStrings("v(b)", e.first.vec2);
    try std.testing.expectEqual(1e-3, e.first.minval);
    try std.testing.expectError(error.ParseError, parse(a, "e err1 v(a) v(b)", Ctx{}, null, false));
    const p = try parse(a, "tran r param='tpd*2' goal=2 weight=3", Ctx{}, null, false);
    try std.testing.expectEqual(.param, p.func);
    try std.testing.expectEqual(3.0, p.goalError(4).?);
    const g = try parse(a, "dc v find v(out) at=5 goal=0 minval=0.5", Ctx{}, null, false);
    try std.testing.expectEqual(0.4, g.goalError(0.2).?);
    const above = try parse(a, "dc v find v(out) at=5 goal > 2", Ctx{}, null, false);
    try std.testing.expectEqual(.above, above.first.goal_bound);
    try std.testing.expectEqual(0, above.goalError(3).?);
    try std.testing.expectEqual(-0.5, above.goalError(1).?);
    const below = try parse(a, "dc v find v(out) at=5 goal <2 weight=2", Ctx{}, null, false);
    try std.testing.expectEqual(0, below.goalError(1).?);
    try std.testing.expectEqual(1.0, below.goalError(3).?);
    const s = try parse(a, "tran s derivative v(out) at=1e-9", Ctx{}, null, false);
    try std.testing.expectEqual(.deriv, s.func);
    try std.testing.expectEqual(1e-9, s.first.at);
    // HSPICE: TARG inherits TRIG's TD, TD=TRIG, values naming results,
    // par() waveforms, REVERSE, the _CONT analyses and EM_AVG.
    const h = try parse(a, "tran d trig v(a) val=1 td=2 rise=1 targ v(b) val=1 rise=1 reverse", Ctx{}, null, true);
    try std.testing.expectEqual(2, h.second.td);
    const n = try parse(a, "tran d trig v(a) val=1 td=2 rise=1 targ v(b) val=1 rise=1", Ctx{}, null, false);
    try std.testing.expectEqual(0, n.second.td);
    const tt = try parse(a, "tran d trig v(a) val=1 rise=2 targ v(b) val=1 rise=1 td=trig", Ctx{}, null, true);
    try std.testing.expect(tt.second.td_trig);
    const r = try parse(a, "tran r avg par('v(a)/2') from=t10 to=2", Ctx{}, null, true);
    try std.testing.expectEqual(1, r.first.ops.len);
    try std.testing.expectEqual(.from, r.first.refs[0].field);
    try std.testing.expectEqual(2, r.first.to);
    const c = try parse(a, "tran_cont c when v(a)=1 fall=2", Ctx{}, null, true);
    try std.testing.expect(c.cont and c.analysis == .tran);
    const em = try parse(a, "tran em em_avg i(r1) from=1 to=2", Ctx{}, null, true);
    try std.testing.expectEqual(0.5, em.first.val);
    // Measures over the newer plots: LSTB keywords and lstb(db), a bare
    // FIND on a one-row plot, PTDNOISE reading the .pnoise result.
    const pm = try parse(a, "lstb pm phase_margin", Ctx{}, null, true);
    try std.testing.expectEqual(.find, pm.func);
    try std.testing.expectEqualStrings("phase_margin", pm.first.vec);
    const lg = try parse(a, "lstb f0 when lstb(db)=0", Ctx{}, null, true);
    try std.testing.expectEqualStrings("loop_gain", lg.first.vec);
    try std.testing.expectEqual('d', lg.first.vectype);
    const dm = try parse(a, "dcmatch s find total_3sigma", Ctx{}, null, true);
    try std.testing.expectEqual(core.measure_no_at, dm.first.at);
    try std.testing.expectError(error.ParseError, parse(a, "ac s find v(out)", Ctx{}, null, true));
    try std.testing.expectEqual(.pnoise, (try parse(a, "ptdnoise n find ptdnoise_density at=1e3", Ctx{}, null, true)).analysis);
    // HSPICE .check: GLOBAL_LEVEL thresholds, one measure per node.
    var checks: std.ArrayList(core.Measure) = .empty;
    var global: ?Levels = null;
    try parseCheck(a, "check", "global_level (1 0 80% 20%)", Ctx{}, &global, 1, &checks);
    try std.testing.expectEqual(0, checks.items.len);
    try parseCheck(a, "check", "setup (clk rise 2 fall) a b", Ctx{}, &global, 1, &checks);
    try std.testing.expectEqualStrings("setup1_b", checks.items[1].name);
    try std.testing.expectEqualStrings("v(clk)", checks.items[0].second.vec);
    try std.testing.expectEqual(core.Check{ .lo = 0.2, .hi = 0.8, .min = -2, .max = 0, .edge = .fall, .ref_edge = .rise }, checks.items[0].check);
    try parseCheck(a, "dout", "b c 0.5 (1 1 x 2 0 1)", Ctx{}, &global, 2, &checks);
    try std.testing.expectEqualSlices([2]f64, &.{ .{ 1, 1 }, .{ 2, 0 } }, checks.items[2].check.expect);
    try std.testing.expectEqualSlices([2]f64, &.{.{ 2, 1 }}, checks.items[3].check.expect);
    try std.testing.expectError(error.ParseError, parseCheck(a, "check", "rise (1 2) a*", Ctx{}, &global, 3, &checks));
}
