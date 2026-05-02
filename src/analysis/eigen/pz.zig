//! Pole-zero analysis (`.pz`): the finite roots of det(G + sC) = 0 for two
//! pencils built from one linearization at the operating point.
//!
//! Poles use the circuit's own MNA. A linearization nulls the independent
//! sources, so the input voltage source is already the short a `vol`
//! denominator wants and a current source the open a `cur` one wants; the
//! mode word changes nothing for poles.
//!
//! Zeros use the same pencil with the output column replaced by the input
//! drive. H(s) = e_outᵀ Y⁻¹ d, so by Cramer's rule that determinant is H's
//! numerator and its roots are the transfer zeros. It equals the bordered
//! determinant [[Y, d], [e_outᵀ, 0]], but as a column swap the C plane stays
//! emptier: a grounded output capacitor drops out of the pencil instead of
//! surviving as a spurious root.
//!
//! The roots are s = σ + 1/λ for the eigenvalues λ of A = −M⁻¹C, M = G + σC,
//! found by dense Hessenberg reduction and Francis double-shift QR (qr.zig).
const std = @import("std");
const root = @import("../types.zig");
const types = @import("core").numerics;
const dense_lu = @import("solver").dense_lu;
const qr = @import("qr.zig");

const Complex = types.Complex;
const GROUND = root.GROUND;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Pz;

/// Poles and zeros in rad/s, each owned by `allocator`.
pub const Roots = struct {
    poles: []Complex,
    zeros: []Complex,
    /// False if the QR hit qr_max_iter before deflating every eigenvalue; the
    /// root lists are then incomplete.
    qr_converged: bool,
    allocator: std.mem.Allocator,

    /// Frees both root lists.
    pub fn deinit(self: *Roots) void {
        self.allocator.free(self.poles);
        self.allocator.free(self.zeros);
    }
};

/// One pencil solve's working set, sliced from one allocation. `g` and `c` are
/// the pencil; the zeros pass rewrites both in place as the numerator.
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
    /// Column of C and its solve, n each.
    col: []f64,
    sol: []f64,
    piv: []u32,
    eigs: []Complex,
};

/// Poles and, when the directive asks for them, transfer zeros at the
/// operating point `x_op`. Returns error.Singular when G itself is singular
/// (a node reached only through capacitors), or when no shift of the zeros'
/// ladder gives a factorable numerator.
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Roots {
    const n: usize = ckt.n;

    try ckt.linearizeAc(x_op);

    const planes: usize = if (options.want_zeros) 5 else 4;
    const arena = try allocator.alloc(f64, planes * n * n + 2 * n);
    defer allocator.free(arena);
    const piv = try allocator.alloc(u32, n);
    defer allocator.free(piv);
    // At most n eigenvalues: an exact bound.
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

    // Denominator: σ = 0 and no rank count, the form every bare `.pz` deck is
    // validated against.
    try shiftedFactor(&w, 0, 0);
    buildA(&w);
    const den = qr.eigenvalues(n, w.a, eigs, options.qr_tol, options.qr_max_iter);

    // s = 1/λ = conj(λ)/|λ|². |λ| ≈ 0 is a row with no dynamics (a resistive
    // node, a branch row), not a pole at the origin, and it is zero to within
    // the QR's backward error, O(n·eps·‖A‖). Anything above that is a real
    // time constant however small next to the slowest one, so the cutoff is
    // absolute: `pz/widely_separated_modes` has τ = 1 ns next to τ = 1000 s,
    // twelve decades apart.
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
    var scale: f64 = 0;
    var kept: usize = 0;
    for (eigs[0..den.count]) |l| {
        const m2 = l.magSq();
        if (l.mag() <= cutoff or m2 == 0) continue;
        const pole = Complex{ .re = l.re / m2, .im = -l.im / m2 };
        if (options.want_poles) poles[kept] = pole;
        kept += 1;
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
        .qr_converged = converged,
        .allocator = allocator,
    };
}

