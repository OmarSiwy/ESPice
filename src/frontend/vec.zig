//! HSPICE digital vector files [SA Ch.9 "Specifying a Digital Vector File
//! and Mixed Mode Stimuli"; CR .VEC]: `.vec 'file'` becomes netlist text,
//! a PWL voltage source per input bit and a `.dout` card per output bit,
//! as HSPICE converts them. Read: RADIX, VNAME (`name`, `name[hi:lo]`,
//! `name[[hi:lo]]`), IO with `i` and `o`, TUNIT, PERIOD, TDELAY, IDELAY,
//! ODELAY, SLOPE, TRISE, TFALL, VIH, VIL, VOH, VOL, VTH, VREF and OUT/OUTZ
//! 0, each with an optional mask, plus tabular data in hex digits and the
//! 0, 1, X and U states. Not read: bidirectional signals (IO `b`, ENABLE,
//! OPTION CBC), Z, L and H inputs, a nonzero OUT, Verilog-sized values and
//! `.param` names in the file.
const std = @import("std");

const Error = error{ OutOfMemory, InvalidVector };

/// PWL points the source models hold (`pwl_times[0:63]`).
const max_points = 64;

/// One signal bit; every waveform field in the file's time unit or volts.
const Bit = struct {
    name: []const u8 = "",
    output: bool = false,
    ref: []const u8 = "0",
    idelay: f64 = 0,
    odelay: f64 = 0,
    // ponytail: HSPICE's default edge rate is not in the manual; 0.1 time
    // units (0.1 ns at the default TUNIT) until a deck says otherwise.
    trise: f64 = 0.1,
    tfall: f64 = 0.1,
    vih: f64 = 3.3,
    vil: f64 = 0,
    voh: f64 = 2.64,
    vol: f64 = 0.66,
    vth: f64 = 1.65,
};

