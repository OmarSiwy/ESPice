const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: D -- Rd -- D' --[channel]-- S' -- Rs -- S
//           G --[diode]-- D'
//           G --[diode]-- S'
// ============================================================================

pub const U = enum(u8) { drain, gate, source, drain_prime, source_prime };
pub const num_ports: usize = 3;

// ============================================================================
// Model Parameters (Parker-Skellern JFET2 / MESFET Level 2)
// ============================================================================

pub const Model = struct {
    // --- Transconductance & Channel ---
    beta: f32 = 1e-4,
    vto: f32 = -2,
    lambda: f32 = 0,
    p: f32 = 2,
    @"q": f32 = 2,
    xi: f32 = 1000,
    z: f32 = 1,
    mxi: f32 = 0,

    // --- Subthreshold ---
    vst: f32 = 0,
    mvst: f32 = 0,

    // --- Drain feedback ---
    lfgam: f32 = 0,
    lfg1: f32 = 0,
    lfg2: f32 = 0,
    hfgam: f32 = 0,
    hfeta: f32 = 0,
    hfe1: f32 = 0,
    hfe2: f32 = 0,
    hfg1: f32 = 0,
    hfg2: f32 = 0,

    // --- Thermal reduction ---
    delta: f32 = 0,
    taud: f32 = 0,
    taug: f32 = 0,

    // --- Gate junction ---
    is: f32 = 1e-14,
    n: f32 = 1,
    pb: f32 = 1,
    ibd: f32 = 0,
    vbd: f32 = 1,
    fc: f32 = 0.5,

    // --- Series resistances ---
    rd: f32 = 0,
    rs: f32 = 0,

    // --- Capacitances ---
    cgs: f32 = 0,
    cgd: f32 = 0,
    cds: f32 = 0,
    acgam: f32 = 0,
    xc: f32 = 0,

    // --- Noise ---
    kf: f32 = 0,
    af: f32 = 1,

    // --- Temperature ---
    tnom: f32 = 27,

    // --- Version ---
    ver: f32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    area: f32 = 1.0,
    m: f32 = 1.0,
    temp: f32 = 27.0,
    dtemp: f32 = 0.0,
    w: f32 = 1e-6,
    l: f32 = 1e-6,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// Branches:
//   Rd: D -- D'        (stamps D,D  D,D'  D',D  D',D')
//   Rs: S -- S'        (stamps S,S  S,S'  S',S  S',S')
//   Channel: D' -- S'  (stamps D',D'  D',S'  S',D'  S',S')
//   GS diode: G -- S'  (stamps G,G  G,S'  S',G  S',S')
//   GD diode: G -- D'  (stamps G,G  G,D'  D',G  D',D')
//   GMIN: D' -- S'     (same as channel)

pub const g_pattern_override = [_]contract.Entry(n_u){
    // Rd branch: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain) },
    // Rs branch: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source) },
    // Gate junction GS: G -- S'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    // D' node (Rd + channel + GD diode)
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    // S' node (Rs + channel + GS diode)
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Charge on G, D', S' from junction capacitances and Cds

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Q_GS: G -- S'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    // Q_DS: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Channel shot noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Channel flicker noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
};

// ============================================================================
// Constants (shared by DC and limiting code)
// ============================================================================

const gmin: f64 = 1.0e-12;
const kq: f64 = 8.617333262145e-5; // k/q in V/K
const f_x: f64 = -10.0;
const m_x: f64 = 40.0;
const e_mx: f64 = 2.35385266837019985e17; // e^40

// ============================================================================
// DC parameter preprocessing (pure f64 -- nothing here depends on x)
// ============================================================================

const DcParams = struct {
    a_eff: f64,
    nvt: f64,
    i_sat: f64,
    i_bd: f64,
    has_bd: bool,
    vbd: f64,
    g_rd: f64,
    g_rs: f64,
    vto: f64,
    lfgam: f64,
    lfg1: f64,
    lfg2: f64,
    vst: f64,
    mvst: f64,
    mxi: f64,
    xi_woo: f64,
    za: f64,
    d3: f64,
    z_param: f64,
    p_exp: f64,
    q_exp: f64,
    beta: f64,
    lam: f64,
    delta: f64,
};

fn dcParams(model: *const Model, instance: *const Instance) DcParams {
    // --- Cast model parameters to f64 ---
    const beta: f64 = @as(f64, model.beta);
    const vto: f64 = @as(f64, model.vto);
    const lam: f64 = @as(f64, model.lambda);
    const p_exp: f64 = @as(f64, model.p);
    const q_exp: f64 = @as(f64, model.@"q");
    const xi: f64 = @as(f64, model.xi);
    const z_param: f64 = @as(f64, model.z);
    const mxi: f64 = @as(f64, model.mxi);
    const vst: f64 = @as(f64, model.vst);
    const mvst: f64 = @as(f64, model.mvst);
    const lfgam: f64 = @as(f64, model.lfgam);
    const lfg1: f64 = @as(f64, model.lfg1);
    const lfg2: f64 = @as(f64, model.lfg2);
    const delta: f64 = @as(f64, model.delta);
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const phi_b: f64 = @as(f64, model.pb);
    const ibd_val: f64 = @as(f64, model.ibd);
    const vbd: f64 = @as(f64, model.vbd);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);

    // --- Cast instance parameters to f64 ---
    const area: f64 = @as(f64, instance.area);
    const m_mult: f64 = @as(f64, instance.m);
    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);

    // --- Effective area and thermal voltage ---
    const a_eff = area * m_mult;
    const t_dev = temp + 273.15 + dtemp;
    const nvt = t_dev * kq * n_em;

    // --- Precomputed model constants ---
    const woo = phi_b - vto;
    const xi_woo = xi * woo;
    const za = @sqrt(1.0 + z_param) / 2.0;
    const d3 = p_exp / (q_exp * @exp((p_exp - q_exp) * @log(@max(woo, 1e-30))));

    return .{
        .a_eff = a_eff,
        .nvt = nvt,
        .i_sat = is_val * a_eff,
        .i_bd = ibd_val * a_eff,
        .has_bd = ibd_val > 0.0,
        .vbd = vbd,
        .g_rd = if (rd != 0.0) a_eff / rd else 1.0e12,
        .g_rs = if (rs != 0.0) a_eff / rs else 1.0e12,
        .vto = vto,
        .lfgam = lfgam,
        .lfg1 = lfg1,
        .lfg2 = lfg2,
        .vst = vst,
        .mvst = mvst,
        .mxi = mxi,
        .xi_woo = xi_woo,
        .za = za,
        .d3 = d3,
        .z_param = z_param,
        .p_exp = p_exp,
        .q_exp = q_exp,
        .beta = beta,
        .lam = lam,
        .delta = delta,
    };
}

