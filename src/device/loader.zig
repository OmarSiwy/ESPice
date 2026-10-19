//! Runtime HDL loading: compile a Verilog-A (`.va`) or Verilog-1364 (`.v`)
//! source to a shared library built from the same evaluator (eval.zig) as the
//! built-in devices, dlopen it, and return its vtable for `Library.load` to
//! register. Loaded libraries are never unloaded, so a vtable stays valid for
//! the life of the process. The loader never sees the `Library`: it reads the
//! names already loaded and returns values.
//! Cites VerA's diagnostics it forwards (E1103, E1104, E0515), LRM 2.4 for the
//! comments the cache key strips, and #102 for display tasks in a loaded model.

const std = @import("std");
const builtin = @import("builtin");
const fastvaf = @import("fastvaf");
const digital = @import("vera_digital");
/// `digital.emitDevice`'s result. VerA keeps the type itself private.
const DeviceZig = @typeInfo(@typeInfo(@TypeOf(digital.emitDevice)).@"fn".return_type.?).error_union.payload;
const ir = @import("device_abi");

const DeviceVtable = ir.DeviceVtable;

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
    /// The Zig compiler that builds the device. It must be the version this
    /// espice was built with.
    zig: []const u8 = "zig",
    /// The loaded VPI applications' vpiIntFunc analog functions (LRM
    /// 12.32.1): a call to one compiles as an integer, so they are part of
    /// the cache key too.
    int_systfs: []const []const u8 = &.{},
};

/// A compiled and opened device, not yet registered.
pub const Prepared = struct {
    vtable: *const DeviceVtable,
    name_buf: [128]u8,
    name_len: u8,
    /// Compiled from a `.v` design (`Library.digital`).
    digital: bool,

    /// The module name, lowercased.
    pub fn name(self: *const Prepared) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The source languages the loader compiles, by file extension, ignoring
/// case: every Verilog-A and Verilog extension the frontend routes here
/// (`source.foreignKindForPath`). Anything else, `.sv` included (VerA's
/// E1104), is `UnsupportedHdlExtension`.
const Hdl = enum { va, v };
const hdl_extensions = std.StaticStringMapWithEql(Hdl, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ ".va", .va }, .{ ".vams", .va }, .{ ".veriloga", .va }, .{ ".v", .v },
});

