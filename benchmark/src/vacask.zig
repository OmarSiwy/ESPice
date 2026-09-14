//! SPICE deck -> VACASK deck, so the VACASK column can answer for the whole
//! fixture suite instead of the nine decks someone hand-translated.
//!
//! VACASK reads its own netlist language, not SPICE — a different language,
//! not a dialect. For most of this suite's history that meant VACASK ran on
//! the fixtures that shipped a hand-written `vacask/runme.sim` beside
//! `circuit.sp` and skipped the other 281, so "vc" was a column that agreed
//! with us on 3% of the table and said SKIP on the rest.
//!
//! The rule this whole file is built around is TRANSLATE OR REFUSE. A card it
//! does not fully understand refuses the DECK, by name, and the fixture skips
//! with that reason printed under its row. Guessing would turn a third opinion
//! into a fourth wrong answer, and a wrong answer that RUNS is indistinguishable
//! from a right one in every column of RESULTS.md — a skip is at least legible.
//!
//! Two facts make that rule enforceable rather than aspirational:
//!
//!   1. `spice/*.osdi` is VACASK's own build of the SPICE device set: the same
//!      equations, under the same parameter names ngspice's `.model` cards
//!      take. So `.model DMOD D(IS=1e-14 N=1)` transcribes to
//!      `model dmod sp_diode (is=1e-14 n=1)` with no reinterpretation of any
//!      parameter — which is the only reason a mechanical translation can be
//!      trusted at all.
//!
//!   2. VACASK hard-errors on an unknown instance or model parameter
//!      ("Parameter 'bogusparam' not found") rather than defaulting it. A name
//!      that got past this file but does not exist over there is therefore a
//!      loud per-fixture skip carrying VACASK's own message, never a silent
//!      substitution. That is what lets the pass-through of model parameters
//!      below be a pass-through instead of a whitelist.
//!
//! Everything is lowercased on the way through. SPICE is case-insensitive and
//! VACASK is not, so `.model DMOD` and `D1 a 0 dmod` only meet if both ends
//! are folded; the runner already lowercases raw-file column names, so node
//! spelling costs nothing downstream.

const std = @import("std");

pub const Output = union(enum) {
    /// A VACASK deck, ready to write into the fixture's scratch dir.
    sim: []const u8,
    /// Why this deck has no faithful translation. Becomes the skip reason.
    refused: []const u8,
};

pub fn translate(gpa: std.mem.Allocator, spice: []const u8) error{OutOfMemory}!Output {
    var x: Xlat = .{ .gpa = gpa };
    x.run(spice) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return .{ .refused = x.reason },
    };
    return .{ .sim = try x.render() };
}

// ============================================================================
// Device modules
// ============================================================================

/// SPICE primitives VACASK ships an OSDI build of under `spice/`. The module
/// name is always `sp_<tag>` and the load path always `spice/<tag>.osdi`, which
/// is why this is an enum and not a table.
const Module = enum {
    resistor,
    capacitor,
    inductor,
    diode,
    bjt,
    jfet1,
    mes1,
    mos1,
    mos2,
    mos3,
    mos6,
    mos9,
    bsim3v3,
    bsim4v8,
    vdmos,
};

/// Devices built into the simulator: no `load`, but still a `model` line.
const Builtin = enum { vsource, isource, vcvs, vccs, cccs, ccvs, mutual };

/// R, C and L carry their value on the INSTANCE in SPICE, so most decks never
/// write a `.model` for them. VACASK has no anonymous instances — every device
/// names a model — so those decks need one synthesised. `xlat_` is reserved:
/// a deck that spells a `.model` with that prefix is refused rather than
/// silently shadowed.
const auto_prefix = "xlat_";

/// SPICE MOSFET LEVEL -> the VACASK module that implements it. A level not in
/// this map is refused: picking "the nearest model" would compare two different
/// sets of equations and report the difference as an espice error.
fn mosModule(level: u32) ?Module {
    return switch (level) {
        1 => .mos1,
        2 => .mos2,
        3 => .mos3,
        6 => .mos6,
        9 => .mos9,
        49 => .bsim3v3,
        54 => .bsim4v8,
        else => null,
    };
}

/// `.model` TYPE -> module, for the types whose parameter sets transcribe
/// name-for-name. `nmos`/`pmos` are absent on purpose: they need the LEVEL to
/// pick a module, so they are handled separately.
///
/// R, C and L model cards are absent on purpose too, and this is the one place
/// the "same parameter names" premise fails: `sp_resistor` renames the model
/// card's `tc1`/`tc2`/`r` to `model_tc1`/`model_tc2`/`model_r` to keep them
/// apart from the instance parameters of the same name. Transcribing those
/// name-for-name would set the INSTANCE parameter and quietly change the
/// device, so `.model ... R` is refused instead.
const model_types = std.StaticStringMap(struct { module: Module, type_sign: i8 }).initComptime(.{
    .{ "d", .{ .module = .diode, .type_sign = 0 } },
    .{ "npn", .{ .module = .bjt, .type_sign = 1 } },
    .{ "pnp", .{ .module = .bjt, .type_sign = -1 } },
    .{ "njf", .{ .module = .jfet1, .type_sign = 1 } },
    .{ "pjf", .{ .module = .jfet1, .type_sign = -1 } },
    .{ "nmf", .{ .module = .mes1, .type_sign = 1 } },
    .{ "pmf", .{ .module = .mes1, .type_sign = -1 } },
    .{ "vdmos", .{ .module = .vdmos, .type_sign = 1 } },
});

/// SPICE `.options` keys that only steer ngspice's own bookkeeping or printing.
/// Dropping one cannot change a number in the raw file, which is the ONLY
/// reason a key is allowed on this list — an unlisted key refuses the deck
/// rather than being dropped on the assumption that it was cosmetic too.
const cosmetic_options = std.StaticStringMap(void).initComptime(.{
    .{ "noacct", {} }, .{ "acct", {} },  .{ "list", {} },  .{ "node", {} },
    .{ "post", {} },   .{ "trans", {} }, .{ "nopage", {} }, .{ "nomod", {} },
    // Solver SELECTION, not solver tolerance: KLU and the default sparse
    // solver factor the same matrix to the same answer (docs/perf).
    .{ "klu", {} }, .{ "sparse", {} },
});

/// `.options KEY=VALUE` whose VACASK spelling is the same word and whose
/// meaning is the same quantity. Probed against the binary, not assumed.
const numeric_options = std.StaticStringMap(void).initComptime(.{
    .{ "reltol", {} }, .{ "abstol", {} }, .{ "vntol", {} },
    .{ "chgtol", {} }, .{ "gmin", {} },   .{ "temp", {} },  .{ "tnom", {} },
});

// ============================================================================
// Translator
// ============================================================================

const Fail = error{ Refused, OutOfMemory };