// ============================================================================
// Gate Junction Diode (Forward + Breakdown), value-form
// ============================================================================
// Region selection on the exponent argument follows the ORIGINAL piecewise
// linearization; each branch is computed in S ops so the Jacobian tracks it.

/// Forward conduction: i = Is*(exp(v/nvt) - 1) + gmin*v, linearized above m_x
/// and saturated below f_x.
fn junctionFwd(comptime S: type, v: S, pp: DcParams) S {
    const arg = v.scale(1.0 / pp.nvt);
    const a = arg.val();
    if (a <= f_x) {
        // r1: -Is + gmin*v
        return v.scale(gmin).addC(-pp.i_sat);
    }
    if (a >= m_x) {
        // r3: Is*e^mx*(arg - m_x + 1) - Is + gmin*v
        return arg.addC(1.0 - m_x).scale(pp.i_sat * e_mx).addC(-pp.i_sat).add(v.scale(gmin));
    }
    // r2: Is*(exp(min(arg, m_x)) - 1) + gmin*v
    return arg.minC(m_x).exp().addC(-1.0).scale(pp.i_sat).add(v.scale(gmin));
}

/// Reverse breakdown: only active when ibd > 0 (parameter branch).
fn junctionRev(comptime S: type, v: S, pp: DcParams) S {
    if (!pp.has_bd) return S.con(0.0);
    const arg = v.scale(-1.0 / pp.vbd);
    const a = arg.val();
    if (a <= f_x) {
        // r1: constant Ibd (flat, matching original)
        return S.con(pp.i_bd);
    }
    if (a >= m_x) {
        // r3: -(Ibd*e^mx*(arg - m_x + 1) - Ibd)
        return arg.addC(1.0 - m_x).scale(-pp.i_bd * e_mx).addC(pp.i_bd);
    }
    // r2: -(Ibd*exp(min(arg, m_x)) - Ibd)
    return arg.minC(m_x).exp().addC(-1.0).scale(-pp.i_bd);
}