/// Compiles and opens one source. Reads `loaded` only, so several can run
/// concurrently. Returns null when the module is already in `loaded`. A `.v`
/// design VerA cannot make a device (E1103) prints its diagnostics and fails
/// with `DigitalFailed`.
fn prepareOne(loaded: []const []const u8, gpa: std.mem.Allocator, io: std.Io, path: []const u8, paths: BuildPaths) Error!?Prepared {
    const hdl = hdl_extensions.get(std.fs.path.extension(path)) orelse return error.UnsupportedHdlExtension;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);
    // The cached build is found from the inputs alone (source and includes,
    // comments stripped), so a hit never runs VerA's frontend in this process.
    const key: ?[32]u8 = try inputKey(io, gpa, hdl, path, source, paths);
    if (key) |k| if (cachedLoad(loaded, gpa, io, paths.work_dir, k, hdl == .v)) |hit| return hit;
    var bag: fastvaf.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The same FastVAF calls as tools/compile_va.zig, so a loaded model and a
    // built-in one are the same device, except that a loaded one keeps its
    // §9.4 display tasks as `say` (`Hooks.say`, #102).
    var va: ?fastvaf.CompileResult = null;
    defer if (va) |*r| r.deinit();
    var v: DeviceZig = undefined;
    const module_name = switch (hdl) {
        .va => blk: {
            const dir = std.fs.path.dirname(path) orelse ".";
            va = fastvaf.compileSourceOpts(gpa, source, .build, .{
                // VAMS-2.3, as the built-ins compile (build.zig `.std`): 2023
                // reserves names models still declare (BSIM-CMG 112's `expm1`).
                .file_name = path,
                .include_dirs = &.{dir},
                .diags = &bag,
                .display = .record,
                .int_systfs = paths.int_systfs,
                .language = .vams_2_3,
            }) catch |err| {
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
    std.debug.assert(out.name_len == module_name.len);
    // Only the compiled MIR knows a `.va` module's name, so `compileSource`
    // must run before this check; codegen and the build are skipped.
    if (isLoaded(loaded, out.name())) return null;
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
        .{ .name = "core", .root = paths.core },
        .{ .name = "device_abi", .root = paths.device_abi, .deps = &.{ "contract", "core" } },
        .{ .name = "dyn", .root = paths.dyn, .deps = &.{ "contract", "gompute", "device_abi" } },
        .{ .name = "sim", .root = try std.fs.path.join(arena, &.{ vera_root, "src/sim/root.zig" }), .deps = &.{ "contract", "base", "diag", "frontend", "kernels" } },
        .{ .name = "base", .root = try std.fs.path.join(arena, &.{ vera_root, "lib/base/root.zig" }) },
        .{ .name = "diag", .root = try std.fs.path.join(arena, &.{ vera_root, "lib/diag.zig" }) },
        .{ .name = "frontend", .root = try std.fs.path.join(arena, &.{ vera_root, "lib/frontend/root.zig" }), .deps = &.{ "base", "diag", "kernels" } },
        .{ .name = "kernels", .root = try std.fs.path.join(arena, &.{ vera_root, "lib/kernels/root.zig" }), .deps = &.{"contract"} },
    };
    // The vtable crosses the dlopen boundary with Zig calling convention and
    // auto layout, so the library must match the host's backend and mode
    // (`layoutHash` checks both).
    var options: fastvaf.orchestrator.Options = .{
        .work_dir = paths.work_dir,
        .name = module_name,
        .optimize = builtin.mode,
        .backend = if (builtin.zig_backend == .stage2_llvm) .llvm else .self_hosted,
        .modules = &modules,
        .zig_exe = paths.zig,
        // The host's libc, not what the compiler detects: a Nix sandbox
        // detects musl, whose libc.so a glibc espice cannot load.
        .target = "native-native-" ++ @tagName(builtin.target.abi),
    };
    // One build tree per (source, host ABI, module set): VerA's writer prunes
    // its tree, so unrelated sources must not share one, and a stable path
    // keeps Zig's compiler cache warm.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(device.text);
    const host_layout = ir.layoutHash();
    hash.update(std.mem.asBytes(&host_layout));
    hash.update(std.mem.asBytes(&ir.abi_version));
    // The module set; mode and backend are the host's, in `host_layout`.
    for (modules) |m| {
        hash.update(m.name);
        hash.update(&.{0});
        hash.update(m.root);
        hash.update(&.{0});
    }
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
    const library = try gpa.print("{s}{s}.{d}{s}", .{
        target.libPrefix(), module_name, generation, target.dynamicLibSuffix(),
    });
    defer gpa.free(library);
    dir.deleteFile(io, library) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err, // else: any other unlink failure aborts the build (see above)
    };
    var built = fastvaf.orchestrator.compileRelease(gpa, io, options, device, generation) catch |err| {
        switch (err) {
            error.CompilerGone => std.debug.print("loader: the Zig compiler '{s}' did not start or exited mid-build; runtime .hdl needs zig {s} on PATH, or its path in $ZIG\n", .{ paths.zig, builtin.zig_version_string }),
            error.ProtocolMismatch => std.debug.print("loader: '{s}' is not zig {s}, the compiler this espice was built with; put that version on PATH or in $ZIG\n", .{ paths.zig, builtin.zig_version_string }),
            else => {}, // else: the remaining errors name themselves; the caller reports them
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
    std.debug.assert(out.vtable.n_u >= out.vtable.num_ports);
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
    h.update(&.{0}); // 'va' ++ 'ssign' is not 'v' ++ 'assign'
    const dir = std.fs.path.dirname(path) orelse ".";
    if (!try hashCode(io, gpa, &h, hdl, dir, path, source, 0)) return null;
    inline for (.{ "contract", "dyn", "gompute", "device_abi", "core", "zig" }) |f| {
        h.update(&.{0});
        h.update(@field(paths, f));
    }
    for (paths.int_systfs) |name| {
        h.update(&.{1});
        h.update(name);
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
/// the binary identity already covers. Text that reads `` `__FILE__`` also
/// hashes `file`, its own path, which the macro expands to. False on anything
/// it cannot follow.
fn hashCode(io: std.Io, gpa: std.mem.Allocator, h: *std.crypto.hash.sha2.Sha256, hdl: Hdl, dir: []const u8, file: []const u8, text: []const u8, depth: u8) !bool {
    // Each level recurses only from depth <= max, so one past it is the deepest call.
    std.debug.assert(depth <= max_include_depth + 1);
    if (depth > max_include_depth) return false;
    const code = try normalizeCode(gpa, text);
    defer gpa.free(code);
    h.update(code);
    h.update(&.{0});
    if (std.mem.indexOf(u8, code, "__FILE__") != null) {
        h.update(file);
        h.update(&.{0});
    }
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
        if (!try hashCode(io, gpa, h, hdl, dir, full, bytes, depth + 1)) return false;
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
/// `` `define``, and so is a blank line after a `\` continuation, which ends
/// one too. A source that reads `__LINE__` keeps every line. Caller frees.
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
    // A comment shrinks to one space plus its newlines, never more.
    std.debug.assert(bare.items.len <= text.len);
    const keep_lines = std.mem.indexOf(u8, bare.items, "__LINE__") != null;
    // Every line gets a '\n', the last one too when `bare` has none.
    var out: std.ArrayList(u8) = try .initCapacity(gpa, bare.items.len + 1);
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, bare.items, '\n');
    var continued = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 and !keep_lines and !continued) continue;
        continued = line.len > 0 and line[line.len - 1] == '\\';
        // Escapes as in the first pass: `"\\"` closes, `"\""` does not.
        var in_string = false;
        var escape = false;
        var gap = false;
        for (line) |ch| {
            if (in_string) {
                if (escape) {
                    escape = false;
                } else if (ch == '\\') {
                    escape = true;
                } else if (ch == '"') {
                    in_string = false;
                }
            } else if (ch == '"') {
                in_string = true;
            } else if (ch == ' ' or ch == '\t' or ch == '\r') {
                gap = true;
                continue;
            }
            if (gap) out.appendAssumeCapacity(' ');
            gap = false;
            out.appendAssumeCapacity(ch);
        }
        out.appendAssumeCapacity('\n');
    }
    std.debug.assert(out.items.len <= bare.items.len + 1);
    return out.toOwnedSlice(gpa);
}

/// The device a previous run built for `key`, opened under its build lock;
/// `.{null}` when that module is already in `loaded`, null on any miss.
fn cachedLoad(loaded: []const []const u8, gpa: std.mem.Allocator, io: std.Io, work_root: []const u8, key: [32]u8, digital_dev: bool) ??Prepared {
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
    std.debug.assert(out.name_len == module_name.len);
    if (isLoaded(loaded, out.name())) return @as(?Prepared, null);

    const work_dir = std.fs.path.join(gpa, &.{ work_root, digest }) catch return null;
    defer gpa.free(work_dir);
    const dir = std.Io.Dir.cwd().openDir(io, work_dir, .{}) catch return null;
    defer dir.close(io);
    const lock = dir.createFile(io, "build.lock", .{ .truncate = false, .lock = .exclusive }) catch return null;
    defer lock.close(io);
    const target = builtin.target;
    const so = gpa.print("{s}/{s}{s}.1{s}", .{ work_dir, target.libPrefix(), module_name, target.dynamicLibSuffix() }) catch return null;
    defer gpa.free(so);
    out.vtable = loadDevice(so) catch return null;
    return out;
}

/// Writes `key`'s index (module name, build directory) after a full build.
/// Best effort: a failed write only costs the next run its fast path.
fn recordInputs(io: std.Io, work_root: []const u8, key: [32]u8, module_name: []const u8, digest_hex: []const u8) void {
    // The pair of `cachedLoad`'s checks on reading the index back.
    std.debug.assert(module_name.len > 0);
    std.debug.assert(digest_hex.len == 64);
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/inputs", .{work_root}) catch return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    var pbuf: [512]u8 = undefined;
    const index = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, &std.fmt.bytesToHex(key, .lower) }) catch return;
    var text: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&text, "{s}\n{s}\n", .{ module_name, digest_hex }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = index, .data = body }) catch return;
}

