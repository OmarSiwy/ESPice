//! Build orchestration & artifact contract. LRM §8.3 device-side ABI only; the
//! rest is engine machinery (no LRM section). See docs/architecture/
//! 02-incremental.html and 05-build-artifact.html.
//!
//! Transformation: device.zig → lib<name>.so (+ GPU kernels) + layout hash +
//! rebuilt signal.
//!
//! CRATE BOUNDARY (do not cross it): FastVAF PRODUCES the artifact. The host
//! OWNS dlopen/dlclose/state-reset. Emit a VERSIONED .so path per generation so
//! the host dlopens a fresh inode (sidesteps dlclose-didn't-unload).
//!
//! Backend split:
//!   - Debug   → self-hosted, incremental via a resident compiler child holding
//!               -fincremental. Build ONLY on demand (not --watch).
//!               Cross-process -fincremental is unimplemented on ELF 0.16, so the
//!               child MUST stay resident to keep incremental state warm.
//!   - Release → LLVM, cold build, per-unit float mode, + GPU kernels.
//!
//! DEVIATION FROM 05-build-artifact.html, verified on this toolchain
//! (zig 0.16.0): the doc prescribes a resident `zig build --listen=-` child
//! speaking the BUILD-RUNNER protocol. That flag no longer exists —
//!
//!     $ zig build --listen=-
//!     unrecognized argument: '--listen=-'
//!
//! 0.16's build runner replaced it with `--webui` (HTTP/WebSocket). The
//! COMPILER still speaks `--listen=-` (std.zig.Server/Client), and that is the
//! process that actually owns incremental state, so the resident child here is
//! `zig build-lib --listen=-` driven directly. Consequence: no generated
//! build.zig at all — the module graph goes on the command line as
//! `--dep`/`-M` pairs, which is exactly what std.Build.Step.Compile emits.

const std = @import("std");
const builtin = @import("builtin");
const codegen = @import("codegen.zig");
const naming = @import("naming.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const ClientMsg = std.zig.Client.Message;
const ServerMsg = std.zig.Server.Message;

pub const Backend = enum { self_hosted, llvm };

/// One support module on the compiler command line. `name` is the `@import`
/// string; `root` is a path to its root source file (relative to the process
/// cwd, or absolute). All strings are BORROWED — they must outlive the
/// `ResidentChild`.
pub const Module = struct {
    name: []const u8,
    root: []const u8,
    /// Names of other entries in `Options.modules` this one imports.
    deps: []const []const u8 = &.{},
};

/// Everything the layout hash pins, plus where to put things. Borrowed strings.
pub const Options = struct {
    /// FastVAF-owned directory: generated device.zig + shim.zig, the compiler
    /// cache, and the versioned artifacts. Created if absent.
    work_dir: []const u8,
    /// Device name. Artifact is `<work_dir>/lib<name>.<generation>.so`.
    name: []const u8,
    /// Debug ⇒ `.self_hosted`; ReleaseFast ⇒ `.llvm` (see the table in ch.5).
    optimize: std.builtin.OptimizeMode,
    backend: Backend,
    /// Support modules. MUST contain `contract` (device.zig imports it) and
    /// `dyn`, whose root must expose
    /// `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`
    /// — in this repo that is `modules/devices/src/engine.zig`. Order is
    /// load-bearing: it is hashed into `layout_hash` and fixes argv order.
    modules: []const Module,
    zig_exe: []const u8 = "zig",
};

pub const Artifact = struct {
    /// Versioned: lib<name>.<generation>.so  — host dlopens this fresh inode.
    so_path: []const u8,
    /// dyn-ABI layout hash. Host rejects a mismatched .so (pins optimize mode,
    /// backend, module roots). LRM §8.3 device ABI.
    layout_hash: u64,
    generation: u32,
    /// The "rebuilt" half of the rebuilt signal: false ⇒ the compiler actually
    /// produced new code this round.
    cache_hit: bool = false,
    /// Present only for ReleaseFast (SPIR-V/PTX/AMDGCN). Host loads/launches.
    /// ponytail: always empty. GPU emission already lives in
    /// modules/devices/build.zig (gompute), and eval_batch.zig has no kernel
    /// entry point yet — wiring a second `build-lib` per GPU target here would
    /// be dead code. Upgrade path: one extra `runCompiler` call per GPU target
    /// with `-target spirv64-vulkan`/`nvptx64-cuda`/`amdgcn-amdhsa`, appended
    /// here; the rest of this file needs no change.
    gpu_kernel_paths: []const []const u8 = &.{},
};

/// A build outcome. `failed` owns its bundle — `bundle.deinit(gpa)`.
pub const Result = union(enum) {
    ok: Artifact,
    failed: std.zig.ErrorBundle,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        switch (self.*) {
            .ok => |a| gpa.free(a.so_path),
            .failed => |*b| b.deinit(gpa),
        }
        self.* = undefined;
    }
};

