//! A SPICE card tree (spice_cards.peg plus a dialect file) -> the canonical
//! netlist canon.zig prints: the grammar oracle's own reading of a deck,
//! written from the research notes' semantics, not from netlist.zig. It
//! evaluates parameters in the scope that defines them, splits each element's
//! nodes from its model by looking the names up (dev/research/ngspice-syntax.md
//! §3.1), and flattens subcircuits, naming devices `<letter>.<path>.<name>`
//! and nets `<path>.<node>`.
//!
//! Some cards the frontend rewrites into another device before it builds
//! them (a behavioural E/G/R, an HSPICE port); the grammar checks their
//! syntax, and here they are "loose": compared by name and pins only. The
//! loose set is part of the result, so the frontend side prints the same.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const netlist = @import("netlist");
const Value = netlist.Value;
const Kv = netlist.Kv;
const peg = @import("peg.zig");
const canon = @import("canon.zig");

/// The rule ids the lowering reads, looked up once per grammar.
pub const Rules = struct {
    element: peg.RuleId,
    model: peg.RuleId,
    subckt: peg.RuleId,
    ends: peg.RuleId,
    param: peg.RuleId,
    assign: peg.RuleId,
    funcdef: peg.RuleId,
    func: peg.RuleId,
    options: peg.RuleId,
    temp: peg.RuleId,
    ic: peg.RuleId,
    nodeset: peg.RuleId,
    global: peg.RuleId,
    analysis: peg.RuleId,
    kind: peg.RuleId,
    cond: peg.RuleId,
    elseif: peg.RuleId,
    @"else": peg.RuleId,
    name: peg.RuleId,
    key: peg.RuleId,
    word: peg.RuleId,
    number: peg.RuleId,
    mantissa: peg.RuleId,
    exponent: peg.RuleId,
    scale: peg.RuleId,
    pair: peg.RuleId,
    group: peg.RuleId,
    expr: peg.RuleId,
    str: peg.RuleId,
    ternary: peg.RuleId,
    @"or": peg.RuleId,
    @"and": peg.RuleId,
    cmp: peg.RuleId,
    add: peg.RuleId,
    mul: peg.RuleId,
    pow: peg.RuleId,
    unary: peg.RuleId,
    paren: peg.RuleId,
    probe: peg.RuleId,
    call: peg.RuleId,
    num: peg.RuleId,
    ref: peg.RuleId,
    lpair: peg.RuleId,
    other: peg.RuleId,
    path: peg.RuleId,

    /// Looks every rule up; asserts each exists.
    pub fn of(g: peg.Grammar) Rules {
        var r: Rules = undefined;
        inline for (@typeInfo(Rules).@"struct".field_names) |f| {
            const name = comptime blk: {
                var buf: [f.len]u8 = undefined;
                @memcpy(&buf, f);
                buf[0] = std.ascii.toUpper(buf[0]);
                break :blk buf;
            };
            const spelled = if (std.mem.eql(u8, &name, "Funcdef")) "FuncDef" else if (std.mem.eql(u8, &name, "Lpair")) "LPair" else if (std.mem.eql(u8, &name, "@\"else\"")) "Else" else &name;
            @field(r, f) = g.rule(spelled);
        }
        return r;
    }
};

/// A rule only some dialects define (`Vec`, HSPICE's), or `none_rule`.
const none_rule = std.math.maxInt(peg.RuleId);

/// The oracle's netlist: canonical lines in canon.zig's order, and the
/// devices compared by name and pins only.
pub const Lowered = struct {
    text: []const u8,
    loose: std.StringHashMapUnmanaged(void),
};

/// Why the oracle could not lower a deck the grammar accepted: a card the
/// semantics refuse (an X card naming no subcircuit, a wrong port count).
pub const Error = error{ OutOfMemory, Refused, WriteFailed };

/// A parameter: a value tree read in the scope that defines it, a number
/// (a folded instance value), or a tree read in the caller's scopes (an
/// instance value that did not fold).
const Def = union(enum) {
    row: u32,
    num: f64,
    caller: struct { row: u32, scopes: []const *const Scope },
};
const Scope = std.StringHashMapUnmanaged(Def);

const Frame = struct {
    path: ?[]const u8 = null,
    ports: []const []const u8 = &.{},
    actuals: []const []const u8 = &.{},
    /// Scopes from global outward-in; the last is this frame's.
    scopes: []const *const Scope,
    /// The subcircuit's own `.model` rows, visible inside it.
    locals: []const u32 = &.{},
    depth: u32 = 0,
};

const depth_max = 32;

/// Device letters of cards whose name does not carry one (a Spectre
/// instance's), by the card's offset in the card text.
pub const Kinds = std.AutoHashMapUnmanaged(u32, u8);

/// Lowers the card tree `t` (start rule `Deck`) of a deck in `dialect`;
/// `kinds` names the letter of each card it holds.
pub fn lower(arena: Allocator, g: peg.Grammar, t: peg.Tree, dialect: netlist.Dialect, kinds: *const Kinds) Error!Lowered {
    var l: L = .{ .arena = arena, .r = .of(g), .vec = g.find("Vec") orelse none_rule, .t = t, .dialect = dialect, .kinds = kinds };
    try l.run();
    return .{ .text = l.out.written(), .loose = l.loose };
}

