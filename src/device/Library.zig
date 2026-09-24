//! Every device type one Problem can instantiate, built-in and runtime-loaded,
//! behind one dense `DeviceType`. Built-ins take ids [0, builtin_count) in
//! catalog order, so a built-in's id is known at comptime (`builtin`); each
//! `load`ed HDL module appends one.
const std = @import("std");
const abi = @import("device_abi");
const catalog = @import("root.zig");
const loader = @import("loader.zig");
const build_options = @import("build_options");
const DeviceType = abi.DeviceType;
const Library = @This();

gpa: std.mem.Allocator,
/// SoA by id. Names of loaded types are owned (lowercased module names);
/// built-in names are static.
names: std.ArrayList([]const u8) = .empty,
vtables: std.ArrayList(*const abi.DeviceVtable) = .empty,

/// Built-in devices: catalog entries with an evaluator, in catalog order.
const builtins = blk: {
    var list: []const []const u8 = &.{};
    for (catalog.catalog) |e| {
        if (@hasDecl(e.type, "eval")) list = list ++ .{e.name};
    }
    break :blk list;
};
pub const builtin_count: u16 = builtins.len;

/// Registers the built-ins; `vtable` resolves each through its linked object.
pub fn init(gpa: std.mem.Allocator) !Library {
    var lib: Library = .{ .gpa = gpa };
    errdefer lib.names.deinit(gpa);
    errdefer lib.vtables.deinit(gpa);
    try lib.names.ensureTotalCapacity(gpa, builtin_count);
    try lib.vtables.ensureTotalCapacity(gpa, builtin_count);
    inline for (builtins) |name| {
        lib.names.appendAssumeCapacity(name);
        lib.vtables.appendAssumeCapacity(catalog.vtable(name));
    }
    return lib;
}

pub fn deinit(self: *Library) void {
    for (self.names.items[builtin_count..]) |name| self.gpa.free(name);
    self.names.deinit(self.gpa);
    self.vtables.deinit(self.gpa);
    self.* = undefined;
}

/// The id of built-in `name` (a catalog stem with an evaluator).
pub fn builtin(comptime name: []const u8) DeviceType {
    inline for (builtins, 0..) |b, i| {
        if (comptime std.mem.eql(u8, b, name)) return @enumFromInt(i);
    }
    @compileError("device: no built-in model named '" ++ name ++ "'");
}

pub fn vtable(self: *const Library, t: DeviceType) *const abi.DeviceVtable {
    return self.vtables.items[@intFromEnum(t)];
}

/// A runtime-loaded type by module name, case-insensitively. Built-ins are not
/// searched: a netlist reaches them through SPICE letters and LEVELs.
// ponytail: linear scan, a deck loads a handful of HDL modules.
pub fn find(self: *const Library, module: []const u8) ?DeviceType {
    for (self.names.items[builtin_count..], builtin_count..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, module)) return @enumFromInt(i);
    }
    return null;
}

/// Add a device type under `module` (copied, lowercased). A name already
/// loaded keeps its first vtable and id.
pub fn register(self: *Library, module: []const u8, vt: *const abi.DeviceVtable) !DeviceType {
    if (self.find(module)) |t| return t;
    if (self.names.items.len >= @intFromEnum(DeviceType.unset)) return error.TooManyDeviceTypes;
    const owned = try std.ascii.allocLowerString(self.gpa, module);
    errdefer self.gpa.free(owned);
    try self.vtables.ensureUnusedCapacity(self.gpa, 1);
    try self.names.append(self.gpa, owned);
    self.vtables.appendAssumeCapacity(vt);
    return @enumFromInt(self.names.items.len - 1);
}

/// Compile and dlopen each HDL source not yet loaded here (loader.zig), then
/// register its module. The generated device builds against this source tree.
pub fn load(self: *Library, io: std.Io, files: []const []const u8) !void {
    const work_dir = try std.fs.path.join(self.gpa, &.{ build_options.src_root, ".zig-cache", "espice-hdl" });
    defer self.gpa.free(work_dir);
    try loader.ensureAllLoaded(self, io, files, .{
        .work_dir = work_dir,
        .contract = build_options.contract_path,
        .dyn = build_options.dyn_path,
        .gompute = build_options.gompute_path,
        .device_abi = build_options.device_abi_path,
        .core = build_options.core_path,
    });
}
