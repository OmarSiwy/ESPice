//! All-source AC transfer (`.acxf`, VACASK `acxf`): `.dcxf`'s readout at
//! every frequency, the frequencies riding `FreqSolver.solveBatch` lanes.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const dcxf = @import("../dc/xf.zig");
const FreqSolver = @import("solver").freq_solve.FreqSolver;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Acxf;

/// Contract entry: complex points (frequency, then `tf(src)` [, `zin(src)`,
/// `yin(src)`] per source). `tf_only` solves one adjoint right-hand side
/// per frequency and reads every transfer off it; otherwise each source is
/// its own forward right-hand side on the same lane factorization.
// ponytail: the forward path holds W·sources·2n values per chunk;
// split the sources into groups when a deck with hundreds of sources and a
// large n needs it.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const out: dcxf.Output = .{ .node = opts.output_node, .neg = opts.output_neg, .branch = opts.output_branch };

    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit(scratch);

    const n_points: usize = opts.sweep.count();
    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);

    const n_rhs: usize = if (opts.tf_only) 1 else opts.sources.len;
    const rhs = try scratch.alloc(f64, @max(n_rhs, 1) * 2 * n);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    if (opts.tf_only) out.seed(rhs) else for (opts.sources, 0..) |s, i| dcxf.excite(s, rhs[i * 2 * n ..]);

    const per: usize = if (opts.tf_only) 1 else 3;
    const cols = 1 + per * opts.sources.len;
    const data = try a.alloc(f64, n_points * cols * 2);
    errdefer a.free(data);

    var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, omegas, rhs, opts.tf_only);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const row = data[pt.k * cols * 2 ..][0 .. cols * 2];
        row[0..2].* = .{ freqs[pt.k], 0 };
        for (opts.sources, 0..) |s, i| {
            const dst = row[2 + 2 * per * i ..][0 .. 2 * per];
            if (opts.tf_only) {
                // The stacked-real transpose is A^H, so its solution is the
                // conjugate of A^T's.
                const tf = dcxf.adjointTf(s, pt.x, n);
                dst[0..2].* = .{ tf.re, -tf.im };
            } else {
                const x = pt.x[i * 2 * n ..][0 .. 2 * n];
                const tf = out.read(x, n);
                const zy = dcxf.immittance(s, x, n);
                dst[0..6].* = .{ tf.re, tf.im, zy[0].re, zy[0].im, zy[1].re, zy[1].im };
            }
        }
    }

    return .{
        .plotname = "AC Transfer Functions",
        .varnames = try dcxf.names(a, "frequency", opts.sources, opts.tf_only),
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}
