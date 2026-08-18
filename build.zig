const std = @import("std");
/// gompute's BUILD side (`emitKernels`), distinct from the `gompute` module the
/// app imports. Owns the GPU arch probe and the device-artifact pipeline.
const gompute_build = @import("gompute");

/// Every source tree lives under `src/` and is built from THIS file — the
/// per-directory `build.zig` / `build.zig.zon` pairs are gone. The import names
/// (`devices`, `analysis`, `solvers`, `fastvaf`, `contract`, `models`)
/// are unchanged, so no source file knows the difference. `fastvaf` is VerA's
/// `vera` module (one engine root since the src/va + src/vf merge); the local
/// import name is kept so `src/devices/loader.zig` does not move with it.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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
    // Filled in below, once the vera dependency exists: the two module roots the
    // runtime HDL loader passes to the compiler. They are OPTIONS rather than
    // paths joined at runtime because `contract` now lives in another package —
    // src/main.zig cannot spell that path, and the previous hand-joined
    // `modules/devices/src/...` silently rotted when that directory was deleted.

    // =======================================================================
    // Leaf modules
    // =======================================================================

    const solvers_mod = b.createModule(.{
        .root_source_file = b.path("src/solvers/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // VerA owns the HDL frontends and the `contract` they emit against; this
    // tree consumes both. Two instances of the dependency on purpose: the
    // MODULES follow the consumer's target/optimize because they ship inside the
    // app, while the CLI below is a build tool that runs on the host.
    const vera = b.dependency("vera", .{ .target = target, .optimize = optimize });
    const contract_mod = vera.module("contract");
    const fastvaf_mod = vera.module("vera");

    // The runtime loader compiles a netlist's HDL card against these two roots,
    // and the orchestrator hashes them into `layout_hash` — so they must be the
    // SAME roots the comptime builtins were compiled against, or every cached
    // `.so` is rejected. `dyn` is engine.zig and stays here: it is simulator
    // runtime, not compiler, and the `.so` cannot depend on the compiler.
    bopts.addOption([]const u8, "contract_path", vera.builder.pathFromRoot("tools/contract.zig"));
    bopts.addOption([]const u8, "dyn_path", b.pathFromRoot("src/devices/engine.zig"));

    // =======================================================================
    // Build-time HDL generator
    //
    // Host-targeted and ReleaseFast: the CLI runs once per model over up to
    // 614 K lines of Verilog-A, and Debug is ~10x slower than it needs to be
    // (VerA PERF.md, "Results"). The MODULES above stay on the consumer's
    // target/optimize — this instance exists to make a build tool fast, not to
    // change what ships. Not installed and not on the default step: an
    // executable nothing references is never built, which is what keeps a tree
    // with no digital models from needing verilator.
    //
    // ONE binary for every HDL. `vera` routes on the file extension itself, so
    // the choice below is only about which FLAGS a given source accepts.
    // =======================================================================

    const vera_exe = b.dependency("vera", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }).artifact("vera");

    // =======================================================================
    // Devices: every src/devices/models/* compiled to Zig at build time
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
    const one_models = b.allocator.alloc(*std.Build.Module, models.len) catch @panic("OOM");
    for (models, 0..) |m, i| {
        const run = b.addRunArtifact(vera_exe);
        // The catalog keys devices by FILE stem while the generated type name
        // comes from the MODULE name; both frontends fail on a mismatch.
        run.addArg(b.fmt("--expect-module={s}", .{m.name}));
        // Verilog-A only: the Verilog frontend is a translator with two flags
        // and rejects the rest rather than pretending to honour them.
        if (m.hdl == .verilog_a) {
            run.addArgs(&.{ "--emit-zig", "--color=never" });
            if (check_va) {
                run.addArg("--check");
                run.addArg("--contract");
                run.addFileArg(vera.path("tools/contract.zig"));
            }
        }
        run.addArg("-o");
        const gen_zig = run.addOutputFileArg(b.fmt("{s}.zig", .{m.name}));
        run.addFileArg(b.path(b.fmt("src/devices/models/{s}", .{m.file})));

        const dev_mod = b.createModule(.{
            .root_source_file = gen_zig,
            .target = target,
            .optimize = optimize,
        });
        dev_mod.addImport("contract", contract_mod);
        dev_mods[i] = dev_mod;

        agg_src.appendSlice(b.allocator, b.fmt("pub const {s} = @import(\"{s}\");\n", .{ m.name, m.name })) catch @panic("OOM");

        // A one-device `models` aggregate, so `devices/kernels.zig` compiled
        // against it exports exactly that device's kernel. See the kernel_roots
        // list below for why the GPU side is sliced this way.
        const one_wf = b.addWriteFiles();
        const one_mod = b.createModule(.{
            .root_source_file = one_wf.add("models.zig", b.fmt("pub const {s} = @import(\"{s}\");\n", .{ m.name, m.name })),
            .target = target,
            .optimize = optimize,
        });
        one_mod.addImport(m.name, dev_mod);
        one_models[i] = one_mod;
    }

    const agg_wf = b.addWriteFiles();
    const models_mod = b.createModule(.{
        .root_source_file = agg_wf.add("models.zig", agg_src.items),
        .target = target,
        .optimize = optimize,
    });
    for (models, dev_mods) |m, dev_mod| models_mod.addImport(m.name, dev_mod);

    const devices_mod = b.createModule(.{
        .root_source_file = b.path("src/devices/root.zig"),
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

    // GPU emission moved below the executable: gompute's `emitKernels` takes the
    // host artifact, which does not exist yet here.

    // =======================================================================
    // Analysis
    // =======================================================================

    const analysis_mod = b.createModule(.{
        .root_source_file = b.path("src/analysis/root.zig"),
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
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "devices", .module = devices_mod },
                .{ .name = "analysis", .module = analysis_mod },
                .{ .name = "build_options", .module = bopts_mod },
                // src/gpu_context.zig: the GPU launcher is APP policy (it owns
                // when to go to the device), so it lives beside the engine
                // rather than inside `devices`, and needs the driver handle and
                // the CPU Newton it drives.
                .{ .name = "gompute", .module = gompute.module("gompute") },
                .{ .name = "solvers", .module = solvers_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    if (no_llvm) {
        exe.use_llvm = false;
        exe.use_lld = false;
    }
    b.installArtifact(exe);

    // GPU side-by-side: the SAME generated devices, recompiled for the GPU as
    // one raw kernel each (devices/kernels.zig loops the catalog).
    //
    // gompute's own build helper, NOT a hand-rolled copy. The copy that used to
    // live here (arch probe, IR rewrite, `zig cc` PTX assembly, artifacts
    // module) was written against gompute 0.1.0 and emitted
    // `pub const cuda: []const u8`. The pinned 1.0.0 host loader reads
    // `cuda_images`/`cuda_index`/`root_names` instead, so every device kernel
    // was baked into the binary and NOTHING could look one up — naming a
    // `RawKernel` was a compile error, which is why `--gpu` was still inert.
    // Emission is the dependency's job; it moves with the dependency.
    //
    // Wired onto the shared `gompute` module, so the app, the devices tests and
    // the runtime `.so` all resolve the same images.
    //
    // ONE ROOT PER DEVICE, not one root for the catalog. A root is the unit the
    // CUDA driver JITs: `openModuleByName` loads the blob holding the kernel it
    // was asked for and no other. With all 25 devices in one root that blob was
    // 71 MB of PTX — every process that touched the GPU spent ~15 MINUTES
    // JIT-compiling BSIM4, HiSIM and HICUM to solve an RC pair. Sliced per
    // device, a netlist pays only for the models it instantiates.
    //
    // Same `kernels.zig` each time; only its `models` import differs, so the
    // comptime catalog loop inside it has exactly one device to export.
    if (!no_gpu) {
        const roots = b.allocator.alloc(gompute_build.KernelRoot, models.len) catch @panic("OOM");
        var n_roots: usize = 0;
        for (models, one_models) |m, one_mod| {
            if (m.size >= gpu_max_model_bytes) continue;
            const dev_imports = b.allocator.create(DeviceImports) catch @panic("OOM");
            dev_imports.* = .{ .models = one_mod, .contract = contract_mod };
            roots[n_roots] = .{
                .name = m.name,
                .root = b.path("src/devices/kernels.zig"),
                .imports = &deviceKernelImports,
                .imports_ctx = dev_imports,
                // The compact models are single enormous eval functions; letting
                // them all compile at once is a memory problem, not a speedup.
                .heavy = m.size >= heavy_model_bytes,
            };
            n_roots += 1;
        }
        gompute_build.emitKernels(b, gompute, exe, .{
            .kernel_roots = roots[0..n_roots],
            .heavy_lanes = 2,
            .target = target,
            // Debug device code drags std.builtin's panic globals in and LLVM's
            // NVPTX backend then emits invalid PTX types for them. ReleaseFast,
            // NOT ReleaseSafe: ReleaseSafe keeps the panic machinery and merely
            // optimizes it, and on these single-huge-eval-function models
            // something in LLVM goes superlinear on the safety-check CFG —
            // measured 443s vs 13.6s for hisimhv_va.
            .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
        });
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ZPicey").dependOn(&run_cmd.step);

    // The generator, on demand. One step now that one binary handles every HDL.
    const run_vera = b.addRunArtifact(vera_exe);
    if (b.args) |args| run_vera.addArgs(args);
    b.step("vera", "Run the vera CLI (any .va/.v/.sv/.vhd)").dependOn(&run_vera.step);

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
        .root_source_file = b.path("src/builder.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "analysis", .module = analysis_mod },
            .{ .name = "devices", .module = devices_mod },
        },
    });
    const app_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "analysis", .module = analysis_mod },
            .{ .name = "devices", .module = devices_mod },
            .{ .name = "builder", .module = builder_mod },
        },
    });

    const app_tests = b.addTest(.{ .root_module = app_test_mod });
    if (no_llvm) {
        app_tests.use_llvm = false;
        app_tests.use_lld = false;
    }
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    // The three module suites, each as its own test root. The HDL frontends'
    // own suites, and both Verilog-A oracles, live in VerA — `zig build test`
    // over there, not here.
    for ([_]struct { name: []const u8, desc: []const u8, mod: *std.Build.Module }{
        .{ .name = "test-solvers", .desc = "Run solver tests", .mod = solvers_mod },
        .{ .name = "test-analysis", .desc = "Run analysis tests", .mod = analysis_mod },
        // Building this at all pulls every models/* through vera.
        .{ .name = "test-devices", .desc = "Run device tests", .mod = devices_mod },
    }) |suite| {
        const run = b.addRunArtifact(b.addTest(.{ .root_module = suite.mod }));
        b.step(suite.name, suite.desc).dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // The Verilog-A conformance and exhaustive oracles moved to VerA with the
    // fixtures they read. They test the compiler, not the simulator:
    //
    //   cd ../VerA && zig build conformance     # 856 fixtures vs .expected-error.txt
    //   cd ../VerA && zig build exhaustive      # testbench transcripts
    //
    // What still guards the boundary from THIS side is `-Dcheck-va` above: every
    // generated device is type-checked against the contract at the .va that
    // produced it.

    // =======================================================================
    // Benchmark (still its own package — it is fixtures and a runner, not a
    // source tree that belongs under src/)
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
    /// Source bytes. Only used to decide `KernelRoot.heavy` — a stand-in for
    /// "how big is this device's eval function", which is not knowable at
    /// configure time and which source size tracks closely enough for a
    /// scheduling hint.
    size: u64,
};

/// Source size past which a model's GPU compilation is `heavy` — chained into
/// `heavy_lanes` rather than run alongside every other big one.
///
/// ponytail: a size threshold, not a hand-kept name list. The compact models
/// (BSIM, HiSIM, HICUM) are the large sources by a wide margin, so the two
/// agree, and a threshold does not go stale when a model is added.
const heavy_model_bytes: u64 = 100 * 1024;

/// Source size at or above which a model gets NO GPU kernel at all.
///
/// Not a build-time convenience — the emitted kernels past this line cannot win.
/// Measured on an RTX 4060 Laptop (sm_89):
///
///   model        source   PTX      cold cuModuleLoadData
///   mos9          20 KB   731 KB    11.4 ms
///   bjt           20 KB   895 KB    12.6 ms
///   hicumL2_va    90 KB   9.7 MB    (not measured; sized like bsim4)
///   bsim4va      440 KB   8.7 MB    37.9 ms WARM
///   bsimsoi_va   399 KB  11.3 MB   308_667 ms  <-- five minutes, cold
///   hisimhv_va   614 KB  38.4 MB   >900_000 ms, killed
///
/// The driver caches JIT output in ~/.nv/ComputeCache, so that cost is paid once
/// per (model, arch, driver) — but it IS paid, the cache evicts at ~109 MB here,
/// and it bought a kernel that loses anyway: bsim4's PTX carries 142_990 f64 ops
/// and 7104+ virtual 64-bit registers against a 255-register file, so it spills
/// to local memory and runs at ~16% occupancy on a part whose f64 rate is 1/69
/// of its f32 rate. The CPU does the same work at 1449 GFLOP/s against the GPU's
/// 152.7. Emitting these also put 68 MB of PTX in .data — most of a 549 MB
/// binary — for kernels that were slower than not having them.
///
/// 80 KB because the sizes cluster: hicumL2_va at 90 KB is the smallest model
/// that blows up (9.7 MB of PTX), and mos2 at 24 KB is the largest that does
/// not. Nothing lives in between.
///
/// ponytail: source bytes, not emitted PTX bytes. PTX size is the quantity that
/// actually predicts JIT cost, but it is only known AFTER paying the build-time
/// compile this threshold exists to skip. Source size is the proxy available at
/// configure time and the cluster gap is wide enough that it separates cleanly.
///
/// Revisit when P3 lands: with an f32 Jacobian these models get ~69x more
/// throughput and a much smaller register footprint, which is the whole point of
/// that phase — this cap is what should move first when it does.
const gpu_max_model_bytes: u64 = 80 * 1024;

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
    var dir = b.build_root.handle.openDir(io, "src/devices/models", .{ .iterate = true }) catch
        @panic("devices: src/devices/models/ missing");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("devices: models/ iterate failed")) |e| {
        if (e.kind != .file) continue;
        const m = matchExt(e.name) orelse continue;
        const st = dir.statFile(io, e.name, .{}) catch @panic("devices: models/ stat failed");
        out.append(b.allocator, .{
            .name = b.dupe(e.name[0 .. e.name.len - m.ext.len]),
            .file = b.dupe(e.name),
            .hdl = m.hdl,
            .size = st.size,
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
// GPU kernels for the generated devices
//
// Only the IMPORTS are ours. `gompute_build.emitKernels` owns the arch probe,
// the device compilation, the IR rewrite, PTX/HSACO assembly and the artifacts
// module — a pipeline this file used to duplicate because gompute 0.1.0 gave a
// kernels root no way to add imports. 1.0.0 has `.imports`, so the duplicate
// went; it had already drifted to emitting an artifacts module the pinned host
// loader cannot read.
// ===========================================================================

/// What `deviceKernelImports` needs, passed through `emitKernels` untouched.
const DeviceImports = struct {
    models: *std.Build.Module,
    contract: *std.Build.Module,
};

/// `src/devices/kernels.zig` reaches the device catalog through `models`, and
/// `engine.zig` behind it needs `contract`. gompute adds `gompute` (its device
/// shim) itself, so those two are the whole delta.
///
/// The modules are reused as-is rather than rebuilt for the GPU target: a
/// device module carries no target-specific code of its own, and rebuilding
/// them here would fork the types the host and the kernel must agree on.
fn deviceKernelImports(
    b: *std.Build,
    _: std.Build.ResolvedTarget,
    _: std.builtin.OptimizeMode,
    ctx: ?*anyopaque,
) []const std.Build.Module.Import {
    const di: *DeviceImports = @ptrCast(@alignCast(ctx.?));
    const out = b.allocator.alloc(std.Build.Module.Import, 2) catch @panic("OOM");
    out[0] = .{ .name = "models", .module = di.models };
    out[1] = .{ .name = "contract", .module = di.contract };
    return out;
}
