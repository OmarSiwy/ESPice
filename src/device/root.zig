//! The device module: the build-time model catalog, runtime HDL loading, the
//! per-Problem `Library` of device types, and the frozen `Circuit`. `abi` is
//! the neutral device ABI; eval.zig implements it for every device type.
/// The neutral device ABI (abi.zig), shared with every device object.
pub const abi = @import("device_abi");
/// The frozen circuit `Circuit.freeze` builds from the protos.
pub const Circuit = @import("Circuit.zig");
/// Runtime HDL compilation and dlopen; `Library.load` is its entry.
pub const loader = @import("loader.zig");
/// The per-Problem table of device types under dense ids.
pub const Library = @import("Library.zig");
/// A dense device-type id into a `Library`.
pub const DeviceType = abi.DeviceType;
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

test {
    _ = @import("tests/catalog.zig");
    _ = Circuit;
    _ = Library;
    _ = loader;
}
