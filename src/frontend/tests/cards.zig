//! Card-level tests of `netlist.parse`: one directive or element form per
//! test, each expected value worked by hand from the card's manual
//! semantics (cited per test), with the boundary and refusal of each form.
const std = @import("std");
const netlist = @import("../netlist.zig");
const Netlist = netlist.Netlist;
const Dialect = netlist.Dialect;

fn parseIn(arena: std.mem.Allocator, dialect: Dialect, src: []const u8) !Netlist {
    return netlist.parse(arena, src, dialect);
}

fn device(nl: Netlist, name: []const u8) !Netlist.View {
    for (0..nl.deviceCount()) |e| {
        const d = nl.device(.from(e));
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return error.MissingDevice;
}

fn kvNum(kv: []const netlist.Kv, key: []const u8) !f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
        .num => |n| n,
        else => error.NotANumber, // else: any other value is no number
    };
    return error.MissingKey;
}

/// Asserts each deck fails with `err` in `dialect`.
fn expectRefused(dialect: Dialect, err: anyerror, decks: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (decks) |src| {
        if (parseIn(arena.allocator(), dialect, src)) |_| {
            std.debug.print("accepted: {s}\n", .{src});
            return error.TestUnexpectedResult;
        } else |got| if (got != err) {
            std.debug.print("{s} (want {s}): {s}\n", .{ @errorName(got), @errorName(err), src });
            return error.TestUnexpectedResult;
        }
    }
}

test ".four naming several outputs is one card per output, numbers kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .ngspice, "t\nr1 a b 1\nr2 b 0 1\n.four 1k v(a) v(b) 3\n.four 2k v(a)\n");
    const as = nl.deck.analyses;
    try std.testing.expectEqual(@as(usize, 3), as.len);
    for (as[0..2], [_][]const u8{ "a", "b" }) |a, net| {
        try std.testing.expect(a.kind == .four and a.split);
        try std.testing.expectEqual(@as(usize, 3), a.args.len);
        try std.testing.expectEqual(@as(f64, 1000), a.args[0].num);
        try std.testing.expectEqualStrings(net, a.args[1].group.args()[0].name);
        try std.testing.expectEqual(@as(f64, 3), a.args[2].num);
    }
    // `pos` is the output net, resolved per card.
    try std.testing.expect(as[0].pos != as[1].pos and as[0].pos != netlist.none);
    try std.testing.expect(!as[2].split);
}

test "MONTE=list expands its a:b ranges; counts are positive integers [CR .DC]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try parseIn(a, .hspice, "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(2 4:6)\n");
    const m = nl.deck.analyses[0].sweep.monte;
    try std.testing.expectEqual(@as(u32, 4), m.n);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 5, 6 }, m.list);
    nl = try parseIn(a, .hspice, "t\nr1 a 0 1\n.tran 1n 10n sweep monte=3 firstrun=2\n");
    try std.testing.expectEqual(netlist.Monte{ .n = 3, .first = 2 }, nl.deck.analyses[0].sweep.monte);
    try expectRefused(.hspice, error.ParseError, &.{
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(0)\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(5:3)\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(1.5)\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=0\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=2.5\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=3 firstrun\n",
        // Each range is small; together they name more trials than any run.
        "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(1:600000 1:600000)\n",
    });
    // A million trials in all is the limit.
    nl = try parseIn(a, .hspice, "t\nr1 a 0 1\n.tran 1n 10n sweep monte=list(1:524288 1:524288)\n");
    try std.testing.expectEqual(@as(u32, 1 << 20), nl.deck.analyses[0].sweep.monte.n);
}

test ".step grids: dec and oct per decade or octave, lin by increment; poi refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const f64 }{
        .{ ".step dec param p 1 100 1", &.{ 1, 10, 100 } },
        .{ ".step oct param p 1 4 1", &.{ 1, 2, 4 } },
        .{ ".step param p 1 2 0.5", &.{ 1, 1.5, 2 } },
        .{ ".step param p list 3 1", &.{ 3, 1 } },
    };
    for (cases) |c| {
        const src = try a.print("t\n.param p=1\nr1 a 0 {{p}}\n{s}\n", .{c[0]});
        const nl = try parseIn(a, .ngspice, src);
        const values = nl.deck.steps[0].values;
        try std.testing.expectEqual(c[1].len, values.len);
        for (c[1], values) |want, got| try std.testing.expectApproxEqRel(want, got, 1e-12);
    }
    try expectRefused(.ngspice, error.ParseError, &.{
        "t\n.param p=1\n.step poi param p 1 2\n",
        "t\n.param p=1\n.step param p 1 2\n",
        "t\n.param p=1\n.step param p 1 2 0\n",
    });
}

