//! End-to-end runtime compilation: a Verilog or Verilog-A source in, a
//! dlopen-ready shared object out. Codegen lowers to contract-shaped Zig;
//! a generated build tree compiles it against the caller's module sources
//! (contract + analysis + solvers) with a one-line shim root that exports
//! the device under the analysis dyn ABI. Mechanism only — cache policy,
//! source-root discovery and dlopen live with the caller.

const std = @import("std");
const va = @import("zvaf");
const v = @import("zvf");

pub const Options = struct {
    io: std.Io,
    /// Directory for the generated build tree and the resulting `.so`.
    output_dir: []const u8,
    /// Module source roots the shim compiles against. Must match the running
    /// app's sources — the dyn ABI layout hash rejects the .so otherwise.
    contract_root: []const u8,
    analysis_root: []const u8,
    solvers_root: []const u8,
    /// Library / device name. Defaults to the module name from the source.
    device_name: ?[]const u8 = null,
    /// MUST match the loading app's optimize mode: Debug and Release std
    /// types differ in layout (SafetyLock et al.) and the dyn ABI layout
    /// hash will reject a mismatched .so.
    optimize: std.builtin.OptimizeMode = .ReleaseFast,
    /// MUST match the loading app's backend (self-hosted vs LLVM) — Zig-ABI
    /// details differ, and the layout hash pins the backend. The self-hosted
    /// backend also compiles the model ~10x faster.
    no_llvm: bool = false,
    /// When set, the generated Zig source is also written to this path.
    dump_zig_path: ?[]const u8 = null,
};

pub const CompiledLibrary = struct {
    allocator: std.mem.Allocator,
    /// `<output_dir>/zig-out/lib/lib<name>.so`
    shared_object_path: []const u8,
    device_name: []const u8,

    pub fn deinit(self: *CompiledLibrary) void {
        self.allocator.free(self.shared_object_path);
        self.allocator.free(self.device_name);
        self.* = undefined;
    }
};

/// Verilog-A source text → codegen → compiled `.so`.
pub fn compileVerilogA(
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) !CompiledLibrary {
    var result = try va.compileSource(allocator, source, null);
    defer result.deinit();
    const zig_source = try va.codegen.generate(allocator, &result.mir, &result.lower);
    defer allocator.free(zig_source);

    const name = opts.device_name orelse result.mir.name;
    return compileGenerated(allocator, name, zig_source, opts);
}

/// Verilog / SystemVerilog source text → codegen → compiled `.so`.
pub fn compileVerilog(
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) !CompiledLibrary {
    const zig_source = try v.fromVerilog(allocator, opts.io, source);
    defer allocator.free(zig_source);

    const name = opts.device_name orelse moduleName(source) orelse return error.NoModuleName;
    return compileGenerated(allocator, name, zig_source, opts);
}

/// `module NAME (...)` — first module wins.
pub fn moduleName(source: []const u8) ?[]const u8 {
    const mod_start = std.mem.indexOf(u8, source, "module ") orelse return null;
    const paren = std.mem.indexOfPos(u8, source, mod_start, "(") orelse return null;
    const name = std.mem.trim(u8, source[mod_start + 7 .. paren], " \t\n\r");
    return if (name.len > 0) name else null;
}

/// Write already-generated device Zig into a throwaway build tree and compile
/// it into a dynamic library exporting the analysis dyn ABI.
pub fn compileGenerated(
    allocator: std.mem.Allocator,
    device_name: []const u8,
    generated_source: []const u8,
    opts: Options,
) !CompiledLibrary {
    const io = opts.io;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, opts.output_dir) catch {};

    if (opts.dump_zig_path) |dump| {
        try cwd.writeFile(io, .{ .sub_path = dump, .data = generated_source });
    }

    const src_subdir = try std.fs.path.join(allocator, &.{ opts.output_dir, "src" });
    defer allocator.free(src_subdir);
    cwd.createDirPath(io, src_subdir) catch {};

    const dev_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "src/device.zig" });
    defer allocator.free(dev_path);
    try cwd.writeFile(io, .{ .sub_path = dev_path, .data = generated_source });

    // Shim root: export the device under the dyn ABI. exportDevice pulls in
    // ProtoStore/DeviceBatch, so the .so carries the same batch machinery
    // (and machine code) the app's baked devices get.
    const shim_source = try std.fmt.allocPrint(allocator,
        \\const dyn = @import("analysis").problem.dyn;
        \\comptime {{
        \\    dyn.exportDevice(@import("device"), "{s}");
        \\}}
        \\
    , .{device_name});
    defer allocator.free(shim_source);
    const shim_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "src/shim.zig" });
    defer allocator.free(shim_path);
    try cwd.writeFile(io, .{ .sub_path = shim_path, .data = shim_source });

    const abs_contract = try cwd.realPathFileAlloc(io, opts.contract_root, allocator);
    defer allocator.free(abs_contract);
    const abs_analysis = try cwd.realPathFileAlloc(io, opts.analysis_root, allocator);
    defer allocator.free(abs_analysis);
    const abs_solvers = try cwd.realPathFileAlloc(io, opts.solvers_root, allocator);
    defer allocator.free(abs_solvers);

    const build_source = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const solvers_mod = b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    const analysis_mod = b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{{ .{{ .name = "solvers", .module = solvers_mod }} }},
        \\    }});
        \\    const contract_mod = b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    const device_mod = b.createModule(.{{
        \\        .root_source_file = b.path("src/device.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{{ .{{ .name = "contract", .module = contract_mod }} }},
        \\    }});
        \\    const shim_mod = b.createModule(.{{
        \\        .root_source_file = b.path("src/shim.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{{
        \\            .{{ .name = "analysis", .module = analysis_mod }},
        \\            .{{ .name = "device", .module = device_mod }},
        \\        }},
        \\    }});
        \\    const lib = b.addLibrary(.{{
        \\        .linkage = .dynamic,
        \\        .name = "{s}",
        \\        .root_module = shim_mod,
        \\    }});
        \\    lib.use_llvm = {s};
        \\    lib.use_lld = {s};
        \\    b.installArtifact(lib);
        \\}}
        \\
    , .{ abs_solvers, abs_analysis, abs_contract, device_name, if (opts.no_llvm) "false" else "true", if (opts.no_llvm) "false" else "true" });
    defer allocator.free(build_source);

    const build_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "build.zig" });
    defer allocator.free(build_path);
    try cwd.writeFile(io, .{ .sub_path = build_path, .data = build_source });

    const opt_arg = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{@tagName(opts.optimize)});
    defer allocator.free(opt_arg);
    const out_dir = try cwd.openDir(io, opts.output_dir, .{});
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", opt_arg },
        .cwd = .{ .dir = out_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            const stderr_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "compile.stderr" });
            defer allocator.free(stderr_path);
            cwd.writeFile(io, .{ .sub_path = stderr_path, .data = result.stderr }) catch {};
            std.debug.print("{s}", .{result.stderr});
            return error.CompileFailed;
        },
        else => return error.CompileFailed,
    }

    const lib_name = try std.fmt.allocPrint(allocator, "lib{s}.so", .{device_name});
    defer allocator.free(lib_name);

    return .{
        .allocator = allocator,
        .shared_object_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "zig-out", "lib", lib_name }),
        .device_name = try allocator.dupe(u8, device_name),
    };
}
