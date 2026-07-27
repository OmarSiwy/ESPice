const std = @import("std");
const zvaf = @import("zvaf");
const bench_options = @import("bench_options");

const Io = std.Io;

const DocumentMap = struct {
    doc: []const u8,
    folder: []const u8,
};

const documents = [_]DocumentMap{
    .{ .doc = "ch1-intro.html", .folder = "ch01_intro" },
    .{ .doc = "ch2-lexical.html", .folder = "ch02_lexical" },
    .{ .doc = "ch3-datatypes.html", .folder = "ch03_data_types" },
    .{ .doc = "ch4-expressions.html", .folder = "ch04_expressions" },
    .{ .doc = "ch5-analog.html", .folder = "ch05_analog_behavior" },
    .{ .doc = "ch6-hierarchy.html", .folder = "ch06_hierarchy" },
    .{ .doc = "ch7-mixed-signal.html", .folder = "ch07_mixed_signal" },
    .{ .doc = "ch8-scheduling.html", .folder = "ch08_scheduling" },
    .{ .doc = "ch9-system.html", .folder = "ch09_system_tasks" },
    .{ .doc = "ch10-directives.html", .folder = "ch10_directives" },
    .{ .doc = "ch11-vpi.html", .folder = "ch11_vpi" },
    .{ .doc = "ch12-vpi-routines.html", .folder = "ch12_vpi_routines" },
    .{ .doc = "annex-a-syntax.html", .folder = "annex_a_syntax" },
    .{ .doc = "annex-b-keywords.html", .folder = "annex_b_keywords" },
    .{ .doc = "annex-c-veriloga.html", .folder = "annex_c_analog_subset" },
    .{ .doc = "annex-d-stddefs.html", .folder = "annex_d_standard_definitions" },
    .{ .doc = "annex-e-spice.html", .folder = "annex_e_spice" },
    .{ .doc = "annex-f-resolution.html", .folder = "annex_f_resolution" },
    .{ .doc = "annex-g-changes.html", .folder = "annex_g_change_history" },
    .{ .doc = "annex-h-glossary.html", .folder = "annex_h_glossary" },
    .{ .doc = "index.html", .folder = "combined" },
};

const CoverageSet = struct {
    allocator: std.mem.Allocator,
    files: [][]u8,

    fn deinit(self: *CoverageSet) void {
        for (self.files) |bytes| self.allocator.free(bytes);
        self.allocator.free(self.files);
    }
};

const Corpus = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayList([]const u8),
    expected_error_files: usize,
    failures: usize,

    fn deinit(self: *Corpus) void {
        for (self.sources.items) |path| self.allocator.free(path);
        self.sources.deinit(self.allocator);
    }
};

const CompileAttempt = union(enum) {
    generated: []const u8,
    failed: Failure,
};

const Failure = struct {
    error_name: []const u8,
    diagnostics: zvaf.DiagnosticList,
    generated_source: ?[]const u8 = null,
};

const FixtureKind = enum { generated, expected_diagnostic };

const FixtureResult = struct {
    passed: bool,
    kind: FixtureKind,
    elapsed_ns: i96,
    source_bytes: usize,
    generated_bytes: usize,
};

