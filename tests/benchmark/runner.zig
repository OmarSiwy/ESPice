//! nix develop .#benchmarking --command zig build bench -- --iters 3 --filter op/
//! Fixtures come from the shared build-generated catalog. Timings are serial:
//! parallel correctness is `zig build test`; competing timings distort results.
const std = @import("std");
const Io = std.Io;
const ngspice = @import("ngspice.zig");
const vacask = @import("vacask.zig");
const compare = @import("compare.zig");
const common = @import("job.zig");
const catalog = @import("fixture_catalog");
const Allocator = std.mem.Allocator;

// Each engine's label, binary and adapter are selected together by this index.
const Engine = enum(u8) { espice, ngspice, vacask };
const Config = struct {
    bins: [3][]const u8,
    fixtures: []const u8,
    filter: []const u8 = "",
    iters: u16 = 3,
    timeout: u32 = 300,
    rtol: f64 = 1e-3,
    klu: bool = false,
    list: bool = false,
    report: []const u8 = "zig-out/benchmark-results.md",
};
// A row is consumed as a whole for reporting, and owns slices in the case arena.
const Measurement = struct { milliseconds: f64, plots: []const compare.Plot };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cfg = try arguments(a, io, init);
    var matched: u32 = 0;
    for (catalog.spice_files) |path| if (matches(path, cfg.filter)) {
        matched += 1;
    };
    if (matched == 0) return error.NoMatchingFixtures;
    if (cfg.list) {
        for (catalog.spice_files) |path| if (matches(path, cfg.filter)) {
            std.debug.print("{s}\n", .{path});
        };
        std.debug.print("{d} fixtures\n", .{matched});
        return;
    }

    var report: Io.Writer.Allocating = .init(a);
    var notes: Io.Writer.Allocating = .init(a);
    const w = &report.writer;
    try w.writeAll("# Simulator benchmark\n\n");
    for (std.enums.values(Engine), cfg.bins) |engine, bin| {
        const flag = switch (engine) {
            .espice => "--version",
            .ngspice => ngspice.version_flag,
            .vacask => vacask.version_flag,
        };
        const version = try std.process.run(a, io, .{ .argv = &.{ bin, flag }, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
        const banner = if (version.stdout.len > 0) version.stdout else version.stderr;
        const text = std.mem.trim(u8, banner, " \t\r\n*");
        try w.print("- {s}: `{s}` — {s}\n", .{ @tagName(engine), bin, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len] });
    }
    try w.print("\nMedian of {d} measured runs after one warm-up; milliseconds include process startup and output. VACASK conversion is outside timing.\n\n", .{cfg.iters});
    try w.writeAll("| Fixture | ESPice ms | ngspice ms | VACASK ms | ESPice/ngspice | ESPice/VACASK | ngspice/VACASK |\n|---|---:|---:|---:|---|---|---|\n");
    std.debug.print("Benchmark: {d} fixtures, {d} repetitions; references from PATH/overrides\n", .{ matched, cfg.iters });
    var random: [16]u8 = undefined;
    io.random(&random);
    const scratch = try std.fmt.allocPrint(a, "zig-out/bench-out/{s}", .{std.fmt.bytesToHex(random, .lower)});
    try Io.Dir.cwd().createDirPath(io, scratch);

    for (catalog.spice_files, 0..) |path, index| {
        if (!matches(path, cfg.filter)) continue;
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const fa = arena.allocator();
        const relative = path["fixtures/".len..];
        const source = try Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(fa, "{s}/{s}", .{ cfg.fixtures, relative }), fa);
        const directory = try std.fmt.allocPrint(fa, "{s}/{d}", .{ scratch, index });
        try Io.Dir.cwd().createDirPath(io, directory);
        const absolute = try Io.Dir.cwd().realPathFileAlloc(io, directory, fa);
        var results: [3]?Measurement = .{null} ** 3;
        var reasons: [3][]const u8 = .{""} ** 3;
        for (std.enums.values(Engine), 0..) |engine, i| {
            const raw = try std.fmt.allocPrint(fa, "{s}/{s}.raw", .{ absolute, @tagName(engine) });
            const job = switch (engine) {
                .espice => common.Job{
                    .argv = &.{ cfg.bins[i], "--backend=cpu", "--format=binary", "-b", "-r", raw, source },
                    .cwd = .{ .path = std.fs.path.dirname(source).? },
                    .raw = raw,
                },
                .ngspice => try ngspice.prepare(io, fa, cfg.bins[i], source, raw, cfg.klu),
                .vacask => try vacask.prepare(io, fa, cfg.bins[i], source, try std.fmt.allocPrint(fa, "{s}/vacask", .{absolute})),
            };
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
        for ([_][2]u8{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 } }) |pair| {
            const left = results[pair[0]];
            const right = results[pair[1]];
            const accuracy = if (left != null and right != null) compare.compareRaws(fa, right.?.plots, left.?.plots, cfg.rtol) else null;
            try w.print(" {s} |", .{if (accuracy) |v| if (!v.complete) "incomplete" else if (v.pass) "agree" else "DIFFER" else "unavailable"});
        }
        try w.writeByte('\n');
        std.debug.print("{s}", .{report.written()[row_start..]});
        for (reasons, std.enums.values(Engine)) |reason, engine| {
            if (reason.len == 0) continue;
            try notes.writer.print("- {s} / {s}: {s}\n", .{ relative, @tagName(engine), reason });
            std.debug.print("  {s}: {s}\n", .{ @tagName(engine), reason });
        }
        // Publish progress after every case, so a later timeout cannot erase it.
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(cfg.report) orelse ".");
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg.report, .data = report.written() });
    }
    try w.print("\n{s}", .{notes.written()});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg.report, .data = report.written() });
    std.debug.print("Report: {s}\nRaw outputs: {s}\n", .{ cfg.report, scratch });
}

fn arguments(a: Allocator, io: Io, init: std.process.Init) !Config {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const engine = args.next() orelse return error.MissingEngine;
    var cfg: Config = .{ .bins = .{ try Io.Dir.cwd().realPathFileAlloc(io, engine, a), "ngspice", "vacask" }, .fixtures = args.next() orelse return error.MissingFixtures };
    const Flag = enum(u8) { list, klu, filter, iters, timeout, rtol, out, ngspice, vacask };
    const flags = std.StaticStringMap(Flag).initComptime(.{
        .{ "--list", .list },   .{ "--ngspice-klu", .klu }, .{ "--filter", .filter },
        .{ "--iters", .iters }, .{ "--timeout", .timeout }, .{ "--rtol", .rtol },
        .{ "--out", .out },     .{ "--ngspice", .ngspice }, .{ "--vacask", .vacask },
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
            .ngspice => cfg.bins[1] = value,
            .vacask => cfg.bins[2] = value,
            .list, .klu => unreachable,
        }
    }
    if (cfg.iters == 0 or cfg.timeout == 0 or cfg.rtol <= 0 or !std.math.isFinite(cfg.rtol)) return error.InvalidArgument;
    for (cfg.bins[1..]) |*bin| if (std.mem.indexOfScalar(u8, bin.*, '/') != null) {
        bin.* = try Io.Dir.cwd().realPathFileAlloc(io, bin.*, a);
    };
    return cfg;
}

fn matches(path: []const u8, filter: []const u8) bool {
    return std.mem.indexOf(u8, path, filter) != null;
}

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

test {
    _ = ngspice;
    _ = vacask;
    _ = compare;
}
