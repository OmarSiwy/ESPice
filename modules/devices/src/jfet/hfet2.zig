const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: D -- Rd -- D' --[channel]-- S' -- Rs -- S
//           G --[Schottky diode]-- D'
//           G --[Schottky diode]-- S'
//           G --[Cgd]-- D'
//           G --[Cgs]-- S'
// ============================================================================

pub const U = enum(u8) { drain, gate, source, drain_prime, source_prime };
pub const num_ports: usize = 3;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- DC: Transconductance & Channel ---
    vt0: f32 = 0.15,
    lambda: f32 = 0.15,
    mu: f32 = 0.4,
    nmax: f32 = 2e16,
    eta: f32 = 1.28,
    vs: f32 = 1.5e5,
    sigma0: f32 = 0.057,
    vsigma: f32 = 0.1,
    vsigmat: f32 = 0.3,
    gamma: f32 = 3,
    m: f32 = 3,
    mc: f32 = 3,
    delta: f32 = 3,
    n: f32 = 5,
    p: f32 = 1,
    del: f32 = 0.04,

    // --- Parasitics & Junction ---
    rd: f32 = 0,
    rs: f32 = 0,
    rdi: f32 = 0,
    rsi: f32 = 0,
    js: f32 = 0,
    ggr: f32 = 0,

    // --- Capacitance ---
    cf: f32 = 0,
    d1: f32 = 3e-8,
    d2: f32 = 2e-7,
    di: f32 = 4e-8,
    deltad: f32 = 4.5e-9,
    epsi: f32 = 1.084e-10,
    eta1: f32 = 2,
    eta2: f32 = 2,
    vt1: f32 = 1.3323,
    vt2: f32 = 0.15,

    // --- Temperature Coefficients ---
    kvto: f32 = 0,
    klambda: f32 = 0,
    kmu: f32 = 0,
    knmax: f32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 20e-6,
    l: f32 = 1e-6,
    temp: f32 = 300.15,
    dtemp: f32 = 0,
    m: f32 = 1,
    type_nfet: i32 = 1,
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

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Q_GS: G -- S'   and  Q_GD: G -- D'

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
    // Gate-source shot noise (Schottky): G -- S'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Gate-drain shot noise (Schottky): G -- D'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain_prime), .kind = .shot },
};

// ============================================================================
// x-independent parameter preprocessing (pure f64 — shared by eval and q)
// ============================================================================

// --- Physical constants ---
const q_e: f64 = 1.60217663e-19;
const kq: f64 = 8.617333262145e-5; // k/q in V/K
const tnom: f64 = 300.15;