const Xlat = struct {
    gpa: std.mem.Allocator,
    reason: []const u8 = "",

    title: []const u8 = "translated from SPICE",
    loads: std.EnumSet(Module) = .initEmpty(),
    autos: std.EnumSet(Module) = .initEmpty(),
    auto_builtins: std.EnumSet(Builtin) = .initEmpty(),

    /// Every `.model` and `.subckt` name in the deck, collected before any card
    /// is emitted. A device card names its model positionally and SPICE lets
    /// the `.model` come after it, so this set is what tells `q1 c b e sub qmod`
    /// (four nodes) from `q1 c b e qmod 2.0` (three nodes and an area).
    names: std.StringHashMapUnmanaged(void) = .empty,

    models: std.ArrayList(u8) = .empty,
    params: std.ArrayList(u8) = .empty,
    subs: std.ArrayList(u8) = .empty,
    net: std.ArrayList(u8) = .empty,
    opts: std.ArrayList(u8) = .empty,
    ctl: std.ArrayList(u8) = .empty,

    in_subckt: bool = false,
    analyses: usize = 0,

    fn refuse(x: *Xlat, comptime fmt: []const u8, args: anytype) Fail {
        x.reason = std.fmt.allocPrint(x.gpa, fmt, args) catch "untranslatable card";
        return error.Refused;
    }

    /// Where instance lines go. A `.subckt` body must be emitted before the
    /// top-level instance that calls it, and SPICE permits the definition to
    /// come after the call.
    fn body(x: *Xlat) *std.ArrayList(u8) {
        return if (x.in_subckt) &x.subs else &x.net;
    }

    fn need(x: *Xlat, m: Module) void {
        x.loads.insert(m);
    }

    fn needAuto(x: *Xlat, m: Module) void {
        x.loads.insert(m);
        x.autos.insert(m);
    }

    fn run(x: *Xlat, spice: []const u8) Fail!void {
        var cards: std.ArrayList(Card) = .empty;
        try lex(x.gpa, spice, &x.title, &cards);

        // Pass 1: the name set. Nothing is emitted here — a device card cannot
        // be parsed at all until every model and subcircuit name is known.
        for (cards.items) |c| {
            const kw = c.tok(0) orelse continue;
            const is_model = std.mem.eql(u8, kw, ".model");
            if (!is_model and !std.mem.eql(u8, kw, ".subckt")) continue;
            const name = c.tok(1) orelse return x.refuse("{s} with no name", .{kw});
            if (std.mem.startsWith(u8, name, auto_prefix))
                return x.refuse("'{s}' collides with the translator's reserved '{s}' prefix", .{ name, auto_prefix });
            try x.names.put(x.gpa, name, {});
        }

        for (cards.items) |c| try x.card(c);
        if (x.analyses == 0) return x.refuse("no analysis card this translator understands", .{});
        if (x.in_subckt) return x.refuse(".subckt with no .ends", .{});
    }

    fn card(x: *Xlat, c: Card) Fail!void {
        const kw = c.tok(0) orelse return;
        if (kw[0] == '.') return x.dotCard(c, kw);
        return x.device(c, kw);
    }

    // ------------------------------------------------------------------
    // Devices
    // ------------------------------------------------------------------

    fn device(x: *Xlat, c: Card, kw: []const u8) Fail!void {
        switch (kw[0]) {
            'r' => try x.passive(c, .resistor, "r"),
            'c' => try x.passive(c, .capacitor, "c"),
            'l' => try x.passive(c, .inductor, "l"),
            'v' => try x.source(c, .vsource),
            'i' => try x.source(c, .isource),
            'd' => try x.modelled(c, 2),
            'q' => try x.modelled(c, 3), // 4th node (substrate) is optional
            'j', 'z' => try x.modelled(c, 3),
            'm' => try x.modelled(c, 4),
            'x' => try x.subcall(c),
            'e' => try x.ctlSource(c, .vcvs),
            'g' => try x.ctlSource(c, .vccs),
            'f' => try x.ctlSource(c, .cccs),
            'h' => try x.ctlSource(c, .ccvs),
            'k' => try x.mutual(c),
            else => return x.refuse("'{c}' device ({s}) has no VACASK counterpart here", .{ kw[0], kw }),
        }
    }

    /// `R1 in out 1k`, `C1 out 0 1n`, `L1 a b 1u`. The value is positional and
    /// may also be spelled `r=`/`c=`/`l=`, which is the same name VACASK uses.
    ///
    /// A model-form passive (`R1 a b RMOD 10k`) is refused: see `model_types`
    /// for why an `.model R` card cannot be transcribed name-for-name.
    fn passive(x: *Xlat, c: Card, m: Module, key: []const u8) Fail!void {
        const name = c.tok(0).?;
        const n1 = c.tok(1) orelse return x.refuse("{s}: missing nodes", .{name});
        const n2 = c.tok(2) orelse return x.refuse("{s}: missing nodes", .{name});
        const first = c.tok(3) orelse return x.refuse("{s}: missing value", .{name});
        if (x.names.contains(first)) return x.refuse("{s}: model-form {c} device", .{ name, key[0] });

        x.needAuto(m);
        const w = x.body().writer(x.gpa);
        try w.print("{s} ({s} {s}) {s}{s}", .{ name, n1, n2, auto_prefix, @tagName(m) });

        var i: usize = 3;
        if (std.mem.indexOfScalar(u8, first, '=') == null) {
            try x.value(w, key, first);
            i = 4;
        }
        while (c.tok(i)) |t| : (i += 1) try x.passiveParam(w, name, t);
        try w.writeAll("\n");
    }

    fn passiveParam(x: *Xlat, w: anytype, name: []const u8, t: []const u8) Fail!void {
        const kv = splitKv(t) orelse return x.refuse("{s}: stray field '{s}'", .{ name, t });
        // `m` is SPICE's device multiplier; VACASK spells it with the
        // Verilog-A builtin. `tc1` is the instance first-order coefficient,
        // which sp_resistor calls `tc` (`tc1` there is the MODEL card's).
        const key = if (std.mem.eql(u8, kv.key, "m"))
            "$mfactor"
        else if (std.mem.eql(u8, kv.key, "tc1"))
            "tc"
        else
            kv.key;
        try x.value(w, key, kv.val);
    }

    /// `V1 in 0 DC 10 AC 1 PULSE(0 5 1n 1n 1n 1u 2u)`. ngspice's grammar is
    /// positional-with-keywords, so this walks the tail rather than indexing it.
    fn source(x: *Xlat, c: Card, b: Builtin) Fail!void {
        const name = c.tok(0).?;
        const n1 = c.tok(1) orelse return x.refuse("{s}: missing nodes", .{name});
        const n2 = c.tok(2) orelse return x.refuse("{s}: missing nodes", .{name});

        x.auto_builtins.insert(b);
        const w = x.body().writer(x.gpa);
        try w.print("{s} ({s} {s}) {s}{s}", .{ name, n1, n2, auto_prefix, @tagName(b) });

        var i: usize = 3;
        var seen_dc = false;
        while (c.tok(i)) |t| : (i += 1) {
            if (std.mem.eql(u8, t, "dc")) {
                const v = c.tok(i + 1) orelse return x.refuse("{s}: DC with no value", .{name});
                try x.value(w, "dc", v);
                seen_dc = true;
                i += 1;
            } else if (std.mem.eql(u8, t, "ac")) {
                // `AC` alone means magnitude 1; a following number is the
                // magnitude and the one after it the phase in degrees.
                var mag: []const u8 = "1";
                if (c.tok(i + 1)) |v| if (isNumber(v)) {
                    mag = v;
                    i += 1;
                    if (c.tok(i + 1)) |p| if (isNumber(p)) {
                        try x.value(w, "phase", p);
                        i += 1;
                    };
                };
                try x.value(w, "mag", mag);
            } else if (waveform(t)) |wf| {
                i = try x.waveformArgs(w, c, i + 1, name, wf);
            } else if (splitKv(t)) |kv| {
                // ngspice also accepts `dc=V` and `ac=M` as fields.
                const key = if (std.mem.eql(u8, kv.key, "ac")) "mag" else if (std.mem.eql(u8, kv.key, "m")) "$mfactor" else kv.key;
                if (std.mem.eql(u8, key, "dc")) seen_dc = true;
                try x.value(w, key, kv.val);
            } else if (isNumber(t) and !seen_dc) {
                // The bare leading value: `V1 1 0 5` is a DC source.
                try x.value(w, "dc", t);
                seen_dc = true;
            } else {
                return x.refuse("{s}: unhandled source field '{s}'", .{ name, t });
            }
        }
        try w.writeAll("\n");
    }

    const Waveform = enum { pulse, sine, exp, pwl, fm };

    /// Argument order for each waveform, in VACASK parameter names, positional
    /// exactly as SPICE writes them. A trailing argument SPICE omits is left
    /// unset so VACASK's own default applies — writing a zero instead would be
    /// this file inventing a stimulus.
    fn waveformArgs(x: *Xlat, w: anytype, c: Card, start: usize, name: []const u8, wf: Waveform) Fail!usize {
        const order: []const []const u8 = switch (wf) {
            .pulse => &.{ "val0", "val1", "delay", "rise", "fall", "width", "period" },
            .sine => &.{ "sinedc", "ampl", "freq", "delay", "theta", "sinephase" },
            .exp => &.{ "val0", "val1", "delay", "tau1", "td2", "tau2" },
            .fm => &.{ "offset", "ampl", "freq", "modindex", "modfreq" },
            .pwl => &.{},
        };
        try w.print(" type=\"{s}\"", .{@tagName(wf)});

        if (wf == .pwl) {
            // `wave=[t0,v0,t1,v1,...]`: one list, so it is built rather than
            // walked pairwise. An odd count is a malformed PWL, not a default.
            var n: usize = 0;
            var i = start;
            try w.writeAll(" wave=[");
            while (c.tok(i)) |t| : (i += 1) {
                if (!isNumber(t)) break;
                if (n > 0) try w.writeAll(",");
                try w.writeAll(t);
                n += 1;
            }
            try w.writeAll("]");
            if (n == 0 or n % 2 != 0) return x.refuse("{s}: PWL with {d} values", .{ name, n });
            return i - 1;
        }

        var i = start;
        var n: usize = 0;
        while (c.tok(i)) |t| : (i += 1) {
            if (!isNumber(t)) break;
            if (n >= order.len) return x.refuse("{s}: {s} with more than {d} arguments", .{ name, @tagName(wf), order.len });
            try x.value(w, order[n], t);
            n += 1;
        }
        if (n < 2) return x.refuse("{s}: {s} with {d} arguments", .{ name, @tagName(wf), n });
        return i - 1;
    }

    /// `D1 a c DMOD 2.0`, `Q1 c b e SUB QMOD`, `M1 d g s b NMOS W=2u L=1u`.
    /// `min_nodes` is the arity SPICE requires; the model name is located by
    /// LOOKUP rather than by position, which is what makes the optional
    /// substrate node on a BJT unambiguous.
    fn modelled(x: *Xlat, c: Card, min_nodes: usize) Fail!void {
        const name = c.tok(0).?;
        const mi = for (1..c.len()) |i| {
            if (x.names.contains(c.tok(i).?)) break i;
        } else return x.refuse("{s}: no .model card names its model", .{name});
        const nodes = mi - 1;
        if (nodes < min_nodes or nodes > min_nodes + 1)
            return x.refuse("{s}: {d} nodes before the model name, expected {d}", .{ name, nodes, min_nodes });

        const w = x.body().writer(x.gpa);
        try w.print("{s} (", .{name});
        for (1..mi) |i| try w.print("{s}{s}", .{ if (i > 1) " " else "", c.tok(i).? });
        try w.print(") {s}", .{c.tok(mi).?});

        var i = mi + 1;
        while (c.tok(i)) |t| : (i += 1) {
            if (splitKv(t)) |kv| {
                const key = if (std.mem.eql(u8, kv.key, "m")) "$mfactor" else kv.key;
                try x.value(w, key, kv.val);
            } else if (isNumber(t) and i == mi + 1) {
                // The one positional tail SPICE gives these devices.
                try x.value(w, "area", t);
            } else if (std.mem.eql(u8, t, "off")) {
                // An OP starting hint, not a device parameter: VACASK reaches
                // the same operating point by its own homotopy.
                continue;
            } else {
                return x.refuse("{s}: unhandled field '{s}'", .{ name, t });
            }
        }
        try w.writeAll("\n");
    }

    /// `X1 in out INVERTER W=2u`. Same lookup trick as `modelled`: everything
    /// before the subcircuit name is a node.
    fn subcall(x: *Xlat, c: Card) Fail!void {
        const name = c.tok(0).?;
        const si = for (1..c.len()) |i| {
            if (x.names.contains(c.tok(i).?)) break i;
        } else return x.refuse("{s}: no .subckt card names its subcircuit", .{name});

        const w = x.body().writer(x.gpa);
        try w.print("{s} (", .{name});
        for (1..si) |i| try w.print("{s}{s}", .{ if (i > 1) " " else "", c.tok(i).? });
        try w.print(") {s}", .{c.tok(si).?});
        var i = si + 1;
        while (c.tok(i)) |t| : (i += 1) {
            const kv = splitKv(t) orelse return x.refuse("{s}: unhandled field '{s}'", .{ name, t });
            try x.value(w, kv.key, kv.val);
        }
        try w.writeAll("\n");
    }

    /// `E1 out 0 in 0 10` (voltage-controlled) and `F1 out 0 VSENSE 2`
    /// (current-controlled). VACASK's node and argument order matches SPICE's
    /// on both shapes; the current-controlled pair names its sensing device
    /// with `ctlinst` instead of taking it as a node.
    fn ctlSource(x: *Xlat, c: Card, b: Builtin) Fail!void {
        const name = c.tok(0).?;
        const voltage_controlled = b == .vcvs or b == .vccs;
        const want: usize = if (voltage_controlled) 6 else 5;
        if (c.len() != want) return x.refuse("{s}: {d} fields, expected {d} (POLY/VALUE/TABLE forms are not translated)", .{ name, c.len(), want });

        x.auto_builtins.insert(b);
        const w = x.body().writer(x.gpa);
        if (voltage_controlled) {
            try w.print("{s} ({s} {s} {s} {s}) {s}{s}", .{
                name, c.tok(1).?, c.tok(2).?, c.tok(3).?, c.tok(4).?, auto_prefix, @tagName(b),
            });
        } else {
            try w.print("{s} ({s} {s}) {s}{s} ctlinst=\"{s}\"", .{
                name, c.tok(1).?, c.tok(2).?, auto_prefix, @tagName(b), c.tok(3).?,
            });
        }
        try x.value(w, "gain", c.tok(want - 1).?);
        try w.writeAll("\n");
    }

    /// `K1 L1 L2 0.99`. VACASK's mutual inductance is a device with no nodes
    /// that names the two inductors it couples.
    fn mutual(x: *Xlat, c: Card) Fail!void {
        const name = c.tok(0).?;
        if (c.len() != 4) return x.refuse("{s}: {d} fields, expected 4", .{ name, c.len() });
        x.auto_builtins.insert(.mutual);
        const w = x.body().writer(x.gpa);
        try w.print("{s} () {s}mutual ind1=\"{s}\" ind2=\"{s}\"", .{ name, auto_prefix, c.tok(1).?, c.tok(2).? });
        try x.value(w, "k", c.tok(3).?);
        try w.writeAll("\n");
    }

    // ------------------------------------------------------------------
    // Dot cards
    // ------------------------------------------------------------------

    fn dotCard(x: *Xlat, c: Card, kw: []const u8) Fail!void {
        const tail = kw[1..];
        if (eqlAny(tail, &.{ "end", "print", "plot", "width", "probe", "save", "title" })) return;
        if (std.mem.eql(u8, tail, "model")) return x.modelCard(c);
        if (std.mem.eql(u8, tail, "subckt")) return x.subcktCard(c);
        if (std.mem.eql(u8, tail, "ends")) {
            if (!x.in_subckt) return x.refuse(".ends without .subckt", .{});
            x.in_subckt = false;
            try x.subs.appendSlice(x.gpa, "ends\n\n");
            return;
        }
        if (std.mem.eql(u8, tail, "param")) return x.paramCard(c);
        if (eqlAny(tail, &.{ "options", "option", "opt" })) return x.optionsCard(c);
        if (std.mem.eql(u8, tail, "temp")) {
            const v = c.tok(1) orelse return x.refuse(".temp with no value", .{});
            if (c.len() != 2) return x.refuse(".temp with {d} values (a temperature sweep is not one analysis)", .{c.len() - 1});
            return x.value(x.opts.writer(x.gpa), "temp", v);
        }
        if (std.mem.eql(u8, tail, "op")) return x.analysis("op", "op", "");
        if (std.mem.eql(u8, tail, "tran")) return x.tranCard(c);
        if (std.mem.eql(u8, tail, "dc")) return x.dcCard(c);
        if (std.mem.eql(u8, tail, "ac")) return x.acCard(c);
        if (std.mem.eql(u8, tail, "noise")) return x.noiseCard(c);
        return x.refuse("'{s}' has no VACASK counterpart here", .{kw});
    }

    fn modelCard(x: *Xlat, c: Card) Fail!void {
        const name = c.tok(1).?;
        const kind = c.tok(2) orelse return x.refuse(".model {s}: no type", .{name});

        var first_param: usize = 3;
        var module: Module = undefined;
        var sign: i8 = 0;
        if (eqlAny(kind, &.{ "nmos", "pmos" })) {
            // LEVEL is the module selector, not a parameter, and defaults to 1.
            var level: u32 = 1;
            for (3..c.len()) |i| {
                const kv = splitKv(c.tok(i).?) orelse continue;
                if (!std.mem.eql(u8, kv.key, "level")) continue;
                level = std.fmt.parseInt(u32, kv.val, 10) catch
                    return x.refuse(".model {s}: LEVEL={s}", .{ name, kv.val });
            }
            module = mosModule(level) orelse return x.refuse(".model {s}: MOSFET LEVEL={d} has no VACASK module", .{ name, level });
            sign = if (kind[0] == 'n') 1 else -1;
        } else if (model_types.get(kind)) |m| {
            module = m.module;
            sign = m.type_sign;
        } else {
            return x.refuse(".model {s}: type '{s}' is not translated", .{ name, kind });
        }

        x.need(module);
        const w = x.models.writer(x.gpa);
        try w.print("model {s} sp_{s} (", .{ name, @tagName(module) });
        if (sign != 0) try w.print(" type={d}", .{sign});
        for (first_param..c.len()) |i| {
            const t = c.tok(i).?;
            const kv = splitKv(t) orelse return x.refuse(".model {s}: stray field '{s}'", .{ name, t });
            if (std.mem.eql(u8, kv.key, "level")) continue;
            try x.value(w, kv.key, kv.val);
        }
        try w.writeAll(" )\n");
    }

    fn subcktCard(x: *Xlat, c: Card) Fail!void {
        if (x.in_subckt) return x.refuse("nested .subckt", .{});
        const name = c.tok(1).?;
        x.in_subckt = true;
        const w = x.subs.writer(x.gpa);
        try w.print("subckt {s}(", .{name});
        var i: usize = 2;
        var n: usize = 0;
        while (c.tok(i)) |t| : (i += 1) {
            if (splitKv(t) != null) break;
            try w.print("{s}{s}", .{ if (n > 0) " " else "", t });
            n += 1;
        }
        try w.writeAll(")\n");
        if (c.tok(i) != null) {
            try w.writeAll("  parameters");
            while (c.tok(i)) |t| : (i += 1) {
                const kv = splitKv(t) orelse return x.refuse(".subckt {s}: stray field '{s}'", .{ name, t });
                try x.value(w, kv.key, kv.val);
            }
            try w.writeAll("\n");
        }
    }

    fn paramCard(x: *Xlat, c: Card) Fail!void {
        const w = x.params.writer(x.gpa);
        try w.writeAll("parameters");
        for (1..c.len()) |i| {
            const kv = splitKv(c.tok(i).?) orelse return x.refuse(".param: stray field '{s}'", .{c.tok(i).?});
            try x.value(w, kv.key, kv.val);
        }
        try w.writeAll("\n");
    }

    fn optionsCard(x: *Xlat, c: Card) Fail!void {
        const w = x.opts.writer(x.gpa);
        for (1..c.len()) |i| {
            const t = c.tok(i).?;
            const kv = splitKv(t) orelse {
                if (cosmetic_options.has(t)) continue;
                return x.refuse(".options {s} changes the answer and has no known VACASK spelling", .{t});
            };
            if (numeric_options.has(kv.key)) {
                try x.value(w, kv.key, kv.val);
            } else if (std.mem.eql(u8, kv.key, "method")) {
                // ngspice's two integration methods, under VACASK's names.
                const m = if (std.mem.eql(u8, kv.val, "trap"))
                    "trap"
                else if (std.mem.eql(u8, kv.val, "gear"))
                    "gear2"
                else
                    return x.refuse(".options method={s}", .{kv.val});
                try w.print(" tran_method=\"{s}\"", .{m});
            } else if (cosmetic_options.has(kv.key)) {
                continue;
            } else {
                return x.refuse(".options {s}= changes the answer and has no known VACASK spelling", .{kv.key});
            }
        }
    }

    // ------------------------------------------------------------------
    // Analyses
    // ------------------------------------------------------------------

    /// One analysis, named `<kind>N`. VACASK writes one raw file per analysis
    /// named after it, so the names have to be distinct within a deck.
    fn analysis(x: *Xlat, kind: []const u8, verb: []const u8, args: []const u8) Fail!void {
        x.analyses += 1;
        try x.ctl.writer(x.gpa).print("  analysis {s}{d} {s}{s}\n", .{ kind, x.analyses, verb, args });
    }

    /// `.tran TSTEP TSTOP [TSTART [TMAX]] [UIC]`.
    fn tranCard(x: *Xlat, c: Card) Fail!void {
        const step = c.tok(1) orelse return x.refuse(".tran with no step", .{});
        const stop = c.tok(2) orelse return x.refuse(".tran with no stop time", .{});
        var args: std.ArrayList(u8) = .empty;
        const w = args.writer(x.gpa);
        try x.value(w, "step", step);
        try x.value(w, "stop", stop);

        var i: usize = 3;
        if (c.tok(i)) |tstart| if (isNumber(tstart)) {
            // TSTART delays when ngspice starts SAVING, not when it starts
            // solving. VACASK always saves from zero, so a nonzero TSTART would
            // compare two different windows of the same waveform.
            if (parseSpice(tstart) orelse 0 != 0) return x.refuse(".tran TSTART={s} has no VACASK counterpart", .{tstart});
            i += 1;
            if (c.tok(i)) |tmax| if (isNumber(tmax)) {
                try x.value(w, "maxstep", tmax);
                i += 1;
            };
        };
        while (c.tok(i)) |t| : (i += 1) {
            if (eqlAny(t, &.{ "uic", "use-initial-conditions" })) {
                try w.writeAll(" icmode=\"uic\"");
            } else return x.refuse(".tran: unhandled field '{s}'", .{t});
        }
        return x.analysis("tran", "tran", args.items);
    }

    /// `.dc SRC START STOP STEP`. VACASK has no `.dc`: a DC sweep is a `sweep`
    /// block wrapped around an operating point.
    ///
    /// `points` counts INTERVALS, not points, so `.dc V1 0 10 0.5` (21 points)
    /// is `points=20`. Off by one here and every sample lands between two of
    /// ngspice's, and the whole column reads as a phantom error.
    ///
    /// The sweep variable is named `vsweep` because VACASK identifiers cannot
    /// contain `-`: it is the same scale ngspice spells `v(v-sweep)`, and the
    /// runner's `scale_aliases` maps the one onto the other.
    fn dcCard(x: *Xlat, c: Card) Fail!void {
        if (c.len() != 5) return x.refuse(".dc with {d} fields (a nested sweep is not one analysis)", .{c.len() - 1});
        const src = c.tok(1).?;
        const from = parseSpice(c.tok(2).?) orelse return x.refuse(".dc: '{s}' is not a number", .{c.tok(2).?});
        const to = parseSpice(c.tok(3).?) orelse return x.refuse(".dc: '{s}' is not a number", .{c.tok(3).?});
        const step = parseSpice(c.tok(4).?) orelse return x.refuse(".dc: '{s}' is not a number", .{c.tok(4).?});
        if (step == 0) return x.refuse(".dc with a zero step", .{});
        const n = @round(@abs((to - from) / step));
        if (!(n >= 1) or n > 1e7) return x.refuse(".dc {s} {d} {d} {d} covers {d} intervals", .{ src, from, to, step, n });
        if (src[0] != 'v' and src[0] != 'i')
            return x.refuse(".dc sweeps '{s}', which is not an independent source", .{src});

        x.analyses += 1;
        try x.ctl.writer(x.gpa).print(
            \\  sweep vsweep instance="{s}" parameter="dc" from={s} to={s} mode="lin" points={d}
            \\    analysis dc{d} op
            \\
        , .{ src, c.tok(2).?, c.tok(3).?, n, x.analyses });
    }

    /// `.ac DEC|OCT|LIN N FSTART FSTOP`. For `dec`/`oct` SPICE's N is points
    /// per decade/octave and so is VACASK's; for `lin` SPICE's N is the TOTAL
    /// point count while VACASK counts intervals, hence the `- 1`.
    fn acCard(x: *Xlat, c: Card) Fail!void {
        if (c.len() != 5) return x.refuse(".ac with {d} fields, expected 4", .{c.len() - 1});
        const mode = c.tok(1).?;
        if (!eqlAny(mode, &.{ "dec", "oct", "lin" })) return x.refuse(".ac sweep type '{s}'", .{mode});
        const n = parseSpice(c.tok(2).?) orelse return x.refuse(".ac: '{s}' is not a number", .{c.tok(2).?});
        const points = if (std.mem.eql(u8, mode, "lin")) n - 1 else n;
        if (!(points >= 1)) return x.refuse(".ac with {d} points", .{n});
        var args: std.ArrayList(u8) = .empty;
        const w = args.writer(x.gpa);
        try x.value(w, "from", c.tok(3).?);
        try x.value(w, "to", c.tok(4).?);
        try w.print(" mode=\"{s}\" points={d}", .{ mode, points });
        return x.analysis("ac", "ac", args.items);
    }

    /// `.noise V(OUT) SRC DEC N FSTART FSTOP`.
    fn noiseCard(x: *Xlat, c: Card) Fail!void {
        // `v(out)` has already been flattened to two tokens by the lexer.
        const base: usize = if (std.mem.eql(u8, c.tok(1) orelse "", "v")) 2 else 1;
        if (c.len() != base + 5) return x.refuse(".noise with {d} fields", .{c.len() - 1});
        const out = c.tok(base).?;
        const src = c.tok(base + 1).?;
        const mode = c.tok(base + 2).?;
        if (!eqlAny(mode, &.{ "dec", "oct", "lin" })) return x.refuse(".noise sweep type '{s}'", .{mode});
        const n = parseSpice(c.tok(base + 3).?) orelse return x.refuse(".noise: '{s}' is not a number", .{c.tok(base + 3).?});
        const points = if (std.mem.eql(u8, mode, "lin")) n - 1 else n;
        if (!(points >= 1)) return x.refuse(".noise with {d} points", .{n});

        var args: std.ArrayList(u8) = .empty;
        const w = args.writer(x.gpa);
        try w.print(" out=\"{s}\" in=\"{s}\"", .{ out, src });
        try x.value(w, "from", c.tok(base + 4).?);
        try x.value(w, "to", c.tok(base + 5).?);
        try w.print(" mode=\"{s}\" points={d}", .{ mode, points });
        return x.analysis("noise", "noise", args.items);
    }

    // ------------------------------------------------------------------

    /// One ` key=value` field. Values pass through verbatim: VACASK reads
    /// SPICE's scale suffixes (`1k`, `1meg`, `1u`, `19f`) with the same
    /// meanings, verified against the binary. An expression in braces does NOT
    /// pass through, so it refuses here rather than reaching VACASK as a name.
    fn value(x: *Xlat, w: anytype, key: []const u8, v: []const u8) Fail!void {
        if (std.mem.indexOfAny(u8, v, "{}'\"") != null)
            return x.refuse("'{s}={s}': expressions are not translated", .{ key, v });
        try w.print(" {s}={s}", .{ key, v });
    }

    fn render(x: *Xlat) error{OutOfMemory}![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const w = out.writer(x.gpa);

        try w.print("{s}\n\n", .{x.title});
        try w.writeAll(
            \\// Generated from circuit.sp by benchmark/src/vacask.zig.
            \\// Hand-edit the SPICE deck, never this file.
            \\
            \\ground 0
            \\
            \\
        );

        var loads = x.loads.iterator();
        while (loads.next()) |m| try w.print("load \"spice/{s}.osdi\"\n", .{@tagName(m)});
        try w.writeAll("\n");

        var autos = x.autos.iterator();
        while (autos.next()) |m| try w.print("model {s}{s} sp_{s}\n", .{ auto_prefix, @tagName(m), @tagName(m) });
        var builtins = x.auto_builtins.iterator();
        while (builtins.next()) |b| try w.print("model {s}{s} {s}\n", .{ auto_prefix, @tagName(b), @tagName(b) });
        try w.writeAll(x.models.items);
        try w.writeAll("\n");

        try w.writeAll(x.params.items);
        if (x.params.items.len > 0) try w.writeAll("\n");
        try w.writeAll(x.subs.items);
        try w.writeAll(x.net.items);

        try w.writeAll("\ncontrol\n  options rawfile=\"binary\"");
        try w.writeAll(x.opts.items);
        try w.writeAll("\n");
        try w.writeAll(x.ctl.items);
        try w.writeAll("endc\n");
        return out.items;
    }
};

