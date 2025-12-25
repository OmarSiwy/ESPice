const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// MOS Level 3 -- Semi-empirical short-channel MOSFET (Berkeley SPICE3f5)
//
// Topology: D (external drain)  -- RD -- D' (internal drain)
//           S (external source) -- RS -- S' (internal source)
//           G (gate)            -- Meyer oxide capacitances --> D', S', B
//           B (bulk)            -- junction diodes          --> D', S'
//           Channel current flows between D' and S'
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, d_prime, s_prime };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- DC Model Parameters ---
    vto: f32 = 0, // Zero-bias threshold voltage (V)
    kp: f32 = 2.07189e-5, // Transconductance parameter (A/V^2)
    gamma: f32 = 0, // Bulk threshold (body effect) parameter (V^1/2)
    phi: f32 = 0.6, // Surface inversion potential (V)
    nsub: f32 = 0, // Substrate doping concentration (cm^-3)
    nss: f32 = 0, // Surface state density (cm^-2)
    nfs: f32 = 0, // Fast surface state density (cm^-2)
    tpg: i32 = 0, // Gate type (0=aluminum, +1=opposite, -1=same)
    eta: f32 = 0, // Vds dependence of Vth (DIBL)
    delta: f32 = 0, // Width effect on Vth (narrow channel)
    input_delta: f32 = 0, // Input delta
    theta: f32 = 0, // Vgs dependence of mobility (1/V)
    kappa: f32 = 0.2, // Channel-length modulation parameter
    alpha: f32 = 0, // Alpha (impact ionization)
    u0: f32 = 600, // Low-field surface mobility (cm^2/V-s)
    vmax: f32 = 0, // Maximum carrier drift velocity (m/s)
    xj: f32 = 0, // Metallurgical junction depth (m)
    delvto: f32 = 0, // Threshold voltage adjust (V)
    type_: i32 = 1, // Device polarity: 1=NMOS, -1=PMOS

    // --- Geometry Parameters ---
    ld: f32 = 0, // Lateral diffusion length (m)
    xl: f32 = 0, // Length mask adjustment (m)
    wd: f32 = 0, // Width narrowing (diffusion) (m)
    xw: f32 = 0, // Width mask adjustment (m)
    tox: f32 = 1e-7, // Gate oxide thickness (m)

    // --- Series Resistance Parameters ---
    rd: f32 = 0, // Drain ohmic resistance (Ohm)
    rs: f32 = 0, // Source ohmic resistance (Ohm)
    rsh: f32 = 0, // Sheet resistance (Ohm/sq)

    // --- Junction Diode Parameters ---
    is_: f32 = 1e-14, // Bulk junction saturation current (A)
    js: f32 = 0, // Bulk junction saturation current density (A/m^2)
    pb: f32 = 0.8, // Bulk junction built-in potential (V)
    fc: f32 = 0.5, // Forward-bias junction cap fitting parameter

    // --- Junction Capacitance Parameters ---
    cbd: f32 = 0, // Zero-bias bulk-drain junction capacitance (F)
    cbs: f32 = 0, // Zero-bias bulk-source junction capacitance (F)
    cj: f32 = 0, // Zero-bias bottom junction cap per unit area (F/m^2)
    mj: f32 = 0.5, // Bottom junction grading coefficient
    cjsw: f32 = 0, // Zero-bias sidewall junction cap per unit length (F/m)
    mjsw: f32 = 0.33, // Sidewall junction grading coefficient

    // --- Overlap Capacitance Parameters ---
    cgso: f32 = 0, // Gate-source overlap cap per unit width (F/m)
    cgdo: f32 = 0, // Gate-drain overlap cap per unit width (F/m)
    cgbo: f32 = 0, // Gate-bulk overlap cap per unit length (F/m)

    // --- Noise Parameters ---
    kf: f32 = 0, // Flicker noise coefficient
    af: f32 = 1, // Flicker noise exponent
    nlev: i32 = 2, // Noise model selection level
    gdsnoi: f32 = 1, // Channel shot noise coefficient

    // --- Temperature ---
    tnom: f32 = 27, // Parameter measurement temperature (deg C)
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 1e-6, // Drawn channel length (m)
    w: f32 = 1e-6, // Drawn channel width (m)
    temp: f32 = 27.0, // Device operating temperature (deg C)
    m: f32 = 1.0, // Multiplier (parallel instances)
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// RD branch: drain -- d_prime
// RS branch: source -- s_prime
// Junction BS: bulk -- s_prime
// Junction BD: bulk -- d_prime
// Channel: d_prime -- s_prime (with gate and bulk dependencies)

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: drain -- d_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.drain) },
    // RS branch: source -- s_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.source) },
    // Bulk junction BD: bulk -- d_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.bulk) },
    // Bulk junction BS: bulk -- s_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.bulk) },
    // Channel: d_prime -- s_prime (with gate and bulk dependence)
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    // Gate dependence of channel
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Meyer gate charges: Q_GS (gate--s_prime), Q_GD (gate--d_prime), Q_GB (gate--bulk)
// Junction charges: Q_BS (bulk--s_prime), Q_BD (bulk--d_prime)

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Q_GS: gate -- s_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    // Q_GD: gate -- d_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    // Q_GB: gate -- bulk
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    // Q_BS: bulk -- s_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.bulk) },
    // Q_BD: bulk -- d_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.bulk) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Channel thermal noise: D' -- S'
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Channel flicker (1/f) noise: D' -- S'
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .flicker },
};

// ============================================================================
// x-independent DC parameter preprocessing (pure f64 — no terminal voltages)
// ============================================================================

