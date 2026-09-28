//! Spectre statements -> SPICE cards: the Spectre dialect's reader, run on
//! the logical lines before netlist.zig reads any card, as pattern.zig
//! rewrites PAT sources. dev/frontend.md "Spectre dialect" is the mapping;
//! § numbers cite dev/research/spectre-syntax.md, and tests/grammar/spectre.peg
//! is the syntax. A Spectre instance name says nothing about its device, so
//! each rewritten device card's letter is kept beside it (`Kinds`).
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const lines = @import("lines.zig");

/// `ParseError`: a malformed statement; `UnsupportedCard`: a statement or
/// form ESPice does not read (logged with the line).
pub const Error = error{ OutOfMemory, ParseError, UnsupportedCard };

/// The device letter of each rewritten card, keyed by `@intFromPtr` of the
/// card's first byte: valid only for the slices `translate` returned, and
/// only while their arena lives.
pub const Kinds = std.AutoHashMapUnmanaged(usize, u8);

/// Rewrites Spectre logical lines (the title already taken) into SPICE cards
/// in `arena`; `kinds` receives each device card's letter. A failing
/// statement is logged with its line; `ParseError` also when a `subckt` or
/// block is still open at the end.
pub fn translate(arena: Allocator, in: []const []const u8, kinds: *Kinds) Error![]const []const u8 {
    var t: T = .{ .arena = arena, .kinds = kinds };
    try t.declare(in);
    var spice = false;
    for (in) |line| {
        if (spice) {
            if (switchesTo(line, "spectre")) {
                spice = false;
                continue;
            }
            try t.out.append(arena, try spiceCard(arena, line));
            continue;
        }
        if (switchesTo(line, "spice")) {
            spice = true;
            continue;
        }
        t.statement(line) catch |err| {
            if (!@import("builtin").is_test) std.log.err("spectre: {s}: {s}", .{ @errorName(err), line });
            return err;
        };
    }
    if (t.subckts.items.len != 0 or t.blocks.items.len != 0) return error.ParseError;
    return t.out.items;
}

/// Whether `line` is `simulator lang=<lang> ...`, compared
/// case-insensitively, as a SPICE region writes it; fields after the
/// language are ignored.
pub fn switchesTo(line: []const u8, lang: []const u8) bool {
    var f = lines.Fields("\"", false).init(line);
    for ([_][]const u8{ "simulator", "lang", "=" }) |w| if (!std.ascii.eqlIgnoreCase(f.next() orelse return false, w)) return false;
    return std.ascii.eqlIgnoreCase(f.next() orelse return false, lang);
}

/// A card of a `simulator lang=spice` region (§3.2): lowercased, its numbers
/// written plain (SPICE suffixes, `meg` is 1e6), and `'expr'` as `"expr"`,
/// the Spectre field splitter's quote.
fn spiceCard(arena: Allocator, line: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        const prev: u8 = if (i == 0) ' ' else line[i - 1];
        const starts = std.ascii.isDigit(c) or (c == '.' and i + 1 < line.len and std.ascii.isDigit(line[i + 1]));
        if (starts and !(std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '.')) {
            var j = i;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '.' or
                ((line[j] == '+' or line[j] == '-') and j > i and std.ascii.toLower(line[j - 1]) == 'e'))) j += 1;
            const lower = try std.ascii.allocLowerString(arena, line[i..j]);
            if (lines.hspice.parseNum(lower)) |v| {
                try out.print(arena, "{e}", .{v});
            } else try out.appendSlice(arena, lower);
            i = j;
            continue;
        }
        try out.append(arena, if (c == '\'') '"' else std.ascii.toLower(c));
        i += 1;
    }
    return out.items;
}

// Tokens ------------------------------------------------------------------

const Tok = struct {
    kind: Kind,
    text: []const u8,

    const Kind = enum { word, string, punct, op };

    fn is(t: Tok, s: []const u8) bool {
        return (t.kind == .punct or t.kind == .op or t.kind == .word) and std.mem.eql(u8, t.text, s);
    }
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '!' or c == '$' or c == '.';
}

/// Splits one Spectre line into words (names, numbers, nodes; a backslash
/// escapes the next byte, §2.2), strings, punctuation and operators.
fn tokenize(arena: Allocator, line: []const u8) Error![]const Tok {
    var out: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        const start = i;
        if (c == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') : (i += 1) if (line[i] == '\\') {
                i += 1;
            };
            if (i >= line.len) return error.ParseError;
            i += 1;
            try out.append(arena, .{ .kind = .string, .text = line[start..i] });
            continue;
        }
        if (isWordByte(c) or c == '\\') {
            while (i < line.len and (isWordByte(line[i]) or line[i] == '\\')) {
                if (line[i] == '\\') i += 1;
                i += 1;
                // An exponent's sign belongs to a number (`1e-9`).
                if (i + 1 < line.len and (line[i] == '+' or line[i] == '-') and
                    (line[i - 1] == 'e' or line[i - 1] == 'E') and std.ascii.isDigit(line[start]) and std.ascii.isDigit(line[i + 1])) i += 1;
            }
            try out.append(arena, .{ .kind = .word, .text = line[start..@min(i, line.len)] });
            continue;
        }
        const two = if (i + 1 < line.len) line[i .. i + 2] else "";
        const pair = for ([_][]const u8{ "**", "<=", ">=", "==", "!=", "&&", "||", "<<", ">>", "~^", "^~" }) |op| {
            if (std.mem.eql(u8, two, op)) break true;
        } else false;
        if (pair) {
            try out.append(arena, .{ .kind = .op, .text = two });
            i += 2;
        } else if (std.mem.indexOfScalar(u8, "()[]{}=,:;", c) != null) {
            try out.append(arena, .{ .kind = .punct, .text = line[i .. i + 1] });
            i += 1;
        } else {
            try out.append(arena, .{ .kind = .op, .text = line[i .. i + 1] });
            i += 1;
        }
    }
    return out.items;
}

// Expressions -------------------------------------------------------------

/// §6.3: the built-in constants, as their values.
const constants = std.StaticStringMap(f64).initComptime(.{
    .{ "M_E", std.math.e },          .{ "M_LOG2E", std.math.log2e },      .{ "M_LOG10E", std.math.log10e },
    .{ "M_LN2", std.math.ln2 },      .{ "M_LN10", std.math.ln10 },        .{ "M_PI", std.math.pi },
    .{ "M_TWO_PI", 2.0 * std.math.pi }, .{ "M_PI_2", std.math.pi / 2.0 },   .{ "M_PI_4", std.math.pi / 4.0 },
    .{ "M_1_PI", 1.0 / std.math.pi },  .{ "M_2_PI", 2.0 / std.math.pi },      .{ "M_2_SQRTPI", std.math.two_sqrtpi },
    .{ "M_SQRT2", std.math.sqrt2 },  .{ "M_SQRT1_2", std.math.sqrt1_2 },  .{ "M_DEGPERRAD", 180.0 / std.math.pi },
    .{ "P_Q", 1.6021918e-19 },       .{ "P_C", 2.997924562e8 },           .{ "P_K", 1.3806226e-23 },
    .{ "P_H", 6.6260755e-34 },       .{ "P_EPS0", 8.85418792394420013968e-12 }, .{ "P_U0", 4.0e-7 * std.math.pi },
    .{ "P_CELSIUS0", 273.15 },
});

