const std = @import("std");
const engine = @import("engine.zig");
const vaload = @import("devices").vaload;
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

pub const types = @import("frontend/types.zig");
pub const Token = @import("frontend/tokenizer.zig").Token;
pub const Parser = @import("frontend/parser.zig").Parser;
pub const ngspice = @import("frontend/tokenizer.zig").ngspice;
pub const hspice = @import("frontend/tokenizer.zig").hspice;
pub const spectre = @import("frontend/tokenizer.zig").spectre;

const Mode = enum { batch, interactive, server, pipe };
const Tokenizer = enum { ngspice, hspice, spectre };
const Format = enum { binary, ascii, csv, touchstone, psf, fsdb, sst2, citi, print };

const FormatSpec = struct {
    names: []const []const u8,
    value: Format,
    writer: *const fn (std.Io, []const u8, rawfile.Plot) anyerror!void,
};

const format_specs = [_]FormatSpec{
    .{ .names = &.{ "binary", "raw" }, .value = .binary, .writer = rawfile.write },
    .{ .names = &.{"ascii"}, .value = .ascii, .writer = ascii_raw.write },
    .{ .names = &.{"csv"}, .value = .csv, .writer = csv.write },
    .{ .names = &.{ "touchstone", "snp", "s2p" }, .value = .touchstone, .writer = touchstone.write },
    .{ .names = &.{"psf"}, .value = .psf, .writer = psf.write },
    .{ .names = &.{"fsdb"}, .value = .fsdb, .writer = fsdb.write },
    .{ .names = &.{ "sst2", "hspice" }, .value = .sst2, .writer = sst2.write },
    .{ .names = &.{ "citi", "citifile" }, .value = .citi, .writer = citifile.write },
    .{ .names = &.{ "print", "text" }, .value = .print, .writer = spice_print.write },
};

// ponytail: fixed-size arrays, no ArrayList. 16 decks / 16 defines is generous.
const Options = struct {
    mode: Mode = .interactive,
    tokenizer: Tokenizer = .ngspice,
    raw_path: ?[]const u8 = null,
    format: Format = .binary,
    log_path: ?[]const u8 = null,
    no_spiceinit: bool = false,
    autorun: bool = false,
    gpu: bool = false,
    defines: [16]?Define = .{null} ** 16,
    n_defines: usize = 0,
    deck_paths: [16]?[]const u8 = .{null} ** 16,
    n_decks: usize = 0,
};

