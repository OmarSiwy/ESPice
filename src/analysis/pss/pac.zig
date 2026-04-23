//! Periodic AC: settle to the LO-driven steady state, Fourier-decompose the
//! G(t) and C(t) planes over one period, then per input frequency solve the
//! LPTV conversion matrix that couples sidebands f_in + m*f_LO, m in -M..M.
//! pxf.zig runs the same sweep on the transposed system.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;
const num = @import("core").numerics;
const fft_mod = @import("solver").fft;
const dense_lu = @import("solver").dense_lu;

pub const Complex = num.Complex;

pub const Options = @import("core").query.Pac;

/// The LPTV sweep PAC and PXF share: linearise about the periodic steady
/// state, then per input frequency build the conversion matrix A(f) (A^T when
/// `adjoint`), drive unknown `exc_node` of sideband m = 0 with `exc_val`, and
/// solve. The caller owns `freqs` (sweep count long) and `out`:
///   PAC (adjoint = false): out[fi*n_sb + p] is `probe_node` at sideband
///     m = p - n_harmonics, output frequency f_in + m*f_LO.
///   PXF (adjoint = true): out[fi*n_sb*n + sb*n + node] = conj(Y), the
///     transfer from every node at every sideband to the output `exc_node`;
///     `probe_node` is unused.
/// Cost: one dense (2(2M+1)n)^2 LU per frequency.
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

    // Sideband p (m_p = p - n_harm, w_p = 2*pi*(f_in + m_p*f_LO)) satisfies
    //   sum_q [G_{p-q} + j*w_p*C_{p-q}] X_q = B_p
    // with G_m, C_m the m-th Fourier coefficients. The adjoint A^H Y = e is
    // A^T Y = e here, since the real expansion of A is real.
    // ponytail: dense and serial per frequency. A batched dense LU over all
    // frequencies is the upgrade when PAC/PXF sweeps dominate a mixer run.
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
/// pattern: g_hat[m * nnz + slot] is the slot's m-th coefficient, the slot
/// being (row_idx[slot], col) for col_ptr[col] <= slot < col_ptr[col + 1].
/// Owns g_hat and c_hat; the pattern slices borrow the circuit's.
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

/// Settles pss_periods - 1 LO periods from x_init with frozen-time
/// quasi-static Newton solves, samples G and C over one more period, and
/// FFTs each pattern slot. The caller owns the result; scratch is freed.
fn linearize(
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

    const x_cur = try allocator.alloc(f64, n);
    defer allocator.free(x_cur);
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
        // Sources follow their waveform only under analysis("tran")
        // (§4.6.1). dt stays 0: the settling is quasi-static.
        ckt.setSimState(.{ .t = t, .kind = .tran });
        _ = converger.run(ckt, ws, x_cur, t, nr_opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => {},
        };
    }

    for (0..n_samples) |k| {
        if (k != 0 and k % 64 == 0) try ckt.checkpoint(.{ .phase = .prepare, .completed = k, .total = n_samples });
        t += dt;
        ckt.setSimState(.{ .t = t, .kind = .tran });
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

    // Only pattern slots: a structurally zero entry's series FFTs to +0 in
    // every bin, which adds nothing to the zeroed conversion matrix.
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

/// Adds the real-expanded LPTV matrix into the zeroed `a_work`
/// (nn2 x nn2 row-major), or its transpose when `transpose`, so PXF needs no
/// extra pass. Each (p, q, row, col) owns its four entries, so slot order is
/// free.
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
    const nnz = lin.g_hat.len / n_samples;
    for (0..n_sb) |p| {
        const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
        const omega_p = 2.0 * std.math.pi * (f_in + @as(f64, @floatFromInt(m_p)) * options.f_lo);

        for (0..n_sb) |q| {
            const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
            const fft_idx = mapHarmonicToFftBin(m_p - m_q, n_samples) orelse continue;

            for (0..n) |col| {
                for (lin.col_ptr[col]..lin.col_ptr[col + 1]) |slot| {
                    const row: usize = lin.row_idx[slot];
                    const g_coeff = lin.g_hat[fft_idx * nnz + slot];
                    const c_coeff = lin.c_hat[fft_idx * nnz + slot];

                    // z = G + j*w*C
                    const z_re = g_coeff.re - omega_p * c_coeff.im;
                    const z_im = g_coeff.im + omega_p * c_coeff.re;

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

/// Contract entry: drive ctx.source_node, read the last probe. Point-major
/// complex rows (frequency, tf_h{-M}..tf_h{+M}), (re, im) per variable.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;
    if (ctx.probes.len == 0) return error.NoProbe;
    const probe = ctx.probes[ctx.probes.len - 1];

    const n_freqs: usize = opts.sweep.count();
    const n_sb: usize = 2 * @as(usize, opts.n_harmonics) + 1;
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

/// FFT bin of signed harmonic m: m mod n_samples, or null when |m| >= n_samples.
pub fn mapHarmonicToFftBin(m: i32, n_samples: usize) ?usize {
    const ns: i32 = @intCast(n_samples);
    if (m >= 0 and m < ns) {
        return @intCast(m);
    } else if (m < 0 and m > -ns) {
        return @intCast(ns + m);
    }
    return null;
}
