//! Fuzz, round-trip and allocation-failure tests for sparam.zig. The
//! Touchstone oracle: no panic, no leak, an error only from `sparam.Error`,
//! and on success a network whose frequencies ascend and whose samples are
//! all finite. Round trips: Y data at R = 1 reads back bit for bit, and a
//! one-port's S, written from a chosen Y by S = (1 − y)/(1 + y), reads back
//! as that Y.
const std = @import("std");
const sparam = @import("../sparam.zig");
const Smith = std.testing.Smith;
/// tests/seeded.zig's generator source, kept here: sparam.zig belongs to
/// the wfit and builder modules, seeded.zig to netlist's.
const Seeded = struct {
    r: std.Random,

    pub fn index(self: *Seeded, len: usize) usize {
        return self.r.uintLessThan(usize, len);
    }

    pub fn eosWeightedSimple(self: *Seeded, false_weight: u64, true_weight: u64) bool {
        return self.r.uintLessThan(u64, false_weight + true_weight) < true_weight;
    }
};
const Cx = std.math.Complex(f64);

fn check(gpa: std.mem.Allocator, bytes: []const u8, ports: usize) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const net = sparam.parseTouchstone(arena.allocator(), bytes, ports) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidTouchstone, error.SingularSParameters => return,
    };
    const nf = net.freq.len;
    try std.testing.expect(nf > 0 and net.ports == ports);
    try std.testing.expectEqual(ports * ports * nf, net.re.len);
    try std.testing.expectEqual(net.re.len, net.im.len);
    for (net.freq, 0..) |f, k| try std.testing.expect(f >= 0 and std.math.isFinite(f) and (k == 0 or f > net.freq[k - 1]));
    for (net.re, net.im) |r, i| try std.testing.expect(std.math.isFinite(r) and std.math.isFinite(i));
}

fn fuzzRaw(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 12]u8 = undefined;
    const ports: usize = if (s.eosWeightedSimple(15, 1)) s.index(66) else 1 + s.index(4);
    try check(std.testing.allocator, buf[0..s.slice(&buf)], ports);
}

test "fuzz sparam.parseTouchstone: raw bytes" {
    try std.testing.fuzz({}, fuzzRaw, .{ .corpus = &.{
        "# MHz S RI R 50\n1 0 0 0.5 0 0.5 0 0 0\n2 0 0 0.5 0 0.5 0 0 0\n",
        "! c\n# Hz S DB R 50\n1 -6.02 0\n2 -6.02 10\r\n",
        "# GHz Z MA R 75\n1 1 0\n",
    } });
}

const options = [_][]const u8{ "hz", "KHz", "MHZ", "ghz", "s", "y", "z", "h", "ma", "db", "ri", "r 50", "r 1", "r 0", "r -1", "r", "q", "x" };
const numbers = [_][]const u8{ "0", "1", "-1", "0.5", "2", "1e3", "1e-9", "-180", "90", "1e300", "1e6", "7000", "nan", "inf", "1k", "0x1p3", "3.", ".5", "-0", "1e-320" };

/// A Touchstone-shaped file: comments, maybe an option line, rows of
/// numbers that mostly fit the port count, sometimes a noise block.
fn file(src: anytype, w: *std.Io.Writer, ports: usize) void {
    const eol = [_][]const u8{ "\n", "\r\n", "\r" };
    const nl = eol[src.index(eol.len)];
    if (src.eosWeightedSimple(3, 1)) w.print("! comment{s}", .{nl}) catch return;
    if (!src.eosWeightedSimple(1, 7)) {
        w.writeAll("#") catch return;
        while (!src.eosWeightedSimple(2, 1)) w.print(" {s}", .{options[src.index(options.len)]}) catch return;
        w.writeAll(nl) catch return;
    }
    var f: u32 = 1;
    while (!src.eosWeightedSimple(4, 1)) {
        const per_row = 2 * ports * ports + if (src.eosWeightedSimple(15, 1)) src.index(3) else 0;
        f += @intCast(src.index(3)); // Sometimes repeats a frequency.
        w.print("{d}", .{f}) catch return;
        for (0..per_row) |k| {
            w.print("{s}{s}", .{ if (k % 8 == 7) nl else " ", numbers[if (src.eosWeightedSimple(3, 1)) src.index(numbers.len) else src.index(8)] }) catch return;
        }
        w.writeAll(if (src.eosWeightedSimple(7, 1)) " ! trailing" else "") catch return;
        w.writeAll(nl) catch return;
    }
    if (ports == 2 and src.eosWeightedSimple(3, 1)) w.print("1 2.0 0.5 0 0.1{s}2 2.0 0.5 0 0.1{s}", .{ nl, nl }) catch return;
}

