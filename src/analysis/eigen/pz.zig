//! Pole-zero analysis. Both halves are one question asked of two matrices:
//! the finite roots of det(G + sC) = 0.
//!
//! POLES are that pencil on the circuit's own MNA. Independent sources are
//! nulled in a linearization, so a deck's input VOLTAGE source is already the
//! short a `vol` denominator wants and its current source is already the open
//! a `cur` denominator wants — the mode word changes nothing here, and a bare
//! `.pz` gets exactly the same answer it always did.
//!
//! ZEROS are the same pencil with the OUTPUT column replaced by the input
//! drive. H(s) = e_outᵀ Y⁻¹ d, so by Cramer's rule that determinant is H's
//! NUMERATOR and its roots are the transfer zeros. It is the determinant
//! [[Y, d], [e_outᵀ, 0]] — "input and output roles exchanged" — written as a
//! column swap instead of a border, which leaves the C plane structurally
//! emptier: a grounded output capacitor drops OUT of the pencil rather than
//! surviving as a spurious root.
//!
//! Roots come from the eigenvalues λ of A = −M⁻¹C with M = G + σC, which are
//! λ = 1/(s − σ). Dense Hessenberg + Francis double-shift QR.
//! The planes are the linearization — one eval() at the op.
const std = @import("std");
const root = @import("../types.zig");
const types = @import("numerics");
const solvers = @import("solvers");
const dense_lu = solvers.dense_lu;

const Complex = types.Complex;
const GROUND = root.GROUND;

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = @import("requests").Pz;

pub const Roots = struct {
    poles: []Complex,
    zeros: []Complex,
    n_stable: u32,
    /// False if the QR iteration hit qr_max_iter before deflating every
    /// eigenvalue — the root list is then incomplete.
    qr_converged: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Roots) void {
        self.allocator.free(self.poles);
        self.allocator.free(self.zeros);
    }
};

/// One pencil solve's working set: n×n planes plus the vectors the
/// back-substitution and the eigenvalue list need, all off one allocation.
/// `g`/`c` are the pencil itself and both get REWRITTEN in place when the
/// zeros pass re-points them at the numerator.
const Work = struct {
    n: usize,
    g: []f64,
    c: []f64,
    /// M = G + σC, overwritten with its LU.
    m: []f64,
    /// A = −M⁻¹C, destroyed by the QR.
    a: []f64,
    /// Matrix powers for `coreRank`; empty when no zeros were asked for.
    p: []f64,
    col: []f64,
    sol: []f64,
    piv: []u32,
    eigs: []Complex,
};

