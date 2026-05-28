//! VACASK adapter for the benchmark: translates each SPICE fixture into
//! VACASK's own netlist language, a different language rather than a dialect.
//!
//! The rule is translate or refuse. A card this file does not fully
//! understand refuses the whole deck by name, and the fixture skips with that
//! reason under its row: a wrong translation that runs is indistinguishable
//! from a right one in the results table.
//!
//! Two facts make a mechanical translation trustworthy:
//!   1. `spice/*.osdi` is VACASK's build of the SPICE device set, with the
//!      same equations and parameter names ngspice's `.model` cards take, so
//!      `.model DMOD D(IS=1e-14 N=1)` becomes
//!      `model dmod sp_diode (is=1e-14 n=1)` unchanged.
//!   2. VACASK hard-errors on an unknown parameter instead of defaulting it,
//!      so model parameters can pass through without a whitelist.
//!
//! Everything is lowercased: SPICE is case-insensitive and VACASK is not.
//! compare.zig already lowercases raw-file column names.

const std = @import("std");
const common = @import("job.zig");
pub const version_flag = "-h";

/// Translates `netlist` into `scratch`/runme.sim and returns the job that runs
/// it there, or a refused job naming the untranslatable card. Translation is
/// not timed.
pub fn prepare(io: std.Io, a: std.mem.Allocator, bin: []const u8, netlist: []const u8, scratch: []const u8) common.Error!common.Job {
    const spice = std.Io.Dir.cwd().readFileAlloc(io, netlist, a, .limited(1 << 26)) catch return error.DeckFailed;
    const sim = switch (try translate(a, spice)) {
        .sim => |text| text,
        .refused => |reason| return .{ .refused = reason },
    };
    std.Io.Dir.cwd().createDirPath(io, scratch) catch return error.ScratchFailed;
    const path = try std.fmt.allocPrint(a, "{s}/runme.sim", .{scratch});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = sim }) catch return error.DeckFailed;
    return .{
        .argv = try a.dupe([]const u8, &.{ bin, "-se", "-sp", "runme.sim" }),
        .cwd = .{ .path = scratch },
    };
}

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

/// SPICE primitives VACASK ships as `spice/<tag>.osdi`, module `sp_<tag>`,
/// plus PSP103, which VACASK ships as `psp103v4.osdi` (module `psp103va`).
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
    psp103,

    fn osdi(m: Module) []const u8 {
        return if (m == .psp103) "psp103v4" else @tagName(m);
    }
    fn name(m: Module) []const u8 {
        return if (m == .psp103) "psp103va" else @tagName(m);
    }
    fn prefix(m: Module) []const u8 {
        return if (m == .psp103) "" else "spice/";
    }
};

/// Devices built into the simulator: no `load`, but still a `model` line.
const Builtin = enum { vsource, isource, vcvs, vccs, cccs, ccvs, mutual };

/// Prefix of the models this file synthesizes: every VACASK instance names a
/// model, while SPICE R/C/L cards and sources usually have none. A deck that
/// uses the prefix itself is refused rather than shadowed.
const auto_prefix = "xlat_";

/// SPICE MOSFET LEVEL -> VACASK module. Any other level is refused: a nearby
/// model would compare different equations.
fn mosModule(level: u32) ?Module {
    return switch (level) {
        1 => .mos1,
        2 => .mos2,
        3 => .mos3,
        6 => .mos6,
        9 => .mos9,
        49 => .bsim3v3,
        54 => .bsim4v8,
        // espice's PSP103 level (frontend/spice.zig); ngspice-45 has none.
        1040 => .psp103,
        else => null,
    };
}

const ModelType = struct { module: Module, sign: i8 };

/// `.model` TYPE -> module, valid at LEVEL 1 only. `modelCard` refuses other
/// levels: `NPN(LEVEL=4)` is VBIC and `NPN(LEVEL=8)` is HICUM, not
/// Gummel-Poon. `nmos`/`pmos` go through `mosModule` instead.
///
/// R, C and L model cards are refused: `sp_resistor` names its model
/// parameters `model_tc1`/`model_r`/..., so a name-for-name copy would set
/// the instance parameters instead.
const model_types = std.StaticStringMap(ModelType).initComptime(.{
    .{ "d", ModelType{ .module = .diode, .sign = 0 } },
    .{ "npn", ModelType{ .module = .bjt, .sign = 1 } },
    .{ "pnp", ModelType{ .module = .bjt, .sign = -1 } },
    .{ "njf", ModelType{ .module = .jfet1, .sign = 1 } },
    .{ "pjf", ModelType{ .module = .jfet1, .sign = -1 } },
    .{ "nmf", ModelType{ .module = .mes1, .sign = 1 } },
    .{ "pmf", ModelType{ .module = .mes1, .sign = -1 } },
    .{ "vdmos", ModelType{ .module = .vdmos, .sign = 1 } },
});

/// `.options` keys that cannot change a number in the raw file, so they are
/// dropped. Any unlisted key refuses the deck.
const cosmetic_options = std.StaticStringMap(void).initComptime(.{
    .{ "noacct", {} }, .{ "acct", {} },   .{ "list", {} },
    .{ "node", {} },   .{ "post", {} },   .{ "trans", {} },
    .{ "nopage", {} }, .{ "nomod", {} },  .{ "lvlcod", {} },
    // Solver selection, not tolerance: both factor the same matrix.
    .{ "klu", {} },    .{ "sparse", {} },
});

/// `.options KEY=VALUE` with the same name and meaning in VACASK, probed
/// against the binary (it rejects `itl1` and `maxord`).
const numeric_options = std.StaticStringMap(void).initComptime(.{
    .{ "reltol", {} }, .{ "abstol", {} }, .{ "vntol", {} },
    .{ "chgtol", {} }, .{ "gmin", {} },   .{ "temp", {} },
    .{ "tnom", {} },
});

const Fail = error{ Refused, OutOfMemory };
const Buf = std.ArrayList(u8);

