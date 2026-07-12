const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: Heterostructure FET Level 1
//
// Three-terminal FET for GaAs/AlGaAs HEMTs and similar III-V devices.
// External ports: drain, gate, source. No internal nodes.
//
// Equivalent circuit:
//   - Voltage-controlled channel current (drain-source) with DIBL,
//     subthreshold smoothing, velocity saturation, knee shaping
//   - Gate leakage diodes (gate-source, gate-drain): dual-exponential + GGR
//   - Nonlinear gate capacitances (Cgs, Cgd) via Meyer-like partition
//   - Parasitic drain-source capacitance Cds
//   - GMIN conditioning across all terminal pairs
// ============================================================================

pub const U = enum(u8) { drain, gate, source };
pub const num_ports: usize = 3;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- DC / Channel Parameters ---
    vt0: f32 = 0.15,
    lambda: f32 = 0.15,
    eta: f32 = 1.28,
    m: f32 = 3,
    mc: f32 = 3,
    gamma: f32 = 3,
    sigma0: f32 = 0.057,
    vsigmat: f32 = 0.3,
    vsigma: f32 = 0.1,
    mu: f32 = 0.4,
    di: f32 = 4e-08,
    delta: f32 = 3,
    vs: f32 = 150000,
    nmax: f32 = 2e+16,
    deltad: f32 = 4.5e-09,
    epsi: f32 = 1.08411e-10,
    p: f32 = 1,

    // --- Gate Leakage / Diode Parameters ---
    js1d: f32 = 1,
    js2d: f32 = 1.15e+06,
    js1s: f32 = 1,
    js2s: f32 = 1.15e+06,
    m1d: f32 = 1.32,
    m2d: f32 = 6.9,
    m1s: f32 = 1.32,
    m2s: f32 = 6.9,
    ggr: f32 = 40,
    del: f32 = 0.04,
    gatemod: i32 = 0,

    // --- Resistance Parameters ---
    rd: f32 = 0,
    rs: f32 = 0,
    rg: f32 = 0,
    rdi: f32 = 0,
    rsi: f32 = 0,
    rgs: f32 = 90,
    rgd: f32 = 90,
    ri: f32 = 0,
    rf: f32 = 0,

    // --- Capacitance Parameters ---
    cds: f32 = 0,
    eta1: f32 = 2,
    d1: f32 = 3e-08,
    vt1: f32 = 1.3323,
    eta2: f32 = 2,
    d2: f32 = 2e-07,
    vt2: f32 = 0.15,

    // --- Temperature Parameters ---
    tf: f32 = 300.15,
    klambda: f32 = 0,
    kmu: f32 = 0,
    kvto: f32 = 0,
    talpha: f32 = 1200,
    mt1: f32 = 3.5,
    mt2: f32 = 9.9,
    phib: f32 = 8.01088e-20,
    astar: f32 = 40000,

    // --- Miscellaneous Model Parameters ---
    cm3: f32 = 0.17,
    a1: f32 = 0,
    a2: f32 = 0,
    mv1: f32 = 3,
    kappa: f32 = 0,
    delf: f32 = 0,
    fgds: f32 = 0,
    ck1: f32 = 1,
    ck2: f32 = 0,
    cm1: f32 = 3,
    cm2: f32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 20e-6,
    l: f32 = 1e-6,
    temp: f32 = 300.15,
    m_mult: f32 = 1.0,
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: drain -- source
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .thermal },
    // Gate-source shot noise
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source), .kind = .shot },
    // Gate-drain shot noise
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain), .kind = .shot },
};

// ============================================================================
// Physical constants
// ============================================================================

const Q_ELECTRON: f64 = 1.602176634e-19;
const K_BOLTZMANN: f64 = 1.380649e-23;

// ============================================================================
// Parameter preprocessing (pure f64 -- no dependence on the unknowns x)
// ============================================================================

