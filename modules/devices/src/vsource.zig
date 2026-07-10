const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ---------------------------------------------------------------------------
// Topology: two-terminal MNA voltage source with branch current unknown.
// External ports: p (positive), n (negative).
// Internal unknown: branch (current through the source, positive from p to n).
// ---------------------------------------------------------------------------

pub const U = enum(u8) { p, n, branch };
pub const mc_param = "dc"; // Model.dc
pub const num_ports: usize = 2;

pub const u_kinds = [n_u]contract.UnknownKind{ .voltage, .voltage, .current };

// ---------------------------------------------------------------------------
// Sparse Jacobian structure.
// The MNA stamp has exactly 4 nonzero entries:
//   dF_p / dI_branch     = +1
//   dF_n / dI_branch     = -1
//   dF_branch / dV_p     = +1
//   dF_branch / dV_n     = -1
// ---------------------------------------------------------------------------

pub const g_pattern_override = [_]contract.Entry(n_u){
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.branch) },
    .{ .row = @intFromEnum(U.n), .col = @intFromEnum(U.branch) },
    .{ .row = @intFromEnum(U.branch), .col = @intFromEnum(U.p) },
    .{ .row = @intFromEnum(U.branch), .col = @intFromEnum(U.n) },
};

// ---------------------------------------------------------------------------
// Waveform type constants (i32, matches isource convention)
// ---------------------------------------------------------------------------

const WF_DC: i32 = 0;
const WF_PULSE: i32 = 1;
const WF_SIN: i32 = 2;
const WF_EXP: i32 = 3;
const WF_PWL: i32 = 4;
const WF_SFFM: i32 = 5;
const WF_AM: i32 = 6;

// ---------------------------------------------------------------------------
// Model -- all source parameters (shared across instances in a model group)
// ---------------------------------------------------------------------------

const max_pwl: usize = 64;

pub const Model = struct {
    // ---- DC / AC ----
    dc: f32 = 0.0,
    acmag: f32 = 1.0,
    acphase: f32 = 0.0,
    waveform: i32 = WF_DC,

    // ---- PULSE: PULSE(V1 V2 TD TR TF PW PER PHASE) ----
    pulse_v1: f32 = 0.0,
    pulse_v2: f32 = 0.0,
    pulse_td: f32 = 0.0,
    pulse_tr: f32 = 1.0e-9,
    pulse_tf: f32 = 1.0e-9,
    pulse_pw: f32 = 1.0e-9,
    pulse_per: f32 = 2.0e-9,
    pulse_phase: f32 = 0.0,

    // ---- SIN: SIN(VO VA FREQ TD THETA PHASE) ----
    sin_vo: f32 = 0.0,
    sin_va: f32 = 0.0,
    sin_freq: f32 = 0.0,
    sin_td: f32 = 0.0,
    sin_theta: f32 = 0.0,
    sin_phase: f32 = 0.0,

    // ---- EXP: EXP(V1 V2 TD1 TAU1 TD2 TAU2) ----
    exp_v1: f32 = 0.0,
    exp_v2: f32 = 0.0,
    exp_td1: f32 = 0.0,
    exp_tau1: f32 = 1.0e-9,
    exp_td2: f32 = 0.0,
    exp_tau2: f32 = 1.0e-9,

    // ---- PWL: PWL(T1 V1 T2 V2 ...) ----
    pwl_times: [max_pwl]f32 = [_]f32{0.0} ** max_pwl,
    pwl_values: [max_pwl]f32 = [_]f32{0.0} ** max_pwl,
    pwl_len: i32 = 0,
    pwl_repeat: f32 = 0.0,
    pwl_td: f32 = 0.0,

    // ---- SFFM: SFFM(VO VA FC MDI FS PHASEC PHASES) ----
    sffm_vo: f32 = 0.0,
    sffm_va: f32 = 0.0,
    sffm_fc: f32 = 0.0,
    sffm_mdi: f32 = 0.0,
    sffm_fs: f32 = 0.0,
    sffm_phasec: f32 = 0.0,
    sffm_phases: f32 = 0.0,

    // ---- AM: AM(VA VO MF FC TD PHASEC PHASES) ----
    am_va: f32 = 0.0,
    am_vo: f32 = 0.0,
    am_mf: f32 = 0.0,
    am_fc: f32 = 0.0,
    am_td: f32 = 0.0,
    am_phasec: f32 = 0.0,
    am_phases: f32 = 0.0,
};

// ---------------------------------------------------------------------------
// Instance -- empty (all parameters live in Model per spec)
// ---------------------------------------------------------------------------

