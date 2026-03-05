//! End-to-end numeric fixture runner. From the repository root:
//!   zig build test -- --jobs 8 --filter op/
//!   zig build test -- --list
//! Expected JSON (including numeric values) is embedded at compile time.
//! Unsupported simulator features are failures, never skipped or blessed.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Complex = std.math.Complex(f64);

const catalog = @import("fixture_catalog");
pub const spice_files = catalog.spice_files;
pub const expected_files = catalog.expected_files;
pub const expected_outputs = catalog.expected_outputs;

// Metadata is cold; numeric data stays in the raw file's contiguous row layout.
// All counts are bounded by u32; offsets into allocated byte slices use usize.
const Column = struct { values: []const Json, rtol: f64, atol: f64 };
const Axis = struct { name: []const u8, values: []const f64, rtol: f64, atol: f64 };
const ExpectedPlot = struct {
    name: []const u8,
    match: enum { exact, samples, selected_rows, unordered },
    row_count: ?u32 = null,
    row_indices: []const u32 = &.{},
    axis: ?Axis = null,
    input_source: ?[]const u8 = null,
    columns: std.json.ArrayHashMap(Column),
};
const Expectation = struct {
    status: enum { success, @"error" },
    plots: []const ExpectedPlot = &.{},
    checks: []const Json = &.{},
    category: ?[]const u8 = null,
};
const Oracle = struct { schema_version: u8, netlist_sha256: []const u8, expect: Expectation };
const Plot = struct {
    name: []const u8,
    names: []const []const u8,
    rows: u32,
    complex: bool,
    data: []align(1) const f64,

    fn value(self: Plot, row: usize, col: usize) Complex {
        const i = (row * self.names.len + col) * @as(usize, if (self.complex) 2 else 1);
        return .init(self.data[i], if (self.complex) self.data[i + 1] else 0);
    }

    fn column(self: Plot, name: []const u8) !usize {
        // Prefer an exact name before the documented SPICE spelling aliases.
        for (self.names, 0..) |actual, i| if (equal(actual, name)) return i;
        var found: ?usize = null;
        for (self.names, 0..) |actual, i| {
            if (!equal(canonical(actual), canonical(name))) continue;
            if (found != null) return error.AmbiguousColumn;
            found = i;
        }
        return found orelse error.MissingColumn;
    }
};

// Workers claim independent indices; the result slots have one writer each.
const Outcome = enum(u8) { unselected, pass, fail };
const Runner = struct {
    io: Io,
    app: []const u8,
    filter: []const u8,
    timeout_seconds: u32,
    next: std.atomic.Value(u32) = .init(0),
    outcomes: []Outcome,
};
threadlocal var diagnostics: ?*Io.Writer = null;
fn diagnostic(comptime fmt: []const u8, args: anytype) void {
    if (diagnostics) |writer| writer.print(fmt, args) catch {};
}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const app = args.next() orelse "zig-out/bin/espice";
    var filter: []const u8 = "";
    var jobs: u16 = 8;
    var timeout_seconds: u32 = 300;
    var list = equal(app, "--list");
    const Flag = enum(u8) { list, filter, jobs, timeout };
    const flags = std.StaticStringMap(Flag).initComptime(.{
        .{ "--list", .list }, .{ "--filter", .filter },
        .{ "--jobs", .jobs }, .{ "--timeout", .timeout },
    });
    while (args.next()) |arg| {
        switch (flags.get(arg) orelse return error.UnknownArgument) {
            .list => list = true,
            .filter => filter = args.next() orelse return error.MissingArgument,
            .jobs => jobs = try std.fmt.parseInt(u16, args.next() orelse return error.MissingArgument, 10),
            .timeout => timeout_seconds = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10),
        }
    }
    if (jobs == 0) return error.InvalidWorkerCount;
    if (timeout_seconds == 0) return error.InvalidTimeout;
    var selected: u32 = 0;
    for (spice_files, expected_files) |path, expected| {
        if (std.mem.indexOf(u8, path, filter) == null) continue;
        selected += 1;
        if (list) std.debug.print("{s} -> {s}\n", .{ path, expected });
    }
    if (selected == 0) return error.NoMatchingFixtures;
    if (list) return 0;
    const outcomes = try init.gpa.alloc(Outcome, spice_files.len);
    defer init.gpa.free(outcomes);
    @memset(outcomes, .unselected);
    var runner: Runner = .{ .io = init.io, .app = app, .filter = filter, .timeout_seconds = timeout_seconds, .outcomes = outcomes };
    var group: Io.Group = .init;
    defer group.cancel(init.io);
    std.debug.print("Correctness: {d} fixtures, {d} workers\n", .{ selected, @min(jobs, selected) });
    for (0..@min(jobs, selected)) |_| try group.concurrent(init.io, worker, .{&runner});
    try group.await(init.io);
    var passed: u32 = 0;
    var failed: u32 = 0;
    for (outcomes) |outcome| switch (outcome) {
        .pass => passed += 1,
        .fail => failed += 1,
        .unselected => {},
    };
    std.debug.print("Correctness: {d} passed, {d} failed, {d} selected\n", .{ passed, failed, selected });
    return if (failed == 0 and passed == selected) 0 else 1;
}

