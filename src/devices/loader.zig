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
    /// FastVAF-owned scratch: generated device.zig, compiler cache, artifacts.
    work_dir: []const u8,
    /// modules/devices/src/contract.zig — the generated device imports it.
    contract: []const u8,
    /// modules/devices/src/engine.zig — must expose `exportDevice`. The
    /// orchestrator hashes this into `layout_hash`, which is exactly the check
    /// `DeviceAbiMismatch` below relies on.
    dyn: []const u8,
    /// gompute's module root — engine.zig imports it (Sink shares the GPU
    /// math core), so the .so's `dyn` module needs it as a dependency.
    gompute: []const u8,
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

    // generation = generated-source hash XOR the host's dyn-ABI layout/version. Same
    // device + same ABI ⇒ same generation, so FastVAF's per-generation build
    // tree IS the compile cache: first load pays, later loads hit it.
    const generation: u32 = @truncate(std.hash.Fnv1a_64.hash(zig_source) ^ engine.layoutHash() ^ engine.abi_version);

    std.debug.print("loader: compiling '{s}' ({s}) — first load, cached afterwards\n", .{ result.mir.name, path });
    // Order is load-bearing: the orchestrator hashes this list into
    // `layout_hash`, so it must match what the CLI's --emit-so passes.
    const modules = [_]fastvaf.orchestrator.Module{
        .{ .name = "contract", .root = paths.contract },
        .{ .name = "gompute", .root = paths.gompute },
        .{ .name = "dyn", .root = paths.dyn, .deps = &.{ "contract", "gompute" } },
    };
    // MATCH THE HOST. The vtable crosses the dlopen boundary with zig
    // callconv and auto struct layout, neither guaranteed across
    // backend/mode — engine.layoutHash() hashes both, so a hardcoded
    // ReleaseFast+llvm .so under a self-hosted host failed
    // DeviceAbiMismatch on every `.hdl` card since the self-hosted switch.
    // The one-shot orchestrator only compiles via LLVM, so a self-hosted
    // (Debug) host cannot load HDL at all — say so instead of tripping the
    // orchestrator's assert. Release espice is LLVM and just works.
    if (@import("builtin").zig_backend != .stage2_llvm) return error.HdlNeedsLlvmHost;
    var built = try fastvaf.buildArtifact(gpa, io, &result, .{
        .work_dir = paths.work_dir,
        .name = result.mir.name,
        .optimize = @import("builtin").mode,
        .backend = .llvm,
        .modules = &modules,
    }, generation, null);
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
    // The real ABI gate lives in engine.loadDevice: it reads the .so's own
    // exported `arp_layout_hash` (engine.layoutHash compiled INTO the .so)
    // and compares against ours. The old pre-dlopen check here compared
    // `art.layout_hash` — the ORCHESTRATOR's cache key (compiler version +
    // module list) — against the engine's TYPE-layout hash: two unrelated
    // formulas that can never agree, which is why every `.hdl` card died
    // with DeviceAbiMismatch.
    const loaded = try engine.loadDevice(art.so_path);
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

/// Load multiple HDL files in parallel — codegen + zig-build run concurrently,
/// then results register sequentially into the process-lifetime registry.
pub fn ensureAllLoaded(gpa: std.mem.Allocator, io: std.Io, files: []const []const u8, paths: BuildPaths) !void {
    if (files.len <= 1) {
        for (files) |p| {
            if (try prepareOne(gpa, io, p, paths)) |r| try registerPrepared(gpa, r);
        }
        return;
    }
    const Result = ?PreparedDevice;
    const results = try gpa.alloc(Result, files.len);
    defer gpa.free(results);

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
