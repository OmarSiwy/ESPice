//! Residue probes (AGENTS.md §1.2 R8, `zig/zero-cost.md`): each hot-path
//! abstraction as an exported `gen_<name>` beside the hand-written
//! `hand_<name>` it claims to equal. Nothing links or runs this object; the
//! build emits its x86_64_v3 ReleaseFast assembly and `tools/asm_probe.py`
//! judges each pair (FOLDED, IDENTICAL, EQUIVALENT or NEGATIVE pass; RESIDUE
//! fails `zig build test`). Seam records citing a probe: dev/decisions.md.
//!
//! Each export calls the abstraction directly and takes runtime pointers and
//! lengths, so nothing constant-folds and no shared helper hides the
//! inlining under test.

const std = @import("std");
const eval = @import("device_eval");
const solver = @import("solver");

// ---- device Dual(2, f64).mul (S3): the product rule through the AD family
// against a value plus a 2-lane gradient written out. ----

const D2 = eval.Dual(2, f64);
const Val2 = D2.Of(0b11);

export fn gen_dual_mul(a: *const [3]f64, b: *const [3]f64, out: *[3]f64) void {
    const x: Val2 = .{ .v = a[0], .d = .{ a[1], a[2] } };
    const y: Val2 = .{ .v = b[0], .d = .{ b[1], b[2] } };
    const r = x.mul(y);
    out.* = .{ r.v, r.d[0], r.d[1] };
}

export fn hand_dual_mul(a: *const [3]f64, b: *const [3]f64, out: *[3]f64) void {
    const V = @Vector(2, f64);
    const av = a[0];
    const bv = b[0];
    const v = av * bv;
    // d(ab) = b' a + a' b, fused as the family fuses it on an FMA target.
    const ad: V = .{ a[1], a[2] };
    const bd: V = .{ b[1], b[2] };
    const d = @mulAdd(V, bd, @splat(av), ad * @as(V, @splat(bv)));
    out.* = .{ v, d[0], d[1] };
}

// ---- solver engine dispatch (S7): `direct.Engine`'s exhaustive switch
// against the three optionals it replaced, checked in their old order. ----

const Engine = solver.direct.Engine;

export fn gen_engine_solve(e: *Engine, x: [*]f64, n: u32) void {
    switch (e.*) {
        .lu => |*lu| lu.solve(x[0..n], x[0..n]),
        .tri => |*tri| tri.solve(x[0..n]),
        .bbd => |*bbd| bbd.solveInPlace(x[0..n]),
    }
}

const HandEngines = struct {
    lu: ?@FieldType(Engine, "lu"),
    tri: ?@FieldType(Engine, "tri"),
    bbd: ?@FieldType(Engine, "bbd"),
};

export fn hand_engine_solve(e: *HandEngines, x: [*]f64, n: u32) void {
    if (e.tri) |*tri| return tri.solve(x[0..n]);
    if (e.bbd) |*bbd| return bbd.solveInPlace(x[0..n]);
    e.lu.?.solve(x[0..n], x[0..n]);
}

// ---- tran's companion Newton hook (S12, #195): `integrator.Hook` against the
// hand-written hooks it replaced, pss's `PeriodHook` (fixed trapezoid) and
// tran's `TranHook` (method per step), on a stand-in circuit whose stamp and
// matrix calls are opaque. ----

const integrator = @import("integrator");
const num = @import("core").numerics;

extern fn probe_eval(x: [*]const f64, len: usize, t: f64) void;
extern fn probe_combine(alpha: f64, out: [*]f64, len: usize) void;

const Ckt = struct {
    n: u32,
    rhs: []f64,
    q_vec: []f64,
    g_vals: []f64,
    c_vals: []f64,

    pub fn evalNewton(_: *Ckt, x: []const f64, t: f64) void {
        probe_eval(x.ptr, x.len, t);
    }
    pub fn combineGC(_: *Ckt, alpha: f64, out: []f64) void {
        probe_combine(alpha, out.ptr, out.len);
    }
    pub fn gcAt(self: *const Ckt, alpha: f64, slot: u32) f64 {
        return self.g_vals[slot] + alpha * self.c_vals[slot];
    }
};

