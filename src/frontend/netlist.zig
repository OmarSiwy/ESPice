//! Netlist text to a flat, subcircuit-expanded nets-by-devices hypergraph,
//! plus models and deck cards. Three walks over the logical lines: declarations
//! (subcircuit ranges, `.param`, `.model`, directives), devices (an `X` card
//! re-reads its subcircuit's lines under a frame), then analysis nets. Values
//! are rows of flat tables; an expression that does not fold stays postfix.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const lines = @import("lines.zig");
pub const source = @import("source.zig");
const csr = @import("csr.zig");
pub const expr = @import("expr.zig");
const measure = @import("measure.zig");
const core = @import("core");
const Name = core.Name;
const InternPool = @import("core").InternPool;
const requests = @import("core").query;

/// Input syntax: ngspice, HSPICE or Spectre.
pub const Dialect = lines.Dialect;
pub const VertexId = csr.VertexId;
pub const EdgeId = csr.EdgeId;
/// Analysis kind, shared with the query layer.
pub const Kind = requests.Kind;
/// Net 0; `0`, `gnd` and `ground` all name it.
pub const ground: VertexId = @enumFromInt(0);
/// Missing id in every u32 index space here.
pub const none = std.math.maxInt(u32);
/// `ParseError`: malformed card; `ModelBinNotFound`: no `.model nm.N` bin
/// holds an M card's L/W; `CircuitTooLarge`: a table passed u32;
/// `UnsupportedCard`: a card or element form ESPice cannot simulate, logged
/// with the line.
pub const Error = error{ OutOfMemory, ParseError, ModelBinNotFound, CircuitTooLarge, UnsupportedCard };

/// Rows `start..start+len` of a flat table.
pub const Span = struct { start: u32 = 0, len: u32 = 0 };

/// One card value after parameter substitution.
pub const Value = union(enum) {
    num: f64,
    /// A word no scope defines: a node, model, keyword or source name.
    name: []const u8,
    /// Postfix ops in `Netlist.ops` that did not fold to a number.
    expr: Span,
    /// `name(args)`: a source waveform or a `v(...)`/`i(...)` output.
    group: Group,
};

/// `name(args)`.
/// ponytail: group arguments are arena slices, not a table: a few per deck.
pub const Group = struct { name: []const u8, args: []const Value };
/// `key=value`; a positional model value has an empty key.
pub const Kv = struct { key: []const u8, value: Value };

/// Vertex payload.
pub const Net = struct { name: Name };

/// Hyperedge payload. `kind` is the lowercase card letter.
pub const Device = struct {
    kind: u8,
    /// Flattened name: `r.x1.r1` for `r1` inside instance `x1`.
    name: Name,
    /// `.model` row the first positional names, `none` otherwise.
    model: u32,
    /// Rows of `Netlist.values`.
    positional: Span,
    /// Rows of `Netlist.kvs`.
    kv: Span,
    /// Subcircuit expansion ordinal, 0 at top level.
    subckt_instance: u32,
};

/// Nets by devices; a device's pins are its member list, in terminal order.
pub const Hypergraph = csr.BipartiteHypergraph(Net, Device);

/// A `.model` card: `kind` is the type word (`nmos`, `d`, a VA module name).
pub const Model = struct { name: []const u8, kind: []const u8, kv: []const Kv };

/// What a `.step` card or an HSPICE `SWEEP` varies.
pub const StepTarget = union(enum) {
    /// A global `.param`, by its row in `Live.names`.
    param: u32,
    temp,
    /// A card's primary value (a source's `dc`, a resistor's `r`), by card name.
    card: []const u8,
};

/// One swept quantity and its points, in sweep order.
pub const Step = struct { target: StepTarget, values: []const f64 };

/// HSPICE `MONTE=n [FIRSTRUN=k]`: trials `first..first + n - 1`; or
/// `MONTE=list(a b:c ...)` [CR .DC]: exactly the trials in `list`.
pub const Monte = struct { n: u32, first: u32 = 1, list: []const u32 = &.{} };

/// An HSPICE sweep on one analysis card: the card runs once per point.
/// On a `.dc` card with no sweep of its own (`.dc DATA=d`, `.dc MONTE=n`)
/// the points are the DC sweep.
pub const Sweep = union(enum) {
    none,
    /// `SWEEP DATA=name`: one point per row of that `.data` table.
    data: []const u8,
    monte: Monte,
    step: Step,
    /// `SWEEP OPTIMIZE=`: the card is the one `Deck.optimize` fits.
    optimize,
};

/// HSPICE optimization [SA Ch.27]: `<card> SWEEP OPTIMIZE=name
/// RESULTS=m1,m2 MODEL=optmod` fits the `.param p = name(init, lo, hi
/// [, dels])` and `OPTRANGE(...)` parameters to the `GOAL=` of the named
/// `.meas` cards. The parameter columns are parallel.
pub const Optimize = struct {
    name: []const u8,
    /// `.meas` card names.
    results: []const []const u8,
    /// The `.model name OPT` card with the optimizer's options.
    model: []const u8,
    /// Each parameter's row in `Live.names`; its nominal is the initial value.
    live: []const u32,
    lo: []const f64,
    hi: []const f64,
    /// Finite-difference step; 0 when not given.
    dels: []const f64,
};

/// An inline `.data` table: one target per column, `values` row-major.
pub const Data = struct {
    name: []const u8,
    labels: []const []const u8,
    columns: []const StepTarget,
    values: []const f64,
};

/// One Monte Carlo variation of a model or element parameter: HSPICE
/// `DEV`/`LOT` on a `.model` value, or a `.variation` block row.
pub const Variation = struct {
    /// `DEV` and local variation draw once per device; `LOT` and global
    /// variation once per model.
    per_device: bool,
    dist: Dist,
    /// The `.model` name; empty for element variation, which `letter` names.
    model: []const u8,
    letter: u8 = 0,
    param: []const u8,
    /// One sigma for `gauss`, the half range otherwise; a fraction of the
    /// nominal when `relative`.
    value: f64,
    relative: bool,

    /// Normal, uniform over ±value, or one of the two extremes.
    pub const Dist = enum(u8) { gauss, unif, limit };
};

/// Values a variant re-evaluates: device and model values that read a swept
/// `.param` or, when some card runs Monte Carlo, a distribution call.
pub const Live = struct {
    /// Swept global `.param` names; a `.live` op indexes them.
    names: []const []const u8 = &.{},
    /// Each name's value in the deck as written.
    nominal: []const f64 = &.{},
    /// Rows of `values`, `kvs` or a group's arguments, parallel to `ops`.
    slots: []const *Value = &.{},
    /// Postfix each slot is evaluated from, and the factor `.option scale`
    /// applies to it afterwards.
    ops: []const Span = &.{},
    scale: []const f64 = &.{},
    /// Distribution calls: op index (ascending) and site key. A site draws
    /// once per trial wherever it is read.
    site_ops: []const u32 = &.{},
    site_keys: []const u64 = &.{},
    /// Constant-pool row that stands in for each name inside expressions a
    /// device keeps as postfix (a B source), or `none`.
    pool_rows: []const u32 = &.{},
    /// Some kept expression reads a swept name, so a variant changes storage
    /// `ParamRef` cannot reach and must be rebuilt.
    opaque_reads: bool = false,
    /// Postfix of each top-level `.if`/`.elseif` condition the parse
    /// evaluated that reads a live name. A variant keeps the nominal
    /// branches only while each still has its nominal truth value.
    conds: []const Span = &.{},
};

/// An analysis card. `pos`/`neg` are the output `v(a[,b])` nets, `ports` the
/// four `.pz` nets; `none` where the card names none or an unknown net.
pub const Analysis = struct {
    kind: Kind,
    args: []const Value,
    sweep: Sweep = .none,
    /// The card as written, for diagnostics.
    line: []const u8 = "",
    /// The syntax the card is read in (`.tran` segments, for one).
    dialect: Dialect = .ngspice,
    pos: u32 = none,
    neg: u32 = none,
    ports: [4]u32 = @splat(none),
    /// Written as an HSPICE shooting-Newton card (`.sn`, `.snac`,
    /// `.snnoise`, `.snxf`), whose keyword arguments differ from `.pss`,
    /// `.pac`, `.pnoise` and `.pxf`.
    sn: bool = false,
    /// One output of a `.four` card that named several; each is its own card.
    split: bool = false,
};

/// Appends `a` to `list`, a `.four` naming several outputs as one card per
/// output (the frequency, that output, and any trailing numbers).
fn appendAnalysis(arena: Allocator, list: *std.ArrayList(Analysis), a: Analysis) Allocator.Error!void {
    var outputs: usize = 0;
    if (a.kind == .four) for (a.args) |v| {
        if (v == .group) outputs += 1;
    };
    if (outputs < 2) return list.append(arena, a);
    for (a.args[1..]) |v| {
        if (v != .group) continue;
        var args: std.ArrayList(Value) = .empty;
        try args.appendSlice(arena, &.{ a.args[0], v });
        for (a.args[1..]) |t| if (t != .group) try args.append(arena, t);
        var part = a;
        part.args = args.items;
        part.split = true;
        try list.append(arena, part);
    }
}

/// `.options` and single-value `.temp` cards, in deck order.
pub const Config = struct {
    temp: bool,
    args: []const Value,
    /// The card as written, for diagnostics.
    line: []const u8 = "",
};
/// One `.ic v(net)=value` entry on a net some card names.
pub const Ic = struct { net: VertexId, value: f64 };
pub const ForeignKind = source.ForeignKind;
/// An HDL or OSDI include, path as written (relative to the deck).
pub const Foreign = struct { kind: ForeignKind, path: []const u8 };

/// Deck data: everything that is not circuit topology.
pub const Deck = struct {
    title: []const u8,
    dialect: Dialect,
    analyses: []const Analysis,
    config: []const Config,
    ic: []const Ic,
    /// `.nodeset` guesses, on nets some card names.
    nodeset: []const Ic,
    /// `.save` outputs as lowercased `v(net)`/`i(name)` labels. Empty: save
    /// everything, as with no `.save` card or a `.save all`.
    saves: []const []const u8,
    foreign: []const Foreign,
    /// `.meas` cards; their strings borrow the parse arena.
    measures: []const core.Measure,
    /// `.step` cards in deck order; the last varies fastest.
    steps: []const Step = &.{},
    data: []const Data = &.{},
    variations: []const Variation = &.{},
    /// The optimization of the deck's one `SWEEP OPTIMIZE=` card.
    optimize: ?Optimize = null,
    /// Each `.alter` run's full source, cumulative, expanded; set by
    /// `prepare`.
    alters: []const []const u8 = &.{},
    /// HSPICE `.save` (the last one); ngspice's `.save` fills `saves`.
    save_op: ?core.SaveOp = null,
    /// HSPICE `.sample` (the last one), for the `.noise` spectra.
    sample: ?core.query.NoiseSample = null,
};

/// A parsed, flattened deck. Every slice lives in the parse arena.
pub const Netlist = struct {
    /// Net and device names.
    pool: InternPool,
    graph: Hypergraph.Graph,
    /// Edges counting-sorted by card letter; `kind_starts[c - 'a']` opens
    /// letter c's run, [26] is the edge count.
    order: []const EdgeId,
    kind_starts: [27]u32,
    /// Positional values of every device, addressed by `Device.positional`.
    values: []const Value,
    /// `key=value` pairs of every device, addressed by `Device.kv`.
    kvs: []const Kv,
    /// Postfix of every unfolded expression, addressed by `Value.expr`.
    ops: []const expr.Op,
    /// Constant pool the `num` ops index.
    consts: []const f64,
    models: []const Model,
    /// Model name to its first `.model` row.
    model_ids: std.StringHashMapUnmanaged(u32),
    deck: Deck,
    live: Live = .{},

    /// A card as the builder reads it.
    pub const View = struct {
        name: []const u8,
        kind: u8,
        pins: []const VertexId,
        positional: []const Value,
        kv: []const Kv,
        model: ?Model,
        subckt_instance: u32,
        /// Row of `model` in `Netlist.models`; `none` without one.
        model_row: u32 = none,
    };

    /// Devices of card letter `c` (lowercase), in file order.
    pub fn bucket(nl: *const Netlist, c: u8) []const EdgeId {
        return nl.order[nl.kind_starts[c - 'a']..nl.kind_starts[c - 'a' + 1]];
    }

    /// Device `e` with its slices resolved.
    pub fn device(nl: *const Netlist, e: EdgeId) View {
        const i = e.index();
        const d = nl.graph.edges.get(i);
        return .{
            .name = nl.pool.str(d.name),
            .kind = d.kind,
            .pins = nl.graph.pins(e),
            .positional = nl.values[d.positional.start..][0..d.positional.len],
            .kv = nl.kvs[d.kv.start..][0..d.kv.len],
            .model = if (d.model == none) null else nl.models[d.model],
            .subckt_instance = d.subckt_instance,
            .model_row = d.model,
        };
    }

    /// Device count after subcircuit expansion.
    pub fn deviceCount(nl: *const Netlist) u32 {
        return nl.graph.edgeCount();
    }

    /// Name of net `v`: `x1.mid` for `mid` inside instance `x1`.
    pub fn netName(nl: *const Netlist, v: VertexId) []const u8 {
        return nl.pool.str(nl.graph.vertices.items(.name)[v.index()]);
    }

    /// First `.model` card named `name`.
    pub fn findModel(nl: *const Netlist, name: []const u8) ?Model {
        return if (nl.model_ids.get(name)) |i| nl.models[i] else null;
    }

    /// The postfix of an unfolded `Value.expr`.
    pub fn exprOps(nl: *const Netlist, span: Span) []const expr.Op {
        return nl.ops[span.start..][0..span.len];
    }

    /// Rewrites every live value for one variant: `values[k]` is live name
    /// k, and `draw.sample(site, f, args)` answers each distribution call
    /// (`null` keeps nominals). Returns true when some value changed.
    /// `stack` is scratch.
    pub fn setLive(nl: *const Netlist, gpa: Allocator, stack: *std.ArrayList(expr.Val), values: []const f64, draw: anytype) !bool {
        const live = nl.live;
        const pool: []f64 = @constCast(nl.consts);
        var changed = false;
        for (live.pool_rows, values) |row, v| if (row != none) {
            changed = changed or pool[row] != v;
            pool[row] = v;
        };
        for (live.slots, live.ops, live.scale) |slot, span, scale| {
            const ops = nl.exprOps(span);
            const x = scale * if (@TypeOf(draw) == @TypeOf(null))
                try expr.eval(gpa, stack, ops, nl.consts, values, null)
            else
                try expr.eval(gpa, stack, ops, nl.consts, values, SiteDraw(@TypeOf(draw)){ .inner = draw, .base = span.start, .ops = live.site_ops, .keys = live.site_keys });
            changed = changed or slot.num != x;
            slot.* = .{ .num = x };
        }
        return changed;
    }
};

/// Maps an op index inside one slot's postfix to its site key.
fn SiteDraw(comptime D: type) type {
    return struct {
        inner: D,
        base: u32,
        ops: []const u32,
        keys: []const u64,

        pub fn value(self: @This(), i: usize, f: expr.Fn, args: []const f64) f64 {
            const at: u32 = self.base + @as(u32, @intCast(i));
            const k = std.sort.lowerBound(u32, self.ops, at, struct {
                fn order(a: u32, b: u32) std.math.Order {
                    return std.math.order(a, b);
                }
            }.order);
            return self.inner.sample(self.keys[k], f, args);
        }
    };
}

/// A site key: `owner` mixed with `salt` (splitmix64 finalizer).
pub fn siteKey(owner: u64, salt: u64) u64 {
    var z = owner ^ (salt +% 0x9e3779b97f4a7c15);
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn nameKey(owner: u64, name: []const u8) u64 {
    return siteKey(owner, std.hash.Wyhash.hash(0, name));
}

/// True for `0`, `gnd` and `ground`, case-insensitively.
pub fn isGroundName(name: []const u8) bool {
    return std.mem.eql(u8, name, "0") or
        std.ascii.eqlIgnoreCase(name, "gnd") or
        std.ascii.eqlIgnoreCase(name, "ground");
}

/// Index of the first card name in `names` equal to `target`, byte for
/// byte; null when none is. O(names.len).
pub fn nameIndex(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, target)) return i;
    return null;
}

/// `ignored`: a card that only shapes printed output, which ESPice writes
/// in full anyway.
const Card = union(enum) { end, ends, subckt, param, model, include, osdi_include, pre_osdi, verilog, control, endc, options, ic, nodeset, global, connect, save, store, sample, meas, ignored, step, data, enddata, variation, end_variation, analysis: Kind, cond: CondCard };

const CondCard = enum { @"if", elseif, @"else", endif };

/// Open `.if` chains, matching ngspice's recifeval (inp.c): each chain keeps
/// the lines of its first true branch and drops the rest.
const Branches = struct {
    open: [max]State = undefined,
    depth: u8 = 0,

    /// `live`: in the kept branch; `pending`: no branch held yet; `spent`:
    /// a branch already held, or the whole chain sits in a dropped region.
    const State = enum(u2) { live, pending, spent };
    const max = 32;

    fn active(b: Branches) bool {
        return b.depth == 0 or b.open[b.depth - 1] == .live;
    }
};