const Xlat = struct {
    gpa: std.mem.Allocator,
    reason: []const u8 = "",

    title: []const u8 = "translated from SPICE",
    loads: std.EnumSet(Module) = .initEmpty(),
    autos: std.EnumSet(Module) = .initEmpty(),
    builtins: std.EnumSet(Builtin) = .initEmpty(),

    /// Every `.model` and `.subckt` name, collected in pass 1 because a card
    /// may precede its model. It tells `q1 c b e sub qmod` (four nodes) from
    /// `q1 c b e qmod 2.0` (three nodes and an area).
    names: std.StringHashMapUnmanaged(void) = .empty,

    models: Buf = .empty,
    params: Buf = .empty,
    subs: Buf = .empty,
    net: Buf = .empty,
    opts: Buf = .empty,
    ctl: Buf = .empty,
    /// `.save` outputs, rendered ahead of every analysis as SPICE applies them.
    saves: Buf = .empty,

    in_subckt: bool = false,
    analyses: usize = 0,

    /// Whether the deck has an `.op`, `.dc`, `.ac` or `.noise`. A source with
    /// both a DC value and a waveform is untranslatable then; see `source`.
    static_analysis: bool = false,
    /// The first `.tran` card's TSTEP and TSTOP, as written. SPICE defaults
    /// omitted PULSE times from them.
    tran_step: ?[]const u8 = null,
    tran_stop: ?[]const u8 = null,

    fn refuse(x: *Xlat, comptime fmt: []const u8, args: anytype) Fail {
        x.reason = std.fmt.allocPrint(x.gpa, fmt, args) catch "untranslatable card";
        return error.Refused;
    }

    fn put(x: *Xlat, b: *Buf, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try b.print(x.gpa, fmt, args);
    }

    fn raw(x: *Xlat, b: *Buf, text: []const u8) error{OutOfMemory}!void {
        try b.appendSlice(x.gpa, text);
    }

    /// Where instance lines go. Subcircuit bodies render before the top level,
    /// since SPICE may define one after its call.
    fn body(x: *Xlat) *Buf {
        return if (x.in_subckt) &x.subs else &x.net;
    }

    fn needAuto(x: *Xlat, m: Module) void {
        x.loads.insert(m);
        x.autos.insert(m);
    }

    fn run(x: *Xlat, spice: []const u8) Fail!void {
        var cards: std.ArrayList(Card) = .empty;
        try lex(x.gpa, spice, &x.title, &cards);

        // Pass 1 emits nothing: device cards need every model and subcircuit
        // name, and the analysis cards, before they can be translated.
        for (cards.items) |c| {
            const kw = c.tok(0) orelse continue;
            if (eqlAny(kw, &.{ ".op", ".dc", ".ac", ".noise" })) x.static_analysis = true;
            if (std.mem.eql(u8, kw, ".tran") and x.tran_step == null) {
                x.tran_step = c.tok(1);
                x.tran_stop = c.tok(2);
            }
            if (!eqlAny(kw, &.{ ".model", ".subckt" })) continue;
            const name = c.tok(1) orelse return x.refuse("{s} with no name", .{kw});
            if (std.mem.startsWith(u8, name, auto_prefix))
                return x.refuse("'{s}' collides with the translator's reserved '{s}' prefix", .{ name, auto_prefix });
            try x.names.put(x.gpa, name, {});
        }

        for (cards.items) |c| try x.card(c);
        if (x.in_subckt) return x.refuse(".subckt with no .ends", .{});
        if (x.analyses == 0) return x.refuse("no analysis card this translator understands", .{});
    }

    fn card(x: *Xlat, c: Card) Fail!void {
        const kw = c.tok(0) orelse return;
        if (kw[0] == '.') return x.dotCard(c, kw);
        return x.device(c, kw);
    }

    fn device(x: *Xlat, c: Card, kw: []const u8) Fail!void {
        switch (kw[0]) {
            'r' => try x.passive(c, .resistor, "r"),
            'c' => try x.passive(c, .capacitor, "c"),
            'l' => try x.passive(c, .inductor, "l"),
            'v' => try x.source(c, .vsource),
            'i' => try x.source(c, .isource),
            'd' => try x.modelled(c, 2),
            'q' => try x.modelled(c, 3), // the 4th node (substrate) is optional
            'j' => try x.modelled(c, 3),
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

    /// `R1 in out 1k`, `C1 out 0 1n`, `L1 a b 1u`. The value may also be
    /// `r=`/`c=`/`l=`, VACASK's names too. A model-form passive is refused
    /// (see `model_types`).
    fn passive(x: *Xlat, c: Card, m: Module, key: []const u8) Fail!void {
        const name = c.tok(0).?;
        const n1 = c.tok(1) orelse return x.refuse("{s}: missing nodes", .{name});
        const n2 = c.tok(2) orelse return x.refuse("{s}: missing nodes", .{name});
        const first = c.tok(3) orelse return x.refuse("{s}: missing value", .{name});
        if (x.names.contains(first)) return x.refuse("{s}: model-form '{s}' device", .{ name, key });

        x.needAuto(m);
        const w = x.body();
        try x.put(w, "{s} ({s} {s}) {s}{s}", .{ name, n1, n2, auto_prefix, @tagName(m) });

        var i: usize = 3;
        if (std.mem.indexOfScalar(u8, first, '=') == null) {
            try x.value(w, key, first);
            i = 4;
        }
        while (c.tok(i)) |t| : (i += 1) {
            const kv = splitKv(t) orelse return x.refuse("{s}: stray field '{s}'", .{ name, t });
            // `m` is SPICE's device multiplier, which VACASK spells with the
            // Verilog-A builtin. `tc1` is the INSTANCE first-order coefficient,
            // which sp_resistor calls `tc` (its `tc1` is the model card's).
            const k = if (std.mem.eql(u8, kv.key, "m"))
                "$mfactor"
            else if (std.mem.eql(u8, kv.key, "tc1") and m == .resistor)
                "tc"
            else
                kv.key;
            try x.value(w, k, kv.val);
        }
        try x.raw(w, "\n");
    }

    /// `V1 in 0 DC 10 AC 1 PULSE(0 5 1n 1n 1n 1u 2u)`: keywords followed by
    /// positional values, so the tail is walked rather than indexed.
    fn source(x: *Xlat, c: Card, b: Builtin) Fail!void {
        const name = c.tok(0).?;
        const n1 = c.tok(1) orelse return x.refuse("{s}: missing nodes", .{name});
        const n2 = c.tok(2) orelse return x.refuse("{s}: missing nodes", .{name});

        x.builtins.insert(b);
        const w = x.body();
        try x.put(w, "{s} ({s} {s}) {s}{s}", .{ name, n1, n2, auto_prefix, @tagName(b) });

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
                // magnitude and the one after that the phase, in degrees.
                var mag: []const u8 = "1";
                if (c.tok(i + 1)) |v| {
                    if (isNumber(v)) {
                        mag = v;
                        i += 1;
                        if (c.tok(i + 1)) |p| {
                            if (isNumber(p)) {
                                try x.value(w, "phase", p);
                                i += 1;
                            }
                        }
                    }
                }
                try x.value(w, "mag", mag);
            } else if (waveform(t)) |wf| {
                // ngspice's static analyses read a source's DC value. VACASK
                // ignores `dc` once `type=` is set and biases at the
                // waveform's t=0 value (ngspice/rtlinv's `.dc` sweep came back
                // constant). No VACASK spelling separates the two, so only a
                // transient-only deck translates.
                if (x.static_analysis)
                    return x.refuse("{s}: a {s} source cannot also hold the DC value a static analysis needs", .{ name, t });
                i = try x.waveformArgs(w, c, i + 1, name, wf);
            } else if (eqlAny(t, &.{ "distof1", "distof2" })) {
                // Distortion drive with optional magnitude and phase. Only
                // `.disto` reads it, and `.disto` is refused.
                while (c.tok(i + 1)) |v| {
                    if (!isNumber(v)) break;
                    i += 1;
                }
            } else if (splitKv(t)) |kv| {
                // ngspice also accepts `dc=V` and `ac=M` as fields.
                const k = if (std.mem.eql(u8, kv.key, "ac"))
                    "mag"
                else if (std.mem.eql(u8, kv.key, "m"))
                    "$mfactor"
                else
                    kv.key;
                if (std.mem.eql(u8, k, "dc")) seen_dc = true;
                try x.value(w, k, kv.val);
            } else if (isNumber(t) and !seen_dc) {
                // The bare leading value: `V1 1 0 5` is a DC source.
                try x.value(w, "dc", t);
                seen_dc = true;
            } else {
                return x.refuse("{s}: unhandled source field '{s}'", .{ name, t });
            }
        }
        try x.raw(w, "\n");
    }

    const Waveform = enum { pulse, sine, exp, pwl, fm };

    /// Emits a waveform's positional arguments under VACASK's names. Omitted
    /// trailing arguments stay unset so VACASK's defaults apply, except PULSE
    /// times, which take SPICE's `.tran` defaults. Returns the index of the
    /// last field consumed.
    fn waveformArgs(x: *Xlat, w: *Buf, c: Card, start: usize, name: []const u8, wf: Waveform) Fail!usize {
        try x.put(w, " type=\"{s}\"", .{@tagName(wf)});

        // VACASK parses `type="pwl" wave=[...]`, but every form tried on this
        // build aborts with "Timestep too small", and one wrote a 3.3 GB raw
        // file first.
        if (wf == .pwl)
            return x.refuse("{s}: PWL is not translated (VACASK's `type=\"pwl\"` aborts on this build)", .{name});

        const order: []const []const u8 = switch (wf) {
            .pulse => &.{ "val0", "val1", "delay", "rise", "fall", "width", "period" },
            .sine => &.{ "sinedc", "ampl", "freq", "delay", "theta", "sinephase" },
            .exp => &.{ "val0", "val1", "delay", "tau1", "td2", "tau2" },
            // The FM pedestal is `sinedc`. VACASK also accepts `offset` on an
            // fm source but ignores it (measured mean 0.0001 instead of 2).
            .fm => &.{ "sinedc", "ampl", "freq", "modindex", "modfreq" },
            .pwl => unreachable,
        };
        var i = start;
        var n: usize = 0;
        while (c.tok(i)) |t| : (i += 1) {
            if (!isNumber(t)) break;
            if (n >= order.len) return x.refuse("{s}: {s} with more than {d} arguments", .{ name, @tagName(wf), order.len });
            // SPICE's EXP TD2 is absolute; VACASK measures `td2` from
            // `delay`, so it is emitted as TD2 - TD1.
            if (wf == .exp and n == 4) {
                const td1 = parseSpice(c.tok(start + 2) orelse "0") orelse 0;
                const td2 = parseSpice(t) orelse return x.refuse("{s}: EXP TD2 '{s}' is not a number", .{ name, t });
                if (td2 < td1) return x.refuse("{s}: EXP TD2 ({s}) precedes TD1", .{ name, t });
                try x.put(w, " td2={e}", .{td2 - td1});
            } else if (wf == .sine and n == 5) {
                // VACASK accepts `sinephase` but ignores it: 0, 45 and 90
                // degrees give byte-identical output.
                return x.refuse("{s}: SIN phase ({s} deg) is accepted but ignored by VACASK", .{ name, t });
            } else {
                try x.value(w, order[n], t);
            }
            n += 1;
        }
        if (n < 2) return x.refuse("{s}: {s} with {d} arguments", .{ name, @tagName(wf), n });

        // SPICE defaults omitted PULSE times from `.tran`: TR and TF to TSTEP,
        // PW and PER to TSTOP. VACASK's own defaults (1 ns edges) disagree.
        //
        // PER is one full cycle instead of TSTOP: VACASK requires PER strictly
        // greater than TR+TF+PW, which ngspice's PER = PW = TSTOP violates, and
        // the next edge lands past TSTOP either way. The 1e-7 margin covers a
        // one-ulp difference between this sum and VACASK's.
        if (wf == .pulse and n < 7) {
            const step = x.tran_step orelse
                return x.refuse("{s}: PULSE omits a time and there is no .tran card to default it from", .{name});
            const stop = x.tran_stop orelse
                return x.refuse("{s}: PULSE omits a time and the .tran card has no stop time", .{name});
            const tstep = parseSpice(step) orelse return x.refuse("{s}: .tran step '{s}' is not a number", .{ name, step });
            const tstop = parseSpice(stop) orelse return x.refuse("{s}: .tran stop '{s}' is not a number", .{ name, stop });

            const tr = if (n > 3) parseSpice(c.tok(start + 3).?) orelse tstep else tstep;
            const tf = if (n > 4) parseSpice(c.tok(start + 4).?) orelse tstep else tstep;
            const pw = if (n > 5) parseSpice(c.tok(start + 5).?) orelse tstop else tstop;
            if (n < 4) try x.put(w, " rise={e}", .{tr});
            if (n < 5) try x.put(w, " fall={e}", .{tf});
            if (n < 6) try x.put(w, " width={e}", .{pw});
            try x.put(w, " period={e}", .{(pw + tr + tf) * (1 + 1e-7)});
        }
        return i - 1;
    }

    /// `D1 a c DMOD 2.0`, `Q1 c b 0 sub QMOD`, `M1 d g s b NM W=2u L=1u`.
    /// The model is found by name, not position, so one optional extra node
    /// (a BJT substrate) is unambiguous. `min_nodes` is SPICE's arity.
    fn modelled(x: *Xlat, c: Card, min_nodes: usize) Fail!void {
        const name = c.tok(0).?;
        const mi = for (1..c.len()) |i| {
            if (x.names.contains(c.tok(i).?)) break i;
        } else return x.refuse("{s}: no .model card names its model", .{name});
        const nodes = mi - 1;
        if (nodes < min_nodes or nodes > min_nodes + 1)
            return x.refuse("{s}: {d} nodes before the model name, expected {d}", .{ name, nodes, min_nodes });

        const w = x.body();
        try x.put(w, "{s} (", .{name});
        for (1..mi) |i| try x.put(w, "{s}{s}", .{ if (i > 1) " " else "", c.tok(i).? });
        try x.put(w, ") {s}", .{c.tok(mi).?});

        var i = mi + 1;
        while (c.tok(i)) |t| : (i += 1) {
            if (splitKv(t)) |kv| {
                const k = if (std.mem.eql(u8, kv.key, "m")) "$mfactor" else kv.key;
                try x.value(w, k, kv.val);
            } else if (isNumber(t) and i == mi + 1) {
                // The one positional tail SPICE gives these devices.
                try x.value(w, "area", t);
            } else if (std.mem.eql(u8, t, "off")) {
                // An OP starting hint, not a device parameter.
                continue;
            } else {
                return x.refuse("{s}: unhandled field '{s}'", .{ name, t });
            }
        }
        try x.raw(w, "\n");
    }

    /// `X1 in out INVERTER W=2u`. As in `modelled`, everything before the
    /// subcircuit name is a node.
    fn subcall(x: *Xlat, c: Card) Fail!void {
        const name = c.tok(0).?;
        const si = for (1..c.len()) |i| {
            if (x.names.contains(c.tok(i).?)) break i;
        } else return x.refuse("{s}: no .subckt card names its subcircuit", .{name});

        const w = x.body();
        try x.put(w, "{s} (", .{name});
        for (1..si) |i| try x.put(w, "{s}{s}", .{ if (i > 1) " " else "", c.tok(i).? });
        try x.put(w, ") {s}", .{c.tok(si).?});
        var i = si + 1;
        while (c.tok(i)) |t| : (i += 1) {
            const kv = splitKv(t) orelse return x.refuse("{s}: unhandled field '{s}'", .{ name, t });
            try x.value(w, kv.key, kv.val);
        }
        try x.raw(w, "\n");
    }

    /// `E1 out 0 in 0 10` and `F1 out 0 VSENSE 2`. Node order matches SPICE;
    /// a current-controlled source names its sensing device with `ctlinst`.
    /// POLY/VALUE/TABLE forms are refused.
    fn ctlSource(x: *Xlat, c: Card, b: Builtin) Fail!void {
        const name = c.tok(0).?;
        const vc = b == .vcvs or b == .vccs;
        const want: usize = if (vc) 6 else 5;
        if (c.len() != want)
            return x.refuse("{s}: {d} fields, expected {d} (POLY/VALUE/TABLE forms are not translated)", .{ name, c.len(), want });

        x.builtins.insert(b);
        const w = x.body();
        if (vc) {
            try x.put(w, "{s} ({s} {s} {s} {s}) {s}{s}", .{
                name, c.tok(1).?, c.tok(2).?, c.tok(3).?, c.tok(4).?, auto_prefix, @tagName(b),
            });
        } else {
            try x.put(w, "{s} ({s} {s}) {s}{s} ctlinst=\"{s}\"", .{
                name, c.tok(1).?, c.tok(2).?, auto_prefix, @tagName(b), c.tok(3).?,
            });
        }
        try x.value(w, "gain", c.tok(want - 1).?);
        try x.raw(w, "\n");
    }

    /// `K1 L1 L2 0.99`: a node-less VACASK device naming the two inductors.
    fn mutual(x: *Xlat, c: Card) Fail!void {
        const name = c.tok(0).?;
        if (c.len() != 4) return x.refuse("{s}: {d} fields, expected 4", .{ name, c.len() });
        x.builtins.insert(.mutual);
        const w = x.body();
        try x.put(w, "{s} () {s}mutual ind1=\"{s}\" ind2=\"{s}\"", .{ name, auto_prefix, c.tok(1).?, c.tok(2).? });
        try x.value(w, "k", c.tok(3).?);
        try x.raw(w, "\n");
    }

    fn dotCard(x: *Xlat, c: Card, kw: []const u8) Fail!void {
        const tail = kw[1..];
        // Listing output only; the benchmark reads the raw file.
        if (eqlAny(tail, &.{ "end", "print", "plot", "width", "probe", "title" })) return;
        if (std.mem.eql(u8, tail, "model")) return x.modelCard(c);
        if (std.mem.eql(u8, tail, "subckt")) return x.subcktCard(c);
        if (std.mem.eql(u8, tail, "ends")) {
            if (!x.in_subckt) return x.refuse(".ends without .subckt", .{});
            x.in_subckt = false;
            return x.raw(&x.subs, "ends\n\n");
        }
        if (std.mem.eql(u8, tail, "param")) return x.paramCard(c);
        if (std.mem.eql(u8, tail, "save")) return x.saveCard(c);
        if (eqlAny(tail, &.{ "options", "option", "opt" })) return x.optionsCard(c);
        if (std.mem.eql(u8, tail, "temp")) {
            if (c.len() != 2) return x.refuse(".temp with {d} values (a temperature sweep is not one analysis)", .{c.len() - 1});
            return x.value(&x.opts, "temp", c.tok(1).?);
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

        // LEVEL is the module SELECTOR, not a parameter, and defaults to 1.
        var level: u32 = 1;
        for (3..c.len()) |i| {
            const kv = splitKv(c.tok(i).?) orelse continue;
            if (!std.mem.eql(u8, kv.key, "level")) continue;
            level = std.fmt.parseInt(u32, kv.val, 10) catch
                return x.refuse(".model {s}: LEVEL={s}", .{ name, kv.val });
        }

        var module: Module = undefined;
        var sign: i8 = 0;
        if (eqlAny(kind, &.{ "nmos", "pmos" })) {
            module = mosModule(level) orelse
                return x.refuse(".model {s}: {s} LEVEL={d} has no VACASK module", .{ name, kind, level });
            sign = if (kind[0] == 'n') 1 else -1;
        } else if (model_types.get(kind)) |m| {
            // Every other type this file knows is the LEVEL 1 device. See
            // `model_types` for the VBIC-as-NPN case this refusal exists for.
            if (level != 1) return x.refuse(".model {s}: {s} LEVEL={d} has no VACASK module", .{ name, kind, level });
            module = m.module;
            sign = m.sign;
        } else {
            return x.refuse(".model {s}: type '{s}' is not translated", .{ name, kind });
        }

        x.loads.insert(module);
        const w = &x.models;
        try x.put(w, "model {s} {s}{s}", .{ name, if (module == .psp103) "" else "sp_", module.name() });

        // An empty `( )` is a VACASK syntax error, so the list is opened only
        // once there is something to put in it.
        var open = false;
        if (sign != 0) {
            try x.put(w, " ( type={d}", .{sign});
            open = true;
        }
        for (3..c.len()) |i| {
            const t = c.tok(i).?;
            const kv = splitKv(t) orelse return x.refuse(".model {s}: stray field '{s}'", .{ name, t });
            if (std.mem.eql(u8, kv.key, "level")) continue;
            if (!open) {
                try x.raw(w, " (");
                open = true;
            }
            try x.value(w, kv.key, kv.val);
        }
        try x.raw(w, if (open) " )\n" else "\n");
    }

    /// `.save v(a) i(v1)` keeps the same spelling in VACASK; `.save all`
    /// (or no card) is VACASK's default.
    /// The lexer splits `v(a)` into `v a`, so the fields come in pairs.
    fn saveCard(x: *Xlat, c: Card) Fail!void {
        if (c.len() == 2 and std.mem.eql(u8, c.tok(1).?, "all")) return;
        if (c.len() % 2 != 1) return x.refuse(".save with an odd field", .{});
        try x.raw(&x.saves, "  save");
        var i: usize = 1;
        while (i < c.len()) : (i += 2) {
            const kind = c.tok(i).?;
            if (!eqlAny(kind, &.{ "v", "i" })) return x.refuse(".save {s}(...) is not translated", .{kind});
            try x.put(&x.saves, " {s}({s})", .{ kind, c.tok(i + 1).? });
        }
        try x.raw(&x.saves, "\n");
    }

    fn subcktCard(x: *Xlat, c: Card) Fail!void {
        if (x.in_subckt) return x.refuse("nested .subckt", .{});
        const name = c.tok(1).?;
        x.in_subckt = true;
        const w = &x.subs;
        try x.put(w, "subckt {s}(", .{name});
        var i: usize = 2;
        var n: usize = 0;
        while (c.tok(i)) |t| : (i += 1) {
            if (splitKv(t) != null) break;
            try x.put(w, "{s}{s}", .{ if (n > 0) " " else "", t });
            n += 1;
        }
        try x.raw(w, ")\n");
        if (c.tok(i) != null) {
            try x.raw(w, "  parameters");
            while (c.tok(i)) |t| : (i += 1) {
                const kv = splitKv(t) orelse return x.refuse(".subckt {s}: stray field '{s}'", .{ name, t });
                try x.value(w, kv.key, kv.val);
            }
            try x.raw(w, "\n");
        }
    }

    fn paramCard(x: *Xlat, c: Card) Fail!void {
        const w = &x.params;
        try x.raw(w, "parameters");
        for (1..c.len()) |i| {
            const kv = splitKv(c.tok(i).?) orelse return x.refuse(".param: stray field '{s}'", .{c.tok(i).?});
            try x.value(w, kv.key, kv.val);
        }
        try x.raw(w, "\n");
    }

    fn optionsCard(x: *Xlat, c: Card) Fail!void {
        const w = &x.opts;
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
                try x.put(w, " tran_method=\"{s}\"", .{m});
            } else if (cosmetic_options.has(kv.key)) {
                continue;
            } else {
                return x.refuse(".options {s}= changes the answer and has no known VACASK spelling", .{kv.key});
            }
        }
    }

    /// One analysis named `<kind><N>`. VACASK writes a raw file per analysis
    /// named after it, so names must be distinct.
    fn analysis(x: *Xlat, kind: []const u8, verb: []const u8, args: []const u8) Fail!void {
        x.analyses += 1;
        try x.put(&x.ctl, "  analysis {s}{d} {s}{s}\n", .{ kind, x.analyses, verb, args });
    }

    /// `.tran TSTEP TSTOP [TSTART [TMAX]] [UIC]`.
    ///
    /// `maxstep` is always emitted. SPICE caps the internal step at TMAX,
    /// default min(TSTEP, (TSTOP-TSTART)/50), while VACASK's `step` is only the
    /// first step; without the cap VACASK strides further (115 points against
    /// ngspice's 408 on tran/rc_pulse).
    fn tranCard(x: *Xlat, c: Card) Fail!void {
        const step = c.tok(1) orelse return x.refuse(".tran with no step", .{});
        const stop = c.tok(2) orelse return x.refuse(".tran with no stop time", .{});
        var args: Buf = .empty;
        try x.value(&args, "step", step);
        try x.value(&args, "stop", stop);

        var i: usize = 3;
        var tmax: ?[]const u8 = null;
        if (c.tok(i)) |tstart| {
            if (isNumber(tstart)) {
                // TSTART delays saving, not solving; VACASK always saves from 0.
                if ((parseSpice(tstart) orelse 0) != 0)
                    return x.refuse(".tran TSTART={s} has no VACASK counterpart", .{tstart});
                i += 1;
                if (c.tok(i)) |explicit| {
                    if (isNumber(explicit)) {
                        tmax = explicit;
                        i += 1;
                    }
                }
            }
        }
        if (tmax) |t| {
            try x.value(&args, "maxstep", t);
        } else {
            // SPICE's own default, computed here rather than left to VACASK's.
            const tstep = parseSpice(step) orelse return x.refuse(".tran step '{s}' is not a number", .{step});
            const tstop = parseSpice(stop) orelse return x.refuse(".tran stop '{s}' is not a number", .{stop});
            try x.put(&args, " maxstep={e}", .{@min(tstep, tstop / 50.0)});
        }
        while (c.tok(i)) |t| : (i += 1) {
            if (!eqlAny(t, &.{ "uic", "use-initial-conditions" }))
                return x.refuse(".tran: unhandled field '{s}'", .{t});
            try x.raw(&args, " icmode=\"uic\"");
        }
        return x.analysis("tran", "tran", args.items);
    }

    /// `.dc SRC START STOP STEP [SRC2 START STOP STEP]` as `sweep` blocks
    /// around an operating point.
    ///
    /// The inner scale is `vsweep` (VACASK identifiers cannot contain `-`);
    /// compare.zig aliases it to ngspice's `v(v-sweep)`. ngspice's first
    /// source is the fast one and VACASK's last `sweep` is, so the blocks are
    /// emitted in reverse.
    fn dcCard(x: *Xlat, c: Card) Fail!void {
        if (c.len() != 5 and c.len() != 9)
            return x.refuse(".dc with {d} fields, expected 4 or 8", .{c.len() - 1});

        x.analyses += 1;
        if (c.len() == 9) try x.sweepBlock(c, 5, "outersweep");
        try x.sweepBlock(c, 1, "vsweep");
        try x.put(&x.ctl, "    analysis dc{d} op\n", .{x.analyses});
    }

    /// One `sweep` block. `points` counts intervals, not samples. The endpoint
    /// is ngspice's last sample rather than STOP: ngspice stops before passing
    /// STOP (`.dc Vgs 0 1.1 0.2` ends at 1.0), while VACASK always lands on `to`.
    fn sweepBlock(x: *Xlat, c: Card, at: usize, scale: []const u8) Fail!void {
        const src = c.tok(at).?;
        const from = parseSpice(c.tok(at + 1).?) orelse return x.refuse(".dc: '{s}' is not a number", .{c.tok(at + 1).?});
        const to = parseSpice(c.tok(at + 2).?) orelse return x.refuse(".dc: '{s}' is not a number", .{c.tok(at + 2).?});
        const step = parseSpice(c.tok(at + 3).?) orelse return x.refuse(".dc: '{s}' is not a number", .{c.tok(at + 3).?});
        if (step == 0) return x.refuse(".dc with a zero step", .{});
        // `.dc TEMP ...` sweeps the ambient, which VACASK does differently.
        if (src[0] != 'v' and src[0] != 'i')
            return x.refuse(".dc sweeps '{s}', which is not an independent source", .{src});

        // Truncate: ngspice's last sample has not passed STOP. The epsilon
        // keeps an exact division exact (0.9/0.1 is 8.999999999999998).
        const span = @abs((to - from) / step);
        const n = @floor(span + 1e-9 * @max(1.0, span));
        if (!(n >= 1) or n > 1e7) return x.refuse(".dc {s} covers {d} intervals", .{ src, n });
        const last = from + std.math.sign(to - from) * n * @abs(step);

        try x.put(&x.ctl, "  sweep {s} instance=\"{s}\" parameter=\"dc\" from=", .{ scale, src });
        try x.number(&x.ctl, c.tok(at + 1).?);
        try x.raw(&x.ctl, " to=");
        // An evenly dividing sweep keeps the deck's own spelling of STOP.
        if (@abs(last - to) <= 1e-12 * @max(1.0, @abs(to))) {
            try x.number(&x.ctl, c.tok(at + 2).?);
        } else {
            try x.put(&x.ctl, "{e}", .{last});
        }
        try x.put(&x.ctl, " mode=\"lin\" points={d}\n", .{n});
    }

    /// `.ac DEC|OCT|LIN N FSTART FSTOP`. For `dec`/`oct` SPICE's N is points per
    /// decade/octave and so is VACASK's; for `lin` SPICE's N is the TOTAL point
    /// count while VACASK counts intervals, hence the `- 1`.
    fn acCard(x: *Xlat, c: Card) Fail!void {
        if (c.len() != 5) return x.refuse(".ac with {d} fields, expected 4", .{c.len() - 1});
        return x.freqSweep("ac", "ac", c.tok(1).?, c.tok(2).?, c.tok(3).?, c.tok(4).?, "");
    }

    /// `.noise V(OUT) SRC DEC N FSTART FSTOP [PTS_PER_SUMMARY]`. The summary
    /// count only adds an ngspice per-device plot, so it is dropped.
    fn noiseCard(x: *Xlat, c: Card) Fail!void {
        // `v(out)` has already been flattened to two fields by the lexer.
        const b: usize = if (std.mem.eql(u8, c.tok(1) orelse "", "v")) 2 else 1;
        if (c.len() != b + 5 and c.len() != b + 6) return x.refuse(".noise with {d} fields", .{c.len() - 1});
        const head = try std.fmt.allocPrint(x.gpa, " out=\"{s}\" in=\"{s}\"", .{ c.tok(b).?, c.tok(b + 1).? });
        return x.freqSweep("noise", "noise", c.tok(b + 2).?, c.tok(b + 3).?, c.tok(b + 4).?, c.tok(b + 5).?, head);
    }

    fn freqSweep(
        x: *Xlat,
        kind: []const u8,
        verb: []const u8,
        mode: []const u8,
        count: []const u8,
        from: []const u8,
        to: []const u8,
        head: []const u8,
    ) Fail!void {
        if (!eqlAny(mode, &.{ "dec", "oct", "lin" })) return x.refuse(".{s} sweep type '{s}'", .{ kind, mode });
        const n = parseSpice(count) orelse return x.refuse(".{s}: '{s}' is not a number", .{ kind, count });
        const points = if (std.mem.eql(u8, mode, "lin")) n - 1 else n;
        if (!(points >= 1)) return x.refuse(".{s} with {d} points", .{ kind, n });

        var args: Buf = .empty;
        try x.raw(&args, head);
        try x.value(&args, "from", from);
        try x.value(&args, "to", to);
        try x.put(&args, " mode=\"{s}\" points={d}", .{ mode, points });
        return x.analysis(kind, verb, args.items);
    }

    /// One ` key=value` field, the value respelled (see `Num.scale`).
    fn value(x: *Xlat, w: *Buf, key: []const u8, v: []const u8) Fail!void {
        try x.put(w, " {s}=", .{key});
        return x.number(w, v);
    }

    /// A SPICE number in VACASK's spelling, or a `.param` name unchanged.
    /// Expressions are refused.
    fn number(x: *Xlat, w: *Buf, v: []const u8) Fail!void {
        if (parseNum(v)) |n| return x.put(w, "{s}{s}", .{ n.mantissa, n.scale });
        if (std.mem.indexOfAny(u8, v, "{}'\"()*/+") != null)
            return x.refuse("'{s}': expressions are not translated", .{v});
        return x.raw(w, v);
    }

    fn render(x: *Xlat) error{OutOfMemory}![]const u8 {
        var out: Buf = .empty;
        try x.put(&out, "{s}\n\n", .{x.title});
        try x.raw(&out,
            \\// Generated from SPICE by tests/benchmark/vacask.zig.
            \\// Edit the SPICE deck, never this file.
            \\
            \\ground 0
            \\
            \\
        );

        var loads = x.loads.iterator();
        while (loads.next()) |m| try x.put(&out, "load \"{s}{s}.osdi\"\n", .{ m.prefix(), m.osdi() });
        try x.raw(&out, "\n");

        var autos = x.autos.iterator();
        while (autos.next()) |m| try x.put(&out, "model {s}{s} sp_{s}\n", .{ auto_prefix, @tagName(m), @tagName(m) });
        var builtins = x.builtins.iterator();
        while (builtins.next()) |b| try x.put(&out, "model {s}{s} {s}\n", .{ auto_prefix, @tagName(b), @tagName(b) });
        try x.raw(&out, x.models.items);
        try x.raw(&out, "\n");

        if (x.params.items.len > 0) {
            try x.raw(&out, x.params.items);
            try x.raw(&out, "\n");
        }
        try x.raw(&out, x.subs.items);
        try x.raw(&out, x.net.items);

        try x.raw(&out, "\ncontrol\n  options rawfile=\"binary\"");
        try x.raw(&out, x.opts.items);
        try x.raw(&out, "\n");
        try x.raw(&out, x.saves.items);
        try x.raw(&out, x.ctl.items);
        try x.raw(&out, "endc\n");
        return out.items;
    }
};