pub const PrepCache = struct { dc: DcParams, q: CapParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = dcParams(model, instance), .q = capParams(model, instance) };
}

// ============================================================================
// DC Current Function (eval)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const dr = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const sr = @intFromEnum(U.source);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const pp = &pc.dc;

    // --- Node voltages ---
    const v_d = x[dr];
    const v_g = x[g];
    const v_s = x[sr];
    const v_dp = x[dp];
    const v_sp = x[sp];

    // --- Junction voltages ---
    const vgs = v_g.sub(v_sp);
    const vgd = v_g.sub(v_dp);
    const vds = v_dp.sub(v_sp);

    // ========================================================================
    // Series Resistances
    // ========================================================================
    const i_rd = v_d.sub(v_dp).scale(pp.g_rd);
    const i_rs = v_s.sub(v_sp).scale(pp.g_rs);

    // ========================================================================
    // Gate-Source / Gate-Drain Junction Diodes (Forward + Breakdown)
    // ========================================================================
    const i_gs = junctionFwd(S, vgs, pp.*).add(junctionRev(S, vgs, pp.*));
    const i_gd = junctionFwd(S, vgd, pp.*).add(junctionRev(S, vgd, pp.*));

    // ========================================================================
    // Source-Drain Reversal
    // ========================================================================
    // Original branched on the sign of vds; region selection via .val().
    const reverse = vds.val() < 0.0;
    const vgs_arg = if (reverse) vgd else vgs;
    const vgd_arg = if (reverse) vgs else vgd;
    const vds_eff = vgs_arg.sub(vgd_arg); // always >= 0

    // ========================================================================
    // Drain Feedback on Threshold
    // ========================================================================
    // lfg_term = lfgam - lfg1*vgs_arg + lfg2*vgd_arg
    const lfg_term = vgs_arg.scale(-pp.lfg1).add(vgd_arg.scale(pp.lfg2)).addC(pp.lfgam);
    // v_gst = vgs_arg - vto - lfg_term*vgd_arg
    const v_gst = vgs_arg.addC(-pp.vto).sub(lfg_term.mul(vgd_arg));

    // ========================================================================
    // Subthreshold Conduction
    // ========================================================================
    const v_gt = blk: {
        if (pp.vst <= 0.0) {
            break :blk v_gst.maxC(0.0);
        }
        // vst_eff = vst * (1 + mvst*vds_eff)
        const vst_eff = vds_eff.scale(pp.vst * pp.mvst).addC(pp.vst);
        const arg_sub = v_gst.div(vst_eff);
        const arg_clamped = arg_sub.minC(m_x).maxC(f_x);
        // softplus: vst_eff * ln(1 + exp(arg))
        // For arg_clamped in [f_x, m_x] range, exp is safe
        break :blk vst_eff.mul(arg_clamped.exp().addC(1.0).log());
    };

    // ========================================================================
    // Core Parker-Skellern Drain Current
    // ========================================================================

    // Dual power-law drain voltage
    const v_gt_safe = v_gt.maxC(1e-30);
    // v_dp_ps = vds_eff * d3 * exp((p - q) * ln(v_gt_safe))
    const v_dp_ps = vds_eff.scale(pp.d3).mul(v_gt_safe.log().scale(pp.p_exp - pp.q_exp).exp());

    // Velocity saturation
    const v_sat_fac = v_gt.div(v_gt.scale(pp.mxi).addC(pp.xi_woo));
    const v_sat = v_gt.div(v_sat_fac.addC(1.0));

    // Smoothed drain saturation voltage
    const aa = v_dp_ps.scale(pp.za).add(v_sat.scale(0.5));
    const aaa = aa.sub(v_sat);
    const arg_sq = v_sat.mul(v_sat).scale(pp.z_param / 4.0);
    const rpt = aa.mul(aa).add(arg_sq).sqrt();
    const arpt = aaa.mul(aaa).add(arg_sq).sqrt();
    const v_dt = rpt.sub(arpt);

    // Intrinsic Q-law FET current
    // I = VDT * (VGT - VDT)^(Q-1) + VGT * [VGT^(Q-1) - (VGT - VDT)^(Q-1)]
    const vgt_minus_vdt = v_gt.sub(v_dt).maxC(1e-30);
    const q_minus_1 = pp.q_exp - 1.0;
    const vgt_qm1 = v_gt_safe.log().scale(q_minus_1).exp();
    const vgt_minus_vdt_qm1 = vgt_minus_vdt.log().scale(q_minus_1).exp();
    const i_drain_core = v_dt.mul(vgt_minus_vdt_qm1).add(v_gt.mul(vgt_qm1.sub(vgt_minus_vdt_qm1)));

    // Channel-length modulation
    const i_d_clm = i_drain_core.scale(pp.beta * pp.a_eff).mul(vds_eff.scale(pp.lam).addC(1.0));

    // Thermal current reduction (DC mode)
    const p_avg = vds_eff.mul(i_d_clm);
    const p_fac = p_avg.scale(pp.delta / pp.a_eff).addC(1.0);
    const i_d_thermal = i_d_clm.div(p_fac);

    // Final drain current with reversal
    const i_d_final = if (reverse) i_d_thermal.neg() else i_d_thermal;

    // GMIN convergence aid on Vds
    const i_gmin = vds.scale(gmin);

    // ========================================================================
    // KCL Node Currents
    // ========================================================================
    var out: [n_u]S = undefined;
    out[dr] = i_rd;
    out[g] = i_gs.add(i_gd);
    out[sr] = i_rs;
    out[dp] = i_rd.neg().add(i_d_final).sub(i_gd).add(i_gmin);
    out[sp] = i_rs.neg().sub(i_d_final).sub(i_gs).sub(i_gmin);
    return out;
}