/// Poles (and, when the directive asked for them, transfer zeros) at a
/// precomputed operating point x_op, in rad/s. Returns error.Singular when the
/// circuit's own G is singular (pure-C node).
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Roots {
    const n: usize = ckt.n;

    // Linearize: one eval fills the G and C planes (ground row included).
    try ckt.linearizeAc(x_op);

    // ponytail: one bulk alloc for all f64 work buffers
    const planes: usize = if (options.want_zeros) 5 else 4;
    const arena = try allocator.alloc(f64, planes * n * n + 2 * n);
    defer allocator.free(arena);
    const piv = try allocator.alloc(u32, n);
    defer allocator.free(piv);
    // At most n eigenvalues — exact upper bound, no growth.
    const eigs = try allocator.alloc(Complex, n);
    defer allocator.free(eigs);

    var w: Work = .{
        .n = n,
        .g = arena[0 .. n * n],
        .c = arena[n * n .. 2 * n * n],
        .m = arena[2 * n * n .. 3 * n * n],
        .a = arena[3 * n * n .. 4 * n * n],
        .p = if (options.want_zeros) arena[4 * n * n .. 5 * n * n] else &.{},
        .col = arena[planes * n * n ..][0..n],
        .sol = arena[planes * n * n + n ..][0..n],
        .piv = piv,
        .eigs = eigs,
    };
    ckt.denseG(w.g);
    ckt.denseC(w.c);

    // Denominator. σ = 0 and no rank pre-count: this is the form every bare
    // `.pz` deck was validated against and it stays bit-for-bit that form.
    try shiftedFactor(&w, 0, 0);
    const den = buildA(&w, options);
    if (true) {
        std.debug.print("PZDBG n={d} count={d} conv={}\n", .{ n, den.count, den.converged });
        for (eigs[0..den.count], 0..) |l, i| std.debug.print("  lam[{d}] = {e} {e}\n", .{ i, l.re, l.im });
    }

    // λ → s = 1/λ = conj(λ)/|λ|²; drop |λ| ≈ 0 (no dynamics, not a pole at the
    // origin). The dropped eigenvalues are the rows with NO dynamics —
    // resistive nodes, branch rows — and those are zero to within the QR's
    // backward error, O(n·eps·‖A‖). Anything above that is a real time
    // constant, however small next to the slowest one. A 1e-9 RELATIVE cutoff
    // instead threw away genuine fast poles the moment a deck spanned more
    // than nine decades: `pz/widely_separated_modes` carries τ = 1 ns and
    // τ = 1000 s, and the 1 ns mode sat twelve decades down, so the analysis
    // reported one pole for a two-pole circuit.
    var max_abs: f64 = 0;
    for (eigs[0..den.count]) |l| max_abs = @max(max_abs, l.mag());
    const cutoff = @as(f64, @floatFromInt(n)) * std.math.floatEps(f64) * max_abs;
    var n_poles: usize = 0;
    for (eigs[0..den.count]) |l| {
        if (l.mag() > cutoff and l.magSq() != 0) n_poles += 1;
    }

    // The pole set is built even for `zer`, because it also fixes the
    // frequency scale the zeros' shift ladder is measured in.
    const poles = try allocator.alloc(Complex, if (options.want_poles) n_poles else 0);
    errdefer allocator.free(poles);
    var n_stable: u32 = 0;
    var scale: f64 = 0;
    var kept: usize = 0;
    for (eigs[0..den.count]) |l| {
        const m2 = l.magSq();
        if (l.mag() <= cutoff or m2 == 0) continue;
        const pole = Complex{ .re = l.re / m2, .im = -l.im / m2 };
        if (options.want_poles) poles[kept] = pole;
        kept += 1;
        if (pole.re < 0) n_stable += 1;
        scale = @max(scale, pole.mag());
    }

    var zeros: []Complex = &.{};
    var converged = den.converged;
    if (options.want_zeros) {
        numeratorPencil(&w, options);
        const num = try zeroRoots(&w, options, scale);
        converged = converged and num.converged;
        zeros = try allocator.alloc(Complex, num.count);
        @memcpy(zeros, eigs[0..num.count]);
    }

    return .{
        .poles = poles,
        .zeros = zeros,
        .n_stable = n_stable,
        .qr_converged = converged,
        .allocator = allocator,
    };
}

/// M = G + σC, overwritten with its LU. `min_ratio` > 0 adds a RELATIVE
/// singularity test on top of dense_lu's: dense_lu's own is absolute (eps²,
/// 4.9e-32) because an honest pencil can have honest pivots that small, so a
/// shift that lands on a root of the pencil factors "successfully" and hands
/// back noise. The denominator pass passes 0 and keeps the old behaviour; the
/// numerator pass has a ladder of shifts to fall through and can afford to be
/// strict.
fn shiftedFactor(w: *Work, sigma: f64, min_ratio: f64) !void {
    const n = w.n;
    var scale: f64 = 0;
    for (w.g, w.c, w.m) |gv, cv, *mv| {
        mv.* = gv + sigma * cv;
        scale = @max(scale, @abs(mv.*));
    }
    try dense_lu.factorize(n, w.m, w.piv);
    if (min_ratio == 0) return;
    var min_piv: f64 = std.math.inf(f64);
    for (0..n) |k| min_piv = @min(min_piv, @abs(w.m[k * n + k]));
    if (min_piv <= min_ratio * scale) return error.Singular;
}

/// A = −M⁻¹C, then its eigenvalues into `w.eigs`. One back-substitution per
/// column of C against the LU already in `w.m`.
fn buildA(w: *Work, options: Options) Eigs {
    const n = w.n;
    for (0..n) |j| {
        for (0..n) |r| w.col[r] = w.c[r * n + j];
        dense_lu.solveFactored(n, w.m, w.piv, w.col, w.sol);
        for (0..n) |r| w.a[r * n + j] = -w.sol[r];
    }
    return eigenvaluesQR(n, w.a, w.eigs, options);
}

