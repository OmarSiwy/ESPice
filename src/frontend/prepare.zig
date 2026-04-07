//! Source to netlist to immutable circuit and queries, for Problem.
const std = @import("std");
const problem = @import("problem_types");
const requests = @import("requests");
const netlist = @import("netlist");
const models = @import("device_models");
const build_options = @import("build_options");
const analyses = @import("analyses.zig");
const builder = @import("builder");
const Builder = builder.Builder;
const Job = requests.Query;
const Ic = problem.Ic;
pub const Prepared = problem.Prepared;
const GROUND = problem.GROUND;
const NO_NODE = analyses.NO_NODE;

pub const Dialect = netlist.Dialect;

pub const Source = union(enum) {
    file: []const u8,
    bytes: Bytes,

    /// origin is a real or virtual filename; relative paths use its directory.
    pub const Bytes = struct { data: []const u8, origin: []const u8 };
};

pub fn parseDialect(name: []const u8) ?Dialect {
    return std.StaticStringMap(Dialect).initComptime(.{
        .{ "ngspice", .ngspice }, .{ "ng", .ngspice },
        .{ "hspice", .hspice },   .{ "hs", .hspice },
        .{ "spectre", .spectre }, .{ "scs", .spectre },
    }).get(name);
}

/// Read, expand and flatten `input` into `session`, then load its HDL models.
/// The netlist borrows `session`; release it once `build` has returned.
pub fn prepare(io: std.Io, session: std.mem.Allocator, input: Source, dialect: Dialect) !netlist.Netlist {
    const origin = switch (input) {
        .file => |path| path,
        .bytes => |bytes| bytes.origin,
    };
    const raw = switch (input) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(io, path, session, .unlimited),
        .bytes => |bytes| try session.dupe(u8, bytes.data),
    };
    const text = if (dialect == .spectre) raw else try netlist.source.expand(io, session, origin, raw);
    const nl = try netlist.parse(session, text, dialect);
    try loadModels(io, session, nl.deck.foreign, origin);
    return nl;
}

fn loadModels(io: std.Io, session: std.mem.Allocator, foreign: []const netlist.Foreign, origin: []const u8) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    for (foreign) |f| if (f.kind == .verilog_a or f.kind == .verilog) try paths.append(session, if (std.fs.path.isAbsolute(f.path))
        f.path
    else
        try std.fs.path.join(session, &.{ std.fs.path.dirname(origin) orelse ".", f.path }));
    if (paths.items.len == 0) return;

    const compiler_paths: models.vaload.BuildPaths = .{
        .work_dir = try std.fs.path.join(session, &.{ build_options.src_root, ".zig-cache", "espice-hdl" }),
        .contract = build_options.contract_path,
        .dyn = build_options.dyn_path,
        .gompute = build_options.gompute_path,
        .device_ir = build_options.device_ir_path,
    };
    // Registry keys and loaded code outlive this problem's session arena.
    try models.vaload.ensureAllLoaded(std.heap.smp_allocator, io, paths.items, compiler_paths);
}

