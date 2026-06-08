const std = @import("std");
const netlist = @import("../netlist.zig");
const lines = netlist.lines;
const source = netlist.source;
const Netlist = netlist.Netlist;
const Value = netlist.Value;

fn parse(arena: std.mem.Allocator, src: []const u8) !Netlist {
    return netlist.parse(arena, src, .ngspice);
}

fn device(nl: Netlist, name: []const u8) !Netlist.View {
    for (0..nl.deviceCount()) |e| {
        const d = nl.device(.from(e));
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return error.MissingDevice;
}

fn numeric(value: Value) !f64 {
    return switch (value) {
        .num => |n| n,
        else => error.UnresolvedConstant,
    };
}

fn parameter(kv: []const netlist.Kv, name: []const u8) !f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, name)) return numeric(item.value);
    return error.MissingParameter;
}

fn pinNames(nl: Netlist, d: Netlist.View, buf: [][]const u8) []const []const u8 {
    for (d.pins, 0..) |v, i| buf[i] = nl.netName(v);
    return buf[0..d.pins.len];
}

test "HDL includes are foreign models; ordinary includes are inert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\test
        \\.hdl "Models/Resistor.va"
        \\.include 'models/diode.vams'
        \\.include "models/common.inc"
        \\.end
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), nl.deck.foreign.len);
    try std.testing.expectEqual(netlist.ForeignKind.verilog_a, nl.deck.foreign[0].kind);
    try std.testing.expectEqualStrings("Models/Resistor.va", nl.deck.foreign[0].path);
    try std.testing.expectEqualStrings("models/diode.vams", nl.deck.foreign[1].path);
    try std.testing.expectEqual(@as(usize, 0), nl.deck.analyses.len);
}

test "case folding SIMD matches W=1 at every boundary" {
    var prng = std.Random.DefaultPrng.init(0xa5c11);
    var src: [257]u8 = undefined;
    var expected: [257]u8 = undefined;
    var actual: [257]u8 = undefined;
    for (0..20) |_| {
        prng.random().bytes(&src);
        inline for (.{ 1, 16, 32, 64 }) |width| for (0..src.len + 1) |n| {
            const count = lines.normalize(1, expected[0..n], src[0..n]);
            try std.testing.expectEqual(count, lines.normalize(width, actual[0..n], src[0..n]));
            try std.testing.expectEqualSlices(u8, expected[0..n], actual[0..n]);
            try std.testing.expectEqual(std.mem.countScalar(u8, src[0..n], '\n'), count);
            for (src[0..n], actual[0..n]) |before, after| try std.testing.expectEqual(std.ascii.toLower(before), after);
        };
    }
}

test "devices are hyperedges over nets in file order; ground is net 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.Io.Writer.Allocating = .init(a);
    try src.writer.writeAll("wide cards\nx1");
    for (0..40) |i| try src.writer.print(" n{d}", .{i});
    try src.writer.writeAll(" wide");
    for (0..20) |i| try src.writer.print(" p{d}={d}", .{ i, i });
    try src.writer.writeAll("\nr2 out gnd 1k\nm1 d g s b nm w=1u\n.subckt wide");
    for (0..40) |i| try src.writer.print(" a{d}", .{i});
    try src.writer.writeAll("\nr1 a0 a39 1\n.ends\n.end\n");
    const nl = try parse(a, src.written());
    try std.testing.expectEqual(@as(u32, 3), nl.deviceCount());
    const x = try device(nl, "r.x1.r1");
    var buf: [8][]const u8 = undefined;
    try std.testing.expectEqualStrings("n0", pinNames(nl, x, &buf)[0]);
    try std.testing.expectEqualStrings("n39", pinNames(nl, x, &buf)[1]);
    const r2 = try device(nl, "r2");
    try std.testing.expectEqual(netlist.ground, r2.pins[1]);
    try std.testing.expectEqual(@as(f64, 1000), try numeric(r2.positional[0]));
    const m1 = try device(nl, "m1");
    try std.testing.expectEqual(@as(usize, 4), m1.pins.len);
    try std.testing.expectEqualStrings("nm", m1.positional[0].name);
    try std.testing.expectEqual('m', nl.device(nl.bucket('m')[0]).kind);
    try std.testing.expectEqual(@as(usize, 2), nl.bucket('r').len);
    try std.testing.expectError(error.ParseError, parse(a, "invalid\n1bad out 0 1k\n"));
}

