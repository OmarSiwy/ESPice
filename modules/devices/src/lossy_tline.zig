const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: Lumped RLGC lossy transmission line (pi-network)
//
//         branch1 (I1)            branch2 (I2)
//   pos1 o----+------[R_eff, L_total]------+----o pos2
//             |                             |
//          [G/2, C/2]                   [G/2, C/2]
//             |                             |
//   neg1 o----+-----------------------------+----o neg2
//
// Four external voltage ports, two internal branch-current unknowns.
// Branch1 enforces current conservation (I1 + I2 = 0).
// Branch2 enforces KVL around the series path (V1 - V2 - R_eff * I_br1 = 0).
//
// KNOWN APPROXIMATION vs ngspice (TRIAGE C4): ngspice's LTRA model solves
// the lossy line by convolving the port histories with the line's impulse
// response (ltra/ltraload.c). This model is a single lumped pi-section:
// correct at DC and for electrically short lines (length << wavelength),
// but it has no propagation delay and understates dispersion, so
// devices/lossy_tline diverges from ngspice on fast transients (~4.5e0
// max rel err). Full fix = LTRA convolution against the history buffer
// (same infrastructure tline.zig uses); deliberately not done — cost is
// high and no current fixture depends on lossy-line delay fidelity.
// ============================================================================

pub const U = enum(u8) {
    pos1 = 0,
    neg1 = 1,
    pos2 = 2,
    neg2 = 3,
    branch1 = 4,
    branch2 = 5,
};

pub const num_ports: usize = 4;

pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // pos1
    .voltage, // neg1
    .voltage, // pos2
    .voltage, // neg2
    .current, // branch1
    .current, // branch2
};

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // Per-unit-length parameters
    r: f32 = 0.0, // Series resistance per unit length (Ohm/m)
    l: f32 = 0.0, // Series inductance per unit length (H/m)
    g: f32 = 0.0, // Shunt conductance per unit length (S/m)
    c: f32 = 0.0, // Shunt capacitance per unit length (F/m)
    len: f32 = 1.0, // Physical length of transmission line (m)

    // Control flags
    nocontrol: bool = false, // Disable timestep control
    steplimit: bool = false, // Always limit timestep to 0.8 * tau_d
    nosteplimit: bool = false, // Never limit timestep to 0.8 * tau_d
    lininterp: bool = false, // Use linear interpolation for history
    quadinterp: bool = false, // Use quadratic interpolation for history
    mixedinterp: bool = false, // Use linear if quadratic results look unacceptable
    truncnr: bool = false, // Use Newton-Raphson for timestep calc in LTRAtrunc
    truncdontcut: bool = false, // Do not limit timestep for impulse response errors

    // Compaction tolerances
    compactrel: f32 = 0.001, // Relative tolerance for straight-line compaction
    compactabs: f32 = 1e-12, // Absolute tolerance for straight-line compaction
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    temp: f32 = 27.0, // Instance temperature (degC)
    dtemp: f32 = 0.0, // Temperature offset from circuit temp (degC)
    m: f32 = 1.0, // Parallel multiplier
    w: f32 = 1e-6, // Instance width (m)
    l: f32 = 1e-6, // Instance length (m)
};

