//! Small-signal analyses about a multi-tone harmonic-balance solution:
//! `.hbac`, `.hbxf` and `.hbnoise` after a `.hb TONES=` card with two or
//! more large-signal tones. A small signal at f rides every spectral line,
//! so its sidebands are f + f_p over the signed lines p = -(m-1)..(m-1).
//! The linearized circuit is the conversion matrix over those sidebands,
//!   A(ω)[p][q] = G_{p-q} + j(ω + ω_p)·C_{p-q},
//! with G_d and C_d the phasors of G(t) and C(t) on the line at
//! f_p - f_q, zero when that difference is not a line. A product that
//! leaves the spectrum is dropped, not folded back: forming A as
//! DFT·diag(G(t_s))·IDFT over `mhb.zig`'s collocation instants aliases it
//! onto the kept lines instead (3x the noise of a two-tone multiplier at
//! NHARMS=1). With one tone this is `pac.zig`'s conversion matrix.
//!
//! ponytail: A(ω) is dense, one LU of the stacked-real 2·n·nf system per
//! frequency, O((2·n·nf)³). Past a few hundred unknowns the upgrade is
//! `pac.sweepKrylov`'s: GMRES on the block convolution, right
//! preconditioned by G_0 + j(ω + ω_p)·C_0 lanes.
const std = @import("std");
const root = @import("../types.zig");
const mhb = @import("mhb.zig");
const pac = @import("pac.zig");
const pxf = @import("pxf.zig");
const pnoise = @import("pnoise.zig");
const num = @import("core").numerics;
const dense_lu = @import("solver").dense_lu;

const Complex = pac.Complex;
const Options = @import("core").query.HbLptv;