/// A Spectre expression -> ESPice expression text, fully parenthesized so
/// expr.zig sees Spectre's tree (§6.1). `toks` is consumed from `at`.
const Expr = struct {
    toks: []const Tok,
    at: usize = 0,
    out: *std.ArrayList(u8),
    arena: Allocator,
    depth: u32 = 0,

    const depth_max = 256;

    fn peek(e: *Expr) ?Tok {
        return if (e.at < e.toks.len) e.toks[e.at] else null;
    }

    fn take(e: *Expr) ?Tok {
        const t = e.peek() orelse return null;
        e.at += 1;
        return t;
    }

    fn put(e: *Expr, s: []const u8) Error!void {
        try e.out.appendSlice(e.arena, s);
    }

    /// Binary levels, loosest first; `**` is the right-associative one.
    const levels = [_][]const []const u8{
        &.{"||"}, &.{"&&"}, &.{ "==", "!=" }, &.{ "<", "<=", ">", ">=" }, &.{ "+", "-" }, &.{ "*", "/", "%" },
    };

    fn ternary(e: *Expr) Error!void {
        if (e.depth == depth_max) return error.ParseError;
        e.depth += 1;
        defer e.depth -= 1;
        const mark = e.out.items.len;
        try e.binary(0);
        if (e.peek()) |t| if (t.is("?")) {
            _ = e.take();
            const cond = try e.arena.dupe(u8, e.out.items[mark..]);
            e.out.shrinkRetainingCapacity(mark);
            try e.put("(");
            try e.put(cond);
            try e.put("?");
            try e.ternary();
            if (!(e.take() orelse return error.ParseError).is(":")) return error.ParseError;
            try e.put(":");
            try e.ternary();
            try e.put(")");
        };
    }

    fn binary(e: *Expr, level: usize) Error!void {
        if (level == levels.len) return e.power();
        const mark = e.out.items.len;
        try e.binary(level + 1);
        while (e.peek()) |t| {
            if (t.kind != .op) break;
            const op = for (levels[level]) |o| {
                if (std.mem.eql(u8, t.text, o)) break o;
            } else break;
            _ = e.take();
            const lhs = try e.arena.dupe(u8, e.out.items[mark..]);
            e.out.shrinkRetainingCapacity(mark);
            try e.put("(");
            try e.put(lhs);
            try e.put(op);
            try e.binary(level + 1);
            try e.put(")");
        }
    }

    /// `a ** b ** c` is `a ** (b ** c)`; a unary operand binds tighter
    /// than `**` (§6.1: `-2**2` is 4).
    fn power(e: *Expr) Error!void {
        const mark = e.out.items.len;
        try e.unary();
        if (e.peek()) |t| if (t.is("**")) {
            _ = e.take();
            const lhs = try e.arena.dupe(u8, e.out.items[mark..]);
            e.out.shrinkRetainingCapacity(mark);
            try e.put("(");
            try e.put(lhs);
            try e.put("**");
            if (e.depth == depth_max) return error.ParseError;
            e.depth += 1;
            defer e.depth -= 1;
            try e.power();
            try e.put(")");
        };
    }

    fn unary(e: *Expr) Error!void {
        const t = e.peek() orelse return error.ParseError;
        if (t.kind == .op and (t.is("-") or t.is("+") or t.is("!"))) {
            _ = e.take();
            if (e.depth == depth_max) return error.ParseError;
            e.depth += 1;
            defer e.depth -= 1;
            try e.put("(");
            try e.put(t.text);
            try e.unary();
            try e.put(")");
            return;
        }
        if (t.kind == .op) return error.UnsupportedCard; // bitwise, shift
        return e.primary();
    }

    fn primary(e: *Expr) Error!void {
        const t = e.take() orelse return error.ParseError;
        switch (t.kind) {
            .string => return e.put(t.text),
            .punct => {
                if (!t.is("(")) return error.ParseError;
                try e.put("(");
                try e.ternary();
                if (!(e.take() orelse return error.ParseError).is(")")) return error.ParseError;
                return e.put(")");
            },
            .op => unreachable,
            .word => {},
        }
        const w = t.text;
        if (std.ascii.isDigit(w[0]) or w[0] == '.') return e.number(w);
        if (e.peek()) |n| if (n.is("(")) return e.call(w);
        if (constants.get(w)) |v| return e.out.print(e.arena, "{e}", .{v});
        // `temp` is the circuit temperature (§6.3); `$time` a behavioural
        // expression's time.
        if (std.mem.eql(u8, w, "temp")) return e.put("temper");
        if (std.mem.eql(u8, w, "$time")) return e.put("time");
        return e.put(w);
    }

    fn number(e: *Expr, w: []const u8) Error!void {
        const v = lines.spectre.parseNum(w) orelse return error.ParseError;
        try e.out.print(e.arena, "{e}", .{v});
    }

    /// A call. `fmod` is `%` and `hypot` its square root; the rest keep
    /// their names, which expr.zig reads (§6.2).
    fn call(e: *Expr, name: []const u8) Error!void {
        _ = e.take(); // (
        var args: std.ArrayList([]const u8) = .empty;
        const first = e.peek() orelse return error.ParseError;
        if (first.is(")")) {
            _ = e.take();
        } else while (true) {
            const mark = e.out.items.len;
            try e.ternary();
            try args.append(e.arena, try e.arena.dupe(u8, e.out.items[mark..]));
            e.out.shrinkRetainingCapacity(mark);
            const sep = e.take() orelse return error.ParseError;
            if (sep.is(")")) break;
            if (!sep.is(",")) return error.ParseError;
        }
        if (std.mem.eql(u8, name, "fmod") and args.items.len == 2)
            return e.out.print(e.arena, "({s}%{s})", .{ args.items[0], args.items[1] });
        if (std.mem.eql(u8, name, "hypot") and args.items.len == 2)
            return e.out.print(e.arena, "sqrt({s}*{s}+{s}*{s})", .{ args.items[0], args.items[0], args.items[1], args.items[1] });
        if (std.mem.eql(u8, name, "sign") and args.items.len == 2)
            return e.out.print(e.arena, "(sgn({s})*abs({s}))", .{ args.items[1], args.items[0] });
        if (std.mem.eql(u8, name, "atan2")) return error.UnsupportedCard;
        try e.put(name);
        try e.put("(");
        for (args.items, 0..) |a, i| {
            if (i > 0) try e.put(",");
            try e.put(a);
        }
        try e.put(")");
    }
};

