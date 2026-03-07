//! Distortion analysis via simplified Volterra series. One eval() at the
//! operating point yields the analytic G and C planes; the second-order
//! kernel is finite differences OF the analytic Jacobian (d2F = dG/dx),
//! one eval per unknown. Per-frequency solves are dense.
//!
//! The third-order kernel is NOT stored. d3 is O(n^4) and every use of it is
//! the single contraction d3(V1,V1,V1), so it is taken as a directional
//! second difference of the analytic Jacobian along the two real directions
//! V1 spans — four evals per frequency point, no tensor. See `cubicForms`.
//!
//! ponytail: O(n^3) d2 tensor + O(n^2) dense solves; device-side analytic
//! F''/F''' stamps are the scalable upgrade for large n.
const std = @import("std");
const root = @import("../types.zig");
const simdZero = root.zeroSimd;
const simdCopy = root.copySimd;
const types = @import("numerics");
const solvers = @import("solvers");
const dense_lu = solvers.dense_lu;

pub const Options = @import("requests").Disto;

/// Everything one sweep can deposit. The four summary columns are always
/// written, one value per frequency point. `h2`/`h3` are ngspice's own
/// output product: the whole second- and third-harmonic SOLUTION VECTOR
/// sampled at `probes`, point-major with (re, im) adjacent — leave them
/// empty and the matching order is not computed at all.
pub const Out = struct {
    freqs: []f64,
    hd2: []f64,
    v1_mag: []f64,
    v2_mag: []f64,
    probes: []const u32 = &.{},
    h2: []f64 = &.{},
    h3: []f64 = &.{},
};

