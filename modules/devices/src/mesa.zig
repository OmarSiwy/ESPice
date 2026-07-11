const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: MESA GaAs MESFET -- 3-terminal (Drain, Gate, Source)
//
//   D -- RD -- d' (drain_prime)
//   G -- RG -- g' (gate_prime)
//   S -- RS -- s' (source_prime)
//
// Intrinsic device between primed nodes:
//   - Two Schottky gate diodes: g'-s', g'-d'
//   - Voltage-controlled channel current: d'-s'
//   - Nonlinear gate-channel capacitances with Ward-Dutton partitioning
//
// Supports model levels 2, 3, 4 (single-layer, delta-doped, carrier-concentration)
// ============================================================================

pub const U = enum(u8) { drain, gate, source, drain_prime, gate_prime, source_prime };
pub const num_ports: usize = 3;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- DC Model Parameters ---
    vto: f32 = -1.26,
    lambda: f32 = 0.045,
    lambdahf: f32 = 0.045,
    beta: f32 = 0.0085,
    vs: f32 = 1.5e5,
    n: f32 = 1,
    eta: f32 = 1.73,
    m: f32 = 2.5,
    mc: f32 = 3,
    alpha: f32 = 0,
    sigma0: f32 = 0.081,
    vsigmat: f32 = 1.01,
    vsigma: f32 = 0.1,
    mu: f32 = 0.23,
    theta: f32 = 0,
    mu1: f32 = 0,
    mu2: f32 = 0,
    delta: f32 = 5,
    tc: f32 = 0,
    zeta: f32 = 1,
    level: i32 = 2,
    nmax: f32 = 2e16,
    gamma: f32 = 3,

    // --- Schottky Gate Diode Parameters ---
    phib: f32 = 0.5,
    phib1: f32 = 0,
    astar: f32 = 4.0e4,
    ggr: f32 = 40,
    del: f32 = 0.04,
    xchi: f32 = 0.033,

    // --- Resistance Parameters ---
    rd: f32 = 0,
    rs: f32 = 0,
    rg: f32 = 0,
    ri: f32 = 0,
    rf: f32 = 0,
    rdi: f32 = 0,
    rsi: f32 = 0,

    // --- Device Geometry Parameters ---
    d: f32 = 1.2e-7,
    nd: f32 = 2e23,
    du: f32 = 3.5e-8,
    ndu: f32 = 1e22,
    th: f32 = 1e-8,
    ndelta: f32 = 6e24,
    epsi: f32 = 1.08411e-10,

    // --- Capacitance Parameters ---
    cas: f32 = 1,
    cbs: f32 = 1,

    // --- Temperature Parameters ---
    tvto: f32 = 0,
    tlambda: f32 = std_inf,
    teta0: f32 = std_inf,
    teta1: f32 = 0,
    tmu: f32 = 300.15,
    xtm0: f32 = 0,
    xtm1: f32 = 0,
    xtm2: f32 = 0,
    rtc1: f32 = 0,
    rtc2: f32 = 0,
    tf: f32 = 300.15,

    // --- Noise Parameters ---
    flo: f32 = 0,
    delfo: f32 = 0,
    ag: f32 = 0,

    // --- Sidegating Parameters ---
    ks: f32 = 0,
    vsg: f32 = 0,

    const std_inf: f32 = @bitCast(@as(u32, 0x7f800000)); // +inf
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 20e-6,
    l: f32 = 1e-6,
    m: f32 = 1.0,
    temp: f32 = 300.15,
    dtemp: f32 = 0,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// RD branch: drain -- drain_prime
// RG branch: gate -- gate_prime
// RS branch: source -- source_prime
// Gate junction GS: gate_prime -- source_prime
// Gate junction GD: gate_prime -- drain_prime
// Channel: drain_prime -- source_prime

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: drain -- drain_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain) },
    // RG branch: gate -- gate_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate) },
    // RS branch: source -- source_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source) },
    // Gate junction GD: gate_prime -- drain_prime
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate_prime) },
    // Gate junction GS: gate_prime -- source_prime
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate_prime) },
    // Channel + self-terms on drain_prime and source_prime
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Charge Q_GS on gate_prime -- source_prime, Q_GD on gate_prime -- drain_prime

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Q_GD: gate_prime -- drain_prime
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    // Q_GS: gate_prime -- source_prime
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // 1. Drain resistance thermal noise: drain_prime -- source_prime
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // 2. Source resistance thermal noise: source_prime -- drain_prime
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // 3. Drain current shot noise: drain_prime -- source_prime
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // 4. 1/f flicker noise: drain_prime -- source_prime
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
};

// ============================================================================
// Physical Constants
// ============================================================================

const K_OVER_Q: f64 = 8.617333e-5; // V/K
const Q_CHARGE: f64 = 1.602176634e-19; // C
const K_BOLTZ: f64 = 1.380649e-23; // J/K
const EPS_GAAS: f64 = 12.244 * 8.85418e-12; // F/m
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const EPS_SMOOTH: f64 = 1.0e-6;
const F64_INF: f64 = @bitCast(@as(u64, 0x7FF0000000000000));

// ============================================================================
// x-independent parameter / temperature preprocessing (pure f64, no x)
// Everything here depends only on Model + Instance, so it is computed once in
// plain f64 and fed as constants into the S-valued physics tail.
// ============================================================================

