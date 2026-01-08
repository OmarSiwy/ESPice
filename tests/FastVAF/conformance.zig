//! Conformance runner — the behavioral oracle.
//!
//! Walks `tests/fixtures/`, compiles every `.va` through `fastvaf.compileSource`
//! and checks it against the fixture's verdict:
//!
//!   no `<stem>.expected-error.txt`  ⇒ MUST compile and generate device.zig
//!   `<stem>.expected-error.txt`     ⇒ MUST fail; every non-blank, non-`#` line
//!                                     of that file must appear as a substring
//!                                     of the error name, of a diagnostic
//!                                     message, or of the generated Zig.
//!
//! Fixtures and `.expected-error.txt` files are the oracle: the runner never
//! normalizes them and the engine is what moves.
//!
//! Deterministic by construction: the walk order is sorted, so a failing run is
//! reproducible and diffable.

const std = @import("std");
const fastvaf = @import("fastvaf");
const options = @import("conformance_options");

const Io = std.Io;

/// Why a fixture failed to produce a device, in the vocabulary the
/// `.expected-error.txt` files are written in.
const Failure = struct {
    /// `@errorName` of the returned error, or a synthetic name for the two
    /// failure modes that are not Zig errors (see `compileFixture`).
    error_name: []const u8,
    diags: fastvaf.diag.Bag,
    /// Non-null only for `GeneratedCompileError`; borrowed from the result arena.
    generated: ?[]const u8 = null,
};

const Attempt = union(enum) { ok, failed: Failure };

pub fn main() !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // The runner is I/O-trivial (read a file, compile, print); the same
    // single-threaded Io the preprocessor uses for `include is plenty.
    const io = Io.Threaded.global_single_threaded.io();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try collectFixtures(arena, io, options.fixture_root);

    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const w = &stderr.interface;

    var passed: usize = 0;
    var failed: usize = 0;
    for (paths) |path| {
        if (try runFixture(gpa, io, arena, path, w)) passed += 1 else failed += 1;
    }

    try w.print("\nconformance: {d}/{d} fixtures pass, {d} fail\n", .{ passed, paths.len, failed });
    try w.flush();
    return if (failed == 0) 0 else 1;
}

/// Sorted so the run is deterministic (`Dir.walk` order is explicitly undefined).
fn collectFixtures(arena: std.mem.Allocator, io: Io, root: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".va")) continue;
        try list.append(arena, try std.fs.path.join(arena, &.{ root, entry.path }));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return list.items;
}

fn runFixture(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    path: []const u8,
    w: *Io.Writer,
) !bool {
    const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));

    // `<stem>.expected-error.txt` next to the fixture; absent ⇒ must compile.
    const expected_path = try std.fmt.allocPrint(arena, "{s}.expected-error.txt", .{
        path[0 .. path.len - ".va".len],
    });
    const expected: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, expected_path, arena, .limited(1 << 16)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };

    var attempt = try compileFixture(gpa, io, path, source);
    defer switch (attempt) {
        .ok => {},
        .failed => |*f| {
            if (f.generated) |g| gpa.free(g);
            f.diags.deinit(gpa);
        },
    };

    if (expected) |patterns| return verifyRejected(path, attempt, patterns, w);
    return verifyAccepted(path, attempt, w);
}

/// One compilation, collapsed to `ok` or a `Failure`. Two failure modes are not
/// Zig errors and get synthetic names, matching the vocabulary the fixtures use:
///   `DiagnosticsReported`  — compiled, but a stage reported a message.
///   `GeneratedCompileError` — codegen deliberately emitted `@compileError`.
fn compileFixture(gpa: std.mem.Allocator, io: Io, path: []const u8, source: []const u8) !Attempt {
    _ = io;
    var diags: fastvaf.diag.Bag = .init(gpa);
    const dir = std.fs.path.dirname(path) orelse ".";
    // `.debug` (not `.lint`) so stage 6 runs: some fixtures are rejected by
    // codegen emitting `@compileError`, which `.lint` would never see.
    var result = fastvaf.compileSourceOpts(gpa, source, .debug, .{
        .file_name = path,
        .include_dirs = &.{dir},
        .diags = &diags,
    }) catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .failed = .{ .error_name = @errorName(err), .diags = diags } };
    };
    errdefer result.deinit();

    if (diags.failed()) {
        var r = result;
        r.deinit();
        return .{ .failed = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }

    const generated = result.generateDevice() catch |err| {
        var r = result;
        r.deinit();
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .failed = .{ .error_name = @errorName(err), .diags = diags } };
    };
    if (std.mem.indexOf(u8, generated, "@compileError") != null) {
        // The generated text dies with the arena, so it has to be duped into
        // the diagnostic list's allocator before the result is dropped.
        const owned = try gpa.dupe(u8, generated);
        var r = result;
        r.deinit();
        return .{ .failed = .{
            .error_name = "GeneratedCompileError",
            .diags = diags,
            .generated = owned,
        } };
    }
    // "compileSource returned" is not the same claim as "produced a device".
    // Parse the emitted Zig with the compiler's own parser: without this, any
    // fixture that generates syntactically broken text still counts as a pass,
    // and the whole accept half of the suite is hollow. (Full semantic
    // analysis would need `zig build-obj` and the `contract` module per
    // fixture; parsing catches the codegen bugs that actually happen —
    // unbalanced braces, a dropped operand, an empty expression.)
    const zsrc = try gpa.dupeZ(u8, generated);
    defer gpa.free(zsrc);
    var zast = try std.zig.Ast.parse(gpa, zsrc, .zig);
    defer zast.deinit(gpa);
    if (zast.errors.len != 0) {
        const first = zast.errors[0];
        const loc = zast.tokenLocation(0, first.token);
        var msg: std.Io.Writer.Allocating = .init(gpa);
        defer msg.deinit();
        msg.writer.print("generated Zig does not parse at line {d}: ", .{loc.line + 1}) catch {};
        zast.renderError(first, &msg.writer) catch {};
        try diags.add(.codegen, .E1002, .{}, "{s}", .{msg.written()});
        result.deinit();
        return .{ .failed = .{ .error_name = "GeneratedParseError", .diags = diags } };
    }

    result.deinit();
    diags.deinit(gpa);
    return .ok;
}