test "HSPICE sweep tails: lin by count, poi by list, .dc over a bare .param (#94)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try parseIn(a, .hspice, "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p lin 3 1 2\n");
    try std.testing.expectEqualSlices(f64, &.{ 1, 1.5, 2 }, nl.deck.analyses[0].sweep.step.values);
    nl = try parseIn(a, .hspice, "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p poi 2 1 5\n");
    try std.testing.expectEqualSlices(f64, &.{ 1, 5 }, nl.deck.analyses[0].sweep.step.values);
    nl = try parseIn(a, .hspice, "t\n.param p=1\nr1 a 0 p\n.dc p 1 3 1\n");
    const dc = nl.deck.analyses[0];
    try std.testing.expectEqual(@as(usize, 0), dc.args.len);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, dc.sweep.step.values);
    try std.testing.expectEqualStrings("p", nl.live.names[dc.sweep.step.target.param]);
    nl = try parseIn(a, .hspice, "t\nr1 a 0 1\n.data d\nx\n1\n.enddata\n.tran 1n 10n sweep data=d\n");
    try std.testing.expectEqualStrings("d", nl.deck.analyses[0].sweep.data);
    try expectRefused(.hspice, error.ParseError, &.{
        "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p poi 3 1 5\n",
        "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p lin 0 1 2\n",
        "t\n.param p=1\nr1 a 0 p\n.tran 1n 10n sweep p bogus 3 1 2\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep data=d extra\n",
        "t\nr1 a 0 1\n.tran 1n 10n sweep\n",
    });
}

test ".mosra reads its keys; SimMode 1 and unknown keys are refused [SA Ch.29]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .hspice, "t\nr1 a 0 1\n.mosra reltotaltime=10 relstep=1 simmode=0 relmode=2 degf=0.1\n");
    const m = nl.deck.mosra.?;
    try std.testing.expectEqual(@as(f64, 10), m.rel_total_time);
    try std.testing.expectEqual(@as(f64, 1), m.rel_step);
    try std.testing.expect(!m.aged_runs);
    try std.testing.expectEqual(@as(u2, 2), m.rel_mode);
    try std.testing.expectEqual(@as(?f64, 0.1), m.deg_f);
    try expectRefused(.hspice, error.UnsupportedCard, &.{
        "t\nr1 a 0 1\n.mosra reltotaltime=10 simmode=1\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=10 dec=1\n",
    });
    try expectRefused(.hspice, error.ParseError, &.{
        "t\nr1 a 0 1\n.mosra reltotaltime=10 relmode=3\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=0\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=10 agingstart=2 agingstop=1\n",
        "t\nr1 a 0 1\n.mosra reltotaltime=10 relstep\n",
    });
}

test ".sample: FS positive, MAXFLD at least 1, BETA in [0, 1] [CR .SAMPLE]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .hspice, "t\nr1 a 0 1\n.sample fs=1g maxfld=4 beta=0.5 tol=1m\n");
    try std.testing.expectEqual(@import("core").query.NoiseSample{ .fs = 1e9, .max_fold = 4, .beta = 0.5 }, nl.deck.sample.?);
    try expectRefused(.hspice, error.ParseError, &.{
        "t\nr1 a 0 1\n.sample fs=0\n",
        "t\nr1 a 0 1\n.sample fs=1g beta=2\n",
        "t\nr1 a 0 1\n.sample fs=1g maxfld=0.5\n",
        "t\nr1 a 0 1\n.sample fs=1g tol\n",
        "t\nr1 a 0 1\n.sample fs=1g bogus=1\n",
    });
}

