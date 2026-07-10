const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: MVSG CMC 4.0.0 -- MIT Virtual Source GaN FET (HEMT)
//
// AlGaN/GaN HEMT sub-circuit model including:
//   - Intrinsic FET (virtual-source channel current under gate)
//   - Source/Drain access region implicit-gate transistors (SAR/DAR)
//   - 4 source-side field-plate transistors (FPS1-FPS4)
//   - 4 drain-side field-plate transistors (FP1-FP4)
//   - Distributed gate resistance (gi1, gi2)
//   - p-GaN Schottky junction module (Dsch, Csch, Rsch at gi2p)
//   - Schottky gate diodes (forward + reverse recombination)
//   - Channel breakdown diodes
//   - Bias-dependent fringing capacitances
//   - Self-heating thermal sub-circuit (dt node)
//   - Charge trapping sub-circuits (drain-lag, gate-lag)
//   - RF gm-dispersion (NQS transport)
//   - Ward-Dutton charge partitioning
//   - Flicker and shot noise
//
// External terminals: d, g, s, b, dt (5 ports)
// Internal nodes: gi1, gi2, gi2p, si, di, src, drc,
//                 fps1, fps2, fps3, fps4, fp1, fp2, fp3, fp4,
//                 xt1, xt2, vtrap, vdl, vgl (21 total = 5+16 internal)
// ============================================================================

pub const U = enum(u8) {
    // External ports (0..4)
    d = 0,
    g = 1,
    s = 2,
    b = 3,
    dt = 4,
    // Internal nodes (5..20)
    gi1 = 5,
    gi2 = 6,
    gi2p = 7,
    si = 8,
    di = 9,
    src = 10,
    drc = 11,
    fps1 = 12,
    fps2 = 13,
    fps3 = 14,
    fps4 = 15,
    fp1 = 16,
    fp2 = 17,
    fp3 = 18,
    fp4 = 19,
    xt1 = 20, // gm-dispersion internal node 1
    xt2 = 21, // gm-dispersion internal node 2
    vtrap = 22, // trapping (trapselect=1) bias stress node
    vdl = 23, // drain-lag trapping node (trapselect=2)
    vgl = 24, // gate-lag trapping node (trapselect=2)
};
pub const num_ports: usize = 5;

// ============================================================================
// Model Parameters (352 total)
// ============================================================================

pub const Model = struct {
    // --- Core Model Parameters (51) ---
    version: f32 = 4.00,
    tnom: f32 = 27.0,
    type_: i32 = 1,
    cg: f32 = 4.00e-3,
    tcg: f32 = 0.0,
    cofsm: f32 = 0.0,
    cofdm: f32 = 0.0,
    cofdsm: f32 = 0.0,
    cofdsubm: f32 = 0.0,
    cofssubm: f32 = 0.0,
    cofgsubm: f32 = 0.0,
    cofsm0: f32 = 0.0,
    cofdm0: f32 = 0.0,
    cofdsm0: f32 = 0.0,
    cofdsubm0: f32 = 0.0,
    cofssubm0: f32 = 0.0,
    cofgsubm0: f32 = 0.0,
    tcofs: f32 = 0.0,
    tcofd: f32 = 0.0,
    tcofds: f32 = 0.0,
    tcofssub: f32 = 0.0,
    tcofdsub: f32 = 0.0,
    tcofgsub: f32 = 0.0,
    vtfrin: f32 = -50,
    nfrin: f32 = 1e2,
    rsh: f32 = 150.0,
    rcs: f32 = 800e-6,
    rcd: f32 = 800e-6,
    vx0: f32 = 3.0e5,
    mu0: f32 = 0.135,
    beta: f32 = 2.0,
    vto: f32 = -2.72,
    ss: f32 = 0.120,
    delta1: f32 = 16e-3,
    delta2: f32 = 0.0,
    dibsat: f32 = 10.0,
    nd: f32 = 0.0,
    alpha: f32 = 3.5,
    lambda: f32 = 0.0,
    vtheta: f32 = 0.0,
    mtheta: f32 = 0.0,
    vzeta: f32 = 150e3,
    vtzeta: f32 = -0.4e-3,
    epsilon: f32 = 2.3,
    rct1: f32 = 0.0,
    rct2: f32 = 0.0,
    flagres: i32 = 0,
    flagsp: i32 = 0,
    flaggum: i32 = 0,
    mmaxs: f32 = 4.0e-5,

    // --- Source Access Region (SAR) Parameters (12) ---
    lgs: f32 = 3.0e-6,
    vtors: f32 = -650,
    cgrs: f32 = 5.0e-3,
    vx0rs: f32 = 100e3,
    mu0rs: f32 = 100e-3,
    betars: f32 = 1.00,
    delta1rs: f32 = 100e-3,
    srs: f32 = 0.100,
    ndrs: f32 = 0.0,
    vthetars: f32 = 0.0,
    mthetars: f32 = 0.0,
    alphars: f32 = 3.5,

    // --- Drain Access Region (DAR) Parameters (12) ---
    lgd: f32 = 4.85e-6,
    vtord: f32 = -650,
    cgrd: f32 = 4.3e-3,
    vx0rd: f32 = 100e3,
    mu0rd: f32 = 100e-3,
    betard: f32 = 1.00,
    delta1rd: f32 = 0.35,
    srd: f32 = 0.3,
    ndrd: f32 = 3.8,
    vthetard: f32 = 0.0,
    mthetard: f32 = 0.0,
    alphard: f32 = 3.5,

    // --- Source-side Field-Plate 1 (FPS1) Parameters (22) ---
    flagfps1: i32 = 1,
    lgfps1: f32 = 0.0,
    vtofps1: f32 = -44.5,
    cgfps1: f32 = 2.0e-4,
    tcgfps1: f32 = 0.0,
    flagfps1s: i32 = 1,
    cfps1s: f32 = 0e-19,
    flagfps1b: i32 = 1,
    ccfps1: f32 = 0.9e-10,
    tccfps1: f32 = 0.0,
    cbfps1: f32 = 0.0,
    tcbfps1: f32 = 0.0,
    vx0fps1: f32 = 1.2e5,
    mu0fps1: f32 = 0.2,
    betafps1: f32 = 1.00,
    delta1fps1: f32 = 0.0,
    sfps1: f32 = 3.2,
    ndfps1: f32 = 0.0,
    vtzetafps1: f32 = -0.4e-3,
    vthetafps1: f32 = 0.0,
    mthetafps1: f32 = 0.0,
    alphafps1: f32 = 1e-2,

    // --- Source-side Field-Plate 2 (FPS2) Parameters (22) ---
    flagfps2: i32 = 0,
    lgfps2: f32 = 0.0,
    vtofps2: f32 = -74.5,
    cgfps2: f32 = 1.0e-4,
    tcgfps2: f32 = 0.0,
    flagfps2s: i32 = 1,
    cfps2s: f32 = 0e-19,
    flagfps2b: i32 = 1,
    ccfps2: f32 = 0.3e-10,
    tccfps2: f32 = 0.0,
    cbfps2: f32 = 0.0,
    tcbfps2: f32 = 0.0,
    vx0fps2: f32 = 1.2e5,
    mu0fps2: f32 = 0.2,
    betafps2: f32 = 1.00,
    delta1fps2: f32 = 0.0,
    sfps2: f32 = 3.2,
    ndfps2: f32 = 0.0,
    vtzetafps2: f32 = -0.4e-3,
    vthetafps2: f32 = 0.0,
    mthetafps2: f32 = 0.0,
    alphafps2: f32 = 1e-2,

    // --- Source-side Field-Plate 3 (FPS3) Parameters (22) ---
    flagfps3: i32 = 0,
    lgfps3: f32 = 0.0,
    vtofps3: f32 = -74.5,
    cgfps3: f32 = 1.0e-4,
    tcgfps3: f32 = 0.0,
    flagfps3s: i32 = 1,
    cfps3s: f32 = 0e-19,
    flagfps3b: i32 = 1,
    ccfps3: f32 = 0.3e-10,
    tccfps3: f32 = 0.0,
    cbfps3: f32 = 0.0,
    tcbfps3: f32 = 0.0,
    vx0fps3: f32 = 1.2e5,
    mu0fps3: f32 = 0.2,
    betafps3: f32 = 1.00,
    delta1fps3: f32 = 0.0,
    sfps3: f32 = 3.2,
    ndfps3: f32 = 0.0,
    vtzetafps3: f32 = -0.4e-3,
    vthetafps3: f32 = 0.0,
    mthetafps3: f32 = 0.0,
    alphafps3: f32 = 1e-2,

    // --- Source-side Field-Plate 4 (FPS4) Parameters (22) ---
    flagfps4: i32 = 0,
    lgfps4: f32 = 0.0,
    vtofps4: f32 = -74.5,
    cgfps4: f32 = 1.0e-4,
    tcgfps4: f32 = 0.0,
    flagfps4s: i32 = 1,
    cfps4s: f32 = 0e-19,
    flagfps4b: i32 = 1,
    ccfps4: f32 = 0.3e-10,
    tccfps4: f32 = 0.0,
    cbfps4: f32 = 0.0,
    tcbfps4: f32 = 0.0,
    vx0fps4: f32 = 1.2e5,
    mu0fps4: f32 = 0.2,
    betafps4: f32 = 1.00,
    delta1fps4: f32 = 0.0,
    sfps4: f32 = 3.2,
    ndfps4: f32 = 0.0,
    vtzetafps4: f32 = -0.4e-3,
    vthetafps4: f32 = 0.0,
    mthetafps4: f32 = 0.0,
    alphafps4: f32 = 1e-2,

    // --- Drain-side Field-Plate 1 (FP1) Parameters (22) ---
    flagfp1: i32 = 1,
    lgfp1: f32 = 0.0,
    vtofp1: f32 = -44.5,
    cgfp1: f32 = 2.0e-4,
    tcgfp1: f32 = 0.0,
    flagfp1s: i32 = 1,
    cfp1s: f32 = 0e-19,
    flagfp1b: i32 = 1,
    ccfp1: f32 = 0.9e-10,
    tccfp1: f32 = 0.0,
    cbfp1: f32 = 0.0,
    tcbfp1: f32 = 0.0,
    vx0fp1: f32 = 1.2e5,
    mu0fp1: f32 = 0.2,
    betafp1: f32 = 1.00,
    delta1fp1: f32 = 0.0,
    sfp1: f32 = 3.2,
    ndfp1: f32 = 0.0,
    vtzetafp1: f32 = -0.4e-3,
    vthetafp1: f32 = 0.0,
    mthetafp1: f32 = 0.0,
    alphafp1: f32 = 1e-2,

    // --- Drain-side Field-Plate 2 (FP2) Parameters (22) ---
    flagfp2: i32 = 0,
    lgfp2: f32 = 0.0,
    vtofp2: f32 = -74.5,
    cgfp2: f32 = 1.0e-4,
    tcgfp2: f32 = 0.0,
    flagfp2s: i32 = 1,
    cfp2s: f32 = 0e-19,
    flagfp2b: i32 = 1,
    ccfp2: f32 = 0.3e-10,
    tccfp2: f32 = 0.0,
    cbfp2: f32 = 0.0,
    tcbfp2: f32 = 0.0,
    vx0fp2: f32 = 1.2e5,
    mu0fp2: f32 = 0.2,
    betafp2: f32 = 1.00,
    delta1fp2: f32 = 0.0,
    sfp2: f32 = 3.2,
    ndfp2: f32 = 0.0,
    vtzetafp2: f32 = -0.4e-3,
    vthetafp2: f32 = 0.0,
    mthetafp2: f32 = 0.0,
    alphafp2: f32 = 1e-2,

    // --- Drain-side Field-Plate 3 (FP3) Parameters (22) ---
    flagfp3: i32 = 0,
    lgfp3: f32 = 0.0,
    vtofp3: f32 = -74.5,
    cgfp3: f32 = 2.0e-4,
    tcgfp3: f32 = 0.0,
    flagfp3s: i32 = 1,
    cfp3s: f32 = 0e-19,
    flagfp3b: i32 = 1,
    ccfp3: f32 = 0.9e-10,
    tccfp3: f32 = 0.0,
    cbfp3: f32 = 0.0,
    tcbfp3: f32 = 0.0,
    vx0fp3: f32 = 1.2e5,
    mu0fp3: f32 = 0.2,
    betafp3: f32 = 1.00,
    delta1fp3: f32 = 0.0,
    sfp3: f32 = 3.2,
    ndfp3: f32 = 0.0,
    vtzetafp3: f32 = -0.4e-3,
    vthetafp3: f32 = 0.0,
    mthetafp3: f32 = 0.0,
    alphafp3: f32 = 1e-2,

    // --- Drain-side Field-Plate 4 (FP4) Parameters (22) ---
    flagfp4: i32 = 0,
    lgfp4: f32 = 0.0,
    vtofp4: f32 = -74.5,
    cgfp4: f32 = 2.0e-4,
    tcgfp4: f32 = 0.0,
    flagfp4s: i32 = 1,
    cfp4s: f32 = 0e-19,
    flagfp4b: i32 = 1,
    ccfp4: f32 = 0.9e-10,
    tccfp4: f32 = 0.0,
    cbfp4: f32 = 0.0,
    tcbfp4: f32 = 0.0,
    vx0fp4: f32 = 1.2e5,
    mu0fp4: f32 = 0.2,
    betafp4: f32 = 1.00,
    delta1fp4: f32 = 0.0,
    sfp4: f32 = 3.2,
    ndfp4: f32 = 0.0,
    vtzetafp4: f32 = -0.4e-3,
    vthetafp4: f32 = 0.0,
    mthetafp4: f32 = 0.0,
    alphafp4: f32 = 1e-2,

    // --- Gate Leakage Parameters (33) ---
    igmod: i32 = 0,
    fracig: f32 = 0,
    vjg: f32 = 1.1,
    pg_param1: f32 = 820e-3,
    pg_params: f32 = 1.00,
    ijs: f32 = 1.00e-12,
    vgsats: f32 = 1.00,
    fracs: f32 = 0.5,
    alphags: f32 = 1.0,
    pg_paramd: f32 = 1.00,
    ijd: f32 = 1.00e-12,
    vgsatd: f32 = 1.00,
    fracd: f32 = 0.5,
    alphagd: f32 = 1.0,
    pgsrecs: f32 = 0.5,
    irecs: f32 = 1.0e-18,
    vgsatqs: f32 = 2.00,
    betarecs: f32 = 2.00,
    pgsrecd: f32 = 0.8,
    irecd: f32 = 2e-5,
    vgsatqd: f32 = 0.8,
    betarecd: f32 = 0.25,
    kbdgates: f32 = 0,
    vbdgs: f32 = 600,
    pbdgs: f32 = 4.00,
    kbdgated: f32 = 0,
    vbdgd: f32 = 600,
    pbdgd: f32 = 4.00,
    igrecmod: i32 = 0,
    pgsrecs2: f32 = 0.5,
    irecs2: f32 = 1.0e-18,
    vgsatqs2: f32 = 2.00,
    betarecs2: f32 = 2.00,
    pgsrecd2: f32 = 0.8,
    irecd2: f32 = 2e-5,
    vgsatqd2: f32 = 0.8,
    betarecd2: f32 = 0.25,

    // --- p-GaN Junction Parameters (20) ---
    flagpgan: i32 = 0,
    pg_param_pgan: f32 = 0.05,
    ij_pgan: f32 = 2e-5,
    vgsat_pgan: f32 = 3,
    frac_pgan: f32 = 0.4,
    alphag_pgan: f32 = 1.0,
    pgsrec_pgan: f32 = 0.5,
    irec_pgan: f32 = 1e-21,
    vgsatq_pgan: f32 = 2e4,
    betarec_pgan: f32 = 1,
    pganrecmod: i32 = 0,
    pgsrec_pgan2: f32 = 0.5,
    irec_pgan2: f32 = 1e-21,
    vgsatq_pgan2: f32 = 2e4,
    betarec_pgan2: f32 = 1,
    vcsh0: f32 = 2.0,
    csh0: f32 = 6e-8,
    fc: f32 = 0.5,
    pgancshorder: i32 = 2,
    rsch0: f32 = 0,
    ohmicratio: f32 = 0,

    // --- Channel Breakdown Parameters (8) ---
    icbdmod: i32 = 0,
    cbddbmod: i32 = 1,
    ijscbd: f32 = 1.00e-9,
    vchbdgs: f32 = 50,
    pchbdgs: f32 = 4.00,
    ijdcbd: f32 = 1.00e-9,
    vchbdgd: f32 = 50,
    pchbdgd: f32 = 4.00,

    // --- Thermal Sub-circuit Parameters (2) ---
    rth: f32 = 25,
    cth: f32 = 1e-4,

    // --- RF gm-Dispersion Parameters (2) ---
    gmdisp: i32 = 0,
    taugmrf: f32 = 1e-3,

    // --- Layout and DC-to-RF Gate Resistance Parameters (4) ---
    rgsp: f32 = 0.0,
    ngcon: f32 = 1,
    lovg: f32 = 0,
    agate: f32 = 1,

    // --- Trapping Model Parameters (19) ---
    trapselect: i32 = 0,
    rintrap1: f32 = 1e9,
    ctrap: f32 = 1e-3,
    vttrap: f32 = 100,
    taut: f32 = 3e-5,
    alphat1: f32 = 1e-3,
    alphat2: f32 = 0.05,
    alphat3: f32 = 1e-3,
    tempt: f32 = 1e-4,
    vgltrapth: f32 = 10,
    vdltrapth: f32 = 100,
    rcapture: f32 = 10.0,
    remission: f32 = 50e-3,
    cdglag: f32 = 1e-6,
    rct1dl: f32 = -5e-3,
    rct1gl: f32 = 5e-3,
    rct2dl: f32 = 0.0,
    rct2gl: f32 = 0.0,
    isat: f32 = 1.0e-9,

    // --- Noise Model Parameters (6) ---
    noisemod: i32 = 0,
    shs: f32 = 3.0,
    shd: f32 = 3.0,
    kf: f32 = 1.0e-4,
    af: f32 = 2.0,
    ffe: f32 = 1.2,

    // --- Minimum Element Parameters (3) ---
    minr: f32 = 1e-3,
    minl: f32 = 1.0e-9,
    minc: f32 = 0.0,
};

