const std = @import("std");
const zvaf = @import("zvaf");

const Io = std.Io;

const Model = struct {
    name: []const u8,
    path: []const u8,
    lines: u32,
};

const models = [_]Model{
    .{ .name = "resistor", .path = "tests/fixtures/resistor.va", .lines = 12 },
    .{ .name = "diode", .path = "tests/fixtures/diode.va", .lines = 45 },
    .{ .name = "amplifier", .path = "tests/fixtures/amplifier.va", .lines = 40 },
    .{ .name = "diode_lim", .path = "tests/fixtures/diode_lim.va", .lines = 30 },
    .{ .name = "hicuml2", .path = "tests/fixtures/hicuml2.va", .lines = 2100 },
    .{ .name = "bsim4", .path = "tests/fixtures/bsim4.va", .lines = 12594 },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = Io.Dir.cwd();
    const N = 30;

    var buf: [256]u8 = undefined;
    var fw = Io.File.stderr().writerStreaming(io, &buf);
    const w = &fw.interface;

    try w.print("\n{s:<12} {s:>6} {s:>10} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{
        "model", "lines", "preproc", "lex+parse", "lower", "codegen", "total",
    });
    try w.print("{s}\n", .{"-" ** 78});
    try w.flush();

    for (models) |m| {
        const source = cwd.readFileAlloc(io, m.path, allocator, .unlimited) catch {
            try w.print("{s:<12} SKIP (file not found: {s})\n", .{ m.name, m.path });
            try w.flush();
            continue;
        };
        defer allocator.free(source);

        var pp_total: i96 = 0;
        var parse_total: i96 = 0;
        var lower_total: i96 = 0;
        var codegen_total: i96 = 0;
        var times: [N]i96 = undefined;

        for (0..N) |i| {
            const t0 = Io.Clock.awake.now(io);
            var arena = std.heap.ArenaAllocator.init(allocator);
            const arena_alloc = arena.allocator();

            const preprocessed = try zvaf.Preprocessor.process(arena_alloc, source);
            const t1 = Io.Clock.awake.now(io);

            var parser = try zvaf.Parser.init(arena_alloc, preprocessed);
            const file = try parser.parseSourceFile();
            const t2 = Io.Clock.awake.now(io);

            if (file.modules.len == 0) {
                arena.deinit();
                continue;
            }
            const module = &file.modules[file.modules.len - 1];
            var mir = zvaf.Mir.init(arena_alloc, module.name);
            var lower = try zvaf.Lower.init(arena_alloc, &mir, file.stmts, file.expr_tags, file.expr_lhs, file.expr_rhs, file.extra_data, file.str_refs);
            try lower.lowerModule(module);
            const t3 = Io.Clock.awake.now(io);

            const zig_src = zvaf.codegen.generate(allocator, &mir, &lower) catch |err| {
                try w.print("  {s}: codegen error: {}\n", .{ m.name, err });
                arena.deinit();
                continue;
            };
            allocator.free(zig_src);
            const t4 = Io.Clock.awake.now(io);

            lower.builder.deinit();
            mir.deinit();
            arena.deinit();

            pp_total += t0.durationTo(t1).nanoseconds;
            parse_total += t1.durationTo(t2).nanoseconds;
            lower_total += t2.durationTo(t3).nanoseconds;
            codegen_total += t3.durationTo(t4).nanoseconds;
            times[i] = t0.durationTo(t4).nanoseconds;
        }

        std.mem.sort(i96, &times, {}, std.sort.asc(i96));
        const median = times[N / 2];

        try w.print("{s:<12} {d:>6} {d:>9.2}ms {d:>9.2}ms {d:>9.2}ms {d:>9.2}ms {d:>7.2}ms\n", .{
            m.name,
            m.lines,
            @as(f64, @floatFromInt(pp_total)) / N / 1e6,
            @as(f64, @floatFromInt(parse_total)) / N / 1e6,
            @as(f64, @floatFromInt(lower_total)) / N / 1e6,
            @as(f64, @floatFromInt(codegen_total)) / N / 1e6,
            @as(f64, @floatFromInt(median)) / 1e6,
        });
        try w.flush();
    }
    try w.flush();
    if (fw.err) |e| return e;
}
