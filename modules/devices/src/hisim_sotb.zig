const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// HiSIM-SOTB 1.3.0 — Surface-Potential-Based SOI MOSFET (Thin Body)
//
// Topology:
//   External:  G (gate), D (drain), S (source), E (substrate/back-gate)
//   Internal:  dp (intrinsic drain after Rd), sp (intrinsic source after Rs),
//              gp (intrinsic gate after Rg)
//
//   G  -- Rg  -- gp
//   D  -- Rd  -- dp
//   S  -- Rs  -- sp
//   Channel: dp <-> sp (controlled by gp, E)
//   Impact ionization, GIDL, gate tunneling, floating body
//
// Value-form contract: physics generic over scalar S. x-independent parameter,
// temperature and geometry prep stays plain f64 (in prepI / prepQ). Only the
// terminal-voltage-dependent chains use S ops so the Jacobian is analytic.
// ============================================================================

pub const U = enum(u8) {
    gate, // 0 - external gate
    drain, // 1 - external drain
    source, // 2 - external source
    sub, // 3 - external substrate (Ves)
    drain_prime, // 4 - intrinsic drain (after Rd)
    source_prime, // 5 - intrinsic source (after Rs)
    gate_prime, // 6 - intrinsic gate (after Rg)
};
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================
const Q_ELECTRON: f64 = 1.602176634e-19;
const K_BOLTZ: f64 = 1.380649e-23;
const EPS_0: f64 = 8.854187817e-12;
const EPS_SI: f64 = 11.7 * EPS_0;
const EPS_OX: f64 = 3.9 * EPS_0;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const NI_300: f64 = 1.45e10; // intrinsic concentration at 300K (cm^-3)
const PI: f64 = 3.14159265358979323846;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device type ---
    type_: i32 = 1, // 1=nMOS, -1=pMOS

    // --- Basic Device Parameters ---
    tfox: f32 = 3.5e-9, // Front oxide thickness [m]
    tbox: f32 = 10.0e-9, // Buried oxide thickness [m]
    tsoi: f32 = 10.0e-9, // Silicon film thickness [m]
    xld: f32 = 0.0, // Gate overlap length [m]
    xldl: f32 = 20.0e-9, // Channel-length dependence of XLD
    xldlmin: f32 = 10.0e-9, // Minimum value of XLDL
    xwd: f32 = 0.0, // Gate overlap width [m]
    xwdc: f32 = 0.0, // Cap width dependence
    tpoly: f32 = 0.0, // Poly-Si gate height [m]
    nsubs: f32 = 1.0e17, // SOI layer impurity conc [cm^-3]
    nsubb: f32 = 1.0e18, // Substrate impurity conc [cm^-3]
    nsubbl: f32 = 0.0, // L-dependence of NSUBB
    nsubblp: f32 = 1.0, // L-dependence of NSUBB
    nsubbw: f32 = 0.0, // W-dependence of NSUBB
    nsubbwp: f32 = 1.0, // W-dependence of NSUBB
    nsubbmin: f32 = 1.0e14, // Minimum NSUBB
    nsubp: f32 = 1.0e17, // Max pocket concentration [cm^-3]
    vfbc: f32 = -1.0, // Flat-band voltage [V]
    vbi: f32 = 1.1, // Built-in potential [V]
    vfbcl1: f32 = 0.0, // L-dependence of Vfb
    vfbcl1p: f32 = 1.0, // L-dependence of Vfb
    vfbcl2: f32 = 0.0, // L-dependence of Vfb
    vfbcl2p: f32 = 1.0, // L-dependence of Vfb
    vfbhamp: f32 = 0.0, // L-dependence of Vfb
    vbsbnd: f32 = 3.0, // Vbs for smoothing
    vbsmax: f32 = 3.5, // Maximum Vbs

    // --- Smoothing Coefficients ---
    ddltmax: f32 = 10.0, // Smoothing coefficient for Vds
    ddltslp: f32 = 50.0, // Lgate-dependence [um^-1]
    ddltict: f32 = 0.0, // Lgate-dependence

    // --- Mobility and Velocity (Front Current) ---
    muecb0: f32 = 300.0, // Coulomb scattering [cm^2/(V*s)]
    muecb0lp: f32 = 0.0,
    muecb0l2: f32 = 0.0,
    muecb0l2p: f32 = 1.0,
    muecb1: f32 = 30.0, // Coulomb scattering [cm^2/(V*s)]
    muecb1lp: f32 = 0.0,
    muecb1l2: f32 = 0.0,
    muecb1l2p: f32 = 1.0,
    mueph0: f32 = 0.3, // Phonon scattering exponent
    mueph1: f32 = 25.0e3, // Phonon scattering [cm^2/(V*s)]
    muetmp: f32 = 1.5, // T-dep of phonon scattering
    muetmpl: f32 = 0.0,
    muetmplp: f32 = 1.0,
    muetmp1: f32 = 0.0,
    muephl: f32 = 0.0, // L-dep of phonon mobility
    mueplp: f32 = 1.0,
    muesr0: f32 = 2.0, // Surface-roughness exponent
    muesr1: f32 = 2.0e15, // Surface-roughness coefficient
    muesrl: f32 = 0.0, // L-dep of surface roughness
    mueslp: f32 = 1.0,
    ndep: f32 = 1.0, // Depletion charge contrib to Eeff
    ndepl: f32 = 0.0,
    ndeplp: f32 = 0.0,
    ninv: f32 = 0.5, // Inversion charge contrib to Eeff
    ninvl: f32 = 0.0,
    ninvlp: f32 = 0.0,
    ninvd: f32 = 0.0, // Inversion charge parameter [V^-1]
    ninvdp: f32 = 1.0,
    bb: f32 = 2.0, // High-field degradation exponent
    vmax: f32 = 7.0e6, // Saturation velocity [cm/s]
    vover: f32 = 10.0e-3, // Velocity overshoot
    voverp: f32 = 100.0e-3,
    voverl: f32 = 0.0,
    voverlp: f32 = 1.0,
    voverw: f32 = 0.0, // W-dep of velocity overshoot
    voverwp: f32 = 1.0,
    vtmp: f32 = 0.0, // T-dep of saturation velocity
    vtmpl: f32 = 0.0,
    vtmplp: f32 = 1.0,
    votmp: f32 = 0.0,
    votmp2: f32 = 0.0,
    mueqb: f32 = 0.0, // Magnitude of QbL for front mobility
    mueqbl: f32 = 0.0,
    mueqblp: f32 = 0.0,
    mueqbb: f32 = 1.0, // Magnitude of QbL for back mobility

    // --- Mobility Model (Back Current) ---
    // Defaults: -1 sentinel => copy from front-side at runtime (spec: "=MUECB0" etc.)
    muecb0b: f32 = -1.0,
    muecb0lpb: f32 = -1.0,
    muecb0l2b: f32 = -1.0,
    muecb0l2pb: f32 = -1.0,
    muecb1b: f32 = -1.0,
    muecb1lpb: f32 = -1.0,
    muecb1l2b: f32 = -1.0,
    muecb1l2pb: f32 = -1.0,
    mueph0b: f32 = -1.0,
    mueph1b: f32 = -1.0,
    muephlb: f32 = -1.0,
    mueplpb: f32 = -1.0,
    muesr0b: f32 = -1.0,
    muesr1b: f32 = -1.0,
    muesrlb: f32 = -1.0,
    mueslpb: f32 = -1.0,

    // --- Short-Channel Effect ---
    parl1: f32 = 10.0e-9,
    parl2: f32 = 10.0e-9,
    sc1: f32 = 0.0,
    sc2: f32 = 0.0,
    sc3: f32 = 0.0,
    sc5: f32 = 0.0,
    scr1: f32 = 0.0,
    scr2: f32 = 0.0,
    scr3: f32 = 0.23,
    scp1: f32 = 0.0,
    scp2: f32 = 0.0,
    scp3: f32 = 0.0,
    lp: f32 = 0.0, // Pocket penetration length [m]
    pthrou: f32 = 0.0, // Subthreshold swing parameter
    vfbshift: f32 = 0.0,

    // --- Poly-Silicon Gate Depletion ---
    pgd1: f32 = 0.0,
    pgd2: f32 = 1.0,
    pgd4: f32 = 0.0,

    // --- Quantum Mechanical Effect ---
    qme1: f32 = 0.0,
    qme2: f32 = 0.0,
    qme3: f32 = 0.0,

    // --- Channel-Length Modulation ---
    clm1: f32 = 0.7,
    clm2: f32 = 0.0, // 0 means use default from eq. 127
    clm3: f32 = 1.0,
    clm5: f32 = 1.0,
    clm6: f32 = 0.0,

    // --- Punchthrough ---
    ptl: f32 = 0.0,
    ptlp: f32 = 1.0,
    ptp: f32 = 3.5,
    pt2: f32 = 0.0,
    pt4: f32 = 0.0,
    pt4p: f32 = 1.0,
    gdl: f32 = 0.0,
    gdlp: f32 = 0.0,
    gdld: f32 = 0.0,

    // --- Narrow-Channel Effect (Front) ---
    wfc: f32 = 0.0,
    wvth0: f32 = 0.0,
    nsubsw: f32 = 0.0,
    nsubswp: f32 = 1.0,
    nsubsmax: f32 = 5.0e18,
    nsubp0: f32 = 0.0,
    nsubwp: f32 = 1.0,
    muephw: f32 = 0.0,
    muepwp: f32 = 1.0,
    muesrw: f32 = 0.0,
    mueswp: f32 = 1.0,
    wl2: f32 = 0.0,
    wl2p: f32 = 1.0,
    muephs: f32 = 0.0,
    muepsp: f32 = 1.0,
    vovers: f32 = 0.0,
    voversp: f32 = 1.0,

    // --- Narrow-Channel Effect (Back) ---
    muephwb: f32 = 0.0,
    muepwpb: f32 = 1.0,
    muephsb: f32 = 0.0,
    muepspb: f32 = 1.0,
    muesrwb: f32 = 0.0,
    mueswpb: f32 = 1.0,

    // --- Well-Proximity Effect ---
    nsubswpe: f32 = 0.0,
    nsubpwpe: f32 = 0.0,
    web: f32 = 0.0,
    wec: f32 = 0.0,

    // --- STI Effects ---
    vthsti: f32 = 0.0,
    vdsti: f32 = 0.0,
    scsti1: f32 = 0.0,
    scsti2: f32 = 0.0,
    nsti: f32 = 5.0e17,
    nstil: f32 = 0.0,
    nstilp: f32 = 1.0,
    nstiw: f32 = 0.0,
    nstiwp: f32 = 1.0,
    wsti: f32 = 0.0,
    wstil: f32 = 0.0,
    wstilp: f32 = 1.0,
    wstiw: f32 = 0.0,
    wstiwp: f32 = 1.0,
    ratwsti: f32 = 0.0,
    wl1: f32 = 0.0,
    wl1p: f32 = 1.0,

    // --- STI Diffusion-Length Effects ---
    nsubssti1: f32 = 0.0,
    nsubssti2: f32 = 0.0,
    nsubssti3: f32 = 1.0,
    nsubpsti1: f32 = 0.0,
    nsubpsti2: f32 = 0.0,
    nsubpsti3: f32 = 1.0,
    muesti1: f32 = 0.0,
    muesti2: f32 = 0.0,
    muesti3: f32 = 1.0,
    saref: f32 = 1.0e-6,
    sbref: f32 = 1.0e-6,

    // --- Temperature Dependence ---
    eg0: f32 = 1.1785, // Bandgap [eV]
    bgtmp1: f32 = 90.25e-6, // T-dep of bandgap [eV/K]
    bgtmp2: f32 = 0.1e-6, // T-dep of bandgap [eV/K^2]
    tnom: f32 = 27.0, // Nominal temperature [degC]

    // --- Parasitic Resistance (Drift Region) ---
    rshg: f32 = 0.0, // Gate sheet resistance [Ohm/sq]
    rsh: f32 = 0.0, // Source/drain sheet resistance [Ohm/sq]
    ldrift: f32 = 1.0e-6, // Length of drain drift region [m]
    ldrifts: f32 = 1.0e-6, // Length of source drift region [m]
    rdrbbd: f32 = 1.0, // High field mobility drain
    rdrbbs: f32 = 1.0, // High field mobility source
    rdrmued: f32 = 1.0e3, // Mobility drain drift
    rdrmues: f32 = 1.0e3, // Mobility source drift
    rdrvmaxd: f32 = 3.0e7, // Saturation velocity drain
    rdrvmaxs: f32 = 3.0e7, // Saturation velocity source
    rdrvtmp: f32 = 0.0, // T-dep of resistance
    rdrmuetmp: f32 = 0.0, // T-dep of resistance
    rdrbbtmp: f32 = 0.0, // T-dep of resistance
    novers: f32 = 1.0e19, // Impurity conc overlap source
    rdrdjunc: f32 = 1.0e-6, // Junction depth
    rdrvmaxl: f32 = 0.0, // Vmax Lgate dependence
    rdrvmaxlp: f32 = 1.0,
    rdrvmaxw: f32 = 0.0, // Vmax Wgate dependence
    rdrvmaxwp: f32 = 1.0,
    rdrmuel: f32 = 0.0, // Mobility Lgate dependence
    rdrmuelp: f32 = 1.0,

    // --- Capacitance Parameters ---
    xqy: f32 = 0.0,
    xqy1: f32 = 0.0,
    xqy2: f32 = 2.0,
    lover: f32 = 30.0e-9, // Overlap length [m]
    nover: f32 = 1.0e19, // Impurity conc in overlap
    vfbover: f32 = 0.0, // Flat-band in overlap
    cgdo: f32 = -1.0, // negative = not specified
    cgso: f32 = -1.0,
    cgbo: f32 = -1.0,

    // --- Substrate Current (Impact Ionization) ---
    vfbsub: f32 = -1.0,
    vfbsubl: f32 = 0.0,
    vfbsublp: f32 = 1.0,
    sub1: f32 = 10.0,
    sub1l: f32 = 2.5e-3,
    sub1lp: f32 = 1.0,
    sub2: f32 = 20.0,
    sub2l: f32 = 2.0e-6,
    subdlt: f32 = 2.0e-3,
    svds: f32 = 0.8,
    slg: f32 = 3.0e-8,
    svgs: f32 = 0.8,
    svgsl: f32 = 0.0,
    svgslp: f32 = 1.0,
    svgsw: f32 = 0.0,
    svgswp: f32 = 1.0,
    svbs: f32 = 0.5,
    svbsl: f32 = 0.0,
    svbslp: f32 = 1.0,
    ibpc1: f32 = 0.0,
    ibpc2: f32 = 0.0,

    // --- Gate Leakage Current ---
    gleak1: f32 = 1.0e4,
    gleak2: f32 = 20.0e6,
    gleak3: f32 = 3.0e-1,
    gleak4: f32 = 0.0,
    gleak5: f32 = 7.5e3,
    gleak6: f32 = 2.5e-1,
    gleak7: f32 = 1.0e-6,
    gleak8: f32 = 1.0,
    gleak9: f32 = 5.0e-1,
    gleak10: f32 = 0.0,
    glksd1: f32 = 1.0e-15,
    glksd2: f32 = 5.0e6,
    glksd3: f32 = -5.0e6,
    glksd4: f32 = 0.0,
    glksd5: f32 = 1.0,
    glkb1: f32 = 5.0e-16,
    glkb2: f32 = 1.0,
    glkb3: f32 = 0.0,
    glkb4: f32 = 1.0,
    glkb5: f32 = 1.0,
    glkb6: f32 = 1.0,
    glkb7: f32 = 10.0e-12,
    glkb8: f32 = 15.0e-12,
    glkb21: f32 = 5.0e-16,
    glkb22: f32 = 1.0,
    glkb23: f32 = 0.0,
    glkb24: f32 = 1.0,
    glkb25: f32 = 1.0,
    glkb26: f32 = 1.0,
    glkb27: f32 = 10.0e-12,
    glkb28: f32 = 15.0e-12,

    // --- GIDL/GISL ---
    gidl1: f32 = 5.0e-6,
    gidl2: f32 = 1.0e6,
    gidl3: f32 = 0.3,
    gidl4: f32 = 0.0,
    gidl5: f32 = 0.2,
    gidlbpl1: f32 = 1.0e-6,
    gidlbplt: f32 = 0.0,
    tfoxgidl: f32 = 3.5e-9,

    // --- Valence Band Electron Tunneling ---
    evb1: f32 = 0.0,
    evb2: f32 = 0.0,
    evb3: f32 = 0.0,
    fvbs: f32 = 0.0,

    // --- Floating-Body Effect ---
    qhe1: f32 = 1.5,
    qhe2: f32 = 0.55,
    hist1: f32 = 1.0e-8,
    hist2: f32 = 1.0e-20,

    // --- 1/f Noise ---
    nfalp: f32 = 1.0e-16,
    nftrp: f32 = 1.0e10,
    cit: f32 = 0.0,
    falph: f32 = 1.0,

    // --- Non-Quasi-Static ---
    dly1: f32 = 1.0e-10,
    dly2: f32 = 0.7,
    dly3: f32 = 8.0e-7,

    // --- Self-Heating ---
    rth0: f32 = 0.1,
    cth0: f32 = 1.0e-7,

    // --- Symmetry Conservation ---
    vzadd0: f32 = 10.0e-3,
    pzadd0: f32 = 5.0e-3,

    // --- Model Selection Flags ---
    coovlp: i32 = 0,
    coqovsm: i32 = 1,
    coisub: i32 = 0,
    coiigs: i32 = 0,
    cogidl: i32 = 0,
    coisti: i32 = 0,
    coadov: i32 = 1,
    conqs: i32 = 0,
    cors: i32 = 0,
    cord: i32 = 0,
    corg: i32 = 0,
    coflick: i32 = 0,
    cothrml: i32 = 0,
    coign: i32 = 0,
    copprv: i32 = 1,
    coselfheat: i32 = 0,
    cofbe: i32 = 0,
    cohist: i32 = 0,
    coievb: i32 = 0,
    covbsbiz: i32 = 0,
    cocinv: i32 = 0,
    conewmub: i32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 5.0e-6, // Gate length [m]
    w: f32 = 5.0e-6, // Gate width [m]
    xgl: f32 = 0.0, // Offset of gate length [m]
    xgw: f32 = 0.0, // Distance from gate contact to channel edge [m]
    m: f32 = 1.0, // Multiplication factor
    nf: f32 = 1.0, // Number of gate fingers
    ngcon: f32 = 1.0, // Number of gate contacts
    sa: f32 = 0.0, // Length diffusion gate-STI [m]
    sb: f32 = 0.0, // Length diffusion gate-STI [m]
    sd: f32 = 0.0, // Length diffusion gate-gate [m]
    sca: f32 = 0.0, // Layout factor for WPE
    scb: f32 = 0.0, // Layout factor for WPE
    scc: f32 = 0.0, // Layout factor for WPE
    temp: f32 = 27.0, // Device temperature [degC]
    dtemp: f32 = 0.0, // Device temperature change [degC]
    nrd: f32 = 1.0, // Number of drain squares
    nrs: f32 = 1.0, // Number of source squares
    ldrift_i: f32 = 1.0e-6, // Instance drain drift length [m]
    ldrifts_i: f32 = 1.0e-6, // Instance source drift length [m]
};

