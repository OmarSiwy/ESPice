const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ---------------------------------------------------------------------------
// Topology: two-terminal ideal independent current source
// Current flows from p through the external circuit to n.
// ---------------------------------------------------------------------------

pub const U = enum(u8) { p, n };
pub const num_ports: usize = 2;

// ---------------------------------------------------------------------------
// No conductance stamp -- pure RHS current injection.
// Empty pattern tells the solver this device touches zero G-matrix entries.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Model -- shared across instances (empty for ideal source)
// ---------------------------------------------------------------------------

pub const Model = struct {};

// ---------------------------------------------------------------------------
// Instance -- per-source parameters: DC, AC, multiplier, waveform config
// ---------------------------------------------------------------------------
//
// Waveform type encoding (i32):
//   0 = dc    (default)
//   1 = pulse
//   2 = sin
//   3 = exp
//   4 = sffm
//   5 = am

pub const Instance = struct {
    // ---- Source configuration ----
    dc: f32 = 0.0,
    m: f32 = 1.0,
    waveform: i32 = 0,

    // ---- AC analysis ----
    acmag: f32 = 1.0,
    acphase: f32 = 0.0,

    // ---- PULSE waveform ----
    pulse_i1: f32 = 0.0,
    pulse_i2: f32 = 0.0,
    pulse_td: f64 = 0.0,
    // ngspice defaults: TR = TF = TSTEP, PW = PER = TSTOP. netlist.zig
    // resolves the -1 sentinels from the .tran directive.
    pulse_tr: f64 = -1.0,
    pulse_tf: f64 = -1.0,
    pulse_pw: f64 = -1.0,
    pulse_per: f64 = -1.0,
    pulse_phase: f64 = 0.0,

    // ---- SIN waveform ----
    sin_ioff: f32 = 0.0,
    sin_iamp: f32 = 0.0,
    sin_freq: f64 = 0.0,
    sin_td: f64 = 0.0,
    sin_theta: f64 = 0.0,
    sin_phase: f64 = 0.0,

    // ---- EXP waveform ----
    exp_i1: f32 = 0.0,
    exp_i2: f32 = 0.0,
    exp_td1: f64 = 0.0,
    exp_tau1: f64 = 1.0e-9,
    exp_td2: f64 = 0.0,
    exp_tau2: f64 = 1.0e-9,

    // ---- SFFM waveform ----
    sffm_ioff: f32 = 0.0,
    sffm_iamp: f32 = 0.0,
    sffm_fc: f64 = 0.0,
    sffm_mdi: f32 = 0.0,
    sffm_fs: f64 = 0.0,
    sffm_phasec: f64 = 0.0,
    sffm_phases: f64 = 0.0,

    // ---- AM waveform ----
    am_ia: f32 = 0.0,
    am_io: f32 = 0.0,
    am_mf: f64 = 0.0,
    am_fc: f64 = 0.0,
    am_td: f64 = 0.0,
    am_phasec: f64 = 0.0,
    am_phases: f64 = 0.0,
};

// ---------------------------------------------------------------------------
// Physics (value-form: generic over scalar S)
//
// The waveform value at time t is a pure f64 function of t and the instance
// parameters -- no dependence on x -- so it stays in a plain f64 helper.
// The residual is then just a constant injection built with S.con.
// ---------------------------------------------------------------------------

