const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: Vertical DMOS Power MOSFET
//
//   D (drain) -- RD -- d' (intrinsic drain)
//   G (gate)  -- RG -- g' (intrinsic gate)
//   S (source) -- RS -- s' (intrinsic source)
//
//   MOSFET channel:  d' -- [channel, controlled by Vg's'] -- s'
//   Body diode:      s' -- [diode] -- b' -- RB -- d'
//   RDS shunt:       d' -- [RDS] -- s'
//   GMIN:            d' -- s'
// ============================================================================

pub const U = enum(u8) { drain, gate, source, d_prime, g_prime, s_prime, b_prime };
pub const num_ports: usize = 3;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device Type & Geometry ---
    type_: i32 = 1, // 1 = NMOS, -1 = PMOS

    // --- DC: MOSFET Channel ---
    vto: f32 = 0,
    kp: f32 = 2e-5,
    ld: f32 = 0,
    phi: f32 = 0.6,
    lambda: f32 = 0,
    theta: f32 = 0,
    mtriode: f32 = 1,
    rds: f32 = 1e15,

    // --- DC: Subthreshold ---
    ksubthres: f32 = 0.1,
    subshift: f32 = 0,
    tksubthres1: f32 = 0,
    tksubthres2: f32 = 0,

    // --- DC: Quasi-Saturation ---
    rq: f32 = 0,
    vq: f32 = 0,

    // --- DC: Body Diode ---
    is: f32 = 1e-14,
    n: f32 = 1,
    bv: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))), // inf
    ibv: f32 = 1e-10,
    nbv: f32 = 1,
    eg: f32 = 1.11,
    xti: f32 = 3,
    rb: f32 = 0,

    // --- Series Resistances ---
    rd: f32 = 0,
    rs: f32 = 0,
    rg: f32 = 0,

    // --- Temperature Coefficients ---
    tnom: f32 = 27,
    tcvth: f32 = 0,
    mu: f32 = -1.5,
    texp0: f32 = 1.5,
    texp1: f32 = 0.3,
    trd1: f32 = 0,
    trd2: f32 = 0,
    trg1: f32 = 0,
    trg2: f32 = 0,
    trs1: f32 = 0,
    trs2: f32 = 0,
    trb1: f32 = 0,
    trb2: f32 = 0,

    // --- Capacitances ---
    cgs: f32 = 0,
    cgdmin: f32 = 0,
    cgdmax: f32 = 0,
    a: f32 = 1,
    cjo: f32 = 0,
    vj: f32 = 0.8,
    mj: f32 = 0.5, // body diode grading coefficient (model M)
    fc: f32 = 0.5,
    tt: f32 = 0,

    // --- Self-Heating ---
    rthjc: f32 = 1,
    rthca: f32 = 1000,
    cthj: f32 = 1e-5,
    rth_ext: f32 = 1000,
    derating: f32 = 0,

    // --- Noise ---
    kf: f32 = 0,
    af: f32 = 1,

    // --- Absolute Maximum Ratings ---
    vgs_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))), // inf
    vgd_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))),
    vds_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))),
    vgsr_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))),
    vgdr_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))),
    pd_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))),
    id_max: f32 = 0,
    idr_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))),
    te_max: f32 = @as(f32, @bitCast(@as(u32, 0x7f800000))),
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 1e-6,
    l: f32 = 1e-6,
    m: f32 = 1.0,
    area: f32 = 1.0,
    temp: f32 = 300.15,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// RD branch:  drain -- d'
// RG branch:  gate  -- g'
// RS branch:  source -- s'
// RB branch:  b' -- d'
// Channel:    d' -- s'  (via g')
// RDS shunt:  d' -- s'
// Body diode: s' -- b'
// GMIN:       d' -- s'

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD: drain -- d'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.drain) },
    // RG: gate -- g'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.g_prime) },
    .{ .row = @intFromEnum(U.g_prime), .col = @intFromEnum(U.gate) },
    // RS: source -- s'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.source) },
    // RB: b' -- d'
    .{ .row = @intFromEnum(U.b_prime), .col = @intFromEnum(U.b_prime) },
    .{ .row = @intFromEnum(U.b_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.b_prime) },
    // Channel + RDS + GMIN: d' -- s'
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    // Channel depends on g': d' -- g', s' -- g'
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.g_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.g_prime) },
    // g' self (RG)
    .{ .row = @intFromEnum(U.g_prime), .col = @intFromEnum(U.g_prime) },
    // Body diode: s' -- b'
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.b_prime) },
    .{ .row = @intFromEnum(U.b_prime), .col = @intFromEnum(U.s_prime) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Qgs: g' -- s'
// Qgd: g' -- d'
// Qsd (body diode): s' -- b'

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Qgs: g' -- s'
    .{ .row = @intFromEnum(U.g_prime), .col = @intFromEnum(U.g_prime) },
    .{ .row = @intFromEnum(U.g_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.g_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    // Qgd: g' -- d'
    .{ .row = @intFromEnum(U.g_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.g_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    // Qsd (body diode junction): s' -- b'
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.b_prime) },
    .{ .row = @intFromEnum(U.b_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.b_prime), .col = @intFromEnum(U.b_prime) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise (D-S)
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .thermal },
    // Source resistance thermal noise (S-D)
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.drain), .kind = .thermal },
    // Drain current shot noise (D-S)
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .shot },
    // Drain current flicker noise (D-S)
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .flicker },
};

