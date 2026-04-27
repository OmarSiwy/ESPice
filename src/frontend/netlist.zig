//! Netlist lines in; nets × devices hypergraph, models and analysis cards out.
//!
//!     bytes ─fold case─▶ logical lines ─split─▶ fields ─switch(first byte)─▶ tables
//!
//! Three walks over the logical lines, each needing what the previous found:
//! declarations (subcircuit line ranges, `.param`, `.model`, directives),
//! then devices (an `X` card re-reads its subcircuit's lines under a frame),
//! then analysis nets. Nothing is a tree: values are rows of flat tables, and
//! an expression that does not fold is flat postfix (`expr.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const lines = @import("lines.zig");
pub const source = @import("source.zig");
const csr = @import("csr.zig");
pub const expr = @import("expr.zig");
const Name = @import("core").Name;
const InternPool = @import("core").InternPool;
const requests = @import("core").query;

pub const Dialect = lines.Dialect;
pub const VertexId = csr.VertexId;
pub const EdgeId = csr.EdgeId;
pub const Kind = requests.Kind;
pub const ground: VertexId = @enumFromInt(0);
/// Missing id in every u32 index space here.
pub const none = std.math.maxInt(u32);
pub const Error = error{ OutOfMemory, ParseError, ModelBinNotFound, CircuitTooLarge };

/// Rows `start..start+len` of a flat table.
pub const Span = struct { start: u32 = 0, len: u32 = 0 };

pub const Value = union(enum) {
    num: f64,
    name: []const u8,
    /// Postfix ops in `Netlist.ops` that did not fold to a number.
    expr: Span,
    /// `name(args)`: a source waveform or a `v(...)`/`i(...)` output.
    group: Group,
};

/// ponytail: group arguments are arena slices, not a table: a few per deck.
pub const Group = struct { name: []const u8, args: []const Value };
/// `key=value`; a positional model value has an empty key.
pub const Kv = struct { key: []const u8, value: Value };

pub const Net = struct { name: Name };

/// Hyperedge payload. `kind` is the lowercase card letter.
pub const Device = struct {
    kind: u8,
    name: Name,
    /// `.model` row the first positional names, `none` otherwise.
    model: u32,
    positional: Span,
    kv: Span,
    /// Subcircuit definition + 1 and expansion ordinal, 0 at top level.
    subckt_type: u16,
    subckt_instance: u32,
};

pub const Hypergraph = csr.BipartiteHypergraph(Net, Device);

pub const Model = struct { name: []const u8, kind: []const u8, kv: []const Kv };

/// An analysis card. `pos`/`neg` are the output `v(a[,b])` nets, `ports` the
/// four `.pz` nets; `none` where the card names none or an unknown net.
pub const Analysis = struct {
    kind: Kind,
    args: []const Value,
    pos: u32 = none,
    neg: u32 = none,
    ports: [4]u32 = @splat(none),
};

/// `.options` and single-value `.temp` cards, in deck order.
pub const Config = struct { temp: bool, args: []const Value };
pub const Ic = struct { net: VertexId, value: f64 };
pub const ForeignKind = source.ForeignKind;
pub const Foreign = struct { kind: ForeignKind, path: []const u8 };

/// Deck data: everything that is not circuit topology.
pub const Deck = struct {
    title: []const u8,
    dialect: Dialect,
    analyses: []const Analysis,
    config: []const Config,
    ic: []const Ic,
    foreign: []const Foreign,
};