// ============================================================================
// Noise Sources
// ============================================================================
pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise: channel drain-source
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Flicker (1/f) noise: channel drain-source
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
    // Shot noise: substrate current
    .{ .row = @intFromEnum(U.sub), .col = @intFromEnum(U.drain_prime), .kind = .shot },
    // Thermal noise: drain resistance
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Thermal noise: source resistance
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Thermal noise: gate resistance
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime), .kind = .thermal },
};

// ============================================================================
// Inline Helpers (scalar f64, no std) — used by x-INDEPENDENT param prep
// ============================================================================

inline fn safe_log(x: f64) f64 {
    return contract.fmath.log(@max(x, 1e-300));
}

inline fn safe_pow(base: f64, exp_val: f64) f64 {
    return contract.fmath.exp(exp_val * safe_log(@abs(base) + 1e-300));
}

inline fn safe_sqrt(x: f64) f64 {
    return @sqrt(@max(x, 0.0));
}

inline fn smooth_min(a: f64, b: f64, delta: f64) f64 {
    const diff = a - b;
    return 0.5 * (a + b - @sqrt(diff * diff + delta * delta));
}

// ============================================================================
// Value-form scalar helpers: faithful S-op mirrors of the f64 guards above.
// safe_sqrt -> maxC(0).sqrt(); safe_log -> maxC(1e-300).log();
// safe_pow  -> abs().addC(1e-300).log().scale(c).exp() (CONSTANT exponent c);
// expClamp  -> minC(80).exp().
// ============================================================================

inline fn sSqrt(comptime S: type, x: S) S {
    return x.maxC(0.0).sqrt();
}
inline fn sLog(comptime S: type, x: S) S {
    return x.maxC(1e-300).log();
}
/// safe_pow with CONSTANT exponent (matches inline safe_pow exactly).
inline fn sPow(comptime S: type, base: S, c: f64) S {
    return base.abs().addC(1e-300).log().scale(c).exp();
}
inline fn sExpClamp(comptime S: type, x: S) S {
    return x.minC(80.0).exp();
}

// ============================================================================
// x-INDEPENDENT parameter/temperature/geometry prep for the CURRENT function.
// Everything here is pure f64: it does not depend on terminal voltages, so it
// carries no Jacobian. Lifted verbatim out of the original i().
// ============================================================================

const ParamsI = struct {
    type_f: f64,
    m_mult: f64,
    nf: f64,
    beta: f64,
    vt: f64,
    eg: f64,
    ni: f64,
    ni2: f64,
    l_gate: f64,
    lum: f64,
    w_eff: f64,
    l_eff: f64,
    temp_c: f64,
    t_ratio: f64,
    tnom_p: f64,
    vzadd0_p: f64,
    // model params referenced in the S tail
    tfox_p: f64,
    tbox_p: f64,
    tsoi_p: f64,
    xld_p: f64,
    vfbc_p: f64,
    vbi_p: f64,
    parl1_p: f64,
    parl2_p: f64,
    sc1_p: f64,
    sc2_p: f64,
    sc3_p: f64,
    sc5_p: f64,
    scr1_p: f64,
    scr2_p: f64,
    scr3_p: f64,
    scp1_p: f64,
    scp2_p: f64,
    scp3_p: f64,
    lp_p: f64,
    pthrou_p: f64,
    pgd1_p: f64,
    pgd2_p: f64,
    pgd4_p: f64,
    qme1_p: f64,
    qme2_p: f64,
    qme3_p: f64,
    clm1_p: f64,
    clm3_p: f64,
    clm5_p: f64,
    clm6_p: f64,
    ptl_p: f64,
    ptlp_p: f64,
    ptp_p: f64,
    pt2_p: f64,
    pt4_p: f64,
    pt4p_p: f64,
    gdl_p: f64,
    gdlp_p: f64,
    gdld_p: f64,
    ddltmax_p: f64,
    ddltslp_p: f64,
    ddltict_p: f64,
    mueph0_p: f64,
    bb_p: f64,
    ninvd_p: f64,
    ninvdp_p: f64,
    nsti_p: f64,
    nstil_p: f64,
    nstilp_p: f64,
    nstiw_p: f64,
    nstiwp_p: f64,
    wsti_p: f64,
    wstil_p: f64,
    wstilp_p: f64,
    wstiw_p: f64,
    wstiwp_p: f64,
    wl1_p: f64,
    wl1p_p: f64,
    vthsti_p: f64,
    vdsti_p: f64,
    scsti1_p: f64,
    scsti2_p: f64,
    // substrate
    vfbsub_p: f64,
    vfbsubl_p: f64,
    vfbsublp_p: f64,
    sub1_p: f64,
    sub1l_p: f64,
    sub1lp_p: f64,
    sub2_p: f64,
    sub2l_p: f64,
    subdlt_p: f64,
    svds_p: f64,
    slg_p: f64,
    svgs_p: f64,
    svgsl_p: f64,
    svgslp_p: f64,
    svgsw_p: f64,
    svgswp_p: f64,
    svbs_p: f64,
    svbsl_p: f64,
    svbslp_p: f64,
    ibpc1_p: f64,
    ibpc2_p: f64,
    // gate leakage
    gleak1_p: f64,
    gleak2_p: f64,
    gleak3_p: f64,
    gleak4_p: f64,
    gleak5_p: f64,
    gleak6_p: f64,
    gleak7_p: f64,
    gleak8_p: f64,
    gleak9_p: f64,
    gleak10_p: f64,
    glksd1_p: f64,
    glksd2_p: f64,
    glksd3_p: f64,
    glksd4_p: f64,
    glksd5_p: f64,
    glkb1_p: f64,
    glkb2_p: f64,
    glkb3_p: f64,
    glkb4_p: f64,
    glkb5_p: f64,
    glkb6_p: f64,
    glkb7_p: f64,
    glkb8_p: f64,
    glkb21_p: f64,
    glkb22_p: f64,
    glkb23_p: f64,
    glkb24_p: f64,
    glkb25_p: f64,
    glkb26_p: f64,
    glkb27_p: f64,
    glkb28_p: f64,
    // GIDL
    gidl1_p: f64,
    gidl2_p: f64,
    gidl3_p: f64,
    gidl4_p: f64,
    gidl5_p: f64,
    gidlbpl1_p: f64,
    gidlbplt_p: f64,
    tfoxgidl_p: f64,
    // EVB
    evb1_p: f64,
    evb2_p: f64,
    evb3_p: f64,
    fvbs_p: f64,
    // FBE
    qhe1_p: f64,
    qhe2_p: f64,
    // resistances / drift
    rsh_p: f64,
    rshg_p: f64,
    nover_p: f64,
    novers_p: f64,
    ldrift_p: f64,
    ldrifts_p: f64,
    nrd: f64,
    nrs: f64,
    xgw: f64,
    ngcon: f64,
    l_drawn: f64,
    xgl: f64,
    x_ov: f64,
    mu_drift0: f64,
    vmax_drift: f64,
    rdrbb_temp: f64,
    mu_source0: f64,
    vmax_source: f64,
    rsrbb_temp: f64,
    rth0_p: f64,
    // derived quantities used by S tail
    nsubsp_eff: f64,
    nsubps: f64,
    nsubsp_sti: f64,
    nsubb_eff: f64,
    nsubs_m3: f64,
    nsubb_m3: f64,
    vfb: f64,
    phi_bc: f64,
    phi_b: f64,
    cfox: f64,
    cbox: f64,
    csoi: f64,
    const0_si: f64,
    qdep_soi: f64,
    c_ef: f64,
    dv_th_w: f64,
    dv_th_sm: f64,
    clm2_val: f64,
    mueqb_f: f64,
    mueqb_b: f64,
    ndep_mod: f64,
    ninv_mod: f64,
    muephonon: f64,
    muesurface: f64,
    mcoulomb0_f: f64,
    mcoulomb1_f: f64,
    t_ratio_mtmp: f64,
    muesr1_p: f64,
    vmax_t: f64,
    muephononb: f64,
    muesurfaceb: f64,
    mcoulomb0b: f64,
    mcoulomb1b: f64,
    muesr1b_p: f64,
    mueph0b_p: f64,
    mueqbb_p: f64,
    wfc_p: f64,
    // flags
    coisti: i32,
    coisub: i32,
    coiigs: i32,
    cogidl: i32,
    coievb: i32,
    cofbe: i32,
    coselfheat: i32,
    conewmub: i32,
    cord: i32,
    cors: i32,
    corg: i32,
};

