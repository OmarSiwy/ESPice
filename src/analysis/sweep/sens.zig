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
    /// ngspice's three column spellings hang off these two (cktsens.c:224-238).
    is_instance: bool = true,
    principal: bool = false,
};

pub const Options = @import("requests").Sens;

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
    output_neg: u32,
    tol: converger.Tolerances,
    allocator: std.mem.Allocator,
) ![]SensEntry {
    const n: usize = ckt.n;
    const ws = try ckt.workspace();
    const nopts = converger.optionsFromTolerances(tol, tol.itl2);

    // -- 1. Nominal OP solve (cold start) --
    // After convergence, ws.slv holds the factored Jacobian at x_op.
    const x_op = try allocator.alloc(f64, n);
    defer allocator.free(x_op);
    root.zeroSimd(x_op);
    ckt.seedJunctions(x_op);

    const dc_result = try converger.run(ckt, ws, x_op, 0, nopts, root.EvalHook{});
    if (!dc_result.converged) return error.DcNotConverged;

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
    // `v(a,b)`: the adjoint seed is the node DIFFERENCE.
    if (output_neg != root.GROUND) lambda[output_neg] = -1.0;
    ws.slv.solveT(lambda, lambda);

    // -- 3. Per-parameter: perturb, re-eval RHS, FD + adjoint dot --
    const entries = try allocator.alloc(SensEntry, params.len);
    errdefer allocator.free(entries);

    for (params, entries, 0..) |p, *entry, index| {
        if (index != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = index, .total = params.len });
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
        // A parameter whose NOMINAL value collapses an internal node (bjt
        // RC/RE = 0, mos1 RD/RS = 0, ...) is re-wired by the +1e-12 floor in
        // `delta_req`: `collapse` stops folding c' onto c, the builder never
        // allocated a distinct c', and the batch reports TopologyChanged. The
        // derivative is not small there, it is not REPRESENTABLE — the
        // perturbed circuit has a node the frozen matrix pattern does not.
        // Report 0 rather than failing the whole analysis; ngspice's sens
        // never perturbs a topology parameter at all (cktsens.c drives the
        // per-device analytic sensitivity routines, not a generic FD).
        ckt.recompute() catch |e| switch (e) {
            error.TopologyChanged => {
                entry.* = .{
                    .device_name = p.device_name,
                    .param_name = p.param_name,
                    .sensitivity = 0,
                    .is_instance = p.ptr.is_instance,
                    .principal = p.ptr.primary,
                };
                continue;
            },
        };

        const delta = p.ptr.get() - orig;
        if (delta == 0) return error.ZeroDelta;

        // Evaluate F(x_op) with perturbed parameter (RHS only, no Newton).
        ckt.evalNewton(x_op, 0);

        // dy/dp = -λ^T · (rhs_pert - rhs_nom) / delta
        entry.* = .{
            .device_name = p.device_name,
            .param_name = p.param_name,
            .sensitivity = -adjointFd(lambda[0..n], ckt.rhs[0..n], rhs_nom, 1.0 / delta),
            .is_instance = p.ptr.is_instance,
            // NOT gated on is_instance: ngspice's IF_PRINCIPAL flag lives on
            // the instance parameter table, but VerA puts every Verilog-A
            // `parameter` on Model, so `primary` is where that flag ended up.
            .principal = p.ptr.primary,
        };
    }

    return entries;
}

// ---------------------------------------------------------------------------
// Contract entry: run(*const RunCtx, Options) !Result
// ---------------------------------------------------------------------------

/// Every collected device parameter becomes one column, one row of dVout/dp.
/// Column naming is ngspice's, cktsens.c:224-238:
///   model parameter                  -> `<card>:<param>`   (r1:tc1)
///   principal instance parameter     -> `<card>`           (r1)
///   any other instance parameter     -> `<card>_<param>`   (r1_scale)
/// Name strings live on the run arena.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const output_node = opts.output_node orelse blk: {
        if (ctx.probes.len == 0) return error.NoOutputNode;
        break :blk ctx.probes[ctx.probes.len - 1];
    };

    // `defer`-freed == scratch; `a` is a results arena. The per-column names
    // built from `entries` below stay on `a` — they ARE the Result. See
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
            .device_name = if (root.CardRef.lookup(opts.cards, ref)) |card|
                try scratch.dupe(u8, card)
            else
                try std.fmt.allocPrint(scratch, "{s}#{d}", .{ ref.device_type, ref.index }),
            .param_name = ref.param_name,
        };
        n_named += 1;
    }

    const entries = try solve(ctx.circuit, params, output_node, opts.output_neg, opts.tol, scratch);
    defer scratch.free(entries);

    const names = try a.alloc([]const u8, entries.len);
    errdefer a.free(names);
    const data = try a.alloc(f64, entries.len);
    errdefer a.free(data);

    var done: usize = 0;
    errdefer for (names[0..done]) |s| a.free(s);
    for (entries, names, data) |e, *name, *out| {
        // The `v(...)` wrapper is ngspice's, not decoration: cktsens.c hands
        // the raw writer a UID_OTHER name, which types as a voltage, so the
        // file spells the column `v(r1)`. Without it nothing keyed off an
        // ngspice sens raw finds the column.
        name.* = if (e.principal)
            try std.fmt.allocPrint(a, "v({s})", .{e.device_name})
        else
            try std.fmt.allocPrint(a, "v({s}{s}{s})", .{ e.device_name, if (e.is_instance) "_" else ":", e.param_name });
        done += 1;
        out.* = e.sensitivity;
    }

    return .{
        // ngspice opens the plot as "Sensitivity Analysis".
        .plotname = "Sensitivity Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .W = W,
    .adjointFd = adjointFd,
    .copySimd = copySimd,
} else {};
