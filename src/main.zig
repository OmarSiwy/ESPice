const std = @import("std");
const engine = @import("engine.zig");
const gpu_context = @import("gpu_context.zig");
const vaload = @import("devices").vaload;
const memstats = @import("memstats");
const build_options = @import("build_options");
const rawfile = @import("output/rawfile.zig");
const ascii_raw = @import("output/ascii_raw.zig");
const csv = @import("output/csv.zig");
const spice_print = @import("output/spice_print.zig");
const touchstone = @import("output/touchstone.zig");
const citifile = @import("output/citifile.zig");
const psf = @import("output/psf.zig");
const sst2 = @import("output/sst2.zig");
const fsdb = @import("output/fsdb.zig");

pub const Parser = @import("frontend/parser.zig").Parser;
pub const ngspice = @import("frontend/tokenizer.zig").ngspice;
pub const hspice = @import("frontend/tokenizer.zig").hspice;
pub const spectre = @import("frontend/tokenizer.zig").spectre;

// `zig test` collects tests only from files the ROOT pulls in explicitly — an
// ordinary `@import` used by runtime code is not enough. Same aggregator idiom
// every root.zig in this tree uses; without it `zig build test-app` built a
// binary that ran zero tests and reported success.
test {
    _ = @import("engine.zig");
    _ = @import("gpu_context.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/parameter_tests.zig");
    _ = @import("frontend/source.zig");
    _ = @import("frontend/tokenizer.zig");
    _ = @import("frontend/types.zig");
    _ = @import("output/rawfile.zig");
    _ = @import("output/ascii_raw.zig");
    _ = @import("output/csv.zig");
    _ = @import("output/spice_print.zig");
    _ = @import("output/touchstone.zig");
    _ = @import("output/citifile.zig");
    _ = @import("output/psf.zig");
    _ = @import("output/sst2.zig");
    _ = @import("output/fsdb.zig");
}

const Mode = enum { batch, interactive, server, pipe };
const Tokenizer = enum { ngspice, hspice, spectre };
const Format = enum { binary, ascii, csv, touchstone, psf, fsdb, sst2, citi, print };