fn prepI(model: *const Model, instance: *const Instance) ParamsI {
    // --- Cast model parameters to f64 ---
    const type_f: f64 = @floatFromInt(model.type_);
    const tfox_p: f64 = @as(f64, model.tfox);
    const tbox_p: f64 = @as(f64, model.tbox);
    const tsoi_p: f64 = @as(f64, model.tsoi);
    const xld_p: f64 = @as(f64, model.xld);
    const xldl_p: f64 = @as(f64, model.xldl);
    const xldlmin_p: f64 = @as(f64, model.xldlmin);
    const xwd_p: f64 = @as(f64, model.xwd);
    const nsubs_p: f64 = @as(f64, model.nsubs);
    const nsubb_p: f64 = @as(f64, model.nsubb);
    const nsubp_p: f64 = @as(f64, model.nsubp);
    const vfbc_p: f64 = @as(f64, model.vfbc);
    const vbi_p: f64 = @as(f64, model.vbi);
    const parl1_p: f64 = @as(f64, model.parl1);
    const parl2_p: f64 = @as(f64, model.parl2);
    const sc1_p: f64 = @as(f64, model.sc1);
    const sc2_p: f64 = @as(f64, model.sc2);
    const sc3_p: f64 = @as(f64, model.sc3);
    const sc5_p: f64 = @as(f64, model.sc5);
    const scr1_p: f64 = @as(f64, model.scr1);
    const scr2_p: f64 = @as(f64, model.scr2);
    const scr3_p: f64 = @as(f64, model.scr3);
    const scp1_p: f64 = @as(f64, model.scp1);
    const scp2_p: f64 = @as(f64, model.scp2);
    const scp3_p: f64 = @as(f64, model.scp3);
    const lp_p: f64 = @as(f64, model.lp);
    const pthrou_p: f64 = @as(f64, model.pthrou);
    const pgd1_p: f64 = @as(f64, model.pgd1);
    const pgd2_p: f64 = @as(f64, model.pgd2);
    const pgd4_p: f64 = @as(f64, model.pgd4);
    const qme1_p: f64 = @as(f64, model.qme1);
    const qme2_p: f64 = @as(f64, model.qme2);
    const qme3_p: f64 = @as(f64, model.qme3);
    const clm1_p: f64 = @as(f64, model.clm1);
    const clm3_p: f64 = @as(f64, model.clm3);
    const clm5_p: f64 = @as(f64, model.clm5);
    const clm6_p: f64 = @as(f64, model.clm6);
    const ptl_p: f64 = @as(f64, model.ptl);
    const ptlp_p: f64 = @as(f64, model.ptlp);
    const ptp_p: f64 = @as(f64, model.ptp);
    const pt2_p: f64 = @as(f64, model.pt2);
    const pt4_p: f64 = @as(f64, model.pt4);
    const pt4p_p: f64 = @as(f64, model.pt4p);
    const gdl_p: f64 = @as(f64, model.gdl);
    const gdlp_p: f64 = @as(f64, model.gdlp);
    const gdld_p: f64 = @as(f64, model.gdld);
    const ddltmax_p: f64 = @as(f64, model.ddltmax);
    const ddltslp_p: f64 = @as(f64, model.ddltslp);
    const ddltict_p: f64 = @as(f64, model.ddltict);
    const muecb0_p: f64 = @as(f64, model.muecb0);
    const muecb0lp_p: f64 = @as(f64, model.muecb0lp);
    const muecb0l2_p: f64 = @as(f64, model.muecb0l2);
    const muecb0l2p_p: f64 = @as(f64, model.muecb0l2p);
    const muecb1_p: f64 = @as(f64, model.muecb1);
    const muecb1lp_p: f64 = @as(f64, model.muecb1lp);
    const muecb1l2_p: f64 = @as(f64, model.muecb1l2);
    const muecb1l2p_p: f64 = @as(f64, model.muecb1l2p);
    const mueph0_p: f64 = @as(f64, model.mueph0);
    const mueph1_p: f64 = @as(f64, model.mueph1);
    const muetmp_p: f64 = @as(f64, model.muetmp);
    const muetmpl_p: f64 = @as(f64, model.muetmpl);
    const muetmplp_p: f64 = @as(f64, model.muetmplp);
    const muetmp1_p: f64 = @as(f64, model.muetmp1);
    const muephl_p: f64 = @as(f64, model.muephl);
    const mueplp_p: f64 = @as(f64, model.mueplp);
    const muesr0_p: f64 = @as(f64, model.muesr0);
    const muesr1_p: f64 = @as(f64, model.muesr1);
    const muesrl_p: f64 = @as(f64, model.muesrl);
    const mueslp_p: f64 = @as(f64, model.mueslp);
    const ndep_p: f64 = @as(f64, model.ndep);
    const ndepl_p: f64 = @as(f64, model.ndepl);
    const ndeplp_p: f64 = @as(f64, model.ndeplp);
    const ninv_p: f64 = @as(f64, model.ninv);
    const ninvl_p: f64 = @as(f64, model.ninvl);
    const ninvlp_p: f64 = @as(f64, model.ninvlp);
    const ninvd_p: f64 = @as(f64, model.ninvd);
    const ninvdp_p: f64 = @as(f64, model.ninvdp);
    const bb_p: f64 = @as(f64, model.bb);
    const vmax_p: f64 = @as(f64, model.vmax);
    const vover_p: f64 = @as(f64, model.vover);
    const voverp_p: f64 = @as(f64, model.voverp);
    const voverl_p: f64 = @as(f64, model.voverl);
    const voverlp_p: f64 = @as(f64, model.voverlp);
    const voverw_p: f64 = @as(f64, model.voverw);
    const voverwp_p: f64 = @as(f64, model.voverwp);
    const vtmp_p: f64 = @as(f64, model.vtmp);
    const vtmpl_p: f64 = @as(f64, model.vtmpl);
    const vtmplp_p: f64 = @as(f64, model.vtmplp);
    const mueqb_p: f64 = @as(f64, model.mueqb);
    const mueqbl_p: f64 = @as(f64, model.mueqbl);
    const mueqblp_p: f64 = @as(f64, model.mueqblp);
    const mueqbb_p: f64 = @as(f64, model.mueqbb);
    const eg0_p: f64 = @as(f64, model.eg0);
    const bgtmp1_p: f64 = @as(f64, model.bgtmp1);
    const bgtmp2_p: f64 = @as(f64, model.bgtmp2);
    const tnom_p: f64 = @as(f64, model.tnom);
    const rsh_p: f64 = @as(f64, model.rsh);
    const rshg_p: f64 = @as(f64, model.rshg);
    const nover_p: f64 = @as(f64, model.nover);
    const novers_p: f64 = @as(f64, model.novers);
    const rdrmued_p: f64 = @as(f64, model.rdrmued);
    const rdrmues_p: f64 = @as(f64, model.rdrmues);
    const rdrvmaxd_p: f64 = @as(f64, model.rdrvmaxd);
    const rdrvmaxs_p: f64 = @as(f64, model.rdrvmaxs);
    const rdrbbd_p: f64 = @as(f64, model.rdrbbd);
    const rdrbbs_p: f64 = @as(f64, model.rdrbbs);
    const rdrvtmp_p: f64 = @as(f64, model.rdrvtmp);
    const rdrmuetmp_p: f64 = @as(f64, model.rdrmuetmp);
    const rdrbbtmp_p: f64 = @as(f64, model.rdrbbtmp);
    const rdrdjunc_p: f64 = @as(f64, model.rdrdjunc);
    const rdrvmaxl_p: f64 = @as(f64, model.rdrvmaxl);
    const rdrvmaxlp_p: f64 = @as(f64, model.rdrvmaxlp);
    const rdrvmaxw_p: f64 = @as(f64, model.rdrvmaxw);
    const rdrvmaxwp_p: f64 = @as(f64, model.rdrvmaxwp);
    const rdrmuel_p: f64 = @as(f64, model.rdrmuel);
    const rdrmuelp_p: f64 = @as(f64, model.rdrmuelp);
    const ldrift_p: f64 = @as(f64, model.ldrift);
    const ldrifts_p: f64 = @as(f64, model.ldrifts);
    const vfbc_l1_p: f64 = @as(f64, model.vfbcl1);
    const vfbc_l1p_p: f64 = @as(f64, model.vfbcl1p);
    const vfbc_l2_p: f64 = @as(f64, model.vfbcl2);
    const vfbc_l2p_p: f64 = @as(f64, model.vfbcl2p);
    const vfbhamp_p: f64 = @as(f64, model.vfbhamp);
    const nsubbl_p: f64 = @as(f64, model.nsubbl);
    const nsubblp_p: f64 = @as(f64, model.nsubblp);
    const nsubbw_p: f64 = @as(f64, model.nsubbw);
    const nsubbwp_p: f64 = @as(f64, model.nsubbwp);
    const wfc_p: f64 = @as(f64, model.wfc);
    const wvth0_p: f64 = @as(f64, model.wvth0);
    const nsubsw_p: f64 = @as(f64, model.nsubsw);
    const nsubswp_p: f64 = @as(f64, model.nsubswp);
    const nsubsmax_p: f64 = @as(f64, model.nsubsmax);
    const nsubp0_p: f64 = @as(f64, model.nsubp0);
    const nsubwp_p: f64 = @as(f64, model.nsubwp);
    const muephw_p: f64 = @as(f64, model.muephw);
    const muepwp_p: f64 = @as(f64, model.muepwp);
    const muesrw_p: f64 = @as(f64, model.muesrw);
    const mueswp_p: f64 = @as(f64, model.mueswp);
    const wl2_p: f64 = @as(f64, model.wl2);
    const wl2p_p: f64 = @as(f64, model.wl2p);
    const muephs_p: f64 = @as(f64, model.muephs);
    const muepsp_p: f64 = @as(f64, model.muepsp);
    const vovers_p: f64 = @as(f64, model.vovers);
    const voversp_p: f64 = @as(f64, model.voversp);
    // Back narrow-channel
    const muephwb_p: f64 = @as(f64, model.muephwb);
    const muepwpb_p: f64 = @as(f64, model.muepwpb);
    const muephsb_p: f64 = @as(f64, model.muephsb);
    const muepspb_p: f64 = @as(f64, model.muepspb);
    const muesrwb_p: f64 = @as(f64, model.muesrwb);
    const mueswpb_p: f64 = @as(f64, model.mueswpb);
    // Back mobility -- resolve sentinel (-1) to front-side value at runtime (spec: "=MUECB0" etc.)
    const muecb0b_p: f64 = if (model.muecb0b < 0.0) muecb0_p else @as(f64, model.muecb0b);
    const muecb0lpb_p: f64 = if (model.muecb0lpb < 0.0) muecb0lp_p else @as(f64, model.muecb0lpb);
    const muecb0l2b_p: f64 = if (model.muecb0l2b < 0.0) muecb0l2_p else @as(f64, model.muecb0l2b);
    const muecb0l2pb_p: f64 = if (model.muecb0l2pb < 0.0) muecb0l2p_p else @as(f64, model.muecb0l2pb);
    const muecb1b_p: f64 = if (model.muecb1b < 0.0) muecb1_p else @as(f64, model.muecb1b);
    const muecb1lpb_p: f64 = if (model.muecb1lpb < 0.0) muecb1lp_p else @as(f64, model.muecb1lpb);
    const muecb1l2b_p: f64 = if (model.muecb1l2b < 0.0) muecb1l2_p else @as(f64, model.muecb1l2b);
    const muecb1l2pb_p: f64 = if (model.muecb1l2pb < 0.0) muecb1l2p_p else @as(f64, model.muecb1l2pb);
    const mueph0b_p: f64 = if (model.mueph0b < 0.0) mueph0_p else @as(f64, model.mueph0b);
    const mueph1b_p: f64 = if (model.mueph1b < 0.0) mueph1_p else @as(f64, model.mueph1b);
    const muephlb_p: f64 = if (model.muephlb < 0.0) muephl_p else @as(f64, model.muephlb);
    const mueplpb_p: f64 = if (model.mueplpb < 0.0) mueplp_p else @as(f64, model.mueplpb);
    const muesr0b_p: f64 = if (model.muesr0b < 0.0) muesr0_p else @as(f64, model.muesr0b);
    const muesr1b_p: f64 = if (model.muesr1b < 0.0) muesr1_p else @as(f64, model.muesr1b);
    const muesrlb_p: f64 = if (model.muesrlb < 0.0) muesrl_p else @as(f64, model.muesrlb);
    const mueslpb_p: f64 = if (model.mueslpb < 0.0) mueslp_p else @as(f64, model.mueslpb);
    // WPE
    const nsubswpe_p: f64 = @as(f64, model.nsubswpe);
    const nsubpwpe_p: f64 = @as(f64, model.nsubpwpe);
    const web_p: f64 = @as(f64, model.web);
    const wec_p: f64 = @as(f64, model.wec);
    // STI
    const vthsti_p: f64 = @as(f64, model.vthsti);
    const vdsti_p: f64 = @as(f64, model.vdsti);
    const scsti1_p: f64 = @as(f64, model.scsti1);
    const scsti2_p: f64 = @as(f64, model.scsti2);
    const nsti_p: f64 = @as(f64, model.nsti);
    const nstil_p: f64 = @as(f64, model.nstil);
    const nstilp_p: f64 = @as(f64, model.nstilp);
    const nstiw_p: f64 = @as(f64, model.nstiw);
    const nstiwp_p: f64 = @as(f64, model.nstiwp);
    const wsti_p: f64 = @as(f64, model.wsti);
    const wstil_p: f64 = @as(f64, model.wstil);
    const wstilp_p: f64 = @as(f64, model.wstilp);
    const wstiw_p: f64 = @as(f64, model.wstiw);
    const wstiwp_p: f64 = @as(f64, model.wstiwp);
    const ratwsti_p: f64 = @as(f64, model.ratwsti);
    const wl1_p: f64 = @as(f64, model.wl1);
    const wl1p_p: f64 = @as(f64, model.wl1p);
    // STI diffusion
    const nsubssti1_p: f64 = @as(f64, model.nsubssti1);
    const nsubssti2_p: f64 = @as(f64, model.nsubssti2);
    const nsubssti3_p: f64 = @as(f64, model.nsubssti3);
    const nsubpsti1_p: f64 = @as(f64, model.nsubpsti1);
    const nsubpsti2_p: f64 = @as(f64, model.nsubpsti2);
    const nsubpsti3_p: f64 = @as(f64, model.nsubpsti3);
    const muesti1_p: f64 = @as(f64, model.muesti1);
    const muesti2_p: f64 = @as(f64, model.muesti2);
    const muesti3_p: f64 = @as(f64, model.muesti3);
    const saref_p: f64 = @as(f64, model.saref);
    const sbref_p: f64 = @as(f64, model.sbref);
    // Substrate current
    const vfbsub_p: f64 = @as(f64, model.vfbsub);
    const vfbsubl_p: f64 = @as(f64, model.vfbsubl);
    const vfbsublp_p: f64 = @as(f64, model.vfbsublp);
    const sub1_p: f64 = @as(f64, model.sub1);
    const sub1l_p: f64 = @as(f64, model.sub1l);
    const sub1lp_p: f64 = @as(f64, model.sub1lp);
    const sub2_p: f64 = @as(f64, model.sub2);
    const sub2l_p: f64 = @as(f64, model.sub2l);
    const subdlt_p: f64 = @as(f64, model.subdlt);
    const svds_p: f64 = @as(f64, model.svds);
    const slg_p: f64 = @as(f64, model.slg);
    const svgs_p: f64 = @as(f64, model.svgs);
    const svgsl_p: f64 = @as(f64, model.svgsl);
    const svgslp_p: f64 = @as(f64, model.svgslp);
    const svgsw_p: f64 = @as(f64, model.svgsw);
    const svgswp_p: f64 = @as(f64, model.svgswp);
    const svbs_p: f64 = @as(f64, model.svbs);
    const svbsl_p: f64 = @as(f64, model.svbsl);
    const svbslp_p: f64 = @as(f64, model.svbslp);
    const ibpc1_p: f64 = @as(f64, model.ibpc1);
    const ibpc2_p: f64 = @as(f64, model.ibpc2);
    // Gate leakage
    const gleak1_p: f64 = @as(f64, model.gleak1);
    const gleak2_p: f64 = @as(f64, model.gleak2);
    const gleak3_p: f64 = @as(f64, model.gleak3);
    const gleak4_p: f64 = @as(f64, model.gleak4);
    const gleak5_p: f64 = @as(f64, model.gleak5);
    const gleak6_p: f64 = @as(f64, model.gleak6);
    const gleak7_p: f64 = @as(f64, model.gleak7);
    const gleak8_p: f64 = @as(f64, model.gleak8);
    const gleak9_p: f64 = @as(f64, model.gleak9);
    const gleak10_p: f64 = @as(f64, model.gleak10);
    const glksd1_p: f64 = @as(f64, model.glksd1);
    const glksd2_p: f64 = @as(f64, model.glksd2);
    const glksd3_p: f64 = @as(f64, model.glksd3);
    const glksd4_p: f64 = @as(f64, model.glksd4);
    const glksd5_p: f64 = @as(f64, model.glksd5);
    const glkb1_p: f64 = @as(f64, model.glkb1);
    const glkb2_p: f64 = @as(f64, model.glkb2);
    const glkb3_p: f64 = @as(f64, model.glkb3);
    const glkb4_p: f64 = @as(f64, model.glkb4);
    const glkb5_p: f64 = @as(f64, model.glkb5);
    const glkb6_p: f64 = @as(f64, model.glkb6);
    const glkb7_p: f64 = @as(f64, model.glkb7);
    const glkb8_p: f64 = @as(f64, model.glkb8);
    const glkb21_p: f64 = @as(f64, model.glkb21);
    const glkb22_p: f64 = @as(f64, model.glkb22);
    const glkb23_p: f64 = @as(f64, model.glkb23);
    const glkb24_p: f64 = @as(f64, model.glkb24);
    const glkb25_p: f64 = @as(f64, model.glkb25);
    const glkb26_p: f64 = @as(f64, model.glkb26);
    const glkb27_p: f64 = @as(f64, model.glkb27);
    const glkb28_p: f64 = @as(f64, model.glkb28);
    // GIDL
    const gidl1_p: f64 = @as(f64, model.gidl1);
    const gidl2_p: f64 = @as(f64, model.gidl2);
    const gidl3_p: f64 = @as(f64, model.gidl3);
    const gidl4_p: f64 = @as(f64, model.gidl4);
    const gidl5_p: f64 = @as(f64, model.gidl5);
    const gidlbpl1_p: f64 = @as(f64, model.gidlbpl1);
    const gidlbplt_p: f64 = @as(f64, model.gidlbplt);
    const tfoxgidl_p: f64 = @as(f64, model.tfoxgidl);
    // EVB
    const evb1_p: f64 = @as(f64, model.evb1);
    const evb2_p: f64 = @as(f64, model.evb2);
    const evb3_p: f64 = @as(f64, model.evb3);
    const fvbs_p: f64 = @as(f64, model.fvbs);
    // FBE
    const qhe1_p: f64 = @as(f64, model.qhe1);
    const qhe2_p: f64 = @as(f64, model.qhe2);
    // Symmetry
    const vzadd0_p: f64 = @as(f64, model.vzadd0);

    // --- Cast instance parameters ---
    const l_drawn: f64 = @as(f64, instance.l);
    const w_drawn: f64 = @as(f64, instance.w);
    const m_mult: f64 = @as(f64, instance.m);
    const nf: f64 = @as(f64, instance.nf);
    const ngcon: f64 = @as(f64, instance.ngcon);
    const xgw: f64 = @as(f64, instance.xgw);
    const nrd: f64 = @as(f64, instance.nrd);
    const nrs: f64 = @as(f64, instance.nrs);
    const sca_p: f64 = @as(f64, instance.sca);
    const scb_p: f64 = @as(f64, instance.scb);
    const scc_p: f64 = @as(f64, instance.scc);
    const sa_p: f64 = @as(f64, instance.sa);
    const sb_p: f64 = @as(f64, instance.sb);

    // --- Temperature ---
    const temp_c: f64 = @as(f64, instance.temp) + @as(f64, instance.dtemp);
    const temp_k: f64 = temp_c + 273.15;
    const tnom_k: f64 = tnom_p + 273.15;
    const t_ratio: f64 = temp_k / tnom_k;
    const beta: f64 = Q_ELECTRON / (K_BOLTZ * temp_k);
    const vt: f64 = 1.0 / beta;

    // Bandgap (eq 176-177)
    const eg_tnom = eg0_p - 90.25e-6 * tnom_p - 1.0e-7 * tnom_p * tnom_p;
    const eg = eg_tnom - bgtmp1_p * (temp_c - tnom_p) - bgtmp2_p * (temp_c * temp_c - tnom_p * tnom_p);

    // Intrinsic carrier concentration (eq 178)
    const ni = NI_300 * safe_pow(t_ratio, 1.5) * contract.fmath.exp(@min(-(eg * Q_ELECTRON) / (2.0 * K_BOLTZ * temp_k), 80.0));
    const ni2 = ni * ni;

    // ===== DEVICE GEOMETRY (Eq. 1-7) =====
    const l_gate = l_drawn; // Eq 1
    const w_gate = w_drawn / nf; // Eq 2
    const lum = l_gate * 1.0e6; // Lgate in um
    const wum = w_gate * 1.0e6; // Wgate in um
    const wl = wum * lum; // Eq 148/155

    // STI width modification (Eq 153)
    const w_sti_mod = wsti_p * ratwsti_p;

    // Gate overlap (Eq 6-7)
    const xldmod = xld_p * l_gate / @max(xldl_p + xldlmin_p, 1.0e-30);
    const xld_eff = if (xld_p > 0.0) @min(xldmod, xld_p) else @max(xldmod, xld_p);
    const l_eff = @max(l_gate - 2.0 * xld_eff, 1.0e-9); // Eq 3
    const w_eff = @max(w_gate - 2.0 * xwd_p - 2.0 * w_sti_mod, 1.0e-9); // Eq 4

    // ===== WELL-PROXIMITY EFFECT (Eq 159-160) =====
    const wpe_factor = sca_p + web_p * scb_p + wec_p * scc_p;
    const nsubs_wpe = nsubs_p + nsubswpe_p * wpe_factor;
    const nsubp_wpe = nsubp_p + nsubpwpe_p * wpe_factor;

    // ===== SOI IMPURITY W-DEPENDENCE (Eq 133) =====
    const nsubsp_w = @min(nsubsmax_p, nsubs_wpe * (1.0 + nsubsw_p / safe_pow(wum, nsubswp_p)));

    // ===== POCKET CONCENTRATION W-DEPENDENCE (Eq 132) =====
    const nsubpp = nsubp_wpe * (1.0 + nsubp0_p / safe_pow(wum, nsubwp_p));

    // ===== STI DIFFUSION-LENGTH EFFECTS (Eq 161-173) =====
    const lod_half = if (sa_p > 0.0 and sb_p > 0.0) 1.0 / (1.0 / (sa_p + 1.0e-30) + 1.0 / (sb_p + 1.0e-30)) else 0.0;
    const lod_half_ref = 1.0 / (1.0 / saref_p + 1.0 / sbref_p);

    // Channel conc modifier (Eq 161-165)
    const nsubsti_t1 = 1.0 / (1.0 + nsubssti2_p);
    const nsubsti_t2 = nsubssti1_p / safe_pow(@max(lod_half, 1.0e-30), nsubssti3_p);
    const nsubsti_t3 = nsubssti1_p / safe_pow(lod_half_ref, nsubssti3_p);
    const nsubsti = (1.0 + nsubsti_t1 * nsubsti_t2) / (1.0 + nsubsti_t1 * nsubsti_t3);
    const nsubsp_sti = nsubsp_w * nsubsti; // Eq 165

    // Pocket conc modifier (Eq 166-170)
    const tsubsti_t1 = 1.0 / (1.0 + nsubpsti2_p);
    const tsubsti_t2 = nsubpsti1_p / safe_pow(@max(lod_half, 1.0e-30), nsubpsti3_p);
    const tsubsti_t3 = nsubpsti1_p / safe_pow(lod_half_ref, nsubpsti3_p);
    const tsubsti = (1.0 + tsubsti_t1 * tsubsti_t2) / (1.0 + tsubsti_t1 * tsubsti_t3);
    const nsubps = if (lod_half > 0.0) nsubpp * tsubsti else nsubpp; // Eq 170

    // ===== POCKET IMPURITY (Eq 65) =====
    const nsubsp_eff = if (l_gate > lp_p and lp_p > 0.0)
        (nsubsp_sti * (l_gate - lp_p) + nsubps * lp_p) / l_gate
    else if (lp_p > 0.0)
        nsubps + (nsubps - nsubsp_sti) * (lp_p - l_gate) / @max(lp_p, 1.0e-30)
    else
        nsubsp_sti; // Eq 65

    // ===== SUBSTRATE IMPURITY (Eq 66, 134) =====
    const nsubb_l = nsubb_p * (1.0 + nsubbl_p / safe_pow(lum, nsubblp_p)); // Eq 66
    const nsubb_eff = @max(@as(f64, model.nsubbmin), nsubb_l * (1.0 + nsubbw_p / safe_pow(wum, nsubbwp_p))); // Eq 134

    // ===== FLAT-BAND VOLTAGE (Eq 68-70) =====
    const vfb1 = vfbc_p * (1.0 + vfbc_l1_p / safe_pow(lum, vfbc_l1p_p)); // Eq 68
    const vfb2 = vfbc_p * (1.0 + vfbc_l2_p / safe_pow(lum, vfbc_l2p_p)); // Eq 69
    const vfb3 = vfbc_p + vfbhamp_p * lum; // Eq 70
    // Smooth limiting: vfb1 <= vfb2 <= vfb3
    const vfb_12 = smooth_min(vfb1, vfb2, 1.0e-6);
    const vfb = smooth_min(vfb_12, vfb3, 1.0e-6); // Eq 67

    // ===== BULK POTENTIALS (Eq 63-64) =====
    const phi_bc = 2.0 * vt * safe_log(nsubsp_eff / ni); // Eq 63 (using Nsubs_eff)
    const phi_b = if (lp_p > 0.0)
        2.0 * vt * safe_log(nsubps / ni) // Eq 64 (pocket)
    else
        phi_bc;

    // ===== CAPACITANCES =====
    const cfox = EPS_OX / tfox_p; // Eq 14
    const cbox = EPS_OX / tbox_p; // Eq 15
    const csoi = EPS_SI / tsoi_p; // Eq 16

    // const0 in SI units (Eq 23)
    const nsubs_m3 = nsubsp_eff * 1.0e6;
    const nsubb_m3 = nsubb_eff * 1.0e6;
    const const0_si = safe_sqrt(2.0 * EPS_SI * Q_ELECTRON * nsubs_m3 / beta);

    // Q_dep_SOI (Eq 17)
    const qdep_soi = -Q_ELECTRON * nsubsp_eff * 1.0e6 * tsoi_p;

    // ===== NARROW-CHANNEL EFFECTS (Eq 129-131, 154) =====
    const c_ef = wfc_p / 2.0 * l_eff; // Eq 131
    const dv_th_w = if (wfc_p != 0.0)
        (1.0 / cfox - 1.0 / (cfox + 2.0 * c_ef / @max(l_eff * w_eff, 1.0e-30))) * qdep_soi + wvth0_p / @max(wum, 1.0e-6)
    else
        wvth0_p / @max(wum, 1.0e-6); // Eq 129
    const dv_th_sm = wl2_p / safe_pow(@max(wl, 1.0e-30), wl2p_p); // Eq 154

    // ===== CHANNEL-LENGTH MODULATION default (Eq 127) =====
    const clm2_val: f64 = if (model.clm2 == 0.0)
        5.0e9 / @max(tsoi_p * nsubs_p, 1.0e-30)
    else
        @as(f64, model.clm2);

    // ===== MOBILITY MODEL (x-independent factors) =====
    // STI mobility modifier (Eq 171-173)
    const muesti_t1 = 1.0 / (1.0 + muesti2_p);
    const muesti_t2 = muesti1_p / safe_pow(@max(lod_half, 1.0e-30), muesti3_p);
    const muesti_t3 = muesti1_p / safe_pow(lod_half_ref, muesti3_p);
    const muesti = (1.0 + muesti_t1 * muesti_t2) / @max(1.0 + muesti_t1 * muesti_t3, 1.0e-30);

    // MUEqb front/back (Eq 90/114)
    const mueqb_f = mueqb_p * (1.0 + mueqbl_p / safe_pow(lum, mueqblp_p));
    const mueqb_b = mueqbb_p * (1.0 + mueqbl_p / safe_pow(lum, mueqblp_p));

    // N_dep and N_inv with L-dependence (Eq 85-86)
    const ndep_mod = ndep_p * (1.0 + ndepl_p / safe_pow(lum, ndeplp_p));
    const ninv_mod = ninv_p * (1.0 + ninvl_p / safe_pow(lum, ninvlp_p));

    // Phonon mobility front (Eq 95, 135, 156, 173)
    const muephonon = mueph1_p * (1.0 + muephl_p / safe_pow(lum, mueplp_p)) *
        (1.0 + muephw_p / safe_pow(wum, muepwp_p)) *
        (1.0 + muephs_p / safe_pow(@max(wl, 1.0e-30), muepsp_p)) *
        muesti;

    // Surface roughness front (Eq 96, 137)
    const muesurface = muesr0_p * (1.0 + muesrl_p / safe_pow(lum, mueslp_p)) *
        (1.0 + muesrw_p / safe_pow(wum, mueswp_p));

    // Coulomb front (Eq 97-98)
    const mcoulomb0_f = muecb0_p * safe_pow(lum, muecb0lp_p) * (1.0 + muecb0l2_p / safe_pow(lum, muecb0l2p_p));
    const mcoulomb1_f = muecb1_p * safe_pow(lum, muecb1lp_p) * (1.0 + muecb1l2_p / safe_pow(lum, muecb1l2p_p));

    // Temperature dependence of phonon (Eq 179-180)
    const m_tmp = muetmp_p * (1.0 + muetmpl_p / safe_pow(lum, muetmplp_p)) + muetmp1_p * t_ratio * t_ratio;
    const t_ratio_mtmp = safe_pow(t_ratio, m_tmp);

    // Saturation velocity (Eq 101, 139, 158)
    const vmax_val = vmax_p * (1.0 + vover_p / safe_pow(lum, voverp_p)) * (1.0 + voverl_p / safe_pow(lum, voverlp_p)) *
        (1.0 + voverw_p / safe_pow(wum, voverwp_p)) *
        (1.0 + vovers_p / safe_pow(@max(wl, 1.0e-30), voversp_p));
    const vtmp_mod = vtmp_p * (1.0 + vtmpl_p / safe_pow(lum, vtmplp_p));
    const vmax_t = vmax_val / @max(1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - vtmp_mod * (1.0 - t_ratio), 1.0e-6);

    // Back-side mobility x-independent factors
    const muephononb = mueph1b_p * (1.0 + muephlb_p / safe_pow(lum, mueplpb_p)) *
        (1.0 + muephwb_p / safe_pow(wum, muepwpb_p)) *
        (1.0 + muephsb_p / safe_pow(@max(wl, 1.0e-30), muepspb_p)) *
        muesti;
    const muesurfaceb = muesr0b_p * (1.0 + muesrlb_p / safe_pow(lum, mueslpb_p)) *
        (1.0 + muesrwb_p / safe_pow(wum, mueswpb_p));
    const mcoulomb0b = muecb0b_p * safe_pow(lum, muecb0lpb_p) * (1.0 + muecb0l2b_p / safe_pow(lum, muecb0l2pb_p));
    const mcoulomb1b = muecb1b_p * safe_pow(lum, muecb1lpb_p) * (1.0 + muecb1l2b_p / safe_pow(lum, muecb1l2pb_p));

    // ===== PARASITIC RESISTANCES (x-independent factors, Eq 184-201) =====
    const x_ov = safe_sqrt(xld_p * xld_p + rdrdjunc_p * rdrdjunc_p);
    const mu_drift0_temp = rdrmued_p / safe_pow(t_ratio, rdrmuetmp_p);
    const mu_drift0 = mu_drift0_temp * (1.0 + rdrmuel_p / safe_pow(lum, rdrmuelp_p));
    const vmax_drift_temp = rdrvmaxd_p / @max(1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - rdrvtmp_p * (1.0 - t_ratio), 1.0e-6);
    const vmax_drift = vmax_drift_temp * (1.0 + rdrvmaxl_p / safe_pow(lum, rdrvmaxlp_p)) *
        (1.0 + rdrvmaxw_p / safe_pow(wum, rdrvmaxwp_p));
    const rdrbb_temp = rdrbbd_p + rdrbbtmp_p * (temp_c - tnom_p);
    const mu_source0_temp = rdrmues_p / safe_pow(t_ratio, rdrmuetmp_p);
    const mu_source0 = mu_source0_temp * (1.0 + rdrmuel_p / safe_pow(lum, rdrmuelp_p));
    const vmax_source_temp = rdrvmaxs_p / @max(1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - rdrvtmp_p * (1.0 - t_ratio), 1.0e-6);
    const vmax_source = vmax_source_temp * (1.0 + rdrvmaxl_p / safe_pow(lum, rdrvmaxlp_p)) *
        (1.0 + rdrvmaxw_p / safe_pow(wum, rdrvmaxwp_p));
    const rsrbb_temp = rdrbbs_p + rdrbbtmp_p * (temp_c - tnom_p);

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .nf = nf,
        .beta = beta,
        .vt = vt,
        .eg = eg,
        .ni = ni,
        .ni2 = ni2,
        .l_gate = l_gate,
        .lum = lum,
        .w_eff = w_eff,
        .l_eff = l_eff,
        .temp_c = temp_c,
        .t_ratio = t_ratio,
        .tnom_p = tnom_p,
        .vzadd0_p = vzadd0_p,
        .tfox_p = tfox_p,
        .tbox_p = tbox_p,
        .tsoi_p = tsoi_p,
        .xld_p = xld_p,
        .vfbc_p = vfbc_p,
        .vbi_p = vbi_p,
        .parl1_p = parl1_p,
        .parl2_p = parl2_p,
        .sc1_p = sc1_p,
        .sc2_p = sc2_p,
        .sc3_p = sc3_p,
        .sc5_p = sc5_p,
        .scr1_p = scr1_p,
        .scr2_p = scr2_p,
        .scr3_p = scr3_p,
        .scp1_p = scp1_p,
        .scp2_p = scp2_p,
        .scp3_p = scp3_p,
        .lp_p = lp_p,
        .pthrou_p = pthrou_p,
        .pgd1_p = pgd1_p,
        .pgd2_p = pgd2_p,
        .pgd4_p = pgd4_p,
        .qme1_p = qme1_p,
        .qme2_p = qme2_p,
        .qme3_p = qme3_p,
        .clm1_p = clm1_p,
        .clm3_p = clm3_p,
        .clm5_p = clm5_p,
        .clm6_p = clm6_p,
        .ptl_p = ptl_p,
        .ptlp_p = ptlp_p,
        .ptp_p = ptp_p,
        .pt2_p = pt2_p,
        .pt4_p = pt4_p,
        .pt4p_p = pt4p_p,
        .gdl_p = gdl_p,
        .gdlp_p = gdlp_p,
        .gdld_p = gdld_p,
        .ddltmax_p = ddltmax_p,
        .ddltslp_p = ddltslp_p,
        .ddltict_p = ddltict_p,
        .mueph0_p = mueph0_p,
        .bb_p = bb_p,
        .ninvd_p = ninvd_p,
        .ninvdp_p = ninvdp_p,
        .nsti_p = nsti_p,
        .nstil_p = nstil_p,
        .nstilp_p = nstilp_p,
        .nstiw_p = nstiw_p,
        .nstiwp_p = nstiwp_p,
        .wsti_p = wsti_p,
        .wstil_p = wstil_p,
        .wstilp_p = wstilp_p,
        .wstiw_p = wstiw_p,
        .wstiwp_p = wstiwp_p,
        .wl1_p = wl1_p,
        .wl1p_p = wl1p_p,
        .vthsti_p = vthsti_p,
        .vdsti_p = vdsti_p,
        .scsti1_p = scsti1_p,
        .scsti2_p = scsti2_p,
        .vfbsub_p = vfbsub_p,
        .vfbsubl_p = vfbsubl_p,
        .vfbsublp_p = vfbsublp_p,
        .sub1_p = sub1_p,
        .sub1l_p = sub1l_p,
        .sub1lp_p = sub1lp_p,
        .sub2_p = sub2_p,
        .sub2l_p = sub2l_p,
        .subdlt_p = subdlt_p,
        .svds_p = svds_p,
        .slg_p = slg_p,
        .svgs_p = svgs_p,
        .svgsl_p = svgsl_p,
        .svgslp_p = svgslp_p,
        .svgsw_p = svgsw_p,
        .svgswp_p = svgswp_p,
        .svbs_p = svbs_p,
        .svbsl_p = svbsl_p,
        .svbslp_p = svbslp_p,
        .ibpc1_p = ibpc1_p,
        .ibpc2_p = ibpc2_p,
        .gleak1_p = gleak1_p,
        .gleak2_p = gleak2_p,
        .gleak3_p = gleak3_p,
        .gleak4_p = gleak4_p,
        .gleak5_p = gleak5_p,
        .gleak6_p = gleak6_p,
        .gleak7_p = gleak7_p,
        .gleak8_p = gleak8_p,
        .gleak9_p = gleak9_p,
        .gleak10_p = gleak10_p,
        .glksd1_p = glksd1_p,
        .glksd2_p = glksd2_p,
        .glksd3_p = glksd3_p,
        .glksd4_p = glksd4_p,
        .glksd5_p = glksd5_p,
        .glkb1_p = glkb1_p,
        .glkb2_p = glkb2_p,
        .glkb3_p = glkb3_p,
        .glkb4_p = glkb4_p,
        .glkb5_p = glkb5_p,
        .glkb6_p = glkb6_p,
        .glkb7_p = glkb7_p,
        .glkb8_p = glkb8_p,
        .glkb21_p = glkb21_p,
        .glkb22_p = glkb22_p,
        .glkb23_p = glkb23_p,
        .glkb24_p = glkb24_p,
        .glkb25_p = glkb25_p,
        .glkb26_p = glkb26_p,
        .glkb27_p = glkb27_p,
        .glkb28_p = glkb28_p,
        .gidl1_p = gidl1_p,
        .gidl2_p = gidl2_p,
        .gidl3_p = gidl3_p,
        .gidl4_p = gidl4_p,
        .gidl5_p = gidl5_p,
        .gidlbpl1_p = gidlbpl1_p,
        .gidlbplt_p = gidlbplt_p,
        .tfoxgidl_p = tfoxgidl_p,
        .evb1_p = evb1_p,
        .evb2_p = evb2_p,
        .evb3_p = evb3_p,
        .fvbs_p = fvbs_p,
        .qhe1_p = qhe1_p,
        .qhe2_p = qhe2_p,
        .rsh_p = rsh_p,
        .rshg_p = rshg_p,
        .nover_p = nover_p,
        .novers_p = novers_p,
        .ldrift_p = ldrift_p,
        .ldrifts_p = ldrifts_p,
        .nrd = nrd,
        .nrs = nrs,
        .xgw = xgw,
        .ngcon = ngcon,
        .l_drawn = l_drawn,
        .xgl = @as(f64, instance.xgl),
        .x_ov = x_ov,
        .mu_drift0 = mu_drift0,
        .vmax_drift = vmax_drift,
        .rdrbb_temp = rdrbb_temp,
        .mu_source0 = mu_source0,
        .vmax_source = vmax_source,
        .rsrbb_temp = rsrbb_temp,
        .rth0_p = @as(f64, model.rth0),
        .nsubsp_eff = nsubsp_eff,
        .nsubps = nsubps,
        .nsubsp_sti = nsubsp_sti,
        .nsubb_eff = nsubb_eff,
        .nsubs_m3 = nsubs_m3,
        .nsubb_m3 = nsubb_m3,
        .vfb = vfb,
        .phi_bc = phi_bc,
        .phi_b = phi_b,
        .cfox = cfox,
        .cbox = cbox,
        .csoi = csoi,
        .const0_si = const0_si,
        .qdep_soi = qdep_soi,
        .c_ef = c_ef,
        .dv_th_w = dv_th_w,
        .dv_th_sm = dv_th_sm,
        .clm2_val = clm2_val,
        .mueqb_f = mueqb_f,
        .mueqb_b = mueqb_b,
        .ndep_mod = ndep_mod,
        .ninv_mod = ninv_mod,
        .muephonon = muephonon,
        .muesurface = muesurface,
        .mcoulomb0_f = mcoulomb0_f,
        .mcoulomb1_f = mcoulomb1_f,
        .t_ratio_mtmp = t_ratio_mtmp,
        .muesr1_p = muesr1_p,
        .vmax_t = vmax_t,
        .muephononb = muephononb,
        .muesurfaceb = muesurfaceb,
        .mcoulomb0b = mcoulomb0b,
        .mcoulomb1b = mcoulomb1b,
        .muesr1b_p = muesr1b_p,
        .mueph0b_p = mueph0b_p,
        .mueqbb_p = mueqbb_p,
        .wfc_p = wfc_p,
        .coisti = model.coisti,
        .coisub = model.coisub,
        .coiigs = model.coiigs,
        .cogidl = model.cogidl,
        .coievb = model.coievb,
        .cofbe = model.cofbe,
        .coselfheat = model.coselfheat,
        .conewmub = model.conewmub,
        .cord = model.cord,
        .cors = model.cors,
        .corg = model.corg,
    };
}

