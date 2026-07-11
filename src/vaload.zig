//! vaload — runtime Verilog-A/Verilog device loading policy: content-hash
//! cache, .so compilation (via fastvaf), dlopen, name registry.
//!
//! The app never rebuilds: a `.hdl` card compiles ONLY the model into a
//! shared object (once per source × compiler version, then cached) and the
//! netlist binds instances to it exactly like baked -Dva-models devices.
//! Mechanism split: dyn ABI in analysis.problem.dyn, build tree in
//! fastvaf.compileGenerated, cache/registry policy here.

const std = @import("std");
const analysis = @import("analysis");
const fastvaf = @import("fastvaf");
const build_options = @import("build_options");

const dyn = analysis.problem.dyn;

/// Process-lifetime registry: model name → loaded .so. Never closed — the
/// vtable and batch code must outlive every circuit; the OS reclaims at exit.
var registry: std.StringHashMapUnmanaged(dyn.LoadedDevice) = .empty;

pub fn get(name: []const u8) ?*const dyn.DeviceVtable {
    const dev = registry.get(name) orelse return null;
    return dev.vt;
}

pub fn isEmpty() bool {
    return registry.count() == 0;
}

/// Compile (or fetch from cache) one `.va`/`.v`/`.sv` file and register its
/// device. Idempotent per model name.
pub fn ensureLoaded(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);

    // Codegen first: cheap, and it yields the model name + the exact Zig
    // source the cache key must cover.
    var name_buf: []const u8 = &.{};
    defer gpa.free(name_buf);
    var zig_source: []const u8 = undefined;
    if (std.mem.endsWith(u8, path, ".va")) {
        var result = try fastvaf.compileSource(gpa, source, null);
        defer result.deinit();
        zig_source = try fastvaf.va.codegen.generate(gpa, &result.mir, &result.lower);
        name_buf = try gpa.dupe(u8, result.mir.name);
    } else if (std.mem.endsWith(u8, path, ".v") or std.mem.endsWith(u8, path, ".sv")) {
        zig_source = try fastvaf.fromVerilog(gpa, io, source);
        name_buf = try gpa.dupe(u8, fastvaf.moduleName(source) orelse std.fs.path.stem(path));
    } else return error.UnknownHdlExtension;
    defer gpa.free(zig_source);

    if (registry.contains(name_buf)) return;

    // Key: generated source ⊕ boundary layout (layoutHash covers the zig
    // version). Any change to either lands in a fresh cache slot.
    var key = std.hash.Fnv1a_64.hash(zig_source);
    key ^= dyn.layoutHash();

    const cache_root = cacheRoot(gpa) catch return error.NoCacheDir;
    defer gpa.free(cache_root);
    const work_dir = try std.fmt.allocPrint(gpa, "{s}/{s}-{x}", .{ cache_root, name_buf, key });
    defer gpa.free(work_dir);
    const so_path = try std.fmt.allocPrint(gpa, "{s}/zig-out/lib/lib{s}.so", .{ work_dir, name_buf });
    defer gpa.free(so_path); // unused after LoadedDevice.open — one free on every path

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
            // Debug/Release std layouts and backend Zig-ABI details differ —
            // the .so must match the app on both (layoutHash pins them).
            .optimize = @import("builtin").mode,
            .no_llvm = @import("builtin").zig_backend != .stage2_llvm,
        });
        lib.deinit();
    }

    const loaded = try dyn.LoadedDevice.open(so_path);

    // Key string owned by the registry (process lifetime).
    const owned_name = try gpa.dupe(u8, name_buf);
    errdefer gpa.free(owned_name);
    try registry.put(gpa, owned_name, loaded);
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