/// Distortion analysis via simplified Volterra series.
///
/// Computes the harmonic responses across a frequency sweep:
///   1. Linearize at the DC operating point: one eval(), dense G and C.
///   2. Second-order kernel d2F/dxa dxb = dG[.,a]/dx_b by differencing the
///      analytic Jacobian at n perturbed points (first derivatives are
///      analytic; only the extra order is FD).
///   3. For each frequency f:
///      a. Solve first-order: (G + jwC) * V1 = excitation
///      b. Second-order nonlinear current ½ F''(V1, V1) from the kernel
///      c. Solve second-order: (G + j*2w*C) * V2 = -½ F''(V1, V1)
///      d. HD2 = |V2[output]| / |V1[output]|
///      e. Third order, only when asked for: the 3f1 current is
///         F''(V1, V2) + ⅙·F'''(V1, V1, V1), and
///         (G + j*3w*C) * V3 = -that.
///
/// PHASOR CONVENTION, ngspice's throughout: the drive is HALF the sinusoid
/// amplitude (cktdisto.c:115) and every kernel is a one-sided phasor, so the
/// 2f1 source term is ½·F''·V1² — ngspice spells the ½ into the device
/// coefficient (`g2 = 0.5 * gd / vte`, diodset.c:78) and contributes
/// `g2 * V1²` (dloadfns.c:545 D1n2F1). The harmonic VECTORS are reported back
/// as sinusoid amplitudes, i.e. ×2 — that is DkerProc (dkerproc.c:43-52) and
/// `HARMONIC_SCALE` below. The summary columns are not rescaled; see the
/// comment on `v1_mag`.
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

    // -- Step 1: Linearize at DC operating point (analytic planes) --
    ckt.eval(x_op, 0);

    const g_dense = try allocator.alloc(f64, n * n);
    defer allocator.free(g_dense);
    ckt.denseG(g_dense);

    const c_mat = try allocator.alloc(f64, n * n);
    defer allocator.free(c_mat);
    ckt.denseC(c_mat);

    // -- Step 2: Second derivatives = FD of the analytic Jacobian --
    // d2[row][a][b] ≈ (G(x_op + eps*e_b) − G(x_op))[row][a] / eps
    const eps = options.fd_eps;
    const inv_eps = 1.0 / eps;
    const d2 = try allocator.alloc(f64, n * n * n);
    defer allocator.free(d2);

    const g_pert = try allocator.alloc(f64, n * n);
    defer allocator.free(g_pert);
    const x_pert = try allocator.alloc(f64, n);
    defer allocator.free(x_pert);

    // ponytail: strided tensor layout d2[row*n*n + a*n + b] prevents contiguous
    // SIMD on the inner (a) loop; scalar per element, n evals dominate cost anyway
    for (0..n) |b| {
        if (b != 0) try ckt.checkpoint(.{ .phase = .prepare, .completed = b, .total = n });
        simdCopy(x_pert, x_op[0..n]);
        x_pert[b] += eps;
        ckt.eval(x_pert, 0);
        ckt.denseG(g_pert);
        for (0..n) |row| {
            for (0..n) |a| {
                d2[row * n * n + a * n + b] =
                    (g_pert[row * n + a] - g_dense[row * n + a]) * inv_eps;
            }
        }
    }

    // Leave the planes consistent with the operating point
    ckt.eval(x_op, 0);

    // -- Step 3: Frequency sweep --
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

    // Third-order scratch: one more dense Jacobian plus the four real cubic
    // forms of `cubicForms`. Both are O(n^2) or smaller next to d2's O(n^3),
    // so they are allocated unconditionally rather than branched around.
    const g_minus = try allocator.alloc(f64, n * n);
    defer allocator.free(g_minus);
    const cubic = try allocator.alloc(f64, 4 * n);
    defer allocator.free(cubic);

    const v1_re = x_work[0..n];
    const v1_im = x_work[n..nn];
    const v2_re = x_work2[0..n];
    const v2_im = x_work2[n..nn];

    // ngspice cktdisto.c:115-116 — HALF amplitude: the F1 drive is the
    // one-sided phasor of a cosine of amplitude `ac_magnitude`.
    const phase_rad = options.ac_phase * std.math.pi / 180.0;
    const drive_re = 0.5 * options.ac_magnitude * @cos(phase_rad);
    const drive_im = 0.5 * options.ac_magnitude * @sin(phase_rad);

    var sw = options.sweep.iter();
    var k: usize = 0;
    while (sw.next()) |f| : (k += 1) {
        if (k != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = k, .total = freqs.len });
        const omega = 2.0 * std.math.pi * f;

        // -- 3a: First-order solve: (G + jwC) * V1 = ½ mag * e[drive row] --
        dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, omega, a_work);

        simdZero(rhs_work);
        if (options.drive_branch != root.GROUND) {
            // V card: its own branch row (cktdisto.c:115-116).
            rhs_work[options.drive_branch] = drive_re;
            rhs_work[n + options.drive_branch] = drive_im;
        } else {
            // I card: current INTO the node, so the row is negated
            // (cktdisto.c:151-158, ISRCposNode gets −0.5·mag).
            rhs_work[options.ac_source_node] = -drive_re;
            rhs_work[n + options.ac_source_node] = -drive_im;
        }

        try dense_lu.factorizeSolve(nn, a_work, rhs_work, x_work);

        // -- 3b: Build second-order RHS: -½ F''[V1, V1] --
        // D2[row] = sum_ab d2[row,a,b] * V1[a] * V1[b]  (complex product).
        // The ½ is ngspice's: `g2 = 0.5 * gd / vte` is exactly ½·d²I/dV²
        // (diodset.c:78), and D1n2F1 contributes `g2 * V1²` (dloadfns.c:545).
        // The full double sum already carries both (a,b) and (b,a), so the
        // factor belongs here once.
        for (0..n) |row| {
            var d2_re: f64 = 0;
            var d2_im: f64 = 0;
            for (0..n) |a| {
                for (0..n) |b_idx| {
                    const coeff = d2[row * n * n + a * n + b_idx];
                    if (coeff == 0) continue;
                    // Complex product: V1[a] * V1[b]
                    const prod_re = v1_re[a] * v1_re[b_idx] - v1_im[a] * v1_im[b_idx];
                    const prod_im = v1_re[a] * v1_im[b_idx] + v1_im[a] * v1_re[b_idx];
                    d2_re += coeff * prod_re;
                    d2_im += coeff * prod_im;
                }
            }
            rhs_work[row] = -0.5 * d2_re;
            rhs_work[n + row] = -0.5 * d2_im;
        }

        // -- 3c: Solve second-order: (G + j*2w*C) * V2 = -D2(V1,V1) --
        const omega2 = 2.0 * omega;
        dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, omega2, a_work);

        try dense_lu.factorizeSolve(nn, a_work, rhs_work, x_work2);

        // -- 3d: Third order, only when a third-harmonic column was asked for.
        // The 3f1 current is F''(V1,V2) + ⅙·F'''(V1,V1,V1): the 2f1·f1 beat
        // through the quadratic kernel plus the direct cube. F'' is the stored
        // d2; F''' is never stored (see `cubicForms`).
        if (want_h3) {
            const d3v = cubicForms(ckt, x_op, v1_re, v1_im, eps, g_dense, g_pert, g_minus, x_pert, cubic);
            for (0..n) |row| {
                var m_re: f64 = 0;
                var m_im: f64 = 0;
                for (0..n) |a| {
                    for (0..n) |b_idx| {
                        const coeff = d2[row * n * n + a * n + b_idx];
                        if (coeff == 0) continue;
                        m_re += coeff * (v1_re[a] * v2_re[b_idx] - v1_im[a] * v2_im[b_idx]);
                        m_im += coeff * (v1_re[a] * v2_im[b_idx] + v1_im[a] * v2_re[b_idx]);
                    }
                }
                rhs_work[row] = -(m_re + d3v[0][row] / 6.0);
                rhs_work[n + row] = -(m_im + d3v[1][row] / 6.0);
            }
            dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, 3.0 * omega, a_work);
            try dense_lu.factorizeSolve(nn, a_work, rhs_work, x_work3);
        }

        // -- 3e: Compute HD2 = |V2[output]| / |V1[output]| --
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
        // The printed magnitudes are the HALF-AMPLITUDE kernels, exactly as
        // solved: the F1 drive is ½·DISTOF1 on the branch row and what comes
        // out of the output node is what gets printed. An earlier ×2 here
        // cited DkerProc's rescale, but the oracles say otherwise and say it
        // unambiguously — `disto/linear_divider_0p01` is a plain 0.75 divider
        // on `DISTOF1 0.01` and wants 3.75e-3, i.e. ½·0.01·0.75. hd2 is a
        // ratio and was right either way, which is how the factor survived.
        v1_mag[k] = v1_out_mag;
        v2_mag[k] = v2_out_mag;

        // ngspice's own product: the harmonic vector at every probe, rescaled
        // from the one-sided kernel to the sinusoid amplitude (DkerProc).
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

    // Leave the planes consistent with the operating point: the third-order
    // kernel perturbs them once per frequency point.
    if (want_h3) ckt.eval(x_op, 0);
}

