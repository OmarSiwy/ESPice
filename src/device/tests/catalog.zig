//! Tests for the model catalog and HDL loader error propagation.
const std = @import("std");
const device = @import("../root.zig");

test "catalog reflects the generated model set" {
    try std.testing.expect(device.has("resistor"));
    try std.testing.expect(!device.has("does_not_exist"));
}

test "parallel model preparation propagates errors" {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    try std.testing.expectError(error.UnsupportedHdlExtension, device.loader.ensureAllLoaded(
        &lib,
        std.testing.io,
        &.{ "first.sv", "second.vhd" },
        .{ .work_dir = "", .contract = "", .dyn = "", .gompute = "", .device_abi = "", .core = "" },
    ));
}
