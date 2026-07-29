//! Build graph for espice. Module imports here ARE the dependency DAG in
//! AGENTS.md: a module can only import what this file hands it.
const std = @import("std");
const gompute_build = @import("gompute");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast by default: `zig build bench` compares against -O2 ngspice,
    // and a Debug espice is 10-40x slower. Not `standardOptimizeOption`: in
    // 0.16 its preferred mode applies only under `-Drelease`.
    const optimize = b.option(std.lang.Optimize, "optimize", "Prioritize performance, safety, or binary size") orelse .fast;
    // Mixed precision (dev/perf/jac-width-2026-09-10.md). The Jacobian width
    // is a property of the instantiation, not of the device, hence two lists.
    //
    // `-Djac-f32-gpu` permits an f32 Jacobian: vera's `--jac-f32` sets
    // `jac_f32`, which the GPU kernel takes and the host declines. Default is
    // none: with mos1 resident (VerA ABI 5), its f32 Jacobian fails four
    // corpus decks under `--backend cuda` that pass in f64 (disto
    // bench_disto_mos_cs, the inverter chains, parallel_inverters_2000).
    // diode and bsim4va measured worse and stay f64.
    const jac_f32_gpu_list = b.option([]const u8, "jac-f32-gpu", "Comma-separated model stems whose physics permits an f32 Jacobian (GPU kernel takes it)") orelse "";
    // `-Djac-f32` also runs the listed stems in f32 on the CPU (vera's
    // `--jac-f32-host`, which implies the permission).
    const jac_f32_list = b.option([]const u8, "jac-f32", "Comma-separated model stems to ALSO build with an f32 Jacobian on the CPU path") orelse "";

    const gompute = b.dependency("gompute", .{});
    const vera = b.dependency("vera", .{ .target = target, .optimize = optimize });
    const contract_mod = vera.module("contract");
    const vera_exe = b.dependency("vera", .{
        .target = b.graph.host,
        .optimize = .fast,
    }).artifact("vera");

    const bopts = b.addOptions();
    bopts.addOption([]const u8, "contract_path", pathFromRoot(b, vera.builder, "tools/contract.zig"));
    // The runtime HDL loader rebuilds device/eval.zig as a .so and imports
    // these roots by path. They are hidden edges of the module graph: move a
    // file, move its path here.
    bopts.addOption([]const u8, "dyn_path", pathFromRoot(b, b, "src/device/eval.zig"));
    bopts.addOption([]const u8, "device_abi_path", pathFromRoot(b, b, "src/device/abi.zig"));
    bopts.addOption([]const u8, "core_path", pathFromRoot(b, b, "src/core/root.zig"));
    const stdpp_dep = b.dependency("stdpp", .{ .target = target, .optimize = optimize });
    bopts.addOption([]const u8, "stdpp_path", pathFromRoot(b, stdpp_dep.builder, "src/root.zig"));
    bopts.addOption([]const u8, "gompute_path", pathFromRoot(b, gompute.builder, "src/root.zig"));

    // Release strips DWARF: debug info was ~2/3 of LLVM time, superlinear in
    // function size, and 115 MB of the shipped binary. `-Ddebug-info` puts it
    // back when a symbolized profile is worth the wait.
    const debug_info = b.option(bool, "debug-info", "Emit DWARF in Release builds (slow: ~3x LLVM time)") orelse false;
    // Compiling every model for NVPTX and AMDGCN is most of a full build.
    // `-Dgpu=false` is the CPU iteration build, not a shipping or bench one.
    const gpu_kernels = b.option(bool, "gpu", "Compile the GPU device kernels (default true)") orelse true;
    // Every module here is (root, target, optimize, strip) plus imports.
    // stdpp (vectorizing iterators) is a std extension: every host module
    // gets it. GPU device modules do not; eval.zig must not import it.
    const stdpp_mod = stdpp_dep.module("stdpp");
    const M = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        strip: bool,
        stdpp: ?*std.Build.Module,
        fn make(
            self: @This(),
            root: std.Build.LazyPath,
            imports: []const std.Build.Module.Import,
        ) *std.Build.Module {
            const mod = self.b.createModule(.{
                .root_source_file = root,
                .target = self.target,
                .optimize = self.optimize,
                .strip = self.strip,
                .imports = imports,
            });
            if (self.stdpp) |sp| mod.addImport("stdpp", sp);
            return mod;
        }
    }{ .b = b, .target = target, .optimize = optimize, .strip = optimize != .debug and !debug_info, .stdpp = stdpp_mod };
    // Strip pinned on, `-Ddebug-info` or not, for device code: DWARF over
    // generated models is superlinear and maps to cache files nobody reads,
    // and with DI on, the NVPTX backend and the host device objects SEGV'd
    // the compiler (mos2, vdmos). Symbols survive; only line tables go.
    const GPU = @TypeOf(M){ .b = b, .target = target, .optimize = optimize, .strip = true, .stdpp = null };

    const build_options_mod = bopts.createModule();

    const core_mod = M.make(b.path("src/core/root.zig"), &.{});
    const core_import: std.Build.Module.Import = .{ .name = "core", .module = core_mod };
    const device_abi_mod = M.make(b.path("src/device/abi.zig"), &.{ .{ .name = "contract", .module = contract_mod }, core_import });
    const device_eval_mod = M.make(b.path("src/device/eval.zig"), &.{
        .{ .name = "contract", .module = contract_mod },
        .{ .name = "gompute", .module = gompute.module("gompute") },
        .{ .name = "device_abi", .module = device_abi_mod },
    });
    device_eval_mod.link_libc = true;
    const solver_mod = M.make(b.path("src/solver/root.zig"), &.{core_import});
    // A leaf on core alone, so `zig build test-output` skips the simulator.
    const output_mod = M.make(b.path("src/output/root.zig"), &.{core_import});

    const netlist_mod = M.make(b.path("src/frontend/netlist.zig"), &.{core_import});
    const frontend_bench = b.addExecutable(.{
        .name = "frontend-bench",
        .use_llvm = optimize != .debug,
        .root_module = M.make(b.path("tests/benchmark/frontend.zig"), &.{.{ .name = "netlist", .module = netlist_mod }}),
    });
    const run_frontend_bench = b.addRunArtifact(frontend_bench);
    run_frontend_bench.addPassthruArgs();
    b.step("bench-frontend", "Measure netlist parsing and expansion").dependOn(&run_frontend_bench.step);

    // Devices: every models/* file compiled to Zig at build time, whatever its
    // HDL. `wf` collects the generated roots: one models.zig re-exporting all
    // devices (device/root.zig reflects over it) and one single-device
    // models.zig per model, because a GPU kernel root must see only its device.
    const models = discoverModels(b);
    const wf = b.addWriteFiles();

    var agg_src: std.ArrayList(u8) = .empty;
    agg_src.appendSlice(b.allocator, "//! Generated — build-time HDL device models.\n") catch @panic("OOM");

    const dev_mods = b.allocator.alloc(*std.Build.Module, models.len) catch @panic("OOM");
    const one_models = b.allocator.alloc(*std.Build.Module, models.len) catch @panic("OOM");
    // One host object per model, so a solver edit
    // does not recompile every device eval as one single-threaded unit.
    // See dev/perf/build-split-2026-09-10.md.
    const host_objs = b.allocator.alloc(*std.Build.Step.Compile, models.len) catch @panic("OOM");
    for (models, 0..) |m, i| {
        const run = b.addRunArtifact(vera_exe);
        // The catalog keys on the file stem, the generated type on the module
        // name; vera fails on a mismatch.
        run.addArg(b.fmt("--expect-module={s}", .{m.name}));
        // The digital frontend rejects these flags, so Verilog-A only.
        // `--check` type-checks the generated device, so a bad lowering names
        // the .va instead of a cache file.
        if (m.hdl == .verilog_a) {
            run.addArgs(&.{"--emit-zig"});
            if (inCsv(jac_f32_gpu_list, m.name)) run.addArg("--jac-f32");
            if (inCsv(jac_f32_list, m.name)) run.addArg("--jac-f32-host");
            // Existing model warnings, allowed so the empty-stderr gate passes:
            // W0650 (unit not provably finite, so strict float: correct but
            // unvectorized), W0651 (closed-infinity ranges in upstream ports),
            // W0850 ($display in hisim-class devices). Re-proving the models
            // clears them.
            run.addArgs(&.{ "--allow=W0650", "--allow=W0651", "--allow=W0850", "--color=never", "--check" });
            // `--check` spawns zig; the one running this build, not PATH's.
            run.addArgs(&.{ "--zig", b.graph.zig_exe, "--contract" });
            run.addFileArg(vera.path("tools/contract.zig"));
        }
        if (m.include) |inc| {
            run.addArgs(&.{ "-I", pathFromRoot(b, b, "models") });
            run.addFileInput(b.path(b.fmt("models/{s}", .{inc})));
        }
        run.addArg("-o");
        const gen_zig = run.addOutputFileArg2(b.fmt("{s}.zig", .{m.name}), .{});
        run.addFileArg(b.path(b.fmt("models/{s}", .{m.file})));

        dev_mods[i] = GPU.make(gen_zig, &.{.{ .name = "contract", .module = contract_mod }});

        const one_line = b.fmt("pub const {s} = @import(\"{s}\");\n", .{ m.name, m.name });
        agg_src.appendSlice(b.allocator, one_line) catch @panic("OOM");

        one_models[i] = GPU.make(wf.add(b.fmt("{s}/models.zig", .{m.name}), one_line), &.{});
        one_models[i].addImport(m.name, dev_mods[i]);

        // The host object exporting `arp_device_<stem>`, built from the same
        // one-device aggregate as the GPU kernel so both see the same type.
        const host_mod = GPU.make(b.path("src/device/eval.zig"), &.{
            .{ .name = "contract", .module = contract_mod },
            .{ .name = "models", .module = one_models[i] },
            .{ .name = "device_abi", .module = device_abi_mod },
            .{ .name = "gompute", .module = gompute.module("gompute") },
        });
        // The runtime-.so half of the evaluator dlopens.
        host_mod.link_libc = true;
        // The device vtable is callconv(.auto), which passes a hidden
        // *StackTrace when error tracing is on. Stripping turns tracing off,
        // so a traced Debug exe would call these with shifted arguments.
        host_mod.error_tracing = optimize == .debug;
        host_objs[i] = b.addObject(.{ .name = b.fmt("dev_{s}", .{m.name}), .root_module = host_mod });
        host_objs[i].use_llvm = optimize != .debug; // see exe.use_llvm
    }

    const models_mod = M.make(wf.add("models.zig", agg_src.items), &.{});
    for (models, dev_mods) |m, dev_mod| models_mod.addImport(m.name, dev_mod);

    const device_mod = M.make(b.path("src/device/root.zig"), &.{
        .{ .name = "models", .module = models_mod },
        .{ .name = "device_abi", .module = device_abi_mod },
        core_import,
        .{ .name = "fastvaf", .module = vera.module("vera") },
        .{ .name = "vera_sim", .module = vera.module("sim") },
        .{ .name = "build_options", .module = build_options_mod },
    });
    device_mod.link_libc = true;

    const analysis_mod = M.make(b.path("src/analysis/root.zig"), &.{
        .{ .name = "solver", .module = solver_mod },
        core_import,
        .{ .name = "device", .module = device_mod },
        .{ .name = "gompute", .module = gompute.module("gompute") },
    });
    analysis_mod.linkSystemLibrary("c", .{});

    // Passive circuit construction, shared by the frontend and its tests.
    const builder_mod = M.make(b.path("src/frontend/builder.zig"), &.{
        core_import,
        .{ .name = "device", .module = device_mod },
        .{ .name = "netlist", .module = netlist_mod },
    });
    const frontend_mod = M.make(b.path("src/frontend/root.zig"), &.{
        core_import,
        .{ .name = "device", .module = device_mod },
        .{ .name = "netlist", .module = netlist_mod },
        .{ .name = "builder", .module = builder_mod },
    });

    const espice_mod = M.make(b.path("src/espice.zig"), &.{
        core_import,
        .{ .name = "analysis", .module = analysis_mod },
        .{ .name = "frontend", .module = frontend_mod },
        .{ .name = "output", .module = output_mod },
    });

    const exe = b.addExecutable(.{
        .name = "espice",
        .root_module = M.make(b.path("src/main.zig"), &.{.{ .name = "espice", .module = espice_mod }}),
    });
    exe.root_module.link_libc = true;
    // The self-hosted backend emits unoptimized code whatever the mode says,
    // so every Release build goes through LLVM; Debug keeps the fast backend.
    exe.use_llvm = optimize != .debug;
    // LLD cannot link Mach-O; macOS keeps Zig's own linker.
    exe.use_lld = optimize != .debug and !target.result.os.tag.isDarwin();
    for (host_objs) |o| exe.root_module.addObject(o);
    b.installArtifact(exe);
    // Runtime `.hdl` builds compile eval.zig against these roots (the
    // `*_path` options above). Installing them in share/espice, where
    // Library.load looks first, frees an installed espice from this tree.
    for ([_]struct { std.Build.LazyPath, []const u8 }{
        .{ b.path("src/core"), "core" },
        .{ b.path("src/device"), "device" },
        .{ gompute.path("src"), "gompute" },
        .{ stdpp_dep.path("src"), "stdpp" },
        .{ vera.path("lib"), "vera/lib" },
        .{ vera.path("src/sim"), "vera/src/sim" },
    }) |dir| b.installDirectory(.{
        .source_dir = dir[0],
        .install_dir = .prefix,
        .install_subdir = b.fmt("share/espice/{s}", .{dir[1]}),
        .include_extensions = &.{".zig"},
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(vera.path("tools/contract.zig"), .prefix, "share/espice/vera/tools/contract.zig").step);

    // GPU kernels. `emitKernels` probes the arch, and a machine with no device
    // emits nothing, but `gompute_kernels` always exists for analysis/gpu.zig.
    const smallest_model = blk: {
        var best = models[0];
        for (models) |m| if (m.size < best.size) {
            best = m;
        };
        break :blk best.name;
    };
    var roots: std.ArrayList(gompute_build.KernelRoot) = .empty;
    for (models, one_models) |m, one_mod| {
        // `-Dgpu=false` still compiles one model: gompute panics on an empty
        // root list, and `--backend cuda` must keep erroring by name.
        if (!gpu_kernels and !std.mem.eql(u8, m.name, smallest_model)) continue;
        if (m.size >= gpu_max_model_bytes) continue;
        const dev_imports = b.allocator.create(DeviceImports) catch @panic("OOM");
        dev_imports.* = .{ .models = one_mod, .contract = contract_mod, .device_abi = device_abi_mod };
        roots.append(b.allocator, .{
            .name = m.name,
            .root = b.path("src/device/eval.zig"),
            .imports = &deviceKernelImports,
            .imports_ctx = dev_imports,
            // Large models are single enormous eval functions; compiling them
            // all at once runs out of memory.
            .heavy = m.size >= heavy_model_bytes,
        }) catch @panic("OOM");
    }
    // The device LU (dev/solvers/gpu-lu.md): std and gompute only, so it
    // builds whenever any kernel does, `-Dgpu=false` included.
    roots.append(b.allocator, .{ .name = "lu", .root = b.path("src/solver/lu_device.zig") }) catch @panic("OOM");
    // HIP is pinned: `.auto` probes the BUILD machine, and a box without an
    // AMD card would compile `--backend hip` out of every binary it ships.
    // gfx1100 (RDNA3) is the claimed baseline. Release CI has no GPU and must
    // pin CUDA too; the driver JITs PTX forward, so an old `sm_` runs on
    // newer cards. `none` compiles a backend out.
    const cuda_arch = b.option([]const u8, "cuda-arch", "CUDA arch (sm_75, ...), `auto` to probe the build machine, `none` to omit") orelse "auto";
    const hip_arch = b.option([]const u8, "hip-arch", "HIP arch (gfx1100, ...), `none` to omit") orelse "gfx1100";
    gompute_build.emitKernels(b, gompute, exe, .{
        .kernel_roots = roots.items,
        .heavy_lanes = 2,
        .target = target,
        .cuda = gpuArch(cuda_arch),
        .hip = gpuArch(hip_arch),
        // Debug kernels compile 30x slower (443 s vs 13.6 s for hisimhv_va).
        .optimize = if (optimize == .debug) .fast else optimize,
    });

    // 0.17 removed @cImport. ponytail: the deprecated TranslateC step, until
    // 0.18 removes it too; then the codeberg translate-c package.
    const espice_h = b.addTranslateC(.{ .root_source_file = b.path("include/espice.h"), .target = target, .optimize = optimize }).createModule();
    const c_api_mod = M.make(b.path("src/c_api.zig"), &.{
        .{ .name = "espice", .module = espice_mod },
        .{ .name = "espice_h", .module = espice_h }, // c_api.zig pins its enums to the header
    });
    c_api_mod.link_libc = true;
    for (host_objs) |o| c_api_mod.addObject(o);
    const c_api_lib = b.addLibrary(.{ .name = "espice", .linkage = .static, .root_module = c_api_mod });
    c_api_lib.use_llvm = exe.use_llvm;
    c_api_lib.use_lld = exe.use_lld;
    b.installArtifact(c_api_lib);
    c_api_lib.installHeader(b.path("include/espice.h"), "espice.h");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run ESPice").dependOn(&run_cmd.step);

    const run_vera = b.addRunArtifact(vera_exe);
    run_vera.addPassthruArgs();
    b.step("vera", "Run the vera CLI (any .va/.v/.sv/.vhd)").dependOn(&run_vera.step);

    // Tests: one test binary per module. `zig test` collects tests only from
    // the root module's own files, so a cross-module `_ = @import(...)` adds
    // none. Within a module, each root.zig's `test { _ = ...; }` aggregator
    // pulls in its siblings. The Verilog-A conformance oracles live in VerA
    // (`zig build conformance`, `zig build exhaustive` there).
    const test_step = b.step("test", "Run every suite and the numeric SPICE fixtures");
    const t: HostTest = .{ .b = b, .exe = exe, .objs = host_objs };

    const c_api_test_mod = M.make(b.path("src/tests/c_api.zig"), &.{.{ .name = "espice_h", .module = espice_h }});
    c_api_test_mod.link_libc = true;
    c_api_test_mod.linkLibrary(c_api_lib);
    const run_c_api_tests = t.run(c_api_test_mod, &.{}, false);

    // analysis_mod predates emitKernels, so its `gompute_kernels` import is wired here.
    if (exe.root_module.import_table.get("gompute_kernels")) |artifacts|
        analysis_mod.addImport("gompute_kernels", artifacts);

    const limiter_gen = b.addRunArtifact(vera_exe);
    limiter_gen.addArgs(&.{ "--emit-zig", "--allow=W0650", "-o" });
    const limiter_source = limiter_gen.addOutputFileArg2("va_limit_state.zig", .{});
    limiter_gen.addFileArg(b.path("tests/fixtures/hdl/veriloga_limit.assets/va_limit_state.va"));
    const limiter_mod = M.make(limiter_source, &.{.{ .name = "contract", .module = contract_mod }});

    // A separate object on purpose: Zig error ordinals differ between
    // compilations even for the same error set, which is what this tests.
    const error_object_mod = M.make(b.path("src/device/tests/device_errors_object.zig"), &.{
        .{ .name = "device_eval", .module = device_eval_mod },
        .{ .name = "device_abi", .module = device_abi_mod },
        .{ .name = "contract", .module = contract_mod },
    });
    error_object_mod.link_libc = true;
    const error_object = b.addObject(.{ .name = "device_errors", .root_module = error_object_mod, .use_llvm = optimize != .debug });
    const error_tests_mod = M.make(b.path("src/device/tests/device_errors.zig"), &.{.{ .name = "device_abi", .module = device_abi_mod }});
    error_tests_mod.addObject(error_object);

    for ([_]struct { []const u8, []const u8, []const *std.Build.Step.Run }{
        .{
            "test-espice", "Run Problem facade, analysis contract, C ABI and CLI tests",
            &.{
                t.run(M.make(b.path("src/tests/espice.zig"), &.{.{ .name = "espice", .module = espice_mod }}), &.{}, true),
                run_c_api_tests,
                // The CLI's own tests; the exe's module already carries the device objects.
                t.run(exe.root_module, &.{}, false),
            },
        },
        .{
            "test-frontend", "Run netlist, builder and prepared-circuit tests",
            &.{
                t.run(netlist_mod, &.{}, false),
                // The W/S fitters (wfit.zig imports sparam.zig).
                t.run(M.make(b.path("src/frontend/wfit.zig"), &.{core_import}), &.{}, false),
                // build_options: the binder test loads models/diode.va at runtime.
                t.run(frontend_mod, &.{.{ .name = "build_options", .module = build_options_mod }}, true),
            },
        },
        .{ "test-analysis", "Run all analysis tests", &.{t.run(analysis_mod, &.{
            .{ .name = "builder", .module = builder_mod },
            .{ .name = "limiter_device", .module = limiter_mod },
            .{ .name = "contract", .module = contract_mod },
            .{ .name = "models", .module = models_mod },
            .{ .name = "device_eval", .module = device_eval_mod },
        }, true)} },
        .{ "test-core", "Run shared data and numerics tests", &.{t.run(core_mod, &.{}, false)} },
        .{ "test-solver", "Run solver tests", &.{t.run(solver_mod, &.{}, false)} },
        .{ "test-output", "Run waveform writer tests", &.{t.run(output_mod, &.{}, false)} },
        .{ "test-device", "Run device catalog, evaluator and ABI tests", &.{
            t.run(device_mod, &.{}, true),
            t.run(device_abi_mod, &.{}, false),
            t.run(M.make(b.path("src/device/tests/eval.zig"), &.{
                .{ .name = "device_eval", .module = device_eval_mod },
                .{ .name = "contract", .module = contract_mod },
            }), &.{}, false),
            t.run(error_tests_mod, &.{}, false),
        } },
    }) |suite| {
        const step = b.step(suite[0], suite[1]);
        for (suite[2]) |r| step.dependOn(&r.step);
        test_step.dependOn(step);
    }
    b.step("test-c-api", "Run C ABI boundary tests").dependOn(&run_c_api_tests.step);

    // The correctness and benchmark runners share one build-time fixture catalog.
    const fixture_catalog = @import("tests/fixture_catalog.zig").create(b);
    const fixture_imports: []const std.Build.Module.Import = &.{.{ .name = "fixture_catalog", .module = fixture_catalog }};
    const correctness = b.addExecutable(.{
        .name = "test-correctness",
        .root_module = M.make(b.path("tests/test_correctness.zig"), fixture_imports),
    });
    const run_correctness = b.addRunArtifact(correctness);
    run_correctness.setCwd(b.path("."));
    run_correctness.addArtifactArg2(exe, .{});
    run_correctness.setEnvironmentVariable("ZIG", b.graph.zig_exe); // runtime .hdl builds
    run_correctness.addPassthruArgs();
    test_step.dependOn(&run_correctness.step);

    // The same corpus and expectations on the device path. Not part of
    // `test`: it needs a GPU, and without one every deck fails by design.
    const run_gpu_corpus = b.addRunArtifact(correctness);
    run_gpu_corpus.setCwd(b.path("."));
    run_gpu_corpus.addArtifactArg2(exe, .{});
    run_gpu_corpus.setEnvironmentVariable("ZIG", b.graph.zig_exe); // runtime .hdl builds
    run_gpu_corpus.addArgs(&.{ "--backend", "cuda" });
    run_gpu_corpus.addPassthruArgs();
    b.step("test-gpu", "Run the numeric SPICE fixtures with --backend cuda").dependOn(&run_gpu_corpus.step);

    const run_harness_tests = t.run(M.make(b.path("tests/test_correctness.zig"), fixture_imports), &.{}, false);
    run_harness_tests.setCwd(b.path("."));
    run_correctness.step.dependOn(&run_harness_tests.step);

    const bench_runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = M.make(b.path("tests/benchmark/runner.zig"), &.{}),
    });
    const run_bench = b.addRunArtifact(bench_runner);
    run_bench.stdio = .inherit;
    run_bench.setCwd(b.path("."));
    run_bench.addArtifactArg2(exe, .{});
    run_bench.setEnvironmentVariable("ZIG", b.graph.zig_exe); // runtime .hdl builds
    run_bench.addArg("tests/fixtures");
    run_bench.addPassthruArgs();
    b.step("bench", "Compare ESPice with ngspice and VACASK (nix develop .#benchmarking)").dependOn(&run_bench.step);
    // Synthetic post-layout decks (no oracles, so not fixtures): generated
    // into zig-out/postlayout, then timed like `bench`.
    const gen_postlayout = b.addSystemCommand(&.{ "python3", "tests/benchmark/postlayout/gen.py", "zig-out/postlayout" });
    gen_postlayout.setCwd(b.path("."));
    const run_postlayout = b.addRunArtifact(bench_runner);
    run_postlayout.stdio = .inherit;
    run_postlayout.setCwd(b.path("."));
    run_postlayout.addArtifactArg2(exe, .{});
    run_postlayout.setEnvironmentVariable("ZIG", b.graph.zig_exe); // runtime .hdl builds
    run_postlayout.addArgs(&.{ "zig-out/postlayout", "--out", "zig-out/postlayout-results.md" });
    run_postlayout.addPassthruArgs();
    run_postlayout.step.dependOn(&gen_postlayout.step);
    b.step("bench-postlayout", "Time ESPice on synthetic post-layout decks against ngspice and VACASK").dependOn(&run_postlayout.step);

    // External suites (ngspice tests, CircuitSim90, power grids, CMC QA):
    // fetched at pinned revisions into zig-out/suites, then timed like
    // `bench`. `-Dsuite=NAME` limits the fetch to one suite.
    const suite = b.option([]const u8, "suite", "bench-suites: one suite under tests/suites (default: all)");
    const fetch_suites = b.addSystemCommand(&.{ "bash", "tests/suites/fetch.sh", "zig-out/suites" });
    if (suite) |name| fetch_suites.addArg(name);
    fetch_suites.setCwd(b.path("."));
    fetch_suites.has_side_effects = true;
    const run_suites = b.addRunArtifact(bench_runner);
    run_suites.stdio = .inherit;
    run_suites.setCwd(b.path("."));
    run_suites.addArtifactArg2(exe, .{});
    run_suites.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    run_suites.addArgs(&.{ if (suite) |name| b.fmt("zig-out/suites/{s}", .{name}) else "zig-out/suites", "--out", "zig-out/suites-results.md" });
    run_suites.addPassthruArgs();
    run_suites.step.dependOn(&fetch_suites.step);
    b.step("bench-suites", "Fetch the external SPICE suites and time ESPice on them against ngspice and VACASK").dependOn(&run_suites.step);
    const run_bench_tests = t.run(M.make(b.path("tests/benchmark/runner.zig"), &.{}), &.{}, false);
    b.step("test-benchmark", "Test reference adapters and benchmark comparison").dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_bench_tests.step);

    // `zig build wasm`: the docs playground's two modules in zig-out/wasm.
    // espice.wasm is this graph again for wasm32-wasi: CPU only, single
    // threaded (GitHub Pages cannot send the COOP/COEP headers shared memory
    // needs), the built-in models, and the C API over in-memory netlists
    // (tools/playground/espice.zig). cktimg.wasm comes from
    // tools/playground/build.zig, a separate build root run as a child
    // `zig build`, so cktImg stays out of this manifest and no other step,
    // package or downstream user ever fetches it.
    {
        const wasm_step = b.step("wasm", "Build the docs playground (zig-out/wasm/espice.wasm, cktimg.wasm)");
        const wt = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
        });
        const wo: std.lang.Optimize = .small;
        const wvera = b.dependency("vera", .{ .target = wt, .optimize = wo });
        const wcontract: std.Build.Module.Import = .{ .name = "contract", .module = wvera.module("contract") };
        const wgompute: std.Build.Module.Import = .{ .name = "gompute", .module = b.dependency("gompute", .{ .target = wt, .optimize = wo }).module("gompute") };
        const W = @TypeOf(M){ .b = b, .target = wt, .optimize = wo, .strip = true, .stdpp = b.dependency("stdpp", .{ .target = wt, .optimize = wo }).module("stdpp") };
        const WD = @TypeOf(M){ .b = b, .target = wt, .optimize = wo, .strip = true, .stdpp = null };
        const wcore: std.Build.Module.Import = .{ .name = "core", .module = W.make(b.path("src/core/root.zig"), &.{}) };
        const wabi: std.Build.Module.Import = .{ .name = "device_abi", .module = W.make(b.path("src/device/abi.zig"), &.{ wcontract, wcore }) };
        const wmodels = W.make(models_mod.root_source_file.?, &.{});
        const wroot = W.make(b.path("tools/playground/espice.zig"), &.{});
        // One object per model, as on the host.
        for (models, dev_mods, one_models) |m, dev, one| {
            const wdev = WD.make(dev.root_source_file.?, &.{wcontract});
            wmodels.addImport(m.name, wdev);
            const wone = WD.make(one.root_source_file.?, &.{.{ .name = m.name, .module = wdev }});
            const host = WD.make(b.path("src/device/eval.zig"), &.{ wcontract, wabi, wgompute, .{ .name = "models", .module = wone } });
            host.link_libc = true; // as on the host
            wroot.addObject(b.addObject(.{ .name = b.fmt("wasm_{s}", .{m.name}), .root_module = host }));
        }
        const wdevice: std.Build.Module.Import = .{ .name = "device", .module = W.make(b.path("src/device/root.zig"), &.{
            .{ .name = "models", .module = wmodels },
            wabi,
            wcore,
            .{ .name = "fastvaf", .module = wvera.module("vera") },
            .{ .name = "vera_sim", .module = wvera.module("sim") },
            .{ .name = "build_options", .module = build_options_mod },
        }) };
        const wnetlist: std.Build.Module.Import = .{ .name = "netlist", .module = W.make(b.path("src/frontend/netlist.zig"), &.{wcore}) };
        const wespice = W.make(b.path("src/espice.zig"), &.{
            wcore,
            .{ .name = "analysis", .module = W.make(b.path("src/analysis/root.zig"), &.{
                .{ .name = "solver", .module = W.make(b.path("src/solver/root.zig"), &.{wcore}) },
                wcore,
                wdevice,
                wgompute,
                // No kernels: the device path compiles out.
                .{ .name = "gompute_kernels", .module = b.createModule(.{ .root_source_file = wf.add("wasm_kernels.zig", "pub const emitted = false;\npub const has_cuda = false;\npub const has_hip = false;\n") }) },
            }) },
            .{ .name = "frontend", .module = W.make(b.path("src/frontend/root.zig"), &.{
                wcore,
                wdevice,
                wnetlist,
                .{ .name = "builder", .module = W.make(b.path("src/frontend/builder.zig"), &.{ wcore, wdevice, wnetlist }) },
            }) },
            .{ .name = "output", .module = W.make(b.path("src/output/root.zig"), &.{wcore}) },
        });
        const wh: std.Build.Module.Import = .{ .name = "espice_h", .module = b.addTranslateC(.{ .root_source_file = b.path("include/espice.h"), .target = wt, .optimize = wo }).createModule() };
        wroot.addImport("c_api", W.make(b.path("src/c_api.zig"), &.{ .{ .name = "espice", .module = wespice }, wh }));
        wroot.addImport("espice_h", wh.module);
        wroot.link_libc = true;
        wroot.single_threaded = true;
        const wexe = b.addExecutable(.{ .name = "espice", .root_module = wroot });
        wexe.entry = .disabled;
        wexe.rdynamic = true;
        wexe.wasi_exec_model = .reactor;
        wasm_step.dependOn(&b.addInstallArtifact(wexe, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } }).step);

        const ck = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--prefix" });
        const ck_out = ck.addOutputDirectoryArg("playground");
        // `-Dcktimg-fork=<checkout>`: build cktimg.wasm against a local cktImg.
        if (b.option([]const u8, "cktimg-fork", "wasm: a local cktImg checkout to build cktimg.wasm against")) |fork| ck.addArg(b.fmt("--fork={s}", .{fork}));
        ck.setCwd(b.path("tools/playground"));
        for ([_][]const u8{ "build.zig", "build.zig.zon", "cktimg.zig" }) |f| ck.addFileInput(b.path(b.fmt("tools/playground/{s}", .{f})));
        wasm_step.dependOn(&b.addInstallFileWithDir(ck_out.path(b, "wasm/cktimg.wasm"), .{ .custom = "wasm" }, "cktimg.wasm").step);
    }
}

