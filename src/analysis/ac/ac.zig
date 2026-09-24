//! AC small-signal sweep: one eval() linearizes (the planes are G and C),
//! then every frequency point is a fill + factor + solve. No circuit
//! contact inside the sweep.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const types = @import("numerics");
const FreqSolver = @import("solver").freq_solve.FreqSolver;

pub const Complex = types.Complex;

pub const Options = @import("requests").Ac;

/// AC small-signal sweep against `exc`, the whole deck's excitation: a
/// stacked-real `[re(0..n), im(0..n)]` vector over the circuit unknowns, built
/// once from every source card carrying an `AC` spec (builder.zig
/// `acExcitation`). A V card lands on its BRANCH row — its branch equation is
/// v_p - v_n - V = 0, so rhs[branch] = V_ac, and driving the clamped node row
/// instead yields identically zero response — an I card on its two node rows.
/// An empty `exc` is a deck with no AC source: zero excitation, zero response.
///
/// Caller owns the output: freqs[n_points], resp[probes.len * n_points]
/// flat, probe-major (resp[p * n_points + k]). No per-point allocation.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    exc: []const f64,
    probes: []const u32,
    freqs: []f64,
    resp: []Complex,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points = freqs.len;
    std.debug.assert(resp.len == probes.len * n_points);
    std.debug.assert(exc.len == nn or exc.len == 0);

    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    const rhs = try allocator.alloc(f64, nn);
    defer allocator.free(rhs);

    root.zeroSimd(rhs);
    if (exc.len == nn) @memcpy(rhs, exc);

    const omegas = try allocator.alloc(f64, n_points);
    defer allocator.free(omegas);
    options.sweep.fill(freqs, omegas);

    var stream = try freq.Stream.init(allocator, &fs, omegas, rhs, false);
    defer stream.deinit(allocator);
    while (try stream.next(ckt)) |pt| {
        for (probes, 0..) |node, p| {
            resp[p * n_points + pt.k] = .{ .re = pt.x[node], .im = pt.x[n + node] };
        }
    }
}

/// Contract entry: the deck's own excitation (every `AC`-carrying source at
/// its own magnitude and phase), complex response at every probe. Data layout:
/// point-major (freq, probes...) with (re, im) per variable.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    // Everything `defer`-freed here is scratch by construction, and
    // `ctx.allocator` is a results arena whose free() is a no-op — so on `a`
    // the probe-major `resp`, the sweep's whole lane workspace and the
    // point-major `data` were three live copies of the same payload for the
    // rest of the run. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator;
    const x_op = ctx.x_op;
    const n_points = opts.sweep.count();

    const freqs = try scratch.alloc(f64, n_points);
    defer scratch.free(freqs);
    const resp = try scratch.alloc(Complex, ctx.probes.len * n_points);
    defer scratch.free(resp);

    try sweep(ctx.circuit, x_op, ctx.ac_drive, ctx.probes, freqs, resp, opts, scratch);

    const names = try root.probeNames(ctx, "frequency");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "frequency" literal
        a.free(names);
    }
    const ncols = names.len;
    const data = try a.alloc(f64, n_points * ncols * 2);
    for (0..n_points) |p| {
        const row = data[p * ncols * 2 ..][0 .. ncols * 2];
        row[0] = freqs[p];
        row[1] = 0;
        for (0..ctx.probes.len) |idx| {
            const c = resp[idx * n_points + p];
            row[(idx + 1) * 2] = c.re;
            row[(idx + 1) * 2 + 1] = c.im;
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