/// Waveform current at time t (before the parallel multiplier m). Pure f64.
fn waveformCurrent(instance: *const Instance, t: f64) f64 {
    const pi: f64 = 3.14159265358979323846;
    const deg2rad: f64 = pi / 180.0;

    const wf: i32 = instance.waveform;

    // ================================================================
    // DC waveform (waveform == 0)
    // ================================================================
    const i_dc: f64 = @as(f64, instance.dc);

    // ================================================================
    // PULSE waveform (waveform == 1)
    // ================================================================
    const p_i1: f64 = @as(f64, instance.pulse_i1);
    const p_i2: f64 = @as(f64, instance.pulse_i2);
    const p_td: f64 = @as(f64, instance.pulse_td);
    // Unresolved -1 sentinels: near-instant edges, never-falling pulse.
    const p_tr: f64 = @max(@as(f64, instance.pulse_tr), 1.0e-12);
    const p_tf: f64 = @max(@as(f64, instance.pulse_tf), 1.0e-12);
    const p_pw: f64 = if (instance.pulse_pw < 0) 1.0e30 else @as(f64, instance.pulse_pw);
    const p_per: f64 = if (instance.pulse_per < 0) 1.0e30 else @as(f64, instance.pulse_per);
    const p_phase: f64 = @as(f64, instance.pulse_phase);

    // Before delay: output is I1
    // After delay: compute phase-adjusted modular time
    const t_after_delay = t - p_td;
    const phase_offset = (p_phase * deg2rad / (2.0 * pi)) * p_per;
    const t_prime = t_after_delay + phase_offset;
    // Safe modular arithmetic: avoid division by zero on period
    const per_safe = @max(p_per, 1.0e-30);
    const t_prime_div = t_prime / per_safe;
    const t_mod = t_prime - @floor(t_prime_div) * per_safe;

    // Segment boundaries
    const seg_rise_end = p_tr;
    const seg_high_end = p_tr + p_pw;
    const seg_fall_end = p_tr + p_pw + p_tf;

    // Rise segment: 0 <= t_mod < TR
    const tr_safe = @max(p_tr, 1.0e-30);
    const i_rise = p_i1 + (p_i2 - p_i1) * (t_mod / tr_safe);

    // High segment: TR <= t_mod < TR + PW
    const i_high = p_i2;

    // Fall segment: TR + PW <= t_mod < TR + PW + TF
    const tf_safe = @max(p_tf, 1.0e-30);
    const i_fall = p_i2 + (p_i1 - p_i2) * ((t_mod - seg_high_end) / tf_safe);

    // Low segment: t_mod >= TR + PW + TF
    const i_low = p_i1;

    // Select segment (branchless chain)
    const i_seg = if (t_mod < seg_rise_end)
        i_rise
    else if (t_mod < seg_high_end)
        i_high
    else if (t_mod < seg_fall_end)
        i_fall
    else
        i_low;

    // Before delay, output I1; after delay, use computed segment
    const i_pulse = if (t_after_delay <= 0.0) p_i1 else i_seg;

    // ================================================================
    // SIN waveform (waveform == 2)
    // ================================================================
    const s_ioff: f64 = @as(f64, instance.sin_ioff);
    const s_iamp: f64 = @as(f64, instance.sin_iamp);
    const s_freq: f64 = @as(f64, instance.sin_freq);
    const s_td: f64 = @as(f64, instance.sin_td);
    const s_theta: f64 = @as(f64, instance.sin_theta);
    const s_phase: f64 = @as(f64, instance.sin_phase);

    const s_phase_rad = s_phase * deg2rad;
    const t_sin = t - s_td;

    // For t <= TD: I_OFF + I_AMP * sin(phase)
    const i_sin_before = s_ioff + s_iamp * contract.fmath.sin(s_phase_rad);

    // For t > TD: I_OFF + I_AMP * exp(-(t-TD)*theta) * sin(2*pi*f*(t-TD) + phase)
    const damp_arg = @min(-(t_sin) * s_theta, 80.0);
    const i_sin_after = s_ioff + s_iamp * contract.fmath.exp(damp_arg) * contract.fmath.sin(2.0 * pi * s_freq * t_sin + s_phase_rad);

    const i_sin = if (t_sin <= 0.0) i_sin_before else i_sin_after;

    // ================================================================
    // EXP waveform (waveform == 3)
    // ================================================================
    const e_i1: f64 = @as(f64, instance.exp_i1);
    const e_i2: f64 = @as(f64, instance.exp_i2);
    const e_td1: f64 = @as(f64, instance.exp_td1);
    const e_tau1: f64 = @as(f64, instance.exp_tau1);
    const e_td2: f64 = @as(f64, instance.exp_td2);
    const e_tau2: f64 = @as(f64, instance.exp_tau2);

    const tau1_safe = @max(e_tau1, 1.0e-30);
    const tau2_safe = @max(e_tau2, 1.0e-30);

    const t_e1 = t - e_td1;
    const t_e2 = t - e_td2;

    // Rising component: active when t > TD1
    const rise_exp_arg = @min(-t_e1 / tau1_safe, 80.0);
    const rise_comp = (e_i2 - e_i1) * (1.0 - contract.fmath.exp(rise_exp_arg));
    const rise_val = if (t_e1 > 0.0) rise_comp else 0.0;

    // Falling component: active when t > TD2
    const fall_exp_arg = @min(-t_e2 / tau2_safe, 80.0);
    const fall_comp = (e_i1 - e_i2) * (1.0 - contract.fmath.exp(fall_exp_arg));
    const fall_val = if (t_e2 > 0.0) fall_comp else 0.0;

    const i_exp = e_i1 + rise_val + fall_val;

    // ================================================================
    // SFFM waveform (waveform == 4)
    // ================================================================
    const fm_ioff: f64 = @as(f64, instance.sffm_ioff);
    const fm_iamp: f64 = @as(f64, instance.sffm_iamp);
    const fm_fc: f64 = @as(f64, instance.sffm_fc);
    const fm_mdi: f64 = @as(f64, instance.sffm_mdi);
    const fm_fs: f64 = @as(f64, instance.sffm_fs);
    const fm_phasec: f64 = @as(f64, instance.sffm_phasec);
    const fm_phases: f64 = @as(f64, instance.sffm_phases);

    const fm_phasec_rad = fm_phasec * deg2rad;
    const fm_phases_rad = fm_phases * deg2rad;

    // I_OFF + I_AMP * sin(2*pi*fc*t + phaseC + MDI * sin(2*pi*fs*t + phaseS))
    const fm_mod = fm_mdi * contract.fmath.sin(2.0 * pi * fm_fs * t + fm_phases_rad);
    const i_sffm = fm_ioff + fm_iamp * contract.fmath.sin(2.0 * pi * fm_fc * t + fm_phasec_rad + fm_mod);

    // ================================================================
    // AM waveform (waveform == 5)
    // ================================================================
    const am_ia: f64 = @as(f64, instance.am_ia);
    const am_io: f64 = @as(f64, instance.am_io);
    const am_mf: f64 = @as(f64, instance.am_mf);
    const am_fc_v: f64 = @as(f64, instance.am_fc);
    const am_td: f64 = @as(f64, instance.am_td);
    const am_phasec: f64 = @as(f64, instance.am_phasec);
    const am_phases: f64 = @as(f64, instance.am_phases);

    const am_phasec_rad = am_phasec * deg2rad;
    const am_phases_rad = am_phases * deg2rad;

    // For t < TD: I = 0
    // For t >= TD: I_A * (I_O + sin(2*pi*fm*t + phaseS)) * sin(2*pi*fc*t + phaseC)
    const am_envelope = am_io + contract.fmath.sin(2.0 * pi * am_mf * t + am_phases_rad);
    const am_carrier = contract.fmath.sin(2.0 * pi * am_fc_v * t + am_phasec_rad);
    const am_active = am_ia * am_envelope * am_carrier;
    const i_am = if (t < am_td) 0.0 else am_active;

    // ================================================================
    // Waveform selection (branchless chain of selects)
    // ================================================================
    return if (wf == 1)
        i_pulse
    else if (wf == 2)
        i_sin
    else if (wf == 3)
        i_exp
    else if (wf == 4)
        i_sffm
    else if (wf == 5)
        i_am
    else
        i_dc;
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);

    // Voltages are not used by an independent source (zero Jacobian), but
    // the signature is fixed by the contract.
    _ = x;
    _ = model;

    const mult: f64 = @as(f64, instance.m);

    // ================================================================
    // Output stamp: RHS[p] += M * I, RHS[n] -= M * I
    // ================================================================
    const i_out = mult * waveformCurrent(instance, t);

    return .{ S.con(i_out), S.con(-i_out) };
}

