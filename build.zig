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
    // Verilog-A / Verilog device models, baked in at BUILD time. The model
    // list lives with the app source: benchmark/va_models.zon (a zon list of .va/
    // .v/.sv paths). vagen runs fastvaf codegen over each and emits one
    // contract-shaped module per device plus va_root.zig re-exporting them.
    // The engine registry and the GPU megakernel both dispatch over this
    // module, so VA devices ride the same comptime path as builtin ones.
    // Editing a model or the list reruns only vagen + this module + link —
    // everything else stays cached. Empty list ⇒ both loops compile to nothing.
    // -----------------------------------------------------------------------
    const va_files = listVaModels(b);
    const va_root: std.Build.LazyPath = blk: {
        if (va_files.len > 0) {
            const vagen_exe = b.addExecutable(.{
                .name = "vagen",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/vagen.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .imports = &.{
                        .{ .name = "fastvaf", .module = fastvaf_dep.module("fastvaf") },
                    },
                }),
            });
            const run = b.addRunArtifact(vagen_exe);
            const out = run.addOutputDirectoryArg("va");
            for (va_files) |file_path| run.addFileArg(file_path);
            break :blk out.path(b, "va_root.zig");
        }
        const wf = b.addWriteFiles();
        break :blk wf.add("va_root.zig", "//! no VA models baked in (benchmark/va_models.zon empty)\n");
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

/// Shared per-TU nvptx pipeline: Zig obj → LLVM IR → ptx_rewrite → llc →
/// ptxas -c (relocatable cubin). Result feeds nvlink.
const NvptxTuCtx = struct {
    b: *std.Build,
    rewrite_exe: *std.Build.Step.Compile,
    llc_opt: []const u8,
    ptxas_opt: []const u8,

    fn add(self: *const NvptxTuCtx, name: []const u8, mod: *std.Build.Module) std.Build.LazyPath {
        const b = self.b;
        const obj = b.addObject(.{ .name = name, .root_module = mod });
        const ll = obj.getEmittedLlvmIr();

        const rewrite = b.addRunArtifact(self.rewrite_exe);
        rewrite.addFileArg(ll);
        const ll_fixed = rewrite.addOutputFileArg(b.fmt("{s}.fixed.ll", .{name}));

        const llc = b.addSystemCommand(&.{ "llc", "-march=nvptx64", "-mcpu=sm_89", self.llc_opt });
        llc.addFileArg(ll_fixed);
        llc.addArg("-o");
        const ptx = llc.addOutputFileArg(b.fmt("{s}.ptx", .{name}));

        // ptxas cost is superlinear per function and blows up on monolithic
        // input (27 GB RSS on the all-devices megablob, OOM-killed 3× on
        // 2026-07-10). Relocatable per-TU compiles keep every ptxas run
        // small and parallel; --allow-expensive-optimizations=false caps the
        // "maximum available resources" behavior it defaults to at >=O2.
        const ptxas = b.addSystemCommand(&.{ "ptxas", "-c", "-arch=sm_89", self.ptxas_opt, "--allow-expensive-optimizations=false" });
        ptxas.addFileArg(ptx);
        ptxas.addArg("-o");
        return ptxas.addOutputFileArg(b.fmt("{s}.o.cubin", .{name}));
    }
};

/// Builtin device model names, parsed at configure time from the decl list
/// in devices/root.zig (`pub const <name> = @import(...)`) — same
/// configure-time file-read pattern as listVaModels. Stubs self-filter via
/// isDevice(), so over-matching here is harmless; missing a device would
/// surface as an unresolved arp_eb_* symbol at nvlink time (loud).
fn listDeviceModels(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    const data = b.build_root.handle.readFileAlloc(io, "modules/devices/src/root.zig", b.allocator, .unlimited) catch
        std.debug.panic("cannot read modules/devices/src/root.zig", .{});
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const prefix = "pub const ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        if (std.mem.indexOf(u8, line, "@import") == null) continue;
        var rest = line[prefix.len..];
        // Quoted identifiers: pub const @"switch" = ...
        if (std.mem.startsWith(u8, rest, "@\"")) {
            rest = rest[2..];
            const q = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            names.append(b.allocator, rest[0..q]) catch @panic("OOM");
            continue;
        }
        const end = std.mem.indexOfAny(u8, rest, " =") orelse continue;
        const name = rest[0..end];
        if (std.mem.eql(u8, name, "contract")) continue; // module re-export, not a device
        names.append(b.allocator, name) catch @panic("OOM");
    }
    return names.items;
}

