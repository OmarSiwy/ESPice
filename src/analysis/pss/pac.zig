//! Periodic AC: shoot to the LO-driven periodic steady state, Fourier-
//! decompose the G(t) and C(t) planes over one period, then per input
//! frequency solve the LPTV conversion matrix that couples sidebands
//! f_in + m*f_LO, m in -M..M. pxf.zig runs the same sweep on the transposed
//! system, pnoise.zig on the transposed system with noise sources.
const std = @import("std");
const root = @import("../types.zig");
const pss = @import("pss.zig");
const num = @import("core").numerics;
const fft_mod = @import("solver").fft;
const dense_lu = @import("solver").dense_lu;
const slotCol = @import("solver").freq_solve.slotCol;
const FreqSolver = @import("solver").freq_solve.FreqSolver;
const Gmres = @import("solver").gmres.Gmres;

/// The complex scalar every periodic small-signal result is built from.
pub const Complex = num.Complex;

/// The `.pac` query; pxf, pnoise and the HB analyses fill one in too.
pub const Options = @import("core").query.Pac;

/// The LPTV sweep PAC, PXF and PNOISE share: per input frequency build the
/// conversion matrix A(f) (A^T when `adjoint`) from `lin`, drive sideband
/// m = 0 with `drive` (`[re(0..n), im(0..n)]`, or empty for no drive), and
/// solve. The caller owns `freqs` (sweep count long) and `out`:
///   PAC (adjoint = false): out[fi*n_sb + p] is `probe_node` at sideband
///     m = p - n_harmonics, output frequency f_in + m*f_LO.
///   PXF (adjoint = true): out[fi*n_sb*n + sb*n + node] = conj(Y), the
///     transfer from a current injected at `node` on sideband sb to the
///     output `drive` selects; `probe_node` is unused.
/// Cost: one dense (2(2M+1)n)^2 LU per frequency, or past `useKrylov`
/// preconditioned GMRES (`sweepKrylov`).
pub fn sweep(
    comptime adjoint: bool,
    ckt: *root.Circuit,
    lin: Linearization,
    drive: []const f64,
    probe_node: u32,
    freqs: []f64,
    out: []Complex,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n_sb = 2 * @as(usize, options.n_harmonics) + 1;
    if (lin.wave.len == 0 and useKrylov(ckt.n, n_sb))
        return sweepKrylov(adjoint, ckt, lin, drive, probe_node, freqs, out, options, allocator);
    return sweepDense(adjoint, ckt, lin, drive, probe_node, freqs, out, options, allocator);
}

/// `sweep` by one dense LU of the real-expanded conversion matrix per
/// input frequency.
fn sweepDense(
    comptime adjoint: bool,
    ckt: *root.Circuit,
    lin: Linearization,
    drive: []const f64,
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
    std.debug.assert(drive.len == 2 * n or drive.len == 0);

    // Sideband p (m_p = p - n_harm, w_p = 2*pi*(f_in + m_p*f_LO)) satisfies
    //   sum_q [G_{p-q} + j*w_p*C_{p-q}] X_q = B_p
    // with G_m, C_m the m-th Fourier coefficients. The transposed real
    // expansion solves A^H Y = e, so conj(Y) is A^T's solution, the
    // transfer row PXF reports.
    // Dense and serial per frequency below `useKrylov`. A(f) is not
    // G + jwC (G_m, C_m are complex and w_p differs per block row), so it
    // is no lane system; its block diagonal is, which `sweepKrylov` uses.
    const a_work = try allocator.alloc(f64, nn2 * nn2);
    defer allocator.free(a_work);
    const rhs_work = try allocator.alloc(f64, nn2);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn2);
    defer allocator.free(x_work);

    // Frequency-dependent entries: per input frequency, `acDyn` along the
    // orbit at every sideband ω, as (entry, sideband) series.
    const n_samples = lin.g_hat.len / lin.col_ptr[n];
    const series = if (lin.wave.len != 0) ckt.ac_dyn_slots.len * n_sb else 0;
    const dyn_f = try allocator.alloc(f64, n_sb + 2 * series * (n_samples + 1) + 2 * n_samples);
    defer allocator.free(dyn_f);
    const dyn_hat = try allocator.alloc(Complex, series * n_samples);
    defer allocator.free(dyn_hat);

    var sw = options.sweep.iter();
    var fi: usize = 0;
    while (sw.next()) |f_in| : (fi += 1) {
        if (fi != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = fi, .total = freqs.len });
        root.zeroSimd(a_work);
        root.zeroSimd(rhs_work);

        buildConversionMatrix(adjoint, a_work, lin, n, n_sb, nn, nn2, f_in, options);
        if (series != 0) {
            const omegas = dyn_f[0..n_sb];
            for (omegas, 0..) |*w, q| w.* = 2.0 * std.math.pi * (f_in + @as(f64, @floatFromInt(@as(i32, @intCast(q)) - @as(i32, @intCast(n_harm)))) * options.f_lo);
            dynSpectra(ckt, lin, omegas, dyn_f[n_sb..], dyn_hat);
            addDynConversion(adjoint, a_work, lin, ckt.ac_dyn_slots, dyn_hat, n, n_sb, nn, nn2);
        }
        if (drive.len != 0) {
            @memcpy(rhs_work[n_harm * n ..][0..n], drive[0..n]);
            @memcpy(rhs_work[nn + n_harm * n ..][0..n], drive[n..]);
        }

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