/// Temperature-adjusted parameters and derived geometry/charge quantities.
/// None of this depends on x.
const Prep = struct {
    type_f: f64,
    m_mult: f64,
    vt: f64,
    vt0_eff: f64,
    lam_eff: f64,
    nmax_eff: f64,
    g_dpar: f64,
    g_spar: f64,
    n0: f64,
    n02: f64,
    gchi0: f64,
    imax: f64,
    js_lw: f64,
    ggr_lw: f64,
    vl: f64,
    use_two_layer: bool,
    w: f64,
    l: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    // --- Cast model parameters to f64 ---
    const vt0: f64 = @as(f64, model.vt0);
    const lam: f64 = @as(f64, model.lambda);
    const mu: f64 = @as(f64, model.mu);
    const nmax_p: f64 = @as(f64, model.nmax);
    const eta: f64 = @as(f64, model.eta);
    const v_sat_vel: f64 = @as(f64, model.vs);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const js: f64 = @as(f64, model.js);
    const ggr: f64 = @as(f64, model.ggr);
    const di: f64 = @as(f64, model.di);
    const deltad: f64 = @as(f64, model.deltad);
    const epsi: f64 = @as(f64, model.epsi);
    const eta2: f64 = @as(f64, model.eta2);
    const d2: f64 = @as(f64, model.d2);
    const kvto: f64 = @as(f64, model.kvto);
    const klambda: f64 = @as(f64, model.klambda);
    const kmu: f64 = @as(f64, model.kmu);
    const knmax: f64 = @as(f64, model.knmax);

    // --- Cast instance parameters to f64 ---
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const m_mult: f64 = @as(f64, instance.m);
    const type_f: f64 = @floatFromInt(instance.type_nfet);

    // --- Temperature-adjusted parameters ---
    const t_dev = temp + dtemp;
    const dt_nom = t_dev - tnom;
    const vt0_eff = type_f * vt0 - kvto * dt_nom;
    const lam_eff = lam + klambda * dt_nom;
    const mu_eff = mu - kmu * dt_nom;
    const nmax_eff = nmax_p - knmax * dt_nom;
    const vt = kq * t_dev;

    // --- Derived quantities ---
    const g_dpar: f64 = if (rd != 0.0) 1.0 / rd else 1.0e12;
    const g_spar: f64 = if (rs != 0.0) 1.0 / rs else 1.0e12;

    const n0 = epsi * eta * vt / (2.0 * q_e * (di + deltad));
    const n02: f64 = if (d2 != 0.0) epsi * eta2 * vt / (2.0 * q_e * d2) else 0.0;

    const gchi0 = q_e * w * mu_eff / l;
    const imax = q_e * w * v_sat_vel * nmax_eff;
    const js_lw = js * w * l / 2.0;
    const ggr_lw = ggr * w * l / 2.0;
    const vl = v_sat_vel / mu_eff * l;

    const use_two_layer = (eta2 != 0.0 and d2 != 0.0);

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .vt = vt,
        .vt0_eff = vt0_eff,
        .lam_eff = lam_eff,
        .nmax_eff = nmax_eff,
        .g_dpar = g_dpar,
        .g_spar = g_spar,
        .n0 = n0,
        .n02 = n02,
        .gchi0 = gchi0,
        .imax = imax,
        .js_lw = js_lw,
        .ggr_lw = ggr_lw,
        .vl = vl,
        .use_two_layer = use_two_layer,
        .w = w,
        .l = l,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// DC Current Function (eval)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const dr = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const sr = @intFromEnum(U.source);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const pr = pc;

    // --- Remaining x-independent model parameters (f64) ---
    const eta: f64 = @as(f64, model.eta);
    const sigma0: f64 = @as(f64, model.sigma0);
    const vsigma: f64 = @as(f64, model.vsigma);
    const vsigmat: f64 = @as(f64, model.vsigmat);
    const gamma: f64 = @as(f64, model.gamma);
    const m_knee: f64 = @as(f64, model.m);
    const delta: f64 = @as(f64, model.delta);
    const n_diode: f64 = @as(f64, model.n);
    const del: f64 = @as(f64, model.del);
    const rdi: f64 = @as(f64, model.rdi);
    const rsi: f64 = @as(f64, model.rsi);
    const eta2: f64 = @as(f64, model.eta2);
    const vt2: f64 = @as(f64, model.vt2);

    const gmin: f64 = 1.0e-12;

    // --- Node voltages (S) ---
    const v_d = x[dr];
    const v_g = x[g];
    const v_s = x[sr];
    const v_dp = x[dp];
    const v_sp = x[sp];

    // --- Terminal voltages (pre-swap, raw) ---
    const vgs_raw = v_g.sub(v_sp).scale(pr.type_f);
    const vgd_raw = v_g.sub(v_dp).scale(pr.type_f);
    const vds_raw = vgs_raw.sub(vgd_raw);
    const vds = vds_raw.abs().maxC(1.0e-30);

    // Source/drain reversal (region select on voltage sign, as in original)
    const reversed = vds_raw.val() < 0.0;
    const vgs_eff = if (reversed) vgd_raw else vgs_raw;

    // ========================================================================
    // Parasitic Resistance Currents
    // ========================================================================
    const i_rd = v_d.sub(v_dp).scale(pr.g_dpar);
    const i_rs = v_s.sub(v_sp).scale(pr.g_spar);

    // ========================================================================
    // Gate Junction Currents (Schottky Diode) -- pre-swap voltages
    // ========================================================================
    const vtn = n_diode * pr.vt;

    // Gate-source diode
    const igs_exp_arg = vgs_raw.scale(1.0 / vtn).minC(80.0);
    const igs_leak_arg = vgs_raw.scale(-del / pr.vt).minC(80.0);
    const i_gs = igs_exp_arg.exp().addC(-1.0).scale(pr.js_lw)
        .add(vgs_raw.mul(igs_leak_arg.exp()).scale(pr.ggr_lw));

    // Gate-drain diode
    const igd_exp_arg = vgd_raw.scale(1.0 / vtn).minC(80.0);
    const igd_leak_arg = vgd_raw.scale(-del / pr.vt).minC(80.0);
    const i_gd = igd_exp_arg.exp().addC(-1.0).scale(pr.js_lw)
        .add(vgd_raw.mul(igd_leak_arg.exp()).scale(pr.ggr_lw));

    // Total gate current
    const i_gate = i_gs.add(i_gd);

    // ========================================================================
    // Channel Current -- Core HFET2 Equations
    // ========================================================================

    // DIBL-adjusted threshold
    const sigma_arg = vgs_eff.addC(-pr.vt0_eff).addC(-vsigmat).scale(1.0 / vsigma).minC(80.0);
    const sigma = S.con(sigma0).div(sigma_arg.exp().addC(1.0));

    // Effective gate overdrive with DIBL
    const vgt0 = vgs_eff.addC(-pr.vt0_eff);
    const vgt = vgt0.add(sigma.mul(vds));

    // Subthreshold smoothing (soft turn-on)
    const u_sub = vgt.scale(1.0 / (2.0 * pr.vt)).addC(-1.0);
    const t_sub = u_sub.mul(u_sub).addC(delta * delta).sqrt();
    const vgte = u_sub.add(t_sub).addC(2.0).scale(pr.vt);

    // Charge density b-factor
    const b = vgt.scale(1.0 / (eta * pr.vt)).minC(80.0).exp();

    // Sheet charge density n_sm
    const nsn = b.scale(0.5).addC(1.0).log().scale(2.0 * pr.n0);

    const nsc_arg = vgt.addC(pr.vt0_eff).addC(-vt2).scale(1.0 / (eta2 * pr.vt + 1.0e-30)).minC(80.0);
    const nsc = nsc_arg.exp().scale(pr.n02);
    // Two-layer: harmonic mean; single-layer: just nsn
    const nsm_raw = if (pr.use_two_layer) nsn.mul(nsc).div(nsn.add(nsc).addC(1.0e-30)) else nsn;

    // Safe floor on n_sm
    const nsm_safe = nsm_raw.mul(nsm_raw).addC(1.0e-76).sqrt();

    // Charge saturation (hard clamp at Nmax)
    const nsm_over_nmax = nsm_safe.scale(1.0 / @max(pr.nmax_eff, 1.0e-30));
    const c_sat = nsm_over_nmax.maxC(1.0e-30).log().scale(gamma).exp();
    const qsat = c_sat.addC(1.0).log().scale(1.0 / gamma).exp();
    const ns = nsm_safe.div(qsat);

    // Channel conductance
    const gchii = ns.scale(pr.gchi0);
    const gch = gchii.div(gchii.scale(rsi + rdi).addC(1.0));

    // Saturation current (velocity saturation limited)
    const gchiim = nsm_safe.scale(pr.gchi0);
    const h_val = gchiim.scale(2.0 * rsi).add(vgte.mul(vgte).scale(1.0 / (pr.vl * pr.vl))).addC(1.0).sqrt();
    const p_val = gchiim.scale(rsi).add(h_val).addC(1.0);
    const isat_m = gchiim.mul(vgte).div(p_val);

    // Imax clamp
    const gclamp = isat_m.scale(1.0 / @max(pr.imax, 1.0e-30)).maxC(1.0e-30).log().scale(gamma).exp();
    const isat = isat_m.div(gclamp.addC(1.0).log().scale(1.0 / gamma).exp());

    // Effective saturation voltage
    const vsat_e = isat.div(gch.maxC(1.0e-30));

    // Drain current with knee smoothing and CLM
    const vds_over_vsate = vds.div(vsat_e.maxC(1.0e-30));
    const d_knee = vds_over_vsate.maxC(1.0e-30).log().scale(m_knee).exp();
    const e_knee = d_knee.addC(1.0).log().scale(1.0 / m_knee).exp();
    const i_drain = gch.mul(vds).mul(vds.scale(pr.lam_eff).addC(1.0)).div(e_knee);

    // Source/drain reversal sign
    const i_drain_signed = if (reversed) i_drain.neg() else i_drain;

    // Type and multiplier
    const i_drain_final = i_drain_signed.scale(pr.type_f * pr.m_mult);

    // ========================================================================
    // GMIN Convergence Aid
    // ========================================================================
    const i_gmin = v_dp.sub(v_sp).scale(gmin);

    // ========================================================================
    // KCL Node Stamps
    // ========================================================================
    const tm = pr.type_f * pr.m_mult;
    var out: [n_u]S = undefined;
    out[dr] = i_rd.neg();
    out[g] = i_gate.scale(tm);
    out[sr] = i_rs.neg();
    out[dp] = i_rd.add(i_drain_final).sub(i_gd.scale(tm)).add(i_gmin);
    out[sp] = i_rs.sub(i_drain_final).sub(i_gate.sub(i_gd).scale(tm)).sub(i_gmin);
    return out;
}

