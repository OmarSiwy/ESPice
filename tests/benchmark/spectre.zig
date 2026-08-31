//! The Spectre reference adapter. Spectre reads the SPICE deck through
//! its own SPICE reader (it picks the reader by the `.sp` extension), so
//! every SPICE construct passes hspice.zig's gate first, as for HSPICE:
//! running SPICE directly covers more decks than translating to Spectre's
//! language would, and keeps one gate to audit.
//!
//! Output is `-format nutascii`, read by compare.zig. Spectre names plots
//! after its own analyses and spells scales and currents its way, so
//! `readPlots` maps them onto the names ESPice and ngspice write.
const std = @import("std");
const common = @import("job.zig");
const compare = @import("compare.zig");
const hspice = @import("hspice.zig");
pub const version_flag = "-V";

/// Copies `netlist` into `scratch`/deck.sp through `hspice.stage` and returns
/// the job that runs it there, writing `spectre.raw` and `spectre.log`.
pub fn prepare(io: std.Io, a: std.mem.Allocator, bin: []const u8, args: []const []const u8, netlist: []const u8, scratch: []const u8, hspice_dialect: bool, match_tol: bool) common.Error!common.Job {
    const staged = try hspice.stageFile(io, a, netlist, scratch, .spectre, hspice_dialect, match_tol);
    if (staged == .refused) return .{ .refused = staged.refused };
    return .{
        .argv = try std.mem.concat(a, []const u8, &.{ &.{bin}, args, &.{ "-format", "nutascii", "-raw", "spectre.raw", "=log", "spectre.log", "deck.sp" } }),
        .cwd = .{ .path = scratch },
        .reader = .spectre,
        .op = staged.deck.op,
    };
}

/// The plots of `spectre.raw` in `dir`, renamed: `Transient Analysis
/// `timeSweep'...` to `Transient Analysis`, `freq` to `frequency`, a DC
/// plot over `dummy` to the operating point (kept only when the deck has
/// `.op`), any other DC plot to a DC sweep over `v(v-sweep)`, and the
/// source current `v1:p` to `i(v1)`. Other plots are dropped.
pub fn readPlots(io: std.Io, a: std.mem.Allocator, dir: []const u8, op: bool) ![]const compare.Plot {
    const path = try std.fmt.allocPrint(a, "{s}/spectre.raw", .{dir});
    return rename(a, compare.parseRawFile(io, a, path) orelse return error.MissingOrInvalidRaw, op);
}

fn rename(a: std.mem.Allocator, raw: []const compare.Plot, op: bool) ![]const compare.Plot {
    var plots: std.ArrayList(compare.Plot) = .empty;
    for (raw) |p| {
        if (p.nvars == 0) continue;
        const names = try a.dupe([]const u8, p.varnames);
        var plot = p;
        plot.varnames = names;
        if (std.mem.startsWith(u8, p.plotname, "Transient Analysis")) {
            plot.plotname = "Transient Analysis";
        } else if (std.mem.startsWith(u8, p.plotname, "AC Analysis")) {
            plot.plotname = "AC Analysis";
            names[0] = "frequency";
        } else if (std.mem.startsWith(u8, p.plotname, "DC Analysis")) {
            const point = std.mem.eql(u8, names[0], "v(dummy)");
            if (point and !op) continue;
            plot.plotname = if (point) "Operating Point" else "DC transfer characteristic";
            names[0] = "v(v-sweep)"; // a scale name: never scored when unmatched
        } else continue;
        for (names[1..]) |*name| if (std.mem.startsWith(u8, name.*, "v(") and std.mem.endsWith(u8, name.*, ":p)")) {
            name.* = try std.fmt.allocPrint(a, "i({s})", .{name.*[2 .. name.len - 3]});
        };
        try plots.append(a, plot);
    }
    if (plots.items.len == 0) return error.MissingOutput;
    return plots.items;
}

