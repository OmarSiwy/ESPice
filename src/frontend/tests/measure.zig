//! Fuzz and allocation-failure tests for measure.zig. `parse` and
//! `parseCheck` take raw bytes and cards built word by word from the
//! `.meas`/`.check` vocabulary; the oracle is no panic, no leak, and an
//! error only from `ParseError`, `OutOfMemory` or the context's own.
const std = @import("std");
const core = @import("core");
const measure = @import("../measure.zig");
const Smith = std.testing.Smith;
const Seeded = @import("seeded.zig").Seeded;

/// Numbers read with `std.fmt.parseFloat`; anything else is a ParseError,
/// which `setValue` keeps as a reference to an earlier result.
const Ctx = struct {
    pub fn measureValue(_: Ctx, t: []const u8) !f64 {
        return std.fmt.parseFloat(f64, t) catch error.ParseError;
    }
    pub fn measureExpr(_: Ctx, t: []const u8) ![]const core.MeasureOp {
        if (t.len == 0) return error.ParseError;
        return &.{.{ .measure = 0 }};
    }
    pub fn measureOption(_: Ctx, _: []const u8) ?f64 {
        return 1;
    }
};

const kinds = [_]?core.query.Kind{ null, .tran, .ac, .dc, .fft, .lstb, .dcmatch, .sp };

fn check(gpa: std.mem.Allocator, text: []const u8, which: u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (which % 4 == 3) {
        var out: std.ArrayList(core.Measure) = .empty;
        var global: ?measure.Levels = null;
        const cards = [_][]const u8{ "check", "dout", "biaschk" };
        // `text` twice, so a `global_level` card reaches the next one.
        for (0..2) |k| measure.parseCheck(a, cards[(which / 4 + k) % cards.len], text, Ctx{}, &global, 1, &out) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.ParseError => {},
        };
        return;
    }
    _ = measure.parse(a, text, Ctx{}, kinds[(which / 4) % kinds.len], which % 2 == 0) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ParseError => {},
    };
}

fn fuzzRaw(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 11]u8 = undefined;
    const which = s.value(u8);
    try check(std.testing.allocator, buf[0..s.slice(&buf)], which);
}

test "fuzz measure: raw bytes parse or fail with a declared error" {
    try std.testing.fuzz({}, fuzzRaw, .{ .corpus = &.{
        "\x00tran tpd trig v(in) val=0.9 rise=1 targ v(out) val=0.9 fall=last",
        "\x01ac g find vdb(out) when vp(out)=-45 cross=1",
        "\x03setup (clk rise 2 fall) a b (1 0 80% 20%)",
    } });
}

/// One word in five is a separator or a stray `=`; the rest are the
/// vocabulary `parse` and `parseCheck` read.
const vocabulary = [_][]const u8{
    "tran",          "ac",            "dc",      "fft",               "lstb",     "dcmatch",     "sp",          "tran_cont",
    "ptdnoise",      "x",             "trig",    "targ",              "delay",    "find",        "when",        "avg",
    "max",           "min_at",        "rms",     "pp",                "integ",    "deriv",       "param='a*2'", "err1",
    "thd",           "jitter",        "em_avg",  "v(a)",              "v(b)",     "vdb(out)",    "vp(out)",     "i(r1)",
    "par('v(a)')",   "lstb(db)",      "lstb(x)", "phase_margin",      "rise=1",   "fall=last",   "cross=2",     "val=0.5",
    "val=v(b)",      "td=1e-9",       "td=trig", "from=0",            "to=t1",    "at=5",        "at=t50",      "goal=1",
    "goal",          ">",             "<",       "2",                 "weight=2", "minval=1",    "nbharm=3",    "binsiz=1e10",
    "maxfreq=1e6",   "last",          "reverse", "print=1",           "=",        "val",         "rise",        "nan",
    "global_level",  "(1 0 80% 20%)", "setup",   "(clk rise 2 fall)", "irdrop",   "(-0.1 1e-9)", "'v(a)'",      "max=2",
    "simulation=tr", "(1 1 0 2 0 1)", "a",       "b*",                "(",        ")",           "{a b}",       "''",
};
const separators = [_][]const u8{ " ", "  ", ",", "\t", " = ", "=" };

fn card(src: anytype, w: *std.Io.Writer) void {
    var first = true;
    while (first or !src.eosWeightedSimple(7, 1)) : (first = false) {
        if (!first) w.writeAll(separators[if (src.eosWeightedSimple(4, 1)) src.index(separators.len) else 0]) catch return;
        w.writeAll(vocabulary[src.index(vocabulary.len)]) catch return;
    }
}

fn fuzzWords(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 11]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const which = s.value(u8);
    card(s, &w);
    try check(std.testing.allocator, w.buffered(), which);
}

test "fuzz measure: cards built from the .meas vocabulary" {
    try std.testing.fuzz({}, fuzzWords, .{});
}

test "measure: 20000 seeded cards parse or fail with a declared error" {
    var prng: std.Random.DefaultPrng = .init(0x3ea5_0001);
    var src: Seeded = .{ .r = prng.random() };
    var buf: [1 << 11]u8 = undefined;
    for (0..20000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        card(&src, &w);
        try check(std.testing.allocator, w.buffered(), prng.random().int(u8));
    }
}

fn parseAll(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try measure.parse(a, "tran d trig v(a) val=1 td=2 rise=1 targ v(b) val=1 rise=1 from=t0", Ctx{}, null, true);
    _ = try measure.parse(a, "ac g find vdb(out) when vp(out)=-45 cross=1", Ctx{}, null, false);
    var out: std.ArrayList(core.Measure) = .empty;
    var global: ?measure.Levels = null;
    try measure.parseCheck(a, "check", "global_level (1 0 80% 20%)", Ctx{}, &global, 1, &out);
    try measure.parseCheck(a, "check", "setup (clk rise 2 fall) a b", Ctx{}, &global, 1, &out);
    try measure.parseCheck(a, "dout", "b c 0.5 (1 1 x 2 0 1)", Ctx{}, &global, 2, &out);
    try measure.parseCheck(a, "biaschk", "'v(a)' max=2 min=-1", Ctx{}, &global, 3, &out);
}

test "measure: parse and parseCheck fail cleanly at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAll, .{});
}
