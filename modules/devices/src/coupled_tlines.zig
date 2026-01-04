// Coupled Transmission Lines (CPL) — 2-conductor symmetric system with modal decomposition
//
// History-dependent device: even/odd mode propagation with lumped losses.
// Six external terminals: a1, a2, gnd_a, b1, b2, gnd_b.

const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminals
// ============================================================================
// All six terminals are external ports. No internal nodes.
// a1/a2 = line 1/2 near-end (port A), b1/b2 = line 1/2 far-end (port B),
// gnd_a/gnd_b = independent ground references for each port pair.

pub const U = enum(u8) {
    a1 = 0,
    a2 = 1,
    gnd_a = 2,
    b1 = 3,
    b2 = 4,
    gnd_b = 5,
};

pub const num_ports: usize = 6;

// ============================================================================
// Model Parameters (Per-Unit-Length)
// ============================================================================

pub const Model = struct {
    // Self per-unit-length parameters (diagonal)
    r: f32 = 0.2, // Self resistance [Ohm/m]
    l: f32 = 9.13e-9, // Self inductance [H/m]
    c: f32 = 3.65e-13, // Self capacitance [F/m]
    g: f32 = 0.0, // Self conductance [S/m]
    // Mutual per-unit-length parameters (off-diagonal)
    lm: f32 = 0.0, // Mutual inductance [H/m]
    cm: f32 = 0.0, // Mutual capacitance [F/m] (typically negative)
    rm: f32 = 0.0, // Mutual resistance [Ohm/m]
    gm: f32 = 0.0, // Mutual conductance [S/m]
    // Physical length
    length: f32 = 10.0, // Line length [m]
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    temp: f32 = 300.15, // Device temperature [K]
    m: f32 = 1.0, // Parallel multiplier
};

// ============================================================================
// Modal parameter preparation (pure f64 — no dependence on x)
// ============================================================================

const ModalParams = struct {
    y0_even: f64,
    y0_odd: f64,
    g_series_even: f64,
    g_series_odd: f64,
    g_even_total: f64,
    g_odd_total: f64,
};

/// Even/odd mode admittances and lumped-loss conductances from the
/// per-unit-length RLGC parameters. Pure f64 — no x.
fn modalParams(model: *const Model) ModalParams {
    const ll: f64 = @as(f64, model.l);
    const cc: f64 = @as(f64, model.c);
    const lm: f64 = @as(f64, model.lm);
    const cm: f64 = @as(f64, model.cm);
    const rr: f64 = @as(f64, model.r);
    const gg: f64 = @as(f64, model.g);
    const rm: f64 = @as(f64, model.rm);
    const gm_pul: f64 = @as(f64, model.gm);
    const length: f64 = @as(f64, model.length);

    // --- Modal decomposition ---
    // Even mode: L+Lm, C+Cm; Odd mode: L-Lm, C-Cm
    // Clamp to avoid degenerate values
    const l_even = @max(ll + lm, 1.0e-30);
    const c_even = @max(cc + cm, 1.0e-30);
    const l_odd = @max(ll - lm, 1.0e-30);
    const c_odd = @max(cc - cm, 1.0e-30);

    // --- Characteristic impedance and admittance (per mode, lossless) ---
    const z0_even = @sqrt(l_even / c_even);
    const z0_odd = @sqrt(l_odd / c_odd);

    const y0_even: f64 = if (z0_even > 0.0) 1.0 / z0_even else 1.0e-12;
    const y0_odd: f64 = if (z0_odd > 0.0) 1.0 / z0_odd else 1.0e-12;

    // --- Per-mode lumped losses ---
    // Series resistance (total for full line length)
    const r_self_clamped = @max(rr, 1.0e-4);
    const r_even_total = (r_self_clamped + rm) * length;
    const r_odd_total = @max((r_self_clamped - rm) * length, 1.0e-30);

    return .{
        .y0_even = y0_even,
        .y0_odd = y0_odd,
        // Series conductance (inverse of series resistance)
        .g_series_even = 1.0 / r_even_total,
        .g_series_odd = 1.0 / r_odd_total,
        // Shunt conductance (total for full line length)
        .g_even_total = (gg + gm_pul) * length,
        .g_odd_total = @max((gg - gm_pul) * length, 0.0),
    };
}