// ============================================================================
// Sparse conductance stamp pattern (G-matrix / Jacobian of i())
//
// From the spec's Jacobian table, 19 non-zero entries:
//
// branch1 row: depends on branch1 (+1) and branch2 (+1)
// branch2 row: depends on pos1 (+1), neg1 (-1), pos2 (-1), neg2 (+1), branch1 (-R_eff)
// pos1 row: depends on branch1 (+1), pos1 (+G_sh), neg1 (-G_sh)
// neg1 row: depends on branch1 (-1), pos1 (-G_sh), neg1 (+G_sh)
// pos2 row: depends on branch2 (+1), pos2 (+G_sh), neg2 (-G_sh)
// neg2 row: depends on branch2 (-1), pos2 (-G_sh), neg2 (+G_sh)
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    // branch1 equation: I_br1 + I_br2 = 0
    .{ .row = @intFromEnum(U.branch1), .col = @intFromEnum(U.branch1) },
    .{ .row = @intFromEnum(U.branch1), .col = @intFromEnum(U.branch2) },
    // branch2 equation: V1 - V2 - R_eff * I_br1 = 0
    .{ .row = @intFromEnum(U.branch2), .col = @intFromEnum(U.pos1) },
    .{ .row = @intFromEnum(U.branch2), .col = @intFromEnum(U.neg1) },
    .{ .row = @intFromEnum(U.branch2), .col = @intFromEnum(U.pos2) },
    .{ .row = @intFromEnum(U.branch2), .col = @intFromEnum(U.neg2) },
    .{ .row = @intFromEnum(U.branch2), .col = @intFromEnum(U.branch1) },
    // pos1 KCL: I_br1 + G_sh * V1
    .{ .row = @intFromEnum(U.pos1), .col = @intFromEnum(U.branch1) },
    .{ .row = @intFromEnum(U.pos1), .col = @intFromEnum(U.pos1) },
    .{ .row = @intFromEnum(U.pos1), .col = @intFromEnum(U.neg1) },
    // neg1 KCL: -I_br1 - G_sh * V1
    .{ .row = @intFromEnum(U.neg1), .col = @intFromEnum(U.branch1) },
    .{ .row = @intFromEnum(U.neg1), .col = @intFromEnum(U.pos1) },
    .{ .row = @intFromEnum(U.neg1), .col = @intFromEnum(U.neg1) },
    // pos2 KCL: I_br2 + G_sh * V2
    .{ .row = @intFromEnum(U.pos2), .col = @intFromEnum(U.branch2) },
    .{ .row = @intFromEnum(U.pos2), .col = @intFromEnum(U.pos2) },
    .{ .row = @intFromEnum(U.pos2), .col = @intFromEnum(U.neg2) },
    // neg2 KCL: -I_br2 - G_sh * V2
    .{ .row = @intFromEnum(U.neg2), .col = @intFromEnum(U.branch2) },
    .{ .row = @intFromEnum(U.neg2), .col = @intFromEnum(U.pos2) },
    .{ .row = @intFromEnum(U.neg2), .col = @intFromEnum(U.neg2) },
};

// ============================================================================
// Sparse capacitance stamp pattern (C-matrix / Jacobian of q())
//
// From the spec's C-matrix table, 9 non-zero entries:
//
// branch2 row: -L_total * I_br1 => (branch2, branch1)
// pos1 row:    C_sh * (V_pos1 - V_neg1) => (pos1, pos1), (pos1, neg1)
// neg1 row:   -C_sh * (V_pos1 - V_neg1) => (neg1, pos1), (neg1, neg1)
// pos2 row:    C_sh * (V_pos2 - V_neg2) => (pos2, pos2), (pos2, neg2)
// neg2 row:   -C_sh * (V_pos2 - V_neg2) => (neg2, pos2), (neg2, neg2)
// ============================================================================

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Series inductance flux: q_br2 = L_total * I_br1
    .{ .row = @intFromEnum(U.branch2), .col = @intFromEnum(U.branch1) },
    // Shunt capacitance at port 1
    .{ .row = @intFromEnum(U.pos1), .col = @intFromEnum(U.pos1) },
    .{ .row = @intFromEnum(U.pos1), .col = @intFromEnum(U.neg1) },
    .{ .row = @intFromEnum(U.neg1), .col = @intFromEnum(U.pos1) },
    .{ .row = @intFromEnum(U.neg1), .col = @intFromEnum(U.neg1) },
    // Shunt capacitance at port 2
    .{ .row = @intFromEnum(U.pos2), .col = @intFromEnum(U.pos2) },
    .{ .row = @intFromEnum(U.pos2), .col = @intFromEnum(U.neg2) },
    .{ .row = @intFromEnum(U.neg2), .col = @intFromEnum(U.pos2) },
    .{ .row = @intFromEnum(U.neg2), .col = @intFromEnum(U.neg2) },
};

// ============================================================================
// Parameter preparation (pure f64 -- no dependence on x)
// ============================================================================

const ResistiveParams = struct { r_eff: f64, g_shunt: f64 };
const ReactiveParams = struct { l_eff: f64, c_shunt: f64 };

/// Effective series resistance and per-port shunt conductance.
fn resistiveParams(model: *const Model, instance: *const Instance) ResistiveParams {
    const r_per_m: f64 = @as(f64, model.r);
    const g_per_m: f64 = @as(f64, model.g);
    const length: f64 = @as(f64, model.len);
    const m: f64 = @as(f64, instance.m);

    // --- Derived totals ---
    const r_total: f64 = r_per_m * length;
    const g_total: f64 = g_per_m * length;

    // --- Singularity guard for series resistance ---
    // G_SHORT = 1e12 => R_min = 1e-12
    const r_eff: f64 = if (r_total > 0.0) r_total else 1.0e-12;

    // --- Shunt conductance per port (pi-network: G_total/2, scaled by m) ---
    const g_shunt: f64 = g_total * 0.5 * m;

    return .{ .r_eff = r_eff, .g_shunt = g_shunt };
}

