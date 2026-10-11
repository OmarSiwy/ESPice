//! AC small-signal sweep. One linearization at the operating point gives the
//! G and C planes; each frequency is then one lane of `freq.Stream`, with no
//! circuit evaluation inside the sweep.
//! Cites dev/analysis/ac-small-signal-noise.md.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const FreqSolver = @import("solver").freq_solve.FreqSolver;

/// The plot's name and scale column (`session.schemaOf` reports them).
pub const plotname = "AC Analysis";
pub const scale = "frequency";

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Ac;

/// Contract entry: the response to `ctx.ac_drive`, the whole deck's AC
/// excitation (every source card with an `AC` spec, at its own magnitude and
/// phase). A V card drives its branch row, because its branch equation is
/// v_p - v_n - V = 0; driving the clamped node row instead would give an
/// identically zero response. An I card drives its two node rows. An empty
/// drive is a deck with no AC source and yields a zero response.
///
/// Complex, point-major (frequency, probes...). A streamed run
/// (`ctx.stream`) writes each row there and returns empty `data`. Asserts
/// that `ctx.ac_drive` is 2n long or empty.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points: usize = opts.sweep.count();
    std.debug.assert(ctx.ac_drive.len == nn or ctx.ac_drive.len == 0);

    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit();

    const rhs = try scratch.alloc(f64, nn);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    if (ctx.ac_drive.len == nn) @memcpy(rhs, ctx.ac_drive);

    const freqs, const omegas = try freq.axis(scratch, opts.sweep);
    defer freq.freeAxis(scratch, freqs);

    const names = try root.probeNames(ctx, scale);
    const row_len = names.len * 2;
    // A streamed run writes each row to `ctx.stream` and keeps only the one
    // being built, in scratch; otherwise the rows are the result.
    const streamed = ctx.stream != null;
    const data = if (streamed) try scratch.alloc(f64, row_len) else try a.alloc(f64, n_points * row_len);
    defer if (streamed) scratch.free(data);
    errdefer if (!streamed) a.free(data);

    var stream = try freq.Stream.init(scratch, &fs, ckt, ctx.x_op, omegas, rhs, false);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const row = if (streamed) data else data[pt.k * row_len ..][0..row_len];
        row[0] = freqs[pt.k];
        row[1] = 0;
        for (ctx.probes, 1..) |node, col| {
            row[col * 2] = pt.x[node];
            row[col * 2 + 1] = pt.x[n + node];
        }
        if (ctx.stream) |w| try w.writeAll(std.mem.sliceAsBytes(row));
    }

    return .{
        .plotname = plotname,
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = if (streamed) &.{} else data,
    };
}
