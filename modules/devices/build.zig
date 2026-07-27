const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Escape hatch only. GPU kernels are ON by default and auto-detected — a
    // machine with no GPU emits nothing and stays green without this flag.
    const no_gpu = b.option(bool, "no-gpu", "Skip GPU kernel compilation for the device models") orelse false;
    // Each model's generated Zig is compiled into the app anyway, so this is
    // duplicated work — what it buys is ATTRIBUTION: `fastvaf --check` fails at
    // the .va that produced bad code, instead of surfacing as an error inside a
    // generated file in the build cache with nothing naming the source.
    const check_va = b.option(bool, "check-va", "Type-check each generated device at its .va (default: on)") orelse true;

    const contract_mod = b.addModule("contract", .{
        .root_source_file = b.path("src/contract.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fastvaf = b.dependency("fastvaf", .{});
    // Second instance, ReleaseFast, for the build-host generator ONLY. The CLI
    // runs 38 times per build over up to 614 K lines of Verilog-A; built Debug
    // that is ~10x slower than it needs to be (FastVAF PERF.md, "Results").
    // The `fastvaf` MODULE above stays on the consumer's optimize mode — this
    // instance exists to make a build tool fast, not to change what ships.
    const fastvaf_host = b.dependency("fastvaf", .{ .optimize = .ReleaseFast });
    const gompute = b.dependency("gompute", .{});

    // Auto-discover active models: every models/NAME.{va,v,sv,vhd,vhdl}
    // (vendor/ is staged and skipped — it is a subdir, not a file, so the file
    // filter drops it). No hand-maintained list; drop a source in and it is
    // built, whichever HDL it is written in.
    const models = discoverModels(b);

    // Build-host generator: FastVAF's own CLI (.va -> MIR -> contract-shaped
    // Zig). This used to be tools/compile_va.zig, a wrapper that re-implemented
    // read-file / compile / generate / write-file and, crucially, had no way to
    // render a diagnostic — a rejected model surfaced here as a bare
    // `error.CompileFailed`. The CLI renders the real thing, snippets and all,
    // so a bad `models/*.va` now fails the build with the source line that
    // caused it. `--expect-module` and the @compileError gate moved with it.
    const va_exe = fastvaf_host.artifact("fastvaf");

    // FastVF's CLI is the same contract at the other end of the HDL split:
    // Verilog / SystemVerilog / VHDL -> verilator (+ sv2v / ghdl) -> the same
    // contract-shaped Zig. Resolved lazily — it shells out to `verilator`, and
    // a tree with no digital models should not need it installed to build.
    const v_exe = if (hasDigitalModel(models)) b.dependency("fastvf", .{}).artifact("fastvf") else null;

    // Aggregate `models` module: one codegen'd device module per import, plus a
    // generated root that re-exports each. root.zig reflects over it.
    var agg_src: std.ArrayList(u8) = .empty;
    agg_src.appendSlice(b.allocator, "//! Generated — build-time HDL device models.\n") catch @panic("OOM");

    const dev_mods = b.allocator.alloc(*std.Build.Module, models.len) catch @panic("OOM");
    for (models, 0..) |m, i| {
        const run = b.addRunArtifact(if (m.hdl == .verilog_a) va_exe else v_exe.?);
        // The catalog keys devices by FILE stem while the generated type name
        // comes from the MODULE name; both CLIs fail on a mismatch.
        run.addArg(b.fmt("--expect-module={s}", .{m.name}));
        if (m.hdl == .verilog_a) {
            run.addArgs(&.{ "--emit-zig", "--color=never" });
            if (check_va) {
                run.addArg("--check");
                run.addArg("--contract");
                run.addFileArg(b.path("src/contract.zig"));
            }
        }
        run.addArg("-o");
        const gen_zig = run.addOutputFileArg(b.fmt("{s}.zig", .{m.name}));
        run.addFileArg(b.path(b.fmt("models/{s}", .{m.file})));

        const dev_mod = b.createModule(.{
            .root_source_file = gen_zig,
            .target = target,
            .optimize = optimize,
        });
        dev_mod.addImport("contract", contract_mod);
        dev_mods[i] = dev_mod;

        agg_src.appendSlice(b.allocator, b.fmt("pub const {s} = @import(\"{s}\");\n", .{ m.name, m.name })) catch @panic("OOM");
    }

    const agg_wf = b.addWriteFiles();
    const models_mod = b.createModule(.{
        .root_source_file = agg_wf.add("models.zig", agg_src.items),
        .target = target,
        .optimize = optimize,
    });
    for (models, dev_mods) |m, dev_mod| models_mod.addImport(m.name, dev_mod);

    const mod = b.addModule("devices", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = contract_mod },
            .{ .name = "models", .module = models_mod },
            .{ .name = "fastvaf", .module = fastvaf.module("fastvaf") },
            .{ .name = "gompute", .module = gompute.module("gompute") },
        },
    });

    // GPU side-by-side: the SAME generated devices, recompiled for the GPU as one
    // raw kernel each (src/kernels.zig loops the catalog). Wired into the gompute
    // module every consumer already imports, so nothing opts in — building the
    // devices module builds the kernels.
    if (!no_gpu) emitDeviceKernels(b, gompute, models_mod, contract_mod, target, optimize);

    // Codegen is not a separate step: anything that builds the devices module
    // pulls every models/*.va through FastVAF. The default step compiles the
    // whole set so a standalone `zig build` here does what the app does.
    const tests = b.addTest(.{ .root_module = mod });
    b.getInstallStep().dependOn(&tests.step);
    const test_step = b.step("test", "Run device tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// One discovered model source. `name` is the file stem — the key the device
/// catalog is formed from — and `hdl` picks which generator CLI compiles it.
const Model = struct {
    name: []const u8,
    file: []const u8,
    hdl: enum { verilog_a, digital },
};

/// Extension -> generator. Verilog-A goes to FastVAF; the digital HDLs all go
/// to FastVF, which internally routes .sv through sv2v and .vhd through ghdl
/// before verilator sees them.
const hdl_by_ext = [_]struct { ext: []const u8, hdl: @FieldType(Model, "hdl") }{
    .{ .ext = ".va", .hdl = .verilog_a },
    .{ .ext = ".v", .hdl = .digital },
    .{ .ext = ".sv", .hdl = .digital },
    .{ .ext = ".vhd", .hdl = .digital },
    .{ .ext = ".vhdl", .hdl = .digital },
};

/// Configure-time glob of models/* -> sorted model list, stable across builds.
fn discoverModels(b: *std.Build) []const Model {
    const io = b.graph.io;
    var out: std.ArrayList(Model) = .empty;
    var dir = b.build_root.handle.openDir(io, "models", .{ .iterate = true }) catch @panic("devices: models/ missing");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("devices: models/ iterate failed")) |e| {
        if (e.kind != .file) continue;
        const m = matchExt(e.name) orelse continue;
        out.append(b.allocator, .{
            .name = b.dupe(e.name[0 .. e.name.len - m.ext.len]),
            .file = b.dupe(e.name),
            .hdl = m.hdl,
        }) catch @panic("OOM");
    }
    std.mem.sort(Model, out.items, {}, struct {
        fn lt(_: void, a: Model, c: Model) bool {
            return std.mem.lessThan(u8, a.name, c.name);
        }
    }.lt);
    // Two sources with the same stem emit the same catalog key, and the
    // aggregate would silently keep whichever import landed last. Sorted, so a
    // duplicate is adjacent.
    if (out.items.len > 1) {
        for (out.items[1..], out.items[0 .. out.items.len - 1]) |cur, prev| {
            if (std.mem.eql(u8, cur.name, prev.name))
                std.debug.panic("devices: models/{s} and models/{s} share the stem '{s}' — " ++
                    "the device catalog keys on the stem, so one would shadow the other", .{ prev.file, cur.file, cur.name });
        }
    }
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// No entry in `hdl_by_ext` is a suffix of another, so first match is the match.
fn matchExt(file_name: []const u8) ?@TypeOf(hdl_by_ext[0]) {
    for (hdl_by_ext) |cand| {
        if (std.mem.endsWith(u8, file_name, cand.ext)) return cand;
    }
    return null;
}

fn hasDigitalModel(models: []const Model) bool {
    for (models) |m| {
        if (m.hdl == .digital) return true;
    }
    return false;
}

// ===========================================================================
// GPU kernels for the generated devices.
//
// This mirrors gompute's own `emitKernels` and exists only because that helper
// takes a kernels root with no way to add imports — ours needs `models` and
// `contract` (src/kernels.zig -> engine.zig -> contract). Everything else is the
// same pipeline: device IR -> gompute's rewrite tool -> PTX / HSACO, published as
// the `gompute_kernels` module gompute's host loader reads.
// ===========================================================================

fn emitDeviceKernels(
    b: *std.Build,
    gompute: *std.Build.Dependency,
    models_mod: *std.Build.Module,
    contract_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // CUDA/HIP drivers do not exist on wasm; skip both backends there.
    const cuda_cpu = if (target.result.cpu.arch.isWasm()) null else detectGpu(b, .cuda);
    const hip_cpu = if (target.result.cpu.arch.isWasm()) null else detectGpu(b, .hip);

    // Debug device code drags std.builtin panic globals in and LLVM's NVPTX
    // backend then emits invalid PTX types for them. ReleaseFast, NOT
    // ReleaseSafe: ReleaseSafe keeps the panic machinery and merely optimizes
    // it, and on these single-huge-eval-function models something in LLVM goes
    // superlinear on the safety-check CFG — measured 443s vs 13.6s for
    // hisimhv_va. gompute's deviceOptimize made the same move in 1.0.0.
    const dev_opt: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;

    const tool = b.addExecutable(.{
        .name = "gompute-kernel-ir-tool",
        .root_module = b.createModule(.{
            .root_source_file = gompute.path("tools/kernel_ir_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    var cuda_ptx: ?std.Build.LazyPath = null;
    var hip_hsaco: ?std.Build.LazyPath = null;
    var hip_names: ?std.Build.LazyPath = null;

    if (cuda_cpu) |cpu| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = "nvptx64-cuda", .cpu_features = cpu }) catch
            @panic("devices: invalid CUDA target CPU");
        const obj = b.addObject(.{
            .name = "arp_device_kernels_cuda",
            .root_module = deviceKernelsModule(b, gompute, models_mod, contract_mod, b.resolveTargetQuery(query), dev_opt),
        });
        const rewrite = b.addRunArtifact(tool);
        rewrite.addFileArg(obj.getEmittedLlvmIr());
        const fixed_ir = rewrite.addOutputFileArg("arp_device_kernels_cuda.ll");
        _ = rewrite.addOutputFileArg("arp_device_kernels_cuda_names.zig");

        // `zig cc` assembles the PTX — no CUDA toolkit needed on the build host.
        const assemble = b.addSystemCommand(&.{
            b.graph.zig_exe, "cc",
            "-target",       "nvptx64-cuda",
            b.fmt("-mcpu={s}", .{cpu}),
            "-S",
            "-g0", // nvptx rejects DWARF; keeps stderr clean
            "-Wno-unused-command-line-argument",
        });
        assemble.addFileArg(fixed_ir);
        cuda_ptx = assemble.addPrefixedOutputFileArg("-o", "arp_devices.ptx");
    }

    if (hip_cpu) |cpu| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = "amdgcn-amdhsa", .cpu_features = cpu }) catch
            @panic("devices: invalid HIP target CPU");
        const obj = b.addObject(.{
            .name = "arp_device_kernels_hip",
            .root_module = deviceKernelsModule(b, gompute, models_mod, contract_mod, b.resolveTargetQuery(query), dev_opt),
        });
        const names_run = b.addRunArtifact(tool);
        names_run.addFileArg(obj.getEmittedLlvmIr());
        _ = names_run.addOutputFileArg("arp_device_kernels_hip.ll");
        hip_names = names_run.addOutputFileArg("arp_device_kernels_hip_names.zig");

        const link = b.addSystemCommand(&.{ b.graph.zig_exe, "ld.lld", "-shared" });
        link.addFileArg(obj.getEmittedBin());
        hip_hsaco = link.addPrefixedOutputFileArg("-o", "arp_devices.hsaco");
    }

    // Exactly the module shape gompute's host loader imports (host/raw.zig).
    const write = b.addWriteFiles();
    const artifacts_mod = b.createModule(.{ .root_source_file = write.add("gompute_kernels.zig", b.fmt(
        \\//! Generated — GPU images for the build-time Verilog-A devices.
        \\pub const has_cuda = {};
        \\pub const has_hip = {};
        \\pub const cuda: []const u8 = if (has_cuda) @embedFile("cuda_blob") else "";
        \\pub const hip: []const u8 = if (has_hip) @embedFile("hip_blob") else "";
        \\pub const hip_names = if (has_hip) @import("hip_names") else struct {{
        \\    pub fn resolve(comptime _: []const u8) [:0]const u8 {{
        \\        @compileError("HIP artifacts were not emitted");
        \\    }}
        \\}};
        \\
    , .{ cuda_cpu != null, hip_cpu != null })) });
    if (cuda_ptx) |p| artifacts_mod.addAnonymousImport("cuda_blob", .{ .root_source_file = p });
    if (hip_hsaco) |p| artifacts_mod.addAnonymousImport("hip_blob", .{ .root_source_file = p });
    if (hip_names) |p| artifacts_mod.addAnonymousImport("hip_names", .{ .root_source_file = p });

    // One import onto the gompute module every consumer already sees: the app,
    // the devices tests and the runtime `.so` all resolve the same images.
    gompute.module("gompute").addImport("gompute_kernels", artifacts_mod);
}