fn worker(runner: *Runner) void {
    while (true) {
        const i = runner.next.fetchAdd(1, .monotonic);
        if (i >= spice_files.len) return;
        const path = spice_files[i];
        if (std.mem.indexOf(u8, path, runner.filter) == null) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var report: Io.Writer.Allocating = .init(arena.allocator());
        diagnostics = &report.writer;
        defer diagnostics = null;
        runCase(arena.allocator(), runner.io, runner.app, path, expected_outputs[i], runner.timeout_seconds) catch |err| {
            runner.outcomes[i] = .fail;
            std.debug.print("FAIL {s}: {s}\n{s}", .{ path, @errorName(err), report.written() });
            continue;
        };
        runner.outcomes[i] = .pass;
        std.debug.print("PASS {s}\n", .{path});
    }
}

fn runCase(a: Allocator, io: Io, app: []const u8, path: []const u8, expected: []const u8, timeout_seconds: u32) !void {
    const oracle = try std.json.parseFromSliceLeaky(Oracle, a, expected, .{ .ignore_unknown_fields = true });
    try validateOracle(oracle);
    const netlist = try std.fmt.allocPrint(a, "tests/{s}", .{path});
    const source = try Io.Dir.cwd().readFileAlloc(io, netlist, a, .unlimited);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    if (!equal(&std.fmt.bytesToHex(digest, .lower), oracle.netlist_sha256)) return error.StaleOracle;

    // Isolated output per case/run. Child processes see the fixture directory,
    // so relative .include/.hdl paths keep their SPICE meaning.
    var random: [16]u8 = undefined;
    io.random(&random);
    const scratch = try std.fmt.allocPrint(a, ".zig-cache/correctness/{s}", .{std.fmt.bytesToHex(random, .lower)});
    try Io.Dir.cwd().createDirPath(io, scratch);
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const raw = try Io.Dir.cwd().realPathFileAlloc(io, scratch, a);
    const output = try std.fmt.allocPrint(a, "{s}/result.raw", .{raw});
    const executable = try Io.Dir.cwd().realPathFileAlloc(io, app, a);
    const result = try simulate(a, io, executable, netlist, output, timeout_seconds);
    if (oracle.expect.status == .@"error") return checkRejection(oracle.expect.category.?, result);
    try requireSuccess(result);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, output, a, .unlimited);
    const plots = try parseRaw(a, bytes);
    try compare(a, oracle.expect, plots);
    for (oracle.expect.checks) |check| {
        if (!equal(try string(try field(check, "kind")), "repeatability")) continue;
        // Remove the first output so a missing second result cannot reuse it.
        try Io.Dir.cwd().deleteFile(io, output);
        try requireSuccess(try simulate(a, io, executable, netlist, output, timeout_seconds));
        const repeated = try parseRaw(a, try Io.Dir.cwd().readFileAlloc(io, output, a, .unlimited));
        try repeatable(plots, repeated);
    }
}

fn simulate(a: Allocator, io: Io, app: []const u8, netlist: []const u8, output: []const u8, timeout_seconds: u32) !std.process.RunResult {
    // A total deadline also covers a child that closes its streams then hangs.
    const Event = union(enum) { process: std.process.RunError!std.process.RunResult, timeout: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();
    const options: std.process.RunOptions = .{
        .argv = &.{ app, "--backend=cpu", "--format=binary", "-b", "-r", output, std.fs.path.basename(netlist) },
        .cwd = .{ .path = std.fs.path.dirname(netlist).? },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    };
    try select.concurrent(.process, std.process.run, .{ a, io, options });
    try select.concurrent(.timeout, Io.sleep, .{ io, Io.Duration.fromSeconds(timeout_seconds), Io.Clock.awake });
    return switch (try select.await()) {
        .process => |result| result,
        .timeout => error.Timeout,
    };
}

fn requireSuccess(result: std.process.RunResult) !void {
    if (result.term == .exited and result.term.exited == 0) return;
    diagnostic("  process {any}\n{s}{s}\n", .{ result.term, result.stdout, result.stderr });
    return error.SimulatorFailed;
}

fn checkRejection(category: []const u8, result: std.process.RunResult) !void {
    // A crash, usage error, missing model or generic unsupported-feature error
    // is not evidence that the requested invalid analysis was diagnosed.
    if (result.term != .exited or result.term.exited != 1) return error.ExpectedDiagnosticExit;
    const categories = std.StaticStringMap([]const u8).initComptime(.{
        .{ "InvalidQueryOptions", "invalid_analysis_arguments" },
        .{ "InvalidAnalysisArguments", "invalid_analysis_arguments" },
        .{ "InvalidAnalysis", "invalid_analysis_arguments" },
        .{ "AnalysisSourceNotFound", "invalid_analysis_arguments" },
        .{ "AnalysisNodeNotFound", "invalid_analysis_arguments" },
        .{ "NonuniqueOperatingPoint", "nonunique_operating_point" },
        .{ "FloatingNode", "nonunique_operating_point" },
        .{ "InconsistentCircuit", "inconsistent_circuit" },
        .{ "InconsistentVoltageLoop", "inconsistent_circuit" },
        .{ "VoltageSourceLoop", "inconsistent_circuit" },
        .{ "CurrentSourceCutset", "inconsistent_circuit" },
        .{ "invalid_analysis_arguments", "invalid_analysis_arguments" },
        .{ "nonunique_operating_point", "nonunique_operating_point" },
        .{ "inconsistent_circuit", "inconsistent_circuit" },
    });
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |text| {
        // Match the diagnostic, not a filename which happens to name an error.
        const start = if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| colon + 1 else 0;
        if (categories.get(std.mem.trim(u8, text[start..], " \t\r"))) |actual| {
            if (equal(actual, category)) return;
        }
    }
    diagnostic("  wanted diagnostic category {s}, received:\n{s}\n", .{ category, result.stderr });
    return error.WrongDiagnostic;
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn canonical(name: []const u8) []const u8 {
    const tf = std.StaticStringMap([]const u8).initComptime(.{
        .{ "v(transfer_function)", "transfer_function" },
        .{ "transfer_function", "transfer_function" },
        .{ "input_resistance", "input_resistance" },
        .{ "output_resistance", "output_resistance" },
    });
    if (tf.get(name)) |mapped| return mapped;
    if (std.mem.indexOf(u8, name, "#input_impedance") != null) return "input_resistance";
    if (std.mem.startsWith(u8, name, "v(output_impedance_at_")) return "output_resistance";
    if (std.mem.endsWith(u8, name, "#branch")) return name[0 .. name.len - 7];
    return name;
}

fn line(bytes: []const u8, pos: *usize) ![]const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, pos.*, '\n') orelse return error.TruncatedRaw;
    const text = std.mem.trim(u8, bytes[pos.*..end], " \t\r");
    pos.* = end + 1;
    return text;
}

