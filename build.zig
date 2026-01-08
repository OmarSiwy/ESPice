const std = @import("std");

/// Every source tree lives under `src_new/` and is built from THIS file — the
/// per-directory `build.zig` / `build.zig.zon` pairs are gone. The import names
/// (`devices`, `analysis`, `solvers`, `fastvaf`, `fastvf`, `contract`, `models`)
/// are unchanged, so no source file knows the difference.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // ponytail: default to Zig backend (17s vs 3m13s). -Dno-llvm=false for LLVM (bench/release).
    const no_llvm = b.option(bool, "no-llvm", "Use Zig's native backend instead of LLVM (default: true)") orelse true;
    // Escape hatch only. GPU kernels are ON by default and auto-detected — a
    // machine with no GPU emits nothing and stays green without this flag.
    const no_gpu = b.option(bool, "no-gpu", "Skip GPU kernel compilation for the device models") orelse false;
    // Each model's generated Zig is compiled into the app anyway, so this is
    // duplicated work — what it buys is ATTRIBUTION: `fastvaf --check` fails at
    // the .va that produced bad code, instead of surfacing as an error inside a
    // generated file in the build cache with nothing naming the source.
    const check_va = b.option(bool, "check-va", "Type-check each generated device at its .va (default: on)") orelse true;

    const gompute = b.dependency("gompute", .{});

    const bopts = b.addOptions();
    bopts.addOption([]const u8, "src_root", b.build_root.path orelse ".");
    const bopts_mod = bopts.createModule();

    // =======================================================================
    // Leaf modules
    // =======================================================================

    const solvers_mod = b.createModule(.{
        .root_source_file = b.path("src_new/solvers/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const contract_mod = b.createModule(.{
        .root_source_file = b.path("src_new/devices/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fastvaf_mod = b.createModule(.{
        .root_source_file = b.path("src_new/FastVAF/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fastvf_mod = b.createModule(.{
        .root_source_file = b.path("src_new/FastVF/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =======================================================================
    // Build-time HDL generators
    //
    // Host-targeted, and ReleaseFast for FastVAF: its CLI runs once per model
    // over up to 614 K lines of Verilog-A, and Debug is ~10x slower than it
    // needs to be (FastVAF PERF.md, "Results"). The MODULES above stay on the
    // consumer's target/optimize — these instances exist to make a build tool
    // fast, not to change what ships. Neither is installed and neither is on the
    // default step: an executable nothing references is never built, which is
    // what keeps a tree with no digital models from needing verilator.
    // =======================================================================

    // .va -> MIR -> contract-shaped Zig. main.zig reaches the engine with a
    // relative `@import("root.zig")`, so no module wiring is needed here.
    const va_exe = b.addExecutable(.{
        .name = "fastvaf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src_new/FastVAF/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });

    // The same contract at the other end of the HDL split: Verilog /
    // SystemVerilog / VHDL -> verilator (+ sv2v / ghdl) -> contract-shaped Zig.
    const vf_cli_mod = b.createModule(.{
        .root_source_file = b.path("src_new/FastVF/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    vf_cli_mod.addImport("zvf", b.createModule(.{
        .root_source_file = b.path("src_new/FastVF/root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    const vf_exe = b.addExecutable(.{ .name = "fastvf", .root_module = vf_cli_mod });

    // =======================================================================
    // Devices: every src_new/devices/models/* compiled to Zig at build time
    // =======================================================================

    // Auto-discover active models: every models/NAME.{va,v,sv,vhd,vhdl}
    // (vendor/ is staged and skipped — it is a subdir, not a file, so the file
    // filter drops it). No hand-maintained list; drop a source in and it is
    // built, whichever HDL it is written in.
    const models = discoverModels(b);

    // Aggregate `models` module: one codegen'd device module per import, plus a
    // generated root that re-exports each. devices/root.zig reflects over it.
    var agg_src: std.ArrayList(u8) = .empty;
    agg_src.appendSlice(b.allocator, "//! Generated — build-time HDL device models.\n") catch @panic("OOM");

    const dev_mods = b.allocator.alloc(*std.Build.Module, models.len) catch @panic("OOM");
    for (models, 0..) |m, i| {
        const run = b.addRunArtifact(if (m.hdl == .verilog_a) va_exe else vf_exe);
        // The catalog keys devices by FILE stem while the generated type name
        // comes from the MODULE name; both CLIs fail on a mismatch.
        run.addArg(b.fmt("--expect-module={s}", .{m.name}));
        if (m.hdl == .verilog_a) {
            run.addArgs(&.{ "--emit-zig", "--color=never" });
            if (check_va) {
                run.addArg("--check");
                run.addArg("--contract");
                run.addFileArg(b.path("src_new/devices/contract.zig"));
            }
        }
        run.addArg("-o");
        const gen_zig = run.addOutputFileArg(b.fmt("{s}.zig", .{m.name}));
        run.addFileArg(b.path(b.fmt("src_new/devices/models/{s}", .{m.file})));

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

    const devices_mod = b.createModule(.{
        .root_source_file = b.path("src_new/devices/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = contract_mod },
            .{ .name = "models", .module = models_mod },
            .{ .name = "fastvaf", .module = fastvaf_mod },
            .{ .name = "gompute", .module = gompute.module("gompute") },
        },
    });
    // DynDevice dlopens generated .so devices.
    devices_mod.linkSystemLibrary("c", .{});

    // GPU side-by-side: the SAME generated devices, recompiled for the GPU as one
    // raw kernel each (devices/kernels.zig loops the catalog). Wired into the
    // gompute module every consumer already imports, so nothing opts in.
    if (!no_gpu) emitDeviceKernels(b, gompute, models_mod, contract_mod, target, optimize);

    // =======================================================================
    // Analysis
    // =======================================================================

    const analysis_mod = b.createModule(.{
        .root_source_file = b.path("src_new/analysis/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "solvers", .module = solvers_mod },
            .{ .name = "devices", .module = devices_mod },
        },
    });
    analysis_mod.linkSystemLibrary("c", .{});

    // =======================================================================
    // The app
    // =======================================================================

    const exe = b.addExecutable(.{
        .name = "zpicey",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src_new/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "devices", .module = devices_mod },
                .{ .name = "analysis", .module = analysis_mod },
                .{ .name = "fastvaf", .module = fastvaf_mod },
                .{ .name = "fastvf", .module = fastvf_mod },
                .{ .name = "build_options", .module = bopts_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    if (no_llvm) {
        exe.use_llvm = false;
        exe.use_lld = false;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ZPicey").dependOn(&run_cmd.step);

    // The two generators, on demand — these were `run` and `emit` inside their
    // own packages; `run` belongs to the app now.
    const run_va = b.addRunArtifact(va_exe);
    if (b.args) |args| run_va.addArgs(args);
    b.step("fastvaf", "Run the fastvaf CLI").dependOn(&run_va.step);
    const run_vf = b.addRunArtifact(vf_exe);
    if (b.args) |args| run_vf.addArgs(args);
    b.step("fastvf", "Print the generated device for a Verilog file").dependOn(&run_vf.step);

    // =======================================================================
    // Tests
    //
    // One test root PER MODULE, because `zig test` collects tests only from the
    // root module's own file set. A `_ = @import("analysis")` inside
    // tests/test_all.zig crosses a MODULE boundary, so those tests are silently
    // dropped — measured: importing all five modules there added ZERO tests,
    // which is exactly how a green suite hides a whole engine going untested.
    //
    // WITHIN a module, one root is enough: every root.zig ends in a
    // `test { _ = <each sibling>; }` aggregator, so the module root pulls its
    // files in. That is what collapses FastVAF's 17 per-file test binaries into
    // one, and the tree from 22 test executables to 6.
    // =======================================================================

    const test_step = b.step("test", "Run every test suite");

    const builder_mod = b.createModule(.{
        .root_source_file = b.path("src_new/builder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "analysis", .module = analysis_mod },
            .{ .name = "devices", .module = devices_mod },
        },
    });
    // tests/FastVF/test_all.zig wants these two under their own names.
    const vf_conf_opts = b.addOptions();
    vf_conf_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    vf_conf_opts.addOption([]const u8, "contract_path", b.pathFromRoot("src_new/devices/contract.zig"));

    const app_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "analysis", .module = analysis_mod },
            .{ .name = "devices", .module = devices_mod },
            .{ .name = "builder", .module = builder_mod },
            // tests/FastVF/test_all.zig is a PATH import from test_all.zig, so it
            // is part of this root module and its one test does run here.
            .{ .name = "zvf", .module = fastvf_mod },
        },
    });
    app_test_mod.addOptions("conf_opts", vf_conf_opts);

    const app_tests = b.addTest(.{ .root_module = app_test_mod });
    if (no_llvm) {
        app_tests.use_llvm = false;
        app_tests.use_lld = false;
    }
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    // The five module suites, each as its own test root.
    for ([_]struct { name: []const u8, desc: []const u8, mod: *std.Build.Module }{
        .{ .name = "test-solvers", .desc = "Run solver tests", .mod = solvers_mod },
        .{ .name = "test-analysis", .desc = "Run analysis tests", .mod = analysis_mod },
        // Building this at all pulls every models/* through FastVAF.
        .{ .name = "test-devices", .desc = "Run device tests", .mod = devices_mod },
        .{ .name = "test-fastvaf", .desc = "Run the FastVAF engine tests", .mod = fastvaf_mod },
        .{ .name = "test-fastvf", .desc = "Run FastVF unit tests", .mod = fastvf_mod },
    }) |suite| {
        const run = b.addRunArtifact(b.addTest(.{ .root_module = suite.mod }));
        b.step(suite.name, suite.desc).dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // FastVF's CLI carries its own tests and is not reachable from fastvf_mod.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vf_cli_mod })).step);

    // =======================================================================
    // Conformance oracles
    // =======================================================================

    // FastVAF's two oracles stay executables rather than moving into
    // tests/test_all.zig: neither declares a `test` block — both are `pub fn
    // main` on purpose, so a failing fixture prints the whole failing set in one
    // run instead of aborting at the first assert. (FastVF's conformance IS a
    // test, so it went into test_all.zig with the rest.)

    // tests/FastVAF/fixtures/**/*.va compiled through compileSource and checked
    // against the sibling `.expected-error.txt`. An EXECUTABLE, not a `test`, on
    // purpose — a failing fixture must print the whole failing set in one run,
    // not abort at the first assert. Also wired into `test`.
    const va_conf_opts = b.addOptions();
    va_conf_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/FastVAF/fixtures"));
    const va_conf_mod = b.createModule(.{
        .root_source_file = b.path("tests/FastVAF/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fastvaf", .module = fastvaf_mod }},
    });
    va_conf_mod.addOptions("conformance_options", va_conf_opts);
    const run_va_conf = b.addRunArtifact(b.addExecutable(.{
        .name = "fastvaf-conformance",
        .root_module = va_conf_mod,
    }));
    b.step("conformance", "Run the Verilog-A fixture conformance suite").dependOn(&run_va_conf.step);
    test_step.dependOn(&run_va_conf.step);

    // The SEMANTIC oracle. Every FastVAF tests/fixtures/exhaustive/*.va becomes a
    // native testbench binary (ch9 display tasks on + the `//!` operating points)
    // whose transcript is compared with the committed `.expected.txt`.
    //
    // NOT in `test`: it spawns a `zig build-exe` per fixture, seconds rather than
    // milliseconds. Run it explicitly:
    //
    //   zig build exhaustive              # check every transcript
    //   zig build exhaustive -- 04_       # only the fixtures matching `04_`
    //   zig build exhaustive -- --bless   # (re)write them, then READ the diff
    const contract_path = b.option(
        []const u8,
        "contract",
        "Root of the `contract` module the generated devices import",
    ) orelse b.pathFromRoot("src_new/devices/contract.zig");
    const exh_opts = b.addOptions();
    exh_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/FastVAF/fixtures/exhaustive"));
    exh_opts.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/fastvaf-tb"));
    exh_opts.addOption([]const u8, "contract", contract_path);
    exh_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const exh_mod = b.createModule(.{
        .root_source_file = b.path("tests/FastVAF/exhaustive.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fastvaf", .module = fastvaf_mod }},
    });
    exh_mod.addOptions("exhaustive_options", exh_opts);
    const run_exh = b.addRunArtifact(b.addExecutable(.{
        .name = "fastvaf-exhaustive",
        .root_module = exh_mod,
    }));
    if (b.args) |a| run_exh.addArgs(a);
    b.step("exhaustive", "Run the Verilog-A testbench transcripts").dependOn(&run_exh.step);

    // =======================================================================
    // Benchmark (still its own package — it is fixtures and a runner, not a
    // source tree that belongs under src_new/)
    // =======================================================================

    const bench_dep = b.dependency("benchmark", .{
        .target = target,
        .optimize = optimize,
        .@"no-llvm" = no_llvm,
    });
    const run_bench = b.addRunArtifact(bench_dep.artifact("bench-runner"));
    run_bench.step.dependOn(b.getInstallStep());
    // Install lazily — only the bench step pays for the bench-runner build.
    run_bench.step.dependOn(&b.addInstallArtifact(bench_dep.artifact("bench-runner"), .{}).step);
    run_bench.stdio = .inherit;
    run_bench.setCwd(b.path("."));
    run_bench.addArgs(&.{ "zig-out/bin/zpicey", "benchmark/fixtures" });
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);
}

// ===========================================================================
// Model discovery
// ===========================================================================

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

/// Configure-time glob of devices/models/* -> sorted model list, stable across builds.
fn discoverModels(b: *std.Build) []const Model {
    const io = b.graph.io;
    var out: std.ArrayList(Model) = .empty;
    var dir = b.build_root.handle.openDir(io, "src_new/devices/models", .{ .iterate = true }) catch
        @panic("devices: src_new/devices/models/ missing");
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

// ===========================================================================
// GPU kernels for the generated devices.
//
// This mirrors gompute's own `emitKernels` and exists only because that helper
// takes a kernels root with no way to add imports — ours needs `models` and
// `contract` (devices/kernels.zig -> engine.zig -> contract). Everything else is
// the same pipeline: device IR -> gompute's rewrite tool -> PTX / HSACO,
// published as the `gompute_kernels` module gompute's host loader reads.
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

/// devices/kernels.zig compiled for a GPU target: same generated devices, same
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
        .root_source_file = b.path("src_new/devices/kernels.zig"),
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
