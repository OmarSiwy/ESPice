const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The engine. Flat `src/*.zig` layout, rooted at src/root.zig, which
    // pub-imports every stage of the pipeline (preprocessor → … → orchestrator).
    // Dependents get it with `.imports = &.{.{ .name = "fastvaf", .module =
    // fastvaf_dep.module("fastvaf") }}`.
    const fastvaf = b.addModule("fastvaf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static lib so a non-Zig host (or a Zig host that prefers linking over
    // importing) can consume the engine too. `zig build` builds + installs it.
    //
    // Named `fastvaf-engine`, not `fastvaf`: an artifact name is also its
    // output name, and `std.Build.artifact()` panics on a duplicate — the CLI
    // below needs the plain name, because every diagnostic the engine renders
    // ends with "run `fastvaf --explain EXXXX`", and a dependent build (see
    // modules/devices) resolves the generator with `dep.artifact("fastvaf")`.
    b.installArtifact(b.addLibrary(.{
        .linkage = .static,
        .name = "fastvaf-engine",
        .root_module = fastvaf,
    }));

    // The CLI. The engine is a library, but its diagnostics advertise a binary
    // — every message ends with "run `fastvaf --explain EXXXX`" — and the lint
    // levels that tune the W0650 finiteness warning need a flag parser. This is
    // that shell and nothing more.
    const cli = b.addExecutable(.{
        .name = "fastvaf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    b.step("run", "Run the fastvaf CLI").dependOn(&run_cli.step);

    // One test root per src file. A single `addTest` on src/root.zig runs ZERO
    // tests: root.zig only ever says `pub const x = @import("x.zig");`, and an
    // unreferenced decl is never analyzed, so those files are never pulled into
    // the test binary. Per-file roots also isolate which stage fails.
    // ponytail: explicit list, not a directory scan — std.Io.Dir iteration in
    // build.zig buys nothing but nondeterministic step order. Add a line when a
    // src file is added.
    const test_step = b.step("test", "Run the engine unit tests");
    for ([_][]const u8{
        "ast.zig",
        "codegen.zig",
        "diag.zig",
        "diag_code.zig",
        "eval_batch.zig",
        "lexer.zig",
        "lower.zig",
        "mir.zig",
        "naming.zig",
        "orchestrator.zig",
        "parser.zig",
        "preprocessor.zig",
        "proof.zig",
        "root.zig",
        "ssa.zig",
        "tb.zig",
        "token.zig",
    }) |file| {
        const t = b.addTest(.{
            .name = b.fmt("test-{s}", .{std.fs.path.stem(file)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}", .{file})),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);

        // `zig build` alone proves nothing about the pipeline: the static lib
        // exports no symbol, so Zig analyzes none of root.zig's pub imports —
        // a type error anywhere in src/ still yields a green build. The test
        // roots DO analyze every declaration of every src file, so the default
        // step depends on compiling (not running) them. `zig build` == "the
        // whole engine type-checks"; `zig build test` == "and it behaves".
        b.getInstallStep().dependOn(&t.step);
    }

    // The behavioral oracle: tests/fixtures/**/*.va compiled through
    // compileSource and checked against the sibling `.expected-error.txt`.
    // It is an EXECUTABLE, not a `test`, on purpose — a failing fixture must
    // print the whole failing set in one run, not abort at the first assert.
    // Wired into `zig build test` so green means "type-checks AND conforms".
    const conformance_options = b.addOptions();
    conformance_options.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures"));
    const conformance_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fastvaf", .module = fastvaf }},
    });
    conformance_mod.addOptions("conformance_options", conformance_options);
    const run_conformance = b.addRunArtifact(b.addExecutable(.{
        .name = "fastvaf-conformance",
        .root_module = conformance_mod,
    }));
    b.step("conformance", "Run the Verilog-A fixture conformance suite")
        .dependOn(&run_conformance.step);
    test_step.dependOn(&run_conformance.step);

    // The SEMANTIC oracle. Every tests/fixtures/exhaustive/*.va becomes a native
    // testbench binary (ch9 display tasks on + the `//!` operating points) whose
    // transcript is compared with the committed `.expected.txt`. See
    // tests/exhaustive.zig for why a transcript is an oracle and the deleted
    // `.expected.zig` snapshots were not.
    //
    // NOT wired into `zig build test`: it spawns a `zig build-exe` per fixture,
    // which is seconds rather than milliseconds, and it needs the `contract`
    // module from the sibling devices package. Run it explicitly:
    //
    //   zig build exhaustive              # check every transcript
    //   zig build exhaustive -- 04_       # only the fixtures matching `04_`
    //   zig build exhaustive -- --bless   # (re)write them, then READ the diff
    const contract_path = b.option(
        []const u8,
        "contract",
        "Root of the `contract` module the generated devices import",
    ) orelse b.pathFromRoot("../devices/src/contract.zig");
    const exhaustive_options = b.addOptions();
    exhaustive_options.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures/exhaustive"));
    exhaustive_options.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/fastvaf-tb"));
    exhaustive_options.addOption([]const u8, "contract", contract_path);
    exhaustive_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const exhaustive_mod = b.createModule(.{
        .root_source_file = b.path("tests/exhaustive.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fastvaf", .module = fastvaf }},
    });
    exhaustive_mod.addOptions("exhaustive_options", exhaustive_options);
    const run_exhaustive = b.addRunArtifact(b.addExecutable(.{
        .name = "fastvaf-exhaustive",
        .root_module = exhaustive_mod,
    }));
    if (b.args) |a| run_exhaustive.addArgs(a);
    b.step("exhaustive", "Run the Verilog-A testbench transcripts")
        .dependOn(&run_exhaustive.step);
}
