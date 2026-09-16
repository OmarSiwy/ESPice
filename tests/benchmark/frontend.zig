//! Parse and elaborate a netlist without device compilation or solver work.
//! zig build bench-frontend -- tests/fixtures/stress/scaling_rc_ladder_100k.sp 15
const std = @import("std");
const syntax = @import("syntax");
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const path = args.next() orelse return error.MissingPath;
    const runs = try std.fmt.parseInt(u16, args.next() orelse "9", 10);
    const source = try syntax.load(init.io, init.arena.allocator(), path);
    var times: [101]i96 = undefined;
    if (runs == 0 or runs > times.len) return error.InvalidRuns;
    var capacity: usize = 0;
    var checksum: usize = 0;
    for (0..@as(usize, runs) + 1) |i| {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const start = std.Io.Timestamp.now(init.io, .awake);
        const parsed = try syntax.Parser(syntax.ngspice).parse(arena.allocator(), source);
        const nl = try syntax.elaborate(arena.allocator(), parsed);
        const elapsed = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds;
        if (i > 0) times[i - 1] = elapsed;
        checksum +%= nl.devices.len();
        capacity = arena.queryCapacity();
    }
    std.mem.sort(i96, times[0..runs], {}, std.sort.asc(i96));
    std.debug.print("{s}: median={d:.3}ms arena={d} bytes checksum={d}\n", .{ path, @as(f64, @floatFromInt(times[runs / 2])) / 1e6, capacity, checksum });
}