/// Analysis megakernel, NVIDIA: split compilation. The driver TU
/// (kernel.zig — entries, Newton/GMRES, dispatch-by-symbol) and one stub TU
/// per device model (kernel_stub.zig — exported evalBatch/limitBatch
/// wrappers) each run the IR→rewrite→llc→ptxas -c pipeline independently,
/// then nvlink resolves the arp_eb_*/arp_lb_* calls into one cubin. Same
/// single cooperative launch as before; ptxas just never sees all models in
/// one translation unit.
fn buildMegaKernelNvidia(b: *std.Build, nv_arch: []const u8, dev_dep: *std.Build.Dependency, va_mod: *std.Build.Module, optimize: std.builtin.OptimizeMode) std.Build.LazyPath {
    const nvptx_target = b.resolveTargetQuery(.{
        .cpu_arch = .nvptx64,
        .os_tag = .cuda,
        .abi = .none,
    });
    _ = nv_arch;

    const gpu_opt: std.builtin.OptimizeMode = if (optimize == .Debug) .Debug else .ReleaseFast;
    const ctx: NvptxTuCtx = .{
        .b = b,
        .rewrite_exe = b.addExecutable(.{
            .name = "ptx_rewrite",
            .root_module = b.createModule(.{
                .root_source_file = b.path("modules/compute/tools/ptx_rewrite.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        }),
        .llc_opt = if (optimize == .Debug) "-O0" else "-O3",
        .ptxas_opt = if (optimize == .Debug) "-O0" else "-O3",
    };

    const abi_mod = b.createModule(.{
        .root_source_file = b.path("modules/analysis/src/gpu_abi.zig"),
        .target = nvptx_target,
        .optimize = gpu_opt,
    });

    const nvlink = b.addSystemCommand(&.{ "nvlink", "-arch=sm_89" });

    // Driver TU: entries + solver skeleton, models referenced only for
    // decl names / kindId hashes (no physics instantiated).
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
    nvlink.addFileArg(ctx.add("megakernel", kernel_mod));

    // One stub TU per builtin model, plus one ("") covering all VA models.
    var stub_names: std.ArrayList([]const u8) = .empty;
    stub_names.appendSlice(b.allocator, listDeviceModels(b)) catch @panic("OOM");
    stub_names.append(b.allocator, "") catch @panic("OOM");
    for (stub_names.items) |name| {
        const sopts = b.addOptions();
        sopts.addOption([]const u8, "model_name", name);
        const stub_mod = b.createModule(.{
            .root_source_file = b.path("modules/devices/src/kernel_stub.zig"),
            .target = nvptx_target,
            .optimize = gpu_opt,
            .imports = &.{
                .{ .name = "dev_models", .module = dev_dep.module("devices") },
                .{ .name = "va_devices", .module = va_mod },
                .{ .name = "gpu_abi", .module = abi_mod },
                .{ .name = "stub_options", .module = sopts.createModule() },
            },
        });
        const tu_name = if (name.len == 0) "arpk_va" else b.fmt("arpk_{s}", .{name});
        nvlink.addFileArg(ctx.add(tu_name, stub_mod));
    }

    nvlink.addArg("-o");
    return nvlink.addOutputFileArg("megakernel.cubin");
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

/// Baked va/v model paths from benchmark/va_models.zon (repo-relative or absolute).
/// Missing manifest == empty list.
fn listVaModels(b: *std.Build) []const std.Build.LazyPath {
    const io = b.graph.io;
    const data = b.build_root.handle.readFileAlloc(io, "benchmark/va_models.zon", b.allocator, .unlimited) catch
        return &.{};
    const src = b.allocator.dupeZ(u8, data) catch @panic("OOM");
    const files = std.zon.parse.fromSliceAlloc([]const []const u8, b.allocator, src, null, .{}) catch
        std.debug.panic("benchmark/va_models.zon: expected a zon list of .va/.v/.sv paths", .{});
    var paths: std.ArrayList(std.Build.LazyPath) = .empty;
    for (files) |p| {
        const lp: std.Build.LazyPath = if (std.fs.path.isAbsolute(p)) .{ .cwd_relative = p } else b.path(p);
        paths.append(b.allocator, lp) catch @panic("OOM");
    }
    return paths.items;
}

