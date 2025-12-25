//! End-to-end compilation: a Verilog or Verilog-A source file in, a compiled
//! shared object out. Each pipeline lowers its source to contract-compliant Zig,
//! optionally dumps that Zig, then builds it into a `.so` against the caller's
//! `contract` module.

const std = @import("std");
const va = @import("zvaf");
const v = @import("zvf");

pub const Language = enum { verilog, verilog_a };

pub const Options = struct {
    io: std.Io,
    /// Directory to place the generated build tree and the resulting `.so`.
    output_dir: []const u8,
    /// Path to the `contract.zig` the generated device is compiled against.
    contract_root: []const u8,
    /// Library / device name. Defaults to the source file stem when null.
    device_name: ?[]const u8 = null,
    /// When set, the generated Zig source is also written to this path.
    dump_zig_path: ?[]const u8 = null,
};

pub const CompiledLibrary = struct {
    allocator: std.mem.Allocator,
    /// Path to the built shared object (`<output_dir>/zig-out/lib/lib<name>.so`).
    shared_object_path: []const u8,

    pub fn deinit(self: *CompiledLibrary) void {
        self.allocator.free(self.shared_object_path);
        self.* = undefined;
    }
};

/// Compile a Verilog-A file (`.va`) to a shared object.
pub fn compileVerilogAFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    opts: Options,
) !CompiledLibrary {
    const source = try readFile(allocator, opts.io, source_path);
    defer allocator.free(source);

    var result = try va.compileSource(allocator, source, null);
    defer result.deinit();
    const zig_source = try va.codegen.generate(allocator, &result.mir, &result.lower);
    defer allocator.free(zig_source);

    const name = opts.device_name orelse result.mir.name;
    return compileGenerated(allocator, name, zig_source, opts);
}

/// Compile a Verilog / SystemVerilog file (`.v` / `.sv`) to a shared object.
pub fn compileVerilogFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    opts: Options,
) !CompiledLibrary {
    const source = try readFile(allocator, opts.io, source_path);
    defer allocator.free(source);

    const zig_source = try v.fromVerilog(allocator, opts.io, source);
    defer allocator.free(zig_source);

    const name = opts.device_name orelse std.fs.path.stem(source_path);
    return compileGenerated(allocator, name, zig_source, opts);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch
        return error.SourceFileNotFound;
}

/// Write already-generated Zig into a throwaway build tree and compile it into a
/// dynamic library against the caller-provided contract module. Use this when
/// the codegen step was run separately (e.g. to extract port/param metadata).
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

    const src_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "src/root.zig" });
    defer allocator.free(src_path);
    try cwd.writeFile(io, .{ .sub_path = src_path, .data = generated_source });

    const abs_contract = try cwd.realPathFileAlloc(io, opts.contract_root, allocator);
    defer allocator.free(abs_contract);

    const build_source = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const contract_mod = b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\
        \\    const root_mod = b.createModule(.{{
        \\        .root_source_file = b.path("src/root.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &.{{
        \\            .{{ .name = "contract", .module = contract_mod }},
        \\        }},
        \\    }});
        \\
        \\    const lib = b.addLibrary(.{{
        \\        .linkage = .dynamic,
        \\        .name = "{s}",
        \\        .root_module = root_mod,
        \\    }});
        \\    b.installArtifact(lib);
        \\}}
        \\
    , .{ abs_contract, device_name });
    defer allocator.free(build_source);

    const build_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "build.zig" });
    defer allocator.free(build_path);
    try cwd.writeFile(io, .{ .sub_path = build_path, .data = build_source });

    const out_dir = try cwd.openDir(io, opts.output_dir, .{});
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", "-Doptimize=ReleaseFast" },
        .cwd = .{ .dir = out_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            const stdout_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "compile.stdout" });
            defer allocator.free(stdout_path);
            const stderr_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "compile.stderr" });
            defer allocator.free(stderr_path);
            cwd.writeFile(io, .{ .sub_path = stdout_path, .data = result.stdout }) catch {};
            cwd.writeFile(io, .{ .sub_path = stderr_path, .data = result.stderr }) catch {};
            return error.CompileFailed;
        },
        else => return error.CompileFailed,
    }

    const lib_name = try std.fmt.allocPrint(allocator, "lib{s}.so", .{device_name});
    defer allocator.free(lib_name);

    return .{
        .allocator = allocator,
        .shared_object_path = try std.fs.path.join(allocator, &.{ opts.output_dir, "zig-out", "lib", lib_name }),
    };
}
