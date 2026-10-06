//! Source to netlist to frozen circuit and queries: the frontend's entry
//! points for the Problem facade. Cites no outside source; the run and
//! variant plan follows dev/analysis/variants.md, the arenas AGENTS.md §2.12.
const std = @import("std");
const core = @import("core");
const requests = @import("core").query;
const netlist = @import("netlist");
const device = @import("device");
const analyses = @import("analyses.zig");
const builder = @import("builder");
const variants = @import("variants.zig");
const mosra = @import("mosra.zig");
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
    runs: []Prepared = &.{},
    /// The deck's HSPICE optimization, when it has one. It borrows the
    /// parse arena, which must then outlive the Prepared.
    tuner: ?variants.Tuner = null,
    /// The live `.param` values a caller sets on the prepared circuit
    /// (`prepare`'s `live`); null without any. It borrows the parse arena,
    /// which must then outlive the Prepared.
    tuning: ?*variants.Tuning = null,

    /// Releases this run's circuit and every nested run's, and the tuning's
    /// templates. The deck slices stay with the session arena. Leaves
    /// `self` undefined.
    pub fn deinit(self: *Prepared) void {
        for (self.runs) |*run| run.deinit();
        if (self.tuning) |t| t.deinit();
        self.circuit.deinit();
        self.* = undefined;
    }
};
const NO_NODE = analyses.NO_NODE;

/// The netlist syntax a deck is read in: ngspice, HSPICE or Spectre.
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

/// Reads, expands and flattens `input` into `session` and reads its data
/// files; compiles nothing (`loadModels` does, #13). The global `.param`
/// names in `live` stay live, so the built circuit takes new values for
/// them without a re-parse (`Prepared.tuning`). The netlist borrows
/// `session`; release it once `build` has returned, or with the Prepared
/// when `live` is not empty. Spectre input expands its `include`s
/// (`source.expandSpectre`) and nothing else: it splits no `.alter` runs
/// and reads no data files. Fails with `UnknownParameter` for a `live`
/// name no global `.param` defines, and with the file error of an
/// unreadable deck, include or data file.
pub fn prepare(io: std.Io, session: std.mem.Allocator, input: Source, dialect: Dialect, live: []const []const u8) !netlist.Netlist {
    const origin = switch (input) {
        .file => |path| path,
        .bytes => |bytes| bytes.origin,
    };
    const raw = switch (input) {
        .file => |path| try std.Io.Dir.cwd().readFileAlloc(io, path, session, .unlimited),
        .bytes => |bytes| try session.dupe(u8, bytes.data),
    };
    if (dialect == .spectre) {
        return netlist.parseLive(session, try netlist.source.expandSpectre(io, session, origin, raw), dialect, live);
    }
    const runs = try netlist.source.splitAlters(session, raw);
    var nl = try netlist.parseLive(session, try netlist.source.expand(io, std.heap.page_allocator, session, origin, runs[0]), dialect, live);
    const alters = try session.alloc([]const u8, runs.len - 1);
    for (alters, runs[1..]) |*text, run| text.* = try netlist.source.expand(io, std.heap.page_allocator, session, origin, run);
    nl.deck.alters = alters;
    nl.files = try loadData(io, session, nl.deck.foreign, origin);
    return nl;
}