/// Builds one test binary from `m`, linked like the executable.
///
/// `m` is copied rather than reused: `addObject` mutates its module, so
/// adding the device objects to a shared one linked every `arp_device_*`
/// into the exe twice, and a module that already backs an installed
/// artifact yields a test binary that runs zero tests. `devices` links the
/// per-model host objects.
const HostTest = struct {
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    objs: []const *std.Build.Step.Compile,

    fn run(self: HostTest, m: *std.Build.Module, extra: []const std.Build.Module.Import, devices: bool) *std.Build.Step.Run {
        const mod = self.b.createModule(.{
            .root_source_file = m.root_source_file,
            .target = m.resolved_target,
            .optimize = m.optimize,
            .strip = m.strip,
            .link_libc = true,
        });
        var it = m.import_table.iterator();
        while (it.next()) |e| mod.addImport(e.key_ptr.*, e.value_ptr.*);
        for (extra) |e| mod.addImport(e.name, e.module);
        // `emitKernels` wires `gompute_kernels` into the exe's root module only.
        if (self.exe.root_module.import_table.get("gompute_kernels")) |k| mod.addImport("gompute_kernels", k);
        mod.link_objects.appendSlice(self.b.allocator, m.link_objects.items) catch @panic("OOM");
        mod.include_dirs.appendSlice(self.b.allocator, m.include_dirs.items) catch @panic("OOM");
        if (devices) for (self.objs) |o| mod.addObject(o);
        const t = self.b.addTest(.{ .root_module = mod, .use_llvm = self.exe.use_llvm, .use_lld = self.exe.use_lld });
        return self.b.addRunArtifact(t);
    }
};

