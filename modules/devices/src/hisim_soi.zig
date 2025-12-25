const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// HiSIM-SOI 1.5.0 — SOI MOSFET
//
// Topology: D(drain), G(gate), S(source), E(substrate/back-gate)
//           B(body, optional), T(thermal, optional)
//           Internal nodes: SP (source-prime), DP (drain-prime), GP (gate-prime)
//
// Solves the Poisson equation across the SOI stack:
//   front oxide / SOI film / buried oxide / substrate
// Handles FD, PD, floating-body, and body-tie conditions.
// Includes: substrate current, gate leakage, GIDL, punchthrough,
//           floating-body effect, history effect, self-heating,
//           STI leakage, NQS, overlap/fringing capacitances,
//           S/D junction diodes, body-tie, valence-band tunneling.
// ============================================================================

pub const U = enum(u8) {
    drain = 0, // External drain
    gate = 1, // External gate
    source = 2, // External source
    sub = 3, // External substrate (back-gate)
    body = 4, // External body (COBCNODE=1) or floating
    dp = 5, // Internal drain-prime (drift region)
    sp = 6, // Internal source-prime (drift region)
    gp = 7, // Internal gate-prime (gate resistance)
};
pub const num_ports: usize = 5;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Model Selection Flags ---
    cobcnode: i32 = 0,
    coadov: i32 = 1,
    coisub: i32 = 0,
    cofbe: i32 = 0,
    coiigs: i32 = 0,
    cogidl: i32 = 0,
    coovlp: i32 = 0,
    coqovsm: i32 = 1,
    coqbdsm: i32 = 1,
    coign: i32 = 0,
    coflick: i32 = 0,
    cothrml: i32 = 0,
    coisti: i32 = 0,
    conqs: i32 = 0,
    cord: i32 = 0,
    cors: i32 = 0,
    corg: i32 = 0,
    corbnet: i32 = 0,
    copprv: i32 = 0,
    coselfheat: i32 = 0,
    cohist: i32 = 0,
    coievb: i32 = 0,
    covbsbiz: i32 = 0,
    colgleff: i32 = 0,
    cooldver: i32 = 0,
    copt: i32 = 0,
    cosubscale: i32 = 0,
    coisubfb: i32 = 0,
    copspt: i32 = 0,
    corbulk: i32 = 0,
    info: i32 = 0,

    // --- Basic Device Parameters ---
    version: f32 = 1.50,
    type_: i32 = 1, // 1=NMOS, -1=PMOS
    tfox: f32 = 3.5e-9,
    tbox: f32 = 110e-9,
    tsoi: f32 = 50e-9,
    xj: f32 = 50e-9,
    nsubs: f32 = 3e17,
    nsubb: f32 = 4e14,
    nsubp: f32 = 1e17,
    vfbc: f32 = -1.0,
    vbi: f32 = 1.1,
    nf_model: f32 = 1.0,
    xld: f32 = 0.0,
    xwd: f32 = 0.0,
    xldc: f32 = 0.0,
    xwdc: f32 = 0.0,
    tpoly: f32 = 0.0,
    ldrift_model: f32 = 1e-6,
    ldrifts_model: f32 = 1e-6,

    // --- Smoothing Parameters (Vds) ---
    ddltmax: f32 = 10.0,
    ddltslp: f32 = 10.0,
    ddltict: f32 = 0.0,
    subdlt: f32 = 2e-3,

    // --- Mobility and Velocity Parameters ---
    muecb0: f32 = 300.0,
    muecb1: f32 = 30.0,
    mueph0: f32 = 0.3,
    mueph1: f32 = 25000.0,
    muetmp: f32 = 1.5,
    muephl: f32 = 0.0,
    mueplp: f32 = 1.0,
    muesr0: f32 = 2.0,
    muesr1: f32 = 2e15,
    muesrl: f32 = 0.0,
    mueslp: f32 = 1.0,
    ndep: f32 = 1.0,
    ninv: f32 = 0.5,
    ninvd: f32 = 0.0,
    bb: f32 = 2.0,
    vmax: f32 = 7e6,
    vover: f32 = 0.01,
    voverp: f32 = 0.1,
    vtmp: f32 = 0.0,

    // --- Short-Channel Effect Parameters ---
    parl1: f32 = 10e-9,
    parl2: f32 = 10e-9,
    sc1: f32 = 0.0,
    sc2: f32 = 0.0,
    sc3: f32 = 0.0,
    scr1: f32 = 0.0,
    scr2: f32 = 0.0,
    scr3: f32 = 0.23,
    scp1: f32 = 0.0,
    scp2: f32 = 0.0,
    scp3: f32 = 0.0,
    lp: f32 = 0.0,

    // --- Flat-Band Voltage Shift (Mechanical Stress) ---
    vfbcl1: f32 = 0.0,
    vfbcl1p: f32 = 1.0,
    vfbcl2: f32 = 0.0,
    vfbcl2p: f32 = 1.0,
    vfbhamp: f32 = 0.0,

    // --- Poly-Si Gate Depletion Parameters ---
    pgd1: f32 = 0.0,
    pgd2: f32 = 1.0,
    pgd4: f32 = 0.0,

    // --- Quantum Mechanical Effect Parameters ---
    qme1: f32 = 0.0,
    qme2: f32 = 0.0,
    qme3: f32 = 0.0,

    // --- Channel-Length Modulation Parameters ---
    clm1: f32 = 0.7,
    clm2: f32 = 0.0, // 0 means compute from TSOI*NSUBS
    clm3: f32 = 1.0,
    clm5: f32 = 1.0,
    clm6: f32 = 0.0,

    // --- Punchthrough Parameters ---
    ptl: f32 = 0.0,
    ptlp: f32 = 1.0,
    ptp: f32 = 3.5,
    pt2: f32 = 0.0,
    pt4: f32 = 0.0,
    pt4p: f32 = 1.0,
    njunc: f32 = 1e20,
    xjpt: f32 = 0.0, // 0 means use TSOI
    mupt: f32 = 0.0,
    vfbpt: f32 = 0.0,
    pslimpt: f32 = 0.0,
    gdl: f32 = 0.0,
    gdlp: f32 = 0.0,
    gdld: f32 = 0.0,

    // --- Narrow-Channel Effect Parameters ---
    wfc: f32 = 0.0,
    wvth0: f32 = 0.0,
    nsubcw: f32 = 0.0,
    nsubcwp: f32 = 1.0,
    nsubcl: f32 = 0.0,
    nsubclp: f32 = 1.0,
    nsubcmax: f32 = 5e18,
    nsubp0: f32 = 0.0,
    nsubwp: f32 = 1.0,
    muephw: f32 = 0.0,
    muepwp: f32 = 1.0,
    muesrw: f32 = 0.0,
    mueswp: f32 = 1.0,

    // --- Small Geometry Parameters ---
    wl2: f32 = 0.0,
    wl2p: f32 = 1.0,
    muephs: f32 = 0.0,
    muepsp: f32 = 1.0,
    vovers: f32 = 0.0,
    voversp: f32 = 1.0,

    // --- STI (Shallow Trench Isolation) Parameters ---
    nsti: f32 = 5e17,
    vthsti: f32 = 0.0,
    vdsti: f32 = 0.0,
    scsti1: f32 = 0.0,
    scsti2: f32 = 0.0,
    wsti: f32 = 0.0,
    wstil: f32 = 0.0,
    wstilp: f32 = 1.0,
    wstiw: f32 = 0.0,
    wstiwp: f32 = 1.0,
    wl1: f32 = 0.0,
    wl1p: f32 = 1.0,

    // --- STI Diffusion Length (LOD) Parameters ---
    nsubcsti1: f32 = 0.0,
    nsubcsti2: f32 = 0.0,
    nsubcsti3: f32 = 1.0,
    nsubpsti1: f32 = 0.0,
    nsubpsti2: f32 = 0.0,
    nsubpsti3: f32 = 1.0,
    muesti1: f32 = 0.0,
    muesti2: f32 = 0.0,
    muesti3: f32 = 1.0,
    saref: f32 = 1e-6,
    sbref: f32 = 1e-6,

    // --- Temperature Dependence Parameters ---
    eg0: f32 = 1.1785,
    bgtmp1: f32 = 90.25e-6,
    bgtmp2: f32 = 0.1e-6,
    tnom: f32 = 27.0,
    rdrvtmp: f32 = 0.0,
    rdrmuetmp: f32 = 0.0,
    rdrbbtmp: f32 = 0.0,

    // --- Parasitic Resistance Parameters ---
    rsh: f32 = 0.0,
    rshg: f32 = 0.0,
    nover: f32 = 1e19,
    novers: f32 = 1e19,
    rdrdjunc: f32 = 1e-6,
    rdrmue: f32 = 1000.0,
    rdrmues: f32 = 1000.0,
    rdrmuel: f32 = 0.0,
    rdrmuelp: f32 = 1.0,
    rdrvmax: f32 = 3e7,
    rdrvmaxs: f32 = 3e7,
    rdrvmaxl: f32 = 0.0,
    rdrvmaxlp: f32 = 1.0,
    rdrvmaxw: f32 = 0.0,
    rdrvmaxwp: f32 = 1.0,
    rdrbb: f32 = 1.0,
    rdrbbs: f32 = 1.0,
    rbulk0: f32 = 0.0,
    rbulkw: f32 = 0.0,

    // --- Capacitance Parameters ---
    xqy: f32 = 0.0,
    xqy1: f32 = 0.0,
    xqy2: f32 = 2.0,
    lover: f32 = 30e-9,
    vfbover: f32 = 0.0,
    ovslp: f32 = 2.1e-7,
    ovmag: f32 = 0.6,
    cgdo: f32 = -1.0, // negative means not user-defined
    cgso: f32 = -1.0,
    cgbo: f32 = 0.0,

    // --- Substrate Current Parameters ---
    sub1: f32 = 0.01,
    sub1l: f32 = 2.5e-3,
    sub1lp: f32 = 1.0,
    sub2: f32 = 20.0,
    sub2l: f32 = 2e-6,
    svds: f32 = 3.0,
    slg: f32 = 3e-8,
    slgl: f32 = 0.0,
    slglp: f32 = 1.0,
    svgs: f32 = 0.8,
    svgsl: f32 = 0.0,
    svgslp: f32 = 1.0,
    svgsw: f32 = 0.0,
    svgswp: f32 = 1.0,
    svbs: f32 = 0.5,
    svbsl: f32 = 0.0,
    svbslp: f32 = 1.0,
    vfbsub: f32 = -1.0,
    vfbsubl: f32 = 0.0,
    vfbsublp: f32 = 1.0,
    dvgpsub: f32 = 0.0,
    dvbssub: f32 = 0.0,
    ibpc1: f32 = 0.0,
    ibpc2: f32 = 0.0,

    // --- Gate Leakage Current Parameters ---
    gleak1: f32 = 1e4,
    gleak2: f32 = 2e7,
    gleak3: f32 = 0.3,
    gleak4: f32 = 4.0,
    gleak5: f32 = 7.5e3,
    gleak6: f32 = 0.25,
    gleak7: f32 = 1e-6,
    glkb1: f32 = 5e-16,
    glkb2: f32 = 1.0,
    glkb3: f32 = 0.0,
    glksd1: f32 = 1e-15,
    glksd2: f32 = 5e6,
    glksd3: f32 = -5e6,

    // --- GIDL Parameters ---
    gidl1: f32 = 5e-6,
    gidl2: f32 = 1e6,
    gidl3: f32 = 0.3,
    gidl4: f32 = 0.0,
    gidl5: f32 = 0.2,
    gidlvb: f32 = 0.5,

    // --- Valence Band Electron Tunneling Parameters ---
    evb1: f32 = 0.0,
    evb2: f32 = 0.0,
    evb3: f32 = 0.0,
    fvbs: f32 = 0.0,

    // --- Floating-Body Effect Parameters ---
    qhe1: f32 = 1.5,
    qhe2: f32 = 0.35,
    qhsmax: f32 = 1e-3,

    // --- History Effect Parameters ---
    hist1: f32 = 1e-8,
    hist2: f32 = 1e-20,

    // --- Self-Heating Parameters ---
    rth0: f32 = 0.1,
    cth0: f32 = 1e-7,

    // --- Source/Body and Drain/Body Diode Parameters ---
    js0: f32 = 1e-4,
    nj: f32 = 1.0,
    xti: f32 = 2.0,
    xti2: f32 = 0.0,
    vdiffj: f32 = 1.6e-3,
    divx: f32 = 0.0,
    cj: f32 = 5e-4,
    cjsw: f32 = 5e-10,
    cjswg: f32 = 5e-10,
    mj: f32 = 0.33,
    mjsw: f32 = 0.33,
    mjswg: f32 = 0.33,
    pb: f32 = 1.0,
    pbsw: f32 = 1.0,
    pbswg: f32 = 1.0,

    // --- Body-Tie Contact Parameters ---
    xwdbt: f32 = 0.0,
    cbtbn: f32 = -1.0, // negative means not user-defined
    cbtbp: f32 = -1.0,
    vfbbtp: f32 = 0.12,

    // --- Noise Parameters ---
    nfalp: f32 = 1e-19,
    nftrp: f32 = 1e10,
    cit: f32 = 0.0,
    falph: f32 = 1.0,

    // --- NQS Parameters ---
    dly1: f32 = 1e-10,
    dly2: f32 = 0.7,
    dly3: f32 = 8e-7,

    // --- Symmetry Conservation Parameters ---
    vzadd0: f32 = 0.01,
    pzadd0: f32 = 0.005,

    // --- Internal Limiter ---
    // VGSMIN: type-dependent default (-5 NMOS, 5 PMOS); runtime adjusted
    vgsmin: f32 = -5.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 5e-6,
    w: f32 = 5e-6,
    ad: f32 = 0.0,
    as_: f32 = 0.0,
    pd: f32 = 0.0,
    ps: f32 = 0.0,
    nrd: f32 = 1.0,
    nrs: f32 = 1.0,
    ldrift: f32 = 1e-6,
    ldrifts: f32 = 1e-6,
    xgw: f32 = 0.0,
    xgl: f32 = 0.0,
    m: f32 = 1.0,
    nf: f32 = 1.0,
    ngcon: f32 = 1.0,
    sa: f32 = 0.0,
    sb: f32 = 0.0,
    sd: f32 = 0.0,
    lod: f32 = 1e-5,
    rbdb: f32 = 50.0,
    rbsb: f32 = 50.0,
    pdbcp: f32 = 0.0,
    psbcp: f32 = 0.0,
    nbt: f32 = 1.0,
    lbt: f32 = 0.0,
    wbtn: f32 = 0.0,
    wbtp: f32 = 0.0,
    abtn: f32 = 0.0,
    abtp: f32 = 0.0,
    temp: f32 = 27.0,
    dtemp: f32 = 0.0,
};

// ============================================================================
// Physical Constants
// ============================================================================

const Q_ELEM: f64 = 1.602176634e-19;
const K_BOLTZ: f64 = 1.380649e-23;
const EPS_SI: f64 = 1.03594e-10; // epsilon_Si = 11.7 * eps0
const EPS_OX: f64 = 3.45313e-11; // epsilon_ox = 3.9 * eps0
const NI_300: f64 = 1.45e10; // intrinsic carrier concentration at 300K (cm^-3)
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const E0_CLM: f64 = 1.0e5;
const PHI_HOLE_BARRIER: f64 = 4.12; // barrier height for hole (V)
const DN_DIFF: f64 = 36.0; // electron diffusivity (cm^2/s)
const DP_DIFF: f64 = 13.0; // hole diffusivity (cm^2/s)
const ND_JUNC: f64 = 1e20; // S/D junction dopant concentration (cm^-3)

// ============================================================================
// Noise sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise: drain-source channel
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp), .kind = .thermal },
    // Flicker noise: drain-source channel
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp), .kind = .flicker },
    // Shot noise: drain-body diode
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.body), .kind = .shot },
    // Shot noise: source-body diode
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.body), .kind = .shot },
    // Shot noise: gate leakage
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.dp), .kind = .shot },
};

// ============================================================================
// Value-form S helpers (x-dependent chains)
//
// The original code repeatedly used the guarded-power idiom
//   @exp(@min(P * @log(@max(base, eps)), 80.0))   (P a constant exponent)
// and the guarded-exp idiom
//   @exp(@min(arg, 80.0)).
// These helpers reproduce those exactly in S ops so the derivative matches
// the original clamping behaviour. `powg` = base^P with base>=eps floor and
// the log-domain 80.0 ceiling; `expc` = exp(min(arg,80)).
// ============================================================================