const Prep = struct {
    // temperatures / thermal voltages
    t_s: f64,
    vts: f64,
    vtes: f64,
    vted: f64,
    // temperature-adjusted params
    mu_t: f64,
    vto_t: f64,
    lambda_t: f64,
    eta_t: f64,
    // series conductances
    g_rd: f64,
    g_rs: f64,
    g_rg: f64,
    // diode saturation / recombination scales
    isat_fs: f64,
    isat_fd: f64,
    ggr_wl: f64,
    // model scalars used in the S tail
    del: f64,
    vsigmat: f64,
    vsigma: f64,
    sigma0: f64,
    delta: f64,
    theta_p: f64,
    tc: f64,
    zeta: f64,
    level: i32,
    nmax: f64,
    gamma_p: f64,
    m_knee: f64,
    mc: f64,
    alpha_p: f64,
    vs: f64,
    mu: f64,
    // geometry
    d_ch: f64,
    nd: f64,
    du: f64,
    ndu: f64,
    th: f64,
    ndelta: f64,
    epsi: f64,
    rdi: f64,
    rsi: f64,
    cas: f64,
    cbs: f64,
    // instance
    w: f64,
    l: f64,
    m_mult: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    // --- Cast model parameters to f64 ---
    const vto: f64 = @as(f64, model.vto);
    const lambda: f64 = @as(f64, model.lambda);
    const vs: f64 = @as(f64, model.vs);
    const n_em: f64 = @as(f64, model.n);
    const eta: f64 = @as(f64, model.eta);
    const mu: f64 = @as(f64, model.mu);
    const theta_p: f64 = @as(f64, model.theta);
    const phib: f64 = @as(f64, model.phib);
    const astar: f64 = @as(f64, model.astar);
    const ggr: f64 = @as(f64, model.ggr);
    const rd_m: f64 = @as(f64, model.rd);
    const rs_m: f64 = @as(f64, model.rs);
    const rg_m: f64 = @as(f64, model.rg);
    const tvto: f64 = @as(f64, model.tvto);
    const tlambda: f64 = @as(f64, model.tlambda);
    const teta0: f64 = @as(f64, model.teta0);
    const teta1: f64 = @as(f64, model.teta1);
    const tmu: f64 = @as(f64, model.tmu);
    const xtm0: f64 = @as(f64, model.xtm0);
    const rtc1: f64 = @as(f64, model.rtc1);
    const rtc2: f64 = @as(f64, model.rtc2);

    // --- Cast instance parameters to f64 ---
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const m_mult: f64 = @as(f64, instance.m);
    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);

    // --- Device temperature ---
    const t_s = temp + dtemp;
    const t_d = t_s; // Source and drain temperatures assumed equal

    // --- Thermal voltages ---
    const vts = K_OVER_Q * t_s;
    const vtd = K_OVER_Q * t_d;
    const vtes = n_em * vts;
    const vted = n_em * vtd;

    // --- Temperature-adjusted parameters ---
    // Mobility: mu_T = mu * (Ts / Tmu)^xtm0
    const mu_t: f64 = if (xtm0 == 0.0) mu else mu * contract.fmath.exp(xtm0 * contract.fmath.log(t_s / tmu));

    // Threshold voltage: Vto_T = Vto - tvto * (Ts - 300.15)
    const vto_t = vto - tvto * (t_s - 300.15);

    // Output conductance: lambda_T = lambda * (1 - Ts/tlambda)
    // When tlambda = +inf, lambda_T = lambda
    const lambda_t: f64 = if (tlambda == F64_INF) lambda else lambda * (1.0 - t_s / tlambda);

    // Subthreshold ideality: eta_T = eta*(1 + Ts/teta0) + teta1/Ts
    // When teta0 = +inf, simplifies to eta + teta1/Ts
    const eta_t: f64 = if (teta0 == F64_INF) eta + teta1 / t_s else eta * (1.0 + t_s / teta0) + teta1 / t_s;

    // --- Resistance temperature adjustment ---
    const dt_r = t_s - 300.15;
    const r_factor = 1.0 + rtc1 * dt_r + rtc2 * dt_r * dt_r;

    // --- Series resistance conductances ---
    const g_rd: f64 = if (rd_m != 0.0) 1.0 / (rd_m * r_factor) else GSHORT;
    const g_rs: f64 = if (rs_m != 0.0) 1.0 / (rs_m * r_factor) else GSHORT;
    const g_rg: f64 = if (rg_m != 0.0) 1.0 / (rg_m * r_factor) else GSHORT;

    // --- Schottky Gate Diode saturation / recombination scales ---
    // Saturation currents: Isat = 0.5 * A* * T^2 * exp(-phib*q / (kB*T)) * W * L
    const isat_fs = 0.5 * astar * t_s * t_s * contract.fmath.exp(@min(-phib * Q_CHARGE / (K_BOLTZ * t_s), 80.0)) * w * l;
    const isat_fd = 0.5 * astar * t_d * t_d * contract.fmath.exp(@min(-phib * Q_CHARGE / (K_BOLTZ * t_d), 80.0)) * w * l;
    const ggr_wl = ggr * w * l;

    return .{
        .t_s = t_s,
        .vts = vts,
        .vtes = vtes,
        .vted = vted,
        .mu_t = mu_t,
        .vto_t = vto_t,
        .lambda_t = lambda_t,
        .eta_t = eta_t,
        .g_rd = g_rd,
        .g_rs = g_rs,
        .g_rg = g_rg,
        .isat_fs = isat_fs,
        .isat_fd = isat_fd,
        .ggr_wl = ggr_wl,
        .del = @as(f64, model.del),
        .vsigmat = @as(f64, model.vsigmat),
        .vsigma = @as(f64, model.vsigma),
        .sigma0 = @as(f64, model.sigma0),
        .delta = @as(f64, model.delta),
        .theta_p = theta_p,
        .tc = @as(f64, model.tc),
        .zeta = @as(f64, model.zeta),
        .level = model.level,
        .nmax = @as(f64, model.nmax),
        .gamma_p = @as(f64, model.gamma),
        .m_knee = @as(f64, model.m),
        .mc = @as(f64, model.mc),
        .alpha_p = @as(f64, model.alpha),
        .vs = vs,
        .mu = mu,
        .d_ch = @as(f64, model.d),
        .nd = @as(f64, model.nd),
        .du = @as(f64, model.du),
        .ndu = @as(f64, model.ndu),
        .th = @as(f64, model.th),
        .ndelta = @as(f64, model.ndelta),
        .epsi = @as(f64, model.epsi),
        .rdi = @as(f64, model.rdi),
        .rsi = @as(f64, model.rsi),
        .cas = @as(f64, model.cas),
        .cbs = @as(f64, model.cbs),
        .w = w,
        .l = l,
        .m_mult = m_mult,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// DC Current Function (eval) -- value-form, generic over scalar S
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;
    _ = model;
    _ = instance;

    const dr = @intFromEnum(U.drain);
    const ga = @intFromEnum(U.gate);
    const sr = @intFromEnum(U.source);
    const dp = @intFromEnum(U.drain_prime);
    const gp = @intFromEnum(U.gate_prime);
    const sp = @intFromEnum(U.source_prime);

    const p = pc;

    // hoist frequently used f64 scalars
    const vts = p.vts;
    const vtes = p.vtes;
    const vted = p.vted;
    const eta_t = p.eta_t;
    const rsi = p.rsi;
    const rdi = p.rdi;
    const zeta = p.zeta;
    const w = p.w;
    const l = p.l;
    const d_ch = p.d_ch;
    const nd = p.nd;
    const vs = p.vs;
    const lambda_t = p.lambda_t;

    // --- Terminal voltages (x reads) ---
    const v_drain = x[dr];
    const v_gate = x[ga];
    const v_source = x[sr];
    const v_dp = x[dp];
    const v_gp = x[gp];
    const v_sp = x[sp];

    // Intrinsic voltages (at primed nodes)
    const vgs_int = v_gp.sub(v_sp);
    const vgd_int = v_gp.sub(v_dp);
    const vds_int = v_dp.sub(v_sp);

    // --- Schottky Gate Diode Currents ---
    // Source-side gate diode current
    // i_gs = m*(isat_fs*(exp(min(vgs/vtes,80))-1) + ggr_wl*vgs*exp(min(-vgs*del/vts,80)) + GMIN*vgs)
    const i_gs = blk: {
        const e_term = vgs_int.scale(1.0 / vtes).minC(80.0).exp().addC(-1.0).scale(p.isat_fs);
        const rec_term = vgs_int.mul(vgs_int.scale(-p.del / vts).minC(80.0).exp()).scale(p.ggr_wl);
        const gmin_term = vgs_int.scale(GMIN);
        break :blk e_term.add(rec_term).add(gmin_term).scale(p.m_mult);
    };

    // Drain-side gate diode current
    const i_gd = blk: {
        const e_term = vgd_int.scale(1.0 / vted).minC(80.0).exp().addC(-1.0).scale(p.isat_fd);
        // vtd == vts in this model (source/drain temperatures equal)
        const rec_term = vgd_int.mul(vgd_int.scale(-p.del / vts).minC(80.0).exp()).scale(p.ggr_wl);
        const gmin_term = vgd_int.scale(GMIN);
        break :blk e_term.add(rec_term).add(gmin_term).scale(p.m_mult);
    };

    // --- Inverse mode handling (smooth blending) ---
    // vds_abs = sqrt(vds^2 + eps); blend = 0.5*(1 + vds/vds_abs)
    const vds_abs = vds_int.mul(vds_int).addC(EPS_SMOOTH).sqrt();
    const blend = vds_int.div(vds_abs).addC(1.0).scale(0.5);
    const one_minus_blend = blend.neg().addC(1.0);

    // Effective gate-source voltage
    const vgs_eff = blend.mul(vgs_int).add(one_minus_blend.mul(vgd_int));

    // --- DIBL / Sigma Correction ---
    // v_on = vto_t (f64 const)
    const vgt0 = vgs_eff.addC(-p.vto_t);
    // sigma = sigma0 / (1 + exp(min((vgt0 - vsigmat)/vsigma, 80)))
    const sigma = S.con(p.sigma0).div(vgt0.addC(-p.vsigmat).scale(1.0 / p.vsigma).minC(80.0).exp().addC(1.0));
    const vgt = vgt0.add(sigma.mul(vds_abs));

    // ========================================================================
    // Common: Subthreshold transition (smoothed Vgte)
    // ========================================================================

    // Level 2/3 smoothed transition
    // u_23 = vgt/vts - 1; t_23 = sqrt(delta^2 + u_23^2); vgte_23 = (vts/2)*(2 + u_23 + t_23)
    const u_23 = vgt.scale(1.0 / vts).addC(-1.0);
    const t_23 = u_23.mul(u_23).addC(p.delta * p.delta).sqrt();
    const vgte_23 = u_23.add(t_23).addC(2.0).scale(vts / 2.0);

    // Level 4 smoothed transition
    const u_4 = vgt.scale(1.0 / (2.0 * vts)).addC(-1.0);
    const t_4 = u_4.mul(u_4).addC(p.delta * p.delta).sqrt();
    const vgte_4 = u_4.add(t_4).addC(2.0).scale(vts);

    // ========================================================================
    // Level 2: Single-layer MESFET
    // ========================================================================

    // Pinch-off voltage
    const vpo_2 = Q_CHARGE * nd * d_ch * d_ch / (2.0 * EPS_GAAS);

    // Pre-computed beta
    const beta_pre_2 = 2.0 * EPS_GAAS * vs * zeta * w / d_ch;

    // Subthreshold carrier concentration scale
    const n0_2 = EPS_GAAS * eta_t * vts / (Q_CHARGE * d_ch);

    // Saturation current scale
    const isatb0_2 = Q_CHARGE * n0_2 * vts * w / l;

    // Channel conductance prefactor (Level 2: gchi0 = q*W/L)
    const gchi0_2 = Q_CHARGE * w / l;

    // Mobility with modulation (Level 2 only): mu_eff = mu_t + theta*vgt  (S)
    const mu_eff_2 = vgt.scale(p.theta_p).addC(p.mu_t);

    // Saturation voltage parameter: vl = vs/(mu_eff + 1e-30)*l  (S)
    const vl_2 = S.con(vs * l).div(mu_eff_2.addC(1e-30));

    // Beta: beta = beta_pre/(vpo + 3*vl)  (S)
    const beta_2 = S.con(beta_pre_2).div(vl_2.scale(3.0).addC(vpo_2));

    // Acceleration parameter: a = 2*beta*vgte_23
    const a_2 = beta_2.mul(vgte_23).scale(2.0);

    // Subthreshold factor (for carrier density): b_sub = exp(min(-vgt/(eta_t*vts),80))
    const b_sub_2 = vgt.scale(-1.0 / (eta_t * vts)).minC(80.0).exp();

    // Sheet carrier density
    // sqrt1 = sqrt(max(0, 1 - vgte_23/vpo))
    const sqrt1_2 = vgte_23.scale(-1.0 / vpo_2).addC(1.0).maxC(0.0).sqrt();
    // ns_denom = 1/(nd*d_ch*(1 - sqrt1) + 1e-30) + b_sub/n0
    const ns_denom_2 = S.con(1.0).div(sqrt1_2.neg().addC(1.0).scale(nd * d_ch).addC(1e-30)).add(b_sub_2.scale(1.0 / n0_2));
    const ns_2 = S.con(1.0).div(ns_denom_2);

    // Channel conductance
    // gchi = gchi0*mu_eff*ns; gch = gchi/(1 + gchi*(rsi+rdi))
    const gchi_2 = mu_eff_2.mul(ns_2).scale(gchi0_2);
    const gch_2 = gchi_2.div(gchi_2.scale(rsi + rdi).addC(1.0));

    // Saturation current (velocity-limited)
    // f = sqrt(1 + 2*a*rsi); dd = 1 + a*rsi + f; e = 1 + tc*vgte_23
    const f_2 = a_2.scale(2.0 * rsi).addC(1.0).sqrt();
    const dd_2 = a_2.scale(rsi).addC(1.0).add(f_2);
    const e_2 = vgte_23.scale(p.tc).addC(1.0);
    const isat_a_2 = a_2.mul(vgte_23).div(dd_2.mul(e_2));

    // Saturation current (diffusion-limited)
    // b_fwd = exp(min(vgt/(eta_t*vts),80)); isat_b = isatb0*mu_eff*b_fwd
    const b_fwd_2 = vgt.scale(1.0 / (eta_t * vts)).minC(80.0).exp();
    const isat_b_2 = mu_eff_2.mul(b_fwd_2).scale(isatb0_2);

    // Combined saturation current (harmonic mean)
    const isat_2 = isat_a_2.mul(isat_b_2).div(isat_a_2.add(isat_b_2).addC(1e-30));

    // Saturation voltage: vsat_e = isat/(gch + 1e-30)
    const vsat_e_2 = isat_2.div(gch_2.addC(1e-30));

    // Effective knee shape: m_eff = m_knee + alpha*vgte_23  (S)
    const m_eff_2 = vgte_23.scale(p.alpha_p).addC(p.m_knee);

    // Drain current
    // vds_ratio = vds_abs/(vsat_e + 1e-30)
    // h = exp((1/m_eff)*log(1 + exp(m_eff*log(max(vds_ratio,1e-30)))))
    const vds_ratio_2 = vds_abs.div(vsat_e_2.addC(1e-30));
    const h_2 = blk: {
        const lr = vds_ratio_2.maxC(1e-30).log();
        const inner = m_eff_2.mul(lr).exp();
        const s = inner.addC(1.0).log();
        const inv_m = S.con(1.0).div(m_eff_2);
        break :blk inv_m.mul(s).exp();
    };
    // id = gch*vds_abs/(h + 1e-30) * (1 + lambda_t*vds_abs)
    const id_2 = gch_2.mul(vds_abs).div(h_2.addC(1e-30)).mul(vds_abs.scale(lambda_t).addC(1.0));

    // ========================================================================
    // Level 3: Delta-doped two-layer MESFET
    // ========================================================================

    // Pinch-off voltages (two-layer)  (all f64 -- geometry only)
    const vpo_u = Q_CHARGE * p.ndu * p.du * p.du / (2.0 * EPS_GAAS);
    const vpo_d = Q_CHARGE * p.ndelta * p.th * (2.0 * p.du + p.th) / (2.0 * EPS_GAAS);
    const vpo_3 = vpo_u + vpo_d;

    // Pre-computed beta (same formula, uses d_ch)
    const beta_pre_3 = 2.0 * EPS_GAAS * vs * zeta * w / d_ch;

    // Subthreshold carrier concentration scale (Level 3: d' = du)
    const n0_3 = EPS_GAAS * eta_t * vts / (Q_CHARGE * p.du);

    // Subthreshold carrier concentration for two-layer
    const nsb0_3 = EPS_GAAS * eta_t * vts / (Q_CHARGE * (p.du + p.th));

    // Saturation current scale (uses n0_3)
    const isatb0_3 = Q_CHARGE * n0_3 * vts * w / l;

    // Channel conductance prefactor (Level 3: gchi0 = q*W/L * mu_T)
    const gchi0_3 = Q_CHARGE * w / l * p.mu_t;

    // Acceleration parameter: a = 2*beta_pre*vgte_23  (S)
    const a_3 = vgte_23.scale(2.0 * beta_pre_3);

    // Subthreshold factor (forward)
    const b_fwd_3 = vgt.scale(1.0 / (eta_t * vts)).minC(80.0).exp();

    // Sheet carrier density (two-layer)
    const nsa_max_3 = p.ndelta * p.th + p.ndu * p.du;
    // r = sqrt(max(0, 1 - vgte_23/vpo_3) / (vpo_u/vpo_3 + 1e-30))
    const r_3 = vgte_23.scale(-1.0 / vpo_3).addC(1.0).maxC(0.0).scale(1.0 / (vpo_u / vpo_3 + 1e-30)).sqrt();
    // nsa = nsa_max - ndu*du*r
    const nsa_3 = r_3.scale(-(p.ndu * p.du)).addC(nsa_max_3);
    const nsb_3 = b_fwd_3.scale(nsb0_3);
    const ns_3 = nsa_3.mul(nsb_3).div(nsa_3.add(nsb_3).addC(1e-30));

    // Channel conductance
    const gchi_3 = ns_3.scale(gchi0_3);
    const gch_3 = gchi_3.div(gchi_3.scale(rsi + rdi).addC(1.0));

    // Saturation currents
    const f_3 = a_3.scale(2.0 * rsi).addC(1.0).sqrt();
    const dd_3 = a_3.scale(rsi).addC(1.0).add(f_3);
    const e_3 = vgte_23.scale(p.tc).addC(1.0);
    const isat_a_3 = a_3.mul(vgte_23).div(dd_3.mul(e_3));
    const isat_b_3 = b_fwd_3.scale(isatb0_3);
    const isat_3 = isat_a_3.mul(isat_b_3).div(isat_a_3.add(isat_b_3).addC(1e-30));

    // Saturation voltage
    const vsat_e_3 = isat_3.div(gch_3.addC(1e-30));

    // Drain current (Level 3: M_eff = M, no alpha correction)
    // h = exp((1/m_knee)*log(1 + exp(m_knee*log(max(vds_ratio,1e-30)))))  -- m_knee is f64
    const vds_ratio_3 = vds_abs.div(vsat_e_3.addC(1e-30));
    const h_3 = blk: {
        const lr = vds_ratio_3.maxC(1e-30).log();
        const inner = lr.scale(p.m_knee).exp();
        break :blk inner.addC(1.0).log().scale(1.0 / p.m_knee).exp();
    };
    const id_3 = gch_3.mul(vds_abs).div(h_3.addC(1e-30)).mul(vds_abs.scale(lambda_t).addC(1.0));

    // ========================================================================
    // Level 4: Carrier-concentration-based MESFET
    // ========================================================================

    // Velocity parameter (f64)
    const vl_4 = vs / (p.mu_t + 1e-30) * l;

    // Subthreshold carrier concentration scale (Level 4: n0 = epsi*eta_T*Vts / (2*q*d))
    const n0_4 = p.epsi * eta_t * vts / (2.0 * Q_CHARGE * d_ch);

    // Channel conductance prefactor (Level 4: gchi0 = q*W/L * mu_T)
    const gchi0_4 = Q_CHARGE * w / l * p.mu_t;

    // Maximum current (f64)
    const imax_4 = Q_CHARGE * p.nmax * vs * w;

    // Carrier concentration (Fermi-Dirac-like)
    // b_fwd = exp(min(vgt/(eta_t*vts),80)); nsm = 2*n0*log(1 + b_fwd/2)
    const b_fwd_4 = vgt.scale(1.0 / (eta_t * vts)).minC(80.0).exp();
    const nsm_4 = b_fwd_4.scale(0.5).addC(1.0).log().scale(2.0 * n0_4);

    // NMAX limiting
    // c = exp(gamma*log(max(nsm/nmax,1e-30)))  = (max(nsm/nmax,1e-30))^gamma
    const c_4 = nsm_4.scale(1.0 / p.nmax).maxC(1e-30).log().scale(p.gamma_p).exp();
    // ns = nsm / exp((1/gamma)*log(1 + c))
    const ns_4 = nsm_4.div(c_4.addC(1.0).log().scale(1.0 / p.gamma_p).exp());

    // Channel conductance
    const gchi_4 = ns_4.scale(gchi0_4);
    const gch_4 = gchi_4.div(gchi_4.scale(rsi + rdi).addC(1.0));

    const gchi_m_4 = nsm_4.scale(gchi0_4);

    // Saturation current (two-term denominator)
    // hsat = sqrt(1 + 2*gchi_m*rsi + vgte_4^2/(vl^2 + 1e-30))
    const hsat_4 = gchi_m_4.scale(2.0 * rsi).add(vgte_4.mul(vgte_4).scale(1.0 / (vl_4 * vl_4 + 1e-30))).addC(1.0).sqrt();
    const p_4 = gchi_m_4.scale(rsi).addC(1.0).add(hsat_4);
    const isat_m_4 = gchi_m_4.mul(vgte_4).div(p_4.addC(1e-30));

    // NMAX limiting on saturation current
    // isat_ratio = (max(|isat_m|/(imax+1e-30),1e-30))^gamma
    const isat_ratio_4 = isat_m_4.abs().scale(1.0 / (imax_4 + 1e-30)).maxC(1e-30).log().scale(p.gamma_p).exp();
    const isat_4 = isat_m_4.div(isat_ratio_4.addC(1.0).log().scale(1.0 / p.gamma_p).exp());

    // Drain current
    // vsat_e = isat/(gch + 1e-30); vds_ratio = vds_abs/(|vsat_e| + 1e-30)
    const vsat_e_4 = isat_4.div(gch_4.addC(1e-30));
    const vds_ratio_4 = vds_abs.div(vsat_e_4.abs().addC(1e-30));
    const e_4 = blk: {
        const lr = vds_ratio_4.maxC(1e-30).log();
        const inner = lr.scale(p.m_knee).exp();
        break :blk inner.addC(1.0).log().scale(1.0 / p.m_knee).exp();
    };
    const id_4 = gch_4.mul(vds_abs).div(e_4.addC(1e-30)).mul(vds_abs.scale(lambda_t).addC(1.0));

    // ========================================================================
    // Select level
    // ========================================================================
    const id_raw: S = if (p.level == 4) id_4 else if (p.level == 3) id_3 else id_2;

    // --- Sign convention and multiplier ---
    // id_signed = id_raw * (2*blend - 1) * m_mult
    const id_signed = id_raw.mul(blend.scale(2.0).addC(-1.0)).scale(p.m_mult);

    // --- Parasitic resistance currents ---
    const i_rd = v_drain.sub(v_dp).scale(p.g_rd);
    const i_rg = v_gate.sub(v_gp).scale(p.g_rg);
    const i_rs = v_source.sub(v_sp).scale(p.g_rs);

    // --- KCL Node Stamping ---
    var out: [n_u]S = undefined;
    out[dr] = i_rd.neg();
    out[ga] = i_rg.neg();
    out[sr] = i_rs.neg();
    out[gp] = i_rg.sub(i_gs).sub(i_gd);
    out[dp] = i_rd.add(id_signed).add(i_gd);
    out[sp] = i_rs.sub(id_signed).add(i_gs);
    return out;
}

