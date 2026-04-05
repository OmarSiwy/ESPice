//! Periodic AC (PAC) Analysis
//!
//! Linearises the circuit around a periodic steady-state (PSS) trajectory and
//! computes the linear periodically-time-varying (LPTV) transfer function.
//!
//! Algorithm:
//!   1. Obtain the PSS solution x_pss(t) by brute-force settling — run
//!      (pss_periods − 1) full periods of frozen-time quasi-static Newton
//!      solves at n_time_samples per period.
//!   2. Sample G(t_k) and C(t_k) (conductance and capacitance Jacobians) at
//!      N uniformly-spaced points within one LO period — one ckt.eval per
//!      sample fills both planes, captured slot-major over the CSC pattern.
//!   3. Fourier-decompose each pattern slot of G and C into harmonic
//!      coefficients G_m, C_m via FFT. A structurally zero entry has an
//!      all-zero series whose FFT is +0 in every bin, and adding +0 into the
//!      zeroed conversion matrix is a no-op, so the pattern is the whole job.
//!   4. For each input frequency f_in, build and solve the LPTV conversion
//!      matrix that couples sidebands f_in + m*f_LO for m in [-M..+M].
//!   5. Result: complex transfer (gain + phase) at each sideband frequency.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const types = @import("numerics");
const solvers = @import("solvers");
const fft_mod = solvers.fft;
const dense_lu = solvers.dense_lu;

pub const Complex = types.Complex;

pub const Options = @import("requests").Pac;

/// The LPTV sweep PAC and PXF share: find the periodic steady state,
/// linearise, then per input frequency build the conversion matrix A(f)
/// (Aᵀ when `adjoint`), drive unknown `exc_node` of sideband m = 0 with
/// `exc_val`, and solve. Caller owns freqs[n_freqs] and `out`:
///   PAC (adjoint = false): out[fi*n_sb + p] is `probe_node` at sideband
///     m = p - n_harmonics (output f = f_in + m*f_LO).
///   PXF (adjoint = true): out[fi*n_sb*n + sb*n + node] = conj(Y), the
///     transfer from every node at every sideband to `exc_node`, the output;
///     `probe_node` is unused.
pub fn sweep(
    comptime adjoint: bool,
    ckt: *root.Circuit,
    x_init: []const f64,
    exc_node: u32,
    exc_val: f64,
    probe_node: u32,
    freqs: []f64,
    out: []Complex,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    const n_harm: usize = options.n_harmonics;
    const n_sb: usize = 2 * n_harm + 1;
    const nn = n_sb * n;
    const nn2 = 2 * nn; // real expansion of the complex system

    const n_freqs = options.sweep.count();
    std.debug.assert(freqs.len == n_freqs);
    std.debug.assert(out.len == @as(usize, n_freqs) * (if (adjoint) nn else n_sb));

    const linearization = try linearize(ckt, x_init, options, allocator);
    defer linearization.deinit(allocator);

    // The LPTV system couples n_sb sidebands, each of dimension n. For
    // sideband p (harmonic m_p = p - n_harm) at omega_p = 2*pi*(f_in + m_p*f_LO):
    //
    //   sum_{q} [G_{p-q} + j*omega_p * C_{p-q}] * X_q = B_p
    //
    // where G_{m}, C_{m} are the m-th Fourier coefficients. The adjoint
    // A^H Y = e is A^T Y = e here: the real expansion of A is real.
    //
    // ponytail: dense (2M+1)n x (2M+1)n real system per frequency, CPU-serial.
    // A batched dense LU (all n_freqs matrices in one launch) is the upgrade
    // when PAC/PXF sweeps dominate a multi-harmonic mixer run.
    const a_work = try allocator.alloc(f64, nn2 * nn2);
    defer allocator.free(a_work);
    const rhs_work = try allocator.alloc(f64, nn2);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn2);
    defer allocator.free(x_work);

    var sw = options.sweep.iter();
    var fi: usize = 0;
    while (sw.next()) |f_in| : (fi += 1) {
        if (fi != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = fi, .total = freqs.len });
        root.zeroSimd(a_work);
        root.zeroSimd(rhs_work);

        buildConversionMatrix(adjoint, a_work, linearization, n, n_sb, nn, nn2, f_in, options);
        rhs_work[n_harm * n + exc_node] = exc_val; // real part

        try dense_lu.factorizeSolve(nn2, a_work, rhs_work, x_work);

        freqs[fi] = f_in;
        if (adjoint) {
            for (out[fi * nn ..][0..nn], x_work[0..nn], x_work[nn..nn2]) |*t, re, im| t.* = .{ .re = re, .im = -im };
        } else for (0..n_sb) |p| {
            const idx = p * n + probe_node;
            out[fi * n_sb + p] = .{ .re = x_work[idx], .im = x_work[nn + idx] };
        }
    }
}

