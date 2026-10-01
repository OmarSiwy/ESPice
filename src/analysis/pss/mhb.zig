//! Harmonic balance over any number of tones: Newton on the spectral
//! residual, each step solved by GMRES preconditioned with the block
//! diagonal G0 + jω_j·C0, one block per spectral line. The blocks share one
//! sparsity pattern and differ only in ω, so they factor as `FreqSolver`
//! frequency lanes (`factorEach`) once per Newton step, and every GMRES
//! iteration solves all of them at once (`solveEach`). The Jacobian itself
//! is never formed: a product is IDFT, the sampled G(t) and C(t) planes,
//! and DFT back, the sparse block Jacobian applied matrix-free.
//!
//! The spectrum is the box of mixing products k·f with |k_i| <= H_i,
//! optionally cut to a diamond Σ|k_i| <= INTMODMAX that keeps each tone's
//! own harmonics (HSPICE `.hb` [CR .HB], VACASK `truncate="hybrid"`).
//! Unknowns are node-major real blocks [dc, c_1, s_1, ..., c_{m-1}, s_{m-1}]
//! with x(t) = dc + Σ c_j cos(ω_j t) + s_j sin(ω_j t), the layout
//! `hb.solveSpectrum` uses for one tone, so one tone is the lines 0..K.
//!
//! One tone samples a uniform period 2x oversampled, as `hb.zig` does, so
//! the fixed point is the dense solver's. Several tones have no common
//! period: they take 2m-1 collocation instants picked greedily from an
//! oversampled pool for the best-conditioned transform, and invert it
//! (the APFT; VACASK `lib/corehbcoloc.cpp`, after Kundert, White and
//! Sangiovanni-Vincentelli, 1990, App. B).
const std = @import("std");
const root = @import("../types.zig");
const num = @import("core").numerics;
const solvers = @import("solver");
const converger = solvers.converger;
const dense_lu = solvers.dense_lu;
const FreqSolver = solvers.freq_solve.FreqSolver;
const Gmres = solvers.gmres.Gmres;
const gvProduct = @import("qpss.zig").gvProduct;

pub const Options = @import("core").query.Hb;

pub const SolveResult = @import("pss.zig").SolveResult;

/// The kept spectral lines, DC first, then by ascending frequency. Line j
/// is `freqs[j]` Hz, the mixing product Σ_i mix[j*tones + i]·f_i.
pub const Spectrum = struct {
    tones: u8,
    freqs: []f64,
    mix: []i16,

    /// Frees both tables; `gpa` is the allocator `spectrum` took.
    pub fn deinit(self: Spectrum, gpa: std.mem.Allocator) void {
        gpa.free(self.freqs);
        gpa.free(self.mix);
    }
};

/// The most tones a spectrum takes.
pub const max_tones = 8;

/// The largest box a spectrum enumerates, Π(2H_i + 1).
pub const max_box: usize = 1 << 22;

