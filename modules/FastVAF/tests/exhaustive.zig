//! Exhaustive runner — the SEMANTIC oracle.
//!
//! `tests/conformance.zig` proves a fixture compiles (or is rejected with the
//! right diagnostic). It says nothing about what the generated device COMPUTES,
//! which is the gap `tests/fixtures/TODO.md` names. This closes it, and it does
//! so without asking anyone to write an expectation in Zig:
//!
//!   tests/fixtures/exhaustive/NNN_name.va            the component + testbench
//!   tests/fixtures/exhaustive/NNN_name.expected.txt   its transcript
//!
//! For each `.va` the runner compiles with §9.4 display tasks ENABLED, generates
//! the operating-point driver from the file's own `//!` lines (src/tb.zig),
//! builds one native binary, runs it, and compares the transcript byte for byte.
//!
//! WHY THIS IS AN ORACLE AND A SNAPSHOT IS NOT. The deleted `.expected.zig`
//! files were FastVAF's own output fed back to it: any wrong answer was frozen
//! as correct. A transcript is different in kind, because the fixture states its
//! OWN expectation in Verilog-A and prints the residual:
//!
//!     $strobe("tanh: got=%g want=%g err=%g", y, 0.46211715726000974,
//!             abs(y - 0.46211715726000974));
//!
//! The golden line reads `err=0`. The constant is independently derived (LRM
//! §4.3.2 defines the function; the value comes from anywhere but FastVAF), a
//! reviewer can check it without running anything, and a regression turns `err=0`
//! into a visible number rather than into a silently re-blessed byte.
//!
//! Blessing a transcript is therefore reading `err=0` lines, not trusting a
//! diff. `--bless` writes them; a human is still the one who accepts them.
//!
//! Deterministic by construction: sorted walk, one binary per fixture, `-ODebug`
//! so no reassociation, and every number printed at fixed precision.

const std = @import("std");
const fastvaf = @import("fastvaf");
const options = @import("exhaustive_options");

const Io = std.Io;

/// Everything one fixture needs, all with the same lifetime.
const Fixture = struct {
    /// `tests/fixtures/exhaustive/007_diode.va`
    path: []const u8,
    /// `007_diode`
    stem: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bless = false;
    var filter: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--bless")) bless = true else filter = a;
    }

    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const w = &stderr.interface;

    const fixtures = try collect(arena, io, options.fixture_root, filter);
    if (fixtures.len == 0) {
        try w.print("exhaustive: no fixtures under {s}\n", .{options.fixture_root});
        try w.flush();
        return 1;
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var blessed: usize = 0;
    for (fixtures) |f| {
        switch (try run(gpa, io, arena, f, bless, w)) {
            .pass => passed += 1,
            .blessed => blessed += 1,
            .fail => failed += 1,
        }
        try w.flush();
    }

    if (bless) {
        try w.print(
            "\nexhaustive: wrote {d} transcript(s), {d} unchanged, {d} failed to run\n" ++
                "REVIEW THEM: a blessed transcript is only an expectation once a human has read it.\n",
            .{ blessed, passed, failed },
        );
    } else {
        try w.print("\nexhaustive: {d}/{d} transcripts match, {d} fail\n", .{
            passed, fixtures.len, failed,
        });
    }
    try w.flush();
    return if (failed == 0) 0 else 1;
}

const Verdict = enum { pass, fail, blessed };

/// Sorted, so a failing run is reproducible and diffable. `filter` is a plain
/// substring: `zig build exhaustive -- 04_` runs one group.
fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, filter: ?[]const u8) ![]const Fixture {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var list: std.ArrayList(Fixture) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".va")) continue;
        if (filter) |f| if (std.mem.indexOf(u8, entry.name, f) == null) continue;
        const name = try arena.dupe(u8, entry.name);
        try list.append(arena, .{
            .path = try std.fs.path.join(arena, &.{ root, name }),
            .stem = name[0 .. name.len - ".va".len],
        });
    }
    std.mem.sort(Fixture, list.items, {}, struct {
        fn lt(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.stem, b.stem);
        }
    }.lt);
    return list.items;
}