/// Rewrite (G, C) in place as the transfer NUMERATOR's pencil: the MNA with
/// the output column replaced by the input drive.
///
/// A differential output is one column operation away from a single column:
/// in det [[Y, d], [e_out⁺ᵀ − e_out⁻ᵀ, 0]], adding column out⁺ into column
/// out⁻ cancels the −1 the border row carries there, leaving the +1 at out⁺
/// alone to expand along — and that expansion is the column swap below.
/// GROUND is row 0, the unit clamp `v(0) = 0`, and never takes a stamp.
fn numeratorPencil(w: *Work, o: Options) void {
    const n = w.n;
    if (o.out_neg != GROUND) {
        for (0..n) |r| {
            w.g[r * n + o.out_neg] += w.g[r * n + o.out_pos];
            w.c[r * n + o.out_neg] += w.c[r * n + o.out_pos];
        }
    }
    for (0..n) |r| {
        w.g[r * n + o.out_pos] = 0;
        w.c[r * n + o.out_pos] = 0;
    }
    if (o.drive_branch != GROUND) {
        // `vol`: the input source's branch row is the only row its rhs enters.
        w.g[o.drive_branch * n + o.out_pos] = 1;
    } else {
        // `cur`: a current injected across the input node pair.
        if (o.in_pos != GROUND) w.g[o.in_pos * n + o.out_pos] = 1;
        if (o.in_neg != GROUND) w.g[o.in_neg * n + o.out_pos] = -1;
    }
}

/// Finite roots of the numerator pencil, written over `w.eigs`.
///
/// σ = 0 first: it is exact when G is nonsingular and the most accurate, since
/// s = σ + 1/λ loses |σ|·eps of ABSOLUTE accuracy on roots far below σ. A
/// transfer zero AT the origin — every high-pass has one — makes the numerator
/// singular at s = 0 and is the whole reason the shift exists. The ladder is
/// in units of the POLE magnitude, not ‖G‖/‖C‖: an MNA branch row puts ±1 in
/// G next to picofarads in C, which inflates that ratio by decades past where
/// the roots actually are, and the shift has to stay at the roots' own scale.
fn zeroRoots(w: *Work, options: Options, pole_scale: f64) !Eigs {
    const n = w.n;
    const eps = std.math.floatEps(f64);
    const min_ratio = @as(f64, @floatFromInt(n)) * eps;
    var scale = pole_scale;
    if (!(scale > 0) or !std.math.isFinite(scale)) scale = planeScale(w);
    // A pencil with no C left has no finite roots; nothing to shift towards.
    if (!(scale > 0) or !std.math.isFinite(scale)) return .{ .count = 0, .converged = true };
    const ladder = [_]f64{ 0, 1, -1, 0.37, -2.7, 11.3 };

    var sigma: f64 = 0;
    for (ladder, 0..) |step, attempt| {
        sigma = step * scale;
        shiftedFactor(w, sigma, min_ratio) catch |err| {
            if (err == error.Singular and attempt + 1 < ladder.len) continue;
            return err;
        };
        break;
    }

    const found = buildA(w, options);
    // How many of those eigenvalues are nonzero in exact arithmetic — see
    // coreRank. Everything else is a root at infinity.
    const keep = @min(coreRank(w), found.count);
    // |λ| descending puts the genuine roots first: the spurious ones are the
    // nilpotent block's, and those sit at eps^(1/k)·‖A‖ of zero. A conjugate
    // pair shares a magnitude, so this never splits one.
    std.mem.sort(Complex, w.eigs[0..found.count], {}, struct {
        fn cmp(_: void, x: Complex, y: Complex) bool {
            return x.magSq() > y.magSq();
        }
    }.cmp);
    var kept: usize = 0;
    for (w.eigs[0..keep]) |l| {
        const m2 = l.magSq();
        if (m2 == 0) break;
        w.eigs[kept] = .{ .re = sigma + l.re / m2, .im = -l.im / m2 };
        kept += 1;
    }
    return .{ .count = kept, .converged = found.converged };
}