/// The spectrum of `tones` Hz with `nharms[i]` harmonics each and
/// INTMODMAX `intmodmax` (0: the whole box). A product whose frequency
/// matches a kept one to 1e-14 relative is the same line: the lower order
/// wins, then a single tone's harmonic, then the earlier product, as in
/// VACASK `lib/spurs.cpp`. error.InvalidQueryOptions past `max_tones` or
/// `max_box`.
pub fn spectrum(gpa: std.mem.Allocator, tones: []const f64, nharms: []const u16, intmodmax: u16) !Spectrum {
    std.debug.assert(tones.len == nharms.len);
    const nt = tones.len;
    if (nt == 0 or nt > max_tones) return error.InvalidQueryOptions;
    var box: usize = 1;
    for (nharms) |h| {
        box = std.math.mul(usize, box, 2 * @as(usize, h) + 1) catch return error.InvalidQueryOptions;
        if (box > max_box or h > std.math.maxInt(i16)) return error.InvalidQueryOptions;
    }

    // Candidates on the positive half: the negative one is the same line.
    const Cand = struct { f: f64, order: u32, mixed: bool, idx: u32 };
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(gpa);
    var mixes: std.ArrayList(i16) = .empty;
    defer mixes.deinit(gpa);
    var k: [max_tones]i32 = undefined;
    for (0..nt) |i| k[i] = -@as(i32, nharms[i]);
    for (0..box) |_| {
        var order: u32 = 0;
        var nnz: u32 = 0;
        var f: f64 = 0;
        var scale: f64 = 0;
        for (0..nt) |i| {
            order += @abs(k[i]);
            nnz += @intFromBool(k[i] != 0);
            const term = @as(f64, @floatFromInt(k[i])) * tones[i];
            f += term;
            scale += @abs(term);
        }
        const kept = intmodmax == 0 or order <= intmodmax or nnz <= 1;
        // Zero only for k = 0; any other product at 0 Hz is DC's duplicate.
        const tol = 1e-14 * scale;
        if (kept and ((order == 0) or f > tol)) {
            try cands.append(gpa, .{ .f = if (order == 0) 0 else f, .order = order, .mixed = nnz > 1, .idx = @intCast(cands.items.len) });
            for (0..nt) |i| try mixes.append(gpa, @intCast(k[i]));
        }
        // Odometer, last tone fastest.
        var i = nt;
        while (i > 0) {
            i -= 1;
            k[i] += 1;
            if (k[i] <= nharms[i]) break;
            k[i] = -@as(i32, nharms[i]);
        }
    }

    const c = cands.items;
    std.sort.pdq(Cand, c, {}, struct {
        fn lt(_: void, a: Cand, b: Cand) bool {
            return a.f < b.f or (a.f == b.f and a.idx < b.idx);
        }
    }.lt);
    const freqs = try gpa.alloc(f64, c.len);
    errdefer gpa.free(freqs);
    const mix = try gpa.alloc(i16, c.len * nt);
    errdefer gpa.free(mix);
    var m: usize = 0;
    var head: usize = 0;
    while (head < c.len) {
        var best = head;
        var end = head + 1;
        while (end < c.len and c[end].f - c[head].f <= 1e-14 * c[end].f) : (end += 1) {
            const a = c[end];
            const b = c[best];
            if (a.order < b.order or (a.order == b.order and (!a.mixed and b.mixed or (a.mixed == b.mixed and a.idx < b.idx)))) best = end;
        }
        freqs[m] = c[best].f;
        @memcpy(mix[m * nt ..][0..nt], mixes.items[c[best].idx * nt ..][0..nt]);
        m += 1;
        head = end;
    }
    return .{
        .tones = @intCast(nt),
        .freqs = try shrink(f64, gpa, freqs, m),
        .mix = try shrink(i16, gpa, mix, m * nt),
    };
}

fn shrink(comptime T: type, gpa: std.mem.Allocator, buf: []T, len: usize) ![]T {
    if (gpa.resize(buf, len)) return buf[0..len];
    const out = try gpa.dupe(T, buf[0..len]);
    gpa.free(buf);
    return out;
}

/// The IDFT/DFT pair between a spectrum block (nf = 2m-1 reals) and nt
/// time samples: x(t_s) = Σ_c inv[s*nf + c]·X_c and
/// X_c = Σ_s fwd[c*nt + s]·x(t_s). Rows are contiguous for `num.dot`.
const Transform = struct {
    nt: usize,
    times: []f64,
    inv: []f64,
    fwd: []f64,
};

/// Pool size per collocation point (VACASK's default `samplefac`).
const pool_factor: usize = 5;

