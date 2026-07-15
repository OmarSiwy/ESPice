const std = @import("std");
const devices = @import("builder").spice;
const DeviceId = devices.DeviceId;
const letter_map = devices.letter_map;
const mosfetDeviceId = devices.mosfetDeviceId;
const bjtDeviceId = devices.bjtDeviceId;
const jfetDeviceId = devices.jfetDeviceId;
const mesDeviceId = devices.mesDeviceId;
const diodeDeviceId = devices.diodeDeviceId;

test "dispatch policy resolves letters and levels" {
    try std.testing.expectEqual(DeviceId.lossy_tline, letter_map.get("o").?);
    try std.testing.expectEqual(DeviceId.txl, letter_map.get("y").?);
    try std.testing.expectEqual(DeviceId.mos1, try mosfetDeviceId(1));
    try std.testing.expectEqual(DeviceId.bsim4va, try mosfetDeviceId(54));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(49));
    try std.testing.expectEqual(DeviceId.bsim3, try mosfetDeviceId(8));
    try std.testing.expectEqual(DeviceId.hicumL2_va, try bjtDeviceId(8));
    try std.testing.expectEqual(DeviceId.jfet2, try jfetDeviceId(2));
    try std.testing.expectEqual(DeviceId.mesa, try mesDeviceId(3));
    try std.testing.expectEqual(DeviceId.b3soifd, try mosfetDeviceId(55));
    try std.testing.expectEqual(DeviceId.b3soidd, try mosfetDeviceId(56));
    try std.testing.expectEqual(DeviceId.psp103, try mosfetDeviceId(1040));
    // Missing-from-catalog (b3soipd, level 57) and unknown levels are
    // unsupported netlists, not panics: the loader turns this into a clean skip.
    // Both warn; the warning is the expected output here, not test noise.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(57));
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(1041));
    // Every tag must resolve to a type: consumers switch `inline else` over
    // the whole enum, so a tag that fails to resolve breaks their build.
    inline for (@typeInfo(DeviceId).@"enum".field_names) |name| _ = DeviceId.Type(@field(DeviceId, name));
}

test "every level table maps each listed level and refuses its neighbours" {
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    try std.testing.expectEqual(DeviceId.diode, try diodeDeviceId(1));
    try std.testing.expectEqual(DeviceId.diode, try diodeDeviceId(3));
    try std.testing.expectError(error.UnsupportedDevice, diodeDeviceId(2));
    try std.testing.expectEqual(DeviceId.gummel_poon, try bjtDeviceId(1));
    try std.testing.expectEqual(DeviceId.gummel_poon, try bjtDeviceId(2));
    try std.testing.expectEqual(DeviceId.vbic13_4t, try bjtDeviceId(4));
    try std.testing.expectEqual(DeviceId.vbic13_4t, try bjtDeviceId(9));
    try std.testing.expectError(error.UnsupportedDevice, bjtDeviceId(3));
    try std.testing.expectEqual(DeviceId.jfet, try jfetDeviceId(1));
    try std.testing.expectError(error.UnsupportedDevice, jfetDeviceId(3));
    try std.testing.expectEqual(DeviceId.mes, try mesDeviceId(1));
    try std.testing.expectEqual(DeviceId.hfet1, try mesDeviceId(5));
    try std.testing.expectEqual(DeviceId.hfet2, try mesDeviceId(6));
    try std.testing.expectError(error.UnsupportedDevice, mesDeviceId(7));
    // LEVEL 0 is no level in any table (an absent LEVEL reads as 1).
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(0));
    try std.testing.expectError(error.UnsupportedDevice, mosfetDeviceId(std.math.maxInt(u16)));
}

test "the letter map knows only the SPICE letters with a device" {
    // m q j z resolve through their LEVEL tables, and u expands in the
    // builder; none of them is a letter_map key.
    for ("mqjzuax") |c| try std.testing.expect(letter_map.get(&.{c}) == null);
    try std.testing.expectEqual(DeviceId.diode, letter_map.get("d").?);
    try std.testing.expectEqual(DeviceId.cswitch, letter_map.get("w").?);
    // Keys are the lowercase letters the netlist hands over.
    try std.testing.expect(letter_map.get("R") == null);
}