/// ‖G‖∞ / ‖C‖∞ — the pencil's own frequency scale, used only when there are no
/// poles to take the scale from.
fn planeScale(w: *const Work) f64 {
    var g_max: f64 = 0;
    var c_max: f64 = 0;
    for (w.g, w.c) |gv, cv| {
        g_max = @max(g_max, @abs(gv));
        c_max = @max(c_max, @abs(cv));
    }
    if (c_max == 0) return 0;
    return g_max / c_max;
}

/// How many eigenvalues of `w.a` are nonzero in exact arithmetic.
///
/// The zero eigenvalues of A = −M⁻¹C are the pencil's roots at infinity, and
/// the QR cannot tell them from small genuine ones: a DEFECTIVE zero
/// eigenvalue of multiplicity k comes back at |λ| ≈ ‖A‖·eps^(1/k), which for
/// the commonest k = 2 is 1e−8·‖A‖ — eight decades above any honest cutoff.
/// That is exactly the shape of a transfer with no finite zeros at all:
/// `pz/rc_lowpass_ports`, `pz/bench_pz_two_pole` and
/// `pz/bench_pz_filt_multistage` each have a nilpotent numerator A, and a
/// magnitude cutoff reports invented zeros at 1e8 rad/s for all three.
///
/// rank(Aᵐ) is first-order accurate instead. In the core–nilpotent split the
/// nilpotent block vanishes at m = its index, and the rank settles on the
/// count of genuine roots; the sequence is non-increasing, so it stops the
/// first time it fails to drop.
fn coreRank(w: *Work) usize {
    const n = w.n;
    var norm: f64 = 0;
    for (w.a) |v| norm = @max(norm, @abs(v));
    if (norm == 0) return 0;
    // Normalised so the m-th power stays O(1) and the rank threshold is a
    // plain eps rather than eps·‖A‖ᵐ.
    for (w.a, w.p) |v, *dst| dst.* = v / norm;

    const tol = @as(f64, @floatFromInt(n)) * std.math.floatEps(f64);
    var rank = n;
    for (0..n) |_| {
        @memcpy(w.m, w.p);
        const r = eliminationRank(n, w.m, tol);
        if (r == rank or r == 0) return r;
        rank = r;
        // w.p ← w.p · (A/‖A‖), through w.m because a matmul cannot alias.
        for (0..n) |i| {
            for (0..n) |j| {
                var acc: f64 = 0;
                for (0..n) |k| acc += w.p[i * n + k] * w.a[k * n + j];
                w.m[i * n + j] = acc / norm;
            }
        }
        @memcpy(w.p, w.m);
    }
    return rank;
}

/// Rank by Gaussian elimination with partial pivoting on a matrix already
/// scaled to a max entry of 1; a column with no pivot above `tol` is skipped
/// rather than ending the sweep.
///
/// ponytail: partial pivoting is not rank-revealing in the worst case (Kahan's
/// matrix); a column-pivoted QR is the upgrade if a deck ever turns up whose
/// zero count this gets wrong.
fn eliminationRank(n: usize, a: []f64, tol: f64) usize {
    var rank: usize = 0;
    for (0..n) |col| {
        if (rank == n) break;
        var best: f64 = 0;
        var best_row: usize = rank;
        for (rank..n) |r| {
            const v = @abs(a[r * n + col]);
            if (v > best) {
                best = v;
                best_row = r;
            }
        }
        if (best <= tol) continue;
        if (best_row != rank) {
            for (col..n) |j| std.mem.swap(f64, &a[rank * n + j], &a[best_row * n + j]);
        }
        const inv = 1.0 / a[rank * n + col];
        for (rank + 1..n) |r| {
            const factor = a[r * n + col] * inv;
            if (factor == 0) continue;
            for (col..n) |j| a[r * n + j] -= factor * a[rank * n + j];
        }
        rank += 1;
    }
    return rank;
}

