//! Source to netlist to frozen circuit and queries: the frontend's entry
//! points for the Problem facade.
const std = @import("std");
const core = @import("core");
const requests = @import("core").query;
const netlist = @import("netlist");
const device = @import("device");
const analyses = @import("analyses.zig");
const builder = @import("builder");
const variants = @import("variants.zig");
const Builder = builder.Builder;
const Job = requests.Query;
const Ic = core.Ic;
const GROUND = core.GROUND;

/// Construction result: the frozen topology and what the deck says about it.
/// The session arena owns every deck slice; `deinit` releases the circuits.
pub const Prepared = struct {
    circuit: device.Circuit,
    deck: core.Deck,
    /// Variant runs whose topology differs from `circuit` (an `.alter`
    /// that swaps elements, a point that collapses a node), each with its
    /// own circuit, deck and variant labels, in output order after this one.
    runs: []const Prepared = &.{},
    /// The deck's HSPICE optimization, when it has one. It borrows the
    /// parse arena, which must then outlive the Prepared.
    tuner: ?*variants.Tuner = null,

    pub fn deinit(self: *Prepared) void {
        for (self.runs) |*run| @constCast(run).deinit();
        self.circuit.deinit();
        self.* = undefined;
    }
};
const NO_NODE = analyses.NO_NODE;

pub const Dialect = netlist.Dialect;

/// Where a deck comes from.
pub const Source = union(enum) {
    /// Path of the deck file.
    file: []const u8,
    bytes: Bytes,

    /// In-memory deck; `origin` is a real or virtual filename whose
    /// directory relative includes resolve against.
    pub const Bytes = struct { data: []const u8, origin: []const u8 };
};

/// The dialect a CLI name or short alias (`ng`, `hs`, `scs`) selects.
pub fn parseDialect(name: []const u8) ?Dialect {
    return std.StaticStringMap(Dialect).initComptime(.{
        .{ "ngspice", .ngspice }, .{ "ng", .ngspice },
        .{ "hspice", .hspice },   .{ "hs", .hspice },
        .{ "spectre", .spectre }, .{ "scs", .spectre },
    }).get(name);
}

/// Reads, expands and flattens `input` into `session`, then loads its HDL
/// models into `lib`. The netlist borrows `session`; release it once `build`
/// has returned. Spectre input takes no `.include` expansion.
pub fn prepare(io: std.Io, lib: *device.Library, session: std.mem.Allocator, input: Source, dialect: Dialect) !netlist.Netlist {
    const origin = switch (input) {
        .file => |path| path,
        .bytes => |bytes| bytes.origin,
    };
    const raw = switch (input) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(io, path, session, .unlimited),
        .bytes => |bytes| try session.dupe(u8, bytes.data),
    };
    if (dialect == .spectre) {
        const nl = try netlist.parse(session, raw, dialect);
        try loadModels(io, lib, session, nl.deck.foreign, origin);
        return nl;
    }
    const runs = try netlist.source.splitAlters(session, raw);
    var nl = try netlist.parse(session, try netlist.source.expand(io, session, origin, runs[0]), dialect);
    const alters = try session.alloc([]const u8, runs.len - 1);
    for (alters, runs[1..]) |*text, run| text.* = try netlist.source.expand(io, session, origin, run);
    nl.deck.alters = alters;
    try loadModels(io, lib, session, nl.deck.foreign, origin);
    return nl;
}

fn loadModels(io: std.Io, lib: *device.Library, session: std.mem.Allocator, foreign: []const netlist.Foreign, origin: []const u8) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    for (foreign) |f| if (f.kind == .verilog_a or f.kind == .verilog) try paths.append(session, if (std.fs.path.isAbsolute(f.path))
        f.path
    else
        try std.fs.path.join(session, &.{ std.fs.path.dirname(origin) orelse ".", f.path }));
    if (paths.items.len == 0) return;

    try lib.load(io, paths.items);
}

/// Narrows the published outputs to the `.save` labels, in place. The
/// probes keep their order; a label nothing publishes is dropped.
fn keepSaved(scratch: std.mem.Allocator, probes: *[]u32, labels: *[][]const u8, saves: []const []const u8) !void {
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    for (saves) |s| try wanted.put(scratch, s, {});
    const p = probes.*;
    const l = labels.*;
    var kept: usize = 0;
    for (p, l) |row, label| {
        if (label.len > 64) continue;
        var buf: [64]u8 = undefined;
        if (!wanted.contains(std.ascii.lowerString(&buf, label))) continue;
        p[kept] = row;
        l[kept] = label;
        kept += 1;
    }
    probes.* = p[0..kept];
    labels.* = l[0..kept];
}

