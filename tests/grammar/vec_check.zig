//! The `.vec` oracle: tests/grammar/vec.peg's tree, lowered here to the
//! netlist text a vector file stands for (a PWL source per input bit, a
//! `.dout` per output bit), against `vec.expand` reached the way a deck
//! reaches it, through `.vec` expansion (`netlist.source.expand`).
const std = @import("std");
const netlist = @import("netlist");
const peg = @import("peg.zig");

const Error = error{ Refused, OutOfMemory };

/// One signal bit, as the oracle reads the spec (vec.peg's header).
const Bit = struct {
    name: []const u8 = "",
    io: u8 = 'i',
    ref: []const u8 = "0",
    idelay: f64 = 0,
    odelay: f64 = 0,
    trise: ?f64 = null,
    tfall: ?f64 = null,
    vih: f64 = 3.3,
    vil: f64 = 0,
    voh: f64 = 2.64,
    vol: f64 = 0.66,
    vth: f64 = 1.65,
    levels: bool = false,
};

const L = struct {
    a: std.mem.Allocator,
    g: peg.Grammar,
    t: peg.Tree,

    fn is(l: L, i: u32, name: []const u8) bool {
        return l.t.rows[i].rule == l.g.rule(name);
    }
    fn lower(l: L, i: u32) Error![]const u8 {
        return std.ascii.allocLowerString(l.a, l.t.text(i));
    }
    /// The lowered text of every `name` child of `i`, joined.
    fn joined(l: L, i: u32, name: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var kids = l.t.children(i);
        while (kids.next()) |k| if (l.is(k, name)) try out.appendSlice(l.a, try l.lower(k));
        return out.items;
    }
    fn float(l: L, i: u32) f64 {
        return std.fmt.parseFloat(f64, l.t.text(i)) catch unreachable;
    }
};

/// The bits `mask` (one hex digit per radix digit) selects; all without.
fn selected(a: std.mem.Allocator, mask: []const u8, digits: []const u8, n: usize) Error![]bool {
    const on = try a.alloc(bool, n);
    if (mask.len == 0) {
        @memset(on, true);
        return on;
    }
    if (mask.len != digits.len) return error.Refused;
    var b: usize = 0;
    for (mask, digits) |c, w| {
        const v = std.fmt.charToDigit(c, 16) catch unreachable;
        for (0..w) |k| {
            on[b] = (v >> @intCast(w - 1 - k)) & 1 == 1;
            b += 1;
        }
    }
    return on;
}