// ============================================================================
// Charge parameter preprocessing (pure f64 -- nothing here depends on x)
// ============================================================================

const CapParams = struct {
    a_eff: f64,
    vto: f64,
    phi_b: f64,
    v_max: f64,
    alpha: f64,
    c_zgs: f64,
    c_zgd: f64,
    cds: f64,
    acgam: f64,
    xc: f64,
    qrt2: f64,
};

fn capParams(model: *const Model, instance: *const Instance) CapParams {
    // --- Cast model parameters to f64 ---
    const vto: f64 = @as(f64, model.vto);
    const xi: f64 = @as(f64, model.xi);
    const phi_b: f64 = @as(f64, model.pb);
    const fc: f64 = @as(f64, model.fc);
    const cgs0: f64 = @as(f64, model.cgs);
    const cgd0: f64 = @as(f64, model.cgd);
    const cds_val: f64 = @as(f64, model.cds);
    const acgam: f64 = @as(f64, model.acgam);
    const xc: f64 = @as(f64, model.xc);

    // --- Cast instance parameters to f64 ---
    const area: f64 = @as(f64, instance.area);
    const m_mult: f64 = @as(f64, instance.m);

    // --- Effective area ---
    const a_eff = area * m_mult;

    // --- Precomputed capacitance constants ---
    const woo = phi_b - vto;
    const alpha = (xi * woo) * (xi * woo) / (4.0 * (xi + 1.0) * (xi + 1.0));
    const v_max = fc * phi_b;

    return .{
        .a_eff = a_eff,
        .vto = vto,
        .phi_b = phi_b,
        .v_max = v_max,
        .alpha = alpha,
        .c_zgs = cgs0 * a_eff,
        .c_zgd = cgd0 * a_eff,
        .cds = cds_val,
        .acgam = acgam,
        .xc = xc,
        // qrt2 depends only on parameters
        .qrt2 = @sqrt(@max(1.0 - v_max / phi_b, 1e-30)),
    };
}

