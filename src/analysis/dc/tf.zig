//! DC transfer function (`.tf`): `.dcxf`'s readout for one source. One
//! sparse factorization of the linearized G serves a forward solve with the
//! input's unit excitation (gain and Rin) and an adjoint solve with e_out
//! (Rout).
//! Cites ngspice tfanal.c and dev/analysis/tf.md (where a current output's
//! Rout departs from ngspice's 1e20 clamp).
const std = @import("std");
const root = @import("../types.zig");
const xf = @import("xf.zig");

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Tf;

/// The three `.tf` results, in the output's units (V/V, A/V, V/A or A/A for
/// the gain; ohms for both resistances).
pub const Values = struct {
    gain: f64,
    input_resistance: f64,
    output_resistance: f64,
};

/// DC transfer function at the operating point `x_op`, from the source on
/// `input_branch` (unused when `options.input_nodes` names an I card) to
/// `options`' output. The gain and Rin come from a unit drive on the input,
/// Rout from the adjoint solve with e_out. Rin, and Rout for a current
/// output, are `xf.infinite` (1e20, ngspice's tfanal.c value) when the unit
/// drive moves no branch current. Overwrites the circuit's planes with the
/// eval at `x_op` and its workspace's factorization. Returns
/// error.SingularMatrix when G is singular once SparseLu has pinned its void
/// unknowns (#160), and error.OutOfMemory.
pub fn solve(ckt: *root.Circuit, x_op: []const f64, options: Options, input_branch: u32, allocator: std.mem.Allocator) !Values {
    const n: usize = ckt.n;
    std.debug.assert(x_op.len >= n);
    const ws = try ckt.workspace();
    ckt.eval(x_op, 0);
    try ws.slv.factor(ckt.g_vals, ckt.solver_execution);

    const buf = try allocator.alloc(f64, 2 * n);
    defer allocator.free(buf);
    const rhs = buf[0..n];
    const x = buf[n..];
    const out: xf.Output = .{ .node = options.output_node, .neg = options.output_neg, .branch = options.output_branch };
    // A V card drives its own branch row. An I card has no branch row, so the
    // unit current goes into its node pair (`.tf v(out) Iin`).
    const src: @import("core").query.XfSource = if (options.input_nodes) |pair|
        .{ .name = "", .branch = null, .nodes = pair }
    else
        .{ .name = "", .branch = input_branch };

    root.zeroSimd(rhs);
    xf.excite(src, rhs);
    ws.slv.solve(rhs, x);
    const gain = out.read(x, n).re;
    const input_resistance = xf.immittance(src, x, n)[0].re;

    // Adjoint: J^T y = e_out. A voltage output reads Rout back on itself; a
    // current output reads the resistance its sensing source sees, as Rin
    // does for a V card: y[br] = (J^-1)[br][br] is the branch current a unit
    // volt on that source moves. ngspice's tfanal.c takes 1/MAX(1e-20, y[br]),
    // which is 1e20 for every passive circuit (dev/analysis/tf.md).
    root.zeroSimd(rhs);
    out.seed(rhs);
    ws.slv.solveT(rhs, x);
    const output_resistance = if (out.branch) |br|
        xf.immittance(.{ .name = "", .branch = br }, x, n)[0].re
    else
        out.read(x, n).re;
    return .{
        .gain = gain,
        .input_resistance = input_resistance,
        .output_resistance = output_resistance,
    };
}

/// Contract entry: one real point (transfer_function, input_resistance,
/// output_resistance) at ctx.x_op.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const input_branch = opts.input_branch orelse ctx.source_branch;
    const res = try solve(ctx.circuit, ctx.x_op, opts, input_branch, ctx.scratch_allocator);

    const names = try a.dupe([]const u8, &.{ "transfer_function", "input_resistance", "output_resistance" });
    errdefer a.free(names); // entries are literals
    const data = try a.dupe(f64, &.{ res.gain, res.input_resistance, res.output_resistance });
    return .{
        .plotname = "Transfer Function",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}