const TrapHook = integrator.Hook(.trapezoidal);
const StepHook = integrator.Hook(null);

const HandStep = struct {
    method: @FieldType(StepHook, "method"),
    c: integrator.Coeffs,
    q_prev: []const f64,
    i_prev: []const f64,
    q_prev2: []const f64,
    a_vals: []f64,
    has_charge: bool,
};

export fn gen_hook_trap_assemble(h: *const TrapHook, ckt: *Ckt, x: [*]const f64, t: f64) void {
    h.assemble(ckt, x[0..ckt.n], t);
}

// The trap hands read `TrapHook` itself: a narrower hand struct gets its own
// auto layout, so the bodies differed only in field offsets (and LLVM's
// `cmp`/`test` pick for the bool), which is not abstraction cost.
export fn hand_hook_trap_assemble(h: *const TrapHook, ckt: *Ckt, x: [*]const f64, t: f64) void {
    ckt.evalNewton(x[0..ckt.n], t);
    if (h.has_charge) {
        const n: usize = ckt.n;
        num.copySimd(h.q_cur[0..n], ckt.q_vec[0..n]);
        integrator.companionAt(.trapezoidal, true, ckt.rhs[0..n], ckt.q_vec[0..n], h.q_prev[0..n], &.{}, h.i_prev[0..n], .{ .ag0 = h.c.ag0, .ag2 = 0 });
    }
}

export fn gen_hook_step_assemble(h: *const StepHook, ckt: *Ckt, x: [*]const f64, t: f64) void {
    h.assemble(ckt, x[0..ckt.n], t);
}

export fn hand_hook_step_assemble(h: *const HandStep, ckt: *Ckt, x: [*]const f64, t: f64) void {
    ckt.evalNewton(x[0..ckt.n], t);
    if (h.has_charge) {
        const n: usize = ckt.n;
        switch (h.method) {
            inline else => |m| integrator.companionAt(m, true, ckt.rhs[0..n], ckt.q_vec[0..n], h.q_prev, h.q_prev2, h.i_prev, h.c),
        }
    }
}

export fn gen_hook_diag_at(h: *const TrapHook, ckt: *Ckt, slot: u32) f64 {
    return h.diagAt(ckt, slot);
}

export fn hand_hook_diag_at(h: *const TrapHook, ckt: *Ckt, slot: u32) f64 {
    return if (h.has_charge) ckt.gcAt(h.c.ag0, slot) else ckt.g_vals[slot];
}

// ---- core.numerics kernels keep their vector form (S11): each `gen_` calls the
// production function; each `hand_` is the scalar loop the vectorizer must beat.
// NEGATIVE means the production loop is vectorized where the scalar one is not,
// so a change that turns a kernel scalar again fails this step. ----

export fn gen_num_dot(a: [*]const f64, b: [*]const f64, n: usize) f64 {
    return @call(.always_inline, num.dot, .{ a[0..n], b[0..n] });
}

export fn hand_num_dot(a: [*]const f64, b: [*]const f64, n: usize) f64 {
    var s: f64 = 0;
    for (a[0..n], b[0..n]) |x, y| s += x * y;
    return s;
}

export fn gen_num_sum(x: [*]const f64, n: usize) f64 {
    return @call(.always_inline, num.sum, .{x[0..n]});
}

export fn hand_num_sum(x: [*]const f64, n: usize) f64 {
    var s: f64 = 0;
    for (x[0..n]) |v| s += v;
    return s;
}

export fn gen_num_norminf(x: [*]const f64, n: usize) f64 {
    return @call(.always_inline, num.normInf, .{x[0..n]});
}

