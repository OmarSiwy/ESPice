const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const solvers_dep = b.dependency("solvers", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("analysis", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "solvers", .module = solvers_dep.module("solvers") },
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