/// Contract entry: the roots at ctx.x_op.
///
/// Two column layouts, because the two shapes a reader wants differ. With no
/// zeros the plot is a LIST — one row per pole under a `pole` column, which is
/// what every deck written against bare `.pz` reads. With zeros the two counts
/// need not match (a transfer can have six zeros against seven poles) and one
/// rectangular table cannot hold two lists of different length, so the layout
/// becomes ngspice's own: `pole(k)`/`zero(k)` columns on a single row.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    // `res` owns a dense n x n eigen workspace and is deinit-ed here, so it is
    // scratch; `a` is a results arena whose free() is a no-op. See
    // RunCtx.scratch_allocator.
    var res = try solve(ctx.circuit, x_op, opts, ctx.scratch_allocator orelse a);
    defer res.deinit();

    if (!opts.want_zeros) {
        const n = res.poles.len;
        const names = try a.dupe([]const u8, &.{ "index", "pole" });
        const data = try a.alloc(f64, n * 4);
        for (res.poles, 0..) |pole, i| {
            data[i * 4] = @floatFromInt(i);
            data[i * 4 + 1] = 0;
            data[i * 4 + 2] = pole.re;
            data[i * 4 + 3] = pole.im;
        }
        return .{ .plotname = "Pole-Zero Analysis", .varnames = names, .is_complex = true, .npoints = n, .data = data };
    }

    const nvars = 1 + res.poles.len + res.zeros.len;
    const names = try a.alloc([]const u8, nvars);
    const data = try a.alloc(f64, nvars * 2);
    names[0] = "index";
    data[0] = 0;
    data[1] = 0;
    var col: usize = 1;
    for ([_][]const u8{ "pole", "zero" }, [_][]const Complex{ res.poles, res.zeros }) |label, roots| {
        for (roots, 1..) |r, k| {
            names[col] = try std.fmt.allocPrint(a, "{s}({d})", .{ label, k });
            data[col * 2] = r.re;
            data[col * 2 + 1] = r.im;
            col += 1;
        }
    }
    return .{ .plotname = "Pole-Zero Analysis", .varnames = names, .is_complex = true, .npoints = 1, .data = data };
}

// ============================================================================
// QR eigenvalue computation: Hessenberg reduction + Francis double-shift
// ============================================================================

const Eigs = struct { count: usize, converged: bool };

/// Writes eigenvalues into out (caller provides n slots — the exact upper
/// bound). converged is false if qr_max_iter was exhausted (remaining
/// eigenvalues dropped).
fn eigenvaluesQR(n: usize, a: []f64, out: []Complex, options: Options) Eigs {
    if (n == 0) return .{ .count = 0, .converged = true };

    if (n == 1) {
        out[0] = .{ .re = a[0], .im = 0 };
        return .{ .count = 1, .converged = true };
    }

    balance(n, a);
    hessenbergReduce(n, a);

    var count: usize = 0;
    var nn = n;
    var iter: u32 = 0;

    while (nn > 0) {
        // Top of the ACTIVE block: the largest l whose entry above it on the
        // subdiagonal is negligible. Chasing the bulge from row 0 instead —
        // which is what this did before there was a search — sweeps a
        // deflated block back into the iteration, and on a matrix that splits
        // in the middle (every MNA pencil with an isolated branch row does)
        // it stops converging at all.
        var l = nn - 1;
        while (l > 0) : (l -= 1) {
            const sub = @abs(a[l * n + (l - 1)]);
            const diag = @abs(a[(l - 1) * n + (l - 1)]) + @abs(a[l * n + l]);
            if (sub <= options.qr_tol * @max(diag, 1e-30)) {
                a[l * n + (l - 1)] = 0;
                break;
            }
        }

        if (l + 1 == nn) {
            out[count] = .{ .re = a[l * n + l], .im = 0 };
            count += 1;
            nn = l;
            iter = 0;
        } else if (l + 2 == nn) {
            extract2x2(a, n, l, out[count..][0..2]);
            count += 2;
            nn = l;
            iter = 0;
        } else {
            if (iter >= options.qr_max_iter) return .{ .count = count, .converged = false };
            francisStep(n, a, l, nn, iter);
            iter += 1;
        }
    }
    return .{ .count = count, .converged = true };
}