pub const Error = error{
    /// The child died mid-update and did not recover on respawn.
    CompilerGone,
    /// The child spoke a protocol we do not understand, or is a different zig.
    ProtocolMismatch,
    /// The compiler reported success but emitted no `emit_digest`.
    NoArtifact,
} || Allocator.Error;

/// Pins optimize mode, backend, the module graph, AND the compiler version:
/// Debug and Release std types differ in layout, and so do two zig versions.
/// A mismatched .so loaded silently is memory corruption — the host compares
/// this against `arp_layout_hash` in the .so before using it.
///
/// Determinism: only ordered slices are hashed; nothing iterates a hash map.
pub fn layoutHash(o: Options) u64 {
    var h: std.hash.Wyhash = .init(0xfa57_0af0_1a40_07);
    h.update(builtin.zig_version_string);
    h.update(&.{0});
    h.update(@tagName(o.optimize));
    h.update(&.{0});
    h.update(@tagName(o.backend));
    h.update(&.{0});
    for (o.modules) |m| {
        h.update(m.name);
        h.update(&.{0});
        h.update(m.root);
        h.update(&.{0});
        for (m.deps) |d| {
            h.update(d);
            h.update(&.{0});
        }
        h.update(&.{1});
    }
    return h.final();
}

// ===========================================================================
// Build tree
// ===========================================================================

/// The dyn-ABI export shim (ch.5): one line that re-exports the generated
/// device under the host's C ABI. Depends only on the device name, so it is
/// byte-identical across rebuilds and never dirties.
fn shimSource(gpa: Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\// GENERATED BY FastVAF — DO NOT EDIT.
        \\comptime {{
        \\    @import("dyn").exportDevice(@import("device"), "{s}");
        \\}}
        \\
    , .{name});
}

/// Write `data` only if it differs from what is on disk; returns whether it
/// wrote. Load-bearing for incremental: `zig` keys its per-file ZIR cache on
/// `stat_inode`/`stat_size`/`stat_mtime` (`Zir.Header` in std/zig/Zir.zig), so
/// rewriting an identical file churns its mtime and forces the compiler to
/// re-run AstGen over it. A no-op edit must be a no-op on disk.
///
/// The return value is the write COUNT the incremental story is actually about
/// — `writeTree` sums it, and the "a no-op recompile writes nothing" test is
/// that sum being zero.
fn writeIfChanged(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    sub_path: []const u8,
    data: []const u8,
) !bool {
    if (dir.readFileAlloc(io, sub_path, gpa, .limited(data.len + 1))) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    return true;
}

