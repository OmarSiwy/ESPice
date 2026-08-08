//! Every device type one Problem can instantiate, built-in or runtime-loaded,
//! under one dense `DeviceType` id. Built-ins take ids [0, builtin_count) in
//! catalog order, so their ids are comptime-known (`builtin`); each loaded
//! HDL module appends one.
const std = @import("std");
const abi = @import("device_abi");
const catalog = @import("catalog.zig");
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
/// Every HDL source `load` has handled, as resolved paths (owned), so one
/// named again, by another `.lib` section or a later `load`, does not
/// compile again.
sources: std.ArrayList([]const u8) = .empty,
/// Where `load` finds the Zig compiler and the evaluator sources. Borrowed;
/// it must outlive every `load`.
toolchain: Toolchain = .{},

/// Overrides for what `load` otherwise reads from the environment and the
/// executable's path, so a host that ships ESPice in its own bundle can point
/// at the files inside it (#13). A null field keeps the default.
pub const Toolchain = struct {
    /// The Zig compiler that builds a loaded device; null reads `$ZIG`, else
    /// runs `zig` from PATH. It must be the version this espice was built
    /// with.
    zig: ?[]const u8 = null,
    /// The `share/espice` directory `zig build` installs, which holds
    /// `device/eval.zig`; null looks in `<exe>/../share/espice`, then falls
    /// back to the source tree this espice was built from.
    share: ?[]const u8 = null,
};

/// Catalog entries with an evaluator, in catalog order.
const builtins = blk: {
    var list: []const []const u8 = &.{};
    for (catalog.catalog) |e| {
        if (@hasDecl(e.type, "eval")) list = list ++ .{e.name};
    }
    break :blk list;
};
/// Built-in types, which hold ids [0, builtin_count); loaded ones follow.
pub const builtin_count: u16 = builtins.len;

/// A library holding the built-ins, each resolved through its linked object.
/// Caller owns it and must `deinit` it.
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

/// Frees the loaded names and the tables. Loaded libraries stay mapped, so
/// vtables handed out stay valid.
pub fn deinit(self: *Library) void {
    for (self.names.items[builtin_count..]) |name| self.gpa.free(name);
    for (self.sources.items) |path| self.gpa.free(path);
    self.sources.deinit(self.gpa);
    self.names.deinit(self.gpa);
    self.vtables.deinit(self.gpa);
    self.digital.deinit(self.gpa);
    self.* = undefined;
}

/// The id of built-in `name`; a compile error when there is none.
pub fn builtin(comptime name: []const u8) DeviceType {
    inline for (builtins, 0..) |b, i| {
        if (comptime std.mem.eql(u8, b, name)) return @fromBackingInt(@intCast(i));
    }
    @compileError("device: no built-in model named '" ++ name ++ "'");
}

/// The vtable of type `t`, valid for the life of the process.
/// Asserts that `t` is registered.
pub fn vtable(self: *const Library, t: DeviceType) *const abi.DeviceVtable {
    return self.vtables.items[@backingInt(t)];
}

/// A runtime-loaded type by module name, case-insensitively. Built-ins are not
/// searched: a netlist reaches them through SPICE letters and LEVELs.
// ponytail: linear scan; a deck loads a handful of HDL modules.
pub fn find(self: *const Library, module: []const u8) ?DeviceType {
    for (self.names.items[builtin_count..], builtin_count..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, module)) return @fromBackingInt(@intCast(i));
    }
    return null;
}

/// Adds a device type under `module` (copied and lowercased) and returns its
/// id; `is_digital` marks a `.v` design (`digital`). A name already loaded
/// keeps its first vtable, flag and id. Fails with `TooManyDeviceTypes` when
/// the id space is full. On failure nothing is added.
pub fn register(self: *Library, module: []const u8, vt: *const abi.DeviceVtable, is_digital: bool) !DeviceType {
    if (self.find(module)) |t| return t;
    if (self.names.items.len >= @backingInt(DeviceType.unset)) return error.TooManyDeviceTypes;
    const owned = try std.ascii.allocLowerString(self.gpa, module);
    errdefer self.gpa.free(owned);
    try self.vtables.ensureUnusedCapacity(self.gpa, 1);
    try self.digital.ensureUnusedCapacity(self.gpa, 1);
    try self.names.append(self.gpa, owned);
    self.vtables.appendAssumeCapacity(vt);
    self.digital.appendAssumeCapacity(is_digital);
    return @fromBackingInt(@intCast(self.names.items.len - 1));
}