/// dgebal-style scaling: the diagonal similarity D⁻¹AD that evens each row's
/// norm against its column's. D is powers of two, so the similarity is EXACT
/// in floating point and the eigenvalues are untouched — what changes is the
/// QR's conditioning, and A = −M⁻¹C spans the decades between a picofarad and
/// a kilohm, which is enough to hand back eigenvalues with the wrong ORDER of
/// magnitude (`pz/bench_pz_pz2` reported a pole at 4e15 rad/s for a circuit
/// whose fastest is 1e9). Numerical Recipes `balanc`, sweeping until a pass
/// changes nothing.
fn balance(n: usize, a: []f64) void {
    const radix: f64 = 2;
    const radix_sq = radix * radix;
    // The sweep is a fixed point and terminates on its own; the cap is here so
    // a denormal cannot turn that into a hang.
    for (0..64) |_| {
        var settled = true;
        for (0..n) |i| {
            var c: f64 = 0;
            var r: f64 = 0;
            for (0..n) |j| {
                if (j == i) continue;
                c += @abs(a[j * n + i]);
                r += @abs(a[i * n + j]);
            }
            if (c == 0 or r == 0) continue;
            const s = c + r;
            var f: f64 = 1;
            var g = r / radix;
            while (c < g) {
                f *= radix;
                c *= radix_sq;
            }
            g = r * radix;
            while (c > g) {
                f /= radix;
                c /= radix_sq;
            }
            if (!((c + r) / f < 0.95 * s)) continue;
            const inv = 1 / f;
            for (0..n) |j| a[i * n + j] *= inv;
            for (0..n) |j| a[j * n + i] *= f;
            settled = false;
        }
        if (settled) return;
    }
}

/// Extract eigenvalues of the 2x2 block at (offset, offset).
fn extract2x2(a: []const f64, n: usize, offset: usize, out: *[2]Complex) void {
    const a11 = a[offset * n + offset];
    const a12 = a[offset * n + offset + 1];
    const a21 = a[(offset + 1) * n + offset];
    const a22 = a[(offset + 1) * n + offset + 1];

    const tr = a11 + a22;
    const det = a11 * a22 - a12 * a21;
    const disc = tr * tr - 4.0 * det;

    if (disc >= 0) {
        const sq = @sqrt(disc);
        out[0] = .{ .re = (tr + sq) / 2.0, .im = 0 };
        out[1] = .{ .re = (tr - sq) / 2.0, .im = 0 };
    } else {
        const sq = @sqrt(-disc);
        out[0] = .{ .re = tr / 2.0, .im = sq / 2.0 };
        out[1] = .{ .re = tr / 2.0, .im = -sq / 2.0 };
    }
}

// ============================================================================
// Hessenberg reduction via Householder reflections (SIMD-accelerated)
// ============================================================================

fn hessenbergReduce(n: usize, a: []f64) void {
    if (n <= 2) return;

    for (0..n - 2) |k| {
        // Compute norm of sub-column a[k+1..n, k].
        var sigma: f64 = 0;
        for (k + 1..n) |row| {
            const v = a[row * n + k];
            sigma += v * v;
        }
        sigma = @sqrt(sigma);

        if (sigma < 1e-30) continue;

        if (a[(k + 1) * n + k] < 0) sigma = -sigma;

        a[(k + 1) * n + k] += sigma;
        const beta = 1.0 / (sigma * a[(k + 1) * n + k]);

        // Apply from the left: A := (I - beta * v * v^T) * A
        for (k..n) |j| {
            var dot_acc: V = @splat(0.0);
            var row: usize = k + 1;
            while (row + W <= n) : (row += W) {
                var vv: V = undefined;
                var av: V = undefined;
                inline for (0..W) |wi| {
                    vv[wi] = a[(row + wi) * n + k];
                    av[wi] = a[(row + wi) * n + j];
                }
                dot_acc += vv * av;
            }
            var dot: f64 = @reduce(.Add, dot_acc);
            while (row < n) : (row += 1) {
                dot += a[row * n + k] * a[row * n + j];
            }
            dot *= beta;
            row = k + 1;
            while (row < n) : (row += 1) {
                a[row * n + j] -= a[row * n + k] * dot;
            }
        }

        // Apply from the right: A := A * (I - beta * v * v^T)
        for (0..n) |row| {
            var dot_acc: V = @splat(0.0);
            var col: usize = k + 1;
            while (col + W <= n) : (col += W) {
                var vv: V = undefined;
                var av: V = undefined;
                inline for (0..W) |wi| {
                    vv[wi] = a[(col + wi) * n + k];
                    av[wi] = a[row * n + (col + wi)];
                }
                dot_acc += av * vv;
            }
            var dot: f64 = @reduce(.Add, dot_acc);
            while (col < n) : (col += 1) {
                dot += a[row * n + col] * a[col * n + k];
            }
            dot *= beta;
            col = k + 1;
            while (col + W <= n) : (col += W) {
                var vv: V = undefined;
                inline for (0..W) |wi| {
                    vv[wi] = a[(col + wi) * n + k];
                }
                inline for (0..W) |wi| {
                    a[row * n + (col + wi)] -= dot * vv[wi];
                }
            }
            while (col < n) : (col += 1) {
                a[row * n + col] -= dot * a[col * n + k];
            }
        }

        // Write sub-diagonal entry and zero below.
        a[(k + 1) * n + k] = -sigma;
        // The reflector maps its own storage v to -v (Hv = -v), leaving
        // nonzeros below the subdiagonal; francisStep reads those slots as
        // bulge entries, so they must be true zeros.
        for (k + 2..n) |row| a[row * n + k] = 0;
    }
}