/// `<work_dir>/{device.zig, shim.zig, u/<key>.zig …}`. No build.zig — see the
/// header. Returns how many files were actually written.
///
/// ONE FILE PER EMITTED DECLARATION, because `zig`'s cache unit is the file.
/// `device.zig` keeps the prologue (topology / `Model` / `Instance`) and the
/// dispatchers and re-imports the rest by their stable structural names, so the
/// only thing crossing a file boundary is a name `naming.zig` already guarantees
/// is insert-tolerant.
///
/// Since the merge (docs/architecture/OUTPUT-VOLUME.md) that is usually TWO
/// files, not ~105: `u/<model>__common__core.zig` holding the whole model, plus
/// one `u/<key>__sec.zig` per §4.5.11/§4.5.12 filter and one for the §9.4
/// display unit when they exist. The split is worth much less than it was — an
/// edit to the physics rewrites the one 3.1 MB file rather than one of 105
/// small ones — but it is not worthless and it is not a special case:
///
///   - `device.zig` (40 KB on `hisimhv_va`) and `h.zig` stay byte- AND
///     mtime-identical across an edit that only changes an expression, so
///     AstGen skips them; and the reverse holds for an edit that only renames a
///     parameter. `writeIfChanged` is what makes a no-op recompile write zero
///     bytes, and that property is what `tests/bench.zig` measures.
///   - the core was ALREADY one 60 000-line declaration before the merge, so
///     the granularity the per-unit split promised was mostly gone already: any
///     shared value re-Sema'd all of it. See 02-incremental.html.
///
/// `pruneUnits` is what makes the shrink safe: a tree written by an older
/// FastVAF has ~105 `u/*.zig`, and leaving 104 stale ones behind would keep
/// feeding `zig` declarations nothing imports.
///
/// FastVAF builds no change-detection of its own here: `writeIfChanged` is a
/// content compare, and everything past the write is `zig`'s job
/// (02-incremental.html — "delegated, we do no hashing of our own").
fn writeTree(io: Io, gpa: Allocator, o: Options, device: codegen.Output) !usize {
    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, o.work_dir);
    var dir = try cwd.openDir(io, o.work_dir, .{});
    defer dir.close(io);

    var writes: usize = 0;

    const shim = try shimSource(gpa, o.name);
    defer gpa.free(shim);
    if (try writeIfChanged(io, gpa, dir, "shim.zig", shim)) writes += 1;

    if (device.names.len == 0) {
        // `Output.single` — no split (the CLI's `--emit-zig`, and the tests).
        if (try writeIfChanged(io, gpa, dir, "device.zig", device.text)) writes += 1;
        return writes;
    }

    if (try writeIfChanged(io, gpa, dir, "h.zig", device.helpers)) writes += 1;

    try dir.createDirPath(io, unit_dir);
    var udir = try dir.openDir(io, unit_dir, .{ .iterate = true });
    defer udir.close(io);

    // One buffer reused for every unit path and every unit body: the paths are
    // short and the bodies are written straight from `device.text`.
    var path_buf: [naming.max_name_len + 8]u8 = undefined;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    for (device.names, device.unit_lo, device.unit_fn, device.unit_hi) |name, lo, fn_at, hi| {
        body.clearRetainingCapacity();
        try body.appendSlice(gpa, device.prelude);
        // `pub ` goes in here, not in the emission: `device.text` is also the
        // stand-alone `--emit-zig` form, where `contract.rejectStrayPubDecls`
        // allows only contract-recognized names to be public.
        try body.appendSlice(gpa, device.text[lo..fn_at]);
        if (!std.mem.startsWith(u8, device.text[fn_at..], "pub ")) try body.appendSlice(gpa, "pub ");
        try body.appendSlice(gpa, device.text[fn_at..hi]);
        const p = try std.fmt.bufPrint(&path_buf, "{s}.zig", .{name});
        if (try writeIfChanged(io, gpa, udir, p, body.items)) writes += 1;
    }

    // device.zig = prologue ++ one import per unit ++ dispatcher tail. The
    // ranges tile (`codegen.Output`'s invariant), so those three pieces are the
    // whole file.
    body.clearRetainingCapacity();
    try body.appendSlice(gpa, device.text[0..device.unit_lo[0]]);
    for (device.names) |name| {
        try body.print(gpa, "const {0s} = @import(\"{1s}/{0s}.zig\").{0s};\n", .{ name, unit_dir });
    }
    try body.appendSlice(gpa, "\n");
    try body.appendSlice(gpa, device.text[device.unit_hi[device.unit_hi.len - 1]..]);
    if (try writeIfChanged(io, gpa, dir, "device.zig", body.items)) writes += 1;

    writes += try pruneUnits(io, gpa, udir, device.names);
    return writes;
}