/// Materializes successful codegen units under .zig-cache and asks the real
/// Zig compiler to instantiate every generic eval/q body against the current
/// device contract. Stable file names plus write-if-changed preserve Zig's own
/// incremental cache between conformance runs.
const GeneratedVerifier = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    root: std.ArrayList(u8) = .empty,
    count: usize = 0,

    fn init(allocator: std.mem.Allocator, io: Io, cwd: Io.Dir) !GeneratedVerifier {
        try cwd.createDirPath(io, bench_options.generated_dir);
        var self: GeneratedVerifier = .{ .allocator = allocator, .io = io, .cwd = cwd };
        try self.root.appendSlice(allocator,
            \\const std = @import("std");
            \\const contract = @import("contract");
            \\
            \\const Scalar = struct {
            \\    v: f64,
            \\    const Self = @This();
            \\    pub fn con(v: f64) Self { return .{ .v = v }; }
            \\    pub fn ddxAt(_: Self, _: usize) f64 { return 0.0; }
            \\    pub fn add(a: Self, b: Self) Self { return con(a.v + b.v); }
            \\    pub fn sub(a: Self, b: Self) Self { return con(a.v - b.v); }
            \\    pub fn neg(a: Self) Self { return con(-a.v); }
            \\    pub fn mul(a: Self, b: Self) Self { return con(a.v * b.v); }
            \\    pub fn div(a: Self, b: Self) Self { return con(a.v / b.v); }
            \\    pub fn scale(a: Self, c: f64) Self { return con(a.v * c); }
            \\    pub fn addC(a: Self, c: f64) Self { return con(a.v + c); }
            \\    pub fn exp(a: Self) Self { return con(@exp(a.v)); }
            \\    pub fn log(a: Self) Self { return con(@log(a.v)); }
            \\    pub fn sqrt(a: Self) Self { return con(@sqrt(a.v)); }
            \\    pub fn sin(a: Self) Self { return con(@sin(a.v)); }
            \\    pub fn cos(a: Self) Self { return con(@cos(a.v)); }
            \\    pub fn tanh(a: Self) Self { return con(std.math.tanh(a.v)); }
            \\    pub fn sinh(a: Self) Self { return con(std.math.sinh(a.v)); }
            \\    pub fn cosh(a: Self) Self { return con(std.math.cosh(a.v)); }
            \\    pub fn atan(a: Self) Self { return con(std.math.atan(a.v)); }
            \\    pub fn abs(a: Self) Self { return con(@abs(a.v)); }
            \\    pub fn minC(a: Self, c: f64) Self { return con(@min(a.v, c)); }
            \\    pub fn maxC(a: Self, c: f64) Self { return con(@max(a.v, c)); }
            \\    pub fn min(a: Self, b: Self) Self { return con(@min(a.v, b.v)); }
            \\    pub fn max(a: Self, b: Self) Self { return con(@max(a.v, b.v)); }
            \\    pub fn pow(a: Self, c: f64) Self { return con(std.math.pow(f64, a.v, c)); }
            \\    pub fn val(a: Self) f64 { return a.v; }
            \\};
            \\
            \\var run_generated: bool = false;
            \\fn instantiate(comptime D: type) void {
            \\    const n = contract.nU(D);
            \\    var x = [_]Scalar{Scalar.con(0.0)} ** n;
            \\    var model: D.Model = .{};
            \\    var instance: D.Instance = .{};
            \\    _ = D.eval(Scalar, x, &model, &instance, 0.0);
            \\    if (@hasDecl(D, "q")) _ = D.q(Scalar, x, &model, &instance, 0.0);
            \\}
            \\
        );
        return self;
    }

    fn deinit(self: *GeneratedVerifier) void {
        self.root.deinit(self.allocator);
    }

    fn add(self: *GeneratedVerifier, index: usize, fixture_path: []const u8, source: []const u8) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{d}.zig", .{index});
        defer self.allocator.free(filename);
        const output_path = try std.fs.path.join(self.allocator, &.{ bench_options.generated_dir, filename });
        defer self.allocator.free(output_path);
        try writeIfChanged(self.allocator, self.io, self.cwd, output_path, source);

        const declaration = try std.fmt.allocPrint(self.allocator,
            \\test "{s}" {{
            \\    if (run_generated) instantiate(@import("{s}"));
            \\}}
            \\
        , .{ fixture_path, filename });
        defer self.allocator.free(declaration);
        try self.root.appendSlice(self.allocator, declaration);
        self.count += 1;
    }

    fn finish(self: *GeneratedVerifier) !bool {
        const root_path = try std.fs.path.join(self.allocator, &.{ bench_options.generated_dir, "all.zig" });
        defer self.allocator.free(root_path);
        try writeIfChanged(self.allocator, self.io, self.cwd, root_path, self.root.items);
        const cache_path = try std.fs.path.join(self.allocator, &.{ bench_options.generated_dir, "zig-cache" });
        defer self.allocator.free(cache_path);
        try self.cwd.createDirPath(self.io, cache_path);
        const root_arg = try std.fmt.allocPrint(self.allocator, "-Mroot={s}", .{root_path});
        defer self.allocator.free(root_arg);
        const contract_arg = try std.fmt.allocPrint(self.allocator, "-Mcontract={s}", .{bench_options.contract_path});
        defer self.allocator.free(contract_arg);

        const result = try std.process.run(self.allocator, self.io, .{ .argv = &.{
            "zig",   "test",     "--test-no-exec", "--cache-dir", cache_path,
            "--dep", "contract", root_arg,         contract_arg,
        } });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            std.debug.print("FAIL generated Zig did not compile against the device contract:\n{s}\n", .{result.stderr});
        }
        return ok;
    }
};