const DcPrep = struct {
    type_f: f64, // device polarity (+1 NMOS / -1 PMOS)
    m_mult: f64, // parallel multiplier
    vt: f64, // thermal voltage at device temp
    leff: f64, // effective channel length
    weff: f64, // effective channel width
    g_rd: f64, // drain series conductance
    g_rs: f64, // source series conductance
    is_val: f64, // junction saturation current
    gamma: f64, // body effect coefficient
    phi_safe: f64, // clamped surface potential
    sqrt_phi: f64, // sqrt(phi)
    alpha_dep: f64, // depletion-layer alpha (2*eps_si/(q*Nsub))
    coeff_dep_lay_width: f64, // sqrt(alpha_dep)
    f_narrow_w: f64, // narrow-channel factor / weff
    eta_scaled: f64, // scaled DIBL coefficient
    do_short: bool, // short-channel Vth correction active
    xj: f64, // junction depth
    xj_leff: f64, // xj_safe / leff
    ld_xj: f64, // ld / xj (when do_short)
    vbi_t: f64, // vbi * type_f
    has_nfs: bool, // subthreshold model active
    cs_cox: f64, // fast-surface-state cap ratio
    theta: f64, // mobility degradation coefficient
    beta: f64, // kp * weff / leff
    has_vmax: bool, // velocity saturation active
    vdsc_k: f64, // vmax * leff / mu0_si
    kappa: f64, // CLM coefficient
    has_primary_clm: bool, // primary CLM path active
    has_fallback_clm: bool, // fallback CLM path active
};

fn dcPrep(model: *const Model, instance: *const Instance) DcPrep {
    // --- Cast model parameters to f64 ---
    const vto: f64 = @as(f64, model.vto);
    const kp: f64 = @as(f64, model.kp);
    const gamma: f64 = @as(f64, model.gamma);
    const phi: f64 = @as(f64, model.phi);
    const nsub: f64 = @as(f64, model.nsub);
    const nfs: f64 = @as(f64, model.nfs);
    const eta_m: f64 = @as(f64, model.eta);
    const delta_m: f64 = @as(f64, model.delta);
    const theta: f64 = @as(f64, model.theta);
    const kappa: f64 = @as(f64, model.kappa);
    const mu0: f64 = @as(f64, model.u0);
    const vmax: f64 = @as(f64, model.vmax);
    const xj: f64 = @as(f64, model.xj);
    const delvto: f64 = @as(f64, model.delvto);
    const ld: f64 = @as(f64, model.ld);
    const xl: f64 = @as(f64, model.xl);
    const wd: f64 = @as(f64, model.wd);
    const xw: f64 = @as(f64, model.xw);
    const tox: f64 = @as(f64, model.tox);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const is_val: f64 = @as(f64, model.is_);

    // --- Cast instance parameters to f64 ---
    const l_draw: f64 = @as(f64, instance.l);
    const w_draw: f64 = @as(f64, instance.w);
    const temp: f64 = @as(f64, instance.temp);
    const m_mult: f64 = @as(f64, instance.m);

    // --- Type factor for NMOS/PMOS ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Physical constants ---
    const eps0: f64 = 8.854214871e-12;
    const eps_si: f64 = 11.7 * eps0;
    const eps_ox: f64 = 3.9 * eps0;
    const q_charge: f64 = 1.602176634e-19;
    const eps: f64 = 1.0e-30;

    // --- Thermal voltage (uses device operating temperature, not tnom) ---
    const vt: f64 = 8.617333e-5 * (temp + 273.15);

    // --- Effective geometry ---
    const leff = @max(l_draw - 2.0 * ld + xl, 1.0e-9);
    const weff = @max(w_draw - 2.0 * wd + xw, 1.0e-9);

    // --- Oxide capacitance per unit area ---
    const cox_prime = eps_ox / tox;

    // --- Series conductances ---
    const g_rd: f64 = if (rd != 0.0) 1.0 / rd else 1.0e12;
    const g_rs: f64 = if (rs != 0.0) 1.0 / rs else 1.0e12;

    // --- Depletion layer coefficient ---
    const nsub_m3 = nsub * 1.0e6; // cm^-3 to m^-3
    const alpha_dep = if (nsub > 0.0) 2.0 * eps_si / (q_charge * nsub_m3) else 0.0;
    const coeff_dep_lay_width = @sqrt(@max(alpha_dep, 0.0));

    // --- Square root of surface potential (zero bias) ---
    const phi_safe = @max(phi, 1.0e-30);
    const sqrt_phi = @sqrt(phi_safe);

    // --- Narrow channel effect ---
    const pi: f64 = 3.14159265358979323846;
    const f_narrow = delta_m * pi * eps_si / (2.0 * cox_prime);

    // --- ETA scaling (DIBL coefficient) ---
    const eta_scaled = eta_m * 8.15e-22 / (cox_prime * leff * leff * leff);

    // --- Short-channel effect setup ---
    const do_short = xj > 0.0 and coeff_dep_lay_width > 0.0;
    const xj_safe = @max(xj, eps);
    const ld_xj: f64 = if (do_short) ld / xj else 0.0;

    // --- Built-in voltage ---
    const vbi = delvto + vto - type_f * gamma * sqrt_phi;

    // --- Subthreshold (weak inversion) setup ---
    const has_nfs = nfs > 0.0;
    const nfs_m2 = nfs * 1.0e4; // cm^-2 to m^-2
    const cs_cox: f64 = if (has_nfs) q_charge * nfs_m2 / cox_prime else 0.0;

    // --- Transconductance factor ---
    const beta = kp * weff / leff;

    // --- Velocity saturation setup ---
    const has_vmax = vmax > 0.0;
    const mu0_si = mu0 * 1.0e-4; // cm^2/V-s to m^2/V-s
    const vdsc_k: f64 = if (has_vmax) vmax * leff / mu0_si else 0.0;

    // --- CLM path selection ---
    const has_primary_clm = alpha_dep > 0.0 and kappa > 0.0;
    const has_fallback_clm = kappa > 0.0 and nsub > 0.0;

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .vt = vt,
        .leff = leff,
        .weff = weff,
        .g_rd = g_rd,
        .g_rs = g_rs,
        .is_val = is_val,
        .gamma = gamma,
        .phi_safe = phi_safe,
        .sqrt_phi = sqrt_phi,
        .alpha_dep = alpha_dep,
        .coeff_dep_lay_width = coeff_dep_lay_width,
        .f_narrow_w = f_narrow / weff,
        .eta_scaled = eta_scaled,
        .do_short = do_short,
        .xj = xj,
        .xj_leff = xj_safe / leff,
        .ld_xj = ld_xj,
        .vbi_t = vbi * type_f,
        .has_nfs = has_nfs,
        .cs_cox = cs_cox,
        .theta = theta,
        .beta = beta,
        .has_vmax = has_vmax,
        .vdsc_k = vdsc_k,
        .kappa = kappa,
        .has_primary_clm = has_primary_clm,
        .has_fallback_clm = has_fallback_clm,
    };
}

