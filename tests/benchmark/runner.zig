//! `zig build bench`: times espice, ngspice and VACASK on every deck under a
//! directory and writes a markdown table of medians and pairwise waveform
//! agreement. Runs are serial, since concurrent runs distort each other's
//! timings.
//!   nix develop .#benchmarking --command zig build bench -- --iters 3 --filter op/
//! `--espice LABEL=WORD,...` (repeatable) adds an espice column; a word is a
//! flag, or an environment assignment when it has `=` and no leading `-`.
//! Without it the one column is `espice=--backend=cpu`. `--ngspice none` or
//! `--vacask none` drops that reference.
//!   zig build bench-postlayout -- --espice cpu8=ESPICE_THREADS=8,--backend=cpu
const std = @import("std");
const Io = std.Io;
const ngspice = @import("ngspice.zig");
const vacask = @import("vacask.zig");
const compare = @import("compare.zig");
const common = @import("job.zig");
const Allocator = std.mem.Allocator;

/// One espice configuration: its column label, the `KEY=VALUE` environment
/// words and the flags.
const Variant = struct { label: []const u8, env: []const []const u8, flags: []const []const u8 };
const Config = struct {
    espice: []const u8,
    variants: []const Variant = &.{},
    /// ngspice, VACASK; "none" skips one.
    refs: [2][]const u8 = .{ "ngspice", "vacask" },
    fixtures: []const u8,
    filter: []const u8 = "",
    iters: u16 = 3,
    timeout: u32 = 300,
    rtol: f64 = 1e-3,
    klu: bool = false,
    list: bool = false,
    report: []const u8 = "zig-out/benchmark-results.md",
};
/// Median wall time in ms and the plots of one engine on one fixture,
/// allocated in the fixture's arena.
const Measurement = struct { milliseconds: f64, plots: []const compare.Plot };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cfg = try arguments(a, io, init);
    const decks = try findDecks(a, io, cfg.fixtures, cfg.filter);
    if (decks.len == 0) return error.NoMatchingFixtures;
    if (cfg.list) {
        for (decks) |path| std.debug.print("{s}\n", .{path});
        std.debug.print("{d} fixtures\n", .{decks.len});
        return;
    }

    var report: Io.Writer.Allocating = .init(a);
    var notes: Io.Writer.Allocating = .init(a);
    const w = &report.writer;
    try w.writeAll("# Simulator benchmark\n\n");
    for ([_][]const u8{ "espice", "ngspice", "vacask" }, [_][]const u8{ cfg.espice, cfg.refs[0], cfg.refs[1] }, [_][]const u8{ "--version", ngspice.version_flag, vacask.version_flag }) |engine, bin, flag| {
        if (std.mem.eql(u8, bin, "none")) continue;
        const version = try std.process.run(a, io, .{ .argv = &.{ bin, flag }, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
        const banner = if (version.stdout.len > 0) version.stdout else version.stderr;
        const text = std.mem.trim(u8, banner, " \t\r\n*");
        try w.print("- {s}: `{s}` — {s}\n", .{ engine, bin, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len] });
    }
    for (cfg.variants) |v| try w.print("- column {s}: `{s} espice {s}`\n", .{ v.label, try std.mem.join(a, " ", v.env), try std.mem.join(a, " ", v.flags) });
    try w.print("\nMedian of {d} measured runs after one warm-up; milliseconds include process startup and output. VACASK conversion is outside timing.\n\n", .{cfg.iters});

    // Columns: the espice variants, then ngspice and VACASK. Agreement: each
    // variant against each reference, then ngspice against VACASK.
    const nv = cfg.variants.len;
    const labels = try a.alloc([]const u8, nv + 2);
    for (cfg.variants, labels[0..nv]) |v, *l| l.* = v.label;
    labels[nv] = "ngspice";
    labels[nv + 1] = "VACASK";
    var pairs: std.ArrayList([2]usize) = .empty;
    for (0..nv) |i| try pairs.appendSlice(a, &.{ .{ i, nv }, .{ i, nv + 1 } });
    try pairs.append(a, .{ nv, nv + 1 });
    try w.writeAll("| Fixture |");
    for (labels) |l| try w.print(" {s} ms |", .{l});
    for (pairs.items) |p| try w.print(" {s}/{s} |", .{ labels[p[0]], labels[p[1]] });
    try w.writeAll("\n|---|");
    for (labels) |_| try w.writeAll("---:|");
    for (pairs.items) |_| try w.writeAll("---|");
    try w.writeByte('\n');
    std.debug.print("Benchmark: {d} fixtures, {d} repetitions; references from PATH/overrides\n", .{ decks.len, cfg.iters });
    var random: [16]u8 = undefined;
    io.random(&random);
    const scratch = try std.fmt.allocPrint(a, "zig-out/bench-out/{s}", .{std.fmt.bytesToHex(random, .lower)});
    try Io.Dir.cwd().createDirPath(io, scratch);

    for (decks, 0..) |relative, index| {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const fa = arena.allocator();
        const source = try Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(fa, "{s}/{s}", .{ cfg.fixtures, relative }), fa);
        const directory = try std.fmt.allocPrint(fa, "{s}/{d}", .{ scratch, index });
        try Io.Dir.cwd().createDirPath(io, directory);
        const absolute = try Io.Dir.cwd().realPathFileAlloc(io, directory, fa);
        const results = try fa.alloc(?Measurement, labels.len);
        const reasons = try fa.alloc([]const u8, labels.len);
        @memset(results, null);
        @memset(reasons, "");
        for (labels, 0..) |label, i| {
            const job: common.Job = if (i < nv) blk: {
                const v = cfg.variants[i];
                const raw = try std.fmt.allocPrint(fa, "{s}/{s}.raw", .{ absolute, label });
                const argv = try std.mem.concat(fa, []const u8, &.{
                    if (v.env.len > 0) &.{"env"} else &.{}, v.env,                                            &.{cfg.espice},
                    v.flags,                                &.{ "--format=binary", "-b", "-r", raw, source },
                });
                break :blk .{ .argv = argv, .cwd = .{ .path = std.fs.path.dirname(source).? }, .raw = raw };
            } else if (std.mem.eql(u8, cfg.refs[i - nv], "none"))
                .{ .refused = "not run" }
            else if (i == nv)
                try ngspice.prepare(io, fa, cfg.refs[0], source, try std.fmt.allocPrint(fa, "{s}/ngspice.raw", .{absolute}), cfg.klu)
            else
                try vacask.prepare(io, fa, cfg.refs[1], source, try std.fmt.allocPrint(fa, "{s}/vacask", .{absolute}));
            if (job.refused.len > 0) {
                reasons[i] = job.refused;
                continue;
            }
            results[i] = measure(io, fa, job, cfg.iters, cfg.timeout) catch |err| {
                reasons[i] = @errorName(err);
                continue;
            };
        }
        const row_start = report.written().len;
        try w.print("| {s} |", .{relative});
        for (results) |result| {
            if (result) |r| try w.print(" {d:.3} |", .{r.milliseconds}) else try w.writeAll(" — |");
        }
        for (pairs.items) |pair| {
            const left = results[pair[0]];
            const right = results[pair[1]];
            const accuracy = if (left != null and right != null) compare.compareRaws(fa, right.?.plots, left.?.plots, cfg.rtol) else null;
            try w.print(" {s} |", .{if (accuracy) |v| if (!v.complete) "incomplete" else if (v.pass) "agree" else "DIFFER" else "unavailable"});
        }
        try w.writeByte('\n');
        std.debug.print("{s}", .{report.written()[row_start..]});
        for (reasons, labels) |reason, label| {
            if (reason.len == 0) continue;
            try notes.writer.print("- {s} / {s}: {s}\n", .{ relative, label, reason });
            std.debug.print("  {s}: {s}\n", .{ label, reason });
        }
        // Publish progress after every case, so a later timeout cannot erase it.
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(cfg.report) orelse ".");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg.report, .data = report.written() });
    }
    try w.print("\n{s}", .{notes.written()});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg.report, .data = report.written() });
    std.debug.print("Report: {s}\nRaw outputs: {s}\n", .{ cfg.report, scratch });
}

