const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ---------------------------------------------------------------------------
// Unknowns — four external voltage terminals, two internal voltage nodes,
//             two branch currents
//
// The lossless transmission line (SPICE T element) uses a Bergeron DC-coupled
// companion model. At each port, a conductance G0 = 1/Z0 connects the
// positive terminal to an internal node, and a branch current flows from the
// negative terminal into the internal node. The two ports are coupled by
// symmetric Bergeron branch equations.
//
//   Port 1:                              Port 2:
//     pos1 ---[G0=1/Z0]--- int1           pos2 ---[G0=1/Z0]--- int2
//                            |                                    |
//     neg1 -----ibr1--------+             neg2 -----ibr2--------+
// ---------------------------------------------------------------------------

pub const U = enum(u8) {
    pos1 = 0,
    neg1 = 1,
    pos2 = 2,
    neg2 = 3,
    int1 = 4,
    int2 = 5,
    ibr1 = 6,
    ibr2 = 7,
};

pub const num_ports: usize = 4;

pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // pos1
    .voltage, // neg1
    .voltage, // pos2
    .voltage, // neg2
    .voltage, // int1
    .voltage, // int2
    .current, // ibr1
    .current, // ibr2
};

// ---------------------------------------------------------------------------
// Model parameters
//
// | Parameter | Default    | Description                               |
// |-----------|------------|-------------------------------------------|
// | z0        | 50.0       | Characteristic impedance (Ohm)            |
// | f         | 1e9        | Frequency at which nl is specified (Hz)   |
// | td        | 0.0        | Transmission delay (s); 0 => nl/f         |
// | nl        | 0.25       | Normalized electrical length (wavelengths) |
// | v1        | 0.0        | Initial voltage at end 1 (V)              |
// | v2        | 0.0        | Initial voltage at end 2 (V)              |
// | i1        | 0.0        | Initial current at end 1 (A)              |
// | i2        | 0.0        | Initial current at end 2 (A)              |
// | reltol    | 1.0        | Relative derivative tolerance              |
// | abstol    | 1.0        | Absolute derivative tolerance              |
// ---------------------------------------------------------------------------

pub const Model = struct {
    z0: f32 = 50.0,
    f: f32 = 1.0e9,
    td: f32 = 0.0,
    nl: f32 = 0.25,
    v1: f32 = 0.0,
    v2: f32 = 0.0,
    i1: f32 = 0.0,
    i2: f32 = 0.0,
    reltol: f32 = 1.0,
    abstol: f32 = 1.0,
};

// ---------------------------------------------------------------------------
// Instance parameters
//
// | Parameter | Default | Description                |
// |-----------|---------|----------------------------|
// | temp      | 300.15  | Device temperature (K)     |
// | m         | 1.0     | Parallel multiplier        |
// ---------------------------------------------------------------------------

pub const Instance = struct {
    temp: f32 = 300.15,
    m: f32 = 1.0,
};

// ---------------------------------------------------------------------------
// History configuration — delay-line device (Bergeron companion model)
//
// Signal layout recorded per accepted step (gatherHistSignals):
//   [0] = v_port1 = V(int1) - V(neg1)   (voltage across the internal
//   [1] = i_br1                          Bergeron source at port 1)
//   [2] = v_port2 = V(int2) - V(neg2)
//   [3] = i_br2
//
// histInject reads these back at t - td to build the delayed sources
//   e1(t) = v_port2(t-td) + Z0 * i_br2(t-td)
//   e2(t) = v_port1(t-td) + Z0 * i_br1(t-td)
// and adds -e1 / -e2 to the ibr1 / ibr2 residual rows, completing the
// branch equations  V(int) - V(neg) - e = 0.
// ---------------------------------------------------------------------------

/// Returns the propagation delay. If td==0, computed from nl/f.
pub fn delays(model: *const Model) [1]f64 {
    const td: f64 = @floatCast(model.td);
    if (td > 0.0) return .{td};
    const nl: f64 = @floatCast(model.nl);
    const f: f64 = @floatCast(model.f);
    if (f > 0.0) return .{nl / f};
    return .{1e-9}; // fallback
}

/// Number of signals stored in the history buffer per tline instance.
/// [0] = v_port1, [1] = i_br1, [2] = v_port2, [3] = i_br2
pub const n_hist_signals: u32 = 4;

/// Gather the signals to record into the history buffer.
/// ngspice traload.c: TRAinput1 = (V(pos2) - V(neg2)) + Z0 * I(brEq2) — the
/// recorded voltage is the PORT TERMINAL voltage, not the internal EMF node.
pub fn gatherHistSignals(x: [n_u]f64) [n_hist_signals]f64 {
    return .{
        // ngspice tranload: the recorded wave voltage is the EXTERNAL port
        // voltage V(pos)-V(neg), not the internal node behind Z0.
        x[@intFromEnum(U.pos1)] - x[@intFromEnum(U.neg1)], // v_port1
        x[@intFromEnum(U.ibr1)], // i_br1
        x[@intFromEnum(U.pos2)] - x[@intFromEnum(U.neg2)], // v_port2
        x[@intFromEnum(U.ibr2)], // i_br2
    };
}