/// The linearized orbit and the per-frequency system it factors.
const Linear = struct {
    orb: mhb.Orbit,
    n: usize,
    /// Sidebands, 2m - 1 for m lines; unknown node·nf + k is sideband k
    /// (signed line k - (nf-1)/2) of that node.
    nf: usize,
    /// G_{p-q} and C_{p-q}, row-major N x N with N = n·nf.
    gm: []Complex,
    cm: []Complex,
    /// A(ω) stacked real, [[Re, -Im], [Im, Re]], LU-factored by `factor`.
    sys: []f64,
    piv: []u32,

    /// Solves `opts`' multi-tone HB and forms its conversion matrices.
    /// error.HbDidNotConverge when Newton stops short; error.InvalidQueryOptions
    /// for a circuit with frequency-dependent entries, which the matrices
    /// would leave out. Free with `deinit` on `allocator`.
    fn init(ckt: *root.Circuit, opts: Options, allocator: std.mem.Allocator) !Linear {
        if (ckt.ac_dyn_slots.len != 0) return error.InvalidQueryOptions;
        const orb = try mhb.orbit(ckt, opts.hb(), allocator);
        errdefer orb.deinit(allocator);
        const n: usize = ckt.n;
        const nf = 2 * orb.spec.freqs.len - 1;
        const big = n * nf;
        const sq = try std.math.mul(usize, big, big);
        const gm = try allocator.alloc(Complex, 2 * sq);
        errdefer allocator.free(gm);
        const sys = try allocator.alloc(f64, 4 * sq);
        errdefer allocator.free(sys);
        const piv = try allocator.alloc(u32, 2 * big);
        errdefer allocator.free(piv);
        const lin: Linear = .{ .orb = orb, .n = n, .nf = nf, .gm = gm[0..sq], .cm = gm[sq..], .sys = sys, .piv = piv };
        try lin.blocks(ckt, allocator);
        return lin;
    }

    fn deinit(self: Linear, allocator: std.mem.Allocator) void {
        self.orb.deinit(allocator);
        allocator.free(self.gm.ptr[0 .. 2 * self.gm.len]);
        allocator.free(self.sys);
        allocator.free(self.piv);
    }

    /// Each pattern slot's G(t) and C(t) to line phasors, spread over the
    /// sideband pairs (p, q) whose offset difference is a line.
    fn blocks(self: Linear, ckt: *const root.Circuit, allocator: std.mem.Allocator) !void {
        const tr = self.orb.tr;
        const nt = tr.nt;
        const nf = self.nf;
        const big = self.n * nf;
        const none = std.math.maxInt(u32);
        // Sideband whose offset is f_p - f_q, or `none`.
        const diff = try allocator.alloc(u32, nf * nf);
        defer allocator.free(diff);
        const tol = 1e-12 * self.orb.spec.freqs[self.orb.spec.freqs.len - 1];
        for (0..nf) |p| for (0..nf) |q| {
            const d = self.offset(p) - self.offset(q);
            diff[p * nf + q] = for (0..nf) |k| {
                if (@abs(self.offset(k) - d) <= tol) break @intCast(k);
            } else none;
        };
        @memset(self.gm, Complex.zero);
        @memset(self.cm, Complex.zero);
        const coef = try allocator.alloc(f64, 2 * nf);
        defer allocator.free(coef);
        const ph = try allocator.alloc(Complex, 2 * nf);
        defer allocator.free(ph);
        for (0..self.n) |col| for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |slot| {
            const row: usize = ckt.row_idx[slot];
            inline for (.{ self.orb.g_td, self.orb.c_td }, 0..) |td, which| {
                const wave = td[slot * nt ..][0..nt];
                const c = coef[which * nf ..][0..nf];
                for (c, 0..) |*v, a| v.* = num.dot(wave, tr.fwd[a * nt ..][0..nt]);
                for (ph[which * nf ..][0..nf], 0..) |*v, k| v.* = linePhasor(c, nf, k);
            }
            for (0..nf) |p| for (0..nf) |q| {
                const k = diff[p * nf + q];
                if (k == none) continue;
                const at = (row * nf + p) * big + col * nf + q;
                self.gm[at] = self.gm[at].add(ph[k]);
                self.cm[at] = self.cm[at].add(ph[nf + k]);
            };
        };
    }

    /// LU-factors A(2π·f) into `sys`. error.SingularMatrix as `dense_lu`.
    fn factor(self: Linear, f: f64) !void {
        const big = self.n * self.nf;
        const n2 = 2 * big;
        for (0..big) |r| {
            const w = 2 * std.math.pi * (f + self.offset(r % self.nf));
            for (0..big) |c| {
                const g = self.gm[r * big + c];
                const cq = self.cm[r * big + c];
                const re = g.re - w * cq.im;
                const im = g.im + w * cq.re;
                self.sys[r * n2 + c] = re;
                self.sys[r * n2 + big + c] = -im;
                self.sys[(big + r) * n2 + c] = im;
                self.sys[(big + r) * n2 + big + c] = re;
            }
        }
        try dense_lu.factorize(n2, self.sys, self.piv);
    }

    /// Sideband `k` of `node` in the stacked 2·n·nf solution `v`: the
    /// phasor at f + f_k, or with `v` the adjoint solution the transfer
    /// from an injection there.
    fn sideband(self: Linear, v: []const f64, node: usize, k: usize) Complex {
        const at = node * self.nf + k;
        return .{ .re = v[at], .im = v[self.n * self.nf + at] };
    }

    /// Signed frequency of sideband `k`, in Hz.
    fn offset(self: Linear, k: usize) f64 {
        const m = self.nf / 2;
        return if (k >= m) self.orb.spec.freqs[k - m] else -self.orb.spec.freqs[m - k];
    }

    /// `pac.result`/`pxf.result` name a sideband by its harmonic index;
    /// renames each sideband's `stride` columns (from column 1) to `prefix`
    /// and the line's mixing product, `tf_h[1,-1]` or `pxf_h[1,-1](node)`.
    fn relabel(self: Linear, a: std.mem.Allocator, res: root.Result, prefix: []const u8, stride: usize) !void {
        // The result builders allocate the names mutable from `a`.
        const names: [][]const u8 = @constCast(res.varnames);
        const spec = self.orb.spec;
        const nt: usize = spec.tones;
        const m = self.nf / 2;
        for (0..self.nf) |k| {
            var buf: [8 * (mhb.max_tones + 1)]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            const line = if (k >= m) k - m else m - k;
            const sign: i32 = if (k >= m) 1 else -1;
            w.writeByte('[') catch unreachable;
            for (spec.mix[line * nt ..][0..nt], 0..) |mx, i| w.print("{s}{d}", .{ if (i == 0) "" else ",", sign * mx }) catch unreachable;
            w.writeByte(']') catch unreachable;
            for (names[1 + k * stride ..][0..stride]) |*name| {
                const tail = name.*[std.mem.indexOfScalar(u8, name.*, '(') orelse name.*.len ..];
                const renamed = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, w.buffered(), tail });
                a.free(name.*);
                name.* = renamed;
            }
        }
    }
};