/// Why one source did not load. The loader's own refusals:
///
/// - `UnsupportedHdlExtension`: the file is not `.va`, `.vams`, `.veriloga`
///   or `.v`, in any case.
/// - `NameTooLong`: the module name is over 128 bytes.
/// - `DigitalFailed`: VerA cannot make a device of the `.v` design (E1103);
///   its diagnostics are printed.
/// - `HdlCodegenRefused`: VerA's codegen refused the model (E0515); printed.
/// - `GeneratedDeviceDoesNotCompile`: the generated device failed to build,
///   an engine bug; the compiler's errors are printed.
/// - `NotArpDevice`, `WrongAbiVersion`, `LayoutMismatch`: the built library
///   lacks an `arp_*` symbol or was built against another device ABI.
///
/// The rest are forwarded unchanged from the steps that fail them: reading
/// the source and its includes, statting this executable for the cache key,
/// VerA's compile and codegen (`fastvaf.Error`, `digital.Error`), the build
/// directory and its lock, VerA's orchestrator build (`CompilerGone` and
/// `ProtocolMismatch` print what to fix), and `dlopen`. On any error nothing
/// is registered; a build tree may be left in the cache, and the next load
/// rebuilds it.
pub const Error = error{
    UnsupportedHdlExtension,
    NameTooLong,
    HdlCodegenRefused,
    GeneratedDeviceDoesNotCompile,
    NotArpDevice,
    WrongAbiVersion,
    LayoutMismatch,
} || std.Io.Dir.ReadFileAllocError ||
    std.process.ExecutablePathAllocError ||
    std.Io.Dir.StatFileError ||
    fastvaf.Error ||
    @import("vera_sim").digital.Error ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.DeleteFileError ||
    OrchestratorError ||
    std.DynLib.Error;