// ============================================================================
// DC Current Function (eval) -- value-form: generic over scalar S
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
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const p = &pc.dc;

    const gmin: f64 = 1.0e-12;
    const eps: f64 = 1.0e-30;

    // --- Terminal voltages ---
    const vd_ext = x[d];
    const vg_ext = x[g];
    const vs_ext = x[s];
    const vb_ext = x[b];
    const vd_int = x[dp];
    const vs_int = x[sp];

    // --- Series resistances ---
    const i_rd = vd_ext.sub(vd_int).scale(p.g_rd);
    const i_rs = vs_ext.sub(vs_int).scale(p.g_rs);

    // --- Internal voltages with NMOS/PMOS polarity ---
    const vgs_raw = vg_ext.sub(vs_int).scale(p.type_f);
    const vds_raw = vd_int.sub(vs_int).scale(p.type_f);
    const vbs_raw = vb_ext.sub(vs_int).scale(p.type_f);

    // --- Source/drain reversal (branchless) ---
    const vds_abs = vds_raw.abs();
    const step_fwd = vds_raw.add(vds_abs).div(vds_abs.addC(eps).scale(2.0));
    const one_m_step = step_fwd.neg().addC(1.0);
    const vds_eff = vds_abs;

    const vgs_fwd = vgs_raw;
    const vgs_rev = vgs_raw.sub(vds_raw);
    const vgs_use = vgs_fwd.mul(step_fwd).add(vgs_rev.mul(one_m_step));

    const vbs_fwd = vbs_raw;
    const vbs_rev = vbs_raw.sub(vds_raw);
    const vbs_use = vbs_fwd.mul(step_fwd).add(vbs_rev.mul(one_m_step));

    // --- Bulk junction diode currents ---
    const vbd = vbs_use.sub(vds_eff);

    const arg_bs = vbs_use.div(S.con(p.vt)).minC(80.0);
    const i_bs = arg_bs.exp().addC(-1.0).scale(p.is_val).add(vbs_use.scale(gmin));

    const arg_bd = vbd.div(S.con(p.vt)).minC(80.0);
    const i_bd = arg_bd.exp().addC(-1.0).scale(p.is_val).add(vbd.scale(gmin));

    // --- Square root of surface potential (bias-dependent) ---
    // Reverse bias: sqrt(phi - vbs_use)
    const sqrt_phi_bs_rev = vbs_use.neg().addC(p.phi_safe).maxC(1.0e-30).sqrt();
    // Forward bias: sqrt(phi) / (1 + vbs/(2*phi))
    const sqrt_phi_bs_fwd = S.con(p.sqrt_phi).div(vbs_use.div(S.con(2.0 * p.phi_safe)).addC(1.0).maxC(1.0e-30));

    // Smooth blend using sign-based step functions
    const abs_vbs = vbs_use.abs();
    const s_neg = vbs_use.neg().maxC(0.0).div(abs_vbs.addC(eps));
    const s_pos = vbs_use.maxC(0.0).div(abs_vbs.addC(eps));
    const sqrt_phi_bs = sqrt_phi_bs_rev.mul(s_neg).add(sqrt_phi_bs_fwd.mul(s_pos));
    // When vbs_use == 0, both s_neg and s_pos are ~0, use sqrt(phi) directly
    // (region selection on the voltage value, as in the original)
    const sqrt_phi_bs_safe: S = if (abs_vbs.val() < 1.0e-20) S.con(p.sqrt_phi) else sqrt_phi_bs;
    const phi_bs = sqrt_phi_bs_safe.mul(sqrt_phi_bs_safe);

    // --- Short-channel effect factor ---
    const wps = sqrt_phi_bs_safe.scale(p.coeff_dep_lay_width);
    const wp_xj: S = if (p.do_short) wps.div(S.con(p.xj)) else S.con(0.0);
    const wc_xj = wp_xj.scale(0.8013292).addC(0.0631353).sub(wp_xj.scale(0.01110777).mul(wp_xj));
    const argc = wp_xj.div(wp_xj.addC(1.0));
    const sqrt_argc = argc.mul(argc).neg().addC(1.0).maxC(0.0).sqrt();
    const f_short_calc = wc_xj.addC(p.ld_xj).mul(sqrt_argc).addC(-p.ld_xj).scale(p.xj_leff).neg().addC(1.0);
    const f_short: S = if (p.do_short) f_short_calc else S.con(1.0);

    // --- Body effect ---
    const gamma_s = f_short.scale(p.gamma);
    const f_body_s = gamma_s.div(sqrt_phi_bs_safe.scale(4.0));
    const f_body = f_body_s.addC(p.f_narrow_w);

    // --- Threshold voltage ---
    const qb_cox = gamma_s.mul(sqrt_phi_bs_safe).add(phi_bs.scale(p.f_narrow_w));
    const vbix = vds_eff.scale(p.eta_scaled).neg().addC(p.vbi_t);
    const vth = vbix.add(qb_cox);

    // --- Subthreshold region (weak inversion) ---
    const cd_cox: S = if (p.has_nfs) qb_cox.div(phi_bs.scale(2.0)) else S.con(0.0);
    const xn: S = if (p.has_nfs) cd_cox.addC(1.0 + p.cs_cox) else S.con(1.0);
    const von: S = if (p.has_nfs) vth.add(xn.scale(p.vt)) else vth;

    // --- Effective gate voltage (clamped to von) ---
    const vgsx = vgs_use.max(von);

    // --- Mobility degradation ---
    const fgate_inv = vgsx.sub(vth).scale(p.theta).addC(1.0);
    const fgate = S.con(1.0).div(fgate_inv.maxC(1.0e-30));

    // --- Saturation voltage ---
    const a_vdsat = vgsx.sub(vth).div(f_body.addC(1.0));

    const vdsc: S = if (p.has_vmax) fgate_inv.scale(p.vdsc_k).div(fgate) else S.con(0.0);

    // Without velocity saturation: VDSAT = a
    // With velocity saturation: VDSAT = a + vdsc - sqrt(a^2 + vdsc^2)
    const b_vdsat = a_vdsat.mul(a_vdsat).add(vdsc.mul(vdsc)).sqrt();
    const vdsat: S = if (p.has_vmax) a_vdsat.add(vdsc).sub(b_vdsat) else a_vdsat;

    // --- Drain current (strong inversion) ---
    const vdsx = vds_eff.min(vdsat.maxC(0.0));

    // Channel charge factor
    const cdo = vgsx.sub(vth).sub(f_body.addC(1.0).scale(0.5).mul(vdsx));

    // Normalized channel current
    const i_dnorm = cdo.mul(vdsx);

    // Base drain current with mobility degradation
    const ids_base = fgate.scale(p.beta).mul(i_dnorm);

    // --- Velocity saturation factor ---
    const fdrain: S = if (p.has_vmax) S.con(1.0).div(vdsx.div(vdsc.maxC(1.0e-30)).addC(1.0)) else S.con(1.0);
    const ids = ids_base.mul(fdrain);

    // --- Channel-length modulation (CLM) ---
    const vds_excess = vds_eff.sub(vdsat).maxC(0.0);

    const fclm: S = if (p.has_primary_clm) blk: {
        // Primary path: alpha_dep > 0 and kappa > 0
        const delta_l_primary = vds_excess.add(vdsat.scale(0.125)).scale(p.kappa * p.alpha_dep).maxC(0.0).sqrt();
        const delta_l_primary_limited = delta_l_primary.minC(p.leff / 2.0);
        break :blk S.con(1.0).div(delta_l_primary_limited.div(S.con(p.leff)).neg().addC(1.0));
    } else if (p.has_fallback_clm) blk: {
        // Fallback path: kappa > 0, nsub > 0, alpha_dep == 0
        const delta_l_raw = vds_excess.maxC(0.0).sqrt().scale(p.coeff_dep_lay_width);
        const delta_l_corr: S = if (p.xj > 0.0)
            delta_l_raw.scale(2.0).div(S.con(p.xj)).addC(1.0).maxC(1.0).sqrt().addC(-1.0).scale(p.xj)
        else
            delta_l_raw;
        break :blk S.con(1.0).div(delta_l_corr.div(S.con(p.leff)).minC(0.5).neg().addC(1.0));
    } else S.con(1.0);

    const ids_sat = ids.mul(fclm);

    // --- Subthreshold current factor ---
    const ids_final: S = if (p.has_nfs)
        ids_sat.mul(vgs_use.sub(von).div(xn.scale(p.vt)).minC(0.0).exp())
    else blk: {
        // Smooth sigmoid cutoff when NFS = 0
        const sigma_arg = vgs_use.sub(von).scale(-100.0).minC(80.0);
        const sigma = S.con(1.0).div(sigma_arg.exp().addC(1.0));
        break :blk ids_sat.mul(sigma);
    };

    // --- Mode sign and output currents ---
    const mode = step_fwd.scale(2.0).addC(-1.0);
    const i_channel = ids_final.mul(mode);

    // PMOS sign and multiplier
    const i_channel_out = i_channel.scale(p.type_f * p.m_mult);
    const i_bs_final = i_bs.scale(p.type_f * p.m_mult);
    const i_bd_final = i_bd.scale(p.type_f * p.m_mult);

    // --- KCL node stamping ---
    var out: [n_u]S = undefined;
    out[d] = i_rd;
    out[g] = S.con(0.0);
    out[s] = i_rs;
    out[b] = i_bd_final.add(i_bs_final);
    out[dp] = i_rd.neg().add(i_channel_out).sub(i_bd_final);
    out[sp] = i_rs.neg().sub(i_channel_out).sub(i_bs_final);
    return out;
}

