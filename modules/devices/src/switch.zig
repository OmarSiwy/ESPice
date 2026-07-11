const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminals
// ============================================================================
// p, n are external switch terminals.
// cp, cn are external control-voltage sense terminals (infinite impedance).

pub const U = enum(u8) {
    p = 0,
    n = 1,
    cp = 2,
    cn = 3,
};

pub const num_ports: usize = 4;

// ============================================================================
// Sparse conductance stamp pattern
// ============================================================================
// The Jacobian has entries only for the p-n conductance block.
// cp and cn have no coupling (infinite input impedance on control port;
// conductance is piecewise-constant, no derivative through the switching
// decision). Matches ngspice swload.c stamp.

pub const g_pattern_override = [_]contract.Entry(n_u){
    .{ .row = 0, .col = 0 }, // dI_p / dV_p  =  +G_eff
    .{ .row = 0, .col = 1 }, // dI_p / dV_n  =  -G_eff
    .{ .row = 1, .col = 0 }, // dI_n / dV_p  =  -G_eff
    .{ .row = 1, .col = 1 }, // dI_n / dV_n  =  +G_eff
};

// ============================================================================
// Noise sources -- thermal noise of the switch resistance
// ============================================================================
// 4kT * G_eff between p and n (Johnson-Nyquist noise).

pub const noise_gens = [_]contract.NoiseGen(Self){
    .{ .row = 0, .col = 1, .kind = .thermal },
};

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    vt: f32 = 0.0, // VT  -- switching threshold voltage [V]
    vh: f32 = 0.0, // VH  -- hysteresis voltage [V]
    ron: f32 = 1.0, // RON -- on-state resistance [Ohm]
    roff: f32 = 1.0e12, // ROFF -- off-state resistance [Ohm] (1/Gmin)
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    init_on: bool = false, // IC=ON: switch starts in HYST_ON state
    init_off: bool = false, // IC=OFF: switch starts in HYST_OFF state
    /// Switch position chosen by the hysteresis FSM (set by updateState).
    /// eval reads this to pick G_on vs G_off. Default matches the default
    /// initial state REALLY_OFF (off).
    sw_on: bool = false,
};

// ============================================================================
// State -- 4-state hysteresis machine
// ============================================================================

pub const State = struct {
    // 0 = REALLY_OFF, 1 = REALLY_ON, 2 = HYST_OFF, 3 = HYST_ON
    current_state: u8 = 0,
    g_eff: f64 = 0.0,
};

const REALLY_OFF: u8 = 0;
const REALLY_ON: u8 = 1;
const HYST_OFF: u8 = 2;
const HYST_ON: u8 = 3;

// ============================================================================
// initState
// ============================================================================
// IC=ON  => HYST_ON,  g_eff = G_on
// IC=OFF => HYST_OFF, g_eff = G_off
// default => REALLY_OFF, g_eff = G_off

pub fn initState(model: *const Model, instance: *Instance) State {
    const g_on: f64 = 1.0 / @as(f64, model.ron);
    const g_off: f64 = 1.0 / @as(f64, model.roff);

    if (instance.init_on) {
        return .{ .current_state = HYST_ON, .g_eff = g_on };
    } else if (instance.init_off) {
        return .{ .current_state = HYST_OFF, .g_eff = g_off };
    } else {
        return .{ .current_state = REALLY_OFF, .g_eff = g_off };
    }
}

// ============================================================================
// updateState -- 4-state hysteresis FSM
// ============================================================================
// Evaluates V_ctrl = V_cp - V_cn against thresholds VT +/- VH and updates
// the switch state. On any state change (including a change of the switch
// position stored in Instance), returns request_reject_at = 0.0 to force a
// re-iteration (equivalent to ngspice CKTnoncon++).
//
// Three regimes:
//   VH > 0 : normal hysteresis, band [VT-VH, VT+VH], memory in band
//   VH < 0 : snap-through, band [VT+VH, VT-VH], snap to opposite in band
//   VH = 0 : no hysteresis, simple threshold at VT