/// Build a passive circuit from a netlist. Scratch owns wiring; the session
/// arena owns every published slice.
pub fn build(sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: netlist.Netlist) !Prepared {
    if (nl.deck.analyses.len > (std.math.maxInt(u32) - 1) / 3) return error.CircuitTooLarge;
    const deck_opts = try analyses.deckOptions(nl.deck.config);
    var b = try Builder.init(sim_arena);
    var compiled_ok = false;
    errdefer if (!compiled_ok) b.deinit();

    // `.options tnom` is a model-card default (b4set.c:1950): models read it
    // as they are derived, before the pattern freezes.
    b.nom_temp_c = deck_opts.tnom_c;
    try b.reserveNodes(nl.graph.vertexCount());

    var nb = try builder.NetBuilder.init(parse_arena, &b, nl);
    try nb.build();
    try nb.tagSubcircuitNodes();
    // Runtime-loaded HDL devices, after the built-in ones and before the freeze.
    try nb.addDynDevices();

    // The card table outlives the Builder; its names live on the parse arena.
    const cards = try sim_arena.dupe(requests.CardRef, b.cards.items);
    for (cards) |*c| {
        c.name = try sim_arena.dupe(u8, c.name);
        c.type_name = try sim_arena.dupe(u8, c.type_name);
    }
    var perm: ?[]const u32 = null;
    var circuit = try b.compilePerm(&perm);
    compiled_ok = true;
    errdefer circuit.deinit();

    // Rows the NetBuilder recorded before the freeze are in pre-BBD coordinates.
    if (perm) |p| for ([_][]u32{
        nb.v.items(.branch),       nb.v.items(.pos),    nb.v.items(.neg),  nb.i.items(.pos),  nb.i.items(.neg),
        nb.br.items(.row),         nb.l.items(.branch), nb.ac.items(.pos), nb.ac.items(.neg), (&nb.source_node)[0..1],
        (&nb.source_branch)[0..1], nb.rows,
    }) |rows| for (rows) |*row| {
        if (row.* < p.len) row.* = p[row.*];
    };

    var ic: std.ArrayList(Ic) = .empty;
    for (nl.deck.ic) |item| {
        // An `.ic` on a node no device touches is dropped, like every other
        // unresolvable directive name.
        const row = nb.frozenRow(item.net.index());
        if (row == NO_NODE or row == GROUND) continue;
        try ic.append(sim_arena, .{ .node = row, .value = item.value });
    }

    const bindings: problem.QueryBindings = .{
        .v_names = try copyNames(sim_arena, nb.v.items(.name)),
        .i_names = try copyNames(sim_arena, nb.i.items(.name)),
        .v_branches = try sim_arena.dupe(u32, nb.v.items(.branch)),
        .v_pos = try sim_arena.dupe(u32, nb.v.items(.pos)),
        .v_neg = try sim_arena.dupe(u32, nb.v.items(.neg)),
        .i_pos = try sim_arena.dupe(u32, nb.i.items(.pos)),
        .i_neg = try sim_arena.dupe(u32, nb.i.items(.neg)),
        .v_distof1 = try sim_arena.dupe([2]f64, nb.v.items(.distof1)),
        .ports = try nb.portList(sim_arena),
    };

    // Probes: branch currents first, then every named node. ngspice gives every
    // MNA branch-current unknown an `i(<card>)` column (V, L, E, H, V-mode B);
    // F, G, S and I-mode B stamp no branch. Branch-first, unlike ngspice,
    // because tf/sens/dcmatch/pxf/pac/disto default their output to the last
    // probe, which must stay the last named node. Named nodes and branch rows
    // are disjoint, so circuit.n bounds the total.
    const probe_buf = try sim_arena.alloc(u32, circuit.n);
    const label_buf = try sim_arena.alloc([]const u8, circuit.n);
    var n_probes: u32 = 0;
    for ([_][]const []const u8{ nb.v.items(.name), nb.l.items(.name), nb.br.items(.name) }, [_][]const u32{ nb.v.items(.branch), nb.l.items(.branch), nb.br.items(.row) }) |names, rows| {
        for (names, rows) |name, br| {
            probe_buf[n_probes] = br;
            label_buf[n_probes] = try std.fmt.allocPrint(sim_arena, "i({s})", .{name});
            n_probes += 1;
        }
    }
    for (1..circuit.n) |i| {
        const label = circuit.nodeName(@intCast(i));
        if (label.len != 0) {
            probe_buf[n_probes] = @intCast(i);
            label_buf[n_probes] = try std.fmt.allocPrint(sim_arena, "v({s})", .{label});
            n_probes += 1;
        }
    }

    // Analysis nets to circuit rows.
    const cards_rows = try parse_arena.dupe(netlist.Analysis, nl.deck.analyses);
    for (cards_rows) |*a| {
        a.pos = nb.frozenRow(a.pos);
        a.neg = nb.frozenRow(a.neg);
        for (&a.ports) |*p| p.* = nb.frozenRow(p.*);
    }
    return .{
        .circuit = circuit,
        .probes = probe_buf[0..n_probes],
        .probe_labels = label_buf[0..n_probes],
        .source_node = nb.source_node,
        .source_branch = nb.source_branch,
        .ac_drive = try nb.acExcitation(sim_arena, circuit.n),
        .title = try sim_arena.dupe(u8, nl.deck.title),
        .n_devices = nl.deviceCount(),
        .ic = ic.items,
        .deck_tol = deck_opts.tol,
        .deck_temp = deck_opts.temp_c,
        .deck_method = deck_opts.method,
        .queries = try analyses.queries(sim_arena, cards_rows, analyses.deck_output_nodes, bindings, cards, deck_opts),
        .bindings = bindings,
        .cards = cards,
        .ac_overrides = try acOverrides(sim_arena, cards, nb.ac_res.items(.name), nb.ac_res.items(.value)),
    };
}

fn copyNames(arena: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copied = try arena.alloc([]const u8, names.len);
    for (names, copied) |name, *copy| copy.* = try arena.dupe(u8, name);
    return copied;
}

/// Frozen-circuit node row by label; NO_NODE when the deck never named it.
const NodeIndex = struct {
    map: std.StringHashMapUnmanaged(u32),

    fn init(arena: std.mem.Allocator, circuit: *const problem.Circuit) !NodeIndex {
        var map: std.StringHashMapUnmanaged(u32) = .empty;
        try map.ensureTotalCapacity(arena, circuit.n);
        for (0..circuit.n) |i| {
            const label = circuit.nodeName(@intCast(i));
            if (label.len != 0) map.putAssumeCapacity(label, @intCast(i));
        }
        return .{ .map = map };
    }

    pub fn node(self: NodeIndex, name: []const u8) u32 {
        return self.map.get(name) orelse NO_NODE;
    }
};

/// Resolve additional SPICE analysis cards against the published circuit.
/// Topology and deck settings are fixed; only query descriptions are allocated.
pub fn resolveQueries(arena: std.mem.Allocator, prepared: *const Prepared, directive_text: []const u8) ![]const Job {
    const nodes: NodeIndex = try .init(arena, &prepared.circuit);
    const cards = try netlist.parseAnalyses(arena, directive_text, nodes);
    if (cards.len == 0) return error.InvalidAnalysisArguments;
    // Appended queries accept only single-ended outputs.
    return analyses.queries(arena, cards, 1, prepared.bindings, prepared.cards, .{
        .tol = prepared.deck_tol,
        .method = prepared.deck_method,
        .temp_c = prepared.deck_temp,
    });
}

/// Preserve card identities so each mutable analysis clone binds its own pointers.
fn acOverrides(
    arena: std.mem.Allocator,
    cards: []const requests.CardRef,
    names: []const []const u8,
    values: []const f64,
) ![]const problem.AcOverride {
    const overrides = try arena.alloc(problem.AcOverride, names.len);
    for (names, values, overrides) |name, value, *override| {
        for (cards) |card| {
            if (!std.mem.eql(u8, card.name, name)) continue;
            override.* = .{ .type_name = card.type_name, .index = card.index, .param_name = "r", .value = value };
            break;
        } else return error.InvalidAcOverride;
    }
    return overrides;
}