const Prep = struct {
    // Temperature-adjusted channel parameters
    vt0_t: f64,
    lambda_t: f64,
    vth_t: f64,
    // Derived channel constants
    n0: f64,
    g_chi0: f64,
    i_max: f64,
    v_l: f64,
    rsi: f64,
    r_t: f64,
    // DIBL / smoothing / knee constants
    sigma0: f64,
    vsigmat: f64,
    vsigma: f64,
    delta2: f64,
    gamma: f64,
    m_knee: f64,
    mc: f64,
    nmax: f64,
    m_mult: f64,
    // Gate leakage
    is1d: f64,
    is2d: f64,
    is1s: f64,
    is2s: f64,
    ggr_wl: f64,
    vt1_gs: f64,
    vt2_gs: f64,
    vt1_gd: f64,
    vt2_gd: f64,
    del: f64,
    // Capacitance model
    p_m: f64,
    cds: f64,
    c_f: f64,
    vt1_cap: f64,
    eta1_vth: f64,
    d1_over_epsi: f64,
    wl: f64,
};

/// All x-independent parameter and temperature preprocessing, hoisted out of
/// eval/q. Mirrors the prologue of the original pointer-form i()/q().
fn prep(model: *const Model, instance: *const Instance) Prep {
    // --- Cast model parameters to f64 ---
    const vt0: f64 = @as(f64, model.vt0);
    const lambda_m: f64 = @as(f64, model.lambda);
    const m_knee: f64 = @as(f64, model.m);
    const mc_m: f64 = @as(f64, model.mc);
    const gamma_m: f64 = @as(f64, model.gamma);
    const sigma0: f64 = @as(f64, model.sigma0);
    const vsigmat: f64 = @as(f64, model.vsigmat);
    const vsigma: f64 = @as(f64, model.vsigma);
    const mu_m: f64 = @as(f64, model.mu);
    const di_m: f64 = @as(f64, model.di);
    const delta_m: f64 = @as(f64, model.delta);
    const vs_m: f64 = @as(f64, model.vs);
    const nmax_m: f64 = @as(f64, model.nmax);
    const deltad_m: f64 = @as(f64, model.deltad);
    const epsi_m: f64 = @as(f64, model.epsi);
    const p_m: f64 = @as(f64, model.p);
    const cds_m: f64 = @as(f64, model.cds);

    // Gate leakage parameters
    const js1d: f64 = @as(f64, model.js1d);
    const js2d: f64 = @as(f64, model.js2d);
    const js1s: f64 = @as(f64, model.js1s);
    const js2s: f64 = @as(f64, model.js2s);
    const m1d: f64 = @as(f64, model.m1d);
    const m2d: f64 = @as(f64, model.m2d);
    const m1s: f64 = @as(f64, model.m1s);
    const m2s: f64 = @as(f64, model.m2s);
    const ggr_m: f64 = @as(f64, model.ggr);
    const del_m: f64 = @as(f64, model.del);

    // Gate capacitance model parameters
    const eta1: f64 = @as(f64, model.eta1);
    const d1_m: f64 = @as(f64, model.d1);
    const vt1: f64 = @as(f64, model.vt1);

    // Resistance parameters
    const rdi: f64 = @as(f64, model.rdi);
    const rsi: f64 = @as(f64, model.rsi);

    // Temperature parameters
    const tf: f64 = @as(f64, model.tf);
    const klambda: f64 = @as(f64, model.klambda);
    const kmu: f64 = @as(f64, model.kmu);
    const kvto: f64 = @as(f64, model.kvto);

    // --- Cast instance parameters to f64 ---
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const temp: f64 = @as(f64, instance.temp);
    const m_mult: f64 = @as(f64, instance.m_mult);

    // --- Temperature scaling ---
    const delta_t = temp - tf;
    const mu_t = mu_m + kmu * delta_t;
    const vt0_t = vt0 + kvto * delta_t;
    const lambda_t = lambda_m + klambda * delta_t;

    // --- Thermal voltage ---
    const vth_t = K_BOLTZMANN * temp / Q_ELECTRON;

    // --- Derived constants ---
    const d_eff = di_m + deltad_m;
    const n0 = epsi_m / (Q_ELECTRON * d_eff);
    const g_chi0 = 2.0 * Q_ELECTRON * w * mu_t / l;
    const i_max = Q_ELECTRON * nmax_m * vs_m * w;
    const v_l = (vs_m / mu_t) * l;
    const c_f = 0.5 * epsi_m * w;

    // --- Gate leakage diode scaling ---
    const area_half = w * l / 2.0;

    return .{
        .vt0_t = vt0_t,
        .lambda_t = lambda_t,
        .vth_t = vth_t,
        .n0 = n0,
        .g_chi0 = g_chi0,
        .i_max = i_max,
        .v_l = v_l,
        .rsi = rsi,
        .r_t = rsi + rdi,
        .sigma0 = sigma0,
        .vsigmat = vsigmat,
        .vsigma = vsigma,
        .delta2 = delta_m * delta_m,
        .gamma = gamma_m,
        .m_knee = m_knee,
        .mc = mc_m,
        .nmax = nmax_m,
        .m_mult = m_mult,
        .is1d = js1d * area_half,
        .is2d = js2d * area_half,
        .is1s = js1s * area_half,
        .is2s = js2s * area_half,
        .ggr_wl = ggr_m * area_half,
        .vt1_gs = vth_t * m1s,
        .vt2_gs = vth_t * m2s,
        .vt1_gd = vth_t * m1d,
        .vt2_gd = vth_t * m2d,
        .del = del_m,
        .p_m = p_m,
        .cds = cds_m,
        .c_f = c_f,
        .vt1_cap = vt1,
        .eta1_vth = eta1 * vth_t,
        .d1_over_epsi = d1_m / epsi_m,
        .wl = w * l,
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

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const pp = pc;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);

    // --- GMIN ---
    const gmin: f64 = 1.0e-12;

    // --- Terminal voltages ---
    const vds = x[d].sub(x[s]);
    const vgs = x[g].sub(x[s]);
    const vgd = x[g].sub(x[d]);

    // ========================================================================
    // Gate Leakage Current (gatemod = 0)
    // ========================================================================
    // Gate-source leakage:
    //   is1s*(exp(min(vgs/vt1_gs,80))-1) + is2s*(exp(min(vgs/vt2_gs,80))-1)
    //   + ggr_wl*exp(min(del*vgs,80))
    const igs_leak = vgs.scale(1.0 / pp.vt1_gs).minC(80.0).exp().addC(-1.0).scale(pp.is1s)
        .add(vgs.scale(1.0 / pp.vt2_gs).minC(80.0).exp().addC(-1.0).scale(pp.is2s))
        .add(vgs.scale(pp.del).minC(80.0).exp().scale(pp.ggr_wl));

    // Gate-drain leakage
    const igd_leak = vgd.scale(1.0 / pp.vt1_gd).minC(80.0).exp().addC(-1.0).scale(pp.is1d)
        .add(vgd.scale(1.0 / pp.vt2_gd).minC(80.0).exp().addC(-1.0).scale(pp.is2d))
        .add(vgd.scale(pp.del).minC(80.0).exp().scale(pp.ggr_wl));

    // ========================================================================
    // Channel Current -- Threshold and DIBL
    // ========================================================================
    // DIBL coefficient with smooth activation (clamp exp arg):
    //   sigma = sigma0 / (1 + exp(min((vds - vsigmat)/vsigma, 80)))
    const sigma = S.con(pp.sigma0)
        .div(vds.addC(-pp.vsigmat).scale(1.0 / pp.vsigma).minC(80.0).exp().addC(1.0));

    // Effective gate overdrive with DIBL: vgt = (vgs - vt0_t) + sigma*vds
    const vgt = vgs.addC(-pp.vt0_t).add(sigma.mul(vds));

    // ========================================================================
    // Channel Current -- Subthreshold Smoothing
    // ========================================================================
    // vgte = 0.5*(vgt + sqrt(vgt^2 + delta^2))
    const vgte = vgt.mul(vgt).addC(pp.delta2).sqrt().add(vgt).scale(0.5);

    // ========================================================================
    // Channel Current -- Sheet Charge and Saturation Limiting
    // ========================================================================
    const nsm = vgte.scale(pp.n0).maxC(1e-38);

    // Power-law saturation clamp at Nmax:
    //   c_pow = exp(gamma*log(max(nsm/nmax, 1e-38)))
    //   ns = nsm / exp((1/gamma)*log(1 + c_pow))
    const c_pow = nsm.scale(1.0 / pp.nmax).maxC(1e-38).log().scale(pp.gamma).exp();
    const ns = nsm.div(c_pow.addC(1.0).log().scale(1.0 / pp.gamma).exp());

    // ========================================================================
    // Channel Current -- Conductance and Velocity Saturation
    // ========================================================================
    const g_chi = ns.scale(pp.g_chi0);
    const g_ch = g_chi.div(g_chi.scale(pp.r_t).addC(1.0));

    const g_chim = nsm.scale(pp.g_chi0);
    // h = sqrt(1 + 2*g_chim*rsi + vgte^2/v_l^2)
    const h = g_chim.scale(2.0 * pp.rsi)
        .add(vgte.mul(vgte).scale(1.0 / (pp.v_l * pp.v_l))).addC(1.0).sqrt();
    const p_val = g_chim.scale(pp.rsi).add(h).addC(1.0);
    const isat_m = g_chim.mul(vgte).div(p_val);

    // Imax power-law clamp:
    //   gsat = exp(gamma*log(max(isat_m/i_max, 1e-38)))
    //   isat = isat_m / exp((1/gamma)*log(1 + gsat))
    const gsat = isat_m.scale(1.0 / pp.i_max).maxC(1e-38).log().scale(pp.gamma).exp();
    const isat = isat_m.div(gsat.addC(1.0).log().scale(1.0 / pp.gamma).exp());

    // Effective saturation voltage
    const vsat_e = isat.div(g_ch.maxC(1e-38));

    // ========================================================================
    // Channel Current -- Drain Current with Knee Shaping
    // ========================================================================
    const vds_over_vsat = vds.div(vsat_e.maxC(1e-38));
    const vds_over_vsat_smooth = vds_over_vsat.mul(vds_over_vsat).addC(1e-30).sqrt();
    const d_knee = vds_over_vsat_smooth.log().scale(pp.m_knee).exp();
    // i_drain = g_ch*vds*(1 + lambda_t*vds) / exp((1/m)*log(1 + d_knee))
    const i_drain = g_ch.mul(vds).mul(vds.scale(pp.lambda_t).addC(1.0))
        .div(d_knee.addC(1.0).log().scale(1.0 / pp.m_knee).exp());

    // ========================================================================
    // GMIN Conditioning
    // ========================================================================
    const i_gmin_ds = vds.scale(gmin);
    const i_gmin_gs = vgs.scale(gmin);
    const i_gmin_gd = vgd.scale(gmin);

    // ========================================================================
    // KCL Assembly
    // ========================================================================
    const i_gate = igs_leak.add(igd_leak).add(i_gmin_gs).add(i_gmin_gd).scale(pp.m_mult);
    const i_drain_total = i_drain.sub(igd_leak).add(i_gmin_ds).sub(i_gmin_gd).scale(pp.m_mult);
    const i_source = i_gate.add(i_drain_total).neg();

    var out: [n_u]S = undefined;
    out[d] = i_drain_total;
    out[g] = i_gate;
    out[s] = i_source;
    return out;
}