// ============================================================================
// x-independent charge-model parameter preprocessing (pure f64)
// ============================================================================

const QPrep = struct {
    type_f: f64, // device polarity (+1 NMOS / -1 PMOS)
    m_mult: f64, // parallel multiplier
    vt: f64, // thermal voltage at device temp
    phi_safe: f64, // clamped surface potential
    sqrt_phi: f64, // sqrt(phi)
    gamma: f64, // body effect coefficient
    vto_adj: f64, // vto + delvto
    has_nfs: bool, // subthreshold model active
    cox_total: f64, // effective total oxide capacitance
    cgso_w: f64, // cgso * weff
    cgdo_w: f64, // cgdo * weff
    cgbo_l: f64, // cgbo * leff
    cbs0: f64, // zero-bias B-S junction cap
    cbd0: f64, // zero-bias B-D junction cap
    pb_safe: f64, // clamped junction potential
    mj: f64, // grading coefficient
    one_minus_mj: f64, // 1 - mj
    fc_pb: f64, // fc * pb
    one_minus_fc: f64, // clamped 1 - fc
};

fn qPrep(model: *const Model, instance: *const Instance) QPrep {
    // --- Cast model parameters to f64 ---
    const vto: f64 = @as(f64, model.vto);
    const kp: f64 = @as(f64, model.kp);
    const gamma: f64 = @as(f64, model.gamma);
    const phi: f64 = @as(f64, model.phi);
    const delvto: f64 = @as(f64, model.delvto);
    const mu0: f64 = @as(f64, model.u0);
    const tox: f64 = @as(f64, model.tox);
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cbd0: f64 = @as(f64, model.cbd);
    const cbs0: f64 = @as(f64, model.cbs);
    const pb: f64 = @as(f64, model.pb);
    const fc: f64 = @as(f64, model.fc);
    const mj: f64 = @as(f64, model.mj);
    const nfs: f64 = @as(f64, model.nfs);
    const ld: f64 = @as(f64, model.ld);
    const xl: f64 = @as(f64, model.xl);
    const wd: f64 = @as(f64, model.wd);
    const xw: f64 = @as(f64, model.xw);

    // --- Cast instance parameters to f64 ---
    const w_draw: f64 = @as(f64, instance.w);
    const l_draw: f64 = @as(f64, instance.l);
    const temp: f64 = @as(f64, instance.temp);
    const m_mult: f64 = @as(f64, instance.m);

    // --- Type factor for NMOS/PMOS ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Physical constants ---
    const eps0: f64 = 8.854214871e-12;
    const eps_ox: f64 = 3.9 * eps0;

    // --- Effective geometry ---
    const leff = @max(l_draw - 2.0 * ld + xl, 1.0e-9);
    const weff = @max(w_draw - 2.0 * wd + xw, 1.0e-9);

    // --- Thermal voltage (uses device operating temperature, not tnom) ---
    const vt: f64 = 8.617333e-5 * (temp + 273.15);

    // --- Surface potential ---
    const phi_safe = @max(phi, 1.0e-30);
    const sqrt_phi = @sqrt(phi_safe);

    // --- Effective oxide capacitance (per unit area) ---
    const mu0_si = mu0 * 1.0e-4;
    const cox_eff: f64 = if (mu0 > 0.0) kp / mu0_si else eps_ox / tox;

    // --- Junction capacitance coefficients ---
    const pb_safe = @max(pb, 1.0e-30);
    const one_minus_mj = 1.0 - mj;
    const fc_pb = fc * pb_safe;
    const one_minus_fc = @max(1.0 - fc, 1.0e-30);

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .vt = vt,
        .phi_safe = phi_safe,
        .sqrt_phi = sqrt_phi,
        .gamma = gamma,
        .vto_adj = vto + delvto,
        .has_nfs = nfs > 0.0,
        .cox_total = cox_eff * weff * leff,
        .cgso_w = cgso * weff,
        .cgdo_w = cgdo * weff,
        .cgbo_l = cgbo * leff,
        .cbs0 = cbs0,
        .cbd0 = cbd0,
        .pb_safe = pb_safe,
        .mj = mj,
        .one_minus_mj = one_minus_mj,
        .fc_pb = fc_pb,
        .one_minus_fc = one_minus_fc,
    };
}