/// Compiles, opens and registers each HDL source not loaded yet (loader.zig).
/// The generated devices build against `toolchain.share`, else the sources
/// `zig build` installs in `<exe>/../share/espice`, else the source tree this
/// espice was built from, with the compiler `toolchain.zig`, else `$ZIG`, else
/// `zig` on PATH. Builds are cached under `cacheDir`. Fails with
/// `error.HdlShareNotFound` when `toolchain.share` holds no
/// `device/eval.zig`, and with `error.RuntimeHdlUnsupported` on wasm, which
/// has no compiler to run and no dlopen; VerA and the loader compile out.
pub fn load(self: *Library, io: std.Io, files: []const []const u8) !void {
    if (comptime @import("builtin").cpu.arch.isWasm()) return error.RuntimeHdlUnsupported;
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zig = self.toolchain.zig orelse if (std.c.getenv("ZIG")) |z| std.mem.span(z) else "zig";
    const work_dir = try cacheDir(a);
    const share = self.toolchain.share orelse
        try std.fs.path.join(a, &.{ std.process.executableDirPathAlloc(io, a) catch "", "..", "share", "espice" });
    const installed = if (std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ share, "device", "eval.zig" }), .{})) |_| true else |_| false;
    // An explicit share that does not hold the sources is the caller's
    // mistake; building against the source tree instead would hide it.
    if (self.toolchain.share != null and !installed) {
        if (!@import("builtin").is_test) std.log.warn("hdl: {s} holds no device/eval.zig; point the toolchain share path at the share/espice directory zig build installs", .{share});
        return error.HdlShareNotFound;
    }
    try self.loadWith(io, files, if (installed) .{
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

/// `load` against explicit build paths: compiles and opens every file not
/// loaded yet in parallel (`loader.prepareAll`), then registers the results
/// in `files` order. The first error wins; nothing is registered after it.
pub fn loadWith(self: *Library, io: std.Io, files: []const []const u8, paths: loader.BuildPaths) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    // A source named twice, here or in an earlier call, compiles once.
    const todo = try loader.pending(self.sources.items, arena_state.allocator(), files);
    const results = try self.gpa.alloc(loader.Result, todo.files.len);
    defer self.gpa.free(results);
    try loader.prepareAll(self.gpa, io, todo.files, self.names.items[builtin_count..], paths, results);
    try self.sources.ensureUnusedCapacity(self.gpa, todo.resolved.len);
    for (results, todo.resolved) |result, resolved| {
        if (try result) |prepared| _ = try self.register(prepared.name(), prepared.vtable, prepared.digital);
        self.sources.appendAssumeCapacity(try self.gpa.dupe(u8, resolved));
    }
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

test register {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    var vts: [2]abi.DeviceVtable = undefined;
    _ = &vts;
    const a = try lib.register("MyRes", &vts[0], false);
    try std.testing.expectEqual(builtin_count, @backingInt(a));
    try std.testing.expectEqualStrings("myres", lib.names.items[@backingInt(a)]);
    // A second spelling of a loaded name keeps the first registration.
    try std.testing.expectEqual(a, try lib.register("myRES", &vts[1], true));
    try std.testing.expect(lib.vtable(a) == &vts[0]);
    try std.testing.expect(!lib.digital.items[@backingInt(a)]);
    try std.testing.expectEqual(@as(?DeviceType, a), lib.find("MYRES"));
    const d = try lib.register("logic", &vts[1], true);
    try std.testing.expectEqual(builtin_count + 1, @backingInt(d));
    try std.testing.expect(lib.digital.items[@backingInt(d)]);
    try std.testing.expectEqual(lib.names.items.len, lib.vtables.items.len);
    try std.testing.expectEqual(lib.names.items.len, lib.digital.items.len);
}

test "an explicit share path must hold the evaluator sources" {
    if (comptime @import("builtin").cpu.arch.isWasm()) return error.SkipZigTest;
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    lib.toolchain = .{ .share = "/nonexistent-espice-test-dir/share/espice", .zig = "/nonexistent/zig" };
    try std.testing.expectError(error.HdlShareNotFound, lib.load(std.testing.io, &.{"m.va"}));
    try std.testing.expectEqual(@as(usize, builtin_count), lib.names.items.len);
}

test "find searches loaded types only" {
    var lib = try Library.init(std.testing.allocator);
    defer lib.deinit();
    try std.testing.expectEqualStrings("resistor", lib.names.items[@backingInt(builtin("resistor"))]);
    try std.testing.expectEqual(@as(?DeviceType, null), lib.find("resistor"));
    try std.testing.expectEqual(@as(?DeviceType, null), lib.find(""));
}

fn registerCase(gpa: std.mem.Allocator) !void {
    var lib = try Library.init(gpa);
    defer lib.deinit();
    var vt: abi.DeviceVtable = undefined;
    _ = &vt;
    _ = try lib.register("a", &vt, false);
    _ = try lib.register("b", &vt, true);
    try std.testing.expectEqual(lib.names.items.len, lib.digital.items.len);
}

test "init and register free everything when an allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registerCase, .{});
}