comptime {
    contract.validate(Self);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isource: dc with multiplier" {
    // I = m * dc = 3 * 2e-3 = 6e-3; out[p] = +6e-3, out[n] = -6e-3
    const model: Model = .{};
    const inst: Instance = .{ .dc = 2e-3, .m = 3 };
    const out = contract.evalValues(Self, .{ 0.7, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 6e-3), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -6e-3), out[1], 1e-9);
}

test "isource: pulse mid-rise" {
    // PULSE(0, 1mA, td=0, tr=1u, tf=1u, pw=1u, per=10u) at t = 0.5u:
    // t_mod = 0.5u < tr -> i = i1 + (i2-i1)*(t_mod/tr) = 0 + 1e-3*0.5 = 0.5e-3
    const model: Model = .{};
    const inst: Instance = .{
        .waveform = 1,
        .pulse_i1 = 0.0,
        .pulse_i2 = 1e-3,
        .pulse_td = 0.0,
        .pulse_tr = 1e-6,
        .pulse_tf = 1e-6,
        .pulse_pw = 1e-6,
        .pulse_per = 10e-6,
    };
    const out = contract.evalValues(Self, .{ 0.0, 0.0 }, &model, &inst, 0.5e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.5e-3), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.5e-3), out[1], 1e-9);
}

test "isource: sin at quarter period" {
    // SIN(ioff=1mA, iamp=2mA, f=1kHz) at t = 0.25ms:
    // i = 1e-3 + 2e-3 * sin(2*pi*1000*0.25e-3) = 1e-3 + 2e-3*sin(pi/2) = 3e-3
    const model: Model = .{};
    const inst: Instance = .{
        .waveform = 2,
        .sin_ioff = 1e-3,
        .sin_iamp = 2e-3,
        .sin_freq = 1000,
    };
    const out = contract.evalValues(Self, .{ 0.0, 0.0 }, &model, &inst, 0.25e-3);
    try testing.expectApproxEqAbs(@as(f64, 3e-3), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -3e-3), out[1], 1e-9);
}

test "isource: exp waveform rise" {
    // EXP(i1=0, i2=1mA, td1=0, tau1=1u, td2=1e9 (never)) at t = 1u:
    // i = 0 + 1e-3 * (1 - exp(-1)) = 1e-3 * 0.6321205588... = 6.321205588e-4
    const model: Model = .{};
    const inst: Instance = .{
        .waveform = 3,
        .exp_i1 = 0.0,
        .exp_i2 = 1e-3,
        .exp_td1 = 0.0,
        .exp_tau1 = 1e-6,
        .exp_td2 = 1e9,
        .exp_tau2 = 1e-6,
    };
    const out = contract.evalValues(Self, .{ 0.0, 0.0 }, &model, &inst, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 6.321205588e-4), out[0], 1e-9);
}
