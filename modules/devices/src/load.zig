//! vaload — runtime Verilog-A/Verilog device loading policy: content-hash
//! cache, .so compilation (via fastvaf), dlopen, name registry.
//!
//! The app never rebuilds: a `.hdl` card compiles ONLY the model into a
//! shared object (once per source × compiler version, then cached) and the
//! netlist binds instances to it like any builtin device.
//! Mechanism split: dyn ABI in dyn.zig, build tree in
//! fastvaf.compileGenerated, cache/registry policy here.

const std = @import("std");
const dyn = @import("dyn.zig");
const fastvaf = @import("fastvaf");
const build_options = @import("build_options");

var reg_mutex: std.atomic.Mutex = .unlocked;
var registry: std.StringHashMapUnmanaged(dyn.LoadedDevice) = .empty;

fn lockMutex() void {
    while (!reg_mutex.tryLock()) std.Thread.yield() catch {};
}
fn unlockMutex() void {
    unlockMutex();
}

pub fn get(name: []const u8) ?*const dyn.DeviceVtable {
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) return null;
    lockMutex();
    defer unlockMutex();
    const dev = registry.get(std.ascii.lowerString(&buf, name)) orelse return null;
    return dev.vt;
}

pub fn isEmpty() bool {
    lockMutex();
    defer unlockMutex();
    return registry.count() == 0;
}

/// Codegen + compile + dlopen for one file. No registry access — safe to
/// run concurrently. Returns the loaded device + its lowercased name, or
/// null if the device was already registered when we checked.
const PreparedDevice = struct { loaded: dyn.LoadedDevice, owned_name: []const u8 };

fn prepareOne(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?PreparedDevice {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);

    var name_buf: []const u8 = &.{};
    defer gpa.free(name_buf);
    var zig_source: []const u8 = undefined;
    if (std.mem.endsWith(u8, path, ".va")) {
        const va_dir = std.fs.path.dirname(path) orelse ".";
        var result = try fastvaf.compileSourceOpts(gpa, source, null, .{
            .io = io,
            .include_dirs = &.{va_dir},
        });
        defer result.deinit();
        zig_source = try fastvaf.va.codegen.generate(gpa, &result.mir, &result.lower);
        name_buf = try gpa.dupe(u8, result.mir.name);
    } else if (std.mem.endsWith(u8, path, ".v") or std.mem.endsWith(u8, path, ".sv")) {
        zig_source = try fastvaf.fromVerilog(gpa, io, source);
        name_buf = try gpa.dupe(u8, fastvaf.moduleName(source) orelse std.fs.path.stem(path));
    } else return error.UnknownHdlExtension;
    defer gpa.free(zig_source);

    var lower_buf: [128]u8 = undefined;
    if (name_buf.len > lower_buf.len) return error.NameTooLong;
    const lower_name = std.ascii.lowerString(&lower_buf, name_buf);

    lockMutex();
    const already = registry.contains(lower_name);
    unlockMutex();
    if (already) return null;

    var key = std.hash.Fnv1a_64.hash(zig_source);
    key ^= dyn.layoutHash();

    const cache_root = cacheRoot(gpa) catch return error.NoCacheDir;
    defer gpa.free(cache_root);
    const work_dir = try std.fmt.allocPrint(gpa, "{s}/{s}-{x}", .{ cache_root, name_buf, key });
    defer gpa.free(work_dir);
    const so_path = try std.fmt.allocPrint(gpa, "{s}/zig-out/lib/lib{s}.so", .{ work_dir, name_buf });
    defer gpa.free(so_path);

    const cached = if (std.Io.Dir.cwd().access(io, so_path, .{})) |_| true else |_| false;
    if (!cached) {
        const src_root = getenv("ARPICE_SRC") orelse build_options.src_root;
        const sub = struct {
            fn join(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
                return std.fs.path.join(a, &.{ root, rel });
            }
        }.join;
        const contract_root = try sub(gpa, src_root, "modules/devices/src/contract.zig");
        defer gpa.free(contract_root);
        const analysis_root = try sub(gpa, src_root, "modules/analysis/src/root.zig");
        defer gpa.free(analysis_root);
        const solvers_root = try sub(gpa, src_root, "modules/solvers/src/root.zig");
        defer gpa.free(solvers_root);

        std.debug.print("vaload: compiling '{s}' ({s}) — first load, cached afterwards\n", .{ name_buf, path });
        var lib = try fastvaf.compileGenerated(gpa, name_buf, zig_source, .{
            .io = io,
            .output_dir = work_dir,
            .contract_root = contract_root,
            .analysis_root = analysis_root,
            .solvers_root = solvers_root,
            .optimize = @import("builtin").mode,
            .no_llvm = @import("builtin").zig_backend != .stage2_llvm,
        });
        lib.deinit();
    }

    const loaded = try dyn.LoadedDevice.open(so_path);
    const owned_name = try gpa.dupe(u8, lower_name);
    return .{ .loaded = loaded, .owned_name = owned_name };
}

fn registerPrepared(gpa: std.mem.Allocator, r: PreparedDevice) !void {
    lockMutex();
    defer unlockMutex();
    if (!registry.contains(r.owned_name)) {
        try registry.put(gpa, r.owned_name, r.loaded);
    } else {
        gpa.free(r.owned_name);
    }
}

/// Compile (or fetch from cache) one `.va`/`.v`/`.sv` file and register its
/// device. Idempotent per model name.
pub fn ensureLoaded(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    if (try prepareOne(gpa, io, path)) |r| try registerPrepared(gpa, r);
}

/// Load multiple HDL files in parallel — codegen + zig-build run concurrently,
/// then results are registered sequentially into the process-lifetime registry.
pub fn ensureAllLoaded(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8) !void {
    if (paths.len <= 1) {
        for (paths) |p| try ensureLoaded(gpa, io, p);
        return;
    }
    const Result = ?PreparedDevice;
    const results = try gpa.alloc(Result, paths.len);
    defer gpa.free(results);
    @memset(results, null);

    var group: std.Io.Group = .init;
    for (paths, results) |path, *slot| {
        try group.concurrent(io, struct {
            fn run(inner_io: std.Io, ctx: struct { g: std.mem.Allocator, p: []const u8, s: *Result }) void {
                ctx.s.* = prepareOne(ctx.g, inner_io, ctx.p) catch null;
            }
        }.run, .{ io, .{ .g = gpa, .p = path, .s = slot } });
    }
    try group.await(io);

    for (results) |r| {
        if (r) |prepared| try registerPrepared(gpa, prepared);
    }
}

/// $XDG_CACHE_HOME/arpice/va, else ~/.cache/arpice/va. Created on demand.
fn cacheRoot(gpa: std.mem.Allocator) ![]const u8 {
    const dir = if (getenv("XDG_CACHE_HOME")) |x|
        try std.fs.path.join(gpa, &.{ x, "arpice", "va" })
    else if (getenv("HOME")) |h|
        try std.fs.path.join(gpa, &.{ h, ".cache", "arpice", "va" })
    else
        return error.NoCacheDir;
    return dir;
}

fn getenv(name: [:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name) orelse return null);
}