fn parseRaw(a: Allocator, bytes: []const u8) ![]const Plot {
    var plots: std.ArrayList(Plot) = .empty;
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] == '\n' or bytes[pos] == '\r') {
            pos += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, try line(bytes, &pos), "Title:")) return error.InvalidRawHeader;
        var name: ?[]const u8 = null;
        var ncols: ?u32 = null;
        var nrows: ?u32 = null;
        var complex: ?bool = null;
        while (true) {
            const text = try line(bytes, &pos);
            if (equal(text, "Variables:")) break;
            const split = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidRawHeader;
            const key = text[0..split];
            const value = std.mem.trim(u8, text[split + 1 ..], " \t");
            if (equal(key, "Plotname")) name = value;
            if (equal(key, "No. Variables")) ncols = try std.fmt.parseInt(u32, value, 10);
            if (equal(key, "No. Points")) nrows = try std.fmt.parseInt(u32, value, 10);
            if (equal(key, "Flags")) {
                complex = if (equal(value, "complex")) true else if (equal(value, "real")) false else return error.UnsupportedRawFlags;
            }
        }
        const cols = ncols orelse return error.InvalidRawHeader;
        const rows = nrows orelse return error.InvalidRawHeader;
        const is_complex = complex orelse return error.InvalidRawHeader;
        if (cols == 0 or cols > bytes.len) return error.InvalidRawHeader;
        const names = try a.alloc([]const u8, cols);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try seen.ensureTotalCapacity(a, cols);
        for (names, 0..) |*dest, i| {
            var tokens = std.mem.tokenizeAny(u8, try line(bytes, &pos), " \t");
            if (try std.fmt.parseInt(u32, tokens.next() orelse return error.InvalidRawHeader, 10) != i) return error.InvalidRawHeader;
            dest.* = tokens.next() orelse return error.InvalidRawHeader;
            _ = tokens.next() orelse return error.InvalidRawHeader;
            if (tokens.next() != null) return error.InvalidRawHeader;
            const key = try std.ascii.allocLowerString(a, dest.*);
            if (seen.getOrPutAssumeCapacity(key).found_existing) return error.DuplicateColumn;
        }
        if (!equal(try line(bytes, &pos), "Binary:")) return error.ExpectedBinaryRaw;
        const width: usize = if (is_complex) 16 else 8;
        const size = try std.math.mul(usize, try std.math.mul(usize, rows, cols), width);
        if (size > bytes.len - pos) return error.TruncatedRaw;
        const data = std.mem.bytesAsSlice(f64, bytes[pos..][0..size]);
        for (data) |v| if (!std.math.isFinite(v)) return error.NonfiniteOutput;
        try plots.append(a, .{ .name = name orelse return error.InvalidRawHeader, .names = names, .rows = rows, .complex = is_complex, .data = data });
        pos += size;
    }
    if (plots.items.len == 0) return error.MissingPlots;
    return plots.toOwnedSlice(a);
}

fn number(value: Json) !f64 {
    const n: f64 = switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => return error.InvalidOracle,
    };
    if (!std.math.isFinite(n)) return error.InvalidOracle;
    return n;
}
fn string(value: Json) ![]const u8 {
    return if (value == .string) value.string else error.InvalidOracle;
}
fn array(value: Json) ![]const Json {
    return if (value == .array) value.array.items else error.InvalidOracle;
}
fn field(value: Json, key: []const u8) !Json {
    if (value != .object) return error.InvalidOracle;
    return value.object.get(key) orelse error.InvalidOracle;
}
fn scalar(value: Json) !Complex {
    if (value != .array) return .init(try number(value), 0);
    const pair = try array(value);
    if (pair.len != 2) return error.InvalidOracle;
    return .init(try number(pair[0]), try number(pair[1]));
}
fn close(actual: Complex, expected: Complex, rtol: f64, atol: f64) bool {
    return std.math.hypot(actual.re - expected.re, actual.im - expected.im) <= atol + rtol * std.math.hypot(expected.re, expected.im);
}
fn tolerance(rtol: f64, atol: f64) !void {
    if (!std.math.isFinite(rtol) or !std.math.isFinite(atol) or rtol < 0 or atol < 0) return error.InvalidOracle;
}

