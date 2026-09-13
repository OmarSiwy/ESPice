//! Test support: `std.testing.allocator` behind a vtable that refuses every
//! in-place resize and remap, for `std.testing.checkAllAllocationFailures`
//! sweeps (#128).

const std = @import("std");

/// `std.testing.allocator` that never grows or shrinks a block in place.
/// Whether a large block grows in place depends on the pages around it, so
/// through the plain testing allocator the number of allocations a sweep
/// counts can change between runs (`error.NondeterministicMemoryUsage`).
/// Here every growth is a counted allocation. Test code only.
pub const fixed_growth: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = free,
} };

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.testing.allocator.rawFree(memory, alignment, ret_addr);
}
