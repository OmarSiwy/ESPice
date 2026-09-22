//! Prepare source and build immutable circuit/query data for Problem.
const std = @import("std");
const problem = @import("problem_types");
const requests = @import("requests");
const numerics = @import("numerics");
const syntax = @import("syntax");
const models = @import("device_models");
const build_options = @import("build_options");
const types = syntax.types;
const netlist = @import("builder");
const Builder = netlist.Builder;
const Job = requests.Query;
const Ic = problem.Ic;
pub const Prepared = problem.Prepared;
const GROUND = problem.GROUND;
const directiveName = netlist.directiveName;
const directiveNumber = netlist.directiveNumber;
const directiveNodeName = netlist.directiveNodeName;
const findNameIndex = netlist.findNameIndex;

pub const Dialect = syntax.types.Dialect;

pub const Source = union(enum) {
    file: []const u8,
    bytes: Bytes,

    /// origin is a real or virtual filename; relative paths use its directory.
    pub const Bytes = struct { data: []const u8, origin: []const u8 };
};

pub const PreparedInput = struct {
    source: []const u8,
    origin: []const u8,
    ast: syntax.Ast,
};

pub fn parseDialect(name: []const u8) ?Dialect {
    return std.StaticStringMap(Dialect).initComptime(.{
        .{ "ngspice", .ngspice }, .{ "ng", .ngspice },
        .{ "hspice", .hspice },   .{ "hs", .hspice },
        .{ "spectre", .spectre }, .{ "scs", .spectre },
    }).get(name);
}

/// Copies caller input into the supplied arena. The AST borrows its storage;
/// the caller may release it once build has published the prepared circuit.
pub fn prepare(io: std.Io, session: std.mem.Allocator, input: Source, dialect: Dialect) !PreparedInput {
    const prepared = try parseSource(io, session, input, dialect);
    try loadModels(io, session, prepared);
    return prepared;
}

fn parseSource(io: std.Io, session: std.mem.Allocator, input: Source, dialect: Dialect) !PreparedInput {
    const origin = try session.dupe(u8, switch (input) {
        .file => |path| path,
        .bytes => |bytes| bytes.origin,
    });
    const source = switch (input) {
        .file => if (dialect == .spectre)
            try std.Io.Dir.cwd().readFileAlloc(io, origin, session, .unlimited)
        else
            try syntax.load(io, session, origin),
        .bytes => |bytes| if (dialect == .spectre)
            try session.dupe(u8, bytes.data)
        else
            try syntax.source.loadBytes(io, session, origin, bytes.data),
    };
    const ast = switch (dialect) {
        .ngspice => try syntax.Parser(syntax.ngspice).parse(session, source),
        .hspice => try syntax.Parser(syntax.hspice).parse(session, source),
        .spectre => try syntax.Parser(syntax.spectre).parse(session, source),
    };
    return .{ .source = source, .origin = origin, .ast = ast };
}

fn loadModels(io: std.Io, session: std.mem.Allocator, prepared: PreparedInput) !void {
    var model_count: usize = 0;
    for (prepared.ast.foreign) |foreign| switch (foreign.kind) {
        .verilog_a, .verilog => model_count += 1,
        else => {},
    };
    if (model_count == 0) return;

    const paths = try session.alloc([]const u8, model_count);
    var index: usize = 0;
    for (prepared.ast.foreign) |foreign| switch (foreign.kind) {
        .verilog_a, .verilog => {
            paths[index] = if (std.fs.path.isAbsolute(foreign.path))
                foreign.path
            else
                try std.fs.path.join(session, &.{ std.fs.path.dirname(prepared.origin) orelse ".", foreign.path });
            index += 1;
        },
        else => {},
    };

    const compiler_paths: models.vaload.BuildPaths = .{
        .work_dir = try std.fs.path.join(session, &.{ build_options.src_root, ".zig-cache", "espice-hdl" }),
        .contract = build_options.contract_path,
        .dyn = build_options.dyn_path,
        .gompute = build_options.gompute_path,
        .device_ir = build_options.device_ir_path,
    };
    // Registry keys and loaded code outlive this problem's session arena.
    try models.vaload.ensureAllLoaded(std.heap.smp_allocator, io, paths, compiler_paths);
}