// ============================================================================
// Instance Parameters (4)
// ============================================================================

pub const Instance = struct {
    w: f32 = 180.0e-6,
    l: f32 = 250.0e-9,
    ngf: f32 = 1,
    dtemp: f32 = 0.0,
};

// ============================================================================
// Constants
// ============================================================================

const KB: f64 = 1.380649e-23;
const Q_ELEC: f64 = 1.602176634e-19;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const TMIN_C: f64 = -273.15;
const TMAX_C: f64 = 1.0e6;
const LN10: f64 = 2.302585092994046;

// ============================================================================
// Inline helper: safe exponential with overflow guard (value-form)
//   explim(arg) = exp(min(arg, 80))
// ============================================================================

inline fn explimS(comptime S: type, arg: S) S {
    return arg.minC(80.0).exp();
}

// ============================================================================
// Inline helper: tanh_approx smoothing (value-form)
//   tanh(x) = sign(x) * (1 - 2/(exp(2|x|)+1)), guarded for overflow
// Region select on sign uses .val() (original branched on sign of xarg).
// ============================================================================

inline fn tanhApproxS(comptime S: type, xarg: S) S {
    const e2x = explimS(S, xarg.abs().scale(2.0));
    const th = e2x.addC(1.0); // exp(2|x|)+1
    const th_v = S.con(1.0).sub(S.con(2.0).div(th)); // 1 - 2/(e2x+1)
    return if (xarg.val() >= 0.0) th_v else th_v.neg();
}

// ============================================================================
// Inline helper: mmax smoothing (value-form)
//   sq branch (flaggum<0.5): 0.5*(x+y+sqrt(diff^2+s))
//   th branch (flaggum>=0.5): 0.5*(x+y+diff*tanh(1e-3/s * diff))
// flaggum is a model flag (x-independent) -> plain-f64 topology branch.
// ============================================================================

inline fn mmaxS(comptime S: type, xv: S, yv: S, s: f64, flaggum: f64) S {
    const diff = xv.sub(yv);
    const sm = if (flaggum < 0.5)
        diff.mul(diff).addC(s).sqrt()
    else blk: {
        const tanh_arg = diff.scale(1.0e-3 / (s + 1.0e-38));
        break :blk diff.mul(tanhApproxS(S, tanh_arg));
    };
    return xv.add(yv).add(sm).scale(0.5);
}

// ============================================================================
// Inline helper: calc_iq -- virtual-source channel current (value-form)
//
// Voltages (vgs_in, vgd_in) and trapfrac_dl are x-dependent -> S.
// All model/temperature parameters stay plain f64.
//
// Returns: (ids, qis, qid, qis0, qid0, qinv_v) as S
// ============================================================================

fn IqResultS(comptime S: type) type {
    return struct { ids: S, qis: S, qid: S, qis0: S, qid0: S, qinv_v: S };
}

inline fn calc_iq(
    comptime S: type,
    vgs_in: S,
    vgd_in: S,
    w_eff: f64,
    l_eff: f64,
    ngf_v: f64,
    cg_v: f64,
    vto_v: f64,
    ss_v: f64,
    nd_v: f64,
    alpha_v: f64,
    beta_v: f64,
    delta1_v: f64,
    delta2_v: f64,
    dibsat_v: f64,
    mu0_v: f64,
    vx0_v: f64,
    vtheta_v: f64,
    mtheta_v: f64,
    lambda_v: f64,
    flagsp_v: f64,
    flaggum_v: f64,
    mmaxs_v: f64,
    phi_t: f64,
    tamb: f64,
    tnom_k: f64,
    epsilon_v: f64,
    vzeta_v: f64,
    vtzeta_v: f64,
    type_f: f64,
    trapfrac_dl: S,
) IqResultS(S) {
    // VDS = VGS - VGD
    const vds = vgs_in.sub(vgd_in);
    const vds_abs = vds.abs();

    // Temperature-dependent threshold (x-independent)
    const vt_f = vto_v + vtzeta_v * (tamb - tnom_k);

    // Subthreshold slope factor with punchthrough (nd_v*|vds| is x-dependent)
    // n_sub = ss/(LN10*phi_t) + nd*|vds|
    const n_sub = vds_abs.scale(nd_v).addC(ss_v / (LN10 * phi_t));

    // DIBL: vsat_dibl = |vds| / (1 + (|vds|/dibsat)^beta)^(1/beta), else 0
    const vsat_dibl = if (dibsat_v > 0.0) blk: {
        const ratio = vds_abs.scale(1.0 / dibsat_v).maxC(1.0e-30);
        // (1 + ratio^beta)^(1/beta) = exp(log(1+exp(beta*log(ratio)))/beta)
        const pw = ratio.log().scale(beta_v).exp().addC(1.0).maxC(1.0e-30).log().scale(1.0 / beta_v).exp();
        break :blk vds_abs.div(pw);
    } else S.con(0.0);
    // delta_dibl = (delta1 - vsat_dibl*delta2)*|vds|
    const delta_dibl = vsat_dibl.scale(-delta2_v).addC(delta1_v).mul(vds_abs);
    const vt_dibl = delta_dibl.neg().addC(vt_f); // vt_f - delta_dibl

    // Vgs_max for symmetry: max(Vgs, Vgd)
    const vgs_max = mmaxS(S, vgs_in, vgd_in, mmaxs_v, flaggum_v);

    // Fermi function for weak-to-strong transition
    // ff_arg = (vgs_max - vt_dibl + flagsp*alpha*phi_t*0.5)/(alpha*phi_t)
    const inv_alpha_phi = 1.0 / (alpha_v * phi_t + 1.0e-30);
    const ff_arg = vgs_max.sub(vt_dibl).addC(flagsp_v * alpha_v * phi_t * 0.5).scale(inv_alpha_phi);
    const ff_exp = explimS(S, ff_arg);
    const ff_v = S.con(1.0).div(ff_exp.addC(1.0)); // 1/(1+ff_exp)

    // Charge at virtual source Qinv,v
    // eta_num = vgs_max - (vt_dibl - flagsp*0.1*alpha*phi_t*ff_v)
    const eta_num = vgs_max.sub(vt_dibl.sub(ff_v.scale(flagsp_v * 0.1 * alpha_v * phi_t)));
    const two_n_phi = n_sub.scale(2.0 * phi_t); // 2*n_sub*phi_t
    const eta = eta_num.div(two_n_phi.addC(1.0e-30));
    // qinv_v = cg * two_n_phi * log(1 + explim(eta))
    const qinv_v = two_n_phi.scale(cg_v).mul(explimS(S, eta).addC(1.0).log());

    // Mobility and velocity: temperature dependent (temp part is f64)
    const temp_ratio = tamb / (tnom_k + 1.0e-30);
    const mu_denom_temp = contract.fmath.exp(epsilon_v * contract.fmath.log(@max(temp_ratio, 1.0e-30)));
    // mu_f = mu0 / (mu_denom_temp * (1 + mtheta*qinv_v/cg))
    const mu_denom = qinv_v.scale(mtheta_v / (cg_v + 1.0e-30)).addC(1.0).scale(mu_denom_temp);
    const mu_f = S.con(mu0_v).div(mu_denom.addC(1.0e-30));
    // vx_t = vx0*(1+vzeta*tnom)/(1+vzeta*tamb) * (1 + lambda*|vds|/l) / (1 + vtheta*qinv_v/cg)
    const vx_pref = vx0_v * (1.0 + vzeta_v * tnom_k) / (1.0 + vzeta_v * tamb + 1.0e-30);
    const vx_num = vds_abs.scale(lambda_v / (l_eff + 1.0e-30)).addC(1.0).scale(vx_pref);
    const vx_den = qinv_v.scale(vtheta_v / (cg_v + 1.0e-30)).addC(1.0);
    const vx_t = vx_num.div(vx_den);

    // Combined velocity: diffusion (weak) + saturation (strong)
    // vxf = 2*ff_v*phi_t*mu_f/l + (1-ff_v)*vx_t
    const vxf = ff_v.mul(mu_f).scale(2.0 * phi_t / (l_eff + 1.0e-30)).add(ff_v.neg().addC(1.0).mul(vx_t));

    // VDSAT
    // vdsat_s = vx_t*l/mu_f
    const vdsat_s = vx_t.scale(l_eff).div(mu_f.addC(1.0e-30));
    // vdsat_s1 = vdsat_s*sqrt(1 + 2*qinv_v/(cg*vdsat_s)) - vdsat_s
    const vdsat_s1_arg = qinv_v.scale(2.0).div(vdsat_s.scale(cg_v).addC(1.0e-30)).addC(1.0).maxC(1.0e-30);
    const vdsat_s1 = vdsat_s.mul(vdsat_s1_arg.sqrt()).sub(vdsat_s);
    // vdsat = vdsat_s*(1-ff_v) + two_n_phi*ff_v
    const one_m_ff = ff_v.neg().addC(1.0);
    const vdsat = vdsat_s.mul(one_m_ff).add(two_n_phi.mul(ff_v));
    const vdsat_1 = vdsat_s1.mul(one_m_ff).add(two_n_phi.mul(ff_v));

    // Saturation function Fsd
    // vds_ratio_s = max(0, vds/vdsat_1)
    const vds_ratio_s = vds.div(vdsat_1.addC(1.0e-30)).maxC(0.0);
    const fsd = powSmoothInv(S, vds_ratio_s, beta_v);
    const vds_ratio_d = vds.neg().div(vdsat_1.addC(1.0e-30)).maxC(0.0);
    const fds = powSmoothInv(S, vds_ratio_d, beta_v);
    const vdx = vds.mul(fsd);
    const vsx = vds.neg().mul(fds);

    // Fermi functions for source and drain charge
    const ffs_arg = vgs_in.sub(vt_dibl).addC(flagsp_v * alpha_v * phi_t * 0.5).scale(inv_alpha_phi);
    const ffs = S.con(1.0).div(explimS(S, ffs_arg).addC(1.0));
    const ffd_arg = vgd_in.sub(vt_dibl).addC(flagsp_v * alpha_v * phi_t * 0.5).scale(inv_alpha_phi);
    const ffd = S.con(1.0).div(explimS(S, ffd_arg).addC(1.0));

    // Source and drain charge
    // qis_eta = (vgd_in - vsx - (vt_dibl - flagsp*0.1*alpha*phi_t*ffs))/two_n_phi
    const inv_two_n_phi = two_n_phi.addC(1.0e-30);
    const qis_eta = vgd_in.sub(vsx).sub(vt_dibl.sub(ffs.scale(flagsp_v * 0.1 * alpha_v * phi_t))).div(inv_two_n_phi);
    const qis_val = two_n_phi.scale(cg_v).mul(explimS(S, qis_eta).addC(1.0).log());
    const qid_eta = vgs_in.sub(vdx).sub(vt_dibl.sub(ffd.scale(flagsp_v * 0.1 * alpha_v * phi_t))).div(inv_two_n_phi);
    const qid_val = two_n_phi.scale(cg_v).mul(explimS(S, qid_eta).addC(1.0).log());

    // Current via DSC
    // vdsc = (qis_val - qid_val)/cg
    const vdsc = qis_val.sub(qid_val).scale(1.0 / (cg_v + 1.0e-30));
    // fsat = fsat_arg / (1 + |fsat_arg|^beta)^(1/beta), fsat_arg = vdsc/vdsat
    const fsat_arg = vdsc.div(vdsat.addC(1.0e-30));
    const fsat = powSmoothInvSigned(S, fsat_arg, beta_v);
    const vel = vxf.mul(fsat);
    // ids = type_f*w*ngf*(qis+qid)*0.5*vel*trapfrac_dl
    const ids = qis_val.add(qid_val).scale(type_f * w_eff * ngf_v * 0.5).mul(vel).mul(trapfrac_dl);

    // Also compute qis0, qid0 (without DIBL for charge model): vt_0 = vt_f
    const vt_0 = vt_f;
    const eta_s0 = vgd_in.sub(vsx).addC(-vt_0).add(ffs.scale(flagsp_v * 0.1 * alpha_v * phi_t)).div(inv_two_n_phi);
    const qis0_val = two_n_phi.scale(cg_v).mul(explimS(S, eta_s0).addC(1.0).log());
    const eta_d0 = vgs_in.sub(vdx).addC(-vt_0).add(ffd.scale(flagsp_v * 0.1 * alpha_v * phi_t)).div(inv_two_n_phi);
    const qid0_val = two_n_phi.scale(cg_v).mul(explimS(S, eta_d0).addC(1.0).log());

    return .{ .ids = ids, .qis = qis_val, .qid = qid_val, .qis0 = qis0_val, .qid0 = qid0_val, .qinv_v = qinv_v };
}

// Helper: 1/(1+max(x,1e-30)^beta)^(1/beta) for x>=0 (soft saturation)
inline fn powSmoothInv(comptime S: type, x: S, beta_v: f64) S {
    const xg = x.maxC(1.0e-30);
    const denom = xg.log().scale(beta_v).exp().addC(1.0).maxC(1.0e-30).log().scale(1.0 / beta_v).exp();
    return S.con(1.0).div(denom);
}

// Helper: x / (1 + |x|^beta)^(1/beta) (odd soft-saturation)
inline fn powSmoothInvSigned(comptime S: type, x: S, beta_v: f64) S {
    const xabs = x.abs().maxC(1.0e-30);
    const denom = xabs.log().scale(beta_v).exp().addC(1.0).maxC(1.0e-30).log().scale(1.0 / beta_v).exp();
    return x.div(denom);
}