pub const PrepCache = struct { dc: DcPrep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{
        .dc = dcPrep(model, instance),
        .q = qPrep(model, instance),
    };
}

/// Bulk junction depletion charge (depletion + forward-bias extension).
/// Region selection on the junction voltage value, as in the original.
fn junctionCharge(comptime S: type, v: S, cj0: f64, p: QPrep) S {
    const x_dep = v.div(S.con(p.pb_safe)).neg().addC(1.0).maxC(1.0e-8);
    const q_dep = x_dep.log().scale(p.one_minus_mj).exp().neg().addC(1.0).scale(cj0 * p.pb_safe / p.one_minus_mj);

    // Forward-bias extension coefficients
    const f1 = (cj0 * p.pb_safe / p.one_minus_mj) * (1.0 - @exp(p.one_minus_mj * @log(p.one_minus_fc)));
    const f2 = @exp((1.0 + p.mj) * @log(p.one_minus_fc));
    const f3 = 1.0 - (p.fc_pb / p.pb_safe) * (1.0 + p.mj);
    const q_fwd = v.addC(-p.fc_pb).scale(f3)
        .add(v.mul(v).addC(-(p.fc_pb * p.fc_pb)).scale(p.mj / (2.0 * p.pb_safe)))
        .scale(cj0 / f2).addC(f1);

    return if (v.val() < p.fc_pb) q_dep else q_fwd;
}

