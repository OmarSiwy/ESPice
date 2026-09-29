//! DC mismatch (Spectre `dcmatch`, HSPICE `.dcmatch`) and DC variation
//! sensitivity (HSPICE `.dcsens`) of one output at the operating point, by
//! adjoint sensitivity. One factorization and one transpose solve give
//! lambda (J^T lambda = e_out); each parameter then costs one
//! finite-difference re-eval of F(x_op) and a dot with lambda.
//! The parameters come in `Groups`: the deck's variation block, or every
//! parameter alone at its Pelgrom sigma, sigma^2(p) = A_P^2 / (W·L). The
//! offset is sigma^2(y) = sum over groups of (dy/dsigma_g)^2.
const std = @import("std");
const root = @import("../types.zig");

const W = std.simd.suggestVectorLength(f64) orelse 8;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Dcmatch;

const Variations = @import("core").query.Variations;

/// One group's share of the output variance.
pub const Contribution = struct {
    /// Index into the `Groups` the result was solved over.
    group: u32,
    /// dy/dsigma with a variation block; dy/dp per parameter without one.
    sensitivity: f64,
    /// Its square times the group's sigma squared.
    variance_contrib: f64,
};

/// The mismatch of one output.
pub const MismatchResult = struct {
    /// In group order; owned by the `solve` allocator.
    contributions: []Contribution,
    total_sigma: f64,
};

/// The parameter groups a mismatch or sensitivity analysis sums over:
/// `Variations` from the deck's variation block, or, without one, every
/// parameter of `Circuit.collectParams` alone, its column dy/dp and its
/// sigma the Pelgrom one.
pub const Groups = struct {
    starts: []const u32,
    list: []Member,
    sigmas: []f64,
    labels: []const []const u8,

    /// A parameter ordinal and the factor its dy/dp enters its group with:
    /// its one-sigma step, or 1 without a variation block.
    pub const Member = struct { param: u32, scale: f64 };

    /// Builds the groups over `refs`; free them with `deinit`.
    /// `error.InvalidVariation` when a group names a parameter past `refs`.
    pub fn init(a: std.mem.Allocator, refs: []const root.ParamRef, vars: Variations) !Groups {
        if (vars.starts.len == 0) {
            const starts = try a.alloc(u32, refs.len + 1);
            errdefer a.free(starts);
            const list = try a.alloc(Member, refs.len);
            errdefer a.free(list);
            const sigmas = try a.alloc(f64, refs.len);
            for (refs, starts[0..refs.len], list, sigmas, 0..) |r, *st, *m, *sg, i| {
                st.* = @intCast(i);
                m.* = .{ .param = @intCast(i), .scale = 1 };
                sg.* = pelgromSigma(r);
            }
            starts[refs.len] = @intCast(refs.len);
            return .{ .starts = starts, .list = list, .sigmas = sigmas, .labels = &.{} };
        }
        const list = try a.alloc(Member, vars.params.len);
        errdefer a.free(list);
        for (list, vars.params, vars.sigmas) |*m, p, sg| {
            if (p >= refs.len) return error.InvalidVariation;
            m.* = .{ .param = p, .scale = sg };
        }
        const sigmas = try a.alloc(f64, vars.starts.len - 1);
        @memset(sigmas, 1);
        return .{ .starts = try a.dupe(u32, vars.starts), .list = list, .sigmas = sigmas, .labels = vars.labels };
    }

    pub fn deinit(self: Groups, a: std.mem.Allocator) void {
        a.free(self.starts);
        a.free(self.list);
        a.free(self.sigmas);
    }

    pub fn count(self: Groups) usize {
        return self.starts.len - 1;
    }

    /// The parameters group `g` moves together.
    pub fn members(self: Groups, g: usize) []const Member {
        return self.list[self.starts[g]..self.starts[g + 1]];
    }

    /// The sigma group `g`'s column is multiplied by for its spread: 1 when
    /// the column is already per sigma.
    pub fn sigma(self: Groups, g: usize) f64 {
        return self.sigmas[g];
    }

    /// Group `g`'s column label, allocated in `a`: the variation label, or
    /// `<type>#<index>.<param>`.
    pub fn label(self: Groups, a: std.mem.Allocator, ckt: *const root.Circuit, refs: []const root.ParamRef, g: usize) ![]const u8 {
        if (self.labels.len != 0) return a.dupe(u8, self.labels[g]);
        const r = refs[self.list[g].param];
        return std.fmt.allocPrint(a, "{s}#{d}.{s}", .{ ckt.typeName(r.type), r.index, r.param_name });
    }
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

/// Each group's contribution to the mismatch of v(output_node) -
/// v(output_neg) at `x_op`, over `refs` (`Circuit.collectParams`). Leaves the
/// circuit's planes at the last perturbed eval.
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    output_node: u32,
    output_neg: u32,
    refs: []const root.ParamRef,
    groups: Groups,
    allocator: std.mem.Allocator,
) !MismatchResult {
    const n: usize = ckt.n;
    if (groups.count() == 0) return .{
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

    try ws.slv.factor(ckt.g_vals, ckt.solver_execution);

    root.zeroSimd(e_out[0..n]);
    e_out[output_node] = 1.0;
    // `v(a,b)`: the adjoint seed is the node difference.
    if (output_neg != root.GROUND) e_out[output_neg] = -1.0;
    ws.slv.solveT(e_out[0..n], lambda[0..n]);

    const contributions = try allocator.alloc(Contribution, groups.count());
    errdefer allocator.free(contributions);

    var total_var: f64 = 0;
    for (contributions, 0..) |*contrib, index| {
        if (index != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = index, .total = contributions.len });
        // The first member is not added to 0, which would turn a -0 into +0.
        var sens: f64 = 0;
        for (groups.members(index), 0..) |m, k| {
            const d = try fdSensitivity(ckt, x_op, lambda, rhs_nom, refs[m.param]) * m.scale;
            sens = if (k == 0) d else sens + d;
        }

        const sigma_p = groups.sigma(index);
        const var_contrib = sens * sens * sigma_p * sigma_p;
        total_var += var_contrib;

        contrib.* = .{
            .group = @intCast(index),
            .sensitivity = sens,
            .variance_contrib = var_contrib,
        };
    }

    return .{
        .contributions = contributions,
        .total_sigma = @sqrt(total_var),
    };
}

