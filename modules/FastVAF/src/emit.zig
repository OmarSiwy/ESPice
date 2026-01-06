//! Shared backend for both pipelines (`v/` Verilog, `va/` Verilog-A).
//!
//! Both backends emit Zig source that targets the same `contract` ABI, so
//! everything contract-shaped lives here exactly once: identifier legality,
//! the full dyn ABI v3 export block, and the validate footer. The pipelines
//! differ only in how they produce physics/logic — never in the ABI surface.
//!
//! Also home of `Buf(T)`: the project-wide growable pool. Structs in this
//! codebase carry no std.ArrayList — flat SoA (`std.MultiArrayList`), fixed
//! caps derived from contract limits, or a Buf.

const std = @import("std");

// ============================================================================
// Buf(T): grow-by-doubling pool. 16 bytes of header (ptr + u32 len + u32 cap)
// vs ArrayList's 24; u32 lengths because nothing here exceeds 4Gi elements.
// ============================================================================

pub fn Buf(comptime T: type) type {
    return struct {
        ptr: [*]T = undefined,
        len: u32 = 0,
        cap: u32 = 0,

        const Self = @This();

        pub const empty: Self = .{};

        pub fn slice(self: Self) []T {
            return self.ptr[0..self.len];
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            if (self.cap != 0) gpa.free(self.ptr[0..self.cap]);
            self.* = .{};
        }

        pub fn ensureTotalCapacity(self: *Self, gpa: std.mem.Allocator, want: usize) !void {
            if (want <= self.cap) return;
            var new_cap: u32 = if (self.cap == 0) 16 else self.cap;
            while (new_cap < want) new_cap *|= 2;
            const new = if (self.cap != 0)
                try gpa.realloc(self.ptr[0..self.cap], new_cap)
            else
                try gpa.alloc(T, new_cap);
            self.ptr = new.ptr;
            self.cap = new_cap;
        }

        pub fn append(self: *Self, gpa: std.mem.Allocator, item: T) !void {
            try self.ensureTotalCapacity(gpa, self.len + 1);
            self.ptr[self.len] = item;
            self.len += 1;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.ptr[self.len] = item;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, gpa: std.mem.Allocator, items: []const T) !void {
            try self.ensureTotalCapacity(gpa, self.len + items.len);
            @memcpy(self.ptr[self.len..][0..items.len], items);
            self.len += @intCast(items.len);
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.ptr[self.len];
        }

        /// Shrink to exact size and hand the memory to the caller.
        pub fn toOwnedSlice(self: *Self, gpa: std.mem.Allocator) ![]T {
            if (self.cap == 0) return &.{};
            const out = try gpa.realloc(self.ptr[0..self.cap], self.len);
            self.* = .{};
            return out;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }
    };
}

// ============================================================================
// Identifier legality
// ============================================================================

pub const Error = error{InvalidName} || std.Io.Writer.Error;

pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Universal Zig identifier legality: non-empty, ident chars only, no leading
/// digit, and not a Zig keyword or primitive type. This is the part shared by
/// both pipelines — the per-pipeline set of self-declared names (which would
/// *shadow* rather than fail to parse) is checked separately by each backend,
/// since those namespaces differ (digital pins vs analog nodes/params).
pub fn validateIdent(name: []const u8) Error!void {
    if (name.len == 0) return Error.InvalidName;
    for (name, 0..) |c, idx| {
        if (!isIdentChar(c)) return Error.InvalidName;
        if (idx == 0 and std.ascii.isDigit(c)) return Error.InvalidName;
    }
    if (std.zig.Token.keywords.has(name)) return Error.InvalidName;
    if (std.zig.primitives.isPrimitive(name)) return Error.InvalidName;
}

/// Write `name` as a Zig identifier, escaping with `@"..."` when it is not a
/// plain-legal identifier (keyword, primitive, or leading digit). Source-derived
/// names (Verilog-A params/nodes like `type`) go through this so the emitted Zig
/// is always valid.
pub fn writeIdent(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    if (validateIdent(name)) {
        try w.writeAll(name);
    } else |_| {
        try w.print("@\"{s}\"", .{name});
    }
}

// ============================================================================
// Dyn ABI v3 — the single definition both generated-device shapes share.
// All Model/Instance/State access is byte-copy: the engine's buffers carry
// no alignment guarantee, so pointer casts are never emitted.
// ============================================================================

// ============================================================================
// Tests
// ============================================================================

test "validateIdent rejects keywords, primitives and bad names" {
    try std.testing.expectError(Error.InvalidName, validateIdent(""));
    try std.testing.expectError(Error.InvalidName, validateIdent("1a"));
    try std.testing.expectError(Error.InvalidName, validateIdent("a-b"));
    try std.testing.expectError(Error.InvalidName, validateIdent("var"));
    try std.testing.expectError(Error.InvalidName, validateIdent("u64"));
    // Analog names that a device may legitimately use as nodes/params.
    try validateIdent("t");
    try validateIdent("q");
    try validateIdent("clk_in");
    try validateIdent("Vth0");
}

test "Buf append/grow/toOwnedSlice" {
    const gpa = std.testing.allocator;
    var b: Buf(u32) = .empty;
    defer b.deinit(gpa);
    for (0..100) |i| try b.append(gpa, @intCast(i));
    try std.testing.expectEqual(@as(u32, 100), b.len);
    try std.testing.expectEqual(@as(u32, 42), b.slice()[42]);
    const owned = try b.toOwnedSlice(gpa);
    defer gpa.free(owned);
    try std.testing.expectEqual(@as(usize, 100), owned.len);
    try std.testing.expectEqual(@as(u32, 0), b.len);
}