fn run(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    f: Fixture,
    bless: bool,
    w: *Io.Writer,
) !Verdict {
    const source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20));

    // Stage 1-6 with §9.4 display ON. W0650 is about speed, and every fixture
    // that probes a node trips it; allowing it here keeps the transcript about
    // the model rather than about float modes.
    var diags: fastvaf.diag.Bag = .init(gpa);
    defer diags.deinit(gpa);
    var levels: fastvaf.diag.Levels = .empty;
    defer levels.deinit(gpa);
    try levels.set(gpa, .W0650, .allow);

    const dir = std.fs.path.dirname(f.path) orelse ".";
    var result = fastvaf.compileSourceOpts(gpa, source, .release_fast, .{
        .file_name = f.path,
        .include_dirs = &.{dir},
        .diags = &diags,
        .lint = levels,
        .display = .emit,
    }) catch |err| {
        try w.print("FAIL {s}: did not compile: {t}\n", .{ f.stem, err });
        fastvaf.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
        return .fail;
    };
    defer result.deinit();

    const device = result.generateDevice() catch |err| {
        try w.print("FAIL {s}: codegen failed: {t}\n", .{ f.stem, err });
        return .fail;
    };
    if (result.device_has_compile_error) {
        try w.print("FAIL {s}: codegen refused a construct (@compileError in the device)\n", .{f.stem});
        return .fail;
    }

    // The `//!` lines are read from the RAW source: the preprocessor deletes
    // comments (§2.4), so by the time `result` exists they are gone.
    const d = fastvaf.tb.parse(arena, source) catch |err| {
        try w.print("FAIL {s}: `//!` directive: {t}\n", .{ f.stem, err });
        return .fail;
    };
    const runner = try fastvaf.tb.renderRunner(arena, f.stem, d);

    // One work directory per fixture: two fixtures may declare the same module
    // name, and a shared scratch would race them onto one `device.zig`.
    const work = try std.fs.path.join(arena, &.{ options.work_root, f.stem });
    const built = fastvaf.tb.buildExe(gpa, io, device, runner, .{
        .work_dir = work,
        .contract = options.contract,
        .name = result.mir.name,
        .zig_exe = options.zig_exe,
    }) catch |err| {
        try w.print("FAIL {s}: building the testbench: {t}\n", .{ f.stem, err });
        return .fail;
    };
    defer built.deinit(gpa);
    const bin = switch (built) {
        .failed => |text| {
            try w.print(
                "FAIL {s}: the generated testbench does not compile — an ENGINE bug:\n{s}\n",
                .{ f.stem, text },
            );
            return .fail;
        },
        .ok => |p| p,
    };

    const got = capture(gpa, io, bin) catch |err| {
        try w.print("FAIL {s}: running the testbench: {t}\n", .{ f.stem, err });
        return .fail;
    };
    defer gpa.free(got);

    // A fixture may deliberately print FAIL from Verilog-A (`$strobe` under a
    // §9.7.3 severity task, or a computed verdict). Matching the golden is not
    // enough if the golden itself says the model is broken.
    if (std.mem.indexOf(u8, got, "FAIL") != null) {
        try w.print("FAIL {s}: the testbench itself reported a failure:\n{s}\n", .{ f.stem, got });
        return .fail;
    }

    const expected_path = try std.fmt.allocPrint(arena, "{s}/{s}.expected.txt", .{ dir, f.stem });
    const want: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, expected_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };

    if (want) |text| {
        if (std.mem.eql(u8, text, got)) return .pass;
        if (!bless) {
            try w.print("FAIL {s}: transcript differs from {s}\n", .{ f.stem, expected_path });
            try printDiff(text, got, w);
            return .fail;
        }
    } else if (!bless) {
        try w.print(
            "FAIL {s}: no {s}.expected.txt — run `zig build exhaustive -- --bless`, " ++
                "then READ the transcript before committing it\n",
            .{ f.stem, f.stem },
        );
        return .fail;
    }

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = expected_path, .data = got });
    try w.print("bless {s}: wrote {d} bytes\n", .{ f.stem, got.len });
    return .blessed;
}

/// Run the testbench and return everything it said. stderr, because that is
/// where `std.debug.print` writes — both the model's `$strobe` output and the
/// harness's residual dump, so the interleaving is the program's, not the OS's.
fn capture(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{bin},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var aw: Io.Writer.Allocating = .fromArrayList(gpa, &text);
    _ = reader.interface.streamRemaining(&aw.writer) catch {};
    text = aw.toArrayList();
    // A nonzero status is part of the transcript: `$finish`/`$fatal` and a
    // panic in generated code both show up here, and silently dropping it would
    // let a crashing testbench match a golden that records the output it managed
    // to produce first.
    switch (try child.wait(io)) {
        .exited => |c| if (c != 0) {
            var line: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&line, "<testbench exited with status {d}>\n", .{c}) catch unreachable;
            try text.appendSlice(gpa, s);
        },
        else => try text.appendSlice(gpa, "<testbench did not exit normally>\n"),
    }
    return text.toOwnedSlice(gpa);
}

/// First differing line, with a little context. A full diff of a 200-line
/// transcript buries the one number that moved.
fn printDiff(want: []const u8, got: []const u8, w: *Io.Writer) !void {
    var a = std.mem.splitScalar(u8, want, '\n');
    var b = std.mem.splitScalar(u8, got, '\n');
    var n: usize = 1;
    while (true) : (n += 1) {
        const la = a.next();
        const lb = b.next();
        if (la == null and lb == null) return;
        const sa = la orelse "<end of expected>";
        const sb = lb orelse "<end of actual>";
        if (std.mem.eql(u8, sa, sb)) continue;
        try w.print("  line {d}:\n    want: {s}\n    got:  {s}\n", .{ n, sa, sb });
        return;
    }
}