// ============================================================================
// Parameter / Temperature Preprocessing (pure f64 — no x dependence)
// ============================================================================

const kb_q: f64 = 8.617333e-5; // k_B / q in V/K

/// Temperature-adjusted body diode saturation current. Pure f64 — no x.
fn isTemp(is_val: f64, xti: f64, eg: f64, t_ratio: f64, vt_nom: f64) f64 {
    return is_val * contract.fmath.exp(xti * contract.fmath.log(@max(t_ratio, 1e-30))) *
        contract.fmath.exp(@min((eg / vt_nom) * (1.0 - 1.0 / t_ratio), 80.0));
}

/// DC prep: everything eval() needs that does not depend on x.
const DcPrep = struct {
    type_f: f64,
    vth_t: f64,
    beta: f64,
    ksubthres_t: f64,
    subshift_p: f64,
    theta_p: f64,
    lam: f64,
    mtriode_p: f64,
    rds_p: f64,
    rq_p: f64,
    vq_p: f64,
    is_t: f64,
    nvt: f64,
    ibv_p: f64,
    bv_finite: f64,
    bv_active: bool,
    nbv_vt: f64,
    g_rd: f64,
    g_rg: f64,
    g_rs: f64,
    g_rb: f64,
    m_mult: f64,
    area: f64,
};