// ============================================================================
// Charge Function (q) -- Statz Capacitance Model
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const dr = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const sr = @intFromEnum(U.source);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const cp = &pc.q;

    // --- Node voltages ---
    const v_g = x[g];
    const v_dp = x[dp];
    const v_sp = x[sp];

    // --- Junction voltages ---
    const vgs_cap = v_g.sub(v_sp);
    const vgd_cap = v_g.sub(v_dp);
    const vds_cap = v_dp.sub(v_sp);

    // ========================================================================
    // Effective Gate Voltage
    // ========================================================================
    const v_ert = vds_cap.mul(vds_cap).addC(cp.alpha).sqrt();
    const v_eff = vgs_cap.add(vgd_cap).add(v_ert).scale(0.5).add(vds_cap.scale(cp.acgam));

    // ========================================================================
    // Pinch-off Smoothing
    // ========================================================================
    const v_nr = v_eff.addC(-cp.vto).scale(1.0 - cp.xc);
    const v_nrt = v_nr.mul(v_nr).addC(0.04).sqrt();
    const v_new = v_eff.add(v_nrt.sub(v_nr).scale(0.5));

    // ========================================================================
    // Capacitance Factor
    // ========================================================================
    // c_fac = 0.5 * (1 + xc + (1 - xc) * v_nr / v_nrt)
    const c_fac = v_nr.div(v_nrt).scale(0.5 * (1.0 - cp.xc)).addC(0.5 * (1.0 + cp.xc));

    // ========================================================================
    // Gate Charge -- Two Regions (original branched on v_new < v_max)
    // ========================================================================
    const in_depletion = v_new.val() < cp.v_max;

    var q_gg: S = undefined;
    var c_gso_eff: S = undefined;
    if (in_depletion) {
        // --- Region 1 (depletion): v_new < v_max ---
        const qrt1 = v_new.scale(-1.0 / cp.phi_b).addC(1.0).maxC(1e-30).sqrt();
        q_gg = qrt1.neg().addC(1.0).scale(cp.c_zgs * 2.0 * cp.phi_b)
            .add(v_eff.sub(v_ert).scale(cp.c_zgd));
        c_gso_eff = c_fac.div(qrt1);
    } else {
        // --- Region 2 (forward extension): v_new >= v_max ---
        const v_x = v_new.addC(-cp.v_max).scale(0.5);
        const par = v_x.scale(1.0 / (cp.phi_b - cp.v_max)).addC(1.0);
        const ext = v_x.mul(par.addC(1.0)).scale(1.0 / cp.qrt2);
        q_gg = ext.addC(2.0 * cp.phi_b * (1.0 - cp.qrt2)).scale(cp.c_zgs)
            .add(v_eff.sub(v_ert).scale(cp.c_zgd));
        c_gso_eff = c_fac.mul(par).scale(1.0 / cp.qrt2);
    }

    // ========================================================================
    // Capacitance Partitioning
    // ========================================================================
    const c_pm = vds_cap.div(v_ert);
    const c_plus = c_pm.addC(1.0).scale(0.5);
    const c_minus = c_pm.neg().addC(1.0).scale(0.5);

    const c_gs_total = c_gso_eff.mul(c_plus.addC(cp.acgam)).scale(cp.c_zgs)
        .add(c_minus.addC(cp.acgam).scale(cp.c_zgd));
    const c_gd_total = c_gso_eff.mul(c_minus.addC(-cp.acgam)).scale(cp.c_zgs)
        .add(c_plus.addC(-cp.acgam).scale(cp.c_zgd));

    // ========================================================================
    // Charge Partitioning
    // ========================================================================
    const c_tot_safe = c_gs_total.add(c_gd_total).maxC(1e-30);

    const q_gs = q_gg.mul(c_gs_total).div(c_tot_safe);
    const q_gd = q_gg.mul(c_gd_total).div(c_tot_safe);

    // ========================================================================
    // Drain-Source Capacitance
    // ========================================================================
    const q_ds = vds_cap.scale(cp.cds * cp.a_eff);

    // ========================================================================
    // KCL Charge Contributions
    // ========================================================================
    var out: [n_u]S = undefined;
    out[dr] = S.con(0.0);
    out[g] = q_gs.add(q_gd);
    out[sr] = S.con(0.0);
    out[dp] = q_gd.neg().add(q_ds);
    out[sp] = q_gs.neg().sub(q_ds);
    return out;
}

