//! cktimg.wasm for the docs playground: netlist text in, schematic SVG out.
//! ESPice's `zig build wasm` runs this build into its own prefix; run alone,
//! it installs zig-out/wasm/cktimg.wasm here.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const optimize: std.lang.Optimize = .small;
    const ck = b.dependency("cktimg", .{ .target = target, .optimize = optimize });
    const np = ck.module("NetlistParser");
    // cktImg's own symbol set, the one its tests and gallery draw with.
    const files = b.addWriteFiles();
    _ = files.addCopyFile(ck.path("tests/symbols.zon"), "symbols.zon");
    const symbols = b.createModule(.{ .root_source_file = files.add("symbols.zig", "pub const text = @embedFile(\"symbols.zon\");\n") });
    // Its SVG writer lives with its tests, on the public API only.
    const svg = b.createModule(.{
        .root_source_file = ck.path("tests/svg.zig"),
        .imports = &.{.{ .name = "NetlistParser", .module = np }},
    });
    const exe = b.addExecutable(.{ .name = "cktimg", .root_module = b.createModule(.{
        .root_source_file = b.path("cktimg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "NetlistParser", .module = np },
            .{ .name = "svg", .module = svg },
            .{ .name = "symbols", .module = symbols },
        },
    }) });
    exe.entry = .disabled;
    exe.rdynamic = true;
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } }).step);
}
