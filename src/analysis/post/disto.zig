//! Distortion analysis (`.disto`) by a simplified Volterra series. One eval
//! at the operating point gives the analytic G and C planes. The
//! second-order kernel is a central difference of the analytic Jacobians
//! (d2F = dG/dx, d2Q = dC/dx), two evals per unknown, and each frequency is
//! a few dense solves.
//!
//! The third-order kernel is never stored. d3 is O(n^4) and its only uses
//! are the contractions d3(V1,V1,V1) and, for two tones, d3(V1,V1,V2*), so
//! each is taken as directional second differences of the Jacobians along
//! the real directions V1 spans: eight or twelve evals per frequency point,
//! no tensor (see `cubicForms`, `mixedCubic`).
//!
//! Every kernel has a resistive and a charge part. A product at ω_out
//! sees K = F⁽ᵏ⁾ + jω_out·Q⁽ᵏ⁾, as ngspice's device DISTO sections stamp the
//! charge Taylor coefficients times jω of the mixing frequency.
//!
//! With a second tone (the card's `f2overf1`, a `DISTOF2` source) the
//! products are ngspice's intermodulation set: f1+f2 and f1-f2 from the
//! quadratic kernel, 2f1-f2 from the cubic one and the f1-f2 and 2f1
//! responses beating against the tones.
//!
//! ponytail: d2 kept as its nonzero terms (at most nnz(G) per unknown) and
//! O(n^3) dense solves per frequency; device-side analytic F''/F''' stamps and
//! a sparse frequency solve are the upgrade for large n.
const std = @import("std");
const root = @import("../types.zig");
const simdZero = root.zeroSimd;
const simdCopy = root.copySimd;
const dense_lu = @import("solver").dense_lu;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Disto;

/// The caller's output buffers for one sweep. The four summary columns are
/// always written, one value per frequency point. `h2`/`h3` are ngspice's
/// own product, the second- and third-harmonic solution sampled at `probes`,
/// point-major with (re, im) adjacent; left empty, that order is not
/// computed at all.
pub const Out = struct {
    freqs: []f64,
    hd2: []f64,
    v1_mag: []f64,
    v2_mag: []f64,
    probes: []const u32 = &.{},
    h2: []f64 = &.{},
    h3: []f64 = &.{},
    /// Two-tone products (`Options.f2_ratio` > 0) at `probes`, laid out as
    /// `h2`: the f1+f2, f1-f2 and 2f1-f2 vectors. Each one left empty is not
    /// computed.
    f1pf2: []f64 = &.{},
    f1mf2: []f64 = &.{},
    twof1mf2: []f64 = &.{},
};