// ============================================================================
// Voltage Limiting (PN junction + FET limiting)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const vto: f64 = @as(f64, model.vto);
    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);

    const t_dev = temp + 273.15 + dtemp;
    const vt = kq * t_dev;
    const nvt = n_em * vt;

    // Critical voltage for PN junction limiting
    const v_crit = nvt * @log(nvt / (@sqrt(2.0) * is_val));

    var result = x_new;

    // --- PN junction limiting on VGS (G -- S') ---
    const vgs_new = x_new[g] - x_new[sp];
    const vgs_old = x_old[g] - x_old[sp];
    const vgs_lim = pnjlim(vgs_new, vgs_old, nvt, v_crit);

    // --- PN junction limiting on VGD (G -- D') ---
    const vgd_new = x_new[g] - x_new[dp];
    const vgd_old = x_old[g] - x_old[dp];
    const vgd_lim = pnjlim(vgd_new, vgd_old, nvt, v_crit);

    // Apply PN limiting corrections to gate node
    // We adjust the gate voltage to satisfy both limited junction voltages.
    // Use the average correction from both junctions.
    const delta_gs = vgs_lim - vgs_new;
    const delta_gd = vgd_lim - vgd_new;

    // Apply the gate correction (use the more restrictive one)
    const delta_g = if (@abs(delta_gs) > @abs(delta_gd)) delta_gs else delta_gd;
    result[g] = x_new[g] + delta_g;

    // Recompute limited junction voltages after gate correction
    const vgs_after = result[g] - result[sp];
    const vgd_after = result[g] - result[dp];

    // --- FET voltage limiting on VGS ---
    const vgs_fet = fetlim(vgs_after, vgs_old, vto);
    const delta_gs_fet = vgs_fet - vgs_after;

    // --- FET voltage limiting on VGD ---
    const vgd_fet = fetlim(vgd_after, vgd_old, vto);
    const delta_gd_fet = vgd_fet - vgd_after;

    // Apply FET limiting (use the more restrictive correction)
    const delta_g_fet = if (@abs(delta_gs_fet) > @abs(delta_gd_fet)) delta_gs_fet else delta_gd_fet;
    result[g] = result[g] + delta_g_fet;

    return result;
}

/// DEVpnjlim -- PN junction voltage limiting
fn pnjlim(v_new: f64, v_old: f64, nvt: f64, v_crit: f64) f64 {
    if (v_new > v_crit and @abs(v_new - v_old) > 2.0 * nvt) {
        if (v_old > 0.0) {
            const arg = (v_new - v_old) / nvt;
            if (arg > 2.0) {
                return v_old + nvt * (2.0 + @log(arg - 2.0));
            } else {
                return v_old + 2.0 * nvt;
            }
        } else {
            if (v_new > 0.0) {
                return nvt * @log(v_new / nvt);
            } else {
                return v_crit;
            }
        }
    }
    return v_new;
}