// ============================================================================
// History Configuration
// ============================================================================
// Signal layout (n_hist_signals = 4): the four MODAL port voltages,
// recorded at every accepted step:
//   [0] = v_a_even = (v_a1 + v_a2) / sqrt(2)   (port A, even mode)
//   [1] = v_a_odd  = (v_a1 - v_a2) / sqrt(2)   (port A, odd mode)
//   [2] = v_b_even = (v_b1 + v_b2) / sqrt(2)   (port B, even mode)
//   [3] = v_b_odd  = (v_b1 - v_b2) / sqrt(2)   (port B, odd mode)
// These are exactly the four y0-weighted terms of the old histOut sum,
// split per (port, mode) so that histInject can apply the mode admittance
// weights (which need the Model, unavailable in gatherHistSignals) and the
// per-mode delays individually. gatherHistSignals depends only on x.

const inv_sqrt2 = 0.7071067811865475;

pub const n_hist_signals: u32 = 4;

/// Gather the four modal port voltages to record into the history buffer.
pub fn gatherHistSignals(x: [n_u]f64) [n_hist_signals]f64 {
    const v_a1 = x[@intFromEnum(U.a1)] - x[@intFromEnum(U.gnd_a)];
    const v_a2 = x[@intFromEnum(U.a2)] - x[@intFromEnum(U.gnd_a)];
    const v_b1 = x[@intFromEnum(U.b1)] - x[@intFromEnum(U.gnd_b)];
    const v_b2 = x[@intFromEnum(U.b2)] - x[@intFromEnum(U.gnd_b)];
    return .{
        (v_a1 + v_a2) * inv_sqrt2, // v_a_even
        (v_a1 - v_a2) * inv_sqrt2, // v_a_odd
        (v_b1 + v_b2) * inv_sqrt2, // v_b_even
        (v_b1 - v_b2) * inv_sqrt2, // v_b_odd
    };
}

/// Returns the two modal propagation delays: [even, odd].
pub fn delays(model: *const Model) [2]f64 {
    const ll: f64 = @as(f64, model.l);
    const cc: f64 = @as(f64, model.c);
    const lm: f64 = @as(f64, model.lm);
    const cm: f64 = @as(f64, model.cm);
    const length: f64 = @as(f64, model.length);

    // Eigenvalues of L*C product matrix
    const lambda_even = @max((ll + lm) * (cc + cm), 1.0e-30);
    const lambda_odd = @max((ll - lm) * (cc - cm), 1.0e-30);

    const tau_even = length * @sqrt(lambda_even);
    const tau_odd = length * @sqrt(lambda_odd);

    return .{ tau_even, tau_odd };
}