fn fuzzFile(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 13]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ports = 1 + s.index(4);
    file(s, &w, ports);
    try check(std.testing.allocator, w.buffered(), ports);
}

test "fuzz sparam.parseTouchstone: Touchstone-shaped files" {
    try std.testing.fuzz({}, fuzzFile, .{});
}

test "sparam: 5000 seeded Touchstone-shaped files parse or fail with a declared error" {
    var prng: std.Random.DefaultPrng = .init(0x5a9a_0001);
    var src: Seeded = .{ .r = prng.random() };
    var buf: [1 << 13]u8 = undefined;
    var parsed: usize = 0;
    for (0..5000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        const ports = 1 + src.index(4);
        file(&src, &w, ports);
        try check(std.testing.allocator, w.buffered(), ports);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        parsed += @intFromBool(if (sparam.parseTouchstone(arena.allocator(), w.buffered(), ports)) |_| true else |_| false);
    }
    // The generator reaches past the refusals.
    try std.testing.expect(parsed > 100);
}

test "sparam: Y data at R = 1 reads back bit for bit, in the 2-port column order" {
    var prng: std.Random.DefaultPrng = .init(0x5a9a_0002);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (1..5) |ports| {
        const pp = ports * ports;
        const nf = 3;
        var want_re: [16 * nf]f64 = undefined;
        var want_im: [16 * nf]f64 = undefined;
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "# Hz Y RI R 1\n");
        for (0..nf) |k| {
            try text.print(a, "{d}", .{k + 1});
            for (0..pp) |q| {
                const re = r.floatNorm(f64) * 1e3;
                const im = r.floatNorm(f64) * 1e-3;
                try text.print(a, " {e} {e}", .{ re, im });
                // The file's q-th pair is entry (q % 2)·2 + q / 2 of a 2-port.
                const e = if (ports == 2) (q % 2) * 2 + q / 2 else q;
                want_re[e * nf + k] = re;
                want_im[e * nf + k] = im;
            }
            try text.append(a, '\n');
        }
        const net = try sparam.parseTouchstone(a, text.items, ports);
        try std.testing.expectEqualSlices(f64, want_re[0 .. pp * nf], net.re);
        try std.testing.expectEqualSlices(f64, want_im[0 .. pp * nf], net.im);
    }
}

test "sparam: a one-port's S reads back as the Y it was written from" {
    var prng: std.Random.DefaultPrng = .init(0x5a9a_0003);
    const r = prng.random();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..200) |_| {
        // y normalized to R = 50 Ω: Y = y/50, S = (1 − y)/(1 + y).
        const y: Cx = .{ .re = @abs(r.floatNorm(f64)) + 0.01, .im = r.floatNorm(f64) };
        const one: Cx = .{ .re = 1, .im = 0 };
        const s = one.sub(y).div(one.add(y));
        const text = try a.print("# Hz S RI R 50\n1 {e} {e}\n", .{ s.re, s.im });
        const net = try sparam.parseTouchstone(a, text, 1);
        try std.testing.expect(net.at(0, 0).sub(y.mul(.{ .re = 1.0 / 50.0, .im = 0 })).magnitude() <= 1e-13 * y.magnitude() / 50);
    }
}

test "sparam: non-finite samples are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 10^(7000/20) overflows.
    try std.testing.expectError(error.InvalidTouchstone, sparam.parseTouchstone(a, "# Hz S DB R 50\n1 7000 0\n", 1));
    // S = −1 + 1e-300: I + S is 1e-300, Y = (2 − 1e-300)/1e-300/50 overflows.
    try std.testing.expectError(error.SingularSParameters, sparam.parseTouchstone(a, "# Hz S RI R 50\n1 -1 1e-310\n", 1));
}

fn fitPipeline(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Y = 1/(R + jωL), R = 10, L = 1 µH, over 1 MHz..100 MHz.
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "# MHz Y RI R 1\n");
    for (1..21) |k| {
        const f = @as(f64, @floatFromInt(k)) * 5e6;
        const y = (Cx{ .re = 1, .im = 0 }).div(.{ .re = 10, .im = 2 * std.math.pi * f * 1e-6 });
        try text.print(a, "{e} {e} {e}\n", .{ f / 1e6, y.re, y.im });
    }
    const net = try sparam.parseTouchstone(a, text.items, 1);
    var f = try sparam.fit(a, net, .{ .max_order = 8 });
    _ = try sparam.enforcePassivity(a, net, &f);
    _ = try sparam.sections(a, f);
}

test "sparam: parse, fit, passivity and sections fail cleanly at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fitPipeline, .{});
}