/// DkerProc (ngspice dkerproc.c:43-52): the harmonic plots report the SINUSOID
/// amplitude, which is twice the one-sided phasor the Volterra recursion
/// solves for. The summary plot deliberately does not apply it (see `v1_mag`).
const HARMONIC_SCALE: f64 = 2.0;

/// `d3(V1, V1, V1)` without ever forming d3 — returned as `.{ re, im }`,
/// each an n-vector aliasing `cubic`.
///
/// d3 is O(n^4) and the only thing it is ever used for is this one
/// contraction, so it is taken as a directional second difference of the
/// analytic Jacobian: for a unit direction u,
///   S(u)[row,a] = (G(x+h·u) − 2G(x) + G(x−h·u))[row,a] / h²  =  d3[row,a,·,·](u,u)
/// and the cubic form T(w,u,u)[row] = Σ_a w[a]·S(u)[row,a] by symmetry of d3.
/// With V1 = p + jq that is four evals — S(p̂) and S(q̂) — and
///   Re = T(p,p,p) − 3T(p,q,q),  Im = 3T(p,p,q) − T(q,q,q).
/// `g_work`/`g_minus` are n·n scratch, `x_work` is n scratch, `cubic` is 4n.
fn cubicForms(
    ckt: *root.Circuit,
    x_op: []const f64,
    p: []const f64,
    q: []const f64,
    h: f64,
    g0: []const f64,
    g_work: []f64,
    g_minus: []f64,
    x_work: []f64,
    cubic: []f64,
) [2][]const f64 {
    const n = p.len;
    const t_ppp = cubic[0..n];
    const t_pqq = cubic[n .. 2 * n];
    const t_ppq = cubic[2 * n .. 3 * n];
    const t_qqq = cubic[3 * n ..];
    simdZero(cubic);

    const norm_p = norm(p);
    const norm_q = norm(q);
    if (norm_p > 0) {
        secondDirDeriv(ckt, x_op, p, 1.0 / norm_p, h, g0, g_work, g_minus, x_work);
        contract(g_work, p, 1.0 / norm_p, t_ppp);
        if (norm_q > 0) contract(g_work, q, 1.0 / norm_q, t_ppq);
    }
    if (norm_q > 0) {
        secondDirDeriv(ckt, x_op, q, 1.0 / norm_q, h, g0, g_work, g_minus, x_work);
        contract(g_work, q, 1.0 / norm_q, t_qqq);
        if (norm_p > 0) contract(g_work, p, 1.0 / norm_p, t_pqq);
    }

    // Undo the unit-direction normalization: every form is cubic in its inputs.
    const ppp = norm_p * norm_p * norm_p;
    const pqq = norm_p * norm_q * norm_q;
    const ppq = norm_p * norm_p * norm_q;
    const qqq = norm_q * norm_q * norm_q;
    for (0..n) |row| {
        const re = ppp * t_ppp[row] - 3.0 * pqq * t_pqq[row];
        const im = 3.0 * ppq * t_ppq[row] - qqq * t_qqq[row];
        t_ppp[row] = re;
        t_pqq[row] = im;
    }
    return .{ t_ppp, t_pqq };
}