fn dcPrep(model: *const Model, instance: *const Instance) DcPrep {
    // --- Cast model parameters to f64 ---
    const type_f: f64 = @floatFromInt(model.type_);
    const vto: f64 = @as(f64, model.vto);
    const kp: f64 = @as(f64, model.kp);
    const ld: f64 = @as(f64, model.ld);
    const ksubthres_p: f64 = @as(f64, model.ksubthres);
    const tksubthres1_p: f64 = @as(f64, model.tksubthres1);
    const tksubthres2_p: f64 = @as(f64, model.tksubthres2);
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const bv: f64 = @as(f64, model.bv);
    const nbv: f64 = @as(f64, model.nbv);
    const eg: f64 = @as(f64, model.eg);
    const xti: f64 = @as(f64, model.xti);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const rg: f64 = @as(f64, model.rg);
    const rb: f64 = @as(f64, model.rb);
    const tnom_c: f64 = @as(f64, model.tnom);
    const tcvth: f64 = @as(f64, model.tcvth);
    const mu_p: f64 = @as(f64, model.mu);
    const trd1: f64 = @as(f64, model.trd1);
    const trd2: f64 = @as(f64, model.trd2);
    const trg1: f64 = @as(f64, model.trg1);
    const trg2: f64 = @as(f64, model.trg2);
    const trs1: f64 = @as(f64, model.trs1);
    const trs2: f64 = @as(f64, model.trs2);
    const trb1: f64 = @as(f64, model.trb1);
    const trb2: f64 = @as(f64, model.trb2);
    const texp0_p: f64 = @as(f64, model.texp0);
    // texp1: listed as RD1 temp exponent; single-RD model uses texp0 only.

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);
    const m_mult: f64 = @as(f64, instance.m);
    const area: f64 = @as(f64, instance.area);
    const t_dev: f64 = @as(f64, instance.temp);

    // --- Temperature ---
    const t_nom_k: f64 = tnom_c + 273.15;
    const delta_t: f64 = t_dev - t_nom_k;

    // Temperature-adjusted threshold voltage
    const vth_t: f64 = vto + tcvth * delta_t;

    // Temperature-adjusted transconductance
    const t_ratio: f64 = t_dev / t_nom_k;
    const kp_t: f64 = kp * contract.fmath.exp(mu_p * contract.fmath.log(@max(t_ratio, 1e-30)));

    // Temperature-adjusted subthreshold slope
    const ksubthres_t: f64 = ksubthres_p * (1.0 + tksubthres1_p * delta_t + tksubthres2_p * delta_t * delta_t);

    // Temperature-adjusted body diode saturation current
    const vt_nom: f64 = kb_q * t_nom_k;
    const vt_dev: f64 = kb_q * t_dev;
    const is_t: f64 = isTemp(is_val, xti, eg, t_ratio, vt_nom);

    // Temperature-adjusted resistances
    // Drain resistance: polynomial (trd1/trd2) * exponential (texp0) temperature models
    const rd_exp_factor: f64 = contract.fmath.exp(texp0_p * contract.fmath.log(@max(t_ratio, 1e-30)));
    const rd_t: f64 = rd * (1.0 + trd1 * delta_t + trd2 * delta_t * delta_t) * rd_exp_factor;
    const rs_t: f64 = rs * (1.0 + trs1 * delta_t + trs2 * delta_t * delta_t);
    const rg_t: f64 = rg * (1.0 + trg1 * delta_t + trg2 * delta_t * delta_t);
    const rb_t: f64 = rb * (1.0 + trb1 * delta_t + trb2 * delta_t * delta_t);

    // Thermal voltage at device temperature
    const nvt: f64 = n_em * vt_dev;

    // Effective geometry
    const l_eff: f64 = @max(l_inst - 2.0 * ld, 1e-9);
    const w_eff: f64 = @max(w_inst, 1e-9);
    const beta: f64 = kp_t * w_eff / l_eff;

    // Body diode breakdown activation
    const bv_finite: f64 = if (bv == bv) bv else 1.0e30; // NaN/inf check via self-equality
    const bv_active: bool = bv_finite < 1.0e30;

    // Series resistance conductances
    const g_rd: f64 = if (rd_t > 0.0) m_mult / rd_t else 1.0e12;
    const g_rg: f64 = if (rg_t > 0.0) m_mult / rg_t else 1.0e12;
    const g_rs: f64 = if (rs_t > 0.0) m_mult / rs_t else 1.0e12;
    const g_rb: f64 = if (rb_t > 0.0) area * m_mult / rb_t else 1.0e12;

    return .{
        .type_f = type_f,
        .vth_t = vth_t,
        .beta = beta,
        .ksubthres_t = ksubthres_t,
        .subshift_p = @as(f64, model.subshift),
        .theta_p = @as(f64, model.theta),
        .lam = @as(f64, model.lambda),
        .mtriode_p = @as(f64, model.mtriode),
        .rds_p = @as(f64, model.rds),
        .rq_p = @as(f64, model.rq),
        .vq_p = @as(f64, model.vq),
        .is_t = is_t,
        .nvt = nvt,
        .ibv_p = @as(f64, model.ibv),
        .bv_finite = bv_finite,
        .bv_active = bv_active,
        .nbv_vt = nbv * vt_dev,
        .g_rd = g_rd,
        .g_rg = g_rg,
        .g_rs = g_rs,
        .g_rb = g_rb,
        .m_mult = m_mult,
        .area = area,
    };
}