// ============================================================================
// Charge Function (q) -- Meyer Gate Capacitances + Junction Depletion
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const p = &pc.q;
    const eps: f64 = 1.0e-30;

    // --- Terminal voltages (raw, on internal nodes) ---
    const vgs = x[g].sub(x[sp]).scale(p.type_f);
    const vgd = x[g].sub(x[dp]).scale(p.type_f);
    const vgb = x[g].sub(x[b]).scale(p.type_f);
    const vbs = x[b].sub(x[sp]).scale(p.type_f);
    const vbd = x[b].sub(x[dp]).scale(p.type_f);

    // ========================================================================
    // Threshold voltage for charge model
    // ========================================================================
    // Reverse/forward bias sqrt(phi - vbs)
    const sqrt_phi_rev = vbs.neg().addC(p.phi_safe).maxC(1.0e-30).sqrt();
    const sqrt_phi_fwd = vbs.div(S.con(2.0 * p.phi_safe)).neg().addC(1.0).maxC(1.0e-30).scale(p.sqrt_phi);

    const abs_vbs = vbs.abs();
    const s_neg = vbs.neg().maxC(0.0).div(abs_vbs.addC(eps));
    const s_pos = vbs.maxC(0.0).div(abs_vbs.addC(eps));
    const sarg = sqrt_phi_rev.mul(s_neg).add(sqrt_phi_fwd.mul(s_pos));
    // When vbs == 0 use sqrt(phi) directly (voltage-value region selection,
    // as in the original)
    const sarg_safe: S = if (abs_vbs.val() < 1.0e-20) S.con(p.sqrt_phi) else sarg;

    const vth_q = sarg_safe.addC(-p.sqrt_phi).scale(p.gamma).addC(p.vto_adj);

    // On/off voltage for Meyer regions
    const von: S = if (p.has_nfs) vth_q.addC(p.vt) else vth_q;

    // ========================================================================
    // Gate overlap charges (scaled by weff/leff and multiplier)
    // ========================================================================
    const q_gs_ov = vgs.scale(p.cgso_w * p.m_mult);
    const q_gd_ov = vgd.scale(p.cgdo_w * p.m_mult);
    const q_gb_ov = vgb.scale(p.cgbo_l * p.m_mult);

    // ========================================================================
    // Meyer intrinsic gate charges (scaled by cox_eff * weff * leff)
    // ========================================================================
    // Effective overdrives
    const vgs_eff_meyer = vgs.sub(vth_q).maxC(0.0);
    const vgd_eff_meyer = vgd.sub(vth_q).maxC(0.0);

    // Accumulation region: Q_GB_Meyer = cox * min(vgs - von, 0)
    const q_gb_meyer = vgs.sub(von).minC(0.0).scale(p.cox_total * p.m_mult);

    // Gate-source (saturation + linear)
    const denom_gs = vgs_eff_meyer.scale(2.0).sub(vgd_eff_meyer).abs().addC(eps);
    const rd_meyer = vgd_eff_meyer.div(denom_gs);
    const q_gs_meyer = vgs_eff_meyer.mul(rd_meyer.mul(rd_meyer).neg().addC(1.0)).scale((2.0 / 3.0) * p.cox_total * p.m_mult);

    // Gate-drain (linear region)
    const denom_gd = vgd_eff_meyer.scale(2.0).sub(vgs_eff_meyer).abs().addC(eps);
    const rs_meyer = vgs_eff_meyer.div(denom_gd);
    const q_gd_meyer = vgd_eff_meyer.mul(rs_meyer.mul(rs_meyer).neg().addC(1.0)).scale((2.0 / 3.0) * p.cox_total * p.m_mult);

    // ========================================================================
    // Total gate charges
    // ========================================================================
    const q_gs_total = q_gs_ov.add(q_gs_meyer);
    const q_gd_total = q_gd_ov.add(q_gd_meyer);
    const q_gb_total = q_gb_ov.add(q_gb_meyer);

    // ========================================================================
    // Bulk junction depletion charges
    // ========================================================================
    const q_bs = junctionCharge(S, vbs, p.cbs0, p.*).scale(p.m_mult);
    const q_bd = junctionCharge(S, vbd, p.cbd0, p.*).scale(p.m_mult);

    // ========================================================================
    // KCL charge stamping
    // ========================================================================
    var out: [n_u]S = undefined;
    out[g] = q_gs_total.add(q_gd_total).add(q_gb_total);
    out[dp] = q_gd_total.neg().sub(q_bd);
    out[sp] = q_gs_total.neg().sub(q_bs);
    out[b] = q_gb_total.neg().add(q_bs).add(q_bd);
    out[@intFromEnum(U.drain)] = S.con(0.0);
    out[@intFromEnum(U.source)] = S.con(0.0);
    return out;
}

