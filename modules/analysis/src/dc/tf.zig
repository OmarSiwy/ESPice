//! DC transfer function: dense factorizeSolve on the linearized G, one
//! forward solve (gain, Rin) + one transpose/adjoint solve (Rout). The
//! planes are the linearization — one eval() at the op.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");
const dense_lu = root.solvers.dense_lu;

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// Branch-current unknown of the input vsource (its row is v_p − v_n − V = 0).
    /// null → ctx.source_branch (the first source's branch).
    input_branch: ?u32 = null,
    /// null → the last probe node.
    output_node: ?u32 = null,
};

pub const Values = struct {
    gain: f64,
    input_resistance: f64,
    output_resistance: f64,
};

/// DC transfer function at a precomputed operating point x_op.
/// Gain and Rin come from a unit excitation on the input source's branch row
/// (dV_in = 1); exciting the clamped + node instead gives identically zero.
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

    // ponytail: one bulk alloc for all work buffers
    const arena = try allocator.alloc(f64, 3 * n * n + 2 * n);
    defer allocator.free(arena);
    const jac = arena[0 .. n * n];
    const jac_work = arena[n * n .. 2 * n * n];
    const jac_t = arena[2 * n * n .. 3 * n * n];
    const rhs = arena[3 * n * n ..][0..n];
    const v_fwd = arena[3 * n * n + n ..][0..n];
    ckt.denseG(jac);

    // Forward solve: J * v_fwd = e_branch (unit source-voltage perturbation)
    @memset(rhs, 0);
    rhs[input_branch] = 1.0;
    @memcpy(jac_work, jac);
    try dense_lu.factorizeSolve(n, jac_work, rhs, v_fwd);

    const gain = v_fwd[output_node];
    // Branch stamps F_p = +i_br: current delivered into the circuit is −i_br.
    // Rin = dV_source / dI_delivered = 1 / (−di_br).
    const di = v_fwd[input_branch];
    const input_resistance = if (di != 0) -1.0 / di else std.math.inf(f64);

    // Adjoint solve: J^T * v_adj = e_output → Rout = v_adj[output]
    for (0..n) |row| {
        for (0..n) |col| jac_t[row * n + col] = jac[col * n + row];
    }

    @memset(rhs, 0);
    rhs[output_node] = 1.0;
    try dense_lu.factorizeSolve(n, jac_t, rhs, v_fwd);
    const output_resistance = v_fwd[output_node];

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
    const data = try a.dupe(f64, &.{ res.gain, res.input_resistance, res.output_resistance });
    return .{
        .plotname = "Transfer Function",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}