// ============================================================================
// Charge Function (q) -- HFET2 Capacitance Model
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const dr = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const sr = @intFromEnum(U.source);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const pr = pc;

    // --- Remaining x-independent model parameters (f64) ---
    const eta: f64 = @as(f64, model.eta);
    const sigma0: f64 = @as(f64, model.sigma0);
    const vsigma: f64 = @as(f64, model.vsigma);
    const vsigmat: f64 = @as(f64, model.vsigmat);
    const gamma: f64 = @as(f64, model.gamma);
    const mc: f64 = @as(f64, model.mc);
    const delta: f64 = @as(f64, model.delta);
    const p_cap_exp: f64 = @as(f64, model.p);
    const rdi: f64 = @as(f64, model.rdi);
    const rsi: f64 = @as(f64, model.rsi);
    const cf: f64 = @as(f64, model.cf);
    const d1: f64 = @as(f64, model.d1);
    const epsi: f64 = @as(f64, model.epsi);
    const eta1: f64 = @as(f64, model.eta1);
    const eta2: f64 = @as(f64, model.eta2);
    const vt1: f64 = @as(f64, model.vt1);
    const vt2: f64 = @as(f64, model.vt2);

    // --- Node voltages (S) ---
    const v_g = x[g];
    const v_dp = x[dp];
    const v_sp = x[sp];

    // --- Terminal voltages (post-swap, same equations as DC) ---
    const vgs_raw = v_g.sub(v_sp).scale(pr.type_f);
    const vgd_raw = v_g.sub(v_dp).scale(pr.type_f);
    const vds_raw = vgs_raw.sub(vgd_raw);
    const vds_abs = vds_raw.abs().maxC(1.0e-30);

    const reversed = vds_raw.val() < 0.0;
    const vgs_eff = if (reversed) vgd_raw else vgs_raw;

    // ========================================================================
    // Recompute channel quantities identically to DC section
    // ========================================================================

    // DIBL-adjusted threshold
    const sigma_arg = vgs_eff.addC(-pr.vt0_eff).addC(-vsigmat).scale(1.0 / vsigma).minC(80.0);
    const sigma = S.con(sigma0).div(sigma_arg.exp().addC(1.0));

    // Effective gate overdrive with DIBL
    const vgt0 = vgs_eff.addC(-pr.vt0_eff);
    const vgt = vgt0.add(sigma.mul(vds_abs));

    // Subthreshold smoothing
    const u_sub = vgt.scale(1.0 / (2.0 * pr.vt)).addC(-1.0);
    const t_sub = u_sub.mul(u_sub).addC(delta * delta).sqrt();
    const vgte = u_sub.add(t_sub).addC(2.0).scale(pr.vt);

    // Charge density b-factor
    const b = vgt.scale(1.0 / (eta * pr.vt)).minC(80.0).exp();

    // Sheet charge density
    const nsn = b.scale(0.5).addC(1.0).log().scale(2.0 * pr.n0);

    const nsc_arg = vgt.addC(pr.vt0_eff).addC(-vt2).scale(1.0 / (eta2 * pr.vt + 1.0e-30)).minC(80.0);
    const nsc = nsc_arg.exp().scale(pr.n02);
    const nsm_raw = if (pr.use_two_layer) nsn.mul(nsc).div(nsn.add(nsc).addC(1.0e-30)) else nsn;
    const nsm_safe = nsm_raw.mul(nsm_raw).addC(1.0e-76).sqrt();

    // Charge saturation
    const nsm_over_nmax = nsm_safe.scale(1.0 / @max(pr.nmax_eff, 1.0e-30));
    const c_sat = nsm_over_nmax.maxC(1.0e-30).log().scale(gamma).exp();
    const qsat = c_sat.addC(1.0).log().scale(1.0 / gamma).exp();
    const ns = nsm_safe.div(qsat);

    // Channel conductance
    const gchii = ns.scale(pr.gchi0);
    const gch = gchii.div(gchii.scale(rsi + rdi).addC(1.0));

    // Saturation current
    const gchiim = nsm_safe.scale(pr.gchi0);
    const h_val = gchiim.scale(2.0 * rsi).add(vgte.mul(vgte).scale(1.0 / (pr.vl * pr.vl))).addC(1.0).sqrt();
    const p_val = gchiim.scale(rsi).add(h_val).addC(1.0);
    const isat_m = gchiim.mul(vgte).div(p_val);

    // Imax clamp
    const gclamp = isat_m.scale(1.0 / @max(pr.imax, 1.0e-30)).maxC(1.0e-30).log().scale(gamma).exp();
    const isat = isat_m.div(gclamp.addC(1.0).log().scale(1.0 / gamma).exp());

    // Effective saturation voltage
    const vsat_e = isat.div(gch.maxC(1.0e-30));

    // ========================================================================
    // Derivative of saturated charge w.r.t. unsaturated charge
    // ========================================================================
    const c_over_1pc = c_sat.div(c_sat.addC(1.0));
    const dns_dnsm = ns.div(nsm_safe.maxC(1.0e-30)).mul(c_over_1pc.neg().addC(1.0));

    // ========================================================================
    // Derivative of sheet charge w.r.t. gate overdrive
    // ========================================================================
    const inv_b = S.con(1.0).div(b.maxC(1.0e-30));
    const dnsm_dvgt_base = S.con(1.0).div(inv_b.addC(0.5)).scale(pr.n0 / (eta * pr.vt));

    const dnsm_dvgt = if (pr.use_two_layer) blk: {
        const nsc_safe = nsc.maxC(1.0e-30);
        const sum = nsc.add(nsn);
        const sum_sq_safe = sum.mul(sum).maxC(1.0e-30);
        break :blk nsc_safe.mul(nsc_safe.mul(dnsm_dvgt_base).add(nsn.mul(nsn).scale(1.0 / (eta2 * pr.vt)))).div(sum_sq_safe);
    } else dnsm_dvgt_base;

    // ========================================================================
    // Derivative of V_GT w.r.t. V_GS (DIBL effect)
    // ========================================================================
    const s_exp_arg = vgt0.addC(-vsigmat).scale(1.0 / vsigma).minC(80.0);
    const s_exp = s_exp_arg.exp();
    const one_p_s = s_exp.addC(1.0);
    const dvgt_dvgs = vds_abs.scale(sigma0 / vsigma).mul(s_exp).div(one_p_s.mul(one_p_s)).neg().addC(1.0);

    // ========================================================================
    // First-layer parasitic capacitance C_g1
    // ========================================================================
    const cg1_exp_arg = vgs_eff.addC(-vt1).scale(-1.0 / (eta1 * pr.vt)).minC(80.0);
    const cg1 = S.con(1.0).div(cg1_exp_arg.exp().scale(eta1 * pr.vt).addC(d1 / epsi));

    // ========================================================================
    // Total intrinsic gate capacitance
    // ========================================================================
    const cgc = dns_dnsm.mul(dnsm_dvgt).mul(dvgt_dvgs).scale(q_e).add(cg1).scale(pr.w * pr.l);

    // ========================================================================
    // Effective drain-source voltage for capacitance partition
    // ========================================================================
    const vds_over_vsate = vds_abs.div(vsat_e.maxC(1.0e-30));
    const vdse_inner = vds_over_vsate.maxC(1.0e-30).log().scale(mc).exp();
    const vdse = vds_abs.mul(vdse_inner.addC(1.0).log().scale(-1.0 / mc).exp());

    // ========================================================================
    // Ward-Dutton capacitance partition
    // ========================================================================
    const two_vsate_minus_vdse = vsat_e.scale(2.0).sub(vdse);
    const den = two_vsate_minus_vdse.maxC(1.0e-30);
    const den_sq = den.mul(den);
    const alpha_gs_base = vsat_e.sub(vdse);
    const alpha_gs = alpha_gs_base.mul(alpha_gs_base).div(den_sq);
    const alpha_gd = vsat_e.mul(vsat_e).div(den_sq);

    // ========================================================================
    // Partition blending factor
    // ========================================================================
    const pcap = vds_abs.div(vsat_e.maxC(1.0e-30)).neg().exp().scale(1.0 - p_cap_exp).addC(p_cap_exp);

    // ========================================================================
    // Terminal capacitances
    // ========================================================================
    const inv_1p_pcap = S.con(1.0).div(pcap.addC(1.0));
    const cgs_val = cgc.mul(alpha_gs.neg().addC(1.0)).mul(inv_1p_pcap).scale(4.0 / 3.0).addC(cf);
    const cgd_val = pcap.mul(cgc).mul(alpha_gd.neg().addC(1.0)).mul(inv_1p_pcap).scale(4.0 / 3.0).addC(cf);

    // Source/drain reversal for capacitances
    const cgs_eff = if (reversed) cgd_val else cgs_val;
    const cgd_eff = if (reversed) cgs_val else cgd_val;

    // ========================================================================
    // Charge Stamps (unsigned terminal voltages)
    // ========================================================================
    const vgs_unsigned = v_g.sub(v_sp);
    const vgd_unsigned = v_g.sub(v_dp);

    const q_gs = cgs_eff.mul(vgs_unsigned).scale(pr.m_mult);
    const q_gd = cgd_eff.mul(vgd_unsigned).scale(pr.m_mult);

    // ========================================================================
    // Node charge contributions (KCL for displacement current dQ/dt)
    // ========================================================================
    var out: [n_u]S = undefined;
    out[dr] = S.con(0.0);
    out[g] = q_gs.add(q_gd);
    out[sr] = S.con(0.0);
    out[dp] = q_gd.neg();
    out[sp] = q_gs.neg();
    return out;
}

