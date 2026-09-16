//! Frontend model loading: compile HDL sources, bind their neutral device IR,
//! and retain loaded code for the process model registry. Runtime evaluation
//! is instantiated by the analysis-owned evaluator compiled into each binding.

const std = @import("std");
const fastvaf = @import("fastvaf");
const ir = @import("device_ir");

const DeviceVtable = ir.DeviceVtable;

/// Registry guard.
///
/// ponytail: a spinlock, not `std.Io.Mutex`. In Zig 0.16 `Mutex.lock` takes an
/// `Io` (it parks on `io.futexWait`), but `get`/`isEmpty` are called from
/// netlist parsing with no `Io` in hand, so adopting it would mean threading
/// `Io` through the public read API and every caller of it. Everything this
/// lock protects is a hash-map lookup or insert — the expensive part (codegen,
/// `zig build`, `dlopen`) runs OUTSIDE it in `prepareOne` — so the critical
/// section is nanoseconds and never worth a syscall to sleep on. Upgrade to
/// `std.Io.Mutex` if the registry ever guards real work.
const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(l: *SpinLock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(l: *SpinLock) void {
        l.held.store(false, .release);
    }
};

var reg_mutex: SpinLock = .{};
var registry: std.StringHashMapUnmanaged(*const DeviceVtable) = .empty;

pub fn get(name: []const u8) ?*const DeviceVtable {
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) return null;
    reg_mutex.lock();
    defer reg_mutex.unlock();
    return registry.get(std.ascii.lowerString(&buf, name));
}

pub fn isEmpty() bool {
    reg_mutex.lock();
    defer reg_mutex.unlock();
    return registry.count() == 0;
}

/// Where the loader may build, and the module roots the generated device needs.
///
/// Passed in rather than derived here: these are SOURCE-TREE paths, and the
/// devices package has no `build_options` (only the app does, via `src_root`).
/// The app is the only caller, and it is the only one that knows where it was
/// built from.
pub const BuildPaths = struct {
    /// Parent of isolated generated-source build trees and compiler caches.
    work_dir: []const u8,
    /// VerA device contract imported by the generated model.
    contract: []const u8,
    /// Analysis evaluator source root exposing `exportDevice`.
    dyn: []const u8,
    /// gompute's module root — engine.zig imports it (Sink shares the GPU
    /// math core), so the .so's `dyn` module needs it as a dependency.
    gompute: []const u8,
    /// Neutral device ABI used by both host and generated evaluator.
    device_ir: []const u8,
};

const PreparedDevice = struct { loaded: *const DeviceVtable, owned_name: []const u8 };