const unit_dir = "u";

/// Delete `u/*.zig` whose key is no longer emitted — a contribution the user
/// removed. Leaving it behind is not just clutter: it is a stale declaration
/// `zig` would keep analysing, and it would silently mask the next name
/// collision.
///
// ponytail: O(files × units) membership scan. A module has ~100 units and the
// directory has ~100 entries; switch to a StringHashMap of the names if a model
// ever shows up with thousands.
fn pruneUnits(io: Io, gpa: Allocator, udir: Io.Dir, names: []const []const u8) !usize {
    var stale: std.ArrayList([]const u8) = .empty;
    defer {
        for (stale.items) |s| gpa.free(s);
        stale.deinit(gpa);
    }

    // Collect first, delete after: mutating a directory while iterating it is
    // unspecified on every filesystem this runs on.
    var it = udir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        var live = false;
        for (names) |n| {
            if (std.mem.eql(u8, n, stem)) live = true;
        }
        if (!live) try stale.append(gpa, try gpa.dupe(u8, entry.name));
    }
    for (stale.items) |s| try udir.deleteFile(io, s);
    return stale.items.len;
}

/// `zig build-lib --listen=- ... -Mroot=shim.zig -Mdevice=... -M<support>...`
///
/// Argument shape copied from `std.Build.Step.Compile.getZigArgs`: every
/// `--dep` applies to the NEXT `-M`. Deterministic: `o.modules` order is the
/// argv order.
fn buildArgv(arena: Allocator, o: Options) ![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;

    try a.appendSlice(arena, &.{
        o.zig_exe,
        "build-lib",
        "--listen=-",
        "-dynamic",
        try std.fmt.allocPrint(arena, "-O{s}", .{@tagName(o.optimize)}),
        "--name",
        o.name,
        "--cache-dir",
        try std.fs.path.join(arena, &.{ o.work_dir, ".zig-cache" }),
    });

    switch (o.backend) {
        // ~10× faster than LLVM and the only backend that patches in place, so
        // it is the only one `-fincremental` is worth anything on (ch.2).
        .self_hosted => try a.appendSlice(arena, &.{ "-fno-llvm", "-fno-lld", "-fincremental" }),
        .llvm => try a.append(arena, "-fllvm"),
    }

    // root = shim.zig: imports `device` plus every support module.
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    try a.appendSlice(arena, &.{
        "--dep",
        "device",
        try std.fmt.allocPrint(arena, "-Mroot={s}", .{
            try std.fs.path.join(arena, &.{ o.work_dir, "shim.zig" }),
        }),
    });

    // device.zig: `const contract = @import("contract");` (codegen.zig header).
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    try a.append(arena, try std.fmt.allocPrint(arena, "-Mdevice={s}", .{
        try std.fs.path.join(arena, &.{ o.work_dir, "device.zig" }),
    }));

    for (o.modules) |m| {
        for (m.deps) |d| try a.appendSlice(arena, &.{ "--dep", d });
        try a.append(arena, try std.fmt.allocPrint(arena, "-M{s}={s}", .{ m.name, m.root }));
    }

    return a.items;
}

// ===========================================================================
// Resident compiler child
// ===========================================================================