/// Delayed-wave RHS injection (pure f64 — reads only recorded history).
///
/// Per mode m with delay tau_m and admittance y0_m, the far-end wave that
/// arrives at the near port is approximated by the matched-source form
/// (v + z0*i ~= 2*v when the far port is matched, i.e. i ~= y0*v), so the
/// injected residual current at the near port is
///   -2 * y0_m * v_far_m(t - tau_m)
/// The port currents are not unknowns of this device, so the exact Bergeron
/// wave v + z0*i cannot be recorded; this matched approximation gives full
/// transmission into a matched load and reduces to the old instantaneous
/// admittance stamp at DC (injection is transient-only).
pub fn histInject(model: *const Model, lookup: anytype, t: f64) [n_u]f64 {
    const p = modalParams(model);
    const td = delays(model);
    const tau_even = td[0];
    const tau_odd = td[1];

    // Delayed far-end modal voltages (signal indices per layout above)
    const v_a_even_d = lookup.at(t - tau_even, 0);
    const v_a_odd_d = lookup.at(t - tau_odd, 1);
    const v_b_even_d = lookup.at(t - tau_even, 2);
    const v_b_odd_d = lookup.at(t - tau_odd, 3);

    // Modal injected currents (matched-source approximation)
    const i_a_even = -2.0 * p.y0_even * v_b_even_d;
    const i_a_odd = -2.0 * p.y0_odd * v_b_odd_d;
    const i_b_even = -2.0 * p.y0_even * v_a_even_d;
    const i_b_odd = -2.0 * p.y0_odd * v_a_odd_d;

    // Modal-to-physical transformation (inverse)
    const i_a1 = (i_a_even + i_a_odd) * inv_sqrt2;
    const i_a2 = (i_a_even - i_a_odd) * inv_sqrt2;
    const i_b1 = (i_b_even + i_b_odd) * inv_sqrt2;
    const i_b2 = (i_b_even - i_b_odd) * inv_sqrt2;

    // Ground node return currents (KCL conservation)
    return .{
        i_a1,
        i_a2,
        -(i_a1 + i_a2),
        i_b1,
        i_b2,
        -(i_b1 + i_b2),
    };
}

// ============================================================================
// PrepCache
// ============================================================================

pub const PrepCache = ModalParams;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    _ = instance;
    return modalParams(model);
}

// ============================================================================
// Physics Function (instantaneous part: wave admittance + lumped losses)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = t;

    // --- Parameter prep (pure f64) ---
    const p = pc;
    const m_mult: f64 = @as(f64, instance.m);

    // --- Read physical port voltages ---
    const v_a1 = x[@intFromEnum(U.a1)].sub(x[@intFromEnum(U.gnd_a)]);
    const v_a2 = x[@intFromEnum(U.a2)].sub(x[@intFromEnum(U.gnd_a)]);
    const v_b1 = x[@intFromEnum(U.b1)].sub(x[@intFromEnum(U.gnd_b)]);
    const v_b2 = x[@intFromEnum(U.b2)].sub(x[@intFromEnum(U.gnd_b)]);

    // --- Physical-to-modal voltage transformation ---
    const v_a_even = v_a1.add(v_a2).scale(inv_sqrt2);
    const v_a_odd = v_a1.sub(v_a2).scale(inv_sqrt2);
    const v_b_even = v_b1.add(v_b2).scale(inv_sqrt2);
    const v_b_odd = v_b1.sub(v_b2).scale(inv_sqrt2);

    // --- Per-mode current contributions ---

    // DC series resistance stamp (port A to port B per mode)
    const i_series_even = v_a_even.sub(v_b_even).scale(p.g_series_even);
    const i_series_odd = v_a_odd.sub(v_b_odd).scale(p.g_series_odd);

    // Total modal current at each port:
    // wave admittance stamp (instantaneous) + series + shunt.
    // Port A: wave + series + shunt
    const i_a_even = v_a_even.scale(p.y0_even).add(i_series_even).add(v_a_even.scale(p.g_even_total));
    const i_a_odd = v_a_odd.scale(p.y0_odd).add(i_series_odd).add(v_a_odd.scale(p.g_odd_total));
    // Port B: wave - series + shunt (sign reversal on series at port B)
    const i_b_even = v_b_even.scale(p.y0_even).sub(i_series_even).add(v_b_even.scale(p.g_even_total));
    const i_b_odd = v_b_odd.scale(p.y0_odd).sub(i_series_odd).add(v_b_odd.scale(p.g_odd_total));

    // --- Modal-to-physical current transformation (inverse) ---
    const i_a1_phys = i_a_even.add(i_a_odd).scale(inv_sqrt2);
    const i_a2_phys = i_a_even.sub(i_a_odd).scale(inv_sqrt2);
    const i_b1_phys = i_b_even.add(i_b_odd).scale(inv_sqrt2);
    const i_b2_phys = i_b_even.sub(i_b_odd).scale(inv_sqrt2);

    // --- GMIN convergence aid ---
    const gmin: f64 = 1.0e-12;

    // --- Final node currents (KCL residuals), scaled by multiplier ---
    const i_out_a1 = i_a1_phys.add(v_a1.scale(gmin)).scale(m_mult);
    const i_out_a2 = i_a2_phys.add(v_a2.scale(gmin)).scale(m_mult);
    const i_out_b1 = i_b1_phys.add(v_b1.scale(gmin)).scale(m_mult);
    const i_out_b2 = i_b2_phys.add(v_b2.scale(gmin)).scale(m_mult);

    // Ground node return currents (KCL conservation)
    return .{
        i_out_a1,
        i_out_a2,
        i_out_a1.add(i_out_a2).neg(),
        i_out_b1,
        i_out_b2,
        i_out_b1.add(i_out_b2).neg(),
    };
}