/// Build a passive circuit from syntax. Scratch owns semantic expansion and
/// wiring; the session arena owns every published slice.
pub fn build(sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, ast: types.Ast) !Prepared {
    const nl = try syntax.elaborate(parse_arena, ast);
    if (nl.devices.len() > std.math.maxInt(u32) or nl.directives.len > (std.math.maxInt(u32) - 1) / 2)
        return error.CircuitTooLarge;
    const deck_opts = try parseDeckOptions(nl.directives);
    var b = try Builder.init(sim_arena);
    var compiled_ok = false;
    errdefer if (!compiled_ok) b.deinit();

    // Before `nb.build()`, because `.options tnom` is a MODEL-CARD default
    // (`b4set.c:1950`), not an analysis knob: every model is derived from
    // it as it is created, so nothing downstream has to re-derive and
    // `collapse` sees its final answer the first time.
    b.nom_temp_c = deck_opts.tnom_c;

    // Node count is bounded by (and usually close to) device count;
    // reserving here avoids incremental rehash during interning.
    try b.reserveNodes(@intCast(@min(nl.devices.len(), std.math.maxInt(u32))));

    var nb = try netlist.NetBuilder.init(parse_arena, &b, nl);
    try nb.build();

    try netlist.tagSubcircuitNodes(&b, nl.devices);

    // Runtime-loaded (.hdl card, dlopen'd) VA/V devices: erased Proto
    // path, batch machinery lives inside the model's .so. Must happen
    // before compile() freezes the pattern.
    try netlist.addDynDevices(&b, parse_arena, nl);

    var prepared: Prepared = undefined;
    // Resolve the output node(s) before compile() destroys the name table.
    // `v(a,b)` is a node DIFFERENCE, so the second name is resolved alongside
    // the first and NO_NODE means "single-ended" downstream.
    const dir_nodes = try parse_arena.alloc(u32, nl.directives.len);
    const dir_nodes_neg = try parse_arena.alloc(u32, nl.directives.len);
    for (nl.directives, dir_nodes, dir_nodes_neg) |dir, *id, *id_neg| {
        const arg: usize = if (std.ascii.eqlIgnoreCase(dir.kind, "four")) 1 else 0;
        if (requests.Keywords.get(dir.kind) != null and arg < dir.args.len) switch (dir.args[arg]) {
            .group => |g| if (g.args.len > 2) return error.UnsupportedAnalysisOutput,
            else => {},
        };
        const name = directiveNodeName(dir, arg) orelse
            (if (arg < dir.args.len) icNodeName(parse_arena, dir.args[arg]) else null);
        id.* = if (name) |n| b.node_names.get(n) orelse NO_NODE else NO_NODE;
        const neg = netlist.directiveNodeNameAt(dir, arg, 1);
        id_neg.* = if (neg) |n| b.node_names.get(n) orelse NO_NODE else NO_NODE;
    }

    // `.pz in+ in− out+ out− vol|cur pol|zer|pz` names four BARE nodes, three
    // more than `dir_nodes` carries, and the name table dies at compile() too.
    const dir_ports = try parse_arena.alloc([4]u32, nl.directives.len);
    for (nl.directives, dir_ports) |dir, *ports| {
        ports.* = @splat(NO_NODE);
        if (!std.ascii.eqlIgnoreCase(dir.kind, "pz")) continue;
        for (ports, 0..) |*port, i| {
            const name = bareNodeName(parse_arena, dir, i) orelse continue;
            port.* = b.node_names.get(name) orelse
                (if (netlist.isGroundName(name)) GROUND else NO_NODE);
        }
    }

    // `.ic` cards, resolved here for the same reason as `dir_nodes`: this is
    // the last point where `b.node_names` exists. Two passes so the result
    // is an exact prepared-arena slice rather than a growable list — the count is
    // known from the arg shape (`v(node)` group followed by its value).
    var n_ic: usize = 0;
    for (nl.directives) |dir| {
        if (!std.ascii.eqlIgnoreCase(dir.kind, "ic")) continue;
        n_ic += dir.args.len / 2;
    }
    const ic_buf = try sim_arena.alloc(Ic, n_ic);
    var n_ic_used: usize = 0;
    for (nl.directives) |dir| {
        if (!std.ascii.eqlIgnoreCase(dir.kind, "ic")) continue;
        var i: usize = 0;
        while (i + 1 < dir.args.len) : (i += 2) {
            const name = icNodeName(parse_arena, dir.args[i]) orelse continue;
            const value = netlist.valueNumber(dir.args[i + 1]) orelse continue;
            // An `.ic` on a node the netlist never mentions is a typo, not a
            // constraint. Dropping it silently matches how the rest of the
            // directive path treats unresolvable names.
            const id = b.node_names.get(name) orelse continue;
            if (id == GROUND) continue;
            ic_buf[n_ic_used] = .{ .node = id, .value = value };
            n_ic_used += 1;
        }
    }
    prepared.ic = ic_buf[0..n_ic_used];

    // compile() may apply the BBD node permutation (subckt decks) and
    // undefines the Builder on return, so the permutation comes back via
    // this out-param, not off `b`. Every index recorded BEFORE compile —
    // source branches/ports, inductor branches, `.ic` nodes, directive
    // nodes — is in old coordinates; the device protos were permuted
    // through applyPerm but these caller-side tables were not, which is
    // how a subckt branch probe read a voltage (fourbitadder i(vin1a) at
    // ~5 V). `mapNode` is the identity when perm is null (no BBD).
    var perm: ?[]const u32 = null;
    // compilePerm tears the Builder shell down; the card table is the one
    // thing on it that outlives the freeze (`.sens` names columns with it).
    // Rows are already on sim_arena — only the parse-arena name strings
    // have to be copied.
    const cards = try sim_arena.dupe(requests.CardRef, b.cards.items);
    for (cards) |*c| {
        c.name = try sim_arena.dupe(u8, c.name);
        c.type_name = try sim_arena.dupe(u8, c.type_name);
    }
    prepared.circuit = try b.compilePerm(&perm);
    compiled_ok = true;

    errdefer prepared.circuit.deinit();

    const mapNode = struct {
        fn f(p: ?[]const u32, id: u32) u32 {
            const pp = p orelse return id;
            return if (id < pp.len) pp[id] else id;
        }
    }.f;
    for (nb.v_branches[0..nb.n_v]) |*v| v.* = mapNode(perm, v.*);
    // `v_ports`/`v_nports` are build-time scratch everywhere EXCEPT portList
    // and the STB probe binding, both of which hand the row straight to a solve.
    for (nb.v_ports[0..nb.n_v]) |*v| v.* = mapNode(perm, v.*);
    for (nb.v_nports[0..nb.n_v]) |*v| v.* = mapNode(perm, v.*);
    for (nb.i_pos[0..nb.n_i]) |*v| v.* = mapNode(perm, v.*);
    for (nb.i_neg[0..nb.n_i]) |*v| v.* = mapNode(perm, v.*);
    for (nb.br_rows[0..nb.n_br]) |*v| v.* = mapNode(perm, v.*);
    for (nb.l_branches[0..nb.n_l]) |*v| v.* = mapNode(perm, v.*);
    for (nb.ac_pos[0..nb.n_ac]) |*v| v.* = mapNode(perm, v.*);
    for (nb.ac_neg[0..nb.n_ac]) |*v| v.* = mapNode(perm, v.*);
    nb.source_node = mapNode(perm, nb.source_node);
    nb.source_branch = mapNode(perm, nb.source_branch);
    for (dir_nodes) |*v| {
        if (v.* != NO_NODE) v.* = mapNode(perm, v.*);
    }
    for (dir_nodes_neg) |*v| {
        if (v.* != NO_NODE) v.* = mapNode(perm, v.*);
    }
    for (dir_ports) |*ports| {
        for (ports) |*v| {
            if (v.* != NO_NODE) v.* = mapNode(perm, v.*);
        }
    }
    for (ic_buf[0..n_ic_used]) |*e| e.node = mapNode(perm, e.node);
    // Escapes into run-time lifetime: title read at output time, counts in
    // the summary. Dupe/copy off the parse arena so it can be reset now.
    prepared.title = try sim_arena.dupe(u8, nl.title);
    prepared.n_devices = @intCast(nl.devices.len());

    prepared.source_node = nb.source_node;
    prepared.source_branch = nb.source_branch;
    // Every `AC`-carrying source collapsed into ONE excitation vector, in
    // post-permutation coordinates. Built here rather than per analysis
    // because it is deck data, not analysis data.
    prepared.ac_drive = try nb.acExcitation(sim_arena, prepared.circuit.n);

    prepared.cards = cards;
    prepared.bindings = .{
        .v_names = try copyNames(sim_arena, nb.v_names[0..nb.n_v]),
        .i_names = try copyNames(sim_arena, nb.i_names[0..nb.n_i]),
        .v_branches = try sim_arena.dupe(u32, nb.v_branches[0..nb.n_v]),
        .v_pos = try sim_arena.dupe(u32, nb.v_ports[0..nb.n_v]),
        .v_neg = try sim_arena.dupe(u32, nb.v_nports[0..nb.n_v]),
        .i_pos = try sim_arena.dupe(u32, nb.i_pos[0..nb.n_i]),
        .i_neg = try sim_arena.dupe(u32, nb.i_neg[0..nb.n_i]),
        .v_distof1 = try sim_arena.dupe([2]f64, nb.v_distof1[0..nb.n_v]),
        .ports = try nb.portList(sim_arena),
    };
    prepared.ac_overrides = try acOverrides(sim_arena, cards, nb.ac_res_names[0..nb.n_ac_res], nb.ac_res_values[0..nb.n_ac_res]);

    // Probes: branch currents first, then every named node. The rule is
    // ngspice's and it is structural, not a list of letters: every MNA
    // branch-current unknown gets a `CKTmkCur` row and `CKTnames` turns
    // every such row into an `i(<card>)` column. That covers V and L, and
    // equally E (vcvsset.c:41-46), H (ccvsset.c:41-46) and a V-mode B
    // (asrcsetup.c:78-83) — `nb.br_*` carries those. F, G and S stamp no
    // branch and correctly have no column.
    //
    // A V card sensed by F/H/W is NOT skipped: it keeps its current, which
    // now lives on the controlling model's `ctrl` branch (builder
    // addBranchRef rewrites `v_branches[ctrl]` to that row). ngspice emits
    // i(vam) for it too.
    //
    // Branch-first, NOT ngspice's voltage-first: tf/sens/dcmatch/pxf/pac/
    // disto default their output variable to probes[len-1], so the last
    // probe must stay the last NAMED NODE. Raw readers key on column
    // names, never position.
    // Named nodes and branch rows are disjoint (branches carry no label),
    // so circuit.n bounds the total.
    const probe_buf = try sim_arena.alloc(u32, prepared.circuit.n);
    const label_buf = try sim_arena.alloc([]const u8, prepared.circuit.n);
    var n_probes: u32 = 0;
    for ([_][]const []const u8{ nb.v_names[0..nb.n_v], nb.l_names[0..nb.n_l], nb.br_names[0..nb.n_br] }, [_][]const u32{ nb.v_branches[0..nb.n_v], nb.l_branches[0..nb.n_l], nb.br_rows[0..nb.n_br] }) |names, rows| {
        for (names, rows) |name, br| {
            probe_buf[n_probes] = br;
            label_buf[n_probes] = try std.fmt.allocPrint(sim_arena, "i({s})", .{name});
            n_probes += 1;
        }
    }
    for (1..prepared.circuit.n) |i| {
        const label = prepared.circuit.nodeName(@intCast(i));
        if (label.len != 0) {
            probe_buf[n_probes] = @intCast(i);
            label_buf[n_probes] = try std.fmt.allocPrint(sim_arena, "v({s})", .{label});
            n_probes += 1;
        }
    }
    prepared.probes = probe_buf[0..n_probes];
    prepared.probe_labels = label_buf[0..n_probes];

    prepared.deck_tol = deck_opts.tol;
    prepared.deck_temp = deck_opts.temp_c;
    prepared.deck_method = deck_opts.method;
    prepared.queries = try queriesFromDirectives(sim_arena, nl.directives, dir_nodes, dir_nodes_neg, dir_ports, prepared.bindings, cards, deck_opts);

    return prepared;
}

