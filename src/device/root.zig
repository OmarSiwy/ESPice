//! Devices: the build-time catalog, runtime HDL loading, and the frozen
//! `Circuit` every analysis runs on. `abi` is the neutral construction and
//! evaluation ABI (device_abi); `eval.zig` implements it per device type.
const std = @import("std");
pub const abi = @import("device_abi");
pub const Circuit = @import("Circuit.zig");
pub const loader = @import("loader.zig");
pub const Library = @import("Library.zig");
pub const DeviceType = abi.DeviceType;
/// Every build-time device, keyed by its binding name. `models.NAME` is
/// the contract-shaped device type.
pub const models = @import("models");

pub const Entry = struct { name: []const u8, type: type };

/// The full device set, reflected from `models` — no hand list. Adding a
/// models/NAME.va makes `catalog` grow automatically.
pub const catalog: []const Entry = blk: {
    const decls = @typeInfo(models).@"struct".decls;
    var list: [decls.len]Entry = undefined;
    for (decls, 0..) |d, i| list[i] = .{ .name = d.name, .type = @field(models, d.name) };
    const frozen = list;
    break :blk &frozen;
};

/// Linked binding name for a generated or native model definition.
pub fn modelName(comptime D: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    inline for (catalog) |e| {
        if (e.type == D) return e.name;
    }
    return null;
}

/// The device's own object, reached through the runtime ABI it already
/// defines. build.zig compiles `device/eval.zig` once per model into
/// `arp_device_<stem>`; everything the host needs from a generated device —
/// `derive`, `collapse`, the `Proto`, and behind that `DeviceBatch(D).eval`
/// and `Hooks` — hangs off this one symbol, so the executable's own
/// compilation never instantiates a device body.
///
/// ponytail: no ABI/layout check across the boundary, unlike `loadDevice`'s
/// `arp_layout_hash` gate. These objects are built from this tree, by this
/// build graph, at the same target and optimize mode — the two sides cannot
/// disagree without the build itself being wrong. Upgrade path if that ever
/// stops being true is the same exported hash the `.so` path uses.
pub fn vtable(comptime name: []const u8) *const abi.DeviceVtable {
    const get = @extern(*const fn () callconv(.c) *const abi.DeviceVtable, .{
        .name = "arp_device_" ++ name,
    });
    return get();
}

/// Resolve a device type by model name (comptime — `catalog` carries `type`).
pub fn byName(comptime name: []const u8) type {
    if (!has(name)) @compileError("devices: no model named '" ++ name ++ "'");
    return @field(models, name);
}

/// True at comptime if a model of this name is registered.
pub fn has(comptime name: []const u8) bool {
    return @hasDecl(models, name);
}

test {
    _ = @import("tests/catalog.zig");
}