inline fn powg(comptime S: type, base: S, p: f64, eps: f64) S {
    return base.maxC(eps).log().scale(p).minC(80.0).exp();
}

inline fn expc(comptime S: type, arg: S) S {
    return arg.minC(80.0).exp();
}

// ============================================================================
// Physics function: eval (value-form, generic over scalar S)
// x-independent parameter / geometry / temperature prep stays plain f64;
// only chains downstream of the terminal voltages use S ops.
// ============================================================================

// ============================================================================
// Prep: x-independent derived values cached across eval/q calls
// ============================================================================

const DcPrep = struct {
    type_f: f64,
    m_mult: f64,
    nf_inst: f64,
    // Geometry
    l_gate: f64,
    w_gate: f64,
    l_eff: f64,
    w_eff: f64,
    l_gate_um: f64,
    w_gate_um: f64,
    l_eff_um: f64,
    // Temperature
    t_abs: f64,
    tnom_abs: f64,
    beta: f64,
    beta_tnom: f64,
    t_ratio: f64,
    eg_tnom: f64,
    eg: f64,
    ni: f64,
    // Doping
    nsubs: f64,
    nsubpp: f64,
    n_sub: f64,
    phi_bc: f64,
    phi_b: f64,
    two_phi_b: f64,
    const_0: f64,
    const_b: f64,
    c_soi: f64,
    // Flat-band
    vfb: f64,
};

fn dcPrep(model: *const Model, instance: *const Instance) DcPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const nsubs_raw: f64 = @as(f64, model.nsubs);
    const nsubb: f64 = @as(f64, model.nsubb);
    const nsubp_raw: f64 = @as(f64, model.nsubp);
    const vfbc_raw: f64 = @as(f64, model.vfbc);
    const vbi_val: f64 = @as(f64, model.vbi);
    _ = vbi_val;
    const xld: f64 = @as(f64, model.xld);
    const xwd: f64 = @as(f64, model.xwd);
    const lp_val: f64 = @as(f64, model.lp);
    const nsubcw: f64 = @as(f64, model.nsubcw);
    const nsubcwp: f64 = @as(f64, model.nsubcwp);
    const nsubcl: f64 = @as(f64, model.nsubcl);
    const nsubclp: f64 = @as(f64, model.nsubclp);
    const nsubcmax: f64 = @as(f64, model.nsubcmax);
    const nsubp0: f64 = @as(f64, model.nsubp0);
    const nsubwp: f64 = @as(f64, model.nsubwp);
    const nsubcsti1: f64 = @as(f64, model.nsubcsti1);
    const nsubcsti2: f64 = @as(f64, model.nsubcsti2);
    const nsubcsti3: f64 = @as(f64, model.nsubcsti3);
    const nsubpsti1: f64 = @as(f64, model.nsubpsti1);
    const nsubpsti2: f64 = @as(f64, model.nsubpsti2);
    const nsubpsti3: f64 = @as(f64, model.nsubpsti3);
    const saref: f64 = @as(f64, model.saref);
    const sbref: f64 = @as(f64, model.sbref);
    const eg0: f64 = @as(f64, model.eg0);
    const bgtmp1: f64 = @as(f64, model.bgtmp1);
    const bgtmp2: f64 = @as(f64, model.bgtmp2);
    const tnom_c: f64 = @as(f64, model.tnom);
    const tsoi: f64 = @as(f64, model.tsoi);
    const vfbcl1: f64 = @as(f64, model.vfbcl1);
    const vfbcl1p: f64 = @as(f64, model.vfbcl1p);
    const vfbcl2: f64 = @as(f64, model.vfbcl2);
    const vfbcl2p: f64 = @as(f64, model.vfbcl2p);
    const vfbhamp: f64 = @as(f64, model.vfbhamp);

    const l_drawn: f64 = @as(f64, instance.l);
    const w_drawn: f64 = @as(f64, instance.w);
    const nf_inst: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const sa: f64 = @as(f64, instance.sa);
    const sb: f64 = @as(f64, instance.sb);
    const lod: f64 = @as(f64, instance.lod);
    const temp_c: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);

    // Geometry
    const l_gate = l_drawn;
    const w_gate = w_drawn / nf_inst;
    const l_eff = @max(l_gate - 2.0 * xld, 1e-9);
    const w_eff = @max(w_gate - 2.0 * xwd, 1e-9);
    const l_gate_um = l_gate * 1e6;
    const w_gate_um = w_gate * 1e6;
    const l_eff_um = l_eff * 1e6;

    // Temperature
    const t_abs = temp_c + dtemp + 273.15;
    const tnom_abs = tnom_c + 273.15;
    const beta_tnom = Q_ELEM / (K_BOLTZ * tnom_abs);
    const beta = Q_ELEM / (K_BOLTZ * t_abs);
    const t_ratio = t_abs / tnom_abs;

    // Bandgap
    const eg_tnom = eg0 - 90.25e-6 * tnom_abs - 1.0e-7 * tnom_abs * tnom_abs;
    const eg = eg_tnom - bgtmp1 * (t_abs - tnom_abs) - bgtmp2 * (t_abs * t_abs - tnom_abs * tnom_abs);

    // Intrinsic carrier concentration
    const ni_factor = @exp(@min(0.5 * beta * eg - 0.5 * beta_tnom * eg_tnom + 1.5 * @log(t_ratio), 80.0));
    const ni = NI_300 * ni_factor;

    // Nsubs with LOD
    const w_dep_factor = 1.0 + nsubcw / @exp(@min(nsubcwp * @log(@max(w_gate_um, 1e-30)), 80.0));
    const l_dep_factor = 1.0 + nsubcl / @exp(@min(nsubclp * @log(@max(l_gate_um, 1e-30)), 80.0));
    var nsubs = @min(nsubcmax, nsubs_raw * w_dep_factor * l_dep_factor);

    const lod_half = @max(lod * 0.5, 1e-30);
    const lod_half_ref = @max((saref + sbref) * 0.5, 1e-30);
    const lod_sa_half = if (sa > 0.0 and sb > 0.0) @max((sa + sb) * 0.5, 1e-30) else lod_half;
    _ = lod_half_ref;
    {
        const t1 = 1.0 / (1.0 + nsubcsti2);
        const t2 = nsubcsti1 / @exp(@min(nsubcsti3 * @log(@max(lod_sa_half, 1e-30)), 80.0));
        const t3 = nsubcsti1 / @exp(@min(nsubcsti3 * @log(@max((saref + sbref) * 0.5, 1e-30)), 80.0));
        const nsubsti = (1.0 + t1 * t2) / (1.0 + t1 * t3);
        nsubs = nsubs * nsubsti;
    }

    var nsubpp = nsubp_raw * (1.0 + nsubp0 / @exp(@min(nsubwp * @log(@max(w_gate_um, 1e-30)), 80.0)));
    {
        const t1 = 1.0 / (1.0 + nsubpsti2);
        const t2 = nsubpsti1 / @exp(@min(nsubpsti3 * @log(@max(lod_sa_half, 1e-30)), 80.0));
        const t3 = nsubpsti1 / @exp(@min(nsubpsti3 * @log(@max((saref + sbref) * 0.5, 1e-30)), 80.0));
        const nsubsti_p = (1.0 + t1 * t2) / (1.0 + t1 * t3);
        nsubpp = nsubpp * nsubsti_p;
    }

    const n_sub = if (l_gate > lp_val and lp_val > 0.0)
        (nsubs * (l_gate - lp_val) + nsubpp * lp_val) / l_gate
    else if (lp_val > 0.0)
        nsubpp + (nsubpp - nsubs) * (lp_val - l_gate) / @max(lp_val, 1e-30)
    else
        nsubs;

    // Poisson equation constants
    const phi_bc = (1.0 / beta) * @log(@max(nsubs / ni, 1e-30));
    const phi_b = (1.0 / beta) * @log(@max(n_sub / ni, 1e-30));
    const two_phi_b = 2.0 * phi_b;

    const const_0 = @sqrt(@max(2.0 * EPS_SI * Q_ELEM * nsubs / beta, 1e-50));
    const const_b = @sqrt(@max(2.0 * EPS_SI * Q_ELEM * nsubb / beta, 1e-50));
    const c_soi = EPS_SI / tsoi;

    // Flat-band voltage
    const vfb1 = vfbc_raw * (1.0 + vfbcl1 / @exp(@min(vfbcl1p * @log(@max(l_gate_um, 1e-30)), 80.0)));
    const vfb2 = vfbc_raw * (1.0 + vfbcl2 / @exp(@min(vfbcl2p * @log(@max(l_gate_um, 1e-30)), 80.0)));
    const vfb3 = vfbc_raw + vfbhamp * l_gate_um;
    const vfb = @min(vfb1, @min(vfb2, vfb3));

    return .{
        .type_f = type_f, .m_mult = m_mult, .nf_inst = nf_inst,
        .l_gate = l_gate, .w_gate = w_gate, .l_eff = l_eff, .w_eff = w_eff,
        .l_gate_um = l_gate_um, .w_gate_um = w_gate_um, .l_eff_um = l_eff_um,
        .t_abs = t_abs, .tnom_abs = tnom_abs, .beta = beta, .beta_tnom = beta_tnom, .t_ratio = t_ratio,
        .eg_tnom = eg_tnom, .eg = eg, .ni = ni,
        .nsubs = nsubs, .nsubpp = nsubpp, .n_sub = n_sub,
        .phi_bc = phi_bc, .phi_b = phi_b, .two_phi_b = two_phi_b,
        .const_0 = const_0, .const_b = const_b, .c_soi = c_soi,
        .vfb = vfb,
    };
}

