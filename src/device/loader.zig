//! Runtime HDL loading: compile a Verilog-A (`.va`) or Verilog-1364 (`.v`)
//! source to a shared library built from the same evaluator (eval.zig) as the
//! built-in devices, dlopen it, and register its vtable in a `Library`. Loaded
//! libraries are never unloaded, so a vtable stays valid for the life of the
//! process.

const std = @import("std");
const builtin = @import("builtin");
const fastvaf = @import("fastvaf");
const digital = @import("vera_sim").digital;
const ir = @import("device_abi");

const DeviceVtable = ir.DeviceVtable;
const Library = @import("Library.zig");

/// Where the loader may build, and the module roots the generated device
/// compiles against. `Library.load` fills these from build options.
pub const BuildPaths = struct {
    /// Parent of the per-source build trees and compiler caches.
    work_dir: []const u8,
    /// VerA's device contract, `<VerA>/tools/contract.zig`. A `.v` device
    /// also imports VerA's `sim` tree, found beside it.
    contract: []const u8,
    /// The evaluator root, src/device/eval.zig.
    dyn: []const u8,
    /// gompute's module root; eval.zig imports it.
    gompute: []const u8,
    /// The device ABI, src/device/abi.zig.
    device_abi: []const u8,
    /// The core module, for the ids the ABI names.
    core: []const u8,
    /// stdpp's module root; core imports it.
    stdpp: []const u8,
    /// The Zig compiler that builds the device. It must be the version this
    /// espice was built with.
    zig: []const u8 = "zig",
};

