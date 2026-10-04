//! Tests for the model catalog and HDL loader error propagation.
const std = @import("std");
const device = @import("../root.zig");

test "catalog reflects the generated model set" {
    try std.testing.expect(device.has("resistor"));
    try std.testing.expect(!device.has("does_not_exist"));
}

test "modelName inverts byName" {
    try std.testing.expectEqualStrings("resistor", device.modelName(device.byName("resistor")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), device.modelName(u8));
}

const no_paths: device.loader.BuildPaths = .{ .work_dir = "", .contract = "", .dyn = "", .gompute = "", .device_abi = "", .core = "", .stdpp = "" };

test "loading no files registers nothing" {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    try device.loader.ensureAllLoaded(&lib, std.testing.io, &.{}, no_paths);
    try std.testing.expectEqual(@as(usize, device.Library.builtin_count), lib.names.items.len);
}

test "the first failing file in list order wins" {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    const missing = "/nonexistent-espice-test-dir/missing.va";
    try std.testing.expectError(error.FileNotFound, device.loader.ensureAllLoaded(&lib, std.testing.io, &.{ missing, "first.sv" }, no_paths));
    try std.testing.expectError(error.UnsupportedHdlExtension, device.loader.ensureAllLoaded(&lib, std.testing.io, &.{ "first.sv", missing }, no_paths));
    try std.testing.expectEqual(@as(usize, device.Library.builtin_count), lib.names.items.len);
}

test "parallel model preparation propagates errors" {
    var lib = try device.Library.init(std.testing.allocator);
    defer lib.deinit();
    try std.testing.expectError(error.UnsupportedHdlExtension, device.loader.ensureAllLoaded(
        &lib,
        std.testing.io,
        &.{ "first.sv", "second.vhd" },
        no_paths,
    ));
}
