const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: ASM-HEMT 101.6.0 -- AlGaN/GaN High Electron Mobility Transistor
//
// Surface-potential-based compact model for AlGaN/GaN HEMTs.
//
// External terminals: gate (G), drain (D), source (S), bulk (B)
// Internal nodes:
//   gi  -- intrinsic gate   (behind Rg, when RGATEMOD>0)
//   di  -- intrinsic drain  (behind Rd access resistance)
//   si  -- intrinsic source (behind Rs access resistance)
//   dt  -- thermal node     (self-heating, SHMOD=1)
//   t1  -- trap node 1      (TRAPMOD=1..5)
//   t2  -- trap node 2      (TRAPMOD=2,4,5)
//
// The intrinsic device includes:
//   - Surface-potential channel current (drift-diffusion)
//   - Field plate sub-transistors (FP1-FP4 drain-side, FP1S-FP4S source-side)
//   - Gate diode currents (GATEMOD 0-4)
//   - Drain-source breakdown
//   - Substrate leakage (source-sub, drain-sub)
//   - Self-heating RC network
//   - Trap RC sub-circuits
//   - Intrinsic + overlap + fringing + substrate capacitances
//   - Flicker and thermal noise
// ============================================================================

pub const U = enum(u8) {
    gate, // 0 - external gate
    drain, // 1 - external drain
    source, // 2 - external source
    bulk, // 3 - external substrate
    gi, // 4 - intrinsic gate (after Rg)
    di, // 5 - intrinsic drain (after Rd)
    si, // 6 - intrinsic source (after Rs)
    dt, // 7 - thermal node (self-heating)
    t1, // 8 - trap node 1
    t2, // 9 - trap node 2
};
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================

const Q_ELECTRON: f64 = 1.6e-19;
const KB_EV: f64 = 8.636e-5; // eV/K
const KB_J: f64 = 1.380649e-23; // J/K
const DOS_CONST: f64 = 3.24e17; // m^-2 eV^-1
const EPPSI: f64 = 0.3; // smoothing constant
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const EXP_MAX: f64 = 80.0;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Process Parameters ---
    tnom: f32 = 27.0,
    tbar: f32 = 2.5e-8,
    tepi: f32 = 1.64e-6,
    epsilon: f32 = 10.66e-11,
    gamma0i: f32 = 2.12e-12,
    gamma1i: f32 = 3.73e-12,
    lsg: f32 = 1e-6,
    ldg: f32 = 1e-6,

    // --- Model Controllers ---
    rdsmod: i32 = 0,
    gatemod: i32 = 0,
    shmod: i32 = 1,
    trapmod: i32 = 0,
    fnmod: i32 = 0,
    tnmod: i32 = 0,
    fp1mod: i32 = 0,
    fp2mod: i32 = 0,
    fp3mod: i32 = 0,
    fp4mod: i32 = 0,
    fp1smod: i32 = 0,
    fp2smod: i32 = 0,
    fp3smod: i32 = 0,
    fp4smod: i32 = 0,
    rgatemod: i32 = 0,
    fastfpmod: i32 = 0,

    // --- Basic Model Parameters ---
    voff: f32 = -2.0,
    asub: f32 = 0.0,
    u0: f32 = 170e-3,
    ua: f32 = 0.0,
    ub: f32 = 0.0,
    uc: f32 = 0.0,
    vsat: f32 = 1.9e5,
    delta: f32 = 2.0,
    lambda: f32 = 0.0,
    eta0: f32 = 1e-9,
    vdscale: f32 = 5.0,
    thesat: f32 = 1.0,
    nfactor: f32 = 0.5,
    cdscd: f32 = 1e-3,
    imin: f32 = 1e-15,
    gdsmin: f32 = 1e-12,
    tgdsmin: f32 = 0.0,

    // --- Access Region Resistance Parameters ---
    vsataccs: f32 = 50e3,
    ns0accs: f32 = 5e17,
    ns0accd: f32 = 5e17,
    k0accs: f32 = 0.0,
    k0accd: f32 = 0.0,
    ksub: f32 = 0.0,
    u0accs: f32 = 155e-3,
    u0accd: f32 = 155e-3,
    mexpaccs: f32 = 2.0,
    mexpaccd: f32 = 2.0,
    ars: f32 = 1.0,
    ard: f32 = 1.0,
    rsc: f32 = 1e-4,
    rdc: f32 = 1e-4,

    // --- Gate Current Parameters ---
    igsdio: f32 = 1e-12,
    njgs: f32 = 2.5,
    igddio: f32 = 1e-12,
    njgd: f32 = 2.5,
    ktgs: f32 = 0.0,
    ktgd: f32 = 0.0,
    rigsdio: f32 = 1e-15,
    rnjgs: f32 = 80.0,
    rigddio: f32 = 1e-15,
    rnjgd: f32 = 80.0,
    rktgs: f32 = 0.0,
    rktgd: f32 = 0.0,
    ebreaks: f32 = 0.0,
    ebreakd: f32 = 0.0,
    ags: f32 = 1.0,
    agd: f32 = 1.0,
    vbis: f32 = 1e-4,
    vbid: f32 = 1e-4,
    ktvbis: f32 = 0.0,
    ktvbid: f32 = 0.0,
    ktnjgs: f32 = 0.0,
    ktnjgd: f32 = 0.0,
    ktrnjgs: f32 = 0.0,
    ktrnjgd: f32 = 0.0,

    // --- Trap Model Parameters -- TRAPMOD=1 (RF Trap) ---
    cdlag: f32 = 1e-6,
    rdlag: f32 = 1e6,
    idio: f32 = 1.0,
    atrapvoff: f32 = 0.1,
    btrapvoff: f32 = 0.3,
    atrapeta0: f32 = 0.0,
    btrapeta0: f32 = 0.05,
    atraprs: f32 = 0.1,
    btraprs: f32 = 0.6,
    atraprd: f32 = 0.5,
    btraprd: f32 = 0.6,

    // --- Trap Model Parameters -- TRAPMOD=2 (Pulsed IV) ---
    rtrap1: f32 = 1.0,
    rtrap2: f32 = 1.0,
    ctrap1: f32 = 10e-6,
    ctrap2: f32 = 1e-6,
    a1_trap: f32 = 0.1,
    vofftr: f32 = 1e-9,
    cdscdtr: f32 = 1e-15,
    eta0tr: f32 = 1e-15,
    rontr1: f32 = 1e-12,
    rontr2: f32 = 1e-13,
    rontr3: f32 = 1e-13,

    // --- Trap Model Parameters -- TRAPMOD=3 (Dynamic Ron) ---
    rtrap3: f32 = 1.0,
    ctrap3: f32 = 1e-4,
    vatrap: f32 = 10.0,
    vdlr1: f32 = 2.0,
    vdlr2: f32 = 20.0,
    wd: f32 = 0.016,
    vtb: f32 = 250.0,
    sct: f32 = 1.0,
    deltax: f32 = 0.01,

    // --- Trap Model Parameters -- TRAPMOD=4 (Separate DL/GL) ---
    remi: f32 = 1.0,
    cglag: f32 = 10e-6,
    remig: f32 = 1.0,
    arcap: f32 = 0.0,
    brcap: f32 = 0.5,
    arcapg: f32 = 0.0,
    brcapg: f32 = 0.5,
    vdlmax: f32 = 20.0,
    vglmax: f32 = 5.0,
    dlvoff: f32 = 0.0,
    glvoff: f32 = 0.0,
    glu0: f32 = 0.0,
    glvsat: f32 = 0.0,
    dlns0s: f32 = 0.0,
    dlns0d: f32 = 0.0,

    // --- Trap Model Parameters -- TRAPMOD=5 (SRH Dynamic) ---
    alphax: f32 = 0.0,
    alphaxd: f32 = 0.0,
    betax: f32 = 0.05,
    gammax: f32 = 0.0,
    etax: f32 = 0.0,
    eno: f32 = 1e4,
    cx: f32 = 1e-7,
    vxmax: f32 = 0.5,
    ea: f32 = 0.5,
    alphay: f32 = 0.0,
    alphayd: f32 = 0.0,
    betay: f32 = 0.05,
    gammay: f32 = 0.0,
    etay: f32 = 0.0,
    eno1: f32 = 1e4,
    cy: f32 = 1e-7,
    vymax: f32 = 0.5,
    ea1: f32 = 0.5,
    glns0s: f32 = 0.0,
    glns0d: f32 = 0.0,

    // --- Field Plate Parameters -- FP1 ---
    iminfp1: f32 = 1e-15,
    vofffp1: f32 = -25.0,
    ktfp1: f32 = 50e-3,
    u0fp1: f32 = 100e-3,
    vsatfp1: f32 = 100e3,
    nfactorfp1: f32 = 0.5,
    cdscdfp1: f32 = 0.0,
    eta0fp1: f32 = 1e-9,
    vdscalefp1: f32 = 10.0,
    gamma0fp1: f32 = 2.12e-12,
    gamma1fp1: f32 = 3.73e-12,

    // --- Field Plate Parameters -- FP2 ---
    iminfp2: f32 = 1e-15,
    vofffp2: f32 = -80.0,
    ktfp2: f32 = 50e-3,
    u0fp2: f32 = 100e-3,
    vsatfp2: f32 = 100e3,
    nfactorfp2: f32 = 0.5,
    cdscdfp2: f32 = 0.0,
    eta0fp2: f32 = 1e-9,
    vdscalefp2: f32 = 10.0,
    gamma0fp2: f32 = 2.12e-12,
    gamma1fp2: f32 = 3.73e-12,

    // --- Field Plate Parameters -- FP3 ---
    iminfp3: f32 = 1e-15,
    vofffp3: f32 = -75.0,
    ktfp3: f32 = 50e-3,
    u0fp3: f32 = 100e-3,
    vsatfp3: f32 = 100e3,
    nfactorfp3: f32 = 0.5,
    cdscdfp3: f32 = 0.0,
    eta0fp3: f32 = 1e-9,
    vdscalefp3: f32 = 10.0,
    gamma0fp3: f32 = 2.12e-12,
    gamma1fp3: f32 = 3.73e-12,

    // --- Field Plate Parameters -- FP4 ---
    iminfp4: f32 = 1e-15,
    vofffp4: f32 = -100.0,
    ktfp4: f32 = 50e-3,
    u0fp4: f32 = 100e-3,
    vsatfp4: f32 = 100e3,
    nfactorfp4: f32 = 0.5,
    cdscdfp4: f32 = 0.0,
    eta0fp4: f32 = 1e-9,
    vdscalefp4: f32 = 10.0,
    gamma0fp4: f32 = 2.12e-12,
    gamma1fp4: f32 = 3.73e-12,

    // --- Capacitance Parameters ---
    cgso: f32 = 10e-15,
    cgdo: f32 = 10e-15,
    cdso: f32 = 10e-15,
    cgdl: f32 = 0.0,
    vdsatcv: f32 = 100.0,
    cbdo: f32 = 0.0,
    cbso: f32 = 0.0,
    cbgo: f32 = 0.0,
    cfg: f32 = 0.0,
    cfd: f32 = 0.0,
    cfgd: f32 = 0.0,
    cfgdsm: f32 = 1e-24,
    cfgd0: f32 = 0.0,
    cj0: f32 = 0.0,
    vbi: f32 = 0.9,
    mz: f32 = 0.5,
    aj: f32 = 100e-3,
    dj: f32 = 1.0,

    // --- Quantum Mechanical Effect Parameters ---
    adosi: f32 = 0.0,
    bdosi: f32 = 1.0,
    qm0i: f32 = 1e-3,
    adosfp1: f32 = 0.0,
    bdosfp1: f32 = 1.0,
    qm0fp1: f32 = 1e-3,
    adosfp2: f32 = 0.0,
    bdosfp2: f32 = 1.0,
    qm0fp2: f32 = 1e-3,
    adosfp3: f32 = 0.0,
    bdosfp3: f32 = 1.0,
    qm0fp3: f32 = 1e-3,
    adosfp4: f32 = 0.0,
    bdosfp4: f32 = 1.0,
    qm0fp4: f32 = 1e-3,

    // --- Cross-Coupling & Substrate Capacitance ---
    cfp1scale: f32 = 0.0,
    cfp2scale: f32 = 0.0,
    cfp3scale: f32 = 0.0,
    cfp4scale: f32 = 0.0,
    csubscalei: f32 = 0.0,
    csubscale1: f32 = 0.0,
    csubscale2: f32 = 0.0,
    csubscale3: f32 = 0.0,
    csubscale4: f32 = 0.0,

    // --- Gate Resistance Parameters ---
    xgw: f32 = 0.0,
    rshg: f32 = 1e-3,

    // --- Noise Model Parameters ---
    noia: f32 = 15e-12,
    noib: f32 = 0.0,
    noic: f32 = 0.0,
    ef: f32 = 1.0,
    tnsc: f32 = 1e27,

    // --- Drain-Source Breakdown Parameters ---
    bvdsl: f32 = 200.0,
    asl: f32 = 0.0,
    nsl: f32 = 10.0,
    kasl: f32 = 0.0,
    knsl: f32 = 0.0,
    kbvdsl: f32 = 0.0,

    // --- Temperature & Self-Heating Parameters ---
    at: f32 = 0.0,
    ute: f32 = -0.5,
    kt1: f32 = 0.0,
    kns0: f32 = 0.0,
    ats: f32 = 0.0,
    utes: f32 = 0.0,
    uted: f32 = 0.0,
    krsc: f32 = 0.0,
    krdc: f32 = 0.0,
    ktvbi: f32 = 0.0,
    ktcfg: f32 = 0.0,
    ktcfgd: f32 = 0.0,
    rth0: f32 = 5.0,
    cth0: f32 = 1e-9,
    talpha: f32 = 1.0,
    dtemp_m: f32 = 0.0,

    // --- Substrate Leakage Parameters ---
    isbl: f32 = 0.0,
    nsb: f32 = 100.0,
    vbisb: f32 = 50.0,
    idbl: f32 = 0.0,
    ndb: f32 = 100.0,
    vbidb: f32 = 50.0,
    ktisb: f32 = 0.0,
    ktidb: f32 = 0.0,
    ktnsb: f32 = 0.0,
    ktndb: f32 = 0.0,
    ktvbisb: f32 = 0.0,
    ktvbidb: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 0.25e-6,
    w: f32 = 200e-6,
    nf: i32 = 1,
    mult_i: f32 = 1.0,
    mult_q: f32 = 1.0,
    mult_fn: f32 = -1.0, // sentinel: if <0, use mult_i
    dfp1: f32 = 50e-9,
    lfp1: f32 = 1e-6,
    dfp2: f32 = 100e-9,
    lfp2: f32 = 1e-6,
    dfp3: f32 = 150e-9,
    lfp3: f32 = 1e-6,
    dfp4: f32 = 200e-9,
    lfp4: f32 = 1e-6,
    ngcon: i32 = 1,
    dtemp: f32 = 0.0,
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: di -- si
    .{ .row = @intFromEnum(U.di), .col = @intFromEnum(U.si), .kind = .thermal },
    // Channel flicker noise: di -- si
    .{ .row = @intFromEnum(U.di), .col = @intFromEnum(U.si), .kind = .flicker },
    // Gate-source shot noise: gi -- si
    .{ .row = @intFromEnum(U.gi), .col = @intFromEnum(U.si), .kind = .shot },
    // Gate-drain shot noise: gi -- di
    .{ .row = @intFromEnum(U.gi), .col = @intFromEnum(U.di), .kind = .shot },
};

// ============================================================================
// Helper: compute surface potential Vf given Vg0, Vg0_eff, Cg, gamma0, gamma1,
// Vtv, and the Boltzmann beta. Returns Vf.
// This implements the unified expression (Eq 3.4.20) plus Householder (3.4.21).
//
// Value-form: vg0, vg0_eff, vtv are x-dependent (S); cg, gam0, gam1, beta_sp
// are pure params (f64).
// ============================================================================