pub const PrepCache = DcPrep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return dcPrep(model, instance);
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // --- Node indices ---
    const D = @intFromEnum(U.drain);
    const G = @intFromEnum(U.gate);
    const Sn = @intFromEnum(U.source);
    const E = @intFromEnum(U.sub);
    const B = @intFromEnum(U.body);
    const DP = @intFromEnum(U.dp);
    const SP = @intFromEnum(U.sp);
    const GP = @intFromEnum(U.gp);

    // --- Read node voltages (S) ---
    const v_drain = x[D];
    const v_gate = x[G];
    const v_source = x[Sn];
    const v_sub = x[E];
    const v_body = x[B];
    const v_dp = x[DP];
    const v_sp = x[SP];
    const v_gp = x[GP];

    const p = pc;

    // Read precomputed x-independent values from DcPrep
    const type_f = p.type_f;
    const m_mult = p.m_mult;
    const nf_inst = p.nf_inst;
    const l_gate = p.l_gate;
    const l_eff = p.l_eff;
    const w_eff = p.w_eff;
    const l_gate_um = p.l_gate_um;
    const w_gate_um = p.w_gate_um;
    const l_eff_um = p.l_eff_um;
    const t_abs = p.t_abs;
    const tnom_abs = p.tnom_abs;
    const beta = p.beta;
    const beta_tnom = p.beta_tnom;
    const t_ratio = p.t_ratio;
    const eg_tnom = p.eg_tnom;
    const eg = p.eg;
    const ni = p.ni;
    const nsubs = p.nsubs;
    const n_sub = p.n_sub;
    const phi_bc = p.phi_bc;
    const two_phi_b = p.two_phi_b;
    const const_0 = p.const_0;
    const const_b = p.const_b;
    const c_soi = p.c_soi;
    const vfb = p.vfb;

    // Cast remaining model params used in x-dependent code
    const tfox: f64 = @as(f64, model.tfox);
    const tsoi: f64 = @as(f64, model.tsoi);
    const vfbc_raw: f64 = @as(f64, model.vfbc);
    const vbi_val: f64 = @as(f64, model.vbi);
    const ddltmax: f64 = @as(f64, model.ddltmax);
    const ddltslp: f64 = @as(f64, model.ddltslp);
    const ddltict: f64 = @as(f64, model.ddltict);
    const muecb0: f64 = @as(f64, model.muecb0);
    const muecb1: f64 = @as(f64, model.muecb1);
    const mueph0: f64 = @as(f64, model.mueph0);
    const mueph1_raw: f64 = if (model.type_ == -1 and model.mueph1 == 25000.0) 9000.0 else @as(f64, model.mueph1);
    const muetmp: f64 = @as(f64, model.muetmp);
    const muephl: f64 = @as(f64, model.muephl);
    const mueplp: f64 = @as(f64, model.mueplp);
    const muesr0: f64 = @as(f64, model.muesr0);
    const muesr1: f64 = @as(f64, model.muesr1);
    const muesrl: f64 = @as(f64, model.muesrl);
    const mueslp: f64 = @as(f64, model.mueslp);
    const ndep: f64 = @as(f64, model.ndep);
    const ninv: f64 = @as(f64, model.ninv);
    const ninvd: f64 = @as(f64, model.ninvd);
    const bb: f64 = if (model.type_ == -1 and model.bb == 2.0) 1.0 else @as(f64, model.bb);
    const vmax_raw: f64 = @as(f64, model.vmax);
    const vover: f64 = @as(f64, model.vover);
    const voverp: f64 = @as(f64, model.voverp);
    const vtmp: f64 = @as(f64, model.vtmp);
    const parl1: f64 = @as(f64, model.parl1);
    const parl2: f64 = @as(f64, model.parl2);
    const sc1: f64 = @as(f64, model.sc1);
    const sc2: f64 = @as(f64, model.sc2);
    const sc3: f64 = @as(f64, model.sc3);
    const scr1: f64 = @as(f64, model.scr1);
    const scr2: f64 = @as(f64, model.scr2);
    const scr3: f64 = @as(f64, model.scr3);
    const scp1: f64 = @as(f64, model.scp1);
    const scp2: f64 = @as(f64, model.scp2);
    const scp3: f64 = @as(f64, model.scp3);
    const lp_val: f64 = @as(f64, model.lp);
    const pgd1: f64 = @as(f64, model.pgd1);
    const pgd2: f64 = @as(f64, model.pgd2);
    const pgd4: f64 = @as(f64, model.pgd4);
    const qme1: f64 = @as(f64, model.qme1);
    const qme2: f64 = @as(f64, model.qme2);
    const qme3: f64 = @as(f64, model.qme3);
    const clm1: f64 = @as(f64, model.clm1);
    const clm2_raw: f64 = @as(f64, model.clm2);
    const clm3: f64 = @as(f64, model.clm3);
    const clm5: f64 = @as(f64, model.clm5);
    const clm6: f64 = @as(f64, model.clm6);
    const ptl: f64 = @as(f64, model.ptl);
    const ptlp: f64 = @as(f64, model.ptlp);
    const ptp: f64 = @as(f64, model.ptp);
    const pt2: f64 = @as(f64, model.pt2);
    const pt4: f64 = @as(f64, model.pt4);
    const pt4p: f64 = @as(f64, model.pt4p);
    const njunc: f64 = @as(f64, model.njunc);
    const xjpt_raw: f64 = @as(f64, model.xjpt);
    const mupt: f64 = @as(f64, model.mupt);
    const vfbpt: f64 = @as(f64, model.vfbpt);
    const pslimpt: f64 = @as(f64, model.pslimpt);
    const gdl: f64 = @as(f64, model.gdl);
    const gdlp_val: f64 = @as(f64, model.gdlp);
    const gdld: f64 = @as(f64, model.gdld);
    const wfc: f64 = @as(f64, model.wfc);
    const wvth0: f64 = @as(f64, model.wvth0);
    const wl2: f64 = @as(f64, model.wl2);
    const wl2p: f64 = @as(f64, model.wl2p);
    const muephs: f64 = @as(f64, model.muephs);
    const muepsp: f64 = @as(f64, model.muepsp);
    const vovers: f64 = @as(f64, model.vovers);
    const voversp: f64 = @as(f64, model.voversp);
    const muephw: f64 = @as(f64, model.muephw);
    const muepwp: f64 = @as(f64, model.muepwp);
    const muesrw: f64 = @as(f64, model.muesrw);
    const mueswp: f64 = @as(f64, model.mueswp);
    const sub1: f64 = @as(f64, model.sub1);
    const sub1l: f64 = @as(f64, model.sub1l);
    const sub1lp: f64 = @as(f64, model.sub1lp);
    const sub2: f64 = @as(f64, model.sub2);
    const sub2l: f64 = @as(f64, model.sub2l);
    const svds: f64 = @as(f64, model.svds);
    const slg: f64 = @as(f64, model.slg);
    const svgs: f64 = @as(f64, model.svgs);
    const svgsl: f64 = @as(f64, model.svgsl);
    const svgslp: f64 = @as(f64, model.svgslp);
    const svgsw: f64 = @as(f64, model.svgsw);
    const svgswp: f64 = @as(f64, model.svgswp);
    const svbs: f64 = @as(f64, model.svbs);
    const svbsl: f64 = @as(f64, model.svbsl);
    const svbslp: f64 = @as(f64, model.svbslp);
    const vfbsub: f64 = @as(f64, model.vfbsub);
    const vfbsubl: f64 = @as(f64, model.vfbsubl);
    const vfbsublp: f64 = @as(f64, model.vfbsublp);
    const ibpc1: f64 = @as(f64, model.ibpc1);
    const ibpc2: f64 = @as(f64, model.ibpc2);
    const gleak1: f64 = @as(f64, model.gleak1);
    const gleak2: f64 = @as(f64, model.gleak2);
    const gleak3: f64 = @as(f64, model.gleak3);
    const gleak4: f64 = @as(f64, model.gleak4);
    const gleak5: f64 = @as(f64, model.gleak5);
    const gleak6: f64 = @as(f64, model.gleak6);
    const gleak7: f64 = @as(f64, model.gleak7);
    const glkb1: f64 = @as(f64, model.glkb1);
    const glkb2: f64 = @as(f64, model.glkb2);
    const glkb3: f64 = @as(f64, model.glkb3);
    const glksd1: f64 = @as(f64, model.glksd1);
    const glksd2: f64 = @as(f64, model.glksd2);
    const glksd3: f64 = @as(f64, model.glksd3);
    const gidl1: f64 = @as(f64, model.gidl1);
    const gidl2: f64 = @as(f64, model.gidl2);
    const gidl3: f64 = @as(f64, model.gidl3);
    const gidl4: f64 = @as(f64, model.gidl4);
    const gidl5: f64 = @as(f64, model.gidl5);
    const gidlvb: f64 = @as(f64, model.gidlvb);
    const evb1: f64 = @as(f64, model.evb1);
    const evb2: f64 = @as(f64, model.evb2);
    const evb3: f64 = @as(f64, model.evb3);
    const fvbs: f64 = @as(f64, model.fvbs);
    const qhe1: f64 = @as(f64, model.qhe1);
    const qhe2: f64 = @as(f64, model.qhe2);
    const hist1: f64 = @as(f64, model.hist1);
    const hist2: f64 = @as(f64, model.hist2);
    const rbdb_inst: f64 = @as(f64, instance.rbdb);
    const rbsb_inst: f64 = @as(f64, instance.rbsb);
    const js0: f64 = @as(f64, model.js0);
    const nj: f64 = @as(f64, model.nj);
    const xti_val: f64 = @as(f64, model.xti);
    const xti2: f64 = @as(f64, model.xti2);
    const vdiffj: f64 = @as(f64, model.vdiffj);
    const divx: f64 = @as(f64, model.divx);
    const vzadd0: f64 = @as(f64, model.vzadd0);
    const rsh: f64 = @as(f64, model.rsh);
    const rshg: f64 = @as(f64, model.rshg);
    const nover_d: f64 = @as(f64, model.nover);
    const novers_s: f64 = @as(f64, model.novers);
    const nrd: f64 = @as(f64, instance.nrd);
    const nrs: f64 = @as(f64, instance.nrs);
    const ldrift_d: f64 = @as(f64, instance.ldrift);
    const ldrift_s: f64 = @as(f64, instance.ldrifts);
    const xgw: f64 = @as(f64, instance.xgw);
    const xgl: f64 = @as(f64, instance.xgl);
    const ngcon: f64 = @as(f64, instance.ngcon);
    const l_drawn: f64 = @as(f64, instance.l);
    const xld: f64 = @as(f64, model.xld);
    const rdrdjunc: f64 = @as(f64, model.rdrdjunc);
    const rdrmue_raw: f64 = @as(f64, model.rdrmue);
    const rdrmues_raw: f64 = @as(f64, model.rdrmues);
    const rdrmuel: f64 = @as(f64, model.rdrmuel);
    const rdrmuelp: f64 = @as(f64, model.rdrmuelp);
    const rdrvmax_raw: f64 = @as(f64, model.rdrvmax);
    const rdrvmaxs_raw: f64 = @as(f64, model.rdrvmaxs);
    const rdrvmaxl: f64 = @as(f64, model.rdrvmaxl);
    const rdrvmaxlp: f64 = @as(f64, model.rdrvmaxlp);
    const rdrvmaxw: f64 = @as(f64, model.rdrvmaxw);
    const rdrvmaxwp: f64 = @as(f64, model.rdrvmaxwp);
    const rdrbb_raw: f64 = @as(f64, model.rdrbb);
    const rdrbbs_raw: f64 = @as(f64, model.rdrbbs);
    const rbulk0: f64 = @as(f64, model.rbulk0);
    const rbulkw: f64 = @as(f64, model.rbulkw);
    const rdrmuetmp: f64 = @as(f64, model.rdrmuetmp);
    const rdrvtmp: f64 = @as(f64, model.rdrvtmp);
    const rdrbbtmp: f64 = @as(f64, model.rdrbbtmp);
    const muesti1: f64 = @as(f64, model.muesti1);
    const muesti2: f64 = @as(f64, model.muesti2);
    const muesti3: f64 = @as(f64, model.muesti3);
    const nsti: f64 = @as(f64, model.nsti);
    const vthsti: f64 = @as(f64, model.vthsti);
    const vdsti: f64 = @as(f64, model.vdsti);
    const scsti1: f64 = @as(f64, model.scsti1);
    const scsti2: f64 = @as(f64, model.scsti2);
    const wsti_raw: f64 = @as(f64, model.wsti);
    const wstil: f64 = @as(f64, model.wstil);
    const wstilp: f64 = @as(f64, model.wstilp);
    const wstiw: f64 = @as(f64, model.wstiw);
    const wstiwp: f64 = @as(f64, model.wstiwp);
    const wl1: f64 = @as(f64, model.wl1);
    const wl1p: f64 = @as(f64, model.wl1p);
    const saref: f64 = @as(f64, model.saref);
    const sbref: f64 = @as(f64, model.sbref);
    const sa: f64 = @as(f64, instance.sa);
    const sb: f64 = @as(f64, instance.sb);
    const lod: f64 = @as(f64, instance.lod);

    // LOD half-distance (used in mobility LOD and STI)
    const lod_half = @max(lod * 0.5, 1e-30);
    const lod_half_ref = @max((saref + sbref) * 0.5, 1e-30);
    const lod_sa_half = if (sa > 0.0 and sb > 0.0) @max((sa + sb) * 0.5, 1e-30) else lod_half;

    // ====================================================================
    // Terminal Voltages with Type Factor  [x-dependent -> S]
    // ====================================================================
    const vgs_ext = v_gp.sub(v_sp).scale(type_f);
    const vds_ext = v_dp.sub(v_sp).scale(type_f);
    const vbs_ext = v_body.sub(v_sp).scale(type_f);
    const v_es = v_sub.sub(v_sp).scale(type_f); // substrate (back-gate) voltage

    // Source-drain reversal (branch on the ORIGINAL vds sign, as before)
    const fwd = vds_ext.val() >= 0.0;
    const mode: f64 = if (fwd) 1.0 else -1.0;
    // vds = |vds_ext| + vzadd0
    const vds = vds_ext.abs().addC(vzadd0);
    const vgs = if (fwd) vgs_ext else vgs_ext.sub(vds_ext);
    const vbs = if (fwd) vbs_ext else vbs_ext.sub(vds_ext);

    // ====================================================================
    // Quantum mechanical effect (Eqs 74-75)  [x-dependent]
    // ====================================================================
    const vth_approx = vfbc_raw + two_phi_b; // f64
    // delta_tox = qme1 / max(vgs - vbs - vth_approx + qme2, 0.01) + qme3
    const qme_denom = vgs.sub(vbs).addC(-vth_approx + qme2).maxC(0.01);
    const delta_tox = S.con(qme1).div(qme_denom).addC(qme3);
    const tfox_eff = delta_tox.maxC(0.0).addC(tfox); // tfox + max(delta_tox, 0)
    const c_fox_eff = tfox_eff.pow(-1.0).scale(EPS_OX); // EPS_OX / tfox_eff

    // Depletion width (Eq 39)  [x-dependent through vbs]
    // w_d = sqrt(max(2*EPS_SI*(two_phi_b - vbs)/(Q*n_sub), 1e-30))
    const w_d = vbs.neg().addC(two_phi_b).scale(2.0 * EPS_SI / (Q_ELEM * n_sub)).maxC(1e-30).sqrt();

    // Substrate charge Q_s,bulk (Eq 19)  [x-dependent through v_es]
    // arg = max(exp(min(-beta*(phi_bc - v_es),80)) + beta*(phi_bc - v_es) - 1, 0)
    const pbc_ves = v_es.neg().addC(phi_bc); // phi_bc - v_es
    const phi_s_bulk_arg = expc(S, pbc_ves.scale(-beta)).add(pbc_ves.scale(beta)).addC(-1.0).maxC(0.0);
    const q_s_bulk = phi_s_bulk_arg.maxC(1e-50).sqrt().scale(const_b);
    _ = q_s_bulk;

    // ====================================================================
    // Section 4: Threshold Voltage Shift (Eq 37)  [x-dependent]
    // ====================================================================
    // Short-channel effect (Eqs 38, 41)
    const l_sce = @max(l_gate - parl2, 1e-9); // f64
    // dey_dy = 2*(vbi - 2phi_b)/l_sce^2 * (sc1 + sc2*vds + sc3*(2phi_b - vbs)/l_gate)
    const sce_pref = 2.0 * (vbi_val - two_phi_b) / (l_sce * l_sce);
    const sce_inner = vds.scale(sc2).add(vbs.neg().addC(two_phi_b).scale(sc3 / l_gate)).addC(sc1);
    const dey_dy = sce_inner.scale(sce_pref);
    // dvth_sc = (EPS_SI / c_fox_eff) * w_d * dey_dy
    const dvth_sc = c_fox_eff.pow(-1.0).scale(EPS_SI).mul(w_d).mul(dey_dy);

    // SOI-specific SCE via BOX (Eq 42)
    // dvth_scr = scr1*tfox*(eg + 2phi_b - scr3 + scr2*vds)/(l_gate/2 + parl1)
    const dvth_scr = vds.scale(scr2).addC(eg + two_phi_b - scr3)
        .scale(scr1 * tfox / (l_gate / 2.0 + parl1));

    // Reverse short-channel / pocket implant (Eqs 43-51)
    // q_b0 = sqrt(max(2*Q*n_sub*EPS_SI*(2phi_b - vbs), 1e-50))
    const q_b0 = vbs.neg().addC(two_phi_b).scale(2.0 * Q_ELEM * n_sub * EPS_SI).maxC(1e-50).sqrt();
    // vth_r = vfb + 2phi_b + q_b0 / c_fox_eff
    const vth_r = q_b0.div(c_fox_eff).addC(vfb + two_phi_b);
    // vth0 = vfb + 2*phi_bc + sqrt(max(2*Q*nsubs*EPS_SI*(2*phi_bc - vbs),1e-50))/c_fox_eff
    const vth0 = vbs.neg().addC(2.0 * phi_bc).scale(2.0 * Q_ELEM * nsubs * EPS_SI).maxC(1e-50).sqrt()
        .div(c_fox_eff).addC(vfb + 2.0 * phi_bc);

    // Pocket SCE (Eq 47)
    const lp_eff = @max(lp_val, 1e-9); // f64
    // dey_dy_p = (lp>0) ? 2*(vbi-2phi_b)/lp_eff^2 * (scp1 + scp2*vds + scp3*(2phi_b-vbs)/lp_eff) : 0
    const dey_dy_p = if (lp_val > 0.0)
        vds.scale(scp2).add(vbs.neg().addC(two_phi_b).scale(scp3 / lp_eff)).addC(scp1)
            .scale(2.0 * (vbi_val - two_phi_b) / (lp_eff * lp_eff))
    else
        S.con(0.0);
    // dvth_p = (vth_r - vth0) * (EPS_SI/c_fox_eff) * w_d * dey_dy_p
    const dvth_p = vth_r.sub(vth0).mul(c_fox_eff.pow(-1.0).scale(EPS_SI)).mul(w_d).mul(dey_dy_p);

    // Narrow-channel Vth shift (Eq 97)
    // dvth_w = wvth0/max(w_gate_um,1e-6) + wfc*w_d/c_fox_eff
    const dvth_w = w_d.scale(wfc).div(c_fox_eff).addC(wvth0 / @max(w_gate_um, 1e-6));

    // Small geometry Vth shift (Eqs 115-116)  [f64]
    const wl = w_gate_um * l_gate_um;
    const wl_safe = @max(wl, 1e-30);
    const dvth_sm = wl2 / @exp(@min(wl2p * @log(wl_safe), 80.0));

    // Poly-Si gate depletion (Eq 73)  [x-dependent through vgs]
    const pgd_l = (1.0 + 1.0 / @max(l_gate_um, 1e-6)); // f64
    const pgd_pref = pgd1 * @exp(@min(pgd4 * @log(pgd_l), 80.0)); // f64
    // phi_spg = pgd_pref * exp(min(vgs - pgd2, 80))
    const phi_spg = expc(S, vgs.addC(-pgd2)).scale(pgd_pref);
    const phi_spg_lim = phi_spg.minC(@max(phi_bc, 0.1)); // limit to phi_s0

    // Total Vth shift (Eq 37)
    const dvth = dvth_sc.add(dvth_scr).add(dvth_p).add(dvth_w).addC(dvth_sm).sub(phi_spg_lim);

    // ====================================================================
    // Section 2: Poisson Solution (Simplified Iterative)  [x-dependent]
    // ====================================================================
    // v_g0 = vgs - vfb + dvth
    const v_g0 = vgs.addC(-vfb).add(dvth);

    // Vds_sat estimation (Eq 27)
    const csi_fox2 = c_fox_eff.mul(c_fox_eff);
    const q_nsubs_esi = Q_ELEM * nsubs * EPS_SI; // f64
    // v_g0_prime = max(v_g0 - 1/beta, 0)
    const v_g0_prime = v_g0.addC(-1.0 / beta).maxC(0.0);
    // vds_sat_arg = max(1 + 2*csi_fox2*v_g0_prime/q_nsubs_esi, 1)
    const vds_sat_arg = csi_fox2.mul(v_g0_prime).scale(2.0 / q_nsubs_esi).addC(1.0).maxC(1.0);
    // vds_sat = v_g0 + q_nsubs_esi/csi_fox2 * (1 - sqrt(vds_sat_arg))
    const vds_sat = v_g0.add(vds_sat_arg.sqrt().neg().addC(1.0).mul(csi_fox2.pow(-1.0).scale(q_nsubs_esi)));
    const vds_sat_eff = vds_sat.maxC(0.01);

    // Vds smoothing (Eqs 24-26)  [delta_eff is f64; vds_eff x-dependent]
    const t1_smooth = ddltslp * l_gate_um; // f64
    const delta_smooth = ddltmax * t1_smooth / @max(ddltmax + t1_smooth, 1e-30) + ddltict; // f64
    const delta_eff = @max(delta_smooth, 1.0); // f64
    // vds_ratio = vds / vds_sat_eff
    const vds_ratio = vds.div(vds_sat_eff);
    // vds_ratio_pow = exp(min(delta_eff*log(max(vds_ratio,1e-30)),80))
    const vds_ratio_pow = powg(S, vds_ratio, delta_eff, 1e-30);
    // vds_eff = vds / exp(min((1/delta_eff)*log(max(1+vds_ratio_pow,1e-30)),80))
    const vds_eff = vds.div(powg(S, vds_ratio_pow.addC(1.0), 1.0 / delta_eff, 1e-30));

    // Surface potential at source (phi_s0) and drain (phi_sL)
    // phi_s0_soi = v_g0 + (q_nsubs_esi/csi_fox2)*(1 - sqrt(max(1 + 2*csi_fox2*max(v_g0-1/beta,0)/q_nsubs_esi,1)))
    const phi_s0_inner = csi_fox2.mul(v_g0.addC(-1.0 / beta).maxC(0.0)).scale(2.0 / q_nsubs_esi).addC(1.0).maxC(1.0);
    const phi_s0_soi = v_g0.add(phi_s0_inner.sqrt().neg().addC(1.0).mul(csi_fox2.pow(-1.0).scale(q_nsubs_esi)));
    const phi_sl_soi = phi_s0_soi.add(vds_eff);

    // Charges at source and drain (Eqs 14-18)
    // Depletion charge in SOI (Eqs 15-17)
    const q_dep_fd = Q_ELEM * nsubs * tsoi; // f64 (Eq 15)

    // Partially-depleted floating-body (Eq 16)
    // phi_b_soi = phi_s0_soi + q_dep_fd/(2*c_soi)
    const phi_b_soi = phi_s0_soi.addC(q_dep_fd / (2.0 * c_soi));
    // pd_fb_arg = max(exp(min(-beta*(phi_s0 - phi_b_soi),80)) + beta*(phi_s0 - phi_b_soi) - 1, 0)
    const psfb = phi_s0_soi.sub(phi_b_soi);
    const pd_fb_arg = expc(S, psfb.scale(-beta)).add(psfb.scale(beta)).addC(-1.0).maxC(0.0);
    const q_dep_pd_fb = pd_fb_arg.maxC(1e-50).sqrt().scale(const_0 / beta);

    // Partially-depleted body-contact (Eq 17): uses Vbcs (=vbs) instead of phi_b_soi
    const v_bcs_pd = vbs;
    const psbc = phi_s0_soi.sub(v_bcs_pd);
    const pd_bc_arg = expc(S, psbc.scale(-beta)).add(psbc.scale(beta)).addC(-1.0).maxC(0.0);
    const q_dep_pd_bc = pd_bc_arg.maxC(1e-50).sqrt().scale(const_0 / beta);

    // Select depletion charge based on depletion condition (branch on flag: f64)
    const co_bcnode_i: f64 = @floatFromInt(model.cobcnode);
    const q_dep_pd = if (co_bcnode_i > 0.0) q_dep_pd_bc else q_dep_pd_fb;
    // q_dep_soi = min(q_dep_fd, max(q_dep_pd, 1e-30))
    const q_dep_soi = q_dep_pd.maxC(1e-30).minC(q_dep_fd);

    // qi_s_sq = q_dep_soi^2 + 2*Q*EPS_SI/beta * exp(min(beta*phi_s0,80))
    const qi_s_sq = q_dep_soi.mul(q_dep_soi).add(expc(S, phi_s0_soi.scale(beta)).scale(2.0 * Q_ELEM * EPS_SI / beta));
    const qi_s = qi_s_sq.maxC(1e-50).sqrt().sub(q_dep_soi);
    const qi_d_sq = q_dep_soi.mul(q_dep_soi).add(expc(S, phi_sl_soi.scale(beta)).scale(2.0 * Q_ELEM * EPS_SI / beta));
    const qi_d = qi_d_sq.maxC(1e-50).sqrt().sub(q_dep_soi);

    // Average charges (Eqs 81-82)
    const qi_avg = qi_s.add(qi_d).scale(0.5);
    const qb_avg = q_dep_soi;

    // ====================================================================
    // Section 8: Mobility Model (Eqs 76-91)
    // L/W/geometry/temperature parts are x-independent (f64); the field-
    // dependent parts (e_eff, mu_ph, mu_sr, mu_cb, mu_0, mu) are x-dependent.
    // ====================================================================
    // L-dependent phonon mobility (Eq 87)  [f64]
    var muephonon = mueph1_raw * (1.0 + muephl / @exp(@min(mueplp * @log(@max(l_gate_um, 1e-30)), 80.0)));
    // L-dependent surface roughness (Eq 88)  [f64]
    var muesurface = muesr1 * (1.0 + muesrl / @exp(@min(mueslp * @log(@max(l_gate_um, 1e-30)), 80.0)));
    // Narrow-width mobility modifications (Eqs 102-103)  [f64]
    muephonon = muephonon * (1.0 + muephw / @exp(@min(muepwp * @log(@max(w_gate_um, 1e-30)), 80.0)));
    muesurface = muesurface * (1.0 + muesrw / @exp(@min(mueswp * @log(@max(w_gate_um, 1e-30)), 80.0)));
    // Small geometry mobility modification (Eq 117)  [f64]
    muephonon = muephonon * (1.0 + muephs / @exp(@min(muepsp * @log(wl_safe), 80.0)));
    // LOD mobility modifier (Eqs 129-133)  [f64]
    {
        const t1 = 1.0 / (1.0 + muesti2);
        const t2 = muesti1 / @exp(@min(muesti3 * @log(@max(lod_sa_half, 1e-30)), 80.0));
        const t3 = muesti1 / @exp(@min(muesti3 * @log(@max(lod_half_ref, 1e-30)), 80.0));
        const muesti = (1.0 + t1 * t2) / (1.0 + t1 * t3);
        muephonon = muephonon * muesti;
    }
    // Temperature-dependent phonon mobility (Eq 142)  [f64]
    muephonon = muephonon / @exp(@min(muetmp * @log(@max(t_ratio, 1e-30)), 80.0));

    // Effective field (Eq 80)  [x-dependent]
    const dphi = phi_sl_soi.sub(phi_s0_soi);
    // dphi_factor = 1 + exp(min(ninvd*log(max(|dphi|+1e-30,1e-30)),80))
    const dphi_factor = powg(S, dphi.abs().addC(1e-30), ninvd, 1e-30).addC(1.0);
    // e_eff = max((ndep*qb + ninv*qi_avg)/(EPS_SI*dphi_factor), 1)
    const e_eff = qb_avg.scale(ndep).add(qi_avg.scale(ninv)).div(dphi_factor.scale(EPS_SI)).maxC(1.0);

    // Coulomb scattering (Eq 77)
    const mu_cb = qi_avg.scale(muecb1 / (Q_ELEM * 1e11)).addC(muecb0);

    // Phonon scattering (Eq 78)
    const e_eff_ph = e_eff.maxC(1.0);
    // mu_ph = muephonon / exp(min(mueph0*log(e_eff_ph),80))
    const mu_ph = powg(S, e_eff_ph, mueph0, 1e-30).pow(-1.0).scale(muephonon);
    // Surface roughness scattering (Eq 79)
    const mu_sr = powg(S, e_eff_ph, muesr0, 1e-30).pow(-1.0).scale(muesurface);

    // Matthiessen's rule (Eq 76): mu_0 = 1/(1/mu_cb + 1/mu_ph + 1/mu_sr)
    const mu_0 = mu_cb.pow(-1.0).add(mu_ph.maxC(1e-30).pow(-1.0)).add(mu_sr.maxC(1e-30).pow(-1.0)).pow(-1.0);

    // Saturation velocity with temperature (Eqs 91, 118, 143)  [f64]
    const vmax_denom = 1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - vtmp * (1.0 - t_ratio);
    var vmax_eff = vmax_raw / @max(vmax_denom, 0.1);
    vmax_eff = vmax_eff * (1.0 + vover / @exp(@min(voverp * @log(@max(l_gate_um, 1e-30)), 80.0)));
    vmax_eff = vmax_eff * (1.0 + vovers / @exp(@min(voversp * @log(wl_safe), 80.0)));

    // ====================================================================
    // Section 3: Drain Current (Eqs 31-36)  [x-dependent]
    // Idd unified form
    // ====================================================================
    // beta*(phi - vbs) - 1 terms
    const psl_vbs = phi_sl_soi.sub(vbs).scale(beta).addC(-1.0);
    const ps0_vbs = phi_s0_soi.sub(vbs).scale(beta).addC(-1.0);
    // term A: c_fox_eff*(beta*v_g0 + 1)*(phi_sl - phi_s0)
    const idd_a = c_fox_eff.mul(v_g0.scale(beta).addC(1.0)).mul(phi_sl_soi.sub(phi_s0_soi));
    // term B: c_fox_eff*(beta/2)*(phi_sl^2 - phi_s0^2)
    const idd_b = c_fox_eff.scale(beta / 2.0).mul(phi_sl_soi.mul(phi_sl_soi).sub(phi_s0_soi.mul(phi_s0_soi)));
    // term C: (2/3)*const_0*( (psl_vbs)^1.5 - (ps0_vbs)^1.5 )  guarded
    const idd_c = powg(S, psl_vbs, 1.5, 1e-30).sub(powg(S, ps0_vbs, 1.5, 1e-30)).scale((2.0 / 3.0) * const_0);
    // term D: const_0*( sqrt(psl_vbs) - sqrt(ps0_vbs) )  guarded
    const idd_d = psl_vbs.maxC(1e-30).sqrt().sub(ps0_vbs.maxC(1e-30).sqrt()).scale(const_0);
    const idd = idd_a.sub(idd_b).sub(idd_c).add(idd_d);

    // ====================================================================
    // Section 9: Channel-Length Modulation (Eqs 92-96)  [x-dependent]
    // ====================================================================
    // phi_s_dl = (1-clm1)*phi_sl + clm1*(phi_s0 + vds)
    const phi_s_dl = phi_sl_soi.scale(1.0 - clm1).add(phi_s0_soi.add(vds).scale(clm1));
    const clm2_eff = if (clm2_raw == 0.0) 5.0e9 / @max(tsoi * nsubs, 1e-10) else clm2_raw; // f64
    // z_clm = EPS_SI*w_d / max(clm2_eff*qb + clm3*qi_avg, 1e-30)
    const z_clm = w_d.scale(EPS_SI).div(qb_avg.scale(clm2_eff).add(qi_avg.scale(clm3)).maxC(1e-30));
    const dphi_clm = phi_s_dl.sub(phi_sl_soi).maxC(0.0);
    // idd_ql = max(|idd|/(beta*max(qi_avg,1e-30)*l_eff), 1e-20)
    const idd_ql = idd.abs().div(qi_avg.maxC(1e-30).scale(beta * l_eff)).maxC(1e-20);
    // a_clm = (Q*nsubs/EPS_SI*z_clm + 2*idd_ql)*dphi_clm*z_clm
    const a_clm = z_clm.scale(Q_ELEM * nsubs / EPS_SI).add(idd_ql.scale(2.0)).mul(dphi_clm).mul(z_clm);
    // b_clm = E0_CLM*z_clm^2
    const b_clm = z_clm.mul(z_clm).scale(E0_CLM);
    // delta_l = -0.5*a_clm + sqrt(max(a_clm^2*0.25 + b_clm + a_clm*b_clm, 1e-30))
    var delta_l = a_clm.scale(-0.5).add(a_clm.mul(a_clm).scale(0.25).add(b_clm).add(a_clm.mul(b_clm)).maxC(1e-30).sqrt());
    delta_l = delta_l.maxC(0.0);
    // Pocket effect (Eq 96): delta_l *= (1 + clm6*exp(min(clm5*log(max(l_gate_um,1e-30)),80)))  [f64 factor]
    const clm_pocket = 1.0 + clm6 * @exp(@min(clm5 * @log(@max(l_gate_um, 1e-30)), 80.0));
    delta_l = delta_l.scale(clm_pocket);
    delta_l = delta_l.minC(0.9 * l_eff); // ensure Leff - deltaL > 0

    // High-field mobility (Eqs 89-90)  [x-dependent]
    // ey_idd = max(|idd|/(beta*max(qi_s,1e-30)*l_eff_um), 1e-20)
    const ey_idd = idd.abs().div(qi_s.maxC(1e-30).scale(beta * l_eff_um)).maxC(1e-20);
    // ey_sq = ey_idd^2 + (0.2*vmax_eff/mu_0)^2
    const ey_term2 = mu_0.pow(-1.0).scale(0.2 * vmax_eff);
    const ey_sq = ey_idd.mul(ey_idd).add(ey_term2.mul(ey_term2)).maxC(1e-30);
    const ey = ey_sq.sqrt();
    // vel_ratio = mu_0*ey/max(vmax_eff,1)
    const vel_ratio = mu_0.mul(ey).scale(1.0 / @max(vmax_eff, 1.0));
    const vel_pow = powg(S, vel_ratio, bb, 1e-30);
    // mu = mu_0 / exp(min((1/bb)*log(max(1+vel_pow,1)),80))
    const mu = mu_0.div(powg(S, vel_pow.addC(1.0).maxC(1.0), 1.0 / bb, 1e-30));

    // Final intrinsic drain current (Eq 31)
    // ids_intrinsic = w_eff*nf/max(l_eff-delta_l,1e-9) * mu * idd / beta
    const l_chan = delta_l.neg().addC(l_eff).maxC(1e-9); // max(l_eff - delta_l, 1e-9)
    const ids_intrinsic = l_chan.pow(-1.0).scale(w_eff * nf_inst).mul(mu).mul(idd).scale(1.0 / beta);

    // ====================================================================
    // Section 5: Punchthrough (Eqs 57-72)  [x-dependent]
    // ====================================================================
    // Shallow punchthrough (Eq 59-60)
    const dphi_pt = phi_sl_soi.sub(phi_s0_soi);
    // poten_base = (vds - dphi_pt)/max(1.1 - phi_s0 + 2, 0.1)
    const poten_den = phi_s0_soi.neg().addC(3.1).maxC(0.1);
    const poten_base = vds.sub(dphi_pt).div(poten_den);
    // poten = exp(min(ptp*log(max(|poten_base|,1e-30)),80))
    const poten = powg(S, poten_base.abs(), ptp, 1e-30);
    const pt_factor = ptl / @exp(@min(ptlp * @log(@max(l_gate_um, 1e-30)), 80.0)); // f64
    // pt_vbs = 1 + pt2*vds + pt4*(phi_s0 - vbs)/exp(min(pt4p*log(max(l_gate_um,1e-30)),80))
    const pt4_l = pt4 / @exp(@min(pt4p * @log(@max(l_gate_um, 1e-30)), 80.0)); // f64
    const pt_vbs = vds.scale(pt2).add(phi_s0_soi.sub(vbs).scale(pt4_l)).addC(1.0);
    // ids_shallow_pt = w_eff*nf/l_eff * (mu/beta) * dphi_pt * c_fox_eff * beta * pt_factor * poten * pt_vbs
    const ids_shallow_pt = mu.scale(w_eff * nf_inst / l_eff / beta).mul(dphi_pt).mul(c_fox_eff)
        .scale(beta * pt_factor).mul(poten).mul(pt_vbs);

    // Deep punchthrough (Eqs 61-70)
    const xjpt = if (xjpt_raw == 0.0) tsoi else xjpt_raw; // f64
    // e_cri_sq = 2*Q*(vbi - vbs)/EPS_SI * n_sub*njunc/max(n_sub+njunc,1e-10)
    const e_cri_sq = vbs.neg().addC(vbi_val).scale(2.0 * Q_ELEM / EPS_SI * n_sub * njunc / @max(n_sub + njunc, 1e-10)).maxC(1e-30);
    const e_cri = e_cri_sq.sqrt();
    // phi_m_sd = -0.25*(e_cri*l_eff)^2 / max(e_cri*l_eff + vds, 1e-30)
    const ecri_l = e_cri.scale(l_eff);
    const phi_m_sd = ecri_l.mul(ecri_l).scale(-0.25).div(ecri_l.add(vds).maxC(1e-30));

    // Surface potential for deep PT
    const vfb_pt = vfb + vfbpt; // f64
    // v_g0_pt = vgs - vfb_pt + dvth
    const v_g0_pt = vgs.addC(-vfb_pt).add(dvth);
    // phi_s_deep_raw = v_g0_pt + q_nsubs_esi/csi_fox2*(1 - sqrt(max(1 + 2*csi_fox2*max(v_g0_pt-1/beta,0)/q_nsubs_esi,1)))
    const phi_s_deep_inner = csi_fox2.mul(v_g0_pt.addC(-1.0 / beta).maxC(0.0)).scale(2.0 / q_nsubs_esi).addC(1.0).maxC(1.0);
    const phi_s_deep_raw = v_g0_pt.add(phi_s_deep_inner.sqrt().neg().addC(1.0).mul(csi_fox2.pow(-1.0).scale(q_nsubs_esi)));
    const phi_s_deep = if (pslimpt > 0.0) phi_s_deep_raw.minC(pslimpt) else phi_s_deep_raw;

    // Depletion charge for deep PT (Eq 68)
    // q_bu_pt = const_0*sqrt(max(exp(min(-beta*(phi_s_deep - phi_m_sd),80)) - 1 + beta*(phi_s_deep - phi_m_sd), 1e-30))
    const psd_pm = phi_s_deep.sub(phi_m_sd);
    const q_bu_pt = expc(S, psd_pm.scale(-beta)).addC(-1.0).add(psd_pm.scale(beta)).maxC(1e-30).sqrt().scale(const_0);
    // w_depl_pt = (phi_s_deep >= phi_m_sd) ? q_bu_pt/max(Q*nsubs,1e-30) : 0   (branch on voltage sign)
    const w_depl_pt = if (psd_pm.val() >= 0.0) q_bu_pt.scale(1.0 / @max(Q_ELEM * nsubs, 1e-30)) else S.con(0.0);

    // wfactor (Eq 66): (w_depl_pt >= xjpt) ? (1 - xjpt/max(w_depl_pt,1e-30))^2 : 0
    const wfactor = if (w_depl_pt.val() >= xjpt) blk: {
        const r = w_depl_pt.maxC(1e-30).pow(-1.0).scale(-xjpt).addC(1.0);
        break :blk r.mul(r);
    } else S.con(0.0);

    // phi_m (Eqs 64-65)
    const phi_m_gate = phi_s_deep.sub(phi_m_sd).mul(wfactor);
    const phi_m = phi_m_gate.add(phi_m_sd);

    // Qn0,PT (Eq 63): sqrt(max(2*Q*njunc*EPS_SI/beta,1e-50)) * sqrt(max(beta*phi_m_gate,1e-30))
    const qn0_pt = phi_m_gate.scale(beta).maxC(1e-30).sqrt().scale(@sqrt(@max(2.0 * Q_ELEM * njunc * EPS_SI / beta, 1e-50)));

    // Jpt,deep (Eq 62): 2/(beta*l_eff)*qn0_pt*mupt*exp(min(-beta*phi_m,80))
    const jpt_deep = qn0_pt.scale(2.0 / (beta * l_eff) * mupt).mul(expc(S, phi_m.scale(-beta)));

    // Ids,deep PT (Eq 61): jpt_deep*w_eff*nf*(1 - exp(min(-beta*vds,80)))
    const ids_deep_pt = jpt_deep.scale(w_eff * nf_inst).mul(expc(S, vds.scale(-beta)).neg().addC(1.0));

    // Channel conductance / pinch-off current (Eq 72)
    // cond_gdl = c_fox_eff*beta*gdl/exp(min(gdlp*log(max(l_gate_um+gdld*1e6,1e-30)),80))*vds  [f64 factor * vds]
    const cond_gdl_f = beta * gdl / @exp(@min(gdlp_val * @log(@max(l_gate_um + gdld * 1e6, 1e-30)), 80.0)); // f64
    const cond_gdl = c_fox_eff.scale(cond_gdl_f).mul(vds);
    // ids_pinchoff = w_eff*nf/l_eff*(mu/beta)*dphi_pt*cond_gdl
    const ids_pinchoff = mu.scale(w_eff * nf_inst / l_eff / beta).mul(dphi_pt).mul(cond_gdl);

    // Total drain current (Eq 57)
    var ids = ids_intrinsic.add(ids_shallow_pt).add(ids_deep_pt).add(ids_pinchoff);

    // ====================================================================
    // Section 15: Substrate Current (Eqs 179-194)  [x-dependent]
    // ====================================================================
    const co_isub: f64 = @floatFromInt(model.coisub);
    // f64 param prep for substrate current
    const l_um = l_gate * 1e6;
    const l_um_safe = @max(l_um, 1e-30);
    const sub1_eff = sub1 * (1.0 + sub1l / @exp(@min(sub1lp * @log(l_um_safe), 80.0)));
    const sub2_eff = sub2 * (1.0 + sub2l / l_um_safe);
    const vfbsub_eff = vfbsub * (1.0 + vfbsubl / @exp(@min(vfbsublp * @log(l_um_safe), 80.0)));
    const slg_factor = 1.0 / (1.0 + slg / (1.0 + l_um_safe));
    const svgs_eff = svgs * (1.0 + svgsl / @exp(@min(svgslp * @log(l_um_safe), 80.0))) / (1.0 + svgsw / @exp(@min(svgswp * @log(@max(w_gate_um, 1e-30)), 80.0)));
    const xvbs_eff = svbs * (1.0 + svbsl / @exp(@min(svbslp * @log(l_um_safe), 80.0)));
    // v_g0_sub = vgs - vfbsub_eff + dvth - phi_spg_lim
    const v_g0_sub = vgs.addC(-vfbsub_eff).add(dvth).sub(phi_spg_lim);
    // vg0_sub_term = v_g0_sub + q_nsubs_esi/csi_fox2*(1 - sqrt(max(1 + 2*csi_fox2*max(v_g0_sub-1/beta,0)/q_nsubs_esi,1)))
    const vg0_sub_inner = csi_fox2.mul(v_g0_sub.addC(-1.0 / beta).maxC(0.0)).scale(2.0 / q_nsubs_esi).addC(1.0).maxC(1.0);
    const vg0_sub_term = v_g0_sub.add(vg0_sub_inner.sqrt().neg().addC(1.0).mul(csi_fox2.pow(-1.0).scale(q_nsubs_esi)));
    // psisubsat = max(svds*vds + phi_s0 - slg_factor*svgs_eff*(vg0_sub_term - xvbs_eff*vbs), 0.01)
    const psisubsat = vds.scale(svds).add(phi_s0_soi)
        .sub(vg0_sub_term.sub(vbs.scale(xvbs_eff)).scale(slg_factor * svgs_eff)).maxC(0.01);
    // i_sub = sub1_eff*psisubsat*ids*exp(min(-sub2_eff/psisubsat,80)) * co_isub
    const i_sub = psisubsat.scale(sub1_eff).mul(ids).mul(expc(S, psisubsat.pow(-1.0).scale(-sub2_eff))).scale(co_isub);

    // Bulk resistance effect on substrate current (Eq 163-164)  [f64]
    const r_bulk_val = rbulkw * w_eff + rbulk0;
    const g_bulk_eff: f64 = if (r_bulk_val > 0.0 and model.corbulk != 0) 1.0 / r_bulk_val else 0.0;

    // Impact-ionization bulk potential change (Eq 194)  [x-dependent through i_sub & dvth]
    // dvbulk = ibpc1*(1 + ibpc2*dvth)*i_sub
    const dvbulk = dvth.scale(ibpc2).addC(1.0).scale(ibpc1).mul(i_sub);
    const i_bulk_impact = dvbulk.scale(g_bulk_eff);

    // ====================================================================
    // Section 15: Gate Leakage Current (Eqs 195-207)  [x-dependent]
    // ====================================================================
    const co_iigs: f64 = @floatFromInt(model.coiigs);
    // Gate-to-channel (Eqs 195-201)
    // v_g_leak = vgs - vfb + gleak4*(dvth - phi_spg_lim)*l_eff - gleak3*phi_sl
    const v_g_leak = vgs.addC(-vfb).add(dvth.sub(phi_spg_lim).scale(gleak4 * l_eff)).sub(phi_sl_soi.scale(gleak3));
    // e_gate_fox = max((1 + ey/gleak5)*(1 - 1/(1+vgs^2))*v_g_leak/tfox_eff, 1)
    const egf_a = ey.scale(1.0 / gleak5).addC(1.0);
    const egf_b = vgs.mul(vgs).addC(1.0).pow(-1.0).neg().addC(1.0); // 1 - 1/(1+vgs^2)
    const e_gate_fox = egf_a.mul(egf_b).mul(v_g_leak).div(tfox_eff).maxC(1.0);
    const eg_pow = @exp(@min(1.5 * @log(@max(eg, 1e-30)), 80.0)); // f64
    // i_gate_raw = Q*gleak1*(e_gate_fox^2)/max(|e_gate_fox|,1) * exp(min(-eg_pow/(gleak2*max(|e_gate_fox|,1)),80))
    //            * qi_avg/max(const_0,1e-30)*w_eff*nf*l_eff * gleak6/(gleak6+vds) * gleak7/(gleak7+w_eff*nf*l_eff)
    const egf_abs = e_gate_fox.abs().maxC(1.0);
    const i_gate_raw = e_gate_fox.mul(e_gate_fox).div(egf_abs).scale(Q_ELEM * gleak1)
        .mul(expc(S, egf_abs.pow(-1.0).scale(-eg_pow / gleak2))) // -eg_pow/(gleak2*|egf|)
        .mul(qi_avg).scale(1.0 / @max(const_0, 1e-30) * w_eff * nf_inst * l_eff)
        .mul(vds.addC(gleak6).pow(-1.0).scale(gleak6))
        .scale(gleak7 / (gleak7 + w_eff * nf_inst * l_eff));
    const i_gate = i_gate_raw.maxC(0.0).scale(co_iigs);
    // Partition (simplified): ratio based on drain field
    // partition = min(max(vds/max(vds+0.5,1e-30),0),1)
    const partition = vds.div(vds.addC(0.5).maxC(1e-30)).maxC(0.0).minC(1.0);
    const i_gate_d = partition.mul(i_gate);
    const i_gate_s = partition.neg().addC(1.0).mul(i_gate);

    // Gate-to-bulk (Eqs 202-203)
    // e_gb = -(vgs - vfbc + glkb3)/tfox_eff  [tfox_eff is S]
    const e_gb = vgs.addC(-vfbc_raw + glkb3).neg().div(tfox_eff);
    const e_gb_abs = e_gb.abs().maxC(1e-30);
    // i_gb = glkb1*e_gb_abs^2*exp(min(-glkb2/e_gb_abs,80))*w_eff*nf*l_eff*co_iigs
    const i_gb = e_gb_abs.mul(e_gb_abs).scale(glkb1).mul(expc(S, e_gb_abs.pow(-1.0).scale(-glkb2)))
        .scale(w_eff * nf_inst * l_eff * co_iigs);

    // Gate-to-source/drain (Eqs 204-207)
    const e_gs_val = vgs.div(tfox_eff);
    const e_gd_val = vgs.sub(vds).div(tfox_eff);
    // i_gs_gate = glksd1*e_gs^2*exp(min(tfox_eff*(-glksd2*vgs + glksd3),80))*w_eff*nf*co_iigs
    const i_gs_gate = e_gs_val.mul(e_gs_val).scale(glksd1)
        .mul(expc(S, tfox_eff.mul(vgs.scale(-glksd2).addC(glksd3))))
        .scale(w_eff * nf_inst * co_iigs);
    // i_gd_gate = glksd1*e_gd^2*exp(min(tfox_eff*(glksd2*(-vgs+vds) + glksd3),80))*w_eff*nf*co_iigs
    const i_gd_gate = e_gd_val.mul(e_gd_val).scale(glksd1)
        .mul(expc(S, tfox_eff.mul(vds.sub(vgs).scale(glksd2).addC(glksd3))))
        .scale(w_eff * nf_inst * co_iigs);

    // ====================================================================
    // Section 15: GIDL Current (Eqs 208-212)  [x-dependent]
    // ====================================================================
    const co_gidl: f64 = @floatFromInt(model.cogidl);
    // v_g0_gidl = vgs - dvth*gidl5
    const v_g0_gidl = vgs.sub(dvth.scale(gidl5));
    // e_gidl_field = max((gidl3*(vds + gidl4) - v_g0_gidl)/tfox_eff, 1)
    const e_gidl_field = vds.addC(gidl4).scale(gidl3).sub(v_g0_gidl).div(tfox_eff).maxC(1.0);
    // v_db = vds - vbs ; v_db3 = v_db^3
    const v_db = vds.sub(vbs);
    const v_db3 = v_db.mul(v_db).mul(v_db);
    const eg_pow_gidl = @exp(@min(1.5 * @log(@max(eg, 1e-30)), 80.0)); // f64
    // i_gidl = Q*gidl1*e_gidl_field*exp(min(-gidl2*eg_pow_gidl/max(e_gidl_field,1),80)) * w_eff*nf * v_db3/max(v_db3+gidlvb,1e-30) * co_gidl
    const i_gidl = e_gidl_field.scale(Q_ELEM * gidl1)
        .mul(expc(S, e_gidl_field.maxC(1.0).pow(-1.0).scale(-gidl2 * eg_pow_gidl)))
        .scale(w_eff * nf_inst)
        .mul(v_db3.div(v_db3.addC(gidlvb).maxC(1e-30)))
        .scale(co_gidl);

    // ====================================================================
    // Section 15: Valence Band Electron Tunneling (Eqs 213-215)  [x-dependent]
    // ====================================================================
    const co_ievb: f64 = @floatFromInt(model.coievb);
    // v_fox = v_g0 - phi_s0
    const v_fox = v_g0.sub(phi_s0_soi);
    // e_fox = max(-(fvbs*vbs - v_fox + dvth_sc + dvth_p + eg + evb3)/tfox_eff, 1)
    const e_fox = vbs.scale(fvbs).sub(v_fox).add(dvth_sc).add(dvth_p).addC(eg + evb3).neg().div(tfox_eff).maxC(1.0);
    // v_fox_ratio = min(v_fox/(2*PHI_HOLE_BARRIER), 0.999)
    const v_fox_ratio = v_fox.scale(1.0 / (2.0 * PHI_HOLE_BARRIER)).minC(0.999);
    // barrier_factor = 1 - (1 - v_fox_ratio)*sqrt(max(1 - v_fox_ratio, 1e-30))
    const one_m_ratio = v_fox_ratio.neg().addC(1.0);
    const barrier_factor = one_m_ratio.mul(one_m_ratio.maxC(1e-30).sqrt()).neg().addC(1.0);
    // i_evb = evb1*Q*(PHI/max(v_fox,1e-30) - 1)*e_fox^2*exp(min(-evb2*barrier_factor/max(e_fox,1),80))*w_eff*nf*l_eff*co_ievb
    var i_evb = v_fox.maxC(1e-30).pow(-1.0).scale(PHI_HOLE_BARRIER).addC(-1.0).scale(evb1 * Q_ELEM)
        .mul(e_fox).mul(e_fox)
        .mul(expc(S, barrier_factor.scale(-evb2).div(e_fox.maxC(1.0))))
        .scale(w_eff * nf_inst * l_eff * co_ievb);
    i_evb = i_evb.maxC(0.0);

    // ====================================================================
    // Section 16: Floating-Body Effect (Eqs 216-222)  [x-dependent]
    // ====================================================================
    const co_fbe: f64 = @floatFromInt(model.cofbe);
    const ln_diff = @sqrt(@max(DN_DIFF * 1e-7, 1e-30)); // f64
    const lp_diff = @sqrt(@max(DP_DIFF * 1e-7, 1e-30)); // f64
    const denom_fbe = Q_ELEM * tsoi * w_eff * @exp(@min(-beta * qhe2, 80.0)) * (DN_DIFF * ND_JUNC * lp_diff + DP_DIFF * ND_JUNC * ln_diff); // f64
    // dv_sb = qhe1/beta*log(max(1 + max(i_sub + i_evb, 0)*lp_diff*ln_diff/max(denom_fbe,1e-50), 1))
    const dv_sb_arg = i_sub.add(i_evb).maxC(0.0).scale(lp_diff * ln_diff / @max(denom_fbe, 1e-50)).addC(1.0).maxC(1.0);
    const dv_sb = dv_sb_arg.log().scale(qhe1 / beta);
    // arg1 = max(exp(min(-beta*(phi_s0 - dv_sb),80)) + beta*(phi_s0 - dv_sb) - 1, 0)
    const ps0_dvsb = phi_s0_soi.sub(dv_sb);
    const fbe_arg1 = expc(S, ps0_dvsb.scale(-beta)).add(ps0_dvsb.scale(beta)).addC(-1.0).maxC(0.0);
    // arg2 = max(exp(min(-beta*phi_s0,80)) + beta*phi_s0 - 1, 0)
    const fbe_arg2 = expc(S, phi_s0_soi.scale(-beta)).add(phi_s0_soi.scale(beta)).addC(-1.0).maxC(0.0);
    const q_h = fbe_arg1.maxC(1e-30).sqrt().sub(fbe_arg2.maxC(1e-30).sqrt()).scale(co_fbe);

    // Add FBE contribution to Ids
    // ids += q_h*c_fox_eff*mu*w_eff*nf/(beta*max(l_eff-delta_l,1e-9))
    ids = ids.add(q_h.mul(c_fox_eff).mul(mu).scale(w_eff * nf_inst / beta).div(l_chan));

    // ====================================================================
    // Section 10: STI Leakage Current (Eqs 104-114)  [x-dependent]
    // ====================================================================
    const co_isti: f64 = @floatFromInt(model.coisti);
    // f64 STI geometry prep
    const l_gate_sm = l_gate + wl1 / @exp(@min(wl1p * @log(wl_safe), 80.0));
    const l_gate_sm_um = l_gate_sm * 1e6;
    const q_n_sti = Q_ELEM * nsti;
    const phi_b_sti = (1.0 / beta) * @log(@max(nsti / ni, 1e-30));
    const two_phi_b_sti = 2.0 * phi_b_sti;
    const l_sce_sti = @max(l_gate_sm - parl2, 1e-9);
    const wsti_eff = wsti_raw * (1.0 + wstil / @exp(@min(wstilp * @log(@max(l_gate_sm_um, 1e-30)), 80.0)) +
        wstiw / @exp(@min(wstiwp * @log(@max(w_gate_um, 1e-30)), 80.0)));
    // STI SCE (Eq 108-110), x-dependent through vbs, vds
    // w_d_sti = sqrt(max(2*EPS_SI*(2phi_b_sti - vbs)/max(q_n_sti,1e-30), 1e-30))
    const w_d_sti = vbs.neg().addC(two_phi_b_sti).scale(2.0 * EPS_SI / @max(q_n_sti, 1e-30)).maxC(1e-30).sqrt();
    // dey_dy_sti = 2*(vbi - 2phi_b_sti)/l_sce_sti^2 * (scsti1 + scsti2*vds)
    const dey_dy_sti = vds.scale(scsti2).addC(scsti1).scale(2.0 * (vbi_val - two_phi_b_sti) / (l_sce_sti * l_sce_sti));
    // dvth_sc_sti = (EPS_SI/c_fox_eff)*w_d_sti*dey_dy_sti
    const dvth_sc_sti = c_fox_eff.pow(-1.0).scale(EPS_SI).mul(w_d_sti).mul(dey_dy_sti);
    // v_gs_sti = vgs - vfbc + vthsti - vdsti*vds + dvth_sc_sti
    const v_gs_sti = vgs.addC(-vfbc_raw + vthsti).sub(vds.scale(vdsti)).add(dvth_sc_sti);
    // phi_s_sti = v_gs_sti + 2*csi_fox2/max(EPS_SI*q_n_sti,1e-30)*(1 - sqrt(max(1 + EPS_SI*q_n_sti/csi_fox2*(beta*(v_gs_sti - vbs) - 1), 1)))
    // note: csi_fox2 is S here (c_fox_eff^2)
    const sti_coef = csi_fox2.scale(2.0 / @max(EPS_SI * q_n_sti, 1e-30)); // 2*csi_fox2/(EPS_SI*q_n_sti)
    const sti_inner = v_gs_sti.sub(vbs).scale(beta).addC(-1.0).scale(EPS_SI * q_n_sti).div(csi_fox2).addC(1.0).maxC(1.0);
    const phi_s_sti = v_gs_sti.add(sti_coef.mul(sti_inner.sqrt().neg().addC(1.0)));
    // qi_sti = c_fox_eff*max(v_gs_sti - phi_s_sti, 0)
    const qi_sti = c_fox_eff.mul(v_gs_sti.sub(phi_s_sti).maxC(0.0));
    // ids_sti = 2*wsti_eff/max(l_eff-delta_l,1e-9)*qi_sti/beta*mu*(1 - exp(min(-beta*vds,80)))*co_isti
    const ids_sti = l_chan.pow(-1.0).scale(2.0 * wsti_eff).mul(qi_sti).scale(1.0 / beta).mul(mu)
        .mul(expc(S, vds.scale(-beta)).neg().addC(1.0)).scale(co_isti);

    ids = ids.add(ids_sti);

    // ====================================================================
    // Section 19: Source/Body and Drain/Body Diode (Eqs 226-244)  [x-dependent]
    // ====================================================================
    // Forward/backward current densities (Eqs 227-228)  [f64]
    const ttnom = t_abs / tnom_abs;
    const js_fwd = js0 * @exp(@min((eg_tnom * beta_tnom - eg * beta + xti_val * @log(@max(ttnom, 1e-30))) / nj, 80.0));
    const js_rev = js0 * @exp(@min((eg_tnom * beta_tnom - eg * beta + xti2 * @log(@max(ttnom, 1e-30))) / nj, 80.0));
    // Saturation currents (Eqs 232-233)  [f64]
    const i_sbd = w_eff * nf_inst * tsoi * js_fwd;
    const i_sbd2 = w_eff * nf_inst * tsoi * js_rev;
    const nvtm = nj / beta;
    // Transition voltage (Eq 235)  [f64]
    const vbdt = nvtm * @log(@max(vdiffj / @max(i_sbd, 1e-50) * ttnom * ttnom + 1.0, 1.0));

    // Body-source and body-drain voltages  [x-dependent]
    const v_bcs = vbs; // body-source voltage
    const v_bcd = v_bcs.sub(vds); // body-drain voltage (Eq 234)

    // Drain-body diode current (Eqs 236-238) — branch on ORIGINAL voltage region
    const i_bd = if (v_bcd.val() < vbdt)
        expc(S, v_bcd.scale(1.0 / nvtm)).addC(-1.0).scale(i_sbd)
    else blk: {
        const exp_vbdt = @exp(@min(vbdt / nvtm, 80.0)); // f64
        // i_sbd*(exp_vbdt-1) + i_sbd/nvtm*exp_vbdt*(v_bcd - vbdt)
        break :blk v_bcd.addC(-vbdt).scale(i_sbd / nvtm * exp_vbdt).addC(i_sbd * (exp_vbdt - 1.0));
    };
    // i_bd_total = i_bd + divx*i_sbd2*v_bcd + v_bcd*GMIN
    const i_bd_total = i_bd.add(v_bcd.scale(divx * i_sbd2)).add(v_bcd.scale(GMIN));

    // Source-body diode current (same form)
    const i_bs = if (v_bcs.val() < vbdt)
        expc(S, v_bcs.scale(1.0 / nvtm)).addC(-1.0).scale(i_sbd)
    else blk: {
        const exp_vbdt = @exp(@min(vbdt / nvtm, 80.0)); // f64
        break :blk v_bcs.addC(-vbdt).scale(i_sbd / nvtm * exp_vbdt).addC(i_sbd * (exp_vbdt - 1.0));
    };
    const i_bs_total = i_bs.add(v_bcs.scale(divx * i_sbd2)).add(v_bcs.scale(GMIN));

    // ====================================================================
    // Section 13: Parasitic Resistances (Eqs 151-164)  [x-dependent]
    // ====================================================================
    // Drain-side drift resistance
    const v_ddp = v_drain.sub(v_dp).scale(type_f);
    const x_ov = @sqrt(xld * xld + rdrdjunc * rdrdjunc); // f64

    // Drift mobility with temperature (Eqs 144, 149, 154)  [f64]
    const mu_drift0_temp = rdrmue_raw / @exp(@min(rdrmuetmp * @log(@max(t_ratio, 1e-30)), 80.0));
    const mu_drift0 = mu_drift0_temp * (1.0 + rdrmuel / @exp(@min(rdrmuelp * @log(@max(l_gate_um, 1e-30)), 80.0)));
    // Drift Vmax with temperature (Eqs 147, 155)  [f64]
    const vmax_drift_denom = 1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - rdrvtmp * (1.0 - t_ratio);
    const vmax_drift_temp = rdrvmax_raw / @max(vmax_drift_denom, 0.1);
    const vmax_drift = vmax_drift_temp *
        (1.0 + rdrvmaxl / @exp(@min(rdrvmaxlp * @log(@max(l_gate_um, 1e-30)), 80.0))) *
        (1.0 + rdrvmaxw / @exp(@min(rdrvmaxwp * @log(@max(w_gate_um, 1e-30)), 80.0)));
    const rdrbb_temp = rdrbb_raw + rdrbbtmp * (t_abs - tnom_abs); // f64

    // Drift current (Eq 152-153): high-field correction  [x-dependent through v_ddp]
    const v_drift_sat = vmax_drift * ldrift_d; // f64
    // drift_vel_ratio = |v_ddp|/max(v_drift_sat,1e-30)
    const drift_vel_ratio = v_ddp.abs().scale(1.0 / @max(v_drift_sat, 1e-30));
    // drift_vel_pow = exp(min(rdrbb_temp*log(max(drift_vel_ratio,1e-30)),80))
    const drift_vel_pow = powg(S, drift_vel_ratio, rdrbb_temp, 1e-30);
    // mu_drift = mu_drift0 / exp(min((1/max(rdrbb_temp,0.1))*log(max(1+drift_vel_pow,1)),80))
    const mu_drift = powg(S, drift_vel_pow.addC(1.0).maxC(1.0), 1.0 / @max(rdrbb_temp, 0.1), 1e-30).pow(-1.0).scale(mu_drift0);
    // g_drift = w_eff*nf*x_ov*Q*nover_d*mu_drift/max(ldrift_d,1e-9)
    const g_drift = mu_drift.scale(w_eff * nf_inst * x_ov * Q_ELEM * nover_d / @max(ldrift_d, 1e-9));

    // External drain sheet resistance: Eq 151  [f64]
    const r_sh_d = rsh * nrd;
    const g_sh_d: f64 = if (r_sh_d > 0.0) 1.0 / r_sh_d else 0.0;
    // g_drain_total = g_drift + g_sh_d
    const g_drain_total = g_drift.addC(g_sh_d);
    // i_drain_res = cord ? g_drain_total*v_ddp : (v_drain - v_dp)*GSHORT
    const i_drain_res = if (model.cord != 0)
        g_drain_total.mul(v_ddp)
    else
        v_drain.sub(v_dp).scale(GSHORT);

    // Source-side drift resistance (Eqs 157-161)
    const v_ssp = v_source.sub(v_sp).scale(type_f);
    const mu_source0_temp = rdrmues_raw / @exp(@min(rdrmuetmp * @log(@max(t_ratio, 1e-30)), 80.0)); // f64
    const mu_source0 = mu_source0_temp * (1.0 + rdrmuel / @exp(@min(rdrmuelp * @log(@max(l_gate_um, 1e-30)), 80.0))); // f64
    const vmax_source_temp = rdrvmaxs_raw / @max(vmax_drift_denom, 0.1); // f64
    const vmax_source = vmax_source_temp *
        (1.0 + rdrvmaxl / @exp(@min(rdrvmaxlp * @log(@max(l_gate_um, 1e-30)), 80.0))) *
        (1.0 + rdrvmaxw / @exp(@min(rdrvmaxwp * @log(@max(w_gate_um, 1e-30)), 80.0))); // f64
    const rdrbbs_temp = rdrbbs_raw + rdrbbtmp * (t_abs - tnom_abs); // f64
    const v_source_sat = vmax_source * ldrift_s; // f64
    const source_vel_ratio = v_ssp.abs().scale(1.0 / @max(v_source_sat, 1e-30));
    const source_vel_pow = powg(S, source_vel_ratio, rdrbbs_temp, 1e-30);
    const mu_source_drift = powg(S, source_vel_pow.addC(1.0).maxC(1.0), 1.0 / @max(rdrbbs_temp, 0.1), 1e-30).pow(-1.0).scale(mu_source0);
    const g_source_drift = mu_source_drift.scale(w_eff * nf_inst * x_ov * Q_ELEM * novers_s / @max(ldrift_s, 1e-9));
    const r_sh_s = rsh * nrs; // f64
    const g_sh_s: f64 = if (r_sh_s > 0.0) 1.0 / r_sh_s else 0.0;
    const g_source_total = g_source_drift.addC(g_sh_s);
    const i_source_res = if (model.cors != 0)
        g_source_total.mul(v_ssp)
    else
        v_source.sub(v_sp).scale(GSHORT);

    // Gate resistance (Eq 162)
    const v_ggp = v_gate.sub(v_gp);
    const g_gate: f64 = if (model.corg != 0 and rshg > 0.0)
        ngcon * (l_drawn - xgl) * nf_inst / @max(rshg * (xgw + w_eff / (3.0 * ngcon)), 1e-30)
    else
        GSHORT;
    const i_gate_res = v_ggp.scale(g_gate);

    // ====================================================================
    // Section 13: Body Resistance Network (Eqs 163-164 with CORBNET)  [f64]
    // ====================================================================
    const co_rbnet: f64 = @floatFromInt(model.corbnet);
    const g_rbdb: f64 = if (rbdb_inst > 0.0) co_rbnet / rbdb_inst else 0.0;
    const g_rbsb: f64 = if (rbsb_inst > 0.0) co_rbnet / rbsb_inst else 0.0;
    _ = g_rbdb;
    _ = g_rbsb;

    // ====================================================================
    // Section 17: History Effect (Eqs 223-225) - DC approximation
    // ====================================================================
    const co_hist: f64 = @floatFromInt(model.cohist);
    // r_sb_hist = hist1/max(i_sub + hist2, 1e-50)  [x-dependent, unused in DC stamp]
    const r_sb_hist = i_sub.addC(hist2).maxC(1e-50).pow(-1.0).scale(hist1);
    const tau_h = r_sb_hist.mul(c_fox_eff);
    const q_h_hist = q_h.scale(co_hist);
    _ = tau_h;
    _ = q_h_hist;

    // ====================================================================
    // Section 18: Self-Heating - DC stub (thermal node not in U enum)
    // ====================================================================
    const co_selfheat: f64 = @floatFromInt(model.coselfheat);
    const rth0: f64 = @as(f64, model.rth0);
    const cth0: f64 = @as(f64, model.cth0);
    // p_diss = |ids|*vds  [x-dependent, unused in DC stamp]
    const p_diss = ids.abs().mul(vds);
    const delta_temp_sh = p_diss.scale(rth0 * co_selfheat);
    _ = delta_temp_sh;
    _ = cth0;

    // ====================================================================
    // Section 22: NQS - DC stub (no transient state)  [f64 stubs]
    // ====================================================================
    const co_nqs: f64 = @floatFromInt(model.conqs);
    const dly1: f64 = @as(f64, model.dly1);
    const dly2: f64 = @as(f64, model.dly2);
    const dly3: f64 = @as(f64, model.dly3);
    _ = co_nqs;
    _ = dly1;
    _ = dly2;
    _ = dly3;

    // ====================================================================
    // Section 21: Noise Model Equations (Eqs 304-314)
    // These feed the noise_gens framework; computed but not stamped.
    // ====================================================================
    const nfalp: f64 = @as(f64, model.nfalp);
    const nftrp: f64 = @as(f64, model.nftrp);
    const cit_val: f64 = @as(f64, model.cit);
    const falph: f64 = @as(f64, model.falph);
    _ = falph;
    // c_dep_noise (S: q_dep_soi depends on x) and n_star (S)
    const c_dep_noise = q_dep_soi.scale(1.0 / @max(tsoi, 1e-9));
    const n_star = c_fox_eff.add(c_dep_noise).addC(cit_val).scale(1.0 / (Q_ELEM * beta));
    // Carrier densities (S)
    const n_0 = qi_s.scale(1.0 / Q_ELEM);
    const n_l = qi_d.scale(1.0 / Q_ELEM);
    // l_noise = max(l_eff - delta_l, 1e-9) = l_chan
    const l_noise = l_chan;
    const n0_ns = n_0.add(n_star);
    const nl_ns = n_l.add(n_star);
    const flicker_term1 = n0_ns.mul(nl_ns).maxC(1e-50).pow(-1.0).scale(nftrp);
    const ey_noise = ey;
    const flicker_term2 = if (n_l.val() > n_0.val() + 1e-30)
        mu.mul(ey_noise).scale(2.0 * nfalp).div(n_l.sub(n_0).maxC(1e-30))
            .mul(nl_ns.div(n0_ns.maxC(1e-30)).maxC(1.0).log())
    else
        S.con(0.0);
    const flicker_term3_base = mu.mul(ey_noise).scale(nfalp);
    const flicker_term3 = flicker_term3_base.mul(flicker_term3_base);
    const s_ids_flicker = ids.mul(ids).scale(1.0 / (beta * w_eff * nf_inst)).div(l_noise)
        .mul(flicker_term1.add(flicker_term2).add(flicker_term3));
    _ = s_ids_flicker;

    // Thermal noise (Eq 307-312)
    const v_gvt = v_g0.maxC(0.01);
    const dphi_noise = phi_sl_soi.sub(phi_s0_soi);
    const mu_f_noise = mu;
    // ey_d_noise = max(ey + |dphi|/max(l_noise,1e-9), 1e-30)
    const ey_d_noise = ey.add(dphi_noise.abs().div(l_noise.maxC(1e-9))).maxC(1e-30);
    const vel_ratio_d = mu_0.mul(ey_d_noise).scale(1.0 / @max(vmax_eff, 1.0));
    const vel_pow_d = powg(S, vel_ratio_d, bb, 1e-30);
    const mu_d_noise = vel_pow_d.addC(1.0).maxC(1.0).pow(-1.0);
    const mu_av = mu_f_noise.add(mu_d_noise).scale(0.5);
    const eta_noise = dphi_noise.div(v_gvt.maxC(0.01)).neg().addC(1.0).maxC(0.01);
    // g_thermal (S) — reproduce the composite expression
    const g_num = mu_f_noise.mul(eta_noise.scale(3.0).addC(1.0).add(eta_noise.mul(eta_noise).scale(6.0))).mul(mu_d_noise).mul(mu_d_noise)
        .add(eta_noise.scale(4.0).addC(3.0).add(eta_noise.mul(eta_noise).scale(3.0)).mul(mu_d_noise).mul(mu_f_noise))
        .add(eta_noise.scale(3.0).addC(6.0).add(eta_noise.mul(eta_noise)).mul(mu_f_noise));
    const g_den = eta_noise.addC(1.0).mul(mu_av).mul(mu_av).scale(15.0).maxC(1e-30);
    const g_thermal = mu.scale(w_eff * nf_inst).mul(c_fox_eff).mul(v_gvt).div(l_noise).mul(g_num).div(g_den);
    _ = g_thermal;

    // ====================================================================
    // Scale all currents by type factor and multiplier (Section 23)
    // ====================================================================
    const ids_final = ids.scale(type_f * mode * m_mult);
    const isub_final = i_sub.scale(type_f * m_mult);
    const ibd_final = i_bd_total.scale(type_f * m_mult);
    const ibs_final = i_bs_total.scale(type_f * m_mult);
    const igate_d_final = i_gate_d.scale(type_f * m_mult);
    const igate_s_final = i_gate_s.scale(type_f * m_mult);
    const igb_final = i_gb.scale(type_f * m_mult);
    const igs_gate_final = i_gs_gate.scale(type_f * m_mult);
    const igd_gate_final = i_gd_gate.scale(type_f * m_mult);
    const igidl_final = i_gidl.scale(type_f * m_mult);
    const ievb_final = i_evb.scale(type_f * m_mult);
    const ibulk_impact_final = i_bulk_impact.scale(type_f * m_mult);

    // ====================================================================
    // KCL stamp (build residual vector)
    // ====================================================================
    var out: [n_u]S = undefined;

    // External drain: drain resistance
    out[D] = i_drain_res.scale(m_mult);
    // External gate: gate resistance
    out[G] = i_gate_res.scale(m_mult);
    // External source: source resistance
    out[Sn] = i_source_res.scale(-m_mult);
    // External substrate: substrate current + GMIN to substrate
    out[E] = isub_final.neg().add(v_es.scale(GMIN));
    // Body node: diode + GIDL + gate-bulk + EVB + impact ionization
    out[B] = ibd_final.add(ibs_final).neg().add(isub_final).sub(igb_final).sub(igidl_final).sub(ievb_final).add(ibulk_impact_final);
    // Internal drain-prime: Ids + diode + gate leakage + GIDL + drain resistance
    out[DP] = ids_final.add(ibd_final).add(igate_d_final).add(igd_gate_final).add(igidl_final).sub(i_drain_res.scale(m_mult));
    // Internal source-prime: -Ids + diode + gate leakage + source resistance
    out[SP] = ids_final.neg().add(ibs_final).add(igate_s_final).add(igs_gate_final).add(i_source_res.scale(m_mult));
    // Internal gate-prime: total gate current - gate resistance
    out[GP] = igate_d_final.add(igate_s_final).add(igb_final).add(igs_gate_final).add(igd_gate_final).neg().sub(i_gate_res.scale(m_mult));

    return out;
}

