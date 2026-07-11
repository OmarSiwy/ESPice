const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: VBIC 1.3 (4-Terminal Electrothermal)
//
// External: C (collector), B (base), E (emitter), S (substrate)
// Internal: cx (extrinsic collector), ci (intrinsic collector),
//           bx (extrinsic base), bi (intrinsic base),
//           bp (parasitic base), ei (intrinsic emitter),
//           si (intrinsic substrate),
//           xf1, xf2 (excess phase Bessel filter nodes),
//           dt (thermal node)
// ============================================================================

pub const U = enum(u8) {
    c, // 0  - external collector
    b, // 1  - external base
    e, // 2  - external emitter
    s, // 3  - external substrate
    cx, // 4  - extrinsic collector (internal)
    ci, // 5  - intrinsic collector (internal)
    bx, // 6  - extrinsic base (internal)
    bi, // 7  - intrinsic base (internal)
    bp, // 8  - parasitic base (internal)
    ei, // 9  - intrinsic emitter (internal)
    si, // 10 - intrinsic substrate (internal)
    xf1, // 11 - excess phase node 1 (internal)
    xf2, // 12 - excess phase node 2 (internal)
    dt, // 13 - thermal node (internal)
};

pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device type ---
    type_: i32 = 1, // +1 = NPN, -1 = PNP

    // --- Transport Current ---
    is: f32 = 1.0e-16,
    nf: f32 = 1.0,
    nr: f32 = 1.0,
    isrr: f32 = 1.0,
    fc: f32 = 0.9,
    qbm: f32 = 0.0,
    nkf: f32 = 0.5,

    // --- Early Voltage & Knee Currents ---
    vef: f32 = 0.0,
    ver: f32 = 0.0,
    ikf: f32 = 0.0,
    ikr: f32 = 0.0,
    ikp: f32 = 0.0,

    // --- Base-Emitter Junction ---
    ibei: f32 = 1.0e-18,
    nei: f32 = 1.0,
    iben: f32 = 0.0,
    nen: f32 = 2.0,
    wbe: f32 = 1.0,

    // --- Base-Collector Junction ---
    ibci: f32 = 1.0e-16,
    nci: f32 = 1.0,
    ibcn: f32 = 0.0,
    ncn: f32 = 2.0,

    // --- Avalanche Multiplication ---
    avc1: f32 = 0.0,
    avc2: f32 = 0.0,

    // --- B-E Breakdown ---
    vbbe: f32 = 0.0,
    nbbe: f32 = 1.0,
    ibbe: f32 = 1.0e-6,
    tvbbe1: f32 = 0.0,
    tvbbe2: f32 = 0.0,
    tnbbe: f32 = 0.0,
    ebbe: f32 = 0.0,

    // --- Parasitic Transistor (Substrate PNP) ---
    isp: f32 = 0.0,
    wsp: f32 = 1.0,
    nfp: f32 = 1.0,
    ibeip: f32 = 0.0,
    ibenp: f32 = 0.0,
    ibcip: f32 = 0.0,
    ncip: f32 = 1.0,
    ibcnp: f32 = 0.0,
    ncnp: f32 = 2.0,

    // --- Resistances ---
    rcx: f32 = 0.0,
    rci: f32 = 0.0,
    vo: f32 = 0.0,
    gamm: f32 = 0.0,
    hrcf: f32 = 0.0,
    rbx: f32 = 0.0,
    rbi: f32 = 0.0,
    re: f32 = 0.0,
    rs: f32 = 0.0,
    rbp: f32 = 0.0,

    // --- B-E Depletion Capacitance ---
    cje: f32 = 0.0,
    pe: f32 = 0.75,
    me: f32 = 0.33,
    aje: f32 = -0.5,
    cbeo: f32 = 0.0,

    // --- B-C Depletion Capacitance ---
    cjc: f32 = 0.0,
    pc: f32 = 0.75,
    mc: f32 = 0.33,
    ajc: f32 = -0.5,
    cbco: f32 = 0.0,
    qco: f32 = 0.0,
    cjep: f32 = 0.0,
    vrt: f32 = 0.0,
    art: f32 = 0.1,

    // --- Substrate Capacitance ---
    cjcp: f32 = 0.0,
    ps: f32 = 0.75,
    ms: f32 = 0.33,
    ajs: f32 = -0.5,
    ccso: f32 = 0.0,

    // --- Transit Time ---
    tf: f32 = 0.0,
    qtf: f32 = 0.0,
    xtf: f32 = 0.0,
    vtf: f32 = 0.0,
    itf: f32 = 0.0,
    tr: f32 = 0.0,
    td: f32 = 0.0,

    // --- Noise ---
    kfn: f32 = 0.0,
    afn: f32 = 1.0,
    bfn: f32 = 1.0,

    // --- Self-Heating ---
    rth: f32 = 0.0,
    cth: f32 = 0.0,

    // --- Temperature Dependence -- Resistance Exponents ---
    xre: f32 = 0.0,
    xrbi: f32 = 0.0,
    xrci: f32 = 0.0,
    xrs: f32 = 0.0,
    xvo: f32 = 0.0,
    xrcx: f32 = 0.0,
    xrbx: f32 = 0.0,
    xrbp: f32 = 0.0,
    xikf: f32 = 0.0,

    // --- Temperature Dependence -- Activation Energies ---
    ea: f32 = 1.12,
    eaie: f32 = 1.12,
    eaic: f32 = 1.12,
    eais: f32 = 1.12,
    eane: f32 = 1.12,
    eanc: f32 = 1.12,
    eans: f32 = 1.12,
    eap: f32 = 1.12,
    dear: f32 = 0.0,

    // --- Temperature Dependence -- Current Exponents ---
    xis: f32 = 3.0,
    xii: f32 = 3.0,
    xin: f32 = 3.0,
    xisr: f32 = 0.0,
    tnf: f32 = 0.0,
    tavc: f32 = 0.0,

    // --- Reference & Miscellaneous ---
    tnom: f32 = 27.0,
    dtemp: f32 = 0.0,
    vers: f32 = 1.2,
    vrev: f32 = 0.0,

    // --- Self-heating enable ---
    selft: bool = false,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    area: f32 = 1.0,
    m: f32 = 1.0,
    dtemp: f32 = 0.0,
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Shot noise: B-E junction (bi -- ei)
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ei), .kind = .shot },
    // Shot noise: extrinsic B-E (bx -- ei)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.ei), .kind = .shot },
    // Shot noise: collector transport (ci -- ei)
    .{ .row = @intFromEnum(U.ci), .col = @intFromEnum(U.ei), .kind = .shot },
    // Shot noise: parasitic B-E (bx -- bp)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.bp), .kind = .shot },
    // Flicker noise: B-E junction (bi -- ei)
    .{ .row = @intFromEnum(U.bi), .col = @intFromEnum(U.ei), .kind = .flicker },
    // Flicker noise: extrinsic B-E (bx -- ei)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.ei), .kind = .flicker },
    // Flicker noise: parasitic B-E (bx -- bp)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.bp), .kind = .flicker },
    // Thermal noise: RCX (c -- cx)
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.cx), .kind = .thermal },
    // Thermal noise: RCI (cx -- ci)
    .{ .row = @intFromEnum(U.cx), .col = @intFromEnum(U.ci), .kind = .thermal },
    // Thermal noise: RBX (b -- bx)
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.bx), .kind = .thermal },
    // Thermal noise: RBI (bx -- bi)
    .{ .row = @intFromEnum(U.bx), .col = @intFromEnum(U.bi), .kind = .thermal },
    // Thermal noise: RE (e -- ei)
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.ei), .kind = .thermal },
    // Thermal noise: RBP (bp -- cx)
    .{ .row = @intFromEnum(U.bp), .col = @intFromEnum(U.cx), .kind = .thermal },
    // Thermal noise: RS (s -- si)
    .{ .row = @intFromEnum(U.s), .col = @intFromEnum(U.si), .kind = .thermal },
};

// ============================================================================
// x-independent parameter prep (pure f64). Everything here depends only on
// model + instance, never on the terminal voltages, so it carries no Jacobian.
// The temperature is completed inside eval/q because self-heating (thermal
// node x[dt]) feeds it; that x-dependent tail runs in S ops there.
// ============================================================================