/// Harmonic responses across the frequency sweep, into `out`:
///   1. Linearize at the operating point: one eval(), dense G and C.
///   2. Second-order kernels d2F/dxa dxb = dG[.,a]/dx_b and d2Q = dC/dx, a
///      central difference of the analytic Jacobians at 2n perturbed points
///      (only the extra order is FD).
///   3. For each frequency f, with K(ω) = F + jω·Q for each order's kernel:
///      a. Solve first-order: (G + jwC) * V1 = excitation
///      b. Second-order nonlinear current ½ K''(2w)(V1, V1)
///      c. Solve second-order: (G + j*2w*C) * V2 = -½ K''(2w)(V1, V1)
///      d. HD2 = |V2[output]| / |V1[output]|
///      e. Third order, only when asked for: the 3f1 current is
///         K''(3w)(V1, V2) + ⅙·K'''(3w)(V1, V1, V1), and
///         (G + j*3w*C) * V3 = -that.
///
/// The phasor convention is ngspice's throughout: the drive is half the
/// sinusoid amplitude (cktdisto.c:115) and every kernel is a one-sided
/// phasor, so the 2f1 source term is ½·F''·V1². ngspice spells the ½ into the
/// device coefficient (`g2 = 0.5 * gd / vte`, diodset.c:78) and contributes
/// `g2 * V1²` (dloadfns.c:545 D1n2F1). The harmonic vectors are reported as
/// sinusoid amplitudes, ×2 (DkerProc, dkerproc.c:43-52, `HARMONIC_SCALE`);
/// the summary magnitudes are not rescaled. The planes are left at the
/// operating point.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    out: Out,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    const freqs = out.freqs;
    const hd2 = out.hd2;
    const v1_mag = out.v1_mag;
    const v2_mag = out.v2_mag;
    std.debug.assert(hd2.len == freqs.len and v1_mag.len == freqs.len and v2_mag.len == freqs.len);
    const want_h2 = out.h2.len != 0;
    const want_h3 = out.h3.len != 0;
    std.debug.assert(!want_h2 or out.h2.len == freqs.len * out.probes.len * 2);
    std.debug.assert(!want_h3 or out.h3.len == freqs.len * out.probes.len * 2);
    const want_im3 = out.twof1mf2.len != 0;
    const two_tone = out.f1pf2.len != 0 or out.f1mf2.len != 0 or want_im3;
    std.debug.assert(!two_tone or options.f2_ratio > 0);

    ckt.eval(x_op, 0);

    // The dense G and C planes, adjacent: the third-order stencils
    // difference both halves as one 2n·n slab.
    const n2 = n * n;
    const gc0 = try allocator.alloc(f64, 2 * n2);
    defer allocator.free(gc0);
    const g_dense = gc0[0..n2];
    const c_mat = gc0[n2..];
    ckt.denseG(g_dense);
    ckt.denseC(c_mat);

    // d2[row][a][b] ≈ (G(x_op + eps*e_b) − G(x_op − eps*e_b))[row][a] / 2eps,
    // and its charge twin from C, kept as the nonzero terms only. G and C
    // share one pattern and both planes are 0 outside it, so only pattern
    // slots can contribute. Central, not forward: the forward difference's
    // O(eps·d3) error was the whole 2nd-harmonic residual of
    // disto/bench_disto_diode_clipper.
    const eps = options.fd_eps;
    const inv_2eps = 0.5 / eps;
    const nnz: usize = ckt.nnz;
    const gc_plus = try allocator.alloc(f64, 2 * nnz);
    defer allocator.free(gc_plus);
    const g_plus = gc_plus[0..nnz];
    const c_plus = gc_plus[nnz..];

    const g_pert = try allocator.alloc(f64, 2 * n2);
    defer allocator.free(g_pert);
    const x_pert = try allocator.alloc(f64, n);
    defer allocator.free(x_pert);

    var term_list: std.ArrayList(Term) = .empty;
    defer term_list.deinit(allocator);
    for (0..n) |b| {
        if (b != 0) try ckt.checkpoint(.{ .phase = .prepare, .completed = b, .total = n });
        simdCopy(x_pert, x_op[0..n]);
        x_pert[b] += eps;
        ckt.eval(x_pert, 0);
        simdCopy(g_plus, ckt.g_vals[0..nnz]);
        simdCopy(c_plus, ckt.c_vals[0..nnz]);
        x_pert[b] = x_op[b] - eps;
        ckt.eval(x_pert, 0);
        for (0..n) |a| for (ckt.col_ptr[a]..ckt.col_ptr[a + 1]) |slot| {
            // (-0 compares equal to 0 and is skipped; NaN is kept.)
            const coeff = (g_plus[slot] - ckt.g_vals[slot]) * inv_2eps;
            const qcoeff = (c_plus[slot] - ckt.c_vals[slot]) * inv_2eps;
            if (coeff == 0 and qcoeff == 0) continue;
            try term_list.append(allocator, .{ .row = ckt.row_idx[slot], .a = @intCast(a), .b = @intCast(b), .coeff = coeff, .qcoeff = qcoeff });
        };
    }

    // Put the planes back at the operating point.
    ckt.eval(x_op, 0);

    // Row by row in (a, b) order: the per-frequency contractions add
    // exactly the terms a dense d2 sweep with a zero skip would, in the same
    // order, so the sums are bitwise the same. The sort is stable and b was
    // appended in ascending order.
    const terms = term_list.items;
    std.sort.block(Term, terms, {}, struct {
        fn lt(_: void, x: Term, y: Term) bool {
            return x.row < y.row or (x.row == y.row and x.a < y.a);
        }
    }.lt);
    const row_start = try allocator.alloc(u32, n + 1);
    defer allocator.free(row_start);
    {
        var t: u32 = 0;
        for (0..n) |row| {
            row_start[row] = t;
            while (t < terms.len and terms[t].row == row) t += 1;
        }
        row_start[n] = t;
    }

    const nn = 2 * n;
    const a_work = try allocator.alloc(f64, nn * nn);
    defer allocator.free(a_work);
    const rhs_work = try allocator.alloc(f64, nn);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn);
    defer allocator.free(x_work);

    const x_work2 = try allocator.alloc(f64, nn);
    defer allocator.free(x_work2);
    const x_work3 = try allocator.alloc(f64, nn);
    defer allocator.free(x_work3);
    // Each A(kω) adds the frequency-dependent entries (`Circuit.acDyn`). The
    // kernels are differences of G, which leaves those entries out, so a
    // nonlinearity behind a delay or filter reaches no harmonic.
    // ponytail: exact for the linear lines in models/; a nonlinear
    // operator input needs acDyn's own second derivative.
    const dyn_work = try allocator.alloc(f64, 2 * ckt.ac_dyn_slots.len);
    defer allocator.free(dyn_work);

    // Third-order scratch: one more dense G/C pair and the eight real cubic
    // forms of `cubicForms`. Both are the size of the (2n)^2 LU slab or
    // less, so they are allocated even when h3 is not wanted.
    const g_minus = try allocator.alloc(f64, 2 * n2);
    defer allocator.free(g_minus);
    const cubic = try allocator.alloc(f64, 8 * n);
    defer allocator.free(cubic);
    // Two-tone scratch: the F2 response V1b (and its conjugate's imaginary
    // part), the f1-f2 response, the IM right-hand side and solution, and
    // the two 2n·n G/C slabs `mixedCubic` accumulates.
    const im_work = try allocator.alloc(f64, if (two_tone) 5 * nn + (if (want_im3) 4 * n2 else 0) else 0);
    defer allocator.free(im_work);
    const v1b = im_work[0..if (two_tone) nn else 0];
    const v1b_cim = im_work[if (two_tone) nn else 0..][0..if (two_tone) n else 0];
    const v2m = im_work[if (two_tone) 2 * nn else 0..][0..if (two_tone) nn else 0];
    const x_im = im_work[if (two_tone) 3 * nn else 0..][0..if (two_tone) nn else 0];
    const t3 = im_work[if (two_tone) 4 * nn else 0..][0..if (two_tone) nn else 0];
    const m_planes = im_work[if (two_tone) 5 * nn else 0..];

    const v1_re = x_work[0..n];
    const v1_im = x_work[n..nn];
    const v2_re = x_work2[0..n];
    const v2_im = x_work2[n..nn];

    // Half amplitude (cktdisto.c:115-116): the F1 drive is the one-sided
    // phasor of a cosine of amplitude `ac_magnitude`.
    const phase_rad = options.ac_phase * std.math.pi / 180.0;
    const drive_re = 0.5 * options.ac_magnitude * @cos(phase_rad);
    const drive_im = 0.5 * options.ac_magnitude * @sin(phase_rad);

    // F2, held at f2_ratio·f_start over the sweep (distoan.c:143): its
    // first-order response V1b is one solve for every point.
    const omega_f2 = 2.0 * std.math.pi * options.f2_ratio * options.sweep.f_start;
    if (two_tone) {
        const ph2 = options.ac2_phase * std.math.pi / 180.0;
        simdZero(rhs_work);
        rhs_work[options.drive2_branch] = 0.5 * options.ac2_magnitude * @cos(ph2);
        rhs_work[n + options.drive2_branch] = 0.5 * options.ac2_magnitude * @sin(ph2);
        try solveAt(ckt, x_op, g_dense, c_mat, omega_f2, a_work, dyn_work, rhs_work, v1b);
        for (v1b_cim, v1b[n..]) |*c, v| c.* = -v;
    }

    var sw = options.sweep.iter();
    var k: usize = 0;
    while (sw.next()) |f| : (k += 1) {
        if (k != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = k, .total = freqs.len });
        const omega = 2.0 * std.math.pi * f;

        // 3a. First order: (G + jwC) V1 = ½ mag · e[drive row].
        dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, omega, a_work);
        ckt.addAcDynDense(x_op, omega, a_work, dyn_work);

        simdZero(rhs_work);
        if (options.drive_branch != root.GROUND) {
            // V card: its own branch row (cktdisto.c:115-116).
            rhs_work[options.drive_branch] = drive_re;
            rhs_work[n + options.drive_branch] = drive_im;
        } else {
            // I card: current into the node, so the row is negated
            // (cktdisto.c:151-158, ISRCposNode gets −0.5·mag).
            rhs_work[options.ac_source_node] = -drive_re;
            rhs_work[n + options.ac_source_node] = -drive_im;
        }

        try dense_lu.factorizeSolve(nn, a_work, rhs_work, x_work);

        // 3b. Second-order rhs, -½ K''(2w)[V1, V1]. The ½ is ngspice's:
        // `g2 = 0.5 * gd / vte` is ½·d²I/dV² (diodset.c:78) and D1n2F1
        // contributes `g2 * V1²` (dloadfns.c:545). The full double sum
        // already carries both (a,b) and (b,a), so the factor appears once.
        const omega2 = 2.0 * omega;
        bilinear(terms, row_start, v1_re, v1_im, v1_re, v1_im, -0.5, omega2, rhs_work);

        // 3c. Second order: (G + j·2w·C) V2 = -½ K''(V1,V1).
        dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, omega2, a_work);
        ckt.addAcDynDense(x_op, omega2, a_work, dyn_work);

        try dense_lu.factorizeSolve(nn, a_work, rhs_work, x_work2);

        // 3d. Third order, only when h3 is wanted. The 3f1 current is
        // K''(V1,V2) + ⅙·K'''(V1,V1,V1) at 3w: the 2f1·f1 beat through the
        // quadratic kernel plus the direct cube.
        if (want_h3) {
            const d3v = cubicForms(ckt, x_op, v1_re, v1_im, cubic_step, 3.0 * omega, gc0, g_pert, g_minus, x_pert, cubic);
            bilinear(terms, row_start, v1_re, v1_im, v2_re, v2_im, -1, 3.0 * omega, rhs_work);
            for (rhs_work[0..n], rhs_work[n..], d3v[0], d3v[1]) |*re, *im, d_re, d_im| {
                re.* -= d_re / 6.0;
                im.* -= d_im / 6.0;
            }
            dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, 3.0 * omega, a_work);
            ckt.addAcDynDense(x_op, 3.0 * omega, a_work, dyn_work);
            try dense_lu.factorizeSolve(nn, a_work, rhs_work, x_work3);
        }

        // 3e. Two tones. The one-sided phasor of ½K''(x,x) at w1+w2 is
        // K''(V1a, V1b), at w1-w2 K''(V1a, V1b*): the cross term of the
        // square counts both orders. At 2w1-w2 the third-order current is
        // K''(V1a, V2(w1-w2)) + K''(V1b*, V2(2w1)) + ½·K'''(V1a, V1a, V1b*),
        // the multinomial 3 of (w1, w1, -w2) over ⅙, every K at 2w1-w2.
        if (two_tone) {
            const w1pw2 = omega + omega_f2;
            const w1mw2 = omega - omega_f2;
            const v1b_re = v1b[0..n];
            if (out.f1pf2.len != 0) {
                bilinear(terms, row_start, v1_re, v1_im, v1b_re, v1b[n..], -1, w1pw2, rhs_work);
                try solveAt(ckt, x_op, g_dense, c_mat, w1pw2, a_work, dyn_work, rhs_work, x_im);
                scatter(out.f1pf2, k, out.probes, x_im);
            }
            if (out.f1mf2.len != 0 or want_im3) {
                bilinear(terms, row_start, v1_re, v1_im, v1b_re, v1b_cim, -1, w1mw2, rhs_work);
                try solveAt(ckt, x_op, g_dense, c_mat, w1mw2, a_work, dyn_work, rhs_work, v2m);
                if (out.f1mf2.len != 0) scatter(out.f1mf2, k, out.probes, v2m);
            }
            if (want_im3) {
                const w_im3 = 2.0 * omega - omega_f2;
                bilinear(terms, row_start, v1_re, v1_im, v2m[0..n], v2m[n..], -1, w_im3, rhs_work);
                bilinear(terms, row_start, v1b_re, v1b_cim, v2_re, v2_im, -1, w_im3, t3);
                for (rhs_work, t3) |*r, t| r.* += t;
                mixedCubic(ckt, x_op, v1_re, v1_im, v1b_re, v1b_cim, cubic_step, w_im3, gc0, g_pert, g_minus, m_planes, x_pert, t3);
                for (rhs_work, t3) |*r, t| r.* -= 0.5 * t;
                try solveAt(ckt, x_op, g_dense, c_mat, w_im3, a_work, dyn_work, rhs_work, x_im);
                scatter(out.twof1mf2, k, out.probes, x_im);
            }
        }

        // 3f. HD2 = |V2[output]| / |V1[output]|.
        const out_row = options.output_node;
        const v1_out_re = v1_re[out_row];
        const v1_out_im = v1_im[out_row];
        const v1_out_mag = @sqrt(v1_out_re * v1_out_re + v1_out_im * v1_out_im);

        const v2_out_re = v2_re[out_row];
        const v2_out_im = v2_im[out_row];
        const v2_out_mag = @sqrt(v2_out_re * v2_out_re + v2_out_im * v2_out_im);

        const hd2_val = if (v1_out_mag > 1e-30) v2_out_mag / v1_out_mag else 0;

        freqs[k] = f;
        hd2[k] = hd2_val;
        // The summary magnitudes are the half-amplitude kernels as solved,
        // with no DkerProc ×2: `disto/linear_divider_0p01`, a 0.75 divider on
        // `DISTOF1 0.01`, wants 3.75e-3 = ½·0.01·0.75.
        v1_mag[k] = v1_out_mag;
        v2_mag[k] = v2_out_mag;

        // ngspice's own product: the harmonic vector at every probe, as a
        // sinusoid amplitude (DkerProc).
        const stride = out.probes.len * 2;
        for (out.probes, 0..) |row, i| {
            if (want_h2) {
                out.h2[k * stride + i * 2] = HARMONIC_SCALE * v2_re[row];
                out.h2[k * stride + i * 2 + 1] = HARMONIC_SCALE * v2_im[row];
            }
            if (want_h3) {
                out.h3[k * stride + i * 2] = HARMONIC_SCALE * x_work3[row];
                out.h3[k * stride + i * 2 + 1] = HARMONIC_SCALE * x_work3[n + row];
            }
        }
    }

    // The third-order kernels perturb the planes at every point.
    if (want_h3 or want_im3) ckt.eval(x_op, 0);
}