/// M = G + σC, overwritten with its LU. `min_ratio` > 0 adds a relative
/// singularity test (smallest pivot against max|M|) on top of dense_lu's
/// absolute one (eps², 4.9e-32). The absolute test lets a shift that lands on
/// a root of the pencil factor "successfully" and hand back noise; the
/// numerator pass has a ladder of shifts to fall through and can afford to be
/// strict. The denominator passes 0.
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

/// A = −M⁻¹C into `w.a`, one back-substitution per column of C against the
/// LU in `w.m`.
fn buildA(w: *Work) void {
    const n = w.n;
    for (0..n) |j| {
        for (0..n) |r| w.col[r] = w.c[r * n + j];
        dense_lu.solveFactored(n, w.m, w.piv, w.col, w.sol);
        for (0..n) |r| w.a[r * n + j] = -w.sol[r];
    }
}

/// Rewrites (G, C) in place as the transfer numerator's pencil: the MNA with
/// the output column replaced by the input drive.
///
/// A differential output is one column operation away from a single column:
/// in det [[Y, d], [e_out⁺ᵀ − e_out⁻ᵀ, 0]], adding column out⁺ into column
/// out⁻ cancels the −1 the border row carries there and leaves the +1 at out⁺
/// to expand along, which is the column swap below. GROUND is row 0, the unit
/// clamp `v(0) = 0`, and never takes a stamp.
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
/// s = σ + 1/λ loses |σ|·eps of absolute accuracy on roots far below σ. A
/// transfer zero at the origin (every high-pass has one) makes the numerator
/// singular at s = 0, which is why the shift exists. The ladder is in units
/// of the pole magnitude rather than ‖G‖/‖C‖: an MNA branch row puts ±1 in G
/// next to picofarads in C, which inflates that ratio decades past where the
/// roots are.
fn zeroRoots(w: *Work, options: Options, pole_scale: f64) !qr.Eigs {
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

    buildA(w);
    // How many eigenvalues are nonzero in exact arithmetic (see coreRank);
    // the rest are roots at infinity. Counted before the QR destroys A.
    const rank = coreRank(w);
    const found = qr.eigenvalues(n, w.a, w.eigs, options.qr_tol, options.qr_max_iter);
    const keep = @min(rank, found.count);
    // |λ| descending puts the genuine roots first: the spurious ones belong to
    // the nilpotent block and sit within eps^(1/k)·‖A‖ of zero. A conjugate
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

/// max|G| / max|C|, the pencil's own frequency scale; 0 when C is empty. Used
/// only when there are no poles to take the scale from.
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
/// the QR cannot tell them from small genuine ones: a defective zero
/// eigenvalue of multiplicity k comes back at |λ| ≈ ‖A‖·eps^(1/k), which for
/// the common k = 2 is 1e−8·‖A‖, eight decades above any honest cutoff. That
/// is the shape of a transfer with no finite zeros: `pz/rc_lowpass_ports`,
/// `pz/bench_pz_two_pole` and `pz/bench_pz_filt_multistage` each have a
/// nilpotent numerator A, and a magnitude cutoff invents zeros at 1e8 rad/s
/// for all three.
///
/// rank(Aᵐ) is first-order accurate instead. In the core-nilpotent split the
/// nilpotent block vanishes at m = its index and the rank settles on the
/// count of genuine roots. The sequence is non-increasing, so the loop stops
/// the first time it fails to drop. O(n⁴) worst case: one n³ product per
/// power.
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

/// Contract entry: the roots at ctx.x_op, complex, in one of two layouts.
/// Poles only: a list, one row per pole under (index, pole), which is what
/// decks written against bare `.pz` read. With zeros the two counts need not
/// match, so the layout is ngspice's: one row of `pole(k)` and `zero(k)`
/// columns.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    var res = try solve(ctx.circuit, ctx.x_op, opts, ctx.scratch_allocator);

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
