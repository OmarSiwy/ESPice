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
    // Mixed precision (docs/gpu-device-eval.md). A listed model gets vera's
    // `--jac-f32`, which emits `pub const jac_f32 = true`; `engine.jacFloat`
    // reads it and gives that device a `Dual` whose DERIVATIVE half is f32.
    // The residual stays f64 either way. Opt-in per model because only the
    // physics knows whether its unknowns fit in f32's ~7 digits.
    const jac_f32_list = b.option([]const u8, "jac-f32", "Comma-separated model stems to build with an f32 Jacobian") orelse "";

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
    bopts.addOption([]const u8, "dyn_path", b.pathFromRoot("src/devices/engine.zig"));
    // The runtime HDL loader rebuilds engine.zig as the .so's `dyn` module,
    // and engine.zig imports gompute — without this root the generated
    // device compiled against a moduleless import and every `.hdl` card
    // died with GeneratedDeviceDoesNotCompile.
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

    const solvers_mod = M.make(b.path("src/solvers/root.zig"), &.{});

    // =======================================================================
    // Devices: every src/devices/models/* compiled to Zig at build time
    //
    // Auto-discovered — drop a source in and it is built, whichever HDL it is
    // written in. `wf` collects every generated aggregate root: one models.zig
    // re-exporting all devices (what devices/root.zig reflects over), plus a
    // one-device models.zig per model, because a GPU kernel root must see
    // exactly the device it compiles (see kernel_roots below).
    // =======================================================================

    const models = discoverModels(b);
    const wf = b.addWriteFiles();

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
        //
        // `--check` type-checks the generated device at its .va, so a bad
        // lowering names the source instead of surfacing inside a cache file.
        if (m.hdl == .verilog_a) {
            run.addArgs(&.{"--emit-zig"});
            if (inCsv(jac_f32_list, m.name)) run.addArg("--jac-f32");
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
        run.addFileArg(b.path(b.fmt("src/devices/models/{s}", .{m.file})));

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
    }

    const models_mod = M.make(wf.add("models.zig", agg_src.items), &.{});
    for (models, dev_mods) |m, dev_mod| models_mod.addImport(m.name, dev_mod);

    const devices_mod = M.make(b.path("src/devices/root.zig"), &.{
        .{ .name = "contract", .module = contract_mod },
        .{ .name = "models", .module = models_mod },
        .{ .name = "fastvaf", .module = vera.module("vera") },
        .{ .name = "gompute", .module = gompute.module("gompute") },
    });
    // DynDevice dlopens generated .so devices.
    devices_mod.linkSystemLibrary("c", .{});

    const analysis_mod = M.make(b.path("src/analysis/root.zig"), &.{
        .{ .name = "solvers", .module = solvers_mod },
        .{ .name = "devices", .module = devices_mod },
    });
    analysis_mod.linkSystemLibrary("c", .{});

    // =======================================================================
    // The app
    // =======================================================================

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "devices", .module = devices_mod },
        .{ .name = "analysis", .module = analysis_mod },
        .{ .name = "build_options", .module = bopts.createModule() },
        // src/gpu_context.zig: the GPU launcher is APP policy (it owns when to
        // go to the device), so it lives beside the engine rather than inside
        // `devices`, and needs the driver handle and the CPU Newton it drives.
        .{ .name = "gompute", .module = gompute.module("gompute") },
        .{ .name = "solvers", .module = solvers_mod },
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
    b.installArtifact(exe);

    // GPU kernels, unconditionally: the arch probe inside `emitKernels` is what
    // decides, and a machine with no device emits nothing and stays green. This
    // is also what makes `gompute_kernels` always exist for gpu_context.zig.
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
        // root list, and `gompute_kernels` has to exist for gpu_context.zig to
        // compile and for `--backend cuda` to keep erroring by name. This is
        // the CPU-iteration build — not a shipping one, and not what
        // `zig build bench` should run.
        if (!gpu_kernels and !std.mem.eql(u8, m.name, smallest_model)) continue;
        if (m.size >= gpu_max_model_bytes) continue;
        const dev_imports = b.allocator.create(DeviceImports) catch @panic("OOM");
        dev_imports.* = .{ .models = one_mod, .contract = contract_mod };
        roots.append(b.allocator, .{
            .name = m.name,
            .root = b.path("src/devices/kernels.zig"),
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
    // tests/test_all.zig crosses a MODULE boundary, so those tests are silently
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

    const test_step = b.step("test", "Run every test suite");

    const app_tests = b.addTest(.{ .root_module = M.make(b.path("tests/test_all.zig"), &.{
        .{ .name = "analysis", .module = analysis_mod },
        .{ .name = "devices", .module = devices_mod },
        .{ .name = "builder", .module = M.make(b.path("src/builder.zig"), &.{
            .{ .name = "analysis", .module = analysis_mod },
            .{ .name = "devices", .module = devices_mod },
        }) },
    }) });
    // Match production: Zig 0.16's native backend miscompiles reused FP comparisons.
    app_tests.use_llvm = exe.use_llvm;
    app_tests.use_lld = exe.use_lld;
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    // The app layer, as its own test root. tests/test_all.zig cannot reach it:
    // main.zig, engine.zig, gpu_context.zig and frontend/ live in the
    // executable's root module, and `zig test` only collects from the root
    // module's file set. Without this the whole app layer — netlist -> jobs ->
    // results, and the parser's own tests — never ran.
    //
    // A FRESH module, not `exe.root_module`: handing addTest a module that
    // already backs an installed artifact silently produced a binary that ran
    // zero tests (a deliberately-broken assertion still passed).
    const exe_tests = b.addTest(.{ .root_module = M.make(b.path("src/main.zig"), app_imports) });
    // `emitKernels` wires `gompute_kernels` into the HOST artifact's root module
    // only, and gpu_context.zig imports it by name — so a second root module
    // over the same files needs the same import or it will not compile.
    if (exe.root_module.import_table.get("gompute_kernels")) |artifacts|
        exe_tests.root_module.addImport("gompute_kernels", artifacts);
    exe_tests.use_llvm = exe.use_llvm;
    exe_tests.use_lld = exe.use_lld;
    const run_exe_tests = b.addRunArtifact(exe_tests);
    b.step("test-app", "Run the executable's own tests").dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_exe_tests.step);

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

    // =======================================================================
    // Benchmark (still its own package — it is fixtures and a runner, not a
    // source tree that belongs under src/)
    // =======================================================================

    const bench_runner = b.dependency("benchmark", .{
        .target = target,
        .optimize = optimize,
    }).artifact("bench-runner");
    const run_bench = b.addRunArtifact(bench_runner);
    run_bench.step.dependOn(b.getInstallStep());
    // Install lazily — only the bench step pays for the bench-runner build.
    run_bench.step.dependOn(&b.addInstallArtifact(bench_runner, .{}).step);
    run_bench.stdio = .inherit;
    run_bench.setCwd(b.path("."));
    run_bench.addArtifactArg(exe);
    run_bench.addArg("benchmark/fixtures");
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);

    const fixtures = b.addSystemCommand(&.{ "python3", "benchmark/check_fixtures.py", "--engine" });
    fixtures.setCwd(b.path("."));
    fixtures.addArtifactArg(exe);
    if (b.args) |args| fixtures.addArgs(args);
    b.step("test-fixtures", "Validate analysis or generated SKY130 fixtures").dependOn(&fixtures.step);
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
// module.
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