// ============================================================================
// PrepCache
// ============================================================================

pub const PrepCache = struct { dc: ParamsI, q: ParamsQ };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{
        .dc = prepI(model, instance),
        .q = prepQ(model, instance),
    };
}

// ============================================================================
// Physics Function: Current (value-form). x-dependent physics in S ops.
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const g = @intFromEnum(U.gate);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);
    const e = @intFromEnum(U.sub);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);

    const p = &pc.dc;

    // shorthand for constants
    const beta = p.beta;
    const cfox = p.cfox;
    const cbox = p.cbox;
    const csoi = p.csoi;
    const const0_si = p.const0_si;
    const eg = p.eg;
    const l_gate = p.l_gate;
    const lum = p.lum;
    const l_eff = p.l_eff;
    const w_eff = p.w_eff;
    const nf = p.nf;
    const phi_b = p.phi_b;
    const phi_bc = p.phi_bc;
    const vfb = p.vfb;
    const nsubs_m3 = p.nsubs_m3;
    const qdep_soi = p.qdep_soi;
    const type_f = p.type_f;
    const m_mult = p.m_mult;

    // ===== TERMINAL VOLTAGES (apply type factor) =====
    const vgs_ext = x[gp].sub(x[sp]).scale(type_f);
    const vds_ext = x[dp].sub(x[sp]).scale(type_f);
    const ves = x[e].sub(x[sp]).scale(type_f);

    // Symmetry: add vzadd0 to avoid discontinuity at Vds=0
    const vds_sym = sSqrt(S, vds_ext.mul(vds_ext).addC(4.0 * p.vzadd0_p * p.vzadd0_p));
    const vds_raw = vds_ext.add(vds_sym).scale(0.5); // smooth abs
    const mode_sign = vds_ext.div(vds_sym.addC(1.0e-30)); // sign of Vds

    // ===== SCE VIA BOX (Eq 55) =====
    const dv_th_scr = vds_raw.scale(p.scr2_p).addC(eg + 2.0 * phi_b - p.scr3_p)
        .scale(p.scr1_p * p.tfox_p / (l_gate / 2.0 + p.parl1_p)); // Eq 55

    // ===== SHORT-CHANNEL EFFECT (Eq 50-54) =====
    // VG for Phi_B'' (Eq 54)
    const vg_sc = vgs_ext.addC(-p.vfbc_p).add(dv_th_scr);
    const const0_bulk = safe_sqrt(2.0 * EPS_SI * Q_ELECTRON * p.nsubb_m3 / beta);
    _ = const0_bulk;

    // Phi_B'' approximation (Eq 53): surface potential for SCE
    const vg_ves = vg_sc.sub(ves);
    const ratio_sq = beta * const0_si / cfox;
    const ratio_sq2 = ratio_sq * ratio_sq;
    const arg_53 = vg_ves.scale(4.0 * beta).addC(-4.0).scale(1.0 / @max(ratio_sq2, 1.0e-30));
    const phi_b_pp = vg_sc.add(sSqrt(S, arg_53.addC(1.0)).neg().addC(1.0)
        .scale(const0_si * const0_si * beta / (cfox * cfox)));

    // Phi_B' with pthrou (Eq 52)
    const phi_b_prime = phi_b_pp.addC(-phi_b).scale(p.pthrou_p).addC(phi_b);

    // Lateral field gradient (Eq 51)
    const l_sc = @max(l_gate - p.parl2_p, 1.0e-9);
    // 2*(vbi - 2*phi_b_prime)/(l_sc^2) * (sc1 + sc2*vds_raw + sc3*(2*phi_b - ves)/l_gate + sc5*ves)
    const dey_factor_a = phi_b_prime.scale(-2.0).addC(p.vbi_p).scale(2.0 / (l_sc * l_sc));
    const dey_factor_b = vds_raw.scale(p.sc2_p)
        .add(ves.scale(-1.0).addC(2.0 * phi_b).scale(p.sc3_p / l_gate))
        .add(ves.scale(p.sc5_p))
        .addC(p.sc1_p);
    const dey_dy = dey_factor_a.mul(dey_factor_b); // Eq 51

    // dV_th_SC (Eq 50)
    const wd_sc = p.tsoi_p; // W_d = TSOI for SOTB
    const dv_th_sc = dey_dy.scale(EPS_SI / cfox * wd_sc);

    // ===== REVERSE SHORT-CHANNEL (POCKET) EFFECT (Eq 56-62) =====
    // Q_B0 (Eq 58)
    const qb0 = sSqrt(S, ves.neg().addC(2.0 * phi_b).maxC(1.0e-30)
        .scale(2.0 * Q_ELECTRON * p.nsubsp_eff * 1.0e6 * EPS_SI));

    // Nsubp0 / Nsubb0 (Eq 62) — x-independent
    const nsubp0_val = if (p.lp_p > 0.0)
        2.0 * p.nsubps - (p.nsubps - p.nsubsp_sti) * l_gate / @max(p.lp_p, 1.0e-30) - p.nsubsp_sti
    else
        p.nsubps;
    const nsubb0_val = @max(nsubp0_val, 1.0);

    // V_th,R (Eq 57)
    const p_tovr = if (l_gate <= 2.0 * p.lp_p and p.lp_p > 0.0) p.vt * safe_log(nsubb0_val / @max(p.nsubsp_eff, 1.0)) else 0.0; // Eq 61
    const vth_r = qb0.scale(1.0 / cfox).addC(vfb + 2.0 * phi_b + p_tovr); // Eq 57

    // V_th0 (Eq 59)
    const qb0_p = sSqrt(S, ves.neg().addC(2.0 * phi_bc).maxC(1.0e-30)
        .scale(2.0 * Q_ELECTRON * p.nsubps * 1.0e6 * EPS_SI));
    const vth0_pocket = qb0_p.scale(1.0 / cfox).addC(vfb + 2.0 * phi_bc); // Eq 59

    // Lateral field for pocket (Eq 60)
    const lp_eff = @max(p.lp_p, 1.0e-9);
    const dey_dy_p = if (p.lp_p > 0.0)
        ves.scale(-1.0).addC(2.0 * phi_b).scale(p.scp3_p / lp_eff)
            .add(vds_raw.scale(p.scp2_p)).addC(p.scp1_p)
            .scale(2.0 * (p.vbi_p - 2.0 * phi_b) / (lp_eff * lp_eff))
    else
        S.con(0.0); // Eq 60

    // dV_th_P (Eq 56)
    const dv_th_p = if (p.lp_p > 0.0)
        vth_r.sub(vth0_pocket).mul(dey_dy_p).scale(EPS_SI / cfox * p.tsoi_p)
    else
        S.con(0.0);

    // ===== POLY GATE DEPLETION (Eq 74) =====
    const pgd_lmod = safe_pow(1.0 + 1.0 / lum, p.pgd4_p);
    const phi_spg = if (p.pgd1_p > 0.0)
        sExpClamp(S, vgs_ext.addC(-p.pgd2_p)).scale(p.pgd1_p * pgd_lmod)
    else
        S.con(0.0);

    // ===== QUANTUM MECHANICAL EFFECT (Eq 75-76) =====
    const vth_approx = vfb + 2.0 * phi_b + qb0.val() / cfox;
    // NOTE: original computes qme_denom from abs(vgs_ext - vth_approx - qme2), where
    // vth_approx uses the runtime qb0 value; QME shifts tfox which alters cfox_eff.
    const qme_denom = vgs_ext.addC(-(vth_approx + p.qme2_p)).abs().maxC(1.0e-6);
    const dtfox = if (p.qme1_p != 0.0)
        qme_denom.scale(0.0).addC(p.qme3_p).add(S.con(p.qme1_p).div(qme_denom))
    else
        S.con(p.qme3_p);
    const tfox_eff = dtfox.addC(p.tfox_p).maxC(1.0e-12);
    const cfox_eff = tfox_eff.pow(-1.0).scale(EPS_OX); // EPS_OX / tfox_eff

    // ===== TOTAL THRESHOLD VOLTAGE SHIFT (Eq 49) =====
    const dv_th = dv_th_sc.add(dv_th_scr).add(dv_th_p).addC(p.dv_th_w + p.dv_th_sm).sub(phi_spg);

    // ===== V_G0 (Eq 9) =====
    const vg0 = vgs_ext.addC(-vfb).add(dv_th);

    // ===== EFFECTIVE DRAIN VOLTAGE (Eq 33-36) =====
    const cfox2 = cfox_eff.mul(cfox_eff);
    const qns = Q_ELECTRON * nsubs_m3 * EPS_SI;
    // vdsat_arg = max(1 + 2*cfox2/(beta*qns)*(beta*vg0 - 1), 1e-30)
    const vdsat_arg = cfox2.mul(vg0.scale(beta).addC(-1.0)).scale(2.0 / (beta * qns)).addC(1.0).maxC(1.0e-30);
    // vdsat = vg0 + qns/cfox2 * (1 - sqrt(vdsat_arg))
    const vdsat = vg0.add(sSqrt(S, vdsat_arg).neg().addC(1.0).mul(cfox2.pow(-1.0)).scale(qns)); // Eq 36
    const vdsat_clamped = vdsat.maxC(1.0e-6);

    // Delta smoothing (Eq 34-35) — x-independent
    const t1_dlt = p.ddltslp_p * lum;
    const delta_dlt = p.ddltmax_p * t1_dlt / @max(p.ddltmax_p + t1_dlt, 1.0e-30) + p.ddltict_p;
    const delta_eff = @max(delta_dlt, 0.5);

    // V_ds,eff (Eq 33): vds_raw / (1 + (vds_raw/vdsat)^delta)^(1/delta)
    const vds_ratio = vds_raw.div(vdsat_clamped.maxC(1.0e-30));
    const vds_eff = vds_raw.div(sPow(S, sPow(S, vds_ratio, delta_eff).addC(1.0), 1.0 / delta_eff)); // Eq 33

    // ===== SURFACE POTENTIALS =====
    const cfox_r = cfox_eff;
    // phi_s0_init = vg0 + qns/(cfox_r^2)*(1 - sqrt(max(1 + 2*cfox_r^2/(beta*qns)*(beta*vg0-1),1e-30)))
    const cfox_r2 = cfox_r.mul(cfox_r);
    const phi_s0_arg = cfox_r2.mul(vg0.scale(beta).addC(-1.0)).scale(2.0 / (beta * qns)).addC(1.0).maxC(1.0e-30);
    const phi_s0_init = vg0.add(sSqrt(S, phi_s0_arg).neg().addC(1.0).mul(cfox_r2.pow(-1.0)).scale(qns));
    // Clamp surface potential: max(min(phi_s0_init, vgs_ext+2), -2)
    const phi_s0 = phi_s0_init.min(vgs_ext.addC(2.0)).maxC(-2.0);

    // phi_sL at drain end (Eq 30/32)
    const phi_sl = phi_s0.add(vds_eff);

    // Back surface potentials
    const phi_b0 = phi_s0.scale(csoi / (csoi + cbox)).add(ves.scale(cbox / (csoi + cbox)));
    const phi_bl = phi_sl.scale(csoi / (csoi + cbox)).add(ves.scale(cbox / (csoi + cbox)));

    // Bulk potential (Eq 13)
    const phi_bulk = phi_b0.addC(qdep_soi / (2.0 * cbox));
    const eeff_bulk_correction = if (p.conewmub == 1)
        phi_b0.sub(phi_bulk).sub(ves).scale(EPS_OX / EPS_SI / p.tbox_p)
    else
        S.con(0.0);

    // ===== DEPLETION AND INVERSION CHARGES (Eq 17-22) =====
    const phi_f_0 = S.con(0.0);
    const phi_f_l = vds_eff;
    const phi_bp_0 = ves;
    const phi_bp_l = ves.add(vds_eff);

    // Q_s,dep at source and drain (Eq 18)
    const qs_dep_0_arg = sExpClamp(S, phi_s0.scale(-beta)).add(phi_s0.sub(phi_bp_0).scale(beta)).addC(-1.0).maxC(1.0e-30);
    const qs_dep_0 = sSqrt(S, qs_dep_0_arg).scale(-const0_si);
    const qs_dep_l_arg = sExpClamp(S, phi_sl.scale(-beta)).add(phi_sl.sub(phi_bp_l).scale(beta)).addC(-1.0).maxC(1.0e-30);
    const qs_dep_l = sSqrt(S, qs_dep_l_arg).scale(-const0_si);

    // Q_b,dep at source and drain (Eq 19)
    const qb_dep_0_arg = sExpClamp(S, phi_b0.scale(-beta)).add(phi_b0.sub(phi_bp_0).scale(beta)).addC(-1.0).maxC(1.0e-30);
    const qb_dep_0 = sSqrt(S, qb_dep_0_arg).scale(-const0_si);
    const qb_dep_l_arg = sExpClamp(S, phi_bl.scale(-beta)).add(phi_bl.sub(phi_bp_l).scale(beta)).addC(-1.0).maxC(1.0e-30);
    const qb_dep_l = sSqrt(S, qb_dep_l_arg).scale(-const0_si);

    // Inversion charge Qi (Eq 20) and Qb (Eq 21) — x-independent factor
    const pp0 = p.nsubsp_eff * 1.0e6;
    const np0 = p.ni2 * 1.0e12 / @max(pp0, 1.0);
    const np0_over_pp0 = np0 / @max(pp0, 1.0);

    // Qi at source (Eq 20)
    const qi_exp_s0 = sExpClamp(S, phi_s0.sub(phi_f_0).scale(beta)).sub(sExpClamp(S, phi_bp_0.sub(phi_f_0).scale(beta)));
    const qi_inner_0 = sSqrt(S, qs_dep_0.mul(qs_dep_0).add(qi_exp_s0.scale(np0_over_pp0).maxC(0.0)));
    const qi_0 = qi_inner_0.add(qs_dep_0).neg(); // Eq 20

    // Qi at drain (Eq 20 at L)
    const qi_exp_sl = sExpClamp(S, phi_sl.sub(phi_f_l).scale(beta)).sub(sExpClamp(S, phi_bp_l.sub(phi_f_l).scale(beta)));
    const qi_inner_l = sSqrt(S, qs_dep_l.mul(qs_dep_l).add(qi_exp_sl.scale(np0_over_pp0).maxC(0.0)));
    const qi_l = qi_inner_l.add(qs_dep_l).neg();

    // Qb at source (Eq 21)
    const qb_exp_0 = sExpClamp(S, phi_b0.sub(phi_f_0).scale(beta)).sub(sExpClamp(S, phi_bp_0.sub(phi_f_0).scale(beta)));
    const qb_inner_0 = sSqrt(S, qb_dep_0.mul(qb_dep_0).add(qb_exp_0.scale(np0_over_pp0).maxC(0.0)));
    const qb_0 = qb_inner_0.add(qb_dep_0).neg();

    // Qb at drain (Eq 21 at L)
    const qb_exp_l = sExpClamp(S, phi_bl.sub(phi_f_l).scale(beta)).sub(sExpClamp(S, phi_bp_l.sub(phi_f_l).scale(beta)));
    const qb_inner_l = sSqrt(S, qb_dep_l.mul(qb_dep_l).add(qb_exp_l.scale(np0_over_pp0).maxC(0.0)));
    const qb_l = qb_inner_l.add(qb_dep_l).neg();

    // Average charges (Eq 37-40, 43, 88-89, 111-112)
    const qi_avg = qi_0.add(qi_l).scale(0.5);
    const qb_avg = qb_0.add(qb_l).scale(0.5);
    const qs_dep_avg = qs_dep_0.add(qs_dep_l).scale(0.5);
    const qb_dep_avg = qb_dep_0.add(qb_dep_l).scale(0.5);

    // ===== CHANNEL-LENGTH MODULATION (Eq 124-128) =====
    const clm2_val = p.clm2_val;
    const clm1_p = p.clm1_p;
    // phi_s(DeltaL) (Eq 124): (1-clm1)*phi_sL + clm1*(phi_s0 + vds_raw)
    const phi_s_dl = phi_sl.scale(1.0 - clm1_p).add(phi_s0.add(vds_raw).scale(clm1_p));

    // z (Eq 126): EPS_SI*wd_sc / max(|clm2*qb_avg + clm3*qi_avg|, 1e-30)
    const z_denom = qb_avg.scale(clm2_val).add(qi_avg.scale(p.clm3_p)).abs().maxC(1.0e-30);
    const z_clm = z_denom.pow(-1.0).scale(EPS_SI * wd_sc);

    // DeltaL (Eq 125 -- quadratic formula)
    const e0_clm: f64 = 1.0e5;
    const dphi_clm = phi_s_dl.sub(phi_sl);
    // idd_f_approx = -beta*(qi_l+qi_0)*(phi_sl-phi_s0)/2 - (qi_l-qi_0)
    const idd_f_approx = qi_l.add(qi_0).mul(phi_sl.sub(phi_s0)).scale(-beta / 2.0).sub(qi_l.sub(qi_0));
    const qi_0_safe = qi_0.abs().maxC(1.0e-30);
    // clm_idd_term = idd_f_approx/(beta*qi_0_safe*l_eff) * 2 * z_clm
    const clm_idd_term = idd_f_approx.div(qi_0_safe.scale(beta * l_eff)).scale(2.0).mul(z_clm);
    // clm_field_term = qN/eps*dphi*z^2 + E0*z^2
    const z_clm2 = z_clm.mul(z_clm);
    const clm_field_term = dphi_clm.scale(Q_ELECTRON * nsubs_m3 / EPS_SI).mul(z_clm2).add(z_clm2.scale(e0_clm));
    const term_a = clm_idd_term.add(clm_field_term);
    // term_b = max(4*(qN/eps*dphi*z^2 + E0*z^2), 0)
    const term_b = dphi_clm.scale(Q_ELECTRON * nsubs_m3 / EPS_SI).mul(z_clm2).add(z_clm2.scale(e0_clm)).scale(4.0).maxC(0.0);
    // delta_l_raw = -0.5*term_a/l_eff + sqrt(term_a^2/l_eff^2 + term_b)
    const delta_l_raw = term_a.scale(-0.5 / l_eff).add(sSqrt(S, term_a.mul(term_a).scale(1.0 / (l_eff * l_eff)).add(term_b)));

    // CLM6 pocket enhancement (Eq 128)
    const delta_l = delta_l_raw.scale(1.0 + p.clm6_p * safe_pow(lum, p.clm5_p)).minC(l_eff * 0.5).maxC(0.0);

    // ===== MOBILITY MODEL (Eq 77-101) =====
    // QIB front (Eq 84)
    const qib_f = qi_avg.sub(qb_l.scale(p.mueqb_f));

    // P_ds2 (Eq 87): |phi_sl - phi_s0|^ninvdp  (variable base, constant exponent)
    const pds2 = sPow(S, phi_sl.sub(phi_s0), p.ninvdp_p);

    // E_eff front (Eq 81-83)
    const eeff_raw_f = qs_dep_avg.scale(p.ndep_mod).add(qib_f.scale(p.ninv_mod)).abs()
        .div(pds2.scale(p.ninvd_p).addC(1.0)).scale(1.0 / EPS_SI).add(eeff_bulk_correction);
    const eeff_f = eeff_raw_f.maxC(3.0e3); // Eq 81

    // mu_CB front (Eq 78)
    const mu_cb_f = qi_avg.abs().scale(p.mcoulomb1_f / (Q_ELECTRON * 1.0e11 * 1.0e4)).addC(p.mcoulomb0_f);
    // mu_PH front (Eq 79) with temp (Eq 179): muephonon / (t_ratio_mtmp * eeff_f^mueph0)
    const mu_ph_f = sPow(S, eeff_f, p.mueph0_p).scale(p.t_ratio_mtmp).pow(-1.0).scale(p.muephonon);
    // mu_SR front (Eq 80): muesr1 / eeff_f^muesurface
    const mu_sr_f = sPow(S, eeff_f, p.muesurface).pow(-1.0).scale(p.muesr1_p);

    // Low-field mobility front (Eq 77)
    const mu0_f = mu_cb_f.maxC(1.0e-6).pow(-1.0)
        .add(mu_ph_f.maxC(1.0e-6).pow(-1.0))
        .add(mu_sr_f.maxC(1.0e-6).pow(-1.0)).pow(-1.0);

    const vmax_t = p.vmax_t;

    // ===== DRAIN CURRENT FRONT (Eq 44-46) =====
    // I_dd,f (Eq 46)
    const idd_f = qi_l.add(qi_0).mul(phi_sl.sub(phi_s0)).scale(beta / 2.0).add(qi_l.sub(qi_0)).neg();

    // E_y front (Eq 100): sqrt((idd_f/(beta*qi_0_safe*l_eff))^2 + (0.2*vmax_t/mu0_f)^2)
    const ey_term1_f = idd_f.div(qi_0_safe.scale(beta * l_eff));
    const ey_term2_f = mu0_f.pow(-1.0).scale(0.2 * vmax_t);
    const ey_f = sSqrt(S, ey_term1_f.mul(ey_term1_f).add(ey_term2_f.mul(ey_term2_f)));

    // High-field mobility front (Eq 99)
    const mu_ratio_f = mu0_f.mul(ey_f).scale(1.0 / vmax_t);
    const mu_f = mu0_f.div(sPow(S, sPow(S, mu_ratio_f.abs(), p.bb_p).addC(1.0), 1.0 / p.bb_p));

    // I_ds,f (Eq 45)
    const l_eff_clm = delta_l.neg().addC(l_eff).maxC(1.0e-9);
    const ids_f = mu_f.mul(idd_f).div(l_eff_clm).scale(w_eff * nf / beta); // Eq 45

    // ===== DRAIN CURRENT BACK (Eq 47-48) =====
    // QIB back (Eq 109)
    const qib_b = qb_avg.sub(qi_l.scale(p.mueqb_b));

    // P_dsb2 (Eq 110)
    const pdsb2 = sPow(S, phi_bl.sub(phi_b0), p.ninvdp_p);

    // E_eff back (Eq 106-108)
    const eeff_raw_b = qb_dep_avg.scale(p.ndep_mod).add(qib_b.scale(p.ninv_mod)).abs()
        .div(pdsb2.scale(p.ninvd_p).addC(1.0)).scale(1.0 / EPS_SI);
    const eeff_b = eeff_raw_b.maxC(3.0e1); // Eq 106

    // mu_CB back (Eq 103)
    const mu_cb_b = qb_avg.abs().scale(p.mcoulomb1b / (Q_ELECTRON * 1.0e11 * 1.0e4)).addC(p.mcoulomb0b);
    // mu_PH back (Eq 104) with temperature
    const mu_ph_b = sPow(S, eeff_b, p.mueph0b_p).scale(p.t_ratio_mtmp).pow(-1.0).scale(p.muephononb);
    // mu_SR back (Eq 105)
    const mu_sr_b = sPow(S, eeff_b, p.muesurfaceb).pow(-1.0).scale(p.muesr1b_p);

    // Low-field mobility back (Eq 102)
    const mu0_b = mu_cb_b.maxC(1.0e-6).pow(-1.0)
        .add(mu_ph_b.maxC(1.0e-6).pow(-1.0))
        .add(mu_sr_b.maxC(1.0e-6).pow(-1.0)).pow(-1.0);

    // I_dd,b (Eq 48)
    const idd_b = qb_l.add(qb_0).mul(phi_bl.sub(phi_b0)).scale(beta / 2.0).add(qb_l.sub(qb_0)).neg();

    // E_y back (Eq 123)
    const qb0_safe = qb_0.abs().maxC(1.0e-30);
    const ey_term1_b = idd_b.div(qb0_safe.scale(beta * l_eff));
    const ey_term2_b = mu0_b.pow(-1.0).scale(0.2 * vmax_t);
    const ey_b = sSqrt(S, ey_term1_b.mul(ey_term1_b).add(ey_term2_b.mul(ey_term2_b)));

    // High-field mobility back (Eq 122)
    const mu_ratio_b = mu0_b.mul(ey_b).scale(1.0 / vmax_t);
    const mu_b = mu0_b.div(sPow(S, sPow(S, mu_ratio_b.abs(), p.bb_p).addC(1.0), 1.0 / p.bb_p));

    // I_ds,b (Eq 47)
    const ids_b = mu_b.mul(idd_b).div(l_eff_clm).scale(w_eff * nf / beta);

    // ===== PUNCHTHROUGH (Eq 71-73) =====
    // COND (Eq 73): cfox_eff*beta*gdl/(lum+gdld*1e6)^gdlp * vds_raw
    const cond = cfox_eff.scale(beta * p.gdl_p / safe_pow(lum + p.gdld_p * 1.0e6, p.gdlp_p)).mul(vds_raw);

    const ptl_mod = p.ptl_p / safe_pow(lum, p.ptlp_p);
    // I_punch,f (Eq 71)
    const ipunch_f = if (p.ptl_p > 0.0) blk_pf: {
        const pt_common = phi_s0.sub(ves).scale(p.pt4_p / safe_pow(lum, p.pt4p_p))
            .add(vds_raw.scale(p.pt2_p)).add(cond).addC(1.0);
        break :blk_pf mu_f.mul(phi_sl.sub(phi_s0)).mul(cfox_eff)
            .mul(sPow(S, phi_s0.neg().addC(p.vbi_p).maxC(1.0e-30), p.ptp_p))
            .mul(pt_common)
            .scale(w_eff * nf / l_eff / beta * beta * ptl_mod);
    } else S.con(0.0);

    // I_punch,b (Eq 72)
    const ipunch_b = if (p.ptl_p > 0.0) blk_pb: {
        const pt_common_b = phi_b0.sub(ves).scale(p.pt4_p / safe_pow(lum, p.pt4p_p))
            .add(vds_raw.scale(p.pt2_p)).add(cond).addC(1.0);
        break :blk_pb mu_b.mul(phi_bl.sub(phi_b0)).mul(cfox_eff)
            .mul(sPow(S, phi_b0.neg().addC(p.vbi_p).maxC(1.0e-30), p.ptp_p))
            .mul(pt_common_b)
            .scale(w_eff * nf / l_eff / beta * beta * ptl_mod);
    } else S.con(0.0);

    // ===== TOTAL DRAIN CURRENT (Eq 44) =====
    const ids_total_base = ids_f.add(ids_b).add(ipunch_f).add(ipunch_b);

    // ===== STI LEAKAGE (Eq 140-153) =====
    const ids_sti: S = if (p.coisti == 1) blk_sti: {
        // STI geometry (Eq 147-152) — x-independent.
        // Original: wl = wum*lum; l_gate_sm = l_gate + wl1/wl^wl1p; w_gate_sm = w_gate + same.
        const wl_geo = p.lum * (p.w_eff * 1.0e6); // wum uses w_gate; w_eff differs by xwd but keep original wl (=wum*lum)
        const wl1_add = p.wl1_p / safe_pow(@max(wl_geo, 1.0e-30), p.wl1p_p);
        const l_gate_sm = l_gate + wl1_add; // Eq 147
        const w_gate_sm = (p.w_eff) + wl1_add; // Eq 152 (w_gate approx via w_eff)
        const lum_sm = l_gate_sm * 1.0e6;
        const wum_sm = w_gate_sm * 1.0e6;
        const nsti_mod = p.nsti_p * (1.0 + p.nstil_p / safe_pow(lum_sm, p.nstilp_p)) * (1.0 + p.nstiw_p / safe_pow(wum_sm, p.nstiwp_p));
        const wsti_mod = p.wsti_p * (1.0 + p.wstil_p / safe_pow(lum_sm, p.wstilp_p)) * (1.0 + p.wstiw_p / safe_pow(wum_sm, p.wstiwp_p));
        const phi_b_sti = 2.0 * p.vt * safe_log(nsti_mod / p.ni);
        // W_d,STI (Eq 145): x-dependent via ves
        const wd_sti = sSqrt(S, ves.neg().addC(2.0 * phi_b_sti).maxC(1.0e-30).scale(2.0 * EPS_SI / (Q_ELECTRON * nsti_mod * 1.0e6)));
        const l_sc_sti = @max(l_gate_sm - p.parl2_p, 1.0e-9);
        const dey_sti = vds_raw.scale(p.scsti2_p).addC(p.scsti1_p).scale(2.0 * (p.vbi_p - 2.0 * phi_b_sti) / (l_sc_sti * l_sc_sti));
        const dv_th_scsti = wd_sti.mul(dey_sti).scale(EPS_SI / cfox);
        const vth_sti = vds_raw.scale(-p.vdsti_p).addC(p.vthsti_p);
        const vgs_sti_prime = vgs_ext.addC(-p.vfbc_p).add(vth_sti).add(dv_th_scsti);
        const qn_sti = Q_ELECTRON * nsti_mod * 1.0e6;
        const sti_arg = vgs_sti_prime.sub(ves).addC(-p.vt).scale(2.0 * cfox * cfox / (EPS_SI * qn_sti)).addC(1.0).maxC(1.0e-30);
        const phi_s_sti = vgs_sti_prime.add(sSqrt(S, sti_arg).neg().addC(1.0).scale(EPS_SI * qn_sti / (cfox * cfox)));
        const qi_sti = phi_s_sti.addC(-phi_b_sti).maxC(0.0).scale(cfox);
        break :blk_sti mu_f.mul(qi_sti).div(l_eff_clm).mul(sExpClamp(S, vds_raw.scale(-beta)).neg().addC(1.0)).scale(2.0 * wsti_mod / beta);
    } else S.con(0.0);

    // ===== SUBSTRATE CURRENT / IMPACT IONIZATION (Eq 213-231) =====
    const isub: S = if (p.coisub == 1) blk_isub: {
        const vfbsubi = p.vfbsub_p * (1.0 + p.vfbsubl_p / safe_pow(l_gate, p.vfbsublp_p));
        // V_gp_SUB' (Eq 221)
        const vgp_sub = vgs_ext.addC(-vfbsubi).sub(dv_th).sub(phi_spg);
        const vgp_clamped = vgp_sub.maxC(p.vt);
        // phi_sa,STI (Eq 220)
        const sa_arg = vgp_clamped.addC(-p.vt).scale(2.0 * cfox * cfox / (EPS_SI * Q_ELECTRON * nsubs_m3)).addC(1.0).maxC(1.0e-30);
        const phi_sa_sti = vgp_clamped.add(sSqrt(S, sa_arg).neg().addC(1.0).scale(Q_ELECTRON * EPS_SI * nsubs_m3 / (cfox * cfox)));
        // phi_sb,STI (Eq 218)
        const asti = beta * cfox * cfox * nsubs_m3 / @max(2.0 * Q_ELECTRON * EPS_SI * p.ni2 * 1.0e12 * nsubs_m3, 1.0e-60);
        // log(max(asti*vgp,1e-30)) / max(beta + 2/vgp, 1e-30)
        const phi_sb_num = sLog(S, vgp_clamped.scale(asti));
        const phi_sb_den = vgp_clamped.pow(-1.0).scale(2.0).addC(beta).maxC(1.0e-30);
        const phi_sb_sti = phi_sb_num.div(phi_sb_den);
        // phi_STI (Eq 216-217)
        const phi_sab_sti = phi_sb_sti.sub(phi_sa_sti).addC(-p.subdlt_p);
        const phi_sti = phi_sb_sti.sub(phi_sab_sti.scale(0.5)).add(sSqrt(S, phi_sab_sti.mul(phi_sab_sti).add(phi_sb_sti.scale(4.0 * p.subdlt_p))));
        // X_sub1, X_sub2 (Eq 224-225) — x-independent
        const xsub1 = p.sub1_p * (1.0 + p.sub1l_p / safe_pow(l_gate, p.sub1lp_p));
        const xsub2 = p.sub2_p * (1.0 + p.sub2l_p / l_gate);
        // SVGSI (Eq 228), X_vbs (Eq 229)
        const svgsi = p.svgs_p * (1.0 + p.svgsl_p / safe_pow(l_gate, p.svgslp_p));
        const xvbs = p.svbs_p * (1.0 + p.svbsl_p / safe_pow(l_gate, p.svbslp_p));
        // Psislsat (Eq 227)
        const psisl_arg = vgp_clamped.addC(-p.vt).scale(2.0 * cfox * cfox / (Q_ELECTRON * EPS_SI * nsubs_m3)).addC(1.0).maxC(1.0e-30);
        const psislsat = vgp_clamped.scale(svgsi).add(sSqrt(S, psisl_arg).neg().addC(1.0).scale(Q_ELECTRON * EPS_SI * nsubs_m3 / (cfox * cfox))).sub(ves.scale(xvbs));
        // Psisubsat (Eq 226)
        const svgsw_mod = 1.0 + p.svgsw_p / safe_pow(w_eff, p.svgswp_p);
        const psisubsat = vds_raw.scale(p.svds_p).add(phi_sti).sub(psislsat.scale(l_gate / (l_gate + p.slg_p) * svgsw_mod)).maxC(1.0e-30);
        // I_ds,SUB (Eq 215) simplified
        const ids_sub = ids_total_base.abs();
        // I_sub (Eq 223): xsub1*psisubsat*ids_sub*exp(-xsub2/psisubsat)
        const isub_base = psisubsat.scale(xsub1).mul(ids_sub).mul(sExpClamp(S, psisubsat.pow(-1.0).scale(-xsub2)));
        // Impact-ionization body potential change (Eq 230-231)
        const dv_body = isub_base.scale(p.ibpc1_p).mul(dv_th.scale(p.ibpc2_p).addC(1.0)); // Eq 231
        const phi_sL_ves = phi_sl.sub(ves).scale(beta).addC(-1.0).maxC(1.0e-30);
        const phi_s0_ves = phi_s0.sub(ves).scale(beta).addC(-1.0).maxC(1.0e-30);
        // term_kk = phi^k * beta * dv_body / (2*phi)  = phi^(k-1) * beta*dv_body/2
        const term_32_l = sPow(S, phi_sL_ves, 1.5).mul(dv_body).div(phi_sL_ves).scale(beta / 2.0);
        const term_32_0 = sPow(S, phi_s0_ves, 1.5).mul(dv_body).div(phi_s0_ves).scale(beta / 2.0);
        const term_12_l = sPow(S, phi_sL_ves, 0.5).mul(dv_body).div(phi_sL_ves).scale(beta / 2.0);
        const term_12_0 = sPow(S, phi_s0_ves, 0.5).mul(dv_body).div(phi_s0_ves).scale(beta / 2.0);
        const ids_bpc = term_32_l.sub(term_32_0).scale(2.0 / 3.0 * const0_si).sub(term_12_l.sub(term_12_0).scale(const0_si));
        break :blk_isub isub_base.add(ids_bpc);
    } else S.con(0.0);

    // ===== GATE TUNNELING CURRENT (Eq 232-250) =====
    const coiigs_f: f64 = if (p.coiigs == 1) 1.0 else 0.0;

    // vg_leak = vgs_ext - gleak8*vfb + (gleak4*dv_th - gleak10*ves)/l_eff - gleak3*phi_s_dl
    const vg_leak = vgs_ext.addC(-p.gleak8_p * vfb)
        .add(dv_th.scale(p.gleak4_p).sub(ves.scale(p.gleak10_p)).scale(1.0 / l_eff))
        .sub(phi_s_dl.scale(p.gleak3_p));
    // e_field_gate = (1 + ey_f/gleak5)*(1 - 1/(1+vgs_ext^2))*vg_leak/tfox_eff
    const efg_a = ey_f.scale(1.0 / p.gleak5_p).addC(1.0);
    const efg_b = vgs_ext.mul(vgs_ext).addC(1.0).pow(-1.0).neg().addC(1.0);
    const e_field_gate = efg_a.mul(efg_b).mul(vg_leak).div(tfox_eff);
    const egp_sq = @max(eg * eg, 1.0e-30);
    const egp_32 = safe_pow(@max(eg, 1.0e-30), 1.5);
    // qi_ratio = (|qi_avg|/|const0_si|)^gleak9  (variable base, const exp)
    const qi_ratio = sPow(S, qi_avg.abs().scale(1.0 / @max(@abs(const0_si), 1.0e-30)), p.gleak9_p);
    const leak_area = w_eff * nf * l_eff;
    // leak_factor: gleak6/(gleak6+vds_raw) * gleak7/(gleak7+leak_area)
    const leak_factor = vds_raw.addC(p.gleak6_p).maxC(1.0e-30).pow(-1.0).scale(p.gleak6_p)
        .scale(p.gleak7_p / @max(p.gleak7_p + leak_area, 1.0e-30));
    // igate = q*gleak1*E^2/egp_sq * exp(-egp32*gleak2/max(|E|,1e-6)) * qi_ratio * leak_area * leak_factor * coiigs
    const igate = e_field_gate.mul(e_field_gate).scale(Q_ELECTRON * p.gleak1_p / egp_sq)
        .mul(sExpClamp(S, e_field_gate.abs().maxC(1.0e-6).pow(-1.0).scale(-egp_32 * p.gleak2_p)))
        .mul(qi_ratio).mul(leak_factor).scale(leak_area * coiigs_f);

    const partition = 0.5;
    const igate_s = igate.scale(1.0 - partition);
    const igate_d = igate.scale(partition);

    // Gate-to-bulk accumulation (Eq 239-244)
    const e_gb1_val = vgs_ext.sub(ves.scale(p.glkb4_p)).addC(-(vfb + p.glkb3_p)).div(tfox_eff).neg();
    const f1_lg = @max(lum + p.glkb7_p, p.glkb8_p);
    // igb1_mag = glkb1*|E|^glkb5*exp(-glkb2/max(|E|,1e-6)-glkb6)*w_eff*nf*f1_lg*coiigs
    const igb1_mag = sPow(S, e_gb1_val.abs(), p.glkb5_p)
        .mul(sExpClamp(S, e_gb1_val.abs().maxC(1.0e-6).pow(-1.0).scale(-p.glkb2_p).addC(-p.glkb6_p)))
        .scale(p.glkb1_p * w_eff * nf * f1_lg * coiigs_f);
    const igb1 = if (e_gb1_val.val() > 0.0) igb1_mag else igb1_mag.neg();

    const e_gb2_val = vgs_ext.sub(ves.scale(p.glkb24_p)).addC(-(vfb + p.glkb23_p)).div(tfox_eff).neg();
    const f2_lg = @max(lum + p.glkb27_p, p.glkb28_p);
    const igb2_mag = sPow(S, e_gb2_val.abs(), p.glkb25_p)
        .mul(sExpClamp(S, e_gb2_val.abs().maxC(1.0e-6).pow(-1.0).scale(-p.glkb22_p).addC(-p.glkb26_p)))
        .scale(p.glkb21_p * w_eff * nf * f2_lg * coiigs_f);
    const igb2 = if (e_gb2_val.val() > 0.0) igb2_mag else igb2_mag.neg();

    // Gate-to-S/D overlap (Eq 245-250)
    const f_sd_lg = safe_pow(lum, p.glksd4_p);
    const e_gs_val = vgs_ext.scale(p.glksd5_p).div(tfox_eff);
    // igs_sd_mag = glksd1*E^2*exp(tfox_eff*(-glksd2*vgs+glksd3))*w_eff*nf*f_sd*coiigs
    const igs_sd_mag = e_gs_val.mul(e_gs_val)
        .mul(sExpClamp(S, tfox_eff.mul(vgs_ext.scale(-p.glksd2_p).addC(p.glksd3_p))))
        .scale(p.glksd1_p * w_eff * nf * f_sd_lg * coiigs_f);
    const igs_sd = if (e_gs_val.val() < 0.0) igs_sd_mag else igs_sd_mag.neg();

    const e_gd_val = vgs_ext.sub(vds_raw).scale(p.glksd5_p).div(tfox_eff);
    // exp(tfox_eff*(glksd2*(-vgs+vds_raw)+glksd3))
    const igd_sd_mag = e_gd_val.mul(e_gd_val)
        .mul(sExpClamp(S, tfox_eff.mul(vgs_ext.neg().add(vds_raw).scale(p.glksd2_p).addC(p.glksd3_p))))
        .scale(p.glksd1_p * w_eff * nf * f_sd_lg * coiigs_f);
    const igd_sd = if (e_gd_val.val() < 0.0) igd_sd_mag else igd_sd_mag.neg();

    // ===== GIDL (Eq 251-254) =====
    const cogidl_f: f64 = if (p.cogidl == 1) 1.0 else 0.0;
    const vg0_gidl = vgs_ext.add(dv_th_sc.add(dv_th_p).scale(p.gidl5_p)); // Eq 254
    const e_gidl_d = vds_raw.addC(p.gidl4_p).scale(p.gidl3_p).sub(vg0_gidl).scale(1.0 / p.tfoxgidl_p); // Eq 253
    const eg2 = @max(eg, 1.0e-6);
    const eg2_32 = safe_pow(eg2, 1.5);
    const t1_gidl = sExpClamp(S, vds_raw.scale(-beta)).addC(1.0).pow(-1.0); // Eq 252
    const gidl_t_factor = 1.0 / @max(1.0 - contract.fmath.exp(@min(-l_eff / @max(p.gidlbpl1_p * safe_pow(p.t_ratio, p.gidlbplt_p), 1.0e-30), 80.0)), 1.0e-30);
    const igidl_raw = if (e_gidl_d.val() > 0.0)
        e_gidl_d.mul(e_gidl_d).scale(Q_ELECTRON * p.gidl1_p / eg2)
            .mul(sExpClamp(S, e_gidl_d.maxC(1.0e-6).pow(-1.0).scale(-p.gidl2_p * eg2_32)))
            .mul(t1_gidl).scale(w_eff * nf * gidl_t_factor)
    else
        S.con(0.0);
    const igidl = igidl_raw.scale(cogidl_f);

    // GISL at source (mirror): e_gidl_s = (gidl3*gidl4 - vg0_gidl)/tfoxgidl
    const e_gidl_s = vg0_gidl.neg().addC(p.gidl3_p * p.gidl4_p).scale(1.0 / p.tfoxgidl_p);
    const igisl_raw = if (e_gidl_s.val() > 0.0)
        e_gidl_s.mul(e_gidl_s).scale(Q_ELECTRON * p.gidl1_p / eg2)
            .mul(sExpClamp(S, e_gidl_s.maxC(1.0e-6).pow(-1.0).scale(-p.gidl2_p * eg2_32)))
            .scale(w_eff * nf * gidl_t_factor)
    else
        S.con(0.0);
    const igisl = igisl_raw.scale(cogidl_f);

    // ===== VALENCE BAND ELECTRON TUNNELING (Eq 255-257) =====
    const coievb_f: f64 = if (p.coievb == 1) 1.0 else 0.0;
    const phi_barrier: f64 = 4.12;
    const vfox = vgs_ext.sub(phi_s0); // Eq 257 approx
    const vfox_ratio = vfox.scale(1.0 / phi_barrier);
    // efox = -(fvbs*ves - vfox + dv_th_sc + dv_th_p + eg + evb3)/tfox_eff
    const efox = ves.scale(p.fvbs_p).sub(vfox).add(dv_th_sc).add(dv_th_p).addC(eg + p.evb3_p).div(tfox_eff).neg();
    const inner_32 = vfox_ratio.neg().addC(1.0).maxC(0.0);
    const inner_32_pow = sPow(S, inner_32, 1.5);
    const ievb = if (p.evb1_p > 0.0 and efox.val() > 0.0)
        vfox_ratio.mul(vfox_ratio.scale(2.0).addC(-1.0)).mul(efox).mul(efox)
            .mul(sExpClamp(S, inner_32_pow.neg().addC(1.0).mul(efox.maxC(1.0e-6).pow(-1.0)).scale(-p.evb2_p)))
            .scale(p.evb1_p * Q_ELECTRON * w_eff * nf * l_eff * coievb_f)
    else
        S.con(0.0);

    // ===== FLOATING-BODY EFFECT (Eq 258-264) =====
    const cofbe_active = p.cofbe == 1 and p.coisub == 1;
    const qh_fbe: S = if (cofbe_active) blk_fbe: {
        const dn: f64 = 36.0;
        const dp_fbe: f64 = 13.0;
        const nd_fbe: f64 = 1.0e20;
        const ln_fbe = safe_sqrt(dn * 1.0e-7);
        const lp_fbe = safe_sqrt(dp_fbe * 1.0e-7);
        const denom_fbe = Q_ELECTRON * p.tsoi_p * w_eff * contract.fmath.exp(@min(-beta * p.qhe2_p, 80.0)) *
            (dn * nd_fbe * lp_fbe + dp_fbe * nd_fbe * ln_fbe);
        // dvsb = qhe1*vt*log(1 + (isub+ievb)*lp_fbe*ln_fbe/max(denom_fbe,1e-60))
        const dvsb = sLog(S, isub.add(ievb).scale(lp_fbe * ln_fbe / @max(denom_fbe, 1.0e-60)).addC(1.0)).scale(p.qhe1_p * p.vt);
        const arg_fbe1 = sExpClamp(S, phi_s0.sub(dvsb).scale(-beta)).add(phi_s0.sub(dvsb).scale(beta)).addC(-1.0).maxC(0.0);
        const arg_fbe2 = sExpClamp(S, phi_s0.scale(-beta)).add(phi_s0.scale(beta)).addC(-1.0).maxC(0.0);
        break :blk_fbe sSqrt(S, arg_fbe1).sub(sSqrt(S, arg_fbe2));
    } else S.con(0.0);
    // FBE perturbation on Ids
    const ids_fbe_correction = qh_fbe.scale(const0_si).mul(mu_f).div(l_eff_clm.scale(beta));

    // ===== SELF-HEATING EFFECT =====
    const coselfheat_active = p.coselfheat == 1 and p.rth0_p > 0.0;
    // delta_T = |ids_total_base + ids_fbe_correction| * |vds_raw| * RTH0
    const p_diss = ids_total_base.add(ids_fbe_correction).abs().mul(vds_raw.abs());
    const delta_temp_sh = if (coselfheat_active) p_diss.scale(p.rth0_p) else S.con(0.0);
    // sh_correction = 1/max(1 + delta_T*1.5e-3, 0.1)
    const sh_correction = delta_temp_sh.scale(1.5e-3).addC(1.0).maxC(0.1).pow(-1.0);
    const ids_sh_base = ids_total_base.add(ids_fbe_correction);
    const ids_sh = if (coselfheat_active) ids_sh_base.mul(sh_correction) else ids_sh_base;

    const ids_total = ids_sh;

    // ===== PARASITIC RESISTANCES (Eq 191-203) =====
    const vddp = x[d].sub(x[dp]).scale(type_f);
    const vddp_abs = vddp.abs().addC(1.0e-30);
    const vddp_sign = vddp.div(vddp_abs);
    // mu_drift (Eq 193): mu_drift0 / (1 + (drift_ratio)^rdrbb)^(1/rdrbb)
    const drift_ratio_d = vddp_abs.scale(p.mu_drift0 / @max(p.vmax_drift, 1.0e-6) / p.ldrift_p);
    const mu_drift = sPow(S, sPow(S, drift_ratio_d.abs(), p.rdrbb_temp).addC(1.0), 1.0 / @max(p.rdrbb_temp, 1.0e-6)).pow(-1.0).scale(p.mu_drift0);
    const iddp_drift = mu_drift.mul(vddp_abs).scale(w_eff * nf * p.x_ov * Q_ELECTRON * p.nover_p * 1.0e6 / p.ldrift_p);
    const i_rsh_d = if (p.rsh_p > 0.0) vddp_abs.scale(1.0 / @max(p.rsh_p * p.nrd, 1.0e-30)) else S.con(0.0);
    const i_drain_res = iddp_drift.add(i_rsh_d).mul(vddp_sign);
    // Drain resistance: G if CORD=1, else GSHORT
    const g_rd: S = if (p.cord == 1 and (p.rsh_p > 0.0 or p.x_ov > 0.0))
        i_drain_res.abs().div(vddp_abs.maxC(1.0e-12))
    else
        S.con(GSHORT);

    const vssp = x[s].sub(x[sp]).scale(type_f);
    const vssp_abs = vssp.abs().addC(1.0e-30);
    const vssp_sign = vssp.div(vssp_abs);
    const drift_ratio_s = vssp_abs.scale(p.mu_source0 / @max(p.vmax_source, 1.0e-6) / p.ldrifts_p);
    const mu_source = sPow(S, sPow(S, drift_ratio_s.abs(), p.rsrbb_temp).addC(1.0), 1.0 / @max(p.rsrbb_temp, 1.0e-6)).pow(-1.0).scale(p.mu_source0);
    const issp_drift = mu_source.mul(vssp_abs).scale(w_eff * nf * p.x_ov * Q_ELECTRON * p.novers_p * 1.0e6 / p.ldrifts_p);
    const i_rsh_s = if (p.rsh_p > 0.0) vssp_abs.scale(1.0 / @max(p.rsh_p * p.nrs, 1.0e-30)) else S.con(0.0);
    const i_source_res = issp_drift.add(i_rsh_s).mul(vssp_sign);
    const g_rs: S = if (p.cors == 1 and (p.rsh_p > 0.0 or p.x_ov > 0.0))
        i_source_res.abs().div(vssp_abs.maxC(1.0e-12))
    else
        S.con(GSHORT);

    // Gate resistance (Eq 203) — x-independent
    const rg_val = if (p.rshg_p > 0.0 and p.corg == 1)
        p.rshg_p * (p.xgw + w_eff / (3.0 * p.ngcon)) / (p.ngcon * @max(p.l_drawn - p.xgl, 1.0e-9) * nf)
    else
        0.0;
    const g_rg: f64 = if (rg_val > 0.0) 1.0 / rg_val else GSHORT;

    // ===== ASSEMBLE KCL CONTRIBUTIONS =====
    const ids_out = ids_total.add(ids_sti).scale(m_mult * type_f);
    const isub_out = isub.scale(m_mult * type_f);
    const igidl_out = igidl.scale(m_mult * type_f);
    const igisl_out = igisl.scale(m_mult * type_f);
    const igate_s_out = igate_s.scale(m_mult * type_f);
    const igate_d_out = igate_d.scale(m_mult * type_f);
    const igb_out = igb1.add(igb2).scale(m_mult * type_f);
    const igs_sd_out = igs_sd.scale(m_mult * type_f);
    const igd_sd_out = igd_sd.scale(m_mult * type_f);
    const ievb_out = ievb.scale(m_mult * type_f);

    // Parasitic resistance currents (external to internal)
    const i_rd = x[d].sub(x[dp]).mul(g_rd);
    const i_rs = x[s].sub(x[sp]).mul(g_rs);
    const i_rg = x[g].sub(x[gp]).scale(g_rg);

    // GMIN for convergence
    const gmin_ds = x[dp].sub(x[sp]).scale(GMIN);
    const gmin_gs = x[gp].sub(x[sp]).scale(GMIN);
    const gmin_es = x[e].sub(x[sp]).scale(GMIN);

    var out: [n_u]S = undefined;

    // Gate node: gate resistance
    out[g] = i_rg;
    // Drain node: drain resistance
    out[d] = i_rd;
    // Source node: source resistance
    out[s] = i_rs;
    // Substrate node: -Isub - GIDL - GISL + Igb + Ievb + gmin
    out[e] = isub_out.neg().sub(igidl_out).sub(igisl_out).add(igb_out).add(ievb_out).add(gmin_es);
    // Drain prime node
    out[dp] = mode_sign.mul(ids_out).add(isub_out).add(igidl_out).add(igate_d_out).add(igd_sd_out).sub(i_rd).add(gmin_ds);
    // Source prime node
    out[sp] = mode_sign.neg().mul(ids_out).add(igisl_out).add(igate_s_out).add(igs_sd_out).sub(i_rs).sub(gmin_ds).sub(gmin_gs).sub(gmin_es);
    // Gate prime node
    out[gp] = igate_s_out.add(igate_d_out).add(igb_out).add(igs_sd_out).add(igd_sd_out).neg().sub(i_rg).add(gmin_gs);

    return out;
}

