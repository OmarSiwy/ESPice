const std = @import("std");
const ir = @import("types.zig");
const Parser = @import("parser.zig").Parser(@import("tokenizer.zig").ngspice);

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
    const nl = try Parser.parse(arena.allocator(),
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
    const nl = try Parser.parse(arena.allocator(),
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
    const nl = try Parser.parse(arena.allocator(),
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
    for ([_][]const u8{ "rtop", "rlocal.xone", "rglobal.xone", "rinner.xnested.xone" }, [_]f64{ 2, 18, 6, 19 }) |name, expected| {
        try std.testing.expectEqual(expected, try numeric((try device(nl, name)).positional[0]));
    }
    try std.testing.expectEqual(@as(usize, 2), nl.params.len);
}

test "parameters: sibling subcircuits do not leak local parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try Parser.parse(arena.allocator(),
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
    for ([_][]const u8{ "r1.x1", "r1.x2", "rtop" }, [_]f64{ 2, 3, 1 }) |name, expected| {
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
        const nl = try Parser.parse(arena.allocator(), src);
        try std.testing.expectEqual(expected, try numeric((try device(nl, "r1")).positional[0]));
    }
}

test "parameters: recursive definitions fail rather than leave unresolved aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ParseError, Parser.parse(arena.allocator(),
        \\parameter cycle
        \\.param a={b+1} b={a-1}
        \\r1 out 0 {a}
        \\.end
    ));
}

test "parameters: disabled stochastic term folds without erasing arbitrary unknowns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disabled = try Parser.parse(arena.allocator(),
        \\nominal stochastic switch
        \\.param mc=0
        \\r1 out 0 {1000+mc*agauss(0,1,1)}
        \\.end
    );
    try std.testing.expectEqual(@as(f64, 1000), try numeric((try device(disabled, "r1")).positional[0]));
    const unknown = try Parser.parse(arena.allocator(),
        \\unresolved term
        \\.param dummy=1
        \\r1 out 0 {0*missing_parameter}
        \\r2 out 0 r=0*missing_parameter
        \\.end
    );
    try std.testing.expect((try device(unknown, "r1")).positional[0] == .expr);
    try std.testing.expect((try device(unknown, "r2")).kv[0].value == .expr);
    const nonfinite = try Parser.parse(arena.allocator(),
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
    const nl = try Parser.parse(arena.allocator(),
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
    const nl = try Parser.parse(arena.allocator(),
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
    try std.testing.expectEqualStrings("nm.1", (try device(nl, "m1.x1")).positional[0].name);
    try std.testing.expectEqualStrings("exact", (try device(nl, "m2")).positional[0].name);
    try std.testing.expectEqualStrings("nm.1", (try device(nl, "m3")).positional[0].name);
}

test "model bins: all four geometry bounds include the one nanometer tolerance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try Parser.parse(arena.allocator(),
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
        try std.testing.expectError(error.ModelBinNotFound, Parser.parse(arena.allocator(), src));
    }
}

test "model bins: invalid scale cannot silently select unscaled geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "0", "-1", "missing" }) |scale| {
        const src = try std.fmt.allocPrint(arena.allocator(), "invalid scale\n.option scale={s}\n.model nm nmos(level=1)\nm1 d g 0 0 nm l=1u w=1u\n.end\n", .{scale});
        try std.testing.expectError(error.ParseError, Parser.parse(arena.allocator(), src));
    }
}

test "parameters: probe names belong to the node and device namespaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try Parser.parse(arena.allocator(),
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
