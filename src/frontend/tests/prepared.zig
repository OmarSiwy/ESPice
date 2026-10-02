const std = @import("std");
const input = @import("../prepare.zig");
const analyses = @import("../analyses.zig");
const netlist = @import("netlist");
const core = @import("core");
const requests = @import("core").query;
const Job = requests.Query;
const NO_NODE = analyses.NO_NODE;
const device = @import("device");

/// Built-ins only: their vtables are static, so the Library may die first.
fn build(sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: netlist.Netlist) !input.Prepared {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    return input.build(&lib, sim_arena, parse_arena, nl);
}

/// Every batch's parameters, stamped with the batch's type as analysis does.
fn collectTyped(circuit: *const device.Circuit, gpa: std.mem.Allocator, refs: *std.ArrayList(device.abi.ParamRef)) !void {
    for (circuit.batches, circuit.batch_types) |batch, t| {
        const first = refs.items.len;
        try batch.hooks.collect_params(batch.ctx, gpa, refs).unwrap();
        for (refs.items[first..]) |*ref| ref.type = t;
    }
}

fn prepare(io: std.Io, session: std.mem.Allocator, source: input.Source, dialect: input.Dialect) !netlist.Netlist {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    return input.prepare(io, &lib, session, source, dialect);
}
const resolveQueries = input.resolveQueries;

fn parse(arena: std.mem.Allocator, src: []const u8) !netlist.Netlist {
    return netlist.parse(arena, src, .ngspice);
}

/// The only card of `src`, with output node row 1 and no reference.
fn card(arena: std.mem.Allocator, src: []const u8) !netlist.Analysis {
    const nl = try parse(arena, try std.fmt.allocPrint(arena, "dispatch\n{s}\n.end\n", .{src}));
    var a = nl.deck.analyses[0];
    a.pos = 1;
    a.neg = NO_NODE;
    a.ports = @splat(NO_NODE);
    return a;
}