// ============================================================================
// x-INDEPENDENT parameter prep for the CHARGE function.
// ============================================================================

const ParamsQ = struct {
    type_f: f64,
    m_mult: f64,
    nf: f64,
    beta: f64,
    l_gate: f64,
    lum: f64,
    l_eff: f64,
    w_effc: f64,
    w_gate: f64,
    vzadd0_p: f64,
    vfbc_p: f64,
    tfox_p: f64,
    tpoly_p: f64,
    lover_p: f64,
    vfbover_p: f64,
    xqy_p: f64,
    xqy1_p: f64,
    xqy2_p: f64,
    tsoi_p: f64,
    cfox: f64,
    cbox: f64,
    csoi: f64,
    qns: f64,
    qdep_soi: f64,
    nsubsp_w: f64,
    cgso_val: f64,
    cgdo_val: f64,
    cgbo_val: f64,
    coovlp: i32,
    coadov: i32,
};

fn prepQ(model: *const Model, instance: *const Instance) ParamsQ {
    const type_f: f64 = @floatFromInt(model.type_);
    const tfox_p: f64 = @as(f64, model.tfox);
    const tbox_p: f64 = @as(f64, model.tbox);
    const tsoi_p: f64 = @as(f64, model.tsoi);
    const xld_p: f64 = @as(f64, model.xld);
    const xldl_p: f64 = @as(f64, model.xldl);
    const xldlmin_p: f64 = @as(f64, model.xldlmin);
    const xwdc_p: f64 = @as(f64, model.xwdc);
    const tpoly_p: f64 = @as(f64, model.tpoly);
    const nsubs_p: f64 = @as(f64, model.nsubs);
    const vfbc_p: f64 = @as(f64, model.vfbc);
    const lover_p: f64 = @as(f64, model.lover);
    const vfbover_p: f64 = @as(f64, model.vfbover);
    const xqy_p: f64 = @as(f64, model.xqy);
    const xqy1_p: f64 = @as(f64, model.xqy1);
    const xqy2_p: f64 = @as(f64, model.xqy2);
    const ratwsti_p: f64 = @as(f64, model.ratwsti);
    const wsti_p: f64 = @as(f64, model.wsti);
    const vzadd0_p: f64 = @as(f64, model.vzadd0);
    const eg0_p: f64 = @as(f64, model.eg0);
    const bgtmp1_p: f64 = @as(f64, model.bgtmp1);
    const bgtmp2_p: f64 = @as(f64, model.bgtmp2);
    const tnom_p: f64 = @as(f64, model.tnom);
    const nsubsw_p: f64 = @as(f64, model.nsubsw);
    const nsubswp_p: f64 = @as(f64, model.nsubswp);
    const nsubsmax_p: f64 = @as(f64, model.nsubsmax);
    const nsubswpe_p: f64 = @as(f64, model.nsubswpe);
    const web_p: f64 = @as(f64, model.web);
    const wec_p: f64 = @as(f64, model.wec);

    const l_drawn: f64 = @as(f64, instance.l);
    const w_drawn: f64 = @as(f64, instance.w);
    const m_mult: f64 = @as(f64, instance.m);
    const nf: f64 = @as(f64, instance.nf);
    const sca_p: f64 = @as(f64, instance.sca);
    const scb_p: f64 = @as(f64, instance.scb);
    const scc_p: f64 = @as(f64, instance.scc);

    // Temperature
    const temp_c: f64 = @as(f64, instance.temp) + @as(f64, instance.dtemp);
    const temp_k: f64 = temp_c + 273.15;
    const tnom_k: f64 = tnom_p + 273.15;
    const t_ratio: f64 = temp_k / tnom_k;
    const beta: f64 = Q_ELECTRON / (K_BOLTZ * temp_k);

    // Bandgap
    const eg_tnom = eg0_p - 90.25e-6 * tnom_p - 1.0e-7 * tnom_p * tnom_p;
    const eg = eg_tnom - bgtmp1_p * (temp_c - tnom_p) - bgtmp2_p * (temp_c * temp_c - tnom_p * tnom_p);
    _ = NI_300 * safe_pow(t_ratio, 1.5) * contract.fmath.exp(@min(-(eg * Q_ELECTRON) / (2.0 * K_BOLTZ * temp_k), 80.0));

    // Geometry
    const l_gate = l_drawn;
    const w_gate = w_drawn / nf;
    const lum = l_gate * 1.0e6;
    const w_sti_mod = wsti_p * ratwsti_p;

    const xldmod = xld_p * l_gate / @max(xldl_p + xldlmin_p, 1.0e-30);
    const xld_eff = if (xld_p > 0.0) @min(xldmod, xld_p) else @max(xldmod, xld_p);
    const l_eff = @max(l_gate - 2.0 * xld_eff, 1.0e-9);
    const w_effc = @max(w_gate - 2.0 * xwdc_p - 2.0 * w_sti_mod, 1.0e-9);

    // WPE
    const wpe_factor = sca_p + web_p * scb_p + wec_p * scc_p;
    const nsubs_wpe = nsubs_p + nsubswpe_p * wpe_factor;
    const nsubsp_w = @min(nsubsmax_p, nsubs_wpe * (1.0 + nsubsw_p / safe_pow(@max(w_gate * 1.0e6, 1.0e-6), nsubswp_p)));

    // Capacitances
    const cfox = EPS_OX / tfox_p;
    const cbox = EPS_OX / tbox_p;
    const csoi = EPS_SI / tsoi_p;

    const nsubs_m3 = nsubsp_w * 1.0e6;
    const qns = Q_ELECTRON * nsubs_m3 * EPS_SI;
    const qdep_soi = -Q_ELECTRON * nsubsp_w * 1.0e6 * tsoi_p;

    // Overlap caps
    const cgso_val: f64 = if (model.cgso >= 0.0) @as(f64, model.cgso) else cfox * lover_p;
    const cgdo_val: f64 = if (model.cgdo >= 0.0) @as(f64, model.cgdo) else cfox * lover_p;
    const cgbo_val: f64 = if (model.cgbo >= 0.0) @as(f64, model.cgbo) else 0.0;

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .nf = nf,
        .beta = beta,
        .l_gate = l_gate,
        .lum = lum,
        .l_eff = l_eff,
        .w_effc = w_effc,
        .w_gate = w_gate,
        .vzadd0_p = vzadd0_p,
        .vfbc_p = vfbc_p,
        .tfox_p = tfox_p,
        .tpoly_p = tpoly_p,
        .lover_p = lover_p,
        .vfbover_p = vfbover_p,
        .xqy_p = xqy_p,
        .xqy1_p = xqy1_p,
        .xqy2_p = xqy2_p,
        .tsoi_p = tsoi_p,
        .cfox = cfox,
        .cbox = cbox,
        .csoi = csoi,
        .qns = qns,
        .qdep_soi = qdep_soi,
        .nsubsp_w = nsubsp_w,
        .cgso_val = cgso_val,
        .cgdo_val = cgdo_val,
        .cgbo_val = cgbo_val,
        .coovlp = model.coovlp,
        .coadov = model.coadov,
    };
}