/// Delayed-source RHS injection (pure f64 — history is frozen w.r.t. the
/// present unknowns, so it carries no Jacobian entries).
///   adds[ibr1] = -e1 = -(v_port2(t-td) + Z0 * i_br2(t-td))
///   adds[ibr2] = -e2 = -(v_port1(t-td) + Z0 * i_br1(t-td))
/// eval() stamps V(int)-V(neg) into the same rows, so the total residual is
/// V(int) - V(neg) - e, matching the old solver's stampRHS(-e) injection.
/// At DC (empty history, lookup returns 0): e=0 gives V(int)=V(neg).
pub fn histInject(model: *const Model, lookup: anytype, t: f64) [n_u]f64 {
    const td = delays(model)[0];
    const t_delayed = t - td;
    const z0: f64 = @floatCast(model.z0);

    // e1 = V_port2(t-td) + Z0 * I_br2(t-td)
    const e1 = lookup.at(t_delayed, 2) + z0 * lookup.at(t_delayed, 3);

    // e2 = V_port1(t-td) + Z0 * I_br1(t-td)
    const e2 = lookup.at(t_delayed, 0) + z0 * lookup.at(t_delayed, 1);

    var adds = [_]f64{0.0} ** n_u;
    adds[@intFromEnum(U.ibr1)] = -e1;
    adds[@intFromEnum(U.ibr2)] = -e2;
    return adds;
}

// ---------------------------------------------------------------------------
// Sparse conductance stamp pattern (Jacobian non-zeros)
//
// The branch equations only contain LOCAL terms (no far-port coupling).
// The delayed source terms (e1, e2) are injected by the solver as RHS
// contributions via histInject.
//
// From the conductance stamps (G0 blocks):
//   pos1-pos1: +G0    pos1-int1: -G0
//   int1-pos1: -G0    int1-int1: +G0
//   pos2-pos2: +G0    pos2-int2: -G0
//   int2-pos2: -G0    int2-int2: +G0
//
// From branch current stamps:
//   neg1-ibr1: -1     int1-ibr1: +1
//   neg2-ibr2: -1     int2-ibr2: +1
//
// From Bergeron branch equations (local terms only):
//   ibr1-int1: +1     ibr1-neg1: -1
//   ibr2-int2: +1     ibr2-neg2: -1
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// PrepCache: hot eval data in contiguous array (SoA over devices)
// ---------------------------------------------------------------------------

pub const PrepCache = struct { g0m: f64, m: f64, z0: f64 };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    const z0: f64 = @as(f64, model.z0);
    const m: f64 = @as(f64, instance.m);
    return .{ .g0m = m / z0, .m = m, .z0 = z0 };
}

// ---------------------------------------------------------------------------
// Physics: current contributions (MNA formulation, Bergeron companion)
//
// t == 0 selects the DC operating-point form (ngspice traload MODEDC): the
// delayed sources have no history yet, so the branch equations couple the
// two ports directly:  V(int1)-V(neg1) - (V(pos2)-V(neg2)) - Z0*I(br2) = 0
// (and symmetrically), which yields V1 = V2, I1 = -I2 at DC. For t > 0 the
// far-port terms come from histInject as delayed RHS sources instead.
// ---------------------------------------------------------------------------

