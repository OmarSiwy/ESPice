//! S-parameter sweep: one eval() linearizes (the planes are G and C), the
//! port z0 terminations are stamped into a dense G copy, then every
//! frequency point is one FreqSolver factor + one solve per port.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");
const FreqSolver = root.solvers.freq_solve.FreqSolver;
const freq = @import("../helper/freq.zig");

pub const Complex = freq.Complex;

/// A port is a netlist vsource: `node` its + terminal, `branch` its MNA
/// branch-current unknown. The sweep turns each into a Thevenin source with
/// series z0 by adding −z0 to the branch row diagonal (branch equation becomes
/// v_p − v_n − z0·i_br = V_s), so un-excited ports terminate in z0 instead of
/// clamping their node.
pub const Port = struct {
    node: u32,
    branch: u32,
    z0: f64 = 50.0,
};

pub const SweepType = enum { log, linear };

pub const Options = struct {
    tol: converger.Tolerances = .{},
    f_start: f64,
    f_stop: f64,
    n_points: u16 = 50,
    sweep_type: SweepType = .log,
    /// Explicit port list. Empty means one port at the drive source
    /// (ctx.source_node / ctx.source_branch) when running via the contract.
    ports: []const Port = &.{},
};

/// Caller owns the output: freqs[n_points] and the flat S-matrix stack
/// s[n_points * n_ports²], point-major — S(row,col) at frequency point fi is
/// s[fi * n_ports² + row * n_ports + col]. No per-point allocation.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    ports: []const Port,
    freqs: []f64,
    s: []Complex,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    const n_ports: usize = ports.len;
    std.debug.assert(freqs.len == options.n_points);
    std.debug.assert(s.len == freqs.len * n_ports * n_ports);

    // Linearize: one eval, dense copies of the planes. The port termination
    // is an analysis-side modification of G, so it goes on the copy —
    // initDense takes ownership of both.
    ckt.eval(x_op, 0);
    const g = try allocator.alloc(f64, n * n);
    ckt.denseG(g);
    const c = allocator.alloc(f64, n * n) catch |err| {
        allocator.free(g);
        return err;
    };
    ckt.denseC(c);

    // Series z0 inside each port source: branch row gains −z0·i_br.
    for (ports) |port| {
        const br: usize = port.branch;
        g[br * n + br] -= port.z0;
    }

    var fs = try FreqSolver.initDense(allocator, @intCast(n), g, c);
    defer fs.deinit(allocator);

    const nn = 2 * n;
    const rhs = try allocator.alloc(f64, nn);
    defer allocator.free(rhs);
    const x_work = try allocator.alloc(f64, nn);
    defer allocator.free(x_work);

    for (0..options.n_points) |fi| {
        const f = genFreq(options, fi);
        try fs.setOmega(2.0 * std.math.pi * f);

        const s_mat = s[fi * n_ports * n_ports ..][0 .. n_ports * n_ports];

        for (0..n_ports) |p| {
            // Unit source voltage on port p only: a_p = 1/(2√z0_p), a_k = 0 (k≠p).
            @memset(rhs, 0);
            rhs[ports[p].branch] = 1.0;
            try fs.solveRhs(rhs, x_work);

            const a_p = 1.0 / (2.0 * @sqrt(ports[p].z0));

            for (0..n_ports) |k| {
                const node_k: usize = ports[k].node;
                const br_k: usize = ports[k].branch;
                const z0_k = ports[k].z0;

                const v_k = if (node_k == root.GROUND) Complex.zero else Complex{
                    .re = x_work[node_k],
                    .im = x_work[n + node_k],
                };
                // i into the DUT = −i_branch (branch stamps F_p = +i_br).
                const i_k = Complex{ .re = -x_work[br_k], .im = -x_work[n + br_k] };
                const b_k = v_k.sub(i_k.scale(z0_k)).scale(1.0 / (2.0 * @sqrt(z0_k)));

                s_mat[k * n_ports + p] = b_k.scale(1.0 / a_p);
            }
        }

        freqs[fi] = f;
    }
}

fn genFreq(options: Options, k: usize) f64 {
    return switch (options.sweep_type) {
        .log => freq.logSweepFreq(options.f_start, options.f_stop, options.n_points, @intCast(k)),
        .linear => blk: {
            const frac = if (options.n_points > 1) @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(options.n_points - 1)) else 0;
            break :blk options.f_start + frac * (options.f_stop - options.f_start);
        },
    };
}

/// Contract entry: opts.ports (or the single drive source as port 1),
/// full S-matrix per frequency. Data layout: point-major
/// (frequency, S11, S12, ..., Snn) with (re, im) per variable.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    const one_port = [_]Port{.{ .node = ctx.source_node, .branch = ctx.source_branch }};
    const ports: []const Port = if (opts.ports.len > 0) opts.ports else &one_port;
    const n_ports = ports.len;
    const n_s = n_ports * n_ports;
    const n_points: usize = opts.n_points;

    const freqs = try a.alloc(f64, n_points);
    defer a.free(freqs);
    const s = try a.alloc(Complex, n_points * n_s);
    defer a.free(s);
    try sweep(ctx.circuit, x_op, ports, freqs, s, opts, a);

    const names = try a.alloc([]const u8, 1 + n_s);
    names[0] = "frequency";
    for (0..n_ports) |i| for (0..n_ports) |j| {
        names[1 + i * n_ports + j] = try std.fmt.allocPrint(a, "S{d}{d}", .{ i + 1, j + 1 });
    };
    const ncols = names.len;
    const data = try a.alloc(f64, n_points * ncols * 2);
    for (0..n_points) |fi| {
        const row = data[fi * ncols * 2 ..][0 .. ncols * 2];
        row[0] = freqs[fi];
        row[1] = 0;
        for (s[fi * n_s ..][0..n_s], 0..) |sv, k| {
            row[(1 + k) * 2] = sv.re;
            row[(1 + k) * 2 + 1] = sv.im;
        }
    }

    return .{
        .plotname = "S-Parameter Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}
