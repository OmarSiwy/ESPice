//! CLI policy only; Problem owns preparation, query execution and delivery.
const std = @import("std");
const problem = @import("problem");
const output = @import("output");

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(init.gpa);
    var dialect: problem.Dialect = .ngspice;
    var selection: output.Selection = .{};
    var backend: problem.Request = .cpu;
    var explicit_gpu = false;
    var max_parallel: u16 = 1;
    var show_plan = false;
    var plan_only = false;
    var timing_in_depth = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\Usage: espice [OPTION]... FILE...
                \\  -b, --batch                 Run all queries (default)
                \\  -r, --rawfile=FILE          Result destination
                \\      --format=FMT            binary|ascii|csv|touchstone|psf|fsdb|sst2|citi|print
                \\      --backend=BE            cpu|auto|cuda|hip (default cpu)
                \\      --gpu                   Require an available GPU
                \\      --jobs=N                Maximum parallel queries (default 1)
                \\      --print-dag             Print the next query frontier before running
                \\      --plan                  Print the DAG without running analyses
                \\      --timing-in-depth       Time preparation, queries, and individual steps
                \\      --tokenizer=FMT         ngspice|hspice|spectre
                \\  -v, --version               Version
                \\
            , .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("espice 0.1.0\n", .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--batch")) {} else if (std.mem.eql(u8, arg, "--gpu")) {
            backend = .auto;
            explicit_gpu = true;
        } else if (std.mem.eql(u8, arg, "--plan")) {
            show_plan = true;
            plan_only = true;
        } else if (std.mem.eql(u8, arg, "--print-dag")) {
            show_plan = true;
        } else if (std.mem.eql(u8, arg, "--timing-in-depth")) {
            timing_in_depth = true;
        } else if (optionValue(arg, "-r", "--rawfile", &args)) |value| {
            selection.path = value orelse return usageFail();
        } else if (optionValue(arg, "", "--format", &args)) |value| {
            selection.format = output.parseFormat(value orelse return usageFail()) orelse return usageFail();
        } else if (optionValue(arg, "", "--backend", &args)) |value| {
            backend = std.StaticStringMap(problem.Request).initComptime(.{
                .{ "cpu", .cpu }, .{ "auto", .auto }, .{ "cuda", .cuda }, .{ "hip", .hip },
            }).get(value orelse return usageFail()) orelse return usageFail();
            explicit_gpu = explicit_gpu or backend == .cuda or backend == .hip;
        } else if (optionValue(arg, "", "--jobs", &args)) |value| {
            max_parallel = std.fmt.parseInt(u16, value orelse return usageFail(), 10) catch return usageFail();
            if (max_parallel == 0) return usageFail();
        } else if (optionValue(arg, "-tokenizer", "--tokenizer", &args)) |value| {
            dialect = problem.parseDialect(value orelse return usageFail()) orelse return usageFail();
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Error: unsupported option '{s}'\n", .{arg});
            return usageFail();
        } else try paths.append(init.gpa, arg);
    }
    if (paths.items.len == 0) return usageFail();

    var failed = false;
    for (paths.items) |path| {
        if (timing_in_depth) std.debug.print("timing: {s}\n", .{path});
        const p = problem.Problem.init(init.gpa, init.io, .{
            .source = .{ .file = path },
            .dialect = dialect,
            .output = selection,
            .backend = .{
                .backend = backend,
                .gpu_explicit = explicit_gpu,
                .solver_threads = @intCast(@min(envThreads("ESPICE_SOLVER_THREADS"), 16)),
                .device_threads = envThreads("ESPICE_THREADS"),
            },
            .max_parallel = max_parallel,
            .timing_in_depth = timing_in_depth,
        }) catch |err| {
            std.debug.print("Error: {s}: {s}\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };
        defer p.deinit();
        if (show_plan) {
            var buffer: [4096]u8 = undefined;
            var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
            try p.print(&stdout.interface, .{ .limits = .{ .max_parallel = max_parallel } });
            try stdout.interface.flush();
        }
        if (plan_only) continue;
        p.run_all() catch |err| {
            std.debug.print("Error: {s}: {s}\n", .{ path, @errorName(err) });
            if (p.output_error()) |delivery| std.debug.print("Output error: {s}\n", .{@errorName(delivery)});
            failed = true;
            continue;
        };
        std.debug.print("{s}: {d} devices\n", .{ p.title(), p.device_count() });
        for (0..p.query_count()) |i| {
            const id: problem.QueryId = @enumFromInt(i);
            if (!(try p.query_info(id)).requested) continue;
            const result = try p.result(id);
            std.debug.print("  {s}: {d} points, {d} variables\n", .{ result.plotname, result.npoints, result.varnames.len });
        }
    }
    return if (failed) 1 else 0;
}

fn envThreads(comptime name: [:0]const u8) u32 {
    const value = std.c.getenv(name) orelse return 1;
    return @max(1, std.fmt.parseInt(u32, std.mem.span(value), 10) catch 1);
}

/// Outer optional means not this flag; inner null means missing value.
fn optionValue(arg: []const u8, short: []const u8, long: []const u8, args: anytype) ??[]const u8 {
    if ((short.len != 0 and std.mem.eql(u8, arg, short)) or std.mem.eql(u8, arg, long))
        return @as(?[]const u8, args.next());
    if (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '=')
        return @as(?[]const u8, arg[long.len + 1 ..]);
    return null;
}

fn usageFail() u8 {
    std.debug.print("Usage: espice [OPTION]... FILE...\nTry 'espice --help' for options.\n", .{});
    return 2;
}