/// Builds the transform for `spec` into `buf`: nt + 2·nt·nf values.
fn transform(spec: Spectrum, tones: []const f64, buf: []f64, allocator: std.mem.Allocator) !Transform {
    const m = spec.freqs.len;
    const nf = 2 * m - 1;
    const nt = transformSamples(spec);
    const tr: Transform = .{ .nt = nt, .times = buf[0..nt], .inv = buf[nt..][0 .. nt * nf], .fwd = buf[nt + nt * nf ..][0 .. nt * nf] };
    if (spec.tones == 1) {
        // One tone: hb.zig's uniform, oversampled grid and its Galerkin
        // projection, harmonic h at sample s read at (h*s) mod nt so every
        // sample sees the same rounded angles.
        const nt_f: f64 = @floatFromInt(nt);
        for (0..nt) |s| {
            tr.times[s] = @as(f64, @floatFromInt(s)) / nt_f / tones[0];
            tr.inv[s * nf] = 1;
            tr.fwd[s] = 1 / nt_f;
            for (1..m) |j| {
                const h: usize = @intCast(spec.mix[j]);
                const angle = 2 * std.math.pi * @as(f64, @floatFromInt((h * s) % nt)) / nt_f;
                tr.inv[s * nf + 2 * j - 1] = @cos(angle);
                tr.inv[s * nf + 2 * j] = @sin(angle);
                tr.fwd[(2 * j - 1) * nt + s] = 2 * @cos(angle) / nt_f;
                tr.fwd[(2 * j) * nt + s] = 2 * @sin(angle) / nt_f;
            }
        }
        return tr;
    }

    // Several tones: a pool of pool_factor·nt uniform instants, shifted by
    // 0.2 step, then greedy selection of the rows farthest from the span
    // of those already kept (modified Gram-Schmidt), as VACASK
    // `buildColocation`. The pool spans 1/(closest line spacing), not
    // VACASK's one period of the lowest line: two lines Δf apart only
    // separate over a window near 1/Δf, and on 1k/1.3k tones at order 5
    // (lines every 100 Hz, lowest at 300 Hz) the shorter window left the
    // transform singular.
    const pool = pool_factor * nt;
    const rows = try allocator.alloc(f64, pool * nf);
    defer allocator.free(rows);
    const pool_t = try allocator.alloc(f64, pool);
    defer allocator.free(pool_t);
    var spacing = spec.freqs[1];
    for (spec.freqs[1 .. m - 1], spec.freqs[2..]) |lo, hi| spacing = @min(spacing, hi - lo);
    const step = 1 / spacing / @as(f64, @floatFromInt(pool));
    for (pool_t, 0..) |*t, i| t.* = (@as(f64, @floatFromInt(i)) + 0.2) * step;
    for (pool_t, 0..) |t, i| basisRow(spec, tones, t, rows[i * nf ..][0..nf]);
    for (0..nt) |i| {
        if (i > 0) {
            const wrt = rows[(i - 1) * nf ..][0..nf];
            const ww = num.dot(wrt, wrt);
            var best = i;
            var best_norm: f64 = -1;
            for (i..pool) |r| {
                const row = rows[r * nf ..][0..nf];
                num.axpy(row, -num.dot(row, wrt) / ww, wrt);
                const nrm = num.dot(row, row);
                if (nrm > best_norm) {
                    best_norm = nrm;
                    best = r;
                }
            }
            if (!(best_norm > 0)) return error.HbDidNotConverge;
            if (best != i) {
                for (rows[i * nf ..][0..nf], rows[best * nf ..][0..nf]) |*a, *b| std.mem.swap(f64, a, b);
                std.mem.swap(f64, &pool_t[i], &pool_t[best]);
            }
        }
    }
    @memcpy(tr.times, pool_t[0..nt]);
    std.sort.pdq(f64, tr.times, {}, std.sort.asc(f64));
    for (tr.times, 0..) |t, s| basisRow(spec, tones, t, tr.inv[s * nf ..][0..nf]);

    // fwd = inv^-1, one unit column at a time.
    const lu = try allocator.dupe(f64, tr.inv);
    defer allocator.free(lu);
    const piv = try allocator.alloc(u32, nt);
    defer allocator.free(piv);
    const e = try allocator.alloc(f64, 2 * nt);
    defer allocator.free(e);
    dense_lu.factorize(nt, lu, piv) catch return error.HbDidNotConverge;
    for (0..nt) |s| {
        @memset(e[0..nt], 0);
        e[s] = 1;
        dense_lu.solveFactored(nt, lu, piv, e[0..nt], e[nt..]);
        for (0..nf) |c| tr.fwd[c * nt + s] = e[nt + c];
    }
    return tr;
}

/// Time samples `transform` uses for `spec`.
fn transformSamples(spec: Spectrum) usize {
    const nf = 2 * spec.freqs.len - 1;
    return if (spec.tones == 1) 2 * nf else nf;
}