/// Spectre's own account of the run in `dir`, from `spectre.log`: the
/// aggregate elapsed time less licensing, and the sum of every `Total time
/// required for ... analysis` elapsed time.
pub fn reported(io: std.Io, a: std.mem.Allocator, dir: []const u8) !common.Reported {
    const path = try std.fmt.allocPrint(a, "{s}/spectre.log", .{dir});
    return parseLog(try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 28)));
}

fn parseLog(log: []const u8) !common.Reported {
    var analysis: f64 = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, log, at, "Total time required for")) |found| {
        at = found + 1;
        analysis += try elapsedAfter(log[found..]);
    }
    const audit = std.mem.indexOf(u8, log, "Aggregate audit") orelse return error.MissingTiming;
    const total = try elapsedAfter(log[audit..]);
    const licensing = if (std.mem.indexOfPos(u8, log, audit, "Time spent in licensing")) |l| try elapsedAfter(log[l..]) else 0;
    return .{ .run_ms = total - licensing, .analysis_ms = analysis };
}

/// The first `elapsed = N unit` in `text`, in milliseconds.
fn elapsedAfter(text: []const u8) !f64 {
    const label = "elapsed = ";
    const at = std.mem.indexOf(u8, text, label) orelse return error.MissingTiming;
    const rest = text[at + label.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse return error.MissingTiming;
    const value = try std.fmt.parseFloat(f64, rest[0..end]);
    // The unit ends at `,` or at a sentence's `.`.
    var words = std.mem.tokenizeAny(u8, rest[end..], " \t\r\n,.");
    const unit = words.next() orelse return error.MissingTiming;
    const scale: f64 = if (std.mem.eql(u8, unit, "s")) 1e3 else if (std.mem.eql(u8, unit, "ms")) 1 else if (std.mem.eql(u8, unit, "us")) 1e-3 else if (std.mem.eql(u8, unit, "ns")) 1e-6 else return error.UnknownUnit;
    return value * scale;
}

test "Spectre's plots are renamed onto ESPice's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "Plotname: DC Analysis `srcSweep': v1:dc = (0 V -> 1 V)\nFlags: real\nNo. Variables: 3\nNo. Points: 1\n" ++
        "Variables:\t0\tdc\tV\n\t\t1\tout\tV\n\t\t2\tv1:p\tA\nValues:\n 0\t1\t0.5\n\t-1e-3\n" ++
        "Plotname: DC Analysis `opBegin'\nFlags: real\nNo. Variables: 2\nNo. Points: 1\n" ++
        "Variables:\t0\tdummy\tdummy\n\t\t1\tout\tV\nValues:\n 0\t0\n\t0.5\n";
    const parsed = compare.parseRawBlob(a, raw).?;
    const plots = try rename(a, parsed, false);
    try std.testing.expectEqual(@as(usize, 1), plots.len);
    try std.testing.expectEqualStrings("DC transfer characteristic", plots[0].plotname);
    try std.testing.expectEqualStrings("v(v-sweep)", plots[0].varnames[0]);
    try std.testing.expectEqualStrings("i(v1)", plots[0].varnames[2]);
    try std.testing.expectEqualStrings("Operating Point", (try rename(a, parsed, true))[1].plotname);
}

test "the log gives the run and analysis times" {
    const log =
        \\Total time required for tran analysis `timeSweep': CPU = 3.451 ms, elapsed = 3.5 ms, util. = 99.6%.
        \\Total time required for dc analysis `opBegin': CPU = 549 us, elapsed = 500 us, util. = 100%.
        \\Aggregate audit (5:07:18 PM, Sat Oct 17, 2026):
        \\Time used: CPU = 176 ms, elapsed = 1.5 s, util. = 19.7%.
        \\Time spent in licensing: elapsed = 432 ms, percentage of total = 48.3%.
    ;
    const r = try parseLog(log);
    try std.testing.expectApproxEqAbs(@as(f64, 1068), r.run_ms, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), r.analysis_ms, 1e-9);
}