// ============================================================================
// DC Current Function (eval) — value-form: generic over scalar S; only the
// x-dependent tail uses S ops, all parameter prep is f64 (dcPrep above).
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const dp = @intFromEnum(U.d_prime);
    const gp = @intFromEnum(U.g_prime);
    const sp = @intFromEnum(U.s_prime);
    const bp = @intFromEnum(U.b_prime);

    const p = &pc.dc;

    // --- Constants ---
    const gmin: f64 = 1.0e-12;
    const eps_sd: f64 = 1.0e-30;
    const eps_sat: f64 = 1.0e-12;

    // ========================================================================
    // Node voltages
    // ========================================================================
    const v_dp = x[dp];
    const v_gp = x[gp];
    const v_sp = x[sp];
    const v_bp = x[bp];

    // ========================================================================
    // Voltage Preprocessing
    // ========================================================================
    // PMOS sign inversion
    const vgs_raw = v_gp.sub(v_sp).scale(p.type_f);
    const vds_raw = v_dp.sub(v_sp).scale(p.type_f);

    // Source-drain reversal (smooth)
    const vds_abs = vds_raw.mul(vds_raw).addC(eps_sd).sqrt();
    const mode = vds_raw.div(vds_abs);
    const vds_int = vds_abs;
    const vgs_int = vgs_raw.sub(mode.neg().addC(1.0).scale(0.5).mul(vds_raw));

    // ========================================================================
    // Channel Current
    // ========================================================================
    // Gate overdrive
    const vgst = vgs_int.addC(-p.vth_t);

    // Subthreshold smoothing (softplus)
    const sub_arg = vgst.addC(-p.subshift_p).div(S.con(p.ksubthres_t)).minC(80.0);
    const vgst_eff = sub_arg.exp().addC(1.0).log().scale(p.ksubthres_t);

    // Mobility degradation
    const f_theta = S.con(1.0).div(vgst.scale(p.theta_p).addC(1.0));

    // Channel-length modulation
    const f_lambda = vds_int.scale(p.lam).addC(1.0);

    // Effective drain-source voltage (smooth saturation clamp)
    const vdsat = vgst_eff;
    const vds_diff = vds_int.sub(vdsat);
    const sqrt_diff = vds_diff.mul(vds_diff).addC(eps_sat).sqrt();
    const vds_eff = vds_int.add(vdsat).sub(sqrt_diff).scale(0.5);

    // Triode multiplier (smooth blend)
    const s_triode = vds_diff.div(sqrt_diff).addC(1.0).scale(0.5);
    const f_mtr = s_triode.scale(1.0 - p.mtriode_p).addC(p.mtriode_p);

    // Forward drain current
    const id_fwd = vgst_eff.mul(vds_eff).sub(vds_eff.mul(vds_eff).scale(0.5))
        .scale(p.beta).mul(f_lambda).mul(f_theta).mul(f_mtr);

    // Quasi-saturation effect: when rq > 0 and vq > 0, a voltage-dependent
    // resistance limits saturation current. The quasi-saturation resistance
    // drops as Vds increases (more drift region saturates), modeled as
    // Rqs = RQ / (1 + Vds/VQ). The effective channel current is reduced by
    // dividing by the additional voltage drop across Rqs:
    // Id_eff = Id_fwd / (1 + Id_fwd * Rqs / Vds_int), which smoothly reduces
    // current when the ohmic drop across the drift region (Id * Rqs) becomes
    // comparable to Vds. (Activation is a pure parameter condition.)
    const id_qs = if (p.rq_p > 0.0 and p.vq_p > 0.0) blk: {
        const rqs = S.con(p.rq_p).div(vds_int.div(S.con(p.vq_p)).addC(1.0));
        const qs_denom = id_fwd.mul(rqs).div(vds_int.addC(1.0e-30)).addC(1.0);
        break :blk id_fwd.div(qs_denom);
    } else id_fwd;

    // Original Vds (unsymmetrized) for RDS and GMIN
    const vds_orig = v_dp.sub(v_sp).scale(p.type_f);

    // Reversal correction
    const id_ch = id_qs.mul(mode);

    // ========================================================================
    // Drain-Source Shunt Resistance
    // ========================================================================
    const i_rds = if (p.rds_p > 0.0 and p.rds_p < 1.0e30) vds_orig.div(S.con(p.rds_p)) else S.con(0.0);

    // ========================================================================
    // GMIN Convergence Aid
    // ========================================================================
    const i_gmin = vds_orig.scale(gmin);

    // ========================================================================
    // Body Diode Current
    // ========================================================================
    // Forward diode voltage (source to drain, through b' node)
    // Diode is between s' and b'. In NMOS, forward is when Vs' > Vb'.
    const vsd_diode = v_sp.sub(v_bp).scale(p.type_f);

    // Diode current
    const diode_arg = vsd_diode.div(S.con(p.nvt)).minC(80.0);
    const i_diode = diode_arg.exp().addC(-1.0).scale(p.is_t).add(vsd_diode.scale(gmin));

    // ========================================================================
    // Body Diode Breakdown
    // ========================================================================
    // IBV sets the current magnitude at breakdown: I_bkdn(Vsd=-BV) = -IBV
    // (Activation depends on the BV parameter only.)
    const i_bkdn = if (p.bv_active)
        vsd_diode.addC(p.bv_finite).neg().div(S.con(p.nbv_vt)).minC(80.0).exp().scale(-p.ibv_p)
    else
        S.con(0.0);

    // Total diode current
    const i_diode_total = i_diode.add(i_bkdn);

    // ========================================================================
    // Total intrinsic current (d' -> s')
    // ========================================================================
    // Channel current + RDS shunt + GMIN go from d' to s'
    // Body diode current goes from s' to b' (then b' to d' via RB)
    const i_ch_total = id_ch.add(i_rds).add(i_gmin).scale(p.m_mult);
    const i_diode_scaled = i_diode_total.scale(p.area).scale(p.m_mult);

    // ========================================================================
    // Series Resistances
    // ========================================================================
    // RD: drain -- d'
    const i_rd = x[d].sub(v_dp).scale(p.g_rd);
    // RG: gate -- g'
    const i_rg = x[g].sub(v_gp).scale(p.g_rg);
    // RS: source -- s'
    const i_rs = x[s].sub(v_sp).scale(p.g_rs);
    // RB: b' -- d' (body diode in-series resistance)
    const i_rb = v_bp.sub(v_dp).scale(p.g_rb);

    // ========================================================================
    // KCL Node Stamps with PMOS sign restoration
    // ========================================================================
    // External nodes: current through series resistances.
    // d': RD brings current in, channel+RDS+GMIN drain current out, RB brings diode current in
    //     (i_rd flows drain->d', so d' receives -i_rd from the RD perspective;
    //      positive id_ch means current out of d'; positive i_rb means current into d')
    // g': RG brings current in, no DC gate current
    // s': RS brings current in, channel current enters, diode current leaves to b'
    // b': diode current from s' arrives, RB current leaves to d'
    const i_ch_signed = i_ch_total.scale(p.type_f);
    const i_diode_signed = i_diode_scaled.scale(p.type_f);
    return .{
        i_rd, // drain
        i_rg, // gate
        i_rs, // source
        i_rd.neg().add(i_ch_signed).add(i_rb), // d'
        i_rg.neg(), // g'
        i_rs.neg().sub(i_ch_signed).sub(i_diode_signed), // s'
        i_diode_signed.sub(i_rb), // b'
    };
}

