const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ---------------------------------------------------------------------------
// Terminals
// ---------------------------------------------------------------------------
// p, n are external switch terminals. ctrl is the sensed control current
// from an external branch (a voltage source). The control current is read
// but never driven -- the switch stamps zero into ctrl's KCL row.
// ---------------------------------------------------------------------------

pub const U = enum(u8) {
    p = 0,
    n = 1,
    ctrl = 2,
};

pub const num_ports: usize = 3;

pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // p
    .voltage, // n
    .current, // ctrl
};

// ---------------------------------------------------------------------------
// Sparse conductance stamp pattern
// ---------------------------------------------------------------------------
// The Jacobian has entries only for the p-n conductance block.
// ctrl has no coupling to p or n (the conductance is a constant within each
// Newton iteration; only the state machine triggers re-iteration).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Model Parameters
// ---------------------------------------------------------------------------

pub const Model = struct {
    it: f32 = 0.0, // IT  -- switching threshold current [A]
    ih: f32 = 0.0, // IH  -- hysteresis current [A]
    ron: f32 = 1.0, // RON -- on-state resistance [Ohm]
    roff: f32 = 1.0e12, // ROFF -- off-state resistance [Ohm] (1/Gmin)
};

// ---------------------------------------------------------------------------
// Instance Parameters
// ---------------------------------------------------------------------------

pub const Instance = struct {
    ic_on: bool = false, // initial condition: switch starts ON
    ic_off: bool = false, // initial condition: switch starts OFF
    // Switch position, managed by updateState (value-form contract: eval can
    // only see Model/Instance, so the chosen conductance lives here).
    // Default matches the default initial state (ic_on = false => REALLY_OFF).
    on: bool = false,
};

// ---------------------------------------------------------------------------
// State -- 4-state hysteresis machine
// ---------------------------------------------------------------------------

pub const State = struct {
    // 0 = REALLY_OFF, 1 = REALLY_ON, 2 = HYST_OFF, 3 = HYST_ON
    state: u8 = 0,
    // Last ACCEPTED timepoint's state (see contract.StateCtlOp).
    accepted_state: u8 = 0,
    accepted_on: bool = false,
};

const REALLY_OFF: u8 = 0;
const REALLY_ON: u8 = 1;
const HYST_OFF: u8 = 2;
const HYST_ON: u8 = 3;

// ---------------------------------------------------------------------------
// initState
// ---------------------------------------------------------------------------
// IC_ON  => start in HYST_ON (on, inside hysteresis band)
// otherwise => start in REALLY_OFF
// ---------------------------------------------------------------------------

pub fn initState(_: *const Model, instance: *Instance) State {
    return .{
        .state = if (instance.ic_on) HYST_ON else REALLY_OFF,
        .accepted_state = if (instance.ic_on) HYST_ON else REALLY_OFF,
        .accepted_on = instance.ic_on,
    };
}

/// Accepted-state bookkeeping (see contract.StateCtlOp): lets the transient
/// loop reject/retry a step whose converged solution flipped the switch.
pub fn stateCtl(_: *const Model, instance: *Instance, state: *State, op: contract.StateCtlOp) bool {
    switch (op) {
        .query => return state.state != state.accepted_state or instance.on != state.accepted_on,
        .commit => {
            state.accepted_state = state.state;
            state.accepted_on = instance.on;
        },
        .revert => {
            state.state = state.accepted_state;
            instance.on = state.accepted_on;
        },
    }
    return false;
}

// ---------------------------------------------------------------------------
// updateState -- 4-state hysteresis machine
// ---------------------------------------------------------------------------
// Evaluates the control current against thresholds IT +/- IH and updates
// the switch state. On any state change, returns request_reject_at = 0.0
// to force a re-iteration (equivalent to ngspice CKTnoncon++).
// The resulting switch position (on/off) is written into instance.on so
// that eval() can select the effective conductance.
// ---------------------------------------------------------------------------

pub fn updateState(model: *const Model, instance: *Instance, x: [n_u]f64, state: *State) contract.UpdateResult {
    const i_ctrl: f64 = x[@intFromEnum(U.ctrl)];
    const i_t: f64 = @as(f64, model.it);
    const i_h: f64 = @as(f64, model.ih);

    const prev = state.state;
    var new_state: u8 = prev;

    if (i_h > 0.0) {
        // Normal hysteresis: band is [IT - IH, IT + IH]
        const i_upper = i_t + i_h;
        const i_lower = i_t - i_h;

        if (i_ctrl > i_upper) {
            new_state = REALLY_ON;
        } else if (i_ctrl < i_lower) {
            new_state = REALLY_OFF;
        }
        // else: in hysteresis band, retain previous state
    } else {
        // Negative or zero hysteresis (snap-through)
        // When IH < 0, band inverts: [IT + IH, IT - IH]
        // When IH = 0, degenerate band at IT
        const i_upper = i_t - i_h; // note: -IH when IH<0 makes this > IT
        const i_lower = i_t + i_h; // note: +IH when IH<0 makes this < IT

        if (i_ctrl > i_upper) {
            new_state = REALLY_ON;
        } else if (i_ctrl < i_lower) {
            new_state = REALLY_OFF;
        } else {
            // Inside the snap-through band
            if (prev == HYST_OFF or prev == HYST_ON) {
                // Already in a HYST state inside the band -- hold
                new_state = prev;
            } else if (prev == REALLY_ON) {
                // Entering band from REALLY_ON -- snap OFF
                new_state = HYST_OFF;
            } else {
                // Entering band from REALLY_OFF -- snap ON
                new_state = HYST_ON;
            }
        }
    }

    state.state = new_state;
    instance.on = (new_state == REALLY_ON) or (new_state == HYST_ON);

    // On state change, signal re-iteration
    if (new_state != prev) {
        return .{ .request_reject_at = 0.0 };
    }
    return .ok;
}