const units = std.StaticStringMap(f64).initComptime(.{
    .{ "fs", 1e-15 }, .{ "ps", 1e-12 }, .{ "ns", 1e-9 }, .{ "us", 1e-6 }, .{ "ms", 1e-3 }, .{ "s", 1 },
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
    var vectors: std.ArrayList(u32) = .empty; // digits per vector
    var unit: f64 = 1e-9;
    var period: ?f64 = null;
    var vth_given = false;
    // Rows of states, one byte per bit: '0', '1' or 'x'.
    var times: std.ArrayList(f64) = .empty;
    var states: std.ArrayList(u8) = .empty;

    var lines = std.mem.splitScalar(u8, src, '\n');
    var pending: std.ArrayList(u8) = .empty;
    var more = true;
    while (more) {
        const raw = lines.next();
        more = raw != null;
        const line = std.mem.trim(u8, if (raw) |l| l[0 .. std.mem.indexOfScalar(u8, l, ';') orelse l.len] else "", " \t\r");
        if (line.len > 0 and line[0] == '+') {
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
        if (std.mem.eql(u8, key, "radix")) {
            // Rows already read hold one state per bit known so far.
            if (times.items.len != 0) return error.InvalidVector;
            for (args) |v| {
                try vectors.append(arena, @intCast(v.len));
                for (v) |c| {
                    if (c < '1' or c > '4') return error.InvalidVector;
                    try digits.append(arena, c - '0');
                    for (0..c - '0') |_| try bits.append(arena, .{});
                }
            }
        } else if (std.mem.eql(u8, key, "vname")) {
            if (args.len != vectors.items.len) return error.InvalidVector;
            var b: usize = 0;
            var d: usize = 0;
            for (args, vectors.items) |v, n| {
                var width: usize = 0;
                for (digits.items[d..][0..n]) |w| width += w;
                d += n;
                try names(arena, v, bits.items[b..][0..width]);
                b += width;
            }
        } else if (std.mem.eql(u8, key, "io")) {
            const chars = try std.mem.concat(arena, u8, args);
            if (chars.len != digits.items.len) return error.InvalidVector;
            var b: usize = 0;
            for (chars, digits.items) |c, w| {
                if (c != 'i' and c != 'o') return error.InvalidVector;
                for (bits.items[b..][0..w]) |*bit| bit.output = c == 'o';
                b += w;
            }
        } else if (std.mem.eql(u8, key, "tunit")) {
            if (args.len != 1) return error.InvalidVector;
            unit = units.get(args[0]) orelse return error.InvalidVector;
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
                .voh => bit.voh = try number(value),
                .vol => bit.vol = try number(value),
                .vth => {
                    bit.vth = try number(value);
                    vth_given = true;
                },
                .vref => bit.ref = value,
                .out, .outz => if (try number(value) != 0) return error.InvalidVector,
                .triz => {},
            };
        } else if (std.ascii.isAlphabetic(key[0]) and period == null) {
            return error.InvalidVector; // ENABLE, OPTION, a misspelt keyword
        } else {
            // A data row: `[time] digits...`.
            const t = if (period) |p| p * @as(f64, @floatFromInt(times.items.len)) else try number(key);
            const chars = try std.mem.concat(arena, u8, if (period != null) toks.items else args);
            if (chars.len != digits.items.len) return error.InvalidVector;
            try times.append(arena, t);
            for (chars, digits.items) |c, w| {
                const x = c == 'x' or c == 'u';
                const v: u8 = if (x) 0 else std.fmt.charToDigit(c, @as(u8, 1) << @intCast(w)) catch return error.InvalidVector;
                var k = w;
                while (k > 0) {
                    k -= 1;
                    try states.append(arena, if (x) 'x' else if (v >> @intCast(k) & 1 == 1) '1' else '0');
                }
            }
        }
    }
    if (bits.items.len == 0 or times.items.len == 0) return error.InvalidVector;

    var out: std.ArrayList(u8) = .empty;
    const n = bits.items.len;
    for (bits.items, 0..) |bit, b| {
        if (bit.name.len == 0) return error.InvalidVector;
        if (bit.output) {
            if (vth_given) try out.print(arena, ".dout {s} {e} (", .{ bit.name, bit.vth }) else try out.print(arena, ".dout {s} {e} {e} (", .{ bit.name, bit.vol, bit.voh });
            for (times.items, 0..) |t, r| {
                const s = states.items[r * n + b];
                if (s != 'x') try out.print(arena, " {e} {c}", .{ (t + bit.odelay) * unit, s });
            }
            try out.appendSlice(arena, " )\n");
            continue;
        }
        // An X or U input drives to zero.
        const level = struct {
            fn of(x: Bit, s: u8) f64 {
                return if (s == '1') x.vih else x.vil;
            }
        }.of;
        var prev = states.items[b];
        try out.print(arena, "vvec_{s} {s} {s} pwl(0 {e}", .{ bit.name, bit.name, bit.ref, level(bit, prev) });
        var points: usize = 1;
        for (times.items, 0..) |t, r| {
            const s = states.items[r * n + b];
            if (level(bit, s) == level(bit, prev)) continue;
            points += 2;
            if (points > max_points) return error.InvalidVector;
            const start = (t + bit.idelay) * unit;
            const ramp = (if (s == '1') bit.trise else bit.tfall) * unit;
            try out.print(arena, " {e} {e} {e} {e}", .{ start, level(bit, prev), start + ramp, level(bit, s) });
            prev = s;
        }
        try out.appendSlice(arena, ")\n");
    }
    return out.items;
}

/// Names the bits of one vector, MSB first: `name` for one bit,
/// `name[hi:lo]` as `name<hi>`..`name<lo>`, `name[[hi:lo]]` as
/// `name[hi]`..`name[lo]`.
fn names(arena: std.mem.Allocator, v: []const u8, out: []Bit) Error!void {
    const open = std.mem.indexOfScalar(u8, v, '[') orelse {
        if (out.len != 1) return error.InvalidVector;
        out[0].name = v;
        return;
    };
    const base = v[0..open];
    const double = std.mem.startsWith(u8, v[open..], "[[");
    const inner = std.mem.trim(u8, v[open..], "[]");
    const colon = std.mem.indexOfScalar(u8, inner, ':') orelse return error.InvalidVector;
    const hi = std.fmt.parseInt(i32, inner[0..colon], 10) catch return error.InvalidVector;
    const lo = std.fmt.parseInt(i32, inner[colon + 1 ..], 10) catch return error.InvalidVector;
    if (@abs(@as(i64, hi) - lo) + 1 != out.len) return error.InvalidVector;
    const step: i32 = if (hi >= lo) -1 else 1;
    for (out, 0..) |*bit, k| {
        const i = hi + step * @as(i32, @intCast(k));
        bit.name = if (double) try std.fmt.allocPrint(arena, "{s}[{d}]", .{ base, i }) else try std.fmt.allocPrint(arena, "{s}{d}", .{ base, i });
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

fn number(text: []const u8) Error!f64 {
    return std.fmt.parseFloat(f64, text) catch error.InvalidVector;
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
        "radix 1\n10 1\n", // a bit without a name
    }) |src| try std.testing.expectError(error.InvalidVector, expand(a, src));
}
