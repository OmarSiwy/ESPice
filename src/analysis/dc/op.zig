//! Operating point: 5-rung Newton ladder (plain → gmin → source → JFNK →
//! optran). One Workspace for the whole continuation — the pattern is
//! frozen, so ordering/symbolic work happens exactly once.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const tran = @import("../tran/tran.zig");

pub const Method = enum { plain, gmin, source, jfnk, optran };

pub const Options = @import("requests").Op;

pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    max_dx: f64,
    method_used: Method,
};

const copySimd = root.copySimd;

/// Cold-start: zero x, then apply SPICE MODEINITJCT junction seeds so
/// iteration 1 linearizes at vcrit/vto instead of 0.
pub fn coldStart(ckt: *root.Circuit, x: []f64) void {
    root.zeroSimd(x);
    ckt.seedJunctions(x);
}

/// Fine-grained primitive: solve the operating point into caller-owned x.
/// engine.zig warm-starts every other analysis through this.
pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
) !SolveResult {
    // §4.6.1: the operating point is a static solve — `analysis("dc")` and
    // `$abstime` = 0. §5.10.2 `initial_step` is the first step of the analysis,
    // and the OP is it: this is where a switch latches its power-on state from
    // `ic`, before any @(cross) can move it. computeBaseline() evaluates
    // const-Jacobian batches, so the state has to be in place first.
    ckt.setSimState(.{ .kind = if (options.tran_op) .ic else .dc, .initial_step = true });
    if (!options.warm_start) coldStart(ckt, x);
    try ckt.computeBaseline();

    const ws = try ckt.workspace();

    const r = try solveLadder(ckt, ws, x, options);
    // Operating point accepted: sync FSM devices (switches) so a following
    // transient starts from a committed state.
    if (r.converged) _ = ckt.stateCtl(.commit);
    // The latch is committed; every later eval at this OP (ac, tf, noise,
    // post-processing) is NOT an initial step and must not re-latch.
    ckt.setSimState(.{ .kind = if (options.tran_op) .ic else .dc });
    return r;
}