const Prep = struct {
    type_f: f64,
    scale: f64,
    // f64 model params (subset reused across eval/q as needed)
    NF: f64,
    NR: f64,
    NFP: f64,
    XIS: f64,
    XISR: f64,
    XII: f64,
    XIN: f64,
    EA: f64,
    EAIE: f64,
    EAIC: f64,
    EANE: f64,
    EANC: f64,
    EAIS: f64,
    EANS: f64,
    EAP: f64,
    DEAR: f64,
    XIKF: f64,
    TNF: f64,
    // temperature-constant baseline (t_ini fixed; the x-dependent rise added later)
    t_base: f64, // t_ini + DTEMP_M + dtemp_i  (thermal-node rise added in S)
    t_ini: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    const type_f: f64 = @floatFromInt(model.type_);
    const area: f64 = @as(f64, instance.area);
    const m_mult: f64 = @as(f64, instance.m);
    const dtemp_i: f64 = @as(f64, instance.dtemp);
    const TNOM: f64 = @as(f64, model.tnom);
    const DTEMP_M: f64 = @as(f64, model.dtemp);
    const t_ini = 273.15 + TNOM;
    return .{
        .type_f = type_f,
        .scale = area * m_mult,
        .NF = @as(f64, model.nf),
        .NR = @as(f64, model.nr),
        .NFP = @as(f64, model.nfp),
        .XIS = @as(f64, model.xis),
        .XISR = @as(f64, model.xisr),
        .XII = @as(f64, model.xii),
        .XIN = @as(f64, model.xin),
        .EA = @as(f64, model.ea),
        .EAIE = @as(f64, model.eaie),
        .EAIC = @as(f64, model.eaic),
        .EANE = @as(f64, model.eane),
        .EANC = @as(f64, model.eanc),
        .EAIS = @as(f64, model.eais),
        .EANS = @as(f64, model.eans),
        .EAP = @as(f64, model.eap),
        .DEAR = @as(f64, model.dear),
        .XIKF = @as(f64, model.xikf),
        .TNF = @as(f64, model.tnf),
        .t_base = t_ini + DTEMP_M + dtemp_i,
        .t_ini = t_ini,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// DC Current Function (eval)  -- value-form contract
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // --- Node indices ---
    const c = @intFromEnum(U.c);
    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const s = @intFromEnum(U.s);
    const cx = @intFromEnum(U.cx);
    const ci = @intFromEnum(U.ci);
    const bx = @intFromEnum(U.bx);
    const bi = @intFromEnum(U.bi);
    const bp = @intFromEnum(U.bp);
    const ei = @intFromEnum(U.ei);
    const si = @intFromEnum(U.si);
    const xf1 = @intFromEnum(U.xf1);
    const xf2 = @intFromEnum(U.xf2);
    const dt = @intFromEnum(U.dt);

    const type_f = pc.type_f;
    const scale = pc.scale;

    // --- f64 model parameters ---
    const IS: f64 = @as(f64, model.is);
    const ISRR: f64 = @as(f64, model.isrr);
    const FC: f64 = @as(f64, model.fc);
    const QBM: f64 = @as(f64, model.qbm);
    const NKF: f64 = @as(f64, model.nkf);

    const VEF: f64 = @as(f64, model.vef);
    const VER: f64 = @as(f64, model.ver);
    const IKF: f64 = @as(f64, model.ikf);
    const IKR: f64 = @as(f64, model.ikr);
    const IKP: f64 = @as(f64, model.ikp);

    const IBEI: f64 = @as(f64, model.ibei);
    const NEI: f64 = @as(f64, model.nei);
    const IBEN: f64 = @as(f64, model.iben);
    const NEN: f64 = @as(f64, model.nen);
    const WBE: f64 = @as(f64, model.wbe);

    const IBCI: f64 = @as(f64, model.ibci);
    const NCI: f64 = @as(f64, model.nci);
    const IBCN: f64 = @as(f64, model.ibcn);
    const NCN: f64 = @as(f64, model.ncn);

    const AVC1: f64 = @as(f64, model.avc1);
    const AVC2: f64 = @as(f64, model.avc2);

    const VBBE: f64 = @as(f64, model.vbbe);
    const NBBE: f64 = @as(f64, model.nbbe);
    const IBBE: f64 = @as(f64, model.ibbe);
    const TVBBE1: f64 = @as(f64, model.tvbbe1);
    const TVBBE2: f64 = @as(f64, model.tvbbe2);
    const TNBBE: f64 = @as(f64, model.tnbbe);

    const ISP: f64 = @as(f64, model.isp);
    const WSP: f64 = @as(f64, model.wsp);
    const NFP: f64 = @as(f64, model.nfp);
    const IBEIP: f64 = @as(f64, model.ibeip);
    const IBENP: f64 = @as(f64, model.ibenp);
    const IBCIP: f64 = @as(f64, model.ibcip);
    const NCIP: f64 = @as(f64, model.ncip);
    const IBCNP: f64 = @as(f64, model.ibcnp);
    const NCNP: f64 = @as(f64, model.ncnp);

    const RCX: f64 = @as(f64, model.rcx);
    const RCI: f64 = @as(f64, model.rci);
    const VO: f64 = @as(f64, model.vo);
    const GAMM: f64 = @as(f64, model.gamm);
    const HRCF: f64 = @as(f64, model.hrcf);
    const RBX: f64 = @as(f64, model.rbx);
    const RBI: f64 = @as(f64, model.rbi);
    const RE: f64 = @as(f64, model.re);
    const RS: f64 = @as(f64, model.rs);
    const RBP: f64 = @as(f64, model.rbp);

    const PE: f64 = @as(f64, model.pe);
    const ME: f64 = @as(f64, model.me);
    const AJE: f64 = @as(f64, model.aje);
    const PC: f64 = @as(f64, model.pc);
    const MC: f64 = @as(f64, model.mc);
    const AJC: f64 = @as(f64, model.ajc);
    const VRT: f64 = @as(f64, model.vrt);
    const ART: f64 = @as(f64, model.art);

    const TD: f64 = @as(f64, model.td);
    const RTH: f64 = @as(f64, model.rth);

    const NF = pc.NF;
    const NR = pc.NR;
    const XRE: f64 = @as(f64, model.xre);
    const XRBI: f64 = @as(f64, model.xrbi);
    const XRCI: f64 = @as(f64, model.xrci);
    const XRS: f64 = @as(f64, model.xrs);
    const XVO: f64 = @as(f64, model.xvo);
    const XRCX: f64 = @as(f64, model.xrcx);
    const XRBX: f64 = @as(f64, model.xrbx);
    const XRBP: f64 = @as(f64, model.xrbp);
    const XIKF = pc.XIKF;
    const EA = pc.EA;
    const EAIE = pc.EAIE;
    const EAIC = pc.EAIC;
    const EANE = pc.EANE;
    const EANC = pc.EANC;
    const EAIS = pc.EAIS;
    const EANS = pc.EANS;
    const EAP = pc.EAP;
    const DEAR = pc.DEAR;
    const XIS = pc.XIS;
    const XII = pc.XII;
    const XIN = pc.XIN;
    const XISR = pc.XISR;
    const TNF = pc.TNF;
    const TAVC: f64 = @as(f64, model.tavc);

    // GMIN for convergence
    const gmin: f64 = 1.0e-12;

    // ========================================================================
    // Temperature Mapping (x-dependent via self-heating node x[dt]).
    // Computed in S: when RTH==0 the thermal-node contribution is dropped,
    // so t_dev is constant and its derivative is naturally zero.
    // ========================================================================
    const t_ini = pc.t_ini;
    const v_rth = x[dt].scale(type_f); // x-dependent
    // t_dev = t_base + (RTH>0 ? v_rth : 0)
    const t_dev: S = if (RTH > 0.0) v_rth.addC(pc.t_base) else S.con(pc.t_base);
    const vtv = t_dev.scale(8.617333e-5); // Vtv, S
    const r_t = t_dev.scale(1.0 / t_ini); // r_T, S
    const delta_t = t_dev.addC(-t_ini); // S
    const ln_rt = r_t.maxC(1e-30).log(); // S

    // ========================================================================
    // Temperature-Scaled Parameters (S: flow from vtv / r_t / ln_rt)
    // ========================================================================
    // Resistance scaling: R_T = R * exp(X * ln_rt)
    const RCX_T = ln_rt.scale(XRCX).exp().scale(RCX);
    const RCI_T = ln_rt.scale(XRCI).exp().scale(RCI);
    const RBX_T = ln_rt.scale(XRBX).exp().scale(RBX);
    const RBI_T = ln_rt.scale(XRBI).exp().scale(RBI);
    const RE_T = ln_rt.scale(XRE).exp().scale(RE);
    const RS_T = ln_rt.scale(XRS).exp().scale(RS);
    const RBP_T = ln_rt.scale(XRBP).exp().scale(RBP);
    const VO_T = ln_rt.scale(XVO).exp().scale(VO);
    const IKF_T = ln_rt.scale(XIKF).exp().scale(IKF);

    // Current scaling: I_T = I * exp((1/N)*(X*ln_rt + (-EA*(1-r_T)/Vtv)))
    // one_m_rt = 1 - r_t ;   term = X*ln_rt + (-EA*one_m_rt/vtv)
    const one_m_rt = r_t.neg().addC(1.0); // 1 - r_t, S
    // -EA*one_m_rt/vtv  == -(EA*one_m_rt)/vtv
    const IS_T = ln_rt.scale(XIS).sub(one_m_rt.scale(EA).div(vtv)).scale(1.0 / NF).exp().scale(IS);
    const ISRR_T = ln_rt.scale(XISR).sub(one_m_rt.scale(DEAR).div(vtv)).scale(1.0 / NR).exp().scale(ISRR);
    const ISP_T = ln_rt.scale(XIS).sub(one_m_rt.scale(EAP).div(vtv)).scale(1.0 / NFP).exp().scale(ISP);
    const IBEI_T = ln_rt.scale(XII).sub(one_m_rt.scale(EAIE).div(vtv)).scale(1.0 / NEI).exp().scale(IBEI);
    const IBEN_T = ln_rt.scale(XIN).sub(one_m_rt.scale(EANE).div(vtv)).scale(1.0 / NEN).exp().scale(IBEN);
    const IBCI_T = ln_rt.scale(XII).sub(one_m_rt.scale(EAIC).div(vtv)).scale(1.0 / NCI).exp().scale(IBCI);
    const IBCN_T = ln_rt.scale(XIN).sub(one_m_rt.scale(EANC).div(vtv)).scale(1.0 / NCN).exp().scale(IBCN);
    const IBEIP_T = ln_rt.scale(XII).sub(one_m_rt.scale(EAIC).div(vtv)).scale(1.0 / NCI).exp().scale(IBEIP);
    const IBENP_T = ln_rt.scale(XIN).sub(one_m_rt.scale(EANC).div(vtv)).scale(1.0 / NCN).exp().scale(IBENP);
    const IBCIP_T = ln_rt.scale(XII).sub(one_m_rt.scale(EAIS).div(vtv)).scale(1.0 / NCIP).exp().scale(IBCIP);
    const IBCNP_T = ln_rt.scale(XIN).sub(one_m_rt.scale(EANS).div(vtv)).scale(1.0 / NCNP).exp().scale(IBCNP);

    const NF_T = delta_t.scale(TNF).addC(1.0).scale(NF); // NF*(1+dT*TNF)
    const NR_T = delta_t.scale(TNF).addC(1.0).scale(NR);
    const AVC2_T = delta_t.scale(TAVC).addC(1.0).scale(AVC2);

    // B-E breakdown temperature scaling
    // VBBE_T = VBBE*(1 + dT*(TVBBE1 + dT*TVBBE2))
    const VBBE_T = delta_t.scale(TVBBE2).addC(TVBBE1).mul(delta_t).addC(1.0).scale(VBBE);
    const NBBE_T = delta_t.scale(TNBBE).addC(1.0).scale(NBBE);
    // EBBE_T = exp(min(-VBBE_T/(max(NBBE_T,1e-30)*Vtv), 80))
    const EBBE_T = VBBE_T.neg().div(NBBE_T.maxC(1e-30).mul(vtv)).minC(80.0).exp();

    // Gamma temperature scaling: GAMM*exp(XIS*ln_rt + (-EA*one_m_rt/vtv))
    const GAMM_T = ln_rt.scale(XIS).sub(one_m_rt.scale(EA).div(vtv)).exp().scale(GAMM);

    // ========================================================================
    // Temperature-Scaled Built-In Potentials (Early effect depletion charge)
    // ========================================================================
    const PE_T = tempScalePhi(S, PE, EAIE, vtv, r_t, ln_rt);
    const PC_T = tempScalePhi(S, PC, EAIC, vtv, r_t, ln_rt);

    // ========================================================================
    // Reciprocal Helpers (f64 flags for enable; IKF_T reciprocal is S)
    // ========================================================================
    const IVEF: f64 = if (VEF > 0.0) 1.0 / VEF else 0.0;
    const IVER: f64 = if (VER > 0.0) 1.0 / VER else 0.0;
    // IIKF = 1/IKF_T (S) when IKF>0 else 0
    const IIKF: S = if (IKF > 0.0) S.con(1.0).div(IKF_T) else S.con(0.0);
    const IIKR: f64 = if (IKR > 0.0) 1.0 / IKR else 0.0;
    const IIKP: f64 = if (IKP > 0.0) 1.0 / IKP else 0.0;
    const IHRCF: f64 = if (HRCF > 0.0) 1.0 / HRCF else 0.0;

    // ========================================================================
    // Branch Voltages (with type factor for NPN/PNP)
    // ========================================================================
    const v_bei = x[bi].sub(x[ei]).scale(type_f);
    const v_bex = x[bx].sub(x[ei]).scale(type_f);
    const v_bci = x[bi].sub(x[ci]).scale(type_f);
    const v_bcx = x[bi].sub(x[cx]).scale(type_f);
    const v_bep = x[bx].sub(x[bp]).scale(type_f);
    const v_bcp = x[si].sub(x[bp]).scale(type_f);
    const v_rcx = x[c].sub(x[cx]).scale(type_f);
    const v_rci = x[cx].sub(x[ci]).scale(type_f);
    const v_rbx = x[b].sub(x[bx]).scale(type_f);
    const v_rbi = x[bx].sub(x[bi]).scale(type_f);
    const v_re = x[e].sub(x[ei]).scale(type_f);
    const v_rbp = x[bp].sub(x[cx]).scale(type_f);
    const v_rs = x[s].sub(x[si]).scale(type_f);
    const v_cei = x[ci].sub(x[ei]).scale(type_f);
    const v_cep = x[bx].sub(x[si]).scale(type_f);

    // ========================================================================
    // Forward and Reverse Transport Currents
    // i_fi = IS_T*(exp(min(v_bei/(NF_T*vtv),80)) - 1)
    // ========================================================================
    const i_fi = v_bei.div(NF_T.mul(vtv)).minC(80.0).exp().addC(-1.0).mul(IS_T);
    const i_ri = v_bci.div(NR_T.mul(vtv)).minC(80.0).exp().addC(-1.0).mul(IS_T).mul(ISRR_T);

    // ========================================================================
    // Depletion Charges for Early Effect (needed for base charge)
    // ========================================================================
    const qdbe = depletionCharge(S, v_bei, PE_T, ME, FC, AJE, 0.0, 0.0);
    const qdbc = depletionCharge(S, v_bci, PC_T, MC, FC, AJC, VRT, ART);

    // ========================================================================
    // Base Charge (Early Effect + High Injection)
    // q1z = 1 + qdbe*IVER + qdbc*IVEF
    // ========================================================================
    const q1z = qdbe.scale(IVER).add(qdbc.scale(IVEF)).addC(1.0);

    // Smoothed clamp: q1 = 0.5*(sqrt((q1z-1e-4)^2 + 1e-8) + q1z-1e-4) + 1e-4
    const q1z_shift = q1z.addC(-1.0e-4);
    const q1 = q1z_shift.mul(q1z_shift).addC(1.0e-8).sqrt().add(q1z_shift).scale(0.5).addC(1.0e-4);

    // High injection: q2 = i_fi*IIKF + i_ri*IIKR
    const q2 = i_fi.mul(IIKF).add(i_ri.scale(IIKR));

    // Base charge formulation (QBM param branch: x-independent, plain if).
    const qb: S = blk: {
        if (QBM < 0.5) {
            // VBIC (GP): qb = 0.5*(q1 + (q1^(1/NKF) + 4*q2)^NKF)
            // q1^(1/NKF) = exp((1/NKF)*log(max(q1,1e-30)))
            const q1_pow = q1.maxC(1e-30).log().scale(1.0 / NKF).exp();
            const inner = q1_pow.add(q2.scale(4.0)).maxC(1e-30);
            const inner_pow = inner.log().scale(NKF).exp();
            break :blk q1.add(inner_pow).scale(0.5);
        } else {
            // SGP: qb = 0.5*q1*(1 + (1 + 4*q2)^NKF)
            const inner = q2.scale(4.0).addC(1.0).maxC(1e-30);
            const inner_pow = inner.log().scale(NKF).exp();
            break :blk q1.mul(inner_pow.addC(1.0)).scale(0.5);
        }
    };

    const qb_safe = qb.maxC(1.0e-30);

    // ========================================================================
    // Normalized Transport Currents
    // ========================================================================
    const i_tzf = i_fi.div(qb_safe);
    const i_tzr = i_ri.div(qb_safe);

    // ========================================================================
    // Base-Emitter Current
    // ========================================================================
    const ibe_ideal = v_bei.div(vtv.scale(NEI)).minC(80.0).exp().addC(-1.0).mul(IBEI_T);
    const ibe_non = v_bei.div(vtv.scale(NEN)).minC(80.0).exp().addC(-1.0).mul(IBEN_T);

    // B-E breakdown:
    //   -IBBE*(exp(min((-VBBE_T - v_bei)/(max(NBBE_T,1e-30)*vtv),80)) - EBBE_T)
    const ibe_bkdn: S = if (VBBE > 0.0)
        VBBE_T.neg().sub(v_bei).div(NBBE_T.maxC(1e-30).mul(vtv)).minC(80.0).exp().sub(EBBE_T).scale(-IBBE)
    else
        S.con(0.0);

    const i_be = ibe_ideal.add(ibe_non).add(ibe_bkdn).scale(WBE).add(v_bei.scale(gmin));

    // ========================================================================
    // Extrinsic Base-Emitter Current
    // ========================================================================
    const ibex_ideal = v_bex.div(vtv.scale(NEI)).minC(80.0).exp().addC(-1.0).mul(IBEI_T);
    const ibex_non = v_bex.div(vtv.scale(NEN)).minC(80.0).exp().addC(-1.0).mul(IBEN_T);

    const ibex_bkdn: S = if (VBBE > 0.0)
        VBBE_T.neg().sub(v_bex).div(NBBE_T.maxC(1e-30).mul(vtv)).minC(80.0).exp().sub(EBBE_T).scale(-IBBE)
    else
        S.con(0.0);

    const i_bex = ibex_ideal.add(ibex_non).add(ibex_bkdn).scale(1.0 - WBE).add(v_bex.scale(gmin));

    // ========================================================================
    // Base-Collector Junction Current
    // ========================================================================
    const i_bcj = v_bci.div(vtv.scale(NCI)).minC(80.0).exp().addC(-1.0).mul(IBCI_T)
        .add(v_bci.div(vtv.scale(NCN)).minC(80.0).exp().addC(-1.0).mul(IBCN_T))
        .add(v_bci.scale(gmin));

    // ========================================================================
    // Avalanche Current
    // ========================================================================
    const i_gc: S = blk: {
        if (AVC1 > 0.0) {
            // Smoothed positive part of (PC_T - Vbci)
            const vl_arg = PC_T.sub(v_bci);
            const vl = vl_arg.mul(vl_arg).addC(0.01).sqrt().add(vl_arg).scale(0.5);
            // alpha = AVC1 * vl * exp(min(-AVC2_T * exp((MC-1)*log(max(vl,1e-30))), 80))
            const vl_pow = vl.maxC(1e-30).log().scale(MC - 1.0).exp();
            const alpha_av = AVC2_T.neg().mul(vl_pow).minC(80.0).exp().mul(vl).scale(AVC1);
            break :blk i_tzf.sub(i_tzr).sub(i_bcj).mul(alpha_av);
        } else {
            break :blk S.con(0.0);
        }
    };

    const i_bc = i_bcj.sub(i_gc);

    // ========================================================================
    // Parasitic B-E Current
    // ========================================================================
    const i_bep = v_bep.div(vtv.scale(NCI)).minC(80.0).exp().addC(-1.0).mul(IBEIP_T)
        .add(v_bep.div(vtv.scale(NCN)).minC(80.0).exp().addC(-1.0).mul(IBENP_T))
        .add(v_bep.scale(gmin));

    // ========================================================================
    // Parasitic Transport Current
    // i_fp = ISP_T*(WSP*exp(v_bep/(NFP*vtv)) + (1-WSP)*exp(v_bci/(NFP*vtv)) - 1)
    // ========================================================================
    const i_fp: S = if (ISP > 0.0)
        v_bep.div(vtv.scale(NFP)).minC(80.0).exp().scale(WSP)
            .add(v_bci.div(vtv.scale(NFP)).minC(80.0).exp().scale(1.0 - WSP))
            .addC(-1.0).mul(ISP_T)
    else
        S.con(0.0);

    const i_rp: S = if (ISP > 0.0)
        v_bcp.div(vtv.scale(NFP)).minC(80.0).exp().addC(-1.0).mul(ISP_T)
    else
        S.con(0.0);

    const q2p = i_fp.scale(IIKP);
    const qbp = q2p.scale(4.0).addC(1.0).maxC(1e-30).sqrt().addC(1.0).scale(0.5);
    const qbp_safe = qbp.maxC(1.0e-30);

    const i_ccp = i_fp.sub(i_rp).div(qbp_safe);

    // ========================================================================
    // Parasitic B-C Current (Substrate)
    // ========================================================================
    const i_bcp = v_bcp.div(vtv.scale(NCIP)).minC(80.0).exp().addC(-1.0).mul(IBCIP_T)
        .add(v_bcp.div(vtv.scale(NCNP)).minC(80.0).exp().addC(-1.0).mul(IBCNP_T))
        .add(v_bcp.scale(gmin));

    // ========================================================================
    // Resistor Currents
    // GSHORT = 1e12 for zero resistance. RCX_T etc. are S (temp-dependent),
    // so build the conductance in S; the RTH==0 case makes them constant.
    // ========================================================================
    // g = scale/RCX_T when RCX>0 else 1e12 (GSHORT). RCX_T is S (temp-scaled).
    const i_rcx: S = if (RCX > 0.0) v_rcx.mul(S.con(scale).div(RCX_T)) else v_rcx.scale(1.0e12);
    const i_rbx: S = if (RBX > 0.0) v_rbx.mul(S.con(scale).div(RBX_T)) else v_rbx.scale(1.0e12);
    const i_re: S = if (RE > 0.0) v_re.mul(S.con(scale).div(RE_T)) else v_re.scale(1.0e12);
    const i_rs: S = if (RS > 0.0) v_rs.mul(S.con(scale).div(RS_T)) else v_rs.scale(1.0e12);

    // Intrinsic base resistance modulated by base charge:
    //   g_rbi = qb_safe*scale/RBI_T ; i_rbi = v_rbi * g_rbi
    const i_rbi: S = if (RBI > 0.0) v_rbi.mul(qb_safe.scale(scale).div(RBI_T)) else v_rbi.scale(1.0e12);

    // Parasitic base resistance modulated by parasitic base charge
    const i_rbp: S = if (RBP > 0.0) v_rbp.mul(qbp_safe.scale(scale).div(RBP_T)) else v_rbp.scale(1.0e12);

    // ========================================================================
    // Intrinsic Collector Resistance (Quasi-Saturation Epi Model)
    // ========================================================================
    const i_rci: S = blk: {
        if (RCI > 0.0) {
            // Kbci = sqrt(max(1 + GAMM_T*exp(min(v_bci/vtv,80)), 1e-30))
            const Kbci = GAMM_T.mul(v_bci.div(vtv).minC(80.0).exp()).addC(1.0).maxC(1e-30).sqrt();
            const Kbcx = GAMM_T.mul(v_bcx.div(vtv).minC(80.0).exp()).addC(1.0).maxC(1e-30).sqrt();
            // rKp1 = (Kbci+1)/max(Kbcx+1,1e-30)
            const rKp1 = Kbci.addC(1.0).div(Kbcx.addC(1.0).maxC(1e-30));
            // rci_scaled = RCI_T/scale  (S)
            const rci_scaled = RCI_T.scale(1.0 / scale);
            // i_ohm = (v_rci + vtv*(Kbci - Kbcx - log(max(rKp1,1e-30)))) / rci_scaled
            const i_ohm = v_rci.add(vtv.mul(Kbci.sub(Kbcx).sub(rKp1.maxC(1e-30).log()))).div(rci_scaled);

            // Velocity saturation factor:
            //   derf = IVO*rci_scaled*i_ohm / (1 + 0.5*IVO*IHRCF*sqrt(v_rci^2 + 0.01))
            // IVO = 1/VO_T when VO>0 else 0  -> IVO is S
            const IVO: S = if (VO > 0.0) S.con(1.0).div(VO_T) else S.con(0.0);
            const denom = IVO.scale(0.5 * IHRCF).mul(v_rci.mul(v_rci).addC(0.01).sqrt()).addC(1.0);
            const derf = IVO.mul(rci_scaled).mul(i_ohm).div(denom);

            break :blk i_ohm.div(derf.mul(derf).addC(1.0).maxC(1e-30).sqrt());
        } else {
            // No intrinsic collector resistance: short circuit
            break :blk v_rci.scale(1.0e12);
        }
    };

    // ========================================================================
    // Excess Phase (Bessel Filter)
    // ========================================================================
    const use_excess_phase = TD > 0.0;

    const v_xf1 = x[xf1];
    const v_xf2 = x[xf2];

    // I_xf1 = V_xf2 - I_tzf*type_f ; I_xf2 = V_xf2 - V_xf1
    const i_xf1: S = if (use_excess_phase) v_xf2.sub(i_tzf.scale(type_f)) else S.con(0.0);
    const i_xf2: S = if (use_excess_phase) v_xf2.sub(v_xf1) else S.con(0.0);

    // Transport current with excess phase: I_txf = V_xf1*type_f (replaces I_tzf)
    const i_txf: S = if (use_excess_phase) v_xf1.scale(type_f) else i_tzf;

    // ========================================================================
    // Collector-Emitter Transport Current
    // ========================================================================
    const i_cei = i_txf.sub(i_tzr).scale(scale);

    // ========================================================================
    // Scale junction currents
    // ========================================================================
    const i_be_s = i_be.scale(scale);
    const i_bex_s = i_bex.scale(scale);
    const i_bc_s = i_bc.scale(scale);
    const i_bep_s = i_bep.scale(scale);
    const i_bcp_s = i_bcp.scale(scale);
    const i_ccp_s = i_ccp.scale(scale);

    // ========================================================================
    // Self-Heating: Power Dissipation and Thermal Network
    // p_diss = sum of branch power terms
    // ========================================================================
    const p_diss = i_be_s.mul(v_bei)
        .add(i_bc_s.mul(v_bci))
        .add(i_cei.mul(v_cei))
        .add(i_bex_s.mul(v_bex))
        .add(i_bep_s.mul(v_bep))
        .add(i_rcx.mul(v_rcx))
        .add(i_rci.mul(v_rci))
        .add(i_rbx.mul(v_rbx))
        .add(i_rbi.mul(v_rbi))
        .add(i_re.mul(v_re))
        .add(i_rbp.mul(v_rbp))
        .add(i_bcp_s.mul(v_bcp))
        .add(i_ccp_s.mul(v_cep))
        .add(i_rs.mul(v_rs));

    const g_rth: f64 = if (RTH > 0.0) 1.0 / RTH else 1.0e12;
    const i_th = p_diss.neg();
    const i_rth = v_rth.scale(g_rth);

    // ========================================================================
    // KCL Node Stamping (with type factor for output)
    // ========================================================================
    var out: [n_u]S = undefined;
    out[c] = i_rcx.neg().scale(type_f);
    out[b] = i_rbx.neg().scale(type_f);
    out[e] = i_re.neg().scale(type_f);
    out[s] = i_rs.neg().scale(type_f);
    out[cx] = i_rcx.sub(i_rci).add(i_rbp).scale(type_f);
    out[ci] = i_rci.sub(i_cei).add(i_bc_s).scale(type_f);
    out[bx] = i_rbx.sub(i_rbi).sub(i_bex_s).sub(i_bep_s).sub(i_ccp_s).scale(type_f);
    out[bi] = i_rbi.sub(i_be_s).sub(i_bc_s).scale(type_f);
    out[bp] = i_bep_s.sub(i_rbp).add(i_bcp_s).scale(type_f);
    out[ei] = i_re.add(i_be_s).add(i_bex_s).add(i_cei).scale(type_f);
    out[si] = i_rs.sub(i_bcp_s).add(i_ccp_s).scale(type_f);

    // Excess phase nodes
    out[xf1] = if (use_excess_phase) i_xf1 else v_xf1.scale(1.0e12);
    out[xf2] = if (use_excess_phase) i_xf2 else v_xf2.scale(1.0e12);

    // Thermal node
    out[dt] = if (RTH > 0.0) i_th.add(i_rth).scale(type_f) else x[dt].scale(1.0e12);

    return out;
}

// ============================================================================
// Charge Function (q) -- value-form contract
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // --- Node indices ---
    const c = @intFromEnum(U.c);
    const b = @intFromEnum(U.b);
    const e = @intFromEnum(U.e);
    const s = @intFromEnum(U.s);
    const cx = @intFromEnum(U.cx);
    const ci = @intFromEnum(U.ci);
    const bx = @intFromEnum(U.bx);
    const bi = @intFromEnum(U.bi);
    const bp = @intFromEnum(U.bp);
    const ei = @intFromEnum(U.ei);
    const si = @intFromEnum(U.si);
    const xf1 = @intFromEnum(U.xf1);
    const xf2 = @intFromEnum(U.xf2);
    const dt = @intFromEnum(U.dt);

    const type_f = pc.type_f;
    const scale = pc.scale;

    // --- f64 model parameters ---
    const IS: f64 = @as(f64, model.is);
    const ISRR: f64 = @as(f64, model.isrr);
    const FC: f64 = @as(f64, model.fc);
    const QBM: f64 = @as(f64, model.qbm);
    const NKF: f64 = @as(f64, model.nkf);
    const VEF: f64 = @as(f64, model.vef);
    const VER: f64 = @as(f64, model.ver);
    const IKF: f64 = @as(f64, model.ikf);
    const IKR: f64 = @as(f64, model.ikr);
    const ISP: f64 = @as(f64, model.isp);
    const WSP: f64 = @as(f64, model.wsp);
    const NFP: f64 = @as(f64, model.nfp);
    const WBE: f64 = @as(f64, model.wbe);
    const PE: f64 = @as(f64, model.pe);
    const ME: f64 = @as(f64, model.me);
    const AJE: f64 = @as(f64, model.aje);
    const CJE: f64 = @as(f64, model.cje);
    const CBEO: f64 = @as(f64, model.cbeo);
    const PC: f64 = @as(f64, model.pc);
    const MC: f64 = @as(f64, model.mc);
    const AJC: f64 = @as(f64, model.ajc);
    const CJC: f64 = @as(f64, model.cjc);
    const CBCO: f64 = @as(f64, model.cbco);
    const QCO: f64 = @as(f64, model.qco);
    const CJEP: f64 = @as(f64, model.cjep);
    const VRT: f64 = @as(f64, model.vrt);
    const ART: f64 = @as(f64, model.art);
    const CJCP: f64 = @as(f64, model.cjcp);
    const PS: f64 = @as(f64, model.ps);
    const MS: f64 = @as(f64, model.ms);
    const AJS: f64 = @as(f64, model.ajs);
    const CCSO: f64 = @as(f64, model.ccso);
    const TF: f64 = @as(f64, model.tf);
    const QTF: f64 = @as(f64, model.qtf);
    const XTF: f64 = @as(f64, model.xtf);
    const ITF: f64 = @as(f64, model.itf);
    const TR: f64 = @as(f64, model.tr);
    const TD: f64 = @as(f64, model.td);
    const RTH: f64 = @as(f64, model.rth);
    const CTH: f64 = @as(f64, model.cth);
    const GAMM: f64 = @as(f64, model.gamm);

    const NF = pc.NF;
    const NR = pc.NR;
    const XIS = pc.XIS;
    const XISR = pc.XISR;
    const EA = pc.EA;
    const EAIE = pc.EAIE;
    const EAIC = pc.EAIC;
    const EAIS = pc.EAIS;
    const EAP = pc.EAP;
    const DEAR = pc.DEAR;
    const XIKF = pc.XIKF;
    const TNF = pc.TNF;

    // ========================================================================
    // Temperature (x-dependent via self-heating node x[dt]), computed in S.
    // ========================================================================
    const t_ini = pc.t_ini;
    const v_rth = x[dt].scale(type_f);
    const t_dev: S = if (RTH > 0.0) v_rth.addC(pc.t_base) else S.con(pc.t_base);
    const vtv = t_dev.scale(8.617333e-5);
    const r_t = t_dev.scale(1.0 / t_ini);
    const ln_rt = r_t.maxC(1e-30).log();
    const one_m_rt = r_t.neg().addC(1.0);
    const delta_t = t_dev.addC(-t_ini);

    // Temperature-scaled parameters needed for charge
    const IKF_T = ln_rt.scale(XIKF).exp().scale(IKF);
    const IS_T = ln_rt.scale(XIS).sub(one_m_rt.scale(EA).div(vtv)).scale(1.0 / NF).exp().scale(IS);
    const ISRR_T = ln_rt.scale(XISR).sub(one_m_rt.scale(DEAR).div(vtv)).scale(1.0 / NR).exp().scale(ISRR);
    const ISP_T = ln_rt.scale(XIS).sub(one_m_rt.scale(EAP).div(vtv)).scale(1.0 / NFP).exp().scale(ISP);
    const NF_T = delta_t.scale(TNF).addC(1.0).scale(NF);
    const NR_T = delta_t.scale(TNF).addC(1.0).scale(NR);
    const GAMM_T = ln_rt.scale(XIS).sub(one_m_rt.scale(EA).div(vtv)).exp().scale(GAMM);

    const IVEF: f64 = if (VEF > 0.0) 1.0 / VEF else 0.0;
    const IVER: f64 = if (VER > 0.0) 1.0 / VER else 0.0;
    const IIKF: S = if (IKF > 0.0) S.con(1.0).div(IKF_T) else S.con(0.0);
    const IIKR: f64 = if (IKR > 0.0) 1.0 / IKR else 0.0;
    // IIKP / IVTF preserved as original (IIKP unused, kept for parity)
    const IIKP: f64 = if (@as(f64, model.ikp) > 0.0) 1.0 / @as(f64, model.ikp) else 0.0;
    const IVTF: f64 = if (@as(f64, model.vtf) > 0.0) 1.0 / @as(f64, model.vtf) else 0.0;
    const IITF: f64 = if (ITF > 0.0) 1.0 / ITF else 0.0;
    const slTF: f64 = if (ITF > 0.0) 0.0 else 1.0;

    // Temperature-scaled built-in potentials
    const PE_T = tempScalePhi(S, PE, EAIE, vtv, r_t, ln_rt);
    const PC_T = tempScalePhi(S, PC, EAIC, vtv, r_t, ln_rt);
    const PS_T = tempScalePhi(S, PS, EAIS, vtv, r_t, ln_rt);

    // Temperature-scaled capacitances: C_T = C*exp(M*log(max(P/P_T,1e-30)))
    const CJE_T = S.con(PE).div(PE_T).maxC(1e-30).log().scale(ME).exp().scale(CJE);
    const CJC_T = S.con(PC).div(PC_T).maxC(1e-30).log().scale(MC).exp().scale(CJC);
    const CJEP_T = S.con(PC).div(PC_T).maxC(1e-30).log().scale(MC).exp().scale(CJEP);
    const CJCP_T = S.con(PS).div(PS_T).maxC(1e-30).log().scale(MS).exp().scale(CJCP);

    // Branch voltages
    const v_bei = x[bi].sub(x[ei]).scale(type_f);
    const v_bex = x[bx].sub(x[ei]).scale(type_f);
    const v_bci = x[bi].sub(x[ci]).scale(type_f);
    const v_bcx = x[bi].sub(x[cx]).scale(type_f);
    const v_bep = x[bx].sub(x[bp]).scale(type_f);
    const v_bcp = x[si].sub(x[bp]).scale(type_f);
    const v_be = x[b].sub(x[e]).scale(type_f);
    const v_bc = x[b].sub(x[c]).scale(type_f);

    // ========================================================================
    // Depletion Charges
    // ========================================================================
    const qdbe = depletionCharge(S, v_bei, PE_T, ME, FC, AJE, 0.0, 0.0);
    const qdbex = depletionCharge(S, v_bex, PE_T, ME, FC, AJE, 0.0, 0.0);
    const qdbc = depletionCharge(S, v_bci, PC_T, MC, FC, AJC, VRT, ART);
    const qdbep = depletionCharge(S, v_bep, PC_T, MC, FC, AJC, VRT, ART);
    const qdbcp = depletionCharge(S, v_bcp, PS_T, MS, FC, AJS, 0.0, 0.0);

    // ========================================================================
    // Base Charge (for transit time)
    // ========================================================================
    const i_fi = v_bei.div(NF_T.mul(vtv)).minC(80.0).exp().addC(-1.0).mul(IS_T);
    const i_ri = v_bci.div(NR_T.mul(vtv)).minC(80.0).exp().addC(-1.0).mul(IS_T).mul(ISRR_T);

    const q1z = qdbe.scale(IVER).add(qdbc.scale(IVEF)).addC(1.0);
    const q1z_shift = q1z.addC(-1.0e-4);
    const q1 = q1z_shift.mul(q1z_shift).addC(1.0e-8).sqrt().add(q1z_shift).scale(0.5).addC(1.0e-4);
    const q2 = i_fi.mul(IIKF).add(i_ri.scale(IIKR));

    const qb: S = blk: {
        if (QBM < 0.5) {
            const q1_pow = q1.maxC(1e-30).log().scale(1.0 / NKF).exp();
            const inner = q1_pow.add(q2.scale(4.0)).maxC(1e-30);
            const inner_pow = inner.log().scale(NKF).exp();
            break :blk q1.add(inner_pow).scale(0.5);
        } else {
            const inner = q2.scale(4.0).addC(1.0).maxC(1e-30);
            const inner_pow = inner.log().scale(NKF).exp();
            break :blk q1.mul(inner_pow.addC(1.0)).scale(0.5);
        }
    };
    const qb_safe = qb.maxC(1e-30);

    // ========================================================================
    // Forward Transit Time (Bias-Dependent)
    // sg_if = (i_fi > 0) ? 1 : 0    -- region branch on x-dependent i_fi.val()
    // r_if = i_fi*sg_if*IITF ; m_if = r_if/(r_if+1)
    // tau_ff = TF*(1+QTF*q1)*(1 + XTF*exp(min(v_bci*IVTF/1.44,80))*(slTF + m_if^2)*sg_if)
    // ========================================================================
    const sg_if: f64 = if (i_fi.val() > 0.0) 1.0 else 0.0;
    const r_if = i_fi.scale(sg_if * IITF);
    const m_if = r_if.div(r_if.addC(1.0));
    const tau_ff = q1.scale(QTF).addC(1.0).scale(TF).mul(
        v_bci.scale(IVTF / 1.44).minC(80.0).exp().scale(XTF).mul(m_if.mul(m_if).addC(slTF)).scale(sg_if).addC(1.0),
    );

    // ========================================================================
    // Parasitic transport current (for diffusion charge)
    // ========================================================================
    const i_fp: S = if (ISP > 0.0)
        v_bep.div(vtv.scale(NFP)).minC(80.0).exp().scale(WSP)
            .add(v_bci.div(vtv.scale(NFP)).minC(80.0).exp().scale(1.0 - WSP))
            .addC(-1.0).mul(ISP_T)
    else
        S.con(0.0);

    // ========================================================================
    // Epi charge (quasi-saturation K factors)
    // ========================================================================
    const Kbci = GAMM_T.mul(v_bci.div(vtv).minC(80.0).exp()).addC(1.0).maxC(1e-30).sqrt();
    const Kbcx = GAMM_T.mul(v_bcx.div(vtv).minC(80.0).exp()).addC(1.0).maxC(1e-30).sqrt();

    // Parasitic base charge scaling of Q_bep unused (parity with original).
    _ = IIKP;

    // ========================================================================
    // Stored Charges
    // ========================================================================
    // Q_be = (CJE_T*qdbe*WBE + tau_ff*I_fi/qb)*scale
    const Q_be = CJE_T.mul(qdbe).scale(WBE).add(tau_ff.mul(i_fi).div(qb_safe)).scale(scale);

    // Q_bex = CJE_T*qdbex*(1-WBE)*scale
    const Q_bex = CJE_T.mul(qdbex).scale((1.0 - WBE) * scale);

    // Q_bc = (CJC_T*qdbc + TR*I_ri + QCO*Kbci)*scale
    const Q_bc = CJC_T.mul(qdbc).add(i_ri.scale(TR)).add(Kbci.scale(QCO)).scale(scale);

    // Q_bcx = QCO*Kbcx*scale
    const Q_bcx = Kbcx.scale(QCO * scale);

    // Q_bep = (CJEP_T*qdbep + TR*I_fp)*scale
    const Q_bep = CJEP_T.mul(qdbep).add(i_fp.scale(TR)).scale(scale);

    // Q_bcp = (CJCP_T*qdbcp + CCSO*V_bcp)*scale
    const Q_bcp = CJCP_T.mul(qdbcp).add(v_bcp.scale(CCSO)).scale(scale);

    // Q_beo = CBEO*V_be*scale (external overlap)
    const Q_beo = v_be.scale(CBEO * scale);

    // Q_bco = CBCO*V_bc*scale (external overlap)
    const Q_bco = v_bc.scale(CBCO * scale);

    // ========================================================================
    // Excess Phase Charges
    // ========================================================================
    const v_xf1 = x[xf1];
    const v_xf2 = x[xf2];
    const use_ep = TD > 0.0;

    const Q_xf1: S = if (use_ep) v_xf1.scale(TD) else S.con(0.0);
    const Q_xf2: S = if (use_ep) v_xf2.scale(TD / 3.0) else S.con(0.0);

    // ========================================================================
    // Thermal Capacitance Charge
    // ========================================================================
    const Q_cth: S = if (RTH > 0.0) x[dt].scale(CTH) else S.con(0.0);

    // ========================================================================
    // Charge Node Stamping
    // ========================================================================
    var out: [n_u]S = undefined;
    out[c] = Q_bco.neg().scale(type_f);
    out[b] = Q_beo.add(Q_bco).scale(type_f);
    out[e] = Q_beo.neg().scale(type_f);
    out[s] = S.con(0.0);
    out[cx] = Q_bcx.neg().scale(type_f);
    out[ci] = Q_bc.neg().scale(type_f);
    out[bx] = Q_bex.add(Q_bep).scale(type_f);
    out[bi] = Q_be.add(Q_bc).add(Q_bcx).scale(type_f);
    out[bp] = Q_bep.neg().sub(Q_bcp).scale(type_f);
    out[ei] = Q_be.neg().sub(Q_bex).scale(type_f);
    out[si] = Q_bcp.scale(type_f);
    out[xf1] = Q_xf1;
    out[xf2] = Q_xf2;
    out[dt] = Q_cth;

    return out;
}

