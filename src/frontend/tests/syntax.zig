const std = @import("std");
const syntax = @import("syntax");
const ir = syntax.types;
const Parser = syntax.Parser;
const ngspice = syntax.ngspice;
const spectre = syntax.spectre;
const normalize = syntax.parser.test_access.normalize;
const elaborate = syntax.elaborate;
const load = syntax.load;

test "parser: recognizes Verilog-A HDL includes as foreign devices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\test
        \\.hdl "models/resistor.va"
        \\.include 'models/diode.vams'
        \\.end
        \\
    ;
    const nl = try Parser(ngspice).parse(arena_state.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), nl.foreign.len);
    try std.testing.expectEqual(ir.ForeignKind.verilog_a, nl.foreign[0].kind);
    try std.testing.expectEqualStrings("models/resistor.va", nl.foreign[0].path);
    try std.testing.expectEqual(ir.ForeignKind.verilog_a, nl.foreign[1].kind);
    try std.testing.expectEqualStrings("models/diode.vams", nl.foreign[1].path);
}

test "parser: leaves ordinary includes as directives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\test
        \\.include "models/common.inc"
        \\.end
        \\
    ;
    const nl = try Parser(ngspice).parse(arena_state.allocator(), src);
    try std.testing.expectEqual(@as(usize, 0), nl.foreign.len);
    try std.testing.expectEqual(@as(usize, 1), nl.directives.len);
    try std.testing.expectEqualStrings("include", nl.directives[0].kind);
}

test "normalization SIMD matches W=1 at every boundary" {
    var prng = std.Random.DefaultPrng.init(0xa5c11);
    var src: [257]u8 = undefined;
    var expected: [257]u8 = undefined;
    var actual: [257]u8 = undefined;
    for (0..20) |_| {
        prng.random().bytes(&src);
        inline for (.{ 1, 16, 32, 64 }) |width| for (0..src.len + 1) |n| {
            const count = normalize(1, expected[0..n], src[0..n]);
            try std.testing.expectEqual(count, normalize(width, actual[0..n], src[0..n]));
            try std.testing.expectEqualSlices(u8, expected[0..n], actual[0..n]);
            try std.testing.expectEqual(std.mem.countScalar(u8, src[0..n], '\n'), count);
            for (src[0..n], actual[0..n]) |before, after| try std.testing.expectEqual(std.ascii.toLower(before), after);
        };
    }
}

test "parser retains source order, subcircuit calls, and unresolved expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ast = try Parser(ngspice).parse(arena.allocator(),
        \\AST boundary
        \\x1 out 0 cell r=2*500
        \\v1 out 0 1
        \\.subckt cell a b r=1k
        \\.param doubled={r*2}
        \\r1 a b {doubled}
        \\.ends
        \\.end
    );
    try std.testing.expectEqual(@as(usize, 2), ast.devices.len);
    try std.testing.expectEqualStrings("x1", ast.devices[0].name);
    try std.testing.expectEqualStrings("v1", ast.devices[1].name);
    try std.testing.expect(ast.devices[0].kv[0].value == .expr);
    try std.testing.expectEqual(@as(usize, 1), ast.subcircuits.len);
    const sub = ast.subcircuits[0];
    try std.testing.expectEqualStrings("cell", sub.name);
    try std.testing.expectEqual(@as(usize, 2), sub.defaults.len);
    try std.testing.expectEqualStrings("r1", sub.devices[0].name);
    try std.testing.expectEqualStrings("doubled", sub.devices[0].positional[0].expr.ident);
    try std.testing.expectEqual(@as(usize, 0), ast.params.len);
}

test "parser reuses card buffers without aliasing previous cards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: std.Io.Writer.Allocating = .init(a);
    try source.writer.writeAll("wide cards\nx1");
    for (0..40) |i| try source.writer.print(" n{d}", .{i});
    try source.writer.writeAll(" wide");
    for (0..20) |i| try source.writer.print(" p{d}={d}", .{ i, i });
    try source.writer.writeAll("\nr2 out 0 1k\nx3 a b small\n.end\n");
    const ast = try Parser(ngspice).parse(a, source.written());
    try std.testing.expectEqual(@as(usize, 40), ast.devices[0].nodes.len);
    try std.testing.expectEqualStrings("n39", ast.devices[0].nodes[39]);
    try std.testing.expectEqual(@as(usize, 20), ast.devices[0].kv.len);
    try std.testing.expectEqualStrings("p19", ast.devices[0].kv[19].key);
    try std.testing.expectEqualStrings("wide", ast.devices[0].positional[0].name);
    try std.testing.expectEqualStrings("out", ast.devices[1].nodes[0]);
    try std.testing.expectEqual(@as(f64, 1000), ast.devices[1].positional[0].num);
    try std.testing.expectEqualStrings("small", ast.devices[2].positional[0].name);
    try std.testing.expectError(error.ParseError, Parser(ngspice).parse(a, "invalid\n1bad out 0 1k\n"));
}