fn validateOracle(oracle: Oracle) !void {
    if (oracle.schema_version != 1 or oracle.netlist_sha256.len != 64) return error.InvalidOracle;
    if (oracle.expect.status == .@"error") {
        if (oracle.expect.category == null) return error.InvalidOracle;
        return;
    }
    if (oracle.expect.plots.len == 0 and oracle.expect.checks.len == 0) return error.EmptyOracle;
    for (oracle.expect.plots) |p| {
        if (p.match != .samples and p.row_count == null) return error.InvalidOracle;
        if (p.match == .samples and p.axis == null) return error.InvalidOracle;
        const count: usize = if (p.match == .selected_rows) p.row_indices.len else if (p.axis) |axis| axis.values.len else p.row_count.?;
        if (p.match == .exact or p.match == .unordered) if (count != p.row_count.?) return error.InvalidOracle;
        if (p.match == .selected_rows) for (p.row_indices, 0..) |index, i| {
            if (index >= p.row_count.? or (i > 0 and index <= p.row_indices[i - 1])) return error.InvalidOracle;
        };
        if (p.axis) |axis| {
            try tolerance(axis.rtol, axis.atol);
            if (axis.values.len != count) return error.InvalidOracle;
            for (axis.values, 0..) |v, i| {
                if (!std.math.isFinite(v)) return error.InvalidOracle;
                if (p.match == .samples and i > 0 and v <= axis.values[i - 1]) return error.InvalidOracle;
            }
        }
        for (p.columns.map.values()) |col| {
            try tolerance(col.rtol, col.atol);
            if (col.values.len != count) return error.InvalidOracle;
            for (col.values) |v| _ = try scalar(v);
        }
    }
    for (oracle.expect.checks) |check| _ = try checkKind(check);
}

fn plotName(actual: []const u8, expected: []const u8) bool {
    if (equal(actual, expected)) return true;
    return equal(expected, "Fourier Analysis") and std.mem.startsWith(u8, actual, "Fourier Analysis (THD = ");
}

fn findPlot(plots: []const Plot, name: []const u8) !Plot {
    var found: ?Plot = null;
    for (plots) |p| if (plotName(p.name, name)) {
        if (found != null) return error.AmbiguousPlot;
        found = p;
    };
    return found orelse error.MissingPlot;
}

fn compare(a: Allocator, expected: Expectation, plots: []const Plot) !void {
    const used = try a.alloc(bool, plots.len);
    @memset(used, false);
    for (expected.plots) |p| {
        var chosen: ?usize = null;
        for (plots, 0..) |actual, i| {
            if (used[i] or !plotName(actual.name, p.name)) continue;
            if (p.input_source) |source| {
                // Ngspice carries the source identity in its impedance column.
                // Generic app TF columns use directive order for repeated plots.
                var identified = false;
                var matches = false;
                for (actual.names) |name| if (std.mem.indexOf(u8, name, "#input_impedance")) |end| {
                    identified = true;
                    matches = matches or equal(std.mem.trimStart(u8, name[0..end], "v("), source);
                };
                if (identified and !matches) continue;
            }
            chosen = i;
            break;
        }
        const i = chosen orelse {
            diagnostic("  missing plot: {s}\n", .{p.name});
            return error.MissingPlot;
        };
        used[i] = true;
        comparePlot(a, p, plots[i]) catch |err| {
            diagnostic("  plot: {s}\n", .{p.name});
            return err;
        };
    }
    for (expected.checks) |check| try compareCheck(a, check, plots);
}

fn comparePlot(a: Allocator, expected: ExpectedPlot, actual: Plot) !void {
    for (expected.columns.map.keys()) |name| _ = try actual.column(name);
    if (expected.row_count) |count| if (count != actual.rows) {
        diagnostic("  rows: expected {d}, got {d}\n", .{ count, actual.rows });
        return error.RowCountMismatch;
    };
    if (expected.match == .unordered) {
        const owners = try a.alloc(?u32, actual.rows);
        const seen = try a.alloc(bool, actual.rows);
        @memset(owners, null);
        for (0..actual.rows) |row| {
            @memset(seen, false);
            if (!try assignRow(expected, actual, @intCast(row), owners, seen)) return error.UnmatchedRow;
        }
        return;
    }
    if (expected.axis) |axis| {
        const c = try actual.column(axis.name);
        if (expected.match == .samples) {
            try increasing(actual, c);
        } else {
            for (axis.values, 0..) |v, j| {
                const row = if (expected.match == .selected_rows) expected.row_indices[j] else j;
                try checkValue(axis.name, row, actual.value(row, c), .init(v, 0), axis.rtol, axis.atol);
            }
        }
    }
    for (expected.columns.map.keys(), expected.columns.map.values()) |name, col| {
        const c = actual.column(name) catch |err| {
            diagnostic("  missing/ambiguous column: {s}\n", .{name});
            return err;
        };
        for (col.values, 0..) |v, j| {
            const row = if (expected.match == .selected_rows) expected.row_indices[j] else j;
            const got = if (expected.match == .samples) blk: {
                const axis = expected.axis.?;
                break :blk try sample(actual, try actual.column(axis.name), c, axis.values[j], axis.rtol, axis.atol);
            } else actual.value(row, c);
            try checkValue(name, row, got, try scalar(v), col.rtol, col.atol);
        }
    }
}