// ============================================================================
// Voltage Limiting -- fetlim (Gate Voltages) + limvds (Drain-Source)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const vt0_val: f64 = @as(f64, model.vt0);

    var result = x_new;

    // --- FET voltage limiting on VGS (G -- S') ---
    const vgs_new = x_new[g] - x_new[sp];
    const vgs_old = x_old[g] - x_old[sp];
    const vgs_lim = fetlim(vgs_new, vgs_old, vt0_val);
    const delta_gs = vgs_lim - vgs_new;

    // --- FET voltage limiting on VGD (G -- D') ---
    const vgd_new = x_new[g] - x_new[dp];
    const vgd_old = x_old[g] - x_old[dp];
    const vgd_lim = fetlim(vgd_new, vgd_old, vt0_val);
    const delta_gd = vgd_lim - vgd_new;

    // Apply the more restrictive gate correction
    const delta_g = if (@abs(delta_gs) > @abs(delta_gd)) delta_gs else delta_gd;
    result[g] = x_new[g] + delta_g;

    // --- limvds on VDS (D' -- S') ---
    const vds_new_raw = x_new[dp] - x_new[sp];
    const vds_old_val = x_old[dp] - x_old[sp];
    const vds_lim = limvds(vds_new_raw, vds_old_val);
    const delta_vds = vds_lim - vds_new_raw;

    // Apply VDS limiting symmetrically to D' and S'
    result[dp] = result[dp] + delta_vds * 0.5;
    result[sp] = result[sp] - delta_vds * 0.5;

    return result;
}