test "analysis directives dispatch every implemented capability and reject malformed requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources: core.QueryBindings = .{ .v_names = &.{"vin"}, .i_names = &.{}, .v_branches = &.{2}, .v_pos = &.{1}, .v_neg = &.{0}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{.{ 0, 0 }}, .ports = &.{.{ .node = 1, .branch = 2 }} };
    const cards: []const requests.CardRef = &.{.{ .type = device.Library.builtin("vsource"), .index = 0, .name = "vin" }};
    // `.fft` reads the deck's `.tran`, `.acmatch` its `.ac`.
    const ctx: analyses.CardContext = .{ .arena = a, .tran = .{ .t_stop = 10e-6, .dt_init = 1e-6 }, .ac = .{ .f_start = 10, .f_stop = 100 } };
    const directives = [_][]const u8{
        ".ac dec 2 10 100",                     ".dc vin 0 1 0.1",       ".dcmatch v(out)",
        ".disto dec 2 10 100",                  ".envelope 1m 5m",       ".four 1k v(out)",
        ".hb 1k",                               ".matex 1u 10u",         ".mc 4",
        ".noise v(out) vin dec 2 10 100",       ".op",                   ".pac 1k dec 2 10 100",
        ".pnoise v(out) vin dec 2 10 100 1k 0", ".pss 1k 128",           ".pxf 1k dec 2 10 100",
        ".pz",                                  ".qpss 1k 1414 1 1",     ".sens v(out)",
        ".sp dec 2 10 100",                     ".stb vin dec 2 10 100", ".temp -40 125 55",
        ".tf v(out) vin",                       ".tran 1u 10u",          ".tran_noise 1u 10u",
        ".hbac dec 2 10 100 1k",                ".hbnoise v(out) vin dec 2 10 100 1k 4 2",
        ".hbxf v(out) dec 2 10 100 1k",         ".phasenoise v(out) dec 2 10 100 1meg",
        ".lstb mode=single vsource=vin dec 2 10 100", ".acxf v(out) dec 2 10 100",
        ".dcxf v(out) tf",                      ".dcinc",
        ".fft v(out)",                          ".acmatch v(out)",      ".dcsens v(out)",
        ".hblin dec 2 10 100",
    };
    try std.testing.expectEqual(std.meta.fields(requests.Kind).len, directives.len);
    inline for (directives, std.meta.fields(requests.Kind)) |directive, field| {
        const id = @field(requests.Kind, field.name);
        const job = (try analyses.buildJob(try card(a, directive), sources, cards, ctx)).?;
        try std.testing.expectEqual(id, std.meta.activeTag(job));
        if (job == .pss) try std.testing.expectEqual(@as(f64, 1e-3), job.pss.period);
    }
    const malformed = [_][]const u8{
        ".ac dec 0 1 10",                ".ac dec -1 1 10",     ".ac dec 2.5 1 10",                      ".ac dec 2 10 1",
        ".ac lin 2 -1 10",               ".dc missing 0 1 0.1", ".dc vin 0 1 0",                         ".dc vin 0 1 -1",
        ".dc vin 0 1 1 missing 0 1 1",   ".tran 0 1u",          ".tran 1u 2u 2u",                        ".pss 0",
        ".pss 1k 2m v(out) 128 4 50 1m", ".mc 65536",           ".pnoise v(out) vin dec 2 10 100 1k -1", ".pz in 0 out 0 vol pz",
        ".tf v(out) missing",            ".temp -300 125 55",
        ".lstb mode=diff vsource=vin",   ".lstb mode=single vsource=vin,vin",   ".lstb mode=sideways vsource=vin",
        ".dcxf v(out) zin",              ".acxf v(out) dec 2 10 100 tf extra",
    };
    for (malformed) |directive| {
        if (analyses.buildJob(try card(a, directive), sources, cards, ctx)) |_| {
            std.debug.print("accepted: {s}\n", .{directive});
            return error.AcceptedInvalidAnalysis;
        } else |_| {}
    }
    // `.lstb` without its own sweep takes the deck's `.ac` grid, and needs one.
    const bare = try card(a, ".lstb mode=single vsource=vin");
    try std.testing.expectEqual(@as(f64, 100), (try analyses.buildJob(bare, sources, cards, ctx)).?.lstb.sweep.f_stop);
    try std.testing.expectError(error.MissingAnalysisCard, analyses.buildJob(bare, sources, cards, .{ .arena = a }));
    // HB and QPSS drive from whatever sources the deck stamps, current ones
    // included, so a deck without a V card is valid.
    const no_v: core.QueryBindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} };
    for ([_][]const u8{ ".hb 1k", ".qpss 1k 1414 1 1" }) |directive| _ = try analyses.buildJob(try card(a, directive), no_v, cards, ctx);
    // A single `.temp` is deck configuration, not a query.
    try std.testing.expectEqual(null, try analyses.buildJob(try card(a, ".temp 50"), sources, cards, ctx));
}

test "deck temperature and tolerances reach statistical and noise jobs" {
    // `.temp` reaches noise through the devices (Circuit.setCircuitTemp ->
    // Model.temperature__ -> the model's own `noisePsd`), not through an
    // analysis-card copy: ngspice's NevalSrc multiplies by `ckt->CKTtemp`
    // (nevalsrc.c:111) because its devices hand over a bare conductance,
    // and ours hand over a finished density.
    const options: analyses.DeckOptions = .{ .temp_c = 85, .tol = .{ .reltol = 1e-5 } };
    var temp_job: Job = .{ .temp = .{} };
    analyses.applyDeckOptions(&temp_job, options);
    try std.testing.expectEqual(@as(f64, 85), temp_job.temp.t_nom);
    try std.testing.expectEqual(options.tol.reltol, temp_job.temp.dc_options.tol.reltol);
}

