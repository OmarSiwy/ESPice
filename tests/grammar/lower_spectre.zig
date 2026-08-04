//! A Spectre statement tree (spectre.peg) -> SPICE cards and each device
//! card's letter: the oracle's own reading of dev/frontend.md "Spectre
//! dialect", from the tree, not from src/frontend/spectre.zig. The cards then
//! take the SPICE oracle's path (spice_cards.peg + hspice.peg, lower.zig).
const std = @import("std");
const Allocator = std.mem.Allocator;
const peg = @import("peg.zig");

/// The oracle's SPICE text and each device card's letter, by the card's
/// offset in the text.
pub const Translated = struct {
    text: []const u8,
    kinds: std.AutoHashMapUnmanaged(u32, u8),
};

/// A construct the mapping refuses (an unsupported analysis, an `include`).
pub const Error = error{ OutOfMemory, Refused };

pub fn translate(arena: Allocator, g: peg.Grammar, t: peg.Tree) Error!Translated {
    var x: X = .{ .arena = arena, .g = g, .t = t };
    inline for (@typeInfo(@TypeOf(x.r)).@"struct".field_names) |f| @field(x.r, f) = g.rule(comptime capital(f));
    var roots = t.children(null);
    const deck = roots.next() orelse return .{ .text = "", .kinds = .empty };
    try x.declare(deck);
    try x.lines(deck);
    return .{ .text = x.out.items, .kinds = x.kinds };
}

fn capital(comptime f: []const u8) []const u8 {
    comptime var buf: [f.len]u8 = undefined;
    @memcpy(&buf, f);
    buf[0] = std.ascii.toUpper(buf[0]);
    const final = buf;
    return &final;
}

/// dev/frontend.md's model-master table.
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

/// dev/frontend.md's primitives, their letters and lead (positional) values.
const Prim = struct { letter: u8, lead: []const []const u8 };
const primitives = std.StaticStringMap(Prim).initComptime(.{
    .{ "resistor", Prim{ .letter = 'r', .lead = &.{"r"} } },
    .{ "capacitor", Prim{ .letter = 'c', .lead = &.{"c"} } },
    .{ "inductor", Prim{ .letter = 'l', .lead = &.{"l"} } },
    .{ "vsource", Prim{ .letter = 'v', .lead = &.{} } },
    .{ "isource", Prim{ .letter = 'i', .lead = &.{} } },
    .{ "iprobe", Prim{ .letter = 'v', .lead = &.{} } },
    .{ "vcvs", Prim{ .letter = 'e', .lead = &.{"gain"} } },
    .{ "vccs", Prim{ .letter = 'g', .lead = &.{"gm"} } },
    .{ "ccvs", Prim{ .letter = 'h', .lead = &.{ "probe", "rm" } } },
    .{ "cccs", Prim{ .letter = 'f', .lead = &.{ "probe", "gain" } } },
    .{ "mutual_inductor", Prim{ .letter = 'k', .lead = &.{ "ind1", "ind2", "coupling" } } },
    .{ "bsource", Prim{ .letter = 'b', .lead = &.{} } },
    .{ "tline", Prim{ .letter = 't', .lead = &.{} } },
});

/// The source keys the waveform takes.
const wave_keys = [_][]const u8{ "dc", "mag", "phase", "type", "val0", "val1", "period", "rise", "fall", "width", "delay", "sinedc", "ampl", "freq", "sinephase", "damp", "td1", "tau1", "td2", "tau2", "wave" };

/// §6.3's constants.
const constants = std.StaticStringMap(f64).initComptime(.{
    .{ "M_E", std.math.e },              .{ "M_LOG2E", std.math.log2e },        .{ "M_LOG10E", std.math.log10e },
    .{ "M_LN2", std.math.ln2 },          .{ "M_LN10", std.math.ln10 },          .{ "M_PI", std.math.pi },
    .{ "M_TWO_PI", 2.0 * std.math.pi },  .{ "M_PI_2", std.math.pi / 2.0 },      .{ "M_PI_4", std.math.pi / 4.0 },
    .{ "M_1_PI", 1.0 / std.math.pi },    .{ "M_2_PI", 2.0 / std.math.pi },      .{ "M_2_SQRTPI", std.math.two_sqrtpi },
    .{ "M_SQRT2", std.math.sqrt2 },      .{ "M_SQRT1_2", std.math.sqrt1_2 },    .{ "M_DEGPERRAD", 180.0 / std.math.pi },
    .{ "P_Q", 1.6021918e-19 },           .{ "P_C", 2.997924562e8 },             .{ "P_K", 1.3806226e-23 },
    .{ "P_H", 6.6260755e-34 },           .{ "P_EPS0", 8.85418792394420013968e-12 }, .{ "P_U0", 4.0e-7 * std.math.pi },
    .{ "P_CELSIUS0", 273.15 },
});