/// Reads every data file the deck names, relative to the deck's directory.
fn loadData(io: std.Io, session: std.mem.Allocator, foreign: []const netlist.Foreign, origin: []const u8) ![]const netlist.DataFile {
    var files: std.ArrayList(netlist.DataFile) = .empty;
    for (foreign) |f| if (f.kind == .data) {
        const path = if (std.fs.path.isAbsolute(f.path)) f.path else try std.fs.path.join(session, &.{ std.fs.path.dirname(origin) orelse ".", f.path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, session, .unlimited) catch |err| {
            std.log.err("netlist: cannot read data file {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        try files.append(session, .{ .path = f.path, .bytes = bytes });
    };
    return files.items;
}

/// Compiles and loads into `lib` the HDL models `nl` (from `prepare` on a
/// deck at `origin`) includes, paths relative to the deck's directory.
/// Fails with `OsdiUnsupported` on any OSDI include (`pre_osdi`, `osdi`)
/// and with the loader's error for a model that does not compile.
pub fn loadModels(io: std.Io, lib: *device.Library, session: std.mem.Allocator, nl: netlist.Netlist, origin: []const u8) !void {
    const foreign = nl.deck.foreign;
    var paths: std.ArrayList([]const u8) = .empty;
    for (foreign) |f| {
        const path = if (std.fs.path.isAbsolute(f.path))
            f.path
        else
            try std.fs.path.join(session, &.{ std.fs.path.dirname(origin) orelse ".", f.path });
        switch (f.kind) {
            .data => {},
            .verilog_a, .verilog => try paths.append(session, path),
            // ESPice compiles Verilog-A through VerA and never loads OSDI, so an
            // OSDI reference is an error rather than a guess at a substitute.
            .osdi_include, .pre_osdi => {
                if (!@import("builtin").is_test) std.log.err("netlist: {s} {s}: espice does not load OSDI binaries; load the Verilog-A source with .hdl \"model.va\"", .{ @tagName(f.kind), f.path });
                return error.OsdiUnsupported;
            },
        }
    }
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
    // One buffer for every lowercased label, not an allocation per label.
    var lower: std.ArrayList(u8) = .empty;
    for (p, l) |row, label| {
        try lower.resize(scratch, label.len);
        if (!wanted.contains(std.ascii.lowerString(lower.items, label))) continue;
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
/// Caller owns the result and releases its circuits with `Prepared.deinit`.
pub fn build(lib: *const device.Library, sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: netlist.Netlist) !Prepared {
    const owned = try parse_arena.create(netlist.Netlist);
    owned.* = nl;
    return buildRun(lib, sim_arena, parse_arena, owned, .{});
}

/// Which run of a deck `buildRun` builds.
pub const Run = variants.Run;

/// What `buildRun` can fail with: the errors of the stages one run goes
/// through (`buildOne`, and setting a point's live values), each raised and
/// logged with its card by the stage that owns it. A failed build releases
/// every circuit it froze; its slices stay in the arenas until they die.
pub const BuildError = ErrorOf(buildOne) || ErrorOf(variants.setPoint);

fn ErrorOf(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.error_set;
}

/// `build` for one run of the deck in `nl`, which must outlive the result
/// when the deck has an HSPICE optimization (`Prepared.tuner` borrows it).
/// A `run.point` sets `nl`'s live values first; they are nominal again
/// when a run with rebuilt points returns.
pub fn buildRun(lib: *const device.Library, sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: *netlist.Netlist, run: Run) BuildError!Prepared {
    var stack: std.ArrayList(netlist.expr.Val) = .empty;
    if (run.point) |pt| try variants.setPoint(parse_arena, &stack, nl, pt);
    var one = try buildOne(lib, sim_arena, parse_arena, nl, run);
    errdefer one.prepared.deinit();
    // Points the plan could not hold as rows, each its own run. A rebuilt
    // `.alter` netlist has no `.alter` of its own and a point run plans no
    // rebuilds, so this recursion is at most two runs deep.
    const runs = try sim_arena.alloc(Prepared, one.rebuilds.len);
    var built: usize = 0;
    errdefer for (runs[0..built]) |*r| r.deinit();
    for (one.rebuilds, runs) |r, *dst| {
        dst.* = try buildRun(lib, sim_arena, parse_arena, r.nl, r.run);
        built += 1;
    }
    for (one.rebuilds) |r| if (r.run.point != null) {
        try variants.setPoint(parse_arena, &stack, nl, .{ .label = "", .axis = 0, .live = nl.live.nominal });
        break;
    };
    one.prepared.runs = runs;
    return one.prepared;
}

/// One run without its rebuilt points: the prepared run and the runs its
/// plan asks for. `CircuitTooLarge` when the deck has more analysis cards
/// than a u32 job index can fan out.
fn buildOne(lib: *const device.Library, sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: *netlist.Netlist, run: Run) !struct { prepared: Prepared, rebuilds: []const variants.Rebuild } {
    if (nl.deck.analyses.len > (std.math.maxInt(u32) - 1) / 3) return error.CircuitTooLarge;
    const deck_opts = try analyses.deckOptions(nl.deck.config, nl.deck.dialect);
    var b = try Builder.init(sim_arena, lib);
    var compiled_ok = false;
    errdefer if (!compiled_ok) b.deinit();

    // `.options tnom` is a model-card default (b4set.c:1950): models read it
    // as they are derived, before the pattern freezes.
    b.nom_temp_c = deck_opts.tnom_c;
    b.reltol = deck_opts.tol.reltol;
    b.abstol = deck_opts.tol.abstol;
    b.vntol = deck_opts.tol.vntol;
    b.gmin = deck_opts.tol.gmin;
    try b.reserveNodes(nl.graph.vertexCount());

    if (nl.deck.draw_seed and run.point == null and !variants.any(nl.deck)) try variants.drawOnce(parse_arena, nl);
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
    const card_names = try requests.CardNames.init(sim_arena, cards);
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
    var tuner: ?variants.Tuner = null;
    // Variation groups for the mismatch and sensitivity cards: the deck's
    // `.variation` block, else the distribution calls in its models and
    // parameters (a PDK's mismatch), else `dcmatch`'s Pelgrom-or-unit
    // fallback, said aloud.
    var card_opts = deck_opts;
    for (nl.deck.analyses) |a| switch (a.kind) {
        .dcmatch, .acmatch, .dcsens => {
            if (nl.deck.variations.len == 0 and nl.live.site_keys.len == 0) {
                if (!@import("builtin").is_test) std.log.warn("variants: {s}: no .variation block and no agauss/gauss/unif/aunif/limit in a model or parameter, so each parameter takes its Pelgrom sigma, or unit variance without one", .{a.line});
                break;
            }
            var planner = try variants.Planner.init(lib, sim_arena, parse_arena, nl, &circuit, cards, "");
            card_opts.variations = if (nl.deck.variations.len != 0) try planner.variations() else try planner.siteVariations();
            if (nl.deck.variations.len == 0 and card_opts.variations.labels.len == 0 and !@import("builtin").is_test)
                std.log.warn("variants: {s}: no distribution call moves a device parameter (a PDK corner without its mismatch switch?), so the mismatch is zero", .{a.line});
            break;
        },
        else => {},
    };
    var aging: ?mosra.Plan = null;
    if (nl.deck.mosra) |m| {
        if (run.point != null or run.prefix.len != 0 or variants.any(nl.deck)) {
            if (!@import("builtin").is_test) std.log.err("netlist: .mosra together with .step, .alter or an analysis sweep: {s}", .{m.line});
            return error.UnsupportedCard;
        }
        aging = try mosra.plan(sim_arena, parse_arena, nl, &nb, &circuit, cards, deck_opts.temp_c orelse 27);
    }
    const plan: variants.Plan = if (aging) |a| .{ .variants = a.variants, .fanout = a.fanout } else if (run.point) |pt| blk: {
        var planner = try variants.Planner.init(lib, sim_arena, parse_arena, nl, &circuit, cards, "");
        var own = pt;
        own.label = run.prefix;
        try planner.add(own);
        break :blk .{ .variants = try planner.table(), .fanout = .{ .global = .{ .count = 1, .nominal = false }, .only = run.card } };
    } else if (run.prefix.len != 0 or variants.any(nl.deck)) blk: {
        var planner = try variants.Planner.init(lib, sim_arena, parse_arena, nl, &circuit, cards, run.prefix);
        const planned = try variants.plan(&planner);
        if (nl.deck.optimize != null) {
            tuner = try variants.Tuner.init(planner);
        }
        break :blk planned;
    } else .{};
    const tuning = if (nl.tunable.len != 0 and run.point == null and run.prefix.len == 0) try variants.Tuning.init(core.gpa, lib, sim_arena, parse_arena, nl, &circuit, cards) else null;
    errdefer if (tuning) |t| t.deinit();
    card_opts.sample = nl.deck.sample;
    card_opts.card_names = card_names;
    const queries = try analyses.queries(sim_arena, cards_rows, circuit.n, false, out.bindings, cards, card_opts, plan.fanout);
    if (aging) |*a| a.mosra.tran = for (queries) |q| {
        if (q == .tran and q.tran.tol.variant == null) break q.tran;
    } else {
        if (!@import("builtin").is_test) std.log.err("netlist: .mosra needs a .tran to stress the devices: {s}", .{nl.deck.mosra.?.line});
        return error.UnsupportedCard;
    };
    return .{ .rebuilds = plan.rebuilds, .prepared = .{ .circuit = circuit, .tuner = tuner, .tuning = tuning, .deck = .{
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
        .uic_ic = out.uic_ic,
        .deck_tol = deck_opts.tol,
        .deck_temp = deck_opts.temp_c,
        .deck_method = deck_opts.method,
        .queries = queries,
        .mosra = if (aging) |a| a.mosra else null,
        .variants = plan.variants,
        .bindings = out.bindings,
        .cards = cards,
        .card_names = card_names,
        .ac_overrides = try acOverrides(sim_arena, cards, nb.ac_res.items(.name), nb.ac_res.items(.value)),
        .measures = try measures(sim_arena, nl.deck.measures),
        .save_op = if (nl.deck.save_op) |s| blk: {
            var own = s;
            if (s.file) |file| own.file = try sim_arena.dupe(u8, file);
            break :blk own;
        } else null,
        .stims = try stims(sim_arena, nl.deck.stims),
    } } };
}

/// `.stim` cards with their strings copied out of the parse arena.
fn stims(arena: std.mem.Allocator, cards: []const core.Stim) ![]const core.Stim {
    const out = try arena.dupe(core.Stim, cards);
    for (out) |*s| {
        if (s.file) |file| s.file = try arena.dupe(u8, file);
        s.dataname = try arena.dupe(u8, s.dataname);
        s.signals = try measures(arena, s.signals);
        const nodes = try arena.dupe([2][]const u8, s.nodes);
        for (nodes) |*pair| for (pair) |*n| {
            n.* = try arena.dupe(u8, n.*);
        };
        s.nodes = nodes;
        s.times = try arena.dupe(f64, s.times);
    }
    return out;
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
        m.expr = try measureOps(arena, m.expr);
        m.check.expect = try arena.dupe([2]f64, m.check.expect);
        for ([_]*core.MeasureClause{ &m.first, &m.second }) |c| {
            c.vec = try arena.dupe(u8, c.vec);
            c.vec2 = try arena.dupe(u8, c.vec2);
            c.ops = try measureOps(arena, c.ops);
            c.ops2 = try measureOps(arena, c.ops2);
            const refs = try arena.dupe(core.MeasureRef, c.refs);
            for (refs) |*ref| ref.expr = try measureOps(arena, ref.expr);
            c.refs = refs;
        }
    }
    return out;
}

fn measureOps(arena: std.mem.Allocator, ops: []const core.MeasureOp) ![]const core.MeasureOp {
    const out = try arena.dupe(core.MeasureOp, ops);
    for (out) |*op| if (op.* == .vector) {
        op.vector = try arena.dupe(u8, op.vector);
    };
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
/// that is not an analysis, or a single-value `.temp`, is
/// `UnsupportedDirectiveMutation`; text holding no card is
/// `InvalidAnalysisArguments`.
pub fn resolveQueries(arena: std.mem.Allocator, prepared: *const Prepared, directive_text: []const u8) ![]const Job {
    const nodes: NodeIndex = try .init(arena, &prepared.circuit);
    const cards = try netlist.parseAnalyses(arena, directive_text, nodes);
    if (cards.len == 0) return error.InvalidAnalysisArguments;
    for (cards) |*a| if (namesNoOutput(a.*)) {
        a.pos = prepared.deck.output_node;
    };
    return analyses.queries(arena, cards, prepared.circuit.n, true, prepared.deck.bindings, prepared.deck.cards, .{
        .tol = prepared.deck.deck_tol,
        .method = prepared.deck.deck_method,
        .temp_c = prepared.deck.deck_temp,
        .card_names = prepared.deck.card_names,
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

test parseDialect {
    try std.testing.expectEqual(Dialect.spectre, parseDialect("scs").?);
    try std.testing.expectEqual(Dialect.ngspice, parseDialect("ngspice").?);
    // Only the listed names and aliases, no prefixes.
    try std.testing.expectEqual(null, parseDialect("h"));
    try std.testing.expectEqual(null, parseDialect(""));
}

test keepSaved {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A label past 64 bytes is still matched (it used to be dropped).
    const long = "v(xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx)";
    var probe_buf = [_]u32{ 1, 2, 3 };
    var label_buf = [_][]const u8{ "v(A)", long, "v(c)" };
    var probes: []u32 = &probe_buf;
    var labels: [][]const u8 = &label_buf;
    try keepSaved(arena.allocator(), &probes, &labels, &.{ long, "v(a)", "v(nowhere)" });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, probes);
    try std.testing.expectEqualStrings("v(A)", labels[0]);
    try std.testing.expectEqualStrings(long, labels[1]);
    try keepSaved(arena.allocator(), &probes, &labels, &.{"v(none)"});
    try std.testing.expectEqual(@as(usize, 0), probes.len);
}

test namesNoOutput {
    try std.testing.expect(namesNoOutput(.{ .kind = .pac, .args = &.{} }));
    try std.testing.expect(namesNoOutput(.{ .kind = .pxf, .args = &.{} }));
    try std.testing.expect(!namesNoOutput(.{ .kind = .pxf, .args = &.{}, .sn = true }));
    try std.testing.expect(!namesNoOutput(.{ .kind = .ac, .args = &.{} }));
}
