const std = @import("std");
const device = @import("../root.zig");

test "catalog reflects the generated model set" {
    try std.testing.expect(device.has("resistor"));
    try std.testing.expect(!device.has("does_not_exist"));
}

test "parallel model preparation propagates errors" {
    try std.testing.expectError(error.UnsupportedHdlExtension, device.loader.ensureAllLoaded(
        std.testing.allocator,
        std.testing.io,
        &.{ "first.v", "second.sv" },
        .{ .work_dir = "", .contract = "", .dyn = "", .gompute = "", .device_abi = "" },
    ));
}
