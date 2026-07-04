const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared codegen helpers (identifier legality, contract footer).
    const emit_mod = b.addModule("emit", .{
        .root_source_file = b.path("src/emit.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Verilog-A pipeline.
    const zvaf_mod = b.addModule("zvaf", .{
        .root_source_file = b.path("src/va/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "emit", .module = emit_mod }},
    });
    // Verilog / SystemVerilog pipeline.
    const zvf_mod = b.addModule("zvf", .{
        .root_source_file = b.path("src/v/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "emit", .module = emit_mod }},
    });
    // Unified facade.
    const fastvaf_mod = b.addModule("fastvaf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zvaf", .module = zvaf_mod },
            .{ .name = "zvf", .module = zvf_mod },
        },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "fastvaf",
        .root_module = fastvaf_mod,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run unit tests");

    // Root + sub-module unit tests (pull in codegen/verilator/frontend tests).
    for ([_]*std.Build.Module{ fastvaf_mod, zvaf_mod, zvf_mod, emit_mod }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

    // Integration test suites.
    const va_test = b.createModule(.{
        .root_source_file = b.path("tests/va_test_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    va_test.addImport("zvaf", zvaf_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = va_test })).step);

    const v_test = b.createModule(.{
        .root_source_file = b.path("tests/v_test_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    v_test.addImport("zvf", zvf_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = v_test })).step);

    // Benchmark (Verilog-A).
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tests/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zvaf", zvaf_mod);
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    b.installArtifact(bench_exe);
    const bench_step = b.step("bench", "Run Verilog-A benchmark");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    const conf_step = b.step("conformance", "Run Verilog + Verilog-A conformance tests");

    // Verilog-A conformance: exe run from its fixtures dir.
    const conf_va_mod = b.createModule(.{
        .root_source_file = b.path("conformance_va/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    conf_va_mod.addImport("zvaf", zvaf_mod);
    const conf_va_exe = b.addExecutable(.{ .name = "conformance_va", .root_module = conf_va_mod });
    b.installArtifact(conf_va_exe);
    const run_conf_va = b.addRunArtifact(conf_va_exe);
    run_conf_va.setCwd(b.path("conformance_va"));
    conf_step.dependOn(&run_conf_va.step);

    // Verilog conformance: generated devices compiled against the real contract.
    const conf_opts = b.addOptions();
    conf_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    conf_opts.addOption([]const u8, "contract_path", b.pathFromRoot("../../modules/devices/src/contract.zig"));
    const conf_v_mod = b.createModule(.{
        .root_source_file = b.path("conformance_v/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    conf_v_mod.addImport("zvf", zvf_mod);
    conf_v_mod.addOptions("conf_opts", conf_opts);
    conf_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = conf_v_mod })).step);
}