fn lowerVec(a: std.mem.Allocator, g: peg.Grammar, t: peg.Tree) Error![]const u8 {
    const l: L = .{ .a = a, .g = g, .t = t };
    var bits: std.ArrayList(Bit) = .empty;
    var digits: std.ArrayList(u8) = .empty;
    var unit: f64 = 1e-9;
    var period: ?f64 = null;
    var tskip = false;
    var named = false;
    var times: std.ArrayList(f64) = .empty;
    var states: std.ArrayList(u8) = .empty;

    var top = t.children(null);
    var stmts = t.children(top.next().?);
    while (stmts.next()) |st| {
        if (l.is(st, "Radix") != (digits.items.len == 0)) return error.Refused;
        if (l.is(st, "Radix")) {
            for (try l.joined(st, "Digits")) |c| {
                try digits.append(a, c - '0');
                for (0..c - '0') |_| try bits.append(a, .{});
            }
        } else if (l.is(st, "Vname")) {
            var b: usize = 0;
            var d: usize = 0;
            var kids = t.children(st);
            while (kids.next()) |k| {
                var base = try l.lower(k);
                var from: u32 = 0;
                var to: u32 = 0;
                var open: []const u8 = "";
                var close: []const u8 = "";
                if (l.is(k, "Bus")) {
                    var parts = t.children(k);
                    base = try l.lower(parts.next().?);
                    // Descend to the group holding the range.
                    var grp = parts.next().?;
                    while (t.child(grp, g.rule("From")) == null) grp = t.child(grp, g.rule("Group")).?;
                    const row = t.rows[k];
                    const in = t.rows[grp];
                    open = t.src[t.rows[t.child(k, g.rule("Id")).?].end..in.start];
                    close = t.src[in.end..row.end];
                    from = std.fmt.parseInt(u32, t.text(t.child(grp, g.rule("From")).?), 10) catch return error.Refused;
                    to = std.fmt.parseInt(u32, t.text(t.child(grp, g.rule("To")).?), 10) catch return error.Refused;
                }
                const width: usize = if (l.is(k, "Bus")) @abs(@as(i64, from) - to) + 1 else 1;
                var have: usize = 0;
                while (have < width) : (d += 1) {
                    if (d == digits.items.len) return error.Refused;
                    have += digits.items[d];
                }
                if (have != width) return error.Refused;
                for (bits.items[b..][0..width], 0..) |*bit, i| {
                    if (!l.is(k, "Bus")) {
                        bit.name = base;
                        continue;
                    }
                    const at: i64 = if (from >= to) @as(i64, from) - @as(i64, @intCast(i)) else @as(i64, from) + @as(i64, @intCast(i));
                    bit.name = try std.fmt.allocPrint(a, "{s}{s}{d}{s}", .{ base, open, at, close });
                }
                b += width;
            }
            if (d != digits.items.len) return error.Refused;
            named = true;
        } else if (l.is(st, "Io")) {
            const chars = try l.joined(st, "IoChars");
            if (chars.len != digits.items.len) return error.Refused;
            var b: usize = 0;
            for (chars, digits.items) |c, w| {
                if (c == 'b') return error.Refused;
                for (bits.items[b..][0..w]) |*bit| bit.io = c;
                b += w;
            }
        } else if (l.is(st, "Tunit")) {
            const u = try l.lower(t.child(st, g.rule("Unit")).?);
            const scale: f64 = switch (u[0]) {
                'f' => 1e-15,
                'p' => 1e-12,
                'n' => 1e-9,
                'u' => 1e-6,
                'm' => 1e-3,
                else => unreachable,
            };
            unit = scale * if (t.child(st, g.rule("Mult"))) |m| l.float(m) else 1;
        } else if (l.is(st, "Period")) {
            period = l.float(t.child(st, g.rule("Num")).?);
        } else if (l.is(st, "Tskip")) {
            tskip = true;
        } else if (l.is(st, "Enable") or l.is(st, "Cbc")) {
            return error.Refused;
        } else if (l.is(st, "Wave") or l.is(st, "Vref")) {
            const mask = try selected(a, try l.joined(st, "Mask"), digits.items, bits.items.len);
            var kids = t.children(st);
            const vref = l.is(st, "Vref");
            const key = if (vref) "vref" else try l.lower(kids.next().?);
            const v_row = kids.next().?;
            const v = if (l.is(v_row, "Num")) l.float(v_row) else 0;
            const zero = !l.is(v_row, "SNum") or l.float(t.child(v_row, g.rule("Mult")).?) == 0;
            for (bits.items, mask) |*bit, on| {
                if (!on) continue;
                const k = std.meta.stringToEnum(enum { tdelay, idelay, odelay, slope, trise, tfall, vih, vil, voh, vol, vth, out, outz, triz, vref }, key).?;
                switch (k) {
                    .tdelay => {
                        bit.idelay = v;
                        bit.odelay = v;
                    },
                    .idelay => bit.idelay = v,
                    .odelay => bit.odelay = v,
                    .slope => {
                        bit.trise = v;
                        bit.tfall = v;
                    },
                    .trise => bit.trise = v,
                    .tfall => bit.tfall = v,
                    .vih => bit.vih = v,
                    .vil => bit.vil = v,
                    .voh => {
                        bit.voh = v;
                        bit.levels = true;
                    },
                    .vol => {
                        bit.vol = v;
                        bit.levels = true;
                    },
                    .vth => bit.vth = v,
                    // A nonzero series resistance is not read.
                    .out, .outz => if (!zero) return error.Refused,
                    .triz => {},
                    .vref => bit.ref = try l.lower(v_row),
                }
            }
        } else {
            assert(l.is(st, "Row"));
            var cells: std.ArrayList(u32) = .empty;
            var kids = t.children(st);
            while (kids.next()) |k| try cells.append(a, k);
            const timed = period == null or tskip;
            if (timed and cells.items.len < 2) return error.Refused;
            const time = if (period) |p| p * @as(f64, @floatFromInt(times.items.len)) else blk: {
                var d: peg.Diag = .{};
                _ = peg.parse(a, g, g.rule("Num"), t.text(cells.items[0]), &d) catch return error.Refused;
                break :blk l.float(cells.items[0]);
            };
            if (times.items.len > 0 and !(time > times.items[times.items.len - 1])) return error.Refused;
            var chars: std.ArrayList(u8) = .empty;
            for (cells.items[@intFromBool(timed)..]) |c| {
                if (t.child(c, g.rule("Verilog")) != null) return error.Refused;
                try chars.appendSlice(a, try l.lower(c));
            }
            if (chars.items.len != digits.items.len) return error.Refused;
            try times.append(a, time);
            for (chars.items, digits.items) |c, w| {
                if (c == 'x' or c == 'u' or c == 'z') {
                    try states.appendNTimes(a, if (c == 'z') 'z' else 'x', w);
                    continue;
                }
                const v = std.fmt.charToDigit(c, @as(u8, 1) << @intCast(w)) catch return error.Refused;
                for (0..w) |k| try states.append(a, if ((v >> @intCast(w - 1 - k)) & 1 == 1) '1' else '0');
            }
        }
    }
    if (bits.items.len == 0 or times.items.len == 0) return error.Refused;
    if (!named) {
        var b: usize = 0;
        for (digits.items, 1..) |w, k| for (0..w) |i| {
            bits.items[b].name = if (w == 1) try std.fmt.allocPrint(a, "v{d}", .{k}) else try std.fmt.allocPrint(a, "v{d}[{d}]", .{ k, w - 1 - i });
            b += 1;
        };
    }

    var out: std.ArrayList(u8) = .empty;
    const n = bits.items.len;
    for (bits.items, 0..) |bit, b| switch (bit.io) {
        'u' => {},
        'o' => {
            try out.print(a, ".dout {s} ", .{bit.name});
            if (bit.levels) try out.print(a, "{e} {e} (", .{ bit.vol, bit.voh }) else try out.print(a, "{e} (", .{bit.vth});
            for (times.items, 0..) |time, r| switch (states.items[r * n + b]) {
                '0', '1' => |s| try out.print(a, " {e} {c}", .{ (time + bit.odelay) * unit, s }),
                else => {},
            };
            try out.appendSlice(a, " )\n");
        },
        else => {
            var level = bit.vil;
            for (0..times.items.len) |r| if (states.items[r * n + b] == 'z') return error.Refused;
            if (states.items[b] == '1') level = bit.vih;
            try out.print(a, "vvec_{s} {s} {s} pwl(0 {e}", .{ bit.name, bit.name, bit.ref, level });
            var points: usize = 1;
            for (times.items, 0..) |time, r| {
                const high = states.items[r * n + b] == '1';
                const next = if (high) bit.vih else bit.vil;
                if (next == level) continue;
                points += 2;
                if (points > 64) return error.Refused;
                const edge = (if (high) bit.trise else bit.tfall) orelse 0.1e-9 / unit;
                const at = (time + bit.idelay) * unit;
                try out.print(a, " {e} {e} {e} {e}", .{ at, level, at + edge * unit, next });
                level = next;
            }
            try out.appendSlice(a, ")\n");
        },
    };
    return out.items;
}