test "deck options reject invalid numeric conversions before construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "itl1=-1", "itl2=65536", "itl4=0.4", "temp=-300", "tnom=nan", "reltol=-1" }) |option| {
        const source = try std.fmt.allocPrint(arena.allocator(), "invalid options\n.options {s}\n.end\n", .{option});
        const nl = try parse(arena.allocator(), source);
        try std.testing.expectError(error.InvalidAnalysisArguments, analyses.deckOptions(nl.deck.config, .ngspice));
    }
    const nl = try parse(arena.allocator(), "later wins\n.temp 50\n.options temp=27 method=gear maxord=1\n.end\n");
    const o = try analyses.deckOptions(nl.deck.config, .ngspice);
    try std.testing.expectEqual(@as(f64, 27), o.temp_c.?);
    try std.testing.expectEqual(requests.Method.backward_euler, o.method.?);
    // HSPICE: DELMAX caps a .tran that sets no tmax; TNOM and TEMP default to 25.
    const h = try analyses.deckOptions((try parse(arena.allocator(), "delmax\n.options delmax=2n\n.end\n")).deck.config, .hspice);
    var tran: Job = .{ .tran = .{ .t_stop = 1e-6, .dt_init = 1e-8 } };
    analyses.applyDeckOptions(&tran, h);
    try std.testing.expectEqual(@as(f64, 2e-9), tran.tran.dt_max.?);
    try std.testing.expectEqual(@as(f64, 25), h.temp_c.?);
    try std.testing.expectEqual(@as(f64, 25), h.tnom_c);
    // Integer options round as ngspice's floor(0.5 + x).
    const rounded = try parse(arena.allocator(), "rounded\n.options itl4=1.5 itl1=99.4 itl2=2.5\n.end\n");
    const r = try analyses.deckOptions(rounded.deck.config, .ngspice);
    try std.testing.expectEqual(@as(u16, 2), r.tol.itl4);
    try std.testing.expectEqual(@as(u16, 99), r.tol.itl1);
    try std.testing.expectEqual(@as(u16, 3), r.tol.itl2);
    // RUNLVL picks trtol whatever TRTOL says; ACCURATE lifts it to 5, FAST
    // alone is 1, RUNLVL=0 turns both off.
    for ([_]struct { []const u8, ?f64 }{
        .{ "runlvl=6 trtol=7", 0.875 }, .{ "runlvl", 7 },         .{ "accurate runlvl=2", 1.75 },
        .{ "accurate", 1.75 },          .{ "fast", 28 },          .{ "runlvl=0 accurate", null },
        .{ "fast accurate=1", 1.75 },   .{ "accurate=0", null },
    }) |case| {
        const source = try std.fmt.allocPrint(arena.allocator(), "runlvl\n.options {s}\n.end\n", .{case[0]});
        try std.testing.expectEqual(case[1], (try analyses.deckOptions((try parse(arena.allocator(), source)).deck.config, .hspice)).trtol);
    }
}

test "nonfinite model parameter cannot become its default" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const nl = try parse(pa.allocator(),
        \\invalid model value
        \\.model nm nmos(level=1 tox={1/0})
        \\vin in 0 1
        \\r1 in out 1k
        \\m1 out in 0 0 nm
        \\.op
        \\.end
    );
    try std.testing.expectError(error.NonFiniteParameter, build(sa.allocator(), pa.allocator(), nl));
}

test "an N card on a psp103va model runs the built-in PSP 103, as ngspice with OSDI does" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const nl = try parse(pa.allocator(),
        \\osdi module name
        \\.model pch psp103va type=-1
        \\vd d 0 -1
        \\np d d 0 0 pch w=1u l=1u
        \\.op
        \\.end
    );
    var prepared = try build(sa.allocator(), pa.allocator(), nl);
    defer prepared.deinit();
    const psp = device.Library.builtin("psp103");
    try std.testing.expect(std.mem.indexOfScalar(@TypeOf(psp), prepared.circuit.batch_types, psp) != null);
}

test "PSP 103 cards run the QS device unless they set SWNQS" {
    const cases = .{
        .{ "", "psp103" },
        .{ " swnqs=0", "psp103" },
        .{ " swnqs=1", "psp103_nqs" },
    };
    inline for (cases) |case| {
        var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer sa.deinit();
        var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pa.deinit();
        const nl = try parse(pa.allocator(), "psp nqs pick\n.model nch nmos level=1040" ++ case[0] ++
            "\nvd d 0 1\nm1 d d 0 0 nch w=1u l=1u\n.op\n.end\n");
        var prepared = try build(sa.allocator(), pa.allocator(), nl);
        defer prepared.deinit();
        const want = device.Library.builtin(case[1]);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(@TypeOf(want), prepared.circuit.batch_types, &.{want}));
    }
}

