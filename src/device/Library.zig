//! Every device type one Problem can instantiate, built-in or runtime-loaded,
//! under one dense `DeviceType` id. Built-ins take ids [0, builtin_count) in
//! catalog order, so their ids are comptime-known (`builtin`); each loaded
//! HDL module appends one. Cites #13 for the embedder's toolchain paths; the
//! loading itself is loader.zig.
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
/// The VPI host (LRM 12.32/12.33) behind `--vpi` and `.options vpi=`, which
/// the espice executable supplies; null in a library build. Borrowed.
vpi: ?*const Vpi = null,
/// Whether `loadVpiApp` loaded at least one application.
vpi_loaded: bool = false,
/// The application each loaded type with `systf_calls` calls through, once
/// `load` attached it (`Vpi.attach`). A handful at most: VerA's VPI holds
/// one design (VerA#84).
systf_hosts: std.ArrayList(SystfBinding) = .empty,

pub const SystfBinding = struct { t: DeviceType, host: *const abi.SystfHost };

/// The VPI application host. The executable implements it over VerA's
/// `vpi` module, so the `vpi_*` symbols an application calls are exported
/// from the executable alone, never from a library that embeds ESPice.
/// Every call is serialized by the implementation.
pub const Vpi = struct {
    ctx: *anyopaque,
    /// Opens the application at `path` and runs its `vlog_startup_routines`
    /// (LRM 12.33.2). Loading one path twice is a no-op.
    load_app: *const fn (ctx: *anyopaque, path: []const u8) VpiError!void,
    /// The analog functions registered as vpiIntFunc (LRM 12.32.1), which
    /// compile as integers; borrowed until the next `load_app`.
    int_systfs: *const fn (ctx: *anyopaque) []const []const u8,
    /// Whether an application registered an analog system task or function
    /// named `name` (with its `$`).
    registered: *const fn (ctx: *anyopaque, name: []const u8) bool,
    /// Builds VerA's design of the module at `source_path` and binds `calls`
    /// (a loaded device's `systf_calls`) to it; returns what its instances
    /// call through, valid for the life of the process.
    attach: *const fn (ctx: *anyopaque, source_path: []const u8, calls: []const abi.Systf) VpiError!*const abi.SystfHost,
    /// LRM 12.31.3, driven by `.op` and `.tran` once a module is attached:
    /// `point` publishes the solution about to be attempted, `verdict` asks
    /// whether it stands (acbConvergenceTest, 12.36), `accept` delivers
    /// acbInitialStep/acbAbsTime/acbElapsedTime/acbAcceptedPoint/acbFinalStep
    /// for the solution last published, and `next_forced` is the earliest
    /// acbAbsTime/acbElapsedTime strictly after `after`, a time the transient
    /// lands on.
    point: *const fn (ctx: *anyopaque, p: AnalogPoint) void,
    verdict: *const fn (ctx: *anyopaque) Verdict,
    accept: *const fn (ctx: *anyopaque, first: bool, last: bool) void,
    next_forced: *const fn (ctx: *anyopaque, after: f64) ?f64,
};

/// The solution an analysis is attempting: LRM 12.18's bounds and 12.9's time.
pub const AnalogPoint = struct {
    kind: enum { op, tran },
    start: f64 = 0,
    stop: f64 = 0,
    max_step: f64 = 0,
    t: f64 = 0,
    dt: f64 = 0,
};

/// `reject`: an acbConvergenceTest returned non-zero or vpiRejectTransientStep
/// ran, so back up; `again`: vpiTransientFailConverge, so solve the same time
/// again.
pub const Verdict = enum { accept, reject, again };

/// Why a VPI step failed, each one logged with what it names:
/// `VpiApplicationUnloadable` (dlopen failed), `VpiNoStartupRoutines` (the
/// library exports no `vlog_startup_routines`), `VpiSecondSystfModule` (a
/// second module calls a `$systf`; VerA's VPI holds one design, VerA#84),
/// `VpiDesignFailed` (VerA could not build the module's design).
pub const VpiError = error{
    VpiApplicationUnloadable,
    VpiNoStartupRoutines,
    VpiSecondSystfModule,
    VpiDesignFailed,
    OutOfMemory,
};

/// Where `load` finds its compiler, sources and build cache, so a host that
/// ships ESPice in its own bundle can point at the files inside it (#13). A
/// null field keeps the default. The library reads no environment: the
/// facade fills `zig` and `cache_dir` from it when the embedder leaves them
/// null (`espice.zig` `toolchainFromEnv`).
pub const Toolchain = struct {
    /// The Zig compiler that builds a loaded device; null runs `zig` from
    /// PATH. It must be the version this espice was built with.
    zig: ?[]const u8 = null,
    /// The `share/espice` directory `zig build` installs, which holds
    /// `device/eval.zig`; null looks in `<exe>/../share/espice`, then falls
    /// back to the source tree this espice was built from.
    share: ?[]const u8 = null,
    /// The directory loaded devices' builds are cached in; null uses
    /// `/tmp/espice-cache/hdl`.
    cache_dir: ?[]const u8 = null,
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
    std.debug.assert(lib.names.items.len == builtin_count);
    std.debug.assert(lib.vtables.items.len == builtin_count);
    return lib;
}