// ============================================================================
// Charge Function (q)
// ============================================================================

/// Charge prep: everything q() needs that does not depend on x.
const QPrep = struct {
    type_f: f64,
    cgs_p: f64,
    cgdmin: f64,
    cgd_diff: f64,
    two_a: f64,
    cjo: f64,
    vj: f64,
    mj: f64,
    fc_vj: f64,
    one_minus_mj: f64,
    f1: f64,
    f2: f64,
    f3: f64,
    tt: f64,
    is_t: f64,
    nvt: f64,
    m_mult: f64,
    area: f64,
};

fn qPrep(model: *const Model, instance: *const Instance) QPrep {
    // --- Cast model parameters to f64 ---
    const a_p: f64 = @as(f64, model.a);
    const cgdmin: f64 = @as(f64, model.cgdmin);
    const cgdmax: f64 = @as(f64, model.cgdmax);
    const vj: f64 = @as(f64, model.vj);
    const mj: f64 = @as(f64, model.mj);
    const fc: f64 = @as(f64, model.fc);
    const cjo: f64 = @as(f64, model.cjo);
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const tnom_c: f64 = @as(f64, model.tnom);
    const eg: f64 = @as(f64, model.eg);
    const xti: f64 = @as(f64, model.xti);

    // --- Cast instance parameters to f64 ---
    const t_dev: f64 = @as(f64, instance.temp);

    // --- Temperature ---
    const t_nom_k: f64 = tnom_c + 273.15;
    const vt_dev: f64 = kb_q * t_dev;
    const nvt: f64 = n_em * vt_dev;

    // Temperature-adjusted IS for transit time diffusion charge
    const t_ratio: f64 = t_dev / t_nom_k;
    const vt_nom: f64 = kb_q * t_nom_k;
    const is_t: f64 = isTemp(is_val, xti, eg, t_ratio, vt_nom);

    // Depletion charge constants
    const one_minus_mj: f64 = 1.0 - mj;
    const one_minus_fc: f64 = 1.0 - fc;
    const f1: f64 = (cjo * vj / one_minus_mj) * (1.0 - contract.fmath.exp(one_minus_mj * contract.fmath.log(@max(one_minus_fc, 1e-30))));
    const f2: f64 = contract.fmath.exp((1.0 + mj) * contract.fmath.log(@max(one_minus_fc, 1e-30)));
    const f3: f64 = 1.0 - fc * (1.0 + mj);

    return .{
        .type_f = @floatFromInt(model.type_),
        .cgs_p = @as(f64, model.cgs),
        .cgdmin = cgdmin,
        .cgd_diff = cgdmax - cgdmin,
        .two_a = 2.0 * a_p,
        .cjo = cjo,
        .vj = vj,
        .mj = mj,
        .fc_vj = fc * vj,
        .one_minus_mj = one_minus_mj,
        .f1 = f1,
        .f2 = f2,
        .f3 = f3,
        .tt = @as(f64, model.tt),
        .is_t = is_t,
        .nvt = nvt,
        .m_mult = @as(f64, instance.m),
        .area = @as(f64, instance.area),
    };
}