/// The four-strategy continuation ladder: plain Newton → dynamic gmin
/// stepping → source stepping → JFNK guarantee rung. Takes a caller-owned
/// Workspace so dc.run can reuse its sweep workspace for fallback solves.
pub fn solveLadder(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    x: []f64,
    options: Options,
) !SolveResult {
    if (ckt.needs_tran_op) {
        // A node with no DC path has an identically-zero G row, so the static
        // operating point is not unique — the transient fallback only reports
        // whichever value the from-zero settling happened to land on. ngspice
        // accepts that under TRANOP, where the transient owns the initial
        // condition; a standalone .op/.ac/.pz has no such owner and the deck
        // is a floating-node deck, not a converged one.
        if (!options.tran_op) {
            std.log.err("topology: a node has no DC path to ground (capacitor-only island) — the operating point is not unique", .{});
            return error.FloatingNode;
        }
        return transientOp(ckt, ws, x, options);
    }
    // Rung 1: plain Newton. NO diagonal gmin: ngspice's NIiter never loads
    // one outside gmin stepping — junction gmin lives in the device models.
    // The always-on 1e-12 shunt this used to carry pinned every solution a
    // little differently from ngspice (voltage_divider read 2.5e-9 off), and
    // "converged" a floating bridge to a common mode ngspice never picks.
    const plain = newtonRun(ckt, ws, x, options.tol, 0.0) catch |e| switch (e) {
        error.SingularMatrix => null,
        else => return e,
    };
    if (converger.opdbg())
        std.debug.print("ladder: plain conv={?}\n", .{if (plain) |p| p.converged else null});
    if (plain) |p| {
        if (p.converged)
            return .{ .converged = true, .iterations = p.iterations, .max_dx = p.max_dx, .method_used = .plain };
    }

    // Last-converged solution for continuation restarts (both rungs).
    const gpa = ws.slv.gpa;
    const x_good = try gpa.alloc(f64, ckt.n);
    defer gpa.free(x_good);
    var total_iter: u16 = 0;

    // Rung 2: dynamic gmin stepping (ngspice cktop.c dynamic_gmin).
    // Descend gmin by `factor`; on a failed rung back gmin up toward the
    // last good value with a gentler factor (4th root) and retry from the
    // last converged x; give up when factor ~ 1.
    {
        coldStart(ckt, x);
        const gtarget = options.tol.gmin;
        var factor: f64 = 10.0;
        var good_gmin = options.tol.gmin_start; // upper bound to back up toward
        var gmin_val = good_gmin / factor;
        var have_good = false;
        var solves: u32 = 0;
        while (solves < 100) : (solves += 1) {
            const r = newtonRun(ckt, ws, x, options.tol, gmin_val) catch |e| switch (e) {
                error.SingularMatrix => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
                else => return e,
            };
            total_iter +|= r.iterations;
            if (converger.opdbg())
                std.debug.print("ladder: gmin={e:.3} conv={} it={d}\n", .{ gmin_val, r.converged, r.iterations });
            if (r.converged) {
                if (gmin_val <= gtarget) {
                    // ngspice dynamic_gmin ends by REMOVING diagGmin for the
                    // last solve — the answer must not carry the shunt.
                    const clean = newtonRun(ckt, ws, x, options.tol, 0.0) catch |err| switch (err) {
                        error.QueryCancelled => return err,
                        else => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
                    };
                    total_iter +|= clean.iterations;
                    if (clean.converged)
                        return .{ .converged = true, .iterations = total_iter, .max_dx = clean.max_dx, .method_used = .gmin };
                    break; // clean solve failed: fall through the ladder
                }
                copySimd(x_good, x);
                have_good = true;
                good_gmin = gmin_val;
                // Easy rung -> accelerate (cap at start factor);
                // hard rung (> 3/4 budget) -> slow down BEFORE failing so
                // folds are approached with shrinking steps.
                if (r.iterations <= options.tol.itl1 / 4) {
                    factor = @min(factor * @sqrt(factor), 10.0);
                } else if (r.iterations > 3 * (options.tol.itl1 / 4)) {
                    factor = @sqrt(factor);
                }
                gmin_val = if (gmin_val < factor * gtarget) gtarget else gmin_val / factor;
            } else {
                if (factor < 1.00005) break; // wedged against the last good rung
                factor = @sqrt(@sqrt(factor));
                gmin_val = good_gmin / factor;
                if (have_good) copySimd(x, x_good) else coldStart(ckt, x);
            }
        }
    }

    // Rung 3: source stepping via device attempt(lambda), adaptive delta:
    // grow 1.5x on success, halve on failure and retry from the last good
    // lambda/x (ngspice src stepping flavor).
    coldStart(ckt, x);
    total_iter = 0;
    {
        var lambda: f64 = 0.0;
        var lambda_good: f64 = -1.0; // none converged yet
        var delta: f64 = 0.25;
        var solves: u32 = 0;
        while (solves < 100) : (solves += 1) {
            ckt.applyAttempt(lambda);
            ckt.has_baseline = false;
            try ckt.computeBaseline();
            const sr = newtonRun(ckt, ws, x, options.tol, 0.0) catch |e| switch (e) {
                error.SingularMatrix => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
                else => {
                    ckt.restoreModels();
                    ckt.has_baseline = false;
                    try ckt.computeBaseline();
                    return e;
                },
            };
            total_iter +|= sr.iterations;
            if (converger.opdbg())
                std.debug.print("ladder: src lambda={e:.3} conv={} it={d}\n", .{ lambda, sr.converged, sr.iterations });
            if (sr.converged) {
                if (lambda >= 1.0) break; // full sources reached
                lambda_good = lambda;
                copySimd(x_good, x);
                delta *= 1.5;
                lambda = @min(lambda + delta, 1.0);
            } else {
                delta *= 0.5;
                if (delta < 1e-4) break;
                if (lambda_good >= 0.0) {
                    copySimd(x, x_good);
                    lambda = @min(lambda_good + delta, 1.0);
                } else {
                    coldStart(ckt, x);
                    lambda = 0.0;
                }
            }
        }
    }
    ckt.restoreModels();
    ckt.has_baseline = false;
    try ckt.computeBaseline();

    // Final solve at true parameters after source stepping
    const final = newtonRun(ckt, ws, x, options.tol, 0.0) catch |e| switch (e) {
        error.SingularMatrix => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
        else => return e,
    };
    total_iter +|= final.iterations;
    if (final.converged)
        return .{
            .converged = true,
            .iterations = total_iter,
            .max_dx = final.max_dx,
            .method_used = .source,
        };

    // Rung 4: JFNK guarantee rung — the same algorithm the GPU kernel
    // runs, so CPU convergence is a superset of GPU convergence by
    // construction. Damping + residual backtracking globalize differently
    // than direct Newton and catch circuits where the factored step wedges.
    {
        coldStart(ckt, x);
        const copts = converger.optionsFromTolerances(options.tol, null);
        // converger.run clears device limiting state on exit; a direct jfnk
        // call must do the same so post-solve evals see clean state.
        defer ckt.clearLimits();
        const jr = try converger.jfnk(ckt, ws, x, 0, copts, root.EvalHook{});
        total_iter +|= jr.iterations;
        if (jr.converged)
            return .{ .converged = true, .iterations = total_iter, .max_dx = jr.max_dx, .method_used = .jfnk };
    }

    var result = try transientOp(ckt, ws, x, options);
    result.iterations +|= total_iter;
    return result;
}