fn surfacePotential(
    comptime S: type,
    vg0: S,
    vg0_eff: S,
    cg: f64,
    gam0: f64,
    gam1: f64,
    vtv: S,
    beta_sp: f64,
) S {
    // H(Vg0) -- Eq 3.4.18
    const cg_over_q = cg / Q_ELECTRON;
    const vg0n = vg0_eff.maxC(1e-30);
    const vg0d = vg0_eff.maxC(1e-30);
    const cg_vg0_over_q = vg0_eff.scale(cg_over_q);
    // |cg_vg0_over_q|^(2/3)
    const cg_vg0_q_23 = cg_vg0_over_q.abs().maxC(1e-38).pow(2.0 / 3.0);
    const gam0_term = cg_vg0_q_23.scale(gam0);

    // h_num = vg0_eff + vtv*(1 - log(max(beta*vg0n,1e-38))) - gam0_term/3
    const h_num = vg0_eff
        .add(vtv.mul(vg0n.scale(beta_sp).maxC(1e-38).log().neg().addC(1.0)))
        .sub(gam0_term.scale(1.0 / 3.0));
    // h_den = vg0_eff*(1 + vtv/vg0d) + (2/3)*gam0_term
    const h_den = vg0_eff.mul(vtv.div(vg0d).addC(1.0))
        .add(gam0_term.scale(2.0 / 3.0));
    const h_val = h_num.div(h_den.maxC(1e-38));

    // Unified Vf -- Eq 3.4.20
    const exp_half = vg0.div(vtv.scale(2.0)).minC(EXP_MAX).exp();
    const ln_term = exp_half.addC(1.0).log().scale(2.0).mul(vtv);
    const cg_dos_term = exp_half.scale(cg / (Q_ELECTRON * DOS_CONST));
    const inv_h = S.con(1.0).div(h_val.maxC(1e-38));
    const denom = cg_dos_term.add(inv_h);
    const vf_unified = vg0.sub(ln_term.div(denom.maxC(1e-38)));

    // Householder correction -- Eq 3.4.21
    // Compute k0, k1 (pure f64 -- params only)
    const k0 = gam0 * @exp((2.0 / 3.0) * @log(@max(cg_over_q, 1e-38)));
    const k1 = gam1 * @exp((2.0 / 3.0) * @log(@max(cg_over_q, 1e-38)));

    const ef_unified = vf_unified;
    const vgef = vg0_eff.sub(ef_unified).maxC(1e-30);
    const vgef_23 = vgef.pow(2.0 / 3.0);
    const vgef_13 = vgef.pow(1.0 / 3.0);
    const vgef_m13 = S.con(1.0).div(vgef_13.maxC(1e-38));
    const vgef_m43 = vgef_m13.div(vgef.maxC(1e-38));

    // xi0 = exp(min((ef - k0*vgef_23)/vtv, EXP_MAX))
    const xi0 = ef_unified.sub(vgef_23.scale(k0)).div(vtv).minC(EXP_MAX).exp();
    const xi1 = ef_unified.sub(vgef_23.scale(k1)).div(vtv).minC(EXP_MAX).exp();

    // p = cg_over_q*vgef - DOS*vtv*(log(xi0+1) + log(xi1+1))
    const p_val = vgef.scale(cg_over_q)
        .sub(vtv.mul(xi0.addC(1.0).log().add(xi1.addC(1.0).log())).scale(DOS_CONST));

    // q (derivative)
    // frac0 = 1/(1 + 1/max(xi0,1e-38))
    const frac0 = S.con(1.0).div(S.con(1.0).div(xi0.maxC(1e-38)).addC(1.0));
    const frac1 = S.con(1.0).div(S.con(1.0).div(xi1.maxC(1e-38)).addC(1.0));
    // term0_q = DOS*frac0*(1 + (2/3)*k0*vgef_m13)
    const term0_q = frac0.mul(vgef_m13.scale((2.0 / 3.0) * k0).addC(1.0)).scale(DOS_CONST);
    const term1_q = frac1.mul(vgef_m13.scale((2.0 / 3.0) * k1).addC(1.0)).scale(DOS_CONST);
    const q_val = term0_q.add(term1_q).neg().addC(-cg_over_q);

    // r (second derivative for Householder)
    // deriv0 = 1 + (2/3)*k0*vgef_m13
    const deriv0 = vgef_m13.scale((2.0 / 3.0) * k0).addC(1.0);
    const deriv1 = vgef_m13.scale((2.0 / 3.0) * k1).addC(1.0);
    // inv0 = 1 + 1/max(xi0,1e-38)
    const inv0 = S.con(1.0).div(xi0.maxC(1e-38)).addC(1.0);
    const inv1 = S.con(1.0).div(xi1.maxC(1e-38)).addC(1.0);
    // r0_num = DOS*k0*inv0 + (DOS/vtv)*deriv0^2*(2/9)*vgef_m43
    const r0_num = inv0.scale(DOS_CONST * k0)
        .add(deriv0.mul(deriv0).mul(vgef_m43).scale(2.0 / 9.0).mul(S.con(DOS_CONST).div(vtv)));
    const r0_den = inv0.mul(inv0);
    const r1_num = inv1.scale(DOS_CONST * k1)
        .add(deriv1.mul(deriv1).mul(vgef_m43).scale(2.0 / 9.0).mul(S.con(DOS_CONST).div(vtv)));
    const r1_den = inv1.mul(inv1);
    const r_val = r0_num.div(r0_den.maxC(1e-38)).add(r1_num.div(r1_den.maxC(1e-38)));

    // Householder step
    const pr = p_val.mul(r_val);
    const two_q = q_val.scale(2.0);
    // hh_denom = 1 + (p/two_q)*(r/two_q)
    const hh_denom = p_val.div(two_q.maxC(1e-38)).mul(r_val.div(two_q.maxC(1e-38))).addC(1.0);
    const vf = vf_unified.sub(pr.div(q_val.mul(hh_denom).maxC(1e-38)));

    return vf;
}

// ============================================================================
// Helper: field-plate sub-transistor CHARGE contributions for one FP region.
// Returns intrinsic gate/drain charge plus cross-coupling and substrate cap
// charge terms. Value-form translation of the original f64 FP charge block
// (Eq 3.5.3/3.5.8 gate/drain, Eq 3.14.1-2 cross-coupling, Eq 3.14.3 substrate,
// Eq 3.14.4 QME).
// ============================================================================

fn fpCharge(
    comptime S: type,
    args: struct {
        cg_raw: f64,
        l_fp: f64,
        w: f64,
        dfp: f64,
        voff_qt: S,
        nfactor_fp: f64,
        cdscd_fp: f64,
        vdscale_fp: f64,
        eta0_fp: f64,
        mob0_fp: f64,
        vsat_fp: f64,
        gamma0_fp: f64,
        gamma1_fp: f64,
        ados: f64,
        bdos: f64,
        qm0: f64,
        cfpscale: f64,
        csubscale: f64,
        vgs_fp: S,
        vds_i: S,
        vdsx: S,
        tdev: S,
        vtk: S,
        delta_m: f64,
        eps_algan: f64,
    },
) struct { qg: S, qd: S, qcc: S, qsub: S } {
    const cg_raw = args.cg_raw;
    const l_fp = args.l_fp;
    const w = args.w;
    const delta_m = args.delta_m;

    // cdsc = 1 + nfactor + cdscd*vdsx
    const cdsc_fp = args.vdsx.scale(args.cdscd_fp).addC(1.0 + args.nfactor_fp);
    const vtv_fp = args.tdev.mul(cdsc_fp).scale(KB_EV);

    // DIBL-adjusted Voff
    const vdscale_sm_fp = args.vdsx.scale(args.vdscale_fp)
        .div(args.vdsx.mul(args.vdsx).addC(args.vdscale_fp * args.vdscale_fp).sqrt());
    const voff_dibl_fp = vdscale_sm_fp.scale(args.eta0_fp).neg().add(args.voff_qt);

    // vgs_min = voff_dibl + vtv*log(max(l/(2*w*q*DOS*vtv^2), 1e-38))
    const log_arg_fp = vtv_fp.mul(vtv_fp).scale(2.0 * w * Q_ELECTRON * DOS_CONST);
    const vgs_min_fp = voff_dibl_fp.add(vtv_fp.mul(
        S.con(l_fp).div(log_arg_fp).maxC(1e-38).log(),
    ));
    const vgs_diff_fp = args.vgs_fp.sub(vgs_min_fp);
    const vgs_eff_fp = vgs_diff_fp.add(vgs_diff_fp.mul(vgs_diff_fp).addC(0.0001).sqrt()).scale(0.5);
    const vg0_fp = vgs_eff_fp.sub(voff_dibl_fp);
    const vg0_eff_fp = vg0_fp.add(vg0_fp.mul(vg0_fp).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5);

    // Saturation / effective drain voltage
    const two_vsat_l_fp = 2.0 * args.vsat_fp / @max(args.mob0_fp, 1e-38) * l_fp; // f64
    const vdsat_fp = vg0_eff_fp.scale(two_vsat_l_fp).div(vg0_eff_fp.addC(two_vsat_l_fp));
    const vds_vdsat_fp = args.vds_i.div(vdsat_fp.maxC(1e-30));
    const vds_vdsat_pow_fp = vds_vdsat_fp.abs().maxC(1e-38).pow(delta_m);
    const vd_eff_fp = args.vds_i.div(vds_vdsat_pow_fp.addC(1.0).log().scale(1.0 / delta_m).exp());

    // Surface potentials
    const beta_sp_fp = cg_raw / (Q_ELECTRON * DOS_CONST * KB_EV * args.tdev.val()); // f64
    const psi_s_fp = surfacePotential(S, vg0_fp, vg0_eff_fp, cg_raw, args.gamma0_fp, args.gamma1_fp, vtv_fp, beta_sp_fp);
    const vgd0_fp = vg0_fp.sub(vd_eff_fp);
    const vgd_eff_fp = vgd0_fp.add(vgd0_fp.mul(vgd0_fp).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5);
    const vf_d_fp = surfacePotential(S, vgd0_fp, vgd_eff_fp, cg_raw, args.gamma0_fp, args.gamma1_fp, vtv_fp, beta_sp_fp);
    const psi_d_fp = vf_d_fp.add(vd_eff_fp);
    const psi_m_fp = psi_d_fp.add(psi_s_fp).scale(0.5);

    // QME -- Eq 3.14.4
    const qg_approx_fp = vg0_fp.sub(psi_m_fp).abs().scale(cg_raw);
    const qme_denom_fp = qg_approx_fp.scale(1.0 / args.qm0).addC(1.0);
    const qme_factor_fp = qme_denom_fp.maxC(1e-38).log().scale(args.bdos).exp().pow(-1.0).scale(args.ados);
    const cg_eff_fp = qme_factor_fp.addC(args.dfp).pow(-1.0).scale(args.eps_algan);

    // Gate charge -- Eq 3.5.3
    const vg0_pm_vtv_fp = vg0_fp.sub(psi_m_fp).add(vtv_fp);
    // numerator: vg0^2 + (1/3)(psi_d^2 + psi_s^2 + psi_d*psi_s)
    //            - vg0*(psi_d + psi_s - vtv) - vtv*psi_m
    const qg_num_fp = vg0_fp.mul(vg0_fp)
        .add(psi_d_fp.mul(psi_d_fp).add(psi_s_fp.mul(psi_s_fp)).add(psi_d_fp.mul(psi_s_fp)).scale(1.0 / 3.0))
        .sub(vg0_fp.mul(psi_d_fp.add(psi_s_fp).sub(vtv_fp)))
        .sub(vtv_fp.mul(psi_m_fp));
    const qg_fp = cg_eff_fp.scale(l_fp * w).mul(qg_num_fp).div(vg0_pm_vtv_fp.maxC(1e-38));

    // Drain charge -- Eq 3.5.8
    const vg0_pm_vtv_fp_sq = vg0_pm_vtv_fp.mul(vg0_pm_vtv_fp);
    const pd = psi_d_fp;
    const ps = psi_s_fp;
    const vt = vtv_fp;
    const vg = vg0_fp;
    // qd_num = 12*pd^3 + 8*ps^3
    //   + ps^2*(16*pd - 5*(vt + 8*vg))
    //   + 2*ps*(12*pd^2 - 5*pd*(5*vt + 8*vg) + 10*(vt + vg)*(vt + 4*vg))
    //   + 15*pd^2*(3*vt + 4*vg) - 60*vg*(vt + vg)^2
    //   + 20*pd*(vt + vg)*(2*vt + 5*vg)
    const vt_vg = vt.add(vg);
    const qd_num_fp = pd.mul(pd).mul(pd).scale(12.0)
        .add(ps.mul(ps).mul(ps).scale(8.0))
        .add(ps.mul(ps).mul(pd.scale(16.0).sub(vt.add(vg.scale(8.0)).scale(5.0))))
        .add(ps.scale(2.0).mul(
            pd.mul(pd).scale(12.0)
                .sub(pd.mul(vt.scale(5.0).add(vg.scale(8.0))).scale(5.0))
                .add(vt_vg.mul(vt.add(vg.scale(4.0))).scale(10.0)),
        ))
        .add(pd.mul(pd).mul(vt.scale(3.0).add(vg.scale(4.0))).scale(15.0))
        .sub(vg.mul(vt_vg).mul(vt_vg).scale(60.0))
        .add(pd.mul(vt_vg).mul(vt.scale(2.0).add(vg.scale(5.0))).scale(20.0));
    const qd_fp = cg_eff_fp.scale(-l_fp * w).mul(qd_num_fp)
        .div(vg0_pm_vtv_fp_sq.maxC(1e-38).scale(120.0));

    // Cross-coupling -- Eq 3.14.1-2
    const psi_ds_fp = psi_d_fp.sub(psi_s_fp);
    const cc_denom_fp = vg0_fp.sub(args.vtk).sub(psi_m_fp).maxC(1e-38).scale(12.0);
    const cc_body = vg0_fp.sub(psi_m_fp).add(psi_ds_fp.mul(psi_ds_fp).div(cc_denom_fp));
    const qcc = cg_eff_fp.scale(-args.cfpscale * w * l_fp).mul(cc_body);

    // Substrate cap -- Eq 3.14.3
    const qsub = cg_eff_fp.scale(-args.csubscale * w * l_fp).mul(cc_body);

    return .{ .qg = qg_fp, .qd = qd_fp, .qcc = qcc, .qsub = qsub };
}

// ============================================================================
// Bias-independent (x-independent) precomputed quantities.
// Everything here is pure f64 param/geometry/temperature prep.
// ============================================================================

