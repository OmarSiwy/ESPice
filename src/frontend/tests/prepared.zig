const std = @import("std");
const impl = @import("../prepare.zig");
const input = impl;
const syntax = @import("syntax");
const types = syntax.types;
const Parser = syntax.Parser;
const ngspice = syntax.ngspice;
const problem = @import("problem_types");
const requests = @import("requests");
const Job = requests.Query;
const NO_NODE = std.math.maxInt(u32);
const build = impl.build;
const resolveQueries = impl.resolveQueries;
const Sources = impl.test_access.Sources;
const DeckOptions = impl.test_access.DeckOptions;
const parseDeckOptions = impl.test_access.parseDeckOptions;
const buildJob = impl.test_access.buildJob;
const applyDeckOptions = impl.test_access.applyDeckOptions;

test "analysis directives dispatch every implemented capability and reject malformed requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources: Sources = .{ .v_names = &.{"vin"}, .i_names = &.{}, .v_branches = &.{2}, .v_distof1 = &.{.{ 0, 0 }} };
    const directives = [_][]const u8{
        ".ac dec 2 10 100",                     ".dc vin 0 1 0.1",       ".dcmatch v(out)",
        ".disto dec 2 10 100",                  ".envelope 1m 5m",       ".four 1k v(out)",
        ".hb 1k",                               ".matex 1u 10u",         ".mc 4",
        ".noise v(out) vin dec 2 10 100",       ".op",                   ".pac 1k dec 2 10 100",
        ".pnoise v(out) vin dec 2 10 100 1k 0", ".pss 1k 128",           ".pxf 1k dec 2 10 100",
        ".pz",                                  ".qpss 1k 1414 1 1",     ".sens v(out)",
        ".sp dec 2 10 100",                     ".stb vin dec 2 10 100", ".temp -40 125 55",
        ".tf v(out) vin",                       ".tran 1u 10u",          ".tran_noise 1u 10u",
    };
    try std.testing.expectEqual(std.meta.fields(requests.Kind).len, directives.len);
    for (directives, 0..) |directive, index| {
        const nl = try Parser(ngspice).parse(a, try std.fmt.allocPrint(a, "dispatch\n{s}\n.end\n", .{directive}));
        const id: requests.Kind = @enumFromInt(index);
        if (id == .stb) {
            try std.testing.expectError(error.UnsupportedStabilityAnalysis, buildJob(nl.directives[0], 1, sources));
            continue;
        }
        const job = (try buildJob(nl.directives[0], 1, sources)).?;
        try std.testing.expectEqual(id, std.meta.activeTag(job));
        if (job == .pss) try std.testing.expectEqual(@as(f64, 1e-3), job.pss.period);
    }
    const malformed = [_][]const u8{
        ".ac dec 0 1 10",                ".ac dec -1 1 10",     ".ac dec 2.5 1 10",                      ".ac dec 2 10 1",
        ".ac lin 2 1 10",                ".dc missing 0 1 0.1", ".dc vin 0 1 0",                         ".dc vin 0 1 -1",
        ".dc vin 0 1 1 missing 0 1 1",   ".tran 0 1u",          ".tran 1u 2u 1u",                        ".pss 0",
        ".pss 1k 2m v(out) 128 4 50 1m", ".mc 65536",           ".pnoise v(out) vin dec 2 10 100 1k -1", ".pz in 0 out 0 vol pz",
        ".tf v(out) missing",            ".temp -300 125 55",
    };
    for (malformed) |directive| {
        const nl = try Parser(ngspice).parse(a, try std.fmt.allocPrint(a, "invalid\n{s}\n.end\n", .{directive}));
        if (buildJob(nl.directives[0], 1, sources)) |_| return error.AcceptedInvalidAnalysis else |_| {}
    }
    const unknown: types.Directive = .{ .kind = "options", .args = &.{} };
    try std.testing.expectEqual(null, try buildJob(unknown, NO_NODE, sources));
}

test "deck temperature and tolerances reach statistical and noise jobs" {
    // `.temp` reaches noise through the DEVICES (engine.zig setCircuitTemp ->
    // Instance.temperature -> the model's own `noisePsd`), not through an
    // analysis-card copy: ngspice's NevalSrc multiplies by `ckt->CKTtemp`
    // (nevalsrc.c:111) precisely because its devices hand over a bare
    // conductance, and ours hand over a finished density.
    const options: DeckOptions = .{ .temp_c = 85, .tol = .{ .reltol = 1e-5 } };
    var temp_job: Job = .{ .temp = .{} };
    applyDeckOptions(&temp_job, options);
    try std.testing.expectEqual(@as(f64, 85), temp_job.temp.t_nom);
    try std.testing.expectEqual(options.tol.reltol, temp_job.temp.dc_options.tol.reltol);
}

