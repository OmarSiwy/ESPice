//! Ids every layer shares that no other core leaf owns: the dense device
//! type id and the ground row. A leaf so `query.zig` and `deck.zig` need not
//! import `root.zig` (AGENTS.md §2.8).
const std = @import("std");

/// Dense id of a device type in a `device.Library`: built-ins first, in
/// catalog order, then runtime-loaded ones. A device never knows its own id;
/// the host stamps it where one is needed (`ParamRef.type`, `CardRef.type`).
pub const DeviceType = enum(u16) { unset = std.math.maxInt(u16), _ };

/// Row 0 of every circuit: the reference node.
pub const GROUND: u32 = 0;