// ============================================================================
// Voltage Limiting (pnjlim + fetlim + limvds)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const is_val: f64 = @as(f64, model.is_);
    const vto: f64 = @as(f64, model.vto);
    const temp: f64 = @as(f64, instance.temp);
    const type_f: f64 = @floatFromInt(model.type_);

    // Thermal voltage uses device operating temperature, not tnom
    const vt: f64 = 8.617333e-5 * (temp + 273.15);

    // Critical voltage for pnjlim
    const v_crit = vt * @log(vt / (@sqrt(2.0) * is_val));

    var result = x_new;

    // ========================================================================
    // PN Junction Limiting on V_BS (bulk -- s_prime)
    // ========================================================================
    {
        const vbs_new = (x_new[b] - x_new[sp]) * type_f;
        const vbs_old = (x_old[b] - x_old[sp]) * type_f;

        var vbs_limited = vbs_new;
        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = (vbs_new - vbs_old) / vt;
                if (arg > 0.0) {
                    vbs_limited = vbs_old + vt * (2.0 + @log(@max(arg - 2.0, 1e-30)));
                } else {
                    vbs_limited = v_crit;
                }
            } else if (vbs_new > 0.0) {
                vbs_limited = vt * @log(@max(vbs_new / vt, 1e-30));
            } else {
                vbs_limited = v_crit;
            }
        }

        const delta_bs = (vbs_limited - vbs_new) * type_f;
        result[b] += delta_bs;
    }

    // ========================================================================
    // PN Junction Limiting on V_BD (bulk -- d_prime)
    // ========================================================================
    {
        const vbd_new = (result[b] - x_new[dp]) * type_f;
        const vbd_old = (x_old[b] - x_old[dp]) * type_f;

        var vbd_limited = vbd_new;
        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = (vbd_new - vbd_old) / vt;
                if (arg > 0.0) {
                    vbd_limited = vbd_old + vt * (2.0 + @log(@max(arg - 2.0, 1e-30)));
                } else {
                    vbd_limited = v_crit;
                }
            } else if (vbd_new > 0.0) {
                vbd_limited = vt * @log(@max(vbd_new / vt, 1e-30));
            } else {
                vbd_limited = v_crit;
            }
        }

        const delta_bd = (vbd_limited - vbd_new) * type_f;
        result[dp] -= delta_bd;
    }

    // ========================================================================
    // FET Gate Voltage Limiting (fetlim) on V_GS
    // ========================================================================
    {
        const vgs_new = (result[g] - result[sp]) * type_f;
        const vgs_old = (x_old[g] - x_old[sp]) * type_f;

        const vtsthi = @abs(2.0 * (vgs_old - vto)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const vtox = vto + 3.5;

        var vgs_fet = vgs_new;

        if (vgs_old >= vto) {
            if (vgs_old >= vtox) {
                // Region 1: V_old >= V_tox
                vgs_fet = @min(vgs_new, vgs_old + vtsthi);
                vgs_fet = @max(vgs_fet, vgs_old - vtstlo);
            } else {
                // Region 2: V_T0 <= V_old < V_tox
                vgs_fet = @min(vgs_new, vgs_old + vtsthi);
                vgs_fet = @max(vgs_fet, vto - 0.5);
            }
        } else {
            // Region 3: V_old < V_T0
            vgs_fet = @max(vgs_new, vgs_old - vtstlo);
            vgs_fet = @min(vgs_fet, vto + 0.5);
        }

        const delta_fet = (vgs_fet - vgs_new) * type_f;
        result[g] += delta_fet;
    }

    // ========================================================================
    // Drain-Source Voltage Limiting (limvds) on V_DS
    // ========================================================================
    {
        const vds_new = (result[dp] - result[sp]) * type_f;
        const vds_old = (x_old[dp] - x_old[sp]) * type_f;

        var vds_limited = vds_new;
        if (vds_old >= 3.5) {
            vds_limited = @max(vds_new, -0.5 * vds_old);
            vds_limited = @min(vds_limited, 2.0 * vds_old);
        } else {
            vds_limited = @min(vds_new, 4.0);
        }

        const delta_vds = (vds_limited - vds_new) * type_f;
        result[dp] += delta_vds;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// Source-stepping of junction saturation current at continuation factor lambda.
// At lambda=0: IS = 1e-12 (easy). At lambda=1: IS = model.is_ (physical).

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is_);
    const is_stepped = is_orig + (gmin_step - is_orig) * (1.0 - lambda);
    m.is_ = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Voltage order: { drain, gate, source, bulk, d_prime, s_prime }

test "mos3: saturation region drain current" {
    // vto=1, kp=2e-5, W=10u, L=1u, defaults otherwise (gamma=0, theta=0,
    // vmax=0, nsub=0 -> no CLM, nfs=0 -> sigmoid cutoff).
    // Bias: vgs=2, vds=2, vbs=0 (rd=rs=0 so internal nodes tied).
    //   beta   = kp*W/L = 2e-5 * 10 = 2e-4
    //   vth    = vbi = vto = 1;  von = vth = 1;  vgsx = max(2,1) = 2
    //   vdsat  = (vgsx-vth)/(1+0) = 1;  vdsx = min(2, 1) = 1
    //   cdo    = 2 - 1 - 0.5*1*1 = 0.5;  ids = beta*0.5*1 = 1e-4
    //   sigma  = 1/(1+exp(-100)) ~= 1
    //   i_bd   = is*(exp(-2/vt)-1) + gmin*(-2) ~= -1e-14 - 2e-12 = -2.01e-12
    //   i_bs   = is*(exp(0)-1) + 0 = 0
    //   out[dp] = ids - i_bd ~= 1e-4;  out[sp] = -ids;  out[b] = i_bd
    // (f32 storage of kp/w shifts ids to 9.999999721e-5; expected values below
    //  are the old pointer-form implementation evaluated at this exact point.)
    const model: Model = .{ .vto = 1.0, .kp = 2e-5 };
    const inst: Instance = .{ .w = 10e-6, .l = 1e-6 };
    const out = contract.evalValues(Self, .{ 2.0, 2.0, 0.0, 0.0, 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15); // drain (v_d == v_dp)
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-15); // gate
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15); // source
    try testing.expectApproxEqAbs(@as(f64, -2.0099999998245167e-12), out[3], 1e-18); // bulk
    try testing.expectApproxEqAbs(@as(f64, 9.999999721005081e-5), out[4], 1e-12); // d_prime
    try testing.expectApproxEqAbs(@as(f64, -9.999999520005082e-5), out[5], 1e-12); // s_prime
}

test "mos3: linear region drain current" {
    // Same device, vds=0.5 < vdsat=1:
    //   vdsx = 0.5;  cdo = 2 - 1 - 0.25 = 0.75;  ids = 2e-4*0.75*0.5 = 7.5e-5
    //   i_bd = -1e-14 - 0.5e-12 = -5.1e-13
    const model: Model = .{ .vto = 1.0, .kp = 2e-5 };
    const inst: Instance = .{ .w = 10e-6, .l = 1e-6 };
    const out = contract.evalValues(Self, .{ 0.5, 2.0, 0.0, 0.0, 0.5, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -5.099999997842851e-13), out[3], 1e-18); // bulk
    try testing.expectApproxEqAbs(@as(f64, 7.499999691003811e-5), out[4], 1e-12); // d_prime
    try testing.expectApproxEqAbs(@as(f64, -7.499999640003811e-5), out[5], 1e-12); // s_prime
}