/// Sideband `k` (signed line h = k - (nf-1)/2) of the real HB coefficients
/// `c` = [dc, c_1, s_1, ...]: the phasor of e^(j·2π·f_h·t), (c_h ∓ j·s_h)/2.
fn linePhasor(c: []const f64, nf: usize, k: usize) Complex {
    const h = @as(i64, @intCast(k)) - @as(i64, @intCast(nf / 2));
    if (h == 0) return .{ .re = c[0], .im = 0 };
    const j: usize = @intCast(@abs(h));
    const s = c[2 * j];
    return .{ .re = 0.5 * c[2 * j - 1], .im = if (h > 0) -0.5 * s else 0.5 * s };
}

/// `.hbac` about a multi-tone orbit: the deck's AC drive on sideband 0,
/// `opts.out_node` read on every sideband. Complex point-major rows
/// (frequency, tf_h[k] for each signed line k by frequency).
pub fn ac(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const lin = try Linear.init(ckt, opts, scratch);
    defer lin.deinit(scratch);
    const nf = lin.nf;
    const big = lin.n * nf;
    const n_freqs: usize = opts.sweep.count();
    const freqs = try scratch.alloc(f64, n_freqs);
    defer scratch.free(freqs);
    const transfer = try scratch.alloc(Complex, n_freqs * nf);
    defer scratch.free(transfer);
    const vecs = try scratch.alloc(f64, 4 * big);
    defer scratch.free(vecs);
    const rhs = vecs[0 .. 2 * big];
    const x = vecs[2 * big ..];
    @memset(rhs, 0);
    if (ctx.ac_drive.len != 0) for (0..lin.n) |node| {
        rhs[node * nf + nf / 2] = ctx.ac_drive[node];
        rhs[big + node * nf + nf / 2] = ctx.ac_drive[lin.n + node];
    };
    var sw = opts.sweep.iter();
    var fi: usize = 0;
    while (sw.next()) |f| : (fi += 1) {
        if (fi != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = fi, .total = n_freqs });
        try lin.factor(f);
        dense_lu.solveFactored(2 * big, lin.sys, lin.piv, rhs, x);
        freqs[fi] = f;
        for (transfer[fi * nf ..][0..nf], 0..) |*t, k| t.* = lin.sideband(x, opts.out_node, k);
    }
    const res = try pac.result(ctx.allocator, freqs, transfer, @intCast(nf / 2), "Harmonic Balance AC Analysis");
    try lin.relabel(ctx.allocator, res, "tf_h", 1);
    return res;
}

/// Solves A(2π·f)^T·w = e for the drive `e` (stacked, real): `x` receives
/// w, the transfers from every unknown and sideband to e's output.
fn solveAdjoint(lin: Linear, f: f64, e: []const f64, x: []f64) !void {
    try lin.factor(f);
    // sys^T is A^H stacked; for a real e, conj of its solution solves A^T.
    dense_lu.solveFactoredT(e.len, lin.sys, lin.piv, e, x);
    for (x[e.len / 2 ..]) |*v| v.* = -v.*;
}