/// Long-lived compiler. Spawn once per session (per optimize/backend tuple);
/// reuse across edits so incremental state stays warm. Incremental state lives
/// in the child's MEMORY — 0.16 cannot serialise it to disk ("TODO implement
/// saving linker state for elf2"), so killing the child throws it away.
pub const ResidentChild = struct {
    io: Io,
    opts: Options,
    /// Owns argv and every string in it.
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    child: std.process.Child,
    /// Backing store for `stdout`; owned by `arena`.
    stdout_buf: []u8,
    stdout: Io.File.Reader,
    layout_hash: u64,

    /// Bodies seen so far: `file_system_inputs` runs ~20 KiB on a std-linked
    /// device, error bundles more. Growable via `readAlloc`, this is only the
    /// steady-state buffer.
    const buf_len = 64 * 1024;

    /// Spawn the child. The first build is cold; every later `rebuild` reuses
    /// the warm state. `o` and all strings it points at must outlive this.
    pub fn spawn(gpa: Allocator, io: Io, o: Options) !ResidentChild {
        var self: ResidentChild = .{
            .io = io,
            .opts = o,
            .arena = .init(gpa),
            .argv = &.{},
            .child = undefined,
            .stdout_buf = &.{},
            .stdout = undefined,
            .layout_hash = layoutHash(o),
        };
        errdefer self.arena.deinit();

        const arena = self.arena.allocator();
        self.argv = try buildArgv(arena, o);
        self.stdout_buf = try arena.alloc(u8, buf_len);

        try self.start();
        return self;
    }

    /// (Re)launch the compiler. Safe to call after the child has died.
    fn start(self: *ResidentChild) !void {
        self.child = std.process.spawn(self.io, .{
            .argv = self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            // Compiler panics land straight on the user's terminal, and a full
            // stderr pipe can never deadlock the update loop.
            .stderr = .inherit,
        }) catch return error.CompilerGone;
        self.stdout = self.child.stdout.?.readerStreaming(self.io, self.stdout_buf);
    }

    fn stop(self: *ResidentChild) void {
        if (self.child.stdin) |stdin| {
            self.send(.exit) catch {};
            stdin.close(self.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.io) catch {
            self.child.kill(self.io);
        };
    }

    pub fn deinit(self: *ResidentChild) void {
        self.stop();
        self.arena.deinit();
        self.* = undefined;
    }

    /// On-demand rebuild: write the regenerated device.zig into the resident
    /// tree, ask for one update, read the answer. NO filesystem watching —
    /// a build fires only from here.
    ///
    /// On a build failure the child is KEPT ALIVE: its warm state is still
    /// valid for the next attempt.
    pub fn rebuild(
        self: *ResidentChild,
        gpa: Allocator,
        device: codegen.Output,
        generation: u32,
    ) !Result {
        _ = try writeTree(self.io, gpa, self.opts, device);
        return self.update(gpa, generation) catch |err| switch (err) {
            // ponytail: zig 0.16.0 SIGSEGVs the resident compiler on the second
            // `update` when inputs changed. Reproduced on the official path too
            // (`zig build --watch -fincremental` logs "restart required:
            // BrokenPipe" and respawns), so this is a compiler bug, not our
            // framing. std.Build.Step.evalZigProcess recovers exactly this way.
            // Cost: that one build is cold. Delete this arm once the compiler
            // survives repeated updates.
            error.CompilerGone => blk: {
                self.stop();
                try self.start();
                break :blk try self.update(gpa, generation);
            },
            else => err,
        };
    }

    fn send(self: *ResidentChild, tag: ClientMsg.Tag) !void {
        const stdin = self.child.stdin orelse return error.CompilerGone;
        var w = stdin.writer(self.io, &.{});
        w.interface.writeStruct(ClientMsg.Header{ .tag = tag, .bytes_len = 0 }, .little) catch
            return error.CompilerGone;
    }

    /// One request/response round of the compiler server protocol. The update
    /// is terminated by `error_bundle` (possibly empty) — same rule
    /// `std.Build.Step.zigProcessUpdate` uses in its resident mode.
    fn update(self: *ResidentChild, gpa: Allocator, generation: u32) !Result {
        try self.send(.update);

        const r = &self.stdout.interface;
        var digest: ?Cache.BinDigest = null;
        var cache_hit = false;

        while (true) {
            const header = r.takeStruct(ServerMsg.Header, .little) catch return error.CompilerGone;
            const body = r.readAlloc(gpa, header.bytes_len) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.CompilerGone,
            };
            defer gpa.free(body);

            switch (header.tag) {
                .zig_version => if (!std.mem.eql(u8, builtin.zig_version_string, body))
                    return error.ProtocolMismatch,
                .emit_digest => {
                    if (body.len < @sizeOf(ServerMsg.EmitDigest) + Cache.bin_digest_len)
                        return error.ProtocolMismatch;
                    const eh: *align(1) const ServerMsg.EmitDigest = @ptrCast(body.ptr);
                    cache_hit = eh.flags.cache_hit;
                    digest = body[@sizeOf(ServerMsg.EmitDigest)..][0..Cache.bin_digest_len].*;
                },
                .error_bundle => {
                    var bundle = try std.zig.Server.allocErrorBundle(gpa, body);
                    if (bundle.errorMessageCount() > 0) return .{ .failed = bundle };
                    bundle.deinit(gpa);
                    break;
                },
                // file_system_inputs / time_report / test_* — nothing here
                // watches the filesystem, so they are consumed and dropped.
                else => {},
            }
        }

        const d = digest orelse return error.NoArtifact;
        return .{ .ok = .{
            .so_path = try self.publish(gpa, d, generation),
            .layout_hash = self.layout_hash,
            .generation = generation,
            .cache_hit = cache_hit,
        } };
    }

    /// Copy the compiler's cache output to a generation-stamped path so the
    /// host dlopens a FRESH INODE. Copy, not link: a hardlink shares the cache
    /// entry's inode, which is the very thing that makes a same-path dlopen
    /// hand back stale code. Caller owns the returned path.
    fn publish(
        self: *ResidentChild,
        gpa: Allocator,
        digest: Cache.BinDigest,
        generation: u32,
    ) ![]u8 {
        const t = &builtin.target;
        const lib_name = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
            t.libPrefix(), self.opts.name, t.dynamicLibSuffix(),
        });
        defer gpa.free(lib_name);

        const src = try std.fs.path.join(gpa, &.{
            self.opts.work_dir, ".zig-cache", "o", &Cache.binToHex(digest), lib_name,
        });
        defer gpa.free(src);

        const dst = try std.fmt.allocPrint(gpa, "{s}{c}{s}{s}.{d}{s}", .{
            self.opts.work_dir, std.fs.path.sep, t.libPrefix(),
            self.opts.name,     generation,      t.dynamicLibSuffix(),
        });
        errdefer gpa.free(dst);

        const cwd: Io.Dir = .cwd();
        cwd.copyFile(src, cwd, dst, self.io, .{}) catch return error.NoArtifact;
        return dst;
    }
};

