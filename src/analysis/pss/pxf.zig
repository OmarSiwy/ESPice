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
const types = @import("solvers").types;
const dense_lu = @import("solvers").dense_lu;

pub const Complex = types.Complex;

pub const Options = pac.Options;

/// Run the adjoint LPTV analysis.
///
/// `probe_node` is the single output node (the RHS selector).
/// After solving A^H Y = e_(out, m=0), the transfer from every input node
/// at every sideband is available as conj(Y).
///
/// Results are written into `transfer[fi * n_sb * n + sb * n + node]` where
/// fi indexes the frequency sweep, sb the sideband, and node the input node.
pub fn analyze(
    ckt: *root.Circuit,
    x_init: []const f64,
    probe_node: u32,
    freqs: []f64,
    transfer: []Complex,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    const n_harm: usize = options.n_harmonics;
    const n_sb: usize = 2 * n_harm + 1;

    const n_freqs = types.logSweepCount(options.f_start, options.f_stop, options.points_per_decade);
    std.debug.assert(freqs.len == n_freqs);
    std.debug.assert(transfer.len == @as(usize, n_freqs) * n_sb * n);

    const linearization = try pac.linearize(ckt, x_init, options, allocator);
    defer allocator.free(linearization.g_hat);
    defer allocator.free(linearization.c_hat);

    // -- Step 4: Frequency sweep — build A, solve A^T y = e ------------------
    // The conversion matrix A (real-expanded 2nn × 2nn) is the same as PAC.
    // For the adjoint solve A^H Y = e, since A is real-expanded from complex
    // blocks with structure [[Re, -Im], [Im, Re]], the Hermitian transpose
    // A^H = conj(A)^T. But A is real, so A^H = A^T. We build A then solve
    // with the transposed system.
    //
    // The RHS selector e_(out, m=0) has a 1.0 at the probe_node in sideband
    // m=0 (index n_harm).

    const nn = n_sb * n;
    const nn2 = 2 * nn;

    const a_work = try allocator.alloc(f64, nn2 * nn2);
    defer allocator.free(a_work);
    const rhs_work = try allocator.alloc(f64, nn2);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn2);
    defer allocator.free(x_work);

    var sw = types.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var fi: usize = 0;
    while (sw.next()) |f_in| : (fi += 1) {
        if (fi != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = fi, .total = freqs.len });
        root.zeroSimd(a_work);
        root.zeroSimd(rhs_work);

        pac.buildConversionMatrix(true, a_work, linearization.g_hat, linearization.c_hat, n, n_sb, nn, nn2, f_in, options);

        const exc_row = n_harm * n + probe_node;
        rhs_work[exc_row] = 1.0;

        try dense_lu.factorizeSolve(nn2, a_work, rhs_work, x_work);

        // Extract results: transfer from input node i at sideband m is conj(Y_(i,m)).
        freqs[fi] = f_in;
        for (0..n_sb) |sb| {
            for (0..n) |node| {
                const idx = sb * n + node;
                // Y = (y_re, y_im), transfer = conj(Y) = (y_re, -y_im)
                transfer[fi * n_sb * n + sb * n + node] = .{
                    .re = x_work[idx],
                    .im = -x_work[nn + idx],
                };
            }
        }
    }
}

/// Contract entry: adjoint LPTV sweep from ctx.probes (output) reading all
/// input nodes at all sidebands. Data layout: point-major complex rows.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    if (ctx.probes.len == 0) return error.NoProbe;
    const probe = ctx.probes[ctx.probes.len - 1];

    // ponytail: Phase 4 — GPU batch dispatch not applicable yet.
    // PXF builds a dense 2*(n_sb*n) × 2*(n_sb*n) conversion matrix A^T per
    // frequency point, then solves via dense LU.  The existing GpuHook
    // freq_solve_adjoint_batch operates on the sparse circuit Jacobian (G+jωC)^H,
    // not a dense LPTV conversion matrix.  Batched dense conversion matrix
    // solves (all frequency points in one launch) require a dedicated
    // dense_solve_batch hook — add when PAC/PXF frequency sweeps dominate
    // runtime on multi-harmonic mixer workloads.

    const n: usize = ctx.circuit.n;
    const n_freqs: usize = types.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const n_sb: usize = 2 * @as(usize, opts.n_harmonics) + 1;
    const n_transfers = n_sb * n; // per frequency point

    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const freqs_buf = try scratch.alloc(f64, n_freqs);
    defer scratch.free(freqs_buf);
    const transfer = try scratch.alloc(Complex, n_freqs * n_transfers);
    defer scratch.free(transfer);

    try analyze(ctx.circuit, x_op, probe, freqs_buf, transfer, opts, scratch);

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
            const node_str = if (label.len == 0) "?" else label;
            names[1 + sb * n + node] = try std.fmt.allocPrint(a, "pxf_h{d}({s})", .{ harmonic, node_str });
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