/// One logical SPICE card: continuations joined, comments gone, lowercased, and
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
/// After that: `*` opens a comment line, ` $ ` and `;` open an inline one, and
/// `+` in column 1 continues the previous card.
fn lex(gpa: std.mem.Allocator, spice: []const u8, title: *[]const u8, out: *std.ArrayList(Card)) error{OutOfMemory}!void {
    var joined: Buf = .empty;
    var lines = std.mem.splitScalar(u8, spice, '\n');
    var first = true;

    while (lines.next()) |line| {
        if (first) {
            first = false;
            const t = std.mem.trim(u8, std.mem.trimStart(u8, std.mem.trim(u8, line, " \t\r"), "*"), " \t\r");
            if (t.len > 0) title.* = try gpa.dupe(u8, t);
            continue;
        }
        const text = std.mem.trim(u8, stripComment(line), " \t\r");
        if (text.len == 0) continue;
        if (text[0] == '+') {
            try joined.appendSlice(gpa, " ");
            try joined.appendSlice(gpa, text[1..]);
            continue;
        }
        try flush(gpa, &joined, out);
        try joined.appendSlice(gpa, text);
    }
    try flush(gpa, &joined, out);
}

/// Lowercases the joined card and splits it into fields. `(`, `)` and `,`
/// are whitespace, so `PULSE(0 5 1n)`, `PULSE (0,5,1n)` and `pulse 0 5 1n`
/// agree; whitespace around `=` is dropped, so `W = 2u` is one field.
fn flush(gpa: std.mem.Allocator, joined: *Buf, out: *std.ArrayList(Card)) error{OutOfMemory}!void {
    defer joined.clearRetainingCapacity();
    if (joined.items.len == 0) return;

    var flat: Buf = .empty;
    var pending_space = false;
    for (joined.items) |ch| {
        const c = std.ascii.toLower(ch);
        if (c == ' ' or c == '\t' or c == '(' or c == ')' or c == ',') {
            pending_space = flat.items.len > 0;
            continue;
        }
        const after_eq = flat.items.len > 0 and flat.items[flat.items.len - 1] == '=';
        if (pending_space and c != '=' and !after_eq) try flat.append(gpa, ' ');
        pending_space = false;
        try flat.append(gpa, c);
    }

    var fields: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, flat.items, ' ');
    while (it.next()) |f| try fields.append(gpa, f);
    if (fields.items.len == 0) return;
    try out.append(gpa, .{ .fields = fields.items });
}