fn copyNames(arena: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copied = try arena.alloc([]const u8, names.len);
    for (names, copied) |name, *copy| copy.* = try arena.dupe(u8, name);
    return copied;
}

fn queriesFromDirectives(arena: std.mem.Allocator, directives: []const types.Directive, dir_nodes: []const u32, dir_nodes_neg: []const u32, dir_ports: []const [4]u32, sources: problem.QueryBindings, cards: []const requests.CardRef, deck_opts: DeckOptions) ![]const Job {
    // Fan-out ceiling: `.disto` is the widest card at three plots per line.
    const jobs = try arena.alloc(Job, directives.len * 3);
    var n_jobs: u32 = 0;
    for (directives, dir_nodes, dir_nodes_neg, dir_ports) |dir, node_id, node_neg, ports| {
        if (try buildJob(dir, node_id, node_neg, ports, sources, cards)) |job0| {
            var job = job0;
            applyDeckOptions(&job, deck_opts);
            jobs[n_jobs] = job;
            n_jobs += 1;
            // The "Integrated Noise" plot always exists; a degenerate band
            // (`.noise ... dec 4 100 100`) integrates to zero and ngspice
            // still prints the row, which is what `noise/single_frequency`
            // pins.
            if (job == .noise) {
                job.noise.integrated = true;
                jobs[n_jobs] = job;
                n_jobs += 1;
            }
            // ngspice's `.disto` output product is the pair of complex
            // harmonic solution vectors; the summary digest above is ours.
            if (job == .disto) {
                inline for (.{ .second, .third }) |harmonic| {
                    job.disto.plot = harmonic;
                    jobs[n_jobs] = job;
                    n_jobs += 1;
                }
            }
        }
    }

    return jobs[0..n_jobs];
}