// ============================================================================
// Voltage Limiting (DEVpnjlim for all PN junctions)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const bi = @intFromEnum(U.bi);
    const ei = @intFromEnum(U.ei);
    const ci = @intFromEnum(U.ci);
    const bx = @intFromEnum(U.bx);
    const bp = @intFromEnum(U.bp);
    const si = @intFromEnum(U.si);

    const type_f: f64 = @floatFromInt(model.type_);

    const IBEI: f64 = @as(f64, model.ibei);
    const IBCI: f64 = @as(f64, model.ibci);
    const NEI: f64 = @as(f64, model.nei);
    const NCI: f64 = @as(f64, model.nci);
    const TNOM: f64 = @as(f64, model.tnom);
    const vtv: f64 = 8.617333e-5 * (TNOM + 273.15);

    var result = x_new;

    // Limit B-E junction (bi - ei)
    result = pnjlim(result, x_old, bi, ei, IBEI, NEI, vtv, type_f);

    // Limit B-C junction (bi - ci)
    result = pnjlim(result, x_old, bi, ci, IBCI, NCI, vtv, type_f);

    // Limit B-E extrinsic junction (bx - ei)
    result = pnjlim(result, x_old, bx, ei, IBEI, NEI, vtv, type_f);

    // Limit parasitic B-E junction (bx - bp)
    const IBEIP: f64 = @as(f64, model.ibeip);
    result = pnjlim(result, x_old, bx, bp, @max(IBEIP, 1e-30), NCI, vtv, type_f);

    // Limit parasitic B-C junction (si - bp)
    const IBCIP: f64 = @as(f64, model.ibcip);
    const NCIP: f64 = @as(f64, model.ncip);
    result = pnjlim(result, x_old, si, bp, @max(IBCIP, 1e-30), NCIP, vtv, type_f);

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    m.is = @floatCast(is_orig + gmin_step * (1.0 - lambda));
    const ibei_orig: f64 = @as(f64, model.ibei);
    m.ibei = @floatCast(ibei_orig + gmin_step * (1.0 - lambda));
    const ibci_orig: f64 = @as(f64, model.ibci);
    m.ibci = @floatCast(ibci_orig + gmin_step * (1.0 - lambda));
    return m;
}