// Augmenting paths preserve multiplicity even when tolerance regions overlap.
// Greedily taking the first close root can reject an otherwise valid pairing.
fn assignRow(expected: ExpectedPlot, actual: Plot, row: u32, owners: []?u32, seen: []bool) anyerror!bool {
    for (0..actual.rows) |candidate| {
        if (seen[candidate]) continue;
        var matches = true;
        for (expected.columns.map.keys(), expected.columns.map.values()) |name, col| {
            matches = matches and close(actual.value(candidate, try actual.column(name)), try scalar(col.values[row]), col.rtol, col.atol);
        }
        if (expected.axis) |axis| matches = matches and close(actual.value(candidate, try actual.column(axis.name)), .init(axis.values[row], 0), axis.rtol, axis.atol);
        if (!matches) continue;
        seen[candidate] = true;
        if (owners[candidate]) |previous| if (!try assignRow(expected, actual, previous, owners, seen)) continue;
        owners[candidate] = row;
        return true;
    }
    return false;
}

fn checkValue(name: []const u8, row: usize, actual: Complex, expected: Complex, rtol: f64, atol: f64) !void {
    if (close(actual, expected, rtol, atol)) return;
    diagnostic("  {s}[{d}]: expected ({e},{e}), got ({e},{e}); rtol={e}, atol={e}\n", .{ name, row, expected.re, expected.im, actual.re, actual.im, rtol, atol });
    return error.ValueMismatch;
}

fn increasing(p: Plot, axis: usize) !void {
    if (p.rows == 0) return error.EmptyTimeAxis;
    for (0..p.rows) |r| {
        const t = p.value(r, axis);
        if (t.im != 0 or (r > 0 and t.re <= p.value(r - 1, axis).re)) return error.NonmonotonicAxis;
    }
}

fn sample(p: Plot, axis: usize, col: usize, t: f64, rtol: f64, atol: f64) !Complex {
    if (p.rows == 0) return error.MissingSamples;
    const first = p.value(0, axis).re;
    const last = p.value(p.rows - 1, axis).re;
    if (t < first) {
        if (close(.init(first, 0), .init(t, 0), rtol, atol)) return p.value(0, col);
        return error.MissingTimeCoverage;
    }
    if (t > last) {
        if (close(.init(last, 0), .init(t, 0), rtol, atol)) return p.value(p.rows - 1, col);
        return error.MissingTimeCoverage;
    }
    var lo: usize = 0;
    var hi: usize = p.rows - 1;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (p.value(mid, axis).re <= t) lo = mid else hi = mid;
    }
    if (t == p.value(lo, axis).re) return p.value(lo, col);
    if (t == p.value(hi, axis).re) return p.value(hi, col);
    const fraction = (t - p.value(lo, axis).re) / (p.value(hi, axis).re - p.value(lo, axis).re);
    const x = p.value(lo, col);
    const y = p.value(hi, col);
    return .init(x.re + fraction * (y.re - x.re), x.im + fraction * (y.im - x.im));
}

const Check = enum { selected_values, fourier_thd, sample_moments, repeatability, pole_zero_sets, axis_bounds, time_weighted_moments };
fn checkKind(check: Json) !Check {
    const kinds = std.StaticStringMap(Check).initComptime(.{
        .{ "selected_values", .selected_values },             .{ "fourier_thd", .fourier_thd },
        .{ "sample_moments", .sample_moments },               .{ "repeatability", .repeatability },
        .{ "pole_zero_sets", .pole_zero_sets },               .{ "axis_bounds", .axis_bounds },
        .{ "time_weighted_moments", .time_weighted_moments },
    });
    return kinds.get(try string(try field(check, "kind"))) orelse error.UnknownCheck;
}
fn nfield(value: Json, key: []const u8) !f64 {
    return number(try field(value, key));
}
fn between(value: f64, minimum: f64, maximum: f64) !void {
    if (minimum > maximum) return error.InvalidOracle;
    if (std.math.isFinite(value) and value >= minimum and value <= maximum) return;
    diagnostic("  value {e} outside [{e}, {e}]\n", .{ value, minimum, maximum });
    return error.StatisticMismatch;
}