/// Codegen + compile + dlopen for one file. No registry access — safe to run
/// concurrently. Returns null if the device was already registered when checked.
fn prepareOne(gpa: std.mem.Allocator, io: std.Io, path: []const u8, paths: BuildPaths) !?PreparedDevice {
    // ponytail: .v/.sv used to come through here via the deleted
    // fastvaf.fromVerilog; that path belongs to modules/FastVF now and is not
    // wired yet. Rejected loudly rather than silently ignored.
    if (!std.mem.endsWith(u8, path, ".va")) return error.UnsupportedHdlExtension;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);

    // Same two FastVAF calls as tools/compile_va.zig — a netlist-loaded model and
    // a built-in model are byte-identical devices by construction.
    var result = try fastvaf.compileSource(gpa, source, .release_fast);
    defer result.deinit();

    var lower_buf: [128]u8 = undefined;
    if (result.mir.name.len > lower_buf.len) return error.NameTooLong;
    const lower_name = std.ascii.lowerString(&lower_buf, result.mir.name);

    reg_mutex.lock();
    const already = registry.contains(lower_name);
    reg_mutex.unlock();
    // Registered already ⇒ nothing below is wanted, INCLUDING generateDevice.
    // compileSource still has to run: the registry key is the module name and
    // only the MIR knows it. Deliberate diagnostic change: a second card for an
    // already-loaded model no longer reports codegen failures for it, because
    // the model it would emit is one we are throwing away.
    if (already) return null;
    const zig_source = try result.generateDevice();

    std.debug.print("loader: compiling '{s}' ({s}) — first load, cached afterwards\n", .{ result.mir.name, path });
    // Order is load-bearing: the orchestrator hashes this list into
    // `layout_hash`, so it must match what the CLI's --emit-so passes.
    const modules = [_]fastvaf.orchestrator.Module{
        .{ .name = "contract", .root = paths.contract },
        .{ .name = "gompute", .root = paths.gompute },
        .{ .name = "device_ir", .root = paths.device_ir, .deps = &.{"contract"} },
        .{ .name = "dyn", .root = paths.dyn, .deps = &.{ "contract", "gompute", "device_ir" } },
    };
    // MATCH THE HOST. The vtable crosses the dlopen boundary with zig
    // callconv and auto struct layout, neither guaranteed across
    // backend/mode — ir.layoutHash() hashes both, so a hardcoded
    // ReleaseFast+llvm .so under a self-hosted host failed
    // DeviceAbiMismatch on every `.hdl` card since the self-hosted switch.
    // The one-shot orchestrator only compiles via LLVM, so a self-hosted
    // (Debug) host cannot load HDL at all — say so instead of tripping the
    // orchestrator's assert. Release espice is LLVM and just works.
    if (@import("builtin").zig_backend != .stage2_llvm) return error.HdlNeedsLlvmHost;
    var options: fastvaf.orchestrator.Options = .{
        .work_dir = paths.work_dir,
        .name = result.mir.name,
        .optimize = @import("builtin").mode,
        .backend = .llvm,
        .modules = &modules,
    };
    // VerA's generation versions the LIBRARY, not device.zig or u/*.zig.
    // Its writer prunes that tree, so unrelated sources must never share it.
    // Keep a stable tree for Zig's compiler cache; include module roots, compiler
    // options and the host ABI so different hosts do not overwrite each other.
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
    // Independently opened file descriptions serialize same-source threads AND
    // processes. Keep the lock through dlopen; closing releases it on all paths.
    const lock = try dir.createFile(io, "build.lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);

    // publish() copies onto this path. Unlink first so it creates a fresh inode:
    // truncating an inode mapped by another loader can corrupt its live vtable.
    // POSIX keeps an unlinked mapping alive. Platforms forbidding this unlink
    // return that error; never fall back to overwriting the mapped file.
    const generation = 1;
    const target = @import("builtin").target;
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
        // The generated device failing to compile is an ENGINE bug, not a bad
        // model — the model already type-checked upstream to get here. Render
        // the compiler's own errors: a swallowed bundle turns a one-line type
        // error into archaeology.
        .failed => |bundle| {
            bundle.renderToStderr(io, .{}, .off) catch {};
            return error.GeneratedDeviceDoesNotCompile;
        },
    };
    // The real ABI gate lives in loadDevice: it reads the .so's own
    // exported `arp_layout_hash` (engine.layoutHash compiled INTO the .so)
    // and compares against ours. The old pre-dlopen check here compared
    // `art.layout_hash` — the ORCHESTRATOR's cache key (compiler version +
    // module list) — against the engine's TYPE-layout hash: two unrelated
    // formulas that can never agree, which is why every `.hdl` card died
    // with DeviceAbiMismatch.
    const loaded = try loadDevice(art.so_path);
    const owned_name = try gpa.dupe(u8, lower_name);
    return .{ .loaded = loaded, .owned_name = owned_name };
}

fn registerPrepared(gpa: std.mem.Allocator, r: PreparedDevice) !void {
    errdefer gpa.free(r.owned_name);
    reg_mutex.lock();
    defer reg_mutex.unlock();
    if (!registry.contains(r.owned_name)) {
        try registry.put(gpa, r.owned_name, r.loaded);
    } else {
        gpa.free(r.owned_name);
    }
}

/// Load multiple HDL files in parallel — codegen + zig-build run concurrently,
/// then results register sequentially into the process-lifetime registry.
pub fn ensureAllLoaded(gpa: std.mem.Allocator, io: std.Io, files: []const []const u8, paths: BuildPaths) !void {
    if (files.len <= 1) {
        for (files) |p| {
            if (try prepareOne(gpa, io, p, paths)) |r| try registerPrepared(gpa, r);
        }
        return;
    }
    const Result = anyerror!?PreparedDevice;
    const results = try gpa.alloc(Result, files.len);
    @memset(results, null);
    defer {
        for (results) |result| {
            if (result) |prepared| {
                if (prepared) |r| gpa.free(r.owned_name);
            } else |_| {}
        }
        gpa.free(results);
    }

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (files, results) |path, *slot| {
        group.async(io, struct {
            fn run(inner_io: std.Io, ctx: struct { g: std.mem.Allocator, p: []const u8, s: *Result, bp: BuildPaths }) void {
                ctx.s.* = prepareOne(ctx.g, inner_io, ctx.p, ctx.bp);
            }
        }.run, .{ io, .{ .g = gpa, .p = path, .s = slot, .bp = paths } });
    }
    try group.await(io);

    for (results) |*slot| {
        if (try slot.*) |prepared| {
            slot.* = null; // registerPrepared consumes the owned name on every path.
            try registerPrepared(gpa, prepared);
        }
    }
}

/// Open a process-lifetime library; its mapping owns the returned vtable.
pub fn loadDevice(path: []const u8) !*const DeviceVtable {
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
