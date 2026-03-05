const std = @import("std");
const devices = @import("device_models");
const vaload = devices.vaload;
const has = devices.has;
const DeviceId = devices.DeviceId;
const letter_map = devices.letter_map;
const mosfetDeviceId = devices.mosfetDeviceId;
const bjtDeviceId = devices.bjtDeviceId;
const jfetDeviceId = devices.jfetDeviceId;
const mesDeviceId = devices.mesDeviceId;

test "catalog reflects the generated model set" {
    _ = vaload;
    // Compiles only inside the devices module (models import present).
    try std.testing.expect(has("resistor"));
    try std.testing.expect(!has("does_not_exist"));
}

test "dispatch policy resolves letters and levels" {
    try std.testing.expectEqual(DeviceId.lossy_tline, letter_map.get("o").?);
    try std.testing.expectEqual(DeviceId.lossy_tline, letter_map.get("y").?);
    try std.testing.expectEqual(DeviceId.mos1, try mosfetDeviceId(1));
    try std.testing.expectEqual(DeviceId.bsim4va, try mosfetDeviceId(54));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(49));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(8));
    try std.testing.expectEqual(DeviceId.hicumL2_va, try bjtDeviceId(8));
    try std.testing.expectEqual(DeviceId.jfet2, try jfetDeviceId(2));
    try std.testing.expectEqual(DeviceId.mesa, try mesDeviceId(3));
    // Missing-from-catalog (b3soifd, level 55) and unknown levels are
    // unsupported netlists, not panics: the loader turns this into a clean skip.
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(55));
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(1040));
    // Every tag must resolve to a type — consumers switch `inline else` over
    // the whole enum, so a tag that fails to resolve breaks their build.
    inline for (@typeInfo(DeviceId).@"enum".fields) |f| _ = DeviceId.Type(@field(DeviceId, f.name));
}

test "parallel model preparation propagates errors" {
    try std.testing.expectError(error.UnsupportedHdlExtension, vaload.ensureAllLoaded(
        std.testing.allocator,
        std.testing.io,
        &.{ "first.v", "second.sv" },
        .{ .work_dir = "", .contract = "", .dyn = "", .gompute = "", .device_ir = "" },
    ));
}
