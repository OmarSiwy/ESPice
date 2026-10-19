//! Tests for the model catalog and HDL loader error propagation.
const std = @import("std");
const catalog = @import("../catalog.zig");
const loader = @import("../loader.zig");
const Library = @import("../Library.zig");

test "catalog reflects the generated model set" {
    try std.testing.expect(catalog.has("resistor"));
    try std.testing.expect(!catalog.has("does_not_exist"));
}

test "modelName inverts byName" {
    try std.testing.expectEqualStrings("resistor", catalog.modelName(catalog.byName("resistor")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), catalog.modelName(u8));
}

const no_paths: loader.BuildPaths = .{ .work_dir = "", .contract = "", .dyn = "", .gompute = "", .device_abi = "", .core = "" };

test "loading no files registers nothing" {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    try lib.loadWith(std.testing.io, &.{}, no_paths);
    try std.testing.expectEqual(@as(usize, Library.builtin_count), lib.names.items.len);
}

test "the first failing file in list order wins" {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    const missing = "/nonexistent-espice-test-dir/missing.va";
    try std.testing.expectError(error.FileNotFound, lib.loadWith(std.testing.io, &.{ missing, "first.sv" }, no_paths));
    try std.testing.expectError(error.UnsupportedHdlExtension, lib.loadWith(std.testing.io, &.{ "first.sv", missing }, no_paths));
    try std.testing.expectEqual(@as(usize, Library.builtin_count), lib.names.items.len);
}

test "parallel model preparation propagates errors" {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    try std.testing.expectError(error.UnsupportedHdlExtension, lib.loadWith(
        std.testing.io,
        &.{ "first.sv", "second.vhd" },
        no_paths,
    ));
}
