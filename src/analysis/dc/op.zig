//! Operating point: a five-rung Newton ladder (plain, gmin stepping, source
//! stepping, JFNK, OPtran) over one Workspace. The pattern is frozen, so the
//! ordering and symbolic factorization happen once for the whole ladder.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;
const tran = @import("../tran/tran.zig");

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Op;

const copySimd = root.copySimd;

const failed: converger.Result = .{ .converged = false, .iterations = 0, .max_dx = 0 };

/// Zeroes `x`, then applies the SPICE MODEINITJCT junction seeds so the first
/// iteration linearizes at vcrit/vto instead of 0.
pub fn coldStart(ckt: *root.Circuit, x: []f64) void {
    root.zeroSimd(x);
    ckt.seedJunctions(x);
}

/// Solves the operating point into caller-owned `x` (cold-started unless
/// `options.warm_start`). On convergence the FSM devices commit their state,
/// and the circuit is left in the static simulation state later evals at this
/// point expect. `iterations` sums every rung tried.
pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
) !converger.Result {
    // Verilog-A §4.6.1: the operating point is a static solve, so
    // `analysis("dc")` holds and `$abstime` = 0. §5.10.2 `initial_step` is the
    // first step of the analysis, which is this solve: a switch latches its
    // power-on state from `ic` here, before any @(cross) can move it.
    // computeBaseline() evaluates const-Jacobian batches, so the state has to
    // be in place first.
    ckt.setSimState(.{ .kind = if (options.tran_op) .ic else .dc, .initial_step = true });
    if (!options.warm_start) coldStart(ckt, x);
    try ckt.computeBaseline();

    const ws = try ckt.workspace();

    const r = try solveLadder(ckt, ws, x, options);
    // Commit FSM devices (switches) so a following transient starts from the
    // accepted state.
    if (r.converged) _ = ckt.stateCtl(.commit);
    // Every later eval at this point (ac, tf, noise, post-processing) is not
    // an initial step and must not re-latch.
    ckt.setSimState(.{ .kind = if (options.tran_op) .ic else .dc });
    return r;
}