/// One model source under models/.
const Model = struct {
    /// File stem: the device catalog's key.
    name: []const u8,
    file: []const u8,
    hdl: enum { verilog_a, digital },
    /// Source size in bytes, the configure-time stand-in for the size of the
    /// device's eval function. Only the two GPU thresholds read it. A
    /// wrapper counts the file it includes.
    size: u64,
    /// The models/ file this one `include`s (`model_includes`), or null.
    include: ?[]const u8 = null,
};

/// Model sources that are a few defines and an `include of another models/
/// file, as upstream PSP ships psp103_nqs.va next to psp103.va. VerA gets
/// models/ as an include directory for them, and the included file becomes
/// an input of their generate step.
const model_includes = [_]struct { name: []const u8, file: []const u8 }{
    .{ .name = "psp103_nqs", .file = "psp103.va" },
    .{ .name = "bsource_i", .file = "bsource.va" },
    .{ .name = "bsource_q", .file = "bsource.va" },
    .{ .name = "vccs_laplace", .file = "vcvs_laplace.va" },
    .{ .name = "vcvs_pole", .file = "vcvs_laplace.va" },
    .{ .name = "vccs_pole", .file = "vcvs_laplace.va" },
    .{ .name = "sparam_2", .file = "sparam_1.va" },
    .{ .name = "sparam_3", .file = "sparam_1.va" },
    .{ .name = "sparam_4", .file = "sparam_1.va" },
    .{ .name = "wline_2", .file = "wline_1.va" },
    .{ .name = "wline_3", .file = "wline_1.va" },
    .{ .name = "wline_4", .file = "wline_1.va" },
    .{ .name = "coupled_ltra3", .file = "coupled_ltra.va" },
    .{ .name = "coupled_ltra4", .file = "coupled_ltra.va" },
};