// ============================================================================
// Lexing
// ============================================================================

/// One logical SPICE card: continuations joined, comments gone, lowercased,
/// split into whitespace-delimited fields.
const Card = struct {
    fields: []const []const u8,

    fn len(c: Card) usize {
        return c.fields.len;
    }

    fn tok(c: Card, i: usize) ?[]const u8 {
        return if (i < c.fields.len) c.fields[i] else null;
    }
};

/// SPICE line 1 is ALWAYS the title, never a card, even when it looks like one.
/// After that: `*` opens a comment line, ` $ ` and ` ; ` open an inline one,
/// and `+` in column 1 continues the previous card.
///
/// `(`, `)` and `,` become whitespace. Nothing in the subset this file accepts
/// uses a paren for anything but grouping a waveform's or a `.model`'s
/// arguments, and flattening them means `PULSE(0 5 1n)`, `PULSE (0,5,1n)` and
/// `pulse 0 5 1n` all tokenize identically instead of needing three cases.
/// Spaces around `=` are eaten for the same reason: `W = 2u` is one field.
fn lex(gpa: std.mem.Allocator, spice: []const u8, title: *[]const u8, out: *std.ArrayList(Card)) error{OutOfMemory}!void {
    var joined: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, spice, '\n');
    var first = true;

    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (first) {
            first = false;
            const t = std.mem.trim(u8, std.mem.trimStart(u8, std.mem.trim(u8, raw, " \t\r"), "*"), " \t\r");
            if (t.len > 0) title.* = try gpa.dupe(u8, t);
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '+') {
            try joined.appendSlice(gpa, " ");
            try joined.appendSlice(gpa, trimmed[1..]);
            continue;
        }
        try flush(gpa, &joined, out);
        try joined.appendSlice(gpa, trimmed);
    }
    try flush(gpa, &joined, out);
}