/// Solves A(ω)·x = rhs, A = G + jωC plus the circuit's frequency-dependent
/// entries at x_op, in the stacked-real form (`a_work` is its 2n·2n slab).
fn solveAt(ckt: *root.Circuit, x_op: []const f64, g_dense: []const f64, c_mat: []const f64, omega: f64, a_work: []f64, dyn_work: []f64, rhs: []const f64, x: []f64) !void {
    const n: usize = ckt.n;
    dense_lu.buildComplexAdmittance(n, 2 * n, g_dense, c_mat, omega, a_work);
    ckt.addAcDynDense(x_op, omega, a_work, dyn_work);
    try dense_lu.factorizeSolve(2 * n, a_work, rhs, x);
}

/// One nonzero of the second-order kernels: d²F[row]/dx_a dx_b (`coeff`)
/// and d²Q[row]/dx_a dx_b (`qcoeff`).
const Term = struct { row: u32, a: u32, b: u32, coeff: f64, qcoeff: f64 };

/// dst (stacked 2n) := scale·(F''(a, b) + jω·Q''(a, b)), the complex
/// bilinear form of the second-order kernels `terms` (rows `row_start`) on
/// phasors a and b given as real and imaginary parts, for a product at ω.
fn bilinear(terms: []const Term, row_start: []const u32, a_re: []const f64, a_im: []const f64, b_re: []const f64, b_im: []const f64, scale: f64, omega: f64, dst: []f64) void {
    const n = a_re.len;
    for (0..n) |row| {
        var re: f64 = 0;
        var im: f64 = 0;
        var q_re: f64 = 0;
        var q_im: f64 = 0;
        for (terms[row_start[row]..row_start[row + 1]]) |t| {
            const p_re = a_re[t.a] * b_re[t.b] - a_im[t.a] * b_im[t.b];
            const p_im = a_re[t.a] * b_im[t.b] + a_im[t.a] * b_re[t.b];
            re += t.coeff * p_re;
            im += t.coeff * p_im;
            q_re += t.qcoeff * p_re;
            q_im += t.qcoeff * p_im;
        }
        dst[row] = scale * (re - omega * q_im);
        dst[n + row] = scale * (im + omega * q_re);
    }
}