/// Effective series inductance and per-port shunt capacitance.
fn reactiveParams(model: *const Model, instance: *const Instance) ReactiveParams {
    const l_per_m: f64 = @as(f64, model.l);
    const c_per_m: f64 = @as(f64, model.c);
    const length: f64 = @as(f64, model.len);
    const m: f64 = @as(f64, instance.m);

    // --- Derived totals ---
    const l_total: f64 = l_per_m * length;
    const c_total: f64 = c_per_m * length;

    // --- Series inductance active only when L_total > 0 ---
    const l_eff: f64 = if (l_total > 0.0) l_total else 0.0;

    // --- Shunt capacitance: pi-network (C_total/2 * m at each port) ---
    const c_shunt: f64 = if (c_total > 0.0) c_total * 0.5 * m else 0.0;

    return .{ .l_eff = l_eff, .c_shunt = c_shunt };
}

// ============================================================================
// PrepCache
// ============================================================================

pub const PrepCache = struct { dc: ResistiveParams, q: ReactiveParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{
        .dc = resistiveParams(model, instance),
        .q = reactiveParams(model, instance),
    };
}

// ============================================================================
// Resistive (DC) Contributions -- eval() function
//
// Pi-network lumped topology:
//   Branch1 equation: I_br1 + I_br2 = 0 (current conservation)
//   Branch2 equation: V1 - V2 - R_eff * I_br1 = 0 (KVL series path)
//   KCL at pos1:  +I_br1 + G_shunt * V1
//   KCL at neg1:  -I_br1 - G_shunt * V1
//   KCL at pos2:  +I_br2 + G_shunt * V2
//   KCL at neg2:  -I_br2 - G_shunt * V2
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;
    _ = t;

    const p = &pc.dc;

    // --- Read unknowns ---
    const i_br1 = x[@intFromEnum(U.branch1)];
    const i_br2 = x[@intFromEnum(U.branch2)];

    // --- Port voltages ---
    const v1 = x[@intFromEnum(U.pos1)].sub(x[@intFromEnum(U.neg1)]);
    const v2 = x[@intFromEnum(U.pos2)].sub(x[@intFromEnum(U.neg2)]);

    // --- KCL at external nodes: branch current + shunt conductance ---
    const kcl1 = i_br1.add(v1.scale(p.g_shunt));
    const kcl2 = i_br2.add(v2.scale(p.g_shunt));

    return .{
        kcl1, // pos1
        kcl1.neg(), // neg1
        kcl2, // pos2
        kcl2.neg(), // neg2
        i_br1.add(i_br2), // branch1: current conservation I_br1 + I_br2 = 0
        v1.sub(v2).sub(i_br1.scale(p.r_eff)), // branch2: KVL V1 - V2 - R_eff * I_br1 = 0
    };
}

// ============================================================================
// Reactive (Charge/Flux) Contributions -- q() function
//
// The solver differentiates q w.r.t. time for displacement currents:
//   dq/dt at voltage nodes => capacitive current (C dV/dt)
//   dq/dt at branch equation => inductive voltage (L dI/dt)
//
// Series inductance (flux linkage in branch2 KVL equation):
//   q_branch2 = -L_total * I_br1  (if L_total > 0, else 0; negative — the
//   solver forms F = eval + dq/dt and the row is V1 - V2 - R*I - L*dI/dt)
//
// Shunt capacitance (pi-network charge at each port):
//   C_shunt = C_total / 2 * m
//   q_pos1 = +C_shunt * V1
//   q_neg1 = -C_shunt * V1
//   q_pos2 = +C_shunt * V2
//   q_neg2 = -C_shunt * V2
//   q_branch1 = 0
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;
    _ = t;

    const p = &pc.q;

    // --- Read unknowns ---
    const i_br1 = x[@intFromEnum(U.branch1)];

    // --- Port voltages ---
    const v1 = x[@intFromEnum(U.pos1)].sub(x[@intFromEnum(U.neg1)]);
    const v2 = x[@intFromEnum(U.pos2)].sub(x[@intFromEnum(U.neg2)]);

    // --- Shunt capacitance charges ---
    const q1 = v1.scale(p.c_shunt);
    const q2 = v2.scale(p.c_shunt);

    return .{
        q1, // pos1
        q1.neg(), // neg1
        q2, // pos2
        q2.neg(), // neg2
        S.con(0.0), // branch1
        // branch2 KVL row is V1 - V2 - R*I - L*dI/dt = 0 and the solver forms
        // F = eval + dq/dt, so the flux linkage enters with a NEGATIVE sign
        // (same convention as inductor.zig).
        i_br1.scale(-p.l_eff), // branch2: flux linkage -L_total * I_br1
    };
}