/// Frees the loaded names and the tables. Loaded libraries stay mapped, so
/// vtables handed out stay valid.
pub fn deinit(self: *Library) void {
    std.debug.assert(self.names.items.len >= builtin_count);
    std.debug.assert(self.vtables.items.len == self.names.items.len);
    for (self.names.items[builtin_count..]) |name| self.gpa.free(name);
    for (self.sources.items) |path| self.gpa.free(path);
    self.sources.deinit(self.gpa);
    self.systf_hosts.deinit(self.gpa);
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
/// Asserts that `t` is registered (`.unset` never is).
pub fn vtable(self: *const Library, t: DeviceType) *const abi.DeviceVtable {
    std.debug.assert(t != .unset);
    std.debug.assert(@backingInt(t) < self.vtables.items.len);
    return self.vtables.items[@backingInt(t)];
}

/// A runtime-loaded type by module name, case-insensitively. Built-ins are not
/// searched: a netlist reaches them through SPICE letters and LEVELs.
// ponytail: linear scan; a deck loads a handful of HDL modules.
pub fn find(self: *const Library, module: []const u8) ?DeviceType {
    std.debug.assert(self.names.items.len >= builtin_count);
    for (self.names.items[builtin_count..], builtin_count..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, module)) {
            std.debug.assert(i < self.vtables.items.len);
            return @fromBackingInt(@intCast(i));
        }
    }
    return null;
}

/// Adds a device type under `module` (copied and lowercased) and returns its
/// id; `is_digital` marks a `.v` design (`digital`). A name already loaded
/// keeps its first vtable, flag and id. Fails with `TooManyDeviceTypes` when
/// the id space is full. On failure nothing is added.
pub fn register(self: *Library, module: []const u8, vt: *const abi.DeviceVtable, is_digital: bool) (error{TooManyDeviceTypes} || std.mem.Allocator.Error)!DeviceType {
    std.debug.assert(self.vtables.items.len == self.names.items.len);
    std.debug.assert(self.digital.items.len == self.names.items.len);
    if (self.find(module)) |t| return t;
    if (self.names.items.len >= @backingInt(DeviceType.unset)) return error.TooManyDeviceTypes;
    const owned = try std.ascii.allocLowerString(self.gpa, module);
    errdefer self.gpa.free(owned);
    try self.vtables.ensureUnusedCapacity(self.gpa, 1);
    try self.digital.ensureUnusedCapacity(self.gpa, 1);
    try self.names.append(self.gpa, owned);
    self.vtables.appendAssumeCapacity(vt);
    self.digital.appendAssumeCapacity(is_digital);
    std.debug.assert(self.vtables.items.len == self.names.items.len);
    std.debug.assert(self.names.items.len > builtin_count);
    return @fromBackingInt(@intCast(self.names.items.len - 1));
}

/// Why `load` failed: `RuntimeHdlUnsupported` on wasm, `HdlShareNotFound`
/// when `toolchain.share` holds no evaluator sources, `TooManyDeviceTypes`
/// when the id space is full, out of memory, a canceled task group, the
/// first file's `loader.Error` in `files` order, or a `VpiError` attaching a
/// module that calls a `$systf`. Files before the failing one stay
/// registered; none after it are.
pub const LoadError = error{ RuntimeHdlUnsupported, HdlShareNotFound, TooManyDeviceTypes } || std.mem.Allocator.Error || std.Io.Cancelable || loader.Error || VpiError;

/// Loads the VPI application at `path` (`--vpi`, `.options vpi=`) and runs
/// its startup routines. Call before `load`: a registration decides how a
/// module compiles (LRM 12.32.1). Fails with `VpiUnavailable` when this
/// build has no VPI host (`vpi` null: an embedding library), else with the
/// host's `VpiError`.
pub fn loadVpiApp(self: *Library, path: []const u8) (error{VpiUnavailable} || VpiError)!void {
    const v = self.vpi orelse {
        if (!@import("builtin").is_test) std.log.err("vpi: {s}: this build loads no VPI applications; run the espice executable", .{path});
        return error.VpiUnavailable;
    };
    try v.load_app(v.ctx, path);
    self.vpi_loaded = true;
}

/// The application type `t` calls its `$systf`s through; null when no
/// application is loaded, or `t` calls none.
pub fn systfHost(self: *const Library, t: DeviceType) ?*const abi.SystfHost {
    for (self.systf_hosts.items) |b| if (b.t == t) return b.host;
    return null;
}

/// Whether `call` is a system task (its value unused), when VerA says;
/// false (a used value) on a contract that does not mark tasks (VerA#83).
pub fn isSystfTask(call: abi.Systf) bool {
    return if (@hasField(abi.Systf, "task")) call.task else false;
}

/// What an instance whose every unregistered `$systf` call is a task calls
/// through: nothing reads a task's value, so 0 with zero partials, and its
/// arguments keep their values (`out` null). Never bound for a used value.
pub const no_vpi_app: abi.SystfHost = .{ .ctx = undefined, .call = noVpiApp };