/// ngspice ends a line at a `;`, or at a `$` that follows whitespace (or opens
/// the line). A `$` glued to a token is left alone.
fn stripComment(line: []const u8) []const u8 {
    const start = std.mem.trimStart(u8, line, " \t");
    if (start.len > 0 and start[0] == '*') return "";
    const upto = if (std.mem.indexOfScalar(u8, line, ';')) |cut| line[0..cut] else line;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, upto, i, '$')) |cut| {
        if (cut == 0 or upto[cut - 1] == ' ' or upto[cut - 1] == '\t') return upto[0..cut];
        i = cut + 1;
    }
    return upto;
}

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
    if (eqlAny(t, &.{ "sin", "sine" })) return .sine;
    if (std.mem.eql(u8, t, "exp")) return .exp;
    if (std.mem.eql(u8, t, "pwl")) return .pwl;
    if (std.mem.eql(u8, t, "sffm")) return .fm;
    return null;
}

fn isNumber(t: []const u8) bool {
    return parseNum(t) != null;
}

fn parseSpice(t: []const u8) ?f64 {
    return if (parseNum(t)) |n| n.value else null;
}

const Num = struct {
    value: f64,
    /// The numeric part, exactly as the deck wrote it.
    mantissa: []const u8,
    /// VACASK's spelling of the SPICE suffix, `""` when there is none. SPICE
    /// suffixes are case-insensitive and VACASK's are not: `M` is milli in
    /// SPICE but mega in VACASK, `T`/`G` exist only uppercase there and
    /// `u`/`n`/`p`/`f`/`a` only lowercase. A trailing unit (`5V`) is dropped,
    /// as SPICE does.
    scale: []const u8,
};