test "spectre: block comments are stripped span-wise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const strip = lines.spectre.Lines.stripBlockComments;
    try std.testing.expectEqualStrings("r1 a b 1k", try strip(a, "r1 a b 1k"));
    try std.testing.expectEqualStrings("r1  a b  1k", try strip(a, "r1 /*x*/ a b /*y*/ 1k"));
    try std.testing.expectEqualStrings("ad", try strip(a, "a/**//*c*/d"));
    try std.testing.expectEqualStrings("", try strip(a, "/**/"));
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
    const text = try source.load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "R1 out 0 1k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "missing") == null);
    // ngspice ignores the name after `.endl` (GF180 closes `.lib dio` with `.endl diode`).
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\nR2 a 0 1\n.endl ff\n" });
    const renamed = try source.load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(renamed);
    try std.testing.expect(std.mem.indexOf(u8, renamed, "R2 a 0 1") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".endl tt\n" });
    try std.testing.expectError(error.InvalidLibrarySection, source.load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib ff\n.endl ff\n" });
    try std.testing.expectError(error.LibrarySectionNotFound, source.load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.include 'lib.sp'\n.endl tt\n" });
    // An unselected library declaration is inert when included without a corner.
    const inert = try source.load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(inert);
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.lib 'lib.sp' tt\n.endl tt\n" });
    try std.testing.expectError(error.IncludeDepthExceeded, source.load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = "\n* unmatched ' comment\n.include 'Models/res.sp'\n.end\n" });
    const blank_title = try source.load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(blank_title);
    try std.testing.expectEqualStrings("\n* unmatched ' comment\nR1 out 0 1k\n\n.end\n\n", blank_title);
    // Include-free input is returned byte-for-byte, including CRLF and no final LF.
    const plain = ".include is only the title\r\n* .lib 'comment\r\nR1 out 0 1k\r\n.end";
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = plain });
    const unchanged = try source.load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(plain, unchanged);
}

test "parameters: unsigned and signed exponents preserve following operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
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
    const nl = try parse(arena.allocator(),
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
    try std.testing.expectEqualStrings("nm", (try device(nl, "m1")).model.?.name);
}

test "parameters: global definitions keep their scope under nested overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ngspice: Rtop=2, Rlocal=18, Rglobal=6, Rinner=19.
    const nl = try parse(arena.allocator(),
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
    const inner = try device(nl, "r.xone.xnested.rinner");
    var buf: [2][]const u8 = undefined;
    try std.testing.expectEqualStrings("top", pinNames(nl, inner, &buf)[0]);
    try std.testing.expectEqualStrings("xone.mid", nl.netName((try device(nl, "r.xone.rlocal")).pins[1]));
    try std.testing.expectEqual(@as(u32, 2), inner.subckt_instance);
}

test "parameters: sibling subcircuits do not leak local parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
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

test "subcircuit models that need instance parameters are read per instance and shared when equal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\instance models
        \\.param shift=1
        \\.subckt cell d g s pre=1 w=1u
        \\m1 d g s s nm w=w l=1u
        \\.model nm nmos level=1 vto='shift+(1-pre)*0.5' kp='2e-5*w/1u'
        \\.ends
        \\x1 a b 0 cell
        \\x2 a b 0 cell pre=0
        \\x3 a b 0 cell
        \\x4 a b 0 cell w=2u
        \\.end
    );
    for ([_][]const u8{ "m.x1.m1", "m.x2.m1", "m.x3.m1", "m.x4.m1" }, [_]f64{ 1, 1.5, 1, 1 }, [_]f64{ 2e-5, 2e-5, 2e-5, 4e-5 }) |name, vto, kp| {
        const m = (try device(nl, name)).model.?;
        try std.testing.expectEqual(vto, try parameter(m.kv, "vto"));
        try std.testing.expectApproxEqRel(kp, try parameter(m.kv, "kp"), 1e-12);
    }
    // The unresolved global row, then one row per distinct parameter set.
    try std.testing.expectEqual(@as(usize, 4), nl.models.len);
}