fn norm(v: []const f64) f64 {
    var acc: f64 = 0;
    for (v) |x| acc += x * x;
    return @sqrt(acc);
}

/// g_out := (G(x_op + h·scale·u) − 2·G(x_op) + G(x_op − h·scale·u)) / h².
fn secondDirDeriv(
    ckt: *root.Circuit,
    x_op: []const f64,
    u: []const f64,
    scale: f64,
    h: f64,
    g0: []const f64,
    g_out: []f64,
    g_minus: []f64,
    x_work: []f64,
) void {
    const n = u.len;
    const step = h * scale;
    simdCopy(x_work, x_op[0..n]);
    for (0..n) |i| x_work[i] += step * u[i];
    ckt.eval(x_work, 0);
    ckt.denseG(g_out);

    simdCopy(x_work, x_op[0..n]);
    for (0..n) |i| x_work[i] -= step * u[i];
    ckt.eval(x_work, 0);
    ckt.denseG(g_minus);

    const inv_h2 = 1.0 / (h * h);
    for (g_out, g0, g_minus) |*out, plane, minus| out.* = (out.* - 2.0 * plane + minus) * inv_h2;
}

/// dst[row] := Σ_a (scale·w[a]) · s[row·n + a].
fn contract(s: []const f64, w: []const f64, scale: f64, dst: []f64) void {
    const n = w.len;
    for (dst, 0..) |*d, row| {
        var acc: f64 = 0;
        const s_row = s[row * n ..][0..n];
        for (s_row, w) |sv, wv| acc += sv * wv;
        d.* = acc * scale;
    }
}

/// Contract entry: drive the branch of the `DISTOF1` card (opts.drive_branch,
/// resolved from the deck by the engine), measure at opts.output_node (or the
/// last probe).
///
/// One `.disto` card publishes three plots, one query each (`opts.plot`):
/// ngspice's `DISTORTION - 2nd harmonic` and `- 3rd harmonic`, complex and
/// point-major (frequency, probes...); and espice's `Distortion Analysis`
/// digest, real and point-major (frequency, hd2, v1_mag, v2_mag).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    var o = opts;
    // No DISTOF1 anywhere in the deck: ngspice would solve an unexcited system
    // and print zeros. ponytail: fall back to the deck's drive source instead,
    // so a card-less `.disto` still reports something; drop the fallback the
    // day a fixture wants ngspice's literal zeros.
    if (o.drive_branch == root.GROUND and o.ac_source_node == root.GROUND)
        o.drive_branch = ctx.source_branch;
    if (o.output_node == root.GROUND) {
        if (ctx.probes.len == 0) return error.NoProbes;
        o.output_node = ctx.probes[ctx.probes.len - 1];
    }

    const n_points: usize = o.sweep.count();
    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    // One flat block, four columns
    const cols = try scratch.alloc(f64, n_points * 4);
    defer scratch.free(cols);
    const freqs = cols[0..n_points];
    const hd2_buf = cols[n_points .. 2 * n_points];
    const v1_buf = cols[2 * n_points .. 3 * n_points];
    const v2_buf = cols[3 * n_points ..];

    var out: Out = .{ .freqs = freqs, .hd2 = hd2_buf, .v1_mag = v1_buf, .v2_mag = v2_buf };
    const harmonic = o.plot != .summary;
    // ponytail: allocated on every path; n_points·probes·2 is the size of the
    // result plot itself, so branching around it would save nothing measurable.
    const harm_buf = try scratch.alloc(f64, n_points * ctx.probes.len * 2);
    defer scratch.free(harm_buf);
    if (harmonic) {
        out.probes = ctx.probes;
        switch (o.plot) {
            .second => out.h2 = harm_buf,
            .third => out.h3 = harm_buf,
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
            .plotname = if (o.plot == .second) "DISTORTION - 2nd harmonic" else "DISTORTION - 3rd harmonic",
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
