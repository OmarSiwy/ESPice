//! HSPICE digital vector files [SA Ch.9 "Specifying a Digital Vector File
//! and Mixed Mode Stimuli"; CR .VEC]: `.vec 'file'` becomes netlist text,
//! a PWL voltage source per input bit and a `.dout` card per output bit,
//! as HSPICE converts them. tests/grammar/vec.peg is the spec. Read: RADIX,
//! VNAME (buses in any nesting of `[] {} () <>` around the `[hi:lo]`
//! range; V1, V2, ... when absent), IO with `i`, `o` and `u`, TUNIT (with a
//! multiplier), PERIOD, TSKIP, TDELAY, IDELAY, ODELAY, SLOPE, TRISE, TFALL,
//! VIH, VIL, VOH, VOL, VTH, VREF, OUT/OUTZ 0 and TRIZ, each with an
//! optional mask, plus tabular data in hex digits and the 0, 1, X and U
//! states, and Z on outputs. Not read: bidirectional signals (IO `b`,
//! ENABLE, OPTION CBC), Z, L and H inputs, a nonzero OUT, Verilog-sized
//! values and `.param` names in the file.
const std = @import("std");
const spiceNum = @import("lines.zig").hspice.parseNum;
const plainNumber = @import("lines.zig").plainNumber;

const Error = error{ OutOfMemory, InvalidVector };

/// PWL points the source models hold (`pwl_times[0:63]`).
const max_points = 64;

/// One signal bit; every waveform field in the file's time unit or volts.
const Bit = struct {
    name: []const u8 = "",
    io: u8 = 'i',
    ref: []const u8 = "0",
    idelay: f64 = 0,
    odelay: f64 = 0,
    /// Null until a SLOPE, TRISE or TFALL sets it: 0.1 ns whatever TUNIT
    /// is (CR p.745).
    trise: ?f64 = null,
    tfall: ?f64 = null,
    vih: f64 = 3.3,
    vil: f64 = 0,
    voh: f64 = 2.64,
    vol: f64 = 0.66,
    vth: f64 = 1.65,
    /// VOH or VOL was given: the check uses them, not VTH (CR p.761, 763).
    levels: bool = false,
};

const units = std.StaticStringMap(f64).initComptime(.{
    .{ "fs", 1e-15 }, .{ "ps", 1e-12 }, .{ "ns", 1e-9 }, .{ "us", 1e-6 }, .{ "ms", 1e-3 },
});

const Field = enum { tdelay, idelay, odelay, slope, trise, tfall, vih, vil, voh, vol, vth, vref, out, outz, triz };

