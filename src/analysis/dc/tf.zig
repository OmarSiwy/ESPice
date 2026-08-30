//! DC transfer function: one LU factorization on the linearized G, then a
//! forward solve (gain, Rin) and a transpose solve (Rout) on the same factors.
//! Two solves, one factorization — the dense_lu factorize/solveFactored/solveFactoredT
//! API makes the explicit transpose unnecessary.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const dense_lu = @import("solvers").dense_lu;

const W = std.simd.suggestVectorLength(f64) orelse 8;

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// Branch-current unknown of the input vsource (its row is v_p - v_n - V = 0).
    /// null -> ctx.source_branch (the first source's branch).
    input_branch: ?u32 = null,
    /// null -> the last probe node.
    output_node: ?u32 = null,
};

pub const Values = struct {
    gain: f64,
    input_resistance: f64,
    output_resistance: f64,
};

/// DC transfer function at a precomputed operating point x_op.
/// Gain and Rin come from a unit excitation on the input source's branch row
/// (dV_in = 1); Rout from the adjoint (transpose) solve with e_out.
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    input_branch: u32,
    output_node: u32,
    allocator: std.mem.Allocator,
) !Values {
    const n: usize = ckt.n;

    // Linearize: one eval fills the G plane (ground equation row included).
    ckt.eval(x_op, 0);

    // ponytail: one bulk alloc — n*n (jac) + n (piv as u32, rounded) + 2*n (rhs + solution)
    const piv_f64s = (n * @sizeOf(u32) + @sizeOf(f64) - 1) / @sizeOf(f64);
    const arena = try allocator.alloc(f64, n * n + piv_f64s + 2 * n);
    defer allocator.free(arena);

    const jac = arena[0 .. n * n];
    const piv_bytes = std.mem.sliceAsBytes(arena[n * n ..][0..piv_f64s]);
    const piv: []u32 = @alignCast(std.mem.bytesAsSlice(u32, piv_bytes[0 .. n * @sizeOf(u32)]));
    const rhs = arena[n * n + piv_f64s ..][0..n];
    const x = arena[n * n + piv_f64s + n ..][0..n];

    ckt.denseG(jac);

    // Factorize once: PA = LU
    try dense_lu.factorize(n, jac, piv);

    // Forward solve: J * v = e[input_branch] -> gain + Rin
    root.zeroSimd(rhs);
    rhs[input_branch] = 1.0;
    dense_lu.solveFactored(n, jac, piv, rhs, x);

    const gain = x[output_node];
    // Branch stamps F_p = +i_br: current delivered into the circuit is -i_br.
    // Rin = dV_source / dI_delivered = 1 / (-di_br).
    const di = x[input_branch];
    const input_resistance = if (di != 0) -1.0 / di else std.math.inf(f64);

    // Adjoint solve: J^T * y = e[output_node] -> Rout = y[output_node]
    root.zeroSimd(rhs);
    rhs[output_node] = 1.0;
    dense_lu.solveFactoredT(n, jac, piv, rhs, x);
    const output_resistance = x[output_node];

    return .{
        .gain = gain,
        .input_resistance = input_resistance,
        .output_resistance = output_resistance,
    };
}

/// Contract entry: one point — gain, Rin, Rout at ctx.x_op.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const input_branch = opts.input_branch orelse ctx.source_branch;
    const output_node = opts.output_node orelse blk: {
        if (ctx.probes.len == 0) return error.NoOutputNode;
        break :blk ctx.probes[ctx.probes.len - 1];
    };

    const res = try solve(ctx.circuit, x_op, input_branch, output_node, a);

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
