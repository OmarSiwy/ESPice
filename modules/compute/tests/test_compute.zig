//! Host-side tests that must pass with or without a GPU/driver present.
//! The e2e saxpy launch lives behind `zig build -Dgpu=true test-gpu` at the
//! repo root, because it needs the PTX kernel pipeline.

const std = @import("std");
const compute = @import("compute");

test "probe never errors and always yields a usable backend" {
    var c = try compute.Compute.init(null);
    defer c.deinit();
    // Whatever was probed must at least synchronize cleanly.
    try c.synchronize();
}

test "explicit cpu backend is a no-op device" {
    var c = try compute.Compute.init(.cpu);
    defer c.deinit();
    try std.testing.expectEqual(compute.Backend.cpu, c.backend);
    try c.synchronize();
    try std.testing.expectError(error.AllocFailed, c.alloc(64));
    try std.testing.expectError(error.ModuleLoadFailed, c.loadModule("not a module"));
    try std.testing.expectError(error.InitFailed, c.createStream());
}

test "cuda buffer alloc/upload/download round-trip (skips without driver)" {
    var c = compute.Compute.init(.cuda) catch return error.SkipZigTest;
    defer c.deinit();

    var buf = try c.alloc(4 * 1024);
    defer buf.free();

    var host: [1024]f32 = undefined;
    for (&host, 0..) |*v, i| v.* = @floatFromInt(i);
    try buf.upload(&host, @sizeOf(@TypeOf(host)));

    var back: [1024]f32 = undefined;
    try buf.download(&back, @sizeOf(@TypeOf(back)));
    try std.testing.expectEqualSlices(f32, &host, &back);
}