/// A SPICE number with optional scale suffix and unit. `meg` and `mil` are
/// tried before `m`.
fn parseNum(t: []const u8) ?Num {
    if (t.len == 0) return null;
    var end: usize = 0;
    while (end < t.len) : (end += 1) {
        const c = t[end];
        if (std.ascii.isDigit(c) or c == '.' or c == '+' or c == '-') continue;
        // `e` is an exponent only when a digit or sign follows it.
        if ((c == 'e' or c == 'E') and end + 1 < t.len and
            (std.ascii.isDigit(t[end + 1]) or t[end + 1] == '+' or t[end + 1] == '-')) continue;
        break;
    }
    const mantissa = std.fmt.parseFloat(f64, t[0..end]) catch return null;
    const suffix = t[end..];
    const scales = .{
        .{ "meg", "meg", 1e6 }, .{ "mil", "mil", 25.4e-6 },
        .{ "t", "T", 1e12 },    .{ "g", "G", 1e9 },
        .{ "k", "k", 1e3 },     .{ "m", "m", 1e-3 },
        .{ "u", "u", 1e-6 },    .{ "n", "n", 1e-9 },
        .{ "p", "p", 1e-12 },   .{ "f", "f", 1e-15 },
        .{ "a", "a", 1e-18 },
    };
    inline for (scales) |s| {
        if (std.ascii.startsWithIgnoreCase(suffix, s[0]))
            return .{ .value = mantissa * s[2], .mantissa = t[0..end], .scale = s[1] };
    }
    // A trailing unit with no scale letter (`5V`, `1ohm`) is ignored by SPICE.
    for (suffix) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return .{ .value = mantissa, .mantissa = t[0..end], .scale = "" };
}