pub const Instance = struct {};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const pi: f64 = 3.14159265358979323846;
const two_pi: f64 = 6.28318530717958647692;
const deg2rad: f64 = pi / 180.0;

// ---------------------------------------------------------------------------
// Waveform evaluation -- pure f64 function of model parameters and time.
// Does not depend on x, so it stays out of the S-typed physics tail.
// ---------------------------------------------------------------------------

fn sourceVoltage(model: *const Model, t: f64) f64 {
    @setFloatMode(.optimized);

    const wf: i32 = model.waveform;

    // ================================================================
    // DC waveform (waveform == 0)
    // ================================================================
    const v_dc: f64 = @as(f64, model.dc);

    // ================================================================
    // PULSE waveform (waveform == 1)
    // ================================================================
    const p_v1: f64 = @as(f64, model.pulse_v1);
    const p_v2: f64 = @as(f64, model.pulse_v2);
    const p_td: f64 = @as(f64, model.pulse_td);
    const p_tr: f64 = @max(@as(f64, model.pulse_tr), 1.0e-12);
    const p_tf: f64 = @max(@as(f64, model.pulse_tf), 1.0e-12);
    const p_pw: f64 = @as(f64, model.pulse_pw);
    const p_per: f64 = @max(@as(f64, model.pulse_per), p_tr + p_pw + p_tf + 1.0e-12);
    const p_phase: f64 = @as(f64, model.pulse_phase);

    const t_after_p_delay = t - p_td;
    const p_phase_offset = (p_phase / 360.0) * p_per;
    const t_eff_pulse = t_after_p_delay + p_phase_offset;
    const p_per_safe = @max(p_per, 1.0e-30);
    const t_mod_raw = t_eff_pulse - @floor(t_eff_pulse / p_per_safe) * p_per_safe;
    const t_mod = @max(t_mod_raw, 0.0);

    const rise_end = p_tr;
    const high_end = p_tr + p_pw;
    const fall_end = p_tr + p_pw + p_tf;

    const v_rise = p_v1 + (p_v2 - p_v1) * (t_mod / p_tr);
    const v_fall = p_v2 - (p_v2 - p_v1) * ((t_mod - high_end) / p_tf);

    const v_pulse_seg = if (t_mod < rise_end)
        v_rise
    else if (t_mod < high_end)
        p_v2
    else if (t_mod < fall_end)
        v_fall
    else
        p_v1;

    const v_pulse = if (t_after_p_delay < 0.0) p_v1 else v_pulse_seg;

    // ================================================================
    // SIN waveform (waveform == 2)
    // ================================================================
    const s_vo: f64 = @as(f64, model.sin_vo);
    const s_va: f64 = @as(f64, model.sin_va);
    const s_freq: f64 = @as(f64, model.sin_freq);
    const s_td: f64 = @as(f64, model.sin_td);
    const s_theta: f64 = @as(f64, model.sin_theta);
    const s_phase_rad: f64 = @as(f64, model.sin_phase) * deg2rad;

    const t_sin = t - s_td;
    const v_sin_before = s_vo + s_va * contract.fmath.sin(s_phase_rad);
    const damp_arg = @min(-s_theta * t_sin, 80.0);
    const v_sin_after = s_vo + s_va * contract.fmath.sin(two_pi * s_freq * t_sin + s_phase_rad) * contract.fmath.exp(damp_arg);
    const v_sin = if (t_sin < 0.0) v_sin_before else v_sin_after;

    // ================================================================
    // EXP waveform (waveform == 3)
    // ================================================================
    const e_v1: f64 = @as(f64, model.exp_v1);
    const e_v2: f64 = @as(f64, model.exp_v2);
    const e_td1: f64 = @as(f64, model.exp_td1);
    const e_tau1: f64 = @max(@as(f64, model.exp_tau1), 1.0e-15);
    const e_td2: f64 = @as(f64, model.exp_td2);
    const e_tau2: f64 = @max(@as(f64, model.exp_tau2), 1.0e-15);

    const t_e1 = t - e_td1;
    const t_e2 = t - e_td2;

    const rise_exp_arg = @min(-t_e1 / e_tau1, 80.0);
    const rise_comp = (e_v2 - e_v1) * (1.0 - contract.fmath.exp(rise_exp_arg));
    const rise_val = if (t_e1 > 0.0) rise_comp else 0.0;

    const fall_exp_arg = @min(-t_e2 / e_tau2, 80.0);
    const fall_comp = (e_v1 - e_v2) * (1.0 - contract.fmath.exp(fall_exp_arg));
    const fall_val = if (t_e2 > 0.0) fall_comp else 0.0;

    const v_exp = e_v1 + rise_val + fall_val;

    // ================================================================
    // PWL waveform (waveform == 4)
    // ================================================================
    const pwl_n: i32 = model.pwl_len;
    const pwl_td: f64 = @as(f64, model.pwl_td);
    const pwl_repeat: f64 = @as(f64, model.pwl_repeat);

    const v_pwl = blk_pwl: {
        const n_pts: usize = @intCast(@max(pwl_n, 0));
        // No breakpoints: fall back to DC
        if (n_pts == 0) break :blk_pwl v_dc;

        var t_eff = t - pwl_td;

        // Before delay: use first breakpoint value
        if (t_eff < 0.0) break :blk_pwl @as(f64, model.pwl_values[0]);

        const t_first: f64 = @as(f64, model.pwl_times[0]);
        const n_last = n_pts - 1;
        const t_last: f64 = @as(f64, model.pwl_times[n_last]);

        // Repeat logic
        if (pwl_repeat > 0.0 and n_pts > 1 and t_eff > t_last and t_last > pwl_repeat) {
            const period = t_last - pwl_repeat;
            if (period > 0.0) {
                const excess = t_eff - pwl_repeat;
                t_eff = pwl_repeat + (excess - @floor(excess / period) * period);
            }
        }

        // Before first breakpoint
        if (t_eff <= t_first) break :blk_pwl @as(f64, model.pwl_values[0]);

        // After last breakpoint
        if (t_eff >= t_last) break :blk_pwl @as(f64, model.pwl_values[n_last]);

        // Linear interpolation: find segment
        var result: f64 = @as(f64, model.pwl_values[n_last]);
        for (0..n_last) |k| {
            const tk: f64 = @as(f64, model.pwl_times[k]);
            const tk1: f64 = @as(f64, model.pwl_times[k + 1]);
            if (t_eff >= tk and t_eff < tk1) {
                const vk: f64 = @as(f64, model.pwl_values[k]);
                const vk1: f64 = @as(f64, model.pwl_values[k + 1]);
                const dt = @max(tk1 - tk, 1.0e-15);
                const alpha = (t_eff - tk) / dt;
                result = vk + (vk1 - vk) * alpha;
                break;
            }
        }
        break :blk_pwl result;
    };

    // ================================================================
    // SFFM waveform (waveform == 5)
    // ================================================================
    const fm_vo: f64 = @as(f64, model.sffm_vo);
    const fm_va: f64 = @as(f64, model.sffm_va);
    const fm_fc: f64 = @as(f64, model.sffm_fc);
    const fm_mdi: f64 = @as(f64, model.sffm_mdi);
    const fm_fs: f64 = @as(f64, model.sffm_fs);
    const fm_phasec_rad: f64 = @as(f64, model.sffm_phasec) * deg2rad;
    const fm_phases_rad: f64 = @as(f64, model.sffm_phases) * deg2rad;

    const fm_mod = fm_mdi * contract.fmath.sin(two_pi * fm_fs * t + fm_phases_rad);
    const v_sffm = fm_vo + fm_va * contract.fmath.sin(two_pi * fm_fc * t + fm_phasec_rad + fm_mod);

    // ================================================================
    // AM waveform (waveform == 6)
    // ================================================================
    const am_va: f64 = @as(f64, model.am_va);
    const am_vo: f64 = @as(f64, model.am_vo);
    const am_mf: f64 = @as(f64, model.am_mf);
    const am_fc_v: f64 = @as(f64, model.am_fc);
    const am_td: f64 = @as(f64, model.am_td);
    const am_phasec_rad: f64 = @as(f64, model.am_phasec) * deg2rad;
    const am_phases_rad: f64 = @as(f64, model.am_phases) * deg2rad;

    const am_envelope = am_vo + contract.fmath.sin(two_pi * am_mf * t + am_phases_rad);
    const am_carrier = contract.fmath.sin(two_pi * am_fc_v * t + am_phasec_rad);
    const am_active = am_va * am_envelope * am_carrier;
    const v_am = if (t < am_td) 0.0 else am_active;

    // ================================================================
    // Waveform selection (branchless chain of selects)
    // ================================================================
    return if (wf == WF_PULSE)
        v_pulse
    else if (wf == WF_SIN)
        v_sin
    else if (wf == WF_EXP)
        v_exp
    else if (wf == WF_PWL)
        v_pwl
    else if (wf == WF_SFFM)
        v_sffm
    else if (wf == WF_AM)
        v_am
    else
        v_dc;
}