/// Resolve additional SPICE analysis cards against the published circuit.
/// Topology and deck settings are fixed; only query descriptions are allocated.
pub fn resolveQueries(arena: std.mem.Allocator, prepared: *const Prepared, directive_text: []const u8) ![]const Job {
    // The full parser consumes .end and uninstantiated subcircuits without
    // retaining them. Check physical card kinds first so none can be hidden.
    var lines = std.mem.splitScalar(u8, directive_text, '\n');
    var have_directive = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '*') continue;
        if (trimmed[0] == '+' and have_directive) continue;
        if (trimmed[0] != '.') return error.UnsupportedDirectiveMutation;
        const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const kind = trimmed[1..end];
        var lower: [16]u8 = undefined;
        if (kind.len > lower.len or requests.Keywords.get(std.ascii.lowerString(lower[0..kind.len], kind)) == null)
            return error.UnsupportedDirectiveMutation;
        have_directive = true;
    }
    if (!have_directive) return error.InvalidAnalysisArguments;
    const source = try std.fmt.allocPrint(arena, "appended queries\n{s}\n.end\n", .{directive_text});
    const ast = try syntax.Parser(syntax.ngspice).parse(arena, source);
    if (ast.devices.len != 0 or ast.subcircuits.len != 0 or ast.models.len != 0 or ast.params.len != 0 or ast.foreign.len != 0)
        return error.UnsupportedDirectiveMutation;
    const nl = try syntax.elaborate(arena, ast);
    if (nl.directives.len > (std.math.maxInt(u32) - 1) / 2) return error.CircuitTooLarge;
    const nodes = try arena.alloc(u32, nl.directives.len);
    // Appended queries currently accept only single-ended outputs below.
    const nodes_neg = try arena.alloc(u32, nl.directives.len);
    @memset(nodes_neg, NO_NODE);
    const ports = try arena.alloc([4]u32, nl.directives.len);
    for (nl.directives, ports) |dir, *port| {
        port.* = @splat(NO_NODE);
        if (!std.ascii.eqlIgnoreCase(dir.kind, "pz")) continue;
        for (port, 0..) |*id, i| {
            const name = bareNodeName(arena, dir, i) orelse continue;
            id.* = if (netlist.isGroundName(name)) GROUND else findNode(prepared, name);
        }
    }
    for (nl.directives, nodes) |dir, *node| {
        if (std.mem.eql(u8, dir.kind, "temp") and dir.args.len == 1) return error.UnsupportedDirectiveMutation;
        const arg: usize = if (std.mem.eql(u8, dir.kind, "four")) 1 else 0;
        if (arg < dir.args.len) switch (dir.args[arg]) {
            .group => |g| if (g.args.len != 1) return error.UnsupportedAnalysisOutput,
            else => {},
        };
        const name = directiveNodeName(dir, arg) orelse
            (if (arg < dir.args.len) icNodeName(arena, dir.args[arg]) else null);
        node.* = if (name) |wanted| findNode(prepared, wanted) else NO_NODE;
    }
    return queriesFromDirectives(arena, nl.directives, nodes, nodes_neg, ports, prepared.bindings, prepared.cards, .{
        .tol = prepared.deck_tol,
        .method = prepared.deck_method,
        .temp_c = prepared.deck_temp,
    });
}

/// Node row by label, for the appended-directive path: it runs after compile()
/// has taken the name table apart, so the intern table is the only index left.
fn findNode(prepared: *const Prepared, wanted: []const u8) u32 {
    for (0..prepared.circuit.n) |i| {
        if (std.mem.eql(u8, prepared.circuit.nodeName(@intCast(i)), wanted)) return @intCast(i);
    }
    return NO_NODE;
}

const NO_NODE: u32 = std.math.maxInt(u32);

/// A node NAME out of one directive argument. `2` tokenizes as a NUMBER while
/// `node_names` is keyed by the string the device cards used, so an integral
/// node has to be spelled back out before the lookup.
fn nodeNameOf(arena: std.mem.Allocator, value: types.Value) ?[]const u8 {
    return switch (value) {
        .name => |n| n,
        .num => |n| if (n == @trunc(n) and @abs(n) < 1e9)
            std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch null
        else
            null,
        else => null,
    };
}

