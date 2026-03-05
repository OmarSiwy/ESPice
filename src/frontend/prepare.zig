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

const Sources = struct {
    v_names: []const []const u8,
    i_names: []const []const u8,
    v_branches: []const u32,
    /// `{mag, phase deg}` of each V card's `DISTOF1`; `{0, _}` = absent.
    /// `.disto` picks its drive by this, never by card order.
    v_distof1: []const [2]f64,
    /// `.sp` ports declared by `portnum`/`z0` on V cards, in port order.
    /// Empty = no port card, which leaves `.sp` on its one-port fallback.
    ports: []const requests.Port = &.{},
    /// (device type, ordinal) -> card name, for `.sens` column naming.
    cards: []const requests.CardRef = &.{},
};

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
    // Resolve the output node before compile() destroys the name table.
    const dir_nodes = try parse_arena.alloc(u32, nl.directives.len);
    for (nl.directives, dir_nodes) |dir, *id| {
        const arg: usize = if (std.ascii.eqlIgnoreCase(dir.kind, "four")) 1 else 0;
        if (requests.Keywords.get(dir.kind) != null and arg < dir.args.len) switch (dir.args[arg]) {
            .group => |g| if (g.args.len != 1) return error.UnsupportedAnalysisOutput,
            else => {},
        };
        const name = directiveNodeName(dir, arg) orelse
            (if (arg < dir.args.len) icNodeName(parse_arena, dir.args[arg]) else null);
        id.* = if (name) |n| b.node_names.get(n) orelse NO_NODE else NO_NODE;
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
    // `v_ports` is build-time scratch everywhere EXCEPT portList, which
    // runs below and hands the row straight to the .sp solve.
    for (nb.v_ports[0..nb.n_v]) |*v| v.* = mapNode(perm, v.*);
    for (nb.br_rows[0..nb.n_br]) |*v| v.* = mapNode(perm, v.*);
    for (nb.l_branches[0..nb.n_l]) |*v| v.* = mapNode(perm, v.*);
    for (nb.ac_pos[0..nb.n_ac]) |*v| v.* = mapNode(perm, v.*);
    for (nb.ac_neg[0..nb.n_ac]) |*v| v.* = mapNode(perm, v.*);
    nb.source_node = mapNode(perm, nb.source_node);
    nb.source_branch = mapNode(perm, nb.source_branch);
    for (dir_nodes) |*v| {
        if (v.* != NO_NODE) v.* = mapNode(perm, v.*);
    }
    for (ic_buf[0..n_ic_used]) |*e| e.node = mapNode(perm, e.node);
    // Escapes into run-time lifetime: title read at output time, counts in
    // the summary. Dupe/copy off the parse arena so it can be reset now.
    prepared.title = try sim_arena.dupe(u8, nl.title);
    prepared.n_devices = @intCast(nl.devices.len());
    prepared.n_directives = @intCast(nl.directives.len);

    prepared.source_node = nb.source_node;
    prepared.source_branch = nb.source_branch;
    // Every `AC`-carrying source collapsed into ONE excitation vector, in
    // post-permutation coordinates. Built here rather than per analysis
    // because it is deck data, not analysis data.
    prepared.ac_drive = try nb.acExcitation(sim_arena, prepared.circuit.n);

    // Sources are parse-arena scratch; resolved into job indices below and
    // never stored on `prepared`.
    const sources: Sources = .{
        .v_names = nb.v_names[0..nb.n_v],
        .i_names = nb.i_names[0..nb.n_i],
        .v_branches = nb.v_branches[0..nb.n_v],
        .v_distof1 = nb.v_distof1[0..nb.n_v],
        // Ports outlive `sources` — `.sp` Options holds the slice — so it
        // lands on the prepared arena, not the parse arena.
        .ports = try nb.portList(sim_arena),
        .cards = cards,
    };

    prepared.cards = cards;
    prepared.bindings = .{
        .v_names = try copyNames(sim_arena, sources.v_names),
        .i_names = try copyNames(sim_arena, sources.i_names),
        .v_branches = try sim_arena.dupe(u32, sources.v_branches),
        .v_distof1 = try sim_arena.dupe([2]f64, sources.v_distof1),
        .ports = sources.ports,
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
    prepared.queries = try queriesFromDirectives(sim_arena, nl.directives, dir_nodes, sources, deck_opts);

    return prepared;
}

fn copyNames(arena: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copied = try arena.alloc([]const u8, names.len);
    for (names, copied) |name, *copy| copy.* = try arena.dupe(u8, name);
    return copied;
}

fn queriesFromDirectives(arena: std.mem.Allocator, directives: []const types.Directive, dir_nodes: []const u32, sources: Sources, deck_opts: DeckOptions) ![]const Job {
    const jobs = try arena.alloc(Job, directives.len * 2);
    var n_jobs: u32 = 0;
    for (directives, dir_nodes) |dir, node_id| {
        if (try buildJob(dir, node_id, sources)) |job0| {
            var job = job0;
            applyDeckOptions(&job, deck_opts);
            jobs[n_jobs] = job;
            n_jobs += 1;
            // noisean.c:495 — no "Integrated Noise" plot for a degenerate
            // band, because there is nothing to integrate over.
            if (job == .noise and job.noise.f_start != job.noise.f_stop) {
                job.noise.integrated = true;
                jobs[n_jobs] = job;
                n_jobs += 1;
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
    for (nl.directives, nodes) |dir, *node| {
        if (std.mem.eql(u8, dir.kind, "temp") and dir.args.len == 1) return error.UnsupportedDirectiveMutation;
        const arg: usize = if (std.mem.eql(u8, dir.kind, "four")) 1 else 0;
        if (arg < dir.args.len) switch (dir.args[arg]) {
            .group => |g| if (g.args.len != 1) return error.UnsupportedAnalysisOutput,
            else => {},
        };
        const name = directiveNodeName(dir, arg) orelse
            (if (arg < dir.args.len) icNodeName(arena, dir.args[arg]) else null);
        node.* = NO_NODE;
        if (name) |wanted| {
            for (0..prepared.circuit.n) |i| {
                if (std.mem.eql(u8, prepared.circuit.nodeName(@intCast(i)), wanted)) {
                    node.* = @intCast(i);
                    break;
                }
            }
        }
    }
    const bindings = prepared.bindings;
    return queriesFromDirectives(arena, nl.directives, nodes, .{
        .v_names = bindings.v_names,
        .i_names = bindings.i_names,
        .v_branches = bindings.v_branches,
        .v_distof1 = bindings.v_distof1,
        .ports = bindings.ports,
        .cards = prepared.cards,
    }, .{ .tol = prepared.deck_tol, .method = prepared.deck_method, .temp_c = prepared.deck_temp });
}

const NO_NODE: u32 = std.math.maxInt(u32);

/// The node inside an `.ic v(<node>)=<value>` group. `v(2)` tokenizes the node
/// as a NUMBER while `node_names` is keyed by the string the device cards used,
/// so an integral node has to be spelled back out before the lookup.
fn icNodeName(arena: std.mem.Allocator, value: types.Value) ?[]const u8 {
    const g = switch (value) {
        .group => |g| g,
        else => return null,
    };
    if (!std.ascii.eqlIgnoreCase(g.name, "v") or g.args.len == 0) return null;
    return switch (g.args[0]) {
        .name => |n| n,
        .num => |n| if (n == @trunc(n) and @abs(n) < 1e9)
            std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch null
        else
            null,
        else => null,
    };
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

fn outputNode(node: u32) !u32 {
    if (node == NO_NODE or node == GROUND) return error.AnalysisNodeNotFound;
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

fn voltageSource(dir: types.Directive, i: usize, sources: Sources) !usize {
    const name = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
    return findNameIndex(sources.v_names, name) orelse error.AnalysisSourceNotFound;
}

fn dcSource(dir: types.Directive, i: usize, sources: Sources) !u32 {
    const name = directiveName(dir, i) orelse return error.InvalidAnalysisArguments;
    if (findNameIndex(sources.v_names, name)) |index| return @intCast(index);
    if (findNameIndex(sources.i_names, name)) |index| {
        // ponytail: DC Options has only a batch-local index; add source kind
        // before permitting mixed V/I decks, where indices otherwise alias.
        if (sources.v_names.len != 0) return error.UnsupportedMixedCurrentSweep;
        return @intCast(index);
    }
    return error.AnalysisSourceNotFound;
}

fn checkStep(start: f64, stop: f64, step: f64) !void {
    const intervals = (stop - start) / step;
    if (step == 0 or !std.math.isFinite(intervals) or intervals < 0 or
        intervals >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidAnalysisArguments;
}

/// Only DEC is supported by the shared frequency sweep. Reject LIN/OCT
/// instead of silently executing a different frequency grid.
fn frequencyOptions(comptime T: type, dir: types.Directive, offset: usize) !T {
    const mode = directiveName(dir, offset) orelse return error.InvalidAnalysisArguments;
    if (!std.ascii.eqlIgnoreCase(mode, "dec")) return error.UnsupportedFrequencySweep;
    const first = try positive(dir, offset + 2);
    const last = try positive(dir, offset + 3);
    if (last < first) return error.InvalidAnalysisArguments;
    return .{ .f_start = first, .f_stop = last, .points_per_decade = try count(u16, dir, offset + 1, 10) };
}

fn buildJob(dir: types.Directive, node_id: u32, sources: Sources) !?Job {
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
            // Output suppression is not implemented: never silently ignore it.
            if (numeric_end > 2 and try number(dir, 2) != 0) return error.UnsupportedTransientStart;
            return .{ .tran = .{ .t_stop = stop, .dt_init = step, .dt_max = if (numeric_end > 3) try positive(dir, 3) else @min(step, stop / 50), .uic = uic } };
        },
        .ac, .disto => {
            try arity(dir, 4, 4);
            if (id == .ac) return .{ .ac = try frequencyOptions(requests.Ac, dir, 0) };
            var opts = try frequencyOptions(requests.Disto, dir, 0);
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
            var opts: requests.Dc = .{ .source_index = try dcSource(dir, 0, sources), .start = try number(dir, 1), .stop = try number(dir, 2), .step = try number(dir, 3) };
            try checkStep(opts.start, opts.stop, opts.step);
            if (dir.args.len == 8) {
                const name = directiveName(dir, 4) orelse return error.InvalidAnalysisArguments;
                if (std.ascii.eqlIgnoreCase(name, "temp")) opts.source2_is_temp = true else opts.source2_index = try dcSource(dir, 4, sources);
                opts.start2 = try number(dir, 5);
                opts.stop2 = try number(dir, 6);
                opts.step2 = try number(dir, 7);
                try checkStep(opts.start2, opts.stop2, opts.step2);
            }
            return .{ .dc = opts };
        },
        .noise => {
            // A legacy source token is accepted as syntax only; noise has no drive.
            try arity(dir, 5, 6);
            const sweep = try frequencyOptions(requests.Ac, dir, dir.args.len - 4);
            return .{ .noise = .{ .out_node = try outputNode(node_id), .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade } };
        },
        .pnoise => {
            try arity(dir, 7, 8);
            const sweep = try frequencyOptions(requests.Ac, dir, 2);
            const sidebands = if (dir.args.len == 8) try number(dir, 7) else 7;
            if (sidebands < 0 or sidebands != @trunc(sidebands) or sidebands > 31) return error.InvalidAnalysisArguments;
            return .{ .pnoise = .{ .out_node = try outputNode(node_id), .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade, .f_fundamental = try positive(dir, 6), .n_sidebands = @intFromFloat(sidebands) } };
        },
        .tf => {
            try arity(dir, 2, 2);
            return .{ .tf = .{ .output_node = try outputNode(node_id), .input_branch = sources.v_branches[try voltageSource(dir, 1, sources)] } };
        },
        .sens, .dcmatch => {
            try arity(dir, 1, 1);
            const node = try outputNode(node_id);
            if (id == .sens) return .{ .sens = .{ .output_node = node, .cards = sources.cards } };
            return .{ .dcmatch = .{ .output_node = node } };
        },
        .four => {
            try arity(dir, 2, 3);
            return .{ .four = .{ .f_fundamental = try positive(dir, 0), .output_node = try outputNode(node_id), .n_harmonics = try count(u16, dir, 2, 9) } };
        },
        .pz => {
            // The eigenvalue module computes poles, not transfer zeros.
            if (dir.args.len != 0) return error.UnsupportedPoleZeroArguments;
            return .{ .pz = .{} };
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
            const sweep = try frequencyOptions(requests.Ac, dir, 1);
            const lo = try positive(dir, 0);
            if (id == .pac) return .{ .pac = .{ .f_lo = lo, .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade } };
            return .{ .pxf = .{ .f_lo = lo, .f_start = sweep.f_start, .f_stop = sweep.f_stop, .points_per_decade = sweep.points_per_decade } };
        },
        .sp => {
            try arity(dir, 4, 4);
            const mode = directiveName(dir, 0) orelse return error.InvalidAnalysisArguments;
            const first = try positive(dir, 2);
            const last = try positive(dir, 3);
            if (last < first) return error.InvalidAnalysisArguments;
            const n = try count(u16, dir, 1, 50);
            const sweep = std.StaticStringMap(requests.SweepType).initComptime(.{ .{ "dec", .log }, .{ "lin", .linear } }).get(mode) orelse return error.UnsupportedFrequencySweep;
            const npoints = if (sweep == .log) numerics.logSweepCount(first, last, n) else n;
            if (npoints > std.math.maxInt(u16)) return error.InvalidAnalysisArguments;
            return .{ .sp = .{ .f_start = first, .f_stop = last, .n_points = @intCast(npoints), .sweep_type = sweep, .ports = sources.ports } };
        },
        .stb => return error.UnsupportedStabilityAnalysis,
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
    .Sources = Sources,
    .DeckOptions = DeckOptions,
    .parseDeckOptions = parseDeckOptions,
    .buildJob = buildJob,
    .applyDeckOptions = applyDeckOptions,
} else {};