fn compareCheck(a: Allocator, check: Json, plots: []const Plot) !void {
    const kind = try checkKind(check);
    if (kind == .repeatability) {
        if ((try field(check, "same_netlist")) != .bool or !(try field(check, "same_netlist")).bool or
            !equal(try string(try field(check, "comparison")), "bitwise_numeric_results")) return error.InvalidOracle;
        return; // runCase performs the second subprocess invocation.
    }
    const p = try findPlot(plots, if (kind == .fourier_thd) "Fourier Analysis" else try string(try field(check, "plot")));
    switch (kind) {
        .repeatability => unreachable,
        .axis_bounds => {
            const col = try p.column(try string(try field(check, "axis")));
            const minimum = try nfield(check, "minimum");
            const maximum = try nfield(check, "maximum");
            if (p.rows == 0) return error.MissingSamples;
            for (0..p.rows) |r| {
                const v = p.value(r, col);
                if (v.im != 0) return error.ComplexAxis;
                try between(v.re, minimum, maximum);
            }
        },
        .selected_values => {
            const col = try p.column(try string(try field(check, "column")));
            const axis = try p.column(try string(try field(check, "axis")));
            const coordinates = try array(try field(check, "coordinates"));
            const values = try array(try field(check, "values"));
            const atol = try nfield(check, "atol");
            const period = try nfield(check, "period");
            if (coordinates.len != values.len or period <= 0 or atol < 0) return error.InvalidOracle;
            for (coordinates, values) |coordinate, expected| {
                var found: ?usize = null;
                for (0..p.rows) |r| if (p.value(r, axis).re == try number(coordinate)) {
                    if (found != null) return error.AmbiguousCoordinate;
                    found = r;
                };
                const value = p.value(found orelse return error.MissingCoordinate, col);
                const delta = @mod(value.re - try number(expected) + period / 2, period) - period / 2;
                try checkValue(p.names[col], found.?, .init(delta, value.im), .init(0, 0), 0, atol);
            }
        },
        .fourier_thd => {
            const harmonic = try p.column("harmonic");
            const magnitude = try p.column("magnitude");
            var fundamental: ?f64 = null;
            var sum: f64 = 0;
            for (0..p.rows) |r| {
                const h = p.value(r, harmonic).re;
                const v = p.value(r, magnitude);
                if (v.im != 0 or h < 0 or @trunc(h) != h) return error.InvalidHarmonics;
                if (h == 1) {
                    if (fundamental != null) return error.InvalidHarmonics;
                    fundamental = v.re;
                } else if (h > 1) sum += v.re * v.re;
            }
            const f = fundamental orelse return error.MissingFundamental;
            if (f <= 0) return error.MissingFundamental;
            try between(100 * @sqrt(sum) / f, try nfield(check, "percent_min"), try nfield(check, "percent_max"));
        },
        .sample_moments => {
            if (@as(f64, @floatFromInt(p.rows)) != try nfield(check, "row_count") or p.rows < 2) return error.RowCountMismatch;
            const col = try p.column(try string(try field(check, "column")));
            var mean: f64 = 0;
            var m2: f64 = 0;
            for (0..p.rows) |r| {
                const v = p.value(r, col);
                if (v.im != 0) return error.ExpectedRealStatistic;
                const delta = v.re - mean;
                mean += delta / @as(f64, @floatFromInt(r + 1));
                m2 += delta * (v.re - mean);
            }
            try between(mean, try nfield(check, "mean_min"), try nfield(check, "mean_max"));
            try between(@sqrt(m2 / @as(f64, @floatFromInt(p.rows - 1))), try nfield(check, "stddev_min"), try nfield(check, "stddev_max"));
        },
        .time_weighted_moments => {
            const col = try p.column(try string(try field(check, "column")));
            const axis = try p.column("time");
            try increasing(p, axis);
            const window = try array(try field(check, "time_window"));
            if (window.len != 2) return error.InvalidOracle;
            const start = try number(window[0]);
            const stop = try number(window[1]);
            if (stop <= start) return error.InvalidOracle;
            if (p.value(0, axis).re > start or p.value(p.rows - 1, axis).re < stop) return error.MissingTimeCoverage;
            var count: u32 = 0;
            var integral: f64 = 0;
            var square: f64 = 0;
            for (0..p.rows) |r| {
                const t = p.value(r, axis).re;
                if (t >= start and t <= stop) count += 1;
                if (r == 0) continue;
                const left = @max(start, p.value(r - 1, axis).re);
                const right = @min(stop, t);
                if (left >= right) continue;
                const v0 = try sample(p, axis, col, left, 0, 0);
                const v1 = try sample(p, axis, col, right, 0, 0);
                if (v0.im != 0 or v1.im != 0) return error.ExpectedRealStatistic;
                integral += (right - left) * (v0.re + v1.re) / 2;
                square += (right - left) * (v0.re * v0.re + v1.re * v1.re) / 2;
            }
            if (@as(f64, @floatFromInt(count)) < try nfield(check, "min_points")) return error.MissingSamples;
            const mean = integral / (stop - start);
            try between(@abs(mean), 0, try nfield(check, "mean_abs_max"));
            try between(square / (stop - start) - mean * mean, try nfield(check, "variance_min"), try nfield(check, "variance_max"));
        },
        .pole_zero_sets => {
            const rtol = try nfield(check, "rtol");
            const atol = try nfield(check, "atol");
            try tolerance(rtol, atol);
            const multiplicity = try field(check, "multiplicity");
            if (multiplicity != .bool or !multiplicity.bool) return error.InvalidOracle;
            for ([_][]const u8{ "pole", "zero" }, [_][]const u8{ "poles", "zeros" }) |prefix, key| {
                var roots: std.ArrayList(Complex) = .empty;
                for (p.names, 0..) |name, c| {
                    const bare = if (std.mem.startsWith(u8, name, "v(")) name[2 .. name.len - 1] else name;
                    if (equal(bare, prefix)) {
                        for (0..p.rows) |r| try roots.append(a, p.value(r, c));
                    } else if (std.mem.startsWith(u8, bare, prefix) and bare.len > prefix.len and bare[prefix.len] == '(') {
                        if (p.rows != 1) return error.InvalidRootLayout;
                        try roots.append(a, p.value(0, c));
                    }
                }
                const expected = try array(try field(check, key));
                if (roots.items.len != expected.len) return error.RootCountMismatch;
                var columns: std.json.ArrayHashMap(Column) = .{};
                try columns.map.put(a, prefix, .{ .values = expected, .rtol = rtol, .atol = atol });
                const data = try a.alloc(f64, 2 * roots.items.len);
                for (roots.items, 0..) |root, i| {
                    data[2 * i] = root.re;
                    data[2 * i + 1] = root.im;
                }
                const root_plot: Plot = .{ .name = p.name, .names = &.{prefix}, .rows = @intCast(roots.items.len), .complex = true, .data = data };
                comparePlot(a, .{ .name = p.name, .match = .unordered, .row_count = root_plot.rows, .columns = columns }, root_plot) catch |err| return if (err == error.UnmatchedRow) error.UnmatchedRoot else err;
            }
        },
    }
}