/// The ESPice text of the Spectre expression `toks`, all of them.
fn expression(arena: Allocator, toks: []const Tok) Error![]const u8 {
    if (toks.len == 0) return error.ParseError;
    var out: std.ArrayList(u8) = .empty;
    var e: Expr = .{ .toks = toks, .out = &out, .arena = arena };
    try e.ternary();
    if (e.at != toks.len) {
        // §6.1's bitwise and shift operators are Spectre, not read here.
        const t = toks[e.at];
        if (t.kind == .op and std.mem.indexOfAny(u8, t.text, "&|^~<>") != null) return error.UnsupportedCard;
        return error.ParseError;
    }
    return out.items;
}

// Statements --------------------------------------------------------------

/// A parameter as written: its key and value tokens (a vector's included).
const Param = struct { key: []const u8, value: []const Tok };

/// Splits `toks` into `key=value` parameters: a value runs to the next
/// `key=` at depth 0 (§4.2). Parentheses around one (`(c=1p)`) are dropped.
fn params(arena: Allocator, toks: []const Tok) Error![]const Param {
    var out: std.ArrayList(Param) = .empty;
    var i: usize = 0;
    while (i < toks.len) {
        if (toks[i].is("(") and i + 2 < toks.len and toks[i + 2].is("=")) {
            // `(c=1p)`: find its close and read the inside.
            var depth: usize = 0;
            var j = i;
            while (j < toks.len) : (j += 1) {
                if (toks[j].is("(")) depth += 1;
                if (toks[j].is(")")) {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (j == toks.len) return error.ParseError;
            try out.appendSlice(arena, try params(arena, toks[i + 1 .. j]));
            i = j + 1;
            continue;
        }
        if (toks[i].kind != .word or i + 1 >= toks.len or !toks[i + 1].is("=")) return error.ParseError;
        const key = toks[i].text;
        var j = i + 2;
        var depth: usize = 0;
        while (j < toks.len) : (j += 1) {
            const t = toks[j];
            if (t.is("(") or t.is("[")) depth += 1;
            if (t.is(")") or t.is("]")) depth -|= 1;
            if (depth == 0 and t.kind == .word and j + 1 < toks.len and toks[j + 1].is("=") and j > i + 2) break;
        }
        try out.append(arena, .{ .key = key, .value = toks[i + 2 .. j] });
        i = j;
    }
    return out.items;
}

fn find(ps: []const Param, key: []const u8) ?[]const Tok {
    for (ps) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

/// The `tran` parameters mapped; any other is refused by name.
const tran_keys = std.StaticStringMap(void).initComptime(.{ .{"stop"}, .{"step"}, .{"start"}, .{"maxstep"}, .{"method"}, .{"skipdc"}, .{"errpreset"} });

/// Spectre `tran method=` as the `.options` that select it; `trapgear2` has
/// no ESPice equivalent and is refused.
const tran_methods = std.StaticStringMap([]const u8).initComptime(.{
    .{ "euler", "method=gear maxord=1" }, .{ "trap", "method=trap" },  .{ "traponly", "method=trap" },
    .{ "gear2", "method=gear" },          .{ "gear2only", "method=gear" },
});

/// A one-word value's text; "" for anything else, which no keyword matches.
fn word(v: []const Tok) []const u8 {
    return if (v.len == 1 and v[0].kind == .word) v[0].text else "";
}

/// Parameter names Spectre reserves (R11 p.361, R19 p.508).
const reserved = std.StaticStringMap(void).initComptime(.{ .{"temp"}, .{"tnom"}, .{"scale"}, .{"scalem"}, .{"freq"}, .{"time"} });

/// §4.3: the primitives and their SPICE letters.
const primitives = std.StaticStringMap(u8).initComptime(.{
    .{ "resistor", 'r' }, .{ "capacitor", 'c' }, .{ "inductor", 'l' },  .{ "vsource", 'v' },
    .{ "isource", 'i' },  .{ "vcvs", 'e' },      .{ "vccs", 'g' },      .{ "ccvs", 'h' },
    .{ "cccs", 'f' },     .{ "mutual_inductor", 'k' }, .{ "iprobe", 'v' }, .{ "bsource", 'b' },
    .{ "tline", 't' },
});

/// A model master's SPICE type (its letter, the type word for n/p, the
/// LEVEL) (dev/frontend.md, the model-master table).
const Master = struct { letter: u8, n: []const u8, p: []const u8, level: ?u16 = null };
const masters = std.StaticStringMap(Master).initComptime(.{
    .{ "resistor", Master{ .letter = 'r', .n = "r", .p = "r" } },
    .{ "capacitor", Master{ .letter = 'c', .n = "c", .p = "c" } },
    .{ "inductor", Master{ .letter = 'l', .n = "l", .p = "l" } },
    .{ "diode", Master{ .letter = 'd', .n = "d", .p = "d", .level = 1 } },
    .{ "bjt", Master{ .letter = 'q', .n = "npn", .p = "pnp", .level = 1 } },
    .{ "vbic", Master{ .letter = 'q', .n = "npn", .p = "pnp", .level = 4 } },
    .{ "hicum", Master{ .letter = 'q', .n = "npn", .p = "pnp", .level = 8 } },
    .{ "mos1", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 1 } },
    .{ "mos2", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 2 } },
    .{ "mos3", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 3 } },
    .{ "bsim3v3", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 8 } },
    .{ "bsim4", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 54 } },
    .{ "bsimsoi", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 10 } },
    .{ "hisim2", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 68 } },
    .{ "hisimhv", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 73 } },
    .{ "psp103", Master{ .letter = 'm', .n = "nmos", .p = "pmos", .level = 1040 } },
    .{ "jfet", Master{ .letter = 'j', .n = "njf", .p = "pjf", .level = 1 } },
});