/// DEVfetlim -- FET gate voltage limiting
fn fetlim(v_new: f64, v_old: f64, vto: f64) f64 {
    const vtox = vto + 3.5;
    const vtsthi = @abs(2.0 * (v_old - vto)) + 2.0;
    const vtstlo = vtsthi / 2.0 + 2.0;
    const dv = v_new - v_old;

    if (v_old >= vto) {
        if (v_old >= vtox) {
            if (dv <= 0.0) {
                return @max(v_new, v_old - vtstlo);
            } else {
                return @min(v_new, v_old + vtsthi);
            }
        } else {
            if (dv <= 0.0) {
                return @max(v_new, vto - 0.5);
            } else {
                return @min(v_new, v_old + vtsthi);
            }
        }
    } else {
        if (dv <= 0.0) {
            return @max(v_new, v_old - vtstlo);
        } else {
            return @min(v_new, vto + 0.5);
        }
    }
}

/// DEVlimvds -- Drain-source voltage limiting
fn limvds(v_new: f64, v_old: f64) f64 {
    const dv = v_new - v_old;
    if (v_old >= 3.5) {
        if (dv <= 0.0) {
            return @max(v_new, -0.5 * v_old);
        } else {
            return @min(v_new, 2.0 * v_old);
        }
    } else {
        if (v_new > 4.0) {
            return 4.0;
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
    const js_orig: f64 = @as(f64, model.js);
    // At lambda=0: JS boosted by gmin; at lambda=1: original JS
    const js_stepped = js_orig + gmin_step * (1.0 - lambda);
    m.js = @floatCast(js_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================
// Expected values below were produced by evaluating the ORIGINAL pointer-form
// i()/q() (verbatim old formulas, f32 param storage) at the given bias points.
// Hand-checkable anchors, defaults w=20u l=1u, T=300.15K:
//   vt   = 8.617333262145e-5 * 300.15 = 2.58649e-2 V
//   vtn  = n*vt = 5 * 2.58649e-2 = 1.29325e-1 V
// Forward case (vgs=0.5, vds=1):
//   i_rd = i_rs = 0 (v_d==v_dp, v_s==v_sp), i_gate = 0 (js=ggr=0),
//   i_gmin = 1e-12*(1-0) = 1e-12, channel current ~1.1888 mA.
// Reverse case (model rd=2, rs=3, js=1e5, ggr=1e-3):
//   i_rd = (0-0.05)/2 = -2.5e-2  ->  out[drain] = +2.5e-2
//   i_rs = (1-0.9)/3 = 3.3333e-2 ->  out[source] = -3.3333e-2
//   js_lw = 1e5*20e-6*1e-6/2 = 1e-6; vgd=0.35 -> i_gd ~ 1e-6*(e^(0.35/0.129325)-1)
//   ~ 1.400e-5; vgs=-0.5 -> i_gs ~ -9.8e-7; i_gate ~ 1.300e-5.

const testing = std.testing;

fn expectClose(expected: f64, actual: f64) !void {
    if (expected == 0.0) {
        try testing.expectApproxEqAbs(expected, actual, 1e-300);
    } else {
        try testing.expectApproxEqRel(expected, actual, 1e-12);
    }
}

test "hfet2 eval: forward on-state (default model, vgs=0.5, vds=1)" {
    const model: Model = .{};
    const inst: Instance = .{};
    // x = { d, g, s, d', s' }; d==d' and s==s' so parasitic currents vanish
    const x = [n_u]f64{ 1.0, 0.5, 0.0, 1.0, 0.0 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    try expectClose(0.0, out[@intFromEnum(U.drain)]);
    try expectClose(0.0, out[@intFromEnum(U.gate)]);
    try expectClose(0.0, out[@intFromEnum(U.source)]);
    try expectClose(1.1887914556517395e-3, out[@intFromEnum(U.drain_prime)]);
    try expectClose(-1.1887914556517395e-3, out[@intFromEnum(U.source_prime)]);
}

test "hfet2 eval: reversed channel with parasitics and Schottky gate" {
    const model: Model = .{ .rd = 2.0, .rs = 3.0, .js = 1e5, .ggr = 1e-3 };
    const inst: Instance = .{};
    // vds_raw = v_d' - v_s' = 0.05 - 0.9 = -0.85 < 0  -> reversed branch
    const x = [n_u]f64{ 0.0, 0.4, 1.0, 0.05, 0.9 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    try expectClose(2.5e-2, out[@intFromEnum(U.drain)]);
    try expectClose(1.299572127567556e-5, out[@intFromEnum(U.gate)]);
    try expectClose(-3.3333333333333326e-2, out[@intFromEnum(U.source)]);
    try expectClose(-2.5412383923504995e-2, out[@intFromEnum(U.drain_prime)]);
    try expectClose(3.373272153556264e-2, out[@intFromEnum(U.source_prime)]);
    // KCL: node residuals of a floating device sum to ~0
    var sum: f64 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "hfet2 q: forward-bias gate charge" {
    const model: Model = .{};
    const inst: Instance = .{};
    const x = [n_u]f64{ 1.0, 0.5, 0.0, 1.0, 0.0 };
    const out = contract.qValues(Self, x, &model, &inst, 0);
    try expectClose(0.0, out[@intFromEnum(U.drain)]);
    try expectClose(1.6451022664929078e-14, out[@intFromEnum(U.gate)]);
    try expectClose(0.0, out[@intFromEnum(U.source)]);
    try expectClose(4.5052004587079753e-17, out[@intFromEnum(U.drain_prime)]);
    try expectClose(-1.6496074669516157e-14, out[@intFromEnum(U.source_prime)]);
}

test "hfet2 q: reversed-channel capacitance swap" {
    const model: Model = .{ .rd = 2.0, .rs = 3.0, .js = 1e5, .ggr = 1e-3 };
    const inst: Instance = .{};
    const x = [n_u]f64{ 0.0, 0.4, 1.0, 0.05, 0.9 };
    const out = contract.qValues(Self, x, &model, &inst, 0);
    try expectClose(0.0, out[@intFromEnum(U.drain)]);
    try expectClose(1.377919509894681e-14, out[@intFromEnum(U.gate)]);
    try expectClose(0.0, out[@intFromEnum(U.source)]);
    try expectClose(-1.3814958356302472e-14, out[@intFromEnum(U.drain_prime)]);
    try expectClose(3.576325735566307e-17, out[@intFromEnum(U.source_prime)]);
}