test "mos3: full model (body effect, short channel, vmax, nfs, rd/rs)" {
    // Exercises series resistances, body effect with back bias, short-channel
    // Vth correction (xj+nsub), DIBL (eta), narrow width (delta), mobility
    // degradation (theta), velocity saturation (vmax), subthreshold slope
    // (nfs), and primary CLM (kappa+nsub). Expected values are the old
    // pointer-form implementation evaluated at this exact operating point:
    //   i_rd = (1.8-1.75)/10 = 5e-3,  i_rs = (0-0.02)/10 = -2e-3
    const model: Model = .{
        .vto = 0.7,
        .kp = 5e-5,
        .gamma = 0.5,
        .phi = 0.7,
        .nsub = 1e16,
        .nfs = 1e11,
        .vmax = 1.5e5,
        .xj = 0.3e-6,
        .kappa = 0.2,
        .theta = 0.05,
        .eta = 1.0,
        .delta = 0.5,
        .rd = 10,
        .rs = 10,
    };
    const inst: Instance = .{ .w = 5e-6, .l = 0.8e-6 };
    const out = contract.evalValues(Self, .{ 1.8, 1.5, 0.0, -0.3, 1.75, 0.02 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 5.0000000000000044e-3), out[0], 1e-12); // drain
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-15); // gate
    try testing.expectApproxEqAbs(@as(f64, -2e-3), out[2], 1e-12); // source
    try testing.expectApproxEqAbs(@as(f64, -2.3899999572922503e-12), out[3], 1e-18); // bulk
    try testing.expectApproxEqAbs(@as(f64, -2.6363148779706036e-3), out[4], 1e-11); // d_prime
    try testing.expectApproxEqAbs(@as(f64, -3.6368511963940064e-4), out[5], 1e-11); // s_prime
}

test "mos3: charge in accumulation with reverse-biased B-S junction" {
    // vto=1, kp=2e-5, cbs=1e-12, cgso=cgdo=1e-10, W=10u, L=1u.
    // Bias: all nodes 0 except bulk=-1 -> vgs=vgd=0, vgb=1, vbs=vbd=-1.
    //   vth_q = 1 (gamma=0);  von = 1;  vgs-von = -1 < 0 -> accumulation
    //   cox_eff  = kp/mu0_si = 2e-5/0.06 = 3.3333e-4
    //   cox_tot  = cox_eff*W*L = 3.3333e-15
    //   q_gb_mey = cox_tot*min(-1,0) = -3.3333e-15;  Meyer gs/gd = 0 (overdrive 0)
    //   overlap: q_gs_ov = q_gd_ov = 0 (vgs=vgd=0), q_gb_ov = 0 (cgbo=0)
    //   q_bs: x = 1-(-1)/0.8 = 2.25; q = (1e-12*0.8/0.5)*(1-2.25^0.5)
    //       = 1.6e-12*(1-1.5) = -8e-13   (vbs=-1 < fc*pb=0.4 -> depletion path)
    //   q_bd = 0 (cbd=0)
    //   out[g] = -3.3333e-15;  out[sp] = +8e-13;  out[b] = 3.3333e-15 - 8e-13
    const model: Model = .{ .vto = 1.0, .kp = 2e-5, .cbs = 1e-12, .cgso = 1e-10, .cgdo = 1e-10 };
    const inst: Instance = .{ .w = 10e-6, .l = 1e-6 };
    const out = contract.qValues(Self, .{ 0.0, 0.0, 0.0, -1.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-30); // drain
    try testing.expectApproxEqAbs(@as(f64, -3.3333331565033124e-15), out[1], 1e-22); // gate
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-30); // source
    try testing.expectApproxEqAbs(@as(f64, -7.966666656336757e-13), out[3], 1e-22); // bulk
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[4], 1e-22); // d_prime
    try testing.expectApproxEqAbs(@as(f64, 7.99999998790179e-13), out[5], 1e-22); // s_prime
}

test "mos3: charge in inversion with forward-biased B-S junction" {
    // vto=1, kp=2e-5, cbs=1e-12, cbd=2e-12, cgso=cgdo=1e-10, cgbo=1e-9.
    // Bias: d=dp=2, g=3, s=sp=0, b=0.5 -> vgs=3, vgd=1, vgb=2.5, vbs=0.5,
    // vbd=-1.5. vbs=0.5 > fc*pb=0.4 -> forward-bias extension path for Q_BS;
    // vbd on depletion path; gate in inversion (Meyer gs/gd charges active).
    // Expected values are the old pointer-form implementation at this point.
    const model: Model = .{ .vto = 1.0, .kp = 2e-5, .cbs = 1e-12, .cbd = 2e-12, .cgso = 1e-10, .cgdo = 1e-10, .cgbo = 1e-9 };
    const inst: Instance = .{ .w = 10e-6, .l = 1e-6 };
    const out = contract.qValues(Self, .{ 2.0, 3.0, 0.0, 0.5, 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.0944444084011588e-14), out[1], 1e-22); // gate
    try testing.expectApproxEqAbs(@as(f64, -1.6094746483332913e-12), out[3], 1e-22); // bulk
    try testing.expectApproxEqAbs(@as(f64, 2.2248639844212933e-12), out[4], 1e-22); // d_prime
    try testing.expectApproxEqAbs(@as(f64, -6.263337801720134e-13), out[5], 1e-22); // s_prime
}