/// VerA's `orchestrator.compileRelease` infers its error set; this names it.
const OrchestratorError = @typeInfo(@typeInfo(@TypeOf(fastvaf.orchestrator.compileRelease)).@"fn".return_type.?).error_union.error_set;

/// What `prepareAll` leaves per file: the opened device, null when its module
/// was already loaded, or the error that stopped it.
pub const Result = Error!?Prepared;

/// Compiles and opens every file in `files` in parallel into `results`
/// (parallel to `files`), skipping modules named in `loaded` (lowercased, as
/// `Library.names` holds them). Registers nothing: the caller walks `results`
/// in order. Fails only when the task group is canceled. Asserts that
/// `results` has one entry per file.
pub fn prepareAll(gpa: std.mem.Allocator, io: std.Io, files: []const []const u8, loaded: []const []const u8, paths: BuildPaths, results: []Result) std.Io.Cancelable!void {
    std.debug.assert(results.len == files.len);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (files, results) |path, *slot| {
        group.async(io, struct {
            fn run(inner_io: std.Io, ctx: struct { l: []const []const u8, g: std.mem.Allocator, p: []const u8, s: *Result, bp: BuildPaths }) void {
                ctx.s.* = prepareOne(ctx.l, ctx.g, inner_io, ctx.p, ctx.bp);
            }
        }.run, .{ io, .{ .l = loaded, .g = gpa, .p = path, .s = slot, .bp = paths } });
    }
    try group.await(io);
}

