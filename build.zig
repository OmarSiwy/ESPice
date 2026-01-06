const std = @import("std");
const devices_build = @import("devices");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // ponytail: default to Zig backend (17s vs 3m13s). -Dno-llvm=false for LLVM (bench/release).
    const no_llvm = b.option(bool, "no-llvm", "Use Zig's native backend instead of LLVM (default: true)") orelse true;

    const devices_dep = b.dependency("devices", .{ .target = target, .optimize = optimize });
    const analysis_dep = b.dependency("analysis", .{ .target = target, .optimize = optimize });
    const fastvaf_dep = b.dependency("fastvaf", .{ .target = target, .optimize = optimize });
    const compute_dep = b.dependency("compute", .{ .target = target, .optimize = optimize });

    const bopts = b.addOptions();
    bopts.addOption([]const u8, "src_root", b.build_root.path orelse ".");
    const bopts_mod = bopts.createModule();

    {
        const dm = devices_dep.module("devices");
        const am = analysis_dep.module("analysis");
        dm.addImport("fastvaf", fastvaf_dep.module("fastvaf"));
        dm.addImport("build_options", bopts_mod);
        dm.linkSystemLibrary("c", .{});
        am.addImport("gpu_abi", devices_dep.module("gpu_abi"));
        am.addImport("devices", dm);
    }

    const exe = b.addExecutable(.{
        .name = "zpicey",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "devices", .module = devices_dep.module("devices") },
                .{ .name = "analysis", .module = analysis_dep.module("analysis") },
                .{ .name = "compute", .module = compute_dep.module("compute") },
                .{ .name = "fastvaf", .module = fastvaf_dep.module("fastvaf") },
            },
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.addImport("build_options", bopts_mod);
    if (no_llvm) {
        exe.use_llvm = false;
        exe.use_lld = false;
    }
    b.installArtifact(exe);

    // Tests
    const builder_mod = b.createModule(.{
        .root_source_file = b.path("src/builder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "analysis", .module = analysis_dep.module("analysis") },
            .{ .name = "devices", .module = devices_dep.module("devices") },
        },
    });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "analysis", .module = analysis_dep.module("analysis") },
                .{ .name = "devices", .module = devices_dep.module("devices") },
                .{ .name = "builder", .module = builder_mod },
            },
        }),
    });
    if (no_llvm) {
        tests.use_llvm = false;
        tests.use_lld = false;
    }
    const test_step = b.step("test", "Run top-level tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ZPicey").dependOn(&run_cmd.step);

    // Benchmark
    const bench_dep = b.dependency("benchmark", .{
        .target = target,
        .optimize = optimize,
        .@"no-llvm" = no_llvm,
    });
    b.installArtifact(bench_dep.artifact("bench-runner"));
    const run_bench = b.addRunArtifact(bench_dep.artifact("bench-runner"));
    run_bench.step.dependOn(b.getInstallStep());
    run_bench.stdio = .inherit;
    run_bench.setCwd(b.path("."));
    run_bench.addArgs(&.{ "zig-out/bin/zpicey", "benchmark/fixtures" });
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);

    // GPU kernels
    const GpuBackend = enum { none, nvidia, amd };
    const gpu_backend = b.option(GpuBackend, "gpu", "GPU backend: nvidia, amd, or none") orelse .none;

    const gpu_inp: devices_build.GpuKernelInputs = .{
        .b = b,
        .devices_dep = devices_dep,
        .ptx_rewrite_path = b.path("modules/compute/tools/ptx_rewrite.zig"),
        .optimize = optimize,
    };

    const kernels_wf = b.addWriteFiles();
    var kernels_src: std.ArrayList(u8) = .empty;
    kernels_src.appendSlice(b.allocator, "//! Generated — embedded GPU kernel images.\n") catch @panic("OOM");
    switch (gpu_backend) {
        .nvidia => {
            _ = kernels_wf.addCopyFile(devices_build.buildMegaKernelNvidia(gpu_inp), "megakernel.bin");
            kernels_src.appendSlice(b.allocator, "pub const megakernel = @embedFile(\"megakernel.bin\");\n") catch @panic("OOM");
        },
        .amd => {
            _ = kernels_wf.addCopyFile(devices_build.buildMegaKernelAmd(gpu_inp), "megakernel.bin");
            kernels_src.appendSlice(b.allocator, "pub const megakernel = @embedFile(\"megakernel.bin\");\n") catch @panic("OOM");
        },
        .none => {
            kernels_src.appendSlice(b.allocator, "pub const megakernel = \"\";\n") catch @panic("OOM");
        },
    }
    exe.root_module.addImport("kernels", b.createModule(.{
        .root_source_file = kernels_wf.add("kernels.zig", kernels_src.items),
        .target = target,
        .optimize = optimize,
    }));
}