/// Builds the frozen circuit and deck data from `nl`, with its variants
/// (`.step`, `SWEEP`, `.alter`, Monte Carlo). `parse_arena` holds
/// construction scratch; `sim_arena` owns every published slice and must
/// outlive the result, as must `lib` when the deck uses loaded devices.
pub fn build(lib: *const device.Library, sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: netlist.Netlist) !Prepared {
    const owned = try parse_arena.create(netlist.Netlist);
    owned.* = nl;
    return buildRun(lib, sim_arena, parse_arena, owned, .{});
}

/// Which run of a deck `buildRun` builds.
pub const Run = struct {
    /// Label of the run's rows: `alter=2`, or a rebuilt point's own.
    prefix: []const u8 = "",
    /// A point whose circuit differs from the nominal one: `nl` already
    /// holds its live values, and the run is that one row.
    point: ?variants.Point = null,
    /// The point belongs to this analysis card's sweep alone.
    card: ?u32 = null,
};

/// `build` for one run of the deck in `nl`.
pub fn buildRun(lib: *const device.Library, sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: *const netlist.Netlist, run: Run) anyerror!Prepared {
    if (nl.deck.analyses.len > (std.math.maxInt(u32) - 1) / 3) return error.CircuitTooLarge;
    const deck_opts = try analyses.deckOptions(nl.deck.config, nl.deck.dialect);
    var b = try Builder.init(sim_arena, lib);
    var compiled_ok = false;
    errdefer if (!compiled_ok) b.deinit();

    // `.options tnom` is a model-card default (b4set.c:1950): models read it
    // as they are derived, before the pattern freezes.
    b.nom_temp_c = deck_opts.tnom_c;
    try b.reserveNodes(nl.graph.vertexCount());

    var nb = try builder.NetBuilder.init(parse_arena, &b, nl.*);
    try nb.build();
    try nb.tagSubcircuitNodes();
    // Runtime-loaded HDL devices, after the built-in ones and before the freeze.
    try nb.addDynDevices();

    // The card table outlives the Builder; its names live on the parse arena.
    const cards = try sim_arena.dupe(requests.CardRef, b.cards.items);
    for (cards) |*c| {
        c.name = try sim_arena.dupe(u8, c.name);
    }
    var perm: ?[]const u32 = null;
    var circuit = try b.compilePerm(&perm);
    compiled_ok = true;
    errdefer circuit.deinit();

    var out = try nb.publish(sim_arena, &circuit, perm);
    if (nl.deck.saves.len > 0) try keepSaved(parse_arena, &out.probes, &out.probe_labels, nl.deck.saves);

    // Analysis nets to circuit rows.
    const cards_rows = try parse_arena.dupe(netlist.Analysis, nl.deck.analyses);
    for (cards_rows) |*a| {
        a.pos = nb.frozenRow(a.pos);
        if (namesNoOutput(a.*)) a.pos = out.output_node;
        a.neg = nb.frozenRow(a.neg);
        for (&a.ports) |*p| p.* = nb.frozenRow(p.*);
    }
    var tuner: ?*variants.Tuner = null;
    const plan: variants.Plan = if (run.point) |pt| blk: {
        var planner = try variants.Planner.init(lib, sim_arena, parse_arena, nl, &circuit, cards, "");
        var own = pt;
        own.label = run.prefix;
        try planner.add(own);
        break :blk .{ .variants = try planner.table(), .fanout = .{ .global = .{ .count = 1, .nominal = false }, .only = run.card } };
    } else if (run.prefix.len != 0 or variants.any(nl.deck)) blk: {
        var planner = try variants.Planner.init(lib, sim_arena, parse_arena, nl, &circuit, cards, run.prefix);
        const planned = try variants.plan(&planner);
        if (nl.deck.optimize != null) {
            tuner = try parse_arena.create(variants.Tuner);
            tuner.?.* = try .init(planner);
        }
        break :blk planned;
    } else .{};
    return .{ .circuit = circuit, .runs = plan.runs, .tuner = tuner, .deck = .{
        .probes = out.probes,
        .probe_labels = out.probe_labels,
        .source_node = out.source_node,
        .source_branch = out.source_branch,
        .output_node = out.output_node,
        .ac_drive = out.ac_drive,
        .title = try sim_arena.dupe(u8, nl.deck.title),
        .n_devices = nl.deviceCount(),
        .ic = try nodeRows(sim_arena, &nb, nl.deck.ic),
        .nodeset = try nodeRows(sim_arena, &nb, nl.deck.nodeset),
        .deck_tol = deck_opts.tol,
        .deck_temp = deck_opts.temp_c,
        .deck_method = deck_opts.method,
        .queries = try analyses.queries(sim_arena, cards_rows, false, out.bindings, cards, deck_opts, plan.fanout),
        .variants = plan.variants,
        .bindings = out.bindings,
        .cards = cards,
        .ac_overrides = try acOverrides(sim_arena, cards, nb.ac_res.items(.name), nb.ac_res.items(.value)),
        .measures = try measures(sim_arena, nl.deck.measures),
    } };
}

