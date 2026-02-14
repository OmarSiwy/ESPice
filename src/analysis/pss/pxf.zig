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
const mapHarmonicToFftBin = pac.mapHarmonicToFftBin;
const types = @import("solvers").types;
const fft_mod = @import("solvers").fft;
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "PXF: mapHarmonicToFftBin" {
    try testing.expectEqual(@as(?usize, 0), mapHarmonicToFftBin(0, 8));
    try testing.expectEqual(@as(?usize, 1), mapHarmonicToFftBin(1, 8));
    try testing.expectEqual(@as(?usize, 7), mapHarmonicToFftBin(-1, 8));
    try testing.expectEqual(@as(?usize, 5), mapHarmonicToFftBin(-3, 8));
    try testing.expectEqual(@as(?usize, null), mapHarmonicToFftBin(8, 8));
    try testing.expectEqual(@as(?usize, null), mapHarmonicToFftBin(-8, 8));
}

test "PXF: adjoint resistive mixer — verify transpose duality with PAC" {
    // For a purely resistive 1-node mixer (G(t) = G0*(1 + m*cos(2*pi*f_LO*t))),
    // the PAC and PXF solutions should be transposes of each other. Since n=1,
    // the conversion matrix is n_sb × n_sb and its transpose should give the
    // same magnitude pattern when the same node is both source and output.
    //
    // We verify: PXF's adjoint solution at sideband m has the same magnitude
    // as PAC's forward solution at sideband m (for a symmetric 1-node circuit).
    const allocator = testing.allocator;

    const f_lo: f64 = 1e6;
    const n_harm: usize = 2;
    const n_sb: usize = 2 * n_harm + 1;
    const n: usize = 1;
    const n_samples: usize = 64;
    const g0: f64 = 1e-3;
    const mod_depth: f64 = 0.5;

    const t_period = 1.0 / f_lo;
    const dt = t_period / @as(f64, @floatFromInt(n_samples));

    var g_time: [n_samples]f64 = undefined;
    for (0..n_samples) |k| {
        const tt = @as(f64, @floatFromInt(k)) * dt;
        g_time[k] = g0 * (1.0 + mod_depth * @cos(2.0 * std.math.pi * f_lo * tt));
    }

    var fft_re: [n_samples]f64 = undefined;
    var fft_im: [n_samples]f64 = [_]f64{0} ** n_samples;
    root.copySimd(&fft_re, &g_time);
    fft_mod.fft(&fft_re, &fft_im);
    const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));

    var g_hat: [n_samples]Complex = undefined;
    for (0..n_samples) |m| {
        g_hat[m] = .{ .re = fft_re[m] * inv_n, .im = fft_im[m] * inv_n };
    }

    const nn = n_sb * n;
    const nn2 = 2 * nn;

    // --- Forward (PAC-style) solve: A * X = e_source ---
    const a_fwd = try allocator.alloc(f64, nn2 * nn2);
    defer allocator.free(a_fwd);
    const rhs_fwd = try allocator.alloc(f64, nn2);
    defer allocator.free(rhs_fwd);
    const x_fwd = try allocator.alloc(f64, nn2);
    defer allocator.free(x_fwd);

    root.zeroSimd(a_fwd);
    root.zeroSimd(rhs_fwd);

    for (0..n_sb) |p| {
        for (0..n_sb) |q| {
            const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
            const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
            const m_diff = m_p - m_q;
            const fft_idx = mapHarmonicToFftBin(m_diff, n_samples) orelse continue;

            // No C, pure conductance.
            const z_re = g_hat[fft_idx].re;
            const z_im = g_hat[fft_idx].im;

            const gr = p * n;
            const gc = q * n;

            a_fwd[gr * nn2 + gc] += z_re;
            a_fwd[gr * nn2 + (nn + gc)] += -z_im;
            a_fwd[(nn + gr) * nn2 + gc] += z_im;
            a_fwd[(nn + gr) * nn2 + (nn + gc)] += z_re;
        }
    }
    rhs_fwd[n_harm * n] = 1.0; // excitation at sideband m=0, node 0
    try dense_lu.factorizeSolve(nn2, a_fwd, rhs_fwd, x_fwd);

    // --- Adjoint (PXF-style) solve: A^T * Y = e_output ---
    const a_adj = try allocator.alloc(f64, nn2 * nn2);
    defer allocator.free(a_adj);
    const rhs_adj = try allocator.alloc(f64, nn2);
    defer allocator.free(rhs_adj);
    const x_adj = try allocator.alloc(f64, nn2);
    defer allocator.free(x_adj);

    root.zeroSimd(a_adj);
    root.zeroSimd(rhs_adj);

    // Build A^T by transposing the assembly.
    for (0..n_sb) |p| {
        for (0..n_sb) |q| {
            const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
            const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
            const m_diff = m_p - m_q;
            const fft_idx = mapHarmonicToFftBin(m_diff, n_samples) orelse continue;

            const z_re = g_hat[fft_idx].re;
            const z_im = g_hat[fft_idx].im;

            const gr = p * n;
            const gc = q * n;

            // Transposed: swap (gr, gc)
            a_adj[gc * nn2 + gr] += z_re;
            a_adj[gc * nn2 + (nn + gr)] += z_im;
            a_adj[(nn + gc) * nn2 + gr] += -z_im;
            a_adj[(nn + gc) * nn2 + (nn + gr)] += z_re;
        }
    }
    rhs_adj[n_harm * n] = 1.0; // selector at output node 0, sideband m=0
    try dense_lu.factorizeSolve(nn2, a_adj, rhs_adj, x_adj);

    // For a 1-node symmetric circuit, |X_fwd[sb]| should equal |conj(Y_adj[sb])|
    // at each sideband (same node for both source and output).
    for (0..n_sb) |sb| {
        const fwd_re = x_fwd[sb * n];
        const fwd_im = x_fwd[nn + sb * n];
        const fwd_mag = @sqrt(fwd_re * fwd_re + fwd_im * fwd_im);

        const adj_re = x_adj[sb * n];
        const adj_im = -x_adj[nn + sb * n]; // conj
        const adj_mag = @sqrt(adj_re * adj_re + adj_im * adj_im);

        try testing.expectApproxEqRel(fwd_mag, adj_mag, 1e-10);
    }

    // Sanity: m=0 response ~1/G0, m=+/-1 sidebands nonzero.
    const x0_mag = @sqrt(x_adj[n_harm * n] * x_adj[n_harm * n] +
        x_adj[nn + n_harm * n] * x_adj[nn + n_harm * n]);
    try testing.expect(x0_mag > 0.5 / g0);
    try testing.expect(x0_mag < 2.0 / g0);
}

test "PXF: Complex arithmetic" {
    const a_c = Complex{ .re = 3.0, .im = 4.0 };
    const b_c = Complex{ .re = 1.0, .im = -2.0 };

    const sum = Complex.add(a_c, b_c);
    try testing.expectApproxEqAbs(@as(f64, 4.0), sum.re, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), sum.im, 1e-15);

    try testing.expectApproxEqAbs(@as(f64, 5.0), a_c.mag(), 1e-15);

    const conj = a_c.conj();
    try testing.expectApproxEqAbs(@as(f64, 3.0), conj.re, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -4.0), conj.im, 1e-15);
}

test "PXF: dense_lu solveT matches known solution" {
    // 2x2 system: [2 1; 1 3] * x = [5; 7] => x = [1.6, 1.8]
    var a_mat = [_]f64{ 2, 1, 1, 3 };
    const b_vec = [_]f64{ 5, 7 };
    var x_vec: [2]f64 = undefined;
    try dense_lu.factorizeSolve(2, &a_mat, &b_vec, &x_vec);
    try testing.expectApproxEqAbs(@as(f64, 1.6), x_vec[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.8), x_vec[1], 1e-12);
}