/// Settled G/C Fourier coefficients, bin-major over the circuit's CSC
/// pattern: g_hat[m * nnz + slot] is slot's m-th coefficient, slot at
/// (row_idx[slot], col) for col_ptr[col] <= slot < col_ptr[col + 1].
pub const Linearization = struct {
    g_hat: []const Complex,
    c_hat: []const Complex,
    col_ptr: []const u32,
    row_idx: []const u32,

    pub fn deinit(self: Linearization, allocator: std.mem.Allocator) void {
        allocator.free(self.g_hat);
        allocator.free(self.c_hat);
    }
};

/// Settled G/C Fourier coefficients shared by PAC and PXF. Caller owns the
/// coefficient slices; sample/FFT scratch is released before returning.
pub inline fn linearize(
    ckt: *root.Circuit,
    x_init: []const f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Linearization {
    const n: usize = ckt.n;
    const n_samples: usize = options.n_time_samples;
    const period = 1.0 / options.f_lo;
    const dt = period / @as(f64, @floatFromInt(n_samples));

    const nr_opts = converger.Options{
        .max_iter = options.pss_max_newton_iter,
        .abstol = options.pss_newton_tol,
    };

    // -- Step 1: PSS via brute-force settling (frozen-time quasi-static) ----
    const x_cur = try allocator.alloc(f64, n);
    defer allocator.free(x_cur);
    // ponytail: reuse the shared copy; slice explicitly to retain the input bound.
    root.copySimd(x_cur, x_init[0..n]);

    try ckt.computeBaseline();
    const ws = try ckt.workspace();

    const nnz: usize = ckt.nnz;
    // Slot-major samples: g_td[slot * n_samples + k].
    const g_td = try allocator.alloc(f64, n_samples * nnz);
    defer allocator.free(g_td);
    const c_td = try allocator.alloc(f64, n_samples * nnz);
    defer allocator.free(c_td);

    var t: f64 = 0;
    const settle_steps = (@as(usize, options.pss_periods) - 1) * n_samples;
    for (0..settle_steps) |k| {
        if (k != 0 and k % n_samples == 0) try ckt.checkpoint(.{ .phase = .periodic, .completed = k / n_samples });
        t += dt;
        _ = converger.run(ckt, ws, x_cur, t, nr_opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => {},
        };
    }

    // -- Step 2: capture G(t_k), C(t_k) over the final period --------------
    for (0..n_samples) |k| {
        if (k != 0 and k % 64 == 0) try ckt.checkpoint(.{ .phase = .prepare, .completed = k, .total = n_samples });
        t += dt;
        _ = converger.run(ckt, ws, x_cur, t, nr_opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => {},
        };
        ckt.eval(x_cur, t);
        for (ckt.g_vals[0..nnz], ckt.c_vals[0..nnz], 0..) |g, c, slot| {
            g_td[slot * n_samples + k] = g;
            c_td[slot * n_samples + k] = c;
        }
    }

    // -- Step 3: FFT each pattern slot across time samples -----------------
    const g_hat = try allocator.alloc(Complex, n_samples * nnz);
    errdefer allocator.free(g_hat);
    const c_hat = try allocator.alloc(Complex, n_samples * nnz);
    errdefer allocator.free(c_hat);

    const fft_re = try allocator.alloc(f64, n_samples);
    defer allocator.free(fft_re);
    const fft_im = try allocator.alloc(f64, n_samples);
    defer allocator.free(fft_im);

    const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));

    for (0..nnz) |slot| {
        inline for (.{ .{ g_td, g_hat }, .{ c_td, c_hat } }) |plane| {
            @memcpy(fft_re, plane[0][slot * n_samples ..][0..n_samples]);
            @memset(fft_im, 0);
            fft_mod.fft(fft_re, fft_im);
            for (0..n_samples) |m| {
                plane[1][m * nnz + slot] = .{
                    .re = fft_re[m] * inv_n,
                    .im = fft_im[m] * inv_n,
                };
            }
        }
    }

    return .{ .g_hat = g_hat, .c_hat = c_hat, .col_ptr = ckt.col_ptr, .row_idx = ckt.row_idx };
}