const assert = std.debug.assert;

/// Token by token, numbers within a relative 1e-12.
fn same(x: []const u8, y: []const u8) bool {
    var i = std.mem.tokenizeAny(u8, x, " \n()");
    var j = std.mem.tokenizeAny(u8, y, " \n()");
    while (true) {
        const p = i.next() orelse return j.next() == null;
        const q = j.next() orelse return false;
        if (std.mem.eql(u8, p, q)) continue;
        const u = std.fmt.parseFloat(f64, p) catch return false;
        const v = std.fmt.parseFloat(f64, q) catch return false;
        if (@abs(u - v) > 1e-12 * @max(@abs(u), @abs(v))) return false;
    }
}

const Check = struct {
    a: std.mem.Allocator,
    g: peg.Grammar,
    tmp: std.testing.TmpDir,
    deck: []const u8,
    bad: usize = 0,

    /// Both readers on `src`; prints and counts a disagreement.
    fn run(c: *Check, src: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = std.testing.io;
        var d: peg.Diag = .{};
        const want: ?[]const u8 = if (peg.parse(a, c.g, c.g.rule("File"), src, &d)) |t| lowerVec(a, c.g, t) catch |e| switch (e) {
            error.Refused => null,
            else => return e,
        } else |e| switch (e) {
            error.NoMatch => null,
            else => return e,
        };
        try c.tmp.dir.writeFile(io, .{ .sub_path = "x.vec", .data = src });
        const got: ?[]const u8 = if (netlist.source.expand(io, std.heap.page_allocator, a, c.deck, "t\n.vec 'x.vec'\n")) |text| text[2..] else |_| null;
        if (want == null and got == null) return;
        if (want != null and got != null and same(want.?, got.?)) return;
        c.bad += 1;
        if (c.bad <= 20) std.debug.print("vec {f}\n--- grammar\n{s}\n--- frontend\n{s}\n", .{ std.zig.fmtString(src), want orelse "(refused)", got orelse "(refused)" });
    }
};