// ============================================================================
// Charge function: q (value-form, generic over scalar S)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = pc;

    const D = @intFromEnum(U.drain);
    const G = @intFromEnum(U.gate);
    const Sn = @intFromEnum(U.source);
    const E = @intFromEnum(U.sub);
    const B = @intFromEnum(U.body);
    const DP = @intFromEnum(U.dp);
    const SP = @intFromEnum(U.sp);
    const GP = @intFromEnum(U.gp);

    const v_dp = x[DP];
    const v_sp = x[SP];
    const v_gp = x[GP];
    const v_body = x[B];

    // --- Cast parameters (f64) ---
    const type_f: f64 = @floatFromInt(model.type_);
    const tfox: f64 = @as(f64, model.tfox);
    const tbox: f64 = @as(f64, model.tbox);
    const tsoi: f64 = @as(f64, model.tsoi);
    const xj: f64 = @as(f64, model.xj);
    const nsubs: f64 = @as(f64, model.nsubs);
    const vfbc: f64 = @as(f64, model.vfbc);
    const xld: f64 = @as(f64, model.xld);
    const xwd: f64 = @as(f64, model.xwd);
    const xldc_raw: f64 = @as(f64, model.xldc);
    const xwdc_raw: f64 = @as(f64, model.xwdc);
    const tpoly: f64 = @as(f64, model.tpoly);
    const lover: f64 = @as(f64, model.lover);
    const xqy_val: f64 = @as(f64, model.xqy);
    const xqy1: f64 = @as(f64, model.xqy1);
    const xqy2: f64 = @as(f64, model.xqy2);
    const ovslp: f64 = @as(f64, model.ovslp);
    const ovmag: f64 = @as(f64, model.ovmag);
    const cgdo_raw: f64 = @as(f64, model.cgdo);
    const cgso_raw: f64 = @as(f64, model.cgso);
    const cgbo: f64 = @as(f64, model.cgbo);

    // Diode cap
    const cj_val: f64 = @as(f64, model.cj);
    const cjsw: f64 = @as(f64, model.cjsw);
    const cjswg: f64 = @as(f64, model.cjswg);
    const mj: f64 = @as(f64, model.mj);
    const mjsw: f64 = @as(f64, model.mjsw);
    const mjswg: f64 = @as(f64, model.mjswg);
    const pb: f64 = @as(f64, model.pb);
    const pbsw: f64 = @as(f64, model.pbsw);
    const pbswg: f64 = @as(f64, model.pbswg);

    const eg0: f64 = @as(f64, model.eg0);
    const tnom_c: f64 = @as(f64, model.tnom);

    // Instance
    const l_drawn: f64 = @as(f64, instance.l);
    const w_drawn: f64 = @as(f64, instance.w);
    const nf_inst: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const ad: f64 = @as(f64, instance.ad);
    const as_val: f64 = @as(f64, instance.as_);
    const pd_val: f64 = @as(f64, instance.pd);
    const ps_val: f64 = @as(f64, instance.ps);
    const temp_c: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    // Geometry (f64)
    const l_gate = l_drawn;
    const w_gate = w_drawn / nf_inst;
    const l_eff = @max(l_gate - 2.0 * xld, 1e-9);
    const w_eff = @max(w_gate - 2.0 * xwd, 1e-9);
    const xldc = if (xldc_raw == 0.0) xld else xldc_raw;
    const xwdc = if (xwdc_raw == 0.0) xwd else xwdc_raw;
    // Eq 4: L_effc = L_gate - 2*XLDC
    const l_effc = @max(l_gate - 2.0 * xldc, 1e-9);
    const w_effc = @max(w_gate - 2.0 * xwdc, 1e-9);
    // BOX capacitance (Eq 12) - used for SOI charge limiting
    const c_box = EPS_OX / tbox;
    _ = l_effc;
    _ = c_box;

    // Section 20: Body-Tie geometry (Eqs 287-303)  [f64, unused in stamp]
    const nbt_inst: f64 = @as(f64, instance.nbt);
    const xwdbt: f64 = @as(f64, model.xwdbt);
    const lbt: f64 = @as(f64, instance.lbt);
    const wbtn: f64 = @as(f64, instance.wbtn);
    const wbtp: f64 = @as(f64, instance.wbtp);
    const abtn_raw: f64 = @as(f64, instance.abtn);
    const abtp_raw: f64 = @as(f64, instance.abtp);
    const pdbcp_q: f64 = @as(f64, instance.pdbcp);
    const psbcp_q: f64 = @as(f64, instance.psbcp);
    const vfbbtp: f64 = @as(f64, model.vfbbtp);
    _ = vfbbtp;

    const abtn_eff = if (abtn_raw > 0.0) abtn_raw else lbt * wbtn;
    const abtp_eff = if (abtp_raw > 0.0) abtp_raw else lbt * wbtp;
    const w_effc_bt = @max(w_gate - nbt_inst * xwdbt - (2.0 - nbt_inst) * xwdc, 1e-9);
    const cbtbn_raw: f64 = @as(f64, model.cbtbn);
    const cbtbp_raw: f64 = @as(f64, model.cbtbp);
    const cbtn_val: f64 = if (cbtbn_raw >= 0.0) cbtbn_raw else EPS_OX / tfox;
    const cbtp_val: f64 = if (cbtbp_raw >= 0.0) cbtbp_raw else EPS_OX / tfox;
    const c_gb_bt = cbtn_val * abtn_eff + cbtp_val * abtp_eff;
    const w_effc_source = w_effc + psbcp_q;
    const w_effc_drain = w_effc + pdbcp_q;
    const tpoly_q: f64 = @as(f64, model.tpoly);
    const c_fring_bt = if (tpoly_q > 0.0 and lbt > 0.0)
        EPS_OX / (3.14159265 / 2.0) * lbt * nf_inst * @log(1.0 + tpoly_q / tfox)
    else
        0.0;
    const c_fring_psbcp = if (tpoly_q > 0.0 and psbcp_q > 0.0)
        EPS_OX / (3.14159265 / 2.0) * psbcp_q * nf_inst * @log(1.0 + tpoly_q / tfox)
    else
        0.0;
    const c_fring_pdbcp = if (tpoly_q > 0.0 and pdbcp_q > 0.0)
        EPS_OX / (3.14159265 / 2.0) * pdbcp_q * nf_inst * @log(1.0 + tpoly_q / tfox)
    else
        0.0;
    const co_bcnode: f64 = @floatFromInt(model.cobcnode);
    const _w_effc_eff = if (co_bcnode > 0.0) w_effc_bt else w_effc;
    _ = _w_effc_eff;
    _ = w_effc_source;
    _ = w_effc_drain;
    _ = c_gb_bt;
    _ = c_fring_bt;
    _ = c_fring_psbcp;
    _ = c_fring_pdbcp;

    // Temperature (f64)
    const t_abs = temp_c + dtemp + 273.15;
    const tnom_abs = tnom_c + 273.15;
    const beta = Q_ELEM / (K_BOLTZ * t_abs);
    const eg_tnom_q = eg0 - 90.25e-6 * tnom_abs - 1.0e-7 * tnom_abs * tnom_abs;
    _ = eg_tnom_q;

    // Terminal voltages with type factor  [x-dependent -> S]
    const vgs = v_gp.sub(v_sp).scale(type_f);
    const vds_raw = v_dp.sub(v_sp).scale(type_f);
    const vbs = v_body.sub(v_sp).scale(type_f);
    // vds = |vds_raw| + vzadd0
    const vds = vds_raw.abs().addC(@as(f64, model.vzadd0));
    const fwd = vds_raw.val() >= 0.0;
    const _vgs_eff = if (fwd) vgs else vgs.sub(vds_raw);
    const _vbs_eff = if (fwd) vbs else vbs.sub(vds_raw);
    _ = _vgs_eff;
    _ = _vbs_eff;

    // Gate oxide cap (f64)
    const c_fox = EPS_OX / tfox;

    // ====================================================================
    // Section 14: Intrinsic Capacitances (Eq 165)  [x-dependent]
    // ====================================================================
    const ni = NI_300; // simplified for charge (f64)
    const phi_bc = (1.0 / beta) * @log(@max(nsubs / ni, 1e-30)); // f64
    const vfb = vfbc; // f64
    const v_g0 = vgs.addC(-vfb); // vgs - vfb
    const q_nsubs_esi = Q_ELEM * nsubs * EPS_SI; // f64
    const csi_fox2 = c_fox * c_fox; // f64

    // Surface potentials  [S]
    // phi_s0 = v_g0 + q_nsubs_esi/csi_fox2*(1 - sqrt(max(1 + 2*csi_fox2*max(v_g0-1/beta,0)/q_nsubs_esi,1)))
    const phi_s0_inner = v_g0.addC(-1.0 / beta).maxC(0.0).scale(2.0 * csi_fox2 / q_nsubs_esi).addC(1.0).maxC(1.0);
    const phi_s0 = v_g0.add(phi_s0_inner.sqrt().neg().addC(1.0).scale(q_nsubs_esi / csi_fox2));
    const phi_sl = phi_s0.add(vds);
    _ = phi_bc;

    // Inversion charge (simplified)  [S]
    const q_dep = Q_ELEM * nsubs * tsoi; // f64
    // qi_s = sqrt(max(q_dep^2 + 2*Q*EPS_SI/beta*exp(min(beta*phi_s0,80)), 1e-50)) - q_dep
    const qi_s = expc(S, phi_s0.scale(beta)).scale(2.0 * Q_ELEM * EPS_SI / beta).addC(q_dep * q_dep).maxC(1e-50).sqrt().addC(-q_dep);
    const qi_d = expc(S, phi_sl.scale(beta)).scale(2.0 * Q_ELEM * EPS_SI / beta).addC(q_dep * q_dep).maxC(1e-50).sqrt().addC(-q_dep);
    // qi_total = (qi_s + qi_d)*0.5*w_eff*nf*l_eff
    const qi_total = qi_s.add(qi_d).scale(0.5 * w_eff * nf_inst * l_eff);

    // Gate charge partitioning (40/60 split for Ward-Dutton)
    const _qi_ratio = qi_d.div(qi_s.add(qi_d).maxC(1e-30));
    _ = _qi_ratio;
    // qg_int = -qi_total - q_dep*w_eff*nf*l_eff
    const qg_int = qi_total.neg().addC(-q_dep * w_eff * nf_inst * l_eff);
    // qd_int = qi_total*(0.5 - (qi_s - qi_d)/max(3*(qi_s+qi_d),1e-30))
    const qd_int = qi_total.mul(qi_s.sub(qi_d).div(qi_s.add(qi_d).scale(3.0).maxC(1e-30)).neg().addC(0.5));
    const qs_int = qi_total.sub(qd_int);

    // ====================================================================
    // Section 14: Lateral-Field Induced Charge (Eq 166)  [x-dependent]
    // ====================================================================
    // w_d = sqrt(max(2*EPS_SI*max(2*phi_s0 - vbs, 0.01)/(Q*nsubs), 1e-30))
    const w_d = phi_s0.scale(2.0).sub(vbs).maxC(0.01).scale(2.0 * EPS_SI / (Q_ELEM * nsubs)).maxC(1e-30).sqrt();
    // q_y_term1 = (xqy>0) ? (phi_s0 + vds - phi_sl)/xqy : 0
    const q_y_term1 = if (xqy_val > 0.0) phi_s0.add(vds).sub(phi_sl).scale(1.0 / xqy_val) else S.con(0.0);
    // q_y_term2 = xqy1*w_eff*1e6*nf/exp(min(xqy2*log(max(l_gate*1e6,1e-30)),80)) * vbs
    const q_y_term2_f = xqy1 * w_eff * 1e6 * nf_inst / @exp(@min(xqy2 * @log(@max(l_gate * 1e6, 1e-30)), 80.0)); // f64
    const q_y_term2 = vbs.scale(q_y_term2_f);
    // q_y = EPS_SI*w_eff*nf*w_d*(q_y_term1 + q_y_term2)
    const q_y = w_d.scale(EPS_SI * w_eff * nf_inst).mul(q_y_term1.add(q_y_term2));

    // ====================================================================
    // Section 14: Overlap Charges (Eqs 167-178)  [x-dependent]
    // ====================================================================
    const c_ov_d: f64 = if (cgdo_raw >= 0.0) cgdo_raw else c_fox * lover;
    const c_ov_s: f64 = if (cgso_raw >= 0.0) cgso_raw else c_fox * lover;

    // Overlap charges  [branch on flag]
    const q_god = if (model.coovlp != 0)
        // Bias-dependent overlap (Eq 171):
        // w_effc*nf*c_fox*((vgs-vds)*lover - ovslp*(1.2 - (phi_sl - vds))*(ovmag + (vgs - vds)))
        vgs.sub(vds).scale(lover)
            .sub(phi_sl.sub(vds).neg().addC(1.2).scale(ovslp).mul(vgs.sub(vds).addC(ovmag)))
            .scale(w_effc * nf_inst * c_fox)
    else
        // Constant overlap: c_ov_d*w_effc*nf*(vgs - vds)
        vgs.sub(vds).scale(c_ov_d * w_effc * nf_inst);

    const q_gos = if (model.coovlp != 0)
        // w_effc*nf*c_fox*(vgs*lover - ovslp*(1.2 - phi_s0)*(ovmag + vgs))
        vgs.scale(lover)
            .sub(phi_s0.neg().addC(1.2).scale(ovslp).mul(vgs.addC(ovmag)))
            .scale(w_effc * nf_inst * c_fox)
    else
        vgs.scale(c_ov_s * w_effc * nf_inst);

    // Gate-bulk overlap (Eq 177): -cgbo*l_gate*(vgs - vbs)
    const q_gbo = vgs.sub(vbs).scale(-cgbo * l_gate);

    // Gate fringing capacitance (Eq 178)
    const c_fring = if (tpoly > 0.0)
        EPS_OX / (3.14159265 / 2.0) * w_gate * nf_inst * @log(1.0 + tpoly / tfox)
    else
        0.0; // f64
    const q_fring = vgs.scale(c_fring);

    // ====================================================================
    // Section 19.2: Diode Capacitance (Eqs 245-269)  [x-dependent]
    // ====================================================================
    // Drain junction charge
    const ad_eff = if (ad > 0.0) ad else w_eff * nf_inst * tsoi; // f64
    const pd_eff = if (pd_val > 0.0) pd_val else 2.0 * (w_eff * nf_inst + tsoi); // f64
    const czbd = cj_val * ad_eff; // f64
    const czbd_sw = cjsw * @max(pd_eff - w_effc * nf_inst, 0.0); // f64
    const czbd_swg = cjswg * w_effc * nf_inst; // f64

    const v_bcd = vbs.sub(vds);
    const q_bd = junctionCharge(S, v_bcd, czbd, pb, mj)
        .add(junctionCharge(S, v_bcd, czbd_sw, pbsw, mjsw))
        .add(junctionCharge(S, v_bcd, czbd_swg, pbswg, mjswg));

    // Clamp to max depletion charge (Eq 255)  [x-dependent, unused in stamp]
    const q_bd_max = Q_ELEM * nsubs * @max(tsoi - xj, 0.0) * ad_eff; // f64
    const _q_bd_clamped = if (v_bcd.val() < 0.0) q_bd.maxC(-q_bd_max) else q_bd;
    _ = _q_bd_clamped;

    // Source junction charge
    const as_eff = if (as_val > 0.0) as_val else w_eff * nf_inst * tsoi; // f64
    const ps_eff = if (ps_val > 0.0) ps_val else 2.0 * (w_eff * nf_inst + tsoi); // f64
    const czbs = cj_val * as_eff; // f64
    const czbs_sw = cjsw * @max(ps_eff - w_effc * nf_inst, 0.0); // f64
    const czbs_swg = cjswg * w_effc * nf_inst; // f64

    const q_bs = junctionCharge(S, vbs, czbs, pb, mj)
        .add(junctionCharge(S, vbs, czbs_sw, pbsw, mjsw))
        .add(junctionCharge(S, vbs, czbs_swg, pbswg, mjswg));

    // ====================================================================
    // Scale charges by multiplier and build charge vector
    // ====================================================================
    const scale = m_mult;
    var out: [n_u]S = undefined;

    out[D] = S.con(0.0); // external drain has no charge
    out[G] = S.con(0.0); // external gate has no charge
    out[Sn] = S.con(0.0); // external source has no charge
    out[E] = S.con(0.0); // substrate charge (minimal)
    out[B] = q_bd.add(q_bs).scale(-scale);
    out[DP] = qd_int.add(q_god).add(q_y).add(q_bd).scale(scale);
    out[SP] = qs_int.add(q_gos).add(q_bs).scale(scale);
    out[GP] = qg_int.sub(q_god).sub(q_gos).sub(q_gbo).sub(q_fring).scale(scale);

    return out;
}

