//! Periodic Transfer Function (PXF) Analysis — adjoint of PAC
//!
//! Computes the transfer function from every input node and sideband to a
//! single output node by solving the adjoint (conjugate-transpose) LPTV system:
//!
//!   A(f)^H · Y = e_(out, m=0)
//!
//! where A is the same conversion matrix used by PAC. The transfer from input
//! node i at sideband m is conj(Y_(i,m)).
//!
//! Uses: supply/LO feedthrough images, conversion gain from every port at
//! once, spur tables.
const std = @import("std");
const root = @import("../types.zig");
const pac = @import("pac.zig");
const types = @import("numerics");

pub const Complex = types.Complex;

pub const Options = pac.Options;

/// Contract entry: adjoint LPTV sweep from ctx.probes (output) reading all
/// input nodes at all sidebands. Data layout: point-major complex rows.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;
    if (ctx.probes.len == 0) return error.NoProbe;
    const probe = ctx.probes[ctx.probes.len - 1];

    const n: usize = ctx.circuit.n;
    const n_freqs: usize = opts.sweep.count();
    const n_sb: usize = 2 * @as(usize, opts.n_harmonics) + 1;
    const n_transfers = n_sb * n; // per frequency point

    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator;
    const freqs_buf = try scratch.alloc(f64, n_freqs);
    defer scratch.free(freqs_buf);
    const transfer = try scratch.alloc(Complex, n_freqs * n_transfers);
    defer scratch.free(transfer);

    try pac.sweep(true, ctx.circuit, x_op, probe, 1.0, probe, freqs_buf, transfer, opts, scratch);

    // Build varnames: "frequency", then "pxf_h{m}(node_label)" for each sideband × node.
    const ncols = 1 + n_transfers;
    const names = try a.alloc([]const u8, ncols);
    names[0] = "frequency";
    var done: usize = 0;
    errdefer {
        for (names[1..][0..done]) |s| a.free(s);
        a.free(names);
    }
    const n_harm: usize = opts.n_harmonics;
    for (0..n_sb) |sb| {
        const harmonic = @as(i32, @intCast(sb)) - @as(i32, @intCast(n_harm));
        for (0..n) |node| {
            const label = ctx.circuit.nodeName(@intCast(node));
            // An unlabeled row is a branch/internal unknown, and a deck can
            // have several — `pxf/two_poles` has two, so a shared "?" placed
            // the SAME column name twice in one raw file. The row index is
            // the name those rows actually have.
            names[1 + sb * n + node] = if (label.len == 0)
                try std.fmt.allocPrint(a, "pxf_h{d}({d})", .{ harmonic, node })
            else
                try std.fmt.allocPrint(a, "pxf_h{d}({s})", .{ harmonic, label });
            done += 1;
        }
    }

    const data = try a.alloc(f64, n_freqs * ncols * 2);
    for (0..n_freqs) |fi| {
        const row = data[fi * ncols * 2 ..][0 .. ncols * 2];
        row[0] = freqs_buf[fi];
        row[1] = 0;
        for (0..n_transfers) |k| {
            const tfv = transfer[fi * n_transfers + k];
            row[(1 + k) * 2] = tfv.re;
            row[(1 + k) * 2 + 1] = tfv.im;
        }
    }
    return .{
        .plotname = "Periodic Transfer Function Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_freqs,
        .data = data,
    };
}