pub const PrepCache = struct { dc: DcPrep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{
        .dc = dcPrep(model, instance),
        .q = qPrep(model, instance),
    };
}

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const dp = @intFromEnum(U.d_prime);
    const gp = @intFromEnum(U.g_prime);
    const sp = @intFromEnum(U.s_prime);
    const bp = @intFromEnum(U.b_prime);

    const p = &pc.q;

    // --- Node voltages ---
    const v_gp = x[gp];
    const v_sp = x[sp];
    const v_dp = x[dp];
    const v_bp = x[bp];

    // ========================================================================
    // Gate-Source Charge (linear)
    // ========================================================================
    // Vgs without PMOS flip for charge
    const vgs_q = v_gp.sub(v_sp);
    const q_gs = vgs_q.scale(p.cgs_p).scale(p.m_mult);

    // ========================================================================
    // Gate-Drain Charge (Non-Linear Cgd)
    // ========================================================================
    const vgd_q = v_gp.sub(v_dp);

    // When cgdmin == cgdmax, linear; otherwise nonlinear integral (the
    // selection is a pure parameter condition):
    // Qgd = Cgdmin*Vgd + (Cgdmax-Cgdmin)/(2a) * (2a*Vgd - ln(1+exp(min(2a*Vgd,80))))
    const q_gd_raw = if (@abs(p.cgd_diff) < 1.0e-30) vgd_q.scale(p.cgdmin) else blk: {
        const two_a_vgd = vgd_q.scale(p.two_a);
        const log_term = two_a_vgd.minC(80.0).exp().addC(1.0).log();
        break :blk vgd_q.scale(p.cgdmin).add(two_a_vgd.sub(log_term).scale(p.cgd_diff / p.two_a));
    };
    const q_gd = q_gd_raw.scale(p.m_mult);

    // ========================================================================
    // Body Diode Junction Charge
    // ========================================================================
    // Vsd for body diode (s' to b')
    const vsd_q = v_sp.sub(v_bp).scale(p.type_f);

    // Depletion charge (when CJO > 0). Region split at FC*VJ follows the
    // original piecewise formula: branch on the voltage value, each branch
    // computed in S ops.
    const q_dep = if (vsd_q.val() < p.fc_vj) blk: {
        // Reverse/moderate forward: vsd < FC*VJ
        const x_dep = vsd_q.div(S.con(p.vj)).neg().addC(1.0).maxC(1e-30);
        break :blk x_dep.log().scale(p.one_minus_mj).exp().neg().addC(1.0)
            .scale(p.cjo * p.vj / p.one_minus_mj);
    } else blk: {
        // Strong forward: vsd >= FC*VJ (quadratic extension)
        const lin = vsd_q.addC(-p.fc_vj).scale(p.f3);
        const quad = vsd_q.mul(vsd_q).addC(-(p.fc_vj * p.fc_vj)).scale(p.mj / (2.0 * p.vj));
        break :blk lin.add(quad).scale(p.cjo / p.f2).addC(p.f1);
    };

    // Transit time diffusion charge (uses temperature-adjusted IS)
    const diode_arg = vsd_q.div(S.con(p.nvt)).minC(80.0);
    const i_diode_q = diode_arg.exp().addC(-1.0).scale(p.is_t);
    const q_tt = i_diode_q.scale(p.tt);

    // Total body diode charge
    const q_sd = q_dep.add(q_tt).scale(p.area).scale(p.m_mult);

    // ========================================================================
    // Charge Node Contributions
    // ========================================================================
    // Q_D = -Q_gd - Q_sd  (intrinsic drain d')
    // Q_G = Q_gs + Q_gd    (intrinsic gate g')
    // Q_S = -Q_gs + Q_sd   (intrinsic source s')

    return .{
        S.con(0.0), // drain
        S.con(0.0), // gate
        S.con(0.0), // source
        q_gd.neg(), // d'
        q_gs.add(q_gd), // g'
        q_gs.neg().add(q_sd), // s'
        q_sd.neg(), // b'
    };
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const dp = @intFromEnum(U.d_prime);
    const gp = @intFromEnum(U.g_prime);
    const sp = @intFromEnum(U.s_prime);
    const bp = @intFromEnum(U.b_prime);

    const type_f: f64 = @floatFromInt(model.type_);
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const tnom_c: f64 = @as(f64, model.tnom);
    const vto: f64 = @as(f64, model.vto);
    const vt: f64 = kb_q * (tnom_c + 273.15);
    const nvt: f64 = n_em * vt;

    var result = x_new;

    // ========================================================================
    // Body Diode PN Junction Limiting (DEVpnjlim)
    // ========================================================================
    // Diode is between s' and b', forward voltage Vsd = (Vs' - Vb') * type
    const vsd_new: f64 = (x_new[sp] - x_new[bp]) * type_f;
    const vsd_old: f64 = (x_old[sp] - x_old[bp]) * type_f;

    const v_crit: f64 = nvt * contract.fmath.log(nvt / (@sqrt(2.0) * is_val));

    var vsd_limited = vsd_new;

    if (vsd_new > v_crit and @abs(vsd_new - vsd_old) > 2.0 * nvt) {
        if (vsd_old > 0.0) {
            const arg = (vsd_new - vsd_old) / nvt;
            if (arg > 0.0) {
                vsd_limited = vsd_old + nvt * (2.0 + contract.fmath.log(arg - 2.0));
            } else {
                vsd_limited = v_crit;
            }
        } else {
            vsd_limited = nvt * contract.fmath.log(vsd_new / nvt);
        }
    }

    // Apply limiting delta to source node (s')
    const delta_sd = (vsd_limited - vsd_new) * type_f;
    result[sp] = x_new[sp] + delta_sd;

    // ========================================================================
    // MOSFET Gate Limiting (DEVfetlim)
    // ========================================================================
    const vgs_new: f64 = (x_new[gp] - x_new[sp]) * type_f;
    const vgs_old: f64 = (x_old[gp] - x_old[sp]) * type_f;

    const v_tsthi: f64 = @abs(2.0 * (vgs_old - vto)) + 2.0;
    const v_tstlo: f64 = v_tsthi * 0.5 + 2.0;
    const v_tox: f64 = vto + 3.5;
    const dv: f64 = vgs_new - vgs_old;

    var vgs_limited = vgs_new;

    if (vgs_old >= vto) {
        // Above threshold
        if (vgs_old >= v_tox) {
            // Well above threshold
            if (dv <= 0.0) {
                // Decreasing
                if (vgs_new >= v_tox and -dv > v_tsthi) {
                    vgs_limited = vgs_old - v_tsthi;
                } else {
                    vgs_limited = @max(vgs_new, vto + 2.0);
                }
            } else {
                // Increasing
                if (dv >= v_tsthi) {
                    vgs_limited = vgs_old + v_tsthi;
                }
            }
        } else {
            // Transition region
            if (dv <= 0.0) {
                // Decreasing
                if (-dv > v_tsthi) {
                    vgs_limited = vgs_old - v_tsthi;
                }
            } else {
                // Increasing
                if (dv >= v_tstlo) {
                    vgs_limited = vgs_old + v_tstlo;
                }
            }
        }
    } else {
        // Below threshold
        if (dv <= 0.0) {
            if (-dv > v_tsthi) {
                vgs_limited = vgs_old - v_tsthi;
            }
        } else {
            if (dv >= v_tstlo) {
                vgs_limited = vgs_old + v_tstlo;
            }
        }
    }

    // Apply gate limiting delta to g'
    const delta_gs = (vgs_limited - vgs_new) * type_f;
    result[gp] = x_new[gp] + delta_gs;

    // ========================================================================
    // Drain-Source Limiting (DEVlimvds)
    // ========================================================================
    const vds_new: f64 = (x_new[dp] - x_new[sp]) * type_f;
    const vds_old: f64 = (x_old[dp] - x_old[sp]) * type_f;

    var vds_limited = vds_new;

    if (vds_old >= 3.5) {
        if (vds_new > vds_old) {
            vds_limited = @min(vds_new, 3.0 * vds_old + 2.0);
        } else if (vds_new < 3.5) {
            vds_limited = @max(vds_new, 2.0);
        }
    } else {
        if (vds_new > vds_old) {
            vds_limited = @min(vds_new, 4.0);
        } else {
            vds_limited = @max(vds_new, -0.5);
        }
    }

    // Apply Vds limiting delta to d'
    const delta_ds = (vds_limited - vds_new) * type_f;
    result[dp] = x_new[dp] + delta_ds;

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    // Blend: at lambda=0, IS = gmin (easy convergence); at lambda=1, IS = original
    const is_stepped = is_orig + (gmin_step - is_orig) * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================
