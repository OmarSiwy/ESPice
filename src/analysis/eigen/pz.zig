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
//! Poles are s = 1/λ for the eigenvalues λ of A = −G⁻¹C, found by dense
//! Hessenberg reduction and Francis double-shift QR (core/eigen.zig). Zeros are the
//! finite generalized eigenvalues of the numerator pencil itself, by QZ
//! (qz.zig). That pencil is singular at s = 0 whenever the transfer has a
//! zero there, and its roots at infinity form a defective block. Through A
//! that block comes back as roundoff eigenvalues scattered as far from zero
//! as genuine ones; the QZ sees each of its roots as a vanishing diagonal of
//! C's triangular factor instead.
const std = @import("std");
const root = @import("../types.zig");
const types = @import("core").numerics;
const dense_lu = @import("solver").dense_lu;
const freq_solve = @import("solver").freq_solve;
const qr = @import("core").eigen;
const qz = @import("qz.zig");

const Complex = types.Complex;
const GROUND = root.GROUND;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Pz;

/// Poles and zeros in rad/s, each owned by `allocator`.
pub const Roots = struct {
    poles: []Complex,
    zeros: []Complex,
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
    /// G, overwritten with its LU.
    m: []f64,
    /// A = −G⁻¹C, destroyed by the QR.
    a: []f64,
    /// Column of C and its solve, n each.
    col: []f64,
    sol: []f64,
    piv: []u32,
    eigs: []Complex,
};

/// Poles and, when the directive asks for them, transfer zeros at the
/// operating point `x_op`. Returns error.Singular when poles are wanted and G
/// itself is singular (a node reached only through capacitors), and
/// error.PzDidNotConverge when the QR or QZ runs out of `qr_max_iter` with
/// roots still missing: a partial root set is never returned.
///
/// Diverges from ngspice, which warns at its iteration limit and publishes
/// the roots it found (cktpzstr.c:225).
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Roots {
    const n: usize = ckt.n;

    try ckt.linearizeAc(x_op);

    const arena = try allocator.alloc(f64, 4 * n * n + 2 * n);
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
        .col = arena[4 * n * n ..][0..n],
        .sol = arena[4 * n * n + n ..][0..n],
        .piv = piv,
        .eigs = eigs,
    };
    ckt.denseG(w.g);
    ckt.denseC(w.c);
    // The frequency-dependent entries at their DC gain, acDyn(0).re (absdelay
    // 1, a laplace H(0)): what a .dc eval stamps in G, bit for bit. e^(-sτ)
    // has no finite pole-zero form, so a delay stays transparent.
    if (ckt.ac_dyn_slots.len != 0) {
        const dyn = try allocator.alloc(f64, 2 * ckt.ac_dyn_slots.len);
        defer allocator.free(dyn);
        const re = dyn[0..ckt.ac_dyn_slots.len];
        ckt.acDyn(x_op, &.{0}, re, dyn[re.len..]);
        for (ckt.ac_dyn_slots, re) |slot, v| {
            if (slot < ckt.nnz) w.g[@as(usize, ckt.row_idx[slot]) * n + freq_solve.slotCol(ckt.col_ptr, slot)] += v;
        }
    }

    var poles: []Complex = &.{};
    errdefer allocator.free(poles);
    if (options.want != .zeros) poles = try poleRoots(&w, options, allocator);

    var zeros: []Complex = &.{};
    if (options.want != .poles) {
        numeratorPencil(&w, options);
        // det(G' + sC') = det(G' − s(−C')).
        for (w.c) |*v| v.* = -v.*;
        const num = qz.roots(n, w.g, w.c, eigs, options.qr_tol, options.qr_max_iter);
        if (!num.converged) return error.PzDidNotConverge;
        zeros = try allocator.dupe(Complex, eigs[0..num.count]);
    }

    return .{
        .poles = poles,
        .zeros = zeros,
        .allocator = allocator,
    };
}

/// Poles from A = −G⁻¹C, in a list owned by `allocator`.
fn poleRoots(w: *Work, options: Options, allocator: std.mem.Allocator) ![]Complex {
    @memcpy(w.m, w.g);
    try dense_lu.factorize(w.n, w.m, w.piv);
    buildA(w);
    const eigs = w.eigs;
    const den = qr.eigenvalues(w.n, w.a, eigs, options.qr_tol, options.qr_max_iter);
    if (!den.converged) return error.PzDidNotConverge;

    // s = 1/λ = conj(λ)/|λ|². |λ| ≈ 0 is a row with no dynamics (a resistive
    // node, a branch row), not a pole at the origin, and it is zero to within
    // the QR's backward error, O(n·eps·‖A‖). Anything above that is a real
    // time constant however small next to the slowest one, so the cutoff is
    // absolute: `pz/widely_separated_modes` has τ = 1 ns next to τ = 1000 s,
    // twelve decades apart.
    var max_abs: f64 = 0;
    for (eigs[0..den.count]) |l| max_abs = @max(max_abs, l.mag());
    const cutoff = @as(f64, @floatFromInt(w.n)) * std.math.floatEps(f64) * max_abs;
    var kept: usize = 0;
    for (eigs[0..den.count]) |l| {
        const m2 = l.magSq();
        if (l.mag() <= cutoff or m2 == 0) continue;
        eigs[kept] = .{ .re = l.re / m2, .im = -l.im / m2 };
        kept += 1;
    }
    return allocator.dupe(Complex, eigs[0..kept]);
}

/// A = −G⁻¹C into `w.a`, one back-substitution per column of C against the
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

/// Contract entry: the roots at ctx.x_op, complex, in one of two layouts.
/// Poles only: a list, one row per pole under (index, pole), which is what
/// decks written against bare `.pz` read. With zeros the two counts need not
/// match, so the layout is ngspice's: one row of `pole(k)` and `zero(k)`
/// columns.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    var res = try solve(ctx.circuit, ctx.x_op, opts, ctx.scratch_allocator);

    defer res.deinit();

    if (opts.want == .poles) {
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