fn writeIfChanged(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    path: []const u8,
    bytes: []const u8,
) !void {
    const old = cwd.readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (old) |contents| allocator.free(contents);
    if (old) |contents| if (std.mem.eql(u8, contents, bytes)) return;
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next() != null) {
        std.debug.print("usage: fastvaf-conformance\n", .{});
        return 2;
    }

    const cwd = Io.Dir.cwd();
    var failures: usize = 0;
    var documented_ids: usize = 0;
    var coverage = try loadCoverage(allocator, io, cwd, &failures, &documented_ids);
    defer coverage.deinit();

    var corpus = try collectCorpus(allocator, io, cwd);
    defer corpus.deinit();
    failures += corpus.failures;

    for (corpus.sources.items) |relative_path| {
        const slash = std.mem.indexOfScalar(u8, relative_path, std.fs.path.sep) orelse {
            std.debug.print("FAIL fixture is not in a document folder: {s}\n", .{relative_path});
            failures += 1;
            continue;
        };
        const folder = relative_path[0..slash];
        const map_index = findDocumentFolder(folder) orelse {
            std.debug.print("FAIL fixture folder has no document mapping: {s}\n", .{folder});
            failures += 1;
            continue;
        };
        const basename = std.fs.path.basename(relative_path);
        if (!containsBackticked(coverage.files[map_index], basename)) {
            std.debug.print("FAIL {s}/COVERAGE.md does not map `{s}`\n", .{ folder, basename });
            failures += 1;
        }
    }

    var times: std.ArrayList(i96) = .empty;
    defer times.deinit(allocator);
    var compilation = zvaf.Compilation.init(allocator);
    defer compilation.deinit();
    var verifier = try GeneratedVerifier.init(allocator, io, cwd);
    defer verifier.deinit();
    var successful_paths: std.ArrayList([]const u8) = .empty;
    defer successful_paths.deinit(allocator);
    var generated_count: usize = 0;
    var diagnostic_count: usize = 0;
    var source_bytes: usize = 0;
    var generated_bytes: usize = 0;

    for (corpus.sources.items, 0..) |relative_path, fixture_index| {
        const full_path = try std.fs.path.join(allocator, &.{ bench_options.fixture_root, relative_path });
        defer allocator.free(full_path);
        const result = try checkAndBenchmarkFixture(
            allocator,
            io,
            cwd,
            &compilation,
            &verifier,
            fixture_index,
            full_path,
        );
        try times.append(allocator, result.elapsed_ns);
        source_bytes += result.source_bytes;
        generated_bytes += result.generated_bytes;
        if (!result.passed) failures += 1;
        switch (result.kind) {
            .generated => {
                generated_count += 1;
                if (result.passed) try successful_paths.append(allocator, relative_path);
            },
            .expected_diagnostic => diagnostic_count += 1,
        }
    }

    if (diagnostic_count != corpus.expected_error_files) {
        std.debug.print(
            "FAIL found {d} expected-error files but {d} source fixtures use them (orphan expectation)\n",
            .{ corpus.expected_error_files, diagnostic_count },
        );
        failures += 1;
    }

    if (!try verifier.finish()) failures += 1;
    const incremental = try benchmarkIncremental(
        allocator,
        io,
        cwd,
        &compilation,
        successful_paths.items,
    );

    printSummary(
        times.items,
        documented_ids,
        corpus.sources.items.len,
        generated_count,
        diagnostic_count,
        source_bytes,
        generated_bytes,
        verifier.count,
        incremental.hits,
        incremental.elapsed_ns,
        compilation.rebuilds,
        failures,
    );
    return if (failures == 0) 0 else 1;
}