/// `.ic`-style values on circuit rows. A node no device touches is dropped,
/// like every other unresolvable directive name.
fn nodeRows(arena: std.mem.Allocator, nb: *const builder.NetBuilder, items: []const netlist.Ic) ![]const Ic {
    var out: std.ArrayList(Ic) = .empty;
    for (items) |item| {
        const row = nb.frozenRow(item.net.index());
        if (row == NO_NODE or row == GROUND) continue;
        try out.append(arena, .{ .node = row, .value = item.value });
    }
    return out.items;
}

/// `.meas` cards with their strings copied out of the parse arena.
fn measures(arena: std.mem.Allocator, cards: []const core.Measure) ![]const core.Measure {
    const out = try arena.dupe(core.Measure, cards);
    for (out) |*m| {
        m.name = try arena.dupe(u8, m.name);
        m.expr = try arena.dupe(core.MeasureOp, m.expr);
        for ([_]*core.MeasureClause{ &m.first, &m.second }) |c| {
            c.vec = try arena.dupe(u8, c.vec);
            c.vec2 = try arena.dupe(u8, c.vec2);
        }
    }
    return out;
}

/// Cards whose output is `Deck.output_node` because they name none. HSPICE's
/// `.snxf v(out) ...` names its own.
fn namesNoOutput(a: netlist.Analysis) bool {
    return a.kind == .pac or (a.kind == .pxf and !a.sn) or a.kind == .disto or a.kind == .hbac;
}

/// Frozen-circuit node row by label, for cards appended after the build.
const NodeIndex = struct {
    map: std.StringHashMapUnmanaged(u32),

    fn init(arena: std.mem.Allocator, circuit: *const device.Circuit) !NodeIndex {
        var map: std.StringHashMapUnmanaged(u32) = .empty;
        try map.ensureTotalCapacity(arena, circuit.n);
        for (0..circuit.n) |i| {
            const label = circuit.nodeName(@intCast(i));
            if (label.len != 0) map.putAssumeCapacity(label, @intCast(i));
        }
        return .{ .map = map };
    }

    /// Row of net `name`; NO_NODE when the deck never named it.
    pub fn node(self: NodeIndex, name: []const u8) u32 {
        return self.map.get(name) orelse NO_NODE;
    }
};

/// Resolves analysis cards appended to a built circuit. Topology and deck
/// settings stay fixed; only the queries are allocated, in `arena`. Any card
/// that is not an analysis is `UnsupportedDirectiveMutation`.
pub fn resolveQueries(arena: std.mem.Allocator, prepared: *const Prepared, directive_text: []const u8) ![]const Job {
    const nodes: NodeIndex = try .init(arena, &prepared.circuit);
    const cards = try netlist.parseAnalyses(arena, directive_text, nodes);
    if (cards.len == 0) return error.InvalidAnalysisArguments;
    for (cards) |*a| if (namesNoOutput(a.*)) {
        a.pos = prepared.deck.output_node;
    };
    return analyses.queries(arena, cards, true, prepared.deck.bindings, prepared.deck.cards, .{
        .tol = prepared.deck.deck_tol,
        .method = prepared.deck.deck_method,
        .temp_c = prepared.deck.deck_temp,
    }, .{});
}

/// Each `ac=` resistance as a (type, instance, parameter) override, so every
/// analysis clone binds its own parameter pointer.
fn acOverrides(
    arena: std.mem.Allocator,
    cards: []const requests.CardRef,
    names: []const []const u8,
    values: []const f64,
) ![]const core.AcOverride {
    const overrides = try arena.alloc(core.AcOverride, names.len);
    for (names, values, overrides) |name, value, *override| {
        for (cards) |card| {
            if (!std.mem.eql(u8, card.name, name)) continue;
            override.* = .{ .type = card.type, .index = card.index, .param_name = "r", .value = value };
            break;
        } else return error.InvalidAcOverride;
    }
    return overrides;
}
