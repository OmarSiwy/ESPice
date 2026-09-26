//! S-parameter sweep. One linearization gives G and C, the port z0
//! terminations go into the frequency solver's copy of G, and each frequency
//! is one lane of `freq.Stream` with one right-hand side per port.
//!
//! Wave variables (Kurokawa power waves):
//!   a_k = (V_k + z0_k·I_k) / (2√z0_k)
//!   b_k = (V_k - z0_k·I_k) / (2√z0_k)
//! where I_k = −i_br_k (branch stamps F_p = +i_br, so the DUT current is
//! negated). Driving port p with a unit source voltage (rhs[b_p] = 1) gives
//! a_p = 1/(2√z0_p) and a_j = 0 elsewhere, so column p of S(ω) is b_j / a_p.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const Complex = @import("core").numerics.Complex;
const FreqSolver = @import("solver").freq_solve.FreqSolver;

/// A port is a netlist vsource: `node` is its + terminal, `branch` its MNA
/// branch-current unknown. Adding −z0 to the branch row diagonal turns it into
/// a Thevenin source with series z0 (v_p − v_n − z0·i_br = V_s), so an
/// undriven port terminates in z0 instead of clamping its node.
const Port = @import("core").query.Port;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Sp;

/// Contract entry: opts.ports (or the deck's drive source as port 1), the
/// full S-matrix per frequency. Complex, point-major
/// (frequency, S11, S12, ..., Snn).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const ckt = ctx.circuit;
    const n: usize = ckt.n;
    const nn = 2 * n;

    const one_port = [_]Port{.{ .node = ctx.source_node, .branch = ctx.source_branch }};
    const ports: []const Port = if (opts.ports.len > 0) opts.ports else &one_port;
    const n_ports = ports.len;
    const n_points: usize = opts.sweep.count();

    const names = try a.alloc([]const u8, 1 + n_ports * n_ports);
    names[0] = "frequency";
    for (0..n_ports) |i| for (0..n_ports) |j| {
        // ngspice names the columns `S_<row>_<col>` (1-based) as UID_OTHER
        // (span.c:544-551), and its raw writer types every non-current UID
        // as a voltage, so the file spells them `v(S_1_1)`. Readers of an
        // ngspice raw look them up by that name.
        names[1 + i * n_ports + j] = try std.fmt.allocPrint(a, "v(S_{d}_{d})", .{ i + 1, j + 1 });
    };
    const row_len = names.len * 2;
    const data = try a.alloc(f64, n_points * row_len);

    var fs = try FreqSolver.fromCircuit(scratch, ckt, ctx.x_op);
    defer fs.deinit(scratch);
    // Series z0 inside each port source: the branch row gains −z0·i_br.
    for (ports) |port| fs.addDiagG(port.branch, -port.z0);

    const axis = try scratch.alloc(f64, 2 * n_points);
    defer scratch.free(axis);
    const freqs = axis[0..n_points];
    const omegas = axis[n_points..];
    opts.sweep.fill(freqs, omegas);

    // One unit drive per port, every one solved against each factorization.
    const rhs = try scratch.alloc(f64, n_ports * nn);
    defer scratch.free(rhs);
    root.zeroSimd(rhs);
    for (ports, 0..) |port, p| rhs[p * nn + port.branch] = 1.0;

    var stream = try freq.Stream.init(scratch, &fs, omegas, rhs, false);
    defer stream.deinit(scratch);
    while (try stream.next(ckt)) |pt| {
        const row = data[pt.k * row_len ..][0..row_len];
        row[0] = freqs[pt.k];
        row[1] = 0;
        for (ports, 0..) |port, p|
            writeColumn(n, ports, pt.x[p * nn ..][0..nn], 1.0 / (2.0 * @sqrt(port.z0)), row[2..], p);
    }

    return .{
        // The job name ngspice opens the plot under (span.c:599-601).
        .plotname = "SP Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}

/// Writes column p of S, driven with incident wave `a_p`, into the stacked
/// (re, im) S-matrix `s_row` of one frequency.
fn writeColumn(n: usize, ports: []const Port, x: []const f64, a_p: f64, s_row: []f64, p: usize) void {
    const n_ports = ports.len;
    for (ports, 0..) |port, k| {
        const node: usize = port.node;
        const br: usize = port.branch;
        const v_k = if (node == root.GROUND) Complex.zero else Complex{ .re = x[node], .im = x[n + node] };
        const i_k = Complex{ .re = -x[br], .im = -x[n + br] };
        const b_k = v_k.sub(i_k.scale(port.z0)).scale(1.0 / (2.0 * @sqrt(port.z0)));
        const s = b_k.scale(1.0 / a_p);
        const idx = (k * n_ports + p) * 2;
        s_row[idx] = s.re;
        s_row[idx + 1] = s.im;
    }
}