// ---------------------------------------------------------------------------
// Breakpoints: return next discontinuity time after t for PULSE/PWL.
// ---------------------------------------------------------------------------

pub fn nextBreakpoint(model: *const Model, t: f64) ?f64 {
    const wf = model.waveform;
    if (wf == WF_PULSE) {
        const td: f64 = @floatCast(model.pulse_td);
        const tr: f64 = @max(@as(f64, @floatCast(model.pulse_tr)), 1e-12);
        const pw: f64 = @floatCast(model.pulse_pw);
        const tf: f64 = @max(@as(f64, @floatCast(model.pulse_tf)), 1e-12);
        const per: f64 = @max(@as(f64, @floatCast(model.pulse_per)), tr + pw + tf + 1e-12);
        if (t < td) return td;
        const t_rel = t - td;
        const cycle = @floor(t_rel / per);
        const edges = [_]f64{ cycle * per + td, cycle * per + td + tr, cycle * per + td + tr + pw, cycle * per + td + tr + pw + tf, (cycle + 1) * per + td };
        for (edges) |e| if (e > t + 1e-18) return e;
        return (cycle + 1) * per + td;
    } else if (wf == WF_PWL) {
        const len: usize = @intCast(@max(model.pwl_len, 0));
        const td: f64 = @floatCast(model.pwl_td);
        for (model.pwl_times[0..len]) |pt| {
            const bp: f64 = @as(f64, pt) + td;
            if (bp > t + 1e-18) return bp;
        }
        return null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Constant-Jacobian flag: G stamp is independent of x.
// ---------------------------------------------------------------------------

pub const constant_g = true;

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    m.dc = @floatCast(@as(f64, model.dc) * lambda);
    return m;
}

// ---------------------------------------------------------------------------
// Physics function: MNA voltage source stamp (value-form)
// ---------------------------------------------------------------------------

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);

    const p = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);
    const br = @intFromEnum(U.branch);

    const v_source = sourceVoltage(model, t);

    return .{
        x[br],
        x[br].neg(),
        x[p].sub(x[n_]).addC(-v_source),
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

test "vsource: DC residual" {
    // dc = 5V, x = { vp=3, vn=1, i_branch=0.25 }
    // F_p = i_branch = 0.25
    // F_n = -i_branch = -0.25
    // F_branch = vp - vn - dc = 3 - 1 - 5 = -3
    const model: Model = .{ .dc = 5.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 3.0, 1.0, 0.25 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.25), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.25), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -3.0), out[2], 1e-12);
}