// ============================================================================
// Francis double-shift QR step (SIMD-accelerated reflectors)
// ============================================================================

/// One bulge chase over the ACTIVE block, rows/columns [lo, nn).
fn francisStep(n: usize, a: []f64, lo: usize, nn: usize, iter: u32) void {
    // Shift polynomial from trailing 2x2 block.
    const am = a[(nn - 2) * n + (nn - 2)];
    const bm = a[(nn - 2) * n + (nn - 1)];
    const cm = a[(nn - 1) * n + (nn - 2)];
    const dm = a[(nn - 1) * n + (nn - 1)];

    var s = am + dm; // trace
    var t = am * dm - bm * cm; // determinant

    // EISPACK's exceptional shift. After ten sweeps the trailing 2x2 has
    // stopped telling the iteration anything, and a shift built from the
    // subdiagonal alone breaks the cycle. Without it a matrix with REPEATED
    // eigenvalues never deflates: `pz/bench_pz_pzt` is three identical R/L
    // sections, so all three of its poles sit on top of each other and the
    // iteration burned its whole budget without emitting one of them.
    if (iter > 0 and iter % 10 == 0) {
        const mag = @abs(cm) + @abs(a[(nn - 2) * n + (nn - 3)]);
        s = 1.5 * mag;
        t = mag * mag;
    }

    // First column of the implicit double-shift polynomial (H - sigma*I)(H - conj(sigma)*I).
    var x = a[lo * n + lo] * a[lo * n + lo] + a[lo * n + lo + 1] * a[(lo + 1) * n + lo] - s * a[lo * n + lo] + t;
    var y = a[(lo + 1) * n + lo] * (a[lo * n + lo] + a[(lo + 1) * n + (lo + 1)] - s);
    var z: f64 = a[(lo + 2) * n + lo] * a[(lo + 1) * n + lo];

    for (lo..nn - 1) |k| {
        const nr = @sqrt(x * x + y * y + z * z);
        if (nr < 1e-30) {
            if (k + 1 < nn - 1) {
                x = a[(k + 1) * n + k];
                y = a[(k + 2) * n + k];
                z = if (k + 3 < nn) a[(k + 3) * n + k] else 0;
            }
            continue;
        }

        if (k + 2 < nn) {
            applyReflector3(n, a, lo, nn, k, x, y, z, nr);
        } else {
            applyReflector2(n, a, lo, nn, k, x, y);
        }

        if (k + 1 < nn - 1) {
            x = a[(k + 1) * n + k];
            y = a[(k + 2) * n + k];
            z = if (k + 3 < nn) a[(k + 3) * n + k] else 0;
        }
    }
}