/// ReleaseFast: cold, one-shot build. LLVM, per-unit float mode (already baked
/// into device.zig by codegen.zig), GPU kernels.
///
/// Same machinery as the resident path — the only differences are in `o`
/// (`.llvm` ⇒ no `-fincremental`, LLVM cannot patch in place) and that the
/// child is reaped immediately. Caller owns `Result`.
pub fn compileRelease(
    gpa: Allocator,
    io: Io,
    o: Options,
    device: codegen.Output,
    generation: u32,
) !Result {
    std.debug.assert(o.backend == .llvm);
    var child = try ResidentChild.spawn(gpa, io, o);
    defer child.deinit();
    return child.rebuild(gpa, device, generation);
}

// ===========================================================================
// Tests
// ===========================================================================

test "layoutHash pins optimize, backend and the module graph" {
    const mods = [_]Module{
        .{ .name = "contract", .root = "c.zig" },
        .{ .name = "dyn", .root = "d.zig", .deps = &.{"contract"} },
    };
    const base: Options = .{
        .work_dir = "w",
        .name = "dev",
        .optimize = .Debug,
        .backend = .self_hosted,
        .modules = &mods,
    };

    try std.testing.expectEqual(layoutHash(base), layoutHash(base));

    var o = base;
    o.optimize = .ReleaseFast;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    o = base;
    o.backend = .llvm;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    const other = [_]Module{
        .{ .name = "contract", .root = "OTHER.zig" },
        .{ .name = "dyn", .root = "d.zig", .deps = &.{"contract"} },
    };
    o = base;
    o.modules = &other;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    // Order is part of the graph identity.
    const swapped = [_]Module{ mods[1], mods[0] };
    o = base;
    o.modules = &swapped;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    // `work_dir`/`name` are placement, not ABI — they must NOT move the hash.
    o = base;
    o.work_dir = "elsewhere";
    o.name = "other";
    try std.testing.expectEqual(layoutHash(base), layoutHash(o));
}