test ".save narrows the outputs; .save all keeps them" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const deck =
        \\save
        \\V1 in 0 1
        \\R1 in Mid 1k
        \\R2 mid out 1k
        \\R3 out 0 1k
        \\.save v(OUT) i(v1) v(nowhere)
        \\
    ;
    const nl = try parse(parse_arena.allocator(), deck ++ ".op\n.end\n");
    var saved = try build(session.allocator(), parse_arena.allocator(), nl);
    defer saved.deinit();
    try std.testing.expectEqual(@as(usize, 2), saved.deck.probe_labels.len);
    try std.testing.expectEqualStrings("i(v1)", saved.deck.probe_labels[0]);
    try std.testing.expectEqualStrings("v(out)", saved.deck.probe_labels[1]);
    const all = try parse(parse_arena.allocator(), deck ++ ".save all\n.op\n.end\n");
    var every = try build(session.allocator(), parse_arena.allocator(), all);
    defer every.deinit();
    try std.testing.expectEqual(@as(usize, 4), every.deck.probe_labels.len);
}

test "prepared metadata and query identities outlive parse storage" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const source = try parse_arena.allocator().dupe(u8,
        \\prepared lifetime
        \\va unused 0 dc 2
        \\vb in 0 dc 10 ac 1
        \\r1 in 2 1k ac=2k
        \\r2 2 0 3k
        \\.options temp=85 reltol=1e-5 method=gear maxord=1
        \\.ic v(2)=0.25
        \\.tf v(2) vb
        \\.noise v(2) vb dec 2 10 100
        \\.sens v(2)
        \\.tran 1u 10u uic
        \\.end
    );
    const nl = try parse(parse_arena.allocator(), source);
    var prepared = try build(session.allocator(), parse_arena.allocator(), nl);
    defer prepared.deinit();
    _ = parse_arena.reset(.free_all);
    try std.testing.expectEqualStrings("prepared lifetime", prepared.deck.title);
    try std.testing.expectEqual(@as(usize, 5), prepared.deck.queries.len);
    try std.testing.expectEqual(@as(f64, 85), prepared.deck.deck_temp.?);
    try std.testing.expectEqual(@as(f64, 1e-5), prepared.deck.deck_tol.reltol);
    try std.testing.expectEqualStrings("i(va)", prepared.deck.probe_labels[0]);
    try std.testing.expectEqualStrings("v(2)", prepared.deck.probe_labels[prepared.deck.probe_labels.len - 1]);
    const node = prepared.deck.probes[prepared.deck.probes.len - 1];
    try std.testing.expectEqual(node, prepared.deck.queries[0].tf.output_node);
    try std.testing.expectEqual(prepared.deck.probes[1], prepared.deck.queries[0].tf.input_branch.?);
    try std.testing.expectEqual(node, prepared.deck.queries[1].noise.out_node);
    try std.testing.expect(!prepared.deck.queries[1].noise.integrated);
    try std.testing.expect(prepared.deck.queries[2].noise.integrated);
    try std.testing.expectEqualStrings("r1", prepared.deck.queries[3].sens.cards[2].name);
    try std.testing.expectEqual(requests.Method.backward_euler, prepared.deck.queries[4].tran.method);
    try std.testing.expect(prepared.deck.queries[4].tran.uic);
    try std.testing.expectEqual(@as(usize, 1), prepared.deck.ic.len);
    try std.testing.expectEqual(node, prepared.deck.ic[0].node);
    try std.testing.expectEqual(@as(f64, 0.25), prepared.deck.ic[0].value);
    try std.testing.expectEqual(@as(usize, 1), prepared.deck.ac_overrides.len);
    try std.testing.expectEqual(device.Library.builtin("resistor"), prepared.deck.ac_overrides[0].type);
    try std.testing.expectEqualStrings("r", prepared.deck.ac_overrides[0].param_name);
    try std.testing.expectEqual(@as(u32, 0), prepared.deck.ac_overrides[0].index);
    try std.testing.expectEqual(@as(f64, 2000), prepared.deck.ac_overrides[0].value);

    const appended = try resolveQueries(session.allocator(), &prepared,
        \\.tf v(2) vb
        \\.dc vb 0 1 0.1
        \\.noise v(2) vb dec 2 10 100
        \\.tran 1u 10u
        \\.sens v(2)
    );
    try std.testing.expectEqual(@as(usize, 6), appended.len);
    try std.testing.expectEqual(node, appended[0].tf.output_node);
    try std.testing.expectEqual(prepared.deck.probes[1], appended[0].tf.input_branch.?);
    try std.testing.expectEqual(device.Library.builtin("vsource"), appended[1].dc.target.device.type);
    try std.testing.expectEqual(@as(u32, 1), appended[1].dc.target.device.index);
    try std.testing.expectEqual(node, appended[2].noise.out_node);
    try std.testing.expect(appended[3].noise.integrated);
    try std.testing.expectEqual(requests.Method.backward_euler, appended[4].tran.method);
    try std.testing.expectEqual(prepared.deck.deck_tol.reltol, appended[4].tran.tol.reltol);
    try std.testing.expectEqualStrings("r1", appended[5].sens.cards[2].name);
    for ([_][]const u8{
        "r3 2 0 1k",            ".model rm r(r=1k)", ".hdl \"part.va\"", ".include \"part.cir\"",
        ".param p=1",           ".options temp=12",  ".temp 12",         ".subckt unused a b\n.ends",
        ".op\n.end\nr3 2 0 1k",
    }) |text| try std.testing.expectError(error.UnsupportedDirectiveMutation, resolveQueries(session.allocator(), &prepared, text));
    try std.testing.expectError(error.InvalidAnalysisArguments, resolveQueries(session.allocator(), &prepared, "* nothing\n"));
    try std.testing.expectError(error.AnalysisNodeNotFound, resolveQueries(session.allocator(), &prepared, ".tf v(missing) vb"));
    try std.testing.expectError(error.UnsupportedAnalysisOutput, resolveQueries(session.allocator(), &prepared, ".tf v(in, 2) vb"));
    try std.testing.expectEqual(@as(usize, 5), prepared.deck.queries.len);
}