test "spectre: block comments are stripped span-wise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const strip = syntax.tokenizer.test_access.stripBlockComments;
    // No marker: the input slice is returned untouched.
    try std.testing.expectEqualStrings("r1 a b 1k", try strip(a, "r1 a b 1k"));
    // Only the ends are trimmed; the spaces that flanked a comment survive.
    try std.testing.expectEqualStrings("r1  a b  1k", try strip(a, "r1 /*x*/ a b /*y*/ 1k"));
    try std.testing.expectEqualStrings("ad", try strip(a, "a/**//*c*/d")); // adjacent markers
    try std.testing.expectEqualStrings("", try strip(a, "/**/"));
    // Unterminated: the rest of the line goes with the comment.
    try std.testing.expectEqualStrings("a", try strip(a, "a /*b c"));
    try std.testing.expectEqualStrings("", try strip(a, "/*"));
}

test "source: nested relative includes select only requested case-insensitive corner" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Models");
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = "Title\n.LIB 'Models/lib.sp' TT\n.end\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib ss ; ignored corner\n.include missing.sp\n.endl ss\n.lib tt $ selected corner\n.inc 'res.sp'\n.endl TT ; close\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/res.sp", .data = "R1 out 0 1k\n" });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/deck.sp", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const text = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "R1 out 0 1k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "missing") == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.endl ff\n" });
    try std.testing.expectError(error.InvalidLibrarySection, load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib ff\n.endl ff\n" });
    try std.testing.expectError(error.LibrarySectionNotFound, load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.include 'lib.sp'\n.endl tt\n" });
    // An unselected library declaration is inert when included without a corner.
    const inert = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(inert);
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.lib 'lib.sp' tt\n.endl tt\n" });
    try std.testing.expectError(error.IncludeDepthExceeded, load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = "\n* unmatched ' comment\n.include 'Models/res.sp'\n.end\n" });
    const blank_title = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(blank_title);
    try std.testing.expectEqualStrings("\n* unmatched ' comment\nR1 out 0 1k\n\n.end\n\n", blank_title);
    // Include-free input is returned byte-for-byte, including CRLF and no final LF.
    const plain = ".include is only the title\r\n* .lib 'comment\r\nR1 out 0 1k\r\n.end";
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = plain });
    const unchanged = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(plain, unchanged);
}

fn parseAndElaborate(arena: std.mem.Allocator, source: []const u8) !ir.Netlist {
    return elaborate(arena, try Parser(ngspice).parse(arena, source));
}

fn device(nl: ir.Netlist, name: []const u8) !ir.Device {
    for (0..nl.devices.len()) |i| {
        const d = nl.devices.get(i);
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return error.MissingDevice;
}

fn numeric(value: ir.Value) !f64 {
    return switch (value) {
        .num => |n| n,
        else => error.UnresolvedConstant,
    };
}

fn parameter(kv: []const ir.Kv, name: []const u8) !f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, name)) return numeric(item.value);
    return error.MissingParameter;
}

test "parameters: unsigned and signed exponents preserve following operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseAndElaborate(arena.allocator(),
        \\exponents
        \\.param a=1e6+2 b=1e+3-2 c=1e-3*2 d=1e12/2
        \\r1 a 0 {a}
        \\r2 b 0 {b}
        \\r3 c 0 {c}
        \\r4 d 0 {d}
        \\.end
    );
    for ([_][]const u8{ "r1", "r2", "r3", "r4" }, [_]f64{ 1000002, 998, 0.002, 5e11 }) |name, expected| {
        try std.testing.expectApproxEqRel(expected, try numeric((try device(nl, name)).positional[0]), 1e-12);
    }
}