/// DEVfetlim -- FET gate voltage limiting
fn fetlim(v_new: f64, v_old: f64, vto: f64) f64 {
    const vtsthi = @abs(2.0 * (v_old - vto)) + 2.0;
    const vtstlo = vtsthi / 2.0 + 2.0;
    const vtox = vto + 3.5;
    const dv = v_new - v_old;

    if (v_old >= vto) {
        if (v_old >= vtox) {
            if (dv <= 0.0) {
                // Decreasing
                if (v_new >= vtox and -dv > vtsthi) {
                    return v_old - vtsthi;
                }
                if (v_new < vtox) {
                    return @max(v_new, vto + 2.0);
                }
            } else {
                // Increasing
                if (dv >= vtsthi) {
                    return v_old + vtsthi;
                }
            }
        } else {
            // vto <= v_old < vtox
            if (dv <= 0.0) {
                if (-dv > vtsthi) {
                    return v_old - vtsthi;
                }
            } else {
                if (dv >= vtstlo) {
                    return v_old + vtstlo;
                }
            }
        }
    } else {
        // v_old < vto (below threshold)
        if (dv <= 0.0) {
            if (-dv > vtsthi) {
                return v_old - vtsthi;
            }
        } else {
            if (dv >= vtstlo) {
                return v_old + vtstlo;
            }
        }
    }
    return v_new;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    // At lambda=0: IS boosted by gmin; at lambda=1: original IS
    const is_stepped = is_orig + gmin_step * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================
// Expected values below are computed from the ORIGINAL pointer-form i()/q()
// formulas evaluated in f64 (with model params first rounded through f32
// storage, exactly as the device does). Derivations are shown per test.

const testing = std.testing;

test "jfet2: on-state residual, vgs=0 vds=1, default params" {
    // x = {vd=1, vg=0, vs=0, vdp=1, vsp=0}; rd=rs=0 so resistor currents = 0.
    //
    // Hand trace through the original i():
    //   nvt   = 300.15 * 8.617333262145e-5 = 0.025864925786328215
    //   GS diode: arg = 0 -> region r2: is*(e^0 - 1) + gmin*0 = 0
    //   GD diode: arg = -1/nvt = -38.66 <= f_x -> r1:
    //             -is + gmin*(-1) = -(f32(1e-14)) - 1e-12 = -1.0099999998245167e-12
    //   Channel (forward, vds=1): v_gst = vgs - vto = 0 - (-2) = 2, v_gt = 2
    //   woo = pb - vto = 3, xi_woo = 3000, za = sqrt(2)/2, d3 = 1 (p = q = 2)
    //   v_dp_ps = 1 * 1 * exp(0) = 1
    //   v_sat = 2 / (1 + 2/3000) = 1.998667554963358
    //   aa    = 0.7071067811865476 + v_sat/2 = 1.7064405586682265
    //   aaa   = aa - v_sat = -0.2922269962951314
    //   arg_sq = v_sat^2/4 = 0.9986679988158018
    //   v_dt  = sqrt(aa^2+arg_sq) - sqrt(aaa^2+arg_sq)
    //         = 1.9775255697673624 - 1.0411842373852365 = 0.9363413323821259
    //   core  = v_dt*(v_gt-v_dt) + v_gt*(v_gt-(v_gt-v_dt)) = 2.868630238801369
    //   i_d   = core * f32(1e-4) = 2.8686301663336737e-4  (lambda=0, delta=0)
    //   out[dp] = i_d - i_gd + gmin*vds = 2.8686301864336739e-4
    //   out[sp] = -i_d - i_gs - gmin*vds = -2.8686301763336736e-4
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    try testing.expectApproxEqRel(@as(f64, -1.0099999998245167e-12), out[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqRel(@as(f64, 2.8686301864336739e-4), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -2.8686301763336736e-4), out[4], 1e-9);
}

test "jfet2: gate forward bias vg=0.6 exercises diode exp region" {
    // x = {1, 0.6, 0, 1, 0}: vgs = 0.6 -> arg = 0.6/nvt = 23.198 (region r2)
    //   i_gs = is*(exp(23.198) - 1) + gmin*0.6 = 1.18718...e-4
    //   vgd = -0.4 -> arg = -15.46 <= f_x -> i_gd = -is - 0.4e-12
    //   channel: v_gst = 0.6 + 2 = 2.6 -> traced through the same PS core.
    // Old-formula f64 reference values:
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.6, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    try testing.expectApproxEqRel(@as(f64, 1.1871869229867342e-4), out[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqRel(@as(f64, 4.0784292007311487e-4), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -5.265616123717883e-4), out[4], 1e-9);
}

test "jfet2: reverse vds swaps source/drain roles" {
    // x = {-1, 0, 0, -1, 0}: vds = -1 < 0 -> reverse mode; vgd = +1 puts the
    // GD diode deep in forward conduction: arg = 1/nvt = 38.66 (region r2),
    //   i_gd = is*(exp(38.66) - 1) - 1e-12 = 617.8245... A (regression value)
    // Channel runs with swapped vgs/vgd (v_gst = vgd - vto = 3) and the final
    // drain current is negated. Old-formula f64 reference values:
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -1.0, 0.0, 0.0, -1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    try testing.expectApproxEqRel(@as(f64, 617.82457283375663), out[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqRel(@as(f64, -617.82506149706853), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 4.8866331193116392e-4), out[4], 1e-9);
}

test "jfet2: series resistances carry ohmic drop" {
    // rd = rs = 10 ohm, x = {1, 0, 0, 0.9, 0.05}:
    //   i_rd = (1/10)*(1 - 0.9)  = 0.01
    //   i_rs = (1/10)*(0 - 0.05) = -0.005
    // Internal channel/diodes evaluated at vdp=0.9, vsp=0.05 (old formula):
    const model: Model = .{ .rd = 10, .rs = 10 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 0.9, 0.05 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, 0.01), out[0], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -9.6855303895755452e-13), out[1], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -0.005), out[2], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -9.7499520972735652e-3), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 4.749952098242121e-3), out[4], 1e-9);
}