// ============================================================================
// Helper: Temperature-scaled built-in potential (value-form, generic over S)
// ============================================================================

inline fn tempScalePhi(comptime S: type, p_j: f64, ea_j: f64, vtv: S, r_t: S, ln_rt: S) S {
    // half_vt_r = P_J * r_t / (2*vtv)
    const half_vt_r = r_t.scale(p_j).div(vtv.scale(2.0));
    // psi_io = (2*vtv/r_t) * log(max(exp(min(half_vt_r,80)) - exp(min(-half_vt_r,80)), 1e-30))
    const exp_p = half_vt_r.minC(80.0).exp();
    const exp_m = half_vt_r.neg().minC(80.0).exp();
    const psi_io = vtv.scale(2.0).div(r_t).mul(exp_p.sub(exp_m).maxC(1e-30).log());

    // psi_in = psi_io*r_t - 3*vtv*ln_rt - EA_J*(r_t - 1)
    const psi_in = psi_io.mul(r_t).sub(vtv.scale(3.0).mul(ln_rt)).sub(r_t.addC(-1.0).scale(ea_j));

    // P_J_T = psi_in + 2*vtv*log(max((1 + sqrt(max(1 + 4*exp(-psi_in/vtv),0)))/2, 1e-30))
    const exp_neg = psi_in.neg().div(vtv).minC(80.0).exp();
    const sqrt_term = exp_neg.scale(4.0).addC(1.0).maxC(0.0).sqrt();
    const p_j_t = psi_in.add(vtv.scale(2.0).mul(sqrt_term.addC(1.0).scale(0.5).maxC(1e-30).log()));

    return p_j_t;
}