/// Point k's row of a harmonic plot (`Out.h2` layout): the stacked 2n
/// solution `x` at every probe, as a sinusoid amplitude.
fn scatter(dst: []f64, k: usize, probes: []const u32, x: []const f64) void {
    const n = x.len / 2;
    for (probes, 0..) |row, i| {
        dst[(k * probes.len + i) * 2] = HARMONIC_SCALE * x[row];
        dst[(k * probes.len + i) * 2 + 1] = HARMONIC_SCALE * x[n + row];
    }
}

/// `dst` (stacked 2n) := K'''(a, a, c) = F'''(a, a, c) + jω·Q'''(a, a, c)
/// for complex a = p + jq and c, without forming d3. With S(u) the second
/// difference of the Jacobians along u (`secondDirDeriv`, scaled back from a
/// unit direction), for each of F and Q
///   d3(a, a, c) = (S(p) - S(q))·c + j·(S(p+q) - S(p) - S(q))·c,
/// the second term being 2·d3(p, q, ·) by polarization. Twelve evals.
/// `gc0` is the G/C pair at x_op (2n·n), `planes` 4n·n scratch,
/// `g_work`/`g_tap` 2n·n, `x_work` n.
fn mixedCubic(
    ckt: *root.Circuit,
    x_op: []const f64,
    p: []const f64,
    q: []const f64,
    c_re: []const f64,
    c_im: []const f64,
    h: f64,
    omega: f64,
    gc0: []const f64,
    g_work: []f64,
    g_tap: []f64,
    planes: []f64,
    x_work: []f64,
    dst: []f64,
) void {
    const n = p.len;
    const n2 = n * n;
    const m1 = planes[0 .. 2 * n2];
    const m2 = planes[2 * n2 ..][0 .. 2 * n2];
    simdZero(planes);
    // (direction, weight into m1, weight into m2); p + q goes through x_work's tail.
    const sum = dst[0..n];
    for (sum, p, q) |*s, a, b| s.* = a + b;
    const dirs = [_]struct { []const f64, f64, f64 }{ .{ p, 1, -1 }, .{ q, -1, -1 }, .{ sum, 0, 1 } };
    for (dirs) |d| {
        const nrm = norm(d[0]);
        if (nrm == 0) continue;
        secondDirDeriv(ckt, x_op, d[0], 1.0 / nrm, h, gc0, g_work, g_tap, x_work);
        const s2 = nrm * nrm;
        for (m1, m2, g_work) |*a, *b, g| {
            a.* += d[1] * s2 * g;
            b.* += d[2] * s2 * g;
        }
    }
    // Per plane Re = m1·c_re - m2·c_im, Im = m1·c_im + m2·c_re; then F + jω·Q.
    for (0..n) |row| {
        var acc: [2][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 } };
        for (&acc, 0..) |*plane, k| {
            const off = k * n2 + row * n;
            for (m1[off..][0..n], m2[off..][0..n], c_re, c_im) |a, b, cr, ci| {
                plane[0] += a * cr - b * ci;
                plane[1] += a * ci + b * cr;
            }
        }
        dst[row] = acc[0][0] - omega * acc[1][1];
        dst[n + row] = acc[0][1] + omega * acc[1][0];
    }
}

