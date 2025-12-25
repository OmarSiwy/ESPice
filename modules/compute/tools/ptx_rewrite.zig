//! LLVM IR rewrite step of the nvptx kernel pipeline.
//!
//! Zig 0.16's nvptx64 backend emits each exported kernel as
//!
//!   @<name> = alias void (...), ptr @<ns>.<fn>
//!   define internal ptx_kernel void @<ns>.<fn>(...) { ... }
//!
//! which llc rejects ("NVPTX aliasee must be a non-kernel function
//! definition"). This tool deletes every alias line and renames the aliasee's
//! define to the exported name (dropping `internal`), producing IR llc accepts:
//!
//!   define ptx_kernel void @<name>(...) { ... }
//!
//! Usage: ptx_rewrite <input.ll> <output.ll>

const std = @import("std");

const Alias = struct { name: []const u8, aliasee: []const u8 };

fn identEnd(s: []const u8) usize {
    for (s, 0..) |c, i| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '$', '-' => {},
        else => return i,
    };
    return s.len;
}

/// Parse `@NAME = ... alias ..., ptr @ALIASEE` (returns null for non-alias lines).
fn parseAlias(line: []const u8) ?Alias {
    if (!std.mem.startsWith(u8, line, "@")) return null;
    if (std.mem.indexOf(u8, line, " alias ") == null) return null;
    const name = line[1 .. identEnd(line[1..]) + 1];
    const at = std.mem.lastIndexOfScalar(u8, line, '@') orelse return null;
    if (at == 0) return null;
    const rest = line[at + 1 ..];
    const aliasee = rest[0..identEnd(rest)];
    if (name.len == 0 or aliasee.len == 0) return null;
    return .{ .name = name, .aliasee = aliasee };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: ptx_rewrite <input.ll> <output.ll>\n", .{});
        return error.BadUsage;
    }

    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(256 * 1024 * 1024));

    // Pass 1: collect aliases.
    var aliases: std.ArrayList(Alias) = .empty;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (parseAlias(line)) |a| try aliases.append(arena, a);
    }

    // Pass 2: drop alias lines, rewrite the aliasee defines.
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len);
    var first = true;
    it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (parseAlias(line) != null) continue;
        if (!first) try out.append(arena, '\n');
        first = false;

        if (std.mem.startsWith(u8, line, "define ")) blk: {
            for (aliases.items) |a| {
                const marker = try std.fmt.allocPrint(arena, "@{s}(", .{a.aliasee});
                const pos = std.mem.indexOf(u8, line, marker) orelse continue;
                // "define internal ptx_kernel ... @aliasee(" -> "define ptx_kernel ... @name("
                // (zig emits `internal` normally and `private` under -fstrip;
                // either way the renamed kernel must be externally visible so
                // llc marks the entry `.visible`.)
                const head = line[0..pos];
                var body = head["define ".len..];
                for ([_][]const u8{ "internal ", "private " }) |linkage| {
                    if (std.mem.startsWith(u8, body, linkage)) {
                        body = body[linkage.len..];
                        break;
                    }
                }
                try out.appendSlice(arena, "define ");
                try out.appendSlice(arena, body);
                try out.append(arena, '@');
                try out.appendSlice(arena, a.name);
                try out.appendSlice(arena, line[pos + marker.len - 1 ..]);
                break :blk;
            }
            try out.appendSlice(arena, line);
        } else {
            try out.appendSlice(arena, line);
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.items });
}