/// Row [1, cos ω_1 t, sin ω_1 t, ...] of the inverse transform at `t`.
/// Each tone's phase is reduced to [0, 1) cycles first, with the product's
/// rounding error recovered by fma, so a late instant keeps its phase.
fn basisRow(spec: Spectrum, tones: []const f64, t: f64, row: []f64) void {
    var cyc: [max_tones]f64 = undefined;
    for (tones, 0..) |f, i| {
        const p = f * t;
        cyc[i] = (p - @trunc(p)) + @mulAdd(f64, f, t, -p);
    }
    row[0] = 1;
    for (1..spec.freqs.len) |j| {
        var c: f64 = 0;
        for (spec.mix[j * tones.len ..][0..tones.len], cyc[0..tones.len]) |k, y| c += @as(f64, @floatFromInt(k)) * y;
        const angle = 2 * std.math.pi * c;
        row[2 * j - 1] = @cos(angle);
        row[2 * j] = @sin(angle);
    }
}

/// x_td[node*nt + s] = Σ_c inv[s, c]·x_hat[node*nf + c].
fn idft(tr: Transform, nf: usize, x_hat: []const f64, x_td: []f64) void {
    const n = x_hat.len / nf;
    for (0..n) |node| {
        const x = x_hat[node * nf ..][0..nf];
        for (x_td[node * tr.nt ..][0..tr.nt], 0..) |*out, s| out.* = num.dot(x, tr.inv[s * nf ..][0..nf]);
    }
}

/// x_hat[node*nf + c] = Σ_s fwd[c, s]·x_td[node*nt + s].
fn dft(tr: Transform, nf: usize, x_td: []const f64, x_hat: []f64) void {
    const n = x_hat.len / nf;
    for (0..n) |node| {
        const x = x_td[node * tr.nt ..][0..tr.nt];
        for (x_hat[node * nf ..][0..nf], 0..) |*out, c| out.* = num.dot(x, tr.fwd[c * tr.nt ..][0..tr.nt]);
    }
}

/// dst += Ω·q_hat: dq/dt of q(t) = a cos(ω t) + b sin(ω t) is
/// ω b cos - ω a sin, so line j's cos row takes +ω_j·b and its sin row
/// -ω_j·a.
fn addOmega(omegas: []const f64, q_hat: []const f64, dst: []f64) void {
    const nf = 2 * omegas.len - 1;
    const n = q_hat.len / nf;
    for (0..n) |node| {
        const q = q_hat[node * nf ..][0..nf];
        const d = dst[node * nf ..][0..nf];
        for (omegas[1..], 1..) |w, j| {
            d[2 * j - 1] += w * q[2 * j];
            d[2 * j] -= w * q[2 * j - 1];
        }
    }
}

fn sum(x: []const f64) f64 {
    var acc: f64 = 0;
    for (x) |v| acc += v;
    return acc;
}