/// normInf's own rule (an i64 max of the sign-cleared bit pattern, so NaN
/// wins) one element at a time on integer registers; the barrier keeps it
/// scalar, so the pair judges vector against scalar. A float `@abs` here would
/// lower to `vandpd xmm`, which the probe counts as vector work.
export fn hand_num_norminf(x: [*]const f64, n: usize) f64 {
    var m: u64 = 0;
    for (x[0..n]) |v| {
        const k = @as(u64, @bitCast(v)) & 0x7fff_ffff_ffff_ffff;
        if (k > m) m = k;
        std.mem.doNotOptimizeAway(m);
    }
    return @bitCast(m);
}

// ---- Lanes(1) primitives (lane-batched-simulation.md §3.1): each lane
// primitive at W = 1 against the scalar operation it replaces. ----

const L1 = solver.lanes.Lanes(1);

export fn gen_lanes_splat(x: f64) f64 {
    return L1.splat(x);
}

export fn hand_lanes_splat(x: f64) f64 {
    return x;
}

export fn gen_lanes_any(m: bool) bool {
    return L1.any(m);
}

export fn hand_lanes_any(m: bool) bool {
    return m;
}

export fn gen_lanes_all(m: bool) bool {
    return L1.all(m);
}

export fn hand_lanes_all(m: bool) bool {
    return m;
}

export fn gen_lanes_select(a: f64, b: f64, c: f64) f64 {
    return L1.select(L1.cmp(.lte, a, b), a, c);
}

export fn hand_lanes_select(a: f64, b: f64, c: f64) f64 {
    return if (a <= b) a else c;
}

export fn gen_lanes_cmp(a: f64, b: f64) bool {
    return L1.any(L1.both(L1.cmp(.lt, a, b), L1.not(L1.cmp(.eq, a, 0))));
}

export fn hand_lanes_cmp(a: f64, b: f64) bool {
    return a < b and !(a == 0);
}

export fn gen_lanes_either(a: f64, b: f64) bool {
    return L1.either(L1.cmp(.gt, a, b), L1.cmp(.neq, b, b));
}

export fn hand_lanes_either(a: f64, b: f64) bool {
    return a > b or b != b;
}

export fn gen_lanes_lane(v: f64) f64 {
    return L1.lane(v, 0);
}

export fn hand_lanes_lane(v: f64) f64 {
    return v;
}

export fn gen_lanes_each(a: f64, b: f64, out: *f64) void {
    var it = L1.each(L1.cmp(.gt, a, b));
    while (it.next()) |l| out.* += L1.lane(a, l);
}

export fn hand_lanes_each(a: f64, b: f64, out: *f64) void {
    if (a > b) out.* += a;
}

// ---- converger.newton at W = 1 (lane-batched-simulation.md §3.1, the
// phase 1 gate): the lane-generic `newton` against a frozen copy of the
// scalar one it replaced (92f7f024, converger.zig:63-675 excerpts), on a
// stand-in system whose device calls are opaque. ----

const converger = solver.converger;

extern fn probe_newton_eval(x: [*]const f64, len: usize, t: f64) void;
extern fn probe_newton_limits(x: [*]f64, x_old: [*]const f64, len: usize) bool;
extern fn probe_newton_states(x: [*]const f64, len: usize) f64;
extern fn probe_newton_device(x: [*]const f64, len: usize) bool;
extern fn probe_newton_load(x: [*]const f64, rhs: [*]const f64, len: usize) bool;
extern fn probe_newton_iter(x_old: [*]const f64, len: usize) void;
extern fn probe_newton_follows(x: [*]const f64, len: usize, t: f64) void;
extern fn probe_newton_checkpoint(completed: u16) bool;