test "parameters: unquoted parameter model and instance expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseAndElaborate(arena.allocator(),
        \\unquoted values
        \\.param base=2 width=1u*2 length=2u/2
        \\.model nm nmos(level=1 vto=base/4+0.1 kp=1e-4*(2+1))
        \\m1 d g 0 0 nm w=width*2 l=length/2
        \\r1 d 0 r=base*500
        \\.end
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), try parameter(nl.models[0].kv, "vto"), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3e-4), try parameter(nl.models[0].kv, "kp"), 1e-17);
    try std.testing.expectApproxEqAbs(@as(f64, 4e-6), try parameter((try device(nl, "m1")).kv, "w"), 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5e-6), try parameter((try device(nl, "m1")).kv, "l"), 1e-18);
    try std.testing.expectEqual(@as(f64, 1000), try parameter((try device(nl, "r1")).kv, "r"));
}

test "parameters: global definitions keep their scope under nested overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ngspice: Rtop=2, Rlocal=18, Rglobal=6, Rinner=19.
    const nl = try parseAndElaborate(arena.allocator(),
        \\scoped expressions
        \\.param base=2 global_derived={base*3}
        \\.subckt inner a b params: local=7
        \\.param derived={local+base}
        \\rinner a b {derived}
        \\.ends
        \\.subckt outer a b params: base=10 local=4
        \\.param value={base+local}
        \\rlocal a mid {value}
        \\rglobal mid b {global_derived}
        \\xnested a b inner local={local+1}
        \\.ends
        \\xone top 0 outer local=8
        \\rtop top 0 {base}
        \\.end
    );
    for ([_][]const u8{ "rtop", "r.xone.rlocal", "r.xone.rglobal", "r.xone.xnested.rinner" }, [_]f64{ 2, 18, 6, 19 }) |name, expected| {
        try std.testing.expectEqual(expected, try numeric((try device(nl, name)).positional[0]));
    }
    try std.testing.expectEqual(@as(usize, 2), nl.params.len);
}

test "parameters: sibling subcircuits do not leak local parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseAndElaborate(arena.allocator(),
        \\independent local scopes
        \\.param r=1
        \\.subckt first a b
        \\.param r=2
        \\r1 a b {r}
        \\.ends
        \\.subckt second a b
        \\.param r=3
        \\r1 a b {r}
        \\.ends
        \\x1 a 0 first
        \\x2 b 0 second
        \\rtop c 0 {r}
        \\.end
    );
    for ([_][]const u8{ "r.x1.r1", "r.x2.r1", "rtop" }, [_]f64{ 2, 3, 1 }) |name, expected| {
        try std.testing.expectEqual(expected, try numeric((try device(nl, name)).positional[0]));
    }
}

test "parameters: ngspice power unary logical and ternary precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ngspice parameter expressions: power is left associative, above unary minus.
    const expressions = [_][]const u8{
        "-2**2", "2**3**2", "2*3**2", "1<2?3:4", "1+2*3", "1>2?3:4>3?5:6", "!(1<2)||2>=2&&3!=4", "0?1/0:5", "-2^2", "2^3^2", "0==2<3", "log(exp(2))", "log10(100)", "ln(exp(2))",
    };
    for (expressions, [_]f64{ -4, 64, 18, 3, 7, 5, 1, 5, -4, 64, 1, 2, 2, 2 }) |expression, expected| {
        const src = try std.fmt.allocPrint(arena.allocator(), "precedence\n.param value={s}\nr1 a 0 {{value}}\n.end\n", .{expression});
        const nl = try parseAndElaborate(arena.allocator(), src);
        try std.testing.expectEqual(expected, try numeric((try device(nl, "r1")).positional[0]));
    }
}

test "parameters: recursive definitions fail rather than leave unresolved aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ParseError, parseAndElaborate(arena.allocator(),
        \\parameter cycle
        \\.param a={b+1} b={a-1}
        \\r1 out 0 {a}
        \\.end
    ));
}

test "parameters: disabled stochastic term folds without erasing arbitrary unknowns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disabled = try parseAndElaborate(arena.allocator(),
        \\nominal stochastic switch
        \\.param mc=0
        \\r1 out 0 {1000+mc*agauss(0,1,1)}
        \\.end
    );
    try std.testing.expectEqual(@as(f64, 1000), try numeric((try device(disabled, "r1")).positional[0]));
    const unknown = try parseAndElaborate(arena.allocator(),
        \\unresolved term
        \\.param dummy=1
        \\r1 out 0 {0*missing_parameter}
        \\r2 out 0 r=0*missing_parameter
        \\.end
    );
    try std.testing.expect((try device(unknown, "r1")).positional[0] == .expr);
    try std.testing.expect((try device(unknown, "r2")).kv[0].value == .expr);
    const nonfinite = try parseAndElaborate(arena.allocator(),
        \\nonfinite term
        \\.param zero=0 bad={1/zero}
        \\r1 out 0 {0*bad}
        \\.end
    );
    const value = (try device(nonfinite, "r1")).positional[0];
    if (value == .num) try std.testing.expect(!std.math.isFinite(value.num));
}