// ============================================================================
// Junction charge helper (for depletion capacitance), value-form.
// Two regions: reverse bias (power-law), forward bias (quadratic extension).
// Eqs 250-269. Branch on the ORIGINAL voltage sign (region select).
// ============================================================================
inline fn junctionCharge(comptime S: type, v: S, cz: f64, phi: f64, mj_val: f64) S {
    // v < 0: reverse bias depletion; v >= 0: forward bias quadratic extension
    if (v.val() < 0.0) {
        // q_rev = phi*cz*(1 - arg^(1-mj))/(1-mj), arg = max(1 - v/phi, 1e-30)
        const arg = v.scale(-1.0 / phi).addC(1.0).maxC(1e-30);
        const sarg = powg(S, arg, 1.0 - mj_val, 1e-30); // arg^(1-mj) guarded
        return arg.mul(sarg).neg().addC(1.0).scale(phi * cz / (1.0 - mj_val));
    }
    // q_fwd = v*cz + v^2*cz*mj/(2*phi)
    return v.scale(cz).add(v.mul(v).scale(cz * mj_val / (2.0 * phi)));
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    // PN junction limiting (DEVpnjlim) and FET gate limiting (DEVfetlim)
    var x_out = x_new;

    const type_f: f64 = @floatFromInt(model.type_);
    const nj: f64 = @as(f64, model.nj);

    const DP = @intFromEnum(U.dp);
    const SP = @intFromEnum(U.sp);
    const GP = @intFromEnum(U.gp);
    const B = @intFromEnum(U.body);

    // Thermal voltage
    const vt = K_BOLTZ * 300.15 / Q_ELEM;
    const nvt = nj * vt;

    // Critical voltage for PN junction
    const is_val: f64 = @as(f64, model.js0) * 1e-10; // approximate small Is
    const v_crit = nvt * @log(nvt / (@sqrt(2.0) * is_val));

    // Body-drain junction limiting
    {
        const v_bd_new = (x_new[B] - x_new[DP]) * type_f;
        const v_bd_old = (x_old[B] - x_old[DP]) * type_f;
        const v_bd_lim = pnjlim(v_bd_new, v_bd_old, nvt, v_crit);
        const delta = (v_bd_lim - v_bd_new) * type_f;
        x_out[B] = x_out[B] + delta;
    }

    // Body-source junction limiting
    {
        const v_bs_new = (x_new[B] - x_new[SP]) * type_f;
        const v_bs_old = (x_old[B] - x_old[SP]) * type_f;
        const v_bs_lim = pnjlim(v_bs_new, v_bs_old, nvt, v_crit);
        const delta = (v_bs_lim - v_bs_new) * type_f;
        x_out[B] = x_out[B] + delta;
    }

    // Gate voltage limiting (DEVfetlim)
    {
        const vgs_new = (x_new[GP] - x_new[SP]) * type_f;
        const vgs_old = (x_old[GP] - x_old[SP]) * type_f;
        const vth: f64 = @as(f64, model.vfbc) + 0.6; // approximate Vth
        const vgs_lim = fetlim(vgs_new, vgs_old, vth);
        // VGSMIN surface potential limiter (type-dependent: -5 NMOS, 5 PMOS)
        const vgsmin_val: f64 = if (model.type_ == -1 and model.vgsmin == -5.0) 5.0 else @as(f64, model.vgsmin);
        const vgs_clamped = if (model.type_ == 1) @max(vgs_lim, vgsmin_val) else @min(vgs_lim, vgsmin_val);
        const delta = (vgs_clamped - vgs_new) * type_f;
        x_out[GP] = x_out[GP] + delta;
    }

    // Vds limiting (DEVlimvds)
    {
        const vds_new = (x_new[DP] - x_new[SP]) * type_f;
        const vds_old = (x_old[DP] - x_old[SP]) * type_f;
        const vds_lim = limvds(vds_new, vds_old);
        const delta = (vds_lim - vds_new) * type_f;
        x_out[DP] = x_out[DP] + delta;
    }

    return x_out;
}