/// The Newton linear system for GMRES: `matvec` is the HB Jacobian at the
/// last residual's samples, `precond` the held G0 + jω_j·C0 blocks.
const Operator = struct {
    ckt: *const root.Circuit,
    tr: Transform,
    omegas: []const f64,
    nf: usize,
    /// G and C at every sample, slot-major, samples contiguous.
    g_td: []const f64,
    c_td: []const f64,
    /// Matvec scratch: two n·nt time planes and one n·nf spectrum.
    v_td: []f64,
    w_td: []f64,
    u_hat: []f64,
    fs: *FreqSolver,
    /// Preconditioner right-hand sides and solutions, m stacked 2n blocks.
    p_rhs: []f64,
    p_x: []f64,

    pub fn matvec(self: *Operator, v: []const f64, w: []f64) void {
        const nf = self.nf;
        const ckt = self.ckt;
        idft(self.tr, nf, v, self.v_td);
        gvProduct(self.w_td, self.g_td, self.v_td, ckt.col_ptr, ckt.row_idx, self.tr.nt);
        dft(self.tr, nf, self.w_td, w);
        if (!ckt.has_charge) return;
        gvProduct(self.w_td, self.c_td, self.v_td, ckt.col_ptr, ckt.row_idx, self.tr.nt);
        dft(self.tr, nf, self.w_td, self.u_hat);
        addOmega(self.omegas, self.u_hat, w);
    }

    /// r := M^-1 r. Line j's (c, s) rows are the phasor X = c - js of
    /// (G0 + jω_j C0)·X = r_c - j·r_s.
    pub fn precond(self: *Operator, r: []f64) void {
        const nf = self.nf;
        const n = r.len / nf;
        const nn = 2 * n;
        for (0..self.omegas.len) |j| {
            const b = self.p_rhs[j * nn ..][0..nn];
            for (0..n) |node| {
                b[node] = r[node * nf + ((2 * j) -| 1)];
                b[n + node] = if (j == 0) 0 else -r[node * nf + 2 * j];
            }
        }
        self.fs.solveEach(self.p_rhs, self.p_x, false);
        for (0..self.omegas.len) |j| {
            const x = self.p_x[j * nn ..][0..nn];
            for (0..n) |node| {
                if (j == 0) {
                    r[node * nf] = x[node];
                } else {
                    r[node * nf + 2 * j - 1] = x[node];
                    r[node * nf + 2 * j] = -x[n + node];
                }
            }
        }
    }
};

/// The shortest step the line search takes before it stops shortening.
const min_step: f64 = 1.0 / 1024.0;

/// GMRES stopping tolerance relative to the Newton residual.
const gmres_tol: f64 = 1e-7;
/// GMRES restart depth and restarts per Newton step.
const gmres_restart: u32 = 40;
const gmres_max_restarts: u32 = 20;

