const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // GPU kernel emission belongs to the devices module; forwarded so
    // `zig build test -Dno-gpu` here means the same thing it does over there.
    const no_gpu = b.option(bool, "no-gpu", "Skip GPU kernel compilation for the device models") orelse false;

    const solvers_dep = b.dependency("solvers", .{
        .target = target,
        .optimize = optimize,
    });
    // src/root.zig and src/Circuit.zig both @import("devices"). Without this
    // the module only ever compiled when a PARENT build supplied it, so
    // `zig build test` standing alone in this directory never built at all.
    const devices_dep = b.dependency("devices", .{
        .target = target,
        .optimize = optimize,
        .@"no-gpu" = no_gpu,
    });

    const mod = b.addModule("analysis", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "solvers", .module = solvers_dep.module("solvers") },
            .{ .name = "devices", .module = devices_dep.module("devices") },
        },
    });
    // DynDevice dlopens generated .so devices.
    mod.linkSystemLibrary("c", .{});

    // Inline tests (root.zig refs every file).
    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit.step);
}