// ============================================================================
// Inline helper: calc_ig_fwd -- gate leakage current for one diode branch
// (value-form). vg_jn is x-dependent -> S; all parameters f64.
// ============================================================================

inline fn calc_ig_fwd(
    comptime S: type,
    vg_jn: S,
    w_eff: f64,
    ngf_v: f64,
    ij_v: f64,
    pg_param_v: f64,
    pg_param1_v: f64,
    vjg_v: f64,
    vgsat_v: f64,
    frac_v: f64,
    alphag_v: f64,
    kbd_v: f64,
    vbd_v: f64,
    pbd_v: f64,
    phi_t: f64,
    tfac_diode: f64,
) S {
    const scale = w_eff * ngf_v * ij_v * tfac_diode;
    const base_exp = contract.fmath.exp(@min(-pg_param1_v * vjg_v / phi_t, 80.0)); // f64: no x

    // Gate breakdown term (x-dependent via vg_jn); kbd flag is f64 topology
    const igd_bd = if (kbd_v > 0.0) blk: {
        // kbd*(explim(-pbd*(vg+vbd) - pg1*vjg/phi) - explim(-pbd*vbd - pg1*vjg/phi))
        const a = explimS(S, vg_jn.addC(vbd_v).scale(-pbd_v).addC(-pg_param1_v * vjg_v / phi_t));
        const b = contract.fmath.exp(@min(-pbd_v * vbd_v - pg_param1_v * vjg_v / phi_t, 80.0));
        break :blk a.addC(-b).scale(kbd_v);
    } else S.con(0.0);

    // Forward current without high injection
    // i_nohinj = scale*base_exp*(explim(pg*vg/phi)-1) - scale*igd_bd
    const i_nohinj = explimS(S, vg_jn.scale(pg_param_v / phi_t)).addC(-1.0).scale(scale * base_exp).sub(igd_bd.scale(scale));

    // High injection current (unscaled)
    // i_hinj_un = scale*(explim(frac_eff*pg*vg/phi) - base_exp - igd_bd)
    const frac_eff = @max(frac_v, 1.0e-30);
    const i_hinj_un = explimS(S, vg_jn.scale(frac_eff * pg_param_v / phi_t)).addC(-base_exp).sub(igd_bd).scale(scale);

    // Evaluate both at vgsat for shift (vgsat is f64; but igd_bd carries x!)
    // i_nohinj_vgsat = scale*base_exp*(explim(pg*vgsat/phi)-1) - scale*igd_bd
    const i_nohinj_vgsat = igd_bd.scale(-scale).addC(scale * base_exp * (contract.fmath.exp(@min(pg_param_v * vgsat_v / phi_t, 80.0)) - 1.0));
    // i_hinj_un_vgsat = scale*(explim(frac_eff*pg*vgsat/phi) - base_exp - igd_bd)
    const i_hinj_un_vgsat = igd_bd.neg().addC(contract.fmath.exp(@min(frac_eff * pg_param_v * vgsat_v / phi_t, 80.0)) - base_exp).scale(scale);
    const shift_ratio = i_nohinj_vgsat.div(i_hinj_un_vgsat.addC(1.0e-38));
    const i_hinj = if (frac_v > 1.0e-30) i_hinj_un.mul(shift_ratio) else i_nohinj_vgsat;

    // Fermi smoothing between regimes
    // ff_vg_arg = (vg - vgsat + 0.5*alphag^2*phi)/(alphag^2*phi)
    const denom_ff = alphag_v * alphag_v * phi_t + 1.0e-30;
    const ff_vg_arg = vg_jn.addC(-vgsat_v + 0.5 * alphag_v * alphag_v * phi_t).scale(1.0 / denom_ff);
    const ff_vg = S.con(1.0).div(explimS(S, ff_vg_arg).addC(1.0));

    // ff_vg*i_nohinj + (1-ff_vg)*i_hinj
    return ff_vg.mul(i_nohinj).add(ff_vg.neg().addC(1.0).mul(i_hinj));
}

// ============================================================================
// Inline helper: calc_ig_rec -- reverse recombination current (value-form)
// ============================================================================

inline fn calc_ig_rec(
    comptime S: type,
    vg_jn: S,
    w_eff: f64,
    ngf_v: f64,
    irec_v: f64,
    pgsrec_v: f64,
    vgsatq_v: f64,
    betarec_v: f64,
    phi_t: f64,
    tfac_diode: f64,
) S {
    const scale = w_eff * ngf_v * irec_v * tfac_diode;
    // frec = -vg / (1 + (|vg|/vgsatq)^betarec)^(1/betarec)
    const abs_ratio = vg_jn.abs().scale(1.0 / (vgsatq_v + 1.0e-30)).maxC(1.0e-30);
    const denom = abs_ratio.log().scale(betarec_v).exp().addC(1.0).maxC(1.0e-30).log().scale(1.0 / betarec_v).exp();
    const frec = vg_jn.neg().div(denom);
    // -scale*(explim(pgsrec*frec/phi)-1)
    return explimS(S, frec.scale(pgsrec_v / phi_t)).addC(-1.0).scale(-scale);
}

// ============================================================================
// Inline helper: calc_capt -- temperature-dependent capacitance (pure f64)
// ============================================================================

inline fn calc_capt(c_in: f64, tempco: f64, tdut: f64, tnom_k: f64) f64 {
    const c_out = c_in * (1.0 + tempco * (tdut - tnom_k));
    return @max(c_out, 0.01 * c_in);
}

// ============================================================================
// Inline helper: fringing charge (value-form). v_term is x-dependent -> S.
// ============================================================================

inline fn fringing_charge(
    comptime S: type,
    v_term: S,
    w_eff: f64,
    ngf_v: f64,
    cof_m0: f64,
    cof_m: f64,
    nfrin_v: f64,
    vtfrin_v: f64,
) S {
    // bias_indep = cof_m0*v_term
    const bias_indep = v_term.scale(cof_m0);
    // arg = (v_term - vtfrin)/nfrin
    const arg = v_term.addC(-vtfrin_v).scale(1.0 / (nfrin_v + 1.0e-30));
    // bias_dep = cof_m*nfrin*log(1 + explim(arg))
    const bias_dep = explimS(S, arg).addC(1.0).log().scale(cof_m * nfrin_v);
    return bias_indep.add(bias_dep).scale(w_eff * ngf_v);
}

// ============================================================================
// Inline helper: FP cross-coupled charge (value-form)
//   Qc = cc_cap*w*n_fp*phi*log(1 + explim((v_gfp - vto_fp)/(n_fp*phi)))
//   n_fp = sfp/(LN10*phi)
// v_gate, v_fp_node are x-dependent -> S; parameters f64.
// ============================================================================

inline fn calc_fp_cc_charge(
    comptime S: type,
    v_gate: S,
    v_fp_node: S,
    cc_cap: f64,
    vto_fp: f64,
    sfp: f64,
    alpha_fp: f64,
    phi_t_v: f64,
    w_v: f64,
    flagsp_v: f64,
) S {
    _ = alpha_fp;
    _ = flagsp_v;
    const n_fp = sfp / (LN10 * phi_t_v);
    const v_gfp = v_gate.sub(v_fp_node);
    const eta_fp = v_gfp.addC(-vto_fp).scale(1.0 / (n_fp * phi_t_v + 1.0e-30));
    return explimS(S, eta_fp).addC(1.0).log().scale(cc_cap * w_v * n_fp * phi_t_v);
}

// ============================================================================
// Bias-independent (x-independent) precomputed quantities.
// Geometry and parasitic resistance values that depend only on model/instance
// parameters (NOT on temperature or terminal voltages).
// ============================================================================

