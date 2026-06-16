//! Touchstone (.snp): S parameters in real/imaginary form against a 50 ohm
//! reference. Needs the complete matrix `types.portCount` checks for.
const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const Plot = types.Plot;

pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const n_ports = try types.portCount(plot.schema());
    try w.print("! {s}\n", .{plot.title});
    try w.writeAll("# Hz S RI R 50\n");
    for (0..plot.result.npoints) |pt| {
        const row = plot.point(pt);
        try w.print("{e}", .{row[0]});
        if (n_ports <= 2) {
            // One line per frequency. The data is row-major (S11 S12 S21 S22);
            // the 2-port spec order is S11 S21 S12 S22.
            const order: []const usize = if (n_ports == 1) &.{1} else &.{ 1, 3, 2, 4 };
            for (order) |vi| try w.print(" {e} {e}", .{ row[2 * vi], row[2 * vi + 1] });
            try w.writeByte('\n');
        } else {
            // n-port: the frequency alone, then one matrix row per line.
            try w.writeByte('\n');
            for (0..n_ports) |m| {
                for (0..n_ports) |n| {
                    const vi = 1 + m * n_ports + n;
                    try w.print(" {e} {e}", .{ row[2 * vi], row[2 * vi + 1] });
                }
                try w.writeByte('\n');
            }
        }
    }
    if (n_ports == 2) try noiseBlock(w, plot);
}

/// Touchstone 1.0's two-port noise data after the S block, when `.lin`
/// published it: frequency, NFmin in dB, |Γopt|, ∠Γopt in degrees and
/// RN normalized to the 50 ohm reference.
fn noiseBlock(w: *Io.Writer, plot: Plot) !void {
    var cols: [3]usize = undefined;
    for ([_][]const u8{ "NFMIN", "GAMMA_OPT", "RN" }, &cols) |name, *col| {
        col.* = for (plot.result.varnames, 0..) |v, i| {
            if (std.mem.eql(u8, v, name)) break i;
        } else return;
    }
    try w.writeAll("! noise parameters\n");
    for (0..plot.result.npoints) |pt| {
        const row = plot.point(pt);
        const g_re = row[2 * cols[1]];
        const g_im = row[2 * cols[1] + 1];
        try w.print("{e} {e} {e} {e} {e}\n", .{
            row[0],
            10 * std.math.log10(row[2 * cols[0]]),
            std.math.hypot(g_re, g_im),
            std.math.radiansToDegrees(std.math.atan2(g_im, g_re)),
            row[2 * cols[2]] / 50.0,
        });
    }
}

test "Touchstone 2-port writes S21 before S12" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "s2p test", .result = .{
        .plotname = "S-Parameter Analysis",
        .varnames = &.{ "frequency", "S(1,1)", "S(1,2)", "S(2,1)", "S(2,2)" },
        .is_complex = true,
        .npoints = 1,
        .data = &.{ 1.0e9, 0.0, 0.5, -0.3, 0.8, 0.1, 0.1, -0.05, 0.4, -0.2 },
    } });
    try std.testing.expectEqualStrings("! s2p test\n# Hz S RI R 50\n1e9 5e-1 -3e-1 1e-1 -5e-2 8e-1 1e-1 4e-1 -2e-1\n", w.buffered());
}