/// §4.9 and §4.10: analysis and control type keywords after a name.
const analysis_kinds = std.StaticStringMap(void).initComptime(.{
    .{"acmatch"}, .{"ac"},    .{"dcmatch"}, .{"dc"},    .{"envlp"}, .{"hbac"},  .{"hbnoise"}, .{"hbsp"},
    .{"hbstb"},   .{"hbxf"},  .{"hb"},      .{"montecarlo"}, .{"noise"}, .{"pac"}, .{"pnoise"}, .{"psp"},
    .{"pss"},     .{"pstb"},  .{"pxf"},     .{"pz"},    .{"qpac"},  .{"qpnoise"}, .{"qpsp"},  .{"qpss"},
    .{"qpxf"},    .{"sp"},    .{"stb"},     .{"sweep"}, .{"tdr"},   .{"tran"},    .{"xf"},    .{"fourier"},
    .{"pdisto"},  .{"sens"},
});
/// What a control statement does here: `options` set options, the rest are
/// read and not acted on, or refused by name.
const ControlKind = enum { options, ignored, refused };
const control_kinds = std.StaticStringMap(ControlKind).initComptime(.{
    .{ "options", .options }, .{ "info", .ignored },     .{ "set", .ignored },  .{ "shell", .ignored },
    .{ "check", .ignored },   .{ "checklimit", .ignored }, .{ "assert", .ignored }, .{ "paramtest", .ignored },
    .{ "alter", .refused },   .{ "altergroup", .refused }, .{ "paramset", .refused },
});

