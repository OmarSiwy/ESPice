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
const types = @import("solvers").types;
const solvers = @import("solvers");

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

// ---------------------------------------------------------------------------
// SIMD helpers (no @memset/@memcpy per convention)
// ---------------------------------------------------------------------------

const copySimd = root.copySimd;

/// SIMD dot product: λ^T · v
inline fn dotSimd(a: []const f64, b: []const f64) f64 {
    const n = @min(a.len, b.len);
    const V = @Vector(W, f64);
    var acc: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const av: V = a[i..][0..W].*;
        const bv: V = b[i..][0..W].*;
        acc += av * bv;
    }
    // ponytail: reduce SIMD accumulator to scalar via array extract
    // (@reduce would work but this is explicit and portable)
    const arr: [W]f64 = acc;
    var s: f64 = 0;
    for (arr) |v| s += v;
    // scalar tail
    while (i < n) : (i += 1) s += a[i] * b[i];
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
    // Build e_out: unit vector at output_node
    root.zeroSimd(lambda);
    lambda[output_node] = 1.0;
    ws.slv.solveT(lambda, lambda);

    // -- 3. Per-parameter: perturb, re-eval RHS, FD + adjoint dot --
    const entries = try allocator.alloc(SensEntry, params.len);
    errdefer allocator.free(entries);

    // Scratch for dF/dp = (rhs_pert - rhs_nom) / delta
    const dfdp = try allocator.alloc(f64, n);
    defer allocator.free(dfdp);

    for (params, entries) |p, *entry| {
        const orig: f64 = p.ptr.get();
        const delta_req = 1e-6 * @abs(orig) + 1e-12;

        // Write the perturbed value, then read it BACK: an f32-typed parameter
        // rounds the step, and differencing against the requested delta instead
        // of the stored one is a wrong derivative, not a small one.
        p.ptr.set(orig + delta_req);
        defer {
            p.ptr.set(orig);
            ckt.recompute();
        }
        ckt.recompute();

        const delta = p.ptr.get() - orig;
        if (delta == 0) return error.ZeroDelta;

        // Evaluate F(x_op) with perturbed parameter (RHS only, no Newton).
        ckt.evalNewton(x_op, 0);
        const inv_delta = 1.0 / delta;

        // dF/dp = (rhs_pert - rhs_nom) / delta  (SIMD)
        {
            const V = @Vector(W, f64);
            const id: V = @splat(inv_delta);
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const rp: V = ckt.rhs[i..][0..W].*;
                const rn: V = rhs_nom[i..][0..W].*;
                dfdp[i..][0..W].* = (rp - rn) * id;
            }
            while (i < n) : (i += 1) {
                dfdp[i] = (ckt.rhs[i] - rhs_nom[i]) * inv_delta;
            }
        }

        // dy/dp = -λ^T · dF/dp
        entry.* = .{
            .device_name = p.device_name,
            .param_name = p.param_name,
            .sensitivity = -dotSimd(lambda[0..n], dfdp[0..n]),
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

    const refs = try ctx.circuit.collectParams();
    const params = try a.alloc(SensParam, refs.len);
    defer a.free(params);

    // Track formatted names so we can free on mid-loop failure.
    var n_named: usize = 0;
    defer for (params[0..n_named]) |p| a.free(p.device_name);

    for (refs, params) |ref, *p| {
        p.* = .{
            .ptr = ref,
            .device_name = try std.fmt.allocPrint(a, "{s}#{d}", .{ ref.device_type, ref.index }),
            .param_name = ref.param_name,
        };
        n_named += 1;
    }

    var res = try solve(ctx.circuit, params, output_node, opts.tol, a);
    defer res.deinit(a);

    // Build result arrays: one name and one sensitivity value per parameter.
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

test "dotSimd: basic inner product" {
    const a = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    const b = [_]f64{ 5.0, 6.0, 7.0, 8.0 };
    try testing.expectApproxEqAbs(@as(f64, 70.0), dotSimd(&a, &b), 1e-15);
}

test "dotSimd: length not multiple of W" {
    const a = [_]f64{ 1.0, 2.0, 3.0 };
    const b = [_]f64{ 4.0, 5.0, 6.0 };
    try testing.expectApproxEqAbs(@as(f64, 32.0), dotSimd(&a, &b), 1e-15);
}

test "dotSimd: single element" {
    const a = [_]f64{7.0};
    const b = [_]f64{3.0};
    try testing.expectApproxEqAbs(@as(f64, 21.0), dotSimd(&a, &b), 1e-15);
}

test "dotSimd: empty" {
    const a = [_]f64{};
    const b = [_]f64{};
    try testing.expectApproxEqAbs(@as(f64, 0.0), dotSimd(&a, &b), 1e-15);
}

test "copySimd: round-trip" {
    var dst: [5]f64 = undefined;
    const src = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    copySimd(&dst, &src);
    for (dst, src) |d, s| try testing.expectEqual(s, d);
}
