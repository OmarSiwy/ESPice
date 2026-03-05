const std = @import("std");
const gompute_build = @import("gompute");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast by DEFAULT: this is a numerical simulator whose proof rule
    // ships bench numbers in commit messages — an accidental Debug `zig build
    // bench` benchmarked a Debug espice against -O2 ngspice and every CPU
    // column in RESULTS.md was ~10-40x pessimistic. Debug stays one
    // `-Doptimize=Debug` away. (Not `standardOptimizeOption`: in 0.16 its
    // preferred mode only rides the `-Drelease` flag; the default stays Debug.)
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;
    // Mixed precision (docs/perf/jac-width-2026-09-10.md). Two lists, because
    // the f32 Jacobian is worth 1.21x on a GPU and −6.4%/+13.7% (deck
    // depending) on this CPU, and the width is a property of the
    // INSTANTIATION, not of the device.
    //
    // `-Djac-f32-gpu` — the PERMISSION. A listed model gets vera's
    // `--jac-f32` ⇒ `pub const jac_f32 = true`, which `engine.gpuJacFloat`
    // takes in the device kernel and `engine.jacFloat` declines on the host.
    // Default is the measured set: mos1 (GPU 1.21x, agreeing to 3.9e-10) and
    // mos6 (same n_u = 8, same U set, same accuracy sweep). Everything else
    // stays f64 on both paths — `diode` and `bsim4va` are excluded by
    // measurement, not by caution.
    const jac_f32_gpu_list = b.option([]const u8, "jac-f32-gpu", "Comma-separated model stems whose physics permits an f32 Jacobian (GPU kernel takes it)") orelse "mos1,mos6";
    // `-Djac-f32` — the HOST ORDER, and it still means exactly what it meant
    // when the CPU numbers were taken: these stems run f32 on the CPU too.
    // Now spelled `--jac-f32-host`, which implies the permission, so
    // `-Djac-f32=mos1,mos6` reproduces the old build bit for bit.
    const jac_f32_list = b.option([]const u8, "jac-f32", "Comma-separated model stems to ALSO build with an f32 Jacobian on the CPU path") orelse "";

    const gompute = b.dependency("gompute", .{});
    const vera = b.dependency("vera", .{ .target = target, .optimize = optimize });
    const contract_mod = vera.module("contract");
    const vera_exe = b.dependency("vera", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }).artifact("vera");

    const bopts = b.addOptions();
    bopts.addOption([]const u8, "src_root", b.build_root.path orelse ".");
    bopts.addOption([]const u8, "contract_path", vera.builder.pathFromRoot("tools/contract.zig"));
    bopts.addOption([]const u8, "dyn_path", b.pathFromRoot("src/analysis/eval.zig"));
    // The runtime HDL loader rebuilds engine.zig as the .so's `dyn` module,
    // and engine.zig imports gompute — without this root the generated
    // device compiled against a moduleless import and every `.hdl` card
    // died with GeneratedDeviceDoesNotCompile.
    bopts.addOption([]const u8, "device_ir_path", b.pathFromRoot("src/problem/device_ir.zig"));
    bopts.addOption([]const u8, "gompute_path", gompute.builder.pathFromRoot("src/root.zig"));

    // Every module in this tree is (root file, target, optimize) plus imports.
    //
    // strip in Release: DWARF maintenance is ~2/3 of the LLVM compile
    // (measured /tmp/audit-llvm-time.md: 737 s espice compile ≈ 490 s of
    // O3-with-debug-info; the DI cost is SUPERLINEAR in function size —
    // exponent 2.0 vs 1.2 stripped on the whale models — and the shipped
    // binary carried 115 MB of DWARF, 96 MB of it .debug_loc). Debug keeps
    // full DI on the fast self-hosted backend; `-Ddebug-info` forces it
    // back on in Release when a symbolized profile is worth the wait.
    const debug_info = b.option(bool, "debug-info", "Emit DWARF in Release builds (slow: ~3x LLVM time)") orelse false;
    // Compiling 38 device models for NVPTX and AMDGCN is most of a full build.
    // `-Dgpu=false` is the CPU-measurement/iteration build; it is NOT a shipping
    // configuration and not what `zig build bench` should run.
    const gpu_kernels = b.option(bool, "gpu", "Compile the GPU device kernels (default true)") orelse true;
    const M = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        strip: bool,
        fn make(
            self: @This(),
            root: std.Build.LazyPath,
            imports: []const std.Build.Module.Import,
        ) *std.Build.Module {
            return self.b.createModule(.{
                .root_source_file = root,
                .target = self.target,
                .optimize = self.optimize,
                .strip = self.strip,
                .imports = imports,
            });
        }
    }{ .b = b, .target = target, .optimize = optimize, .strip = optimize != .Debug and !debug_info };
    // Same maker, strip PINNED on: for modules that also cross into the
    // NVPTX/AMDGCN kernel builds. See gpu_dev_mod below.
    const GPU = @TypeOf(M){ .b = b, .target = target, .optimize = optimize, .strip = true };

    const build_options_mod = bopts.createModule();

    const numerics_mod = M.make(b.path("src/problem/numerics.zig"), &.{});
    const device_ir_mod = M.make(b.path("src/problem/device_ir.zig"), &.{.{ .name = "contract", .module = contract_mod }});
    const requests_mod = M.make(b.path("src/problem/requests.zig"), &.{
        .{ .name = "numerics", .module = numerics_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
    });
    const problem_types_mod = M.make(b.path("src/problem/types.zig"), &.{
        .{ .name = "numerics", .module = numerics_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
        .{ .name = "requests", .module = requests_mod },
    });
    const device_eval_mod = M.make(b.path("src/analysis/eval.zig"), &.{
        .{ .name = "contract", .module = contract_mod },
        .{ .name = "gompute", .module = gompute.module("gompute") },
        .{ .name = "device_ir", .module = device_ir_mod },
    });
    device_eval_mod.link_libc = true;
    const solvers_mod = M.make(b.path("src/analysis/solvers/root.zig"), &.{.{ .name = "numerics", .module = numerics_mod }});

    // Waveform writers. A leaf like `solvers`: it imports nothing but std, so
    // it is a module rather than a set of files in the app root, and
    // `zig build test-output` runs it without building the simulator.
    const output_types_mod = M.make(b.path("src/output/types.zig"), &.{});
    const output_mod = M.make(b.path("src/output/root.zig"), &.{.{ .name = "output_types", .module = output_types_mod }});

    // Netlist front end. Also a std-only leaf — `builder` consumes its
    // `types.Netlist`, but nothing in it reaches back into the simulator.
    const syntax_mod = M.make(b.path("src/frontend/syntax.zig"), &.{});
    const frontend_bench = b.addExecutable(.{
        .name = "frontend-bench",
        .use_llvm = optimize != .Debug,
        .root_module = M.make(b.path("tests/benchmark/frontend.zig"), &.{.{ .name = "syntax", .module = syntax_mod }}),
    });
    const run_frontend_bench = b.addRunArtifact(frontend_bench);
    if (b.args) |args| run_frontend_bench.addArgs(args);
    b.step("bench-frontend", "Measure netlist parsing and expansion").dependOn(&run_frontend_bench.step);

    // =======================================================================
    // Devices: every models/* compiled to Zig at build time
    //
    // Auto-discovered — drop a source in and it is built, whichever HDL it is
    // written in. `wf` collects every generated aggregate root: one models.zig
    // re-exporting all devices (what frontend/models.zig reflects over), plus a
    // one-device models.zig per model, because a GPU kernel root must see
    // exactly the device it compiles (see kernel_roots below).
    // =======================================================================

    const models = discoverModels(b);
    const wf = b.addWriteFiles();

    var agg_src: std.ArrayList(u8) = .empty;
    agg_src.appendSlice(b.allocator, "//! Generated — build-time HDL device models.\n") catch @panic("OOM");

    const dev_mods = b.allocator.alloc(*std.Build.Module, models.len) catch @panic("OOM");
    const one_models = b.allocator.alloc(*std.Build.Module, models.len) catch @panic("OOM");
    // One HOST object per model, the CPU counterpart of the per-model GPU
    // kernel roots below. Every `DeviceBatch(D)` used to be instantiated inside
    // the single `zig build-exe` that also holds solvers/analysis/app, so Zig
    // cached all 38 whale evals as ONE unit: a one-line solver edit recompiled
    // the lot, single-threaded, on a 32-core box. See
    // docs/perf/build-split-2026-09-10.md and src/analysis/eval.zig.
    const host_objs = b.allocator.alloc(*std.Build.Step.Compile, models.len + 1) catch @panic("OOM");
    for (models, 0..) |m, i| {
        const run = b.addRunArtifact(vera_exe);
        // The catalog keys devices by FILE stem while the generated type name
        // comes from the MODULE name; both frontends fail on a mismatch.
        run.addArg(b.fmt("--expect-module={s}", .{m.name}));
        // Verilog-A only: the Verilog frontend is a translator with two flags
        // and rejects the rest rather than pretending to honour them.
        //
        // `--check` type-checks the generated device at its .va, so a bad
        // lowering names the source instead of surfacing inside a cache file.
        if (m.hdl == .verilog_a) {
            run.addArgs(&.{"--emit-zig"});
            if (inCsv(jac_f32_gpu_list, m.name)) run.addArg("--jac-f32");
            if (inCsv(jac_f32_list, m.name)) run.addArg("--jac-f32-host");
            // W0650 (unit not provably finite -> strict float) predates the
            // current vera on several models; the empty-stderr gate would
            // otherwise fail any model that regenerates. Strict mode is
            // correct, just unvectorized — re-prove models (teach the prover
            // $limit's bound) when device-eval speed is the open front.
            // W0651: upstream .va ports use closed-infinity ranges; W0850:
            // hisim-class models $display in the device artifact. Both are
            // pre-existing; same re-prove pass as W0650 owns them.
            run.addArgs(&.{ "--allow=W0650", "--allow=W0651", "--allow=W0850", "--color=never", "--check", "--contract" });
            run.addFileArg(vera.path("tools/contract.zig"));
        }
        run.addArg("-o");
        const gen_zig = run.addOutputFileArg(b.fmt("{s}.zig", .{m.name}));
        run.addFileArg(b.path(b.fmt("models/{s}", .{m.file})));

        // ALWAYS stripped, `-Ddebug-info` included. DWARF over generated code
        // maps to a cache file nobody reads, and the DI cost is superlinear in
        // function size (build.zig's strip header) — the whale models ARE the
        // superlinear tail, which made `-Ddebug-info=true` a ~1 h build for a
        // profile whose interesting frames are all in src/. The device symbol
        // still names itself; only its line table goes.
        dev_mods[i] = GPU.make(gen_zig, &.{.{ .name = "contract", .module = contract_mod }});

        const one_line = b.fmt("pub const {s} = @import(\"{s}\");\n", .{ m.name, m.name });
        agg_src.appendSlice(b.allocator, one_line) catch @panic("OOM");

        // Also `GPU.make`: this one crosses into the NVPTX/AMDGCN builds, and
        // -Ddebug-info=true crashed `zig build-obj -target nvptx64-cuda` (SEGV
        // in DWARF emission for mos2/vdmos), so the one build mode the
        // profiling doc names was unusable.
        one_models[i] = GPU.make(wf.add(b.fmt("{s}/models.zig", .{m.name}), one_line), &.{});
        one_models[i].addImport(m.name, dev_mods[i]);

        // The one-device object: `engine.deviceVtable(D)` and everything it
        // pulls — ProtoStore, DeviceBatch, eval, hooks — under the runtime ABI
        // symbol `arp_device_<stem>`. Same `one_models` aggregate the GPU
        // kernel root gets, so host and device compile the SAME device type.
        const host_mod = M.make(b.path("src/analysis/eval.zig"), &.{
            .{ .name = "contract", .module = contract_mod },
            .{ .name = "models", .module = one_models[i] },
            .{ .name = "device_ir", .module = device_ir_mod },
            .{ .name = "gompute", .module = gompute.module("gompute") },
        });
        // engine.zig's runtime-`.so` half dlopens; matches devices_mod.
        host_mod.link_libc = true;
        host_objs[i] = b.addObject(.{ .name = b.fmt("dev_{s}", .{m.name}), .root_module = host_mod });
        // Same reason the executable does it: the self-hosted backend has no
        // optimizer, whatever the optimize mode claims (see `exe.use_llvm`).
        host_objs[i].use_llvm = optimize != .Debug;
    }

    // Native line algorithms retain their own accepted-step history. Export
    // the existing neutral vtables from a CPU object, as for generated models.
    const native_models_mod = M.make(b.path("models/native/root.zig"), &.{.{ .name = "contract", .module = contract_mod }});
    inline for (.{ "ltra_native", "txl_native", "cpl_native_2", "cpl_native_3", "cpl_native_4" }) |name|
        agg_src.appendSlice(b.allocator, b.fmt("pub const {s} = @import(\"native_models\").{s};\n", .{ name, name })) catch @panic("OOM");
    const native_host_mod = M.make(b.path("src/analysis/eval.zig"), &.{
        .{ .name = "contract", .module = contract_mod },
        .{ .name = "models", .module = native_models_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
        .{ .name = "gompute", .module = gompute.module("gompute") },
    });
    native_host_mod.link_libc = true;
    host_objs[models.len] = b.addObject(.{ .name = "dev_native_lines", .root_module = native_host_mod });
    host_objs[models.len].use_llvm = optimize != .Debug;

    const models_mod = M.make(wf.add("models.zig", agg_src.items), &.{});
    models_mod.addImport("native_models", native_models_mod);
    for (models, dev_mods) |m, dev_mod| models_mod.addImport(m.name, dev_mod);

    const devices_mod = M.make(b.path("src/frontend/models.zig"), &.{
        .{ .name = "models", .module = models_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
        .{ .name = "fastvaf", .module = vera.module("vera") },
    });
    // DynDevice dlopens generated .so devices.
    devices_mod.linkSystemLibrary("c", .{});

    const analysis_mod = M.make(b.path("src/analysis/root.zig"), &.{
        .{ .name = "models", .module = models_mod },
        .{ .name = "solvers", .module = solvers_mod },
        .{ .name = "numerics", .module = numerics_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
        .{ .name = "device_eval", .module = device_eval_mod },
        .{ .name = "problem_types", .module = problem_types_mod },
        .{ .name = "requests", .module = requests_mod },
        .{ .name = "output_types", .module = output_types_mod },
        .{ .name = "gompute", .module = gompute.module("gompute") },
    });
    analysis_mod.linkSystemLibrary("c", .{});

    // Passive circuit construction is shared by the frontend and its tests.
    const builder_mod = M.make(b.path("src/frontend/builder.zig"), &.{
        .{ .name = "problem_types", .module = problem_types_mod },
        .{ .name = "requests", .module = requests_mod },
        .{ .name = "numerics", .module = numerics_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
        .{ .name = "devices", .module = devices_mod },
        .{ .name = "syntax", .module = syntax_mod },
    });
    const frontend_mod = M.make(b.path("src/frontend/root.zig"), &.{
        .{ .name = "numerics", .module = numerics_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
        .{ .name = "problem_types", .module = problem_types_mod },
        .{ .name = "requests", .module = requests_mod },
        .{ .name = "syntax", .module = syntax_mod },
        .{ .name = "builder", .module = builder_mod },
        .{ .name = "device_models", .module = devices_mod },
        .{ .name = "build_options", .module = build_options_mod },
    });

    // The owning facade composes frontend preparation, analysis and output.
    const problem_imports: []const std.Build.Module.Import = &.{
        .{ .name = "analysis", .module = analysis_mod },
        .{ .name = "frontend", .module = frontend_mod },
        .{ .name = "requests", .module = requests_mod },
        .{ .name = "problem_types", .module = problem_types_mod },
        .{ .name = "output", .module = output_mod },
    };
    const problem_mod = M.make(b.path("src/problem/root.zig"), problem_imports);

    // =======================================================================
    // The app
    // =======================================================================

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "output", .module = output_mod },
        .{ .name = "problem", .module = problem_mod },
    };
    const exe = b.addExecutable(.{
        .name = "espice",
        .root_module = M.make(b.path("src/main.zig"), app_imports),
    });
    exe.root_module.link_libc = true;
    // Backend follows the optimize mode: the self-hosted x86 backend compiles
    // fast but emits UNOPTIMIZED code whatever the mode says — a "ReleaseFast"
    // espice off it benchmarked 10-40x behind ngspice while the profile showed
    // plain scalar device eval. Debug keeps the fast-iterating self-hosted
    // backend; any Release* goes through LLVM, which is the only backend with
    // an optimizer. Tests stay self-hosted below — correctness needs no
    // optimizer and the compile-time win is the whole point there.
    exe.use_llvm = optimize != .Debug;
    exe.use_lld = optimize != .Debug;
    for (host_objs) |o| exe.root_module.addObject(o);
    b.installArtifact(exe);

    // GPU kernels, unconditionally: the arch probe inside `emitKernels` is what
    // decides, and a machine with no device emits nothing and stays green. This
    // is also what makes `gompute_kernels` always exist for analysis/gpu.zig.
    // Emission sits below the executable because `emitKernels` takes it.
    const smallest_model = blk: {
        var best = models[0];
        for (models) |m| if (m.size < best.size) {
            best = m;
        };
        break :blk best.name;
    };
    var roots: std.ArrayList(gompute_build.KernelRoot) = .empty;
    for (models, one_models) |m, one_mod| {
        // `-Dgpu=false` compiles ONE model for the GPU instead of all 38, which
        // is the bulk of a full build. Not zero: gompute panics on an empty
        // root list, and `gompute_kernels` has to exist for analysis/gpu.zig to
        // compile and for `--backend cuda` to keep erroring by name. This is
        // the CPU-iteration build — not a shipping one, and not what
        // `zig build bench` should run.
        if (!gpu_kernels and !std.mem.eql(u8, m.name, smallest_model)) continue;
        if (m.size >= gpu_max_model_bytes) continue;
        const dev_imports = b.allocator.create(DeviceImports) catch @panic("OOM");
        dev_imports.* = .{ .models = one_mod, .contract = contract_mod, .device_ir = device_ir_mod };
        roots.append(b.allocator, .{
            .name = m.name,
            .root = b.path("src/analysis/eval.zig"),
            .imports = &deviceKernelImports,
            .imports_ctx = dev_imports,
            // The compact models are single enormous eval functions; letting
            // them all compile at once is a memory problem, not a speedup.
            .heavy = m.size >= heavy_model_bytes,
        }) catch @panic("OOM");
    }
    gompute_build.emitKernels(b, gompute, exe, .{
        .kernel_roots = roots.items,
        .heavy_lanes = 2,
        .target = target,
        // HIP is PINNED, CUDA is probed. `.auto` asks the BUILD machine, so on
        // a dev box with an NVIDIA card it found no AMD device and compiled the
        // hip backend out — silently making `--backend hip` a hard error in
        // every binary shipped from here, whatever the deploy machine has.
        // gfx1100 (RDNA3) is the baseline we claim; a CUDA build still probes
        // because the probe succeeds here and pinning would freeze sm_89 in.
        .hip = .{ .gpu = .{ .name = "gfx1100" } },
        // measured 443s vs 13.6s for hisimhv_va.
        .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
    });

    const c_api_mod = M.make(b.path("src/problem/c_api.zig"), &.{.{ .name = "problem", .module = problem_mod }});
    c_api_mod.link_libc = true;
    for (host_objs) |o| c_api_mod.addObject(o);
    const c_api_lib = b.addLibrary(.{ .name = "espice", .linkage = .static, .root_module = c_api_mod });
    c_api_lib.use_llvm = exe.use_llvm;
    c_api_lib.use_lld = exe.use_lld;
    b.installArtifact(c_api_lib);
    c_api_lib.installHeader(b.path("include/espice.h"), "espice.h");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ESPice").dependOn(&run_cmd.step);

    // The generator, on demand. One step now that one binary handles every HDL.
    const run_vera = b.addRunArtifact(vera_exe);
    if (b.args) |args| run_vera.addArgs(args);
    b.step("vera", "Run the vera CLI (any .va/.v/.sv/.vhd)").dependOn(&run_vera.step);

    // =======================================================================
    // Tests
    //
    // One test root PER MODULE, because `zig test` collects tests only from the
    // root module's own file set. A `_ = @import("analysis")` inside
    // A cross-module import crosses a MODULE boundary, so tests are silently
    // dropped — measured: importing all five modules there added ZERO tests,
    // which is exactly how a green suite hides a whole engine going untested.
    //
    // WITHIN a module, one root is enough: every root.zig ends in a
    // `test { _ = <each sibling>; }` aggregator, so the module root pulls its
    // files in. That is what collapses FastVAF's 17 per-file test binaries into
    // one, and the tree from 22 test executables to 6.
    //
    // The Verilog-A conformance and exhaustive oracles live in VerA with the
    // fixtures they read — they test the compiler, not the simulator:
    //   cd ../VerA && zig build conformance
    //   cd ../VerA && zig build exhaustive
    // =======================================================================

    const test_step = b.step("test", "Run Problem contracts and numeric SPICE fixtures");

    const c_api_test_mod = M.make(b.path("src/problem/tests/c_api.zig"), &.{});
    c_api_test_mod.link_libc = true;
    c_api_test_mod.addIncludePath(b.path("include"));
    c_api_test_mod.linkLibrary(c_api_lib);
    const c_api_tests = b.addTest(.{ .root_module = c_api_test_mod });
    c_api_tests.use_llvm = exe.use_llvm;
    c_api_tests.use_lld = exe.use_lld;
    const run_c_api_tests = b.addRunArtifact(c_api_tests);
    b.step("test-c-api", "Run C ABI boundary tests").dependOn(&run_c_api_tests.step);

    // The app layer has its own test root:
    // main.zig and frontend/ used to live in the
    // executable's root module, and `zig test` only collects from the root
    // module's file set. Without this the whole app layer — netlist -> jobs ->
    // results, and the parser's own tests — never ran.
    //
    // A FRESH module, not `exe.root_module`: handing addTest a module that
    // already backs an installed artifact silently produced a binary that ran
    // zero tests (a deliberately-broken assertion still passed).
    const exe_tests = b.addTest(.{ .root_module = M.make(b.path("src/main.zig"), app_imports) });
    // `emitKernels` wires `gompute_kernels` into the HOST artifact's root module
    // only, and analysis/gpu.zig imports it by name — so a second root module
    // over the same files needs the same import or it will not compile.
    // `problem_mod` is declared before emitKernels runs, so it is wired here
    // too rather than at its declaration.
    if (exe.root_module.import_table.get("gompute_kernels")) |artifacts| {
        exe_tests.root_module.addImport("gompute_kernels", artifacts);
        analysis_mod.addImport("gompute_kernels", artifacts);
    }
    exe_tests.use_llvm = exe.use_llvm;
    exe_tests.use_lld = exe.use_lld;
    for (host_objs) |o| exe_tests.root_module.addObject(o);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    b.step("test-app", "Run the executable's own tests").dependOn(&run_exe_tests.step);

    // The engine does NOT ride the generic suite loop: it drives real solves, so
    // builder resolves generated devices through `arp_device_*` and the binary
    // has to link the same host objects the exe does, on the same backend.
    // A FRESH module, not `problem_mod`: `addObject` MUTATES the module it is
    // called on, so adding the device objects to the shared one put them in the
    // exe as well and every `arp_device_*` linked twice. Same reason exe_tests
    // builds its own root.
    const problem_test_mod = M.make(b.path("src/problem/tests/problem.zig"), &.{.{ .name = "problem", .module = problem_mod }});
    if (exe.root_module.import_table.get("gompute_kernels")) |artifacts|
        problem_test_mod.addImport("gompute_kernels", artifacts);
    const problem_tests = b.addTest(.{ .root_module = problem_test_mod });
    problem_tests.use_llvm = exe.use_llvm;
    problem_tests.use_lld = exe.use_lld;
    for (host_objs) |o| problem_test_mod.addObject(o);
    const run_problem_tests = b.addRunArtifact(problem_tests);
    const test_problem_step = b.step("test-problem", "Run Problem, C ABI and numerical contract tests");
    test_problem_step.dependOn(&run_problem_tests.step);
    test_problem_step.dependOn(&run_c_api_tests.step);
    test_step.dependOn(test_problem_step);

    const numerical_tests = b.addTest(.{
        .root_module = M.make(b.path("src/problem/tests/numerics.zig"), &.{.{ .name = "numerics", .module = numerics_mod }}),
    });
    const run_numerical_tests = b.addRunArtifact(numerical_tests);
    b.step("test-numerics", "Run numerical contract tests").dependOn(&run_numerical_tests.step);
    test_problem_step.dependOn(&run_numerical_tests.step);

    const prepared_test_mod = M.make(b.path("src/frontend/root.zig"), &.{
        .{ .name = "syntax", .module = syntax_mod },
        .{ .name = "builder", .module = builder_mod },
        .{ .name = "device_models", .module = devices_mod },
        .{ .name = "problem_types", .module = problem_types_mod },
        .{ .name = "requests", .module = requests_mod },
        .{ .name = "numerics", .module = numerics_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
        .{ .name = "build_options", .module = build_options_mod },
    });
    const prepared_tests = b.addTest(.{ .root_module = prepared_test_mod });
    prepared_tests.use_llvm = exe.use_llvm;
    prepared_tests.use_lld = exe.use_lld;
    for (host_objs) |o| prepared_test_mod.addObject(o);
    const run_prepared = b.addRunArtifact(prepared_tests);
    b.step("test-prepared", "Run source and prepared-circuit tests").dependOn(&run_prepared.step);

    const limiter_gen = b.addRunArtifact(vera_exe);
    limiter_gen.addArgs(&.{ "--emit-zig", "--allow=W0650", "-o" });
    const limiter_source = limiter_gen.addOutputFileArg("va_limit_state.zig");
    limiter_gen.addFileArg(b.path("tests/fixtures/hdl/veriloga_limit.assets/va_limit_state.va"));
    const limiter_mod = M.make(limiter_source, &.{.{ .name = "contract", .module = contract_mod }});
    const analysis_test_mod = M.make(b.path("src/analysis/root.zig"), &.{});
    var analysis_imports = analysis_mod.import_table.iterator();
    while (analysis_imports.next()) |entry| analysis_test_mod.addImport(entry.key_ptr.*, entry.value_ptr.*);
    analysis_test_mod.addImport("builder", builder_mod);
    analysis_test_mod.addImport("limiter_device", limiter_mod);
    analysis_test_mod.link_libc = true;
    const analysis_tests = b.addTest(.{ .root_module = analysis_test_mod });
    for (host_objs) |o| analysis_tests.root_module.addObject(o);
    const run_analysis = b.addRunArtifact(analysis_tests);
    b.step("test-analysis", "Run all analysis tests").dependOn(&run_analysis.step);
    b.step("test-iteration", "Run analysis tests including Newton lifecycle integration").dependOn(&run_analysis.step);
    test_step.dependOn(&run_analysis.step);

    const native_tests_mod = M.make(b.path("models/native/root.zig"), &.{.{ .name = "contract", .module = contract_mod }});
    native_tests_mod.link_libc = true;
    const native_tests = b.addTest(.{ .root_module = native_tests_mod });
    const run_native = b.addRunArtifact(native_tests);
    b.step("test-native-lines", "Run native transmission-line oracle tests").dependOn(&run_native.step);
    test_step.dependOn(&run_native.step);

    const eval_tests_mod = M.make(b.path("src/analysis/tests/eval.zig"), &.{.{ .name = "device_eval", .module = device_eval_mod }});
    // A separate object is essential: Zig error ordinals differ between
    // compilations even when the callback signatures use the same error set.
    const error_object_mod = M.make(b.path("src/analysis/tests/device_errors_object.zig"), &.{
        .{ .name = "device_eval", .module = device_eval_mod },
        .{ .name = "device_ir", .module = device_ir_mod },
    });
    error_object_mod.link_libc = true;
    const error_object = b.addObject(.{ .name = "device_errors", .root_module = error_object_mod, .use_llvm = optimize != .Debug });
    const error_tests_mod = M.make(b.path("src/analysis/tests/device_errors.zig"), &.{.{ .name = "device_ir", .module = device_ir_mod }});
    error_tests_mod.link_libc = true;
    error_tests_mod.addObject(error_object);
    const error_tests = b.addTest(.{ .root_module = error_tests_mod, .use_llvm = optimize != .Debug });
    const run_error_tests = b.addRunArtifact(error_tests);
    b.step("test-device-errors", "Check separately compiled device callback statuses").dependOn(&run_error_tests.step);
    test_step.dependOn(&run_error_tests.step);

    const solver_tests_mod = M.make(b.path("src/analysis/tests/solvers.zig"), &.{.{ .name = "solvers", .module = solvers_mod }});
    solver_tests_mod.link_libc = true;

    const frontend_syntax_tests = M.make(b.path("src/frontend/tests/syntax.zig"), &.{.{ .name = "syntax", .module = syntax_mod }});
    const frontend_builder_tests = M.make(b.path("src/frontend/tests/builder.zig"), &.{
        .{ .name = "syntax", .module = syntax_mod },
        .{ .name = "builder", .module = builder_mod },
        .{ .name = "device_models", .module = devices_mod },
    });
    const frontend_model_tests = M.make(b.path("src/frontend/tests/models.zig"), &.{.{ .name = "device_models", .module = devices_mod }});

    for ([_]struct { name: []const u8, desc: []const u8, mod: *std.Build.Module }{
        .{ .name = "test-output", .desc = "Run waveform writer tests", .mod = output_mod },
        .{ .name = "test-frontend", .desc = "Run netlist front-end tests", .mod = frontend_syntax_tests },
        .{ .name = "test-eval", .desc = "Run evaluation tests", .mod = eval_tests_mod },
        .{ .name = "test-builder", .desc = "Run netlist -> Circuit builder tests", .mod = frontend_builder_tests },
        .{ .name = "test-solvers", .desc = "Run solver tests", .mod = solver_tests_mod },
        // Building this at all pulls every models/* through vera.
        .{ .name = "test-devices", .desc = "Run device tests", .mod = frontend_model_tests },
    }) |suite| {
        const suite_tests = b.addTest(.{ .root_module = suite.mod });
        if (suite.mod == frontend_builder_tests)
            for (host_objs) |obj| suite_tests.root_module.addObject(obj);
        const run = b.addRunArtifact(suite_tests);
        b.step(suite.name, suite.desc).dependOn(&run.step);
    }

    // Both runners receive the same recursively discovered compile-time catalog.
    const fixture_catalog = @import("tests/fixture_catalog.zig").create(b);
    const fixture_imports: []const std.Build.Module.Import = &.{.{ .name = "fixture_catalog", .module = fixture_catalog }};
    const correctness = b.addExecutable(.{
        .name = "test-correctness",
        .root_module = M.make(b.path("tests/test_correctness.zig"), fixture_imports),
    });
    const run_correctness = b.addRunArtifact(correctness);
    run_correctness.setCwd(b.path("."));
    run_correctness.addArtifactArg(exe);
    if (b.args) |args| run_correctness.addArgs(args);
    test_step.dependOn(&run_correctness.step);

    const harness_tests = b.addTest(.{ .root_module = M.make(b.path("tests/test_correctness.zig"), fixture_imports) });
    const run_harness_tests = b.addRunArtifact(harness_tests);
    run_harness_tests.setCwd(b.path("."));
    run_correctness.step.dependOn(&run_harness_tests.step);

    const bench_runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = M.make(b.path("tests/benchmark/runner.zig"), fixture_imports),
    });
    const run_bench = b.addRunArtifact(bench_runner);
    run_bench.stdio = .inherit;
    run_bench.setCwd(b.path("."));
    run_bench.addArtifactArg(exe);
    run_bench.addArg("tests/fixtures");
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Compare ESPice with ngspice and VACASK (nix develop .#benchmarking)").dependOn(&run_bench.step);
    const bench_tests = b.addTest(.{ .root_module = M.make(b.path("tests/benchmark/runner.zig"), fixture_imports) });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    b.step("test-benchmark", "Test reference adapters and benchmark comparison").dependOn(&run_bench_tests.step);
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
    /// Source bytes. Only used for the two GPU thresholds below — a stand-in
    /// for "how big is this device's eval function", which is not knowable at
    /// configure time and which source size tracks closely enough.
    size: u64,
};

/// Is `name` one of the comma-separated entries of `csv`? (`-Djac-f32=a,b`.)
fn inCsv(csv: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |e| {
        if (std.mem.eql(u8, std.mem.trim(u8, e, " "), name)) return true;
    }
    return false;
}

/// Source size past which a model's GPU compilation is `heavy` — chained into
/// `heavy_lanes` rather than run alongside every other big one.
///
/// MUST sit under `gpu_max_model_bytes` or it gates nothing: at the old
/// 100 KB no admitted root could ever be heavy (everything ≥ 80 KB is
/// excluded outright), so `heavy_lanes` and the memory-protection chaining
/// silently never engaged. 20 KB puts the largest admitted kernels
/// (mos9/bjt at 20 KB, mos2 at 24 KB) on the chained lanes.
const heavy_model_bytes: u64 = 20 * 1024;

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
    var dir = b.build_root.handle.openDir(io, "models", .{ .iterate = true }) catch
        @panic("devices: models/ missing");
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
// module.
// ===========================================================================

/// What `deviceKernelImports` needs, passed through `emitKernels` untouched.
const DeviceImports = struct {
    models: *std.Build.Module,
    contract: *std.Build.Module,
    device_ir: *std.Build.Module,
};

/// `src/analysis/eval.zig` reaches the device catalog through `models`, and
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
    const out = b.allocator.alloc(std.Build.Module.Import, 3) catch @panic("OOM");
    out[0] = .{ .name = "models", .module = di.models };
    out[1] = .{ .name = "contract", .module = di.contract };
    out[2] = .{ .name = "device_ir", .module = di.device_ir };
    return out;
}