test ".dcxf leaves out a V card an F or H senses" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    const nl = try parse(session.allocator(),
        \\sensed
        \\v1 in 0 1
        \\vs in a 0
        \\r1 a 0 1k
        \\f1 0 out vs 2
        \\r2 out 0 1k
        \\i1 0 out 1m
        \\.dcxf v(out)
        \\.end
    );
    var prepared = try build(session.allocator(), session.allocator(), nl);
    defer prepared.deinit();
    const sources = prepared.deck.queries[0].dcxf.sources;
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("v1", sources[0].name);
    try std.testing.expectEqualStrings("i1", sources[1].name);
}

test "a numeric reference node is that node, not ground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try parse(a,
        \\numeric reference
        \\vb in 0 dc 10 ac 1
        \\r1 in 2 1k
        \\r2 2 0 3k
        \\.tf v(in, 2) vb
        \\.noise v(in, 2) vb dec 2 10 100
        \\.end
    );
    var prepared = try build(a, a, nl);
    defer prepared.deinit();
    const node = prepared.deck.probes[prepared.deck.probes.len - 1];
    try std.testing.expectEqualStrings("v(2)", prepared.deck.probe_labels[prepared.deck.probe_labels.len - 1]);
    try std.testing.expectEqual(node, prepared.deck.queries[0].tf.output_neg);
    try std.testing.expectEqual(node, prepared.deck.queries[1].noise.out_neg);
}

test "cards without an output measure the last net the deck introduces, whatever the BBD order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try parse(a,
        \\bbd output
        \\.subckt rc p q
        \\r1 p m 1k
        \\c1 m q 1n
        \\.ends
        \\v1 in 0 dc 0 ac 1 distof1 0.01
        \\x1 in mid rc
        \\x2 mid out rc
        \\r2 out 0 1k
        \\.disto dec 2 10 100
        \\.pac 1k dec 2 10 100
        \\.end
    );
    var prepared = try build(a, a, nl);
    defer prepared.deinit();
    const deck = prepared.deck;
    // x2's internal net comes last in the deck; the permutation puts v(mid) last among the probes.
    try std.testing.expectEqualStrings("x2.m", prepared.circuit.nodeName(deck.output_node));
    try std.testing.expectEqualStrings("v(mid)", deck.probe_labels[deck.probe_labels.len - 1]);
    try std.testing.expectEqual(deck.output_node, deck.queries[0].disto.output_node);
    try std.testing.expectEqual(deck.output_node, deck.queries[3].pac.out_node);
}