/// `.pz` spells its four ports as bare arguments rather than `v(...)` groups.
fn bareNodeName(arena: std.mem.Allocator, dir: types.Directive, index: usize) ?[]const u8 {
    if (index >= dir.args.len) return null;
    return nodeNameOf(arena, dir.args[index]);
}

/// The node inside an `.ic v(<node>)=<value>` group.
fn icNodeName(arena: std.mem.Allocator, value: types.Value) ?[]const u8 {
    const g = switch (value) {
        .group => |g| g,
        else => return null,
    };
    if (!std.ascii.eqlIgnoreCase(g.name, "v") or g.args.len == 0) return null;
    return nodeNameOf(arena, g.args[0]);
}

/// Parsed `.options` overrides. One pass over the deck's directives; the
/// parser already splits `key=value` into adjacent name/value args.
const DeckOptions = struct {
    tol: numerics.Tolerances = .{},
    method: ?requests.Method = null,
    temp_c: ?f64 = null,
    /// `.options tnom=<degC>` — ngspice `cktsopt.c:71-73` stores it as
    /// `TSKnomTemp = val + CONSTCtoK`, so the CARD is Celsius; the default is
    /// `cktntask.c:127`'s 300.15 K = 27 degC. Independent of `.options temp`
    /// (`OPT_TEMP`, the same file's next case): nominal is where the model card
    /// was extracted, `temp` is where the circuit is being run.
    ///
    /// Not optional and not applied per job: unlike `temp`, this is not an
    /// analysis knob — it reaches the devices at BUILD time, before the
    /// pattern is frozen, so no sweep can move it and `recompute`'s
    /// topology-change path is never involved.
    tnom_c: f64 = 27.0,
};

fn parseDeckOptions(directives: []const types.Directive) !DeckOptions {
    const option_cards = std.StaticStringMap(void).initComptime(.{
        .{ "options", {} }, .{ "option", {} }, .{ "opt", {} }, .{ "opts", {} },
    });
    const Option = enum(u8) { method, reltol, abstol, vntol, gmin, trtol, chgtol, itl1, itl2, itl4, maxord, temp, tnom };
    const names = std.StaticStringMap(Option).initComptime(.{
        .{ "method", .method }, .{ "reltol", .reltol }, .{ "abstol", .abstol },
        .{ "vntol", .vntol },   .{ "gmin", .gmin },     .{ "trtol", .trtol },
        .{ "chgtol", .chgtol }, .{ "itl1", .itl1 },     .{ "itl2", .itl2 },
        .{ "itl4", .itl4 },     .{ "maxord", .maxord }, .{ "temp", .temp },
        .{ "tnom", .tnom },
    });
    const methods = std.StaticStringMap(requests.Method).initComptime(.{
        .{ "gear", .gear_2 }, .{ "trap", .trapezoidal }, .{ "trapezoidal", .trapezoidal },
    });
    var o: DeckOptions = .{};
    var maxord: ?f64 = null;
    for (directives) |dir| {
        if (std.ascii.eqlIgnoreCase(dir.kind, "temp") and dir.args.len == 1) {
            o.temp_c = try number(dir, 0);
            if (o.temp_c.? <= -273.15) return error.InvalidAnalysisArguments;
            continue;
        }
        var lower: [16]u8 = undefined;
        if (dir.kind.len > lower.len or !option_cards.has(std.ascii.lowerString(lower[0..dir.kind.len], dir.kind))) continue;
        var i: usize = 0;
        while (i < dir.args.len) : (i += 1) {
            const key = directiveName(dir, i) orelse continue;
            if (key.len > lower.len) continue;
            const option = names.get(std.ascii.lowerString(lower[0..key.len], key)) orelse continue;
            i += 1;
            if (option == .method) {
                const method = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
                if (method.len > lower.len) return error.InvalidAnalysisArguments;
                o.method = methods.get(std.ascii.lowerString(lower[0..method.len], method)) orelse return error.InvalidAnalysisArguments;
                continue;
            }
            const value = try number(dir, i);
            switch (option) {
                .method => unreachable,
                .temp, .tnom => {
                    if (value <= -273.15) return error.InvalidAnalysisArguments;
                    if (option == .temp) o.temp_c = value else o.tnom_c = value;
                },
                .itl1, .itl2, .itl4 => {
                    if (value < 1 or value != @trunc(value) or value > std.math.maxInt(u16)) return error.InvalidAnalysisArguments;
                    const iterations: u16 = @intFromFloat(value);
                    switch (option) {
                        .itl1 => o.tol.itl1 = iterations,
                        .itl2 => o.tol.itl2 = iterations,
                        .itl4 => o.tol.itl4 = iterations,
                        else => unreachable,
                    }
                },
                .maxord => {
                    if (value < 1 or value != @trunc(value)) return error.InvalidAnalysisArguments;
                    maxord = value;
                },
                inline else => |field| {
                    if (value < 0) return error.InvalidAnalysisArguments;
                    @field(o.tol, @tagName(field)) = value;
                },
            }
        }
    }
    if (o.method == .gear_2 and maxord != null and maxord.? < 2) o.method = .backward_euler;
    return o;
}

/// `uic` is a trailing KEYWORD, not a positional: `.tran 1n 100n uic` and
/// `.tran 1n 100n 0 1n uic` are both legal, so scan rather than index.
fn hasUic(dir: types.Directive) bool {
    for (dir.args) |a| switch (a) {
        .name => |n| if (std.ascii.eqlIgnoreCase(n, "uic")) return true,
        else => {},
    };
    return false;
}