fn repeatable(first: []const Plot, second: []const Plot) !void {
    if (first.len != second.len) return error.NotRepeatable;
    for (first, second) |p, q| {
        if (!equal(p.name, q.name) or p.rows != q.rows or p.complex != q.complex or p.names.len != q.names.len) return error.NotRepeatable;
        for (p.names, q.names) |x, y| if (!equal(x, y)) return error.NotRepeatable;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(p.data), std.mem.sliceAsBytes(q.data))) return error.NotRepeatable;
    }
}

test "every discovered fixture has a valid oracle and matching source hash" {
    try std.testing.expect(spice_files.len > 0);
    for (spice_files, expected_outputs) |path, json| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const oracle = try std.json.parseFromSliceLeaky(Oracle, a, json, .{ .ignore_unknown_fields = true });
        validateOracle(oracle) catch |err| {
            std.debug.print("invalid oracle: {s}\n", .{path});
            return err;
        };
        const source = try Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "tests/{s}", .{path}), a, .unlimited);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
        try std.testing.expectEqualStrings(oracle.netlist_sha256, &std.fmt.bytesToHex(digest, .lower));
    }
}

test "raw parser rejects truncated and nonfinite data and reads concatenated plots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const header = "Title: test\nPlotname: AC Analysis\nFlags: complex\nNo. Variables: 2\nNo. Points: 1\nVariables:\n0 frequency frequency\n1 v(out) voltage\nBinary:\n";
    const data = [_]f64{ 1, 0, 0.5, -0.5 };
    const blob = try std.mem.concat(a, u8, &.{ header, std.mem.sliceAsBytes(&data), header, std.mem.sliceAsBytes(&data) });
    const plots = try parseRaw(a, blob);
    try std.testing.expectEqual(@as(usize, 2), plots.len);
    try std.testing.expectEqual(@as(f64, -0.5), plots[1].value(0, 1).im);
    try std.testing.expectError(error.TruncatedRaw, parseRaw(a, blob[0 .. blob.len - 1]));
    const bad = [_]f64{ 1, 0, std.math.nan(f64), 0 };
    try std.testing.expectError(error.NonfiniteOutput, parseRaw(a, try std.mem.concat(a, u8, &.{ header, std.mem.sliceAsBytes(&bad) })));
}

test "numeric matching covers row indices, interpolation, phase and multiplicity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"name":"Transient Analysis","match":"samples","axis":{"name":"time","values":[0,0.5,1],"rtol":0,"atol":0},"columns":{"v(out)":{"values":[0,1,2],"rtol":0,"atol":1e-12}}}
    ;
    var expected = try std.json.parseFromSliceLeaky(ExpectedPlot, a, json, .{});
    const p: Plot = .{ .name = "Transient Analysis", .names = &.{ "time", "v(out)" }, .rows = 3, .complex = false, .data = &.{ 0, 0, 0.75, 1.5, 1, 2 } };
    try comparePlot(a, expected, p);
    try std.testing.expectError(error.MissingTimeCoverage, sample(p, 0, 1, -0.1, 0, 0));
    expected.match = .exact;
    expected.row_count = 3;
    try std.testing.expectError(error.ValueMismatch, comparePlot(a, expected, p));
    const selected = try std.json.parseFromSliceLeaky(ExpectedPlot, a,
        \\{"name":"Transient Analysis","match":"selected_rows","row_count":3,"row_indices":[0,2],"columns":{"v(out)":{"values":[0,2],"rtol":0,"atol":0}}}
    , .{});
    try comparePlot(a, selected, p);
    var short = p;
    short.rows = 2;
    try std.testing.expectError(error.RowCountMismatch, comparePlot(a, selected, short));
    try std.testing.expect(!close(.init(0, 1), .init(0, -1), 1e-3, 0));
    try std.testing.expect(!close(.init(1e-9, 0), .init(2e-9, 0), 1e-3, 0));
    const roots = try std.json.parseFromSliceLeaky(ExpectedPlot, a,
        \\{"name":"Pole-Zero Analysis","match":"unordered","row_count":2,"columns":{"pole":{"values":[[-1,0],[-1,0]],"rtol":0,"atol":0}}}
    , .{});
    const duplicate: Plot = .{ .name = "Pole-Zero Analysis", .names = &.{"pole"}, .rows = 2, .complex = true, .data = &.{ -1, 0, -2, 0 } };
    try std.testing.expectError(error.UnmatchedRow, comparePlot(a, roots, duplicate));
    const overlapping = try std.json.parseFromSliceLeaky(ExpectedPlot, a,
        \\{"name":"Pole-Zero Analysis","match":"unordered","row_count":2,"columns":{"pole":{"values":[0,1],"rtol":0,"atol":0.75}}}
    , .{});
    const shuffled: Plot = .{ .name = "Pole-Zero Analysis", .names = &.{"pole"}, .rows = 2, .complex = false, .data = &.{ 0.5, -0.5 } };
    try comparePlot(a, overlapping, shuffled);
    const wrong: Plot = .{ .name = p.name, .names = p.names, .rows = p.rows, .complex = false, .data = &.{ 0, 0, 0.75, 1.5, 1, 3 } };
    try std.testing.expectError(error.NotRepeatable, repeatable(&.{p}, &.{wrong}));
}