// Expected values below are regression values from the OLD pointer-form
// i()/q() implementation, evaluated on the same inputs. The dominant-term
// hand arithmetic is shown per test.

const testing = std.testing;

test "vdmos: on-state channel current (saturation)" {
    // vto=2, kp=1, x = {D=5, G=5, S=0, d'=5, g'=5, s'=0, b'=5}.
    // Hand arithmetic (old formula): vgs=5, vds=5, mode=+1.
    //   beta = kp_t * w/l = kp_t (w == l). kp_t = kp * (T/Tnom)^mu; T =
    //   f64(f32(300.15)) = 300.1499938964844 K vs Tnom = 300.15 K, so
    //   kp_t ~= 1 + 3.05e-8.
    //   vgst = 5-2 = 3; softplus vgst_eff ~= 3; vds_eff ~= vdsat = 3.
    //   Id = beta*(3*3 - 0.5*3^2) = beta*4.5 ~= 4.5000001373.
    //   i_rds = 5/1e15, i_gmin = 5e-12; body diode reverse: Vsb' = -5 ->
    //   i_diode ~= -(IS + gmin*5) = -5.01e-12 at b'.
    const model: Model = .{ .vto = 2, .kp = 1 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 5, 5, 0, 5, 5, 0, 5 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), out[2], 1e-15);
    try testing.expectApproxEqRel(@as(f64, 4.5000001372655065), out[3], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), out[4], 1e-15);
    try testing.expectApproxEqRel(@as(f64, -4.500000137260496), out[5], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -5.0099999904877055e-12), out[6], 1e-9);
}