test "deck options reject invalid numeric conversions before construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "itl1=-1", "itl2=65536", "itl4=1.5", "temp=-300", "tnom=nan", "reltol=-1" }) |option| {
        const source = try std.fmt.allocPrint(arena.allocator(), "invalid options\n.options {s}\n.end\n", .{option});
        const nl = try Parser(ngspice).parse(arena.allocator(), source);
        try std.testing.expectError(error.InvalidAnalysisArguments, parseDeckOptions(nl.directives));
    }
}

test "nonfinite model parameter cannot become its default" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();
    const nl = try Parser(ngspice).parse(pa.allocator(),
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

test "prepared metadata and query identities outlive parse storage" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse.deinit();
    const source = try parse.allocator().dupe(u8,
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
    const nl = try Parser(ngspice).parse(parse.allocator(), source);
    var prepared = try build(session.allocator(), parse.allocator(), nl);
    defer prepared.deinit();
    _ = parse.reset(.free_all);
    try std.testing.expectEqualStrings("prepared lifetime", prepared.title);
    try std.testing.expectEqual(@as(usize, 5), prepared.queries.len);
    try std.testing.expectEqual(@as(f64, 85), prepared.deck_temp.?);
    try std.testing.expectEqual(@as(f64, 1e-5), prepared.deck_tol.reltol);
    try std.testing.expectEqualStrings("i(va)", prepared.probe_labels[0]);
    try std.testing.expectEqualStrings("v(2)", prepared.probe_labels[prepared.probe_labels.len - 1]);
    const node = prepared.probes[prepared.probes.len - 1];
    try std.testing.expectEqual(node, prepared.queries[0].tf.output_node.?);
    try std.testing.expectEqual(prepared.probes[1], prepared.queries[0].tf.input_branch.?);
    try std.testing.expectEqual(node, prepared.queries[1].noise.out_node);
    try std.testing.expect(!prepared.queries[1].noise.integrated);
    try std.testing.expect(prepared.queries[2].noise.integrated);
    try std.testing.expectEqualStrings("r1", prepared.queries[3].sens.cards[2].name);
    try std.testing.expectEqual(requests.Method.backward_euler, prepared.queries[4].tran.method);
    try std.testing.expect(prepared.queries[4].tran.uic);
    try std.testing.expectEqual(@as(usize, 1), prepared.ic.len);
    try std.testing.expectEqual(node, prepared.ic[0].node);
    try std.testing.expectEqual(@as(f64, 0.25), prepared.ic[0].value);
    try std.testing.expectEqual(@as(usize, 1), prepared.ac_overrides.len);
    try std.testing.expectEqualStrings("resistor", prepared.ac_overrides[0].type_name);
    try std.testing.expectEqualStrings("r", prepared.ac_overrides[0].param_name);
    try std.testing.expectEqual(@as(u32, 0), prepared.ac_overrides[0].index);
    try std.testing.expectEqual(@as(f64, 2000), prepared.ac_overrides[0].value);

    const appended = try resolveQueries(session.allocator(), &prepared,
        \\.tf v(2) vb
        \\.dc vb 0 1 0.1
        \\.noise v(2) vb dec 2 10 100
        \\.tran 1u 10u
    );
    try std.testing.expectEqual(@as(usize, 5), appended.len);
    try std.testing.expectEqual(node, appended[0].tf.output_node.?);
    try std.testing.expectEqual(prepared.probes[1], appended[0].tf.input_branch.?);
    try std.testing.expectEqual(@as(u32, 1), appended[1].dc.source_index);
    try std.testing.expectEqual(node, appended[2].noise.out_node);
    try std.testing.expect(appended[3].noise.integrated);
    try std.testing.expectEqual(requests.Method.backward_euler, appended[4].tran.method);
    try std.testing.expectEqual(prepared.deck_tol.reltol, appended[4].tran.tol.reltol);
    for ([_][]const u8{
        "r3 2 0 1k",            ".model rm r(r=1k)", ".hdl \"part.va\"", ".include \"part.cir\"",
        ".param p=1",           ".options temp=12",  ".temp 12",         ".subckt unused a b\n.ends",
        ".op\n.end\nr3 2 0 1k",
    }) |text| try std.testing.expectError(error.UnsupportedDirectiveMutation, resolveQueries(session.allocator(), &prepared, text));
    try std.testing.expectError(error.AnalysisNodeNotFound, resolveQueries(session.allocator(), &prepared, ".tf v(missing) vb"));
    try std.testing.expectEqual(@as(usize, 5), prepared.queries.len);
}

test "selected unresolved parameters fail while unused models stay inert" {
    inline for (.{
        ".model nm nmos(level=1 tox={missing})\nm1 out in 0 0 nm\n",
        "r1 out 0 r=0*missing\n",
        ".param mc=1\n.model nm nmos(level=1 tox={1e-7+mc*agauss(0,1e-9,1)})\nm1 out in 0 0 nm\n",
    }) |body| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        var parse = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse.deinit();
        const nl = try Parser(ngspice).parse(parse.allocator(), "unresolved numeric parameter\n.param dummy=1\nvin in 0 dc 1\nrload in out 1k\n" ++ body ++ ".op\n.end\n");
        try std.testing.expectError(error.UnresolvedParameter, build(session.allocator(), parse.allocator(), nl));
    }
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse.deinit();
    const nl = try Parser(ngspice).parse(parse.allocator(),
        \\unused model
        \\.model unused nmos(level=1 tox={missing})
        \\vin in 0 dc 1
        \\r1 in out 1k
        \\r2 out 0 1k
        \\.op
        \\.end
    );
    var prepared = try build(session.allocator(), parse.allocator(), nl);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), prepared.queries.len);
}

