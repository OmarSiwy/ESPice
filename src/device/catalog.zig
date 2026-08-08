//! The build-time model catalog: every decl of the generated `models`
//! module, reflected at comptime into (binding name, device type) rows, and
//! each built-in's vtable from its separately compiled object. A leaf, so
//! `Library.zig` reads it without importing `root.zig` (AGENTS.md §2.8).
const abi = @import("device_abi");

/// Every build-time device type, one decl per binding name.
pub const models = @import("models");

/// One catalog row: a model's binding name and its generated device type.
pub const Entry = struct { name: []const u8, type: type };

/// Every decl of `models`, reflected at comptime; a new models/NAME.va
/// appears here without a hand-kept list.
pub const catalog: []const Entry = blk: {
    const decls = @typeInfo(models).@"struct".decl_names;
    var list: [decls.len]Entry = undefined;
    for (decls, 0..) |d, i| list[i] = .{ .name = d, .type = @field(models, d) };
    const frozen = list;
    break :blk &frozen;
};

/// The binding name of device type D, or null when D is not in the catalog.
pub fn modelName(comptime D: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    inline for (catalog) |e| {
        if (e.type == D) return e.name;
    }
    return null;
}

/// The vtable of built-in model `name`, from the `arp_device_<name>` symbol
/// its separately compiled object exports. Everything the host needs from a
/// generated device is reached through it, so the executable never
/// instantiates a device body itself.
// ponytail: no layout-hash check here, unlike loader.zig's `.so` path. These
// objects come from this build graph at the same target and mode; add the
// exported hash check if that ever stops being true.
pub fn vtable(comptime name: []const u8) *const abi.DeviceVtable {
    const get = @extern(*const fn () callconv(.c) *const abi.DeviceVtable, .{
        .name = "arp_device_" ++ name,
    });
    return get();
}

/// The device type registered as `name`; a compile error when there is none.
pub fn byName(comptime name: []const u8) type {
    if (!has(name)) @compileError("devices: no model named '" ++ name ++ "'");
    return @field(models, name);
}

/// Whether a model named `name` is registered.
pub fn has(comptime name: []const u8) bool {
    return @hasDecl(models, name);
}