// ============================================================================
// Charge Function (q) -- value-form, generic over scalar S
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;
    _ = model;
    _ = instance;

    const dr = @intFromEnum(U.drain);
    const ga = @intFromEnum(U.gate);
    const sr = @intFromEnum(U.source);
    const dp = @intFromEnum(U.drain_prime);
    const gp = @intFromEnum(U.gate_prime);
    const sp = @intFromEnum(U.source_prime);

    const p = pc;

    const vts = p.vts;
    const eta_t = p.eta_t;
    const rsi = p.rsi;
    const rdi = p.rdi;
    const zeta = p.zeta;
    const w = p.w;
    const l = p.l;
    const d_ch = p.d_ch;
    const nd = p.nd;
    const vs = p.vs;

    // --- Terminal voltages ---
    const v_gp = x[gp];
    const v_dp = x[dp];
    const v_sp = x[sp];

    const vgs_int = v_gp.sub(v_sp);
    const vgd_int = v_gp.sub(v_dp);
    const vds_int = v_dp.sub(v_sp);

    // --- Inverse mode handling ---
    const vds_abs = vds_int.mul(vds_int).addC(EPS_SMOOTH).sqrt();
    const blend = vds_int.div(vds_abs).addC(1.0).scale(0.5);
    const one_minus_blend = blend.neg().addC(1.0);
    const vgs_eff = blend.mul(vgs_int).add(one_minus_blend.mul(vgd_int));

    // --- DIBL / Sigma Correction ---
    const vgt0 = vgs_eff.addC(-p.vto_t);
    const sigma = S.con(p.sigma0).div(vgt0.addC(-p.vsigmat).scale(1.0 / p.vsigma).minC(80.0).exp().addC(1.0));
    const vgt = vgt0.add(sigma.mul(vds_abs));

    // --- Smoothed subthreshold transition ---
    // Level 2/3
    const u_23 = vgt.scale(1.0 / vts).addC(-1.0);
    const t_23 = u_23.mul(u_23).addC(p.delta * p.delta).sqrt();
    const vgte_23 = u_23.add(t_23).addC(2.0).scale(vts / 2.0);

    // Level 4
    const u_4 = vgt.scale(1.0 / (2.0 * vts)).addC(-1.0);
    const t_4 = u_4.mul(u_4).addC(p.delta * p.delta).sqrt();
    const vgte_4 = u_4.add(t_4).addC(2.0).scale(vts);

    // ========================================================================
    // Fringing Capacitance (f64)
    // ========================================================================
    const c_f: f64 = if (p.level == 4) p.epsi * w / 2.0 else EPS_GAAS * w / 2.0;

    // ========================================================================
    // Gate-Channel Capacitance per level + saturation voltage
    // ========================================================================

    // --- Level 2 ---
    const vpo_2 = Q_CHARGE * nd * d_ch * d_ch / (2.0 * EPS_GAAS);
    const b_cap_2 = vgt.scale(-1.0 / (eta_t * vts)).minC(80.0).exp();
    const sqrt_dep_2 = vgt.scale(-1.0 / vpo_2).addC(1.0).maxC(0.0).sqrt();
    // cgc = w*l*EPS_GAAS / (d_ch*(sqrt_dep + b_cap + 1e-30))
    const cgc_2 = S.con(w * l * EPS_GAAS).div(sqrt_dep_2.add(b_cap_2).addC(1e-30).scale(d_ch));

    // Saturation voltage for capacitance (recompute Level 2 Isat / gch)
    const beta_pre_c2 = 2.0 * EPS_GAAS * vs * zeta * w / d_ch;
    const n0_c2 = EPS_GAAS * eta_t * vts / (Q_CHARGE * d_ch);
    const isatb0_c2 = Q_CHARGE * n0_c2 * vts * w / l;
    const gchi0_c2 = Q_CHARGE * w / l;
    const mu_eff_c2 = vgt.scale(p.theta_p).addC(p.mu_t);
    const vl_c2 = S.con(vs * l).div(mu_eff_c2.addC(1e-30));
    const beta_c2 = S.con(beta_pre_c2).div(vl_c2.scale(3.0).addC(vpo_2));
    const a_c2 = beta_c2.mul(vgte_23).scale(2.0);
    const b_sub_c2 = vgt.scale(-1.0 / (eta_t * vts)).minC(80.0).exp();
    const sqrt1_c2 = vgte_23.scale(-1.0 / vpo_2).addC(1.0).maxC(0.0).sqrt();
    const ns_denom_c2 = S.con(1.0).div(sqrt1_c2.neg().addC(1.0).scale(nd * d_ch).addC(1e-30)).add(b_sub_c2.scale(1.0 / n0_c2));
    const ns_c2 = S.con(1.0).div(ns_denom_c2);
    const gchi_c2 = mu_eff_c2.mul(ns_c2).scale(gchi0_c2);
    const gch_c2 = gchi_c2.div(gchi_c2.scale(rsi + rdi).addC(1.0));
    const f_c2 = a_c2.scale(2.0 * rsi).addC(1.0).sqrt();
    const dd_c2 = a_c2.scale(rsi).addC(1.0).add(f_c2);
    const e_c2 = vgte_23.scale(p.tc).addC(1.0);
    const isat_a_c2 = a_c2.mul(vgte_23).div(dd_c2.mul(e_c2));
    const b_fwd_c2 = vgt.scale(1.0 / (eta_t * vts)).minC(80.0).exp();
    const isat_b_c2 = mu_eff_c2.mul(b_fwd_c2).scale(isatb0_c2);
    const isat_c2 = isat_a_c2.mul(isat_b_c2).div(isat_a_c2.add(isat_b_c2).addC(1e-30));
    const vsat_e_c2 = isat_c2.div(gch_c2.addC(1e-30));

    // --- Level 3 ---
    const vpo_u = Q_CHARGE * p.ndu * p.du * p.du / (2.0 * EPS_GAAS);
    const vpo_d = Q_CHARGE * p.ndelta * p.th * (2.0 * p.du + p.th) / (2.0 * EPS_GAAS);
    const vpo_3 = vpo_u + vpo_d;
    const n0_c3 = EPS_GAAS * eta_t * vts / (Q_CHARGE * p.du);
    const nsb0_c3 = EPS_GAAS * eta_t * vts / (Q_CHARGE * (p.du + p.th));
    const isatb0_c3 = Q_CHARGE * n0_c3 * vts * w / l;
    const gchi0_c3 = Q_CHARGE * w / l * p.mu_t;
    const beta_pre_c3 = 2.0 * EPS_GAAS * vs * zeta * w / d_ch;
    const a_c3 = vgte_23.scale(2.0 * beta_pre_c3);
    const b_fwd_c3 = vgt.scale(1.0 / (eta_t * vts)).minC(80.0).exp();
    const nsa_max_c3 = p.ndelta * p.th + p.ndu * p.du;
    const r_c3 = vgte_23.scale(-1.0 / vpo_3).addC(1.0).maxC(0.0).scale(1.0 / (vpo_u / vpo_3 + 1e-30)).sqrt();
    const nsa_c3 = r_c3.scale(-(p.ndu * p.du)).addC(nsa_max_c3);
    const nsb_c3 = b_fwd_c3.scale(nsb0_c3);
    const ns_c3 = nsa_c3.mul(nsb_c3).div(nsa_c3.add(nsb_c3).addC(1e-30));
    const gchi_c3 = ns_c3.scale(gchi0_c3);
    const gch_c3 = gchi_c3.div(gchi_c3.scale(rsi + rdi).addC(1.0));
    const f_c3 = a_c3.scale(2.0 * rsi).addC(1.0).sqrt();
    const dd_c3 = a_c3.scale(rsi).addC(1.0).add(f_c3);
    const e_c3 = vgte_23.scale(p.tc).addC(1.0);
    const isat_a_c3 = a_c3.mul(vgte_23).div(dd_c3.mul(e_c3));
    const isat_b_c3 = b_fwd_c3.scale(isatb0_c3);
    const isat_c3 = isat_a_c3.mul(isat_b_c3).div(isat_a_c3.add(isat_b_c3).addC(1e-30));
    const vsat_e_c3 = isat_c3.div(gch_c3.addC(1e-30));

    // Capacitance: Level 3
    // ca = EPS_GAAS/(du*r + 1e-30); cb = EPS_GAAS/(du+th)*b_fwd
    const ca_c3 = S.con(EPS_GAAS).div(r_c3.scale(p.du).addC(1e-30));
    const cb_c3 = b_fwd_c3.scale(EPS_GAAS / (p.du + p.th));
    const cgc_3 = ca_c3.mul(cb_c3).div(ca_c3.add(cb_c3).addC(1e-30)).scale(w * l);

    // --- Level 4 ---
    const n0_c4 = p.epsi * eta_t * vts / (2.0 * Q_CHARGE * d_ch);
    const gchi0_c4 = Q_CHARGE * w / l * p.mu_t;
    const imax_c4 = Q_CHARGE * p.nmax * vs * w;
    const b_fwd_c4 = vgt.scale(1.0 / (eta_t * vts)).minC(80.0).exp();
    const nsm_c4 = b_fwd_c4.scale(0.5).addC(1.0).log().scale(2.0 * n0_c4);
    const c_c4 = nsm_c4.scale(1.0 / p.nmax).maxC(1e-30).log().scale(p.gamma_p).exp();
    const ns_c4 = nsm_c4.div(c_c4.addC(1.0).log().scale(1.0 / p.gamma_p).exp());
    const gchi_c4 = ns_c4.scale(gchi0_c4);
    const gch_c4 = gchi_c4.div(gchi_c4.scale(rsi + rdi).addC(1.0));
    const gchi_m_c4 = nsm_c4.scale(gchi0_c4);
    const vl_c4 = vs / (p.mu_t + 1e-30) * l;
    const hsat_c4 = gchi_m_c4.scale(2.0 * rsi).add(vgte_4.mul(vgte_4).scale(1.0 / (vl_c4 * vl_c4 + 1e-30))).addC(1.0).sqrt();
    const p_c4 = gchi_m_c4.scale(rsi).addC(1.0).add(hsat_c4);
    const isat_m_c4 = gchi_m_c4.mul(vgte_4).div(p_c4.addC(1e-30));
    const isat_ratio_c4 = isat_m_c4.abs().scale(1.0 / (imax_c4 + 1e-30)).maxC(1e-30).log().scale(p.gamma_p).exp();
    const isat_c4 = isat_m_c4.div(isat_ratio_c4.addC(1.0).log().scale(1.0 / p.gamma_p).exp());
    const vsat_e_c4 = isat_c4.div(gch_c4.addC(1e-30));

    // Capacitance: Level 4
    // ca_inv = d_ch/(cas*epsi + 1e-30); b_cap = exp(min(-vgt/(eta_t*vts),80))
    // cb_inv = eta_t*vts/(cbs*q*n0 + 1e-30)*b_cap; cgc_m = 1/(ca_inv + cb_inv)
    const ca_inv_c4 = d_ch / (p.cas * p.epsi + 1e-30);
    const b_cap_c4 = vgt.scale(-1.0 / (eta_t * vts)).minC(80.0).exp();
    const cb_inv_c4 = b_cap_c4.scale(eta_t * vts / (p.cbs * Q_CHARGE * n0_c4 + 1e-30));
    const cgc_m_c4 = S.con(1.0).div(cb_inv_c4.addC(ca_inv_c4));
    // cgc = w*l*cgc_m / exp((1 + 1/gamma)*log(1 + c))
    const cgc_4 = cgc_m_c4.scale(w * l).div(c_c4.addC(1.0).log().scale(1.0 + 1.0 / p.gamma_p).exp());

    // ========================================================================
    // Select level-dependent quantities
    // ========================================================================
    const cgc: S = if (p.level == 4) cgc_4 else if (p.level == 3) cgc_3 else cgc_2;
    const vsat_e: S = if (p.level == 4) vsat_e_c4.abs() else if (p.level == 3) vsat_e_c3 else vsat_e_c2;

    // ========================================================================
    // Effective drain-source voltage for capacitance (All Levels)
    // ========================================================================
    // vds_ratio = vds_abs/(vsat_e + 1e-30)
    // vdse = vds_abs * exp((-1/mc)*log(1 + exp(mc*log(max(vds_ratio,1e-30)))))
    const vds_ratio_cap = vds_abs.div(vsat_e.addC(1e-30));
    const vdse = blk: {
        const lr = vds_ratio_cap.maxC(1e-30).log();
        const inner = lr.scale(p.mc).exp();
        const factor = inner.addC(1.0).log().scale(-1.0 / p.mc).exp();
        break :blk vds_abs.mul(factor);
    };

    // ========================================================================
    // Ward-Dutton Charge Partitioning (All Levels)
    // ========================================================================
    // two_vsat_m_vdse = 2*vsat_e - vdse
    // fgs = (vsat_e - vdse)/(two... + 1e-30); fgd = vsat_e/(two... + 1e-30)
    const two_vsat_m_vdse = vsat_e.scale(2.0).sub(vdse);
    const fgs = vsat_e.sub(vdse).div(two_vsat_m_vdse.addC(1e-30));
    const fgd = vsat_e.div(two_vsat_m_vdse.addC(1e-30));

    // c_gs = c_f + (2/3)*cgc*(1 - fgs^2); c_gd = c_f + (2/3)*cgc*(1 - fgd^2)
    const c_gs = cgc.mul(fgs.mul(fgs).neg().addC(1.0)).scale(2.0 / 3.0).addC(c_f);
    const c_gd = cgc.mul(fgd.mul(fgd).neg().addC(1.0)).scale(2.0 / 3.0).addC(c_f);

    // ========================================================================
    // Inverse-Mode Capacitance Swapping
    // ========================================================================
    const cgs_eff = blend.mul(c_gs).add(one_minus_blend.mul(c_gd));
    const cgd_eff = blend.mul(c_gd).add(one_minus_blend.mul(c_gs));

    // ========================================================================
    // Charge Contributions (scaled by multiplier)
    // ========================================================================
    const q_gs = cgs_eff.mul(vgs_int).scale(p.m_mult);
    const q_gd = cgd_eff.mul(vgd_int).scale(p.m_mult);

    // ========================================================================
    // Charge KCL Stamping
    // ========================================================================
    var out: [n_u]S = undefined;
    out[dr] = S.con(0.0);
    out[ga] = S.con(0.0);
    out[sr] = S.con(0.0);
    out[gp] = q_gs.add(q_gd);
    out[sp] = q_gs.neg();
    out[dp] = q_gd.neg();
    return out;
}

