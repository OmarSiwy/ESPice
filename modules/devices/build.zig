const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const contract_mod = b.addModule("contract", .{
        .root_source_file = b.path("src/contract.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Blob ABI shared by host packing (batch.zig, analysis) and the GPU
    // kernel TUs. One module instance everywhere — a second instance rooted
    // at the same file is a compile error in any TU that sees both.
    const gpu_abi_mod = b.addModule("gpu_abi", .{
        .root_source_file = b.path("src/gpu_abi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("devices", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = contract_mod },
            .{ .name = "gpu_abi", .module = gpu_abi_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run device tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

// --- GPU megakernel build API (called from top-level build.zig) ---

pub const GpuKernelInputs = struct {
    b: *std.Build,
    devices_dep: *std.Build.Dependency,
    ptx_rewrite_path: std.Build.LazyPath,
    /// modules/solvers/src/newton_core.zig — dependency-free solver core
    /// shared with the CPU converger; the driver TU imports it as a module.
    newton_core_path: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
};

pub fn buildMegaKernelNvidia(inp: GpuKernelInputs) std.Build.LazyPath {
    const b = inp.b;
    const nvptx_target = b.resolveTargetQuery(.{ .cpu_arch = .nvptx64, .os_tag = .cuda, .abi = .none });
    const gpu_opt: std.builtin.OptimizeMode = if (inp.optimize == .Debug) .Debug else .ReleaseFast;
    const ctx: NvptxTuCtx = .{
        .b = b,
        .rewrite_exe = b.addExecutable(.{
            .name = "ptx_rewrite",
            .root_module = b.createModule(.{
                .root_source_file = inp.ptx_rewrite_path,
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        }),
        .llc_opt = if (inp.optimize == .Debug) "-O0" else "-O3",
        .ptxas_opt = if (inp.optimize == .Debug) "-O0" else "-O3",
    };
    // Same gpu_abi module instance the host devices module imports — the
    // stub TUs see it via dev_models too, and duplicate roots are an error.
    const abi_mod = inp.devices_dep.module("gpu_abi");
    const nvlink = b.addSystemCommand(&.{ "nvlink", "-arch=sm_89" });

    const kernel_mod = b.createModule(.{
        .root_source_file = inp.devices_dep.path("src/kernel.zig"),
        .target = nvptx_target,
        .optimize = gpu_opt,
        .imports = &.{
            .{ .name = "dev_models", .module = inp.devices_dep.module("devices") },
            .{ .name = "gpu_abi", .module = abi_mod },
            .{ .name = "newton_core", .module = b.createModule(.{
                .root_source_file = inp.newton_core_path,
                .target = nvptx_target,
                .optimize = gpu_opt,
            }) },
        },
    });
    nvlink.addFileArg(ctx.add("megakernel", kernel_mod));

    for (listDeviceModels(inp.devices_dep)) |name| {
        const sopts = b.addOptions();
        sopts.addOption([]const u8, "model_name", name);
        const stub_mod = b.createModule(.{
            .root_source_file = inp.devices_dep.path("src/kernel_stub.zig"),
            .target = nvptx_target,
            .optimize = gpu_opt,
            .imports = &.{
                .{ .name = "dev_models", .module = inp.devices_dep.module("devices") },
                .{ .name = "gpu_abi", .module = abi_mod },
                .{ .name = "stub_options", .module = sopts.createModule() },
            },
        });
        nvlink.addFileArg(ctx.add(b.fmt("arpk_{s}", .{name}), stub_mod));
    }
    nvlink.addArg("-o");
    return nvlink.addOutputFileArg("megakernel.cubin");
}

pub fn buildMegaKernelAmd(inp: GpuKernelInputs) std.Build.LazyPath {
    const b = inp.b;
    const amdgcn_target = b.resolveTargetQuery(.{ .cpu_arch = .amdgcn, .os_tag = .amdhsa, .abi = .none });
    const gpu_opt: std.builtin.OptimizeMode = if (inp.optimize == .Debug) .Debug else .ReleaseFast;
    const abi_mod = inp.devices_dep.module("gpu_abi");
    const obj = b.addObject(.{
        .name = "megakernel",
        .root_module = b.createModule(.{
            .root_source_file = inp.devices_dep.path("src/kernel.zig"),
            .target = amdgcn_target,
            .optimize = gpu_opt,
            .imports = &.{
                .{ .name = "dev_models", .module = inp.devices_dep.module("devices") },
                .{ .name = "gpu_abi", .module = abi_mod },
                .{ .name = "newton_core", .module = b.createModule(.{
                    .root_source_file = inp.newton_core_path,
                    .target = amdgcn_target,
                    .optimize = gpu_opt,
                }) },
            },
        }),
    });
    return obj.getEmittedBin();
}

const NvptxTuCtx = struct {
    b: *std.Build,
    rewrite_exe: *std.Build.Step.Compile,
    llc_opt: []const u8,
    ptxas_opt: []const u8,

    fn add(self: *const NvptxTuCtx, name: []const u8, mod: *std.Build.Module) std.Build.LazyPath {
        const b_ = self.b;
        const obj = b_.addObject(.{ .name = name, .root_module = mod });
        const ll = obj.getEmittedLlvmIr();

        const rewrite = b_.addRunArtifact(self.rewrite_exe);
        rewrite.addFileArg(ll);
        const ll_fixed = rewrite.addOutputFileArg(b_.fmt("{s}.fixed.ll", .{name}));

        const llc = b_.addSystemCommand(&.{ "llc", "-march=nvptx64", "-mcpu=sm_89", self.llc_opt });
        llc.addFileArg(ll_fixed);
        llc.addArg("-o");
        const ptx = llc.addOutputFileArg(b_.fmt("{s}.ptx", .{name}));

        // ponytail: per-TU ptxas to avoid 27GB RSS OOM on monolithic input
        const ptxas = b_.addSystemCommand(&.{ "ptxas", "-c", "-arch=sm_89", self.ptxas_opt, "--allow-expensive-optimizations=false" });
        ptxas.addFileArg(ptx);
        ptxas.addArg("-o");
        return ptxas.addOutputFileArg(b_.fmt("{s}.o.cubin", .{name}));
    }
};

fn listDeviceModels(dep: *std.Build.Dependency) []const []const u8 {
    const b = dep.builder;
    const data = dep.builder.build_root.handle.readFileAlloc(b.graph.io, "src/root.zig", b.allocator, .unlimited) catch
        std.debug.panic("cannot read devices/src/root.zig", .{});
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const prefix = "pub const ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        if (std.mem.indexOf(u8, line, "@import") == null) continue;
        var rest = line[prefix.len..];
        if (std.mem.startsWith(u8, rest, "@\"")) {
            rest = rest[2..];
            const q = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            names.append(b.allocator, rest[0..q]) catch @panic("OOM");
            continue;
        }
        const end = std.mem.indexOfAny(u8, rest, " =") orelse continue;
        const name = rest[0..end];
        if (std.mem.eql(u8, name, "contract")) continue;
        names.append(b.allocator, name) catch @panic("OOM");
    }
    return names.items;
}
