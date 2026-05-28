//! ngspice adapter for the benchmark: the batch command line, plus an
//! optional `.options klu` copy of the deck. The binary comes from PATH in
//! `nix develop .#benchmarking`, whose flake lock pins its version.
const std = @import("std");
const common = @import("job.zig");
pub const version_flag = "--version";

/// A batch job writing `raw_path`. With `klu`, a deck that lacks the option
/// runs from a copy beside `raw_path` with `.options klu` inserted.
pub fn prepare(io: std.Io, a: std.mem.Allocator, bin: []const u8, netlist: []const u8, raw_path: []const u8, klu: bool) common.Error!common.Job {
    const source = std.Io.Dir.cwd().realPathFileAlloc(io, netlist, a) catch return error.DeckFailed;
    const raw_dir = std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(raw_path) orelse ".", a) catch return error.ScratchFailed;
    const raw = try std.fmt.allocPrint(a, "{s}/{s}", .{ raw_dir, std.fs.path.basename(raw_path) });
    const text = std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(1 << 27)) catch return error.DeckFailed;
    if (hasPsp(text)) return .{ .refused = "ngspice-45 has no PSP103 (LEVEL=1040)" };
    var deck: []const u8 = source;
    if (klu) {
        if (!deckHasKlu(text)) {
            deck = try std.fmt.allocPrint(a, "{s}.sp", .{raw});
            const body = try withKlu(a, text);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = deck, .data = body }) catch return error.DeckFailed;
        }
    }
    return .{
        .argv = try a.dupe([]const u8, &.{ bin, "-n", "-b", "-r", raw, deck }),
        .cwd = .{ .path = std.fs.path.dirname(source).? },
        .raw = raw,
    };
}

/// Whether the deck names espice's PSP103 level. ngspice-45 accepts the
/// card and simulates something else, slowly.
fn hasPsp(text: []const u8) bool {
    var i: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(text, i, "level")) |at| : (i = at + 5) {
        var rest = std.mem.trimStart(u8, text[at + 5 ..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        if (std.mem.startsWith(u8, rest, "1040")) return true;
    }
    return false;
}

/// Whether any `.option(s)` card after the title names `klu`.
fn deckHasKlu(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next(); // SPICE title is never an option card.
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const card = words.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(card, ".option") and !std.ascii.eqlIgnoreCase(card, ".options")) continue;
        while (words.next()) |word| if (std.ascii.eqlIgnoreCase(word, "klu")) return true;
    }
    return false;
}

fn withKlu(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.fmt.allocPrint(a, "{s}\n.options klu\n{s}", .{ text[0..nl], text[@min(nl + 1, text.len)..] });
}

test "a PSP103 deck is refused" {
    try std.testing.expect(hasPsp("t\n.model n nmos(LEVEL = 1040 toxo=1e-9)\n"));
    try std.testing.expect(!hasPsp("t\n.model n nmos(level=54)\n"));
}

test "KLU preprocessing preserves the title and source body" {
    const body = try withKlu(std.testing.allocator, "title\nV1 a 0 1\nR1 a 0 1k\n.op\n.end\n");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("title\n.options klu\nV1 a 0 1\nR1 a 0 1k\n.op\n.end\n", body);
    try std.testing.expect(deckHasKlu(body));
    try std.testing.expect(!deckHasKlu(".options klu\n.op\n.end"));
    try std.testing.expect(!deckHasKlu("title\n.optionsbogus klu\n.op\n.end"));
}
