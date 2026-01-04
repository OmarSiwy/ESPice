const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ---------------------------------------------------------------------------
// Unknowns
// ---------------------------------------------------------------------------
// External ports: p, n, ctrl_p, ctrl_n (4 external terminals)
// Internal: branch (current through the voltage source)
pub const U = enum(u8) {
    p = 0,
    n = 1,
    ctrl_p = 2,
    ctrl_n = 3,
    branch = 4,
};
pub const num_ports: usize = 4;

// The branch unknown is a current, not a voltage.
pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // p
    .voltage, // n
    .voltage, // ctrl_p
    .voltage, // ctrl_n
    .current, // branch
};

// ---------------------------------------------------------------------------
// Model parameters -- shared across instances
// ---------------------------------------------------------------------------
pub const Model = struct {
    // Polynomial coefficients
    c0: f32 = 0.0, // Constant term (V)
    c1: f32 = 0.0, // Linear coefficient (V/V)
    c2: f32 = 0.0, // Quadratic coefficient (V/V^2)

    // Temperature coefficients
    tnom: f32 = 27.0, // Nominal (reference) temperature (C)
    tc1: f32 = 0.0, // First-order temperature coefficient (1/K)
    tc2: f32 = 0.0, // Second-order temperature coefficient (1/K^2)
    reciproctc: i32 = 0, // When 1, use reciprocal temperature factor

    // Multiplier mode
    reciprocm: i32 = 0, // When 1, divide by multiplier instead of multiply

    // Output mode: 0 = voltage source (V={...}), 1 = current source (I={...})
    imode: i32 = 0,
};

// ---------------------------------------------------------------------------
// Instance parameters -- per-device
// ---------------------------------------------------------------------------
pub const Instance = struct {
    temp: f32 = 27.0, // Instance operating temperature (C)
    dtemp: f32 = 0.0, // Instance temperature offset (C)
    m: f32 = 1.0, // Output multiplier
};

// ---------------------------------------------------------------------------
// Sparse conductance stamp pattern
// ---------------------------------------------------------------------------
// Non-zero Jacobian entries:
//   F_p         depends on I_branch        -> (p, branch)
//   F_n         depends on I_branch        -> (n, branch)
//   F_branch    depends on V(p)            -> (branch, p)
//   F_branch    depends on V(n)            -> (branch, n)
//   F_branch    depends on V(ctrl_p)       -> (branch, ctrl_p)
//   F_branch    depends on V(ctrl_n)       -> (branch, ctrl_n)

// ---------------------------------------------------------------------------
// Physics function: KCL/KVL residuals (value-form)
// ---------------------------------------------------------------------------
// F_p        = +I_branch
// F_n        = -I_branch
// F_ctrl_p   = 0
// F_ctrl_n   = 0
// F_branch   = V(p) - V(n) - factor * (c0 + c1*Vctrl + c2*Vctrl^2)
//
// The AD framework extracts all Jacobian entries automatically from the
// dual-number evaluation of this function.

/// Combined temperature/multiplier scaling factor. Pure f64 — no x.
fn scaleFactor(model: *const Model, instance: *const Instance) f64 {
    const tnom: f64 = @as(f64, model.tnom);
    const tc1: f64 = @as(f64, model.tc1);
    const tc2: f64 = @as(f64, model.tc2);

    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const m: f64 = @as(f64, instance.m);

    // Temperature factor: delta = (temp + dtemp) - tnom
    const delta = (temp + dtemp) - tnom;
    const ft_raw = @mulAdd(f64, tc2, delta * delta, @mulAdd(f64, tc1, delta, 1.0));

    // Reciprocal temperature mode: if reciproctc == 1, invert ft
    const ft = if (model.reciproctc == 1) 1.0 / ft_raw else ft_raw;

    // Combined scaling factor: ft * m or ft / m
    return if (model.reciprocm == 1) ft / m else ft * m;
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // Enum indices
    const p = @intFromEnum(U.p);
    const n = @intFromEnum(U.n);
    const cp = @intFromEnum(U.ctrl_p);
    const cn = @intFromEnum(U.ctrl_n);
    const br = @intFromEnum(U.branch);

    // x-independent parameter prep (plain f64)
    const c0: f64 = @as(f64, model.c0);
    const c1: f64 = @as(f64, model.c1);
    const c2: f64 = @as(f64, model.c2);
    const factor = scaleFactor(model, instance);

    // Control voltage: V(ctrl_p) - V(ctrl_n)
    const v_ctrl = x[cp].sub(x[cn]);

    // Polynomial expression: c0 + c1*Vctrl + c2*Vctrl^2
    const expr = v_ctrl.mul(v_ctrl).scale(c2).add(v_ctrl.scale(c1)).addC(c0);

    // Scaled source value: factor * expr (a voltage or a current per imode)
    const source = expr.scale(factor);

    // Branch residual:
    //   voltage mode (imode=0): F_branch = V(p) - V(n) - source  (KVL)
    //   current mode (imode=1): F_branch = I_branch - source
    const f_branch = if (model.imode != 0)
        x[br].sub(source)
    else
        x[p].sub(x[n]).sub(source);

    // KCL / KVL residuals
    return .{
        // F_p = +I_branch
        x[br],
        // F_n = -I_branch
        x[br].neg(),
        // F_ctrl_p = 0 (infinite input impedance)
        S.con(0.0),
        // F_ctrl_n = 0 (infinite input impedance)
        S.con(0.0),
        f_branch,
    };
}