/// Every `*.sp` under `root` whose relative path contains `filter`, sorted.
/// Files under a deck's side directory (`*.assets/`) are not decks.
fn findDecks(a: Allocator, io: Io, root: []const u8, filter: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".sp")) continue;
        if (std.mem.indexOf(u8, entry.path, ".assets/") != null or !matches(entry.path, filter)) continue;
        try paths.append(a, try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return paths.items;
}

fn arguments(a: Allocator, io: Io, init: std.process.Init) !Config {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const engine = args.next() orelse return error.MissingEngine;
    var cfg: Config = .{ .espice = try Io.Dir.cwd().realPathFileAlloc(io, engine, a), .fixtures = args.next() orelse return error.MissingFixtures };
    var variants: std.ArrayList(Variant) = .empty;
    const Flag = enum(u8) { list, klu, filter, iters, timeout, rtol, out, ngspice, vacask, espice };
    const flags = std.StaticStringMap(Flag).initComptime(.{
        .{ "--list", .list },     .{ "--ngspice-klu", .klu }, .{ "--filter", .filter },
        .{ "--iters", .iters },   .{ "--timeout", .timeout }, .{ "--rtol", .rtol },
        .{ "--out", .out },       .{ "--ngspice", .ngspice }, .{ "--vacask", .vacask },
        .{ "--espice", .espice },
    });
    while (args.next()) |arg| {
        const flag = flags.get(arg) orelse return error.UnknownArgument;
        if (flag == .list) {
            cfg.list = true;
            continue;
        }
        if (flag == .klu) {
            cfg.klu = true;
            continue;
        }
        const value = args.next() orelse return error.MissingArgument;
        switch (flag) {
            .filter => cfg.filter = value,
            .iters => cfg.iters = try std.fmt.parseInt(u16, value, 10),
            .timeout => cfg.timeout = try std.fmt.parseInt(u32, value, 10),
            .rtol => cfg.rtol = try std.fmt.parseFloat(f64, value),
            .out => cfg.report = value,
            .ngspice => cfg.refs[0] = value,
            .vacask => cfg.refs[1] = value,
            .espice => try variants.append(a, try parseVariant(a, value)),
            .list, .klu => unreachable,
        }
    }
    if (cfg.iters == 0 or cfg.timeout == 0 or cfg.rtol <= 0 or !std.math.isFinite(cfg.rtol)) return error.InvalidArgument;
    for (&cfg.refs) |*bin| if (std.mem.indexOfScalar(u8, bin.*, '/') != null) {
        bin.* = try Io.Dir.cwd().realPathFileAlloc(io, bin.*, a);
    };
    if (variants.items.len == 0) try variants.append(a, try parseVariant(a, "espice=--backend=cpu"));
    cfg.variants = variants.items;
    return cfg;
}

