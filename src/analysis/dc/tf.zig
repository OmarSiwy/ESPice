//! DC transfer function (`.tf`): one dense LU of the linearized G, then a
//! forward solve for the gain and input resistance and a transpose solve on
//! the same factors for the output resistance.
const std = @import("std");
const root = @import("../types.zig");
const dense_lu = @import("solver").dense_lu;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Tf;

/// The three `.tf` results, in the output's units (V/V, A/V, V/A or A/A for
/// the gain; ohms for both resistances).
pub const Values = struct {
    gain: f64,
    input_resistance: f64,
    output_resistance: f64,
};

/// DC transfer function at the operating point `x_op`. The gain and Rin come
/// from a unit drive on the input, Rout from the adjoint solve with e_out.
/// Rin is +inf when the unit drive moves no input-branch current. Returns
/// error.SingularMatrix when G is singular.
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    options: Options,
    input_branch: u32,
    output_node: u32,
    output_neg: u32,
    allocator: std.mem.Allocator,
) !Values {
    const n: usize = ckt.n;

    ckt.eval(x_op, 0);

    const buf = try allocator.alloc(f64, n * n + n);
    defer allocator.free(buf);
    const jac = buf[0 .. n * n];
    const x = buf[n * n ..];
    const piv = try allocator.alloc(u32, n);
    defer allocator.free(piv);

    ckt.denseG(jac);
    try dense_lu.factorize(n, jac, piv);

    // A V card drives its own branch row. An I card has no branch row, so the
    // unit current goes into its node pair (`.tf v(out) Iin`), which is what
    // the card itself stamps.
    root.zeroSimd(x);
    if (options.input_nodes) |pair| {
        if (pair[0] != root.GROUND) x[pair[0]] = -1.0;
        if (pair[1] != root.GROUND) x[pair[1]] = 1.0;
    } else x[input_branch] = 1.0;
    dense_lu.solveFactored(n, jac, piv, x, x);

    const gain = outputOf(x, options, output_node, output_neg);
    const input_resistance = if (options.input_nodes) |pair| blk: {
        // A current drive: the input immittance is the voltage the unit
        // current develops across the card's own terminals.
        const vp = if (pair[0] != root.GROUND) x[pair[0]] else 0;
        const vn = if (pair[1] != root.GROUND) x[pair[1]] else 0;
        break :blk vn - vp;
    } else blk: {
        // Branch stamps F_p = +i_br, so the current delivered into the
        // circuit is -i_br and Rin = dV_source / dI_delivered = 1 / (-di_br).
        const di = x[input_branch];
        break :blk if (di != 0) -1.0 / di else std.math.inf(f64);
    };

    // Adjoint: J^T y = e_out, and Rout is y read back on the output.
    root.zeroSimd(x);
    if (options.output_branch) |br| x[br] = 1.0 else {
        x[output_node] = 1.0;
        if (output_neg != root.GROUND) x[output_neg] = -1.0;
    }
    dense_lu.solveFactoredT(n, jac, piv, x, x);

    return .{
        .gain = gain,
        .input_resistance = input_resistance,
        .output_resistance = outputOf(x, options, output_node, output_neg),
    };
}

/// The output read from `x`: a branch current (`i(Vmeasure)`) or a node
/// voltage (`v(a)`, or the difference `v(a,b)`).
fn outputOf(x: []const f64, options: Options, output_node: u32, output_neg: u32) f64 {
    if (options.output_branch) |br| return x[br];
    return x[output_node] - if (output_neg != root.GROUND) x[output_neg] else 0;
}

/// Contract entry: one real point (transfer_function, input_resistance,
/// output_resistance) at ctx.x_op.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const input_branch = opts.input_branch orelse ctx.source_branch;
    const res = try solve(ctx.circuit, ctx.x_op, opts, input_branch, opts.output_node, opts.output_neg, ctx.scratch_allocator);

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