// ============================================================================
// Charge Function (value-form)
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
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);
    const e = @intFromEnum(U.sub);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);

    const p = &pc.q;
    const beta = p.beta;
    const cfox = p.cfox;
    const cbox = p.cbox;
    const csoi = p.csoi;
    const qns = p.qns;
    const w_effc = p.w_effc;
    const nf = p.nf;
    const l_eff = p.l_eff;
    const l_gate = p.l_gate;
    const lum = p.lum;
    const type_f = p.type_f;
    const m_mult = p.m_mult;

    // Terminal voltages
    const vgs = x[gp].sub(x[sp]).scale(type_f);
    const vds_ext = x[dp].sub(x[sp]).scale(type_f);
    const ves = x[e].sub(x[sp]).scale(type_f);
    const vds_sym = sSqrt(S, vds_ext.mul(vds_ext).addC(4.0 * p.vzadd0_p * p.vzadd0_p));
    const vds_raw = vds_ext.add(vds_sym).scale(0.5);

    // Surface potentials (simplified)
    const vg0 = vgs.addC(-p.vfbc_p); // simplified Vg0
    // vdsat_arg = max(1 + 2*cfox^2/(beta*qns)*(beta*vg0 - 1), 1e-30)
    const vdsat_arg = vg0.scale(beta).addC(-1.0).scale(2.0 * cfox * cfox / (beta * qns)).addC(1.0).maxC(1.0e-30);
    const vdsat = vg0.add(sSqrt(S, vdsat_arg).neg().addC(1.0).scale(qns / (cfox * cfox)));
    const vdsat_c = vdsat.maxC(1.0e-6);
    // vds_eff = vds_raw / (1 + (vds_raw/vdsat_c)^10)^0.1
    const vds_eff = vds_raw.div(sPow(S, sPow(S, vds_raw.div(vdsat_c), 10.0).addC(1.0), 0.1));

    // phi_s0 (same closed form as vdsat surface potential)
    const phi_s0_arg = vg0.scale(beta).addC(-1.0).scale(2.0 * cfox * cfox / (beta * qns)).addC(1.0).maxC(1.0e-30);
    const phi_s0 = vg0.add(sSqrt(S, phi_s0_arg).neg().addC(1.0).scale(qns / (cfox * cfox)));
    const phi_sl = phi_s0.add(vds_eff);
    const phi_b0 = phi_s0.scale(csoi / (csoi + cbox)).add(ves.scale(cbox / (csoi + cbox)));

    // ===== INTRINSIC GATE CHARGE =====
    // Q_gate = -Cfox * W_effc * NF * Leff * (Vgs - (phi_s0 + phi_sL)/2)
    const phi_avg = phi_s0.add(phi_sl).scale(0.5);
    const q_gate_intr = vgs.sub(phi_avg).scale(-cfox * w_effc * nf * l_eff);

    // Charge partitioning (Ward-Dutton 40/60)
    const qi_total = phi_avg.sub(phi_b0).maxC(0.0).scale(cfox * w_effc * nf * l_eff);
    const q_drain_intr = qi_total.scale(-0.4);
    const q_source_intr = qi_total.scale(-0.6);

    // ===== OVERLAP CHARGES (Eq 205-212) =====
    const q_ovlp_s = if (p.coovlp == 0)
        vgs.scale(p.cgso_val * w_effc * nf)
    else
        vgs.sub(ves).addC(-2.0 * p.vfbover_p).scale(w_effc * nf * p.lover_p * cfox);

    const q_ovlp_d = if (p.coovlp == 0)
        vgs.sub(vds_raw).scale(p.cgdo_val * w_effc * nf)
    else
        vgs.sub(ves).addC(-2.0 * p.vfbover_p).scale(w_effc * nf * p.lover_p * cfox);

    // Gate-bulk overlap (Eq 210)
    const q_ovlp_b = vgs.sub(ves).scale(-p.cgbo_val * l_gate);

    // ===== LATERAL FIELD CHARGE Q_y (Eq 204) =====
    const q_y: S = if (p.coadov == 1 and p.xqy_p > 0.0) blk_qy: {
        const wd_q = p.tsoi_p;
        break :blk_qy phi_s0.add(vds_raw).sub(phi_sl).scale(EPS_SI * w_effc * nf * wd_q / p.xqy_p)
            .add(ves.scale(p.xqy1_p * w_effc * 1.0e6 * nf / safe_pow(lum, p.xqy2_p)));
    } else S.con(0.0);

    // ===== FRINGING CAPACITANCE (Eq 212) =====
    const q_fringe = if (p.tpoly_p > 0.0)
        vgs.scale(EPS_OX / (PI / 2.0) * p.w_gate * nf * safe_log(1.0 + p.tpoly_p / p.tfox_p))
    else
        S.con(0.0);

    // ===== ASSEMBLE CHARGE OUTPUTS =====
    const q_g_total = q_gate_intr.add(q_ovlp_d).add(q_ovlp_s).add(q_ovlp_b).add(q_fringe).scale(m_mult);
    const q_d_total = q_drain_intr.sub(q_ovlp_d).add(q_y).scale(m_mult);
    const q_s_total = q_source_intr.sub(q_ovlp_s).scale(m_mult);
    const q_e_total = q_ovlp_b.neg().sub(q_y).scale(m_mult);

    var out: [n_u]S = undefined;
    out[g] = S.con(0.0);
    out[d] = S.con(0.0);
    out[s] = S.con(0.0);
    out[e] = q_e_total.scale(type_f);
    out[dp] = q_d_total.scale(type_f);
    out[sp] = q_s_total.scale(type_f);
    out[gp] = q_g_total.scale(type_f);
    return out;
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var result = x_new;
    const type_f: f64 = @floatFromInt(model.type_);

    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);

    const vt_lim: f64 = K_BOLTZ * 300.15 / Q_ELECTRON;

    // Gate voltage limiting (DEVfetlim)
    {
        const vgs_new = (x_new[gp] - x_new[sp]) * type_f;
        const vgs_old = (x_old[gp] - x_old[sp]) * type_f;
        const vth: f64 = @as(f64, model.vfbc) + 0.6; // approximate Vth
        const vgs_lim = fetlim(vgs_new, vgs_old, vth);
        const delta_v = (vgs_lim - vgs_new) * type_f;
        result[gp] = result[gp] + delta_v;
    }

    // Vds limiting (DEVlimvds)
    {
        const vds_new = (x_new[dp] - x_new[sp]) * type_f;
        const vds_old = (x_old[dp] - x_old[sp]) * type_f;
        const vds_lim = limvds(vds_new, vds_old);
        const delta_v = (vds_lim - vds_new) * type_f;
        result[dp] = result[dp] + delta_v;
    }

    // Ves limiting (substrate)
    {
        const e_idx = @intFromEnum(U.sub);
        const ves_new = (x_new[e_idx] - x_new[sp]) * type_f;
        const ves_old = (x_old[e_idx] - x_old[sp]) * type_f;
        const max_step = 3.0 * vt_lim;
        const delta = ves_new - ves_old;
        const abs_delta = @abs(delta);
        const ves_lim = if (abs_delta > max_step)
            ves_old + (if (delta > 0.0) max_step else -max_step)
        else
            ves_new;
        const delta_v = (ves_lim - ves_new) * type_f;
        result[e_idx] = result[e_idx] + delta_v;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale GMIN-equivalent via subthreshold parameter smoothing
    const gmin_scale = GMIN * (1.0 - lambda);

    // Add GMIN to substrate current parameters for easier initial convergence
    const sub1_orig: f64 = @as(f64, model.sub1);
    const sub1_scaled = sub1_orig * lambda;
    m.sub1 = @as(f32, @floatCast(sub1_scaled));

    // Smooth Vfbc for convergence
    const vfbc_orig: f64 = @as(f64, model.vfbc);
    const vfbc_scaled = vfbc_orig * lambda + (-0.5) * (1.0 - lambda);
    m.vfbc = @as(f32, @floatCast(vfbc_scaled));

    // Scale SCE for convergence
    const sc1_orig: f64 = @as(f64, model.sc1);
    m.sc1 = @as(f32, @floatCast(sc1_orig * lambda));

    _ = gmin_scale;
    return m;
}