/// Whether `name` is one of the comma-separated entries of `csv`.
fn inCsv(csv: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |e| {
        if (std.mem.eql(u8, std.mem.trim(u8, e, " "), name)) return true;
    }
    return false;
}

/// Source size from which a model's GPU compile runs on the chained
/// `heavy_lanes` instead of alongside the others. Must stay below
/// `gpu_max_model_bytes` to gate anything; 20 KB puts the largest admitted
/// kernels (mos9, gummel_poon, mos2) on those lanes.
const heavy_model_bytes: u64 = 20 * 1024;

/// Source size at or above which a model gets no GPU kernel. Every model in
/// `models/` fits (hisimhv_va is the largest at 601 KB), so this only guards
/// a future one. Measured on an RTX 4060 Laptop (sm_89) against an
/// i9-14900HX, 2000 parallel inverters, per device eval:
///
///   model        source   PTX      cold JIT   GPU eval   one host core
///   bsim4va      431 KB   3.6 MB     15 s       0.7 ms      7.3 ms
///   psp103       397 KB   7.8 MB     35 s       1.1 ms      ~8 ms
///   hisimhv_va   601 KB  29.3 MB   1001 s       6.3 ms     ~33 ms
///
/// The cold JIT happens once per build: the driver caches the result in
/// ~/.nv/ComputeCache (raised to 4 GiB at run time, see analysis/gpu.zig),
/// and `--backend auto` leaves an image over 1 MB of PTX on the CPU until an
/// explicit `--backend cuda` run has compiled it. Admitting them costs the
/// default build ~4 more minutes (7 min to 11-12 min on this machine).
///
/// The previous 80 KB limit assumed the kernels lose; that was before
/// held-variable models could be resident and before the fused reduce and
/// the one-wait Newton iteration.
const gpu_max_model_bytes: u64 = 1024 * 1024;