/// True when a sweep over n unknowns and n_sb sidebands solves by
/// `sweepKrylov`. The dense LU is O((2·n_sb·n)^3) a point and the Krylov
/// solve O(iterations·(n_sb^2·nnz + n_sb·LU)). Whole-run medians on
/// diode-RC ladder `.hbac` decks: dense 0.94x at n·n_sb = 35, even at 49,
/// Krylov 1.25x at 70, 1.44x at 85, 10x at 408 and 43x at 748
/// (dev/analysis/multitone-hb.md).
fn useKrylov(n: usize, n_sb: usize) bool {
    return n * n_sb >= 64;
}

/// `sweep` by GMRES on the conversion matrix, never formed: a product is
/// the block convolution Σ_q (G_{p-q} + jω_p·C_{p-q}) x_q over the pattern
/// (conjugated and transposed for the adjoint). The right preconditioner
/// is its block diagonal G_0 + jω_p·C_0, one lane per sideband, factored
/// once per input frequency (`FreqSolver.factorEach`). The circuit's
/// frequency-dependent entries are the dense path's alone.
fn sweepKrylov(
    comptime adjoint: bool,
    ckt: *root.Circuit,
    lin: Linearization,
    drive: []const f64,
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
    const nnz: usize = lin.col_ptr[n];

    const work = try allocator.alloc(f64, 2 * nnz + 3 * 2 * nn + n_sb);
    defer allocator.free(work);
    const g0 = work[0..nnz];
    const c0 = work[nnz..][0..nnz];
    const rhs = work[2 * nnz ..][0 .. 2 * nn];
    const p_rhs = work[2 * nnz + 2 * nn ..][0 .. 2 * nn];
    const p_x = work[2 * nnz + 4 * nn ..][0 .. 2 * nn];
    const omegas = work[2 * nnz + 6 * nn ..][0..n_sb];
    const x = try allocator.alloc(f64, 2 * nn);
    defer allocator.free(x);
    for (g0, c0, lin.g_hat[0..nnz], lin.c_hat[0..nnz]) |*g, *c, gh, ch| {
        g.* = gh.re;
        c.* = ch.re;
    }
    var fs = try FreqSolver.fromPlanes(allocator, @intCast(n), lin.col_ptr, lin.row_idx, g0, c0);
    defer fs.deinit(allocator);
    var gmres = try Gmres.init(allocator, @intCast(2 * nn), @intCast(@min(2 * nn, krylov_restart)));
    defer gmres.deinit(allocator);
    var op: ConversionOp(adjoint) = .{ .lin = lin, .n = n, .n_sb = n_sb, .omegas = omegas, .fs = &fs, .p_rhs = p_rhs, .p_x = p_x };

    var sw = options.sweep.iter();
    var fi: usize = 0;
    while (sw.next()) |f_in| : (fi += 1) {
        if (fi != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = fi, .total = freqs.len });
        for (omegas, 0..) |*w, p| w.* = 2.0 * std.math.pi * (f_in + @as(f64, @floatFromInt(@as(i32, @intCast(p)) - @as(i32, @intCast(n_harm)))) * options.f_lo);
        try fs.factorEach(allocator, omegas);
        root.zeroSimd(rhs);
        if (drive.len != 0) {
            @memcpy(rhs[n_harm * n ..][0..n], drive[0..n]);
            @memcpy(rhs[nn + n_harm * n ..][0..n], drive[n..]);
        }
        root.zeroSimd(x);
        // Where the dense LU would report a singular matrix.
        if (!gmres.solve(&op, rhs, x, krylov_tol, krylov_max_restarts).converged) return error.PacDidNotConverge;

        freqs[fi] = f_in;
        if (adjoint) {
            for (out[fi * nn ..][0..nn], x[0..nn], x[nn..]) |*t, re, im| t.* = .{ .re = re, .im = -im };
        } else for (0..n_sb) |p| {
            const idx = p * n + probe_node;
            out[fi * n_sb + p] = .{ .re = x[idx], .im = x[nn + idx] };
        }
    }
}