/// Driven harmonic balance on `spec` (tones `tones` Hz) from the DC
/// operating point. `x_hat` (n·(2m-1), caller-owned) receives node-major
/// blocks [dc, c_1, s_1, ...], the last iterate when Newton does not
/// converge. Newton takes `hb.zig`'s backtracking line search; each step
/// is GMRES on the matrix-free Jacobian with the block-diagonal
/// preconditioner. Memory is O(nnz·nt + m·LU) for the sampled planes and
/// the held factors.
pub fn solve(ckt: *root.Circuit, x_hat: []f64, spec: Spectrum, tones: []const f64, options: Options, allocator: std.mem.Allocator) !SolveResult {
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;
    const m = spec.freqs.len;
    const nf = 2 * m - 1;
    const nt = transformSamples(spec);
    const total = n * nf;
    std.debug.assert(x_hat.len == total);

    const sizes = [_]usize{
        nt + 2 * nt * nf, // transform
        total, // f_hat
        total, // q_hat, also the matvec's u_hat
        total, // dx
        total, // x_prev
        3 * n * nt, // x_td/v_td, f_td/w_td, q_td
        2 * nnz * nt, // g_td, c_td
        2 * nnz, // g0, c0
        2 * m * 2 * n, // p_rhs, p_x
        m, // omegas
        n, // x_sample
    };
    var len: usize = 0;
    for (sizes) |s| len += s;
    const arena = try allocator.alloc(f64, len);
    defer allocator.free(arena);
    var off: usize = 0;
    const take = struct {
        fn f(a: []f64, o: *usize, l: usize) []f64 {
            defer o.* += l;
            return a[o.*..][0..l];
        }
    }.f;
    const tr = try transform(spec, tones, take(arena, &off, sizes[0]), allocator);
    const f_hat = take(arena, &off, total);
    const q_hat = take(arena, &off, total);
    const dx = take(arena, &off, total);
    const x_prev = take(arena, &off, total);
    const x_td = take(arena, &off, n * nt);
    const f_td = take(arena, &off, n * nt);
    const q_td = take(arena, &off, n * nt);
    const g_td = take(arena, &off, nnz * nt);
    const c_td = take(arena, &off, nnz * nt);
    const g0 = take(arena, &off, nnz);
    const c0 = take(arena, &off, nnz);
    const p_rhs = take(arena, &off, 2 * m * n);
    const p_x = take(arena, &off, 2 * m * n);
    const omegas = take(arena, &off, m);
    const x_sample = take(arena, &off, n);
    std.debug.assert(off == len);
    for (omegas, spec.freqs) |*w, f| w.* = 2 * std.math.pi * f;
    if (!ckt.has_charge) root.zeroSimd(c_td);

    // DC coefficients from the operating point, as hb.zig.
    root.zeroSimd(x_hat);
    {
        const ws = try ckt.workspace();
        ckt.setSimState(.{ .kind = .dc });
        root.zeroSimd(x_sample);
        _ = converger.run(ckt, ws, x_sample, 0, converger.optionsFromTolerances(options.tol, null), root.EvalHook{}) catch {};
        for (0..n) |node| x_hat[node * nf] = x_sample[node];
    }

    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_sample);
    defer fs.deinit(allocator);
    var gmres = try Gmres.init(allocator, @intCast(total), @intCast(@min(total, gmres_restart)));
    defer gmres.deinit(allocator);
    var op: Operator = .{
        .ckt = ckt,
        .tr = tr,
        .omegas = omegas,
        .nf = nf,
        .g_td = g_td,
        .c_td = c_td,
        .v_td = x_td,
        .w_td = f_td,
        .u_hat = q_hat,
        .fs = &fs,
        .p_rhs = p_rhs,
        .p_x = p_x,
    };

    // Sample spacing for the transient state; an idt only needs dt > 0.
    const dt = 1 / (spec.freqs[1] * @as(f64, @floatFromInt(nt)));
    var step: f64 = 1.0;
    var prev_residual: f64 = std.math.inf(f64);
    var retrying = false;
    var iter: u16 = 0;
    while (iter < options.max_iter) : (iter += 1) {
        if (iter != 0) try ckt.checkpoint(.{ .phase = .harmonic, .completed = iter });
        idft(tr, nf, x_hat, x_td);
        // Sample s is the circuit at t_s in the transient phase, the only
        // phase in which a source follows its waveform (§4.6.1).
        // ponytail: the nt evals are independent; batch them on the GPU
        // when HB profiles eval-bound.
        for (0..nt) |s| {
            const t = tr.times[s];
            for (0..n) |node| x_sample[node] = x_td[node * nt + s];
            ckt.setSimState(.{ .t = t, .dt = dt, .kind = .tran });
            ckt.eval(x_sample, t);
            for (0..n) |node| f_td[node * nt + s] = ckt.rhs[node];
            for (0..n) |node| q_td[node * nt + s] = ckt.q_vec[node];
            for (ckt.g_vals[0..nnz], 0..) |g, slot| g_td[slot * nt + s] = g;
            if (ckt.has_charge) for (ckt.c_vals[0..nnz], 0..) |c, slot| {
                c_td[slot * nt + s] = c;
            };
        }
        dft(tr, nf, f_td, f_hat);
        if (ckt.has_charge) {
            dft(tr, nf, q_td, q_hat);
            addOmega(omegas, q_hat, f_hat);
        }

        const residual = num.normInf(f_hat);
        if (converger.hbTrace()) std.debug.print("MHB iter={d} res={e} step={e}\n", .{ iter, residual, step });
        if (residual < options.hb_tol) return .{ .converged = true, .iterations = iter + 1, .residual_norm = residual };

        if (iter != 0 and !(residual <= prev_residual) and step > min_step) {
            step *= 0.5;
            root.copySimd(x_hat, x_prev);
            num.axpy(x_hat, step, dx);
            retrying = true;
            continue;
        }
        prev_residual = residual;
        if (!retrying) step = @min(step * 2.0, 1.0);
        retrying = false;

        // G0, C0: the sample means. Not the DC line through `fwd`: a
        // collocation fit aliases G(t)'s harmonics past the kept band into
        // it, and an exponential's can drive it negative. A mean keeps
        // every conductance's sign.
        const inv_nt = 1 / @as(f64, @floatFromInt(nt));
        for (0..nnz) |slot| {
            g0[slot] = sum(g_td[slot * nt ..][0..nt]) * inv_nt;
            c0[slot] = sum(c_td[slot * nt ..][0..nt]) * inv_nt;
        }
        fs.setPlanes(g0, c0);
        try fs.factorEach(allocator, omegas);

        num.scale(f_hat, -1, f_hat);
        root.zeroSimd(dx);
        const gr = gmres.solve(&op, f_hat, dx, gmres_tol, gmres_max_restarts);
        if (converger.hbTrace()) std.debug.print("  gmres it={d} res={e} conv={}\n", .{ gr.iterations, gr.residual, gr.converged });
        root.copySimd(x_prev, x_hat);
        num.axpy(x_hat, step, dx);
    }
    // f_hat was negated for the last solve; its norm is the same.
    return .{ .converged = false, .iterations = options.max_iter, .residual_norm = num.normInf(f_hat) };
}