/// Step of the third-order kernel's second difference, along a unit
/// direction (volts, for the node rows that dominate V1). It is not
/// `fd_eps`: a second difference loses ε·|G|/h² to roundoff, and V1 is often
/// dominated by a nearly linear output node, so the controlling voltage of
/// the nonlinearity moves only a fraction of h. At h = 1e-6 that left the
/// BJT common-emitter HD3 as roundoff, moving 1.5% for a 1e-5 K temperature
/// change (disto/bench_disto_bjt_ce). The fourth-order stencil keeps the
/// truncation at (h/Vt)^4/90, 2.4e-8 relative for an exponential at 1e-3 V;
/// that deck's HD3 is flat to four digits for h from 1e-4 to 1e-2.
const cubic_step: f64 = 1e-3;

/// The harmonic plots report the sinusoid amplitude, twice the one-sided
/// phasor the Volterra recursion solves for (DkerProc, dkerproc.c:43-52).
/// The summary plot does not apply it.
const HARMONIC_SCALE: f64 = 2.0;

/// `K'''(V1, V1, V1)` at ω, F''' + jω·Q''', without forming d3, returned as
/// `.{ re, im }`, each an n-vector aliasing `cubic`.
///
/// It is a directional second difference of the analytic Jacobians: for a
/// unit direction u, with G(k) = G(x + k·h·u),
///   S(u)[row,a] = (16(G(1) + G(−1)) − (G(2) + G(−2)) − 30G(0))[row,a] / 12h²
///               = d3[row,a,·,·](u,u) + O(h⁴)
/// and the cubic form T(w,u,u)[row] = Σ_a w[a]·S(u)[row,a] by symmetry of d3,
/// likewise for C. With V1 = p + jq that is eight evals, S(p̂) and S(q̂), and
/// per plane
///   A = T(p,p,p) − 3T(p,q,q),  B = 3T(p,p,q) − T(q,q,q),
/// so F'''(V1,V1,V1) = A_F + jB_F and the charge part adds jω(A_Q + jB_Q).
/// `gc0` is the G/C pair at x_op (2n·n), `g_work`/`g_minus` 2n·n scratch,
/// `x_work` n scratch, `cubic` 8n.
fn cubicForms(
    ckt: *root.Circuit,
    x_op: []const f64,
    p: []const f64,
    q: []const f64,
    h: f64,
    omega: f64,
    gc0: []const f64,
    g_work: []f64,
    g_minus: []f64,
    x_work: []f64,
    cubic: []f64,
) [2][]const f64 {
    const n = p.len;
    const n2 = n * n;
    simdZero(cubic);

    // cubic[k·4n ..] holds plane k's T(p,p,p), T(p,q,q), T(p,p,q), T(q,q,q).
    const norm_p = norm(p);
    const norm_q = norm(q);
    if (norm_p > 0) {
        secondDirDeriv(ckt, x_op, p, 1.0 / norm_p, h, gc0, g_work, g_minus, x_work);
        for (0..2) |k| {
            const t = cubic[k * 4 * n ..];
            contract(g_work[k * n2 ..][0..n2], p, 1.0 / norm_p, t[0..n]);
            if (norm_q > 0) contract(g_work[k * n2 ..][0..n2], q, 1.0 / norm_q, t[2 * n ..][0..n]);
        }
    }
    if (norm_q > 0) {
        secondDirDeriv(ckt, x_op, q, 1.0 / norm_q, h, gc0, g_work, g_minus, x_work);
        for (0..2) |k| {
            const t = cubic[k * 4 * n ..];
            contract(g_work[k * n2 ..][0..n2], q, 1.0 / norm_q, t[3 * n ..][0..n]);
            if (norm_p > 0) contract(g_work[k * n2 ..][0..n2], p, 1.0 / norm_p, t[n..][0..n]);
        }
    }

    // Undo the unit-direction normalization: every form is cubic in its inputs.
    const ppp = norm_p * norm_p * norm_p;
    const pqq = norm_p * norm_q * norm_q;
    const ppq = norm_p * norm_p * norm_q;
    const qqq = norm_q * norm_q * norm_q;
    for (0..n) |row| {
        var ab: [2][2]f64 = undefined;
        for (&ab, 0..) |*plane, k| {
            const t = cubic[k * 4 * n ..];
            plane.* = .{
                ppp * t[row] - 3.0 * pqq * t[n + row],
                3.0 * ppq * t[2 * n + row] - qqq * t[3 * n + row],
            };
        }
        cubic[row] = ab[0][0] - omega * ab[1][1];
        cubic[n + row] = ab[0][1] + omega * ab[1][0];
    }
    return .{ cubic[0..n], cubic[n .. 2 * n] };
}