const testing = std.testing;

/// Test harness: `translate` into an arena freed at `deinit`.
const Probe = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Probe {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(p: *Probe) void {
        p.arena.deinit();
    }

    fn sim(p: *Probe, spice: []const u8) ![]const u8 {
        return switch (try translate(p.arena.allocator(), spice)) {
            .sim => |s| s,
            .refused => |r| {
                std.debug.print("unexpectedly refused: {s}\n", .{r});
                return error.UnexpectedRefusal;
            },
        };
    }

    fn why(p: *Probe, spice: []const u8) ![]const u8 {
        return switch (try translate(p.arena.allocator(), spice)) {
            .sim => error.UnexpectedlyTranslated,
            .refused => |r| r,
        };
    }
};

fn has(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}

test "the divider translates to what the hand-written deck says, line for line" {
    // The circuit of fixtures/op/voltage_divider.
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\* DC operating-point fixture: symmetric voltage divider.
        \\Vin in 0 DC 10
        \\R1 in out 5k
        \\R2 out 0 5k
        \\.op
        \\.end
    );
    try has(out, "vin (in 0) xlat_vsource dc=10\n");
    try has(out, "r1 (in out) xlat_resistor r=5k\n");
    try has(out, "r2 (out 0) xlat_resistor r=5k\n");
    try has(out, "load \"spice/resistor.osdi\"");
    try has(out, "model xlat_resistor sp_resistor");
    try has(out, "analysis op1 op");
    try has(out, "ground 0");
    // Line 1 is the title with its comment marker taken off, never a card.
    try testing.expect(std.mem.startsWith(u8, out, "DC operating-point fixture"));
}

