//! DC mismatch (Spectre `dcmatch`): the Pelgrom-model random offset of one
//! output at the operating point, by adjoint sensitivity. One factorization
//! and one transpose solve give lambda (J^T lambda = e_out); each parameter
//! then costs one finite-difference re-eval of F(x_op) and a dot with lambda.
//! The offset is sigma^2(y) = sum (dy/dp)^2 · sigma^2(p), with Pelgrom
//! sigma^2(p) = A_P^2 / (W·L).
const std = @import("std");
const root = @import("../types.zig");

const W = std.simd.suggestVectorLength(f64) orelse 8;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Dcmatch;

/// One parameter's share of the output variance.
pub const Contribution = struct {
    device_name: []const u8,
    device_index: u32,
    param_name: []const u8,
    /// dy/dp, in output units per parameter unit.
    sensitivity: f64,
    /// (dy/dp)^2 · sigma^2(p).
    variance_contrib: f64,
};

/// The mismatch of one output.
pub const MismatchResult = struct {
    /// Sorted by descending variance share; owned by the `solve` allocator.
    contributions: []Contribution,
    total_sigma: f64,
};

/// The parameter's mismatch sigma (not sigma^2): A_P / sqrt(W·L).
inline fn pelgromSigma(ref: root.ParamRef) f64 {
    if (ref.pelgrom_ap > 0 and ref.area_wl > 0) return ref.pelgrom_ap / @sqrt(ref.area_wl);
    // ponytail: unit sigma when the parameter carries no Pelgrom data; wire
    // a per-model coefficient when a deck needs a real one.
    return 1.0;
}

/// dy/dp = -lambda^T · dF/dp, with dF/dp the forward difference of F(x_op)
/// against `rhs_nom`. Restores the parameter before returning. Returns 0 when
/// the step rounds away or the perturbation would change the topology.
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

    // Only this parameter moves and temperature does not, so re-deriving its
    // own device type is the whole recompute (Circuit.recomputeType).
    param.set(orig + delta_req);
    // The step the parameter actually took: an f32 field rounds it.
    const delta = param.get() - orig;
    defer {
        param.set(orig);
        ckt.recomputeType(param.type) catch unreachable; // restores the checked original parameter
    }
    // As in sens.zig: the +1e-12 floor un-collapses an internal node whose
    // parasitic is nominally 0, and the frozen pattern has no row for it. The
    // derivative is unrepresentable, not small.
    ckt.recomputeType(param.type) catch |e| switch (e) {
        error.TopologyChanged => return 0,
    };

    ckt.eval(x_op, 0);
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

/// Every collected parameter's contribution to the mismatch of `output_node`
/// at `x_op`. Leaves the circuit's planes at the last perturbed eval.
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

    const arena = try allocator.alloc(f64, 3 * n);
    defer allocator.free(arena);
    const lambda = arena[0..n];
    const e_out = arena[n .. 2 * n];
    const rhs_nom = arena[2 * n .. 3 * n];

    const ws = try ckt.workspace();
    ckt.eval(x_op, 0);

    @memcpy(rhs_nom, ckt.rhs[0..n]);

    try ws.slv.factor(ckt.g_vals);

    root.zeroSimd(e_out[0..n]);
    e_out[output_node] = 1.0;
    ws.slv.solveT(e_out[0..n], lambda[0..n]);

    const contributions = try allocator.alloc(Contribution, refs.len);
    errdefer allocator.free(contributions);

    var total_var: f64 = 0;
    for (refs, contributions, 0..) |ref, *contrib, index| {
        if (index != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = index, .total = refs.len });
        const sens = try fdSensitivity(ckt, x_op, lambda, rhs_nom, ref);

        const sigma_p = pelgromSigma(ref);
        const var_contrib = sens * sens * sigma_p * sigma_p;
        total_var += var_contrib;

        contrib.* = .{
            .device_name = ckt.typeName(ref.type),
            .device_index = ref.index,
            .param_name = ref.param_name,
            .sensitivity = sens,
            .variance_contrib = var_contrib,
        };
    }

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

/// Contract entry: one real point, `total_3sigma` followed by each
/// parameter's sensitivity (`<type>#<index>.<param>`) in descending variance
/// order.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const ckt = ctx.circuit;
    const scratch = ctx.scratch_allocator;
    const res = try solve(ckt, ctx.x_op, opts.output_node, scratch);
    defer scratch.free(res.contributions);

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

/// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .pelgromSigma = pelgromSigma,
} else {};