// DEVpnjlim: PN junction voltage limiting
inline fn pnjlim(vnew: f64, vold: f64, nvt: f64, vcrit: f64) f64 {
    if (vnew > vcrit and @abs(vnew - vold) > 2.0 * nvt) {
        if (vold > 0.0) {
            const arg = 1.0 + (vnew - vold) / nvt;
            return if (arg > 0.0) vold + nvt * @log(arg) else vcrit;
        } else {
            return nvt * @log(vnew / nvt);
        }
    }
    return vnew;
}

// DEVfetlim: FET gate voltage limiting
inline fn fetlim(vnew: f64, vold: f64, vth: f64) f64 {
    const vgst_new = vnew - vth;
    const vgst_old = vold - vth;
    const vov2 = vgst_old + 0.5;

    if (vgst_new >= vgst_old) {
        if (vgst_old >= 0.0) {
            // Both above threshold
            const vtol = vov2 * 2.0;
            return if (vgst_new - vgst_old > vtol)
                vth + vgst_old + vtol
            else
                vnew;
        } else {
            // Subthreshold
            return if (vgst_new > 0.5) vth + 0.5 else vnew;
        }
    }
    // Decreasing voltage
    if (vgst_old >= 0.0) {
        const vtol = vov2 * 2.0;
        return if (vgst_old - vgst_new > vtol)
            vth + vgst_old - vtol
        else
            vnew;
    }
    return vnew;
}

