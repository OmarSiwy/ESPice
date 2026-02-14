//! Adjoint DC sensitivity: one nominal OP solve + one transpose solve →
//! per-parameter cost is a single RHS eval + dot product, not a full Newton.
//!
//! Algorithm:
//!   1. Nominal OP solve → x_op, Jacobian J stays factored in workspace
//!   2. Adjoint solve: J^T · λ = e_out  (one transpose back-sub)
//!   3. Per parameter p:
//!      a. perturb p, re-eval F(x_op) → rhs_pert
//!      b. dF/dp ≈ (rhs_pert - rhs_nom) / delta   (FD on RHS only)
//!      c. dy/dp = -λ^T · dF/dp                    (one dot product)
//!
//! Cost: O(nnz + N_params * n) vs old O(N_params * Newton_iters * nnz).
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;

const W = std.simd.suggestVectorLength(f64) orelse 8;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const SensParam = struct {
    ptr: root.ParamRef,
    device_name: []const u8,
    param_name: []const u8,
};

pub const SensEntry = struct {
    device_name: []const u8,
    param_name: []const u8,
    sensitivity: f64,
};

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// null → the last probe node.
    output_node: ?u32 = null,
};

pub const SolveResult = struct {
    entries: []SensEntry,
    op_value: f64,

    pub fn deinit(self: *SolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }
};

const copySimd = root.copySimd;

/// λ^T · dF/dp with the difference fused in: dF/dp = (pert - nom) * inv_delta
/// never leaves registers, so there is no n-element scratch and no reload.
/// Grouping, lane width, the explicit left-to-right lane fold and the scalar
/// tail are the ones the separate dot used. dcmatch's per-block `@reduce`
/// reduction order is deliberately different and must not be substituted here.
inline fn adjointFd(lambda: []const f64, pert: []const f64, nom: []const f64, inv_delta: f64) f64 {
    const n = lambda.len;
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
    // ponytail: reduce SIMD accumulator to scalar via array extract
    // (@reduce would work but this is explicit and portable)
    const arr: [W]f64 = acc;
    var s: f64 = 0;
    for (arr) |v| s += v;
    while (i < n) : (i += 1) s += lambda[i] * ((pert[i] - nom[i]) * inv_delta);
    return s;
}

// ---------------------------------------------------------------------------
// Core solver — adjoint method
// ---------------------------------------------------------------------------

/// Adjoint DC sensitivity: nominal solve → transpose solve → per-parameter
/// RHS perturbation + dot product.
///
/// No `computeBaseline()`: the baseline would freeze const-Jacobian stamps
/// (resistors) and mask the very perturbations being measured.
///
/// GPU batch note: solve_batch doesn't help here — the nominal OP is a single
/// solve (already GPU-accelerated via converger.run), and the per-parameter
/// perturbation loop is eval-only (ckt.evalNewton, no Newton iteration), so
/// there are no N independent Newton solves to batch.
pub fn solve(
    ckt: *root.Circuit,
    params: []const SensParam,
    output_node: u32,
    tol: converger.Tolerances,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    const ws = try ckt.workspace();
    const nopts = tol.newtonOpts(tol.itl2);

    // -- 1. Nominal OP solve (cold start) --
    // After convergence, ws.slv holds the factored Jacobian at x_op.
    const x_op = try allocator.alloc(f64, n);
    defer allocator.free(x_op);
    root.zeroSimd(x_op);
    ckt.seedJunctions(x_op);

    const dc_result = try converger.run(ckt, ws, x_op, 0, nopts, root.EvalHook{});
    if (!dc_result.converged) return error.DcNotConverged;

    const v0 = x_op[output_node];

    // -- Capture nominal RHS at the operating point --
    // Re-eval at x_op to get the nominal F(x_op) residual in ckt.rhs.
    ckt.evalNewton(x_op, 0);
    const rhs_nom = try allocator.alloc(f64, n);
    defer allocator.free(rhs_nom);
    copySimd(rhs_nom, ckt.rhs[0..n]);

    // -- 2. Adjoint solve: J^T · λ = e_out --
    const lambda = try allocator.alloc(f64, n);
    defer allocator.free(lambda);
    root.zeroSimd(lambda);
    lambda[output_node] = 1.0;
    ws.slv.solveT(lambda, lambda);

    // -- 3. Per-parameter: perturb, re-eval RHS, FD + adjoint dot --
    const entries = try allocator.alloc(SensEntry, params.len);
    errdefer allocator.free(entries);

    for (params, entries) |p, *entry| {
        const orig: f64 = p.ptr.get();
        const delta_req = 1e-6 * @abs(orig) + 1e-12;

        // Write the perturbed value, then read it BACK: an f32-typed parameter
        // rounds the step, and differencing against the requested delta instead
        // of the stored one is a wrong derivative, not a small one.
        p.ptr.set(orig + delta_req);
        defer {
            p.ptr.set(orig);
            ckt.recompute() catch unreachable; // restores the checked original parameter
        }
        try ckt.recompute();

        const delta = p.ptr.get() - orig;
        if (delta == 0) return error.ZeroDelta;

        // Evaluate F(x_op) with perturbed parameter (RHS only, no Newton).
        ckt.evalNewton(x_op, 0);

        // dy/dp = -λ^T · (rhs_pert - rhs_nom) / delta
        entry.* = .{
            .device_name = p.device_name,
            .param_name = p.param_name,
            .sensitivity = -adjointFd(lambda[0..n], ckt.rhs[0..n], rhs_nom, 1.0 / delta),
        };
    }

    return .{ .entries = entries, .op_value = v0 };
}