const NSys = struct {
    n: u32,
    nnz: u32,
    diag_slots: []const u32,
    rhs: []f64,
    current_row: []const bool,
    g_vals: []f64,
    solver_execution: num.Execution = .{},

    pub const Event = struct { phase: enum { nonlinear }, completed: u16, total: u16 };

    pub fn beginSolve(_: *NSys) void {}
    pub fn checkpoint(_: *NSys, e: Event) error{QueryCancelled}!void {
        if (!probe_newton_checkpoint(e.completed)) return error.QueryCancelled;
    }
    pub fn advanceIteration(_: *NSys, x_old: []const f64) void {
        probe_newton_iter(x_old.ptr, x_old.len);
    }
    pub fn loadCheck(_: *NSys, x: []const f64, _: []const f64, rhs: []const f64, _: f64, _: f64) bool {
        return probe_newton_load(x.ptr, rhs.ptr, x.len);
    }
    pub fn evalFollows(_: *const NSys, x: []const f64, t: f64, _: bool) void {
        probe_newton_follows(x.ptr, x.len, t);
    }
    pub fn applyLimits(_: *const NSys, x: []f64, x_old: []const f64) bool {
        return probe_newton_limits(x.ptr, x_old.ptr, x.len);
    }
    pub fn checkConvergence(_: *const NSys, x: []const f64) bool {
        return probe_newton_device(x.ptr, x.len);
    }
    pub fn updateStates(_: *NSys, x: []const f64) ?f64 {
        const r = probe_newton_states(x.ptr, x.len);
        return if (r == r) r else null;
    }
};

const NHook = struct {
    pub fn assemble(_: NHook, sys: *NSys, x: []const f64, t: f64) void {
        probe_newton_eval(x.ptr, x.len, t);
        _ = sys;
    }
    pub fn vals(_: NHook, sys: *NSys) []f64 {
        return sys.g_vals;
    }
    pub fn diagAt(_: NHook, sys: *NSys, slot: u32) f64 {
        return sys.g_vals[slot];
    }
};

export fn gen_newton(sys: *NSys, ws: *converger.Workspace, x: [*]f64, t: f64, opts: *const converger.Options, out: *converger.Result) u16 {
    out.* = converger.newton(sys, ws, x[0..sys.n], t, opts.*, NHook{}) catch |e| return @intFromError(e);
    return 0;
}

export fn hand_newton(sys: *NSys, ws: *converger.Workspace, x: [*]f64, t: f64, opts: *const converger.Options, out: *converger.Result) u16 {
    out.* = old_newton.newton(sys, ws, x[0..sys.n], t, opts.*, NHook{}) catch |e| return @intFromError(e);
    return 0;
}

// The delta gate alone: the lane-generic `updateAndNorm` at W = 1 against
// its scalar original.
export fn gen_update_and_norm(x: [*]f64, dx: [*]const f64, x_old: [*]f64, cur: [*]const bool, n: usize, reltol: f64, abstol: f64, vntol: f64) f64 {
    return converger.updateAndNorm(1, x[0..n], dx[0..n], x_old[0..n], cur[0..n], reltol, abstol, vntol, true);
}

export fn hand_update_and_norm(x: [*]f64, dx: [*]const f64, x_old: [*]f64, cur: [*]const bool, n: usize, reltol: f64, abstol: f64, vntol: f64) f64 {
    return old_newton.updateAndNorm(x[0..n], dx[0..n], x_old[0..n], cur[0..n], reltol, abstol, vntol);
}

