//! Architecture fitness check (Principle 14.9): every `.zig` under src/ and
//! tests/ → a list of violations, compared by name with tests/FITNESS.tsv.
//! Checks: a `//!` first line (always enforced); no leaf importing its own
//! module's `root.zig` (AGENTS.md §2.8); no `else =>` without a
//! `// else: <why>` note on its line (Principle 10.2; `inline else` is not a
//! catch-all). The last two are ratchets: the recorded list may only shrink.
//! Run from the repo root; `--update` rewrites the file from a measured run:
//!   zig build test-fitness -- --update
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const fitness_path = "tests/FITNESS.tsv";
/// Trees scanned, relative to the repo root.
const roots = [_][]const u8{ "src", "tests" };
/// Generated or vendored trees under `roots` that are not this project's code.
const skipped = [_][]const u8{ "tests/fixtures/", "tests/suites/", "tests/pending/" };
/// Files under src/ and tests/ number in the hundreds.
const files_max = 4096;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const update = if (args.next()) |a| std.mem.eql(u8, a, "--update") else false;

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    for (roots) |root| try collect(arena, init.io, root, &paths);
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    std.debug.assert(paths.items.len > 0);

    var measured: Io.Writer.Allocating = .init(arena);
    try measured.writer.writeAll("# Measured by tests/fitness.zig; rewrite with `zig build test-fitness -- --update`.\n");
    var headers_missing: u32 = 0;
    for (paths.items) |path| {
        const source = try Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);
        if (!std.mem.startsWith(u8, source, "//!")) {
            std.debug.print("FITNESS {s}: no //! header on the first line\n", .{path});
            headers_missing += 1;
        }
        if (importsOwnRoot(path, source)) try measured.writer.print("root-import\t{s}\n", .{path});
        const catch_alls = unannotatedElse(source);
        if (catch_alls != 0) try measured.writer.print("else\t{s}\t{d}\n", .{ path, catch_alls });
    }
    if (update) {
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = fitness_path, .data = measured.written() });
        std.debug.print("Fitness: wrote {s}\n", .{fitness_path});
        return if (headers_missing == 0) 0 else 1;
    }
    const recorded = Io.Dir.cwd().readFileAlloc(init.io, fitness_path, arena, .unlimited) catch |err| {
        std.debug.print("Fitness: cannot read {s} ({s}); run with --update\n", .{ fitness_path, @errorName(err) });
        return 1;
    };
    var stderr_buf: [256]u8 = undefined;
    var stderr = Io.File.stderr().writer(init.io, &stderr_buf);
    const same = sameLines(&stderr.interface, recorded, measured.written());
    stderr.interface.flush() catch {};
    std.debug.print("Fitness: {d} files, {d} without a header, list {s}\n", .{ paths.items.len, headers_missing, if (same) "unchanged" else "changed" });
    return if (same and headers_missing == 0) 0 else 1;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collect(arena: Allocator, io: Io, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.path });
        for (skipped) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) break;
        } else {
            if (out.items.len >= files_max) return error.TooManyFiles;
            try out.append(arena, path);
        }
    }
}

/// A leaf (any file in a `src/<module>/` tree except that tree's
/// `root.zig`) that imports the module root, closing a cycle through it.
fn importsOwnRoot(path: []const u8, source: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    const rest = path["src/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false; // src/*.zig has no module root
    const in_module = rest[slash + 1 ..];
    if (std.mem.eql(u8, in_module, "root.zig")) return false;
    // Depth below the module directory decides the relative spelling.
    const depth = std.mem.count(u8, in_module, "/");
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    w.writeAll("@import(\"") catch unreachable;
    for (0..depth) |_| w.writeAll("../") catch unreachable;
    w.writeAll("root.zig\")") catch unreachable;
    return std.mem.indexOf(u8, source, w.buffered()) != null;
}

/// `else =>` arms with no `// else:` note on the same line. `inline else`
/// instantiates per tag and is not a catch-all.
fn unannotatedElse(source: []const u8) u32 {
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, code, at, "else =>")) |i| : (at = i + "else =>".len) {
            const inline_arm = i >= "inline ".len and std.mem.eql(u8, code[i - "inline ".len .. i], "inline ");
            if (inline_arm) continue;
            if (std.mem.indexOf(u8, line, "// else:") == null) n += 1;
        }
    }
    return n;
}

/// True when both lists hold the same non-comment lines; prints the rest.
fn sameLines(out: *Io.Writer, recorded: []const u8, measured: []const u8) bool {
    var same = true;
    inline for (.{ .{ recorded, measured, "recorded, not measured" }, .{ measured, recorded, "measured, not recorded" } }) |pair| {
        var it = std.mem.splitScalar(u8, pair[0], '\n');
        while (it.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (!hasLine(pair[1], line)) {
                out.print("FITNESS {s}: {s}\n", .{ pair[2], line }) catch {};
                same = false;
            }
        }
    }
    return same;
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return true;
    return false;
}

test "else arms: inline is exempt, a note exempts, two per line count twice" {
    try std.testing.expectEqual(@as(u32, 0), unannotatedElse("switch (k) { inline else => |t| f(t) }"));
    try std.testing.expectEqual(@as(u32, 0), unannotatedElse("else => {}, // else: every error is fatal here"));
    try std.testing.expectEqual(@as(u32, 1), unannotatedElse("    else => return err,"));
    try std.testing.expectEqual(@as(u32, 2), unannotatedElse("switch (a) { .x => 1, else => 0 } + switch (b) { .y => 1, else => 0 }"));
    try std.testing.expectEqual(@as(u32, 0), unannotatedElse("// an else => in a comment"));
}

test "root imports: leaf spellings by depth; roots and src/*.zig exempt" {
    try std.testing.expect(importsOwnRoot("src/core/deck.zig", "const r = @import(\"root.zig\");"));
    try std.testing.expect(importsOwnRoot("src/analysis/ac/ac.zig", "@import(\"../root.zig\")"));
    try std.testing.expect(!importsOwnRoot("src/analysis/ac/ac.zig", "@import(\"root.zig\")"));
    try std.testing.expect(!importsOwnRoot("src/core/root.zig", "@import(\"root.zig\")"));
    try std.testing.expect(!importsOwnRoot("src/espice.zig", "@import(\"root.zig\")"));
}

test "same lines ignores comments and order" {
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expect(sameLines(&sink.writer, "# a\nx\ny\n", "y\nx\n"));
    try std.testing.expect(!sameLines(&sink.writer, "x\n", "x\ny\n"));
}