pub fn updateState(model: *const Model, instance: *Instance, x: [n_u]f64, state: *State) contract.UpdateResult {
    const vth: f64 = @as(f64, model.vt);
    const vh: f64 = @as(f64, model.vh);
    const g_on: f64 = 1.0 / @as(f64, model.ron);
    const g_off: f64 = 1.0 / @as(f64, model.roff);

    const v_ctrl: f64 = x[@intFromEnum(U.cp)] - x[@intFromEnum(U.cn)];
    const prev = state.current_state;
    var new_state: u8 = prev;

    if (vh > 0.0) {
        // Case 1: Positive hysteresis
        // Band [VT - VH, VT + VH]. Inside band: retain previous state.
        if (v_ctrl > vth + vh) {
            new_state = REALLY_ON;
        } else if (v_ctrl < vth - vh) {
            new_state = REALLY_OFF;
        }
        // else: in hysteresis band, state unchanged
    } else if (vh < 0.0) {
        // Case 2: Negative hysteresis / snap-through
        // Since VH < 0: VT - VH > VT and VT + VH < VT
        // Band is [VT + VH, VT - VH].
        if (v_ctrl > vth - vh) {
            new_state = REALLY_ON;
        } else if (v_ctrl < vth + vh) {
            new_state = REALLY_OFF;
        } else {
            // Inside the snap-through band
            if (prev == HYST_OFF or prev == HYST_ON) {
                // Already in a HYST state -- hold
                new_state = prev;
            } else if (prev == REALLY_ON) {
                // Entering band from REALLY_ON -- snap to HYST_OFF
                new_state = HYST_OFF;
            } else {
                // Entering band from REALLY_OFF -- snap to HYST_ON
                new_state = HYST_ON;
            }
        }
    } else {
        // Case 3: No hysteresis (VH == 0)
        if (v_ctrl > vth) {
            new_state = REALLY_ON;
        } else {
            new_state = REALLY_OFF;
        }
    }

    // Post-update conductance assignment: the position eval reads lives in
    // Instance; State keeps the FSM bookkeeping.
    const is_on = (new_state == REALLY_ON or new_state == HYST_ON);
    const pos_changed = (is_on != instance.sw_on);
    instance.sw_on = is_on;
    state.g_eff = if (is_on) g_on else g_off;
    state.current_state = new_state;

    // Convergence feedback: reject timestep if state (or the effective
    // switch position) changed.
    if (new_state != prev or pos_changed) {
        return .{ .request_reject_at = 0.0 };
    }
    return .ok;
}

// ============================================================================
// eval -- Physics function (value-form)
// ============================================================================
// Stamps G_eff * (Vp - Vn) into p and n nodes. The conductance is selected
// from the switch position the hysteresis FSM stored in Instance (updateState
// above); it is piecewise-constant in x, so no derivative flows through the
// switching decision (control-voltage comparison happens in updateState on
// plain f64 x, matching the old solver-side state.g_eff stamp).
// cp and cn outputs are always zero (infinite input impedance).

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const p = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);

    // Model parameters cast to f64 (x-independent, stays plain f64)
    const g_on: f64 = 1.0 / @as(f64, model.ron);
    const g_off: f64 = 1.0 / @as(f64, model.roff);
    const g_eff: f64 = if (instance.sw_on) g_on else g_off;

    // Switch current: I_sw = G_eff * (Vp - Vn)
    const i_sw = x[p].sub(x[n_]).scale(g_eff);

    return .{
        i_sw, // KCL at p
        i_sw.neg(), // KCL at n
        S.con(0.0), // cp: sense only, zero current into control port
        S.con(0.0), // cn: sense only, zero current into control port
    };
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "switch: on-state residual" {
    // Old formula: g_eff = 1/ron = 1/2 = 0.5; i_sw = 0.5 * (1.0 - 0.0) = 0.5
    // out = { +0.5, -0.5, 0, 0 }
    const model: Model = .{ .ron = 2.0 };
    const inst: Instance = .{ .sw_on = true };
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 5.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.5), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-12);
}

test "switch: off-state residual (default roff = 1e12)" {
    // Old formula: g_eff = 1/roff = 1e-12; i_sw = 1e-12 * (1.0 - 0.0) = 1e-12
    // (tolerance accounts for f32 param storage: 1e12 as f32 = 999999995904,
    // so g_off = 1.000000004096e-12 -- ~4e-9 relative)
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1e-12), out[0], 1e-20);
    try testing.expectApproxEqAbs(@as(f64, -1e-12), out[1], 1e-20);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-20);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-20);
}