fn noVpiApp(_: *anyopaque, _: usize, _: []const f64, partials: []f64) f64 {
    @memset(partials, 0);
    return 0;
}

/// Whether a loaded application registered `name` (LRM 12.32).
pub fn systfRegistered(self: *const Library, name: []const u8) bool {
    const v = self.vpi orelse return false;
    return self.vpi_loaded and v.registered(v.ctx, name);
}

/// Compiles, opens and registers each HDL source not loaded yet (loader.zig).
/// The generated devices build against `toolchain.share`, else the sources
/// `zig build` installs in `<exe>/../share/espice`, else the source tree this
/// espice was built from, with the compiler `toolchain.zig`, else `zig` on
/// PATH. Builds are cached under `toolchain.cache_dir`. Fails with
/// `error.HdlShareNotFound` when `toolchain.share` holds no
/// `device/eval.zig`, and with `error.RuntimeHdlUnsupported` on wasm, which
/// has no compiler to run and no dlopen; VerA and the loader compile out.
pub fn load(self: *Library, io: std.Io, files: []const []const u8) LoadError!void {
    if (comptime @import("builtin").cpu.arch.isWasm()) return error.RuntimeHdlUnsupported;
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zig = self.toolchain.zig orelse "zig";
    const work_dir = self.toolchain.cache_dir orelse "/tmp/espice-cache/hdl";
    const share = self.toolchain.share orelse
        try std.fs.path.join(a, &.{ std.process.executableDirPathAlloc(io, a) catch "", "..", "share", "espice" });
    const installed = if (std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ share, "device", "eval.zig" }), .{})) |_| true else |_| false;
    // An explicit share that does not hold the sources is the caller's
    // mistake; building against the source tree instead would hide it.
    if (self.toolchain.share != null and !installed) {
        if (!@import("builtin").is_test) std.log.warn("hdl: {s} holds no device/eval.zig; point the toolchain share path at the share/espice directory zig build installs", .{share});
        return error.HdlShareNotFound;
    }
    const int_systfs: []const []const u8 = if (self.vpi) |v| (if (self.vpi_loaded) v.int_systfs(v.ctx) else &.{}) else &.{};
    try self.loadWith(io, files, if (installed) .{
        .work_dir = work_dir,
        .contract = try std.fs.path.join(a, &.{ share, "vera", "tools", "contract.zig" }),
        .dyn = try std.fs.path.join(a, &.{ share, "device", "eval.zig" }),
        .gompute = try std.fs.path.join(a, &.{ share, "gompute", "root.zig" }),
        .device_abi = try std.fs.path.join(a, &.{ share, "device", "abi.zig" }),
        .core = try std.fs.path.join(a, &.{ share, "core", "root.zig" }),
        .zig = zig,
        .int_systfs = int_systfs,
    } else .{
        .work_dir = work_dir,
        .contract = build_options.contract_path,
        .dyn = build_options.dyn_path,
        .gompute = build_options.gompute_path,
        .device_abi = build_options.device_abi_path,
        .core = build_options.core_path,
        .zig = zig,
        .int_systfs = int_systfs,
    });
}

/// `load` against explicit build paths: compiles and opens every file not
/// loaded yet in parallel (`loader.prepareAll`), then registers the results
/// in `files` order. Fails as `load` does, wasm aside.
pub fn loadWith(self: *Library, io: std.Io, files: []const []const u8, paths: loader.BuildPaths) LoadError!void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    // A source named twice, here or in an earlier call, compiles once.
    const todo = try loader.pending(self.sources.items, arena_state.allocator(), files);
    std.debug.assert(todo.files.len == todo.resolved.len);
    const results = try self.gpa.alloc(loader.Result, todo.files.len);
    defer self.gpa.free(results);
    try loader.prepareAll(self.gpa, io, todo.files, self.names.items[builtin_count..], paths, results);
    try self.sources.ensureUnusedCapacity(self.gpa, todo.resolved.len);
    for (results, todo.resolved) |result, resolved| {
        if (try result) |prepared| {
            const t = try self.register(prepared.name(), prepared.vtable, prepared.digital);
            for (prepared.vtable.systf_calls) |c| if (isSystfTask(c) and !self.systfRegistered(c.name))
                std.log.warn("{s}: no VPI application registered (LRM 12.32); the call does nothing", .{c.name});
            // LRM 12.32: bind the module's `$systf` calls to the loaded
            // application. Without one, `NetBuilder` refuses or no-ops each
            // call by name.
            if (prepared.vtable.systf_calls.len != 0 and self.vpi_loaded) {
                const v = self.vpi.?;
                try self.systf_hosts.ensureUnusedCapacity(self.gpa, 1);
                self.systf_hosts.appendAssumeCapacity(.{ .t = t, .host = try v.attach(v.ctx, resolved, prepared.vtable.systf_calls) });
            }
        }
        self.sources.appendAssumeCapacity(try self.gpa.dupe(u8, resolved));
    }
    std.debug.assert(self.vtables.items.len == self.names.items.len);
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
    try std.testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, registerCase, .{});
}