fn an(kind: Kind) Card {
    return .{ .analysis = kind };
}

fn cond(c: CondCard) Card {
    return .{ .cond = c };
}

/// Source keywords that may follow a P card's nodes (`mixedPort`).
const port_source_words = std.StaticStringMap(void).initComptime(.{
    .{"dc"},   .{"ac"}, .{"hb"},   .{"hbac"}, .{"pulse"},   .{"sin"},     .{"exp"},
    .{"pwl"},  .{"sffm"}, .{"am"}, .{"lfsr"}, .{"pat"}, .{"distof1"}, .{"distof2"},
});

/// Every dot card the three dialects accept, looked up lowercased.
const cards = std.StaticStringMap(Card).initComptime(.{
    .{ "end", .end },         .{ "ends", .ends },                 .{ "subckt", .subckt },
    .{ "param", .param },     .{ "model", .model },               .{ "include", .include },
    .{ "hdl", .include },     .{ "osdi_include", .osdi_include }, .{ "pre_osdi", .pre_osdi },
    .{ "verilog", .verilog }, .{ "option", .options },            .{ "options", .options },
    .{ "opt", .options },     .{ "opts", .options },              .{ "ic", .ic },
    .{ "ac", an(.ac) },       .{ "dc", an(.dc) },                 .{ "dcmatch", an(.dcmatch) },
    .{ "disto", an(.disto) }, .{ "envelope", an(.envelope) },     .{ "envlp", an(.envelope) },
    .{ "four", an(.four) },   .{ "hb", an(.hb) },                 .{ "matex", an(.matex) },
    .{ "hbac", an(.hbac) },   .{ "hbnoise", an(.hbnoise) },       .{ "hbxf", an(.hbxf) },
    .{ "hbosc", an(.hb) },    .{ "snosc", an(.pss) },         .{ "phasenoise", an(.phasenoise) },
    .{ "mc", an(.mc) },       .{ "montecarlo", an(.mc) },         .{ "noise", an(.noise) },
    .{ "op", an(.op) },       .{ "pac", an(.pac) },               .{ "pnoise", an(.pnoise) },
    .{ "pss", an(.pss) },     .{ "pxf", an(.pxf) },               .{ "pz", an(.pz) },
    .{ "qpss", an(.qpss) },   .{ "sens", an(.sens) },             .{ "sp", an(.sp) },
    .{ "stb", an(.stb) },     .{ "temp", an(.temp) },             .{ "tf", an(.tf) },
    .{ "sn", an(.pss) },      .{ "snac", an(.pac) },              .{ "snnoise", an(.pnoise) },
    .{ "snxf", an(.pxf) },    .{ "fft", an(.fft) },               .{ "ptdnoise", an(.pnoise) },
    .{ "tran", an(.tran) },   .{ "trannoise", an(.tran_noise) },  .{ "tran_noise", an(.tran_noise) },
    .{ "lstb", an(.lstb) },   .{ "acxf", an(.acxf) },             .{ "dcxf", an(.dcxf) },
    .{ "dcinc", an(.dcinc) },   .{ "lin", an(.sp) },            .{ "acmatch", an(.acmatch) },
    .{ "dcsens", an(.dcsens) }, .{ "hblin", an(.hblin) },     .{ "net", an(.sp) },
    .{ "if", cond(.@"if") },  .{ "elseif", cond(.elseif) },       .{ "else", cond(.@"else") },
    .{ "endif", cond(.endif) }, .{ "meas", .meas },           .{ "measure", .meas },
    .{ "save", .save },         .{ "dcvolt", .ic },                 .{ "nodeset", .nodeset },
    .{ "global", .global },     .{ "connect", .connect },           .{ "jitter", .meas },
    .{ "store", .store },       .{ "sample", .sample },
    .{ "control", .control },   .{ "endc", .endc },
    .{ "print", .ignored },     .{ "plot", .ignored },              .{ "probe", .ignored },
    .{ "graph", .ignored },     .{ "width", .ignored },             .{ "title", .ignored },
    .{ "protect", .ignored },   .{ "unprotect", .ignored },         .{ "prot", .ignored },
    .{ "unprot", .ignored },
});

/// Sweep and variation cards (frontend/variants.zig).
const variant_cards = std.StaticStringMap(Card).initComptime(.{
    .{ "step", .step }, .{ "data", .data }, .{ "enddata", .enddata }, .{ "variation", .variation }, .{ "end_variation", .end_variation },
});

/// A behavioural E/F/G/H form, named by the word in the first control-node
/// slot (ngspice inpcom.c, HSPICE's E/G element keywords).
const Form = enum { value, poly, table, pwl, laplace, delay, vcr, vccap, kind, refused };

const behavioural = std.StaticStringMap(Form).initComptime(.{
    .{ "poly", .poly },       .{ "value", .value },   .{ "vol", .value },      .{ "cur", .value },
    .{ "table", .table },     .{ "laplace", .laplace }, .{ "pole", .refused }, .{ "freq", .refused },
    .{ "vcr", .vcr },         .{ "vccap", .vccap },   .{ "delay", .delay },    .{ "opamp", .refused },
    .{ "npwl", .refused },    .{ "ppwl", .refused },  .{ "pwl", .pwl },        .{ "and", .refused },
    .{ "nand", .refused },    .{ "or", .refused },    .{ "nor", .refused },    .{ "vcvs", .kind },
    .{ "vccs", .kind },       .{ "ccvs", .kind },     .{ "cccs", .kind },      .{ "transformer", .refused },
});

/// Row of `key` in `kvs`.
fn kvIndex(kvs: []const Kv, key: []const u8) ?usize {
    for (kvs, 0..) |kv, i| if (std.mem.eql(u8, kv.key, key)) return i;
    return null;
}

/// Steps `pw` to the exponents of the next SPICE 2G6 polynomial term: a
/// literal port of NXTPWR (XSPICE spice2poly), which orders the terms as
/// the expansion of (a + (b + c))^k, k = 1, 2, ...
fn nextPower(pw: []u32) void {
    const dim = pw.len;
    if (dim == 1) {
        pw[0] += 1;
        return;
    }
    var k = dim;
    while (k > 0 and pw[k - 1] == 0) k -= 1;
    if (k == 0) {
        pw[0] += 1;
        return;
    }
    if (k != dim) {
        pw[k - 1] -= 1;
        pw[k] += 1;
        return;
    }
    for (pw[0 .. k - 1]) |e| {
        if (e != 0) break;
    } else {
        pw[0] = pw[dim - 1] + 1;
        pw[dim - 1] = 0;
        return;
    }
    var psum: u32 = 1;
    k = dim;
    while (pw[k - 2] < 1) : (k -= 1) {
        psum += pw[k - 1];
        pw[k - 1] = 0;
    }
    pw[k - 1] += psum;
    pw[k - 2] -= 1;
}

test "nextPower: SPICE 2G6 term order" {
    var pw: [2]u32 = .{ 0, 0 };
    const want = [_][2]u32{ .{ 1, 0 }, .{ 0, 1 }, .{ 2, 0 }, .{ 1, 1 }, .{ 0, 2 }, .{ 3, 0 }, .{ 2, 1 } };
    for (want) |e| {
        nextPower(&pw);
        try std.testing.expectEqual(e, pw);
    }
    var p3: [3]u32 = .{ 0, 0, 0 };
    const want3 = [_][3]u32{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 2, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 1 }, .{ 0, 2, 0 }, .{ 0, 1, 1 }, .{ 0, 0, 2 }, .{ 3, 0, 0 } };
    for (want3) |e| {
        nextPower(&p3);
        try std.testing.expectEqual(e, p3);
    }
}

/// The card a `.keyword` names, case-insensitively; null for any other card.
fn cardOf(head: []const u8) ?Card {
    var buf: [16]u8 = undefined;
    if (head.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..head.len], head);
    return cards.get(lower) orelse variant_cards.get(lower);
}

/// Parses `src` in `dialect` into `arena`. The result borrows `src` (paths
/// keep their original case) and the arena.
pub fn parse(arena: Allocator, src: []const u8, dialect: Dialect) Error!Netlist {
    return switch (dialect) {
        inline else => |d| Reader(lines.Syntax(d)).run(arena, src, d),
    };
}

/// Parses analysis cards appended to a built circuit, resolving nets through
/// `lookup.node(name) u32`. Any other line, and a single-value `.temp`, is
/// refused with `UnsupportedDirectiveMutation`.
pub fn parseAnalyses(arena: Allocator, text: []const u8, lookup: anytype) (Error || error{UnsupportedDirectiveMutation})![]Analysis {
    const lower = try arena.alloc(u8, text.len);
    _ = lines.normalize(1, lower, text);
    var r: Reader(lines.ngspice) = try .init(arena, text, lower, .ngspice);
    r.global_scopes = .{&r.globals};
    var src: lines.ngspice.Lines = .{ .rest = lower, .arena = arena };
    var out: std.ArrayList(Analysis) = .empty;
    while (try src.next()) |line| {
        if (line[0] != '.') return error.UnsupportedDirectiveMutation;
        var f = lines.ngspice.Split.init(line);
        const card = cardOf(f.next().?[1..]) orelse return error.UnsupportedDirectiveMutation;
        if (card != .analysis) return error.UnsupportedDirectiveMutation;
        const args = try r.readArgs(&f);
        // A single `.temp` is deck configuration, fixed at build.
        if (card.analysis == .temp and args.len == 1) return error.UnsupportedDirectiveMutation;
        const first = out.items.len;
        try appendAnalysis(arena, &out, .{ .kind = card.analysis, .args = args, .line = line, .sn = isSn(line) });
        for (out.items[first..]) |*a| resolve(a, lookup);
    }
    return out.items;
}

/// `.sn`, `.snac`, `.snnoise` or `.snxf`: the HSPICE shooting-Newton
/// spelling of a periodic card. `.snosc` keeps the `.pss` form.
fn isSn(line: []const u8) bool {
    const words = std.StaticStringMap(void).initComptime(.{ .{"sn"}, .{"snac"}, .{"snnoise"}, .{"snxf"}, .{"ptdnoise"} });
    const head = line[1 .. std.mem.indexOfAny(u8, line, " \t") orelse line.len];
    var buf: [8]u8 = undefined;
    return head.len <= buf.len and words.has(std.ascii.lowerString(buf[0..head.len], head));
}

/// Name inside a `v(...)` group, or a bare name; `which` 1 is the reference.
fn groupNode(value: Value, which: usize, buf: *[24]u8) ?[]const u8 {
    return switch (value) {
        .name => |n| if (which == 0) n else null,
        .group => |g| if (std.ascii.eqlIgnoreCase(g.name, "v") and g.args.len > which) nodeText(g.args[which], buf) else null,
        else => null,
    };
}

/// A node spelled as a bare argument: a name, or an integral number (`.pz 1 0 3 0`).
fn nodeText(value: Value, buf: *[24]u8) ?[]const u8 {
    return switch (value) {
        .name => |n| n,
        .num => |n| if (n == @trunc(n) and @abs(n) < 1e9)
            std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch null
        else
            null,
        else => null,
    };
}

/// Output and `.pz` nets of `a`, through `lookup.node(name) u32`.
fn resolve(a: *Analysis, lookup: anytype) void {
    const arg: usize = if (a.kind == .four) 1 else 0;
    var buf: [24]u8 = undefined;
    if (arg < a.args.len) {
        if (groupNode(a.args[arg], 0, &buf)) |n| a.pos = lookup.node(n);
        if (groupNode(a.args[arg], 1, &buf)) |n| a.neg = lookup.node(n);
    }
    // `.lstb ... localgnd=n` (VACASK `acstb`): `pos` is the local ground,
    // ground itself when absent.
    if (a.kind == .lstb) {
        a.pos = 0;
        for (a.args[0 .. a.args.len -| 1], 1..) |v, i| if (v == .name and std.ascii.eqlIgnoreCase(v.name, "localgnd")) {
            const n = nodeText(a.args[i], &buf) orelse continue;
            a.pos = if (isGroundName(n)) 0 else lookup.node(n);
        };
    }
    if (a.kind != .pz) return;
    for (&a.ports, 0..) |*id, i| {
        if (i >= a.args.len) break;
        const port = nodeText(a.args[i], &buf) orelse continue;
        id.* = if (isGroundName(port)) 0 else lookup.node(port);
    }
}

const Entry = union(enum) { num: f64, text: []const u8 };
const Scope = std.StringHashMapUnmanaged(Entry);

/// Where an expanded card is read: the enclosing `X` card's full name, its
/// port map, and the parameter scopes, outermost first.
const Frame = struct {
    path: ?[]const u8 = null,
    ports: []const []const u8 = &.{},
    actuals: []const VertexId = &.{},
    scopes: []const *const Scope,
    depth: u8 = 0,
    instance: u32 = 0,
    /// The subcircuit being expanded, null at top level.
    sub: ?u16 = null,
    /// Where this instance's rows start in `Reader.instance_models`.
    models_mark: u32 = 0,
};

const Subckt = struct {
    name: []const u8,
    ports: []const []const u8,
    defaults: []const struct { key: []const u8, text: []const u8 },
    /// Lines between `.subckt` and `.ends`. Dot cards among them are global,
    /// except `.model` (`LocalModel`).
    first: u32,
    end: u32,
    /// This subcircuit's `.model` cards, `Reader.local_models[models_lo..models_hi]`.
    models_lo: u32 = 0,
    models_hi: u32 = 0,
    /// Some line in the body is an `.if` chain card: `expand` reads the dot
    /// cards only then, since a PDK wrapper carries ~180 `.model` bins.
    has_cond: bool = false,
};

const ModelRow = struct { name: []const u8, kind: []const u8, kv: Span };

/// A `.model` card inside a subcircuit. As in ngspice (subckt.c
/// modtranslate), only cards of that subcircuit's own body see it. `top` is
/// the card read at global scope. Every instance shares it when `shared`;
/// otherwise each `X` instance reads the card again under its own
/// parameters, because its values need one the global scope lacks (IHP's
/// `pre_layout`, or the subcircuit's `l`/`w`) or it sits under the body's
/// `.if` (`cond`), which only an instance can decide.
const LocalModel = struct { name: []const u8, line: u32, top: u32, shared: bool, cond: bool };

/// A `.model` line and whether it sits under a subcircuit body's `.if`.
const ModelLine = struct { line: u32, cond: bool };

