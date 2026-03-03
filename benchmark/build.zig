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

    // The runner's own `test` blocks had no step to run them: `zig build bench`
    // builds the binary and every assertion in it was dead weight. The SPICE ->
    // VACASK translator makes that untenable — it is the one part of this
    // directory that can be wrong QUIETLY, in a column that looks like a result.
    const runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Test the benchmark runner").dependOn(&b.addRunArtifact(runner_tests).step);
}
