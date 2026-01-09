//! loader.zig — runtime HDL device loading. APP-ONLY: this is the one piece
//! that depends on FastVAF, so it is deliberately NOT in engine.zig. engine.zig
//! is the shared device core that BOTH the app (comptime builtins) and the
//! FastVAF-built `.so` (runtime dynamics) compile identically; the `.so` cannot
//! depend on FastVAF (that would be circular), so the loader lives here.
//!
//! Compiles a netlist HDL card (.va/.v/.sv) to a `.so` once (via FastVAF),
//! content-hash caches it, dlopen's it, and registers it by name. The app never
//! rebuilds; a foreign model is compiled on first use and cached thereafter.

const std = @import("std");
const fastvaf = @import("fastvaf");
const engine = @import("engine.zig");

const LoadedDevice = engine.LoadedDevice;
const DeviceVtable = engine.DeviceVtable;

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
var registry: std.StringHashMapUnmanaged(LoadedDevice) = .empty;

pub fn get(name: []const u8) ?*const DeviceVtable {
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) return null;
    reg_mutex.lock();
    defer reg_mutex.unlock();
    const dev = registry.get(std.ascii.lowerString(&buf, name)) orelse return null;
    return dev.vt;
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
    /// FastVAF-owned scratch: generated device.zig, compiler cache, artifacts.
    work_dir: []const u8,
    /// modules/devices/src/contract.zig — the generated device imports it.
    contract: []const u8,
    /// modules/devices/src/engine.zig — must expose `exportDevice`. The
    /// orchestrator hashes this into `layout_hash`, which is exactly the check
    /// `DeviceAbiMismatch` below relies on.
    dyn: []const u8,
};

const PreparedDevice = struct { loaded: LoadedDevice, owned_name: []const u8 };

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
    const zig_source = try result.generateDevice();

    var lower_buf: [128]u8 = undefined;
    if (result.mir.name.len > lower_buf.len) return error.NameTooLong;
    const lower_name = std.ascii.lowerString(&lower_buf, result.mir.name);

    reg_mutex.lock();
    const already = registry.contains(lower_name);
    reg_mutex.unlock();
    if (already) return null;

    // generation = generated-source hash XOR the host's dyn-ABI layout. Same
    // device + same ABI ⇒ same generation, so FastVAF's per-generation build
    // tree IS the compile cache: first load pays, later loads hit it.
    const generation: u32 = @truncate(std.hash.Fnv1a_64.hash(zig_source) ^ engine.layoutHash());

    std.debug.print("loader: compiling '{s}' ({s}) — first load, cached afterwards\n", .{ result.mir.name, path });
    // Order is load-bearing: the orchestrator hashes this list into
    // `layout_hash`, so it must match what the CLI's --emit-so passes.
    const modules = [_]fastvaf.orchestrator.Module{
        .{ .name = "contract", .root = paths.contract },
        .{ .name = "dyn", .root = paths.dyn, .deps = &.{"contract"} },
    };
    var built = try fastvaf.buildArtifact(gpa, io, &result, .{
        .work_dir = paths.work_dir,
        .name = result.mir.name,
        .optimize = .ReleaseFast,
        .backend = .llvm,
        .modules = &modules,
    }, generation, null);
    defer built.deinit(gpa);
    const art = switch (built) {
        .ok => |a| a,
        // The generated device failing to compile is an ENGINE bug, not a bad
        // model — the model already type-checked upstream to get here.
        .failed => return error.GeneratedDeviceDoesNotCompile,
    };
    // The .so bakes the engine's struct layouts in; a stale one is UB, not a bug
    // report. Reject before dlopen.
    if (art.layout_hash != engine.layoutHash()) return error.DeviceAbiMismatch;

    const loaded = try LoadedDevice.open(art.so_path);
    const owned_name = try gpa.dupe(u8, lower_name);
    return .{ .loaded = loaded, .owned_name = owned_name };
}

fn registerPrepared(gpa: std.mem.Allocator, r: PreparedDevice) !void {
    reg_mutex.lock();
    defer reg_mutex.unlock();
    if (!registry.contains(r.owned_name)) {
        try registry.put(gpa, r.owned_name, r.loaded);
    } else {
        gpa.free(r.owned_name);
    }
}

/// Compile (or fetch from cache) one `.va`/`.v`/`.sv` file and register its
/// device. Idempotent per model name.
pub fn ensureLoaded(gpa: std.mem.Allocator, io: std.Io, path: []const u8, paths: BuildPaths) !void {
    if (try prepareOne(gpa, io, path, paths)) |r| try registerPrepared(gpa, r);
}

/// Load multiple HDL files in parallel — codegen + zig-build run concurrently,
/// then results register sequentially into the process-lifetime registry.
pub fn ensureAllLoaded(gpa: std.mem.Allocator, io: std.Io, files: []const []const u8, paths: BuildPaths) !void {
    if (files.len <= 1) {
        for (files) |p| try ensureLoaded(gpa, io, p, paths);
        return;
    }
    const Result = ?PreparedDevice;
    const results = try gpa.alloc(Result, files.len);
    defer gpa.free(results);
    @memset(results, null);

    var group: std.Io.Group = .init;
    for (files, results) |path, *slot| {
        try group.concurrent(io, struct {
            fn run(inner_io: std.Io, ctx: struct { g: std.mem.Allocator, p: []const u8, s: *Result, bp: BuildPaths }) void {
                ctx.s.* = prepareOne(ctx.g, inner_io, ctx.p, ctx.bp) catch null;
            }
        }.run, .{ io, .{ .g = gpa, .p = path, .s = slot, .bp = paths } });
    }
    try group.await(io);

    for (results) |r| {
        if (r) |prepared| try registerPrepared(gpa, prepared);
    }
}