const T = struct {
    arena: Allocator,
    kinds: *Kinds,
    out: std.ArrayList([]const u8) = .empty,
    /// Model names and their masters; subcircuit names (any depth).
    models: std.StringHashMapUnmanaged([]const u8) = .empty,
    subckts: std.ArrayList(Open) = .empty,
    subckt_names: std.StringHashMapUnmanaged(void) = .empty,
    /// `ahdl_include` was given: an unknown master is a Verilog-A module.
    ahdl: bool = false,
    ahdl_models: std.StringHashMapUnmanaged(void) = .empty,
    /// Open braces: `if` branches, a `statistics` block, a model group, a
    /// function body.
    blocks: std.ArrayList(Block) = .empty,

    /// A subcircuit whose `.subckt` card waits for its body's
    /// `parameters`: the card's index, its name and ports, its defaults.
    const Open = struct { card: usize, head: []const u8, defaults: std.ArrayList(u8) = .empty };
    const Block = union(enum) { cond, skip, group: struct { name: []const u8, master: []const u8, kv: []const Param }, func };

    fn emit(t: *T, comptime fmt: []const u8, args: anytype) Error!void {
        try t.out.append(t.arena, try std.fmt.allocPrint(t.arena, fmt, args));
    }

    fn device(t: *T, letter: u8, comptime fmt: []const u8, args: anytype) Error!void {
        const card = try std.fmt.allocPrint(t.arena, fmt, args);
        try t.out.append(t.arena, card);
        try t.kinds.put(t.arena, @intFromPtr(card.ptr), letter);
    }

    /// Pass 1: model, subcircuit and module names, which instances before
    /// their definitions may name (§6.4).
    fn declare(t: *T, in: []const []const u8) Error!void {
        var spice = false;
        for (in) |line| {
            if (spice) {
                if (switchesTo(line, "spectre")) spice = false;
                continue;
            }
            if (switchesTo(line, "spice")) {
                spice = true;
                continue;
            }
            const toks = tokenize(t.arena, line) catch continue;
            if (toks.len < 2 or toks[0].kind != .word) continue;
            const head = toks[0].text;
            if (std.mem.eql(u8, head, "model") and toks.len >= 3) try t.models.put(t.arena, toks[1].text, toks[2].text);
            if (std.mem.eql(u8, head, "subckt")) try t.subckt_names.put(t.arena, toks[1].text, {});
            if (std.mem.eql(u8, head, "inline") and toks.len >= 3) try t.subckt_names.put(t.arena, toks[2].text, {});
            if (std.mem.eql(u8, head, "ahdl_include")) t.ahdl = true;
        }
    }

    fn statement(t: *T, line: []const u8) Error!void {
        const toks = try tokenize(t.arena, line);
        if (toks.len == 0) return;
        if (t.blocks.items.len > 0) switch (t.blocks.items[t.blocks.items.len - 1]) {
            .skip => return t.skipped(toks),
            .group => return t.groupRow(toks),
            .func => return t.funcBody(toks),
            .cond => {},
        };
        const head = toks[0];
        if (head.is("}")) return t.closeBrace(toks);
        if (head.kind != .word) return error.ParseError;
        const w = head.text;
        const rest = toks[1..];
        if (std.mem.eql(u8, w, "simulator")) return; // `insensitive=yes` and the like
        if (std.mem.eql(u8, w, "parameters")) return t.parameters(rest);
        if (std.mem.eql(u8, w, "model")) return t.model(rest);
        if (std.mem.eql(u8, w, "subckt")) return t.subckt(rest);
        if (std.mem.eql(u8, w, "inline") and rest.len > 0 and rest[0].is("subckt")) return t.subckt(rest[1..]);
        if (std.mem.eql(u8, w, "ends")) return t.ends();
        if (std.mem.eql(u8, w, "global")) return t.global(rest);
        if (std.mem.eql(u8, w, "ic") or std.mem.eql(u8, w, "nodeset")) return t.initial(w, rest);
        if (std.mem.eql(u8, w, "save")) return saveChecked(rest);
        if (std.mem.eql(u8, w, "ahdl_include")) {
            if (rest.len != 1 or rest[0].kind != .string) return error.ParseError;
            return t.emit(".hdl {s}", .{rest[0].text});
        }
        if (std.mem.eql(u8, w, "if")) return t.cond(rest, ".if");
        if (std.mem.eql(u8, w, "real")) return t.func(rest);
        if (std.mem.eql(u8, w, "statistics")) {
            std.log.warn("spectre: statistics blocks are read and set aside (no Monte Carlo variations)", .{});
            return t.blocks.append(t.arena, .skip);
        }
        if (std.mem.eql(u8, w, "include") or std.mem.eql(u8, w, "library") or std.mem.eql(u8, w, "section"))
            return error.UnsupportedCard;
        return t.named(toks);
    }

    /// `parameters a=1 b`: global `.param`, or a subcircuit's defaults
    /// (one with no value has none, §4.6).
    fn parameters(t: *T, toks: []const Tok) Error!void {
        var text: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < toks.len) {
            if (toks[i].kind != .word) return error.ParseError;
            const key = toks[i].text;
            if (reserved.has(key)) return error.UnsupportedCard;
            if (i + 1 < toks.len and toks[i + 1].is("=")) {
                var j = i + 2;
                var depth: usize = 0;
                while (j < toks.len) : (j += 1) {
                    if (toks[j].is("(") or toks[j].is("[")) depth += 1;
                    if (toks[j].is(")") or toks[j].is("]")) depth -|= 1;
                    // The next declaration: a key with `=`, or a bare key
                    // (no default) after a complete value.
                    const after_value = toks[j - 1].kind == .word or toks[j - 1].kind == .string or toks[j - 1].is(")") or toks[j - 1].is("]");
                    if (depth == 0 and toks[j].kind == .word and j > i + 2 and
                        ((j + 1 < toks.len and toks[j + 1].is("=")) or (after_value and (j + 1 == toks.len or toks[j + 1].kind == .word)))) break;
                }
                try text.print(t.arena, " {s}={s}", .{ key, try value(t.arena, toks[i + 2 .. j]) });
                i = j;
            } else i += 1;
        }
        if (t.subckts.items.len > 0) {
            const o = &t.subckts.items[t.subckts.items.len - 1];
            try o.defaults.appendSlice(t.arena, text.items);
        } else if (text.items.len > 0) try t.emit(".param{s}", .{text.items});
    }

    /// `model name master params`, or a model group (`{` rows `}`).
    fn model(t: *T, toks: []const Tok) Error!void {
        if (toks.len < 2 or toks[0].kind != .word or toks[1].kind != .word) return error.ParseError;
        const name = toks[0].text;
        const master = toks[1].text;
        var tail = toks[2..];
        const group = tail.len > 0 and tail[tail.len - 1].is("{");
        if (group) tail = tail[0 .. tail.len - 1];
        const ps = try params(t.arena, tail);
        if (group) return t.blocks.append(t.arena, .{ .group = .{ .name = name, .master = master, .kv = ps } });
        try t.modelCard(name, master, ps, &.{});
    }

    fn modelCard(t: *T, name: []const u8, master: []const u8, ps: []const Param, more: []const Param) Error!void {
        const m = masters.get(master) orelse return error.UnsupportedCard;
        const ty = find(ps, "type") orelse find(more, "type");
        const p = if (ty) |v| v.len == 1 and (std.mem.eql(u8, v[0].text, "p") or std.mem.eql(u8, v[0].text, "pnp")) else false;
        var text: std.ArrayList(u8) = .empty;
        try text.print(t.arena, ".model {s} {s}", .{ name, if (p) m.p else m.n });
        if (m.level) |lv| try text.print(t.arena, " level={d}", .{lv});
        for ([_][]const Param{ ps, more }) |list| for (list) |kv| {
            if (std.mem.eql(u8, kv.key, "type")) continue;
            try text.print(t.arena, " {s}={s}", .{ kv.key, try value(t.arena, kv.value) });
        };
        try t.out.append(t.arena, text.items);
    }

    /// A model group's `label: params` row, or its closing `}`.
    fn groupRow(t: *T, toks: []const Tok) Error!void {
        const g = t.blocks.items[t.blocks.items.len - 1].group;
        if (toks[0].is("}")) {
            _ = t.blocks.pop();
            return;
        }
        if (toks.len < 2 or toks[0].kind != .word or !toks[1].is(":")) return error.ParseError;
        const bin = try std.fmt.allocPrint(t.arena, "{s}.{s}", .{ g.name, toks[0].text });
        try t.modelCard(bin, g.master, g.kv, try params(t.arena, toks[2..]));
    }

    fn subckt(t: *T, toks: []const Tok) Error!void {
        if (toks.len == 0 or toks[0].kind != .word) return error.ParseError;
        var head: std.ArrayList(u8) = .empty;
        try head.print(t.arena, ".subckt {s}", .{toks[0].text});
        var ports = toks[1..];
        // `(ports)` or bare ports (§4.5); an open parenthesis must close.
        if (ports.len > 0 and ports[0].is("(")) {
            if (!ports[ports.len - 1].is(")")) return error.ParseError;
            ports = ports[1 .. ports.len - 1];
        }
        for (ports) |tok| {
            if (tok.kind != .word) return error.ParseError;
            try head.print(t.arena, " {s}", .{tok.text});
        }
        try t.out.append(t.arena, "");
        try t.subckts.append(t.arena, .{ .card = t.out.items.len - 1, .head = head.items });
    }

    fn ends(t: *T) Error!void {
        const o = t.subckts.pop() orelse return error.ParseError;
        t.out.items[o.card] = try std.mem.concat(t.arena, u8, &.{ o.head, o.defaults.items });
        try t.emit(".ends", .{});
    }

    /// `global g n...`: the first name is ground (§4.8).
    fn global(t: *T, toks: []const Tok) Error!void {
        if (toks.len == 0 or toks[0].kind != .word) return error.ParseError;
        const g = toks[0].text;
        if (!std.mem.eql(u8, g, "0")) try t.emit(".connect 0 {s}", .{g});
        if (toks.len == 1) return;
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(t.arena, ".global");
        for (toks[1..]) |tok| {
            if (tok.kind != .word) return error.ParseError;
            try text.print(t.arena, " {s}", .{tok.text});
        }
        try t.out.append(t.arena, text.items);
    }

    /// `ic n=v ...` / `nodeset n=v ...` on nodes; an `inst:terminal` signal
    /// is refused.
    fn initial(t: *T, card: []const u8, toks: []const Tok) Error!void {
        var text: std.ArrayList(u8) = .empty;
        try text.print(t.arena, ".{s}", .{card});
        for (try params(t.arena, toks)) |p| {
            if (std.mem.indexOfScalar(u8, p.key, ':') != null) return error.UnsupportedCard;
            try text.print(t.arena, " v({s})={s}", .{ p.key, try value(t.arena, p.value) });
        }
        try t.out.append(t.arena, text.items);
    }

    /// `if (cond) {`, `if (cond) stmt`, and `} else ...` (§4.12).
    fn cond(t: *T, toks: []const Tok, card: []const u8) Error!void {
        if (toks.len == 0 or !toks[0].is("(")) return error.ParseError;
        var depth: usize = 0;
        var close: usize = 0;
        for (toks, 0..) |tok, i| {
            if (tok.is("(")) depth += 1;
            if (tok.is(")")) {
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            }
        } else return error.ParseError;
        try t.emit("{s} ({s})", .{ card, try expression(t.arena, toks[1..close]) });
        const tail = toks[close + 1 ..];
        if (tail.len == 1 and tail[0].is("{")) return t.blocks.append(t.arena, .cond);
        if (tail.len == 0) return error.ParseError;
        // One statement, no braces, maybe `else stmt` after it; a nested
        // `if` takes the `else` itself (it binds to the closest, R19 p.491).
        const split = if (tail[0].is("if")) tail.len else for (tail, 0..) |tok, i| {
            if (tok.is("else")) break i;
        } else tail.len;
        if (split == 0) return error.ParseError;
        try t.namedOrStatement(tail[0..split]);
        if (split < tail.len) {
            if (split + 1 == tail.len) return error.ParseError;
            try t.emit(".else", .{});
            try t.namedOrStatement(tail[split + 1 ..]);
        }
        try t.emit(".endif", .{});
    }

    fn namedOrStatement(t: *T, toks: []const Tok) Error!void {
        if (toks[0].kind == .word and std.mem.eql(u8, toks[0].text, "if")) return t.cond(toks[1..], ".if");
        return t.named(toks);
    }

    /// `}` closing a block: a branch, maybe followed by `else`.
    fn closeBrace(t: *T, toks: []const Tok) Error!void {
        const b = t.blocks.pop() orelse return error.ParseError;
        assert(b == .cond);
        if (toks.len == 1) return t.emit(".endif", .{});
        if (!toks[1].is("else")) return error.ParseError;
        const tail = toks[2..];
        if (tail.len >= 1 and tail[0].is("if")) {
            // `} else if (c) {`: one chain.
            try t.cond(tail[1..], ".elseif");
            return;
        }
        if (tail.len == 1 and tail[0].is("{")) {
            try t.emit(".else", .{});
            return t.blocks.append(t.arena, .cond);
        }
        return error.ParseError;
    }

    fn skipped(t: *T, toks: []const Tok) Error!void {
        var depth: isize = 0;
        for (toks) |tok| {
            if (tok.is("{")) depth += 1;
            if (tok.is("}")) depth -= 1;
        }
        // A nested block opens on its own line; the block's `}` closes it.
        if (depth > 0) return t.blocks.append(t.arena, .skip);
        if (depth < 0) _ = t.blocks.pop();
    }

    /// `real f(real a, real b) {` with its `return e` and `}` lines.
    fn func(t: *T, toks: []const Tok) Error!void {
        if (toks.len < 3 or toks[0].kind != .word or !toks[1].is("(")) return error.ParseError;
        var text: std.ArrayList(u8) = .empty;
        try text.print(t.arena, ".func {s}(", .{toks[0].text});
        var i: usize = 2;
        var first = true;
        // `real a, real b`: every argument is typed `real` (§4.7).
        while (i < toks.len and !toks[i].is(")")) {
            if (!first) {
                if (!toks[i].is(",")) return error.ParseError;
                i += 1;
            }
            if (i + 1 >= toks.len or !toks[i].is("real") or toks[i + 1].kind != .word) return error.ParseError;
            if (!first) try text.append(t.arena, ',');
            first = false;
            try text.appendSlice(t.arena, toks[i + 1].text);
            i += 2;
        }
        try text.append(t.arena, ')');
        const tail = if (i + 1 < toks.len) toks[i + 1 ..] else return error.ParseError;
        if (!tail[0].is("{")) return error.ParseError;
        // `{ return e }` on one line, or the body on the lines after.
        if (tail.len > 1) {
            const body = tail[1..];
            if (!body[0].is("return") or !body[body.len - 1].is("}")) return error.ParseError;
            var end = body.len - 1;
            if (end > 1 and body[end - 1].is(";")) end -= 1;
            try text.print(t.arena, " {s}", .{try expression(t.arena, body[1..end])});
            return t.out.append(t.arena, text.items);
        }
        try t.out.append(t.arena, text.items);
        try t.blocks.append(t.arena, .func);
    }

    fn funcBody(t: *T, toks: []const Tok) Error!void {
        if (toks[0].is("}")) {
            _ = t.blocks.pop();
            return;
        }
        if (!toks[0].is("return")) return error.ParseError;
        var end = toks.len;
        if (end > 1 and toks[end - 1].is(";")) end -= 1;
        const last = &t.out.items[t.out.items.len - 1];
        last.* = try std.fmt.allocPrint(t.arena, "{s} {s}", .{ last.*, try expression(t.arena, toks[1..end]) });
    }

    /// A statement led by a name: an analysis, a control statement or an
    /// instance (§4.1).
    fn named(t: *T, toks: []const Tok) Error!void {
        if (toks[0].kind != .word) return error.ParseError;
        const name = toks[0].text;
        var i: usize = 1;
        var nodes: std.ArrayList([]const u8) = .empty;
        var paren = false;
        if (i < toks.len and toks[i].is("(")) {
            paren = true;
            i += 1;
            while (i < toks.len and !toks[i].is(")")) : (i += 1) {
                if (toks[i].kind != .word) return error.ParseError;
                try nodes.append(t.arena, toks[i].text);
            }
            if (i == toks.len) return error.ParseError;
            i += 1;
        }
        if (i < toks.len and toks[i].kind == .word and !(i + 1 < toks.len and toks[i + 1].is("="))) {
            const kw = toks[i].text;
            if (analysis_kinds.has(kw)) return t.analysis(name, kw, nodes.items, toks[i + 1 ..]);
            if (!paren) if (control_kinds.get(kw)) |c| return t.control(c, toks[i + 1 ..]);
        }
        // An instance: without parentheses, the master is the last bare word
        // before the first `key=` (§4.2).
        if (!paren) {
            while (i < toks.len and toks[i].kind == .word and !(i + 1 < toks.len and toks[i + 1].is("="))) : (i += 1)
                try nodes.append(t.arena, toks[i].text);
            const master = nodes.pop() orelse return error.ParseError;
            return t.instance(name, nodes.items, master, try params(t.arena, toks[i..]));
        }
        if (i >= toks.len or toks[i].kind != .word) return error.ParseError;
        return t.instance(name, nodes.items, toks[i].text, try params(t.arena, toks[i + 1 ..]));
    }

    fn instance(t: *T, name: []const u8, nodes: []const []const u8, master: []const u8, ps: []const Param) Error!void {
        const pins = try std.mem.join(t.arena, " ", nodes);
        if (primitives.get(master)) |letter| return t.primitive(letter, master, name, pins, ps);
        var kv: std.ArrayList(u8) = .empty;
        for (ps) |p| try kv.print(t.arena, " {s}={s}", .{ p.key, try value(t.arena, p.value) });
        if (t.subckt_names.contains(master)) return t.device('x', "{s} {s} {s}{s}", .{ name, pins, master, kv.items });
        if (t.models.get(master)) |mm| {
            const m = masters.get(mm) orelse return error.UnsupportedCard;
            return t.device(m.letter, "{s} {s} {s}{s}", .{ name, pins, master, kv.items });
        }
        // A model group's members are `master.label`; the instance names
        // the group, which bins.
        if (t.ahdl) {
            const gop = try t.ahdl_models.getOrPut(t.arena, master);
            if (!gop.found_existing) try t.emit(".model {s} {s}", .{ master, master });
            return t.device('n', "{s} {s} {s}{s}", .{ name, pins, master, kv.items });
        }
        return error.UnsupportedCard;
    }

    /// A primitive's card (dev/frontend.md, the primitive list).
    fn primitive(t: *T, letter: u8, master: []const u8, name: []const u8, pins: []const u8, ps: []const Param) Error!void {
        var pos: std.ArrayList(u8) = .empty;
        var kv: std.ArrayList(u8) = .empty;
        const lead: []const []const u8 = switch (letter) {
            'r' => &.{"r"},
            'c' => &.{"c"},
            'l' => &.{"l"},
            'e' => &.{"gain"},
            'g' => &.{"gm"},
            'h' => &.{ "probe", "rm" },
            'f' => &.{ "probe", "gain" },
            'k' => &.{ "ind1", "ind2", "coupling" },
            else => &.{},
        };
        for (lead) |key| if (find(ps, key)) |v| try pos.print(t.arena, " {s}", .{try value(t.arena, v)});
        var source = false;
        if (letter == 'v' or letter == 'i') {
            source = true;
            if (std.mem.eql(u8, master, "iprobe")) try pos.appendSlice(t.arena, " dc 0");
            try t.waveform(&pos, ps);
        }
        for (ps) |p| {
            const used = for (lead) |key| {
                if (std.mem.eql(u8, key, p.key)) break true;
            } else source and isWaveKey(p.key);
            if (used) continue;
            try kv.print(t.arena, " {s}={s}", .{ p.key, try value(t.arena, p.value) });
        }
        const sep: []const u8 = if (pins.len > 0) " " else "";
        try t.device(letter, "{s}{s}{s}{s}{s}", .{ name, sep, pins, pos.items, kv.items });
    }

    fn isWaveKey(key: []const u8) bool {
        const keys = [_][]const u8{ "dc", "mag", "phase", "type", "val0", "val1", "period", "rise", "fall", "width", "delay", "sinedc", "ampl", "freq", "sinephase", "damp", "td1", "tau1", "td2", "tau2", "wave" };
        for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    /// `dc`, `mag`/`phase` and `type=` waveforms as SPICE source values.
    fn waveform(t: *T, pos: *std.ArrayList(u8), ps: []const Param) Error!void {
        if (find(ps, "dc")) |v| try pos.print(t.arena, " dc {s}", .{try value(t.arena, v)});
        if (find(ps, "mag")) |v| {
            try pos.print(t.arena, " ac {s}", .{try value(t.arena, v)});
            if (find(ps, "phase")) |ph| try pos.print(t.arena, " {s}", .{try value(t.arena, ph)});
        }
        const ty = find(ps, "type") orelse return;
        if (ty.len != 1) return error.ParseError;
        const kind = ty[0].text;
        const fields: []const []const u8, const fname: []const u8 = if (std.mem.eql(u8, kind, "pulse"))
            .{ &.{ "val0", "val1", "delay", "rise", "fall", "width", "period" }, "pulse" }
        else if (std.mem.eql(u8, kind, "sine"))
            .{ &.{ "sinedc", "ampl", "freq", "delay", "damp", "sinephase" }, "sin" }
        else if (std.mem.eql(u8, kind, "exp"))
            .{ &.{ "val0", "val1", "td1", "tau1", "td2", "tau2" }, "exp" }
        else if (std.mem.eql(u8, kind, "pwl")) {
            const wave = find(ps, "wave") orelse return error.UnsupportedCard;
            if (wave.len < 2 or !wave[0].is("[") or !wave[wave.len - 1].is("]")) return error.ParseError;
            try pos.print(t.arena, " pwl(", .{});
            var first = true;
            for (try vector(t.arena, wave)) |v| {
                if (!first) try pos.append(t.arena, ' ');
                first = false;
                try pos.appendSlice(t.arena, v);
            }
            try pos.append(t.arena, ')');
            return;
        } else if (std.mem.eql(u8, kind, "dc"))
            return
        else
            return error.UnsupportedCard;
        // Trailing fields not given are left off; a gap reads as 0.
        var last: usize = 0;
        for (fields, 0..) |f, k| if (find(ps, f) != null) {
            last = k + 1;
        };
        try pos.print(t.arena, " {s}(", .{fname});
        for (fields[0..last], 0..) |f, k| {
            if (k > 0) try pos.append(t.arena, ' ');
            try pos.appendSlice(t.arena, if (find(ps, f)) |v| try value(t.arena, v) else "0");
        }
        try pos.append(t.arena, ')');
    }

    fn analysis(t: *T, name: []const u8, kind: []const u8, nodes: []const []const u8, toks: []const Tok) Error!void {
        _ = name;
        if (t.subckts.items.len > 0) return error.UnsupportedCard;
        var body = toks;
        if (body.len > 0 and body[body.len - 1].is("{")) return error.UnsupportedCard; // child analyses
        const ps = try params(t.arena, body);
        body = &.{};
        const num = struct {
            fn of(arena: Allocator, list: []const Param, key: []const u8) Error!?[]const u8 {
                const v = find(list, key) orelse return null;
                return try value(arena, v);
            }
        }.of;
        if (std.mem.eql(u8, kind, "tran")) {
            for (ps) |p| if (!tran_keys.has(p.key)) {
                if (!@import("builtin").is_test) std.log.err("spectre: tran parameter `{s}` is not supported", .{p.key});
                return error.UnsupportedCard;
            };
            const stop = try num(t.arena, ps, "stop") orelse return error.ParseError;
            const step = try num(t.arena, ps, "step") orelse try std.fmt.allocPrint(t.arena, "\"({s}/50)\"", .{std.mem.trim(u8, stop, "\"")});
            const start = try num(t.arena, ps, "start");
            const maxstep = try num(t.arena, ps, "maxstep");
            // ponytail: `method` becomes the deck's `.options method`, so a
            // second tran with another method sets both. Per-card methods
            // when a deck needs two.
            if (find(ps, "method")) |m| try t.emit(".options {s}", .{tran_methods.get(word(m)) orelse return error.UnsupportedCard});
            // `moderate` is Spectre's default; the other presets retune
            // reltol and the LTE together, which is not mapped.
            if (find(ps, "errpreset")) |e| if (!std.mem.eql(u8, word(e), "moderate")) return error.UnsupportedCard;
            // `skipdc=yes` starts from the `ic` statements, as `uic` does.
            const uic = if (find(ps, "skipdc")) |d|
                (if (std.mem.eql(u8, word(d), "yes")) " uic" else if (std.mem.eql(u8, word(d), "no")) "" else return error.UnsupportedCard)
            else
                "";
            if (maxstep) |m| return t.emit(".tran {s} {s} {s} {s}{s}", .{ step, stop, start orelse "0", m, uic });
            if (start) |s| return t.emit(".tran {s} {s} {s}{s}", .{ step, stop, s, uic });
            return t.emit(".tran {s} {s}{s}", .{ step, stop, uic });
        }
        if (std.mem.eql(u8, kind, "dc")) {
            const target = if (find(ps, "dev")) |d| d[0].text else if (find(ps, "param")) |p| p[0].text else {
                if (ps.len != 0) return error.UnsupportedCard;
                return t.emit(".op", .{});
            };
            if (find(ps, "dev") != null) if (find(ps, "param")) |p| if (!std.mem.eql(u8, p[0].text, "dc")) return error.UnsupportedCard;
            return t.emit(".dc {s} {s}", .{ target, try t.sweep(ps, false) });
        }
        if (std.mem.eql(u8, kind, "ac")) return t.emit(".ac {s}", .{try t.sweep(ps, true)});
        if (std.mem.eql(u8, kind, "noise")) {
            const src = find(ps, "iprobe") orelse return error.UnsupportedCard;
            const out = switch (nodes.len) {
                1 => try std.fmt.allocPrint(t.arena, "v({s})", .{nodes[0]}),
                2 => try std.fmt.allocPrint(t.arena, "v({s},{s})", .{ nodes[0], nodes[1] }),
                else => return error.UnsupportedCard,
            };
            return t.emit(".noise {s} {s} {s}", .{ out, src[0].text, try t.sweep(ps, true) });
        }
        return error.UnsupportedCard;
    }

    /// A sweep's SPICE grid: `dec N a b`, `lin N a b`, `poi n v...` (`freq`
    /// set when `ac`); for `.dc`, `a b step` or `poi`.
    fn sweep(t: *T, ps: []const Param, ac: bool) Error![]const u8 {
        if (find(ps, "values")) |v| {
            const vals = try vector(t.arena, v);
            return std.fmt.allocPrint(t.arena, "poi {d} {s}", .{ vals.len, try std.mem.join(t.arena, " ", vals) });
        }
        const start = try value(t.arena, find(ps, "start") orelse return error.UnsupportedCard);
        const stop = try value(t.arena, find(ps, "stop") orelse return error.UnsupportedCard);
        if (find(ps, "dec")) |n| return std.fmt.allocPrint(t.arena, "dec {s} {s} {s}", .{ try value(t.arena, n), start, stop });
        if (find(ps, "lin")) |n| {
            if (ac) return std.fmt.allocPrint(t.arena, "lin {s} {s} {s}", .{ try value(t.arena, n), start, stop });
            const q = "\"";
            return std.fmt.allocPrint(t.arena, "{s} {s} \"(({s}-{s})/{s})\"", .{ start, stop, std.mem.trim(u8, stop, q), std.mem.trim(u8, start, q), std.mem.trim(u8, try value(t.arena, n), q) });
        }
        if (find(ps, "step")) |s| {
            if (ac) return error.UnsupportedCard;
            return std.fmt.allocPrint(t.arena, "{s} {s} {s}", .{ start, stop, try value(t.arena, s) });
        }
        return error.UnsupportedCard;
    }

    fn control(t: *T, c: ControlKind, toks: []const Tok) Error!void {
        switch (c) {
            .refused => return error.UnsupportedCard,
            .ignored => return,
            .options => {
                var text: std.ArrayList(u8) = .empty;
                for (try params(t.arena, toks)) |p| {
                    const v = try value(t.arena, p.value);
                    if (std.mem.eql(u8, p.key, "temp")) {
                        try t.emit(".temp {s}", .{v});
                        continue;
                    }
                    const key = if (std.mem.eql(u8, p.key, "vabstol")) "vntol" else if (std.mem.eql(u8, p.key, "iabstol")) "abstol" else p.key;
                    try text.print(t.arena, " {s}={s}", .{ key, v });
                }
                if (text.items.len > 0) try t.emit(".options{s}", .{text.items});
            },
        }
    }
};

