//! Quasi-periodic steady state: `.qpss f1 f2 K1 K2` solved as two-tone
//! harmonic balance by `mhb.solve` over the (2K1+1) x (2K2+1) box, then
//! published two-sided, one row per mix product k*f1 + l*f2.
//!
//! Cites: dev/analysis/qpss.md, dev/analysis/multitone-hb.md §QPSS.
const std = @import("std");
const root = @import("../types.zig");
const mhb = @import("mhb.zig");

/// The `.qpss` query: tones f1, f2 and their truncations k1, k2.
pub const Options = @import("core").query.Qpss;

/// Fills `lines[(l + k2)(2k1 + 1) + (k + k1)]` with the index of the
/// one-sided line of `spec` (ascending `spec.freqs`) at |k*f1 + l*f2|: k in
/// -k1..k1 fastest, l in -k2..k2 slowest. A product the spectrum merged into
/// another line within its 1e-14 relative tolerance maps to that line.
/// Asserts lines.len is the box size and `spec` has a line.
pub fn boxLines(spec: mhb.Spectrum, f1: f64, f2: f64, k1: u16, k2: u16, lines: []u32) void {
    const nf1 = 2 * @as(usize, k1) + 1;
    std.debug.assert(lines.len == nf1 * (2 * @as(usize, k2) + 1));
    std.debug.assert(spec.freqs.len >= 1);
    for (lines, 0..) |*line, flat| {
        const kl = signedKL(flat, k1, k2);
        const f = @abs(@as(f64, @floatFromInt(kl.k)) * f1 + @as(f64, @floatFromInt(kl.l)) * f2);
        // The nearest line: the first at or above f, or the one below it.
        const hi = std.sort.lowerBound(f64, spec.freqs, f, struct {
            fn order(target: f64, x: f64) std.math.Order {
                return std.math.order(target, x);
            }
        }.order);
        const j = if (hi == spec.freqs.len or (hi > 0 and f - spec.freqs[hi - 1] < spec.freqs[hi] - f)) hi - 1 else hi;
        std.debug.assert(@abs(spec.freqs[j] - f) <= 1e-12 * @max(f, 1));
        line.* = @intCast(j);
    }
}

/// (k, l) of box row `flat`.
fn signedKL(flat: usize, k1: u16, k2: u16) struct { k: i32, l: i32 } {
    const nf1 = 2 * @as(usize, k1) + 1;
    return .{
        .k = @as(i32, @intCast(flat % nf1)) - @as(i32, k1),
        .l = @as(i32, @intCast(flat / nf1)) - @as(i32, k2),
    };
}

/// Contract entry: one row per mix product (frequency k*f1 + l*f2, then each
/// probe's |X_kl|). The grid is two-sided, so a real tone splits across its
/// +-(k, l) conjugate pair and its amplitude is twice one line's magnitude
/// (DC excepted). Non-convergence, and a singular collocation transform, are
/// error.QpssDidNotConverge; a box of one line (k1 = k2 = 0) is
/// error.InvalidQueryOptions.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    try ctx.circuit.refuseDigital("qpss");
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const f2 = [1]f64{opts.f2};
    const k2 = [1]u16{opts.k2};
    const hb_opts: mhb.Options = .{ .tol = opts.tol, .f0 = opts.f1, .n_harmonics = opts.k1, .extra_tones = &f2, .extra_harmonics = &k2, .max_iter = opts.max_newton, .hb_tol = opts.hb_tol };
    const tones = [2]f64{ opts.f1, opts.f2 };
    const spec = try mhb.spectrum(scratch, &tones, &.{ opts.k1, opts.k2 }, 0, 1);
    defer spec.deinit(scratch);
    if (spec.freqs.len < 2) return error.InvalidQueryOptions;

    const nf = 2 * spec.freqs.len - 1;
    const x_hat = try scratch.alloc(f64, @as(usize, ctx.circuit.n) * nf);
    defer scratch.free(x_hat);
    const st = mhb.solve(ctx.circuit, x_hat, spec, &tones, hb_opts, scratch) catch |err| switch (err) {
        error.HbDidNotConverge => return error.QpssDidNotConverge,
        else => |e| return e, // else: every other error passes through unchanged
    };
    if (!st.converged) return error.QpssDidNotConverge;

    const n_rows = (2 * @as(usize, opts.k1) + 1) * (2 * @as(usize, opts.k2) + 1);
    const lines = try scratch.alloc(u32, n_rows);
    defer scratch.free(lines);
    boxLines(spec, opts.f1, opts.f2, opts.k1, opts.k2, lines);

    const names = try root.probeNames(ctx, "frequency");
    const ncols = names.len;
    std.debug.assert(ncols == ctx.probes.len + 1);
    const data = try a.alloc(f64, n_rows * ncols);
    for (lines, 0..) |j, flat| {
        const row = data[flat * ncols ..][0..ncols];
        const kl = signedKL(flat, opts.k1, opts.k2);
        row[0] = @as(f64, @floatFromInt(kl.k)) * opts.f1 + @as(f64, @floatFromInt(kl.l)) * opts.f2;
        for (ctx.probes, row[1..]) |node, *v| {
            const x = x_hat[node * nf ..][0..nf];
            // One-sided amplitude hypot(c, s) is twice each two-sided |X_kl|.
            v.* = if (j == 0) @abs(x[0]) else 0.5 * std.math.hypot(x[2 * j - 1], x[2 * j]);
        }
    }

    return .{
        .plotname = "Quasi-Periodic Steady State",
        .varnames = names,
        .is_complex = false,
        .npoints = n_rows,
        .data = data,
    };
}