/// A two-unit device in the shape `codegen.generate` produces: prologue, two
/// tiling unit ranges, dispatcher tail.
const split_prologue =
    \\const contract = @import("contract");
    \\pub const k2: f64 = 2.0;
    \\
;
const split_unit_a =
    \\fn unit_a(y: f64) f64 {
    \\    return y * k2;
    \\}
    \\
;
const split_unit_b =
    \\fn unit_b(y: f64) f64 {
    \\    return y + k2;
    \\}
    \\
;
const split_tail =
    \\pub fn eval(x: f64) callconv(.c) f64 {
    \\    return unit_a(x) + unit_b(x);
    \\}
    \\
;
const split_text = split_prologue ++ split_unit_a ++ split_unit_b ++ split_tail;
const split_prelude = "const dev = @import(\"../device.zig\");\nconst k2 = dev.k2;\n";

fn splitOutput(names: []const []const u8) codegen.Output {
    return .{
        .text = split_text,
        .names = names,
        .unit_lo = &.{
            split_prologue.len,
            split_prologue.len + split_unit_a.len,
        },
        .unit_fn = &.{
            split_prologue.len,
            split_prologue.len + split_unit_a.len,
        },
        .unit_hi = &.{
            split_prologue.len + split_unit_a.len,
            split_prologue.len + split_unit_a.len + split_unit_b.len,
        },
        .prelude = split_prelude,
        .helpers = "pub const k3: f64 = 3.0;\n",
    };
}

test "writeTree splits per unit, and a no-op regeneration writes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    const o: Options = .{
        .work_dir = work,
        .name = "testdev",
        .optimize = .Debug,
        .backend = .self_hosted,
        .modules = &.{},
    };

    const both = [_][]const u8{ "unit_a", "unit_b" };
    // shim + h.zig + 2 units + device.zig
    try std.testing.expectEqual(@as(usize, 5), try writeTree(io, gpa, o, splitOutput(&both)));

    // THE point of the split: regenerating an unchanged device touches nothing
    // on disk, so `zig` sees identical mtime/size/inode on every file and skips
    // AstGen for all of them (`Zir.Header` in std/zig/Zir.zig).
    try std.testing.expectEqual(@as(usize, 0), try writeTree(io, gpa, o, splitOutput(&both)));

    // The unit file is prelude ++ exactly its slice of the emission.
    const a = try tmp.dir.readFileAlloc(io, "u/unit_a.zig", gpa, .limited(4096));
    defer gpa.free(a);
    try std.testing.expectEqualStrings(split_prelude ++ "pub " ++ split_unit_a, a);

    // device.zig is prologue ++ imports ++ tail — the units themselves are gone.
    const dev = try tmp.dir.readFileAlloc(io, "device.zig", gpa, .limited(4096));
    defer gpa.free(dev);
    try std.testing.expect(std.mem.startsWith(u8, dev, split_prologue));
    try std.testing.expect(std.mem.endsWith(u8, dev, split_tail));
    try std.testing.expect(std.mem.indexOf(u8, dev, "const unit_a = @import(\"u/unit_a.zig\").unit_a;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dev, "return y * k2;") == null);

    // A unit that vanished takes its file with it: the rewritten device.zig
    // plus the delete. `u/unit_a.zig` is byte-identical, so it is NOT rewritten
    // — which is the whole reason zig will skip re-analysing it.
    const shrunk: codegen.Output = .{
        .text = split_prologue ++ split_unit_a ++ split_tail,
        .names = &.{"unit_a"},
        .unit_lo = &.{split_prologue.len},
        .unit_fn = &.{split_prologue.len},
        .unit_hi = &.{split_prologue.len + split_unit_a.len},
        .prelude = split_prelude,
        .helpers = "pub const k3: f64 = 3.0;\n",
    };
    try std.testing.expectEqual(@as(usize, 2), try writeTree(io, gpa, o, shrunk));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "u/unit_b.zig", .{}));
}