/// `LABEL=WORD,WORD,...`. A word with `=` and no leading `-` is an
/// environment assignment; the others are espice flags.
fn parseVariant(a: Allocator, spec: []const u8) !Variant {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidArgument;
    if (eq == 0) return error.InvalidArgument;
    var env: std.ArrayList([]const u8) = .empty;
    var flags: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, spec[eq + 1 ..], ',');
    while (words.next()) |word| {
        const is_env = word[0] != '-' and std.mem.indexOfScalar(u8, word, '=') != null;
        try (if (is_env) &env else &flags).append(a, word);
    }
    return .{ .label = spec[0..eq], .env = env.items, .flags = flags.items };
}

fn matches(path: []const u8, filter: []const u8) bool {
    return std.mem.indexOf(u8, path, filter) != null;
}

/// One warm-up plus `iters` timed runs under `timeout`, with process startup
/// and output included. Returns the median and the last run's plots.
fn measure(io: Io, a: Allocator, job: common.Job, iters: u16, seconds: u32) !Measurement {
    const timeout = try std.fmt.allocPrint(a, "{d}", .{seconds});
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "timeout", "--kill-after=5", timeout }, job.argv });
    const samples = try a.alloc(i96, iters);
    for (0..@as(usize, iters) + 1) |i| {
        // Clear previous output before each repetition. A successful process
        // which fails to publish cannot borrow the warm-up's waveform.
        if (job.raw.len > 0) Io.Dir.cwd().deleteFile(io, job.raw) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (job.raw.len == 0) try clearRaws(io, job.cwd.path);
        const log_path = try std.fmt.allocPrint(a, "{s}.log", .{if (job.raw.len > 0) job.raw else job.cwd.path});
        const log = try Io.Dir.cwd().createFile(io, log_path, .{});
        defer log.close(io);
        const start = Io.Timestamp.now(io, .awake);
        var child = try std.process.spawn(io, .{ .argv = argv, .cwd = job.cwd, .stdin = .ignore, .stdout = if (i == 0) .{ .file = log } else .ignore, .stderr = .{ .file = log } });
        defer child.kill(io);
        const term = try child.wait(io);
        const elapsed = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        if (term != .exited or term.exited != 0) return if (term == .exited and term.exited == 124) error.Timeout else error.SimulatorFailed;
        if (i > 0) samples[i - 1] = elapsed;
        if (job.raw.len > 0) try Io.Dir.cwd().access(io, job.raw, .{});
    }
    std.mem.sort(i96, samples, {}, std.sort.asc(i96));
    const median: f64 = if (samples.len % 2 == 1) @floatFromInt(samples[samples.len / 2]) else (@as(f64, @floatFromInt(samples[samples.len / 2 - 1])) + @as(f64, @floatFromInt(samples[samples.len / 2]))) / 2;
    const plots = if (job.raw.len > 0) compare.parseRawFile(io, a, job.raw) orelse return error.MissingOrInvalidRaw else try vacaskPlots(io, a, job.cwd.path);
    return .{ .milliseconds = median / 1e6, .plots = plots };
}