/// A parameter: its key and its value's row.
const KeyValue = struct { key: []const u8, value: u32 };

const X = struct {
    arena: Allocator,
    g: peg.Grammar,
    t: peg.Tree,
    out: std.ArrayList(u8) = .empty,
    kinds: std.AutoHashMapUnmanaged(u32, u8) = .empty,
    models: std.StringHashMapUnmanaged([]const u8) = .empty,
    subckts: std.StringHashMapUnmanaged(void) = .empty,
    ahdl: bool = false,
    ahdl_models: std.StringHashMapUnmanaged(void) = .empty,
    r: struct {
        simulator: peg.RuleId,
        spiceRegion: peg.RuleId,
        spiceCard: peg.RuleId,
        include: peg.RuleId,
        ahdlInclude: peg.RuleId,
        library: peg.RuleId,
        section: peg.RuleId,
        global: peg.RuleId,
        parameters: peg.RuleId,
        paramDecl: peg.RuleId,
        model: peg.RuleId,
        group: peg.RuleId,
        subckt: peg.RuleId,
        ends: peg.RuleId,
        function: peg.RuleId,
        fArg: peg.RuleId,
        save: peg.RuleId,
        ic: peg.RuleId,
        nodeset: peg.RuleId,
        signal: peg.RuleId,
        @"if": peg.RuleId,
        @"else": peg.RuleId,
        statistics: peg.RuleId,
        analysis: peg.RuleId,
        control: peg.RuleId,
        instance: peg.RuleId,
        name: peg.RuleId,
        node: peg.RuleId,
        master: peg.RuleId,
        kind: peg.RuleId,
        kind2: peg.RuleId,
        param: peg.RuleId,
        key: peg.RuleId,
        vector: peg.RuleId,
        expr: peg.RuleId,
        ternary: peg.RuleId,
        @"or": peg.RuleId,
        @"and": peg.RuleId,
        eq: peg.RuleId,
        rel: peg.RuleId,
        add: peg.RuleId,
        mul: peg.RuleId,
        pow: peg.RuleId,
        unary: peg.RuleId,
        unary2: peg.RuleId,
        paren: peg.RuleId,
        call: peg.RuleId,
        ref: peg.RuleId,
        num: peg.RuleId,
        mantissa: peg.RuleId,
        exponent: peg.RuleId,
        scale: peg.RuleId,
        string: peg.RuleId,
    } = undefined,

    fn kind(x: *const X, row: u32) peg.RuleId {
        return x.t.rows[row].rule;
    }

    fn str(x: *const X, row: u32) []const u8 {
        return x.t.text(row);
    }

    fn line(x: *X, comptime fmt: []const u8, args: anytype) Error!void {
        try x.out.print(x.arena, fmt, args);
        try x.out.append(x.arena, '\n');
    }

    fn device(x: *X, letter: u8, comptime fmt: []const u8, args: anytype) Error!void {
        try x.kinds.put(x.arena, @intCast(x.out.items.len), letter);
        try x.line(fmt, args);
    }

    /// Model, subcircuit and module names anywhere in the deck (§6.4:
    /// forward references are allowed).
    fn declare(x: *X, list: u32) Error!void {
        var it = x.t.children(list);
        while (it.next()) |c| {
            const k = x.kind(c);
            if (k == x.r.model) {
                try x.models.put(x.arena, x.str(x.t.child(c, x.r.name).?), x.str(x.t.child(c, x.r.master).?));
            } else if (k == x.r.subckt) {
                try x.subckts.put(x.arena, x.str(x.t.child(c, x.r.name).?), {});
                try x.declare(c);
            } else if (k == x.r.ahdlInclude) {
                x.ahdl = true;
            } else if (k == x.r.@"if" or k == x.r.@"else") {
                try x.declare(c);
            }
        }
    }

    fn lines(x: *X, list: u32) Error!void {
        var it = x.t.children(list);
        while (it.next()) |c| try x.stmt(c);
    }

    fn stmt(x: *X, c: u32) Error!void {
        const k = x.kind(c);
        const r = x.r;
        if (k == r.simulator or k == r.save or k == r.ends or k == r.name) return;
        if (k == r.spiceRegion) return x.region(c);
        if (k == r.parameters) return x.parameters(c, null);
        if (k == r.model) return x.model(c);
        if (k == r.subckt) return x.subckt(c);
        if (k == r.global) return x.global(c);
        if (k == r.ic or k == r.nodeset) return x.initial(c, if (k == r.ic) "ic" else "nodeset");
        if (k == r.@"if") return x.cond(c, ".if");
        if (k == r.function) return x.function(c);
        if (k == r.statistics) return;
        if (k == r.ahdlInclude) return x.line(".hdl {s}", .{x.str(x.t.child(c, r.string).?)});
        if (k == r.instance) return x.instance(c);
        if (k == r.analysis) return x.analysis(c);
        if (k == r.control) return x.control(c);
        // `include`, `library`, `section`: refused until Spectre include
        // expansion lands.
        return error.Refused;
    }

    /// §3.2: a SPICE region's cards, as Spectre's SPICE reader reads them:
    /// lowercased, numbers with SPICE suffixes written plain, `'` quoting
    /// as `"`.
    fn region(x: *X, c: u32) Error!void {
        var it = x.t.children(c);
        while (it.next()) |card| {
            if (x.kind(card) != x.r.spiceCard) continue;
            try x.spiceCard(x.str(card));
        }
    }

    fn spiceCard(x: *X, card: []const u8) Error!void {
        var i: usize = 0;
        while (i < card.len) {
            const ch = card[i];
            const prev: u8 = if (i == 0) ' ' else card[i - 1];
            const starts = std.ascii.isDigit(ch) or (ch == '.' and i + 1 < card.len and std.ascii.isDigit(card[i + 1]));
            if (starts and !(std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '.')) {
                var j = i;
                while (j < card.len and (std.ascii.isAlphanumeric(card[j]) or card[j] == '.' or
                    ((card[j] == '+' or card[j] == '-') and j > i and std.ascii.toLower(card[j - 1]) == 'e'))) j += 1;
                if (spiceNumber(card[i..j])) |v| {
                    try x.out.print(x.arena, "{e}", .{v});
                } else for (card[i..j]) |b| try x.out.append(x.arena, std.ascii.toLower(b));
                i = j;
                continue;
            }
            try x.out.append(x.arena, if (ch == '\'') '"' else std.ascii.toLower(ch));
            i += 1;
        }
        try x.out.append(x.arena, '\n');
    }

    /// An HSPICE number (hspice-syntax.md T3): mantissa, `e`/`d` exponent,
    /// then T G MEG X K MIL M U N P F A, letters after it ignored.
    fn spiceNumber(word: []const u8) ?f64 {
        var buf: [64]u8 = undefined;
        if (word.len > buf.len) return null;
        const w = std.ascii.lowerString(&buf, word);
        var i: usize = 0;
        while (i < w.len and (std.ascii.isDigit(w[i]) or w[i] == '.')) i += 1;
        if (i == 0) return null;
        var end = i;
        if (i < w.len and (w[i] == 'e' or w[i] == 'd')) {
            var j = i + 1;
            if (j < w.len and (w[j] == '+' or w[j] == '-')) j += 1;
            const digits = j;
            while (j < w.len and std.ascii.isDigit(w[j])) j += 1;
            if (j > digits) end = j;
        }
        var lit: [64]u8 = undefined;
        @memcpy(lit[0..end], w[0..end]);
        for (lit[0..end]) |*b| if (b.* == 'd') {
            b.* = 'e';
        };
        var v = std.fmt.parseFloat(f64, lit[0..end]) catch return null;
        const suffix = w[end..];
        if (std.mem.startsWith(u8, suffix, "meg")) {
            v *= 1e6;
        } else if (std.mem.startsWith(u8, suffix, "mil")) {
            v *= 25.4e-6;
        } else if (suffix.len > 0) v *= switch (suffix[0]) {
            't' => 1e12,
            'g' => 1e9,
            'x' => 1e6,
            'k' => 1e3,
            'm' => 1e-3,
            'u' => 1e-6,
            'n' => 1e-9,
            'p' => 1e-12,
            'f' => 1e-15,
            'a' => 1e-18,
            else => 1,
        };
        return v;
    }

    fn params(x: *X, row: u32) Error![]const KeyValue {
        var out: std.ArrayList(KeyValue) = .empty;
        var it = x.t.children(row);
        while (it.next()) |c| if (x.kind(c) == x.r.param) {
            var p = x.t.children(c);
            const key = x.str(p.next().?);
            try out.append(x.arena, .{ .key = key, .value = p.next().? });
        };
        return out.items;
    }

    fn findParam(ps: anytype, key: []const u8) ?u32 {
        for (ps) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
        return null;
    }

    /// `parameters a=1 b`: global cards, or the defaults `into` gathers for
    /// a subcircuit's `.subckt` card (no value: no default).
    fn parameters(x: *X, c: u32, into: ?*std.ArrayList(u8)) Error!void {
        var text: std.ArrayList(u8) = .empty;
        var it = x.t.children(c);
        while (it.next()) |d| {
            if (x.kind(d) != x.r.paramDecl) continue;
            var p = x.t.children(d);
            const key = x.str(p.next().?);
            // Spectre reserves these names (R11 p.361, R19 p.508).
            for ([_][]const u8{ "temp", "tnom", "scale", "scalem", "freq", "time" }) |w| if (std.mem.eql(u8, key, w)) return error.Refused;
            const v = p.next() orelse continue;
            try text.print(x.arena, " {s}={s}", .{ key, try x.value(v) });
        }
        if (into) |o| return o.appendSlice(x.arena, text.items);
        if (text.items.len > 0) try x.line(".param{s}", .{text.items});
    }

    fn model(x: *X, c: u32) Error!void {
        const name = x.str(x.t.child(c, x.r.name).?);
        const master = x.str(x.t.child(c, x.r.master).?);
        const ps = try x.params(c);
        var groups = false;
        var it = x.t.children(c);
        while (it.next()) |gr| if (x.kind(gr) == x.r.group) {
            groups = true;
            // `label:`, a name or an integer (R19 p.493).
            const row = x.str(gr);
            const label = std.mem.trimEnd(u8, row[0..std.mem.indexOfScalar(u8, row, ':').?], " \t");
            try x.modelCard(try std.fmt.allocPrint(x.arena, "{s}.{s}", .{ name, label }), master, ps, try x.params(gr));
        };
        if (!groups) try x.modelCard(name, master, ps, &.{});
    }

    fn modelCard(x: *X, name: []const u8, master: []const u8, ps: anytype, more: anytype) Error!void {
        const m = masters.get(master) orelse return error.Refused;
        const ty = findParam(ps, "type") orelse findParam(more, "type");
        const p = if (ty) |v| std.mem.eql(u8, x.str(v), "p") or std.mem.eql(u8, x.str(v), "pnp") else false;
        var text: std.ArrayList(u8) = .empty;
        try text.print(x.arena, ".model {s} {s}", .{ name, if (p) m.p else m.n });
        if (m.level) |lv| try text.print(x.arena, " level={d}", .{lv});
        for (ps) |kv| if (!std.mem.eql(u8, kv.key, "type")) try text.print(x.arena, " {s}={s}", .{ kv.key, try x.value(kv.value) });
        for (more) |kv| if (!std.mem.eql(u8, kv.key, "type")) try text.print(x.arena, " {s}={s}", .{ kv.key, try x.value(kv.value) });
        try x.line("{s}", .{text.items});
    }

    /// `.subckt name ports <defaults from every parameters line>`, the body,
    /// `.ends`.
    fn subckt(x: *X, c: u32) Error!void {
        var head: std.ArrayList(u8) = .empty;
        try head.print(x.arena, ".subckt {s}", .{x.str(x.t.child(c, x.r.name).?)});
        var defaults: std.ArrayList(u8) = .empty;
        var it = x.t.children(c);
        while (it.next()) |d| {
            if (x.kind(d) == x.r.node) try head.print(x.arena, " {s}", .{x.str(d)});
            if (x.kind(d) == x.r.parameters) try x.parameters(d, &defaults);
        }
        try x.line("{s}{s}", .{ head.items, defaults.items });
        var body = x.t.children(c);
        while (body.next()) |d| {
            const k = x.kind(d);
            if (k == x.r.name or k == x.r.node or k == x.r.parameters or k == x.r.ends) continue;
            if (k == x.r.analysis) return error.Refused;
            try x.stmt(d);
        }
        try x.line(".ends", .{});
    }

    fn global(x: *X, c: u32) Error!void {
        var it = x.t.children(c);
        const g = x.str(it.next().?);
        if (!std.mem.eql(u8, g, "0")) try x.line(".connect 0 {s}", .{g});
        var rest: std.ArrayList(u8) = .empty;
        while (it.next()) |n| try rest.print(x.arena, " {s}", .{x.str(n)});
        if (rest.items.len > 0) try x.line(".global{s}", .{rest.items});
    }

    fn initial(x: *X, c: u32, card: []const u8) Error!void {
        var text: std.ArrayList(u8) = .empty;
        try text.print(x.arena, ".{s}", .{card});
        var it = x.t.children(c);
        while (it.next()) |sig| {
            if (std.mem.indexOfScalar(u8, x.str(sig), ':') != null) return error.Refused;
            const v = it.next().?;
            try text.print(x.arena, " v({s})={s}", .{ x.str(sig), try x.value(v) });
        }
        try x.line("{s}", .{text.items});
    }

    /// `.if (c)` ... `.elseif`/`.else` ... `.endif` (§4.12).
    fn cond(x: *X, c: u32, card: []const u8) Error!void {
        var it = x.t.children(c);
        const test_row = it.next().?;
        try x.line("{s} ({s})", .{ card, try x.expr(test_row) });
        while (it.next()) |d| {
            if (x.kind(d) == x.r.@"else") {
                var e = x.t.children(d);
                const first = e.next() orelse continue;
                if (x.kind(first) == x.r.@"if") {
                    // `else if`: one chain, ended by the inner `.endif`.
                    return x.cond(first, ".elseif");
                }
                try x.line(".else", .{});
                try x.stmt(first);
                while (e.next()) |s| try x.stmt(s);
                continue;
            }
            try x.stmt(d);
        }
        try x.line(".endif", .{});
    }

    fn function(x: *X, c: u32) Error!void {
        var it = x.t.children(c);
        const name = x.str(it.next().?);
        var args: std.ArrayList(u8) = .empty;
        var body: u32 = undefined;
        while (it.next()) |d| {
            if (x.kind(d) == x.r.fArg) {
                if (args.items.len > 0) try args.append(x.arena, ',');
                try args.appendSlice(x.arena, x.str(x.t.child(d, x.r.name).?));
            } else body = d;
        }
        try x.line(".func {s}({s}) {s}", .{ name, args.items, try x.expr(body) });
    }

    fn instance(x: *X, c: u32) Error!void {
        var it = x.t.children(c);
        const name = x.str(it.next().?);
        var pins: std.ArrayList(u8) = .empty;
        var master: []const u8 = "";
        while (it.next()) |d| {
            if (x.kind(d) == x.r.node) {
                if (pins.items.len > 0) try pins.append(x.arena, ' ');
                try pins.appendSlice(x.arena, x.str(d));
            } else if (x.kind(d) == x.r.master) master = x.str(d);
        }
        const ps = try x.params(c);
        if (primitives.get(master)) |p| return x.primitive(p, master, name, pins.items, ps);
        var kv: std.ArrayList(u8) = .empty;
        for (ps) |p| try kv.print(x.arena, " {s}={s}", .{ p.key, try x.value(p.value) });
        if (x.subckts.contains(master)) return x.device('x', "{s} {s} {s}{s}", .{ name, pins.items, master, kv.items });
        if (x.models.get(master)) |mm| {
            const m = masters.get(mm) orelse return error.Refused;
            return x.device(m.letter, "{s} {s} {s}{s}", .{ name, pins.items, master, kv.items });
        }
        if (x.ahdl) {
            const gop = try x.ahdl_models.getOrPut(x.arena, master);
            if (!gop.found_existing) try x.line(".model {s} {s}", .{ master, master });
            return x.device('n', "{s} {s} {s}{s}", .{ name, pins.items, master, kv.items });
        }
        return error.Refused;
    }

    fn primitive(x: *X, p: Prim, master: []const u8, name: []const u8, pins: []const u8, ps: anytype) Error!void {
        var pos: std.ArrayList(u8) = .empty;
        var kv: std.ArrayList(u8) = .empty;
        for (p.lead) |key| if (findParam(ps, key)) |v| try pos.print(x.arena, " {s}", .{try x.value(v)});
        const source = p.letter == 'v' or p.letter == 'i';
        if (source) {
            if (std.mem.eql(u8, master, "iprobe")) try pos.appendSlice(x.arena, " dc 0");
            try x.waveform(&pos, ps);
        }
        outer: for (ps) |kvp| {
            for (p.lead) |key| if (std.mem.eql(u8, key, kvp.key)) continue :outer;
            if (source) for (wave_keys) |key| if (std.mem.eql(u8, key, kvp.key)) continue :outer;
            try kv.print(x.arena, " {s}={s}", .{ kvp.key, try x.value(kvp.value) });
        }
        const sep: []const u8 = if (pins.len > 0) " " else "";
        try x.device(p.letter, "{s}{s}{s}{s}{s}", .{ name, sep, pins, pos.items, kv.items });
    }

    fn waveform(x: *X, pos: *std.ArrayList(u8), ps: anytype) Error!void {
        if (findParam(ps, "dc")) |v| try pos.print(x.arena, " dc {s}", .{try x.value(v)});
        if (findParam(ps, "mag")) |v| {
            try pos.print(x.arena, " ac {s}", .{try x.value(v)});
            if (findParam(ps, "phase")) |ph| try pos.print(x.arena, " {s}", .{try x.value(ph)});
        }
        const ty = x.str(findParam(ps, "type") orelse return);
        const W = struct { fields: []const []const u8, name: []const u8 };
        const w: W = if (std.mem.eql(u8, ty, "pulse"))
            .{ .fields = &.{ "val0", "val1", "delay", "rise", "fall", "width", "period" }, .name = "pulse" }
        else if (std.mem.eql(u8, ty, "sine"))
            .{ .fields = &.{ "sinedc", "ampl", "freq", "delay", "damp", "sinephase" }, .name = "sin" }
        else if (std.mem.eql(u8, ty, "exp"))
            .{ .fields = &.{ "val0", "val1", "td1", "tau1", "td2", "tau2" }, .name = "exp" }
        else if (std.mem.eql(u8, ty, "pwl")) {
            const wave = findParam(ps, "wave") orelse return error.Refused;
            if (x.kind(wave) != x.r.vector) return error.Refused;
            try pos.appendSlice(x.arena, " pwl(");
            var it = x.t.children(wave);
            var first = true;
            while (it.next()) |el| {
                if (!first) try pos.append(x.arena, ' ');
                first = false;
                try pos.appendSlice(x.arena, try x.element(el));
            }
            try pos.append(x.arena, ')');
            return;
        } else if (std.mem.eql(u8, ty, "dc")) return else return error.Refused;
        var last: usize = 0;
        for (w.fields, 0..) |f, k| if (findParam(ps, f) != null) {
            last = k + 1;
        };
        try pos.print(x.arena, " {s}(", .{w.name});
        for (w.fields[0..last], 0..) |f, k| {
            if (k > 0) try pos.append(x.arena, ' ');
            try pos.appendSlice(x.arena, if (findParam(ps, f)) |v| try x.value(v) else "0");
        }
        try pos.append(x.arena, ')');
    }

    fn analysis(x: *X, c: u32) Error!void {
        const k = x.str(x.t.child(c, x.r.kind).?);
        var nodes: std.ArrayList([]const u8) = .empty;
        var it = x.t.children(c);
        while (it.next()) |d| if (x.kind(d) == x.r.node) try nodes.append(x.arena, x.str(d));
        // Child analyses in braces are a `sweep` or `montecarlo`'s: refused.
        var kids = x.t.children(c);
        while (kids.next()) |d| if (x.kind(d) == x.r.instance or x.kind(d) == x.r.analysis) return error.Refused;
        const ps = try x.params(c);
        if (std.mem.eql(u8, k, "tran")) {
            const stop = try x.value(findParam(ps, "stop") orelse return error.Refused);
            const step = if (findParam(ps, "step")) |s| try x.value(s) else try std.fmt.allocPrint(x.arena, "\"({s}/50)\"", .{std.mem.trim(u8, stop, "\"")});
            const start = if (findParam(ps, "start")) |s| try x.value(s) else null;
            if (findParam(ps, "maxstep")) |m| return x.line(".tran {s} {s} {s} {s}", .{ step, stop, start orelse "0", try x.value(m) });
            if (start) |s| return x.line(".tran {s} {s} {s}", .{ step, stop, s });
            return x.line(".tran {s} {s}", .{ step, stop });
        }
        if (std.mem.eql(u8, k, "dc")) {
            const target = if (findParam(ps, "dev")) |d| x.str(d) else if (findParam(ps, "param")) |p| x.str(p) else {
                if (ps.len != 0) return error.Refused;
                return x.line(".op", .{});
            };
            if (findParam(ps, "dev") != null) if (findParam(ps, "param")) |p| if (!std.mem.eql(u8, x.str(p), "dc")) return error.Refused;
            return x.line(".dc {s} {s}", .{ target, try x.sweep(ps, false) });
        }
        if (std.mem.eql(u8, k, "ac")) return x.line(".ac {s}", .{try x.sweep(ps, true)});
        if (std.mem.eql(u8, k, "noise")) {
            const src = findParam(ps, "iprobe") orelse return error.Refused;
            const out = switch (nodes.items.len) {
                1 => try std.fmt.allocPrint(x.arena, "v({s})", .{nodes.items[0]}),
                2 => try std.fmt.allocPrint(x.arena, "v({s},{s})", .{ nodes.items[0], nodes.items[1] }),
                else => return error.Refused,
            };
            return x.line(".noise {s} {s} {s}", .{ out, x.str(src), try x.sweep(ps, true) });
        }
        return error.Refused;
    }

    fn sweep(x: *X, ps: anytype, ac: bool) Error![]const u8 {
        if (findParam(ps, "values")) |v| {
            if (x.kind(v) != x.r.vector) return error.Refused;
            var els: std.ArrayList(u8) = .empty;
            var n: usize = 0;
            var it = x.t.children(v);
            while (it.next()) |el| {
                try els.print(x.arena, " {s}", .{try x.element(el)});
                n += 1;
            }
            return std.fmt.allocPrint(x.arena, "poi {d}{s}", .{ n, els.items });
        }
        const start = try x.value(findParam(ps, "start") orelse return error.Refused);
        const stop = try x.value(findParam(ps, "stop") orelse return error.Refused);
        if (findParam(ps, "dec")) |n| return std.fmt.allocPrint(x.arena, "dec {s} {s} {s}", .{ try x.value(n), start, stop });
        if (findParam(ps, "lin")) |n| {
            if (ac) return std.fmt.allocPrint(x.arena, "lin {s} {s} {s}", .{ try x.value(n), start, stop });
            const q = "\"";
            return std.fmt.allocPrint(x.arena, "{s} {s} \"(({s}-{s})/{s})\"", .{ start, stop, std.mem.trim(u8, stop, q), std.mem.trim(u8, start, q), std.mem.trim(u8, try x.value(n), q) });
        }
        if (findParam(ps, "step")) |s| {
            if (ac) return error.Refused;
            return std.fmt.allocPrint(x.arena, "{s} {s} {s}", .{ start, stop, try x.value(s) });
        }
        return error.Refused;
    }

    fn control(x: *X, c: u32) Error!void {
        const k = x.str(x.t.child(c, x.r.kind2).?);
        if (std.mem.eql(u8, k, "alter") or std.mem.eql(u8, k, "altergroup") or std.mem.eql(u8, k, "paramset")) return error.Refused;
        if (!std.mem.eql(u8, k, "options")) return;
        var text: std.ArrayList(u8) = .empty;
        for (try x.params(c)) |p| {
            const v = try x.value(p.value);
            if (std.mem.eql(u8, p.key, "temp")) {
                try x.line(".temp {s}", .{v});
                continue;
            }
            const key = if (std.mem.eql(u8, p.key, "vabstol")) "vntol" else if (std.mem.eql(u8, p.key, "iabstol")) "abstol" else p.key;
            try text.print(x.arena, " {s}={s}", .{ key, v });
        }
        if (text.items.len > 0) try x.line(".options{s}", .{text.items});
    }

    // Values ----------------------------------------------------------------

    /// A value as SPICE text: a name, a plain number, or a quoted expression.
    fn value(x: *X, row: u32) Error![]const u8 {
        if (x.kind(row) == x.r.vector) return error.Refused;
        const e = try x.expr(row);
        if (e[0] == '"' or std.mem.indexOfAny(u8, e, "()+*/%?:<>=!&|") == null and !std.mem.startsWith(u8, e, "-")) return e;
        return std.fmt.allocPrint(x.arena, "\"{s}\"", .{e});
    }

    /// A vector element (§5): a constant, a name, a signed one, a string or
    /// a parenthesized expression, as one card field.
    fn element(x: *X, row: u32) Error![]const u8 {
        const e = try x.expr(row);
        if (e[0] == '"' or std.mem.indexOfAny(u8, e, "()+*/%?:<>=!&|") == null and !std.mem.startsWith(u8, e, "-")) return e;
        return std.fmt.allocPrint(x.arena, "\"{s}\"", .{e});
    }

    /// An expression's ESPice text, fully parenthesized (§6.1).
    fn expr(x: *X, row: u32) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try x.emit(&out, row, 0);
        return out.items;
    }

    fn emit(x: *X, out: *std.ArrayList(u8), row: u32, depth: u32) Error!void {
        if (depth > peg.depth_max) return error.Refused;
        const r = x.r;
        const k = x.kind(row);
        var it = x.t.children(row);
        if (k == r.expr or k == r.paren and false) {
            return x.emit(out, it.next().?, depth + 1);
        }
        if (k == r.ternary) {
            const c = it.next().?;
            const a = it.next() orelse return x.emit(out, c, depth + 1);
            const b = it.next().?;
            try out.append(x.arena, '(');
            try x.emit(out, c, depth + 1);
            try out.append(x.arena, '?');
            try x.emit(out, a, depth + 1);
            try out.append(x.arena, ':');
            try x.emit(out, b, depth + 1);
            return out.append(x.arena, ')');
        }
        if (k == r.@"or" or k == r.@"and" or k == r.eq or k == r.rel or k == r.add or k == r.mul) {
            // Left-associative: each step wraps the text so far.
            var acc: std.ArrayList(u8) = .empty;
            try x.emit(&acc, it.next().?, depth + 1);
            while (it.next()) |op| {
                var rhs: std.ArrayList(u8) = .empty;
                try x.emit(&rhs, it.next().?, depth + 1);
                acc = try listOf(x.arena, try std.fmt.allocPrint(x.arena, "({s}{s}{s})", .{ acc.items, x.str(op), rhs.items }));
            }
            return out.appendSlice(x.arena, acc.items);
        }
        if (k == r.pow) {
            const a = it.next().?;
            _ = it.next() orelse return x.emit(out, a, depth + 1);
            const b = it.next().?;
            try out.append(x.arena, '(');
            try x.emit(out, a, depth + 1);
            try out.appendSlice(x.arena, "**");
            try x.emit(out, b, depth + 1);
            return out.append(x.arena, ')');
        }
        if (k == r.unary or k == r.unary2) {
            const first = it.next().?;
            const operand = it.next() orelse return x.emit(out, first, depth + 1);
            try out.print(x.arena, "({s}", .{x.str(first)});
            try x.emit(out, operand, depth + 1);
            return out.append(x.arena, ')');
        }
        if (k == r.paren) {
            try out.append(x.arena, '(');
            try x.emit(out, it.next().?, depth + 1);
            return out.append(x.arena, ')');
        }
        if (k == r.string) return out.appendSlice(x.arena, x.str(row));
        if (k == r.num) return out.print(x.arena, "{e}", .{x.number(row)});
        if (k == r.ref) {
            const w = x.str(row);
            if (constants.get(w)) |v| return out.print(x.arena, "{e}", .{v});
            if (std.mem.eql(u8, w, "temp")) return out.appendSlice(x.arena, "temper");
            if (std.mem.eql(u8, w, "$time")) return out.appendSlice(x.arena, "time");
            return out.appendSlice(x.arena, w);
        }
        if (k == r.call) {
            const name = x.str(it.next().?);
            var args: std.ArrayList([]const u8) = .empty;
            while (it.next()) |a| {
                var buf: std.ArrayList(u8) = .empty;
                try x.emit(&buf, a, depth + 1);
                try args.append(x.arena, buf.items);
            }
            const a = args.items;
            if (std.mem.eql(u8, name, "fmod") and a.len == 2) return out.print(x.arena, "({s}%{s})", .{ a[0], a[1] });
            if (std.mem.eql(u8, name, "hypot") and a.len == 2) return out.print(x.arena, "sqrt({s}*{s}+{s}*{s})", .{ a[0], a[0], a[1], a[1] });
            if (std.mem.eql(u8, name, "sign") and a.len == 2) return out.print(x.arena, "(sgn({s})*abs({s}))", .{ a[1], a[0] });
            if (std.mem.eql(u8, name, "atan2")) return error.Refused;
            try out.print(x.arena, "{s}(", .{name});
            for (a, 0..) |arg, i| {
                if (i > 0) try out.append(x.arena, ',');
                try out.appendSlice(x.arena, arg);
            }
            return out.append(x.arena, ')');
        }
        return error.Refused;
    }

    /// §2.4: a Spectre number: mantissa, exponent or SI scale (case-
    /// sensitive), unit letters ignored.
    fn number(x: *const X, row: u32) f64 {
        const m = x.str(x.t.child(row, x.r.mantissa).?);
        var v = std.fmt.parseFloat(f64, m) catch unreachable;
        if (x.t.child(row, x.r.exponent)) |e| {
            const exp = std.fmt.parseFloat(f64, x.str(e)[1..]) catch unreachable;
            v *= std.math.pow(f64, 10, exp);
        }
        if (x.t.child(row, x.r.scale)) |s| v *= switch (x.str(s)[0]) {
            'P' => 1e15,
            'T' => 1e12,
            'G' => 1e9,
            'M' => 1e6,
            'K', 'k' => 1e3,
            '_' => 1,
            '%', 'c' => 1e-2,
            'm' => 1e-3,
            'u' => 1e-6,
            'n' => 1e-9,
            'p' => 1e-12,
            'f' => 1e-15,
            'a' => 1e-18,
            else => unreachable,
        };
        return v;
    }
};

fn listOf(arena: Allocator, s: []const u8) Allocator.Error!std.ArrayList(u8) {
    var l: std.ArrayList(u8) = .empty;
    try l.appendSlice(arena, s);
    return l;
}