/// The netlist text vector file `src` stands for, in `arena`: one
/// `vvec_<bit>` PWL source per input bit and one `.dout` card per output.
/// InvalidVector for a form this reader does not take (see the module
/// comment) or one the manual forbids.
pub fn expand(arena: std.mem.Allocator, src: []const u8) Error![]const u8 {
    var bits: std.ArrayList(Bit) = .empty;
    // Bits per digit, digit by digit across the vectors.
    var digits: std.ArrayList(u8) = .empty;
    var unit: f64 = 1e-9;
    var period: ?f64 = null;
    var tskip = false;
    var named = false;
    // Rows of states, one byte per bit: '0', '1', 'x' or 'z'.
    var times: std.ArrayList(f64) = .empty;
    var states: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, src, '\n');
    var pending: std.ArrayList(u8) = .empty;
    var more = true;
    while (more) {
        const raw = lines.next();
        more = raw != null;
        const line = std.mem.trim(u8, if (raw) |l| l[0 .. std.mem.indexOfScalar(u8, l, ';') orelse l.len] else "", " \t\r");
        // Blank and comment lines do not end a statement before its `+`.
        if (line.len == 0 and more) continue;
        if (line.len > 0 and line[0] == '+') {
            if (pending.items.len == 0) return error.InvalidVector;
            try pending.append(arena, ' ');
            try pending.appendSlice(arena, line[1..]);
            continue;
        }
        const stmt = try arena.dupe(u8, pending.items);
        pending.clearRetainingCapacity();
        try pending.appendSlice(arena, line);
        var toks: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, stmt, " \t");
        while (it.next()) |t| try toks.append(arena, try std.ascii.allocLowerString(arena, t));
        if (toks.items.len == 0) continue;
        const key = toks.items[0];
        const args = toks.items[1..];
        // RADIX is the first statement, and the only one (CR p.744).
        if (std.mem.eql(u8, key, "radix") != (digits.items.len == 0)) return error.InvalidVector;
        if (std.mem.eql(u8, key, "radix")) {
            for (args) |v| for (v) |c| {
                if (c < '1' or c > '4') return error.InvalidVector;
                try digits.append(arena, c - '0');
                for (0..c - '0') |_| try bits.append(arena, .{});
            };
            if (digits.items.len == 0) return error.InvalidVector;
        } else if (std.mem.eql(u8, key, "vname")) {
            // Names take digits in order: a bus as many as its bits fill,
            // a plain name one single-bit digit (CR p.759).
            var b: usize = 0;
            var d: usize = 0;
            for (args) |v| {
                const width = try busWidth(v);
                var have: usize = 0;
                while (have < width) : (d += 1) {
                    if (d == digits.items.len) return error.InvalidVector;
                    have += digits.items[d];
                }
                if (have != width) return error.InvalidVector;
                try names(arena, v, bits.items[b..][0..width]);
                b += width;
            }
            if (d != digits.items.len) return error.InvalidVector;
            named = true;
        } else if (std.mem.eql(u8, key, "io")) {
            const chars = try std.mem.concat(arena, u8, args);
            if (chars.len != digits.items.len) return error.InvalidVector;
            var b: usize = 0;
            for (chars, digits.items) |c, w| {
                if (c != 'i' and c != 'o' and c != 'u') return error.InvalidVector;
                for (bits.items[b..][0..w]) |*bit| bit.io = c;
                b += w;
            }
        } else if (std.mem.eql(u8, key, "tunit")) {
            unit = try timeUnit(args);
        } else if (std.mem.eql(u8, key, "tskip")) {
            if (args.len != 0) return error.InvalidVector;
            tskip = true;
        } else if (std.mem.eql(u8, key, "period")) {
            if (args.len != 1) return error.InvalidVector;
            period = try number(args[0]);
        } else if (std.meta.stringToEnum(Field, key)) |field| {
            if (args.len == 0) return error.InvalidVector;
            const value = args[0];
            const mask = try maskBits(arena, args[1..], digits.items, bits.items.len);
            for (bits.items, mask) |*bit, on| if (on) switch (field) {
                .tdelay => {
                    bit.idelay = try number(value);
                    bit.odelay = bit.idelay;
                },
                .idelay => bit.idelay = try number(value),
                .odelay => bit.odelay = try number(value),
                .slope => {
                    bit.trise = try number(value);
                    bit.tfall = bit.trise;
                },
                .trise => bit.trise = try number(value),
                .tfall => bit.tfall = try number(value),
                .vih => bit.vih = try number(value),
                .vil => bit.vil = try number(value),
                .voh => {
                    bit.voh = try number(value);
                    bit.levels = true;
                },
                .vol => {
                    bit.vol = try number(value);
                    bit.levels = true;
                },
                .vth => bit.vth = try number(value),
                .vref => bit.ref = value,
                .out, .outz => if ((spiceNum(value) orelse return error.InvalidVector) != 0) return error.InvalidVector,
                .triz => if (spiceNum(value) == null) return error.InvalidVector,
            };
        } else if (std.ascii.isAlphabetic(key[0]) and period == null) {
            return error.InvalidVector; // ENABLE, OPTION, a misspelt keyword
        } else {
            // A data row: `[time] digits...`; TSKIP keeps an unread time.
            const timed = period == null or tskip;
            if (timed and args.len == 0) return error.InvalidVector;
            const t = if (period) |p| p * @as(f64, @floatFromInt(times.items.len)) else try number(key);
            if (times.items.len > 0 and !(t > times.items[times.items.len - 1])) return error.InvalidVector;
            const chars = try std.mem.concat(arena, u8, if (timed) args else toks.items);
            if (chars.len != digits.items.len) return error.InvalidVector;
            try times.append(arena, t);
            for (chars, digits.items) |c, w| {
                const x: ?u8 = switch (c) {
                    'x', 'u' => 'x',
                    'z' => 'z',
                    else => null,
                };
                const v: u8 = if (x != null) 0 else std.fmt.charToDigit(c, @as(u8, 1) << @intCast(w)) catch return error.InvalidVector;
                var k = w;
                while (k > 0) {
                    k -= 1;
                    try states.append(arena, x orelse if (v >> @intCast(k) & 1 == 1) '1' else '0');
                }
            }
        }
    }
    if (bits.items.len == 0 or times.items.len == 0) return error.InvalidVector;
    // No VNAME: vector k is `vk`, its bits `vk[w-1]`..`vk[0]` past one bit.
    if (!named) {
        var b: usize = 0;
        for (digits.items, 1..) |w, k| {
            const name = try arena.print("v{d}", .{k});
            for (bits.items[b..][0..w], 0..) |*bit, i| bit.name = if (w == 1) name else try arena.print("{s}[{d}]", .{ name, w - 1 - i });
            b += w;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    const n = bits.items.len;
    for (bits.items, 0..) |bit, b| {
        if (bit.io == 'u') continue;
        if (bit.io == 'o') {
            if (bit.levels) try out.print(arena, ".dout {s} {e} {e} (", .{ bit.name, bit.vol, bit.voh }) else try out.print(arena, ".dout {s} {e} (", .{ bit.name, bit.vth });
            for (times.items, 0..) |t, r| {
                const s = states.items[r * n + b];
                if (s == '0' or s == '1') try out.print(arena, " {e} {c}", .{ (t + bit.odelay) * unit, s });
            }
            try out.appendSlice(arena, " )\n");
            continue;
        }
        for (0..times.items.len) |r| if (states.items[r * n + b] == 'z') return error.InvalidVector;
        // An X or U input drives to zero: VIL.
        const levels = [2]f64{ bit.vil, bit.vih };
        var prev = states.items[b];
        try out.print(arena, "vvec_{s} {s} {s} pwl(0 {e}", .{ bit.name, bit.name, bit.ref, levels[@intFromBool(prev == '1')] });
        var points: usize = 1;
        for (times.items, 0..) |t, r| {
            const s = states.items[r * n + b];
            if (levels[@intFromBool(s == '1')] == levels[@intFromBool(prev == '1')]) continue;
            points += 2;
            if (points > max_points) return error.InvalidVector;
            const start = (t + bit.idelay) * unit;
            const edge = if (s == '1') bit.trise else bit.tfall;
            const ramp = if (edge) |e| e * unit else 0.1e-9;
            try out.print(arena, " {e} {e} {e} {e}", .{ start, levels[@intFromBool(prev == '1')], start + ramp, levels[@intFromBool(s == '1')] });
            prev = s;
        }
        try out.appendSlice(arena, ")\n");
    }
    return out.items;
}

/// `TUNIT [m] u` or `TUNIT mu`: the unit `u` (fs to ms) times the plain
/// number `m` (CR p.755-756: `tunit 999ns` and `tunit .99 ps` are legal,
/// `tunit .99eps` is not).
fn timeUnit(args: []const []const u8) Error!f64 {
    const text, const glued = switch (args.len) {
        1 => .{ args[0], true },
        2 => .{ args[1], false },
        else => return error.InvalidVector,
    };
    if (text.len < 2 or (!glued and text.len != 2)) return error.InvalidVector;
    const u = units.get(text[text.len - 2 ..]) orelse return error.InvalidVector;
    const m = if (glued) text[0 .. text.len - 2] else args[0];
    if (m.len == 0 and glued) return u;
    if (m[0] == '+' or m[0] == '-') return error.InvalidVector;
    return u * try number(m);
}

/// The bits a VNAME entry covers: its `[hi:lo]` range's, else 1.
fn busWidth(v: []const u8) Error!usize {
    const r = try range(v) orelse return 1;
    return std.math.cast(usize, @abs(@as(i64, r.hi) - r.lo) + 1) orelse error.InvalidVector;
}

const Range = struct { base: []const u8, open: []const u8, close: []const u8, hi: u32, lo: u32 };

/// A bus `id G [hi:lo] G'`: the innermost `[hi:lo]` is the range and the
/// grouping around it is kept, balanced (CR p.760: `a[[0:3]]` names
/// `a[0]`, `vb<[4:1]>` names `vb<4>`, `vb[12:1]` names `vb12`). Null for a
/// plain identifier.
fn range(v: []const u8) Error!?Range {
    const opens = "[{(<";
    const closes = "]})>";
    const start = std.mem.indexOfAny(u8, v, opens) orelse {
        try ident(v);
        return null;
    };
    try ident(v[0..start]);
    const lb = std.mem.lastIndexOfScalar(u8, v, '[') orelse return error.InvalidVector;
    if (lb < start) return error.InvalidVector;
    const rb = lb + (std.mem.indexOfScalar(u8, v[lb..], ']') orelse return error.InvalidVector);
    const open = v[start..lb];
    const close = v[rb + 1 ..];
    if (open.len != close.len) return error.InvalidVector;
    for (open, 0..) |c, i| {
        const k = std.mem.indexOfScalar(u8, opens, c) orelse return error.InvalidVector;
        if (close[close.len - 1 - i] != closes[k]) return error.InvalidVector;
    }
    const inner = v[lb + 1 .. rb];
    const colon = std.mem.indexOfScalar(u8, inner, ':') orelse return error.InvalidVector;
    return .{ .base = v[0..start], .open = open, .close = close, .hi = try index(inner[0..colon]), .lo = try index(inner[colon + 1 ..]) };
}

fn ident(v: []const u8) Error!void {
    if (v.len == 0 or !(std.ascii.isAlphabetic(v[0]) or v[0] == '_')) return error.InvalidVector;
    for (v) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return error.InvalidVector;
}

fn index(text: []const u8) Error!u32 {
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidVector;
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidVector;
}

/// Names the bits of one VNAME entry, MSB first (`range`).
fn names(arena: std.mem.Allocator, v: []const u8, out: []Bit) Error!void {
    const r = try range(v) orelse {
        out[0].name = v;
        return;
    };
    std.debug.assert(@abs(@as(i64, r.hi) - r.lo) + 1 == out.len);
    for (out, 0..) |*bit, k| {
        const i: i64 = if (r.hi >= r.lo) @as(i64, r.hi) - @as(i64, @intCast(k)) else @as(i64, r.hi) + @as(i64, @intCast(k));
        bit.name = try arena.print("{s}{s}{d}{s}", .{ r.base, r.open, i, r.close });
    }
}

/// Which bits a waveform statement's mask selects; every bit with no mask.
fn maskBits(arena: std.mem.Allocator, mask: []const []const u8, digits: []const u8, n: usize) Error![]bool {
    const on = try arena.alloc(bool, n);
    if (mask.len == 0) {
        @memset(on, true);
        return on;
    }
    const chars = try std.mem.concat(arena, u8, mask);
    if (chars.len != digits.len) return error.InvalidVector;
    var b: usize = 0;
    for (chars, digits) |c, w| {
        const v = std.fmt.charToDigit(c, 16) catch return error.InvalidVector;
        var k = w;
        while (k > 0) {
            k -= 1;
            on[b] = v >> @intCast(k) & 1 == 1;
            b += 1;
        }
    }
    return on;
}

/// A plain decimal number: no scale suffix, `inf`, `nan` or hex (the time
/// group is in TUNIT units, SA p.268).
fn number(text: []const u8) Error!f64 {
    return plainNumber(text) orelse error.InvalidVector;
}

test "a vector file becomes PWL inputs and .dout outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try expand(arena.allocator(),
        \\; two inputs and a 2-bit output
        \\radix 1 1 2
        \\vname a b q[[1:0]]
        \\io i i o
        \\tunit ns
        \\slope 0.5
        \\vih 5 1 0 0
        \\vth 2.5
        \\10 1 0 x
        \\20 0 1 2
    );
    try std.testing.expectEqualStrings(
        \\vvec_a a 0 pwl(0 5e0 2e-8 5e0 2.05e-8 0e0)
        \\vvec_b b 0 pwl(0 0e0 2e-8 0e0 2.05e-8 3.3e0)
        \\.dout q[1] 2.5e0 ( 2e-8 1 )
        \\.dout q[0] 2.5e0 ( 2e-8 0 )
        \\
    , text);
    try std.testing.expectError(error.InvalidVector, expand(arena.allocator(), "radix 1\nvname a\nio b\n10 1\n"));
}