test "HSPICE .save is the operating-point save; ngspice .save lists outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nl = try parseIn(a, .hspice, "t\nr1 a 0 1\n.save type=ic level=top time=1n file='Op.ic'\n");
    const s = nl.deck.save_op.?;
    try std.testing.expect(s.ic and s.top_only);
    try std.testing.expectEqual(@as(f64, 1e-9), s.time);
    try std.testing.expectEqualStrings("Op.ic", s.file.?); // the path keeps its case
    nl = try parseIn(a, .hspice, "t\nr1 a 0 1\n.save type=ic\n.save level=none\n");
    try std.testing.expectEqual(@as(?@import("core").SaveOp, null), nl.deck.save_op);
    nl = try parseIn(a, .ngspice, "t\nr1 a 0 1\n.save v(A) i(R1) x\n");
    try std.testing.expectEqual(@as(usize, 2), nl.deck.saves.len);
    try std.testing.expectEqualStrings("v(a)", nl.deck.saves[0]);
    try std.testing.expectEqualStrings("i(r1)", nl.deck.saves[1]);
    nl = try parseIn(a, .ngspice, "t\nr1 a 0 1\n.save v(a)\n.save all\n");
    try std.testing.expectEqual(@as(usize, 0), nl.deck.saves.len);
    try expectRefused(.hspice, error.ParseError, &.{
        "t\nr1 a 0 1\n.save time=-1\n",
        "t\nr1 a 0 1\n.save type=foo\n",
        "t\nr1 a 0 1\n.save level=some\n",
        "t\nr1 a 0 1\n.save bogus=1\n",
        "t\nr1 a 0 1\n.save type\n",
    });
}

test "shunt options add one R or C per net to ground [CR Ch.3]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .ngspice, "t\nr1 a b 1\nr2 b 0 1\n.options gshunt=1e-12 cshunt=1p rshunt=1e9\n");
    // Nets a and b, three shunts each, after the two cards.
    try std.testing.expectEqual(@as(u32, 2 + 2 * 3), nl.deviceCount());
    const g = try device(nl, "r.gshunt.a");
    try std.testing.expectEqual(@as(f64, 1e12), g.positional[0].num);
    try std.testing.expectEqual(netlist.ground, g.pins[1]);
    try std.testing.expectEqual(@as(f64, 1e-12), (try device(nl, "c.cshunt.b")).positional[0].num);
    try std.testing.expectEqual(@as(f64, 1e9), (try device(nl, "r.rshunt.b")).positional[0].num);
    // A zero shunt adds nothing.
    const none_added = try parseIn(arena.allocator(), .ngspice, "t\nr1 a 0 1\n.options gshunt=0\n");
    try std.testing.expectEqual(@as(u32, 1), none_added.deviceCount());
}

test ".ic and .dcvolt keep nets some card names, never ground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .ngspice, "t\nr1 a b 1\n.ic v(a)=1 v(0)=2 v(nosuch)=3 v(b)=x\n.dcvolt b 2\n.nodeset v(a)=0.5\n");
    try std.testing.expectEqual(@as(usize, 2), nl.deck.ic.len);
    try std.testing.expectEqualStrings("a", nl.netName(nl.deck.ic[0].net));
    try std.testing.expectEqual(@as(f64, 1), nl.deck.ic[0].value);
    try std.testing.expectEqualStrings("b", nl.netName(nl.deck.ic[1].net));
    try std.testing.expectEqual(@as(f64, 2), nl.deck.ic[1].value);
    try std.testing.expectEqual(@as(usize, 1), nl.deck.nodeset.len);
    try std.testing.expectEqual(@as(f64, 0.5), nl.deck.nodeset[0].value);
}

test "ngspice reads `10%3` as the number 10 and refuses an operator-led field (#200)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .ngspice, "t\nr1 a 0 r=10%3\nr2 a 0 r=2k\\3\n");
    try std.testing.expectEqual(@as(f64, 10), try kvNum((try device(nl, "r1")).kv, "r"));
    try std.testing.expectEqual(@as(f64, 2000), try kvNum((try device(nl, "r2")).kv, "r"));
    try expectRefused(.ngspice, error.UnsupportedCard, &.{
        "t\nr1 a 0 10 %3\n",
        "t\nr1 a 0 10 *3\n",
        "t\nd1 a 0 ^dm\n",
    });
}