/// One case per rule of vec.peg and per spec item of
/// dev/research/data-file-syntax.md §3 (V1-V11 named).
const cases = [_][]const u8{
    "; comment\nradix 1 1 2\nvname a b q[[1:0]]\nio i i o\ntunit ns\nslope 0.5\nvih 5 1 0 0\nvth 2.5\n10 1 0 x\n20 0 1 2\n",
    "RADIX 1\r\nVNAME A\r\n10 1 ; row\r\n20 0",
    "radix 1\n+ 1\nvname a\n+\n+ b\n; c\n\n+ ;x\n10 1 1\n",
    "+ radix 1\nvname a\n10 1\n",
    "  radix 1  \n\t vname a ;n\n  \r\n10 1\n   ",
    "radix 1\r\n  ; c\r\n\t+ 1\r\nvname a\r\n10 1 1\n; end",
    "radix 1\nvname a\nout -0\n10 1\n",
    "radix 1\nvname a\n10 1\n  ; tail",
    // V1: names fill bits; RADIX tokens carry no meaning.
    "radix 144\nvname a x[[3:0]] y[[3:0]]\n10 1 a 5\n",
    "radix 444444\nvname a[[0:23]]\n10 000000\n20 abcdef\n",
    "radix 11\nvname a b\n10 1 1\n",
    "radix 4\nvname a\n10 1\n",
    // V2: one RADIX, first.
    "radix 1\nradix 1\nvname a\n10 1\n",
    "vname a\nradix 1\n10 1\n",
    // V3: no VNAME.
    "radix 1 2\n10 1 3\n",
    // V4: groupings.
    "radix 4 2 1\nvname vb<[4:1]> c{[1:0]} d([[0:0]])\n10 a 2 1\n",
    "radix 4\nvname vb[12:9]\n10 a\n",
    "radix 1\nvname a<[0:0]]\n10 1\n",
    "radix 1\nvname 1a\n10 1\n",
    // V5: TUNIT multipliers.
    "radix 1\nvname a\ntunit 999ns\n10 1\n20 0\n",
    "radix 1\nvname a\ntunit .99 ps\n10 1\n20 0\n",
    "radix 1\nvname a\ntunit .99e+6ps\n10 1\n20 0\n",
    "radix 1\nvname a\ntunit 2 FS\n10 1\n20 0\n",
    "radix 1\nvname a\ntunit us\n10 1\n20 0\n",
    "radix 1\nvname a\ntunit ms\n10 1\n20 0\n",
    "radix 1\nvname a\ntunit .99eps\n10 1\n",
    "radix 1\nvname a\ntunit .99 e+6ps\n10 1\n",
    "radix 1\nvname a\ntunit s\n10 1\n",
    // V6: IO u; IO b is not read.
    "radix 111\nio iuo\n10 101\n",
    "radix 1\nio b\n10 1\n",
    "radix 1\nvname a\nio I\nio O\n10 1\n",
    // V7: SLOPE defaults to 0.1 ns whatever TUNIT.
    "radix 1\nvname a\ntunit ps\n10 1\n20 0\n",
    "radix 2\nvname a[1:0]\ntrise 2 1\ntfall 3 1\n10 3\n20 0\n",
    // V8: VOH/VOL replace VTH only where given.
    "radix 11\nvname a b\nio oo\nvoh 3 10\nvol 0.5 01\nvth 1\n10 11\n20 00\n",
    // V9: Z expects nothing on an output, and is not read on an input.
    "radix 11\nvname a b\nio io\n10 1z\n20 0 1\n",
    "radix 1\nvname a\n10 z\n",
    // V10: TSKIP under PERIOD keeps an unread time.
    "radix 1\nvname a\nperiod 5\ntskip\n7 1\n3 0\n",
    "radix 4\nvname d[3:0]\nperiod 10\na\n5\n",
    "radix 1\nvname a\ntskip\n10 1\n20 0\n",
    // V11: plain numbers; HSPICE numbers on OUT and TRIZ.
    "radix 1\nvname a\nvih inf\n10 1\n",
    "radix 1\nvname a\nvih 5v\n10 1\n",
    "radix 1\nvname a\nvih +5e0\nvil -.5\n10 1\n20 0\n",
    "radix 1\nvname a\ntriz 15.1Meg\nout 0\noutz 0k\n10 1\n",
    "radix 1\nvname a\nout 1k\n10 1\n",
    "radix 1\nvname a\nperiod 1e1\n0\n1\n",
    // Delays, references, masks, and what ESPice refuses.
    "radix 1 1\nvname a b\ntdelay 1 01\nidelay 2 10\nodelay 3\nvref gnd 10\n10 11\n20 00\n",
    "radix 1\nvname a\nenable ~a 1\n10 1\n",
    "radix 1\nvname a\noption cbc\n10 1\n",
    "radix 4\nvname a[3:0]\n10 4'b1010\n",
    "radix 1\nvname a\n20 1\n10 0\n",
    "radix 1\nvname a\n10 1 1\n",
    "radix 1\nvname a\n10\n",
    "radix 5\nvname a\n10 1\n",
    "radix 1\nvname a\nvih 5 11\n10 1\n",
    "radix 1\nvname a\nfoo 1\n10 1\n",
    "radix 1\n",
    "",
};

