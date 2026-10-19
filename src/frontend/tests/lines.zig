//! Differential tests of `lines.zig` against `lines_oracle.zig`, the reader
//! before its single-scan rewrite: seeded random line soups must read the
//! same in every dialect. Plus each dialect's line rules, worked by hand.
const std = @import("std");
const lines = @import("../lines.zig");
const oracle = @import("lines_oracle.zig");

/// Bytes the soup draws from: every byte a line rule reads, plus filler.
const soup_bytes = "ab1x .\t\t  +*#$;/'\"\\\n\n\n\r{}(),=@ek-";

fn soup(r: std.Random, buf: []u8) []u8 {
    const n = r.uintLessThan(usize, buf.len);
    for (buf[0..n]) |*c| c.* = soup_bytes[r.uintLessThan(usize, soup_bytes.len)];
    return buf[0..n];
}

fn sameLines(comptime S: type, comptime O: type, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var got: S.Lines = .{ .rest = src, .arena = arena.allocator() };
    var want: O.Lines = .{ .rest = src, .arena = arena.allocator() };
    while (true) {
        const w = try want.next();
        const g = try got.next();
        if (w == null or g == null) {
            if (w != null or g != null) {
                std.debug.print("soup: {any}\n", .{src});
                return error.TestUnexpectedResult;
            }
            return;
        }
        std.testing.expectEqualStrings(w.?, g.?) catch |err| {
            std.debug.print("soup: {any}\n", .{src});
            return err;
        };
    }
}

test "logical lines match the pre-rewrite reader on 20000 random soups" {
    var prng: std.Random.DefaultPrng = .init(0x11e5);
    const r = prng.random();
    var buf: [160]u8 = undefined;
    for (0..20000) |_| {
        const src = soup(r, &buf);
        try sameLines(lines.ngspice, oracle.ngspice, src);
        try sameLines(lines.hspice, oracle.hspice, src);
        try sameLines(lines.spectre, oracle.spectre, src);
    }
    // A Spectre deck that switches into a SPICE region and back.
    try sameLines(lines.spectre, oracle.spectre, "simulator lang=spice\nr1 a b 1\n+ 2\nsimulator lang=spectre\nr2 (a b) resistor\n");
}

test "a SPICE literal longer than 64 bytes reads with a `d` exponent" {
    // The old reader copied a `d` literal into a 64-byte buffer for
    // parseFloat and read a longer one as no number at all.
    const zeros: [70]u8 = @splat('0');
    const long = "1" ++ zeros ++ "d-70";
    try std.testing.expectEqual(@as(?f64, 1), lines.ngspice.parseNum(long));
    try std.testing.expectEqual(@as(?f64, 1e3), lines.hspice.parseNum(long ++ "k"));
}

fn expectLines(comptime S: type, src: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var it: S.Lines = .{ .rest = src, .arena = arena.allocator() };
    for (want) |w| try std.testing.expectEqualStrings(w, (try it.next()) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(null, try it.next());
}

test "ngspice line rules, by ngspice-syntax.md section" {
    // §1.3: an `@` line ends the file.
    try expectLines(lines.ngspice, "r1 a 0 1\n@ stop\nr2 a 0 1\n", &.{"r1 a 0 1"});
    // §1.6: a `+` line with nothing to continue is ignored; `\\` glues the
    // next line on as it is, `+` and all, with one blank between.
    try expectLines(lines.ngspice, "+ x\nr1 a 0 1\n", &.{"r1 a 0 1"});
    try expectLines(lines.ngspice, "r1 a \\\\\n+b 1\n", &.{"r1 a +b 1"});
    // §1.5: a line that is only a `//` comment is a comment line, so the
    // `+` after it continues nothing; a quoted `;` or `$` is text.
    try expectLines(lines.ngspice, "r1 a 0 1\n// c\n+ 2\n", &.{"r1 a 0 1"});
    try expectLines(lines.ngspice, "b1 a 0 v='1 ; $x' ; tail\n", &.{"b1 a 0 v='1 ; $x'"});
    // A `$` inside a name is no comment; after a comma it is.
    try expectLines(lines.ngspice, "r1 a$b 0 1,$c\n", &.{"r1 a$b 0 1,"});
    // Blank and comment lines between a card and its `+` line are skipped.
    try expectLines(lines.ngspice, "r1 a 0\n\n* c\n# d\n$ e\n+ 1\n", &.{"r1 a 0 1"});
}

test "HSPICE line rules, by hspice-syntax.md rule" {
    // L6: ` \` continues with one blank, a quote open across it keeps its
    // `$` as text, and `+` after a break is text.
    try expectLines(lines.hspice, "v1 a 0 'x $y \\\nz'\n", &.{"v1 a 0 'x $y z'"});
    try expectLines(lines.hspice, "r1 a \\\\\n+1\n", &.{"r1 a+1"});
    // L3: a `$` after a number token or a closing quote is a comment.
    try expectLines(lines.hspice, "r1 a 0 1k$c\nr2 a 0 'p'$c\n", &.{ "r1 a 0 1k", "r2 a 0 'p'" });
    // L2: `$` and `*` lead comment lines; L5 skips them before a `+`.
    try expectLines(lines.hspice, "$ x\nr1 a 0\n* y\n+ 1\n", &.{"r1 a 0 1"});
}

test "Spectre line rules, by spectre-syntax.md section" {
    // §1.4: an odd run of trailing backslashes continues; an even run is
    // escaped backslashes, name bytes.
    try expectLines(lines.spectre, "r1 a\\\\\nr2 b\n", &.{ "r1 a\\\\", "r2 b" });
    try expectLines(lines.spectre, "r1 a \\\n b\n", &.{"r1 a b"});
    // §1.3: `*` comments only in the first column; `//` anywhere outside a
    // string.
    try expectLines(lines.spectre, "r1 a\n * b\n", &.{ "r1 a", "* b" });
    try expectLines(lines.spectre, "r1 \"a//b\" // c\n", &.{"r1 \"a//b\""});
}