fn applyDeckOptions(job: *Job, o: DeckOptions) void {
    switch (job.*) {
        inline else => |*opts| {
            if (comptime @hasField(@TypeOf(opts.*), "tol")) opts.tol = o.tol;
            if (comptime @hasField(@TypeOf(opts.*), "dc_options")) opts.dc_options.tol = o.tol;
        },
    }
    if (job.* == .temp) job.temp.t_nom = o.temp_c orelse 27;
    if (o.method) |m| switch (job.*) {
        .tran => |*t| t.method = m,
        else => {},
    };
}

fn number(dir: types.Directive, i: usize) !f64 {
    const n = directiveNumber(dir, i) orelse return error.InvalidAnalysisArguments;
    if (!std.math.isFinite(n)) return error.InvalidAnalysisArguments;
    return n;
}

fn positive(dir: types.Directive, i: usize) !f64 {
    const n = try number(dir, i);
    if (n <= 0) return error.InvalidAnalysisArguments;
    return n;
}

fn count(comptime T: type, dir: types.Directive, i: usize, default: T) !T {
    if (i >= dir.args.len) return default;
    const n = try positive(dir, i);
    if (n != @trunc(n) or n > std.math.maxInt(T)) return error.InvalidAnalysisArguments;
    return @intFromFloat(n);
}

fn arity(dir: types.Directive, min: usize, max: usize) !void {
    if (dir.args.len < min or dir.args.len > max) return error.InvalidAnalysisArguments;
}

/// One case-insensitive keyword argument, lowered into caller storage so the
/// `StaticStringMap` lookup that follows stays allocation-free.
fn keyword(dir: types.Directive, i: usize, buf: []u8) ![]const u8 {
    const name = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
    if (name.len > buf.len) return error.InvalidAnalysisArguments;
    return std.ascii.lowerString(buf[0..name.len], name);
}

fn outputNode(node: u32) !u32 {
    if (node == NO_NODE or node == GROUND) return error.AnalysisNodeNotFound;
    return node;
}

/// `i(name)` — a branch-current probe, as opposed to the `v(...)` groups
/// `dir_nodes` resolves. Returns the named card.
fn currentProbeName(dir: types.Directive, i: usize) ?[]const u8 {
    if (i >= dir.args.len) return null;
    return switch (dir.args[i]) {
        .group => |g| if (std.ascii.eqlIgnoreCase(g.name, "i") and g.args.len == 1)
            switch (g.args[0]) {
                .name => |n| n,
                else => null,
            }
        else
            null,
        else => null,
    };
}