test "a lone POLY(1) coefficient is p1 in HSPICE and p0 in ngspice [SA G-element]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ngspice: the constant term alone, `(2)`, folds to a number.
    const ng = try device(try parseIn(a, .ngspice, "t\ne1 o 0 poly(1) a 0 2\nr1 a 0 1\n"), "e1");
    try std.testing.expectEqual('b', ng.kind);
    try std.testing.expectEqual(@as(f64, 2), try kvNum(ng.kv, "v"));
    // HSPICE: `0 + 2*v(a)` reads the circuit and stays postfix.
    const hs = try device(try parseIn(a, .hspice, "t\ne1 o 0 poly(1) a 0 2\nr1 a 0 1\n"), "e1");
    try std.testing.expect(hs.kv[0].value == .expr);
    try expectRefused(.ngspice, error.ParseError, &.{
        "t\ne1 o 0 poly(0) a 0 2\n",
        "t\ne1 o 0 poly(9) a 0 2\n",
        "t\ne1 o 0 poly(1.5) a 0 2\n",
        "t\ne1 o 0 poly(1) a 0\n",
    });
}

test "LAPLACE, POLE and DELAY keep their letter and count their terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lap = try device(try parseIn(a, .ngspice, "t\ne1 o 0 laplace a 0 1 / 1 1e-3\n"), "e1");
    try std.testing.expectEqual('e', lap.kind);
    try std.testing.expectEqual(@as(usize, 4), lap.pins.len);
    try std.testing.expectEqual(@as(usize, 3), lap.positional.len);
    try std.testing.expectEqual(@as(f64, 1), try kvNum(lap.kv, "laplace"));
    const pole = try device(try parseIn(a, .ngspice, "t\ng1 o 0 pole a 0 1 / 1 2 3\n"), "g1");
    try std.testing.expectEqual(@as(f64, 1), try kvNum(pole.kv, "pole"));
    const delay = try device(try parseIn(a, .ngspice, "t\ne1 o 0 delay a 0 td=1n\n"), "e1");
    try std.testing.expectEqual(@as(f64, 1e-9), try kvNum(delay.kv, "td"));
    try expectRefused(.ngspice, error.ParseError, &.{
        "t\ne1 o 0 laplace a 0 1\n", // no denominator
        "t\ne1 o 0 laplace a 0 / 1\n", // no numerator
        "t\ne1 o 0 pole a 0 1 2 / 1\n", // an even numerator count
        "t\ne1 o 0 delay a 0\n", // no td
        "t\ne1 o 0 delay a 0 1 td=1n\n", // a stray coefficient
    });
    try expectRefused(.ngspice, error.UnsupportedCard, &.{"t\nf1 o 0 laplace a 0 1 / 1\n"});
}

test "an HSPICE P card is a V port; its hblin band splits into two keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .hspice, "t\np1 a 0 port=1 z0=50 hblin=[1, 2]\nr1 a 0 50\n");
    const p = try device(nl, "p1");
    try std.testing.expectEqual('v', p.kind);
    try std.testing.expectEqual(@as(f64, 1), try kvNum(p.kv, "hblin_h"));
    try std.testing.expectEqual(@as(f64, 2), try kvNum(p.kv, "hblin_s"));
    try std.testing.expectEqual(@as(f64, 50), try kvNum(p.kv, "z0"));
    try expectRefused(.hspice, error.UnsupportedCard, &.{
        "t\np1 a 0 port=1 hblin=[1, 2, 3]\n",
        "t\np1 a 0 b c port=1\n", // a fourth node: a balanced port
    });
    try expectRefused(.hspice, error.ParseError, &.{"t\np1 a 0 port=1 hblin=[1\n"});
}

test ".options vpi= names VPI applications in their own case (#197)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nl = try parseIn(arena.allocator(), .ngspice, "t\nr1 a 0 1\n.options reltol=1e-4 vpi=\"Lib/App.so\" vpi='b.so'\n");
    try std.testing.expectEqual(@as(usize, 2), nl.deck.vpi_apps.len);
    try std.testing.expectEqualStrings("Lib/App.so", nl.deck.vpi_apps[0]);
    try std.testing.expectEqualStrings("b.so", nl.deck.vpi_apps[1]);
    // The card's other options read as any `.options`.
    const args = nl.deck.config[0].args;
    try std.testing.expectEqualStrings("reltol", args[0].name);
    try std.testing.expectEqual(@as(f64, 1e-4), args[1].num);
    try expectRefused(.ngspice, error.ParseError, &.{"t\nr1 a 0 1\n.options vpi=\n"});
}

