//! Adjoint DC sensitivity (`.sens`): one factorization at the operating point
//! and one transpose solve give λ (J^T λ = e_out). Each parameter then costs
//! one re-eval of F(x_op) and a dot product, dy/dp = -λ^T · dF/dp with dF/dp
//! a forward difference, instead of a Newton solve per parameter.
const std = @import("std");
const root = @import("../types.zig");

const W = std.simd.suggestVectorLength(f64) orelse 8;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Sens;

const copySimd = root.copySimd;

/// Returns λ^T · (pert - nom) · inv_delta, the adjoint dot of a forward
/// difference, over `lambda.len` rows. Deterministic for a given target: the
/// summation order is fixed by the lane width, so `.sens` and `.dcmatch`
/// (which shares it) reproduce run to run.
/// Asserts that `pert` and `nom` are at least as long as `lambda`.
pub inline fn adjointFd(lambda: []const f64, pert: []const f64, nom: []const f64, inv_delta: f64) f64 {
    const n = lambda.len;
    std.debug.assert(pert.len >= n and nom.len >= n);
    // The difference is fused into the dot, so no n-element scratch is
    // written or reloaded. The W-lane accumulator, its left-to-right fold
    // and the scalar tail fix the order; the oracle test pins it bit for bit.
    const V = @Vector(W, f64);
    const id: V = @splat(inv_delta);
    var acc: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const lv: V = lambda[i..][0..W].*;
        const rp: V = pert[i..][0..W].*;
        const rn: V = nom[i..][0..W].*;
        acc += lv * ((rp - rn) * id);
    }
    const arr: [W]f64 = acc;
    var s: f64 = 0;
    for (arr) |v| s += v;
    while (i < n) : (i += 1) s += lambda[i] * ((pert[i] - nom[i]) * inv_delta);
    return s;
}

/// dV(output_node, output_neg)/dp for each of `params` at `x_op`, parallel to
/// `params` and owned by `allocator`. `x_op` is the executor's operating point
/// (the full OP ladder; a plain Newton here fails on circuits that need
/// stepping). Each parameter is restored before the next. Returns
/// error.ZeroDelta when a parameter's step rounds away entirely.
///
/// No `computeBaseline()`: the baseline would freeze the const-Jacobian
/// stamps (resistors) and mask the very perturbations being measured.
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    params: []const root.ParamRef,
    output_node: u32,
    output_neg: u32,
    allocator: std.mem.Allocator,
) ![]f64 {
    const n: usize = ckt.n;
    const ws = try ckt.workspace();

    ckt.evalNewton(x_op, 0);
    const rhs_nom = try allocator.alloc(f64, n);
    defer allocator.free(rhs_nom);
    copySimd(rhs_nom, ckt.rhs[0..n]);
    try ws.slv.factor(ckt.g_vals, ckt.solver_execution);

    const lambda = try allocator.alloc(f64, n);
    defer allocator.free(lambda);
    root.zeroSimd(lambda);
    lambda[output_node] = 1.0;
    // `v(a,b)`: the adjoint seed is the node difference.
    if (output_neg != root.GROUND) lambda[output_neg] = -1.0;
    ws.slv.solveT(lambda, lambda);

    const sens = try allocator.alloc(f64, params.len);
    errdefer allocator.free(sens);

    for (params, sens, 0..) |p, *out, index| {
        if (index != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = index, .total = params.len });
        const orig: f64 = p.get();
        const delta_req = 1e-6 * @abs(orig) + 1e-12;

        // Only this parameter moves and temperature does not, so re-deriving
        // its own device type is the whole recompute (Circuit.recomputeType).
        p.set(orig + delta_req);
        defer {
            p.set(orig);
            ckt.recomputeType(p.type) catch unreachable; // restores the checked original parameter
        }
        // A parameter whose nominal value collapses an internal node
        // (gummel_poon RC/RE = 0, mos1 RD/RS = 0, ...) is re-wired by the
        // +1e-12 floor in `delta_req`: `collapse` stops folding c' onto c, the
        // builder never allocated a distinct c', and the batch reports
        // TopologyChanged. The perturbed circuit has a node the frozen pattern
        // lacks, so the derivative is not representable; report 0 rather than
        // fail the analysis. ngspice never perturbs a topology parameter
        // (cktsens.c uses per-device analytic sensitivities, not a generic FD).
        ckt.recomputeType(p.type) catch |e| switch (e) {
            error.TopologyChanged => {
                out.* = 0;
                continue;
            },
        };

        // Difference against the step actually stored: an f32 parameter
        // rounds it, and the requested delta would give a wrong derivative,
        // not a small one.
        const delta = p.get() - orig;
        if (delta == 0) return error.ZeroDelta;

        ckt.evalNewton(x_op, 0);
        out.* = -adjointFd(lambda[0..n], ckt.rhs[0..n], rhs_nom, 1.0 / delta);
    }

    return sens;
}

/// Contract entry: one real point, one column per collected device parameter
/// holding dVout/dp. Columns carry ngspice's names (cktsens.c:224-238):
///   model parameter                  -> `<card>:<param>`   (r1:tc1)
///   principal instance parameter     -> `<card>`           (r1)
///   any other instance parameter     -> `<card>_<param>`   (r1_scale)
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const refs = try ctx.circuit.collectParams();
    const sens = try solve(ctx.circuit, ctx.x_op, refs, opts.output_node, opts.output_neg, scratch);
    defer scratch.free(sens);

    const names = try a.alloc([]const u8, refs.len);
    errdefer a.free(names);
    var done: usize = 0;
    errdefer for (names[0..done]) |s| a.free(s);
    for (refs, names) |ref, *name| {
        const card = root.CardRef.lookup(opts.cards, ref.type, ref.index);
        const dev = card orelse try std.fmt.allocPrint(scratch, "{s}#{d}", .{ ctx.circuit.typeName(ref.type), ref.index });
        defer if (card == null) scratch.free(dev);
        // `primary` rather than is_instance: ngspice's IF_PRINCIPAL flag lives
        // on the instance parameter table, but VerA puts every Verilog-A
        // `parameter` on Model, so `primary` is where that flag ends up. The
        // `v(...)` wrapper is ngspice's too: cktsens.c hands the raw writer a
        // UID_OTHER name, which types as a voltage, so readers of an ngspice
        // raw look the column up as `v(r1)`.
        name.* = if (ref.primary)
            try std.fmt.allocPrint(a, "v({s})", .{dev})
        else
            try std.fmt.allocPrint(a, "v({s}{s}{s})", .{ dev, if (ref.is_instance) "_" else ":", ref.param_name });
        done += 1;
    }
    const data = try a.dupe(f64, sens);

    return .{
        .plotname = "Sensitivity Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

/// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .W = W,
    .copySimd = copySimd,
} else {};