/// `.hbxf` about a multi-tone orbit: transfers from a current at every
/// node and sideband to `opts.out_node` at f, in `.pxf`'s complex shape
/// with the sidebands named by mixing product.
pub fn xf(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const lin = try Linear.init(ckt, opts, scratch);
    defer lin.deinit(scratch);
    const n = lin.n;
    const nf = lin.nf;
    const big = n * nf;
    const n_freqs: usize = opts.sweep.count();
    const freqs = try scratch.alloc(f64, n_freqs);
    defer scratch.free(freqs);
    const transfer = try scratch.alloc(Complex, n_freqs * nf * n);
    defer scratch.free(transfer);
    const vecs = try scratch.alloc(f64, 4 * big);
    defer scratch.free(vecs);
    const e = vecs[0 .. 2 * big];
    const x = vecs[2 * big ..];
    @memset(e, 0);
    e[opts.out_node * nf + nf / 2] = 1;
    var sw = opts.sweep.iter();
    var fi: usize = 0;
    while (sw.next()) |f| : (fi += 1) {
        if (fi != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = fi, .total = n_freqs });
        try solveAdjoint(lin, f, e, x);
        freqs[fi] = f;
        const row = transfer[fi * nf * n ..][0 .. nf * n];
        for (0..nf) |k| for (0..n) |node| {
            row[k * n + node] = lin.sideband(x, node, k);
        };
    }
    const res = try pxf.result(ctx, freqs, transfer, @intCast(nf / 2), "Harmonic Balance Transfer Function Analysis");
    try lin.relabel(ctx.allocator, res, "pxf_h", n);
    return res;
}