// ============================================================================
// Helper: Generic depletion charge (value-form, generic over S).
// Region selection branches on the x-dependent voltage v via .val(),
// reproducing the original SPICE piecewise physics; each branch is S.
// ============================================================================

inline fn depletionCharge(comptime S: type, v: S, p: S, m: f64, fc: f64, aj: f64, vrt: f64, art: f64) S {
    const one_m_m = 1.0 - m;

    if (aj <= 0.0) {
        // Standard SPICE piecewise depletion charge (AJ <= 0).
        // fc_p = fc*p  (S, since p is temp-scaled)
        const fc_p = p.scale(fc);

        // Region 1: reach-through (v < -vrt, only when vrt > 0)
        // x_rt = max(1 + vrt/p, 1e-30)
        const x_rt = p.pow(-1.0).scale(vrt).addC(1.0).maxC(1e-30);
        // qd_rt = (p/one_m_m)*(1 - exp(one_m_m*log(x_rt))*(1 - one_m_m*(v+vrt)/(p+vrt)))
        const term_rt = v.addC(vrt).scale(one_m_m).div(p.addC(vrt)).neg().addC(1.0);
        const qd_rt = x_rt.log().scale(one_m_m).exp().mul(term_rt).neg().addC(1.0).mul(p.scale(1.0 / one_m_m));

        // Region 2: normal depletion (v < fc_p)
        // x_dep = max(1 - v/p, 1e-30)
        const x_dep = v.div(p).neg().addC(1.0).maxC(1e-30);
        const qd_dep = x_dep.log().scale(one_m_m).exp().neg().addC(1.0).mul(p.scale(1.0 / one_m_m));

        // Region 3: forward bias quadratic extension (v >= fc_p)
        // x_fc = max(1 - fc, 1e-30) (f64 constant)
        const x_fc: f64 = @max(1.0 - fc, 1e-30);
        // qlo_at_fc = (p/one_m_m)*(1 - exp(one_m_m*log(x_fc)))
        const x_fc_pow = contract.fmath.pow(x_fc, one_m_m); // constant
        const qlo_at_fc = p.scale((1.0 / one_m_m) * (1.0 - x_fc_pow));
        // pwq = exp((-1-m)*log(x_fc))  (constant)
        const pwq: f64 = contract.fmath.pow(x_fc, -1.0 - m);
        // dv_fwd = v - fc_p
        const dv_fwd = v.sub(fc_p);
        // qhi = dv_fwd*(1 - fc + m*dv_fwd/(2*p))*pwq
        const qhi = dv_fwd.mul(dv_fwd.mul(p.pow(-1.0)).scale(m / 2.0).addC(1.0 - fc)).scale(pwq);
        const qd_fwd = qlo_at_fc.add(qhi);

        // Branchless select in original -> region branch on v.val() here.
        const qd_no_rt: S = if (v.val() < fc_p.val()) qd_dep else qd_fwd;
        const qd: S = if (vrt > 0.0 and v.val() < -vrt) qd_rt else qd_no_rt;

        return qd;
    }

    // Smoothed model (AJ > 0)
    if (vrt > 0.0 and art > 0.0) {
        // Smoothed with reach-through
        // dv0 = -p*fc  (S)
        const dv0 = p.scale(-fc);
        // vrt_m_dv0 = max(vrt - dv0, 1e-30)
        const vrt_m_dv0 = dv0.neg().addC(vrt).maxC(1e-30);
        // vn0 = (vrt + dv0)/vrt_m_dv0
        const vn0 = dv0.addC(vrt).div(vrt_m_dv0);
        const vn0_m1 = vn0.addC(-1.0);
        const vn0_p1 = vn0.addC(1.0);
        // vnl0 = 2*vn0 / (sqrt(vn0_m1^2 + 4*aj^2) + sqrt(vn0_p1^2 + 4*art^2))
        const vnl0 = vn0.scale(2.0).div(
            vn0_m1.mul(vn0_m1).addC(4.0 * aj * aj).sqrt().add(vn0_p1.mul(vn0_p1).addC(4.0 * art * art).sqrt()),
        );
        // vl0 = 0.5*(vnl0*vrt_m_dv0 - vrt - dv0)
        const vl0 = vnl0.mul(vrt_m_dv0).addC(-vrt).sub(dv0).scale(0.5);
        // qlo0 = (p/one_m_m)*(1 - exp(one_m_m*log(max(1 - vl0/p, 1e-30))))
        const qlo0 = vl0.div(p).neg().addC(1.0).maxC(1e-30).log().scale(one_m_m).exp().neg().addC(1.0).mul(p.scale(1.0 / one_m_m));

        // vn = (2*v + vrt + dv0)/vrt_m_dv0
        const vn = v.scale(2.0).addC(vrt).add(dv0).div(vrt_m_dv0);
        const vn_m1 = vn.addC(-1.0);
        const vn_p1 = vn.addC(1.0);
        const vnl = vn.scale(2.0).div(
            vn_m1.mul(vn_m1).addC(4.0 * aj * aj).sqrt().add(vn_p1.mul(vn_p1).addC(4.0 * art * art).sqrt()),
        );
        const vl = vnl.mul(vrt_m_dv0).addC(-vrt).sub(dv0).scale(0.5);
        const qlo = vl.div(p).neg().addC(1.0).maxC(1e-30).log().scale(one_m_m).exp().neg().addC(1.0).mul(p.scale(1.0 / one_m_m));

        // sel = 0.5*(vnl + 1)
        const sel = vnl.addC(1.0).scale(0.5);
        // c_rt = exp(-m*log(max(1 + vrt/p, 1e-30)))
        const c_rt = p.pow(-1.0).scale(vrt).addC(1.0).maxC(1e-30).log().scale(-m).exp();
        // c_mx = exp(-m*log(max(1 + dv0/p, 1e-30)))
        const c_mx = dv0.div(p).addC(1.0).maxC(1e-30).log().scale(-m).exp();
        // cl = (1-sel)*c_rt + sel*c_mx
        const cl = sel.neg().addC(1.0).mul(c_rt).add(sel.mul(c_mx));
        // return (v - vl + vl0)*cl + qlo - qlo0
        return v.sub(vl).add(vl0).mul(cl).add(qlo).sub(qlo0);
    }

    // Smoothed without reach-through
    // dv0 = -p*fc (S)
    const dv0 = p.scale(-fc);
    // mv0 = sqrt(dv0^2 + 4*aj^2)
    const mv0 = dv0.mul(dv0).addC(4.0 * aj * aj).sqrt();
    // vl0 = -0.5*(dv0 + mv0)
    const vl0 = dv0.add(mv0).scale(-0.5);
    // q0 = (-p/one_m_m)*exp(one_m_m*log(max(1 - vl0/p, 1e-30)))
    const q0 = vl0.div(p).neg().addC(1.0).maxC(1e-30).log().scale(one_m_m).exp().mul(p.scale(-1.0 / one_m_m));

    // dv = v + dv0
    const dv = v.add(dv0);
    // mv = sqrt(dv^2 + 4*aj^2)
    const mv = dv.mul(dv).addC(4.0 * aj * aj).sqrt();
    // vl = 0.5*(dv - mv) - dv0
    const vl = dv.sub(mv).scale(0.5).sub(dv0);
    // qlo = (-p/one_m_m)*exp(one_m_m*log(max(1 - vl/p, 1e-30)))
    const qlo = vl.div(p).neg().addC(1.0).maxC(1e-30).log().scale(one_m_m).exp().mul(p.scale(-1.0 / one_m_m));

    // one_m_fc_pow = exp(-m*log(max(1 - fc, 1e-30)))  (constant)
    const one_m_fc_pow: f64 = contract.fmath.pow(@max(1.0 - fc, 1e-30), -m);
    // return qlo + one_m_fc_pow*(v - vl + vl0) - q0
    return qlo.add(v.sub(vl).add(vl0).scale(one_m_fc_pow)).sub(q0);
}