test "jfet2: charge, depletion region" {
    // cgs = cgd = 1e-12, cds = 2e-12; x = {1, 0, 0, 1, 0}.
    // Hand trace through the original q():
    //   woo = 3, alpha = (3000)^2/(4*1001^2) = 2.2455067410112366
    //   v_ert = sqrt(1 + alpha)                = 1.8015290008798739
    //   v_eff = 0.5*(0 + (-1) + v_ert)         = 0.40076450043993694
    //   v_nr  = v_eff + 2                      = 2.400764500439937
    //   v_nrt = sqrt(v_nr^2 + 0.04)            = 2.409080776265632
    //   v_new = v_eff + 0.5*(v_nrt - v_nr)     = 0.4049226383527844 < v_max=0.5
    //   qrt1  = sqrt(1 - v_new)                = 0.771412575504973
    //   q_gg  = 2e-12*(1-qrt1) + 1e-12*(v_eff - v_ert) = -9.4358964767948476e-13
    //   c_fac = 0.5*(1 + v_nr/v_nrt), c_gso = c_fac/qrt1 = 1.2940856876435083
    //   c_pm  = 1/v_ert; partition ->
    //   q_gs = -5.053667449457666e-13, q_gd = -4.382229065041163e-13
    //   q_ds = 2e-12*1 = 2e-12
    //   out[g]  = q_gs + q_gd  = -9.4358964767948476e-13
    //   out[dp] = -q_gd + q_ds =  2.4382228967614584e-12
    //   out[sp] = -q_gs - q_ds = -1.4946332490819736e-12
    const model: Model = .{ .cgs = 1e-12, .cgd = 1e-12, .cds = 2e-12 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, 0.0, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -9.4358964767948476e-13), out[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-30);
    try testing.expectApproxEqRel(@as(f64, 2.4382228967614584e-12), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -1.4946332490819736e-12), out[4], 1e-9);
}

test "jfet2: charge, forward-extension region" {
    // vg = 0.8, vds = 0 -> v_ert = sqrt(alpha), v_eff = 0.8 + sqrt(alpha)/2,
    // v_new > v_max = 0.5 -> region 2 (forward extension of the Statz model).
    // vds = 0 makes the partition symmetric: q_gs = q_gd = q_gg/2.
    // Old-formula f64 reference values:
    const model: Model = .{ .cgs = 1e-12, .cgd = 1e-12, .cds = 2e-12 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.0, 0.8, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-30);
    try testing.expectApproxEqRel(@as(f64, 2.9070378159321497e-12), out[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -1.4535189079660749e-12), out[3], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -1.4535189079660749e-12), out[4], 1e-9);
}