fn clearRaws(io: Io, path: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".raw")) {
        try dir.deleteFile(io, entry.name);
    };
}

/// The plots of every raw file VACASK wrote into `path`, in file-name order.
fn vacaskPlots(io: Io, a: Allocator, path: []const u8) ![]const compare.Plot {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".raw")) {
        try names.append(a, try a.dupe(u8, entry.name));
    };
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var plots: std.ArrayList(compare.Plot) = .empty;
    for (names.items) |name| {
        const raw = try dir.readFileAlloc(io, name, a, .unlimited);
        try plots.appendSlice(a, compare.parseRawBlob(a, raw) orelse return error.InvalidRaw);
    }
    if (plots.items.len == 0) return error.MissingRaw;
    return plots.toOwnedSlice(a);
}

test "an espice variant splits environment from flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseVariant(arena.allocator(), "cpu8=ESPICE_THREADS=8,--backend=cpu");
    try std.testing.expectEqualStrings("cpu8", v.label);
    try std.testing.expectEqualStrings("ESPICE_THREADS=8", v.env[0]);
    try std.testing.expectEqual(@as(usize, 1), v.env.len);
    try std.testing.expectEqualStrings("--backend=cpu", v.flags[0]);
    try std.testing.expectError(error.InvalidArgument, parseVariant(arena.allocator(), "unlabelled"));
}

test {
    _ = ngspice;
    _ = vacask;
    _ = compare;
}