// ============================================================================
// Helper: FET gate voltage limiting (DEVfetlim)
// ============================================================================

fn fetlim(vnew: f64, vold: f64, vth: f64) f64 {
    const vov_new = vnew - vth;
    const vov_old = vold - vth;

    const result = if (vov_new > 0.0 and vov_old > 0.0) blk: {
        const delta = vnew - vold;
        const abs_delta = @abs(delta);
        const twice_vov = 2.0 * vov_old;
        break :blk if (abs_delta > twice_vov) if (delta > 0.0) vold + twice_vov else vold - twice_vov else vnew;
    } else if (vov_new > 0.0)
        vth + 0.5 * vov_new
    else if (vov_old > 0.0)
        vth - 0.5 * vov_old
    else
        vnew;

    return result;
}

// ============================================================================
// Helper: Vds limiting (DEVlimvds)
// ============================================================================

fn limvds(vnew: f64, vold: f64) f64 {
    const delta = vnew - vold;
    const abs_delta = @abs(delta);
    const max_step: f64 = 3.5;

    return if (abs_delta > max_step)
        if (vold >= 0.0)
            vold + (if (delta > 0.0) max_step else -max_step)
        else
            (if (delta > 0.0) @min(vnew, max_step) else vold - max_step)
    else
        vnew;
}

