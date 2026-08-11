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
    lu: ?solver.sparse_lu.SparseLu,
    tri: ?solver.tridiag.TriDiag,
    bbd: ?solver.bbd.Bbd,
};

export fn hand_engine_solve(e: *HandEngines, x: [*]f64, n: u32) void {
    if (e.tri) |*tri| return tri.solve(x[0..n]);
    if (e.bbd) |*bbd| return bbd.solveInPlace(x[0..n]);
    e.lu.?.solve(x[0..n], x[0..n]);
}
