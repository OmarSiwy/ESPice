const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bench_runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_runner.use_llvm = false;
    bench_runner.use_lld = false;
    b.installArtifact(bench_runner);
}
