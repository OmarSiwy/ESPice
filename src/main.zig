//! The `espice` command line: flags in, one `Problem` per netlist file, a
//! one-line summary per result on stderr. Exit 1 if any file fails, 2 on a
//! usage error.
const std = @import("std");
const problem = @import("espice");

/// std reserves a 256 KB alternate signal stack per thread for stack-overflow
/// traces, as zero-filled TLS: every thread of every compilation unit pays it
/// (1.5 MB per thread across the device objects before this). Kept in Debug,
/// where the trace is worth it.
pub const std_options: std.Options = .{ .signal_stack_size = if (@import("builtin").mode == .debug) 1 << 18 else null };

/// VerA's device/host contract checks (`contract.validating`), on in Debug
/// only: off, a device build spends 0.4-1.8% fewer instructions.
pub const vera_validate_contract = @import("builtin").mode == .debug;

/// glibc's `mallopt` (malloc.h); M_MMAP_THRESHOLD is -3.
extern "c" fn mallopt(param: c_int, value: c_int) c_int;

/// Runs every netlist named on the command line and returns the exit code:
/// 0, 1 if any file failed to prepare or run, 2 on a usage error.
pub fn main(init: std.process.Init) !u8 {
    // glibc raises its mmap threshold to each mmapped block it frees (up to
    // 32 MB), so after one query frees a big buffer the next ones come from
    // the heap and stay resident when freed. A fixed 128 KB threshold (its
    // default) hands every big block back at once: peak RSS
    // scaling_rc_ladder_100k 285 -> 277 MB, opamp with two .ac 180 -> 170 MB,
    // for 4% more minor page faults on the ladder.
    if (@import("builtin").target.isGnuLibC()) _ = mallopt(-3, 128 * 1024);
    var args = init.minimal.args.iterate();
    _ = args.skip();
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(init.gpa);
    var dialect: problem.Dialect = .ngspice;
    var selection: problem.Selection = .{};
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
            selection.format = problem.parseFormat(value orelse return usageFail()) orelse return usageFail();
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
                // One deck, run once: no query is appended later.
                .final_plan = true,
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
        {
            var out_buf: [4096]u8 = undefined;
            var err_buf: [1024]u8 = undefined;
            var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
            var stderr: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buf);
            try p.print_measures(&stdout.interface, &stderr.interface);
            try stdout.interface.flush();
            try stderr.interface.flush();
        }
        std.debug.print("{s}: {d} devices\n", .{ p.title(), p.device_count() });
        for (0..p.query_count()) |i| {
            const id: problem.QueryId = @fromBackingInt(@intCast(i));
            if (!(try p.query_info(id)).requested) continue;
            const result = try p.result(id);
            std.debug.print("  {s}: {d} points, {d} variables\n", .{ result.plotname, result.npoints, result.varnames.len });
        }
        const runs = try p.run_results(init.gpa);
        defer init.gpa.free(runs);
        for (runs) |result| std.debug.print("  {s}: {d} points, {d} variables\n", .{ result.plotname, result.npoints, result.varnames.len });
    }
    return if (failed) 1 else 0;
}

/// A positive thread count from the environment, 1 when unset or unparsable.
fn envThreads(comptime name: [:0]const u8) u32 {
    const value = std.c.getenv(name) orelse return 1;
    return @max(1, std.fmt.parseInt(u32, std.mem.span(value), 10) catch 1);
}

/// The value of `short`/`long` given as `-r X`, `--rawfile X` or `--rawfile=X`.
/// Outer null: `arg` is not this flag. Inner null: the value is missing or
/// empty (`--rawfile=`), which is a usage error.
fn optionValue(arg: []const u8, short: []const u8, long: []const u8, args: anytype) ??[]const u8 {
    if ((short.len != 0 and std.mem.eql(u8, arg, short)) or std.mem.eql(u8, arg, long)) {
        const value = args.next() orelse return @as(?[]const u8, null);
        return if (value.len == 0) @as(?[]const u8, null) else value;
    }
    if (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '=')
        return if (arg.len == long.len + 1) @as(?[]const u8, null) else arg[long.len + 1 ..];
    return null;
}

fn usageFail() u8 {
    std.debug.print("Usage: espice [OPTION]... FILE...\nTry 'espice --help' for options.\n", .{});
    return 2;
}