/// Private implementation access for the analysis test suite; void outside tests.
pub const test_access = if (@import("builtin").is_test) .{
    .sweepDense = sweepDense,
    .sweepKrylov = sweepKrylov,
} else {};

/// GMRES restart depth, relative tolerance and restarts of `sweepKrylov`.
/// The tolerance keeps the transfer within roundoff distance of the dense
/// LU's.
const krylov_restart: u32 = 60;
const krylov_tol: f64 = 1e-11;
const krylov_max_restarts: u32 = 20;

/// The conversion matrix of one input frequency as a GMRES operator, on
/// stacked-real sideband-major vectors [re(p*n + node), im(p*n + node)].
fn ConversionOp(comptime adjoint: bool) type {
    return struct {
        lin: Linearization,
        n: usize,
        n_sb: usize,
        /// ω_p of every sideband at this input frequency.
        omegas: []const f64,
        fs: *FreqSolver,
        p_rhs: []f64,
        p_x: []f64,

        /// w = A v (A^H v when adjoint): z = G_{p-q} + jω_p·C_{p-q} couples
        /// v_q[col] into w_p[row], or conj(z) couples v_p[row] into w_q[col].
        pub fn matvec(self: *@This(), v: []const f64, w: []f64) void {
            const n = self.n;
            const nn = self.n_sb * n;
            const nnz: usize = self.lin.col_ptr[n];
            const n_samples = self.lin.g_hat.len / nnz;
            root.zeroSimd(w);
            for (0..self.n_sb) |p| for (0..self.n_sb) |q| {
                const m: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(q));
                const bin = mapHarmonicToFftBin(m, n_samples) orelse continue;
                const omega_p = self.omegas[p];
                const g_hat = self.lin.g_hat[bin * nnz ..][0..nnz];
                const c_hat = self.lin.c_hat[bin * nnz ..][0..nnz];
                for (0..n) |col| for (self.lin.col_ptr[col]..self.lin.col_ptr[col + 1]) |slot| {
                    const row: usize = self.lin.row_idx[slot];
                    const z_re = g_hat[slot].re - omega_p * c_hat[slot].im;
                    const z_im = if (adjoint) -(g_hat[slot].im + omega_p * c_hat[slot].re) else g_hat[slot].im + omega_p * c_hat[slot].re;
                    const src = if (adjoint) p * n + row else q * n + col;
                    const dst = if (adjoint) q * n + col else p * n + row;
                    const x_re = v[src];
                    const x_im = v[nn + src];
                    w[dst] += z_re * x_re - z_im * x_im;
                    w[nn + dst] += z_re * x_im + z_im * x_re;
                };
            };
        }

        /// r := M^-1 r through `fs`, factored at `omegas`, M the block diagonal (G_0 + jω_p·C_0, or its ^H).
        pub fn precond(self: *@This(), r: []f64) void {
            const n = self.n;
            const nn = self.n_sb * n;
            for (0..self.n_sb) |p| {
                @memcpy(self.p_rhs[2 * p * n ..][0..n], r[p * n ..][0..n]);
                @memcpy(self.p_rhs[2 * p * n + n ..][0..n], r[nn + p * n ..][0..n]);
            }
            self.fs.solveEach(self.p_rhs, self.p_x, adjoint);
            for (0..self.n_sb) |p| {
                @memcpy(r[p * n ..][0..n], self.p_x[2 * p * n ..][0..n]);
                @memcpy(r[nn + p * n ..][0..n], self.p_x[2 * p * n + n ..][0..n]);
            }
        }
    };
}

