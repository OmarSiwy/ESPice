//! AC mismatch (HSPICE `.acmatch`): the 1-sigma spread of one AC output over
//! the `.ac` sweep from the parameter variations `.dcmatch` uses, by adjoint
//! sensitivity per frequency lane. Each parameter costs one solve on the DC
//! factor (its operating-point shift, dx = −J⁻¹ ∂F/∂p) and one eval at the
//! shifted point; each frequency then costs one pass over the pattern:
//!   dy/dp = −λ(ω)ᵀ (dG/dp + jω dC/dp) x(ω),
//! with A x = b the AC solution and Aᵀ λ = e_out. The magnitude, phase, real
//! and imaginary spreads sum each group's linear change in quadrature.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const dcmatch = @import("../dc/dcmatch.zig");
const num = @import("core").numerics;
const Complex = num.Complex;
const FreqSolver = @import("solver").freq_solve.FreqSolver;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Acmatch;

/// The spread columns ahead of the per-group sensitivities: 1-sigma of the
/// magnitude, of the phase in degrees, and of the real and imaginary parts.
const spread_names = [_][]const u8{ "acm_mag", "acm_phase", "acm_re", "acm_im" };

/// Contract entry: complex point-major rows (frequency, the four spreads
/// as real values, then each group's dy/dσ, or dy/dp per
/// parameter without a variation block, labelled as `.dcmatch` labels
/// them).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points: usize = opts.sweep.count();

    const refs = try ckt.collectParams();
    const groups = try dcmatch.Groups.init(scratch, refs, opts.variations);
    defer groups.deinit(scratch);
    const n_groups = groups.count();

    // Every point's AC solution x(ω) and adjoint z(ω) = A⁻ᴴ e_out (the
    // stacked-real transpose solve), so λ = conj(z).
    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);
    const sol = try scratch.alloc(f64, 2 * n_points * nn + 2 * nn);
    defer scratch.free(sol);
    const drive = sol[2 * n_points * nn ..][0..nn];
    const e_out = sol[2 * n_points * nn + nn ..][0..nn];
    root.zeroSimd(drive);
    if (ctx.ac_drive.len == nn) @memcpy(drive, ctx.ac_drive);
    root.zeroSimd(e_out);
    e_out[opts.output_node] = 1;
    if (opts.output_neg != root.GROUND) e_out[opts.output_neg] = -1;
    {
        var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
        defer fs.deinit(scratch);
        for ([_]bool{ false, true }, [_][]const f64{ drive, e_out }) |adjoint, rhs| {
            var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, omegas, rhs, adjoint);
            defer stream.deinit(scratch);
            const base: usize = if (adjoint) n_points * nn else 0;
            while (try stream.next(ckt)) |pt| @memcpy(sol[base + pt.k * nn ..][0..nn], pt.x);
        }
    }

    // Nominal planes and the DC factor for the operating-point shifts.
    // ponytail: dG/dp and dC/dp come from the plain eval, so an `ac=` value
    // (Circuit.linearizeAc) and the frequency-dependent `acDyn` terms carry
    // no parameter derivative; add them when a varied device has either.
    const nnz: usize = ckt.nnz;
    const planes = try scratch.alloc(f64, 3 * nnz + 3 * n);
    defer scratch.free(planes);
    const g0 = planes[0..nnz];
    const c0 = planes[nnz..][0..nnz];
    const dval = planes[2 * nnz ..][0..nnz];
    const rhs0 = planes[3 * nnz ..][0..n];
    const dx = planes[3 * nnz + n ..][0..n];
    const xs = planes[3 * nnz + 2 * n ..][0..n];
    const ws = try ckt.workspace();
    ckt.eval(ctx.x_op, 0);
    @memcpy(g0, ckt.g_vals[0..nnz]);
    @memcpy(c0, ckt.c_vals[0..nnz]);
    @memcpy(rhs0, ckt.rhs[0..n]);
    try ws.slv.factor(ckt.g_vals, ckt.solver_execution);

    // dy per group and point, then per parameter into its group.
    const dy = try scratch.alloc(Complex, n_groups * n_points);
    defer scratch.free(dy);
    @memset(dy, Complex.zero);
    const dg = try scratch.alloc(f64, nnz);
    defer scratch.free(dg);
    for (0..n_groups) |g| {
        try ckt.checkpoint(.{ .phase = .sweep, .completed = g, .total = n_groups });
        for (groups.members(g)) |m| {
            const p = refs[m.param];
            const orig = p.get();
            p.set(orig + 1e-6 * @abs(orig) + 1e-12);
            const delta = p.get() - orig;
            defer {
                p.set(orig);
                ckt.recomputeType(p.type) catch unreachable; // restores the checked original parameter
            }
            ckt.recomputeType(p.type) catch |e| switch (e) {
                error.TopologyChanged => continue,
            };
            if (delta == 0) continue;
            // dx = −J⁻¹ ∂F/∂p, then the planes at (p + δ, x_op + δ·dx).
            ckt.eval(ctx.x_op, 0);
            diffQuot(dx, ckt.rhs[0..n], rhs0, delta);
            ws.slv.solve(dx, dx);
            @memcpy(xs, ctx.x_op[0..n]);
            num.axpy(xs, -delta, dx);
            ckt.eval(xs, 0);
            diffQuot(dg, ckt.g_vals[0..nnz], g0, delta);
            diffQuot(dval, ckt.c_vals[0..nnz], c0, delta);
            for (0..n_points) |k| {
                const x = sol[k * nn ..][0..nn];
                const adj = sol[(n_points + k) * nn ..][0..nn];
                var acc = Complex.zero;
                for (0..n) |col| {
                    const xc = Complex{ .re = x[col], .im = x[n + col] };
                    for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |slot| {
                        const row = ckt.row_idx[slot];
                        const lam = Complex{ .re = adj[row], .im = -adj[n + row] };
                        const da = Complex{ .re = dg[slot], .im = omegas[k] * dval[slot] };
                        acc = acc.add(lam.mul(da).mul(xc));
                    }
                }
                dy[g * n_points + k] = dy[g * n_points + k].sub(acc.scale(m.scale));
            }
        }
    }
    // Leave the planes at the nominal point, as the sweep found them.
    ckt.eval(ctx.x_op, 0);

    const names = try a.alloc([]const u8, 1 + spread_names.len + n_groups);
    names[0] = "frequency";
    @memcpy(names[1..][0..spread_names.len], &spread_names);
    for (names[1 + spread_names.len ..], 0..) |*name, g| name.* = try groups.label(a, ckt, refs, g);
    const row_len = 2 * names.len;
    const data = try a.alloc(f64, n_points * row_len);
    for (0..n_points) |k| {
        const row = data[k * row_len ..][0..row_len];
        const x = sol[k * nn ..][0..nn];
        var y = Complex{ .re = x[opts.output_node], .im = x[n + opts.output_node] };
        if (opts.output_neg != root.GROUND) y = y.sub(.{ .re = x[opts.output_neg], .im = x[n + opts.output_neg] });
        row[0] = freqs[k];
        row[1] = 0;
        var var_m: f64 = 0;
        var var_p: f64 = 0;
        var var_r: f64 = 0;
        var var_i: f64 = 0;
        const mag = y.mag();
        for (0..n_groups) |g| {
            const d = dy[g * n_points + k];
            // One sigma of the group: its dy/dσ; without a variation
            // block the column is dy/dp and the sigma scales it here.
            const s = d.scale(groups.sigma(g));
            const dm = (y.re * s.re + y.im * s.im) / mag;
            const dp = (y.re * s.im - y.im * s.re) / (mag * mag);
            var_m += dm * dm;
            var_p += dp * dp;
            var_r += s.re * s.re;
            var_i += s.im * s.im;
            row[2 * (1 + spread_names.len + g)] = d.re;
            row[2 * (1 + spread_names.len + g) + 1] = d.im;
        }
        for ([_]f64{ var_m, std.math.radiansToDegrees(1) * std.math.radiansToDegrees(1) * var_p, var_r, var_i }, 0..) |v, i| {
            row[2 * (1 + i)] = @sqrt(v);
            row[2 * (1 + i) + 1] = 0;
        }
    }
    return .{
        .plotname = "AC Mismatch",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}

/// dst[i] = (v[i] − v0[i]) / delta over dst.len.
fn diffQuot(dst: []f64, v: []const f64, v0: []const f64, delta: f64) void {
    for (dst, v[0..dst.len], v0[0..dst.len]) |*d, a, b| d.* = (a - b) / delta;
}
