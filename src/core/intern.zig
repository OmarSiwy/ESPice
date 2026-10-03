//! Net and device names, each stored once: bytes plus u32 offsets,
//! deduplicated through a map keyed by the dense id itself.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Dense id of an interned name, in first-seen order.
pub const Name = enum(u32) {
    _,
    pub inline fn index(n: Name) u32 {
        return @backingInt(n);
    }
};

/// Deduplicating string table. Names live in one byte buffer; the map holds
/// only ids and hashes the stored bytes on demand.
pub const InternPool = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// `offs[i]` starts name i; one trailing entry ends the last name.
    offs: std.ArrayList(u32) = .empty,
    map: std.HashMapUnmanaged(Name, void, Context, std.hash_map.default_max_load_percentage) = .empty,

    /// Hashes a stored name through the offsets, so a key is just its id.
    const Context = struct {
        pool: *const InternPool,
        pub fn hash(ctx: Context, n: Name) u64 {
            return std.hash_map.hashString(ctx.pool.str(n));
        }
        pub fn eql(_: Context, a: Name, b: Name) bool {
            return a == b;
        }
    };

    /// Looks a string up against stored ids without interning it.
    const Adapter = struct {
        pool: *const InternPool,
        pub fn hash(_: Adapter, s: []const u8) u64 {
            return std.hash_map.hashString(s);
        }
        pub fn eql(ctx: Adapter, s: []const u8, n: Name) bool {
            return std.mem.eql(u8, s, ctx.pool.str(n));
        }
    };

    pub fn deinit(p: *InternPool, gpa: Allocator) void {
        p.bytes.deinit(gpa);
        p.offs.deinit(gpa);
        p.map.deinit(gpa);
        p.* = undefined;
    }

    /// Returns the id of `s`, adding it on first sight. May invalidate
    /// slices returned by `str`. Leaves the pool unchanged on error.
    pub fn intern(p: *InternPool, gpa: Allocator, s: []const u8) Allocator.Error!Name {
        if (p.offs.items.len == 0) try p.offs.append(gpa, 0);
        const gop = try p.map.getOrPutContextAdapted(gpa, s, Adapter{ .pool = p }, .{ .pool = p });
        if (gop.found_existing) return gop.key_ptr.*;
        errdefer p.map.removeByPtr(gop.key_ptr);
        const n: Name = @fromBackingInt(@intCast(p.offs.items.len - 1));
        try p.bytes.appendSlice(gpa, s);
        errdefer p.bytes.shrinkRetainingCapacity(p.bytes.items.len - s.len);
        try p.offs.append(gpa, @intCast(p.bytes.items.len));
        gop.key_ptr.* = n;
        return n;
    }

    /// Pre-sizes the map for `names` distinct names.
    pub fn reserve(p: *InternPool, gpa: Allocator, names: u32) Allocator.Error!void {
        try p.map.ensureTotalCapacityContext(gpa, names, .{ .pool = p });
    }

    /// Returns the id of `s` if it was interned, without adding it.
    pub fn find(p: *const InternPool, s: []const u8) ?Name {
        return p.map.getKeyAdapted(s, Adapter{ .pool = p });
    }

    /// Returns the bytes of `n`. Valid until the next `intern`.
    pub fn str(p: *const InternPool, n: Name) []const u8 {
        return p.bytes.items[p.offs.items[n.index()]..p.offs.items[n.index() + 1]];
    }
};

test "names intern once, in first-seen order" {
    const gpa = std.testing.allocator;
    var p: InternPool = .{};
    defer p.deinit(gpa);
    const a = try p.intern(gpa, "x1.out");
    const b = try p.intern(gpa, "r1");
    for (0..100) |i| {
        var buf: [8]u8 = undefined;
        _ = try p.intern(gpa, try std.fmt.bufPrint(&buf, "n{d}", .{i}));
    }
    try std.testing.expectEqual(a, try p.intern(gpa, "x1.out"));
    try std.testing.expectEqual(@as(u32, 1), b.index());
    try std.testing.expectEqualStrings("r1", p.str(b));
    try std.testing.expectEqualStrings("n99", p.str(p.find("n99").?));
    try std.testing.expectEqual(a, p.find("x1.out").?);
    try std.testing.expectEqual(null, p.find("x1"));
}