/// A compiled and opened device, not yet registered.
const Prepared = struct {
    vtable: *const DeviceVtable,
    name_buf: [128]u8,
    name_len: u8,
    /// Compiled from a `.v` design (`Library.digital`).
    digital: bool,

    fn name(self: *const Prepared) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The source languages the loader compiles, by file extension. Anything
/// else, `.sv` included (VerA's E1104), is `UnsupportedHdlExtension`.
const Hdl = enum { va, v };
const hdl_extensions = std.StaticStringMap(Hdl).initComptime(.{ .{ ".va", .va }, .{ ".v", .v } });

/// Compiles and opens one source. Reads `lib` only, so several can run
/// concurrently. Returns null when the module is already registered. A `.v`
/// design VerA cannot make a device (E1103) prints its diagnostics and fails
/// with `DigitalFailed`.
fn prepareOne(lib: *const Library, gpa: std.mem.Allocator, io: std.Io, path: []const u8, paths: BuildPaths) !?Prepared {
    const hdl = hdl_extensions.get(std.fs.path.extension(path)) orelse return error.UnsupportedHdlExtension;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);
    // The cached build is found from the inputs alone (source and includes,
    // comments stripped), so a hit never runs VerA's frontend in this process.
    const key: ?[32]u8 = try inputKey(io, gpa, hdl, path, source, paths);
    if (key) |k| if (cachedLoad(lib, gpa, io, paths.work_dir, k, hdl == .v)) |hit| return hit;
    var bag: fastvaf.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The same FastVAF calls as tools/compile_va.zig, so a loaded model and a
    // built-in one are the same device.
    var va: ?fastvaf.CompileResult = null;
    defer if (va) |*r| r.deinit();
    var v: digital.DeviceZig = undefined;
    const module_name = switch (hdl) {
        .va => blk: {
            const dir = std.fs.path.dirname(path) orelse ".";
            va = fastvaf.compileSourceOpts(gpa, source, .build, .{ .file_name = path, .include_dirs = &.{dir}, .diags = &bag }) catch |err| {
                printDiags(&bag);
                return err;
            };
            break :blk va.?.mir.name;
        },
        .v => blk: {
            v = try emitDigital(arena, path, source);
            break :blk v.name;
        },
    };

    var out: Prepared = .{ .vtable = undefined, .name_buf = undefined, .name_len = undefined, .digital = hdl == .v };
    if (module_name.len > out.name_buf.len) return error.NameTooLong;
    out.name_len = @intCast(std.ascii.lowerString(&out.name_buf, module_name).len);
    // Only the compiled MIR knows a `.va` module's name, so `compileSource`
    // must run before this check; codegen and the build are skipped.
    if (lib.find(out.name()) != null) return null;
    const device: fastvaf.codegen.Output = switch (hdl) {
        .va => try va.?.generateOutput(),
        .v => .{ .text = v.zig },
    };
    // Warnings of a successful compile, and codegen's refusals (E0515).
    printDiags(&bag);
    if (va != null and va.?.device_has_compile_error) return error.HdlCodegenRefused;

    std.debug.print("loader: compiling '{s}' ({s}) — first load, cached afterwards\n", .{ module_name, path });
    // The orchestrator hashes this list into its cache key. `sim` and its
    // imports are VerA's build.zig `module_specs` rows, which a `.v` device
    // needs; a `.va` device never imports them, so they cost it nothing.
    const vera_root = std.fs.path.dirname(std.fs.path.dirname(paths.contract) orelse ".") orelse ".";
    const modules = [_]fastvaf.orchestrator.Module{
        .{ .name = "contract", .root = paths.contract },
        .{ .name = "gompute", .root = paths.gompute },
        .{ .name = "stdpp", .root = paths.stdpp },
        .{ .name = "core", .root = paths.core, .deps = &.{"stdpp"} },
        .{ .name = "device_abi", .root = paths.device_abi, .deps = &.{ "contract", "core" } },
        .{ .name = "dyn", .root = paths.dyn, .deps = &.{ "contract", "gompute", "device_abi" } },
        .{ .name = "sim", .root = try std.fs.path.join(arena, &.{ vera_root, "src/sim/root.zig" }), .deps = &.{ "contract", "diag", "frontend", "kernels" } },
        .{ .name = "diag", .root = try std.fs.path.join(arena, &.{ vera_root, "lib/diag.zig" }) },
        .{ .name = "frontend", .root = try std.fs.path.join(arena, &.{ vera_root, "lib/frontend/root.zig" }), .deps = &.{"diag"} },
        .{ .name = "kernels", .root = try std.fs.path.join(arena, &.{ vera_root, "lib/backend/kernels.zig" }) },
    };
    // The vtable crosses the dlopen boundary with Zig calling convention and
    // auto layout, so the library must match the host's backend and mode
    // (`layoutHash` checks both). The orchestrator builds only with LLVM, so a
    // self-hosted host cannot load HDL.
    if (builtin.zig_backend != .stage2_llvm) {
        std.debug.print("loader: this espice is a Debug build; runtime .hdl needs one built with -Doptimize=ReleaseFast (the default)\n", .{});
        return error.HdlNeedsLlvmHost;
    }
    var options: fastvaf.orchestrator.Options = .{
        .work_dir = paths.work_dir,
        .name = module_name,
        .optimize = builtin.mode,
        .backend = .llvm,
        .modules = &modules,
        .zig_exe = paths.zig,
    };
    // One build tree per (source, host ABI, module set): VerA's writer prunes
    // its tree, so unrelated sources must not share one, and a stable path
    // keeps Zig's compiler cache warm.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(device.text);
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
        target.libPrefix(), module_name, generation, target.dynamicLibSuffix(),
    });
    defer gpa.free(library);
    dir.deleteFile(io, library) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var built = fastvaf.orchestrator.compileRelease(gpa, io, options, device, generation) catch |err| {
        switch (err) {
            error.CompilerGone => std.debug.print("loader: the Zig compiler '{s}' did not start or exited mid-build; runtime .hdl needs zig {s} on PATH, or its path in $ZIG\n", .{ paths.zig, builtin.zig_version_string }),
            error.ProtocolMismatch => std.debug.print("loader: '{s}' is not zig {s}, the compiler this espice was built with; put that version on PATH or in $ZIG\n", .{ paths.zig, builtin.zig_version_string }),
            else => {},
        }
        return err;
    };
    defer built.deinit(gpa);
    const art = switch (built) {
        .ok => |a| a,
        // The model already type-checked (or VerA emitted the `.v` device), so
        // a compile failure here is an engine bug; show the compiler's own
        // errors.
        .failed => |bundle| {
            bundle.renderToStderr(io, .{}, .off) catch {};
            return error.GeneratedDeviceDoesNotCompile;
        },
    };
    out.vtable = try loadDevice(art.so_path);
    if (key) |k| recordInputs(io, paths.work_dir, k, module_name, &std.fmt.bytesToHex(digest, .lower));
    return out;
}

/// Longest include chain the key follows; VerA refuses deeper ones anyway.
const max_include_depth = 32;