// ============================================================================
// Charge Function (q) -- Gate Capacitance (Meyer-like partition) + Cds
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const pp = pc;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);

    // --- Terminal voltages ---
    const vds = x[d].sub(x[s]);
    const vgs = x[g].sub(x[s]);
    const vgd = x[g].sub(x[d]);

    // ========================================================================
    // Recompute channel quantities needed for capacitance
    // ========================================================================

    // DIBL
    const sigma = S.con(pp.sigma0)
        .div(vds.addC(-pp.vsigmat).scale(1.0 / pp.vsigma).minC(80.0).exp().addC(1.0));

    // Gate overdrive
    const vgt = vgs.addC(-pp.vt0_t).add(sigma.mul(vds));

    // Subthreshold smoothing
    const vgte = vgt.mul(vgt).addC(pp.delta2).sqrt().add(vgt).scale(0.5);

    // Sheet charge
    const nsm = vgte.scale(pp.n0).maxC(1e-38);
    const c_pow = nsm.scale(1.0 / pp.nmax).maxC(1e-38).log().scale(pp.gamma).exp();
    const one_plus_c = c_pow.addC(1.0);
    const ns = nsm.div(one_plus_c.log().scale(1.0 / pp.gamma).exp());

    // Channel conductance for vsat_e computation
    const g_chi = ns.scale(pp.g_chi0);
    const g_ch = g_chi.div(g_chi.scale(pp.r_t).addC(1.0));

    const g_chim = nsm.scale(pp.g_chi0);
    const h = g_chim.scale(2.0 * pp.rsi)
        .add(vgte.mul(vgte).scale(1.0 / (pp.v_l * pp.v_l))).addC(1.0).sqrt();
    const p_val = g_chim.scale(pp.rsi).add(h).addC(1.0);
    const isat_m = g_chim.mul(vgte).div(p_val);

    const gsat = isat_m.scale(1.0 / pp.i_max).maxC(1e-38).log().scale(pp.gamma).exp();
    const isat = isat_m.div(gsat.addC(1.0).log().scale(1.0 / pp.gamma).exp());

    const vsat_e = isat.div(g_ch.maxC(1e-38));

    // ========================================================================
    // Charge Model -- Channel Capacitance Derivatives
    // ========================================================================

    // d(ns)/d(nsm) = (ns/max(nsm,1e-38)) * (1 - c_pow/(1 + c_pow))
    const dns_dnsm = ns.div(nsm.maxC(1e-38)).mul(c_pow.div(one_plus_c).neg().addC(1.0));

    // d(vgte)/d(vgt) = 0.5*(1 + vgt/sqrt(vgt^2 + delta^2))
    const dvgte_dvgt = vgt.div(vgt.mul(vgt).addC(pp.delta2).sqrt()).addC(1.0).scale(0.5);

    // d(nsm)/d(vgt)
    const dnsm_dvgt = dvgte_dvgt.scale(pp.n0);

    // d(vgt)/d(vgs) = 1 (sigma depends on vds, not vgs)
    // So d(ns)/d(vgs) = dns_dnsm * dnsm_dvgt * 1

    // ========================================================================
    // Charge Model -- Gate Capacitance (Cg1)
    // ========================================================================
    // exp_arg = min(-(vgs - vt1)/(eta1*vth), 80)
    // cg1 = 1 / (d1/epsi + eta1*vth*exp(exp_arg))
    const exp_arg_cg1 = vgs.addC(-pp.vt1_cap).scale(-1.0 / pp.eta1_vth).minC(80.0);
    const cg1 = S.con(1.0).div(exp_arg_cg1.exp().scale(pp.eta1_vth).addC(pp.d1_over_epsi));

    // ========================================================================
    // Charge Model -- Total Gate Channel Capacitance
    // ========================================================================
    // cgc = w*l*(q_e * dns_dnsm * dnsm_dvgt * 1 + cg1)
    const cgc = dns_dnsm.mul(dnsm_dvgt).scale(Q_ELECTRON).add(cg1).scale(pp.wl);

    // ========================================================================
    // Charge Model -- Saturation Voltage for Capacitance
    // ========================================================================
    const vds_over_vsat_c = vds.div(vsat_e.maxC(1e-38));
    const vds_over_vsat_smooth_c = vds_over_vsat_c.mul(vds_over_vsat_c).addC(1e-30).sqrt();
    const d_knee_c = vds_over_vsat_smooth_c.log().scale(pp.mc).exp();
    const vds_e = vds.div(d_knee_c.addC(1.0).log().scale(1.0 / pp.mc).exp());

    // ========================================================================
    // Charge Model -- Meyer-like Capacitance Partition
    // ========================================================================
    const two_vsat_minus_vdse = vsat_e.scale(2.0).sub(vds_e).addC(1e-30);
    const r_gs = vsat_e.sub(vds_e).div(two_vsat_minus_vdse);
    const alpha_gs = r_gs.mul(r_gs);
    const r_gd = vsat_e.div(two_vsat_minus_vdse);
    const alpha_gd = r_gd.mul(r_gd);

    // Partition weighting factor:
    //   p_part = p + (1-p)*exp(min(-vds/max(vsat_e,1e-38), 80))
    const p_part = vds.div(vsat_e.maxC(1e-38)).neg().minC(80.0).exp()
        .scale(1.0 - pp.p_m).addC(pp.p_m);

    // ========================================================================
    // Charge Model -- Terminal Capacitances
    // ========================================================================
    const one_plus_ppart = p_part.addC(1.0);
    // c_gs = c_f + (4/3)*cgc*(1 - alpha_gs)/(1 + p_part)
    const c_gs = cgc.mul(alpha_gs.neg().addC(1.0)).scale(4.0 / 3.0)
        .div(one_plus_ppart).addC(pp.c_f);
    // c_gd = c_f + (4/3)*p_part*cgc*(1 - alpha_gd)/(1 + p_part)
    const c_gd = p_part.mul(cgc).mul(alpha_gd.neg().addC(1.0)).scale(4.0 / 3.0)
        .div(one_plus_ppart).addC(pp.c_f);

    // ========================================================================
    // Charge Model -- Terminal Charges
    // ========================================================================
    const q_gs = c_gs.mul(vgs);
    const q_gd = c_gd.mul(vgd);
    const q_ds = vds.scale(pp.cds);

    const q_gate = q_gs.add(q_gd).scale(pp.m_mult);
    const q_drain = q_gd.neg().add(q_ds).scale(pp.m_mult);
    const q_source = q_gs.neg().sub(q_ds).scale(pp.m_mult);

    var out: [n_u]S = undefined;
    out[d] = q_drain;
    out[g] = q_gate;
    out[s] = q_source;
    return out;
}