test "switch: updateState no-hysteresis threshold flips position and rejects" {
    // VH = 0, VT = 1.0: v_ctrl above VT turns the switch on.
    const model: Model = .{ .vt = 1.0, .ron = 10.0 };
    var inst: Instance = .{};
    var s = initState(&model, &inst);
    try testing.expectEqual(REALLY_OFF, s.current_state);

    // v_ctrl = 2.0 > 1.0 -> REALLY_ON, state changed -> reject requested
    const r1 = updateState(&model, &inst, .{ 0.0, 0.0, 2.0, 0.0 }, &s);
    try testing.expect(r1 == .request_reject_at);
    try testing.expectEqual(REALLY_ON, s.current_state);
    try testing.expect(inst.sw_on);
    try testing.expectApproxEqAbs(@as(f64, 0.1), s.g_eff, 1e-12);

    // Same input again: no change -> ok
    const r2 = updateState(&model, &inst, .{ 0.0, 0.0, 2.0, 0.0 }, &s);
    try testing.expect(r2 == .ok);

    // v_ctrl = 0.5 <= 1.0 -> REALLY_OFF again -> reject
    const r3 = updateState(&model, &inst, .{ 0.0, 0.0, 0.5, 0.0 }, &s);
    try testing.expect(r3 == .request_reject_at);
    try testing.expect(!inst.sw_on);
}

test "switch: positive hysteresis retains state in band" {
    // VT = 1.0, VH = 0.5: band is [0.5, 1.5].
    const model: Model = .{ .vt = 1.0, .vh = 0.5 };
    var inst: Instance = .{};
    var s = initState(&model, &inst);

    // v_ctrl = 1.0 is inside the band; starting state REALLY_OFF holds.
    const r1 = updateState(&model, &inst, .{ 0.0, 0.0, 1.0, 0.0 }, &s);
    try testing.expect(r1 == .ok);
    try testing.expect(!inst.sw_on);

    // v_ctrl = 2.0 > 1.5 -> REALLY_ON
    _ = updateState(&model, &inst, .{ 0.0, 0.0, 2.0, 0.0 }, &s);
    try testing.expect(inst.sw_on);

    // Back into the band: memory -- still on, no state change.
    const r2 = updateState(&model, &inst, .{ 0.0, 0.0, 1.0, 0.0 }, &s);
    try testing.expect(r2 == .ok);
    try testing.expect(inst.sw_on);

    // v_ctrl = 0.4 < 0.5 -> REALLY_OFF
    _ = updateState(&model, &inst, .{ 0.0, 0.0, 0.4, 0.0 }, &s);
    try testing.expect(!inst.sw_on);
}

test "switch: negative hysteresis snap-through" {
    // VT = 1.0, VH = -0.5: band is [0.5, 1.5]; entering it snaps to the
    // opposite state.
    const model: Model = .{ .vt = 1.0, .vh = -0.5 };
    var inst: Instance = .{};
    var s = initState(&model, &inst);
    try testing.expectEqual(REALLY_OFF, s.current_state);

    // Entering band from REALLY_OFF snaps to HYST_ON.
    const r1 = updateState(&model, &inst, .{ 0.0, 0.0, 1.0, 0.0 }, &s);
    try testing.expect(r1 == .request_reject_at);
    try testing.expectEqual(HYST_ON, s.current_state);
    try testing.expect(inst.sw_on);

    // Staying in band: hold HYST_ON.
    const r2 = updateState(&model, &inst, .{ 0.0, 0.0, 1.2, 0.0 }, &s);
    try testing.expect(r2 == .ok);
    try testing.expectEqual(HYST_ON, s.current_state);
}

test "switch: IC=ON reconciles Instance position on first updateState" {
    // With IC=ON the FSM starts in HYST_ON, but Instance.sw_on defaults to
    // off; the first in-band updateState flips the position and requests a
    // re-iteration so eval is re-run with the on conductance.
    const model: Model = .{ .vt = 1.0, .vh = 0.5, .ron = 4.0 };
    var inst: Instance = .{ .init_on = true };
    var s = initState(&model, &inst);
    try testing.expectEqual(HYST_ON, s.current_state);
    try testing.expectApproxEqAbs(@as(f64, 0.25), s.g_eff, 1e-12);

    const r = updateState(&model, &inst, .{ 0.0, 0.0, 1.0, 0.0 }, &s);
    try testing.expect(r == .request_reject_at);
    try testing.expect(inst.sw_on);

    // Residual now reflects the on-state: 0.25 * (2 - 0) = 0.5
    const out = contract.evalValues(Self, .{ 2.0, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out[0], 1e-12);
}