/// Settled G/C Fourier coefficients, bin-major over the circuit's CSC
/// pattern: g_hat[m * nnz + slot] is the slot's m-th coefficient, the slot
/// being (row_idx[slot], col) for col_ptr[col] <= slot < col_ptr[col + 1].
/// Owns g_hat, c_hat and wave; the pattern slices borrow the circuit's.
pub const Linearization = struct {
    g_hat: []const Complex,
    c_hat: []const Complex,
    col_ptr: []const u32,
    row_idx: []const u32,
    /// The orbit's sample rows (`Orbit.wave`) and the kind they linearize
    /// under, kept only when the circuit has frequency-dependent entries
    /// (`Circuit.ac_dyn_slots`), whose terms `sweep` samples per input
    /// frequency. Empty otherwise.
    wave: []const f64 = &.{},
    kind: root.AnalysisKind = .ac,

    /// Frees g_hat, c_hat and wave with the allocator `linearize` took;
    /// the pattern slices stay the circuit's.
    pub fn deinit(self: Linearization, allocator: std.mem.Allocator) void {
        allocator.free(self.g_hat);
        allocator.free(self.c_hat);
        allocator.free(self.wave);
    }
};

/// One period of a periodic steady state (the shooting PSS's `orbit` or
/// `hb.orbit`) with every unknown recorded.
pub const Orbit = struct {
    /// n_samples + 1 point-major rows [t, x(0..n)], row k at t = k*T/n_samples.
    wave: []f64,
    converged: bool,

    /// The state at sample k, a view into `wave`.
    pub fn state(self: Orbit, k: usize, n: usize) []const f64 {
        return self.wave[k * (n + 1) + 1 ..][0..n];
    }

    /// Samples per period, the last row (t = T) excluded.
    pub fn samples(self: Orbit, n: usize) usize {
        return self.wave.len / (n + 1) - 1;
    }
};

/// Shoots from x_init to the periodic steady state (`pss.solve`: trapezoid
/// steps that carry the charge history) and records one period of every
/// unknown. An unconverged shoot still returns its last period, flagged. The
/// caller frees `wave` with `allocator`.
pub fn orbit(ckt: *root.Circuit, x_init: []const f64, options: pss.Options, allocator: std.mem.Allocator) !Orbit {
    const n: usize = ckt.n;
    const rows = try allocator.alloc(u32, n);
    defer allocator.free(rows);
    for (rows, 0..) |*r, i| r.* = @intCast(i);
    const wave = try allocator.alloc(f64, (@as(usize, options.n_samples) + 1) * (n + 1));
    errdefer allocator.free(wave);
    const res = try pss.solve(ckt, x_init, rows, wave, options, allocator);
    return .{ .wave = wave, .converged = res.converged };
}

/// Samples G and C along `orb` under the small-signal analysis `kind`
/// (`.ac` or `.noise`) and Fourier-transforms each pattern slot.
/// The orbit's sample count must be a power of two. The caller frees the
/// result with `Linearization.deinit` on `allocator`.
pub fn linearize(ckt: *root.Circuit, orb: Orbit, kind: root.AnalysisKind, allocator: std.mem.Allocator) !Linearization {
    const n: usize = ckt.n;
    const n_samples = orb.samples(n);
    const nnz: usize = ckt.nnz;
    const plane = n_samples * nnz;
    // Slot-major samples, G then C: td[slot * n_samples + k].
    const td = try allocator.alloc(f64, 2 * plane);
    defer allocator.free(td);

    for (0..n_samples) |k| {
        if (k != 0 and k % 64 == 0) try ckt.checkpoint(.{ .phase = .prepare, .completed = k, .total = n_samples });
        const t = orb.wave[k * (n + 1)];
        // A small-signal kind is not "static" (§4.6.1), so sources follow
        // their waveform at t, and an idt linearizes to its 1/(jw) row.
        ckt.setSimState(.{ .t = t, .kind = kind });
        ckt.eval(orb.state(k, n), t);
        for (ckt.g_vals[0..nnz], ckt.c_vals[0..nnz], 0..) |g, c, slot| {
            td[slot * n_samples + k] = g;
            td[plane + slot * n_samples + k] = c;
        }
    }

    // Only pattern slots: a structurally zero entry's series FFTs to +0 in
    // every bin, which adds nothing to the zeroed conversion matrix.
    const g_hat = try allocator.alloc(Complex, plane);
    errdefer allocator.free(g_hat);
    const c_hat = try allocator.alloc(Complex, plane);
    errdefer allocator.free(c_hat);
    try spectra(td[0..plane], n_samples, g_hat, allocator);
    try spectra(td[plane..], n_samples, c_hat, allocator);
    const wave: []const f64 = if (ckt.ac_dyn_slots.len != 0) try allocator.dupe(f64, orb.wave) else &.{};

    return .{ .g_hat = g_hat, .c_hat = c_hat, .col_ptr = ckt.col_ptr, .row_idx = ckt.row_idx, .wave = wave, .kind = kind };
}