// ---------------------------------------------------------------------------
// Compile-time contract validation
// ---------------------------------------------------------------------------
comptime {
    contract.validate(Self);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bsource: polynomial residual, unity factor" {
    // c0=1, c1=2, c2=3, Vctrl = 0.5 - 0 = 0.5
    //   expr = 1 + 2*0.5 + 3*0.25 = 1 + 1 + 0.75 = 2.75
    // Defaults: temp=27, dtemp=0, tnom=27 -> delta=0 -> ft=1; m=1 -> factor=1
    //   V_source = 2.75
    // x = { v_p=2, v_n=0, v_cp=0.5, v_cn=0, i_br=0.01 }
    //   F_p = 0.01, F_n = -0.01, F_cp = F_cn = 0
    //   F_br = 2 - 0 - 2.75 = -0.75
    const model: Model = .{ .c0 = 1.0, .c1 = 2.0, .c2 = 3.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 2.0, 0.0, 0.5, 0.0, 0.01 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.01), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.01), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.75), out[4], 1e-12);
}

test "bsource: current mode residual" {
    // imode=1, c2=0.001, Vctrl = 2 - 0 = 2 -> I_source = 0.001*4 = 0.004
    // x = { v_p=1, v_n=0, v_cp=2, v_cn=0, i_br=0.005 }
    //   F_br = 0.005 - 0.004 = 0.001; F_p/F_n unchanged (+/- I_branch)
    const model: Model = .{ .c2 = 0.001, .imode = 1 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 2.0, 0.0, 0.005 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.005), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.005), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.001), out[4], 1e-12);
}

test "bsource: temperature factor and reciprocal multiplier" {
    // tc1 = 0.015625 (exact in f32), temp=127, tnom=27 -> delta=100
    //   ft = 1 + 0.015625*100 = 2.5625
    // reciprocm=1, m=2 -> factor = 2.5625 / 2 = 1.28125
    // c1=1, Vctrl=1 -> expr = 1 -> V_source = 1.28125
    // x = { v_p=2, v_n=0, v_cp=1, v_cn=0, i_br=0 }
    //   F_br = 2 - 0 - 1.28125 = 0.71875
    const model: Model = .{ .c1 = 1.0, .tc1 = 0.015625, .reciprocm = 1 };
    const inst: Instance = .{ .temp = 127.0, .m = 2.0 };
    const out = contract.evalValues(Self, .{ 2.0, 0.0, 1.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.71875), out[4], 1e-12);
}

test "bsource: reciprocal temperature mode" {
    // tc1 = 0.015625, delta = 100 -> ft_raw = 2.5625; reciproctc=1 -> ft = 1/2.5625
    // m=1 -> factor = 1/2.5625 = 0.39024390243902439...
    // c1=1, Vctrl=2 -> expr = 2 -> V_source = 2/2.5625 = 0.78048780487804878...
    // x = { v_p=1, v_n=0, v_cp=2, v_cn=0, i_br=0 }
    //   F_br = 1 - 2/2.5625
    const model: Model = .{ .c1 = 1.0, .tc1 = 0.015625, .reciproctc = 1 };
    const inst: Instance = .{ .temp = 127.0 };
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 2.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.0 - 2.0 / 2.5625), out[4], 1e-12);
}