test ".connect is top-level only; nested .subckt definitions stop at 16" {
    try expectRefused(.ngspice, error.UnsupportedCard, &.{"t\n.subckt s a\n.connect a b\nr1 a 0 1\n.ends\nx1 n s\n"});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ 16, 17 }) |depth| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "t\n");
        for (0..depth) |k| try src.print(a, ".subckt s{d} p\n", .{k});
        try src.appendSlice(a, "r1 p 0 1\n");
        for (0..depth) |_| try src.appendSlice(a, ".ends\n");
        try src.appendSlice(a, "x1 n s0\n");
        if (depth == 16)
            _ = try parseIn(a, .ngspice, src.items)
        else
            try std.testing.expectError(error.ParseError, parseIn(a, .ngspice, src.items));
    }
}

test "groups nest 32 deep; the 33rd level is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ 32, 33 }) |depth| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "t\nv1 a 0 ");
        for (0..depth) |_| try src.appendSlice(a, "f(");
        try src.append(a, '1');
        for (0..depth) |_| try src.append(a, ')');
        try src.append(a, '\n');
        if (depth == 32) {
            const nl = try parseIn(a, .ngspice, src.items);
            var v = (try device(nl, "v1")).positional[0];
            for (0..depth) |_| v = v.group.args()[0];
            try std.testing.expectEqual(@as(f64, 1), v.num);
        } else try std.testing.expectError(error.ParseError, parseIn(a, .ngspice, src.items));
    }
}

test "parseAnalyses takes analysis cards only (#64)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Lookup = struct {
        pub fn node(_: @This(), name: []const u8) u32 {
            return if (std.mem.eql(u8, name, "out")) 7 else netlist.none;
        }
    };
    const got = try netlist.parseAnalyses(a, ".TRAN 1n 10n\n* note\n.ac dec 10 1 1g\n.tf v(OUT) v1\n", Lookup{});
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings(".TRAN 1n 10n", got[0].line); // as written
    try std.testing.expectEqual(@as(u32, 7), got[2].pos);
    for ([_][]const u8{ "r1 a 0 1\n", ".temp 27\n", ".foo 1\n", ".param p=1\n", ".model m d\n" }) |text|
        try std.testing.expectError(error.UnsupportedDirectiveMutation, netlist.parseAnalyses(a, text, Lookup{}));
    try std.testing.expectEqual(@as(usize, 0), (try netlist.parseAnalyses(a, "", Lookup{})).len);
}

fn parseAnalysesAll(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const Lookup = struct {
        pub fn node(_: @This(), _: []const u8) u32 {
            return 1;
        }
    };
    _ = try netlist.parseAnalyses(arena.allocator(), ".tran 1n 10n sweep monte=3\n.four 1k v(a) v(b)\n.ac dec 10 1 1g\n", Lookup{});
}

test "parseAnalyses: every allocation failure surfaces as OutOfMemory" {
    try std.testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, parseAnalysesAll, .{});
}

fn parseDialects(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try netlist.parse(a,
        \\hspice allocation failures
        \\.param p=1
        \\.subckt cell a b w0=1u
        \\r1 a b 'p*2'
        \\.ends
        \\x1 in out cell w0=2u
        \\v1 in 0 pat (1 0 0 1n 1n 5n b101)
        \\p1 out 0 port=1 z0=50
        \\.mosra reltotaltime=10
        \\.tran 1n 10n sweep p lin 3 1 2
        \\.end
    , .hspice);
    _ = try netlist.parse(a,
        \\spectre allocation failures
        \\parameters p=1
        \\r1 (a 0) resistor r=p
        \\v1 (a 0) vsource dc=1
        \\tr tran stop=10n
    , .spectre);
}

test "HSPICE and Spectre decks: every allocation failure surfaces as OutOfMemory" {
    try std.testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, parseDialects, .{});
}