// ---------------------------------------------------------------------------
// eval -- Physics function (value-form, stateful)
// ---------------------------------------------------------------------------
// Stamps G_eff * (Vp - Vn) into p and n rows.
// The effective conductance is selected by the switch position held in
// Instance (set by updateState from the state machine). The control
// threshold comparison happens in updateState on f64 x, not here.
// The ctrl output is always zero (sense only, no load on control branch).
// ---------------------------------------------------------------------------

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;

    // Model parameters cast to f64 (x-independent, stays plain f64)
    const g_on: f64 = 1.0 / @as(f64, model.ron);
    const g_off: f64 = 1.0 / @as(f64, model.roff);
    const g_eff: f64 = if (instance.on) g_on else g_off;

    // Switch current
    const i_sw = x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]).scale(g_eff);

    return .{
        i_sw, // p
        i_sw.neg(), // n
        S.con(0.0), // ctrl: sense only, no load on control branch
    };
}

comptime {
    contract.validate(Self);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "cswitch: on-state residual" {
    // Old formula: g_eff = 1/RON when on; i_sw = g_eff*(vp - vn).
    // RON = 2 => g_on = 0.5; vp - vn = 3 - 1 = 2 => i_sw = 0.5 * 2 = 1.0 A.
    const model: Model = .{ .ron = 2.0 };
    const inst: Instance = .{ .on = true };
    const out = contract.evalValues(Self, .{ 3.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1.0), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
}

test "cswitch: off-state residual" {
    // Old formula: g_eff = 1/ROFF when off; default ROFF = 1e12.
    // vp - vn = 1 => i_sw = 1e-12 A.
    // (tolerance accounts for f32 storage of ROFF: |1/f32(1e12) - 1e-12| ~ 4e-21)
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1e-12), out[0], 1e-19);
    try testing.expectApproxEqAbs(@as(f64, -1e-12), out[1], 1e-19);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
}

test "cswitch: hysteresis state machine drives instance.on" {
    // IT = 1, IH = 0.5 => band [0.5, 1.5]
    const model: Model = .{ .it = 1.0, .ih = 0.5 };
    var inst: Instance = .{};
    var s: State = initState(&model, &inst);
    try testing.expectEqual(REALLY_OFF, s.state);
    try testing.expect(!inst.on);

    // i_ctrl = 2.0 > 1.5 => REALLY_ON; state change => reject
    var res = updateState(&model, &inst, .{ 0, 0, 2.0 }, &s);
    try testing.expect(res == .request_reject_at);
    try testing.expectEqual(REALLY_ON, s.state);
    try testing.expect(inst.on);

    // i_ctrl = 1.2 inside band => hold previous state
    res = updateState(&model, &inst, .{ 0, 0, 1.2 }, &s);
    try testing.expect(res == .ok);
    try testing.expect(inst.on);

    // i_ctrl = 0.4 < 0.5 => REALLY_OFF; state change => reject
    res = updateState(&model, &inst, .{ 0, 0, 0.4 }, &s);
    try testing.expect(res == .request_reject_at);
    try testing.expect(!inst.on);
}

test "cswitch: zero-hysteresis snap-through" {
    // IT = 0.5, IH = 0 => degenerate band at 0.5
    const model: Model = .{ .it = 0.5, .ih = 0.0 };
    var inst: Instance = .{};
    var s: State = initState(&model, &inst);
    try testing.expectEqual(REALLY_OFF, s.state);

    // Entering band from REALLY_OFF => snap ON (HYST_ON), reject
    var res = updateState(&model, &inst, .{ 0, 0, 0.5 }, &s);
    try testing.expect(res == .request_reject_at);
    try testing.expectEqual(HYST_ON, s.state);
    try testing.expect(inst.on);

    // Still in band, already HYST => hold
    res = updateState(&model, &inst, .{ 0, 0, 0.5 }, &s);
    try testing.expect(res == .ok);
    try testing.expectEqual(HYST_ON, s.state);

    // Above band => REALLY_ON
    res = updateState(&model, &inst, .{ 0, 0, 0.6 }, &s);
    try testing.expect(res == .request_reject_at);
    try testing.expectEqual(REALLY_ON, s.state);

    // Back into band from REALLY_ON => snap OFF (HYST_OFF)
    res = updateState(&model, &inst, .{ 0, 0, 0.5 }, &s);
    try testing.expect(res == .request_reject_at);
    try testing.expectEqual(HYST_OFF, s.state);
    try testing.expect(!inst.on);
}

test "cswitch: ic_on initial state" {
    const model: Model = .{};
    const inst: Instance = .{ .ic_on = true };
    const s = initState(&model, &inst);
    try testing.expectEqual(HYST_ON, s.state);
}