/// The cache key of `path`: the code VerA reads for it, every
/// `` `include`` followed the way VerA resolves it, with comments stripped
/// so a comment-only edit keeps the cached build; plus the module roots it
/// builds against and this binary's size and mtime, which any rebuild (a VerA
/// re-pin included) changes. Null when an include cannot be resolved
/// statically (a macro-named one, or one in a `.v` design, which VerA gives
/// no include dirs): the full path then compiles and reports it.
fn inputKey(io: std.Io, gpa: std.mem.Allocator, hdl: Hdl, path: []const u8, source: []const u8, paths: BuildPaths) !?[32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(@tagName(hdl));
    const dir = std.fs.path.dirname(path) orelse ".";
    if (!try hashCode(io, gpa, &h, hdl, dir, source, 0)) return null;
    inline for (.{ "contract", "dyn", "gompute", "device_abi", "core", "stdpp", "zig" }) |f| {
        h.update(&.{0});
        h.update(@field(paths, f));
    }
    const host_layout = ir.layoutHash();
    h.update(std.mem.asBytes(&host_layout));
    h.update(std.mem.asBytes(&ir.abi_version));
    h.update(builtin.zig_version_string);
    h.update(@tagName(builtin.mode));
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    const st = try std.Io.Dir.cwd().statFile(io, exe, .{});
    h.update(std.mem.asBytes(&st.size));
    h.update(std.mem.asBytes(&st.mtime));
    return h.finalResult();
}

/// Hashes `text` without comments, then each file it `` `include``s, as
/// VerA's `readInclude` finds it: absolute as written, else under `dir` (the
/// loader's one include dir), else a built-in annex file by basename, which
/// the binary identity already covers. False on anything it cannot follow.
fn hashCode(io: std.Io, gpa: std.mem.Allocator, h: *std.crypto.hash.sha2.Sha256, hdl: Hdl, dir: []const u8, text: []const u8, depth: u8) !bool {
    if (depth > max_include_depth) return false;
    const code = try normalizeCode(gpa, text);
    defer gpa.free(code);
    h.update(code);
    h.update(&.{0});
    var rest: []const u8 = code;
    while (std.mem.indexOf(u8, rest, "`include")) |at| {
        if (hdl == .v) return false;
        rest = std.mem.trimStart(u8, rest[at + "`include".len ..], " \t");
        if (rest.len == 0 or rest[0] != '"') return false;
        const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return false;
        const name = rest[1..close];
        rest = rest[close + 1 ..];
        const full = if (std.fs.path.isAbsolute(name)) try gpa.dupe(u8, name) else try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(full);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(64 * 1024 * 1024)) catch {
            if (fastvaf_builtin_includes.has(std.fs.path.basename(name))) {
                h.update(name);
                h.update(&.{0});
                continue;
            }
            return false;
        };
        defer gpa.free(bytes);
        if (!try hashCode(io, gpa, h, hdl, dir, bytes, depth + 1)) return false;
    }
    return true;
}

/// VerA's built-in annex headers (`preprocessor.builtin_includes`).
const fastvaf_builtin_includes = std.StaticStringMap(void).initComptime(.{
    .{"constants.vams"}, .{"disciplines.vams"}, .{"driver_access.vams"},
});

/// `text` as the compiler sees it, minus what cannot change a build: every
/// `//` and `/* */` comment (LRM 2.4) goes, a block comment keeping its
/// newlines as VerA's preprocessor does; then each line has its runs of
/// spaces and tabs (outside strings) collapsed and its ends trimmed, and
/// blank lines are dropped. Newlines between code are kept, since one ends a
/// `` `define``. A source that reads `__LINE__` keeps every line. Caller frees.
fn normalizeCode(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var bare: std.ArrayList(u8) = try .initCapacity(gpa, text.len);
    defer bare.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
            i = @min(i + 1, text.len);
            bare.appendSliceAssumeCapacity(text[start..i]);
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            const end = @min((std.mem.indexOfPos(u8, text, i + 2, "*/") orelse text.len) + 2, text.len);
            bare.appendAssumeCapacity(' ');
            for (text[i..end]) |ch| if (ch == '\n') bare.appendAssumeCapacity('\n');
            i = end;
        } else {
            bare.appendAssumeCapacity(c);
            i += 1;
        }
    }
    const keep_lines = std.mem.indexOf(u8, bare.items, "__LINE__") != null;
    var out: std.ArrayList(u8) = try .initCapacity(gpa, bare.items.len);
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, bare.items, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 and !keep_lines) continue;
        var in_string = false;
        var gap = false;
        for (line, 0..) |ch, k| {
            if (ch == '"' and (k == 0 or line[k - 1] != '\\')) in_string = !in_string;
            if (!in_string and (ch == ' ' or ch == '\t' or ch == '\r')) {
                gap = true;
                continue;
            }
            if (gap) out.appendAssumeCapacity(' ');
            gap = false;
            out.appendAssumeCapacity(ch);
        }
        out.appendAssumeCapacity('\n');
    }
    return out.toOwnedSlice(gpa);
}