test "resident child builds, versions and rebuilds a device" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    // Minimal stand-ins for the host's modules. `dyn`'s only obligation is the
    // `exportDevice` signature the shim calls.
    try tmp.dir.writeFile(io, .{ .sub_path = "contract.zig", .data = "pub const k: f64 = 2.0;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dyn.zig", .data =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    });

    const mods = [_]Module{
        .{ .name = "contract", .root = try std.fs.path.join(gpa, &.{ work, "contract.zig" }) },
        .{ .name = "dyn", .root = try std.fs.path.join(gpa, &.{ work, "dyn.zig" }) },
    };
    defer for (mods) |m| gpa.free(m.root);

    const o: Options = .{
        .work_dir = work,
        .name = "testdev",
        .optimize = .Debug,
        .backend = .self_hosted,
        .modules = &mods,
    };

    var child = ResidentChild.spawn(gpa, io, o) catch |err| switch (err) {
        // No `zig` on PATH in this environment: nothing to assert.
        error.CompilerGone => return error.SkipZigTest,
        else => return err,
    };
    defer child.deinit();

    const dev_v1 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;
    var r1 = try child.rebuild(gpa, .single(dev_v1), 1);
    defer r1.deinit(gpa);
    switch (r1) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch {};
            return error.UnexpectedBuildFailure;
        },
        .ok => |a| {
            try std.testing.expectEqual(@as(u32, 1), a.generation);
            try std.testing.expectEqual(layoutHash(o), a.layout_hash);
            try std.testing.expect(std.mem.endsWith(u8, a.so_path, "libtestdev.1.so"));
            _ = try Io.Dir.cwd().statFile(io, a.so_path, .{});
        },
    }

    // A changed unit rebuilds to a fresh inode under a new generation.
    const dev_v2 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k + 1.0; }
        \\
    ;
    var r2 = try child.rebuild(gpa, .single(dev_v2), 2);
    defer r2.deinit(gpa);
    switch (r2) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch {};
            return error.UnexpectedBuildFailure;
        },
        .ok => |a| {
            try std.testing.expect(std.mem.endsWith(u8, a.so_path, "libtestdev.2.so"));
            _ = try Io.Dir.cwd().statFile(io, a.so_path, .{});
        },
    }

    // A broken unit is reported as diagnostics, and the child survives it.
    var r3 = try child.rebuild(gpa, .single("pub fn eval() void { @compileError(\"boom\"); }\n"), 3);
    defer r3.deinit(gpa);
    try std.testing.expect(r3 == .failed);

    var r4 = try child.rebuild(gpa, .single(dev_v2), 4);
    defer r4.deinit(gpa);
    try std.testing.expect(r4 == .ok);

    // The SPLIT form compiles too: `zig` resolves `device.zig`'s
    // `@import("u/<key>.zig")` and the unit file's `@import("../device.zig")`
    // back the other way. A cycle between two files is legal Zig; if it were
    // not, the whole per-unit scheme would be unbuildable.
    var r5 = try child.rebuild(gpa, splitOutput(&.{ "unit_a", "unit_b" }), 5);
    defer r5.deinit(gpa);
    switch (r5) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch {};
            return error.UnexpectedBuildFailure;
        },
        .ok => |a| try std.testing.expect(std.mem.endsWith(u8, a.so_path, "libtestdev.5.so")),
    }
}