/// Contract entry: one real point, `total_3sigma` followed by each group's
/// sensitivity (`<type>#<index>.<param>`, or the variation label) in
/// descending variance order.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    return publish(ctx, opts.output_node, opts.output_neg, opts.variations, true);
}

/// `.dcsens`: DC sensitivity to the variation block's parameters.
pub const Sens = struct {
    pub const Options = @import("core").query.Dcsens;

    /// Contract entry: one real point, each group's dy/dsigma (dy/dp per
    /// parameter without a variation block) in group order.
    pub fn run(ctx: *const root.RunCtx, opts: Sens.Options) !root.Result {
        return publish(ctx, opts.output_node, opts.output_neg, opts.variations, false);
    }
};

/// Solves the groups and publishes them, as `.dcmatch` (`mismatch`: the
/// 3-sigma total first, variance-sorted) or `.dcsens`.
fn publish(ctx: *const root.RunCtx, output_node: u32, output_neg: u32, vars: Variations, mismatch: bool) !root.Result {
    const a = ctx.allocator;
    const ckt = ctx.circuit;
    const scratch = ctx.scratch_allocator;
    const refs = try ckt.collectParams();
    const groups = try Groups.init(scratch, refs, vars);
    defer groups.deinit(scratch);
    const res = try solve(ckt, ctx.x_op, output_node, output_neg, refs, groups, scratch);
    defer scratch.free(res.contributions);
    if (mismatch) std.mem.sort(Contribution, res.contributions, {}, struct {
        fn lessThan(_: void, x: Contribution, y: Contribution) bool {
            return y.variance_contrib < x.variance_contrib;
        }
    }.lessThan);

    const head: usize = @intFromBool(mismatch);
    const ncols = head + res.contributions.len;
    const names = try a.alloc([]const u8, ncols);
    errdefer a.free(names);
    if (mismatch) names[0] = "total_3sigma";

    var done: usize = 0;
    errdefer for (names[head..][0..done]) |s| a.free(s);
    for (res.contributions, names[head..]) |c, *name| {
        name.* = try groups.label(a, ckt, refs, c.group);
        done += 1;
    }

    const data = try a.alloc(f64, ncols);
    if (mismatch) data[0] = 3.0 * res.total_sigma;
    for (res.contributions, data[head..]) |c, *out| out.* = c.sensitivity;

    return .{
        .plotname = if (mismatch) "DC Mismatch" else "DC Sensitivity",
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