// ============================================================================
// Voltage Limiting (Schottky junction limiting + FET gate overdrive limiting)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const gp = @intFromEnum(U.gate_prime);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const n_em: f64 = @as(f64, model.n);
    const phib: f64 = @as(f64, model.phib);
    const astar: f64 = @as(f64, model.astar);

    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const t_s = temp + dtemp;
    const vts = K_OVER_Q * t_s;
    const nvt = n_em * vts;

    // Saturation current for critical voltage computation
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const isat = 0.5 * astar * t_s * t_s * contract.fmath.exp(@min(-phib * Q_CHARGE / (K_BOLTZ * t_s), 80.0)) * w * l;

    // Critical voltage for pnjlim: Vcrit = n*Vt * ln(n*Vt / (sqrt(2) * Isat))
    const v_crit = nvt * contract.fmath.log(nvt / (@sqrt(2.0) * isat));

    var result = x_new;

    // ========================================================================
    // PN Junction Limiting on V_GS (gate_prime -- source_prime)
    // ========================================================================
    {
        const vgs_new = x_new[gp] - x_new[sp];
        const vgs_old = x_old[gp] - x_old[sp];

        var vgs_limited = vgs_new;
        if (vgs_new > v_crit and @abs(vgs_new - vgs_old) > 2.0 * nvt) {
            if (vgs_old > 0.0) {
                const arg = (vgs_new - vgs_old) / nvt;
                if (arg > 2.0) {
                    vgs_limited = vgs_old + nvt * (2.0 + contract.fmath.log(arg - 2.0));
                } else {
                    vgs_limited = vgs_old + 2.0 * nvt;
                }
            } else if (vgs_new > 0.0) {
                vgs_limited = nvt * contract.fmath.log(vgs_new / nvt);
            } else {
                vgs_limited = v_crit;
            }
        }

        const delta_gs = vgs_limited - vgs_new;
        result[gp] += delta_gs;
    }

    // ========================================================================
    // PN Junction Limiting on V_GD (gate_prime -- drain_prime)
    // ========================================================================
    {
        const vgd_new = result[gp] - x_new[dp];
        const vgd_old = x_old[gp] - x_old[dp];

        var vgd_limited = vgd_new;
        if (vgd_new > v_crit and @abs(vgd_new - vgd_old) > 2.0 * nvt) {
            if (vgd_old > 0.0) {
                const arg = (vgd_new - vgd_old) / nvt;
                if (arg > 2.0) {
                    vgd_limited = vgd_old + nvt * (2.0 + contract.fmath.log(arg - 2.0));
                } else {
                    vgd_limited = vgd_old + 2.0 * nvt;
                }
            } else if (vgd_new > 0.0) {
                vgd_limited = nvt * contract.fmath.log(vgd_new / nvt);
            } else {
                vgd_limited = v_crit;
            }
        }

        const delta_gd = vgd_limited - vgd_new;
        result[dp] -= delta_gd;
    }

    // ========================================================================
    // FET Gate Overdrive Limiting (fetlim) on V_GS
    // ========================================================================
    {
        const vto: f64 = @as(f64, model.vto);
        const tvto: f64 = @as(f64, model.tvto);
        const vto_t = vto - tvto * (t_s - 300.15);

        const vgs_new = result[gp] - result[sp];
        const vgs_old = x_old[gp] - x_old[sp];

        const vtsthi = @abs(2.0 * (vgs_old - vto_t)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const vtox = vto_t + 3.5;

        var vgs_fet = vgs_new;

        if (vgs_old >= vtox) {
            if (vgs_new > vgs_old) {
                vgs_fet = @min(vgs_new, vgs_old + vtsthi);
            } else {
                vgs_fet = @max(vgs_new, vgs_old - vtstlo);
                vgs_fet = @max(vgs_fet, vto_t + 2.0);
            }
        } else if (vgs_old >= vto_t) {
            if (vgs_new > vgs_old) {
                vgs_fet = @min(vgs_new, vgs_old + vtsthi);
            } else {
                vgs_fet = @max(vgs_new, vto_t - 0.5);
            }
        } else {
            if (vgs_new < vgs_old) {
                vgs_fet = @max(vgs_new, vgs_old - vtsthi);
            } else {
                vgs_fet = @min(vgs_new, vgs_old + vtstlo);
                vgs_fet = @min(vgs_fet, vto_t + 0.5);
            }
        }

        const delta_fet = vgs_fet - vgs_new;
        result[gp] += delta_fet;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// Gmin stepping: at lambda=0, add large gmin to diode conductance for easy
// convergence; at lambda=1, use original model parameters.

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    // Scale effective gate conductance ggr by adding gmin*(1-lambda)
    const ggr_orig: f64 = @as(f64, model.ggr);
    const ggr_stepped = ggr_orig + gmin_step * (1.0 - lambda);
    m.ggr = @floatCast(ggr_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "mesa: default level-2 device, drain current > 0 in saturation" {
    // Default model (level 2). Bias: Vd=2, Vg=0, Vs=0, primed nodes tied to
    // terminals (Rd=Rs=Rg=0 -> GSHORT resistors). With Vgs=0 and Vto=-1.26,
    // the channel is on (Vgs > Vto), so the drain-prime node must sink current.
    const model: Model = .{};
    const inst: Instance = .{};
    // x = [drain, gate, source, drain_prime, gate_prime, source_prime]
    const out = contract.evalValues(Self, .{ 2.0, 0.0, 0.0, 2.0, 0.0, 0.0 }, &model, &inst, 0);

    // KCL residuals must sum to ~0 (charge conservation of currents).
    var sum: f64 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-6);

    // Drain-side current into drain_prime should be positive (device sinks
    // channel current from drain toward source in forward saturation).
    // out[dp] = i_rd + id_signed + i_gd ; with Vgs=0>Vto the channel conducts.
    try testing.expect(out[@intFromEnum(U.drain_prime)] > 0.0);
    // Source-prime carries the returning channel current (negative here).
    try testing.expect(out[@intFromEnum(U.source_prime)] < 0.0);
}

test "mesa: forward-biased gate Schottky diode current (g'-s')" {
    // Isolate the source-side gate diode: put a forward bias on gate_prime
    // relative to source_prime and read the diode contribution at gate_prime.
    // With Vds=0 (drain_prime = source_prime) the channel current id -> 0 by
    // the antisymmetric sign factor (2*blend-1)=0 at vds=0, so the gate node
    // residual is dominated by the two diodes.
    //
    // Hand check of the diode current at Vgs=0.5, defaults:
    //   isat_fs = 0.5*astar*Ts^2*exp(-phib*q/(kB*Ts))*W*L
    //   astar=4e4, Ts=300.15, W=20e-6, L=1e-6, phib=0.5
    //   -phib*q/(kB*Ts) = -0.5*1.602176634e-19/(1.380649e-23*300.15)
    //                   ~ -19.327 -> exp ~ 4.02e-9
    //   isat_fs = 0.5*4e4*300.15^2*4.02e-9*20e-6*1e-6 ~ 1.449e-13 (order)
    //   vtes = n*K_OVER_Q*Ts = 1*8.617333e-5*300.15 ~ 0.025865 V
    //   exp(0.5/0.025865) ~ exp(19.33) ~ 2.48e8 -> huge forward current
    // We only assert sign/monotonic behavior since exact value is dominated by
    // the exponential; the diode must inject positive current out of gate_prime.
    const model: Model = .{};
    const inst: Instance = .{};

    // gate_prime high, source_prime = drain_prime = 0.
    const out = contract.evalValues(Self, .{ 0.0, 0.5, 0.0, 0.0, 0.5, 0.0 }, &model, &inst, 0);

    // out[gp] = i_rg - i_gs - i_gd. i_rg here pushes gate current in; the diode
    // terms subtract. With strong forward bias i_gs+i_gd dominates so the gate
    // node residual is strongly negative (diodes conducting away from gp).
    try testing.expect(out[@intFromEnum(U.gate_prime)] < 0.0);

    // KCL residuals sum to zero.
    var sum: f64 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-3);
}

test "mesa: zero Vds gives zero channel current sign factor" {
    // At Vds = 0, blend = 0.5, so (2*blend - 1) = 0 -> id_signed = 0.
    // With all node voltages equal, the diodes see 0 bias too, so every
    // residual is ~0 (only GMIN leakage, which is 0 at 0V).
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    for (out) |o| try testing.expectApproxEqAbs(@as(f64, 0.0), o, 1e-9);
}

test "mesa: charge q gate partitioning is finite and antisymmetric bookkeeping" {
    // q stamps: out[gp] = q_gs + q_gd, out[sp] = -q_gs, out[dp] = -q_gd.
    // Therefore out[gp] + out[sp] + out[dp] == 0 exactly (charge conservation),
    // and out[dr]=out[ga]=out[sr]=0.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, 0.5, 0.0, 1.0, 0.5, 0.0 }, &model, &inst, 0);

    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.drain)]);
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.gate)]);
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.source)]);

    const qsum = out[@intFromEnum(U.gate_prime)] +
        out[@intFromEnum(U.source_prime)] +
        out[@intFromEnum(U.drain_prime)];
    try testing.expectApproxEqAbs(@as(f64, 0.0), qsum, 1e-18);

    // Charges must be finite (no NaN/Inf from the smoothing chains).
    for (out) |o| try testing.expect(std.math.isFinite(o));
}