// ============================================================================
// Sparse conductance stamp pattern
// ============================================================================
// The device stamps on all six nodes. The conductance matrix is not fully
// dense — ground nodes only couple to their respective signal nodes.
// Signal nodes at port A: a1, a2 (couple to each other and to gnd_a)
// Signal nodes at port B: b1, b2 (couple to each other and to gnd_b)
// Series resistance couples A-side to B-side nodes.

// ============================================================================
// Noise sources: thermal noise from series resistance and shunt conductance
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise from series resistance between port A and port B (line 1)
    .{ .row = 0, .col = 3, .kind = .thermal },
    // Thermal noise from series resistance between port A and port B (line 2)
    .{ .row = 1, .col = 4, .kind = .thermal },
    // Thermal noise from shunt conductance at a1
    .{ .row = 0, .col = 2, .kind = .thermal },
    // Thermal noise from shunt conductance at a2
    .{ .row = 1, .col = 2, .kind = .thermal },
    // Thermal noise from shunt conductance at b1
    .{ .row = 3, .col = 5, .kind = .thermal },
    // Thermal noise from shunt conductance at b2
    .{ .row = 4, .col = 5, .kind = .thermal },
};

// ============================================================================
// Comptime contract validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Exact-in-f32 test parameters: l = 0.25 H/m, c = 2^-12 F/m, length = 2 m
//   => z0 = sqrt(0.25 / 2^-12) = sqrt(1024) = 32, y0 = 0.03125
//   => tau = length * sqrt(l*c) = 2 * sqrt(2^-14) = 2 * 2^-7 = 0.015625