// ============================================================================
// Voltage Limiting (fetlim on Vgs + limvds on Vds)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);

    const vt0: f64 = @as(f64, model.vt0);

    var result = x_new;

    // ========================================================================
    // FET Voltage Limiter (fetlim) on V_GS
    // ========================================================================
    {
        const vt: f64 = 0.026;
        const vthr = vt0 + vt;
        const vtstep = 2.0 * vt;

        const vgs_new = x_new[g] - x_new[s];
        const vgs_old = x_old[g] - x_old[s];

        var vgs_lim = vgs_new;

        if (vgs_new > vgs_old) {
            if (vgs_old >= vthr) {
                // Clamp upward step
                vgs_lim = @min(vgs_new, vgs_old + vtstep);
            } else {
                // Clamp to threshold
                vgs_lim = @min(vgs_new, vthr);
            }
        } else if (vgs_new < vgs_old) {
            if (vgs_old >= vthr) {
                // Clamp downward step
                vgs_lim = @max(vgs_new, vgs_old - vtstep);
            }
            // else: no limiting
        }

        // Apply delta to gate node
        const delta_gs = vgs_lim - vgs_new;
        result[g] += delta_gs;
    }

    // ========================================================================
    // Drain-Source Voltage Limiter (limvds) on V_DS
    // ========================================================================
    {
        const vds_new = result[d] - result[s];
        const vds_old = x_old[d] - x_old[s];

        var vds_lim = vds_new;

        if (vds_old >= 3.5) {
            // Large V_DS_old region
            if (vds_new - vds_old > 2.0 * (vds_old + 1.0)) {
                // Upward step clamped
                vds_lim = 3.0 * vds_old + 2.0;
            } else if (vds_new < 3.5) {
                // Downward clamped to floor
                vds_lim = 3.5;
            }
        } else {
            // Small V_DS_old region
            if (vds_new > 4.0) {
                // Upward clamped to ceiling
                vds_lim = 4.0;
            }
        }

        // Apply delta to drain node
        const delta_vds = vds_lim - vds_new;
        result[d] += delta_vds;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// Ramp gate leakage saturation current densities from small (easy) to model
// values. At lambda=0: use minimum floor; at lambda=1: use model values.

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;

    const js1d_orig: f64 = @as(f64, model.js1d);
    const js2d_orig: f64 = @as(f64, model.js2d);
    const js1s_orig: f64 = @as(f64, model.js1s);
    const js2s_orig: f64 = @as(f64, model.js2s);

    const scale = 1.0 - lambda;

    m.js1d = @floatCast(js1d_orig + gmin_step * scale);
    m.js2d = @floatCast(js2d_orig + gmin_step * scale);
    m.js1s = @floatCast(js1s_orig + gmin_step * scale);
    m.js2s = @floatCast(js2s_orig + gmin_step * scale);

    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
//
// Expected values are physics regressions captured from the ORIGINAL
// pointer-form i()/q() implementation (pre-migration), evaluated at default
// Model{}/Instance{} parameters via a standalone harness printed at 17
// significant digits. Tolerances are relative 1e-9 to absorb the
// division-vs-reciprocal-scale reassociation permitted by
// @setFloatMode(.optimized); expected values themselves are unchanged.
// ============================================================================

const testing = std.testing;

fn expectRel(expected: f64, actual: f64) !void {
    try testing.expectApproxEqRel(expected, actual, 1e-9);
}

test "hfet1: on-state currents (vd=2.0, vg=0.5, vs=0)" {
    // Old-code reference at x = {2.0, 0.5, 0.0}:
    //   i_drain  =  1.20578720972509650e-2
    //   i_gate   =  1.89341899285658980e-4
    //   i_source = -1.22472139965366240e-2
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 2.0, 0.5, 0.0 }, &model, &inst, 0);
    try expectRel(1.20578720972509650e-2, out[@intFromEnum(U.drain)]);
    try expectRel(1.89341899285658980e-4, out[@intFromEnum(U.gate)]);
    try expectRel(-1.22472139965366240e-2, out[@intFromEnum(U.source)]);
    // KCL: currents sum to zero
    try testing.expectApproxEqAbs(0.0, out[0] + out[1] + out[2], 1e-18);
}

