//! AC small-signal sweep. One linearization at the operating point gives the
//! G and C planes; each frequency is then one lane of `freq.Stream`, with no
//! circuit evaluation inside the sweep.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const FreqSolver = @import("solver").freq_solve.FreqSolver;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Ac;

/// Contract entry: the response to `ctx.ac_drive`, the whole deck's AC
/// excitation (every source card with an `AC` spec, at its own magnitude and
/// phase). A V card drives its branch row, because its branch equation is
/// v_p - v_n - V = 0; driving the clamped node row instead would give an
/// identically zero response. An I card drives its two node rows. An empty
/// drive is a deck with no AC source and yields a zero response.
///
/// Complex, point-major (frequency, probes...).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points: usize = opts.sweep.count();
    std.debug.assert(ctx.ac_drive.len == nn or ctx.ac_drive.len == 0);

    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit(scratch);

    const rhs = try scratch.alloc(f64, nn);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    if (ctx.ac_drive.len == nn) @memcpy(rhs, ctx.ac_drive);

    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);

    const names = try root.probeNames(ctx, "frequency");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "frequency" literal
        a.free(names);
    }
    const row_len = names.len * 2;
    const data = try a.alloc(f64, n_points * row_len);
    errdefer a.free(data);

    var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, omegas, rhs, false);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const row = data[pt.k * row_len ..][0..row_len];
        row[0] = freqs[pt.k];
        row[1] = 0;
        for (ctx.probes, 1..) |node, col| {
            row[col * 2] = pt.x[node];
            row[col * 2 + 1] = pt.x[n + node];
        }
    }

    return .{
        .plotname = "AC Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}