/// The device a previous run built for `key`, opened under its build lock;
/// `.{null}` when that module is already registered, null on any miss.
fn cachedLoad(lib: *const Library, gpa: std.mem.Allocator, io: std.Io, work_root: []const u8, key: [32]u8, digital_dev: bool) ??Prepared {
    var buf: [512]u8 = undefined;
    const index = std.fmt.bufPrint(&buf, "{s}/inputs/{s}", .{ work_root, &std.fmt.bytesToHex(key, .lower) }) catch return null;
    var text_buf: [256]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, index, &text_buf) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const module_name = lines.next() orelse return null;
    const digest = lines.next() orelse return null;
    if (module_name.len == 0 or digest.len != 64) return null;

    var out: Prepared = .{ .vtable = undefined, .name_buf = undefined, .name_len = undefined, .digital = digital_dev };
    if (module_name.len > out.name_buf.len) return null;
    out.name_len = @intCast(std.ascii.lowerString(&out.name_buf, module_name).len);
    if (lib.find(out.name()) != null) return @as(?Prepared, null);

    const work_dir = std.fs.path.join(gpa, &.{ work_root, digest }) catch return null;
    defer gpa.free(work_dir);
    const dir = std.Io.Dir.cwd().openDir(io, work_dir, .{}) catch return null;
    defer dir.close(io);
    const lock = dir.createFile(io, "build.lock", .{ .truncate = false, .lock = .exclusive }) catch return null;
    defer lock.close(io);
    const target = builtin.target;
    const so = std.fmt.allocPrint(gpa, "{s}/{s}{s}.1{s}", .{ work_dir, target.libPrefix(), module_name, target.dynamicLibSuffix() }) catch return null;
    defer gpa.free(so);
    out.vtable = loadDevice(so) catch return null;
    return out;
}

/// Writes `key`'s index (module name, build directory) after a full build.
/// Best effort: a failed write only costs the next run its fast path.
fn recordInputs(io: std.Io, work_root: []const u8, key: [32]u8, module_name: []const u8, digest_hex: []const u8) void {
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/inputs", .{work_root}) catch return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    var pbuf: [512]u8 = undefined;
    const index = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, &std.fmt.bytesToHex(key, .lower) }) catch return;
    var text: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&text, "{s}\n{s}\n", .{ module_name, digest_hex }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index, .data = body }) catch return;
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
        if (try result) |prepared| _ = try lib.register(prepared.name(), prepared.vtable, prepared.digital);
    }
}

/// VerA's `.v` contract device for `source`: 4-state, under the static
/// schedule (the CLI's default). Prints VerA's diagnostics, the W1155 1 s
/// tick warning included, and fails with `DigitalFailed` on its E1103
/// refusal.
fn emitDigital(arena: std.mem.Allocator, path: []const u8, source: []const u8) !digital.DeviceZig {
    var bag: fastvaf.diag.Bag = .init(arena);
    try bag.setSingleFile(path, source);
    const dev = digital.emitDevice(arena, source, .{ .file_name = path }, .static, &bag);
    printDiags(&bag);
    return dev;
}

/// Prints VerA's diagnostics (file:line, code, message) to stderr.
fn printDiags(bag: *fastvaf.diag.Bag) void {
    if (bag.isEmpty()) return;
    var buf: [1024]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    fastvaf.diag.render(bag, w, .{}) catch {};
    w.flush() catch {};
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

test "normalizeCode: comments and layout drop, code and line breaks stay" {
    const g = std.testing.allocator;
    const plain = try normalizeCode(g, "`define G 2.0\nmodule m;\n  x = \"a  // b\";\nendmodule\n");
    defer g.free(plain);
    const noisy = try normalizeCode(g, "// header\n`define G 2.0   // gain\n\n/* block\n   comment */\nmodule   m;\n\tx = \"a  // b\";\nendmodule");
    defer g.free(noisy);
    try std.testing.expectEqualStrings(plain, noisy);
    // A newline ends a `define: joining the lines must not hash the same.
    const joined = try normalizeCode(g, "`define G 2.0 module m;\n  x = \"a  // b\";\nendmodule\n");
    defer g.free(joined);
    try std.testing.expect(!std.mem.eql(u8, plain, joined));
}