// ============================================================================
// Validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "lossy tline: resistive residual (RG pi-network)" {
    // r=50 Ohm/m, g=0.03125 S/m, len=2 m (all exact in f32):
    //   r_total = 100, g_total = 0.0625, g_shunt = 0.03125 (m=1)
    // x: v_pos1=1, v_neg1=0, v_pos2=0.5, v_neg2=0, i_br1=0.005, i_br2=-0.005
    //   v1 = 1, v2 = 0.5
    //   pos1: 0.005 + 0.03125*1     = 0.03625
    //   neg1:                        -0.03625
    //   pos2: -0.005 + 0.03125*0.5  = 0.010625
    //   neg2:                        -0.010625
    //   br1:  0.005 + (-0.005)      = 0
    //   br2:  1 - 0.5 - 100*0.005   = 0
    const model: Model = .{ .r = 50, .g = 0.03125, .len = 2 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.5, 0.0, 0.005, -0.005 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.03625), out[@intFromEnum(U.pos1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.03625), out[@intFromEnum(U.neg1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.010625), out[@intFromEnum(U.pos2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.010625), out[@intFromEnum(U.neg2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.branch1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.branch2)], 1e-12);
}

test "lossy tline: zero-R singularity guard uses R_min = 1e-12" {
    // r=0 => r_eff = 1e-12; g=0 => no shunt conductance.
    // x: v1=1, v2=0.5, i_br1=2, i_br2=-2
    //   br2: 1 - 0.5 - 1e-12*2 = 0.5 - 2e-12
    //   pos1: 2, pos2: -2
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.5, 0.0, 2.0, -2.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.5 - 2e-12), out[@intFromEnum(U.branch2)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), out[@intFromEnum(U.pos1)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2.0), out[@intFromEnum(U.pos2)], 1e-15);
}

test "lossy tline: charge/flux (LC pi-network)" {
    // l=0.5 H/m, c=0.25 F/m, len=2 m (exact in f32):
    //   l_total = 1, c_total = 0.5, c_shunt = 0.25 (m=1)
    // x: v1=1, v2=0.5, i_br1=0.01
    //   q_pos1 = 0.25*1   = 0.25    q_neg1 = -0.25
    //   q_pos2 = 0.25*0.5 = 0.125   q_neg2 = -0.125
    //   q_br1  = 0
    //   q_br2  = -1*0.01  = -0.01
    const model: Model = .{ .l = 0.5, .c = 0.25, .len = 2 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, 0.0, 0.5, 0.0, 0.01, -0.01 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.25), out[@intFromEnum(U.pos1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.25), out[@intFromEnum(U.neg1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.125), out[@intFromEnum(U.pos2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.125), out[@intFromEnum(U.neg2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.branch1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.01), out[@intFromEnum(U.branch2)], 1e-12);
}

test "lossy tline: zero L and C give zero charge" {
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, 0.0, 0.5, 0.0, 3.0, -3.0 }, &model, &inst, 0);
    inline for (0..n_u) |u| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[u], 1e-15);
    }
}

test "lossy tline: parallel multiplier m scales shunt elements" {
    // g=0.03125 S/m, len=2, m=4 => g_shunt = 0.0625*0.5*4 = 0.125
    // c=0.25 F/m, len=2, m=4    => c_shunt = 0.5*0.5*4 = 1.0
    // x: v1=1, v2=0, branches 0
    //   eval pos1: 0 + 0.125*1 = 0.125
    //   q    pos1: 1.0*1 = 1.0
    const model: Model = .{ .g = 0.03125, .c = 0.25, .len = 2 };
    const inst: Instance = .{ .m = 4 };
    const out_i = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.125), out_i[@intFromEnum(U.pos1)], 1e-12);
    const out_q = contract.qValues(Self, .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out_q[@intFromEnum(U.pos1)], 1e-12);
}
