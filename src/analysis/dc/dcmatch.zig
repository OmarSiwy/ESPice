//! DC mismatch analysis (Spectre `dcmatch`): Pelgrom-model random offset at
//! the operating point via adjoint sensitivity.
//!
//!   1. OP solve (reuse or cold-start) — keeps the factored J in the workspace.
//!   2. Adjoint solve J^T * lambda = e_out  (one transpose back-substitution).
//!   3. Per-parameter FD stamp: perturb p_d, re-eval F(x_op), finite-difference
//!      dF/dp_d, dot with lambda -> dy/dp_d.
//!   4. Accumulate sigma^2(y) = sum (dy/dp_d)^2 * sigma^2(dp_d).
//!   5. Report 3-sigma offset + ranked contribution table.
//!
//! Pelgrom sigma^2(dp) = A_P^2 / (W*L).  When a ParamRef carries nonzero
//! pelgrom_ap and area_wl the real coefficient is used; otherwise falls back
//! to unit variance.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;

const W = std.simd.suggestVectorLength(f64) orelse 8;

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// null -> the last probe node.
    output_node: ?u32 = null,
};

pub const Contribution = struct {
    device_name: []const u8,
    device_index: u32,
    param_name: []const u8,
    sensitivity: f64,
    variance_contrib: f64,
};

pub const MismatchResult = struct {
    contributions: []Contribution,
    total_sigma: f64,
};

// -------------------------------------------------------------------------
// Pelgrom variance
// -------------------------------------------------------------------------

/// Compute per-parameter mismatch sigma from Pelgrom coefficients.
/// Returns sigma (not sigma^2).
inline fn pelgromSigma(ref: root.ParamRef) f64 {
    if (ref.pelgrom_ap > 0 and ref.area_wl > 0) {
        // sigma^2 = A_P^2 / (W*L)  =>  sigma = A_P / sqrt(W*L)
        return ref.pelgrom_ap / @sqrt(ref.area_wl);
    }
    // ponytail: unit variance fallback — no Pelgrom data on this param
    return 1.0;
}

// -------------------------------------------------------------------------
// FD parameter-derivative stamps
// -------------------------------------------------------------------------

/// Finite-difference dF/dp: perturb p, re-eval F(x_op), compute
/// (F_pert - F_nom) / delta. Returns the adjoint dot -lambda^T * dF/dp.
fn fdSensitivity(
    ckt: *root.Circuit,
    x_op: []const f64,
    lambda: []const f64,
    rhs_nom: []const f64,
    param: root.ParamRef,
) !f64 {
    const n: usize = ckt.n;
    const orig: f64 = param.get();
    const delta_req = 1e-6 * @abs(orig) + 1e-12;

    param.set(orig + delta_req);
    // The step the parameter ACTUALLY took — an f32-typed field rounds it.
    const delta = param.get() - orig;
    defer {
        param.set(orig);
        ckt.recompute() catch unreachable; // restores the checked original parameter
    }
    try ckt.recompute();

    ckt.eval(x_op, 0);

    // dF/dp = (rhs_pert - rhs_nom) / delta, then dot with -lambda
    // Sensitivity = -lambda^T * dF/dp
    if (delta == 0) return 0;

    const inv_delta = 1.0 / delta;
    const V = @Vector(W, f64);
    const inv_v: V = @splat(inv_delta);
    var dot: f64 = 0;
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const rp: V = ckt.rhs[i..][0..W].*;
        const rn: V = rhs_nom[i..][0..W].*;
        const lv: V = lambda[i..][0..W].*;
        const df: V = (rp - rn) * inv_v;
        dot += @reduce(.Add, lv * df);
    }
    while (i < n) : (i += 1) {
        const df = (ckt.rhs[i] - rhs_nom[i]) * inv_delta;
        dot += lambda[i] * df;
    }

    return -dot;
}

// -------------------------------------------------------------------------
// Core solve
// -------------------------------------------------------------------------

// GPU batch dispatch: not beneficial here. The inner loop is N FD parameter
// perturbations (re-eval + adjoint dot), not N independent Newton solves.
// The single OP solve and single adjoint solve are already covered by the
// scalar GPU path. Batch Newton (solve_batch) has no leverage.

pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    output_node: u32,
    allocator: std.mem.Allocator,
) !MismatchResult {
    const n: usize = ckt.n;
    const refs = try ckt.collectParams();
    if (refs.len == 0) return .{
        .contributions = &.{},
        .total_sigma = 0,
    };

    // ponytail: retain only lambda, e_out and rhs_nom; store dF/dp if a caller needs it.
    const arena = try allocator.alloc(f64, 3 * n);
    defer allocator.free(arena);
    const lambda = arena[0..n];
    const e_out = arena[n .. 2 * n];
    const rhs_nom = arena[2 * n .. 3 * n];

    const ws = try ckt.workspace();
    ckt.eval(x_op, 0);

    // ponytail: the nominal snapshot is a disjoint bulk copy.
    @memcpy(rhs_nom, ckt.rhs[0..n]);

    try ws.slv.factor(ckt.g_vals);

    // Adjoint solve: J^T * lambda = e_out
    root.zeroSimd(e_out[0..n]);
    e_out[output_node] = 1.0;
    ws.slv.solveT(e_out[0..n], lambda[0..n]);

    // Per-parameter FD sensitivity + mismatch accumulation
    const contributions = try allocator.alloc(Contribution, refs.len);
    errdefer allocator.free(contributions);

    var total_var: f64 = 0;
    for (refs, contributions) |ref, *contrib| {
        const sens = try fdSensitivity(ckt, x_op, lambda, rhs_nom, ref);

        const sigma_p = pelgromSigma(ref);
        const var_contrib = sens * sens * sigma_p * sigma_p;
        total_var += var_contrib;

        contrib.* = .{
            .device_name = ref.device_type,
            .device_index = ref.index,
            .param_name = ref.param_name,
            .sensitivity = sens,
            .variance_contrib = var_contrib,
        };
    }

    // Sort contributions descending by variance_contrib (design-actionable ranking)
    std.mem.sort(Contribution, contributions, {}, struct {
        fn lessThan(_: void, a: Contribution, b: Contribution) bool {
            return b.variance_contrib < a.variance_contrib;
        }
    }.lessThan);

    return .{
        .contributions = contributions,
        .total_sigma = @sqrt(total_var),
    };
}

// -------------------------------------------------------------------------
// Contract entry point
// -------------------------------------------------------------------------

pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const ckt = ctx.circuit;

    const output_node = opts.output_node orelse blk: {
        if (ctx.probes.len == 0) return error.NoOutputNode;
        break :blk ctx.probes[ctx.probes.len - 1];
    };

    const x_op = ctx.x_op orelse blk: {
        const x = try a.alloc(f64, ckt.n);
        errdefer a.free(x);
        const r = try @import("op.zig").solve(ckt, x, .{ .tol = opts.tol });
        if (!r.converged) return error.OpDidNotConverge;
        break :blk x;
    };
    defer if (ctx.x_op == null) a.free(x_op);

    const res = try solve(ckt, x_op, output_node, a);
    defer a.free(res.contributions);

    const n_contribs = res.contributions.len;
    const ncols = 1 + n_contribs;
    const names = try a.alloc([]const u8, ncols);
    errdefer a.free(names);
    names[0] = "total_3sigma";

    var done: usize = 0;
    errdefer for (names[1..][0..done]) |s| a.free(s);
    for (res.contributions, names[1..]) |c, *name| {
        name.* = try std.fmt.allocPrint(a, "{s}#{d}.{s}", .{ c.device_name, c.device_index, c.param_name });
        done += 1;
    }

    const data = try a.alloc(f64, ncols);
    data[0] = 3.0 * res.total_sigma;
    for (res.contributions, data[1..]) |c, *out| out.* = c.sensitivity;

    return .{
        .plotname = "DC Mismatch",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "pelgromSigma — real coefficients" {
    const ref = root.ParamRef{
        .ptr = undefined,
        .device_type = "nmos",
        .param_name = "vth0",
        .index = 0,
        .is_instance = false,
        .primary = false,
        .pelgrom_ap = 4e-3, // 4 mV·um
        .area_wl = 1e-12, // 1 um^2
    };
    const sigma = pelgromSigma(ref);
    // sigma = 4e-3 / sqrt(1e-12) = 4e-3 / 1e-6 = 4000
    try std.testing.expectApproxEqRel(sigma, 4e3, 1e-12);
}

test "pelgromSigma — unit fallback when pelgrom_ap is zero" {
    const ref = root.ParamRef{
        .ptr = undefined,
        .device_type = "nmos",
        .param_name = "vth0",
        .index = 0,
        .is_instance = false,
        .primary = false,
        .pelgrom_ap = 0,
        .area_wl = 1e-12,
    };
    try std.testing.expectEqual(pelgromSigma(ref), 1.0);
}

test "pelgromSigma — unit fallback when area_wl is zero" {
    const ref = root.ParamRef{
        .ptr = undefined,
        .device_type = "nmos",
        .param_name = "vth0",
        .index = 0,
        .is_instance = false,
        .primary = false,
        .pelgrom_ap = 4e-3,
        .area_wl = 0,
    };
    try std.testing.expectEqual(pelgromSigma(ref), 1.0);
}

test "pelgromSigma — both zero gives unit fallback" {
    const ref = root.ParamRef{
        .ptr = undefined,
        .device_type = "nmos",
        .param_name = "vth0",
        .index = 0,
        .is_instance = false,
        .primary = false,
    };
    try std.testing.expectEqual(pelgromSigma(ref), 1.0);
}