test "vec: cases, corpus, exhaustive, coverage" {
    // `.vec` expansion warns on every file it refuses.
    std.testing.log_level = .err;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: peg.Diag = .{};
    const g = peg.compile(a, @embedFile("vec.peg"), &d) catch |err| {
        std.debug.print("vec.peg: {t} at byte {d} {s}\n", .{ err, d.offset, d.name });
        return err;
    };
    var c: Check = .{ .a = a, .g = g, .tmp = std.testing.tmpDir(.{}), .deck = undefined };
    defer c.tmp.cleanup();
    c.deck = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/deck.sp", .{c.tmp.sub_path});
    for (cases) |src| try c.run(src);

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "tests/fixtures", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".vec")) continue;
        try c.run(try dir.readFileAlloc(std.testing.io, e.path, a, .limited(1 << 20)));
    }

    // Bounded-exhaustive: a RADIX line, two statements and a row block.
    const radixes = [_][]const u8{ "", "radix 1\n", "radix 11\n", "radix 2\n", "radix 1 2\n", "radix 4\n" };
    const body = [_][]const u8{
        "",               "vname a\n",      "vname a b\n",     "vname q[[1:0]]\n", "vname q<[0:1]>\n", "vname a q[1:0]\n",
        "io i\n",         "io o\n",         "io u\n",          "io b\n",           "io io\n",          "tunit ps\n",
        "tunit 2 ns\n",   "tunit 3ps\n",    "period 5\n",      "tskip\n",          "slope 1\n",        "trise 2 1\n",
        "vth 2\n",        "voh 3\n",        "vol 0.5 1\n",     "tdelay 1\n",       "odelay 2\n",       "idelay -1\n",
        "vref gnd\n",     "out 0\n",        "out 1\n",         "triz 15.1meg\n",   "+ 1\n",            "; c\n",
    };
    const rows = [_][]const u8{ "10 1\n", "10 0\n20 1\n", "1\n", "10 z\n", "10 x\n", "10 3\n", "10 1 1\n", "0\n1\n0\n", "10 11\n", "5 2'b10\n" };
    var buf: std.ArrayList(u8) = .empty;
    for (radixes) |r| for (body) |x| for (body) |y| for (rows) |w| {
        buf.clearRetainingCapacity();
        for ([_][]const u8{ r, x, y, w }) |part| try buf.appendSlice(a, part);
        try c.run(buf.items);
    };

    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, g, h.node);
        std.debug.print("vec.peg: rule {s}: never matched: {s}\n", .{ h.rule, w.written() });
    }
    if (c.bad > 0 or holes.len > 0) {
        std.debug.print("vec: {d} disagree, {d} coverage gaps\n", .{ c.bad, holes.len });
        return error.GrammarCheck;
    }
}