test "hfet1: subthreshold-region currents (vd=1.0, vg=-0.5, vs=0)" {
    // Old-code reference at x = {1.0, -0.5, 0.0}:
    //   i_drain  =  9.85542258984513000e-3
    //   i_gate   = -2.22984974648795300e-5
    //   i_source = -9.83312409238025100e-3
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, -0.5, 0.0 }, &model, &inst, 0);
    try expectRel(9.85542258984513000e-3, out[@intFromEnum(U.drain)]);
    try expectRel(-2.22984974648795300e-5, out[@intFromEnum(U.gate)]);
    try expectRel(-9.83312409238025100e-3, out[@intFromEnum(U.source)]);
}

test "hfet1: reverse-vds currents exercise gate-drain leakage exponentials" {
    // Old-code reference at x = {-1.0, 0.5, 0.0} (vgd = 1.5 forward-biases the
    // gate-drain diode; dominated by is1d*exp(vgd/(vth*m1d))):
    //   i_drain  = -1.20372765268705170e8
    //   i_gate   =  1.20372765261068970e8
    //   i_source =  7.63620436191558800e-3
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -1.0, 0.5, 0.0 }, &model, &inst, 0);
    try expectRel(-1.20372765268705170e8, out[@intFromEnum(U.drain)]);
    try expectRel(1.20372765261068970e8, out[@intFromEnum(U.gate)]);
    try expectRel(7.63620436191558800e-3, out[@intFromEnum(U.source)]);
}