fn flush(gpa: std.mem.Allocator, joined: *std.ArrayList(u8), out: *std.ArrayList(Card)) error{OutOfMemory}!void {
    defer joined.clearRetainingCapacity();
    if (joined.items.len == 0) return;

    // Lowercase, flatten grouping punctuation, and glue `=` to its neighbours.
    var flat: std.ArrayList(u8) = .empty;
    for (joined.items, 0..) |ch, i| {
        const c = std.ascii.toLower(ch);
        switch (c) {
            '(', ')', ',' => try flat.append(gpa, ' '),
            '=' => {
                while (flat.items.len > 0 and (flat.items[flat.items.len - 1] == ' ' or flat.items[flat.items.len - 1] == '\t'))
                    _ = flat.pop();
                try flat.append(gpa, '=');
            },
            ' ', '\t' => {
                // Only drop the space if an `=` follows it, so `a = 1` joins
                // but `a 1` does not.
                if (std.mem.indexOfNonePos(u8, joined.items, i, " \t")) |n| {
                    if (joined.items[n] == '=') continue;
                }
                try flat.append(gpa, ' ');
            },
            else => try flat.append(gpa, c),
        }
    }

    var fields: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, flat.items, " \t");
    while (it.next()) |f| try fields.append(gpa, f);
    if (fields.items.len == 0) return;
    try out.append(gpa, .{ .fields = fields.items });
}