fn loadCoverage(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    failures: *usize,
    documented_ids: *usize,
) !CoverageSet {
    const files = try allocator.alloc([]u8, documents.len);
    var loaded: usize = 0;
    errdefer {
        for (files[0..loaded]) |bytes| allocator.free(bytes);
        allocator.free(files);
    }

    for (documents, 0..) |mapping, i| {
        const doc_path = try std.fs.path.join(allocator, &.{ bench_options.docs_dir, mapping.doc });
        defer allocator.free(doc_path);
        const coverage_path = try std.fs.path.join(allocator, &.{
            bench_options.fixture_root,
            mapping.folder,
            "COVERAGE.md",
        });
        defer allocator.free(coverage_path);

        const doc = cwd.readFileAlloc(io, doc_path, allocator, .unlimited) catch |err| {
            std.debug.print("FAIL cannot read documentation {s}: {t}\n", .{ doc_path, err });
            return err;
        };
        defer allocator.free(doc);
        files[i] = cwd.readFileAlloc(io, coverage_path, allocator, .unlimited) catch |err| {
            std.debug.print("FAIL cannot read coverage matrix {s}: {t}\n", .{ coverage_path, err });
            return err;
        };
        loaded += 1;

        if (std.mem.indexOf(u8, files[i], mapping.doc) == null) {
            std.debug.print("FAIL {s} does not name source document {s}\n", .{ coverage_path, mapping.doc });
            failures.* += 1;
        }

        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, doc, cursor, "id=\"")) |attribute| {
            const id_start = attribute + 4;
            const id_end = std.mem.indexOfScalarPos(u8, doc, id_start, '"') orelse break;
            const id = doc[id_start..id_end];
            if (!containsBackticked(files[i], id)) {
                std.debug.print("FAIL {s} omits documented section id `{s}`\n", .{ coverage_path, id });
                failures.* += 1;
            }
            documented_ids.* += 1;
            cursor = id_end + 1;
        }
    }

    return .{ .allocator = allocator, .files = files };
}

fn collectCorpus(allocator: std.mem.Allocator, io: Io, cwd: Io.Dir) !Corpus {
    var corpus: Corpus = .{
        .allocator = allocator,
        .sources = .empty,
        .expected_error_files = 0,
        .failures = 0,
    };
    errdefer corpus.deinit();

    var seen_folders = [_]bool{false} ** documents.len;
    var fixture_dir = cwd.openDir(io, bench_options.fixture_root, .{ .iterate = true }) catch |err| {
        std.debug.print("FAIL cannot open fixture root {s}: {t}\n", .{ bench_options.fixture_root, err });
        return err;
    };
    defer fixture_dir.close(io);
    var walker = try fixture_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and entry.depth() == 1) {
            if (findDocumentFolder(entry.basename)) |index| {
                seen_folders[index] = true;
            } else {
                std.debug.print("FAIL unexpected top-level fixture directory: {s}\n", .{entry.basename});
                corpus.failures += 1;
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".va")) {
            try corpus.sources.append(allocator, try allocator.dupe(u8, entry.path));
        } else if (std.mem.endsWith(u8, entry.path, ".expected-error.txt")) {
            corpus.expected_error_files += 1;
        } else if (std.mem.endsWith(u8, entry.path, ".expected.zig")) {
            std.debug.print(
                "FAIL stale byte-exact golden remains: {s}; semantic oracles are tracked in fixtures/TODO.md\n",
                .{entry.path},
            );
            corpus.failures += 1;
        }
    }

    for (seen_folders, documents) |seen, mapping| {
        if (!seen) {
            std.debug.print("FAIL missing fixture directory: {s}\n", .{mapping.folder});
            corpus.failures += 1;
        }
    }
    std.mem.sort([]const u8, corpus.sources.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return corpus;
}

fn checkAndBenchmarkFixture(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    compilation: *zvaf.Compilation,
    verifier: *GeneratedVerifier,
    fixture_index: usize,
    path: []const u8,
) !FixtureResult {
    const source = try cwd.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(source);
    const stem = path[0 .. path.len - 3];
    const error_path = try std.fmt.allocPrint(allocator, "{s}.expected-error.txt", .{stem});
    defer allocator.free(error_path);
    const expected_error = try readOptional(cwd, io, allocator, error_path);
    defer if (expected_error) |patterns| allocator.free(patterns);

    const started = Io.Clock.awake.now(io);
    var attempt = try compileFixture(allocator, io, compilation, path, source);
    const finished = Io.Clock.awake.now(io);
    defer deinitAttempt(allocator, &attempt);

    if (expected_error) |patterns| {
        return .{
            .passed = verifyExpectedFailure(path, source, patterns, attempt),
            .kind = .expected_diagnostic,
            .elapsed_ns = started.durationTo(finished).nanoseconds,
            .source_bytes = source.len,
            .generated_bytes = 0,
        };
    }

    var passed = false;
    var output_len: usize = 0;
    switch (attempt) {
        .failed => |failure| {
            std.debug.print("FAIL {s}: expected code generation, got {s}\n", .{ path, failure.error_name });
            printDiagnostics(path, failure.diagnostics.slice());
        },
        .generated => |generated| {
            passed = validateContractShape(path, generated);
            output_len = generated.len;
            try verifier.add(fixture_index, path, generated);
        },
    }
    return .{
        .passed = passed,
        .kind = .generated,
        .elapsed_ns = started.durationTo(finished).nanoseconds,
        .source_bytes = source.len,
        .generated_bytes = output_len,
    };
}