test "a DC sweep counts intervals, not points" {
    // `.dc V1 0 10 0.5` is 21 samples, 20 intervals.
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\sweep
        \\V1 in 0 DC 0
        \\R1 in 0 1k
        \\.dc V1 0 10 0.5
        \\.end
    );
    try has(out, "sweep vsweep instance=\"v1\" parameter=\"dc\" from=0 to=10 mode=\"lin\" points=20");
    try has(out, "analysis dc1 op");
}

test "AC lin counts intervals while dec counts per decade" {
    // SPICE's LIN N is a total and its DEC N a rate.
    var p: Probe = .init();
    defer p.deinit();
    try has(try p.sim(
        \\ac
        \\V1 in 0 AC 1
        \\R1 in 0 1k
        \\.ac lin 11 1 100
        \\.end
    ), "mode=\"lin\" points=10");
    const dec = try p.sim(
        \\ac
        \\V1 in 0 AC 2 90
        \\R1 in 0 1k
        \\.ac dec 10 1 100
        \\.end
    );
    try has(dec, "mode=\"dec\" points=10");
    try has(dec, "phase=90 mag=2");
}

test "a BJT's substrate node is optional and found by model lookup" {
    var p: Probe = .init();
    defer p.deinit();
    const three = try p.sim(
        \\bjt
        \\Q1 c b 0 QMOD
        \\V1 c 0 5
        \\R1 b 0 1k
        \\.model QMOD NPN(IS=1e-16 BF=100)
        \\.op
        \\.end
    );
    try has(three, "q1 (c b 0) qmod\n");
    try has(three, "model qmod sp_bjt ( type=1 is=1e-16 bf=100 )");

    // With a substrate node: `sub` is not a model name, so it is a node.
    const four = try p.sim(
        \\bjt
        \\Q1 c b 0 sub QMOD 2.5
        \\V1 c 0 5
        \\R1 b 0 1k
        \\.model QMOD PNP(IS=1e-16)
        \\.op
        \\.end
    );
    try has(four, "q1 (c b 0 sub) qmod area=2.5\n");
    try has(four, "type=-1");
}

test "MOSFET LEVEL picks the module and never leaks into the parameters" {
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\mos
        \\M1 d g 0 0 NM W=2u L=1u
        \\V1 d 0 5
        \\V2 g 0 5
        \\.model NM NMOS(LEVEL=3 VTO=0.7 KP=2e-5)
        \\.op
        \\.end
    );
    try has(out, "model nm sp_mos3 ( type=1 vto=0.7 kp=2e-5 )");
    try has(out, "m1 (d g 0 0) nm w=2u l=1u\n");
    try has(out, "load \"spice/mos3.osdi\"");
    try testing.expect(std.mem.indexOf(u8, out, "level=") == null);

    // A level with no module refuses rather than picking a nearby one.
    try has(try p.why(
        \\mos
        \\M1 d g 0 0 NM W=2u L=1u
        \\V1 d 0 5
        \\.model NM NMOS(LEVEL=73)
        \\.op
        \\.end
    ), "LEVEL=73");

    // PSP103 is VACASK's own psp103v4.osdi; `.save` comes before the analyses.
    const psp = try p.sim(
        \\psp
        \\M1 d g 0 0 NP W=1u L=0.2u
        \\V1 d 0 1.2
        \\V2 g 0 1.2
        \\.save v(d) i(v1)
        \\.model NP PMOS(LEVEL=1040 TOXO=1.5e-9)
        \\.op
        \\.end
    );
    try has(psp, "load \"psp103v4.osdi\"");
    try has(psp, "model np psp103va ( type=-1 toxo=1.5e-9 )");
    try has(psp, "  save v(d) i(v1)\n  analysis op1 op");
}

test "waveforms map positionally and stop where SPICE stopped" {
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\wave
        \\V1 a 0 PULSE(0 5 1n 2n 3n 10n 20n)
        \\V2 b 0 SIN(0 1 1k)
        \\R1 a 0 1k
        \\R2 b 0 1k
        \\.tran 1n 100n
        \\.end
    );
    try has(out, "v1 (a 0) xlat_vsource type=\"pulse\" val0=0 val1=5 delay=1n rise=2n fall=3n width=10n period=20n\n");
    // Three arguments given, three emitted; the rest take VACASK's defaults.
    try has(out, "v2 (b 0) xlat_vsource type=\"sine\" sinedc=0 ampl=1 freq=1k\n");
    try has(out, "analysis tran1 tran step=1n stop=100n maxstep=");
}

test "continuations, inline comments and spaced equals are one card" {
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\lexing
        \\V1 in 0 DC 1 $ the supply
        \\M1 d g 0 0 NM W = 2u
        \\+ L= 1u ; continued
        \\R1 d in 1k
        \\.model NM NMOS(LEVEL=1
        \\+ VTO=0.7)
        \\.op
        \\.end
    );
    try has(out, "v1 (in 0) xlat_vsource dc=1\n");
    try has(out, "m1 (d g 0 0) nm w=2u l=1u\n");
    try has(out, "model nm sp_mos1 ( type=1 vto=0.7 )");
}

test "subcircuits are emitted before the instances that call them" {
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
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
    try has(out, "subckt inv(a b)");
    try has(out, "x1 (in out) inv");
    try has(out, "ends\n");
    try testing.expect(std.mem.indexOf(u8, out, "subckt inv(a b)").? <
        std.mem.indexOf(u8, out, "x1 (in out) inv").?);
}

test "controlled sources keep SPICE's node and control order" {
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
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
    try has(out, "e1 (out 0 in 0) xlat_vcvs gain=10\n");
    try has(out, "f1 (out3 0) xlat_cccs ctlinst=\"vs\" gain=2\n");

    // POLY/VALUE/TABLE are a different device, not a different spelling.
    try has(try p.why(
        \\ctl
        \\V1 in 0 1
        \\E1 out 0 POLY(1) in 0 0 1 2
        \\R1 out 0 1k
        \\.op
        \\.end
    ), "POLY");
}