/// `save X[:t] ... [key=value]` (§4.11): checked, and not acted on, since
/// every vector is written. A `:` needs a terminal or output after it.
fn saveChecked(toks: []const Tok) Error!void {
    for (toks, 0..) |tok, i| if (tok.is(":")) {
        if (i + 1 == toks.len or toks[i + 1].kind != .word) return error.ParseError;
    };
}

/// A parameter's value as SPICE text: a name, a plain number, or an
/// expression in quotes, which every card field reads as one (a bare `(`
/// would start a group).
fn value(arena: Allocator, toks: []const Tok) Error![]const u8 {
    if (toks.len == 1 and toks[0].kind == .word and !std.ascii.isDigit(toks[0].text[0]) and toks[0].text[0] != '.' and
        constants.get(toks[0].text) == null and !std.mem.eql(u8, toks[0].text, "temp")) return toks[0].text;
    if (toks.len > 0 and toks[0].is("[")) return error.UnsupportedCard; // a vector where one is not read
    return quoted(arena, try expression(arena, toks));
}

/// `text` as one card field: as is when it is a number, a name or a
/// string, in quotes when it is an expression.
fn quoted(arena: Allocator, text: []const u8) Error![]const u8 {
    if (text[0] == '"' or std.mem.indexOfAny(u8, text, "()+*/%?:<>=!&|") == null and !std.mem.startsWith(u8, text, "-")) return text;
    return std.fmt.allocPrint(arena, "\"{s}\"", .{text});
}