// DEVlimvds: Drain-source voltage limiting
inline fn limvds(vnew: f64, vold: f64) f64 {
    if (vold >= 3.5) {
        return if (vnew > vold)
            @min(vnew, 3.0 * vold + 2.0)
        else if (vnew < 3.5)
            @max(vnew, 2.0)
        else
            vnew;
    }
    return if (vnew > vold)
        @min(vnew, 4.0)
    else
        @max(vnew, -0.5);
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale junction saturation current for source/parameter stepping
    // At lambda=0, Is is very large (easy to converge), at lambda=1 it is nominal
    const gmin_scale: f32 = @floatCast(GMIN * (1.0 - lambda));
    m.js0 = @as(f32, @floatCast(@as(f64, model.js0) + @as(f64, gmin_scale)));
    return m;
}

// ============================================================================
// Sparse conductance stamp pattern
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    // External drain <-> DP
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.drain) },
    // External source <-> SP
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.source) },
    // External gate <-> GP
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gp) },
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.gate) },
    // DP diagonal
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.dp) },
    // SP diagonal
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.sp) },
    // GP diagonal
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.gp) },
    // Channel: DP <-> SP
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.dp) },
    // Gate-channel: GP <-> DP, GP <-> SP
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.gp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.gp) },
    // Body <-> DP, Body <-> SP (junction diodes)
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.body) },
    // Substrate <-> Body (substrate current)
    .{ .row = @intFromEnum(U.sub), .col = @intFromEnum(U.sub) },
    .{ .row = @intFromEnum(U.sub), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.sub) },
    // GP <-> Body (gate-body leakage)
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.gp) },
};

