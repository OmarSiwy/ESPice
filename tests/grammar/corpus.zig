//! tests/fixtures -> every deck with the dialect its `.expected.json` reads
//! it in: the corpus each grammar must accept, as zig-spec checks
//! grammar.peg against a directory of real Zig files.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const netlist = @import("netlist");

/// One fixture deck, its bytes and its dialect.
pub const Deck = struct { path: []const u8, src: []const u8, dialect: netlist.Dialect };

/// Every `.sp` deck under `tests/fixtures`, sorted by path, read into
/// `arena`. Runs from the repository root (build.zig sets the cwd).
pub fn load(arena: Allocator, io: Io) ![]Deck {
    var dir = try Io.Dir.cwd().openDir(io, "tests/fixtures", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var decks: std.ArrayList(Deck) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".sp")) continue;
        const path = try arena.dupe(u8, entry.path);
        const json_path = try std.mem.concat(arena, u8, &.{ path[0 .. path.len - 3], ".expected.json" });
        const json = try dir.readFileAlloc(io, json_path, arena, .limited(64 << 20));
        try decks.append(arena, .{
            .path = path,
            .src = try dir.readFileAlloc(io, path, arena, .limited(64 << 20)),
            .dialect = dialectOf(json),
        });
    }
    std.mem.sort(Deck, decks.items, {}, struct {
        fn less(_: void, a: Deck, b: Deck) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    std.debug.assert(decks.items.len > 0);
    return decks.items;
}

/// The `"tokenizer"` an oracle file names; ngspice when it names none.
fn dialectOf(json: []const u8) netlist.Dialect {
    const key = "\"tokenizer\"";
    const at = std.mem.indexOf(u8, json, key) orelse return .ngspice;
    const rest = json[at + key.len ..];
    const open = std.mem.indexOfScalar(u8, rest, '"') orelse return .ngspice;
    const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse return .ngspice;
    return std.meta.stringToEnum(netlist.Dialect, rest[open + 1 .. close]) orelse .ngspice;
}

test dialectOf {
    try std.testing.expectEqual(netlist.Dialect.hspice, dialectOf("{\"schema_version\": 1, \"tokenizer\": \"hspice\"}"));
    try std.testing.expectEqual(netlist.Dialect.ngspice, dialectOf("{\"schema_version\": 1}"));
}