/// Whether `name` (lowercased) is in `loaded`; `Library.find`'s rule.
// ponytail: linear scan; a deck loads a handful of HDL modules.
fn isLoaded(loaded: []const []const u8, name: []const u8) bool {
    for (loaded) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// The sources of `files` still to compile, each once, in first-seen order:
/// `files` entries as given (for messages), and their resolved paths, the
/// identity `Library.sources` keeps. `sources` is what earlier loads
/// handled (`Library.sources`). Both results live in `arena`.
// ponytail: lexical resolution, so a symlinked second spelling still
// compiles (and then registers nothing, the module name being taken);
// key on the file's inode if that shows up.
pub fn pending(sources: []const []const u8, arena: std.mem.Allocator, files: []const []const u8) std.mem.Allocator.Error!struct { files: []const []const u8, resolved: []const []const u8 } {
    var todo: std.ArrayList([]const u8) = try .initCapacity(arena, files.len);
    var resolved: std.ArrayList([]const u8) = try .initCapacity(arena, files.len);
    // ponytail: linear scans; a deck names a handful of HDL sources.
    for (files) |f| {
        const r = try std.fs.path.resolve(arena, &.{f});
        if (has(sources, r) or has(resolved.items, r)) continue;
        todo.appendAssumeCapacity(f);
        resolved.appendAssumeCapacity(r);
    }
    std.debug.assert(todo.items.len == resolved.items.len);
    std.debug.assert(todo.items.len <= files.len);
    return .{ .files = todo.items, .resolved = resolved.items };
}

fn has(list: []const []const u8, path: []const u8) bool {
    for (list) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

/// VerA's `.v` contract device for `source`: 4-state, under the static
/// schedule (the CLI's default). Prints VerA's diagnostics, the W1155 1 s
/// tick warning included, and fails with `DigitalFailed` on its E1103
/// refusal.
fn emitDigital(arena: std.mem.Allocator, path: []const u8, source: []const u8) !DeviceZig {
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

test "pending: a source named twice, or loaded before, compiles once" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The same file under three spellings, as several `.lib` sections name it.
    const first = try pending(&.{}, a, &.{ "lib/m.va", "lib/./m.va", "other.va", "lib/sub/../m.va" });
    try std.testing.expectEqual(@as(usize, 2), first.files.len);
    try std.testing.expectEqualStrings("lib/m.va", first.files[0]);
    try std.testing.expectEqualStrings("other.va", first.files[1]);
    // A later load skips what an earlier one handled.
    const again = try pending(first.resolved, a, &.{ "other.va", "lib/m.va", "new.va" });
    try std.testing.expectEqual(@as(usize, 1), again.files.len);
    try std.testing.expectEqualStrings("new.va", again.files[0]);
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

test "normalizeCode: corner cases" {
    const g = std.testing.allocator;
    const Norm = struct {
        fn eql(a: []const u8, b: []const u8) !bool {
            const na = try normalizeCode(std.testing.allocator, a);
            defer std.testing.allocator.free(na);
            const nb = try normalizeCode(std.testing.allocator, b);
            defer std.testing.allocator.free(nb);
            return std.mem.eql(u8, na, nb);
        }
    };
    // A final line without '\n' and nothing to drop still fits the buffer.
    const bare = try normalizeCode(g, "a");
    defer g.free(bare);
    try std.testing.expectEqualStrings("a\n", bare);
    const empty = try normalizeCode(g, "");
    defer g.free(empty);
    try std.testing.expectEqualStrings("", empty);
    // Unterminated strings and comments run to the end without overreading.
    const open = try normalizeCode(g, "x = \"ab\\");
    defer g.free(open);
    try std.testing.expectEqualStrings("x = \"ab\\\n", open);
    const comment = try normalizeCode(g, "/* never closed\n");
    defer g.free(comment);
    try std.testing.expectEqualStrings("", comment);
    try std.testing.expect(try Norm.eql("a\r\nb\r\n", "a\nb\n"));
    // Whitespace inside a string after an escaped backslash is the string's.
    try std.testing.expect(!try Norm.eql("x = \"\\\\\"; y = \"a  b\";", "x = \"\\\\\"; y = \"a b\";"));
    try std.testing.expect(!try Norm.eql("x = \"\\\"  \";", "x = \"\\\" \";"));
    // A blank line ends a continued `define; dropping it would extend the body.
    try std.testing.expect(!try Norm.eql("`define X a \\\n\nb\n", "`define X a \\\nb\n"));
    // `__LINE__` keeps blank lines, since they move it.
    try std.testing.expect(!try Norm.eql("`__LINE__\n\nx\n", "`__LINE__\nx\n"));
    try std.testing.expect(try Norm.eql("x\n\ny\n", "x\ny\n"));
}

test "the loader takes every Verilog-A and Verilog extension the frontend routes to it" {
    for ([_][]const u8{ "m.va", "m.VA", "m.Va", "m.vams", "m.veriloga" }) |p| try std.testing.expectEqual(Hdl.va, hdl_extensions.get(std.fs.path.extension(p)).?);
    for ([_][]const u8{ "m.v", "m.V" }) |p| try std.testing.expectEqual(Hdl.v, hdl_extensions.get(std.fs.path.extension(p)).?);
    try std.testing.expect(hdl_extensions.get(".sv") == null);
}

test "inputKey keys a .va and a .v source apart" {
    const g = std.testing.allocator;
    const io = std.testing.io;
    const paths: BuildPaths = .{ .work_dir = ".", .contract = "c", .dyn = "d", .gompute = "g", .device_abi = "a", .core = "k" };
    const va = (try inputKey(io, g, .va, "m.va", "ssign y;\n", paths)).?;
    const v = (try inputKey(io, g, .v, "m.v", "assign y;\n", paths)).?;
    try std.testing.expect(!std.mem.eql(u8, &va, &v));
}

test "hashCode: includes it cannot follow, and __FILE__" {
    const g = std.testing.allocator;
    const io = std.testing.io;
    const Sha = std.crypto.hash.sha2.Sha256;
    var h = Sha.init(.{});
    try std.testing.expect(try hashCode(io, g, &h, .va, ".", "m.va", "module m; endmodule\n", 0));
    try std.testing.expect(!try hashCode(io, g, &h, .va, ".", "m.va", "`include `HDR\n", 0));
    try std.testing.expect(!try hashCode(io, g, &h, .va, ".", "m.va", "`include \"x", 0));
    try std.testing.expect(!try hashCode(io, g, &h, .v, ".", "m.v", "`include \"a.vh\"\n", 0));
    try std.testing.expect(!try hashCode(io, g, &h, .va, ".", "m.va", "", max_include_depth + 1));
    // Missing on disk: an annex header falls back to its name, anything else
    // gives up.
    const nowhere = "/nonexistent-espice-test-dir";
    try std.testing.expect(try hashCode(io, g, &h, .va, nowhere, "m.va", "`include \"disciplines.vams\"\n", 0));
    try std.testing.expect(!try hashCode(io, g, &h, .va, nowhere, "m.va", "`include \"nope.vh\"\n", 0));

    // The same text keys apart under two names only when it reads `__FILE__`.
    const Pair = struct {
        fn differ(text: []const u8) !bool {
            var a = Sha.init(.{});
            var b = Sha.init(.{});
            _ = try hashCode(std.testing.io, std.testing.allocator, &a, .va, ".", "a.va", text, 0);
            _ = try hashCode(std.testing.io, std.testing.allocator, &b, .va, ".", "b.va", text, 0);
            const da = a.finalResult();
            const db = b.finalResult();
            return !std.mem.eql(u8, &da, &db);
        }
    };
    try std.testing.expect(try Pair.differ("s = `__FILE__;\n"));
    try std.testing.expect(!try Pair.differ("s = 1;\n"));
}