fn norm(v: []const f64) f64 {
    var acc: f64 = 0;
    for (v) |x| acc += x * x;
    return @sqrt(acc);
}

/// g_out := the second derivative of the G/C pair (2n·n, G first) along
/// `scale·u` at x_op, by the five-point stencil in `cubicForms`. `g0` is the
/// pair at x_op.
fn secondDirDeriv(
    ckt: *root.Circuit,
    x_op: []const f64,
    u: []const f64,
    scale: f64,
    h: f64,
    g0: []const f64,
    g_out: []f64,
    g_tap: []f64,
    x_work: []f64,
) void {
    const n = u.len;
    const n2 = n * n;
    // (k, weight) of the stencil's off-centre points.
    const taps = [_]struct { f64, f64 }{ .{ 1, 16 }, .{ -1, 16 }, .{ 2, -1 }, .{ -2, -1 } };
    for (g_out[0..n2], g0[0..n2]) |*out, plane| out.* = -30.0 * plane;
    simdZero(g_out[n2..]);
    for (taps) |tap| {
        const step = tap[0] * h * scale;
        simdCopy(x_work, x_op[0..n]);
        for (0..n) |i| x_work[i] += step * u[i];
        ckt.eval(x_work, 0);
        ckt.denseG(g_tap[0..n2]);
        ckt.denseC(g_tap[n2..]);
        for (g_out[0..n2], g_tap[0..n2]) |*out, g| out.* += tap[1] * g;
        // C as differences from C(0): exactly zero for a linear capacitor.
        for (g_out[n2..], g_tap[n2..], g0[n2..]) |*out, c, c0| out.* += tap[1] * (c - c0);
    }
    const inv = 1.0 / (12.0 * h * h);
    for (g_out) |*out| out.* *= inv;
}