test "model bins: scaled geometry selects width and preserves instance fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseAndElaborate(arena.allocator(),
        \\scaled bins
        \\.option scale=1u wnflag=1
        \\.model nm.1 nmos(level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u)
        \\.model nm.2 nmos(level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u)
        \\m1 d g 0 0 nm l=1 w=2 nf=2 ad=4 as=5 pd=6 ps=7 sa=8 sb=9 sd=10
        \\m2 d g 0 0 nm l=1 w=2 nf=2 wnflag=0
        \\.end
    );
    const m1 = try device(nl, "m1");
    try std.testing.expectEqualStrings("nm.1", m1.positional[0].name);
    try std.testing.expectEqualStrings("nm.2", (try device(nl, "m2")).positional[0].name);
    for ([_][]const u8{ "l", "w", "ad", "as", "pd", "ps", "sa", "sb", "sd", "nf" }, [_]f64{ 1e-6, 2e-6, 4e-12, 5e-12, 6e-6, 7e-6, 8e-6, 9e-6, 10e-6, 2 }) |name, expected| {
        try std.testing.expectApproxEqRel(expected, try parameter(m1.kv, name), 1e-12);
    }
    try std.testing.expectEqual(@as(usize, 2), nl.models.len);
}

test "model bins: source order and exact names take precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseAndElaborate(arena.allocator(),
        \\model namespace
        \\.model nm.9 nmos(level=1 lmin=1u lmax=2u wmin=1u wmax=2u)
        \\.model nm.1 nmos(level=1 lmin=1u lmax=2u wmin=1u wmax=2u)
        \\.model exact.1 nmos(level=1 lmin=1u lmax=2u wmin=1u wmax=2u)
        \\.model exact nmos(level=1)
        \\.subckt wrap d g
        \\m1 d g 0 0 nm l=1.5u w=1.5u
        \\.ends
        \\x1 d g wrap
        \\m2 d g 0 0 exact l=9u w=9u
        \\m3 d g 0 0 nm.1 l=9u w=9u
        \\.end
    );
    // ngspice prepends model declarations (inpmkmod.c): last matching bin wins.
    try std.testing.expectEqualStrings("nm.1", (try device(nl, "m.x1.m1")).positional[0].name);
    try std.testing.expectEqualStrings("exact", (try device(nl, "m2")).positional[0].name);
    try std.testing.expectEqualStrings("nm.1", (try device(nl, "m3")).positional[0].name);
}

test "model bins: all four geometry bounds include the one nanometer tolerance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseAndElaborate(arena.allocator(),
        \\bin boundaries
        \\.model nm.0 nmos(level=1 lmin=1u lmax=2u wmin=3u wmax=4u)
        \\m1 d g 0 0 nm l=0.9995u w=3.5u
        \\m2 d g 0 0 nm l=2.0005u w=3.5u
        \\m3 d g 0 0 nm l=1.5u w=2.9995u
        \\m4 d g 0 0 nm l=1.5u w=4.0005u
        \\.end
    );
    for (0..nl.devices.len()) |i| try std.testing.expectEqualStrings("nm.0", nl.devices.get(i).positional[0].name);
    for ([_][]const u8{ "l=0.9985u w=3.5u", "l=2.0015u w=3.5u", "l=1.5u w=2.9985u", "l=1.5u w=4.0015u" }) |geometry| {
        const src = try std.fmt.allocPrint(arena.allocator(), "outside bin\n.model nm.0 nmos(level=1 lmin=1u lmax=2u wmin=3u wmax=4u)\nm1 d g 0 0 nm {s}\n.end\n", .{geometry});
        try std.testing.expectError(error.ModelBinNotFound, parseAndElaborate(arena.allocator(), src));
    }
}