// ngspice renames a subcircuit's models per instance and translates only
// its own body's references (subckt.c modtranslate): the top level and a
// nested instance of another subcircuit see the global card.
test "subcircuit models are visible only to their own body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\local model scope
        \\.subckt inner a b
        \\d1 a b dm
        \\.ends
        \\.subckt outer a b isv=1e-12
        \\.model dm d is={isv}
        \\x1 a b inner
        \\d2 a b dm
        \\.ends
        \\.model dm d is=1e-14
        \\x0 1 0 outer isv=1e-13
        \\d3 1 0 dm
        \\.end
    );
    for ([_][]const u8{ "d.x0.x1.d1", "d.x0.d2", "d3" }, [_]f64{ 1e-14, 1e-13, 1e-14 }) |name, is| {
        try std.testing.expectEqual(is, try parameter((try device(nl, name)).model.?.kv, "is"));
    }
}

test "a subcircuit .model under .if applies only to the instances that keep it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\conditional models
        \\.subckt cell a b sel=0
        \\d1 a b dm
        \\.if (sel == 1)
        \\.model dm d is=1e-12
        \\.else
        \\.model dm d is=1e-14
        \\.endif
        \\.ends
        \\x1 1 0 cell sel=1
        \\x2 1 0 cell
        \\.end
    );
    try std.testing.expectEqual(@as(f64, 1e-12), try parameter((try device(nl, "d.x1.d1")).model.?.kv, "is"));
    try std.testing.expectEqual(@as(f64, 1e-14), try parameter((try device(nl, "d.x2.d1")).model.?.kv, "is"));
}

test "model bins: a subcircuit's own bins are picked and read per instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\local bins
        \\.subckt cell d g vt=0.5 w0=1u
        \\m1 d g 0 0 nm l=1u w=w0
        \\.model nm.1 nmos level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u vto=vt
        \\.model nm.2 nmos level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u vto='vt+1'
        \\.ends
        \\x1 d g cell
        \\x2 d g cell vt=0.7 w0=2u
        \\.end
    );
    for ([_][]const u8{ "m.x1.m1", "m.x2.m1" }, [_][]const u8{ "nm.1", "nm.2" }, [_]f64{ 0.5, 1.7 }) |name, bin, vto| {
        const m = try device(nl, name);
        try std.testing.expectEqualStrings(bin, m.positional[0].name);
        try std.testing.expectEqualStrings(bin, m.model.?.name);
        try std.testing.expectApproxEqRel(vto, try parameter(m.model.?.kv, "vto"), 1e-12);
    }
}

test ".if chains keep the first true branch, per subcircuit instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\ngspice .if/.elseif/.else/.endif
        \\.param top=2
        \\.subckt rr a b r0=1k sel=0
        \\.if (sel == 0)
        \\r1 a b 'r0'
        \\.elseif (sel == 1)
        \\.if (r0 > 5k)
        \\r1 a b 7
        \\.else
        \\r1 a b '2*r0'
        \\.endif
        \\.else
        \\r1 a b 5
        \\.endif
        \\.ends
        \\x0 a 0 rr
        \\x1 b 0 rr sel=1
        \\x2 c 0 rr sel=2
        \\x3 d 0 rr sel=1 r0=10k
        \\.if (top > 3)
        \\rgone e 0 1
        \\.elseif (top == 2)
        \\rtop e 0 3
        \\.else
        \\rgone2 e 0 1
        \\.endif
        \\.end
    );
    try std.testing.expectEqual(5, nl.deviceCount());
    for ([_][]const u8{ "r.x0.r1", "r.x1.r1", "r.x2.r1", "r.x3.r1", "rtop" }, [_]f64{ 1e3, 2e3, 5, 7, 3 }) |name, expected| {
        try std.testing.expectEqual(expected, try numeric((try device(nl, name)).positional[0]));
    }
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    try std.testing.expectError(error.ParseError, parse(arena2.allocator(), "t\n.if (1)\nr1 a 0 1\n.end\n"));
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
        const nl = try parse(arena.allocator(), src);
        try std.testing.expectEqual(expected, try numeric((try device(nl, "r1")).positional[0]));
    }
}

test "parameters: recursive definitions fail rather than leave unresolved aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ParseError, parse(arena.allocator(),
        \\parameter cycle
        \\.param a={b+1} b={a-1}
        \\r1 out 0 {a}
        \\.end
    ));
}