/// Fourier coefficients of the `td.len / n_samples` series stored
/// series-major in `td` (td[s * n_samples + k]), written bin-major into
/// `hat` (hat[m * count + s]) and scaled by 1/n_samples, so bin m is the
/// m-th complex Fourier coefficient. n_samples must be a power of two.
/// Asserts hat.len == td.len.
pub fn spectra(td: []const f64, n_samples: usize, hat: []Complex, allocator: std.mem.Allocator) !void {
    std.debug.assert(hat.len == td.len);
    const count = td.len / n_samples;
    const fft_buf = try allocator.alloc(f64, 2 * n_samples);
    defer allocator.free(fft_buf);
    const fft_re = fft_buf[0..n_samples];
    const fft_im = fft_buf[n_samples..];
    const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));
    for (0..count) |s| {
        @memcpy(fft_re, td[s * n_samples ..][0..n_samples]);
        @memset(fft_im, 0);
        fft_mod.fft(fft_re, fft_im);
        for (0..n_samples) |m| hat[m * count + s] = .{ .re = fft_re[m] * inv_n, .im = fft_im[m] * inv_n };
    }
}

/// Shoots to the LO-periodic steady state in n_time_samples steps and
/// linearizes about it: the PAC and PXF front half. The caller frees the
/// result with `Linearization.deinit` on `allocator`.
pub fn settle(ckt: *root.Circuit, x_init: []const f64, options: Options, allocator: std.mem.Allocator) !Linearization {
    const orb = try orbit(ckt, x_init, .{
        .tol = options.tol,
        .period = 1.0 / options.f_lo,
        .n_samples = options.n_time_samples,
        .max_newton_iter = options.pss_max_newton_iter,
        .newton_tol = options.pss_newton_tol,
    }, allocator);
    defer allocator.free(orb.wave);
    return linearize(ckt, orb, .ac, allocator);
}

/// Fourier coefficients of `Circuit.acDyn` along `lin`'s orbit at each ω in
/// `omegas` (one per sideband): hat[m * series + e * omegas.len + q] is bin m
/// of entry e at omegas[q], series = entries * omegas.len. `work` holds
/// 2 * series * (n_samples + 1) + 2 * n_samples values. Leaves the sim state
/// at the last sample.
pub fn dynSpectra(ckt: *root.Circuit, lin: Linearization, omegas: []const f64, work: []f64, hat: []Complex) void {
    const n: usize = ckt.n;
    const n_samples = lin.wave.len / (n + 1) - 1;
    const series = ckt.ac_dyn_slots.len * omegas.len;
    const re = work[0..series];
    const im = work[series..][0..series];
    const td = work[2 * series ..][0 .. 2 * series * n_samples];
    const fft_re = work[2 * series * (n_samples + 1) ..][0..n_samples];
    const fft_im = work[2 * series * (n_samples + 1) + n_samples ..][0..n_samples];
    for (0..n_samples) |k| {
        const row = lin.wave[k * (n + 1) ..][0 .. n + 1];
        ckt.setSimState(.{ .t = row[0], .kind = lin.kind });
        ckt.acDyn(row[1..], omegas, re, im);
        for (re, im, 0..) |r, i, sr| {
            td[sr * n_samples + k] = r;
            td[(series + sr) * n_samples + k] = i;
        }
    }
    const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));
    for (0..series) |sr| {
        @memcpy(fft_re, td[sr * n_samples ..][0..n_samples]);
        @memcpy(fft_im, td[(series + sr) * n_samples ..][0..n_samples]);
        fft_mod.fft(fft_re, fft_im);
        for (0..n_samples) |m| hat[m * series + sr] = .{ .re = fft_re[m] * inv_n, .im = fft_im[m] * inv_n };
    }
}

