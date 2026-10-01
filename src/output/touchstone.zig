//! Touchstone (.snp): S parameters in real/imaginary form. One reference
//! impedance for every port writes Touchstone 1.0 (`# Hz S RI R z0`); ports
//! with different ones write Touchstone 2.0 with a `[Reference]` line, which
//! 1.0 cannot express. Needs the complete matrix `types.portCount` checks for.
const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const Plot = types.Plot;

pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const n_ports = try types.portCount(plot.schema());
    if (plot.z0.len != 0 and plot.z0.len != n_ports) return error.DataLengthMismatch;
    const z0 = if (plot.z0.len == 0) 50.0 else plot.z0[0];
    const v2 = for (plot.z0) |z| {
        if (z != z0) break true;
    } else false;
    try w.print("! {s}\n", .{plot.title});
    if (v2) try w.writeAll("[Version] 2.0\n");
    try w.print("# Hz S RI R {d}\n", .{z0});
    if (v2) {
        try w.print("[Number of Ports] {d}\n", .{n_ports});
        if (n_ports == 2) try w.writeAll("[Two-Port Data Order] 21_12\n");
        try w.print("[Number of Frequencies] {d}\n[Reference]", .{plot.result.npoints});
        for (plot.z0) |z| try w.print(" {d}", .{z});
        try w.writeAll("\n[Network Data]\n");
    }
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
    if (n_ports == 2) try noiseBlock(w, plot, z0, v2);
    if (v2) try w.writeAll("[End]\n");
}

/// Touchstone's two-port noise data after the S block, when `.lin`
/// published it: frequency, NFmin in dB, |Γopt|, ∠Γopt in degrees and
/// RN normalized to port 1's reference `z0`, which Γopt is taken against.
fn noiseBlock(w: *Io.Writer, plot: Plot, z0: f64, v2: bool) !void {
    var cols: [3]usize = undefined;
    for ([_][]const u8{ "NFMIN", "GAMMA_OPT", "RN" }, &cols) |name, *col| {
        col.* = for (plot.result.varnames, 0..) |v, i| {
            if (std.mem.eql(u8, v, name)) break i;
        } else return;
    }
    try w.writeAll(if (v2) "[Noise Data]\n" else "! noise parameters\n");
    for (0..plot.result.npoints) |pt| {
        const row = plot.point(pt);
        const g_re = row[2 * cols[1]];
        const g_im = row[2 * cols[1] + 1];
        try w.print("{e} {e} {e} {e} {e}\n", .{
            row[0],
            10 * std.math.log10(row[2 * cols[0]]),
            std.math.hypot(g_re, g_im),
            std.math.radiansToDegrees(std.math.atan2(g_im, g_re)),
            row[2 * cols[2]] / z0,
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

test "Touchstone writes 2.0 with a reference line for unequal port impedances" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "t", .z0 = &.{ 50, 75 }, .result = .{
        .plotname = "S-Parameter Analysis",
        .varnames = &.{ "frequency", "S(1,1)", "S(1,2)", "S(2,1)", "S(2,2)" },
        .is_complex = true,
        .npoints = 1,
        .data = &.{ 1.0e9, 0.0, 0.5, -0.3, 0.8, 0.1, 0.1, -0.05, 0.4, -0.2 },
    } });
    try std.testing.expectEqualStrings("! t\n[Version] 2.0\n# Hz S RI R 50\n[Number of Ports] 2\n[Two-Port Data Order] 21_12\n" ++
        "[Number of Frequencies] 1\n[Reference] 50 75\n[Network Data]\n1e9 5e-1 -3e-1 1e-1 -5e-2 8e-1 1e-1 4e-1 -2e-1\n[End]\n", w.buffered());
}