/// Fill the zeroed real-expanded LPTV matrix, optionally storing its transpose.
/// The transpose is specialized at comptime so PXF needs no extra matrix pass.
/// Each (p, q, row, col) owns its four entries, so slot order is free.
pub inline fn buildConversionMatrix(
    comptime transpose: bool,
    a_work: []f64,
    lin: Linearization,
    n: usize,
    n_sb: usize,
    nn: usize,
    nn2: usize,
    f_in: f64,
    options: Options,
) void {
    const n_samples: usize = options.n_time_samples;
    const n_harm: usize = options.n_harmonics;
    for (0..n_sb) |p| {
        const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
        const omega_p = 2.0 * std.math.pi * (f_in + @as(f64, @floatFromInt(m_p)) * options.f_lo);

        for (0..n_sb) |q| {
            const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
            const m_diff = m_p - m_q;

            const fft_idx = mapHarmonicToFftBin(m_diff, n_samples) orelse continue;
            const nnz = lin.g_hat.len / n_samples;

            for (0..n) |col| {
                for (lin.col_ptr[col]..lin.col_ptr[col + 1]) |slot| {
                    const row: usize = lin.row_idx[slot];
                    const g_coeff = lin.g_hat[fft_idx * nnz + slot];
                    const c_coeff = lin.c_hat[fft_idx * nnz + slot];

                    // (G + j*omega*C) complex coefficient:
                    // real part: G_re - omega*C_im
                    // imag part: G_im + omega*C_re
                    const z_re = g_coeff.re - omega_p * c_coeff.im;
                    const z_im = g_coeff.im + omega_p * c_coeff.re;

                    // Map into the 2*nn x 2*nn real system:
                    //   | Re  -Im |   | X_re |   | B_re |
                    //   | Im   Re | * | X_im | = | B_im |
                    const gr = if (transpose) q * n + col else p * n + row;
                    const gc = if (transpose) p * n + row else q * n + col;

                    a_work[gr * nn2 + gc] += z_re;
                    a_work[gr * nn2 + (nn + gc)] += if (transpose) z_im else -z_im;
                    a_work[(nn + gr) * nn2 + gc] += if (transpose) -z_im else z_im;
                    a_work[(nn + gr) * nn2 + (nn + gc)] += z_re;
                }
            }
        }
    }
}

/// Contract entry: PSS-linearised sweep, excitation on ctx.source_node,
/// output at the last probe. Data layout: point-major complex rows
/// (frequency, tf_h{-M}..tf_h{+M}) with (re, im) per variable.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;
    if (ctx.probes.len == 0) return error.NoProbe;
    const probe = ctx.probes[ctx.probes.len - 1];

    const n_freqs: usize = opts.sweep.count();
    const n_sb: usize = 2 * @as(usize, opts.n_harmonics) + 1;
    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator;
    const freqs = try scratch.alloc(f64, n_freqs);
    defer scratch.free(freqs);
    const transfer = try scratch.alloc(Complex, n_freqs * n_sb);
    defer scratch.free(transfer);

    try sweep(false, ctx.circuit, x_op, ctx.source_node, 1.0, probe, freqs, transfer, opts, scratch);

    const names = try a.alloc([]const u8, 1 + n_sb);
    names[0] = "frequency";
    for (0..n_sb) |k| {
        const harmonic = @as(i32, @intCast(k)) - @as(i32, opts.n_harmonics);
        names[1 + k] = try std.fmt.allocPrint(a, "tf_h{d}", .{harmonic});
    }
    const ncols = names.len;
    const data = try a.alloc(f64, n_freqs * ncols * 2);
    for (0..n_freqs) |fi| {
        const row = data[fi * ncols * 2 ..][0 .. ncols * 2];
        row[0] = freqs[fi];
        row[1] = 0;
        for (0..n_sb) |k| {
            const tfv = transfer[fi * n_sb + k];
            row[(1 + k) * 2] = tfv.re;
            row[(1 + k) * 2 + 1] = tfv.im;
        }
    }
    return .{
        .plotname = "Periodic AC Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_freqs,
        .data = data,
    };
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Map a signed harmonic index to an FFT bin. Returns null if out of range.
pub fn mapHarmonicToFftBin(m: i32, n_samples: usize) ?usize {
    const ns: i32 = @intCast(n_samples);
    // FFT bin for harmonic m: m mod N (negative harmonics wrap to N+m).
    if (m >= 0 and m < ns) {
        return @intCast(m);
    } else if (m < 0 and m > -ns) {
        return @intCast(ns + m);
    }
    return null;
}