test "statistical checks measure samples and reject biased output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const check = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"sample_moments","plot":"Monte Carlo","column":"v(out)","row_count":3,"mean_min":0.99,"mean_max":1.01,"stddev_min":0.99,"stddev_max":1.01}
    , .{});
    const p: Plot = .{ .name = "Monte Carlo", .names = &.{"v(out)"}, .rows = 3, .complex = false, .data = &.{ 0, 1, 2 } };
    try compareCheck(a, check, &.{p});
    var biased = p;
    biased.data = &.{ 1, 2, 3 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, check, &.{biased}));
    try std.testing.expectError(error.UnknownCheck, checkKind(try std.json.parseFromSliceLeaky(Json, a, "{\"kind\":\"typo\"}", .{})));
}

test "invalid decks require the intended diagnostic instead of arbitrary failure" {
    try checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("Error: example.sp: InvalidQueryOptions\n") });
    try std.testing.expectError(error.WrongDiagnostic, checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("Error: ModelNotFound\n") }));
    try std.testing.expectError(error.WrongDiagnostic, checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 1 }, .stdout = @constCast(""), .stderr = @constCast("Error: InvalidQueryOptions.sp: ModelNotFound\n") }));
    try std.testing.expectError(error.ExpectedDiagnosticExit, checkRejection("invalid_analysis_arguments", .{ .term = .{ .exited = 2 }, .stdout = @constCast(""), .stderr = @constCast("Usage: espice FILE\n") }));
}

test "deadline kills a simulator that closes output streams before hanging" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "simulator", .data = "#!/bin/sh\nexec 1>&- 2>&-\nexec sleep 5\n", .flags = .{ .permissions = .fromMode(0o755) } });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app = try tmp.dir.realPathFileAlloc(io, "simulator", a);
    try std.testing.expectError(error.Timeout, simulate(a, io, app, "tests/fixtures/op/divider_default.sp", "/dev/null", 1));
}

test "time statistics, phase wrap, THD, axis bounds and root sets are enforced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const waveform: Plot = .{ .name = "Transient Noise Analysis", .names = &.{ "time", "v(out)" }, .rows = 3, .complex = false, .data = &.{ 0, -1, 0.5, 1, 1, -1 } };
    const moments = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"time_weighted_moments","plot":"Transient Noise Analysis","column":"v(out)","time_window":[0,1],"min_points":3,"mean_abs_max":0.01,"variance_min":0.99,"variance_max":1.01}
    , .{});
    try compareCheck(a, moments, &.{waveform});
    var silent = waveform;
    silent.data = &.{ 0, 0, 0.5, 0, 1, 0 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, moments, &.{silent}));
    const bounds = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"axis_bounds","plot":"Transient Noise Analysis","axis":"time","minimum":0.5,"maximum":1}
    , .{});
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, bounds, &.{waveform}));
    const spectrum: Plot = .{ .name = "Fourier Analysis (THD = 0.0000 %)", .names = &.{ "harmonic", "magnitude", "phase_deg" }, .rows = 3, .complex = false, .data = &.{ 0, 0, 0, 1, 1, 270, 2, 0, 0 } };
    const phase = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"selected_values","plot":"Fourier Analysis","axis":"harmonic","coordinates":[1],"column":"phase_deg","values":[-90],"atol":0.01,"period":360}
    , .{});
    try compareCheck(a, phase, &.{spectrum});
    const thd = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"fourier_thd","percent_min":0,"percent_max":0.1}
    , .{});
    try compareCheck(a, thd, &.{spectrum});
    var distorted = spectrum;
    distorted.data = &.{ 0, 0, 0, 1, 1, 270, 2, 0.1, 0 };
    try std.testing.expectError(error.StatisticMismatch, compareCheck(a, thd, &.{distorted}));
    const roots: Plot = .{ .name = "Pole-Zero Analysis", .names = &.{ "pole(1)", "zero(1)", "pole(2)" }, .rows = 1, .complex = true, .data = &.{ -2, 0, 0, 0, -1, 0 } };
    const sets = try std.json.parseFromSliceLeaky(Json, a,
        \\{"kind":"pole_zero_sets","plot":"Pole-Zero Analysis","poles":[[-1,0],[-2,0]],"zeros":[[0,0]],"rtol":0,"atol":0,"multiplicity":true}
    , .{});
    try compareCheck(a, sets, &.{roots});
    var wrong = roots;
    wrong.data = &.{ -2, 0, 0, 0, -2, 0 };
    try std.testing.expectError(error.UnmatchedRoot, compareCheck(a, sets, &.{wrong}));
}