fn Reader(comptime S: type) type {
    const F = S.Split;
    return struct {
        const R = @This();

        arena: Allocator,
        dialect: Dialect,
        orig: []const u8,
        text: []const u8,
        lines: std.ArrayList([]const u8) = .empty,
        hg: Hypergraph.Builder,
        pool: InternPool = .{},
        /// The net of each name, `none` for a device name.
        net_of: std.ArrayList(u32) = .empty,
        /// A flattened name under construction.
        name_buf: std.ArrayList(u8) = .empty,
        values: std.ArrayList(Value) = .empty,
        kvs: std.ArrayList(Kv) = .empty,
        ops: std.ArrayList(expr.Op) = .empty,
        consts: std.ArrayList(f64) = .empty,
        models: std.ArrayList(ModelRow) = .empty,
        model_ids: std.StringHashMapUnmanaged(u32) = .empty,
        subckts: std.ArrayList(Subckt) = .empty,
        subckt_ids: std.StringHashMapUnmanaged(u16) = .empty,
        /// Every subcircuit's `.model` cards, in line order.
        local_models: std.ArrayList(LocalModel) = .empty,
        /// Names in `local_models`, for `isModel`.
        local_names: std.StringHashMapUnmanaged(void) = .empty,
        /// `.option scale` and `wnflag`, read before any device.
        scale: f64 = 1,
        wnflag: bool = false,
        /// Model rows read from each `local_models` line, one per distinct
        /// set of values, so instances with equal parameters share a row.
        variants: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
        /// `(name, row)` of the instance models the open expansions resolved;
        /// `Frame.models_mark` splits it by instance.
        instance_models: std.ArrayList(struct { name: []const u8, row: u32 }) = .empty,
        globals: Scope = .empty,
        global_scopes: [1]*const Scope = undefined,
        analyses: std.ArrayList(Analysis) = .empty,
        config: std.ArrayList(Config) = .empty,
        ic_cards: std.ArrayList([]const Value) = .empty,
        nodeset_cards: std.ArrayList([]const Value) = .empty,
        meas_lines: std.ArrayList([]const u8) = .empty,
        /// `.global` names: one net at every subcircuit level.
        global_nets: std.StringHashMapUnmanaged(void) = .empty,
        saves: std.ArrayList([]const u8) = .empty,
        save_all: bool = false,
        save_op: ?core.SaveOp = null,
        sample: ?core.query.NoiseSample = null,
        foreign: std.ArrayList(Foreign) = .empty,
        measures: std.ArrayList(core.Measure) = .empty,
        instances: u32 = 1,
        /// `.data` and `.variation` blocks: first and one-past-last line.
        blocks: std.ArrayList([2]u32) = .empty,
        steps: std.ArrayList(Step) = .empty,
        data: std.ArrayList(Data) = .empty,
        variations: std.ArrayList(Variation) = .empty,
        /// Top-level `.if`/`.elseif` conditions evaluated in walk 1, in order.
        cond_texts: std.ArrayList([]const u8) = .empty,
        /// Swept global parameters, registered before any device is read.
        live_names: std.StringArrayHashMapUnmanaged(void) = .empty,
        live_nominal: std.ArrayList(f64) = .empty,
        /// A device or model value is being read: one that reads a live name
        /// or (under `monte`) a distribution keeps its postfix.
        in_card: bool = false,
        /// A live name may appear outside a card (a live name's own value).
        live_ok: bool = false,
        /// Some card runs Monte Carlo.
        monte: bool = false,
        optimize: ?Optimize = null,
        site_ops: std.ArrayList(u32) = .empty,
        site_keys: std.ArrayList(u64) = .empty,
        /// Key of the text whose distribution calls are being emitted, and
        /// the next call's ordinal within it.
        site_owner: u64 = 0,
        site_ordinal: u32 = 0,
        // Per-card scratch.
        nodes: std.ArrayList([]const u8) = .empty,
        pins: std.ArrayList(VertexId) = .empty,
        positional: std.ArrayList(Value) = .empty,
        card_kv: std.ArrayList(Kv) = .empty,
        scratch: expr.Scratch = .{},
        stack: std.ArrayList(expr.Val) = .empty,

        fn init(arena: Allocator, orig: []const u8, text: []const u8, dialect: Dialect) Allocator.Error!R {
            var r: R = .{ .arena = arena, .dialect = dialect, .orig = orig, .text = text, .hg = try .init(arena) };
            const zero = try r.pool.intern(arena, "0");
            _ = r.hg.addVertex(arena, .{ .name = zero }) catch return error.OutOfMemory;
            try r.net_of.append(arena, 0);
            return r;
        }

        fn run(arena: Allocator, src: []const u8, dialect: Dialect) Error!Netlist {
            var line_hint: usize = undefined;
            const text: []const u8 = if (S.fold_case) blk: {
                const buf = try arena.alloc(u8, src.len);
                line_hint = lines.normalize(std.simd.suggestVectorLength(u8) orelse 1, buf, src);
                break :blk buf;
            } else blk: {
                line_hint = std.mem.countScalar(u8, src, '\n');
                break :blk src;
            };
            var r: R = try .init(arena, src, text, dialect);
            r.global_scopes = .{&r.globals};
            var split: S.Lines = .{ .rest = text, .arena = arena };
            var title: []const u8 = "";
            if (S.title_line) {
                const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
                title = std.mem.trim(u8, text[0..nl], " \t\r");
                split.rest = if (nl < text.len) text[nl + 1 ..] else "";
            }
            try r.lines.ensureTotalCapacity(arena, line_hint);
            while (try split.next()) |line| try r.lines.append(arena, line);
            try r.hg.ensureTotalCapacity(arena, line_hint + 1, line_hint, 3 * line_hint);
            try r.pool.reserve(arena, @intCast(@min(2 * line_hint, none - 1)));
            try r.values.ensureTotalCapacity(arena, line_hint);

            var top_devices: std.ArrayList(u32) = .empty;
            var model_lines: std.ArrayList(ModelLine) = .empty;
            var directive_lines: std.ArrayList(u32) = .empty;
            try r.declarations(&top_devices, &model_lines, &directive_lines);
            const top: Frame = .{ .scopes = &r.global_scopes };
            // Model lines and subcircuit bodies both run in line order.
            var s: usize = 0;
            for (model_lines.items) |ml| {
                const subs = r.subckts.items;
                while (s < subs.len and subs[s].end <= ml.line) s += 1;
                const local = s < subs.len and ml.line >= subs[s].first;
                try r.readModel(r.lines.items[ml.line], &top, !local);
                if (!local) continue;
                const row: u32 = @intCast(r.models.items.len - 1);
                const name = r.models.items[row].name;
                const shared = !ml.cond and !r.unresolved(r.models.items[row].kv) and !r.namesParam(r.models.items[row].kv, subs[s]);
                if (subs[s].models_hi == 0) subs[s].models_lo = @intCast(r.local_models.items.len);
                try r.local_models.append(arena, .{ .name = name, .line = ml.line, .top = row, .shared = shared, .cond = ml.cond });
                subs[s].models_hi = @intCast(r.local_models.items.len);
                try r.local_names.put(arena, name, {});
            }
            for (r.blocks.items) |b| try r.readBlock(b);
            for (directive_lines.items) |i| try r.readDirective(r.lines.items[i]);
            try r.binOptions();

            for (top_devices.items) |i| try r.readDevice(r.lines.items[i], &top);
            try r.shunts();
            try r.readMeasures();
            var live = try r.resolveLive();
            live.conds = try r.liveConds();
            try r.modelBins(live);

            const graph = try r.hg.finish(arena);
            const models = try arena.alloc(Model, r.models.items.len);
            for (models, r.models.items) |*m, row| m.* = .{ .name = row.name, .kind = row.kind, .kv = r.kvs.items[row.kv.start..][0..row.kv.len] };

            // Stable counting sort of devices by card letter.
            const kinds = graph.edges.items(.kind);
            var starts: [27]u32 = @splat(0);
            for (kinds) |k| starts[k - 'a' + 1] += 1;
            for (1..starts.len) |i| starts[i] += starts[i - 1];
            const order = try arena.alloc(EdgeId, kinds.len);
            var next: [26]u32 = starts[0..26].*;
            for (kinds, 0..) |k, e| {
                order[next[k - 'a']] = .from(e);
                next[k - 'a'] += 1;
            }

            const nets: NetLookup = .{ .pool = &r.pool, .net_of = r.net_of.items };
            for (r.analyses.items) |*a| resolve(a, nets);

            return .{
                .pool = r.pool,
                .graph = graph,
                .order = order,
                .kind_starts = starts,
                .values = r.values.items,
                .kvs = r.kvs.items,
                .ops = r.ops.items,
                .consts = r.consts.items,
                .models = models,
                .model_ids = r.model_ids,
                .live = live,
                .deck = .{
                    .title = title,
                    .dialect = dialect,
                    .analyses = r.analyses.items,
                    .config = r.config.items,
                    .ic = try nodeValues(arena, r.ic_cards.items, nets),
                    .nodeset = try nodeValues(arena, r.nodeset_cards.items, nets),
                    .saves = if (r.save_all) &.{} else r.saves.items,
                    .foreign = r.foreign.items,
                    .measures = r.measures.items,
                    .steps = r.steps.items,
                    .data = r.data.items,
                    .variations = r.variations.items,
                    .optimize = r.optimize,
                    .save_op = r.save_op,
                    .sample = r.sample,
                },
            };
        }

        /// `v(net)=value` pairs (or bare `net value`, as `.dcvolt` allows) of
        /// `.ic`-style cards; a net no card names is dropped.
        fn nodeValues(arena: Allocator, cards_args: []const []const Value, nets: NetLookup) Error![]const Ic {
            var out: std.ArrayList(Ic) = .empty;
            for (cards_args) |args| {
                var buf: [24]u8 = undefined;
                var i: usize = 0;
                while (i + 1 < args.len) : (i += 2) {
                    const name = switch (args[i]) {
                        .group => |g| if (std.ascii.eqlIgnoreCase(g.name, "v") and g.args.len > 0) nodeText(g.args[0], &buf) else null,
                        else => nodeText(args[i], &buf),
                    } orelse continue;
                    const value = switch (args[i + 1]) {
                        .num => |n| n,
                        else => continue,
                    };
                    const id = nets.node(name);
                    if (id == none or id == 0) continue;
                    try out.append(arena, .{ .net = .from(id), .value = value });
                }
            }
            return out.items;
        }

        const NetLookup = struct {
            pool: *const InternPool,
            net_of: []const u32,
            pub fn node(self: NetLookup, name: []const u8) u32 {
                if (std.mem.eql(u8, name, "0")) return 0;
                const n = self.pool.find(name) orelse return none;
                return self.net_of[n.index()];
            }
        };

        // Walk 1: declarations.

        fn declarations(r: *R, top: *std.ArrayList(u32), models: *std.ArrayList(ModelLine), directives: *std.ArrayList(u32)) Error!void {
            const arena = r.arena;
            var open: ?u16 = null;
            var defaults: std.ArrayList(@typeInfo(@FieldType(Subckt, "defaults")).pointer.child) = .empty;
            // Top-level `.if` conditions see the `.param` cards above them.
            // Inside a subcircuit they are left to `expand`, per instance;
            // `sub_ifs` counts the open ones so a `.model` there is marked.
            // ponytail: a `.param` under a subcircuit's `.if` applies
            // unconditionally; scope it when a PDK needs it.
            var branches: Branches = .{};
            var sub_ifs: u8 = 0;
            const global: Frame = .{ .scopes = &r.global_scopes };
            // An open `.data` or `.variation` block: its closing card and first line.
            var block: ?struct { close: Card, first: u32 } = null;
            // Inside `.control`/`.endc`: ngspice's interpreter. Only the
            // model loads matter to a batch run; the rest is skipped aloud.
            var control = false;
            for (r.lines.items, 0..) |line, index| {
                const i: u32 = @intCast(index);
                if (control) {
                    var cf = F.init(line);
                    const head = cf.next().?;
                    if (std.ascii.eqlIgnoreCase(head, ".endc")) {
                        control = false;
                    } else if (std.ascii.eqlIgnoreCase(head, "pre_osdi") or std.ascii.eqlIgnoreCase(head, "osdi")) {
                        if (branches.active()) try r.foreign.append(arena, .{ .kind = .pre_osdi, .path = try r.pathOf(&cf) });
                    } else if (!@import("builtin").is_test) std.log.warn("netlist: .control command '{s}' ignored", .{head});
                    continue;
                }
                if (block) |b| {
                    if (line[0] != '.') continue;
                    var bf = F.init(line);
                    const c = cardOf(bf.next().?[1..]) orelse continue;
                    if (std.meta.activeTag(c) != std.meta.activeTag(b.close)) continue;
                    if (open == null and branches.active()) try r.blocks.append(arena, .{ b.first, i });
                    block = null;
                    continue;
                }
                const live = open != null or branches.active();
                if (line[0] != '.') {
                    if (open == null and live) try top.append(arena, i);
                    continue;
                }
                var f = F.init(line);
                const head = f.next().?;
                if (head.len < 2) return error.ParseError;
                const card = cardOf(head[1..]) orelse {
                    if (live) try directives.append(arena, i);
                    continue;
                };
                if (card == .cond) {
                    if (open) |id| {
                        r.subckts.items[id].has_cond = true;
                        switch (card.cond) {
                            .@"if" => sub_ifs +|= 1,
                            .endif => sub_ifs -|= 1,
                            else => {},
                        }
                    } else try r.branch(&branches, card.cond, &f, &global);
                    continue;
                }
                if (card == .control) {
                    control = true;
                    continue;
                }
                if (card == .data or card == .variation) {
                    block = .{ .close = if (card == .data) .enddata else .end_variation, .first = i };
                    continue;
                }
                if (!live) continue;
                switch (card) {
                    .end => break,
                    .ends => {
                        const id = open orelse return error.ParseError;
                        r.subckts.items[id].end = i;
                        r.subckts.items[id].defaults = defaults.items;
                        open = null;
                        sub_ifs = 0;
                    },
                    .subckt => {
                        if (open != null) return error.ParseError;
                        const name = f.next() orelse return error.ParseError;
                        var ports: std.ArrayList([]const u8) = .empty;
                        defaults = .empty;
                        while (f.next()) |t| {
                            if (t[0] == '(' or t[0] == ')') continue;
                            if (!F.isWord(t)) return error.ParseError;
                            if (std.mem.eql(u8, t, "params:")) continue;
                            if (f.takeEq())
                                try defaults.append(arena, .{ .key = t, .text = try r.paramText(&f) })
                            else
                                try ports.append(arena, t);
                        }
                        if (!F.isWord(name)) return error.ParseError;
                        if (r.subckts.items.len == std.math.maxInt(u16)) return error.CircuitTooLarge;
                        open = @intCast(r.subckts.items.len);
                        try r.subckts.append(arena, .{ .name = name, .ports = ports.items, .defaults = &.{}, .first = i + 1, .end = i + 1 });
                        try r.subckt_ids.put(arena, name, open.?);
                    },
                    .param => while (f.next()) |key| {
                        if (!F.isWord(key)) return error.ParseError;
                        const eq = f.next() orelse return error.ParseError;
                        if (eq[0] != '=') return error.ParseError;
                        const text = try r.paramText(&f);
                        if (open != null)
                            try defaults.append(arena, .{ .key = key, .text = text })
                        else
                            try r.globals.put(arena, key, .{ .text = text });
                    },
                    .model => try models.append(arena, .{ .line = i, .cond = open != null and sub_ifs > 0 }),
                    .include, .osdi_include, .pre_osdi, .verilog => {
                        const path = try r.pathOf(&f);
                        const kind: ForeignKind = switch (card) {
                            .osdi_include => .osdi_include,
                            .pre_osdi => .pre_osdi,
                            .verilog => .verilog,
                            else => source.foreignKindForPath(path) orelse continue,
                        };
                        try r.foreign.append(arena, .{ .kind = kind, .path = path });
                    },
                    else => try directives.append(arena, i),
                }
            }
            if (open != null or branches.depth != 0 or block != null or control) return error.ParseError;
        }

        /// Applies one `.if`/`.elseif`/`.else`/`.endif` card to `b`. A
        /// condition is the rest of the line, evaluated under `frame` only
        /// when its branch could still be taken; nonzero is true.
        fn branch(r: *R, b: *Branches, card: CondCard, f: *F, frame: *const Frame) Error!void {
            if (card == .@"if") {
                if (b.depth == Branches.max) return error.ParseError;
                b.open[b.depth] = if (!b.active()) .spent else if (try r.condition(f, frame)) .live else .pending;
                b.depth += 1;
                return;
            }
            if (b.depth == 0) return error.ParseError;
            const top = &b.open[b.depth - 1];
            switch (card) {
                .@"if" => unreachable,
                .elseif => top.* = if (top.* != .pending) .spent else if (try r.condition(f, frame)) .live else .pending,
                .@"else" => top.* = if (top.* == .pending) .live else .spent,
                .endif => b.depth -= 1,
            }
        }

        fn condition(r: *R, f: *F, frame: *const Frame) Error!bool {
            const was_in_card = r.in_card;
            r.in_card = false;
            defer r.in_card = was_in_card;
            if (frame.sub == null) try r.cond_texts.append(r.arena, f.rest());
            return switch (try r.exprValue(f.rest(), frame, false)) {
                .num => |n| n != 0,
                else => error.ParseError,
            };
        }

        /// A quoted or bare path; its original case survives case folding.
        fn pathOf(r: *R, f: *F) Error![]const u8 {
            const t = f.next() orelse return error.ParseError;
            var path = t;
            if (F.isQuote(t[0])) {
                path = F.body(t);
            } else if (!F.isWord(t)) {
                return error.ParseError;
            } else if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) {
                path = t[1 .. t.len - 1];
            }
            const at = @intFromPtr(path.ptr);
            const base = @intFromPtr(r.text.ptr);
            if (at >= base and at + path.len <= base + r.text.len) return r.orig[at - base ..][0..path.len];
            return path;
        }

        /// The text a parameter definition is re-read from on every use.
        fn paramText(r: *R, f: *F) Error![]const u8 {
            const rest = f.rest();
            if (rest.len == 0) return error.ParseError;
            if (rest[0] == '{' or rest[0] == '\'') {
                const t = f.next().?;
                return if (!F.isWord(t)) F.body(t) else t;
            }
            const mark = r.scratch.mark();
            defer r.scratch.reset(mark);
            const start = f.pos;
            f.pos = try expr.compile(S.parseNum, r.arena, &r.scratch, f.line, f.pos);
            return f.line[start..f.pos];
        }

        /// Reads a `.model` card under `frame` into a new row; `global`
        /// makes it the row its name resolves to outside subcircuits.
        fn readModel(r: *R, line: []const u8, frame: *const Frame, global: bool) Error!void {
            var f = F.init(line);
            _ = f.next();
            const name = f.next() orelse return error.ParseError;
            const kind = f.next() orelse return error.ParseError;
            if (!F.isWord(name) or !F.isWord(kind)) return error.ParseError;
            const was_in_card = r.in_card;
            r.in_card = true;
            defer r.in_card = was_in_card;
            r.site_owner = nameKey(nameKey(0, frame.path orelse ""), name);
            r.site_ordinal = 0;
            const matrix_keys = std.StaticStringMap(void).initComptime(.{ .{ "r", {} }, .{ "l", {} }, .{ "g", {} }, .{ "c", {} } });
            // CPL matrices are blank-separated; a negative entry is not a subtraction.
            const cpl = std.mem.eql(u8, kind, "cpl");
            r.card_kv.clearRetainingCapacity();
            while (f.next()) |t| {
                if (t[0] == '(' or t[0] == ')' or t[0] == ',') continue;
                if (!F.isWord(t)) return error.ParseError;
                if (f.takeEq()) {
                    // DEV/LOT tolerances apply to the value before them;
                    // the global-scope read records them once.
                    const prev = if (r.card_kv.items.len > 0) r.card_kv.items[r.card_kv.items.len - 1].key else "";
                    if (try r.devLot(t, prev, name, &f, line)) |v| {
                        if (global) try r.variations.append(r.arena, v);
                        continue;
                    }
                    const value = if (cpl and matrix_keys.has(t)) try r.readValue(&f, frame, true, true) else try r.kvValue(&f, frame, true);
                    try r.card_kv.append(r.arena, .{ .key = t, .value = value });
                } else {
                    const value: Value = if (S.parseNum(t)) |n| .{ .num = n } else try r.nameValue(t, frame, true);
                    try r.card_kv.append(r.arena, .{ .key = "", .value = value });
                }
            }
            const span = try appendSpan(Kv, r.arena, &r.kvs, r.card_kv.items);
            if (global) {
                const gop = try r.model_ids.getOrPut(r.arena, name);
                if (!gop.found_existing) gop.value_ptr.* = @intCast(r.models.items.len);
            }
            try r.models.append(r.arena, .{ .name = name, .kind = kind, .kv = span });
        }

        /// True when a value in `span` did not fold: it names a parameter the
        /// global scope lacks, which no device could bind.
        fn unresolved(r: *const R, span: Span) bool {
            for (r.kvs.items[span.start..][0..span.len]) |kv| if (kv.value == .expr) return true;
            return false;
        }

        /// True when a value in `span` is a bare name `sub` declares as a
        /// parameter: read at global scope it stayed a name, but each
        /// instance substitutes its own value.
        fn namesParam(r: *const R, span: Span, sub: Subckt) bool {
            for (r.kvs.items[span.start..][0..span.len]) |kv| if (kv.value == .name) {
                for (sub.defaults) |d| if (std.mem.eql(u8, d.key, kv.value.name)) return true;
            };
            return false;
        }

        /// The model row card `letter` inside `frame` names: a `.model` of
        /// the frame's own subcircuit (for an M card, the `name.N` bin the
        /// card's L and W select, as ngspice bins the renamed subcircuit
        /// models), else the first global row. Rewrites the card's model
        /// name, `r.values[pos]`, to the bin it picks.
        fn modelRow(r: *R, letter: u8, name: []const u8, pos: u32, frame: *const Frame) Error!u32 {
            const sub = r.subckts.items[frame.sub orelse return r.model_ids.get(name) orelse none];
            for (r.instance_models.items[frame.models_mark..]) |m| if (std.mem.eql(u8, m.name, name)) return m.row;
            const locals = r.local_models.items[sub.models_lo..sub.models_hi];
            for (locals) |m| if (!m.cond and std.mem.eql(u8, m.name, name)) return r.localRow(m, frame);
            if (letter != 'm') return r.model_ids.get(name) orelse none;
            // ngspice prepends model declarations (inpmkmod.c): the last
            // matching bin wins, as in `modelBins`.
            const kv = r.card_kv.items;
            const l = (number(kv, "l") orelse return r.model_ids.get(name) orelse none) * r.scale;
            const use_nf = if (number(kv, "wnflag")) |flag| flag != 0 else r.wnflag;
            const nf = if (use_nf) number(kv, "nf") orelse 1 else 1;
            const w = (number(kv, "w") orelse return r.model_ids.get(name) orelse none) * r.scale / nf;
            var k = locals.len;
            while (k > 0) {
                k -= 1;
                const m = locals[k];
                if (m.cond or !isBinOf(m.name, name)) continue;
                // ponytail: bounds from the global-scope read; a bin whose
                // bounds need instance parameters is never picked.
                const b = binBounds(r.kvs.items[r.models.items[m.top].kv.start..][0..r.models.items[m.top].kv.len]) orelse continue;
                if (!binHolds(b, l, w)) continue;
                r.values.items[pos] = .{ .name = m.name };
                return r.localRow(m, frame);
            }
            return r.model_ids.get(name) orelse none;
        }

        /// The row of local model `m` for the instance `frame` expands: the
        /// shared global-scope row, else one read under the instance's
        /// parameters on first use.
        fn localRow(r: *R, m: LocalModel, frame: *const Frame) Error!u32 {
            if (m.shared) return m.top;
            const line = m.line;
            const name = m.name;
            const kv_mark = r.kvs.items.len;
            try r.readModel(r.lines.items[line], frame, false);
            var row: u32 = @intCast(r.models.items.len - 1);
            const gop = try r.variants.getOrPut(r.arena, line);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const fresh = r.kvs.items[kv_mark..];
            for (gop.value_ptr.items) |old| {
                const kv = r.models.items[old].kv;
                if (!sameValues(r.kvs.items[kv.start..][0..kv.len], fresh)) continue;
                r.models.shrinkRetainingCapacity(row);
                r.kvs.shrinkRetainingCapacity(kv_mark);
                row = old;
                break;
            } else try gop.value_ptr.append(r.arena, row);
            try r.instance_models.append(r.arena, .{ .name = name, .row = row });
            return row;
        }

        /// Equal keys and values; an unfolded expression never compares equal.
        fn sameValues(a: []const Kv, b: []const Kv) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| {
                if (!std.mem.eql(u8, x.key, y.key)) return false;
                const same = switch (x.value) {
                    .num => |n| y.value == .num and y.value.num == n,
                    .name => |n| y.value == .name and std.mem.eql(u8, y.value.name, n),
                    else => false,
                };
                if (!same) return false;
            }
            return true;
        }

        fn readArgs(r: *R, f: *F) Error![]const Value {
            const top: Frame = .{ .scopes = &r.global_scopes };
            var args: std.ArrayList(Value) = .empty;
            while (f.next()) |t| {
                if (t[0] == ',' or t[0] == '=') continue;
                const last = if (args.items.len != 0) args.items[args.items.len - 1] else Value{ .num = 0 };
                if (last == .name and std.mem.eql(u8, last.name, "monte") and std.ascii.eqlIgnoreCase(t, "list")) {
                    // `MONTE=list(10 20:30)`, parentheses optional: the trial
                    // numbers follow `list`, each `a:b` range expanded.
                    try args.append(r.arena, .{ .name = "list" });
                    while (f.next()) |n| {
                        if (n[0] == ')') break;
                        if (n[0] == '(' or n[0] == ',') continue;
                        const colon = std.mem.indexOfScalar(u8, n, ':') orelse n.len;
                        const lo = S.parseNum(n[0..colon]) orelse return error.ParseError;
                        const hi = if (colon == n.len) lo else S.parseNum(n[colon + 1 ..]) orelse return error.ParseError;
                        if (!(lo >= 1 and hi >= lo and hi <= std.math.maxInt(u32)) or lo != @trunc(lo) or hi != @trunc(hi)) return error.ParseError;
                        var k = lo;
                        while (k <= hi) : (k += 1) try args.append(r.arena, .{ .num = k });
                    }
                    continue;
                }
                try args.append(r.arena, try r.valueAt(t, f, &top, false, false));
            }
            return args.items;
        }

        fn readDirective(r: *R, line: []const u8) Error!void {
            var f = F.init(line);
            const card = cardOf(f.next().?[1..]);
            // Read once every analysis card is: HSPICE's untyped `.meas`
            // takes the last one.
            if (card != null and card.? == .meas) return r.meas_lines.append(r.arena, line);
            const c = card orelse return r.unsupported(line, "unsupported card");
            if (c == .ignored) return;
            if (c == .save and r.dialect == .hspice) return r.readSaveOp(line, &f);
            // HSPICE `.store` checkpoints the process on a wall-clock
            // schedule for an OS-level restore [CR .STORE]; the results do not
            // depend on it.
            if (c == .store) return std.log.warn("netlist: .store: checkpoints are not written; the run is not restartable", .{});
            const args = try r.readArgs(&f);
            switch (c) {
                .step => try r.steps.append(r.arena, r.readStep(args) catch |err| return r.failed(line, err)),
                .analysis => |kind| {
                    // HSPICE's `.temp t1 t2 ...` lists run temperatures; ngspice's
                    // three-number form is a sweep.
                    const temp_list = kind == .temp and args.len > 1 and r.dialect == .hspice;
                    const swept = r.readSweep(kind, args) catch |err| return r.failed(line, err);
                    if (!temp_list) try appendAnalysis(r.arena, &r.analyses, .{ .kind = kind, .args = swept.args, .sweep = swept.sweep, .line = r.written(line), .dialect = r.dialect, .sn = isSn(line) });
                    if (kind == .temp and (args.len == 1 or temp_list)) try r.config.append(r.arena, .{ .temp = true, .args = args, .line = r.written(line) });
                },
                .options => try r.config.append(r.arena, .{ .temp = false, .args = args, .line = r.written(line) }),
                .ic => try r.ic_cards.append(r.arena, args),
                .sample => r.sample = r.readSample(args) catch |err| return r.failed(line, err),
                .nodeset => try r.nodeset_cards.append(r.arena, args),
                .global => for (args) |a| {
                    var buf: [24]u8 = undefined;
                    const name = nodeText(a, &buf) orelse return error.ParseError;
                    try r.global_nets.put(r.arena, try r.arena.dupe(u8, name), {});
                },
                .connect => {
                    if (args.len != 2) return error.ParseError;
                    // ponytail: top level only; a subcircuit's `.connect` needs
                    // per-instance aliases.
                    for (r.subckts.items) |s| for (r.lines.items[s.first..s.end]) |l| if (l.ptr == line.ptr)
                        return r.unsupported(line, ".connect inside a subcircuit");
                    var bufs: [2][24]u8 = undefined;
                    try r.connect(nodeText(args[0], &bufs[0]) orelse return error.ParseError, nodeText(args[1], &bufs[1]) orelse return error.ParseError);
                },
                .save => for (args) |a| switch (a) {
                    .group => |g| if (g.args.len == 1 and (std.ascii.eqlIgnoreCase(g.name, "v") or std.ascii.eqlIgnoreCase(g.name, "i"))) {
                        var buf: [24]u8 = undefined;
                        const name = nodeText(g.args[0], &buf) orelse continue;
                        const label = try std.fmt.allocPrint(r.arena, "{c}({s})", .{ std.ascii.toLower(g.name[0]), name });
                        try r.saves.append(r.arena, std.ascii.lowerString(label, label));
                    },
                    .name => |n| if (std.ascii.eqlIgnoreCase(n, "all")) {
                        r.save_all = true;
                    },
                    else => {},
                },
                else => {},
            }
        }

        /// HSPICE `.sample FS= [TOL=] [NUMF=] [MAXFLD=] [BETA=]` [CR .SAMPLE].
        /// TOL and NUMF size HSPICE's adaptive fold count; MAXFLD bounds it
        /// here, so they are checked and unused.
        fn readSample(r: *R, args: []const Value) Error!core.query.NoiseSample {
            _ = r;
            var s: core.query.NoiseSample = .{ .fs = 0 };
            var i: usize = 0;
            while (i + 1 < args.len) : (i += 2) {
                if (args[i] != .name or args[i + 1] != .num) return error.ParseError;
                const v = args[i + 1].num;
                const Key = enum { fs, tol, numf, maxfld, beta };
                switch (std.meta.stringToEnum(Key, args[i].name) orelse return error.ParseError) {
                    .fs => s.fs = v,
                    .maxfld => s.max_fold = v,
                    .beta => s.beta = v,
                    .tol, .numf => {},
                }
            }
            if (i != args.len or !(s.fs > 0) or !(s.max_fold >= 1) or !(s.beta >= 0 and s.beta <= 1)) return error.ParseError;
            return s;
        }

        /// HSPICE `.save [TYPE=NODESET|IC] [FILE=] [LEVEL=ALL|TOP|SELECT|NONE]
        /// [TIME=]` [CR .SAVE]. SELECT saves every node, as ALL; NONE saves
        /// nothing. The last card wins.
        fn readSaveOp(r: *R, line: []const u8, f: *F) Error!void {
            var save: core.SaveOp = .{};
            var none_level = false;
            while (f.next()) |key| {
                if (!F.isWord(key) or !f.takeEq()) return r.failed(line, error.ParseError);
                const Key = enum { type, file, level, time };
                switch (std.meta.stringToEnum(Key, key) orelse return r.failed(line, error.ParseError)) {
                    .file => save.file = try r.pathOf(f),
                    .time => save.time = S.parseNum(f.next() orelse "") orelse return r.failed(line, error.ParseError),
                    .type => {
                        const v = f.next() orelse "";
                        if (!std.mem.eql(u8, v, "ic") and !std.mem.eql(u8, v, "nodeset")) return r.failed(line, error.ParseError);
                        save.ic = std.mem.eql(u8, v, "ic");
                    },
                    .level => {
                        const v = f.next() orelse "";
                        const levels = std.StaticStringMap(void).initComptime(.{ .{"all"}, .{"top"}, .{"select"}, .{"none"} });
                        if (!levels.has(v)) return r.failed(line, error.ParseError);
                        save.top_only = std.mem.eql(u8, v, "top");
                        none_level = std.mem.eql(u8, v, "none");
                    },
                }
            }
            if (!(save.time >= 0)) return r.failed(line, error.ParseError);
            r.save_op = if (none_level) null else save;
        }

        /// `line` as the deck spells it: the original case when `line` is a
        /// slice of the parsed text, else the joined continuation as read.
        fn written(r: *const R, line: []const u8) []const u8 {
            const at = @intFromPtr(line.ptr);
            const base = @intFromPtr(r.text.ptr);
            return if (at >= base and at + line.len <= base + r.text.len) r.orig[at - base ..][0..line.len] else line;
        }

        /// Logs `line` with `err` and returns `err`; `ParseError` for a
        /// malformed card, `UnsupportedCard` for a form ESPice cannot run.
        fn failed(r: *const R, line: []const u8, err: Error) Error {
            if (!@import("builtin").is_test) std.log.err("netlist: {s}: {s}", .{ @errorName(err), r.written(line) });
            return err;
        }

        // Sweeps and variants.

        /// The live-table row of global `.param` `name`, registering it (and
        /// folding its nominal value) on first use; null for a name no
        /// `.param` defines.
        fn liveParam(r: *R, name: []const u8) Error!?u32 {
            if (r.live_names.getIndex(name)) |k| return @intCast(k);
            const entry = r.globals.get(name) orelse return null;
            const top: Frame = .{ .scopes = &r.global_scopes };
            r.live_ok = true;
            defer r.live_ok = false;
            const v = switch (entry) {
                .num => |n| n,
                .text => |text| switch (try r.exprValue(text, &top, false)) {
                    .num => |n| n,
                    else => return error.ParseError,
                },
            };
            try r.live_names.put(r.arena, name, {});
            try r.live_nominal.append(r.arena, v);
            return @intCast(r.live_names.count() - 1);
        }

        /// A swept name: a global `.param`, `temp`, or a card.
        fn stepTarget(r: *R, name: []const u8) Error!StepTarget {
            if (std.mem.eql(u8, name, "temp")) return .temp;
            if (try r.liveParam(name)) |k| return .{ .param = k };
            return .{ .card = name };
        }

        /// `.step [lin|dec|oct] [param] name start stop incr`, `.step
        /// [param] name list v...`, with `temp` or a source for the name
        /// (ngspice/LTspice form). `dec`/`oct` take points per decade or
        /// octave.
        fn readStep(r: *R, args: []const Value) Error!Step {
            var i: usize = 0;
            var grid: Grid = .lin;
            if (i < args.len and args[i] == .name) if (grids.get(args[i].name)) |g| {
                grid = g;
                i += 1;
            };
            const param = i < args.len and args[i] == .name and std.mem.eql(u8, args[i].name, "param");
            i += @intFromBool(param);
            if (i >= args.len or args[i] != .name) return error.ParseError;
            const target: StepTarget = if (param)
                .{ .param = try r.liveParam(args[i].name) orelse return error.ParseError }
            else
                try r.stepTarget(args[i].name);
            i += 1;
            if (i < args.len and args[i] == .name and std.mem.eql(u8, args[i].name, "list")) return .{ .target = target, .values = try r.numbers(args[i + 1 ..]) };
            if (grid == .poi) return error.ParseError;
            const n = try r.numbers(args[i..]);
            if (n.len != 3) return error.ParseError;
            return .{ .target = target, .values = try points(r.arena, grid, n[0], n[1], n[2], .per_unit) };
        }

        /// Splits an analysis card's HSPICE sweep tail (`SWEEP ...`, or a
        /// bare `DATA=`/`MONTE=` on `.dc`) off its arguments.
        fn readSweep(r: *R, kind: Kind, args: []const Value) Error!struct { args: []const Value, sweep: Sweep } {
            var at: ?usize = null;
            for (args, 0..) |a, i| if (a == .name and std.mem.eql(u8, a.name, "sweep")) {
                at = i;
                break;
            };
            if (at == null and kind == .dc and args.len >= 2 and args[0] == .name and
                (std.mem.eql(u8, args[0].name, "data") or std.mem.eql(u8, args[0].name, "monte"))) at = 0;
            const i = at orelse return .{ .args = args, .sweep = .none };
            const tail = args[i + @intFromBool(args[i] == .name and std.mem.eql(u8, args[i].name, "sweep")) ..];
            if (tail.len < 2 or tail[0] != .name) return error.ParseError;
            const head = tail[0].name;
            const sweep: Sweep = if (std.mem.eql(u8, head, "optimize")) blk: {
                // ponytail: one optimization per deck.
                if (r.optimize != null) return error.UnsupportedCard;
                r.optimize = try r.readOptimize(tail);
                break :blk .optimize;
            } else if (std.mem.eql(u8, head, "data")) blk: {
                if (tail.len != 2 or tail[1] != .name) return error.ParseError;
                break :blk .{ .data = tail[1].name };
            } else if (std.mem.eql(u8, head, "monte")) blk: {
                if (tail[1] == .name and std.mem.eql(u8, tail[1].name, "list")) {
                    const list = try r.arena.alloc(u32, tail.len - 2);
                    for (list, 2..) |*t, k| t.* = try positiveCount(tail, k);
                    if (list.len == 0) return error.ParseError;
                    r.monte = true;
                    break :blk .{ .monte = .{ .n = @intCast(list.len), .list = list } };
                }
                var m: Monte = .{ .n = try positiveCount(tail, 1) };
                if (tail.len == 4 and tail[2] == .name and std.mem.eql(u8, tail[2].name, "firstrun")) {
                    m.first = try positiveCount(tail, 3);
                } else if (tail.len != 2) return error.ParseError;
                r.monte = true;
                break :blk .{ .monte = m };
            } else blk: {
                const target = try r.stepTarget(head);
                if (tail.len >= 2 and tail[1] == .name) {
                    const grid = grids.get(tail[1].name) orelse return error.ParseError;
                    const n = try r.numbers(tail[2..]);
                    if (n.len < 1 or n[0] != @trunc(n[0]) or n[0] < 1) return error.ParseError;
                    if (grid == .poi) {
                        if (n.len != 1 + @as(usize, @intFromFloat(n[0]))) return error.ParseError;
                        break :blk .{ .step = .{ .target = target, .values = n[1..] } };
                    }
                    if (n.len != 3) return error.ParseError;
                    break :blk .{ .step = .{ .target = target, .values = try points(r.arena, grid, n[1], n[2], n[0], if (grid == .lin) .total else .per_unit) } };
                }
                const n = try r.numbers(tail[1..]);
                if (n.len != 3) return error.ParseError;
                break :blk .{ .step = .{ .target = target, .values = try points(r.arena, .lin, n[0], n[1], n[2], .per_unit) } };
            };
            return .{ .args = args[0..i], .sweep = sweep };
        }

        /// `OPTIMIZE=name RESULTS=m1,m2 MODEL=optmod`, in any order, and the
        /// parameters `name(...)` or `OPTRANGE(...)` define, registered live
        /// at their initial values in deck order.
        fn readOptimize(r: *R, tail: []const Value) Error!Optimize {
            var opt: Optimize = .{ .name = "", .results = &.{}, .model = "", .live = &.{}, .lo = &.{}, .hi = &.{}, .dels = &.{} };
            var results: std.ArrayList([]const u8) = .empty;
            const Key = enum { none, optimize, results, model };
            var key: Key = .none;
            for (tail) |v| {
                if (v != .name) return error.ParseError;
                if (std.meta.stringToEnum(Key, v.name)) |k| {
                    key = k;
                    continue;
                }
                switch (key) {
                    .optimize => opt.name = v.name,
                    .model => opt.model = v.name,
                    .results => try results.append(r.arena, v.name),
                    .none => return error.ParseError,
                }
            }
            if (opt.name.len == 0 or opt.model.len == 0 or results.items.len == 0) return error.ParseError;
            opt.results = results.items;
            const Def = struct { key: []const u8, text: []const u8 };
            var defs: std.ArrayList(Def) = .empty;
            var it = r.globals.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .text) {
                const text = e.value_ptr.text;
                const paren = std.mem.indexOfScalar(u8, text, '(') orelse continue;
                const head = std.mem.trim(u8, text[0..paren], " \t{'");
                if (std.mem.eql(u8, head, opt.name) or std.mem.eql(u8, head, "optrange"))
                    try defs.append(r.arena, .{ .key = e.key_ptr.*, .text = text[paren..] });
            };
            if (defs.items.len == 0) return error.ParseError;
            // Deck order: every definition's text is a slice of the deck.
            std.mem.sort(Def, defs.items, {}, struct {
                fn less(_: void, a: Def, b: Def) bool {
                    return @intFromPtr(a.text.ptr) < @intFromPtr(b.text.ptr);
                }
            }.less);
            const n = defs.items.len;
            const live = try r.arena.alloc(u32, n);
            const lo = try r.arena.alloc(f64, n);
            const hi = try r.arena.alloc(f64, n);
            const dels = try r.arena.alloc(f64, n);
            const top: Frame = .{ .scopes = &r.global_scopes };
            for (defs.items, live, lo, hi, dels) |d, *k, *l, *u, *h| {
                // `(init, lo, hi[, dels])`, each a number or an expression.
                const close = std.mem.lastIndexOfScalar(u8, d.text, ')') orelse return error.ParseError;
                var args: [4]f64 = @splat(0);
                var count: usize = 0;
                var depth: u32 = 0;
                var start: usize = 1;
                for (d.text[1 .. close + 1], 1..) |c, i| {
                    if (c == '(') depth += 1;
                    if (c == ')' and depth > 0) {
                        depth -= 1;
                        continue;
                    }
                    if (depth != 0 or (c != ',' and i != close)) continue;
                    if (count == args.len) return error.ParseError;
                    args[count] = switch (try r.exprValue(d.text[start..i], &top, false)) {
                        .num => |x| x,
                        else => return error.ParseError,
                    };
                    count += 1;
                    start = i + 1;
                }
                if (count < 3 or !(args[1] <= args[0] and args[0] <= args[2] and args[1] < args[2])) return error.ParseError;
                r.globals.getPtr(d.key).?.* = .{ .num = args[0] };
                k.* = (try r.liveParam(d.key)).?;
                l.* = args[1];
                u.* = args[2];
                h.* = args[3];
            }
            opt.live = live;
            opt.lo = lo;
            opt.hi = hi;
            opt.dels = dels;
            return opt;
        }

        /// A positive integer argument.
        fn positiveCount(args: []const Value, i: usize) Error!u32 {
            if (i >= args.len or args[i] != .num) return error.ParseError;
            const n = args[i].num;
            if (!(n >= 1) or n != @trunc(n) or n > std.math.maxInt(u32)) return error.ParseError;
            return @intFromFloat(n);
        }

        /// Every value as a finite number.
        fn numbers(r: *R, args: []const Value) Error![]const f64 {
            const out = try r.arena.alloc(f64, args.len);
            for (args, out) |a, *o| {
                if (a != .num or !std.math.isFinite(a.num)) return error.ParseError;
                o.* = a.num;
            }
            return out;
        }

        /// A `.data` or `.variation` block, lines `b[0]..b[1]`.
        fn readBlock(r: *R, b: [2]u32) Error!void {
            var f = F.init(r.lines.items[b[0]]);
            const card = cardOf(f.next().?[1..]).?;
            if (card == .variation) return r.readVariation(b);
            const top: Frame = .{ .scopes = &r.global_scopes };
            const name = f.next() orelse return r.failed(r.lines.items[b[0]], error.ParseError);
            var labels: std.ArrayList([]const u8) = .empty;
            var columns: std.ArrayList(StepTarget) = .empty;
            var values: std.ArrayList(f64) = .empty;
            for (b[0]..b[1]) |li| {
                const line = r.lines.items[li];
                var lf = F.init(line);
                if (li == b[0]) {
                    _ = lf.next();
                    _ = lf.next();
                }
                while (lf.next()) |t| {
                    if (t[0] == ',' or t[0] == '+') continue;
                    if (F.isWord(t) and S.parseNum(t) == null) {
                        // `MER`/`LAM` and `FILE=` read external tables.
                        if (values.items.len != 0 or lf.nextByte() == '=') return r.failed(line, error.UnsupportedCard);
                        try labels.append(r.arena, t);
                        try columns.append(r.arena, try r.stepTarget(t));
                        continue;
                    }
                    switch (try r.valueAt(t, &lf, &top, false, false)) {
                        .num => |n| try values.append(r.arena, n),
                        else => return r.failed(line, error.ParseError),
                    }
                }
            }
            if (columns.items.len == 0 or values.items.len % columns.items.len != 0)
                return r.failed(r.lines.items[b[0]], error.ParseError);
            try r.data.append(r.arena, .{ .name = name, .labels = labels.items, .columns = columns.items, .values = values.items });
        }

        /// HSPICE `.variation` block [SA Ch.20]: `.global_variation` and
        /// `.local_variation` rows `<type> <model> p=sigma [%] ...`, and
        /// `.element_variation` rows `<letter> p=sigma [%] ...`. Sigmas are
        /// one sigma of a Gaussian, relative when followed by `%`.
        fn readVariation(r: *R, b: [2]u32) Error!void {
            var local = false;
            var element = false;
            for (b[0] + 1..b[1]) |li| {
                const line = r.lines.items[li];
                var f = F.init(line);
                const head = f.next().?;
                if (head[0] == '.') {
                    const markers = std.StaticStringMap([2]?bool).initComptime(.{
                        .{ ".global_variation", .{ false, false } }, .{ ".end_global_variation", .{ null, null } },
                        .{ ".local_variation", .{ true, false } },   .{ ".end_local_variation", .{ null, null } },
                        .{ ".element_variation", .{ null, true } },  .{ ".end_element_variation", .{ null, false } },
                    });
                    const m = markers.get(head) orelse return r.failed(line, error.UnsupportedCard);
                    if (m[0]) |l| local = l;
                    if (m[1]) |e| element = e;
                    continue;
                }
                if (std.mem.eql(u8, head, "option")) continue;
                var model: []const u8 = "";
                var letter: u8 = 0;
                if (element) letter = head[0] else model = f.next() orelse return r.failed(line, error.ParseError);
                while (f.next()) |key| {
                    if (!F.isWord(key) or !f.takeEq()) return r.failed(line, error.ParseError);
                    const v = try r.percentValue(&f) orelse return r.failed(line, error.ParseError);
                    try r.variations.append(r.arena, .{ .per_device = local or element, .dist = .gauss, .model = model, .letter = letter, .param = key, .value = v.value, .relative = v.relative });
                }
            }
        }

        /// A number, optionally followed by (or ending in) `%`.
        fn percentValue(r: *R, f: *F) Error!?struct { value: f64, relative: bool } {
            _ = r;
            const t = f.next() orelse return null;
            const pct = t[t.len - 1] == '%';
            const n = S.parseNum(if (pct) t[0 .. t.len - 1] else t) orelse return null;
            if (!std.math.isFinite(n)) return null;
            if (!pct and f.nextByte() == '%') {
                _ = f.next();
                return .{ .value = n / 100, .relative = true };
            }
            return .{ .value = if (pct) n / 100 else n, .relative = pct };
        }

        /// HSPICE `dev[/n][/dist]=v` or `lot[/n][/dist]=v` after model value
        /// `param`; null when `key` is neither.
        fn devLot(r: *R, key: []const u8, param: []const u8, model: []const u8, f: *F, line: []const u8) Error!?Variation {
            var parts = std.mem.splitScalar(u8, key, '/');
            const head = parts.next().?;
            const per_device = std.mem.eql(u8, head, "dev");
            if (!per_device and !std.mem.eql(u8, head, "lot")) return null;
            var dist: Variation.Dist = .unif;
            while (parts.next()) |p| {
                if (p.len > 0 and std.ascii.isDigit(p[0])) continue;
                const dists = std.StaticStringMap(Variation.Dist).initComptime(.{
                    .{ "gauss", .gauss }, .{ "unif", .unif }, .{ "uniform", .unif }, .{ "limit", .limit },
                });
                dist = dists.get(p) orelse return r.failed(line, error.UnsupportedCard);
            }
            if (param.len == 0) return r.failed(line, error.ParseError);
            const v = try r.percentValue(f) orelse return r.failed(line, error.ParseError);
            // A Gaussian's value is its 3-sigma spread [SA Ch.20 "Variations
            // Specified Using DEV and LOT"]; `Variation.value` holds one sigma.
            const value = if (dist == .gauss) v.value / 3 else v.value;
            return .{ .per_device = per_device, .dist = dist, .model = model, .param = param, .value = value, .relative = v.relative };
        }

        /// Collects the live values after the device walk: each table value
        /// kept as postfix because it read a live name or a distribution
        /// becomes a slot holding its nominal number. Other kept postfix
        /// (a B source's) reads each live name from a constant-pool row.
        fn resolveLive(r: *R) Error!Live {
            if (r.live_names.count() == 0 and r.site_ops.items.len == 0) return .{};
            var slots: std.ArrayList(*Value) = .empty;
            var spans: std.ArrayList(Span) = .empty;
            var out: Live = .{ .names = r.live_names.keys(), .nominal = r.live_nominal.items };
            const pool_rows = try r.arena.alloc(u32, r.live_names.count());
            @memset(pool_rows, none);
            for (r.values.items) |*v| try r.liveSlot(v, &slots, &spans, pool_rows, &out);
            for (r.kvs.items) |*kv| try r.liveSlot(&kv.value, &slots, &spans, pool_rows, &out);
            out.slots = slots.items;
            out.ops = spans.items;
            const scale = try r.arena.alloc(f64, slots.items.len);
            @memset(scale, 1);
            out.scale = scale;
            out.site_ops = r.site_ops.items;
            out.site_keys = r.site_keys.items;
            out.pool_rows = pool_rows;
            return out;
        }

        fn liveSlot(r: *R, v: *Value, slots: *std.ArrayList(*Value), spans: *std.ArrayList(Span), pool_rows: []u32, out: *Live) Error!void {
            switch (v.*) {
                .group => |g| for (g.args) |*a| try r.liveSlot(@constCast(a), slots, spans, pool_rows, out),
                .expr => |span| {
                    const ops = r.ops.items[span.start..][0..span.len];
                    const sited = blk: {
                        const k = std.sort.lowerBound(u32, r.site_ops.items, span.start, orderU32);
                        break :blk k < r.site_ops.items.len and r.site_ops.items[k] < span.start + span.len;
                    };
                    var reads = false;
                    for (ops) |op| reads = reads or op.code == .live;
                    if (!reads and !sited) return;
                    const folded = try expr.fold(r.arena, &r.stack, ops, r.consts.items, false, r.live_nominal.items);
                    if (folded.known) {
                        try slots.append(r.arena, v);
                        try spans.append(r.arena, span);
                        v.* = .{ .num = folded.num };
                        return;
                    }
                    for (@constCast(ops)) |*op| if (op.code == .live) {
                        if (pool_rows[op.a] == none) {
                            try r.consts.append(r.arena, r.live_nominal.items[op.a]);
                            pool_rows[op.a] = @intCast(r.consts.items.len - 1);
                        }
                        op.* = .{ .code = .num, .a = pool_rows[op.a] };
                        out.opaque_reads = true;
                    };
                },
                else => {},
            }
        }

        /// Recompiles the top-level conditions walk 1 evaluated, now that the
        /// swept names are known, keeping those that read one.
        fn liveConds(r: *R) Error![]const Span {
            if (r.live_names.count() == 0) return &.{};
            const was_in_card = r.in_card;
            r.in_card = true;
            defer r.in_card = was_in_card;
            const top: Frame = .{ .scopes = &r.global_scopes };
            var out: std.ArrayList(Span) = .empty;
            for (r.cond_texts.items) |text| switch (try r.exprValue(text, &top, false)) {
                .expr => |span| try out.append(r.arena, span),
                else => {},
            };
            return out.items;
        }

        fn orderU32(a: u32, b: u32) std.math.Order {
            return std.math.order(a, b);
        }

        /// Logs `line` as `what` and fails the parse with `UnsupportedCard`.
        fn unsupported(r: *const R, line: []const u8, what: []const u8) Error {
            // The test runner fails any test that logs an error.
            if (!@import("builtin").is_test) std.log.err("netlist: {s}: {s}", .{ what, r.written(line) });
            return error.UnsupportedCard;
        }

        // Values.

        /// A positional value: number, name, `{expr}`/quoted expression, or
        /// `name(args)`. `subst_names` substitutes a name a scope defines
        /// (devices and models do; analysis cards only substitute expressions).
        fn readValue(r: *R, f: *F, frame: *const Frame, subst_names: bool, geometry: bool) Error!Value {
            return r.valueAt(f.next() orelse return error.ParseError, f, frame, subst_names, geometry);
        }

        /// `readValue` whose first field `t` is already read.
        fn valueAt(r: *R, t: []const u8, f: *F, frame: *const Frame, subst_names: bool, geometry: bool) Error!Value {
            if (!F.isWord(t)) {
                if (t[0] == '{' or F.isQuote(t[0])) return r.exprValue(F.body(t), frame, geometry);
                return error.ParseError;
            }
            if (f.nextByte() == '(') {
                _ = f.next();
                // `v(...)`/`i(...)` name nodes and devices, never numbers.
                const probe = std.ascii.eqlIgnoreCase(t, "v") or std.ascii.eqlIgnoreCase(t, "i");
                var args: std.ArrayList(Value) = .empty;
                while (true) {
                    const a = f.next() orelse return error.ParseError;
                    if (a[0] == ')') break;
                    if (a[0] == ',') continue;
                    try args.append(r.arena, if (probe and F.isWord(a)) .{ .name = a } else try r.valueAt(a, f, frame, subst_names, geometry));
                }
                // HSPICE writes SFFM(VO VA FC MDI FS) [CR SFFM]; the source
                // models read ngspice 44's (VO VA FM MDI FC). An omitted MDI
                // is 0 and an omitted FS the models' -1, their 5/TSTOP.
                if (r.dialect == .hspice and args.items.len > 2 and std.ascii.eqlIgnoreCase(t, "sffm")) {
                    if (args.items.len == 3) try args.append(r.arena, .{ .num = 0 });
                    if (args.items.len == 4) try args.append(r.arena, .{ .num = -1 });
                    std.mem.swap(Value, &args.items[2], &args.items[4]);
                }
                return .{ .group = .{ .name = t, .args = args.items } };
            }
            if (S.parseNum(t)) |n| return .{ .num = n };
            return if (subst_names) r.nameValue(t, frame, geometry) else .{ .name = t };
        }

        /// The value after `key=`: an expression read up to where the grammar
        /// stops, or a braced/quoted field.
        fn kvValue(r: *R, f: *F, frame: *const Frame, geometry: bool) Error!Value {
            const rest = f.rest();
            if (rest.len == 0) return error.ParseError;
            if (rest[0] == '{' or rest[0] == '\'') return r.readValue(f, frame, true, geometry);
            // A lone number literal (`w=0.5u`) needs no compile.
            if (std.ascii.isDigit(rest[0]) or rest[0] == '.') {
                const save = f.pos;
                const w = f.next().?;
                if (expr.numberLen(w) == w.len and !expr.isOperator(f.nextByte() orelse ' '))
                    return .{ .num = S.parseNum(w) orelse return error.ParseError };
                f.pos = save;
            }
            const mark = r.scratch.mark();
            defer r.scratch.reset(mark);
            f.pos = try expr.compile(S.parseNum, r.arena, &r.scratch, f.line, f.pos);
            const ops = r.scratch.ops.items[mark.ops..];
            if (ops.len == 1 and ops[0].code == .num) return .{ .num = r.scratch.consts.items[ops[0].a] };
            if (ops.len == 1 and ops[0].code == .ident) return r.nameValue(r.scratch.names.items[ops[0].a], frame, geometry);
            return r.fold(mark.ops, frame, geometry);
        }

        /// A bare name: substituted when a scope defines it.
        fn nameValue(r: *R, name: []const u8, frame: *const Frame, geometry: bool) Error!Value {
            if (find(frame.scopes, name) == null) return .{ .name = name };
            const mark = r.scratch.mark();
            defer r.scratch.reset(mark);
            try r.scratch.names.append(r.arena, name);
            try r.scratch.ops.append(r.arena, .{ .code = .ident, .a = @intCast(mark.names) });
            return r.fold(mark.ops, frame, geometry);
        }

        /// Parses the `.meas` cards in deck order. ngspice reports a bad one
        /// and simulates anyway.
        fn readMeasures(r: *R) Error!void {
            var last: ?Kind = null;
            if (r.dialect == .hspice) for (r.analyses.items) |a| switch (a.kind) {
                .tran, .ac, .dc => last = a.kind,
                else => {},
            };
            var jitters: u32 = 0;
            for (r.meas_lines.items) |line| {
                var f = F.init(line);
                var text = f.rest();
                if (std.mem.eql(u8, f.next().?, ".jitter")) {
                    // `.jitter <kind> TRIG ...` reads as `.meas <kind>
                    // jitter[N] jitter TRIG ...`, N from the second card on.
                    jitters += 1;
                    const kind = f.next() orelse "";
                    text = if (jitters == 1)
                        try std.fmt.allocPrint(r.arena, "{s} jitter jitter {s}", .{ kind, f.rest() })
                    else
                        try std.fmt.allocPrint(r.arena, "{s} jitter{d} jitter {s}", .{ kind, jitters, f.rest() });
                } else text = f.rest();
                const m = measure.parse(r.arena, text, r, last, r.dialect == .hspice) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        std.log.warn("netlist: ignoring malformed card '{s}'", .{line});
                        continue;
                    },
                };
                try r.measures.append(r.arena, m);
            }
        }

        /// A `PARAM=` or `par()` measure expression in postfix: names of
        /// earlier `.meas` cards read their results, global parameters fold
        /// to numbers, `v(a[,b])` and `i(x)` read result vectors. Arithmetic
        /// only; anything else is a ParseError.
        pub fn measureExpr(r: *R, text: []const u8) Error![]const core.MeasureOp {
            const body = if (text.len > 0 and (text[0] == '{' or F.isQuote(text[0]))) F.body(text) else text;
            const mark = r.scratch.mark();
            defer r.scratch.reset(mark);
            try expr.compileAll(S.parseNum, r.arena, &r.scratch, body);
            // Copies: folding a parameter below reuses the scratch.
            const ops = try r.arena.dupe(expr.Op, r.scratch.ops.items[mark.ops..]);
            const names = try r.arena.dupe([]const u8, r.scratch.names.items);
            const consts = try r.arena.dupe(f64, r.scratch.consts.items);
            var out: std.ArrayList(core.MeasureOp) = .empty;
            for (ops) |op| try out.append(r.arena, switch (op.code) {
                .num => .{ .num = consts[op.a] },
                .vprobe, .iprobe => {
                    const letter = if (op.code == .vprobe) "v" else "i";
                    try out.append(r.arena, .{ .vector = try std.fmt.allocPrint(r.arena, "{s}({s})", .{ letter, names[op.a] }) });
                    if (op.b == expr.none) continue;
                    try out.append(r.arena, .{ .vector = try std.fmt.allocPrint(r.arena, "{s}({s})", .{ letter, names[op.b] }) });
                    try out.append(r.arena, .sub);
                    continue;
                },
                .ident => for (r.measures.items, 0..) |m, i| {
                    if (std.mem.eql(u8, m.name, names[op.a])) break .{ .measure = @intCast(i) };
                } else .{ .num = try r.measureValue(names[op.a]) },
                .neg => .neg,
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .pow => .pow,
                else => return error.ParseError,
            });
            return out.items;
        }

        /// A numeric `.option name=value`, the last one given.
        pub fn measureOption(r: *R, name: []const u8) ?f64 {
            var found: ?f64 = null;
            for (r.config.items) |c| if (!c.temp) for (c.args, 0..) |a, i| {
                if (a != .name or i + 1 >= c.args.len or !std.mem.eql(u8, a.name, name)) continue;
                if (c.args[i + 1] == .num) found = c.args[i + 1].num;
            };
            return found;
        }

        /// A `.meas` value: a number or a global parameter expression.
        pub fn measureValue(r: *R, text: []const u8) Error!f64 {
            if (S.parseNum(text)) |n| return n;
            const body = if (text[0] == '{' or F.isQuote(text[0])) F.body(text) else text;
            const top: Frame = .{ .scopes = &r.global_scopes };
            return switch (try r.exprValue(body, &top, false)) {
                .num => |n| n,
                else => error.ParseError,
            };
        }

        fn exprValue(r: *R, text: []const u8, frame: *const Frame, geometry: bool) Error!Value {
            const mark = r.scratch.mark();
            defer r.scratch.reset(mark);
            try expr.compileAll(S.parseNum, r.arena, &r.scratch, text);
            return r.fold(mark.ops, frame, geometry);
        }

        /// Splice parameters into the scratch ops from `from` on, then fold. A
        /// number keeps nothing; anything else keeps its postfix.
        /// A device or model value that reads a live name, or a distribution
        /// when some card runs Monte Carlo, keeps its postfix too: a variant
        /// re-evaluates it (`resolveLive`). A live name read anywhere else is
        /// `UnsupportedCard`, since nothing would re-read it.
        fn fold(r: *R, from: usize, frame: *const Frame, geometry: bool) Error!Value {
            const ops_mark = r.ops.items.len;
            const consts_mark = r.consts.items.len;
            const sites_mark = r.site_ops.items.len;
            try r.subst(from, r.scratch.ops.items.len, frame, frame.scopes, 0);
            const ops = r.ops.items[ops_mark..];
            const v = try expr.fold(r.arena, &r.stack, ops, r.consts.items, geometry, r.live_nominal.items);
            if (v.known) {
                var reads = false;
                for (ops) |op| reads = reads or op.code == .live;
                const sited = r.site_ops.items.len > sites_mark;
                if (reads and !r.in_card and !r.live_ok) {
                    if (!@import("builtin").is_test) std.log.err("netlist: a swept parameter is read outside a device or model value", .{});
                    return error.UnsupportedCard;
                }
                if (!(r.in_card and (reads or sited))) {
                    r.ops.shrinkRetainingCapacity(ops_mark);
                    r.consts.shrinkRetainingCapacity(consts_mark);
                    r.site_ops.shrinkRetainingCapacity(sites_mark);
                    r.site_keys.shrinkRetainingCapacity(sites_mark);
                    return .{ .num = v.num };
                }
            }
            return .{ .expr = .{ .start = @intCast(ops_mark), .len = @intCast(r.ops.items.len - ops_mark) } };
        }

        const Hit = struct { entry: Entry, level: usize };

        fn find(scopes: []const *const Scope, name: []const u8) ?Hit {
            var i = scopes.len;
            while (i > 0) {
                i -= 1;
                if (scopes[i].get(name)) |entry| return .{ .entry = entry, .level = i };
            }
            return null;
        }

        /// Copy scratch ops `from..to` into the netlist's ops. A name a scope
        /// defines is replaced by its definition, read in the scope that
        /// defined it; probe nets are mapped through `frame`.
        fn subst(r: *R, from: usize, to: usize, frame: *const Frame, scopes: []const *const Scope, depth: u8) Error!void {
            if (depth == 64) return error.ParseError;
            // `expr.Code.ident`'s final operand: declared geometry, then the
            // B-source tape's simulator variables.
            const ident_class = std.StaticStringMap(u32).initComptime(.{ .{ "l", 1 }, .{ "w", 1 }, .{ "mult", 1 }, .{ "time", 2 }, .{ "temper", 3 } });
            var i = from;
            while (i < to) : (i += 1) {
                const op = r.scratch.ops.items[i];
                switch (op.code) {
                    .num => try r.emitNum(r.scratch.consts.items[op.a]),
                    .ident => {
                        const name = r.scratch.names.items[op.a];
                        const hit = find(scopes, name) orelse {
                            try r.ops.append(r.arena, .{ .code = .ident, .a = ident_class.get(name) orelse 0 });
                            continue;
                        };
                        if (hit.level == 0) if (r.live_names.getIndex(name)) |k| {
                            try r.ops.append(r.arena, .{ .code = .live, .a = @intCast(k) });
                            continue;
                        };
                        switch (hit.entry) {
                            .num => |n| try r.emitNum(n),
                            .text => |text| {
                                const mark = r.scratch.mark();
                                defer r.scratch.reset(mark);
                                try expr.compileAll(S.parseNum, r.arena, &r.scratch, text);
                                // Calls inside a parameter's text draw once per
                                // scope that defines it: globally, or per instance.
                                const owner = r.site_owner;
                                const ordinal = r.site_ordinal;
                                defer {
                                    r.site_owner = owner;
                                    r.site_ordinal = ordinal;
                                }
                                r.site_owner = nameKey(nameKey(0, levelPath(frame, hit.level)), name);
                                r.site_ordinal = 0;
                                try r.subst(mark.ops, r.scratch.ops.items.len, frame, scopes[0 .. hit.level + 1], depth + 1);
                            },
                        }
                    },
                    // The device by its flattened card name (`commit`), for a B-source tape.
                    .iprobe => {
                        const a = if (op.a == none) none else a: {
                            const dev = r.scratch.names.items[op.a];
                            const flat = if (frame.path) |path| try r.joined(&.{ dev[0..1], ".", path, ".", dev }) else dev;
                            break :a (try r.internName(flat)).index();
                        };
                        try r.ops.append(r.arena, .{ .code = .iprobe, .a = a, .b = none });
                    },
                    .vprobe => try r.ops.append(r.arena, .{
                        .code = .vprobe,
                        .a = if (op.a == none) none else (try r.netOf(frame, r.scratch.names.items[op.a])).index(),
                        .b = if (op.b == none) none else (try r.netOf(frame, r.scratch.names.items[op.b])).index(),
                    }),
                    else => {
                        if (r.monte and op.code == .call and expr.isDistribution(@enumFromInt(op.a))) {
                            try r.site_ops.append(r.arena, @intCast(r.ops.items.len));
                            try r.site_keys.append(r.arena, siteKey(r.site_owner, r.site_ordinal));
                            r.site_ordinal += 1;
                        }
                        try r.ops.append(r.arena, op);
                    },
                }
            }
        }

        /// The instance path whose scope sits at `level` of `frame`'s
        /// scopes: its first `level` dotted components, "" for globals.
        fn levelPath(frame: *const Frame, level: usize) []const u8 {
            const path = frame.path orelse return "";
            if (level == 0) return "";
            var seen: usize = 0;
            for (path, 0..) |c, i| if (c == '.') {
                seen += 1;
                if (seen == level) return path[0..i];
            };
            return path;
        }

        fn emitNum(r: *R, n: f64) Error!void {
            try r.consts.append(r.arena, n);
            try r.ops.append(r.arena, .{ .code = .num, .a = @intCast(r.consts.items.len - 1) });
        }

        // Walk 2: devices.

        /// A name into the pool; a new one maps to no net yet.
        fn internName(r: *R, s: []const u8) Error!Name {
            const n = try r.pool.intern(r.arena, s);
            if (n.index() == r.net_of.items.len) try r.net_of.append(r.arena, none);
            return n;
        }

        fn intern(r: *R, s: []const u8) Error!VertexId {
            if (isGroundName(s)) return ground;
            const n = try r.internName(s);
            const slot = &r.net_of.items[n.index()];
            if (slot.* == none) {
                const v = r.hg.addVertex(r.arena, .{ .name = n }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.CircuitTooLarge,
                };
                slot.* = v.index();
            }
            return .from(slot.*);
        }

        /// Makes nets `a` and `b` one net, before any device card is read.
        /// Two names that are already distinct nets (an alias chain closing
        /// on itself through different roots) are refused.
        fn connect(r: *R, a: []const u8, b: []const u8) Error!void {
            var slots: [2]?*u32 = .{ null, null };
            var ids: [2]u32 = .{ 0, 0 };
            for ([_][]const u8{ a, b }, 0..) |name, k| if (!isGroundName(name)) {
                const n = try r.internName(try r.arena.dupe(u8, name));
                slots[k] = &r.net_of.items[n.index()];
                ids[k] = slots[k].?.*;
            };
            if (ids[0] == none and ids[1] == none) ids[0] = (try r.intern(try r.arena.dupe(u8, a))).index();
            if (ids[0] == none) slots[0].?.* = ids[1] else if (ids[1] == none) slots[1].?.* = ids[0] else if (ids[0] != ids[1]) return error.ParseError;
        }

        /// `parts` joined, in reused scratch.
        fn joined(r: *R, parts: []const []const u8) Error![]const u8 {
            r.name_buf.clearRetainingCapacity();
            for (parts) |part| try r.name_buf.appendSlice(r.arena, part);
            return r.name_buf.items;
        }

        /// A node as the frame names it: a port maps to the caller's net,
        /// `0`/`gnd` stay global, anything else is `<path>.<node>`.
        fn netOf(r: *R, frame: *const Frame, node: []const u8) Error!VertexId {
            const path = frame.path orelse return r.intern(node);
            for (frame.ports, frame.actuals) |p, a| if (std.mem.eql(u8, p, node)) return a;
            if (std.mem.eql(u8, node, "0") or std.mem.eql(u8, node, "gnd") or r.global_nets.contains(node)) return r.intern(node);
            return r.intern(try r.joined(&.{ path, ".", node }));
        }

        /// A mixed-mode P card, `P1 n+ n- ref port=1 ...` [SA Ch.17]: a
        /// third word that is neither a key (`port=`) nor a source keyword.
        /// The manual writes a P card's DC value as `DC mag`, so a bare
        /// third word is the reference node, not a value.
        fn mixedPort(f: F) bool {
            var p = f;
            _ = p.next();
            _ = p.next();
            const t = p.next() orelse return false;
            if (!F.isWord(t)) return false;
            if (p.next()) |u| if (u[0] == '=') return false;
            var buf: [8]u8 = undefined;
            return t.len > buf.len or !port_source_words.has(std.ascii.lowerString(&buf, t));
        }

        fn fixedPins(letter: u8) ?usize {
            return switch (letter) {
                // W n+ n- Vctrl model: Vctrl/model are positional words (ngspice INP2W).
                'r', 'c', 'l', 'v', 'i', 'd', 'b', 'f', 'h', 'w' => 2,
                'q', 'z', 'j' => 3,
                'e', 'g', 's', 'm', 't', 'o' => 4,
                'k' => 0,
                else => null,
            };
        }

        fn readDevice(r: *R, line: []const u8, frame: *const Frame) Error!void {
            const arena = r.arena;
            const port_card = r.dialect == .hspice and std.ascii.toLower(line[0]) == 'p';
            var f = F.init(if (port_card) try r.portLine(line) else line);
            const head = f.next() orelse return error.ParseError;
            const was_in_card = r.in_card;
            r.in_card = true;
            defer r.in_card = was_in_card;
            r.site_owner = nameKey(nameKey(0, frame.path orelse ""), head);
            r.site_ordinal = 0;
            if (!F.isWord(head) or !std.ascii.isAlphabetic(head[0])) return error.ParseError;
            // HSPICE's P element is a port: a V card that `port=` numbers
            // for `.lin` (`P1 in 0 port=1 z0=50`).
            const letter = if (port_card) 'v' else std.ascii.toLower(head[0]);
            // HSPICE reads these letters as lossy lines, S-parameter blocks
            // and IBIS buffers, none of which is built.
            if (r.dialect == .hspice and std.mem.indexOfScalar(u8, "bsuw", letter) != null)
                return r.unsupported(line, "unsupported HSPICE element");
            if (std.mem.indexOfScalar(u8, "efgh", letter) != null) {
                var probe = f;
                _ = probe.next();
                _ = probe.next();
                var buf: [16]u8 = undefined;
                const at = probe.pos;
                if (probe.next()) |t| if (t.len <= buf.len) if (behavioural.get(std.ascii.lowerString(&buf, t))) |form| {
                    // `E1 a b VCVS c d 2`: the type word only repeats the letter.
                    if (form == .kind) return r.readDevice(try std.mem.concat(r.arena, u8, &.{ line[0..at], " ", probe.line[probe.pos..] }), frame);
                    return r.behaviouralCard(line, head, letter, f, frame, form);
                };
            }
            r.nodes.clearRetainingCapacity();
            r.positional.clearRetainingCapacity();
            r.card_kv.clearRetainingCapacity();
            var kv_text: std.ArrayList([]const u8) = .empty;

            if ((f.nextByte() orelse return error.ParseError) == '(') {
                _ = f.next();
                while (true) {
                    const t = f.next() orelse return error.ParseError;
                    if (t[0] == ')') break;
                    if (t[0] == ',') continue;
                    if (!F.isWord(t)) return error.ParseError;
                    try r.nodes.append(arena, t);
                }
                const model = f.next() orelse return error.ParseError;
                if (!F.isWord(model)) return error.ParseError;
                try r.positional.append(arena, try r.nameValue(model, frame, false));
            } else if (fixedPins(letter)) |fixed| {
                const count = if (port_card and mixedPort(f)) 3 else fixed;
                try r.nodes.ensureUnusedCapacity(arena, count);
                for (0..count) |_| {
                    const t = f.next() orelse return error.ParseError;
                    if (!F.isWord(t)) return error.ParseError;
                    r.nodes.appendAssumeCapacity(t);
                }
                if (letter == 'b') {
                    const out = f.next() orelse return error.ParseError;
                    const eq = f.next() orelse return error.ParseError;
                    if (!F.isWord(out) or eq[0] != '=') return error.ParseError;
                    const t = f.peek() orelse return error.ParseError;
                    const text = if (t[0] == '{' or F.isQuote(t[0])) F.body(t) else f.rest();
                    try r.card_kv.append(arena, .{ .key = out, .value = try r.exprValue(text, frame, false) });
                    return r.commit(head, letter, frame);
                }
            } else {
                // Variable-terminal cards end their word list with the model/subcircuit name.
                while (true) {
                    const save = f.pos;
                    const t = f.next() orelse break;
                    if (!F.isWord(t) or f.takeEq()) {
                        f.pos = save;
                        break;
                    }
                    try r.nodes.append(arena, t);
                }
                const model = r.nodes.pop() orelse return error.ParseError;
                try r.positional.append(arena, try r.nameValue(model, frame, false));
            }

            // A third node makes a mixed-mode (balanced) port, not built.
            if (port_card) {
                var probe = f;
                if (probe.next()) |t| if (F.isWord(t) and !probe.takeEq()) return r.unsupported(line, "mixed-mode P element");
            }
            while (f.next()) |t| {
                if (t[0] == ',') {
                    continue;
                } else if (F.isWord(t) and f.takeEq()) {
                    const start = f.pos;
                    try r.card_kv.append(arena, .{ .key = t, .value = try r.kvValue(&f, frame, false) });
                    if (letter == 'x') try kv_text.append(arena, std.mem.trim(u8, f.line[start..f.pos], " \t"));
                } else {
                    try r.positional.append(arena, try r.valueAt(t, &f, frame, true, false));
                }
            }
            if (letter == 'x') return r.expand(head, frame, kv_text.items);
            if (letter == 'q' or letter == 'm') try r.splitTerminals();
            return r.commit(head, letter, frame);
        }

        /// An E/F/G/H card in a behavioural form, `f` just past the name. Value,
        /// POLY, TABLE and PWL(1) forms, and HSPICE's VCR and VCCAP, become a
        /// B card over one expression (`i=`, `v=`, or `q=` for the charge of
        /// VCCAP); LAPLACE and DELAY keep their letter and carry the form in
        /// `laplace=<numerator count>` or `td=`. Anything else is refused.
        fn behaviouralCard(r: *R, line: []const u8, head: []const u8, letter: u8, f_in: F, frame: *const Frame, form: Form) Error!void {
            const arena = r.arena;
            var f = f_in;
            r.nodes.clearRetainingCapacity();
            r.positional.clearRetainingCapacity();
            r.card_kv.clearRetainingCapacity();
            for (0..2) |_| try r.nodes.append(arena, try r.word(&f));
            _ = f.next();
            const by_current = letter == 'f' or letter == 'h';
            var w: std.ArrayList(u8) = .empty;
            switch (form) {
                .refused, .kind => return r.unsupported(line, "unsupported controlled-source form"),
                .laplace, .delay => {
                    if (by_current) return r.unsupported(line, "unsupported controlled-source form");
                    for (0..2) |_| try r.nodes.append(arena, try r.word(&f));
                    var n_num: usize = 0;
                    while (f.next()) |t| {
                        if (t[0] == ',' or t[0] == '(' or t[0] == ')') continue;
                        if (form == .laplace and std.mem.eql(u8, t, "/")) {
                            n_num = r.positional.items.len;
                        } else if (F.isWord(t) and f.takeEq()) {
                            try r.card_kv.append(arena, .{ .key = t, .value = try r.kvValue(&f, frame, false) });
                        } else try r.positional.append(arena, .{ .num = try r.numberAt(t, &f, frame) });
                    }
                    if (form == .laplace) {
                        if (n_num == 0 or n_num == r.positional.items.len) return error.ParseError;
                        try r.card_kv.append(arena, .{ .key = "laplace", .value = .{ .num = @floatFromInt(n_num) } });
                    } else if (r.positional.items.len != 0 or kvIndex(r.card_kv.items, "td") == null) return error.ParseError;
                    return r.commit(head, letter, frame);
                },
                .value => {
                    _ = f.takeEq();
                    const t = f.peek() orelse return error.ParseError;
                    if (t[0] == '{' or F.isQuote(t[0])) {
                        try w.appendSlice(arena, F.body(t));
                        _ = f.next();
                    } else {
                        try w.appendSlice(arena, f.rest());
                        f.pos = f.line.len;
                    }
                },
                .poly => try r.polyText(&w, &f, frame, by_current),
                .table => {
                    // TABLE {expr} = (x1, y1) (x2, y2) ... (ngspice inpcom.c),
                    // corners smoothed over a tenth of the shorter segment.
                    _ = f.takeEq();
                    const t = f.next() orelse return error.ParseError;
                    if (t[0] != '{' and !F.isQuote(t[0])) return error.ParseError;
                    _ = f.takeEq();
                    try w.print(arena, "table(({s}),0.1", .{F.body(t)});
                    _ = try r.tableText(&w, &f, frame);
                },
                .pwl, .vcr, .vccap => {
                    // HSPICE: [VCR|VCCAP] [PWL(1)|POLY(n)] in+ in- ..., or the
                    // linear `VCR in+ in- factor` (a resistance or capacitance).
                    const inner = if (form == .pwl) Form.pwl else blk: {
                        if (by_current) return r.unsupported(line, "unsupported controlled-source form");
                        const t = f.peek() orelse return error.ParseError;
                        var buf: [8]u8 = undefined;
                        const sub = if (t.len <= buf.len) behavioural.get(std.ascii.lowerString(&buf, t)) else null;
                        if (sub == null) break :blk Form.value;
                        if (sub.? != .pwl and sub.? != .poly) return r.unsupported(line, "unsupported controlled-source form");
                        _ = f.next();
                        break :blk sub.?;
                    };
                    switch (form) {
                        .vcr => try w.print(arena, "v({s},{s})/(", .{ r.nodes.items[0], r.nodes.items[1] }),
                        .vccap => try w.print(arena, "v({s},{s})*(", .{ r.nodes.items[0], r.nodes.items[1] }),
                        else => try w.append(arena, '('),
                    }
                    switch (inner) {
                        .poly => try r.polyText(&w, &f, frame, false),
                        .pwl => {
                            if (!std.mem.eql(u8, f.next() orelse "", "(") or !std.mem.eql(u8, f.next() orelse "", "1") or
                                !std.mem.eql(u8, f.next() orelse "", ")")) return r.unsupported(line, "multi-input PWL");
                            var ctl: std.ArrayList(u8) = .empty;
                            try r.controlText(&ctl, &f, by_current);
                            var pts: std.ArrayList(u8) = .empty;
                            const spacing = try r.tableText(&pts, &f, frame);
                            // DELTA, the corner width, defaults to a quarter of
                            // the closest breakpoint spacing [SA G-element parameters].
                            const delta = if (kvIndex(r.card_kv.items, "delta")) |k| switch (r.card_kv.items[k].value) {
                                .num => |x| x,
                                else => return error.ParseError,
                            } else spacing / 4;
                            try w.print(arena, "table({s},{e}{s}", .{ ctl.items, -delta, pts.items });
                        },
                        else => {
                            try w.append(arena, '(');
                            try r.controlText(&w, &f, false);
                            try w.print(arena, ")*({e})", .{try r.numberAt(f.next() orelse return error.ParseError, &f, frame)});
                        },
                    }
                    try w.append(arena, ')');
                },
            }
            // HSPICE modifiers [SA E-element parameters], in this order.
            while (f.next()) |t| {
                if (t[0] == ',') continue;
                if (!F.isWord(t) or !f.takeEq()) return error.ParseError;
                try r.card_kv.append(arena, .{ .key = t, .value = try r.kvValue(&f, frame, false) });
            }
            var tc: [2]Kv = undefined;
            var n_tc: usize = 0;
            for (r.card_kv.items) |kv| {
                const x = switch (kv.value) {
                    .num => |x| x,
                    else => return r.unsupported(line, "non-constant controlled-source parameter"),
                };
                const keys = std.StaticStringMap(u8).initComptime(.{
                    .{ "scale", 's' }, .{ "m", 's' },   .{ "abs", 'a' },   .{ "max", 'x' },  .{ "min", 'n' },
                    .{ "tc1", 't' },   .{ "tc2", 't' }, .{ "ic", 'i' },    .{ "delta", 'i' },
                });
                const k = keys.get(kv.key) orelse return r.unsupported(line, "unsupported controlled-source parameter");
                switch (k) {
                    's' => w = try wrapped(arena, "(", w.items, try std.fmt.allocPrint(arena, ")*({e})", .{x})),
                    'a' => if (x != 0) {
                        w = try wrapped(arena, "abs(", w.items, ")");
                    },
                    'x' => w = try wrapped(arena, "min(", w.items, try std.fmt.allocPrint(arena, ",{e})", .{x})),
                    'n' => w = try wrapped(arena, "max(", w.items, try std.fmt.allocPrint(arena, ",{e})", .{x})),
                    't' => {
                        if (n_tc == tc.len) return error.ParseError;
                        tc[n_tc] = kv;
                        n_tc += 1;
                    },
                    else => {},
                }
            }
            r.card_kv.clearRetainingCapacity();
            const key: []const u8 = if (form == .vccap) "q" else if (letter == 'g' or letter == 'f') "i" else "v";
            try r.card_kv.append(arena, .{ .key = key, .value = try r.exprValue(w.items, frame, false) });
            try r.card_kv.appendSlice(arena, tc[0..n_tc]);
            return r.commit(head, 'b', frame);
        }

        /// `pre ++ text ++ post` in a fresh list.
        fn wrapped(arena: Allocator, pre: []const u8, text: []const u8, post: []const u8) Error!std.ArrayList(u8) {
            var out: std.ArrayList(u8) = .empty;
            try out.print(arena, "{s}{s}{s}", .{ pre, text, post });
            return out;
        }

        /// The next node or source name, past any `(`, `)` or `,`.
        fn word(_: *R, f: *F) Error![]const u8 {
            while (f.next()) |t| {
                if (t[0] == ',' or t[0] == '(' or t[0] == ')') continue;
                if (!F.isWord(t)) return error.ParseError;
                return t;
            }
            return error.ParseError;
        }

        /// A number field, or a parameter or `{expr}` that folds to one.
        fn numberAt(r: *R, t: []const u8, f: *F, frame: *const Frame) Error!f64 {
            return switch (try r.valueAt(t, f, frame, true, false)) {
                .num => |x| x,
                else => error.ParseError,
            };
        }

        /// One controlling quantity as expression text: `v(a,b)` over the
        /// next two nodes, or `i(vname)` over the next source name.
        fn controlText(r: *R, w: *std.ArrayList(u8), f: *F, by_current: bool) Error!void {
            if (by_current) return w.print(r.arena, "i({s})", .{try r.word(f)});
            const a = try r.word(f);
            const b = try r.word(f);
            if (isGroundName(b)) return w.print(r.arena, "v({s})", .{a});
            try w.print(r.arena, "v({s},{s})", .{ a, b });
        }

        /// `(x1, y1) (x2, y2) ...` or `x1,y1 x2,y2 ...` as `,x1,y1,...)`.
        /// A `key=value` among them goes to `card_kv`. Returns the smallest x
        /// spacing.
        fn tableText(r: *R, w: *std.ArrayList(u8), f: *F, frame: *const Frame) Error!f64 {
            var n: usize = 0;
            var last: f64 = 0;
            var spacing = std.math.inf(f64);
            while (f.next()) |t| {
                if (t[0] == ',' or t[0] == '(' or t[0] == ')') continue;
                if (F.isWord(t) and f.takeEq()) {
                    try r.card_kv.append(r.arena, .{ .key = t, .value = try r.kvValue(f, frame, false) });
                    continue;
                }
                const x = try r.numberAt(t, f, frame);
                if (n % 2 == 0) {
                    if (n > 0) spacing = @min(spacing, x - last);
                    last = x;
                }
                try w.print(r.arena, ",{e}", .{x});
                n += 1;
            }
            if (n < 4 or n % 2 != 0) return error.ParseError;
            try w.append(r.arena, ')');
            return spacing;
        }

        /// `POLY(n) <controls> p0 p1 ...` as a sum of products in SPICE 2G6
        /// coefficient order (XSPICE spice2poly nxtpwr). HSPICE reads a lone
        /// coefficient as p1 [SA G-element parameters]; ngspice as p0.
        fn polyText(r: *R, w: *std.ArrayList(u8), f: *F, frame: *const Frame, by_current: bool) Error!void {
            const arena = r.arena;
            if (!std.mem.eql(u8, f.next() orelse "", "(")) return error.ParseError;
            const dim_f = try r.numberAt(f.next() orelse return error.ParseError, f, frame);
            if (!std.mem.eql(u8, f.next() orelse "", ")") or dim_f < 1 or dim_f > 8 or dim_f != @trunc(dim_f)) return error.ParseError;
            const dim: usize = @intFromFloat(dim_f);
            var ctl: [8][]const u8 = undefined;
            for (ctl[0..dim]) |*c| {
                var t: std.ArrayList(u8) = .empty;
                try r.controlText(&t, f, by_current);
                c.* = t.items;
            }
            var coef: std.ArrayList(f64) = .empty;
            while (f.next()) |t| {
                if (t[0] == ',') continue;
                if (F.isWord(t) and f.takeEq()) {
                    try r.card_kv.append(arena, .{ .key = t, .value = try r.kvValue(f, frame, false) });
                    continue;
                }
                try coef.append(arena, try r.numberAt(t, f, frame));
            }
            if (coef.items.len == 0) return error.ParseError;
            if (coef.items.len == 1 and dim == 1 and r.dialect == .hspice) try coef.insert(arena, 0, 0);
            try w.print(arena, "({e})", .{coef.items[0]});
            var pw: [8]u32 = @splat(0);
            for (coef.items[1..]) |c| {
                nextPower(pw[0..dim]);
                if (c == 0) continue;
                try w.print(arena, "+({e})", .{c});
                for (pw[0..dim], ctl[0..dim]) |e, x| for (0..e) |_| try w.print(arena, "*{s}", .{x});
            }
        }

        /// the plain keys `hblin_h=h hblin_s=s` the builder reads. A longer
        /// vector (multi-tone HB) is refused.
        fn portLine(r: *R, line: []const u8) Error![]const u8 {
            const at = std.ascii.indexOfIgnoreCase(line, "hblin") orelse return line;
            const open = std.mem.indexOfScalarPos(u8, line, at, '[') orelse return error.ParseError;
            const close = std.mem.indexOfScalarPos(u8, line, open, ']') orelse return error.ParseError;
            var it = std.mem.tokenizeAny(u8, line[open + 1 .. close], ", \t");
            const h = it.next() orelse return error.ParseError;
            const s = it.next() orelse return error.ParseError;
            if (it.next() != null) return r.unsupported(line, "multi-tone HBLIN band");
            return std.fmt.allocPrint(r.arena, "{s} hblin_h={s} hblin_s={s} {s}", .{ line[0..at], h, s, line[close + 1 ..] });
        }

        fn isModel(r: *R, name: []const u8) bool {
            return r.model_ids.contains(name) or r.local_names.contains(name);
        }

        /// Q cards carry 3-5 terminals and M cards 3-7 against the fixed 3
        /// and 4 read, so the model name can land on either side of the
        /// node/positional split. Move it to positional[0].
        fn splitTerminals(r: *R) Error!void {
            const nodes = &r.nodes;
            const pos = &r.positional;
            // Too few terminals: the model name was read as the last node.
            if (nodes.items.len > 0 and (pos.items.len == 0 or switch (pos.items[0]) {
                .name => |n| !r.isModel(n),
                else => true,
            })) {
                const last = nodes.items[nodes.items.len - 1];
                if (r.isModel(last)) {
                    _ = nodes.pop();
                    pos.shrinkRetainingCapacity(@min(pos.items.len, 3));
                    try pos.insert(r.arena, 0, .{ .name = last });
                    return;
                }
            }
            // Too many: extra terminals spilled into positional before the model.
            var model_at: ?usize = null;
            for (pos.items, 0..) |p, i| switch (p) {
                .name => |n| if (r.isModel(n)) {
                    model_at = i;
                },
                else => {},
            };
            const mi = model_at orelse return;
            if (mi == 0 or nodes.items.len + mi > 8 or pos.items.len - mi > 4) return;
            for (pos.items[0..mi]) |p| switch (p) {
                .name, .num => {},
                else => return,
            };
            for (pos.items[0..mi]) |p| try nodes.append(r.arena, switch (p) {
                .name => |n| n,
                .num => |v| try std.fmt.allocPrint(r.arena, "{d}", .{v}),
                else => unreachable,
            });
            try pos.replaceRange(r.arena, 0, mi, &.{});
        }

        fn commit(r: *R, head: []const u8, letter: u8, frame: *const Frame) Error!void {
            const arena = r.arena;
            try r.pins.resize(arena, r.nodes.items.len);
            for (r.nodes.items, r.pins.items) |n, *pin| pin.* = try r.netOf(frame, n);
            const positional = try appendSpan(Value, arena, &r.values, r.positional.items);
            const kv = try appendSpan(Kv, arena, &r.kvs, r.card_kv.items);
            // After the spans: reading an instance model reuses the card scratch.
            const model: u32 = if (r.positional.items.len > 0 and r.positional.items[0] == .name)
                try r.modelRow(letter, r.positional.items[0].name, positional.start, frame)
            else
                none;
            // A behavioural E/F/G/H is built as a B card but keeps its own
            // letter in a flattened name, which is what its i() probes use.
            const name_letter = if (letter == 'b') std.ascii.toLower(head[0]) else letter;
            const name = try r.internName(if (frame.path) |path| try r.joined(&[_][]const u8{ &.{name_letter}, ".", path, ".", head }) else head);
            _ = r.hg.addEdge(arena, .{
                .kind = letter,
                .name = name,
                .model = model,
                .positional = positional,
                .kv = kv,
                .subckt_instance = frame.instance,
            }, r.pins.items) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CircuitTooLarge,
            };
        }

        /// Flatten an `X` card: read its subcircuit's lines under a child frame.
        fn expand(r: *R, head: []const u8, frame: *const Frame, kv_text: []const []const u8) Error!void {
            const arena = r.arena;
            if (frame.depth > 32) return error.ParseError;
            if (r.positional.items.len < 1) return error.ParseError;
            const sname = switch (r.positional.items[r.positional.items.len - 1]) {
                .name => |n| n,
                else => return error.ParseError,
            };
            const id = r.subckt_ids.get(sname) orelse return error.ParseError;
            const sub = r.subckts.items[id];
            if (r.nodes.items.len != sub.ports.len) return error.ParseError;
            if (r.instances == std.math.maxInt(u32)) return error.CircuitTooLarge;
            const instance = r.instances;
            r.instances += 1;

            // Shadow order: instance values, subcircuit defaults, enclosing scopes.
            const scope = try arena.create(Scope);
            scope.* = .empty;
            for (sub.defaults) |d| try scope.put(arena, d.key, .{ .text = d.text });
            for (r.card_kv.items, kv_text) |kv, text| try scope.put(arena, kv.key, switch (kv.value) {
                .num => |n| .{ .num = n },
                .name => |n| .{ .text = n },
                else => .{ .text = if (text.len > 0 and (text[0] == '{' or F.isQuote(text[0]))) F.body(text) else text },
            });
            const actuals = try arena.alloc(VertexId, r.nodes.items.len);
            for (r.nodes.items, actuals) |n, *a| a.* = try r.netOf(frame, n);
            const scopes = try std.mem.concat(arena, *const Scope, &.{ frame.scopes, &.{scope} });
            const child: Frame = .{
                .path = if (frame.path) |p| try std.mem.concat(arena, u8, &.{ p, ".", head }) else head,
                .ports = sub.ports,
                .actuals = actuals,
                .scopes = scopes,
                .depth = frame.depth + 1,
                .instance = instance,
                .sub = id,
                .models_mark = @intCast(r.instance_models.items.len),
            };
            defer r.instance_models.shrinkRetainingCapacity(child.models_mark);
            // Models first, as ngspice reads every `.model` before any
            // device: the ones under a branch this instance keeps.
            const locals = r.local_models.items[sub.models_lo..sub.models_hi];
            if (for (locals) |m| {
                if (m.cond) break true;
            } else false) {
                var kept: Branches = .{};
                for (r.lines.items[sub.first..sub.end], sub.first..) |line, i| {
                    if (line[0] != '.') continue;
                    var f = F.init(line);
                    const card = cardOf(f.next().?[1..]) orelse continue;
                    switch (card) {
                        .cond => |c| try r.branch(&kept, c, &f, &child),
                        .model => if (kept.active()) for (locals) |m| {
                            if (m.cond and m.line == i) _ = try r.localRow(m, &child);
                        },
                        else => {},
                    }
                }
            }
            var branches: Branches = .{};
            for (r.lines.items[sub.first..sub.end]) |line| {
                if (line[0] != '.') {
                    if (branches.active()) try r.readDevice(line, &child);
                    continue;
                }
                if (!sub.has_cond) continue;
                var f = F.init(line);
                const card = cardOf(f.next().?[1..]) orelse continue;
                if (card == .cond) try r.branch(&branches, card.cond, &f, &child);
            }
            if (branches.depth != 0) return error.ParseError;
        }

        // After the walk: shunts and model bins.

        /// `.options gshunt=G cshunt=C` [CR Ch.3]: a conductance and a
        /// capacitance from every net to ground, added as R and C cards
        /// named `r.gshunt.<net>` and `c.cshunt.<net>`.
        fn shunts(r: *R) Error!void {
            const nets = r.hg.vertices.len;
            inline for (.{ .{ "gshunt", 'r' }, .{ "cshunt", 'c' } }) |s| if (r.option(s[0])) |v| if (v > 0) {
                for (1..nets) |net| {
                    const value: Value = .{ .num = if (s[1] == 'r') 1 / v else v };
                    const pins = [2]VertexId{ .from(net), ground };
                    const net_name = r.pool.str(r.hg.vertices.items(.name)[net]);
                    const name = try r.internName(try std.fmt.allocPrint(r.arena, "{c}.{s}.{s}", .{ s[1], s[0], net_name }));
                    _ = r.hg.addEdge(r.arena, .{
                        .kind = s[1],
                        .name = name,
                        .model = none,
                        .positional = try appendSpan(Value, r.arena, &r.values, &.{value}),
                        .kv = .{},
                        .subckt_instance = 0,
                    }, &pins) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.CircuitTooLarge,
                    };
                }
            };
        }

        /// The last `.options name=value` number in the deck, null when none
        /// sets it.
        fn option(r: *const R, name: []const u8) ?f64 {
            var out: ?f64 = null;
            for (r.config.items) |c| if (!c.temp) for (c.args, 0..) |a, i| {
                if (a == .name and std.ascii.eqlIgnoreCase(a.name, name) and i + 1 < c.args.len and c.args[i + 1] == .num) out = c.args[i + 1].num;
            };
            return out;
        }

        /// `.option scale` and `wnflag`, which bin selection reads.
        fn binOptions(r: *R) Error!void {
            r.wnflag = r.dialect != .ngspice;
            for (r.config.items) |c| {
                if (c.temp) continue;
                for (c.args, 0..) |arg, i| {
                    if (arg != .name) continue;
                    const is_scale = std.mem.eql(u8, arg.name, "scale");
                    if (!is_scale and !std.mem.eql(u8, arg.name, "wnflag")) continue;
                    if (i + 1 == c.args.len or c.args[i + 1] != .num) return error.ParseError;
                    if (is_scale) r.scale = c.args[i + 1].num else r.wnflag = c.args[i + 1].num != 0;
                }
            }
            if (!(r.scale > 0) or !std.math.isFinite(r.scale)) return error.ParseError;
        }

        /// `.option scale` and ngspice model binning (INPgetModBin): an M card
        /// naming `nm` takes the last-declared global `nm.<n>` whose L/W
        /// bounds hold it, within 1 nm. `modelRow` already binned the cards
        /// that name a subcircuit's own bins.
        fn modelBins(r: *R, live: Live) Error!void {
            const scale = r.scale;
            // Slot of each live table value, for the scale and the bin check.
            var slot_of: std.AutoHashMapUnmanaged(*const Value, u32) = .empty;
            for (live.slots, 0..) |slot, k| try slot_of.put(r.arena, slot, @intCast(k));
            const wnflag = r.wnflag;
            const arena = r.arena;
            const models = r.models.items;
            const kvs = r.kvs.items;
            var names: std.StringHashMapUnmanaged(u32) = .empty;
            const next = try arena.alloc(u32, models.len);
            @memset(next, none);
            const bounds = try arena.alloc([4]f64, models.len);
            // Global rows only: a subcircuit's models are its own.
            for (models, 0..) |m, i| if (r.model_ids.contains(m.name)) try names.put(arena, m.name, @intCast(i));
            for (models, 0..) |m, mi| {
                if (!r.model_ids.contains(m.name)) continue;
                const dot = std.mem.lastIndexOfScalar(u8, m.name, '.') orelse continue;
                _ = std.fmt.parseInt(u32, m.name[dot + 1 ..], 10) catch continue;
                bounds[mi] = binBounds(kvs[m.kv.start..][0..m.kv.len]) orelse continue;
                const entry = try names.getOrPut(arena, m.name[0..dot]);
                if (entry.found_existing) {
                    if (std.mem.eql(u8, models[entry.value_ptr.*].name, m.name[0..dot])) continue;
                    next[mi] = entry.value_ptr.*;
                }
                entry.value_ptr.* = @intCast(mi);
            }
            const lengths = std.StaticStringMap(u2).initComptime(.{
                .{ "l", 1 },  .{ "w", 1 },  .{ "pd", 1 }, .{ "ps", 1 }, .{ "sa", 1 }, .{ "sb", 1 }, .{ "sd", 1 },
                .{ "ad", 2 }, .{ "as", 2 },
            });
            const edges = r.hg.edges.slice();
            for (edges.items(.kind), edges.items(.positional), edges.items(.kv), edges.items(.model)) |kind, ps, ks, *model| {
                if (kind != 'm') continue;
                const kv = r.kvs.items[ks.start..][0..ks.len];
                var swept_geometry = false;
                for (kv) |*item| {
                    const power = lengths.get(item.key) orelse continue;
                    if (item.value != .num) return error.ParseError;
                    const factor = if (power == 2) scale * scale else scale;
                    if (slot_of.get(&item.value)) |k| {
                        @constCast(live.scale)[k] = factor;
                        swept_geometry = swept_geometry or std.mem.eql(u8, item.key, "l") or std.mem.eql(u8, item.key, "w");
                    }
                    if (scale != 1) item.value.num *= factor;
                }
                if (ps.len == 0) continue;
                const first = &r.values.items[ps.start];
                if (first.* != .name) continue;
                var bin = names.get(first.name) orelse continue;
                if (std.mem.eql(u8, first.name, models[bin].name)) continue;
                // A variant rewrites values, never the bin a card picked.
                if (swept_geometry) {
                    if (!@import("builtin").is_test) std.log.err("netlist: a swept or sampled l/w on binned model '{s}'", .{first.name});
                    return error.UnsupportedCard;
                }
                const l = number(kv, "l") orelse return error.ParseError;
                const use_nf = if (number(kv, "wnflag")) |flag| flag != 0 else wnflag;
                const nf = if (use_nf) number(kv, "nf") orelse 1 else 1;
                const w = (number(kv, "w") orelse return error.ParseError) / nf;
                while (bin != none) : (bin = next[bin]) {
                    if (binHolds(bounds[bin], l, w)) {
                        first.* = .{ .name = models[bin].name };
                        model.* = r.model_ids.get(models[bin].name) orelse none;
                        break;
                    }
                }
                if (bin == none) return error.ModelBinNotFound;
            }
        }

        /// Whether `model` is a bin of `base`: `base.<n>`.
        fn isBinOf(model: []const u8, base: []const u8) bool {
            if (model.len <= base.len + 1 or !std.mem.startsWith(u8, model, base) or model[base.len] != '.') return false;
            _ = std.fmt.parseInt(u32, model[base.len + 1 ..], 10) catch return false;
            return true;
        }

        /// A bin card's `{lmin, lmax, wmin, wmax}`, null unless all four are numbers.
        fn binBounds(kv: []const Kv) ?[4]f64 {
            return .{
                number(kv, "lmin") orelse return null, number(kv, "lmax") orelse return null,
                number(kv, "wmin") orelse return null, number(kv, "wmax") orelse return null,
            };
        }

        /// Whether bin bounds `b` hold `l` and `w`, each within 1 nm.
        fn binHolds(b: [4]f64, l: f64, w: f64) bool {
            return (@abs(l - b[0]) < 1e-9 or @abs(l - b[1]) < 1e-9 or (l > b[0] and l < b[1])) and
                (@abs(w - b[2]) < 1e-9 or @abs(w - b[3]) < 1e-9 or (w > b[2] and w < b[3]));
        }

        fn number(kv: []const Kv, key: []const u8) ?f64 {
            for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
                .num => |n| n,
                else => null,
            };
            return null;
        }
    };
}

