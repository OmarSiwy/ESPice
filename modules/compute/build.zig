const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("compute", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // std.DynLib needs a real dlopen (ElfDynLib can't resolve libcuda's deps).
    mod.link_libc = true;

    // Host-only unit tests (no GPU required; probe falls back to cpu).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_compute.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compute", .module = mod },
        },
    });
    test_mod.link_libc = true;

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run compute host-side tests").dependOn(&run_tests.step);
}