/// dst[row] := (Σ_a s[row·n + a] · w[a]) · scale.
fn contract(s: []const f64, w: []const f64, scale: f64, dst: []f64) void {
    const n = w.len;
    for (dst, 0..) |*d, row| {
        var acc: f64 = 0;
        const s_row = s[row * n ..][0..n];
        for (s_row, w) |sv, wv| acc += sv * wv;
        d.* = acc * scale;
    }
}

/// Contract entry: drive the `DISTOF1` card's branch (opts.drive_branch,
/// resolved from the deck) and measure at opts.output_node.
///
/// One `.disto` card publishes three plots, one query each (`opts.plot`):
/// ngspice's `DISTORTION - 2nd harmonic` and `- 3rd harmonic`, complex and
/// point-major (frequency, probes...), and espice's `Distortion Analysis`
/// summary, real and point-major (frequency, hd2, v1_mag, v2_mag).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;

    var o = opts;
    // ponytail: with no DISTOF1 in the deck ngspice solves an unexcited system
    // and prints zeros; this falls back to the deck's drive source so a
    // card-less `.disto` still reports something. Drop the fallback when a
    // fixture wants ngspice's zeros.
    if (o.drive_branch == root.GROUND and o.ac_source_node == root.GROUND)
        o.drive_branch = ctx.source_branch;

    const n_points: usize = o.sweep.count();
    const scratch = ctx.scratch_allocator;
    const cols = try scratch.alloc(f64, n_points * 4);
    defer scratch.free(cols);
    const freqs = cols[0..n_points];
    const hd2_buf = cols[n_points .. 2 * n_points];
    const v1_buf = cols[2 * n_points .. 3 * n_points];
    const v2_buf = cols[3 * n_points ..];

    var out: Out = .{ .freqs = freqs, .hd2 = hd2_buf, .v1_mag = v1_buf, .v2_mag = v2_buf };
    const harmonic = o.plot != .summary;
    // ponytail: allocated on every path; it is the size of the result plot
    // itself, so branching around it would save nothing measurable.

    const harm_buf = try scratch.alloc(f64, n_points * ctx.probes.len * 2);
    defer scratch.free(harm_buf);
    if (harmonic) {
        out.probes = ctx.probes;
        switch (o.plot) {
            .second => out.h2 = harm_buf,
            .third => out.h3 = harm_buf,
            .f1pf2 => out.f1pf2 = harm_buf,
            .f1mf2 => out.f1mf2 = harm_buf,
            .twof1mf2 => out.twof1mf2 = harm_buf,
            .summary => unreachable,
        }
    }

    try sweep(ctx.circuit, x_op, out, o, scratch);

    if (harmonic) {
        const names = try root.probeNames(ctx, "frequency");
        errdefer {
            for (names[1..]) |s| a.free(s); // names[0] is the "frequency" literal
            a.free(names);
        }
        const ncols = names.len;
        const data = try a.alloc(f64, n_points * ncols * 2);
        for (0..n_points) |i| {
            const row = data[i * ncols * 2 ..][0 .. ncols * 2];
            row[0] = freqs[i];
            row[1] = 0;
            @memcpy(row[2..], harm_buf[i * ctx.probes.len * 2 ..][0 .. ctx.probes.len * 2]);
        }
        return .{
            .plotname = switch (o.plot) {
                .second => "DISTORTION - 2nd harmonic",
                .third => "DISTORTION - 3rd harmonic",
                .f1pf2 => "DISTORTION - IM: f1+f2",
                .f1mf2 => "DISTORTION - IM: f1-f2",
                .twof1mf2 => "DISTORTION - IM: 2f1-f2",
                .summary => unreachable,
            },
            .varnames = names,
            .is_complex = true,
            .npoints = n_points,
            .data = data,
        };
    }

    const names = try a.dupe([]const u8, &.{ "frequency", "hd2", "v1_mag", "v2_mag" });
    errdefer a.free(names); // entries are literals
    const ncols = names.len;
    const data = try a.alloc(f64, n_points * ncols);
    for (0..n_points) |i| {
        const row = data[i * ncols ..][0..ncols];
        row[0] = freqs[i];
        row[1] = hd2_buf[i];
        row[2] = v1_buf[i];
        row[3] = v2_buf[i];
    }

    return .{
        .plotname = "Distortion Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}
