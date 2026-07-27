const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fastvf_mod = b.addModule("fastvf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Named `fastvf-engine`, not `fastvf`: an artifact name is also its output
    // name, and `std.Build.artifact()` panics on a duplicate. The CLI below
    // needs the plain name, because `modules/devices` resolves the build-time
    // generator with `dep.artifact("fastvf")`. Same split as FastVAF.
    b.installArtifact(b.addLibrary(.{
        .linkage = .static,
        .name = "fastvf-engine",
        .root_module = fastvf_mod,
    }));

    // Unit tests (expression translation, codegen shape).
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fastvf_mod })).step);

    // The CLI. Installed as an artifact because it is also the BUILD-TIME
    // generator: `modules/devices` resolves it with `dep.artifact("fastvf")`
    // and runs it once per `models/*.{v,sv,vhd}`, exactly as it does for
    // `fastvaf`.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("zvf", fastvf_mod);
    const cli = b.addExecutable(.{ .name = "fastvf", .root_module = cli_mod });
    b.installArtifact(cli);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_mod })).step);

    // Inspect the translator's output for one source file.
    const emit_run = b.addRunArtifact(cli);
    if (b.args) |args| emit_run.addArgs(args);
    b.step("emit", "Print the generated device for a Verilog file").dependOn(&emit_run.step);

    // Conformance: generated devices are compiled against the real contract and
    // driven with golden input vectors. Needs `zig` and the contract path.
    const conf_opts = b.addOptions();
    conf_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    conf_opts.addOption([]const u8, "contract_path", b.pathFromRoot("../devices/src/contract.zig"));

    const conf_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    conf_mod.addImport("zvf", fastvf_mod);
    conf_mod.addOptions("conf_opts", conf_opts);

    const conformance = b.step("conformance", "Run the Verilog conformance suite");
    conformance.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = conf_mod })).step);
}
