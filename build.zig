const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const devices_dep = b.dependency("devices", .{
        .target = target,
        .optimize = optimize,
    });
    const analysis_dep = b.dependency("analysis", .{
        .target = target,
        .optimize = optimize,
    });
    const solvers_dep = b.dependency("solvers", .{
        .target = target,
        .optimize = optimize,
    });
    const fastvaf_dep = b.dependency("fastvaf", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zpicey",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "devices", .module = devices_dep.module("devices") },
                .{ .name = "analysis", .module = analysis_dep.module("analysis") },
                .{ .name = "solvers", .module = solvers_dep.module("solvers") },
                .{ .name = "fastvaf", .module = fastvaf_dep.module("fastvaf") },
            },
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    // Top-level tests: circuit construction (Builder) + every analysis
    // through the public module surface.
    const builder_mod = b.createModule(.{
        .root_source_file = b.path("src/builder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "analysis", .module = analysis_dep.module("analysis") },
            .{ .name = "devices", .module = devices_dep.module("devices") },
        },
    });
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "analysis", .module = analysis_dep.module("analysis") },
            .{ .name = "devices", .module = devices_dep.module("devices") },
            .{ .name = "solvers", .module = solvers_dep.module("solvers") },
            .{ .name = "builder", .module = builder_mod },
        },
    });
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run top-level tests");
    test_step.dependOn(&run_tests.step);

    const run_step = b.step("run", "Run ZPicey");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Benchmark harness
    const bench_runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/src/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(bench_runner);

    const run_bench = b.addRunArtifact(bench_runner);
    run_bench.step.dependOn(b.getInstallStep());
    run_bench.stdio = .inherit;
    run_bench.setCwd(b.path("."));
    run_bench.addArgs(&.{ "zig-out/bin/zpicey", "benchmark/fixtures" });
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}