test "vdmos: body diode forward conduction" {
    // Same model, x = {0, 0, 0.6, 0, 0, 0.6, 0}: Vs'b' = 0.6 forward-biases
    // the body diode; channel is off (vgs_int = 0 after reversal symmetrize,
    // vgst = -2 deep subthreshold).
    // Hand arithmetic: nvt = 8.617333e-5 * 300.1499939 = 0.02586492...
    //   i_diode = IS_T*(exp(0.6/nvt)-1) + gmin*0.6
    //           ~= 1e-14*exp(23.1974) + 6e-13 ~= 1.187e-4.
    //   s' sees -i_diode (plus ~-6e-13 channel-side leakage on d').
    const model: Model = .{ .vto = 2, .kp = 1 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0, 0, 0.6, 0, 0, 0.6, 0 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, -6.006000212495016e-13), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -1.1871872104185935e-4), out[5], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 1.1871872164245938e-4), out[6], 1e-9);
}

test "vdmos: series resistances RD/RG/RS" {
    // rd=10, rg=100, rs=1; external nodes offset from intrinsic ones:
    //   i_rd = (5.1-5)/rd_t, rd_t = 10*(T/Tnom)^1.5 ~= 10*(1-3.05e-8)
    //        ~= 0.0100000003
    //   i_rg = (5.2-5)/100 = 2e-3, i_rs = (-0.05-0)/1 = -5e-2.
    const model: Model = .{ .vto = 2, .kp = 1, .rd = 10, .rg = 100, .rs = 1 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 5.1, 5.2, -0.05, 5, 5, 0, 5 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, 1.0000000305023241e-2), out[0], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 2.0000000000000018e-3), out[1], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -5e-2), out[2], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 4.490000136960483), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -2.0000000000000018e-3), out[4], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -4.4500001372604965), out[5], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -5.0099999904877055e-12), out[6], 1e-9);
}

test "vdmos: charges (reverse junction, vsd < FC*VJ)" {
    // cgs=1n, cgdmin=20p, cgdmax=500p, a=0.5, cjo=1n, tt=50n.
    // x = {5, 10, 0, 5, 10, 0, -0.3}: vgs=10, vgd=5, vsd = 0.3 < fc*vj = 0.4.
    // Hand arithmetic (old formula):
    //   q_gs = 1e-9*10 = 1e-8.
    //   Qgd: 2a*vgd = 5; q_gd = 20e-12*5 + (480e-12/1)*(5 - ln(1+e^5))
    //        = 1e-10 + 480e-12*(-6.7153e-3) ~= 9.6777e-11.
    //   Depletion: q_dep = (cjo*vj/(1-mj))*(1-(1-0.3/0.8)^0.5)
    //        = 1.6e-9*(1-sqrt(0.625)) ~= 3.3509e-10 (tt term ~5e-17).
    const model: Model = .{ .vto = 2, .kp = 1, .cgs = 1e-9, .cgdmin = 20e-12, .cgdmax = 500e-12, .a = 0.5, .cjo = 1e-9, .tt = 50e-9 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 5, 10, 0, 5, 10, 0, -0.3 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0), out[0], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0), out[1], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0), out[2], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -9.677663242006781e-11), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 1.0096776349600753e-8), out[4], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -9.664910736907843e-9), out[5], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -3.3508898027284215e-10), out[6], 1e-9);
}

test "vdmos: charges (forward junction, vsd >= FC*VJ)" {
    // Same caps, x = {5, 10, 0, 5, 10, 0, -0.5}: vsd = 0.5 >= fc*vj = 0.4 ->
    // quadratic extension branch.
    // Hand arithmetic: f1 = 1.6e-9*(1-sqrt(0.5)) = 4.6863e-10,
    //   f2 = 0.5^1.5 = 0.35355, f3 = 1-0.5*1.5 = 0.25,
    //   q_dep = f1 + (1e-9/f2)*(0.25*(0.5-0.4) + (0.5/1.6)*(0.25-0.16))
    //         = 4.6863e-10 + 2.8284e-9*(0.025 + 0.028125) ~= 6.190e-10.
    const model: Model = .{ .vto = 2, .kp = 1, .cgs = 1e-9, .cgdmin = 20e-12, .cgdmax = 500e-12, .a = 0.5, .cjo = 1e-9, .tt = 50e-9 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 5, 10, 0, 5, 10, 0, -0.5 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, -9.677663242006781e-11), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 1.0096776349600753e-8), out[4], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -9.380986115820369e-9), out[5], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -6.190136013603172e-10), out[6], 1e-9);
}