/// Extension -> generator. Verilog-A goes to vera's analog frontend; the
/// digital HDLs go to its Verilog frontend (.sv via sv2v, .vhd via ghdl).
const hdl_by_ext = [_]struct { ext: []const u8, hdl: @FieldType(Model, "hdl") }{
    .{ .ext = ".va", .hdl = .verilog_a },
    .{ .ext = ".v", .hdl = .digital },
    .{ .ext = ".sv", .hdl = .digital },
    .{ .ext = ".vhd", .hdl = .digital },
    .{ .ext = ".vhdl", .hdl = .digital },
};

/// Lists models/* sorted by stem, so builds are reproducible. Panics on two
/// sources sharing a stem, since one would silently shadow the other.
fn discoverModels(b: *std.Build) []const Model {
    const io = b.graph.io;
    var out: std.ArrayList(Model) = .empty;
    // Read at configure time: 0.17 caches the configuration, so the listing
    // and each source's size must be declared to re-run it when they change.
    b.dependOnDirectoryContents(b.path("models"));
    var dir = b.root.openDir(io, "models", .{ .iterate = true }) catch
        @panic("devices: models/ missing");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("devices: models/ iterate failed")) |e| {
        if (e.kind != .file) continue;
        const m = matchExt(e.name) orelse continue;
        b.dependOnFileMetadata(b.path(b.fmt("models/{s}", .{e.name})));
        const st = dir.statFile(io, e.name, .{}) catch @panic("devices: models/ stat failed");
        const name = e.name[0 .. e.name.len - m.ext.len];
        const include = for (model_includes) |mi| {
            if (std.mem.eql(u8, mi.name, name)) break mi.file;
        } else null;
        if (include) |f| b.dependOnFileMetadata(b.path(b.fmt("models/{s}", .{f})));
        const inc_size = if (include) |f|
            (dir.statFile(io, f, .{}) catch @panic("devices: models/ include missing")).size
        else
            0;
        out.append(b.allocator, .{
            .name = b.dupe(name),
            .file = b.dupe(e.name),
            .hdl = m.hdl,
            .size = st.size + inc_size,
            .include = include,
        }) catch @panic("OOM");
    }
    std.mem.sort(Model, out.items, {}, struct {
        fn lt(_: void, a: Model, c: Model) bool {
            return std.mem.lessThan(u8, a.name, c.name);
        }
    }.lt);
    // Sorted, so a duplicate stem is adjacent.
    if (out.items.len > 1) {
        for (out.items[1..], out.items[0 .. out.items.len - 1]) |cur, prev| {
            if (std.mem.eql(u8, cur.name, prev.name))
                std.debug.panic("devices: models/{s} and models/{s} share the stem '{s}' — " ++
                    "the device catalog keys on the stem, so one would shadow the other", .{ prev.file, cur.file, cur.name });
        }
    }
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// No extension in `hdl_by_ext` is a suffix of another, so the first match wins.
fn matchExt(file_name: []const u8) ?@TypeOf(hdl_by_ext[0]) {
    for (hdl_by_ext) |cand| {
        if (std.mem.endsWith(u8, file_name, cand.ext)) return cand;
    }
    return null;
}

