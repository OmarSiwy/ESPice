const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The device contract lives in this module's source tree; exposed as its
    // own module so codegen consumers (FastVAF) can import it too.
    const contract_mod = b.addModule("contract", .{
        .root_source_file = b.path("src/contract.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("devices", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = contract_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run device tests");
    test_step.dependOn(&run_tests.step);
}