test "prepared bindings retain model fields and exclude runtime state from parameter collection" {
    var session = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session.deinit();
    var parse = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse.deinit();
    const nl = try Parser(ngspice).parse(parse.allocator(),
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
    var prepared = try build(session.allocator(), parse.allocator(), nl);
    defer prepared.deinit();
    _ = parse.reset(.free_all);
    var refs: std.ArrayList(problem.device_ir.ParamRef) = .empty;
    for (prepared.circuit.batches) |batch| try batch.hooks.collect_params(batch.ctx, session.allocator(), &refs);
    var saw_pub = false;
    var resistors: u32 = 0;
    for (refs.items) |ref| {
        if (std.mem.eql(u8, ref.param_name, "pubZ")) {
            try std.testing.expectEqual(@as(f64, 1.25e-18), ref.get());
            saw_pub = true;
        }
        if (!std.mem.eql(u8, ref.device_type, "resistor")) continue;
        if (ref.is_instance) {
            try std.testing.expect(std.mem.eql(u8, ref.param_name, "temperature") or std.mem.eql(u8, ref.param_name, "mfactor"));
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
    for ([_][]const u8{ "level=-1", "level=65536", "level=54 tnoimod=1e40", "level=54 tnoimod=1.5" }) |parameters| {
        var session = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer session.deinit();
        var parse = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse.deinit();
        const source = try std.fmt.allocPrint(parse.allocator(), "invalid integer parameter\n.model nm nmos({s})\nvd drain 0 1\nvg gate 0 1\nm1 drain gate 0 0 nm\n.op\n.end\n", .{parameters});
        const nl = try Parser(ngspice).parse(parse.allocator(), source);
        try std.testing.expectError(error.ParameterOutOfRange, build(session.allocator(), parse.allocator(), nl));
    }
}

test "constant behavioral sources preserve value and output mode after folding" {
    inline for (.{ "v=5", "i=1m", "v={2+3}", "i={2*0.0005}" }, .{ 5.0, 0.001, 5.0, 0.001 }) |output, expected| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const ast = try Parser(ngspice).parse(a, "constant behavioral source\nb1 out 0 " ++ output ++ "\nr1 out 0 1k\n.end\n");
        var prepared = try build(a, a, ast);
        defer prepared.deinit();
        var refs: std.ArrayList(problem.device_ir.ParamRef) = .empty;
        for (prepared.circuit.batches) |batch| try batch.hooks.collect_params(batch.ctx, a, &refs);
        var found = false;
        for (refs.items) |ref| if (std.mem.eql(u8, ref.device_type, "bsource") and std.mem.eql(u8, ref.param_name, "c0")) {
            try std.testing.expectApproxEqAbs(expected, ref.get(), 1e-15);
            found = true;
        };
        try std.testing.expect(found);
        try std.testing.expectEqual(output[0] == 'v', std.mem.eql(u8, prepared.probe_labels[0], "i(b1)"));
    }
}

test "input preparation retains bytes and origin after caller storage changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = "retained input\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n".*;
    var origin = "Models/Deck.cir".*;
    const prepared = try input.prepare(std.testing.io, arena.allocator(), .{
        .bytes = .{ .data = &source, .origin = &origin },
    }, .ngspice);
    @memset(&source, 'x');
    @memset(&origin, 'x');
    try std.testing.expectEqualStrings("Models/Deck.cir", prepared.origin);
    try std.testing.expect(std.mem.startsWith(u8, prepared.source, "retained input\n"));
    try std.testing.expectEqual(@as(usize, 2), prepared.ast.devices.len);
    try std.testing.expectEqualStrings("retained input", prepared.ast.title);
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
    const prepared = try input.prepare(io, a, .{ .file = path }, .hspice);
    try std.testing.expectEqual(@as(usize, 2), prepared.ast.devices.len);
    const from_bytes = try input.prepare(io, a, .{
        .bytes = .{ .data = "byte input\n.include res.inc\nV1 out 0 1\n.end\n", .origin = path },
    }, .ngspice);
    try std.testing.expectEqual(@as(usize, 2), from_bytes.ast.devices.len);
    try std.testing.expectEqual(input.Dialect.hspice, input.parseDialect("hs").?);
}