/// The tones and harmonic counts of `opts`, f0 first.
fn toneList(opts: Options, tones: *[max_tones]f64, nharms: *[max_tones]u16) !usize {
    const count = 1 + opts.extra_tones.len;
    if (count > max_tones or opts.extra_harmonics.len != opts.extra_tones.len) return error.InvalidQueryOptions;
    tones[0] = opts.f0;
    nharms[0] = opts.n_harmonics;
    @memcpy(tones[1..count], opts.extra_tones);
    @memcpy(nharms[1..count], opts.extra_harmonics);
    return count;
}

/// Contract entry for `.hb TONES=` (any tone count) and the positional
/// card with several tones: one row per spectral line, DC first then by
/// frequency. With `opts.phasors` the rows are complex, (frequency, each
/// probe's phasor c - j·s), x(t) = Re{X·e^(jωt)}, DC real; otherwise
/// (frequency, each probe's amplitude sqrt(c² + s²)) with a signed DC.
/// Non-convergence is error.HbDidNotConverge.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    var tones: [max_tones]f64 = undefined;
    var nharms: [max_tones]u16 = undefined;
    const count = try toneList(opts, &tones, &nharms);
    const spec = try spectrum(scratch, tones[0..count], nharms[0..count], opts.intmodmax);
    defer spec.deinit(scratch);
    if (spec.freqs.len < 2) return error.InvalidQueryOptions;
    const nf = 2 * spec.freqs.len - 1;
    const x_hat = try scratch.alloc(f64, @as(usize, ctx.circuit.n) * nf);
    defer scratch.free(x_hat);
    const st = try solve(ctx.circuit, x_hat, spec, tones[0..count], opts, scratch);
    if (!st.converged) return error.HbDidNotConverge;

    const names = try root.probeNames(ctx, "frequency");
    const width: usize = if (opts.phasors) 2 else 1;
    const ncols = names.len * width;
    const data = try a.alloc(f64, spec.freqs.len * ncols);
    @memset(data, 0);
    for (spec.freqs, 0..) |f, j| {
        const row = data[j * ncols ..][0..ncols];
        row[0] = f;
        for (ctx.probes, 1..) |node, p| {
            const x = x_hat[node * nf ..][0..nf];
            const v = row[p * width ..][0..width];
            if (j == 0) {
                v[0] = x[0];
            } else if (opts.phasors) {
                v[0] = x[2 * j - 1];
                v[1] = -x[2 * j];
            } else v[0] = std.math.hypot(x[2 * j - 1], x[2 * j]);
        }
    }
    return .{
        .plotname = "Harmonic Balance",
        .varnames = names,
        .is_complex = opts.phasors,
        .npoints = spec.freqs.len,
        .data = data,
    };
}

/// Solves one tone at f0 with K = `options.n_harmonics` through `solve`;
/// `x_hat` in `hb.solveSpectrum`'s layout.
pub fn solveOneTone(ckt: *root.Circuit, x_hat: []f64, options: Options, allocator: std.mem.Allocator) !SolveResult {
    const tones = [_]f64{options.f0};
    const spec = try spectrum(allocator, &tones, &.{options.n_harmonics}, 0);
    defer spec.deinit(allocator);
    return solve(ckt, x_hat, spec, &tones, options, allocator);
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .transform = transform,
    .transformSamples = transformSamples,
    .idft = idft,
    .dft = dft,
} else {};