/// Adds the frequency-dependent entries into `a_work` as
/// `buildConversionMatrix` adds G + jωC: bin m_p - m_q of entry e at the
/// input sideband's ω_q couples sideband q into p.
// ponytail: the operator sees its input's sideband ω_q, exact when the chain
// into the operator is time-invariant along the orbit (every line in
// models/). An operator fed by a modulated signal, or a ddt of an operator
// with a modulated gain, needs acDyn split at the operator.
pub fn addDynConversion(
    comptime transpose: bool,
    a_work: []f64,
    lin: Linearization,
    slots: []const u32,
    hat: []const Complex,
    n: usize,
    n_sb: usize,
    nn: usize,
    nn2: usize,
) void {
    const nnz = lin.col_ptr[n];
    const n_samples = lin.g_hat.len / nnz;
    const series = slots.len * n_sb;
    for (0..n_sb) |p| for (0..n_sb) |q| {
        const bin = mapHarmonicToFftBin(@as(i32, @intCast(p)) - @as(i32, @intCast(q)), n_samples) orelse continue;
        for (slots, 0..) |slot, e| {
            if (slot >= nnz) continue;
            const z = hat[bin * series + e * n_sb + q];
            stamp(transpose, a_work, n, nn, nn2, p, q, lin.row_idx[slot], slotCol(lin.col_ptr, slot), z.re, z.im);
        }
    };
}

/// Adds z at sideband block (p, q), entry (row, col), of the real-expanded
/// `a_work`, or of its transpose.
inline fn stamp(comptime transpose: bool, a_work: []f64, n: usize, nn: usize, nn2: usize, p: usize, q: usize, row: usize, col: usize, z_re: f64, z_im: f64) void {
    //   | Re  -Im |   | X_re |   | B_re |
    //   | Im   Re | * | X_im | = | B_im |
    const gr = if (transpose) q * n + col else p * n + row;
    const gc = if (transpose) p * n + row else q * n + col;

    a_work[gr * nn2 + gc] += z_re;
    a_work[gr * nn2 + (nn + gc)] += if (transpose) z_im else -z_im;
    a_work[(nn + gr) * nn2 + gc] += if (transpose) -z_im else z_im;
    a_work[(nn + gr) * nn2 + (nn + gc)] += z_re;
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
    const n_harm: usize = options.n_harmonics;
    const nnz: usize = lin.col_ptr[n];
    const n_samples = lin.g_hat.len / nnz;
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
                    stamp(transpose, a_work, n, nn, nn2, p, q, row, col, z_re, z_im);
                }
            }
        }
    }
}

/// Contract entry: the deck's AC excitation (`ctx.ac_drive`, applied as
/// `.ac` applies it) on sideband 0, read at `opts.out_node`. Point-major
/// complex rows (frequency, tf_h{-M}..tf_h{+M}), (re, im) per variable.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const n_freqs: usize = opts.sweep.count();
    const n_sb: usize = 2 * @as(usize, opts.n_harmonics) + 1;
    const scratch = ctx.scratch_allocator;
    const freqs = try scratch.alloc(f64, n_freqs);
    defer scratch.free(freqs);
    const transfer = try scratch.alloc(Complex, n_freqs * n_sb);
    defer scratch.free(transfer);

    const lin = try settle(ctx.circuit, ctx.x_op, opts, scratch);
    defer lin.deinit(scratch);
    try sweep(false, ctx.circuit, lin, ctx.ac_drive, opts.out_node, freqs, transfer, opts, scratch);
    return result(a, freqs, transfer, opts.n_harmonics, "Periodic AC Analysis");
}