const old_newton = struct {
    const assert = std.debug.assert;
    const inf = std.math.inf(f64);
    const Execution = num.Execution;
    const Options = converger.Options;
    const Result = converger.Result;
    const Workspace = converger.Workspace;
    const force_g = converger.force_g;

    const Reject = enum { converged, first_iter, delta, limited, flipped, residual, device, runaway };

    fn Deref(comptime P: type) type {
        return if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
    }

    fn executionOf(sys: anytype) Execution {
        return if (comptime @hasField(Deref(@TypeOf(sys)), "solver_execution")) sys.solver_execution else .{};
    }

    fn newton(
        sys: anytype,
        ws: *Workspace,
        x: []f64,
        t: f64,
        opts: Options,
        hook: anytype,
    ) !Result {
        const S = Deref(@TypeOf(sys));
        assert(ws.slv.n == sys.n);
        assert(ws.dx.len >= sys.n);
        assert(ws.x_old.len >= sys.n);
        assert(x.len >= sys.n);
        const slv = &ws.slv;
        const dx = ws.dx;
        const x_old = ws.x_old;
        var iter: u16 = 0;
        var init_fix = opts.init_fix;
        var limit: f64 = x_plausible;
        if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();
        const prof = &ws.prof;

        while (iter < opts.max_iter) : (iter += 1) {
            if (comptime @hasDecl(S, "checkpoint")) if (iter != 0)
                try sys.checkpoint(.{ .phase = .nonlinear, .completed = iter, .total = opts.max_iter });
            if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);
            prof.start();
            hook.assemble(sys, x, t);
            prof.lap(.eval);
            const v = hook.vals(sys);
            loadExtras(sys, v, x, opts);
            if (iter == 0) limit = plausibleLimit(sys, x[0..sys.n], sys.rhs[0..sys.n], v);
            var norm_f: f64 = 0; // read only by the traces
            if (ws.knobs.newton_debug or ws.knobs.opdbg) {
                norm_f = num.normInf(sys.rhs[0..sys.n]);
            }
            if (ws.knobs.newton_debug)
                std.debug.print("  it={d} |F|={e} x={any}\n", .{ iter, norm_f, x[0..@min(sys.n, 8)] });
            // Before the factor and solve, which may overwrite `v` and `rhs`.
            const load_ok = if (comptime @hasDecl(S, "loadCheck")) sys.loadCheck(x, v, sys.rhs[0..sys.n], opts.reltol, opts.abstol) else true;
            prof.lap(.load);
            // The device LU (dev/solvers/gpu-lu.md) is bitwise this factor and
            // solve; false leaves both to the host.
            const on_device = if (comptime @hasDecl(S, "deviceSolve")) sys.deviceSolve(slv, v, dx) orelse false else false;
            if (!on_device) {
                slv.factor(v, executionOf(sys)) catch |e| {
                    if (ws.knobs.opdbg) {
                        var nan_cnt: usize = 0;
                        for (v[0..sys.nnz]) |vi| {
                            if (!std.math.isFinite(vi)) nan_cnt += 1;
                        }
                        const max_x = num.normInf(x[0..sys.n]);
                        std.debug.print("  newton it={d} FACTOR FAIL {} nan_vals={d} max|x|={e:.3} |F|={e:.3}\n", .{ iter, e, nan_cnt, max_x, norm_f });
                    }
                    return e;
                };
                prof.lap(.factor);
                slv.solveNeg(sys.rhs, dx);
            }
            prof.lap(.solve);
            // The INITFIX pass does not stage: its converged iterate is not the
            // answer, and staging there restarted a Newton-history limiter from a
            // stale value, so the extra pass solved F(lim(x)) = 0 (#53).
            const st = finalizeStep(sys, hook, x, dx, x_old, sys.rhs, v, iter, t, opts, limit, load_ok, !init_fix);
            prof.lap(.update);
            if (ws.knobs.opdbg) {
                var fi: usize = 0;
                var di: usize = 0;
                for (0..sys.n) |i| {
                    if (@abs(sys.rhs[i]) > @abs(sys.rhs[fi])) fi = i;
                    if (@abs(dx[i]) > @abs(dx[di])) di = i;
                }
                const name_fi = sysNodeName(sys, @intCast(fi));
                const name_di = sysNodeName(sys, @intCast(di));
                std.debug.print("  newton it={d} |F|={e:.3}@{d}({s}) dx={e:.3}@{d}({s}) x={e:.3} scaled={e:.3} conv={} why={s}\n", .{ iter, norm_f, fi, name_fi, dx[di], di, name_di, x[di], st.scaled, st.converged, @tagName(st.why) });
            }
            if (st.converged and init_fix) {
                init_fix = false;
            } else if (st.converged) {
                @memcpy(x[0..sys.n], x_old[0..sys.n]);
                return .{ .converged = true, .iterations = iter + 1 };
            }
        }
        return .{ .converged = false, .iterations = opts.max_iter };
    }

    fn loadExtras(sys: anytype, v: []f64, x: []const f64, opts: Options) void {
        assert(x.len >= sys.n);
        assert(v.len >= sys.nnz);
        loadGmin(sys, v, sys.rhs[0..sys.n], x, opts);
        for (opts.force) |f| {
            v[f.slot] += force_g;
            sys.rhs[f.row] += force_g * (x[f.row] - f.value);
        }
    }

    fn residualGate(opts: Options, diag: f64, xi: f64) f64 {
        const scale = @abs(diag);
        // A zero diagonal is a voltage-defined branch row (V/E/H source): it is
        // gated at scale 1, a loose 10*(reltol*|x| + vntol) that an exact
        // solution's O(gain * eps) residual (a 1e9-gain E source reads 2.7e-8)
        // still passes, but that refuses x = 0 when the only residual sits on
        // such a row (#152).
        const s = if (scale == 0) 1.0 else scale;
        return @max(opts.residual_tol, 10.0 * s * (opts.reltol * @abs(xi) + opts.vntol));
    }

    fn sysNodeName(sys: anytype, idx: u32) []const u8 {
        const S = Deref(@TypeOf(sys));
        if (comptime @hasDecl(S, "nodeName")) return sys.nodeName(idx);
        return "?";
    }

    const Step = struct { converged: bool, scaled: f64, why: Reject = .converged };

    const x_plausible = 1e9;

    fn plausibleLimit(sys: anytype, x: []const f64, f: []const f64, vals: []const f64) f64 {
        var g: f64 = 1;
        for (sys.diag_slots[0..sys.n]) |slot| g = @max(g, @abs(vals[slot]));
        const scale = @min(@max(num.normInf(x), num.normInf(f) * g), 1e18);
        // Negated, so a NaN start keeps the floor.
        return if (!(1e3 * scale > x_plausible)) x_plausible else 1e3 * scale;
    }

    fn plausible(x: []const f64, limit: f64) bool {
        const block = 64;
        var i: usize = 0;
        while (i + block <= x.len) : (i += block) {
            var bad: u64 = 0;
            for (x[i..][0..block]) |xi| bad |= @intFromBool(!(@abs(xi) <= limit));
            if (bad != 0) return false;
        }
        var bad: u64 = 0;
        for (x[i..]) |xi| bad |= @intFromBool(!(@abs(xi) <= limit));
        return bad == 0;
    }

    fn residualMisses(opts: Options, residual: []const f64, x: []const f64, vals: []const f64, diag_slots: []const u32) usize {
        assert(residual.len >= x.len);
        assert(diag_slots.len >= x.len);
        var misses: usize = 0;
        for (residual[0..x.len], x, diag_slots[0..x.len]) |ri, xi, slot|
            misses += @intFromBool(!(@abs(ri) <= residualGate(opts, vals[slot], xi)));
        return misses;
    }

    fn finalizeStep(
        sys: anytype,
        hook: anytype,
        x: []f64,
        dx: []const f64,
        x_old: []f64,
        residual: []const f64,
        vals: []const f64,
        iter: u16,
        t: f64,
        opts: Options,
        limit: f64,
        load_ok: bool,
        stage: bool,
    ) Step {
        const S = Deref(@TypeOf(sys));
        const n = sys.n;
        assert(residual.len >= n);
        assert(vals.len >= sys.nnz);
        const scaled = updateAndNorm(x[0..n], dx[0..n], x_old[0..n], sys.current_row[0..n], opts.reltol, opts.abstol, opts.vntol);

        // The first-iterate and delta gates are already decided and neither
        // reads the limiter, so the next assemble at the limited x is certain:
        // a system that batches its limit pass with that eval may start both.
        if (comptime @hasDecl(S, "evalFollows")) {
            if ((iter == 0 or scaled >= 1.0) and iter + 1 < opts.max_iter) sys.evalFollows(x, t, false);
        }

        const limited = if (comptime @hasDecl(S, "applyLimits")) sys.applyLimits(x, x_old) else false;

        if (limited) return .{ .converged = false, .scaled = scaled, .why = .limited };
        if (iter == 0) return .{ .converged = false, .scaled = scaled, .why = .first_iter };
        if (scaled >= 1.0) return .{ .converged = false, .scaled = scaled, .why = .delta };
        if (!plausible(x[0..n], limit)) return .{ .converged = false, .scaled = scaled, .why = .runaway };
        if (residualMisses(opts, residual[0..n], x[0..n], vals, sys.diag_slots[0..n]) != 0)
            return .{ .converged = false, .scaled = scaled, .why = .residual };
        if (!load_ok) return .{ .converged = false, .scaled = scaled, .why = .device };
        if (comptime @hasDecl(S, "checkConvergence")) {
            if (!sys.checkConvergence(x)) return .{ .converged = false, .scaled = scaled, .why = .device };
        }
        // Last, at the x_k `newton` publishes: staging per iterate re-entered every
        // model core once per instance per iteration (18% of
        // scaling/parallel_inverters_100), and devices whose core reads the
        // staged latches (cswitch/vswitch hysteresis) saw F change mid-solve.
        // A device that flips here forces one more iterate.
        // Before staging: a device whose eval reads its staged history (LTRA
        // appends the point it stages) would see this x twice (#53).
        if (comptime @hasDecl(S, "certify") and S.certify) if (stage) sys.certifyPoint(hook, x_old[0..n], t, opts);
        if (comptime @hasDecl(S, "updateStates")) if (stage) {
            if (sys.updateStates(x_old[0..n])) |_| return .{ .converged = false, .scaled = scaled, .why = .flipped };
        };
        // The first-iterate and delta gates passed.
        assert(iter > 0);
        assert(!(scaled >= 1.0));
        return .{ .converged = true, .scaled = scaled };
    }

    fn loadGmin(sys: anytype, vals: ?[]f64, rhs: ?[]f64, x: []const f64, opts: Options) void {
        if (!(opts.gmin > 0)) return;
        const gmin = opts.gmin;
        const stamps = opts.gmin_stamps;
        if (vals) |v| {
            if (stamps.len > 0) {
                for (stamps) |g| v[g.slot] += gmin;
            } else for (sys.diag_slots[0..sys.n]) |slot| v[slot] += gmin;
        }
        if (rhs) |r| {
            if (stamps.len > 0) {
                for (stamps) |g| r[g.row] += gmin * x[g.col];
            } else for (r[0..sys.n], x[0..sys.n]) |*ri, xi| ri.* += gmin * xi;
        }
    }

    fn updateAndNorm(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
        // Up front, so the loop carries no per-slice bounds checks.
        assert(dx.len >= x.len);
        assert(x_old.len >= x.len);
        assert(current_row.len >= x.len);
        var worst: i64 = 0;
        for (x, dx[0..x.len], x_old[0..x.len], current_row[0..x.len]) |*xi, d, *xoi, cur| {
            const xo = xi.*;
            const xn = xo + d;
            xoi.* = xo;
            xi.* = xn;
            const tol = reltol * @max(@abs(xn), @abs(xo)) + (if (cur) abstol else vntol);
            const finite = @abs(xn) < inf and @abs(d) < inf;
            const q = @abs(d) / tol;
            const score: f64 = if (!finite) inf else if (q == q) q else 0;
            worst = @max(worst, @as(i64, @bitCast(score)));
        }
        const result: f64 = @bitCast(worst);
        assert(!(result < 0));
        return result;
    }
};