/// ngspice ends a line at an unquoted `$` or `;` that follows whitespace (or
/// opens the line). A `$` glued to a token is left alone.
fn stripComment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, ';')) |cut| return stripDollar(line[0..cut]);
    return stripDollar(line);
}

fn stripDollar(line: []const u8) []const u8 {
    if (std.mem.trimStart(u8, line, " \t").len > 0 and std.mem.trimStart(u8, line, " \t")[0] == '*') return "";
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, i, '$')) |cut| {
        if (cut == 0 or line[cut - 1] == ' ' or line[cut - 1] == '\t') return line[0..cut];
        i = cut + 1;
    }
    return line;
}

// ============================================================================
// Field helpers
// ============================================================================

const Kv = struct { key: []const u8, val: []const u8 };

fn splitKv(t: []const u8) ?Kv {
    const cut = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    if (cut == 0 or cut + 1 == t.len) return null;
    return .{ .key = t[0..cut], .val = t[cut + 1 ..] };
}

fn eqlAny(needle: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, needle, o)) return true;
    return false;
}

fn waveform(t: []const u8) ?Xlat.Waveform {
    if (std.mem.eql(u8, t, "pulse")) return .pulse;
    if (std.mem.eql(u8, t, "sin") or std.mem.eql(u8, t, "sine")) return .sine;
    if (std.mem.eql(u8, t, "exp")) return .exp;
    if (std.mem.eql(u8, t, "pwl")) return .pwl;
    if (std.mem.eql(u8, t, "sffm")) return .fm;
    return null;
}