fn verifyAccepted(path: []const u8, attempt: Attempt, w: *Io.Writer) !bool {
    switch (attempt) {
        .ok => return true,
        .failed => |f| {
            try w.print("FAIL {s}: expected success, got {s}\n", .{ path, f.error_name });
            try printDiags(f, w);
            return false;
        },
    }
}

fn verifyRejected(path: []const u8, attempt: Attempt, patterns: []const u8, w: *Io.Writer) !bool {
    const f = switch (attempt) {
        .ok => {
            try w.print("FAIL {s}: expected a diagnostic, but compiled cleanly\n", .{path});
            return false;
        },
        .failed => |f| f,
    };

    var lines = std.mem.splitScalar(u8, patterns, '\n');
    var checked: usize = 0;
    while (lines.next()) |raw| {
        const pattern = std.mem.trim(u8, raw, " \t\r");
        if (pattern.len == 0 or pattern[0] == '#') continue;
        checked += 1;
        if (!failureContains(f, pattern)) {
            try w.print("FAIL {s}: diagnostic substring not found: \"{s}\"\n", .{ path, pattern });
            try w.print("  error: {s}\n", .{f.error_name});
            try printDiags(f, w);
            return false;
        }
    }
    if (checked == 0) {
        try w.print("FAIL {s}: expected-error file has no required substrings\n", .{path});
        return false;
    }
    return true;
}

/// A rejection is described by more than the returned error value: the
/// `.expected-error.txt` files are written in a vocabulary of PHASE labels
/// ("ParseError", "DiagnosticsReported") as well as of error names and message
/// substrings. Each label below is a fact derived from the failure, not an
/// alias invented to make a fixture pass:
///   `DiagnosticsReported` — the failure carries at least one diagnostic.
///   `ParseError`          — every diagnostic came from stage 1/2/3, i.e. the
///                           model never reached lowering.
/// A lowering or proof rejection therefore still fails a fixture that demands
/// `ParseError`; the labels discriminate.
/// A fixture line is either a CODE (`E0313`, `W0650`) or a message substring.
///
/// Codes are the preferred form: they are stable, so the prose of a diagnostic
/// can be improved without touching 293 fixture files, and they pin WHICH rule
/// fired rather than how it happened to be worded.
fn asCode(pattern: []const u8) ?fastvaf.diag.Code {
    if (pattern.len != 5) return null;
    if (pattern[0] != 'E' and pattern[0] != 'W') return null;
    for (pattern[1..]) |c| if (c < '0' or c > '9') return null;
    return std.meta.stringToEnum(fastvaf.diag.Code, pattern);
}

fn failureContains(f: Failure, pattern: []const u8) bool {
    if (asCode(pattern)) |want| {
        for (f.diags.messages()) |mi| {
            if (f.diags.get(mi).code == want) return true;
        }
        return false;
    }
    if (std.mem.indexOf(u8, f.error_name, pattern) != null) return true;
    if (f.generated) |g| if (std.mem.indexOf(u8, g, pattern) != null) return true;

    const diags = f.diags.messages();
    if (diags.len != 0) {
        if (std.mem.eql(u8, pattern, "DiagnosticsReported")) return true;
        if (std.mem.eql(u8, pattern, "ParseError")) {
            for (diags) |mi| switch (f.diags.get(mi).stage) {
                .preprocess, .parse => {},
                .lower, .proof, .codegen => return false,
            };
            return true;
        }
    }
    // Substring match runs over the message AND the catalogue title, because
    // migrating to codes moved a lot of wording out of the message and into
    // `Info.title` — a fixture pinning the old prose still matches. Notes are
    // searched with it, in the same pass: they trail their own diagnostic in
    // the bundle now, so there is no all-notes pool to walk separately.
    var nbuf: [fastvaf.diag.max_children]fastvaf.diag.Note = undefined;
    for (diags) |mi| {
        const d = f.diags.get(mi);
        if (std.mem.indexOf(u8, d.message, pattern) != null) return true;
        if (std.mem.indexOf(u8, d.point, pattern) != null) return true;
        if (std.mem.indexOf(u8, fastvaf.diag.info(d.code).title, pattern) != null) return true;
        for (f.diags.notes(d, &nbuf)) |n| {
            if (std.mem.indexOf(u8, n.text, pattern) != null) return true;
        }
    }
    return false;
}

fn printDiags(f: Failure, w: *Io.Writer) !void {
    // Render the real thing, so a failing fixture shows exactly what a user
    // would see — snippet, carets, notes and all. Colour is off: this output
    // is read from a log as often as from a terminal.
    var bag = f.diags;
    fastvaf.diag.render(&bag, w, .{ .explain_hint = false, .summary = false }) catch {};
    // A `@compileError` carries the whole reason; without it "GeneratedCompileError"
    // says nothing about WHICH construct codegen refused.
    if (f.generated) |g| {
        var rest = g;
        while (std.mem.indexOf(u8, rest, "@compileError")) |at| {
            const line_end = std.mem.indexOfScalar(u8, rest[at..], '\n') orelse rest.len - at;
            try w.print("  codegen: {s}\n", .{rest[at .. at + line_end]});
            rest = rest[at + line_end ..];
        }
    }
}