test "coupled tlines: uncoupled single-ended residual" {
    // r = 0.5, length = 2 => r_total = 1 per mode, g_series = 1.0
    // x: v_a1 = 1, everything else 0. s = 1/sqrt(2).
    //   v_a_even = v_a_odd = s, v_b_* = 0
    //   i_a_even = i_a_odd = (0.03125 + 1.0) * s = 1.03125 * s
    //   i_b_even = i_b_odd = -1.0 * s  (series sign reversal at port B)
    //   i_a1 = 2 * 1.03125 * s^2 = 1.03125, i_a2 = 0
    //   i_b1 = -2 * s^2 = -1.0,             i_b2 = 0
    //   gmin adds 1e-12 * v: out_a1 = 1.03125 + 1e-12
    const model: Model = .{ .r = 0.5, .l = 0.25, .c = 0.000244140625, .length = 2.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.03125 + 1e-12), out[@intFromEnum(U.a1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.a2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -(1.03125 + 1e-12)), out[@intFromEnum(U.gnd_a)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1.0), out[@intFromEnum(U.b1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.b2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[@intFromEnum(U.gnd_b)], 1e-12);
}

test "coupled tlines: even-mode drive with mutual coupling" {
    // l = 0.25, lm = 0.25 => l_even = 0.5, l_odd clamped to 1e-30
    // c = 2^-12, cm = 2^-12 => c_even = 2^-11, c_odd clamped to 1e-30
    //   z0_even = sqrt(0.5 / 2^-11) = sqrt(1024) = 32, y0_even = 0.03125
    // r = 0.75, rm = 0.25, length = 2 => r_even_total = 2, g_series_even = 0.5
    // g = 0.125, gm = 0.125 => g_even_total = 0.5, g_odd_total = 0
    // x: v_a1 = v_a2 = 1 (pure even drive => all odd-mode terms are 0)
    //   v_a_even = 2s, i_series_even = 0.5 * 2s = s
    //   i_a_even = 2s*0.03125 + s + 2s*0.5 = 2s * 1.03125
    //   i_b_even = 0 - s + 0 = -s
    //   i_a1 = i_a2 = i_a_even * s = 2 * s^2 * 1.03125 = 1.03125 (+ gmin)
    //   i_b1 = i_b2 = -s * s = -0.5
    const model: Model = .{
        .r = 0.75,
        .l = 0.25,
        .c = 0.000244140625,
        .g = 0.125,
        .lm = 0.25,
        .cm = 0.000244140625,
        .rm = 0.25,
        .gm = 0.125,
        .length = 2.0,
    };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 1.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.03125 + 1e-12), out[@intFromEnum(U.a1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.03125 + 1e-12), out[@intFromEnum(U.a2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -2.0 * (1.03125 + 1e-12)), out[@intFromEnum(U.gnd_a)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.5), out[@intFromEnum(U.b1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.5), out[@intFromEnum(U.b2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[@intFromEnum(U.gnd_b)], 1e-12);
}

test "coupled tlines: parallel multiplier m scales residual" {
    const model: Model = .{ .r = 0.5, .l = 0.25, .c = 0.000244140625, .length = 2.0 };
    const inst: Instance = .{ .m = 4 };
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 4.0 * (1.03125 + 1e-12)), out[@intFromEnum(U.a1)], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, -4.0), out[@intFromEnum(U.b1)], 1e-11);
}

test "coupled tlines: modal delays" {
    // tau = length * sqrt(l*c) = 2 * sqrt(0.25 * 2^-12) = 2 * 2^-7 = 0.015625
    const model: Model = .{ .l = 0.25, .c = 0.000244140625, .length = 2.0 };
    const td = delays(&model);
    try testing.expectApproxEqAbs(@as(f64, 0.015625), td[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.015625), td[1], 1e-15);
}

test "coupled tlines: gatherHistSignals records modal voltages" {
    // v_a1 = 1, rest 0 => v_a_even = v_a_odd = 1/sqrt(2), v_b_* = 0
    const sig = gatherHistSignals(.{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0 });
    const s = 0.7071067811865475;
    try testing.expectApproxEqAbs(@as(f64, s), sig[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, s), sig[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), sig[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), sig[3], 1e-15);
}

test "coupled tlines: histInject applies delayed far-end wave" {
    // Uncoupled model of the first test: y0_even = y0_odd = 0.03125.
    // Delayed history: v_b1 = 1, v_b2 = 0 => v_b_even = v_b_odd = s; port A
    // history zero. Injection at port A:
    //   i_a_even = i_a_odd = -2 * 0.03125 * s = -0.0625 * s
    //   i_a1 = (i_a_even + i_a_odd) * s = -0.125 * s^2 = -0.0625, i_a2 = 0
    // Port B side sees zero (no delayed port-A wave).
    const MockLookup = struct {
        vals: [4]f64,
        pub fn at(self: @This(), t_q: f64, sig: usize) f64 {
            _ = t_q;
            return self.vals[sig];
        }
    };
    const model: Model = .{ .r = 0.5, .l = 0.25, .c = 0.000244140625, .length = 2.0 };
    const s = 0.7071067811865475;
    const lookup = MockLookup{ .vals = .{ 0.0, 0.0, s, s } };
    const adds = histInject(&model, lookup, 1.0);
    try testing.expectApproxEqAbs(@as(f64, -0.0625), adds[@intFromEnum(U.a1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.a2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0625), adds[@intFromEnum(U.gnd_a)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.b1)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.b2)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), adds[@intFromEnum(U.gnd_b)], 1e-12);
}