/// A sweep grid: `lin` from an increment or a point count, `dec`/`oct`
/// from points per decade or octave, `poi` an explicit list.
const Grid = enum { lin, dec, oct, poi };
const grids = std.StaticStringMap(Grid).initComptime(.{ .{ "lin", .lin }, .{ "dec", .dec }, .{ "oct", .oct }, .{ "poi", .poi } });

/// The points of `grid` from `start` to `stop`. `x` is the increment
/// (`per_unit`) or the point count (`total`) for `lin`, and points per
/// decade or octave for `dec`/`oct`. The end point is kept within a
/// relative 1e-9, as a SPICE sweep keeps it.
fn points(arena: Allocator, grid: Grid, start: f64, stop: f64, x: f64, mode: enum { per_unit, total }) Error![]const f64 {
    const max_points = 1 << 24;
    var n: f64 = undefined;
    var ratio: f64 = 1;
    switch (grid) {
        .poi => unreachable,
        .lin => if (mode == .total) {
            if (!(x >= 1) or x != @trunc(x)) return error.ParseError;
            n = x;
        } else {
            if (x == 0 or !std.math.isFinite((stop - start) / x) or (stop - start) / x < 0) return error.ParseError;
            n = @floor((stop - start) / x + 1e-9) + 1;
        },
        .dec, .oct => {
            if (!(start > 0) or !(stop >= start) or !(x > 0)) return error.ParseError;
            ratio = std.math.pow(f64, if (grid == .dec) 10 else 2, 1 / x);
            n = @floor(@log(stop / start) / @log(ratio) + 1e-9) + 1;
        },
    }
    if (!(n <= max_points)) return error.ParseError;
    const out = try arena.alloc(f64, @intFromFloat(n));
    for (out, 0..) |*o, k| {
        const kf: f64 = @floatFromInt(k);
        o.* = switch (grid) {
            .lin => if (mode == .total)
                (if (out.len == 1) start else start + kf * (stop - start) / (n - 1))
            else
                start + kf * x,
            else => start * std.math.pow(f64, ratio, kf),
        };
    }
    return out;
}

fn appendSpan(comptime T: type, arena: Allocator, list: *std.ArrayList(T), items: []const T) Error!Span {
    const start = list.items.len;
    if (start + items.len > none) return error.CircuitTooLarge;
    try list.appendSlice(arena, items);
    return .{ .start = @intCast(start), .len = @intCast(items.len) };
}

test {
    _ = csr;
    _ = measure;
    _ = @import("tests/netlist.zig");
}
