//! Every device type one Problem can instantiate, built-in or runtime-loaded,
//! under one dense `DeviceType` id. Built-ins take ids [0, builtin_count) in
//! catalog order, so their ids are comptime-known (`builtin`); each loaded
//! HDL module appends one.
const std = @import("std");
const abi = @import("device_abi");
const catalog = @import("root.zig");
const loader = @import("loader.zig");
const build_options = @import("build_options");
const DeviceType = abi.DeviceType;
const Library = @This();

gpa: std.mem.Allocator,
/// Type names by id. Loaded names are owned and lowercased; built-in names
/// are static.
names: std.ArrayList([]const u8) = .empty,
/// Vtables by id, parallel to `names`.
vtables: std.ArrayList(*const abi.DeviceVtable) = .empty,
/// Whether each type runs a digital engine (a `.v` design), parallel to
/// `names`; it becomes `Batch.digital` at the freeze.
digital: std.ArrayList(bool) = .empty,

/// Catalog entries with an evaluator, in catalog order.
const builtins = blk: {
    var list: []const []const u8 = &.{};
    for (catalog.catalog) |e| {
        if (@hasDecl(e.type, "eval")) list = list ++ .{e.name};
    }
    break :blk list;
};
pub const builtin_count: u16 = builtins.len;

/// A library holding the built-ins, each resolved through its linked object.
pub fn init(gpa: std.mem.Allocator) !Library {
    var lib: Library = .{ .gpa = gpa };
    errdefer lib.names.deinit(gpa);
    errdefer lib.vtables.deinit(gpa);
    errdefer lib.digital.deinit(gpa);
    try lib.names.ensureTotalCapacity(gpa, builtin_count);
    try lib.vtables.ensureTotalCapacity(gpa, builtin_count);
    try lib.digital.appendNTimes(gpa, false, builtin_count);
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
    self.digital.deinit(self.gpa);
    self.* = undefined;
}

/// The id of built-in `name`; a compile error when there is none.
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
// ponytail: linear scan; a deck loads a handful of HDL modules.
pub fn find(self: *const Library, module: []const u8) ?DeviceType {
    for (self.names.items[builtin_count..], builtin_count..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, module)) return @enumFromInt(i);
    }
    return null;
}

/// Adds a device type under `module` (copied and lowercased) and returns its
/// id; `is_digital` marks a `.v` design (`digital`). A name already loaded
/// keeps its first vtable, flag and id. Fails with `TooManyDeviceTypes` when
/// the id space is full.
pub fn register(self: *Library, module: []const u8, vt: *const abi.DeviceVtable, is_digital: bool) !DeviceType {
    if (self.find(module)) |t| return t;
    if (self.names.items.len >= @intFromEnum(DeviceType.unset)) return error.TooManyDeviceTypes;
    const owned = try std.ascii.allocLowerString(self.gpa, module);
    errdefer self.gpa.free(owned);
    try self.vtables.ensureUnusedCapacity(self.gpa, 1);
    try self.digital.ensureUnusedCapacity(self.gpa, 1);
    try self.names.append(self.gpa, owned);
    self.vtables.appendAssumeCapacity(vt);
    self.digital.appendAssumeCapacity(is_digital);
    return @enumFromInt(self.names.items.len - 1);
}

/// Compiles, opens and registers each HDL source not loaded yet (loader.zig).
/// The generated devices build against the sources `zig build` installs in
/// `<exe>/../share/espice`, else against the source tree this espice was built
/// from, with the compiler in `$ZIG`, else `zig` on PATH. Builds are cached
/// under `cacheDir`.
pub fn load(self: *Library, io: std.Io, files: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zig = if (std.c.getenv("ZIG")) |z| std.mem.span(z) else "zig";
    const work_dir = try cacheDir(a);
    const exe_dir = std.process.executableDirPathAlloc(io, a) catch "";
    const share = try std.fs.path.join(a, &.{ exe_dir, "..", "share", "espice" });
    const installed = if (std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ share, "device", "eval.zig" }), .{})) |_| true else |_| false;
    // ponytail: exe-relative, so a host of libespice finds no share/ and
    // falls back to the build tree; pass the prefix through the C API if an
    // installed library ever needs runtime .hdl.
    try loader.ensureAllLoaded(self, io, files, if (installed) .{
        .work_dir = work_dir,
        .contract = try std.fs.path.join(a, &.{ share, "vera", "tools", "contract.zig" }),
        .dyn = try std.fs.path.join(a, &.{ share, "device", "eval.zig" }),
        .gompute = try std.fs.path.join(a, &.{ share, "gompute", "root.zig" }),
        .device_abi = try std.fs.path.join(a, &.{ share, "device", "abi.zig" }),
        .core = try std.fs.path.join(a, &.{ share, "core", "root.zig" }),
        .stdpp = try std.fs.path.join(a, &.{ share, "stdpp", "root.zig" }),
        .zig = zig,
    } else .{
        .work_dir = work_dir,
        .contract = build_options.contract_path,
        .dyn = build_options.dyn_path,
        .gompute = build_options.gompute_path,
        .device_abi = build_options.device_abi_path,
        .core = build_options.core_path,
        .stdpp = build_options.stdpp_path,
        .zig = zig,
    });
}

/// The runtime HDL build cache: `$ESPICE_CACHE/hdl`, else
/// `$XDG_CACHE_HOME/espice/hdl`, else `$HOME/.cache/espice/hdl`, else
/// `$TMPDIR/espice-cache/hdl` (default `/tmp`).
fn cacheDir(a: std.mem.Allocator) ![]const u8 {
    const env = struct {
        fn get(name: [*:0]const u8) ?[]const u8 {
            const v = std.mem.span(std.c.getenv(name) orelse return null);
            return if (v.len == 0) null else v;
        }
    }.get;
    if (env("ESPICE_CACHE")) |d| return std.fs.path.join(a, &.{ d, "hdl" });
    if (env("XDG_CACHE_HOME")) |d| return std.fs.path.join(a, &.{ d, "espice", "hdl" });
    if (env("HOME")) |d| return std.fs.path.join(a, &.{ d, ".cache", "espice", "hdl" });
    return std.fs.path.join(a, &.{ env("TMPDIR") orelse "/tmp", "espice-cache", "hdl" });
}