test "selected unresolved parameters fail while unused models stay inert" {
    inline for (.{
        ".model nm nmos(level=1 tox={missing})\nm1 out in 0 0 nm\n",
        "r1 out 0 r=0*missing\n",
        // A value naming no parameter and no model, not the 1 mOhm default.
        "r1 out 0 missing\n",
    }) |body| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse_arena.deinit();
        const nl = try parse(parse_arena.allocator(), "unresolved numeric parameter\n.param dummy=1\nvin in 0 dc 1\nrload in out 1k\n" ++ body ++ ".op\n.end\n");
        try std.testing.expectError(error.UnresolvedParameter, build(session.allocator(), parse_arena.allocator(), nl));
    }
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const nl = try parse(parse_arena.allocator(),
        \\unused model
        \\.model unused nmos(level=1 tox={missing})
        \\vin in 0 dc 1
        \\r1 in out 1k
        \\r2 out 0 1k
        \\.op
        \\.end
    );
    var prepared = try build(session.allocator(), parse_arena.allocator(), nl);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), prepared.deck.queries.len);
}

test "prepared bindings retain model fields and exclude runtime state from parameter collection" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const nl = try parse(parse_arena.allocator(),
        \\escaped parameter name
        \\.model nm nmos(level=54 pub=1.25e-18)
        \\vd drain 0 1
        \\vg gate 0 1.2
        \\m1 drain gate 0 0 nm l=1u w=10u
        \\r1 drain gate 1k
        \\r2 gate 0 3k
        \\.op
        \\.end
    );
    var prepared = try build(session.allocator(), parse_arena.allocator(), nl);
    defer prepared.deinit();
    _ = parse_arena.reset(.free_all);
    var refs: std.ArrayList(device.abi.ParamRef) = .empty;
    try collectTyped(&prepared.circuit, session.allocator(), &refs);
    var saw_pub = false;
    var resistors: u32 = 0;
    for (refs.items) |ref| {
        if (std.mem.eql(u8, ref.param_name, "pubZ")) {
            // 125 * 1e-20: ngspice INPevaluate bits for `1.25e-18`.
            try std.testing.expectEqual(@as(f64, 125) * @as(f64, 1e-20), ref.get());
            saw_pub = true;
        }
        if (ref.type != device.Library.builtin("resistor")) continue;
        if (ref.is_instance) {
            try std.testing.expectEqualStrings("mfactor", ref.param_name);
            try std.testing.expect(!ref.primary);
        }
        if (std.mem.eql(u8, ref.param_name, "r")) {
            try std.testing.expect(ref.primary);
            resistors += 1;
        }
    }
    try std.testing.expect(saw_pub);
    try std.testing.expectEqual(@as(u32, 2), resistors);
}

test "selected model integer fields and levels reject out-of-range values" {
    for ([_][]const u8{ "level=-1", "level=65536", "level=54 tnoimod=1e40" }) |parameters| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse_arena.deinit();
        const source = try std.fmt.allocPrint(parse_arena.allocator(), "invalid integer parameter\n.model nm nmos({s})\nvd drain 0 1\nvg gate 0 1\nm1 drain gate 0 0 nm\n.op\n.end\n", .{parameters});
        const nl = try parse(parse_arena.allocator(), source);
        try std.testing.expectError(error.ParameterOutOfRange, build(session.allocator(), parse_arena.allocator(), nl));
    }
}

test "behavioral sources the tape cannot express are rejected, not opened" {
    inline for (.{ "v=v(out)+i(r1)", "i=v(out)*x", "i=foo(v(out))", "i=agauss(v(out),1,1)", "i=min(v(a))", "v=v(out)+v(a)+v(b)+v(c)+v(d)+v(e)+v(f)+v(g)+v(h)" }) |output| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nl = try parse(a, "behavioral source\nb1 out 0 " ++ output ++ "\nr1 out 0 1k\nr2 a 0 1k\nr3 b 0 1k\nr4 c 0 1\nr5 d 0 1\nr6 e 0 1\nr7 f 0 1\nr8 g 0 1\nr9 h 0 1\n.end\n");
        try std.testing.expectError(error.UnsupportedBsourceExpression, build(a, a, nl));
    }
}