const Prep = struct {
    tnom_k: f64,
    rcs_w_base: f64,
    rcd_w_base: f64,
    g_rg1: f64,
    g_rg2: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    _ = l;
    const ngf: f64 = @as(f64, instance.ngf);
    const rcs: f64 = @as(f64, model.rcs);
    const rcd: f64 = @as(f64, model.rcd);
    const rsh: f64 = @as(f64, model.rsh);
    const flagres: f64 = @floatFromInt(model.flagres);
    const rgsp: f64 = @as(f64, model.rgsp);
    const ngcon: f64 = @as(f64, model.ngcon);
    const lovg: f64 = @as(f64, model.lovg);
    const agate: f64 = @as(f64, model.agate);
    const minr: f64 = @as(f64, model.minr);

    const tnom_k: f64 = @as(f64, model.tnom) + 273.15;

    // Contact resistance base values (geometry only, no temperature)
    const rcs_w_base = if (flagres < 0.5) rcs / (w * ngf) else (rcs / w + rsh * @as(f64, model.lgs) / w) / ngf;
    const rcd_w_base = if (flagres < 0.5) rcd / (w * ngf) else (rcd / w + rsh * @as(f64, model.lgd) / w) / ngf;

    // Gate resistance (pure geometry, no temperature)
    const rg_dc = rgsp / (ngf * ngcon + 1.0e-30) * (lovg + w / (ngcon + 1.0e-30));
    const rg1 = rgsp / (ngf * ngcon + 1.0e-30) * (lovg + agate * w / (ngcon + 1.0e-30));
    const rg2 = rg_dc - rg1;
    const g_rg1 = if (rg1 > minr) 1.0 / rg1 else GSHORT;
    const g_rg2 = if (rg2 > minr) 1.0 / rg2 else GSHORT;

    return .{
        .tnom_k = tnom_k,
        .rcs_w_base = rcs_w_base,
        .rcd_w_base = rcd_w_base,
        .g_rg1 = g_rg1,
        .g_rg2 = g_rg2,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// Physics function: eval (value-form)
//
// Full MVSG current contributions. Computes:
//   1. Temperature setup (self-heating from dt node)
//   2. Contact and sheet resistances (src, drc nodes)
//   3. Gate resistance network (gi1, gi2 nodes)
//   4. Intrinsic FET channel current (si->di)
//   5. Access region transistors (SAR: fps4->src, DAR: drc->fp4)
//   6. Field-plate transistors (FPS1-4, FP1-4)
//   7. Gate leakage diodes (Schottky forward + reverse recombination)
//   8. p-GaN module (gi2p node)
//   9. Channel breakdown
//   10. Trapping sub-circuits (vtrap / vdl+vgl nodes)
//   11. gm-dispersion (xt1, xt2 nodes)
//   12. Thermal self-heating power injection
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // --- Node indices ---
    const D = @intFromEnum(U.d);
    const G = @intFromEnum(U.g);
    const S_ = @intFromEnum(U.s);
    const B = @intFromEnum(U.b);
    const DT = @intFromEnum(U.dt);
    const GI1 = @intFromEnum(U.gi1);
    const GI2 = @intFromEnum(U.gi2);
    const GI2P = @intFromEnum(U.gi2p);
    const SI = @intFromEnum(U.si);
    const DI = @intFromEnum(U.di);
    const SRC = @intFromEnum(U.src);
    const DRC = @intFromEnum(U.drc);
    const FPS1 = @intFromEnum(U.fps1);
    const FPS2 = @intFromEnum(U.fps2);
    const FPS3 = @intFromEnum(U.fps3);
    const FPS4 = @intFromEnum(U.fps4);
    const FP1 = @intFromEnum(U.fp1);
    const FP2 = @intFromEnum(U.fp2);
    const FP3 = @intFromEnum(U.fp3);
    const FP4 = @intFromEnum(U.fp4);
    const XT1 = @intFromEnum(U.xt1);
    const XT2 = @intFromEnum(U.xt2);
    const VTRAP = @intFromEnum(U.vtrap);
    const VDL = @intFromEnum(U.vdl);
    const VGL = @intFromEnum(U.vgl);

    // --- Precomputed geometry from PrepCache ---
    const tnom_k: f64 = pc.tnom_k;
    const rcs_w_base = pc.rcs_w_base;
    const rcd_w_base = pc.rcd_w_base;
    const g_rg1 = pc.g_rg1;
    const g_rg2 = pc.g_rg2;

    // --- Cast model parameters to f64 (x-independent) ---
    const type_f: f64 = @floatFromInt(model.type_);
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const ngf: f64 = @as(f64, instance.ngf);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const cg: f64 = @as(f64, model.cg);
    const vto: f64 = @as(f64, model.vto);
    const ss: f64 = @as(f64, model.ss);
    const nd: f64 = @as(f64, model.nd);
    const alpha_m: f64 = @as(f64, model.alpha);
    const beta_m: f64 = @as(f64, model.beta);
    const delta1_m: f64 = @as(f64, model.delta1);
    const delta2_m: f64 = @as(f64, model.delta2);
    const dibsat_m: f64 = @as(f64, model.dibsat);
    const mu0_m: f64 = @as(f64, model.mu0);
    const vx0_m: f64 = @as(f64, model.vx0);
    const vtheta_m: f64 = @as(f64, model.vtheta);
    const mtheta_m: f64 = @as(f64, model.mtheta);
    const lambda_m: f64 = @as(f64, model.lambda);
    const flagsp: f64 = @floatFromInt(model.flagsp);
    const flaggum: f64 = @floatFromInt(model.flaggum);
    const mmaxs_m: f64 = @as(f64, model.mmaxs);
    const epsilon_m: f64 = @as(f64, model.epsilon);
    const vzeta_m: f64 = @as(f64, model.vzeta);
    const vtzeta_m: f64 = @as(f64, model.vtzeta);
    const rsh: f64 = @as(f64, model.rsh);
    const rct1: f64 = @as(f64, model.rct1);
    const rct2: f64 = @as(f64, model.rct2);
    const rth: f64 = @as(f64, model.rth);
    const minr: f64 = @as(f64, model.minr);
    const minl: f64 = @as(f64, model.minl);
    const igmod: f64 = @floatFromInt(model.igmod);
    const trapselect: f64 = @floatFromInt(model.trapselect);
    const gmdisp: f64 = @floatFromInt(model.gmdisp);
    const icbdmod: f64 = @floatFromInt(model.icbdmod);
    const flagpgan: f64 = @floatFromInt(model.flagpgan);

    // --- Read node voltages (x-dependent) ---
    const v_d = x[D];
    const v_g = x[G];
    const v_s = x[S_];
    const v_b = x[B];
    const v_dt = x[DT];
    const v_gi1 = x[GI1];
    const v_gi2 = x[GI2];
    const v_gi2p = x[GI2P];
    const v_si = x[SI];
    const v_di = x[DI];
    const v_src = x[SRC];
    const v_drc = x[DRC];
    const v_fps1 = x[FPS1];
    const v_fps2 = x[FPS2];
    const v_fps3 = x[FPS3];
    const v_fps4 = x[FPS4];
    const v_fp1 = x[FP1];
    const v_fp2 = x[FP2];
    const v_fp3 = x[FP3];
    const v_fp4 = x[FP4];
    const v_xt1 = x[XT1];
    const v_xt2 = x[XT2];
    const v_vtrap = x[VTRAP];
    const v_vdl = x[VDL];
    const v_vgl = x[VGL];

    // --- Temperature ---
    // t_sh (self-heating) is x-dependent (v_dt); temperature feeds phi_t which
    // enters exponentials. To keep the Jacobian faithful with the original AND
    // avoid routing x through f64, we mirror the original: t_sh depends on v_dt.
    // The original computed phi_t, tfac_diode etc. from tamb which included v_dt.
    // Those are used as constants inside the S chains. Since the original stored
    // these as f64 (they were plain f64 there too, because x was f64), the
    // self-heating -> phi_t coupling was ALWAYS treated as a constant per-eval in
    // the pointer contract. We reproduce that by evaluating temperature at the
    // f64 value of v_dt (region-style .val() read), matching the old numerics.
    const t_sh = if (rth > 0.0) v_dt.val() else 0.0;
    const tamb_raw = tnom_k + dtemp + t_sh;
    const tamb = @max(@min(tamb_raw, TMAX_C + 273.15), TMIN_C + 273.15);
    const phi_t = KB * tamb / Q_ELEC;
    const tfac_diode = (tamb / tnom_k) * (tamb / tnom_k) * (tamb / tnom_k); // (T/T0)^3
    const tcg: f64 = @as(f64, model.tcg);
    const cg_t = calc_capt(cg, tcg, tamb, tnom_k);

    // --- Contact Resistances (f64 conductances) ---
    // rcs_w_base, rcd_w_base from PrepCache
    const dt_from_nom = tamb - tnom_k;
    const r_temp_factor = 1.0 + rct1 * dt_from_nom + rct2 * dt_from_nom * dt_from_nom;
    const r_si = @max(rcs_w_base * r_temp_factor, 0.1 * rcs_w_base);
    const r_di = @max(rcd_w_base * r_temp_factor, 0.1 * rcd_w_base);
    const g_rcs = if (r_si > minr) 1.0 / r_si else GSHORT;
    const g_rcd = if (r_di > minr) 1.0 / r_di else GSHORT;

    // Contact resistance currents: s->src, d->drc
    const i_rcs = v_s.sub(v_src).scale(g_rcs);
    const i_rcd = v_d.sub(v_drc).scale(g_rcd);

    // --- Gate Resistance ---
    // g_rg1, g_rg2 from PrepCache

    // Gate resistance currents: g->gi1->gi2
    const i_rg1 = v_g.sub(v_gi1).scale(g_rg1);
    const i_rg2 = v_gi1.sub(v_gi2).scale(g_rg2);

    // --- p-GaN Junction ---
    const v_pgan = v_gi2p.sub(v_gi2);
    const ohmfrac: f64 = @as(f64, model.ohmicratio);
    const rsch0: f64 = @as(f64, model.rsch0);
    const schottky_frac = 1.0 - ohmfrac;

    const pgan_active = flagpgan > 0.5;
    const pg_param_pgan: f64 = @as(f64, model.pg_param_pgan);
    const ij_pgan: f64 = @as(f64, model.ij_pgan);

    // Forward current
    const i_pgan_fwd = if (pgan_active) calc_ig_fwd(
        S,
        v_pgan,
        w * schottky_frac,
        ngf,
        ij_pgan,
        pg_param_pgan,
        0.0,
        0.0,
        @as(f64, model.vgsat_pgan),
        @as(f64, model.frac_pgan),
        @as(f64, model.alphag_pgan),
        0.0,
        0.0,
        0.0,
        phi_t,
        tfac_diode,
    ) else S.con(0.0);

    // Reverse recombination
    const i_pgan_rec = if (pgan_active) calc_ig_rec(
        S,
        v_pgan,
        w * schottky_frac,
        ngf,
        @as(f64, model.irec_pgan),
        @as(f64, model.pgsrec_pgan),
        @as(f64, model.vgsatq_pgan),
        @as(f64, model.betarec_pgan),
        phi_t,
        tfac_diode,
    ) else S.con(0.0);

    // Secondary p-GaN recombination
    const pganrecmod: f64 = @floatFromInt(model.pganrecmod);
    const i_pgan_rec2 = if (pgan_active and pganrecmod > 0.5) calc_ig_rec(
        S,
        v_pgan,
        w * schottky_frac,
        ngf,
        @as(f64, model.irec_pgan2),
        @as(f64, model.pgsrec_pgan2),
        @as(f64, model.vgsatq_pgan2),
        @as(f64, model.betarec_pgan2),
        phi_t,
        tfac_diode,
    ) else S.con(0.0);

    const i_dsch = i_pgan_fwd.add(i_pgan_rec).add(i_pgan_rec2);

    // p-GaN ohmic resistance (parallel path gi2p -> gi2)
    const g_rsch = if (pgan_active and rsch0 > 0.0 and ohmfrac > 0.0) w * ohmfrac * ngf / rsch0 else 0.0;
    const i_rsch = v_pgan.scale(g_rsch);

    // gi2p also connects to gi2 via GMIN
    const i_pgan_total = i_dsch.add(i_rsch).add(v_pgan.scale(GMIN));

    // --- Trapping ---
    const tempt: f64 = @as(f64, model.tempt);
    const t_trapfac = @max(1.0 + tempt * (tamb - tnom_k), 0.1);

    const trap1_active = trapselect > 0.5 and trapselect < 1.5;
    const trap2_active = trapselect > 1.5;

    // trapselect=1: RDS,On increase via vtrap node
    const alphat1: f64 = @as(f64, model.alphat1);
    const alphat2: f64 = @as(f64, model.alphat2);
    const alphat3: f64 = @as(f64, model.alphat3);
    const vttrap: f64 = @as(f64, model.vttrap);
    const rintrap1: f64 = @as(f64, model.rintrap1);
    const v_dg_trap = v_di.sub(v_gi2);
    // vtcol0 = alphat1*|v_dg_trap| + explim((v_dg_trap - vttrap - alphat3*v_vtrap)/alphat2)
    const vtcol0 = v_dg_trap.abs().scale(alphat1).add(explimS(S, v_dg_trap.addC(-vttrap).sub(v_vtrap.scale(alphat3)).scale(1.0 / (alphat2 + 1.0e-30))));
    const i_vtrap = if (trap1_active) v_vtrap.sub(vtcol0).scale(1.0 / (rintrap1 + 1.0e-30)) else S.con(0.0);
    // drsht = 1 + v_vtrap*t_trapfac (x-dependent when trap1 active)
    const drsht = if (trap1_active) v_vtrap.scale(t_trapfac).addC(1.0) else S.con(1.0);

    // trapselect=2: Gate-lag/Drain-lag
    const vdltrapth: f64 = @as(f64, model.vdltrapth);
    const vgltrapth: f64 = @as(f64, model.vgltrapth);
    const rcapture: f64 = @as(f64, model.rcapture);
    const remission: f64 = @as(f64, model.remission);
    _ = @as(f64, model.isat); // isat_trap reserved for future diode clamp

    const v_dl_diff = v_di.sub(v_vdl);
    const g_dl = if (v_dl_diff.val() > 0.0) 1.0 / rcapture else 1.0 / remission;
    const i_dl_res = v_dl_diff.scale(g_dl);
    const v_gl_diff = v_gi2.sub(v_vgl);
    const g_gl = if (v_gl_diff.val() > 0.0) 1.0 / rcapture else 1.0 / remission;
    const i_gl_res = v_gl_diff.scale(g_gl);
    const qfrac_d = v_vdl.abs().scale(1.0 / (vdltrapth + 1.0e-30));
    const qfrac_g = v_vgl.abs().scale(1.0 / (vgltrapth + 1.0e-30));

    const i_vdl = if (trap2_active) i_dl_res else S.con(0.0);
    const i_vgl = if (trap2_active) i_gl_res else S.con(0.0);
    // trapfrac_dl = 1/(1 + qfrac_d + qfrac_g)
    const trapfrac_dl = if (trap2_active) S.con(1.0).div(qfrac_d.add(qfrac_g).addC(1.0)) else S.con(1.0);

    // --- Access Region Voltages ---
    // Source access: SAR
    const lgs: f64 = @as(f64, model.lgs);
    const cgrs: f64 = @as(f64, model.cgrs);
    const mu0rs: f64 = @as(f64, model.mu0rs);
    const vtors: f64 = @as(f64, model.vtors);
    const v_ig_s = vtors + 1.0 / (rsh * cgrs * mu0rs + 1.0e-30); // f64
    const vsar_s = mmaxS(S, v_src.sub(v_di), v_src.sub(v_si), mmaxs_m, flaggum);
    const vgs_rs = vsar_s.neg().addC(v_ig_s); // v_ig_s - vsar_s

    // Drain access: DAR (v_ig_d depends on drsht which is x-dependent)
    const lgd: f64 = @as(f64, model.lgd);
    const cgrd: f64 = @as(f64, model.cgrd);
    const mu0rd: f64 = @as(f64, model.mu0rd);
    const vtord: f64 = @as(f64, model.vtord);
    // v_ig_d = vtord + 1/(drsht*rsh*cgrd*mu0rd)
    const v_ig_d = drsht.scale(rsh * cgrd * mu0rd).addC(1.0e-30).pow(-1.0).addC(vtord);
    const vdar_d = mmaxS(S, v_drc.sub(v_di), v_drc.sub(v_si), mmaxs_m, flaggum);
    const vgs_rd = v_ig_d.sub(vdar_d);

    // --- Intrinsic FET ---
    const v_gi2_si = v_gi2.sub(v_si).scale(type_f);
    const v_gi2_di = v_gi2.sub(v_di).scale(type_f);
    const intr = calc_iq(
        S,
        v_gi2_si,
        v_gi2_di,
        w,
        l,
        ngf,
        cg_t,
        vto,
        ss,
        nd,
        alpha_m,
        beta_m,
        delta1_m,
        delta2_m,
        dibsat_m,
        mu0_m,
        vx0_m,
        vtheta_m,
        mtheta_m,
        lambda_m,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        vtzeta_m,
        type_f,
        trapfrac_dl,
    );
    const i_ds_intr = intr.ids;

    // --- Source Access Region transistor (SAR): fps4 -> src ---
    const sar_active = lgs > minl;
    const v_sar_gs = if (sar_active) vgs_rs.sub(v_fps4).scale(type_f) else S.con(0.0);
    const v_sar_gd = if (sar_active) vgs_rs.sub(v_src).scale(type_f) else S.con(0.0);
    const sar = if (sar_active) calc_iq(
        S,
        v_sar_gs,
        v_sar_gd,
        w,
        lgs,
        ngf,
        cgrs,
        vtors,
        @as(f64, model.srs),
        @as(f64, model.ndrs),
        @as(f64, model.alphars),
        @as(f64, model.betars),
        @as(f64, model.delta1rs),
        0.0,
        0.0,
        mu0rs,
        @as(f64, model.vx0rs),
        @as(f64, model.vthetars),
        @as(f64, model.mthetars),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        0.0,
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_ds_sar = sar.ids;
    const g_sar_short = if (!sar_active) GSHORT else 0.0;
    const i_sar_short = v_fps4.sub(v_src).scale(g_sar_short);

    // --- Drain Access Region transistor (DAR): drc -> fp4 ---
    const dar_active = lgd > minl;
    const v_dar_gs = if (dar_active) vgs_rd.sub(v_drc).scale(type_f) else S.con(0.0);
    const v_dar_gd = if (dar_active) vgs_rd.sub(v_fp4).scale(type_f) else S.con(0.0);
    const dar = if (dar_active) calc_iq(
        S,
        v_dar_gs,
        v_dar_gd,
        w,
        lgd,
        ngf,
        cgrd,
        vtord,
        @as(f64, model.srd),
        @as(f64, model.ndrd),
        @as(f64, model.alphard),
        @as(f64, model.betard),
        @as(f64, model.delta1rd),
        0.0,
        0.0,
        mu0rd,
        @as(f64, model.vx0rd),
        @as(f64, model.vthetard),
        @as(f64, model.mthetard),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        0.0,
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_ds_dar = dar.ids;
    const g_dar_short = if (!dar_active) GSHORT else 0.0;
    const i_dar_short = v_drc.sub(v_fp4).scale(g_dar_short);

    // --- Field-Plate Transistors ---
    // Source-side FP1: si -> fps1
    const lgfps1: f64 = @as(f64, model.lgfps1);
    const fps1_active = lgfps1 > minl;
    const fps1_gate_node = if (@as(f64, @floatFromInt(model.flagfps1)) > 0.5) v_gi2 else v_si;
    const v_fps1_gs = if (fps1_active) fps1_gate_node.sub(v_si).scale(type_f) else S.con(0.0);
    const v_fps1_gd = if (fps1_active) fps1_gate_node.sub(v_fps1).scale(type_f) else S.con(0.0);
    const cgfps1_t = calc_capt(@as(f64, model.cgfps1), @as(f64, model.tcgfps1), tamb, tnom_k);
    const vtofps1_t: f64 = @as(f64, model.vtofps1) + @as(f64, model.vtzetafps1) * (tamb - tnom_k);
    const fps1 = if (fps1_active) calc_iq(
        S,
        v_fps1_gs,
        v_fps1_gd,
        w,
        lgfps1,
        ngf,
        cgfps1_t,
        vtofps1_t,
        @as(f64, model.sfps1),
        @as(f64, model.ndfps1),
        @as(f64, model.alphafps1),
        @as(f64, model.betafps1),
        @as(f64, model.delta1fps1),
        0.0,
        0.0,
        @as(f64, model.mu0fps1),
        @as(f64, model.vx0fps1),
        @as(f64, model.vthetafps1),
        @as(f64, model.mthetafps1),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafps1),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fps1 = fps1.ids;
    const g_fps1_short = if (!fps1_active) GSHORT else 0.0;
    const i_fps1_short = v_si.sub(v_fps1).scale(g_fps1_short);

    // Source-side FP2: fps1 -> fps2
    const lgfps2: f64 = @as(f64, model.lgfps2);
    const fps2_active = lgfps2 > minl;
    const fps2_gate_node = if (@as(f64, @floatFromInt(model.flagfps2)) > 0.5) v_gi2 else v_si;
    const v_fps2_gs = if (fps2_active) fps2_gate_node.sub(v_fps1).scale(type_f) else S.con(0.0);
    const v_fps2_gd = if (fps2_active) fps2_gate_node.sub(v_fps2).scale(type_f) else S.con(0.0);
    const cgfps2_t = calc_capt(@as(f64, model.cgfps2), @as(f64, model.tcgfps2), tamb, tnom_k);
    const vtofps2_t: f64 = @as(f64, model.vtofps2) + @as(f64, model.vtzetafps2) * (tamb - tnom_k);
    const fps2 = if (fps2_active) calc_iq(
        S,
        v_fps2_gs,
        v_fps2_gd,
        w,
        lgfps2,
        ngf,
        cgfps2_t,
        vtofps2_t,
        @as(f64, model.sfps2),
        @as(f64, model.ndfps2),
        @as(f64, model.alphafps2),
        @as(f64, model.betafps2),
        @as(f64, model.delta1fps2),
        0.0,
        0.0,
        @as(f64, model.mu0fps2),
        @as(f64, model.vx0fps2),
        @as(f64, model.vthetafps2),
        @as(f64, model.mthetafps2),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafps2),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fps2 = fps2.ids;
    const g_fps2_short = if (!fps2_active) GSHORT else 0.0;
    const i_fps2_short = v_fps1.sub(v_fps2).scale(g_fps2_short);

    // Source-side FP3: fps2 -> fps3
    const lgfps3: f64 = @as(f64, model.lgfps3);
    const fps3_active = lgfps3 > minl;
    const fps3_gate_node = if (@as(f64, @floatFromInt(model.flagfps3)) > 0.5) v_gi2 else v_si;
    const v_fps3_gs = if (fps3_active) fps3_gate_node.sub(v_fps2).scale(type_f) else S.con(0.0);
    const v_fps3_gd = if (fps3_active) fps3_gate_node.sub(v_fps3).scale(type_f) else S.con(0.0);
    const cgfps3_t = calc_capt(@as(f64, model.cgfps3), @as(f64, model.tcgfps3), tamb, tnom_k);
    const vtofps3_t: f64 = @as(f64, model.vtofps3) + @as(f64, model.vtzetafps3) * (tamb - tnom_k);
    const fps3 = if (fps3_active) calc_iq(
        S,
        v_fps3_gs,
        v_fps3_gd,
        w,
        lgfps3,
        ngf,
        cgfps3_t,
        vtofps3_t,
        @as(f64, model.sfps3),
        @as(f64, model.ndfps3),
        @as(f64, model.alphafps3),
        @as(f64, model.betafps3),
        @as(f64, model.delta1fps3),
        0.0,
        0.0,
        @as(f64, model.mu0fps3),
        @as(f64, model.vx0fps3),
        @as(f64, model.vthetafps3),
        @as(f64, model.mthetafps3),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafps3),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fps3 = fps3.ids;
    const g_fps3_short = if (!fps3_active) GSHORT else 0.0;
    const i_fps3_short = v_fps2.sub(v_fps3).scale(g_fps3_short);

    // Source-side FP4: fps3 -> fps4
    const lgfps4: f64 = @as(f64, model.lgfps4);
    const fps4_active = lgfps4 > minl;
    const fps4_gate_node = if (@as(f64, @floatFromInt(model.flagfps4)) > 0.5) v_gi2 else v_si;
    const v_fps4_gs = if (fps4_active) fps4_gate_node.sub(v_fps3).scale(type_f) else S.con(0.0);
    const v_fps4_gd = if (fps4_active) fps4_gate_node.sub(v_fps4).scale(type_f) else S.con(0.0);
    const cgfps4_t = calc_capt(@as(f64, model.cgfps4), @as(f64, model.tcgfps4), tamb, tnom_k);
    const vtofps4_t: f64 = @as(f64, model.vtofps4) + @as(f64, model.vtzetafps4) * (tamb - tnom_k);
    const fps4_res = if (fps4_active) calc_iq(
        S,
        v_fps4_gs,
        v_fps4_gd,
        w,
        lgfps4,
        ngf,
        cgfps4_t,
        vtofps4_t,
        @as(f64, model.sfps4),
        @as(f64, model.ndfps4),
        @as(f64, model.alphafps4),
        @as(f64, model.betafps4),
        @as(f64, model.delta1fps4),
        0.0,
        0.0,
        @as(f64, model.mu0fps4),
        @as(f64, model.vx0fps4),
        @as(f64, model.vthetafps4),
        @as(f64, model.mthetafps4),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafps4),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fps4 = fps4_res.ids;
    const g_fps4_short = if (!fps4_active) GSHORT else 0.0;
    const i_fps4_short = v_fps3.sub(v_fps4).scale(g_fps4_short);

    // Drain-side FP1: di -> fp1
    const lgfp1: f64 = @as(f64, model.lgfp1);
    const fp1_active = lgfp1 > minl;
    const fp1_gate_node = if (@as(f64, @floatFromInt(model.flagfp1)) > 0.5) v_gi2 else v_di;
    const v_fp1_gs = if (fp1_active) fp1_gate_node.sub(v_di).scale(type_f) else S.con(0.0);
    const v_fp1_gd = if (fp1_active) fp1_gate_node.sub(v_fp1).scale(type_f) else S.con(0.0);
    const cgfp1_t = calc_capt(@as(f64, model.cgfp1), @as(f64, model.tcgfp1), tamb, tnom_k);
    const vtofp1_t: f64 = @as(f64, model.vtofp1) + @as(f64, model.vtzetafp1) * (tamb - tnom_k);
    const fp1_res = if (fp1_active) calc_iq(
        S,
        v_fp1_gs,
        v_fp1_gd,
        w,
        lgfp1,
        ngf,
        cgfp1_t,
        vtofp1_t,
        @as(f64, model.sfp1),
        @as(f64, model.ndfp1),
        @as(f64, model.alphafp1),
        @as(f64, model.betafp1),
        @as(f64, model.delta1fp1),
        0.0,
        0.0,
        @as(f64, model.mu0fp1),
        @as(f64, model.vx0fp1),
        @as(f64, model.vthetafp1),
        @as(f64, model.mthetafp1),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafp1),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fp1 = fp1_res.ids;
    const g_fp1_short = if (!fp1_active) GSHORT else 0.0;
    const i_fp1_short = v_di.sub(v_fp1).scale(g_fp1_short);

    // Drain-side FP2: fp1 -> fp2
    const lgfp2: f64 = @as(f64, model.lgfp2);
    const fp2_active = lgfp2 > minl;
    const fp2_gate_node = if (@as(f64, @floatFromInt(model.flagfp2)) > 0.5) v_gi2 else v_di;
    const v_fp2_gs = if (fp2_active) fp2_gate_node.sub(v_fp1).scale(type_f) else S.con(0.0);
    const v_fp2_gd = if (fp2_active) fp2_gate_node.sub(v_fp2).scale(type_f) else S.con(0.0);
    const cgfp2_t = calc_capt(@as(f64, model.cgfp2), @as(f64, model.tcgfp2), tamb, tnom_k);
    const vtofp2_t: f64 = @as(f64, model.vtofp2) + @as(f64, model.vtzetafp2) * (tamb - tnom_k);
    const fp2_res = if (fp2_active) calc_iq(
        S,
        v_fp2_gs,
        v_fp2_gd,
        w,
        lgfp2,
        ngf,
        cgfp2_t,
        vtofp2_t,
        @as(f64, model.sfp2),
        @as(f64, model.ndfp2),
        @as(f64, model.alphafp2),
        @as(f64, model.betafp2),
        @as(f64, model.delta1fp2),
        0.0,
        0.0,
        @as(f64, model.mu0fp2),
        @as(f64, model.vx0fp2),
        @as(f64, model.vthetafp2),
        @as(f64, model.mthetafp2),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafp2),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fp2 = fp2_res.ids;
    const g_fp2_short = if (!fp2_active) GSHORT else 0.0;
    const i_fp2_short = v_fp1.sub(v_fp2).scale(g_fp2_short);

    // Drain-side FP3: fp2 -> fp3
    const lgfp3: f64 = @as(f64, model.lgfp3);
    const fp3_active = lgfp3 > minl;
    const fp3_gate_node = if (@as(f64, @floatFromInt(model.flagfp3)) > 0.5) v_gi2 else v_di;
    const v_fp3_gs = if (fp3_active) fp3_gate_node.sub(v_fp2).scale(type_f) else S.con(0.0);
    const v_fp3_gd = if (fp3_active) fp3_gate_node.sub(v_fp3).scale(type_f) else S.con(0.0);
    const cgfp3_t = calc_capt(@as(f64, model.cgfp3), @as(f64, model.tcgfp3), tamb, tnom_k);
    const vtofp3_t: f64 = @as(f64, model.vtofp3) + @as(f64, model.vtzetafp3) * (tamb - tnom_k);
    const fp3_res = if (fp3_active) calc_iq(
        S,
        v_fp3_gs,
        v_fp3_gd,
        w,
        lgfp3,
        ngf,
        cgfp3_t,
        vtofp3_t,
        @as(f64, model.sfp3),
        @as(f64, model.ndfp3),
        @as(f64, model.alphafp3),
        @as(f64, model.betafp3),
        @as(f64, model.delta1fp3),
        0.0,
        0.0,
        @as(f64, model.mu0fp3),
        @as(f64, model.vx0fp3),
        @as(f64, model.vthetafp3),
        @as(f64, model.mthetafp3),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafp3),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fp3 = fp3_res.ids;
    const g_fp3_short = if (!fp3_active) GSHORT else 0.0;
    const i_fp3_short = v_fp2.sub(v_fp3).scale(g_fp3_short);

    // Drain-side FP4: fp3 -> fp4
    const lgfp4: f64 = @as(f64, model.lgfp4);
    const fp4_active = lgfp4 > minl;
    const fp4_gate_node = if (@as(f64, @floatFromInt(model.flagfp4)) > 0.5) v_gi2 else v_di;
    const v_fp4_gs = if (fp4_active) fp4_gate_node.sub(v_fp3).scale(type_f) else S.con(0.0);
    const v_fp4_gd = if (fp4_active) fp4_gate_node.sub(v_fp4).scale(type_f) else S.con(0.0);
    const cgfp4_t = calc_capt(@as(f64, model.cgfp4), @as(f64, model.tcgfp4), tamb, tnom_k);
    const vtofp4_t: f64 = @as(f64, model.vtofp4) + @as(f64, model.vtzetafp4) * (tamb - tnom_k);
    const fp4_res = if (fp4_active) calc_iq(
        S,
        v_fp4_gs,
        v_fp4_gd,
        w,
        lgfp4,
        ngf,
        cgfp4_t,
        vtofp4_t,
        @as(f64, model.sfp4),
        @as(f64, model.ndfp4),
        @as(f64, model.alphafp4),
        @as(f64, model.betafp4),
        @as(f64, model.delta1fp4),
        0.0,
        0.0,
        @as(f64, model.mu0fp4),
        @as(f64, model.vx0fp4),
        @as(f64, model.vthetafp4),
        @as(f64, model.mthetafp4),
        0.0,
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzetafp4),
        type_f,
        S.con(1.0),
    ) else IqResultS(S){ .ids = S.con(0.0), .qis = S.con(0.0), .qid = S.con(0.0), .qis0 = S.con(0.0), .qid0 = S.con(0.0), .qinv_v = S.con(0.0) };
    const i_fp4 = fp4_res.ids;
    const g_fp4_short = if (!fp4_active) GSHORT else 0.0;
    const i_fp4_short = v_fp3.sub(v_fp4).scale(g_fp4_short);

    // --- Gate Leakage Diodes ---
    const v_gs_diode = v_gi2p.sub(v_si).scale(type_f);
    const v_gd_diode = v_gi2p.sub(v_di).scale(type_f);

    const ig_active = igmod > 0.5;

    // Forward gate-source current
    const i_gs_fwd = calc_ig_fwd(
        S,
        v_gs_diode,
        w,
        ngf,
        @as(f64, model.ijs),
        @as(f64, model.pg_params),
        @as(f64, model.pg_param1),
        @as(f64, model.vjg),
        @as(f64, model.vgsats),
        @as(f64, model.fracs),
        @as(f64, model.alphags),
        @as(f64, model.kbdgates),
        @as(f64, model.vbdgs),
        @as(f64, model.pbdgs),
        phi_t,
        tfac_diode,
    );
    const i_gs_rec = calc_ig_rec(
        S,
        v_gs_diode,
        w,
        ngf,
        @as(f64, model.irecs),
        @as(f64, model.pgsrecs),
        @as(f64, model.vgsatqs),
        @as(f64, model.betarecs),
        phi_t,
        tfac_diode,
    );
    const igrecmod: f64 = @floatFromInt(model.igrecmod);
    const i_gs_rec2 = if (igrecmod > 0.5) calc_ig_rec(
        S,
        v_gs_diode,
        w,
        ngf,
        @as(f64, model.irecs2),
        @as(f64, model.pgsrecs2),
        @as(f64, model.vgsatqs2),
        @as(f64, model.betarecs2),
        phi_t,
        tfac_diode,
    ) else S.con(0.0);

    const i_gd_fwd = calc_ig_fwd(
        S,
        v_gd_diode,
        w,
        ngf,
        @as(f64, model.ijd),
        @as(f64, model.pg_paramd),
        @as(f64, model.pg_param1),
        @as(f64, model.vjg),
        @as(f64, model.vgsatd),
        @as(f64, model.fracd),
        @as(f64, model.alphagd),
        @as(f64, model.kbdgated),
        @as(f64, model.vbdgd),
        @as(f64, model.pbdgd),
        phi_t,
        tfac_diode,
    );
    const i_gd_rec = calc_ig_rec(
        S,
        v_gd_diode,
        w,
        ngf,
        @as(f64, model.irecd),
        @as(f64, model.pgsrecd),
        @as(f64, model.vgsatqd),
        @as(f64, model.betarecd),
        phi_t,
        tfac_diode,
    );
    const i_gd_rec2 = if (igrecmod > 0.5) calc_ig_rec(
        S,
        v_gd_diode,
        w,
        ngf,
        @as(f64, model.irecd2),
        @as(f64, model.pgsrecd2),
        @as(f64, model.vgsatqd2),
        @as(f64, model.betarecd2),
        phi_t,
        tfac_diode,
    ) else S.con(0.0);

    // Total gate leakage: zeroed when igmod=0
    const i_gs_gate = if (ig_active) i_gs_fwd.add(i_gs_rec).add(i_gs_rec2) else S.con(0.0);
    const i_gd_gate = if (ig_active) i_gd_fwd.add(i_gd_rec).add(i_gd_rec2) else S.con(0.0);

    // fracig: fraction de-biased through FP transistors
    const fracig: f64 = @as(f64, model.fracig);
    const i_gs_intr = i_gs_gate.scale(1.0 - fracig);
    const i_gd_intr = i_gd_gate.scale(1.0 - fracig);
    const i_gs_fp = i_gs_gate.scale(fracig);
    const i_gd_fp = i_gd_gate.scale(fracig);

    // --- Channel Breakdown ---
    const cbd_active = icbdmod > 0.5;
    const ijscbd: f64 = @as(f64, model.ijscbd);
    const vchbdgs: f64 = @as(f64, model.vchbdgs);
    const pchbdgs: f64 = @as(f64, model.pchbdgs);
    const ijdcbd: f64 = @as(f64, model.ijdcbd);
    const vchbdgd: f64 = @as(f64, model.vchbdgd);
    const pchbdgd: f64 = @as(f64, model.pchbdgd);
    const cbddbmod_val: f64 = @floatFromInt(model.cbddbmod);

    // Forward channel breakdown (S->D direction)
    const v_sd_cbd = if (cbddbmod_val > 0.5) v_src.sub(v_drc) else v_si.sub(v_di);
    const v_sg_cbd = if (cbddbmod_val > 0.5) v_src.sub(v_gi2) else v_si.sub(v_gi2);
    // i = w*ngf*ijscbd*(explim(-pchbdgs*vchbdgs) - explim(-pchbdgs*(v_sd+v_sg-vchbdgs)))
    const cbd_sd_term1 = contract.fmath.exp(@min(-pchbdgs * vchbdgs, 80.0));
    const cbd_sd_term2 = explimS(S, v_sd_cbd.add(v_sg_cbd).addC(-vchbdgs).scale(-pchbdgs));
    const i_cbd_sd_raw = cbd_sd_term2.neg().addC(cbd_sd_term1).scale(w * ngf * ijscbd);

    // Reverse channel breakdown (D->S direction)
    const v_ds_cbd = if (cbddbmod_val > 0.5) v_drc.sub(v_src) else v_di.sub(v_si);
    const v_dg_cbd = if (cbddbmod_val > 0.5) v_drc.sub(v_gi2) else v_di.sub(v_gi2);
    const cbd_ds_term1 = contract.fmath.exp(@min(-pchbdgd * vchbdgd, 80.0));
    const cbd_ds_term2 = explimS(S, v_ds_cbd.add(v_dg_cbd).addC(-vchbdgd).scale(-pchbdgd));
    const i_cbd_ds_raw = cbd_ds_term2.neg().addC(cbd_ds_term1).scale(w * ngf * ijdcbd);

    const i_cbd_sd = if (cbd_active) i_cbd_sd_raw else S.con(0.0);
    const i_cbd_ds = if (cbd_active) i_cbd_ds_raw else S.con(0.0);

    // --- gm-Dispersion (NQS transport) ---
    const gmd_active = gmdisp > 0.5;
    const taugmrf: f64 = @as(f64, model.taugmrf);
    const g_gm = 1.0 / (taugmrf + 1.0e-30);
    // i_xt1 = v_xt1*g_gm - i_ds_intr*g_gm
    const i_xt1 = if (gmd_active) v_xt1.scale(g_gm).sub(i_ds_intr.scale(g_gm)) else S.con(0.0);
    const i_xt2 = if (gmd_active) v_xt2.scale(g_gm).sub(v_xt1.scale(g_gm)) else S.con(0.0);

    // --- Self-Heating ---
    const g_th = if (rth > 0.0) 1.0 / rth else GSHORT;
    const i_th_res = v_dt.scale(g_th);

    // Power dissipation computation
    const v_rcs = v_s.sub(v_src);
    const v_rcd = v_d.sub(v_drc);
    const p_rcs = v_rcs.mul(v_rcs).scale(g_rcs);
    const p_rcd = v_rcd.mul(v_rcd).scale(g_rcd);
    const p_intr = i_ds_intr.mul(v_di.sub(v_si));
    const p_sar = i_ds_sar.mul(v_fps4.sub(v_src));
    const p_dar = i_ds_dar.mul(v_drc.sub(v_fp4));
    const p_fps = i_fps1.mul(v_si.sub(v_fps1)).add(i_fps2.mul(v_fps1.sub(v_fps2))).add(i_fps3.mul(v_fps2.sub(v_fps3))).add(i_fps4.mul(v_fps3.sub(v_fps4)));
    const p_fp = i_fp1.mul(v_di.sub(v_fp1)).add(i_fp2.mul(v_fp1.sub(v_fp2))).add(i_fp3.mul(v_fp2.sub(v_fp3))).add(i_fp4.mul(v_fp3.sub(v_fp4)));
    const p_diss = p_intr.add(p_sar).add(p_dar).add(p_fps).add(p_fp).add(p_rcs).add(p_rcd);

    // Thermal node: power injection (negative current = heat source)
    const i_th_power = i_th_res.sub(p_diss);

    // --- GMIN conditioning on key junctions ---
    const gmin_gi2_si = v_gi2.sub(v_si).scale(GMIN);
    const gmin_gi2_di = v_gi2.sub(v_di).scale(GMIN);
    const gmin_si_di = v_si.sub(v_di).scale(GMIN);

    // Channel breakdown contributions
    const cbd_si_contrib = if (cbd_active and cbddbmod_val < 0.5) i_cbd_sd else S.con(0.0);
    const cbd_di_contrib = if (cbd_active and cbddbmod_val < 0.5) i_cbd_ds else S.con(0.0);
    const cbd_src_contrib = if (cbd_active and cbddbmod_val > 0.5) i_cbd_sd else S.con(0.0);
    const cbd_drc_contrib = if (cbd_active and cbddbmod_val > 0.5) i_cbd_ds else S.con(0.0);

    // --- Assemble KCL output contributions ---
    var out: [n_u]S = undefined;

    // d: external drain
    out[D] = i_rcd;
    // g: external gate
    out[G] = i_rg1;
    // s: external source
    out[S_] = i_rcs;
    // b: external body -- GMIN to ground reference, body effect
    out[B] = v_b.sub(v_s).scale(GMIN);
    // dt: thermal node
    out[DT] = i_th_power;
    // gi1: gate resistance intermediate
    out[GI1] = i_rg1.neg().add(i_rg2);
    // gi2: internal gate
    out[GI2] = i_rg2.neg().add(gmin_gi2_si).add(gmin_gi2_di).add(i_pgan_total);
    // gi2p: p-GaN junction node
    out[GI2P] = i_pgan_total.neg().add(i_gs_intr).add(i_gd_intr).add(i_gs_fp).add(i_gd_fp);

    // si: intrinsic source
    out[SI] = i_ds_intr.neg().sub(i_fps1).sub(i_fps1_short).sub(gmin_gi2_si).sub(gmin_si_di).sub(i_gs_intr).sub(cbd_si_contrib);
    // di: intrinsic drain
    out[DI] = i_ds_intr.sub(i_fp1).sub(i_fp1_short).sub(gmin_gi2_di).add(gmin_si_di).sub(i_gd_intr).sub(cbd_di_contrib);
    // src: source contact resistance node
    out[SRC] = i_rcs.neg().add(i_ds_sar).add(i_sar_short).sub(cbd_src_contrib);
    // drc: drain contact resistance node
    out[DRC] = i_rcd.neg().add(i_ds_dar).add(i_dar_short).sub(cbd_drc_contrib);

    // fps1..fps4
    out[FPS1] = i_fps1.add(i_fps1_short).sub(i_fps2).sub(i_fps2_short);
    out[FPS2] = i_fps2.add(i_fps2_short).sub(i_fps3).sub(i_fps3_short);
    out[FPS3] = i_fps3.add(i_fps3_short).sub(i_fps4).sub(i_fps4_short);
    out[FPS4] = i_fps4.add(i_fps4_short).sub(i_ds_sar).sub(i_sar_short).sub(i_gs_fp);

    // fp1..fp4
    out[FP1] = i_fp1.add(i_fp1_short).sub(i_fp2).sub(i_fp2_short);
    out[FP2] = i_fp2.add(i_fp2_short).sub(i_fp3).sub(i_fp3_short);
    out[FP3] = i_fp3.add(i_fp3_short).sub(i_fp4).sub(i_fp4_short);
    out[FP4] = i_fp4.add(i_fp4_short).sub(i_ds_dar).sub(i_dar_short).sub(i_gd_fp);

    // xt1, xt2: gm-dispersion nodes
    out[XT1] = i_xt1;
    out[XT2] = i_xt2;

    // vtrap / vdl / vgl: trapping nodes
    out[VTRAP] = i_vtrap;
    out[VDL] = i_vdl;
    out[VGL] = i_vgl;

    return out;
}

// ============================================================================
// Charge function: q (value-form)
//
// Computes:
//   1. Ward-Dutton channel charge partitioning (Qgs, Qgd for intrinsic FET)
//   2. FP channel charges (Ward-Dutton for each active FP transistor)
//   3. FP cross-coupled charges (ccfp, cbfp, cfps)
//   4. Fringing capacitance charges
//   5. p-GaN Schottky junction charge (Csch)
//   6. Self-heating thermal capacitance
//   7. Trapping capacitance (ctrap / cdglag)
//   8. gm-dispersion capacitance
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const D = @intFromEnum(U.d);
    const G = @intFromEnum(U.g);
    const S_ = @intFromEnum(U.s);
    const B = @intFromEnum(U.b);
    const DT = @intFromEnum(U.dt);
    const GI1 = @intFromEnum(U.gi1);
    const GI2 = @intFromEnum(U.gi2);
    const GI2P = @intFromEnum(U.gi2p);
    const SI = @intFromEnum(U.si);
    const DI = @intFromEnum(U.di);
    const SRC = @intFromEnum(U.src);
    const DRC = @intFromEnum(U.drc);
    const FPS1 = @intFromEnum(U.fps1);
    const FPS2 = @intFromEnum(U.fps2);
    const FPS3 = @intFromEnum(U.fps3);
    const FPS4 = @intFromEnum(U.fps4);
    const FP1 = @intFromEnum(U.fp1);
    const FP2 = @intFromEnum(U.fp2);
    const FP3 = @intFromEnum(U.fp3);
    const FP4 = @intFromEnum(U.fp4);
    const XT1 = @intFromEnum(U.xt1);
    const XT2 = @intFromEnum(U.xt2);
    const VTRAP = @intFromEnum(U.vtrap);
    const VDL = @intFromEnum(U.vdl);
    const VGL = @intFromEnum(U.vgl);

    // Cast parameters (x-independent)
    const type_f: f64 = @floatFromInt(model.type_);
    const tnom_k: f64 = pc.tnom_k;
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const ngf: f64 = @as(f64, instance.ngf);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const rth: f64 = @as(f64, model.rth);
    const minl: f64 = @as(f64, model.minl);
    const flagsp: f64 = @floatFromInt(model.flagsp);
    const flaggum: f64 = @floatFromInt(model.flaggum);
    const mmaxs_m: f64 = @as(f64, model.mmaxs);

    // Read node voltages
    const v_b = x[B];
    const v_dt = x[DT];
    const v_gi2 = x[GI2];
    const v_gi2p = x[GI2P];
    const v_si = x[SI];
    const v_di = x[DI];
    const v_fps1 = x[FPS1];
    const v_fps2 = x[FPS2];
    const v_fps3 = x[FPS3];
    const v_fps4 = x[FPS4];
    const v_fp1 = x[FP1];
    const v_fp2 = x[FP2];
    const v_fp3 = x[FP3];
    const v_fp4 = x[FP4];
    const v_xt1 = x[XT1];
    const v_xt2 = x[XT2];
    const v_vtrap = x[VTRAP];
    const v_vdl = x[VDL];
    const v_vgl = x[VGL];

    // Temperature (self-heating region read on v_dt.val(), mirroring old f64 path)
    const t_sh = if (rth > 0.0) v_dt.val() else 0.0;
    const tamb = @max(@min(tnom_k + dtemp + t_sh, TMAX_C + 273.15), TMIN_C + 273.15);
    const phi_t = KB * tamb / Q_ELEC;
    const tcg: f64 = @as(f64, model.tcg);
    const cg_t = calc_capt(@as(f64, model.cg), tcg, tamb, tnom_k);
    const alpha_m: f64 = @as(f64, model.alpha);
    const beta_m: f64 = @as(f64, model.beta);
    const epsilon_m: f64 = @as(f64, model.epsilon);
    const vzeta_m: f64 = @as(f64, model.vzeta);

    // Trapping
    const trapselect: f64 = @floatFromInt(model.trapselect);
    const q_vdltrapth: f64 = @as(f64, model.vdltrapth);
    const q_vgltrapth: f64 = @as(f64, model.vgltrapth);
    const q_qfrac_d = v_vdl.abs().scale(1.0 / (q_vdltrapth + 1.0e-30));
    const q_qfrac_g = v_vgl.abs().scale(1.0 / (q_vgltrapth + 1.0e-30));
    const trapfrac_dl = if (trapselect > 1.5) S.con(1.0).div(q_qfrac_d.add(q_qfrac_g).addC(1.0)) else S.con(1.0);

    // --- Intrinsic FET channel charge (Ward-Dutton) ---
    const v_gi2_si = v_gi2.sub(v_si).scale(type_f);
    const v_gi2_di = v_gi2.sub(v_di).scale(type_f);
    const intr = calc_iq(
        S,
        v_gi2_si,
        v_gi2_di,
        w,
        l,
        ngf,
        cg_t,
        @as(f64, model.vto),
        @as(f64, model.ss),
        @as(f64, model.nd),
        alpha_m,
        beta_m,
        @as(f64, model.delta1),
        @as(f64, model.delta2),
        @as(f64, model.dibsat),
        @as(f64, model.mu0),
        @as(f64, model.vx0),
        @as(f64, model.vtheta),
        @as(f64, model.mtheta),
        @as(f64, model.lambda),
        flagsp,
        flaggum,
        mmaxs_m,
        phi_t,
        tamb,
        tnom_k,
        epsilon_m,
        vzeta_m,
        @as(f64, model.vtzeta),
        type_f,
        trapfrac_dl,
    );

    // Ward-Dutton partitioning using qis0, qid0
    const qis0 = intr.qis0.addC(1.0e-38);
    const qid0 = intr.qid0.addC(1.0e-38);
    const qsum = qis0.add(qid0).addC(1.0e-57);
    const qsum2 = qis0.mul(qis0).add(qid0.mul(qid0)).add(qis0.mul(qid0).scale(2.0)).addC(1.0e-19);
    // qinv = (2/3)*w*l*(qis0^2 + qid0^2 + qis0*qid0)/qsum
    const qinv = qis0.mul(qis0).add(qid0.mul(qid0)).add(qis0.mul(qid0)).scale((2.0 / 3.0) * w * l).div(qsum.addC(1.0e-38));
    // qd_wd = (2/15)*w*l*(2*qis0^3 + 3*qid0^3 + 4*qis0^2*qid0 + 6*qid0^2*qis0)/qsum2
    const qd_num = qis0.mul(qis0).mul(qis0).scale(2.0)
        .add(qid0.mul(qid0).mul(qid0).scale(3.0))
        .add(qis0.mul(qis0).mul(qid0).scale(4.0))
        .add(qid0.mul(qid0).mul(qis0).scale(6.0));
    const qd_wd = qd_num.scale((2.0 / 15.0) * w * l).div(qsum2.addC(2.0e-19));
    const qs_wd = qinv.sub(qd_wd);

    const q_gs_intr = qs_wd.scale(ngf * type_f).mul(trapfrac_dl);
    const q_gd_intr = qd_wd.scale(ngf * type_f).mul(trapfrac_dl);

    // --- Fringing Capacitance Charges ---
    const vtfrin: f64 = @as(f64, model.vtfrin);
    const nfrin: f64 = @as(f64, model.nfrin);

    const cofs_t = calc_capt(@as(f64, model.cofsm), @as(f64, model.tcofs), tamb, tnom_k);
    const cofd_t = calc_capt(@as(f64, model.cofdm), @as(f64, model.tcofd), tamb, tnom_k);
    const cofds_t = calc_capt(@as(f64, model.cofdsm), @as(f64, model.tcofds), tamb, tnom_k);
    const cofssub_t = calc_capt(@as(f64, model.cofssubm), @as(f64, model.tcofssub), tamb, tnom_k);
    const cofdsub_t = calc_capt(@as(f64, model.cofdsubm), @as(f64, model.tcofdsub), tamb, tnom_k);
    const cofgsub_t = calc_capt(@as(f64, model.cofgsubm), @as(f64, model.tcofgsub), tamb, tnom_k);
    const cofs0: f64 = @as(f64, model.cofsm0);
    const cofd0: f64 = @as(f64, model.cofdm0);
    const cofds0: f64 = @as(f64, model.cofdsm0);
    const cofssub0: f64 = @as(f64, model.cofssubm0);
    const cofdsub0: f64 = @as(f64, model.cofdsubm0);
    const cofgsub0: f64 = @as(f64, model.cofgsubm0);

    const v_gs_frin = v_gi2.sub(v_si);
    const v_gd_frin = v_gi2.sub(v_di);
    const v_ds_frin = v_di.sub(v_si);
    const v_ssub_frin = v_si.sub(v_b);
    const v_dsub_frin = v_di.sub(v_b);
    const v_gsub_frin = v_gi2.sub(v_b);

    const q_frin_gs = fringing_charge(S, v_gs_frin, w, ngf, cofs0, cofs_t, nfrin, vtfrin);
    const q_frin_gd = fringing_charge(S, v_gd_frin, w, ngf, cofd0, cofd_t, nfrin, vtfrin);
    const q_frin_ds = fringing_charge(S, v_ds_frin, w, ngf, cofds0, cofds_t, nfrin, vtfrin);
    const q_frin_ssub = fringing_charge(S, v_ssub_frin, w, ngf, cofssub0, cofssub_t, nfrin, vtfrin);
    const q_frin_dsub = fringing_charge(S, v_dsub_frin, w, ngf, cofdsub0, cofdsub_t, nfrin, vtfrin);
    const q_frin_gsub = fringing_charge(S, v_gsub_frin, w, ngf, cofgsub0, cofgsub_t, nfrin, vtfrin);

    // --- FP Cross-coupled and Body Charges ---
    // Source-side FP charges
    const lgfps1: f64 = @as(f64, model.lgfps1);
    const ccfps1_t = calc_capt(@as(f64, model.ccfps1), @as(f64, model.tccfps1), tamb, tnom_k);
    const cbfps1_t = calc_capt(@as(f64, model.cbfps1), @as(f64, model.tcbfps1), tamb, tnom_k);
    const cfps1s_v: f64 = @as(f64, model.cfps1s);
    const vtofps1_t_q: f64 = @as(f64, model.vtofps1) + @as(f64, model.vtzetafps1) * (tamb - tnom_k);
    const sfps1_q: f64 = @as(f64, model.sfps1);
    const alphafps1_q: f64 = @as(f64, model.alphafps1);
    const fps1_gate_q = if (@as(f64, @floatFromInt(model.flagfps1)) > 0.5) v_gi2 else v_si;
    const fps1_q_active = lgfps1 > minl;
    const fps1b_active = fps1_q_active and @as(f64, @floatFromInt(model.flagfps1b)) > 0.5;
    const fps1s_active = fps1_q_active and @as(f64, @floatFromInt(model.flagfps1s)) > 0.5;
    const q_cc_fps1 = if (fps1b_active) calc_fp_cc_charge(S, fps1_gate_q, v_fps1, ccfps1_t, vtofps1_t_q, sfps1_q, alphafps1_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fps1 = if (fps1b_active) calc_fp_cc_charge(S, v_b, v_fps1, cbfps1_t, vtofps1_t_q, sfps1_q, alphafps1_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fps1 = if (fps1s_active) calc_fp_cc_charge(S, fps1_gate_q, v_si, cfps1s_v, vtofps1_t_q, sfps1_q, alphafps1_q, phi_t, w, flagsp) else S.con(0.0);

    const lgfps2: f64 = @as(f64, model.lgfps2);
    const ccfps2_t = calc_capt(@as(f64, model.ccfps2), @as(f64, model.tccfps2), tamb, tnom_k);
    const cbfps2_t = calc_capt(@as(f64, model.cbfps2), @as(f64, model.tcbfps2), tamb, tnom_k);
    const cfps2s_v: f64 = @as(f64, model.cfps2s);
    const vtofps2_t_q: f64 = @as(f64, model.vtofps2) + @as(f64, model.vtzetafps2) * (tamb - tnom_k);
    const sfps2_q: f64 = @as(f64, model.sfps2);
    const alphafps2_q: f64 = @as(f64, model.alphafps2);
    const fps2_gate_q = if (@as(f64, @floatFromInt(model.flagfps2)) > 0.5) v_gi2 else v_si;
    const fps2_q_active = lgfps2 > minl;
    const fps2b_active = fps2_q_active and @as(f64, @floatFromInt(model.flagfps2b)) > 0.5;
    const fps2s_active = fps2_q_active and @as(f64, @floatFromInt(model.flagfps2s)) > 0.5;
    const q_cc_fps2 = if (fps2b_active) calc_fp_cc_charge(S, fps2_gate_q, v_fps2, ccfps2_t, vtofps2_t_q, sfps2_q, alphafps2_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fps2 = if (fps2b_active) calc_fp_cc_charge(S, v_b, v_fps2, cbfps2_t, vtofps2_t_q, sfps2_q, alphafps2_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fps2 = if (fps2s_active) calc_fp_cc_charge(S, fps2_gate_q, v_si, cfps2s_v, vtofps2_t_q, sfps2_q, alphafps2_q, phi_t, w, flagsp) else S.con(0.0);

    const lgfps3: f64 = @as(f64, model.lgfps3);
    const ccfps3_t = calc_capt(@as(f64, model.ccfps3), @as(f64, model.tccfps3), tamb, tnom_k);
    const cbfps3_t = calc_capt(@as(f64, model.cbfps3), @as(f64, model.tcbfps3), tamb, tnom_k);
    const cfps3s_v: f64 = @as(f64, model.cfps3s);
    const vtofps3_t_q: f64 = @as(f64, model.vtofps3) + @as(f64, model.vtzetafps3) * (tamb - tnom_k);
    const sfps3_q: f64 = @as(f64, model.sfps3);
    const alphafps3_q: f64 = @as(f64, model.alphafps3);
    const fps3_gate_q = if (@as(f64, @floatFromInt(model.flagfps3)) > 0.5) v_gi2 else v_si;
    const fps3_q_active = lgfps3 > minl;
    const fps3b_active = fps3_q_active and @as(f64, @floatFromInt(model.flagfps3b)) > 0.5;
    const fps3s_active = fps3_q_active and @as(f64, @floatFromInt(model.flagfps3s)) > 0.5;
    const q_cc_fps3 = if (fps3b_active) calc_fp_cc_charge(S, fps3_gate_q, v_fps3, ccfps3_t, vtofps3_t_q, sfps3_q, alphafps3_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fps3 = if (fps3b_active) calc_fp_cc_charge(S, v_b, v_fps3, cbfps3_t, vtofps3_t_q, sfps3_q, alphafps3_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fps3 = if (fps3s_active) calc_fp_cc_charge(S, fps3_gate_q, v_si, cfps3s_v, vtofps3_t_q, sfps3_q, alphafps3_q, phi_t, w, flagsp) else S.con(0.0);

    const lgfps4: f64 = @as(f64, model.lgfps4);
    const ccfps4_t = calc_capt(@as(f64, model.ccfps4), @as(f64, model.tccfps4), tamb, tnom_k);
    const cbfps4_t = calc_capt(@as(f64, model.cbfps4), @as(f64, model.tcbfps4), tamb, tnom_k);
    const cfps4s_v: f64 = @as(f64, model.cfps4s);
    const vtofps4_t_q: f64 = @as(f64, model.vtofps4) + @as(f64, model.vtzetafps4) * (tamb - tnom_k);
    const sfps4_q: f64 = @as(f64, model.sfps4);
    const alphafps4_q: f64 = @as(f64, model.alphafps4);
    const fps4_gate_q = if (@as(f64, @floatFromInt(model.flagfps4)) > 0.5) v_gi2 else v_si;
    const fps4_q_active = lgfps4 > minl;
    const fps4b_active = fps4_q_active and @as(f64, @floatFromInt(model.flagfps4b)) > 0.5;
    const fps4s_active = fps4_q_active and @as(f64, @floatFromInt(model.flagfps4s)) > 0.5;
    const q_cc_fps4 = if (fps4b_active) calc_fp_cc_charge(S, fps4_gate_q, v_fps4, ccfps4_t, vtofps4_t_q, sfps4_q, alphafps4_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fps4 = if (fps4b_active) calc_fp_cc_charge(S, v_b, v_fps4, cbfps4_t, vtofps4_t_q, sfps4_q, alphafps4_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fps4 = if (fps4s_active) calc_fp_cc_charge(S, fps4_gate_q, v_si, cfps4s_v, vtofps4_t_q, sfps4_q, alphafps4_q, phi_t, w, flagsp) else S.con(0.0);

    // Drain-side FP charges
    const lgfp1: f64 = @as(f64, model.lgfp1);
    const ccfp1_t = calc_capt(@as(f64, model.ccfp1), @as(f64, model.tccfp1), tamb, tnom_k);
    const cbfp1_t = calc_capt(@as(f64, model.cbfp1), @as(f64, model.tcbfp1), tamb, tnom_k);
    const cfp1s_v: f64 = @as(f64, model.cfp1s);
    const vtofp1_t_q: f64 = @as(f64, model.vtofp1) + @as(f64, model.vtzetafp1) * (tamb - tnom_k);
    const sfp1_q: f64 = @as(f64, model.sfp1);
    const alphafp1_q: f64 = @as(f64, model.alphafp1);
    const fp1_gate_q = if (@as(f64, @floatFromInt(model.flagfp1)) > 0.5) v_gi2 else v_di;
    const fp1_q_active = lgfp1 > minl;
    const fp1b_active = fp1_q_active and @as(f64, @floatFromInt(model.flagfp1b)) > 0.5;
    const fp1s_active = fp1_q_active and @as(f64, @floatFromInt(model.flagfp1s)) > 0.5;
    const q_cc_fp1 = if (fp1b_active) calc_fp_cc_charge(S, fp1_gate_q, v_fp1, ccfp1_t, vtofp1_t_q, sfp1_q, alphafp1_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fp1 = if (fp1b_active) calc_fp_cc_charge(S, v_b, v_fp1, cbfp1_t, vtofp1_t_q, sfp1_q, alphafp1_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fp1 = if (fp1s_active) calc_fp_cc_charge(S, fp1_gate_q, v_si, cfp1s_v, vtofp1_t_q, sfp1_q, alphafp1_q, phi_t, w, flagsp) else S.con(0.0);

    const lgfp2: f64 = @as(f64, model.lgfp2);
    const ccfp2_t = calc_capt(@as(f64, model.ccfp2), @as(f64, model.tccfp2), tamb, tnom_k);
    const cbfp2_t = calc_capt(@as(f64, model.cbfp2), @as(f64, model.tcbfp2), tamb, tnom_k);
    const cfp2s_v: f64 = @as(f64, model.cfp2s);
    const vtofp2_t_q: f64 = @as(f64, model.vtofp2) + @as(f64, model.vtzetafp2) * (tamb - tnom_k);
    const sfp2_q: f64 = @as(f64, model.sfp2);
    const alphafp2_q: f64 = @as(f64, model.alphafp2);
    const fp2_gate_q = if (@as(f64, @floatFromInt(model.flagfp2)) > 0.5) v_gi2 else v_di;
    const fp2_q_active = lgfp2 > minl;
    const fp2b_active = fp2_q_active and @as(f64, @floatFromInt(model.flagfp2b)) > 0.5;
    const fp2s_active = fp2_q_active and @as(f64, @floatFromInt(model.flagfp2s)) > 0.5;
    const q_cc_fp2 = if (fp2b_active) calc_fp_cc_charge(S, fp2_gate_q, v_fp2, ccfp2_t, vtofp2_t_q, sfp2_q, alphafp2_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fp2 = if (fp2b_active) calc_fp_cc_charge(S, v_b, v_fp2, cbfp2_t, vtofp2_t_q, sfp2_q, alphafp2_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fp2 = if (fp2s_active) calc_fp_cc_charge(S, fp2_gate_q, v_si, cfp2s_v, vtofp2_t_q, sfp2_q, alphafp2_q, phi_t, w, flagsp) else S.con(0.0);

    const lgfp3: f64 = @as(f64, model.lgfp3);
    const ccfp3_t = calc_capt(@as(f64, model.ccfp3), @as(f64, model.tccfp3), tamb, tnom_k);
    const cbfp3_t = calc_capt(@as(f64, model.cbfp3), @as(f64, model.tcbfp3), tamb, tnom_k);
    const cfp3s_v: f64 = @as(f64, model.cfp3s);
    const vtofp3_t_q: f64 = @as(f64, model.vtofp3) + @as(f64, model.vtzetafp3) * (tamb - tnom_k);
    const sfp3_q: f64 = @as(f64, model.sfp3);
    const alphafp3_q: f64 = @as(f64, model.alphafp3);
    const fp3_gate_q = if (@as(f64, @floatFromInt(model.flagfp3)) > 0.5) v_gi2 else v_di;
    const fp3_q_active = lgfp3 > minl;
    const fp3b_active = fp3_q_active and @as(f64, @floatFromInt(model.flagfp3b)) > 0.5;
    const fp3s_active = fp3_q_active and @as(f64, @floatFromInt(model.flagfp3s)) > 0.5;
    const q_cc_fp3 = if (fp3b_active) calc_fp_cc_charge(S, fp3_gate_q, v_fp3, ccfp3_t, vtofp3_t_q, sfp3_q, alphafp3_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fp3 = if (fp3b_active) calc_fp_cc_charge(S, v_b, v_fp3, cbfp3_t, vtofp3_t_q, sfp3_q, alphafp3_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fp3 = if (fp3s_active) calc_fp_cc_charge(S, fp3_gate_q, v_si, cfp3s_v, vtofp3_t_q, sfp3_q, alphafp3_q, phi_t, w, flagsp) else S.con(0.0);

    const lgfp4: f64 = @as(f64, model.lgfp4);
    const ccfp4_t = calc_capt(@as(f64, model.ccfp4), @as(f64, model.tccfp4), tamb, tnom_k);
    const cbfp4_t = calc_capt(@as(f64, model.cbfp4), @as(f64, model.tcbfp4), tamb, tnom_k);
    const cfp4s_v: f64 = @as(f64, model.cfp4s);
    const vtofp4_t_q: f64 = @as(f64, model.vtofp4) + @as(f64, model.vtzetafp4) * (tamb - tnom_k);
    const sfp4_q: f64 = @as(f64, model.sfp4);
    const alphafp4_q: f64 = @as(f64, model.alphafp4);
    const fp4_gate_q = if (@as(f64, @floatFromInt(model.flagfp4)) > 0.5) v_gi2 else v_di;
    const fp4_q_active = lgfp4 > minl;
    const fp4b_active = fp4_q_active and @as(f64, @floatFromInt(model.flagfp4b)) > 0.5;
    const fp4s_active = fp4_q_active and @as(f64, @floatFromInt(model.flagfp4s)) > 0.5;
    const q_cc_fp4 = if (fp4b_active) calc_fp_cc_charge(S, fp4_gate_q, v_fp4, ccfp4_t, vtofp4_t_q, sfp4_q, alphafp4_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cb_fp4 = if (fp4b_active) calc_fp_cc_charge(S, v_b, v_fp4, cbfp4_t, vtofp4_t_q, sfp4_q, alphafp4_q, phi_t, w, flagsp) else S.con(0.0);
    const q_cs_fp4 = if (fp4s_active) calc_fp_cc_charge(S, fp4_gate_q, v_si, cfp4s_v, vtofp4_t_q, sfp4_q, alphafp4_q, phi_t, w, flagsp) else S.con(0.0);

    // --- p-GaN Schottky Junction Charge ---
    const flagpgan: f64 = @floatFromInt(model.flagpgan);
    const vcsh0: f64 = @as(f64, model.vcsh0);
    const csh0: f64 = @as(f64, model.csh0);
    const fc_v: f64 = @as(f64, model.fc);
    const q_ohmfrac: f64 = @as(f64, model.ohmicratio);
    const q_schottky_frac = 1.0 - q_ohmfrac;
    const pgancshorder: f64 = @floatFromInt(model.pgancshorder);
    const v_pgan_q = v_gi2p.sub(v_gi2);
    const scale_sch = 2.0 * csh0 * w * q_schottky_frac * ngf * vcsh0;
    const fc_v_vcsh = fc_v * vcsh0;

    // Depletion charge (v_pgan <= fc*vcsh0)
    // arg_dep = max(1 - v_pgan/vcsh0, 1e-30)
    const arg_dep = v_pgan_q.scale(-1.0 / vcsh0).addC(1.0).maxC(1.0e-30);
    // q_sch_dep = scale_sch*(1 - sqrt(arg_dep))
    const q_sch_dep = arg_dep.sqrt().neg().addC(1.0).scale(scale_sch);

    // Taylor series extension (v_pgan > fc*vcsh0)
    const arg_fc = @max(1.0 - fc_v, 1.0e-30);
    const sqrt_fc = @sqrt(arg_fc);
    const q_fc = scale_sch * (1.0 - sqrt_fc);
    const dv_sch = v_pgan_q.addC(-fc_v_vcsh); // v_pgan - fc*vcsh0
    const inv_sqrt_fc = 1.0 / (sqrt_fc + 1.0e-30);
    const c1_sch = scale_sch * 0.5 / (vcsh0 + 1.0e-30) * inv_sqrt_fc;
    const c2_sch = scale_sch * 0.25 / (vcsh0 * vcsh0 + 1.0e-30) * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc;
    const c3_sch = scale_sch * 0.375 / (vcsh0 * vcsh0 * vcsh0 + 1.0e-30) * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc;
    const c4_sch = scale_sch * 0.625 * 0.375 / (vcsh0 * vcsh0 * vcsh0 * vcsh0 + 1.0e-30) * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc;
    const c5_sch = scale_sch * 0.875 * 0.625 * 0.375 / (vcsh0 * vcsh0 * vcsh0 * vcsh0 * vcsh0 + 1.0e-30) * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc * inv_sqrt_fc;

    // q_sch_taylor_base = q_fc + c1*dv
    const q_sch_taylor_base = dv_sch.scale(c1_sch).addC(q_fc);
    const dv2 = dv_sch.mul(dv_sch);
    const dv3 = dv2.mul(dv_sch);
    const dv4 = dv3.mul(dv_sch);
    const dv5 = dv4.mul(dv_sch);
    const q_sch_t2 = if (pgancshorder >= 2.0) q_sch_taylor_base.add(dv2.scale(c2_sch * 0.5)) else q_sch_taylor_base;
    const q_sch_t3 = if (pgancshorder >= 3.0) q_sch_t2.add(dv3.scale(c3_sch / 6.0)) else q_sch_t2;
    const q_sch_t4 = if (pgancshorder >= 4.0) q_sch_t3.add(dv4.scale(c4_sch / 24.0)) else q_sch_t3;
    const q_sch_taylor = if (pgancshorder >= 5.0) q_sch_t4.add(dv5.scale(c5_sch / 120.0)) else q_sch_t4;

    // Region select on v_pgan <= fc*vcsh0 (original branched on this voltage)
    const q_sch_raw = if (v_pgan_q.val() <= fc_v_vcsh) q_sch_dep else q_sch_taylor;
    const q_sch = if (flagpgan > 0.5) q_sch_raw else S.con(0.0);

    // --- Self-Heating Thermal Capacitance ---
    const cth: f64 = @as(f64, model.cth);
    const q_th = v_dt.scale(cth);

    // --- Trapping Capacitances ---
    const q_ctrap: f64 = @as(f64, model.ctrap);
    const q_cdglag: f64 = @as(f64, model.cdglag);
    const q_rct1dl: f64 = @as(f64, model.rct1dl);
    const q_rct1gl: f64 = @as(f64, model.rct1gl);
    const q_rct2dl: f64 = @as(f64, model.rct2dl);
    const q_rct2gl: f64 = @as(f64, model.rct2gl);
    const q_dt_nom = tamb - tnom_k;
    const q_c_dlt = q_cdglag * (1.0 + q_rct1dl * q_dt_nom + q_rct2dl * q_dt_nom * q_dt_nom);
    const q_c_glt = q_cdglag * (1.0 + q_rct1gl * q_dt_nom + q_rct2gl * q_dt_nom * q_dt_nom);
    const q_trap = if (trapselect > 0.5 and trapselect < 1.5) v_vtrap.scale(q_ctrap) else S.con(0.0);
    const q_vdl = if (trapselect > 1.5) v_vdl.scale(q_c_dlt) else S.con(0.0);
    const q_vgl = if (trapselect > 1.5) v_vgl.scale(q_c_glt) else S.con(0.0);

    // --- gm-Dispersion Capacitance ---
    const gmdisp: f64 = @floatFromInt(model.gmdisp);
    const q_taugmrf: f64 = @as(f64, model.taugmrf);
    const q_xt1 = if (gmdisp > 0.5) v_xt1.scale(q_taugmrf) else S.con(0.0);
    const q_xt2 = if (gmdisp > 0.5) v_xt2.scale(q_taugmrf / 3.0) else S.con(0.0);

    // --- Assemble charge outputs ---
    var out: [n_u]S = undefined;

    out[D] = S.con(0.0);
    out[G] = S.con(0.0);
    out[S_] = S.con(0.0);

    // b: body charge from fringing and FP body caps
    out[B] = q_frin_ssub.neg().sub(q_frin_dsub).sub(q_frin_gsub).sub(q_cb_fps1).sub(q_cb_fps2).sub(q_cb_fps3).sub(q_cb_fps4).sub(q_cb_fp1).sub(q_cb_fp2).sub(q_cb_fp3).sub(q_cb_fp4);

    out[DT] = q_th;
    out[GI1] = S.con(0.0);

    // gi2: gate charge from intrinsic + fringing
    out[GI2] = q_gs_intr.add(q_gd_intr).add(q_frin_gs).add(q_frin_gd).add(q_frin_gsub).add(q_cc_fps1).add(q_cc_fps2).add(q_cc_fps3).add(q_cc_fps4).add(q_cc_fp1).add(q_cc_fp2).add(q_cc_fp3).add(q_cc_fp4).add(q_sch);

    // gi2p: p-GaN junction charge
    out[GI2P] = q_sch.neg();

    // si: source charge
    out[SI] = q_gs_intr.neg().sub(q_frin_gs).add(q_frin_ssub).sub(q_frin_ds).sub(q_cs_fps1).sub(q_cs_fps2).sub(q_cs_fps3).sub(q_cs_fps4).sub(q_cs_fp1).sub(q_cs_fp2).sub(q_cs_fp3).sub(q_cs_fp4);

    // di: drain charge
    out[DI] = q_gd_intr.neg().sub(q_frin_gd).add(q_frin_dsub).add(q_frin_ds);

    out[SRC] = S.con(0.0);
    out[DRC] = S.con(0.0);

    // fps1-fps4
    out[FPS1] = q_cc_fps1.neg().sub(q_cb_fps1);
    out[FPS2] = q_cc_fps2.neg().sub(q_cb_fps2);
    out[FPS3] = q_cc_fps3.neg().sub(q_cb_fps3);
    out[FPS4] = q_cc_fps4.neg().sub(q_cb_fps4);

    // fp1-fp4
    out[FP1] = q_cc_fp1.neg().sub(q_cb_fp1);
    out[FP2] = q_cc_fp2.neg().sub(q_cb_fp2);
    out[FP3] = q_cc_fp3.neg().sub(q_cb_fp3);
    out[FP4] = q_cc_fp4.neg().sub(q_cb_fp4);

    // xt1, xt2
    out[XT1] = q_xt1;
    out[XT2] = q_xt2;

    // vtrap, vdl, vgl
    out[VTRAP] = q_trap;
    out[VDL] = q_vdl;
    out[VGL] = q_vgl;

    return out;
}

// ============================================================================
// Voltage Limiting
//
// Limits Newton steps for:
//   - Gate junction voltages (PN junction limiting)
//   - Intrinsic FET gate-source/gate-drain (FET limiting)
//   - p-GaN junction voltage
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const GI2 = @intFromEnum(U.gi2);
    const GI2P = @intFromEnum(U.gi2p);
    const SI = @intFromEnum(U.si);
    const DI = @intFromEnum(U.di);

    var result = x_new;
    const phi_t = KB * (@as(f64, model.tnom) + 273.15) / Q_ELEC;

    // --- DEVpnjlim for gate diodes (gi2p-si, gi2p-di) ---
    const ijs: f64 = @as(f64, model.ijs);
    const v_crit = phi_t * contract.fmath.log(phi_t / (@sqrt(2.0) * @max(ijs, 1.0e-30)));

    // Gate-Source junction limiting (gi2p - si)
    const vgs_new = x_new[GI2P] - x_new[SI];
    const vgs_old = x_old[GI2P] - x_old[SI];
    const vgs_lim = pnjlim(vgs_new, vgs_old, phi_t, v_crit);
    const dvgs = vgs_lim - vgs_new;
    result[GI2P] = result[GI2P] + dvgs;

    // Gate-Drain junction limiting (gi2p - di)
    const vgd_new = result[GI2P] - x_new[DI];
    const vgd_old = x_old[GI2P] - x_old[DI];
    const vgd_lim = pnjlim(vgd_new, vgd_old, phi_t, v_crit);
    const dvgd = vgd_lim - vgd_new;
    result[GI2P] = result[GI2P] + dvgd;

    // --- DEVfetlim for intrinsic FET (gi2-si, gi2-di) ---
    const vto_f: f64 = @as(f64, model.vto);
    const vgs_fet_new = x_new[GI2] - x_new[SI];
    const vgs_fet_old = x_old[GI2] - x_old[SI];
    const vgs_fet_lim = fetlim(vgs_fet_new, vgs_fet_old, vto_f);
    const dvgs_fet = vgs_fet_lim - vgs_fet_new;
    result[GI2] = result[GI2] + dvgs_fet;

    const vgd_fet_new = result[GI2] - x_new[DI];
    const vgd_fet_old = x_old[GI2] - x_old[DI];
    const vgd_fet_lim = fetlim(vgd_fet_new, vgd_fet_old, vto_f);
    const dvgd_fet = vgd_fet_lim - vgd_fet_new;
    result[GI2] = result[GI2] + dvgd_fet;

    return result;
}

// PN junction voltage limiting (DEVpnjlim)
inline fn pnjlim(v_new: f64, v_old: f64, phi_t: f64, v_crit: f64) f64 {
    const dv = v_new - v_old;
    const v_abs = @abs(dv);
    const small_step = v_abs < 2.0 * phi_t;
    const forward_big = v_new > v_crit;
    const arg = @min(1.0 + (v_new - v_old) / (phi_t + 1.0e-30), 80.0);
    const v_log = v_old + phi_t * contract.fmath.log(@max(arg, 1.0e-30));
    const result = if (small_step) v_new else (if (forward_big) v_log else v_new);
    return result;
}

// FET gate voltage limiting (DEVfetlim)
inline fn fetlim(v_new: f64, v_old: f64, vto: f64) f64 {
    const vgs_t = v_old - vto;
    const dv = v_new - v_old;
    const dv_abs = @abs(dv);
    const limit_val = @max(0.2, 2.0 * @abs(vgs_t));
    const result = if (dv_abs <= limit_val) v_new else v_old + limit_val * dv / (dv_abs + 1.0e-30);
    return result;
}

// ============================================================================
// Parameter stepping (convergence aid)
//
// Scales IS-like parameters by gmin*(1-lambda) to aid convergence.
// lambda=0: fully simplified, lambda=1: original parameters
// ============================================================================

pub fn attempt(model: Model, lam: f64) Model {
    var m = model;
    const gmin_step: f32 = @floatCast(GMIN * (1.0 - lam));

    m.ijs = model.ijs + gmin_step;
    m.ijd = model.ijd + gmin_step;
    m.irecs = model.irecs + gmin_step;
    m.irecd = model.irecd + gmin_step;
    m.irecs2 = model.irecs2 + gmin_step;
    m.irecd2 = model.irecd2 + gmin_step;
    m.ij_pgan = model.ij_pgan + gmin_step;
    m.irec_pgan = model.irec_pgan + gmin_step;
    m.irec_pgan2 = model.irec_pgan2 + gmin_step;
    m.ijscbd = model.ijscbd + gmin_step;
    m.ijdcbd = model.ijdcbd + gmin_step;
    m.isat = model.isat + gmin_step;

    return m;
}

// ============================================================================
// Noise Sources
//
// 1. Channel thermal noise (si-di)
// 2. Gate shot noise (gi2p-si, gi2p-di)
// 3. Flicker noise (si-di, 1/f)
// 4. Parasitic resistance thermal noise (s-src, d-drc, g-gi1, gi1-gi2)
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: si -> di
    .{ .row = @intFromEnum(U.si), .col = @intFromEnum(U.di), .kind = .thermal },
    // Gate-Source shot noise: gi2p -> si
    .{ .row = @intFromEnum(U.gi2p), .col = @intFromEnum(U.si), .kind = .shot },
    // Gate-Drain shot noise: gi2p -> di
    .{ .row = @intFromEnum(U.gi2p), .col = @intFromEnum(U.di), .kind = .shot },
    // Flicker noise: si -> di
    .{ .row = @intFromEnum(U.si), .col = @intFromEnum(U.di), .kind = .flicker },
    // Source contact resistance thermal noise: s -> src
    .{ .row = @intFromEnum(U.s), .col = @intFromEnum(U.src), .kind = .thermal },
    // Drain contact resistance thermal noise: d -> drc
    .{ .row = @intFromEnum(U.d), .col = @intFromEnum(U.drc), .kind = .thermal },
    // Gate resistance 1 thermal noise: g -> gi1
    .{ .row = @intFromEnum(U.g), .col = @intFromEnum(U.gi1), .kind = .thermal },
    // Gate resistance 2 thermal noise: gi1 -> gi2
    .{ .row = @intFromEnum(U.gi1), .col = @intFromEnum(U.gi2), .kind = .thermal },
};

// ============================================================================
// Validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Build a "quiescent" bias where every node sits at 0 V. All difference
// voltages are then 0, so most exponential branches evaluate at their
// baseline. Used to sanity-check symmetry and the trivial residual.
fn zeroBias() [n_u]f64 {
    return [_]f64{0.0} ** n_u;
}

test "mvsg: default model residual at zero bias is finite and small" {
    // At V=0 everywhere the intrinsic FET has vgs=vgd=0 (deep subthreshold,
    // vto=-2.72 so channel is ON actually: vgs_max - vt_dibl = 0-(-2.72)=2.72).
    // We don't assert an exact channel current here (many coupled nodes), but
    // every residual entry must be finite (no NaN/Inf from the exp/log chains).
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, zeroBias(), &model, &inst, 0);
    for (out) |v| {
        try testing.expect(std.math.isFinite(v));
    }
    // External source/drain contact resistors see 0 V drop -> 0 current.
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.d)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.s)], 1e-12);
}

test "mvsg: contact resistance current (drain) matches Ohm law" {
    // With flagres=0, r_di = rcd/(w*ngf). Put a voltage only across d<->drc.
    // rcd=800e-6, w=180e-6, ngf=1 -> r_di = 800e-6/(180e-6) = 4.4444... ohm
    // g_rcd = 1/r_di = 225 S.  Set v_d=1e-3, v_drc=0 -> i_rcd = 1e-3*225 = 0.225 A.
    // out[d] = i_rcd. (Hand arithmetic: 800e-6/180e-6 = 4.444444...,
    //   1/4.444444 = 0.225, times 1e-3 = 2.25e-4.)
    const model: Model = .{};
    const inst: Instance = .{};
    var x = zeroBias();
    x[@intFromEnum(U.d)] = 1e-3;
    // Keep drc at 0.
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // r_di = 800e-6 / (180e-6 * 1) = 4.44444...; g = 0.225 S; i = 2.25e-4 A.
    const g_expected: f64 = 1.0 / (800e-6 / (180e-6 * 1.0));
    try testing.expectApproxEqAbs(@as(f64, 1e-3 * g_expected), out[@intFromEnum(U.d)], 1e-9);
}

test "mvsg: thermal capacitance charge q[dt] = cth * v_dt" {
    // cth=1e-4 default. Set v_dt = 2.0 -> q[dt] = 2e-4.
    const model: Model = .{};
    const inst: Instance = .{};
    var x = zeroBias();
    x[@intFromEnum(U.dt)] = 2.0;
    const qout = contract.qValues(Self, x, &model, &inst, 0);
    // q_th = cth * v_dt = 1e-4 * 2.0 = 2e-4
    try testing.expectApproxEqAbs(@as(f64, 2e-4), qout[@intFromEnum(U.dt)], 1e-9);
}

test "mvsg: intrinsic channel conducts forward drain current (on-state)" {
    // Drive the internal gate above threshold and put a small drain bias on
    // the intrinsic drain relative to intrinsic source. vto=-2.72, so with
    // v_gi2=0, v_si=0, v_di=0.05 we have vgs=0 (well above vt) -> channel ON,
    // vds=0.05 -> forward current flows si->di. Sign check only + finiteness:
    // out[di] should be > 0 (current sourced into di from channel) while
    // out[si] < 0 (drawn out of si), by KCL symmetry of the intrinsic branch.
    const model: Model = .{};
    const inst: Instance = .{};
    var x = zeroBias();
    x[@intFromEnum(U.gi2)] = 0.0;
    x[@intFromEnum(U.si)] = 0.0;
    x[@intFromEnum(U.di)] = 0.05;
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    for (out) |v| try testing.expect(std.math.isFinite(v));
    // With vds>0 the intrinsic transistor pushes positive ids (type_f=+1),
    // contributing +i_ds_intr to out[di]. Assert a nonzero forward current.
    try testing.expect(@abs(out[@intFromEnum(U.di)]) > 0.0);
}

test "mvsg: fringing charge responds to gate-source bias" {
    // Enable a fringing cap and check q[gi2] grows with v_gi2. Default cofsm=0,
    // so set cofsm to a nonzero value; the bias-dependent term is
    // cof_m*nfrin*log(1+exp((v-vtfrin)/nfrin))*w*ngf. Just assert q[gi2] is
    // finite and changes between two biases (monotone in gate voltage).
    const model: Model = .{ .cofsm = 1e-3 };
    const inst: Instance = .{};
    const x0 = zeroBias();
    var x1 = zeroBias();
    x1[@intFromEnum(U.gi2)] = 1.0;
    const q0 = contract.qValues(Self, x0, &model, &inst, 0);
    const q1 = contract.qValues(Self, x1, &model, &inst, 0);
    try testing.expect(std.math.isFinite(q0[@intFromEnum(U.gi2)]));
    try testing.expect(std.math.isFinite(q1[@intFromEnum(U.gi2)]));
    // Raising v_gi2 increases the fringing (gate) charge stored at gi2.
    try testing.expect(q1[@intFromEnum(U.gi2)] != q0[@intFromEnum(U.gi2)]);
}