test "model bins: invalid scale cannot silently select unscaled geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "0", "-1", "missing" }) |scale| {
        const src = try std.fmt.allocPrint(arena.allocator(), "invalid scale\n.option scale={s}\n.model nm nmos(level=1)\nm1 d g 0 0 nm l=1u w=1u\n.end\n", .{scale});
        try std.testing.expectError(error.ParseError, parseAndElaborate(arena.allocator(), src));
    }
}

test "parameters: probe names belong to the node and device namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseAndElaborate(arena.allocator(),
        \\probe namespaces
        \\.param out=7 vin=8
        \\vin out 0 dc 1
        \\b1 sense 0 v={v(out)+i(vin)}
        \\.end
    );
    const e = (try device(nl, "b1")).kv[0].value.expr.binop;
    try std.testing.expect(e.a.call.args[0].* == .ident);
    try std.testing.expect(e.b.call.args[0].* == .ident);
    try std.testing.expectEqualStrings("out", e.a.call.args[0].ident);
    try std.testing.expectEqualStrings("vin", e.b.call.args[0].ident);
}

test "elaboration: non-standard instance name in subcircuit expands correctly" {
    // OSDI-era netlists (e.g. VACASK) name MOSFET instances like 'nm' (letter 'n')
    // inside subcircuits. After expansion, the device must still be usable:
    // nodes and model name must be parsed correctly via variable-node-count path.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\wrapper
        \\.model mymod NMOS(level=1 VTO=0.7)
        \\.subckt wrap d g s b
        \\  nm d g s b mymod w=1u l=0.2u
        \\.ends
        \\xm1 out in vdd 0 wrap
        \\vdd vdd 0 1.0
        \\.op
        \\.end
        \\
    ;
    const ast = try Parser(ngspice).parse(arena_state.allocator(), src);
    const nl = try elaborate(arena_state.allocator(), ast);
    const dl = nl.devices;
    var found = false;
    for (0..dl.len()) |i| {
        const d = dl.get(i);
        if (std.mem.indexOf(u8, d.name, "nm") != null) {
            try std.testing.expectEqual(@as(usize, 4), d.nodes.len);
            try std.testing.expectEqual(@as(usize, 1), d.positional.len);
            switch (d.positional[0]) {
                .name => |n| try std.testing.expectEqualStrings("mymod", n),
                else => return error.TestUnexpectedResult,
            }
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "elaboration preserves the AST and scales shared subcircuit instances once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ast = try Parser(ngspice).parse(a,
        \\immutable declarations
        \\.option scale=1u
        \\.param threshold=0.6
        \\.model nm.1 nmos(level=1 vto={threshold} lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u)
        \\.subckt cell d g
        \\m1 d g 0 0 nm l=1 w=2
        \\.ends
        \\x1 a b cell
        \\x2 c d cell
        \\r1 a 0 r=2*500
        \\.end
    );
    for (0..2) |_| {
        const nl = try elaborate(a, ast);
        const mos = nl.devices.bucket('m');
        try std.testing.expectEqual(@as(usize, 2), mos.size());
        for (0..mos.size()) |i| {
            const d = mos.get(i);
            try std.testing.expectEqualStrings("nm.1", d.positional[0].name);
            try std.testing.expectEqual(@as(f64, 1e-6), try parameter(d.kv, "l"));
            try std.testing.expectEqual(@as(f64, 2e-6), try parameter(d.kv, "w"));
        }
        try std.testing.expectEqual(@as(f64, 1000), try parameter(nl.devices.bucket('r').get(0).kv, "r"));
    }
    const original = ast.subcircuits[0].devices[0];
    try std.testing.expectEqualStrings("nm", original.positional[0].name);
    try std.testing.expectEqual(@as(f64, 1), try parameter(original.kv, "l"));
    try std.testing.expectEqual(@as(f64, 2), try parameter(original.kv, "w"));
    try std.testing.expect(ast.models[0].kv[1].value == .expr);
}

test "CPL matrices preserve negative entries after the named coefficient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ast = try Parser(ngspice).parse(a, "* matrix list\n.model line CPL c={3p+0.5p} -0.3p 3.5p length=1+1\n.end\n");
    const nl = try elaborate(a, ast);
    const values = nl.models[0].kv;
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqual(@as(f64, 3.5e-12), values[0].value.num);
    try std.testing.expectEqual(@as(f64, -0.3e-12), values[1].value.num);
    try std.testing.expectEqual(@as(f64, 3.5e-12), values[2].value.num);
    try std.testing.expectEqual(@as(f64, 2), values[3].value.num);
}