/// `.hbnoise` about a multi-tone orbit, `.pnoise`'s method over the
/// mixing products. Each source is a unit stationary noise scaled by the
/// amplitude a(t) = sqrt(PSD(t)) along the orbit, a_q its sideband q
/// phasor. Noise at f + ν reaches injection sideband p through a_q when
/// f_p - f_q = ν, so the output density at f is
///   Σ_ν S(f + ν)·|Σ_{f_p - f_q = ν} H_p·a_q|²
/// with H_p `.hbxf`'s transfer. Pairs whose ν agree to 1e-12 of the top
/// line are the same noise and add coherently. Point-major rows
/// (frequency, hbnoise_density) in V²/Hz.
pub fn noise(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const srcs = try ckt.collectNoiseSources(ctx.x_op, scratch);
    defer scratch.free(srcs);
    const lin = try Linear.init(ckt, opts, scratch);
    defer lin.deinit(scratch);
    const n = lin.n;
    const nf = lin.nf;
    const big = n * nf;
    const ns = srcs.len;
    const tr = lin.orb.tr;
    const nt = tr.nt;

    // Amplitude phasors per source and sideband, white then flicker.
    const amp = try scratch.alloc(Complex, 2 * ns * nf);
    defer scratch.free(amp);
    const exponent = try scratch.alloc(f64, ns);
    defer scratch.free(exponent);
    {
        const td = try scratch.alloc(f64, 2 * ns * nt + nf + n);
        defer scratch.free(td);
        const hat = td[2 * ns * nt ..][0..nf];
        const x_s = td[2 * ns * nt + nf ..][0..n];
        for (0..nt) |s| {
            for (x_s, 0..) |*v, node| v.* = lin.orb.x_td[node * nt + s];
            const at = try ckt.collectNoiseSources(x_s, scratch);
            defer scratch.free(at);
            if (at.len != ns) return error.NoiseTopologyChanged;
            for (at, srcs, 0..) |src, original, i| {
                if (src.node_p != original.node_p or src.node_n != original.node_n) return error.NoiseTopologyChanged;
                td[i * nt + s] = pnoise.whiteAmp(src);
                td[(ns + i) * nt + s] = src.coeff * pnoise.signedSqrt(src.flicker);
                if (s == 0) exponent[i] = src.ef;
            }
        }
        // Forward transform, then each line's phasor.
        for (0..2 * ns) |i| {
            const a = td[i * nt ..][0..nt];
            for (hat, 0..) |*h, c| h.* = num.dot(a, tr.fwd[c * nt ..][0..nt]);
            for (amp[i * nf ..][0..nf], 0..) |*q, k| q.* = linePhasor(hat, nf, k);
        }
    }

    // Group every (p, q) pair by ν = f_p - f_q.
    const pairs = nf * nf;
    const group = try scratch.alloc(u32, pairs);
    defer scratch.free(group);
    const nu = try scratch.alloc(f64, pairs);
    defer scratch.free(nu);
    const order = try scratch.alloc(u32, pairs);
    defer scratch.free(order);
    for (0..nf) |p| for (0..nf) |q| {
        nu[p * nf + q] = lin.offset(p) - lin.offset(q);
    };
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.sort.pdq(u32, order, nu, struct {
        fn lt(v: []const f64, a: u32, b: u32) bool {
            return v[a] < v[b];
        }
    }.lt);
    const tol = 1e-12 * lin.orb.spec.freqs[lin.orb.spec.freqs.len - 1];
    var groups: usize = 0;
    const group_nu = try scratch.alloc(f64, pairs);
    defer scratch.free(group_nu);
    for (order, 0..) |i, r| {
        if (r == 0 or nu[i] - group_nu[groups - 1] > tol) {
            group_nu[groups] = nu[i];
            groups += 1;
        }
        group[i] = @intCast(groups - 1);
    }
    const acc = try scratch.alloc(Complex, 2 * groups);
    defer scratch.free(acc);

    const n_points: usize = opts.sweep.count();
    const freqs = try scratch.alloc(f64, n_points);
    defer scratch.free(freqs);
    const density = try scratch.alloc(f64, n_points);
    defer scratch.free(density);
    const vecs = try scratch.alloc(f64, 4 * big);
    defer scratch.free(vecs);
    const e = vecs[0 .. 2 * big];
    const x = vecs[2 * big ..];
    @memset(e, 0);
    if (opts.out_node != root.GROUND) e[opts.out_node * nf + nf / 2] = 1;
    if (opts.out_neg != root.GROUND) e[opts.out_neg * nf + nf / 2] = -1;

    var sw = opts.sweep.iter();
    var fi: usize = 0;
    while (sw.next()) |f| : (fi += 1) {
        if (fi != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = fi, .total = n_points });
        try solveAdjoint(lin, f, e, x);
        freqs[fi] = f;
        var total: f64 = 0;
        var lead: usize = 0;
        while (lead < ns) {
            const end = root.NoiseSource.groupEnd(srcs, lead);
            defer lead = end;
            // One correlated group: its rows add coherently into `acc`.
            @memset(acc, Complex.zero);
            for (srcs[lead..end], lead..) |src, i| for (0..nf) |p| {
                const hp = if (src.node_p != root.GROUND) lin.sideband(x, src.node_p, p) else Complex.zero;
                const hn = if (src.node_n != root.GROUND) lin.sideband(x, src.node_n, p) else Complex.zero;
                const h = hp.sub(hn);
                for (0..nf) |q| {
                    const g = group[p * nf + q];
                    acc[g] = acc[g].add(h.mul(amp[i * nf + q]));
                    acc[groups + g] = acc[groups + g].add(h.mul(amp[(ns + i) * nf + q]));
                }
            };
            const head = srcs[lead];
            for (0..groups) |g| total += pnoise.sourcePsd(acc[g].magSq() * pnoise.whiteShape(head, f + group_nu[g]), acc[groups + g].magSq(), exponent[lead], f + group_nu[g]);
        }
        density[fi] = total;
    }
    return pnoise.result(ctx.allocator, freqs, density, "hbnoise_density", "Harmonic Balance Noise Analysis");
}

test linePhasor {
    // x(t) = dc + c1 cos + s1 sin + c2 cos2 + s2 sin2: the ±h phasors are
    // conjugates and sum back to the real coefficients.
    const c = [_]f64{ 0.5, 0.3, -0.2, 0.1, 0.4 };
    const nf = c.len;
    const dc = linePhasor(&c, nf, nf / 2);
    try std.testing.expectEqual(@as(f64, 0.5), dc.re);
    try std.testing.expectEqual(@as(f64, 0), dc.im);
    for (1..3) |h| {
        const pos = linePhasor(&c, nf, nf / 2 + h);
        const neg = linePhasor(&c, nf, nf / 2 - h);
        try std.testing.expectEqual(pos.re, neg.re);
        try std.testing.expectEqual(pos.im, -neg.im);
        // Re{2·X·e^(jωt)} at t = 0 is c_h, at ωt = π/2 it is s_h.
        try std.testing.expectEqual(c[2 * h - 1], 2 * pos.re);
        try std.testing.expectEqual(c[2 * h], -2 * pos.im);
    }
}