/// A vector's elements as SPICE text (§5).
fn vector(arena: Allocator, toks: []const Tok) Error![]const []const u8 {
    if (toks.len < 2 or !toks[0].is("[") or !toks[toks.len - 1].is("]")) return error.ParseError;
    var out: std.ArrayList([]const u8) = .empty;
    const inner = toks[1 .. toks.len - 1];
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i].is(",")) {
            i += 1;
            continue;
        }
        // An element: a signed constant or name, or a parenthesized expression.
        var j = i + 1;
        if (inner[i].kind == .op and j < inner.len) j += 1;
        if (inner[i].is("(")) {
            var depth: usize = 0;
            j = i;
            while (j < inner.len) : (j += 1) {
                if (inner[j].is("(")) depth += 1;
                if (inner[j].is(")")) {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            j += 1;
        }
        try out.append(arena, try quoted(arena, try expression(arena, inner[i..j])));
        i = j;
    }
    return out.items;
}

const testing = std.testing;

test "expressions keep Spectre's tree (§6.1)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "-2**2", "((-2e0)**2e0)" },
        .{ "2**3**2", "(2e0**(3e0**2e0))" },
        .{ "a<b==c", "((a<b)==c)" },
        .{ "1+2*3", "(1e0+(2e0*3e0))" },
        .{ "c?1k:2M", "(c?1e3:2e6)" },
        .{ "fmod(7,3)", "(7e0%3e0)" },
        .{ "temp+M_PI", "(temper+3.141592653589793e0)" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try expression(a, try tokenize(a, c[0])));
    try testing.expectError(error.UnsupportedCard, expression(a, try tokenize(a, "a&b")));
}