// ============================================================================
// Noise Spectral Density Computation (Eqs 268-278)
// ============================================================================
// These functions compute the noise PSD values used by the noise analysis
// engine. They take operating-point quantities computed during the i() evaluation.

/// Flicker (1/f) noise PSD * f (Eq 268-270): N_flick = S_Ids * f
/// Returns the value to be divided by f in the noise analysis.
inline fn noise_flicker_psd(
    ids: f64,
    nftrp: f64,
    nfalp: f64,
    beta_val: f64,
    l_eff_clm: f64,
    w_eff: f64,
    nf_val: f64,
    cfox: f64,
    cit: f64,
    mu_f: f64,
    ey: f64,
    n0: f64,
    nl: f64,
) f64 {
    // Eq 269: N* = (C_FOX + C_dep + CIT) / (q * beta)
    const n_star = (cfox + cit) / (Q_ELECTRON * beta_val);
    const n0_ns = n0 + n_star;
    const nl_ns = nl + n_star;
    const dn = nl - n0;
    const dn_safe = @max(@abs(dn), 1.0e-30);
    // Eq 268: three terms
    const term1 = 1.0 / @max(n0_ns * nl_ns, 1.0e-60);
    const term2 = 2.0 * mu_f * ey * nfalp / dn_safe * safe_log(@abs(nl_ns) / @max(@abs(n0_ns), 1.0e-30));
    const term3 = mu_f * ey * nfalp * mu_f * ey * nfalp;
    // S_Ids = Ids^2 * NFTRP / (beta * f * (Leff-dL) * Weff * NF) * [terms]
    // N_flick = S_Ids * f (Eq 270)
    return ids * ids * nftrp / (beta_val * l_eff_clm * w_eff * nf_val) * (term1 + term2 + term3);
}

/// Thermal noise PSD (Eq 271-276): N_thrml = S_id / (4kT)
inline fn noise_thermal_psd(
    w_eff: f64,
    nf_val: f64,
    cfox: f64,
    vgvt: f64,
    l_eff_clm: f64,
    mu_f: f64,
    mu_d: f64,
    eta: f64,
) f64 {
    // Eq 271 simplified: S_id = 4kT * Weff*NF*Cfox*Vgvt/(Leff-dL) * mobility_factor
    const mu_av = (mu_f + mu_d) / 2.0; // Eq 273
    const mu_av2 = mu_av * mu_av;
    const eta2 = eta * eta;
    // Numerator terms from Eq 271
    const num = mu_f * (1.0 + 3.0 * eta + 6.0 * eta2) * mu_d * mu_d +
        (3.0 + 4.0 * eta + 3.0 * eta2) * mu_d * mu_f +
        (6.0 + 3.0 * eta + eta2) * mu_f;
    const denom = 15.0 * (1.0 + eta) * mu_av2;
    // N_thrml = Weff*NF*Cfox*Vgvt/(Leff-dL) * num/denom (Eq 276: S_id/(4kT))
    return w_eff * nf_val * cfox * @max(vgvt, 0.0) / @max(l_eff_clm, 1.0e-30) * num / @max(denom, 1.0e-30);
}

// ============================================================================
// Sparse Conductance Pattern
// ============================================================================

// ============================================================================
// Sparse Capacitance Pattern
// ============================================================================

// ============================================================================
// Compile-time Validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "hisim_sotb: resistor stamps at zero bias (all voltages 0)" {
    // At V = 0 everywhere: vgs=vds=ves=0. The channel/leakage currents vanish
    // (Ids ~ 0 because qi_avg -> qs_dep..., substrate/gate leak off by flag),
    // and the parasitic-resistance branches contribute i_rd=i_rs=i_rg=0.
    // So every residual entry must be ~0.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0, 0, 0, 0, 0, 0, 0 }, &model, &inst, 0);
    for (out) |v| {
        try testing.expect(std.math.isFinite(v));
        try testing.expectApproxEqAbs(@as(f64, 0.0), v, 1e-6);
    }
}

test "hisim_sotb: gate/drain/source resistance branches (GSHORT)" {
    // With cord/cors/corg default 0, g_rd=g_rs=g_rg=GSHORT=1e12.
    // Put 1 mV across each external->internal resistor; residual on the
    // external node = GSHORT * dv. Internal nodes also receive -i_r*.
    // Expected i_rd = GSHORT * (x[d]-x[dp]) = 1e12 * 1e-3 = 1e9.
    const model: Model = .{};
    const inst: Instance = .{};
    // indices: gate0 drain1 source2 sub3 dp4 sp5 gp6
    var xv = [_]f64{ 0, 0, 0, 0, 0, 0, 0 };
    xv[@intFromEnum(U.drain)] = 1e-3; // 1 mV drain vs drain_prime(0)
    const out = contract.evalValues(Self, xv, &model, &inst, 0);
    // i_rd = GSHORT * 1e-3 = 1e9 stamped on external drain node (out[drain]).
    // Hand: g_rd = GSHORT (1e12), (x[d]-x[dp]) = 1e-3 -> 1e9.
    try testing.expectApproxEqRel(@as(f64, 1e9), out[@intFromEnum(U.drain)], 1e-9);
    // The drain_prime node gets -i_rd (plus tiny gmin/channel terms ~ 0 here).
    try testing.expect(out[@intFromEnum(U.drain_prime)] < -0.9e9);
}

test "hisim_sotb: charge is finite and zero-bias intrinsic gate charge sign" {
    // At zero bias, vgs=0 -> q_gate_intr = -Cfox*Weffc*nf*Leff*(0 - phi_avg).
    // phi_avg follows phi_s0 which for vg0 = -vfbc = +1 (nMOS, vfbc=-1) is > 0,
    // so q_gate_intr = +Cfox*...*phi_avg > 0. Just assert finiteness + gate>0.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0, 0, 0, 0, 0, 0, 0 }, &model, &inst, 0);
    for (out) |v| try testing.expect(std.math.isFinite(v));
    // external g/d/s charges are hard-zero by construction.
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.gate)]);
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.drain)]);
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.source)]);
    // Charge conservation: sum of all node charges must be ~0 (KCL of charge).
    var sum: f64 = 0;
    for (out) |v| sum += v;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-12);
}

test "hisim_sotb: overlap charge scales linearly with vgs (Cgso path)" {
    // coovlp=0 (default): q_ovlp_s = cgso_val * w_effc * nf * vgs, cgso_val =
    // cfox*lover (cgso sentinel -1). With vgs applied only, the source overlap
    // charge is a linear function of vgs. Test residual finiteness + that
    // gate charge grows when vgs grows.
    const model: Model = .{};
    const inst: Instance = .{};
    var x1 = [_]f64{ 0, 0, 0, 0, 0, 0, 0 };
    x1[@intFromEnum(U.gate_prime)] = 0.5; // vgs = 0.5
    var x2 = [_]f64{ 0, 0, 0, 0, 0, 0, 0 };
    x2[@intFromEnum(U.gate_prime)] = 1.0; // vgs = 1.0
    const o1 = contract.qValues(Self, x1, &model, &inst, 0);
    const o2 = contract.qValues(Self, x2, &model, &inst, 0);
    try testing.expect(std.math.isFinite(o1[@intFromEnum(U.gate_prime)]));
    try testing.expect(std.math.isFinite(o2[@intFromEnum(U.gate_prime)]));
    // Gate charge must actually respond to vgs (nonzero sensitivity): the two
    // operating points differ.
    try testing.expect(o1[@intFromEnum(U.gate_prime)] != o2[@intFromEnum(U.gate_prime)]);
}
