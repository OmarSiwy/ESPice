//! Runtime HDL loading: compile a Verilog-A source to a shared library built
//! from the same evaluator (eval.zig) as the built-in devices, dlopen it, and
//! register its vtable in a `Library`. Loaded libraries are never unloaded, so
//! a vtable stays valid for the life of the process.

const std = @import("std");
const builtin = @import("builtin");
const fastvaf = @import("fastvaf");
const ir = @import("device_abi");

const DeviceVtable = ir.DeviceVtable;
const Library = @import("Library.zig");

/// Where the loader may build, and the module roots the generated device
/// compiles against. `Library.load` fills these from build options.
pub const BuildPaths = struct {
    /// Parent of the per-source build trees and compiler caches.
    work_dir: []const u8,
    /// VerA's device contract.
    contract: []const u8,
    /// The evaluator root, src/device/eval.zig.
    dyn: []const u8,
    /// gompute's module root; eval.zig imports it.
    gompute: []const u8,
    /// The device ABI, src/device/abi.zig.
    device_abi: []const u8,
    /// The core module, for the ids the ABI names.
    core: []const u8,
};

/// A compiled and opened device, not yet registered.
const Prepared = struct {
    vtable: *const DeviceVtable,
    name_buf: [128]u8,
    name_len: u8,

    fn name(self: *const Prepared) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Compiles and opens one source. Reads `lib` only, so several can run
/// concurrently. Returns null when the module is already registered.
fn prepareOne(lib: *const Library, gpa: std.mem.Allocator, io: std.Io, path: []const u8, paths: BuildPaths) !?Prepared {
    // ponytail: Verilog (.v/.sv) models are not wired; reject them loudly.
    if (!std.mem.endsWith(u8, path, ".va")) return error.UnsupportedHdlExtension;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);

    // The same FastVAF calls as tools/compile_va.zig, so a loaded model and a
    // built-in one are the same device.
    var result = try fastvaf.compileSource(gpa, source, .release_fast);
    defer result.deinit();

    var out: Prepared = .{ .vtable = undefined, .name_buf = undefined, .name_len = undefined };
    if (result.mir.name.len > out.name_buf.len) return error.NameTooLong;
    out.name_len = @intCast(std.ascii.lowerString(&out.name_buf, result.mir.name).len);
    // Only the compiled MIR knows the module name, so `compileSource` must run
    // before this check; codegen and the build are skipped.
    if (lib.find(out.name()) != null) return null;
    const zig_source = try result.generateDevice();

    std.debug.print("loader: compiling '{s}' ({s}) — first load, cached afterwards\n", .{ result.mir.name, path });
    // The orchestrator hashes this list into its cache key, so the order must
    // match the CLI's --emit-so.
    const modules = [_]fastvaf.orchestrator.Module{
        .{ .name = "contract", .root = paths.contract },
        .{ .name = "gompute", .root = paths.gompute },
        .{ .name = "core", .root = paths.core },
        .{ .name = "device_abi", .root = paths.device_abi, .deps = &.{ "contract", "core" } },
        .{ .name = "dyn", .root = paths.dyn, .deps = &.{ "contract", "gompute", "device_abi" } },
    };
    // The vtable crosses the dlopen boundary with Zig calling convention and
    // auto layout, so the library must match the host's backend and mode
    // (`layoutHash` checks both). The orchestrator builds only with LLVM, so a
    // self-hosted host cannot load HDL.
    if (builtin.zig_backend != .stage2_llvm) return error.HdlNeedsLlvmHost;
    var options: fastvaf.orchestrator.Options = .{
        .work_dir = paths.work_dir,
        .name = result.mir.name,
        .optimize = builtin.mode,
        .backend = .llvm,
        .modules = &modules,
    };
    // One build tree per (source, host ABI, module set): VerA's writer prunes
    // its tree, so unrelated sources must not share one, and a stable path
    // keeps Zig's compiler cache warm.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(zig_source);
    const host_layout = ir.layoutHash();
    const module_layout = fastvaf.orchestrator.layoutHash(options);
    hash.update(std.mem.asBytes(&host_layout));
    hash.update(std.mem.asBytes(&ir.abi_version));
    hash.update(std.mem.asBytes(&module_layout));
    const digest = hash.finalResult();
    const work_dir = try std.fs.path.join(gpa, &.{ paths.work_dir, &std.fmt.bytesToHex(digest, .lower) });
    defer gpa.free(work_dir);
    options.work_dir = work_dir;
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    const dir = try std.Io.Dir.cwd().openDir(io, work_dir, .{});
    defer dir.close(io);
    // Serializes builds of the same source across threads and processes; held
    // through dlopen and released on close.
    const lock = try dir.createFile(io, "build.lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);

    // Unlink before the build copies onto this path, so it gets a fresh
    // inode: truncating a library another loader has mapped would corrupt its
    // live vtable. Platforms that refuse the unlink fail here rather than
    // overwrite a mapped file.
    const generation = 1;
    const target = builtin.target;
    const library = try std.fmt.allocPrint(gpa, "{s}{s}.{d}{s}", .{
        target.libPrefix(), result.mir.name, generation, target.dynamicLibSuffix(),
    });
    defer gpa.free(library);
    dir.deleteFile(io, library) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var built = try fastvaf.buildArtifact(gpa, io, &result, options, generation, null);
    defer built.deinit(gpa);
    const art = switch (built) {
        .ok => |a| a,
        // The model already type-checked, so a compile failure here is an
        // engine bug; show the compiler's own errors.
        .failed => |bundle| {
            bundle.renderToStderr(io, .{}, .off) catch {};
            return error.GeneratedDeviceDoesNotCompile;
        },
    };
    out.vtable = try loadDevice(art.so_path);
    return out;
}

/// Compiles and loads every source not yet in `lib`, in parallel, then
/// registers the results in `files` order. The first error wins; nothing is
/// registered after it.
pub fn ensureAllLoaded(lib: *Library, io: std.Io, files: []const []const u8, paths: BuildPaths) !void {
    const gpa = lib.gpa;
    const Result = anyerror!?Prepared;
    const results = try gpa.alloc(Result, files.len);
    defer gpa.free(results);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (files, results) |path, *slot| {
        group.async(io, struct {
            fn run(inner_io: std.Io, ctx: struct { l: *const Library, g: std.mem.Allocator, p: []const u8, s: *Result, bp: BuildPaths }) void {
                ctx.s.* = prepareOne(ctx.l, ctx.g, inner_io, ctx.p, ctx.bp);
            }
        }.run, .{ io, .{ .l = lib, .g = gpa, .p = path, .s = slot, .bp = paths } });
    }
    try group.await(io);

    for (results) |result| {
        if (try result) |prepared| _ = try lib.register(prepared.name(), prepared.vtable);
    }
}

/// Opens a device library for the life of the process and returns its
/// vtable, which the mapping owns. Fails with `NotArpDevice` when a required
/// symbol is missing, and `WrongAbiVersion`/`LayoutMismatch` when the library
/// was built against a different ABI.
fn loadDevice(path: []const u8) !*const DeviceVtable {
    var lib = try std.DynLib.open(path);
    errdefer lib.close();

    const u32_fn = *const fn () callconv(.c) u32;
    const u64_fn = *const fn () callconv(.c) u64;
    const ver = lib.lookup(u32_fn, "arp_abi_version") orelse return error.NotArpDevice;
    if (ver() != ir.abi_version) return error.WrongAbiVersion;
    const lh = lib.lookup(u64_fn, "arp_layout_hash") orelse return error.NotArpDevice;
    if (lh() != ir.layoutHash()) return error.LayoutMismatch;

    const get_vt = lib.lookup(*const fn () callconv(.c) *const DeviceVtable, "arp_device") orelse
        return error.NotArpDevice;
    return get_vt();
}