test "hfet1: on-state charges (vd=2.0, vg=0.5, vs=0)" {
    // Old-code reference at x = {2.0, 0.5, 0.0}:
    //   q_drain  =  1.63055344988024560e-15
    //   q_gate   =  9.26869535096026200e-16
    //   q_source = -2.55742298497627180e-15
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 2.0, 0.5, 0.0 }, &model, &inst, 0);
    try expectRel(1.63055344988024560e-15, out[@intFromEnum(U.drain)]);
    try expectRel(9.26869535096026200e-16, out[@intFromEnum(U.gate)]);
    try expectRel(-2.55742298497627180e-15, out[@intFromEnum(U.source)]);
}

test "hfet1: subthreshold charges (vd=1.0, vg=-0.5, vs=0)" {
    // Old-code reference at x = {1.0, -0.5, 0.0}:
    //   q_drain  =  1.68925257978342960e-15
    //   q_gate   = -5.20265155689942950e-15
    //   q_source =  3.51339897711600030e-15
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, -0.5, 0.0 }, &model, &inst, 0);
    try expectRel(1.68925257978342960e-15, out[@intFromEnum(U.drain)]);
    try expectRel(-5.20265155689942950e-15, out[@intFromEnum(U.gate)]);
    try expectRel(3.51339897711600030e-15, out[@intFromEnum(U.source)]);
}