test "input preparation retains bytes and origin after caller storage changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = "retained input\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n".*;
    var origin = "Models/Deck.cir".*;
    const prepared = try prepare(std.testing.io, arena.allocator(), .{
        .bytes = .{ .data = &source, .origin = &origin },
    }, .ngspice);
    @memset(&source, 'x');
    @memset(&origin, 'x');
    try std.testing.expectEqual(@as(u32, 2), prepared.deviceCount());
    try std.testing.expectEqualStrings("retained input", prepared.deck.title);
}

test "input preparation resolves file includes and selected dialect" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "res.inc", .data = "R1 out 0 1k\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "input.cir",
        .data = "included input\n.include res.inc\nV1 out 0 1\n.op\n.end\n",
    });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/input.cir", .{tmp.sub_path});
    const prepared = try prepare(io, a, .{ .file = path }, .hspice);
    try std.testing.expectEqual(@as(u32, 2), prepared.deviceCount());
    const from_bytes = try prepare(io, a, .{
        .bytes = .{ .data = "byte input\n.include res.inc\nV1 out 0 1\n.end\n", .origin = path },
    }, .ngspice);
    try std.testing.expectEqual(@as(u32, 2), from_bytes.deviceCount());
    try std.testing.expectEqual(input.Dialect.hspice, input.parseDialect("hs").?);
}

test "control source binding retains first exact duplicate and distinct mixed-case names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nl = try netlist.parse(a,
        \\VCase first 0 2
        \\vcase second 0 3
        \\VCase duplicate 0 9
        \\R1 first 0 1k
        \\R2 second 0 1k
        \\R3 duplicate 0 1k
        \\F1 out1 0 VCase 1
        \\F2 out2 0 vcase 1
        \\R4 out1 0 1k
        \\R5 out2 0 1k
    , .spectre);
    var prepared = try build(a, a, nl);
    defer prepared.deinit();
    var refs: std.ArrayList(device.abi.ParamRef) = .empty;
    try collectTyped(&prepared.circuit, a, &refs);
    var found: u32 = 0;
    for (refs.items) |ref| {
        if (ref.type != device.Library.builtin("cccs") or !std.mem.eql(u8, ref.param_name, "vsense")) continue;
        try std.testing.expect(ref.index < 2);
        try std.testing.expectEqual(([_]f64{ 2, 3 })[ref.index], ref.get());
        found += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), found);
}

test "one binder: a runtime-registered device binds a card exactly as the same model built in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    // The built-in resistor's own vtable, registered the way `Library.load`
    // registers a dlopen'd one: its cards then take the runtime-device route
    // (loadedType, bind_model, derive, collapse). Only the dlopen step is
    // left out; a real .so of models/*.va is not a fixture yet because VerA's
    // library emit declares `h` twice for models with hoisted temporaries.
    const loaded = try lib.register("resistor_rt", device.vtable("resistor"), false);
    try std.testing.expect(loaded != device.Library.builtin("resistor"));

    // One card, bound twice: R1 through the built-in resistor, N1 through the
    // loaded one (`.model` kind names the module).
    const pairs = "r=2k tc1=1e-3 tc2=1e-6 dtemp=5";
    const nl = try netlist.parse(a, try std.fmt.allocPrint(a,
        \\one binder
        \\V1 a 0 1
        \\R1 a 0 {s}
        \\N1 a 0 rloaded
        \\.model rloaded resistor_rt {s}
        \\.end
    , .{ pairs, pairs }), .ngspice);
    var prepared = try input.build(&lib, a, a, nl);
    defer prepared.deinit();

    var refs: [2]std.ArrayList(device.abi.ParamRef) = .{ .empty, .empty };
    for (prepared.circuit.batches, prepared.circuit.batch_types) |batch, t| {
        const side: usize = if (t == device.Library.builtin("resistor")) 0 else if (t == loaded) 1 else continue;
        try batch.hooks.collect_params(batch.ctx, a, &refs[side]).unwrap();
    }
    try std.testing.expect(refs[0].items.len > 0);
    try std.testing.expectEqual(refs[0].items.len, refs[1].items.len);
    for (refs[0].items, refs[1].items) |built_in, runtime| {
        try std.testing.expectEqualStrings(built_in.param_name, runtime.param_name);
        try std.testing.expectEqual(built_in.get(), runtime.get());
    }
}