/// PAC's published shape, shared with `.hbac`: point-major complex rows
/// (frequency, tf_h{-M}..tf_h{+M}) from `sweep(false, ...)`'s `freqs` and
/// `transfer`, allocated in `a`.
pub fn result(a: std.mem.Allocator, freqs: []const f64, transfer: []const Complex, n_harmonics: u16, plotname: []const u8) !root.Result {
    const n_freqs = freqs.len;
    const n_sb: usize = 2 * @as(usize, n_harmonics) + 1;
    const names = try a.alloc([]const u8, 1 + n_sb);
    names[0] = "frequency";
    for (0..n_sb) |k| {
        const harmonic = @as(i32, @intCast(k)) - @as(i32, n_harmonics);
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
        .plotname = plotname,
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

test spectra {
    // Bin-major output: hat[m * 2 + s] for two series, 1 + cos and sin(2·),
    // in the forward convention X_m = Σ x_k e^(-j2πkm/N) / N.
    const ns = 8;
    var td: [2 * ns]f64 = undefined;
    for (0..ns) |k| {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / ns;
        td[k] = 1 + @cos(a);
        td[ns + k] = @sin(2 * a);
    }
    var hat: [2 * ns]Complex = undefined;
    try spectra(&td, ns, &hat, std.testing.allocator);
    for (0..ns) |m| {
        const c = hat[m * 2];
        const s = hat[m * 2 + 1];
        const want_c: f64 = switch (m) {
            0 => 1,
            1, ns - 1 => 0.5,
            else => 0,
        };
        const want_s: f64 = switch (m) {
            2 => -0.5,
            ns - 2 => 0.5,
            else => 0,
        };
        try std.testing.expectApproxEqAbs(want_c, c.re, 1e-15);
        try std.testing.expectApproxEqAbs(@as(f64, 0), c.im, 1e-15);
        try std.testing.expectApproxEqAbs(@as(f64, 0), s.re, 1e-15);
        try std.testing.expectApproxEqAbs(want_s, s.im, 1e-15);
    }
}

test ConversionOp {
    // The matrix-free GMRES operator against the dense conversion matrix
    // the LU path builds, forward and adjoint, on a random three-node
    // pattern with complex G and C spectra.
    var prng = std.Random.DefaultPrng.init(0xC0DE);
    const rnd = prng.random();
    const n = 3;
    const n_harm = 1;
    const n_sb = 2 * n_harm + 1;
    const nn = n_sb * n;
    const nn2 = 2 * nn;
    const n_samples = 8;
    const col_ptr = [_]u32{ 0, 2, 3, 5 };
    const row_idx = [_]u32{ 0, 2, 1, 0, 2 };
    var g_hat: [n_samples * row_idx.len]Complex = undefined;
    var c_hat: [n_samples * row_idx.len]Complex = undefined;
    for (&g_hat, &c_hat) |*g, *c| {
        g.* = .{ .re = rnd.float(f64) - 0.5, .im = rnd.float(f64) - 0.5 };
        c.* = .{ .re = (rnd.float(f64) - 0.5) * 1e-6, .im = (rnd.float(f64) - 0.5) * 1e-6 };
    }
    const lin: Linearization = .{ .g_hat = &g_hat, .c_hat = &c_hat, .col_ptr = &col_ptr, .row_idx = &row_idx };
    const opts: Options = .{ .f_lo = 1e5, .out_node = 0, .n_harmonics = n_harm, .sweep = .{ .f_start = 1, .f_stop = 1 } };
    const f_in: f64 = 3e4;
    var omegas: [n_sb]f64 = undefined;
    for (&omegas, 0..) |*w, p| w.* = 2.0 * std.math.pi * (f_in + @as(f64, @floatFromInt(@as(i32, @intCast(p)) - n_harm)) * opts.f_lo);
    var v: [nn2]f64 = undefined;
    for (&v) |*x| x.* = rnd.float(f64) - 0.5;
    var a_work: [nn2 * nn2]f64 = undefined;
    var want: [nn2]f64 = undefined;
    var got: [nn2]f64 = undefined;
    inline for (.{ false, true }) |adjoint| {
        @memset(&a_work, 0);
        buildConversionMatrix(adjoint, &a_work, lin, n, n_sb, nn, nn2, f_in, opts);
        for (&want, 0..) |*w, r| w.* = num.dot(a_work[r * nn2 ..][0..nn2], &v);
        var op: ConversionOp(adjoint) = .{ .lin = lin, .n = n, .n_sb = n_sb, .omegas = &omegas, .fs = undefined, .p_rhs = got[0..0], .p_x = got[0..0] };
        op.matvec(&v, &got);
        for (want, got) |w, g| try std.testing.expectApproxEqAbs(w, g, 1e-12);
    }
}