test "options that change the answer are translated; the rest are refused" {
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\opts
        \\V1 in 0 1
        \\R1 in 0 1k
        \\.options noacct klu reltol=1e-4 method=gear
        \\.temp 55
        \\.op
        \\.end
    );
    try has(out, "reltol=1e-4");
    try has(out, "tran_method=\"gear2\"");
    try has(out, "temp=55");
    try testing.expect(std.mem.indexOf(u8, out, "klu") == null);

    // `maxord` has no VACASK spelling, and dropping it changes the integration order.
    try has(try p.why(
        \\opts
        \\V1 in 0 1
        \\R1 in 0 1k
        \\.options maxord=2
        \\.op
        \\.end
    ), "maxord");
}

test "a card with no faithful translation refuses the whole deck, by name" {
    var p: Probe = .init();
    defer p.deinit();
    for ([_][]const u8{
        // A behavioural source is an expression language, not a device.
        "b\nB1 out 0 V=V(in)*2\nV1 in 0 1\n.op\n.end",
        // `.model R` renames its parameters in VACASK; see model_types.
        "rmod\nR1 a 0 RM 1k\nV1 a 0 1\n.model RM R(TC1=1e-3)\n.op\n.end",
        // An analysis VACASK does not run is not one it runs badly.
        "pz\nV1 in 0 1\nR1 in 0 1k\n.pz 1 0 1 0 vol pz\n.end",
        // No transitive translation: the included file is still SPICE.
        "inc\nV1 in 0 1\nR1 in 0 1k\n.include models.inc\n.op\n.end",
        // `.dc ... TEMP` sweeps the ambient, not a source parameter.
        "t\nV1 a 0 1\nR1 a 0 1k\n.dc V1 0 1 0.1 TEMP -40 125 55\n.end",
        // VBIC and HICUM both spell their card `NPN`. Mapping on the keyword
        // alone put them on Gummel-Poon; only the LEVEL tells them apart.
        "vbic\nQ1 c b 0 VB\nV1 c 0 5\nR1 b 0 1k\n.model VB NPN(LEVEL=4 IS=1e-16)\n.op\n.end",
        "hicum\nQ1 c b 0 HC\nV1 c 0 5\nR1 b 0 1k\n.model HC NPN(LEVEL=8 IS=1e-16)\n.op\n.end",
    }) |deck| {
        try testing.expect((try p.why(deck)).len > 0);
    }
}

test "a nested .dc emits VACASK's sweeps in the opposite order" {
    // ngspice's first source is the fast one; VACASK's last sweep block is.
    // In deck order the samples would come out transposed.
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\nested
        \\VDS d 0 0
        \\VGS g 0 0
        \\R1 d g 1k
        \\.dc VDS 0 5 0.1 VGS 1 3 0.5
        \\.end
    );
    const outer = std.mem.indexOf(u8, out, "sweep outersweep instance=\"vgs\"").?;
    const inner = std.mem.indexOf(u8, out, "sweep vsweep instance=\"vds\"").?;
    try testing.expect(outer < inner);
    try has(out, "from=1 to=3 mode=\"lin\" points=4");
    try has(out, "from=0 to=5 mode=\"lin\" points=50");
}

test "scale suffixes are respelled into VACASK's, which are not SPICE's" {
    // SPICE `M` is milli, VACASK `M` is mega.
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\suffixes
        \\V1 a 0 1
        \\R1 a b 4.7M
        \\R2 b c 1G
        \\R3 c d 2U
        \\R4 d e 1MEG
        \\R5 e 0 10kohm
        \\.op
        \\.end
    );
    try has(out, "r1 (a b) xlat_resistor r=4.7m\n"); // milli, as SPICE meant
    try has(out, "r2 (b c) xlat_resistor r=1G\n"); // VACASK has no lowercase giga
    try has(out, "r3 (c d) xlat_resistor r=2u\n"); // VACASK has no uppercase micro
    try has(out, "r4 (d e) xlat_resistor r=1meg\n");
    try has(out, "r5 (e 0) xlat_resistor r=10k\n"); // the trailing unit is dropped
}

test "a model with no parameters gets no empty parameter list" {
    // `model dmod sp_diode ( )` is a VACASK syntax error.
    var p: Probe = .init();
    defer p.deinit();
    const out = try p.sim(
        \\bare
        \\D1 a 0 DMOD
        \\V1 a 0 1
        \\.model DMOD D
        \\.op
        \\.end
    );
    try has(out, "model dmod sp_diode\n");
}

test "a source cannot hold both a DC value and a waveform when a static analysis asks" {
    // ngspice's static analyses read the DC value; VACASK biases at the
    // waveform's t=0 value once `type=` is set.
    var p: Probe = .init();
    defer p.deinit();
    try has(try p.why(
        \\rtlinv
        \\vin 1 0 PULSE(0 5 2n 2n 2n 80n)
        \\r1 1 0 1k
        \\.dc vin 0 2.5 0.025
        \\.end
    ), "DC value");

    // A transient-only deck never reads the DC value, so it translates.
    try has(try p.sim(
        \\tran only
        \\vin 1 0 DC 3 PULSE(0 5 2n 2n 2n 80n 160n)
        \\r1 1 0 1k
        \\.tran 1n 100n
        \\.end
    ), "type=\"pulse\"");
}

test "a .dc step that does not divide the range stops where ngspice stops" {
    // ngspice stops before passing STOP: six samples ending at 1.0.
    var p: Probe = .init();
    defer p.deinit();
    try has(try p.sim(
        \\uneven
        \\Vgs g 0 DC 0
        \\R1 g 0 1k
        \\.dc Vgs 0 1.1 0.2
        \\.end
    ), "from=0 to=1e0 mode=\"lin\" points=5");

    // An evenly-dividing sweep keeps the deck's own spelling of the endpoint.
    try has(try p.sim(
        \\even
        \\V1 in 0 DC 0
        \\R1 in 0 1k
        \\.dc V1 0 10 0.5
        \\.end
    ), "from=0 to=10 mode=\"lin\" points=20");
}

test "PULSE without rise/fall takes SPICE's TSTEP default, not VACASK's 1ns" {
    // SPICE defaults TR/TF to TSTEP and PW to TSTOP; VACASK uses 1 ns edges.
    var p: Probe = .init();
    defer p.deinit();
    try has(try p.sim(
        \\rc
        \\vin 1 0 PULSE(0 1)
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.tran 0.1 7.0
        \\.end
    ), "type=\"pulse\" val0=0 val1=1 rise=1e-1 fall=1e-1 width=7e0 period=7.2000007");
}

test "waveform arguments VACASK accepts but ignores are refused" {
    var p: Probe = .init();
    defer p.deinit();
    // `sinephase` is accepted and ignored.
    try has(try p.why(
        \\phase
        \\V1 in 0 SIN(0 1 1k 0 0 90)
        \\R1 in 0 1k
        \\.tran 1u 1m
        \\.end
    ), "ignored by VACASK");

    // PWL parses and then aborts the transient on this build.
    try has(try p.why(
        \\pwl
        \\V1 in 0 PWL(0 0 1n 5 2n 0)
        \\R1 in 0 1k
        \\.tran 0.1n 10n
        \\.end
    ), "PWL is not translated");
}

test "SFFM's pedestal is sinedc; `offset` is a parameter VACASK takes and ignores" {
    // `offset` is accepted on an fm source and ignored; `sinedc` is the pedestal.
    var p: Probe = .init();
    defer p.deinit();
    try has(try p.sim(
        \\fm
        \\V1 in 0 SFFM(2 1 100k 5 1k)
        \\R1 in 0 1k
        \\.tran 100n 2m
        \\.end
    ), "type=\"fm\" sinedc=2 ampl=1 freq=100k modindex=5 modfreq=1k");
}

test "a deck with no analysis is refused rather than run empty" {
    var p: Probe = .init();
    defer p.deinit();
    try has(try p.why("empty\nV1 in 0 1\nR1 in 0 1k\n.end"), "no analysis");
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