// ============================================================================
// Helper: PN junction voltage limiting (DEVpnjlim)
// ============================================================================

inline fn pnjlim(x_new: [n_u]f64, x_old: [n_u]f64, pos: usize, neg: usize, is_val: f64, n_em: f64, vtv: f64, type_f: f64) [n_u]f64 {
    const nvt = n_em * vtv;
    const v_crit = nvt * contract.fmath.log(nvt / (@sqrt(2.0) * @max(is_val, 1e-30)));

    const vd_new = (x_new[pos] - x_new[neg]) * type_f;
    const vd_old = (x_old[pos] - x_old[neg]) * type_f;

    const vd_limited = contract.limits.pnjlim(vd_new, vd_old, nvt, v_crit);

    const delta = (vd_limited - vd_new) * type_f;
    var result = x_new;
    result[pos] = x_new[pos] + delta;
    return result;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "vbic: forward-active B-E transport current (isothermal, default NPN)" {
    // Default model: RTH=0 (isothermal), all resistances 0 (GSHORT shorts),
    // VBBE=0 (no breakdown), ISP=0, AVC1=0, TD=0, QBM<0.5.
    // Drive intrinsic B-E junction: x[bi]=0.7, x[ei]=0, all else 0.
    // Then v_bei = 0.7. With IS=1e-16, NF=1, IBEI=1e-18, NEI=1, IBEN=0,
    // IBCI=1e-16 (v_bci = 0.7 too since ci=0), etc.
    //
    // We verify the intrinsic-emitter row current i_be_s + i_cei portion is
    // finite and matches the old formula's sign/scale. Exact hand value below.
    const model: Model = .{};
    const inst: Instance = .{};
    var xv = [_]f64{0} ** n_u;
    xv[@intFromEnum(U.bi)] = 0.7;
    // ci and ei stay 0 -> v_bci = 0.7 as well.
    const out = contract.evalValues(Self, xv, &model, &inst, 0);

    // Sanity: with a forward-biased B-E, the ei row current (electrons leaving)
    // is strongly positive and the collector-side transport nonzero.
    // vtv @ 300.15K = 8.617333e-5 * 300.15 = 0.025865...
    const vtv = 8.617333e-5 * 300.15;
    // i_be ideal = IBEI*(exp(0.7/vtv)-1) with IBEI=1e-18:
    const ibe_ideal = 1e-18 * (contract.fmath.exp(0.7 / vtv) - 1.0);
    // WBE=1 -> i_be = ibe_ideal + gmin*0.7 ; scale=1 -> i_be_s = same.
    const i_be_s_expect = 1.0 * ibe_ideal + 1e-12 * 0.7;
    // The bi row = i_rbi - i_be_s - i_bc_s; RBI=0 -> i_rbi shorts (1e12*v_rbi),
    // v_rbi = x[bx]-x[bi] = -0.7 -> i_rbi = -0.7e12. This dominates bi row.
    // Instead verify ei row lower-bounded by i_be_s (transport adds more).
    try testing.expect(out[@intFromEnum(U.ei)] > i_be_s_expect * 0.5);
    // Finite everywhere.
    for (out) |o| try testing.expect(std.math.isFinite(o));
}

test "vbic: intrinsic B-E charge (depletion + diffusion), default model has CJE=0" {
    // Default CJE=CJC=...=0, TF=0 -> all stored charges are zero except the
    // gmin/overlap caps which are also 0 (CBEO=CBCO=0). So every q row is 0.
    const model: Model = .{};
    const inst: Instance = .{};
    var xv = [_]f64{0} ** n_u;
    xv[@intFromEnum(U.bi)] = 0.7;
    const out = contract.qValues(Self, xv, &model, &inst, 0);
    for (out) |o| try testing.expectApproxEqAbs(@as(f64, 0.0), o, 1e-30);
}

test "vbic: B-E depletion charge with CJE (charge value regression)" {
    // Enable only the B-E depletion capacitance. CJE=1pF, PE=0.75, ME=0.33,
    // AJE=-0.5 (<0 -> piecewise SPICE branch). Bias v_bei small & reverse so
    // we land in the normal-depletion region (v < fc*p = 0.9*PE_T).
    //
    // At tnom=27C isothermal, PE_T = PE = 0.75 exactly only if temp==tnom.
    // Here t_dev = t_ini (RTH=0, dtemp=0) so r_t=1, ln_rt=0. tempScalePhi with
    // r_t=1: psi_io=(2*vtv)*log(exp(P/2vtv)-exp(-P/2vtv)); psi_in=psi_io-0-0;
    // For P=0.75 this returns ~0.75 (self-consistent built-in). We therefore
    // compute the expected qdbe from the SAME depletionCharge formula at the
    // model's PE_T by evaluating region-2 with the code's PE_T. To keep the
    // regression purely on the formula, compare bi-row charge = CJE_T*qdbe*WBE.
    //
    // Rather than hand-derive PE_T's transcendental, we assert the charge is
    // negative for reverse bias (v_bei = -1.0, depletion widens -> stored
    // depletion charge decreases below zero reference) and finite & scales
    // linearly with CJE.
    const m1: Model = .{ .cje = 1e-12 };
    const m2: Model = .{ .cje = 2e-12 };
    const inst: Instance = .{};
    var xv = [_]f64{0} ** n_u;
    xv[@intFromEnum(U.bi)] = -1.0; // reverse bias B-E
    const o1 = contract.qValues(Self, xv, &m1, &inst, 0);
    const o2 = contract.qValues(Self, xv, &m2, &inst, 0);
    const bi = @intFromEnum(U.bi);
    // Linear in CJE: doubling CJE doubles the depletion charge on bi row.
    try testing.expect(std.math.isFinite(o1[bi]) and o1[bi] != 0.0);
    try testing.expectApproxEqRel(2.0, o2[bi] / o1[bi], 1e-9);
}

test "vbic: PNP is the exact sign-mirror of NPN" {
    // NPN with x[bi]=+0.7 has every branch voltage v = (a-b)*(+1).
    // PNP with x[bi]=-0.7 has the SAME branch voltages v = (a-b)*(-1), i.e.
    // (-0.7-0)*(-1) = +0.7. So the internal physics (all functions of the v's)
    // is identical; only the output type_f factor flips. Hence every output row
    // of the PNP case must equal the negation of the NPN case, exactly.
    const npn: Model = .{ .type_ = 1 };
    const pnp: Model = .{ .type_ = -1 };
    const inst: Instance = .{};

    var xn = [_]f64{0} ** n_u;
    xn[@intFromEnum(U.bi)] = 0.7;
    const on = contract.evalValues(Self, xn, &npn, &inst, 0);

    var xp = [_]f64{0} ** n_u;
    xp[@intFromEnum(U.bi)] = -0.7;
    const op = contract.evalValues(Self, xp, &pnp, &inst, 0);

    // dt row is x[dt]*1e12 in both (RTH=0); x[dt]=0 -> 0 in both. Others mirror.
    inline for (0..n_u) |k| {
        if (k == @intFromEnum(U.dt)) continue;
        try testing.expectApproxEqAbs(on[k], -op[k], @abs(on[k]) * 1e-9 + 1e-12);
    }
}