test "vsource: PULSE waveform in high region" {
    // PULSE(0 5 0 1n 1n 1u 1m), t = 0.5u:
    //   t_mod = 0.5u; rise_end = 1n; high_end = 1n + 1u
    //   1n <= 0.5u < 1n + 1u  ->  v = v2 = 5
    // x = { vp=5, vn=0, i_branch=0 } -> F_branch = 5 - 0 - 5 = 0
    const model: Model = .{
        .waveform = WF_PULSE,
        .pulse_v1 = 0.0,
        .pulse_v2 = 5.0,
        .pulse_td = 0.0,
        .pulse_tr = 1.0e-9,
        .pulse_tf = 1.0e-9,
        .pulse_pw = 1.0e-6,
        .pulse_per = 1.0e-3,
    };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 5.0, 0.0, 0.0 }, &model, &inst, 0.5e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-9);
}

test "vsource: SIN waveform at quarter period" {
    // SIN(1 2 1k 0 0 0), t = 0.25m:
    //   v = vo + va * sin(2*pi*1000*0.25e-3) = 1 + 2*sin(pi/2) = 3
    // x = { vp=0, vn=0, i_branch=0 } -> F_branch = 0 - 0 - 3 = -3
    const model: Model = .{
        .waveform = WF_SIN,
        .sin_vo = 1.0,
        .sin_va = 2.0,
        .sin_freq = 1.0e3,
    };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 0.0, 0.0 }, &model, &inst, 0.25e-3);
    try testing.expectApproxEqAbs(@as(f64, -3.0), out[2], 1e-9);
}

test "vsource: PWL linear interpolation" {
    // PWL(0 0, 1m 10): at t = 0.4m, v = 0 + (10-0)*(0.4m/1m) = 4
    // x = { vp=4, vn=0, i_branch=0 } -> F_branch = 4 - 4 = 0
    // Tolerance: pwl_times is f32 storage, so f32(1e-3) carries ~4.7e-8
    // relative error -> the 4V interpolant is off by ~1.9e-7 absolute.
    var model: Model = .{ .waveform = WF_PWL, .pwl_len = 2 };
    model.pwl_times[0] = 0.0;
    model.pwl_values[0] = 0.0;
    model.pwl_times[1] = 1.0e-3;
    model.pwl_values[1] = 10.0;
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 4.0, 0.0, 0.0 }, &model, &inst, 0.4e-3);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-6);
}