pub const Netlist = struct {
    /// Net and device names.
    pool: InternPool,
    graph: Hypergraph.Graph,
    /// Edges counting-sorted by card letter; `kind_starts[c - 'a']` opens
    /// letter c's run, [26] is the edge count.
    order: []const EdgeId,
    kind_starts: [27]u32,
    values: []const Value,
    kvs: []const Kv,
    ops: []const expr.Op,
    consts: []const f64,
    models: []const Model,
    model_ids: std.StringHashMapUnmanaged(u32),
    deck: Deck,

    /// A card as the builder reads it.
    pub const View = struct {
        name: []const u8,
        kind: u8,
        pins: []const VertexId,
        positional: []const Value,
        kv: []const Kv,
        model: ?Model,
        subckt_type: u16,
        subckt_instance: u32,
    };

    pub fn bucket(nl: *const Netlist, c: u8) []const EdgeId {
        return nl.order[nl.kind_starts[c - 'a']..nl.kind_starts[c - 'a' + 1]];
    }

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
            .subckt_type = d.subckt_type,
            .subckt_instance = d.subckt_instance,
        };
    }

    pub fn deviceCount(nl: *const Netlist) u32 {
        return nl.graph.edgeCount();
    }

    pub fn netName(nl: *const Netlist, v: VertexId) []const u8 {
        return nl.pool.str(nl.graph.vertices.items(.name)[v.index()]);
    }

    /// First `.model` card named `name`.
    pub fn findModel(nl: *const Netlist, name: []const u8) ?Model {
        return if (nl.model_ids.get(name)) |i| nl.models[i] else null;
    }

    pub fn exprOps(nl: *const Netlist, span: Span) []const expr.Op {
        return nl.ops[span.start..][0..span.len];
    }
};

pub fn isGroundName(name: []const u8) bool {
    return std.mem.eql(u8, name, "0") or
        std.ascii.eqlIgnoreCase(name, "gnd") or
        std.ascii.eqlIgnoreCase(name, "ground");
}

const Card = union(enum) { end, ends, subckt, param, model, include, osdi_include, pre_osdi, verilog, options, ic, analysis: Kind };

fn an(kind: Kind) Card {
    return .{ .analysis = kind };
}

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
    .{ "mc", an(.mc) },       .{ "montecarlo", an(.mc) },         .{ "noise", an(.noise) },
    .{ "op", an(.op) },       .{ "pac", an(.pac) },               .{ "pnoise", an(.pnoise) },
    .{ "pss", an(.pss) },     .{ "pxf", an(.pxf) },               .{ "pz", an(.pz) },
    .{ "qpss", an(.qpss) },   .{ "sens", an(.sens) },             .{ "sp", an(.sp) },
    .{ "stb", an(.stb) },     .{ "temp", an(.temp) },             .{ "tf", an(.tf) },
    .{ "tran", an(.tran) },   .{ "trannoise", an(.tran_noise) },  .{ "tran_noise", an(.tran_noise) },
});

/// The card a `.keyword` names, case-insensitively; null for any other card.
fn cardOf(head: []const u8) ?Card {
    var buf: [16]u8 = undefined;
    if (head.len > buf.len) return null;
    return cards.get(std.ascii.lowerString(buf[0..head.len], head));
}

/// Read, fold case and split `src`, then build every table.
pub fn parse(arena: Allocator, src: []const u8, dialect: Dialect) Error!Netlist {
    return switch (dialect) {
        inline else => |d| Reader(lines.Syntax(d)).run(arena, src, d),
    };
}

/// Only analysis cards, resolved against `lookup` (`node(name) u32`), for
/// cards appended to a built circuit. Any other line is refused.
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
        var a: Analysis = .{ .kind = card.analysis, .args = args };
        resolve(&a, lookup);
        try out.append(arena, a);
    }
    return out.items;
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
    subckt_type: u16 = 0,
    instance: u32 = 0,
};

const Subckt = struct {
    name: []const u8,
    ports: []const []const u8,
    defaults: []const struct { key: []const u8, text: []const u8 },
    /// Lines between `.subckt` and `.ends`; dot cards among them are global.
    first: u32,
    end: u32,
};