// ponytail: up to 16 decks; use an ArrayList if more are needed.
const Options = struct {
    mode: Mode = .interactive,
    tokenizer: Tokenizer = .ngspice,
    raw_path: ?[]const u8 = null,
    format: Format = .binary,
    backend: gpu_context.Request = .cpu,
    /// The user NAMED the device. `--gpu` and `--backend cuda|hip` both do;
    /// `--backend auto` does not, and that is the entire difference between
    /// "use the GPU" and "use the GPU if you feel like it".
    gpu_explicit: bool = false,
    deck_paths: [16][]const u8 = undefined,
    n_decks: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    // Two lifetimes. parse_arena: source text, Netlist, wiring scratch — reset
    // after each deck's fromNetlist returns. sim_arena: Circuit, Workspace,
    // jobs, results — lives per-deck until the writers finish.
    var parse_arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer parse_arena_state.deinit();
    // Both arenas are wrapped so ZP_MEM_STATS can charge every table to the
    // phase that asked for it; `track` is the identity when the variable is
    // unset. See src/mem_stats.zig for what the columns mean on an arena.
    const arena = memstats.track(parse_arena_state.allocator());

    var sim_arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer sim_arena_state.deinit();
    const sim_arena = memstats.track(sim_arena_state.allocator());

    var it = init.minimal.args.iterate();
    _ = it.skip();

    var opts: Options = .{};

    while (it.next()) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            if (parseMode(arg)) |mode| {
                opts.mode = mode;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--autorun")) {
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-spiceinit")) {
            } else if (std.mem.eql(u8, arg, "--gpu")) {
                opts.backend = .auto;
                opts.gpu_explicit = true;
            } else if (optionValue(arg, "", "--backend", &it)) |oa| {
                const val = valueOrUsage(oa) orelse return 2;
                opts.backend = std.meta.stringToEnum(gpu_context.Request, val) orelse {
                    std.debug.print("Error: unknown backend '{s}' (want auto|cpu|cuda|hip)\n", .{val});
                    return 2;
                };
                // Naming a backend IS an explicit request, and `auto` is the
                // only mode that keeps the work-gate heuristic. Sticky (`or`),
                // never cleared: `--gpu --backend auto` in either order still
                // asked for the GPU, so neither ordering silently runs on the
                // CPU. `--backend cpu` needs no clearing — it turns the GPU off.
                opts.gpu_explicit = opts.gpu_explicit or
                    opts.backend == .cuda or opts.backend == .hip;
            } else if (optionValue(arg, "-r", "--rawfile", &it)) |oa| {
                opts.raw_path = valueOrUsage(oa) orelse return 2;
            } else if (optionValue(arg, "-o", "--output", &it)) |oa| {
                _ = valueOrUsage(oa) orelse return 2;
            } else if (optionValue(arg, "-D", "--define", &it)) |oa| {
                _ = valueOrUsage(oa) orelse return 2;
            } else if (std.mem.startsWith(u8, arg, "-D") and arg.len > 2) {
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                std.debug.print(
                    \\Usage: espice [OPTION]... [FILE]...
                    \\
                    \\  -a, --autorun              Run the loaded netlist at once
                    \\  -b, --batch                Process FILE in batch mode
                    \\      --backend=BE           Compute backend (auto|cpu|cuda|hip, default cpu; auto may decline)
                    \\      --gpu                  Require the GPU: bypasses the work gate, errors if unavailable
                    \\  -D, --define=var[=val]     Define a variable
                    \\      --format=FMT            Output format (binary|ascii|csv|touchstone|psf|fsdb|sst2|citi|print)
                    \\  -h, --help                 Display this help and exit
                    \\  -i, --interactive          Run in interactive mode
                    \\  -n, --no-spiceinit         Don't load .spiceinit
                    \\  -o, --output=FILE          Set the output file for batch logs
                    \\  -p, --pipe                 Run in I/O pipe mode
                    \\  -r, --rawfile=FILE         Set the raw output file
                    \\  -s, --server               Run in server mode
                    \\  -tokenizer, --tokenizer=FMT  Input format (ngspice|hspice|spectre)
                    \\  -v, --version              Output version information
                    \\
                , .{});
                return 0;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                std.debug.print("espice 0.1.0\nCircuit level simulation program.\nBuilt with Zig.\n", .{});
                return 0;
            } else if (optionValue(arg, "", "--format", &it)) |oa| {
                const val = valueOrUsage(oa) orelse return 2;
                opts.format = parseFormat(val) orelse {
                    std.debug.print("Error: unknown format '{s}'\n", .{val});
                    return 2;
                };
            } else if (optionValue(arg, "-tokenizer", "--tokenizer", &it)) |oa| {
                const val = valueOrUsage(oa) orelse return 2;
                opts.tokenizer = parseTokenizer(val) orelse {
                    std.debug.print("Error: unknown tokenizer '{s}'\n", .{val});
                    return 2;
                };
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--completion") or
                std.mem.startsWith(u8, arg, "--soa-log"))
            {
                // ignored
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--term"))
            {
                _ = it.skip();
            } else {
                std.debug.print("Error: unknown option: {s}\n", .{arg});
                return usageFail();
            }
        } else {
            if (opts.n_decks < opts.deck_paths.len) {
                opts.deck_paths[opts.n_decks] = arg;
                opts.n_decks += 1;
            }
        }
    }

    if (opts.n_decks == 0 and opts.mode == .batch) {
        std.debug.print("Error: no input file specified for batch mode\n", .{});
        return usageFail();
    }

    if (opts.n_decks == 0) {
        std.debug.print(
            \\
            \\  espice 0.1.0
            \\  Circuit level simulation program
            \\
            \\
        , .{});
        std.debug.print("Note: interactive mode not yet implemented\n", .{});
        return 0;
    }

    // Strict --backend cuda|hip: reject up front if this binary cannot honour
    // it, naming what WAS detected. auto/cpu always pass (auto falls back).
    if (!gpu_context.requestSupported(opts.backend)) {
        std.debug.print("Error: requested {s}, found: {s}\n", .{ @tagName(opts.backend), gpu_context.detectedName() });
        return 2;
    }

    var any_ran = false;
    for (opts.deck_paths[0..opts.n_decks]) |path| {
        // The parse arena is live until `fromNetlist` returns (see the reset
        // below), so this row and the setup rows overlap in RSS by design.
        const parse_row = memstats.enter("parse: source + AST");
        const src = (if (opts.tokenizer == .spectre)
            std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)
        else
            @import("frontend/source.zig").load(io, arena, path)) catch |err| {
            std.debug.print("Error: can't load input file '{s}': {s}\n", .{ path, @errorName(err) });
            continue;
        };

        const nl = switch (opts.tokenizer) {
            .ngspice => Parser(ngspice).parse(arena, src),
            .hspice => Parser(hspice).parse(arena, src),
            .spectre => Parser(spectre).parse(arena, src),
        } catch return skip(io, "parse error");
        memstats.scaleBy("parse: source + AST", nl.devices.len());
        memstats.leave(parse_row);

        // Foreign HDL (.hdl cards): compile + dlopen at runtime (cached by
        // content hash — first load pays a model compile, never again).
        // Relative paths resolve against the netlist file's dir (HSPICE).
        // Multiple files load in parallel (codegen + zig-build concurrent).
        {
            var hdl_paths: std.ArrayList([]const u8) = .empty;
            defer hdl_paths.deinit(arena);
            for (nl.foreign) |f| switch (f.kind) {
                .verilog_a, .verilog => {
                    const hdl_path = if (std.fs.path.isAbsolute(f.path))
                        f.path
                    else
                        try std.fs.path.join(arena, &.{ std.fs.path.dirname(path) orelse ".", f.path });
                    try hdl_paths.append(arena, hdl_path);
                },
                else => {},
            };
            // Module roots for the runtime .so build. These must be the SAME
            // roots the builtins were compiled against — the orchestrator hashes
            // them into `layout_hash`, which is what rejects a stale cached .so.
            //
            // The build hands them over whole rather than letting us join them
            // onto `src_root`: `contract` lives in the vera package now, which
            // has no path expressible from here. The joined form silently rotted
            // once before, when the `modules/` tree it named was deleted.
            const hdl_build_paths: vaload.BuildPaths = .{
                .work_dir = try std.fs.path.join(arena, &.{ build_options.src_root, ".zig-cache", "espice-hdl" }),
                .contract = build_options.contract_path,
                .dyn = build_options.dyn_path,
                .gompute = build_options.gompute_path,
            };
            // Registry keys outlive every deck; compile scratch is freed individually.
            vaload.ensureAllLoaded(std.heap.smp_allocator, io, hdl_paths.items, hdl_build_paths) catch |e| {
                std.debug.print("Error: runtime HDL load failed: {s}\n", .{@errorName(e)});
                return skip(io, "hdl load error");
            };
        }

        if (opts.mode == .batch) {
            // Resolve the backend request to the engine's opt-in flags:
            // .cpu never touches the GPU; .auto/.cuda/.hip engage it. A named
            // cuda/hip this BINARY cannot honour was already rejected above;
            // gpu_explicit makes a MACHINE that cannot honour it (absent
            // device/driver) a hard error in run(), and turns the work gate off.
            const setup_row = memstats.enter("setup: engine + jobs");
            var sim = engine.Simulation.fromNetlist(sim_arena, arena, nl, io, .{
                .gpu = opts.backend != .cpu,
                .gpu_explicit = opts.gpu_explicit,
            }) catch |e| {
                std.debug.print("Engine error: {s}\n", .{@errorName(e)});
                return skip(io, @errorName(e));
            };
            defer sim.deinit();
            memstats.leave(setup_row);

            // fromNetlist owns every surviving value; release parse scratch now.
            _ = parse_arena_state.reset(.free_all);

            // Big runtime-VA models (PSP103: ~24k dual-number locals) need
            // multi-MB eval frames; the default 8 MB main stack overflows.
            // ponytail: run the solve on a fat-stack thread; a stackless
            // eval would need codegen-level local reuse.
            // ponytail: single binary transient only; other job/format combinations
            // retain Results until a whole-deck streaming contract is needed.
            var stream_path = if (opts.format == .binary and sim.n_jobs == 1 and
                std.meta.activeTag(sim.jobs[0]) == .tran) opts.raw_path else null;
            if (stream_path) |p| if (!(rawfile.canStream(io, p) catch return skip(io, "write error"))) {
                stream_path = null;
            };
            const Runner = struct {
                fn run(sm: *engine.Simulation, run_io: std.Io, output_path: ?[]const u8, points: *?usize, out: *?anyerror) void {
                    if (output_path) |p| {
                        points.* = stream(sm, run_io, p) catch |e| {
                            out.* = e;
                            return;
                        };
                    } else sm.run() catch |e| {
                        out.* = e;
                    };
                }

                fn stream(sm: *engine.Simulation, run_io: std.Io, output_path: []const u8) !usize {
                    const a = std.heap.smp_allocator;
                    const names = try a.alloc([]const u8, sm.probe_labels.len + 1);
                    defer a.free(names);
                    names[0] = "time";
                    @memcpy(names[1..], sm.probe_labels);
                    var output = try rawfile.Stream.init(run_io, a, output_path, sm.title, names);
                    defer output.deinit();
                    _ = try sm.runTransient(&output);
                    try output.finish();
                    return output.npoints;
                }
            };
            var run_err: ?anyerror = null;
            var streamed_points: ?usize = null;
            const run_row = memstats.enter("run: solve + results");
            if (std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Runner.run, .{ &sim, io, stream_path, &streamed_points, &run_err })) |th| {
                th.join();
            } else |_| {
                Runner.run(&sim, io, stream_path, &streamed_points, &run_err);
            }
            memstats.leave(run_row);
            memstats.report();
            if (run_err) |e| {
                std.debug.print("Engine error: {s}\n", .{@errorName(e)});
                return skip(io, @errorName(e));
            }

            const results = sim.getResults();
            if (opts.raw_path) |raw_path| {
                for (results, 0..) |res, ri| {
                    // ponytail: both raw output paths consume the same plot metadata.
                    const plot: rawfile.Plot = .{
                        .title = sim.title,
                        .plotname = res.plotname,
                        .varnames = res.varnames,
                        .is_complex = res.is_complex,
                        .npoints = res.npoints,
                        .data = res.data,
                    };
                    // ngspice appends every plot to ONE raw file; readers (the
                    // benchmark runner included) parse the concatenation. The
                    // old `{path}.{d}` side files left every analysis past the
                    // first invisible to comparison — rtlinv's .tran was never
                    // compared at all. Non-raw formats keep the suffix: they
                    // have no multi-plot framing.
                    if (opts.format == .binary and ri > 0) {
                        rawfile.writeAppend(io, raw_path, plot) catch return skip(io, "write error");
                        continue;
                    }
                    const plot_path = if (ri == 0)
                        raw_path
                    else
                        try std.fmt.allocPrint(arena, "{s}.{d}", .{ raw_path, ri + 1 });
                    writePlot(io, plot_path, opts.format, plot) catch return skip(io, "write error");
                }
            }

            std.debug.print("\n--- Simulation Summary ---\n", .{});
            std.debug.print("Title:      {s}\n", .{sim.title});
            std.debug.print("Devices:    {d}\n", .{sim.n_devices});
            std.debug.print("Directives: {d}\n", .{sim.n_directives});
            for (results) |res| {
                std.debug.print("Analysis:   {s} ({d} points, {d} variables)\n", .{
                    res.plotname, res.npoints, res.varnames.len,
                });
            }
            if (streamed_points) |n| std.debug.print("Analysis:   Transient Analysis ({d} points, {d} variables)\n", .{
                n, sim.probes.len + 1,
            });
            if (opts.raw_path) |rp| std.debug.print("Raw file:   {s}\n", .{rp});
        }

        any_ran = true;

        // Per-deck reset: both lifetimes end here. Retain the backing pages so
        // the next deck reuses them instead of re-mmapping.
        _ = parse_arena_state.reset(.retain_capacity);
        _ = sim_arena_state.reset(.retain_capacity);
    }

    if (!any_ran) return 1;
    return 0;
}