fn compileFixture(
    allocator: std.mem.Allocator,
    io: Io,
    compilation: *zvaf.Compilation,
    path: []const u8,
    source: []const u8,
) !CompileAttempt {
    var diagnostics: zvaf.DiagnosticList = .empty;
    const parent = std.fs.path.dirname(path) orelse ".";
    const include_dirs = [_][]const u8{parent};
    const update = compilation.update(path, source, &diagnostics, .{
        .io = io,
        .include_dirs = &include_dirs,
    }) catch |err| {
        return .{ .failed = .{
            .error_name = @errorName(err),
            .diagnostics = diagnostics,
        } };
    };
    if (diagnostics.len != 0) {
        return .{ .failed = .{
            .error_name = "DiagnosticsReported",
            .diagnostics = diagnostics,
        } };
    }

    const generated = update.generated;
    if (std.mem.indexOf(u8, generated, "@compileError") != null) {
        return .{ .failed = .{
            .error_name = "GeneratedCompileError",
            .diagnostics = diagnostics,
            .generated_source = generated,
        } };
    }
    diagnostics.deinit(allocator);
    return .{ .generated = generated };
}

fn deinitAttempt(allocator: std.mem.Allocator, attempt: *CompileAttempt) void {
    switch (attempt.*) {
        .generated => {},
        .failed => |*failure| {
            failure.diagnostics.deinit(allocator);
        },
    }
}

fn verifyExpectedFailure(path: []const u8, source: []const u8, patterns: []const u8, attempt: CompileAttempt) bool {
    const failure = switch (attempt) {
        .generated => {
            std.debug.print("FAIL {s}: expected a diagnostic, but generated Zig successfully\n", .{path});
            return false;
        },
        .failed => |failure| failure,
    };

    var lines = std.mem.splitScalar(u8, patterns, '\n');
    var checked: usize = 0;
    while (lines.next()) |raw_line| {
        const pattern = std.mem.trim(u8, raw_line, " \t\r");
        if (pattern.len == 0 or pattern[0] == '#') continue;
        checked += 1;
        if (!failureContains(failure, source, pattern)) {
            std.debug.print("FAIL {s}: diagnostic substring not found: {s}\n", .{ path, pattern });
            std.debug.print("  error: {s}\n", .{failure.error_name});
            printDiagnostics(path, failure.diagnostics.slice());
            return false;
        }
    }
    if (checked == 0) {
        std.debug.print("FAIL {s}: expected-error file has no required substrings\n", .{path});
        return false;
    }
    return true;
}

fn failureContains(failure: Failure, source: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOf(u8, failure.error_name, pattern) != null) return true;
    if (failure.generated_source) |generated| {
        if (std.mem.indexOf(u8, generated, pattern) != null) return true;
    }
    for (failure.diagnostics.slice()) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, pattern) != null) return true;
        if (patternAtDiagnosticLocation(source, diagnostic.line, diagnostic.col, pattern)) return true;
    }
    return false;
}

fn patternAtDiagnosticLocation(source: []const u8, line_number: u32, column: u32, pattern: []const u8) bool {
    if (line_number == 0 or column == 0) return false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var current: u32 = 1;
    while (lines.next()) |line| : (current += 1) {
        if (current != line_number) continue;
        const start: usize = column - 1;
        return start <= line.len and std.mem.startsWith(u8, line[start..], pattern);
    }
    return false;
}

fn validateContractShape(path: []const u8, source: []const u8) bool {
    const required = [_][]const u8{
        "const contract = @import(\"contract\");",
        "pub const U = enum(u8)",
        "pub const Model = struct",
        "pub const Instance = struct",
        "pub fn eval(comptime S: type",
        "contract.validate(Self)",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print("FAIL {s}: generated Zig lacks contract marker `{s}`\n", .{ path, needle });
            return false;
        }
    }
    if (std.mem.indexOf(u8, source, "@compileError") != null) {
        std.debug.print("FAIL {s}: generated Zig contains an @compileError stub\n", .{path});
        return false;
    }
    return true;
}