test "vector files: hex digits, PERIOD rows and malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // One hex digit is four bits, MSB first; PERIOD rows carry no time.
    const text = try expand(a, "radix 4\nvname d[3:0]\nio i\nperiod 10\nslope 0\na\n5\n");
    var it = std.mem.splitScalar(u8, text, '\n');
    for ([_][]const u8{ "vvec_d3 d3 0 pwl(0 3.3e0 ", "vvec_d2 d2 0 pwl(0 0e0 ", "vvec_d1 d1 0 pwl(0 3.3e0 ", "vvec_d0 d0 0 pwl(0 0e0 " }) |head|
        try std.testing.expect(std.mem.startsWith(u8, it.next().?, head));
    try std.testing.expectEqualStrings("", it.next().?);
    try std.testing.expectEqual(null, it.next());
    for ([_][]const u8{
        "",
        "radix 1\n",
        "radix 5\nvname a\n10 1\n",
        "radix 1\nvname a b\n",
        "radix 1\nvname a[1:0]\n",
        "radix 1\nvname a[2147483647:-2147483648]\n",
        "radix 1\nvname a\ntunit hours\n",
        "radix 1\nvname a\nout 1\n10 1\n",
        "radix 1\nvname a\nenable 1\n10 1\n",
        "radix 1\nvname a\n10 2\n",
        "radix 1\nvname a\n10 1 1\n",
        "radix 1\nvname a\nvih 5 11\n10 1\n",
        "radix 1\nvname a\n10 1\nradix 1\n20 1 0\n", // RADIX after data
        "radix 1\nradix 1\nvname a\n10 1\n", // a second RADIX
        "vname a\nradix 1\n10 1\n", // RADIX not first
        "radix 1\nvname a\ntunit .99eps\n10 1\n",
        "radix 1\nvname a\ntunit .99 e+6ps\n10 1\n",
        "radix 1\nvname a\nvih inf\n10 1\n",
        "radix 1\nvname a\nvih 5v\n10 1\n",
        "radix 1\nvname a\n10 z\n", // Z on an input
        "radix 1\nvname a\n20 1\n10 0\n", // rows out of order
        "radix 4\nvname a\n10 1\n", // a plain name on four bits
        "radix 1\nvname a<[0:0]]\n10 1\n", // unbalanced grouping
    }) |src| try std.testing.expectError(error.InvalidVector, expand(a, src));
    // V1, V3-V10: names fill bits, not RADIX tokens; V1, V2... by default;
    // TUNIT takes a multiplier; IO `u` drops a bit; SLOPE defaults to
    // 0.1 ns; VOH/VOL replace VTH; Z expects nothing; TSKIP keeps a time.
    try std.testing.expectEqualStrings(
        \\vvec_v1 v1 0 pwl(0 0e0 2e-11 0e0 1.2e-10 3.3e0)
        \\.dout v3 6.6e-1 3e0 ( 0e0 0 )
        \\
    , try expand(a, "radix 111\nio iuo\ntunit 2 ps\nvoh 3\nperiod 10\ntskip\n5 000\n7 11z\n"));
    try std.testing.expectEqualStrings(
        \\vvec_vb<1> vb<1> 0 pwl(0 3.3e0)
        \\vvec_vb<0> vb<0> 0 pwl(0 0e0)
        \\vvec_c{[3]} c{[3]} 0 pwl(0 0e0)
        \\
    , try expand(a, "radix 21\nvname vb<[1:0]> c{[[3:3]]}\n1 2 0\n"));
}

test {
    _ = @import("tests/vec.zig");
}