// ---------------------------------------------------------------------------
// Contract entry: run(*const RunCtx, Options) !Result
// ---------------------------------------------------------------------------

/// Every collected device parameter becomes one column ("<type>#<index>.<param>"),
/// one row of dVout/dp. Name strings live on the run arena.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const output_node = opts.output_node orelse blk: {
        if (ctx.probes.len == 0) return error.NoOutputNode;
        break :blk ctx.probes[ctx.probes.len - 1];
    };

    // `defer`-freed == scratch; `a` is a results arena. The per-column names
    // built from `res` below stay on `a` — they ARE the Result. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const refs = try ctx.circuit.collectParams();
    const params = try scratch.alloc(SensParam, refs.len);
    defer scratch.free(params);

    // Track formatted names so we can free on mid-loop failure.
    var n_named: usize = 0;
    defer for (params[0..n_named]) |p| scratch.free(p.device_name);

    for (refs, params) |ref, *p| {
        p.* = .{
            .ptr = ref,
            .device_name = try std.fmt.allocPrint(scratch, "{s}#{d}", .{ ref.device_type, ref.index }),
            .param_name = ref.param_name,
        };
        n_named += 1;
    }

    var res = try solve(ctx.circuit, params, output_node, opts.tol, scratch);
    defer res.deinit(scratch);

    const names = try a.alloc([]const u8, res.entries.len);
    errdefer a.free(names);
    const data = try a.alloc(f64, res.entries.len);
    errdefer a.free(data);

    var done: usize = 0;
    errdefer for (names[0..done]) |s| a.free(s);
    for (res.entries, names, data) |e, *name, *out| {
        name.* = try std.fmt.allocPrint(a, "{s}.{s}", .{ e.device_name, e.param_name });
        done += 1;
        out.* = e.sensitivity;
    }

    return .{
        .plotname = "DC Sensitivity",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Scalar oracle for adjointFd: the materialize-then-dot form it replaced,
/// with the same lane fold (W == 1 degenerates to this loop exactly).
fn adjointFdOracle(lambda: []const f64, pert: []const f64, nom: []const f64, inv_delta: f64) f64 {
    var dfdp: [64]f64 = undefined;
    for (0..lambda.len) |i| dfdp[i] = (pert[i] - nom[i]) * inv_delta;
    const V = @Vector(W, f64);
    var acc: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= lambda.len) : (i += W) {
        const av: V = lambda[i..][0..W].*;
        const bv: V = dfdp[i..][0..W].*;
        acc += av * bv;
    }
    const arr: [W]f64 = acc;
    var s: f64 = 0;
    for (arr) |v| s += v;
    while (i < lambda.len) : (i += 1) s += lambda[i] * dfdp[i];
    return s;
}

test "adjointFd: matches the materialize-then-dot oracle bit for bit" {
    var prng = std.Random.DefaultPrng.init(0xfeed);
    const rng = prng.random();
    var lambda: [64]f64 = undefined;
    var pert: [64]f64 = undefined;
    var nom: [64]f64 = undefined;
    for (0..64) |i| {
        lambda[i] = rng.floatNorm(f64);
        nom[i] = rng.floatNorm(f64);
        pert[i] = nom[i] + 1e-7 * rng.floatNorm(f64);
    }
    // every length across the vector boundary, plus the empty and tail cases
    for (0..65) |n| {
        const inv_delta = 1.0 / 1e-7;
        try testing.expectEqual(
            adjointFdOracle(lambda[0..n], pert[0..n], nom[0..n], inv_delta),
            adjointFd(lambda[0..n], pert[0..n], nom[0..n], inv_delta),
        );
    }
}

test "adjointFd: known value" {
    // dF/dp = (pert - nom) / delta = (2,4,6)/2 = (1,2,3); λ·dF/dp = 4+10+18 = 32
    const lambda = [_]f64{ 4.0, 5.0, 6.0 };
    const nom = [_]f64{ 0.0, 0.0, 0.0 };
    const pert = [_]f64{ 2.0, 4.0, 6.0 };
    try testing.expectApproxEqAbs(@as(f64, 32.0), adjointFd(&lambda, &pert, &nom, 0.5), 1e-15);
}

test "copySimd: round-trip" {
    var dst: [5]f64 = undefined;
    const src = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    copySimd(&dst, &src);
    for (dst, src) |d, s| try testing.expectEqual(s, d);
}