const L = struct {
    arena: Allocator,
    r: Rules,
    vec: peg.RuleId,
    kinds: *const Kinds,
    t: peg.Tree,
    dialect: netlist.Dialect,
    out: std.Io.Writer.Allocating = undefined,
    loose: std.StringHashMapUnmanaged(void) = .empty,
    globals: Scope = .empty,
    subckts: std.StringHashMapUnmanaged(u32) = .empty,
    models: std.StringHashMapUnmanaged(void) = .empty,
    global_nets: std.StringHashMapUnmanaged(void) = .empty,
    /// Lines after the devices, gathered in card order.
    model_lines: std.Io.Writer.Allocating = undefined,
    analysis_lines: std.Io.Writer.Allocating = undefined,
    config_lines: std.Io.Writer.Allocating = undefined,
    ic_args: std.ArrayList([]const Value) = .empty,
    nodeset_args: std.ArrayList([]const Value) = .empty,
    nets: std.StringHashMapUnmanaged(void) = .empty,
    ic_text: []const u8 = "",
    /// Top-level `.model` rows in card order (the bins `binOf` searches).
    global_models: std.ArrayList(u32) = .empty,
    /// `.option scale` and `wnflag` (HSPICE's default 1, ngspice's 0).
    scale: f64 = 1,
    wnflag: bool = false,
    /// Global `.param` names a sweep varies: a device or model value that
    /// reads one stays an expression, re-evaluated per point.
    live: std.StringHashMapUnmanaged(void) = .empty,
    /// Some card runs Monte Carlo: distribution calls in a device or model
    /// value stay expressions, drawn per trial.
    monte: bool = false,
    /// Reading a device or model value.
    in_card: bool = false,
    /// `.func` and `.param f(x)=` definitions: formals and body row.
    funcs: std.StringHashMapUnmanaged(struct { formals: []const []const u8, body: u32 }) = .empty,
    /// The formals of the user functions `eval` is inside, innermost last.
    bindings: std.ArrayList(struct { name: []const u8, value: f64 }) = .empty,
    printed_models: std.StringHashMapUnmanaged(void) = .empty,
    /// HSPICE `SWEEP OPTIMIZE=name` names: `name(init, lo, hi)` is `init`.
    opt_names: std.StringHashMapUnmanaged(void) = .empty,
    /// `.connect a b`: `b` is another name for top-level net `a`.
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Nets in the order a card first names them, for the shunts.
    net_order: std.ArrayList([]const u8) = .empty,

    fn kind(l: *const L, row: u32) peg.RuleId {
        return l.t.rows[row].rule;
    }

    fn text(l: *const L, row: u32) []const u8 {
        return l.t.text(row);
    }

    fn run(l: *L) Error!void {
        l.out = .init(l.arena);
        l.model_lines = .init(l.arena);
        l.analysis_lines = .init(l.arena);
        l.config_lines = .init(l.arena);
        var roots = l.t.children(null);
        const deck = roots.next() orelse return;
        // Walk 1: declarations at the top level (and subcircuit names at any
        // depth: their names are global, §2.5).
        try l.declare(deck, &l.globals, true);
        l.wnflag = l.dialect != .ngspice;
        try l.prescan(deck);
        const top: Frame = .{ .scopes = &.{&l.globals} };
        // Walk 2: devices, models and deck cards, in card order.
        try l.walk(deck, &top, true);
        try l.shunts();
        try nodeCards(l);
        const w = &l.out.writer;
        try w.writeAll(l.model_lines.written());
        try w.writeAll(l.analysis_lines.written());
        try w.writeAll(l.config_lines.written());
        try w.writeAll(l.ic_text);
    }

    /// `.option gshunt=G cshunt=C`: an R of 1/G and a C from every net to
    /// ground, named `r.gshunt.<net>` and `c.cshunt.<net>`, nets in the
    /// order cards first name them (hspice-syntax.md, HSPICE dialect).
    fn shunts(l: *L) Error!void {
        var roots = l.t.children(null);
        var it = l.t.children(roots.next().?);
        var g: ?f64 = null;
        var c: ?f64 = null;
        while (it.next()) |card| if (l.kind(card) == l.r.options) {
            const a = try l.cardArgs(card);
            for (a, 0..) |v, i| if (v == .name and i + 1 < a.len and a[i + 1] == .num) {
                if (std.mem.eql(u8, v.name, "gshunt")) g = a[i + 1].num;
                if (std.mem.eql(u8, v.name, "cshunt")) c = a[i + 1].num;
            };
        };
        const w = &l.out.writer;
        inline for (.{ .{ "gshunt", 'r', g }, .{ "cshunt", 'c', c } }) |sh| if (sh[2]) |v| if (v > 0) {
            for (l.net_order.items) |n| {
                if (netlist.isGroundName(n)) continue;
                try w.print("dev {c} {c}.{s}.{s} ({s} 0) {e:.11}\n", .{ sh[1], sh[1], sh[0], n, n, if (sh[1] == 'r') 1 / v else v });
            }
        };
    }

    /// Records the subcircuits, models and parameters a statement list
    /// declares. `top` also takes `.global` nets.
    fn declare(l: *L, list: u32, scope: *Scope, top: bool) Error!void {
        var it = l.t.children(list);
        while (it.next()) |c| {
            const k = l.kind(c);
            if (k == l.r.subckt) {
                const name = l.text(l.t.child(c, l.r.name).?);
                const gop = try l.subckts.getOrPut(l.arena, name);
                if (!gop.found_existing) gop.value_ptr.* = c;
                // Nested definitions are global names too.
                var inner = l.t.children(c);
                while (inner.next()) |ic| if (l.kind(ic) == l.r.subckt) {
                    const n = l.text(l.t.child(ic, l.r.name).?);
                    const g2 = try l.subckts.getOrPut(l.arena, n);
                    if (!g2.found_existing) g2.value_ptr.* = ic;
                };
            } else if (k == l.r.model) {
                if (top) {
                    try l.models.put(l.arena, l.text(l.t.child(c, l.r.name).?), {});
                    try l.global_models.append(l.arena, c);
                }
            } else if (k == l.r.param) {
                var a = l.t.children(c);
                while (a.next()) |as| if (l.kind(as) == l.r.assign) {
                    const key = l.text(l.t.child(as, l.r.key).?);
                    try scope.put(l.arena, key, .{ .row = valueRow(l, as) });
                } else if (l.kind(as) == l.r.funcdef) try l.defineFunc(as);
            } else if (k == l.r.func) {
                try l.defineFunc(c);
            } else if (k == l.r.global and top) {
                var a = l.t.children(c);
                while (a.next()) |w| try l.global_nets.put(l.arena, l.text(w), {});
            } else if (k == l.r.cond) {
                for (try l.taken(c, scope)) |b| try l.declareOne(b, scope, top);
            }
        }
    }

    fn declareOne(l: *L, card: u32, scope: *Scope, top: bool) Error!void {
        // One card through `declare`: wrap it as the list's only child.
        _ = top;
        const k = l.kind(card);
        if (k == l.r.param) {
            var a = l.t.children(card);
            while (a.next()) |as| if (l.kind(as) == l.r.assign) {
                const key = l.text(l.t.child(as, l.r.key).?);
                try scope.put(l.arena, key, .{ .row = valueRow(l, as) });
            } else if (l.kind(as) == l.r.funcdef) try l.defineFunc(as);
        } else if (k == l.r.model) {
            try l.models.put(l.arena, l.text(l.t.child(card, l.r.name).?), {});
            try l.global_models.append(l.arena, card);
        } else if (k == l.r.cond) {
            for (try l.taken(card, scope)) |b| try l.declareOne(b, scope, false);
        }
    }

    /// The cards of the branch an `.if` chain takes: the first whose
    /// condition is nonzero, or its `.else`; none when no branch holds
    /// (ngspice-syntax.md §4.1, `.if`). Conditions read `scope`.
    fn taken(l: *L, chain: u32, scope: *const Scope) Error![]const u32 {
        const scopes: []const *const Scope = if (scope == &l.globals) &.{&l.globals} else &.{ &l.globals, scope };
        var out: std.ArrayList(u32) = .empty;
        var state: enum { looking, taking, done } = .looking;
        var it = l.t.children(chain);
        // The first child is the `.if` condition.
        const first = it.next().?;
        // A condition that does not fold is refused, as the frontend's is.
        state = if ((l.eval(first, scopes, 0) orelse return error.Refused) != 0) .taking else .looking;
        while (it.next()) |c| {
            const k = l.kind(c);
            if (k == l.r.elseif or k == l.r.@"else") {
                if (state == .taking) {
                    state = .done;
                } else if (state == .looking) {
                    if (k == l.r.@"else") {
                        state = .taking;
                    } else {
                        var e = l.t.children(c);
                        state = if ((l.eval(e.next().?, scopes, 0) orelse return error.Refused) != 0) .taking else .looking;
                    }
                }
                continue;
            }
            if (state == .taking) try out.append(l.arena, c);
        }
        return out.items;
    }

    /// A user function (§2.4): its keys are the name then the formals, its
    /// last child the body.
    fn defineFunc(l: *L, row: u32) Error!void {
        var it = l.t.children(row);
        const name = l.text(it.next().?);
        var formals: std.ArrayList([]const u8) = .empty;
        var body: u32 = undefined;
        while (it.next()) |c| {
            if (l.kind(c) == l.r.key) try formals.append(l.arena, l.text(c)) else body = c;
        }
        try l.funcs.put(l.arena, name, .{ .formals = formals.items, .body = body });
    }

    /// Reads what changes how values fold before any device is read:
    /// `.option scale`/`wnflag`, the swept `.param` names and Monte Carlo.
    fn prescan(l: *L, deck: u32) Error!void {
        var it = l.t.children(deck);
        while (it.next()) |c| {
            const k = l.kind(c);
            if (k == l.r.options) {
                const a = try l.cardArgs(c);
                for (a, 0..) |v, i| if (v == .name and i + 1 < a.len and a[i + 1] == .num) {
                    if (std.mem.eql(u8, v.name, "scale")) l.scale = a[i + 1].num;
                    if (std.mem.eql(u8, v.name, "wnflag")) l.wnflag = a[i + 1].num != 0;
                };
            } else if (k == l.r.analysis or k == l.r.temp) {
                const a = try l.cardArgs(c);
                const dc = k == l.r.analysis and std.mem.eql(u8, l.text(l.t.child(c, l.r.kind).?), "dc");
                if (dc and a.len == 4 and a[0] == .name and l.globals.contains(a[0].name)) try l.live.put(l.arena, a[0].name, {});
                for (a, 0..) |v, i| if (v == .name) {
                    if (std.mem.eql(u8, v.name, "monte")) l.monte = true;
                    if (std.mem.eql(u8, v.name, "optimize") and i + 1 < a.len and a[i + 1] == .name) try l.opt_names.put(l.arena, a[i + 1].name, {});
                    if (std.mem.eql(u8, v.name, "sweep") and i + 1 < a.len and a[i + 1] == .name and l.globals.contains(a[i + 1].name))
                        try l.live.put(l.arena, a[i + 1].name, {});
                };
            } else if (k == l.r.other) {
                // `.step [lin|dec|oct] [param] name ...`
                var words = std.mem.tokenizeAny(u8, l.text(c), " \t,=()");
                const head = words.next() orelse "";
                if (std.mem.eql(u8, head, ".connect")) {
                    const a = words.next() orelse continue;
                    const b = words.next() orelse continue;
                    try l.aliases.put(l.arena, b, a);
                    continue;
                }
                if (!std.mem.eql(u8, head, ".step")) continue;
                while (words.next()) |w| {
                    if (std.mem.eql(u8, w, "lin") or std.mem.eql(u8, w, "dec") or std.mem.eql(u8, w, "oct") or std.mem.eql(u8, w, "param")) continue;
                    if (l.globals.contains(w)) try l.live.put(l.arena, w, {});
                    break;
                }
            }
        }
    }

    /// The row holding an assignment's value: the child after its key.
    fn valueRow(l: *const L, assign: u32) u32 {
        var it = l.t.children(assign);
        _ = it.next(); // key
        return it.next().?;
    }

    fn walk(l: *L, list: u32, frame: *const Frame, top: bool) Error!void {
        var it = l.t.children(list);
        while (it.next()) |c| {
            const k = l.kind(c);
            if (k == l.r.element) {
                try l.element(c, frame);
            } else if (k == l.r.model) {
                if (top) try l.model(c, frame);
            } else if (top and k == l.r.analysis) {
                try l.analysis(c);
            } else if (top and k == l.r.temp) {
                try l.analysisAs(c, "temp");
            } else if (top and k == l.r.options) {
                const vals = try l.cardArgs(c);
                try l.config_lines.writer.writeAll("option");
                for (vals) |v| {
                    try l.config_lines.writer.writeByte(' ');
                    try canon.value(&l.config_lines.writer, v);
                }
                try l.config_lines.writer.writeByte('\n');
            } else if (top and k == l.r.ic) {
                try l.ic_args.append(l.arena, try l.cardArgs(c));
            } else if (top and k == l.r.nodeset) {
                try l.nodeset_args.append(l.arena, try l.cardArgs(c));
            } else if (k == l.r.cond) {
                const scope = frame.scopes[frame.scopes.len - 1];
                for (try l.taken(c, scope)) |b| try l.walkOne(b, frame, top);
            }
        }
    }

    fn walkOne(l: *L, card: u32, frame: *const Frame, top: bool) Error!void {
        const k = l.kind(card);
        if (k == l.r.element) return l.element(card, frame);
        if (k == l.r.model and top) return l.model(card, frame);
        if (k == l.r.analysis and top) return l.analysis(card);
        if (k == l.r.cond) {
            const scope = frame.scopes[frame.scopes.len - 1];
            for (try l.taken(card, scope)) |b| try l.walkOne(b, frame, top);
        }
    }

    // Values ---------------------------------------------------------------

    /// A number field's value: mantissa and exponent, then the scale.
    fn number(l: *const L, row: u32) f64 {
        const m = l.text(l.t.child(row, l.r.mantissa).?);
        const whole = l.text(row);
        const neg = whole[0] == '-';
        var e: i32 = 0;
        if (l.t.child(row, l.r.exponent)) |x| {
            const xs = l.text(x)[1..];
            e = std.fmt.parseInt(i32, xs, 10) catch if (xs[0] == '-') -400 else 400;
        }
        var mant = std.fmt.parseFloat(f64, m) catch unreachable;
        if (l.t.child(row, l.r.scale)) |s| {
            const st = l.text(s);
            if (std.mem.eql(u8, st, "meg")) {
                e += 6;
            } else if (std.mem.eql(u8, st, "mil")) {
                e -= 6;
                mant *= 25.4;
            } else e += switch (st[0]) {
                't' => 12,
                'g' => 9,
                'x' => 6,
                'k' => 3,
                'm' => -3,
                'u' => -6,
                'n' => -9,
                'p' => -12,
                'f' => -15,
                'a' => -18,
                else => unreachable,
            };
        }
        const v = mant * std.math.pow(f64, 10, @floatFromInt(e));
        return if (neg) -v else v;
    }

    /// A positional field as the frontend reads it (`valueAt`): a number, a
    /// word (substituted when `subst` and a scope defines it), an
    /// expression, or `name(args)`.
    fn field(l: *L, row: u32, frame: *const Frame, subst: bool) Error!Value {
        const k = l.kind(row);
        if (k == l.r.word) {
            if (l.t.child(row, l.r.number)) |n| return .{ .num = l.number(n) };
            const w = l.text(row);
            if (subst) if (find(frame.scopes, w) != null) return l.refValue(w, frame);
            return .{ .name = w };
        }
        if (k == l.r.expr) return l.exprValue(l.t.child(row, l.r.ternary).?, frame);
        if (k == l.r.str) return .{ .name = l.text(row) };
        if (k == l.r.group) {
            var it = l.t.children(row);
            const head = it.next().?;
            const name = l.text(head);
            const probe = std.mem.eql(u8, name, "v") or std.mem.eql(u8, name, "i");
            var vals: std.ArrayList(Value) = .empty;
            while (it.next()) |a| try vals.append(l.arena, if (probe and l.kind(a) == l.r.word) .{ .name = l.text(a) } else try l.field(a, frame, subst));
            // HSPICE SFFM is (VO VA FC MDI FS), the source models read
            // ngspice's (VO VA FM MDI FC): MDI defaults to 0, FS to -1
            // (their 5/TSTOP), then FC and FS trade places.
            if (l.dialect == .hspice and vals.items.len > 2 and std.mem.eql(u8, name, "sffm")) {
                if (vals.items.len == 3) try vals.append(l.arena, .{ .num = 0 });
                if (vals.items.len == 4) try vals.append(l.arena, .{ .num = -1 });
                std.mem.swap(Value, &vals.items[2], &vals.items[4]);
            }
            return .{ .group = .{ .name = name, .args = vals.items } };
        }
        if (k == l.r.pair) return error.Refused;
        if (k == l.vec) {
            var vals: std.ArrayList(Value) = .empty;
            var it = l.t.children(row);
            while (it.next()) |a| try vals.append(l.arena, try l.field(a, frame, subst));
            return .{ .group = .{ .name = "", .args = vals.items } };
        }
        // An unbraced expression where a field stands (a pair's value only).
        if (k == l.r.ternary) return l.exprValue(row, frame);
        return .{ .name = l.text(row) };
    }

    /// A `key=value` value as the frontend reads it (`kvValue`).
    fn pairValue(l: *L, row: u32, frame: *const Frame) Error!Value {
        const k = l.kind(row);
        if (k == l.r.path) return .{ .name = std.mem.trim(u8, l.text(row), "\"'") };
        // `key="x"`: the frontend reads the quotes as a parenthesis.
        if (k == l.r.str) return .{ .name = l.text(row)[1 .. l.text(row).len - 1] };
        if (k == l.r.ternary) {
            if (single(l, row, l.r.ref)) |ref| {
                const w = l.text(ref);
                return if (find(frame.scopes, w) != null) l.refValue(w, frame) else .{ .name = w };
            }
            return l.exprValue(row, frame);
        }
        return l.field(row, frame, true);
    }

    /// The lone atom of rule `want` an expression tree is, or null.
    fn single(l: *const L, row: u32, want: peg.RuleId) ?u32 {
        var at = row;
        while (true) {
            if (l.kind(at) == want) return at;
            var it = l.t.children(at);
            const first = it.next() orelse return null;
            if (it.next() != null) return null;
            at = first;
        }
    }

    fn refValue(l: *L, name: []const u8, frame: *const Frame) Error!Value {
        const v = l.evalRef(name, frame.scopes, 0) orelse return .{ .expr = .{} };
        return .{ .num = v };
    }

    fn exprValue(l: *L, row: u32, frame: *const Frame) Error!Value {
        const v = l.eval(row, frame.scopes, 0) orelse return .{ .expr = .{} };
        return .{ .num = v };
    }

    fn find(scopes: []const *const Scope, name: []const u8) ?struct { def: Def, level: usize } {
        var i = scopes.len;
        while (i > 0) {
            i -= 1;
            if (scopes[i].get(name)) |d| return .{ .def = d, .level = i };
        }
        return null;
    }

    /// A parameter's value, read in the scope that defined it.
    fn evalRef(l: *L, name: []const u8, scopes: []const *const Scope, depth: u32) ?f64 {
        if (depth > 64) return null;
        const hit = find(scopes, name) orelse return null;
        const inner, const row = switch (hit.def) {
            .num => |v| return v,
            .row => |row| .{ scopes[0 .. hit.level + 1], row },
            .caller => |c| .{ c.scopes, c.row },
        };
        const k = l.kind(row);
        const saved = l.bindings;
        l.bindings = .empty;
        defer l.bindings = saved;
        if (k == l.r.ternary) return l.eval(row, inner, depth + 1);
        if (k == l.r.expr) return l.eval(l.t.child(row, l.r.ternary).?, inner, depth + 1);
        if (k == l.r.word) {
            if (l.t.child(row, l.r.number)) |n| return l.number(n);
            return l.evalRef(l.text(row), inner, depth + 1);
        }
        return null;
    }

    /// Folds an expression tree to a number, or null when it reads a name
    /// no scope defines, a node, or a function the oracle does not know.
    fn eval(l: *L, row: u32, scopes: []const *const Scope, depth: u32) ?f64 {
        if (depth > peg.depth_max) return null;
        const k = l.kind(row);
        const r = l.r;
        var it = l.t.children(row);
        if (k == r.ternary) {
            const c = l.eval(it.next().?, scopes, depth + 1) orelse return null;
            const a = it.next() orelse return c;
            const b = it.next().?;
            return if (c != 0) l.eval(a, scopes, depth + 1) else l.eval(b, scopes, depth + 1);
        }
        if (k == r.@"or" or k == r.@"and" or k == r.cmp or k == r.add or k == r.mul or k == r.pow) {
            var acc = l.eval(it.next().?, scopes, depth + 1) orelse return null;
            while (it.next()) |op| {
                const rhs = l.eval(it.next().?, scopes, depth + 1) orelse return null;
                acc = binary(l.text(op), acc, rhs) orelse return null;
            }
            return acc;
        }
        if (k == r.unary) {
            const first = it.next().?;
            const operand = it.next() orelse return l.eval(first, scopes, depth + 1);
            const op = l.text(first);
            const v = l.eval(operand, scopes, depth + 1) orelse return null;
            return switch (op[0]) {
                '-' => -v,
                '+' => v,
                '!' => if (v == 0) 1 else 0,
                else => null,
            };
        }
        if (k == r.paren) return l.eval(it.next().?, scopes, depth + 1);
        if (k == r.num) return l.numText(l.text(row));
        if (k == r.ref) {
            const name = l.text(row);
            var b = l.bindings.items.len;
            while (b > 0) {
                b -= 1;
                if (std.mem.eql(u8, l.bindings.items[b].name, name)) return l.bindings.items[b].value;
            }
            return l.evalRef(name, scopes, depth + 1);
        }
        if (k == r.call) {
            const name = l.text(it.next().?);
            var vals: [8]f64 = undefined;
            var n: usize = 0;
            while (it.next()) |a| {
                if (n == vals.len) return null;
                vals[n] = l.eval(a, scopes, depth + 1) orelse return null;
                n += 1;
            }
            // HSPICE optimization: `p = optname(init, lo, hi[, dels])` and
            // `optrange(...)` hold their initial value until the fit runs.
            if (n >= 3 and (std.mem.eql(u8, name, "optrange") or l.opt_names.contains(name))) return vals[0];
            if (call(name, vals[0..n])) |v| return v;
            // A user function: its body with each formal bound to its value.
            const func = l.funcs.get(name) orelse return null;
            if (func.formals.len != n) return null;
            const outer = l.bindings.items.len;
            defer l.bindings.shrinkRetainingCapacity(outer);
            for (func.formals, vals[0..n]) |f, v| l.bindings.append(l.arena, .{ .name = f, .value = v }) catch return null;
            const body = func.body;
            const bk = l.kind(body);
            return l.eval(if (bk == l.r.expr) l.t.child(body, l.r.ternary).? else body, scopes, depth + 1);
        }
        return null; // a probe: a node or device value, known only at run time
    }

    /// A number literal, read as the frontend reads one in this dialect.
    fn numText(l: *const L, s: []const u8) ?f64 {
        return switch (l.dialect) {
            .ngspice => netlist.lines.ngspice.parseNum(s),
            .hspice => netlist.lines.hspice.parseNum(s),
            .spectre => netlist.lines.spectre.parseNum(s),
        };
    }

    fn binary(op: []const u8, a: f64, b: f64) ?f64 {
        const t = struct {
            fn b2f(x: bool) f64 {
                return if (x) 1 else 0;
            }
        };
        if (std.mem.eql(u8, op, "||")) return t.b2f(a != 0 or b != 0);
        if (std.mem.eql(u8, op, "&&")) return t.b2f(a != 0 and b != 0);
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) return t.b2f(a == b);
        if (std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<>")) return t.b2f(a != b);
        if (std.mem.eql(u8, op, "<=")) return t.b2f(a <= b);
        if (std.mem.eql(u8, op, ">=")) return t.b2f(a >= b);
        if (std.mem.eql(u8, op, "**")) return power(a, b);
        return switch (op[0]) {
            '<' => t.b2f(a < b),
            '>' => t.b2f(a > b),
            '+' => a + b,
            '-' => a - b,
            '*' => a * b,
            '/' => a / b,
            '%' => a - b * @trunc(a / b),
            '\\' => @trunc(@abs(a / b)),
            '^' => power(a, b),
            else => null,
        };
    }

    /// numparam's default `^` (§2.2): pow(|x|, y).
    fn power(a: f64, b: f64) f64 {
        return std.math.pow(f64, @abs(a), b);
    }

    /// To the nearest integer, a half to the even one (numparam `nint`).
    fn halfEven(x: f64) f64 {
        const r = @round(x);
        if (@abs(x - @trunc(x)) != 0.5) return r;
        return if (@mod(r, 2) == 0) r else r - std.math.sign(x);
    }

    /// numparam's built-in functions (§2.2, `xpressn.c:fmathS`); the
    /// distributions fold to their nominal, the first argument.
    fn call(name: []const u8, a: []const f64) ?f64 {
        const one = struct {
            fn f(n: []const u8, x: f64) ?f64 {
                const m = std.math;
                const table = .{
                    .{ "sqr", x * x },   .{ "sqrt", @sqrt(x) },                       .{ "sin", @sin(x) },      .{ "cos", @cos(x) },
                    .{ "exp", @exp(x) }, .{ "ln", @log(x) },                          .{ "log", @log(x) },      .{ "log10", @log10(x) },
                    .{ "arctan", m.atan(x) }, .{ "atan", m.atan(x) },                 .{ "abs", @abs(x) },      .{ "int", @trunc(x) },
                    .{ "nint", halfEven(x) }, .{ "sinh", m.sinh(x) },                   .{ "cosh", m.cosh(x) },   .{ "tanh", m.tanh(x) },
                    .{ "sgn", m.sign(x) }, .{ "ceil", @ceil(x) },                     .{ "floor", @floor(x) },  .{ "asin", m.asin(x) },
                    .{ "acos", m.acos(x) }, .{ "asinh", m.asinh(x) },                 .{ "acosh", m.acosh(x) }, .{ "atanh", m.atanh(x) },
                    .{ "tan", @tan(x) },
                };
                inline for (table) |e| if (std.mem.eql(u8, n, e[0])) return e[1];
                return null;
            }
        };
        if (a.len == 1) if (one.f(name, a[0])) |v| return v;
        if (a.len == 2) {
            if (std.mem.eql(u8, name, "pow")) return power(a[0], a[1]);
            if (std.mem.eql(u8, name, "pwr")) return std.math.pow(f64, @abs(a[0]), a[1]);
            if (std.mem.eql(u8, name, "min")) return @min(a[0], a[1]);
            if (std.mem.eql(u8, name, "max")) return @max(a[0], a[1]);
        }
        if (a.len == 3 and std.mem.eql(u8, name, "ternary_fcn")) return if (a[0] != 0) a[1] else a[2];
        for ([_][]const u8{ "agauss", "gauss", "unif", "aunif", "limit" }) |d|
            if (std.mem.eql(u8, name, d) and a.len >= 2) return a[0];
        return null;
    }

    // Cards ---------------------------------------------------------------

    /// The fields of a card, without its leading `skip` children, as
    /// values the way `readArgs` reads them: pairs flatten to key and value,
    /// and words are not substituted.
    fn cardArgs(l: *L, card: u32) Error![]const Value {
        const top: Frame = .{ .scopes = &.{&l.globals} };
        var out: std.ArrayList(Value) = .empty;
        var it = l.t.children(card);
        while (it.next()) |c| {
            const k = l.kind(c);
            if (k == l.r.kind) continue;
            if (k == l.r.pair) {
                var p = l.t.children(c);
                try out.append(l.arena, .{ .name = l.text(p.next().?) });
                try out.append(l.arena, try l.rawField(p.next().?, &top));
            } else try out.append(l.arena, try l.rawField(c, &top));
        }
        return out.items;
    }

    /// A field read by `valueAt` with no substitution: an unbraced
    /// expression is a single word to it.
    fn rawField(l: *L, row: u32, frame: *const Frame) Error!Value {
        if (l.kind(row) == l.r.ternary) {
            const t = l.text(row);
            return if (l.numText(t)) |n| .{ .num = n } else .{ .name = t };
        }
        return l.field(row, frame, false);
    }

    fn analysis(l: *L, card: u32) Error!void {
        const kind_text = l.text(l.t.child(card, l.r.kind).?);
        return l.analysisAs(card, analysisName(kind_text) orelse return error.Refused);
    }

    /// An analysis card as the frontend keeps it: its sweep tail (`SWEEP
    /// ...`, a bare `DATA=`/`MONTE=` on `.dc`, HSPICE's `.dc param ...`)
    /// split off to a marker, and a `.four` naming several outputs split
    /// into one card per output.
    fn analysisAs(l: *L, card: u32, name: []const u8) Error!void {
        var a = try l.cardArgs(card);
        var swept = false;
        for (a, 0..) |v, i| if (v == .name and std.mem.eql(u8, v.name, "sweep")) {
            a = a[0..i];
            swept = true;
            break;
        };
        const dc = std.mem.eql(u8, name, "dc");
        if (!swept and dc and a.len >= 2 and a[0] == .name and (std.mem.eql(u8, a[0].name, "data") or std.mem.eql(u8, a[0].name, "monte"))) {
            a = a[0..0];
            swept = true;
        }
        if (!swept and dc and a.len == 4 and a[0] == .name and l.globals.contains(a[0].name)) {
            a = a[0..0];
            swept = true;
        }
        const w = &l.analysis_lines.writer;
        var outputs: usize = 0;
        if (std.mem.eql(u8, name, "four")) for (a) |v| {
            if (v == .group) outputs += 1;
        };
        if (outputs >= 2) {
            for (a[1..]) |out| {
                if (out != .group) continue;
                try w.writeAll("analysis four ");
                try canon.value(w, a[0]);
                try w.writeByte(' ');
                try canon.value(w, out);
                for (a[1..]) |v| if (v != .group) {
                    try w.writeByte(' ');
                    try canon.value(w, v);
                };
                try w.writeByte('\n');
            }
        } else if (std.mem.eql(u8, name, "temp") and a.len > 1 and l.dialect == .hspice) {
            // HSPICE `.temp t1 t2 ...` lists run temperatures, not a sweep.
        } else {
            try w.print("analysis {s}", .{name});
            for (a) |v| {
                try w.writeByte(' ');
                try canon.value(w, v);
            }
            if (swept) try w.writeAll(" sweep");
            try w.writeByte('\n');
        }
        if (std.mem.eql(u8, name, "temp") and (a.len == 1 or (a.len > 1 and l.dialect == .hspice))) {
            try l.config_lines.writer.writeAll("temp");
            for (a) |v| {
                try l.config_lines.writer.writeByte(' ');
                try canon.value(&l.config_lines.writer, v);
            }
            try l.config_lines.writer.writeByte('\n');
        }
    }

    /// The query kind an analysis card word names (netlist.zig `cards`).
    fn analysisName(word: []const u8) ?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "acphasenoise", "noise" }, .{ "envlp", "envelope" }, .{ "hbosc", "hb" }, .{ "snosc", "pss" },
            .{ "montecarlo", "mc" },       .{ "sn", "pss" },         .{ "snac", "pac" }, .{ "snnoise", "pnoise" },
            .{ "snxf", "pxf" },            .{ "ptdnoise", "pnoise" }, .{ "trannoise", "tran_noise" }, .{ "lin", "sp" },
            .{ "net", "sp" },
        });
        return map.get(word) orelse word;
    }

    /// A `.model` card's values as the frontend keeps them: `key=value`
    /// pairs, positional values under an empty key, and a CPL or W
    /// model's matrix entries one blank-separated number each (`LPair`).
    fn modelValues(l: *L, card: u32, frame: *const Frame) Error![]const Kv {
        var it = l.t.children(card);
        _ = it.next(); // name
        _ = it.next(); // type
        var out: std.ArrayList(Kv) = .empty;
        l.in_card = true;
        defer l.in_card = false;
        while (it.next()) |c| {
            const k = l.kind(c);
            if (k == l.r.pair or k == l.r.lpair) {
                var p = l.t.children(c);
                const key = l.text(p.next().?);
                // HSPICE `DEV[/dist]=` and `LOT[/dist]=` tolerances on the
                // value before them are Monte Carlo variations, not
                // parameters (hspice-syntax.md D2).
                if (isTolerance(key)) continue;
                const vrow = p.next().?;
                try out.append(l.arena, .{ .key = key, .value = if (k == l.r.lpair) try l.field(vrow, frame, true) else try l.pairValue(vrow, frame) });
            } else try out.append(l.arena, .{ .key = "", .value = try l.field(c, frame, true) });
        }
        return out.items;
    }

    fn isTolerance(key: []const u8) bool {
        inline for (.{ "dev", "lot" }) |t| if (std.mem.eql(u8, key, t) or (std.mem.startsWith(u8, key, t) and key.len > 3 and key[3] == '/')) return true;
        return false;
    }

    fn model(l: *L, card: u32, frame: *const Frame) Error!void {
        var it = l.t.children(card);
        const name = l.text(it.next().?);
        // The first definition of a name is the one it resolves to.
        const gop = try l.printed_models.getOrPut(l.arena, name);
        if (gop.found_existing) return;
        const type_word = l.text(it.next().?);
        const w = &l.model_lines.writer;
        try w.print("model {s} {s}", .{ name, type_word });
        const kvs = try l.modelValues(card, frame);
        if (kvs.len > 0) {
            try w.writeAll(" {");
            for (kvs, 0..) |kv, i| {
                if (i > 0) try w.writeByte(' ');
                try w.print("{s}=", .{kv.key});
                try canon.value(w, kv.value);
            }
            try w.writeByte('}');
        }
        try w.writeByte('\n');
    }

    /// The nodes a card of `letter` takes before its model or values, per
    /// dev/research/ngspice-syntax.md §3.1; `words` are its leading
    /// positional words. Model-named nodes are resolved by lookup.
    fn nodeCount(l: *L, letter: u8, words: []const []const u8, frame: *const Frame) usize {
        // A behavioural E/F/G/H names its form where its control nodes
        // would stand (§3.2): two nodes, then the form.
        if (std.mem.indexOfScalar(u8, "efgh", letter) != null and words.len > 2 and isForm(words[2])) return 2;
        if (l.dialect == .hspice) switch (letter) {
            // HSPICE S and W elements (S-parameter block, lossy line): every
            // word on the card is a node (hspice-syntax.md §4).
            's', 'w' => return words.len,
            // A P port is `p n` or, with a third word that names no source
            // keyword, the mixed-mode `p n ref` [SA Ch.17].
            'p' => return if (words.len >= 3 and !isPortWord(words[2])) 3 else 2,
            else => {},
        };
        return switch (letter) {
            'r', 'c', 'l', 'v', 'i', 'b', 'f', 'h' => 2,
            'k' => 0,
            'w' => 2,
            'j', 'z', 'u' => 3,
            'e', 'g', 's', 't', 'o', 'y' => 4,
            // The first word at or past the minimum that names a model.
            'd' => l.firstModel(words, 2, frame) orelse 2,
            'q' => l.firstModel(words, 3, frame) orelse 3,
            'm' => l.firstModel(words, 3, frame) orelse 4,
            // X, N, A, P and the rest: every word but the last.
            else => if (words.len > 0) words.len - 1 else 0,
        };
    }

    fn isPortWord(word: []const u8) bool {
        const port_words = [_][]const u8{ "dc", "ac", "hb", "hbac", "pulse", "sin", "exp", "pwl", "sffm", "am", "lfsr", "pat", "distof1", "distof2" };
        for (port_words) |p| if (std.mem.eql(u8, word, p)) return true;
        return false;
    }

    fn isForm(word: []const u8) bool {
        for (forms) |f| if (std.mem.eql(u8, word, f)) return true;
        return false;
    }

    const forms = [_][]const u8{ "poly", "value", "vol", "cur", "table", "laplace", "pole", "freq", "vcr", "vccap", "delay", "pwl", "vcvs", "vccs", "ccvs", "cccs", "opamp", "npwl", "ppwl", "and", "nand", "or", "nor", "transformer" };

    fn firstModel(l: *L, words: []const []const u8, min: usize, frame: *const Frame) ?usize {
        var i = min;
        while (i < words.len) : (i += 1) if (l.isModel(words[i], frame)) return i;
        return null;
    }

    fn modelName(l: *const L, row: u32) []const u8 {
        return l.text(l.t.child(row, l.r.name).?);
    }

    fn isModel(l: *const L, name: []const u8, frame: *const Frame) bool {
        for (frame.locals) |m| if (std.mem.eql(u8, l.modelName(m), name) or isBinOf(l.modelName(m), name)) return true;
        for (l.global_models.items) |m| if (std.mem.eql(u8, l.modelName(m), name) or isBinOf(l.modelName(m), name)) return true;
        return false;
    }

    /// `model` is a bin of `base`: `base.<digits>` (§4.1, binning).
    fn isBinOf(model_name: []const u8, base: []const u8) bool {
        if (model_name.len <= base.len + 1 or !std.mem.startsWith(u8, model_name, base) or model_name[base.len] != '.') return false;
        _ = std.fmt.parseInt(u32, model_name[base.len + 1 ..], 10) catch return false;
        return true;
    }

    /// The bin of `base` an M card of length `len` and width `width` takes:
    /// the last-declared one whose `lmin lmax wmin wmax` hold it, each
    /// within 1 nm (§4.1, ngspice INPgetModBin; ESPice searches a
    /// subcircuit's own bins before the global ones).
    fn binOf(l: *L, base: []const u8, len: f64, width: f64, frame: *const Frame) Error!?[]const u8 {
        const top: Frame = .{ .scopes = &.{&l.globals} };
        inline for (.{ true, false }) |local| {
            const rows = if (local) frame.locals else l.global_models.items;
            const at: *const Frame = if (local) frame else &top;
            var found: ?[]const u8 = null;
            var any = false;
            for (rows) |m| {
                const mname = l.modelName(m);
                if (std.mem.eql(u8, mname, base)) return null; // a model of that very name
                if (!isBinOf(mname, base)) continue;
                any = true;
                const kv = try l.modelValues(m, at);
                const b = [4]?f64{ kvNumber(kv, "lmin"), kvNumber(kv, "lmax"), kvNumber(kv, "wmin"), kvNumber(kv, "wmax") };
                if (b[0] == null or b[1] == null or b[2] == null or b[3] == null) continue;
                if (within(len, b[0].?, b[1].?) and within(width, b[2].?, b[3].?)) found = mname;
            }
            if (any) return found orelse error.Refused;
        }
        return null;
    }

    fn within(v: f64, lo: f64, hi: f64) bool {
        return @abs(v - lo) < 1e-9 or @abs(v - hi) < 1e-9 or (v > lo and v < hi);
    }

    fn kvNumber(kv: []const Kv, key: []const u8) ?f64 {
        for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
            .num => |n| n,
            else => null,
        };
        return null;
    }

    fn net(l: *L, frame: *const Frame, node: []const u8) Error![]const u8 {
        const n = try l.netName(frame, node);
        if (!l.nets.contains(n)) try l.net_order.append(l.arena, n);
        try l.nets.put(l.arena, n, {});
        return n;
    }

    fn netName(l: *L, frame: *const Frame, node: []const u8) Error![]const u8 {
        // Ground prints as `0` whatever names it in this dialect.
        if (netlist.isGround(l.dialect, node)) return "0";
        const path = frame.path orelse return l.aliases.get(node) orelse node;
        for (frame.ports, frame.actuals) |p, a| if (std.mem.eql(u8, p, node)) return a;
        if (l.global_nets.contains(node)) return node;
        return std.mem.concat(l.arena, u8, &.{ path, ".", node });
    }

    fn element(l: *L, card: u32, frame: *const Frame) Error!void {
        var it = l.t.children(card);
        const head = l.text(it.next().?);
        const letter = l.kinds.get(l.t.rows[card].start) orelse head[0];
        var fields: std.ArrayList(u32) = .empty;
        while (it.next()) |c| try fields.append(l.arena, c);
        // The leading words, the candidates for nodes.
        var words: std.ArrayList([]const u8) = .empty;
        for (fields.items) |f| {
            if (l.kind(f) != l.r.word) break;
            try words.append(l.arena, l.text(f));
        }
        if (letter == 'x') return l.instance(head, fields.items, words.items, frame);
        // HSPICE reads B and U as IBIS buffers and lumped lines, which
        // ESPice does not build.
        if (l.dialect == .hspice and (letter == 'b' or letter == 'u')) return error.Refused;
        const flat = if (frame.path) |p| try std.mem.concat(l.arena, u8, &.{ &.{letter}, ".", p, ".", head }) else head;
        const n = @min(l.nodeCount(letter, words.items, frame), words.items.len);
        var pins: std.ArrayList([]const u8) = .empty;
        for (words.items[0..n]) |node| {
            const p = try l.net(frame, node);
            try pins.append(l.arena, p);
            try l.nets.put(l.arena, p, {});
        }
        const w = &l.out.writer;
        if (l.rewritten(letter, fields.items[n..])) {
            // LAPLACE, POLE and DELAY keep their letter and control nodes;
            // the other forms become a two-terminal B card.
            const form = if (words.items.len > 2) words.items[2] else "";
            if (std.mem.eql(u8, form, "laplace") or std.mem.eql(u8, form, "pole") or std.mem.eql(u8, form, "delay"))
                for (words.items[3..@min(5, words.items.len)]) |node| try pins.append(l.arena, try l.net(frame, node));
            try l.loose.put(l.arena, flat, {});
            try w.print("dev {s} (", .{flat});
            for (pins.items, 0..) |p, i| {
                if (i > 0) try w.writeByte(' ');
                try w.writeAll(p);
            }
            try w.writeAll(")\n");
            return;
        }
        l.in_card = true;
        defer l.in_card = false;
        var positional: std.ArrayList(Value) = .empty;
        var kvs: std.ArrayList(Kv) = .empty;
        for (fields.items[n..]) |f| {
            if (l.kind(f) == l.r.pair) {
                var p = l.t.children(f);
                const key = l.text(p.next().?);
                try kvs.append(l.arena, .{ .key = key, .value = try l.pairValue(p.next().?, frame) });
            } else try positional.append(l.arena, try l.field(f, frame, true));
        }
        if (letter == 'm') try l.mosGeometry(positional.items, kvs.items, frame);
        // A P card's `hblin=[h, s]` band is the keys `hblin_h=h hblin_s=s`
        // the builder reads.
        if (l.dialect == .hspice and letter == 'p') for (kvs.items, 0..) |kv, i| {
            if (!std.mem.eql(u8, kv.key, "hblin") or kv.value != .group or kv.value.group.args.len != 2) continue;
            const v = kv.value.group.args;
            kvs.items[i] = .{ .key = "hblin_h", .value = v[0] };
            try kvs.insert(l.arena, i + 1, .{ .key = "hblin_s", .value = v[1] });
            break;
        };
        // An HSPICE P port is a V card that `port=` numbers.
        const kind_letter: u8 = if (l.dialect == .hspice and letter == 'p') 'v' else letter;
        try w.print("dev {c} {s} (", .{ kind_letter, flat });
        for (pins.items, 0..) |p, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(p);
        }
        try w.writeByte(')');
        for (positional.items) |v| {
            try w.writeByte(' ');
            try canon.value(w, v);
        }
        if (kvs.items.len > 0) {
            try w.writeAll(" {");
            for (kvs.items, 0..) |kv, i| {
                if (i > 0) try w.writeByte(' ');
                try w.print("{s}=", .{kv.key});
                try canon.value(w, kv.value);
            }
            try w.writeByte('}');
        }
        try w.writeByte('\n');
    }

    /// `.option scale` on an M card's lengths (areas by its square), then
    /// its model bin from the scaled L and W (W/NF under `wnflag`).
    fn mosGeometry(l: *L, positional: []Value, kvs: []Kv, frame: *const Frame) Error!void {
        const lengths = std.StaticStringMap(u2).initComptime(.{
            .{ "l", 1 },  .{ "w", 1 },  .{ "pd", 1 }, .{ "ps", 1 }, .{ "sa", 1 }, .{ "sb", 1 }, .{ "sd", 1 },
            .{ "ad", 2 }, .{ "as", 2 },
        });
        for (kvs) |*kv| {
            const dims = lengths.get(kv.key) orelse continue;
            if (kv.value == .num and l.scale != 1) kv.value.num *= if (dims == 2) l.scale * l.scale else l.scale;
        }
        if (positional.len == 0 or positional[0] != .name) return;
        const len = kvNumber(kvs, "l") orelse return;
        const nf = if (if (kvNumber(kvs, "wnflag")) |f| f != 0 else l.wnflag) kvNumber(kvs, "nf") orelse 1 else 1;
        const width = (kvNumber(kvs, "w") orelse return) / nf;
        if (try l.binOf(positional[0].name, len, width, frame)) |bin| positional[0] = .{ .name = bin };
    }

    /// True for a card the frontend builds as another device: a behavioural
    /// E/F/G/H form (§3.2), a behavioural R, or a B source, whose
    /// expression holds node probes.
    fn rewritten(l: *L, letter: u8, tail: []const u32) bool {
        if (tail.len == 0) return false;
        const first = l.text(tail[0]);
        switch (letter) {
            'e', 'f', 'g', 'h' => {
                var kids = l.t.children(tail[0]);
                const head_word = if (l.kind(tail[0]) == l.r.group) l.text(kids.next().?) else first;
                if (isForm(head_word)) return true;
                for (tail) |t| if (l.kind(t) == l.r.pair) {
                    const key = l.text(l.t.child(t, l.r.key).?);
                    for (forms) |f| if (std.mem.eql(u8, key, f)) return true;
                };
            },
            'b' => return true,
            // An HSPICE `PAT (...)` source is rewritten to the PWL that draws
            // it before the card is read (frontend/pattern.zig).
            // Parentheses are separators in HSPICE, so `pat 1 0 ...` too.
            'v', 'i' => for (tail) |t| {
                var kids = l.t.children(t);
                const head_word = if (l.kind(t) == l.r.group) l.text(kids.next().?) else l.text(t);
                if (std.mem.eql(u8, head_word, "pat")) return true;
            },
            'r' => for (tail) |t| {
                const s = l.text(t);
                for ([_][]const u8{ "v(", "i(", "time", "temper", "hertz" }) |m| if (std.mem.indexOf(u8, s, m) != null) return true;
            },
            else => {},
        }
        return false;
    }

    /// Flattens an X card: its subcircuit's statements under a child frame.
    fn instance(l: *L, head: []const u8, fields: []const u32, words: []const []const u8, frame: *const Frame) Error!void {
        if (frame.depth >= depth_max or words.len == 0) return error.Refused;
        const sname = words[words.len - 1];
        const def = l.subckts.get(sname) orelse return error.Refused;
        const ports = try l.subcktPorts(def);
        const nodes = words[0 .. words.len - 1];
        if (nodes.len != ports.len) return error.Refused;
        var actuals = try l.arena.alloc([]const u8, nodes.len);
        for (nodes, 0..) |node, i| {
            actuals[i] = try l.net(frame, node);
            try l.nets.put(l.arena, actuals[i], {});
        }
        // Shadow order: instance values, then the subcircuit's defaults (on
        // its header, and its own `.param` lines, which ngspice moves there,
        // §2.5), then the enclosing scopes. An instance value is read in the
        // caller's scope.
        const scope = try l.arena.create(Scope);
        scope.* = .empty;
        try l.defaults(def, scope);
        try l.declare(def, scope, false);
        for (fields[words.len..]) |f| if (l.kind(f) == l.r.pair) {
            var p = l.t.children(f);
            const key = l.text(p.next().?);
            const vrow = p.next().?;
            const v = try l.pairValue(vrow, frame);
            try scope.put(l.arena, key, if (v == .num) .{ .num = v.num } else .{ .caller = .{ .row = vrow, .scopes = frame.scopes } });
        };
        var locals: std.ArrayList(u32) = .empty;
        var it = l.t.children(def);
        while (it.next()) |c| if (l.kind(c) == l.r.model) try locals.append(l.arena, c);
        const scopes = try std.mem.concat(l.arena, *const Scope, &.{ frame.scopes, &.{scope} });
        const child: Frame = .{
            .path = if (frame.path) |p| try std.mem.concat(l.arena, u8, &.{ p, ".", head }) else head,
            .ports = ports,
            .actuals = actuals,
            .scopes = scopes,
            .locals = locals.items,
            .depth = frame.depth + 1,
        };
        try l.walk(def, &child, false);
    }

    fn subcktPorts(l: *L, def: u32) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = l.t.children(def);
        _ = it.next(); // name
        while (it.next()) |c| {
            if (l.kind(c) != l.r.word) break;
            try out.append(l.arena, l.text(c));
        }
        return out.items;
    }

    fn defaults(l: *L, def: u32, scope: *Scope) Error!void {
        var it = l.t.children(def);
        while (it.next()) |c| if (l.kind(c) == l.r.pair) {
            const key = l.text(l.t.child(c, l.r.key).?);
            try scope.put(l.arena, key, .{ .row = valueRow(l, c) });
        };
    }
};

/// `.ic`/`.nodeset` pairs on nets some card names: `v(net) value` or
/// `net value`, a numeric value, a net that is not ground.
fn nodeCards(l: *L) Error!void {
    const w = &l.analysis_lines.writer;
    _ = w;
    var tail: std.Io.Writer.Allocating = .init(l.arena);
    inline for (.{ .{ "ic", &l.ic_args }, .{ "nodeset", &l.nodeset_args } }) |which| {
        for (which[1].items) |a| {
            var i: usize = 0;
            while (i + 1 < a.len) : (i += 2) {
                const name: []const u8 = switch (a[i]) {
                    .group => |g| if (std.mem.eql(u8, g.name, "v") and g.args.len > 0 and g.args[0] == .name) g.args[0].name else continue,
                    .name => |n| n,
                    else => continue,
                };
                const value = switch (a[i + 1]) {
                    .num => |v| v,
                    else => continue,
                };
                if (netlist.isGroundName(name) or !l.nets.contains(name)) continue;
                try tail.writer.print("{s} {s} {e:.11}\n", .{ which[0], name, value });
            }
        }
    }
    l.ic_text = tail.written();
}