test "parameters: disabled stochastic term folds without erasing arbitrary unknowns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disabled = try parse(arena.allocator(),
        \\nominal stochastic switch
        \\.param mc=0
        \\r1 out 0 {1000+mc*agauss(0,1,1)}
        \\.model nm nmos(level=1 vto={0.7+0*l*w})
        \\.end
    );
    try std.testing.expectEqual(@as(f64, 1000), try numeric((try device(disabled, "r1")).positional[0]));
    // 7 * 0.1: ngspice INPevaluate bits, not the correctly rounded 0.7.
    try std.testing.expectEqual(@as(f64, 7) * @as(f64, 0.1), try parameter(disabled.models[0].kv, "vto"));
    const unknown = try parse(arena.allocator(),
        \\unresolved term
        \\.param dummy=1
        \\r1 out 0 {0*missing_parameter}
        \\r2 out 0 r=0*missing_parameter
        \\r3 out 0 {0*l}
        \\.end
    );
    try std.testing.expect((try device(unknown, "r1")).positional[0] == .expr);
    try std.testing.expect((try device(unknown, "r2")).kv[0].value == .expr);
    try std.testing.expect((try device(unknown, "r3")).positional[0] == .expr);
    const nonfinite = try parse(arena.allocator(),
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
    const nl = try parse(arena.allocator(),
        \\scaled bins
        \\.option scale=1u wnflag=1
        \\.model nm.1 nmos(level=1 lmin=0.9u lmax=1.1u wmin=0.9u wmax=1.1u)
        \\.model nm.2 nmos(level=1 lmin=0.9u lmax=1.1u wmin=1.9u wmax=2.1u)
        \\.subckt cell d g
        \\m1 d g 0 0 nm l=1 w=2 nf=2 ad=4 as=5 pd=6 ps=7 sa=8 sb=9 sd=10
        \\.ends
        \\x1 a b cell
        \\x2 c d cell
        \\m2 d g 0 0 nm l=1 w=2 nf=2 wnflag=0
        \\.end
    );
    for ([_][]const u8{ "m.x1.m1", "m.x2.m1" }) |name| {
        const m1 = try device(nl, name);
        try std.testing.expectEqualStrings("nm.1", m1.positional[0].name);
        try std.testing.expectEqualStrings("nm.1", m1.model.?.name);
        for ([_][]const u8{ "l", "w", "ad", "as", "pd", "ps", "sa", "sb", "sd", "nf" }, [_]f64{ 1e-6, 2e-6, 4e-12, 5e-12, 6e-6, 7e-6, 8e-6, 9e-6, 10e-6, 2 }) |key, expected| {
            try std.testing.expectApproxEqRel(expected, try parameter(m1.kv, key), 1e-12);
        }
    }
    try std.testing.expectEqualStrings("nm.2", (try device(nl, "m2")).positional[0].name);
    try std.testing.expectEqual(@as(usize, 2), nl.models.len);
}

test "model bins: source order and exact names take precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
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
    const nl = try parse(arena.allocator(),
        \\bin boundaries
        \\.model nm.0 nmos(level=1 lmin=1u lmax=2u wmin=3u wmax=4u)
        \\m1 d g 0 0 nm l=0.9995u w=3.5u
        \\m2 d g 0 0 nm l=2.0005u w=3.5u
        \\m3 d g 0 0 nm l=1.5u w=2.9995u
        \\m4 d g 0 0 nm l=1.5u w=4.0005u
        \\.end
    );
    for (0..nl.deviceCount()) |e| try std.testing.expectEqualStrings("nm.0", nl.device(.from(e)).positional[0].name);
    for ([_][]const u8{ "l=0.9985u w=3.5u", "l=2.0015u w=3.5u", "l=1.5u w=2.9985u", "l=1.5u w=4.0015u" }) |geometry| {
        const src = try std.fmt.allocPrint(arena.allocator(), "outside bin\n.model nm.0 nmos(level=1 lmin=1u lmax=2u wmin=3u wmax=4u)\nm1 d g 0 0 nm {s}\n.end\n", .{geometry});
        try std.testing.expectError(error.ModelBinNotFound, parse(arena.allocator(), src));
    }
}

test "model bins: invalid scale cannot silently select unscaled geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "0", "-1", "missing" }) |scale| {
        const src = try std.fmt.allocPrint(arena.allocator(), "invalid scale\n.option scale={s}\n.model nm nmos(level=1)\nm1 d g 0 0 nm l=1u w=1u\n.end\n", .{scale});
        try std.testing.expectError(error.ParseError, parse(arena.allocator(), src));
    }
}

