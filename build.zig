const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // ponytail: default to Zig backend (17s vs 3m13s). -Dno-llvm=false for LLVM (bench/release).
    const no_llvm = b.option(bool, "no-llvm", "Use Zig's native backend instead of LLVM (default: true)") orelse true;

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
    const compute_dep = b.dependency("compute", .{
        .target = target,
        .optimize = optimize,
    });

    // -----------------------------------------------------------------------
    // va_devices: permanently-empty stub. HDL models are declared per-netlist
    // with the `.hdl "path"` directive (compiled + dlopen'd at runtime, see
    // src/vaload.zig). The module stays so netlist.zig's inline-for over its
    // decls and the GPU megakernel builds keep compiling — both loops compile
    // to nothing.
    // -----------------------------------------------------------------------
    const va_root: std.Build.LazyPath = blk: {
        const wf = b.addWriteFiles();
        break :blk wf.add("va_root.zig", "//! no baked VA models; use per-netlist .hdl cards\n");
    };
    const va_mod = b.createModule(.{
        .root_source_file = va_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = devices_dep.module("contract") },
        },
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
                .{ .name = "compute", .module = compute_dep.module("compute") },
                .{ .name = "fastvaf", .module = fastvaf_dep.module("fastvaf") },
                .{ .name = "va_devices", .module = va_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    // Runtime .hdl loading compiles model .so's against these sources.
    // ponytail: baked build root works for repo-run dev; ARPICE_SRC overrides,
    // installable share/ dir when distribution matters.
    const bopts = b.addOptions();
    bopts.addOption([]const u8, "src_root", b.build_root.path orelse ".");
    exe.root_module.addOptions("build_options", bopts);
    if (no_llvm) {
        exe.use_llvm = false;
        exe.use_lld = false;
    }
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
    if (no_llvm) {
        tests.use_llvm = false;
        tests.use_lld = false;
    }
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
    if (no_llvm) {
        bench_runner.use_llvm = false;
        bench_runner.use_lld = false;
    }
    b.installArtifact(bench_runner);

    const run_bench = b.addRunArtifact(bench_runner);
    run_bench.step.dependOn(b.getInstallStep());
    run_bench.stdio = .inherit;
    run_bench.setCwd(b.path("."));
    run_bench.addArgs(&.{ "zig-out/bin/zpicey", "benchmark/fixtures" });
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // -----------------------------------------------------------------------
    // GPU compute: analysis megakernel (modules/devices/src/kernel.zig).
    // With -Dgpu=false (the default) the kernels module holds an empty stub
    // and GPU init just declines at runtime.
    // -----------------------------------------------------------------------
    const GpuBackend = enum { none, nvidia, amd };
    const gpu_backend = b.option(GpuBackend, "gpu", "GPU backend: nvidia (cubin via ptxas), amd (hsaco via llc), or none") orelse .none;
    // Legacy compat: -Dgpu=true maps to nvidia
    const gpu_nv_arch = b.option([]const u8, "gpu-nv-arch", "NVIDIA SM architecture (default sm_89)") orelse "sm_89";
    const gpu_amd_arch = b.option([]const u8, "gpu-amd-arch", "AMD GFX architecture (default gfx1100)") orelse "gfx1100";

    const kernels_wf = b.addWriteFiles();
    var kernels_src: std.ArrayList(u8) = .empty;
    kernels_src.appendSlice(b.allocator, "//! Generated by build.zig — embedded GPU kernel images.\n") catch @panic("OOM");
    switch (gpu_backend) {
        .nvidia => {
            const cubin = buildMegaKernelNvidia(b, gpu_nv_arch, devices_dep, va_mod, optimize);
            _ = kernels_wf.addCopyFile(cubin, "megakernel.bin");
            kernels_src.appendSlice(b.allocator, "pub const megakernel = @embedFile(\"megakernel.bin\");\n") catch @panic("OOM");
        },
        .amd => {
            const hsaco = buildMegaKernelAmd(b, gpu_amd_arch, devices_dep, va_mod, optimize);
            _ = kernels_wf.addCopyFile(hsaco, "megakernel.bin");
            kernels_src.appendSlice(b.allocator, "pub const megakernel = @embedFile(\"megakernel.bin\");\n") catch @panic("OOM");
        },
        .none => {
            kernels_src.appendSlice(b.allocator, "pub const megakernel = \"\";\n") catch @panic("OOM");
        },
    }
    const kernels_root = kernels_wf.add("kernels.zig", kernels_src.items);
    const kernels_mod = b.createModule(.{
        .root_source_file = kernels_root,
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("kernels", kernels_mod);
}

/// Analysis megakernel: whole Newton solve per launch. Same IR→rewrite→llc
/// pipeline as the devices unit, plus the dependency-free gpu_abi module
/// (blob layout shared with the host packer in analysis/problem.zig).
fn buildMegaKernelNvidia(b: *std.Build, nv_arch: []const u8, dev_dep: *std.Build.Dependency, va_mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) std.Build.LazyPath {
    const nvptx_target = b.resolveTargetQuery(.{
        .cpu_arch = .nvptx64,
        .os_tag = .cuda,
        .abi = .none,
    });
    _ = nv_arch;

    const gpu_opt: std.builtin.OptimizeMode = if (optimize == .Debug) .Debug else .ReleaseFast;
    const llc_opt: []const u8 = if (optimize == .Debug) "-O0" else "-O3";
    const ptxas_opt: []const u8 = if (optimize == .Debug) "-O0" else "-O3";

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("modules/analysis/src/gpu_abi.zig"),
        .target = nvptx_target,
        .optimize = gpu_opt,
    });
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("modules/devices/src/kernel.zig"),
        .target = nvptx_target,
        .optimize = gpu_opt,
        .imports = &.{
            .{ .name = "dev_models", .module = dev_dep.module("devices") },
            .{ .name = "va_devices", .module = va_mod },
            .{ .name = "gpu_abi", .module = abi_mod },
        },
    });

    const obj = b.addObject(.{ .name = "megakernel", .root_module = kernel_mod });
    const ll = obj.getEmittedLlvmIr();

    const rewrite_exe = b.addExecutable(.{
        .name = "ptx_rewrite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("modules/compute/tools/ptx_rewrite.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const rewrite = b.addRunArtifact(rewrite_exe);
    rewrite.addFileArg(ll);
    const ll_fixed = rewrite.addOutputFileArg("megakernel.fixed.ll");

    const llc = b.addSystemCommand(&.{ "llc", "-march=nvptx64", "-mcpu=sm_89", llc_opt });
    llc.addFileArg(ll_fixed);
    llc.addArg("-o");
    const ptx = llc.addOutputFileArg("megakernel.ptx");

    const ptxas = b.addSystemCommand(&.{ "ptxas", "-arch=sm_89", ptxas_opt });
    ptxas.addFileArg(ptx);
    ptxas.addArg("-o");
    return ptxas.addOutputFileArg("megakernel.cubin");
}

/// AMD path: Zig → LLVM IR → rewrite → llc -march=amdgcn → HSACO.
/// No ptxas equivalent needed — llc emits a ready-to-load code object.
fn buildMegaKernelAmd(b: *std.Build, amd_arch: []const u8, dev_dep: *std.Build.Dependency, va_mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) std.Build.LazyPath {
    const amdgcn_target = b.resolveTargetQuery(.{
        .cpu_arch = .amdgcn,
        .os_tag = .amdhsa,
        .abi = .none,
    });

    const gpu_opt: std.builtin.OptimizeMode = if (optimize == .Debug) .Debug else .ReleaseFast;

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("modules/analysis/src/gpu_abi.zig"),
        .target = amdgcn_target,
        .optimize = gpu_opt,
    });
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("modules/devices/src/kernel.zig"),
        .target = amdgcn_target,
        .optimize = gpu_opt,
        .imports = &.{
            .{ .name = "dev_models", .module = dev_dep.module("devices") },
            .{ .name = "va_devices", .module = va_mod },
            .{ .name = "gpu_abi", .module = abi_mod },
        },
    });

    // AMDGCN: no alias rewrite needed — LLVM's AMDGPU backend handles
    // kernel exports directly. Zig → obj → ready-to-load code object.
    const obj = b.addObject(.{ .name = "megakernel", .root_module = kernel_mod });
    _ = amd_arch;
    return obj.getEmittedBin();
}