// ponytail: fixed CLI aliases use stdlib maps; writers dispatch on the resolved enum.
fn parseFormat(s: []const u8) ?Format {
    return std.StaticStringMap(Format).initComptime(.{
        .{ "binary", .binary }, .{ "raw", .binary },
        .{ "ascii", .ascii }, .{ "csv", .csv },
        .{ "touchstone", .touchstone }, .{ "snp", .touchstone }, .{ "s2p", .touchstone },
        .{ "psf", .psf }, .{ "fsdb", .fsdb },
        .{ "sst2", .sst2 }, .{ "hspice", .sst2 },
        .{ "citi", .citi }, .{ "citifile", .citi },
        .{ "print", .print }, .{ "text", .print },
    }).get(s);
}

fn parseTokenizer(s: []const u8) ?Tokenizer {
    return std.StaticStringMap(Tokenizer).initComptime(.{
        .{ "ngspice", .ngspice }, .{ "ng", .ngspice },
        .{ "hspice", .hspice }, .{ "hs", .hspice },
        .{ "spectre", .spectre }, .{ "scs", .spectre },
    }).get(s);
}

fn parseMode(s: []const u8) ?Mode {
    return std.StaticStringMap(Mode).initComptime(.{
        .{ "-b", .batch }, .{ "--batch", .batch },
        .{ "-i", .interactive }, .{ "--interactive", .interactive },
        .{ "-s", .server }, .{ "--server", .server },
        .{ "-p", .pipe }, .{ "--pipe", .pipe },
    }).get(s);
}