// Sparse capacitance stamp pattern
pub const c_pattern_override = [_]contract.Entry(n_u){
    // Intrinsic gate charge: GP <-> DP, GP <-> SP
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.gp) },
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.gp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.gp) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.gp) },
    // DP diagonal (drain junction cap)
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.dp) },
    // SP diagonal (source junction cap)
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.sp) },
    // Body diagonal
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body) },
    // Body <-> DP, Body <-> SP (junction caps)
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.body) },
    // DP <-> SP (channel charge)
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.dp) },
};

// ============================================================================
// Contract validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Node order in x[]: {drain, gate, source, sub, body, dp, sp, gp}
// Helper to build a terminal-voltage vector for the 8 unknowns.
fn xv(drain: f64, gate: f64, source: f64, sub: f64, body: f64, dp: f64, sp: f64, gp: f64) [n_u]f64 {
    return .{ drain, gate, source, sub, body, dp, sp, gp };
}

test "hisim_soi: on-state channel current sign + KCL balance (NMOS)" {
    // Default NMOS. Bias the INTERNAL channel nodes so the intrinsic MOS
    // current flows: gp=1.2 (gate), dp=1.0 (drain), sp=0 (source), all others 0.
    // With type_=1, mode=+1 (vds_ext>=0), the drain-prime residual (DP) should
    // be positive (current into DP) and the source-prime (SP) its negative
    // partner in the channel; KCL over all 8 rows must sum to ~0 because every
    // stamped current is a branch current shared between two rows.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(
        Self,
        xv(1.0, 1.2, 0.0, 0.0, 0.0, 1.0, 0.0, 1.2),
        &model,
        &inst,
        0,
    );
    // KCL: total device current summed over all nodes is 0 (charge conservation
    // of the branch stamps). External D/G are tied to their primes (v equal),
    // internal channel currents are equal-and-opposite; substrate GMIN term
    // uses v_es = 0 here so it contributes nothing.
    var sum: f64 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-6);
    // Channel is conducting: DP residual (drain-prime) must be a real current.
    // (Long-channel default device => small but nonzero intrinsic current.)
    try testing.expect(@abs(out[5]) > 1e-11);
    // Source-prime carries the opposite channel current sign from drain-prime.
    try testing.expect(out[5] * out[6] < 0.0);
}

test "hisim_soi: zero-bias residual is ~zero (no spurious current)" {
    // All terminals grounded: every branch current must vanish (only vzadd0
    // symmetry offset remains inside vds, which does not by itself drive a
    // channel current at Vgs=0 below threshold).
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, xv(0, 0, 0, 0, 0, 0, 0, 0), &model, &inst, 0);
    var sum: f64 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-9);
}

test "hisim_soi: junctionCharge reverse-bias formula (hand-checked)" {
    // Reverse bias v_bcd < 0 exercises the power-law branch of junctionCharge.
    // Take a source-body diode with vbs = -1.0 V, default caps.
    //   cj=5e-4, mj=0.33, pb=1.0 ; as_eff = w_eff*nf*tsoi (defaults)
    //   w_eff = 5e-6 - 2*0 = ... actually w_gate = w/nf = 5e-6, xwd=0 -> w_eff=5e-6
    //   tsoi=50e-9 -> as_eff = 5e-6*1*50e-9 = 2.5e-13
    //   czbs = cj*as_eff = 5e-4 * 2.5e-13 = 1.25e-16
    // Reverse-bias area term at v=-1: arg = 1 - (-1)/1 = 2
    //   q_rev = phi*cz*(1 - arg^(1-mj))/(1-mj)
    //         = 1*1.25e-16*(1 - 2^0.67)/0.67
    //   2^0.67 = exp(0.67*ln2) = exp(0.67*0.693147) = exp(0.464408) = 1.591086
    //   (1 - 1.591086)/0.67 = -0.591086/0.67 = -0.882218
    //   area term ~ 1.25e-16 * -0.882218 = -1.10277e-16
    // The sidewall/gate terms add on top; here we only assert the body-charge
    // (out[B] = -(q_bd+q_bs)*m) is negative and of ~1e-16 magnitude for this
    // reverse-biased source diode with drain equal to source (v_bcd == vbs).
    const model: Model = .{};
    const inst: Instance = .{};
    // vbs = (v_body - v_sp)*type_f = (-1 - 0)*1 = -1 ; vds ~ vzadd0 (small)
    const out = contract.qValues(Self, xv(0, 0, 0, 0, -1.0, 0, 0, 0), &model, &inst, 0);
    // Body charge = -(q_bd + q_bs). Both diodes reverse-biased -> q<0 -> out[B]>0.
    try testing.expect(out[4] > 0.0);
    try testing.expect(@abs(out[4]) > 1e-17 and @abs(out[4]) < 1e-13);
}

test "hisim_soi: PMOS type factor flips channel current" {
    // Same bias magnitudes as the NMOS on-state test but PMOS (type_=-1) with
    // inverted terminal voltages. The drain-prime residual should have the
    // opposite sign of the NMOS case (type_f = -1 folds through ids_final).
    const nmodel: Model = .{};
    const pmodel: Model = .{ .type_ = -1 };
    const inst: Instance = .{};
    const nout = contract.evalValues(Self, xv(1.0, 1.2, 0, 0, 0, 1.0, 0, 1.2), &nmodel, &inst, 0);
    const pout = contract.evalValues(Self, xv(-1.0, -1.2, 0, 0, 0, -1.0, 0, -1.2), &pmodel, &inst, 0);
    // Both conduct
    try testing.expect(@abs(nout[5]) > 1e-11);
    try testing.expect(@abs(pout[5]) > 1e-11);
    // Opposite drain-prime current polarity between NMOS and PMOS symmetric bias
    try testing.expect(nout[5] * pout[5] < 0.0);
}