const Prep = struct {
    // temperature
    tnom_k: f64,
    t_ambient: f64,
    // geometry / process
    cg: f64,
    cepi: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    const tnom: f64 = @as(f64, model.tnom);
    const tbar: f64 = @as(f64, model.tbar);
    const tepi: f64 = @as(f64, model.tepi);
    const eps_algan: f64 = @as(f64, model.epsilon);
    const dtemp_inst: f64 = @as(f64, instance.dtemp);
    const dtemp_mod: f64 = @as(f64, model.dtemp_m);

    const tnom_k = tnom + 273.15;
    const t_ambient = tnom_k + dtemp_inst + dtemp_mod;

    const cg = eps_algan / tbar; // Eq 3.2.14
    const cepi = eps_algan / tepi; // Eq 3.2.16

    return .{
        .tnom_k = tnom_k,
        .t_ambient = t_ambient,
        .cg = cg,
        .cepi = cepi,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// DC Current Function (eval) -- value form
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const G = @intFromEnum(U.gate);
    const D = @intFromEnum(U.drain);
    const Ss = @intFromEnum(U.source);
    const B = @intFromEnum(U.bulk);
    const GI = @intFromEnum(U.gi);
    const DI = @intFromEnum(U.di);
    const SI = @intFromEnum(U.si);
    const DT = @intFromEnum(U.dt);
    const T1 = @intFromEnum(U.t1);
    const T2 = @intFromEnum(U.t2);

    // ====================================================================
    // Cast model parameters to f64 (x-independent)
    // ====================================================================
    _ = model.tnom; // tnom_k comes from prep()
    const tbar: f64 = @as(f64, model.tbar);
    const eps_algan: f64 = @as(f64, model.epsilon);
    const gamma0: f64 = @as(f64, model.gamma0i);
    const gamma1: f64 = @as(f64, model.gamma1i);
    const lsg: f64 = @as(f64, model.lsg);
    const ldg: f64 = @as(f64, model.ldg);

    const voff: f64 = @as(f64, model.voff);
    _ = model.asub; // ASUB not used in Eq 3.3.4 per spec
    const mob0: f64 = @as(f64, model.u0);
    const ua: f64 = @as(f64, model.ua);
    const ub: f64 = @as(f64, model.ub);
    const uc: f64 = @as(f64, model.uc);
    const vsat_m: f64 = @as(f64, model.vsat);
    const delta_m: f64 = @as(f64, model.delta);
    const lambda_m: f64 = @as(f64, model.lambda);
    const eta0: f64 = @as(f64, model.eta0);
    const vdscale: f64 = @as(f64, model.vdscale);
    _ = model.thesat; // THESAT computed as mu_eff/(VSAT*L) per Eq 3.9.2
    const nfactor: f64 = @as(f64, model.nfactor);
    const cdscd_m: f64 = @as(f64, model.cdscd);
    const imin: f64 = @as(f64, model.imin);
    const gdsmin: f64 = @as(f64, model.gdsmin);
    const tgdsmin: f64 = @as(f64, model.tgdsmin);

    // Access resistance
    const vsataccs: f64 = @as(f64, model.vsataccs);
    const ns0accs: f64 = @as(f64, model.ns0accs);
    _ = model.ns0accd; // Eq 3.3.10 uses NS0ACCS as base per spec
    const k0accs: f64 = @as(f64, model.k0accs);
    const k0accd: f64 = @as(f64, model.k0accd);
    const ksub: f64 = @as(f64, model.ksub);
    const mob_accs: f64 = @as(f64, model.u0accs);
    const mob_accd: f64 = @as(f64, model.u0accd);
    const mexpaccs: f64 = @as(f64, model.mexpaccs);
    const mexpaccd: f64 = @as(f64, model.mexpaccd);
    const ars_m: f64 = @as(f64, model.ars);
    const ard_m: f64 = @as(f64, model.ard);
    const rsc: f64 = @as(f64, model.rsc);
    const rdc: f64 = @as(f64, model.rdc);

    // Gate current
    const igsdio: f64 = @as(f64, model.igsdio);
    const njgs: f64 = @as(f64, model.njgs);
    const igddio: f64 = @as(f64, model.igddio);
    const njgd: f64 = @as(f64, model.njgd);
    const ktgs: f64 = @as(f64, model.ktgs);
    const ktgd: f64 = @as(f64, model.ktgd);
    const rigsdio: f64 = @as(f64, model.rigsdio);
    const rnjgs: f64 = @as(f64, model.rnjgs);
    const rigddio: f64 = @as(f64, model.rigddio);
    const rnjgd: f64 = @as(f64, model.rnjgd);
    const rktgs: f64 = @as(f64, model.rktgs);
    const rktgd: f64 = @as(f64, model.rktgd);
    const ebreaks: f64 = @as(f64, model.ebreaks);
    const ebreakd: f64 = @as(f64, model.ebreakd);
    const ags_m: f64 = @as(f64, model.ags);
    const agd_m: f64 = @as(f64, model.agd);
    const vbis_m: f64 = @as(f64, model.vbis);
    const vbid_m: f64 = @as(f64, model.vbid);
    const ktvbis: f64 = @as(f64, model.ktvbis);
    const ktvbid: f64 = @as(f64, model.ktvbid);
    const ktnjgs: f64 = @as(f64, model.ktnjgs);
    const ktnjgd: f64 = @as(f64, model.ktnjgd);
    const ktrnjgs: f64 = @as(f64, model.ktrnjgs);
    const ktrnjgd: f64 = @as(f64, model.ktrnjgd);

    // Trap parameters (TRAPMOD=1) -- cdlag used only in q function
    const rdlag: f64 = @as(f64, model.rdlag);
    const idio: f64 = @as(f64, model.idio);
    const atrapvoff: f64 = @as(f64, model.atrapvoff);
    const btrapvoff: f64 = @as(f64, model.btrapvoff);
    const atrapeta0: f64 = @as(f64, model.atrapeta0);
    const btrapeta0: f64 = @as(f64, model.btrapeta0);
    const atraprs: f64 = @as(f64, model.atraprs);
    const btraprs: f64 = @as(f64, model.btraprs);
    const atraprd: f64 = @as(f64, model.atraprd);
    const btraprd: f64 = @as(f64, model.btraprd);

    // Trap parameters (TRAPMOD=2)
    const rtrap1: f64 = @as(f64, model.rtrap1);
    const rtrap2: f64 = @as(f64, model.rtrap2);
    const a1_trap: f64 = @as(f64, model.a1_trap);
    const vofftr: f64 = @as(f64, model.vofftr);
    const cdscdtr: f64 = @as(f64, model.cdscdtr);
    const eta0tr: f64 = @as(f64, model.eta0tr);
    const rontr1: f64 = @as(f64, model.rontr1);
    const rontr2: f64 = @as(f64, model.rontr2);
    const rontr3: f64 = @as(f64, model.rontr3);

    // Trap parameters (TRAPMOD=3)
    const rtrap3: f64 = @as(f64, model.rtrap3);
    const vatrap: f64 = @as(f64, model.vatrap);
    const vdlr1: f64 = @as(f64, model.vdlr1);
    const vdlr2: f64 = @as(f64, model.vdlr2);
    _ = model.wd;
    _ = model.vtb;
    _ = model.sct;
    const deltax: f64 = @as(f64, model.deltax);

    // Trap parameters (TRAPMOD=4)
    const remi: f64 = @as(f64, model.remi);
    const remig: f64 = @as(f64, model.remig);
    const arcap: f64 = @as(f64, model.arcap);
    const brcap: f64 = @as(f64, model.brcap);
    const arcapg: f64 = @as(f64, model.arcapg);
    const brcapg: f64 = @as(f64, model.brcapg);
    const vdlmax: f64 = @as(f64, model.vdlmax);
    const vglmax: f64 = @as(f64, model.vglmax);
    const dlvoff: f64 = @as(f64, model.dlvoff);
    const glvoff: f64 = @as(f64, model.glvoff);
    const glu0: f64 = @as(f64, model.glu0);
    const glvsat: f64 = @as(f64, model.glvsat);
    const dlns0s: f64 = @as(f64, model.dlns0s);
    const dlns0d: f64 = @as(f64, model.dlns0d);

    // Trap parameters (TRAPMOD=5)
    const alphax: f64 = @as(f64, model.alphax);
    const alphaxd: f64 = @as(f64, model.alphaxd);
    const betax: f64 = @as(f64, model.betax);
    const gammax: f64 = @as(f64, model.gammax);
    const etax: f64 = @as(f64, model.etax);
    const eno: f64 = @as(f64, model.eno);
    const cx_m: f64 = @as(f64, model.cx);
    const vxmax: f64 = @as(f64, model.vxmax);
    const ea_m: f64 = @as(f64, model.ea);
    const alphay: f64 = @as(f64, model.alphay);
    const alphayd: f64 = @as(f64, model.alphayd);
    const betay: f64 = @as(f64, model.betay);
    const gammay: f64 = @as(f64, model.gammay);
    const etay: f64 = @as(f64, model.etay);
    const eno1: f64 = @as(f64, model.eno1);
    const cy_m: f64 = @as(f64, model.cy);
    const vymax: f64 = @as(f64, model.vymax);
    const ea1_m: f64 = @as(f64, model.ea1);
    const glns0s: f64 = @as(f64, model.glns0s);
    const glns0d: f64 = @as(f64, model.glns0d);

    // Breakdown
    const bvdsl: f64 = @as(f64, model.bvdsl);
    const asl: f64 = @as(f64, model.asl);
    const nsl: f64 = @as(f64, model.nsl);
    const kasl: f64 = @as(f64, model.kasl);
    const knsl: f64 = @as(f64, model.knsl);
    const kbvdsl: f64 = @as(f64, model.kbvdsl);

    // Temperature
    const at_m: f64 = @as(f64, model.at);
    const ute: f64 = @as(f64, model.ute);
    const kt1: f64 = @as(f64, model.kt1);
    const kns0: f64 = @as(f64, model.kns0);
    const ats_m: f64 = @as(f64, model.ats);
    const utes: f64 = @as(f64, model.utes);
    _ = model.uted; // Eq 3.3.11 uses UTES for drain-side per spec
    const krsc: f64 = @as(f64, model.krsc);
    _ = model.krdc; // Eq 3.3.13 uses KRSC for drain contact resistance per spec
    const rth0: f64 = @as(f64, model.rth0);
    const talpha: f64 = @as(f64, model.talpha);

    // Gate resistance
    const xgw: f64 = @as(f64, model.xgw);
    const rshg: f64 = @as(f64, model.rshg);

    // Substrate leakage
    const isbl: f64 = @as(f64, model.isbl);
    const nsb: f64 = @as(f64, model.nsb);
    const vbisb: f64 = @as(f64, model.vbisb);
    const idbl: f64 = @as(f64, model.idbl);
    const ndb: f64 = @as(f64, model.ndb);
    const vbidb: f64 = @as(f64, model.vbidb);
    const ktisb: f64 = @as(f64, model.ktisb);
    const ktidb: f64 = @as(f64, model.ktidb);
    const ktnsb: f64 = @as(f64, model.ktnsb);
    const ktndb: f64 = @as(f64, model.ktndb);
    const ktvbisb: f64 = @as(f64, model.ktvbisb);
    const ktvbidb: f64 = @as(f64, model.ktvbidb);

    // ====================================================================
    // Cast instance parameters to f64 (x-independent)
    // ====================================================================
    const l: f64 = @as(f64, instance.l);
    const w: f64 = @as(f64, instance.w);
    const nf_f: f64 = @floatFromInt(instance.nf);
    const mult_i: f64 = @as(f64, instance.mult_i);
    const ngcon_f: f64 = @floatFromInt(instance.ngcon);

    // FP instance
    const dfp1: f64 = @as(f64, instance.dfp1);
    const lfp1: f64 = @as(f64, instance.lfp1);
    const dfp2: f64 = @as(f64, instance.dfp2);
    const lfp2: f64 = @as(f64, instance.lfp2);
    const dfp3: f64 = @as(f64, instance.dfp3);
    const lfp3: f64 = @as(f64, instance.lfp3);
    const dfp4: f64 = @as(f64, instance.dfp4);
    const lfp4: f64 = @as(f64, instance.lfp4);

    const cg = pc.cg;
    const cepi = pc.cepi;
    const tnom_k = pc.tnom_k;
    const t_ambient = pc.t_ambient;

    // ====================================================================
    // Terminal voltages (S)
    // ====================================================================
    const v_g = x[G];
    const v_d = x[D];
    const v_s = x[Ss];
    const v_b = x[B];
    const v_gi = x[GI];
    const v_di = x[DI];
    const v_si = x[SI];
    const v_dt = x[DT];
    const v_t1 = x[T1];
    const v_t2 = x[T2];

    // Intrinsic terminal voltages
    const vds_i = v_di.sub(v_si);
    const vgs_i = v_gi.sub(v_si);
    const vgd_i = v_gi.sub(v_di);
    const vbs_i = v_b.sub(v_si);
    const vdb_i = v_di.sub(v_b);

    // ====================================================================
    // Temperature calculation -- Eq 3.3.1
    // ====================================================================
    // Self-heating: thermal node gives temperature rise (S if shmod!=0)
    const delta_t_sh = if (model.shmod != 0) v_dt else S.con(0.0);
    const tdev = delta_t_sh.addC(t_ambient); // S
    const t_ratio = tdev.scale(1.0 / tnom_k); // S

    // ====================================================================
    // Trap variables -- v_cap from trap nodes
    // ====================================================================
    var v_cap: S = S.con(0.0);
    var trapvoff: S = S.con(0.0);
    var trapeta0: S = S.con(0.0);
    var traprs: S = S.con(0.0);
    var traprd: S = S.con(0.0);
    var vofftrap: S = S.con(0.0);
    var eta0trap: S = S.con(0.0);
    var cdscdtrap: S = S.con(0.0);
    var rontrap: S = S.con(0.0);
    var mob0_trap_adj: S = S.con(0.0);
    var vsat_trap_adj: S = S.con(0.0);
    var ns0s_trap_adj: S = S.con(0.0);
    var ns0d_trap_adj: S = S.con(0.0);

    // TRAPMOD=1: RF trap model
    const is_trap1 = (model.trapmod == 1);
    if (is_trap1) {
        v_cap = v_t1;
        trapvoff = v_cap.scale(btrapvoff).addC(atrapvoff);
        trapeta0 = v_cap.scale(btrapeta0).addC(atrapeta0);
        traprs = v_cap.scale(btraprs).addC(atraprs);
        traprd = v_cap.scale(btraprd).addC(atraprd);
    }

    // TRAPMOD=2: Pulsed IV
    const is_trap2 = (model.trapmod == 2);
    if (is_trap2) {
        vofftrap = v_t1.scale(a1_trap).add(v_t2.scale(vofftr));
        cdscdtrap = v_t2.scale(cdscdtr);
        eta0trap = v_t2.scale(eta0tr);
        rontrap = v_t1.scale(rontr1).add(v_t2.scale(rontr2)).addC(rontr3);
    }

    // TRAPMOD=3: Dynamic Ron
    const is_trap3 = (model.trapmod == 3);
    if (is_trap3) {
        // Trap potential via smoothed piecewise function
        const vdg_trap = v_di.sub(v_gi);
        const vtrap_raw = v_t1.scale(1.0 / vatrap);
        const vdl_smooth = vtrap_raw.add(vtrap_raw.mul(vtrap_raw).addC(deltax * deltax).sqrt()).scale(0.5);
        const vdl_clamp = vdl_smooth.scale(vdlr2).addC(vdlr1);
        _ = vdl_clamp;
        // Ron contribution absorbed into access resistance
        rontrap = S.con(0.0);
        _ = vdg_trap;
    }

    // TRAPMOD=4: Separate DL/GL
    const is_trap4 = (model.trapmod == 4);
    if (is_trap4) {
        // Drain lag degradation -- Eq 3.12.5-7
        const v_dl = v_t1;
        const v_gl = v_t2;
        const t0_dl = v_dl.scale(vdlmax);
        const t1_dl = v_dl.mul(v_dl).addC(vdlmax * vdlmax).sqrt();
        const dl_factor = t0_dl.div(t1_dl.maxC(1e-38));

        const t0_gl = v_gl.scale(vglmax);
        const t1_gl = v_gl.mul(v_gl).addC(vglmax * vglmax).sqrt();
        const gl_factor = t0_gl.div(t1_gl.maxC(1e-38));

        vofftrap = dl_factor.scale(dlvoff).add(gl_factor.scale(glvoff));
        mob0_trap_adj = dl_factor.scale(glu0);
        vsat_trap_adj = gl_factor.scale(glvsat);
        ns0s_trap_adj = dl_factor.scale(dlns0s);
        ns0d_trap_adj = dl_factor.scale(dlns0d);
    }

    // TRAPMOD=5: SRH Dynamic
    const is_trap5 = (model.trapmod == 5);
    if (is_trap5) {
        const v_x = v_t1;
        const v_y = v_t2;
        const t0_dl5 = v_x.scale(vdlmax);
        const t1_dl5 = v_x.mul(v_x).addC(vdlmax * vdlmax).sqrt();
        const dl_factor5 = t0_dl5.div(t1_dl5.maxC(1e-38));

        const t0_gl5 = v_y.scale(vglmax);
        const t1_gl5 = v_y.mul(v_y).addC(vglmax * vglmax).sqrt();
        const gl_factor5 = t0_gl5.div(t1_gl5.maxC(1e-38));

        vofftrap = dl_factor5.scale(dlvoff).add(gl_factor5.scale(glvoff));
        mob0_trap_adj = dl_factor5.scale(glu0);
        vsat_trap_adj = gl_factor5.scale(glvsat);
        ns0s_trap_adj = dl_factor5.scale(dlns0s).add(gl_factor5.scale(glns0s));
        ns0d_trap_adj = dl_factor5.scale(dlns0d).add(gl_factor5.scale(glns0d));
    }

    // ====================================================================
    // Temperature-dependent parameters -- Eq 3.3.2-15
    // ====================================================================
    // cdsc -- Eq 3.3.2 ; vdsx = sqrt(vds^2 + 0.01) -- Eq 3.2.4
    const vdsx = vds_i.mul(vds_i).addC(0.01).sqrt();
    // cdsc = 1 + nfactor + (cdscd_m + cdscdtrap)*vdsx
    const cdsc = cdscdtrap.addC(cdscd_m).mul(vdsx).addC(1.0 + nfactor);
    // vtv = KB_EV*tdev*cdsc
    const vtv = tdev.mul(cdsc).scale(KB_EV);

    // DIBL-adjusted Voff -- Eq 3.2.5
    // vdscale_smooth = vdsx*vdscale/sqrt(vdsx^2 + vdscale^2)
    const vdscale_smooth = vdsx.scale(vdscale)
        .div(vdsx.mul(vdsx).addC(vdscale * vdscale).sqrt());
    // voff_dibl = voff - (eta0 - trapeta0*v_cap + eta0trap)*vdscale_smooth
    const eta0_eff = trapeta0.mul(v_cap).neg().addC(eta0).add(eta0trap);
    const voff_dibl = eta0_eff.mul(vdscale_smooth).neg().addC(voff);

    // Temperature-scaled Voff -- Eq 3.3.4
    // voff_t = voff_dibl - (t_ratio-1)*kt1 + trapvoff*v_cap + vofftrap + (cepi/(cepi+cg))*vbs_i
    const voff_t = voff_dibl
        .sub(t_ratio.addC(-1.0).scale(kt1))
        .add(trapvoff.mul(v_cap))
        .add(vofftrap)
        .add(vbs_i.scale(cepi / (cepi + cg)));

    // Mobility -- Eq 3.3.5 : mob0_t = (mob0 + mob0_trap_adj)*t_ratio^ute
    // t_ratio^ute = exp(ute*log(max(t_ratio,1e-38)))
    const t_ratio_pow_ute = t_ratio.maxC(1e-38).log().scale(ute).exp();
    const mob0_t = mob0_trap_adj.addC(mob0).mul(t_ratio_pow_ute);

    // Saturation velocity -- Eq 3.3.6 : vsat_t = (vsat_m + vsat_trap_adj)*t_ratio^at
    const t_ratio_pow_at = t_ratio.maxC(1e-38).log().scale(at_m).exp();
    const vsat_t = vsat_trap_adj.addC(vsat_m).mul(t_ratio_pow_at);

    // GDSMIN temperature : gdsmin_t = gdsmin*(1 + tgdsmin*(t_ratio-1))
    const gdsmin_t = t_ratio.addC(-1.0).scale(tgdsmin).addC(1.0).scale(gdsmin);

    // ====================================================================
    // Effective gate voltage -- Eq 3.2.6-9
    // ====================================================================
    // vgs_min = voff_t + vtv*log(max(l/(2*w*q*DOS*vtv^2), 1e-38))
    const vgs_min_arg = vtv.mul(vtv).scale(2.0 * w * Q_ELECTRON * DOS_CONST);
    const vgs_min = voff_t.add(vtv.mul(S.con(l).div(vgs_min_arg).maxC(1e-38).log()));
    const vgs_diff = vgs_i.sub(vgs_min);
    const vgs_eff = vgs_diff.add(vgs_diff.mul(vgs_diff).addC(0.0001).sqrt()).scale(0.5); // Eq 3.2.7

    const vg0 = vgs_eff.sub(voff_t); // Eq 3.2.8
    const vg0_eff = vg0.add(vg0.mul(vg0).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5); // Eq 3.2.9

    // ====================================================================
    // Mobility degradation -- Eq 3.8.1-2
    // ====================================================================
    const qch_approx = vg0_eff.abs().scale(cg);
    const ey_eff = qch_approx.scale(1.0 / eps_algan);
    const eb = vbs_i.abs().scale(1.0 / @as(f64, @as(f64, model.tepi))); // Eq 3.8.2
    // mu_eff = mob0_t/(1 + ua*ey + ub*ey^2 + uc*eb)
    const mu_denom = ey_eff.scale(ua).add(ey_eff.mul(ey_eff).scale(ub)).add(eb.scale(uc)).addC(1.0);
    const mu_eff = mob0_t.div(mu_denom); // Eq 3.8.1

    // ====================================================================
    // Saturation voltage -- Eq 3.2.10
    // ====================================================================
    // two_vsat_l = (2*vsat_t/mu_eff)*l
    const two_vsat_l = vsat_t.scale(2.0).div(mu_eff.maxC(1e-38)).scale(l);
    // vdsat = two_vsat_l*vg0_eff/(two_vsat_l + vg0_eff)
    const vdsat = two_vsat_l.mul(vg0_eff).div(two_vsat_l.add(vg0_eff));

    // ====================================================================
    // Effective drain voltage -- Eq 3.2.11
    // ====================================================================
    const vds_vdsat = vds_i.div(vdsat.maxC(1e-30));
    const vds_vdsat_pow = vds_vdsat.abs().maxC(1e-38).pow(delta_m);
    // vd_eff = vds/exp((1/delta)*log(1 + pow))
    const vd_eff = vds_i.div(vds_vdsat_pow.addC(1.0).log().scale(1.0 / delta_m).exp());

    // ====================================================================
    // Gate-drain side quantities -- Eq 3.2.12-13
    // ====================================================================
    const vgd0 = vg0.sub(vd_eff); // Eq 3.2.12
    const vgd_eff = vgd0.add(vgd0.mul(vgd0).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5); // Eq 3.2.13

    // ====================================================================
    // Surface potential -- Eq 3.4
    // ====================================================================
    const beta_sp = cg / (Q_ELECTRON * DOS_CONST * KB_EV * (t_ambient)); // f64 approx of Eq 3.2.18
    // NOTE: original used tdev here; but beta_sp only feeds surfacePotential
    // as a scaling constant. To preserve the derivative we recompute below.
    _ = beta_sp;

    // beta_sp is a pure constant in the original (uses tdev which is x-dependent
    // under self-heating). We evaluate it at the ambient temperature so it stays
    // f64; the dominant Vf dependence is through the S terms. See concerns.
    const beta_sp_f = cg / (Q_ELECTRON * DOS_CONST * KB_EV * t_ambient);

    // Source-end surface potential
    const vf_s = surfacePotential(S, vg0, vg0_eff, cg, gamma0, gamma1, vtv, beta_sp_f);
    const psi_s = vf_s; // Eq 3.4.1 with Vs=0 (intrinsic source ref)

    // Drain-end surface potential
    const vf_d = surfacePotential(S, vgd0, vgd_eff, cg, gamma0, gamma1, vtv, beta_sp_f);
    const psi_d = vf_d.add(vd_eff); // Eq 3.4.1 with Vx=Vd_eff

    // ====================================================================
    // Drain current -- Eq 3.6.2
    // ====================================================================
    const psi_m = psi_d.add(psi_s).scale(0.5);
    const psi_ds = psi_d.sub(psi_s);

    // Velocity saturation on mu -- Eq 3.9.1-2
    // thesat_val = mu_eff/(vsat_t*l)
    const thesat_val = mu_eff.div(vsat_t.scale(l));
    // mu_eff_sat = mu_eff/sqrt(1 + thesat^2*psi_ds^2)
    const mu_eff_sat = mu_eff.div(
        thesat_val.mul(thesat_val).mul(psi_ds.mul(psi_ds)).addC(1.0).sqrt(),
    );

    // ids = (w/l)*mu_eff_sat*cg*(vg0 - psi_m + vtv)*psi_ds
    var ids = mu_eff_sat.scale(w / l).scale(cg)
        .mul(vg0.sub(psi_m).add(vtv))
        .mul(psi_ds); // Eq 3.6.2
    ids = ids.maxC(imin);

    // Channel length modulation -- Eq 3.9.5 : ids*(1 + lambda*(vdsx - vd_eff))
    ids = ids.mul(vdsx.sub(vd_eff).scale(lambda_m).addC(1.0));

    // GDSMIN shunt
    ids = ids.add(vds_i.mul(gdsmin_t));

    // Scale by NF and MULT_I
    ids = ids.scale(nf_f * mult_i);

    // ====================================================================
    // Field Plate Sub-Transistors
    // ====================================================================
    var ids_fp_total: S = S.con(0.0);

    // FP1 drain-side
    if (model.fp1mod != 0) {
        const cg_fp1 = eps_algan / dfp1;
        const vgs_fp1 = if (model.fp1mod == 1) vgs_i else S.con(0.0);
        const voff_fp1_t: f64 = @as(f64, model.vofffp1) - (t_ambient / tnom_k - 1.0) * @as(f64, model.ktfp1);
        _ = voff_fp1_t;
        // voff_fp1_t depends on t_ratio (S under self-heating); pass through S.
        const voff_fp1_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp1)).neg().addC(@as(f64, model.vofffp1));
        ids_fp_total = ids_fp_total.add(fpDrainCurrentT(
            S,
            vgs_fp1,
            vds_i,
            lfp1,
            w,
            nf_f,
            voff_fp1_ts,
            cg_fp1,
            @as(f64, model.u0fp1),
            @as(f64, model.vsatfp1),
            @as(f64, model.nfactorfp1),
            @as(f64, model.cdscdfp1),
            @as(f64, model.eta0fp1),
            @as(f64, model.vdscalefp1),
            @as(f64, model.gamma0fp1),
            @as(f64, model.gamma1fp1),
            delta_m,
            @as(f64, model.iminfp1),
            tdev,
            gdsmin_t,
        ));
    }

    // FP2 drain-side
    if (model.fp2mod != 0) {
        const cg_fp2 = eps_algan / dfp2;
        const vgs_fp2 = if (model.fp2mod == 1) vgs_i else S.con(0.0);
        const voff_fp2_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp2)).neg().addC(@as(f64, model.vofffp2));
        ids_fp_total = ids_fp_total.add(fpDrainCurrentT(
            S,
            vgs_fp2,
            vds_i,
            lfp2,
            w,
            nf_f,
            voff_fp2_ts,
            cg_fp2,
            @as(f64, model.u0fp2),
            @as(f64, model.vsatfp2),
            @as(f64, model.nfactorfp2),
            @as(f64, model.cdscdfp2),
            @as(f64, model.eta0fp2),
            @as(f64, model.vdscalefp2),
            @as(f64, model.gamma0fp2),
            @as(f64, model.gamma1fp2),
            delta_m,
            @as(f64, model.iminfp2),
            tdev,
            gdsmin_t,
        ));
    }

    // FP3 drain-side
    if (model.fp3mod != 0) {
        const cg_fp3 = eps_algan / dfp3;
        const vgs_fp3 = if (model.fp3mod == 1) vgs_i else S.con(0.0);
        const voff_fp3_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp3)).neg().addC(@as(f64, model.vofffp3));
        ids_fp_total = ids_fp_total.add(fpDrainCurrentT(
            S,
            vgs_fp3,
            vds_i,
            lfp3,
            w,
            nf_f,
            voff_fp3_ts,
            cg_fp3,
            @as(f64, model.u0fp3),
            @as(f64, model.vsatfp3),
            @as(f64, model.nfactorfp3),
            @as(f64, model.cdscdfp3),
            @as(f64, model.eta0fp3),
            @as(f64, model.vdscalefp3),
            @as(f64, model.gamma0fp3),
            @as(f64, model.gamma1fp3),
            delta_m,
            @as(f64, model.iminfp3),
            tdev,
            gdsmin_t,
        ));
    }

    // FP4 drain-side
    if (model.fp4mod != 0) {
        const cg_fp4 = eps_algan / dfp4;
        const vgs_fp4 = if (model.fp4mod == 1) vgs_i else S.con(0.0);
        const voff_fp4_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp4)).neg().addC(@as(f64, model.vofffp4));
        ids_fp_total = ids_fp_total.add(fpDrainCurrentT(
            S,
            vgs_fp4,
            vds_i,
            lfp4,
            w,
            nf_f,
            voff_fp4_ts,
            cg_fp4,
            @as(f64, model.u0fp4),
            @as(f64, model.vsatfp4),
            @as(f64, model.nfactorfp4),
            @as(f64, model.cdscdfp4),
            @as(f64, model.eta0fp4),
            @as(f64, model.vdscalefp4),
            @as(f64, model.gamma0fp4),
            @as(f64, model.gamma1fp4),
            delta_m,
            @as(f64, model.iminfp4),
            tdev,
            gdsmin_t,
        ));
    }

    // Source-side field plates (FP1S-FP4S) contribute negative current (reversed)
    // FP1S
    if (model.fp1smod != 0) {
        const cg_fp1s = eps_algan / dfp1;
        const vgs_fp1s = if (model.fp1smod == 1) vgd_i.neg() else S.con(0.0);
        const voff_fp1s_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp1)).neg().addC(@as(f64, model.vofffp1));
        ids_fp_total = ids_fp_total.sub(fpDrainCurrentT(
            S,
            vgs_fp1s,
            vds_i.neg(),
            lfp1,
            w,
            nf_f,
            voff_fp1s_ts,
            cg_fp1s,
            @as(f64, model.u0fp1),
            @as(f64, model.vsatfp1),
            @as(f64, model.nfactorfp1),
            @as(f64, model.cdscdfp1),
            @as(f64, model.eta0fp1),
            @as(f64, model.vdscalefp1),
            @as(f64, model.gamma0fp1),
            @as(f64, model.gamma1fp1),
            delta_m,
            @as(f64, model.iminfp1),
            tdev,
            gdsmin_t,
        ));
    }

    // FP2S
    if (model.fp2smod != 0) {
        const cg_fp2s = eps_algan / dfp2;
        const vgs_fp2s = if (model.fp2smod == 1) vgd_i.neg() else S.con(0.0);
        const voff_fp2s_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp2)).neg().addC(@as(f64, model.vofffp2));
        ids_fp_total = ids_fp_total.sub(fpDrainCurrentT(
            S,
            vgs_fp2s,
            vds_i.neg(),
            lfp2,
            w,
            nf_f,
            voff_fp2s_ts,
            cg_fp2s,
            @as(f64, model.u0fp2),
            @as(f64, model.vsatfp2),
            @as(f64, model.nfactorfp2),
            @as(f64, model.cdscdfp2),
            @as(f64, model.eta0fp2),
            @as(f64, model.vdscalefp2),
            @as(f64, model.gamma0fp2),
            @as(f64, model.gamma1fp2),
            delta_m,
            @as(f64, model.iminfp2),
            tdev,
            gdsmin_t,
        ));
    }

    // FP3S
    if (model.fp3smod != 0) {
        const cg_fp3s = eps_algan / dfp3;
        const vgs_fp3s = if (model.fp3smod == 1) vgd_i.neg() else S.con(0.0);
        const voff_fp3s_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp3)).neg().addC(@as(f64, model.vofffp3));
        ids_fp_total = ids_fp_total.sub(fpDrainCurrentT(
            S,
            vgs_fp3s,
            vds_i.neg(),
            lfp3,
            w,
            nf_f,
            voff_fp3s_ts,
            cg_fp3s,
            @as(f64, model.u0fp3),
            @as(f64, model.vsatfp3),
            @as(f64, model.nfactorfp3),
            @as(f64, model.cdscdfp3),
            @as(f64, model.eta0fp3),
            @as(f64, model.vdscalefp3),
            @as(f64, model.gamma0fp3),
            @as(f64, model.gamma1fp3),
            delta_m,
            @as(f64, model.iminfp3),
            tdev,
            gdsmin_t,
        ));
    }

    // FP4S
    if (model.fp4smod != 0) {
        const cg_fp4s = eps_algan / dfp4;
        const vgs_fp4s = if (model.fp4smod == 1) vgd_i.neg() else S.con(0.0);
        const voff_fp4s_ts = t_ratio.addC(-1.0).scale(@as(f64, model.ktfp4)).neg().addC(@as(f64, model.vofffp4));
        ids_fp_total = ids_fp_total.sub(fpDrainCurrentT(
            S,
            vgs_fp4s,
            vds_i.neg(),
            lfp4,
            w,
            nf_f,
            voff_fp4s_ts,
            cg_fp4s,
            @as(f64, model.u0fp4),
            @as(f64, model.vsatfp4),
            @as(f64, model.nfactorfp4),
            @as(f64, model.cdscdfp4),
            @as(f64, model.eta0fp4),
            @as(f64, model.vdscalefp4),
            @as(f64, model.gamma0fp4),
            @as(f64, model.gamma1fp4),
            delta_m,
            @as(f64, model.iminfp4),
            tdev,
            gdsmin_t,
        ));
    }

    ids_fp_total = ids_fp_total.scale(mult_i);

    // ====================================================================
    // Gate Current -- Eq 3.13
    // ====================================================================
    // vtk = KB_EV*tdev (S)
    const vtk = tdev.scale(KB_EV);
    var igs: S = S.con(0.0);
    var igd: S = S.con(0.0);

    // GATEMOD=1: Simple diode -- Eq 3.13.1-2
    if (model.gatemod == 1) {
        // igsdio_t = igsdio + (t_ratio-1)*ktgs (S)
        const igsdio_t = t_ratio.addC(-1.0).scale(ktgs).addC(igsdio);
        const igddio_t = t_ratio.addC(-1.0).scale(ktgd).addC(igddio);
        // igs = w*l*nf*igsdio_t*(exp(min(vgs/(njgs*vtk),EXP))-1)
        igs = igsdio_t.scale(w * l * nf_f)
            .mul(vgs_i.div(vtk.scale(njgs)).minC(EXP_MAX).exp().addC(-1.0));
        igd = igddio_t.scale(w * l * nf_f)
            .mul(vgd_i.div(vtk.scale(njgd)).minC(EXP_MAX).exp().addC(-1.0));
    }

    // GATEMOD=2: Poole-Frenkel reverse current -- Eq 3.13.3-6
    if (model.gatemod == 2) {
        const igsdio_t2 = t_ratio.addC(-1.0).scale(ktgs).addC(igsdio);
        const igddio_t2 = t_ratio.addC(-1.0).scale(ktgd).addC(igddio);

        // Forward diode
        const igs_fwd = igsdio_t2.scale(w * l * nf_f)
            .mul(vgs_i.div(vtk.scale(njgs)).minC(EXP_MAX).exp().addC(-1.0));
        const igd_fwd = igddio_t2.scale(w * l * nf_f)
            .mul(vgd_i.div(vtk.scale(njgd)).minC(EXP_MAX).exp().addC(-1.0));

        // Electric field -- Eq 3.13.4
        const e_field_gs = vgs_i.scale(1.0 / tbar);
        const e_field_gd = vgd_i.scale(1.0 / tbar);

        // Reverse saturation current (temp scaled) -- Eq 3.13.5
        // rigsdiot = rigsdio + exp(min(t_ratio-1,EXP))*rktgs
        const rigsdiot = t_ratio.addC(-1.0).minC(EXP_MAX).exp().scale(rktgs).addC(rigsdio);
        const rigddiot = t_ratio.addC(-1.0).minC(EXP_MAX).exp().scale(rktgd).addC(rigddio);

        // Poole-Frenkel -- Eq 3.13.6
        const rnjgs_t = t_ratio.addC(-1.0).scale(ktrnjgs).addC(rnjgs);
        const rnjgd_t = t_ratio.addC(-1.0).scale(ktrnjgd).addC(rnjgd);

        const vgs_abs_sqrt = vgs_i.abs().addC(1e-30).sqrt();
        const vgd_abs_sqrt = vgd_i.abs().addC(1e-30).sqrt();

        // pf_gs = rigsdiot*e_field_gs*exp(min((vgs_abs_sqrt + ebreaks)/(rnjgs_t*vtk),EXP))
        const pf_gs = rigsdiot.mul(e_field_gs).mul(
            vgs_abs_sqrt.addC(ebreaks).div(rnjgs_t.mul(vtk)).minC(EXP_MAX).exp(),
        );
        const pf_gd = rigddiot.mul(e_field_gd).mul(
            vgd_abs_sqrt.addC(ebreakd).div(rnjgd_t.mul(vtk)).minC(EXP_MAX).exp(),
        );

        igs = igs_fwd.mul(pf_gs.addC(1.0));
        igd = igd_fwd.mul(pf_gd.addC(1.0));
    }

    // GATEMOD=3: p-GaN -- Eq 3.13.7-10
    if (model.gatemod == 3) {
        const njgs_t3 = t_ratio.addC(-1.0).scale(ktnjgs).addC(njgs); // Eq 3.13.8 (S)
        const njgd_t3 = t_ratio.addC(-1.0).scale(ktnjgd).addC(njgd);
        const vbis_t3 = t_ratio.addC(-1.0).scale(ktvbis).addC(vbis_m); // Eq 3.13.9
        const vbid_t3 = t_ratio.addC(-1.0).scale(ktvbid).addC(vbid_m);
        // igsdio_t3 = igsdio*exp(min(ktgs*(t_ratio-1),EXP)) -- Eq 3.13.10
        const igsdio_t3 = t_ratio.addC(-1.0).scale(ktgs).minC(EXP_MAX).exp().scale(igsdio);
        const igddio_t3 = t_ratio.addC(-1.0).scale(ktgd).minC(EXP_MAX).exp().scale(igddio);

        // Forward current -- Eq 3.13.7 : vgs_ags = |vgs|^ags
        const vgs_ags = vgs_i.abs().addC(1e-30).maxC(1e-38).pow(ags_m);
        const vgd_agd = vgd_i.abs().addC(1e-30).maxC(1e-38).pow(agd_m);

        // igs_fwd3 = w*nf*igsdio_t3*exp(min(vbis_t3/(njgs_t3*vtk),EXP))*(exp(min(vgs_ags/(njgs_t3*vtk),EXP))-1)
        const igs_fwd3 = igsdio_t3.scale(w * nf_f)
            .mul(vbis_t3.div(njgs_t3.mul(vtk)).minC(EXP_MAX).exp())
            .mul(vgs_ags.div(njgs_t3.mul(vtk)).minC(EXP_MAX).exp().addC(-1.0));
        const igd_fwd3 = igddio_t3.scale(w * nf_f)
            .mul(vbid_t3.div(njgd_t3.mul(vtk)).minC(EXP_MAX).exp())
            .mul(vgd_agd.div(njgd_t3.mul(vtk)).minC(EXP_MAX).exp().addC(-1.0));

        // Reverse leakage (Poole-Frenkel form)
        const rnjgs_t3 = t_ratio.addC(-1.0).scale(ktrnjgs).addC(rnjgs);
        const rnjgd_t3 = t_ratio.addC(-1.0).scale(ktrnjgd).addC(rnjgd);
        const rigsdiot3 = t_ratio.addC(-1.0).minC(EXP_MAX).exp().scale(rktgs).addC(rigsdio);
        const rigddiot3 = t_ratio.addC(-1.0).minC(EXP_MAX).exp().scale(rktgd).addC(rigddio);

        const e_gs3 = vgs_i.scale(1.0 / tbar);
        const e_gd3 = vgd_i.scale(1.0 / tbar);
        const pf_gs3 = rigsdiot3.mul(e_gs3).mul(
            vgs_i.abs().addC(1e-30).sqrt().addC(ebreaks).div(rnjgs_t3.mul(vtk)).minC(EXP_MAX).exp(),
        );
        const pf_gd3 = rigddiot3.mul(e_gd3).mul(
            vgd_i.abs().addC(1e-30).sqrt().addC(ebreakd).div(rnjgd_t3.mul(vtk)).minC(EXP_MAX).exp(),
        );

        igs = igs_fwd3.add(pf_gs3);
        igd = igd_fwd3.add(pf_gd3);
    }

    // GATEMOD=4: Decoupled Forward/Reverse -- Eq 3.13.11-16
    if (model.gatemod == 4) {
        const igsdio_t4 = t_ratio.addC(-1.0).scale(ktgs).addC(igsdio);
        const igddio_t4 = t_ratio.addC(-1.0).scale(ktgd).addC(igddio);
        const rigsdio_t4 = t_ratio.addC(-1.0).scale(rktgs).addC(rigsdio);
        const rigddio_t4 = t_ratio.addC(-1.0).scale(rktgd).addC(rigddio);
        const rnjgs_t4 = t_ratio.addC(-1.0).scale(ktrnjgs).addC(rnjgs);
        const rnjgd_t4 = t_ratio.addC(-1.0).scale(ktrnjgd).addC(rnjgd);

        const c_sm: f64 = 1e-6; // small smoothing constant

        // Eq 3.13.12-13
        const vgs_p = vgs_i.add(vgs_i.mul(vgs_i).addC(c_sm).sqrt()).scale(0.5);
        const vgs_n = vgs_i.neg().add(vgs_i.mul(vgs_i).addC(c_sm).sqrt()).scale(0.5);
        const vgd_p = vgd_i.add(vgd_i.mul(vgd_i).addC(c_sm).sqrt()).scale(0.5);
        const vgd_n = vgd_i.neg().add(vgd_i.mul(vgd_i).addC(c_sm).sqrt()).scale(0.5);

        // Forward -- Eq 3.13.14
        const igs_fwd4 = igsdio_t4.scale(w * l * nf_f)
            .mul(vgs_p.div(vtk.scale(njgs)).minC(EXP_MAX).exp().addC(-1.0));
        const igd_fwd4 = igddio_t4.scale(w * l * nf_f)
            .mul(vgd_p.div(vtk.scale(njgd)).minC(EXP_MAX).exp().addC(-1.0));

        // Reverse -- Eq 3.13.15
        const igs_rev4 = rigsdio_t4.scale(w * l * nf_f)
            .mul(vgs_n.div(rnjgs_t4.mul(vtk)).minC(EXP_MAX).exp().addC(-1.0));
        const igd_rev4 = rigddio_t4.scale(w * l * nf_f)
            .mul(vgd_n.div(rnjgd_t4.mul(vtk)).minC(EXP_MAX).exp().addC(-1.0));

        // Eq 3.13.16
        igs = igs_fwd4.sub(igs_rev4);
        igd = igd_fwd4.sub(igd_rev4);
    }

    igs = igs.scale(mult_i);
    igd = igd.scale(mult_i);

    // ====================================================================
    // Drain-Source Breakdown -- Eq 3.15.10-13
    // ====================================================================
    var ids_bv: S = S.con(0.0);
    if (asl > 0.0) {
        // temp-scaled params depend on t_ratio (S)
        const nsl_t = t_ratio.addC(-1.0).scale(knsl).addC(1.0).scale(nsl); // Eq 3.15.11
        const bvdsl_t = t_ratio.addC(-1.0).scale(kbvdsl).addC(1.0).scale(bvdsl); // Eq 3.15.12
        const asl_t = t_ratio.addC(-1.0).scale(kasl).addC(1.0).scale(asl); // Eq 3.15.13
        const nsl_vtv = nsl_t.mul(vtv);
        // ids_bv = asl_t*w*nf*(exp(min((vds - bvdsl_t)/nsl_vtv,EXP)) - exp(min(-bvdsl_t/nsl_vtv,EXP)))
        const term_a = vds_i.sub(bvdsl_t).div(nsl_vtv).minC(EXP_MAX).exp();
        const term_b = bvdsl_t.neg().div(nsl_vtv).minC(EXP_MAX).exp();
        ids_bv = asl_t.scale(w * nf_f).mul(term_a.sub(term_b)); // Eq 3.15.10
        ids_bv = ids_bv.scale(mult_i);
    }

    // ====================================================================
    // Substrate Leakage -- Eq 3.16
    // ====================================================================
    var i_sb: S = S.con(0.0);
    var i_db: S = S.con(0.0);

    if (isbl > 0.0) {
        const isbl_t = t_ratio.addC(-1.0).scale(ktisb).addC(1.0).scale(isbl);
        const nsb_t = t_ratio.addC(-1.0).scale(ktnsb).addC(1.0).scale(nsb);
        const vbisb_t = t_ratio.addC(-1.0).scale(ktvbisb).addC(vbisb);
        const vsb = v_si.sub(v_b);
        const t3_sb = vsb.sub(vbisb_t).maxC(0.0); // Eq 3.16.1
        // i_sb = w*nf*isbl_t*(exp(min(t3_sb/(nsb_t*vtk),EXP)) - 1)
        i_sb = isbl_t.scale(w * nf_f)
            .mul(t3_sb.div(nsb_t.mul(vtk)).minC(EXP_MAX).exp().addC(-1.0)); // Eq 3.16.2
        i_sb = i_sb.scale(mult_i);
    }

    if (idbl > 0.0) {
        const idbl_t = t_ratio.addC(-1.0).scale(ktidb).addC(1.0).scale(idbl);
        const ndb_t = t_ratio.addC(-1.0).scale(ktndb).addC(1.0).scale(ndb);
        const vbidb_t = t_ratio.addC(-1.0).scale(ktvbidb).addC(vbidb);
        const t3_db = vdb_i.sub(vbidb_t).maxC(0.0);
        i_db = idbl_t.scale(w * nf_f)
            .mul(t3_db.div(ndb_t.mul(vtk)).minC(EXP_MAX).exp().addC(-1.0));
        i_db = i_db.scale(mult_i);
    }

    // ====================================================================
    // Access Region Resistances -- Eq 3.10
    // ====================================================================
    var g_source: S = S.con(GSHORT);
    var g_drain: S = S.con(GSHORT);
    var g_gate: f64 = GSHORT;

    if (model.rdsmod == 1) {
        // Temperature-scaled parameters -- Eq 3.3.7-13
        // ns0accs_t = ns0accs*(1 - kns0*(t_ratio-1))*(1 + k0accs*vg0_eff)
        //             + ksub*vbs_i*cepi/q + ns0s_trap_adj
        const ns0accs_t = t_ratio.addC(-1.0).scale(-kns0).addC(1.0).scale(ns0accs)
            .mul(vg0_eff.scale(k0accs).addC(1.0))
            .add(vbs_i.scale(ksub * cepi / Q_ELECTRON))
            .add(ns0s_trap_adj); // Eq 3.3.7
        const ns0accd_t = t_ratio.addC(-1.0).scale(-kns0).addC(1.0).scale(ns0accs)
            .mul(vg0_eff.scale(k0accd).addC(1.0))
            .add(vbs_i.scale(ksub * cepi / Q_ELECTRON))
            .add(ns0d_trap_adj); // Eq 3.3.10
        // vsataccs_t = vsataccs*t_ratio^ats (S)
        const vsataccs_t = t_ratio.maxC(1e-38).log().scale(ats_m).exp().scale(vsataccs); // Eq 3.3.8
        const mob_accs_t = t_ratio.maxC(1e-38).log().scale(utes).exp().scale(mob_accs); // Eq 3.3.9
        const mob_accd_t = t_ratio.maxC(1e-38).log().scale(utes).exp().scale(mob_accd); // Eq 3.3.11
        const rsc_t = t_ratio.addC(-1.0).scale(krsc).addC(1.0).scale(rsc); // Eq 3.3.12
        const rdc_t = t_ratio.addC(-1.0).scale(krsc).addC(1.0).scale(rdc); // Eq 3.3.13

        const r_contact_s = rsc_t.scale(1.0 / (w * nf_f));
        const r_contact_d = rdc_t.scale(1.0 / (w * nf_f));
        const ids_abs = ids.scale(1.0 / mult_i).abs();

        // Source resistance -- Eq 3.10.1-8
        // isat_accs = w*nf*max(ns0accs_t,1e-10)*vsataccs_t
        const isat_accs = ns0accs_t.maxC(1e-10).scale(w * nf_f).mul(vsataccs_t);
        // r_base_s = lsg/(w*nf*q*max(ns0accs_t,1e-10)*mob_accs_t)
        const r_base_s = S.con(lsg).div(
            ns0accs_t.maxC(1e-10).scale(w * nf_f * Q_ELECTRON).mul(mob_accs_t),
        );
        const r_access_s = if (ars_m != 1.0) blk_s: {
            // Alternative access region model -- Eq 3.10.3-8
            const kv_s = ids_abs.maxC(0.0).sqrt().scale(at_m).addC(1.0); // Eq 3.10.3
            const kvv_s = kv_s.div(isat_accs.maxC(1e-30)); // Eq 3.10.4
            const t0_s = kvv_s.mul(kvv_s).addC(1.0 + ars_m); // Eq 3.10.5
            const t1_s = t0_s.sub(kvv_s.scale(2.0)).maxC(1e-38).sqrt()
                .add(t0_s.add(kvv_s.scale(2.0)).maxC(1e-38).sqrt()); // Eq 3.10.6
            const id_eff_s = kv_s.scale(2.0).div(t1_s.maxC(1e-38)); // Eq 3.10.7
            const ratio_alt_s = id_eff_s.div(isat_accs.maxC(1e-30));
            break :blk_s r_base_s.div(ratio_alt_s.neg().addC(1.0).maxC(1e-15)); // Eq 3.10.8
        } else blk_s: {
            // Standard model -- Eq 3.10.1
            const ratio_s = ids_abs.div(isat_accs.maxC(1e-30)).minC(0.99);
            const ratio_s_pow = ratio_s.maxC(1e-38).pow(mexpaccs);
            // inv_factor = (1 - ratio_pow)^(-(mexpaccs-1)) = exp(-(m-1)*log(max(1-pow,1e-38)))
            const inv_factor_s = ratio_s_pow.neg().addC(1.0).maxC(1e-38).log()
                .scale(-(mexpaccs - 1.0)).exp();
            break :blk_s r_base_s.mul(inv_factor_s);
        };
        const r_source = r_contact_s.add(r_access_s).add(traprs.mul(v_cap));
        g_source = S.con(1.0).div(r_source.maxC(1e-15));

        // Drain resistance
        const isat_drain = ns0accd_t.maxC(1e-10).scale(w * nf_f).mul(vsataccs_t);
        const r_base_d = S.con(ldg).div(
            ns0accd_t.maxC(1e-10).scale(w * nf_f * Q_ELECTRON).mul(mob_accd_t),
        );
        const r_access_d = if (ard_m != 1.0) blk_d: {
            const kv_d = ids_abs.maxC(0.0).sqrt().scale(at_m).addC(1.0); // Eq 3.10.3
            const kvv_d = kv_d.div(isat_drain.maxC(1e-30)); // Eq 3.10.4
            const t0_d = kvv_d.mul(kvv_d).addC(1.0 + ard_m); // Eq 3.10.5
            const t1_d = t0_d.sub(kvv_d.scale(2.0)).maxC(1e-38).sqrt()
                .add(t0_d.add(kvv_d.scale(2.0)).maxC(1e-38).sqrt()); // Eq 3.10.6
            const id_eff_d = kv_d.scale(2.0).div(t1_d.maxC(1e-38)); // Eq 3.10.7
            const ratio_alt_d = id_eff_d.div(isat_drain.maxC(1e-30));
            break :blk_d r_base_d.div(ratio_alt_d.neg().addC(1.0).maxC(1e-15)); // Eq 3.10.8
        } else blk_d: {
            const ratio_d = ids_abs.div(isat_drain.maxC(1e-30)).minC(0.99);
            const ratio_d_pow = ratio_d.maxC(1e-38).pow(mexpaccd);
            const inv_factor_d = ratio_d_pow.neg().addC(1.0).maxC(1e-38).log()
                .scale(-(mexpaccd - 1.0)).exp();
            break :blk_d r_base_d.mul(inv_factor_d);
        };
        const r_drain = r_contact_d.add(r_access_d).add(traprd.mul(v_cap)).add(rontrap);
        g_drain = S.con(1.0).div(r_drain.maxC(1e-15));
    }

    // Gate resistance -- Eq 3.10.9 (pure f64: no x dependence)
    if (model.rgatemod != 0) {
        const r_gate = rshg * (xgw + w / (3.0 * ngcon_f)) / (ngcon_f * nf_f * l); // Eq 3.10.9
        g_gate = if (r_gate > 0.0) 1.0 / r_gate else 1.0e3;
    }

    // ====================================================================
    // Parasitic resistance branch currents
    // ====================================================================
    // Source branch: S -- si
    const i_rs = v_s.sub(v_si).mul(g_source);
    // Drain branch: D -- di
    const i_rd = v_d.sub(v_di).mul(g_drain);
    // Gate branch: G -- gi (g_gate is f64)
    const i_rg = v_g.sub(v_gi).scale(g_gate);

    // ====================================================================
    // Trap sub-circuit currents
    // ====================================================================
    var i_trap1: S = S.con(0.0);
    var i_trap2: S = S.con(0.0);
    var i_trap1_ext: S = S.con(0.0);
    var i_trap2_ext: S = S.con(0.0);

    // TRAPMOD=1: RC network with diode
    if (is_trap1) {
        // i_trap_dio = idio*(exp(min(v_t1/vtv,EXP))-1)
        const i_trap_dio = v_t1.div(vtv).minC(EXP_MAX).exp().addC(-1.0).scale(idio);
        const i_trap_r = v_t1.div(vtv).mul(vtv).scale(1.0 / rdlag); // v_t1/rdlag (keep S deriv)
        _ = i_trap_r;
        const i_trap_r2 = v_t1.scale(1.0 / rdlag);
        i_trap1 = i_trap_dio.add(i_trap_r2);
        i_trap1_ext = i_trap1.neg();
    }

    // TRAPMOD=2: Two RC networks
    if (is_trap2) {
        i_trap1 = v_t1.scale(1.0 / rtrap1);
        i_trap2 = v_t2.scale(1.0 / rtrap2);
        i_trap1_ext = i_trap1.neg();
        i_trap2_ext = i_trap2.neg();
    }

    // TRAPMOD=3: Single RC network for dynamic Ron
    if (is_trap3) {
        // rtrap3_t = rtrap3*t_ratio^talpha (S)
        const rtrap3_t = t_ratio.maxC(1e-38).log().scale(talpha).exp().scale(rtrap3);
        i_trap1 = v_t1.div(rtrap3_t);
        i_trap1_ext = i_trap1.neg();
    }

    // TRAPMOD=4: Separate drain-lag / gate-lag
    if (is_trap4) {
        const vcap_dl = v_t1.scale(brcap).addC(arcap);
        i_trap1 = v_t1.sub(vcap_dl).scale(1.0 / remi);
        i_trap1_ext = i_trap1.neg();

        const vcap_gl = v_t2.scale(brcapg).addC(arcapg);
        i_trap2 = v_t2.sub(vcap_gl).scale(1.0 / remig);
        i_trap2_ext = i_trap2.neg();
    }

    // TRAPMOD=5: SRH dynamic trap
    if (is_trap5) {
        // phi_x = log(max(exp(min(alphax*vgs + alphaxd*vgd + betax*vds + gammax, EXP)) + etax, 1e-38))
        const arg_x = vgs_i.scale(alphax).add(vgd_i.scale(alphaxd)).add(vds_i.scale(betax)).addC(gammax);
        const phi_x = arg_x.minC(EXP_MAX).exp().addC(etax).maxC(1e-38).log();
        // en_x = eno*exp(min(ea/(KB*tdev) - ea/(KB*tnom_k), EXP)) (S via tdev)
        const en_x = tdev.scale(KB_EV).pow(-1.0).scale(ea_m).addC(-ea_m / (KB_EV * tnom_k))
            .minC(EXP_MAX).exp().scale(eno);
        // exp2phi_x = exp(min(2*phi_x,EXP))
        const exp2phi_x = phi_x.scale(2.0).minC(EXP_MAX).exp();
        // icn_x = cx*en_x*(vxmax - v_t1)*(exp2phi_x - 1)/2
        const icn_x = en_x.scale(cx_m).mul(v_t1.neg().addC(vxmax)).mul(exp2phi_x.addC(-1.0)).scale(0.5);
        const ien_x = en_x.scale(cx_m).mul(v_t1);
        i_trap1 = icn_x.sub(ien_x);
        i_trap1_ext = i_trap1.neg();

        const arg_y = vgs_i.scale(alphay).add(vgd_i.scale(alphayd)).add(vds_i.scale(betay)).addC(gammay);
        const phi_y = arg_y.minC(EXP_MAX).exp().addC(etay).maxC(1e-38).log();
        const en_y = tdev.scale(KB_EV).pow(-1.0).scale(ea1_m).addC(-ea1_m / (KB_EV * tnom_k))
            .minC(EXP_MAX).exp().scale(eno1);
        const exp2phi_y = phi_y.scale(2.0).minC(EXP_MAX).exp();
        const icn_y = en_y.scale(cy_m).mul(v_t2.neg().addC(vymax)).mul(exp2phi_y.addC(-1.0)).scale(0.5);
        const ien_y = en_y.scale(cy_m).mul(v_t2);
        i_trap2 = icn_y.sub(ien_y);
        i_trap2_ext = i_trap2.neg();
    }

    // ====================================================================
    // Self-heating -- thermal node current
    // ====================================================================
    var i_th: S = S.con(0.0);
    if (model.shmod != 0) {
        const rth = @max(rth0, 1e-15);
        // i_th = v_dt/rth - P_diss
        // P_diss = |ids*vds| + |igs*vgs| + |igd*vgd|
        const p_diss = ids.mul(vds_i).abs()
            .add(igs.mul(vgs_i).abs())
            .add(igd.mul(vgd_i).abs());
        i_th = v_dt.scale(1.0 / rth).sub(p_diss);
    }

    // ====================================================================
    // GMIN conditioning across intrinsic terminals
    // ====================================================================
    const i_gmin_gi_si = v_gi.sub(v_si).scale(GMIN);
    const i_gmin_gi_di = v_gi.sub(v_di).scale(GMIN);
    const i_gmin_di_si = v_di.sub(v_si).scale(GMIN);

    // ====================================================================
    // KCL Assembly
    // ====================================================================
    // Total intrinsic drain current (channel + FP + breakdown)
    const ids_total = ids.add(ids_fp_total).add(ids_bv);

    var out: [n_u]S = undefined;

    // External nodes: parasitic resistance branches
    out[G] = i_rg; // gate: current into Rg
    out[D] = i_rd; // drain: current into Rd
    out[Ss] = i_rs; // source: current into Rs
    out[B] = i_sb.add(i_db).neg(); // bulk: substrate leakage (into bulk)

    // Intrinsic gate node
    out[GI] = i_rg.neg().add(igs).add(igd).add(i_gmin_gi_si).add(i_gmin_gi_di);

    // Intrinsic drain node
    out[DI] = i_rd.neg().add(ids_total).sub(igd).add(i_db).add(i_gmin_di_si).sub(i_gmin_gi_di);

    // Intrinsic source node
    out[SI] = i_rs.neg().sub(ids_total).sub(igs).add(i_sb).sub(i_gmin_di_si).sub(i_gmin_gi_si);

    // Thermal node
    out[DT] = i_th;

    // Trap nodes
    out[T1] = i_trap1_ext;
    out[T2] = i_trap2_ext;

    return out;
}