/// The continuation ladder from `x` as given: plain Newton, dynamic gmin
/// stepping, source stepping, JFNK, then OPtran. Takes the caller's Workspace
/// so dc.zig can fall back to it mid-sweep. Returns error.FloatingNode when a
/// node has no DC path to ground outside a TRANOP.
pub fn solveLadder(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    x: []f64,
    options: Options,
) !converger.Result {
    if (ckt.needs_tran_op) {
        // A node with no DC path has an all-zero G row, so the static
        // operating point is not unique and the transient only reports
        // wherever settling from zero landed. ngspice accepts that under
        // TRANOP, where the transient owns the initial condition; a standalone
        // .op/.ac/.pz has no such owner, so the deck is rejected.
        if (!options.tran_op) {
            std.log.err("topology: a node has no DC path to ground (capacitor-only island) — the operating point is not unique", .{});
            return error.FloatingNode;
        }
        return transientOp(ckt, ws, x, options);
    }
    // Rung 1: plain Newton with no diagonal gmin. ngspice's NIiter loads one
    // only during gmin stepping (junction gmin lives in the device models);
    // an always-on shunt moves every solution off ngspice's (voltage_divider
    // by 2.5e-9) and settles a floating bridge on a common mode ngspice never
    // picks.
    const plain = newtonRun(ckt, ws, x, options.tol, 0.0, null) catch |e| switch (e) {
        error.SingularMatrix => null,
        else => return e,
    };
    if (converger.opdbg())
        std.debug.print("ladder: plain conv={?}\n", .{if (plain) |p| p.converged else null});
    if (plain) |p| {
        if (p.converged) return p;
    }

    // Last converged solution, the restart point of both stepping rungs.
    const gpa = ws.slv.gpa;
    const x_good = try gpa.alloc(f64, ckt.n);
    defer gpa.free(x_good);
    var total_iter: u16 = 0;

    // Rung 2: dynamic gmin stepping (ngspice cktop.c dynamic_gmin). Descend
    // gmin by `factor`; on a failed step, back up toward the last good gmin
    // with the 4th root of the factor and retry from the last converged x;
    // give up once the factor is ~1.
    {
        coldStart(ckt, x);
        const gtarget = options.tol.gmin;
        var factor: f64 = 10.0;
        var good_gmin = options.tol.gmin_start; // upper bound to back up toward
        var gmin_val = good_gmin / factor;
        var have_good = false;
        var solves: u32 = 0;
        while (solves < 100) : (solves += 1) {
            const r = newtonRun(ckt, ws, x, options.tol, gmin_val, options.tol.itl2) catch |e| switch (e) {
                error.SingularMatrix => failed,
                else => return e,
            };
            total_iter +|= r.iterations;
            if (converger.opdbg())
                std.debug.print("ladder: gmin={e:.3} conv={} it={d}\n", .{ gmin_val, r.converged, r.iterations });
            if (r.converged) {
                if (gmin_val <= gtarget) {
                    // ngspice's dynamic_gmin removes diagGmin for the last
                    // solve: the answer must not carry the shunt.
                    const clean = newtonRun(ckt, ws, x, options.tol, 0.0, null) catch |err| switch (err) {
                        error.QueryCancelled => return err,
                        else => failed,
                    };
                    total_iter +|= clean.iterations;
                    if (clean.converged)
                        return .{ .converged = true, .iterations = total_iter, .max_dx = clean.max_dx };
                    break;
                }
                copySimd(x_good, x);
                have_good = true;
                good_gmin = gmin_val;
                // An easy step accelerates (capped at the start factor); a
                // hard one (over 3/4 of the budget) slows down before it
                // fails, so folds are approached with shrinking steps.
                // Thresholds, floor and final clamp are cktop.c:207-222, on
                // the itl2 budget these solves run with.
                if (r.iterations <= options.tol.itl2 / 4) {
                    factor = @min(factor * @sqrt(factor), 10.0);
                } else if (r.iterations > 3 * options.tol.itl2 / 4) {
                    factor = @max(@sqrt(factor), 1.00005);
                }
                if (gmin_val < factor * gtarget) {
                    factor = gmin_val / gtarget;
                    gmin_val = gtarget;
                } else gmin_val /= factor;
            } else {
                if (factor < 1.00005) break; // wedged against the last good step
                factor = @sqrt(@sqrt(factor));
                gmin_val = good_gmin / factor;
                if (have_good) copySimd(x, x_good) else coldStart(ckt, x);
            }
        }
    }

    // Rung 3: source stepping through the devices' attempt(lambda), with an
    // adaptive step: grow 1.5x on success, halve on failure and retry from
    // the last good lambda and x.
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
            const sr = newtonRun(ckt, ws, x, options.tol, 0.0, options.tol.itl2) catch |e| switch (e) {
                error.SingularMatrix => failed,
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
                // Nothing converged yet means the lambda = 0 start failed, and
                // a retry would be the same cold solve.
                if (lambda_good < 0.0) break;
                copySimd(x, x_good);
                lambda = @min(lambda_good + delta, 1.0);
            }
        }
    }
    ckt.restoreModels();
    ckt.has_baseline = false;
    try ckt.computeBaseline();

    const final = newtonRun(ckt, ws, x, options.tol, 0.0, null) catch |e| switch (e) {
        error.SingularMatrix => failed,
        else => return e,
    };
    total_iter +|= final.iterations;
    if (final.converged)
        return .{ .converged = true, .iterations = total_iter, .max_dx = final.max_dx };

    // Rung 4: JFNK, the algorithm the GPU kernel runs, so CPU convergence is
    // a superset of GPU convergence. Damping plus residual backtracking
    // catches circuits where the factored Newton step wedges.
    {
        coldStart(ckt, x);
        const copts = converger.optionsFromTolerances(options.tol, null);
        // converger.run clears device limiting state on exit; a direct jfnk
        // call must too, so post-solve evals see clean state.
        defer ckt.clearLimits();
        const jr = try converger.jfnk(ckt, ws, x, 0, copts, root.EvalHook{});
        total_iter +|= jr.iterations;
        if (jr.converged)
            return .{ .converged = true, .iterations = total_iter, .max_dx = jr.max_dx };
    }

    var result = try transientOp(ckt, ws, x, options);
    result.iterations +|= total_iter;
    return result;
}

/// Rung 5, ngspice OPtran (optran.c): a real transient with full sources,
/// dt 10 ns to 1 µs, no ramp and no extra regularization, so the device
/// capacitances do the conditioning the static rungs could not. The settled
/// state only seeds a clean Newton, whose result is the answer; reporting the
/// settled state itself would be a false success
/// (stress/scaling_inverter_chain_4k). Under `needs_tran_op` the settled state
/// is the answer. ngspice 44.2 runs this rung only when `optran` is given
/// (cktop.c:94-97).
fn transientOp(ckt: *root.Circuit, ws: *converger.Workspace, x: []f64, options: Options) !converger.Result {
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
    // The transient left .tran device state behind; the op contract is a
    // static circuit whatever the outcome.
    ckt.setSimState(.{ .kind = if (options.tran_op) .ic else .dc });
    ckt.has_baseline = false;
    try ckt.computeBaseline();
    if (sim == null or !sim.?.completed) return failed;
    if (ckt.needs_tran_op) return .{ .converged = true, .iterations = 0, .max_dx = 0 };
    return newtonRun(ckt, ws, x, options.tol, 0.0, null) catch |err| switch (err) {
        error.QueryCancelled => return err,
        else => failed,
    };
}

/// Contract entry: the executor's solved ctx.x_op, one point per probe.
pub fn run(ctx: *const root.RunCtx, _: Options) !root.Result {
    const x = ctx.x_op;
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

/// `max_iter` null means itl1. The stepping rungs pass itl2 (ngspice's
/// CKTdcTrcvMaxIter, cktop.c:194 and the source-stepping NIiter calls).
fn newtonRun(ckt: *root.Circuit, ws: *converger.Workspace, x: []f64, tol: converger.Tolerances, gmin: f64, max_iter: ?u16) !converger.Result {
    var copts = converger.optionsFromTolerances(tol, max_iter);
    copts.gmin = gmin;
    return converger.run(ckt, ws, x, 0, copts, root.EvalHook{});
}