fn isNumber(t: []const u8) bool {
    return parseSpice(t) != null;
}

/// SPICE's number-with-scale-suffix. Only needed where this file has to COUNT
/// something (`.dc` intervals, `.ac` points) or check a value is zero; every
/// other value is handed to VACASK verbatim, which reads the same suffixes with
/// the same meanings.
///
/// `meg` before `m` matters: `1meg` is 1e6 and `1m` is 1e-3, and taking the
/// shorter match first turns a megohm into a milliohm.
fn parseSpice(t: []const u8) ?f64 {
    if (t.len == 0) return null;
    var end: usize = 0;
    while (end < t.len) : (end += 1) {
        const c = t[end];
        if (std.ascii.isDigit(c) or c == '.' or c == '+' or c == '-') continue;
        // An exponent's `e` is part of the number, not a suffix — but only
        // when a sign or digit follows it, so `1e` is still `1 exa`.
        if ((c == 'e' or c == 'E') and end + 1 < t.len and
            (std.ascii.isDigit(t[end + 1]) or t[end + 1] == '+' or t[end + 1] == '-')) continue;
        break;
    }
    const mantissa = std.fmt.parseFloat(f64, t[0..end]) catch return null;
    const suffix = t[end..];
    const scales = .{
        .{ "meg", 1e6 }, .{ "mil", 25.4e-6 },
        .{ "t", 1e12 },  .{ "g", 1e9 },      .{ "k", 1e3 },  .{ "m", 1e-3 },
        .{ "u", 1e-6 },  .{ "n", 1e-9 },     .{ "p", 1e-12 }, .{ "f", 1e-15 },
        .{ "a", 1e-18 },
    };
    inline for (scales) |s| {
        if (std.ascii.startsWithIgnoreCase(suffix, s[0])) return mantissa * s[1];
    }
    // A trailing unit (`1kohm` is caught above, `5v` here) is ignored by SPICE.
    for (suffix) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return mantissa;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn sim(spice: []const u8) ![]const u8 {
    return switch (try translate(testing.allocator, spice)) {
        .sim => |s| s,
        .refused => |r| {
            std.debug.print("unexpectedly refused: {s}\n", .{r});
            return error.Refused;
        },
    };
}

fn why(spice: []const u8) ![]const u8 {
    return switch (try translate(testing.allocator, spice)) {
        .sim => return error.UnexpectedlyTranslated,
        .refused => |r| r,
    };
}

test "the divider translates to the hand-written deck, line for line" {
    // Byte-for-byte the circuit of fixtures/op/voltage_divider, whose
    // hand-translated runme.sim this has to reproduce the MEANING of.
    const out = try sim(
        \\* DC operating-point fixture: symmetric voltage divider.
        \\Vin in 0 DC 10
        \\R1 in out 5k
        \\R2 out 0 5k
        \\.op
        \\.end
    );
    try testing.expect(std.mem.indexOf(u8, out, "vin (in 0) xlat_vsource dc=10\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "r1 (in out) xlat_resistor r=5k\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "r2 (out 0) xlat_resistor r=5k\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "load \"spice/resistor.osdi\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model xlat_resistor sp_resistor") != null);
    try testing.expect(std.mem.indexOf(u8, out, "analysis op1 op") != null);
    // The title is line 1 with its comment marker taken off, never a card.
    try testing.expect(std.mem.startsWith(u8, out, "DC operating-point fixture"));
}

test "a DC sweep counts intervals, not points" {
    // `.dc V1 0 10 0.5` is 21 ngspice samples. Emitting points=21 shifts every
    // one of them by half a step and the whole column reads as an error.
    const out = try sim(
        \\sweep
        \\V1 in 0 DC 0
        \\R1 in 0 1k
        \\.dc V1 0 10 0.5
        \\.end
    );
    try testing.expect(std.mem.indexOf(u8, out, "points=20") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sweep vsweep instance=\"v1\" parameter=\"dc\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "analysis dc1 op") != null);
}

test "AC lin counts intervals and dec counts per-decade" {
    // The asymmetry is real: SPICE's LIN N is a TOTAL and its DEC N is a rate.
    const lin = try sim(
        \\ac
        \\V1 in 0 AC 1
        \\R1 in 0 1k
        \\.ac lin 11 1 100
        \\.end
    );
    defer testing.allocator.free(lin);
    try testing.expect(std.mem.indexOf(u8, lin, "mode=\"lin\" points=10") != null);

    const dec = try sim(
        \\ac
        \\V1 in 0 AC 1
        \\R1 in 0 1k
        \\.ac dec 10 1 100
        \\.end
    );
    defer testing.allocator.free(dec);
    try testing.expect(std.mem.indexOf(u8, dec, "mode=\"dec\" points=10") != null);
    try testing.expect(std.mem.indexOf(u8, dec, "mag=1") != null);
}

test "a BJT's substrate node is optional and found by model lookup" {
    const three = try sim(
        \\bjt
        \\Q1 c b 0 QMOD
        \\V1 c 0 5
        \\R1 b 0 1k
        \\.model QMOD NPN(IS=1e-16 BF=100)
        \\.op
        \\.end
    );
    defer testing.allocator.free(three);
    try testing.expect(std.mem.indexOf(u8, three, "q1 (c b 0) qmod\n") != null);
    try testing.expect(std.mem.indexOf(u8, three, "model qmod sp_bjt ( type=1 is=1e-16 bf=100 )") != null);

    // Same card with a substrate node: `sub` is not a model name, so it is a
    // node. Positional counting alone could not tell these two apart.
    const four = try sim(
        \\bjt
        \\Q1 c b 0 sub QMOD
        \\V1 c 0 5
        \\R1 b 0 1k
        \\.model QMOD PNP(IS=1e-16)
        \\.op
        \\.end
    );
    defer testing.allocator.free(four);
    try testing.expect(std.mem.indexOf(u8, four, "q1 (c b 0 sub) qmod\n") != null);
    try testing.expect(std.mem.indexOf(u8, four, "type=-1") != null);
}

test "MOSFET LEVEL picks the module and never leaks into the parameters" {
    const out = try sim(
        \\mos
        \\M1 d g 0 0 NM W=2u L=1u
        \\V1 d 0 5
        \\V2 g 0 5
        \\.model NM NMOS(LEVEL=3 VTO=0.7 KP=2e-5)
        \\.op
        \\.end
    );
    try testing.expect(std.mem.indexOf(u8, out, "model nm sp_mos3 ( type=1 vto=0.7 kp=2e-5 )") != null);
    try testing.expect(std.mem.indexOf(u8, out, "level=") == null);
    try testing.expect(std.mem.indexOf(u8, out, "m1 (d g 0 0) nm w=2u l=1u\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "load \"spice/mos3.osdi\"") != null);

    // A level with no module is a refusal, not the nearest model: comparing
    // two different sets of equations would print the difference as our error.
    const r = try why(
        \\mos
        \\M1 d g 0 0 NM W=2u L=1u
        \\V1 d 0 5
        \\.model NM NMOS(LEVEL=1040)
        \\.op
        \\.end
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "LEVEL=1040") != null);
}

test "waveforms map positionally and stop where SPICE stopped" {
    const out = try sim(
        \\wave
        \\V1 a 0 PULSE(0 5 1n 2n 3n 10n 20n)
        \\V2 b 0 SIN(0 1 1k)
        \\V3 c 0 PWL(0 0 1n 5 2n 0)
        \\R1 a 0 1k
        \\R2 b 0 1k
        \\R3 c 0 1k
        \\.tran 1n 100n
        \\.end
    );
    try testing.expect(std.mem.indexOf(u8, out,
        "v1 (a 0) xlat_vsource type=\"pulse\" val0=0 val1=5 delay=1n rise=2n fall=3n width=10n period=20n\n") != null);
    // Three arguments given, three emitted: an omitted TD is VACASK's default,
    // not a zero this file made up.
    try testing.expect(std.mem.indexOf(u8, out,
        "v2 (b 0) xlat_vsource type=\"sine\" sinedc=0 ampl=1 freq=1k\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "type=\"pwl\" wave=[0,0,1n,5,2n,0]\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "analysis tran1 tran step=1n stop=100n") != null);
}

test "continuations, inline comments and spaced equals are one card" {
    const out = try sim(
        \\lexing
        \\V1 in 0 DC 1 $ the supply
        \\M1 d g 0 0 NM W = 2u
        \\+ L = 1u ; continued
        \\R1 d in 1k
        \\.model NM NMOS(LEVEL=1
        \\+ VTO=0.7)
        \\.op
        \\.end
    );
    try testing.expect(std.mem.indexOf(u8, out, "v1 (in 0) xlat_vsource dc=1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "m1 (d g 0 0) nm w=2u l=1u\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model nm sp_mos1 ( type=1 vto=0.7 )") != null);
}

test "subcircuits are emitted before the instances that call them" {
    const out = try sim(
        \\subckt
        \\X1 in out INV
        \\V1 in 0 1
        \\.subckt INV a b
        \\R1 a b 1k
        \\R2 b 0 1k
        \\.ends
        \\.op
        \\.end
    );
    const def = std.mem.indexOf(u8, out, "subckt inv(a b)").?;
    const call = std.mem.indexOf(u8, out, "x1 (in out) inv").?;
    try testing.expect(def < call);
    try testing.expect(std.mem.indexOf(u8, out, "ends\n") != null);
}

test "controlled sources keep SPICE's node and control order" {
    const out = try sim(
        \\ctl
        \\V1 in 0 1
        \\VS out2 0 0
        \\E1 out 0 in 0 10
        \\F1 out3 0 VS 2
        \\R1 out 0 1k
        \\R2 out3 0 1k
        \\.op
        \\.end
    );
    try testing.expect(std.mem.indexOf(u8, out, "e1 (out 0 in 0) xlat_vcvs gain=10\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "f1 (out3 0) xlat_cccs ctlinst=\"vs\" gain=2\n") != null);

    // POLY/VALUE/TABLE are a different device, not a different spelling.
    const r = try why(
        \\ctl
        \\V1 in 0 1
        \\E1 out 0 POLY(1) in 0 0 1 2
        \\R1 out 0 1k
        \\.op
        \\.end
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "POLY") != null);
}

test "options that change the answer are translated; the rest are refused" {
    const out = try sim(
        \\opts
        \\V1 in 0 1
        \\R1 in 0 1k
        \\.options noacct klu reltol=1e-4 method=gear
        \\.temp 55
        \\.op
        \\.end
    );
    try testing.expect(std.mem.indexOf(u8, out, "reltol=1e-4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tran_method=\"gear2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "temp=55") != null);
    try testing.expect(std.mem.indexOf(u8, out, "klu") == null);

    // `maxord` has no VACASK spelling. Dropping it would silently run a
    // different integration order than ngspice did.
    const r = try why(
        \\opts
        \\V1 in 0 1
        \\R1 in 0 1k
        \\.options maxord=2
        \\.op
        \\.end
    );
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "maxord") != null);
}

test "a card with no faithful translation refuses the deck by name" {
    for ([_][]const u8{
        // A behavioural source is an expression language, not a device.
        "b\nB1 out 0 V=V(in)*2\nV1 in 0 1\n.op\n.end",
        // `.model R` renames its parameters in VACASK; see model_types.
        "rmod\nR1 a 0 RM 1k\nV1 a 0 1\n.model RM R(TC1=1e-3)\n.op\n.end",
        // An analysis VACASK does not run is not an analysis it runs badly.
        "pz\nV1 in 0 1\nR1 in 0 1k\n.pz 1 0 1 0 vol pz\n.end",
        // No transitive translation: the included file is still SPICE.
        "inc\nV1 in 0 1\nR1 in 0 1k\n.include models.inc\n.op\n.end",
    }) |deck| {
        const r = try why(deck);
        defer testing.allocator.free(r);
        try testing.expect(r.len > 0);
    }
}

test "a deck with no analysis is refused rather than run empty" {
    const r = try why("empty\nV1 in 0 1\nR1 in 0 1k\n.end");
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "no analysis") != null);
}

test "scale suffixes: meg before m, and an exponent is not a suffix" {
    try testing.expectEqual(@as(?f64, 1e6), parseSpice("1meg"));
    try testing.expectEqual(@as(?f64, 1e6), parseSpice("1MEG"));
    try testing.expectEqual(@as(?f64, 1e-3), parseSpice("1m"));
    try testing.expectEqual(@as(?f64, 1e-14), parseSpice("1e-14"));
    try testing.expectEqual(@as(?f64, 5e-3), parseSpice("5mA"));
    try testing.expectEqual(@as(?f64, 1e3), parseSpice("1kohm"));
    try testing.expectEqual(@as(?f64, -5), parseSpice("-5"));
    try testing.expectEqual(@as(?f64, 0.005), parseSpice("0.005"));
    try testing.expectEqual(@as(?f64, null), parseSpice("vin"));
    try testing.expectEqual(@as(?f64, null), parseSpice(""));
}
