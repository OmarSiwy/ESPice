//! ngspice invocation and optional KLU preprocessing. Resolve binaries via PATH
//! in `nix develop .#benchmarking`; the flake lock owns package versions.
const std = @import("std");
const common = @import("job.zig");
pub const executable = "ngspice";
pub const version_flag = "--version";

pub fn prepare(io: std.Io, a: std.mem.Allocator, bin: []const u8, netlist: []const u8, raw_path: []const u8, klu: bool) common.Error!common.Job {
    const source = std.Io.Dir.cwd().realPathFileAlloc(io, netlist, a) catch return error.DeckFailed;
    const raw_dir = std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(raw_path) orelse ".", a) catch return error.ScratchFailed;
    const raw = try std.fmt.allocPrint(a, "{s}/{s}", .{ raw_dir, std.fs.path.basename(raw_path) });
    var deck: []const u8 = source;
    if (klu) {
        const text = std.Io.Dir.cwd().readFileAlloc(io, source, a, .limited(1 << 26)) catch return error.DeckFailed;
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

pub fn deckHasKlu(text: []const u8) bool {
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

test "KLU preprocessing preserves the title and source body" {
    const body = try withKlu(std.testing.allocator, "title\nV1 a 0 1\nR1 a 0 1k\n.op\n.end\n");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("title\n.options klu\nV1 a 0 1\nR1 a 0 1k\n.op\n.end\n", body);
    try std.testing.expect(deckHasKlu(body));
    try std.testing.expect(!deckHasKlu(".options klu\n.op\n.end"));
    try std.testing.expect(!deckHasKlu("title\n.optionsbogus klu\n.op\n.end"));
}