const Define = struct { name: []const u8, value: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var it = init.minimal.args.iterate();
    _ = it.skip();

    var opts: Options = .{};

    while (it.next()) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            if (parseMode(arg)) |mode| {
                opts.mode = mode;
            } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--autorun")) {
                opts.autorun = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-spiceinit")) {
                opts.no_spiceinit = true;
            } else if (std.mem.eql(u8, arg, "--gpu")) {
                opts.gpu = true;
            } else if (optionValue(arg, "-r", "--rawfile", &it)) |oa| {
                opts.raw_path = valueOrUsage(oa, io) orelse return 2;
            } else if (optionValue(arg, "-o", "--output", &it)) |oa| {
                opts.log_path = valueOrUsage(oa, io) orelse return 2;
            } else if (optionValue(arg, "-D", "--define", &it)) |oa| {
                const val = valueOrUsage(oa, io) orelse return 2;
                addDefine(&opts, val);
            } else if (std.mem.startsWith(u8, arg, "-D") and arg.len > 2) {
                addDefine(&opts, arg[2..]);
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp(io);
                return 0;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                printVersion(io);
                return 0;
            } else if (optionValue(arg, "", "--format", &it)) |oa| {
                const val = valueOrUsage(oa, io) orelse return 2;
                opts.format = parseFormat(val) orelse {
                    std.debug.print("Error: unknown format '{s}'\n", .{val});
                    return 2;
                };
            } else if (optionValue(arg, "-tokenizer", "--tokenizer", &it)) |oa| {
                const val = valueOrUsage(oa, io) orelse return 2;
                opts.tokenizer = parseTokenizer(val) orelse {
                    std.debug.print("Error: unknown tokenizer '{s}'\n", .{val});
                    return 2;
                };
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--completion") or
                std.mem.startsWith(u8, arg, "--soa-log"))
            {
                // ignored
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--term") or
                std.mem.eql(u8, arg, "--soa-log"))
            {
                _ = it.skip();
            } else {
                std.debug.print("Error: unknown option: {s}\n", .{arg});
                return usageFail(io);
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
        return usageFail(io);
    }

    if (opts.n_decks == 0) {
        printBanner(io);
        std.debug.print("Note: interactive mode not yet implemented\n", .{});
        return 0;
    }

    var any_ran = false;
    for (opts.deck_paths[0..opts.n_decks]) |maybe_path| {
        const path = maybe_path orelse continue;
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch {
            std.debug.print("Error: can't open input file '{s}'\n", .{path});
            continue;
        };

        var nl = switch (opts.tokenizer) {
            .ngspice => Parser(ngspice).parse(arena, src),
            .hspice => Parser(hspice).parse(arena, src),
            .spectre => Parser(spectre).parse(arena, src),
        } catch return skip(io, "parse error");

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
            // Source-tree paths for the runtime .so build. The devices package
            // has no `build_options`, and these must be the SAME roots the
            // builtins were compiled against — the orchestrator hashes them into
            // `layout_hash`, which is what rejects a stale cached .so.
            const src_root = build_options.src_root;
            const hdl_build_paths: vaload.BuildPaths = .{
                .work_dir = try std.fs.path.join(arena, &.{ src_root, ".zig-cache", "zpicey-hdl" }),
                .contract = try std.fs.path.join(arena, &.{ src_root, "modules", "devices", "src", "contract.zig" }),
                .dyn = try std.fs.path.join(arena, &.{ src_root, "modules", "devices", "src", "engine.zig" }),
            };
            vaload.ensureAllLoaded(arena, io, hdl_paths.items, hdl_build_paths) catch |e| {
                std.debug.print("Error: runtime HDL load failed: {s}\n", .{@errorName(e)});
                return skip(io, "hdl load error");
            };
        }

        if (opts.mode == .batch) {
            var sim = engine.Simulation.fromNetlist(arena, nl, io, .{ .gpu = opts.gpu }) catch |e| {
                std.debug.print("Engine error: {s}\n", .{@errorName(e)});
                return skip(io, @errorName(e));
            };
            defer sim.deinit();

            // Big runtime-VA models (PSP103: ~24k dual-number locals) need
            // multi-MB eval frames; the default 8 MB main stack overflows.
            // ponytail: run the solve on a fat-stack thread; a stackless
            // eval would need codegen-level local reuse.
            const Runner = struct {
                fn run(sm: *engine.Simulation, out: *?anyerror) void {
                    sm.run() catch |e| {
                        out.* = e;
                    };
                }
            };
            var run_err: ?anyerror = null;
            if (std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Runner.run, .{ &sim, &run_err })) |th| {
                th.join();
            } else |_| {
                Runner.run(&sim, &run_err);
            }
            if (run_err) |e| {
                std.debug.print("Engine error: {s}\n", .{@errorName(e)});
                return skip(io, @errorName(e));
            }

            const results = sim.getResults();
            if (opts.raw_path) |raw_path| {
                for (results, 0..) |res, ri| {
                    const plot_path = if (ri == 0)
                        raw_path
                    else
                        try std.fmt.allocPrint(arena, "{s}.{d}", .{ raw_path, ri + 1 });
                    writePlot(io, plot_path, opts.format, .{
                        .title = nl.title,
                        .plotname = res.plotname,
                        .varnames = res.varnames,
                        .is_complex = res.is_complex,
                        .npoints = res.npoints,
                        .data = res.data,
                    }) catch return skip(io, "write error");
                }
            }

            std.debug.print("\n--- Simulation Summary ---\n", .{});
            std.debug.print("Title:      {s}\n", .{nl.title});
            std.debug.print("Devices:    {d}\n", .{nl.devices.len()});
            std.debug.print("Directives: {d}\n", .{nl.directives.len});
            for (results) |res| {
                std.debug.print("Analysis:   {s} ({d} points, {d} variables)\n", .{
                    res.plotname, res.npoints, res.varnames.len,
                });
            }
            if (opts.raw_path) |rp| std.debug.print("Raw file:   {s}\n", .{rp});
        }

        any_ran = true;
    }

    if (!any_ran) return 1;
    return 0;
}