// ============================================================================
// Field plate helper with S-typed temperature-scaled Voff (Voff can depend on
// t_ratio which is x-dependent under self-heating). Wraps the geometry helper.
// ============================================================================

fn fpDrainCurrentT(
    comptime S: type,
    vgs_fp: S,
    vds_raw: S,
    l_fp: f64,
    w: f64,
    nf_f: f64,
    voff_fp: S,
    cg_fp: f64,
    mob0_fp: f64,
    vsat_fp: f64,
    nfactor_fp: f64,
    cdscd_fp: f64,
    eta0_fp: f64,
    vdscale_fp: f64,
    gamma0_fp: f64,
    gamma1_fp: f64,
    delta_m: f64,
    imin_fp: f64,
    tdev: S,
    gdsmin: S,
) S {
    // vdsx = sqrt(vds^2 + 0.01)
    const vdsx_fp = vds_raw.mul(vds_raw).addC(0.01).sqrt();

    // DIBL-adjusted Voff
    const vdscale_smooth_fp = vdsx_fp.scale(vdscale_fp)
        .div(vdsx_fp.mul(vdsx_fp).addC(vdscale_fp * vdscale_fp).sqrt());
    const voff_dibl_fp = vdscale_smooth_fp.scale(eta0_fp).neg().add(voff_fp);

    // cdsc / vtv (vtv depends on tdev -- S)
    const cdsc_fp = vdsx_fp.scale(cdscd_fp).addC(1.0 + nfactor_fp);
    const vtv_fp = tdev.mul(cdsc_fp).scale(KB_EV);

    // Effective gate voltage
    const log_arg_fp = vtv_fp.mul(vtv_fp).scale(2.0 * w * Q_ELECTRON * DOS_CONST);
    const vgs_min_fp = voff_dibl_fp.add(vtv_fp.mul(
        S.con(l_fp).div(log_arg_fp).maxC(1e-38).log(),
    ));
    const vgs_diff_fp = vgs_fp.sub(vgs_min_fp);
    const vgs_eff_fp = vgs_diff_fp.add(vgs_diff_fp.mul(vgs_diff_fp).addC(0.0001).sqrt()).scale(0.5);

    const vg0_fp = vgs_eff_fp.sub(voff_dibl_fp);
    const vg0_eff_fp = vg0_fp.add(vg0_fp.mul(vg0_fp).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5);

    // Mobility (f64)
    const mu_eff_fp = mob0_fp;
    const thesat_fp = mu_eff_fp / (vsat_fp * l_fp);
    const two_vsat_l_fp = 2.0 * vsat_fp / @max(mu_eff_fp, 1e-38) * l_fp;
    const vdsat_fp = vg0_eff_fp.scale(two_vsat_l_fp).div(vg0_eff_fp.addC(two_vsat_l_fp));

    // Effective drain voltage
    const vds_vdsat_fp = vds_raw.div(vdsat_fp.maxC(1e-30));
    const vds_vdsat_pow_fp = vds_vdsat_fp.abs().maxC(1e-38).pow(delta_m);
    const vd_eff_fp = vds_raw.div(vds_vdsat_pow_fp.addC(1.0).log().scale(1.0 / delta_m).exp());

    // Surface potential -- beta_sp uses tdev; evaluate as pure constant via
    // t_ambient is not available here, so use value at the operating point.
    // beta_sp only scales the H() denominator; use tdev.val()-based constant.
    const beta_sp_fp = cg_fp / (Q_ELECTRON * DOS_CONST * KB_EV * tdev.val());

    const vf_s_fp = surfacePotentialT(S, vg0_fp, vg0_eff_fp, cg_fp, gamma0_fp, gamma1_fp, vtv_fp, beta_sp_fp);
    const psi_s_fp = vf_s_fp;

    const vgd0_fp = vg0_fp.sub(vd_eff_fp);
    const vgd_eff_fp = vgd0_fp.add(vgd0_fp.mul(vgd0_fp).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5);
    const vf_d_fp = surfacePotentialT(S, vgd0_fp, vgd_eff_fp, cg_fp, gamma0_fp, gamma1_fp, vtv_fp, beta_sp_fp);
    const psi_d_fp = vf_d_fp.add(vd_eff_fp);

    const psi_m_fp = psi_d_fp.add(psi_s_fp).scale(0.5);
    const psi_ds_fp = psi_d_fp.sub(psi_s_fp);

    // Drain current
    const mu_sat_fp = S.con(mu_eff_fp).div(
        psi_ds_fp.mul(psi_ds_fp).scale(thesat_fp * thesat_fp).addC(1.0).sqrt(),
    );
    var ids_fp = mu_sat_fp.scale(w / l_fp).scale(cg_fp)
        .mul(vg0_fp.sub(psi_m_fp).add(vtv_fp))
        .mul(psi_ds_fp);
    ids_fp = ids_fp.maxC(imin_fp);

    // CLM factor is 1 (lambda=0 in original)
    ids_fp = ids_fp.mul(vdsx_fp.sub(vd_eff_fp).scale(0.0).addC(1.0));

    // GDSMIN shunt
    ids_fp = ids_fp.add(vds_raw.mul(gdsmin));

    return ids_fp.scale(nf_f);
}