fn evalInner(comptime S: type, x: [n_u]S, g0m: f64, m: f64, z0: f64, dc: bool) [n_u]S {
    const pos1 = @intFromEnum(U.pos1);
    const neg1 = @intFromEnum(U.neg1);
    const pos2 = @intFromEnum(U.pos2);
    const neg2 = @intFromEnum(U.neg2);
    const int1 = @intFromEnum(U.int1);
    const int2 = @intFromEnum(U.int2);
    const ibr1 = @intFromEnum(U.ibr1);
    const ibr2 = @intFromEnum(U.ibr2);

    var out: [n_u]S = undefined;
    out[pos1] = x[pos1].sub(x[int1]).scale(g0m);
    out[neg1] = x[ibr1].scale(m).neg();
    out[pos2] = x[pos2].sub(x[int2]).scale(g0m);
    out[neg2] = x[ibr2].scale(m).neg();
    out[int1] = x[int1].sub(x[pos1]).scale(g0m).add(x[ibr1].scale(m));
    out[int2] = x[int2].sub(x[pos2]).scale(g0m).add(x[ibr2].scale(m));
    out[ibr1] = x[int1].sub(x[neg1]);
    out[ibr2] = x[int2].sub(x[neg2]);
    if (dc) {
        out[ibr1] = out[ibr1].sub(x[pos2].sub(x[neg2])).sub(x[ibr2].scale(z0));
        out[ibr2] = out[ibr2].sub(x[pos1].sub(x[neg1])).sub(x[ibr1].scale(z0));
    }
    return out;
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    const z0: f64 = @as(f64, model.z0);
    const g0: f64 = 1.0 / z0;
    const m: f64 = @as(f64, instance.m);
    return evalInner(S, x, g0 * m, m, z0, t == 0);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    return evalInner(S, x, pc.g0m, pc.m, pc.z0, t == 0);
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

test "tline: instantaneous residual, z0=50" {
    // Old-formula arithmetic (g0 = 1/50 = 0.02, m = 1):
    //   x = { pos1=1.0, neg1=0.0, pos2=0.0, neg2=0.0,
    //         int1=0.5, int2=0.0, ibr1=0.01, ibr2=0.0 }
    //   f(pos1) = 0.02*(1.0-0.5)          =  0.01
    //   f(neg1) = -0.01                   = -0.01
    //   f(pos2) = 0.02*(0.0-0.0)          =  0.0
    //   f(neg2) = -0.0                    =  0.0
    //   f(int1) = 0.02*(0.5-1.0) + 0.01   =  0.0
    //   f(int2) = 0.02*(0.0-0.0) + 0.0    =  0.0
    //   f(ibr1) = 0.5 - 0.0               =  0.5
    //   f(ibr2) = 0.0 - 0.0               =  0.0
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(
        Self,
        .{ 1.0, 0.0, 0.0, 0.0, 0.5, 0.0, 0.01, 0.0 },
        &model,
        &inst,
        0,
    );
    try testing.expectApproxEqAbs(@as(f64, 0.01), out[@intFromEnum(U.pos1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.01), out[@intFromEnum(U.neg1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.pos2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.neg2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.int1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.int2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out[@intFromEnum(U.ibr1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.ibr2)], 1e-12);
}

test "tline: parallel multiplier m scales KCL rows, not branch equations" {
    // g0*m = 0.02*4 = 0.08; branch rows are voltage equations (unscaled).
    //   f(pos1) = 0.08*(2.0-1.0) = 0.08
    //   f(neg1) = -4*0.05        = -0.2
    //   f(int1) = 0.08*(1.0-2.0) + 4*0.05 = 0.12
    //   f(ibr1) = 1.0 - 0.0      = 1.0
    const model: Model = .{};
    const inst: Instance = .{ .m = 4 };
    const out = contract.evalValues(
        Self,
        .{ 2.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.05, 0.0 },
        &model,
        &inst,
        0,
    );
    try testing.expectApproxEqAbs(@as(f64, 0.08), out[@intFromEnum(U.pos1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.2), out[@intFromEnum(U.neg1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.12), out[@intFromEnum(U.int1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[@intFromEnum(U.ibr1)], 1e-12);
}

test "tline: delays from td, and from nl/f when td==0" {
    // (tolerances account for f32 parameter storage: rel err ~6e-8)
    const m_td: Model = .{ .td = 5e-9 };
    try testing.expectApproxEqAbs(@as(f64, 5e-9), delays(&m_td)[0], 5e-16);

    // td=0 => nl/f = 0.25 / 1e9 = 2.5e-10
    const m_nlf: Model = .{};
    try testing.expectApproxEqAbs(@as(f64, 2.5e-10), delays(&m_nlf)[0], 5e-17);
}

test "tline: gatherHistSignals layout" {
    const x = [n_u]f64{ 1.0, 0.1, 2.0, 0.2, 1.5, 2.5, 0.01, 0.02 };
    const sig = gatherHistSignals(x);
    try testing.expectApproxEqAbs(@as(f64, 0.9), sig[0], 1e-12); // pos1 - neg1
    try testing.expectApproxEqAbs(@as(f64, 0.01), sig[1], 1e-12); // ibr1
    try testing.expectApproxEqAbs(@as(f64, 1.8), sig[2], 1e-12); // pos2 - neg2
    try testing.expectApproxEqAbs(@as(f64, 0.02), sig[3], 1e-12); // ibr2
}

test "tline: histInject Bergeron delayed sources" {
    // Constant-history mock lookup:
    //   sig0 (v_port1) = 1.0, sig1 (i_br1) = 0.01
    //   sig2 (v_port2) = 2.0, sig3 (i_br2) = 0.03
    // z0 = 50:
    //   e1 = 2.0 + 50*0.03 = 3.5  -> adds[ibr1] = -3.5
    //   e2 = 1.0 + 50*0.01 = 1.5  -> adds[ibr2] = -1.5
    const MockLookup = struct {
        pub fn at(_: @This(), t_query: f64, signal: usize) f64 {
            _ = t_query;
            return switch (signal) {
                0 => 1.0,
                1 => 0.01,
                2 => 2.0,
                3 => 0.03,
                else => unreachable,
            };
        }
    };
    const model: Model = .{ .td = 1e-9 };
    const adds = histInject(&model, MockLookup{}, 5e-9);
    try testing.expectApproxEqAbs(@as(f64, -3.5), adds[@intFromEnum(U.ibr1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1.5), adds[@intFromEnum(U.ibr2)], 1e-12);
    // All non-branch rows receive nothing.
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.pos1)], 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.neg1)], 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.pos2)], 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.neg2)], 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.int1)], 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.int2)], 0);
}