/// `v(a,b)` second node. Absent (single-ended) resolves to GROUND, which is
/// what every consumer already means by "no reference node"; a name the deck
/// never defines is a typo, not a ground reference.
fn outputNeg(node: u32) !u32 {
    if (node == NO_NODE) return GROUND;
    return node;
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

fn voltageSource(dir: types.Directive, i: usize, sources: problem.QueryBindings) !usize {
    const name = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
    return findNameIndex(sources.v_names, name) orelse error.AnalysisSourceNotFound;
}

/// `.dc <card|TEMP> start stop step`. The card table is the same one the AC
/// overrides and `.sens` resolve through, so the swept quantity is named by
/// (device type, instance index, parameter) — which is what `ParamRef` is
/// keyed on. A batch-local index alone could not tell `V1` from `I1`.
fn dcTarget(dir: types.Directive, i: usize, cards: []const requests.CardRef) !requests.Dc.SweepTarget {
    const name = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
    if (std.ascii.eqlIgnoreCase(name, "temp")) return .{ .is_temp = true };
    for (cards) |c| {
        if (!std.ascii.eqlIgnoreCase(c.name, name)) continue;
        // ngspice sweeps a card's PRIMARY value: `dc` on a source, the
        // element value on a passive.
        const param = std.StaticStringMap([]const u8).initComptime(.{
            .{ "resistor", "r" }, .{ "capacitor", "c" }, .{ "inductor", "l" },
        }).get(c.type_name) orelse "dc";
        return .{ .type_name = c.type_name, .index = c.index, .param_name = param };
    }
    return error.AnalysisSourceNotFound;
}

fn checkStep(start: f64, stop: f64, step: f64) !void {
    const intervals = (stop - start) / step;
    if (step == 0 or !std.math.isFinite(intervals) or intervals < 0 or
        intervals >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidAnalysisArguments;
}

/// `dec|oct|lin N fstart fstop` — the one grid every frequency-domain
/// directive spells the same way. `lin` is the only kind that admits
/// fstart = 0 (a geometric grid has no zeroth point to step from).
fn frequencySweep(dir: types.Directive, offset: usize) !numerics.FreqSweep {
    const mode = directiveName(dir, offset) orelse return error.InvalidAnalysisArguments;
    const kinds = std.StaticStringMap(numerics.SweepKind).initComptime(.{
        .{ "dec", .dec }, .{ "oct", .oct }, .{ "lin", .lin },
    });
    var lower: [8]u8 = undefined;
    if (mode.len > lower.len) return error.UnsupportedFrequencySweep;
    const kind = kinds.get(std.ascii.lowerString(lower[0..mode.len], mode)) orelse return error.UnsupportedFrequencySweep;
    const first = if (kind == .lin) try number(dir, offset + 2) else try positive(dir, offset + 2);
    const last = try positive(dir, offset + 3);
    if (first < 0 or last < first) return error.InvalidAnalysisArguments;
    return .{ .f_start = first, .f_stop = last, .points = try count(u32, dir, offset + 1, 10), .kind = kind };
}

fn buildJob(dir: types.Directive, node_id: u32, node_neg: u32, ports: [4]u32, sources: problem.QueryBindings, cards: []const requests.CardRef) !?Job {
    const id = requests.Keywords.get(dir.kind) orelse return null;
    switch (id) {
        .op => {
            try arity(dir, 0, 0);
            return .{ .op = .{} };
        },
        .tran, .tran_noise, .matex => {
            try arity(dir, 2, if (id == .tran) 5 else 2);
            const step = try positive(dir, 0);
            const stop = try positive(dir, 1);
            if (id == .matex) return .{ .matex = .{ .t_stop = stop, .h_output_cap = step } };
            if (id == .tran_noise) return .{ .tran_noise = .{ .t_stop = stop, .dt_init = step, .dt_max = step } };
            var numeric_end = dir.args.len;
            const uic = hasUic(dir);
            if (uic) numeric_end -= 1;
            if (numeric_end > 4) return error.InvalidAnalysisArguments;
            // ngspice tstart: suppresses OUTPUT before it, never the solve.
            const t_start = if (numeric_end > 2) try number(dir, 2) else 0;
            if (!(t_start >= 0) or t_start >= stop) return error.InvalidAnalysisArguments;
            return .{ .tran = .{ .t_stop = stop, .dt_init = step, .t_start = t_start, .dt_max = if (numeric_end > 3) try positive(dir, 3) else @min(step, stop / 50), .uic = uic } };
        },
        .ac, .disto => {
            try arity(dir, 4, 4);
            const grid = try frequencySweep(dir, 0);
            if (id == .ac) return .{ .ac = .{ .sweep = grid } };
            var opts: requests.Disto = .{ .sweep = grid };
            // ngspice cktdisto.c:100-117: the F1 drive is whichever card
            // carries DISTOF1 — never "the first source" — and it lands on
            // that card's BRANCH row. `disto/bjt_ce` is the proof: its first V
            // card is the supply Vcc and the DISTOF1 is on Vin.
            // ponytail: first such card only. ngspice sums every DISTOF1
            // source into one RHS; no fixture has two, and the loop is the
            // upgrade when one does.
            for (sources.v_branches, sources.v_distof1) |br, d| {
                if (d[0] == 0) continue;
                opts.drive_branch = br;
                opts.ac_magnitude = d[0];
                opts.ac_phase = d[1];
                break;
            }
            return .{ .disto = opts };
        },
        .dc => {
            if (dir.args.len != 4 and dir.args.len != 8) return error.InvalidAnalysisArguments;
            var opts: requests.Dc = .{ .target = try dcTarget(dir, 0, cards), .start = try number(dir, 1), .stop = try number(dir, 2), .step = try number(dir, 3) };
            // Only the OUTER variable may be the temperature: the inner march
            // installs its value through one ParamRef write, and temperature
            // is a whole-circuit set plus a re-derive.
            if (opts.target.is_temp) return error.UnsupportedTemperatureSweep;
            try checkStep(opts.start, opts.stop, opts.step);
            if (dir.args.len == 8) {
                opts.target2 = try dcTarget(dir, 4, cards);
                opts.start2 = try number(dir, 5);
                opts.stop2 = try number(dir, 6);
                opts.step2 = try number(dir, 7);
                try checkStep(opts.start2, opts.stop2, opts.step2);
            }
            return .{ .dc = opts };
        },
        .noise => {
            // The input reference source does not drive the noise solve, but
            // it still has to EXIST: accepting a name no card carries turned
            // `.noise v(out) Missing ...` into a silent success.
            try arity(dir, 5, 6);
            const in_branch: ?u32 = if (dir.args.len == 6)
                sources.v_branches[try voltageSource(dir, 1, sources)]
            else
                null;
            return .{ .noise = .{ .out_node = try outputNode(node_id), .out_neg = try outputNeg(node_neg), .in_branch = in_branch, .sweep = try frequencySweep(dir, dir.args.len - 4) } };
        },
        .pnoise => {
            try arity(dir, 7, 8);
            const sweep = try frequencySweep(dir, 2);
            const sidebands = if (dir.args.len == 8) try number(dir, 7) else 7;
            if (sidebands < 0 or sidebands != @trunc(sidebands) or sidebands > 31) return error.InvalidAnalysisArguments;
            return .{ .pnoise = .{ .out_node = try outputNode(node_id), .sweep = sweep, .f_fundamental = try positive(dir, 6), .n_sidebands = @intFromFloat(sidebands) } };
        },
        .tf => {
            try arity(dir, 2, 2);
            var opts: requests.Tf = .{};
            // `.tf i(Vmeasure) ...` measures a BRANCH current. `dir_nodes`
            // only resolves `v(...)`, so the `i(...)` spelling is read here.
            if (currentProbeName(dir, 0)) |probe| {
                opts.output_branch = sources.v_branches[findNameIndex(sources.v_names, probe) orelse return error.AnalysisSourceNotFound];
            } else {
                opts.output_node = try outputNode(node_id);
                opts.output_neg = try outputNeg(node_neg);
            }
            // The drive is a V card (branch row) or an I card (node pair).
            const drive = directiveName(dir, 1) orelse return error.InvalidAnalysisArguments;
            if (findNameIndex(sources.v_names, drive)) |v| {
                opts.input_branch = sources.v_branches[v];
            } else if (findNameIndex(sources.i_names, drive)) |i_idx| {
                opts.input_nodes = .{ sources.i_pos[i_idx], sources.i_neg[i_idx] };
            } else return error.AnalysisSourceNotFound;
            return .{ .tf = opts };
        },
        .sens, .dcmatch => {
            try arity(dir, 1, 1);
            const node = try outputNode(node_id);
            if (id == .sens) return .{ .sens = .{ .output_node = node, .output_neg = try outputNeg(node_neg), .cards = cards } };
            return .{ .dcmatch = .{ .output_node = node } };
        },
        .four => {
            try arity(dir, 2, 3);
            return .{ .four = .{ .f_fundamental = try positive(dir, 0), .output_node = try outputNode(node_id), .n_harmonics = try count(u16, dir, 2, 9) } };
        },
        .pz => {
            // Bare `.pz` asks for the circuit's own poles and names no transfer.
            if (dir.args.len == 0) return .{ .pz = .{} };
            try arity(dir, 6, 6);
            const drive_kind = std.StaticStringMap(enum { vol, cur })
                .initComptime(.{ .{ "vol", .vol }, .{ "cur", .cur } });
            const wanted = std.StaticStringMap(enum { pol, zer, pz })
                .initComptime(.{ .{ "pol", .pol }, .{ "zer", .zer }, .{ "pz", .pz } });
            var lower: [4]u8 = undefined;
            const kind = drive_kind.get(try keyword(dir, 4, &lower)) orelse return error.InvalidAnalysisArguments;
            const want = wanted.get(try keyword(dir, 5, &lower)) orelse return error.InvalidAnalysisArguments;
            var opts: requests.Pz = .{
                .in_pos = try outputNode(ports[0]),
                .in_neg = try outputNeg(ports[1]),
                .out_pos = try outputNode(ports[2]),
                .out_neg = try outputNeg(ports[3]),
                .want_poles = want != .zer,
                .want_zeros = want != .pol,
            };
            // A `vol` transfer is driven by a voltage source, and the source
            // the deck already put across the input port IS that drive: its
            // branch row is the column the numerator's Cramer rule needs, and
            // its presence in the nulled matrix is the short the denominator
            // needs. Adding a second one across the same pair would be two
            // contradictory constraints on one node pair, which is the trap
            // `.stb` fell into. `cur` needs no card: a current injection is
            // just the node pair, which is why `bench_pz_simplepz` can ask for
            // a transimpedance with no source in the deck at all.
            if (kind == .vol) {
                opts.drive_branch = for (sources.v_pos, sources.v_neg, sources.v_branches) |p, m, br| {
                    if ((p == opts.in_pos and m == opts.in_neg) or (p == opts.in_neg and m == opts.in_pos)) break br;
                } else return error.AnalysisSourceNotFound;
            }
            return .{ .pz = opts };
        },
        .pss => {
            try arity(dir, 1, 2);
            return .{ .pss = .{ .period = 1 / try positive(dir, 0), .n_samples = try count(u32, dir, 1, 256) } };
        },
        .hb => {
            try arity(dir, 1, 2);
            if (sources.v_names.len == 0) return error.AnalysisSourceNotFound;
            return .{ .hb = .{ .f0 = try positive(dir, 0), .n_harmonics = try count(u16, dir, 1, 8) } };
        },
        .qpss => {
            try arity(dir, 2, 4);
            if (sources.v_names.len == 0) return error.AnalysisSourceNotFound;
            return .{ .qpss = .{ .f1 = try positive(dir, 0), .f2 = try positive(dir, 1), .k1 = try count(u16, dir, 2, 5), .k2 = try count(u16, dir, 3, 5) } };
        },
        .pac, .pxf => {
            try arity(dir, 5, 5);
            const sweep = try frequencySweep(dir, 1);
            const lo = try positive(dir, 0);
            if (id == .pac) return .{ .pac = .{ .f_lo = lo, .sweep = sweep } };
            return .{ .pxf = .{ .f_lo = lo, .sweep = sweep } };
        },
        .sp => {
            try arity(dir, 4, 4);
            return .{ .sp = .{ .sweep = try frequencySweep(dir, 0), .ports = sources.ports } };
        },
        .stb => {
            // `.stb Vprobe dec N fstart fstop` — the named 0 V source IS the
            // loop break; the sweep drives its branch row directly.
            try arity(dir, 5, 5);
            const probe = try voltageSource(dir, 0, sources);
            return .{ .stb = .{
                .sweep = try frequencySweep(dir, 1),
                .probe_p = sources.v_pos[probe],
                .probe_n = sources.v_neg[probe],
                .probe_branch = sources.v_branches[probe],
            } };
        },
        .envelope => {
            try arity(dir, 2, 2);
            return .{ .envelope = .{ .t_carrier = try positive(dir, 0), .t_stop = try positive(dir, 1) } };
        },
        .mc => {
            try arity(dir, 1, 2);
            var opts: requests.Mc = .{ .n_trials = try count(u16, dir, 0, 100) };
            if (dir.args.len == 2) opts.variation = try number(dir, 1);
            if (opts.variation < 0) return error.InvalidAnalysisArguments;
            return .{ .mc = opts };
        },
        .temp => {
            // Standard single-temperature card is deck configuration.
            if (dir.args.len == 1) {
                if (try number(dir, 0) <= -273.15) return error.InvalidAnalysisArguments;
                return null;
            }
            try arity(dir, 3, 3);
            const opts: requests.Temp = .{ .t_start = try number(dir, 0), .t_stop = try number(dir, 1), .t_step = try number(dir, 2) };
            try checkStep(opts.t_start, opts.t_stop, opts.t_step);
            if (opts.t_step <= 0 or (opts.t_stop - opts.t_start) / opts.t_step >= std.math.maxInt(u32) or
                @min(opts.t_start, opts.t_stop) <= -273.15) return error.InvalidAnalysisArguments;
            return .{ .temp = opts };
        },
    }
}

// Private implementation access for the frontend test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .DeckOptions = DeckOptions,
    .parseDeckOptions = parseDeckOptions,
    .buildJob = buildJob,
    .applyDeckOptions = applyDeckOptions,
} else {};