fn parseFormat(s: []const u8) ?Format {
    for (format_specs) |spec| if (matchesAny(s, spec.names)) return spec.value;
    return null;
}

fn parseTokenizer(s: []const u8) ?Tokenizer {
    const specs = [_]struct { names: []const []const u8, value: Tokenizer }{
        .{ .names = &.{ "ngspice", "ng" }, .value = .ngspice },
        .{ .names = &.{ "hspice", "hs" }, .value = .hspice },
        .{ .names = &.{ "spectre", "scs" }, .value = .spectre },
    };
    for (specs) |spec| if (matchesAny(s, spec.names)) return spec.value;
    return null;
}

fn parseMode(s: []const u8) ?Mode {
    const specs = [_]struct { names: []const []const u8, value: Mode }{
        .{ .names = &.{ "-b", "--batch" }, .value = .batch },
        .{ .names = &.{ "-i", "--interactive" }, .value = .interactive },
        .{ .names = &.{ "-s", "--server" }, .value = .server },
        .{ .names = &.{ "-p", "--pipe" }, .value = .pipe },
    };
    for (specs) |spec| if (matchesAny(s, spec.names)) return spec.value;
    return null;
}

fn matchesAny(s: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, s, name)) return true;
    return false;
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

fn valueOrUsage(oa: OptionArg, io: std.Io) ?[]const u8 {
    return switch (oa) {
        .value => |v| v,
        .missing => blk: {
            _ = usageFail(io);
            break :blk null;
        },
    };
}

fn writePlot(io: std.Io, path: []const u8, format: Format, plot: rawfile.Plot) !void {
    for (format_specs) |spec| if (spec.value == format) return spec.writer(io, path, plot);
    unreachable;
}

fn addDefine(opts: *Options, spec: []const u8) void {
    if (opts.n_defines >= opts.defines.len) return;
    if (std.mem.indexOfScalar(u8, spec, '=')) |eq|
        opts.defines[opts.n_defines] = .{ .name = spec[0..eq], .value = spec[eq + 1 ..] }
    else
        opts.defines[opts.n_defines] = .{ .name = spec, .value = "true" };
    opts.n_defines += 1;
}

fn skip(io: std.Io, reason: []const u8) u8 {
    var buf: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &buf);
    stdout.interface.print("{{\"skip\":\"{s}\"}}\n", .{reason}) catch {};
    stdout.interface.flush() catch {};
    return 1;
}

fn usageFail(io: std.Io) u8 {
    _ = io;
    std.debug.print("Usage: zpicey [OPTION]... [FILE]...\nTry 'zpicey -h' for more information.\n", .{});
    return 2;
}

fn printBanner(io: std.Io) void {
    _ = io;
    std.debug.print(
        \\
        \\  zpicey 0.1.0
        \\  Circuit level simulation program
        \\
        \\
    , .{});
}

fn printVersion(io: std.Io) void {
    _ = io;
    std.debug.print("zpicey 0.1.0\nCircuit level simulation program.\nBuilt with Zig.\n", .{});
}

fn printHelp(io: std.Io) void {
    _ = io;
    std.debug.print(
        \\Usage: zpicey [OPTION]... [FILE]...
        \\
        \\  -a, --autorun              Run the loaded netlist at once
        \\  -b, --batch                Process FILE in batch mode
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
}