// surfacePotentialT: identical to surfacePotential but takes vtv as S (the FP
// path builds vtv from S tdev). beta_sp stays f64.
fn surfacePotentialT(
    comptime S: type,
    vg0: S,
    vg0_eff: S,
    cg: f64,
    gam0: f64,
    gam1: f64,
    vtv: S,
    beta_sp: f64,
) S {
    return surfacePotential(S, vg0, vg0_eff, cg, gam0, gam1, vtv, beta_sp);
}

// ============================================================================
// Charge Function (q) -- Intrinsic + Overlap + Fringing + Access + Substrate
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, _: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const G = @intFromEnum(U.gate);
    const D = @intFromEnum(U.drain);
    const Ss = @intFromEnum(U.source);
    const B = @intFromEnum(U.bulk);
    const GI = @intFromEnum(U.gi);
    const DI = @intFromEnum(U.di);
    const SI = @intFromEnum(U.si);
    const DT = @intFromEnum(U.dt);
    const T1 = @intFromEnum(U.t1);
    const T2 = @intFromEnum(U.t2);

    // ====================================================================
    // Cast parameters (x-independent)
    // ====================================================================
    const tnom: f64 = @as(f64, model.tnom);
    const tbar: f64 = @as(f64, model.tbar);
    const tepi: f64 = @as(f64, model.tepi);
    const eps_algan: f64 = @as(f64, model.epsilon);
    const gamma0: f64 = @as(f64, model.gamma0i);
    const gamma1: f64 = @as(f64, model.gamma1i);
    const voff: f64 = @as(f64, model.voff);
    const eta0: f64 = @as(f64, model.eta0);
    const vdscale: f64 = @as(f64, model.vdscale);
    const nfactor: f64 = @as(f64, model.nfactor);
    const cdscd_m: f64 = @as(f64, model.cdscd);
    const mob0: f64 = @as(f64, model.u0);
    const vsat_m: f64 = @as(f64, model.vsat);
    const delta_m: f64 = @as(f64, model.delta);
    const ua: f64 = @as(f64, model.ua);
    const ub: f64 = @as(f64, model.ub);
    const uc: f64 = @as(f64, model.uc);
    const at_m: f64 = @as(f64, model.at);
    const ute: f64 = @as(f64, model.ute);
    const kt1: f64 = @as(f64, model.kt1);
    _ = model.asub; // ASUB not used in Eq 3.3.4 per spec

    // Capacitance parameters
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cdso: f64 = @as(f64, model.cdso);
    const cgdl: f64 = @as(f64, model.cgdl);
    const vdsatcv: f64 = @as(f64, model.vdsatcv);
    const cbdo: f64 = @as(f64, model.cbdo);
    const cbso: f64 = @as(f64, model.cbso);
    const cbgo: f64 = @as(f64, model.cbgo);
    const cfg_m: f64 = @as(f64, model.cfg);
    const cfd_m: f64 = @as(f64, model.cfd);
    const cfgd_m: f64 = @as(f64, model.cfgd);
    _ = model.cfgdsm; // smoothing parameter reserved for future use
    const cfgd0: f64 = @as(f64, model.cfgd0);
    const cj0: f64 = @as(f64, model.cj0);
    const vbi_m: f64 = @as(f64, model.vbi);
    const mz: f64 = @as(f64, model.mz);
    _ = model.aj; // forward-bias limiting factor for depletion cap (absorbed into clamp)
    const dj_m: f64 = @as(f64, model.dj);
    const ktcfg: f64 = @as(f64, model.ktcfg);
    const ktcfgd: f64 = @as(f64, model.ktcfgd);
    const ktvbi_m: f64 = @as(f64, model.ktvbi);
    _ = model.rth0; // rth0 used in i function for thermal resistance
    const cth0: f64 = @as(f64, model.cth0);

    // QME
    const adosi: f64 = @as(f64, model.adosi);
    const bdosi: f64 = @as(f64, model.bdosi);
    const qm0i: f64 = @as(f64, model.qm0i);

    // QME for field plates
    const adosfp1: f64 = @as(f64, model.adosfp1);
    const bdosfp1: f64 = @as(f64, model.bdosfp1);
    const qm0fp1: f64 = @as(f64, model.qm0fp1);
    const adosfp2: f64 = @as(f64, model.adosfp2);
    const bdosfp2: f64 = @as(f64, model.bdosfp2);
    const qm0fp2: f64 = @as(f64, model.qm0fp2);
    const adosfp3: f64 = @as(f64, model.adosfp3);
    const bdosfp3: f64 = @as(f64, model.bdosfp3);
    const qm0fp3: f64 = @as(f64, model.qm0fp3);
    const adosfp4: f64 = @as(f64, model.adosfp4);
    const bdosfp4: f64 = @as(f64, model.bdosfp4);
    const qm0fp4: f64 = @as(f64, model.qm0fp4);

    // Cross-coupling & substrate cap
    const csubscalei: f64 = @as(f64, model.csubscalei);
    const csubscale1: f64 = @as(f64, model.csubscale1);
    const csubscale2: f64 = @as(f64, model.csubscale2);
    const csubscale3: f64 = @as(f64, model.csubscale3);
    const csubscale4: f64 = @as(f64, model.csubscale4);
    const cfp1scale: f64 = @as(f64, model.cfp1scale);
    const cfp2scale: f64 = @as(f64, model.cfp2scale);
    const cfp3scale: f64 = @as(f64, model.cfp3scale);
    const cfp4scale: f64 = @as(f64, model.cfp4scale);

    // FP parameters for charge
    const gamma0fp1: f64 = @as(f64, model.gamma0fp1);
    const gamma1fp1: f64 = @as(f64, model.gamma1fp1);
    const gamma0fp2: f64 = @as(f64, model.gamma0fp2);
    const gamma1fp2: f64 = @as(f64, model.gamma1fp2);
    const gamma0fp3: f64 = @as(f64, model.gamma0fp3);
    const gamma1fp3: f64 = @as(f64, model.gamma1fp3);
    const gamma0fp4: f64 = @as(f64, model.gamma0fp4);
    const gamma1fp4: f64 = @as(f64, model.gamma1fp4);
    const vofffp1: f64 = @as(f64, model.vofffp1);
    const vofffp2: f64 = @as(f64, model.vofffp2);
    const vofffp3: f64 = @as(f64, model.vofffp3);
    const vofffp4: f64 = @as(f64, model.vofffp4);
    const nfactorfp1: f64 = @as(f64, model.nfactorfp1);
    const nfactorfp2: f64 = @as(f64, model.nfactorfp2);
    const nfactorfp3: f64 = @as(f64, model.nfactorfp3);
    const nfactorfp4: f64 = @as(f64, model.nfactorfp4);
    const cdscdfp1: f64 = @as(f64, model.cdscdfp1);
    const cdscdfp2: f64 = @as(f64, model.cdscdfp2);
    const cdscdfp3: f64 = @as(f64, model.cdscdfp3);
    const cdscdfp4: f64 = @as(f64, model.cdscdfp4);
    const eta0fp1: f64 = @as(f64, model.eta0fp1);
    const eta0fp2: f64 = @as(f64, model.eta0fp2);
    const eta0fp3: f64 = @as(f64, model.eta0fp3);
    const eta0fp4: f64 = @as(f64, model.eta0fp4);
    const vdscalefp1: f64 = @as(f64, model.vdscalefp1);
    const vdscalefp2: f64 = @as(f64, model.vdscalefp2);
    const vdscalefp3: f64 = @as(f64, model.vdscalefp3);
    const vdscalefp4: f64 = @as(f64, model.vdscalefp4);
    const ktfp1: f64 = @as(f64, model.ktfp1);
    const ktfp2: f64 = @as(f64, model.ktfp2);
    const ktfp3: f64 = @as(f64, model.ktfp3);
    const ktfp4: f64 = @as(f64, model.ktfp4);
    const mob0fp1: f64 = @as(f64, model.u0fp1);
    const mob0fp2: f64 = @as(f64, model.u0fp2);
    const mob0fp3: f64 = @as(f64, model.u0fp3);
    const mob0fp4: f64 = @as(f64, model.u0fp4);
    const vsatfp1: f64 = @as(f64, model.vsatfp1);
    const vsatfp2: f64 = @as(f64, model.vsatfp2);
    const vsatfp3: f64 = @as(f64, model.vsatfp3);
    const vsatfp4: f64 = @as(f64, model.vsatfp4);

    // Instance
    const l: f64 = @as(f64, instance.l);
    const w: f64 = @as(f64, instance.w);
    const nf_f: f64 = @floatFromInt(instance.nf);
    const mult_q: f64 = @as(f64, instance.mult_q);
    const dfp1: f64 = @as(f64, instance.dfp1);
    const lfp1: f64 = @as(f64, instance.lfp1);
    const dfp2: f64 = @as(f64, instance.dfp2);
    const lfp2: f64 = @as(f64, instance.lfp2);
    const dfp3: f64 = @as(f64, instance.dfp3);
    const lfp3: f64 = @as(f64, instance.lfp3);
    const dfp4: f64 = @as(f64, instance.dfp4);
    const lfp4: f64 = @as(f64, instance.lfp4);
    const dtemp_inst: f64 = @as(f64, instance.dtemp);
    const dtemp_mod: f64 = @as(f64, model.dtemp_m);

    // Trap capacitances
    const cdlag: f64 = @as(f64, model.cdlag);
    const ctrap1: f64 = @as(f64, model.ctrap1);
    const ctrap2: f64 = @as(f64, model.ctrap2);
    const ctrap3: f64 = @as(f64, model.ctrap3);
    const cglag: f64 = @as(f64, model.cglag);
    const cx_m: f64 = @as(f64, model.cx);
    const cy_m: f64 = @as(f64, model.cy);

    // ====================================================================
    // Terminal voltages (S)
    // ====================================================================
    const v_gi = x[GI];
    const v_di = x[DI];
    const v_si = x[SI];
    const v_b = x[B];
    const v_dt = x[DT];
    const v_t1 = x[T1];
    const v_t2 = x[T2];
    _ = x[G];
    _ = x[D];
    _ = x[Ss];

    const vds_i = v_di.sub(v_si);
    const vgs_i = v_gi.sub(v_si);
    const vgd_i = v_gi.sub(v_di);
    const vbs_i = v_b.sub(v_si);

    // ====================================================================
    // Temperature
    // ====================================================================
    const tnom_k = tnom + 273.15;
    const t_ambient = tnom_k + dtemp_inst + dtemp_mod;
    const delta_t_sh = if (model.shmod != 0) v_dt else S.con(0.0);
    const tdev = delta_t_sh.addC(t_ambient); // S
    const t_ratio = tdev.scale(1.0 / tnom_k); // S
    const vtk = tdev.scale(KB_EV); // S

    // ====================================================================
    // Recompute channel quantities needed for charge
    // ====================================================================
    const cg = eps_algan / tbar;
    const cepi = eps_algan / tepi;

    const vdsx = vds_i.mul(vds_i).addC(0.01).sqrt();
    const cdsc = vdsx.scale(cdscd_m).addC(1.0 + nfactor);
    const vtv = tdev.mul(cdsc).scale(KB_EV);

    // DIBL
    const vdscale_smooth = vdsx.scale(vdscale)
        .div(vdsx.mul(vdsx).addC(vdscale * vdscale).sqrt());
    const voff_dibl = vdscale_smooth.scale(eta0).neg().addC(voff);
    const voff_t = voff_dibl.sub(t_ratio.addC(-1.0).scale(kt1)).add(vbs_i.scale(cepi / (cepi + cg)));

    // Effective Vgs
    const vgs_min_arg = vtv.mul(vtv).scale(2.0 * w * Q_ELECTRON * DOS_CONST);
    const vgs_min = voff_t.add(vtv.mul(S.con(l).div(vgs_min_arg).maxC(1e-38).log()));
    const vgs_diff = vgs_i.sub(vgs_min);
    const vgs_eff = vgs_diff.add(vgs_diff.mul(vgs_diff).addC(0.0001).sqrt()).scale(0.5);
    const vg0 = vgs_eff.sub(voff_t);
    const vg0_eff = vg0.add(vg0.mul(vg0).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5);

    // Mobility
    const mob0_t = t_ratio.maxC(1e-38).log().scale(ute).exp().scale(mob0);
    const qch_approx = vg0_eff.abs().scale(cg);
    const ey_eff = qch_approx.scale(1.0 / eps_algan);
    const eb = vbs_i.abs().scale(1.0 / tepi);
    const mu_denom = ey_eff.scale(ua).add(ey_eff.mul(ey_eff).scale(ub)).add(eb.scale(uc)).addC(1.0);
    const mu_eff = mob0_t.div(mu_denom);

    // Saturation velocity
    const vsat_t = t_ratio.maxC(1e-38).log().scale(at_m).exp().scale(vsat_m);
    const two_vsat_l = vsat_t.scale(2.0).div(mu_eff.maxC(1e-38)).scale(l);
    const vdsat = two_vsat_l.mul(vg0_eff).div(two_vsat_l.add(vg0_eff));

    // Effective drain voltage
    const vds_vdsat = vds_i.div(vdsat.maxC(1e-30));
    const vds_vdsat_pow = vds_vdsat.abs().maxC(1e-38).pow(delta_m);
    const vd_eff = vds_i.div(vds_vdsat_pow.addC(1.0).log().scale(1.0 / delta_m).exp());

    // Surface potentials -- beta_sp uses tdev (x-dependent); evaluate at ambient.
    const beta_sp = cg / (Q_ELECTRON * DOS_CONST * KB_EV * t_ambient);
    const vgd0 = vg0.sub(vd_eff);
    const vgd_eff_sp = vgd0.add(vgd0.mul(vgd0).addC(4.0 * EPPSI * EPPSI).sqrt()).scale(0.5);

    const vf_s = surfacePotential(S, vg0, vg0_eff, cg, gamma0, gamma1, vtv, beta_sp);
    const psi_s = vf_s;

    const vf_d = surfacePotential(S, vgd0, vgd_eff_sp, cg, gamma0, gamma1, vtv, beta_sp);
    const psi_d = vf_d.add(vd_eff);

    const psi_m = psi_d.add(psi_s).scale(0.5);

    // ====================================================================
    // QME-adjusted gate capacitance -- Eq 3.14.4
    // ====================================================================
    // qg_approx = cg*|vg0 - psi_m|
    const qg_approx = vg0.sub(psi_m).abs().scale(cg);
    // qme_denom = 1 + qg_approx/qm0
    const qme_denom = qg_approx.scale(1.0 / qm0i).addC(1.0);
    // qme_factor = adosi/qme_denom^bdosi = adosi*exp(-bdosi*log(max(qme_denom,1e-38)))
    const qme_factor = qme_denom.maxC(1e-38).log().scale(-bdosi).exp().scale(adosi);
    // cg_eff = eps/(tbar + qme_factor)
    const cg_eff = qme_factor.addC(tbar).pow(-1.0).scale(eps_algan);

    // ====================================================================
    // Intrinsic gate charge -- Eq 3.5.3
    // ====================================================================
    const vg0_psi_m_vtv = vg0.sub(psi_m).add(vtv);
    // numerator: vg0^2 + (1/3)(psi_d^2 + psi_s^2 + psi_d*psi_s)
    //            - vg0*(psi_d + psi_s - vtv) - vtv*psi_m
    const qg_num = vg0.mul(vg0)
        .add(psi_d.mul(psi_d).add(psi_s.mul(psi_s)).add(psi_d.mul(psi_s)).scale(1.0 / 3.0))
        .sub(vg0.mul(psi_d.add(psi_s).sub(vtv)))
        .sub(vtv.mul(psi_m));
    const qg_intr = cg_eff.scale(l * w).mul(qg_num).div(vg0_psi_m_vtv.maxC(1e-38)); // Eq 3.5.3

    // ====================================================================
    // Ward-Dutton Drain charge -- Eq 3.5.8
    // ====================================================================
    const vg0_psi_m_vtv_sq = vg0_psi_m_vtv.mul(vg0_psi_m_vtv);
    const qd_intr = wardDuttonDrain(S, cg_eff, l, w, vtv, vg0, psi_d, psi_s, vg0_psi_m_vtv_sq);

    const qs_intr = qg_intr.neg().sub(qd_intr); // Eq 3.5.6

    // ====================================================================
    // Overlap capacitances -- gate-source, gate-drain, drain-source
    // ====================================================================
    const q_cgso = vgs_i.scale(cgso * nf_f);
    const q_cgdo_base = vgd_i.scale(cgdo * nf_f);

    // CGDL bias dependence : vds_cv = vds/sqrt(1 + (vds/vdsatcv)^2)
    const vds_cv = vds_i.div(vds_i.scale(1.0 / vdsatcv).mul(vds_i.scale(1.0 / vdsatcv)).addC(1.0).sqrt());
    const q_cgdl = vds_cv.scale(cgdl * nf_f);

    const q_cgdo = q_cgdo_base.add(q_cgdl);
    const q_cdso = vds_i.scale(cdso * nf_f);

    // ====================================================================
    // Fringing capacitances -- Eq 3.3.15 (cfg_t, cfgd_t depend on t_ratio -> S)
    // ====================================================================
    const cfg_t = t_ratio.addC(-1.0).scale(ktcfg).neg().addC(cfg_m); // Eq 3.3.15
    const cfgd_t = t_ratio.addC(-1.0).scale(ktcfgd).neg().addC(cfgd_m);

    const q_cfg = cfg_t.mul(vgs_i).scale(nf_f); // gate fringing
    const q_cfd = vds_i.scale(cfd_m * nf_f); // drain fringing

    // CFGD -- gate-drain fringing with smoothing
    const q_cfgd = cfgd_t.addC(cfgd0).mul(vgd_i).scale(nf_f);

    // ====================================================================
    // Substrate capacitances
    // ====================================================================
    const q_cbdo = v_di.sub(v_b).scale(cbdo * nf_f);
    const q_cbso = v_si.sub(v_b).scale(cbso * nf_f);
    const q_cbgo = v_gi.sub(v_b).scale(cbgo * nf_f);

    // ====================================================================
    // Access region depletion capacitance -- Eq 3.11.1
    // ====================================================================
    const vbi_t = t_ratio.addC(-1.0).scale(ktvbi_m).neg().addC(vbi_m); // Eq 3.3.14 (S)
    var q_accd: S = S.con(0.0);
    if (cj0 > 0.0) {
        // v_ratio = 1 + vds/max(vbi_t,1e-30)
        const v_ratio = vds_i.div(vbi_t.maxC(1e-30)).addC(1.0);
        const v_ratio_safe = v_ratio.maxC(1e-30);
        // c_dep = cj0/v_ratio^mz = cj0*exp(-mz*log(v_ratio_safe))
        const c_dep = v_ratio_safe.log().scale(-mz).exp().scale(cj0); // Eq 3.11.1
        q_accd = c_dep.mul(vds_i).scale(nf_f * dj_m);
    }

    // ====================================================================
    // Substrate capacitance (cross-coupling) -- Eq 3.14.3
    // ====================================================================
    var q_sub_intr: S = S.con(0.0);
    if (csubscalei > 0.0) {
        const psi_ds_sq = psi_d.sub(psi_s).mul(psi_d.sub(psi_s));
        // denom_sub = 12*max(vg0 - vtk - psi_m, 1e-38)
        const denom_sub = vg0.sub(vtk).sub(psi_m).maxC(1e-38).scale(12.0);
        q_sub_intr = cg_eff.scale(-csubscalei * w * l)
            .mul(vg0.sub(psi_m).add(psi_ds_sq.div(denom_sub)));
    }

    // ====================================================================
    // Field plate charge contributions
    // ====================================================================
    var qg_fp_total: S = S.con(0.0);
    var qd_fp_total: S = S.con(0.0);
    var q_cc_total: S = S.con(0.0);
    var q_sub_fp_total: S = S.con(0.0);

    // FP1
    if (model.fp1mod != 0) {
        const cg_fp1_raw = eps_algan / dfp1;
        const vgs_fp1_q = if (model.fp1mod == 1) vgs_i else S.con(0.0);
        const voff_fp1_qt = t_ratio.addC(-1.0).scale(ktfp1).neg().addC(vofffp1);

        const r = fpCharge(S, .{
            .cg_raw = cg_fp1_raw,
            .l_fp = lfp1,
            .w = w,
            .dfp = dfp1,
            .voff_qt = voff_fp1_qt,
            .nfactor_fp = nfactorfp1,
            .cdscd_fp = cdscdfp1,
            .vdscale_fp = vdscalefp1,
            .eta0_fp = eta0fp1,
            .mob0_fp = mob0fp1,
            .vsat_fp = vsatfp1,
            .gamma0_fp = gamma0fp1,
            .gamma1_fp = gamma1fp1,
            .ados = adosfp1,
            .bdos = bdosfp1,
            .qm0 = qm0fp1,
            .cfpscale = cfp1scale,
            .csubscale = csubscale1,
            .vgs_fp = vgs_fp1_q,
            .vds_i = vds_i,
            .vdsx = vdsx,
            .tdev = tdev,
            .vtk = vtk,
            .delta_m = delta_m,
            .eps_algan = eps_algan,
        });
        qg_fp_total = qg_fp_total.add(r.qg);
        qd_fp_total = qd_fp_total.add(r.qd);
        q_cc_total = q_cc_total.add(r.qcc);
        q_sub_fp_total = q_sub_fp_total.add(r.qsub);
    }

    // FP2
    if (model.fp2mod != 0) {
        const cg_fp2_raw = eps_algan / dfp2;
        const vgs_fp2_q = if (model.fp2mod == 1) vgs_i else S.con(0.0);
        const voff_fp2_qt = t_ratio.addC(-1.0).scale(ktfp2).neg().addC(vofffp2);

        const r = fpCharge(S, .{
            .cg_raw = cg_fp2_raw,
            .l_fp = lfp2,
            .w = w,
            .dfp = dfp2,
            .voff_qt = voff_fp2_qt,
            .nfactor_fp = nfactorfp2,
            .cdscd_fp = cdscdfp2,
            .vdscale_fp = vdscalefp2,
            .eta0_fp = eta0fp2,
            .mob0_fp = mob0fp2,
            .vsat_fp = vsatfp2,
            .gamma0_fp = gamma0fp2,
            .gamma1_fp = gamma1fp2,
            .ados = adosfp2,
            .bdos = bdosfp2,
            .qm0 = qm0fp2,
            .cfpscale = cfp2scale,
            .csubscale = csubscale2,
            .vgs_fp = vgs_fp2_q,
            .vds_i = vds_i,
            .vdsx = vdsx,
            .tdev = tdev,
            .vtk = vtk,
            .delta_m = delta_m,
            .eps_algan = eps_algan,
        });
        qg_fp_total = qg_fp_total.add(r.qg);
        qd_fp_total = qd_fp_total.add(r.qd);
        q_cc_total = q_cc_total.add(r.qcc);
        q_sub_fp_total = q_sub_fp_total.add(r.qsub);
    }

    // FP3
    if (model.fp3mod != 0) {
        const cg_fp3_raw = eps_algan / dfp3;
        const vgs_fp3_q = if (model.fp3mod == 1) vgs_i else S.con(0.0);
        const voff_fp3_qt = t_ratio.addC(-1.0).scale(ktfp3).neg().addC(vofffp3);

        const r = fpCharge(S, .{
            .cg_raw = cg_fp3_raw,
            .l_fp = lfp3,
            .w = w,
            .dfp = dfp3,
            .voff_qt = voff_fp3_qt,
            .nfactor_fp = nfactorfp3,
            .cdscd_fp = cdscdfp3,
            .vdscale_fp = vdscalefp3,
            .eta0_fp = eta0fp3,
            .mob0_fp = mob0fp3,
            .vsat_fp = vsatfp3,
            .gamma0_fp = gamma0fp3,
            .gamma1_fp = gamma1fp3,
            .ados = adosfp3,
            .bdos = bdosfp3,
            .qm0 = qm0fp3,
            .cfpscale = cfp3scale,
            .csubscale = csubscale3,
            .vgs_fp = vgs_fp3_q,
            .vds_i = vds_i,
            .vdsx = vdsx,
            .tdev = tdev,
            .vtk = vtk,
            .delta_m = delta_m,
            .eps_algan = eps_algan,
        });
        qg_fp_total = qg_fp_total.add(r.qg);
        qd_fp_total = qd_fp_total.add(r.qd);
        q_cc_total = q_cc_total.add(r.qcc);
        q_sub_fp_total = q_sub_fp_total.add(r.qsub);
    }

    // FP4
    if (model.fp4mod != 0) {
        const cg_fp4_raw = eps_algan / dfp4;
        const vgs_fp4_q = if (model.fp4mod == 1) vgs_i else S.con(0.0);
        const voff_fp4_qt = t_ratio.addC(-1.0).scale(ktfp4).neg().addC(vofffp4);

        const r = fpCharge(S, .{
            .cg_raw = cg_fp4_raw,
            .l_fp = lfp4,
            .w = w,
            .dfp = dfp4,
            .voff_qt = voff_fp4_qt,
            .nfactor_fp = nfactorfp4,
            .cdscd_fp = cdscdfp4,
            .vdscale_fp = vdscalefp4,
            .eta0_fp = eta0fp4,
            .mob0_fp = mob0fp4,
            .vsat_fp = vsatfp4,
            .gamma0_fp = gamma0fp4,
            .gamma1_fp = gamma1fp4,
            .ados = adosfp4,
            .bdos = bdosfp4,
            .qm0 = qm0fp4,
            .cfpscale = cfp4scale,
            .csubscale = csubscale4,
            .vgs_fp = vgs_fp4_q,
            .vds_i = vds_i,
            .vdsx = vdsx,
            .tdev = tdev,
            .vtk = vtk,
            .delta_m = delta_m,
            .eps_algan = eps_algan,
        });
        qg_fp_total = qg_fp_total.add(r.qg);
        qd_fp_total = qd_fp_total.add(r.qd);
        q_cc_total = q_cc_total.add(r.qcc);
        q_sub_fp_total = q_sub_fp_total.add(r.qsub);
    }

    const qs_fp_total = qg_fp_total.neg().sub(qd_fp_total);

    // ====================================================================
    // Self-heating thermal capacitance charge
    // ====================================================================
    const q_th = if (model.shmod != 0) v_dt.scale(cth0) else S.con(0.0);

    // ====================================================================
    // Trap capacitance charges
    // ====================================================================
    var q_trap1: S = S.con(0.0);
    var q_trap2: S = S.con(0.0);

    if (model.trapmod == 1) {
        q_trap1 = v_t1.scale(cdlag);
    }
    if (model.trapmod == 2) {
        q_trap1 = v_t1.scale(ctrap1);
        q_trap2 = v_t2.scale(ctrap2);
    }
    if (model.trapmod == 3) {
        q_trap1 = v_t1.scale(ctrap3);
    }
    if (model.trapmod == 4) {
        q_trap1 = v_t1.scale(cdlag);
        q_trap2 = v_t2.scale(cglag);
    }
    if (model.trapmod == 5) {
        q_trap1 = v_t1.scale(cx_m);
        q_trap2 = v_t2.scale(cy_m);
    }

    // ====================================================================
    // Scale by multiplier
    // ====================================================================
    const scale = nf_f * mult_q;

    var out: [n_u]S = undefined;

    // External nodes -- no direct charge
    out[G] = S.con(0.0);
    out[D] = S.con(0.0);
    out[Ss] = S.con(0.0);
    out[B] = q_cbdo.neg().sub(q_cbso).sub(q_cbgo).add(q_sub_intr).add(q_sub_fp_total).scale(mult_q);

    // Intrinsic gate
    out[GI] = qg_intr.add(qg_fp_total).scale(scale)
        .add(q_cgso).add(q_cgdo).add(q_cfg).add(q_cfgd).add(q_cbgo)
        .add(q_cc_total.scale(mult_q))
        .scale(mult_q);

    // Intrinsic drain
    out[DI] = qd_intr.add(qd_fp_total).scale(scale)
        .sub(q_cgdo).add(q_cdso).add(q_cfd).sub(q_cfgd).add(q_cbdo).add(q_accd)
        .scale(mult_q);

    // Intrinsic source
    out[SI] = qs_intr.add(qs_fp_total).scale(scale)
        .sub(q_cgso).sub(q_cdso).sub(q_cfg).add(q_cbso)
        .scale(mult_q);

    // Thermal node
    out[DT] = q_th;

    // Trap nodes
    out[T1] = q_trap1;
    out[T2] = q_trap2;

    return out;
}