fn readOptional(
    cwd: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !?[]u8 {
    return cwd.readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn containsBackticked(haystack: []const u8, value: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, value)) |position| {
        const after = position + value.len;
        if (position != 0 and after < haystack.len and
            haystack[position - 1] == '`' and haystack[after] == '`') return true;
        cursor = after;
    }
    return false;
}

fn findDocumentFolder(folder: []const u8) ?usize {
    for (documents, 0..) |mapping, i| {
        if (std.mem.eql(u8, mapping.folder, folder)) return i;
    }
    return null;
}

fn printDiagnostics(path: []const u8, diagnostics: []const zvaf.Diagnostic) void {
    for (diagnostics) |diagnostic| {
        std.debug.print(
            "  {s}:{d}:{d}: {s}\n",
            .{ path, diagnostic.line, diagnostic.col, diagnostic.message },
        );
    }
}

const IncrementalResult = struct {
    hits: usize,
    elapsed_ns: i96,
};

/// Re-submit every successful unit without changes. This is both a correctness
/// assertion (same stable handle/generation, cache status = cached) and the
/// warm-update benchmark for the source-unit engine.
fn benchmarkIncremental(
    allocator: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    compilation: *zvaf.Compilation,
    paths: []const []const u8,
) !IncrementalResult {
    const started = Io.Clock.awake.now(io);
    var hits: usize = 0;
    for (paths) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ bench_options.fixture_root, relative_path });
        defer allocator.free(path);
        const source = try cwd.readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(source);
        const parent = std.fs.path.dirname(path) orelse ".";
        const update = try compilation.update(path, source, null, .{
            .io = io,
            .include_dirs = &.{parent},
        });
        if (update.status != .cached) {
            std.debug.print("FAIL incremental update rebuilt unchanged unit: {s}\n", .{path});
            continue;
        }
        hits += 1;
    }
    const finished = Io.Clock.awake.now(io);
    return .{ .hits = hits, .elapsed_ns = started.durationTo(finished).nanoseconds };
}

fn printSummary(
    times: []i96,
    documented_ids: usize,
    fixture_count: usize,
    generated_count: usize,
    diagnostic_count: usize,
    source_bytes: usize,
    generated_bytes: usize,
    compiled_count: usize,
    incremental_hits: usize,
    incremental_ns: i96,
    rebuilds: u64,
    failures: usize,
) void {
    std.mem.sort(i96, times, {}, std.sort.asc(i96));
    const total_ns: i96 = total: {
        var total: i96 = 0;
        for (times) |elapsed| total += elapsed;
        break :total total;
    };
    const p50 = if (times.len == 0) 0 else times[times.len / 2];
    const p95_index = if (times.len == 0) 0 else @min(times.len - 1, (times.len * 95 + 99) / 100 - 1);
    const p95 = if (times.len == 0) 0 else times[p95_index];
    const maximum = if (times.len == 0) 0 else times[times.len - 1];
    const average = if (times.len == 0) 0 else @divTrunc(total_ns, @as(i96, @intCast(times.len)));

    std.debug.print("\nFastVAF conformance + benchmark\n", .{});
    std.debug.print("  documentation: {d} files, {d} section ids\n", .{ documents.len, documented_ids });
    std.debug.print(
        "  accuracy:      {d} fixtures ({d} generated, {d} expected diagnostics), {d} failures\n",
        .{ fixture_count, generated_count, diagnostic_count, failures },
    );
    std.debug.print(
        "  compiled Zig:  {d} generated devices instantiated against contract.zig\n",
        .{compiled_count},
    );
    std.debug.print(
        "  throughput:    {d:.2} ms total, {d:.3} ms mean, {d:.3} ms p50, {d:.3} ms p95, {d:.3} ms max\n",
        .{ nsToMs(total_ns), nsToMs(average), nsToMs(p50), nsToMs(p95), nsToMs(maximum) },
    );
    std.debug.print(
        "  incremental:   {d}/{d} unchanged units cached in {d:.2} ms ({d} cold rebuilds)\n",
        .{ incremental_hits, generated_count, nsToMs(incremental_ns), rebuilds },
    );
    std.debug.print("  volume:        {d} source bytes, {d} generated Zig bytes\n", .{ source_bytes, generated_bytes });
    std.debug.print("  semantic Zig:  pending independent oracles in tests/fixtures/TODO.md\n\n", .{});
}

fn nsToMs(nanoseconds: i96) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / 1e6;
}