fn transientOp(ckt: *root.Circuit, ws: *converger.Workspace, x: []f64, options: Options) !SolveResult {
    // Rung 5: ngspice OPtran (optran.c) — when every static strategy fails,
    // the operating point is the SETTLED STATE of a real transient with full
    // sources: dt 10 ns, run to 1 µs, no ramp, no extra regularization —
    // device capacitances do the conditioning statics could not. ngspice
    // takes the settled state directly; a clean confirming Newton upgrades
    // it when the circuit allows one, and its failure is not a failure of
    // the rung.
    {
        const opa = ws.slv.gpa;
        root.zeroSimd(x);
        var wf = try tran.Waveform.init(opa, 0, 16);
        defer wf.deinit();
        const sim = tran.simulate(ckt, x, &.{}, &wf, .{
            .tol = options.tol,
            .t_stop = 1e-6,
            .dt_init = 1e-8,
            .dt_max = 1e-8,
            .uic = true,
        }, opa) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => null,
        };
        // The transient left .tran device state behind; the op contract is
        // a static circuit whatever the outcome.
        ckt.setSimState(.{ .kind = if (options.tran_op) .ic else .dc });
        ckt.has_baseline = false;
        try ckt.computeBaseline();
        if (sim != null and sim.?.completed) {
            if (ckt.needs_tran_op) return .{ .converged = true, .iterations = 0, .max_dx = 0, .method_used = .optran };
            const fin = newtonRun(ckt, ws, x, options.tol, 0.0) catch |err| switch (err) {
                error.QueryCancelled => return err,
                else => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
            };
            return .{ .converged = true, .iterations = fin.iterations, .max_dx = fin.max_dx, .method_used = .optran };
        }
    }

    return .{ .converged = false, .iterations = 0, .max_dx = 0, .method_used = .source };
}

/// Contract entry: solve (or reuse ctx.x_op) and format one point per probe.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const x = ctx.x_op orelse blk: {
        const x = try ctx.allocator.alloc(f64, ctx.circuit.n);
        errdefer ctx.allocator.free(x);
        const r = try solve(ctx.circuit, x, opts);
        if (!r.converged) return error.OpDidNotConverge;
        break :blk x;
    };
    defer if (ctx.x_op == null) ctx.allocator.free(x);
    const names = try root.probeNames(ctx, null);
    errdefer {
        for (names) |s| ctx.allocator.free(s); // no scale literal: all allocated
        ctx.allocator.free(names);
    }
    const data = try ctx.allocator.alloc(f64, names.len);
    for (ctx.probes, data) |node, *out| out.* = x[node];
    return .{
        .plotname = "Operating Point",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

fn newtonRun(ckt: *root.Circuit, ws: *converger.Workspace, x: []f64, tol: converger.Tolerances, gmin: f64) !converger.Result {
    var copts = converger.optionsFromTolerances(tol, null);
    copts.gmin = gmin;
    return converger.run(ckt, ws, x, 0, copts, root.EvalHook{});
}