test "behavioural sources keep postfix with probe nets mapped through the subcircuit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\probe namespaces
        \\.param out=7 vin=8 k=3
        \\vin out 0 dc 1
        \\b1 sense 0 v={v(out)+i(vin)}
        \\.subckt amp in
        \\b2 o 0 v=k*v(in,mid)
        \\.ends
        \\xa out amp
        \\.end
    );
    const b1 = (try device(nl, "b1")).kv[0].value.expr;
    const ops = nl.exprOps(b1);
    try std.testing.expectEqual(netlist.expr.Code.vprobe, ops[0].code);
    try std.testing.expectEqualStrings("out", nl.netName(.from(ops[0].a)));
    try std.testing.expectEqual(netlist.expr.Code.iprobe, ops[1].code);
    try std.testing.expectEqual(netlist.expr.Code.add, ops[2].code);
    const b2 = nl.exprOps((try device(nl, "b.xa.b2")).kv[0].value.expr);
    try std.testing.expectEqual(@as(f64, 3), nl.consts[b2[0].a]);
    try std.testing.expectEqualStrings("out", nl.netName(.from(b2[1].a)));
    try std.testing.expectEqualStrings("xa.mid", nl.netName(.from(b2[1].b)));
    try std.testing.expectEqual(netlist.expr.Code.mul, b2[2].code);
}

test "non-standard instance letters read a variable terminal list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\wrapper
        \\.model mymod NMOS(level=1 VTO=0.7)
        \\.subckt wrap d g s b
        \\  nm d g s b mymod w=1u l=0.2u
        \\.ends
        \\xm1 out in vdd 0 wrap
        \\q1 c b e 0 mymod
        \\m2 d g s mymod
        \\.end
        \\
    );
    const nm = try device(nl, "n.xm1.nm");
    try std.testing.expectEqual(@as(usize, 4), nm.pins.len);
    try std.testing.expectEqualStrings("mymod", nm.positional[0].name);
    try std.testing.expectEqual(@as(usize, 4), (try device(nl, "q1")).pins.len);
    try std.testing.expectEqualStrings("mymod", (try device(nl, "q1")).positional[0].name);
    try std.testing.expectEqual(@as(usize, 3), (try device(nl, "m2")).pins.len);
}

test "CPL matrices preserve negative entries after the named coefficient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(), "* matrix list\n.model line CPL c={3p+0.5p} -0.3p 3.5p length=1+1\n.end\n");
    const values = nl.models[0].kv;
    try std.testing.expectEqual(@as(usize, 4), values.len);
    try std.testing.expectEqual(@as(f64, 3.5e-12), values[0].value.num);
    // 3 * 1e-13: ngspice INPevaluate bits, not the correctly rounded -0.3e-12.
    try std.testing.expectEqual(@as(f64, -3) * @as(f64, 1e-13), values[1].value.num);
    try std.testing.expectEqual(@as(f64, 3.5e-12), values[2].value.num);
    try std.testing.expectEqual(@as(f64, 2), values[3].value.num);
}

test "analysis cards resolve output nets; a numeric reference is a net" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parse(arena.allocator(),
        \\analyses
        \\r1 in 2 1k
        \\r2 2 0 1k
        \\.ic v(2)=0.25 v(missing)=1
        \\.tf v(in, 2) r1
        \\.four 1k v(2)
        \\.pz in 0 2 gnd vol pz
        \\.options temp=85
        \\.temp 50
        \\.end
    );
    try std.testing.expectEqual(@as(usize, 4), nl.deck.analyses.len);
    const in = nl.deck.analyses[0].pos;
    try std.testing.expectEqualStrings("in", nl.netName(.from(in)));
    try std.testing.expectEqualStrings("2", nl.netName(.from(nl.deck.analyses[0].neg)));
    try std.testing.expectEqual(nl.deck.analyses[0].neg, nl.deck.analyses[1].pos);
    try std.testing.expectEqual([4]u32{ in, 0, nl.deck.analyses[0].neg, 0 }, nl.deck.analyses[2].ports);
    try std.testing.expectEqual(@as(usize, 1), nl.deck.ic.len);
    try std.testing.expectEqual(@as(f64, 0.25), nl.deck.ic[0].value);
    try std.testing.expectEqual(@as(usize, 2), nl.deck.config.len);
    try std.testing.expect(nl.deck.config[1].temp);
}
