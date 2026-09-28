//! Small-signal analyses about the harmonic-balance solution. Each one
//! solves `hb.solveSpectrum`, samples every unknown onto a power-of-two grid
//! with `hb.orbit`, and hands that orbit to the back half of its shooting
//! twin: `.hbac` is PAC's forward sweep, `.hbxf` PXF's adjoint sweep and
//! `.hbnoise` `pnoise.orbitSweep`. The linearization, conversion matrix and
//! sideband folding are shared code, so the two orbit providers differ only
//! in how they find the orbit.
const std = @import("std");
const root = @import("../types.zig");
const hb = @import("hb.zig");
const pac = @import("pac.zig");
const pxf = @import("pxf.zig");
const pnoise = @import("pnoise.zig");

const Complex = pac.Complex;
const HbLptv = @import("core").query.HbLptv;

/// Orbit samples per period before rounding up: the `.pnoise` default. The
/// grid only has to resolve G(t) and C(t), whose harmonics run past the
/// HB's K, so it does not shrink with K.
const min_samples: usize = 64;

/// Solves HB and samples its orbit on a power-of-two grid wide enough for
/// HB's own 2(2K+1) points and for sideband offsets up to 2M.
/// error.HbDidNotConverge when Newton stops short. The caller frees `wave`.
fn orbit(ckt: *root.Circuit, opts: HbLptv, allocator: std.mem.Allocator) !pac.Orbit {
    const n: usize = ckt.n;
    const nf = 2 * @as(usize, opts.n_harmonics) + 1;
    const x_hat = try allocator.alloc(f64, n * nf);
    defer allocator.free(x_hat);
    const st = try hb.solveSpectrum(ckt, x_hat, &.{}, opts.hb(), allocator);
    if (!st.status.converged) return error.HbDidNotConverge;
    const n_sb = 2 * @as(usize, opts.n_sidebands) + 1;
    return hb.orbit(x_hat, n, opts.f0, pnoise.samplesFor(@max(min_samples, 2 * nf), n_sb), true, allocator);
}

/// The HB orbit linearized under `kind`. The caller owns the result.
fn linearize(ckt: *root.Circuit, opts: HbLptv, kind: root.AnalysisKind, allocator: std.mem.Allocator) !pac.Linearization {
    const orb = try orbit(ckt, opts, allocator);
    defer allocator.free(orb.wave);
    return pac.linearize(ckt, orb, kind, allocator);
}

/// The `pac.sweep` options for these HB options: sidebands -M..M at f0.
fn pacOptions(opts: HbLptv) pac.Options {
    return .{ .tol = opts.tol, .f_lo = opts.f0, .out_node = opts.out_node, .n_harmonics = opts.n_sidebands, .sweep = opts.sweep };
}

/// `.hbac`: periodic AC about the HB orbit.
pub const Ac = struct {
    pub const Options = HbLptv;

    /// Contract entry: the deck's AC excitation on sideband 0, read at
    /// `opts.out_node`, in `.pac`'s shape: point-major complex rows
    /// (frequency, tf_h{-M}..tf_h{+M}).
    pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
        const scratch = ctx.scratch_allocator;
        const n_freqs: usize = opts.sweep.count();
        const freqs = try scratch.alloc(f64, n_freqs);
        defer scratch.free(freqs);
        const transfer = try scratch.alloc(Complex, n_freqs * (2 * @as(usize, opts.n_sidebands) + 1));
        defer scratch.free(transfer);
        const lin = try linearize(ctx.circuit, opts, .ac, scratch);
        defer lin.deinit(scratch);
        try pac.sweep(false, ctx.circuit, lin, ctx.ac_drive, opts.out_node, freqs, transfer, pacOptions(opts), scratch);
        return pac.result(ctx.allocator, freqs, transfer, opts.n_sidebands, "Harmonic Balance AC Analysis");
    }
};

/// `.hbxf`: periodic transfer functions about the HB orbit.
pub const Xf = struct {
    pub const Options = HbLptv;

    /// Contract entry: transfers from every node and sideband to
    /// `opts.out_node`, in `.pxf`'s shape: point-major complex rows
    /// (frequency, pxf_h{m}(node) for every sideband then node).
    pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
        const scratch = ctx.scratch_allocator;
        const n: usize = ctx.circuit.n;
        const n_freqs: usize = opts.sweep.count();
        const freqs = try scratch.alloc(f64, n_freqs);
        defer scratch.free(freqs);
        const transfer = try scratch.alloc(Complex, n_freqs * (2 * @as(usize, opts.n_sidebands) + 1) * n);
        defer scratch.free(transfer);
        const drive = try scratch.alloc(f64, 2 * n);
        defer scratch.free(drive);
        @memset(drive, 0);
        drive[opts.out_node] = 1;
        const lin = try linearize(ctx.circuit, opts, .ac, scratch);
        defer lin.deinit(scratch);
        try pac.sweep(true, ctx.circuit, lin, drive, 0, freqs, transfer, pacOptions(opts), scratch);
        return pxf.result(ctx, freqs, transfer, opts.n_sidebands, "Harmonic Balance Transfer Function Analysis");
    }
};

/// `.hbnoise`: cyclostationary noise about the HB orbit.
pub const Noise = struct {
    pub const Options = HbLptv;

    /// Contract entry: output noise density of v(out_node) - v(out_neg), in
    /// `.pnoise`'s shape: point-major rows (frequency, hbnoise_density).
    pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
        const scratch = ctx.scratch_allocator;
        const srcs = try ctx.circuit.collectNoiseSources(ctx.x_op, scratch);
        defer scratch.free(srcs);
        const n_points: usize = opts.sweep.count();
        const freqs = try scratch.alloc(f64, n_points);
        defer scratch.free(freqs);
        const density = try scratch.alloc(f64, n_points);
        defer scratch.free(density);
        const orb = try orbit(ctx.circuit, opts, scratch);
        defer scratch.free(orb.wave);
        _ = try pnoise.orbitSweep(ctx.circuit, orb, srcs, freqs, density, .{
            .tol = opts.tol,
            .out_node = opts.out_node,
            .out_neg = opts.out_neg,
            .sweep = opts.sweep,
            .f_fundamental = opts.f0,
            .n_sidebands = opts.n_sidebands,
        }, scratch);
        return pnoise.result(ctx.allocator, freqs, density, "hbnoise_density", "Harmonic Balance Noise Analysis");
    }
};