/// src/kernels.zig compiled for a GPU target: same generated devices, same
/// engine core, gompute's device shim in place of the host one.
fn deviceKernelsModule(
    b: *std.Build,
    gompute: *std.Build.Dependency,
    models_mod: *std.Build.Module,
    contract_mod: *std.Build.Module,
    gpu_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/kernels.zig"),
        .target = gpu_target,
        .optimize = optimize,
        // Debug info in device IR makes the PTX claim DWARF it lacks; the CUDA
        // driver then rejects the module (error 218).
        .strip = true,
        .imports = &.{
            .{ .name = "gompute", .module = gompute.module("gompute_device") },
            .{ .name = "models", .module = models_mod },
            .{ .name = "contract", .module = contract_mod },
        },
    });
}

/// Probe the build machine for a GPU arch. nvidia-smi ships with every NVIDIA
/// driver and amdgpu-arch with ROCm, so these are the lightest reliable probes
/// (same ones gompute uses). null ⇒ that backend emits nothing.
fn detectGpu(b: *std.Build, comptime kind: enum { cuda, hip }) ?[]const u8 {
    var code: u8 = undefined;
    switch (kind) {
        .cuda => {
            const out = b.runAllowFail(
                &.{ "nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader" },
                &code,
                .ignore,
            ) catch return null;
            const line = std.mem.trim(u8, std.mem.sliceTo(out, '\n'), " \r\t");
            if (line.len == 0) return null;
            var buf: std.ArrayList(u8) = .empty;
            buf.appendSlice(b.allocator, "sm_") catch @panic("OOM");
            for (line) |c| if (c != '.') buf.append(b.allocator, c) catch @panic("OOM");
            return buf.items;
        },
        .hip => {
            for ([_][]const []const u8{ &.{"amdgpu-arch"}, &.{"rocm_agent_enumerator"} }) |argv| {
                const out = b.runAllowFail(argv, &code, .ignore) catch continue;
                var it = std.mem.tokenizeAny(u8, out, " \r\n\t");
                // gfx000 is the CPU agent rocm_agent_enumerator reports.
                while (it.next()) |arch| {
                    if (std.mem.startsWith(u8, arch, "gfx") and !std.mem.eql(u8, arch, "gfx000")) return arch;
                }
            }
            return null;
        },
    }
}