const OptionArg = union(enum) { value: []const u8, missing };

fn optionValue(arg: []const u8, short: []const u8, long: []const u8, it: anytype) ?OptionArg {
    if (short.len != 0 and std.mem.eql(u8, arg, short))
        return if (it.next()) |v| .{ .value = v } else .missing;
    if (std.mem.eql(u8, arg, long))
        return if (it.next()) |v| .{ .value = v } else .missing;
    if (long.len != 0 and arg.len > long.len + 1 and std.mem.startsWith(u8, arg, long) and arg[long.len] == '=')
        return .{ .value = arg[long.len + 1 ..] };
    return null;
}

fn valueOrUsage(oa: OptionArg) ?[]const u8 {
    return switch (oa) {
        .value => |v| v,
        .missing => blk: {
            _ = usageFail();
            break :blk null;
        },
    };
}

fn writePlot(io: std.Io, path: []const u8, format: Format, plot: rawfile.Plot) !void {
    return switch (format) {
        .binary => rawfile.write(io, path, plot),
        .ascii => ascii_raw.write(io, path, plot),
        .csv => csv.write(io, path, plot),
        .touchstone => touchstone.write(io, path, plot),
        .psf => psf.write(io, path, plot),
        .fsdb => fsdb.write(io, path, plot),
        .sst2 => sst2.write(io, path, plot),
        .citi => citifile.write(io, path, plot),
        .print => spice_print.write(io, path, plot),
    };
}

fn skip(io: std.Io, reason: []const u8) u8 {
    var buf: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &buf);
    stdout.interface.print("{{\"skip\":\"{s}\"}}\n", .{reason}) catch {};
    stdout.interface.flush() catch {};
    return 1;
}

fn usageFail() u8 {
    std.debug.print("Usage: espice [OPTION]... [FILE]...\nTry 'espice -h' for more information.\n", .{});
    return 2;
}
