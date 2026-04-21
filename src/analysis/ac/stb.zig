//! Loop-gain stability (STB): drive the deck's own 0 V probe source with a
//! unit injection on its branch row and sweep T(ω) = −V(+)/V(−).
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const Complex = @import("core").numerics.Complex;
const FreqSolver = @import("solver").freq_solve.FreqSolver;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Stb;

/// Contract entry: the loop gain at every frequency. Complex, point-major
/// (frequency, loop_gain).
///
/// The probe is the deck's own 0 V source (`.stb Vprobe ...`), not one this
/// module adds: its branch equation is already `v_p - v_n - V = 0`, so
/// `rhs[branch] = 1` makes it the 1 V loop injection and leaves every other
/// stamp alone. The orientation is ngspice's: the probe's `+` node is where
/// the signal arrives (the driven side of the break) and `−` is where it
/// leaves into the rest of the loop, so T = −V(+)/V(−).
///
/// Returns error.InvalidProbe when a probe index is out of range or the `−`
/// node is ground (no returned voltage to divide by).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    if (opts.probe_branch >= n or opts.probe_p >= n or opts.probe_n >= n)
        return error.InvalidProbe;
    if (opts.probe_n == root.GROUND) return error.InvalidProbe;

    try ckt.linearizeAc(ctx.x_op);
    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit(scratch);

    const n_points: usize = opts.sweep.count();
    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);

    const rhs = try scratch.alloc(f64, 2 * n);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    rhs[opts.probe_branch] = 1.0;

    const names = try a.dupe([]const u8, &.{ "frequency", "loop_gain" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, n_points * 4);
    errdefer a.free(data);

    var stream = try freq.Stream.init(scratch, &fs, omegas, rhs, false);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const v_p: Complex = .{ .re = pt.x[opts.probe_p], .im = pt.x[n + opts.probe_p] };
        const v_n: Complex = .{ .re = pt.x[opts.probe_n], .im = pt.x[n + opts.probe_n] };
        const t = v_p.div(v_n).scale(-1);
        data[pt.k * 4 ..][0..4].* = .{ freqs[pt.k], 0, t.re, t.im };
    }

    return .{
        .plotname = "Stability Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}
