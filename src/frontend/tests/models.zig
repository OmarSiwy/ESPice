const std = @import("std");
const devices = @import("builder").spice;
const DeviceId = devices.DeviceId;
const letter_map = devices.letter_map;
const mosfetDeviceId = devices.mosfetDeviceId;
const bjtDeviceId = devices.bjtDeviceId;
const jfetDeviceId = devices.jfetDeviceId;
const mesDeviceId = devices.mesDeviceId;

test "dispatch policy resolves letters and levels" {
    try std.testing.expectEqual(DeviceId.lossy_tline, letter_map.get("o").?);
    try std.testing.expectEqual(DeviceId.txl_native, letter_map.get("y").?);
    try std.testing.expectEqual(DeviceId.mos1, try mosfetDeviceId(1));
    try std.testing.expectEqual(DeviceId.bsim4va, try mosfetDeviceId(54));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(49));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(8));
    try std.testing.expectEqual(DeviceId.hicumL2_va, try bjtDeviceId(8));
    try std.testing.expectEqual(DeviceId.jfet2, try jfetDeviceId(2));
    try std.testing.expectEqual(DeviceId.mesa, try mesDeviceId(3));
    // Missing-from-catalog (b3soifd, level 55) and unknown levels are
    // unsupported netlists, not panics: the loader turns this into a clean skip.
    // Both warn; the warning is the expected output here, not test noise.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(55));
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(1040));
    // Every tag must resolve to a type — consumers switch `inline else` over
    // the whole enum, so a tag that fails to resolve breaks their build.
    inline for (@typeInfo(DeviceId).@"enum".fields) |f| _ = DeviceId.Type(@field(DeviceId, f.name));
}