fn applyReflector3(n: usize, a: []f64, lo: usize, nn: usize, k: usize, x_in: f64, y_in: f64, z_in: f64, nr: f64) void {
    const sign_x: f64 = if (x_in >= 0) 1.0 else -1.0;
    const v0 = x_in + sign_x * nr;
    const v1 = y_in;
    const v2 = z_in;
    const denom = v0 * v0 + v1 * v1 + v2 * v2;
    if (denom < 1e-60) return;
    const beta = 2.0 / denom;

    const v0v: V = @splat(v0);
    const v1v: V = @splat(v1);
    const v2v: V = @splat(v2);
    const betav: V = @splat(beta);

    // Apply from left: rows k, k+1, k+2
    // Column lo-1 is the split this block was deflated at; reaching back into
    // it would refill the negligible subdiagonal entry and undo the split.
    const col_start = if (k > lo) k - 1 else lo;
    var j: usize = col_start;
    while (j + W <= nn) : (j += W) {
        const r0: V = a[k * n + j ..][0..W].*;
        const r1: V = a[(k + 1) * n + j ..][0..W].*;
        const r2: V = a[(k + 2) * n + j ..][0..W].*;
        const dot_v = v0v * r0 + v1v * r1 + v2v * r2;
        const tv = betav * dot_v;
        const p0: *[W]f64 = a[k * n + j ..][0..W];
        const p1: *[W]f64 = a[(k + 1) * n + j ..][0..W];
        const p2: *[W]f64 = a[(k + 2) * n + j ..][0..W];
        p0.* = r0 - tv * v0v;
        p1.* = r1 - tv * v1v;
        p2.* = r2 - tv * v2v;
    }
    // Scalar tail for non-W-aligned columns.
    while (j < nn) : (j += 1) {
        const dot = v0 * a[k * n + j] + v1 * a[(k + 1) * n + j] + v2 * a[(k + 2) * n + j];
        const tv = beta * dot;
        a[k * n + j] -= tv * v0;
        a[(k + 1) * n + j] -= tv * v1;
        a[(k + 2) * n + j] -= tv * v2;
    }

    // Apply from right: rows 0..min(nn-1, k+3), columns k, k+1, k+2
    const row_end = @min(nn, k + 4);
    for (0..row_end) |row| {
        const dot = a[row * n + k] * v0 + a[row * n + k + 1] * v1 + a[row * n + k + 2] * v2;
        const tv = beta * dot;
        a[row * n + k] -= tv * v0;
        a[row * n + k + 1] -= tv * v1;
        a[row * n + k + 2] -= tv * v2;
    }
}

fn applyReflector2(n: usize, a: []f64, lo: usize, nn: usize, k: usize, x_in: f64, y_in: f64) void {
    const nr = @sqrt(x_in * x_in + y_in * y_in);
    if (nr < 1e-30) return;

    const sign_x: f64 = if (x_in >= 0) 1.0 else -1.0;
    const v0 = x_in + sign_x * nr;
    const v1 = y_in;
    const denom = v0 * v0 + v1 * v1;
    if (denom < 1e-60) return;
    const beta = 2.0 / denom;

    const v0v: V = @splat(v0);
    const v1v: V = @splat(v1);
    const betav: V = @splat(beta);

    // Column lo-1 is the split this block was deflated at; reaching back into
    // it would refill the negligible subdiagonal entry and undo the split.
    const col_start = if (k > lo) k - 1 else lo;
    var j: usize = col_start;
    while (j + W <= nn) : (j += W) {
        const r0: V = a[k * n + j ..][0..W].*;
        const r1: V = a[(k + 1) * n + j ..][0..W].*;
        const dot_v = v0v * r0 + v1v * r1;
        const tv = betav * dot_v;
        const p0: *[W]f64 = a[k * n + j ..][0..W];
        const p1: *[W]f64 = a[(k + 1) * n + j ..][0..W];
        p0.* = r0 - tv * v0v;
        p1.* = r1 - tv * v1v;
    }
    // Scalar tail.
    while (j < nn) : (j += 1) {
        const dot = v0 * a[k * n + j] + v1 * a[(k + 1) * n + j];
        const tv = beta * dot;
        a[k * n + j] -= tv * v0;
        a[(k + 1) * n + j] -= tv * v1;
    }

    const row_end = @min(nn, k + 3);
    for (0..row_end) |row| {
        const dot = a[row * n + k] * v0 + a[row * n + k + 1] * v1;
        const tv = beta * dot;
        a[row * n + k] -= tv * v0;
        a[row * n + k + 1] -= tv * v1;
    }
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .Complex = Complex,
    .eigenvaluesQR = eigenvaluesQR,
    .hessenbergReduce = hessenbergReduce,
} else {};
