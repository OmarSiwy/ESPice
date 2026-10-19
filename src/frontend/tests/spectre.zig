//! Fuzz, depth and allocation-failure tests for spectre.zig's `translate`.
//! The oracle: no panic, no leak, an error only from `spectre.Error`, and
//! on success one letter per card.
const std = @import("std");
const spectre = @import("../spectre.zig");
const Smith = std.testing.Smith;
const Seeded = @import("seeded.zig").Seeded;

fn check(gpa: std.mem.Allocator, in: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = spectre.translate(arena.allocator(), in) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ParseError, error.UnsupportedCard => return,
    };
    try std.testing.expectEqual(out.lines.len, out.kinds.len);
}

/// Statements and fragments of them; a generated line is up to four.
const vocabulary = [_][]const u8{
    "r1 (a 0) resistor r=1k",                      "v1 (in 0) vsource dc=1 mag=1 type=pulse val0=0 val1=1 period=1n",
    "c1 a 0 capacitor c=1p",                       "model nm bsim4 type=n vth0=0.4",
    "m1 (d g s b) nm w=1u l=100n",                 "parameters a=1 b=2*a c",
    "subckt inv (in out)",                         "ends inv",
    "x1 (a b) inv",                                "tran1 tran stop=1u step=1n method=gear2 skipdc=yes",
    "dc1 dc dev=v1 start=0 stop=1 step=0.1",       "ac1 ac start=1 stop=1g dec=10",
    "if (a > 1) {",                                "} else {",
    "}",                                           "if (a) r2 (a 0) resistor r=1 else r3 (a 0) resistor r=2",
    "real f(real x) { return x*2 }",               "real g(real x, real y) {",
    "return x+y",                                  "statistics {",
    "process {",                                   "model g bsim3v3 {",
    "1: type=n lmin=0 lmax=1",                     "simulator lang=spice",
    "simulator lang=spectre",                      "r9 a 0 1k",
    "global 0 vdd",                                "ic a=1 b=2",
    "save a b:p",                                  "ahdl_include \"m.va\"",
    "opts options reltol=1e-3 temp=27",            "x (",
    "= =",                                         "a ** b ** -c",
    "pwl1 (a 0) vsource type=pwl wave=[0 0 1n 1]", "(c=1p)",
    "fmod(7, 3) ? 1 : 2",                          "[1, 2, (3)]",
    "\"str",                                       "a & b",
    "inline subckt cell a b",                      "n1 noise iprobe=v1 start=1 stop=1k dec=1",
};

fn line(src: anytype, w: *std.Io.Writer) void {
    var first = true;
    while (first or !src.eosWeightedSimple(3, 1)) : (first = false) {
        if (!first) w.writeAll(" ") catch return;
        w.writeAll(vocabulary[src.index(vocabulary.len)]) catch return;
    }
}

fn deck(src: anytype, gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var in: std.ArrayList([]const u8) = .empty;
    while (!src.eosWeightedSimple(7, 1)) {
        var buf: [1 << 10]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        line(src, &w);
        try in.append(arena.allocator(), try arena.allocator().dupe(u8, w.buffered()));
    }
    try check(gpa, in.items);
}

fn fuzzDeck(_: void, s: *Smith) anyerror!void {
    try deck(s, std.testing.allocator);
}

test "fuzz spectre.translate: decks built from statements" {
    std.testing.log_level = .err;
    try std.testing.fuzz({}, fuzzDeck, .{});
}

fn fuzzRaw(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 11]u8 = undefined;
    const text = buf[0..s.slice(&buf)];
    var lines: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| : (n += 1) {
        if (n == lines.len) break;
        lines[n] = l;
    }
    try check(std.testing.allocator, lines[0..n]);
}

test "fuzz spectre.translate: raw lines" {
    std.testing.log_level = .err;
    try std.testing.fuzz({}, fuzzRaw, .{ .corpus = &.{ "r1 (a 0) resistor r=1k\nv1 (a 0) vsource dc=1", "if (a) {\nr1 (a 0) resistor r=1\n}" } });
}

test "spectre: 5000 seeded decks translate or fail with a declared error" {
    std.testing.log_level = .err;
    var prng: std.Random.DefaultPrng = .init(0x5bec_0001);
    var src: Seeded = .{ .r = prng.random() };
    for (0..5000) |_| try deck(&src, std.testing.allocator);
}

test "spectre: input-controlled nesting is a ParseError, not a stack overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 100_000;
    var parens: std.ArrayList(u8) = .empty;
    try parens.appendSlice(a, "parameters p=");
    try parens.appendNTimes(a, '(', n);
    try parens.append(a, '1');
    try parens.appendNTimes(a, ')', n);
    var unary: std.ArrayList(u8) = .empty;
    try unary.appendSlice(a, "parameters p=");
    try unary.appendNTimes(a, '-', n);
    try unary.append(a, '1');
    var power: std.ArrayList(u8) = .empty;
    try power.appendSlice(a, "parameters p=1");
    for (0..n) |_| try power.appendSlice(a, "**1");
    var ifs: std.ArrayList(u8) = .empty;
    for (0..n) |_| try ifs.appendSlice(a, "if (1) ");
    try ifs.appendSlice(a, "r1 (a 0) resistor r=1");
    for ([_][]const u8{ parens.items, unary.items, power.items, ifs.items }) |text|
        try std.testing.expectError(error.ParseError, spectre.translate(a, &.{text}));
    // Realistic nesting still reads.
    _ = try spectre.translate(a, &.{"if (1) if (1) r1 (a 0) resistor r=((((1))))"});
}

fn translateDeck(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = try spectre.translate(arena.allocator(), &.{
        "parameters w=1u",
        "model nm bsim4 type=n",
        "subckt inv (in out) ",
        "parameters k=2",
        "m1 (out in 0 0) nm w=w*k",
        "ends inv",
        "x1 (a b) inv",
        "v1 (a 0) vsource type=pwl wave=[0 0 1n 1]",
        "if (w > 0) {",
        "r1 (a 0) resistor r=1k",
        "} else {",
        "r1 (a 0) resistor r=2k",
        "}",
        "tran1 tran stop=1u",
    });
}

test "spectre: translate fails cleanly at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, translateDeck, .{});
}
