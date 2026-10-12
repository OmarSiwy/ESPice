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

const HandTrap = struct {
    alpha: f64,
    q_prev: []const f64,
    i_prev: []const f64,
    q_snap: []f64,
    a_vals: []f64,
    has_charge: bool,
};

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

export fn hand_hook_trap_assemble(h: *const HandTrap, ckt: *Ckt, x: [*]const f64, t: f64) void {
    ckt.evalNewton(x[0..ckt.n], t);
    if (h.has_charge) {
        const n: usize = ckt.n;
        num.copySimd(h.q_snap[0..n], ckt.q_vec[0..n]);
        integrator.companionAt(.trapezoidal, true, ckt.rhs[0..n], ckt.q_vec[0..n], h.q_prev[0..n], &.{}, h.i_prev[0..n], .{ .ag0 = h.alpha, .ag2 = 0 });
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

export fn hand_hook_diag_at(h: *const HandTrap, ckt: *Ckt, slot: u32) f64 {
    return if (h.has_charge) ckt.gcAt(h.alpha, slot) else ckt.g_vals[slot];
}