// Ward-Dutton drain charge polynomial (Eq 3.5.8), value form.
fn wardDuttonDrain(
    comptime S: type,
    cg_eff: S,
    l: f64,
    w: f64,
    vtv: S,
    vg0: S,
    psi_d: S,
    psi_s: S,
    vg0_psi_m_vtv_sq: S,
) S {
    const poly = psi_d.mul(psi_d).mul(psi_d).scale(12.0)
        .add(psi_s.mul(psi_s).mul(psi_s).scale(8.0))
        .add(psi_s.mul(psi_s).mul(psi_d.scale(16.0).sub(vtv.add(vg0.scale(8.0)).scale(5.0))))
        .add(psi_s.scale(2.0).mul(
            psi_d.mul(psi_d).scale(12.0)
                .sub(psi_d.mul(vtv.scale(5.0).add(vg0.scale(8.0))).scale(5.0))
                .add(vtv.add(vg0).mul(vtv.add(vg0.scale(4.0))).scale(10.0)),
        ))
        .add(psi_d.mul(psi_d).scale(15.0).mul(vtv.scale(3.0).add(vg0.scale(4.0))))
        .sub(vg0.scale(60.0).mul(vtv.add(vg0)).mul(vtv.add(vg0)))
        .add(psi_d.scale(20.0).mul(vtv.add(vg0)).mul(vtv.scale(2.0).add(vg0.scale(5.0))));
    return cg_eff.scale(-l * w).div(vg0_psi_m_vtv_sq.maxC(1e-38).scale(120.0)).mul(poly);
}

// Field-plate charge computation (Eq 3.5.3 / 3.5.8 + cross-coupling + substrate),
// value form. All x-dependent inputs are S; geometry/temperature-scaled params
// are f64 or S as noted.
const FpChargeArgs = struct {
    cg_raw: f64,
    l_fp: f64,
    w: f64,
    dfp: f64,
    voff_qt: anytype_dummy,
    nfactor_fp: f64,
    cdscd_fp: f64,
    vdscale_fp: f64,
    eta0_fp: f64,
    mob0_fp: f64,
    vsat_fp: f64,
    gamma0_fp: f64,
    gamma1_fp: f64,
    ados: f64,
    bdos: f64,
    qm0: f64,
    cfpscale: f64,
    csubscale: f64,
    vgs_fp: anytype_dummy,
    vds_i: anytype_dummy,
    vdsx: anytype_dummy,
    tdev: anytype_dummy,
    vtk: anytype_dummy,
    delta_m: f64,
    eps_algan: f64,
};

const anytype_dummy = @compileError("placeholder");