const ModelRow = struct { name: []const u8, kind: []const u8, kv: Span };

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
        globals: Scope = .empty,
        global_scopes: [1]*const Scope = undefined,
        analyses: std.ArrayList(Analysis) = .empty,
        config: std.ArrayList(Config) = .empty,
        ic_cards: std.ArrayList([]const Value) = .empty,
        foreign: std.ArrayList(Foreign) = .empty,
        instances: u32 = 1,
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
            var model_lines: std.ArrayList(u32) = .empty;
            var directive_lines: std.ArrayList(u32) = .empty;
            try r.declarations(&top_devices, &model_lines, &directive_lines);
            for (model_lines.items) |i| try r.readModel(r.lines.items[i]);
            for (directive_lines.items) |i| try r.readDirective(r.lines.items[i]);

            const top: Frame = .{ .scopes = &r.global_scopes };
            for (top_devices.items) |i| try r.readDevice(r.lines.items[i], &top);
            try r.modelBins();

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
            var ic: std.ArrayList(Ic) = .empty;
            for (r.ic_cards.items) |args| {
                var buf: [24]u8 = undefined;
                var i: usize = 0;
                while (i + 1 < args.len) : (i += 2) {
                    const name = switch (args[i]) {
                        .group => |g| if (std.ascii.eqlIgnoreCase(g.name, "v") and g.args.len > 0) nodeText(g.args[0], &buf) else null,
                        else => null,
                    } orelse continue;
                    const value = switch (args[i + 1]) {
                        .num => |n| n,
                        else => continue,
                    };
                    const id = nets.node(name);
                    if (id == none or id == 0) continue;
                    try ic.append(arena, .{ .net = .from(id), .value = value });
                }
            }

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
                .deck = .{
                    .title = title,
                    .dialect = dialect,
                    .analyses = r.analyses.items,
                    .config = r.config.items,
                    .ic = ic.items,
                    .foreign = r.foreign.items,
                },
            };
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

        // -- walk 1: declarations ---------------------------------------------

        fn declarations(r: *R, top: *std.ArrayList(u32), models: *std.ArrayList(u32), directives: *std.ArrayList(u32)) Error!void {
            const arena = r.arena;
            var open: ?u16 = null;
            var defaults: std.ArrayList(@typeInfo(@FieldType(Subckt, "defaults")).pointer.child) = .empty;
            for (r.lines.items, 0..) |line, index| {
                const i: u32 = @intCast(index);
                if (line[0] != '.') {
                    if (open == null) try top.append(arena, i);
                    continue;
                }
                var f = F.init(line);
                const head = f.next().?;
                if (head.len < 2) return error.ParseError;
                const card = cardOf(head[1..]) orelse {
                    try directives.append(arena, i);
                    continue;
                };
                switch (card) {
                    .end => break,
                    .ends => {
                        const id = open orelse return error.ParseError;
                        r.subckts.items[id].end = i;
                        r.subckts.items[id].defaults = defaults.items;
                        open = null;
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
                    .model => try models.append(arena, i),
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
            if (open != null) return error.ParseError;
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

        fn readModel(r: *R, line: []const u8) Error!void {
            var f = F.init(line);
            _ = f.next();
            const name = f.next() orelse return error.ParseError;
            const kind = f.next() orelse return error.ParseError;
            if (!F.isWord(name) or !F.isWord(kind)) return error.ParseError;
            const top: Frame = .{ .scopes = &r.global_scopes };
            const matrix_keys = std.StaticStringMap(void).initComptime(.{ .{ "r", {} }, .{ "l", {} }, .{ "g", {} }, .{ "c", {} } });
            // CPL matrices are blank-separated; a negative entry is not a subtraction.
            const cpl = std.mem.eql(u8, kind, "cpl");
            r.card_kv.clearRetainingCapacity();
            while (f.next()) |t| {
                if (t[0] == '(' or t[0] == ')' or t[0] == ',') continue;
                if (!F.isWord(t)) return error.ParseError;
                if (f.takeEq()) {
                    const value = if (cpl and matrix_keys.has(t)) try r.readValue(&f, &top, true, true) else try r.kvValue(&f, &top, true);
                    try r.card_kv.append(r.arena, .{ .key = t, .value = value });
                } else {
                    const value: Value = if (S.parseNum(t)) |n| .{ .num = n } else try r.nameValue(t, &top, true);
                    try r.card_kv.append(r.arena, .{ .key = "", .value = value });
                }
            }
            const span = try appendSpan(Kv, r.arena, &r.kvs, r.card_kv.items);
            const gop = try r.model_ids.getOrPut(r.arena, name);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(r.models.items.len);
            try r.models.append(r.arena, .{ .name = name, .kind = kind, .kv = span });
        }

        fn readArgs(r: *R, f: *F) Error![]const Value {
            const top: Frame = .{ .scopes = &r.global_scopes };
            var args: std.ArrayList(Value) = .empty;
            while (f.next()) |t| {
                if (t[0] == ',' or t[0] == '=') continue;
                try args.append(r.arena, try r.valueAt(t, f, &top, false, false));
            }
            return args.items;
        }

        fn readDirective(r: *R, line: []const u8) Error!void {
            var f = F.init(line);
            const card = cardOf(f.next().?[1..]);
            const args = try r.readArgs(&f);
            const c = card orelse return;
            switch (c) {
                .analysis => |kind| {
                    try r.analyses.append(r.arena, .{ .kind = kind, .args = args });
                    if (kind == .temp and args.len == 1) try r.config.append(r.arena, .{ .temp = true, .args = args });
                },
                .options => try r.config.append(r.arena, .{ .temp = false, .args = args }),
                .ic => try r.ic_cards.append(r.arena, args),
                else => {},
            }
        }

        // -- values ---------------------------------------------------------------

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

        fn exprValue(r: *R, text: []const u8, frame: *const Frame, geometry: bool) Error!Value {
            const mark = r.scratch.mark();
            defer r.scratch.reset(mark);
            try expr.compileAll(S.parseNum, r.arena, &r.scratch, text);
            return r.fold(mark.ops, frame, geometry);
        }

        /// Splice parameters into the scratch ops from `from` on, then fold. A
        /// number keeps nothing; anything else keeps its postfix.
        fn fold(r: *R, from: usize, frame: *const Frame, geometry: bool) Error!Value {
            const ops_mark = r.ops.items.len;
            const consts_mark = r.consts.items.len;
            try r.subst(from, r.scratch.ops.items.len, frame, frame.scopes, 0);
            const v = try expr.fold(r.arena, &r.stack, r.ops.items[ops_mark..], r.consts.items, geometry);
            if (v.known) {
                r.ops.shrinkRetainingCapacity(ops_mark);
                r.consts.shrinkRetainingCapacity(consts_mark);
                return .{ .num = v.num };
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
            const geometry_names = std.StaticStringMap(void).initComptime(.{ .{ "l", {} }, .{ "w", {} }, .{ "mult", {} } });
            var i = from;
            while (i < to) : (i += 1) {
                const op = r.scratch.ops.items[i];
                switch (op.code) {
                    .num => try r.emitNum(r.scratch.consts.items[op.a]),
                    .ident => {
                        const name = r.scratch.names.items[op.a];
                        const hit = find(scopes, name) orelse {
                            try r.ops.append(r.arena, .{ .code = .ident, .a = @intFromBool(geometry_names.has(name)) });
                            continue;
                        };
                        switch (hit.entry) {
                            .num => |n| try r.emitNum(n),
                            .text => |text| {
                                const mark = r.scratch.mark();
                                defer r.scratch.reset(mark);
                                try expr.compileAll(S.parseNum, r.arena, &r.scratch, text);
                                try r.subst(mark.ops, r.scratch.ops.items.len, frame, scopes[0 .. hit.level + 1], depth + 1);
                            },
                        }
                    },
                    // The device name is not kept: no consumer reads it.
                    .iprobe => try r.ops.append(r.arena, .{ .code = .iprobe, .a = none, .b = none }),
                    .vprobe => try r.ops.append(r.arena, .{
                        .code = .vprobe,
                        .a = if (op.a == none) none else (try r.netOf(frame, r.scratch.names.items[op.a])).index(),
                        .b = if (op.b == none) none else (try r.netOf(frame, r.scratch.names.items[op.b])).index(),
                    }),
                    else => try r.ops.append(r.arena, op),
                }
            }
        }

        fn emitNum(r: *R, n: f64) Error!void {
            try r.consts.append(r.arena, n);
            try r.ops.append(r.arena, .{ .code = .num, .a = @intCast(r.consts.items.len - 1) });
        }

        // -- walk 2: devices --------------------------------------------------------

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
            if (std.mem.eql(u8, node, "0") or std.mem.eql(u8, node, "gnd")) return r.intern(node);
            return r.intern(try r.joined(&.{ path, ".", node }));
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
            var f = F.init(line);
            const head = f.next() orelse return error.ParseError;
            if (!F.isWord(head) or !std.ascii.isAlphabetic(head[0])) return error.ParseError;
            const letter = std.ascii.toLower(head[0]);
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
            } else if (fixedPins(letter)) |count| {
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

        fn isModel(r: *R, name: []const u8) bool {
            return r.model_ids.contains(name);
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
            const model: u32 = if (r.positional.items.len > 0 and r.positional.items[0] == .name)
                r.model_ids.get(r.positional.items[0].name) orelse none
            else
                none;
            const name = try r.internName(if (frame.path) |path| try r.joined(&[_][]const u8{ &.{letter}, ".", path, ".", head }) else head);
            _ = r.hg.addEdge(arena, .{
                .kind = letter,
                .name = name,
                .model = model,
                .positional = try appendSpan(Value, arena, &r.values, r.positional.items),
                .kv = try appendSpan(Kv, arena, &r.kvs, r.card_kv.items),
                .subckt_type = frame.subckt_type,
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
                .subckt_type = id + 1,
                .instance = instance,
            };
            for (r.lines.items[sub.first..sub.end]) |line| {
                if (line[0] != '.') try r.readDevice(line, &child);
            }
        }

        // -- after the walk: model bins ---------------------------------------------

        /// `.option scale` and ngspice model binning (INPgetModBin): an M card
        /// naming `nm` takes the last-declared `nm.<n>` whose L/W bounds
        /// hold it, within 1 nm.
        fn modelBins(r: *R) Error!void {
            var scale: f64 = 1;
            var wnflag = r.dialect != .ngspice;
            for (r.config.items) |c| {
                if (c.temp) continue;
                for (c.args, 0..) |arg, i| {
                    if (arg != .name) continue;
                    const is_scale = std.mem.eql(u8, arg.name, "scale");
                    if (!is_scale and !std.mem.eql(u8, arg.name, "wnflag")) continue;
                    if (i + 1 == c.args.len or c.args[i + 1] != .num) return error.ParseError;
                    if (is_scale) scale = c.args[i + 1].num else wnflag = c.args[i + 1].num != 0;
                }
            }
            if (!(scale > 0) or !std.math.isFinite(scale)) return error.ParseError;
            const arena = r.arena;
            const models = r.models.items;
            const kvs = r.kvs.items;
            var names: std.StringHashMapUnmanaged(u32) = .empty;
            const next = try arena.alloc(u32, models.len);
            @memset(next, none);
            const bounds = try arena.alloc([4]f64, models.len);
            for (models, 0..) |m, i| try names.put(arena, m.name, @intCast(i));
            for (models, 0..) |m, mi| {
                const dot = std.mem.lastIndexOfScalar(u8, m.name, '.') orelse continue;
                _ = std.fmt.parseInt(u32, m.name[dot + 1 ..], 10) catch continue;
                const kv = kvs[m.kv.start..][0..m.kv.len];
                bounds[mi] = .{
                    number(kv, "lmin") orelse continue, number(kv, "lmax") orelse continue,
                    number(kv, "wmin") orelse continue, number(kv, "wmax") orelse continue,
                };
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
                for (kv) |*item| {
                    const power = lengths.get(item.key) orelse continue;
                    if (item.value != .num) return error.ParseError;
                    if (scale != 1) item.value.num *= if (power == 2) scale * scale else scale;
                }
                if (ps.len == 0) continue;
                const first = &r.values.items[ps.start];
                if (first.* != .name) continue;
                var bin = names.get(first.name) orelse continue;
                if (std.mem.eql(u8, first.name, models[bin].name)) continue;
                const l = number(kv, "l") orelse return error.ParseError;
                const use_nf = if (number(kv, "wnflag")) |flag| flag != 0 else wnflag;
                const nf = if (use_nf) number(kv, "nf") orelse 1 else 1;
                const w = (number(kv, "w") orelse return error.ParseError) / nf;
                while (bin != none) : (bin = next[bin]) {
                    const b = bounds[bin];
                    if ((@abs(l - b[0]) < 1e-9 or @abs(l - b[1]) < 1e-9 or (l > b[0] and l < b[1])) and
                        (@abs(w - b[2]) < 1e-9 or @abs(w - b[3]) < 1e-9 or (w > b[2] and w < b[3])))
                    {
                        first.* = .{ .name = models[bin].name };
                        model.* = r.model_ids.get(models[bin].name) orelse none;
                        break;
                    }
                }
                if (bin == none) return error.ModelBinNotFound;
            }
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

fn appendSpan(comptime T: type, arena: Allocator, list: *std.ArrayList(T), items: []const T) Error!Span {
    const start = list.items.len;
    if (start + items.len > none) return error.CircuitTooLarge;
    try list.appendSlice(arena, items);
    return .{ .start = @intCast(start), .len = @intCast(items.len) };
}

test {
    _ = csr;
    _ = @import("tests/netlist.zig");
}