/// `-Dcuda-arch`/`-Dhip-arch` as gompute options: `none`, `auto` or an arch name.
fn gpuArch(arch: []const u8) gompute_build.CudaOptions {
    if (std.mem.eql(u8, arch, "none")) return .{ .enabled = false };
    if (std.mem.eql(u8, arch, "auto")) return .{};
    return .{ .gpu = .{ .name = arch } };
}

/// Context `deviceKernelImports` receives through `emitKernels`.
const DeviceImports = struct {
    models: *std.Build.Module,
    contract: *std.Build.Module,
    device_abi: *std.Build.Module,
};

/// The imports a GPU kernel root (src/device/eval.zig) needs beyond the
/// `gompute` shim gompute adds itself. The host modules are reused as-is: a
/// device module has no target-specific code, and rebuilding it per target
/// would fork types the host and kernel must share.
fn deviceKernelImports(
    b: *std.Build,
    _: std.Build.ResolvedTarget,
    _: std.lang.Optimize,
    ctx: ?*anyopaque,
) []const std.Build.Module.Import {
    const di: *DeviceImports = @ptrCast(@alignCast(ctx.?));
    const out = b.allocator.alloc(std.Build.Module.Import, 3) catch @panic("OOM");
    out[0] = .{ .name = "models", .module = di.models };
    out[1] = .{ .name = "contract", .module = di.contract };
    out[2] = .{ .name = "device_abi", .module = di.device_abi };
    return out;
}

/// Absolute `sub_path` under `owner`'s package root (0.17 dropped
/// `Build.pathFromRoot`). The runtime loader needs these as plain strings,
/// and a dependency's root (`zig-pkg/...`, or a `--fork` checkout) is relative to the
/// build root, so it is resolved against `b`'s.
fn pathFromRoot(b: *std.Build, owner: *std.Build, sub_path: []const u8) []u8 {
    const top = b.root.root_dir.path orelse ".";
    const dep = owner.root.root_dir.path orelse ".";
    return b.pathResolve(&.{ top, b.root.sub_path, dep, owner.root.sub_path, sub_path });
}
